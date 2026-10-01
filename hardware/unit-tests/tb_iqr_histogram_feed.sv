`timescale 1ns / 1ps

import libstf::*;

/**
 * Standalone testbench for IqrHistogramFeed -- the multi-lane arbitration the production top uses
 * to run IQR pass 1 during decode.
 *
 * WHY THIS EXISTS. build-15 shipped with an arbiter bug that HUNG THE DECODER on silicon, with no
 * host-visible error at all: `out.valid` followed `any_head` (ANY lane has a head) while the payload
 * came from sk_data[grant], last cycle's winner -- precisely the lane that has just run dry. Garbage
 * `keep` bits inflated the element count, `last` fired early, the IQR core left HISTOGRAM, the top's
 * mux parked this module's ready at 0, the skids filled, and the tee stopped the decoder dead.
 *
 * It is invisible at N_LANES=1, where `grant` is always 0. So this testbench runs FOUR lanes at
 * deliberately uneven rates, which is the only condition that exposes it.
 *
 * What it checks, per scenario:
 *   1. every element pushed is emitted EXACTLY ONCE  (values are unique, tagged lane<<32 | index)
 *   2. no element is emitted that was never pushed   (catches garbage from an empty slot)
 *   3. o_fed_elements == the true total
 *   4. `last` is asserted exactly once, on the beat that completes the column
 *   5. o_done rises and stays
 *   6. the module never back-pressures forever (a lane's ready must recover)
 *
 * Run:  see hardware/unit-tests/run_feed_tb.sh
 */
module tb_iqr_histogram_feed;

    localparam int N_LANES      = 4;
    localparam int NUM_ELEMENTS = 8;      // 8 x int64 per 512-bit beat, as in the production top
    localparam int CLK_HALF     = 2;      // 4 ns period == 250 MHz

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    // -- DUT wiring ------------------------------------------------------------------------------
    logic                                       i_enable;
    logic [63:0]                                i_expected;
    logic                                       i_restart;
    logic [N_LANES-1:0]                         i_valid;
    logic [N_LANES-1:0]                         o_ready;
    data64_t [N_LANES-1:0][NUM_ELEMENTS-1:0]    i_data;
    logic [N_LANES-1:0][NUM_ELEMENTS-1:0]       i_keep;
    logic [63:0]                                o_fed_elements;
    logic                                       o_done;

    ndata_i #(data64_t, NUM_ELEMENTS) out (.clk(clk), .rst_n(rst_n));

    IqrHistogramFeed #(
        .value_t(data64_t),
        .NUM_ELEMENTS(NUM_ELEMENTS),
        .N_LANES(N_LANES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .i_enable(i_enable),
        .i_expected(i_expected),
        .i_restart(i_restart),
        .i_valid(i_valid),
        .o_ready(o_ready),
        .i_data(i_data),
        .i_keep(i_keep),
        .o_fed_elements(o_fed_elements),
        .o_done(o_done),
        .out(out)
    );

    // -- Scoreboard ------------------------------------------------------------------------------
    // Values are unique across the whole run: (lane << 32) | index. `pushed` records what the lanes
    // handed over; `emitted` counts what came out. Any mismatch localizes the failure.
    int  pushed  [longint];
    int  emitted [longint];
    int  errors      = 0;
    int  n_pushed    = 0;
    int  n_emitted   = 0;
    int  n_last      = 0;

    // The IQR core holds ready high through HISTOGRAM but does stall (BRAM clear, bank conflicts),
    // so drive a pseudo-random ready rather than a constant 1 -- a constant would never fill the
    // skid buffers, which is half of what this module is for.
    logic [15:0] lfsr = 16'hACE1;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign out.ready = rst_n && (lfsr[3:0] != 4'd0);   // ~94% ready

    // Emission checker.
    always_ff @(posedge clk) begin
        if (rst_n && out.valid && out.ready) begin
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                if (out.keep[e]) begin
                    automatic longint v = out.data[e];
                    if (!pushed.exists(v)) begin
                        $error("[%0t] EMITTED A VALUE THAT WAS NEVER PUSHED: 0x%0h (lane %0d slot %0d)",
                               $time, v, v >> 32, v[31:0]);
                        errors++;
                    end else if (emitted.exists(v)) begin
                        $error("[%0t] DUPLICATE EMISSION: 0x%0h", $time, v);
                        errors++;
                    end else begin
                        emitted[v] = 1;
                    end
                    n_emitted++;
                end
            end
            if (out.last) begin
                n_last++;
                if (n_emitted != i_expected) begin
                    $error("[%0t] `last` on the wrong beat: emitted %0d, expected %0d",
                           $time, n_emitted, i_expected);
                    errors++;
                end
            end
        end
    end

    // -- Lane driver -----------------------------------------------------------------------------
    // `gap` models the decoder lanes running at different rates: lane L offers a beat only every
    // (L+1)-th opportunity, so lanes empty at different times -- which is the condition that makes
    // `grant` go stale.
    // Stimulus changes on the NEGEDGE and `ready` is sampled on the negedge too -- that is the value
    // the upcoming posedge will see alongside valid, so "taken" is decided without racing the DUT's
    // own registers. Driving valid with a non-blocking assign and polling ready after the posedge
    // (the obvious-looking version) leaves valid high one edge too long and pushes the same beat
    // twice, which shows up as DUPLICATE EMISSION and looks exactly like a DUT bug.
    task automatic drive_lane(input int lane, input int n_beats, input int gap,
                              input int last_beat_keep);
        int  slot = 0;
        bit  taken;
        for (int b = 0; b < n_beats; b++) begin
            int k = (b == n_beats - 1) ? last_beat_keep : NUM_ELEMENTS;
            // idle for `gap` cycles before offering the beat
            for (int g = 0; g < gap; g++) begin
                @(negedge clk);
                i_valid[lane] = 1'b0;
                @(posedge clk);
            end
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                if (e < k) begin
                    i_data[lane][e] = (longint'(lane) << 32) | slot;
                    i_keep[lane][e] = 1'b1;
                    pushed[(longint'(lane) << 32) | slot] = 1;
                    n_pushed++;
                    slot++;
                end else begin
                    i_data[lane][e] = 64'hDEAD_BEEF_DEAD_BEEF;   // must never be emitted
                    i_keep[lane][e] = 1'b0;
                end
            end
            i_valid[lane] = 1'b1;
            taken = 1'b0;
            while (!taken) begin
                taken = o_ready[lane];   // stable at the negedge == what the posedge will sample
                @(posedge clk);
                @(negedge clk);
            end
            i_valid[lane] = 1'b0;
        end
        @(negedge clk);
        i_valid[lane] = 1'b0;
    endtask

    // -- Scenarios -------------------------------------------------------------------------------
    task automatic reset_dut();
        rst_n     = 1'b0;
        i_enable  = 1'b0;
        i_restart = 1'b0;
        i_valid   = '0;
        i_data    = '0;
        i_keep    = '0;
        pushed.delete();
        emitted.delete();
        n_pushed  = 0;
        n_emitted = 0;
        n_last    = 0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    task automatic run_scenario(input string name, input int beats[N_LANES],
                                input int gaps[N_LANES], input int last_keep);
        int total = 0;
        int before_errors = errors;
        reset_dut();
        for (int L = 0; L < N_LANES; L++) begin
            total += (beats[L] - 1) * NUM_ELEMENTS + ((L == N_LANES-1) ? last_keep : NUM_ELEMENTS);
        end
        i_expected = total;
        i_enable   = 1'b1;
        @(posedge clk);
        i_restart  = 1'b1;
        @(posedge clk);
        i_restart  = 1'b0;

        fork
            drive_lane(0, beats[0], gaps[0], (0 == N_LANES-1) ? last_keep : NUM_ELEMENTS);
            drive_lane(1, beats[1], gaps[1], (1 == N_LANES-1) ? last_keep : NUM_ELEMENTS);
            drive_lane(2, beats[2], gaps[2], (2 == N_LANES-1) ? last_keep : NUM_ELEMENTS);
            drive_lane(3, beats[3], gaps[3], (3 == N_LANES-1) ? last_keep : NUM_ELEMENTS);
        join

        // let the skids drain
        repeat (400) @(posedge clk);

        if (n_emitted != total) begin
            $error("%s: emitted %0d elements, pushed %0d", name, n_emitted, total);
            errors++;
        end
        if (o_fed_elements != total) begin
            $error("%s: o_fed_elements = %0d, expected %0d", name, o_fed_elements, total);
            errors++;
        end
        if (n_last != 1) begin
            $error("%s: `last` asserted %0d times, expected exactly 1", name, n_last);
            errors++;
        end
        if (!o_done) begin
            $error("%s: o_done never rose", name);
            errors++;
        end
        $display("  %-28s total=%5d emitted=%5d fed=%5d last=%0d done=%0b  %s",
                 name, total, n_emitted, o_fed_elements, n_last, o_done,
                 (errors == before_errors) ? "PASS" : "*** FAIL ***");
    endtask

    initial begin
        int beats[N_LANES];
        int gaps [N_LANES];

        $display("=== IqrHistogramFeed testbench (N_LANES=%0d, NUM_ELEMENTS=%0d) ===",
                 N_LANES, NUM_ELEMENTS);

        // Uneven rates: the case the production top actually sees, and the one that makes `grant`
        // go stale while another lane still has data.
        beats = '{20, 20, 20, 20};  gaps = '{0, 1, 2, 3};
        run_scenario("uneven rates", beats, gaps, NUM_ELEMENTS);

        // Very uneven depths: lanes finish at wildly different times, so the granted lane is empty
        // for long stretches while others are full.
        beats = '{40,  5, 25, 10};  gaps = '{0, 3, 1, 2};
        run_scenario("uneven depths", beats, gaps, NUM_ELEMENTS);

        // Partial final beat: `last` must land on the element that completes the column, not on a
        // beat boundary.
        beats = '{12, 12, 12, 12};  gaps = '{1, 0, 2, 1};
        run_scenario("partial last beat", beats, gaps, 3);

        // One lane silent: exercises the wrap-around search with a permanently empty lane.
        beats = '{15, 1, 15, 15};   gaps = '{0, 0, 1, 2};
        run_scenario("one lane nearly idle", beats, gaps, NUM_ELEMENTS);

        // Back-to-back with no gaps: maximum skid pressure.
        beats = '{30, 30, 30, 30};  gaps = '{0, 0, 0, 0};
        run_scenario("saturated, no gaps", beats, gaps, NUM_ELEMENTS);

        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "ALL SCENARIOS PASSED" : "FAILURES", errors,
                 (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "IqrHistogramFeed testbench FAILED");
        $finish;
    end

    // Global watchdog: a deadlocked arbiter would otherwise spin forever.
    initial begin
        #2_000_000;
        $fatal(1, "TIMEOUT -- the feed stopped making progress (deadlock?)");
    end

endmodule

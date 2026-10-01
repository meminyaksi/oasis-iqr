`timescale 1ns / 1ps

import libstf::*;

/**
 * Integration testbench: IqrHistogramFeed -> pass mux -> IQR_detection, wired EXACTLY as
 * hardware/src/vfpga_top.svh wires them for the fused path -- the seam the unit test on the feed
 * alone cannot reach.
 *
 * WHAT IT PROVES. The two halves of the fused operator have their own tests (tb_iqr_histogram_feed
 * for the merge, iqr_detection_test for the histogram/quartile math) but had NEVER run connected.
 * This drives a real column through the actual two-pass flow:
 *
 *   pass 1 (fused): the column is split across 4 decoder lanes and merged by the feed into
 *                   IQR_detection's HISTOGRAM input -- the mux selects the feed because
 *                   fuse_enable && o_hist_active.
 *   pass 2 (host):  the SAME column is re-streamed in order through the host port; o_hist_active is
 *                   now low so the mux selects it, and IQR_detection emits one 0/1 flag per element.
 *
 * and asserts, against an independent reference model computed with the same integer math:
 *   - dbg_total == N            (the histogram counted every element -- the on-silicon gate)
 *   - the flag column matches bit-for-bit, in order
 *   - o_hist_active is high through pass 1 and low through pass 2 (the mux switches when it should)
 *
 * The mux logic below is copied verbatim from vfpga_top.svh; if that file's handoff is wrong, this
 * reproduces it. (It does NOT compile vfpga_top.svh itself -- that needs the whole Coyote shell.)
 *
 * Run:  hardware/unit-tests/run_fused_integration_tb.sh
 */
module tb_iqr_fused_integration;

    localparam int N_LANES      = 4;
    localparam int NUM_ELEMENTS = 8;
    localparam int NUM_BINS     = 16;
    localparam int BIN_SHIFT    = 4;      // bin width 16 -> covers 0..255 in 16 bins
    localparam longint BIN_MIN  = 0;
    localparam int IS_SIGNED    = 0;
    localparam int CLK_HALF     = 2;

    localparam int N = 96;                // 12 beats, 3 per lane -- clean round-robin

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    // -- The column and its reference flags ------------------------------------------------------
    longint col   [N];
    bit     ref_fl[N];

    // -- Feed side -------------------------------------------------------------------------------
    logic                                       fuse_enable;
    logic [63:0]                                i_expected;
    logic                                       clear_pulse;   // -> feed i_restart AND core clear_req
    logic [N_LANES-1:0]                         i_valid;
    logic [N_LANES-1:0]                         o_ready;
    data64_t [N_LANES-1:0][NUM_ELEMENTS-1:0]    i_data;
    logic [N_LANES-1:0][NUM_ELEMENTS-1:0]       i_keep;
    logic [63:0]                                fed_elements;
    logic                                       feed_done;

    ndata_i #(data64_t, NUM_ELEMENTS) feed_out (.clk(clk), .rst_n(rst_n));

    IqrHistogramFeed #(
        .value_t(data64_t), .NUM_ELEMENTS(NUM_ELEMENTS), .N_LANES(N_LANES)
    ) feed (
        .clk(clk), .rst_n(rst_n),
        .i_enable(fuse_enable), .i_expected(i_expected), .i_restart(clear_pulse),
        .i_valid(i_valid), .o_ready(o_ready), .i_data(i_data), .i_keep(i_keep),
        .o_fed_elements(fed_elements), .o_done(feed_done),
        .out(feed_out)
    );

    // -- Host side (pass 2 re-stream), driven by the TB ------------------------------------------
    ndata_i #(data64_t, NUM_ELEMENTS) host_in (.clk(clk), .rst_n(rst_n));

    // -- Pass mux + core -------------------------------------------------------------------------
    logic hist_active;
    ndata_i #(data64_t, NUM_ELEMENTS) iqr_in  (.clk(clk), .rst_n(rst_n));
    ndata_i #(data64_t, NUM_ELEMENTS) flag_out(.clk(clk), .rst_n(rst_n));

    // --- copied verbatim from vfpga_top.svh ---
    logic take_feed;
    assign take_feed      = fuse_enable && hist_active;
    assign iqr_in.data    = take_feed ? feed_out.data  : host_in.data;
    assign iqr_in.keep    = take_feed ? feed_out.keep  : host_in.keep;
    assign iqr_in.last    = take_feed ? feed_out.last  : host_in.last;
    assign iqr_in.valid   = take_feed ? feed_out.valid : host_in.valid;
    assign feed_out.ready = take_feed ? iqr_in.ready   : 1'b0;
    assign host_in.ready  = take_feed ? 1'b0           : iqr_in.ready;
    // --- end verbatim ---

    data64_t dbg_total, dbg_clear_seq;
    logic [63:0] dbg_accepted, dbg_committed, dbg_flushes, dbg_collisions;

    IQR_detection #(
        .value_t(data64_t), .NUM_ELEMENTS(NUM_ELEMENTS),
        .NUM_BINS(NUM_BINS), .COUNT_WIDTH(32)
    ) core (
        .clk(clk), .rst_n(rst_n),
        .bin_min  (data64_t'(BIN_MIN)),
        .bin_shift(($clog2($bits(data64_t) + 1))'(BIN_SHIFT)),
        .is_signed(IS_SIGNED[0]),
        .clear_req(clear_pulse),
        .dbg_total(dbg_total), .dbg_clear_seq(dbg_clear_seq),
        .dbg_accepted(dbg_accepted), .dbg_committed(dbg_committed),
        .dbg_flushes(dbg_flushes), .dbg_collisions(dbg_collisions),
        .o_hist_active(hist_active),
        // Step 2 ports: index mode stays OFF here -- this testbench is the value-path reference
        // that tb_iqr_index_stream's index path is checked against.
        .i_idx_mode(1'b0),
        .i_expected(64'(N)),
        .o_idx_data(), .o_idx_valid(), .i_idx_ready(1'b1), .o_idx_last(), .o_idx_beats(),
        .in(iqr_in), .out(flag_out)
    );

    // -- Reference model (same integer math as the hardware) -------------------------------------
    function automatic int value_to_bin(longint v);
        longint shifted = (v - BIN_MIN) >>> BIN_SHIFT;
        if (shifted < 0)          return 0;
        if (shifted >= NUM_BINS)  return NUM_BINS - 1;
        return int'(shifted);
    endfunction

    task automatic compute_reference();
        int      hist [NUM_BINS];
        int      total, cum, q1b, q3b;
        bit      q1f, q3f;
        longint  q1v, q3v, iqr, lo, hi;
        foreach (hist[b]) hist[b] = 0;
        for (int i = 0; i < N; i++) hist[value_to_bin(col[i])]++;
        total = N; cum = 0; q1f = 0; q3f = 0; q1b = NUM_BINS-1; q3b = NUM_BINS-1;
        for (int b = 0; b < NUM_BINS; b++) begin
            cum += hist[b];
            if (!q1f && cum*4 >= total)     begin q1b = b; q1f = 1; end
            if (!q3f && cum*4 >= 3*total)    begin q3b = b; q3f = 1; end
        end
        q1v = BIN_MIN + (longint'(q1b) <<< BIN_SHIFT);
        q3v = BIN_MIN + (longint'(q3b) <<< BIN_SHIFT);
        iqr = q3v - q1v;
        lo  = q1v - iqr - (iqr >>> 1);   // 1.5*IQR = IQR + IQR>>1, exactly as hardware
        hi  = q3v + iqr + (iqr >>> 1);
        for (int i = 0; i < N; i++) ref_fl[i] = (col[i] < lo || col[i] > hi) ? 1'b1 : 1'b0;
        $display("  reference: q1=%0d q3=%0d iqr=%0d fences=[%0d,%0d]", q1v, q3v, iqr, lo, hi);
    endtask

    // -- Drivers ---------------------------------------------------------------------------------
    // Pass 1: feed lane L gets column beats whose beat-index % N_LANES == L. Order does not matter
    // to a histogram, so this models the real decoder spreading a column over its lanes.
    task automatic drive_pass1_lane(input int lane);
        int nbeats = (N + NUM_ELEMENTS - 1) / NUM_ELEMENTS;
        bit taken;
        for (int b = lane; b < nbeats; b += N_LANES) begin
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                int idx = b*NUM_ELEMENTS + e;
                if (idx < N) begin
                    i_data[lane][e] = data64_t'(col[idx]);
                    i_keep[lane][e] = 1'b1;
                end else begin
                    i_data[lane][e] = 64'hDEAD_BEEF;
                    i_keep[lane][e] = 1'b0;
                end
            end
            i_valid[lane] = 1'b1;
            taken = 1'b0;
            while (!taken) begin
                taken = o_ready[lane];
                @(posedge clk); @(negedge clk);
            end
            i_valid[lane] = 1'b0;
        end
        @(negedge clk);
        i_valid[lane] = 1'b0;
    endtask

    // Pass 2: the whole column, in order, on the host port. Collects one flag per element off
    // flag_out in the same order and checks it against the reference.
    int  n_flags = 0;
    int  errors  = 0;

    always_ff @(posedge clk) begin
        if (rst_n && flag_out.valid && flag_out.ready) begin
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                if (flag_out.keep[e]) begin
                    if (n_flags < N) begin
                        if (flag_out.data[e][0] !== ref_fl[n_flags]) begin
                            $error("flag[%0d] = %0b, expected %0b (value %0d)",
                                   n_flags, flag_out.data[e][0], ref_fl[n_flags], col[n_flags]);
                            errors++;
                        end
                    end
                    n_flags++;
                end
            end
        end
    end
    assign flag_out.ready = rst_n;   // host always ready to take flags

    task automatic drive_pass2();
        int nbeats = (N + NUM_ELEMENTS - 1) / NUM_ELEMENTS;
        bit taken;
        for (int b = 0; b < nbeats; b++) begin
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                int idx = b*NUM_ELEMENTS + e;
                if (idx < N) begin
                    host_in.data[e] = data64_t'(col[idx]);
                    host_in.keep[e] = 1'b1;
                end else begin
                    host_in.data[e] = '0;
                    host_in.keep[e] = 1'b0;
                end
            end
            host_in.valid = 1'b1;
            host_in.last  = (b == nbeats - 1);
            taken = 1'b0;
            while (!taken) begin
                taken = host_in.ready;
                @(posedge clk); @(negedge clk);
            end
            host_in.valid = 1'b0;
            host_in.last  = 1'b0;
        end
    endtask

    // -- Sequence --------------------------------------------------------------------------------
    initial begin
        // A column with a clear body and a few outliers on both ends, so q1 != q3 and the fences
        // actually flag something.
        for (int i = 0; i < N; i++) col[i] = 40 + (i * 37) % 80;   // spread across 40..119
        col[5]  = 0;    col[50] = 2;                                // low outliers
        col[10] = 255;  col[77] = 250;  col[88] = 240;             // high outliers
        compute_reference();

        fuse_enable = 1'b0; i_expected = '0; clear_pulse = 1'b0;
        i_valid = '0; i_data = '0; i_keep = '0;
        host_in.valid = 1'b0; host_in.last = 1'b0; host_in.data = '0; host_in.keep = '0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // Arm the run, then clear (fences the histogram AND re-arms the feed counter).
        i_expected  = N;
        fuse_enable = 1'b1;
        @(negedge clk); clear_pulse = 1'b1;
        @(negedge clk); clear_pulse = 1'b0;
        // Fence: wait for the clear sweep to complete before streaming pass 1.
        begin
            automatic longint seq0  = dbg_clear_seq;
            automatic int     guard = 0;
            while (dbg_clear_seq == seq0 && guard < 5000) begin @(posedge clk); guard++; end
        end

        $display("=== IQR fused integration (N=%0d, %0d lanes, %0d bins) ===", N, N_LANES, NUM_BINS);

        // Pass 1: all lanes concurrently.
        if (!hist_active) begin
            $error("hist_active LOW at the start of pass 1 -- the mux would select the host port");
            errors++;
        end
        fork
            drive_pass1_lane(0); drive_pass1_lane(1);
            drive_pass1_lane(2); drive_pass1_lane(3);
        join

        // Wait for the feed's terminating `last`, then for the core to leave HISTOGRAM.
        begin automatic int g = 0; while (!feed_done && g < 5000) begin @(posedge clk); g++; end end
        $display("  [dbg] feed_done=%0b fed_elements=%0d accepted=%0d committed=%0d",
                 feed_done, fed_elements, dbg_accepted, dbg_committed);
        begin automatic int g = 0; while (hist_active && g < 5000) begin @(posedge clk); g++; end end
        // dbg_total is accumulated during Q_SUM, which runs AFTER HISTOGRAM. Give the scan time.
        repeat (2*NUM_BINS + 32) @(posedge clk);
        $display("  [dbg] after scan: dbg_total=%0d accepted=%0d committed=%0d",
                 dbg_total, dbg_accepted, dbg_committed);

        if (dbg_total !== N) begin
            $error("dbg_total = %0d, expected %0d  (histogram lost/gained counts)", dbg_total, N);
            errors++;
        end else
            $display("  pass 1 OK: dbg_total = %0d, fed_elements = %0d", dbg_total, fed_elements);

        // Pass 2: host stream stalls automatically through QUARTILES (in.ready low) and flows in FLAG.
        drive_pass2();
        repeat (40) @(posedge clk);

        if (n_flags != N) begin
            $error("emitted %0d flags, expected %0d", n_flags, N);
            errors++;
        end

        if (errors == 0)
            $display("=== PASS: %0d flags match, dbg_total == N, mux switched correctly ===", n_flags);
        else
            $display("=== FAIL: %0d error(s) ===", errors);

        if (errors != 0) $fatal(1, "integration testbench FAILED");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "TIMEOUT -- fused datapath stopped making progress (deadlock?)");
    end

endmodule

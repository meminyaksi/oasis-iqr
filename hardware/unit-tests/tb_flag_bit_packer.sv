`timescale 1ns / 1ps

import libstf::*;

/**
 * Testbench for FlagBitPacker -- the per-element flag stream -> dense bitmask packer.
 *
 * WHY THIS EXISTS. The packer was rewritten from an indexed write into a 512-bit accumulator
 * (acc[slot*8 +: 8] = bits, a 64-way barrel-shifter cloud that was the design's worst timing
 * offender: 330 of 1000 failing paths in build-15, 15.6 levels at fanout 412) into a fixed shift
 * register. The bit LAYOUT must be byte-for-byte identical afterwards or every flag the host reads
 * back is misplaced -- and a misplaced bitmask still returns a plausible outlier COUNT, so the
 * end-to-end benchmarks would not necessarily catch it.
 *
 * The rewrite also introduced a flush: a partial final word sits at the top of the accumulator and is
 * shifted down with zeros until aligned, costing up to SLOTS-1 cycles once per column. The partial
 * cases are therefore the ones that matter most here.
 *
 * Checks, per scenario:
 *   - every emitted word matches a reference packing computed independently in the TB
 *   - the beat count is ceil(N / SLOTS)
 *   - `last` is asserted on exactly the final beat, and nowhere else
 *   - the final word is zero-padded above bit N-1 (no stale bits from the flush)
 *
 * Run:  hardware/unit-tests/run_flag_packer_tb.sh
 */
module tb_flag_bit_packer;

    localparam int NUM_ELEMENTS = 8;
    localparam int LANE_W       = 64;
    localparam int OUT_W        = NUM_ELEMENTS * LANE_W;   // 512
    localparam int SLOTS        = OUT_W / NUM_ELEMENTS;    // 64 input beats per output word
    localparam int CLK_HALF     = 2;
    localparam int MAX_FLAGS    = 4096;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    ndata_i #(data64_t, NUM_ELEMENTS) in  (.clk(clk), .rst_n(rst_n));
    ndata_i #(data64_t, NUM_ELEMENTS) out (.clk(clk), .rst_n(rst_n));

    FlagBitPacker #(
        .value_t(data64_t),
        .NUM_ELEMENTS(NUM_ELEMENTS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in(in),
        .out(out)
    );

    // -- Reference ------------------------------------------------------------------------------
    bit flags   [MAX_FLAGS];      // the flag sequence driven in
    int n_flags;                  // how many are live this scenario
    int errors    = 0;
    int n_words   = 0;            // output words seen
    int n_last    = 0;

    // Expected word w, bit b  <=>  flags[w*OUT_W + b], zero beyond n_flags.
    function automatic logic [OUT_W-1:0] expected_word(int w);
        logic [OUT_W-1:0] e = '0;
        for (int b = 0; b < OUT_W; b++) begin
            int idx = w * OUT_W + b;
            if (idx < n_flags && flags[idx]) e[b] = 1'b1;
        end
        return e;
    endfunction

    // Back-pressure the packer irregularly -- a constant ready would never exercise out_free.
    logic [15:0] lfsr = 16'hBEEF;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign out.ready = rst_n && (lfsr[2:0] != 3'd0);   // ~88% ready

    // -- Output checker -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n && out.valid && out.ready) begin
            automatic logic [OUT_W-1:0] got = '0;
            automatic logic [OUT_W-1:0] exp = expected_word(n_words);
            for (int g = 0; g < NUM_ELEMENTS; g++) begin
                got[g * LANE_W +: LANE_W] = out.data[g];
            end
            if (got !== exp) begin
                $error("word %0d mismatch\n      got 0x%0h\n      exp 0x%0h", n_words, got, exp);
                errors++;
            end
            if (out.keep !== '1) begin
                $error("word %0d: keep = %b, expected all ones (words are always full)",
                       n_words, out.keep);
                errors++;
            end
            n_words++;
            if (out.last) n_last++;
            else if (n_words * OUT_W >= n_flags) begin
                $error("word %0d completes the column but `last` was not asserted", n_words - 1);
                errors++;
            end
        end
    end

    // -- Driver ---------------------------------------------------------------------------------
    // Negedge stimulus, ready sampled on the negedge: that is the value the upcoming posedge sees
    // alongside valid, so "taken" is decided without racing the DUT's registers.
    task automatic drive(input int n);
        automatic bit taken;
        automatic int sent = 0;
        while (sent < n) begin
            automatic int k = (n - sent >= NUM_ELEMENTS) ? NUM_ELEMENTS : (n - sent);
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                if (e < k) begin
                    in.data[e] = data64_t'(flags[sent + e] ? 1 : 0);
                    in.keep[e] = 1'b1;
                end else begin
                    // Unkept lanes carry a 1 in bit 0 on purpose: the packer must mask them off via
                    // keep, not trust the payload. A packer that ignored keep would set stray bits.
                    in.data[e] = data64_t'(1);
                    in.keep[e] = 1'b0;
                end
            end
            in.valid = 1'b1;
            in.last  = ((sent + k) >= n);
            taken    = 1'b0;
            while (!taken) begin
                taken = in.ready;
                @(posedge clk); @(negedge clk);
            end
            in.valid = 1'b0;
            in.last  = 1'b0;
            sent += k;
        end
    endtask

    task automatic run_scenario(input string name, input int n, input int pattern);
        automatic int errors0 = errors;
        automatic int want_words;
        rst_n    = 1'b0;
        in.valid = 1'b0; in.last = 1'b0; in.data = '0; in.keep = '0;
        n_words  = 0; n_last = 0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        n_flags = n;
        for (int i = 0; i < n; i++) begin
            case (pattern)
                0: flags[i] = 1'b0;                       // all clear
                1: flags[i] = 1'b1;                       // all set
                2: flags[i] = (i % 3 == 0);               // sparse
                3: flags[i] = ((i * 7 + 3) % 11 < 4);     // pseudo-random-ish
                default: flags[i] = (i == 0) || (i == n - 1);   // ends only
            endcase
        end

        drive(n);
        repeat (SLOTS + 60) @(posedge clk);   // let any flush drain

        want_words = (n + OUT_W - 1) / OUT_W;
        if (n_words != want_words) begin
            $error("%s: emitted %0d words, expected %0d", name, n_words, want_words);
            errors++;
        end
        if (n_last != 1) begin
            $error("%s: `last` asserted %0d times, expected exactly 1", name, n_last);
            errors++;
        end
        $display("  %-34s N=%5d words=%3d (want %3d) last=%0d  %s",
                 name, n, n_words, want_words, n_last,
                 (errors == errors0) ? "PASS" : "*** FAIL ***");
    endtask

    initial begin
        $display("=== FlagBitPacker testbench (NUM_ELEMENTS=%0d, OUT_W=%0d, SLOTS=%0d) ===",
                 NUM_ELEMENTS, OUT_W, SLOTS);

        // Exactly one full word: no flush at all.
        run_scenario("exact 1 word, all set",        512, 1);
        run_scenario("exact 1 word, mixed",          512, 3);
        // Exactly two full words.
        run_scenario("exact 2 words, mixed",        1024, 3);
        // Partial finals -- the flush path, which is what the rewrite added.
        run_scenario("partial: 1 beat only",            8, 1);
        run_scenario("partial: 1 element only",         1, 1);
        run_scenario("partial: half a word",          256, 3);
        run_scenario("partial: word minus one beat",  504, 3);
        run_scenario("partial: word plus one beat",   520, 3);
        run_scenario("partial: ragged 1000",         1000, 2);
        run_scenario("partial: ends only",            777, 4);
        run_scenario("all clear, ragged",             999, 0);

        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "ALL SCENARIOS PASSED" : "FAILURES", errors,
                 (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "FlagBitPacker testbench FAILED");
        $finish;
    end

    initial begin
        #4_000_000;
        $fatal(1, "TIMEOUT -- packer stopped making progress (stuck flush?)");
    end

endmodule

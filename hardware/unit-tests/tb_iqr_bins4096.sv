`timescale 1ns / 1ps

import libstf::*;

/**
 * IQR_detection at NUM_BINS=4096 -- the functional gate for the 1024->4096 bin change.
 *
 * Runs the full core (histogram -> quartiles -> flags) at 4096 bins on a DETERMINISTIC dataset that
 * reproduces taxi_d3's fence-vs-cluster miss in miniature, and checks the flag column against the
 * known answer. Pinned quartiles (Q1~2000, Q3~8000 -> upper fence 15668) with a dense 300-row cluster
 * at 15670, one step past the fence, over a span of 13670 (bin_min 2000, bin_shift 2 -> bin width 4):
 *
 *   - At 4096 bins the fence stays at 15668, so all 300 cluster rows flag and NOTHING else does
 *     (verified offline against iqr_detection_test.py's reference model: exact == 4096 == 300).
 *   - At 1024 bins the SAME data needs bin_shift 4 (width 16); the coarse fence rounds ABOVE the
 *     cluster and flags 0 rows -- a 300-row undercount. So flip NUM_BINS to 1024 below and this TB
 *     FAILS (count 0, not 300): that is the red->green->revert check for the bin-count widening.
 *
 * Value path only (idx_mode = 0); the index outputs are left open. Standalone xsim, no coyote shell.
 */
module tb_iqr_bins4096;

    localparam int NUM_ELEMENTS = 8;
    localparam int NUM_BINS     = 4096;   // <-- flip to 1024 to see the test fail (revert check)
    localparam int CLK_HALF     = 2;
    localparam int MAX_N        = 1400;

    // Dataset geometry (see header).
    localparam longint BIN_MIN   = 2000;
    localparam longint SPAN      = 15670 - 2000;   // 13670: max value - bin_min
    localparam int     CLUSTER0  = 1000;  // first index of the 15670 cluster
    localparam int     N_TOTAL   = 1300;
    localparam int     N_EXPECT  = 300;   // outliers, all in [CLUSTER0, N_TOTAL)

    // The host sizes the window as the CPU/host derive_window does: bin width = ceil(span/NUM_BINS)
    // rounded up to a power of two, so bin_shift is COUPLED to the bin count. 4096 -> width 4, shift 2
    // (fence stays at the cluster); 1024 -> width 16, shift 4 (coarse fence rounds ABOVE the cluster,
    // 0 outliers). Deriving it here is what makes the revert-to-1024 check faithful.
    function automatic int derive_shift(input int nbins);
        automatic int width = int'((SPAN + nbins - 1) / nbins);   // ceil(span/nbins)
        automatic int s     = 0;
        while ((1 << s) < width) s++;                             // ceil(log2 width)
        return s;
    endfunction
    localparam int BIN_SHIFT = derive_shift(NUM_BINS);

    logic clk = 1'b0, rst_n = 1'b0;
    always #CLK_HALF clk = ~clk;

    logic [63:0] bin_min;
    logic [6:0]  bin_shift;
    logic        is_signed;
    logic        clear_pulse;
    logic [63:0] expected;

    ndata_i #(data64_t, NUM_ELEMENTS) iqr_in   (.clk(clk), .rst_n(rst_n));
    ndata_i #(data64_t, NUM_ELEMENTS) flag_out (.clk(clk), .rst_n(rst_n));

    data64_t     dbg_total, dbg_clear_seq;
    logic [63:0] dbg_accepted, dbg_committed, dbg_flushes, dbg_collisions;
    logic        hist_active;

    // Index-mode outputs unused in value mode; left open / tied.
    logic [NUM_ELEMENTS*64-1:0] idx_data;
    logic                       idx_valid, idx_last;
    logic [63:0]                idx_beats;
    localparam int FLAGW_LANES = (NUM_ELEMENTS*64) / 16;
    logic [FLAGW_LANES-1:0]     flagw_data, flagw_keep;
    logic                       flagw_valid, flagw_last;

    IQR_detection #(
        .value_t(data64_t), .NUM_ELEMENTS(NUM_ELEMENTS),
        .NUM_BINS(NUM_BINS), .COUNT_WIDTH(32)
    ) core (
        .clk(clk), .rst_n(rst_n),
        .bin_min(bin_min), .bin_shift(bin_shift[$clog2(65)-1:0]), .is_signed(is_signed),
        .clear_req(clear_pulse),
        .dbg_total(dbg_total), .dbg_clear_seq(dbg_clear_seq),
        .dbg_accepted(dbg_accepted), .dbg_committed(dbg_committed),
        .dbg_flushes(dbg_flushes), .dbg_collisions(dbg_collisions),
        .o_hist_active(hist_active),
        .i_idx_mode(1'b0), .i_expected(expected),
        .o_idx_data(idx_data), .o_idx_valid(idx_valid), .i_idx_ready(1'b1),
        .o_idx_last(idx_last), .o_idx_beats(idx_beats),
        .o_flagw_data(flagw_data), .o_flagw_keep(flagw_keep), .o_flagw_valid(flagw_valid),
        .i_flagw_ready(1'b1), .o_flagw_last(flagw_last),
        .in(iqr_in), .out(flag_out)
    );

    // Irregular back-pressure on the flag output so the core cannot get a free ride.
    logic [15:0] lfsr = 16'h7A5C;
    always_ff @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    assign flag_out.ready = rst_n && (lfsr[2:0] != 3'd0);

    // Capture one flag per element as it streams out (value mode: 8-wide on flag_out).
    bit flags_got [MAX_N];
    int n_flags;
    always_ff @(posedge clk) begin
        if (rst_n && flag_out.valid && flag_out.ready) begin
            for (int j = 0; j < NUM_ELEMENTS; j++) begin
                if (flag_out.keep[j]) begin
                    if (n_flags < MAX_N) flags_got[n_flags] = flag_out.data[j][0];
                    n_flags++;
                end
            end
        end
    end

    longint col [MAX_N];
    int     n_elems;
    int     errors = 0;

    task automatic drive_beats();
        automatic bit taken;
        automatic int nb = (n_elems + NUM_ELEMENTS - 1) / NUM_ELEMENTS;
        for (int b = 0; b < nb; b++) begin
            @(negedge clk);
            for (int e = 0; e < NUM_ELEMENTS; e++) begin
                automatic int i = b*NUM_ELEMENTS + e;
                iqr_in.data[e] = (i < n_elems) ? data64_t'(col[i]) : '0;
                iqr_in.keep[e] = (i < n_elems);
            end
            iqr_in.last  = ((b + 1) * NUM_ELEMENTS >= n_elems);
            iqr_in.valid = 1'b1;
            taken = 1'b0;
            while (!taken) begin
                taken = iqr_in.ready;
                @(posedge clk); @(negedge clk);
            end
            iqr_in.valid = 1'b0;
            iqr_in.last  = 1'b0;
        end
    endtask

    task automatic run_two_pass();
        automatic int guard;
        rst_n = 1'b0;
        iqr_in.valid = 1'b0; iqr_in.last = 1'b0; iqr_in.data = '0; iqr_in.keep = '0;
        clear_pulse = 1'b0; n_flags = 0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        expected = 64'(n_elems);
        @(negedge clk); clear_pulse = 1'b1;
        @(negedge clk); clear_pulse = 1'b0;
        guard = 0;
        while (dbg_clear_seq == 0 && guard < 40000) begin @(posedge clk); guard++; end

        drive_beats();                                   // pass 1: HISTOGRAM
        guard = 0;
        while (hist_active && guard < 80000) begin @(posedge clk); guard++; end
        repeat (2*NUM_BINS + 128) @(posedge clk);        // let QUARTILES finish (scans NUM_BINS bins)

        drive_beats();                                   // pass 2: FLAG
        repeat (1200) @(posedge clk);
    endtask

    int idx;
    int n_set, n_set_in_cluster, n_set_before_cluster;
    initial begin
        // Build the deterministic column: [2000]x250, ramp 2000..7988 step 12 (500), [8000]x250,
        // [15670]x300.  Total 1300; the 300 cluster values are the only outliers.
        idx = 0;
        for (int i = 0; i < 250; i++) col[idx++] = 2000;
        for (longint v = 2000; v < 8000; v += 12) col[idx++] = v;
        for (int i = 0; i < 250; i++) col[idx++] = 8000;
        for (int i = 0; i < 300; i++) col[idx++] = 15670;
        n_elems = idx;

        bin_min   = BIN_MIN[63:0];
        bin_shift = BIN_SHIFT[6:0];
        is_signed = 1'b0;

        $display("=== IQR_detection bins=%0d functional test (N=%0d, bin_min=%0d, shift=%0d) ===",
                 NUM_BINS, n_elems, BIN_MIN, BIN_SHIFT);

        if (n_elems != N_TOTAL) begin $error("dataset build wrong: N=%0d", n_elems); errors++; end

        run_two_pass();

        if (n_flags != n_elems) begin
            $error("emitted %0d flags, expected %0d", n_flags, n_elems); errors++;
        end
        if (dbg_total !== data64_t'(n_elems)) begin
            $error("dbg_total=%0d, expected %0d (histogram lost counts)", dbg_total, n_elems); errors++;
        end

        n_set = 0; n_set_in_cluster = 0; n_set_before_cluster = 0;
        for (int i = 0; i < n_elems; i++) begin
            if (flags_got[i]) begin
                n_set++;
                if (i >= CLUSTER0) n_set_in_cluster++; else n_set_before_cluster++;
            end
        end

        // The known answer: exactly N_EXPECT outliers, ALL in the cluster, NONE before it.
        if (n_set != N_EXPECT) begin
            $error("outlier count = %0d, expected %0d (1024-bin coarse fence would give 0)",
                   n_set, N_EXPECT); errors++;
        end
        if (n_set_before_cluster != 0) begin
            $error("%0d outliers flagged BEFORE the cluster (should be 0)", n_set_before_cluster);
            errors++;
        end
        if (n_set_in_cluster != N_EXPECT) begin
            $error("%0d of %0d cluster rows flagged (should be all)", n_set_in_cluster, N_EXPECT);
            errors++;
        end

        $display("  bins=%0d  N=%0d  outliers=%0d (in-cluster=%0d, before=%0d)  %s",
                 NUM_BINS, n_elems, n_set, n_set_in_cluster, n_set_before_cluster,
                 (errors == 0) ? "PASS (4096 resolves the fence cluster)" : "*** FAIL ***");
        $display("=== %s (%0d error%s) ===",
                 (errors == 0) ? "ALL CLEAN" : "FAILURES", errors, (errors == 1) ? "" : "s");
        if (errors != 0) $fatal(1, "bins=%0d functional test FAILED", NUM_BINS);
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "TIMEOUT -- core stalled");
    end

endmodule

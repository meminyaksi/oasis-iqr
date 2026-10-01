`timescale 1ns / 1ps

`include "libstf_macros.svh"

// Uncomment to build the count-loss ILAs (ila_iqr = all-8-bank scan/readback+total; ila_iqr_rmw
// = all-8-bank BRAM read-modify-write path + wdata_dbg, to watch the drain-commit loss live). From
// hardware/src/init_ip.tcl and the probe widths there to match (BIN_IDX_WIDTH / COUNT_WIDTH).
// Leave commented for production bitstreams -- the host-readable counters below need no ILA.
// `define IQR_DEBUG_ILA   // ILAs OFF for the lean production bitstream (re-enable to debug)

module IQR_detection #(
    parameter type value_t,
    parameter      NUM_ELEMENTS,
    parameter      NUM_BINS    = 16,         // generic bin count
    parameter      COUNT_WIDTH = 32,         // width of each bin counter
    // Compile-time index-mode (step-2 packed-index pass 2) enable. DEFAULT OFF. Index mode was
    // retired to reclaim timing: its IqrIndexPack 512-bit packer was the `idx_pack` critical-path
    // cluster (WNS). With EN_INDEX=0 the IqrIndex* instances below are NOT generated and every
    // i_idx_mode branch folds to the value path, so the synthesized design is value-only. The
    // i_idx_mode/i_expected/o_idx_*/o_flagw_* ports are retained (CSR + host unchanged) but ignored.
    parameter bit  EN_INDEX    = 1'b0
) (
    input logic clk,
    input logic rst_n,

    // Runtime configuration, driven from host CSRs (held stable for a run):
    //   bin_min   : window low edge (interpreted signed when is_signed)
    //   bin_shift : bin width = 2**bin_shift
    //   is_signed : treat input values as signed (sign-aware binning + fences)
    input logic [$bits(value_t) - 1:0]            bin_min,
    input logic [$clog2($bits(value_t) + 1) - 1:0] bin_shift,
    input logic                                   is_signed,

    // Host-pulsed clear: forces a full histogram zero-sweep before the next pass-1, so
    // every run starts clean regardless of how the previous run terminated. Coyote does
    // not reset the user logic between host processes, and the end-of-run self-clear is
    // not guaranteed to take effect across that boundary -- this pulse recovers it.
    input logic                                   clear_req,

    // Debug: grand total of the histogram for the last scanned dataset (== element count
    // iff the banks were properly zeroed). The host reads it to confirm no cross-run residue.
    output logic [$bits(value_t) - 1:0]           dbg_total,

    // Clear-completion sequence: increments by 1 every time a clear_req-initiated zero-sweep
    // FINISHES (not the reset/end-of-run self-clears). The host captures it, pulses clear_req,
    // then polls until it advances -- a race-free fence so the posted clear write is guaranteed
    // applied (banks zeroed, core idle-ready) before pass-1 data is allowed to stream in.
    output logic [$bits(value_t) - 1:0]           dbg_clear_seq,

    // -- Count-loss diagnostics (read back via the IQR CSR block; reset on clear_req each run) ---
    // The host knows N (values streamed in pass-1) and compares the chain
    //     N  >=  dbg_accepted  >=  dbg_committed  >=  dbg_total
    // to localize WHERE pass-1 counts are lost on silicon (sim is hazard-free, so loss hides):
    //   accepted  < N         -> loss at the input handshake / DMA (before binning)
    //   committed < accepted  -> loss in the coalescing accumulator (runs not fully carried)
    //   total     < committed -> loss in the BRAM read-modify-write (the read-after-write hazard)
    // dbg_collisions counts flush-reads that hit a just-written bin -- direct hazard evidence;
    // dbg_flushes is the BRAM write count (texture for how much coalescing happened).
    output logic [63:0]                           dbg_accepted,
    output logic [63:0]                           dbg_committed,
    output logic [63:0]                           dbg_flushes,
    output logic [63:0]                           dbg_collisions,

    // Which pass the core is currently consuming input for. The two passes read the SAME `in`
    // port sequentially, so a top that sources them differently -- pass 1 fused with the decoder
    // output on-chip, pass 2 re-streamed from host memory -- needs to know which to select.
    // High in HISTOGRAM (pass 1), low in QUARTILES/FLAG. Combinational off `state`.
    output logic                                  o_hist_active,

    // -- Step 2: bin-index pass 2 (see hardware/src/hdl/iqr_index.sv) ---------------------------
    // When i_idx_mode is high, HISTOGRAM additionally emits a packed 16-bit-per-element index
    // stream on o_idx_*, and FLAG expects that stream back on `in` (32 indices per 512-bit beat)
    // instead of the raw 64-bit values -- 4x less pass-2 PCIe traffic at bit-identical results.
    // i_expected is the column's element count; the index array is padded to a whole beat and the
    // tail is masked against it, so no in-band length is needed.
    input  logic                                  i_idx_mode,
    input  logic [63:0]                           i_expected,

    output logic [$bits(value_t)*NUM_ELEMENTS-1:0] o_idx_data,
    output logic                                  o_idx_valid,
    input  logic                                  i_idx_ready,
    output logic                                  o_idx_last,
    // Index beats emitted this column, for the host to poll before draining the transfer.
    output logic [63:0]                           o_idx_beats,

    // -- Step-2 WIDE flag output (index mode only) ---------------------------------------------
    // In index mode, pass 2 compares all 32 indices of a beat in one cycle and emits their outlier
    // bits here, 32 lanes wide, instead of dribbling 8 per cycle onto the value `out`. vFPGA top
    // packs them with IqrWideFlagPack (32 bits/beat). This is the step-2 speedup: ~4x the flag
    // throughput, so pass 2 finally runs faster and not just with less traffic (RESULTS.md 9.21).
    // Idle when i_idx_mode is low (the value path uses `out`).
    // Lane count = beat bits / IDX_BITS = 512/32 = 16 (IDX_BITS is a localparam declared below, so
    // the wire-format 32 is written literally here).
    output logic [$bits(value_t)*NUM_ELEMENTS/32 - 1:0] o_flagw_data,
    output logic [$bits(value_t)*NUM_ELEMENTS/32 - 1:0] o_flagw_keep,
    output logic                                  o_flagw_valid,
    input  logic                                  i_flagw_ready,
    output logic                                  o_flagw_last,

    ndata_i.s in,   // #(value_t, NUM_ELEMENTS) input values
    ndata_i.m out   // #(value_t, NUM_ELEMENTS) results (driven later)
);

`RESET_RESYNC // Reset pipelining

    localparam int VALUE_WIDTH   = $bits(value_t);
    localparam int BIN_IDX_WIDTH = (NUM_BINS > 1) ? $clog2(NUM_BINS) : 1;

    // Step 2 wire format, fixed by hardware/src/hdl/iqr_index.sv: IDX_BITS bits per element =
    // a signed half-bin index (IDX_W bits) + an `exact` bit, the rest reserved. FIDX_W is the wider
    // space the fences live in.
    //
    // RE-WIDENED FOR 4096 BINS (build-24). TRAP 2 in iqr_index.sv bounds the reachable fence index at
    // ~5*(NUM_BINS-1): +5115 at 1024 bins (fit IDX_W=14, +-8191), but ~+20475 at 4096 bins -- which a
    // 14-bit index would SATURATE, silently missing far outliers. IDX_W=16 (+-32768) covers +20475 with
    // margin, so saturation stays safe (a saturated data index is still beyond every reachable fence).
    // IDX_W=16 + the exact bit no longer fits a 16-bit slot, so IDX_BITS goes to 32 (the next
    // beat-aligned width): 512/32 = 16 indices/beat, i.e. pass 2 moves 2x fewer beats than the value
    // path instead of 4x -- still a win. The three former /16 sites moved to /32 with it: o_flagw_data/
    // o_flagw_keep below, IQR_FLAGW_LANES in vfpga_top.svh, and host IDX_PER_BEAT in iqr_runner.cpp.
    // The host guard (IqrRunner::enable_index_pass2) now permits up to 4096 bins.
    localparam int IDX_BITS = 32;
    localparam int IDX_W    = 16;
    localparam int FIDX_W   = 20;

    // Step-2 wide flag consumer signals (instance further below). Declared here because the FLAG-state
    // FSM references idxf_valid/idxf_last for its index-mode exit.
    localparam int IDXF_LANES = (VALUE_WIDTH*NUM_ELEMENTS) / IDX_BITS;   // 512/32 = 16
    logic                     idxf_in_valid, idxf_in_ready;
    logic [IDXF_LANES - 1:0]  idxf_flags, idxf_keep;
    logic                     idxf_valid, idxf_last;

    typedef enum logic [1:0] {
        HISTOGRAM,
        QUARTILES,
        FLAG
    } state_t;

    state_t state;

    // Pass selector for a fused top (see the port comment).
    assign o_hist_active = (state == HISTOGRAM);

    // Effective index-mode select: forced low (constant-folded) when EN_INDEX=0, so the whole index
    // datapath below is trimmed and the value path is bit-identical to a no-index build. All the
    // former `i_idx_mode` uses reference this instead.
    wire idx_mode = EN_INDEX ? i_idx_mode : 1'b0;

    // Quartile search status
    logic q1_found;
    logic q3_found;

    // -- Quartile scan state --------------------------------------------------
    // The histogram lives spread across NUM_ELEMENTS banks. The quartile scan
    // sweeps the bins, summing the banks per bin (the deferred merge), in two
    // passes: Q_SUM computes the grand total, Q_SCAN walks the cumulative count
    // to locate Q1 (25%) and Q3 (75%).
    logic [COUNT_WIDTH - 1:0]  bank_q [NUM_ELEMENTS];   // per-bank read data (exposed by g_bank)

    // -- Count-loss diagnostics: per-bank accumulators, summed into the CSR debug regs below ----
    logic [63:0] bank_accepted   [NUM_ELEMENTS];   // # values this bank saw at the input (beats)
    logic [63:0] bank_committed  [NUM_ELEMENTS];   // Σ delta each bank intended to write to BRAM
    logic [63:0] bank_flushes    [NUM_ELEMENTS];   // # BRAM writes (flushes) per bank
    logic [63:0] bank_collisions [NUM_ELEMENTS];   // # flush-reads that hit a just-written bin

    typedef enum logic {Q_SUM, Q_SCAN} q_phase_t;
    q_phase_t                   q_phase;
    logic [BIN_IDX_WIDTH:0]     scan_cnt;               // sweep counter, 0..NUM_BINS+1
    logic [BIN_IDX_WIDTH - 1:0] q_raddr;                // bank read address during QUARTILES
    assign q_raddr = scan_cnt[BIN_IDX_WIDTH - 1:0];

    logic [COUNT_WIDTH - 1:0]   total;                  // total element count (sum of all bins)
    logic [COUNT_WIDTH - 1:0]   cumulative;             // running cumulative during Q_SCAN

    assign dbg_total = ($bits(value_t))'(total);        // debug readback (zero-extended)

    logic [BIN_IDX_WIDTH - 1:0] q1_bin, q3_bin;         // bins where Q1 / Q3 land
    logic [VALUE_WIDTH - 1:0]   q1_val, q3_val;         // their representative values
    logic signed [VALUE_WIDTH + 2:0] iqr_val;           // Q3 - Q1
    logic signed [VALUE_WIDTH + 2:0] lower_fence;       // Q1 - 1.5*IQR
    logic signed [VALUE_WIDTH + 2:0] upper_fence;       // Q3 + 1.5*IQR

    // Step 2: the same fences in half-bin index space, registered once per column (fence_step 4).
    logic signed [FIDX_W - 1:0] lo_fidx_c, hi_fidx_c;   // combinational from the registered fences
    logic signed [FIDX_W - 1:0] lo_fidx_r, hi_fidx_r;   // what FLAG compares against

    // Pipelined fence computation: the once-per-dataset fence math (wide variable shift +
    // signed adds) was a single-cycle cloud that failed setup (upper_fence_i*/lower_fence_reg).
    // Spread it over 4 registered steps; runs once per dataset so the extra cycles are free.
    logic [2:0]                      fence_step;
    logic [VALUE_WIDTH - 1:0]        q1v_r, q3v_r;
    logic signed [VALUE_WIDTH + 2:0] q1e_r, q3e_r, iqrv_r;

    // -- BRAM clear sweep -----------------------------------------------------
    // A BRAM cannot be wiped in one cycle, so on entering HISTOGRAM we walk
    // address 0..NUM_BINS-1 writing zero to every bank before accepting data.
    // Also reused to re-clear the banks between datasets (FLAG -> HISTOGRAM).
    logic                       clearing;
    logic [BIN_IDX_WIDTH - 1:0] clear_addr;

    // Host clear-completion handshake: clear_req_pending marks that the *current* sweep was
    // started by a host clear_req; clear_seq is bumped once that sweep finishes so the host can
    // observe its specific clear completed (immune to the posted write-FIFO and to missing the
    // ~1us sweep). Reset/end-of-run self-clears leave clear_req_pending low and do not bump it.
    logic                       clear_req_pending;
    logic [31:0]                clear_seq;
    assign dbg_clear_seq = ($bits(value_t))'(clear_seq);

    // -- Per-lane bin index: two-stage pipeline (timing) ----------------------
    // The bin index is a long combinational cloud once bin_min/bin_shift/is_signed
    // are runtime CSRs: a signed subtract (value - bin_min) FOLLOWED BY a *variable*
    // barrel shift (>> bin_shift) and the saturate compare. Driving the histogram
    // BRAM address off that whole cloud in a single cycle is the marginal path that
    // mis-bins values on silicon when bin_shift > 0 -- functionally correct in sim
    // (proven bit-exact), but it fails setup post-route, scattering counts into wrong
    // bins and grossly shifting the quartiles (the "wide" example: ~248 flag misses,
    // while bin_shift = 0 distributions, whose shift is trivial, pass). Split the
    // cloud into TWO registered stages so the subtract and the variable shift occupy
    // separate clock cycles:
    //   stage A : diff = value - bin_min   (+ below-window flag)        -> *_q1
    //   stage B : shifted = diff >> bin_shift, then saturate to a bin   -> lane_idx_q
    // bin_min/bin_shift/is_signed are held stable for the whole run, so they need no
    // pipelining. This adds ONE more cycle between input accept and the increment
    // commit (beat -> commit is now 4 cycles), so the HISTOGRAM drain waits one extra
    // cycle (drain_cnt = 4 instead of 3). Out-of-window values clamp into the edge
    // bins (Q1/Q3 are central, so edge pile-up does not perturb them).

    // A beat is accepted at the input on this cycle (it is binned three cycles later,
    // after the two-stage bin-index pipeline below).
    logic accept;
    assign accept = (state == HISTOGRAM) && !clearing && in.valid && in.ready;

    // -- Stage A (comb): signed/unsigned subtract + below-window flag ---------
    logic                        below_a [NUM_ELEMENTS];
    logic signed [VALUE_WIDTH:0] diff_a  [NUM_ELEMENTS];   // value - bin_min, one extra bit
    always_comb begin
        for (int i = 0; i < NUM_ELEMENTS; i++) begin
            // Compare/subtract in the configured signedness. Unsigned: zero-extend;
            // signed: sign-extend. When !below the value is >= bin_min, so diff >= 0.
            if (is_signed) begin
                below_a[i] = $signed(in.data[i]) < $signed(bin_min);
                diff_a[i]  = $signed({in.data[i][VALUE_WIDTH-1], in.data[i]})
                           - $signed({bin_min[VALUE_WIDTH-1], bin_min});
            end else begin
                below_a[i] = in.data[i] < bin_min;
                diff_a[i]  = $signed({1'b0, in.data[i]}) - $signed({1'b0, bin_min});
            end
        end
    end

    // -- Step 2: encode each lane's half-bin index off the SAME beat the histogram bins -----------
    // Combinational, in parallel with stage A. The pack module registers, so this adds no stage to
    // the histogram path. The index is NOT the histogram's bin index: that one saturates into
    // [0, NUM_BINS-1], which would collapse every below-window value onto bin 0 and lose the
    // information the fence compare needs.
    logic [NUM_ELEMENTS*IDX_BITS - 1:0] idx_packed_in;
    if (EN_INDEX) begin : g_idx_enc
        for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : g_lane
            logic signed [IDX_W - 1:0] e_idx;
            logic                      e_exact;
            IqrIndexEncode #(.VALUE_WIDTH(VALUE_WIDTH), .IDX_W(IDX_W)) inst_enc (
                .i_value(in.data[I]), .i_bin_min(bin_min), .i_bin_shift(bin_shift),
                .i_is_signed(is_signed), .o_idx(e_idx), .o_exact(e_exact)
            );
            assign idx_packed_in[I*IDX_BITS +: IDX_BITS] =
                {{(IDX_BITS - IDX_W - 1){1'b0}}, e_exact, e_idx};
        end
        IqrFenceIndex #(
            .VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(VALUE_WIDTH + 3), .FIDX_W(FIDX_W)
        ) inst_lo_fidx (
            .i_fence(lower_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift),
            .i_is_signed(is_signed), .o_fidx(lo_fidx_c)
        );
        IqrFenceIndex #(
            .VALUE_WIDTH(VALUE_WIDTH), .FENCE_WIDTH(VALUE_WIDTH + 3), .FIDX_W(FIDX_W)
        ) inst_hi_fidx (
            .i_fence(upper_fence), .i_bin_min(bin_min), .i_bin_shift(bin_shift),
            .i_is_signed(is_signed), .o_fidx(hi_fidx_c)
        );
    end else begin : g_no_idx_enc
        // Index mode compiled out: park the encoder/fence outputs so nothing downstream is undriven.
        assign idx_packed_in = '0;
        assign lo_fidx_c     = '0;
        assign hi_fidx_c     = '0;
    end

    logic idx_pack_ready;   // instance is below, next to last_seen

    // -- Stage A register -----------------------------------------------------
    logic                        below_q1 [NUM_ELEMENTS];
    logic signed [VALUE_WIDTH:0] diff_q1  [NUM_ELEMENTS];
    logic                        accept_q1;
    logic [NUM_ELEMENTS - 1:0]   keep_q1;
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            accept_q1 <= 1'b0;
        end else begin
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                below_q1[i] <= below_a[i];
                diff_q1[i]  <= diff_a[i];
                keep_q1[i]  <= in.keep[i];
            end
            accept_q1 <= accept;
        end
    end

    // -- Stage B (comb): variable barrel shift + saturate to bin index --------
    logic [BIN_IDX_WIDTH - 1:0] lane_idx_b [NUM_ELEMENTS];
    always_comb begin
        logic [VALUE_WIDTH:0] shifted;
        for (int i = 0; i < NUM_ELEMENTS; i++) begin
            if (below_q1[i]) begin
                lane_idx_b[i] = '0;                                  // saturate low
            end else begin
                shifted = $unsigned(diff_q1[i]) >> bin_shift;        // diff >= 0 here
                if (shifted >= NUM_BINS)
                    lane_idx_b[i] = BIN_IDX_WIDTH'(NUM_BINS - 1);    // saturate high
                else
                    lane_idx_b[i] = shifted[BIN_IDX_WIDTH - 1:0];
            end
        end
    end

    // -- Stage B register (feeds the histogram BRAM address in g_bank) --------
    logic [BIN_IDX_WIDTH - 1:0] lane_idx_q [NUM_ELEMENTS];
    logic                       accept_q;
    logic [NUM_ELEMENTS - 1:0]  keep_q;
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            accept_q <= 1'b0;
        end else begin
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                lane_idx_q[i] <= lane_idx_b[i];
                keep_q[i]     <= keep_q1[i];
            end
            accept_q <= accept_q1;
        end
    end

    // -- Banked histogram store: collision-free via run coalescing -------------
    // The earlier version read-modified-wrote the BRAM for EVERY value. Two
    // consecutive values in the same bin then read AND wrote the same address in
    // one cycle -- a BRAM read/write collision that drops counts on silicon
    // (invisible to zero-delay sim, ~10% wandering loss), and it leaned on a
    // same-cycle forwarding bypass whose registers sat at marginal hold (+0.021 ns).
    //
    // Here each bank keeps the CURRENT bin's running count in registers (acc_*),
    // and the BRAM is touched only when the bin CHANGES (a "flush"): mem[bin]+=delta.
    // Because we only flush on a change, two consecutive flushes are ALWAYS different
    // bins, so every BRAM read that actually feeds a flush is collision-free (the
    // simultaneous write is the PREVIOUS flush -- a different bin), a repeated bin is
    // >=2 flushes apart (its earlier write has committed), and NO forwarding is needed
    // (so the +0.021 ns hold path is gone). flush_final (driven by the FSM drain)
    // pushes every bank's last run into the BRAM before the quartile scan reads it.
    logic flush_final;   // FSM pulse: commit each bank's pending run at end of pass-1
    for (genvar K = 0; K < NUM_ELEMENTS; K++) begin : g_bank
        // Force DISTRIBUTED LUTRAM (not BRAM). Root-caused on silicon (build-06, 2026-06-30):
        // with ram_style="block" Vivado split the 8 banks into 4 LUTRAM (banks 0-3) + 4 true-dual-
        // port RAMB36 (banks 4-7). The LUTRAM banks had ZERO count-loss in every test; the BRAM
        // banks lost ~9% of writes (per-write, proportional, wandering, collisions=0, STA-clean) to
        // the synchronous-read read-during-write collision that STA can't see. LUTRAM's async read
        // reads the current value every cycle, so the RMW has no read-latency hazard -> correct.
        // Forcing all 8 banks to LUTRAM makes every bank behave like the proven-good 0-3.
        (* ram_style = "distributed" *)
        logic [COUNT_WIDTH - 1:0]   mem [NUM_BINS];   // histogram bank (distributed LUTRAM)
        logic [COUNT_WIDTH - 1:0]   rd_q;             // registered read data

        // Coalescing accumulator: the run currently being counted for this bank.
        logic [BIN_IDX_WIDTH - 1:0] acc_bin;
        logic [COUNT_WIDTH - 1:0]   acc_cnt;
        logic                       acc_valid = 1'b0; // power-up empty (no reset block -> BRAM)

        // Flush request (coalescing -> RMW pipeline register): add fl_delta to mem[fl_bin].
        logic                       fl_we = 1'b0;
        logic [BIN_IDX_WIDTH - 1:0] fl_bin;
        logic [COUNT_WIDTH - 1:0]   fl_delta;

        // RMW stage-1 (commit) registers.
        logic                       s1_we = 1'b0;
        logic [BIN_IDX_WIDTH - 1:0] s1_bin;
        logic [COUNT_WIDTH - 1:0]   s1_delta;

`ifdef IQR_DEBUG_ILA
        // DEBUG: the literal value driven onto the BRAM DI pin on a commit, `rd_q + s1_delta` -- the
        // exact net the setup-violation hypothesis is about. Probed by ila_iqr_rmw. If this 32-bit
        // add violates setup into the BRAM, this value (as the ILA samples it) will DISAGREE with
        // what the quartile scan later reads back from mem[s1_bin] (bank_q during QUARTILES): the
        // adder computed the right number, but the BRAM latched a corrupted one.
        logic [COUNT_WIDTH - 1:0]   wdata_dbg;
        assign wdata_dbg = rd_q + s1_delta;
`endif

`ifdef IQR_BRAM_RAW_HAZARD_SIM
        // -- SIM-ONLY: model the silicon BRAM read-after-write hazard ----------------
        // Behavioural sim makes a write to mem[B] visible to a read of B on the very next
        // cycle, so it HIDES the hardware count-loss. Real registered BRAM does not: a read up
        // to HAZ_DEPTH cycles after the write returns the STALE (pre-write) value. The define's
        // VALUE sets the depth, so the test can sweep it to match the measured hardware loss
        // (1 ~= 5%, 2 ~= ~10%). Guarded -> NEVER in synthesis (the `else branch is the real RTL).
        localparam int              HAZ_DEPTH = `IQR_BRAM_RAW_HAZARD_SIM;
        logic                       haz_v [HAZ_DEPTH];   // recent-write valid (newest at [0])
        logic [BIN_IDX_WIDTH - 1:0] haz_b [HAZ_DEPTH];   // recent-write bin
        logic [COUNT_WIDTH - 1:0]   haz_s [HAZ_DEPTH];   // bin value BEFORE that write
        initial for (int j = 0; j < HAZ_DEPTH; j++) haz_v[j] = 1'b0;
`endif

        // Expose this bank's read data so the quartile scan can merge the banks.
        assign bank_q[K] = rd_q;

        logic beat;
        assign beat = accept_q && keep_q[K];   // a value for this bank this cycle

        // BRAM read address. In HISTOGRAM we read the bin being flushed (fl_bin) so
        // the RMW has its old value; when there is no flush the read is unused, so we
        // park it OFF the write address (~s1_bin) -- this guarantees the read never
        // shares an address with the write even on the unused cycles. In QUARTILES
        // every bank reads the shared scan address so the merge can sum them.
        logic [BIN_IDX_WIDTH - 1:0] raddr;
        assign raddr = (state == HISTOGRAM) ? (fl_we ? fl_bin : ~s1_bin) : q_raddr;

        // NOTE: memory read/write kept OUTSIDE any reset-conditional (Vivado refuses
        // ram_style=block otherwise, Synth 8-6849). No reset needed: acc_valid/fl_we/
        // s1_we power up 0, and the CLEAR phase (write priority) zeroes every bin
        // before any accumulation.
        always_ff @(posedge clk) begin
            // -- Coalescing front-end: accumulate same-bin runs, flush on change --
            fl_we <= 1'b0;                            // default: no flush this cycle
            if (clearing) begin
                acc_valid <= 1'b0;                    // banks being zeroed -> drop accumulation
            end else if (flush_final) begin
                // End of pass-1: push this bank's final run into the BRAM.
                fl_we     <= acc_valid;
                fl_bin    <= acc_bin;
                fl_delta  <= acc_cnt;
                acc_valid <= 1'b0;
            end else if (beat) begin
                if (acc_valid && (lane_idx_q[K] == acc_bin)) begin
                    acc_cnt <= acc_cnt + COUNT_WIDTH'(1'b1);   // same bin: register-only, no BRAM
                end else begin
                    fl_we     <= acc_valid;                    // bin changed: flush the old run
                    fl_bin    <= acc_bin;
                    fl_delta  <= acc_cnt;
                    acc_bin   <= lane_idx_q[K];                // and start a new one
                    acc_cnt   <= COUNT_WIDTH'(1'b1);
                    acc_valid <= 1'b1;
                end
            end

            // -- RMW: stage 0 read mem[fl_bin], stage 1 write mem[fl_bin] + delta --
`ifdef IQR_BRAM_RAW_HAZARD_SIM
            begin : haz_rd
                automatic logic                     hit = 1'b0;
                automatic logic [COUNT_WIDTH - 1:0] val = '0;
                // A bin read within HAZ_DEPTH cycles of its write sees the stale value -> its
                // increment is overwritten and lost, exactly like the silicon leak.
                for (int j = 0; j < HAZ_DEPTH; j++)
                    if (haz_v[j] && (raddr == haz_b[j])) begin hit = 1'b1; val = haz_s[j]; end
                rd_q <= hit ? val : mem[raddr];
            end
            // shift the recent-write history (capture pre-write value of this cycle's write)
            haz_v[0] <= s1_we && !clearing;
            haz_b[0] <= s1_bin;
            haz_s[0] <= mem[s1_bin];
            for (int j = 1; j < HAZ_DEPTH; j++) begin
                haz_v[j] <= haz_v[j-1];
                haz_b[j] <= haz_b[j-1];
                haz_s[j] <= haz_s[j-1];
            end
`else
            rd_q     <= mem[raddr];
`endif
            s1_we    <= fl_we;
            s1_bin   <= fl_bin;
            s1_delta <= fl_delta;

            if (clearing)
                mem[clear_addr] <= '0;
            else if (s1_we)
                mem[s1_bin] <= rd_q + s1_delta;
        end

        // -- Count-loss diagnostics for this bank (pure observation, NOT in the datapath) ----
        // Track the last DIAG_HAZ committed write bins. A flush that READS a bin written within
        // that window gets the stale (pre-write) value on real BRAM -> its add overwrites the
        // recent write and a count is lost. hazard_hit flags exactly that read.
        localparam int DIAG_HAZ = 2;
        logic                       w_hist_v [DIAG_HAZ];
        logic [BIN_IDX_WIDTH - 1:0] w_hist_b [DIAG_HAZ];
        logic                       hazard_hit;
        always_comb begin
            hazard_hit = 1'b0;
            if (fl_we)
                for (int j = 0; j < DIAG_HAZ; j++)
                    if (w_hist_v[j] && (fl_bin == w_hist_b[j])) hazard_hit = 1'b1;
        end

        logic [63:0] diag_accepted;    // # values this bank saw at the input (a beat per value)
        logic [63:0] diag_committed;   // Σ delta this bank intended to write into its BRAM
        logic [63:0] diag_flushes;     // # BRAM writes (flushes) for this bank
        logic [63:0] diag_collisions;  // # flush-reads that hit a just-written bin (hazard)
        always_ff @(posedge clk) begin
            if (reset_synced == 1'b0) begin
                for (int j = 0; j < DIAG_HAZ; j++) w_hist_v[j] <= 1'b0;
                diag_accepted   <= '0;
                diag_committed  <= '0;
                diag_flushes    <= '0;
                diag_collisions <= '0;
            end else begin
                // Shift recent-write history (this cycle's BRAM write is s1_we -> mem[s1_bin]).
                w_hist_v[0] <= s1_we && !clearing;
                w_hist_b[0] <= s1_bin;
                for (int j = 1; j < DIAG_HAZ; j++) begin
                    w_hist_v[j] <= w_hist_v[j-1];
                    w_hist_b[j] <= w_hist_b[j-1];
                end
                if (clear_req) begin               // host re-arms before each run -> per-run counts
                    diag_accepted   <= '0;
                    diag_committed  <= '0;
                    diag_flushes    <= '0;
                    diag_collisions <= '0;
                end else begin
                    if (beat) diag_accepted <= diag_accepted + 64'd1;   // value entered binning
                    if (s1_we && !clearing) begin
                        diag_committed <= diag_committed + 64'(s1_delta);
                        diag_flushes   <= diag_flushes   + 64'd1;
                    end
                    if (hazard_hit) diag_collisions <= diag_collisions + 64'd1;
                end
            end
        end
        assign bank_accepted[K]   = diag_accepted;
        assign bank_committed[K]  = diag_committed;
        assign bank_flushes[K]    = diag_flushes;
        assign bank_collisions[K] = diag_collisions;
    end

    // -- Count-loss diagnostics: sum the per-bank accumulators across all banks (read via CSR) ---
    // accepted/committed/flushes/collisions are each Σ over the NUM_ELEMENTS banks. accepted counts
    // input beats per bank (mirrors committed's structure so the two can only diverge on a real
    // coalescing drop, not a counting artifact).
    //
    // The reduction is PIPELINED into a registered 8->4->2->1 adder tree (mirrors the scan-merge
    // pipeline below). These four sums feed ONLY the host CSR readback (dbg_*), which is sampled
    // after a run finishes, so the 3-cycle latency is functionally invisible -- and it keeps the
    // physically-scattered per-bank diag counters off the long combinational route into the config
    // read register that was the build-27 critical path (WNS -1.496, 15 levels, 76% route). A plain
    // always_comb Σ pulls all 8 banks to one endpoint in a single cycle. (Assumes NUM_ELEMENTS == 8,
    // the production geometry -- same assumption as the scan pipeline below.)
    logic [63:0] acc_r1 [4], com_r1 [4], flu_r1 [4], col_r1 [4];   // stage 1: 8 banks -> 4 partials
    logic [63:0] acc_r2 [2], com_r2 [2], flu_r2 [2], col_r2 [2];   // stage 2: 4 -> 2
    logic [63:0] accepted_sum, committed_sum, flushes_sum, collisions_sum;  // stage 3: 2 -> 1
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            for (int i = 0; i < 4; i++) begin
                acc_r1[i] <= '0; com_r1[i] <= '0; flu_r1[i] <= '0; col_r1[i] <= '0;
            end
            for (int i = 0; i < 2; i++) begin
                acc_r2[i] <= '0; com_r2[i] <= '0; flu_r2[i] <= '0; col_r2[i] <= '0;
            end
            accepted_sum <= '0; committed_sum <= '0; flushes_sum <= '0; collisions_sum <= '0;
        end else begin
            for (int i = 0; i < 4; i++) begin   // stage 1: pair the 8 banks
                acc_r1[i] <= bank_accepted[2*i]   + bank_accepted[2*i + 1];
                com_r1[i] <= bank_committed[2*i]  + bank_committed[2*i + 1];
                flu_r1[i] <= bank_flushes[2*i]    + bank_flushes[2*i + 1];
                col_r1[i] <= bank_collisions[2*i] + bank_collisions[2*i + 1];
            end
            for (int i = 0; i < 2; i++) begin   // stage 2: pair the 4 partials
                acc_r2[i] <= acc_r1[2*i] + acc_r1[2*i + 1];
                com_r2[i] <= com_r1[2*i] + com_r1[2*i + 1];
                flu_r2[i] <= flu_r1[2*i] + flu_r1[2*i + 1];
                col_r2[i] <= col_r1[2*i] + col_r1[2*i + 1];
            end
            accepted_sum   <= acc_r2[0] + acc_r2[1];   // stage 3: final Σ
            committed_sum  <= com_r2[0] + com_r2[1];
            flushes_sum    <= flu_r2[0] + flu_r2[1];
            collisions_sum <= col_r2[0] + col_r2[1];
        end
    end
    assign dbg_accepted   = accepted_sum;
    assign dbg_committed  = committed_sum;
    assign dbg_flushes    = flushes_sum;
    assign dbg_collisions = collisions_sum;

    // -- Quartile-scan merge pipeline (timing) --------------------------------
    // The 8-way reduction of the per-bank counts is the path that fails setup on silicon
    // (bin_total_q_reg/D, WNS -0.430): a single-cycle 8-input add silently latches a wrong
    // partial sum, so the histogram is correct (committed == N) but `total` reads low -- the
    // count-loss we root-caused. FIX: pipeline the reduction into THREE single-level adder
    // stages (8 -> 4 -> 2 -> 1), each registered, so no stage is deeper than one add. This
    // lengthens read->merge latency from 2 to SCAN_LAT cycles, so the scan skips scan_cnt <
    // SCAN_LAT, runs to NUM_BINS+SCAN_LAT-1, and the located bin is scan_cnt-SCAN_LAT. The scan
    // runs once per dataset (~NUM_BINS cycles) so the extra latency is free. (Assumes
    // NUM_ELEMENTS == 8, the production geometry.)
    localparam int SCAN_LAT = 4;               // 1 (BRAM read) + 3 (reduction register stages)

    logic [COUNT_WIDTH + 2:0] red1 [4];        // stage 1: 8 banks -> 4 partial sums
    logic [COUNT_WIDTH + 2:0] red2 [2];        // stage 2: 4 -> 2
    logic [COUNT_WIDTH + 2:0] bin_total_q;     // stage 3: 2 -> 1  (consumed by the FSM merge below)
    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            for (int i = 0; i < 4; i++) red1[i] <= '0;
            red2[0] <= '0; red2[1] <= '0;
            bin_total_q <= '0;
        end else begin
            for (int i = 0; i < 4; i++)        // stage 1: pair the 8 banks
                red1[i] <= (COUNT_WIDTH + 3)'(bank_q[2*i]) + (COUNT_WIDTH + 3)'(bank_q[2*i + 1]);
            red2[0]     <= red1[0] + red1[1];  // stage 2: pair the 4 partials
            red2[1]     <= red1[2] + red1[3];
            bin_total_q <= red2[0] + red2[1];  // stage 3: final per-bin sum
        end
    end

    // -- Control FSM ----------------------------------------------------------
    logic       last_seen;

    if (EN_INDEX) begin : g_idx_pack
        IqrIndexPack #(
            .NUM_ELEMENTS(NUM_ELEMENTS), .IDX_BITS(IDX_BITS), .OUT_W(VALUE_WIDTH*NUM_ELEMENTS)
        ) inst_idx_pack (
            .clk(clk), .rst_n(rst_n),
            .i_data(idx_packed_in),
            .i_keep(in.keep),
            .i_valid(accept),
            .o_ready(idx_pack_ready),
            // Flush at the end of pass 1: last_seen is held through the drain, and the packer latches
            // the request once and clears it after emitting, so this cannot double-emit.
            .i_flush((state == HISTOGRAM) && last_seen),
            .i_restart(clear_req),
            // So the final full beat carries o_last when the column is an exact multiple of 32 elements
            // (no flush beat). Without it the host's index drain hangs -- the ov_uniform silicon failure.
            .i_expected(i_expected),
            .o_data(o_idx_data), .o_valid(o_idx_valid), .o_ready_in(i_idx_ready), .o_last(o_idx_last),
            .o_beats(o_idx_beats)
        );
    end else begin : g_no_idx_pack
        // Index mode compiled out: the pass-1 index stream never fires; always-ready so the
        // HISTOGRAM in.ready term folds cleanly (idx_mode is 0 anyway, so it is not even consulted).
        assign idx_pack_ready = 1'b1;
        assign o_idx_data     = '0;
        assign o_idx_valid    = 1'b0;
        assign o_idx_last     = 1'b0;
        assign o_idx_beats    = '0;
    end
    logic [3:0] drain_cnt;

    // Drain timing. DRAIN_START set on the last beat; flush_final fires DRAIN_START-2
    // later (so the 2-stage bin-index pipe has delivered the last beats to the
    // coalescers), then drain_cnt counts down to 0 before QUARTILES starts reading.
    // The gap from flush_final->0 is the SETTLE window: it must be long enough that
    // every bank's final RMW commit has fully landed in BRAM and the read port has
    // switched off the write address BEFORE the quartile scan reads bin 0. Silicon
    // (build-06 dual-ILA, 2026-06-30) showed the OLD 5-cycle drain lost the upper
    // banks' final (drain) commit to a write-vs-first-read TDP collision at the
    // HISTOGRAM->QUARTILES boundary (bank7 every run, bank5 borderline; bin-independent,
    // wandering total 12-15/16). Widened to a ~10-cycle settle to clear that collision.
    localparam logic [3:0] DRAIN_START = 4'd12;
    localparam logic [3:0] DRAIN_FLUSH = DRAIN_START - 4'd2;   // 2 cycles after the last beat
    assign flush_final = (state == HISTOGRAM) && last_seen && (drain_cnt == DRAIN_FLUSH);

    always_ff @(posedge clk) begin
        logic [COUNT_WIDTH + 2:0]        cum4, tot1, tot3;

        if (reset_synced == 1'b0) begin
            state             <= HISTOGRAM;
            clearing          <= 1'b1;   // clear the banks before first dataset
            clear_addr        <= '0;
            last_seen         <= 1'b0;
            drain_cnt         <= '0;
            q1_found          <= 1'b0;
            q3_found          <= 1'b0;
            clear_req_pending <= 1'b0;   // reset sweep is not a host clear -> no seq bump
            clear_seq         <= '0;
        end else if (clear_req) begin
            // Host requested a fresh start: re-arm the clear sweep from whatever state
            // the previous run left us in. Recovers cross-run residue at the process
            // boundary (the per-bank clear at clearing=1 zeroes every bin below).
            state             <= HISTOGRAM;
            clearing          <= 1'b1;
            clear_addr        <= '0;
            last_seen         <= 1'b0;
            drain_cnt         <= '0;
            q1_found          <= 1'b0;
            q3_found          <= 1'b0;
            clear_req_pending <= 1'b1;   // this sweep is host-requested -> bump seq on completion
        end else begin
            case (state)
                HISTOGRAM: begin
                    if (clearing) begin
                        // Sweep zeros across every bank, then open the input.
                        // (in.ready is held low by the combinational block.)
                        if (clear_addr == BIN_IDX_WIDTH'(NUM_BINS - 1)) begin
                            clearing <= 1'b0;
                            // Sweep done. If it was host-requested, signal completion so the
                            // host's poll releases and streams pass-1 into a guaranteed-zero,
                            // idle-ready core (no early beats consumed -> no lost counts).
                            if (clear_req_pending) begin
                                clear_seq         <= clear_seq + 1'b1;
                                clear_req_pending <= 1'b0;
                            end
                        end else begin
                            clear_addr <= clear_addr + 1'b1;
                        end
                    end else if (!last_seen) begin
                        // Bin until the terminating beat is consumed (in.ready is
                        // high in this phase, so consumed == valid).
                        if (in.valid && in.ready && in.last) begin
                            last_seen <= 1'b1;
                            // Drain: let the 2-stage bin-index pipe deliver the last beats to
                            // the coalescers, then flush_final (at DRAIN_FLUSH) pushes every
                            // bank's final run into the BRAM, then a ~10-cycle settle lets the
                            // RMW commits fully land before the quartile scan reads the histogram.
                            drain_cnt <= DRAIN_START;
                        end
                    end else begin
                        // Drain the RMW pipeline before reading the histogram.
                        if (drain_cnt == 4'd0) begin
                            state      <= QUARTILES;
                            last_seen  <= 1'b0;
                            // Arm the quartile scan.
                            q_phase    <= Q_SUM;
                            scan_cnt   <= '0;
                            total      <= '0;
                            cumulative <= '0;
                            q1_found   <= 1'b0;
                            q3_found   <= 1'b0;
                            fence_step <= 3'd0;   // arm the pipelined fence computation
                        end else begin
                            drain_cnt <= drain_cnt - 4'd1;
                        end
                    end
                end

                QUARTILES: begin
                    if (q1_found && q3_found) begin
                        // Both quartiles located. Derive their values + the 1.5*IQR fences
                        // (1.5*IQR = IQR + IQR/2, no multiplier) over 4 registered steps so the
                        // wide variable-shift and signed adds each meet timing, then hand to FLAG.
                        case (fence_step)
                            3'd0: begin   // bin -> value (the wide variable shift, isolated)
                                q1v_r <= bin_min + (VALUE_WIDTH'(q1_bin) << bin_shift);
                                q3v_r <= bin_min + (VALUE_WIDTH'(q3_bin) << bin_shift);
                                fence_step <= 3'd1;
                            end
                            3'd1: begin   // sign/zero-extend to fence width (signed windows)
                                q1e_r <= is_signed ? $signed({{3{q1v_r[VALUE_WIDTH-1]}}, q1v_r}) : $signed({3'b0, q1v_r});
                                q3e_r <= is_signed ? $signed({{3{q3v_r[VALUE_WIDTH-1]}}, q3v_r}) : $signed({3'b0, q3v_r});
                                fence_step <= 3'd2;
                            end
                            3'd2: begin   // IQR = Q3 - Q1
                                iqrv_r <= q3e_r - q1e_r;
                                fence_step <= 3'd3;
                            end
                            3'd3: begin   // fences, then the index-space conversion
                                q1_val      <= q1v_r;
                                q3_val      <= q3v_r;
                                iqr_val     <= iqrv_r;
                                lower_fence <= q1e_r - iqrv_r - (iqrv_r >>> 1);
                                upper_fence <= q3e_r + iqrv_r + (iqrv_r >>> 1);
                                fence_step  <= 3'd4;
                            end
                            3'd4: begin
                                // Step 2: register the fences in half-bin index space. One extra
                                // cycle per COLUMN, which keeps a wide variable shift off the path
                                // that every FLAG beat takes. Harmless when i_idx_mode is low.
                                lo_fidx_r <= lo_fidx_c;
                                hi_fidx_r <= hi_fidx_c;
                                state     <= FLAG;
                            end
                        endcase
                    end else begin
                        case (q_phase)
                            Q_SUM: begin
                                // Pass 1: grand total = sum of every bin.
                                // bin_total_q holds bin scan_cnt-SCAN_LAT (BRAM read + 3-stage
                                // reduction), so accumulate bins 0..NUM_BINS-1 over scan_cnt
                                // SCAN_LAT..NUM_BINS+SCAN_LAT-1.
                                if (scan_cnt >= SCAN_LAT)
                                    total <= total + bin_total_q[COUNT_WIDTH - 1:0];

                                if (scan_cnt == NUM_BINS + SCAN_LAT - 1) begin
                                    q_phase  <= Q_SCAN;
                                    scan_cnt <= '0;
                                end else begin
                                    scan_cnt <= scan_cnt + 1'b1;
                                end
                            end

                            Q_SCAN: begin
                                // Pass 2: cumulative count locates the quartiles.
                                // Q1 = first bin with 4*cumulative >= total,
                                // Q3 = first bin with 4*cumulative >= 3*total.
                                // bin_total_q is bin scan_cnt-SCAN_LAT, so the located bin is too.
                                if (scan_cnt >= SCAN_LAT) begin
                                    cum4 = ((COUNT_WIDTH + 3)'(cumulative) + bin_total_q) << 2;
                                    tot1 = (COUNT_WIDTH + 3)'(total);
                                    tot3 = ((COUNT_WIDTH + 3)'(total) << 1) + (COUNT_WIDTH + 3)'(total);

                                    cumulative <= cumulative + bin_total_q[COUNT_WIDTH - 1:0];

                                    if (!q1_found && cum4 >= tot1) begin
                                        q1_found <= 1'b1;
                                        q1_bin   <= scan_cnt[BIN_IDX_WIDTH - 1:0] - BIN_IDX_WIDTH'(SCAN_LAT);
                                    end
                                    if (!q3_found && cum4 >= tot3) begin
                                        q3_found <= 1'b1;
                                        q3_bin   <= scan_cnt[BIN_IDX_WIDTH - 1:0] - BIN_IDX_WIDTH'(SCAN_LAT);
                                    end
                                end

                                if (scan_cnt != NUM_BINS + SCAN_LAT - 1)
                                    scan_cnt <= scan_cnt + 1'b1;
                            end
                        endcase
                    end
                end

                FLAG: begin
                    // Pass 2: stream the column back out with the outlier mask
                    // (combinational passthrough below). Finish on the last beat
                    // actually transferred (in.ready == out.ready here).
                    //
                    // Index mode finishes on the WIDE flag output's last: the value `out` is idle in
                    // index mode, and one input index beat is consumed the same cycle its 16 flags are
                    // handed to the wide packer, so idxf_last on an accepted wide beat is the column's
                    // end. (The wide packer's own tail flush drains afterwards, steered on valid in the
                    // top -- see vfpga_top.)
                    if (idx_mode ? (idxf_valid && i_flagw_ready && idxf_last)
                                  : (in.valid && in.ready && in.last)) begin
                        state      <= HISTOGRAM;
                        clearing   <= 1'b1;        // re-clear banks for next dataset
                        clear_addr <= '0;
                    end
                end
            endcase
        end
    end

    // -- Step 2: pass-2 index consumer (WIDE) --------------------------------------------------
    // Active only in FLAG and only in index mode. It takes one 512-bit beat of 16 indices (32-bit
    // packing for 4096 bins), compares them all in one cycle, and emits all 16 outlier bits as one wide
    // flag beat on o_flagw_* (packed by IqrWideFlagPack in the top). This is the step-2 speedup: the
    // value path's `out` is left idle in index mode, and pass 2 produces ~16 flags/cycle instead of 8.
    if (EN_INDEX) begin : g_idx_flag
        logic [VALUE_WIDTH*NUM_ELEMENTS - 1:0] in_flat;
        always_comb for (int i = 0; i < NUM_ELEMENTS; i++) in_flat[i*VALUE_WIDTH +: VALUE_WIDTH] = in.data[i];

        wire idx_flag_active = idx_mode && (state == FLAG);
        assign idxf_in_valid = idx_flag_active && in.valid;

        IqrIndexFlag #(
            .IDX_BITS(IDX_BITS), .IDX_W(IDX_W), .FIDX_W(FIDX_W),
            .IN_W(VALUE_WIDTH*NUM_ELEMENTS)
        ) inst_idx_flag (
            .clk(clk), .rst_n(rst_n),
            .i_enable(idx_flag_active),
            .i_expected(i_expected),
            // Re-arm on the host clear pulse, the same fence that re-arms pass 1.
            .i_restart(clear_req),
            .i_lo_fidx(lo_fidx_r), .i_hi_fidx(hi_fidx_r),
            .i_data(in_flat), .i_valid(idxf_in_valid), .o_ready(idxf_in_ready),
            .o_flags(idxf_flags), .o_keep(idxf_keep), .o_valid(idxf_valid),
            .o_ready_in(i_flagw_ready), .o_last(idxf_last)
        );
    end else begin : g_no_idx_flag
        // Index mode compiled out: pass-2 consumer absent; tie its signals so the FLAG-state
        // exit, in.ready mux, and o_flagw_* all see a quiescent index path (idx_mode is 0).
        assign idxf_in_valid = 1'b0;
        assign idxf_in_ready = 1'b0;
        assign idxf_flags    = '0;
        assign idxf_keep     = '0;
        assign idxf_valid    = 1'b0;
        assign idxf_last     = 1'b0;
    end

    // Drive the wide flag output straight from the consumer (the top packs it).
    assign o_flagw_data  = idxf_flags;
    assign o_flagw_keep  = idxf_keep;
    assign o_flagw_valid = idxf_valid;
    assign o_flagw_last  = idxf_last;

    // -- Input ready ----------------------------------------------------------
    // Combinational so FLAG can backpressure straight from out.ready (zero-buffer
    // passthrough). HISTOGRAM accepts only in its binning phase; QUARTILES stalls.
    // In index mode HISTOGRAM must also wait on the index packer, and FLAG takes its ready from
    // the index consumer instead of straight from out.ready (it buffers a beat and emits 4).
    always_comb begin
        case (state)
            HISTOGRAM: in.ready = (!clearing) && (!last_seen)
                                  && ((!idx_mode) || idx_pack_ready);
            FLAG:      in.ready = idx_mode ? idxf_in_ready : out.ready;
            default:   in.ready = 1'b0;     // QUARTILES
        endcase
    end

    // -- Output (pass 2 flag column) ------------------------------------------
    // Idle outside FLAG. In FLAG we emit one flag per input element: 1 if the
    // element is an outlier (outside the [lower_fence, upper_fence] window), 0 if
    // normal. keep is passed through unchanged, so the stream stays dense (no
    // holes mid-beat) and the host receives a same-length 0/1 column aligned with
    // its input. The fences are signed; the value is sign-extended when is_signed
    // and zero-extended otherwise, so the compare matches the configured domain.
    always_comb begin
        logic signed [VALUE_WIDTH + 2:0] sval;
        logic                            is_outlier;

        // Default: idle.
        out.valid = 1'b0;
        out.last  = 1'b0;
        out.keep  = '0;
        out.data  = '0;

        // Only the VALUE path drives `out`. In index mode the flags leave on the wide o_flagw_*
        // stream (packed by IqrWideFlagPack in the top), so `out` stays idle.
        if ((state == FLAG) && !idx_mode) begin
            out.valid = in.valid;
            out.last  = in.last;
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                sval        = is_signed ? $signed({{3{in.data[i][VALUE_WIDTH-1]}}, in.data[i]})
                                        : $signed({3'b0, in.data[i]});
                is_outlier  = (sval < lower_fence) || (sval > upper_fence);
                out.data[i] = is_outlier ? value_t'(1) : value_t'(0);  // flag, not the value
                out.keep[i] = in.keep[i];                              // dense: no holes
            end
        end
    end

`ifdef IQR_DEBUG_ILA
    // -- Count-loss diagnostic ILA: the FULL life of `total` -------------------------------------
    // Traces every stage so the count-loss never needs another bitgen to localize:
    //   per-bank reads (bank_q) -> 3-stage reduction (red1->red2->bin_total_q) -> accumulator
    //   (total) -> quartiles (q1_bin/q3_bin/cumulative) -> fences (lower/upper_fence) -> host
    //   (dbg_total), with state/q_phase/scan_cnt/fence_step context + one write-side tap.
    // Probe widths MUST match hardware/src/init_ip.tcl. Synthesis-only (breaks xsim) -> comment
    // the `define for co-sim. Trigger on accept_q to capture the whole pass; the scan is long
    // (~NUM_BINS*2 cycles) so to see total accumulate you may trigger on state==QUARTILES instead.
    // ILA #1 -- SCAN / SUM path: the FULL 8->4->2->1 reduction (every bank read + every
    // reduction node) so the per-bin grand total can be reconstructed by hand from the probes,
    // plus the quartile/fence context. (Was 3-of-8 banks + 1-of-4 red1; now all 8 + all of them.)
    ila_iqr inst_ila_iqr (
        .clk    (clk),
        .probe0 (state),               // 2  HISTOGRAM/QUARTILES/FLAG
        .probe1 (q_phase),             // 1  Q_SUM / Q_SCAN
        .probe2 (scan_cnt),            // 11 which scan step (bin = scan_cnt-SCAN_LAT)
        .probe3 (clearing),            // 1
        .probe4 (accept_q),            // 1  a beat is being binned (pass-1)
        .probe5 (fence_step),          // 2  pipelined-fence sub-step
        .probe6 (q_raddr),             // 10 scan read address presented to every bank
        .probe7 (flush_final),         // 1  end-of-pass drain pulse
        .probe8 (clear_addr),          // 10 CLEAR sweep address
        .probe9 (bank_q[0]),           // 32 per-bank scan read mem[q_raddr]
        .probe10(bank_q[1]),           // 32
        .probe11(bank_q[2]),           // 32
        .probe12(bank_q[3]),           // 32
        .probe13(bank_q[4]),           // 32
        .probe14(bank_q[5]),           // 32
        .probe15(bank_q[6]),           // 32
        .probe16(bank_q[7]),           // 32
        .probe17(red1[0]),             // 35 reduction stage 1 (8->4)
        .probe18(red1[1]),             // 35
        .probe19(red1[2]),             // 35
        .probe20(red1[3]),             // 35
        .probe21(red2[0]),             // 35 reduction stage 2 (4->2)
        .probe22(red2[1]),             // 35
        .probe23(bin_total_q),         // 35 reduction stage 3 = per-bin 8-bank sum
        .probe24(total),               // 32 running grand total (the suspect)
        .probe25(cumulative),          // 32 Q_SCAN cumulative
        .probe26(q1_bin),              // 10
        .probe27(q3_bin),              // 10
        .probe28(lower_fence),         // 67
        .probe29(upper_fence),         // 67
        .probe30(dbg_total)            // 64 what is shipped to the host CSR
    );

    // ILA #2 -- per-bank READ-MODIFY-WRITE path, banks 0..3. Follows a value the whole way:
    //   lane_idx_q (binned value) -> coalescer (acc_bin/acc_cnt/acc_valid) -> flush request
    //   (fl_we/fl_bin/fl_delta) -> RMW commit (s1_we/s1_bin/s1_delta) -> BRAM read-back (rd_q)
    //   at read address (raddr); the value actually written on a commit is rd_q + s1_delta, so the
    //   write data is reconstructable. hazard_hit flags a flush that read a just-written bin.
    // Banks 0..3 cover (for the {0,7,8,8,9,...} dataset) the bin-8 lost banks 0 & 3, the bin-8
    // survived bank 2, and bank 1 (bin-7) as a non-bin8 control. Trigger on flush_final or
    // g_bank[K].s1_we to catch the drain commits; on accept_q to catch pass-1 binning.
    ila_iqr_rmw inst_ila_iqr_rmw (
        .clk    (clk),
        .probe0 (state),
        .probe1 (clearing),
        .probe2 (flush_final),
        .probe3 (accept_q),
        .probe4 (last_seen),
        .probe5 (drain_cnt),
        .probe6 (scan_cnt),
        // -- bank 0 --
        .probe7(g_bank[0].beat),
        .probe8(lane_idx_q[0]),
        .probe9(g_bank[0].acc_bin),
        .probe10(g_bank[0].acc_cnt),
        .probe11(g_bank[0].acc_valid),
        .probe12(g_bank[0].fl_we),
        .probe13(g_bank[0].fl_bin),
        .probe14(g_bank[0].fl_delta),
        .probe15(g_bank[0].s1_we),
        .probe16(g_bank[0].s1_bin),
        .probe17(g_bank[0].s1_delta),
        .probe18(g_bank[0].rd_q),
        .probe19(g_bank[0].raddr),
        .probe20(g_bank[0].hazard_hit),
        // -- bank 1 --
        .probe21(g_bank[1].beat),
        .probe22(lane_idx_q[1]),
        .probe23(g_bank[1].acc_bin),
        .probe24(g_bank[1].acc_cnt),
        .probe25(g_bank[1].acc_valid),
        .probe26(g_bank[1].fl_we),
        .probe27(g_bank[1].fl_bin),
        .probe28(g_bank[1].fl_delta),
        .probe29(g_bank[1].s1_we),
        .probe30(g_bank[1].s1_bin),
        .probe31(g_bank[1].s1_delta),
        .probe32(g_bank[1].rd_q),
        .probe33(g_bank[1].raddr),
        .probe34(g_bank[1].hazard_hit),
        // -- bank 2 --
        .probe35(g_bank[2].beat),
        .probe36(lane_idx_q[2]),
        .probe37(g_bank[2].acc_bin),
        .probe38(g_bank[2].acc_cnt),
        .probe39(g_bank[2].acc_valid),
        .probe40(g_bank[2].fl_we),
        .probe41(g_bank[2].fl_bin),
        .probe42(g_bank[2].fl_delta),
        .probe43(g_bank[2].s1_we),
        .probe44(g_bank[2].s1_bin),
        .probe45(g_bank[2].s1_delta),
        .probe46(g_bank[2].rd_q),
        .probe47(g_bank[2].raddr),
        .probe48(g_bank[2].hazard_hit),
        // -- bank 3 --
        .probe49(g_bank[3].beat),
        .probe50(lane_idx_q[3]),
        .probe51(g_bank[3].acc_bin),
        .probe52(g_bank[3].acc_cnt),
        .probe53(g_bank[3].acc_valid),
        .probe54(g_bank[3].fl_we),
        .probe55(g_bank[3].fl_bin),
        .probe56(g_bank[3].fl_delta),
        .probe57(g_bank[3].s1_we),
        .probe58(g_bank[3].s1_bin),
        .probe59(g_bank[3].s1_delta),
        .probe60(g_bank[3].rd_q),
        .probe61(g_bank[3].raddr),
        .probe62(g_bank[3].hazard_hit),
        // -- bank 4 --
        .probe63(g_bank[4].beat),
        .probe64(lane_idx_q[4]),
        .probe65(g_bank[4].acc_bin),
        .probe66(g_bank[4].acc_cnt),
        .probe67(g_bank[4].acc_valid),
        .probe68(g_bank[4].fl_we),
        .probe69(g_bank[4].fl_bin),
        .probe70(g_bank[4].fl_delta),
        .probe71(g_bank[4].s1_we),
        .probe72(g_bank[4].s1_bin),
        .probe73(g_bank[4].s1_delta),
        .probe74(g_bank[4].rd_q),
        .probe75(g_bank[4].raddr),
        .probe76(g_bank[4].hazard_hit),
        // -- bank 5 --
        .probe77(g_bank[5].beat),
        .probe78(lane_idx_q[5]),
        .probe79(g_bank[5].acc_bin),
        .probe80(g_bank[5].acc_cnt),
        .probe81(g_bank[5].acc_valid),
        .probe82(g_bank[5].fl_we),
        .probe83(g_bank[5].fl_bin),
        .probe84(g_bank[5].fl_delta),
        .probe85(g_bank[5].s1_we),
        .probe86(g_bank[5].s1_bin),
        .probe87(g_bank[5].s1_delta),
        .probe88(g_bank[5].rd_q),
        .probe89(g_bank[5].raddr),
        .probe90(g_bank[5].hazard_hit),
        // -- bank 6 --
        .probe91(g_bank[6].beat),
        .probe92(lane_idx_q[6]),
        .probe93(g_bank[6].acc_bin),
        .probe94(g_bank[6].acc_cnt),
        .probe95(g_bank[6].acc_valid),
        .probe96(g_bank[6].fl_we),
        .probe97(g_bank[6].fl_bin),
        .probe98(g_bank[6].fl_delta),
        .probe99(g_bank[6].s1_we),
        .probe100(g_bank[6].s1_bin),
        .probe101(g_bank[6].s1_delta),
        .probe102(g_bank[6].rd_q),
        .probe103(g_bank[6].raddr),
        .probe104(g_bank[6].hazard_hit),
        // -- bank 7 --
        .probe105(g_bank[7].beat),
        .probe106(lane_idx_q[7]),
        .probe107(g_bank[7].acc_bin),
        .probe108(g_bank[7].acc_cnt),
        .probe109(g_bank[7].acc_valid),
        .probe110(g_bank[7].fl_we),
        .probe111(g_bank[7].fl_bin),
        .probe112(g_bank[7].fl_delta),
        .probe113(g_bank[7].s1_we),
        .probe114(g_bank[7].s1_bin),
        .probe115(g_bank[7].s1_delta),
        .probe116(g_bank[7].rd_q),
        .probe117(g_bank[7].raddr),
        .probe118(g_bank[7].hazard_hit),
        // -- BRAM write-data taps (rd_q+s1_delta on the DI pin) banks 0..7 --
        .probe119(g_bank[0].wdata_dbg),
        .probe120(g_bank[1].wdata_dbg),
        .probe121(g_bank[2].wdata_dbg),
        .probe122(g_bank[3].wdata_dbg),
        .probe123(g_bank[4].wdata_dbg),
        .probe124(g_bank[5].wdata_dbg),
        .probe125(g_bank[6].wdata_dbg),
        .probe126(g_bank[7].wdata_dbg)
    );
`endif

endmodule


// =================================================================================================
// FlagBitPacker
//
// Packs a per-element 0/1 flag stream into a dense bitmask: element e -> bit e (byte e/8, bit e%8),
// emitted as full OUT_W-bit beats (NUM_ELEMENTS x value_t); the final beat is zero-padded and
// carries last. Shrinks the host output transfer + readback by OUT_W/NUM_ELEMENTS (= 64x at 8x64):
// a 64 MB INT64 flag column becomes a 1 MB bitmask -- the readback was ~85% of the end-to-end time.
//
// Kept in this file (rather than its own) on purpose: it is only *reachable* through a
// `ifdef in the sim wrapper, and Vivado drops conditionally-unreachable files from the auto
// compile order. Living in the always-compiled DUT file guarantees it is in the library.
//
// Input  : in.data[i][0] = outlier flag for lane i, in.keep[i] = lane valid (only the final
//          beat is partial, since the column streams NUM_ELEMENTS-wide).
// =================================================================================================
module FlagBitPacker #(
    parameter type value_t,
    parameter      NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,    // flags  : #(value_t, NUM_ELEMENTS)
    ndata_i.m out    // bitmask: #(value_t, NUM_ELEMENTS), full beats, last on the final beat
);

`RESET_RESYNC

    localparam int LANE_W = $bits(value_t);
    localparam int OUT_W  = NUM_ELEMENTS * LANE_W;       // bits per output beat (512)
    localparam int SLOTS  = OUT_W / NUM_ELEMENTS;        // input beats per output beat (64)
    localparam int CNT_W  = $clog2(SLOTS + 1);           // must hold SLOTS itself, not SLOTS-1

    // -- Why this is a SHIFT REGISTER and not an indexed write ------------------------------------
    // The obvious form is  acc[slot * NUM_ELEMENTS +: NUM_ELEMENTS] = beat_bits  -- a variable-
    // position write into a 512-bit register. That synthesises to a 64-way, 512-bit-wide
    // barrel-shifter cloud rebuilt every cycle, and it was the WORST timing offender in the design:
    // build-15 reported 330 of 1000 failing paths in inst_iqr_flag_packer, averaging 15.6 logic
    // levels at fanout 412.
    //
    // A FIXED shift is pure wiring -- no mux, no select decode. Shifting right by NUM_ELEMENTS with
    // new bits entering at the TOP reproduces the required bit order exactly: the first beat is
    // pushed down by each subsequent one, so after SLOTS beats beat 0 sits in bits [7:0] and beat 63
    // in [511:504], which is the layout the host expects (element e -> bit e).
    //
    // THE COST, and why it is free in practice: a partial final word leaves the bits at the TOP,
    // needing a shift down by (SLOTS - filled) -- which would be a variable shift again, i.e. the
    // very thing we removed. So instead the packer just keeps shifting zeros in until the word is
    // full, then emits. That burns up to SLOTS-1 = 63 cycles ONCE PER COLUMN. Against sf10's ~7.5 M
    // output beats it is unmeasurable, and it buys a completely mux-free datapath.
    logic [OUT_W - 1:0] acc;           // bit accumulator, filled from the top down
    logic [CNT_W - 1:0] filled;        // beats accumulated into acc, 0..SLOTS
    logic               flushing;      // bottom-aligning a partial final word
    logic [CNT_W - 1:0] flush_left;    // shifts still owed before acc is bottom-aligned
    logic [OUT_W - 1:0] out_word;      // registered output payload
    logic               out_valid_r;
    logic               out_last_r;

    // This beat's NUM_ELEMENTS flag bits (unkept lanes contribute 0).
    logic [NUM_ELEMENTS - 1:0] beat_bits;
    always_comb
        for (int i = 0; i < NUM_ELEMENTS; i++)
            beat_bits[i] = in.keep[i] & in.data[i][0];

    // The whole datapath: a fixed right shift with insertion at the top.
    function automatic logic [OUT_W - 1:0] shift_in(logic [OUT_W - 1:0]        cur,
                                                    logic [NUM_ELEMENTS - 1:0] bits);
        return {bits, cur[OUT_W - 1:NUM_ELEMENTS]};
    endfunction

    // Accept input unless a completed beat is still waiting to be taken, or we are mid-flush (the
    // flush is self-driven and must not race new input into acc).
    wire out_free = !out_valid_r || out.ready;
    assign in.ready = out_free && !flushing;

    wire fire = in.valid && in.ready;

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            acc <= '0; filled <= '0; flushing <= 1'b0; flush_left <= '0;
            out_valid_r <= 1'b0; out_last_r <= 1'b0;
        end else begin
            if (out_valid_r && out.ready) out_valid_r <= 1'b0;  // previous beat consumed

            if (flushing) begin
                // Intermediate shifts touch only acc, so they never need the output to be free.
                if (flush_left > CNT_W'(1)) begin
                    acc        <= shift_in(acc, '0);
                    flush_left <= flush_left - CNT_W'(1);
                end else if (out_free) begin
                    out_word    <= shift_in(acc, '0);   // the shift that lands bit 0 in [0]
                    out_valid_r <= 1'b1;
                    out_last_r  <= 1'b1;
                    acc         <= '0;
                    filled      <= '0;
                    flushing    <= 1'b0;
                    flush_left  <= '0;
                end
            end else if (fire) begin
                logic [OUT_W - 1:0] nxt;
                logic [CNT_W - 1:0] nfill;
                nxt   = shift_in(acc, beat_bits);
                nfill = filled + CNT_W'(1);

                if (nfill == CNT_W'(SLOTS)) begin
                    // Word complete on its own -- already bottom-aligned, no flush needed.
                    out_word    <= nxt;
                    out_valid_r <= 1'b1;
                    out_last_r  <= in.last;
                    acc         <= '0;
                    filled      <= '0;
                end else if (in.last) begin
                    // Partial final word: hold it and shift zeros until it is aligned.
                    acc        <= nxt;
                    filled     <= nfill;
                    flushing   <= 1'b1;
                    flush_left <= CNT_W'(SLOTS) - nfill;
                end else begin
                    acc    <= nxt;
                    filled <= nfill;
                end
            end
        end
    end

    always_comb begin
        for (int g = 0; g < NUM_ELEMENTS; g++)
            out.data[g] = out_word[g * LANE_W +: LANE_W];
        out.valid = out_valid_r;
        out.last  = out_last_r;
        out.keep  = '1;     // every emitted beat is a full word (final beat zero-padded)
    end

endmodule

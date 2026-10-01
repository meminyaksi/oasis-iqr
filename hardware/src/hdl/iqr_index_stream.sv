`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The two ends of IQR step 2: turning pass 2 from a 64-bit value re-read into a packed index
 * re-read. Both modules are self-contained so they can be simulated without the IQR core.
 *
 * The wire format is fixed by iqr_index.sv: IDX_BITS bits per element = a signed half-bin index
 * (IDX_W bits) plus an `exact` bit, the rest reserved; proven bit-identical to the value compare
 * (tb_iqr_index). Re-widened for 4096 bins (build-24): IDX_W 14->16, IDX_BITS 16->32, so at 512 bits
 * per beat that is IDX_PER_BEAT = 16 elements, against 8 values per beat -- pass 2 moves 2x fewer
 * beats (was 4x at IDX_BITS=16), still the whole point. The defaults below track the canonical 32/16.
 *
 * WHY TWO MODULES AND NOT ONE WIDER PORT. Only the pass-2 INPUT gets wider. The flag OUTPUT keeps
 * its per-lane shape and simply runs multiple beats per input beat, so everything downstream is
 * untouched. That was the cheapest place to put the width change.
 */

// -------------------------------------------------------------------------------------------------
// IqrIndexPack -- pass 1 side. Takes NUM_ELEMENTS encoded indices per beat and gathers GATHER
// (= OUT_W/(NUM_ELEMENTS*IDX_BITS), = 2 at IDX_BITS=32) of them into one 512-bit output beat of
// IDX_PER_BEAT indices, for the host to store and hand back as pass 2's input.
//
// The tail is zero-padded rather than length-tracked: the host knows the element count N and the
// consumer masks the tail off against it (see IqrIndexFlag), so a partial final beat needs no
// in-band length. `i_flush` emits whatever is accumulated -- tie it to the end of pass 1.
// -------------------------------------------------------------------------------------------------
module IqrIndexPack #(
    parameter int NUM_ELEMENTS = 8,
    parameter int IDX_BITS     = 32,
    parameter int OUT_W        = 512
) (
    input logic clk,
    input logic rst_n,

    // One beat of encoded indices, packed LSB-first: element i occupies [i*IDX_BITS +: IDX_BITS].
    input  logic [NUM_ELEMENTS*IDX_BITS - 1:0] i_data,
    input  logic [NUM_ELEMENTS - 1:0]          i_keep,
    input  logic                               i_valid,
    output logic                               o_ready,
    // Emit a partial beat now (end of pass 1). Held until the beat is taken.
    input  logic                               i_flush,
    // Re-arm the beat counter for a new column (tie to the histogram clear pulse).
    input  logic                               i_restart,
    // Total elements in the column, so the LAST full beat can carry o_last even when the column is
    // an exact multiple of IDX_PER_BEAT and no flush beat is emitted. Without this, a column whose
    // element count is a multiple of 32 ends with o_last never asserted, the output writer never
    // closes the index transfer, and the host's drain (BypassStreamReceiver::next(), no timeout)
    // hangs forever -- the exact silicon failure on ov_uniform (N=20,000,000 = 625,000*32).
    input  logic [63:0]                        i_expected,

    output logic [OUT_W - 1:0]                 o_data,
    output logic                               o_valid,
    input  logic                               o_ready_in,
    output logic                               o_last,

    // Beats actually handed to the output writer this column. The host polls this before draining
    // the index transfer: the bypass receiver's next() blocks on a completion interrupt with NO
    // timeout, so a short stream would hang the query with nothing to report -- exactly the failure
    // mode that made the build-15 arbiter bug so expensive to find. Reset by i_restart.
    output logic [63:0]                        o_beats
);

`RESET_RESYNC

    localparam int IN_BITS      = NUM_ELEMENTS * IDX_BITS;      // 8*32 = 256
    localparam int GATHER       = OUT_W / IN_BITS;              // 512/256 = 2
    localparam int GCNT_W       = $clog2(GATHER + 1);
    localparam int IDX_PER_BEAT = OUT_W / IDX_BITS;             // 512/32 = 16

    // Total beats this column will produce = ceil(i_expected / IDX_PER_BEAT). Used to mark o_last on
    // the final full beat (the flush path handles the partial-tail case on its own).
    wire [63:0] expected_beats = (i_expected + 64'(IDX_PER_BEAT) - 64'd1) / 64'(IDX_PER_BEAT);

    logic [63:0]         beats;
    logic [63:0]         committed;   // beats emitted (out_valid_r set), vs `beats` = beats accepted
    logic [OUT_W - 1:0]  acc;
    logic [GCNT_W - 1:0] filled;
    logic                out_valid_r, out_last_r;
    logic [OUT_W - 1:0]  out_word;
    logic                flush_pending;

    // Fixed shift, new bits at the top -- same reasoning as FlagBitPacker: an indexed write into a
    // 512-bit register is a barrel-shifter cloud, a fixed shift is wiring. After GATHER beats the
    // first group sits in the low bits, which is the order the host expects.
    function automatic logic [OUT_W - 1:0] shift_in(logic [OUT_W - 1:0] cur,
                                                    logic [IN_BITS - 1:0] grp);
        return {grp, cur[OUT_W - 1:IN_BITS]};
    endfunction

    wire out_free = !out_valid_r || o_ready_in;
    assign o_ready = out_free && !flush_pending;

    wire fire = i_valid && o_ready;

    assign o_data  = out_word;
    assign o_valid = out_valid_r;
    assign o_last  = out_last_r;
    assign o_beats = beats;

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            acc <= '0; filled <= '0; out_valid_r <= 1'b0; out_last_r <= 1'b0;
            flush_pending <= 1'b0; beats <= '0; committed <= '0;
        end else begin
            if (out_valid_r && o_ready_in) begin
                out_valid_r <= 1'b0;
                beats       <= beats + 64'd1;
            end

            if (i_restart) begin beats <= '0; committed <= '0; end

            if (i_flush && !flush_pending && filled != '0) begin
                flush_pending <= 1'b1;
            end

            if (flush_pending) begin
                if (out_free) begin
                    // Zero-fill the rest of the word; the consumer masks the tail against N.
                    logic [OUT_W - 1:0] padded;
                    padded = acc;
                    for (int g = 0; g < GATHER; g++) begin
                        if (GCNT_W'(g) >= filled) begin
                            padded = shift_in(padded, '0);
                        end
                    end
                    out_word      <= padded;
                    out_valid_r   <= 1'b1;
                    out_last_r    <= 1'b1;   // a flush is always the final (partial-tail) beat
                    committed     <= committed + 64'd1;
                    acc           <= '0;
                    filled        <= '0;
                    flush_pending <= 1'b0;
                end
            end else if (fire) begin
                logic [OUT_W - 1:0]  nxt;
                logic [GCNT_W - 1:0] nfill;
                logic [IN_BITS - 1:0] grp;
                // Masked-off lanes contribute a zero index; they are beyond N and get dropped by the
                // consumer, but leaving them undefined would make the packed word non-deterministic.
                for (int i = 0; i < NUM_ELEMENTS; i++) begin
                    grp[i*IDX_BITS +: IDX_BITS] = i_keep[i] ? i_data[i*IDX_BITS +: IDX_BITS]
                                                            : IDX_BITS'(0);
                end
                nxt   = shift_in(acc, grp);
                nfill = filled + GCNT_W'(1);
                if (nfill == GCNT_W'(GATHER)) begin
                    out_word    <= nxt;
                    out_valid_r <= 1'b1;
                    // A full beat is the column's last only when the element count is an exact
                    // multiple of IDX_PER_BEAT, so no flush beat will follow. Otherwise the flush
                    // carries o_last (above). This is the fix for the multiple-of-32 drain hang.
                    out_last_r  <= (committed + 64'd1 == expected_beats);
                    committed   <= committed + 64'd1;
                    acc         <= '0;
                    filled      <= '0;
                end else begin
                    acc    <= nxt;
                    filled <= nfill;
                end
            end
        end
    end

endmodule


// -------------------------------------------------------------------------------------------------
// IqrIndexFlag -- pass 2 side. Consumes one 512-bit beat of LANES=IN_W/IDX_BITS indices (16 at
// IDX_BITS=32), compares every one against the index-space fences IN PARALLEL, and emits ALL of them
// as one wide flag beat.
//
// WHY WIDE (the step-2 speedup). The compares were always parallel; an earlier version threw that away
// by serialising the ready flags into sub-beats of 8, so pass 2 produced only ~8 flags/cycle -- the
// same rate as the value path, which is why step 2 moved fewer bytes yet ran no faster on silicon
// (build-19, RESULTS.md 9.21). Emitting all LANES in one cycle lets pass 2 consume one 512-bit index
// beat every cycle: LANES elements/cycle at PCIe rate. The output is packed by IqrWideFlagPack
// (LANES bits/beat) instead of the 8-wide FlagBitPacker.
//
// Zero-buffer passthrough: the compare is combinational, so o_valid follows i_valid and o_ready
// follows o_ready_in, exactly like the value path's FLAG output. `emitted` (elements handed out so
// far) is the only state; i_expected masks the padded tail of the final beat and places o_last on the
// beat carrying element N-1.
// -------------------------------------------------------------------------------------------------
module IqrIndexFlag #(
    parameter int IDX_BITS = 32,
    parameter int IDX_W    = 16,
    parameter int FIDX_W   = 20,
    parameter int IN_W     = 512
) (
    input logic clk,
    input logic rst_n,

    input logic                        i_enable,     // index mode on
    input logic [63:0]                 i_expected,   // total elements in the column
    input logic                        i_restart,    // re-arm the element counter for a new column

    input logic signed [FIDX_W - 1:0]  i_lo_fidx,
    input logic signed [FIDX_W - 1:0]  i_hi_fidx,

    input  logic [IN_W - 1:0]          i_data,
    input  logic                       i_valid,
    output logic                       o_ready,

    output logic [IN_W/IDX_BITS - 1:0] o_flags,   // LANES outlier bits, one per index in the beat
    output logic [IN_W/IDX_BITS - 1:0] o_keep,    // which lanes are within N (tail masked)
    output logic                       o_valid,
    input  logic                       o_ready_in,
    output logic                       o_last
);

`RESET_RESYNC

    localparam int LANES = IN_W / IDX_BITS;   // 512/32 = 16

    // -- Combinational compare of all LANES indices in the incoming beat --------------------------
    logic [LANES - 1:0] beat_outlier;
    for (genvar E = 0; E < LANES; E++) begin : g_cmp
        logic signed [IDX_W - 1:0] e_idx;
        logic                      e_exact;
        // Layout, fixed by IqrIndexPack: [IDX_W-1:0] = index, [IDX_W] = exact, rest reserved.
        assign e_idx   = i_data[E*IDX_BITS +: IDX_W];
        assign e_exact = i_data[E*IDX_BITS + IDX_W];

        IqrIndexCompare #(.IDX_W(IDX_W), .FIDX_W(FIDX_W)) inst_cmp (
            .i_idx(e_idx), .i_exact(e_exact),
            .i_lo_fidx(i_lo_fidx), .i_hi_fidx(i_hi_fidx),
            .o_outlier(beat_outlier[E])
        );
    end

    logic [63:0]        emitted;   // elements handed out so far this column
    logic [LANES - 1:0] keep_c;
    always_comb
        for (int j = 0; j < LANES; j++)
            keep_c[j] = (emitted + 64'(j)) < i_expected;

    assign o_flags = beat_outlier;   // raw; the packer masks with o_keep, as FlagBitPacker does
    assign o_keep  = keep_c;
    assign o_valid = i_enable && i_valid && (keep_c != '0);
    assign o_ready = i_enable && o_ready_in;
    // Last when this beat carries the final element of the column.
    assign o_last  = o_valid && ((emitted + 64'(LANES)) >= i_expected);

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            emitted <= '0;
        end else if (i_restart) begin
            emitted <= '0;
        end else if (o_valid && o_ready_in) begin
            emitted <= emitted + 64'(LANES);
        end
    end

endmodule


// -------------------------------------------------------------------------------------------------
// IqrWideFlagPack -- packs NUM_LANES flag bits per beat into OUT_W-bit words (element e -> bit e),
// the same layout FlagBitPacker produces, so the host reads the bitmask identically. It is the wide
// twin of FlagBitPacker: NUM_LANES bits/beat instead of 8 (16 at IDX_BITS=32), filling a 512-bit word
// in SLOTS = OUT_W/NUM_LANES beats (32 at NUM_LANES=16).
//
// Structure is copied verbatim from FlagBitPacker (a FIXED right-shift with insertion at the top --
// pure wiring, no barrel-shifter), including the partial-final-word flush that shifts zeros until the
// word bottom-aligns (up to SLOTS-1 cycles once per column). See FlagBitPacker in IQR_detection.sv
// for the full rationale.
// -------------------------------------------------------------------------------------------------
module IqrWideFlagPack #(
    parameter int NUM_LANES = 16,
    parameter int OUT_W     = 512
) (
    input logic clk,
    input logic rst_n,
    // Per-column reset: clears the accumulator/flush state so a new column cannot inherit residual bits
    // from the previous one in the same session (the §9.23 first-word leak). Defaults to 0 so existing
    // instantiations are unaffected; the top ties it to the same clear_req that restarts IqrIndexFlag.
    input logic i_restart = 1'b0,

    input  logic [NUM_LANES - 1:0] i_flags,
    input  logic [NUM_LANES - 1:0] i_keep,
    input  logic                   i_valid,
    output logic                   o_ready,
    input  logic                   i_last,

    output logic [OUT_W - 1:0]     o_data,
    output logic                   o_valid,
    input  logic                   o_ready_in,
    output logic                   o_last
);

`RESET_RESYNC

    localparam int SLOTS = OUT_W / NUM_LANES;   // 512/16 = 32
    localparam int CNT_W = $clog2(SLOTS + 1);

    logic [OUT_W - 1:0] acc;
    logic [CNT_W - 1:0] filled;
    logic               flushing;
    logic [CNT_W - 1:0] flush_left;
    logic [OUT_W - 1:0] out_word;
    logic               out_valid_r, out_last_r;

    logic [NUM_LANES - 1:0] beat_bits;
    always_comb
        for (int i = 0; i < NUM_LANES; i++)
            beat_bits[i] = i_keep[i] & i_flags[i];

    function automatic logic [OUT_W - 1:0] shift_in(logic [OUT_W - 1:0]     cur,
                                                    logic [NUM_LANES - 1:0] bits);
        return {bits, cur[OUT_W - 1:NUM_LANES]};
    endfunction

    wire out_free = !out_valid_r || o_ready_in;
    assign o_ready = out_free && !flushing;
    wire fire = i_valid && o_ready;

    assign o_data  = out_word;
    assign o_valid = out_valid_r;
    assign o_last  = out_last_r;

    always_ff @(posedge clk) begin
        if (reset_synced == 1'b0) begin
            acc <= '0; filled <= '0; flushing <= 1'b0; flush_left <= '0;
            out_valid_r <= 1'b0; out_last_r <= 1'b0;
        end else if (i_restart) begin
            // New column: drop any accumulated/flushing state so its first word starts from zero.
            acc <= '0; filled <= '0; flushing <= 1'b0; flush_left <= '0;
            out_valid_r <= 1'b0; out_last_r <= 1'b0;
        end else begin
            if (out_valid_r && o_ready_in) out_valid_r <= 1'b0;

            if (flushing) begin
                if (flush_left > CNT_W'(1)) begin
                    acc        <= shift_in(acc, '0);
                    flush_left <= flush_left - CNT_W'(1);
                end else if (out_free) begin
                    out_word    <= shift_in(acc, '0);
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
                    out_word    <= nxt;
                    out_valid_r <= 1'b1;
                    out_last_r  <= i_last;
                    acc         <= '0;
                    filled      <= '0;
                end else if (i_last) begin
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

endmodule

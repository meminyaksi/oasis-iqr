`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Bin-index encoding for IQR pass 2 -- lets the FLAG pass compare a compact INDEX per element
 * instead of re-reading the full 64-bit value, at BIT-IDENTICAL results.
 *
 * WHY. Pass 2 ships the whole decoded column back across PCIe (457.7 MB on sf10, 38.4 ms of the
 * operator's 139.5) and does nothing with each element but compare it against two constants: 8 bytes
 * moved per 1 bit produced. The histogram pass already derives a bin index for every element, so
 * shipping THAT instead is ~4x less traffic.
 *
 * WHY IT CAN BE EXACT, and the two traps.
 *
 * Q1 and Q3 are bin LOWER EDGES (IQR_detection sets q1_val = bin_min + q1_bin<<bin_shift), so with
 * W = 2**bin_shift:
 *     IQR      = (q3_bin - q1_bin) * W
 *     1.5*IQR  = IQR + IQR/2      -- exactly, because W is even whenever bin_shift >= 1
 *     fences   = bin_min + (an exact multiple of W/2)
 * So both fences land on HALF-BIN boundaries. Encoding at half-bin resolution therefore loses
 * nothing: the comparison becomes an identity, not an approximation.
 *
 * TRAP 1 -- the strict upper compare needs one extra bit. Let d = value - bin_min, s = bin_shift-1,
 * and let the fences be f = k*2**s (lower) and g = m*2**s (upper). Floor division gives
 *     d <  f   <=>   (d >>> s) <  k            EXACT (floor is monotonic, k an integer)
 *     d >  g   <=>   (d >>> s) >  m  OR  ((d >>> s) == m AND d != g)
 * The second case is real: every d in (g, g + 2**s) floors to m, so an index-only compare would
 * report them as INSIDE the fence and silently miss outliers. Hence `o_exact` -- "d is an exact
 * multiple of 2**s" -- which distinguishes d == g from d just above it.
 *
 * TRAP 2 -- the width tracks NUM_BINS. In HALF-bins the fence indices span
 *     f/(W/2) = 2*q1_bin - 3*(q3_bin-q1_bin)  >= -3*(NUM_BINS-1)
 *     g/(W/2) = 2*q3_bin + 3*(q3_bin-q1_bin)  <=  5*(NUM_BINS-1)   (q1_bin,q3_bin in [0,NUM_BINS-1])
 * At 1024 bins that is +5115/-3069 (13-bit signed +-4096 does NOT cover +5115; IDX_W=14 does). At
 * 4096 bins it is ~+20475/-12285, which IDX_W=14 (+-8191) would SATURATE and silently miss -- so the
 * design re-widened to IDX_W = 16 (+-32768), which covers 4096 with margin. Saturating is safe
 * precisely because every reachable fence index is strictly inside the range: a saturated data index
 * still compares on the correct side. Get this width wrong and far-out outliers are missed silently
 * -- gate on ov_drift. (>4096 bins would exceed +-32768 again; widen further or refuse in the host.)
 *
 * bin_shift == 0 (bin width 1) is the degenerate case: there is no half-bin, s = 0 and the index IS
 * d itself, so the compare is trivially exact.
 */

// -------------------------------------------------------------------------------------------------
// IqrIndexEncode -- (value, window) -> (half-bin index, exact flag), one lane.
// Purely combinational; the caller registers it (IQR_detection splits the equivalent bin-index
// computation across two stages for timing and this belongs in the same pipeline).
// -------------------------------------------------------------------------------------------------
module IqrIndexEncode #(
    parameter int VALUE_WIDTH = 64,
    parameter int IDX_W       = 16         // signed; see TRAP 2 above before changing (16 covers 4096 bins)
) (
    input  logic [VALUE_WIDTH - 1:0]                 i_value,
    input  logic [VALUE_WIDTH - 1:0]                 i_bin_min,
    input  logic [$clog2(VALUE_WIDTH + 1) - 1:0]     i_bin_shift,
    input  logic                                     i_is_signed,

    output logic signed [IDX_W - 1:0]                o_idx,
    output logic                                     o_exact
);

    // d = value - bin_min in the configured signedness, one extra bit so it cannot overflow.
    logic signed [VALUE_WIDTH:0] d;
    always_comb begin
        if (i_is_signed) begin
            d = $signed({i_value[VALUE_WIDTH-1], i_value})
              - $signed({i_bin_min[VALUE_WIDTH-1], i_bin_min});
        end else begin
            d = $signed({1'b0, i_value}) - $signed({1'b0, i_bin_min});
        end
    end

    // Half-bin shift. bin_shift == 0 => s == 0 => the index is d itself (exact by construction).
    logic [$clog2(VALUE_WIDTH + 1) - 1:0] s;
    always_comb s = (i_bin_shift == '0) ? '0 : (i_bin_shift - 1'b1);

    // Arithmetic (floor) shift: floor semantics are what the exactness proof above relies on, and
    // they are also what makes negative d behave -- a value below the window must produce a
    // NEGATIVE index, not clamp to zero the way the histogram's bin index does.
    logic signed [VALUE_WIDTH:0] shifted;
    always_comb shifted = d >>> s;

    // exact <=> the low s bits of d are zero. Recomputing d from the shifted value avoids
    // materialising a variable mask.
    always_comb o_exact = ((shifted <<< s) == d);

    // Saturate into IDX_W. Safe because every reachable fence index is strictly inside the range
    // (TRAP 2), so a saturated index is still on the correct side of both fences.
    localparam longint IDX_MAX =  (longint'(1) << (IDX_W - 1)) - 1;
    localparam longint IDX_MIN = -(longint'(1) << (IDX_W - 1));
    always_comb begin
        if (shifted > $signed((VALUE_WIDTH+1)'(IDX_MAX)))      o_idx = IDX_W'(IDX_MAX);
        else if (shifted < $signed((VALUE_WIDTH+1)'(IDX_MIN))) o_idx = IDX_W'(IDX_MIN);
        else                                                   o_idx = IDX_W'(shifted);
    end

endmodule


// -------------------------------------------------------------------------------------------------
// IqrFenceIndex -- converts a fence (absolute value) into the same half-bin index space.
// Runs ONCE per column, in the QUARTILES tail, so it is not on any throughput path.
// No saturation: the fence indices are bounded by construction (TRAP 2) and clamping them could
// move a fence, whereas clamping a data index cannot change which side of it the datum falls.
// -------------------------------------------------------------------------------------------------
module IqrFenceIndex #(
    parameter int VALUE_WIDTH = 64,
    parameter int FENCE_WIDTH = 67,        // IQR_detection's lower_fence/upper_fence width
    parameter int FIDX_W      = 20         // comfortably wider than any reachable fence index
) (
    input  logic signed [FENCE_WIDTH - 1:0]          i_fence,
    input  logic [VALUE_WIDTH - 1:0]                 i_bin_min,
    input  logic [$clog2(VALUE_WIDTH + 1) - 1:0]     i_bin_shift,
    input  logic                                     i_is_signed,

    output logic signed [FIDX_W - 1:0]               o_fidx
);

    logic signed [FENCE_WIDTH:0] f;
    always_comb begin
        if (i_is_signed) begin
            f = $signed({i_fence[FENCE_WIDTH-1], i_fence})
              - $signed({{(FENCE_WIDTH+1-VALUE_WIDTH){i_bin_min[VALUE_WIDTH-1]}}, i_bin_min});
        end else begin
            f = $signed({i_fence[FENCE_WIDTH-1], i_fence})
              - $signed({{(FENCE_WIDTH+1-VALUE_WIDTH){1'b0}}, i_bin_min});
        end
    end

    logic [$clog2(VALUE_WIDTH + 1) - 1:0] s;
    always_comb s = (i_bin_shift == '0) ? '0 : (i_bin_shift - 1'b1);

    // f is an exact multiple of 2**s (see the header), so this arithmetic shift is exact division.
    logic signed [FENCE_WIDTH:0] fsh;
    always_comb fsh = f >>> s;

    always_comb o_fidx = FIDX_W'(fsh);

endmodule


// -------------------------------------------------------------------------------------------------
// IqrIndexCompare -- the pass-2 outlier test, in index space. Replaces the two 67-bit signed
// compares against the raw value with two narrow compares plus the exact-bit correction.
// -------------------------------------------------------------------------------------------------
module IqrIndexCompare #(
    parameter int IDX_W  = 16,
    parameter int FIDX_W = 20
) (
    input  logic signed [IDX_W - 1:0]   i_idx,
    input  logic                        i_exact,
    input  logic signed [FIDX_W - 1:0]  i_lo_fidx,   // index of lower_fence
    input  logic signed [FIDX_W - 1:0]  i_hi_fidx,   // index of upper_fence

    output logic                        o_outlier
);

    logic signed [FIDX_W - 1:0] idx_x;
    always_comb idx_x = FIDX_W'(i_idx);              // sign-extend to the fence width

    // value < lower_fence  <=>  idx < lo_fidx                       (floor is monotonic)
    // value > upper_fence  <=>  idx > hi_fidx, or idx == hi_fidx and value is not exactly on it
    always_comb o_outlier = (idx_x < i_lo_fidx)
                         || (idx_x > i_hi_fidx)
                         || ((idx_x == i_hi_fidx) && !i_exact);

endmodule

`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * IqrHistogramFeed -- merges the decoder lanes' decoded output into a single stream for the
 * IQR core's HISTOGRAM pass, so pass 1 runs DURING decode instead of after it.
 *
 * WHY. Today the decoded column crosses PCIe three times: out of the decoder to the host, then
 * back to the FPGA twice (once to build the histogram, once to emit flags). The first of those
 * return trips is pure waste -- the values were on-chip moments earlier. Feeding the histogram
 * directly from the decoder output deletes it. Measured in software (RESULTS.md 9.15) this took
 * sf10's operator from 170.5 ms to 131.8 ms with `decode` unchanged, because pass 1 fits inside
 * decode's existing slack. Pass 2 cannot be fused: it needs the final Q1/Q3, which only exist
 * once every element has been histogrammed.
 *
 * THREE THINGS THIS MODULE EXISTS TO GET RIGHT:
 *
 * 1. `last` REGENERATION. Each decoder lane asserts `last` at the end of every ROW GROUP, but the
 *    histogram must see exactly ONE `last`, at the end of the whole column -- and no lane knows
 *    where that is. So per-lane `last` is dropped and this module counts elements against
 *    `i_expected` (a host CSR) and raises `last` itself on the beat that completes the column.
 *    If this count is wrong, pass 1 terminates early and every quartile is silently wrong, which
 *    is why the host also cross-checks dbg_total == N after the run.
 *
 * 2. ORDER DOES NOT MATTER, BANDWIDTH DOES. A histogram is order-independent, so a plain
 *    round-robin over the lanes is sufficient -- no reordering, no per-lane sequencing. The
 *    aggregate decoder output (4 lanes x ~1.37 GB/s = ~5.5 GB/s measured) is comfortably under
 *    this port's 512 bit @ 250 MHz = 16 GB/s, so the arbiter cannot become the bottleneck.
 *
 * 3. DECOUPLING FROM THE HOST PATH. The decoder output is TEE'd: it must still reach the host,
 *    which re-streams it for pass 2. A bare tee advances only when both sinks accept, so a lane
 *    waiting its arbitration turn would stall the host path and slow decode -- the opposite of
 *    the point. Each lane therefore gets a 2-deep skid buffer here, so the tee sees a ready that
 *    is high except in the rare case of a genuinely full buffer.
 *
 * When `i_enable` is low the module is inert: every lane's ready is held high so the tee is a
 * no-op and the legacy host-streamed pass 1 is used unchanged.
 */
module IqrHistogramFeed #(
    parameter type value_t,
    parameter int  NUM_ELEMENTS,
    parameter int  N_LANES
) (
    input logic clk,
    input logic rst_n,

    // Fuse mode on. Low => inert (ready held high, no output), legacy host pass 1.
    input logic        i_enable,
    // Total elements in the column. Drives `last` generation; set by the host before the run.
    input logic [63:0] i_expected,
    // Pulse to re-arm the element counter for a new column (tie to the histogram clear pulse).
    input logic        i_restart,

    // Per-lane decoder output, flattened: SystemVerilog interface arrays in port lists are
    // awkward to connect from a generate block in the top, and the tee has to be built there
    // anyway (the same beat must also go to the host).
    input  logic [N_LANES-1:0]                       i_valid,
    output logic [N_LANES-1:0]                       o_ready,
    input  value_t [N_LANES-1:0][NUM_ELEMENTS-1:0]   i_data,
    input  logic [N_LANES-1:0][NUM_ELEMENTS-1:0]     i_keep,

    // Diagnostics: elements fed so far, and whether the terminating `last` has been sent. The
    // host reads these back to distinguish "pass 1 never finished" from "pass 1 finished wrong".
    output logic [63:0]                              o_fed_elements,
    output logic                                     o_done,

    ndata_i.m out   // #(value_t, NUM_ELEMENTS) merged stream into IQR_detection
);

`RESET_RESYNC

    localparam int LANE_BITS = (N_LANES > 1) ? $clog2(N_LANES) : 1;

    // Element accounting. Declared up here because the skid buffers' ready depends on `done` (the
    // safety valve below).
    logic [63:0] fed;
    logic        done;
    logic [63:0] beat_elems;

    // -- Per-lane 2-deep skid buffer ---------------------------------------------------------
    // Decouples the tee in the top from this module's arbitration. Two entries is enough: the
    // worst-case wait for a turn is N_LANES-1 beats and the aggregate input rate is ~1/3 of the
    // output rate, so the buffers drain far faster than they fill.
    value_t [NUM_ELEMENTS-1:0] sk_data [N_LANES][2];
    logic   [NUM_ELEMENTS-1:0] sk_keep [N_LANES][2];
    logic   [1:0]              sk_occ  [N_LANES];   // one bit per slot, LSB = head
    logic                      sk_full [N_LANES];
    logic                      sk_has  [N_LANES];

    for (genvar L = 0; L < N_LANES; L++) begin : g_skid
        assign sk_full[L] = sk_occ[L][1];      // both slots taken
        assign sk_has[L]  = sk_occ[L][0];      // head valid
        // Inert when disabled: never back-pressure the decoder's path to the host.
        //
        // SAFETY VALVE: also hold ready high once `done`. The top's mux parks this module's ready at
        // 0 the instant the core leaves HISTOGRAM, so without this a single miscounted element turns
        // into a DEADLOCKED DECODER rather than a wrong answer -- the skids fill, the tee stops
        // advancing, and the host hangs with nothing to report. Dropping post-`done` beats instead
        // degrades a miscount to the histogram_total != N error the host already checks for.
        assign o_ready[L] = (!i_enable) || done || (!sk_full[L]);
    end

    // -- Round-robin arbitration over the lane heads ------------------------------------------
    logic [LANE_BITS-1:0] grant;
    logic                 any_head;
    logic [LANE_BITS-1:0] next_grant;

    always_comb begin
        any_head   = 1'b0;
        next_grant = grant;
        // Search from grant+1 wrapping, so no lane can be starved.
        for (int unsigned k = 1; k <= N_LANES; k++) begin
            int unsigned c;
            c = (int'(grant) + k) % N_LANES;
            if (!any_head && sk_has[c]) begin
                any_head   = 1'b1;
                next_grant = LANE_BITS'(c);
            end
        end
        // Prefer holding the current lane if it still has data (fewer switches, same throughput).
        if (sk_has[grant]) begin
            any_head   = 1'b1;
            next_grant = grant;
        end
    end

    // -- Element accounting and `last` generation ----------------------------------------------
    // Count off the SKID SLOT, not off out.keep. Sourcing it from out.keep made the always_comb
    // below read a signal it also drives (out.last needs beat_elems, beat_elems came from out.keep),
    // which xsim treats as a non-converging combinational loop and resolves to X -- `fed` then went
    // X on the first beat and `last` never fired. Synthesis would have inferred the same flat logic,
    // so this is a simulation-visibility fix, but the dependency was genuinely circular as written.
    logic [$clog2(NUM_ELEMENTS + 1) - 1:0] beat_cnt;
    always_comb begin
        beat_cnt = '0;
        for (int e = 0; e < NUM_ELEMENTS; e++) begin
            if (sk_keep[next_grant][0][e]) beat_cnt = beat_cnt + 1'b1;
        end
    end
    assign beat_elems     = 64'(beat_cnt);
    assign o_fed_elements = fed;
    assign o_done         = done;

    // Drive the merged stream from `next_grant` -- the lane SELECTED THIS CYCLE -- not from `grant`,
    // which is last cycle's winner and is precisely the lane that has just run dry.
    //
    // This was the build-15 hang. `out.valid` follows `any_head` (ANY lane has a head) while the
    // payload came from sk_data[grant]. As soon as lane `grant` emptied and a different lane had
    // data, the module asserted valid over an empty slot: garbage `keep` bits inflated beat_elems,
    // `fed` overshot i_expected, `last` fired early, the core left HISTOGRAM, the top's mux parked
    // this module's ready at 0, the skids filled, and the tee deadlocked the DECODER -- a silent
    // hang with no host-visible error, since the host never even reached finish_fused.
    // It is invisible with N_LANES=1, where grant is always 0.
    always_comb begin
        out.data  = sk_data[next_grant][0];
        out.keep  = sk_keep[next_grant][0];
        out.valid = i_enable && any_head && !done;
        out.last  = i_enable && any_head && ((fed + beat_elems) >= i_expected);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            grant <= '0;
            fed   <= '0;
            done  <= 1'b0;
            for (int L = 0; L < N_LANES; L++) begin
                sk_occ[L] <= '0;
            end
        end else begin
            if (i_restart) begin
                fed  <= '0;
                done <= 1'b0;
            end

            // Push: the top's tee handed us a beat this cycle.
            for (int L = 0; L < N_LANES; L++) begin
                logic push, pop;
                // Once `done`, accept and DISCARD: see o_ready's comment on why dropping beats is
                // the safe behaviour here.
                push = i_enable && !done && i_valid[L] && o_ready[L];
                pop  = out.valid && out.ready && (next_grant == LANE_BITS'(L));

                if (push && !pop) begin
                    if (!sk_occ[L][0]) begin
                        sk_data[L][0] <= i_data[L];
                        sk_keep[L][0] <= i_keep[L];
                        sk_occ[L][0]  <= 1'b1;
                    end else begin
                        sk_data[L][1] <= i_data[L];
                        sk_keep[L][1] <= i_keep[L];
                        sk_occ[L][1]  <= 1'b1;
                    end
                end else if (pop && !push) begin
                    sk_data[L][0] <= sk_data[L][1];
                    sk_keep[L][0] <= sk_keep[L][1];
                    sk_occ[L]     <= {1'b0, sk_occ[L][1]};
                end else if (push && pop) begin
                    // Simultaneous: shift down and land the new beat in the vacated slot.
                    if (sk_occ[L][1]) begin
                        sk_data[L][0] <= sk_data[L][1];
                        sk_keep[L][0] <= sk_keep[L][1];
                        sk_data[L][1] <= i_data[L];
                        sk_keep[L][1] <= i_keep[L];
                    end else begin
                        sk_data[L][0] <= i_data[L];
                        sk_keep[L][0] <= i_keep[L];
                    end
                end
            end

            if (out.valid && out.ready) begin
                grant <= next_grant;
                fed   <= fed + beat_elems;
                if (out.last) begin
                    done <= 1'b1;   // one `last` per column; stay quiet until i_restart
                end
            end else if (any_head) begin
                grant <= next_grant;
            end
        end
    end

endmodule

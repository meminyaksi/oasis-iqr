`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb cq_rd.tie_off_s();

`ifdef EN_RDMA
always_comb rq_rd.tie_off_s();
always_comb rq_wr.tie_off_s();

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

for (genvar I = 0; I < N_RDMA_AXI; I++) begin
    always_comb axis_rrsp_send[I].tie_off_m();
    always_comb axis_rrsp_recv[I].tie_off_s();
    always_comb axis_rreq_send[I].tie_off_m();
end

`ASSERT_ELAB(N_STRM_AXI == N_RDMA_AXI)
`endif

localparam NUM_STREAMS        = N_STRM_AXI;
localparam DATABEAT_SIZE      = AXI_DATA_BITS / 8;
// MemConfig write side needs NUM_STREAMS+1 regs, read side needs 3 (ID, num_streams, max_enqueued).
localparam MEM_CONFIG_NUM_REGS = (NUM_STREAMS + 1 > 3) ? NUM_STREAMS + 1 : 3;

// In local mode the last stream is reserved for the IQR_detection operator (a 4th config block),
// mirroring how RDMA reserves a bypass stream. RDMA/production builds are unchanged.
`ifdef EN_RDMA
localparam NUM_CONFIGS   = 3;
localparam NUM_DECODERS  = NUM_STREAMS - 1;
`else
localparam NUM_CONFIGS   = 4;                 // + IQR config block
localparam NUM_DECODERS  = NUM_STREAMS - 1;   // reserve the last lane for IQR
`endif

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i                       write_configs[NUM_CONFIGS](.*);
read_config_i                        read_configs [NUM_CONFIGS](.*);
mem_config_i                         mem_conf[NUM_STREAMS](.*);
ready_valid_i #(read_req_t)          read_conf[NUM_STREAMS](.*);
ready_valid_i #(column_chunk_conf_t) column_chunk_conf[NUM_DECODERS](.*);
decoder_profile_i                    decoder_profiles[NUM_DECODERS]();

GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_SIZES({
        MEM_CONFIG_NUM_REGS,
        COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS),
        NUM_READ_REQ_CONFIG_REGS * NUM_STREAMS
`ifndef EN_RDMA
        , NUM_IQR_CONFIG_REGS
`endif
    })
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

MemConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .out(column_chunk_conf),

    .profile(decoder_profiles)
);

ReadReqConfig #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_read_req_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[2]),
    .read_config(read_configs[2]),

    .out(read_conf)
);

// -- Arbiter the read send queue ------------------------------------------------------------------
metaIntf #(.STYPE(req_t)) sq_rd_strm [NUM_STREAMS](.aclk(clk), .aresetn(rst_n));

MetaIntfArbiter #(
    .N_INTERFACES(NUM_STREAMS),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_rd_strm),
    .intf_out(sq_rd)
);

// -- Data path ------------------------------------------------------------------------------------
AXI4S axi_out[NUM_STREAMS](.aclk(clk), .aresetn(rst_n));

// Fused pass 1: the decoded beats are TEE'd off each decoder lane straight into the IQR histogram,
// so pass 1 runs during decode instead of being re-streamed from the host afterwards. Flattened
// per-lane wires (interface arrays are awkward to drive from a generate block). In an RDMA build
// there is no IQR lane, so hist_ready is tied high below and the tee degenerates to a pass-through.
localparam int IQR_ELEMS = DATABEAT_SIZE / 8;   // 8 x int64 per 512-bit beat
logic    [NUM_DECODERS-1:0]                 hist_valid;
logic    [NUM_DECODERS-1:0]                 hist_ready;
logic    [NUM_DECODERS-1:0]                 host_side_ready;
data64_t [NUM_DECODERS-1:0][IQR_ELEMS-1:0]  hist_data;
logic    [NUM_DECODERS-1:0][IQR_ELEMS-1:0]  hist_keep;
for (genvar I = 0; I < NUM_DECODERS; I++) begin
    AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
    ndata_i       #(data8_t, DATABEAT_SIZE) decoder_in(.*);
    typed_ndata_i #(DATABEAT_SIZE)          typed_out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) out(.*);
    ndata_i       #(data8_t, DATABEAT_SIZE) host_tee(.*);

`ifdef EN_RDMA
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_rreq_recv[I], axi_in)

    RDMARead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_rdma_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`else
    // AXI4SR to AXI4S
    `AXIS_ASSIGN(axis_host_recv[I], axi_in)

    LocalRead #(
        .AXI_STRM_ID(I),
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_local_read (
        .clk(clk),
        .rst_n(rst_n),

        .conf(read_conf[I]),
        .sq_rd(sq_rd_strm[I]),

        .in(axi_in),
        .out(decoder_in)
    );
`endif

    ColumnChunkDecoder #(
        .DATABEAT_SIZE(DATABEAT_SIZE)
    ) inst_column_chunk_decoder (
        .clk(clk),
        .rst_n(rst_n),

        .conf(column_chunk_conf[I]),

        .in(decoder_in),
        .out(typed_out),

        .profile(decoder_profiles[I])
    );

    // TEE. The decoded beat goes to the host (which re-streams it for pass 2) AND, when fused
    // pass 1 is enabled, to the IQR histogram feed. Both sinks must accept before the decoder
    // advances; the feed carries a per-lane skid buffer so its ready is high except when
    // genuinely backed up, which keeps this from slowing decode.
    `DATA_ASSIGN(typed_out, out);

    // Textbook tee: a beat advances only when BOTH sinks accept.
    assign out.ready     = host_side_ready[I] && hist_ready[I];
    assign hist_valid[I] = out.valid && host_side_ready[I];
    // Same 512 bits, regrouped from 64 bytes to 8 x int64; keep collapses 8 byte-lanes into one.
    assign hist_data[I]  = out.data;
    for (genvar K = 0; K < IQR_ELEMS; K++) begin : g_hist_keep
        assign hist_keep[I][K] = &out.keep[K * 8 +: 8];
    end

    NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(host_tee),
        .out(axi_out[I])
    );

    // Host branch of the tee (unchanged payload; this is what pass 2 re-streams).
    assign host_tee.data      = out.data;
    assign host_tee.keep      = out.keep;
    assign host_tee.last      = out.last;
    assign host_tee.valid     = out.valid && hist_ready[I];
    assign host_side_ready[I] = host_tee.ready;
end

`ifdef EN_RDMA
// No IQR lane in an RDMA build, so nothing consumes the histogram tee: hold every lane's ready high
// and the tee degenerates to a plain pass-through to the host.
assign hist_ready = '1;
`endif

// -- RDMA bypass stream (last stream slot, no decoder) --------------------------------------------
`ifdef EN_RDMA
localparam BYPASS_ID = NUM_STREAMS - 1;

AXI4S axi_in (.aclk(aclk), .aresetn(aresetn));
ndata_i #(data8_t, DATABEAT_SIZE) bypass_ndata();

// AXI4SR to AXI4S
`AXIS_ASSIGN(axis_rreq_recv[BYPASS_ID], axi_in)

RDMARead #(
    .AXI_STRM_ID(BYPASS_ID),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_rdma_read_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[BYPASS_ID]),
    .sq_rd(sq_rd_strm[BYPASS_ID]),    

    .in(axi_in),
    .out(bypass_ndata)
);

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_bypass (
    .clk(clk),
    .rst_n(rst_n),

    .in(bypass_ndata),
    .out(axi_out[BYPASS_ID])
);
`endif

// -- IQR_detection lane (local mode: the reserved last stream) ------------------------------------
`ifndef EN_RDMA
localparam int IQR_LANE         = NUM_STREAMS - 1;
localparam int IQR_NUM_ELEMENTS = DATABEAT_SIZE / 8;   // 8 int64 per 512-bit beat

// The decoded int64 column reaches the IQR lane from one of two sources, selected at runtime by the
// IqrConfig use_card CSR (driven below):
//   host (legacy) -- streamed in via LOCAL_READ on axis_host_recv (LocalRead drives the DMA request),
//   card/HBM       -- the host stages the column in HBM (LOCAL_OFFLOAD) and the passes LOCAL_READ it
//                     with STRM_CARD, so it arrives on axis_card_recv (receive-only, no sq_rd).
logic iqr_use_card;  // driven by inst_iqr_config.use_card

// Host source: LocalRead (DMA request + receive) -> byte ndata.
AXI4S iqr_axi_in (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[IQR_LANE], iqr_axi_in)

ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_host();
LocalRead #(
    .AXI_STRM_ID(IQR_LANE),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_iqr_local_read (
    .clk(clk),
    .rst_n(rst_n),

    .conf(read_conf[IQR_LANE]),
    .sq_rd(sq_rd_strm[IQR_LANE]),

    .in(iqr_axi_in),
    .out(iqr_bytes_host)
);

// Selected input to the operator (host or card).
ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_in();

// Card/HBM removed. It was measured at 8 MB/s with a size-independent ~1548x penalty on the READ
// path -- a fixed per-request cost, not slow memory (RESULTS.md 9.17) -- and the fused design below
// makes it unnecessary anyway: with pass 1 fed on-chip there is only one pass left to source.
// The use_card CSR is retained but ignored, so the register map and the host software are unchanged.
// EN_MEM=0 (HBM removed for WNS): the vFPGA is handed no axis_card_* ports at all -- user_logic_tmplt
// gates them on `{% if cnfg.en_mem %}` -- so these tie-offs must be `ifdef EN_MEM`-guarded too, exactly
// as Coyote's own template gates its card tie-offs. With EN_MEM defined only when nonzero (lynx_pkg),
// the whole block vanishes at EN_MEM=0 and references no absent port. N_CARD_AXI is still >=1 there.
`ifdef EN_MEM
for (genvar C = 0; C < N_CARD_AXI; C++) begin : g_iqr_card_send_tie
    always_comb axis_card_send[C].tie_off_m();
end
for (genvar C = 0; C < N_CARD_AXI; C++) begin : g_iqr_card_recv_tie
    always_comb axis_card_recv[C].tie_off_s();
end
`endif

assign iqr_bytes_in.data    = iqr_bytes_host.data;
assign iqr_bytes_in.keep    = iqr_bytes_host.keep;
assign iqr_bytes_in.last    = iqr_bytes_host.last;
assign iqr_bytes_in.valid   = iqr_bytes_host.valid;
assign iqr_bytes_host.ready = iqr_bytes_in.ready;

// data8 ndata (64 lanes) -> data64 ndata (8 lanes): same 512 bits; regroup keep (8 bytes -> 1 elem).
// This is the HOST-sourced stream. It carries pass 2 always, and pass 1 too when fusing is off.
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_host_in();
assign iqr_host_in.data   = iqr_bytes_in.data;
assign iqr_host_in.last   = iqr_bytes_in.last;
assign iqr_host_in.valid  = iqr_bytes_in.valid;
assign iqr_bytes_in.ready = iqr_host_in.ready;
for (genvar K = 0; K < IQR_NUM_ELEMENTS; K++) begin : g_iqr_keep_in
    assign iqr_host_in.keep[K] = &iqr_bytes_in.keep[K * 8 +: 8];
end

// -- Fused pass 1: the on-chip feed from the decoder lanes ----------------------------------------
logic        iqr_clear_req;   // driven by inst_iqr_config below; also re-arms the feed
logic        iqr_fuse_enable;
logic [63:0] iqr_hist_expected;
logic [63:0] iqr_fed_elements;
logic        iqr_feed_done;
logic        iqr_hist_active;   // from IQR_detection: high while it is consuming pass 1

// Step 2 (bin-index pass 2): the packed 16-bit-per-element index stream the core emits during
// HISTOGRAM, and the CSR that arms it. 512 bits per beat = 32 indices, so pass 2 re-reads 4x fewer
// beats than the value path it replaces. See hardware/src/hdl/iqr_index.sv.
logic                        iqr_idx_mode;
logic [DATABEAT_SIZE*8 - 1:0] iqr_idx_data;
logic                        iqr_idx_valid;
logic                        iqr_idx_ready;
logic                        iqr_idx_last;
logic [63:0]                 iqr_idx_beats;

// Index mode (step-2 packed-index pass 2) is RETIRED, compile-time OFF. The IqrIndex* logic in the
// core (the `idx_pack` timing cluster) is not synthesized (IQR_detection EN_INDEX=0), IqrWideFlagPack
// below is not instantiated, and the output steering folds to the value path. iqr_idx_on gates every
// index branch; with IQR_EN_INDEX=0 it is constant 0 regardless of the CSR, so a host that still sets
// idx_mode cannot engage a datapath that no longer exists. Set to 1 (and rebuild) to bring it back.
localparam bit IQR_EN_INDEX = 1'b0;
wire           iqr_idx_on   = IQR_EN_INDEX ? iqr_idx_mode : 1'b0;

// Step-2 WIDE flag output: 16 outlier bits per cycle from the core (re-widened to 32-bit indices for
// 4096 bins, build-24), packed into 512-bit words by IqrWideFlagPack. Step-2 speedup (RESULTS.md 9.21).
// Must equal IQR_detection's IDXF_LANES = 512/IDX_BITS; IDX_BITS moved 16 -> 32 for 4096 bins.
localparam int IQR_FLAGW_LANES = (DATABEAT_SIZE*8) / 32;   // 512/32 = 16
logic [IQR_FLAGW_LANES - 1:0] iqr_flagw_data;
logic [IQR_FLAGW_LANES - 1:0] iqr_flagw_keep;
logic                        iqr_flagw_valid;
logic                        iqr_flagw_ready;
logic                        iqr_flagw_last;

ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_feed_in();
IqrHistogramFeed #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS),
    .N_LANES(NUM_DECODERS)
) inst_iqr_histogram_feed (
    .clk(clk),
    .rst_n(rst_n),

    .i_enable(iqr_fuse_enable),
    .i_expected(iqr_hist_expected),
    .i_restart(iqr_clear_req),      // same pulse that zeroes the banks re-arms the element count

    .i_valid(hist_valid),
    .o_ready(hist_ready),
    .i_data(hist_data),
    .i_keep(hist_keep),

    .o_fed_elements(iqr_fed_elements),
    .o_done(iqr_feed_done),

    .out(iqr_feed_in)
);

// Pass selector. The IQR core reads BOTH passes from one port, so the source is chosen by which
// pass it is in: the on-chip feed during HISTOGRAM, the host stream during FLAG. With fusing off
// this collapses to the host stream in both passes, i.e. the legacy behaviour.
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_in();
logic iqr_take_feed;
assign iqr_take_feed = iqr_fuse_enable && iqr_hist_active;

assign iqr_in.data  = iqr_take_feed ? iqr_feed_in.data  : iqr_host_in.data;
assign iqr_in.keep  = iqr_take_feed ? iqr_feed_in.keep  : iqr_host_in.keep;
assign iqr_in.last  = iqr_take_feed ? iqr_feed_in.last  : iqr_host_in.last;
assign iqr_in.valid = iqr_take_feed ? iqr_feed_in.valid : iqr_host_in.valid;
// Park the idle source's ready low so it cannot advance while unselected.
assign iqr_feed_in.ready = iqr_take_feed ? iqr_in.ready : 1'b0;
assign iqr_host_in.ready = iqr_take_feed ? 1'b0         : iqr_in.ready;

// -- StreamProfiler taps on the IQR input (both passes) and output (flag emission) ----------------
// Free-running (stop tied low): counters accumulate over a run and re-zero on the next run's first
// beat. Host reads them via the IQR CSRs after the passes. starved => waiting on host/DMA (the
// round-trip we are optimizing); stalled => back-pressured by the output writer.
stream_profile_i iqr_profile_in();
stream_profile_i iqr_profile_out();
assign iqr_profile_in.stop  = 1'b0;
assign iqr_profile_out.stop = 1'b0;

StreamProfiler inst_iqr_profile_in (
    .clk(clk),
    .rst_n(rst_n),
    .last (iqr_in.last),
    .valid(iqr_in.valid),
    .ready(iqr_in.ready),
    .profile(iqr_profile_in)
);

// IQR config block (config 3): window CSRs in, count-loss diagnostics + debug out.
logic [63:0] iqr_bin_min, iqr_bin_shift_w, iqr_dbg_total, iqr_dbg_clear_seq;
logic [63:0] iqr_dbg_accepted, iqr_dbg_committed, iqr_dbg_flushes, iqr_dbg_collisions;
logic        iqr_is_signed;   // iqr_clear_req is declared earlier: the feed uses it
IqrConfig inst_iqr_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[3]),
    .read_config(read_configs[3]),

    .dbg_accepted(iqr_dbg_accepted),
    .dbg_committed(iqr_dbg_committed),
    .dbg_flushes(iqr_dbg_flushes),
    .dbg_collisions(iqr_dbg_collisions),
    .dbg_total(iqr_dbg_total),
    .clear_seq(iqr_dbg_clear_seq),

    .prof_in_handshakes (iqr_profile_in.counters.handshakes_cycles),
    .prof_in_starved    (iqr_profile_in.counters.starved_cycles),
    .prof_in_stalled    (iqr_profile_in.counters.stalled_cycles),
    .prof_in_idle       (iqr_profile_in.counters.idle_cycles),
    .prof_out_handshakes(iqr_profile_out.counters.handshakes_cycles),
    .prof_out_starved   (iqr_profile_out.counters.starved_cycles),
    .prof_out_stalled   (iqr_profile_out.counters.stalled_cycles),
    .prof_out_idle      (iqr_profile_out.counters.idle_cycles),

    .bin_min(iqr_bin_min),
    .bin_shift(iqr_bin_shift_w),
    .is_signed(iqr_is_signed),
    .clear_req(iqr_clear_req),
    .use_card(iqr_use_card),

    .fed_elements(iqr_fed_elements),
    .feed_done(iqr_feed_done),
    .fuse_enable(iqr_fuse_enable),
    .hist_expected(iqr_hist_expected),
    .idx_mode(iqr_idx_mode),
    .idx_beats(iqr_idx_beats)
);

ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_flags_nd();
IQR_detection #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS),
    .NUM_BINS(4096),
    .COUNT_WIDTH(32),
    .EN_INDEX(IQR_EN_INDEX)   // 0: index datapath not synthesized (value path only)
) inst_iqr_detection (
    .clk(clk),
    .rst_n(rst_n),

    .bin_min(iqr_bin_min),
    .bin_shift(iqr_bin_shift_w[$clog2($bits(data64_t) + 1) - 1:0]),
    .is_signed(iqr_is_signed),
    .clear_req(iqr_clear_req),
    .dbg_total(iqr_dbg_total),
    .dbg_clear_seq(iqr_dbg_clear_seq),
    .dbg_accepted(iqr_dbg_accepted),
    .dbg_committed(iqr_dbg_committed),
    .dbg_flushes(iqr_dbg_flushes),
    .dbg_collisions(iqr_dbg_collisions),

    .o_hist_active(iqr_hist_active),

    .i_idx_mode(iqr_idx_mode),
    .i_expected(iqr_hist_expected),   // shared with the fused feed: the column's element count
    .o_idx_data(iqr_idx_data),
    .o_idx_valid(iqr_idx_valid),
    .i_idx_ready(iqr_idx_ready),
    .o_idx_last(iqr_idx_last),
    .o_idx_beats(iqr_idx_beats),

    // Step-2 wide flag output (index mode): 16 flags/cycle (32-bit indices for 4096 bins), packed by
    // IqrWideFlagPack below.
    .o_flagw_data(iqr_flagw_data),
    .o_flagw_keep(iqr_flagw_keep),
    .o_flagw_valid(iqr_flagw_valid),
    .i_flagw_ready(iqr_flagw_ready),
    .o_flagw_last(iqr_flagw_last),

    .in(iqr_in),
    .out(iqr_flags_nd)
);

// Pack the 0/1 flags into a dense bitmask (what the host IqrRunner expects).
ndata_i #(data64_t, IQR_NUM_ELEMENTS) iqr_packed();
FlagBitPacker #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS)
) inst_iqr_flag_packer (
    .clk(clk),
    .rst_n(rst_n),

    .in(iqr_flags_nd),
    .out(iqr_packed)
);

// Step-2 WIDE packer: 32 flag bits/cycle -> 512-bit words, element e at bit e (same layout as
// FlagBitPacker), so the host reads the bitmask identically. Only fed in index mode.
logic [DATABEAT_SIZE*8 - 1:0] iqr_wpacked_data;
logic                        iqr_wpacked_valid;
logic                        iqr_wpacked_ready;
logic                        iqr_wpacked_last;
if (IQR_EN_INDEX) begin : g_iqr_wide_packer
    IqrWideFlagPack #(
        .NUM_LANES(IQR_FLAGW_LANES),
        .OUT_W(DATABEAT_SIZE*8)
    ) inst_iqr_wide_packer (
        .clk(clk),
        .rst_n(rst_n),
        .i_restart(iqr_clear_req),   // per-column clear: drop residual acc/flush state so a new column's
                                     // first word cannot inherit the previous column's bits (§9.23 leak fix)
        .i_flags(iqr_flagw_data),
        .i_keep(iqr_flagw_keep),
        .i_valid(iqr_flagw_valid),
        .o_ready(iqr_flagw_ready),
        .i_last(iqr_flagw_last),
        .o_data(iqr_wpacked_data),
        .o_valid(iqr_wpacked_valid),
        .o_ready_in(iqr_wpacked_ready),
        .o_last(iqr_wpacked_last)
    );
end else begin : g_no_iqr_wide_packer
    // Index mode compiled out: no wide packer. Tie its outputs idle; the core's i_flagw_ready is
    // ignored when EN_INDEX=0, and the output steering never selects the wide path (iqr_idx_on=0).
    assign iqr_flagw_ready   = 1'b0;
    assign iqr_wpacked_data  = '0;
    assign iqr_wpacked_valid = 1'b0;
    assign iqr_wpacked_last  = 1'b0;
end

// Profile the packed-flag output stream (back-pressure from the output writer / host DMA).
StreamProfiler inst_iqr_profile_out (
    .clk(clk),
    .rst_n(rst_n),
    .last (iqr_packed.last),
    .valid(iqr_packed.valid),
    .ready(iqr_packed.ready),
    .profile(iqr_profile_out)
);

// data64 ndata -> data8 ndata for the output writer.
//
// STEP 2: this one writer carries BOTH host-bound streams, because they are disjoint in time -- the
// index beats are emitted during HISTOGRAM (plus the packer's flush, which drains into QUARTILES)
// and the packed flags only during FLAG. Steering on iqr_idx_valid rather than on the core's state
// is what makes the flush safe: the packer holds its last beat until accepted, and a state-based
// mux would stop routing it the moment HISTOGRAM ended. The two valids are never high together, so
// the priority here never actually arbitrates.
ndata_i #(data8_t, DATABEAT_SIZE) iqr_bytes_out();
logic iqr_idx_take;
assign iqr_idx_take = iqr_idx_on && iqr_idx_valid;

// Pass-2 flag source: in index mode the WIDE packer (512-bit words, always full), else the 8-wide
// FlagBitPacker. iqr_idx_mode is a per-query constant, so exactly one of these is ever active, and
// the pass-1 index stream (iqr_idx_take) takes priority within index mode -- the two are disjoint in
// time (indices during HISTOGRAM, flags during FLAG). Steering on valid, not state, keeps each
// packer's tail flush safe.
wire                        flag2_valid = iqr_idx_on ? iqr_wpacked_valid : iqr_packed.valid;
wire                        flag2_last  = iqr_idx_on ? iqr_wpacked_last  : iqr_packed.last;

assign iqr_bytes_out.data  = iqr_idx_take ? iqr_idx_data
                           : (iqr_idx_on ? iqr_wpacked_data : iqr_packed.data);
assign iqr_bytes_out.last  = iqr_idx_take ? iqr_idx_last  : flag2_last;
assign iqr_bytes_out.valid = iqr_idx_take ? 1'b1          : flag2_valid;

assign iqr_idx_ready     = iqr_idx_take ? iqr_bytes_out.ready : 1'b0;
// Wide packer drains only in index mode when the index stream is not being routed.
assign iqr_wpacked_ready = (!iqr_idx_take &&  iqr_idx_on) ? iqr_bytes_out.ready : 1'b0;
assign iqr_packed.ready  = (!iqr_idx_take && !iqr_idx_on) ? iqr_bytes_out.ready : 1'b0;

for (genvar K = 0; K < IQR_NUM_ELEMENTS; K++) begin : g_iqr_keep_out
    // Index beats and wide-packed words are always full 512-bit words (tail zero-padded, host masks
    // against N), so keep is all ones; only the 8-wide value packer carries a per-lane keep.
    assign iqr_bytes_out.keep[K * 8 +: 8] =
        (iqr_idx_take || iqr_idx_on) ? 8'hFF : {8{iqr_packed.keep[K]}};
end

NDataToAXI #(data8_t, DATABEAT_SIZE) inst_iqr_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(iqr_bytes_out),
    .out(axi_out[IQR_LANE])
);
`endif

// -- Output writer --------------------------------------------------------------------------------
OutputWriter inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(axi_out),
    .data_out(axis_host_send)
);

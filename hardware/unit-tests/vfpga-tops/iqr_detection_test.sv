`timescale 1ns / 1ps

import oasis::*;
import parcore::*;

// -----------------------------------------------------------------------------------------------
// Oasis-native IQR_detection unit-test top.
//
// Port of celeris/hardware/unit-tests/vfpga_tops/iqr_detection_test.sv to oasis conventions: it
// instantiates the self-contained IQR_detection operator (pulled from the celeris submodule) and
// wires it with oasis/parcore's own libstf types + adapters (data64_t, ndata_i, AXIToNDataTyped,
// NDataToAXITyped, StreamConfig) -- so it does NOT pull in celeris's libstf and there are no
// package collisions.
//
// Two-pass flow (host streams the column twice on host stream 0):
//   pass 1 (HISTOGRAM) -> IQR_detection builds the histogram + derives Q1/Q3 fences in hardware
//   pass 2 (FLAG)      -> re-stream the column; IQR_detection emits the 0/1 outlier column
//
// Window params are compile-time constants here (overridable per test via defines); the host-CSR
// path is exercised in the production top, not this unit test.
// -----------------------------------------------------------------------------------------------

// -- IQR_detection parameters (mirrored in iqr_detection_test.py) --------------------------------
`ifdef IQR_NUM_BINS_OVERWRITE
localparam int IQR_NUM_BINS = `IQR_NUM_BINS_OVERWRITE;
`else
localparam int IQR_NUM_BINS = 16;
`endif

`ifdef IQR_BIN_SHIFT_OVERWRITE
localparam int IQR_BIN_SHIFT = `IQR_BIN_SHIFT_OVERWRITE;
`else
localparam int IQR_BIN_SHIFT = 0;
`endif

`ifdef IQR_BIN_MIN_OVERWRITE
localparam int IQR_BIN_MIN = `IQR_BIN_MIN_OVERWRITE;
`else
localparam int IQR_BIN_MIN = 0;
`endif

`ifdef IQR_IS_SIGNED_OVERWRITE
localparam int IQR_IS_SIGNED = `IQR_IS_SIGNED_OVERWRITE;
`else
localparam int IQR_IS_SIGNED = 0;     // default: unsigned (non-negative test data)
`endif

// 64-bit values, 512-bit AXI beat -> 8 values per beat (matches CELERIS_NUM_TUPLES in celeris).
localparam int IQR_NUM_ELEMENTS = AXI_DATA_BITS / 64;

// -- Tie-off unused interfaces and signals -------------------------------------------------------
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

// Only the first host stream carries input values.
for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end

// Card/HBM streams are unused by this operator; tie them off so their tvalid is defined (the coyote
// AXI monitor fatals on an undriven tvalid). Mirrors the production vfpga_top.svh tie-off.
for (genvar C = 0; C < N_CARD_AXI; C++) begin : g_card_send_tie
    always_comb axis_card_send[C].tie_off_m();
end
for (genvar C = 0; C < N_CARD_AXI; C++) begin : g_card_recv_tie
    always_comb axis_card_recv[C].tie_off_s();
end

// -- Fix clock and reset names -------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration: one StreamConfig for the input data type -------------------------------------
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(OASIS_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({2})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

stream_config_i stream_config[1](.*);
StreamConfig #(
    .NUM_STREAMS(1)
) inst_stream_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(stream_config)
);

// The data type is written once but consumed by the input adapter on every transfer's last beat.
// Because the host sends the column twice, latch the type and hold it valid for both passes.
type_t latched_type;
logic  type_valid;

assign stream_config[0].select_ready    = 1'b1;
assign stream_config[0].data_type_ready = ~type_valid;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        type_valid   <= 1'b0;
        latched_type <= INT32_T;
    end else if (stream_config[0].data_type_valid && ~type_valid) begin
        latched_type <= stream_config[0].data_type_data;
        type_valid   <= 1'b1;
    end
end

ready_valid_i #(type_t) in_data_type();
ready_valid_i #(type_t) out_data_type();

assign in_data_type.data   = latched_type;
assign in_data_type.valid  = type_valid;
assign out_data_type.data  = latched_type;
assign out_data_type.valid = type_valid;

// -- Input: AXI -> ndata -------------------------------------------------------------------------
AXI4S axi_host_recv_0(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0) // AXI4SR to AXI4S

ndata_i #(data64_t, IQR_NUM_ELEMENTS) values();
AXIToNDataTyped #(
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS)
) inst_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in_type(in_data_type),

    .in(axi_host_recv_0),
    .out(values)
);

// -- IQR_detection (histogram -> quartiles -> outlier mask) --------------------------------------
data64_t     iqr_dbg_total_sim;
ndata_i #(data64_t, IQR_NUM_ELEMENTS) masked();
IQR_detection #(
    .value_t(data64_t),
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS),
    .NUM_BINS(IQR_NUM_BINS),
    .COUNT_WIDTH(32)
) inst_iqr_detection (
    .clk(clk),
    .rst_n(rst_n),

    .bin_min  (data64_t'(IQR_BIN_MIN)),
    .bin_shift(($clog2($bits(data64_t) + 1))'(IQR_BIN_SHIFT)),
    .is_signed(IQR_IS_SIGNED[0]),

    // Sim relies on reset + the end-of-pass self-clear; the host clear pulse is tied off.
    .clear_req(1'b0),
    .dbg_total(iqr_dbg_total_sim),
    .dbg_clear_seq(),

    .in(values),
    .out(masked)
);

// -- Histogram count-loss probe (sim-only diagnostic) --------------------------------------------
// Independently count pass-1 input values off the IQR input handshake and compare against the
// device's dbg_total. Equal => the histogram store kept every count.
int unsigned sim_pass1_values;
logic        sim_pass1_done;
always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        sim_pass1_values <= 0;
        sim_pass1_done   <= 1'b0;
    end else if (!sim_pass1_done && values.valid && values.ready) begin
        sim_pass1_values <= sim_pass1_values + $countones(values.keep);
        if (values.last) sim_pass1_done <= 1'b1;
    end
end
final begin
    $display("[SIM-PROBE] pass1 input values = %0d, IQR dbg_total = %0d  (%s)",
             sim_pass1_values, iqr_dbg_total_sim,
             (sim_pass1_values == iqr_dbg_total_sim) ? "OK: no count loss"
                                                     : "LEAK: histogram lost counts");
end

// -- Output: ndata -> AXI ------------------------------------------------------------------------
AXI4S axi_out[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));
NDataToAXITyped #(
    .NUM_ELEMENTS(IQR_NUM_ELEMENTS)
) inst_data_to_axi (
    .clk(clk),
    .rst_n(rst_n),
    .out_type(out_data_type),
    .in(masked),
    .out(axi_out[0])
);

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axi_out[I].tie_off_m();
end

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    `AXIS_ASSIGN(axi_out[I], axis_host_send[I])
end

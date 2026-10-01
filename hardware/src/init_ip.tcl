# Select the correct ILA IP for the target architecture.
# NOTE: On Versal (e.g. V80) the IP is called axis_ila instead of ila,
#       and the versioned -version flag of the UltraScale+ ila core does not apply.
if {$cfg(fpga_arch) eq "ultrascale_plus"} {
    set ila_ip_name "ila"
    set ila_create_args [list -name ila -vendor xilinx.com -library ip -version 6.2]
} elseif {$cfg(fpga_arch) eq "versal"} {
    set ila_ip_name "axis_ila"
    set ila_create_args [list -name axis_ila -vendor xilinx.com -library ip]
} else {
    puts "ERROR: Unsupported FPGA architecture: $cfg(fpga_arch)"
    exit 1
}

create_ip {*}$ila_create_args -module_name ila_rdma_read
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {18} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {128} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {76} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {76} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {64} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {64} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
] [get_ips ila_rdma_read]

# IQR count-loss debug ILA: traces the FULL life of `total` (per-bank reads -> 3-stage reduction
# -> accumulator -> quartiles -> fences -> host CSR) so the count-loss never needs another bitgen
# to localize. Only instantiated when IQR_detection.sv defines IQR_DEBUG_ILA; created here
# unconditionally (an unused IP is harmless, matching ila_rdma_read on --no-rdma builds). Probe
# widths MUST match the module-level ila_iqr instance in hardware/iqr_app/hdl/IQR_detection.sv at
# NUM_BINS=1024 (BIN_IDX_WIDTH=10, COUNT_WIDTH=32, VALUE_WIDTH=64). If you change NUM_BINS, update
# scan_cnt(2)/q1_bin(14)/q3_bin(15) widths to the new $clog2(NUM_BINS) [+1 for scan_cnt].
# ILA #1 -- SCAN/SUM path. Full 8->4->2->1 reduction (all 8 bank reads + every reduction node)
# + quartile/fence context. Widths MUST match inst_ila_iqr in IQR_detection.sv at NUM_BINS=1024
# (BIN_IDX_WIDTH=10, COUNT_WIDTH=32 -> red=35, VALUE_WIDTH=64 -> fence=67).
create_ip {*}$ila_create_args -module_name ila_iqr
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {31} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {2}  \
    CONFIG.C_PROBE1_WIDTH {1}  \
    CONFIG.C_PROBE2_WIDTH {11} \
    CONFIG.C_PROBE3_WIDTH {1}  \
    CONFIG.C_PROBE4_WIDTH {1}  \
    CONFIG.C_PROBE5_WIDTH {2}  \
    CONFIG.C_PROBE6_WIDTH {10} \
    CONFIG.C_PROBE7_WIDTH {1}  \
    CONFIG.C_PROBE8_WIDTH {10} \
    CONFIG.C_PROBE9_WIDTH {32}  \
    CONFIG.C_PROBE10_WIDTH {32} \
    CONFIG.C_PROBE11_WIDTH {32} \
    CONFIG.C_PROBE12_WIDTH {32} \
    CONFIG.C_PROBE13_WIDTH {32} \
    CONFIG.C_PROBE14_WIDTH {32} \
    CONFIG.C_PROBE15_WIDTH {32} \
    CONFIG.C_PROBE16_WIDTH {32} \
    CONFIG.C_PROBE17_WIDTH {35} \
    CONFIG.C_PROBE18_WIDTH {35} \
    CONFIG.C_PROBE19_WIDTH {35} \
    CONFIG.C_PROBE20_WIDTH {35} \
    CONFIG.C_PROBE21_WIDTH {35} \
    CONFIG.C_PROBE22_WIDTH {35} \
    CONFIG.C_PROBE23_WIDTH {35} \
    CONFIG.C_PROBE24_WIDTH {32} \
    CONFIG.C_PROBE25_WIDTH {32} \
    CONFIG.C_PROBE26_WIDTH {10} \
    CONFIG.C_PROBE27_WIDTH {10} \
    CONFIG.C_PROBE28_WIDTH {67} \
    CONFIG.C_PROBE29_WIDTH {67} \
    CONFIG.C_PROBE30_WIDTH {64} \
] [get_ips ila_iqr]

# ILA #2 -- per-bank READ-MODIFY-WRITE path, banks 0..3. 7 common context probes, then 14 probes
# per bank: beat(1) lane_idx_q(10) acc_bin(10) acc_cnt(32) acc_valid(1) fl_we(1) fl_bin(10)
# fl_delta(32) s1_we(1) s1_bin(10) s1_delta(32) rd_q(32) raddr(10) hazard_hit(1). Widths MUST match
# inst_ila_iqr_rmw in IQR_detection.sv. ALL 8 banks (was 0-3) so build-07's marginal bank
# can't hide. Depth 1024 spans pass-1 binning + drain + early scan (action fits in <100 samples).
create_ip {*}$ila_create_args -module_name ila_iqr_rmw
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {127} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {2} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {4} \
    CONFIG.C_PROBE6_WIDTH {11} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {10} \
    CONFIG.C_PROBE9_WIDTH {10} \
    CONFIG.C_PROBE10_WIDTH {32} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {10} \
    CONFIG.C_PROBE14_WIDTH {32} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {10} \
    CONFIG.C_PROBE17_WIDTH {32} \
    CONFIG.C_PROBE18_WIDTH {32} \
    CONFIG.C_PROBE19_WIDTH {10} \
    CONFIG.C_PROBE20_WIDTH {1} \
    CONFIG.C_PROBE21_WIDTH {1} \
    CONFIG.C_PROBE22_WIDTH {10} \
    CONFIG.C_PROBE23_WIDTH {10} \
    CONFIG.C_PROBE24_WIDTH {32} \
    CONFIG.C_PROBE25_WIDTH {1} \
    CONFIG.C_PROBE26_WIDTH {1} \
    CONFIG.C_PROBE27_WIDTH {10} \
    CONFIG.C_PROBE28_WIDTH {32} \
    CONFIG.C_PROBE29_WIDTH {1} \
    CONFIG.C_PROBE30_WIDTH {10} \
    CONFIG.C_PROBE31_WIDTH {32} \
    CONFIG.C_PROBE32_WIDTH {32} \
    CONFIG.C_PROBE33_WIDTH {10} \
    CONFIG.C_PROBE34_WIDTH {1} \
    CONFIG.C_PROBE35_WIDTH {1} \
    CONFIG.C_PROBE36_WIDTH {10} \
    CONFIG.C_PROBE37_WIDTH {10} \
    CONFIG.C_PROBE38_WIDTH {32} \
    CONFIG.C_PROBE39_WIDTH {1} \
    CONFIG.C_PROBE40_WIDTH {1} \
    CONFIG.C_PROBE41_WIDTH {10} \
    CONFIG.C_PROBE42_WIDTH {32} \
    CONFIG.C_PROBE43_WIDTH {1} \
    CONFIG.C_PROBE44_WIDTH {10} \
    CONFIG.C_PROBE45_WIDTH {32} \
    CONFIG.C_PROBE46_WIDTH {32} \
    CONFIG.C_PROBE47_WIDTH {10} \
    CONFIG.C_PROBE48_WIDTH {1} \
    CONFIG.C_PROBE49_WIDTH {1} \
    CONFIG.C_PROBE50_WIDTH {10} \
    CONFIG.C_PROBE51_WIDTH {10} \
    CONFIG.C_PROBE52_WIDTH {32} \
    CONFIG.C_PROBE53_WIDTH {1} \
    CONFIG.C_PROBE54_WIDTH {1} \
    CONFIG.C_PROBE55_WIDTH {10} \
    CONFIG.C_PROBE56_WIDTH {32} \
    CONFIG.C_PROBE57_WIDTH {1} \
    CONFIG.C_PROBE58_WIDTH {10} \
    CONFIG.C_PROBE59_WIDTH {32} \
    CONFIG.C_PROBE60_WIDTH {32} \
    CONFIG.C_PROBE61_WIDTH {10} \
    CONFIG.C_PROBE62_WIDTH {1} \
    CONFIG.C_PROBE63_WIDTH {1} \
    CONFIG.C_PROBE64_WIDTH {10} \
    CONFIG.C_PROBE65_WIDTH {10} \
    CONFIG.C_PROBE66_WIDTH {32} \
    CONFIG.C_PROBE67_WIDTH {1} \
    CONFIG.C_PROBE68_WIDTH {1} \
    CONFIG.C_PROBE69_WIDTH {10} \
    CONFIG.C_PROBE70_WIDTH {32} \
    CONFIG.C_PROBE71_WIDTH {1} \
    CONFIG.C_PROBE72_WIDTH {10} \
    CONFIG.C_PROBE73_WIDTH {32} \
    CONFIG.C_PROBE74_WIDTH {32} \
    CONFIG.C_PROBE75_WIDTH {10} \
    CONFIG.C_PROBE76_WIDTH {1} \
    CONFIG.C_PROBE77_WIDTH {1} \
    CONFIG.C_PROBE78_WIDTH {10} \
    CONFIG.C_PROBE79_WIDTH {10} \
    CONFIG.C_PROBE80_WIDTH {32} \
    CONFIG.C_PROBE81_WIDTH {1} \
    CONFIG.C_PROBE82_WIDTH {1} \
    CONFIG.C_PROBE83_WIDTH {10} \
    CONFIG.C_PROBE84_WIDTH {32} \
    CONFIG.C_PROBE85_WIDTH {1} \
    CONFIG.C_PROBE86_WIDTH {10} \
    CONFIG.C_PROBE87_WIDTH {32} \
    CONFIG.C_PROBE88_WIDTH {32} \
    CONFIG.C_PROBE89_WIDTH {10} \
    CONFIG.C_PROBE90_WIDTH {1} \
    CONFIG.C_PROBE91_WIDTH {1} \
    CONFIG.C_PROBE92_WIDTH {10} \
    CONFIG.C_PROBE93_WIDTH {10} \
    CONFIG.C_PROBE94_WIDTH {32} \
    CONFIG.C_PROBE95_WIDTH {1} \
    CONFIG.C_PROBE96_WIDTH {1} \
    CONFIG.C_PROBE97_WIDTH {10} \
    CONFIG.C_PROBE98_WIDTH {32} \
    CONFIG.C_PROBE99_WIDTH {1} \
    CONFIG.C_PROBE100_WIDTH {10} \
    CONFIG.C_PROBE101_WIDTH {32} \
    CONFIG.C_PROBE102_WIDTH {32} \
    CONFIG.C_PROBE103_WIDTH {10} \
    CONFIG.C_PROBE104_WIDTH {1} \
    CONFIG.C_PROBE105_WIDTH {1} \
    CONFIG.C_PROBE106_WIDTH {10} \
    CONFIG.C_PROBE107_WIDTH {10} \
    CONFIG.C_PROBE108_WIDTH {32} \
    CONFIG.C_PROBE109_WIDTH {1} \
    CONFIG.C_PROBE110_WIDTH {1} \
    CONFIG.C_PROBE111_WIDTH {10} \
    CONFIG.C_PROBE112_WIDTH {32} \
    CONFIG.C_PROBE113_WIDTH {1} \
    CONFIG.C_PROBE114_WIDTH {10} \
    CONFIG.C_PROBE115_WIDTH {32} \
    CONFIG.C_PROBE116_WIDTH {32} \
    CONFIG.C_PROBE117_WIDTH {10} \
    CONFIG.C_PROBE118_WIDTH {1} \
    CONFIG.C_PROBE119_WIDTH {32} \
    CONFIG.C_PROBE120_WIDTH {32} \
    CONFIG.C_PROBE121_WIDTH {32} \
    CONFIG.C_PROBE122_WIDTH {32} \
    CONFIG.C_PROBE123_WIDTH {32} \
    CONFIG.C_PROBE124_WIDTH {32} \
    CONFIG.C_PROBE125_WIDTH {32} \
    CONFIG.C_PROBE126_WIDTH {32} \
] [get_ips ila_iqr_rmw]

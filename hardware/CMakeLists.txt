cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of ColumnChunkDecoders. The number of streams is equal to this in local mode. If RDMA is 
# enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)
set(EN_STRM 1)

# Card-memory (HBM) streams DISABLED. The IQR datapath never used HBM -- the vFPGA tied the card
# interfaces off (the card read path was a dead end, RESULTS.md 9.17) -- so this removes ~40,010 LUTs
# and ~67,194 FFs of dead silicon (build-27 553,061 LUTs -> build-26 513,051).
#
# HISTORY, so nobody re-runs the old experiment and draws the old conclusion: removing HBM under
# `place_design -directive SSI_BalanceSLRs` made WNS WORSE by 0.66-0.68 ns (build-23 -1.879 vs
# build-25 -2.562; build-27 -1.496 vs build-26 -2.154). The controller was acting as an accidental
# FLOORPLAN ANCHOR pinning a block in SLR0; without it BalanceSLRs scattered the four ~77k-LUT
# ColumnChunkDecoders across SLR boundaries (worst path crossed 4). That penalty was measured ONLY
# under BalanceSLRs. Forcing `SSI_SpreadSLLs` instead (see pnr_shell.tcl.in) anchors the floorplan
# DELIBERATELY -- it allocates extra area to high-connectivity regions, which is what the decoders
# actually needed -- and is worth +0.338 ns on its own. So the anchor hack is no longer needed.
#
# ⚠️ BUILD WITH `OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs`. Without it the ML predictor picks BalanceSLRs
# and this HBM-out config re-measures the old, wrong ~-2.15 answer.
#
# N_CARD_AXI stays 1: it is Coyote's minimum, because the generated wrapper declares
# [N_CARD_AXI-1:0] ranges and 0 makes that [-1:0] (Synth 8-2908, "range width must be a positive
# integer"). The vfpga_top.svh card tie-offs are `ifdef EN_MEM`-guarded (EN_MEM is #defined only when
# nonzero, lynx_pkg_tmplt), so at EN_MEM=0 they compile out along with the vFPGA's card ports.
set(EN_MEM 0)
set(N_CARD_AXI 1)

if(ENABLE_RDMA)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_RDMA 1)
    set(N_RDMA_AXI ${N_STREAMS})
    set(N_STRM_AXI ${N_STREAMS})
else()
    set(EN_RDMA 0)
    # Local mode (sim): reserve one extra stream past the decoders for the IQR_detection lane.
    math(EXPR N_STRM_AXI "${N_DECODERS} + 1")
endif()

# Build with optimization, since timing closure can be difficult.
#
# BUILD_OPT=1 is what turns on the slow Vivado directives at EVERY stage (opt_design -Explore,
# place_design -Auto_1, phys_opt/route -AggressiveExplore) *and* the post-route phys_opt_design pass,
# which BUILD_OPT=0 skips entirely. Measured on build-16: ~9 h at 1. Expect ~4-5 h at 0, for roughly
# 0.2-0.5 ns less slack.
#
# Plain set(), not a cache entry: find_package(CoyoteHW) above already seeded BUILD_OPT=0 in the
# cache, so a CACHE form here would never take effect. Hence the separate user-facing switch.
#
# Use -DOASIS_FAST_BUILD=ON (or scripts/synthesize.sh --fast) for iteration bitstreams; leave it OFF
# for anything whose timing numbers get reported. A fast build places and routes DIFFERENTLY, so it
# needs its own pass through the correctness gates rather than inheriting another build's.
option(OASIS_FAST_BUILD "Skip the slow Vivado directives: ~half the build time, worse WNS" OFF)

set(COMP_CORES 64)
if(OASIS_FAST_BUILD)
    set(BUILD_OPT 0)
    message(STATUS "OASIS_FAST_BUILD=ON -> BUILD_OPT=0 (fast directives, expect worse WNS)")
else()
    set(BUILD_OPT 1)
endif()

# Target FPGA device (override with -DFDEV_NAME=v80 for the Alveo V80)
set(FDEV_NAME u55c CACHE STRING "Target FPGA device (u55c, v80, ...)")

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src iqr_app"
)

create_hw()

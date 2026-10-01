#!/usr/bin/env bash
# Standalone xsim run for tb_iqr_bins4096.sv -- IQR_detection at NUM_BINS=4096, driven directly
# through the raw ndata interfaces (no coyote shell / AXI monitors). Functional gate for the
# 1024->4096 bin change: a taxi_d3-style fence cluster that 4096 bins resolve (300 outliers) and
# 1024 bins miss (0). Flip NUM_BINS to 1024 in the TB and this run FAILS -- the revert check.
#
#   module load vivado/2024.2      # or: source /tools/Xilinx/Vivado/2024.2/settings64.sh
#   hardware/unit-tests/run_bins4096_tb.sh
#
# IQR_detection's count-loss ILAs are behind `ifdef IQR_DEBUG_ILA (left undefined here).
set -euo pipefail

ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/bins4096_tb.$$"

command -v xvlog >/dev/null || { echo "xvlog not on PATH -- run: module load vivado/2024.2" >&2; exit 2; }

LYNX=$(ls -t "$ROOT"/hardware/build-*/oasis_shell/hdl/lynx_pkg.sv 2>/dev/null | head -1)
[[ -f "$LYNX" ]] || { echo "no generated lynx_pkg.sv found under hardware/build-*" >&2; exit 2; }

mkdir -p "$WORK"; cd "$WORK"

xvlog -sv -i "$LIBSTF" -i "$ROOT/hardware/iqr_app/hdl" \
    "$LYNX" \
    "$LIBSTF/common.sv" \
    "$LIBSTF/data_interfaces.sv" \
    "$LIBSTF/util/reset_resync.sv" \
    "$ROOT/hardware/src/hdl/iqr_index.sv" \
    "$ROOT/hardware/src/hdl/iqr_index_stream.sv" \
    "$ROOT/hardware/iqr_app/hdl/IQR_detection.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_bins4096.sv"

xelab -debug typical tb_iqr_bins4096 -s bins4096_tb
xsim bins4096_tb -runall

echo "workdir: $WORK"

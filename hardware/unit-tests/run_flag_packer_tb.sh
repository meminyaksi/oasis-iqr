#!/usr/bin/env bash
# Standalone xsim run for tb_flag_bit_packer.sv -- the flag stream -> dense bitmask packer.
#
#   module load vivado/2024.2
#   hardware/unit-tests/run_flag_packer_tb.sh
#
# FlagBitPacker lives inside IQR_detection.sv (deliberately -- see the comment there), so that
# file is compiled for it. Its ILAs are behind `ifdef IQR_DEBUG_ILA, left undefined here.
set -euo pipefail

ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/packer_tb.$$"

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
    "$ROOT/hardware/unit-tests/tb_flag_bit_packer.sv"

xelab -debug typical tb_flag_bit_packer -s packer_tb
xsim packer_tb -runall

echo "workdir: $WORK"

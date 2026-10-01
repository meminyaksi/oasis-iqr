#!/usr/bin/env bash
# Standalone xsim run for tb_iqr_histogram_feed.sv.
#
#   module load vivado/2024.2      # 2023.2 has the mixed-language `fifo ... DEPTH` elaboration bug
#   hardware/unit-tests/run_feed_tb.sh
#
# Deliberately NOT wired into the Coyote unit-test framework: IqrHistogramFeed needs no shell, no
# CSRs and no DMA, so compiling three libstf files plus the DUT gets an answer in seconds instead of
# minutes. Exit status is the verdict.
set -euo pipefail

ROOT="${OASIS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LIBSTF="$ROOT/parcore/libstf/hardware/src/hdl"
WORK="${TMPDIR:-/tmp}/feed_tb.$$"

command -v xvlog >/dev/null || { echo "xvlog not on PATH -- run: module load vivado/2024.2" >&2; exit 2; }

# libstf's common.sv imports Coyote's lynxTypes, which is GENERATED per build from
# coyote/hw/templates/common/lynx_pkg_tmplt.txt -- there is no checked-in copy. Borrow the one from
# the newest completed build rather than re-running the generator; only widths are needed here.
LYNX=$(ls -t "$ROOT"/hardware/build-*/oasis_shell/hdl/lynx_pkg.sv 2>/dev/null | head -1)
[[ -f "$LYNX" ]] || { echo "no generated lynx_pkg.sv found under hardware/build-*/oasis_shell/hdl" >&2; exit 2; }

mkdir -p "$WORK"
cd "$WORK"

xvlog -sv -i "$LIBSTF" \
    "$LYNX" \
    "$LIBSTF/common.sv" \
    "$LIBSTF/data_interfaces.sv" \
    "$LIBSTF/util/reset_resync.sv" \
    "$ROOT/hardware/src/hdl/iqr_histogram_feed.sv" \
    "$ROOT/hardware/unit-tests/tb_iqr_histogram_feed.sv"

xelab -debug typical tb_iqr_histogram_feed -s feed_tb
xsim feed_tb -runall

echo "workdir: $WORK"

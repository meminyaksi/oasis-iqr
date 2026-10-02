#!/bin/bash
# FPGA vs CPU IQR execution time on the 7 real datasets (the paper's real-dataset figure).
#
# Per dataset and arm: 1 warm-up + N timed runs in one DuckDB session, end-to-end query time
# (.timer "real"), median. The query aggregates the flags (count of outliers) instead of storing them,
# so DuckDB's single-threaded table append is not measured. CPU arm = iqr_cpu_flags_groupby (exact
# quartiles). Speedup = CPU / FPGA.
#
# Usage:  scripts/run_real.sh [DATASET_DIR]      (default ~/datasets; N=15 by default)
# Needs:  extension/build/release/duckdb built, FPGA programmed, 1 GiB huge pages reserved.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUCK="$ROOT/extension/build/release/duckdb"
DS="${1:-$HOME/datasets}"
N="${N:-15}"
THREADS="${THREADS:-32}"

export LD_LIBRARY_PATH="$HOME/opt/lib:${LD_LIBRARY_PATH:-}"
export OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16
unset OASIS_IQR_IDX_PASS2 OASIS_IQR_TIMING

# file stem, column, row count, label in the figure
DATASETS=(
    "taxi_d1            fare_cents  3.0M   taxi_d1"
    "tpch_qty           v           6.0M   tpch_qty"
    "taxi_d2            fare_cents  6.0M   taxi_d2"
    "tpch_extprice      v           6.0M   extprice"
    "taxi_d3            fare_cents  13.1M  taxi_d3"
    "taxi_d4            fare_cents  20.3M  taxi_d4"
    "tpch_extprice_sf10 v           60.0M  sf10"
)

# Runs one query 1+N times; prints "<median seconds> <outlier count>".
measure() {
    local q="$1" out
    out=$( { echo "PRAGMA threads=$THREADS;"; echo ".mode list"; echo ".headers off"; echo ".timer on"
             for _ in $(seq 0 "$N"); do echo "$q"; done; } | "$DUCK" 2>&1 )
    local med cnt
    med=$(echo "$out" | grep -oP 'Run Time \(s\): real \K[0-9.]+' | tail -n +2 | sort -n |
          awk '{a[NR]=$1} END {if (NR==0) print "nan"; else print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}')
    cnt=$(echo "$out" | grep -E '^[0-9]+$' | tail -1)
    echo "${med:-nan} ${cnt:-nan}"
}

printf "%-16s %7s %10s %10s %9s\n" "dataset" "rows" "CPU (ms)" "FPGA (ms)" "speedup"
warnings=()
for d in "${DATASETS[@]}"; do
    read -r name col rows label <<< "$d"
    f="$DS/$name.parquet"
    if [ ! -f "$f" ]; then
        warnings+=("$name: missing $f (skipped)")
        continue
    fi
    cat "$f" > /dev/null    # warm the page cache

    read -r fpga_s fpga_cnt <<< "$(measure "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('$f','$col');")"
    read -r cpu_s  cpu_cnt  <<< "$(measure "SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('$f','$col');")"

    awk -v l="$label" -v r="$rows" -v c="$cpu_s" -v g="$fpga_s" \
        'BEGIN { printf "%-16s %7s %10.1f %10.1f %8.2fx\n", l, r, c*1000, g*1000, (g>0 ? c/g : 0) }'

    # Correctness: the FPGA's 4096-bin quartiles may differ slightly from the exact CPU result.
    # Anything above 1% of the rows is not quantisation and must be looked at.
    if [[ "$fpga_cnt" =~ ^[0-9]+$ && "$cpu_cnt" =~ ^[0-9]+$ ]]; then
        diff=$(( fpga_cnt > cpu_cnt ? fpga_cnt - cpu_cnt : cpu_cnt - fpga_cnt ))
        total=$(awk -v r="${rows%M}" 'BEGIN { printf "%d", r * 1e6 }')
        if [ "$diff" -gt $(( total / 100 )) ]; then
            warnings+=("$name: FPGA flagged $fpga_cnt rows, CPU $cpu_cnt -- check before using this row")
        fi
    else
        warnings+=("$name: a query failed (FPGA='$fpga_cnt' CPU='$cpu_cnt'); rerun it by hand to see the error")
    fi
done

for w in "${warnings[@]}"; do echo "WARNING: $w" >&2; done

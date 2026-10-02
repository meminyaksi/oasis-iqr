# Oasis -- Data Processing SmartNIC

Oasis is a data processing SmartNIC for cloud-native data lakes. It offloads Parquet decoding into
the network data path. The main components are a hardware design that embeds 
[ParCore](https://github.com/celeris-labs/parcore) into an RDMA-enabled 
[Coyote](https://github.com/fpgasystems/Coyote) vFPGA and a software abstraction for easy 
integration into query engines.

The hardware component requires the ParCore submodule and its dependencies to be loaded by either 
cloning this repo with submodules directly:

```bash
git clone --recurse-submodules git@github.com:celeris-labs/oasis.git
```

Or initializing the submodule as a step after cloning:

```bash
git submodule update --init extension/duckdb
git submodule update --init extension/extension-ci-tools
git submodule update --init --recursive parcore
git submodule update --init celeris
```

## Hardware
The functionality of the hardware component can be verified with unit tests that are built on top of 
the Coyote unit test framework. We also describe how to synthesize the hardware.

### Unit tests
To run the unit tests, the Vivado simulation project needs to be set up:

```bash
./scripts/setup_simulation.sh
```

After this is finished, VSCode shows the unit tests as a test flask on the left side. The simulation
project needs to be regenerated whenever new files are added (also for the dependencies).

### Synthesis
For synthesis, execute the following command:

```bash
./scripts/synthesize.sh [--no-rdma] [--decoders <number-of-decoders>]
```

The script spins off the synthesis in the background in a way that the user can disconnect from 
the server without the synthesis stopping. You can check the progress in `hardware/build-**/bitgen.log`. 
It is expected that the synthesis takes multiple hours to finish sometimes not printing anything new 
to the log for a while.

## Software
The software consists of the Oasis software library and a DuckDB extension.

### Oasis library
The Oasis software library has dependencies on the Coyote, libSTF, and ParCore software libraries to 
be installed or includes them from the submodules. In case they are not installed already, libSTF 
also has a dependency on jemalloc that can be installed with `./parcore/libstf/scripts/install_jemalloc.sh` 
and ParCore currently has a dependency on Arrow 21.0.0 which can be installed with `./parcore/scripts/install_arrow.sh`. 
The Oasis software library can be built as follows:

```bash
mkdir software/build
cmake -S software -B software/build
cmake --build software/build -j
```

If you want to install it to e.g., `~/opt`, you need to add `-DCMAKE_INSTALL_PREFIX=$HOME/opt` to 
the first `cmake` command and execute `cmake --install software/build` after the build.

### DuckDB extension
The DuckDB Oasis extension can be built as follows and requires the Oasis software library to be 
installed first:

```bash
cd extension
make -j
```

More detail can be found in the `extension/README.md`.

## IQR outlier detection operator

This repository adds an FPGA IQR (interquartile range) outlier detector to Oasis. For one 64-bit
integer Parquet column, the FPGA decodes the column, builds a 4096-bin histogram, computes the
quartiles and the fences (`Q1 - 1.5*IQR`, `Q3 + 1.5*IQR`) on chip, and flags every row. The flags
come back to the host as a packed 1-bit-per-row bitmask.

**To reproduce the IQR results, follow this section from top to bottom.** It is self-contained:
it covers cloning, building, programming the FPGA with the provided bitstream, generating the
datasets, and running the benchmark. Nothing has to be configured beyond what is written here.

### SQL functions

Both take `(path VARCHAR, column VARCHAR)` for a `BIGINT`/`UBIGINT` Parquet column and return one
`BOOLEAN` column `is_outlier`, one row per input row:

| function | what it runs |
|---|---|
| **`iqr_flags_only(path, column)`** | **the FPGA operator**: Parquet decode, histogram, quartiles, fences and flags on the FPGA |
| **`iqr_cpu_flags_groupby(path, column)`** | **the CPU baseline**: DuckDB's Parquet reader + exact quartiles in C++ (GROUP BY / ORDER BY) |

```sql
SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_flags_only('data.parquet', 'v');
SELECT count(*) FILTER (WHERE is_outlier) FROM iqr_cpu_flags_groupby('data.parquet', 'v');
```

`iqr_flags_only` chooses its path from the column's row count. There are no settings or
environment variables:
- **fewer than 30M rows:** the decoded column is gathered in host memory, the histogram window is
  derived from it, and it is streamed to the IQR core twice (histogram pass, flag pass).
- **30M rows or more:** fused. The window is derived from 16 row groups decoded on the FPGA, pass 1
  runs on chip while the column decodes, and only the flag pass crosses PCIe.

| part | files |
|---|---|
| IQR operator RTL | `hardware/iqr_app/hdl/IQR_detection.sv` |
| CSR block, fused histogram feed | `hardware/src/hdl/iqr_config.sv`, `hardware/src/hdl/iqr_histogram_feed.sv` |
| index-mode RTL (compiled out with `EN_INDEX=0`, still needed for elaboration) | `hardware/src/hdl/iqr_index.sv`, `hardware/src/hdl/iqr_index_stream.sv` |
| production vFPGA top | `hardware/src/vfpga_top.svh` |
| host driver | `software/oasis/iqr_runner.*`, `software/oasis/iqr_config.hpp`, `software/oasis/bypass_receiver.*` |
| DuckDB table functions | `extension/src/oasis_iqr.cpp` |
| real-dataset benchmark | `scripts/run_real.sh` |
| RTL testbenches | `hardware/unit-tests/run_*_tb.sh`, `hardware/unit-tests/tb_*.sv` |

### 1. Requirements

- A **Xilinx Alveo U55C** on an ETH HACC node (the programming script uses `/opt/hdev/cli`, `sudo`
  and Vivado on `PATH`). Build the software on the build server; program the card and run on the
  alveo node (home directory shared).
- CMake **≥ 3.25** (`pip install --user "cmake>=3.28"` and `export PATH=$HOME/.local/bin:$PATH`).
- The bitstream **`cyt_top_b29_po.bit`**, which is provided separately (md5
  `11e35b5d31309520855283075de5ee49`). It was built from this repository's RTL with
  `--no-rdma --decoders 4`, without HBM (`EN_MEM=0`), and with 4096 bins.

### 2. Clone

Clone **without** `--recurse-submodules` and initialise only the submodules below (the `celeris`
submodule is not used by the build):
```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
git clone https://github.com/meminyaksi/oasis-iqr.git && cd oasis-iqr
git submodule update --init extension/duckdb extension/extension-ci-tools
git submodule update --init --recursive parcore
```

### 3. Build the software (build server)

The DuckDB extension links the libraries installed under `~/opt`, so install them first. ParCore
builds without Arrow by default, so Arrow is not needed.
```bash
bash parcore/libstf/scripts/install_jemalloc.sh          # installs jemalloc into ~/opt
export CMAKE_PREFIX_PATH=$HOME/opt
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
cmake --build software/build -j && cmake --install software/build   # Coyote, libstf, ParCore, Oasis
(cd extension && make -j)                                # -> extension/build/release/duckdb
```
After any later change in `software/` or `parcore/`, re-run the `cmake --install` step before
rebuilding the extension. The extension uses the installed copy, not the source tree.

### 4. Program the FPGA (alveo node)

The driver must be built on the node, because it is built for the running kernel.
```bash
(cd parcore/libstf/coyote/driver && make)
bash parcore/libstf/coyote/util/program_hacc_local.sh /path/to/cyt_top_b29_po.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages   # programming clears them
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages               # must print 8
lsmod | grep coyote_driver && ls /dev/coyote*
```
`hdev set hugepages` can report success without reserving anything; write the sysfs file directly
as above.

### 5. Generate the datasets (once, ~740 MB)

Use the stock `duckdb` Python module (`pip install --user duckdb`), not the extension-linked binary,
which aborts at startup on a machine without 1 GiB huge pages. Do not set `ROW_GROUP_SIZE`: the
default row-group layout is part of the real data.
```bash
mkdir -p ~/datasets && cd ~/datasets
for m in 01 02 03 04 05 06; do
  curl -fL -o ytd_2024_${m}.parquet \
    "https://d37ci6vc6kj4l6.cloudfront.net/trip-data/yellow_tripdata_2024-${m}.parquet"
done
python3 - <<'EOF'
import duckdb
c = duckdb.connect()
files = lambda ms: "[" + ",".join(f"'ytd_2024_{m}.parquet'" for m in ms) + "]"
for name, ms in [("taxi_d1", ["01"]), ("taxi_d2", ["01", "02"]),
                 ("taxi_d3", ["01", "02", "03", "04"]),
                 ("taxi_d4", ["01", "02", "03", "04", "05", "06"])]:
    c.sql(f"COPY (SELECT round(fare_amount*100)::BIGINT AS fare_cents FROM read_parquet({files(ms)})) "
          f"TO '{name}.parquet' (FORMAT PARQUET)")
c.sql("INSTALL tpch; LOAD tpch; CALL dbgen(sf=1)")
c.sql("COPY (SELECT l_quantity::BIGINT AS v FROM lineitem) TO 'tpch_qty.parquet' (FORMAT PARQUET)")
c.sql("COPY (SELECT (l_extendedprice*100)::BIGINT AS v FROM lineitem) TO 'tpch_extprice.parquet' (FORMAT PARQUET)")
c = duckdb.connect()
c.sql("INSTALL tpch; LOAD tpch; CALL dbgen(sf=10)")
c.sql("COPY (SELECT (l_extendedprice*100)::BIGINT AS v FROM lineitem) TO 'tpch_extprice_sf10.parquet' (FORMAT PARQUET)")
EOF
```
Check that each file holds the expected data with
`SELECT count(*), sum(<column>)::HUGEINT FROM read_parquet('<file>')`, where the column is
`fare_cents` for the taxi files and `v` for the TPC-H files:

| file | rows | sum |
|---|--:|--:|
| `taxi_d1.parquet` | 2,964,624 | 5388222476 |
| `taxi_d2.parquet` | 5,972,150 | 10815993187 |
| `taxi_d3.parquet` | 13,069,067 | 24176275770 |
| `taxi_d4.parquet` | 20,332,093 | 38401520485 |
| `tpch_qty.parquet` | 6,001,215 | 153078795 |
| `tpch_extprice.parquet` | 6,001,215 | 22957731090120 |
| `tpch_extprice_sf10.parquet` | 59,986,052 | 229381315677336 |

If the NYC TLC files have been re-issued, the taxi rows will differ.

### 6. Run the benchmark (alveo node)

```bash
scripts/run_real.sh ~/datasets
```
For each dataset this runs both functions once to warm up and then 15 times in one DuckDB session
(`PRAGMA threads=32`), and reports the median end-to-end query time. The queries aggregate the flags
(`count(*) FILTER (WHERE is_outlier)`), so storing the result is not measured. The run takes a few
minutes. Only one DuckDB process may use the card at a time. Do not interrupt an FPGA query with
Ctrl-C.

The output is one table:
```
dataset             rows   CPU (ms)  FPGA (ms)   speedup
taxi_d1             3.0M        ...        ...      ...x
...
sf10               60.0M        ...        ...      ...x
```
A `WARNING:` line after the table means a dataset file is missing, a query failed, or the FPGA and
CPU outlier counts differ by more than 1% of the rows. The FPGA's 4096-bin histogram gives slightly
different counts from the exact CPU result, but never by that much.

**Reference values.** These are earlier measurements of the same configuration, on an earlier
bitstream with the same design (4 decoders, 4096 bins). Expect the same shape, with a deviation of
about 10–20%:

| dataset | rows | CPU (ms) | FPGA (ms) | speedup |
|---|--:|--:|--:|--:|
| taxi_d1 | 3.0M | 16 | 14 | 1.14× |
| tpch_qty | 6.0M | 32 | 21 | 1.52× |
| taxi_d2 | 6.0M | 33 | 21 | 1.57× |
| extprice | 6.0M | 89 | 28 | 3.18× |
| taxi_d3 | 13.1M | 56 | 40 | 1.40× |
| taxi_d4 | 20.3M | 79 | 59 | 1.34× |
| sf10 | 60.0M | 332 | 150 | 2.21× |

The FPGA should be faster on every dataset, with the largest margins on extprice and sf10.

### Troubleshooting

| symptom | cause |
|---|---|
| an error about 1GiB huge pages at startup | re-run the `nr_hugepages` line in step 4 (programming clears them) |
| the extension fails to configure (Coyote/libstf/parcore/oasis not found) | `export CMAKE_PREFIX_PATH=$HOME/opt` and re-run step 3 |
| `iqr_flags_only` fails to find the IQR config block | the card holds a bitstream without the IQR lane (e.g. built with RDMA); the IQR lane exists only in `--no-rdma` builds |
| sf10 aborts with `fused pass 1 did not complete` or `fused pass 1 histogram total ... != ... elements` | the on-chip feed miscounted; reprogram the card and re-run |
| FPGA times several times higher than the reference (e.g. sf10 ~400 ms) | the bitstream was built with 1 decoder instead of 4 |

### Building the bitstream (only if not using the provided one)

The IQR lane exists only in local (non-RDMA) builds. The production configuration is
`N_DECODERS=4`, `EN_MEM=0`, `EN_RDMA=0`, 4096 bins. A build takes about 9–11 hours.

1. Apply the Coyote place-directive patch (Coyote is a third-party submodule, so the change is kept
   as a patch). It adds an `OASIS_PLACE_DIRECTIVE` override to `place_design`:
   ```bash
   cd parcore/libstf/coyote
   git apply ../../../patches/coyote-pnr_shell-SSI_SpreadSLLs.patch
   ```
2. Synthesize. `--no-rdma` and `--decoders 4` are both required (the script defaults to 1 decoder):
   ```bash
   export OASIS_PLACE_DIRECTIVE=SSI_SpreadSLLs
   ./scripts/synthesize.sh --no-rdma --device u55c --decoders 4
   grep -m1 "OASIS: place_design" hardware/build-NN/bitgen.log   # confirms the directive was used
   ```
3. Run the post-route phys_opt ladder on the routed design. The production bitstream
   (`cyt_top_b29_po.bit`, WNS −0.518 ns) is the output of this step, not of step 2 alone. Each
   directive is kept only if it improves setup slack without breaking hold:
   ```bash
   cp hardware/pnr/physopt_iterate.tcl hardware/build-NN/ && cd hardware/build-NN
   TERM=xterm vivado -mode batch -source physopt_iterate.tcl   # writes bitstreams/cyt_top_b29_po.bit
   ```
   Timing does not fully close (negative WNS), so a new build places and routes differently from the
   production one. Check its outlier counts against the CPU baseline before trusting its numbers.

### RTL testbenches

Each script needs Vivado (`xvlog`) on `PATH` and a configured `hardware/build-*` directory (for the
generated `lynx_pkg.sv`):
```bash
bash hardware/unit-tests/run_flag_packer_tb.sh
bash hardware/unit-tests/run_bins4096_tb.sh
bash hardware/unit-tests/run_feed_tb.sh
bash hardware/unit-tests/run_fused_integration_tb.sh
```

## License
The Oasis code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libstf will be accepted under the terms of the same license.
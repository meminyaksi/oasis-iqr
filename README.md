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
This repository adds an FPGA IQR (interquartile range) outlier-detection operator to Oasis. The
Parquet column is decoded on the FPGA, a 4096-bin histogram is built on chip, the quartiles and the
fences (`Q1 - 1.5*IQR`, `Q3 + 1.5*IQR`) are computed on chip, and every row is classified in a second
pass. The flags come back to the host as a packed 1-bit-per-row bitmask.

| part | files |
|---|---|
| IQR operator RTL | `hardware/iqr_app/hdl/IQR_detection.sv` |
| CSR block, fused histogram feed | `hardware/src/hdl/iqr_config.sv`, `hardware/src/hdl/iqr_histogram_feed.sv` |
| index-mode RTL (compiled out with `EN_INDEX=0`, still needed for elaboration) | `hardware/src/hdl/iqr_index.sv`, `hardware/src/hdl/iqr_index_stream.sv` |
| production vFPGA top | `hardware/src/vfpga_top.svh` |
| host driver | `software/oasis/iqr_runner.*`, `software/oasis/iqr_config.hpp`, `software/oasis/bypass_receiver.*` |
| DuckDB table functions | `extension/src/oasis_iqr.cpp` |
| RTL testbenches | `hardware/unit-tests/run_*_tb.sh`, `hardware/unit-tests/tb_*.sv` |
| co-simulation example | `examples/iqr_sim/` |

### Building the bitstream
The IQR lane exists only in local (non-RDMA) builds. The production configuration is
`N_DECODERS=4`, `EN_MEM=0`, `EN_RDMA=0`, 4096 bins.

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

### Programming the FPGA
```bash
cd parcore/libstf/coyote/driver && make && cd -
bash parcore/libstf/coyote/util/program_hacc_local.sh \
     hardware/build-NN/bitstreams/cyt_top_b29_po.bit \
     parcore/libstf/coyote/driver/build/coyote_driver.ko 1
echo 8 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
```

### Running
The extension links the *installed* Oasis library, so reinstall it before rebuilding the extension
after any change in `software/` or `parcore/`:
```bash
cmake -S software -B software/build -DCMAKE_INSTALL_PREFIX=$HOME/opt -DCMAKE_PREFIX_PATH=$HOME/opt
cmake --build software/build -j && cmake --install software/build
cd extension && make -j && cd build/release
export LD_LIBRARY_PATH=$HOME/opt/lib:$LD_LIBRARY_PATH
./duckdb -c "SELECT * FROM iqr_flags('file.parquet', 'bigint_col') LIMIT 20;"
```

Table functions: `iqr_flags(path, col)` (value + `is_outlier`), `iqr_flags_only(path, col)`,
the CPU baseline `iqr_cpu_flags_groupby` (exact quartiles), and `iqr_profiler()` /
`decoder_profiler()`.

The evaluated configuration enables the fused path, where pass 1 (the histogram) runs on chip during
decode. Fusion engages only for columns with at least `OASIS_IQR_FUSE_MIN_ROWS` rows (default 6M);
smaller columns use the non-fused path.
```bash
export OASIS_IQR_STREAM=1 OASIS_IQR_FUSE=1 OASIS_IQR_WINDOW_FPGA=1 OASIS_IQR_DECODE_WINDOW=16
```

### Real-dataset benchmark
`scripts/run_real.sh [DATASET_DIR]` measures the FPGA operator against the CPU baseline on the seven
real datasets and prints one table: CPU and FPGA end-to-end time (median of 15 warm runs) and the
speedup, with `(fused)` on the datasets that ran fused. It sets the fused configuration above itself.
Any dataset whose FPGA and CPU outlier counts differ by more than 1% of its rows is reported as a
warning after the table.

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
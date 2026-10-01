#include "oasis_iqr.hpp"

#include "coalesced_fetcher.hpp"
#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/parallel/task_scheduler.hpp"
#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis_context_cache_entry.hpp"
#include "parcore/configuration.hpp"
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <vector>

namespace duckdb {

// ---------------------------------------------------------------------------------------------
// iqr_flags(path VARCHAR, column VARCHAR)
//
// A *pipeline-breaking* table function (like ORDER BY / a global aggregate): the IQR operator needs
// the whole column before it can flag any row (the quartiles are global), so the work is done once,
// up front, and the results are then streamed out as (value, is_outlier) rows.
//
// M2a (this file): the SQL surface -- bind/schema, registration, and the emit + bitmask-unpack loop.
// The heavy phase (decode the column across all row groups + run the IQR two passes) is the seam
// filled in M2b; for now it throws so the function still binds and is visible in DuckDB.
// ---------------------------------------------------------------------------------------------

namespace {

struct IqrFlagsBindData : public TableFunctionData {
    string      filename;
    string      column_name;
    idx_t       column_id = DConstants::INVALID_INDEX; // index of the target column in the file
    LogicalType column_type;                           // its type (must be a 64-bit integer)
    bool        is_signed = true;                      // BIGINT -> signed, UBIGINT -> unsigned

    // Parsed footer, captured at bind time. The CPU path builds one ParquetReader per worker and
    // hands each this cache so the footer is parsed once, not once per thread.
    shared_ptr<ParquetFileMetadataCache> parquet_metadata;

    // iqr_flags echoes the value column back, so it needs the decoded column gathered contiguously.
    // iqr_flags_only emits just the bitmask and therefore never has to see the values at all, which
    // is what makes the streaming path below legal for it.
    bool needs_values = true;
};

// Global state shared across DuckDB workers. iqr_flags is a pipeline breaker: the heavy phase (decode
// + the IQR passes) runs once, in InitGlobal, before any worker starts. *Emission* is then embarrassingly
// parallel -- `values` and `flags` are fully materialized, read-only, and every row is independent --
// so workers claim disjoint STANDARD_VECTOR_SIZE slices off an atomic cursor. Emitting serially
// (the old MaxThreads == 1) cost 81 ms of the 144 ms taxi_d4 query, more than the FPGA work itself.
struct IqrFlagsGlobalState : public GlobalTableFunctionState {
    std::shared_ptr<libstf::Buffer> values; // decoded int64 column (N elements), for the value output
    std::shared_ptr<libstf::Buffer> flags;  // packed outlier bitmask (1 bit/element)
    size_t                          num_elements = 0;
    std::atomic<size_t>             cursor {0}; // next element to claim

    // DuckDB clamps parallelism to min(MaxThreads(), scheduler threads). One worker per output chunk.
    idx_t MaxThreads() const override {
        return MaxValue<idx_t>(1, (num_elements + STANDARD_VECTOR_SIZE - 1) / STANDARD_VECTOR_SIZE);
    }
};

// No per-worker state: emission reads only the shared, immutable `values`/`flags` buffers.
struct IqrFlagsLocalState : public LocalTableFunctionState {};

// Wraps one fetched compressed column-chunk slice as a LocalSourceOperator. Copies the bytes into a
// fresh memory-pool buffer (the simple, always-correct path; the zero-copy aligned-slice path in
// oasis_scan.cpp is an optimization we can adopt later).
std::unique_ptr<oasis::SourceOperator> MakeHostSourceCopy(oasis::OasisContext &ctx,
                                                          const CoalescedFetcher::RangeView &view) {
    void *ptr = nullptr;
    auto  st  = ctx.memory_pool()->allocate(view.size, &ptr);
    if (!st.ok()) {
        throw IOException("iqr_flags: could not allocate input buffer: " + st.message());
    }
    std::memcpy(ptr, view.data(), view.size);
    auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, view.size, view.size);
    return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
}

// How many row groups to keep in flight on the decoder(s). Must be at least (decoder lanes x
// scheduler pipeline depth) to keep every lane fed; larger costs memory (one sink buffer per group
// in flight) and buys nothing. OASIS_IQR_DECODE_WINDOW=1 restores the old submit-and-block shape,
// which is useful for measuring what the pipelining is worth.
size_t decode_window() {
    static const size_t window = [] {
        const char *env = std::getenv("OASIS_IQR_DECODE_WINDOW");
        if (env) {
            long v = std::strtol(env, nullptr, 10);
            if (v >= 1) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(8);
    }();
    return window;
}

// A non-owning view of `[off, off+size)` inside `owner`. The FPGA can write straight into it, so a
// row group's decoded values land in their final place in the column buffer with no copy. The
// deleter frees only the Buffer struct and keeps `owner` alive for as long as any slice of it is.
std::shared_ptr<libstf::Buffer> MakeSlice(const std::shared_ptr<libstf::Buffer> &owner, size_t off,
                                          size_t size, size_t capacity) {
    auto *view = new libstf::Buffer {static_cast<std::byte *>(owner->ptr) + off, size, capacity};
    return std::shared_ptr<libstf::Buffer>(view, [owner](libstf::Buffer *p) { delete p; });
}

size_t RoundUpToTransfer(size_t bytes) {
    const size_t unit = libstf::BYTES_PER_FPGA_TRANSFER;
    return ((std::max<size_t>(bytes, 1) + unit - 1) / unit) * unit;
}

// Wall-clock phase breakdown, printed to stderr when OASIS_IQR_TIMING=1. Wall clock only: the FPGA's
// StreamProfiler counters accumulate for the life of the bitstream and cannot time a single query.
bool timing_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_TIMING");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

using TimingClock = std::chrono::steady_clock;
double ms_since(TimingClock::time_point t) {
    return std::chrono::duration<double, std::milli>(TimingClock::now() - t).count();
}

// Where the decode phase's wall clock goes. `wait` is the only part the FPGA controls: it is time
// spent blocked on a row group the decoder has not finished. Everything else is host work that the
// pipelining is meant to hide behind it.
struct DecodeTiming {
    double fetch_ms  = 0.0; // read compressed bytes (page cache) into a pooled buffer
    double submit_ms = 0.0; // build the flow, allocate the sink, hand it to the scheduler
    double wait_ms   = 0.0; // blocked on the FPGA finishing a row group
    double copy_ms   = 0.0; // memcpy decoded values into the column buffer (0 on the zero-copy path)
    size_t groups    = 0;
    bool   zero_copy = false;
    bool   streamed  = false; // handed the per-group buffers to IqrRunner instead of gathering them
};

// OASIS_IQR_STREAM=1 passes the per-row-group decoded buffers straight to IqrRunner instead of
// gathering them into one contiguous column, removing the host memcpy entirely.
//
// This is legal because IqrRunner::run() already takes a *vector* of chunks and concatenates them
// logically, asserting `last` only on the final one -- the gather was never a device requirement,
// only a convenience. It is off by default because the first attempt (measured on the 1-decoder
// build-11) was a wash: the copy saving was cancelled by ~27 ms of extra decode wait from holding
// every sink buffer to the end. With more decoder lanes the decode-side penalty shrinks while the
// copy saving does not, so the trade-off is worth re-measuring per bitstream.
bool stream_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_STREAM");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// OASIS_IQR_OVERLAP=1 drives the IQR histogram (pass 1) DURING decode instead of after it, so that
// heavy = max(decode, pass1) + pass2 rather than decode + pass1 + pass2. Requires the streaming path
// (the per-group buffers must survive to be re-streamed for pass 2) and is therefore implied to be
// off whenever OASIS_IQR_STREAM is off.
//
// The bins must be fixed before the first pass-1 beat, so the window comes from DeriveWindowSpanning()
// (a host-side sample across uniformly-spaced row groups) rather than from the decoded column. The
// first implementation derived it from a PREFIX instead and was catastrophically wrong on
// order-dependent data -- 19,997,999 of 20,000,000 rows flagged against a true answer of 200. See
// RESULTS.md 9.15, and re-run bench/overlap_ab.sh accuracy after touching any of this.
// OASIS_IQR_FUSE=1 arms the RTL to feed the histogram straight from the decoder output, so pass 1
// costs no PCIe traffic and no host time at all. Needs a bitstream with IqrHistogramFeed (build-15
// onwards); on an older bitstream the fuse CSRs are ignored and pass 1 would never terminate, so the
// runner's histogram_total check catches it rather than silently returning wrong flags.
// Unlike OASIS_IQR_OVERLAP this does NOT require the streaming sink -- the tee is in hardware.
bool fuse_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_FUSE");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// OASIS_IQR_IDX_PASS2=1 makes pass 2 re-read packed 16-bit bin indices the FPGA emitted during
// pass 1 instead of the 64-bit value column -- 4x less PCIe traffic at bit-identical results
// (RESULTS.md 9.19 / tb_iqr_idx_mode). Requires a bitstream with the idx_mode CSR (register 7);
// on an older one the register is ignored and pass 2 would misread indices as values, which the
// histogram_total check does NOT catch. Off by default, and only meaningful with OASIS_IQR_FUSE=1
// since it rides the same begin_fused/finish_fused path.
bool idx_pass2_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_IDX_PASS2");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

bool overlap_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_OVERLAP");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// Callback invoked by DecodeColumnAllGroups on the streaming path: once with the total element count
// before any group decodes, then once per decoded chunk in column order. Lets the caller feed the
// IQR histogram pass while the remaining groups are still decoding.
struct DecodeHooks {
    // (total_elements, streaming): `streaming` is the FINAL per-file sink decision, not the env
    // var. The software overlap needs the streaming sink and must bail when it is false, or it
    // would arm pass 1 and then wait forever for chunks that are never fed.
    std::function<void(size_t total_elements, bool streaming)>                on_start;
    std::function<void(const std::shared_ptr<libstf::Buffer> &, size_t, bool)> on_chunk;
};

// Number of histogram bins baked into the bitstream. Must match IqrRunner::NUM_BINS and the vFPGA
// top's IQR_NUM_BINS -- the window is only meaningful relative to it.
constexpr int64_t IQR_HW_NUM_BINS = 4096;

// Defined below; declared here for DeriveWindowSpanning.
template <typename F>
void ParallelRanges(size_t n, size_t nthreads, F &&fn);

// How many row groups the window sample spans. 16 is the MINIMUM SAFE value: at 8, taxi_d1
// regresses from 1247 outliers to 1348 (§9.15.1).
//
// Raising it above 16 was tried and REJECTED (build-16, 2026-07-23). 48 groups fixes taxi_d3
// (fpga_vs_cpp 31791 -> 162) but every extra group is another group decoded twice, so it taxes the
// datasets that actually benefit from fusing:
//
//   dataset | unfused | fused @16 grp    | fused @48 grp
//   taxi_d3 | 32.9 ms | 33.0 ms  WRONG   | ~42 ms  correct   <- gains nothing from fusing either way
//   taxi_d4 | 49.6 ms | 40.6 ms  correct | 51.6 ms correct
//   sf10    |169.6 ms |137.2 ms  correct |152.9 ms correct
//
// taxi_d3 does not benefit from fusion at ANY group count, so paying for it globally is a bad
// trade. It is excluded by the streaming-sink gate instead (see the fuse decision in RunHeavyPhase),
// which gets it a free, exact, full-column window.
//
// Sample DENSITY is not the lever either: 2048 -> 32768 values per group returned the identical
// answer on taxi_d3 (1296479) while win_derive went 4.72 -> 20.32 ms. Coverage matters, resolution
// does not.
size_t window_groups() {
    static const size_t k = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_GROUPS");
        if (e) {
            long v = std::strtol(e, nullptr, 10);
            if (v > 0) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(16);
    }();
    return k;
}

// Row count below which fusing pass 1 is a NET LOSS, so the legacy path is used instead.
//
// Fusion deletes pass 1, worth ~0.64 ms per million rows (8 bytes/row at the measured 12.5 GB/s).
// But the histogram window must be sized BEFORE the first beat, and that sample is a roughly FIXED
// cost (~9-19 ms). Below the break-even the window costs more than the pass it saves. Measured
// end-to-end ratios, build-16, fused+FPGA window vs the same bitstream unfused:
//
//   taxi_d1   3.0M   1.67x -> 1.27x   LOST    (saved ~2 ms, paid ~9)
//   extprice  6.0M   1.00x -> 0.86x   LOST    (saved ~4 ms, paid ~9)
//   taxi_d3  13.1M   0.82x -> 0.86x   won
//   taxi_d4  20.3M   0.78x -> 0.90x   won
//   sf10     60.0M   0.85x -> 1.06x   won
//
// This is the same fixed-cost-vs-scaling-benefit arithmetic that keeps OASIS_IQR_OVERLAP off
// (§9.15.1). RAISED 10M -> 30M (build-21, 2026-07-27): once the ragged stitch let taxi_d3/d4 actually
// fuse, medians showed fusion is a wall-clock LOSS at their sizes (op 36->43 / 54->62 ms) though a
// CPU-seconds win (~2x). It only wins latency at sf10 scale (60M, §9.19). 30M keeps taxi_d3 (13M) and
// taxi_d4 (20M) on the latency-optimal memcpy path while sf10+ still fuses. Fusion is verified per-row
// exact for taxi when it does engage (obstacle-1 fixed).
// LOWERED 30M -> 6M (build-29): the 36->43 / 54->62 ms taxi loss above was measured on build-21, which
// was synthesized with 1 decode lane instead of 4. On build-29 (4 lanes) the size sweep (micro_bench.md
// Test 1) measures the fused/unfused break-even at 6M rows, with fusion ahead at every size above it
// (20M: 2.32x vs 1.79x over the CPU baseline). 6M is also the threshold Tests 2-5 ran with.
size_t fuse_min_rows() {
    static const size_t n = [] {
        const char *e = std::getenv("OASIS_IQR_FUSE_MIN_ROWS");
        if (e) {
            long long v = std::strtoll(e, nullptr, 10);
            if (v >= 0) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(6000000);
    }();
    return n;
}

// OASIS_IQR_WINDOW_FPGA=1 takes the window sample from the FPGA decoder instead of decompressing it
// on the host. See DeriveWindowFromFpga() for why that is worth doing. Off by default so the fused
// bitstream can be validated against the window path that is already trusted.
bool window_fpga_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_FPGA");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// TEST ONLY (OASIS_IQR_FORCE_STREAM=1): bypass the ragged-chunk streaming guard so taxi_d3/d4 can be
// FUSED for measurement. The pass-2 flag packer is bit-misaligned on ragged chunks, so per-row flags
// are WRONG -- but the OUTLIER COUNT is preserved (raggedness shifts positions, not the number of set
// bits), and the count is exactly the window-accuracy signal we want to sweep. NEVER enable for real
// output; it produces mislabeled rows.
bool force_stream() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_FORCE_STREAM");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();
    return on;
}

// OASIS_IQR_STREAM_RAGGED=1 lifts the ragged-chunk streaming guard the CORRECT way: taxi_d3/d4 (odd-
// sized row groups) stream/fuse, and IqrRunner folds the byte-padded-per-chunk flag output back into a
// dense bitmask (has_intermediate_ragged / repack_ragged_flags), so per-row flags are RIGHT -- unlike
// force_stream(), which only preserves the count. Off by default until validated on silicon (the byte-
// alignment of each chunk in the packed stream, which the stitch assumes, holds iff consecutive stream
// transfers are beat-aligned; confirm with the taxi 3-way correctness test before making it default).
// DEFAULT-ON (build-21, 2026-07-27): the host-side ragged stitch (repack_ragged_flags) is proven
// per-row exact on taxi_d3/d4 (net_diff == per_row_mismatch: 104/104 and 0/0). So a fused taxi-shaped
// (odd-row-group) column fuses correctly instead of falling to memcpy. Set OASIS_IQR_STREAM_RAGGED=0
// to force the old memcpy fallback. (No effect at default settings until FUSE is enabled and rows>=6M.)
bool stream_ragged_enabled() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_STREAM_RAGGED");
        return !e || !(e[0] == '0' || e[0] == 'f' || e[0] == 'F' || e[0] == 'n' || e[0] == 'N');
    }();
    return on;
}

// OASIS_IQR_WINDOW_IQR=1 sizes the histogram window from the sample's INTERQUARTILE spread
// [Q1-2*IQR, Q3+2*IQR] instead of its [p1, p99] range. The p1/p99 range is tail-dominated on
// heavy-tailed columns, so ceil(range/IQR_HW_NUM_BINS) lands on a power-of-2 boundary and bin_shift flips with the
// sample (taxi_d3's count is bistable 1296479<->1328108 across group counts). Basing the width on the
// IQR -- the quantity actually being resolved, from the densest/most stable percentiles -- keeps the
// bins fine and stable. Off by default until validated against the trusted window path.
// DEFAULT-ON (build-21, 2026-07-27): validated to fix taxi_d3 (31,496 -> 104) and taxi_d4 (-> exact) at
// 4096 bins with no regression on d1/d2/tpch/extprice/sf10, and overlap 200/200 on ov_uniform/ov_drift.
// Set OASIS_IQR_WINDOW_IQR=0 to fall back to the old p1/p99 span.
bool window_iqr_rule() {
    static const bool on = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_IQR");
        return !e || !(e[0] == '0' || e[0] == 'f' || e[0] == 'F' || e[0] == 'n' || e[0] == 'N');
    }();
    return on;
}

// How many values to keep per sampled row group. Raising this is NEARLY FREE on the FPGA window
// path: DeriveWindowFromFpga already decodes each picked group in full, so a denser stride costs no
// extra decode -- only the percentile step, which is O(n) (see WindowFromSample). Contrast with
// window_groups(), where every extra group is another group decoded twice: at 48 groups taxi_d4's
// fused operator went 40.6 -> 51.6 ms and sf10's 137.2 -> 152.9 ms, for accuracy gains only taxi_d3
// needed. Resolution is the cheap axis; coverage is the expensive one.
size_t window_samples_per_group() {
    static const size_t n = [] {
        const char *e = std::getenv("OASIS_IQR_WINDOW_SAMPLES");
        if (e) {
            long v = std::strtol(e, nullptr, 10);
            if (v > 0) {
                return static_cast<size_t>(v);
            }
        }
        return static_cast<size_t>(2048);
    }();
    return n;
}

// The one place the (sample -> bin_min, bin_shift) rule lives. Both window derivations feed it, so
// they cannot drift apart: whichever way the sample was collected, identical values must produce an
// identical window. Same rule as IqrRunner::derive_window -- robust percentiles, NOT min/max, so a
// stray outlier cannot blow up the bin width (footer min/max was tried and is degenerate: taxi_d4
// spans -128540..33407632, which makes 4096 bins 8192 wide while the fares live in 0..5000).
// Consumes `sample` (sorts it in place). Returns false if there is nothing usable to measure.
bool WindowFromSample(std::vector<int64_t> &sample, int64_t &bin_min_out, uint64_t &bin_shift_out) {
    if (sample.size() < 2) {
        return false;
    }
    // nth_element, not sort. Only two order statistics are needed (p1 and p99), and selection is
    // O(n) against sort's O(n log n) -- which is what lets the sample be dense enough to place the
    // window accurately. With a full sort, 16 groups x 32768 values would cost ~30 ms of host CPU
    // and defeat the purpose of moving the sample onto the FPGA in the first place.
    // The two selections compose: after the p1 pass everything below k1 sits left of it, so the p99
    // selection only has to partition the remaining suffix.
    const size_t m  = sample.size();

    // Choose the span the window must cover. Default: robust [p1, p99]. With OASIS_IQR_WINDOW_IQR:
    // [Q1-2*IQR, Q3+2*IQR] from p25/p75, which ties bin width to the IQR and removes the power-of-2
    // bistability (see window_iqr_rule()). Falls back to p1/p99 when the IQR is degenerate.
    int64_t lo, hi;
    bool    used_iqr = false;
    if (window_iqr_rule()) {
        const size_t k25 = m / 4;
        const size_t k75 = std::min(m - 1, m * 3 / 4);
        std::nth_element(sample.begin(), sample.begin() + k25, sample.end());
        const int64_t q1 = sample[k25];
        if (k25 + 1 <= k75) {
            std::nth_element(sample.begin() + k25 + 1, sample.begin() + k75, sample.end());
        }
        const int64_t q3  = sample[k75];
        const int64_t iqr = q3 - q1;
        if (iqr > 0) {
            lo       = q1 - 2 * iqr;   // covers the +-1.5*IQR fences plus a 0.5*IQR estimation margin
            hi       = q3 + 2 * iqr;
            used_iqr = true;
        }
    }
    if (!used_iqr) {
        const size_t k1  = m * 1 / 100;
        const size_t k99 = std::min(m - 1, m * 99 / 100);
        std::nth_element(sample.begin(), sample.begin() + k1, sample.end());
        lo = sample[k1];
        // k1 < k99 for every m >= 2, so the suffix range is non-empty; guard anyway rather than risk
        // UB on an unexpected input.
        if (k1 + 1 <= k99) {
            std::nth_element(sample.begin() + k1 + 1, sample.begin() + k99, sample.end());
        }
        hi = sample[k99];
    }

    const int64_t range = hi - lo;
    if (range <= 0) {
        bin_min_out   = lo;
        bin_shift_out = 0;
        return true;
    }

    uint64_t width = static_cast<uint64_t>((range + IQR_HW_NUM_BINS - 1) / IQR_HW_NUM_BINS);
    uint64_t shift = 0;
    while ((1ull << shift) < width) {
        ++shift;
    }
    const int64_t binw = static_cast<int64_t>(1ull << shift);

    // Floor-align the low edge to a bin boundary (correct for negative lo too).
    bin_min_out   = (lo >= 0) ? (lo / binw) * binw : -(((-lo) + binw - 1) / binw) * binw;
    bin_shift_out = shift;
    return true;
}

// Derives the histogram window (bin_min, bin_shift) WITHOUT the decoded column in hand, so pass 1 can
// be started before decode finishes. Returns false if no usable sample could be taken, in which case
// the caller must fall back to the serial path.
//
// WHY THIS SHAPE. Three cheaper sources were tried or considered and all fail:
//   * a PREFIX of the decoded column -- measured, and catastrophic: on order-drifting data the bins
//     span only the early range, everything later clamps into the top bin, Q3 collapses and the
//     fences flag 19,997,999 of 20,000,000 rows (RESULTS.md 9.15).
//   * parquet footer min/max -- present on every row group of every dataset here, but NOT robust:
//     taxi_d4 spans -128540..33407632, so 4096 bins are 8192 wide while the fares themselves live
//     in 0..5000. Every value lands in bin 0 => q1 == q3 => IQR 0 => degenerate fences.
//   * a percentile over the per-group footer min/max -- no better, because outliers are spread
//     across essentially every row group (taxi_d4 is 10 % outliers), so every group's max is extreme.
// What is actually needed is real values drawn from ACROSS the file. Reading the first DataChunk of
// a handful of uniformly-spaced row groups costs a few ms of host CPU, spans the column by
// construction, and feeds the same robust p1/p99 rule IqrRunner::derive_window already uses.
bool DeriveWindowSpanning(ClientContext &context, const IqrFlagsBindData &bind, int64_t &bin_min_out,
                          uint64_t &bin_shift_out) {
    const size_t k_groups = window_groups();

    ParquetOptions parquet_opts(context);
    ParquetReader  probe(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(probe);

    std::vector<size_t> live;
    for (size_t g = 0; g < meta.groups.size(); g++) {
        if (meta.groups[g].chunks[bind.column_id].num_values > 0) {
            live.push_back(g);
        }
    }
    if (live.empty()) {
        return false;
    }

    // Uniformly spaced groups, always including the first and last: drift is monotonic in row order,
    // so the extremes of the file are exactly the points a prefix sample misses.
    const size_t        k = std::min(k_groups, live.size());
    std::vector<size_t> picks;
    picks.reserve(k);
    for (size_t i = 0; i < k; i++) {
        picks.push_back(live[(k == 1) ? 0 : (i * (live.size() - 1)) / (k - 1)]);
    }
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());

    // The groups are sampled in PARALLEL. Serially this cost 51.6 ms on sf10 (3.2 ms per group --
    // pulling one DataChunk still forces a full page decompress), which is MORE than the ~38 ms the
    // overlap saves, and made `heavy` worse than the serial path. The picks are independent, so this
    // is embarrassingly parallel.
    const size_t nworkers =
        std::min<size_t>(picks.size(), std::max<unsigned>(1, std::thread::hardware_concurrency()));
    std::vector<std::vector<int64_t>> parts(nworkers);

    ParallelRanges(picks.size(), nworkers, [&](size_t t, size_t a, size_t b) {
        auto &part = parts[t];
        for (size_t i = a; i < b; i++) {
            ParquetOptions opts(context);
            ParquetReader  reader(context, OpenFileInfo {bind.filename}, opts, probe.metadata);
            // Both lists in lockstep: InitializeScan builds readers from `column_indexes`, Schedule()
            // walks `column_ids` to decide what to fetch. Setting only one yields empty rows.
            reader.column_ids.push_back(MultiFileLocalColumnId(bind.column_id));
            reader.column_indexes.emplace_back(bind.column_id);

            ParquetReaderScanState state;
            reader.InitializeScan(context, state, {static_cast<idx_t>(picks[i])});

            DataChunk chunk;
            chunk.Initialize(Allocator::Get(context), {bind.column_type});
            chunk.Reset();
            auto res = reader.Scan(context, state, chunk);
            while (res.GetResultType() == AsyncResultType::BLOCKED) {
                res.ExecuteTasksSynchronously();
                res = reader.Scan(context, state, chunk);
            }
            // One DataChunk per group is enough: k groups x STANDARD_VECTOR_SIZE is tens of thousands
            // of values, far more than the ~8192 the serial path samples, and it stops after the
            // group's first page rather than decoding the whole group.
            if (chunk.size() == 0) {
                continue;
            }
            auto &vec = chunk.data[0];
            vec.Flatten();
            const int64_t *p = FlatVector::GetData<int64_t>(vec);
            part.insert(part.end(), p, p + chunk.size());
        }
    });

    std::vector<int64_t> sample;
    for (auto &part : parts) {
        sample.insert(sample.end(), part.begin(), part.end());
    }
    return WindowFromSample(sample, bin_min_out, bin_shift_out);
}

// What the fuse decision needs to know before any decoding happens, read from the CACHED FOOTER --
// no page reads, no decompression. Both facts have to be known up front: the row count because
// fusion is a net loss on small columns (fuse_min_rows), and the streaming verdict because a
// memcpy-sink column gets a free, exact window from run() and must not be fused (see the fuse
// decision in RunHeavyPhase). Deciding after decode would mean paying for a window sample we then
// throw away.
struct FooterFacts {
    size_t rows      = 0;
    bool   stream_ok = false;   // would DecodeColumnAllGroups' streaming guard accept this column?
};

FooterFacts ReadFooterFacts(ClientContext &context, const IqrFlagsBindData &bind) {
    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(reader);

    FooterFacts         f;
    std::vector<size_t> live;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        const size_t nv = meta.groups[gi].chunks[bind.column_id].num_values;
        if (nv == 0) {
            continue;
        }
        live.push_back(gi);
        f.rows += nv;
    }

    // Mirrors DecodeColumnAllGroups exactly: FlagBitPacker emits 8 flags per beat, so a ragged
    // intermediate chunk byte-pads mid-stream. STREAM_RAGGED lifts the guard correctly (IqrRunner
    // repacks); FORCE_STREAM lifts it for measurement only (mislabeled flags -- see force_stream()).
    f.stream_ok = stream_enabled() && !bind.needs_values && !live.empty();
    if (f.stream_ok && !force_stream() && !stream_ragged_enabled()) {
        for (size_t i = 0; i + 1 < live.size(); i++) {
            if (meta.groups[live[i]].chunks[bind.column_id].num_values % 8 != 0) {
                f.stream_ok = false;
                break;
            }
        }
    }
    return f;
}

// Derives the histogram window from a sample decoded BY THE FPGA, so the host never decompresses
// anything twice.
//
// WHY. DeriveWindowSpanning() pulls one DataChunk (2048 rows) from each of 16 spanning row groups on
// the HOST. That sounds cheap -- 0.05 % of sf10 -- but you cannot decode 2048 rows out of a
// compressed Parquet page: reading any row forces a full page decompress. So it costs ~3.2 ms per
// group, ~51 ms of host CPU, parallelised down to ~18 ms of wall clock. And every one of those pages
// is decompressed AGAIN by the FPGA moments later as part of the real decode. It is pure duplicated
// work, and it lands on the metric this study leads with: §9.15.1 measured host CPU-work on
// tpch_extprice falling 3.70x -> 1.91x once the window was enabled.
//
// So: decode the 16 spanning groups on the FPGA (fuse off, since the bins do not exist yet), sample
// their output, derive the window, and let the caller then decode the WHOLE column with the bins
// already set. The sampled groups therefore decode twice, ~3 ms of FPGA time. That is deliberate.
// The alternative -- keeping their decoded values and replaying them into the (idle) iqr_host_in
// port so nothing decodes twice -- saves ~1.7 ms but requires flipping fuse_enable in the middle of
// the HISTOGRAM state, i.e. a posted CSR write with no ordering against in-flight data. That is the
// same hazard class that already forced the histogram-clear fence, and it is not worth 1.7 ms.
//
// The sample must SPAN the column. Taking it from whichever groups decode first is the prefix window,
// which flagged 19,997,999 of 20,000,000 rows against a true answer of 200 (RESULTS.md 9.15).
//
// Returns false if no usable sample could be taken; the caller must then fall back.
bool DeriveWindowFromFpga(ClientContext &context, oasis::OasisContext &ctx,
                          const IqrFlagsBindData &bind, int64_t &bin_min_out,
                          uint64_t &bin_shift_out) {
    auto &fs          = FileSystem::GetFileSystem(context);
    auto  file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(reader);

    const size_t col = bind.column_id;

    std::vector<size_t> live;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        if (meta.groups[gi].chunks[col].num_values > 0) {
            live.push_back(gi);
        }
    }
    if (live.empty()) {
        return false;
    }

    // Uniformly spaced, first and last always included: drift is monotonic in row order, so the ends
    // of the file are exactly what a prefix sample misses.
    const size_t        k = std::min(window_groups(), live.size());
    std::vector<size_t> picks;
    picks.reserve(k);
    for (size_t i = 0; i < k; i++) {
        picks.push_back(live[(k == 1) ? 0 : (i * (live.size() - 1)) / (k - 1)]);
    }
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());

    // STRIDE-SAMPLE across each group rather than keeping everything: the picks yield ~2 M values on
    // sf10 and the percentile step is host work. Keeping all of it was never the constraint on
    // ACCURACY though -- the groups are decoded in full either way, so density here is cheap and
    // WindowFromSample selects in O(n). Raise OASIS_IQR_WINDOW_SAMPLES before reaching for more
    // groups; see window_samples_per_group().
    const size_t PER_GROUP_SAMPLE = window_samples_per_group();

    struct InFlight {
        oasis::SplinterResultHandle result;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlight> in_flight;
    std::vector<int64_t> sample;
    sample.reserve(picks.size() * PER_GROUP_SAMPLE);

    auto drain_one = [&]() {
        InFlight g = std::move(in_flight.front());
        in_flight.pop_front();
        auto batch = g.result.get_next_batch();
        if (!batch) {
            throw InternalException("iqr_flags: window decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }
        const int64_t *p      = static_cast<const int64_t *>(batch->buffer->ptr);
        const size_t   stride = std::max<size_t>(1, g.num_values / PER_GROUP_SAMPLE);
        for (size_t i = 0; i < g.num_values; i += stride) {
            sample.push_back(p[i]);
        }
    };

    const size_t depth = decode_window();
    for (size_t gi : picks) {
        const auto &group = meta.groups[gi];
        const auto &cc    = group.chunks[col];
        auto        type  = parcore::metadata::to_libstf_type(cc.type);

        uint64_t span_begin = std::numeric_limits<uint64_t>::max();
        uint64_t span_end   = 0;
        for (const auto &c : group.chunks) {
            span_begin = std::min<uint64_t>(span_begin, c.offset);
            span_end   = std::max<uint64_t>(span_end, c.offset + c.total_compressed_size);
        }
        CoalescedFetcher fetcher(*file_handle, ctx.memory_pool(),
                                 {span_begin, span_end - span_begin});
        auto handle = fetcher.Register(cc.offset, cc.total_compressed_size);
        fetcher.PrepareReads();
        for (size_t i = 0; i < fetcher.num_reads(); i++) {
            fetcher.ExecuteMergedRead(i);
        }

        oasis::QuerySplinter splinter;
        oasis::OperatorFlow  flow;
        flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
        flow.push_back(
            std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
        flow.push_back(std::make_unique<oasis::LocalSinkOperator>(
            ctx.allocate_output_buffer(cc.num_values * libstf::size_of(type)), gi));
        splinter.streams.push_back(std::move(flow));

        in_flight.push_back({ctx.scheduler().submit(std::move(splinter)), cc.num_values, gi});
        if (in_flight.size() >= depth) {
            drain_one();
        }
    }
    while (!in_flight.empty()) {
        drain_one();
    }

    return WindowFromSample(sample, bin_min_out, bin_shift_out);
}

// Decodes the target column across every row group via the ParCore decoder into one contiguous host
// buffer (DMA-mapped, so IqrRunner can stream it). Each group is one QuerySplinter
// (source -> decode -> sink); the scheduler dispatches them asynchronously across the decoder lanes
// and we keep `decode_window()` of them in flight.
//
// Where each group's sink lives decides whether we pay a copy:
//   zero-copy  -- the sink IS the group's slice of the column buffer, so the FPGA DMAs the decoded
//                 values straight into their final position. Needs every non-final group to be a
//                 whole number of 64 KB FPGA transfers (DuckDB's 122,880-row groups are exactly 15),
//                 so that the next group starts on a transfer boundary.
//   fallback   -- a standalone sink per group, memcpy'd into place. Always correct.
// When `chunks_out` is non-null and the streaming preconditions hold, the decoded per-group buffers
// are appended to it in column order and NO contiguous column is built (the return value is null).
std::shared_ptr<libstf::Buffer> DecodeColumnAllGroups(
    ClientContext &context, oasis::OasisContext &ctx, const IqrFlagsBindData &bind,
    size_t &num_values_out, DecodeTiming &tm,
    std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> *chunks_out = nullptr,
    DecodeHooks *hooks = nullptr) {
    auto &fs          = FileSystem::GetFileSystem(context);
    auto  file_handle = fs.OpenFile(bind.filename, FileOpenFlags::FILE_FLAGS_READ);

    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {bind.filename}, parquet_opts);
    auto           meta = BuildParcoreMetadata(reader);

    const size_t col = bind.column_id;

    // The non-empty row groups, in order, and the total value count.
    std::vector<size_t> live;
    size_t              total = 0;
    for (size_t gi = 0; gi < meta.groups.size(); gi++) {
        size_t nv = meta.groups[gi].chunks[col].num_values;
        if (nv == 0) {
            continue;
        }
        live.push_back(gi);
        total += nv;
    }
    num_values_out = total;
    if (total == 0) {
        return nullptr;
    }

    // DISABLED -- a slice sink DOES NOT WORK on this hardware, and it hangs, not errors.
    //
    // The FPGA output writer manages each output buffer as a whole *registered allocation*; the
    // decode-completion interrupt routes back to the runner by allocation. A MakeSlice() view into a
    // shared buffer is not a registered allocation, so the interrupt never arrives and the runner
    // blocks forever in get_next_batch(). This is the "one-buffer-per-chunk invariant" that the
    // working scan path documents and obeys (oasis_scan.cpp: each chunk's sink is its own
    // ctx.allocate_output_buffer()). Zero-copy legitimately lives on the SOURCE and the DuckDB-emit
    // side (FlatVector::SetData), never on the sink.
    //
    // The 64 KB-alignment guard below was never the real constraint -- it merely happened to fail on
    // every real (unaligned) parquet and so always fell back to memcpy, hiding the broken path. Feeding
    // it an aligned file exposed the hang. The memcpy is not removable this way; the only legitimate
    // way to drop it is to teach IqrRunner to stream the per-chunk buffers in sequence instead of
    // gathering them into one contiguous column. Do not re-enable slice sinks. See
    // memory/iqr-fpga-beats-duckdb-host-path.md and IQR_HBM_LEARNINGS.md.
    bool zero_copy = false;
    tm.zero_copy = zero_copy;

    // Streaming precondition. FlagBitPacker emits 8 flags per beat, so a chunk that is not a whole
    // number of 8 elements makes the packer byte-pad *mid-stream*. Only the FINAL chunk may be partial
    // unless the host repacks. DuckDB writes 122,880-row groups (a clean multiple of 8) so this normally
    // holds, but taxi files carry odd-sized groups -- hence the check. STREAM_RAGGED lifts it the correct
    // way (IqrRunner folds the byte-padded flags back to dense). Falling back to the memcpy is always
    // correct.
    bool stream = chunks_out && stream_enabled() && !bind.needs_values;
    if (stream && !stream_ragged_enabled()) {
        for (size_t i = 0; i + 1 < live.size(); i++) {
            if (meta.groups[live[i]].chunks[col].num_values % 8 != 0) {
                stream = false;
                break;
            }
        }
    }
    tm.streamed = stream;

    // One contiguous int64 destination buffer for the whole column. Allocated through the output-buffer
    // path so its address/capacity satisfy the hardware enqueue rules -- the slices inherit that.
    // Skipped entirely when streaming: the per-group sink buffers ARE the input to the two passes.
    size_t total_bytes = total * sizeof(int64_t);
    auto   values      = stream ? nullptr : ctx.allocate_output_buffer(total_bytes);
    void  *dst         = stream ? nullptr : values->ptr;
    if (!stream) {
        ctx.tlb_manager()->ensure_tlb_mapping(dst, values->capacity);
    }

    // Row groups decode independently, and Scheduler::submit() is asynchronous and load-balances
    // flows across the decoder lanes. So keep a sliding window of groups in flight: the FPGA decodes
    // earlier groups while the host fetches and copies out later ones. Submitting one group and
    // immediately blocking on it left the decoder idle for every fetch, submit and memcpy -- which
    // is most of the wall clock, since decode is ~77% of the query and the lane was stalling inside
    // it. The window bounds peak memory (window x group_size of sink buffers, on top of `values`).
    struct InFlightGroup {
        oasis::SplinterResultHandle result;
        size_t                      off_elems;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlightGroup> in_flight;

    // On the fallback path the 166 per-group copies are independent and write to disjoint ranges, so
    // they run on a pool of threads rather than on this one. Serially they cost ~20 ms of a 77 ms
    // query (163 MB at one core's memcpy bandwidth); the FPGA has long since finished by then, so
    // there is nothing to overlap them with -- they have to be made faster, not hidden.
    struct PendingCopy {
        std::shared_ptr<libstf::Buffer> src;
        size_t                          off_elems;
        size_t                          num_values;
    };
    std::vector<PendingCopy> copies;

    auto drain_one = [&]() {
        InFlightGroup g = std::move(in_flight.front());
        in_flight.pop_front();

        auto t0    = TimingClock::now();
        auto batch = g.result.get_next_batch();
        tm.wait_ms += ms_since(t0);
        if (!batch) {
            throw InternalException("iqr_flags: decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }

        // Streaming: keep the sink buffer itself as one input chunk. drain_one pops the FIFO front,
        // which is submission (row-group) order, so the chunks stay in column order.
        if (stream) {
            size_t bytes = g.num_values * sizeof(int64_t);
            chunks_out->emplace_back(batch->buffer, bytes);
            if (hooks && hooks->on_chunk) {
                // Column order is guaranteed by the FIFO pop above, which the histogram does not
                // strictly need but pass 2 does -- and both read this same chunk list.
                hooks->on_chunk(batch->buffer, bytes, chunks_out->size() == live.size());
            }
        } else if (!zero_copy) {
            // zero-copy: the sink WAS the column slice, so the values are already in place.
            copies.push_back({batch->buffer, g.off_elems, g.num_values});
        }
    };

    auto run_copies = [&]() {
        if (copies.empty()) {
            return;
        }
        auto   t0        = TimingClock::now();
        size_t n_threads = std::min<size_t>(copies.size(),
                                            std::max<unsigned>(1, std::thread::hardware_concurrency()));
        std::atomic<size_t>      next {0};
        std::vector<std::thread> workers;
        workers.reserve(n_threads);
        for (size_t t = 0; t < n_threads; t++) {
            workers.emplace_back([&] {
                for (size_t i = next.fetch_add(1); i < copies.size(); i = next.fetch_add(1)) {
                    const auto &c = copies[i];
                    std::memcpy(static_cast<int64_t *>(dst) + c.off_elems, c.src->ptr,
                                c.num_values * sizeof(int64_t));
                }
            });
        }
        for (auto &w : workers) {
            w.join();
        }
        copies.clear(); // releases the sink buffers back to the pool
        tm.copy_ms += ms_since(t0);
    };

    // Flush the copies in batches so the sink buffers we are holding stay bounded (a full column's
    // worth of them would double peak memory on large inputs).
    const size_t copy_batch = std::max<size_t>(8, 2 * std::thread::hardware_concurrency());

    // NOTE (measured 2026-07-22, build-13 + streaming): fetching on a background pool was tried and
    // is a NO-OP. The async scheduler already keeps `window` groups in flight, so the inline fetch
    // below overlaps with FPGA decode by construction -- prefetching only moved 42.8 ms out of
    // `fetch` and into `fpga_wait` with decode total unchanged (181.1 -> 181.7 ms), while costing
    // ~7 % more host CPU (sf10 0.442 -> 0.474 CPU-s). The decoder, not the host feed, bounds this
    // phase. See RESULTS.md 9.11.
    // Announce the element count now that the streaming decision is final, so the caller can arm
    // the IQR pass before the first group lands. Fired regardless of sink: the RTL-fused path tees
    // in hardware and works with the memcpy sink too; only the software overlap needs streaming,
    // and it gates itself on stream_enabled().
    if (hooks && hooks->on_start) {
        hooks->on_start(total, stream);
    }

    const size_t window    = decode_window();
    size_t       off_elems = 0;
    for (size_t gi : live) {
        const auto &group = meta.groups[gi];
        const auto &cc    = group.chunks[col];
        auto        type  = parcore::metadata::to_libstf_type(cc.type);
        tm.groups++;

        // Full byte span of the row group ([min chunk offset, max chunk end) over ALL chunks).
        auto     t0         = TimingClock::now();
        uint64_t span_begin = std::numeric_limits<uint64_t>::max();
        uint64_t span_end   = 0;
        for (const auto &c : group.chunks) {
            span_begin = std::min<uint64_t>(span_begin, c.offset);
            span_end   = std::max<uint64_t>(span_end, c.offset + c.total_compressed_size);
        }
        CoalescedFetcher fetcher(*file_handle, ctx.memory_pool(),
                                 {span_begin, span_end - span_begin});
        auto handle = fetcher.Register(cc.offset, cc.total_compressed_size);
        fetcher.PrepareReads();
        for (size_t i = 0; i < fetcher.num_reads(); i++) {
            fetcher.ExecuteMergedRead(i);
        }
        tm.fetch_ms += ms_since(t0);

        // source -> decode -> sink, one flow. MakeHostSourceCopy copies the compressed bytes into a
        // pooled buffer, so the fetcher may die at the end of this iteration while the flow is still
        // in flight.
        t0 = TimingClock::now();
        oasis::QuerySplinter splinter;
        oasis::OperatorFlow  flow;
        flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
        flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));

        const size_t out_bytes = cc.num_values * libstf::size_of(type);
        auto         sink      = zero_copy
                                     ? MakeSlice(values, off_elems * sizeof(int64_t), out_bytes,
                                                 RoundUpToTransfer(out_bytes))
                                     : ctx.allocate_output_buffer(out_bytes);
        flow.push_back(std::make_unique<oasis::LocalSinkOperator>(sink, gi));
        splinter.streams.push_back(std::move(flow));

        in_flight.push_back(
            {ctx.scheduler().submit(std::move(splinter)), off_elems, cc.num_values, gi});
        tm.submit_ms += ms_since(t0);

        off_elems += cc.num_values;

        if (in_flight.size() >= window) {
            drain_one();
        }
        if (copies.size() >= copy_batch) {
            run_copies();
        }
    }
    while (!in_flight.empty()) {
        drain_one();
    }
    run_copies();

    return values;
}

// Computes the whole result once: decode the target column, run the IQR two passes, store the value
// buffer + packed flag bitmask into `gstate`.
void RunHeavyPhase(ClientContext &context, const IqrFlagsBindData &bind, IqrFlagsGlobalState &gstate) {
    auto &ctx = GetOrCreateOasisContext(context);

    auto         t_all = TimingClock::now();
    DecodeTiming tm;

    // OASIS_IQR_USE_CARD=1 stages the decoded column in HBM and reads both passes from card memory
    // instead of re-DMAing from the host (needs an EN_MEM bitstream). Off by default (legacy host path).
    static const bool use_card = [] {
        const char *e = std::getenv("OASIS_IQR_USE_CARD");
        return e && (e[0] == '1' || e[0] == 't' || e[0] == 'T');
    }();

    // Overlapped pass 1: feed each decoded row group to the histogram as it lands, so pass 1 hides
    // under decode instead of running after it. Card mode stages the whole column up front and so has
    // nothing to overlap.
    //
    // The bins must be fixed before the first beat, and they MUST come from a sample that spans the
    // column -- a prefix-derived window is a wrong-answer bug, not a precision trade-off (§9.15).
    // If the spanning sample cannot be taken we simply do not overlap.
    // Fused pass 1 (RTL) takes precedence over the software overlap: it is strictly better where
    // available (no PCIe traffic, no host CPU) and works with either sink.
    bool fuse = fuse_enabled() && !use_card;

    // Two gates on fusing, both decided from the footer so no decoding is wasted on a fuse we then
    // decline, and no window sample is taken that we then throw away.
    //
    // 1. ROW COUNT. Fusion's saving scales with N (~0.64 ms/Mrow) while the window sample is a
    //    roughly fixed cost, so below fuse_min_rows() it is a measured net loss:
    //    taxi_d1 1.67x -> 1.27x, extprice 1.00x -> 0.86x.
    //
    // 2. STREAMING SINK. A column the streaming guard rejects falls back to the memcpy sink, and
    //    on that path run() derives the window from the WHOLE decoded column -- free, and exactly
    //    right. Fusing forces a sampled window instead, which is strictly worse there. taxi_d3 is
    //    the case in point: fused it finds 1296479 of 1328270 outliers (2.4% low) at 16 groups, and
    //    fixing that with 48 groups makes it SLOWER than not fusing (42 vs 32.9 ms) -- it gains
    //    nothing from fusion at any setting. taxi_d4 happens to be accurate at 16 groups and would
    //    gain 49.6 -> 40.6 ms, but that accuracy is observed, not predictable: taxi_d3 shows a
    //    same-sink, same-shape column can silently lose 2.4% on identical settings. Non-streaming
    //    columns get a perfect window for free, so there is no reason to gamble on them.
    //
    // Both fall through to the previous behaviour if the footer read yields nothing (rows == 0).
    size_t fuse_rows      = 0;
    bool   fuse_small     = false;
    bool   fuse_no_stream = false;
    if (fuse) {
        const FooterFacts facts = ReadFooterFacts(context, bind);
        fuse_rows               = facts.rows;
        if (fuse_rows > 0) {
            fuse_small     = fuse_rows < fuse_min_rows();
            fuse_no_stream = !facts.stream_ok;
            if (fuse_small || fuse_no_stream) {
                fuse = false;
            }
        }
    }

    bool       overlap = !fuse && overlap_enabled() && stream_enabled() && !use_card && !bind.needs_values;
    int64_t     win_min   = 0;
    uint64_t    win_shift = 0;
    double      window_ms = 0.0;
    const char *win_src   = "n/a";
    if (fuse || overlap) {
        // Both need the bins fixed before any value arrives, so the window comes from a sample that
        // SPANS the column (a prefix-derived one is a wrong-answer bug -- RESULTS.md 9.15).
        //
        // Two ways to get that sample. The FPGA path decodes the spanning groups on the device and
        // costs ~3 ms of device time; the host path decompresses their pages on the CPU and costs
        // ~18 ms wall / ~51 ms of host CPU for work the FPGA is about to repeat. The FPGA path is
        // strictly better but changes which values are sampled -- whole groups, stride-sampled,
        // rather than each group's first DataChunk -- so bin_min/bin_shift can land a step apart and
        // flag counts can shift. It is therefore opt-in until re-gated with overlap_ab.sh accuracy.
        auto t_win = TimingClock::now();
        bool ok    = false;
        if (window_fpga_enabled()) {
            ok = DeriveWindowFromFpga(context, ctx, bind, win_min, win_shift);
            win_src = ok ? "fpga" : "fpga-failed";
        }
        if (!ok) {
            ok      = DeriveWindowSpanning(context, bind, win_min, win_shift);
            win_src = window_fpga_enabled() ? "host(fallback)" : "host";
        }
        window_ms = ms_since(t_win);
        fuse      = fuse && ok;
        overlap   = overlap && ok;
    }

    // auto_window stays true: if the overlap does not engage (the streaming guard rejects the file),
    // run() must derive its own window exactly as before, not inherit the spanning one.
    oasis::IqrRunner runner(ctx, bind.is_signed, /*auto_window=*/true, /*bin_min=*/0, /*bin_shift=*/0,
                            use_card);

    bool        pass1_started = false;
    DecodeHooks hooks;

    if (fuse) {
        // Step 2 must be armed before begin_fused(): the index receive buffer has to exist before
        // the first pass-1 beat or the beats the device emits during HISTOGRAM have nowhere to land.
        runner.enable_index_pass2(idx_pass2_enabled());

        // Arm the device before the first group decodes; the decode then drives pass 1 as a side
        // effect of the hardware tee. The element count must be exact -- the on-chip feed
        // regenerates the terminating `last` from it, since each lane asserts `last` per row group.
        hooks.on_start = [&](size_t total_elements, bool) {
            runner.begin_fused(win_min, win_shift, total_elements);
            pass1_started = true;
        };
    }
    if (overlap) {
        hooks.on_start = [&](size_t, bool streaming) {
            if (!streaming) {
                return;   // memcpy fallback: leave pass1_started false so run() handles it
            }
            runner.begin_overlapped(win_min, win_shift); // clears the histogram
            pass1_started = true;
        };
        hooks.on_chunk = [&](const std::shared_ptr<libstf::Buffer> &buf, size_t bytes, bool is_last) {
            runner.feed_pass1({buf->ptr, bytes}, is_last);
        };
    }

    size_t n        = 0;
    auto   t_decode = TimingClock::now();
    // Non-empty only on the streaming path; then gstate.values stays null and these ARE the input.
    std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> chunks;
    gstate.values =
        DecodeColumnAllGroups(context, ctx, bind, n, tm, &chunks, (fuse || overlap) ? &hooks : nullptr);
    double decode_ms    = ms_since(t_decode);
    gstate.num_elements = n;
    if (n == 0) {
        return; // empty column -> no rows, no flags
    }

    // Snapshot the free-running StreamProfiler counters BEFORE the run so the print below can subtract
    // and report just THIS run's cycles (they accumulate for the life of the bitstream, see above).
    oasis::IqrConfig::StreamProfile base_in{}, base_out{};
    if (timing_enabled()) {
        auto cfg = ctx.config<oasis::IqrConfig>();
        base_in  = cfg->input_profile();
        base_out = cfg->output_profile();
    }
    // One chunk (the gathered column) on the default path; one chunk per row group when streaming.
    // run() concatenates them logically and asserts `last` only on the final one, so the packed
    // bitmask is identical either way.
    std::vector<oasis::IqrRunner::InputChunk> inputs;
    if (chunks.empty()) {
        inputs.emplace_back(gstate.values->ptr, n * sizeof(int64_t));
    } else {
        inputs.reserve(chunks.size());
        for (const auto &c : chunks) {
            inputs.emplace_back(c.first->ptr, c.second);
        }
    }

    // pass1_started is the authority, not `overlap`: the decode path silently falls back to the
    // memcpy sink when a row group is not a multiple of 8 elements, and then no chunk was ever fed.
    auto             t_iqr = TimingClock::now();
    auto             res   = !pass1_started ? runner.run(inputs)
                             : (fuse ? runner.finish_fused(inputs)
                                     : runner.finish_overlapped(inputs));
    double           iqr_ms = ms_since(t_iqr);
    gstate.flags           = res.flags;

    // OASIS_IQR_DUMP_FLAGS=/path: write the raw flag bitmask to disk for OFFLINE per-row validation of
    // the fused/streaming path (which cannot be materialized in SQL without deadlocking the no-timeout
    // receiver). Layout: uint64 N (little-endian), then ceil(N/8) mask bytes, 1 bit/row, LSB-first.
    if (const char *dump = std::getenv("OASIS_IQR_DUMP_FLAGS")) {
        if (dump[0] && gstate.flags && gstate.flags->ptr) {
            if (std::FILE *fp = std::fopen(dump, "wb")) {
                uint64_t nn = n;
                std::fwrite(&nn, sizeof(nn), 1, fp);
                std::fwrite(gstate.flags->ptr, 1, (n + 7) / 8, fp);
                std::fclose(fp);
                std::fprintf(stderr, "[iqr] dumped %zu flag bits (%zu bytes) to %s\n",
                             n, (n + 7) / 8, dump);
            } else {
                std::fprintf(stderr, "[iqr] OASIS_IQR_DUMP_FLAGS: could not open %s for writing\n", dump);
            }
        }
    }

    if (timing_enabled()) {
        std::fprintf(stderr,
                     "[iqr] rows=%zu  groups=%zu  window=%zu  sink=%s  pass1=%s  "
                     "win_derive %.2f ms (%s)\n"
                     "[iqr]   decode  %8.2f ms   (fpga_wait %.2f | fetch %.2f | submit %.2f | copy %.2f)\n"
                     "[iqr]   iqr     %8.2f ms   (staging %.2f | passes %.2f)\n"
                     "[iqr]   heavy   %8.2f ms   <- everything before DuckDB emits a single row\n",
                     n, tm.groups, decode_window(),
                     tm.streamed ? "stream" : (tm.zero_copy ? "zero-copy" : "memcpy"),
                     // overlapped: pass 1 is inside `decode`, so `passes` below is pass 2 only.
                     // win_derive is the spanning sample, charged to `heavy` but not to decode; its
                     // source is host (CPU page decompress) or fpga (device decode of the picks).
                     // Name the reason fusion was declined, so a run that asked for it and did not
                     // get it does not look like OASIS_IQR_FUSE was ignored.
                     !pass1_started ? (fuse_small        ? "serial(small)"
                                       : fuse_no_stream  ? "serial(no-stream)"
                                                         : "serial")
                                    : (fuse ? (idx_pass2_enabled() ? "fused+idx" : "fused")
                                 : "overlapped"),
                     window_ms, win_src,
                     decode_ms,
                     tm.wait_ms, tm.fetch_ms, tm.submit_ms, tm.copy_ms, iqr_ms, res.stage_ms,
                     res.passes_ms, ms_since(t_all));

        // FPGA-internal cycle breakdown (StreamProfiler). Subtract the pre-run snapshot to isolate
        // this run. 250 MHz -> us = cycles/250. handshakes should equal 2*N/8 (2 passes, 8 elems/beat),
        // and each handshake beat moves 64 bytes. busy/starved/stalled exclude idle (between-pass,
        // host-timing-dependent). starved = FPGA ready but no data (waiting on PCIe/host -- the HBM
        // target); stalled = data present but FPGA back-pressuring (compute-bound).
        auto sub = [](uint64_t a, uint64_t b) { return (a >= b) ? (a - b) : a; };
        oasis::IqrConfig::StreamProfile in{
            sub(res.input_profile.handshakes, base_in.handshakes),  sub(res.input_profile.starved, base_in.starved),
            sub(res.input_profile.stalled,    base_in.stalled),     sub(res.input_profile.idle,    base_in.idle)};
        oasis::IqrConfig::StreamProfile out{
            sub(res.output_profile.handshakes, base_out.handshakes), sub(res.output_profile.starved, base_out.starved),
            sub(res.output_profile.stalled,    base_out.stalled),    sub(res.output_profile.idle,    base_out.idle)};
        auto     pct     = [](uint64_t x, uint64_t t) { return t ? 100.0 * (double) x / (double) t : 0.0; };
        uint64_t in_act  = in.handshakes + in.starved + in.stalled;
        uint64_t out_act = out.handshakes + out.starved + out.stalled;
        double   in_bw   = res.passes_ms > 0.0 ? (double) in.handshakes * 64.0 / (res.passes_ms * 1e6) : 0.0;
        std::fprintf(stderr,
                     "[iqr-prof] N=%zu  expect handshakes(2N/8)=%.0f  passes=%.2f ms\n"
                     "[iqr-prof]  INPUT  hs=%llu starved=%llu stalled=%llu idle=%llu | busy=%.1f%% starved=%.1f%% stalled=%.1f%%  active=%.1f us  eff=%.2f GB/s\n"
                     "[iqr-prof]  OUTPUT hs=%llu starved=%llu stalled=%llu idle=%llu | busy=%.1f%% starved=%.1f%% stalled=%.1f%%  active=%.1f us\n"
                     "[iqr-prof]  (self-check: raw in.hs=%llu base in.hs=%llu -- if raw already==2N/8 the counters self-zero and the delta is a no-op)\n",
                     n, 2.0 * (double) n / 8.0, res.passes_ms,
                     (unsigned long long) in.handshakes, (unsigned long long) in.starved,
                     (unsigned long long) in.stalled, (unsigned long long) in.idle,
                     pct(in.handshakes, in_act), pct(in.starved, in_act), pct(in.stalled, in_act),
                     in_act / 250.0, in_bw,
                     (unsigned long long) out.handshakes, (unsigned long long) out.starved,
                     (unsigned long long) out.stalled, (unsigned long long) out.idle,
                     pct(out.handshakes, out_act), pct(out.starved, out_act), pct(out.stalled, out_act),
                     out_act / 250.0,
                     (unsigned long long) res.input_profile.handshakes, (unsigned long long) base_in.handshakes);
    }
}

// Resolves (file, column) to a validated IqrFlagsBindData: locates the target column, checks it is a
// 64-bit integer, and captures its signedness. Shared by iqr_flags and iqr_flags_only, which run the
// identical heavy phase and differ only in output schema. `fn` names the caller for error messages.
unique_ptr<IqrFlagsBindData> ResolveIqrColumn(ClientContext &context, const string &filename,
                                              const string &column, const char *fn) {
    ParquetOptions parquet_opts(context);
    ParquetReader  reader(context, OpenFileInfo {filename}, parquet_opts);

    auto bind_data = make_uniq<IqrFlagsBindData>();
    for (idx_t i = 0; i < reader.columns.size(); i++) {
        if (reader.columns[i].name.GetIdentifierName() == column) {
            bind_data->column_id   = i;
            bind_data->column_type = reader.columns[i].type;
            break;
        }
    }
    if (bind_data->column_id == DConstants::INVALID_INDEX) {
        throw BinderException("%s: column '%s' not found in '%s'", fn, column, filename);
    }

    // The vFPGA top instantiates IQR_detection with 64-bit values, so only 64-bit integer columns
    // are supported. Signedness is taken from the column type and forwarded to the device.
    auto type_id = bind_data->column_type.id();
    if (type_id != LogicalTypeId::BIGINT && type_id != LogicalTypeId::UBIGINT) {
        throw BinderException("%s: column '%s' must be a 64-bit integer (BIGINT or UBIGINT), but is %s",
                              fn, column, bind_data->column_type.ToString());
    }
    bind_data->filename         = filename;
    bind_data->column_name      = column;
    bind_data->is_signed        = (type_id == LogicalTypeId::BIGINT);
    bind_data->parquet_metadata = reader.metadata;
    return bind_data;
}

unique_ptr<FunctionData> IqrFlagsBind(ClientContext &context, TableFunctionBindInput &input,
                                      vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_flags");

    // Output schema: the value column, then the boolean outlier flag.
    names.push_back(bind_data->column_name);
    return_types.push_back(bind_data->column_type);
    names.push_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);

    return std::move(bind_data);
}

// iqr_flags_only(path, column) -> just the BOOLEAN is_outlier column (one row per input row). Same
// heavy phase as iqr_flags, but the emit skips re-copying the value: the caller already has the
// values, so the only new information is the per-row flag. Half the output to materialize, and it is
// the mask you apply back onto your own table.
unique_ptr<FunctionData> IqrFlagsOnlyBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_flags_only");
    bind_data->needs_values = false; // bitmask only -> the decoded column never has to be gathered
    names.emplace_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);
    return std::move(bind_data);
}

// The heavy phase runs here: InitGlobal is called once, on one thread, before any worker executes.
// That also lets MaxThreads() see the final row count, so DuckDB sizes the scan's parallelism.
unique_ptr<GlobalTableFunctionState> IqrFlagsInitGlobal(ClientContext &context,
                                                        TableFunctionInitInput &input) {
    auto &bind   = input.bind_data->Cast<IqrFlagsBindData>();
    auto  gstate = make_uniq<IqrFlagsGlobalState>();
    RunHeavyPhase(context, bind, *gstate);
    return std::move(gstate);
}

unique_ptr<LocalTableFunctionState> IqrFlagsInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                      GlobalTableFunctionState *) {
    return make_uniq<IqrFlagsLocalState>();
}

void IqrFlagsFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    // Claim a disjoint slice of rows. Workers never overlap, so no lock is needed past this point.
    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    const int64_t *values = reinterpret_cast<const int64_t *>(gstate.values->ptr);
    const uint8_t *mask   = reinterpret_cast<const uint8_t *>(gstate.flags->ptr);

    auto &value_vec = output.data[0];
    auto &flag_vec  = output.data[1];
    value_vec.SetVectorType(VectorType::FLAT_VECTOR);
    flag_vec.SetVectorType(VectorType::FLAT_VECTOR);
    auto value_out = FlatVector::GetDataMutable<int64_t>(value_vec);
    auto flag_out  = FlatVector::GetDataMutable<bool>(flag_vec);

    for (size_t k = 0; k < emit; k++) {
        size_t i     = start + k;
        value_out[k] = values[i];
        // Packed bitmask: element i is byte i/8, bit i%8 (LSB-first) -- matches IQR_detection.sv.
        flag_out[k] = (mask[i >> 3] >> (i & 7)) & 1u;
    }
    output.SetChildCardinality(emit);
}

// Unpacks `emit` flags starting at element `start` out of a packed bitmask into a single BOOLEAN
// output vector. Shared verbatim by iqr_flags_only (FPGA) and iqr_cpu_flags_groupby (CPU): both produce the
// same packed layout, so the entire output path of the two operators is the same code. That is what
// makes the head-to-head a controlled experiment -- only the compute differs, never the emit.
void EmitFlagSlice(const uint8_t *mask, size_t start, size_t emit, DataChunk &output) {
    auto &flag_vec = output.data[0];
    flag_vec.SetVectorType(VectorType::FLAT_VECTOR);
    auto flag_out = FlatVector::GetDataMutable<bool>(flag_vec);

    for (size_t k = 0; k < emit; k++) {
        size_t i    = start + k;
        // Packed bitmask: element i is byte i/8, bit i%8 (LSB-first) -- matches IQR_detection.sv.
        flag_out[k] = (mask[i >> 3] >> (i & 7)) & 1u;
    }
    output.SetChildCardinality(emit);
}

// Emit only the boolean flag column (no value echoed back). Shares InitGlobal/InitLocal/GlobalState
// with iqr_flags; the parallel cursor + bitmask-unpack are identical, just without the value copy.
void IqrFlagsOnlyFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    EmitFlagSlice(reinterpret_cast<const uint8_t *>(gstate.flags->ptr), start, emit, output);
}

// =============================================================================================
// CPU reference implementation (iqr_cpu_flags_groupby, below) -- shared infrastructure
//
// The apples-to-apples twin of iqr_flags_only: same bind, same validation, same packed-bitmask
// output, same emit code (EmitFlagSlice). The ONLY difference is that the quartiles and the fence
// comparison run on the host cores instead of on the FPGA.
//
// Why this exists. The CPU baseline used to be an ~9-line SQL query (6 CTEs, a GROUP BY, a window
// function, correlated subqueries). That measures "FPGA operator vs CPU algorithm + DuckDB's parser,
// binder, optimizer and general-purpose executor" -- not FPGA vs CPU. Our own phrasing sweep proved
// the point: the *same* algorithm written five different ways in SQL ranged 0.092 s to 3.381 s, a
// 37x spread. A SQL baseline therefore measures the query, not the machine. Implementing it here
// makes both sides one line of SQL and makes the baseline something a reviewer can actually read.
//
// The algorithm, matching the SQL exactly:
//   q1 = smallest v with (#elements <= v)*4 >= N  ==  the ceil(N/4)-th smallest value
//   q3 = smallest v with (#elements <= v)*4 >= 3N ==  the ceil(3N/4)-th smallest value
//   d = q3-q1;  lo = q1 - (d + (d>>1));  hi = q3 + (d + (d>>1))   (1.5*IQR, divider-free)
//   flag[i] = (v[i] < lo) || (v[i] > hi)
// so the quartiles are plain order statistics, computed exactly by iqr_cpu_flags_groupby below.
// =============================================================================================

// OASIS_IQR_CPU_RAW_ALLOC=1 makes the CPU baseline allocate its materialised column with raw
// new[]/delete[] instead of DuckDB's pooled allocator. Default is POOLED, because delete[] returns the
// pages to the OS and that kernel unmap is pure overhead inside the operator -- measured (9.18):
//
//   column        pooled free    delete[] free
//   48 MB sets    3.8-4.7 ms     9.4-11.6 ms
//   taxi_d3 105MB 5.7 ms         19.6 ms
//   taxi_d4 163MB 7.3 ms         27.0 ms
//
// The FPGA path already allocates through pooled buffers, so pooled is also the symmetric choice: it
// gives both arms of the comparison the same memory machinery (9.18 Defect 2). The raw path is kept
// switchable because it was requested explicitly (9.28) and because the difference is worth measuring.
bool cpu_raw_alloc() {
    static const bool raw = [] {
        const char *e = std::getenv("OASIS_IQR_CPU_RAW_ALLOC");
        return e && *e == '1';
    }();
    return raw;
}

// Owns the materialised column under either strategy. Neither value-initialises: `new int64_t[n]`
// default-initialises (does nothing) and Allocate() does not touch the memory, so the parallel parquet
// read is what first-touches the pages -- 32 workers absorbing the faults instead of one memset
// (9.24 step 12c: a std::vector here would cost 82 ms on taxi_d4, 229 ms on sf10).
struct CpuColumn {
    AllocatedData              pooled;
    std::unique_ptr<int64_t[]> raw;
    int64_t                   *ptr = nullptr;

    void Allocate(ClientContext &context, size_t n_elems) {
        if (cpu_raw_alloc()) {
            raw.reset(new int64_t[n_elems]);
            ptr = raw.get();
        } else {
            pooled = Allocator::Get(context).Allocate(n_elems * sizeof(int64_t));
            ptr    = reinterpret_cast<int64_t *>(pooled.get());
        }
    }
    // Timed inside `heavy` on purpose (9.18 Defect 3): holding the whole column is a real cost of the
    // CPU approach, so releasing it must be counted in the operator, not hidden as tax afterwards.
    void Release() {
        raw.reset();
        pooled.Reset();
        ptr = nullptr;
    }
    const char *Kind() const { return cpu_raw_alloc() ? "raw new[]" : "pooled"; }
};

// DuckDB's configured worker count (PRAGMA threads), so the CPU baseline gets exactly the
// parallelism the user asked for -- the same knob that governs the SQL baseline.
size_t CpuThreadCount(ClientContext &context) {
    int32_t n = TaskScheduler::GetScheduler(context).NumberOfThreads();
    return n < 1 ? 1u : static_cast<size_t>(n);
}

// A persistent worker pool behind ParallelRanges.
//
// Why: the CPU operators call ParallelRanges several times per query (min/max, each histogram level,
// the flag mask; or count, scatter, aggregate, flags on the GROUP BY path) and the original version
// created and joined 32 fresh std::threads EVERY call. Measured at 32 threads with 4 calls per query
// (bench/micro/threads_ab.cpp): **4.95 ms of pure dispatch, vs 0.61 ms with a pool -- 4.34 ms saved
// per query, independent of dataset size.** That is ~20 % of taxi_d1's operator and ~3 % of sf10's,
// so it matters most on the small datasets. RESULTS.md 9.32.
//
// Also fixes a latent crash: callers throw from inside the parallel region (ReadColumnCpu raises on a
// short read), and an exception escaping a std::thread lambda calls std::terminate. The pool captures
// the first exception and rethrows it on the caller's thread.
class IqrThreadPool {
public:
    static IqrThreadPool &Get() {
        static IqrThreadPool pool;
        return pool;
    }

    // Runs body(worker_id, worker_count) on every pooled thread. The CALLER is responsible for
    // mapping its logical ranges onto worker_count workers -- see ParallelRanges, which strides. Do
    // NOT assume worker_count equals the caller's requested thread count; it is the pool size.
    //
    // Returns false if the pool is already in use (a nested or concurrent call), so the caller can
    // fall back to spawning. Keeps this non-reentrant pool safe without serialising queries.
    bool TryRun(const std::function<void(size_t, size_t)> &body) {
        std::unique_lock<std::mutex> gate(run_mutex_, std::try_to_lock);
        if (!gate.owns_lock()) {
            return false;
        }
        {
            std::lock_guard<std::mutex> l(m_);
            body_   = &body;
            err_    = nullptr;
            pending_ = workers_.size();
            gen_++;
        }
        cv_.notify_all();
        {
            std::unique_lock<std::mutex> l(m_);
            done_cv_.wait(l, [this] { return pending_ == 0; });
            body_ = nullptr;
            if (err_) {
                auto e = err_;
                err_   = nullptr;
                std::rethrow_exception(e);
            }
        }
        return true;
    }

    size_t size() const { return workers_.size(); }

private:
    IqrThreadPool() {
        const size_t k = std::max<unsigned>(1, std::thread::hardware_concurrency());
        workers_.reserve(k);
        for (size_t i = 0; i < k; i++) {
            workers_.emplace_back([this, i] { Worker(i); });
        }
    }
    ~IqrThreadPool() {
        {
            std::lock_guard<std::mutex> l(m_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto &w : workers_) {
            w.join();
        }
    }

    void Worker(size_t id) {
        size_t seen = 0;
        for (;;) {
            const std::function<void(size_t, size_t)> *body = nullptr;
            {
                std::unique_lock<std::mutex> l(m_);
                cv_.wait(l, [&] { return stop_ || gen_ != seen; });
                if (stop_) {
                    return;
                }
                seen = gen_;
                body = body_; // every worker participates; the caller strides

            }
            if (body) {
                try {
                    (*body)(id, workers_.size());
                } catch (...) {
                    std::lock_guard<std::mutex> l(m_);
                    if (!err_) {
                        err_ = std::current_exception();
                    }
                }
            }
            {
                std::lock_guard<std::mutex> l(m_);
                if (--pending_ == 0) {
                    done_cv_.notify_one();
                }
            }
        }
    }

    std::vector<std::thread>           workers_;
    std::mutex                         m_, run_mutex_;
    std::condition_variable            cv_, done_cv_;
    const std::function<void(size_t, size_t)> *body_ = nullptr;
    std::exception_ptr                         err_;
    size_t                                     gen_ = 0, pending_ = 0;
    bool                               stop_ = false;
};

// Splits [0, n) into at most `nthreads` contiguous ranges and runs fn(thread_idx, lo, hi) on each.
// thread_idx is always < nthreads, so callers can index per-thread scratch by it. The chunking is
// identical to the original spawn-per-call version, so passes that must agree on ranges (the GROUP BY
// count and scatter passes) still do.
template <class F>
void ParallelRanges(size_t n, size_t nthreads, F &&fn) {
    if (n == 0) {
        return;
    }
    if (nthreads <= 1) {
        fn(size_t(0), size_t(0), n);
        return;
    }
    const size_t chunk = (n + nthreads - 1) / nthreads;
    // Each pooled worker takes every k-th logical range, so `nthreads` may be larger OR smaller than
    // the pool. Mapping ranges 1:1 onto workers would silently DROP ranges when nthreads > pool size
    // (caught by bench/micro/pool_test.cpp: n=1000, nt=100 left elements 640.. unvisited). Distinct
    // logical ranges still get distinct `t`, so per-thread scratch indexed by `t` stays correct.
    auto body = [&](size_t id, size_t k) {
        for (size_t t = id; t < nthreads; t += k) {
            const size_t lo = t * chunk;
            if (lo >= n) {
                break; // t increasing => lo increasing, so nothing later can be in range
            }
            fn(t, lo, std::min(n, lo + chunk));
        }
    };
    if (IqrThreadPool::Get().TryRun(body)) {
        return;
    }
    // Fallback: pool busy (nested or concurrent call). Same semantics, just pays the spawn.
    std::vector<std::thread> workers;
    workers.reserve(nthreads);
    for (size_t t = 0; t < nthreads; t++) {
        size_t lo = t * chunk;
        if (lo >= n) {
            break;
        }
        size_t hi = std::min(n, lo + chunk);
        workers.emplace_back([&fn, t, lo, hi] { fn(t, lo, hi); });
    }
    for (auto &w : workers) {
        w.join();
    }
}

// lo/hi for the 1.5*IQR rule. Computed in 128-bit so q3+1.5*IQR can never overflow T, then clamped
// back into T's range -- clamping is exact here, since no value of type T can lie outside it anyway.
template <class T>
void IqrFences(T q1, T q3, T &lo, T &hi) {
    const __int128 a    = static_cast<__int128>(q1);
    const __int128 b    = static_cast<__int128>(q3);
    const __int128 d    = b - a;
    const __int128 ext  = d + (d >> 1); // d + d/2 == 1.5*IQR; d >= 0, so the shift is exact
    const __int128 l    = a - ext;
    const __int128 h    = b + ext;
    const __int128 tmin = static_cast<__int128>(std::numeric_limits<T>::lowest());
    const __int128 tmax = static_cast<__int128>(std::numeric_limits<T>::max());
    lo = static_cast<T>(l < tmin ? tmin : (l > tmax ? tmax : l));
    hi = static_cast<T>(h < tmin ? tmin : (h > tmax ? tmax : h));
}

// flag[i] = v[i] < lo || v[i] > hi, into the same LSB-first packed bitmask the FPGA writes. Threads
// are split on *byte* boundaries so no two of them ever touch the same mask byte.
template <class T>
void ComputeFlagMask(const T *v, size_t n, T lo, T hi, uint8_t *mask, size_t nt) {
    const size_t nbytes = (n + 7) / 8;
    ParallelRanges(nbytes, nt, [&](size_t, size_t blo, size_t bhi) {
        for (size_t b = blo; b < bhi; b++) {
            const size_t base  = b * 8;
            const size_t limit = std::min<size_t>(8, n - base);
            uint8_t      byte  = 0;
            for (size_t j = 0; j < limit; j++) {
                T x = v[base + j];
                byte |= static_cast<uint8_t>((x < lo || x > hi) ? 1u : 0u) << j;
            }
            mask[b] = byte;
        }
    });
}

// Reads the target column into one contiguous int64 array using DuckDB's own parquet reader (the
// CPU's best decoder, just as the FPGA path uses its own). Row counts come from the footer, so each
// worker knows its destination offset up front and workers write disjoint ranges of `out`.
size_t ReadColumnCpu(ClientContext &context, const IqrFlagsBindData &bind, size_t nt,
                     CpuColumn &out) {
    ParquetOptions parquet_opts(context);
    ParquetReader  probe(context, OpenFileInfo {bind.filename}, parquet_opts, bind.parquet_metadata);
    auto           meta = BuildParcoreMetadata(probe);

    const size_t        ngroups = meta.groups.size();
    std::vector<size_t> group_off(ngroups, 0);
    size_t              total = 0;
    for (size_t g = 0; g < ngroups; g++) {
        group_off[g] = total;
        total += meta.groups[g].chunks[bind.column_id].num_values;
    }
    if (total == 0) {
        return 0;
    }
    // Pooled by default, raw new[] under OASIS_IQR_CPU_RAW_ALLOC=1 -- see CpuColumn above for the
    // measured difference and why pooled is the symmetric choice.
    out.Allocate(context, total);

    // One worker per contiguous block of row groups; each builds its own reader and scan state
    // (neither is thread-safe) but shares the already-parsed footer.
    const size_t nworkers = std::min(nt, ngroups);
    ParallelRanges(ngroups, nworkers, [&](size_t, size_t ga, size_t gb) {
        ParquetOptions opts(context);
        ParquetReader  reader(context, OpenFileInfo {bind.filename}, opts, probe.metadata);
        // Project only the target column. Both lists must be pushed in lockstep and are indexed
        // positionally: InitializeScan builds state.column_readers from `column_indexes`, while
        // Schedule() walks `column_ids` to decide which chunks to actually fetch. Setting only
        // column_indexes yields a reader that returns rows containing nothing.
        reader.column_ids.push_back(MultiFileLocalColumnId(bind.column_id));
        reader.column_indexes.emplace_back(bind.column_id);

        vector<idx_t> groups;
        groups.reserve(gb - ga);
        for (size_t g = ga; g < gb; g++) {
            groups.push_back(static_cast<idx_t>(g));
        }
        ParquetReaderScanState state;
        reader.InitializeScan(context, state, std::move(groups));

        DataChunk chunk;
        chunk.Initialize(Allocator::Get(context), {bind.column_type});

        int64_t *const start = out.ptr + group_off[ga];
        int64_t       *dst   = start;
        for (;;) {
            chunk.Reset();
            auto res = reader.Scan(context, state, chunk);
            // The reader may need async I/O; run it here rather than yielding to the scheduler.
            while (res.GetResultType() == AsyncResultType::BLOCKED) {
                res.ExecuteTasksSynchronously();
                res = reader.Scan(context, state, chunk);
            }
            const idx_t count = chunk.size();
            if (count == 0) {
                break;
            }
            auto &vec = chunk.data[0];
            vec.Flatten();
            std::memcpy(dst, FlatVector::GetData<int64_t>(vec), count * sizeof(int64_t));
            dst += count;
        }

        // The footer already told us how many values these groups hold, so a short read means the
        // scan silently stopped early and the tail of `out` would still be zero-filled -- which
        // produces q1 == q3 == 0, fences of [0,0] and a plausible-looking all-false mask. Fail loudly
        // instead: a wrong answer here is far worse than an exception.
        const size_t expected = (gb < ngroups ? group_off[gb] : total) - group_off[ga];
        const size_t got      = static_cast<size_t>(dst - start);
        if (got != expected) {
            throw InternalException("iqr_cpu_flags_groupby: row groups [%llu,%llu) yielded %llu values, "
                                    "expected %llu",
                                    (unsigned long long)ga, (unsigned long long)gb,
                                    (unsigned long long)got, (unsigned long long)expected);
        }
    });
    return total;
}

// The CPU twin of IqrFlagsGlobalState: owns plain host memory, so this operator builds and runs with
// no FPGA present at all.
struct IqrCpuGlobalState : public GlobalTableFunctionState {
    std::unique_ptr<uint8_t[]> flags; // packed outlier bitmask, same layout as the FPGA's
    size_t                     num_elements = 0;
    std::atomic<size_t>        cursor {0};

    idx_t MaxThreads() const override {
        return MaxValue<idx_t>(1, (num_elements + STANDARD_VECTOR_SIZE - 1) / STANDARD_VECTOR_SIZE);
    }
};

unique_ptr<FunctionData> IqrCpuFlagsBind(ClientContext &context, TableFunctionBindInput &input,
                                         vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_cpu_flags_groupby");
    names.emplace_back("is_outlier");
    return_types.push_back(LogicalType::BOOLEAN);
    return std::move(bind_data);
}

void IqrCpuFlagsFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrCpuGlobalState>();

    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    EmitFlagSlice(gstate.flags.get(), start, emit, output);
}

// =============================================================================================
// iqr_cpu_flags_groupby(path, column) -- the DIRECT C++ TRANSLITERATION of the SQL baseline
//
// Why this exists (RESULTS.md 9.29). It shares the SQL's mechanics as well as its rule, so the
// SQL -> C++ speedup measures only leaving DuckDB's parser / binder / optimizer / general-purpose
// executor, not a change of algorithm. It transliterates the SQL statement for statement:
//
//     ecnt AS (SELECT v, count(*) c FROM s GROUP BY v)          -> per-thread hash tables + combine
//     ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt) -> sort the DISTINCT values, scan
//     eq   AS (min(v) WHERE cc*4>=t / cc*4>=3*t)                -> first hit in that scan
//     ef   AS (q1-(d+(d>>1)), q3+(d+(d>>1)))                    -> IqrFences, unchanged
//     SELECT (v < lo OR v > hi)                                 -> ComputeFlagMask, unchanged
//
// The column read (ReadColumnCpu) and the packed-bitmask emit path (EmitFlagSlice) are the same code
// the FPGA operator's comparison uses, so a head-to-head measures the computation and nothing else.
//
// Shape note: this is a hash aggregate over N followed by a sort over D (the distinct count) -- the
// same shape DuckDB's plan has, and NOT a sort over N (that is 6.5's approach 4, 36.8x slower).
// Memory is therefore O(D) per thread; on these datasets D <= ~2 M, so the per-thread tables can
// reach a few tens of MB each. That is the same cost the SQL baseline pays.
// =============================================================================================

// Bottom-up parallel merge sort over the (value, count) pairs -- the `order` phase.
//
// This was a single-threaded std::sort and it is the dominant cost on high-cardinality columns:
// **83.64 ms of tpch_extprice's 126.14 ms operator (66 %)** at D = 933,900, and 121 ms on sf10 at
// D = 1.35 M (RESULTS.md 9.33). Low-cardinality columns are unaffected either way (tpch_qty's `order`
// is 0.02 ms at D = 50), which is why this is the fix for extprice/sf10 specifically.
//
// Bottom-up rather than a K-way merge: each round merges disjoint adjacent pairs of runs, so every
// round is embarrassingly parallel and needs no coordination. The final rounds have few pairs and so
// less parallelism -- that is inherent to merge sort and is why the expected speedup is ~5-6x, not 32x.
template <class T>
void ParallelSortPairs(std::pair<T, uint64_t> *v, size_t n, size_t nt) {
    auto cmp = [](const std::pair<T, uint64_t> &a, const std::pair<T, uint64_t> &b) {
        return a.first < b.first;
    };
    // Below this the dispatch and the scratch allocation cost more than the sort saves.
    if (n < 1u << 15 || nt <= 1) {
        std::sort(v, v + n, cmp);
        return;
    }
    const size_t runs  = std::min(nt, n / 4096);
    const size_t chunk = (n + runs - 1) / runs;
    ParallelRanges(n, runs, [&](size_t, size_t lo, size_t hi) { std::sort(v + lo, v + hi, cmp); });

    // Scratch via new[]: std::pair<integral, uint64_t> is trivially default-constructible, so this
    // does NOT initialise. A std::vector here would memset it first (9.24 step 12c, 9.31).
    std::unique_ptr<std::pair<T, uint64_t>[]> scratch(new std::pair<T, uint64_t>[n]);
    std::pair<T, uint64_t> *src = v, *dst = scratch.get();
    for (size_t width = chunk; width < n; width *= 2) {
        const size_t npairs = (n + 2 * width - 1) / (2 * width);
        ParallelRanges(npairs, std::min(nt, npairs), [&](size_t, size_t plo, size_t phi) {
            for (size_t q = plo; q < phi; q++) {
                const size_t lo  = q * 2 * width;
                if (lo >= n) {
                    break;
                }
                const size_t mid = std::min(n, lo + width);
                const size_t hi  = std::min(n, lo + 2 * width);
                std::merge(src + lo, src + mid, src + mid, src + hi, dst + lo, cmp);
            }
        });
        std::swap(src, dst);
    }
    if (src != v) {
        std::copy(src, src + n, v);
    }
}

// Returns the fence description; also reports the distinct count, which is the whole story of why
// GROUP BY is or is not competitive on a given column.
template <class T>
std::string IqrCpuCoreGroupBy(const int64_t *raw, size_t n, size_t nt, uint8_t *mask,
                              double &group_ms, double &order_ms, double &flag_ms,
                              size_t &n_distinct, double &part_out, double &agg_out) {
    using U = typename std::make_unsigned<T>::type;
    const T *v = reinterpret_cast<const T *>(raw);

    // ---- ecnt: GROUP BY v, RADIX-PARTITIONED --------------------------------------------------
    // The first version of this built one hash table per thread and then combined them in a single
    // loop on one core. That combine was 90 % of the whole phase (RESULTS.md 9.30): with D = 1.35 M
    // distinct and 32 threads it performed ~31 M pointer-chasing probes into a growing
    // multi-hundred-MB node-based table, single-threaded -- which is why sf10's GROUP BY operator
    // took 6.4 s and average parallelism over the query was only 3.7x on 32 threads.
    //
    // A real hash aggregate does not have that step, because it partitions by hash first: partitions
    // are disjoint, so each one aggregates independently and nothing has to be merged afterwards.
    // Measured on sf10's shape (bench/micro/groupby_ab.cpp): 12209 ms -> 565 ms, **21.6x**, with an
    // identical distinct count.
    //
    // Cost of the technique: one extra pass and a scatter buffer the size of the column (960 MB peak
    // on sf10, column + buffer). In exchange every partition's working set fits in cache, so the
    // aggregate pass stops missing on every probe.
    constexpr size_t P    = 256;      // partitions; keeps each working set well under L2 at D ~ 1.4 M
    constexpr size_t PMASK = P - 1;

    auto hash_of = [](U x) {          // multiplicative hash; the low bits select the partition
        uint64_t h = static_cast<uint64_t>(x) * 0x9E3779B97F4A7C15ull;
        return static_cast<size_t>(h ^ (h >> 29));
    };

    auto t0 = TimingClock::now();

    // NOTE: a low-cardinality fast path (skip partitioning below ~4096 distinct, RESULTS.md 9.33 "B")
    // was implemented and REVERTED. It was a net negative: its probe allocates and frees ~131k
    // unordered_map nodes before bailing out, costing **+3 ms on every column with D > 4096** (six of
    // seven datasets) in order to speed up the one low-cardinality column by 17 ms -- which overshot,
    // taking tpch_qty's C++ operator to 12.1 ms against the FPGA's 15.0. See 9.34.
    std::vector<std::pair<T, uint64_t>> ord;

    // Pass 1 -- per-thread, per-partition counts, so the scatter can write to exact offsets with no
    // synchronisation at all.
    std::vector<std::vector<size_t>> cnt(nt, std::vector<size_t>(P, 0));
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        auto &c = cnt[t];
        for (size_t i = lo; i < hi; i++) {
            c[hash_of(static_cast<U>(v[i])) & PMASK]++;
        }
    });

    // Exclusive prefix sums: pstart[p] is where partition p begins, off[t][p] where thread t writes.
    std::vector<size_t> pstart(P + 1, 0);
    for (size_t p = 0; p < P; p++) {
        size_t sum = 0;
        for (size_t t = 0; t < nt; t++) {
            sum += cnt[t][p];
        }
        pstart[p + 1] = pstart[p] + sum;
    }
    std::vector<std::vector<size_t>> off(nt, std::vector<size_t>(P, 0));
    for (size_t p = 0; p < P; p++) {
        size_t run = pstart[p];
        for (size_t t = 0; t < nt; t++) {
            off[t][p] = run;
            run += cnt[t][p];
        }
    }

    // Pass 2 -- scatter. Disjoint destinations by construction, so no atomics.
    //
    // NOT std::vector: it value-initialises, i.e. memsets all 480 MB (sf10) on ONE thread before the
    // scatter overwrites every byte of it -- 229 ms, which is 35 % of this operator. `new T[n]` on a
    // trivially-constructible T default-initialises, i.e. does nothing. Same trap as 9.24 step 12c;
    // measured in 9.31 (the scatter itself runs at 50 GB/s, already at memory bandwidth).
    std::unique_ptr<T[]> buf_owner(new T[n]);
    T *const             buf = buf_owner.get();
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        auto local = off[t]; // by value: keeps the cursors in registers/L1 rather than shared memory
        for (size_t i = lo; i < hi; i++) {
            buf[local[hash_of(static_cast<U>(v[i])) & PMASK]++] = v[i];
        }
    });
    const double part_ms = ms_since(t0);

    // Pass 3 -- aggregate each partition independently. This is what replaces the serial merge.
    auto                                              t_agg = TimingClock::now();
    std::vector<std::vector<std::pair<T, uint64_t>>>  pairs(P);
    const size_t                                      agg_nt = std::min<size_t>(nt, P);
    ParallelRanges(P, agg_nt, [&](size_t, size_t plo, size_t phi) {
        std::unordered_map<T, uint64_t> m;
        for (size_t p = plo; p < phi; p++) {
            const size_t len = pstart[p + 1] - pstart[p];
            m.clear();
            m.reserve(len / 4 + 16);
            for (size_t i = pstart[p]; i < pstart[p + 1]; i++) {
                m[buf[i]]++;
            }
            pairs[p].assign(m.begin(), m.end());
        }
    });
    buf_owner.reset(); // release the scatter buffer before the sort allocates
    const double agg_ms = ms_since(t_agg);

    n_distinct = 0;
    for (size_t p = 0; p < P; p++) {
        n_distinct += pairs[p].size();
    }
    group_ms = ms_since(t0);
    part_out = part_ms;
    agg_out  = agg_ms;

    // ---- ecum + eq: ORDER BY v, cumulative count, first value past each rank -------------------
    // t1 starts BEFORE the concatenation on purpose. An earlier version started it after, which left
    // the 15 MB gather (and its first-touch faults) in an untimed gap -- the phases then no longer
    // summed to `heavy` (16.9 ms unaccounted on extprice) and made the parallel sort look better than
    // it is. Same class of mistake as 9.31, so: every millisecond between t_all and the end must live
    // inside exactly one phase timer.
    auto t1 = TimingClock::now();
    ord.reserve(n_distinct);
    for (size_t p = 0; p < P; p++) {
        ord.insert(ord.end(), pairs[p].begin(), pairs[p].end());
        std::vector<std::pair<T, uint64_t>>().swap(pairs[p]);
    }
    ParallelSortPairs<T>(ord.data(), ord.size(), nt);

    // The SQL's integer, divider-free percentile test: cc*4 >= t for q1 and cc*4 >= 3*t for q3,
    // where t = sum(c) = n. cc <= n, so cc*4 cannot overflow uint64 for any realistic n.
    const uint64_t t_total = static_cast<uint64_t>(n);
    T              q1 = ord.empty() ? T {} : ord.back().first;
    T              q3 = q1;
    bool           have_q1 = false, have_q3 = false;
    uint64_t       cc = 0;
    for (const auto &e : ord) {
        cc += e.second;
        if (!have_q1 && cc * 4 >= t_total) {
            q1      = e.first;
            have_q1 = true;
        }
        if (!have_q3 && cc * 4 >= 3 * t_total) {
            q3      = e.first;
            have_q3 = true;
            break; // q3 >= q1 always, so nothing after this can change either
        }
    }
    T lo, hi;
    IqrFences<T>(q1, q3, lo, hi);
    // Release the pair array here, inside the phase that owns it. Left to the destructor at function
    // return it would free ~15 MB (at D = 933,900) inside `heavy` but outside every phase timer -- a
    // 2.09 ms residual that stopped the phases summing to `heavy`. See the t1 note above: every
    // millisecond between t_all and the end must live inside exactly one phase timer.
    std::vector<std::pair<T, uint64_t>>().swap(ord);
    order_ms = ms_since(t1);

    // ---- the labeling pass (ComputeFlagMask) -----------------------------------------------
    auto t2 = TimingClock::now();
    ComputeFlagMask<T>(v, n, lo, hi, mask, nt);
    flag_ms = ms_since(t2);

    return "q1=" + std::to_string(q1) + " q3=" + std::to_string(q3) + " lo=" + std::to_string(lo) +
           " hi=" + std::to_string(hi);
}

void RunHeavyPhaseCpuGroupBy(ClientContext &context, const IqrFlagsBindData &bind,
                             IqrCpuGlobalState &gstate) {
    const size_t nt    = CpuThreadCount(context);
    auto         t_all = TimingClock::now();

    CpuColumn                  values;
    auto                       t_read  = TimingClock::now();
    const size_t               n       = ReadColumnCpu(context, bind, nt, values);
    const double               read_ms = ms_since(t_read);
    gstate.num_elements                = n;
    if (n == 0) {
        return;
    }
    gstate.flags.reset(new uint8_t[(n + 7) / 8]);

    const int64_t *vals = values.ptr;
    double         group_ms = 0.0, order_ms = 0.0, flag_ms = 0.0, part_ms = 0.0, agg_ms = 0.0;
    size_t         n_distinct = 0;
    std::string    fences =
        bind.is_signed ? IqrCpuCoreGroupBy<int64_t>(vals, n, nt, gstate.flags.get(), group_ms,
                                                    order_ms, flag_ms, n_distinct, part_ms, agg_ms)
                          : IqrCpuCoreGroupBy<uint64_t>(vals, n, nt, gstate.flags.get(), group_ms,
                                                        order_ms, flag_ms, n_distinct, part_ms, agg_ms);

    // Fairness rule: the column release is a real cost of holding the whole
    // column, so it is counted inside `heavy` (RESULTS.md 9.18 Defect 3).
    auto         t_free  = TimingClock::now();
    values.Release();
    const double free_ms = ms_since(t_free);

    if (timing_enabled()) {
        std::fprintf(stderr,
                     "[iqr-cpu-gb] rows=%zu  threads=%zu  distinct=%zu  %s\n"
                     "[iqr-cpu-gb]   read    %8.2f ms   <- DuckDB parquet decode of the target column\n"
                     "[iqr-cpu-gb]   group   %8.2f ms   <- GROUP BY v: radix-partitioned (partition %.2f + aggregate %.2f)\n"
                     "[iqr-cpu-gb]   order   %8.2f ms   <- ORDER BY v over the %zu distinct + cumulative scan\n"
                     "[iqr-cpu-gb]   flags   %8.2f ms   <- fence compare into the packed bitmask\n"
                     "[iqr-cpu-gb]   free    %8.2f ms   <- release the materialised column\n"
                     "[iqr-cpu-gb]   heavy   %8.2f ms   <- everything before DuckDB emits a single row\n",
                     n, nt, n_distinct, fences.c_str(), read_ms, group_ms, part_ms, agg_ms,
                     order_ms, n_distinct, flag_ms, free_ms, ms_since(t_all));
    }
}

unique_ptr<GlobalTableFunctionState> IqrCpuGroupByInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input) {
    auto &bind   = input.bind_data->Cast<IqrFlagsBindData>();
    auto  gstate = make_uniq<IqrCpuGlobalState>();
    RunHeavyPhaseCpuGroupBy(context, bind, *gstate);
    return std::move(gstate);
}

// iqr_profiler() -> one row of the RAW StreamProfiler counters (regs 7-14), cumulative since the
// bitstream was loaded and NOT reset. Read it yourself, before and after an iqr_flags query, to see a
// run's accumulation and control it manually (unlike the [iqr-prof] print, which auto-subtracts):
//   SELECT * FROM iqr_profiler();                                   -- baseline
//   SELECT count(*) FROM iqr_flags_only('/path.parquet','col');     -- run (accumulates)
//   SELECT * FROM iqr_profiler();                                   -- after; delta = this run's cycles
// in_handshakes should rise by exactly 2*N/8 per run (2 passes, 8 elems/beat). 250 MHz -> us=cycles/250.
struct IqrProfilerState : public GlobalTableFunctionState {
    bool  done = false;
    idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> IqrProfilerBind(ClientContext &, TableFunctionBindInput &,
                                         vector<LogicalType> &return_types, vector<string> &names) {
    for (auto *c : {"in_handshakes", "in_starved", "in_stalled", "in_idle", "out_handshakes",
                    "out_starved", "out_stalled", "out_idle"}) {
        names.emplace_back(c);
        return_types.push_back(LogicalType::UBIGINT);
    }
    return make_uniq<TableFunctionData>();
}

unique_ptr<GlobalTableFunctionState> IqrProfilerInit(ClientContext &, TableFunctionInitInput &) {
    return make_uniq<IqrProfilerState>();
}

void IqrProfilerFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &st = data_p.global_state->Cast<IqrProfilerState>();
    if (st.done) {
        output.SetChildCardinality(0);
        return;
    }
    auto    &ctx = GetOrCreateOasisContext(context);
    auto     cfg = ctx.config<oasis::IqrConfig>();
    auto     in  = cfg->input_profile();
    auto     out = cfg->output_profile();
    uint64_t vals[8] = {in.handshakes,  in.starved,  in.stalled,  in.idle,
                        out.handshakes, out.starved, out.stalled, out.idle};
    for (int c = 0; c < 8; c++) {
        output.data[c].SetVectorType(VectorType::FLAT_VECTOR);
        FlatVector::GetDataMutable<uint64_t>(output.data[c])[0] = vals[c];
    }
    output.SetChildCardinality(1);
    st.done = true;
}

// decoder_profiler() -> one row PER DECODER LANE of the built-in ColumnChunkDecoder StreamProfilers
// (input + output). Tells you where the DECODER spends its time: in_starved = waiting on compressed
// bytes (fetch/PCIe-bound); out_stalled = decoder output back-pressured; high busy with low starved/
// stalled = compute-bound (the hard-column case). NOTE: these HW profilers AUTO-RESET after each full
// read, so each call returns the cycles since the PREVIOUS call -- read once to clear, run your query,
// read again for that query's decode. 250 MHz -> us = cycles/250.
struct DecoderProfilerState : public GlobalTableFunctionState {
    bool  done = false;
    idx_t MaxThreads() const override { return 1; }
};

unique_ptr<FunctionData> DecoderProfilerBind(ClientContext &, TableFunctionBindInput &,
                                             vector<LogicalType> &return_types, vector<string> &names) {
    names.emplace_back("decoder");
    return_types.push_back(LogicalType::UBIGINT);
    for (auto *c : {"in_handshakes", "in_starved", "in_stalled", "in_idle", "out_handshakes",
                    "out_starved", "out_stalled", "out_idle"}) {
        names.emplace_back(c);
        return_types.push_back(LogicalType::UBIGINT);
    }
    return make_uniq<TableFunctionData>();
}

unique_ptr<GlobalTableFunctionState> DecoderProfilerInit(ClientContext &, TableFunctionInitInput &) {
    return make_uniq<DecoderProfilerState>();
}

void DecoderProfilerFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &st = data_p.global_state->Cast<DecoderProfilerState>();
    if (st.done) {
        output.SetChildCardinality(0);
        return;
    }
    auto &ctx = GetOrCreateOasisContext(context);
    auto  cfg = ctx.config<parcore::ColumnChunkDecoderConfig>();
    auto  nd  = cfg->num_decoders();
    for (int col = 0; col < 9; col++) {
        output.data[col].SetVectorType(VectorType::FLAT_VECTOR);
    }
    for (libstf::stream_t d = 0; d < nd; d++) {
        auto     p        = cfg->read_profile(d);
        uint64_t row[9]   = {(uint64_t) d,
                             p.in.handshakes_cycles,  p.in.starved_cycles,  p.in.stalled_cycles,  p.in.idle_cycles,
                             p.out.handshakes_cycles, p.out.starved_cycles, p.out.stalled_cycles, p.out.idle_cycles};
        for (int col = 0; col < 9; col++) {
            FlatVector::GetDataMutable<uint64_t>(output.data[col])[d] = row[col];
        }
    }
    output.SetChildCardinality(nd);
    st.done = true;
}

} // namespace

void RegisterOasisIqrFunction(ExtensionLoader &loader) {
    TableFunction iqr_flags("iqr_flags",                                  // name
                            {LogicalType::VARCHAR, LogicalType::VARCHAR}, // args: file path, column
                            IqrFlagsFunction,                            // emit (parallel)
                            IqrFlagsBind,                                // bind (schema)
                            IqrFlagsInitGlobal,                          // global init (heavy phase)
                            IqrFlagsInitLocal                            // local init (per worker)
    );
    loader.RegisterFunction(iqr_flags);

    // Flag-only sibling: same heavy phase, emits just the is_outlier boolean array (no value column).
    TableFunction iqr_flags_only("iqr_flags_only", {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                 IqrFlagsOnlyFunction, IqrFlagsOnlyBind, IqrFlagsInitGlobal,
                                 IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_flags_only);

    // CPU reference implementation: a direct transliteration of the SQL baseline (GROUP BY +
    // ORDER BY), with the same signature, schema and emit path as iqr_flags_only, so
    //   SELECT is_outlier FROM iqr_flags_only(f,c);          -- FPGA
    //   SELECT is_outlier FROM iqr_cpu_flags_groupby(f,c);   -- CPU
    // differ in nothing but where the quartiles and the fence compare run. See RESULTS.md 9.29.
    TableFunction iqr_cpu_flags_groupby("iqr_cpu_flags_groupby",
                                        {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                        IqrCpuFlagsFunction, IqrCpuFlagsBind,
                                        IqrCpuGroupByInitGlobal, IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_cpu_flags_groupby);

    // Raw StreamProfiler read (no args): SELECT * FROM iqr_profiler(); returns the cumulative regs 7-14
    // so you can snapshot/subtract manually around your own queries (accumulation under your control).
    TableFunction iqr_profiler("iqr_profiler", {}, IqrProfilerFunction, IqrProfilerBind, IqrProfilerInit);
    loader.RegisterFunction(iqr_profiler);

    // Built-in ColumnChunkDecoder StreamProfilers (one row per decoder lane): SELECT * FROM
    // decoder_profiler(); shows where the DECODER spends time. HW auto-resets after each read.
    TableFunction decoder_profiler("decoder_profiler", {}, DecoderProfilerFunction, DecoderProfilerBind,
                                   DecoderProfilerInit);
    loader.RegisterFunction(decoder_profiler);
}

} // namespace duckdb

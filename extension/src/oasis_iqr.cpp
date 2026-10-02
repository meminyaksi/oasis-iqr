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
#include "parcore/metadata/metadata.hpp"
#include "parcore_metadata_util.hpp"
#include "parquet_reader.hpp"

#include <algorithm>
#include <atomic>
#include <condition_variable>
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
// IQR outlier detection over one 64-bit integer column of a Parquet file.
//
//   iqr_flags_only(path, column)         decodes the column on the FPGA's ParCore decoders and runs
//                                        the IQR_detection operator on it.
//   iqr_cpu_flags_groupby(path, column)  the CPU baseline: DuckDB's parquet reader + an exact
//                                        GROUP BY / ORDER BY quartile computation in C++.
//
// Both are pipeline-breaking table functions (the quartiles are global, so the whole column must be
// seen before any row can be flagged). The work runs once in InitGlobal; the packed bitmask is then
// emitted as one BOOLEAN `is_outlier` row per input row through the same EmitFlagSlice code.
// ---------------------------------------------------------------------------------------------

namespace {

struct IqrFlagsBindData : public TableFunctionData {
    string      filename;
    string      column_name;
    idx_t       column_id = DConstants::INVALID_INDEX; // index of the target column in the file
    LogicalType column_type;                           // its type (must be a 64-bit integer)
    bool        is_signed = true;                      // BIGINT -> signed, UBIGINT -> unsigned

    // Parsed footer, captured at bind time and shared, so it is parsed once rather than per reader.
    shared_ptr<ParquetFileMetadataCache> parquet_metadata;
};

// The result of the FPGA operator. Emission is embarrassingly parallel -- `flags` is read-only and
// every row is independent -- so workers claim disjoint STANDARD_VECTOR_SIZE slices off a cursor.
struct IqrFlagsGlobalState : public GlobalTableFunctionState {
    std::shared_ptr<libstf::Buffer> column; // the gathered decoded column (non-fused path only)
    std::shared_ptr<libstf::Buffer> flags;  // packed outlier bitmask (1 bit/element)
    size_t                          num_elements = 0;
    std::atomic<size_t>             cursor {0}; // next element to claim

    // DuckDB clamps parallelism to min(MaxThreads(), scheduler threads). One worker per output chunk.
    idx_t MaxThreads() const override {
        return MaxValue<idx_t>(1, (num_elements + STANDARD_VECTOR_SIZE - 1) / STANDARD_VECTOR_SIZE);
    }
};

// No per-worker state: emission reads only the shared, immutable result.
struct IqrFlagsLocalState : public LocalTableFunctionState {};

// ---------------------------------------------------------------------------------------------
// FPGA path
// ---------------------------------------------------------------------------------------------

// Row groups kept in flight on the decoders. Must be at least (decoder lanes x scheduler pipeline
// depth) to keep every lane fed; larger only costs memory (one sink buffer per group in flight).
constexpr size_t DECODE_WINDOW = 16;

// Number of histogram bins built into the bitstream.
constexpr int64_t IQR_HW_NUM_BINS = oasis::IqrRunner::NUM_BINS;

// Columns with at least this many rows use the fused path; smaller ones use the two-pass path.
// Fusion removes pass 1's PCIe transfer, a saving that grows with the row count, but it needs the
// histogram window before decoding starts, which costs a fixed FPGA window sample (below). On the
// real datasets fusion only pays off at sf10 scale; on taxi_d3/d4 (13M/20M rows, ragged row groups
// and heavy tails) it loses.
constexpr size_t FUSE_MIN_ROWS = 30000000;

// Window sample for the fused path: this many row groups, spread uniformly across the column (first
// and last included), each stride-sampled down to WINDOW_SAMPLES_PER_GROUP values. Coverage matters
// more than density: a sample taken from a prefix of the column flags almost every row on data whose
// values drift with row order.
constexpr size_t WINDOW_GROUPS            = 16;
constexpr size_t WINDOW_SAMPLES_PER_GROUP = 2048;

// Wraps one fetched compressed column-chunk slice as a LocalSourceOperator, copying the bytes into a
// memory-pool buffer so the fetcher may be released while the flow is still in flight.
std::unique_ptr<oasis::SourceOperator> MakeHostSourceCopy(oasis::OasisContext &ctx,
                                                          const CoalescedFetcher::RangeView &view) {
    void *ptr = nullptr;
    auto  st  = ctx.memory_pool()->allocate(view.size, &ptr);
    if (!st.ok()) {
        throw IOException("iqr_flags_only: could not allocate input buffer: " + st.message());
    }
    std::memcpy(ptr, view.data(), view.size);
    auto buffer = libstf::make_buffer(ctx.memory_pool(), ptr, view.size, view.size);
    return std::make_unique<oasis::LocalSourceOperator>(std::move(buffer));
}

// Builds the source -> decode -> sink flow for one row group's chunk of the target column.
oasis::QuerySplinter MakeDecodeSplinter(oasis::OasisContext &ctx, FileHandle &file_handle,
                                        const parcore::metadata::RowGroup &group, size_t col,
                                        size_t gi) {
    const auto &cc   = group.chunks[col];
    auto        type = parcore::metadata::to_libstf_type(cc.type);

    // Full byte span of the row group ([min chunk offset, max chunk end) over ALL chunks).
    uint64_t span_begin = std::numeric_limits<uint64_t>::max();
    uint64_t span_end   = 0;
    for (const auto &c : group.chunks) {
        span_begin = std::min<uint64_t>(span_begin, c.offset);
        span_end   = std::max<uint64_t>(span_end, c.offset + c.total_compressed_size);
    }
    CoalescedFetcher fetcher(file_handle, ctx.memory_pool(), {span_begin, span_end - span_begin});
    auto             handle = fetcher.Register(cc.offset, cc.total_compressed_size);
    fetcher.PrepareReads();
    for (size_t i = 0; i < fetcher.num_reads(); i++) {
        fetcher.ExecuteMergedRead(i);
    }

    oasis::QuerySplinter splinter;
    oasis::OperatorFlow  flow;
    flow.push_back(MakeHostSourceCopy(ctx, fetcher.Resolve(handle)));
    flow.push_back(std::make_unique<oasis::DecodeColumnChunkOperator>(cc.compression, cc.num_values, type));
    // Each sink is its own registered output buffer: the decode-completion interrupt is routed per
    // allocation, so a slice of a shared buffer would never complete.
    flow.push_back(std::make_unique<oasis::LocalSinkOperator>(
        ctx.allocate_output_buffer(cc.num_values * libstf::size_of(type)), gi));
    splinter.streams.push_back(std::move(flow));
    return splinter;
}

// Turns a sample into the histogram window (bin_min, bin_shift): the 4096 bins cover
// [Q1 - 2*IQR, Q3 + 2*IQR] of the sample, i.e. the 1.5*IQR fences plus a 0.5*IQR estimation margin,
// falling back to [p1, p99] when the IQR is degenerate. Robust percentiles, not min/max: taxi_d4
// spans -128540..33407632 while the fares live in 0..5000, so a min/max window would put every value
// in bin 0. Same rule as IqrRunner::derive_window, which sizes the window on the two-pass path.
// Consumes `sample` (reorders it). Returns false if there is nothing usable to measure.
bool WindowFromSample(std::vector<int64_t> &sample, int64_t &bin_min_out, uint64_t &bin_shift_out) {
    if (sample.size() < 2) {
        return false;
    }
    // nth_element, not sort: only two order statistics are needed, and selection is O(n). The two
    // selections compose: after the first, everything below k_lo sits left of it, so the second
    // only has to partition the remaining suffix.
    const size_t m = sample.size();

    int64_t lo, hi;
    bool    used_iqr = false;
    {
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
            lo       = q1 - 2 * iqr;
            hi       = q3 + 2 * iqr;
            used_iqr = true;
        }
    }
    if (!used_iqr) {
        const size_t k1  = m * 1 / 100;
        const size_t k99 = std::min(m - 1, m * 99 / 100);
        std::nth_element(sample.begin(), sample.begin() + k1, sample.end());
        lo = sample[k1];
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

// Derives the histogram window for the fused path before the column is decoded: the WINDOW_GROUPS
// spanning row groups are decoded on the FPGA (with fusion still off, since the bins do not exist
// yet), stride-sampled, and fed to WindowFromSample. Those groups therefore decode twice, a few ms of
// FPGA time, and the host never decompresses anything. Returns false if no usable sample could be
// taken; the caller then uses the two-pass path.
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

    // Uniformly spaced, first and last always included.
    const size_t        k = std::min(WINDOW_GROUPS, live.size());
    std::vector<size_t> picks;
    picks.reserve(k);
    for (size_t i = 0; i < k; i++) {
        picks.push_back(live[(k == 1) ? 0 : (i * (live.size() - 1)) / (k - 1)]);
    }
    picks.erase(std::unique(picks.begin(), picks.end()), picks.end());

    struct InFlight {
        oasis::SplinterResultHandle result;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlight> in_flight;
    std::vector<int64_t> sample;
    sample.reserve(picks.size() * WINDOW_SAMPLES_PER_GROUP);

    auto drain_one = [&]() {
        InFlight g = std::move(in_flight.front());
        in_flight.pop_front();
        auto batch = g.result.get_next_batch();
        if (!batch) {
            throw InternalException("iqr_flags_only: window decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }
        const int64_t *p      = static_cast<const int64_t *>(batch->buffer->ptr);
        const size_t   stride = std::max<size_t>(1, g.num_values / WINDOW_SAMPLES_PER_GROUP);
        for (size_t i = 0; i < g.num_values; i += stride) {
            sample.push_back(p[i]);
        }
    };

    for (size_t gi : picks) {
        in_flight.push_back({ctx.scheduler().submit(MakeDecodeSplinter(ctx, *file_handle, meta.groups[gi],
                                                                       col, gi)),
                             meta.groups[gi].chunks[col].num_values, gi});
        if (in_flight.size() >= DECODE_WINDOW) {
            drain_one();
        }
    }
    while (!in_flight.empty()) {
        drain_one();
    }

    return WindowFromSample(sample, bin_min_out, bin_shift_out);
}

// Decodes the target column across every row group on the ParCore decoders. Each group is one
// QuerySplinter (source -> decode -> sink); the scheduler dispatches them asynchronously across the
// decoder lanes and DECODE_WINDOW of them are kept in flight, so the FPGA decodes earlier groups
// while the host fetches later ones.
//
// `start_fused` is called once with the column's element count, before any group is submitted.
//   returns false -> the per-group outputs are gathered into one contiguous column, which is
//                    returned (the two-pass path: IqrRunner::run streams it twice).
//   returns true  -> the per-group output buffers are appended to `chunks_out` in column order and
//                    nothing is returned (the fused path: pass 1 already ran on-chip during decode,
//                    and IqrRunner::finish_fused streams these chunks for pass 2).
std::shared_ptr<libstf::Buffer> DecodeColumnAllGroups(
    ClientContext &context, oasis::OasisContext &ctx, const IqrFlagsBindData &bind,
    size_t &num_values_out, std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> &chunks_out,
    const std::function<bool(size_t)> &start_fused) {
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

    const bool stream = start_fused(total);

    // Two-pass path: one contiguous int64 destination for the whole column, allocated through the
    // output-buffer path so its address/capacity satisfy the hardware enqueue rules.
    size_t total_bytes = total * sizeof(int64_t);
    auto   values      = stream ? nullptr : ctx.allocate_output_buffer(total_bytes);
    void  *dst         = stream ? nullptr : values->ptr;
    if (!stream) {
        ctx.tlb_manager()->ensure_tlb_mapping(dst, values->capacity);
    }

    struct InFlightGroup {
        oasis::SplinterResultHandle result;
        size_t                      off_elems;
        size_t                      num_values;
        size_t                      gi;
    };
    std::deque<InFlightGroup> in_flight;

    // On the two-pass path each group's sink is copied into its place in `values`. The copies are
    // independent and write disjoint ranges, so they run on a pool of threads in batches.
    struct PendingCopy {
        std::shared_ptr<libstf::Buffer> src;
        size_t                          off_elems;
        size_t                          num_values;
    };
    std::vector<PendingCopy> copies;

    auto drain_one = [&]() {
        InFlightGroup g = std::move(in_flight.front());
        in_flight.pop_front();

        auto batch = g.result.get_next_batch();
        if (!batch) {
            throw InternalException("iqr_flags_only: decode of row group %llu produced no output",
                                    (unsigned long long)g.gi);
        }
        if (stream) {
            // The FIFO pop is submission (row-group) order, so the chunks stay in column order.
            chunks_out.emplace_back(batch->buffer, g.num_values * sizeof(int64_t));
        } else {
            copies.push_back({batch->buffer, g.off_elems, g.num_values});
        }
    };

    auto run_copies = [&]() {
        if (copies.empty()) {
            return;
        }
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
    };

    // Flush the copies in batches so the sink buffers held at once stay bounded.
    const size_t copy_batch = std::max<size_t>(8, 2 * std::thread::hardware_concurrency());

    size_t off_elems = 0;
    for (size_t gi : live) {
        const size_t nv = meta.groups[gi].chunks[col].num_values;
        in_flight.push_back(
            {ctx.scheduler().submit(MakeDecodeSplinter(ctx, *file_handle, meta.groups[gi], col, gi)),
             off_elems, nv, gi});
        off_elems += nv;

        if (in_flight.size() >= DECODE_WINDOW) {
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

// Decodes the target column and runs the IQR operator on it, storing the packed flags in `gstate`.
void RunHeavyPhase(ClientContext &context, const IqrFlagsBindData &bind, IqrFlagsGlobalState &gstate) {
    auto &ctx = GetOrCreateOasisContext(context);

    oasis::IqrRunner runner(ctx, bind.is_signed);

    // Fused when the column is large enough and the window sample succeeds. The device must be
    // armed before the first group decodes: decoding then drives pass 1 through the on-chip tee.
    auto start_fused = [&](size_t total_elements) {
        if (total_elements < FUSE_MIN_ROWS) {
            return false;
        }
        int64_t  bin_min   = 0;
        uint64_t bin_shift = 0;
        if (!DeriveWindowFromFpga(context, ctx, bind, bin_min, bin_shift)) {
            return false;
        }
        runner.begin_fused(bin_min, bin_shift, total_elements);
        return true;
    };

    size_t n = 0;
    std::vector<std::pair<std::shared_ptr<libstf::Buffer>, size_t>> chunks; // fused path only
    gstate.column       = DecodeColumnAllGroups(context, ctx, bind, n, chunks, start_fused);
    gstate.num_elements = n;
    if (n == 0) {
        return; // empty column -> no rows, no flags
    }

    std::vector<oasis::IqrRunner::InputChunk> inputs;
    if (gstate.column) {
        inputs.emplace_back(gstate.column->ptr, n * sizeof(int64_t));
        gstate.flags = runner.run(inputs).flags;
    } else {
        inputs.reserve(chunks.size());
        for (const auto &c : chunks) {
            inputs.emplace_back(c.first->ptr, c.second);
        }
        gstate.flags = runner.finish_fused(inputs).flags;
    }
}

// Resolves (file, column) to a validated IqrFlagsBindData: locates the target column, checks it is a
// 64-bit integer, and captures its signedness. `fn` names the caller for error messages.
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

unique_ptr<FunctionData> IqrFlagsOnlyBind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
    auto bind_data = ResolveIqrColumn(context, StringValue::Get(input.inputs[0]),
                                      StringValue::Get(input.inputs[1]), "iqr_flags_only");
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

// Unpacks `emit` flags starting at element `start` out of a packed bitmask into a single BOOLEAN
// output vector. Shared by iqr_flags_only (FPGA) and iqr_cpu_flags_groupby (CPU): both produce the
// same packed layout, so the output path of the two operators is the same code and only the compute
// differs in the head-to-head.
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

void IqrFlagsOnlyFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &gstate = data_p.global_state->Cast<IqrFlagsGlobalState>();

    // Claim a disjoint slice of rows. Workers never overlap, so no lock is needed past this point.
    size_t start = gstate.cursor.fetch_add(STANDARD_VECTOR_SIZE, std::memory_order_relaxed);
    if (start >= gstate.num_elements) {
        output.SetChildCardinality(0);
        return;
    }
    size_t emit = std::min<size_t>(STANDARD_VECTOR_SIZE, gstate.num_elements - start);

    EmitFlagSlice(reinterpret_cast<const uint8_t *>(gstate.flags->ptr), start, emit, output);
}

// ---------------------------------------------------------------------------------------------
// CPU baseline: iqr_cpu_flags_groupby
//
// The apples-to-apples twin of iqr_flags_only: same bind, same validation, same packed-bitmask
// output, same emit code (EmitFlagSlice). The only difference is that decoding, the quartiles and
// the fence comparison run on the host cores instead of on the FPGA.
//
// It is a direct C++ transliteration of the SQL formulation, statement for statement:
//
//     ecnt AS (SELECT v, count(*) c FROM s GROUP BY v)          -> radix-partitioned hash aggregate
//     ecum AS (SELECT v, sum(c) OVER (ORDER BY v) cc FROM ecnt) -> sort the DISTINCT values, scan
//     eq   AS (min(v) WHERE cc*4>=t / cc*4>=3*t)                -> first hit in that scan
//     ef   AS (q1-(d+(d>>1)), q3+(d+(d>>1)))                    -> IqrFences
//     SELECT (v < lo OR v > hi)                                 -> ComputeFlagMask
//
// i.e. q1 is the ceil(N/4)-th smallest value, q3 the ceil(3N/4)-th, and the fences are the exact
// 1.5*IQR rule. Writing it in C++ rather than SQL makes the baseline measure the machine rather than
// DuckDB's parser/optimizer, while keeping the same algorithm as the SQL.
//
// Shape: a hash aggregate over N followed by a sort over D (the distinct count) -- the same shape as
// DuckDB's plan, not a sort over N. Memory is O(D) per partition.
// ---------------------------------------------------------------------------------------------

// The materialised column, allocated through DuckDB's pooled allocator (the FPGA path also uses
// pooled buffers, so both arms get the same memory machinery). Not value-initialised: the parallel
// parquet read first-touches the pages, so the page faults are spread across all workers instead
// of one memset.
struct CpuColumn {
    AllocatedData pooled;
    int64_t      *ptr = nullptr;

    void Allocate(ClientContext &context, size_t n_elems) {
        pooled = Allocator::Get(context).Allocate(n_elems * sizeof(int64_t));
        ptr    = reinterpret_cast<int64_t *>(pooled.get());
    }
    // Releasing the column is a real cost of the CPU approach, so it happens inside the operator.
    void Release() {
        pooled.Reset();
        ptr = nullptr;
    }
};

// DuckDB's configured worker count (PRAGMA threads), so the CPU baseline gets exactly the
// parallelism the user asked for.
size_t CpuThreadCount(ClientContext &context) {
    int32_t n = TaskScheduler::GetScheduler(context).NumberOfThreads();
    return n < 1 ? 1u : static_cast<size_t>(n);
}

// A persistent worker pool behind ParallelRanges. The CPU operator calls ParallelRanges several times
// per query (count, scatter, aggregate, sort, flags); creating and joining fresh threads on every
// call cost ~4 ms of pure dispatch per query at 32 threads.
//
// Callers may throw from inside the parallel region (ReadColumnCpu raises on a short read); the pool
// captures the first exception and rethrows it on the caller's thread instead of terminating.
class IqrThreadPool {
public:
    static IqrThreadPool &Get() {
        static IqrThreadPool pool;
        return pool;
    }

    // Runs body(worker_id, worker_count) on every pooled thread. The CALLER maps its logical ranges
    // onto worker_count workers -- see ParallelRanges, which strides. worker_count is the pool size,
    // not the caller's requested thread count.
    //
    // Returns false if the pool is already in use (a nested or concurrent call), so the caller can
    // fall back to spawning threads.
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
// thread_idx is always < nthreads, so callers can index per-thread scratch by it. Passes that must
// agree on ranges (the GROUP BY count and scatter passes) get identical chunking.
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
    // the pool; mapping ranges 1:1 onto workers would drop ranges when nthreads > pool size. Distinct
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

// The CPU twin of IqrFlagsGlobalState: owns plain host memory, so this operator runs with no FPGA.
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

// Bottom-up parallel merge sort over the (value, count) pairs -- the ORDER BY over the distinct
// values. Each round merges disjoint adjacent pairs of runs, so every round is parallel and needs no
// coordination; it matters on high-cardinality columns (extprice, sf10) where D is ~1 M.
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
    // does NOT initialise (a std::vector would memset it first).
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

// Computes the exact quartiles of `raw` (GROUP BY + ORDER BY, as the SQL does) and writes the packed
// outlier bitmask into `mask`.
template <class T>
void IqrCpuCoreGroupBy(const int64_t *raw, size_t n, size_t nt, uint8_t *mask) {
    using U = typename std::make_unsigned<T>::type;
    const T *v = reinterpret_cast<const T *>(raw);

    // ---- ecnt: GROUP BY v, RADIX-PARTITIONED --------------------------------------------------
    // Partitioning by hash first makes the partitions disjoint, so each one aggregates independently
    // and nothing has to be merged afterwards (a per-thread table + serial combine was ~20x slower on
    // sf10). Cost: one extra pass and a scatter buffer the size of the column; in exchange every
    // partition's working set fits in cache.
    constexpr size_t P     = 256;     // partitions; keeps each working set well under L2 at D ~ 1.4 M
    constexpr size_t PMASK = P - 1;

    auto hash_of = [](U x) {          // multiplicative hash; the low bits select the partition
        uint64_t h = static_cast<uint64_t>(x) * 0x9E3779B97F4A7C15ull;
        return static_cast<size_t>(h ^ (h >> 29));
    };

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

    // Pass 2 -- scatter. Disjoint destinations by construction, so no atomics. `new T[n]` rather than
    // std::vector: a vector would memset the whole buffer on one thread before the scatter overwrites
    // every byte of it.
    std::unique_ptr<T[]> buf_owner(new T[n]);
    T *const             buf = buf_owner.get();
    ParallelRanges(n, nt, [&](size_t t, size_t lo, size_t hi) {
        auto local = off[t]; // by value: keeps the cursors in registers/L1 rather than shared memory
        for (size_t i = lo; i < hi; i++) {
            buf[local[hash_of(static_cast<U>(v[i])) & PMASK]++] = v[i];
        }
    });

    // Pass 3 -- aggregate each partition independently.
    std::vector<std::vector<std::pair<T, uint64_t>>> pairs(P);
    const size_t                                     agg_nt = std::min<size_t>(nt, P);
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

    size_t n_distinct = 0;
    for (size_t p = 0; p < P; p++) {
        n_distinct += pairs[p].size();
    }

    // ---- ecum + eq: ORDER BY v, cumulative count, first value past each rank -------------------
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
    std::vector<std::pair<T, uint64_t>>().swap(ord); // release the pair array before the flag pass

    // ---- SELECT (v < lo OR v > hi) ------------------------------------------------------------
    ComputeFlagMask<T>(v, n, lo, hi, mask, nt);
}

void RunHeavyPhaseCpuGroupBy(ClientContext &context, const IqrFlagsBindData &bind,
                             IqrCpuGlobalState &gstate) {
    const size_t nt = CpuThreadCount(context);

    CpuColumn    values;
    const size_t n      = ReadColumnCpu(context, bind, nt, values);
    gstate.num_elements = n;
    if (n == 0) {
        return;
    }
    gstate.flags.reset(new uint8_t[(n + 7) / 8]);

    if (bind.is_signed) {
        IqrCpuCoreGroupBy<int64_t>(values.ptr, n, nt, gstate.flags.get());
    } else {
        IqrCpuCoreGroupBy<uint64_t>(values.ptr, n, nt, gstate.flags.get());
    }
    values.Release();
}

unique_ptr<GlobalTableFunctionState> IqrCpuGroupByInitGlobal(ClientContext &context,
                                                             TableFunctionInitInput &input) {
    auto &bind   = input.bind_data->Cast<IqrFlagsBindData>();
    auto  gstate = make_uniq<IqrCpuGlobalState>();
    RunHeavyPhaseCpuGroupBy(context, bind, *gstate);
    return std::move(gstate);
}

} // namespace

void RegisterOasisIqrFunction(ExtensionLoader &loader) {
    // FPGA operator: one BOOLEAN is_outlier row per input row.
    TableFunction iqr_flags_only("iqr_flags_only", {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                 IqrFlagsOnlyFunction, IqrFlagsOnlyBind, IqrFlagsInitGlobal,
                                 IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_flags_only);

    // CPU baseline with the same signature, schema and emit path, so
    //   SELECT is_outlier FROM iqr_flags_only(f,c);          -- FPGA
    //   SELECT is_outlier FROM iqr_cpu_flags_groupby(f,c);   -- CPU
    // differ in nothing but where decoding, the quartiles and the fence compare run.
    TableFunction iqr_cpu_flags_groupby("iqr_cpu_flags_groupby",
                                        {LogicalType::VARCHAR, LogicalType::VARCHAR},
                                        IqrCpuFlagsFunction, IqrCpuFlagsBind,
                                        IqrCpuGroupByInitGlobal, IqrFlagsInitLocal);
    loader.RegisterFunction(iqr_cpu_flags_groupby);
}

} // namespace duckdb

#include "oasis/iqr_runner.hpp"

#include <libstf/buffer.hpp>
#include <libstf/util.hpp>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace oasis {

namespace {

// The device packs the flags into a dense bitmask (1 bit/element) emitted as full 512-bit beats, so
// the output is ceil(N/512) 64-byte beats -- 64x smaller than an INT64-per-flag column.
constexpr size_t FLAG_BITS_PER_BEAT  = 512;
constexpr size_t FLAG_BYTES_PER_BEAT = FLAG_BITS_PER_BEAT / 8;

size_t flag_bytes_for(size_t num_elements) {
    size_t beats = (num_elements + FLAG_BITS_PER_BEAT - 1) / FLAG_BITS_PER_BEAT;
    return beats * FLAG_BYTES_PER_BEAT;
}

// -- Ragged-chunk flag stitch -----------------------------------------------------------------------
// When pass 2 streams several chunks (one transfer per row group), the device asserts `last` only on
// the final chunk, and FlagBitPacker shifts in 8 bits per beat regardless of the beat's keep. So each
// chunk c lands as 8*ceil(nv_c/8) bits: its nv_c flags plus up to 7 zero pad bits when the chunk is
// not a whole number of 8 elements. The packing is dense only when every chunk except the last is a
// multiple of 8; real files (taxi, sf10) have ragged row groups, so the drain is sized for the padded
// footprint and folded back into a dense bitmask by repack_ragged_flags().
bool has_intermediate_ragged(const std::vector<IqrRunner::InputChunk> &chunks) {
    if (chunks.size() < 2) return false;
    for (size_t i = 0; i + 1 < chunks.size(); i++)
        if ((chunks[i].second / sizeof(int64_t)) % 8 != 0) return true;
    return false;
}

size_t padded_flag_bytes(const std::vector<IqrRunner::InputChunk> &chunks) {
    size_t padded_bits = 0;
    for (const auto &c : chunks)
        padded_bits += ((c.second / sizeof(int64_t) + 7) / 8) * 8;   // byte-padded per chunk
    size_t beats = (padded_bits + FLAG_BITS_PER_BEAT - 1) / FLAG_BITS_PER_BEAT;
    return beats * FLAG_BYTES_PER_BEAT;
}

} // namespace

IqrRunner::IqrRunner(OasisContext &ctx, bool is_signed)
    : ctx_(ctx), iqr_config_(ctx.config<IqrConfig>()) {
    // The vFPGA top reinterprets the incoming bytes as 64-bit values, so only signedness is set.
    iqr_config_->set_signed(is_signed);
}

size_t IqrRunner::count_elements(const std::vector<InputChunk> &inputs) {
    size_t total = 0;
    for (const auto &chunk : inputs) {
        total += chunk.second / sizeof(int64_t);
    }
    return total;
}

void IqrRunner::derive_window(const std::vector<InputChunk> &inputs) {
    // Stride-sample the column (cheap; it only sizes the bins -- the FPGA still histograms every row).
    size_t total = count_elements(inputs);
    if (total == 0) {
        bin_min_   = 0;
        bin_shift_ = 0;
        return;
    }

    // Seek directly to each sampled index instead of walking every element: a few thousand values out
    // of tens of millions, so only that many cache lines are touched.
    std::vector<int64_t> sample;
    sample.reserve(std::min<size_t>(total, SAMPLE_TARGET));
    size_t step = std::max<size_t>(1, total / SAMPLE_TARGET);

    size_t chunk_base = 0; // index of the first element of the current chunk
    size_t c          = 0;
    for (size_t idx = 0; idx < total; idx += step) {
        // Advance to the chunk containing `idx` (indices are non-decreasing, so this walks forward).
        while (c < inputs.size() && idx >= chunk_base + inputs[c].second / sizeof(int64_t)) {
            chunk_base += inputs[c].second / sizeof(int64_t);
            ++c;
        }
        if (c >= inputs.size()) {
            break;
        }
        const int64_t *p = reinterpret_cast<const int64_t *>(inputs[c].first);
        sample.push_back(p[idx - chunk_base]);
    }

    std::sort(sample.begin(), sample.end());
    size_t m = sample.size();

    // Cover [Q1 - 2*IQR, Q3 + 2*IQR]: the 1.5*IQR fences plus a 0.5*IQR estimation margin. Tying the
    // bin width to the IQR keeps the fences on fine bins even on tail-heavy columns. Same rule as
    // WindowFromSample() in the extension, which sizes the window for the fused path. Falls back to
    // [p1, p99] when the IQR is degenerate (q1 == q3).
    int64_t lo, hi;
    int64_t q1  = sample[m / 4];
    int64_t q3  = sample[std::min(m - 1, m * 3 / 4)];
    int64_t iqr = q3 - q1;
    if (iqr > 0) {
        lo = q1 - 2 * iqr;
        hi = q3 + 2 * iqr;
    } else {
        lo = sample[m * 1 / 100];                     // ~1st percentile
        hi = sample[std::min(m - 1, m * 99 / 100)];   // ~99th percentile
    }
    int64_t range = hi - lo;

    if (range <= 0) {
        bin_min_   = lo;
        bin_shift_ = 0;
        return;
    }

    // bin width = ceil(range / NUM_BINS), rounded up to a power of two (the HW shifts).
    uint64_t width = static_cast<uint64_t>((range + NUM_BINS - 1) / NUM_BINS);
    uint64_t shift = 0;
    while ((1ull << shift) < width) {
        ++shift;
    }
    int64_t binw = static_cast<int64_t>(1ull << shift);

    // Floor-align the low edge to a bin boundary (correct for negative lo too).
    bin_min_   = (lo >= 0) ? (lo / binw) * binw : -(((-lo) + binw - 1) / binw) * binw;
    bin_shift_ = shift;
}

void IqrRunner::stream_pass(const std::vector<InputChunk> &inputs) {
    size_t last = inputs.size() - 1;
    for (size_t i = 0; i < inputs.size(); ++i) {
        libstf::enqueue_stream_input(ctx_.cthread(), ctx_.tlb_manager(), inputs[i].first,
                                     inputs[i].second,
                                     static_cast<libstf::stream_t>(ctx_.iqrStream()), i == last);
    }
}

void IqrRunner::clear_histogram_fenced() {
    // The clear is a posted CSR write on the control plane; the input DMA travels the data plane with
    // no mutual ordering. If pass-1 beats reach the core before the clear does, they get binned then
    // wiped. The device advances a clear-completion counter when a sweep finishes: capture it, pulse
    // clear, then spin until it advances -- at which point the banks are zero and the core is ready.
    uint64_t clr_seq0 = iqr_config_->clear_seq();
    iqr_config_->clear_histogram();
    for (uint64_t spins = 0; iqr_config_->clear_seq() == clr_seq0; ++spins) {
        if (spins > 100000000ull) {
            throw std::runtime_error("IqrRunner: timed out waiting for histogram clear to complete");
        }
    }
}

std::shared_ptr<libstf::Buffer>
IqrRunner::drain_to_buffer(BypassStreamReceiver::Handle &handle, size_t total_bytes) {
    // next() blocks on the completion interrupt and returns nullptr once the transfer is drained.
    std::vector<std::shared_ptr<libstf::Buffer>> chunks;
    while (auto buffer = handle.next()) {
        chunks.push_back(buffer);
    }
    if (chunks.empty()) {
        throw std::runtime_error("IqrRunner: transfer drained no buffers");
    }
    if (chunks.size() == 1) {
        return chunks.front();
    }
    void *ptr    = nullptr;
    auto  status = ctx_.memory_pool()->allocate(total_bytes, &ptr);
    if (!status.ok()) {
        throw std::runtime_error("IqrRunner: failed to allocate drain buffer: " + status.message());
    }
    size_t off = 0;
    for (const auto &c : chunks) {
        std::memcpy(static_cast<std::byte *>(ptr) + off, c->ptr, c->size);
        off += c->size;
    }
    return libstf::make_buffer(ctx_.memory_pool(), ptr, total_bytes, total_bytes);
}

// Each chunk's flags start on a BYTE boundary in `padded` (the device shifts whole bytes), so the
// source read is byte-aligned; the destination is fully packed.
std::shared_ptr<libstf::Buffer>
IqrRunner::repack_ragged_flags(const std::shared_ptr<libstf::Buffer> &padded,
                               const std::vector<InputChunk> &chunks, size_t num_elements) {
    const uint8_t *src       = static_cast<const uint8_t *>(padded->ptr);
    size_t         dst_bytes = flag_bytes_for(num_elements);
    void          *ptr       = nullptr;
    auto           status    = ctx_.memory_pool()->allocate(dst_bytes, &ptr);
    if (!status.ok()) {
        throw std::runtime_error("IqrRunner: failed to allocate flag repack buffer: " +
                                 status.message());
    }
    auto dst = static_cast<uint8_t *>(ptr);
    std::memset(dst, 0, dst_bytes);

    // OR the low n (<=8) bits of `bits` into dst at bit position `bit` (LSB-first). Spans at most two
    // bytes.
    auto put_bits = [](uint8_t *d, size_t bit, uint8_t bits, int n) {
        for (int j = 0; j < n; j++)
            if ((bits >> j) & 1u) d[(bit + j) >> 3] |= static_cast<uint8_t>(1u << ((bit + j) & 7));
    };

    size_t src_bit = 0;   // byte-aligned at each chunk boundary
    size_t dst_bit = 0;   // contiguous
    for (const auto &c : chunks) {
        size_t         nv   = c.second / sizeof(int64_t);
        const uint8_t *sb   = src + (src_bit >> 3);   // src_bit is a multiple of 8
        size_t         full = nv >> 3;
        int            rem  = static_cast<int>(nv & 7);
        for (size_t b = 0; b < full; b++) { put_bits(dst, dst_bit, sb[b], 8); dst_bit += 8; }
        if (rem) { put_bits(dst, dst_bit, sb[full], rem); dst_bit += static_cast<size_t>(rem); }
        src_bit += ((nv + 7) / 8) * 8;               // past this chunk's byte-padded footprint
    }
    return libstf::make_buffer(ctx_.memory_pool(), ptr, dst_bytes, dst_bytes);
}

void IqrRunner::begin_fused(int64_t bin_min, uint64_t bin_shift, size_t expected_elements) {
    bin_min_   = bin_min;
    bin_shift_ = bin_shift;
    iqr_config_->set_bin_min(bin_min_);
    iqr_config_->set_bin_shift(bin_shift_);

    // Order matters: the element count and the enable must be in place BEFORE the clear pulse,
    // because that same pulse re-arms the feed's element counter on the device.
    iqr_config_->set_hist_expected(expected_elements);
    iqr_config_->set_fuse_enable(true);

    clear_histogram_fenced();
    fused_ = true;
}

IqrRunner::Result IqrRunner::finish_fused(const std::vector<InputChunk> &inputs) {
    if (!fused_) {
        throw std::runtime_error("IqrRunner: finish_fused() called before begin_fused()");
    }
    fused_ = false;

    Result result;
    result.num_elements = count_elements(inputs);
    if (result.num_elements == 0) {
        iqr_config_->set_fuse_enable(false);
        return result;
    }

    // Pass 1 ran on-chip during decode. Wait for the feed to have sent its terminating `last` before
    // enqueuing pass 2, bounded in wall clock so a stalled feed becomes a readable error rather than
    // a hang.
    {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (!iqr_config_->feed_done()) {
            if (std::chrono::steady_clock::now() > deadline) {
                iqr_config_->set_fuse_enable(false);   // unpark the input mux before giving up
                throw std::runtime_error(
                    "IqrRunner: fused pass 1 did not complete (fed " +
                    std::to_string(iqr_config_->fed_elements()) + " of " +
                    std::to_string(result.num_elements) + " elements, histogram_total " +
                    std::to_string(iqr_config_->histogram_total()) + ")");
            }
        }
    }

    // Pass 2: the flag output buffer must be enqueued before the device emits. Ragged intermediate
    // chunks make the device byte-pad each one, so size the drain for that and fold back below.
    const bool ragged    = has_intermediate_ragged(inputs);
    size_t     out_bytes = ragged ? padded_flag_bytes(inputs) : flag_bytes_for(result.num_elements);
    auto       handle    = ctx_.bypass_receiver().acquire(out_bytes);

    stream_pass(inputs);

    result.flags                   = drain_to_buffer(*handle, out_bytes);
    const uint64_t histogram_total = iqr_config_->histogram_total();
    if (ragged) result.flags = repack_ragged_flags(result.flags, inputs, result.num_elements);

    iqr_config_->set_fuse_enable(false);   // leave the input mux on the host path

    // A miscounted pass 1 yields plausible but wrong quartiles, so check rather than trust.
    if (histogram_total != result.num_elements) {
        throw std::runtime_error("IqrRunner: fused pass 1 histogram total " +
                                 std::to_string(histogram_total) + " != " +
                                 std::to_string(result.num_elements) + " elements");
    }
    return result;
}

IqrRunner::Result IqrRunner::run(const std::vector<InputChunk> &inputs) {
    Result result;
    result.num_elements = count_elements(inputs);
    if (inputs.empty() || result.num_elements == 0) {
        // Nothing to flag. Leave result.flags null; the caller treats this as an empty column.
        return result;
    }

    // 1. Derive and push the histogram window.
    derive_window(inputs);
    iqr_config_->set_bin_min(bin_min_);
    iqr_config_->set_bin_shift(bin_shift_);

    // 2. Flag output size: a dense bitmask, or the byte-padded footprint for ragged chunks.
    const bool ragged    = has_intermediate_ragged(inputs);
    size_t     out_bytes = ragged ? padded_flag_bytes(inputs) : flag_bytes_for(result.num_elements);

    // 3. Zero the histogram, fenced ahead of the input DMA.
    clear_histogram_fenced();

    // 4. Enqueue the flag output buffer BEFORE streaming the input. Output is FPGA-initiated: the
    // OutputWriter fills this buffer during the FLAG pass and signals completion with an interrupt
    // that the bypass receiver collects.
    auto handle = ctx_.bypass_receiver().acquire(out_bytes);

    // 5. Pass 1 builds the histogram; pass 2 re-streams the column and the operator emits the flags.
    stream_pass(inputs); // pass 1: HISTOGRAM
    stream_pass(inputs); // pass 2: FLAG

    // 6. Drain the flags.
    result.flags = drain_to_buffer(*handle, out_bytes);
    if (ragged) result.flags = repack_ragged_flags(result.flags, inputs, result.num_elements);
    return result;
}

} // namespace oasis

#pragma once

#include "oasis/iqr_config.hpp"
#include "oasis/oasis_context.hpp"

#include "oasis/bypass_receiver.hpp"

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

namespace oasis {

/**
 * Drives the IQR_detection vFPGA operator for one 64-bit integer column.
 *
 * The operator makes two passes over the column:
 *   pass 1 (HISTOGRAM) -> the FPGA builds a 4096-bin histogram and, in hardware, derives Q1/Q3 and
 *                         the 1.5*IQR fences (the host never sees the histogram),
 *   pass 2 (FLAG)      -> the column is streamed again and the FPGA emits a packed
 *                         1-bit-per-element outlier bitmask.
 *
 * Two ways to drive it:
 *   run()                          both passes are streamed from host buffers holding the decoded
 *                                  column; the histogram window is derived from that column.
 *   begin_fused() / finish_fused() pass 1 is fed on-chip from the decoder output while the column
 *                                  decodes (no PCIe traffic for pass 1); only pass 2 is streamed.
 *                                  The caller supplies the window, since the runner has not seen
 *                                  the data when pass 1 starts.
 *
 * The runner is single-use per column. The caller owns the decoded-column buffers and must keep
 * them alive until run() / finish_fused() returns.
 */
class IqrRunner {
  public:
    // One contiguous decoded-column chunk to stream: raw pointer + byte size of packed int64 values.
    using InputChunk = std::pair<const void *, size_t>;

    struct Result {
        // Packed outlier bitmask: element i is byte i/8, bit i%8 (1 = outlier).
        std::shared_ptr<libstf::Buffer> flags;
        size_t                          num_elements = 0;
    };

    // Number of histogram bins built into the bitstream (IQR_NUM_BINS in the vFPGA top).
    static constexpr int64_t NUM_BINS = 4096;

    /**
     * @param ctx        the shared oasis context (owns the cThread, memory pool, TLB, configs).
     * @param is_signed  treat the column values as signed (sign-aware binning + fences).
     */
    IqrRunner(OasisContext &ctx, bool is_signed);

    /**
     * Derives the histogram window from `inputs`, streams them through both passes and returns the
     * packed outlier bitmask. The chunks are concatenated logically in order.
     */
    Result run(const std::vector<InputChunk> &inputs);

    /**
     * Fused pass 1. Call begin_fused() before the column is decoded; the hardware then feeds the
     * histogram straight from the decoder output. After decoding, finish_fused() streams pass 2 from
     * the decoded chunks and drains the flags.
     *
     * `expected_elements` must be the exact element count: each decoder lane asserts `last` once per
     * row group, so the on-chip feed regenerates the column's single terminating `last` from this
     * count. finish_fused() verifies histogram_total == N and throws otherwise, because a miscount
     * produces plausible-looking but wrong quartiles rather than an obvious failure.
     */
    void   begin_fused(int64_t bin_min, uint64_t bin_shift, size_t expected_elements);
    Result finish_fused(const std::vector<InputChunk> &inputs);

  private:
    OasisContext              &ctx_;
    std::shared_ptr<IqrConfig> iqr_config_;

    int64_t  bin_min_   = 0;
    uint64_t bin_shift_ = 0;
    bool     fused_     = false;

    static constexpr size_t SAMPLE_TARGET = 8192; // values sampled to size the window in run()

    static size_t count_elements(const std::vector<InputChunk> &inputs);

    // Sets bin_min_/bin_shift_ so the 4096 bins cover [Q1 - 2*IQR, Q3 + 2*IQR] of a stride sample
    // of the column (robust percentiles, so a stray outlier cannot blow up the bin width).
    void derive_window(const std::vector<InputChunk> &inputs);

    // Streams every chunk once to the IQR lane, asserting `last` only on the final chunk.
    void stream_pass(const std::vector<InputChunk> &inputs);

    // Zeroes the histogram banks and blocks until the clear sweep has completed. The clear is a posted
    // CSR write with no ordering against the input DMA, so it must be fenced ahead of pass 1.
    void clear_histogram_fenced();

    // Drains a bypass-receiver transfer into one contiguous buffer.
    std::shared_ptr<libstf::Buffer> drain_to_buffer(BypassStreamReceiver::Handle &handle,
                                                    size_t total_bytes);

    // Folds a flag drain that is byte-padded per chunk (produced when pass 2 streams chunks whose
    // element counts are not multiples of 8) back into a dense 1-bit-per-element bitmask.
    std::shared_ptr<libstf::Buffer> repack_ragged_flags(const std::shared_ptr<libstf::Buffer> &padded,
                                                        const std::vector<InputChunk> &chunks,
                                                        size_t num_elements);
};

} // namespace oasis

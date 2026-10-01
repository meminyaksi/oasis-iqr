#pragma once

#include "oasis/iqr_config.hpp"
#include "oasis/oasis_context.hpp"

#include "oasis/bypass_receiver.hpp"

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

#include <chrono>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace oasis {

/**
 * Drives the IQR_detection vFPGA operator for one column, re-homed on OasisContext.
 *
 * This is the oasis port of celeris::IqrOperator's core: the host streams the (already decoded)
 * 64-bit value column to the device TWICE on stream 0 --
 *   pass 1 (HISTOGRAM) -> the FPGA builds a banked histogram and, in hardware, derives Q1/Q3 and
 *                         the 1.5*IQR fences (the host never sees the histogram),
 *   pass 2 (FLAG)      -> the same column is re-streamed and the FPGA emits a dense, packed
 *                         1-bit-per-element outlier bitmask.
 *
 * The caller (the iqr_flags table function) supplies the decoded column as host buffers. The runner
 * caches nothing of its own across calls -- it is single-use per column, mirroring the standalone
 * operator. Only 64-bit (INT64) columns are supported (the vFPGA top instantiates IQR_detection
 * with value_t = data64_t, an 8x64 ndata layout).
 *
 * NOTE: unlike celeris, the runner does NOT round-trip a Table. The two passes stream the same host
 * buffers the caller passes in -- so the caller owns the decoded-column lifetime for the duration of
 * run().
 */
class IqrRunner {
  public:
    // One contiguous decoded-column chunk to stream: raw pointer + byte size. The runner treats the
    // bytes as packed int64 values.
    using InputChunk = std::pair<const void *, size_t>;

    struct Result {
        // Packed outlier bitmask: ceil(N/512) 64-byte beats, 1 bit per input element (1 = outlier).
        std::shared_ptr<libstf::Buffer> flags;
        size_t                          num_elements = 0;

        // The histogram window actually used (derived in auto mode, else the explicit values).
        int64_t  bin_min   = 0;
        uint64_t bin_shift = 0;

        // Debug: the device's histogram grand total for this run (== num_elements iff the banks were
        // zeroed; a short-fall exposes the silicon count-loss we documented).
        uint64_t histogram_total = 0;

        // Count-loss diagnostics (per run). The chain  num_elements >= accepted >= committed >=
        // histogram_total  localizes where pass-1 counts are lost: accepted < num_elements -> input/
        // DMA; committed < accepted -> coalescing; histogram_total < committed -> BRAM RMW hazard.
        // collisions counts flush-reads that hit a just-written bin (direct hazard evidence);
        // flushes is the BRAM write count.
        uint64_t accepted   = 0;
        uint64_t committed  = 0;
        uint64_t flushes    = 0;
        uint64_t collisions = 0;

        // StreamProfiler cycle breakdown (read after both passes). input_* aggregates the histogram
        // + flag input streams; output_* is the flag emission. starved dominating input => the path
        // is host/DMA-bound (the round-trip HBM staging targets); stalled dominating => back-pressured.
        // NOTE: these device counters are NEVER cleared between processes -- they accumulate for the
        // life of the bitstream. Only differences between consecutive runs are meaningful. Prefer the
        // wall-clock split below.
        IqrConfig::StreamProfile input_profile  = {};
        IqrConfig::StreamProfile output_profile = {};

        // Wall-clock split of run(), which is what actually settles host-vs-card:
        //   stage_ms  = host->HBM staging (memcpy + LOCAL_OFFLOAD). Zero in host mode. This is the
        //               Coyote migration path (4 KB/command, sleep-throttled) -- expected to dominate.
        //   passes_ms = both input passes + draining the flags, i.e. the time the FPGA spends reading
        //               the column (from HBM in card mode, from the host in host mode) and emitting.
        // Dividing 2*N*8 bytes by passes_ms gives the achieved INPUT bandwidth of each source, which
        // is the number the whole HBM question hinges on.
        double stage_ms  = 0.0;
        double passes_ms = 0.0;
    };

    /**
     * @param ctx          the shared oasis context (owns the cThread, memory pool, TLB, configs).
     * @param is_signed    treat the column values as signed (sign-aware binning + fences).
     * @param auto_window  if true, derive bin_min/bin_shift from a sample of the data; if false, use
     *                     the explicit bin_min/bin_shift passed in.
     * @param bin_min      explicit histogram window low edge   (used only when auto_window == false).
     * @param bin_shift    explicit bin width = 2**bin_shift     (used only when auto_window == false).
     */
    IqrRunner(OasisContext &ctx, bool is_signed, bool auto_window, int64_t bin_min = 0,
              uint64_t bin_shift = 0, bool use_card = false);

    /**
     * Streams `inputs` through both passes and returns the packed outlier bitmask. The chunks are
     * concatenated logically in order; `last` is asserted only on the final chunk of pass 2's input.
     * Throws std::runtime_error on allocation / timeout failures.
     */
    Result run(const std::vector<InputChunk> &inputs);

    /**
     * ---- Overlapped (incremental) driving of pass 1 -------------------------------------------
     *
     * run() cannot start until the whole column exists, so on the streaming decode path the two
     * PCIe passes are strictly serialised after decode (measured: sf10 heavy = 92.8 decode + 77.8
     * iqr, exactly additive -- RESULTS.md 9.14). Pass 1 is a pure streaming reduction, so it can
     * instead consume each row group as it is decoded, hiding it under decode:
     *
     *     heavy = max(decode, pass1) + pass2   instead of   decode + pass1 + pass2
     *
     * Pass 2 genuinely cannot move: it needs the final Q1/Q3, which exist only once every element
     * has been histogrammed.
     *
     * Call sequence (all on one thread, chunks in column order):
     *     begin_overlapped(prefix)          // window from `prefix`, clear histogram
     *     feed_pass1(chunk, is_last) x N    // is_last only on the column's final chunk
     *     finish_overlapped(all_chunks)     // pass 2 + drain -> Result
     *
     * THE CALLER MUST SUPPLY THE WINDOW. The bins have to be fixed before the first pass-1 beat, so
     * the runner cannot derive them the way run() does -- it has not seen the data yet. Deriving
     * them from a PREFIX of the column was tried and is CATASTROPHIC on order-dependent data: it
     * flagged 19,997,999 of 20,000,000 rows where the correct answer was 200 (RESULTS.md 9.15). The
     * window must come from a sample that SPANS the column; see DeriveWindowSpanning() in the
     * extension. Passing it here rather than through the constructor keeps run() on its own
     * derive-from-data path, so a caller whose overlap does not engage is unaffected.
     *
     * Not supported with use_card (staging needs the whole column up front); the caller must fall
     * back to run().
     */
    /**
     * ---- Fused pass 1 (RTL) -------------------------------------------------------------------
     * Unlike begin_overlapped(), which still DMAs pass 1 from the host, this arms the hardware to
     * feed the histogram directly from the decoder output. The host then simply decodes; pass 1
     * happens as a side effect and costs no PCIe traffic and no host time at all.
     *
     *     begin_fused(bin_min, bin_shift, N)   // before decoding
     *     ... caller decodes the column ...     // pass 1 runs on-chip
     *     finish_fused(chunks)                  // pass 2 + drain
     *
     * `N` must be the exact element count: the on-chip feed regenerates the single terminating
     * `last` from it (each decoder lane asserts `last` per row group and cannot know where the
     * column ends). finish_fused() verifies histogram_total == N and throws if not, because a
     * miscount produces plausible-looking but wrong quartiles rather than an obvious failure.
     *
     * Works with either sink: the tee is in hardware, so it does not care whether the host
     * gathered the column or kept per-row-group chunks.
     */
    void   begin_fused(int64_t bin_min, uint64_t bin_shift, size_t expected_elements);
    Result finish_fused(const std::vector<InputChunk> &inputs);

    /**
     * ---- Step 2: bin-index pass 2 -------------------------------------------------------------
     * Pass 2 does nothing per element but compare it against two constants, yet it re-reads the
     * whole 64-bit column: 8 bytes moved per 1 bit produced. With this on, HISTOGRAM additionally
     * emits a packed 32-bit-per-element index stream (16-bit signed half-bin index + an `exact`
     * bit; re-widened from 16-bit/14-bit for 4096 bins), the host catches it, and pass 2 re-reads
     * THAT -- 2x fewer bytes (was 4x at 16-bit packing).
     *
     * The results are bit-identical, not approximate: Q1/Q3 are bin lower edges, so 1.5*IQR is an
     * exact multiple of half a bin and both fences land on half-bin boundaries. Proven in
     * tb_iqr_index (204884 value/window combinations) and tb_iqr_idx_mode (the same column through
     * the core in both modes). The `exact` bit exists because floor division collapses every value
     * in (upper_fence, upper_fence + W/2) onto the fence's own index; without it those outliers are
     * silently missed.
     *
     * Must be set BEFORE begin_fused(): the index receive buffer has to be armed before the first
     * pass-1 beat, or the beats the device emits during HISTOGRAM have nowhere to land.
     * Needs a bitstream with the idx_mode CSR (register 7) -- on an older one the register is
     * ignored, pass 2 would re-read indices as if they were values, and the histogram_total check
     * would not catch it. Off by default.
     */
    void enable_index_pass2(bool on) {
        // Index mode's wire format is a 32-bit word: a 16-bit signed half-bin index (IDX_W=16) plus
        // an `exact` bit, the rest reserved. TRAP 2 (iqr_index.sv) bounds the reachable fence indices
        // at ~5*(NUM_BINS-1): +5115/-3069 at 1024 bins, ~+20475/-12285 at 4096 bins. IDX_W=16
        // (+-32768) covers 4096 with margin, so saturation stays safe. The re-widen (IDX_W 14->16,
        // IDX_BITS 16->32, host IDX_PER_BEAT 32->16, the o_flagw_data /16->/32 sites) landed for
        // build-24. Beyond 4096 bins the fence indices would exceed +-32768 again -- refuse rather than
        // ship silently-wrong flags.
        if (on && NUM_BINS > 4096) {
            throw std::runtime_error(
                "IqrRunner: index-mode pass 2 is only bit-exact for NUM_BINS<=4096 (IDX_W=16); this "
                "bitstream is built for " + std::to_string(NUM_BINS) + " bins. Re-widen IDX_W/IDX_BITS "
                "before enabling index mode at >4096 bins.");
        }
        idx_mode_ = on;
    }

    void   begin_overlapped(int64_t bin_min, uint64_t bin_shift);
    void   feed_pass1(const InputChunk &chunk, bool is_last);
    Result finish_overlapped(const std::vector<InputChunk> &inputs);

  private:
    OasisContext              &ctx_;
    std::shared_ptr<IqrConfig> iqr_config_;

    bool     is_signed_;
    bool     auto_window_;
    int64_t  bin_min_;
    uint64_t bin_shift_;
    bool     use_card_;   // read the two passes from card/HBM instead of re-DMAing from the host

    // Histogram bin count baked into the bitstream (must match the vFPGA top's IQR_NUM_BINS).
    static constexpr int64_t NUM_BINS      = 4096;
    static constexpr size_t  SAMPLE_TARGET = 8192;   // ~rows sampled to size the window
    // Card stream index the HBM-staged column is read on (matches axis_card_recv[0] in vfpga_top).
    static constexpr int64_t CARD_STREAM   = 0;

    // Counts total int64 elements across all chunks.
    static size_t count_elements(const std::vector<InputChunk> &inputs);

    // Sets bin_min_/bin_shift_ from a robust percentile range of a stride-sample of the data, so a
    // stray outlier cannot blow up the bin width. Port of celeris::IqrOperator::derive_window.
    void derive_window(const std::vector<InputChunk> &inputs);

    // Streams every chunk once, asserting `last` exactly on the final chunk. `strm_kind`/`dest`
    // select host vs card (STRM_HOST + iqrStream, or STRM_CARD + CARD_STREAM).
    void stream_pass(const std::vector<InputChunk> &inputs, uint32_t strm_kind, int64_t dest);

    // Card mode: copy the decoded chunks into one host buffer and migrate it to HBM (LOCAL_OFFLOAD),
    // leaving the caller's original host buffers intact (they still back the value-column output).
    // Returns the staged buffer (its ptr is the card-resident vaddr the passes read).
    std::shared_ptr<libstf::Buffer> stage_to_card(const std::vector<InputChunk> &inputs);

    // Zero the histogram banks and BLOCK until the clear sweep has completed. Must be fenced ahead
    // of the first pass-1 beat: the clear is a posted CSR write on the control plane while the input
    // travels the data plane, with no mutual ordering, so beats that overtake it get binned then
    // wiped. Shared by run() and begin_overlapped().
    void clear_histogram_fenced();

    // Drains the flag buffer(s) the FPGA wrote into one contiguous bitmask, then reads back the
    // count-loss and profiler diagnostics. Shared tail of run() and finish_overlapped(). Returns the
    // instant the drain completed, so the caller can close `passes_ms` on device time alone.
    std::chrono::steady_clock::time_point
    collect_result(Result &result, size_t out_bytes, BypassStreamReceiver::Handle &handle);

    // Bytes the packed index array occupies for `n` elements: 32 indices per 64-byte beat, padded
    // to a whole beat (the device masks the tail against hist_expected).
    static size_t index_bytes_for(size_t n);

    // Drains a bypass-receiver transfer into one contiguous buffer. Shared by the flag drain and
    // the step-2 index drain.
    std::shared_ptr<libstf::Buffer> drain_to_buffer(BypassStreamReceiver::Handle &handle,
                                                    size_t total_bytes);

    // Folds a byte-padded-per-chunk flag drain (produced when pass 2 streams ragged intermediate
    // chunks) back into a dense, contiguous 1-bit-per-element bitmask. No-op unless a chunk before
    // the last is not a multiple of 8 elements (has_intermediate_ragged). Verified offline against a
    // brute-force reference; see the .cpp.
    std::shared_ptr<libstf::Buffer> repack_ragged_flags(
        const std::shared_ptr<libstf::Buffer> &padded,
        const std::vector<InputChunk> &chunks, size_t num_elements);

    // Overlapped-mode state, live only between begin_overlapped() and finish_overlapped().
    bool overlapped_ = false;
    bool fused_      = false;

    // Step 2 state. idx_mode_ is sticky (set by the caller); idx_handle_/idx_bytes_ live only
    // between begin_fused() and finish_fused().
    bool                                     idx_mode_  = false;
    std::shared_ptr<BypassStreamReceiver::Handle> idx_handle_;
    size_t                                   idx_bytes_ = 0;
};

} // namespace oasis

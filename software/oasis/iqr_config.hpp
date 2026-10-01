#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>

namespace oasis {

// Config id the IQR_detection vFPGA region advertises (register 0 of its
// ConfigReadRegisterFile). This is the HARDWARE <-> SOFTWARE contract: the IQR region in the
// co-resident oasis bitstream must report this exact value, or GlobalConfig::get_config<IqrConfig>()
// will not bind. The bytes spell "IQRDETCT" (I,Q,R,D,E,T,C,T) so it is unique and self-documenting.
//
// (In standalone celeris the IQR block reused CELERIS_SYSTEM_ID as its config id because IQR was the
// whole design. In oasis IQR is one config block among several -- ParCore decoder, MemConfig,
// ReadReq -- so it gets its own id, like READ_REQ_CONFIG_ID does.)
constexpr uint64_t IQR_CONFIG_ID = 0x4951524445544354ull;

/**
 * Host-side control panel for the IQR_detection vFPGA operator (the histogram + quartile outlier
 * detector). A thin libstf::Config: every accessor is a single CSR register read/write.
 *
 * Register map (matches hardware/src/hdl/aggregation/IQR_detection.sv via its config block):
 *
 *   READ side (count-loss diagnostics + debug):
 *     reg 0 = config id (== IQR_CONFIG_ID, checked by GlobalConfig)
 *     reg 1 = accepted   (values that entered binning in pass-1; compare to N)
 *     reg 2 = committed  (sum of deltas the RMW intended to write into the histogram BRAM)
 *     reg 3 = flushes    (number of BRAM writes -- coalescing texture)
 *     reg 4 = collisions (flush-reads that hit a just-written bin -- direct hazard evidence)
 *     reg 5 = histogram grand total of the last run (debug: == N iff banks were zeroed)
 *     reg 6 = clear-completion counter (advances once per finished host clear sweep)
 *     reg  7..10 = input  StreamProfiler cycles: handshakes / starved / stalled / idle
 *     reg 11..14 = output StreamProfiler cycles: handshakes / starved / stalled / idle
 *
 *   The chain  N >= accepted >= committed >= total  localizes where pass-1 counts are lost:
 *   accepted<N -> input/DMA; committed<accepted -> coalescing; total<committed -> BRAM RMW hazard.
 *
 *   WRITE side (runtime window + control):
 *     reg 0 = bin_min   (raw 64-bit pattern; HW interprets signed when set_signed(true))
 *     reg 1 = bin_shift (bin width = 2**bin_shift)
 *     reg 2 = is_signed (1/0)
 *     reg 3 = clear pulse (re-arm the histogram clear sweep before a run)
 *
 * The FPGA computes Q1/Q3 and the 1.5*IQR fences itself between the two passes -- the host never
 * touches the histogram. Its only jobs are: write the window (bin_min/bin_shift/is_signed), pulse
 * the clear, and read back the diagnostic/debug counters.
 */
class IqrConfig : public libstf::Config {
  public:
    IqrConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
        : libstf::Config(cthread, addr_offset, num_regs) {}

    // -- read side: count-loss diagnostics (reset per run by clear_histogram(), like dbg_total) ---
    // accepted: values that entered binning in pass-1 (== N iff no input/DMA loss).
    uint64_t accepted()   { return read_register(1).value(); }
    // committed: Σ deltas the BRAM read-modify-write intended to store (== accepted iff coalescing
    // carried every run; > total when the read-after-write hazard drops counts in the BRAM).
    uint64_t committed()  { return read_register(2).value(); }
    // flushes: number of BRAM writes (how often the coalescer hit a bin change).
    uint64_t flushes()    { return read_register(3).value(); }
    // collisions: flush-reads that hit a just-written bin -- direct evidence of the BRAM hazard.
    uint64_t collisions() { return read_register(4).value(); }

    // Debug: histogram grand total of the last run (== element count iff the banks were properly
    // zeroed; > N reveals cross-run residue).
    uint64_t histogram_total()  { return read_register(5).value(); }

    // Clear-completion counter: advances once per completed host clear sweep. Used to fence the
    // posted clear write ahead of the input DMA (see IqrRunner::run).
    uint64_t clear_seq()        { return read_register(6).value(); }

    // -- read side: StreamProfiler cycle counters ------------------------------------------------
    // Free-running per-stream profilers on the IQR input and output. Counters accumulate across a
    // run's two passes and are re-zeroed by the next run's first input beat, so read them AFTER the
    // passes complete (IqrRunner::run does). Reading: handshakes = productive (valid && ready);
    // starved = ready && !valid (waiting on host/DMA -- the round-trip we target with HBM); stalled
    // = valid && !ready (back-pressured); idle = cycles between the two passes.
    struct StreamProfile { uint64_t handshakes, starved, stalled, idle; };
    StreamProfile input_profile() {
        return {read_register(7).value(),  read_register(8).value(),
                read_register(9).value(),  read_register(10).value()};
    }
    StreamProfile output_profile() {
        return {read_register(11).value(), read_register(12).value(),
                read_register(13).value(), read_register(14).value()};
    }

    // -- write side: runtime window parameters + control -----------------------------------------
    // bin_min is sent as its raw 64-bit pattern (the HW interprets it signed when set_signed(true)).
    void set_bin_min(int64_t bin_min)  { write_register(libstf::ConfigRegister(0, static_cast<uint64_t>(bin_min))); }
    void set_bin_shift(uint64_t shift) { write_register(libstf::ConfigRegister(1, shift)); }
    void set_signed(bool is_signed)    { write_register(libstf::ConfigRegister(2, is_signed ? 1u : 0u)); }

    // Re-arm the histogram clear sweep so the next run starts from a zeroed histogram.
    void clear_histogram()             { write_register(libstf::ConfigRegister(3, 1u)); }

    // DEPRECATED, retained so the register map does not shift. The card/HBM datapath was removed
    // from the RTL: it measured 8 MB/s with a size-independent ~1548x penalty on the READ path
    // (RESULTS.md 9.17), and with pass 1 fused on-chip there is only one pass left to source.
    void set_use_card(bool use_card)   { write_register(libstf::ConfigRegister(4, use_card ? 1u : 0u)); }

    // -- Fused pass 1 --------------------------------------------------------------------------
    // Feed the HISTOGRAM pass straight from the decoder output instead of re-streaming the column
    // from the host. `expected` is the total element count of the column: each decoder lane asserts
    // `last` once per ROW GROUP and no lane knows where the column ends, so the on-chip feed
    // regenerates the single terminating `last` from this count. A wrong value ends pass 1 early
    // and every quartile is silently wrong -- always verify histogram_total() == N afterwards.
    void set_fuse_enable(bool on)      { write_register(libstf::ConfigRegister(5, on ? 1u : 0u)); }
    void set_hist_expected(uint64_t n) { write_register(libstf::ConfigRegister(6, n)); }

    // Step 2: pass 2 re-reads packed 16-bit bin indices instead of the 64-bit value column, which is
    // 4x less PCIe traffic at bit-identical results (proven in tb_iqr_index / tb_iqr_idx_mode).
    // Requires set_hist_expected() -- the index array is padded to a whole 32-element beat and the
    // device masks the tail against the element count rather than reading an in-band length.
    void set_idx_mode(bool on)         { write_register(libstf::ConfigRegister(7, on ? 1u : 0u)); }

    // Feed diagnostics: elements pushed so far, and whether the terminating `last` was sent.
    // Distinguishes "pass 1 never finished" from "pass 1 finished with the wrong count".
    uint64_t fed_elements()            { return read_register(15).value(); }
    bool     feed_done()               { return read_register(16).value() != 0; }

    // Step 2: index beats the device has handed to the output writer this column. Polled before
    // draining the index transfer, because the bypass receiver's next() blocks on a completion
    // interrupt with NO timeout -- a short stream would hang the query with nothing to report.
    uint64_t index_beats()             { return read_register(17).value(); }

    static constexpr uint64_t ID = IQR_CONFIG_ID;
};

} // namespace oasis

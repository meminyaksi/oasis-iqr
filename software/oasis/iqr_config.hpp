#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

#include <cstdint>
#include <memory>

namespace oasis {

// Config id the IQR_detection vFPGA region advertises (register 0 of its config block). The bytes
// spell "IQRDETCT" and must equal IQR_CONFIG_ID in hardware/src/hdl/common.sv, or
// GlobalConfig::get_config<IqrConfig>() will not bind.
constexpr uint64_t IQR_CONFIG_ID = 0x4951524445544354ull;

/**
 * Host-side control panel for the IQR_detection vFPGA operator. Every accessor is a single CSR
 * register read or write. Only the registers the host driver uses are exposed here; the full
 * register map is documented in hardware/src/hdl/iqr_config.sv.
 *
 * The FPGA computes Q1/Q3 and the 1.5*IQR fences itself between the two passes. The host writes the
 * histogram window, pulses the clear, arms the fused feed, and reads back the completion counters.
 */
class IqrConfig : public libstf::Config {
  public:
    IqrConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs)
        : libstf::Config(cthread, addr_offset, num_regs) {}

    // -- read side -------------------------------------------------------------------------------
    // Histogram grand total of the last run (== element count iff no pass-1 count was lost).
    uint64_t histogram_total() { return read_register(5).value(); }

    // Clear-completion counter: advances once per completed clear sweep. Used to fence the posted
    // clear write ahead of the input DMA.
    uint64_t clear_seq()       { return read_register(6).value(); }

    // Fused-feed progress: elements pushed so far, and whether the terminating `last` was sent.
    uint64_t fed_elements()    { return read_register(15).value(); }
    bool     feed_done()       { return read_register(16).value() != 0; }

    // -- write side ------------------------------------------------------------------------------
    // bin_min is sent as its raw 64-bit pattern (the HW interprets it signed when set_signed(true)).
    void set_bin_min(int64_t bin_min)  { write_register(libstf::ConfigRegister(0, static_cast<uint64_t>(bin_min))); }
    void set_bin_shift(uint64_t shift) { write_register(libstf::ConfigRegister(1, shift)); }
    void set_signed(bool is_signed)    { write_register(libstf::ConfigRegister(2, is_signed ? 1u : 0u)); }

    // Re-arm the histogram clear sweep so the next run starts from a zeroed histogram.
    void clear_histogram()             { write_register(libstf::ConfigRegister(3, 1u)); }

    // Fused pass 1: feed the HISTOGRAM pass straight from the decoder output. `expected` is the
    // column's total element count: each decoder lane asserts `last` once per row group, so the
    // on-chip feed regenerates the single terminating `last` from this count.
    void set_fuse_enable(bool on)      { write_register(libstf::ConfigRegister(5, on ? 1u : 0u)); }
    void set_hist_expected(uint64_t n) { write_register(libstf::ConfigRegister(6, n)); }

    static constexpr uint64_t ID = IQR_CONFIG_ID;
};

} // namespace oasis

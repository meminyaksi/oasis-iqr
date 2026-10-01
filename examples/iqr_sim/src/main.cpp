// Drives the IQR_detection operator end-to-end through OasisContext + IqrRunner, against either a
// real FPGA or the Coyote software-in-the-loop simulation (EN_SIMULATION). The cThread is swapped
// transparently, so this is the exact production software path. Validates the co-resident IQR lane
// added to vfpga_top.svh (S2).

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>

#include <libstf/memory_pool.hpp>

#include "oasis/iqr_runner.hpp"
#include "oasis/oasis_context.hpp"

// ---- reference model: mirrors IQR_detection (256 bins; Q1/Q3 + 1.5*IQR fences, integer math) ----
static int value_to_bin(int64_t v, int nb, int bs, int64_t bmin) {
    int64_t s = (v - bmin) >> bs;
    if (s < 0) return 0;
    if (s >= nb) return nb - 1;
    return static_cast<int>(s);
}

static std::vector<int> model_flags(const std::vector<int64_t> &d, int nb, int bs, int64_t bmin) {
    std::vector<int64_t> hist(nb, 0);
    for (auto v : d) hist[value_to_bin(v, nb, bs, bmin)]++;
    int64_t total = static_cast<int64_t>(d.size());
    auto    binval = [&](int b) { return bmin + (static_cast<int64_t>(b) << bs); };
    int64_t q1 = binval(nb - 1), q3 = binval(nb - 1), cum = 0;
    bool    q1f = false, q3f = false;
    for (int b = 0; b < nb; b++) {
        cum += hist[b];
        if (!q1f && cum * 4 >= total) { q1 = binval(b); q1f = true; }
        if (!q3f && cum * 4 >= 3 * total) { q3 = binval(b); q3f = true; }
    }
    int64_t iqr = q3 - q1, lo = q1 - iqr - (iqr >> 1), hi = q3 + iqr + (iqr >> 1);
    std::vector<int> f;
    for (auto v : d) f.push_back((v < lo || v > hi) ? 1 : 0);
    return f;
}

int main(int argc, char **argv) {
    using namespace oasis;

    // 1. Context. In sim use a SimpleMemoryPool (host/card memory is simulated); on hardware the
    //    huge-page pool. OasisContext::init builds the (sim or real) cThread transparently.
#ifdef EN_SIMULATION
    auto pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
    auto pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif
    OasisContext::init(pool);
    auto &ctx = OasisContext::ctx();

    std::cout << "IQR present: " << (ctx.isIQRPresent() ? "yes" : "no")
              << ", IQR stream = " << ctx.iqrStream() << std::endl;
    if (!ctx.isIQRPresent()) {
        std::cerr << "Bitstream has no IQR config block -- did the design build with the IQR lane?\n";
        return 2;
    }

    // 2. SCALING dataset, configurable via argv so sizes can be swept WITHOUT rebuilding:
    //      ./iqr_sim [N] [MOD]    (defaults N=8192, MOD=10)
    //    data[i] = i % MOD -> no adjacent same-bin per lane (no coalescing) -> every value is its
    //    own flush. bin == value (bin_shift=0), so MOD must keep values in-window (small). With the
    //    LUTRAM fix the histogram is exact: expect total == N for every size.
    size_t N   = (argc > 1) ? std::strtoul(argv[1], nullptr, 10) : 8192;
    int    MOD = (argc > 2) ? std::atoi(argv[2]) : 10;
    if (N == 0) N = 8192;
    if (MOD <= 0) MOD = 10;
    std::vector<int64_t> data;
    data.reserve(N);
    for (size_t i = 0; i < N; ++i) data.push_back((int64_t)(i % (size_t)MOD));
    const size_t         n    = data.size();
    std::cout << "dataset: N=" << N << " values, value range 0.." << (MOD - 1)
              << " (expect total=" << N << ")" << std::endl;

    // 3. DMA-mapped input buffer holding the column.
    void *in  = nullptr;
    auto  st = ctx.memory_pool()->allocate(n * sizeof(int64_t), &in);
    if (!st.ok()) {
        std::cerr << "input allocation failed: " << st.message() << std::endl;
        return 1;
    }
    ctx.tlb_manager()->ensure_tlb_mapping(in, n * sizeof(int64_t));
    std::memcpy(in, data.data(), n * sizeof(int64_t));

    // 4. Run IQR: explicit window (bin_min=0, bin_shift=0), unsigned -- matches the model below.
    // OASIS_IQR_USE_CARD=1 exercises the HBM path: stage the column in card memory and read both
    // passes with STRM_CARD (needs an EN_MEM sim/bitstream). Default off = legacy host path.
    const char *card_env = std::getenv("OASIS_IQR_USE_CARD");
    const bool  use_card = card_env && (card_env[0] == '1' || card_env[0] == 't' || card_env[0] == 'T');
    std::cout << "input source: " << (use_card ? "card/HBM (STRM_CARD)" : "host (STRM_HOST)") << "\n";

    IqrRunner runner(ctx, /*is_signed=*/false, /*auto_window=*/false, /*bin_min=*/0, /*bin_shift=*/0,
                     use_card);
    auto      res = runner.run({{in, n * sizeof(int64_t)}});

    // Count-loss diagnostics: the chain N >= accepted >= committed >= total pinpoints any loss
    // stage on silicon (input/DMA, coalescing, or the BRAM read-after-write hazard). On a clean
    // run all four equal N and collisions == 0.
    std::cout << "histogram_total = " << res.histogram_total << "  (expect " << n << ")\n"
              << "diagnostics: accepted=" << res.accepted << " committed=" << res.committed
              << " total=" << res.histogram_total << " (expect " << n << ")"
              << "  flushes=" << res.flushes << " collisions=" << res.collisions << "\n";
    if (res.accepted   < n)             std::cout << "  -> LOSS at input/DMA (accepted < N)\n";
    if (res.committed  < res.accepted)  std::cout << "  -> LOSS in coalescing (committed < accepted)\n";
    if (res.histogram_total < res.committed)
        std::cout << "  -> LOSS in BRAM read-modify-write hazard (total < committed), collisions="
                  << res.collisions << "\n";

    // Wall-clock split: this is what settles host-vs-card. `staging` is the Coyote migration DMA
    // (host->HBM, card mode only); `passes` is the FPGA reading the column twice + emitting flags.
    // The passes bandwidth is the ACHIEVED input bandwidth of the source (host DMA vs HBM) -- the
    // number the whole HBM design hinges on. Host is expected around 12.8 GB/s (PCIe Gen3 x16).
    const double pass_bytes = 2.0 * n * sizeof(int64_t); // both passes re-read the column
    std::cout << "timing: staging=" << res.stage_ms << " ms  passes=" << res.passes_ms << " ms\n"
              << "input bandwidth (passes): "
              << (res.passes_ms > 0 ? pass_bytes / (res.passes_ms * 1e6) : 0.0) << " GB/s"
              << "  [" << (use_card ? "HBM" : "host DMA") << ", " << pass_bytes / (1 << 20)
              << " MiB over 2 passes]\n";

    // StreamProfiler cycle breakdown. input aggregates both passes; output is the flag emit.
    // WARNING: these device counters are NEVER cleared between processes -- they accumulate for the
    // life of the bitstream, so the absolute values (and percentages) are meaningless. Only the
    // DIFFERENCE between two consecutive runs means anything. Trust the wall-clock split above.
    auto pct = [](uint64_t part, uint64_t whole) { return whole ? (100.0 * part / whole) : 0.0; };
    const auto &pi = res.input_profile, &po = res.output_profile;
    uint64_t in_tot  = pi.handshakes + pi.starved + pi.stalled + pi.idle;
    uint64_t out_tot = po.handshakes + po.starved + po.stalled + po.idle;
    std::cout << "stream profile [input ]: handshakes=" << pi.handshakes
              << " starved="  << pi.starved  << " (" << pct(pi.starved, in_tot)  << "%)"
              << " stalled="  << pi.stalled  << " (" << pct(pi.stalled, in_tot)  << "%)"
              << " idle="     << pi.idle     << "\n"
              << "stream profile [output]: handshakes=" << po.handshakes
              << " starved="  << po.starved  << " (" << pct(po.starved, out_tot) << "%)"
              << " stalled="  << po.stalled  << " (" << pct(po.stalled, out_tot) << "%)"
              << " idle="     << po.idle     << "\n";
    std::cout << std::flush;

    // 5. Unpack the packed flag bitmask: element i -> byte i/8, bit i%8 (LSB-first).
    const uint8_t   *mask = static_cast<const uint8_t *>(res.flags->ptr);
    std::vector<int> dev(n);
    for (size_t i = 0; i < n; i++) {
        dev[i] = (mask[i >> 3] >> (i & 7)) & 1u;
    }

    // 6. Compare against the reference model (1024 bins, the production NUM_BINS).
    auto exp      = model_flags(data, 1024, 0, 0);
    int  mismatch = 0;
    for (size_t i = 0; i < n; i++) {
        if (dev[i] != exp[i]) {
            mismatch++;
            std::cout << "  mismatch i=" << i << " v=" << data[i] << " device=" << dev[i]
                      << " model=" << exp[i] << std::endl;
        }
    }
    std::cout << "Mismatches: " << mismatch << std::endl;
    std::cout << (mismatch == 0 ? "PASSED: IQR runs end-to-end against the simulated FPGA"
                                : "FAILED: device flags do not match the model")
              << std::endl;
    return mismatch == 0 ? 0 : 1;
}

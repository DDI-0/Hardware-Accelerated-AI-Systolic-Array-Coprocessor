/**
 * Hardware-Accelerated Systolic Array Coprocessor Host Benchmark
 * Target: Intel Agilex 5 SoC (ARM Cortex-A55, Terasic DE25-Standard)
 * Interfaces: /dev/mem memory-mapped CSRs and MSGDMA engines
 *
 * Compilation on board:
 *   g++ -O3 -std=c++17 gemm_test.cpp -o gemm_test
 *
 * Usage:
 *   sudo ./gemm_test --diag            # First bring-up: CSRs only, no DMA mapping/writes
 *   sudo ./gemm_test --mem-test        # CPU read/write test of reserved DDR; no DMA
 *   sudo ./gemm_test --dma-input-test  # Transfer 16 words into input FIFO; no compute
 *   sudo ./gemm_test --tile-test       # One 16x16 tile with output DMA and CPU reference
 *   sudo ./gemm_test --accum-test      # 17x33 times 33x19: accumulation and padded edges
 *   sudo ./gemm_test --benchmark -M 64 -K 64 -N 64
 *   sudo ./gemm_test --benchmark -M 64 -K 64 -N 64 --poll-us 0
 *   sudo ./gemm_test --suite-list --suite all
 *   sudo ./gemm_test --suite all --output-prefix /mnt/gemm_results
 *   sudo ./gemm_test --swap-bytes      # Toggle byte packing order if bus swaps bytes
 *   sudo ./gemm_test -M 64 -K 64 -N 64 # Arbitrary tiled GEMM benchmark
 */

#include <iostream>
#include <iomanip>
#include <vector>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <algorithm>
#include <cassert>
#include <fstream>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "gemm_metrics.hpp"
#include "gemm_suite.hpp"

// Hardware Address Definitions (Agilex 5 Lightweight H2F Bridge)
#define LWH2F_BRIDGE_BASE       0x20000000ULL  // Agilex 5 LWH2F physical base
#define LWH2F_SPAN              0x00200000ULL  // 2MB span

// Offsets on the Lightweight Bridge (from Platform Designer)
#define SA_CSR_OFFSET           0x00020000ULL  // Systolic Array CSR (128 bytes)
#define MSGDMA1_CSR_OFFSET      0x00020080ULL  // Drain DMA CSR (32 bytes)
#define MSGDMA0_CSR_OFFSET      0x000200A0ULL  // Feeder DMA CSR (32 bytes)
#define MSGDMA1_DESC_OFFSET     0x000200C0ULL  // Drain DMA Descriptor (16 bytes)
#define MSGDMA0_DESC_OFFSET     0x000200D0ULL  // Feeder DMA Descriptor (16 bytes)

// Configure only after DDR has been reserved from Linux and the F2SDRAM
// address path has been verified. 0x38000000 is LWH2F space, not CPU DDR.
// The live DT and /proc/iomem reservation are checked before mapping this memory.
#define DMA_BUF_PHYS_BASE       0xB8000000ULL
#define DMA_BUF_SPAN            0x01000000ULL  // 16MB buffer span

// Contiguous buffer sub-allocations
#define DMA_IN_AB_OFFSET        0x00000000ULL  // Contiguous A (256B) + B (256B) = 512B
#define DMA_OUT_C_OFFSET        0x00010000ULL  // Output Matrix C tile (1024B)

// Systolic Array Register Offsets & Bitfields
#define SA_REG_CTRL             0x00  // (W)     [0]=START, [1]=SOFT_RST, [2]=FLUSH_OUT
#define SA_REG_STATUS           0x04  // (R/W1C) [0]=BUSY, [1]=DONE, [2]=IRQ, [3]=IN_RDY, [4]=OUT_EMPTY, [5]=OUT_FULL, [6]=ERR_OVF
#define SA_REG_CONFIG           0x08  // (RW)    [0]=SIGNED(RO), [1]=IRQ_EN, [2]=IRQ_EACH, [3]=CONT, [4]=ACCUM, [5]=LAST_TILE
#define SA_REG_PERF_CYCLES      0x0C  // (R)     Computation cycles
#define SA_REG_TXN_COUNT        0x10  // (R)     Completed transactions
#define SA_REG_ERR_COUNT        0x14  // (R)     Overflow error count
#define SA_REG_FIFO_STATUS      0x18  // (R)     [7:0]=in_lvl, [15:8]=out_lvl, [23:16]=in_depth, [31:24]=out_depth
#define SA_REG_VERSION          0x20  // (R)     [31:24]=major, [23:16]=minor, [15:0]=patch
#define SA_REG_CAPABILITY       0x24  // (R)     [7:0]=N, [15:8]=data_w, [23:16]=acc_w, [24]=signed
#define SA_REG_DIM_MK           0x28  // (RW)    [7:0]=ACT_M, [15:8]=ACT_K (CORRECTED)
#define SA_REG_DIM_N            0x2C  // (RW)    [7:0]=ACT_N

// Control bits
#define CTRL_START              (1 << 0)
#define CTRL_SOFT_RST           (1 << 1)
#define CTRL_FLUSH_OUT          (1 << 2)

// Status bits
#define STS_BUSY                (1 << 0)
#define STS_DONE                (1 << 1)
#define STS_IRQ_PENDING         (1 << 2)
#define STS_IN_FIFO_READY       (1 << 3)
#define STS_OUT_FIFO_EMPTY      (1 << 4)
#define STS_OUT_FIFO_FULL       (1 << 5)
#define STS_ERR_OVERFLOW        (1 << 6)

// Config bits
#define CFG_SIGNED_MODE         (1 << 0)
#define CFG_IRQ_EN              (1 << 1)
#define CFG_IRQ_ON_EACH         (1 << 2)
#define CFG_CONTINUOUS          (1 << 3)
#define CFG_ACCUMULATE          (1 << 4)
#define CFG_LAST_TILE           (1 << 5)

// Hardware dimensions
constexpr int SA_N = 16;
constexpr int SA_WORDS_PER_MAT = 64;   // 16 rows * (16 / 4) words = 64 words (256 bytes)
constexpr int SA_WORDS_PER_TXN = 128;  // A (64 words) + B (64 words) = 128 words (512 bytes)
constexpr int SA_WORDS_PER_OUT = 256;  // 16 rows * 16 cols = 256 words (1024 bytes)

// Driver Class: Hardware Control, DMA Arming, & Tiling Engine
class SystolicArrayDriver {
private:
    int mem_fd = -1;
    void* bridge_base = MAP_FAILED;
    void* dma_buf_virt = MAP_FAILED;

    volatile uint32_t* sa_csr = nullptr;
    volatile uint32_t* dma0_csr = nullptr;
    volatile uint32_t* dma0_desc = nullptr;
    volatile uint32_t* dma1_csr = nullptr;
    volatile uint32_t* dma1_desc = nullptr;

    uint32_t* dma_in_ab = nullptr;  // Contiguous 128-word buffer for A + B
    int32_t*  dma_out_c = nullptr;  // 256-word buffer for Matrix C tile

    bool swap_bytes = false;

public:
    static void memory_barrier() {
#if defined(__aarch64__)
        asm volatile("dsb sy" ::: "memory");
#else
        __sync_synchronize();
#endif
    }

    static bool reserved_dma_memory(uint64_t base) {
        const char* node = "/sys/firmware/devicetree/base/reserved-memory/sa_dma@b8000000/";
        std::ifstream reg(std::string(node) + "reg", std::ios::binary);
        std::ifstream no_map(std::string(node) + "no-map", std::ios::binary);
        unsigned char bytes[16] = {};
        reg.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
        if (reg.gcount() != sizeof(bytes) || !no_map) return false;
        uint64_t address = 0, span = 0;
        for (int i = 0; i < 8; ++i) {
            address = (address << 8) | bytes[i];
            span = (span << 8) | bytes[i + 8];
        }
        if (address != base || span != DMA_BUF_SPAN) return false;
        std::ifstream iomem("/proc/iomem");
        std::string line;
        while (std::getline(iomem, line)) {
            unsigned long long first = 0, last = 0;
            char label[64] = {};
            if (std::sscanf(line.c_str(), "%llx-%llx : %63s", &first, &last, label) == 3
                && std::strcmp(label, "reserved") == 0
                && first == base && last == base + DMA_BUF_SPAN - 1) return true;
        }
        return false;
    }

    explicit SystolicArrayDriver(bool swap_bytes_flag = false)
        : swap_bytes(swap_bytes_flag) {}

    ~SystolicArrayDriver() {
        close_hw();
    }

    bool init(bool diagnostics_only, uint64_t bridge_phys = LWH2F_BRIDGE_BASE,
              uint64_t dma_buf_phys = DMA_BUF_PHYS_BASE) {
        if (!diagnostics_only && !reserved_dma_memory(dma_buf_phys)) {
            std::cerr << "[ERROR] Reserved no-map DDR at 0xB8000000 (16 MiB) is missing.\n"
                      << "Repeat the manual U-Boot reservation procedure before --mem-test.\n";
            return false;
        }
        mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
        if (mem_fd < 0) {
            std::cerr << "[ERROR] Cannot open /dev/mem. Are you running with sudo?" << std::endl;
            return false;
        }

        // Map Lightweight H2F Bridge for CSRs
        bridge_base = mmap(nullptr, LWH2F_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, bridge_phys);
        if (bridge_base == MAP_FAILED) {
            std::cerr << "[ERROR] mmap failed for LWH2F bridge at 0x" << std::hex << bridge_phys << std::dec << std::endl;
            close(mem_fd);
            mem_fd = -1;
            return false;
        }

        uint8_t* base_ptr = static_cast<uint8_t*>(bridge_base);
        sa_csr    = reinterpret_cast<volatile uint32_t*>(base_ptr + SA_CSR_OFFSET);
        dma0_csr  = reinterpret_cast<volatile uint32_t*>(base_ptr + MSGDMA0_CSR_OFFSET);
        dma0_desc = reinterpret_cast<volatile uint32_t*>(base_ptr + MSGDMA0_DESC_OFFSET);
        dma1_csr  = reinterpret_cast<volatile uint32_t*>(base_ptr + MSGDMA1_CSR_OFFSET);
        dma1_desc = reinterpret_cast<volatile uint32_t*>(base_ptr + MSGDMA1_DESC_OFFSET);

        // Diagnostic mode never maps, reads, writes, or arms DMA memory.
        if (diagnostics_only) return true;

        // Map the separately reserved DDR4 buffer for DMA streaming.
        dma_buf_virt = mmap(nullptr, DMA_BUF_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, dma_buf_phys);
        if (dma_buf_virt == MAP_FAILED) {
            std::cerr << "[ERROR] mmap failed for DMA buffer at 0x" << std::hex << dma_buf_phys << std::dec << std::endl;
            close_hw();
            return false;
        }

        uint8_t* buf_ptr = static_cast<uint8_t*>(dma_buf_virt);
        dma_in_ab = reinterpret_cast<uint32_t*>(buf_ptr + DMA_IN_AB_OFFSET);
        dma_out_c = reinterpret_cast<int32_t*>(buf_ptr + DMA_OUT_C_OFFSET);

        return true;
    }

    bool test_reserved_memory() {
        std::cout << "[MEM] Testing CPU access to reserved DDR; no DMA descriptors issued."
                  << std::endl;
        const uint64_t offsets[] = {DMA_IN_AB_OFFSET, DMA_OUT_C_OFFSET};
        for (uint64_t offset : offsets) {
            std::cout << "[MEM] Writing/reading 1024 bytes at physical 0x" << std::hex
                      << (DMA_BUF_PHYS_BASE + offset) << std::dec << std::endl;
            auto* words = reinterpret_cast<volatile uint32_t*>(
                static_cast<uint8_t*>(dma_buf_virt) + offset);
            for (uint32_t i = 0; i < 256; ++i) words[i] = 0xA5C30000U ^ i;
            memory_barrier();
            for (uint32_t i = 0; i < 256; ++i) {
                if (words[i] != (0xA5C30000U ^ i)) {
                    std::cerr << "[MEM] Readback mismatch at word " << i << std::endl;
                    return false;
                }
            }
        }
        std::cout << "[MEM] PASS: both reserved DDR buffers passed CPU readback.\n"
                  << "[MEM] FPGA/F2SDRAM DMA access has not been tested." << std::endl;
        return true;
    }

    bool test_input_dma() {
        constexpr uint32_t words_to_send = 16; // Below 128-word loader threshold.
        constexpr uint32_t dma_busy = 1U;
        constexpr uint32_t descriptor_empty = 1U << 1;
        constexpr uint32_t stopped_or_reset = 0x1E0U; // CSR status bits 5..8.
        std::cout << "[DMA-IN] Reading MSGDMA0 status at physical 0x200200a0."
                  << std::endl;
        uint32_t dma_status = dma0_csr[0];
        std::cout << "[DMA-IN] Initial status=0x" << std::hex << dma_status
                  << std::dec << std::endl;
        if ((dma_status & (dma_busy | stopped_or_reset)) || !(dma_status & descriptor_empty)
            || (read_reg(SA_REG_STATUS) & STS_BUSY)) {
            std::cerr << "[DMA-IN] Hardware is not idle. Restart with a fresh FPGA reset/boot.\n";
            return false;
        }
        write_reg(SA_REG_CONFIG, 0);
        reset();
        if ((read_reg(SA_REG_FIFO_STATUS) & 0xFFFFU) != 0) {
            std::cerr << "[DMA-IN] FIFOs did not clear.\n";
            return false;
        }
        auto* input = reinterpret_cast<volatile uint32_t*>(dma_in_ab);
        for (uint32_t i = 0; i < words_to_send; ++i) input[i] = 0x12340000U | i;
        memory_barrier();
        std::cout << "[DMA-IN] Submitting 64-byte read from reserved DDR 0xb8000000."
                  << std::endl;
        dma0_desc[0] = static_cast<uint32_t>(DMA_BUF_PHYS_BASE + DMA_IN_AB_OFFSET);
        dma0_desc[1] = 0; // Unused for memory-to-stream DMA.
        dma0_desc[2] = words_to_send * sizeof(uint32_t);
        memory_barrier();
        dma0_desc[3] = 0x80000000U; // GO; packet/channel interfaces are disabled.
        memory_barrier();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        uint32_t fifo_status = 0;
        do {
            dma_status = dma0_csr[0];
            fifo_status = read_reg(SA_REG_FIFO_STATUS);
            if (dma_status & stopped_or_reset) break;
            if (!(dma_status & dma_busy) && (dma_status & descriptor_empty)
                && (fifo_status & 0xFFU) == words_to_send) {
                std::cout << "[DMA-IN] PASS: DMA idle, descriptor consumed, input FIFO=16 words.\n"
                          << "[DMA-IN] Transfer arrival verified; operand contents and output DMA remain untested."
                          << std::endl;
                reset(); // Discard diagnostic operands before a later compute test.
                return true;
            }
            usleep(100);
        } while (std::chrono::steady_clock::now() < deadline);
        std::cerr << "[DMA-IN] FAIL: status=0x" << std::hex << dma_status
                  << " FIFO_STATUS=0x" << fifo_status << std::dec << std::endl;
        return false;
    }

    bool test_single_tile() {
        std::cout << "[TILE] Checking both DMA engines before one 16x16 signed tile."
                  << std::endl;
        const uint32_t in_status = dma0_csr[0];
        const uint32_t out_status = dma1_csr[0];
        std::cout << "[TILE] Input DMA status=0x" << std::hex << in_status
                  << " output DMA status=0x" << out_status << std::dec << std::endl;
        if (((in_status | out_status) & 0x1E1U) || !(in_status & 2U)
            || !(out_status & 2U) || (read_reg(SA_REG_STATUS) & STS_BUSY)) {
            std::cerr << "[TILE] Hardware is not idle; restart with a fresh FPGA reset/boot.\n";
            return false;
        }
        if (read_reg(SA_REG_CAPABILITY) != 0x01200810U) {
            std::cerr << "[TILE] Hardware capability does not match the signed 16x16 test.\n";
            return false;
        }
        write_reg(SA_REG_CONFIG, 0);
        reset();
        if ((read_reg(SA_REG_FIFO_STATUS) & 0xFFFFU) != 0) {
            std::cerr << "[TILE] FIFOs did not clear.\n";
            return false;
        }
        int8_t a[256], b[256];
        int32_t expected[256] = {};
        for (int i = 0; i < 256; ++i) {
            a[i] = static_cast<int8_t>((i % 7) - 3);
            b[i] = static_cast<int8_t>(((i * 3) % 11) - 5);
        }
        for (int r = 0; r < 16; ++r)
            for (int c = 0; c < 16; ++c)
                for (int k = 0; k < 16; ++k)
                    expected[r * 16 + c] += static_cast<int32_t>(a[r * 16 + k])
                                            * static_cast<int32_t>(b[k * 16 + c]);
        auto* input = reinterpret_cast<volatile uint32_t*>(dma_in_ab);
        auto* output = reinterpret_cast<volatile int32_t*>(dma_out_c);
        // MSGDMA reverses four 8-bit symbols between MM and Avalon-ST.
        // Put element zero in CPU word bits [31:24] so RTL receives it in [7:0].
        for (int w = 0; w < 64; ++w) {
            uint32_t aw = 0, bw = 0;
            for (int lane = 0; lane < 4; ++lane) {
                aw |= static_cast<uint32_t>(static_cast<uint8_t>(a[w * 4 + lane])) << ((3 - lane) * 8);
                bw |= static_cast<uint32_t>(static_cast<uint8_t>(b[w * 4 + lane])) << ((3 - lane) * 8);
            }
            input[w] = aw;
            input[64 + w] = bw;
        }
        for (int i = 0; i < 256; ++i) output[i] = 0x5A5A5A5A;
        memory_barrier();
        set_dimensions(16, 16, 16);
        write_reg(SA_REG_CONFIG, CFG_IRQ_EN | CFG_IRQ_ON_EACH | CFG_LAST_TILE);
        std::cout << "[TILE] Arming output DMA: 1024 bytes to DDR 0xb8010000."
                  << std::endl;
        dma1_desc[0] = 0;
        dma1_desc[1] = static_cast<uint32_t>(DMA_BUF_PHYS_BASE + DMA_OUT_C_OFFSET);
        dma1_desc[2] = 1024;
        memory_barrier();
        dma1_desc[3] = 0x80000000U;
        memory_barrier();
        std::cout << "[TILE] Arming input DMA: 512 bytes from DDR 0xb8000000."
                  << std::endl;
        dma0_desc[0] = static_cast<uint32_t>(DMA_BUF_PHYS_BASE + DMA_IN_AB_OFFSET);
        dma0_desc[1] = 0;
        dma0_desc[2] = 512;
        memory_barrier();
        dma0_desc[3] = 0x80000000U;
        memory_barrier();
        std::cout << "[TILE] Starting compute; CPU packs element zero in [31:24], DMA delivers [7:0]."
                  << std::endl;
        write_reg(SA_REG_CTRL, CTRL_START);
        memory_barrier();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        uint32_t sa_status = 0, in_dma = 0, out_dma = 0;
        bool completed = false;
        do {
            sa_status = read_reg(SA_REG_STATUS);
            in_dma = dma0_csr[0];
            out_dma = dma1_csr[0];
            if ((in_dma | out_dma) & 0x1E0U) break;
            // Capture completion alone is insufficient: wait for both DMA engines.
            if ((sa_status & STS_IRQ_PENDING) && !(in_dma & 1U) && !(out_dma & 1U)
                && (in_dma & 2U) && (out_dma & 2U)) {
                completed = true;
                break;
            }
            usleep(100);
        } while (std::chrono::steady_clock::now() < deadline);
        std::cout << "[TILE] Final SA status=0x" << std::hex << sa_status
                  << " input DMA=0x" << in_dma << " output DMA=0x" << out_dma
                  << " FIFO_STATUS=0x" << read_reg(SA_REG_FIFO_STATUS)
                  << std::dec << std::endl;
        if (!completed) {
            std::cerr << "[TILE] FAIL: completion timeout or stopped DMA.\n";
            return false;
        }
        memory_barrier();
        int mismatches = 0;
        for (int i = 0; i < 256; ++i) {
            // Output MSGDMA also reverses symbols; decode before signed comparison.
            const uint32_t raw = static_cast<uint32_t>(output[i]);
            const uint32_t decoded = ((raw & 0x000000FFU) << 24)
                                   | ((raw & 0x0000FF00U) << 8)
                                   | ((raw & 0x00FF0000U) >> 8)
                                   | ((raw & 0xFF000000U) >> 24);
            int32_t actual;
            std::memcpy(&actual, &decoded, sizeof(actual));
            if (actual != expected[i]) {
                if (mismatches < 8)
                    std::cerr << "[TILE] Mismatch (" << i / 16 << "," << i % 16
                              << "): expected " << expected[i] << ", got " << actual << '\n';
                ++mismatches;
            }
        }
        write_reg(SA_REG_STATUS, STS_IRQ_PENDING);
        if (mismatches) {
            std::cerr << "[TILE] FAIL: " << mismatches << " mismatches.\n";
            return false;
        }
        std::cout << "[TILE] PASS: all 256 signed results match the CPU reference."
                  << std::endl;
        return true;
    }

    void close_hw() {
        if (dma_buf_virt != MAP_FAILED) {
            munmap(dma_buf_virt, DMA_BUF_SPAN);
            dma_buf_virt = MAP_FAILED;
        }
        if (bridge_base != MAP_FAILED) {
            munmap(bridge_base, LWH2F_SPAN);
            bridge_base = MAP_FAILED;
        }
        if (mem_fd >= 0) {
            close(mem_fd);
            mem_fd = -1;
        }
    }

    inline void write_reg(uint32_t offset, uint32_t val) {
        sa_csr[offset >> 2] = val;
    }

    inline uint32_t read_reg(uint32_t offset) {
        return sa_csr[offset >> 2];
    }

    void print_diagnostics() {
        std::cout << "[MMIO] VERSION at physical 0x" << std::hex
                  << (LWH2F_BRIDGE_BASE + SA_CSR_OFFSET + SA_REG_VERSION)
                  << std::dec << std::endl;
        uint32_t ver = read_reg(SA_REG_VERSION);
        std::cout << "[MMIO] VERSION returned 0x" << std::hex << ver
                  << std::dec << std::endl;
        uint32_t cap = read_reg(SA_REG_CAPABILITY);
        std::cout << "[MMIO] CAPABILITY returned 0x" << std::hex << cap
                  << std::dec << std::endl;
        uint32_t sts = read_reg(SA_REG_STATUS);
        uint32_t fifo = read_reg(SA_REG_FIFO_STATUS);

        uint32_t v_major = (ver >> 24) & 0xFF;
        uint32_t v_minor = (ver >> 16) & 0xFF;
        uint32_t v_patch = ver & 0xFFFF;

        std::cout << "========================================================\n";
        std::cout << "  Agilex 5 16x16 Systolic Array Coprocessor Status\n";
        std::cout << "========================================================\n";
        std::cout << "  Hardware Version : v" << v_major << "." << v_minor << "." << v_patch << "\n";
        std::cout << "  Array Dimensions : " << (cap & 0xFF) << "x" << (cap & 0xFF) << "\n";
        std::cout << "  Data Precision   : " << ((cap >> 8) & 0xFF) << "-bit input, "
                  << ((cap >> 16) & 0xFF) << "-bit accumulator\n";
        std::cout << "  Signed Support   : " << ((cap & (1 << 24)) ? "YES (INT8)" : "NO") << "\n";
        std::cout << "  Byte Packing     : " << (swap_bytes ? "LITTLE-ENDIAN (override)" : "BIG-ENDIAN (MSGDMA symbol order)") << "\n";
        std::cout << "  Status Register  : 0x" << std::hex << std::setw(8) << std::setfill('0') << sts << std::dec << "\n";
        std::cout << "    BUSY=" << (sts & STS_BUSY ? 1 : 0)
                  << " DONE=" << (sts & STS_DONE ? 1 : 0)
                  << " IRQ=" << (sts & STS_IRQ_PENDING ? 1 : 0)
                  << " IN_RDY=" << (sts & STS_IN_FIFO_READY ? 1 : 0)
                  << " OUT_EMPTY=" << (sts & STS_OUT_FIFO_EMPTY ? 1 : 0)
                  << " OUT_FULL=" << (sts & STS_OUT_FIFO_FULL ? 1 : 0)
                  << " ERR_OVF=" << (sts & STS_ERR_OVERFLOW ? 1 : 0) << "\n";
        std::cout << "  Input FIFO       : level=" << (fifo & 0xFF) << ", depth=" << ((fifo >> 16) & 0xFF) << "\n";
        std::cout << "  Output FIFO      : level=" << ((fifo >> 8) & 0xFF) << ", depth=" << ((fifo >> 24) & 0xFF) << "\n";
        std::cout << "  Txn Count Total  : " << read_reg(SA_REG_TXN_COUNT) << "\n";
        std::cout << "========================================================\n";
    }

    void reset() {
        write_reg(SA_REG_CTRL, CTRL_SOFT_RST | CTRL_FLUSH_OUT);
        usleep(100);
        // Clear sticky status bits (W1C)
        write_reg(SA_REG_STATUS, 0xFFFFFFFF);
    }

    // FIXED: [7:0] = ACT_M, [15:8] = ACT_K
    void set_dimensions(int M, int K, int N) {
        assert(M >= 1 && M <= 16);
        assert(K >= 1 && K <= 16);
        assert(N >= 1 && N <= 16);
        uint32_t dim_mk = (static_cast<uint32_t>(K) << 8) | (static_cast<uint32_t>(M) & 0xFF);
        write_reg(SA_REG_DIM_MK, dim_mk);
        write_reg(SA_REG_DIM_N, static_cast<uint32_t>(N));
    }

    // Arm MSGDMA0 (Feed: Memory-Mapped to Streaming)
    void arm_dma_input(uint32_t src_phys, uint32_t byte_len) {
        dma0_desc[0] = src_phys;    // Read address in DDR4
        dma0_desc[1] = 0;           // Write address (ignored for MM->ST)
        dma0_desc[2] = byte_len;    // Byte length (always 512 bytes for 128 words)
        memory_barrier();
        dma0_desc[3] = 0x80000000U; // GO; streaming packet support is disabled
        memory_barrier();
    }

    // Arm MSGDMA1 (Drain: Streaming to Memory-Mapped)
    void arm_dma_output(uint32_t dst_phys, uint32_t byte_len) {
        dma1_desc[0] = 0;           // Read address (ignored for ST->MM)
        dma1_desc[1] = dst_phys;    // Write address in DDR4
        dma1_desc[2] = byte_len;    // Byte length (always 1024 bytes for 256 words)
        memory_barrier();
        dma1_desc[3] = 0x80000000U;
        memory_barrier();
    }

    // Polls STS_IRQ_PENDING (bit 2) for both intermediate & final tiles
    bool wait_completion(bool final_tile, int poll_us, int timeout_ms = 2000) {
        const auto deadline = std::chrono::steady_clock::now()
                            + std::chrono::milliseconds(timeout_ms);
        do {
            const uint32_t sts = read_reg(SA_REG_STATUS);
            const uint32_t in_dma = dma0_csr[0];
            const uint32_t out_dma = dma1_csr[0];
            if ((sts & STS_ERR_OVERFLOW) || ((in_dma | out_dma) & 0x1E0U)) {
                std::cerr << "[ERROR] SA/DMA error: SA=0x" << std::hex << sts
                          << " input=0x" << in_dma << " output=0x" << out_dma
                          << std::dec << std::endl;
                return false;
            }
            const bool input_done = !(in_dma & 1U) && (in_dma & 2U);
            const bool output_done = !(out_dma & 1U) && (out_dma & 2U);
            if ((sts & STS_IRQ_PENDING) && !(sts & STS_BUSY) && input_done
                && output_done) {
                // Intermediate tiles must produce no output; final DMA must drain it.
                if ((read_reg(SA_REG_FIFO_STATUS) & 0xFFFFU) != 0) {
                    std::cerr << "[ERROR] Unexpected FIFO data after "
                              << (final_tile ? "final" : "intermediate") << " tile.\n";
                    return false;
                }
                memory_barrier();
                // Clear sticky IRQ bit (W1C)
                write_reg(SA_REG_STATUS, STS_IRQ_PENDING);
                return true;
            }
            if (poll_us) usleep(poll_us);
        } while (std::chrono::steady_clock::now() < deadline);
        std::cerr << "[ERROR] Completion timeout: SA=0x" << std::hex
                  << read_reg(SA_REG_STATUS) << " input=0x" << dma0_csr[0]
                  << " output=0x" << dma1_csr[0] << std::dec << std::endl;
        return false;
    }

    // Pack 4 INT8 values into a 32-bit word matching hardware convention
    inline uint32_t pack_4(int8_t b0, int8_t b1, int8_t b2, int8_t b3) const {
        uint32_t v0 = static_cast<uint8_t>(b0);
        uint32_t v1 = static_cast<uint8_t>(b1);
        uint32_t v2 = static_cast<uint8_t>(b2);
        uint32_t v3 = static_cast<uint8_t>(b3);

        if (swap_bytes) {
            // Little-endian native ARM layout
            return v0 | (v1 << 8) | (v2 << 16) | (v3 << 24);
        } else {
            // MSGDMA converts MM little-endian words to ST network symbol order.
            return (v0 << 24) | (v1 << 16) | (v2 << 8) | v3;
        }
    }

    // Tiling Engine: Computes arbitrary M x K x N on fixed 16x16 hardware
    bool run_tiled_gemm(int M, int K, int N, const int8_t* A, const int8_t* B, int32_t* C,
                        uint64_t& total_cycles, GemmTimings& timings, int poll_us, bool verbose) {
        total_cycles = 0;
        timings = {};
        using Clock = std::chrono::steady_clock;
        const auto elapsed_us = [](Clock::time_point start) {
            return std::chrono::duration<double, std::micro>(Clock::now() - start).count();
        };
        if (M < 1 || K < 1 || N < 1 || M > 1024 || K > 1024 || N > 1024 || swap_bytes) {
            std::cerr << "[ERROR] Tiled test requires dimensions 1..1024 and default MSGDMA packing.\n";
            return false;
        }
        if (read_reg(SA_REG_CAPABILITY) != 0x01200810U
            || (read_reg(SA_REG_STATUS) & STS_BUSY)
            || ((dma0_csr[0] | dma1_csr[0]) & 0x1E1U)
            || !(dma0_csr[0] & 2U) || !(dma1_csr[0] & 2U)) {
            std::cerr << "[ERROR] Expected idle SA and DMA engines with supported capability.\n";
            return false;
        }
        auto* input = reinterpret_cast<volatile uint32_t*>(dma_in_ab);
        auto* output = reinterpret_cast<volatile uint32_t*>(dma_out_c);
        int num_tiles_m = (M + SA_N - 1) / SA_N;
        int num_tiles_k = (K + SA_N - 1) / SA_N;
        int num_tiles_n = (N + SA_N - 1) / SA_N;

        for (int tm = 0; tm < num_tiles_m; ++tm) {
            for (int tn = 0; tn < num_tiles_n; ++tn) {
                auto stage_start = Clock::now();
                write_reg(SA_REG_CONFIG, 0);
                reset();
                if ((read_reg(SA_REG_FIFO_STATUS) & 0xFFFFU) != 0) return false;
                for (int i = 0; i < 256; ++i) output[i] = 0x5A5A5A5AU;
                timings.reset_us += elapsed_us(stage_start);
                ++timings.output_tiles;

                // Accumulate across the K dimension
                for (int tk = 0; tk < num_tiles_k; ++tk) {
                    stage_start = Clock::now();
                    int cur_m = std::min(SA_N, M - tm * SA_N);
                    int cur_k = std::min(SA_N, K - tk * SA_N);
                    int cur_n = std::min(SA_N, N - tn * SA_N);

                    bool is_last_k  = (tk == num_tiles_k - 1);

                    // 1. Pack Matrix A and B into ONE contiguous 128-word buffer
                    //    A: words 0..63 (256 bytes)
                    //    B: words 64..127 (256 bytes)
                    //    Unused entries are zero-padded so FSM receives 128 words

                    // Pack A into first 64 words
                    for (int r = 0; r < SA_N; ++r) {
                        for (int w = 0; w < SA_N / 4; ++w) {
                            int8_t v[4] = {0, 0, 0, 0};
                            for (int b = 0; b < 4; ++b) {
                                int c = w * 4 + b;
                                if (r < cur_m && c < cur_k) {
                                    v[b] = A[(tm * SA_N + r) * K + (tk * SA_N + c)];
                                }
                            }
                            input[r * (SA_N / 4) + w] = pack_4(v[0], v[1], v[2], v[3]);
                        }
                    }

                    // Pack B into next 64 words (offset 64)
                    for (int r = 0; r < SA_N; ++r) {
                        for (int w = 0; w < SA_N / 4; ++w) {
                            int8_t v[4] = {0, 0, 0, 0};
                            for (int b = 0; b < 4; ++b) {
                                int c = w * 4 + b;
                                if (r < cur_k && c < cur_n) {
                                    v[b] = B[(tk * SA_N + r) * N + (tn * SA_N + c)];
                                }
                            }
                            input[SA_WORDS_PER_MAT + r * (SA_N / 4) + w] = pack_4(v[0], v[1], v[2], v[3]);
                        }
                    }

                    // 2. Program hardware runtime dimensions
                    timings.pack_us += elapsed_us(stage_start);
                    stage_start = Clock::now();
                    // Always compute a padded full tile: rectangular feed timing in
                    // current RTL can truncate B columns when ACT_N > ACT_M.
                    set_dimensions(SA_N, SA_N, SA_N);
                    uint32_t cfg = CFG_IRQ_EN | CFG_IRQ_ON_EACH | CFG_ACCUMULATE;
                    if (is_last_k) cfg |= CFG_LAST_TILE;
                    write_reg(SA_REG_STATUS, STS_IRQ_PENDING);
                    write_reg(SA_REG_CONFIG, cfg);
                    memory_barrier();

                    // 3. Arm Single 512-Byte Input DMA (128 words: 64 A + 64 B)
                    uint32_t dma_in_phys  = DMA_BUF_PHYS_BASE + DMA_IN_AB_OFFSET;
                    uint32_t dma_out_phys = DMA_BUF_PHYS_BASE + DMA_OUT_C_OFFSET;

                    // Arm the full output drain before submitting final operands.
                    if (is_last_k) {
                        uint32_t c_bytes = SA_N * SA_N * sizeof(int32_t);
                        arm_dma_output(dma_out_phys, c_bytes);
                    }
                    arm_dma_input(dma_in_phys, SA_WORDS_PER_TXN * sizeof(uint32_t));

                    // 4. Trigger Coprocessor Execution
                    if (verbose) std::cout << "[TILE] Output tile (" << tm << "," << tn
                              << "), K step " << tk + 1 << "/" << num_tiles_k
                              << (is_last_k ? " (capture + DMA)" : " (retain sums)")
                              << std::endl;
                    write_reg(SA_REG_CTRL, CTRL_START);
                    memory_barrier();
                    timings.submit_us += elapsed_us(stage_start);
                    ++timings.steps;
                    stage_start = Clock::now();

                    // 5. Wait for tile execution to finish
                    if (!wait_completion(is_last_k, poll_us)) {
                        std::cerr << "[ERROR] Timeout waiting for tile (tm=" << tm
                                  << ", tn=" << tn << ", tk=" << tk << ")" << std::endl;
                        return false;
                    }
                    timings.wait_us += elapsed_us(stage_start);
                    stage_start = Clock::now();

                    total_cycles += read_reg(SA_REG_PERF_CYCLES);

                    // Decode full 16x16 DMA output, retaining only valid edge entries.
                    if (is_last_k) {
                        for (int r = 0; r < cur_m; ++r) {
                            for (int c = 0; c < cur_n; ++c) {
                                const uint32_t raw = output[r * SA_N + c];
                                const uint32_t decoded = ((raw & 0xFFU) << 24)
                                    | ((raw & 0xFF00U) << 8)
                                    | ((raw & 0xFF0000U) >> 8)
                                    | ((raw & 0xFF000000U) >> 24);
                                std::memcpy(&C[(tm * SA_N + r) * N + (tn * SA_N + c)],
                                            &decoded, sizeof(decoded));
                            }
                        }
                    }
                    timings.decode_us += elapsed_us(stage_start);
                }
            }
        }
        return true;
    }
};

// CPU Golden Reference Matrix Multiplication (C = A * B)
void gemm_cpu(int M, int K, int N, const int8_t* A, const int8_t* B, int32_t* C) {
    for (int i = 0; i < M; ++i) {
        for (int j = 0; j < N; ++j) {
            int32_t sum = 0;
            for (int k = 0; k < K; ++k) {
                sum += static_cast<int32_t>(A[i * K + k]) * static_cast<int32_t>(B[k * N + j]);
            }
            C[i * N + j] = sum;
        }
    }
}

// Main Benchmark Routine
int main(int argc, char* argv[]) {
    std::cout << "\n========================================================\n";
    std::cout << "  Agilex 5 Systolic Array Host Benchmark (ARM Cortex-A55)\n";
    std::cout << "========================================================\n";

    bool diag_only = false;
    bool mem_only = false;
    bool dma_input_only = false;
    bool tile_only = false;
    bool accum_only = false;
    bool benchmark = false;
    bool suite_mode = false, suite_list = false, suite_option = false;
    bool poll_explicit = false, dimensions_explicit = false;
    gemm_suite::Options suite_options;
    bool verbose = false;
    bool swap_bytes = false;
    int test_M = 64, test_K = 64, test_N = 64;
    int poll_us = 10;

    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--diag") diag_only = true;
        else if (std::string(argv[i]) == "--mem-test") mem_only = true;
        else if (std::string(argv[i]) == "--dma-input-test") dma_input_only = true;
        else if (std::string(argv[i]) == "--tile-test") tile_only = true;
        else if (std::string(argv[i]) == "--accum-test") accum_only = true;
        else if (std::string(argv[i]) == "--benchmark") benchmark = true;
        else if (std::string(argv[i]) == "--suite-list") suite_list = true;
        else if (std::string(argv[i]) == "--suite" || std::string(argv[i]) == "--output-prefix") {
            const std::string option = argv[i];
            if (++i == argc) { std::cerr << "Missing value for " << option << '\n'; return 1; }
            if (option == "--suite") {
                suite_mode = true;
                suite_options.selection = argv[i];
                if (!gemm_suite::valid_selection(suite_options.selection)) {
                    std::cerr << "Suite must be all, repeat, correctness, boundary, scaling, or large.\n"; return 1;
                }
            } else {
                suite_option = true;
                suite_options.output_prefix = argv[i];
                if (suite_options.output_prefix.empty()) { std::cerr << "Empty output prefix.\n"; return 1; }
            }
        }
        else if (std::string(argv[i]) == "--runs" || std::string(argv[i]) == "--warmup"
                 || std::string(argv[i]) == "--seed") {
            const std::string option = argv[i];
            if (++i == argc) { std::cerr << "Missing value for " << option << '\n'; return 1; }
            char* end = nullptr;
            const unsigned long long value = std::strtoull(argv[i], &end, 10);
            const unsigned long long limit = option == "--seed" ? 0xFFFFFFFFULL
                                           : option == "--runs" ? 1000ULL : 100ULL;
            if (argv[i][0] == '-' || end == argv[i] || *end != '\0' || value > limit
                || (option == "--runs" && value == 0)) {
                std::cerr << "Invalid value for " << option << '\n'; return 1;
            }
            suite_option = true;
            if (option == "--runs") suite_options.runs = static_cast<int>(value);
            else if (option == "--warmup") suite_options.warmup = static_cast<int>(value);
            else suite_options.seed = static_cast<uint32_t>(value);
        }
        else if (std::string(argv[i]) == "--verbose") verbose = true;
        else if (std::string(argv[i]) == "--swap-bytes") swap_bytes = true;
        else if (std::string(argv[i]) == "--help") {
            std::cout << "Usage: gemm_test [--benchmark | --diag | --mem-test | --dma-input-test | --tile-test | --accum-test]\n"
                      << "  -M/-K/-N 1..1024  Benchmark dimensions (default 64 each)\n"
                      << "  --poll-us 0..1000  Completion polling sleep (default 10; 0 busy-polls)\n"
                      << "  --verbose          Print each tile step (adds console overhead)\n"
                      << "  --suite all|repeat|correctness|boundary|scaling|large\n"
                      << "  --suite-list       Show suite points without mapping or accessing hardware\n"
                      << "  --runs 1..1000     Measured suite runs per point (default 30)\n"
                      << "  --warmup 0..100    Excluded suite warmups per point (default 3)\n"
                      << "  --seed 0..4294967295  Base seed (default 23063)\n"
                      << "  --output-prefix PATH  CSV and manifest prefix; existing files are refused\n"
                      << "Suites default to poll-us 0; large runs 256,512,768,1024 cubed.\n";
            return 0;
        }
        else if (std::string(argv[i]) == "-M" || std::string(argv[i]) == "-K"
                 || std::string(argv[i]) == "-N" || std::string(argv[i]) == "--poll-us") {
            const std::string option = argv[i];
            if (++i == argc) {
                std::cerr << "Missing value for " << option << '\n';
                return 1;
            }
            char* end = nullptr;
            const long value = std::strtol(argv[i], &end, 10);
            const bool polling = option == "--poll-us";
            if (end == argv[i] || *end != '\0' || value < (polling ? 0 : 1)
                || value > (polling ? 1000 : 1024)) {
                std::cerr << "Invalid value for " << option << '\n';
                return 1;
            }
            if (option == "-M") { test_M = static_cast<int>(value); dimensions_explicit = true; }
            else if (option == "-K") { test_K = static_cast<int>(value); dimensions_explicit = true; }
            else if (option == "-N") { test_N = static_cast<int>(value); dimensions_explicit = true; }
            else { poll_us = static_cast<int>(value); poll_explicit = true; }
        } else {
            std::cerr << "Unknown option: " << argv[i] << "; use --help.\n";
            return 1;
        }
    }

    if (static_cast<int>(diag_only) + static_cast<int>(mem_only)
        + static_cast<int>(dma_input_only) + static_cast<int>(tile_only)
        + static_cast<int>(accum_only) + static_cast<int>(benchmark)
        + static_cast<int>(suite_mode || suite_list) > 1) {
        std::cerr << "Choose a single test or benchmark mode.\n";
        return 1;
    }
    if (suite_option && !suite_mode && !suite_list) {
        std::cerr << "Suite options require --suite or --suite-list.\n"; return 1;
    }
    if (suite_mode || suite_list) {
        if (dimensions_explicit || verbose || swap_bytes) {
            std::cerr << "Suites define their dimensions and require default packing with tile logging off.\n";
            return 1;
        }
        suite_options.poll_us = poll_explicit ? poll_us : 0;
        if (suite_list) {
            gemm_suite::print_plan(suite_options, gemm_suite::cases(suite_options.selection));
            return 0;
        }
    }
    if (swap_bytes && (benchmark || accum_only
        || (!diag_only && !mem_only && !dma_input_only && !tile_only))) {
        std::cerr << "Benchmark requires the validated default MSGDMA byte order.\n";
        return 1;
    }
    if (accum_only) {
        if (swap_bytes) {
            std::cerr << "--accum-test requires the validated default MSGDMA byte order.\n";
            return 1;
        }
        test_M = 17; test_K = 33; test_N = 19;
    }
    SystolicArrayDriver sa(swap_bytes);
    if (!sa.init(diag_only)) {
        return 1;
    }

    sa.print_diagnostics();
    if (diag_only) {
        return 0;
    }
    if (mem_only) return sa.test_reserved_memory() ? 0 : 1;
    if (dma_input_only) return sa.test_input_dma() ? 0 : 1;
    if (tile_only) return sa.test_single_tile() ? 0 : 1;
    if (suite_mode) return gemm_suite::run(sa, suite_options, gemm_cpu);

    std::cout << "\n[CONFIG] Problem Size: M=" << test_M << ", K=" << test_K << ", N=" << test_N << "\n";
    std::cout << "  Decomposed into: "
              << ((test_M + 15) / 16) << "x" << ((test_N + 15) / 16)
              << " output tiles, " << ((test_K + 15) / 16) << " accumulate steps per tile\n";
    std::cout << "  Poll sleep: " << poll_us << " us; tile logging: "
              << (verbose || accum_only ? "on" : "off") << '\n';

    // Allocate matrices
    std::vector<int8_t> A(test_M * test_K);
    std::vector<int8_t> B(test_K * test_N);
    std::vector<int32_t> C_cpu(test_M * test_N, 0);
    std::vector<int32_t> C_hw(test_M * test_N, 0);

    // Initialize with deterministic pseudo-random test pattern (-10 to +10)
    for (size_t i = 0; i < A.size(); ++i) A[i] = static_cast<int8_t>(static_cast<int>(i % 21) - 10);
    for (size_t i = 0; i < B.size(); ++i) B[i] = static_cast<int8_t>(static_cast<int>((i * 3) % 21) - 10);

    // 1. CPU Reference Execution
    std::cout << "\n[1/3] Running CPU Reference Execution...\n";
    auto t0 = std::chrono::high_resolution_clock::now();
    gemm_cpu(test_M, test_K, test_N, A.data(), B.data(), C_cpu.data());
    auto t1 = std::chrono::high_resolution_clock::now();
    double cpu_time_us = std::chrono::duration<double, std::micro>(t1 - t0).count();
    std::cout << "  CPU Execution Time : " << std::fixed << std::setprecision(2) << cpu_time_us << " us\n";

    // 2. Hardware Coprocessor Tiled Execution
    std::cout << "\n[2/3] Running FPGA Systolic Array Coprocessor Execution...\n";
    uint64_t hw_cycles = 0;
    GemmTimings timings;
    auto hw_t0 = std::chrono::high_resolution_clock::now();
    bool success = sa.run_tiled_gemm(test_M, test_K, test_N, A.data(), B.data(), C_hw.data(),
                                   hw_cycles, timings, poll_us, verbose || accum_only);
    auto hw_t1 = std::chrono::high_resolution_clock::now();
    double hw_wall_us = std::chrono::duration<double, std::micro>(hw_t1 - hw_t0).count();

    if (!success) {
        std::cerr << "\n[FAIL] Hardware execution encountered an error/timeout!\n";
        return 1;
    }

    // 3. Verification: Word-by-word comparison
    std::cout << "\n[3/3] Verifying Hardware Output Against Golden Model...\n";
    int mismatches = 0;
    for (int i = 0; i < test_M; ++i) {
        for (int j = 0; j < test_N; ++j) {
            int32_t exp = C_cpu[i * test_N + j];
            int32_t got = C_hw[i * test_N + j];
            if (exp != got) {
                if (mismatches < 10) {
                    std::cerr << "  [MISMATCH] at (" << i << "," << j << "): expected "
                              << exp << ", got " << got << "\n";
                }
                mismatches++;
            }
        }
    }

    if (mismatches == 0) {
        std::cout << "  >>> VERIFICATION PASSED: 0 mismatches across " << (test_M * test_N) << " elements! <<<\n";
    } else {
        std::cerr << "  >>> VERIFICATION FAILED: " << mismatches << " total mismatches! <<<\n";
    }

    // Performance Calculations
    double total_ops = 2.0 * test_M * test_K * test_N;
    double hw_core_us = hw_cycles * 0.01; // 100 MHz clock = 10 ns per cycle
    double core_gops = (total_ops / (hw_core_us * 1e-6)) / 1e9;
    double wall_gops = (total_ops / (hw_wall_us * 1e-6)) / 1e9;

    std::cout << "\n========================================================\n";
    std::cout << "                     PERFORMANCE SUMMARY                \n";
    std::cout << "========================================================\n";
    std::cout << "  Total Operations    : " << total_ops / 1e6 << " MOPs\n";
    std::cout << "  Hardware Cycles     : " << hw_cycles << " cycles (" << hw_core_us << " us @ 100MHz)\n";
    std::cout << "  Host End-to-End Time: " << hw_wall_us << " us\n";
    std::cout << "  Reset / buffer init : " << timings.reset_us << " us\n"
              << "  Operand packing     : " << timings.pack_us << " us\n"
              << "  CSR / DMA submission: " << timings.submit_us << " us\n"
              << "  Completion waits    : " << timings.wait_us << " us\n"
              << "  Output / cycle reads: " << timings.decode_us << " us\n"
              << "  Tile steps / outputs: " << timings.steps << " / " << timings.output_tiles << '\n'
              << "  Input / output bytes: " << timings.steps * 512 << " / " << timings.output_tiles * 1024 << '\n';
    std::cout << "  Core Compute Rate   : " << std::fixed << std::setprecision(2) << core_gops << " GOPS\n";
    std::cout << "  Wall Throughput     : " << std::fixed << std::setprecision(2) << wall_gops << " GOPS\n";
    std::cout << "  Speedup over ARM CPU: " << (cpu_time_us / hw_wall_us) << "x (end-to-end), "
              << (cpu_time_us / hw_core_us) << "x (core)\n";
    std::cout << "========================================================\n\n";
    std::cout << "Core timing counts PE compute/reset/flush cycles only; waits include DMA and polling.\n"
              << "Rates use useful matrix operations; padded work is excluded.\n";

    return (mismatches == 0) ? 0 : 1;
}

// harte_p_verilator_main.cpp — batched Harte runner for MH030-P (rtlp/),
// Verilator backend. Generated from tb/harte_verilator_main.cpp and differing
// from it in exactly two places: the header names, and how architectural state
// is read out of a core whose register file is one flat 16-entry array and
// whose SR is split between sr_sys_r and the testbench's captured CCR.
//
// Same manifest-driven batching as tb/harte_batch_tb.sv (many tests per
// process, real rst_n pulse between them, no memory clear -- see plan.md's
// batching investigation for why that's safe), but compiled to native code
// via Verilator instead of interpreted by Icarus, and driven entirely from
// C++ (mirrors tb/mustest_main.cpp's proven pattern: poke memory directly
// via rootp access, no $readmemh, no SV-side loop).
//
// Each manifest line points to a small per-test "blob" file (written by
// scripts/run_harte_batch.py's Verilator backend) with two sections:
//   P <n>                  n patch entries follow: <addr_hex> <byte_hex>
//   W <m>                  m watch addresses follow: <addr_hex>
// Patches are applied directly into mem[] before reset; watch addresses are
// read back from mem[] after the run and reported as MEMWRITE lines -- final
// memory state is all Harte's own JSON format ever specifies (initial/final
// snapshots only, no intermediate bus trace), so this is not a loss of
// verification fidelity versus tb/harte_batch_tb.sv's cycle-by-cycle
// $display capture, just a faster way to get the same answer.
//
// Output format matches tb/harte_batch_tb.sv exactly (=== TEST N ===,
// REGSTATE, MEMWRITE, OK/TIMEOUT/ADDRERR, ENDTEST) so
// scripts/run_harte_batch.py's split_batch_output()/parse_block()/compare()
// work completely unchanged -- only the "how do I generate one chunk's
// input and invoke the simulator" step differs between backends.
//
// Usage: sim/harte_pvbatch +manifest=<path> [+cycles=<N>]

#include "Vharte_p_verilator_tb.h"
#include "Vharte_p_verilator_tb___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

static const char* plus_str(int argc, char** argv, const char* key, const char* dflt) {
    const int klen = strlen(key);
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '+' && strncmp(argv[i] + 1, key, klen) == 0
                && argv[i][1 + klen] == '=')
            return argv[i] + 2 + klen;
    }
    return dflt;
}
static int plus_int(int argc, char** argv, const char* key, int dflt) {
    const char* v = plus_str(argc, argv, key, nullptr);
    return v ? atoi(v) : dflt;
}

struct Patch { uint32_t addr; uint8_t val; };

struct TestBlob {
    std::vector<Patch>   patches;
    std::vector<uint32_t> watch;
};

static bool load_blob(const std::string& path, TestBlob& blob) {
    std::ifstream f(path);
    if (!f) return false;
    std::string tag;
    int n = 0;
    if (!(f >> tag >> n) || tag != "P") return false;
    blob.patches.resize(n);
    for (int i = 0; i < n; i++) {
        unsigned a, v;
        f >> std::hex >> a >> v;
        blob.patches[i] = {a, (uint8_t)v};
    }
    if (!(f >> tag >> n) || tag != "W") return false;
    blob.watch.resize(n);
    for (int i = 0; i < n; i++) {
        unsigned a;
        f >> std::hex >> a;
        blob.watch[i] = a;
    }
    return true;
}

// Same big-endian-within-32-bit-word byte convention as
// scripts/gen_harte_hex.py's patches_to_hex() (shift = (3 - (addr&3)) * 8).
// Templated so it works whether Verilator exposes the unpacked array as a
// raw pointer or a VlUnpacked<> wrapper (varies by version).
template <class Mem>
static inline void mem_write_byte(Mem& mem, uint32_t addr, uint8_t val) {
    uint32_t widx  = (addr >> 2) & 0x3FFFFFu;
    int      shift = (3 - (addr & 3)) * 8;
    mem[widx] = (mem[widx] & ~(0xFFu << shift)) | ((uint32_t)val << shift);
}
template <class Mem>
static inline uint8_t mem_read_byte(const Mem& mem, uint32_t addr) {
    uint32_t widx  = (addr >> 2) & 0x3FFFFFu;
    int      shift = (3 - (addr & 3)) * 8;
    return (uint8_t)((mem[widx] >> shift) & 0xFFu);
}

int main(int argc, char** argv) {
    std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);

    const char* manifest_path = plus_str(argc, argv, "manifest", "");
    const int   cycles        = plus_int(argc, argv, "cycles", 8000);
    if (!manifest_path[0]) {
        fprintf(stderr, "ERROR: +manifest=<path> required\n");
        return 1;
    }

    std::ifstream mf(manifest_path);
    if (!mf) {
        fprintf(stderr, "ERROR: cannot open manifest %s\n", manifest_path);
        return 1;
    }

    std::unique_ptr<Vharte_p_verilator_tb> top{new Vharte_p_verilator_tb{ctx.get()}};
    auto& mem = top->rootp->harte_p_verilator_tb__DOT__mem;

    std::string blob_path;
    int idx = 0;
    while (std::getline(mf, blob_path)) {
        if (blob_path.empty()) continue;

        printf("=== TEST %d ===\n", idx);

        TestBlob blob;
        if (!load_blob(blob_path, blob)) {
            printf("TIMEOUT\n");
            printf("ENDTEST\n");
            idx++;
            continue;
        }

        // mem[] deliberately carries over from the previous test -- see
        // plan.md's batching investigation for why that's safe (patches
        // always fully re-specify what each test depends on).
        for (const auto& p : blob.patches) mem_write_byte(mem, p.addr, p.val);

        // Reset: 20 full clk_4x periods (40 half-toggles) with rst_n=0,
        // matching tb/harte_batch_tb.sv's `repeat(20) @(posedge clk_4x)`.
        top->rst_n  = 0;
        top->clk_4x = 0;
        top->eval();
        for (int i = 0; i < 40; i++) {
            top->clk_4x = !top->clk_4x;
            ctx->timeInc(5);
            top->eval();
        }
        top->rst_n = 1;
        top->eval();

        bool stopped = false;
        for (int i = 0; i < cycles; i++) {
            top->clk_4x = 1; ctx->timeInc(5); top->eval();
            top->clk_4x = 0; ctx->timeInc(5); top->eval();
            if (top->stop_out) {
                // 4 more full periods, matching harte_batch_tb.sv's
                // `repeat(4) @(posedge clk_4x)` settle wait.
                for (int j = 0; j < 4; j++) {
                    top->clk_4x = 1; ctx->timeInc(5); top->eval();
                    top->clk_4x = 0; ctx->timeInc(5); top->eval();
                }
                stopped = true;
                break;
            }
        }

        auto* r = top->rootp;
        // regs[0..7] are D0-D7 and regs[8..15] are A0-A7, one flat array --
        // there is no separate a7_current, because this core has no shadow
        // stack pointer yet.
        auto&    rg  = r->harte_p_verilator_tb__DOT__dut__DOT__u_cpu__DOT__u_core__DOT__u_rf__DOT__regs;
        uint32_t pc  = r->harte_p_verilator_tb__DOT__dut__DOT__if_pc;
        uint16_t sr  = (uint16_t)((r->harte_p_verilator_tb__DOT__dut__DOT__u_cpu__DOT__u_core__DOT__sr_sys_r << 8)
                     | r->harte_p_verilator_tb__DOT__ccr_before_stop);

        printf("REGSTATE D0=%08x D1=%08x D2=%08x D3=%08x D4=%08x D5=%08x D6=%08x D7=%08x "
               "A0=%08x A1=%08x A2=%08x A3=%08x A4=%08x A5=%08x A6=%08x A7=%08x SR=%04x PC=%08x\n",
               rg[0], rg[1], rg[2],  rg[3],  rg[4],  rg[5],  rg[6],  rg[7],
               rg[8], rg[9], rg[10], rg[11], rg[12], rg[13], rg[14], rg[15],
               sr, pc);

        for (uint32_t addr : blob.watch)
            printf("MEMWRITE %06x %02x\n", addr, mem_read_byte(mem, addr));

        if (!stopped)
            printf("TIMEOUT\n");
        else
            printf("OK\n");

        printf("ENDTEST\n");
        idx++;
    }

    top->final();
    return 0;
}

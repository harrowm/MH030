#include "Vmustest_tb.h"
#include "Vmustest_tb___024root.h"   // exposes rootp->mustest_tb__DOT__main_mem
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>

static const char* plus_str(int argc, char** argv, const char* key, const char* dflt) {
    const int klen = strlen(key);
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '+' && strncmp(argv[i]+1, key, klen) == 0
                && argv[i][1+klen] == '=')
            return argv[i] + 2 + klen;
    }
    return dflt;
}
static int plus_int(int argc, char** argv, const char* key, int dflt) {
    const char* v = plus_str(argc, argv, key, nullptr);
    return v ? atoi(v) : dflt;
}

static void load_hex(Vmustest_tb* top, const char* path) {
    auto& mem = top->rootp->mustest_tb__DOT__main_mem;
    auto& xram = top->rootp->mustest_tb__DOT__ext_ram;

    for (int i = 0; i < 32768; i++) mem[i]  = 0xDEADBEEFU;
    for (int i = 0; i < 16384; i++) xram[i] = 0;
    mem[0] = 0x000003F0U;   // SSP
    mem[1] = 0x00010000U;   // reset PC

    if (!path || !path[0]) return;
    std::ifstream f(path);
    std::string line;
    int idx = 16384;
    while (std::getline(f, line) && idx < 32768) {
        if (line.empty() || line[0] == '/') continue;
        mem[idx++] = (uint32_t)strtoul(line.c_str(), nullptr, 16);
    }
}

int main(int argc, char** argv) {
    std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);

    const char* hexfile  = plus_str(argc, argv, "hexfile",  "");
    const char* testname = plus_str(argc, argv, "testname", "mustest");
    const int   cycles   = plus_int(argc, argv, "cycles",   5000000);

    std::unique_ptr<Vmustest_tb> top{new Vmustest_tb{ctx.get()}};

    load_hex(top.get(), hexfile);

    // Reset: 80 half-cycles (40 full clk_4x periods) with rst_n=0
    top->rst_n  = 0;
    top->clk_4x = 0;
    top->eval();
    for (int i = 0; i < 80; i++) {
        top->clk_4x ^= 1;
        ctx->timeInc(5);
        top->eval();
    }
    top->rst_n = 1;
    top->eval();

    // Bus trace: set MUSTEST_TRACE=1 in environment for diagnostic output
    bool do_trace = getenv("MUSTEST_TRACE") != nullptr;
    int  trace_max = 10000;   // max bus cycles to print

    // Run: one iteration = one full clk_4x period (posedge + negedge)
    bool stopped = false;
    uint8_t prev_as = 1;
    int bus_cyc = 0;
    for (int i = 0; i < cycles; i++) {
        top->clk_4x = 1;
        ctx->timeInc(5);
        top->eval();

        // Sample bus signals on posedge (after eval)
        if (do_trace) {
            auto* r = top->rootp;
            uint8_t  as_n  = r->mustest_tb__DOT__ext_as_n;
            uint8_t  ds_n  = r->mustest_tb__DOT__ext_ds_n;
            uint8_t  rw    = r->mustest_tb__DOT__ext_rw;
            uint8_t  fc    = r->mustest_tb__DOT__ext_fc;
            uint8_t  siz   = r->mustest_tb__DOT__ext_siz;
            uint32_t a     = r->mustest_tb__DOT__ext_a;
            uint32_t d_out = r->mustest_tb__DOT__ext_d_out;
            uint32_t d_in  = r->mustest_tb__DOT__ext_d_in;
            uint8_t  d_oe  = r->mustest_tb__DOT__ext_d_oe;
            // Print when DS active (data phase); also log first DS assert separately
            uint8_t ds_active = r->mustest_tb__DOT__ds_active_r;
            // Detect first cycle DS asserts (SP_S3: ds_active=0 but DS+AS active)
            if (!ds_n && !as_n && !rw && d_oe && !ds_active) {
                if (bus_cyc < trace_max)
                    fprintf(stderr, "[cyc %5d] S3   W %08x siz=%d d_out=%08x\n",
                            i, a, siz, d_out);
            }
            if (ds_active && !ds_n && !as_n) {
                if (bus_cyc < trace_max) {
                    if (rw)
                        fprintf(stderr, "[cyc %5d] BUS R %08x siz=%d d_in =%08x\n",
                                i, a, siz, d_in);
                    else
                        fprintf(stderr, "[cyc %5d] BUS W %08x siz=%d d_out=%08x oe=%d\n",
                                i, a, siz, d_out, d_oe);
                }
                bus_cyc++;
            }
            prev_as = as_n;
        }

        top->clk_4x = 0;
        ctx->timeInc(5);
        top->eval();

        // Detailed per-cycle trace for write to 0x3E8
        if (do_trace && i >= 464 && i <= 476) {
            auto* r = top->rootp;
            uint8_t  as_n    = r->mustest_tb__DOT__ext_as_n;
            uint8_t  ds_n    = r->mustest_tb__DOT__ext_ds_n;
            uint8_t  rw      = r->mustest_tb__DOT__ext_rw;
            uint32_t d_out   = r->mustest_tb__DOT__ext_d_out;
            uint8_t  d_oe    = r->mustest_tb__DOT__ext_d_oe;
            uint8_t  ds_act  = r->mustest_tb__DOT__ds_active_r;
            uint32_t a       = r->mustest_tb__DOT__ext_a;
            uint32_t mem_fa  = r->mustest_tb__DOT__main_mem[0xFA];
            fprintf(stderr, "[cyc %5d] a=%08x as=%d ds=%d rw=%d d_out=%08x d_oe=%d ds_act=%d mem[FA]=%08x\n",
                    i, a, as_n, ds_n, rw, d_out, d_oe, ds_act, mem_fa);
        }
        if (top->stop_out) {
            for (int j = 0; j < 8; j++) {
                top->clk_4x ^= 1;
                ctx->timeInc(5);
                top->eval();
            }
            stopped = true;
            break;
        }
    }
    if (do_trace) fprintf(stderr, "Total bus cycles seen: %d\n", bus_cyc);

    // Debug: dump key memory locations to verify write data
    if (do_trace) {
        auto* r = top->rootp;
        fprintf(stderr, "main_mem[0x6]  (addr 0x18)  = %08x\n", r->mustest_tb__DOT__main_mem[0x6]);
        fprintf(stderr, "main_mem[0x7]  (addr 0x1C)  = %08x\n", r->mustest_tb__DOT__main_mem[0x7]);
        fprintf(stderr, "main_mem[0xFB] (addr 0x3EC) = %08x\n", r->mustest_tb__DOT__main_mem[0xFB]);
        fprintf(stderr, "ext_ram[0x3C00] (addr 0x30F000) = %08x\n", r->mustest_tb__DOT__ext_ram[0x3C00]);
    }

    if (!stopped)
        printf("FAIL  %s (timeout after %d cycles)\n", testname, cycles);
    else if (top->fail_out)
        printf("FAIL  %s\n", testname);
    else if (top->pass_out)
        printf("PASS  %s\n", testname);
    else
        printf("FAIL  %s (no pass/fail written)\n", testname);

    top->final();
    return 0;
}

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
    // Extra: always track writes to test device (0x1000xx) for debugging
    bool track_tdev = getenv("MUSTEST_TDEV") != nullptr;
    // MUSTEST_PREBUF=N: circular buffer of last N bus events before TDEV write
    int prebuf_n = 0;
    {
        const char* v = getenv("MUSTEST_PREBUF");
        if (v) prebuf_n = atoi(v);
    }
    struct BusEv { int cyc; bool rw; uint32_t a; int siz; uint32_t d; };
    std::vector<BusEv> prebuf;
    if (prebuf_n > 0) prebuf.reserve(prebuf_n + 1);

    // Run: one iteration = one full clk_4x period (posedge + negedge)
    bool stopped = false;
    uint8_t prev_as = 1;
    int bus_cyc = 0;
    for (int i = 0; i < cycles; i++) {
        top->clk_4x = 1;
        ctx->timeInc(5);
        top->eval();

        // Sample bus signals on posedge (after eval)
        {
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
            if (do_trace) {
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
            }
            // Always track writes to test device (0x10xxxx) if MUSTEST_TDEV set
            if ((track_tdev || prebuf_n > 0) && ds_active && !ds_n && !as_n
                    && !rw && d_oe && (a >> 16) == 0x10) {
                // Dump pre-buffer before announcing tdev write
                if (prebuf_n > 0) {
                    for (auto& e : prebuf)
                        fprintf(stderr, "[pre %7d] BUS %c %08x siz=%d d=%08x\n",
                                e.cyc, e.rw ? 'R' : 'W', e.a, e.siz, e.d);
                    prebuf.clear();
                }
                if (track_tdev)
                    fprintf(stderr, "[cyc %7d] TDEV W %08x siz=%d d_out=%08x\n",
                            i, a, siz, d_out);
            }
            // Pre-buffer: accumulate bus events for MUSTEST_PREBUF
            if (prebuf_n > 0 && ds_active && !ds_n && !as_n) {
                static uint32_t last_pa = 0xFFFFFFFF; static int last_pcyc = -99;
                if (a != last_pa || i > last_pcyc + 15) {  // deduplicate multi-tick
                    if ((int)prebuf.size() >= prebuf_n) prebuf.erase(prebuf.begin());
                    prebuf.push_back({i, (bool)rw, a, siz, rw ? d_in : d_out});
                    last_pa = a; last_pcyc = i;
                }
            }
            prev_as = as_n;
        }

        top->clk_4x = 0;
        ctx->timeInc(5);
        top->eval();

        // Targeted trace around the ADDX write (cycle range via env MUSTEST_TRACE_LO/HI)
        {
            static int trace_lo = -1, trace_hi = -1;
            if (trace_lo < 0) {
                const char* lo = getenv("MUSTEST_TRACE_LO");
                const char* hi = getenv("MUSTEST_TRACE_HI");
                trace_lo = lo ? atoi(lo) : -1;
                trace_hi = hi ? atoi(hi) : -1;
            }
            if (trace_lo >= 0 && i >= trace_lo && i <= trace_hi) {
                auto* r = top->rootp;
                uint8_t  as_n    = r->mustest_tb__DOT__ext_as_n;
                uint8_t  ds_n    = r->mustest_tb__DOT__ext_ds_n;
                uint8_t  rw      = r->mustest_tb__DOT__ext_rw;
                uint32_t d_out   = r->mustest_tb__DOT__ext_d_out;
                uint8_t  d_oe    = r->mustest_tb__DOT__ext_d_oe;
                uint8_t  ds_act  = r->mustest_tb__DOT__ds_active_r;
                uint32_t a       = r->mustest_tb__DOT__ext_a;
                // ADDX/write-data path internals
                uint8_t  phase   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_mem_phase_r;
                uint8_t  run     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_mem_run_r;
                uint32_t src     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_src_r;
                uint32_t dst     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_dst_r;
                uint32_t ex_res  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__ex_result;
                uint32_t mem_wd  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_wdata;
                uint32_t biu_wd  = r->mustest_tb__DOT__u_top__DOT__biu_eu_wdata;
                uint8_t  ci_st   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cache__DOT__state;
                uint32_t ci_wd   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cache__DOT__wdata_r;
                uint8_t  sf_st   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf;
                uint32_t sf_wd   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf_wdata;
                uint32_t sf_cwd  = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__cyc_wdata;
                uint32_t cg_cwd  = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cg__DOT__cyc_wdata;
                uint8_t  geu     = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__grant_eu;
                uint8_t  bidle   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__bus_idle;
                fprintf(stderr, "[cyc %7d] a=%08x as=%d ds=%d rw=%d d_out=%08x oe=%d dact=%d"
                        " | ph=%d run=%d src=%08x dst=%08x exr=%08x mwd=%08x biuwd=%08x"
                        " | ci=%d ciwd=%08x sf=%d sfwd=%08x sfcwd=%08x cgcwd=%08x geu=%d idle=%d\n",
                        i, a, as_n, ds_n, rw, d_out, d_oe, ds_act,
                        phase, run, src, dst, ex_res, mem_wd, biu_wd,
                        ci_st, ci_wd, sf_st, sf_wd, sf_cwd, cg_cwd, geu, bidle);
            }
        }
        // ADDX-FSM trace: dump write-data path whenever addx is active (MUSTEST_ADDX_TRACE env)
        if (getenv("MUSTEST_ADDX_TRACE")) {
            auto* r = top->rootp;
            uint8_t run = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_mem_run_r;
            if (run) {
                uint8_t  phase   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_mem_phase_r;
                uint32_t src     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_src_r;
                uint32_t dst     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__addx_dst_r;
                uint32_t ex_res  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__ex_result;
                uint32_t mem_wd  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_wdata;
                uint32_t biu_wd  = r->mustest_tb__DOT__u_top__DOT__biu_eu_wdata;
                uint8_t  ci_st   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cache__DOT__state;
                uint32_t ci_wd   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cache__DOT__wdata_r;
                uint8_t  sf_st   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf;
                uint32_t sf_wd   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf_wdata;
                uint32_t sf_cwd  = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__cyc_wdata;
                uint32_t cg_cwd  = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cg__DOT__cyc_wdata;
                uint8_t  geu     = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__grant_eu;
                uint8_t  geur    = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_arb__DOT__grant_eu_r;
                uint8_t  bidle   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__bus_idle;
                uint32_t a       = r->mustest_tb__DOT__ext_a;
                uint32_t d_out   = r->mustest_tb__DOT__ext_d_out;
                uint8_t  cgst    = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_cg__DOT__state;
                fprintf(stderr, "[addx %7d] ph=%d src=%08x dst=%08x exr=%08x mwd=%08x biuwd=%08x"
                        " ci=%d ciwd=%08x sf=%d sfwd=%08x sfcwd=%08x cgcwd=%08x geu=%d geur=%d idle=%d cgst=%d a=%08x dout=%08x\n",
                        i, phase, src, dst, ex_res, mem_wd, biu_wd,
                        ci_st, ci_wd, sf_st, sf_wd, sf_cwd, cg_cwd, geu, geur, bidle, cgst, a, d_out);
            }
        }
        // MOVEP-FSM trace: dump FSM state whenever any movep state is active
        if (getenv("MUSTEST_MOVEP_TRACE")) {
            auto* r = top->rootp;
            uint8_t mp_st  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_start_r;
            uint8_t mp_pre = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_pre_r;
            uint8_t mp_run = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_run_r;
            uint8_t mp_ld  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_load_r;
            uint8_t mp_lng = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_long_r;
            uint8_t mp_bc  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_byte_r;
            uint8_t mp_lst = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_last;
            uint32_t mp_av = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_addr_r;
            uint32_t mp_dv = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_dn_val_r;
            uint8_t  mp_wb = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movep_wr_byte_r;
            uint8_t  iac   = r->mustest_tb__DOT__u_top__DOT__eu_instr_ack;
            uint8_t  dim   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__dec_is_movep;
            uint32_t rbd   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__rd_b_data;
            uint8_t  mrq   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_req;
            uint8_t  mak   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_ack;
            if (mp_st || mp_pre || mp_run || dim) {
                fprintf(stderr, "[movep %7d] st=%d pre=%d run=%d ld=%d lng=%d bc=%d lst=%d"
                        " addr=%08x dnval=%08x wbyte=%02x iac=%d dim=%d rbd=%08x mrq=%d mak=%d\n",
                        i, mp_st, mp_pre, mp_run, mp_ld, mp_lng, mp_bc, mp_lst,
                        mp_av, mp_dv, mp_wb, iac, dim, rbd, mrq, mak);
            }
        }
        // MOVEM-FSM trace: dump write-data path whenever movem_run_r is active
        if (getenv("MUSTEST_MOVEM_TRACE")) {
            auto* r = top->rootp;
            uint8_t  mv_run  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_run_r;
            if (mv_run) {
                uint8_t  mv_ld   = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_load_r;
                uint8_t  mv_lng  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_long_r;
                uint16_t mv_msk  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_mask_r;
                uint8_t  mv_bidx = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_bit_idx;
                uint8_t  mv_rsel = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_reg_sel;
                uint32_t mv_addr = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__movem_addr_r;
                uint8_t  ra_sel  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__rd_a_sel;
                uint32_t ra_data = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__rd_a_data;
                uint32_t mem_wd  = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_wdata;
                uint32_t biu_wd  = r->mustest_tb__DOT__u_top__DOT__biu_eu_wdata;
                uint8_t  mrq     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_req;
                uint8_t  mak     = r->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_seq__DOT__mem_ack;
                uint8_t  sf_st   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf;
                uint32_t sf_wd   = r->mustest_tb__DOT__u_top__DOT__u_biu__DOT__u_sf__DOT__sf_wdata;
                uint32_t d_out   = r->mustest_tb__DOT__ext_d_out;
                fprintf(stderr, "[movem %7d] run=%d ld=%d lng=%d mask=%04x bidx=%d rsel=%d addr=%08x"
                        " ra_sel=%d ra_data=%08x mwd=%08x biuwd=%08x mrq=%d mak=%d sf=%d sfwd=%08x dout=%08x\n",
                        i, mv_run, mv_ld, mv_lng, mv_msk, mv_bidx, mv_rsel, mv_addr,
                        ra_sel, ra_data, mem_wd, biu_wd, mrq, mak, sf_st, sf_wd, d_out);
            }
        }
        // Periodic D4 dump (every 2M cycles) if MUSTEST_REGDUMP set
        if (getenv("MUSTEST_REGDUMP") && (i % 2000000 == 0) && i > 0) {
            auto& dreg = top->rootp->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_rf__DOT__d_reg;
            printf("D4_AT_CYC%d = %08x D5=%08x D3=%08x D6=%08x\n",
                   i, dreg[4], dreg[5], dreg[3], dreg[6]);
            fflush(stdout);
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

    if (getenv("MUSTEST_REGDUMP")) {
        auto& dreg = top->rootp->mustest_tb__DOT__u_top__DOT__u_eu__DOT__u_rf__DOT__d_reg;
        printf("REGDUMP D0=%08x D1=%08x D2=%08x D3=%08x\n"
               "        D4=%08x D5=%08x D6=%08x D7=%08x\n",
               dreg[0], dreg[1], dreg[2], dreg[3],
               dreg[4], dreg[5], dreg[6], dreg[7]);
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

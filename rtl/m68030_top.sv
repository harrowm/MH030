`timescale 1ns/1ps
`default_nettype none

// MC68030 Top Level — full chip integration
//
// Integrates: m68030_biu, m68030_ifu, m68030_seq, m68030_eu, m68030_exc,
// m68030_mmu. All EU control registers (TC/TT0/TT1/CACR/CAAR) are wired
// to both the BIU and the MMU. I-cache (biu_icache_if, inside m68030_biu,
// Phase 127) and D-cache (biu_cache_if) are both real and reachable;
// CACR's icache_en/dcache_en bits reset to 0, so both come up disabled.
//
// Boot sequence:
//   BIU fetches SSP@0 and PC@4 (init_done pulse).  On the rising edge of
//   init_done, boot_pulse fires for one cycle and writes init_ssp → EU A7
//   and init_pc → EU PC + IFU fetch start.
//
// Exception bus mux:
//   When exc_active is asserted, EXC drives the BIU's eu_req port
//   (supervisor-data FC=101) for stack-frame pushes and vector fetch.
//   EU normal data requests are wired through eu_seq; the
//   OR logic means EXC always wins while active.

module m68030_top #(
    parameter int POWERON_RSTO_CLKS = 2048   // 4× clocks; pass-through to m68030_biu
) (
    input  logic        clk_4x,
    input  logic        rst_n,

    // ───────────────────────────────────────────────────────────────────────
    // External chip pins (pass-through to m68030_biu)
    // ───────────────────────────────────────────────────────────────────────
    output logic [31:0] ext_a,
    output logic [31:0] ext_d_out,
    output logic        ext_d_oe,
    input  logic [31:0] ext_d_in,
    output logic        ext_as_n,
    output logic        ext_ds_n,
    output logic        ext_rw,
    output logic [2:0]  ext_fc,
    output logic [1:0]  ext_siz,
    output logic        ext_ecs_n,
    output logic        ext_ocs_n,
    output logic        ext_rstout_n,
    output logic        ext_cbreq_n,
    output logic        ext_e,
    output logic        ext_bg_n,
    output logic        bus_halted,
    output logic        eu_stop,
    output logic        eu_addr_err,
    output logic        ifu_addr_err,
    input  logic        dsack0_n,
    input  logic        dsack1_n,
    input  logic        sterm_n,
    input  logic        berr_n,
    input  logic        halt_n,
    input  logic        avec_n,
    input  logic        vpa_n,
    input  logic [2:0]  ipl_n,
    input  logic        br_n,
    input  logic        bgack_n,
    input  logic        cback_n,
    // Phase 158 Stage 7: CIIN#/CIOUT# -- confirmed via grep neither pin
    // existed anywhere in the RTL before this stage.
    input  logic        ciin_n,
    output logic        ciout_n
);

    // ─── Control register stubs (caches disabled; MMU wired to m68030_mmu) ──
    localparam logic [31:0] CACR_RESET = 32'h0000_0000;
    localparam logic [31:0] CAAR_RESET = 32'h0000_0000;
    // TC, CRP, SRP, TT0, TT1: set by EU MOVEC — wired from EU regs (stub: disabled)
    localparam logic [31:0] TC_RESET   = 32'h0000_0000;
    localparam logic [63:0] CRP_RESET  = 64'h0000_0002_0000_0000;
    localparam logic [63:0] SRP_RESET  = 64'h0000_0002_0000_0000;
    localparam logic [31:0] TT0_RESET  = 32'h0000_0000;
    localparam logic [31:0] TT1_RESET  = 32'h0000_0000;

    // ───────────────────────────────────────────────────────────────────────
    // IPL synchronizer — 2-stage, active-high output
    // ───────────────────────────────────────────────────────────────────────
    logic [2:0] ipl_sync1_r, ipl_sync2_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ipl_sync1_r <= 3'b111;
            ipl_sync2_r <= 3'b111;
        end else begin
            ipl_sync1_r <= ipl_n;
            ipl_sync2_r <= ipl_sync1_r;
        end
    end
    logic [2:0] ipl_sync;
    assign ipl_sync = ~ipl_sync2_r;

    // ───────────────────────────────────────────────────────────────────────
    // BIU status wires
    // ───────────────────────────────────────────────────────────────────────
    logic        bus_idle, init_done;
    logic [31:0] init_ssp, init_pc;
    logic [1:0]  phase;
    logic [6:0]  s_state;
    logic [31:0] fault_addr_biu, fault_data_biu;
    logic [2:0]  fault_fc_biu;
    logic        fault_rw_biu;
    logic [1:0]  fault_siz_biu;
    logic        fault_valid_biu, fault_retry_biu, fault_is_rmw_biu;
    logic        retry_pending, halt_out;
    logic [3:0]  exc_frame_format;
    logic        exc_frame_valid;
    logic [15:0] exc_ssw;
    logic        mmu_fault, mmu_ci;
    logic [15:0] mmusr;

    // BIU EU-port return signals
    logic [31:0] eu_rdata;
    logic        eu_ack, eu_berr, eu_retry;
    logic [7:0]  eu_iack_vec;
    logic        eu_iack_avec, eu_iack_ack;
    logic        bus_lock;
    logic [31:0] eu_cas2_rdata1, eu_cas2_rdata2;
    logic        eu_cas2_ack;
    logic [31:0] eu_burst_rdata0, eu_burst_rdata1;
    logic [31:0] eu_burst_rdata2, eu_burst_rdata3;
    logic        eu_burst_ack, eu_burst_berr;
    logic        eu_m16_ack, eu_m16_berr;
    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic [31:0] eu_coproc_rdata;
    logic        eu_coproc_ack, eu_coproc_berr;
    logic        eu_bkpt_req, eu_bkpt_rw;
    logic [1:0]  eu_bkpt_siz;
    logic [2:0]  eu_bkpt_fc;
    logic [31:0] eu_bkpt_addr, eu_bkpt_wdata;
    logic [31:0] eu_bkpt_rdata;
    logic        eu_bkpt_ack, eu_bkpt_berr;
    logic        eu_bkpt_illegal_req_w;
    // open-items backlog Stage 13 (plan.md): live opcode substitution.
    logic        eu_bkpt_subst_active_w;
    logic [15:0] eu_bkpt_subst_word_w;
    logic [31:0] eu_mo_rdata0, eu_mo_rdata1;
    logic [31:0] eu_mo_rdata2, eu_mo_rdata3;
    logic        eu_mo_ack, eu_mo_berr;

    // BIU IFU-port return signals
    logic [31:0] ifu_rdata;
    logic        ifu_ack, ifu_berr;

    // ───────────────────────────────────────────────────────────────────────
    // Boot one-shot — fires for one cycle on the rising edge of init_done
    // ───────────────────────────────────────────────────────────────────────
    logic init_done_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) init_done_r <= 1'b0;
        else        init_done_r <= init_done;
    logic boot_pulse;
    assign boot_pulse = init_done & ~init_done_r;

    // ───────────────────────────────────────────────────────────────────────
    // EU output wires
    // ───────────────────────────────────────────────────────────────────────
    logic        eu_instr_ack, eu_busy;
    // Interrupt dispatch-race handshake: exc's int_pending flows into eu_seq
    // (via m68030_eu), and eu_seq's "deliberately holding a ready instruction
    // in DECODE" pulse flows back, replacing the old !eu_busy gate (which
    // raced with an instruction launching the same cycle stall cleared).
    logic        exc_int_pending_w, eu_int_ready_w;
    logic [31:0] eu_pc_out, eu_vbr_out;
    logic [31:0] eu_usp_out, eu_msp_out, eu_isp_out;
    logic [15:0] eu_sr_out;
    logic        eu_supervisor, eu_master_mode;
    logic [2:0]  eu_ipl_mask;
    logic        eu_div_trap;
    logic        eu_chk_trap;
    logic        eu_need_ext_w;  // 10-item backlog Stage 5 (plan.md)
    logic        eu_trap_req_w;
    logic [3:0]  eu_trap_num_w;
    logic        eu_trapv_req_w;
    logic        eu_illegal_req_w;
    logic        eu_priv_req_w;
    logic        eu_trace_req_w;
    logic        eu_linea_req_w;
    logic        eu_linef_req_w;
    logic        eu_fmt_err_req_w;

    // ───────────────────────────────────────────────────────────────────────
    // IFU output wires
    // ───────────────────────────────────────────────────────────────────────
    logic [15:0] ifu_instr_word;
    logic [31:0] ifu_ext_data;
    logic [15:0] ifu_q3_word;
    logic [31:0] ifu_ext34_data;
    logic [15:0] ifu_q5_word;      // Phase 145
    logic        ifu_instr_valid, ifu_ext_valid, ifu_ext4_valid, ifu_ext5_valid;
    logic        ifu_ext6_valid;   // Phase 145
    logic        ifu_ext1_valid;   // Phase 163 Stage 1 (plan.md)
    logic [31:0] ifu_decode_pc;
    logic [31:0] eu_ex_decode_pc;  // Phase 150 Stage 1 (plan.md): see eu_seq.sv's own ex_decode_pc_out comment
    logic [31:0] ifu_bus_addr;
    logic        ifu_bus_req;
    logic [2:0]  ifu_fc_out;
    logic        ifu_bus_err;
    logic [31:0] ifu_bus_err_addr;
    logic        ifu_addr_err_int;

    // ───────────────────────────────────────────────────────────────────────
    // SEQ output wires
    // ───────────────────────────────────────────────────────────────────────
    logic [2:0]  seq_drain;
    logic [15:0] seq_eu_instr_word;
    logic [31:0] seq_eu_ext_data;
    logic [15:0] seq_eu_q3_word;
    logic [31:0] seq_eu_ext34_data;
    logic [15:0] seq_eu_q5_word;    // Phase 145
    logic        seq_eu_instr_valid, seq_eu_ext_valid;

    // ───────────────────────────────────────────────────────────────────────
    // EXC output wires
    // ───────────────────────────────────────────────────────────────────────
    logic [31:0] exc_addr_w, exc_wdata_w, exc_rdata_w;
    logic        exc_rw_w;
    logic [1:0]  exc_siz_w;
    logic        exc_req_w, exc_ack_w;
    logic [31:0] exc_ssp_out;
    logic        exc_ssp_wr_en;
    logic [31:0] exc_new_pc;
    logic        exc_new_pc_wr;
    logic [15:0] exc_new_sr;
    logic        exc_new_sr_wr;
    logic        exc_active;
    logic [7:0]  exc_vector_num;

    // EU memory bus signals (from m68030_eu)
    logic        eu_mem_req, eu_mem_rw;
    logic [1:0]  eu_mem_siz;
    logic [2:0]  eu_mem_fc;
    logic [31:0] eu_mem_addr, eu_mem_wdata;
    logic        eu_mem_rmw;
    logic        eu_mem_rmw_lookup;  // Phase 158 Stage 3
    logic        eu_an_wr_en;
    logic [2:0]  eu_an_wr_sel;
    logic [31:0] eu_an_wr_data;
    // CACR/CAAR from EU (wired to BIU instead of reset stubs)
    logic [31:0] eu_cacr_out, eu_caar_out;

    // ───────────────────────────────────────────────────────────────────────
    // BIU eu_req mux — priority: EXC > EU data > idle
    // EXC (exception frame push) takes over the EU bus port.
    // EU data cycles (MOVE to/from memory) use it when EXC is inactive.
    // ───────────────────────────────────────────────────────────────────────
    logic [31:0] biu_eu_addr, biu_eu_wdata;
    logic [2:0]  biu_eu_fc;
    logic        biu_eu_rw, biu_eu_req;
    logic [1:0]  biu_eu_siz;

    assign biu_eu_req   = exc_active ? exc_req_w   : eu_mem_req;
    assign biu_eu_addr  = exc_active ? exc_addr_w  : eu_mem_addr;
    assign biu_eu_wdata = exc_active ? exc_wdata_w : eu_mem_wdata;
    assign biu_eu_fc    = exc_active ? 3'b101      : eu_mem_fc;
    assign biu_eu_rw    = exc_active ? exc_rw_w    : eu_mem_rw;
    assign biu_eu_siz   = exc_active ? exc_siz_w   : eu_mem_siz;
    assign exc_ack_w    = eu_ack & exc_active;
    assign exc_rdata_w  = eu_rdata;

    // ───────────────────────────────────────────────────────────────────────
    // Branch signals from EU
    // ───────────────────────────────────────────────────────────────────────
    logic        eu_branch_taken;
    logic [31:0] eu_branch_target;

    // ───────────────────────────────────────────────────────────────────────
    // PC write mux — boot > exc > branch; exc and boot are mutually exclusive
    // ───────────────────────────────────────────────────────────────────────
    logic        pc_wr_en_common;
    logic [31:0] pc_wr_data_common;
    assign pc_wr_en_common   = boot_pulse | exc_new_pc_wr | eu_branch_taken;
    assign pc_wr_data_common = boot_pulse    ? init_pc           :
                               exc_new_pc_wr ? exc_new_pc        :
                                               eu_branch_target;

    // ───────────────────────────────────────────────────────────────────────
    // EU-side (data) bus error: sticky-to-pulse conversion.
    // exc_frame_valid (biu_exc_capture, via m68030_biu) is deliberately
    // latched "until reset" (BIU-090) so the frame's captured fault data
    // stays stable through the whole EXC_PUSH sequence — it stays high
    // forever after the very first fault, not just for one cycle, and never
    // returns to 0 for any later, independent fault (only reset clears it).
    // An edge-detector keyed off exc_frame_valid therefore only ever fires
    // ONCE, for the very first EU-side bus error the CPU ever takes in a
    // session — every subsequent, genuinely independent fault is silently
    // dropped (found via a test chaining many single-fault sources back to
    // back in one simulation; every earlier BERR-mid-* test had only ever
    // exercised exactly one fault per run, so this never surfaced before).
    // eu_berr (m68030_biu's own top-level output, sourced from
    // biu_cache_if's CI_BERR state) is the fix: unlike exc_frame_valid it's
    // a genuine one-cycle-wide pulse per fault — CI_BERR unconditionally
    // returns to CI_IDLE the very next cycle regardless of any other state,
    // so it naturally re-arms for each new, independent access. Latch
    // straight off its level (already exactly one cycle wide, so no
    // separate edge-detect is needed); still cleared on pc_wr_en_common,
    // the same pulse the exception controller issues once it finally loads
    // the handler PC — mirrors m68030_ifu.sv's own bus_err_r, which solves
    // the identical problem correctly via its own already-pulsed source.
    // ───────────────────────────────────────────────────────────────────────
    logic eu_bus_err_r;
    // Declared ahead of use (Icarus requires a net referenced in a
    // continuous-assignment port connection to be declared before that
    // point in the file) -- shared by u_exc's own bus_err_req input and
    // Phase 150 Stage 1's fault_pc mux below, both needing the identical
    // "is a bus error the thing dispatching right now" condition.
    wire bus_err_req_w = ifu_bus_err | eu_bus_err_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                      eu_bus_err_r <= 1'b0;
        else if (pc_wr_en_common)        eu_bus_err_r <= 1'b0;
        else if (eu_berr)                eu_bus_err_r <= 1'b1;
    end

    // ───────────────────────────────────────────────────────────────────────
    // SSP write mux — boot sets init_ssp; EXC updates after frame push
    // ───────────────────────────────────────────────────────────────────────
    logic        ssp_wr_en_mux;
    logic [31:0] ssp_wr_data_mux;
    assign ssp_wr_en_mux   = boot_pulse | exc_ssp_wr_en;
    assign ssp_wr_data_mux = boot_pulse ? init_ssp : exc_ssp_out;

    // EXC SSP input — active supervisor stack pointer (ISP when M=0, MSP when M=1)
    logic [31:0] exc_ssp_in;
    assign exc_ssp_in = eu_master_mode ? eu_msp_out : eu_isp_out;

    // ───────────────────────────────────────────────────────────────────────
    // MMU output wires
    // ───────────────────────────────────────────────────────────────────────
    logic [31:0] mmu_pa;
    logic        mmu_ack, mmu_fault_mmu, mmu_ci_mmu;
    logic        mmu_pflush_ack_w;
    logic        mmu_ptest_ack;
    logic [15:0] mmu_mmusr;
    logic        mmu_active;

    // EU ↔ MMU wires
    logic        eu_pflush_req_w, eu_pflush_all_w;
    logic [2:0]  eu_pflush_fc_w;
    logic [31:0] eu_pflush_va_w;
    logic        eu_ptest_req_w;
    logic [31:0] eu_ptest_va_w;
    logic [2:0]  eu_ptest_fc_w;
    logic        eu_pload_req_w;      // Phase 150 Stage 5
    logic [31:0] eu_pload_va_w;
    logic [2:0]  eu_pload_fc_w;
    logic        eu_pload_rw_w;
    logic        mmu_pload_ack_w;
    logic [31:0] eu_tc_w, eu_tt0_w, eu_tt1_w;
    logic [63:0] eu_crp_w, eu_srp_w;

    // BIU ↔ MMU translation port wires
    logic [31:0] biu_mmu_va_w;
    logic [2:0]  biu_mmu_fc_w;
    logic        biu_mmu_rw_w, biu_mmu_req_w;
    logic [31:0] biu_mmu_pa_w;
    logic        biu_mmu_done_w, biu_mmu_fault_w, biu_mmu_ci_w;
    logic        biu_mmu_is_ptest_w; // Phase 150 Stage 4

    // BIU ↔ MMU pflush port wires
    logic        biu_pflush_req_w, biu_pflush_all_w;
    logic [2:0]  biu_pflush_fc_w;
    logic [31:0] biu_pflush_va_w;
    logic        biu_pflush_ack_w;

    // ───────────────────────────────────────────────────────────────────────
    // m68030_ifu
    // ───────────────────────────────────────────────────────────────────────
    m68030_ifu u_ifu (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .pc_wr_en     (pc_wr_en_common),
        .pc_wr_data   (pc_wr_data_common),
        .drain        (seq_drain),
        .need_ext     (eu_need_ext_w),
        .instr_word   (ifu_instr_word),
        .ext_data     (ifu_ext_data),
        .q3_word      (ifu_q3_word),
        .ext34_data   (ifu_ext34_data),
        .q5_word      (ifu_q5_word),
        .instr_valid  (ifu_instr_valid),
        .ext1_valid   (ifu_ext1_valid),
        .ext_valid    (ifu_ext_valid),
        .ext4_valid   (ifu_ext4_valid),
        .ext5_valid   (ifu_ext5_valid),
        .ext6_valid   (ifu_ext6_valid),
        .decode_pc    (ifu_decode_pc),
        .ifu_addr     (ifu_bus_addr),
        .ifu_req      (ifu_bus_req),
        .ifu_rdata    (ifu_rdata),
        .ifu_ack      (ifu_ack),
        .ifu_berr     (ifu_berr),
        .supervisor   (eu_supervisor),
        .fc_out       (ifu_fc_out),
        .bus_err      (ifu_bus_err),
        .bus_err_addr (ifu_bus_err_addr),
        .addr_err     (ifu_addr_err_int),
        // open-items backlog Stage 13 (plan.md): live opcode substitution.
        .bkpt_subst_active (eu_bkpt_subst_active_w),
        .bkpt_subst_word   (eu_bkpt_subst_word_w)
    );

    // ───────────────────────────────────────────────────────────────────────
    // m68030_seq  (purely combinational)
    // ───────────────────────────────────────────────────────────────────────
    m68030_seq u_seq (
        .instr_word      (ifu_instr_word),
        .ifu_ext_data    (ifu_ext_data),
        .ifu_q3_word     (ifu_q3_word),
        .ifu_ext34_data  (ifu_ext34_data),
        .ifu_q5_word     (ifu_q5_word),
        .instr_valid     (ifu_instr_valid),
        .ifu_ext1_valid  (ifu_ext1_valid),
        .ifu_ext_valid   (ifu_ext_valid),
        .ifu_ext4_valid  (ifu_ext4_valid),
        .ifu_ext5_valid  (ifu_ext5_valid),
        .ifu_ext6_valid  (ifu_ext6_valid),
        .drain           (seq_drain),
        .eu_instr_word   (seq_eu_instr_word),
        .eu_ext_data     (seq_eu_ext_data),
        .eu_q3_word      (seq_eu_q3_word),
        .eu_ext34_data   (seq_eu_ext34_data),
        .eu_q5_word      (seq_eu_q5_word),
        .eu_instr_valid  (seq_eu_instr_valid),
        .eu_ext_valid    (seq_eu_ext_valid),
        .eu_instr_ack    (eu_instr_ack),
        .eu_busy         (eu_busy)
    );

    // ───────────────────────────────────────────────────────────────────────
    // m68030_eu
    // ───────────────────────────────────────────────────────────────────────
    m68030_eu u_eu (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .instr_word    (seq_eu_instr_word),
        .instr_valid   (seq_eu_instr_valid),
        .ext_data      (seq_eu_ext_data),
        .q3_word       (seq_eu_q3_word),
        .ext34_data    (seq_eu_ext34_data),
        .q5_word       (seq_eu_q5_word),
        .ext_valid     (seq_eu_ext_valid),
        .instr_ack     (eu_instr_ack),
        .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en_common),
        .pc_wr_data    (pc_wr_data_common),
        .pc_out        (eu_pc_out),
        .decode_pc     (ifu_decode_pc),
        .ex_decode_pc  (eu_ex_decode_pc),
        .branch_taken  (eu_branch_taken),
        .branch_target (eu_branch_target),
        .mem_req       (eu_mem_req),
        .mem_rw        (eu_mem_rw),
        .mem_siz       (eu_mem_siz),
        .mem_fc        (eu_mem_fc),
        .mem_addr      (eu_mem_addr),
        .mem_wdata     (eu_mem_wdata),
        .mem_rdata     (eu_ack && !exc_active ? eu_rdata : 32'h0),
        .mem_ack       (eu_ack && !exc_active),
        .mem_berr      (eu_berr && !exc_active),
        .mem_rmw       (eu_mem_rmw),
        .mem_rmw_lookup (eu_mem_rmw_lookup),
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .eu_bkpt_req         (eu_bkpt_req),
        .eu_bkpt_rw          (eu_bkpt_rw),
        .eu_bkpt_siz         (eu_bkpt_siz),
        .eu_bkpt_fc          (eu_bkpt_fc),
        .eu_bkpt_addr        (eu_bkpt_addr),
        .eu_bkpt_wdata       (eu_bkpt_wdata),
        .eu_bkpt_rdata       (eu_bkpt_rdata),
        .eu_bkpt_ack         (eu_bkpt_ack),
        .eu_bkpt_berr        (eu_bkpt_berr),
        .eu_bkpt_illegal_req (eu_bkpt_illegal_req_w),
        .eu_bkpt_subst_active (eu_bkpt_subst_active_w),
        .eu_bkpt_subst_word   (eu_bkpt_subst_word_w),
        // MMU instruction interface
        .eu_pflush_req   (eu_pflush_req_w),
        .eu_pflush_all   (eu_pflush_all_w),
        .eu_pflush_fc    (eu_pflush_fc_w),
        .eu_pflush_va    (eu_pflush_va_w),
        .eu_pflush_ack   (mmu_pflush_ack_w),
        .eu_ptest_req    (eu_ptest_req_w),
        .eu_ptest_va     (eu_ptest_va_w),
        .eu_ptest_fc     (eu_ptest_fc_w),
        .eu_ptest_ack    (mmu_ptest_ack),
        .eu_ptest_mmusr  (mmu_mmusr),
        .eu_pload_req    (eu_pload_req_w),
        .eu_pload_va     (eu_pload_va_w),
        .eu_pload_fc     (eu_pload_fc_w),
        .eu_pload_rw     (eu_pload_rw_w),
        .eu_pload_ack    (mmu_pload_ack_w),
        .eu_pload_mmusr  (mmu_mmusr),
        .tc_out          (eu_tc_w),
        .tt0_out         (eu_tt0_w),
        .tt1_out         (eu_tt1_w),
        .crp_out         (eu_crp_w),
        .srp_out         (eu_srp_w),
        .an_wr_en      (eu_an_wr_en),
        .an_wr_sel     (eu_an_wr_sel),
        .an_wr_data    (eu_an_wr_data),
        .vbr_wr_en     (1'b0),
        .vbr_wr_data   (32'h0),
        .vbr_out       (eu_vbr_out),
        .usp_out       (eu_usp_out),
        .msp_out       (eu_msp_out),
        .isp_out       (eu_isp_out),
        .cacr_out      (eu_cacr_out),
        .caar_out      (eu_caar_out),
        .sr_out        (eu_sr_out),
        .supervisor    (eu_supervisor),
        .master_mode   (eu_master_mode),
        .ipl_mask      (eu_ipl_mask),
        .int_pending   (exc_int_pending_w),
        .eu_int_ready  (eu_int_ready_w),
        .exc_active    (exc_active),
        .div_trap      (eu_div_trap),
        .chk_trap      (eu_chk_trap),
        .eu_need_ext   (eu_need_ext_w),
        .eu_trap_req   (eu_trap_req_w),
        .eu_trap_num   (eu_trap_num_w),
        .eu_trapv_req  (eu_trapv_req_w),
        .eu_illegal_req(eu_illegal_req_w),
        .eu_stop       (eu_stop),
        .eu_reset_req  (),              // wired to BIU RSTOUT via eu_reset_req
        .eu_priv_req    (eu_priv_req_w),
        .eu_trace_req   (eu_trace_req_w),
        .eu_linea_req   (eu_linea_req_w),
        .eu_linef_req   (eu_linef_req_w),
        .eu_fmt_err_req (eu_fmt_err_req_w),
        .ssp_wr_en     (ssp_wr_en_mux),
        .ssp_wr_data   (ssp_wr_data_mux),
        .exc_sr_wr_en  (exc_new_sr_wr),
        .exc_sr_wr_data(exc_new_sr)
    );

    // ───────────────────────────────────────────────────────────────────────
    // m68030_exc
    // ───────────────────────────────────────────────────────────────────────
    m68030_exc u_exc (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        // Exception sources
        .bus_err_req  (bus_err_req_w),
        .addr_err_req (ifu_addr_err_int),
        .ipl_sync     (ipl_sync),
        .ipl_mask     (eu_ipl_mask),
        .int_pending_out(exc_int_pending_w),
        .int_ready    (eu_int_ready_w),
        .illegal_req  (eu_illegal_req_w | eu_bkpt_illegal_req_w),
        .priv_req     (eu_priv_req_w),
        .trace_req    (eu_trace_req_w),
        .linea_req    (eu_linea_req_w),
        .linef_req    (eu_linef_req_w),
        .fmt_err_req  (eu_fmt_err_req_w),
        .div_zero_req (eu_div_trap),
        .chk_req      (eu_chk_trap),
        .trapv_req    (eu_trapv_req_w),
        .trap_req     (eu_trap_req_w),
        .trap_num     (eu_trap_num_w),
        // Fault snapshot
        // Phase 150 Stage 1 (plan.md): fault_pc is muxed by exception type,
        // not a single blanket source. bus_err_req_w (a mid-instruction
        // fault detected well after decode may have legitimately raced
        // ahead to the next instruction) needs eu_ex_decode_pc, the PC of
        // whatever instruction is/was actually in EX -- see eu_seq.sv's own
        // ex_decode_pc_out comment; confirmed via a Stage 1 investigation
        // probe (a real MMU translation fault on MOVE.L's own data read)
        // that raw ifu_decode_pc pointed 2 bytes past the true faulting
        // instruction. Every OTHER exception source (interrupts, internal
        // exceptions) keeps the original ifu_decode_pc -- a first attempt
        // that switched ALL sources to eu_ex_decode_pc broke
        // INT-mid-MOVEM (tb/stall_fsm_tb.sv): an interrupt's own correct
        // resume address is "the next instruction about to decode" (real
        // 68030 semantics -- interrupts only ever fire at instruction
        // boundaries, held off by eu_int_ready_w until the boundary is
        // reached), which IS ifu_decode_pc; eu_ex_decode_pc would instead
        // point at whatever instruction had *just* finished (e.g. the FSM
        // that just retired), making RTE silently re-execute it.
        .fault_pc     (bus_err_req_w ? eu_ex_decode_pc : ifu_decode_pc),
        .fault_sr     (eu_sr_out),
        .fault_addr   (ifu_bus_err ? ifu_bus_err_addr : fault_addr_biu),
        .fault_ssw    (exc_ssw),
        .bus_err_fmt  (exc_frame_format),   // format code from biu_exc_capture
        .fault_data   (fault_data_biu),     // DOB from biu at fault time
        // SSP
        .ssp_in       (exc_ssp_in),
        .ssp_out      (exc_ssp_out),
        .ssp_wr_en    (exc_ssp_wr_en),
        // VBR
        .vbr_in       (eu_vbr_out),
        // Bus interface
        .exc_addr     (exc_addr_w),
        .exc_wdata    (exc_wdata_w),
        .exc_rw       (exc_rw_w),
        .exc_siz      (exc_siz_w),
        .exc_req      (exc_req_w),
        .exc_ack      (exc_ack_w),
        .exc_rdata    (exc_rdata_w),
        // Outputs to EU
        .new_pc       (exc_new_pc),
        .new_pc_wr    (exc_new_pc_wr),
        .new_sr       (exc_new_sr),
        .new_sr_wr    (exc_new_sr_wr),
        .exc_active   (exc_active),
        .exc_vector_num(exc_vector_num)
    );

    // ───────────────────────────────────────────────────────────────────────
    // m68030_mmu
    // ───────────────────────────────────────────────────────────────────────
    m68030_mmu u_mmu (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .tc             (eu_tc_w),           // TC register from EU
        // EU virtual address for MMU translation
        .va_in          (32'h0),
        .fc_in          (3'b0),
        .rw_in          (1'b1),
        .req_in         (1'b0),
        .pa_out         (mmu_pa),
        .ack_out        (mmu_ack),
        .fault_out      (mmu_fault_mmu),
        .ci_out         (mmu_ci_mmu),
        // EU PFLUSH
        .pflush_req     (eu_pflush_req_w),
        .pflush_all     (eu_pflush_all_w),
        .pflush_fc      (eu_pflush_fc_w),
        .pflush_va      (eu_pflush_va_w),
        .pflush_ack     (mmu_pflush_ack_w),
        // EU PTEST
        .ptest_req      (eu_ptest_req_w),
        .ptest_va       (eu_ptest_va_w),
        .ptest_fc       (eu_ptest_fc_w),
        .mmusr_out      (mmu_mmusr),
        .ptest_ack      (mmu_ptest_ack),
        // EU PLOAD (Phase 150 Stage 5)
        .pload_req      (eu_pload_req_w),
        .pload_va       (eu_pload_va_w),
        .pload_fc       (eu_pload_fc_w),
        .pload_rw       (eu_pload_rw_w),
        .pload_ack      (mmu_pload_ack_w),
        // BIU translation port
        .biu_va         (biu_mmu_va_w),
        .biu_fc         (biu_mmu_fc_w),
        .biu_rw         (biu_mmu_rw_w),
        .biu_req        (biu_mmu_req_w),
        .biu_is_ptest   (biu_mmu_is_ptest_w), // Phase 150 Stage 4
        .biu_mmusr      (mmusr),              // Phase 150 Stage 4
        .biu_pa         (biu_mmu_pa_w),
        .biu_done       (biu_mmu_done_w),
        .biu_fault      (biu_mmu_fault_w),
        .biu_ci         (biu_mmu_ci_w),
        // BIU pflush port
        .biu_pflush_req (biu_pflush_req_w),
        .biu_pflush_all (biu_pflush_all_w),
        .biu_pflush_fc  (biu_pflush_fc_w),
        .biu_pflush_va  (biu_pflush_va_w),
        .biu_pflush_ack (biu_pflush_ack_w),
        .mmu_active     (mmu_active)
    );

    // ───────────────────────────────────────────────────────────────────────
    // m68030_biu
    // ───────────────────────────────────────────────────────────────────────
    m68030_biu #(
        .RSTOUT_CLKS       (124),
        .TIMEOUT_CLKS      (128),
        .POWERON_RSTO_CLKS (POWERON_RSTO_CLKS)
    ) u_biu (
        .clk_4x          (clk_4x),
        .rst_n           (rst_n),
        // External pins
        .ext_a           (ext_a),
        .ext_d_out       (ext_d_out),
        .ext_d_oe        (ext_d_oe),
        .ext_d_in        (ext_d_in),
        .ext_as_n        (ext_as_n),
        .ext_ds_n        (ext_ds_n),
        .ext_rw          (ext_rw),
        .ext_fc          (ext_fc),
        .ext_siz         (ext_siz),
        .ext_ecs_n       (ext_ecs_n),
        .ext_ocs_n       (ext_ocs_n),
        .ext_rstout_n    (ext_rstout_n),
        .ext_cbreq_n     (ext_cbreq_n),
        .ext_e           (ext_e),
        .ext_bg_n        (ext_bg_n),
        // Async inputs
        .dsack0_n        (dsack0_n),
        .dsack1_n        (dsack1_n),
        .sterm_n         (sterm_n),
        .berr_n          (berr_n),
        .halt_n          (halt_n),
        .avec_n          (avec_n),
        .vpa_n           (vpa_n),
        .ipl_n           (ipl_n),
        .br_n            (br_n),
        .bgack_n         (bgack_n),
        .cback_n         (cback_n),
        .ciin_n          (ciin_n),    // Phase 158 Stage 7
        .ciout_n         (ciout_n),
        // EU normal data interface (EXC mux)
        .eu_addr         (biu_eu_addr),
        .eu_wdata        (biu_eu_wdata),
        .eu_rdata        (eu_rdata),
        .eu_fc           (biu_eu_fc),
        .eu_rw           (biu_eu_rw),
        .eu_siz          (biu_eu_siz),
        .eu_is_operand   (exc_active),
        .eu_req          (biu_eu_req),
        .eu_ack          (eu_ack),
        .eu_berr         (eu_berr),
        .eu_retry        (eu_retry),
        .mem_rmw_lookup  (eu_mem_rmw_lookup),  // Phase 158 Stage 3
        // IACK (stub)
        .eu_iack_req     (1'b0),
        .eu_iack_level   (3'b0),
        .eu_iack_vec     (eu_iack_vec),
        .eu_iack_avec    (eu_iack_avec),
        .eu_iack_ack     (eu_iack_ack),
        // RST (stub)
        .eu_rst_req      (1'b0),
        // RMW
        .eu_rmw          (eu_mem_rmw),
        .bus_lock        (bus_lock),
        // CAS2 (stub)
        .eu_cas2_req     (1'b0),
        .eu_cas2_addr1   (32'h0),
        .eu_cas2_addr2   (32'h0),
        .eu_cas2_fc      (3'b0),
        .eu_cas2_siz     (2'b0),
        .eu_cas2_wdata1  (32'h0),
        .eu_cas2_wdata2  (32'h0),
        .eu_cas2_do_write1(1'b0),
        .eu_cas2_do_write2(1'b0),
        .eu_cas2_rdata1  (eu_cas2_rdata1),
        .eu_cas2_rdata2  (eu_cas2_rdata2),
        .eu_cas2_ack     (eu_cas2_ack),
        // Burst (stub)
        .eu_burst_req    (1'b0),
        .eu_burst_addr   (32'h0),
        .eu_burst_fc     (3'b0),
        .eu_burst_rdata0 (eu_burst_rdata0),
        .eu_burst_rdata1 (eu_burst_rdata1),
        .eu_burst_rdata2 (eu_burst_rdata2),
        .eu_burst_rdata3 (eu_burst_rdata3),
        .eu_burst_ack    (eu_burst_ack),
        .eu_burst_berr   (eu_burst_berr),
        // MOVE16 (stub)
        .eu_m16_req      (1'b0),
        .eu_m16_addr     (32'h0),
        .eu_m16_fc       (3'b0),
        .eu_m16_wdata0   (32'h0),
        .eu_m16_wdata1   (32'h0),
        .eu_m16_wdata2   (32'h0),
        .eu_m16_wdata3   (32'h0),
        .eu_m16_ack      (eu_m16_ack),
        .eu_m16_berr     (eu_m16_berr),
        // Coprocessor (stub)
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        // BKPT breakpoint-acknowledge (Phase 157 Stage 3)
        .eu_bkpt_req     (eu_bkpt_req),
        .eu_bkpt_rw      (eu_bkpt_rw),
        .eu_bkpt_addr    (eu_bkpt_addr),
        .eu_bkpt_fc      (eu_bkpt_fc),
        .eu_bkpt_siz     (eu_bkpt_siz),
        .eu_bkpt_wdata   (eu_bkpt_wdata),
        .eu_bkpt_rdata   (eu_bkpt_rdata),
        .eu_bkpt_ack     (eu_bkpt_ack),
        .eu_bkpt_berr    (eu_bkpt_berr),
        // Address error outputs
        .eu_addr_err     (eu_addr_err),
        .ifu_addr_err    (ifu_addr_err),
        // MOVEM/MOVEP multi-op (stub)
        .eu_mo_req       (1'b0),
        .eu_mo_start_addr(32'h0),
        .eu_mo_fc        (3'b0),
        .eu_mo_siz       (2'b0),
        .eu_mo_rw        (1'b1),
        .eu_mo_count     (3'b0),
        .eu_mo_stride    (3'b0),
        .eu_mo_wdata0    (32'h0),
        .eu_mo_wdata1    (32'h0),
        .eu_mo_wdata2    (32'h0),
        .eu_mo_wdata3    (32'h0),
        .eu_mo_rdata0    (eu_mo_rdata0),
        .eu_mo_rdata1    (eu_mo_rdata1),
        .eu_mo_rdata2    (eu_mo_rdata2),
        .eu_mo_rdata3    (eu_mo_rdata3),
        .eu_mo_ack       (eu_mo_ack),
        .eu_mo_berr      (eu_mo_berr),
        // IFU
        .ifu_addr        (ifu_bus_addr),
        .ifu_req         (ifu_bus_req),
        .ifu_rdata       (ifu_rdata),
        .ifu_ack         (ifu_ack),
        .ifu_berr        (ifu_berr),
        // open-items backlog Stage 8 (plan.md): live S-bit for
        // instruction-fetch FC (010 user / 110 supervisor program space)
        .s_bit           (eu_sr_out[13]),
        // Control registers (MMU/cache disabled)
        .cacr            (eu_cacr_out),
        .caar            (eu_caar_out),
        .tc              (eu_tc_w),       // TC register from EU
        .crp             (eu_crp_w),      // CRP from EU PMOVE
        .srp             (eu_srp_w),
        .tt0             (eu_tt0_w),      // TT0 register from EU
        .tt1             (eu_tt1_w),      // TT1 register from EU
        // Status outputs
        .bus_idle        (bus_idle),
        .bus_halted      (bus_halted),
        .init_done       (init_done),
        .init_ssp        (init_ssp),
        .init_pc         (init_pc),
        .phase           (phase),
        .s_state         (s_state),
        .fault_addr      (fault_addr_biu),
        .fault_data      (fault_data_biu),
        .fault_fc        (fault_fc_biu),
        .fault_rw        (fault_rw_biu),
        .fault_siz       (fault_siz_biu),
        .fault_valid     (fault_valid_biu),
        .fault_retry     (fault_retry_biu),
        .fault_is_rmw    (fault_is_rmw_biu),
        .retry_pending   (retry_pending),
        .halt_out        (halt_out),
        .exc_frame_format(exc_frame_format),
        .exc_frame_valid (exc_frame_valid),
        .exc_ssw         (exc_ssw),
        .mmu_fault       (biu_mmu_fault_w),
        .mmu_ci          (biu_mmu_ci_w),
        .mmusr           (mmusr),
        // External MMU translation port
        .mmu_va_ext      (biu_mmu_va_w),
        .mmu_fc_ext      (biu_mmu_fc_w),
        .mmu_rw_ext      (biu_mmu_rw_w),
        .mmu_req_ext     (biu_mmu_req_w),
        .mmu_is_ptest_ext(biu_mmu_is_ptest_w), // Phase 150 Stage 4
        .mmu_pa_ext      (biu_mmu_pa_w),
        .mmu_done_ext    (biu_mmu_done_w),
        // External PFLUSH port
        .mmu_pflush_req  (biu_pflush_req_w),
        .mmu_pflush_all  (biu_pflush_all_w),
        .mmu_pflush_fc   (biu_pflush_fc_w),
        .mmu_pflush_va   (biu_pflush_va_w),
        .mmu_pflush_ack  (biu_pflush_ack_w)
    );

endmodule

`default_nettype wire

`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P top, REAL-BUS configuration: the pipelined CPU driving rtl/'s own
// verified m68030_biu. This is plan A4 -- the "protocol-exact, timing-free"
// contract -- made concrete, and with it the 68030's genuine 256-byte I- and
// D-caches (Tier 2 reuse, plan P6).
//
// WHAT A4 ACTUALLY SAYS, and what is therefore true here:
//
//   * The BIU is REUSED, not rewritten. Every S-state, every pin transition,
//     the AS/DS stagger, SIZ/FC, the DSACK handshake, RMC#, burst continuity --
//     all exactly as MC68030UM.pdf specifies, because it is the same RTL that
//     was verified against the manual over ~280 phases.
//   * What changes is the EU-FACING PORT. eu_new_dispatch and the whole
//     preview_ok zero-gap mechanism are GONE: this core drives eu_addr/eu_rw/
//     eu_siz/eu_wdata/eu_req from flip-flops and consumes eu_ack into one.
//     eu_new_dispatch is therefore tied low -- the honest value, since this
//     core never has a hazard-checked next address a cycle early.
//   * THE SIGNED-OFF CONSEQUENCE: consecutive bus cycles may be separated by
//     one or more idle clk_4x ticks where rtl/ had none. WITHIN a cycle nothing
//     differs. This is the one deliberate divergence from MH030, and it is the
//     reason the caches are not optional here: a real bus access costs ~16
//     ticks against the abstract bus's ~3.8, so without the caches a real-bus
//     rtlp is slower than rtl/ is WITH them. The caches pay for the BIU.
//
// WHY THE CACHES ARE REACHABLE AT ALL. cacr comes from the core's own MOVEC
// register, so software enables them exactly as it does on rtl/ -- and the
// 68030 resets with both OFF, so a program that never writes CACR gets no
// caches, here as on real silicon.
//
// TWO RESET-VECTOR FETCHES, DELIBERATELY NOT MERGED. The BIU runs its own
// SSP/PC init sequence out of reset (biu_cycle_gen's ST_INIT_SSP_*/ST_INIT_PC_*
// states) and so does the core (mh030p_core.sv's rst_state machine), so boot
// reads addresses 0 and 4 twice. The BIU holds eu_req off until its own pair
// completes, so the two never collide, and the core's own pair is the one that
// actually loads A7 and the PC. Consuming init_ssp/init_pc instead would need a
// boot write port into the register file for a saving of two bus cycles, once,
// at reset. It is recorded here rather than silently left as a puzzle.
//
// STUBBED BIU PORTS. Everything the core cannot yet ask for is tied off the
// same way rtl/m68030_top.sv ties off what IT cannot: CAS2, burst-from-EU,
// MOVE16 (not a real 68030 instruction), MOVEM/MOVEP multi-op, coprocessor,
// BKPT and IACK. The core sequences MOVEM and MOVEP as ordinary accesses from
// its own FSMs rather than through biu_multiop_fsm, and it autovectors
// interrupts internally rather than running a real IACK cycle -- both genuine
// gaps against rtl/, listed in plan.md, not hidden here.
// =============================================================================

module mh030p_biu_top #(
    parameter int POWERON_RSTO_CLKS = 2048   // 4x clocks; pass-through to the BIU
) (
    input  wire        clk_4x,
    input  wire        rst_n,

    // ── External chip pins (pass-through to m68030_biu) ─────────────────────
    output wire [31:0] ext_a,
    output wire [31:0] ext_d_out,
    output wire        ext_d_oe,
    input  wire [31:0] ext_d_in,
    output wire        ext_as_n,
    output wire        ext_ds_n,
    output wire        ext_rw,
    output wire [2:0]  ext_fc,
    output wire [1:0]  ext_siz,
    output wire        ext_ecs_n,
    output wire        ext_ocs_n,
    output wire        ext_rstout_n,
    output wire        ext_cbreq_n,
    output wire        ext_bg_n,
    output wire        ext_rmc_n,
    output wire        ext_dben_n,
    output wire        ciout_n,

    input  wire        dsack0_n,
    input  wire        dsack1_n,
    input  wire        sterm_n,
    input  wire        berr_n,
    input  wire        halt_n,
    input  wire        avec_n,
    input  wire [2:0]  ipl_n,
    input  wire        br_n,
    input  wire        bgack_n,
    input  wire        cback_n,
    input  wire        ciin_n,
    input  wire        cdis_n,
    input  wire        mmudis_n,

    output wire        bus_halted,
    output wire        status_n,

    // ── Architectural state, exposed for the testbench ──────────────────────
    output wire        wb_wr_en,
    output wire [3:0]  wb_wr_sel,
    output wire [31:0] wb_wr_data,
    output wire        stopped,
    output wire [7:0]  ccr_out
);

    // ── CPU side ───────────────────────────────────────────────────────────
    wire        if_req,  mem_req, mem_rw, mem_lock;
    wire [31:0] if_addr, mem_addr, mem_wdata;
    wire [1:0]  mem_siz;
    wire [31:0] if_rdata, mem_rdata;
    wire        if_ack,  mem_ack;
    wire [31:0] if_pc;
    wire [7:0]  sr_sys;
    wire [31:0] cacr;

    // Real silicon presents IPL on three ACTIVE-LOW pins; the core takes the
    // level already encoded, exactly as it does in the abstract configuration.
    wire [2:0] ipl = ~ipl_n;

    mh030p_cpu u_cpu (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .if_req(if_req), .if_addr(if_addr),
        .if_rdata(if_rdata), .if_ack(if_ack),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_lock(mem_lock),
        .ipl(ipl),
        .sr_sys(sr_sys), .cacr(cacr),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .stopped(stopped), .ccr_out(ccr_out),
        .if_pc(if_pc)
    );

    // ── The A4 adaptation, in full ─────────────────────────────────────────
    // Three genuine conversions between the core's abstract port and the BIU's,
    // and nothing else. Each one is a real difference, not tidying.

    // 1. FUNCTION CODE. The core does not produce one -- it has no need of a
    //    concept of address space. The BIU does, for the cache tags, the MMU
    //    and the FC pins. S is SR bit 13, which is sr_sys[5] here.
    wire supervisor = sr_sys[5];
    wire [2:0] eu_fc = supervisor ? 3'b101 : 3'b001;   // supervisor/user DATA

    // 2. WRITE-DATA JUSTIFICATION. The core right-justifies write data (byte in
    //    [7:0], word in [15:0]), which is what its abstract memory models
    //    consume. biu_byte_lane_ctrl.sv expects the OPPOSITE -- its header says
    //    so outright: "byte in wdata_in[31:24], word in wdata_in[31:16]". Get
    //    this wrong and every byte write lands the wrong value on the right
    //    address, which is exactly the shape of bug Phase 283 chased from the
    //    other direction. Reads need no conversion: biu_sizing_fsm's
    //    merge_rdata() already returns them right-justified, the convention the
    //    core and rtl/eu_seq_execute.svh both already expect.
    wire [31:0] eu_wdata = (mem_siz == UZ_BYTE) ? {mem_wdata[7:0],  24'h0}
                         : (mem_siz == UZ_WORD) ? {mem_wdata[15:0], 16'h0}
                                                : mem_wdata;

    // 3. THE BUS LOCK. mem_lock is asserted for the whole of an indivisible
    //    operation, from its read's dispatch to its write's ack. It maps to
    //    eu_cas_hold, NOT to eu_rmw: eu_rmw makes biu_cycle_gen run its single
    //    combined 12-state RMW cycle, where the EU hands over read and write at
    //    once, and this core does not work that way -- it dispatches two
    //    ordinary transactions. eu_cas_hold is precisely the signal Phase
    //    241/242 added for that shape (silent-copper-latch.md): it feeds
    //    bus_lock and RMC# and gives the EU a sticky grant across the
    //    read-to-write gap, without changing the cycle type. The D-cache must
    //    also be forced to miss on the read half, which is mem_rmw_lookup's job
    //    (Phase 158 Stage 3) -- a locked read that hit in the cache would never
    //    reach the bus and the lock would mean nothing.
    wire eu_rmw_lookup = mem_lock && mem_rw;

    // Unused BIU outputs, named so the tie-off is visible rather than implied.
    wire [31:0] eu_rdata_w;
    wire        eu_ack_w, eu_berr_w, eu_retry_w;
    wire [7:0]  eu_iack_vec_w;
    wire        eu_iack_avec_w, eu_iack_ack_w, eu_iack_berr_w;
    wire        bus_lock_w;
    wire [31:0] eu_cas2_rdata1_w, eu_cas2_rdata2_w;
    wire        eu_cas2_ack_w;
    wire [31:0] eu_burst_rdata0_w, eu_burst_rdata1_w;
    wire [31:0] eu_burst_rdata2_w, eu_burst_rdata3_w;
    wire        eu_burst_ack_w, eu_burst_berr_w;
    wire        eu_m16_ack_w, eu_m16_berr_w;
    wire [31:0] eu_coproc_rdata_w;
    wire        eu_coproc_ack_w, eu_coproc_berr_w;
    wire [31:0] eu_bkpt_rdata_w;
    wire        eu_bkpt_ack_w, eu_bkpt_berr_w;
    wire        eu_addr_err_w, ifu_addr_err_w;
    wire [31:0] eu_mo_rdata0_w, eu_mo_rdata1_w;
    wire [31:0] eu_mo_rdata2_w, eu_mo_rdata3_w;
    wire        eu_mo_ack_w, eu_mo_berr_w;
    wire        ifu_berr_w;
    wire        ifu_ack_raw;
    wire        bus_idle_w, init_done_w;
    wire [31:0] init_ssp_w, init_pc_w;
    wire [1:0]  phase_w;
    wire [6:0]  s_state_w;
    wire [31:0] fault_addr_w, fault_data_w;
    wire [2:0]  fault_fc_w;
    wire        fault_rw_w;
    wire [1:0]  fault_siz_w;
    wire        fault_valid_w, fault_retry_w, fault_is_rmw_w;
    wire        retry_pending_w, retry_exhausted_w;
    wire [3:0]  exc_frame_format_w;
    wire        exc_frame_valid_w;
    wire [15:0] exc_ssw_w;
    wire        mmu_fault_w, mmu_ci_w;
    wire [15:0] mmusr_w;
    wire [31:0] mmu_pa_ext_w;
    wire        mmu_done_ext_w, mmu_pflush_ack_w;

    // 4. ACK WIDTH. This is the fourth genuine conversion, and the one that is
    //    invisible until it bites. biu_cycle_gen holds its acknowledgement high
    //    for ALL FOUR clk_4x ticks of S7 -- rtl/m68030_ifu.sv:475 says so
    //    outright ("biu_cycle_gen holds ifu_ack high for all 4 ticks of S7") and
    //    guards itself with fetch_pend_r accordingly. This core's port is
    //    specified with a SINGLE-TICK ack, which is what mh030p_arb.sv delivers,
    //    so a level ack is consumed four times: the fetch unit enqueued the same
    //    longword repeatedly and advanced its PC by 4 each time, stepping the
    //    instruction stream in strides of 8 or 16 bytes and skipping code. The
    //    data side misbehaved the same way.
    //
    //    The conversion belongs HERE and not in the core: the single-tick ack is
    //    the abstract configuration's verified contract, and widening the core to
    //    tolerate a level ack would change the arm that passes the full Harte
    //    corpus in order to accommodate this one. A rising-edge detect keeps the
    //    change entirely inside the adapter, which is what the adapter is for.
    //
    //    Holding the request through the remaining ack ticks is safe and is what
    //    rtl/m68030_ifu.sv does too -- it deasserts one cycle AFTER the ack.
    reg eu_ack_seen_r, ifu_ack_seen_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            eu_ack_seen_r  <= 1'b0;
            ifu_ack_seen_r <= 1'b0;
        end else begin
            eu_ack_seen_r  <= eu_ack_w;
            ifu_ack_seen_r <= ifu_ack_raw;
        end
    end

    assign mem_rdata = eu_rdata_w;
    assign mem_ack   = eu_ack_w    && !eu_ack_seen_r;
    assign if_ack    = ifu_ack_raw && !ifu_ack_seen_r;

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
        .ext_bg_n        (ext_bg_n),
        .ext_rmc_n       (ext_rmc_n),
        .ext_dben_n      (ext_dben_n),
        // Async inputs
        .dsack0_n        (dsack0_n),
        .dsack1_n        (dsack1_n),
        .sterm_n         (sterm_n),
        .berr_n          (berr_n),
        .halt_n          (halt_n),
        .avec_n          (avec_n),
        .ipl_n           (ipl_n),
        .br_n            (br_n),
        .bgack_n         (bgack_n),
        .cback_n         (cback_n),
        .ciin_n          (ciin_n),
        .ciout_n         (ciout_n),
        .cdis_n          (cdis_n),
        .mmudis_n        (mmudis_n),
        // ── The A4 port ────────────────────────────────────────────────────
        .eu_addr         (mem_addr),
        .eu_wdata        (eu_wdata),
        .eu_rdata        (eu_rdata_w),
        .eu_fc           (eu_fc),
        .eu_rw           (mem_rw),
        .eu_siz          (mem_siz),
        // Every data access this core makes IS an operand transfer -- it has no
        // other kind -- so OCS asserts on all of them.
        .eu_is_operand   (1'b1),
        .eu_req          (mem_req),
        // THE A4 DELETION. See the header: there is no preview mechanism to
        // report, and claiming one would tell the BIU to trust an address that
        // is not yet valid.
        .eu_new_dispatch (1'b0),
        .eu_ack          (eu_ack_w),
        .eu_berr         (eu_berr_w),
        .eu_retry        (eu_retry_w),
        .mem_rmw_lookup  (eu_rmw_lookup),
        // IACK: this core autovectors internally, so no real IACK cycle runs.
        .eu_iack_req     (1'b0),
        .eu_iack_level   (3'b0),
        .eu_iack_vec     (eu_iack_vec_w),
        .eu_iack_avec    (eu_iack_avec_w),
        .eu_iack_ack     (eu_iack_ack_w),
        .eu_iack_berr    (eu_iack_berr_w),
        .eu_rst_req      (1'b0),
        // Bus lock -- see conversion 3 in the header.
        .eu_rmw          (1'b0),
        .eu_is_cas       (mem_lock),
        .eu_cas_hold     (mem_lock),
        .bus_lock        (bus_lock_w),
        // CAS2 (stub -- this core sequences it from its own FSM)
        .eu_cas2_req     (1'b0),
        .eu_cas2_addr1   (32'h0),
        .eu_cas2_addr2   (32'h0),
        .eu_cas2_fc      (3'b0),
        .eu_cas2_siz     (2'b0),
        .eu_cas2_wdata1  (32'h0),
        .eu_cas2_wdata2  (32'h0),
        .eu_cas2_do_write1(1'b0),
        .eu_cas2_do_write2(1'b0),
        .eu_cas2_rdata1  (eu_cas2_rdata1_w),
        .eu_cas2_rdata2  (eu_cas2_rdata2_w),
        .eu_cas2_ack     (eu_cas2_ack_w),
        // EU-initiated burst (stub; the CACHES still burst -- their own
        // dc_burst_req/ic_burst_req paths are internal to the BIU)
        .eu_burst_req    (1'b0),
        .eu_burst_addr   (32'h0),
        .eu_burst_fc     (3'b0),
        .eu_burst_rdata0 (eu_burst_rdata0_w),
        .eu_burst_rdata1 (eu_burst_rdata1_w),
        .eu_burst_rdata2 (eu_burst_rdata2_w),
        .eu_burst_rdata3 (eu_burst_rdata3_w),
        .eu_burst_ack    (eu_burst_ack_w),
        .eu_burst_berr   (eu_burst_berr_w),
        // MOVE16: not a real MC68030 instruction (Phase 250 F8). Permanent stub.
        .eu_m16_req      (1'b0),
        .eu_m16_addr     (32'h0),
        .eu_m16_fc       (3'b0),
        .eu_m16_wdata0   (32'h0),
        .eu_m16_wdata1   (32'h0),
        .eu_m16_wdata2   (32'h0),
        .eu_m16_wdata3   (32'h0),
        .eu_m16_ack      (eu_m16_ack_w),
        .eu_m16_berr     (eu_m16_berr_w),
        // Coprocessor (stub -- UC_COPROC is not executable in this core)
        .eu_coproc_req   (1'b0),
        .eu_coproc_rw    (1'b1),
        .eu_coproc_addr  (32'h0),
        .eu_coproc_fc    (3'b0),
        .eu_coproc_siz   (2'b0),
        .eu_coproc_wdata (32'h0),
        .eu_coproc_rdata (eu_coproc_rdata_w),
        .eu_coproc_ack   (eu_coproc_ack_w),
        .eu_coproc_berr  (eu_coproc_berr_w),
        // BKPT (stub)
        .eu_bkpt_req     (1'b0),
        .eu_bkpt_rw      (1'b1),
        .eu_bkpt_addr    (32'h0),
        .eu_bkpt_fc      (3'b0),
        .eu_bkpt_siz     (2'b0),
        .eu_bkpt_wdata   (32'h0),
        .eu_bkpt_rdata   (eu_bkpt_rdata_w),
        .eu_bkpt_ack     (eu_bkpt_ack_w),
        .eu_bkpt_berr    (eu_bkpt_berr_w),
        .eu_addr_err     (eu_addr_err_w),
        .ifu_addr_err    (ifu_addr_err_w),
        // MOVEM/MOVEP multi-op (stub -- both are sequenced as ordinary
        // accesses by the core's own FSMs, not through biu_multiop_fsm)
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
        .eu_mo_rdata0    (eu_mo_rdata0_w),
        .eu_mo_rdata1    (eu_mo_rdata1_w),
        .eu_mo_rdata2    (eu_mo_rdata2_w),
        .eu_mo_rdata3    (eu_mo_rdata3_w),
        .eu_mo_ack       (eu_mo_ack_w),
        .eu_mo_berr      (eu_mo_berr_w),
        // ── Instruction fetch, through the real I-cache ────────────────────
        .ifu_addr        (if_addr),
        .ifu_req         (if_req),
        .ifu_rdata       (if_rdata),
        .ifu_ack         (ifu_ack_raw),
        .ifu_berr        (ifu_berr_w),
        .s_bit           (supervisor),
        // ── Control registers ──────────────────────────────────────────────
        // CACR is real: it is the core's own MOVEC register, so software turns
        // the caches on here exactly as it does on rtl/. The MMU registers are
        // zero -- TC=0 means translation disabled, which is what this core
        // needs since UC_MMU is not executable.
        .cacr            (cacr),
        .caar            (32'h0),
        .tc              (32'h0),
        .crp             (64'h0),
        .srp             (64'h0),
        .tt0             (32'h0),
        .tt1             (32'h0),
        // ── Status and fault outputs ───────────────────────────────────────
        .bus_idle        (bus_idle_w),
        .bus_halted      (bus_halted),
        .init_done       (init_done_w),
        .init_ssp        (init_ssp_w),
        .init_pc         (init_pc_w),
        .phase           (phase_w),
        .s_state         (s_state_w),
        .fault_addr      (fault_addr_w),
        .fault_data      (fault_data_w),
        .fault_fc        (fault_fc_w),
        .fault_rw        (fault_rw_w),
        .fault_siz       (fault_siz_w),
        .fault_valid     (fault_valid_w),
        .fault_retry     (fault_retry_w),
        .fault_is_rmw    (fault_is_rmw_w),
        .retry_pending   (retry_pending_w),
        .retry_exhausted (retry_exhausted_w),
        .status_n        (status_n),
        // This core has no exception controller of its own outside the pipeline,
        // so there is no genuine double-fault condition to report yet.
        .double_fault    (1'b0),
        .exc_frame_format(exc_frame_format_w),
        .exc_frame_valid (exc_frame_valid_w),
        .exc_ssw         (exc_ssw_w),
        .mmu_fault       (mmu_fault_w),
        .mmu_ci          (mmu_ci_w),
        .mmusr           (mmusr_w),
        // External MMU translation port -- no m68030_mmu instance here.
        .mmu_va_ext      (32'h0),
        .mmu_fc_ext      (3'b0),
        .mmu_rw_ext      (1'b1),
        .mmu_req_ext     (1'b0),
        .mmu_is_ptest_ext(1'b0),
        .mmu_pa_ext      (mmu_pa_ext_w),
        .mmu_done_ext    (mmu_done_ext_w),
        .mmu_pflush_req  (1'b0),
        .mmu_pflush_all  (1'b0),
        .mmu_pflush_fc   (3'b0),
        .mmu_pflush_va   (32'h0),
        .mmu_pflush_ack  (mmu_pflush_ack_w)
    );

endmodule

`default_nettype wire

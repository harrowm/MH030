`timescale 1ns/1ps
`default_nettype none

// MC68030 Bus Interface Unit — Integration Wrapper 
//
// Instantiates and interconnects all biu_* submodules.  This is the
// boundary between the chip's internal bus-management logic and the
// external pin-level bus.
//
// Data path (normal EU access):
//   EU → biu_cache_if → biu_sizing_fsm → biu_cycle_gen → external bus
//
// Data path (MOVEM/MOVEP):
//   EU (mo_req) → biu_multiop_fsm → biu_sizing_fsm → biu_cycle_gen
//
// Special EU operations (IACK, RMW, CAS2, burst, MOVE16, coproc, RST)
//   go directly to biu_cycle_gen, bypassing sizing and cache layers.
//
// IFU instruction prefetch (Phase 127 — was direct-to-cycle_gen, no cache):
//   IFU → biu_icache_if → biu_cycle_gen ifu port (arbiter grant_ifu priority
//   unchanged; a hit never reaches biu_cycle_gen at all, a miss/disabled
//   access uses the exact same protocol the IFU used to drive directly)
//
// Async input synchronisation: biu_config (2-stage FF) for all chip pins.
// BERR timeout watchdog: biu_error_handler (combined with external BERR).
// Output tri-state gate: biu_pin_driver (blocks D-bus during reset).

module m68030_biu #(
    parameter int RSTOUT_CLKS       = 124,   // RESET-instruction RSTOUT duration (4× clocks)
    parameter int TIMEOUT_CLKS      = 128,   // BERR watchdog threshold  (4× clocks)
    parameter int POWERON_RSTO_CLKS = 2048   // Power-on RSTOUT duration (4× clocks; = 512 ext clocks)
) (
    input  logic        clk_4x,
    input  logic        rst_n,

    // -----------------------------------------------------------------------
    // External chip pins
    // -----------------------------------------------------------------------
    output logic [31:0] ext_a,
    // Data bus (bidirectional modelled as separate in/out/oe)
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
    output logic        ext_e,          // E-clock output
    output logic        ext_bg_n,       // Bus Grant to external DMA

    // Asynchronous chip inputs (raw pins — synchronised internally)
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
    // Phase 158 Stage 7: CIIN# (peripheral says "this data isn't
    // cacheable") -- async, synchronized like every other pin above.
    input  logic        ciin_n,
    // CIOUT# (CPU says "this access is definitely non-cacheable") --
    // driven combinationally from the cache-if modules' own already-live
    // non-cacheable conditions (mmu_ci/RMW-lookup/CPU-space/cache-disabled),
    // not a synchronized input.
    output logic        ciout_n,

    // -----------------------------------------------------------------------
    // EU normal data-access interface (goes through cache + sizing layers)
    // -----------------------------------------------------------------------
    input  logic [31:0] eu_addr,
    input  logic [31:0] eu_wdata,
    output logic [31:0] eu_rdata,
    input  logic [2:0]  eu_fc,
    input  logic        eu_rw,
    input  logic [1:0]  eu_siz,
    input  logic        eu_is_operand,
    input  logic        eu_is_icache,   // 1 = use I-cache, 0 = use D-cache
    input  logic        eu_req,
    output logic        eu_ack,
    output logic        eu_berr,
    output logic        eu_retry,
    input  logic        mem_rmw_lookup,  // Phase 158 Stage 3 — D-cache force-miss

    // EU special interfaces (direct to biu_cycle_gen — bypass cache/sizing)
    input  logic        eu_iack_req,
    input  logic [2:0]  eu_iack_level,
    output logic [7:0]  eu_iack_vec,
    output logic        eu_iack_avec,
    output logic        eu_iack_ack,

    input  logic        eu_rst_req,

    input  logic        eu_rmw,
    output logic        bus_lock,

    input  logic        eu_cas2_req,
    input  logic [31:0] eu_cas2_addr1,
    input  logic [31:0] eu_cas2_addr2,
    input  logic [2:0]  eu_cas2_fc,
    input  logic [1:0]  eu_cas2_siz,
    input  logic [31:0] eu_cas2_wdata1,
    input  logic [31:0] eu_cas2_wdata2,
    input  logic        eu_cas2_do_write1,
    input  logic        eu_cas2_do_write2,
    output logic [31:0] eu_cas2_rdata1,
    output logic [31:0] eu_cas2_rdata2,
    output logic        eu_cas2_ack,

    input  logic        eu_burst_req,
    input  logic [31:0] eu_burst_addr,
    input  logic [2:0]  eu_burst_fc,
    output logic [31:0] eu_burst_rdata0,
    output logic [31:0] eu_burst_rdata1,
    output logic [31:0] eu_burst_rdata2,
    output logic [31:0] eu_burst_rdata3,
    output logic        eu_burst_ack,
    output logic        eu_burst_berr,

    input  logic        eu_m16_req,
    input  logic [31:0] eu_m16_addr,
    input  logic [2:0]  eu_m16_fc,
    input  logic [31:0] eu_m16_wdata0,
    input  logic [31:0] eu_m16_wdata1,
    input  logic [31:0] eu_m16_wdata2,
    input  logic [31:0] eu_m16_wdata3,
    output logic        eu_m16_ack,
    output logic        eu_m16_berr,

    input  logic        eu_coproc_req,
    input  logic        eu_coproc_rw,
    input  logic [31:0] eu_coproc_addr,
    input  logic [2:0]  eu_coproc_fc,
    input  logic [1:0]  eu_coproc_siz,
    input  logic [31:0] eu_coproc_wdata,
    output logic [31:0] eu_coproc_rdata,
    output logic        eu_coproc_ack,
    output logic        eu_coproc_berr,

    input  logic        eu_bkpt_req,
    input  logic        eu_bkpt_rw,
    input  logic [31:0] eu_bkpt_addr,
    input  logic [2:0]  eu_bkpt_fc,
    input  logic [1:0]  eu_bkpt_siz,
    input  logic [31:0] eu_bkpt_wdata,
    output logic [31:0] eu_bkpt_rdata,
    output logic        eu_bkpt_ack,
    output logic        eu_bkpt_berr,

    // Address error outputs 
    output logic        eu_addr_err,    // word access to odd address
    output logic        ifu_addr_err,   // instruction fetch to odd address

    // EU MOVEM/MOVEP multi-op interface (goes through multiop_fsm → sizing)
    input  logic        eu_mo_req,
    input  logic [31:0] eu_mo_start_addr,
    input  logic [2:0]  eu_mo_fc,
    input  logic [1:0]  eu_mo_siz,
    input  logic        eu_mo_rw,
    input  logic [2:0]  eu_mo_count,
    input  logic [2:0]  eu_mo_stride,
    input  logic [31:0] eu_mo_wdata0,
    input  logic [31:0] eu_mo_wdata1,
    input  logic [31:0] eu_mo_wdata2,
    input  logic [31:0] eu_mo_wdata3,
    output logic [31:0] eu_mo_rdata0,
    output logic [31:0] eu_mo_rdata1,
    output logic [31:0] eu_mo_rdata2,
    output logic [31:0] eu_mo_rdata3,
    output logic        eu_mo_ack,
    output logic        eu_mo_berr,

    // -----------------------------------------------------------------------
    // IFU instruction-prefetch interface (now behind biu_icache_if — see
    // u_icache below; identical protocol to when this was wired direct to
    // biu_cycle_gen)
    // -----------------------------------------------------------------------
    input  logic [31:0] ifu_addr,
    input  logic        ifu_req,
    output logic [31:0] ifu_rdata,
    output logic        ifu_ack,
    output logic        ifu_berr,

    // -----------------------------------------------------------------------
    // Control registers (written by EU via MOVEC)
    // -----------------------------------------------------------------------
    input  logic [31:0] cacr,
    input  logic [31:0] caar,
    input  logic [31:0] tc,
    input  logic [63:0] crp,
    input  logic [63:0] srp,
    input  logic [31:0] tt0,
    input  logic [31:0] tt1,

    // -----------------------------------------------------------------------
    // Status and fault outputs
    // -----------------------------------------------------------------------
    output logic        bus_idle,
    output logic        bus_halted,
    output logic        init_done,
    output logic [31:0] init_ssp,
    output logic [31:0] init_pc,
    output logic [1:0]  phase,
    output logic [6:0]  s_state,

    output logic [31:0] fault_addr,
    output logic [31:0] fault_data,
    output logic [2:0]  fault_fc,
    output logic        fault_rw,
    output logic [1:0]  fault_siz,
    output logic        fault_valid,
    output logic        fault_retry,
    output logic        fault_is_rmw,
    output logic        retry_pending,
    output logic        halt_out,

    output logic [3:0]  exc_frame_format,
    output logic        exc_frame_valid,
    output logic [15:0] exc_ssw,

    output logic        mmu_fault,
    output logic        mmu_ci,
    output logic [15:0] mmusr,

    // External MMU translation interface (driven by m68030_mmu)
    input  logic [31:0] mmu_va_ext,
    input  logic [2:0]  mmu_fc_ext,
    input  logic        mmu_rw_ext,
    input  logic        mmu_req_ext,
    input  logic        mmu_is_ptest_ext, // Phase 150 Stage 4
    output logic [31:0] mmu_pa_ext,
    output logic        mmu_done_ext,   // hit | walk_done (one-cycle pulse)

    // External PFLUSH interface
    input  logic        mmu_pflush_req,
    input  logic        mmu_pflush_all,
    input  logic [2:0]  mmu_pflush_fc,
    input  logic [31:0] mmu_pflush_va,
    output logic        mmu_pflush_ack
);

    // -----------------------------------------------------------------------
    // Synchronised async inputs (from biu_config)
    // -----------------------------------------------------------------------
    logic dsack0_s, dsack1_s, sterm_s, berr_s_ext;
    logic halt_s, avec_s, vpa_s;
    logic [2:0] ipl_s;
    logic br_s, bgack_s, cback_s;
    logic ciin_s;  // Phase 158 Stage 7
    logic ciout_w; // biu_cache_if's own CIOUT determination (active-high internal)
    logic pins_released;
    logic cfg_poweron_rstout_n;  // power-on RSTOUT from biu_config

    biu_config #(.POWERON_RSTO_CLKS(POWERON_RSTO_CLKS)) u_cfg (
        .clk_4x            (clk_4x),
        .rst_n             (rst_n),
        .dsack0_n          (dsack0_n),
        .dsack1_n          (dsack1_n),
        .sterm_n           (sterm_n),
        .berr_n            (berr_n),
        .halt_n            (halt_n),
        .avec_n            (avec_n),
        .vpa_n             (vpa_n),
        .ipl_n             (ipl_n),
        .br_n              (br_n),
        .bgack_n           (bgack_n),
        .cback_n           (cback_n),
        .ciin_n            (ciin_n),
        .dsack0_s          (dsack0_s),
        .dsack1_s          (dsack1_s),
        .sterm_s           (sterm_s),
        .berr_s            (berr_s_ext),
        .avec_s            (avec_s),
        .halt_s            (halt_s),
        .vpa_s             (vpa_s),
        .ipl_s             (ipl_s),
        .br_s              (br_s),
        .bgack_s           (bgack_s),
        .cback_s           (cback_s),
        .ciin_s            (ciin_s),
        .pins_released     (pins_released),
        .poweron_rstout_n  (cfg_poweron_rstout_n)
    );

    // -----------------------------------------------------------------------
    // E-clock generator
    // -----------------------------------------------------------------------
    logic [3:0] eclk_cnt;

    biu_eclk_gen u_eclk (
        .clk_4x  (clk_4x),
        .rst_n   (rst_n),
        .e       (ext_e),
        .eclk_cnt(eclk_cnt)
    );

    // -----------------------------------------------------------------------
    // BERR watchdog — fires berr_timeout after TIMEOUT_CLKS of no response.
    // Feeds berr_combined into cycle_gen.berr_s.
    // Uses berr_s_ext (not combined) to avoid a self-clearing feedback loop.
    // -----------------------------------------------------------------------
    logic berr_timeout, berr_combined;
    logic bus_reset_inst;

    biu_error_handler #(.TIMEOUT_CLKS(TIMEOUT_CLKS)) u_err (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .bus_idle       (bus_idle),
        .bus_reset_inst (bus_reset_inst),
        .retry_pending  (retry_pending),
        .dsack0_s       (dsack0_s),
        .dsack1_s     (dsack1_s),
        .sterm_s      (sterm_s),
        .berr_s       (berr_s_ext),
        .berr_timeout (berr_timeout),
        .halt_out     (halt_out)
    );

    assign berr_combined = berr_s_ext | berr_timeout;

    // -----------------------------------------------------------------------
    // Internal signals declared here so Icarus sees them before any use
    // -----------------------------------------------------------------------
    // Arbiter grants
    logic grant_mmu, grant_eu, grant_ifu, dma_active;
    // biu_icache_if's own burst-linefill request (Phase 127 cache plan
    // Step 8) — declared here, ahead of u_arb's own instantiation below,
    // since Icarus requires port-connection expressions to reference
    // already-declared signals (unlike plain continuous assigns elsewhere
    // in this file, which tolerate forward references).
    logic        ic_burst_req;
    logic [31:0] ic_burst_addr;
    // Phase 158 Stage 4c: biu_cache_if's own D-side burst-linefill request,
    // same declared-early-for-arbiter-port-refs reasoning as ic_burst_req
    // above.
    logic        dc_burst_req;
    logic [31:0] dc_burst_addr;
    logic [2:0]  dc_burst_fc;
    // cg_eu_burst_beat also needs early declaration -- both u_cache (below)
    // and u_icache (later) reference it in their own port connections.
    logic [1:0]  cg_eu_burst_beat;
    // Sizing FSM → cycle_gen EU port (also drives arbiter eu_req)
    logic sf_cyc_req;
    logic [31:0] sf_cyc_addr, sf_cyc_wdata;
    logic [2:0]  sf_cyc_fc;
    logic [1:0]  sf_cyc_siz;
    logic        sf_cyc_rw, sf_cyc_is_op;
    // Cycle-gen single-sub-cycle output back to sizing_fsm
    logic [31:0] cg_eu_rdata;
    logic        cg_eu_ack;
    logic [1:0]  cyc_port_dsack;
    // Sizing FSM assembled output (feeds cache_if and multiop_fsm)
    logic [31:0] sf_eu_rdata;
    logic        sf_eu_ack;
    // Cycle_gen EU berr (direct to wrapper output and multiop/cache_if)
    logic        cg_eu_berr_raw;
    // MMU table walker wires (needed by arbiter mmu_req before u_mmu decl)
    logic [31:0] mmu_walk_addr;
    logic [2:0]  mmu_walk_fc;
    logic        mmu_walk_req;
    logic        mmu_walk_rw;      // Phase 150 Stage 3: 1=read, 0=write (U/M write-back)
    logic [31:0] mmu_walk_wdata;   // Phase 150 Stage 3: write data for the U/M write-back cycle
    logic [31:0] cg_mmu_rdata;
    logic        cg_mmu_ack, cg_mmu_berr;
    // Multiop → sizing_fsm
    logic [31:0] mo_sf_addr, mo_sf_wdata;
    logic [2:0]  mo_sf_fc;
    logic [1:0]  mo_sf_siz;
    logic        mo_sf_rw, mo_sf_is_op, mo_sf_req;
    // Cache_if → sizing_fsm
    logic [31:0] ca_sf_addr, ca_sf_wdata;
    logic [2:0]  ca_sf_fc;
    logic [1:0]  ca_sf_siz;
    logic        ca_sf_rw, ca_sf_is_op, ca_sf_req;
    logic [31:0] ca_eu_rdata;
    logic        ca_eu_ack, ca_eu_berr;
    // Icache_if → cycle_gen (ifu_* port, same protocol the IFU used to
    // drive directly)
    logic [31:0] ic_cg_addr, ic_cg_rdata;
    logic        ic_cg_req, ic_cg_ack, ic_cg_berr;
    // Sizing FSM input mux output
    logic [31:0] sf_in_addr, sf_in_wdata;
    logic [2:0]  sf_in_fc;
    logic [1:0]  sf_in_siz;
    logic        sf_in_rw, sf_in_is_op, sf_in_req;
    // Cycle_gen raw d-bus (before pin_driver gates OE)
    logic [31:0] cg_ext_d_out_raw;
    logic        cg_ext_d_out_raw_oe;
    // RESET-instruction RSTOUT from cycle_gen (separate from power-on RSTOUT)
    logic        cg_rstout_n;

    // -----------------------------------------------------------------------
    // Bus arbiter — Priority: MMU > EU > IFU > external DMA
    // -----------------------------------------------------------------------

    biu_arbiter u_arb (
        .clk_4x    (clk_4x),
        .rst_n     (rst_n),
        .mmu_req   (mmu_walk_req),
        // sf_cyc_req | dc_burst_req: same reasoning as ifu_req's own
        // ic_cg_req | ic_burst_req below, applied to the D-side -- biu_cache_if
        // now has two distinct downstream request paths too (sf_cyc_req for
        // its ordinary sizing_fsm-routed accesses, dc_burst_req for a DBE=1
        // miss's own genuine burst linefill, Phase 158 Stage 4c). Omitting
        // dc_burst_req here would let a D-cache burst bypass normal
        // mmu>eu>ifu arbitration the exact same way the original ic_burst_req
        // bug did (see that bug's own writeup in the ifu_req comment below).
        //
        // | (eu_req & !eu_mo_req) (Phase 163 Stage 3, plan.md): both
        // biu_cache_if.sv's own CI_DONE state and biu_sizing_fsm.sv's own
        // SS_DONE state (which merely passes CI_DONE's own gap through)
        // correctly drop their downstream request for exactly one tick as
        // a terminal "ack pulse" -- neither can safely present the NEXT
        // transaction's own address/data any earlier, since eu_seq.sv's
        // own RMW-phase-transition registers (e.g. mem_rmw_run_r) only
        // update the cycle *after* that ack is observed. But that one-tick
        // gap coincides exactly with the one tick this arbiter's own grant
        // re-evaluates (bus_idle), so a read-modify-write instruction's own
        // immediate write phase could lose that specific window to a
        // lower-priority ifu_req that happened to be pending at that exact
        // moment -- confirmed via direct trace (Stage 2): the raw eu_req
        // port below stays genuinely continuous (unbroken) across the
        // whole RMW sequence the entire time sf_cyc_req blips low, so OR-
        // ing it in here only affects THIS module's own grant-holding
        // decision, not what data biu_cycle_gen ever sees (still gated by
        // sf_cyc_req itself, unchanged, so nothing can launch a cycle with
        // stale address/data). !eu_mo_req mirrors the identical gate
        // already applied to biu_cache_if's own eu_req input just below
        // (currently a no-op since eu_mo_req is hardwired 0, kept for
        // consistency with that established convention).
        .eu_req    (sf_cyc_req | dc_burst_req | (eu_req & !eu_mo_req)),
        // downstream request from biu_icache_if, not the raw IFU-side ifu_req
        // (which stays asserted on a cache hit that never reaches the bus).
        // ic_cg_req | ic_burst_req: biu_icache_if now has TWO distinct
        // downstream request paths (ic_cg_req for the icache_en=0 bypass,
        // ic_burst_req for an enabled-cache miss's own genuine burst
        // linefill, Phase 127 cache plan Step 8) -- either one means "the
        // I-cache module wants the bus," so the arbiter needs to see both.
        // Missing this originally caused a real, found-by-tracing bug: with
        // ic_burst_req wired only into biu_cycle_gen's own eu_burst_req
        // port (which sits ABOVE grant_eu/grant_ifu in cycle_gen's own
        // idle-priority chain, bypassing this arbiter entirely), an I-cache
        // burst could win the bus over a simultaneously-pending, genuinely
        // higher-priority ordinary EU access -- confirmed via direct
        // mem_req/mem_wdata/mem_ack tracing: JSR's own return-address push
        // reported mem_ack=1 (the EU believed its write completed) but a
        // literal two-instruction-later RTS read back a stale, wrong value
        // from the very same stack address, meaning the write had actually
        // been starved/lost while an I-cache burst silently jumped the
        // queue. See cg_burst_req_mux below for the other half of the fix
        // (gating ic_burst_req's own entry into cycle_gen's port on
        // grant_ifu, the same way the ordinary ifu_req path already does).
        .ifu_req   (ic_cg_req | ic_burst_req),
        .bus_idle  (bus_idle),
        .bus_lock  (bus_lock),
        .grant_mmu (grant_mmu),
        .grant_eu  (grant_eu),
        .grant_ifu (grant_ifu),
        .dma_active(dma_active),
        .br_s      (br_s),
        .ext_bg_n  (ext_bg_n),
        .bgack_s   (bgack_s),
        // AS# pin feedback: optimistically tied to 1 (deasserted) — the 68030
        // protocol requires external DMA to release AS# before BGACK; we rely
        // on that convention rather than routing the physical pin back.
        .as_n_fb   (1'b1)
    );

    // -----------------------------------------------------------------------
    // MMU interface — ATC + table walker, arbitrated (Phase 150, plan.md)
    //
    // biu_mmu_if is a single-request-at-a-time resource. Before this phase
    // it only ever had one real requester (the EXT port below, driven by
    // m68030_mmu.sv for PTEST/explicit translation requests). This phase
    // wires real address translation into the live cache-miss paths,
    // adding two more requesters — biu_cache_if.sv (D) and biu_icache_if.sv
    // (I) — that need the same underlying biu_mmu_if instance. biu_mmu_arb
    // arbitrates them (EXT > D > I, matching BIU-097's own MMU priority)
    // and demuxes the shared result back to whichever owner is being
    // serviced.
    // -----------------------------------------------------------------------

    // Raw, undemuxed biu_mmu_if outputs (any owner) — feeds the arbiter's
    // own result input, and separately biu_exc_capture's own mmu_fault
    // input below (format-$9 classification doesn't care which owner
    // triggered a real walk-time BERR, unlike the demuxed per-owner
    // fault/hit/walk_done pulses, which do).
    logic [31:0] raw_mmu_pa_w;
    logic        raw_mmu_hit_w, raw_mmu_walk_done_w, raw_mmu_fault_w;
    logic        raw_mmu_fault_is_berr_w;
    logic        raw_mmu_ci_w, raw_mmu_wp_w;
    logic [15:0] raw_mmu_mmusr_w; // Phase 150 Stage 4

    // Arbitrated request into biu_mmu_if
    logic [31:0] arb_mmu_va;
    logic [2:0]  arb_mmu_fc;
    logic        arb_mmu_rw;
    logic        arb_mmu_req;
    logic        arb_mmu_is_ptest; // Phase 150 Stage 4

    // D-side (biu_cache_if.sv) translation-request wires
    logic [31:0] ca_xl_va, ca_xl_pa;
    logic [2:0]  ca_xl_fc;
    logic        ca_xl_rw, ca_xl_req;
    logic        ca_xl_hit, ca_xl_walk_done, ca_xl_fault, ca_xl_fault_is_berr;
    logic        ca_xl_ci, ca_xl_wp;
    logic        ca_xlate_fault_pulse;
    logic [31:0] ca_xlate_fault_addr;
    logic [2:0]  ca_xlate_fault_fc;
    logic        ca_xlate_fault_rw;
    logic [1:0]  ca_xlate_fault_siz;

    // I-side (biu_icache_if.sv) translation-request wires
    logic [31:0] ic_xl_va, ic_xl_pa;
    logic [2:0]  ic_xl_fc;
    logic        ic_xl_rw, ic_xl_req;
    logic        ic_xl_hit, ic_xl_walk_done, ic_xl_fault, ic_xl_fault_is_berr;
    logic        ic_xl_ci;
    logic        ic_xlate_fault_pulse;
    logic [31:0] ic_xlate_fault_addr;
    logic [2:0]  ic_xlate_fault_fc;
    logic        ic_xlate_fault_rw;
    logic [1:0]  ic_xlate_fault_siz;

    // mmu_done_ext = hit | walk_done (both one-cycle pulses) — EXT owner only
    logic mmu_hit_w, mmu_walk_done_w;
    assign mmu_done_ext = mmu_hit_w | mmu_walk_done_w;

    biu_mmu_arb u_mmu_arb (
        .clk_4x (clk_4x),
        .rst_n  (rst_n),

        .ext_va  (mmu_va_ext),
        .ext_fc  (mmu_fc_ext),
        .ext_rw  (mmu_rw_ext),
        .ext_req (mmu_req_ext),
        .ext_is_ptest     (mmu_is_ptest_ext), // Phase 150 Stage 4
        .ext_pa           (mmu_pa_ext),
        .ext_hit          (mmu_hit_w),
        .ext_walk_done    (mmu_walk_done_w),
        .ext_fault        (mmu_fault),
        .ext_fault_is_berr(),          // not consumed by m68030_mmu.sv today
        .ext_ci           (mmu_ci),
        .ext_wp           (),          // not consumed today
        .ext_mmusr        (mmusr),     // Phase 150 Stage 4: now the real, EXT-demuxed MMUSR

        .d_va  (ca_xl_va),
        .d_fc  (ca_xl_fc),
        .d_rw  (ca_xl_rw),
        .d_req (ca_xl_req),
        .d_pa           (ca_xl_pa),
        .d_hit          (ca_xl_hit),
        .d_walk_done    (ca_xl_walk_done),
        .d_fault        (ca_xl_fault),
        .d_fault_is_berr(ca_xl_fault_is_berr),
        .d_ci           (ca_xl_ci),
        .d_wp           (ca_xl_wp),

        .i_va  (ic_xl_va),
        .i_fc  (ic_xl_fc),
        .i_rw  (ic_xl_rw),
        .i_req (ic_xl_req),
        .i_pa           (ic_xl_pa),
        .i_hit          (ic_xl_hit),
        .i_walk_done    (ic_xl_walk_done),
        .i_fault        (ic_xl_fault),
        .i_fault_is_berr(ic_xl_fault_is_berr),
        .i_ci           (ic_xl_ci),
        .i_wp           (),             // I-side has no xl_wp consumer

        .mmu_va  (arb_mmu_va),
        .mmu_fc  (arb_mmu_fc),
        .mmu_rw  (arb_mmu_rw),
        .mmu_req (arb_mmu_req),
        .mmu_is_ptest      (arb_mmu_is_ptest), // Phase 150 Stage 4
        .mmu_pa            (raw_mmu_pa_w),
        .mmu_hit           (raw_mmu_hit_w),
        .mmu_walk_done     (raw_mmu_walk_done_w),
        .mmu_fault         (raw_mmu_fault_w),
        .mmu_fault_is_berr (raw_mmu_fault_is_berr_w),
        .mmu_ci            (raw_mmu_ci_w),
        .mmu_wp            (raw_mmu_wp_w),
        .mmu_mmusr         (raw_mmu_mmusr_w) // Phase 150 Stage 4
    );

    biu_mmu_if u_mmu (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .va          (arb_mmu_va),
        .fc          (arb_mmu_fc),
        .rw          (arb_mmu_rw),
        .req         (arb_mmu_req),
        .is_ptest    (arb_mmu_is_ptest), // Phase 150 Stage 4
        .pa          (raw_mmu_pa_w),
        .hit         (raw_mmu_hit_w),
        .walk_done   (raw_mmu_walk_done_w),
        .fault       (raw_mmu_fault_w),
        .fault_is_berr(raw_mmu_fault_is_berr_w),
        .ci          (raw_mmu_ci_w),
        .wp          (raw_mmu_wp_w),
        .mmusr       (raw_mmu_mmusr_w), // Phase 150 Stage 4
        .mmu_req_addr(mmu_walk_addr),
        .mmu_req_fc  (mmu_walk_fc),
        .mmu_req     (mmu_walk_req),
        .mmu_req_rw  (mmu_walk_rw),
        .mmu_req_wdata(mmu_walk_wdata),
        .mmu_rdata   (cg_mmu_rdata),
        .mmu_ack     (cg_mmu_ack),
        .mmu_berr    (cg_mmu_berr),
        .tc          (tc),
        .crp         (crp),
        .srp         (srp),
        .tt0         (tt0),
        .tt1         (tt1),
        .pflush_req  (mmu_pflush_req),
        .pflush_all  (mmu_pflush_all),
        .pflush_fc   (mmu_pflush_fc),
        .pflush_va   (mmu_pflush_va),
        .pflush_ack  (mmu_pflush_ack)
    );

    // -----------------------------------------------------------------------
    // MOVEM/MOVEP multi-operation FSM
    // Drives the sizing_fsm EU port when eu_mo_req is active.
    // -----------------------------------------------------------------------

    biu_multiop_fsm u_mo (
        .clk_4x          (clk_4x),
        .rst_n           (rst_n),
        .eu_mo_req       (eu_mo_req),
        .eu_mo_start_addr(eu_mo_start_addr),
        .eu_mo_fc        (eu_mo_fc),
        .eu_mo_siz       (eu_mo_siz),
        .eu_mo_rw        (eu_mo_rw),
        .eu_mo_count     (eu_mo_count),
        .eu_mo_stride    (eu_mo_stride),
        .eu_mo_wdata0    (eu_mo_wdata0),
        .eu_mo_wdata1    (eu_mo_wdata1),
        .eu_mo_wdata2    (eu_mo_wdata2),
        .eu_mo_wdata3    (eu_mo_wdata3),
        .eu_mo_rdata0    (eu_mo_rdata0),
        .eu_mo_rdata1    (eu_mo_rdata1),
        .eu_mo_rdata2    (eu_mo_rdata2),
        .eu_mo_rdata3    (eu_mo_rdata3),
        .eu_mo_ack       (eu_mo_ack),
        .eu_mo_berr      (eu_mo_berr),
        .sf_eu_addr      (mo_sf_addr),
        .sf_eu_fc        (mo_sf_fc),
        .sf_eu_siz       (mo_sf_siz),
        .sf_eu_rw        (mo_sf_rw),
        .sf_eu_wdata     (mo_sf_wdata),
        .sf_eu_is_op     (mo_sf_is_op),
        .sf_eu_req       (mo_sf_req),
        .sf_eu_rdata     (sf_eu_rdata),
        .sf_eu_ack       (sf_eu_ack),
        .sf_eu_berr      (cg_eu_berr_raw)
    );

    // -----------------------------------------------------------------------
    // Cache interface — I-cache + D-cache, direct-mapped 256B each
    // Drives the sizing_fsm EU port when no multiop is active.
    // -----------------------------------------------------------------------

    biu_cache_if u_cache (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .eu_addr     (eu_addr),
        .eu_fc       (eu_fc),
        .eu_rw       (eu_rw),
        .eu_siz      (eu_siz),
        .eu_wdata    (eu_wdata),
        .eu_req      (eu_req & !eu_mo_req),  // gate when multiop active
        .eu_is_icache(eu_is_icache),
        .mem_rmw_lookup(mem_rmw_lookup),  // Phase 158 Stage 3
        .eu_rdata    (ca_eu_rdata),
        .eu_ack      (ca_eu_ack),
        .eu_berr     (ca_eu_berr),
        .mmu_ci      (mmu_ci),
        .ciin        (ciin_s),    // Phase 158 Stage 7
        .ciout       (ciout_w),
        .sf_addr     (ca_sf_addr),
        .sf_fc       (ca_sf_fc),
        .sf_rw       (ca_sf_rw),
        .sf_siz      (ca_sf_siz),
        .sf_wdata    (ca_sf_wdata),
        .sf_is_op    (ca_sf_is_op),
        .sf_req      (ca_sf_req),
        .sf_rdata    (sf_eu_rdata),
        .sf_ack      (sf_eu_ack),
        .sf_berr     (cg_eu_berr_raw),
        // Phase 158 Stage 4c: same shared bus-level burst-response signals
        // biu_icache_if's own ic_burst_* input ports already wire below --
        // mutual exclusion between the two clients is via the arbiter
        // (grant_eu vs. grant_ifu) and cg_burst_req_mux above, not any
        // per-client response demuxing, so both modules can safely receive
        // the same physical wires.
        .dc_burst_req   (dc_burst_req),
        .dc_burst_addr  (dc_burst_addr),
        .dc_burst_fc    (dc_burst_fc),
        .dc_burst_rdata0(eu_burst_rdata0),
        .dc_burst_rdata1(eu_burst_rdata1),
        .dc_burst_rdata2(eu_burst_rdata2),
        .dc_burst_rdata3(eu_burst_rdata3),
        .dc_burst_beat  (cg_eu_burst_beat),
        .dc_burst_ack   (eu_burst_ack),
        .dc_burst_berr  (eu_burst_berr),
        .cacr        (cacr),
        .caar        (caar),
        .tc          (tc),
        .xl_va       (ca_xl_va),
        .xl_fc       (ca_xl_fc),
        .xl_rw       (ca_xl_rw),
        .xl_req      (ca_xl_req),
        .xl_pa       (ca_xl_pa),
        .xl_hit      (ca_xl_hit),
        .xl_walk_done(ca_xl_walk_done),
        .xl_fault    (ca_xl_fault),
        .xl_fault_is_berr(ca_xl_fault_is_berr),
        .xl_ci       (ca_xl_ci),
        .xl_wp       (ca_xl_wp),
        .xlate_fault_pulse(ca_xlate_fault_pulse),
        .xlate_fault_addr (ca_xlate_fault_addr),
        .xlate_fault_fc   (ca_xlate_fault_fc),
        .xlate_fault_rw   (ca_xlate_fault_rw),
        .xlate_fault_siz  (ca_xlate_fault_siz)
    );

    // EU data-access output mux: multiop OR cache-if path
    assign eu_rdata = ca_eu_rdata;   // cache_if serves eu_rdata on hit or after fill
    assign eu_ack   = ca_eu_ack;     // cache_if fires eu_ack in CI_DONE

    // -----------------------------------------------------------------------
    // I-cache interface — interposed between the IFU's existing longword
    // fetch port and biu_cycle_gen's existing ifu_* port (Phase 127). Same
    // protocol on both sides; a pure combinational bypass when icache_en=0
    // keeps this byte-for-byte identical to the pre-existing direct wiring.
    // -----------------------------------------------------------------------

    // Burst-linefill wires (Phase 127 cache plan Step 8): biu_icache_if's
    // own genuine SIZ=11 pin-level miss-fill request, muxed into the
    // existing eu_burst_req/addr/fc port biu_cycle_gen already implements
    // (CBREQ#/CBACK# handshake and all, tested since Phase 7 via
    // tb/biu_tb.sv's own direct eu_burst_req cases -- until now nothing in
    // the integrated chip ever drove it, since m68030_top.sv hardwires the
    // external eu_burst_req input to 0). The external EU-facing port takes
    // priority when both assert -- purely defensive, since m68030_top.sv
    // still hardwires eu_burst_req to 0 unconditionally, so ic_burst_req is
    // the only real requester of this port in the full chip; the collision
    // this priority resolves cannot actually occur in any of this project's
    // own test configurations (confirmed: tb/biu_tb.sv, the only place
    // eu_burst_req is ever driven nonzero, instantiates m68030_biu directly
    // and never drives ifu_req into a cache-enabled miss during its own
    // eu_burst_req test cases).
    //
    // ic_burst_req's own entry is ADDITIONALLY gated on grant_ifu -- unlike
    // the external eu_burst_req port (which, per biu_cycle_gen's own
    // pre-existing design, bypasses biu_arbiter.sv entirely, checked above
    // grant_eu/grant_ifu in its idle-priority chain), the I-cache's own
    // burst request must go through NORMAL mmu>eu>ifu arbitration the same
    // way the ordinary (non-burst) ifu_req path already correctly does.
    // A first version omitted this gate, reasoning the external port's own
    // "always above grant_eu" design was pre-existing and safe to reuse
    // as-is -- wrong, and caught by direct tracing, not by inspection: an
    // I-cache burst silently won the bus over a simultaneously-pending,
    // genuinely higher-priority ordinary EU write (JSR's own return-address
    // push) -- eu_seq.sv still saw mem_ack=1 (believing its write
    // completed) but the write had actually been starved, and a
    // two-instruction-later RTS read back stale data from the same stack
    // address, corrupting the return address and hanging the CPU in an
    // infinite JSR/RTS loop. u_arb's own ifu_req input is fed
    // ic_cg_req|ic_burst_req (see its own instantiation above) so grant_ifu
    // correctly reflects either downstream request path.
    // Phase 158 Stage 4c: dc_burst_req (biu_cache_if's own D-side burst
    // request) joins this same mux as a third tier, between the external
    // eu_burst_req port (highest) and ic_burst_req (lowest) -- matching
    // this project's own documented EU>IFU arbiter priority (CLAUDE.md),
    // since the D-cache is part of the EU's own data path. Gated on
    // grant_eu, mirroring exactly why ic_burst_req is gated on grant_ifu
    // above (a burst request must go through normal mmu>eu>ifu arbitration,
    // not bypass it) -- u_arb's own eu_req input is fed sf_cyc_req|
    // dc_burst_req (see its own instantiation above) so grant_eu correctly
    // reflects either downstream request path.
    wire         cg_burst_req_mux  = eu_burst_req | (dc_burst_req && grant_eu) | (ic_burst_req && grant_ifu);
    wire [31:0]  cg_burst_addr_mux = eu_burst_req ? eu_burst_addr :
                                     (dc_burst_req && grant_eu) ? dc_burst_addr : ic_burst_addr;
    wire [2:0]   cg_burst_fc_mux   = eu_burst_req ? eu_burst_fc :
                                     (dc_burst_req && grant_eu) ? dc_burst_fc : 3'b110; // Supervisor Program Space, matches ordinary ifu_req's own fixed FC

    biu_icache_if u_icache (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .ifu_addr       (ifu_addr),
        // Phase 158 Stage 2: tied to the same hardcoded Supervisor Program
        // Space constant biu_cycle_gen.sv's own ordinary ifu_req path uses
        // (3'b110) -- see biu_icache_if.sv's own header comment for why
        // genuine dynamic S-bit-awareness for instruction fetches is a
        // separate, deeper, out-of-scope gap, not fixed this stage.
        .ifu_fc         (3'b110),
        .ifu_req        (ifu_req),
        .ifu_rdata      (ifu_rdata),
        .ifu_ack        (ifu_ack),
        .ifu_berr       (ifu_berr),
        .cg_addr        (ic_cg_addr),
        .cg_req         (ic_cg_req),
        .cg_rdata       (ic_cg_rdata),
        .cg_ack         (ic_cg_ack),
        .cg_berr        (ic_cg_berr),
        .cacr           (cacr),
        .caar           (caar),
        .ciin           (ciin_s),    // Phase 158 Stage 7
        .ic_burst_req   (ic_burst_req),
        .ic_burst_addr  (ic_burst_addr),
        .ic_burst_rdata0(eu_burst_rdata0),
        .ic_burst_rdata1(eu_burst_rdata1),
        .ic_burst_rdata2(eu_burst_rdata2),
        .ic_burst_rdata3(eu_burst_rdata3),
        .ic_burst_beat  (cg_eu_burst_beat),
        .ic_burst_ack   (eu_burst_ack),
        .ic_burst_berr  (eu_burst_berr),
        .tc             (tc),
        .xl_va       (ic_xl_va),
        .xl_fc       (ic_xl_fc),
        .xl_rw       (ic_xl_rw),
        .xl_req      (ic_xl_req),
        .xl_pa       (ic_xl_pa),
        .xl_hit      (ic_xl_hit),
        .xl_walk_done(ic_xl_walk_done),
        .xl_fault    (ic_xl_fault),
        .xl_fault_is_berr(ic_xl_fault_is_berr),
        .xl_ci       (ic_xl_ci),
        .xlate_fault_pulse(ic_xlate_fault_pulse),
        .xlate_fault_addr (ic_xlate_fault_addr),
        .xlate_fault_fc   (ic_xlate_fault_fc),
        .xlate_fault_rw   (ic_xlate_fault_rw),
        .xlate_fault_siz  (ic_xlate_fault_siz)
    );

    // -----------------------------------------------------------------------
    // Sizing FSM input mux: multiop takes priority over cache-if
    // -----------------------------------------------------------------------

    always_comb begin
        if (mo_sf_req) begin
            sf_in_addr  = mo_sf_addr;   sf_in_wdata = mo_sf_wdata;
            sf_in_fc    = mo_sf_fc;     sf_in_siz   = mo_sf_siz;
            sf_in_rw    = mo_sf_rw;     sf_in_is_op = mo_sf_is_op;
            sf_in_req   = mo_sf_req;
        end else begin
            sf_in_addr  = ca_sf_addr;   sf_in_wdata = ca_sf_wdata;
            sf_in_fc    = ca_sf_fc;     sf_in_siz   = ca_sf_siz;
            sf_in_rw    = ca_sf_rw;     sf_in_is_op = ca_sf_is_op;
            sf_in_req   = ca_sf_req;
        end
    end

    // -----------------------------------------------------------------------
    // Dynamic bus-sizing FSM — handles 8/16/32-bit port sizing
    // -----------------------------------------------------------------------

    biu_sizing_fsm u_sf (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .eu_addr       (sf_in_addr),
        .eu_siz        (sf_in_siz),
        .eu_rw         (sf_in_rw),
        .eu_wdata      (sf_in_wdata),
        .eu_fc         (sf_in_fc),
        .eu_is_operand (sf_in_is_op),
        .eu_req        (sf_in_req),
        .eu_rdata      (sf_eu_rdata),
        .eu_ack        (sf_eu_ack),
        .cyc_addr      (sf_cyc_addr),
        .cyc_siz       (sf_cyc_siz),
        .cyc_rw        (sf_cyc_rw),
        .cyc_wdata     (sf_cyc_wdata),
        .cyc_fc        (sf_cyc_fc),
        .cyc_is_operand(sf_cyc_is_op),
        .cyc_req       (sf_cyc_req),
        .cyc_rdata     (cg_eu_rdata),
        .cyc_ack       (cg_eu_ack),
        .cyc_port_dsack(cyc_port_dsack),
        .bus_idle      (bus_idle)
    );

    // -----------------------------------------------------------------------
    // Core bus-cycle generator — owns all S-state transitions
    // -----------------------------------------------------------------------

    // Phase 150 (plan.md): declared here (ahead of use) so biu_cycle_gen's
    // own instantiation below can target them directly -- Icarus requires
    // a net referenced in a continuous-assignment port connection to be
    // declared before that point in the file. See the mux logic and its
    // own comment further down for how these combine with the new
    // synthetic translation/WP fault pulses.
    logic [31:0] cg_fault_addr_w, cg_fault_data_w;
    logic [2:0]  cg_fault_fc_w;
    logic        cg_fault_rw_w;
    logic [1:0]  cg_fault_siz_w;
    logic        cg_fault_valid_w;

    biu_cycle_gen #(.RSTOUT_CLKS(RSTOUT_CLKS)) u_cg (
        .clk_4x          (clk_4x),
        .rst_n           (rst_n),
        // External bus (data bus routed through biu_pin_driver below)
        .ext_a           (ext_a),
        .ext_as_n        (ext_as_n),
        .ext_ds_n        (ext_ds_n),
        .ext_rw          (ext_rw),
        .ext_fc          (ext_fc),
        .ext_siz         (ext_siz),
        .ext_ecs_n       (ext_ecs_n),
        .ext_ocs_n       (ext_ocs_n),
        .ext_d_out       (cg_ext_d_out_raw),
        .ext_d_oe        (cg_ext_d_out_raw_oe),
        .ext_rstout_n    (cg_rstout_n),
        .ext_cbreq_n     (ext_cbreq_n),
        .ext_d_in        (ext_d_in),
        // Synchronised async inputs
        .dsack0_s        (dsack0_s),
        .dsack1_s        (dsack1_s),
        .sterm_s         (sterm_s),
        .berr_s          (berr_combined),
        .halt_s          (halt_s),
        .avec_s          (avec_s),
        .vpa_s           (vpa_s),
        .ipl_s           (ipl_s),
        .bgack_s         (bgack_s),
        .cback_s         (cback_s),
        // Arbiter grants
        .grant_mmu       (grant_mmu),
        .grant_eu        (grant_eu),
        .grant_ifu       (grant_ifu),
        .dma_active      (dma_active),
        // EU normal data access (from sizing_fsm)
        .eu_addr         (sf_cyc_addr),
        .eu_wdata        (sf_cyc_wdata),
        .eu_rdata        (cg_eu_rdata),
        .eu_fc           (sf_cyc_fc),
        .eu_rw           (sf_cyc_rw),
        .eu_siz          (sf_cyc_siz),
        .eu_is_operand   (sf_cyc_is_op),
        .eu_req          (sf_cyc_req),
        .eu_ack          (cg_eu_ack),
        .eu_berr         (cg_eu_berr_raw),
        .eu_retry        (eu_retry),
        // IFU instruction prefetch (now behind biu_icache_if, see u_icache above)
        .ifu_addr        (ic_cg_addr),
        .ifu_req         (ic_cg_req),
        .ifu_rdata       (ic_cg_rdata),
        .ifu_ack         (ic_cg_ack),
        .ifu_berr        (ic_cg_berr),
        // MMU table walker
        .mmu_addr        (mmu_walk_addr),
        .mmu_fc          (mmu_walk_fc),
        .mmu_req         (mmu_walk_req),
        .mmu_rw          (mmu_walk_rw),
        .mmu_wdata       (mmu_walk_wdata),
        .mmu_rdata       (cg_mmu_rdata),
        .mmu_ack         (cg_mmu_ack),
        .mmu_berr        (cg_mmu_berr),
        // IACK
        .eu_iack_req     (eu_iack_req),
        .eu_iack_level   (eu_iack_level),
        .eu_iack_vec     (eu_iack_vec),
        .eu_iack_avec    (eu_iack_avec),
        .eu_iack_ack     (eu_iack_ack),
        // RESET instruction
        .eu_rst_req      (eu_rst_req),
        // E-clock for VPA synchronisation
        .eclk_cnt        (eclk_cnt),
        // Status
        .phase           (phase),
        .s_state         (s_state),
        .bus_idle        (bus_idle),
        .bus_reset_inst  (bus_reset_inst),
        .bus_halted      (bus_halted),
        .init_done       (init_done),
        .init_ssp        (init_ssp),
        .init_pc         (init_pc),
        .cyc_port_dsack  (cyc_port_dsack),
        // Fault capture (Phase 150, plan.md: renamed to cg_*_w so a
        // synthetic translation/WP fault can be muxed in below without
        // touching biu_cycle_gen's own real-BERR capture)
        .fault_addr      (cg_fault_addr_w),
        .fault_data      (cg_fault_data_w),
        .fault_fc        (cg_fault_fc_w),
        .fault_rw        (cg_fault_rw_w),
        .fault_siz       (cg_fault_siz_w),
        .fault_valid     (cg_fault_valid_w),
        .retry_pending   (retry_pending),
        .fault_retry     (fault_retry),
        .fault_is_rmw    (fault_is_rmw),
        // RMW
        .eu_rmw          (eu_rmw),
        .bus_lock        (bus_lock),
        // CAS2
        .eu_cas2_req     (eu_cas2_req),
        .eu_cas2_addr1   (eu_cas2_addr1),
        .eu_cas2_addr2   (eu_cas2_addr2),
        .eu_cas2_fc      (eu_cas2_fc),
        .eu_cas2_siz     (eu_cas2_siz),
        .eu_cas2_wdata1  (eu_cas2_wdata1),
        .eu_cas2_wdata2  (eu_cas2_wdata2),
        .eu_cas2_do_write1(eu_cas2_do_write1),
        .eu_cas2_do_write2(eu_cas2_do_write2),
        .eu_cas2_rdata1  (eu_cas2_rdata1),
        .eu_cas2_rdata2  (eu_cas2_rdata2),
        .eu_cas2_ack     (eu_cas2_ack),
        // Burst read -- request side muxed with biu_icache_if's own
        // ic_burst_req/addr (see the mux comment above); response side
        // (rdata/ack/berr) fans out unchanged to both the external port and
        // biu_icache_if's own ic_burst_* inputs, since only one of the two
        // requesters is ever actually in flight in any real configuration.
        .eu_burst_req    (cg_burst_req_mux),
        .eu_burst_addr   (cg_burst_addr_mux),
        .eu_burst_fc     (cg_burst_fc_mux),
        .eu_burst_rdata0 (eu_burst_rdata0),
        .eu_burst_rdata1 (eu_burst_rdata1),
        .eu_burst_rdata2 (eu_burst_rdata2),
        .eu_burst_rdata3 (eu_burst_rdata3),
        .eu_burst_ack    (eu_burst_ack),
        .eu_burst_berr   (eu_burst_berr),
        .eu_burst_beat   (cg_eu_burst_beat),
        // MOVE16 burst write
        .eu_m16_req      (eu_m16_req),
        .eu_m16_addr     (eu_m16_addr),
        .eu_m16_fc       (eu_m16_fc),
        .eu_m16_wdata0   (eu_m16_wdata0),
        .eu_m16_wdata1   (eu_m16_wdata1),
        .eu_m16_wdata2   (eu_m16_wdata2),
        .eu_m16_wdata3   (eu_m16_wdata3),
        .eu_m16_ack      (eu_m16_ack),
        .eu_m16_berr     (eu_m16_berr),
        // Coprocessor
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
        .eu_addr_err     (eu_addr_err),
        .ifu_addr_err    (ifu_addr_err)
    );

    // eu_berr now comes from cache_if's own, properly-gated final-abort
    // signal (CI_BERR state) rather than the raw cycle_gen pulse, which
    // fired on every transient in-flight retry attempt, not just a genuine
    // final abort — see biu_cache_if.sv's CI_BERR state.
    assign eu_berr = ca_eu_berr;

    // -----------------------------------------------------------------------
    // Synthetic fault-capture mux (Phase 150, plan.md): a pure translation
    // or WP fault (no real bus error at all) needs to feed the same
    // exception-frame capture path a real BERR does. biu_cycle_gen's own
    // cg_fault_valid_w only ever fires for a genuine external BERR sampled
    // during a real bus cycle — an invalid descriptor or WP violation never
    // generates one. Priority: real bus fault > D-side xlate > I-side
    // xlate (arbitrary among the two xlate sources, since both can't fire
    // the same cycle — only one of biu_cache_if/biu_icache_if is ever in
    // CI_XLATE/IC_XLATE at a time in practice, but the mux is defensive
    // either way). ca_xlate_fault_pulse/ic_xlate_fault_pulse are already
    // gated (their own source modules) to exclude the real-walk-BERR case,
    // which cg_fault_valid_w already captures independently — see
    // biu_mmu_if.sv's own fault_is_berr_r comment for the full reasoning.
    // (cg_fault_*_w themselves are declared earlier, ahead of biu_cycle_gen's
    // own instantiation, since Icarus requires a net used in a continuous
    // assignment port connection to be declared before that point in the
    // file — see the comment there.)
    // -----------------------------------------------------------------------
    wire         xlate_fault_any = ca_xlate_fault_pulse | ic_xlate_fault_pulse;
    wire [31:0]  xlate_fault_addr_mux = ca_xlate_fault_pulse ? ca_xlate_fault_addr : ic_xlate_fault_addr;
    wire [2:0]   xlate_fault_fc_mux   = ca_xlate_fault_pulse ? ca_xlate_fault_fc   : ic_xlate_fault_fc;
    wire         xlate_fault_rw_mux   = ca_xlate_fault_pulse ? ca_xlate_fault_rw   : ic_xlate_fault_rw;
    wire [1:0]   xlate_fault_siz_mux  = ca_xlate_fault_pulse ? ca_xlate_fault_siz  : ic_xlate_fault_siz;

    assign fault_valid = cg_fault_valid_w | xlate_fault_any;
    assign fault_addr  = cg_fault_valid_w ? cg_fault_addr_w : xlate_fault_addr_mux;
    assign fault_fc    = cg_fault_valid_w ? cg_fault_fc_w   : xlate_fault_fc_mux;
    assign fault_rw    = cg_fault_valid_w ? cg_fault_rw_w   : xlate_fault_rw_mux;
    assign fault_siz   = cg_fault_valid_w ? cg_fault_siz_w  : xlate_fault_siz_mux;
    // No real bus data for a pure translation/WP fault (no bus cycle ever
    // happened) -- pass through biu_cycle_gen's own value unconditionally;
    // harmless when it's a stale/idle 0, and exact fault_data correctness
    // for this new case is a documented, deliberately out-of-scope
    // refinement beyond Stage 0 (frame_format/SSW correctness is the goal
    // here, not full byte-perfect frame DATA-field correctness).
    assign fault_data  = cg_fault_data_w;

    // -----------------------------------------------------------------------
    // Exception frame capture — SSW + format determination
    // -----------------------------------------------------------------------
    biu_exc_capture u_exc (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .fault_valid    (fault_valid),
        .fault_addr     (fault_addr),
        .fault_data     (fault_data),
        .fault_fc       (fault_fc),
        .fault_rw       (fault_rw),
        .fault_siz      (fault_siz),
        .fault_retry    (fault_retry),
        .fault_is_rmw   (fault_is_rmw),
        .pipe_b_active  (1'b0),
        .pipe_c_active  (1'b0),
        // Phase 150 (plan.md): raw, undemuxed biu_mmu_if fault (any owner)
        // -- format-$9 classification doesn't care WHICH owner triggered a
        // real walk-time BERR, unlike the top-level mmu_fault OUTPUT port
        // (arbiter's ext_fault, demuxed to EXT/PTEST only, consumed by
        // m68030_mmu.sv for its own PTEST result). A pure logical fault
        // (invalid descriptor/WP) also correctly sets raw_mmu_fault_w via
        // the same path.
        .mmu_fault      (raw_mmu_fault_w | xlate_fault_any),
        .frame_format   (exc_frame_format),
        .frame_valid    (exc_frame_valid),
        .frame_fault_addr(),
        .frame_fault_data(),
        .frame_fault_fc (),
        .frame_fault_rw (),
        .frame_fault_siz(),
        .frame_word0    (),
        .ssw            (exc_ssw)
    );

    // -----------------------------------------------------------------------
    // Pin driver — gates D-bus OE during reset
    // -----------------------------------------------------------------------
    biu_pin_driver u_pd (
        .d_out        (cg_ext_d_out_raw),
        .d_oe         (cg_ext_d_out_raw_oe),
        .pins_released(pins_released),
        .ext_d_out    (ext_d_out),
        .ext_d_oe     (ext_d_oe)
    );

    // -----------------------------------------------------------------------
    // ext_rstout_n: asserted (low) by either power-on counter or RESET instruction.
    // Active-low: both sources must be deasserted (high) for the pin to be high.
    // -----------------------------------------------------------------------
    assign ext_rstout_n = cg_rstout_n & cfg_poweron_rstout_n;

    // Phase 158 Stage 7: CIOUT# -- active-low pin, inverted from
    // biu_cache_if's own active-high ciout determination.
    assign ciout_n = !ciout_w;

endmodule

`default_nettype wire

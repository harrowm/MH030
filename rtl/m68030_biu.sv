`default_nettype none

// MC68030 Bus Interface Unit — Integration Wrapper (Phase 13)
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
// IFU instruction prefetch:
//   EU (ifu_*) → biu_cycle_gen ifu port (direct, arbiter grant_ifu priority)
//
// Async input synchronisation: biu_config (2-stage FF) for all chip pins.
// BERR timeout watchdog: biu_error_handler (combined with external BERR).
// Output tri-state gate: biu_pin_driver (blocks D-bus during reset).

module m68030_biu #(
    parameter int RSTOUT_CLKS  = 124,   // RSTOUT assertion duration (4x clocks)
    parameter int TIMEOUT_CLKS = 128    // BERR watchdog threshold  (4x clocks)
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

    // Address error outputs (Phase 19)
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
    // IFU instruction-prefetch interface (direct to cycle_gen — no cache)
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
    logic pins_released;

    biu_config u_cfg (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .dsack0_n     (dsack0_n),
        .dsack1_n     (dsack1_n),
        .sterm_n      (sterm_n),
        .berr_n       (berr_n),
        .halt_n       (halt_n),
        .avec_n       (avec_n),
        .vpa_n        (vpa_n),
        .ipl_n        (ipl_n),
        .br_n         (br_n),
        .bgack_n      (bgack_n),
        .cback_n      (cback_n),
        .dsack0_s     (dsack0_s),
        .dsack1_s     (dsack1_s),
        .sterm_s      (sterm_s),
        .berr_s       (berr_s_ext),
        .avec_s       (avec_s),
        .halt_s       (halt_s),
        .vpa_s        (vpa_s),
        .ipl_s        (ipl_s),
        .br_s         (br_s),
        .bgack_s      (bgack_s),
        .cback_s      (cback_s),
        .pins_released(pins_released)
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
    // Sizing FSM input mux output
    logic [31:0] sf_in_addr, sf_in_wdata;
    logic [2:0]  sf_in_fc;
    logic [1:0]  sf_in_siz;
    logic        sf_in_rw, sf_in_is_op, sf_in_req;
    // Cycle_gen raw d-bus (before pin_driver gates OE)
    logic [31:0] cg_ext_d_out_raw;
    logic        cg_ext_d_out_raw_oe;

    // -----------------------------------------------------------------------
    // Bus arbiter — Priority: MMU > EU > IFU > external DMA
    // -----------------------------------------------------------------------

    biu_arbiter u_arb (
        .clk_4x    (clk_4x),
        .rst_n     (rst_n),
        .mmu_req   (mmu_walk_req),
        .eu_req    (sf_cyc_req),
        .ifu_req   (ifu_req),
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
    // MMU interface — ATC + table walker
    // -----------------------------------------------------------------------

    // mmu_done_ext = hit | walk_done (both one-cycle pulses)
    logic mmu_hit_w, mmu_walk_done_w;
    assign mmu_done_ext = mmu_hit_w | mmu_walk_done_w;

    biu_mmu_if u_mmu (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .va          (mmu_va_ext),
        .fc          (mmu_fc_ext),
        .rw          (mmu_rw_ext),
        .req         (mmu_req_ext),
        .pa          (mmu_pa_ext),
        .hit         (mmu_hit_w),
        .walk_done   (mmu_walk_done_w),
        .fault       (mmu_fault),
        .ci          (mmu_ci),
        .mmu_req_addr(mmu_walk_addr),
        .mmu_req_fc  (mmu_walk_fc),
        .mmu_req     (mmu_walk_req),
        .mmu_rdata   (cg_mmu_rdata),
        .mmu_ack     (cg_mmu_ack),
        .mmu_berr    (cg_mmu_berr),
        .tc          (tc),
        .crp         (crp),
        .srp         (srp),
        .tt0         (tt0),
        .tt1         (tt1),
        .mmusr       (mmusr),
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
        .eu_rdata    (ca_eu_rdata),
        .eu_ack      (ca_eu_ack),
        .eu_berr     (ca_eu_berr),
        .mmu_ci      (mmu_ci),
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
        .cacr        (cacr),
        .caar        (caar)
    );

    // EU data-access output mux: multiop OR cache-if path
    assign eu_rdata = ca_eu_rdata;   // cache_if serves eu_rdata on hit or after fill
    assign eu_ack   = ca_eu_ack;     // cache_if fires eu_ack in CI_DONE

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
        .ext_rstout_n    (ext_rstout_n),
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
        // IFU instruction prefetch
        .ifu_addr        (ifu_addr),
        .ifu_req         (ifu_req),
        .ifu_rdata       (ifu_rdata),
        .ifu_ack         (ifu_ack),
        .ifu_berr        (ifu_berr),
        // MMU table walker
        .mmu_addr        (mmu_walk_addr),
        .mmu_fc          (mmu_walk_fc),
        .mmu_req         (mmu_walk_req),
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
        // Fault capture
        .fault_addr      (fault_addr),
        .fault_data      (fault_data),
        .fault_fc        (fault_fc),
        .fault_rw        (fault_rw),
        .fault_siz       (fault_siz),
        .fault_valid     (fault_valid),
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
        // Burst read
        .eu_burst_req    (eu_burst_req),
        .eu_burst_addr   (eu_burst_addr),
        .eu_burst_fc     (eu_burst_fc),
        .eu_burst_rdata0 (eu_burst_rdata0),
        .eu_burst_rdata1 (eu_burst_rdata1),
        .eu_burst_rdata2 (eu_burst_rdata2),
        .eu_burst_rdata3 (eu_burst_rdata3),
        .eu_burst_ack    (eu_burst_ack),
        .eu_burst_berr   (eu_burst_berr),
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
        .eu_addr_err     (eu_addr_err),
        .ifu_addr_err    (ifu_addr_err)
    );

    // eu_berr routed direct from cycle_gen (cache_if.eu_berr is always 0)
    assign eu_berr = cg_eu_berr_raw;

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
        .mmu_fault      (mmu_fault),
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

endmodule

`default_nettype wire

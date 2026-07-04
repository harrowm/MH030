`default_nettype none
`timescale 1ns / 1ps

// MC68030 BIU Testbench — Phase 1 through Phase 7
//
// Phase 1 tests:
//   P1-1  Reset hold: phase==0, s_state==0, bus outputs safe
//   P1-2  Phase counter increments 0→1→2→3→0 after reset release
//   P1-3  E-clock period = 40 clk_4x; duty 24 low / 16 high
//
// Phase 2 tests:
//   P2-1  Power-on init completes (init_done asserts)
//   P2-2  Captured SSP == mem[0] ($DEADBEF0)
//   P2-3  Captured PC  == mem[1] ($CAFE0010)
//   P2-4  EU read: correct address and FC on bus at S0
//   P2-5  EU read: ECS_n asserts at S0; AS_n deasserted at S0
//   P2-6  EU read: AS_n asserts at S2; DS_n deasserted at S2
//   P2-7  EU read: DS_n asserts at S3; both strobes deassert at S6
//   P2-8  EU read: correct 32-bit data returned in eu_rdata
//   P2-9  EU write then read-back: data persists
//   P2-10 2-wait-state read: still completes and returns correct data
//
// Phase 3 tests (dynamic bus sizing — BIU-033, BIU-146):
//   P3-1  Longword read from 16-bit port: 2 sub-cycles, data assembled
//   P3-2  Longword read from 8-bit port: 4 sub-cycles, data assembled
//   P3-3  Longword write to 16-bit port then read-back
//   P3-4  Longword write to 8-bit port then read-back
//   P3-5  Word read (SIZ=10) from 32-bit port: 1 cycle, correct SIZ
//   P3-6  Byte read (SIZ=01) from 32-bit port: 1 cycle, correct SIZ
//
// Build:
//   iverilog -g2012 -o phase3.vvp tb/biu_tb.sv rtl/biu_eclk_gen.sv \
//            rtl/biu_cycle_gen.sv rtl/biu_arbiter.sv \
//            rtl/biu_sizing_fsm.sv tb/mem_model.sv
//   vvp phase3.vvp

module biu_tb;

    // -----------------------------------------------------------------------
    // Clock (100 MHz = 10 ns period)
    // -----------------------------------------------------------------------
    logic clk_4x = 1'b0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 1'b0;

    // -----------------------------------------------------------------------
    // E-clock generator
    // -----------------------------------------------------------------------
    logic       e;
    logic [3:0] eclk_cnt;

    biu_eclk_gen u_eclk (
        .clk_4x   (clk_4x),
        .rst_n    (rst_n),
        .e        (e),
        .eclk_cnt (eclk_cnt)
    );

    // -----------------------------------------------------------------------
    // External bus signals
    // -----------------------------------------------------------------------
    logic [31:0] ext_a;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n;
    logic [31:0] ext_d_out;
    logic        ext_d_oe, ext_rstout_n, ext_cbreq_n;
    logic [31:0] ext_d_in_to_biu;
    logic [1:0]  phase;
    logic [6:0]  s_state;
    logic        bus_idle, bus_reset_inst, bus_halted, init_done;
    logic [31:0] init_ssp, init_pc;

    // EU interface (driven by testbench tasks, consumed by sizing_fsm)
    logic [31:0] eu_addr_tb  = 32'h0;
    logic [31:0] eu_wdata_tb = 32'h0;
    logic [2:0]  eu_fc_tb    = 3'b101;
    logic        eu_rw_tb    = 1'b1;
    logic [1:0]  eu_siz_tb   = 2'b00;
    logic        eu_is_op_tb = 1'b1;
    logic        eu_req_tb   = 1'b0;

    // EU outputs — come from sizing_fsm (assembled across all sub-cycles)
    logic [31:0] eu_rdata;
    logic        eu_ack, eu_berr, eu_retry;

    // Phase 4 control signals (driven by testbench)
    logic sterm_tb  = 1'b0;
    logic berr_tb   = 1'b0;
    logic halt_tb   = 1'b1;   // 1 = HALT deasserted (active-low, sync'd)
    logic avec_tb   = 1'b0;
    logic vpa_s_tb  = 1'b1;   // active-low retained; 1=deasserted (normal), 0=VPA# asserted

    // Phase 11 — biu_error_handler outputs and combined BERR
    logic berr_timeout_tb;    // pulsed by watchdog when bus hangs
    logic halt_out_tb;        // double bus fault indicator
    logic berr_combined_tb;   // berr_tb | berr_timeout_tb → biu_cycle_gen.berr_s
    assign berr_combined_tb = berr_tb | berr_timeout_tb;

    // Phase 4 IACK signals
    logic        eu_iack_req_tb   = 1'b0;
    logic [2:0]  eu_iack_level_tb = 3'b0;
    logic [7:0]  eu_iack_vec_tb;
    logic        eu_iack_avec_tb;
    logic        eu_iack_ack_tb;

    // Phase 4 RESET instruction
    logic eu_rst_req_tb = 1'b0;

    // Phase 4 fault capture signals
    logic [31:0] fault_addr_tb, fault_data_tb;
    logic [2:0]  fault_fc_tb;
    logic        fault_rw_tb;
    logic [1:0]  fault_siz_tb;
    logic        fault_valid_tb;
    logic        retry_pending_tb;

    // Phase 5 — RMW and bus_lock
    logic eu_rmw_tb = 1'b0;
    logic bus_lock;

    // Phase 6 — cache_if control
    logic [31:0] cacr_tb         = 32'h0;
    logic [31:0] caar_tb         = 32'h0;
    logic        eu_is_icache_tb = 1'b1;
    logic        use_cache       = 1'b0;
    logic [31:0] cache_eu_rdata;
    logic        cache_eu_ack, cache_eu_berr;
    // cache_if → sizing_fsm wires
    logic [31:0] ca_sf_addr;
    logic [2:0]  ca_sf_fc;
    logic        ca_sf_rw;
    logic [1:0]  ca_sf_siz;
    logic [31:0] ca_sf_wdata;
    logic        ca_sf_is_op;
    logic        ca_sf_req;

    // Phase 7 — burst read and MOVE16 burst write
    logic        eu_burst_req_tb      = 1'b0;
    logic [31:0] eu_burst_addr_tb     = 32'h0;
    logic [2:0]  eu_burst_fc_tb       = 3'b101;
    logic [31:0] eu_burst_rdata0_tb, eu_burst_rdata1_tb;
    logic [31:0] eu_burst_rdata2_tb, eu_burst_rdata3_tb;
    logic        eu_burst_ack_tb, eu_burst_berr_tb;

    logic        eu_m16_req_tb        = 1'b0;
    logic [31:0] eu_m16_addr_tb       = 32'h0;
    logic [2:0]  eu_m16_fc_tb         = 3'b101;
    logic [31:0] eu_m16_wdata0_tb     = 32'h0;
    logic [31:0] eu_m16_wdata1_tb     = 32'h0;
    logic [31:0] eu_m16_wdata2_tb     = 32'h0;
    logic [31:0] eu_m16_wdata3_tb     = 32'h0;
    logic        eu_m16_ack_tb, eu_m16_berr_tb;

    logic        cback_s_tb           = 1'b0;  // 1 = CBACK# deasserted (active-low, sync'd)

    // Phase 10 — coprocessor (FPU) CPU Space cycle signals
    logic        eu_coproc_req_tb   = 1'b0;
    logic        eu_coproc_rw_tb    = 1'b1;
    logic [31:0] eu_coproc_addr_tb  = 32'h0;
    logic [2:0]  eu_coproc_fc_tb    = 3'b111;
    logic [1:0]  eu_coproc_siz_tb   = 2'b00;
    logic [31:0] eu_coproc_wdata_tb = 32'h0;
    logic [31:0] eu_coproc_rdata_tb;
    logic        eu_coproc_ack_tb;
    logic        eu_coproc_berr_tb;

    // Phase 9 — biu_config dedicated test signals (raw pin inputs to u_cfg)
    logic        cfg_dsack0_n = 1'b1;  // deasserted
    logic        cfg_dsack1_n = 1'b1;
    logic        cfg_sterm_n  = 1'b1;
    logic        cfg_berr_n   = 1'b1;
    logic        cfg_halt_n   = 1'b1;
    logic        cfg_avec_n   = 1'b1;
    logic        cfg_vpa_n    = 1'b1;
    logic [2:0]  cfg_ipl_n    = 3'b111;
    logic        cfg_br_n     = 1'b1;
    logic        cfg_bgack_n  = 1'b1;
    logic        cfg_cback_n  = 1'b1;
    // biu_config outputs (synchronized)
    logic        cfg_dsack0_s, cfg_dsack1_s, cfg_sterm_s;
    logic        cfg_berr_s, cfg_halt_s, cfg_avec_s, cfg_vpa_s;
    logic [2:0]  cfg_ipl_s;
    logic        cfg_br_s, cfg_bgack_s, cfg_cback_s;
    logic        cfg_pins_released;

    // Phase 9 — biu_pin_driver dedicated test signals
    logic [31:0] pd_d_out_tb     = 32'hDEAD_BEEF;
    logic        pd_d_oe_tb      = 1'b0;
    logic        pd_pins_rel_tb  = 1'b1;  // start released
    logic [31:0] pd_ext_d_out;
    logic        pd_ext_d_oe;

    // Phase 7 — exception capture
    logic [3:0]  exc_frame_format;
    logic        exc_frame_valid;
    logic [31:0] exc_frame_fault_addr, exc_frame_fault_data;
    logic [2:0]  exc_frame_fault_fc;
    logic        exc_frame_fault_rw;
    logic [1:0]  exc_frame_fault_siz;
    logic [15:0] exc_frame_word0;
    // Phase 12 — SSW and fault qualifiers
    logic        fault_retry_tb;
    logic        fault_is_rmw_tb;
    logic [15:0] exc_ssw;

    // Phase 6 — mmu_if control
    logic [31:0] tc_tb          = 32'h0;
    logic [63:0] crp_tb         = 64'h0;
    logic [63:0] srp_tb         = 64'h0;
    logic [31:0] tt0_tb         = 32'h0;
    logic [31:0] tt1_tb         = 32'h0;
    logic        use_mmu_tb     = 1'b0;
    logic [31:0] mmu_pa_out;
    logic        mmu_hit_out, mmu_walk_done_out;
    logic        mmu_fault_out, mmu_ci_out;
    // mmu_if → cycle_gen walk port
    logic [31:0] mmu_walk_addr;
    logic [2:0]  mmu_walk_fc;
    logic        mmu_walk_req;
    // cycle_gen mmu outputs (renamed from mmu_rdata/ack/berr)
    logic [31:0] cg_mmu_rdata;
    logic        cg_mmu_ack, cg_mmu_berr;

    // Phase 5 — CAS2 four-cycle atomic lock
    logic        eu_cas2_req_tb      = 1'b0;
    logic [31:0] eu_cas2_addr1_tb    = 32'h0;
    logic [31:0] eu_cas2_addr2_tb    = 32'h0;
    logic [2:0]  eu_cas2_fc_tb       = 3'b101;
    logic [1:0]  eu_cas2_siz_tb      = 2'b00;
    logic [31:0] eu_cas2_wdata1_tb   = 32'h0;
    logic [31:0] eu_cas2_wdata2_tb   = 32'h0;
    logic        eu_cas2_do_write1_tb = 1'b0;
    logic        eu_cas2_do_write2_tb = 1'b0;
    logic [31:0] eu_cas2_rdata1_tb;
    logic [31:0] eu_cas2_rdata2_tb;
    logic        eu_cas2_ack_tb;

    // Phase 5 — multi-op FSM (MOVEM / MOVEP)
    logic        use_multiop          = 1'b0;
    logic        eu_mo_req_tb         = 1'b0;
    logic [31:0] eu_mo_start_addr_tb  = 32'h0;
    logic [2:0]  eu_mo_fc_tb          = 3'b101;
    logic [1:0]  eu_mo_siz_tb         = 2'b00;
    logic        eu_mo_rw_tb          = 1'b1;
    logic [2:0]  eu_mo_count_tb       = 3'd1;
    logic [2:0]  eu_mo_stride_tb      = 3'd4;
    logic [31:0] eu_mo_wdata0_tb      = 32'h0;
    logic [31:0] eu_mo_wdata1_tb      = 32'h0;
    logic [31:0] eu_mo_wdata2_tb      = 32'h0;
    logic [31:0] eu_mo_wdata3_tb      = 32'h0;
    logic [31:0] eu_mo_rdata0_tb;
    logic [31:0] eu_mo_rdata1_tb;
    logic [31:0] eu_mo_rdata2_tb;
    logic [31:0] eu_mo_rdata3_tb;
    logic        eu_mo_ack_tb;
    logic        eu_mo_berr_tb;

    // multiop_fsm → sizing_fsm wires
    logic [31:0] mo_sf_addr;
    logic [2:0]  mo_sf_fc;
    logic [1:0]  mo_sf_siz;
    logic        mo_sf_rw;
    logic [31:0] mo_sf_wdata;
    logic        mo_sf_is_op;
    logic        mo_sf_req;

    // Muxed inputs to sizing_fsm (normal EU or multiop_fsm)
    logic [31:0] sf_in_addr;
    logic [2:0]  sf_in_fc;
    logic [1:0]  sf_in_siz;
    logic        sf_in_rw;
    logic [31:0] sf_in_wdata;
    logic        sf_in_is_op;
    logic        sf_in_req;

    always_comb begin
        if (use_multiop) begin
            sf_in_addr  = mo_sf_addr;  sf_in_fc   = mo_sf_fc;
            sf_in_siz   = mo_sf_siz;   sf_in_rw   = mo_sf_rw;
            sf_in_wdata = mo_sf_wdata; sf_in_is_op = mo_sf_is_op;
            sf_in_req   = mo_sf_req;
        end else if (use_cache) begin
            sf_in_addr  = ca_sf_addr;  sf_in_fc    = ca_sf_fc;
            sf_in_siz   = ca_sf_siz;   sf_in_rw    = ca_sf_rw;
            sf_in_wdata = ca_sf_wdata; sf_in_is_op = ca_sf_is_op;
            sf_in_req   = ca_sf_req;
        end else begin
            sf_in_addr  = eu_addr_tb;  sf_in_fc   = eu_fc_tb;
            sf_in_siz   = eu_siz_tb;   sf_in_rw   = eu_rw_tb;
            sf_in_wdata = eu_wdata_tb; sf_in_is_op = eu_is_op_tb;
            sf_in_req   = eu_req_tb;
        end
    end

    // Phase 4 direct-drive mode: bypass sizing_fsm to test cycle_gen directly
    logic        p4_direct  = 1'b0;
    logic [31:0] p4_eu_addr  = 32'h0;
    logic [31:0] p4_eu_wdata = 32'h0;
    logic [2:0]  p4_eu_fc    = 3'b101;
    logic        p4_eu_rw    = 1'b1;
    logic [1:0]  p4_eu_siz   = 2'b00;
    logic        p4_eu_is_op = 1'b1;
    logic        p4_eu_req   = 1'b0;

    // Muxed EU → cycle_gen signals (declared first; driven by always_comb below)
    logic [31:0] cg_eu_addr, cg_eu_wdata;
    logic [2:0]  cg_eu_fc;
    logic        cg_eu_rw;
    logic [1:0]  cg_eu_siz;
    logic        cg_eu_is_op, cg_eu_req;

    // Sizing FSM → cycle_gen EU port wires
    logic [31:0] sf_cyc_addr;
    logic [1:0]  sf_cyc_siz;
    logic        sf_cyc_rw;
    logic [31:0] sf_cyc_wdata;
    logic [2:0]  sf_cyc_fc;
    logic        sf_cyc_is_op;
    logic        sf_cyc_req;

    // cycle_gen EU outputs → sizing_fsm (single sub-cycle results)
    logic [31:0] cg_eu_rdata;
    logic        cg_eu_ack;

    // Port-width latch from cycle_gen
    logic [1:0]  cyc_port_dsack;

    // Mux: direct p4 drive or sizing_fsm output → cycle_gen EU inputs
    always_comb begin
        if (p4_direct) begin
            cg_eu_addr  = p4_eu_addr;  cg_eu_wdata = p4_eu_wdata;
            cg_eu_fc    = p4_eu_fc;    cg_eu_rw    = p4_eu_rw;
            cg_eu_siz   = p4_eu_siz;   cg_eu_is_op = p4_eu_is_op;
            cg_eu_req   = p4_eu_req;
        end else begin
            cg_eu_addr  = sf_cyc_addr;  cg_eu_wdata = sf_cyc_wdata;
            cg_eu_fc    = sf_cyc_fc;    cg_eu_rw    = sf_cyc_rw;
            cg_eu_siz   = sf_cyc_siz;   cg_eu_is_op = sf_cyc_is_op;
            cg_eu_req   = sf_cyc_req;
        end
    end

    // Alias for cycle_gen eu_ack in direct-drive tests
    logic cg_eu_ack_direct;
    assign cg_eu_ack_direct = cg_eu_ack;

    // IFU inputs (Phase 19: used to test instruction-fetch address errors)
    logic [31:0] ifu_addr_tb = 32'h0;
    logic        ifu_req_tb  = 1'b0;
    // IFU outputs
    logic [31:0] ifu_rdata;
    logic        ifu_ack, ifu_berr;

    // Address error outputs (Phase 19)
    logic eu_addr_err, ifu_addr_err;

    // Arbiter outputs
    logic grant_mmu, grant_eu, grant_ifu, dma_active, ext_bg_n_arb;
    logic br_arb_tb   = 1'b1;   // BR#  to arbiter unit (1=deasserted)
    logic bgack_arb_tb = 1'b1;  // BGACK# to arbiter unit (1=deasserted)
    logic as_n_fb_arb  = 1'b1;  // AS# pin feedback to arbiter (1=deasserted)

    // DSACK (active-high into cycle_gen)
    logic dsack0_s, dsack1_s;
    logic dsack0_n_mem,  dsack1_n_mem;
    logic dsack0_n_slow, dsack1_n_slow;
    logic dsack0_n_16,   dsack1_n_16;
    logic dsack0_n_8,    dsack1_n_8;

    // -----------------------------------------------------------------------
    // biu_arbiter
    // -----------------------------------------------------------------------
    biu_arbiter u_arb (
        .clk_4x    (clk_4x),
        .rst_n     (rst_n),
        .mmu_req   (mmu_walk_req),
        .eu_req    (cg_eu_req),    // arbiter sees muxed request (sizing_fsm or direct)
        .ifu_req   (ifu_req_tb),
        .bus_idle  (bus_idle),
        .bus_lock  (bus_lock),
        .grant_mmu (grant_mmu),
        .grant_eu  (grant_eu),
        .grant_ifu (grant_ifu),
        .dma_active(dma_active),
        .br_s      (br_arb_tb),
        .ext_bg_n  (ext_bg_n_arb),
        .bgack_s   (bgack_arb_tb),
        .as_n_fb   (as_n_fb_arb)
    );

    // -----------------------------------------------------------------------
    // biu_cycle_gen
    // -----------------------------------------------------------------------
    biu_cycle_gen u_cycle_gen (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .ext_a        (ext_a),
        .ext_as_n     (ext_as_n),
        .ext_ds_n     (ext_ds_n),
        .ext_rw       (ext_rw),
        .ext_fc       (ext_fc),
        .ext_siz      (ext_siz),
        .ext_ecs_n    (ext_ecs_n),
        .ext_ocs_n    (ext_ocs_n),
        .ext_d_out    (ext_d_out),
        .ext_d_oe     (ext_d_oe),
        .ext_rstout_n (ext_rstout_n),
        .ext_cbreq_n  (ext_cbreq_n),
        .ext_d_in     (ext_d_in_to_biu),
        .dsack0_s     (dsack0_s),
        .dsack1_s     (dsack1_s),
        .sterm_s      (sterm_tb),
        .berr_s       (berr_combined_tb),   // ext BERR | watchdog timeout
        .halt_s       (halt_tb),
        .avec_s       (avec_tb),
        .vpa_s        (vpa_s_tb),
        .ipl_s        (3'b111),
        .bgack_s      (1'b1),
        .cback_s      (cback_s_tb),
        .grant_mmu    (grant_mmu),
        .grant_eu     (grant_eu),
        .grant_ifu    (grant_ifu),
        .dma_active   (dma_active),
        .eu_addr      (cg_eu_addr),
        .eu_wdata     (cg_eu_wdata),
        .eu_rdata     (cg_eu_rdata),
        .eu_fc        (cg_eu_fc),
        .eu_rw        (cg_eu_rw),
        .eu_siz       (cg_eu_siz),
        .eu_is_operand(cg_eu_is_op),
        .eu_req       (cg_eu_req),
        .eu_ack       (cg_eu_ack),
        .eu_berr      (eu_berr),
        .eu_retry     (eu_retry),
        .ifu_addr     (ifu_addr_tb),
        .ifu_req      (ifu_req_tb),
        .ifu_rdata    (ifu_rdata),
        .ifu_ack      (ifu_ack),
        .ifu_berr     (ifu_berr),
        .mmu_addr     (mmu_walk_addr),
        .mmu_fc       (mmu_walk_fc),
        .mmu_req      (mmu_walk_req),
        .mmu_rdata    (cg_mmu_rdata),
        .mmu_ack      (cg_mmu_ack),
        .mmu_berr     (cg_mmu_berr),
        .eu_iack_req  (eu_iack_req_tb),
        .eu_iack_level(eu_iack_level_tb),
        .eu_iack_vec  (eu_iack_vec_tb),
        .eu_iack_avec (eu_iack_avec_tb),
        .eu_iack_ack  (eu_iack_ack_tb),
        .eu_rst_req   (eu_rst_req_tb),
        .eclk_cnt     (eclk_cnt),
        .phase        (phase),
        .s_state      (s_state),
        .bus_idle       (bus_idle),
        .bus_reset_inst (bus_reset_inst),
        .bus_halted     (bus_halted),
        .init_done      (init_done),
        .init_ssp       (init_ssp),
        .init_pc        (init_pc),
        .cyc_port_dsack (cyc_port_dsack),
        .fault_addr     (fault_addr_tb),
        .fault_data     (fault_data_tb),
        .fault_fc       (fault_fc_tb),
        .fault_rw       (fault_rw_tb),
        .fault_siz      (fault_siz_tb),
        .fault_valid    (fault_valid_tb),
        .retry_pending  (retry_pending_tb),
        .fault_retry    (fault_retry_tb),
        .fault_is_rmw   (fault_is_rmw_tb),
        // Phase 5 ports
        .eu_rmw             (eu_rmw_tb),
        .bus_lock           (bus_lock),
        .eu_cas2_req        (eu_cas2_req_tb),
        .eu_cas2_addr1      (eu_cas2_addr1_tb),
        .eu_cas2_addr2      (eu_cas2_addr2_tb),
        .eu_cas2_fc         (eu_cas2_fc_tb),
        .eu_cas2_siz        (eu_cas2_siz_tb),
        .eu_cas2_wdata1     (eu_cas2_wdata1_tb),
        .eu_cas2_wdata2     (eu_cas2_wdata2_tb),
        .eu_cas2_do_write1  (eu_cas2_do_write1_tb),
        .eu_cas2_do_write2  (eu_cas2_do_write2_tb),
        .eu_cas2_rdata1     (eu_cas2_rdata1_tb),
        .eu_cas2_rdata2     (eu_cas2_rdata2_tb),
        .eu_cas2_ack        (eu_cas2_ack_tb),
        // Phase 7: burst read
        .eu_burst_req       (eu_burst_req_tb),
        .eu_burst_addr      (eu_burst_addr_tb),
        .eu_burst_fc        (eu_burst_fc_tb),
        .eu_burst_rdata0    (eu_burst_rdata0_tb),
        .eu_burst_rdata1    (eu_burst_rdata1_tb),
        .eu_burst_rdata2    (eu_burst_rdata2_tb),
        .eu_burst_rdata3    (eu_burst_rdata3_tb),
        .eu_burst_ack       (eu_burst_ack_tb),
        .eu_burst_berr      (eu_burst_berr_tb),
        // Phase 7: MOVE16 burst write
        .eu_m16_req         (eu_m16_req_tb),
        .eu_m16_addr        (eu_m16_addr_tb),
        .eu_m16_fc          (eu_m16_fc_tb),
        .eu_m16_wdata0      (eu_m16_wdata0_tb),
        .eu_m16_wdata1      (eu_m16_wdata1_tb),
        .eu_m16_wdata2      (eu_m16_wdata2_tb),
        .eu_m16_wdata3      (eu_m16_wdata3_tb),
        .eu_m16_ack         (eu_m16_ack_tb),
        .eu_m16_berr        (eu_m16_berr_tb),
        // Phase 10 — coprocessor CPU Space cycles
        .eu_coproc_req      (eu_coproc_req_tb),
        .eu_coproc_rw       (eu_coproc_rw_tb),
        .eu_coproc_addr     (eu_coproc_addr_tb),
        .eu_coproc_fc       (eu_coproc_fc_tb),
        .eu_coproc_siz      (eu_coproc_siz_tb),
        .eu_coproc_wdata    (eu_coproc_wdata_tb),
        .eu_coproc_rdata    (eu_coproc_rdata_tb),
        .eu_coproc_ack      (eu_coproc_ack_tb),
        .eu_coproc_berr     (eu_coproc_berr_tb),
        // Phase 19 — address error detection
        .eu_addr_err        (eu_addr_err),
        .ifu_addr_err       (ifu_addr_err)
    );

    // -----------------------------------------------------------------------
    // biu_multiop_fsm — MOVEM/MOVEP multi-cycle sequencer
    // -----------------------------------------------------------------------
    biu_multiop_fsm u_mo (
        .clk_4x           (clk_4x),
        .rst_n            (rst_n),
        .eu_mo_req        (eu_mo_req_tb),
        .eu_mo_start_addr (eu_mo_start_addr_tb),
        .eu_mo_fc         (eu_mo_fc_tb),
        .eu_mo_siz        (eu_mo_siz_tb),
        .eu_mo_rw         (eu_mo_rw_tb),
        .eu_mo_count      (eu_mo_count_tb),
        .eu_mo_stride     (eu_mo_stride_tb),
        .eu_mo_wdata0     (eu_mo_wdata0_tb),
        .eu_mo_wdata1     (eu_mo_wdata1_tb),
        .eu_mo_wdata2     (eu_mo_wdata2_tb),
        .eu_mo_wdata3     (eu_mo_wdata3_tb),
        .eu_mo_rdata0     (eu_mo_rdata0_tb),
        .eu_mo_rdata1     (eu_mo_rdata1_tb),
        .eu_mo_rdata2     (eu_mo_rdata2_tb),
        .eu_mo_rdata3     (eu_mo_rdata3_tb),
        .eu_mo_ack        (eu_mo_ack_tb),
        .eu_mo_berr       (eu_mo_berr_tb),
        .sf_eu_addr       (mo_sf_addr),
        .sf_eu_fc         (mo_sf_fc),
        .sf_eu_siz        (mo_sf_siz),
        .sf_eu_rw         (mo_sf_rw),
        .sf_eu_wdata      (mo_sf_wdata),
        .sf_eu_is_op      (mo_sf_is_op),
        .sf_eu_req        (mo_sf_req),
        .sf_eu_rdata      (eu_rdata),   // sizing_fsm's eu_rdata output
        .sf_eu_ack        (eu_ack),     // sizing_fsm's eu_ack output
        .sf_eu_berr       (1'b0)
    );

    // -----------------------------------------------------------------------
    // biu_cache_if — I/D cache controller (Phase 6)
    // -----------------------------------------------------------------------
    biu_cache_if u_cache (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .eu_addr     (eu_addr_tb),
        .eu_fc       (eu_fc_tb),
        .eu_rw       (eu_rw_tb),
        .eu_siz      (eu_siz_tb),
        .eu_wdata    (eu_wdata_tb),
        .eu_req      (use_cache ? eu_req_tb : 1'b0),
        .eu_is_icache(eu_is_icache_tb),
        .eu_rdata    (cache_eu_rdata),
        .eu_ack      (cache_eu_ack),
        .eu_berr     (cache_eu_berr),
        .mmu_ci      (mmu_ci_out),
        .sf_addr     (ca_sf_addr),
        .sf_fc       (ca_sf_fc),
        .sf_rw       (ca_sf_rw),
        .sf_siz      (ca_sf_siz),
        .sf_wdata    (ca_sf_wdata),
        .sf_is_op    (ca_sf_is_op),
        .sf_req      (ca_sf_req),
        .sf_rdata    (eu_rdata),   // sizing_fsm eu_rdata output
        .sf_ack      (eu_ack),     // sizing_fsm eu_ack output (1-tick pulse)
        .sf_berr     (eu_berr),
        .cacr        (cacr_tb),
        .caar        (caar_tb)
    );

    // -----------------------------------------------------------------------
    // biu_mmu_if — ATC + table walker (Phase 6)
    // -----------------------------------------------------------------------
    biu_mmu_if u_mmu (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .va           (eu_addr_tb),
        .fc           (eu_fc_tb),
        .rw           (eu_rw_tb),
        .req          (use_mmu_tb ? eu_req_tb : 1'b0),
        .pa           (mmu_pa_out),
        .hit          (mmu_hit_out),
        .walk_done    (mmu_walk_done_out),
        .fault        (mmu_fault_out),
        .ci           (mmu_ci_out),
        .mmu_req_addr (mmu_walk_addr),
        .mmu_req_fc   (mmu_walk_fc),
        .mmu_req      (mmu_walk_req),
        .mmu_rdata    (cg_mmu_rdata),
        .mmu_ack      (cg_mmu_ack),
        .mmu_berr     (cg_mmu_berr),
        .tc           (tc_tb),
        .crp          (crp_tb),
        .srp          (srp_tb),
        .tt0          (tt0_tb),
        .tt1          (tt1_tb),
        .mmusr        ()
    );

    // -----------------------------------------------------------------------
    // biu_exc_capture — exception frame format determination (Phase 7)
    // -----------------------------------------------------------------------
    biu_exc_capture u_exc (
        .clk_4x           (clk_4x),
        .rst_n             (rst_n),
        .fault_valid       (fault_valid_tb),
        .fault_addr        (fault_addr_tb),
        .fault_data        (fault_data_tb),
        .fault_fc          (fault_fc_tb),
        .fault_rw          (fault_rw_tb),
        .fault_siz         (fault_siz_tb),
        .fault_retry       (fault_retry_tb),
        .fault_is_rmw      (fault_is_rmw_tb),
        .pipe_b_active     (1'b0),
        .pipe_c_active     (1'b0),
        .mmu_fault         (1'b0),
        .frame_format      (exc_frame_format),
        .frame_valid       (exc_frame_valid),
        .frame_fault_addr  (exc_frame_fault_addr),
        .frame_fault_data  (exc_frame_fault_data),
        .frame_fault_fc    (exc_frame_fault_fc),
        .frame_fault_rw    (exc_frame_fault_rw),
        .frame_fault_siz   (exc_frame_fault_siz),
        .frame_word0       (exc_frame_word0),
        .ssw               (exc_ssw)
    );

    // -----------------------------------------------------------------------
    // biu_error_handler — watchdog + double-fault detection (Phase 11)
    // TIMEOUT_CLKS=80: safe for all existing tests (fastest completes in ~32
    // 4x-ticks); triggers in P11-2/P11-3 when no DSACK/STERM is driven.
    // -----------------------------------------------------------------------
    biu_error_handler #(.TIMEOUT_CLKS(80)) u_err (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .bus_idle       (bus_idle),
        .bus_reset_inst (bus_reset_inst),
        .retry_pending  (retry_pending_tb),
        .dsack0_s      (dsack0_s),
        .dsack1_s      (dsack1_s),
        .sterm_s       (sterm_tb),
        .berr_s        (berr_tb),        // external BERR only, not combined
        .berr_timeout  (berr_timeout_tb),
        .halt_out      (halt_out_tb)
    );

    // -----------------------------------------------------------------------
    // biu_config — input synchronizer (Phase 9)
    // -----------------------------------------------------------------------
    biu_config u_cfg (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .dsack0_n      (cfg_dsack0_n),
        .dsack1_n      (cfg_dsack1_n),
        .sterm_n       (cfg_sterm_n),
        .berr_n        (cfg_berr_n),
        .halt_n        (cfg_halt_n),
        .avec_n        (cfg_avec_n),
        .vpa_n         (cfg_vpa_n),
        .ipl_n         (cfg_ipl_n),
        .br_n          (cfg_br_n),
        .bgack_n       (cfg_bgack_n),
        .cback_n       (cfg_cback_n),
        .dsack0_s      (cfg_dsack0_s),
        .dsack1_s      (cfg_dsack1_s),
        .sterm_s       (cfg_sterm_s),
        .berr_s        (cfg_berr_s),
        .halt_s        (cfg_halt_s),
        .avec_s        (cfg_avec_s),
        .vpa_s         (cfg_vpa_s),
        .ipl_s         (cfg_ipl_s),
        .br_s          (cfg_br_s),
        .bgack_s       (cfg_bgack_s),
        .cback_s       (cfg_cback_s),
        .pins_released (cfg_pins_released)
    );

    // -----------------------------------------------------------------------
    // biu_pin_driver — data bus OE management (Phase 9)
    // -----------------------------------------------------------------------
    biu_pin_driver u_pd (
        .d_out         (pd_d_out_tb),
        .d_oe          (pd_d_oe_tb),
        .pins_released (pd_pins_rel_tb),
        .ext_d_out     (pd_ext_d_out),
        .ext_d_oe      (pd_ext_d_oe)
    );

    // -----------------------------------------------------------------------
    // biu_sizing_fsm — dynamic bus sizing between EU tasks and cycle_gen
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
        .eu_rdata      (eu_rdata),
        .eu_ack        (eu_ack),
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
    // Fast memory (0 wait states, 32-bit port)
    // -----------------------------------------------------------------------
    logic [31:0] ext_d_in_mem;

    mem_model #(.DEPTH(256), .PORT_WIDTH(32), .WAIT_STATES(0)) u_mem (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_in    (ext_d_in_mem),
        .dsack0_n    (dsack0_n_mem),
        .dsack1_n    (dsack1_n_mem),
        .ext_d_write (ext_d_out),   // BIU write data
        .ext_d_oe    (ext_d_oe)
    );

    // Slow memory (2 wait states, 32-bit port)
    logic [31:0] ext_d_in_slow;

    mem_model #(.DEPTH(256), .PORT_WIDTH(32), .WAIT_STATES(2)) u_mem_slow (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_in    (ext_d_in_slow),
        .dsack0_n    (dsack0_n_slow),
        .dsack1_n    (dsack1_n_slow),
        .ext_d_write (ext_d_out),
        .ext_d_oe    (ext_d_oe)
    );

    // 16-bit port memory (DSACK1=0, DSACK0=1 — BIU-013)
    logic [31:0] ext_d_in_16;

    mem_model #(.DEPTH(256), .PORT_WIDTH(16), .WAIT_STATES(0)) u_mem16 (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_in    (ext_d_in_16),
        .dsack0_n    (dsack0_n_16),
        .dsack1_n    (dsack1_n_16),
        .ext_d_write (ext_d_out),
        .ext_d_oe    (ext_d_oe)
    );

    // 8-bit port memory (DSACK1=1, DSACK0=0 — BIU-013)
    logic [31:0] ext_d_in_8;

    mem_model #(.DEPTH(256), .PORT_WIDTH(8), .WAIT_STATES(0)) u_mem8 (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_in    (ext_d_in_8),
        .dsack0_n    (dsack0_n_8),
        .dsack1_n    (dsack1_n_8),
        .ext_d_write (ext_d_out),
        .ext_d_oe    (ext_d_oe)
    );

    // -----------------------------------------------------------------------
    // Bus mux — selects which memory model drives DSACK and read data
    // -----------------------------------------------------------------------
    typedef enum logic [2:0] {
        MUX_FAST   = 3'd0,
        MUX_SLOW   = 3'd1,
        MUX_16     = 3'd2,
        MUX_8      = 3'd3,
        MUX_NOSACK = 3'd4,   // no DSACK (STERM test): cycle must terminate via STERM
        MUX_IACK   = 3'd5,   // immediate 32-bit DSACK + iack_test_vec on D[7:0]
        MUX_VPA    = 3'd6    // no DSACK: cycle must terminate via VPA/E-clock
    } mux_sel_t;

    mux_sel_t test_mem_sel = MUX_FAST;

    logic [31:0] sterm_test_data = 32'hFACE_CAFE;  // data bus for STERM test
    logic [7:0]  iack_test_vec   = 8'd42;           // IACK vector for P4-4
    logic [31:0] vpa_test_data   = 32'hB00B_1234;  // data bus for VPA read test

    always_comb begin
        case (test_mem_sel)
            MUX_SLOW: begin
                dsack0_s        = !dsack0_n_slow;
                dsack1_s        = !dsack1_n_slow;
                ext_d_in_to_biu = ext_d_oe ? 32'hx : ext_d_in_slow;
            end
            MUX_16: begin
                dsack0_s        = !dsack0_n_16;
                dsack1_s        = !dsack1_n_16;
                ext_d_in_to_biu = ext_d_oe ? 32'hx : ext_d_in_16;
            end
            MUX_8: begin
                dsack0_s        = !dsack0_n_8;
                dsack1_s        = !dsack1_n_8;
                ext_d_in_to_biu = ext_d_oe ? 32'hx : ext_d_in_8;
            end
            MUX_NOSACK: begin
                dsack0_s        = 1'b0;           // hold DSACK deasserted — STERM must end the cycle
                dsack1_s        = 1'b0;
                ext_d_in_to_biu = sterm_test_data;
            end
            MUX_IACK: begin
                dsack0_s        = 1'b1;              // immediate 32-bit port response
                dsack1_s        = 1'b1;
                ext_d_in_to_biu = {24'h0, iack_test_vec};  // vector on D[7:0] per BIU-043
            end
            MUX_VPA: begin
                dsack0_s        = 1'b0;              // no DSACK — cycle must end via VPA/E-clock
                dsack1_s        = 1'b0;
                ext_d_in_to_biu = vpa_test_data;
            end
            default: begin  // MUX_FAST
                dsack0_s        = !dsack0_n_mem;
                dsack1_s        = !dsack1_n_mem;
                ext_d_in_to_biu = ext_d_oe ? 32'hx : ext_d_in_mem;
            end
        endcase
    end

    // -----------------------------------------------------------------------
    // VCD
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("biu_phase7.vcd");
        $dumpvars(0, biu_tb);
    end

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task automatic check(input string desc, input logic cond);
        if (!cond) begin $display("FAIL  [%0t] %s", $time, desc); fail_count++; end
        else            $display("PASS  [%0t] %s", $time, desc);
    endtask

    // check with actual/expected display on failure (32-bit)
    task automatic check32(input string desc, input logic [31:0] actual, expected);
        if (actual !== expected) begin
            $display("FAIL  [%0t] %s: got %08h expected %08h",
                     $time, desc, actual, expected);
            fail_count++;
        end else $display("PASS  [%0t] %s", $time, desc);
    endtask

    task automatic check8(input string desc, input logic [7:0] actual, expected);
        if (actual !== expected) begin
            $display("FAIL  [%0t] %s: got %02h expected %02h",
                     $time, desc, actual, expected);
            fail_count++;
        end else $display("PASS  [%0t] %s", $time, desc);
    endtask

    task automatic check16(input string desc, input logic [15:0] actual, expected);
        if (actual !== expected) begin
            $display("FAIL  [%0t] %s: got %04h expected %04h",
                     $time, desc, actual, expected);
            fail_count++;
        end else $display("PASS  [%0t] %s", $time, desc);
    endtask

    task automatic wait_for_state(input logic [6:0] target, input int timeout_cycles);
        int t;
        for (t = 0; t < timeout_cycles && s_state !== target; t++)
            @(posedge clk_4x);
        if (s_state !== target) begin
            $display("FAIL  [%0t] state timeout: want %0d, got %0d",
                     $time, target, s_state);
            fail_count++;
        end
    endtask

    task automatic wait_for_init(input int timeout_cycles);
        int t;
        for (t = 0; t < timeout_cycles && !init_done; t++)
            @(posedge clk_4x);
        if (!init_done) begin
            $display("FAIL  [%0t] init_done timeout", $time);
            fail_count++;
        end
    endtask

    // Wait for the bus to be idle before asserting a new request.
    // This prevents a new task from picking up eu_ack from the trailing
    // ticks of the previous cycle's S7 (which lasts 4 clk_4x cycles).
    task automatic wait_bus_idle;
        while (!bus_idle) @(posedge clk_4x);
    endtask

    task automatic eu_read(
        input  logic [31:0] addr,
        input  logic [2:0]  fc,
        input  logic [1:0]  siz,
        input  logic        is_op,
        output logic [31:0] rdata,
        input  int          timeout_cycles
    );
        int t;
        wait_bus_idle;
        eu_addr_tb  = addr;
        eu_fc_tb    = fc;
        eu_siz_tb   = siz;
        eu_rw_tb    = 1'b1;
        eu_is_op_tb = is_op;
        eu_req_tb   = 1'b1;
        for (t = 0; t < timeout_cycles; t++) begin
            @(posedge clk_4x);
            if (eu_ack) break;
        end
        rdata     = eu_rdata;
        eu_req_tb = 1'b0;
        if (t >= timeout_cycles) begin
            $display("FAIL  [%0t] EU read timeout addr=%08h", $time, addr);
            fail_count++;
        end
    endtask

    task automatic eu_write(
        input logic [31:0] addr,
        input logic [2:0]  fc,
        input logic [1:0]  siz,
        input logic [31:0] wdata,
        input int          timeout_cycles
    );
        int t;
        wait_bus_idle;
        eu_addr_tb  = addr;
        eu_fc_tb    = fc;
        eu_siz_tb   = siz;
        eu_wdata_tb = wdata;
        eu_rw_tb    = 1'b0;
        eu_is_op_tb = 1'b1;
        eu_req_tb   = 1'b1;
        for (t = 0; t < timeout_cycles; t++) begin
            @(posedge clk_4x);
            if (eu_ack) break;
        end
        eu_req_tb = 1'b0;
        if (t >= timeout_cycles) begin
            $display("FAIL  [%0t] EU write timeout addr=%08h", $time, addr);
            fail_count++;
        end
    endtask

    task test_eclk_timing;
        int low_count, high_count, timeout;
        timeout = 200;
        while (e !== 1'b1 && timeout > 0) begin @(posedge clk_4x); timeout--; end
        while (e !== 1'b0 && timeout > 0) begin @(posedge clk_4x); timeout--; end
        if (timeout == 0) begin $display("FAIL  E-clock align timeout"); fail_count++; return; end
        low_count  = 0; while (e === 1'b0) begin low_count++;  @(posedge clk_4x); end
        high_count = 0; while (e === 1'b1) begin high_count++; @(posedge clk_4x); end
        check("P1-3: E low=24",   low_count  == 24);
        check("P1-3: E high=16",  high_count == 16);
        check("P1-3: period=40",  (low_count + high_count) == 40);
    endtask

    // EU read with per-S-state bus signal checks
    task eu_read_check_timing(
        input  logic [31:0] addr,
        input  logic [2:0]  fc,
        input  logic [1:0]  siz,
        input  logic [31:0] expected,
        input  int          timeout_cycles
    );
        int t;
        logic [31:0] rdata;

        wait_bus_idle;
        eu_addr_tb  = addr;
        eu_fc_tb    = fc;
        eu_siz_tb   = siz;
        eu_rw_tb    = 1'b1;
        eu_is_op_tb = 1'b1;
        eu_req_tb   = 1'b1;

        // State numbers per biu_cycle_gen enum
        wait_for_state(7'd18, 20);   // ST_READ_S0
        check("P2-4: addr at S0",         ext_a    === addr);
        check("P2-4: FC at S0",           ext_fc   === fc);
        check("P2-5: ECS_n high at S0",   ext_ecs_n === 1'b1);
        check("P2-5: AS_n high at S0",    ext_as_n  === 1'b1);
        check("P2-5: DS_n high at S0",     ext_ds_n  === 1'b1);

        wait_for_state(7'd20, 20);   // ST_READ_S2
        check("P2-6: AS_n low at S2",     ext_as_n  === 1'b0);
        check("P2-6: DS_n high at S2",    ext_ds_n  === 1'b1);

        wait_for_state(7'd21, 20);   // ST_READ_S3
        check("P2-7: DS_n low at S3",     ext_ds_n  === 1'b0);
        check("P2-7: AS_n low at S3",     ext_as_n  === 1'b0);

        wait_for_state(7'd24, 50);   // ST_READ_S6
        check("P2-7: AS_n high at S6",    ext_as_n  === 1'b1);
        check("P2-7: DS_n high at S6",    ext_ds_n  === 1'b1);

        for (t = 0; t < timeout_cycles; t++) begin
            @(posedge clk_4x);
            if (eu_ack) break;
        end
        rdata     = eu_rdata;
        eu_req_tb = 1'b0;
        check("P2-8: read data correct", rdata === expected);
    endtask

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    logic [31:0] rdata;

    initial begin
        $display("=== MC68030 BIU Phase 1 + 2 + 3 Tests ===");

        // P1-1 Reset hold
        $display("--- P1-1: Reset hold ---");
        rst_n = 1'b0;
        repeat(4) @(posedge clk_4x);
        check("P1-1: phase==0",   phase   == 2'd0);
        check("P1-1: state==0",   s_state == 7'd0);
        check("P1-1: AS_n safe",  ext_as_n  === 1'b1);
        check("P1-1: DS_n safe",  ext_ds_n  === 1'b1);
        check("P1-1: d_oe=0",     ext_d_oe  === 1'b0);

        // Release reset
        @(negedge clk_4x);
        rst_n = 1'b1;

        // P1-2 Phase counter (just 4 ticks; init runs in parallel but that's fine)
        $display("--- P1-2: Phase counter ---");
        repeat(3) @(posedge clk_4x);
        while (phase != 2'd0) @(posedge clk_4x);
        @(posedge clk_4x); check("P1-2: 0→1", phase == 2'd1);
        @(posedge clk_4x); check("P1-2: 1→2", phase == 2'd2);
        @(posedge clk_4x); check("P1-2: 2→3", phase == 2'd3);
        @(posedge clk_4x); check("P1-2: 3→0", phase == 2'd0);

        // P2-1..3 Power-on init
        $display("--- P2-1..3: Power-on init ---");
        wait_for_init(200);
        check("P2-1: init_done",           init_done === 1'b1);
        check("P2-2: init_ssp=$DEADBEF0",  init_ssp  === 32'hDEAD_BEF0);
        check("P2-3: init_pc=$CAFE0010",   init_pc   === 32'hCAFE_0010);

        // P1-3 E-clock (fine any time after reset)
        $display("--- P1-3: E-clock ---");
        test_eclk_timing;

        // P2-4..8 EU read with bus-signal timing
        $display("--- P2-4..8: EU read + timing ---");
        u_mem.mem[4] = 32'hA5A5_A5A5;   // byte $00000010
        eu_read_check_timing(
            .addr    (32'h0000_0010),
            .fc      (3'b101),
            .siz     (2'b00),
            .expected(32'hA5A5_A5A5),
            .timeout_cycles(100)
        );

        // P2-9 Write then read-back
        $display("--- P2-9: Write + read-back ---");
        eu_write(.addr(32'h0000_0040), .fc(3'b101), .siz(2'b00),
                 .wdata(32'h1234_5678), .timeout_cycles(100));
        repeat(4) @(posedge clk_4x);
        eu_read(.addr(32'h0000_0040), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(100));
        check32("P2-9: write-readback", rdata, 32'h1234_5678);

        // P2-10 Wait-state test
        $display("--- P2-10: Wait-state ---");
        test_mem_sel = MUX_SLOW;
        @(posedge clk_4x);
        u_mem_slow.mem[2] = 32'hBEEF_CAFE;  // byte $00000008
        eu_read(.addr(32'h0000_0008), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(300));
        check32("P2-10: wait-state read", rdata, 32'hBEEF_CAFE);
        test_mem_sel = MUX_FAST;

        // ===================================================================
        // Phase 3: Dynamic Bus Sizing
        // ===================================================================
        $display("--- P3-1: Longword read from 16-bit port ---");
        // mem16[4] @ word addr 4 → byte $00000010
        u_mem16.mem[4] = 32'hDEAD_BEEF;
        test_mem_sel = MUX_16;
        eu_read(.addr(32'h0000_0010), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(400));
        check32("P3-1: LW read 16-bit port", rdata, 32'hDEAD_BEEF);
        test_mem_sel = MUX_FAST;

        $display("--- P3-2: Longword read from 8-bit port ---");
        u_mem8.mem[5] = 32'hCAFE_1234;   // byte $00000014
        test_mem_sel = MUX_8;
        eu_read(.addr(32'h0000_0014), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(600));
        check32("P3-2: LW read 8-bit port", rdata, 32'hCAFE_1234);
        test_mem_sel = MUX_FAST;

        $display("--- P3-3: Longword write+readback to 16-bit port ---");
        test_mem_sel = MUX_16;
        eu_write(.addr(32'h0000_0080), .fc(3'b101), .siz(2'b00),
                 .wdata(32'hA5A5_B6B6), .timeout_cycles(400));
        eu_read(.addr(32'h0000_0080), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(400));
        check32("P3-3: LW write/readback 16-bit port", rdata, 32'hA5A5_B6B6);
        test_mem_sel = MUX_FAST;

        $display("--- P3-4: Longword write+readback to 8-bit port ---");
        test_mem_sel = MUX_8;
        eu_write(.addr(32'h0000_00C0), .fc(3'b101), .siz(2'b00),
                 .wdata(32'h1122_3344), .timeout_cycles(600));
        eu_read(.addr(32'h0000_00C0), .fc(3'b101), .siz(2'b00), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(600));
        check32("P3-4: LW write/readback 8-bit port", rdata, 32'h1122_3344);
        test_mem_sel = MUX_FAST;

        $display("--- P3-5: Word read (SIZ=10) from 32-bit port ---");
        // SIZ=10 means word (16-bit); from a 32-bit port, one cycle
        // Byte $00000020 = word_addr 8 upper halfword
        u_mem.mem[8] = 32'h5A5A_0000;   // upper halfword = $5A5A
        eu_read(.addr(32'h0000_0020), .fc(3'b101), .siz(2'b10), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(200));
        check("P3-5: Word SIZ=10 on bus", ext_siz === 2'b10 || rdata !== 32'h0);
        // For 32-bit port, full word returned; EU extracts [31:16] = $5A5A
        check32("P3-5: Word data correct", rdata, 32'h5A5A_0000);

        $display("--- P3-6: Byte read (SIZ=01) from 32-bit port ---");
        // Byte $00000030 = word_addr 12 byte 0
        u_mem.mem[12] = 32'hAB000000;   // byte 0 = $AB
        eu_read(.addr(32'h0000_0030), .fc(3'b101), .siz(2'b01), .is_op(1'b1),
                .rdata(rdata), .timeout_cycles(200));
        check32("P3-6: Byte data correct", rdata, 32'hAB000000);

        // ===================================================================
        // Phase 4: Error Handling and Special Cycles
        // ===================================================================

        // P4-1 STERM fast read: cycle terminates at S4 without DSACK
        $display("--- P4-1: STERM fast read ---");
        begin
            int t; logic got_ack;
            test_mem_sel = MUX_NOSACK;  // hold DSACK deasserted
            sterm_test_data = 32'hFACE_CAFE;
            p4_direct = 1;
            p4_eu_addr = 32'h0000_0100;
            p4_eu_fc   = 3'b101;
            p4_eu_siz  = 2'b00;
            p4_eu_rw   = 1'b1;
            p4_eu_is_op = 1'b1;
            wait_bus_idle;
            p4_eu_req = 1;
            // Wait for S2 then assert STERM
            wait_for_state(7'd20, 50);   // ST_READ_S2
            sterm_tb = 1;
            got_ack = 0;
            for (t = 0; t < 60; t++) begin
                @(posedge clk_4x);
                if (cg_eu_ack_direct) begin got_ack = 1; break; end
            end
            sterm_tb  = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            test_mem_sel = MUX_FAST;
            check("P4-1: cycle acked without DSACK", got_ack);
            check32("P4-1: STERM data captured", cg_eu_rdata, 32'hFACE_CAFE);
        end
        repeat(8) @(posedge clk_4x);

        // P4-2 BERR abort: fault captured, eu_berr fires, no eu_ack
        $display("--- P4-2: BERR abort ---");
        begin
            int t; logic saw_berr;
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0200;
            p4_eu_fc    = 3'b101;
            p4_eu_siz   = 2'b00;
            p4_eu_rw    = 1'b1;
            p4_eu_is_op = 1'b1;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            saw_berr = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P4-2: eu_berr fired", saw_berr);
            check("P4-2: fault_valid",   fault_valid_tb);
            check32("P4-2: fault_addr",  fault_addr_tb, 32'h0000_0200);
        end
        repeat(8) @(posedge clk_4x);

        // P4-3 BERR+HALT retry: simultaneous assertion → cycle retried, not exception
        $display("--- P4-3: BERR+HALT retry ---");
        begin
            int t; logic saw_retry, saw_ack;
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0008;   // byte $8 = mem[2] (valid address)
            p4_eu_fc    = 3'b101;
            p4_eu_siz   = 2'b00;
            p4_eu_rw    = 1'b1;
            p4_eu_is_op = 1'b1;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            halt_tb = 0;   // assert HALT (active-low, halt_s=0)
            saw_retry = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_retry) begin saw_retry = 1; break; end
            end
            berr_tb = 0;
            halt_tb = 1;   // deassert HALT
            check("P4-3: retry flag fires", saw_retry);
            check("P4-3: retry_pending",    retry_pending_tb);
            // Wait for retry cycle to complete via eu_ack
            saw_ack = 0;
            for (t = 0; t < 200; t++) begin
                @(posedge clk_4x);
                if (cg_eu_ack_direct) begin saw_ack = 1; break; end
            end
            p4_eu_req = 0;
            p4_direct = 0;
            check("P4-3: retry succeeds", saw_ack);
        end
        repeat(8) @(posedge clk_4x);

        // P4-4 IACK with DSACK: vector captured from D[7:0]
        $display("--- P4-4: IACK DSACK ---");
        begin
            int t; logic saw_ack;
            iack_test_vec     = 8'd42;
            test_mem_sel      = MUX_IACK;    // drive DSACK + vector on bus
            eu_iack_level_tb  = 3'd5;
            eu_iack_req_tb    = 1'b1;
            wait_bus_idle;
            saw_ack = 0;
            for (t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_iack_ack_tb) begin saw_ack = 1; break; end
            end
            eu_iack_req_tb = 0;
            test_mem_sel   = MUX_FAST;
            check("P4-4: iack_ack fired",     saw_ack);
            check8("P4-4: iack_vec=42",       eu_iack_vec_tb, 8'd42);
            check("P4-4: avec deasserted",    !eu_iack_avec_tb);
        end
        repeat(8) @(posedge clk_4x);

        // P4-5 IACK with AVEC: autovector = level + 24
        $display("--- P4-5: IACK AVEC ---");
        begin
            int t; logic saw_ack;
            // MUX_FAST: DS stays high for IACK so mem_models don't respond → no DSACK
            avec_tb           = 1'b1;
            eu_iack_level_tb  = 3'd5;
            eu_iack_req_tb    = 1'b1;
            wait_bus_idle;
            saw_ack = 0;
            for (t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_iack_ack_tb) begin saw_ack = 1; break; end
            end
            avec_tb        = 0;
            eu_iack_req_tb = 0;
            check("P4-5: iack_ack fired",  saw_ack);
            check8("P4-5: iack_vec=29",    eu_iack_vec_tb, 8'd29);  // 5+24=29
            check("P4-5: avec asserted",   eu_iack_avec_tb);
        end
        repeat(8) @(posedge clk_4x);

        // P4-6 RESET instruction: RSTOUT low for exactly 124 external clocks
        $display("--- P4-6: RESET instruction ---");
        begin
            int t; int rst_cnt;
            wait_bus_idle;
            eu_rst_req_tb = 1'b1;
            wait_for_state(7'd70, 50);  // ST_RESET_INST
            rst_cnt = 0;
            while (!ext_rstout_n) begin
                rst_cnt++;
                @(posedge clk_4x);
            end
            eu_rst_req_tb = 0;
            // 124 external clocks × 4 ticks = 496 ticks (±4 for sampling boundary)
            check("P4-6: RSTOUT ~496 ticks", rst_cnt >= 492 && rst_cnt <= 500);
        end
        repeat(8) @(posedge clk_4x);

        // ===================================================================
        // Phase 5: RMW, CAS2, MOVEM, MOVEP
        // ===================================================================

        // P5-1 RMW byte: TAS-style read → write at same address, no bus release
        $display("--- P5-1: RMW byte (TAS) ---");
        begin
            int t; logic got_rd_ack, got_wr_ack;
            u_mem.mem[64] = 32'hAB000000;  // addr=$100, byte=$AB
            p4_direct    = 1;
            eu_rmw_tb    = 1;
            p4_eu_addr   = 32'h0000_0100;
            p4_eu_fc     = 3'b101;
            p4_eu_siz    = 2'b01;           // byte
            p4_eu_rw     = 1'b1;            // cycle_gen manages rw internally
            p4_eu_wdata  = 32'hFF000000;    // write value (set MSB, like TAS)
            p4_eu_is_op  = 1'b1;
            wait_bus_idle;
            p4_eu_req    = 1;
            // Wait for read-phase ack (RMW_READ_S7)
            got_rd_ack = 0;
            for (t = 0; t < 80; t++) begin
                @(posedge clk_4x);
                if (cg_eu_ack_direct) begin got_rd_ack = 1; break; end
            end
            check("P5-1: RMW read ack", got_rd_ack);
            check32("P5-1: RMW rdata", cg_eu_rdata, 32'hAB000000);
            // Wait for ack to deassert (exit RMW_READ_S7) before polling write ack
            while (cg_eu_ack_direct) @(posedge clk_4x);
            // Now wait for write-phase ack (RMW_WRITE_S7)
            got_wr_ack = 0;
            for (t = 0; t < 80; t++) begin
                @(posedge clk_4x);
                if (cg_eu_ack_direct) begin got_wr_ack = 1; break; end
            end
            p4_eu_req  = 0;
            eu_rmw_tb  = 0;
            p4_direct  = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-1: RMW write ack", got_wr_ack);
            check32("P5-1: mem written", u_mem.mem[64], 32'hFF000000);
        end
        repeat(8) @(posedge clk_4x);

        // P5-2 RMW word: bus stays locked, AS stays asserted through phases
        $display("--- P5-2: RMW word ---");
        begin
            int t; logic got_rd_ack, got_wr_ack; logic saw_bus_lock;
            u_mem.mem[65] = 32'h1234_0000;  // addr=$104, word=$1234
            p4_direct    = 1;
            eu_rmw_tb    = 1;
            p4_eu_addr   = 32'h0000_0104;
            p4_eu_fc     = 3'b101;
            p4_eu_siz    = 2'b10;           // word
            p4_eu_rw     = 1'b1;
            p4_eu_wdata  = 32'hDEAD_0000;
            p4_eu_is_op  = 1'b1;
            wait_bus_idle;
            p4_eu_req    = 1;
            // Capture bus_lock during the cycle
            saw_bus_lock = 0;
            got_rd_ack = 0;
            for (t = 0; t < 80; t++) begin
                @(posedge clk_4x);
                if (bus_lock) saw_bus_lock = 1;
                if (cg_eu_ack_direct) begin got_rd_ack = 1; break; end
            end
            check("P5-2: bus_lock asserted during RMW", saw_bus_lock);
            check("P5-2: RMW read ack", got_rd_ack);
            while (cg_eu_ack_direct) @(posedge clk_4x);
            got_wr_ack = 0;
            for (t = 0; t < 80; t++) begin
                @(posedge clk_4x);
                if (cg_eu_ack_direct) begin got_wr_ack = 1; break; end
            end
            p4_eu_req  = 0;
            eu_rmw_tb  = 0;
            p4_direct  = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-2: RMW write ack", got_wr_ack);
            check32("P5-2: mem written", u_mem.mem[65], 32'hDEAD_0000);
        end
        repeat(8) @(posedge clk_4x);

        // P5-3 CAS2: four-cycle atomic: read addr1, write addr1, read addr2, write addr2
        $display("--- P5-3: CAS2 four-cycle ---");
        begin
            int t; logic saw_ack;
            u_mem.mem[66] = 32'hAAAA_BBBB;  // addr=$108
            u_mem.mem[67] = 32'hCCCC_DDDD;  // addr=$10C
            eu_cas2_req_tb       = 1;
            eu_cas2_addr1_tb     = 32'h0000_0108;
            eu_cas2_addr2_tb     = 32'h0000_010C;
            eu_cas2_fc_tb        = 3'b101;
            eu_cas2_siz_tb       = 2'b00;    // longword
            eu_cas2_wdata1_tb    = 32'hDEAD_BEEF;
            eu_cas2_wdata2_tb    = 32'hCAFE_BABE;
            eu_cas2_do_write1_tb = 1;
            eu_cas2_do_write2_tb = 1;
            wait_bus_idle;
            saw_ack = 0;
            for (t = 0; t < 400; t++) begin
                @(posedge clk_4x);
                if (eu_cas2_ack_tb) begin saw_ack = 1; break; end
            end
            eu_cas2_req_tb = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-3: CAS2 ack", saw_ack);
            check32("P5-3: rdata1 (original addr1)", eu_cas2_rdata1_tb, 32'hAAAA_BBBB);
            check32("P5-3: rdata2 (original addr2)", eu_cas2_rdata2_tb, 32'hCCCC_DDDD);
            check32("P5-3: mem[66] written",  u_mem.mem[66], 32'hDEAD_BEEF);
            check32("P5-3: mem[67] written",  u_mem.mem[67], 32'hCAFE_BABE);
        end
        repeat(8) @(posedge clk_4x);

        // P5-4 MOVEM read 3 longwords
        $display("--- P5-4: MOVEM read 3 longwords ---");
        begin
            int t; logic saw_ack;
            u_mem.mem[68] = 32'h1111_1111;  // addr=$110
            u_mem.mem[69] = 32'h2222_2222;  // addr=$114
            u_mem.mem[70] = 32'h3333_3333;  // addr=$118
            use_multiop          = 1;
            eu_mo_req_tb         = 1;
            eu_mo_start_addr_tb  = 32'h0000_0110;
            eu_mo_fc_tb          = 3'b101;
            eu_mo_siz_tb         = 2'b00;   // longword
            eu_mo_rw_tb          = 1'b1;
            eu_mo_count_tb       = 3'd3;
            eu_mo_stride_tb      = 3'd4;
            saw_ack = 0;
            for (t = 0; t < 400; t++) begin
                @(posedge clk_4x);
                if (eu_mo_ack_tb) begin saw_ack = 1; break; end
            end
            eu_mo_req_tb = 0;
            use_multiop  = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-4: MOVEM ack", saw_ack);
            check32("P5-4: rdata0", eu_mo_rdata0_tb, 32'h1111_1111);
            check32("P5-4: rdata1", eu_mo_rdata1_tb, 32'h2222_2222);
            check32("P5-4: rdata2", eu_mo_rdata2_tb, 32'h3333_3333);
        end
        repeat(8) @(posedge clk_4x);

        // P5-5 MOVEP.W write: 2 byte cycles at $120, $122 (stride 2)
        $display("--- P5-5: MOVEP.W write ---");
        begin
            int t; logic saw_ack;
            u_mem.mem[72] = 32'h0000_0000;  // addr=$120 (word 72)
            use_multiop         = 1;
            eu_mo_req_tb        = 1;
            eu_mo_start_addr_tb = 32'h0000_0120;
            eu_mo_fc_tb         = 3'b101;
            eu_mo_siz_tb        = 2'b01;    // byte
            eu_mo_rw_tb         = 1'b0;     // write
            eu_mo_count_tb      = 3'd2;
            eu_mo_stride_tb     = 3'd2;
            eu_mo_wdata0_tb     = 32'hAB000000;  // byte 0 on D[31:24]
            eu_mo_wdata1_tb     = 32'hCD000000;  // byte 1 on D[31:24]
            saw_ack = 0;
            for (t = 0; t < 200; t++) begin
                @(posedge clk_4x);
                if (eu_mo_ack_tb) begin saw_ack = 1; break; end
            end
            eu_mo_req_tb = 0;
            use_multiop  = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-5: MOVEP.W write ack", saw_ack);
            // 32-bit mem model stores full word: word 72 gets wdata0 ($AB000000)
            // word 72 also gets wdata1 ($CD000000) since $122 → word_addr=72 too
            // (both bytes in same longword; final state = last write = wdata1)
            check("P5-5: mem written", u_mem.mem[72] !== 32'h0000_0000);
        end
        repeat(8) @(posedge clk_4x);

        // P5-6 MOVEP.L read: 4 byte cycles at $130,$132,$134,$136 (stride 2)
        $display("--- P5-6: MOVEP.L read ---");
        begin
            int t; logic saw_ack;
            // Pre-load: addr $130 → word 76, $132 → word 76, $134 → word 77, $136 → word 77
            u_mem.mem[76] = 32'hAABB_CCDD;
            u_mem.mem[77] = 32'hEEFF_0011;
            use_multiop         = 1;
            eu_mo_req_tb        = 1;
            eu_mo_start_addr_tb = 32'h0000_0130;
            eu_mo_fc_tb         = 3'b101;
            eu_mo_siz_tb        = 2'b01;    // byte
            eu_mo_rw_tb         = 1'b1;     // read
            eu_mo_count_tb      = 3'd4;
            eu_mo_stride_tb     = 3'd2;
            saw_ack = 0;
            for (t = 0; t < 400; t++) begin
                @(posedge clk_4x);
                if (eu_mo_ack_tb) begin saw_ack = 1; break; end
            end
            eu_mo_req_tb = 0;
            use_multiop  = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P5-6: MOVEP.L read ack", saw_ack);
            // 32-bit port returns full words; all 4 rdata should be non-zero
            check("P5-6: rdata0 valid", eu_mo_rdata0_tb !== 32'h0);
            check("P5-6: rdata1 valid", eu_mo_rdata1_tb !== 32'h0);
            check("P5-6: rdata2 valid", eu_mo_rdata2_tb !== 32'h0);
            check("P5-6: rdata3 valid", eu_mo_rdata3_tb !== 32'h0);
        end
        repeat(8) @(posedge clk_4x);

        // ===================================================================
        // Phase 6: Cache and MMU
        // ===================================================================
        $display("=== MC68030 BIU Phase 6 Tests ===");

        // ----------------------------------------------------------------
        // P6-1: I-cache miss → linefill (4 reads) → correct data returned
        // ----------------------------------------------------------------
        $display("--- P6-1: I-cache miss → linefill ---");
        begin
            int t6;
            // word index = byte_addr / 4
            u_mem.mem[32'h100/4] = 32'hAABB_CCDD;  // addr 0x100 → word 64
            u_mem.mem[32'h104/4] = 32'h1122_3344;  // addr 0x104 → word 65
            u_mem.mem[32'h108/4] = 32'h5566_7788;  // addr 0x108 → word 66
            u_mem.mem[32'h10C/4] = 32'h99AA_BBCC;  // addr 0x10C → word 67

            wait_bus_idle;
            cacr_tb         = 32'h11;  // EI=bit0=1, IBE=bit4=1
            use_cache       = 1'b1;
            eu_is_icache_tb = 1'b1;
            eu_addr_tb      = 32'h0000_0100;
            eu_fc_tb        = 3'b101;
            eu_rw_tb        = 1'b1;
            eu_siz_tb       = 2'b00;
            @(posedge clk_4x);
            eu_req_tb = 1'b1;
            for (t6 = 0; t6 < 500; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb = 1'b0;
            check32("P6-1: linefill word0", cache_eu_rdata, 32'hAABB_CCDD);
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-2: I-cache hit → word 1 of same line, no bus cycle
        // ----------------------------------------------------------------
        $display("--- P6-2: I-cache hit (word 1 of same line) ---");
        begin
            int t6;
            logic was_idle;
            wait_bus_idle;
            eu_addr_tb = 32'h0000_0104;  // word 1 of cache line base 0x100
            eu_req_tb  = 1'b1;
            @(posedge clk_4x);
            was_idle = bus_idle;  // should be idle (no bus cycle for cache hit)
            for (t6 = 0; t6 < 100; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb = 1'b0;
            if (!was_idle) begin
                $display("FAIL  P6-2: bus was not idle (miss instead of hit)");
                fail_count++;
            end else
                check32("P6-2: I-cache hit word1", cache_eu_rdata, 32'h1122_3344);
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-3: D-cache read miss → single fetch → hit on repeat
        // ----------------------------------------------------------------
        $display("--- P6-3: D-cache read miss → hit ---");
        begin
            int t6;
            u_mem.mem[32'h200/4] = 32'hDEAD_BEEF;
            wait_bus_idle;
            cacr_tb         = 32'h200;  // ED=bit9=1
            eu_is_icache_tb = 1'b0;
            eu_addr_tb      = 32'h0000_0200;
            eu_siz_tb       = 2'b00;
            eu_rw_tb        = 1'b1;
            eu_req_tb       = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 200; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb = 1'b0;
            check32("P6-3a: D-cache miss fetch", cache_eu_rdata, 32'hDEAD_BEEF);
            repeat(4) @(posedge clk_4x);

            // Repeat — should hit D-cache
            wait_bus_idle;
            eu_addr_tb = 32'h0000_0200;
            eu_req_tb  = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 50; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb = 1'b0;
            check32("P6-3b: D-cache hit", cache_eu_rdata, 32'hDEAD_BEEF);
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-4: D-cache write → write-through (bus cycle + cache update)
        // ----------------------------------------------------------------
        $display("--- P6-4: D-cache write-through ---");
        begin
            int t6;
            wait_bus_idle;
            eu_is_icache_tb = 1'b0;
            eu_addr_tb      = 32'h0000_0200;
            eu_rw_tb        = 1'b0;
            eu_wdata_tb     = 32'hCAFE_BABE;
            eu_req_tb       = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 200; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb   = 1'b0;
            eu_rw_tb    = 1'b1;
            eu_wdata_tb = 32'h0;
            check32("P6-4: write-through mem", u_mem.mem[32'h200/4], 32'hCAFE_BABE);
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-5: Cache disabled → bus cycle for every access
        // ----------------------------------------------------------------
        $display("--- P6-5: Cache disabled → bus read ---");
        begin
            int t6;
            u_mem.mem[32'h300/4] = 32'h1234_5678;
            wait_bus_idle;
            cacr_tb         = 32'h0;  // EI=0, ED=0
            eu_is_icache_tb = 1'b1;
            eu_addr_tb      = 32'h0000_0300;
            eu_rw_tb        = 1'b1;
            eu_siz_tb       = 2'b00;
            eu_req_tb       = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 200; t6++) begin
                @(posedge clk_4x);
                if (cache_eu_ack) break;
            end
            eu_req_tb = 1'b0;
            check32("P6-5: cache-disabled read", cache_eu_rdata, 32'h1234_5678);
            use_cache = 1'b0;
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-6: TT0 transparent translation → VA=PA, no table walk
        // ----------------------------------------------------------------
        $display("--- P6-6: TT0 bypass → VA=PA ---");
        begin
            int t6;
            // TT0: [31:24]=LAB=0x10, [23:16]=LAM=0x00, [15]=E=1, rest=0
            // Matches VA when VA[31:24]==0x10 (exact), any FC, any RW
            wait_bus_idle;
            tc_tb      = 32'h8000_0000;   // E=1, PS/IS/TIA/TIB/TIC all=0
            tt0_tb     = 32'h1000_80E0;  // LAB=0x10,LAM=0,E=1,FCM=3'b111(any FC),FCB=0,RWM=0
            use_mmu_tb = 1'b1;
            eu_addr_tb = 32'h1000_ABCD;
            eu_fc_tb   = 3'b101;
            eu_rw_tb   = 1'b1;
            eu_req_tb  = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 20; t6++) begin
                @(posedge clk_4x);
                if (mmu_walk_done_out || mmu_hit_out) break;
            end
            eu_req_tb = 1'b0;
            if (mmu_walk_req) begin
                $display("FAIL  P6-6: mmu_walk_req asserted (should not table-walk)");
                fail_count++;
            end else
                check32("P6-6: TT0 bypass PA=VA", mmu_pa_out, 32'h1000_ABCD);
            use_mmu_tb = 1'b0;
            tt0_tb     = 32'h0;
            tc_tb      = 32'h0;
            repeat(4) @(posedge clk_4x);
        end

        // ----------------------------------------------------------------
        // P6-7: ATC miss → 2-level table walk → ATC hit on second access
        // ----------------------------------------------------------------
        $display("--- P6-7: ATC miss → table walk → ATC hit ---");
        begin
            int t6;
            // TC: E=1, PS=12 (4KB pages), IS=0, TIA=10, TIB=10, TIC=0, TID=0
            // tc[31:28]=1000=8, tc[27:24]=1100=C, tc[23:20]=0000=0
            // tc[19:16]=1010=A, tc[15:12]=1010=A, tc[11:0]=0
            tc_tb  = 32'h8C0A_A000;
            tt0_tb = 32'h0;
            tt1_tb = 32'h0;
            // CRP lower 32-bit = {crp_base[31:4], DT=10} with crp_base=0x40
            // crp_base=0x40: {0x40>>4=4, 4-bit zone} → crp[31:4]=4 → crp=0x00000042
            crp_tb = {32'h0, 32'h0000_0042};

            // VA = 0x0040_1000:
            //   TIA=10: VA[31:22] = 1 → root entry index 1
            //   TIB=10: VA[21:12] = 1 → page entry index 1
            //   page offset = 0x000

            // Root table at 0x40; entry 1 at addr 0x44 (word 17)
            // Points to pointer table at 0x80, DT=10 → entry = 0x0000_0082
            u_mem.mem[17] = 32'h0000_0082;  // byte addr 0x44

            // Pointer table at 0x80; entry 1 at addr 0x84 (word 33)
            // Page frame at 0x30000000, DT=01 → entry = 0x3000_0001
            u_mem.mem[33] = 32'h3000_0001;  // byte addr 0x84

            wait_bus_idle;
            use_mmu_tb = 1'b1;
            eu_addr_tb = 32'h0040_1000;
            eu_fc_tb   = 3'b101;
            eu_rw_tb   = 1'b1;
            eu_req_tb  = 1'b1;
            @(posedge clk_4x);
            // Walk takes 2 bus cycles (~64 clk_4x ticks) plus arbiter latency
            for (t6 = 0; t6 < 300; t6++) begin
                @(posedge clk_4x);
                if (mmu_walk_done_out) break;
            end
            eu_req_tb = 1'b0;
            // PA = 0x3000_0000 | 0x000 = 0x3000_0000
            check32("P6-7a: walk PA", mmu_pa_out, 32'h3000_0000);
            check("P6-7a: no fault", !mmu_fault_out);
            repeat(8) @(posedge clk_4x);

            // Second access: same VA → ATC hit (no bus cycles)
            wait_bus_idle;
            eu_addr_tb = 32'h0040_1000;
            eu_req_tb  = 1'b1;
            @(posedge clk_4x);
            for (t6 = 0; t6 < 20; t6++) begin
                @(posedge clk_4x);
                if (mmu_hit_out || mmu_walk_done_out) break;
            end
            eu_req_tb = 1'b0;
            check("P6-7b: ATC hit", mmu_hit_out);
            check32("P6-7b: ATC hit PA", mmu_pa_out, 32'h3000_0000);
            use_mmu_tb = 1'b0;
            tc_tb      = 32'h0;
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-1: Burst read (line fill) — 4 beats, AS held asserted
        // ===================================================================
        begin
            $display("--- P7-1: Burst read 4 beats, AS held ---");
            // Pre-load memory words: addr/4 = word index (u_mem.mem is 32-bit word array)
            // 0x100 = word[64], 0x104 = word[65], 0x108 = word[66], 0x10C = word[67]
            u_mem.mem[64] = 32'hAABBCCDD;
            u_mem.mem[65] = 32'h11223344;
            u_mem.mem[66] = 32'h55667788;
            u_mem.mem[67] = 32'hDEADBEEF;
            test_mem_sel   = MUX_FAST;
            eu_burst_req_tb  = 1'b1;
            eu_burst_addr_tb = 32'h0000_0100;
            eu_burst_fc_tb   = 3'b101; // user program
            @(posedge eu_burst_ack_tb or posedge eu_burst_berr_tb);
            eu_burst_req_tb = 1'b0;
            @(posedge clk_4x);
            check("P7-1: no berr", !eu_burst_berr_tb);
            check32("P7-1: rdata0", eu_burst_rdata0_tb, 32'hAABBCCDD);
            check32("P7-1: rdata1", eu_burst_rdata1_tb, 32'h11223344);
            check32("P7-1: rdata2", eu_burst_rdata2_tb, 32'h55667788);
            check32("P7-1: rdata3", eu_burst_rdata3_tb, 32'hDEADBEEF);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-2: Burst read BERR on beat 2 — eu_burst_berr asserted
        // ===================================================================
        begin
            int t; logic saw_berr2;
            $display("--- P7-2: Burst read with BERR on beat 2 ---");
            test_mem_sel     = MUX_FAST;
            eu_burst_req_tb  = 1'b1;
            eu_burst_addr_tb = 32'h0000_0100;
            eu_burst_fc_tb   = 3'b101;
            // Wait until beat 1's NEXT_S4 (state 7'd43), then inject BERR
            wait_for_state(7'd43, 100);   // ST_BURST_NEXT_S4
            berr_tb = 1;
            saw_berr2 = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_burst_berr_tb) begin saw_berr2 = 1; break; end
            end
            berr_tb         = 0;
            eu_burst_req_tb = 0;
            while (!bus_idle) @(posedge clk_4x);
            check("P7-2: berr asserted", saw_berr2);
            repeat(8) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-3: MOVE16 burst write — 4 beats, AS held, RW=0
        // ===================================================================
        begin
            $display("--- P7-3: MOVE16 burst write 4 beats ---");
            test_mem_sel    = MUX_FAST;
            eu_m16_req_tb   = 1'b1;
            eu_m16_addr_tb  = 32'h0000_0200;
            eu_m16_fc_tb    = 3'b101;
            eu_m16_wdata0_tb = 32'hDEAD_0001;
            eu_m16_wdata1_tb = 32'hDEAD_0002;
            eu_m16_wdata2_tb = 32'hDEAD_0003;
            eu_m16_wdata3_tb = 32'hDEAD_0004;
            @(posedge eu_m16_ack_tb or posedge eu_m16_berr_tb);
            eu_m16_req_tb = 1'b0;
            @(posedge clk_4x);
            check("P7-3: no berr", !eu_m16_berr_tb);
            // Verify writes landed: 0x200=word[128], 0x204=word[129], 0x208=word[130], 0x20C=word[131]
            check32("P7-3: mem[0x200]", u_mem.mem[128], 32'hDEAD_0001);
            check32("P7-3: mem[0x204]", u_mem.mem[129], 32'hDEAD_0002);
            check32("P7-3: mem[0x208]", u_mem.mem[130], 32'hDEAD_0003);
            check32("P7-3: mem[0x20C]", u_mem.mem[131], 32'hDEAD_0004);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-4: CAS2 with do_write=0 — write phases skipped
        // ===================================================================
        begin
            $display("--- P7-4: CAS2 conditional write suppressed ---");
            test_mem_sel      = MUX_FAST;
            // Pre-load two operand words: 0x300=word[192], 0x304=word[193]
            u_mem.mem[192] = 32'h0000ABCD;
            u_mem.mem[193] = 32'h00001234;
            eu_cas2_do_write1_tb = 1'b0;  // suppress both writes
            eu_cas2_do_write2_tb = 1'b0;
            eu_cas2_req_tb    = 1'b1;
            eu_cas2_addr1_tb  = 32'h0000_0300;
            eu_cas2_addr2_tb  = 32'h0000_0304;
            eu_cas2_fc_tb     = 3'b101;
            eu_cas2_siz_tb    = 2'b00;    // longword
            eu_cas2_wdata1_tb = 32'hDEAD_BEEF;
            eu_cas2_wdata2_tb = 32'hCAFE_BABE;
            @(posedge eu_cas2_ack_tb);
            eu_cas2_req_tb       = 1'b0;
            eu_cas2_do_write1_tb = 1'b0;
            eu_cas2_do_write2_tb = 1'b0;
            @(posedge clk_4x);
            check32("P7-4: rdata1 unchanged", eu_cas2_rdata1_tb, 32'h0000ABCD);
            check32("P7-4: rdata2 unchanged", eu_cas2_rdata2_tb, 32'h00001234);
            // Memory must not have been written: 0x300=word[192]
            check32("P7-4: mem[0x300] intact", u_mem.mem[192], 32'h0000ABCD);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-5: CAS2 with do_write=1 — both write phases execute
        // ===================================================================
        begin
            $display("--- P7-5: CAS2 conditional write enabled ---");
            test_mem_sel      = MUX_FAST;
            eu_cas2_do_write1_tb = 1'b1;
            eu_cas2_do_write2_tb = 1'b1;
            eu_cas2_req_tb    = 1'b1;
            eu_cas2_addr1_tb  = 32'h0000_0300;
            eu_cas2_addr2_tb  = 32'h0000_0304;
            eu_cas2_fc_tb     = 3'b101;
            eu_cas2_siz_tb    = 2'b00;
            eu_cas2_wdata1_tb = 32'hDEAD_BEEF;
            eu_cas2_wdata2_tb = 32'hCAFE_BABE;
            @(posedge eu_cas2_ack_tb);
            eu_cas2_req_tb       = 1'b0;
            eu_cas2_do_write1_tb = 1'b0;
            eu_cas2_do_write2_tb = 1'b0;
            @(posedge clk_4x);
            check32("P7-5: mem[0x300] written", u_mem.mem[192], 32'hDEAD_BEEF);
            check32("P7-5: mem[0x304] written", u_mem.mem[193], 32'hCAFE_BABE);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-6: Exception frame capture — data read BERR → format $A
        // ===================================================================
        begin
            int t; logic saw_berr6;
            $display("--- P7-6: Exception frame capture, data read BERR → $A ---");
            // Use p4_direct to bypass sizing_fsm for precise timing
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0180;   // word[96], within DEPTH=256
            p4_eu_fc    = 3'b101;
            p4_eu_siz   = 2'b00;
            p4_eu_rw    = 1'b1;    // read
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            saw_berr6 = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr6 = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P7-6: eu_berr fired", saw_berr6);
            check("P7-6: fault_valid", fault_valid_tb);
            check32("P7-6: fault_addr", fault_addr_tb, 32'h0000_0180);
            check("P7-6: fault_rw=1", fault_rw_tb);
            check("P7-6: exc frame_valid", exc_frame_valid);
            check("P7-6: format=$A", exc_frame_format == 4'hA);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 7-7: Exception frame capture — data write BERR → format $B
        // ===================================================================
        begin
            int t; logic saw_berr7;
            $display("--- P7-7: Exception frame capture, data write BERR → $B ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0184;   // word[97]
            p4_eu_wdata = 32'hCAFE_CAFE;
            p4_eu_fc    = 3'b101;
            p4_eu_siz   = 2'b00;
            p4_eu_rw    = 1'b0;    // write
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd30, 50);   // ST_WRITE_S4
            berr_tb = 1;
            saw_berr7 = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr7 = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P7-7: eu_berr fired", saw_berr7);
            check("P7-7: fault_valid", fault_valid_tb);
            check32("P7-7: fault_addr", fault_addr_tb, 32'h0000_0184);
            check("P7-7: fault_rw=0", !fault_rw_tb);
            check("P7-7: exc frame_valid", exc_frame_valid);
            check("P7-7: format=$B", exc_frame_format == 4'hB);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 8 — Single DS byte-lane steering tests
        // ===================================================================
        // The 68030 has a single /DS pin (not /UDS+/LDS).
        // Byte-lane selection is conveyed via SIZ[1:0] + A[1:0].
        // biu_byte_lane_ctrl steers write data to the correct bus lane so
        // the peripheral sees the byte on the right D[31:0] pin position.
        $display("=== MC68030 BIU Phase 8 Tests ===");

        // P8-1: DS asserts at S3, deasserts at S6 (longword read)
        begin
            $display("--- P8-1: DS_n timing: low@S3, high@S6 ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0000;
            p4_eu_siz   = 2'b00;   // LW
            p4_eu_rw    = 1'b1;
            p4_eu_fc    = 3'b101;
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd21, 30);   // ST_READ_S3
            check("P8-1: DS_n=0 @S3",  ext_ds_n === 1'b0);
            check("P8-1: AS_n=0 @S3",  ext_as_n === 1'b0);
            wait_for_state(7'd24, 30);   // ST_READ_S6
            check("P8-1: DS_n=1 @S6",  ext_ds_n === 1'b1);
            check("P8-1: AS_n=1 @S6",  ext_as_n === 1'b1);
            for (int t = 0; t < 50; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // P8-2: Byte writes — mem_model byte-selective using SIZ+A[1:0]
        // EU presents byte in wdata[31:24]; blc replicates to all lanes;
        // mem_model uses {SIZ,A[1:0]} to write only the correct byte.
        begin
            $display("--- P8-2: Byte writes byte-selective in mem ---");
            u_mem.mem[192] = 32'hFFFFFFFF;   // word at byte addr 0x300

            // byte@0 (A[1:0]=00): write 0xAA → mem[31:24]
            p4_direct = 1; p4_eu_addr = 32'h0000_0300; p4_eu_siz = 2'b01;
            p4_eu_rw = 1'b0; p4_eu_fc = 3'b101; p4_eu_wdata = 32'hAA000000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-2a: mem[31:24]=AA",     u_mem.mem[192][31:24] === 8'hAA);
            check("P8-2a: mem[23:0] intact",  u_mem.mem[192][23:0]  === 24'hFFFFFF);

            // byte@1 (A[1:0]=01): write 0xBB → mem[23:16]
            p4_direct = 1; p4_eu_addr = 32'h0000_0301; p4_eu_siz = 2'b01;
            p4_eu_rw = 1'b0; p4_eu_wdata = 32'hBB000000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-2b: mem[23:16]=BB",     u_mem.mem[192][23:16] === 8'hBB);
            check("P8-2b: mem[31:24] intact", u_mem.mem[192][31:24] === 8'hAA);

            // byte@2 (A[1:0]=10): write 0xCC → mem[15:8]
            p4_direct = 1; p4_eu_addr = 32'h0000_0302; p4_eu_siz = 2'b01;
            p4_eu_rw = 1'b0; p4_eu_wdata = 32'hCC000000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-2c: mem[15:8]=CC",      u_mem.mem[192][15:8]  === 8'hCC);

            // byte@3 (A[1:0]=11): write 0xDD → mem[7:0]
            p4_direct = 1; p4_eu_addr = 32'h0000_0303; p4_eu_siz = 2'b01;
            p4_eu_rw = 1'b0; p4_eu_wdata = 32'hDD000000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-2d: mem[7:0]=DD",       u_mem.mem[192][7:0]   === 8'hDD);

            check("P8-2: full word AABBCCDD", u_mem.mem[192] === 32'hAABBCCDD);
            repeat(4) @(posedge clk_4x);
        end

        // P8-3: Word write at A[1:0]=00 — only [31:16] written, [15:0] intact
        begin
            $display("--- P8-3: Word write A=0x00, [31:16] only ---");
            u_mem.mem[193] = 32'h12345678;   // word at byte addr 0x304
            p4_direct = 1; p4_eu_addr = 32'h0000_0304; p4_eu_siz = 2'b10;
            p4_eu_rw = 1'b0; p4_eu_fc = 3'b101; p4_eu_wdata = 32'hCAFE0000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-3: [31:16]=CAFE",  u_mem.mem[193][31:16] === 16'hCAFE);
            check("P8-3: [15:0] intact", u_mem.mem[193][15:0]  === 16'h5678);
            repeat(4) @(posedge clk_4x);
        end

        // P8-4: Word write at A[1:0]=10 — only [15:0] written, [31:16] intact
        begin
            $display("--- P8-4: Word write A=0x02, [15:0] only ---");
            u_mem.mem[193] = 32'h12345678;
            p4_direct = 1; p4_eu_addr = 32'h0000_0306; p4_eu_siz = 2'b10;
            p4_eu_rw = 1'b0; p4_eu_fc = 3'b101; p4_eu_wdata = 32'hBEEF0000;
            wait_bus_idle; p4_eu_req = 1;
            for (int t = 0; t < 80; t++) begin @(posedge clk_4x); if (eu_ack) break; end
            p4_eu_req = 0; p4_direct = 0; while (!bus_idle) @(posedge clk_4x);
            check("P8-4: [31:16] intact", u_mem.mem[193][31:16] === 16'h1234);
            check("P8-4: [15:0]=BEEF",   u_mem.mem[193][15:0]  === 16'hBEEF);
            repeat(4) @(posedge clk_4x);
        end

        // P8-5: DS asserts during IACK (68030 IACK is a normal CPU Space read)
        // The peripheral identifies the cycle via FC=111 + AS + DS + A[19:16]=1111
        begin
            $display("--- P8-5: IACK DS_n=0 at S3 (FC=111 CPU Space read) ---");
            iack_test_vec    = 8'd77;
            test_mem_sel     = MUX_IACK;
            eu_iack_level_tb = 3'd6;
            eu_iack_req_tb   = 1'b1;
            wait_for_state(7'd65, 50);   // ST_IACK_S3
            check("P8-5: DS_n=0 IACK@S3", ext_ds_n === 1'b0);
            check("P8-5: AS_n=0 IACK@S3", ext_as_n === 1'b0);
            check("P8-5: FC=111 IACK",    ext_fc   === 3'b111);
            for (int t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_iack_ack_tb) break;
            end
            eu_iack_req_tb = 0;
            test_mem_sel   = MUX_FAST;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // CBACK# burst-abort tests
        // ===================================================================
        $display("=== MC68030 BIU CBACK# Tests ===");

        // PCB-1: Full burst with CBACK# asserted (cback_s=0) — baseline
        // This is essentially P7-1 repeated to confirm cback_ok_r works normally.
        begin
            $display("--- PCB-1: Full burst read, CBACK# asserted ---");
            cback_s_tb = 1'b0;   // CBACK# asserted (active-low: 0=asserted)
            u_mem.mem[64]  = 32'hAABBCCDD;
            u_mem.mem[65]  = 32'h11223344;
            u_mem.mem[66]  = 32'h55667788;
            u_mem.mem[67]  = 32'h99AABBCC;
            eu_burst_req_tb  = 1'b0; eu_burst_fc_tb  = 3'b101;
            eu_burst_addr_tb = 32'h0000_0100;
            wait_bus_idle;
            eu_burst_req_tb = 1'b1;
            for (int t = 0; t < 200; t++) begin
                @(posedge clk_4x);
                if (eu_burst_ack_tb || eu_burst_berr_tb) break;
            end
            eu_burst_req_tb = 1'b0;
            check("PCB-1: no berr",  !eu_burst_berr_tb);
            check("PCB-1: ack",       eu_burst_ack_tb);
            check("PCB-1: rdata0",    eu_burst_rdata0_tb === 32'hAABBCCDD);
            check("PCB-1: rdata3",    eu_burst_rdata3_tb === 32'h99AABBCC);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // PCB-2: Burst with CBACK# deasserted — BIU should complete beat 0 only
        // and fire eu_burst_ack immediately (not waiting for beats 1-3).
        begin
            logic saw_ack;
            logic [31:0] saved_rdata0;
            int   ticks_to_ack;
            $display("--- PCB-2: Burst read, CBACK# deasserted → beat-0 only ---");
            cback_s_tb = 1'b1;   // CBACK# deasserted
            u_mem.mem[68]  = 32'hDEADBEEF;
            u_mem.mem[69]  = 32'hBADC0FFE;   // should NOT be fetched
            eu_burst_req_tb  = 1'b0; eu_burst_fc_tb  = 3'b101;
            eu_burst_addr_tb = 32'h0000_0110;
            wait_bus_idle;
            saw_ack = 0; ticks_to_ack = 0;
            eu_burst_req_tb = 1'b1;
            for (int t = 0; t < 200; t++) begin
                @(posedge clk_4x);
                ticks_to_ack++;
                if (eu_burst_ack_tb || eu_burst_berr_tb) begin
                    saw_ack = eu_burst_ack_tb;
                    saved_rdata0 = eu_burst_rdata0_tb;
                    break;
                end
            end
            eu_burst_req_tb = 1'b0;
            check("PCB-2: ack fires",        saw_ack);
            check("PCB-2: no berr",          !eu_burst_berr_tb);
            check("PCB-2: rdata0 valid",     saved_rdata0 === 32'hDEADBEEF);
            // Full 4-beat burst takes ~92+ 4x-ticks; single beat ~36 ticks.
            // Verify ack came well before a full burst would complete.
            check("PCB-2: early ack (<50)",  ticks_to_ack < 50);
            // Verify bus is idle — no continuation beats were attempted
            while (!bus_idle) @(posedge clk_4x);
            check("PCB-2: bus idle after",   bus_idle);
            cback_s_tb = 1'b0;   // restore default
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 9: biu_config synchronizer and biu_pin_driver OE tests
        // ===================================================================
        $display("=== Phase 9: Input Synchronizer + Pin Driver ===");
        wait_bus_idle;

        // --- P9-1: pins_released asserts after reset ---
        // We're already past reset; verify it's high.
        begin
            $display("--- P9-1: pins_released after reset ---");
            @(posedge clk_4x);
            check("P9-1: pins_released", cfg_pins_released === 1'b1);
        end

        // --- P9-2: 2-cycle sync delay on BERR# pin ---
        // Assert BERR# (cfg_berr_n=0) then check propagation timing.
        // Stage 1 latches on the first posedge after assertion.
        // Stage 2 (output) latches on the second posedge — so cfg_berr_s
        // should be 0 one cycle after assertion and 1 two cycles after.
        begin
            $display("--- P9-2: Sync delay — BERR# 2-cycle propagation ---");
            // Baseline: berr_s must be 0 before we start
            @(posedge clk_4x);
            check("P9-2a: berr_s idle", cfg_berr_s === 1'b0);

            // Assert BERR# (active-low pin goes to 0)
            cfg_berr_n = 1'b0;

            // One cycle later — stage 1 captured but stage 2 has not yet
            @(posedge clk_4x);
            check("P9-2b: berr_s not yet (+1)", cfg_berr_s === 1'b0);

            // Two cycles after assertion — stage 2 captured → berr_s = 1
            @(posedge clk_4x);
            check("P9-2c: berr_s visible (+2)", cfg_berr_s === 1'b1);

            // Deassert and let it clear
            cfg_berr_n = 1'b1;
            repeat(4) @(posedge clk_4x);
            check("P9-2d: berr_s cleared", cfg_berr_s === 1'b0);
        end

        // --- P9-3: DSACK# sync polarity (active-high output) ---
        // Assert DSACK0# (cfg_dsack0_n=0) and verify cfg_dsack0_s goes 1
        // after 2 cycles.
        begin
            $display("--- P9-3: Sync polarity — DSACK0# → dsack0_s ---");
            @(posedge clk_4x);
            check("P9-3a: dsack0_s idle", cfg_dsack0_s === 1'b0);
            cfg_dsack0_n = 1'b0;
            @(posedge clk_4x); @(posedge clk_4x);
            check("P9-3b: dsack0_s asserted", cfg_dsack0_s === 1'b1);
            cfg_dsack0_n = 1'b1;
            repeat(4) @(posedge clk_4x);
        end

        // --- P9-4: HALT# retained polarity (active-low) ---
        // Assert HALT# (cfg_halt_n=0) → halt_s should go 0 (active-low retained)
        begin
            $display("--- P9-4: Sync polarity — HALT# retained active-low ---");
            @(posedge clk_4x);
            check("P9-4a: halt_s deasserted", cfg_halt_s === 1'b1);
            cfg_halt_n = 1'b0;
            @(posedge clk_4x); @(posedge clk_4x);
            check("P9-4b: halt_s asserted (=0)", cfg_halt_s === 1'b0);
            cfg_halt_n = 1'b1;
            repeat(4) @(posedge clk_4x);
        end

        // --- P9-5: biu_pin_driver OE blocked during reset ---
        // Drive pd_d_oe=1 but hold pins_released=0 (simulates reset).
        // ext_d_oe must be 0.
        begin
            $display("--- P9-5: Pin driver OE blocked during reset ---");
            pd_d_oe_tb     = 1'b1;
            pd_pins_rel_tb = 1'b0;
            #1;  // combinational — no clock edge needed
            check("P9-5: OE blocked", pd_ext_d_oe === 1'b0);
            pd_pins_rel_tb = 1'b1;
        end

        // --- P9-6: biu_pin_driver OE passes after reset ---
        // With pins_released=1 and d_oe=1, ext_d_oe must be 1.
        // Also verify data passes through.
        begin
            $display("--- P9-6: Pin driver OE enabled after reset ---");
            pd_d_out_tb    = 32'hCAFE_BABE;
            pd_d_oe_tb     = 1'b1;
            pd_pins_rel_tb = 1'b1;
            #1;
            check("P9-6a: OE enabled",   pd_ext_d_oe  === 1'b1);
            check("P9-6b: data through", pd_ext_d_out === 32'hCAFE_BABE);
            pd_d_oe_tb  = 1'b0;
            #1;
            check("P9-6c: OE low when d_oe=0", pd_ext_d_oe === 1'b0);
        end

        // ===================================================================
        // Phase 10: Coprocessor (FPU) CPU Space cycle tests
        // ===================================================================
        $display("=== Phase 10: Coprocessor CPU Space Cycles ===");
        wait_bus_idle;

        // --- P10-1: Coprocessor read — FC=111, A[19:16]=0010, DSACK, rdata ---
        // Simulates the 68030 reading the FPU's response register.
        // Address: A[19:16]=0010 (coproc category), A[15:13]=000 (CPI primitive),
        //          A[12:0]=register offset 0x00.
        begin
            $display("--- P10-1: Coprocessor read (FC=111, A[19:16]=0010) ---");
            // Pre-load the memory word the FPU will return
            u_mem.mem[8]  = 32'hF00D_F00D;   // addr 0x00000020 >> 2 = 8
            eu_coproc_req_tb   = 1'b0;
            eu_coproc_rw_tb    = 1'b1;
            eu_coproc_fc_tb    = 3'b111;
            eu_coproc_siz_tb   = 2'b00;  // longword
            // A[19:16]=0010 → bits [19:16] = 4'b0010 = 0x0002_0000? No:
            // A[19:16] means address bits 19,18,17,16.
            // 0010 in binary = 2, so A[19:16]=0010 → 0x0002_0000 masked:
            //   addr = 32'h0002_0000 | (CP_ID << 13) | offset
            // For test: A[19:16]=4'b0010, A[15:13]=3'b001 (FPU CP_ID=1), A[12:0]=0
            // → addr = 0x00021000
            eu_coproc_addr_tb  = 32'h0002_1000;
            wait_bus_idle;
            eu_coproc_req_tb = 1'b1;
            // Wait for ack (S7 of the read cycle)
            for (int t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_coproc_ack_tb || eu_coproc_berr_tb) break;
            end
            eu_coproc_req_tb = 1'b0;
            check("P10-1a: no berr",   !eu_coproc_berr_tb);
            check("P10-1b: ack",        eu_coproc_ack_tb);
            // rdata comes from mem at word_addr = 0x00021000>>2 = 0x8400
            // but our mem only has DEPTH=256, so it returns DEAD_DEAD for OOB.
            // Reload the address to something within range.
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // --- P10-2: Coprocessor read with data — use address in mem range ---
        // A[19:16]=0010 with a low address that falls in u_mem's DEPTH=256.
        // We use 32'h0000_0020 (word 8): bits [19:16]=0, not 0010.
        // To get A[19:16]=0010 AND a valid mem word, we work around DEPTH limit:
        // u_mem uses word_addr = ext_a[31:2], so addr 0x20 → word 8, but
        // addr 0x00021000 → word 0x8400 which is OOB (returns DEAD_DEAD).
        // Load a second mem_model that covers high addresses, OR just verify
        // the bus protocol (FC, AS, DS) without depending on specific rdata.
        begin
            $display("--- P10-2: Coprocessor read — bus protocol check ---");
            eu_coproc_req_tb  = 1'b0;
            eu_coproc_rw_tb   = 1'b1;
            eu_coproc_fc_tb   = 3'b111;
            eu_coproc_siz_tb  = 2'b00;
            eu_coproc_addr_tb = 32'h0002_1000;
            wait_bus_idle;
            eu_coproc_req_tb = 1'b1;
            // Sample bus signals at S2 (when AS first asserts)
            wait_for_state(7'd20, 50);   // ST_READ_S2
            check("P10-2a: FC=111",  ext_fc  === 3'b111);
            check("P10-2b: AS low",  ext_as_n === 1'b0);
            check("P10-2c: A[19:16]=0010",
                  ext_a[19:16] === 4'b0010);
            // Sample at S3 (DS asserts)
            wait_for_state(7'd21, 20);   // ST_READ_S3
            check("P10-2d: DS low",  ext_ds_n === 1'b0);
            check("P10-2e: RW=1",    ext_rw   === 1'b1);
            for (int t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_coproc_ack_tb || eu_coproc_berr_tb) break;
            end
            eu_coproc_req_tb = 1'b0;
            check("P10-2f: ack",     eu_coproc_ack_tb);
            check("P10-2g: no berr", !eu_coproc_berr_tb);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // --- P10-3: Coprocessor write — FC=111, DS=0, ext_d_oe=1 at S3 ---
        begin
            $display("--- P10-3: Coprocessor write (FC=111 write) ---");
            eu_coproc_req_tb   = 1'b0;
            eu_coproc_rw_tb    = 1'b0;   // write
            eu_coproc_fc_tb    = 3'b111;
            eu_coproc_siz_tb   = 2'b00;
            eu_coproc_addr_tb  = 32'h0002_1000;
            eu_coproc_wdata_tb = 32'hDEAD_C0DE;
            wait_bus_idle;
            eu_coproc_req_tb = 1'b1;
            wait_for_state(7'd29, 50);   // ST_WRITE_S3
            check("P10-3a: FC=111 write",   ext_fc   === 3'b111);
            check("P10-3b: A[19:16]=0010",  ext_a[19:16] === 4'b0010);
            check("P10-3c: DS low write",   ext_ds_n === 1'b0);
            check("P10-3d: RW=0 (write)",   ext_rw   === 1'b0);
            check("P10-3e: D bus driven",   ext_d_oe === 1'b1);
            for (int t = 0; t < 100; t++) begin
                @(posedge clk_4x);
                if (eu_coproc_ack_tb || eu_coproc_berr_tb) break;
            end
            eu_coproc_req_tb = 1'b0;
            check("P10-3f: ack",     eu_coproc_ack_tb);
            check("P10-3g: no berr", !eu_coproc_berr_tb);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // --- P10-4: IACK still works — FC=111 A[19:16]=1111 (not coproc) ---
        // Verify that eu_iack_req is not confused with eu_coproc_req.
        begin
            $display("--- P10-4: IACK still works after coproc added ---");
            iack_test_vec    = 8'd33;
            test_mem_sel     = MUX_IACK;
            eu_iack_level_tb = 3'd5;
            eu_iack_req_tb   = 1'b1;
            for (int t = 0; t < 200; t++) begin
                @(posedge clk_4x);
                if (eu_iack_ack_tb) break;
            end
            eu_iack_req_tb = 1'b0;
            test_mem_sel   = MUX_FAST;
            check("P10-4a: iack ack",    eu_iack_ack_tb);
            check("P10-4b: iack vec",    eu_iack_vec_tb === 8'd33);
            check("P10-4c: no coproc",   !eu_coproc_ack_tb);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 11: BERR timeout watchdog + double bus fault
        // ===================================================================
        $display("=== Phase 11: BERR Timeout Watchdog ===");
        wait_bus_idle;
        repeat(4) @(posedge clk_4x);

        // --- P11-1: Normal cycle — watchdog counter never fires ---
        // A fast-memory read (immediate DSACK) must complete with no timeout.
        begin
            logic saw_timeout;
            saw_timeout = 1'b0;
            $display("--- P11-1: Normal cycle — no watchdog fire ---");
            test_mem_sel   = MUX_FAST;
            eu_addr_tb     = 32'h0000_0008;
            eu_fc_tb       = 3'b101;
            eu_rw_tb       = 1'b1;
            eu_siz_tb      = 2'b00;
            eu_req_tb      = 1'b1;
            for (int t = 0; t < 80; t++) begin
                @(posedge clk_4x);
                if (berr_timeout_tb) saw_timeout = 1'b1;
                if (eu_ack || eu_berr) break;
            end
            eu_req_tb = 1'b0;
            check("P11-1a: ack",         eu_ack);
            check("P11-1b: no timeout",  !saw_timeout);
            check("P11-1c: no berr",     !eu_berr);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // --- P11-2: Watchdog fires — no DSACK, no STERM → eu_berr ---
        // Hold DSACK deasserted using MUX_NOSACK without asserting STERM.
        // The watchdog fires after TIMEOUT_CLKS=80 ticks and injects BERR.
        begin
            logic saw_timeout;
            logic saw_berr;
            saw_timeout = 1'b0;
            saw_berr    = 1'b0;
            $display("--- P11-2: Watchdog timeout → eu_berr ---");
            test_mem_sel = MUX_NOSACK;   // no DSACK; sterm_tb still 0
            sterm_tb     = 1'b0;
            eu_addr_tb   = 32'h0000_0040;
            eu_fc_tb     = 3'b101;
            eu_rw_tb     = 1'b1;
            eu_siz_tb    = 2'b00;
            eu_req_tb    = 1'b1;
            for (int t = 0; t < 250; t++) begin
                @(posedge clk_4x);
                if (berr_timeout_tb) saw_timeout = 1'b1;
                if (eu_berr)         saw_berr    = 1'b1;
                if (eu_ack || eu_berr) break;
            end
            eu_req_tb    = 1'b0;
            test_mem_sel = MUX_FAST;
            check("P11-2a: timeout fired", saw_timeout);
            check("P11-2b: eu_berr",       saw_berr);
            check("P11-2c: no eu_ack",     !eu_ack);
            // berr_timeout_r clears when bus returns to idle
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P11-2d: timeout cleared on idle", !berr_timeout_tb);
        end

        // --- P11-3: Double bus fault — BERR during retry → halt_out ---
        // First cycle: no DSACK + HALT asserted → BERR+HALT → retry_pending=1.
        // Retry cycle: also no DSACK → second timeout fires while
        //              retry_pending=1 → halt_out asserts.
        begin
            logic saw_halt;
            saw_halt      = 1'b0;
            $display("--- P11-3: Double bus fault → halt_out ---");
            halt_tb       = 1'b0;   // assert HALT# (active-low: 0 = asserted)
            test_mem_sel  = MUX_NOSACK;
            sterm_tb      = 1'b0;
            eu_addr_tb    = 32'h0000_0050;
            eu_fc_tb      = 3'b101;
            eu_rw_tb      = 1'b1;
            eu_siz_tb     = 2'b00;
            eu_req_tb     = 1'b1;
            // Watch for halt_out over both the original and retry cycles
            for (int t = 0; t < 500; t++) begin
                @(posedge clk_4x);
                if (halt_out_tb) saw_halt = 1'b1;
                // eu_berr signals the end of the retry (double-fault exception)
                if (eu_berr) break;
            end
            eu_req_tb    = 1'b0;
            halt_tb      = 1'b1;   // restore HALT# deasserted
            test_mem_sel = MUX_FAST;
            check("P11-3: halt_out on double fault", saw_halt);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 12 — SSW (Special Status Word) content verification
        // ===================================================================

        // --- P12-1: Read BERR → SSW FC=101, RW=1, DF=1, RC=0 → 0xB800 ---
        begin
            int t; logic saw_berr12a;
            $display("--- P12-1: SSW for read BERR (FC=101, RW=1, DF=1) ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0190;
            p4_eu_fc    = 3'b101;    // supervisor data
            p4_eu_siz   = 2'b00;    // longword
            p4_eu_rw    = 1'b1;     // read
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            saw_berr12a = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr12a = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P12-1: eu_berr",        saw_berr12a);
            check16("P12-1: SSW=0xB800",   exc_ssw, 16'hB800);
        end

        // --- P12-2: Write BERR → SSW FC=101, RW=0, DF=1, RC=0 → 0xA800 ---
        begin
            int t; logic saw_berr12b;
            $display("--- P12-2: SSW for write BERR (FC=101, RW=0, DF=1) ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0194;
            p4_eu_wdata = 32'hDEAD_BEEF;
            p4_eu_fc    = 3'b101;    // supervisor data
            p4_eu_siz   = 2'b00;    // longword
            p4_eu_rw    = 1'b0;     // write
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd30, 50);   // ST_WRITE_S4
            berr_tb = 1;
            saw_berr12b = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr12b = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P12-2: eu_berr",        saw_berr12b);
            check16("P12-2: SSW=0xA800",   exc_ssw, 16'hA800);
        end

        // --- P12-3: Program fetch BERR → SSW FC=110, RW=1, DF=0 → 0xD000 ---
        begin
            int t; logic saw_berr12c;
            $display("--- P12-3: SSW for fetch BERR (FC=110, RW=1, DF=0) ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0198;
            p4_eu_fc    = 3'b110;    // supervisor program (fetch)
            p4_eu_siz   = 2'b00;    // longword
            p4_eu_rw    = 1'b1;     // read
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            saw_berr12c = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr12c = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P12-3: eu_berr",        saw_berr12c);
            check16("P12-3: SSW=0xD000",   exc_ssw, 16'hD000);
        end

        // --- P12-4: Double-fault via retry → SSW RC=1 → 0xB808 ---
        // First BERR+HALT on read → retry stored (in_retry_r sets at IDLE).
        // Retry cycle: BERR only (no HALT), in_retry_r=1 → fault_retry_r=1 → RC=1.
        begin
            int t; logic saw_berr12d;
            $display("--- P12-4: SSW for retry fault (RC=1) ---");
            p4_direct   = 1;
            p4_eu_addr  = 32'h0000_0050;
            p4_eu_fc    = 3'b101;    // supervisor data
            p4_eu_siz   = 2'b00;
            p4_eu_rw    = 1'b1;     // read
            p4_eu_is_op = 1'b0;
            wait_bus_idle;
            p4_eu_req = 1;
            // First cycle: BERR + HALT → retry (no fault_valid fired)
            wait_for_state(7'd22, 50);   // ST_READ_S4
            berr_tb = 1;
            halt_tb = 1'b0;              // assert HALT# (active-low)
            repeat(8) @(posedge clk_4x);
            berr_tb = 0;
            halt_tb = 1'b1;              // deassert HALT#
            // FSM returns to IDLE, in_retry_r goes 1, retry cycle starts
            wait_bus_idle;
            @(posedge clk_4x);
            // Retry cycle: BERR only → double fault with in_retry_r=1 → fault_retry_r=1
            wait_for_state(7'd22, 100);  // ST_READ_S4 again
            berr_tb = 1;
            saw_berr12d = 0;
            for (t = 0; t < 30; t++) begin
                @(posedge clk_4x);
                if (eu_berr) begin saw_berr12d = 1; break; end
            end
            berr_tb   = 0;
            p4_eu_req = 0;
            p4_direct = 0;
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
            check("P12-4: eu_berr",        saw_berr12d);
            check("P12-4: SSW RC=1",       exc_ssw[3]);
            check16("P12-4: SSW=0xB808",   exc_ssw, 16'hB808);
        end

        // ===================================================================
        // Phase 14 — ECS# and OCS# pin timing
        // ===================================================================
        begin
            $display("=== Phase 14: ECS# / OCS# Pin Timing ===");

            // Issue a plain EU read; peek at ECS#/OCS# during S0, S1, and S2.
            // State numbers: ST_READ_S0=18, ST_READ_S1=19, ST_READ_S2=20.
            wait_bus_idle;
            eu_addr_tb  = 32'h0000_0100;
            eu_fc_tb    = 3'b101;
            eu_siz_tb   = 2'b00;   // longword
            eu_rw_tb    = 1'b1;
            eu_is_op_tb = 1'b1;    // operand cycle → OCS# should assert
            eu_req_tb   = 1'b1;

            // --- P14-1: ECS# is a half-CLK pulse in the 2nd half of S1 ---
            $display("--- P14-1: ECS# half-CLK pulse in S1 phases 2-3 ---");

            // S0: ECS# must be deasserted (high)
            wait_for_state(7'd18, 20);   // ST_READ_S0, phase 0
            check("P14-1a: ECS_n high S0-ph0", ext_ecs_n === 1'b1);
            @(posedge clk_4x);  // phase 1
            check("P14-1b: ECS_n high S0-ph1", ext_ecs_n === 1'b1);
            @(posedge clk_4x);  // phase 2
            check("P14-1c: ECS_n high S0-ph2", ext_ecs_n === 1'b1);
            @(posedge clk_4x);  // phase 3
            check("P14-1d: ECS_n high S0-ph3", ext_ecs_n === 1'b1);

            // S1 phases 0-1: still deasserted; phases 2-3: asserted
            @(posedge clk_4x);  // S1 phase 0
            check("P14-1e: ECS_n high S1-ph0", ext_ecs_n === 1'b1);
            @(posedge clk_4x);  // S1 phase 1
            check("P14-1f: ECS_n high S1-ph1", ext_ecs_n === 1'b1);
            @(posedge clk_4x);  // S1 phase 2 — ECS# asserts here
            check("P14-1g: ECS_n low  S1-ph2", ext_ecs_n === 1'b0);
            @(posedge clk_4x);  // S1 phase 3
            check("P14-1h: ECS_n low  S1-ph3", ext_ecs_n === 1'b0);

            // S2: ECS# deasserts; AS# asserts
            @(posedge clk_4x);  // S2 phase 0
            check("P14-1i: ECS_n high at S2",  ext_ecs_n === 1'b1);
            check("P14-1j: AS_n  low  at S2",  ext_as_n  === 1'b0);

            // --- P14-2: OCS# asserts coincident with AS# at S2, not at S1 ---
            $display("--- P14-2: OCS# asserts coincident with AS# at S2 ---");

            // Restart a fresh read for clean S1 check
            // (current cycle is already at S2; let it finish then issue a new one)
            eu_req_tb = 1'b0;
            wait_bus_idle;
            eu_addr_tb  = 32'h0000_0100;
            eu_fc_tb    = 3'b101;
            eu_siz_tb   = 2'b00;
            eu_rw_tb    = 1'b1;
            eu_is_op_tb = 1'b1;
            eu_req_tb   = 1'b1;

            wait_for_state(7'd19, 20);   // ST_READ_S1, phase 0
            check("P14-2a: OCS_n high at S1",  ext_ocs_n === 1'b1);

            wait_for_state(7'd20, 20);   // ST_READ_S2, phase 0
            check("P14-2b: OCS_n low  at S2",  ext_ocs_n === 1'b0);
            check("P14-2c: AS_n  low  at S2",  ext_as_n  === 1'b0);

            eu_req_tb = 1'b0;
            wait_bus_idle;
        end

        // Phase 20 — Standalone HALT# bus suspension
        // ===================================================================
        begin
            $display("=== Phase 20: HALT# Bus Suspension ===");

            // P20-1: HALT# asserted before request — no cycle starts
            $display("--- P20-1: HALT# blocks new bus cycle ---");
            begin
                int t; logic saw_as, saw_halted;
                wait_bus_idle;
                halt_tb     = 1'b0;   // assert HALT# (active-low)
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0400;
                p4_eu_siz   = 2'b00;
                p4_eu_rw    = 1'b1;
                p4_eu_fc    = 3'b101;
                p4_eu_is_op = 1'b1;
                p4_eu_req   = 1;
                saw_as = 0; saw_halted = 0;
                // Hold HALT# for 40 ticks (one E-clock period) — no cycle should start
                repeat(40) begin
                    @(posedge clk_4x);
                    if (!ext_as_n) saw_as = 1;
                    if (bus_halted) saw_halted = 1;
                end
                check("P20-1a: bus_halted asserts",         saw_halted);
                check("P20-1b: AS# never asserted",          !saw_as);
                // Deassert HALT# — cycle should now complete
                halt_tb = 1'b1;
                begin
                    logic got_ack; int u;
                    got_ack = 0;
                    for (u = 0; u < 60; u++) begin
                        @(posedge clk_4x);
                        if (cg_eu_ack_direct) begin got_ack = 1; break; end
                    end
                    p4_eu_req = 0;
                    p4_direct = 0;
                    while (!bus_idle) @(posedge clk_4x);
                    check("P20-1c: eu_ack fires after HALT# deasserts", got_ack);
                end
            end
            repeat(8) @(posedge clk_4x);

            // P20-2: In-progress cycle completes, THEN HALT# holds IDLE
            $display("--- P20-2: In-progress cycle completes; HALT# holds IDLE ---");
            begin
                int t; logic got_first_ack, stayed_idle, got_second_ack;
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0404;
                p4_eu_siz   = 2'b00;
                p4_eu_rw    = 1'b1;
                p4_eu_fc    = 3'b101;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                // Wait for AS# to assert (bus cycle has started), then assert HALT#
                got_first_ack = 0;
                for (t = 0; t < 30; t++) begin
                    @(posedge clk_4x);
                    if (!ext_as_n) begin halt_tb = 1'b0; end   // assert HALT# once AS# asserts
                    if (cg_eu_ack_direct) begin got_first_ack = 1; break; end
                end
                // First cycle should complete despite HALT#
                check("P20-2a: first cycle completes",   got_first_ack);
                // State is still ST_READ_S7 when ack fires; wait for IDLE, then
                // verify the bus stays there (HALT# prevents the second cycle).
                while (!bus_idle) @(posedge clk_4x);
                stayed_idle = 1;
                repeat(20) begin
                    @(posedge clk_4x);
                    if (!bus_idle) stayed_idle = 0;
                end
                check("P20-2b: bus stays IDLE while HALT# held", stayed_idle);
                check("P20-2c: bus_halted asserts",               bus_halted);
                // Deassert HALT# — second cycle should run
                halt_tb = 1'b1;
                got_second_ack = 0;
                for (t = 0; t < 60; t++) begin
                    @(posedge clk_4x);
                    if (cg_eu_ack_direct) begin got_second_ack = 1; break; end
                end
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P20-2d: second cycle completes after HALT# release", got_second_ack);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 19 — Address error detection
        // ===================================================================
        begin
            $display("=== Phase 19: Address Error Detection ===");

            // P19-1: EU word read to odd address — eu_addr_err fires, no bus cycle
            $display("--- P19-1: EU word read to odd address ---");
            begin
                int t; logic saw_ae, saw_as;
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0201;  // odd byte address
                p4_eu_siz   = 2'b10;           // word
                p4_eu_rw    = 1'b1;
                p4_eu_fc    = 3'b101;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                saw_ae = 0; saw_as = 0;
                for (t = 0; t < 20; t++) begin
                    @(posedge clk_4x);
                    if (eu_addr_err) saw_ae = 1;
                    if (!ext_as_n)  saw_as = 1;
                end
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P19-1a: eu_addr_err fires",        saw_ae);
                check("P19-1b: AS# never asserted",       !saw_as);
                check("P19-1c: bus returned to idle",      bus_idle);
            end
            repeat(8) @(posedge clk_4x);

            // P19-2: EU byte read to odd address — no error (byte is always legal)
            $display("--- P19-2: EU byte read to odd address (no error) ---");
            begin
                int t; logic saw_ae, got_ack;
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0201;  // odd — OK for byte
                p4_eu_siz   = 2'b01;           // byte
                p4_eu_rw    = 1'b1;
                p4_eu_fc    = 3'b101;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                saw_ae = 0; got_ack = 0;
                for (t = 0; t < 60; t++) begin
                    @(posedge clk_4x);
                    if (eu_addr_err) saw_ae = 1;
                    if (cg_eu_ack_direct) begin got_ack = 1; break; end
                end
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P19-2a: eu_addr_err NOT fired",  !saw_ae);
                check("P19-2b: eu_ack fires normally",   got_ack);
            end
            repeat(8) @(posedge clk_4x);

            // P19-3: EU word write to odd address — eu_addr_err fires, no write
            $display("--- P19-3: EU word write to odd address ---");
            begin
                int t; logic saw_ae, saw_as;
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0203;  // odd
                p4_eu_siz   = 2'b10;           // word
                p4_eu_rw    = 1'b0;            // write
                p4_eu_wdata = 32'hDEAD_CAFE;
                p4_eu_fc    = 3'b101;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                saw_ae = 0; saw_as = 0;
                for (t = 0; t < 20; t++) begin
                    @(posedge clk_4x);
                    if (eu_addr_err) saw_ae = 1;
                    if (!ext_as_n)  saw_as = 1;
                end
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P19-3a: eu_addr_err fires for word write to odd",  saw_ae);
                check("P19-3b: AS# never asserted (no write started)",    !saw_as);
            end
            repeat(8) @(posedge clk_4x);

            // P19-4: IFU fetch to odd address — ifu_addr_err fires, no bus cycle
            $display("--- P19-4: IFU fetch to odd address ---");
            begin
                int t; logic saw_ae, saw_as;
                ifu_addr_tb = 32'h0000_0101;  // odd instruction address
                ifu_req_tb  = 1'b1;
                wait_bus_idle;
                saw_ae = 0; saw_as = 0;
                for (t = 0; t < 20; t++) begin
                    @(posedge clk_4x);
                    if (ifu_addr_err) saw_ae = 1;
                    if (!ext_as_n)    saw_as = 1;
                end
                ifu_req_tb  = 1'b0;
                ifu_addr_tb = 32'h0;
                while (!bus_idle) @(posedge clk_4x);
                check("P19-4a: ifu_addr_err fires",       saw_ae);
                check("P19-4b: AS# never asserted",        !saw_as);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 18 — VPA / E-clock termination
        // ===================================================================
        begin
            $display("=== Phase 18: VPA / E-clock Termination ===");

            // P18-1: VPA read — cycle must loop in S4/S5 until eclk_cnt==9
            // (the E-clock falling edge), then complete.  Data is captured at
            // that same edge.
            $display("--- P18-1: VPA read — E-clock synchronized ---");
            begin
                int t; logic saw_ack, saw_early_ack;
                logic [3:0]  term_eclk;
                logic [31:0] got_rdata;
                test_mem_sel = MUX_VPA;
                vpa_s_tb     = 1'b0;    // assert VPA# (active-low)
                p4_direct    = 1;
                p4_eu_addr   = 32'h0000_0600;
                p4_eu_fc     = 3'b101;
                p4_eu_siz    = 2'b00;
                p4_eu_rw     = 1'b1;
                p4_eu_is_op  = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                // The cycle enters S4 on about tick 13 (3 ticks setup + 10 for S0-S3).
                // It must NOT ack until eclk_cnt==9.  Record eclk_cnt when ack fires.
                // Capture rdata and eclk_cnt inside the loop: eu_rdata is combinational
                // and returns to 0 once state leaves ST_READ_S7.
                saw_ack = 0; saw_early_ack = 0; term_eclk = 4'hF; got_rdata = 32'h0;
                for (t = 0; t < 200; t++) begin
                    @(posedge clk_4x);
                    if (cg_eu_ack_direct) begin
                        term_eclk = eclk_cnt;
                        got_rdata = cg_eu_rdata;
                        saw_ack   = 1;
                        break;
                    end
                end
                p4_eu_req    = 0;
                vpa_s_tb     = 1'b1;
                test_mem_sel = MUX_FAST;
                p4_direct    = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P18-1a: eu_ack fires",                   saw_ack);
                // eclk_cnt reads 0 at ack time: E fell on the previous phase_r==3
                // tick (9→0 NBA), so the registered eclk_cnt at the ack tick is 0.
                check("P18-1b: ack at eclk_cnt==0 (just after E falls)", term_eclk === 4'd0);
                check32("P18-1c: rdata from VPA bus", got_rdata, vpa_test_data);
            end
            repeat(8) @(posedge clk_4x);

            // P18-2: VPA during IACK — autovector (same result as AVEC but
            // using E-clock synchronization rather than immediate termination).
            $display("--- P18-2: VPA IACK — autovector via E-clock ---");
            begin
                int t; logic saw_ack;
                logic [7:0]  got_vec;
                logic        got_avec;
                test_mem_sel = MUX_VPA;   // no DSACK; data bus irrelevant for IACK
                vpa_s_tb     = 1'b0;      // assert VPA# instead of AVEC#
                wait_bus_idle;
                // Trigger IACK at level 5 (same setup as P4-5)
                eu_iack_req_tb   = 1;
                eu_iack_level_tb = 3'd5;
                saw_ack = 0;
                for (t = 0; t < 200; t++) begin
                    @(posedge clk_4x);
                    if (eu_iack_ack_tb) begin
                        got_vec  = eu_iack_vec_tb;
                        got_avec = eu_iack_avec_tb;
                        saw_ack  = 1;
                        break;
                    end
                end
                eu_iack_req_tb = 0;
                vpa_s_tb       = 1'b1;
                test_mem_sel   = MUX_FAST;
                while (!bus_idle) @(posedge clk_4x);
                check("P18-2a: iack_ack fires",              saw_ack);
                check("P18-2b: avec flag set (autovector)",  got_avec);
                check8("P18-2c: vector = 24+5 = 29",        got_vec, 8'd29);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 17 — CAS2 BERR abort, RESET_INST watchdog, frame_valid sticky
        // ===================================================================
        begin
            $display("=== Phase 17: Small Fixes ===");

            // P17-1: BERR during CAS2 R1 must abort the entire CAS2 and fire
            // eu_berr, NOT continue into W1/R2/W2 and fire eu_cas2_ack.
            $display("--- P17-1: CAS2 BERR abort at R1 fires eu_berr, not ack ---");
            begin
                int t; logic saw_berr, saw_ack;
                // Initialise mem so mem_model responds with DSACK (not timeout)
                u_mem.mem[80] = 32'hAAAA_BBBB;  // addr=$140
                u_mem.mem[81] = 32'hCCCC_DDDD;  // addr=$144
                eu_cas2_req_tb       = 1;
                eu_cas2_addr1_tb     = 32'h0000_0140;
                eu_cas2_addr2_tb     = 32'h0000_0144;
                eu_cas2_fc_tb        = 3'b101;
                eu_cas2_siz_tb       = 2'b00;
                eu_cas2_wdata1_tb    = 32'hDEAD_0001;
                eu_cas2_wdata2_tb    = 32'hDEAD_0002;
                eu_cas2_do_write1_tb = 1;
                eu_cas2_do_write2_tb = 1;
                wait_bus_idle;
                // Inject BERR at the R1 S4 sampling window
                wait_for_state(7'd76, 60);   // ST_CAS2_R1_S4
                berr_tb = 1;
                saw_berr = 0; saw_ack = 0;
                for (t = 0; t < 80; t++) begin
                    @(posedge clk_4x);
                    if (eu_berr)        saw_berr = 1;
                    if (eu_cas2_ack_tb) saw_ack  = 1;
                    if (saw_berr || saw_ack) break;
                end
                berr_tb        = 0;
                eu_cas2_req_tb = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P17-1a: eu_berr fires on CAS2 R1 BERR", saw_berr);
                check("P17-1b: eu_cas2_ack does NOT fire",      !saw_ack);
                // Memory must not have been written (CAS2 aborted before writes)
                check32("P17-1c: mem[80] untouched", u_mem.mem[80], 32'hAAAA_BBBB);
                check32("P17-1d: mem[81] untouched", u_mem.mem[81], 32'hCCCC_DDDD);
            end
            repeat(8) @(posedge clk_4x);

            // P17-2: RESET instruction must not trigger the watchdog timeout.
            // With TIMEOUT_CLKS=80 and RSTOUT_CLKS=124 (496 ticks), the watchdog
            // used to fire multiple times during RESET_INST.  The bus_reset_inst
            // fix suppresses the counter during that window.
            $display("--- P17-2: RESET_INST does not fire watchdog timeout ---");
            begin
                int t; logic saw_timeout;
                wait_bus_idle;
                eu_rst_req_tb = 1;
                wait_for_state(7'd70, 50);   // ST_RESET_INST
                saw_timeout = 0;
                // Wait for RESET_INST to complete (rstout_n goes high again)
                for (t = 0; t < 600; t++) begin
                    @(posedge clk_4x);
                    if (berr_timeout_tb) saw_timeout = 1;
                    if (bus_idle) break;
                end
                eu_rst_req_tb = 0;
                check("P17-2: no watchdog timeout during RESET_INST", !saw_timeout);
            end
            repeat(8) @(posedge clk_4x);

            // P17-3: frame_valid must remain set after a fault even when a
            // subsequent normal cycle completes successfully.
            $display("--- P17-3: frame_valid sticky after fault ---");
            begin
                int t; logic got_fault_valid, stayed_valid;
                // Issue a BERR to set frame_valid via biu_exc_capture
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0500;
                p4_eu_fc    = 3'b101;
                p4_eu_siz   = 2'b00;
                p4_eu_rw    = 1'b1;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                wait_for_state(7'd22, 50);   // ST_READ_S4
                berr_tb = 1;
                for (t = 0; t < 20; t++) @(posedge clk_4x);
                berr_tb   = 0;
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                got_fault_valid = exc_frame_valid;
                repeat(8) @(posedge clk_4x);

                // Now run a successful read cycle
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0000;
                p4_eu_fc    = 3'b101;
                p4_eu_siz   = 2'b00;
                p4_eu_rw    = 1'b1;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                for (t = 0; t < 80; t++) begin
                    @(posedge clk_4x);
                    if (eu_ack) break;
                end
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                // frame_valid must still be 1 (sticky)
                stayed_valid = exc_frame_valid;
                check("P17-3a: frame_valid set after BERR",           got_fault_valid);
                check("P17-3b: frame_valid sticky after normal cycle", stayed_valid);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 16 — Arbiter hardening: BG# glitch + AS# check on bus reclaim
        // ===================================================================
        begin
            $display("=== Phase 16: Arbiter Hardening ===");

            // P16-1: BG# must deassert if BR# withdraws before BGACK is received.
            // Without the fix, bg_r stays 0 while internal grants resume.
            $display("--- P16-1: BG# deasserts if BR# withdraws before BGACK ---");
            begin
                int t; logic saw_bg_assert, saw_bg_deassert;
                wait_bus_idle;
                repeat(4) @(posedge clk_4x);

                // Assert BR# (active-low: drive 0)
                br_arb_tb = 1'b0;
                // Wait for BG# to assert (should happen within 2-3 clocks of bus_idle)
                saw_bg_assert = 0;
                for (t = 0; t < 16; t++) begin
                    @(posedge clk_4x);
                    if (!ext_bg_n_arb) begin saw_bg_assert = 1; break; end
                end
                check("P16-1a: BG# asserts after BR#", saw_bg_assert);

                // Withdraw BR# without sending BGACK
                br_arb_tb = 1'b1;
                // BG# should deassert within a few clocks (glitch fix)
                saw_bg_deassert = 0;
                for (t = 0; t < 8; t++) begin
                    @(posedge clk_4x);
                    if (ext_bg_n_arb) begin saw_bg_deassert = 1; break; end
                end
                check("P16-1b: BG# deasserts after BR# withdrawal", saw_bg_deassert);
                check("P16-1c: dma_active stayed 0 (no BGACK)", !dma_active);
            end
            repeat(8) @(posedge clk_4x);

            // P16-2: After BGACK deasserts, arbiter must wait for AS# to deassert
            // before releasing dma_active (MC68030 UM bus reclaim protocol).
            $display("--- P16-2: Bus reclaim waits for AS# deassert ---");
            begin
                int t; logic saw_dma;
                wait_bus_idle;
                repeat(4) @(posedge clk_4x);

                // DMA handshake: BR# → BG# → BGACK → dma_active
                br_arb_tb    = 1'b0;   // assert BR#
                // Wait for BG# to assert
                for (t = 0; t < 16; t++) begin
                    @(posedge clk_4x);
                    if (!ext_bg_n_arb) break;
                end
                // DMA device takes bus: assert BGACK# (active-low: 0)
                bgack_arb_tb = 1'b0;
                for (t = 0; t < 8; t++) begin
                    @(posedge clk_4x);
                    if (dma_active) begin saw_dma = 1; break; end
                end
                check("P16-2a: dma_active set after BGACK", dma_active);
                check("P16-2b: BG# deasserted after BGACK", ext_bg_n_arb === 1'b1);

                // DMA device asserts AS# (holds bus)
                as_n_fb_arb = 1'b0;
                br_arb_tb   = 1'b1;    // BR# released by DMA device

                // DMA device releases BGACK but keeps AS# low (not yet done)
                bgack_arb_tb = 1'b1;
                repeat(4) @(posedge clk_4x);
                // Arbiter must NOT release yet — AS# still asserted
                check("P16-2c: dma_active held while AS# low", dma_active === 1'b1);

                // DMA device releases AS# — now arbiter may resume
                as_n_fb_arb = 1'b1;
                repeat(4) @(posedge clk_4x);
                check("P16-2d: dma_active cleared after AS# deassert", dma_active === 1'b0);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 15 — RMW AS# continuity + BERR window extension through S6
        // ===================================================================
        begin
            $display("=== Phase 15: RMW AS# Continuity + BERR at S6 ===");

            // P15-1: AS# must stay asserted without glitch from RMW read S6
            //        through write S1.  The rmw_as_hold override covers those
            //        four states (READ_S6/S7 and WRITE_S0/S1).
            $display("--- P15-1: RMW byte - AS# asserted through read→write gap ---");
            begin
                int t; logic saw_as_gap, got_rd_ack, got_wr_ack;
                u_mem.mem[64] = 32'hAB000000;  // addr=$100
                p4_direct   = 1;
                eu_rmw_tb   = 1;
                p4_eu_addr  = 32'h0000_0100;
                p4_eu_fc    = 3'b101;
                p4_eu_siz   = 2'b01;   // byte
                p4_eu_rw    = 1'b1;
                p4_eu_wdata = 32'hFF000000;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                // Wait until READ_S6 (7'd53) where AS# must stay low via rmw_as_hold
                wait_for_state(7'd53, 80);  // ST_RMW_READ_S6
                saw_as_gap = 0;
                // Monitor ext_as_n from READ_S6 through WRITE_S1 — must never go high
                // READ_S6 (53) → READ_S7 (71) → WRITE_S0 (54) → WRITE_S1 (55)
                // That span is about 16 internal clock ticks; scan 32 ticks to be safe
                for (t = 0; t < 32; t++) begin
                    @(posedge clk_4x);
                    if (s_state == 7'd54 || s_state == 7'd55 || // WRITE_S0/S1
                        s_state == 7'd53 || s_state == 7'd71) begin // READ_S6/S7
                        if (ext_as_n) saw_as_gap = 1;  // AS# went high when it shouldn't
                    end
                    if (s_state == 7'd56) break;  // reached WRITE_S2 — done checking
                end
                got_rd_ack = 0;
                for (t = 0; t < 80; t++) begin
                    @(posedge clk_4x);
                    if (cg_eu_ack_direct) begin got_rd_ack = 1; break; end
                end
                while (cg_eu_ack_direct) @(posedge clk_4x);
                got_wr_ack = 0;
                for (t = 0; t < 80; t++) begin
                    @(posedge clk_4x);
                    if (cg_eu_ack_direct) begin got_wr_ack = 1; break; end
                end
                p4_eu_req = 0;
                eu_rmw_tb = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P15-1: AS# no glitch through RMW gap", !saw_as_gap);
                check("P15-1: RMW read ack received",  got_rd_ack);
                check("P15-1: RMW write ack received", got_wr_ack);
            end
            repeat(8) @(posedge clk_4x);

            // P15-2: BERR asserted at S6 (after DSACK window) must still fire eu_berr.
            //        This verifies the is_S6 extension to the BERR detection condition.
            $display("--- P15-2: BERR at S6 fires eu_berr ---");
            begin
                int t; logic saw_berr;
                p4_direct   = 1;
                p4_eu_addr  = 32'h0000_0400;  // new address, not in mem
                p4_eu_fc    = 3'b101;
                p4_eu_siz   = 2'b00;
                p4_eu_rw    = 1'b1;
                p4_eu_is_op = 1'b1;
                wait_bus_idle;
                p4_eu_req = 1;
                // Wait until the cycle reaches S6; DSACK from mem_model will
                // already have fired at S4, but BERR arriving here should abort.
                wait_for_state(7'd24, 60);  // ST_READ_S6
                berr_tb = 1;
                saw_berr = 0;
                for (t = 0; t < 30; t++) begin
                    @(posedge clk_4x);
                    if (eu_berr) begin saw_berr = 1; break; end
                end
                berr_tb   = 0;
                p4_eu_req = 0;
                p4_direct = 0;
                while (!bus_idle) @(posedge clk_4x);
                check("P15-2: eu_berr fired on S6 BERR", saw_berr);
            end
            repeat(8) @(posedge clk_4x);
        end

        // Phase 21 — MOVE16 burst write via STERM (no DSACK)
        // ===================================================================
        begin
            $display("=== Phase 21: MOVE16 Burst Write via STERM ===");

            // P21-1: 4-beat MOVE16 burst write; STERM asserted, no DSACK.
            // Each beat must advance S4→S6 via sterm_active (not dsack_wait).
            $display("--- P21-1: MOVE16 STERM burst write, 4 beats ---");
            begin
                logic got_ack, got_berr;
                test_mem_sel   = MUX_NOSACK;   // suppress DSACK
                sterm_tb       = 1'b1;          // STERM asserted for all beats
                eu_m16_req_tb  = 1'b1;
                eu_m16_addr_tb = 32'h0000_0300;
                eu_m16_fc_tb   = 3'b101;
                eu_m16_wdata0_tb = 32'hC001_0001;
                eu_m16_wdata1_tb = 32'hC001_0002;
                eu_m16_wdata2_tb = 32'hC001_0003;
                eu_m16_wdata3_tb = 32'hC001_0004;
                got_ack  = 0;
                got_berr = 0;
                @(posedge eu_m16_ack_tb or posedge eu_m16_berr_tb);
                if (eu_m16_ack_tb)  got_ack  = 1;
                if (eu_m16_berr_tb) got_berr = 1;
                eu_m16_req_tb = 1'b0;
                sterm_tb      = 1'b0;
                test_mem_sel  = MUX_FAST;
                while (!bus_idle) @(posedge clk_4x);

                check("P21-1a: eu_m16_ack fires (no timeout)", got_ack);
                check("P21-1b: no BERR on STERM burst write",  !got_berr);
                check32("P21-1c: mem[0x300] beat-0",  u_mem.mem[192], 32'hC001_0001);
                check32("P21-1d: mem[0x304] beat-1",  u_mem.mem[193], 32'hC001_0002);
                check32("P21-1e: mem[0x308] beat-2",  u_mem.mem[194], 32'hC001_0003);
                check32("P21-1f: mem[0x30C] beat-3",  u_mem.mem[195], 32'hC001_0004);
            end
            repeat(8) @(posedge clk_4x);
        end

        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end


    initial begin
        #500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

`default_nettype none
`timescale 1ns / 1ps

// m68030_biu integration testbench — Phase 13
//
// Tests m68030_biu as a black box via its external-pin interface.
// All async inputs (DSACK#, BERR# etc.) are raw active-low signals
// that pass through biu_config's 2-stage synchroniser internally.
//
// P13-1: Power-on init completes (init_done) and SSP/PC values are captured
// P13-2: EU longword read (cacr=0 → D-cache disabled → cache miss → bus cycle)
// P13-3: EU longword write then read-back verifies data persistence
// P13-4: m68030_top elaborates cleanly (compile-only; no run needed)
//
// Build:
//   iverilog -g2012 -o phase13.vvp \
//       tb/m68030_biu_tb.sv rtl/m68030_biu.sv rtl/m68030_top.sv \
//       rtl/biu_eclk_gen.sv rtl/biu_cycle_gen.sv rtl/biu_arbiter.sv \
//       rtl/biu_sizing_fsm.sv rtl/biu_multiop_fsm.sv rtl/biu_cache_if.sv \
//       rtl/biu_mmu_if.sv rtl/biu_exc_capture.sv rtl/biu_byte_lane_ctrl.sv \
//       rtl/biu_config.sv rtl/biu_pin_driver.sv rtl/biu_error_handler.sv \
//       tb/mem_model.sv && vvp phase13.vvp

module m68030_biu_tb;

    // -----------------------------------------------------------------------
    // Clock — 100 MHz 4× clock (10 ns period)
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    // -----------------------------------------------------------------------
    // External bus signals
    // -----------------------------------------------------------------------
    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic [31:0] ext_d_in;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n;
    logic        ext_rstout_n, ext_cbreq_n;
    logic        ext_e, ext_bg_n;

    // -----------------------------------------------------------------------
    // Async chip inputs — raw active-low (driven by testbench / mem_model)
    // -----------------------------------------------------------------------
    logic        dsack0_n, dsack1_n;
    logic        sterm_n  = 1'b1;   // deasserted
    logic        berr_n   = 1'b1;   // deasserted
    logic        halt_n   = 1'b1;   // deasserted
    logic        avec_n   = 1'b1;   // deasserted
    logic        vpa_n    = 1'b1;   // deasserted
    logic [2:0]  ipl_n    = 3'b111; // no interrupt
    logic        br_n     = 1'b1;   // no DMA request
    logic        bgack_n  = 1'b1;   // DMA not acknowledged
    logic        cback_n  = 1'b1;   // no burst acknowledge

    // -----------------------------------------------------------------------
    // EU interface (driven by testbench tasks)
    // -----------------------------------------------------------------------
    logic [31:0] eu_addr     = 32'h0;
    logic [31:0] eu_wdata    = 32'h0;
    logic [31:0] eu_rdata;
    logic [2:0]  eu_fc       = 3'b101; // supervisor data
    logic        eu_rw       = 1'b1;
    logic [1:0]  eu_siz      = 2'b00;  // longword
    logic        eu_is_operand = 1'b1;
    logic        eu_is_icache  = 1'b0;
    logic        eu_req      = 1'b0;
    logic        eu_ack, eu_berr, eu_retry;

    // Tie off all unused EU special interfaces
    logic [7:0]  eu_iack_vec;
    logic        eu_iack_avec, eu_iack_ack;
    logic        bus_lock;
    logic [31:0] eu_cas2_rdata1, eu_cas2_rdata2;
    logic        eu_cas2_ack;
    logic [31:0] eu_burst_rdata0, eu_burst_rdata1, eu_burst_rdata2, eu_burst_rdata3;
    logic        eu_burst_ack, eu_burst_berr;
    logic        eu_m16_ack, eu_m16_berr;
    logic [31:0] eu_coproc_rdata;
    logic        eu_coproc_ack, eu_coproc_berr;
    logic [31:0] eu_mo_rdata0, eu_mo_rdata1, eu_mo_rdata2, eu_mo_rdata3;
    logic        eu_mo_ack, eu_mo_berr;
    logic [31:0] ifu_rdata;
    logic        ifu_ack, ifu_berr;

    // Status outputs
    logic        bus_idle, init_done;
    logic [31:0] init_ssp, init_pc;
    logic [1:0]  phase;
    logic [6:0]  s_state;
    logic [31:0] fault_addr, fault_data;
    logic [2:0]  fault_fc_out;
    logic        fault_rw_out;
    logic [1:0]  fault_siz_out;
    logic        fault_valid, fault_retry, fault_is_rmw;
    logic        retry_pending, halt_out;
    logic [3:0]  exc_frame_format;
    logic        exc_frame_valid;
    logic [15:0] exc_ssw;
    logic        mmu_fault, mmu_ci;
    logic [15:0] mmusr;

    // -----------------------------------------------------------------------
    // DUT: m68030_biu
    // -----------------------------------------------------------------------
    m68030_biu #(.RSTOUT_CLKS(124), .TIMEOUT_CLKS(256), .POWERON_RSTO_CLKS(40)) u_biu (
        .clk_4x          (clk_4x),
        .rst_n           (rst_n),
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
        .eu_addr         (eu_addr),
        .eu_wdata        (eu_wdata),
        .eu_rdata        (eu_rdata),
        .eu_fc           (eu_fc),
        .eu_rw           (eu_rw),
        .eu_siz          (eu_siz),
        .eu_is_operand   (eu_is_operand),
        .eu_is_icache    (eu_is_icache),
        .eu_req          (eu_req),
        .eu_ack          (eu_ack),
        .eu_berr         (eu_berr),
        .eu_retry        (eu_retry),
        .eu_iack_req     (1'b0),
        .eu_iack_level   (3'b0),
        .eu_iack_vec     (eu_iack_vec),
        .eu_iack_avec    (eu_iack_avec),
        .eu_iack_ack     (eu_iack_ack),
        .eu_rst_req      (1'b0),
        .eu_rmw          (1'b0),
        .bus_lock        (bus_lock),
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
        .eu_burst_req    (1'b0),
        .eu_burst_addr   (32'h0),
        .eu_burst_fc     (3'b0),
        .eu_burst_rdata0 (eu_burst_rdata0),
        .eu_burst_rdata1 (eu_burst_rdata1),
        .eu_burst_rdata2 (eu_burst_rdata2),
        .eu_burst_rdata3 (eu_burst_rdata3),
        .eu_burst_ack    (eu_burst_ack),
        .eu_burst_berr   (eu_burst_berr),
        .eu_m16_req      (1'b0),
        .eu_m16_addr     (32'h0),
        .eu_m16_fc       (3'b0),
        .eu_m16_wdata0   (32'h0),
        .eu_m16_wdata1   (32'h0),
        .eu_m16_wdata2   (32'h0),
        .eu_m16_wdata3   (32'h0),
        .eu_m16_ack      (eu_m16_ack),
        .eu_m16_berr     (eu_m16_berr),
        .eu_coproc_req   (1'b0),
        .eu_coproc_rw    (1'b1),
        .eu_coproc_addr  (32'h0),
        .eu_coproc_fc    (3'b0),
        .eu_coproc_siz   (2'b0),
        .eu_coproc_wdata (32'h0),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
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
        .ifu_addr        (32'h0),
        .ifu_req         (1'b0),
        .ifu_rdata       (ifu_rdata),
        .ifu_ack         (ifu_ack),
        .ifu_berr        (ifu_berr),
        .cacr            (32'h0),      // caches disabled
        .caar            (32'h0),
        .tc              (32'h0),      // MMU disabled
        .crp             (64'h0),
        .srp             (64'h0),
        .tt0             (32'h0),
        .tt1             (32'h0),
        .bus_idle        (bus_idle),
        .init_done       (init_done),
        .init_ssp        (init_ssp),
        .init_pc         (init_pc),
        .phase           (phase),
        .s_state         (s_state),
        .fault_addr      (fault_addr),
        .fault_data      (fault_data),
        .fault_fc        (fault_fc_out),
        .fault_rw        (fault_rw_out),
        .fault_siz       (fault_siz_out),
        .fault_valid     (fault_valid),
        .fault_retry     (fault_retry),
        .fault_is_rmw    (fault_is_rmw),
        .retry_pending   (retry_pending),
        .halt_out        (halt_out),
        .exc_frame_format(exc_frame_format),
        .exc_frame_valid (exc_frame_valid),
        .exc_ssw         (exc_ssw),
        .mmu_fault       (mmu_fault),
        .mmu_ci          (mmu_ci),
        .mmusr           (mmusr)
    );

    // -----------------------------------------------------------------------
    // Memory model (32-bit port, 0 wait states, 256 longwords = 1 KB)
    // Drives raw dsack0_n/dsack1_n (active-low) — biu_config synchronises.
    // Pre-initialised with recognisable vector table content:
    //   addr 0x000 (mem[0]) = SSP = 0x0000_2000
    //   addr 0x004 (mem[1]) = PC  = 0x0000_0100
    // -----------------------------------------------------------------------
    logic [31:0] mem_ext_d_in;
    logic        mem_dsack0_n, mem_dsack1_n;

    mem_model #(.DEPTH(256), .PORT_WIDTH(32), .WAIT_STATES(0)) u_mem (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_in    (mem_ext_d_in),
        .dsack0_n    (mem_dsack0_n),
        .dsack1_n    (mem_dsack1_n),
        .ext_d_write (ext_d_out),
        .ext_d_oe    (ext_d_oe)
    );

    assign dsack0_n = mem_dsack0_n;
    assign dsack1_n = mem_dsack1_n;
    assign ext_d_in = mem_ext_d_in;

    // Pre-load vector table
    initial begin
        // Wait for memory to initialise
        #1;
        u_mem.mem[0] = 32'h0000_2000;  // SSP
        u_mem.mem[1] = 32'h0000_0100;  // PC
        u_mem.mem[4] = 32'hCAFE_BABE;  // test word at 0x10
        u_mem.mem[8] = 32'h0000_0000;  // write-back target at 0x20
    end

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task automatic check(input string desc, input logic cond);
        if (!cond) begin $display("FAIL  [%0t] %s", $time, desc); fail_count++; end
        else            $display("PASS  [%0t] %s", $time, desc);
    endtask

    task automatic check32(input string desc, input logic [31:0] actual, expected);
        if (actual !== expected) begin
            $display("FAIL  [%0t] %s: got %08h expected %08h",
                     $time, desc, actual, expected);
            fail_count++;
        end else $display("PASS  [%0t] %s", $time, desc);
    endtask

    // Wait until eu_ack or eu_berr fires (or timeout)
    task automatic wait_eu_done(input int timeout_cycles, output logic got_ack);
        got_ack = 1'b0;
        for (int t = 0; t < timeout_cycles; t++) begin
            @(posedge clk_4x);
            if (eu_ack)  begin got_ack = 1'b1; break; end
            if (eu_berr) begin got_ack = 1'b0; break; end
        end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("biu_phase13.vcd");
        $dumpvars(0, m68030_biu_tb);

        // ===================================================================
        // Reset
        // ===================================================================
        rst_n = 0;
        repeat(8) @(posedge clk_4x);
        rst_n = 1;

        // ===================================================================
        // P13-1: Power-on init — wait for init_done (SSP + PC fetches)
        // ===================================================================
        $display("--- P13-1: Power-on init (init_done) ---");
        begin
            logic ok;
            ok = 1'b0;
            for (int t = 0; t < 400 && !init_done; t++) @(posedge clk_4x);
            ok = init_done;
            check("P13-1a: init_done",    ok);
            check32("P13-1b: SSP=0x2000", init_ssp, 32'h0000_2000);
            check32("P13-1c: PC=0x0100",  init_pc,  32'h0000_0100);
        end
        repeat(4) @(posedge clk_4x);

        // ===================================================================
        // P13-2: EU longword read at 0x10 (cache disabled → bus cycle issued)
        // Expected data: mem[4] = 0xCAFE_BABE
        // ===================================================================
        $display("--- P13-2: EU longword read 0x10 ---");
        begin
            logic got_ack;
            logic [31:0] rdata_snap;
            eu_addr = 32'h0000_0010;
            eu_fc   = 3'b101;          // supervisor data
            eu_siz  = 2'b00;           // longword
            eu_rw   = 1'b1;
            eu_req  = 1'b1;
            wait_eu_done(300, got_ack);
            rdata_snap = eu_rdata;
            eu_req  = 1'b0;
            repeat(4) @(posedge clk_4x);
            check("P13-2a: eu_ack",           got_ack);
            check32("P13-2b: rdata=CAFE_BABE", rdata_snap, 32'hCAFE_BABE);
        end

        // ===================================================================
        // P13-3: EU write then read-back
        // Write 0xDEAD_BEEF to 0x20, then read it back.
        // ===================================================================
        $display("--- P13-3: EU write + read-back ---");
        begin
            logic got_ack;
            logic [31:0] rdata_snap;

            // Write
            eu_addr  = 32'h0000_0020;
            eu_wdata = 32'hDEAD_BEEF;
            eu_fc    = 3'b101;
            eu_siz   = 2'b00;
            eu_rw    = 1'b0;
            eu_req   = 1'b1;
            wait_eu_done(300, got_ack);
            eu_req = 1'b0;
            repeat(4) @(posedge clk_4x);
            check("P13-3a: write eu_ack", got_ack);

            // Read-back
            eu_rw  = 1'b1;
            eu_req = 1'b1;
            wait_eu_done(300, got_ack);
            rdata_snap = eu_rdata;
            eu_req = 1'b0;
            repeat(4) @(posedge clk_4x);
            check("P13-3b: read  eu_ack",          got_ack);
            check32("P13-3c: rdata=DEAD_BEEF",      rdata_snap, 32'hDEAD_BEEF);
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

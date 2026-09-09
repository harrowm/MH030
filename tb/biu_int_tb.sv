`default_nettype none
`timescale 1ns / 1ps

// m68030_biu integration testbench
//
// Tests m68030_biu as a black box via its external-pin interface.
// All async inputs (DSACK#, BERR# etc.) are raw active-low signals
// that pass through biu_config's 2-stage synchroniser internally.
//
// Tests:
//   - Power-on init: init_done fires; SSP/PC fetched from reset vectors
//   - EU longword read: cache disabled → bus cycle issued; data returned
//   - EU longword write + read-back: data persists in memory model

module biu_int_tb;

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
    logic        ext_bg_n;

    // -----------------------------------------------------------------------
    // Async chip inputs — raw active-low (driven by testbench / mem_model)
    // -----------------------------------------------------------------------
    logic        dsack0_n, dsack1_n;
    logic        sterm_n  = 1'b1;   // deasserted
    logic        berr_n   = 1'b1;   // deasserted
    logic        halt_n   = 1'b1;   // deasserted
    logic        avec_n   = 1'b1;   // deasserted
    logic [2:0]  ipl_n    = 3'b111; // no interrupt
    logic        br_n     = 1'b1;   // no DMA request
    logic        bgack_n  = 1'b1;   // DMA not acknowledged
    logic        cback_n  = 1'b1;   // no burst acknowledge
    logic        ciin_n   = 1'b1;   // Phase 158 Stage 7: CIIN# deasserted (not asserted)

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
    logic        retry_pending, halt_out, status_n;
    // Phase 250 Part B: status_n is now wired to a genuine double_fault
    // input (m68030_exc.sv's own new detection, no real m68030_exc here
    // since this file tests m68030_biu standalone) -- testbench-driven
    // directly for the dedicated double-fault test below. halt_out itself
    // was renamed retry_exhausted at the port; this tb-local variable name
    // is kept for minimal diff (still holds the same signal).
    logic        double_fault_tb = 1'b0;
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
        .ext_bg_n        (ext_bg_n),
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
        .ciin_n          (ciin_n),   // Phase 158 Stage 7
        .ciout_n         (),
        .cdis_n          (1'b1),     // docs/*.md review: deasserted (not asserted)
        .mmudis_n        (1'b1),     // docs/*.md review: deasserted (not asserted)
        .eu_addr         (eu_addr),
        .eu_wdata        (eu_wdata),
        .eu_rdata        (eu_rdata),
        .eu_fc           (eu_fc),
        .eu_rw           (eu_rw),
        .eu_siz          (eu_siz),
        .eu_is_operand   (eu_is_operand),
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
        .s_bit           (1'b1),       // supervisor (matches this project's
                                        // established default-supervisor
                                        // testbench convention)
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
        .retry_exhausted (halt_out),
        .status_n        (status_n),
        .double_fault    (double_fault_tb),
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
        .ext_d_oe    (ext_d_oe),
        // open-items backlog Stage 10 (plan.md): testbench-only, not a
        // real pin -- see mem_model.sv's own port comment.
        .burst_beat_probe (u_biu.u_cg.u_bc.burst_beat)
    );

    // Phase 250 F10: lets a test simulate "no device responds" (needed to
    // drive a genuine watchdog-timeout-driven double bus fault) without
    // touching mem_model.sv itself, which every other test in this file
    // relies on responding normally -- mem_model's own state machine has
    // no address-range gating (confirmed via direct read), so an
    // out-of-range address alone wouldn't suppress DSACK the way it does
    // in some other testbenches' own memory models.
    logic suppress_dsack = 1'b0;
    assign dsack0_n = suppress_dsack ? 1'b1 : mem_dsack0_n;
    assign dsack1_n = suppress_dsack ? 1'b1 : mem_dsack1_n;
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
        $dumpvars(0, biu_int_tb);

        // ===================================================================
        // Reset
        // ===================================================================
        rst_n = 0;
        repeat(8) @(posedge clk_4x);
        rst_n = 1;

        // ===================================================================
        // Power-on init: BIU fetches SSP and PC from reset vectors
        // ===================================================================
        $display("--- Power-on init (init_done) ---");
        begin
            logic ok;
            ok = 1'b0;
            for (int t = 0; t < 400 && !init_done; t++) @(posedge clk_4x);
            ok = init_done;
            check("init_done fires",    ok);
            check32("SSP=0x2000", init_ssp, 32'h0000_2000);
            check32("PC=0x0100",  init_pc,  32'h0000_0100);
        end
        repeat(4) @(posedge clk_4x);

        // ===================================================================
        // EU longword read — cache disabled → BIU issues external bus cycle
        // ===================================================================
        $display("--- EU longword read 0x10 ---");
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
            check("eu_ack fires",           got_ack);
            check32("rdata=CAFE_BABE", rdata_snap, 32'hCAFE_BABE);
        end

        // ===================================================================
        // EU write then read-back — data persists in memory model
        // ===================================================================
        $display("--- EU write + read-back ---");
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
            check("write eu_ack fires", got_ack);

            // Read-back
            eu_rw  = 1'b1;
            eu_req = 1'b1;
            wait_eu_done(300, got_ack);
            rdata_snap = eu_rdata;
            eu_req = 1'b0;
            repeat(4) @(posedge clk_4x);
            check("read eu_ack fires",          got_ack);
            check32("rdata=DEAD_BEEF",      rdata_snap, 32'hDEAD_BEEF);
        end

        // ===================================================================
        // Phase 250 Part B: retry_exhausted (renamed from halt_out) is a
        // real, useful BERR+HALT-retry-exhaustion signal, but §7.5.4 is
        // explicit that a retried bus cycle "does not constitute a bus
        // error or contribute to a double bus fault" -- this is NOT the
        // same condition status_n reports (see below). Reached via the
        // same BERR+HALT shape tb/biu_tb.sv's own standalone
        // biu_error_handler test already proves: HALT# asserted + no
        // DSACK/STERM response produces a BERR+HALT retry
        // (retry_pending=1), and a fault condition overlapping that retry
        // asserts retry_exhausted.
        // ===================================================================
        $display("--- Retry exhausted -> retry_exhausted (halt_out) ---");
        begin
            logic saw_retry, saw_exhausted;
            saw_retry     = 1'b0;
            saw_exhausted = 1'b0;
            // Real HALT# gates bus-cycle *initiation* itself (bus_halted's
            // own !halt_s term keeps the FSM parked in ST_IDLE while
            // HALT# is asserted) -- asserting it before/alongside eu_req
            // would prevent the cycle from ever starting at all, never
            // reaching the S4/S5/S6 BERR-check states where the real
            // BERR+HALT retry decision lives. Let the cycle genuinely
            // dispatch first (HALT# deasserted), then assert HALT#
            // partway through, matching what real hardware requires:
            // HALT# and BERR# sampled together at the point the fault is
            // recognized, not necessarily from the cycle's own start.
            suppress_dsack = 1'b1;   // no device ever responds
            eu_addr = 32'h0000_0030;
            eu_fc   = 3'b101;
            eu_rw   = 1'b1;
            eu_siz  = 2'b00;
            eu_req  = 1'b1;
            repeat(10) @(posedge clk_4x);
            halt_n  = 1'b0;   // assert HALT# (active-low: 0 = asserted)
            for (int t = 0; t < 2000 && !saw_exhausted; t++) begin
                @(posedge clk_4x);
                if (retry_pending) saw_retry = 1'b1;
                if (halt_out)      saw_exhausted = 1'b1;
            end
            eu_req         = 1'b0;
            halt_n         = 1'b1;   // restore HALT# deasserted
            suppress_dsack = 1'b0;   // restore normal DSACK response
            check("BERR+HALT genuinely produced a retry", saw_retry);
            check("retry_exhausted asserts on retry exhaustion", saw_exhausted);
            // Not wired to status_n anymore (Phase 250 Part B) -- confirm
            // that directly, since this exact scenario used to (wrongly)
            // assert it.
            check("status_n NOT affected by retry_exhausted alone", status_n);
            while (!bus_idle) @(posedge clk_4x);
            repeat(4) @(posedge clk_4x);
        end

        // ===================================================================
        // Phase 250 F10/Part B: STATUS pin, genuine double-bus-fault
        // sub-case. A real STATUS pin (MC68030UM.pdf Table 12-4/§7.5.4/
        // §8.1.2) has 4 distinct meanings; this project deliberately
        // implements only the one that isn't microsequencer-timing-
        // dependent -- continuously asserted (active low here, matching
        // the manual's own "Output, Low" polarity) = processor halted due
        // to double bus fault. This module tests m68030_biu standalone
        // (no real m68030_exc instantiated here), so the genuine
        // double_fault condition is driven directly via the new
        // double_fault_tb input rather than reconstructed from a real
        // exception-dispatch race -- m68030_exc.sv's own EXC-* tests
        // (tb/exc_tb.sv) cover the detection logic itself; this test only
        // proves status_n's own sticky-latch wiring reacts correctly to
        // whatever double_fault says. Run LAST (permanent park, matching
        // this project's own established precedent).
        // ===================================================================
        $display("--- Double bus fault -> status_n (sticky) ---");
        begin
            check("status_n deasserted before any fault", status_n);
            double_fault_tb = 1'b1;
            repeat(4) @(posedge clk_4x);
            check("status_n asserts on double bus fault", !status_n);
            double_fault_tb = 1'b0;
            // Sticky: real STATUS stays asserted "continuously... until
            // the processor is reset" (MC68030UM.pdf) -- confirm it
            // doesn't clear on its own once the underlying double_fault
            // pulse has long since passed.
            repeat(200) @(posedge clk_4x);
            check("status_n stays asserted (sticky, not a momentary pulse)", !status_n);
            rst_n = 1'b0;
            repeat(4) @(posedge clk_4x);
            rst_n = 1'b1;
            repeat(4) @(posedge clk_4x);
            check("status_n clears on reset", status_n);
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

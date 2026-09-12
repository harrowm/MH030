`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: the full three-cycle chain from
// MC68030UM.pdf Figure 7-21 ("Asynchronous Byte and Word Read Cycles --
// 32-Bit Port", p.7-33) -- a word read, then two byte reads, all inside
// the same longword, all zero-wait-state, all back-to-back with no
// idle gap deliberately inserted between them (the BIU dispatches the
// next cycle's S0 the instant the prior one's ST_IDLE tick sees a fresh
// eu_req -- the only gap that can appear is the project's own already-
// documented structural one-tick ST_IDLE dispatch floor, not an
// artifact of this testbench).
//
// This is NOT a pass/fail regression test (there is no `make test` target
// for it) -- it exists purely to produce a VCD that
// scripts/vcd_to_wavedrom.py turns into a WaveDrom timing diagram for
// comparison against Figure 7-21 directly, cycle for cycle:
//   1. word read  @ 0x10, SIZ=10 (word)  -> bytes 0-1 (D31-D16)
//   2. byte read  @ 0x12, SIZ=01 (byte)  -> byte 2   (D15-D8)
//   3. byte read  @ 0x13, SIZ=01 (byte)  -> byte 3   (D7-D0)
// all within the same test longword at address 0x10 (0x1234_5678),
// matching the figure's own WORD/BYTE/BYTE region layout and the A1/A0
// transitions it shows (00 -> 10 -> 11).
//
// Structure mirrors tb/biu_int_tb.sv's own m68030_biu integration harness
// (reset -> power-on init -> eu_req cycles), trimmed to the minimum
// needed for these three back-to-back reads; reuses tb/mem_model.sv
// directly rather than reinventing a memory model.

module read_cycle_tb;

    // -----------------------------------------------------------------------
    // Clock -- 100 MHz 4x clock (10 ns period), matching the project's own
    // "4x external bus frequency" convention throughout.
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
    logic        ext_rmc_n, ext_dben_n;
    logic        status_n;

    // -----------------------------------------------------------------------
    // Async chip inputs -- raw active-low (driven here / by mem_model)
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
    logic        ciin_n   = 1'b1;   // not cache-inhibited

    // -----------------------------------------------------------------------
    // EU interface -- the one bus request this testbench ever issues
    // -----------------------------------------------------------------------
    logic [31:0] eu_addr     = 32'h0;
    logic [31:0] eu_wdata    = 32'h0;
    logic [31:0] eu_rdata;
    logic [2:0]  eu_fc       = 3'b101; // supervisor data
    logic        eu_rw       = 1'b1;   // read
    logic [1:0]  eu_siz      = 2'b10;  // word (SIZ[1:0]=10)
    logic        eu_is_operand = 1'b1;
    logic        eu_req      = 1'b0;
    logic        eu_ack, eu_berr, eu_retry;

    // Tie off every EU/IFU special-interface port this diagram doesn't use
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
    logic [31:0] eu_bkpt_rdata;
    logic        eu_bkpt_ack, eu_bkpt_berr;
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
    logic        retry_pending, retry_exhausted;
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
        .ext_rmc_n       (ext_rmc_n),
        .ext_dben_n      (ext_dben_n),
        .bus_halted      (),
        .eu_addr_err     (),
        .ifu_addr_err    (),
        .dsack0_n        (dsack0_n),
        .dsack1_n        (dsack1_n),
        .sterm_n         (sterm_n),
        .berr_n          (berr_n),
        .halt_n          (halt_n),
        .status_n        (status_n),
        .avec_n          (avec_n),
        .ipl_n           (ipl_n),
        .br_n            (br_n),
        .bgack_n         (bgack_n),
        .cback_n         (cback_n),
        .ciin_n          (ciin_n),
        .ciout_n         (),
        .cdis_n          (1'b1),
        .mmudis_n        (1'b1),
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
        .eu_bkpt_req     (1'b0),
        .eu_bkpt_rw      (1'b1),
        .eu_bkpt_addr    (32'h0),
        .eu_bkpt_fc      (3'b0),
        .eu_bkpt_siz     (2'b0),
        .eu_bkpt_wdata   (32'h0),
        .eu_bkpt_rdata   (eu_bkpt_rdata),
        .eu_bkpt_ack     (eu_bkpt_ack),
        .eu_bkpt_berr    (eu_bkpt_berr),
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
        .s_bit           (1'b1),       // supervisor
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
        .retry_exhausted (retry_exhausted),
        .double_fault    (double_fault_tb),
        .exc_frame_format(exc_frame_format),
        .exc_frame_valid (exc_frame_valid),
        .exc_ssw         (exc_ssw),
        .mmu_fault       (mmu_fault),
        .mmu_ci          (mmu_ci),
        .mmusr           (mmusr)
    );

    // -----------------------------------------------------------------------
    // Memory model -- 32-bit port, ZERO wait states (matching Figure 7-21's
    // own "asynchronous, no wait states" shape), reused directly rather
    // than reinventing it.
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
        .burst_beat_probe (u_biu.u_cg.u_bc.burst_beat)
    );

    assign dsack0_n = mem_dsack0_n;
    assign dsack1_n = mem_dsack1_n;
    assign ext_d_in = mem_ext_d_in;

    // -----------------------------------------------------------------------
    // Test sequence: reset -> power-on init -> three back-to-back reads
    // matching Figure 7-21's own word/byte/byte chain exactly, pre-loaded
    // with a recognisable value so the diagram's own data lanes show
    // something legible (mirrors the figure's own "OPn" convention).
    // -----------------------------------------------------------------------
    initial begin
        // Wait for memory to initialise, then pre-load the vector table
        // (SSP/PC, consumed by power-on init) and the test longword itself.
        #1;
        u_mem.mem[0] = 32'h0000_2000;  // SSP
        u_mem.mem[1] = 32'h0000_0100;  // PC
        u_mem.mem[4] = 32'h1234_5678;  // test longword at 0x10: byte0=$12 byte1=$34 byte2=$56 byte3=$78
    end

    // One request/wait-for-ack/report step, reused for all three cycles.
    // eu_req is left asserted across cycles (never dropped between them) so
    // the BIU's own ST_IDLE dispatch sees a fresh request the instant the
    // prior cycle's S7 returns to ST_IDLE -- the only gap that can appear
    // is that single already-documented structural dispatch tick, not
    // anything this testbench inserts deliberately.
    task automatic do_read(input [31:0] addr, input [1:0] siz, input string label);
        logic got_ack;
        got_ack = 1'b0;
        eu_addr = addr;
        eu_siz  = siz;
        for (int t = 0; t < 40; t++) begin
            @(posedge clk_4x);
            if (eu_ack)  begin got_ack = 1'b1; break; end
            if (eu_berr) break;
        end
        if (got_ack)
            $display("PASS: %s read acked, eu_rdata=%08h", label, eu_rdata);
        else
            $display("FAIL: %s read never acked", label);
    endtask

    initial begin
        $dumpfile("read_cycle.vcd");
        $dumpvars(0, read_cycle_tb);

        rst_n = 0;
        repeat(8) @(posedge clk_4x);
        rst_n = 1;

        // Power-on init: BIU fetches SSP and PC from reset vectors
        for (int t = 0; t < 400 && !init_done; t++) @(posedge clk_4x);
        if (!init_done) $display("FAIL: init_done never asserted");

        // Settle a few cycles so the diagram's own "before" state is clean
        // idle bus, not the tail of the init fetches.
        repeat(8) @(posedge clk_4x);

        eu_fc  = 3'b101;   // supervisor data, throughout
        eu_rw  = 1'b1;     // read, throughout
        eu_req = 1'b1;     // stays asserted across all three chained cycles

        do_read(32'h0000_0010, 2'b10, "word ");   // WORD  @0x10 -> D31-D16 = $1234
        do_read(32'h0000_0012, 2'b01, "byte1");   // BYTE  @0x12 -> D15-D8  = $56
        do_read(32'h0000_0013, 2'b01, "byte2");   // BYTE  @0x13 -> D7-D0   = $78

        eu_req = 1'b0;

        // A few idle cycles after, so the diagram shows the bus genuinely
        // returning to idle (matching the manual's own "back-to-back or
        // idle" convention) rather than cutting off mid-signal.
        repeat(8) @(posedge clk_4x);

        $finish;
    end

endmodule

`default_nettype wire

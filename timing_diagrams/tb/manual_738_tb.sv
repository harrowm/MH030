`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-38's own
// Long-Word Operand Request from $07 with Burst Request and Wait Cycle
// (tests/timing_manual_738.s header). A D-cache miss with DBE (burst
// enable) set triggers a real 4-longword burst line fill -- uses
// tb/mem_model.sv (already proven for burst fills via tb/cache_tb.sv,
// including its own burst_beat_probe convention for the frozen-address
// beat addressing real 68030 burst mode uses) for the WHOLE address
// space rather than the inline 32-bit model every other diagram in
// this set uses, since ordinary reads/writes and a genuine burst fill
// both need to work against the SAME memory here. DSACK-terminated
// (not /STERM -- mem_model.sv is DSACK-only); real 68030 burst mode
// accepts either termination method (biu_cycle_gen.sv's own
// `!dsack_wait || sterm_active` condition), so this still matches the
// figure's own protocol shape even though the specific manual example
// happens to show /STERM.

module manual_738_tb;

    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic [31:0] ext_d_in;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_dben_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_bg_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;
    logic        dsack0_n, dsack1_n;

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    // Always grants a burst the CPU requests -- real 68030 burst
    // protocol: the device asserts /CBACK in response to /CBREQ once
    // it can supply a full 4-longword line.
    wire         cback_n  = ext_cbreq_n;
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;

    m68030_top #(.POWERON_RSTO_CLKS(40)) u_top (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .ext_a        (ext_a),
        .ext_d_out    (ext_d_out),
        .ext_d_oe     (ext_d_oe),
        .ext_d_in     (ext_d_in),
        .ext_as_n     (ext_as_n),
        .ext_ds_n     (ext_ds_n),
        .ext_rw       (ext_rw),
        .ext_fc       (ext_fc),
        .ext_siz      (ext_siz),
        .ext_ecs_n    (ext_ecs_n),
        .ext_ocs_n    (ext_ocs_n),
        .ext_dben_n   (ext_dben_n),
        .ext_rstout_n (ext_rstout_n),
        .ext_cbreq_n  (ext_cbreq_n),
        .ext_bg_n     (ext_bg_n),
        .bus_halted   (bus_halted),
        .eu_addr_err  (eu_addr_err),
        .ifu_addr_err (ifu_addr_err),
        .dsack0_n     (dsack0_n),
        .dsack1_n     (dsack1_n),
        .sterm_n      (sterm_n),
        .berr_n       (berr_n),
        .halt_n       (halt_n),
        .avec_n       (avec_n),
        .ipl_n        (ipl_n),
        .br_n         (br_n),
        .bgack_n      (bgack_n),
        .cback_n      (cback_n),
        .ciin_n       (ciin_n),
        .cdis_n       (cdis_n),
        .mmudis_n     (mmudis_n),
        .ciout_n      ()
    );

    wire [1:0] burst_beat_probe = u_top.u_biu.u_cg.u_bc.burst_beat;

    mem_model #(.DEPTH(4096), .PORT_WIDTH(32), .WAIT_STATES(0)) u_mem (
        .clk_4x           (clk_4x),
        .rst_n            (rst_n),
        .ext_a            (ext_a),
        .ext_as_n         (ext_as_n),
        .ext_ds_n         (ext_ds_n),
        .ext_rw           (ext_rw),
        .ext_siz          (ext_siz),
        .ext_d_in         (ext_d_in),
        .dsack0_n         (dsack0_n),
        .dsack1_n         (dsack1_n),
        .ext_d_write      (ext_d_out),
        .ext_d_oe         (ext_d_oe),
        .burst_beat_probe (burst_beat_probe)
    );

    wire [6:0] s_state = u_top.s_state;

    initial begin
        $dumpfile("manual_738.vcd");
        $dumpvars(0, manual_738_tb);

        $readmemh("../tests/timing_manual_738.hex", u_mem.mem);
        // Distinct marker longwords for each of the 4 beats of the burst
        // line at $3000 (word indices 0xC00..0xC03), so the diagram's
        // own data lanes show 4 genuinely different values per beat.
        u_mem.mem[16'h3000 >> 2]        = 32'hB0B0_0000;
        u_mem.mem[(16'h3000 >> 2) + 1]  = 32'hB1B1_1111;
        u_mem.mem[(16'h3000 >> 2) + 2]  = 32'hB2B2_2222;
        u_mem.mem[(16'h3000 >> 2) + 3]  = 32'hB3B3_3333;

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        for (int t = 0; t < 3000 && u_top.u_eu.u_rf.d_reg[0] !== 32'hB0B0_0000; t++)
            @(posedge clk_4x);

        repeat(20) @(posedge clk_4x);

        $display("FINAL d_reg[0] = %08x", u_top.u_eu.u_rf.d_reg[0]);
        $finish;
    end

endmodule

`default_nettype wire

`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-39's own Long-
// Word Operand Request from $07 with Burst Request -- CBACK Negated Early
// (tests/timing_manual_739.s header). Identical shape to manual_738_tb.sv
// (same mem_model.sv-backed burst fill), except /CBACK is only held
// asserted for the FIRST beat -- genuinely negated from beat 1 onward,
// not just mirroring /CBREQ's own brief pulse. Exercises the real
// per-beat CBACK sampling added to rtl/biu_burst_ctrl.sv while building
// this diagram (MC68030UM.pdf S6.1.4/6.2: "The premature negation of the
// CBACK signal during the burst operation causes the current cycle to
// complete normally... However, the burst operation aborts") -- the
// burst here completes beat 1 normally, then stops, never reaching
// beats 2/3.

module manual_739_tb;

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
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;
    // /CBACK: declared here (before u_top's own instantiation, which
    // needs it as a port connection) but driven further down, once
    // burst_beat_probe (itself read from u_top's own internal hierarchy)
    // is available -- asserted for beat 0 only, genuinely negated from
    // beat 1 onward. The burst completes beat 1 normally (its own data
    // still placed on the bus), then aborts instead of continuing to
    // beat 2.
    wire cback_n;

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

    assign cback_n = (burst_beat_probe == 2'd0) ? 1'b0 : 1'b1;

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
        $dumpfile("manual_739.vcd");
        $dumpvars(0, manual_739_tb);

        $readmemh("../tests/timing_manual_739.hex", u_mem.mem);
        // Distinct marker longwords for each of the 4 beats of the burst
        // line at $3000 -- only beats 0/1 should ever actually be seen on
        // the bus (the burst aborts before reaching beats 2/3).
        u_mem.mem[16'h3000 >> 2]        = 32'hB0B0_0000;
        u_mem.mem[(16'h3000 >> 2) + 1]  = 32'hB1B1_1111;
        u_mem.mem[(16'h3000 >> 2) + 2]  = 32'hB2B2_2222;
        u_mem.mem[(16'h3000 >> 2) + 3]  = 32'hB3B3_3333;

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Wait for the burst to genuinely start, then genuinely end (state
        // leaves the burst states again), then stop with a SMALL margin --
        // deliberately NOT waiting on d_reg[0] alone plus a long fixed
        // tail: the requested word is available to the EU after just beat
        // 0 completes (real 68030 semantics, confirmed against the manual
        // text), well before the abort at beat 1 even happens, so a long
        // tail risks capturing a LATER, unrelated dispatch instead of the
        // abort itself (confirmed via a first attempt at this diagram,
        // which showed beats 2/3 -- from a SEPARATE, later access -- in
        // the rendered window instead of the intended 2-beat abort).
        for (int t = 0; t < 3000 && !u_top.u_biu.u_cg.u_bc.is_burst; t++)
            @(posedge clk_4x);
        for (int t = 0; t < 3000 && u_top.u_biu.u_cg.u_bc.is_burst; t++)
            @(posedge clk_4x);
        repeat(4) @(posedge clk_4x);

        $display("FINAL d_reg[0] = %08x", u_top.u_eu.u_rf.d_reg[0]);
        $finish;
    end

endmodule

`default_nettype wire

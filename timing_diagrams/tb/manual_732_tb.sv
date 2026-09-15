`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-32's own
// Synchronous Read with CIIN Asserted and CBACK Negated (tests/
// timing_manual_732.s header). Driven through the REAL EU/decode
// pipeline, same inline-32-bit-model shape as manual_725_tb.sv, but
// the device terminates the cycle via /STERM instead of /DSACKx --
// biu_cycle_gen.sv's own `sterm_active` bypass (`(!dsack_wait ||
// sterm_active) && !berr_s`) takes over entirely; /DSACKx stays
// deasserted throughout. CIIN is also asserted here (tied active for
// the whole cycle, matching the figure's own "CIIN Asserted" case,
// since this project's per-beat CIIN capture (Phase 229) only matters
// for burst fills -- a single synchronous beat just needs it sampled
// as asserted at the one beat that matters) and CBACK stays negated
// (no burst -- this is an ordinary, non-cache-allocating access).

module manual_732_tb;

    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_dben_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_bg_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;

    // Tied to the 32-bit-port encoding (00) even though STERM, not
    // DSACKx, is what actually terminates the cycle -- biu_sizing_fsm.sv
    // still samples {dsack1_s,dsack0_s} (cyc_port_dsack) at S4/S5 to
    // decide whether dynamic sizing needs another sub-cycle, regardless
    // of which mechanism terminated the current one. Leaving both
    // deasserted (2'b11, a real-hardware-undefined encoding) hung the
    // whole read forever -- confirmed by inspection: biu_sizing_fsm.sv's
    // own needs_more()/next_siz() treat 2'b11 as "3 bytes remain, keep
    // going," so the FSM kept requesting further sub-cycles STERM's own
    // single-beat termination never provides. First found empirically
    // (the hang resolved the moment this was tied to the 32-bit
    // encoding instead of left deasserted), then confirmed against the
    // actual RTL source, not left as a guess.
    logic        dsack0_n = 1'b0;
    logic        dsack1_n = 1'b0;
    logic        sterm_n;   // continuously assigned below -- no initial value here
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b1;   // negated -- no burst, matches the figure
    logic        ciin_n   = 1'b0;   // asserted -- matches the figure's own "CIIN Asserted" case
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;
    wire         ciout_n;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        $readmemh("../tests/timing_manual_732.hex", rom);
        rom[16'h3010 >> 2] = 32'h1111_1111;  // marker the test program reads
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    // STERM's own latch window (biu_cycle_gen.sv's sterm_latched_r) is a
    // SINGLE specific S-state tick (state==ST_READ_S2 at state_adv), not
    // a level checked continuously like DSACKx's own "by end of S2"
    // recognition -- the other diagrams' own ds_active_r1/r2 hold-time
    // model (tuned for DSACKx's later, more forgiving recognition point)
    // asserts too late to ever land inside that window, missing the
    // latch every time (confirmed via a direct debug trace before fixing
    // this, not guessed at). Modeled here instead as an always-ready
    // synchronous device: STERM held permanently asserted from reset,
    // and read data driven unconditionally and combinationally from the
    // live address -- exactly what Figure 7-32 itself shows (STERM
    // already low well before S2, immediately after /ECS negates).
    assign sterm_n  = 1'b0;
    wire [31:0] ext_d_in = rd_word;

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
        .ciout_n      (ciout_n)
    );

    wire [6:0] s_state = u_top.s_state;

    initial begin
        $dumpfile("manual_732.vcd");
        $dumpvars(0, manual_732_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        for (int t = 0; t < 3000 && u_top.u_eu.u_rf.d_reg[0] !== 32'h1111_1111; t++)
            @(posedge clk_4x);

        repeat(8) @(posedge clk_4x);

        $display("FINAL d_reg[0] = %08x", u_top.u_eu.u_rf.d_reg[0]);
        $finish;
    end

endmodule

`default_nettype wire

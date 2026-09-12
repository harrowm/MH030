`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: Phase 254's own EU-side preview fast
// path (`~/.claude/plans/wobbly-honking-cascade.md`, CLAUDE.md), shown
// through the REAL EU/decode/execute pipeline -- unlike read_cycle_tb.sv,
// which drives m68030_biu standalone with hand-toggled eu_req/eu_addr and
// therefore can never exercise preview_ok at all (see its own header
// comment and README.md's "Known differences" section for why).
//
// Runs the exact scenario tests/timing_preview.s was built to measure:
// a taken branch lands directly on a back-to-back MOVE.L (A0),D0 /
// MOVE.L (A1),D1 pair (isolated so the IFU has no prefetch head start),
// then STOP. Reuses the already-assembled ../tests/timing_preview.hex
// directly rather than re-encoding the program here, so this diagram is
// provably the same scenario tb/timing_tb.sv measured a real 8-tick ->
// 6-tick AS-fall-to-AS-fall gap reduction for (CLAUDE.md's own Phase 254
// entry).
//
// Structure mirrors tb/timing_tb.sv's own m68030_top harness (the real,
// full CPU -- not a standalone BIU instance) almost verbatim, trimmed to
// just reset + free-run + VCD dump: no measurement/pass-fail machinery
// is needed here, matching read_cycle_tb.sv's own "not a make test
// target" convention.

module preview_dispatch_tb;

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

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b0;
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;

    // ── Memory model: same shape as tb/timing_tb.sv's own inline model ──────
    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        $readmemh("../tests/timing_preview.hex", rom);
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    logic ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) ds_active_r <= 1'b0;
        else        ds_active_r <= !ext_ds_n & !ext_as_n;
    end

    wire dsack0_n = ~ds_active_r;
    wire dsack1_n = ~ds_active_r;

    wire [31:0] ext_d_in = (!ext_ds_n & ext_rw) ? rd_word : {32{1'bz}};

    always_ff @(posedge clk_4x) begin
        if (ds_active_r && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
            if (ext_a[13:2] < MEM_WORDS) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: rom[ext_a[13:2]]        <= ext_d_out;
                    4'b10_00: rom[ext_a[13:2]][31:16] <= ext_d_out[31:16];
                    4'b10_10: rom[ext_a[13:2]][15:0]  <= ext_d_out[15:0];
                    4'b01_00: rom[ext_a[13:2]][31:24] <= ext_d_out[31:24];
                    4'b01_01: rom[ext_a[13:2]][23:16] <= ext_d_out[23:16];
                    4'b01_10: rom[ext_a[13:2]][15:8]  <= ext_d_out[15:8];
                    4'b01_11: rom[ext_a[13:2]][7:0]   <= ext_d_out[7:0];
                    default:  rom[ext_a[13:2]]        <= ext_d_out;
                endcase
            end
        end
    end

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

    // Tap the BIU's internal S-state directly for the diagram's own
    // synthetic "S-STATE" lane (vcd_to_wavedrom.py's own convention,
    // mirroring read_cycle_tb.sv) -- m68030_top does not expose it as a
    // real port (nothing outside the chip needs to see it), so this is a
    // testbench-only hierarchical tap, the same idiom tb/timing_tb.sv
    // already uses for u_top.u_eu.u_rf.a_reg/sr_out.
    wire [6:0] s_state = u_top.s_state;

    initial begin
        $dumpfile("preview_dispatch.vcd");
        $dumpvars(0, preview_dispatch_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Free-run until MOVE.L (A1),D1 (the second instruction under
        // test) actually retires, mirroring tb/timing_tb.sv's own
        // watch-register technique exactly (same test program, same
        // D1==$22222222 marker). Stopping here -- rather than a fixed
        // generous tick budget -- matters: this RTL's own IFU keeps
        // prefetching well past STOP (this project's own documented
        // "DUT may have extra trailing reads after STOP" convention), so
        // a fixed-budget free-run pushes vcd_to_wavedrom.py's own "last
        // N back-to-back AS windows" past the two reads this diagram
        // exists to show, capturing unrelated post-STOP prefetch traffic
        // instead (found via a first attempt that did exactly this).
        for (int t = 0; t < 2000 && u_top.u_eu.u_rf.d_reg[1] !== 32'h2222_2222; t++)
            @(posedge clk_4x);

        // A few settle cycles so the diagram shows the second read's own
        // bus cycle genuinely completing (AS/DS negated) rather than
        // cutting off mid-signal.
        repeat(8) @(posedge clk_4x);

        $finish;
    end

endmodule

`default_nettype wire

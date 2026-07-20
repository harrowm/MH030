`default_nettype none
`timescale 1ps/1ps

// Phase 78: Musashi instruction test suite DUT testbench (Verilator-compatible)
//
// clk_4x and rst_n are driven from C++ main (no --timing; no always #5).
// Memory is loaded by C++ directly writing mustest_tb.main_mem[] after
// model construction.  pass/fail/stop are exposed as output ports.
//
// Memory map (matches tools/musashi/test/test_driver.c):
//   0x000000-0x00FFFF  main_mem[0:16383]     RAM  — vector table + stack
//   0x010000-0x01FFFF  main_mem[16384:32767]  ROM  — code binary (linked at 0x10000)
//   0x100000-0x10FFFF  test device            writes: +0=FAIL, +4=PASS
//   0x300000-0x30FFFF  ext_ram[0:16383]       extra RAM for memory EA tests

module mustest_tb (
    input  logic        clk_4x,
    input  logic        rst_n,
    output logic        pass_out,
    output logic        fail_out,
    output logic        stop_out
);

    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_e, ext_bg_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;
    logic        eu_stop_out;

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic        vpa_n    = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b0;

    // ── Memory arrays (initialised by C++ main after model construction) ──────
    localparam int MAIN_WORDS = 32768;
    localparam int XRAM_WORDS = 16384;

    logic [31:0] main_mem [0:MAIN_WORDS-1];
    logic [31:0] ext_ram  [0:XRAM_WORDS-1];

    // ── Address decode ────────────────────────────────────────────────────────
    wire sel_main = (ext_a[23:17] == 7'h00);   // 0x000000-0x01FFFF
    wire sel_tdev = (ext_a[23:16] == 8'h10);   // 0x100000-0x10FFFF
    wire sel_xram = (ext_a[23:16] == 8'h30);   // 0x300000-0x30FFFF

    wire [14:0] main_idx = ext_a[16:2];
    wire [13:0] xram_idx = ext_a[15:2];

    wire [31:0] rd_word = sel_main ? main_mem[main_idx] :
                          sel_xram ? ext_ram[xram_idx]  : 32'hDEAD_BEEF;

    // ── DSACK (32-bit port; 1-cycle DS registration latency) ─────────────────
    logic ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) ds_active_r <= 1'b0;
        else        ds_active_r <= !ext_ds_n & !ext_as_n;
    end
    wire dsack0_n = ~ds_active_r;
    wire dsack1_n = ~ds_active_r;

    wire [31:0] ext_d_in = ext_rw ? rd_word : 32'h0;

    // ── Write handler ─────────────────────────────────────────────────────────
    logic pass_seen = 1'b0;
    logic fail_seen = 1'b0;

    always_ff @(posedge clk_4x) begin
        if (ds_active_r && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
            if (sel_tdev) begin
                if (ext_a[7:0] == 8'h00) fail_seen <= 1'b1;   // 0x100000
                if (ext_a[7:0] == 8'h04) pass_seen <= 1'b1;   // 0x100004
            end
            if (sel_main && !ext_a[16]) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: main_mem[main_idx]        <= ext_d_out;
                    4'b10_00: main_mem[main_idx][31:16] <= ext_d_out[31:16];
                    4'b10_10: main_mem[main_idx][15:0]  <= ext_d_out[15:0];
                    4'b01_00: main_mem[main_idx][31:24] <= ext_d_out[31:24];
                    4'b01_01: main_mem[main_idx][23:16] <= ext_d_out[23:16];
                    4'b01_10: main_mem[main_idx][15:8]  <= ext_d_out[15:8];
                    4'b01_11: main_mem[main_idx][7:0]   <= ext_d_out[7:0];
                    default:  main_mem[main_idx]        <= ext_d_out;
                endcase
            end
            if (sel_xram) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: ext_ram[xram_idx]        <= ext_d_out;
                    4'b10_00: ext_ram[xram_idx][31:16] <= ext_d_out[31:16];
                    4'b10_10: ext_ram[xram_idx][15:0]  <= ext_d_out[15:0];
                    4'b01_00: ext_ram[xram_idx][31:24] <= ext_d_out[31:24];
                    4'b01_01: ext_ram[xram_idx][23:16] <= ext_d_out[23:16];
                    4'b01_10: ext_ram[xram_idx][15:8]  <= ext_d_out[15:8];
                    4'b01_11: ext_ram[xram_idx][7:0]   <= ext_d_out[7:0];
                    default:  ext_ram[xram_idx]        <= ext_d_out;
                endcase
            end
        end
    end

    // ── DUT ───────────────────────────────────────────────────────────────────
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
        .ext_rstout_n (ext_rstout_n),
        .ext_cbreq_n  (ext_cbreq_n),
        .ext_e        (ext_e),
        .ext_bg_n     (ext_bg_n),
        .bus_halted   (bus_halted),
        .eu_stop      (eu_stop_out),
        .eu_addr_err  (eu_addr_err),
        .ifu_addr_err (ifu_addr_err),
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
        .cback_n      (cback_n)
    );

    // ── STOP detection ────────────────────────────────────────────────────────
    logic stop_seen = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (eu_stop_out) stop_seen <= 1'b1;
    end

    assign pass_out = pass_seen;
    assign fail_out = fail_seen;
    assign stop_out = stop_seen;

endmodule

`default_nettype wire

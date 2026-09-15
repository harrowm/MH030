`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-36's own
// Synchronous Read-Modify-Write Cycle Timing -- CIIN Asserted (tests/
// timing_manual_736.s header). Combines manual_730_tb.sv's own RMW-lock
// shape (TAS's locked read-then-write, RMC held continuously across
// both phases) with manual_732_tb.sv's own /STERM-terminated,
// always-ready synchronous device model (no DSACKx ever asserts; CIIN
// held asserted throughout, matching the figure's own title) -- unlike
// manual_732_tb.sv this device also accepts writes, since TAS's own
// write phase needs to land somewhere.

module manual_736_tb;

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
    // DSACKx, actually terminates the cycle -- biu_sizing_fsm.sv still
    // samples {dsack1_s,dsack0_s} at S4/S5 regardless of which mechanism
    // terminated the current sub-cycle; leaving both deasserted (2'b11)
    // hangs the FSM forever waiting for sub-cycles STERM's own
    // single-beat termination never provides (manual_732_tb.sv's own
    // header comment has the full derivation).
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
        $readmemh("../tests/timing_manual_736.hex", rom);
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    // Same always-ready synchronous device model as manual_732_tb.sv's
    // own header comment derives (STERM's own single-tick latch window
    // at ST_READ_S2 needs the device ready well before S2, not just by
    // "end of S2" the way DSACKx's own hold-time model tolerates).
    assign sterm_n = 1'b0;
    wire [31:0] ext_d_in = rd_word;

    // Write capture: unlike manual_732_tb.sv (read-only), TAS's own
    // write phase needs a real place to land. No hold-time modeling
    // needed here either -- the device is always ready, so react
    // directly to DS/AS/R-W going active on any given tick.
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
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
        .ciout_n      (ciout_n)
    );

    wire [6:0] s_state = u_top.s_state;

    initial begin
        $dumpfile("manual_736.vcd");
        $dumpvars(0, manual_736_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // TAS sets the Z flag from the byte's pre-TAS value (0) and
        // OR's in $80 -- watch for the byte at $3010 to become $80.
        for (int t = 0; t < 3000 && rom[16'h3010>>2][31:24] !== 8'h80; t++)
            @(posedge clk_4x);

        repeat(8) @(posedge clk_4x);

        $display("FINAL byte@$3010 = %02x", rom[16'h3010>>2][31:24]);
        $finish;
    end

endmodule

`default_nettype wire

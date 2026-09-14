`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-23's own
// Long-Word Read -- 16-Bit Port (tests/timing_manual_723.s header). Same
// hybrid-memory-region shape as manual_722_tb.sv: ordinary 32-bit inline
// model serves code/vectors/stack, a narrow $100-$1FF region (routed to
// tb/mem_model.sv, PORT_WIDTH=16) serves the target read.

module manual_723_tb;

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

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        $readmemh("../tests/timing_manual_723.hex", rom);
    end

    wire in_narrow = (ext_a[31:8] == 24'h000001);

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    logic ds_active_r1, ds_active_r2;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ds_active_r1 <= 1'b0;
            ds_active_r2 <= 1'b0;
        end else begin
            ds_active_r1 <= !ext_ds_n & !ext_as_n & !in_narrow;
            ds_active_r2 <= ds_active_r1;
        end
    end

    localparam int HOLD_TICKS = 4;
    logic [2:0] hold_cnt_r;
    logic       hold_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt_r    <= '0;
            hold_active_r <= 1'b0;
        end else if (ds_active_r2) begin
            hold_cnt_r    <= HOLD_TICKS[2:0];
            hold_active_r <= 1'b1;
        end else if (hold_cnt_r != 0) begin
            hold_cnt_r    <= hold_cnt_r - 3'd1;
            hold_active_r <= 1'b1;
        end else begin
            hold_active_r <= 1'b0;
        end
    end

    logic [31:0] held_data_r;
    always_ff @(posedge clk_4x) begin
        if (ds_active_r2) held_data_r <= rd_word;
    end

    wire dev_data_valid = ds_active_r2 || hold_active_r;
    wire inline_dsack0_n = ~dev_data_valid;
    wire inline_dsack1_n = ~dev_data_valid;

    wire [31:0] inline_d_in = ds_active_r2 ? rd_word :
                               hold_active_r ? held_data_r : {32{1'bz}};

    always_ff @(posedge clk_4x) begin
        if (ds_active_r2 && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
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

    wire narrow_as_n = in_narrow ? ext_as_n : 1'b1;
    wire narrow_ds_n = in_narrow ? ext_ds_n : 1'b1;
    wire [31:0] narrow_d_in;
    wire narrow_dsack0_n, narrow_dsack1_n;

    mem_model #(.DEPTH(256), .PORT_WIDTH(16), .WAIT_STATES(0)) u_mem16 (
        .clk_4x           (clk_4x),
        .rst_n            (rst_n),
        .ext_a            (ext_a),
        .ext_as_n         (narrow_as_n),
        .ext_ds_n         (narrow_ds_n),
        .ext_rw           (ext_rw),
        .ext_siz          (ext_siz),
        .ext_d_in         (narrow_d_in),
        .dsack0_n         (narrow_dsack0_n),
        .dsack1_n         (narrow_dsack1_n),
        .ext_d_write      (ext_d_out),
        .ext_d_oe         (ext_d_oe),
        .burst_beat_probe (2'b00)
    );

    wire [31:0] ext_d_in  = in_narrow ? narrow_d_in  : inline_d_in;
    wire        dsack0_n  = in_narrow ? narrow_dsack0_n : inline_dsack0_n;
    wire        dsack1_n  = in_narrow ? narrow_dsack1_n : inline_dsack1_n;

    initial begin
        // Marker longword at $100 -- mem_model indexes by the raw absolute
        // word address (ext_a[31:2]), so $100 is word index 64.
        u_mem16.mem[64] = 32'h1122_3344;
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

    wire [6:0] s_state = u_top.s_state;

    initial begin
        $dumpfile("manual_723.vcd");
        $dumpvars(0, manual_723_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        for (int t = 0; t < 3000 && u_top.u_eu.u_rf.d_reg[0] !== 32'h1122_3344; t++)
            @(posedge clk_4x);

        repeat(8) @(posedge clk_4x);

        $display("FINAL d_reg[0] = %08x", u_top.u_eu.u_rf.d_reg[0]);
        $finish;
    end

endmodule

`default_nettype wire

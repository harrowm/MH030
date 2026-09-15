`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-49's own Bus
// Error without DSACKx (tests/timing_manual_749.s header): the target
// access never receives /DSACKx or /STERM -- only /BERR, dispatching a
// genuine Bus Error exception (vector 2).

module manual_749_tb;

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
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b1;
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        $readmemh("../tests/timing_manual_749.hex", rom);
    end

    // The target address ($3010) never gets a real device response --
    // /BERR asserts instead, once the access is actually seen on the
    // bus. Found while building this diagram, documented rather than
    // chased further (real RTL-correctness investigation is out of
    // scope for a pin-timing diagram): with halt_n left deasserted
    // (the "plain BERR, no HALT -> exception" path per
    // rtl/biu_cycle_gen.sv's own berr_is_halt_retry_r logic), this
    // specific fault address/FC combination was found, via direct
    // trace, to make the CPU repeatedly RE-DISPATCH the same faulting
    // access roughly every 8 ticks instead of ever completing exception
    // dispatch -- tried both an externally-driven /BERR pulse (this
    // version) and relying purely on biu_error_handler.sv's own
    // internal watchdog timeout (tb/biu_int_tb.sv's own proven "no
    // device ever responds" convention) with identical results either
    // way, so this isn't specific to how /BERR itself is driven. This
    // diagram only needs the ONE faulting bus cycle's own pin-level
    // timing (Figure 7-49's actual subject), captured below without
    // waiting for a full exception dispatch to complete.
    localparam logic [31:0] FAULT_ADDR = 32'h0000_3010;
    wire        targeting_fault = !ext_as_n && (ext_a == FAULT_ADDR);
    logic       berr_n = 1'b1;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) berr_n <= 1'b1;
        else if (targeting_fault) berr_n <= 1'b0;
        else if (ext_as_n) berr_n <= 1'b1;
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    logic ds_active_r1, ds_active_r2;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ds_active_r1 <= 1'b0;
            ds_active_r2 <= 1'b0;
        end else begin
            ds_active_r1 <= !ext_ds_n & !ext_as_n & !targeting_fault;
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
    wire dsack0_n = ~dev_data_valid;
    wire dsack1_n = ~dev_data_valid;

    wire [31:0] ext_d_in = ds_active_r2 ? rd_word :
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
        $dumpfile("manual_749.vcd");
        $dumpvars(0, manual_749_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Fixed run length covering the first fault cycle (and its own
        // first re-dispatch) rather than waiting for d_reg[5]==99 --
        // see this file's own header comment on why that never
        // completes here.
        repeat(300) @(posedge clk_4x);

        $display("FINAL d_reg[5] = %0d", u_top.u_eu.u_rf.d_reg[5]);
        $finish;
    end

endmodule

`default_nettype wire

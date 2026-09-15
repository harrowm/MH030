`default_nettype none
`timescale 1ns / 1ps

// Timing-diagram source testbench: MC68030UM.pdf Figure 7-44 (Interrupt
// Acknowledge Cycle Timing) / Figure 7-45 (Autovector Operation Timing),
// tests/timing_manual_744.s header. Driven through the REAL EU/decode
// pipeline: a genuine level-7 (NMI) interrupt request, recognized at the
// next instruction boundary, dispatches a real CPU-space IACK bus cycle
// (biu_cycle_gen.sv), auto-answered here with /AVEC (autovector) --
// mirrors tb/stall_fsm_tb.sv's own established auto-AVEC responder
// pattern exactly (iack_cycle_active decode: AS asserted, FC=111, A[31:4]
// all ones -- matches biu_cycle_gen.sv's own IACK dispatch address).

module manual_744_tb;

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
        $readmemh("../tests/timing_manual_744.hex", rom);
        rom[16'h3010 >> 2] = 32'hCAFE_F00D;
    end

    // Real IACK cycle, auto-answered with /AVEC (autovector) -- matches
    // tb/stall_fsm_tb.sv's own established pattern exactly.
    wire iack_cycle_active = !ext_as_n && (ext_fc == 3'b111) && (ext_a[31:4] == 28'hFFFFFFF);
    wire avec_n = !iack_cycle_active;

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    logic ds_active_r1, ds_active_r2;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ds_active_r1 <= 1'b0;
            ds_active_r2 <= 1'b0;
        end else begin
            ds_active_r1 <= !ext_ds_n & !ext_as_n;
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

    // Ordinary reads/writes get DSACK; a genuine IACK cycle is answered
    // via /AVEC instead (dsack stays deasserted for it, matching real
    // autovector protocol -- the peripheral drives NEITHER DSACKx).
    wire dev_data_valid = (ds_active_r2 || hold_active_r) && !iack_cycle_active;
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
        $dumpfile("manual_744.vcd");
        $dumpvars(0, manual_744_tb);

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Request a genuine level-7 (NMI) interrupt immediately -- the
        // test program loops in place (bra.s) after its own read rather
        // than using STOP (tb/stall_fsm_tb.sv's own established
        // "quiescent self-loop" convention for interrupt injection):
        // found, via direct trace, that recognizing an already-pending
        // interrupt while genuinely STOPped takes far longer in this RTL
        // than recognizing one between ordinary instructions -- not a
        // bug (STOP+interrupt already has its own dedicated, passing
        // coverage elsewhere, e.g. Phase 250 F9's own STOP+trace work),
        // just a different, slower path than this diagram needs.
        ipl_n = 3'b000;

        // Wait for dispatch to start (exc_active), then for it to finish
        // again (RTE completed) -- keeps the recorded VCD tight around
        // the IACK+autovector+frame-push sequence itself, not padded
        // with a long, arbitrary run of unrelated trailing activity that
        // would push the diagram's own "last N cycles" window off the
        // interesting part. 400-tick bound matches tb/stall_fsm_tb.sv's
        // own SPURIOUS-INT test's identical wait.
        for (int t = 0; t < 400 && !u_top.u_exc.exc_active; t++)
            @(posedge clk_4x);
        ipl_n = 3'b111;
        for (int t = 0; t < 400 && u_top.u_exc.exc_active; t++)
            @(posedge clk_4x);

        // Minimal tail (just enough for the last write's own data/DSACK
        // hold time to settle) -- the CPU resumes its own self-loop
        // fetch immediately once exc_active clears (RTE completed), and
        // a longer tail here would let 1-2 of those trailing refetches
        // become part of the diagram's own "last N cycles" window
        // instead of the actual IACK+frame-push sequence (confirmed via
        // a direct look at the first attempt's own rendered diagram,
        // which showed a repeating self-loop-fetch pattern instead).
        repeat(6) @(posedge clk_4x);

        $display("FINAL d_reg[0] = %08x", u_top.u_eu.u_rf.d_reg[0]);
        $finish;
    end

endmodule

`default_nettype wire

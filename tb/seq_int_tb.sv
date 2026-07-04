`default_nettype none
`timescale 1ns/1ps

// m68030_seq integration testbench — Phase 32
// Wires m68030_ifu + m68030_seq + m68030_eu and runs a tiny program:
//
//   0x1000: CLR.L  D0          (1 word;  0x4280)
//   0x1002: ADDI.L #42, D0     (3 words; 0x0680 0x0000 0x002A)
//   0x1008: CLR.L  D1          (1 word;  0x4281)
//   0x100A: ADD.L  D0, D1      (1 word;  0xD280)
//   0x100C: NOP                 (stalls pipeline — no drain, acts as HALT)
//
// Expected final state: D0=42, D1=42.
//
// Compile:
//   iverilog -g2012 -o /tmp/phase32i.vvp -I rtl \
//     rtl/m68030_ifu.sv rtl/m68030_seq.sv rtl/m68030_eu.sv \
//     rtl/eu_seq.sv rtl/eu_regfile.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
//     rtl/eu_mul_div.sv rtl/eu_bcd.sv rtl/eu_bitops.sv \
//     tb/seq_int_tb.sv
//   vvp /tmp/phase32i.vvp

module seq_int_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;  // 100 MHz 4× clock

    // -----------------------------------------------------------------------
    // PC write (shared to IFU and EU)
    // -----------------------------------------------------------------------
    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 0;

    // -----------------------------------------------------------------------
    // IFU ↔ BIU stub
    // -----------------------------------------------------------------------
    logic [31:0] ifu_addr;
    logic        ifu_req;
    logic [31:0] ifu_rdata;
    logic        ifu_ack;
    logic        ifu_berr = 0;

    // 4-entry stub ROM (each entry = one longword fetch)
    logic [31:0] rom [0:3];
    initial begin
        // 0x1000: CLR.L D0 (0x4280) | ADDI.L opcode (0x0680)
        rom[0] = 32'h4280_0680;
        // 0x1004: ADDI.L immediate MSW=0x0000, LSW=0x002A (42 decimal)
        rom[1] = 32'h0000_002A;
        // 0x1008: CLR.L D1 (0x4281) | ADD.L D0,D1 (0xD280)
        rom[2] = 32'h4281_D280;
        // 0x100C: NOP (0x4E71) — stalls pipeline, acts as halt
        rom[3] = 32'h4E71_4E71;
    end
    // ROM selected by address bits [3:2] (covers 0x1000–0x100C)
    assign ifu_rdata = rom[ifu_addr[3:2]];
    assign ifu_ack   = ifu_req;   // zero-latency stub

    // -----------------------------------------------------------------------
    // IFU ↔ SEQ wires
    // -----------------------------------------------------------------------
    logic [15:0] ifu_instr_word;
    logic [31:0] ifu_ext_data;
    logic        ifu_instr_valid;
    logic        ifu_ext_valid;
    logic [1:0]  drain;

    // -----------------------------------------------------------------------
    // SEQ ↔ EU wires
    // -----------------------------------------------------------------------
    logic [15:0] eu_instr_word;
    logic [31:0] eu_ext_data;
    logic        eu_instr_valid;
    logic        eu_ext_valid;
    logic        eu_instr_ack;
    logic        eu_busy;

    // -----------------------------------------------------------------------
    // EU misc outputs (not checked here)
    // -----------------------------------------------------------------------
    logic [31:0] pc_out, vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;

    // -----------------------------------------------------------------------
    // m68030_ifu
    // -----------------------------------------------------------------------
    m68030_ifu u_ifu (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .pc_wr_en     (pc_wr_en),
        .pc_wr_data   (pc_wr_data),
        .drain        (drain),
        .instr_word   (ifu_instr_word),
        .ext_data     (ifu_ext_data),
        .instr_valid  (ifu_instr_valid),
        .ext_valid    (ifu_ext_valid),
        .decode_pc    (),
        .ifu_addr     (ifu_addr),
        .ifu_req      (ifu_req),
        .ifu_rdata    (ifu_rdata),
        .ifu_ack      (ifu_ack),
        .ifu_berr     (ifu_berr),
        .supervisor   (supervisor),
        .fc_out       (),
        .bus_err      (),
        .bus_err_addr (),
        .addr_err     ()
    );

    // -----------------------------------------------------------------------
    // m68030_seq
    // -----------------------------------------------------------------------
    m68030_seq u_seq (
        .instr_word     (ifu_instr_word),
        .ifu_ext_data   (ifu_ext_data),
        .instr_valid    (ifu_instr_valid),
        .ifu_ext_valid  (ifu_ext_valid),
        .drain          (drain),
        .eu_instr_word  (eu_instr_word),
        .eu_ext_data    (eu_ext_data),
        .eu_instr_valid (eu_instr_valid),
        .eu_ext_valid   (eu_ext_valid),
        .eu_instr_ack   (eu_instr_ack),
        .eu_busy        (eu_busy)
    );

    // -----------------------------------------------------------------------
    // m68030_eu
    // -----------------------------------------------------------------------
    m68030_eu u_eu (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .instr_word  (eu_instr_word),
        .instr_valid (eu_instr_valid),
        .ext_data    (eu_ext_data),
        .ext_valid   (eu_ext_valid),
        .instr_ack   (eu_instr_ack),
        .eu_busy     (eu_busy),
        .pc_wr_en    (pc_wr_en),
        .pc_wr_data  (pc_wr_data),
        .pc_out      (pc_out),
        .vbr_wr_en   (1'b0),
        .vbr_wr_data (32'h0),
        .vbr_out     (vbr_out),
        .usp_out     (usp_out),
        .msp_out     (msp_out),
        .isp_out     (isp_out),
        .sr_out      (sr_out),
        .supervisor  (supervisor),
        .master_mode (master_mode),
        .ipl_mask    (ipl_mask),
        .div_trap    (div_trap)
    );

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    integer fail;
    initial begin
        fail = 0;

        // Hold reset for 2 cycles
        repeat (2) @(posedge clk_4x);
        rst_n = 1;
        @(posedge clk_4x); #1;

        // Write PC = 0x1000, kick IFU + EU
        pc_wr_en   = 1;
        pc_wr_data = 32'h0000_1000;
        @(posedge clk_4x); #1;
        pc_wr_en = 0;

        // Wait long enough for all 4 instructions to complete.
        // Pipeline: IFU latency (2 fetches), ADDI.L stall, 2× RAW stalls.
        // 30 cycles is comfortably longer than required.
        repeat (30) @(posedge clk_4x);
        #1;

        // ----------------------------------------------------------------
        // INT-1: D0 = 42 (CLR then ADDI.L #42)
        // ----------------------------------------------------------------
        if (u_eu.u_rf.d_reg[0] !== 32'd42) begin
            $display("FAIL INT-1: D0=%0d (exp 42)", u_eu.u_rf.d_reg[0]);
            fail = fail + 1;
        end else $display("PASS INT-1: D0=42");

        // ----------------------------------------------------------------
        // INT-2: D1 = 42 (CLR then ADD.L D0,D1)
        // ----------------------------------------------------------------
        if (u_eu.u_rf.d_reg[1] !== 32'd42) begin
            $display("FAIL INT-2: D1=%0d (exp 42)", u_eu.u_rf.d_reg[1]);
            fail = fail + 1;
        end else $display("PASS INT-2: D1=42");

        if (fail == 0)
            $display("ALL INTEGRATION TESTS PASSED");
        else
            $display("%0d INTEGRATION TEST(S) FAILED", fail);

        $finish;
    end

    // Timeout watchdog
    initial begin
        #10000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

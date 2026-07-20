`default_nettype none
`timescale 1ns/1ps

// m68030_seq standalone testbench — Phase 32
// Verifies drain count, ext_data format conversion, and EU-busy stall.
//
// Run: iverilog -g2012 -o /tmp/phase32.vvp -I rtl rtl/m68030_seq.sv tb/seq_tb.sv
//      vvp /tmp/phase32.vvp

module seq_tb;

    logic [15:0] instr_word;
    logic [31:0] ifu_ext_data;
    logic [15:0] ifu_q3_word;
    logic [31:0] ifu_ext34_data;
    logic        instr_valid;
    logic        ifu_ext_valid;
    logic        ifu_ext4_valid;
    logic        ifu_ext5_valid;
    logic [2:0]  drain;
    logic [15:0] eu_instr_word;
    logic [31:0] eu_ext_data;
    logic [15:0] eu_q3_word;
    logic [31:0] eu_ext34_data;
    logic        eu_instr_valid;
    logic        eu_ext_valid;
    logic        eu_instr_ack;
    logic        eu_busy;

    m68030_seq dut (.*);

    integer fail;
    initial fail = 0;

    // All outputs are combinational — just drive inputs and check after #1.
    task check_drain;
        input [255:0] name;
        input [1:0]   exp_drain;
        begin
            #1;
            if (drain !== exp_drain) begin
                $display("FAIL %0s: drain=%0d exp=%0d", name, drain, exp_drain);
                fail = fail + 1;
            end else $display("PASS %0s drain=%0d", name, drain);
        end
    endtask

    // check_ext: reads eu_ext_data directly after #1 (avoids arg-eval-before-settle issue)
    task check_ext;
        input [255:0] name;
        input [31:0]  exp;
        begin
            #1;
            if (eu_ext_data !== exp) begin
                $display("FAIL %0s: got=%08h exp=%08h", name, eu_ext_data, exp);
                fail = fail + 1;
            end else $display("PASS %0s got=%08h", name, eu_ext_data);
        end
    endtask

    // Instruction encodings used in tests
    // CLR.L D0: group 4, f_dn=001 (CLR), f_ss=10 (long), f_mode=000, f_reg=000
    localparam CLR_L_D0   = 16'h4280;
    // ADDI.B #,D0: group 0, f_dn=011 (ADDI), f_dir=0, f_ss=00 (byte), f_mode=000, f_reg=000
    localparam ADDI_B_D0  = 16'h0600;
    // ADDI.W #,D0: group 0, f_dn=011, f_ss=01 (word)
    localparam ADDI_W_D0  = 16'h0640;
    // ADDI.L #,D0: group 0, f_dn=011, f_ss=10 (long)
    localparam ADDI_L_D0  = 16'h0680;
    // BTST #n,D0: group 0, f_dn=100, f_dir=0, f_ss=00 (BTST), f_mode=000, f_reg=000
    localparam BTST_IMM_D0 = 16'h0800;
    // BSET #n,D0: group 0, f_dn=100, f_dir=0, f_ss=11 (BSET), f_mode=000, f_reg=000
    localparam BSET_IMM_D0 = 16'h08C0;
    // BSET D5,D0: group 0, f_dn=101 (D5), f_dir=1, f_ss=11, f_mode=000, f_reg=000
    localparam BSET_REG_D0 = 16'h0BC0;
    // MOVE.L D1→D0: group 2 (long), f_dir=0, f_ss=00, f_mode=000
    localparam MOVE_L_D1_D0 = 16'h2001;
    // OR.L D0,D1: group 8, f_dn=001, f_dir=0, f_ss=10, f_mode=000, f_reg=000
    localparam OR_L_D0_D1   = 16'h8280;

    initial begin
        // Defaults
        instr_word    = 16'h0;
        ifu_ext_data  = 32'h0;
        instr_valid   = 1'b0;
        ifu_ext_valid = 1'b0;
        eu_instr_ack  = 1'b0;
        eu_busy       = 1'b0;

        // ----------------------------------------------------------------
        // SEQ-1: 0-extension-word instructions — drain=1 when acked
        // ----------------------------------------------------------------

        // CLR.L D0 (no extension word)
        instr_word = CLR_L_D0; instr_valid = 1; eu_instr_ack = 1;
        check_drain("SEQ-1a CLR.L drain", 2'd1);

        // MOVE.L D1,D0 (no extension word)
        instr_word = MOVE_L_D1_D0;
        check_drain("SEQ-1b MOVE.L drain", 2'd1);

        // OR.L D0,D1 (no extension word)
        instr_word = OR_L_D0_D1;
        check_drain("SEQ-1c OR.L drain", 2'd1);

        // Register BSET D5,D0 (f_dir=1 → 0 ext words)
        instr_word = BSET_REG_D0;
        check_drain("SEQ-1d BSET Dn drain", 2'd1);

        // ----------------------------------------------------------------
        // SEQ-2: 1-extension-word instructions — drain=2 when acked
        // ----------------------------------------------------------------

        // ADDI.B #imm,D0
        instr_word = ADDI_B_D0;
        check_drain("SEQ-2a ADDI.B drain", 2'd2);

        // ADDI.W #imm,D0
        instr_word = ADDI_W_D0;
        check_drain("SEQ-2b ADDI.W drain", 2'd2);

        // BTST #n,D0 (immediate bit ops always 1 ext word)
        instr_word = BTST_IMM_D0;
        check_drain("SEQ-2c BTST# drain", 2'd2);

        // BSET #n,D0
        instr_word = BSET_IMM_D0;
        check_drain("SEQ-2d BSET# drain", 2'd2);

        // ----------------------------------------------------------------
        // SEQ-3: 2-extension-word instructions (long immediate) — drain=3
        // ----------------------------------------------------------------
        instr_word = ADDI_L_D0;
        check_drain("SEQ-3 ADDI.L drain", 2'd3);

        // ----------------------------------------------------------------
        // SEQ-4: drain=0 when eu_instr_ack=0 (EU busy or not acking)
        // ----------------------------------------------------------------
        instr_word = ADDI_L_D0; eu_instr_ack = 0;
        check_drain("SEQ-4a drain=0 when not acked (long)", 2'd0);

        instr_word = CLR_L_D0;
        check_drain("SEQ-4b drain=0 when not acked (0-ext)", 2'd0);

        instr_word = ADDI_B_D0;
        check_drain("SEQ-4c drain=0 when not acked (byte)", 2'd0);

        // ----------------------------------------------------------------
        // SEQ-5: eu_instr_valid = instr_valid pass-through
        // ----------------------------------------------------------------
        instr_valid = 1'b1; #1;
        if (eu_instr_valid !== 1'b1) begin
            $display("FAIL SEQ-5a eu_instr_valid not passed (got %b)", eu_instr_valid);
            fail = fail + 1;
        end else $display("PASS SEQ-5a eu_instr_valid=1");

        instr_valid = 1'b0; #1;
        if (eu_instr_valid !== 1'b0) begin
            $display("FAIL SEQ-5b eu_instr_valid=0 not passed");
            fail = fail + 1;
        end else $display("PASS SEQ-5b eu_instr_valid=0");

        // ----------------------------------------------------------------
        // SEQ-6: eu_ext_valid = ifu_ext_valid pass-through
        // ----------------------------------------------------------------
        ifu_ext_valid = 1'b1; #1;
        if (eu_ext_valid !== 1'b1) begin
            $display("FAIL SEQ-6a eu_ext_valid not passed");
            fail = fail + 1;
        end else $display("PASS SEQ-6a eu_ext_valid=1");

        // ----------------------------------------------------------------
        // SEQ-7: ext_data format conversion
        // ----------------------------------------------------------------

        // SEQ-7a: byte immediate — ADDI.B #0x42, D0
        // IFU ext_data: {0x0042, 0x????} → first ext word in [31:16] = 0x0042
        // eu_ext_data = {16'h0, 0x0042} = 0x00000042
        instr_word = ADDI_B_D0; ifu_ext_data = {16'h0042, 16'hDEAD};
        check_ext("SEQ-7a byte imm → 0x00000042", 32'h00000042);

        // SEQ-7b: word immediate — ADDI.W #0x1234, D0
        // First ext word = 0x1234 → eu_ext_data = {16'h0, 0x1234} = 0x00001234
        instr_word = ADDI_W_D0; ifu_ext_data = {16'h1234, 16'hBEEF};
        check_ext("SEQ-7b word imm → 0x00001234", 32'h00001234);

        // SEQ-7c: long immediate — ADDI.L #0x12345678, D0
        // IFU ext_data = {MSW=0x1234, LSW=0x5678} = 0x12345678 as-is
        instr_word = ADDI_L_D0; ifu_ext_data = 32'h12345678;
        check_ext("SEQ-7c long imm → 0x12345678", 32'h12345678);

        // SEQ-7d: bit number (BTST #5, D0)
        // First ext word = 0x0005 → eu_ext_data = {16'h0, 0x0005} = 0x00000005
        instr_word = BTST_IMM_D0; ifu_ext_data = {16'h0005, 16'hDEAD};
        check_ext("SEQ-7d bit# → 0x00000005", 32'h00000005);

        // SEQ-7e: 0-ext instruction — ext_count=0 uses same path as 1-ext
        // eu_ext_data = {16'h0, ifu_ext_data[31:16]} = {16'h0, 0xDEAD} = 0x0000DEAD
        instr_word = CLR_L_D0; ifu_ext_data = 32'hDEADBEEF;
        check_ext("SEQ-7e 0-ext → 0x0000DEAD", 32'h0000DEAD);

        // ----------------------------------------------------------------
        // SEQ-8: eu_instr_word pass-through
        // ----------------------------------------------------------------
        instr_word = 16'hABCD; #1;
        if (eu_instr_word !== 16'hABCD) begin
            $display("FAIL SEQ-8 eu_instr_word pass-through");
            fail = fail + 1;
        end else $display("PASS SEQ-8 eu_instr_word pass-through");

        // ----------------------------------------------------------------
        if (fail == 0)
            $display("ALL SEQ TESTS PASSED");
        else
            $display("%0d SEQ TEST(S) FAILED", fail);

        $finish;
    end

endmodule

`default_nettype wire

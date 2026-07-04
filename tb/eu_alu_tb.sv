`default_nettype none
`timescale 1ps/1ps

// Phase 24: eu_alu unit testbench
// Tests: ADD/ADDX, SUB/SUBX, NEG/NEGX, CMP, AND/OR/EOR/NOT, TST/CLR,
//        all three sizes (byte/word/long), carry/borrow, overflow, Z-preserve.

module eu_alu_tb;

    // ALU is purely combinational — no clock needed, but declare for convention
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    // DUT ports
    logic [31:0] src   = 0;
    logic [31:0] dst   = 0;
    logic [3:0]  op    = 0;
    logic [1:0]  siz   = 2'b01;   // default: byte
    logic        x_in  = 0;
    logic        z_in  = 0;

    logic [31:0] result;
    logic        n_out, z_out, v_out, c_out, x_out;

    // Operation codes (must match eu_alu localparams)
    localparam [3:0]
        ALU_ADD  = 4'h0,
        ALU_ADDX = 4'h1,
        ALU_SUB  = 4'h2,
        ALU_SUBX = 4'h3,
        ALU_NEG  = 4'h4,
        ALU_NEGX = 4'h5,
        ALU_AND  = 4'h6,
        ALU_OR   = 4'h7,
        ALU_EOR  = 4'h8,
        ALU_NOT  = 4'h9,
        ALU_CMP  = 4'hA,
        ALU_TST  = 4'hB,
        ALU_CLR  = 4'hC;

    eu_alu u_alu (
        .src    (src),
        .dst    (dst),
        .op     (op),
        .siz    (siz),
        .x_in   (x_in),
        .z_in   (z_in),
        .result (result),
        .n_out  (n_out),
        .z_out  (z_out),
        .v_out  (v_out),
        .c_out  (c_out),
        .x_out  (x_out)
    );

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    // Apply ALU inputs and wait 1ps for combinational outputs to settle
    task apply(
        input logic [3:0]  o, input logic [1:0] sz,
        input logic [31:0] d, input logic [31:0] s,
        input logic xi, input logic zi
    );
        op = o; siz = sz; dst = d; src = s; x_in = xi; z_in = zi;
        #1;
    endtask

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 24: eu_alu ===");

        // ================================================================
        // A: ADD / ADDX  (byte unless noted)
        // ================================================================
        $display("--- A: ADD/ADDX ---");

        // A1: basic add, no flags
        apply(ALU_ADD, 2'b01, 32'd1, 32'd2, 0, 0);
        check32("A1a: 1+2=3",     result, 32'h3);
        check("A1a: N=0", !n_out); check("A1a: Z=0", !z_out);
        check("A1a: V=0", !v_out); check("A1a: C=0", !c_out);

        // A2: byte add with overflow (positive+positive=negative)
        apply(ALU_ADD, 2'b01, 32'h7F, 32'h01, 0, 0);
        check32("A2a: 0x7F+1=0x80", result, 32'h80);
        check("A2a: N=1",  n_out); check("A2a: Z=0", !z_out);
        check("A2a: V=1",  v_out); check("A2a: C=0", !c_out);

        // A3: byte add with carry (unsigned overflow)
        apply(ALU_ADD, 2'b01, 32'hFF, 32'h01, 0, 0);
        check32("A3a: 0xFF+1=0x00", result, 32'h00);
        check("A3a: N=0", !n_out); check("A3a: Z=1",  z_out);
        check("A3a: V=0", !v_out); check("A3a: C=1",  c_out);

        // A4: ADDX byte with X=1
        apply(ALU_ADDX, 2'b01, 32'h01, 32'h02, 1, 0);
        check32("A4a: 1+2+X=4",   result, 32'h4);
        check("A4a: C=0", !c_out); check("A4a: X=0", !x_out);

        // A5: ADDX Z-preserve — result=0, Z follows z_in
        // 0x80 + 0x80 + X=0 → 0x00, carry=1
        apply(ALU_ADDX, 2'b01, 32'h80, 32'h80, 0, 1);  // z_in=1
        check32("A5a: 0x80+0x80+X=0x00", result, 32'h00);
        check("A5a: Z preserved (z_in=1)", z_out == 1'b1);
        check("A5a: C=1", c_out);

        apply(ALU_ADDX, 2'b01, 32'h80, 32'h80, 0, 0);  // z_in=0
        check("A5b: Z preserved (z_in=0)", z_out == 1'b0);

        // A6: ADDX result nonzero always clears Z
        apply(ALU_ADDX, 2'b01, 32'h01, 32'h00, 0, 1);  // 1+0+0=1; z_in=1
        check("A6a: ADDX Z cleared when result!=0", z_out == 1'b0);

        // ================================================================
        // B: SUB / SUBX
        // ================================================================
        $display("--- B: SUB/SUBX ---");

        // B1: basic subtract, no borrow
        apply(ALU_SUB, 2'b01, 32'd5, 32'd3, 0, 0);
        check32("B1a: 5-3=2",     result, 32'h2);
        check("B1a: N=0", !n_out); check("B1a: Z=0", !z_out);
        check("B1a: V=0", !v_out); check("B1a: C=0", !c_out);

        // B2: byte subtract with borrow (0 - 1)
        apply(ALU_SUB, 2'b01, 32'h00, 32'h01, 0, 0);
        check32("B2a: 0-1=0xFF",  result, 32'hFF);
        check("B2a: N=1",  n_out); check("B2a: Z=0", !z_out);
        check("B2a: V=0", !v_out); check("B2a: C=1",  c_out);

        // B3: byte subtract overflow (negative - positive = positive)
        apply(ALU_SUB, 2'b01, 32'h80, 32'h01, 0, 0);
        check32("B3a: 0x80-1=0x7F", result, 32'h7F);
        check("B3a: V=1",  v_out);
        check("B3a: C=0", !c_out);

        // B4: subtract giving zero
        apply(ALU_SUB, 2'b01, 32'h05, 32'h05, 0, 0);
        check32("B4a: 5-5=0",    result, 32'h0);
        check("B4a: Z=1",  z_out);
        check("B4a: C=0", !c_out);

        // B5: SUBX byte 5-3-X=1 → 1
        apply(ALU_SUBX, 2'b01, 32'h05, 32'h03, 1, 0);
        check32("B5a: 5-3-X=1",  result, 32'h1);
        check("B5a: Z=0 (nonzero)", !z_out);

        // B6: SUBX Z-preserve: 3-3-0=0 → Z follows z_in
        apply(ALU_SUBX, 2'b01, 32'h03, 32'h03, 0, 1);  // z_in=1
        check32("B6a: 3-3-0=0",   result, 32'h0);
        check("B6a: Z preserved (z_in=1)", z_out == 1'b1);

        apply(ALU_SUBX, 2'b01, 32'h03, 32'h03, 0, 0);  // z_in=0
        check("B6b: Z preserved (z_in=0)", z_out == 1'b0);

        // ================================================================
        // C: NEG / NEGX
        // ================================================================
        $display("--- C: NEG/NEGX ---");

        // C1: NEG byte 1 → -1 = 0xFF
        apply(ALU_NEG, 2'b01, 32'h01, 32'h00, 0, 0);
        check32("C1a: NEG 1 = 0xFF",   result, 32'hFF);
        check("C1a: N=1",  n_out); check("C1a: C=1",  c_out);
        check("C1a: V=0", !v_out);

        // C2: NEG byte 0x80 → 0x80 (overflow)
        apply(ALU_NEG, 2'b01, 32'h80, 32'h00, 0, 0);
        check32("C2a: NEG 0x80 = 0x80", result, 32'h80);
        check("C2a: V=1",  v_out); check("C2a: C=1",  c_out);

        // C3: NEG byte 0 → 0, no borrow
        apply(ALU_NEG, 2'b01, 32'h00, 32'h00, 0, 0);
        check32("C3a: NEG 0 = 0",       result, 32'h0);
        check("C3a: Z=1",  z_out); check("C3a: C=0", !c_out);
        check("C3a: V=0", !v_out);

        // C4: NEGX byte 1, X=0 → -1 = 0xFF
        apply(ALU_NEGX, 2'b01, 32'h01, 32'h00, 0, 0);
        check32("C4a: NEGX 1+X=0 = 0xFF", result, 32'hFF);
        check("C4a: C=1", c_out);

        // C5: NEGX byte 0, X=0 → 0; Z preserved from z_in
        apply(ALU_NEGX, 2'b01, 32'h00, 32'h00, 0, 1);  // z_in=1
        check32("C5a: NEGX 0+X=0 = 0",   result, 32'h0);
        check("C5a: C=0",  !c_out);
        check("C5a: Z preserved (z_in=1)", z_out == 1'b1);

        // C6: NEGX byte 0, X=1 → -1 = 0xFF; nonzero clears Z
        apply(ALU_NEGX, 2'b01, 32'h00, 32'h00, 1, 1);  // z_in=1 but result!=0
        check32("C6a: NEGX 0+X=1 = 0xFF", result, 32'hFF);
        check("C6a: C=1",  c_out);
        check("C6a: Z=0 (result nonzero)", !z_out);

        // ================================================================
        // D: Logical operations
        // ================================================================
        $display("--- D: AND/OR/EOR/NOT ---");

        // D1: AND
        apply(ALU_AND, 2'b01, 32'hFF, 32'h0F, 0, 0);
        check32("D1a: 0xFF & 0x0F = 0x0F", result, 32'h0F);
        check("D1a: N=0", !n_out); check("D1a: V=0", !v_out); check("D1a: C=0", !c_out);

        apply(ALU_AND, 2'b01, 32'hFF, 32'h00, 0, 0);
        check32("D1b: 0xFF & 0x00 = 0x00", result, 32'h0);
        check("D1b: Z=1",  z_out);

        // D2: OR
        apply(ALU_OR, 2'b01, 32'hF0, 32'h0F, 0, 0);
        check32("D2a: 0xF0 | 0x0F = 0xFF", result, 32'hFF);
        check("D2a: N=1",  n_out); check("D2a: Z=0", !z_out);

        // D3: EOR
        apply(ALU_EOR, 2'b01, 32'hFF, 32'hFF, 0, 0);
        check32("D3a: 0xFF ^ 0xFF = 0x00", result, 32'h0);
        check("D3a: Z=1",  z_out);

        apply(ALU_EOR, 2'b01, 32'hAA, 32'h55, 0, 0);
        check32("D3b: 0xAA ^ 0x55 = 0xFF", result, 32'hFF);
        check("D3b: N=1",  n_out);

        // D4: NOT
        apply(ALU_NOT, 2'b01, 32'h00, 32'h00, 0, 0);
        check32("D4a: NOT 0x00 = 0xFF",   result, 32'hFF);
        check("D4a: N=1",  n_out); check("D4a: Z=0", !z_out);

        apply(ALU_NOT, 2'b01, 32'hFF, 32'h00, 0, 0);
        check32("D4b: NOT 0xFF = 0x00",   result, 32'h0);
        check("D4b: Z=1",  z_out);

        // D5: X unchanged by logical ops
        apply(ALU_AND, 2'b01, 32'hF0, 32'h0F, 1, 0);  // x_in=1
        check("D5a: X unchanged by AND", x_out == 1'b1);
        apply(ALU_OR,  2'b01, 32'h00, 32'hFF, 0, 0);  // x_in=0
        check("D5b: X unchanged by OR",  x_out == 1'b0);

        // ================================================================
        // E: CMP
        // ================================================================
        $display("--- E: CMP ---");

        // E1: CMP, no borrow (dst > src)
        apply(ALU_CMP, 2'b01, 32'h05, 32'h03, 0, 0);
        check("E1a: CMP 5-3, N=0", !n_out);
        check("E1a: CMP 5-3, C=0", !c_out);
        check("E1a: CMP 5-3, Z=0", !z_out);

        // E2: CMP, borrow (dst < src)
        apply(ALU_CMP, 2'b01, 32'h03, 32'h05, 0, 0);
        check("E2a: CMP 3-5, N=1",  n_out);
        check("E2a: CMP 3-5, C=1",  c_out);

        // E3: CMP equal
        apply(ALU_CMP, 2'b01, 32'h07, 32'h07, 0, 0);
        check("E3a: CMP 7-7, Z=1",  z_out);
        check("E3a: CMP 7-7, C=0", !c_out);

        // E4: CMP does NOT change X
        apply(ALU_CMP, 2'b01, 32'h03, 32'h05, 1, 0);  // x_in=1, would borrow
        check("E4a: CMP X unchanged (x_in=1)", x_out == 1'b1);
        apply(ALU_CMP, 2'b01, 32'h05, 32'h03, 0, 0);  // x_in=0
        check("E4b: CMP X unchanged (x_in=0)", x_out == 1'b0);

        // ================================================================
        // F: TST / CLR
        // ================================================================
        $display("--- F: TST/CLR ---");

        // F1: TST negative
        apply(ALU_TST, 2'b01, 32'h80, 32'h00, 0, 0);
        check("F1a: TST 0x80, N=1",  n_out);
        check("F1a: TST 0x80, Z=0", !z_out);
        check("F1a: TST 0x80, V=0", !v_out);
        check("F1a: TST 0x80, C=0", !c_out);

        // F2: TST zero
        apply(ALU_TST, 2'b01, 32'h00, 32'h00, 0, 0);
        check("F2a: TST 0x00, N=0", !n_out);
        check("F2a: TST 0x00, Z=1",  z_out);

        // F3: CLR
        apply(ALU_CLR, 2'b01, 32'hFF, 32'hFF, 1, 0);  // x_in=1 should be preserved
        check32("F3a: CLR result=0",  result, 32'h0);
        check("F3a: CLR Z=1",  z_out);
        check("F3a: CLR N=0", !n_out);
        check("F3a: CLR V=0", !v_out);
        check("F3a: CLR C=0", !c_out);
        check("F3a: CLR X unchanged (x_in=1)", x_out == 1'b1);

        // ================================================================
        // G: Word and long size coverage
        // ================================================================
        $display("--- G: Word and Long size ---");

        // G1: word ADD overflow
        apply(ALU_ADD, 2'b10, 32'h7FFF, 32'h0001, 0, 0);
        check32("G1a: word 0x7FFF+1=0x8000", result, 32'h8000);
        check("G1a: N=1",  n_out);
        check("G1a: V=1",  v_out);
        check("G1a: C=0", !c_out);

        // G2: word SUB borrow
        apply(ALU_SUB, 2'b10, 32'h0000, 32'h0001, 0, 0);
        check32("G2a: word 0-1=0xFFFF", result, 32'hFFFF);
        check("G2a: C=1",  c_out);

        // G3: long ADD carry
        apply(ALU_ADD, 2'b00, 32'hFFFF_FFFF, 32'h0000_0001, 0, 0);
        check32("G3a: long 0xFFFFFFFF+1=0",    result, 32'h0);
        check("G3a: Z=1",  z_out);
        check("G3a: C=1",  c_out);
        check("G3a: V=0", !v_out);

        // G4: long SUB overflow
        apply(ALU_SUB, 2'b00, 32'h8000_0000, 32'h0000_0001, 0, 0);
        check32("G4a: long 0x80000000-1=0x7FFFFFFF", result, 32'h7FFF_FFFF);
        check("G4a: V=1",  v_out);
        check("G4a: C=0", !c_out);

        // G5: word NOT
        apply(ALU_NOT, 2'b10, 32'h0000_FFFF, 32'h00, 0, 0);
        check32("G5a: word NOT 0xFFFF=0x0000", result, 32'h0);
        check("G5a: Z=1",  z_out);

        // G6: long NEG overflow
        apply(ALU_NEG, 2'b00, 32'h8000_0000, 32'h00, 0, 0);
        check32("G6a: long NEG 0x80000000=0x80000000", result, 32'h8000_0000);
        check("G6a: V=1",  v_out);
        check("G6a: C=1",  c_out);

        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #10000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

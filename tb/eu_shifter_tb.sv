`default_nettype none
`timescale 1ps/1ps

// Phase 25: eu_shifter testbench
// Tests: LSL/LSR, ASL/ASR, ROL/ROR, ROXL/ROXR, byte/word/long, edge cases

module eu_shifter_tb;

    logic [31:0] operand = 0;
    logic [5:0]  count   = 0;
    logic [3:0]  op      = 0;
    logic [1:0]  siz     = 2'b01;   // default: byte
    logic        x_in    = 0;

    logic [31:0] result;
    logic        n_out, z_out, v_out, c_out, x_out;

    localparam [3:0]
        SHF_ASL  = 4'h0,
        SHF_ASR  = 4'h1,
        SHF_LSL  = 4'h2,
        SHF_LSR  = 4'h3,
        SHF_ROL  = 4'h4,
        SHF_ROR  = 4'h5,
        SHF_ROXL = 4'h6,
        SHF_ROXR = 4'h7;

    eu_shifter u_shf (
        .operand (operand),
        .count   (count),
        .op      (op),
        .siz     (siz),
        .x_in    (x_in),
        .result  (result),
        .n_out   (n_out),
        .z_out   (z_out),
        .v_out   (v_out),
        .c_out   (c_out),
        .x_out   (x_out)
    );

    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    task apply(input logic [3:0] o, input logic [1:0] sz,
               input logic [5:0] cnt, input logic [31:0] val, input logic xi);
        op = o; siz = sz; count = cnt; operand = val; x_in = xi;
        #1;
    endtask

    initial begin
        $display("=== Phase 25: eu_shifter ===");

        // ================================================================
        // A: LSL — logical shift left
        // ================================================================
        $display("--- A: LSL ---");

        // A1: byte LSL 1
        apply(SHF_LSL, 2'b01, 6'd1, 32'h01, 0);
        check32("A1a: LSL byte 0x01 by 1 = 0x02", result, 32'h02);
        check("A1a: N=0", !n_out); check("A1a: Z=0", !z_out);
        check("A1a: C=0", !c_out); check("A1a: V=0", !v_out);

        // A2: byte LSL — C gets MSB shifted out
        apply(SHF_LSL, 2'b01, 6'd1, 32'hAB, 0);
        check32("A2a: LSL byte 0xAB by 1 = 0x56", result, 32'h56);
        check("A2a: C=1 (old MSB)", c_out);
        check("A2a: X=1",           x_out);
        check("A2a: N=0", !n_out);

        // A3: byte LSL 4
        apply(SHF_LSL, 2'b01, 6'd4, 32'hAB, 0);
        // 0xAB = 10101011, <<4 = 1011_0000 = 0xB0, C = bit 4 of original = 0xAB[4]=0
        check32("A3a: LSL byte 0xAB by 4 = 0xB0", result, 32'hB0);
        check("A3a: C=0 (bit 4 of 0xAB)", !c_out);
        check("A3a: N=1", n_out);

        // A4: byte LSL 8 — all shifted out, result=0, C = LSB of original
        apply(SHF_LSL, 2'b01, 6'd8, 32'h81, 0);
        check32("A4a: LSL byte 0x81 by 8 = 0x00", result, 32'h00);
        check("A4a: Z=1",           z_out);
        check("A4a: C=1 (LSB of 0x81)", c_out);

        // A5: byte LSL count=0 — no change, C=0, X unchanged
        apply(SHF_LSL, 2'b01, 6'd0, 32'hAB, 1);  // x_in=1
        check32("A5a: LSL byte by 0 = 0xAB unchanged", result, 32'hAB);
        check("A5a: C=0 when count=0", !c_out);
        check("A5a: X=x_in unchanged", x_out == 1'b1);

        // ================================================================
        // B: LSR — logical shift right
        // ================================================================
        $display("--- B: LSR ---");

        // B1: byte LSR 1
        apply(SHF_LSR, 2'b01, 6'd1, 32'hAB, 0);
        // 0xAB = 10101011, >>1 = 01010101 = 0x55, C = bit 0 = 1
        check32("B1a: LSR byte 0xAB by 1 = 0x55", result, 32'h55);
        check("B1a: C=1 (old LSB)", c_out);
        check("B1a: N=0", !n_out);   // MSB of 0x55 = 0

        // B2: byte LSR 4
        apply(SHF_LSR, 2'b01, 6'd4, 32'hAB, 0);
        // 0xAB >>4 = 0x0A, C = bit 3 of 0xAB = 1
        check32("B2a: LSR byte 0xAB by 4 = 0x0A", result, 32'h0A);
        check("B2a: C=1 (bit 3 of 0xAB)", c_out);

        // B3: byte LSR 8
        apply(SHF_LSR, 2'b01, 6'd8, 32'hAB, 0);
        check32("B3a: LSR byte 0xAB by 8 = 0x00", result, 32'h00);
        check("B3a: Z=1",            z_out);
        check("B3a: C=1 (MSB=bit 7)", c_out); // C = op[7] when shift=8

        // ================================================================
        // C: ASL — arithmetic shift left
        // ================================================================
        $display("--- C: ASL ---");

        // C1: byte ASL 1, no overflow
        apply(SHF_ASL, 2'b01, 6'd1, 32'h3F, 0);
        // 0x3F = 00111111, <<1 = 01111110 = 0x7E, top 2 bits of 0x3F = 00 → V=0
        check32("C1a: ASL byte 0x3F by 1 = 0x7E", result, 32'h7E);
        check("C1a: V=0 (no overflow)", !v_out);
        check("C1a: N=0", !n_out);

        // C2: byte ASL 1, overflow (MSB changes: was 0, becomes 1 via bit 6)
        apply(SHF_ASL, 2'b01, 6'd1, 32'h7F, 0);
        // 0x7F = 01111111, <<1 = 11111110 = 0xFE; top bits [7:6] = 01 → differ → V=1
        check32("C2a: ASL byte 0x7F by 1 = 0xFE", result, 32'hFE);
        check("C2a: V=1 (MSB changed)", v_out);
        check("C2a: N=1", n_out);
        check("C2a: C=0 (old bit 7=0)", !c_out);

        // C3: byte ASL 1, 0x80 — overflow (was negative, bit 6=0 → V=1)
        apply(SHF_ASL, 2'b01, 6'd1, 32'h80, 0);
        // 0x80 = 10000000, <<1 = 00000000 = 0x00; top 2 bits of 0x80 = 10 → V=1
        check32("C3a: ASL byte 0x80 by 1 = 0x00", result, 32'h00);
        check("C3a: V=1", v_out);
        check("C3a: C=1 (old bit 7=1)", c_out);
        check("C3a: Z=1", z_out);

        // C4: byte ASL 1, 0xC0 — no overflow (both top bits = 1, same sign)
        apply(SHF_ASL, 2'b01, 6'd1, 32'hC0, 0);
        // top 2 bits: 11 → same → V=0
        check32("C4a: ASL byte 0xC0 by 1 = 0x80", result, 32'h80);
        check("C4a: V=0", !v_out);
        check("C4a: N=1", n_out);
        check("C4a: C=1 (old bit 7=1)", c_out);

        // ================================================================
        // D: ASR — arithmetic shift right
        // ================================================================
        $display("--- D: ASR ---");

        // D1: byte ASR 1, positive
        apply(SHF_ASR, 2'b01, 6'd1, 32'h7E, 0);
        check32("D1a: ASR byte 0x7E by 1 = 0x3F", result, 32'h3F);
        check("D1a: C=0 (old bit 0)", !c_out);
        check("D1a: N=0", !n_out);
        check("D1a: V=0", !v_out);

        // D2: byte ASR 1, negative — sign extends
        apply(SHF_ASR, 2'b01, 6'd1, 32'hFE, 0);
        // 0xFE = 11111110, >>1 = 11111111 = 0xFF (sign extend)
        check32("D2a: ASR byte 0xFE by 1 = 0xFF", result, 32'hFF);
        check("D2a: C=0 (old bit 0 of 0xFE)", !c_out);
        check("D2a: N=1", n_out);

        // D3: byte ASR 1, 0x81 → 0xC0 (shift right, sign extend, C=LSB=1)
        apply(SHF_ASR, 2'b01, 6'd1, 32'h81, 0);
        // 0x81 = 10000001, >>1 w/ sign = 11000000 = 0xC0, C = 1
        check32("D3a: ASR byte 0x81 by 1 = 0xC0", result, 32'hC0);
        check("D3a: C=1 (old bit 0)", c_out);

        // D4: byte ASR 4, negative
        apply(SHF_ASR, 2'b01, 6'd4, 32'hF0, 0);
        // 0xF0 = 1111_0000, >>4 w/ sign = 1111_1111 = 0xFF, C = bit[3] of 0xF0 = 0
        check32("D4a: ASR byte 0xF0 by 4 = 0xFF", result, 32'hFF);
        check("D4a: C=0 (bit 3 of 0xF0=0)", !c_out);

        // ================================================================
        // E: ROL / ROR
        // ================================================================
        $display("--- E: ROL/ROR ---");

        // E1: byte ROL 1
        apply(SHF_ROL, 2'b01, 6'd1, 32'hAB, 0);
        // 0xAB = 10101011, rotate left 1 = 01010111 = 0x57, C=old_MSB=1
        check32("E1a: ROL byte 0xAB by 1 = 0x57", result, 32'h57);
        check("E1a: C=1 (old MSB, now bit 0)", c_out);
        check("E1a: N=0", !n_out);
        check("E1a: X=x_in unchanged", x_out == 1'b0);  // ROL doesn't update X

        // E2: byte ROL 4
        apply(SHF_ROL, 2'b01, 6'd4, 32'hAB, 0);
        // 0xAB = 1010_1011, ROL4 = 1011_1010 = 0xBA
        check32("E2a: ROL byte 0xAB by 4 = 0xBA", result, 32'hBA);
        check("E2a: C=0 (bit 0 of result)", !c_out);  // 0xBA bit 0 = 0
        check("E2a: N=1", n_out);

        // E3: byte ROR 1
        apply(SHF_ROR, 2'b01, 6'd1, 32'hAB, 0);
        // 0xAB = 10101011, ROR 1 = 11010101 = 0xD5, C=old_LSB=1
        check32("E3a: ROR byte 0xAB by 1 = 0xD5", result, 32'hD5);
        check("E3a: C=1 (old LSB = MSB of result)", c_out);
        check("E3a: N=1", n_out);
        check("E3a: X=x_in unchanged", x_out == 1'b0);  // ROR doesn't update X

        // E4: byte ROR 4
        apply(SHF_ROR, 2'b01, 6'd4, 32'hAB, 0);
        // 0xAB = 1010_1011, ROR4 = 1011_1010 = 0xBA
        check32("E4a: ROR byte 0xAB by 4 = 0xBA", result, 32'hBA);
        check("E4a: C=1 (MSB of result)", c_out);  // 0xBA bit 7 = 1

        // E5: ROL count=0 — X unchanged, C=0
        apply(SHF_ROL, 2'b01, 6'd0, 32'hAB, 1);  // x_in=1
        check32("E5a: ROL by 0 = unchanged", result, 32'hAB);
        check("E5a: C=0", !c_out);
        check("E5a: X=x_in", x_out == 1'b1);

        // ================================================================
        // F: ROXL / ROXR
        // ================================================================
        $display("--- F: ROXL/ROXR ---");

        // F1: byte ROXL 1, X=0
        apply(SHF_ROXL, 2'b01, 6'd1, 32'hAB, 0);
        // 0xAB = 10101011, X=0; result = {0xAB[6:0], X} = 01010110 = 0x56, C=bit7=1
        check32("F1a: ROXL byte 0xAB by 1 (X=0) = 0x56", result, 32'h56);
        check("F1a: C=1 (old MSB)",  c_out);
        check("F1a: X=1", x_out);
        check("F1a: N=0", !n_out);

        // F2: byte ROXL 1, X=1
        apply(SHF_ROXL, 2'b01, 6'd1, 32'h2A, 1);
        // 0x2A = 00101010, X=1; result = {0x2A[6:0], 1} = 01010101 = 0x55, C=bit7=0
        check32("F2a: ROXL byte 0x2A by 1 (X=1) = 0x55", result, 32'h55);
        check("F2a: C=0 (old MSB=0)", !c_out);
        check("F2a: X=0", !x_out);

        // F3: byte ROXR 1, X=0
        apply(SHF_ROXR, 2'b01, 6'd1, 32'hAB, 0);
        // 0xAB = 10101011, X=0; result = {X, 0xAB[7:1]} = {0, 1010101} = 01010101 = 0x55, C=bit0=1
        check32("F3a: ROXR byte 0xAB by 1 (X=0) = 0x55", result, 32'h55);
        check("F3a: C=1 (old LSB)", c_out);
        check("F3a: X=1", x_out);

        // F4: byte ROXR 1, X=1
        apply(SHF_ROXR, 2'b01, 6'd1, 32'hAA, 1);
        // 0xAA = 10101010, X=1; result = {1, 1010101} = 11010101 = 0xD5, C=bit0=0
        check32("F4a: ROXR byte 0xAA by 1 (X=1) = 0xD5", result, 32'hD5);
        check("F4a: C=0 (old LSB=0)", !c_out);
        check("F4a: N=1", n_out);

        // F5: ROXL count=0 — X unchanged, C=0
        apply(SHF_ROXL, 2'b01, 6'd0, 32'hAB, 1);
        check("F5a: ROXL by 0, C=0",      !c_out);
        check("F5a: ROXL by 0, X=x_in=1", x_out == 1'b1);

        // ================================================================
        // G: Word and long size coverage
        // ================================================================
        $display("--- G: Word/Long ---");

        // G1: word LSL 1
        apply(SHF_LSL, 2'b10, 6'd1, 32'h8000, 0);
        // 0x8000 << 1 = 0x0000, C = 1 (MSB shifted out)
        check32("G1a: LSL word 0x8000 by 1 = 0x0000", result, 32'h0000);
        check("G1a: C=1", c_out);
        check("G1a: Z=1", z_out);

        // G2: word ASR 1, negative
        apply(SHF_ASR, 2'b10, 6'd1, 32'h8000, 0);
        // 0x8000 >>1 w/ sign = 0xC000, C=0
        check32("G2a: ASR word 0x8000 by 1 = 0xC000", result, 32'hC000);
        check("G2a: C=0", !c_out);
        check("G2a: N=1", n_out);

        // G3: long LSL 1
        apply(SHF_LSL, 2'b00, 6'd1, 32'hFFFF_FFFF, 0);
        check32("G3a: LSL long 0xFFFFFFFF by 1 = 0xFFFFFFFE", result, 32'hFFFF_FFFE);
        check("G3a: C=1 (MSB)", c_out);

        // G4: long LSR 1
        apply(SHF_LSR, 2'b00, 6'd1, 32'hFFFF_FFFF, 0);
        check32("G4a: LSR long 0xFFFFFFFF by 1 = 0x7FFFFFFF", result, 32'h7FFF_FFFF);
        check("G4a: C=1 (LSB)", c_out);
        check("G4a: N=0", !n_out);

        // G5: word ROL 8
        apply(SHF_ROL, 2'b10, 6'd8, 32'h1234, 0);
        // 0x1234 rotate left 8 (word) = 0x3412
        check32("G5a: ROL word 0x1234 by 8 = 0x3412", result, 32'h3412);

        // G6: word ROXL 1, X=1
        apply(SHF_ROXL, 2'b10, 6'd1, 32'h4000, 1);
        // 0x4000 = 0100_0000_0000_0000, X=1
        // result = {0x4000[14:0], 1} = 1000_0000_0000_0001 = 0x8001, C = 0x4000[15] = 0
        check32("G6a: ROXL word 0x4000 by 1 (X=1) = 0x8001", result, 32'h8001);
        check("G6a: C=0 (old MSB=0)", !c_out);
        check("G6a: N=1", n_out);

        // G7: long ASL V flag — 0x40000000 << 1 = 0x80000000, V=1 (sign changed)
        apply(SHF_ASL, 2'b00, 6'd1, 32'h4000_0000, 0);
        check32("G7a: ASL long 0x40000000 by 1 = 0x80000000", result, 32'h8000_0000);
        check("G7a: V=1 (sign changed)", v_out);

        // G8: long ASL V=0 — 0xC0000000 << 1 = 0x80000000, top 2 bits were 11 → V=0
        apply(SHF_ASL, 2'b00, 6'd1, 32'hC000_0000, 0);
        check32("G8a: ASL long 0xC0000000 by 1 = 0x80000000", result, 32'h8000_0000);
        check("G8a: V=0 (sign preserved)", !v_out);

        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #50000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

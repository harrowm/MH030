`default_nettype none
`timescale 1ps/1ps

// Phase 26: eu_mul_div testbench
// Tests: MULU.W, MULS.W, MULU.L, MULS.L, DIVU.W, DIVS.W

module eu_mul_div_tb;

    logic [31:0] src = 0, dst = 0;
    logic [2:0]  op  = 0;

    logic [31:0] result_lo, result_hi;
    logic        n_out, z_out, v_out, c_out, div_by_zero;

    localparam [2:0]
        MUL_UW = 3'h0,
        MUL_SW = 3'h1,
        MUL_UL = 3'h2,
        MUL_SL = 3'h3,
        DIV_UW = 3'h4,
        DIV_SW = 3'h5;

    eu_mul_div u_md (
        .src        (src),
        .dst        (dst),
        .op         (op),
        .result_lo  (result_lo),
        .result_hi  (result_hi),
        .n_out      (n_out),
        .z_out      (z_out),
        .v_out      (v_out),
        .c_out      (c_out),
        .div_by_zero(div_by_zero)
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

    task apply(input logic [2:0] o, input logic [31:0] s, input logic [31:0] d);
        op = o; src = s; dst = d; #1;
    endtask

    initial begin
        $display("=== Phase 26: eu_mul_div ===");

        // ================================================================
        // A: MULU.W — unsigned 16×16→32
        // ================================================================
        $display("--- A: MULU.W ---");

        // A1: simple
        apply(MUL_UW, 32'h0003, 32'h0004);
        check32("A1a: 3×4=12",          result_lo, 32'h0000_000C);
        check("A1a: N=0", !n_out); check("A1a: Z=0", !z_out);
        check("A1a: V=0", !v_out); check("A1a: C=0", !c_out);

        // A2: max 16×max 16 → 0xFFFE0001
        apply(MUL_UW, 32'hFFFF, 32'hFFFF);
        check32("A2a: 0xFFFF×0xFFFF=0xFFFE0001", result_lo, 32'hFFFE_0001);
        check("A2a: N=1", n_out); check("A2a: Z=0", !z_out);

        // A3: zero result
        apply(MUL_UW, 32'h1234, 32'h0000);
        check32("A3a: 0x1234×0=0",      result_lo, 32'h0);
        check("A3a: Z=1", z_out); check("A3a: N=0", !n_out);

        // A4: upper bits of src/dst must be ignored (only low 16 used)
        apply(MUL_UW, 32'hFFFF_0003, 32'hFFFF_0004); // upper halves = 0xFFFF, should be ignored
        check32("A4a: upper bits ignored: 3×4=12", result_lo, 32'h0000_000C);

        // ================================================================
        // B: MULS.W — signed 16×16→32
        // ================================================================
        $display("--- B: MULS.W ---");

        // B1: positive × positive
        apply(MUL_SW, 32'h0005, 32'h0006);
        check32("B1a: 5×6=30",          result_lo, 32'h1E);
        check("B1a: N=0", !n_out);

        // B2: negative × positive  (0xFFFF = -1 as 16-bit signed)
        apply(MUL_SW, 32'hFFFF, 32'h0002);
        check32("B2a: -1×2=-2",         result_lo, 32'hFFFF_FFFE);
        check("B2a: N=1", n_out); check("B2a: Z=0", !z_out);

        // B3: negative × negative  (0x8000 = -32768)
        apply(MUL_SW, 32'h8000, 32'h8000);
        check32("B3a: -32768×-32768=0x40000000", result_lo, 32'h4000_0000);
        check("B3a: N=0", !n_out);

        // B4: -32768 × 2
        apply(MUL_SW, 32'h8000, 32'h0002);
        check32("B4a: -32768×2=0xFFFF0000", result_lo, 32'hFFFF_0000);
        check("B4a: N=1", n_out);

        // B5: zero
        apply(MUL_SW, 32'h7FFF, 32'h0000);
        check32("B5a: 32767×0=0",       result_lo, 32'h0);
        check("B5a: Z=1", z_out);

        // ================================================================
        // C: MULU.L — unsigned 32×32→64
        // ================================================================
        $display("--- C: MULU.L ---");

        // C1: 0x10000 × 0x10000 = 0x1_00000000
        apply(MUL_UL, 32'h0001_0000, 32'h0001_0000);
        check32("C1a: hi=1",            result_hi, 32'h0000_0001);
        check32("C1a: lo=0",            result_lo, 32'h0000_0000);
        check("C1a: N=0", !n_out); check("C1a: Z=0", !z_out);

        // C2: 0xFFFFFFFF × 0xFFFFFFFF = 0xFFFFFFFE_00000001
        apply(MUL_UL, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        check32("C2a: hi=0xFFFFFFFE",   result_hi, 32'hFFFF_FFFE);
        check32("C2a: lo=0x00000001",   result_lo, 32'h0000_0001);
        check("C2a: N=1", n_out);

        // C3: 0 × 0xFFFFFFFF = 0
        apply(MUL_UL, 32'h0, 32'hFFFF_FFFF);
        check32("C3a: hi=0",            result_hi, 32'h0);
        check32("C3a: lo=0",            result_lo, 32'h0);
        check("C3a: Z=1", z_out);

        // ================================================================
        // D: MULS.L — signed 32×32→64
        // ================================================================
        $display("--- D: MULS.L ---");

        // D1: 0x80000000 (-2147483648) × 2 = -4294967296 = 0xFFFFFFFF_00000000
        apply(MUL_SL, 32'h8000_0000, 32'h0000_0002);
        check32("D1a: hi=0xFFFFFFFF",   result_hi, 32'hFFFF_FFFF);
        check32("D1a: lo=0x00000000",   result_lo, 32'h0000_0000);
        check("D1a: N=1", n_out); check("D1a: Z=0", !z_out);

        // D2: -1 × -1 = 1
        apply(MUL_SL, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        check32("D2a: hi=0",            result_hi, 32'h0);
        check32("D2a: lo=1",            result_lo, 32'h1);
        check("D2a: N=0", !n_out);

        // D3: 0x7FFFFFFF × 0x7FFFFFFF = 0x3FFFFFFF_00000001
        apply(MUL_SL, 32'h7FFF_FFFF, 32'h7FFF_FFFF);
        check32("D3a: hi=0x3FFFFFFF",   result_hi, 32'h3FFF_FFFF);
        check32("D3a: lo=0x00000001",   result_lo, 32'h0000_0001);
        check("D3a: N=0", !n_out);

        // ================================================================
        // E: DIVU.W — unsigned 32÷16→16r:16q
        // ================================================================
        $display("--- E: DIVU.W ---");

        // E1: 7 ÷ 3 = quotient 2, remainder 1
        apply(DIV_UW, 32'h0003, 32'h0007);
        check32("E1a: 7÷3={rem=1,q=2}=0x00010002", result_lo, 32'h0001_0002);
        check("E1a: N=0", !n_out); check("E1a: Z=0", !z_out);
        check("E1a: V=0", !v_out); check("E1a: C=0", !c_out);
        check("E1a: div_by_zero=0", !div_by_zero);

        // E2: 65534 ÷ 32767 = quotient 2, remainder 0
        apply(DIV_UW, 32'h7FFF, 32'h0000_FFFE);
        check32("E2a: 65534÷32767={rem=0,q=2}", result_lo, 32'h0000_0002);
        check("E2a: Z=0", !z_out);

        // E3: exact 0xFFFF ÷ 0x0001 = 65535, rem 0
        apply(DIV_UW, 32'h0001, 32'h0000_FFFF);
        check32("E3a: 0xFFFF÷1={rem=0,q=0xFFFF}", result_lo, 32'h0000_FFFF);
        check("E3a: N=1 (q[15]=1)", n_out);
        check("E3a: Z=0", !z_out);

        // E4: overflow — quotient > 0xFFFF
        apply(DIV_UW, 32'h0001, 32'h0001_0000);  // 65536 ÷ 1 = 65536 → overflow
        check("E4a: V=1 (overflow)", v_out);
        check("E4a: div_by_zero=0", !div_by_zero);

        // E5: divide by zero
        apply(DIV_UW, 32'h0000, 32'h1234_5678);
        check("E5a: V=1 (div-by-zero)", v_out);
        check("E5a: div_by_zero=1", div_by_zero);

        // ================================================================
        // F: DIVS.W — signed 32÷16→16r:16q
        // ================================================================
        $display("--- F: DIVS.W ---");

        // F1: 7 ÷ 3 = quotient 2, remainder 1
        apply(DIV_SW, 32'h0003, 32'h0000_0007);
        check32("F1a: 7÷3={rem=1,q=2}=0x00010002", result_lo, 32'h0001_0002);
        check("F1a: N=0", !n_out); check("F1a: Z=0", !z_out);
        check("F1a: V=0", !v_out); check("F1a: div_by_zero=0", !div_by_zero);

        // F2: -7 ÷ 3 = quotient -2 (0xFFFE), remainder -1 (0xFFFF)
        apply(DIV_SW, 32'h0003, 32'hFFFF_FFF9);
        check32("F2a: -7÷3={rem=-1,q=-2}=0xFFFFFFFE", result_lo, 32'hFFFF_FFFE);
        check("F2a: N=1 (q=-2)", n_out);
        check("F2a: Z=0", !z_out);

        // F3: 7 ÷ -3 = quotient -2 (0xFFFE), remainder 1 (0x0001)
        apply(DIV_SW, 32'hFFFF, 32'h0000_0007);  // src=0xFFFF=(-1 as 16-bit)... wait, need -3
        // -3 as 16-bit signed = 0xFFFD
        apply(DIV_SW, 32'hFFFD, 32'h0000_0007);
        check32("F3a: 7÷(-3)={rem=1,q=-2}=0x0001FFFE", result_lo, 32'h0001_FFFE);
        check("F3a: N=1", n_out);

        // F4: quotient zero
        apply(DIV_SW, 32'h0005, 32'h0000_0003);  // 3 ÷ 5 = 0 rem 3
        check32("F4a: 3÷5={rem=3,q=0}=0x00030000", result_lo, 32'h0003_0000);
        check("F4a: Z=1", z_out);

        // F5: overflow — quotient > 32767
        apply(DIV_SW, 32'h0001, 32'h0001_0000);  // 65536 ÷ 1 = 65536 > 32767
        check("F5a: V=1 (overflow)", v_out);
        check("F5a: div_by_zero=0", !div_by_zero);

        // F6: overflow — quotient < -32768  (-65536 ÷ 1 = -65536)
        apply(DIV_SW, 32'h0001, 32'hFFFF_0000);  // 0xFFFF0000 = -65536 (signed 32-bit)
        check("F6a: V=1 (underflow -65536÷1)", v_out);

        // F7: divide by zero
        apply(DIV_SW, 32'h0000, 32'h0000_1234);
        check("F7a: V=1 (div-by-zero)", v_out);
        check("F7a: div_by_zero=1", div_by_zero);

        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

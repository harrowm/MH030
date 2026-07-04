`default_nettype none
`timescale 1ps/1ps

// Phase 29: eu_agu testbench
// Tests all addressing modes including brief and full extension word formats.
//
// Register setup: A0=0x1000, A1=0x2000, A7=0x7FFC
//                 D0=0x10, D1=0x20, D2=0x40
//                 PC=0x4000
//
// Groups:
//   A: Register-direct modes (Dn, An) — is_direct checks
//   B: Simple indirect (An), (An)+, -(An) with An update checks
//   C: (d16,An) — displacement indirect
//   D: Brief extension word (d8,An,Xn.L*scale)
//   E: Absolute short and absolute long
//   F: PC-relative (d16,PC) and (d8,PC,Xn) brief
//   G: Full extension word non-indirect (An base + index + bd)
//   H: Pre/post-increment step sizes (byte, word, long, line; A7 byte rule)

module agu_tb;

    // -----------------------------------------------------------------------
    // eu_agu is combinational — no clock needed for checks.
    // Use a clock only to sequence test cases cleanly.
    // -----------------------------------------------------------------------
    logic clk = 0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic [2:0]  mode;
    logic [2:0]  reg_field;
    logic [1:0]  siz;
    logic [31:0] an_in [0:7];
    logic [31:0] dn_in [0:7];
    logic [31:0] pc_in;
    logic [15:0] ext0, ext1, ext2;

    logic [31:0] ea_out;
    logic        is_direct, is_an_dir;
    logic [1:0]  ext_count;
    logic        an_upd_en;
    logic [2:0]  an_upd_reg;
    logic [31:0] an_upd_new;

    eu_agu u_agu (
        .mode       (mode),
        .reg_field  (reg_field),
        .siz        (siz),
        .an_in      (an_in),
        .dn_in      (dn_in),
        .pc_in      (pc_in),
        .ext0       (ext0),
        .ext1       (ext1),
        .ext2       (ext2),
        .ea_out     (ea_out),
        .is_direct  (is_direct),
        .is_an_dir  (is_an_dir),
        .ext_count  (ext_count),
        .an_upd_en  (an_upd_en),
        .an_upd_reg (an_upd_reg),
        .an_upd_new (an_upd_new)
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

    // Set an_in / dn_in convenience task
    task set_regs();
        // Address registers
        an_in[0] = 32'h0000_1000;  // A0
        an_in[1] = 32'h0000_2000;  // A1
        an_in[2] = 32'h0000_3000;  // A2
        an_in[3] = 32'h0000_4000;  // A3
        an_in[4] = 32'h0000_5000;  // A4
        an_in[5] = 32'h0000_6000;  // A5
        an_in[6] = 32'h0000_7000;  // A6
        an_in[7] = 32'h0000_7FFC;  // A7 (stack, near top)
        // Data registers
        dn_in[0] = 32'h0000_0010;  // D0 = 0x10
        dn_in[1] = 32'h0000_0020;  // D1 = 0x20
        dn_in[2] = 32'h0000_0040;  // D2 = 0x40
        dn_in[3] = 32'hFFFF_FFFF;  // D3 = -1
        dn_in[4] = 32'h0000_0000;  // D4 = 0
        dn_in[5] = 32'h0000_0004;  // D5 = 4
        dn_in[6] = 32'hFFFF_0000;  // D6 = large negative
        dn_in[7] = 32'h0000_0001;  // D7 = 1
        // PC
        pc_in = 32'h0000_4000;
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        set_regs();
        ext0 = 16'h0; ext1 = 16'h0; ext2 = 16'h0;
        siz  = 2'b00; // default: long

        $display("=== Phase 29: eu_agu ===");

        // ================================================================
        // A: Register-direct modes
        // ================================================================
        $display("--- A: Register direct ---");
        // A1: Dn direct (mode=000, reg=D2)
        mode = 3'b000; reg_field = 3'b010; // D2
        #1;
        check("A1: Dn is_direct", is_direct);
        check("A1: Dn is_an_dir=0", !is_an_dir);
        check("A1: Dn ext_count=0", (ext_count == 2'd0));
        check("A1: Dn no an_upd", !an_upd_en);

        // A2: An direct (mode=001, reg=A1)
        mode = 3'b001; reg_field = 3'b001; // A1
        #1;
        check("A2: An is_direct", is_direct);
        check("A2: An is_an_dir=1", is_an_dir);
        check("A2: An ext_count=0", (ext_count == 2'd0));

        // ================================================================
        // B: Simple indirect modes
        // ================================================================
        $display("--- B: Indirect ---");
        // B1: (A0) — address register indirect
        mode = 3'b010; reg_field = 3'b000; siz = 2'b00; // (A0)
        #1;
        check32("B1: (A0)=0x1000", ea_out, 32'h0000_1000);
        check("B1: not direct", !is_direct);
        check("B1: no an_upd", !an_upd_en);
        check("B1: ext=0", (ext_count == 2'd0));

        // B2: (A1)+ — post-increment long
        mode = 3'b011; reg_field = 3'b001; siz = 2'b00; // (A1)+ long
        #1;
        check32("B2: (A1)+  ea=0x2000", ea_out, 32'h0000_2000);
        check("B2: an_upd_en", an_upd_en);
        check32("B2: an_upd_new=0x2004", an_upd_new, 32'h0000_2004);
        check("B2: an_upd_reg=1", (an_upd_reg == 3'd1));

        // B3: -(A2) — pre-decrement long
        mode = 3'b100; reg_field = 3'b010; siz = 2'b00; // -(A2) long
        #1;
        check32("B3: -(A2)  ea=0x2FFC", ea_out, 32'h0000_2FFC);
        check("B3: an_upd_en", an_upd_en);
        check32("B3: an_upd_new=0x2FFC", an_upd_new, 32'h0000_2FFC);

        // B4: (A0)+ byte — post-increment byte (non-A7)
        mode = 3'b011; reg_field = 3'b000; siz = 2'b01; // (A0)+ byte
        #1;
        check32("B4: (A0)+.B ea=0x1000", ea_out, 32'h0000_1000);
        check32("B4: (A0)+.B new=0x1001", an_upd_new, 32'h0000_1001);

        // B5: (A0)+ word — post-increment word
        mode = 3'b011; reg_field = 3'b000; siz = 2'b10; // (A0)+ word
        #1;
        check32("B5: (A0)+.W ea=0x1000", ea_out, 32'h0000_1000);
        check32("B5: (A0)+.W new=0x1002", an_upd_new, 32'h0000_1002);

        // ================================================================
        // C: (d16,An) displacement indirect
        // ================================================================
        $display("--- C: d16,An ---");
        // C1: (0x0100, A0) → 0x1000 + 0x100 = 0x1100
        mode = 3'b101; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h0100; // d16 = +256
        #1;
        check32("C1: (0x100,A0)=0x1100", ea_out, 32'h0000_1100);
        check("C1: ext_count=1", (ext_count == 2'd1));
        check("C1: no an_upd", !an_upd_en);

        // C2: (-4, A1) → 0x2000 + (-4) = 0x1FFC
        mode = 3'b101; reg_field = 3'b001; siz = 2'b00;
        ext0 = 16'hFFFC; // d16 = -4
        #1;
        check32("C2: (-4,A1)=0x1FFC", ea_out, 32'h0000_1FFC);

        // ================================================================
        // D: Brief extension word (d8, An, Xn.L*scale)
        // ================================================================
        $display("--- D: Brief ext ---");
        // D1: (4, A0, D0.L*1) → 0x1000 + 0x10 + 4 = 0x1014
        // Brief: D/A=0 Reg=0 W/L=1 Scale=00 Ext=0 d8=0x04
        // ext0 = 0[D] 000[D0] 1[L] 00[1x] 0[brief] 00000100
        //      = 0_000_1_00_0_0000_0100 = 0x0804
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h0804; // D0.L*1, d8=4
        #1;
        // A0=0x1000, D0=0x10, d8=4 → EA = 0x1000 + 0x10 + 4 = 0x1014
        check32("D1: (4,A0,D0.L)=0x1014", ea_out, 32'h0000_1014);
        check("D1: ext_count=1", (ext_count == 2'd1));

        // D2: (0, A1, D1.L*2) → 0x2000 + 0x20*2 + 0 = 0x2040
        // D/A=0 Reg=001[D1] W/L=1[L] Scale=01[2x] Brief=0 d8=0
        // ext0 = 0_001_1_01_0_00000000 = 0x1A00
        mode = 3'b110; reg_field = 3'b001; siz = 2'b00;
        ext0 = 16'h1A00; // D1.L*2, d8=0
        #1;
        // A1=0x2000, D1=0x20, 0x20*2=0x40 → EA = 0x2000 + 0x40 = 0x2040
        check32("D2: (0,A1,D1.L*2)=0x2040", ea_out, 32'h0000_2040);

        // D3: (-8, A0, D2.L*4) → 0x1000 + 0x40*4 + (-8) = 0x1000+0x100-8 = 0x10F8
        // D/A=0 Reg=010[D2] W/L=1[L] Scale=10[4x] Brief=0 d8=0xF8(-8)
        // ext0 = 0_010_1_10_0_11111000 = 0x2CF8
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h2CF8; // D2.L*4, d8=-8
        #1;
        // A0=0x1000, D2=0x40, 0x40*4=0x100, d8=-8=0xFFFFFFF8
        // EA = 0x1000 + 0x100 + 0xFFFFFFF8 = 0x10F8
        check32("D3: (-8,A0,D2.L*4)=0x10F8", ea_out, 32'h0000_10F8);

        // D4: (0, A0, A1.L*1) → 0x1000 + 0x2000 + 0 = 0x3000
        // D/A=1[An] Reg=001[A1] W/L=1[L] Scale=00[1x] Brief=0 d8=0
        // ext0 = 1_001_1_00_0_00000000 = 0x9800
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h9800; // A1.L*1, d8=0
        #1;
        // A0=0x1000, A1=0x2000 → EA = 0x1000 + 0x2000 = 0x3000
        check32("D4: (0,A0,A1.L)=0x3000", ea_out, 32'h0000_3000);

        // D5: Word-size index (W/L=0): sign-extend D3[15:0]=0xFFFF to -1
        // D/A=0 Reg=011[D3] W/L=0[W] Scale=00 Brief=0 d8=0
        // ext0 = 0_011_0_00_0_00000000 = 0x3000
        // D3=0xFFFF_FFFF, word-sign-extend D3[15:0]=0xFFFF → -1
        // EA = A0 + (-1) + 0 = 0x1000 - 1 = 0x0FFF
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h3000; // D3.W*1, d8=0
        #1;
        check32("D5: (0,A0,D3.W)=0x0FFF", ea_out, 32'h0000_0FFF);

        // ================================================================
        // E: Absolute addressing
        // ================================================================
        $display("--- E: Absolute ---");
        // E1: xxx.W absolute short — sign-extend 16-bit to 32
        // (0x8000).W → sign-extended = 0xFFFF8000
        mode = 3'b111; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h8000;
        #1;
        check32("E1: abs.W 0x8000→0xFFFF8000", ea_out, 32'hFFFF_8000);
        check("E1: ext_count=1", (ext_count == 2'd1));

        // E2: xxx.W with positive value (0x1234).W → 0x00001234
        ext0 = 16'h1234;
        #1;
        check32("E2: abs.W 0x1234→0x1234", ea_out, 32'h0000_1234);

        // E3: xxx.L absolute long
        mode = 3'b111; reg_field = 3'b001; siz = 2'b00;
        ext0 = 16'hABCD; ext1 = 16'hEF01;
        #1;
        check32("E3: abs.L 0xABCDEF01", ea_out, 32'hABCD_EF01);
        check("E3: ext_count=2", (ext_count == 2'd2));

        // ================================================================
        // F: PC-relative
        // ================================================================
        $display("--- F: PC-relative ---");
        // F1: (d16,PC) → PC + 0x0100 = 0x4000 + 0x100 = 0x4100
        mode = 3'b111; reg_field = 3'b010; siz = 2'b00;
        ext0 = 16'h0100; // d16 = +256
        #1;
        check32("F1: (0x100,PC)=0x4100", ea_out, 32'h0000_4100);
        check("F1: ext_count=1", (ext_count == 2'd1));

        // F2: (d16,PC) negative displacement → PC - 4 = 0x3FFC
        ext0 = 16'hFFFC; // d16 = -4
        #1;
        check32("F2: (-4,PC)=0x3FFC", ea_out, 32'h0000_3FFC);

        // F3: (d8,PC,D0.L*1) brief → PC + D0 + d8 = 0x4000 + 0x10 + 8 = 0x4018
        // D/A=0 Reg=000[D0] W/L=1[L] Scale=00 Brief=0 d8=8
        // ext0 = 0_000_1_00_0_00001000 = 0x0808
        mode = 3'b111; reg_field = 3'b011; siz = 2'b00;
        ext0 = 16'h0808; // D0.L*1, d8=8
        #1;
        // PC=0x4000, D0=0x10, d8=8 → EA = 0x4000 + 0x10 + 8 = 0x4018
        check32("F3: (8,PC,D0.L)=0x4018", ea_out, 32'h0000_4018);
        check("F3: ext_count=1", (ext_count == 2'd1));

        // ================================================================
        // G: Full extension word — non-indirect (I/IS=000)
        // ================================================================
        $display("--- G: Full ext (non-indirect) ---");
        // G1: Full ext, BS=0, IS=0, BD=word, I/IS=000 (no indirect)
        // base=A0=0x1000, index=D0.L*1=0x10, bd=ext1=0x0200 → EA=0x1000+0x10+0x200=0x1210
        // ext0[8]=1(full) [7]=0(BS=0) [6]=0(IS=0) [5:4]=10(BD=word) [3]=0 [2:0]=000
        //      = D/A=0 Reg=D0=000 W/L=1 Scale=00 [8]=1 [7:6:5:4]=0010 [3]=0 [2:0]=000
        //      bits: [15]=0 [14:12]=000 [11]=1 [10:9]=00 [8]=1 [7]=0 [6]=0 [5:4]=10 [3]=0 [2:0]=000
        //      = 0000_1_00_1_0_0_10_0_000 = 0x0190? Let me recalc:
        // bit15=0 bit14:12=000 bit11=1 bit10:9=00 bit8=1 bit7=0 bit6=0 bit5:4=10 bit3=0 bit2:0=000
        // = 0_000_1_00_1_0_0_10_0_000 (grouped by 1-3-1-2-1-1-1-2-1-3)
        // = 0000_1001_0010_0000 = 0x0920
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h0920; // D0.L*1, full, BS=0, IS=0, BD=word, I/IS=000
        ext1 = 16'h0200; // bd=+0x200
        #1;
        check32("G1: full An+D0+bd=0x1210", ea_out, 32'h0000_1210);
        check("G1: ext_count=2", (ext_count == 2'd2));

        // G2: Full ext, BS=1 (suppress base), IS=0, BD=word → EA = 0 + D0 + bd
        // BS=1: ext0[7]=1
        // bit15=0 bit14:12=000 bit11=1 bit10:9=00 bit8=1 bit7=1 bit6=0 bit5:4=10 bit3=0 bit2:0=000
        // = 0000_1001_1010_0000 = 0x09A0
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h09A0; // D0.L*1, full, BS=1, IS=0, BD=word
        ext1 = 16'h0100; // bd=+0x100
        #1;
        // base=0 (BS=1), index=D0=0x10, bd=0x100 → EA=0x10+0x100=0x110
        check32("G2: full BS=1 D0+bd=0x110", ea_out, 32'h0000_0110);

        // G3: Full ext, BS=0, IS=1 (suppress index), BD=null → EA = A0 + 0 + 0 = 0x1000
        // IS=1: ext0[6]=1, BD=null: ext0[5:4]=01
        // bit15=0 bit14:12=000 bit11=1 bit10:9=00 bit8=1 bit7=0 bit6=1 bit5:4=01 bit3=0 bit2:0=000
        // = 0000_1001_0101_0000 = 0x0950? Wait:
        // [15:8] = 0_000_1_00_1 = 0x09
        // [7:0]  = 0_1_01_0_000 = 0x50
        // = 0x0950
        mode = 3'b110; reg_field = 3'b000; siz = 2'b00;
        ext0 = 16'h0950; // D0.L*1, full, BS=0, IS=1, BD=null
        ext1 = 16'h0000; // ignored (bd=null)
        #1;
        // base=A0=0x1000, index=0 (IS=1), bd=0 → EA=0x1000
        check32("G3: full IS=1 base-only=0x1000", ea_out, 32'h0000_1000);
        check("G3: ext_count=1 (null bd)", (ext_count == 2'd1));

        // G4: Full ext, D1.L*8, BD=word, base=A1
        // D/A=0 Reg=001[D1] W/L=1 Scale=11[8x] full=1 BS=0 IS=0 BD=10[word] IIS=000
        // [15:8] = 0_001_1_11_1 = 0x1F
        // [7:0]  = 0_0_10_0_000 = 0x20
        // ext0 = 0x1F20
        mode = 3'b110; reg_field = 3'b001; siz = 2'b00; // A1=0x2000
        ext0 = 16'h1F20; // D1.L*8, full, BS=0,IS=0,BD=word
        ext1 = 16'h0010; // bd=+16
        #1;
        // A1=0x2000, D1=0x20, 0x20*8=0x100, bd=0x10 → EA=0x2000+0x100+0x10=0x2110
        check32("G4: full A1+D1*8+bd=0x2110", ea_out, 32'h0000_2110);

        // ================================================================
        // H: Step sizes for (An)+ and -(An)
        // ================================================================
        $display("--- H: Step sizes ---");
        // H1: -(A0) byte (non-A7) → step=1, ea=0x1000-1=0x0FFF
        mode = 3'b100; reg_field = 3'b000; siz = 2'b01;
        #1;
        check32("H1: -(A0).B step=1", an_upd_new, 32'h0000_0FFF);

        // H2: -(A7) byte → step=2 (A7 word-aligned), ea=0x7FFC-2=0x7FFA
        mode = 3'b100; reg_field = 3'b111; siz = 2'b01;
        #1;
        check32("H2: -(A7).B step=2", an_upd_new, 32'h0000_7FFA);
        check32("H2: -(A7).B ea=0x7FFA", ea_out, 32'h0000_7FFA);

        // H3: (A0)+ word → step=2
        mode = 3'b011; reg_field = 3'b000; siz = 2'b10;
        #1;
        check32("H3: (A0)+.W step=2", an_upd_new, 32'h0000_1002);

        // H4: (A0)+ long → step=4
        mode = 3'b011; reg_field = 3'b000; siz = 2'b00;
        #1;
        check32("H4: (A0)+.L step=4", an_upd_new, 32'h0000_1004);

        // H5: (A0)+ line → step=16
        mode = 3'b011; reg_field = 3'b000; siz = 2'b11;
        #1;
        check32("H5: (A0)+.line step=16", an_upd_new, 32'h0000_1010);

        // ================================================================
        // Done
        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED");
        $finish;
    end

endmodule

`default_nettype wire

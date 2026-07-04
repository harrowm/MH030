`default_nettype none
`timescale 1ps/1ps

// Phase 27: eu_seq testbench
// Instantiates eu_seq + eu_regfile + eu_alu + eu_shifter + eu_mul_div
// Uses hierarchical references (u_rf.d_reg[], u_rf.sr_r) to check results.
//
// Instruction encodings tested (register-direct EA, Dn only):
//   ADDI/SUBI/ANDI/ORI/EORI/CMPI  #imm,Dn
//   MOVE.B/W/L  Dm,Dn
//   ADD/SUB/AND/OR.L  Dm,Dn
//   EOR.L  Dn,Dm  ;  CMP.L  Dm,Dn
//   NEG/NEGX/NOT/CLR/TST.L  Dn
//   LSL/LSR/ASR.L #cnt,Dn  ;  ROL.W #cnt,Dn
//   MULU.W/MULS.W  Dm,Dn
//   DIVU.W/DIVS.W  Dm,Dn
//   RAW hazard: 2-cycle stall when EX/WB destination conflicts with decode read

module eu_seq_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // -----------------------------------------------------------------------
    // eu_seq interface signals
    // -----------------------------------------------------------------------
    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;

    // Regfile ↔ seq wires
    logic [3:0]  rd_a_sel, rd_b_sel;
    logic [1:0]  rd_a_siz, rd_b_siz;
    logic [31:0] rd_a_data, rd_b_data;
    logic        wr_en;
    logic [3:0]  wr_sel;
    logic [1:0]  wr_siz;
    logic [31:0] wr_data;
    logic        sr_wr_en;
    logic [15:0] sr_wr_data;
    logic        sr_ccr_only;
    logic [15:0] sr_out;

    // ALU ↔ seq wires
    logic [31:0] alu_src, alu_dst, alu_result;
    logic [3:0]  alu_op;
    logic [1:0]  alu_siz;
    logic        alu_x_in, alu_z_in;
    logic        alu_n, alu_z, alu_v, alu_c, alu_x;

    // Shifter ↔ seq wires
    logic [31:0] shf_operand, shf_result;
    logic [5:0]  shf_count;
    logic [3:0]  shf_op;
    logic [1:0]  shf_siz;
    logic        shf_x_in, shf_n, shf_z, shf_v, shf_c, shf_x;

    // Mul/div ↔ seq wires
    logic [31:0] md_src, md_dst, md_result_lo, md_result_hi;
    logic [2:0]  md_op;
    logic        md_n, md_z, md_v, md_c, md_div_by_zero;

    // seq outputs
    logic        instr_ack, seq_busy, div_trap;

    // BCD ↔ seq wires
    logic [7:0]  bcd_src, bcd_dst, bcd_result;
    logic [1:0]  bcd_op;
    logic        bcd_x_in, bcd_z_in, bcd_c, bcd_z_flag;

    // Bitops ↔ seq wires
    logic [31:0] bit_dst, bit_result;
    logic [4:0]  bit_num;
    logic [1:0]  bit_op;
    logic        bit_z;

    // -----------------------------------------------------------------------
    // Module instantiation
    // -----------------------------------------------------------------------
    eu_seq u_seq (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .ext_valid      (ext_valid),
        .rd_a_sel       (rd_a_sel),
        .rd_a_siz       (rd_a_siz),
        .rd_a_data      (rd_a_data),
        .rd_b_sel       (rd_b_sel),
        .rd_b_siz       (rd_b_siz),
        .rd_b_data      (rd_b_data),
        .wr_en          (wr_en),
        .wr_sel         (wr_sel),
        .wr_siz         (wr_siz),
        .wr_data        (wr_data),
        .sr_wr_en       (sr_wr_en),
        .sr_wr_data     (sr_wr_data),
        .sr_ccr_only    (sr_ccr_only),
        .sr_out         (sr_out),
        .alu_src        (alu_src),
        .alu_dst        (alu_dst),
        .alu_op         (alu_op),
        .alu_siz        (alu_siz),
        .alu_x_in       (alu_x_in),
        .alu_z_in       (alu_z_in),
        .alu_result     (alu_result),
        .alu_n          (alu_n),
        .alu_z          (alu_z),
        .alu_v          (alu_v),
        .alu_c          (alu_c),
        .alu_x          (alu_x),
        .shf_operand    (shf_operand),
        .shf_count      (shf_count),
        .shf_op         (shf_op),
        .shf_siz        (shf_siz),
        .shf_x_in       (shf_x_in),
        .shf_result     (shf_result),
        .shf_n          (shf_n),
        .shf_z          (shf_z),
        .shf_v          (shf_v),
        .shf_c          (shf_c),
        .shf_x          (shf_x),
        .md_src         (md_src),
        .md_dst         (md_dst),
        .md_op          (md_op),
        .md_result_lo   (md_result_lo),
        .md_result_hi   (md_result_hi),
        .md_n           (md_n),
        .md_z           (md_z),
        .md_v           (md_v),
        .md_c           (md_c),
        .md_div_by_zero (md_div_by_zero),
        .bcd_src        (bcd_src),
        .bcd_dst        (bcd_dst),
        .bcd_op         (bcd_op),
        .bcd_x_in       (bcd_x_in),
        .bcd_z_in       (bcd_z_in),
        .bcd_result     (bcd_result),
        .bcd_c          (bcd_c),
        .bcd_z          (bcd_z_flag),
        .bit_dst        (bit_dst),
        .bit_num        (bit_num),
        .bit_op         (bit_op),
        .bit_result     (bit_result),
        .bit_z          (bit_z),
        .instr_ack      (instr_ack),
        .seq_busy       (seq_busy),
        .div_trap       (div_trap)
    );

    eu_regfile u_rf (
        .clk_4x     (clk_4x),
        .rst_n      (rst_n),
        .rd_a_sel   (rd_a_sel),
        .rd_a_siz   (rd_a_siz),
        .rd_a_data  (rd_a_data),
        .rd_b_sel   (rd_b_sel),
        .rd_b_siz   (rd_b_siz),
        .rd_b_data  (rd_b_data),
        .wr_en      (wr_en),
        .wr_sel     (wr_sel),
        .wr_siz     (wr_siz),
        .wr_data    (wr_data),
        .pc_wr_en   (1'b0),
        .pc_wr_data (32'h0),
        .pc_out     (),
        .sr_wr_en   (sr_wr_en),
        .sr_wr_data (sr_wr_data),
        .sr_ccr_only(sr_ccr_only),
        .sr_out     (sr_out),
        .vbr_wr_en  (1'b0),
        .vbr_wr_data(32'h0),
        .vbr_out    (),
        .usp_out    (),
        .msp_out    (),
        .isp_out    (),
        .supervisor (),
        .master_mode(),
        .ipl_mask   ()
    );

    eu_alu u_alu (
        .src    (alu_src),
        .dst    (alu_dst),
        .op     (alu_op),
        .siz    (alu_siz),
        .x_in   (alu_x_in),
        .z_in   (alu_z_in),
        .result (alu_result),
        .n_out  (alu_n),
        .z_out  (alu_z),
        .v_out  (alu_v),
        .c_out  (alu_c),
        .x_out  (alu_x)
    );

    eu_shifter u_shf (
        .operand (shf_operand),
        .count   (shf_count),
        .op      (shf_op),
        .siz     (shf_siz),
        .x_in    (shf_x_in),
        .result  (shf_result),
        .n_out   (shf_n),
        .z_out   (shf_z),
        .v_out   (shf_v),
        .c_out   (shf_c),
        .x_out   (shf_x)
    );

    eu_mul_div u_md (
        .src        (md_src),
        .dst        (md_dst),
        .op         (md_op),
        .result_lo  (md_result_lo),
        .result_hi  (md_result_hi),
        .n_out      (md_n),
        .z_out      (md_z),
        .v_out      (md_v),
        .c_out      (md_c),
        .div_by_zero(md_div_by_zero)
    );

    eu_bcd u_bcd (
        .src    (bcd_src),
        .dst    (bcd_dst),
        .op     (bcd_op),
        .x_in   (bcd_x_in),
        .z_in   (bcd_z_in),
        .result (bcd_result),
        .c_out  (bcd_c),
        .x_out  (),
        .z_out  (bcd_z_flag)
    );

    eu_bitops u_bit (
        .dst     (bit_dst),
        .bit_num (bit_num),
        .op      (bit_op),
        .result  (bit_result),
        .z_out   (bit_z)
    );

    // -----------------------------------------------------------------------
    // Checks and tasks
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

    // Send one instruction (held for 1 cycle, then released)
    task send(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        instr_word  = iw;
        instr_valid = 1'b1;
        ext_data    = imm;
        ext_valid   = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
    endtask

    // Wait 2 cycles for EX→WB→regfile-commit pipeline drain
    task drain;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Convenience: send + drain (single instruction with full pipeline flush)
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        send(iw, imm, has_ext);
        drain;
    endtask

    // -----------------------------------------------------------------------
    // Instruction encodings
    // -----------------------------------------------------------------------
    // ADDI/SUBI/ANDI/ORI/EORI.x #,Dn
    // Format: 0000_ooo_0_ss_000_rrr  ooo=001(ANDI),010(SUBI),011(ADDI),101(EORI),110(CMPI)
    // ss: 00=byte, 01=word, 10=long
    localparam ADDI_L = 16'h0600 | (3'b011 << 9); // 0x0680 base for long: | 0x80
    // ss=10 → bits[7:6]=10 → bits[7]=1,bits[6]=0 → 0x80 in lower byte
    localparam ADDI_L_D0 = 16'h0680, ADDI_L_D1 = 16'h0681, ADDI_L_D2 = 16'h0682;
    localparam ADDI_W_D0 = 16'h0640; // ss=01
    localparam ADDI_B_D0 = 16'h0600; // ss=00
    localparam SUBI_L_D0 = 16'h0480; // ooo=010, ss=10
    localparam ANDI_L_D0 = 16'h0280; // ooo=001, ss=10
    localparam ORI_L_D0  = 16'h0080; // ooo=000, ss=10
    localparam EORI_L_D0 = 16'h0A80; // ooo=101, ss=10
    localparam CMPI_L_D0 = 16'h0C80; // ooo=110, ss=10

    // MOVE.L/W/B Dm,Dn: group[15:12]=size, dest=[11:9], dest_mode=[8:6]=000, src_mode=[5:3]=000, src=[2:0]
    localparam MOVE_L_D1_D0 = 16'h2001; // MOVE.L D1,D0
    localparam MOVE_W_D1_D0 = 16'h3001; // MOVE.W D1,D0
    localparam MOVE_B_D2_D0 = 16'h1002; // MOVE.B D2,D0

    // ADD/SUB/AND/OR.L Dm,Dn (ea→Dn, dir=0): 1x01/1001/1100/1000 [11:9]=Dn [8]=0 [7:6]=10 [5:3]=000 [2:0]=Dm
    localparam ADD_L_D1_D0  = 16'hD081; // D0 = D0 + D1
    localparam ADD_L_D0_D1  = 16'hD280; // D1 = D1 + D0
    localparam SUB_L_D1_D0  = 16'h9081; // D0 = D0 - D1
    localparam AND_L_D1_D0  = 16'hC081; // D0 = D0 & D1
    localparam OR_L_D1_D0   = 16'h8081; // D0 = D0 | D1

    // EOR.L D0,D1 (D1=D1^D0): 1011_000_1_10_000_001 = 0xB181
    localparam EOR_L_D0_D1  = 16'hB181;
    // CMP.L D1,D0 (flags=D0-D1): 1011_000_0_10_000_001 = 0xB081
    localparam CMP_L_D1_D0  = 16'hB081;
    // CMP.L D0,D1 (flags=D1-D0): 1011_001_0_10_000_000 = 0xB280
    localparam CMP_L_D0_D1  = 16'hB280;

    // NEG/NEGX/NOT/CLR/TST.L Dn: group=0100, [11:9]=subop, [7:6]=10(long), [5:3]=000, [2:0]=Dn
    localparam NEG_L_D0  = 16'h4480; // subop=010
    localparam NEGX_L_D0 = 16'h4080; // subop=000
    localparam NOT_L_D0  = 16'h4680; // subop=011
    localparam CLR_L_D0  = 16'h4280; // subop=001
    localparam TST_L_D0  = 16'h4A80; // subop=101

    // Shifts: 1110_ccc_d_ss_i_tt_rrr  ccc=count/reg, d=dir(1=L), ss=size, i=0(imm)/1(reg), tt=type, rrr=dest
    // tt: 00=AS, 01=LS, 10=ROX, 11=RO
    // shf_op = {tt[1], tt[0]^tt[1], ~d}
    localparam LSL_L_2_D0 = 16'hE588; // ccc=2,d=1,ss=10,i=0,tt=01,rrr=0
    localparam LSR_L_1_D0 = 16'hE288; // ccc=1,d=0,ss=10,i=0,tt=01,rrr=0
    localparam ASR_L_1_D0 = 16'hE280; // ccc=1,d=0,ss=10,i=0,tt=00,rrr=0
    localparam ROL_W_1_D0 = 16'hE358; // ccc=1,d=1,ss=01,i=0,tt=11,rrr=0

    // MUL/DIV: [15:12]=1100/1000, [11:9]=Dn(dest), [8]=0(MULU/DIVU)/1(MULS/DIVS), [7:6]=11, [5:3]=000, [2:0]=Dm(src)
    localparam MULU_W_D1_D0 = 16'hC0C1;
    localparam MULS_W_D1_D0 = 16'hC1C1;
    localparam DIVU_W_D1_D0 = 16'h80C1;
    localparam DIVS_W_D1_D0 = 16'h81C1;

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 27: eu_seq ===");

        // Reset for 2 cycles
        rst_n = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // ================================================================
        // A: ADDI — initialize registers and verify writes
        // ================================================================
        $display("--- A: ADDI ---");

        // A1: ADDI.L #10, D0
        run(ADDI_L_D0, 32'd10, 1'b1);
        check32("A1: D0=10", u_rf.d_reg[0], 32'd10);
        check("A1: N=0", !u_rf.sr_r[3]);
        check("A1: Z=0", !u_rf.sr_r[2]);

        // A2: ADDI.L #3, D1
        run(ADDI_L_D1, 32'd3, 1'b1);
        check32("A2: D1=3", u_rf.d_reg[1], 32'd3);

        // A3: ADDI.W #0x1234, D0 — word add, D0 was 10 = 0x0A, lower word → 0x123E
        run(ADDI_W_D0, 32'h00001234, 1'b1);
        check32("A3: D0 word", u_rf.d_reg[0], 32'h0000123E);

        // A4: ADDI.B #2, D0 — byte add, D0[7:0] was 0x3E → 0x40
        run(ADDI_B_D0, 32'h00000002, 1'b1);
        check32("A4: D0 byte", u_rf.d_reg[0], 32'h00001240);

        // A5: SUBI.L #0x1240, D0 — back to 0
        run(SUBI_L_D0, 32'h00001240, 1'b1);
        check32("A5: D0=0", u_rf.d_reg[0], 32'h0);
        check("A5: Z=1", u_rf.sr_r[2]);

        // A6: ORI.L #0xA5, D0
        run(ORI_L_D0, 32'h000000A5, 1'b1);
        check32("A6: D0=0xA5", u_rf.d_reg[0], 32'h000000A5);

        // A7: ANDI.L #0x0F, D0
        run(ANDI_L_D0, 32'h0000000F, 1'b1);
        check32("A7: D0=5", u_rf.d_reg[0], 32'h00000005);

        // A8: EORI.L #0xFF, D0
        run(EORI_L_D0, 32'h000000FF, 1'b1);
        check32("A8: D0=0xFA", u_rf.d_reg[0], 32'h000000FA);

        // A9: CMPI.L #0xFA, D0 — no write, flags: Z=1, N=0, C=0
        run(CMPI_L_D0, 32'h000000FA, 1'b1);
        check("A9: CMPI Z=1", u_rf.sr_r[2]);
        check("A9: CMPI N=0", !u_rf.sr_r[3]);
        check32("A9: D0 unchanged=0xFA", u_rf.d_reg[0], 32'h000000FA);

        // ================================================================
        // B: MOVE
        // ================================================================
        $display("--- B: MOVE ---");
        // Re-initialize: D0=0, D1=0xDEADBEEF
        run(ADDI_L_D0, 32'h0, 1'b1); // D0=0 (add 0, D0 was 0xFA)
        // Hmm, ADDI.L #0,D0 doesn't clear D0, just adds 0. D0 stays 0xFA.
        // Use CLR instead.
        run(CLR_L_D0, 32'h0, 1'b0); // CLR.L D0 → D0=0
        check32("B0: CLR D0", u_rf.d_reg[0], 32'h0);
        run(ADDI_L_D1, 32'hDEAD0000, 1'b1); // D1 = 3 + 0xDEAD0000
        // D1 was 3, adding 0xDEAD0000: 3+0xDEAD0000=0xDEAD0003
        // Let me use a fresh D1 by CLR then ADDI
        // Actually D1=3 from A2. Let's just use what we have.
        // D1 = 3 + 0xDEAD0000 = 0xDEAD0003
        check32("B0: D1=0xDEAD0003", u_rf.d_reg[1], 32'hDEAD0003);

        // B1: MOVE.L D1,D0 → D0=0xDEAD0003
        run(MOVE_L_D1_D0, 32'h0, 1'b0);
        check32("B1: MOVE.L D1→D0", u_rf.d_reg[0], 32'hDEAD0003);
        check("B1: N=1 (msb set)", u_rf.sr_r[3]);
        check("B1: Z=0", !u_rf.sr_r[2]);

        // B2: MOVE.W D1,D0 (D0[15:0] = D1[15:0]=0x0003, D0[31:16] preserved)
        run(MOVE_W_D1_D0, 32'h0, 1'b0);
        check32("B2: MOVE.W D1→D0", u_rf.d_reg[0], 32'hDEAD0003);
        // D0[31:16] was 0xDEAD (from B1), D0[15:0] = D1[15:0] = 0x0003
        // So D0 = 0xDEAD_0003 ✓ (same as before, since D1[15:0]=0x0003)
        check("B2: N=0 (word msb D0[15]=0)", !u_rf.sr_r[3]);

        // B3: MOVE.B D2,D0 (D0[7:0] = D2[7:0]; D2=0 from reset; D0[31:8] preserved)
        // D2 was touched by ADDI_L_D2 — but we never ran that in this test.
        // D2 = 0 (reset state). D0[7:0] ← 0. D0 = 0xDEAD0000
        run(MOVE_B_D2_D0, 32'h0, 1'b0);
        check32("B3: MOVE.B D2→D0", u_rf.d_reg[0], 32'hDEAD0000);

        // ================================================================
        // C: ADD, SUB, AND, OR, EOR, CMP
        // ================================================================
        $display("--- C: ALU ---");
        // Init: D0=10, D1=3
        run(CLR_L_D0,   32'h0, 1'b0);
        run(ADDI_L_D0,  32'd10, 1'b1);  // D0=10
        run(ADDI_L_D1,  32'd3,  1'b1);  // D1=3+0xDEAD0003? No: still 0xDEAD0003+3
        // Need to CLR D1 too. Use NOT then NOT (NOT NOT X = X) or just use hardcoded value.
        // Actually let me re-init D1 from scratch.
        run(CLR_L_D0, 32'h0, 1'b0);          // D0=0 (reusing CLR_L_D0 for D0 again)
        // Wait, CLR_L_D0 clears D0. I need to clear D1.
        // CLR.L D1: subop=001, rrr=001 → 0100_001_0_10_000_001 = 0x4281
        run(16'h4281, 32'h0, 1'b0);           // CLR.L D1 → D1=0
        check32("C0: CLR D1", u_rf.d_reg[1], 32'h0);

        run(ADDI_L_D0, 32'd10, 1'b1); // D0=10
        run(ADDI_L_D1, 32'd3,  1'b1); // D1=3
        check32("C0b: D0=10", u_rf.d_reg[0], 32'd10);
        check32("C0c: D1=3",  u_rf.d_reg[1], 32'd3);

        // C1: ADD.L D1,D0 → D0=13
        run(ADD_L_D1_D0, 32'h0, 1'b0);
        check32("C1: ADD D0=13", u_rf.d_reg[0], 32'd13);
        check("C1: N=0", !u_rf.sr_r[3]); check("C1: Z=0", !u_rf.sr_r[2]);

        // C2: SUB.L D1,D0 (D0=13-3=10)
        run(SUB_L_D1_D0, 32'h0, 1'b0);
        check32("C2: SUB D0=10", u_rf.d_reg[0], 32'd10);
        check("C2: C=0 (no borrow)", !u_rf.sr_r[0]);

        // C3: AND.L D1,D0 (D0=10&3=2)
        run(AND_L_D1_D0, 32'h0, 1'b0);
        check32("C3: AND D0=2", u_rf.d_reg[0], 32'd2);

        // C4: OR.L D1,D0 (D0=2|3=3)
        run(OR_L_D1_D0, 32'h0, 1'b0);
        check32("C4: OR D0=3", u_rf.d_reg[0], 32'd3);

        // C5: EOR.L D0,D1 (D1=D1^D0=3^3=0)
        run(EOR_L_D0_D1, 32'h0, 1'b0);
        check32("C5: EOR D1=0", u_rf.d_reg[1], 32'h0);
        check("C5: Z=1", u_rf.sr_r[2]);

        // C6: CMP.L D1,D0 (D0-D1=3-0=3): N=0, Z=0, C=0
        run(CMP_L_D1_D0, 32'h0, 1'b0);
        check("C6: CMP N=0", !u_rf.sr_r[3]);
        check("C6: CMP Z=0", !u_rf.sr_r[2]);
        check("C6: CMP C=0", !u_rf.sr_r[0]);
        check32("C6: D0 unchanged", u_rf.d_reg[0], 32'd3);

        // C7: CMP.L D0,D1 (D1-D0=0-3=-3): N=1, Z=0, C=1 (borrow)
        run(CMP_L_D0_D1, 32'h0, 1'b0);
        check("C7: CMP N=1", u_rf.sr_r[3]);
        check("C7: CMP C=1", u_rf.sr_r[0]);
        check32("C7: D1 unchanged", u_rf.d_reg[1], 32'h0);

        // ================================================================
        // D: NEG, NEGX, NOT, CLR, TST
        // ================================================================
        $display("--- D: Misc ---");
        // D0=5
        run(ADDI_L_D0, 32'd5, 1'b1); // D0=3+5=8? No. D0 was 3 from C4/C6. D0=3+5=8.
        // Ugh, accumulation. Let me CLR and re-init.
        run(CLR_L_D0, 32'h0, 1'b0);
        run(ADDI_L_D0, 32'd5, 1'b1); // D0=5
        check32("D0: init D0=5", u_rf.d_reg[0], 32'd5);

        // D1: NEG.L D0 → D0=-5=0xFFFFFFFB
        run(NEG_L_D0, 32'h0, 1'b0);
        check32("D1: NEG D0=-5", u_rf.d_reg[0], 32'hFFFFFFFB);
        check("D1: N=1", u_rf.sr_r[3]); check("D1: Z=0", !u_rf.sr_r[2]);
        check("D1: C=1 (borrow from 0-5)", u_rf.sr_r[0]);

        // D2: NOT.L D0 → D0=~(-5)=~0xFFFFFFFB=4=0x00000004
        run(NOT_L_D0, 32'h0, 1'b0);
        check32("D2: NOT D0=4", u_rf.d_reg[0], 32'h00000004);

        // D3: CLR.L D0 → D0=0, Z=1
        run(CLR_L_D0, 32'h0, 1'b0);
        check32("D3: CLR D0=0", u_rf.d_reg[0], 32'h0);
        check("D3: Z=1", u_rf.sr_r[2]);

        // D4: ADDI.L #10, D0 then TST
        run(ADDI_L_D0, 32'd10, 1'b1);
        run(TST_L_D0, 32'h0, 1'b0); // TST D0=10: N=0, Z=0, V=0, C=0; no write
        check("D4: TST N=0", !u_rf.sr_r[3]);
        check("D4: TST Z=0", !u_rf.sr_r[2]);
        check32("D4: D0 unchanged", u_rf.d_reg[0], 32'd10);

        // D5: NEGX.L D0 (D0=10, X from CCR)
        // ADDI in D4 ran ALU_ADD which updates X=C=0 (10+0, no carry).
        // TST doesn't change X. So X=0 here.
        // NEGX: 0 - D0 - X = 0 - 10 - 0 = -10 = 0xFFFFFFF6
        run(NEGX_L_D0, 32'h0, 1'b0);
        check32("D5: NEGX D0=-10 (X=0)", u_rf.d_reg[0], 32'hFFFFFFF6);

        // ================================================================
        // E: Shifts
        // ================================================================
        $display("--- E: Shifts ---");
        run(CLR_L_D0, 32'h0, 1'b0);
        run(ADDI_L_D0, 32'd5, 1'b1); // D0=5

        // E1: LSL.L #2, D0 → D0=20
        run(LSL_L_2_D0, 32'h0, 1'b0);
        check32("E1: LSL #2 D0=20", u_rf.d_reg[0], 32'd20);
        check("E1: C=0", !u_rf.sr_r[0]);

        // E2: LSR.L #1, D0 → D0=10
        run(LSR_L_1_D0, 32'h0, 1'b0);
        check32("E2: LSR #1 D0=10", u_rf.d_reg[0], 32'd10);

        // E3: ASR.L #1, D0 (D0=10→5)
        run(ASR_L_1_D0, 32'h0, 1'b0);
        check32("E3: ASR #1 D0=5", u_rf.d_reg[0], 32'd5);

        // E4: LSL.L #2, D0 → 20; then NEG → -20 = 0xFFFFFFEC
        run(LSL_L_2_D0, 32'h0, 1'b0);
        run(NEG_L_D0,   32'h0, 1'b0);
        check32("E4: D0=-20", u_rf.d_reg[0], 32'hFFFFFFEC);

        // E5: ASR.L #1, D0 (D0=-20, arithmetic right shift → -10 = 0xFFFFFFF6)
        run(ASR_L_1_D0, 32'h0, 1'b0);
        check32("E5: ASR #1 -20→-10", u_rf.d_reg[0], 32'hFFFFFFF6);
        check("E5: N=1", u_rf.sr_r[3]);

        // E6: ROL.W #1, D0 (D0[15:0]=0xFFF6 from E5's -10, rotate left by 1)
        // 0xFFF6 = 1111_1111_1111_0110 → ROL1 = 1111_1111_1110_1101 = 0xFFED; C=1 (old msb)
        // wr_siz=word preserves D0[31:16]=0xFFFF → D0 = {0xFFFF, 0xFFED} = 0xFFFFFFED
        run(ROL_W_1_D0, 32'h0, 1'b0);
        check32("E6: ROL.W D0", u_rf.d_reg[0], 32'hFFFFFFED);
        check("E6: C=1", u_rf.sr_r[0]);

        // ================================================================
        // F: MULU, MULS, DIVU, DIVS
        // ================================================================
        $display("--- F: MUL/DIV ---");
        // F1: MULU.W D1,D0 (D0[15:0]=5 (5&0xFFFF=5), D1[15:0]=?)
        // Re-init: D0=5, D1=4
        run(CLR_L_D0, 32'h0, 1'b0);
        run(16'h4281, 32'h0, 1'b0); // CLR.L D1
        run(ADDI_L_D0, 32'd5, 1'b1); // D0=5
        run(ADDI_L_D1, 32'd4, 1'b1); // D1=4

        // F1: MULU.W D1,D0: D0 = D0[15:0] * D1[15:0] = 5*4 = 20
        run(MULU_W_D1_D0, 32'h0, 1'b0);
        check32("F1: MULU 5*4=20", u_rf.d_reg[0], 32'd20);
        check("F1: Z=0", !u_rf.sr_r[2]); check("F1: N=0", !u_rf.sr_r[3]);

        // F2: MULS.W D1,D0 (D0=20, D1=4): 20*4=80 (signed)
        run(MULS_W_D1_D0, 32'h0, 1'b0);
        check32("F2: MULS 20*4=80", u_rf.d_reg[0], 32'd80);

        // F3: DIVU.W D1,D0: D0=80/4=20, rem=0 → result={rem[15:0],quot[15:0]}={0,20}=0x00000014
        run(DIVU_W_D1_D0, 32'h0, 1'b0);
        check32("F3: DIVU 80/4={0,20}", u_rf.d_reg[0], 32'h0000_0014);

        // F4: DIVS.W with signed dividend
        // Set D0=-7 (0xFFFFFFF9): CLR, SUBI.L #7
        run(CLR_L_D0, 32'h0, 1'b0);
        run(SUBI_L_D0, 32'd7, 1'b1); // D0=0-7=0xFFFFFFF9
        check32("F4-init: D0=-7", u_rf.d_reg[0], 32'hFFFFFFF9);
        // Set D1=3
        run(16'h4281, 32'h0, 1'b0); // CLR D1
        run(ADDI_L_D1, 32'd3, 1'b1); // D1=3

        // DIVS.W D1,D0: -7/3 = quot=-2 (0xFFFE), rem=-1 (0xFFFF)
        // result = {rem[15:0], quot[15:0]} = {0xFFFF, 0xFFFE} = 0xFFFFFFFE
        run(DIVS_W_D1_D0, 32'h0, 1'b0);
        check32("F4: DIVS -7/3", u_rf.d_reg[0], 32'hFFFFFFFE);
        check("F4: N=1 (quot=-2)", u_rf.sr_r[3]);

        // F5: DIVU overflow check (dividend > max 16-bit quotient)
        run(CLR_L_D0, 32'h0, 1'b0);
        run(ADDI_L_D0, 32'h00010000, 1'b1); // D0=0x10000=65536
        run(16'h4281, 32'h0, 1'b0); run(ADDI_L_D1, 32'd1, 1'b1); // D1=1
        run(DIVU_W_D1_D0, 32'h0, 1'b0); // 65536/1 = overflow (>0xFFFF)
        check("F5: DIVU overflow V=1", u_rf.sr_r[1]);

        // ================================================================
        // G: RAW hazard stall test
        // ================================================================
        $display("--- G: RAW hazard ---");
        // Reset D0,D1 to 0
        run(CLR_L_D0, 32'h0, 1'b0);
        run(16'h4281, 32'h0, 1'b0); // CLR D1

        // G1: Feed A (ADDI.L #5,D0) then immediately B (ADD.L D0,D1) without drain.
        //     Expected: 2-cycle stall, then D1=5.
        //     Incorrect (no stall): D1=0+old_D0=0.

        // Feed A: ADDI.L #5, D0
        instr_word = ADDI_L_D0; ext_data = 32'd5; ext_valid = 1; instr_valid = 1;
        @(posedge clk_4x); #1; // A → EX; instr_ack for A

        // Feed B immediately: ADD.L D0,D1 (D1=D1+D0); B reads D0 which A writes
        instr_word = ADD_L_D0_D1; ext_valid = 0; // instr_valid still 1
        @(posedge clk_4x); #1; // posedge 2: hazard_ex stall; A → WB; EX ← bubble
        check("G1: stall cycle 1", seq_busy); // hazard_wb=1 → still stalling
        @(posedge clk_4x); #1; // posedge 3: hazard_wb stall; WB → bubble; D0=5 committed in regfile
        // At posedge 3+#1: WB=bubble so seq_busy=0; stall clears; B can enter EX next posedge
        @(posedge clk_4x); #1; // posedge 4: stall=0; B → EX (reads committed D0=5)
        instr_valid = 0;        // B accepted; deassert
        @(posedge clk_4x); #1; // posedge 5: B → WB; wr_en fires for D1
        @(posedge clk_4x); #1; // posedge 6: D1=5 committed
        check32("G1: D1=5 (stall resolved)", u_rf.d_reg[1], 32'd5);

        // G2: Non-hazard back-to-back (D0 op D2, D1 op D3 — different registers)
        run(CLR_L_D0, 32'h0, 1'b0);
        run(ADDI_L_D0, 32'd7, 1'b1); // D0=7
        // ADD.L D0,D1 after full drain: no stall (D0 already committed)
        run(ADD_L_D0_D1, 32'h0, 1'b0); // D1=D1+D0=5+7=12
        check32("G2: no stall D1=12", u_rf.d_reg[1], 32'd12);

        // ================================================================
        // H: BCD arithmetic (ABCD / SBCD / NBCD)
        // ================================================================
        $display("--- H: BCD arithmetic ---");

        // H1: ABCD D0,D1 — 0x12 + 0x34 = 0x46
        // ABCD Ds,Dd: 1100_Dd_1_00_00_0_Ds → Dd=D1=[001], Ds=D0=[000]
        // [15:8]=1100_0011=0xC3, [7:0]=00_000_000=0x00 → 0xC300
        run(CLR_L_D0,   32'h0,    1'b0);
        run(16'h4281,   32'h0,    1'b0);  // CLR.L D1
        run(ADDI_B_D0,  32'h12,   1'b1);  // D0 = 0x12
        run(16'h0601,   32'h34,   1'b1);  // ADDI.B #0x34, D1
        run(16'hC300,   32'h0,    1'b0);  // ABCD D0,D1
        check32("H1: ABCD 0x12+0x34=0x46", u_rf.d_reg[1], 32'h46);

        // H2: SBCD D2,D3 — 0x72 - 0x55 = 0x17
        // SBCD Ds,Dd: 1000_Dd_1_00_00_0_Ds → Dd=D3=[011], Ds=D2=[010]
        // [15:8]=1000_0111=0x87, [7:0]=00_000_010=0x02 → 0x8702
        run(16'h4282,   32'h0,    1'b0);  // CLR.L D2
        run(16'h4283,   32'h0,    1'b0);  // CLR.L D3
        run(16'h0602,   32'h55,   1'b1);  // D2 = 0x55
        run(16'h0603,   32'h72,   1'b1);  // D3 = 0x72
        run(16'h8702,   32'h0,    1'b0);  // SBCD D2,D3 (dst=D3, src=D2)
        check32("H2: SBCD 0x72-0x55=0x17", u_rf.d_reg[3], 32'h17);

        // H3: NBCD D4 — -(0x45) = 0x55 with borrow
        // NBCD Dn: 0100_100_0_00_000_Dn → Dn=D4=[100]
        // [15:8]=0100_1000=0x48, [7:0]=00_000_100=0x04 → 0x4804
        run(16'h4284,   32'h0,    1'b0);  // CLR.L D4
        run(16'h0604,   32'h45,   1'b1);  // ADDI.B #0x45, D4
        run(16'h4804,   32'h0,    1'b0);  // NBCD D4
        check32("H3: NBCD 0x45=0x55", u_rf.d_reg[4], 32'h55);
        check("H3: NBCD X flag set", u_rf.sr_r[4]);

        // ================================================================
        // I: Bit operations (BTST/BCHG/BCLR/BSET)
        // ================================================================
        $display("--- I: Bit ops ---");

        // I1: BSET #5,D7 — D7=0 → D7=0x20, Z=1 (bit was clear)
        // 0000_100_0_11_000_111 + ext=5 → [15:8]=0x08, [7:0]=0xC7 → 0x08C7
        run(16'h4287,   32'h0,    1'b0);  // CLR.L D7
        run(16'h08C7,   32'h5,    1'b1);  // BSET #5,D7
        check32("I1: BSET #5,D7 → 0x20", u_rf.d_reg[7], 32'h20);
        check("I1: Z=1 (bit was 0)",  u_rf.sr_r[2]);

        // I2: BTST #5,D7 — bit 5=1, Z=0
        // 0000_100_0_00_000_111 + ext=5 → 0x0807
        run(16'h0807,   32'h5,    1'b1);
        check("I2: BTST #5 set → Z=0", !u_rf.sr_r[2]);

        // I3: BCLR #5,D7 — D7=0x20 → D7=0x00, Z=0 (bit was set)
        // 0000_100_0_10_000_111 + ext=5 → 0x0887
        run(16'h0887,   32'h5,    1'b1);
        check32("I3: BCLR #5,D7 → 0", u_rf.d_reg[7], 32'h0);
        check("I3: Z=0 (bit was set)",  !u_rf.sr_r[2]);

        // I4: BCHG #3,D7 — D7=0 → D7=0x08, Z=1 (bit was clear)
        // 0000_100_0_01_000_111 + ext=3 → [7:0]=01_000_111=0x47 → 0x0847
        run(16'h0847,   32'h3,    1'b1);
        check32("I4: BCHG #3,D7 → 0x08", u_rf.d_reg[7], 32'h8);
        check("I4: Z=1 (bit was 0)",  u_rf.sr_r[2]);

        // I5: Register BSET D5,D0 — D5=10(0xA) as bit count, D0=0 → D0=0x400
        // BSET Ds,Dd: 0000_Ds_1_11_000_Dd → Ds=D5=[101], Dd=D0=[000]
        // [15:8]=0000_1011=0x0B, [7:0]=11_000_000=0xC0 → 0x0BC0
        run(CLR_L_D0,   32'h0,    1'b0);
        run(16'h4285,   32'h0,    1'b0);  // CLR.L D5
        run(16'h0605,   32'hA,    1'b1);  // ADDI.B #10, D5 → D5=10
        run(16'h0BC0,   32'h0,    1'b0);  // BSET D5,D0 → D0[10]=1
        check32("I5: BSET D5,D0 → 0x400", u_rf.d_reg[0], 32'h400);

        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                  $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

// Phase 68: TRAPcc, CAS EU decode, BCD/bit-op memory forms
//
//   P68-01: TRAPcc (condition F)      — no trap (NOP)
//   P68-02: TRAPcc (condition T)      — trap fires (eu_trapv_req pulse)
//   P68-03: TRAPcc.W (condition F)    — no trap, 1 ext word consumed
//   P68-04: TRAPcc.L (condition F)    — no trap, 2 ext words consumed
//   P68-05: CAS.L D2,D3,(A0)         — compare matches → write D3 to memory
//   P68-06: CAS.L D2,D3,(A0)         — compare fails  → load M[EA] into D2
//   P68-07: CAS.W D2,D3,(A0)         — word compare matches → write
//   P68-08: NBCD (A0)                — memory BCD negate
//   P68-09: ABCD -(A1),-(A0)         — memory BCD add  (predecrement)
//   P68-10: SBCD -(A1),-(A0)         — memory BCD sub  (predecrement)
//   P68-11: BSET #3,(A0)             — memory bit set

`default_nettype none
`timescale 1ns/1ps

module seq68_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word  = 16'h0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 32'h0;
    logic        ext_valid   = 0;
    logic        instr_ack;
    logic        eu_busy;

    logic        pc_wr_en    = 0;
    logic [31:0] pc_wr_data  = 32'h0;
    logic [31:0] pc_out;
    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 32'h0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;

    logic [31:0] decode_pc    = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req;
    logic        mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
    logic        mem_berr    = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;
    logic [31:0] eu_coproc_rdata = 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack   = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack    = 0;
    logic [15:0] eu_ptest_mmusr  = 16'h0;

    logic [31:0] tc_out, tt0_out, tt1_out;
    logic [63:0] crp_out, srp_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;
    logic        eu_reset_req;

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu u_dut (
        .clk_4x        (clk),
        .rst_n         (rst_n),
        .instr_word    (instr_word),
        .instr_valid   (instr_valid),
        .ext_data      (ext_data),
        .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),
        .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en),
        .pc_wr_data    (pc_wr_data),
        .pc_out        (pc_out),
        .vbr_wr_en     (vbr_wr_en),
        .vbr_wr_data   (vbr_wr_data),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),
        .msp_out       (msp_out),
        .isp_out       (isp_out),
        .cacr_out      (cacr_out),
        .caar_out      (caar_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .decode_pc     (decode_pc),
        .branch_taken  (branch_taken),
        .branch_target (branch_target),
        .mem_req       (mem_req),
        .mem_rw        (mem_rw),
        .mem_siz       (mem_siz),
        .mem_fc        (mem_fc),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_rdata     (mem_rdata),
        .mem_ack       (mem_ack),
        .mem_berr      (mem_berr),
        .mem_rmw       (mem_rmw),
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .eu_pflush_req   (eu_pflush_req),
        .eu_pflush_all   (eu_pflush_all),
        .eu_pflush_fc    (eu_pflush_fc),
        .eu_pflush_va    (eu_pflush_va),
        .eu_pflush_ack   (eu_pflush_ack),
        .eu_ptest_req    (eu_ptest_req),
        .eu_ptest_va     (eu_ptest_va),
        .eu_ptest_fc     (eu_ptest_fc),
        .eu_ptest_ack    (eu_ptest_ack),
        .eu_ptest_mmusr  (eu_ptest_mmusr),
        .tc_out          (tc_out),
        .tt0_out         (tt0_out),
        .tt1_out         (tt1_out),
        .crp_out         (crp_out),
        .srp_out         (srp_out),
        .an_wr_en        (an_wr_en),
        .an_wr_sel       (an_wr_sel),
        .an_wr_data      (an_wr_data),
        .div_trap        (div_trap),
        .chk_trap        (chk_trap),
        .eu_trap_req     (eu_trap_req),
        .eu_trap_num     (eu_trap_num),
        .eu_trapv_req    (eu_trapv_req),
        .eu_illegal_req  (eu_illegal_req),
        .eu_stop         (eu_stop),
        .eu_reset_req    (eu_reset_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (combinatorial ack) ────────────────────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── trapv pulse capture ─────────────────────────────────────────────────
    int trapv_count;
    always_ff @(posedge clk) begin
        if (!rst_n) trapv_count <= 0;
        else if (eu_trapv_req) trapv_count <= trapv_count + 1;
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0b exp %0b", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk_ccr(input string tag,
                            input logic exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
    endtask

    // run_instr: present instr_word + optional ext, wait for ack, then settle
    task automatic run_instr(input logic [15:0] iw,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(12) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        // CLR.L Dn then ADDI.L #val,Dn
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        // MOVEA.L D0,An: 0010_an_001_000_000 = 2'h2 + (an<<9) + 9'h040
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        int prev_trapv;

        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        trapv_count = 0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // ====================================================================
        // P68-01: TRAPcc (condition F = never true) — no trap fired
        //   Opcode 0x51FC: 0101_0001_1111_1100
        //   f_group=5, f_cond=0001(F), f_ss=11, f_mode=111, f_reg=100 (no operand)
        // ====================================================================
        $display("--- P68-01: TRAPcc.F (no trap) ---");
        prev_trapv = trapv_count;
        run_instr(16'h51FC, 1'b0, 32'h0);
        chk1("P68-01:no_trap", (trapv_count == prev_trapv), 1'b1);

        // ====================================================================
        // P68-02: TRAPcc (condition T = always true) — trap must fire
        //   Opcode 0x50FC: 0101_0000_1111_1100
        //   f_group=5, f_cond=0000(T), f_ss=11, f_mode=111, f_reg=100
        // ====================================================================
        $display("--- P68-02: TRAPcc.T (trap fires) ---");
        prev_trapv = trapv_count;
        run_instr(16'h50FC, 1'b0, 32'h0);
        chk1("P68-02:trap_fired", (trapv_count > prev_trapv), 1'b1);

        // ====================================================================
        // P68-03: TRAPcc.W (condition F) — no trap, 1-word operand consumed
        //   Opcode 0x51FA: 0101_0001_1111_1010, ext=0x1234
        //   f_reg=010 → dec_needs_ext=1
        // ====================================================================
        $display("--- P68-03: TRAPcc.W.F (no trap, ext consumed) ---");
        prev_trapv = trapv_count;
        run_instr(16'h51FA, 1'b1, 32'h00001234);
        chk1("P68-03:no_trap", (trapv_count == prev_trapv), 1'b1);

        // ====================================================================
        // P68-04: TRAPcc.L (condition F) — no trap, 2-word operand consumed
        //   Opcode 0x51F8: 0101_0001_1111_1000, ext=0xDEAD_BEEF
        //   f_reg=000 → dec_needs_ext=1 (2-word ext consumed by seq)
        // ====================================================================
        $display("--- P68-04: TRAPcc.L.F (no trap, 2-ext consumed) ---");
        prev_trapv = trapv_count;
        run_instr(16'h51F8, 1'b1, 32'hDEAD_BEEF);
        chk1("P68-04:no_trap", (trapv_count == prev_trapv), 1'b1);

        // ====================================================================
        // P68-05: CAS.L D2,D3,(A0) — compare matches, write D3 to memory
        //   Set M[0x100] = 0xABCD_1234 = compare value (D2)
        //   Set D3 = 0x5678_9ABC = replacement value
        //   After CAS: M[0x100] should be 0x5678_9ABC; Z=1 (match)
        //
        //   Opcode: group 0, f_dir=0, f_dn=111(→.L), f_ss=11, f_mode=010, f_reg=0(A0)
        //   = 0000_111_0_11_010_000 = 0x0ED0
        //   ext word: [8:6]=Dc=D2(010), [2:0]=Du=D3(011) → 0x0043
        // ====================================================================
        $display("--- P68-05: CAS.L match → write Du ---");
        ram[32'h100>>2] = 32'hABCD_1234;
        set_an(3'd0, 32'h0000_0100);
        set_dn(2, 32'hABCD_1234);   // Dc = D2 (compare value = M[EA])
        set_dn(3, 32'h5678_9ABC);   // Du = D3 (replacement)
        run_instr(16'h0ED0, 1'b1, 32'h0083);
        chk("P68-05:mem",    ram[32'h100>>2], 32'h5678_9ABC);
        chk1("P68-05:Z",     sr_out[2], 1'b1);  // Z=1: compare matched

        // ====================================================================
        // P68-06: CAS.L D2,D3,(A0) — compare fails, load M[EA] into D2
        //   Set M[0x104] = 0x1111_2222
        //   Set D2 = 0xFFFF_FFFF (doesn't match), D3 = 0x5678_9ABC
        //   After CAS: M[0x104] unchanged; D2 = 0x1111_2222; Z=0
        //   Read D2 back using MOVE.L D2,D0 + check D0
        // ====================================================================
        $display("--- P68-06: CAS.L mismatch → load M[EA] to Dc ---");
        ram[32'h104>>2] = 32'h1111_2222;
        set_an(3'd0, 32'h0000_0104);
        set_dn(2, 32'hFFFF_FFFF);   // Dc = D2 (won't match)
        set_dn(3, 32'h5678_9ABC);   // Du = D3
        run_instr(16'h0ED0, 1'b1, 32'h0083);
        // Memory unchanged
        chk("P68-06:mem",    ram[32'h104>>2], 32'h1111_2222);
        chk1("P68-06:Z",     sr_out[2], 1'b0);  // Z=0: mismatch
        // D2 should now hold M[EA] = 0x1111_2222
        // MOVE.L D2,(A1) directly: 0010_001_010_000_010 = 0x2282
        set_an(3'd1, 32'h0000_0200);
        run_instr(16'h2282, 1'b0, 32'h0);  // MOVE.L D2,(A1)
        chk("P68-06:D2_in_D0", ram[32'h200>>2], 32'h1111_2222);

        // ====================================================================
        // P68-07: CAS.W D2,D3,(A0) — word compare matches, write word
        //   Set M[0x108] (lower word): 0x0000_ABCD
        //   D2=0x0000_ABCD (compare), D3=0x0000_5678 (replacement)
        //   Opcode: group 0, f_dn=011(→.W), f_ss=11, f_mode=010, f_reg=0(A0)
        //   = 0000_011_0_11_010_000 = 0x06D0
        // ====================================================================
        $display("--- P68-07: CAS.W match → write word ---");
        ram[32'h108>>2] = 32'h0000_ABCD;
        set_an(3'd0, 32'h0000_0108);
        set_dn(2, 32'h0000_ABCD);
        set_dn(3, 32'h0000_5678);
        run_instr(16'h06D0, 1'b1, 32'h0083);
        // Memory word written: expect 0x5678 in lower 16 bits (upper unchanged = 0x0000)
        chk("P68-07:mem",   ram[32'h108>>2], 32'h0000_5678);
        chk1("P68-07:Z",    sr_out[2], 1'b1);

        // ====================================================================
        // P68-08: NBCD (A0) — memory BCD negate
        //   Encoding: group 4, f_dir=0, f_ss=00, f_dn=100, f_mode=010, f_reg=0(A0)
        //   = 0100_100_0_00_010_000 = 0x4810
        //   M[0x110] = 0x00000027 (BCD 27); after NBCD: 0-27-X = BCD 73 (X=0 → 100-27=73)
        //   CCR: C=1 (borrow), N=0, Z=0
        // ====================================================================
        $display("--- P68-08: NBCD (A0) ---");
        ram[32'h110>>2] = 32'h0000_0027;
        set_an(3'd0, 32'h0000_0110);
        // Clear X flag first (ADDI.L #0,D0 doesn't touch X; use MOVE #0,CCR)
        // Use "MOVE #imm,CCR": ORI #0,CCR = 0003, ext=0
        run_instr(16'h003C, 1'b1, 32'h0000_0000);  // ORI #0,CCR — clears nothing, X still 0
        run_instr(16'h4810, 1'b0, 32'h0);
        // NBCD(0x27) with X=0: 0x00 - 0x27 - 0 = 0x73 BCD (with borrow, C=1)
        chk("P68-08:mem",  ram[32'h110>>2], 32'h0000_0073);
        chk1("P68-08:C",   sr_out[0], 1'b1);   // C=1 (borrow)
        chk1("P68-08:Z",   sr_out[2], 1'b0);   // Z=0

        // ====================================================================
        // P68-09: ABCD -(A1),-(A0) — memory BCD add
        //   Encoding: group C, f_dir=1, f_ss=00, f_mode=001, f_dn=0(A0), f_reg=1(A1)
        //   = 1100_000_1_00_001_001 = 0xC109
        //   Pre-decrements A0 and A1, reads bytes from each, adds BCD
        //   A0=0x0120, A1=0x0124 → read M[0x011F]→[3], M[0x0123]→[3]
        //   Actually predec: A0→0x011F, A1→0x0123; reads byte from each address
        //   Set byte at 0x011F = 0x27, byte at 0x0123 = 0x38
        //   ABCD: 0x27 + 0x38 + X=0 = 0x65 (BCD); write to 0x011F
        // ====================================================================
        $display("--- P68-09: ABCD -(A1),-(A0) ---");
        // Clear C/X flags
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);  // ANDI #0xE0,CCR → clears N,Z,V,C,X

        // Store test bytes in memory (byte at byte address)
        // 0x011F is word-address 0x118>>2=70, byte offset 3 → bits[7:0]
        // 0x0123 is word-address 0x120>>2=72, byte offset 3 → bits[7:0]
        ram[32'h11C>>2] = 32'h0000_0027;  // addr 0x11F = ram[71][7:0] ...
        // Better to use longword-aligned addresses. Let's use byte addresses 0x0200 and 0x0204
        // that are word-aligned — byte read from 0x0200 gets bits[31:24] (big-endian), tricky.
        // Use addresses that are naturally at byte offset 3 of a longword (simplest for mem model).
        // mem model reads: mem_rdata = ram[mem_addr[14:2]]; BIU byte-selects handle the rest.
        // For byte read from addr 0x0203 → ram[0x200>>2][7:0] (LSB of longword)
        // The EU/BIU: mem_rdata is the full longword, EU takes low byte for byte ops.
        // So store byte at LS byte of each longword (addr must be at last byte of word).
        // Let's use: addr 0x0203 and 0x0207
        // A0 predec from 0x0204 → A0=0x0203, A1 predec from 0x0208 → A1=0x0207
        // Wait, for byte, each access is a single byte; predec by 1 for byte.
        // A0 starts at 0x0204; after predec = 0x0203; read M[0x0203] = ram[0x200>>2][7:0]
        // A1 starts at 0x0208; after predec = 0x0207; read M[0x0207] = ram[0x204>>2][7:0]
        ram[32'h200>>2] = 32'h0000_0027;  // M[0x0203] = 0x27 (dest/Ax value)
        ram[32'h204>>2] = 32'h0000_0038;  // M[0x0207] = 0x38 (src/Ay value)
        set_an(3'd0, 32'h0000_0204);  // Ax=A0, starts at 0x0204; predec → 0x0203
        set_an(3'd1, 32'h0000_0208);  // Ay=A1, starts at 0x0208; predec → 0x0207
        run_instr(16'hC109, 1'b0, 32'h0);
        // ABCD: dst(0x27) + src(0x38) + X=0 = 0x65 BCD
        chk("P68-09:mem",  ram[32'h200>>2], 32'h0000_0065);
        chk1("P68-09:C",   sr_out[0], 1'b0);   // C=0 (no BCD carry)
        chk1("P68-09:Z",   sr_out[2], 1'b0);   // Z=0 (result non-zero)

        // ====================================================================
        // P68-10: SBCD -(A1),-(A0) — memory BCD subtract
        //   Encoding: group 8, f_dir=1, f_ss=00, f_mode=001, f_dn=0(A0), f_reg=1(A1)
        //   = 1000_000_1_00_001_001 = 0x8109
        //   Use addresses 0x0300 (dst) and 0x0304 (src)
        //   A0=0x0304, A1=0x0308; predec→ A0=0x0303, A1=0x0307
        //   M[0x0303] = 0x73 (dst), M[0x0307] = 0x28 (src)
        //   SBCD: 0x73 - 0x28 - X=0 = 0x45 BCD
        // ====================================================================
        $display("--- P68-10: SBCD -(A1),-(A0) ---");
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);  // ANDI #0xE0,CCR → clear NZVC,X
        ram[32'h300>>2] = 32'h0000_0073;  // M[0x0303] = 0x73 (Ax/dst)
        ram[32'h304>>2] = 32'h0000_0028;  // M[0x0307] = 0x28 (Ay/src)
        set_an(3'd0, 32'h0000_0304);  // Ax=A0: predec → 0x0303
        set_an(3'd1, 32'h0000_0308);  // Ay=A1: predec → 0x0307
        run_instr(16'h8109, 1'b0, 32'h0);
        // SBCD: 0x73 - 0x28 - 0 = 0x45 BCD
        chk("P68-10:mem",  ram[32'h300>>2], 32'h0000_0045);
        chk1("P68-10:C",   sr_out[0], 1'b0);   // C=0 (no borrow)

        // ====================================================================
        // P68-11: BSET #3,(A0) — memory bit set
        //   Encoding: group 0, f_dir=0, f_dn=100, f_ss=11, f_mode=010, f_reg=0(A0)
        //   = 0000_100_0_11_010_000 = 0x08D0
        //   ext word [2:0] = bit number = 3 → 0x0003
        //   M[0x0400] = 0x00000000 → after BSET #3: bit 3 set → 0x00000008
        //   Z=1 (bit was 0 before set)
        // ====================================================================
        $display("--- P68-11: BSET #3,(A0) ---");
        ram[32'h400>>2] = 32'h0000_0000;
        set_an(3'd0, 32'h0000_0400);
        run_instr(16'h08D0, 1'b1, 32'h0003);
        chk("P68-11:mem",  ram[32'h400>>2], 32'h0000_0008);
        chk1("P68-11:Z",   sr_out[2], 1'b1);   // Z=1: bit was clear before

        // ====================================================================
        // Results
        // ====================================================================
        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("PASS seq68 (%0d checks)", pass_cnt);
        else
            $display("FAIL seq68: %0d/%0d checks failed", fail_cnt, pass_cnt + fail_cnt);
        $finish;
    end

    // Timeout guard
    initial begin
        #200000;
        $display("FAIL seq68: TIMEOUT");
        $finish;
    end

endmodule

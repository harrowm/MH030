`default_nettype none

// MC68030 Micro-sequencer — purely combinational glue between IFU and EU.
//
// Responsibilities:
//   1. Decode instruction word count (opcode + 0/1/2 extension words).
//   2. Convert IFU ext_data format → EU format:
//        IFU: {q[1], q[2]} = {first_ext_word[15:0], second_ext_word[15:0]}
//        EU:  immediate in low bits (zero-extended)
//        Byte/word immediate  → {16'h0, first_ext_word}
//        Long immediate (32b) → {first_ext_word, second_ext_word} (= ifu_ext_data as-is)
//        Bit number (BTST…)   → {16'h0, first_ext_word}
//   3. Drive IFU drain: advance queue by (1 + ext_count) words when EU accepts.
//   4. Pass instr_word / instr_valid / ext_valid to EU unchanged
//      (EU handles its own need_ext stall when ext_valid=0).
//
// Extension-word count rule (register-direct EA, current scope):
//   Group 0000, f_dir=0, f_mode=000 — ALL need ≥1 extension word:
//     f_dn=100 (bit ops imm):  1 ext word (bit number)
//     f_dn≠100, f_ss=10 (long):  2 ext words (32-bit immediate)
//     f_dn≠100, f_ss≠10 (byte/word): 1 ext word
//   All other supported groups: 0 ext words
//
// IFU ext_valid uses the q_cnt≥3 threshold from m68030_ifu.  This is
// conservative for 1-extension-word instructions (q_cnt≥2 would suffice),
// but is always correct: EU stalls on need_ext until ext_valid rises.

module m68030_seq (
    // From m68030_ifu
    input  logic [15:0] instr_word,       // q[0] — current opcode word
    input  logic [31:0] ifu_ext_data,     // {q[1],q[2]} — two extension words
    input  logic [15:0] ifu_q3_word,      // q[3] — third extension word
    input  logic [31:0] ifu_ext34_data,   // {q[3],q[4]} — words 3+4
    input  logic        instr_valid,      // IFU has ≥1 word (q_cnt ≥ 1)
    input  logic        ifu_ext_valid,    // IFU has ≥3 words (q_cnt ≥ 3)
    input  logic        ifu_ext4_valid,   // IFU has ≥4 words (q_cnt ≥ 4)
    input  logic        ifu_ext5_valid,   // IFU has ≥5 words (q_cnt ≥ 5)
    output logic [2:0]  drain,            // words to remove from IFU queue

    // To m68030_eu
    output logic [15:0] eu_instr_word,
    output logic [31:0] eu_ext_data,      // immediate in low bits (EU convention)
    output logic [15:0] eu_q3_word,       // q[3] pass-through for 3-ext instructions
    output logic [31:0] eu_ext34_data,    // {q[3],q[4]} for 4-ext instructions
    output logic        eu_instr_valid,
    output logic        eu_ext_valid,

    // From m68030_eu
    input  logic        eu_instr_ack,     // EU accepted instruction this cycle
    input  logic        eu_busy           // EU pipeline stalled (informational)
);

    // -----------------------------------------------------------------------
    // Pre-extract instruction fields
    // -----------------------------------------------------------------------
    logic [3:0] f_group;  assign f_group = instr_word[15:12];
    logic [2:0] f_dn;     assign f_dn    = instr_word[11:9];
    logic       f_dir;    assign f_dir   = instr_word[8];
    logic [1:0] f_ss;     assign f_ss    = instr_word[7:6];
    logic [2:0] f_mode;   assign f_mode  = instr_word[5:3];
    logic [2:0] f_reg;    assign f_reg   = instr_word[2:0];

    // -----------------------------------------------------------------------
    // Extension-word count (0, 1, or 2)
    // -----------------------------------------------------------------------
    // Group 0000, f_dir=0, Dn-direct EA: immediate ops need extension words
    logic is_imm_g0;
    assign is_imm_g0 = (f_group == 4'h0) && (!f_dir) && (f_mode == 3'b000);

    // Group 0101, f_ss=11, f_mode=001: DBcc Dn, d16 needs 1 extension word
    logic is_dbcc;
    assign is_dbcc = (f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b001);

    // Group 0110: BRA/Bcc/BSR: .W (disp8=0x00) needs 1 ext; .L (disp8=0xFF) needs 2
    logic [7:0] f_disp8_s;
    assign f_disp8_s = instr_word[7:0];
    logic is_branch_w, is_branch_l;
    assign is_branch_w = (f_group == 4'h6) && (f_disp8_s == 8'h00);
    assign is_branch_l = (f_group == 4'h6) && (f_disp8_s == 8'hFF);

    // Groups 1/2/3 (MOVE/MOVEA): (d16,An) src mode = f_mode=101; dst mode = {f_dir,f_ss}=101
    logic [2:0] f_move_dst_mode_s;
    assign f_move_dst_mode_s = {f_dir, f_ss};  // instr_word[8:6] for MOVE dst EA
    logic is_move_d16;
    assign is_move_d16 = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                         ((f_mode == 3'b101) || (f_move_dst_mode_s == 3'b101));

    // Group 4, LEA with (d16,An): f_dir=1, f_ss=11, f_mode=101
    logic is_lea_d16;
    assign is_lea_d16 = (f_group == 4'h4) && f_dir && (f_ss == 2'b11) && (f_mode == 3'b101);

    // Group 4, JSR/JMP with (d16,An): f_dir=0, f_dn=111, f_ss=10 or 11, f_mode=101
    logic is_jsr_jmp_d16;
    assign is_jsr_jmp_d16 = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                             (f_ss == 2'b10 || f_ss == 2'b11) && (f_mode == 3'b101);

    // Group 4, LINK.W: f_dir=0, f_dn=111, f_ss=01, f_mode=010 — needs 1 ext word (d16)
    logic is_link;
    assign is_link = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                     (f_ss == 2'b01) && (f_mode == 3'b010);

    // Phase 63: LINK.L — 2 ext words (32-bit displacement)
    logic is_link_l;
    assign is_link_l = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                       (f_ss == 2'b00) && (f_mode == 3'b001);

    // Phase 63: PACK/UNPK — 1 ext word (16-bit adj immediate)
    // Register form: f_mode=000; memory form: f_mode=001; both need 1 ext word
    logic is_pack_unpk;
    assign is_pack_unpk = (f_group == 4'h8) && f_dir &&
                          (f_ss == 2'b01 || f_ss == 2'b10) &&
                          (f_mode == 3'b000 || f_mode == 3'b001);

    // Phase 64: MOVES — 0000 1110 0ss mmm rrr (group 0, f_dir=0, f_dn=111, f_ss!=11)
    // Short EA (An)/(An)+/-(An): 1 ext word (MOVES descriptor only)
    // Long EA (d16,An)/(d8,An,Xn)/(xxx).W: 2 ext words (descriptor + EA extension)
    logic is_moves;
    assign is_moves = (f_group == 4'h0) && !f_dir && (f_dn == 3'b111) && (f_ss != 2'b11) &&
                      (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100);
    logic is_moves_long_ea;
    assign is_moves_long_ea = (f_group == 4'h0) && !f_dir && (f_dn == 3'b111) && (f_ss != 2'b11) &&
                              (f_mode == 3'b101 || f_mode == 3'b110 ||
                               (f_mode == 3'b111 && f_reg == 3'b000));

    // Phase 43: MOVEM — always exactly 1 extension word (the register mask)
    // Supported EA modes: -(An)(100), (An)+(011), (An)(010) — no extra displacement word.
    // MOVEM store: f_dn=100, !f_dir, f_ss[1]=1  MOVEM load: f_dn=110, !f_dir, f_ss[1]=1
    logic is_movem;
    assign is_movem = (f_group == 4'h4) && !f_dir && f_ss[1] &&
                      (f_dn == 3'b100 || f_dn == 3'b110) &&
                      (f_mode == 3'b100 || f_mode == 3'b011 || f_mode == 3'b010);

    // Phase 41: brief indexed EA (d8,An,Xn) — always 1 extension word
    logic is_move_idx_src;   // groups 1/2/3, src mode=110 (indexed)
    assign is_move_idx_src = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                             (f_mode == 3'b110);
    logic is_lea_idx;        // LEA (d8,An,Xn)
    assign is_lea_idx = (f_group == 4'h4) && f_dir && (f_ss == 2'b11) && (f_mode == 3'b110);
    logic is_jmp_idx;        // JMP (d8,An,Xn)
    assign is_jmp_idx = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                        (f_ss == 2'b11) && (f_mode == 3'b110);

    // Phase 40: absolute EA (xxx).W/(xxx).L
    // Phase 42: PC-relative (d16,PC) and (d8,PC,Xn) also use f_mode=111
    //   f_reg sub-type: 000=abs.W(1ext), 001=abs.L(2ext), 010=(d16,PC)(1ext), 011=(d8,PC,Xn)(1ext)
    logic is_move_abs_src;   // groups 1/2/3, f_mode=111 (any sub-type)
    assign is_move_abs_src = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                             (f_mode == 3'b111);
    // dst abs: groups 1/2/3, dst_mode=111, src=Dn/An (no PC-relative destination)
    logic is_move_abs_dst;
    assign is_move_abs_dst = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                             ({f_dir, f_ss} == 3'b111) &&
                             (f_mode == 3'b000 || f_mode == 3'b001);
    // LEA/JSR/JMP with f_mode=111 (covers abs.W/L and PC-relative)
    logic is_lea_abs;
    assign is_lea_abs = (f_group == 4'h4) && f_dir && (f_ss == 2'b11) && (f_mode == 3'b111);
    logic is_jsr_jmp_abs;
    assign is_jsr_jmp_abs = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                            (f_ss == 2'b10 || f_ss == 2'b11) && (f_mode == 3'b111);
    // abs.L (f_reg==001) needs 2 ext words; abs.W (f_reg==000) and PC-relative (010/011) need 1
    logic is_abs_long;
    assign is_abs_long = (is_move_abs_src  && (instr_word[2:0] == 3'b001)) ||
                         (is_move_abs_dst  && (f_dn == 3'b001))             ||
                         ((is_lea_abs || is_jsr_jmp_abs) && (instr_word[2:0] == 3'b001));
    logic is_abs_short;
    assign is_abs_short = (is_move_abs_src  && (instr_word[2:0] == 3'b000)) ||
                          (is_move_abs_dst  && (f_dn == 3'b000))              ||
                          ((is_lea_abs || is_jsr_jmp_abs) && (instr_word[2:0] == 3'b000));
    // PC-relative modes: (d16,PC)=010 and (d8,PC,Xn)=011 — always 1 ext word
    logic is_pc_rel;
    assign is_pc_rel = (is_move_abs_src || is_lea_abs || is_jsr_jmp_abs) &&
                       (instr_word[2:0] == 3'b010 || instr_word[2:0] == 3'b011);

    // Phase 60: Group 0 immediate ALU ops to (An)/(An)+/-(An)
    // ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm, ea  (f_dir=0, f_mode ∈ {010,011,100}, f_dn ∉ {100,111})
    logic is_imm_g0_mem;
    assign is_imm_g0_mem = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                           (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100) &&
                           (f_dn != 3'b100 && f_dn != 3'b111);

    // Phase 78: Group 0 imm ALU to (d16,An) or (xxx).W — 2 ext for byte/word, 3 for long
    logic is_imm_g0_d16_or_absw;
    assign is_imm_g0_d16_or_absw = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                                   (f_dn != 3'b100 && f_dn != 3'b111) &&
                                   (f_mode == 3'b101 ||
                                    (f_mode == 3'b111 && f_reg == 3'b000));

    // Phase 78: Group 0 imm ALU to (xxx).L — 3 ext for byte/word, 4 for long
    logic is_imm_g0_absl;
    assign is_imm_g0_absl = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                             (f_dn != 3'b100 && f_dn != 3'b111) &&
                             (f_mode == 3'b111 && f_reg == 3'b001);

    // Phase 57: ADDA/SUBA/CMPA #imm,An (groups 9/B/D, f_ss=11, f_mode=111, f_reg=100)
    logic is_adda_suba_cmpa_imm;
    assign is_adda_suba_cmpa_imm =
        (f_group == 4'h9 || f_group == 4'hb || f_group == 4'hd) &&
        (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b100);

    // Phase 57: ORI/ANDI/EORI #imm,CCR/SR (group 0, !f_dir, f_mode=111, f_reg=100)
    logic is_ori_andi_eori_sr;
    assign is_ori_andi_eori_sr =
        (f_group == 4'h0) && !f_dir && (f_mode == 3'b111) && (f_reg == 3'b100);

    // Phase 58: MULU.L/MULS.L/DIVU.L/DIVS.L — always 1 extension word
    logic is_muldivl;
    assign is_muldivl = (f_group == 4'h4) && (f_dn == 3'b110) && !f_dir &&
                        (f_ss == 2'b00 || f_ss == 2'b01) && (f_mode == 3'b000);

    // Phase 59: PEA — 1 ext word for (d16,An)/indexed/abs.W/PC-rel, 2 for abs.L
    logic is_pea;
    assign is_pea = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                    (f_ss == 2'b01) && (f_mode >= 3'b010);

    // Phase 59: RTD — exactly 1 extension word (displacement)
    logic is_rtd;
    assign is_rtd = (instr_word == 16'h4E74);

    // STOP — exactly 1 extension word (new SR immediate)
    logic is_stop_opcode;
    assign is_stop_opcode = (instr_word == 16'h4E72);

    // Phase 62: bit-field instructions — always exactly 1 extension word
    // Group E, f_ss=11 (bits[7:6]=11), f_dn[2]=1 (bit[11]=1)
    logic is_bf;
    assign is_bf = (f_group == 4'he) && (f_ss == 2'b11) && f_dn[2];

    // Phase 65: ALU memory-source forms (OR/SUB/CMP/AND/ADD + DIVU/DIVS/MULU/MULS from memory EA)
    // Groups 8/9/B/C/D with (d16,An), (xxx).W, (xxx).L, (d16,PC) — 1 or 2 extension words
    logic is_alu_mem_src;
    assign is_alu_mem_src =
        (f_group == 4'h8 || f_group == 4'h9 || f_group == 4'hb ||
         f_group == 4'hc || f_group == 4'hd) &&
        (f_mode == 3'b101 ||
         (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 || f_reg == 3'b010)));
    logic is_alu_mem_src_long;
    assign is_alu_mem_src_long = is_alu_mem_src && (f_mode == 3'b111) && (f_reg == 3'b001);

    // Phase 66: ADDQ/SUBQ #n, (d16,An) / (xxx).W / (xxx).L — 1 or 2 ext words
    logic is_addq_subq_ext;
    assign is_addq_subq_ext = (f_group == 4'h5) && (f_ss != 2'b11) &&
        (f_mode == 3'b101 || (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)));
    logic is_addq_subq_ext_long;
    assign is_addq_subq_ext_long = is_addq_subq_ext && (f_mode == 3'b111) && (f_reg == 3'b001);

    // PEA abs.L: f_mode=111, f_reg=001
    logic is_pea_abs_long;
    assign is_pea_abs_long = is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b001);

    // Phase 67: MOVE memory→memory — both src and dst are memory EA (not register)
    // Must appear before is_move_d16/is_abs_short in ext_count priority.
    logic is_move_mm;
    assign is_move_mm = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_move_dst_mode_s == 3'b010 || f_move_dst_mode_s == 3'b011 ||
         f_move_dst_mode_s == 3'b100 || f_move_dst_mode_s == 3'b101 ||
         f_move_dst_mode_s == 3'b111) &&
        (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
         f_mode == 3'b101 || f_mode == 3'b111);

    // Number of extension words needed by src EA and dst EA independently
    logic [1:0] move_mm_src_ext_w, move_mm_dst_ext_w;
    logic [2:0] move_mm_total_ext_w;  // sum; 3+ = unsupported (not decoded)
    always_comb begin
        if (f_mode == 3'b101 || (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010)))
            move_mm_src_ext_w = 2'd1;
        else if (f_mode == 3'b111 && f_reg == 3'b001)
            move_mm_src_ext_w = 2'd2;
        else if (f_mode == 3'b111 && f_reg == 3'b100)  // immediate: MOVE.L=2 words, .B/.W=1
            move_mm_src_ext_w = (f_group == 4'h2) ? 2'd2 : 2'd1;
        else
            move_mm_src_ext_w = 2'd0;
    end
    always_comb begin
        if (f_move_dst_mode_s == 3'b101 ||
            (f_move_dst_mode_s == 3'b111 && f_dn == 3'b000))
            move_mm_dst_ext_w = 2'd1;
        else if (f_move_dst_mode_s == 3'b111 && f_dn == 3'b001)
            move_mm_dst_ext_w = 2'd2;
        else
            move_mm_dst_ext_w = 2'd0;
    end
    assign move_mm_total_ext_w = {1'b0, move_mm_src_ext_w} + {1'b0, move_mm_dst_ext_w};

    logic [2:0] ext_count;
    always_comb begin
        if (is_imm_g0)
            ext_count = ((f_dn != 3'b100) && (f_ss == 2'b10)) ? 3'd2 : 3'd1;
        else if (is_imm_g0_absl)
            ext_count = (f_ss == 2'b10) ? 3'd4 : 3'd3;  // long: 2 imm + 2 addr; byte/word: 1 imm + 2 addr
        else if (is_imm_g0_d16_or_absw)
            ext_count = (f_ss == 2'b10) ? 3'd3 : 3'd2;  // long: 2 imm + 1 ea; byte/word: 1 imm + 1 ea
        else if (is_imm_g0_mem)
            ext_count = (f_ss == 2'b10) ? 3'd2 : 3'd1;  // long imm = 2 ext; byte/word = 1
        // Phase 67: move_mm before is_move_d16/is_abs_short so dual-ext combos get ext_count
        // For MOVE #imm, abs.W/abs.L: total_ext_w is 3 or 4; use separate signals for dst EA
        else if (is_move_mm && move_mm_total_ext_w >= 3'd4)
            ext_count = 3'd4;  // e.g. MOVE.L #imm32, abs.L: 2 imm + 2 addr = 4
        else if (is_move_mm && move_mm_total_ext_w == 3'd3)
            ext_count = 3'd3;  // e.g. MOVE.L #imm32, abs.W: 2 imm + 1 addr = 3
        else if (is_move_mm && move_mm_total_ext_w == 3'd2)
            ext_count = 3'd2;
        else if (is_move_mm && move_mm_total_ext_w == 3'd1)
            ext_count = 3'd1;
        // Phase 68: TRAPcc.L has 2-word operand
        else if ((f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b000))
            ext_count = 3'd2;
        // Phase 71: CAS2 always needs 2 extension words (Rn1/Dc1/Du1 + Rn2/Dc2/Du2)
        else if ((f_group == 4'h0) && !f_dir && (f_ss == 2'b11) &&
                 (f_dn == 3'b110 || f_dn == 3'b111) &&
                 (f_mode == 3'b111) && (f_reg == 3'b100))
            ext_count = 3'd2;
        // MOVE/MOVEA #imm, Dn/An — immediate src (f_mode=111,f_reg=100) with register dst
        // is_move_mm doesn't fire when dst_mode is 000 (Dn) or 001 (An direct)
        else if ((f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                 (f_mode == 3'b111) && (f_reg == 3'b100) &&
                 (f_move_dst_mode_s == 3'b000 || f_move_dst_mode_s == 3'b001))
            ext_count = (f_group == 4'h2) ? 3'd2 : 3'd1;
        // MOVE.W #imm, SR (0x46FC) / MOVE.W #imm, CCR (0x44FC) — group 4, 1 ext word
        else if (instr_word == 16'h46FC || instr_word == 16'h44FC)
            ext_count = 3'd1;
        // Phase 78: MOVE.W EA,SR/CCR with abs.L source — 2 extension words
        else if ((f_group == 4'h4) && !f_dir && (f_ss == 2'b11) &&
                 (f_dn == 3'b011 || f_dn == 3'b010) &&
                 (f_mode == 3'b111) && (f_reg == 3'b001))
            ext_count = 3'd2;
        // Phase 78: MOVE.W EA,SR/CCR with (d16,An)/(d8,An,Xn)/abs.W/(d16,PC)/(d8,PC,Xn) — 1 ext word
        else if ((f_group == 4'h4) && !f_dir && (f_ss == 2'b11) &&
                 (f_dn == 3'b011 || f_dn == 3'b010) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011))))
            ext_count = 3'd1;
        // Phase 78: MOVE #imm, (d8,An,Xn) — indexed dst, immediate src
        // MOVE.L: imm32=2 words + brief_ext=1 word = 3; MOVE.B/W: imm=1 + brief_ext=1 = 2
        else if ((f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                 (f_move_dst_mode_s == 3'b110) &&
                 (f_mode == 3'b111) && (f_reg == 3'b100))
            ext_count = (f_group == 4'h2) ? 3'd3 : 3'd2;
        // Phase 78: MOVE Dn/An, (d8,An,Xn) — indexed dst, register src (1 brief_ext)
        else if ((f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                 (f_move_dst_mode_s == 3'b110) &&
                 (f_mode == 3'b000 || f_mode == 3'b001))
            ext_count = 3'd1;
        else if (is_branch_l || is_abs_long || (is_adda_suba_cmpa_imm && f_dir) || is_pea_abs_long ||
                 is_link_l || is_moves_long_ea || is_alu_mem_src_long || is_addq_subq_ext_long)
            ext_count = 3'd2;
        else if (is_branch_w || is_dbcc || is_move_d16 || is_lea_d16 || is_jsr_jmp_d16 ||
                 is_link || is_abs_short || is_pc_rel ||
                 is_move_idx_src || is_lea_idx || is_jmp_idx || is_movem ||
                 is_adda_suba_cmpa_imm || is_ori_andi_eori_sr || is_muldivl ||
                 is_rtd || is_stop_opcode || is_bf || is_pack_unpk || is_moves ||
                 (is_alu_mem_src && !is_alu_mem_src_long) ||
                 (is_addq_subq_ext && !is_addq_subq_ext_long) ||
                 (is_pea && (f_mode == 3'b101)) ||   // (d16,An)
                 (is_pea && (f_mode == 3'b110)) ||   // (d8,An,Xn) indexed
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b000)) || // abs.W
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b010)) || // (d16,PC)
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b011)) || // (d8,PC,Xn)
                 // Phase 68: TRAPcc.W, CAS, BTST/BCHG/BCLR/BSET #n mem — all 1 ext word
                 ((f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b010)) ||
                 ((f_group == 4'h0) && !f_dir && (f_ss == 2'b11) &&
                  (f_dn == 3'b101 || f_dn == 3'b011 || f_dn == 3'b111) && (f_mode == 3'b010)) ||
                 ((f_group == 4'h0) && !f_dir && (f_dn == 3'b100) &&
                  (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)))
            ext_count = 3'd1;
        else
            ext_count = 2'd0;
    end

    // -----------------------------------------------------------------------
    // IFU drain: advance queue when EU accepts the instruction
    // -----------------------------------------------------------------------
    assign drain = eu_instr_ack ? (3'd1 + ext_count) : 3'd0;

    // -----------------------------------------------------------------------
    // EU ext_data format conversion
    //   ≥2-ext-word (long imm, BRA.L, move_mm with 2+ ext): full 32-bit unchanged
    //   1-ext-word (byte/word imm, bit#, BRA.W, DBcc d16): first ext word in [15:0]
    // EU reads: byte/word imm → ext_data[15:0]; long imm/BRA.L → ext_data[31:0]
    // For ext_count≥3 (MOVE.L #imm,abs.W/abs.L): ifu_ext_data = {q[1],q[2]} = 32-bit imm
    // -----------------------------------------------------------------------
    assign eu_ext_data = (ext_count >= 3'd2) ? ifu_ext_data
                                              : {16'h0, ifu_ext_data[31:16]};

    // -----------------------------------------------------------------------
    // ext_valid: ensure required words are present before EU dispatches
    // -----------------------------------------------------------------------
    assign eu_ext_valid = (ext_count >= 3'd4) ? ifu_ext5_valid :
                          (ext_count == 3'd3) ? ifu_ext4_valid :
                                                ifu_ext_valid;

    // -----------------------------------------------------------------------
    // Pass-through to EU
    // -----------------------------------------------------------------------
    assign eu_instr_word  = instr_word;
    assign eu_instr_valid = instr_valid;
    assign eu_q3_word     = ifu_q3_word;
    assign eu_ext34_data  = ifu_ext34_data;

endmodule

`default_nettype wire

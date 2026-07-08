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
    input  logic        instr_valid,      // IFU has ≥1 word (q_cnt ≥ 1)
    input  logic        ifu_ext_valid,    // IFU has ≥3 words (q_cnt ≥ 3)
    output logic [1:0]  drain,            // words to remove from IFU queue

    // To m68030_eu
    output logic [15:0] eu_instr_word,
    output logic [31:0] eu_ext_data,      // immediate in low bits (EU convention)
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

    // Phase 62: bit-field instructions — always exactly 1 extension word
    // Group E, f_ss=11 (bits[7:6]=11), f_dn[2]=1 (bit[11]=1)
    logic is_bf;
    assign is_bf = (f_group == 4'he) && (f_ss == 2'b11) && f_dn[2];

    // PEA abs.L: f_mode=111, f_reg=001
    logic is_pea_abs_long;
    assign is_pea_abs_long = is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b001);

    logic [1:0] ext_count;
    always_comb begin
        if (is_imm_g0)
            ext_count = ((f_dn != 3'b100) && (f_ss == 2'b10)) ? 2'd2 : 2'd1;
        else if (is_imm_g0_mem)
            ext_count = (f_ss == 2'b10) ? 2'd2 : 2'd1;  // long imm = 2 ext; byte/word = 1
        else if (is_branch_l || is_abs_long || (is_adda_suba_cmpa_imm && f_dir) || is_pea_abs_long)
            ext_count = 2'd2;
        else if (is_branch_w || is_dbcc || is_move_d16 || is_lea_d16 || is_jsr_jmp_d16 ||
                 is_link || is_abs_short || is_pc_rel ||
                 is_move_idx_src || is_lea_idx || is_jmp_idx || is_movem ||
                 is_adda_suba_cmpa_imm || is_ori_andi_eori_sr || is_muldivl ||
                 is_rtd || is_bf ||
                 (is_pea && (f_mode == 3'b101)) ||   // (d16,An)
                 (is_pea && (f_mode == 3'b110)) ||   // (d8,An,Xn) indexed
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b000)) || // abs.W
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b010)) || // (d16,PC)
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b011)))   // (d8,PC,Xn)
            ext_count = 2'd1;
        else
            ext_count = 2'd0;
    end

    // -----------------------------------------------------------------------
    // IFU drain: advance queue when EU accepts the instruction
    // -----------------------------------------------------------------------
    assign drain = eu_instr_ack ? (2'd1 + ext_count) : 2'd0;

    // -----------------------------------------------------------------------
    // EU ext_data format conversion
    //   2-ext-word (long imm, BRA.L): full 32-bit value unchanged
    //   1-ext-word (byte/word imm, bit#, BRA.W, DBcc d16): first ext word in [15:0]
    // EU reads: byte/word imm → ext_data[15:0]; long imm/BRA.L → ext_data[31:0]
    // -----------------------------------------------------------------------
    assign eu_ext_data = (ext_count == 2'd2) ? ifu_ext_data
                                              : {16'h0, ifu_ext_data[31:16]};

    // -----------------------------------------------------------------------
    // Pass-through to EU
    // -----------------------------------------------------------------------
    assign eu_instr_word  = instr_word;
    assign eu_instr_valid = instr_valid;
    assign eu_ext_valid   = ifu_ext_valid;

endmodule

`default_nettype wire

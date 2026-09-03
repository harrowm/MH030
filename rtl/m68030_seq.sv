`timescale 1ns/1ps
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
// IFU ext_valid uses the q_cnt≥3 threshold from m68030_ifu -- correct for
// 2-extension-word instructions. 1-extension-word instructions (the
// majority of memory-EA/short-immediate forms) instead use ext1_valid
// (q_cnt≥2, Phase 163 Stage 1, plan.md): since IFU fills always arrive 2
// words at a time, q_cnt jumps straight from 2 to 4, so gating a
// 1-ext-word instruction on q_cnt≥3 forced it to wait for an entire
// unneeded extra bus fetch before dispatch -- a real, measurable
// dispatch-overhead cost, not just a theoretical inefficiency.

module m68030_seq (
    // From m68030_ifu
    input  logic [15:0] instr_word,       // q[0] — current opcode word
    input  logic [31:0] ifu_ext_data,     // {q[1],q[2]} — two extension words
    input  logic [15:0] ifu_q3_word,      // q[3] — third extension word
    input  logic [31:0] ifu_ext34_data,   // {q[3],q[4]} — words 3+4
    input  logic [15:0] ifu_q5_word,      // q[5] — fifth extension word (Phase 145)
    input  logic [15:0] ifu_q6_word,      // q[6] — sixth extension word (10-item
                                           // backlog Stage 8, plan.md)
    input  logic        instr_valid,      // IFU has ≥1 word (q_cnt ≥ 1)
    input  logic        ifu_ext1_valid,   // IFU has ≥2 words (q_cnt ≥ 2, Phase 163 Stage 1)
    input  logic        ifu_ext_valid,    // IFU has ≥3 words (q_cnt ≥ 3)
    input  logic        ifu_ext4_valid,   // IFU has ≥4 words (q_cnt ≥ 4)
    input  logic        ifu_ext5_valid,   // IFU has ≥5 words (q_cnt ≥ 5)
    input  logic        ifu_ext6_valid,   // IFU has ≥6 words (q_cnt ≥ 6, Phase 145)
    input  logic        ifu_ext7_valid,   // IFU has ≥7 words (q_cnt ≥ 7, 10-item
                                           // backlog Stage 8)
    output logic [2:0]  drain,            // words to remove from IFU queue

    // To m68030_eu
    output logic [15:0] eu_instr_word,
    output logic [31:0] eu_ext_data,      // immediate in low bits (EU convention)
    output logic [15:0] eu_q3_word,       // q[3] pass-through for 3-ext instructions
    output logic [31:0] eu_ext34_data,    // {q[3],q[4]} for 4-ext instructions
    output logic [15:0] eu_q5_word,       // q[5] pass-through for 5-ext instructions
    output logic [15:0] eu_q6_word,       // q[6] pass-through for 6-ext instructions
    output logic        eu_instr_valid,
    output logic        eu_ext_valid,

    // From m68030_eu
    input  logic        eu_instr_ack,     // EU accepted instruction this cycle
    input  logic        eu_busy           // EU pipeline stalled (informational)
);

    // -----------------------------------------------------------------------
    // Pre-extract instruction fields
    // -----------------------------------------------------------------------
    // See rtl/opcode_fields.sv (ext_count de-duplication plan, plan.md,
    // Stage 2) -- the shared, single-source-of-truth primitive extraction
    // eu_seq.sv's own identical fields are also built from.
    logic [3:0] f_group;  assign f_group = opf_group(instr_word);
    logic [2:0] f_dn;     assign f_dn    = opf_dn(instr_word);
    logic       f_dir;    assign f_dir   = opf_dir(instr_word);
    logic [1:0] f_ss;     assign f_ss    = opf_ss(instr_word);
    logic [2:0] f_mode;   assign f_mode  = opf_mode(instr_word);
    logic [2:0] f_reg;    assign f_reg   = opf_reg(instr_word);

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

    // LINK.L — 2 ext words (32-bit displacement)
    logic is_link_l;
    assign is_link_l = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                       (f_ss == 2'b00) && (f_mode == 3'b001);

    // PACK/UNPK — 1 ext word (16-bit adj immediate)
    // Register form: f_mode=000; memory form: f_mode=001; both need 1 ext word
    logic is_pack_unpk;
    assign is_pack_unpk = (f_group == 4'h8) && f_dir &&
                          (f_ss == 2'b01 || f_ss == 2'b10) &&
                          (f_mode == 3'b000 || f_mode == 3'b001);

    // MOVES — 0000 1110 0ss mmm rrr (group 0, f_dir=0, f_dn=111, f_ss!=11)
    // Short EA (An)/(An)+/-(An): 1 ext word (MOVES descriptor only)
    // Long EA (d16,An)/(d8,An,Xn)/(xxx).W: 2 ext words (descriptor + EA extension)
    logic is_moves;
    assign is_moves = (f_group == 4'h0) && !f_dir && (f_dn == 3'b111) && (f_ss != 2'b11) &&
                      (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100);
    logic is_moves_long_ea;
    assign is_moves_long_ea = (f_group == 4'h0) && !f_dir && (f_dn == 3'b111) && (f_ss != 2'b11) &&
                              (f_mode == 3'b101 || f_mode == 3'b110 ||
                               (f_mode == 3'b111 && f_reg == 3'b000));

    // MOVEM — always exactly 1 extension word (the register mask)
    // Supported EA modes: -(An)(100), (An)+(011), (An)(010) — no extra displacement word.
    // MOVEM store: f_dn=100, !f_dir, f_ss[1]=1  MOVEM load: f_dn=110, !f_dir, f_ss[1]=1
    logic is_movem;
    assign is_movem = (f_group == 4'h4) && !f_dir && f_ss[1] &&
                      (f_dn == 3'b100 || f_dn == 3'b110) &&
                      (f_mode == 3'b100 || f_mode == 3'b011 || f_mode == 3'b010);

    // MOVEP: 0000 Dn 1 ss 001 An + d16 — exactly 1 extension word (displacement)
    // f_mode==001 is An-direct, only legal as the MOVEP EA mode in group 0 with f_dir=1
    logic is_movep;
    assign is_movep = (f_group == 4'h0) && f_dir && (f_mode == 3'b001);

    // MOVEM with extended EA: group 4, !f_dir, f_ss[1]=1, f_dn=100/110
    // 2-ext-word: (d16,An)/indexed/abs.W/(d16,PC)/(d8,PC,Xn)
    logic is_movem_2ext;
    assign is_movem_2ext = (f_group == 4'h4) && !f_dir && f_ss[1] &&
                           (f_dn == 3'b100 || f_dn == 3'b110) &&
                           (f_mode == 3'b101 || f_mode == 3'b110 ||
                            (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011)));
    // 3-ext-word: abs.L
    logic is_movem_3ext;
    assign is_movem_3ext = (f_group == 4'h4) && !f_dir && f_ss[1] &&
                           (f_dn == 3'b100 || f_dn == 3'b110) &&
                           (f_mode == 3'b111 && f_reg == 3'b001);

    // brief indexed EA (d8,An,Xn) — always 1 extension word
    logic is_move_idx_src;   // groups 1/2/3, src mode=110 (indexed)
    assign is_move_idx_src = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                             (f_mode == 3'b110);

    // Full-format extension word for mode=110 (peeked from ifu_ext_data[31:16],
    // the word right after the opcode -- q1 -- which ifu_ext_valid (q_cnt>=3)
    // already guarantees is stable by the time any ext_count value derived
    // from it can actually be dispatched on, via eu_ext_valid's own gating
    // below; see the comment on memind_ext_count for the full reasoning).
    // Bit positions match eu_seq.sv's fi_* extraction of the same word, just
    // offset by +16 since this file's ifu_ext_data has word1 in the high half
    // (opposite convention from eu_seq.sv's own ext_data — see this file's
    // header comment).
    // eaf_is_full/eaf_bdsz/eaf_iis: shared with eu_seq.sv's own fi_is_full/
    // fi_bdsz/fi_iis (rtl/opcode_fields.sv, ext_count de-duplication plan
    // Stage 3, plan.md) -- previously these exact bit positions (8/[5:4]/
    // [2:0]) were hand-copied 4 separate times across the two files.
    logic        peek_fi_full;  assign peek_fi_full = eaf_is_full(ifu_ext_data[31:16]); // bit8
    logic [1:0]  peek_fi_bdsz;  assign peek_fi_bdsz = eaf_bdsz(ifu_ext_data[31:16]);    // bits5:4
    logic [2:0]  peek_fi_iis;   assign peek_fi_iis  = eaf_iis(ifu_ext_data[31:16]);     // bits2:0

    // MOVE <ea>,dst with a mode=110 full-format source EA (memory-indirect,
    // or plain (bd,An,Xn) with a non-null bd) needs more than the 1
    // extension word every other mode=110 form (brief (d8,An,Xn), or a full
    // word with null bd/od) gets away with — one word per non-null
    // displacement (bd and, when genuinely indirect, od), on top of the
    // extension word itself. Previously hardcoded to 1 unconditionally
    // (is_move_idx_src's own bucket below), which silently dropped any bd/od
    // extension words for a non-null displacement, desyncing the IFU stream
    // into decoding whatever memory happened to follow as the next
    // instruction — found via a dedicated Musashi-cosim test
    // (tests/memind2.s) built for the memory-indirect EA investigation (see
    // plan.md Phase 107/115), not previously caught since Harte's corpus is
    // 68000-captured and has zero coverage of this 68020+-only mode.
    logic [2:0] memind_bd_words, memind_od_words, memind_ext_count;
    always_comb begin
        // eaf_disp_words: shared with movem_bd_words/movem_od_words/
        // q3bd_words below (rtl/opcode_fields.sv, ext_count
        // de-duplication plan Stage 4, plan.md).
        memind_bd_words = eaf_disp_words(peek_fi_bdsz);
        // od words only apply once genuine indirect action is selected
        // (iis != 000); iis[1:0] then gives the od size the same way bdsz
        // gives the bd size (01=null, 10=word, 11=long) -- the iis==000
        // case needs no separate guard, since iis[1:0]==00 whenever
        // iis==000 too, and eaf_disp_words already returns 0 for that.
        memind_od_words = eaf_disp_words(peek_fi_iis[1:0]);
        memind_ext_count = 3'd1 + memind_bd_words + memind_od_words;
    end

    // Stage 4 (plan.md Phase 119): MOVEM's own full-format mode=110 EA.
    // Unlike every other family in this rollout, MOVEM's baseline layout
    // already occupies BOTH ext words before any full-format concept
    // applies -- mask=q1 (ifu_ext_data[31:16]), EA descriptor=q2
    // (ifu_ext_data[15:0]) -- so the descriptor's own is_full/bdsz/iis bits
    // live at q2's position (bits [8]/[5:4]/[2:0] of the raw 32-bit
    // ifu_ext_data), not q1's (peek_fi_full/etc above read q1's bits,
    // correct for every single-EA-word family but wrong here -- reading
    // them for MOVEM would inspect the mask's own bits, not the
    // descriptor's). ext_count is additive on top of MOVEM's 2-word
    // baseline (mask + descriptor), not a wholesale override like
    // is_memind_full's, since that baseline is what non-null bd/od needs
    // *more than*, not a value to replace. Only the word-bd, non-indirect
    // sub-case (fi_iis==000, fi_bdsz==10) is actually decoded correctly
    // (eu_seq.sv's own MOVEM (d8,An,Xn) block, using q3_word for the bd
    // value); every other full-format sub-case (genuine indirect, long bd)
    // still degrades to the brief interpretation for dec_ea_offset, same
    // "least-wrong fallback" every other family in this rollout uses for
    // memory-indirect -- but movem_ext_count still accounts for their words
    // to avoid desyncing the IFU stream even where the resulting EA value
    // itself is wrong, mirroring memind_ext_count's own reasoning above.
    // Same shared eaf_* extraction as peek_fi_full/etc above (rtl/opcode_fields.sv).
    logic        peek_fi_full_movem;  assign peek_fi_full_movem = eaf_is_full(ifu_ext_data[15:0]);
    logic [1:0]  peek_fi_bdsz_movem;  assign peek_fi_bdsz_movem = eaf_bdsz(ifu_ext_data[15:0]);
    logic [2:0]  peek_fi_iis_movem;   assign peek_fi_iis_movem  = eaf_iis(ifu_ext_data[15:0]);
    logic [2:0] movem_bd_words, movem_od_words, movem_ext_count;
    always_comb begin
        movem_bd_words = eaf_disp_words(peek_fi_bdsz_movem);
        movem_od_words = eaf_disp_words(peek_fi_iis_movem[1:0]);
        movem_ext_count = 3'd2 + movem_bd_words + movem_od_words;
    end
    // is_movem itself only covers the -(An)/(An)+/(An) modes (f_mode ∈
    // {100,011,010}), not the indexed mode -- is_movem_2ext (declared
    // above, already includes f_mode==110 alongside (d16,An)/abs.W/(d16,PC)/
    // (d8,PC,Xn)) is the correct base condition to narrow down instead.
    logic is_movem_idx_full;
    assign is_movem_idx_full = is_movem_2ext && (f_mode == 3'b110) && peek_fi_full_movem;

    // Phase 120: CMP2/CHK2's own indexed form shares MOVEM's exact "q1=other
    // data, q2=EA descriptor" layout -- q1 here is the Rn/CHK2-flag word
    // (cmp2_ext_w in eu_seq.sv), not a register mask, but the bit-position
    // shape is identical (q2's own full/bdsz/iis bits, not q1's), so this
    // reuses peek_fi_full_movem/movem_bd_words/movem_od_words directly
    // rather than duplicating them -- baseline is additively 2 words (the
    // Rn descriptor + the EA descriptor), same as MOVEM's mask+descriptor.
    logic is_cmp2chk2_idx_full;
    assign is_cmp2chk2_idx_full = (f_group == 4'h0) && !f_dir && (f_ss == 2'b11) &&
                                  !f_dn[2] && (f_dn != 3'b011) && (f_mode == 3'b110) &&
                                  peek_fi_full_movem;
    logic [2:0] cmp2chk2_ext_count;
    assign cmp2chk2_ext_count = 3'd2 + movem_bd_words + movem_od_words;

    // Phase 122 (Sub-scope A, plan.md): MOVE mem-to-mem indexed-dst, for the
    // two source shapes with a *fixed* (not variable per sub-mode) 1-word
    // baseline -- abs.W src and (d16,PC) src. Both already have baseline 2
    // (src's own 1 word + dst's own brief descriptor), same MOVEM/CMP2CHK2
    // "q1=other data, q2=EA descriptor" shape (dst's own descriptor is
    // already naturally in ifu_ext_data's low half here, no swap needed,
    // since is_move_mm never joins mode110_ea_src) -- reuses
    // peek_fi_full_movem/movem_bd_words/movem_od_words directly. Register
    // src (Sub-scope A's 3rd tractable case) has a genuinely different,
    // 1-word baseline instead -- see is_move_reg_idx_dst_mode110 above,
    // which folds into the ordinary is_memind_full/fi_bd machinery unchanged
    // rather than needing this additive treatment. Imm/abs.L src (2-word
    // baseline, dst brief already at q3_word) and plain-memory src (baseline
    // varies 0-1 per sub-mode, entangling with this same q3 slot) are
    // deliberately out of scope this phase -- both would need a genuine q4,
    // matching the boundary Phase 121 already drew around long bd/od.
    logic is_move_mm_absw_idxdst_full, is_move_mm_pcrel_idxdst_full;
    assign is_move_mm_absw_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_mode == 3'b111) && (f_reg == 3'b000) &&
        (f_move_dst_mode_s == 3'b110) && peek_fi_full_movem;
    assign is_move_mm_pcrel_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_mode == 3'b111) && (f_reg == 3'b010) &&
        (f_move_dst_mode_s == 3'b110) && peek_fi_full_movem;
    logic [2:0] move_mm_idxdst_ext_count;
    assign move_mm_idxdst_ext_count = 3'd2 + movem_bd_words + movem_od_words;

    // Phase 141 (plan.md): MOVE #imm, indexed dst -- full-format bd.
    // MOVE.B/W's own baseline is imm16@q1 + descriptor@q2 -- the exact
    // same "q1=other data, q2=EA descriptor" shape as abs.W-src/(d16,PC)-
    // src just above, so directly reuses peek_fi_full_movem/
    // movem_bd_words/movem_od_words (both word AND long bd supported,
    // same as those two arms). This signal is MOVE.B/W only (word bd
    // suffices at this baseline, no q5 needed); MOVE.L's own baseline
    // is imm32@q1,q2 + descriptor@q3 -- one word further out, needing
    // its own peek at q3's own bits (is_move_mm_imml_idxdst_full,
    // below) -- word bd via q4, and (Phase 147, once q5 existed) long
    // bd too via q5. Genuine memory-indirect + any od remain the only
    // gap left for either arm.
    logic is_move_mm_immw_idxdst_full;
    assign is_move_mm_immw_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h3) &&   // MOVE.B/W, not .L
        (f_mode == 3'b111) && (f_reg == 3'b100) &&
        (f_move_dst_mode_s == 3'b110) && peek_fi_full_movem;
    logic [2:0] move_mm_immw_idxdst_ext_count;
    assign move_mm_immw_idxdst_ext_count = 3'd2 + movem_bd_words + movem_od_words;

    // Same shared eaf_* extraction as peek_fi_full/etc above (rtl/opcode_fields.sv).
    logic        peek_fi_full_q3;  assign peek_fi_full_q3 = eaf_is_full(ifu_q3_word);
    logic [1:0]  peek_fi_bdsz_q3;  assign peek_fi_bdsz_q3 = eaf_bdsz(ifu_q3_word);
    logic [2:0]  peek_fi_iis_q3;   assign peek_fi_iis_q3  = eaf_iis(ifu_q3_word);
    // Phase 147 (plan.md): bd word count for the "descriptor@q3, 3-word
    // baseline" shape (MOVE.L imm-src / abs.L-src) -- word bd needs 1 more
    // word (q4), long bd needs 2 more (q4+q5, unlocked by Phase 145's own
    // genuine q5), mirroring movem_bd_words' own additive shape. Shared by
    // both signals below since they have the identical baseline/descriptor
    // position.
    logic [2:0] q3bd_words;
    assign q3bd_words = eaf_disp_words(peek_fi_bdsz_q3);
    logic is_move_mm_imml_idxdst_full;
    assign is_move_mm_imml_idxdst_full =
        (f_group == 4'h2) &&                       // MOVE.L
        (f_mode == 3'b111) && (f_reg == 3'b100) &&
        (f_move_dst_mode_s == 3'b110) &&
        peek_fi_full_q3 && peek_fi_bdsz_q3[1] && (peek_fi_iis_q3 == 3'b000);
        // peek_fi_bdsz_q3[1]: 1 for word(10)/long(11), 0 for null(01)/rsvd(00)
        // -- null bd stays on the brief fallback path (offset 0 either way).
    logic [2:0] move_mm_imml_idxdst_ext_count;
    assign move_mm_imml_idxdst_ext_count = 3'd3 + q3bd_words;  // imm32(2)+descriptor(1)+bd

    // Phase 142/147 (plan.md): MOVE (xxx).L, indexed dst -- abs.L src's own
    // 2-word baseline (the address itself) pushes the dst descriptor to
    // q3_word, the exact same position MOVE.L imm-src already needed
    // peek_fi_full_q3/peek_fi_bdsz_q3/peek_fi_iis_q3/q3bd_words for --
    // reused directly, both word and long bd (Phase 147).
    logic is_move_mm_absl_idxdst_full;
    assign is_move_mm_absl_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_mode == 3'b111) && (f_reg == 3'b001) &&
        (f_move_dst_mode_s == 3'b110) &&
        peek_fi_full_q3 && peek_fi_bdsz_q3[1] && (peek_fi_iis_q3 == 3'b000);
    logic [2:0] move_mm_absl_idxdst_ext_count;
    assign move_mm_absl_idxdst_ext_count = 3'd3 + q3bd_words;  // abs.L(2)+descriptor(1)+bd

    // Phase 143 (plan.md): MOVE (An)/(An)+/-(An)/(d16,An), indexed dst --
    // full-format bd, the plain-memory-src arm. Non-(d16,An) src modes
    // have a 1-word baseline (the dst descriptor alone, at q1) -- the
    // exact shape every single-EA-word family uses, so directly reuses
    // peek_fi_full/peek_fi_bdsz/peek_fi_iis and memind_bd_words (without
    // memind_od_words -- this arm doesn't support od). (d16,An)-src has
    // a 2-word baseline instead (src's own d16 at q1, descriptor at q2) --
    // same "q1=other data, q2=descriptor" shape as abs.W-src/PC-rel-src/
    // MOVE.B/W's own imm-src, reusing peek_fi_full_movem/movem_bd_words
    // directly -- deferred-items closure plan Stage 8 (plan.md) added long
    // bd here too, the same peek position/mechanism already correctly
    // computing 2 words for it (movem_bd_words), just never previously
    // gated in or given its own value-extraction in eu_seq.sv.
    logic is_move_mm_plainsrc_idxdst_full;
    assign is_move_mm_plainsrc_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100) &&
        (f_move_dst_mode_s == 3'b110) &&
        peek_fi_full && (peek_fi_iis == 3'b000);
    logic [2:0] move_mm_plainsrc_idxdst_ext_count;
    assign move_mm_plainsrc_idxdst_ext_count = 3'd1 + memind_bd_words;

    // Deferred-items closure plan Stage 8 (plan.md): renamed from
    // is_move_mm_d16src_idxdst_wordbd (same convention as Phase 147's own
    // imml/absl renames) once long bd joined word bd here -- widened the
    // gate from bdsz==10 (word only) to bdsz[1] (word(10)/long(11), not
    // null(01)/rsvd(00), matching q3bd_words'/movem_bd_words' own
    // established convention elsewhere), and ext_count from a fixed 3 to
    // 2+movem_bd_words (word=3, long=4). movem_bd_words already computed
    // the correct word count for long bd here -- the gap was purely that
    // this arm's own gate/ext_count never used it, and eu_seq.sv's own
    // dec_dst_ea_offset never had a q4-based long-bd value extraction for
    // this specific (d16,An)-src sub-case (fixed alongside this).
    logic is_move_mm_d16src_idxdst_full;
    assign is_move_mm_d16src_idxdst_full =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_mode == 3'b101) &&
        (f_move_dst_mode_s == 3'b110) &&
        peek_fi_full_movem && peek_fi_bdsz_movem[1] && (peek_fi_iis_movem == 3'b000);
    logic [2:0] move_mm_d16src_idxdst_ext_count;
    assign move_mm_d16src_idxdst_ext_count = 3'd2 + movem_bd_words;

    // Stage 1 (plan.md Phase 116): the same brief-only-EA-decode gap Phase 115
    // fixed for MOVE also exists in every other f_mode==110 family's own
    // decode block in eu_seq.sv -- each hardcodes the brief (d8,An,Xn)
    // interpretation and never checks fi_is_full. This session's rollout
    // covers the "unary memory operand" group (An+Xn only, no third
    // register) mirroring Phase 81's own "Bucket A" grouping: TAS, NBCD,
    // NEGX/CLR/NEG/NOT/TST, and memory shift/rotate. Each family's own
    // baseline ext_count for mode=110 is exactly 1 (verified against each
    // of their own branches below), matching is_move_idx_src's own
    // baseline -- so extending is_memind_full's gate to include them lets
    // the existing override (ext_count = memind_ext_count) apply
    // correctly to all five with no other change needed here.
    logic is_tas_mode110, is_nbcd_mode110, is_negx_clr_neg_not_tst_mode110, is_shift_mode110;
    assign is_nbcd_mode110 = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                             (f_ss == 2'b00) && (f_mode == 3'b110);
    assign is_tas_mode110  = (f_group == 4'h4) && !f_dir && (f_dn == 3'b101) &&
                             (f_ss == 2'b11) && (f_mode == 3'b110);
    assign is_negx_clr_neg_not_tst_mode110 = (f_group == 4'h4) && !f_dir && (f_ss != 2'b11) &&
                             (f_dn == 3'b000 || f_dn == 3'b001 || f_dn == 3'b010 ||
                              f_dn == 3'b011 || f_dn == 3'b101) && (f_mode == 3'b110);
    assign is_shift_mode110 = (f_group == 4'he) && (f_ss == 2'b11) && !f_dn[2] && (f_mode == 3'b110);

    // Stage 2 (plan.md Phase 117): ALU-mem-src (ADD/SUB/CMP/AND/OR/EOR/ADDA/
    // SUBA/CMPA/MULU/MULS/DIVU/DIVS memory forms, both directions -- "Dn,ea"
    // RMW dest and "ea,Dn" source share the same f_mode/f_group encoding,
    // distinguished elsewhere by f_dir, so one flag covers both) and dynamic
    // BTST/BCHG/BCLR/BSET Dn,ea. is_alu_mem_src (declared further down in
    // this file; continuous assigns are declaration-order-independent) is
    // already exactly the right condition for the first group once narrowed
    // to f_mode==110 specifically -- it doesn't check f_dir at all, and its
    // own f_mode==110 baseline is already confirmed ext_count=1 via the
    // existing (is_alu_mem_src && !is_alu_mem_src_long) bucket (mode=110
    // can never be the abs.L case is_alu_mem_src_long checks for). Dynamic
    // bit-ops get their own new flag mirroring their existing (inline,
    // unnamed) ext_count condition, narrowed the same way. PC-relative
    // (d8,PC,Xn) forms for both families are deliberately not included here
    // (same boundary Stage 1 drew) -- their EA offset comes from a
    // differently-shaped dec_abs_ea_val computation, not dec_ea_offset,
    // needing separate handling not attempted this pass.
    // is_alu_mem_src itself is declared further down in this file; Icarus
    // does not support forward-referencing a continuous-assign net across
    // declaration order (unlike some other tools), so its own condition is
    // inlined here rather than referenced, narrowed to mode=110 directly.
    logic is_alu_mem_src_mode110, is_dyn_bit_mode110;
    assign is_alu_mem_src_mode110 =
        (f_group == 4'h8 || f_group == 4'h9 || f_group == 4'hb ||
         f_group == 4'hc || f_group == 4'hd) && (f_mode == 3'b110);
    assign is_dyn_bit_mode110 = (f_group == 4'h0) && f_dir && (f_mode == 3'b110);

    // Stage 3 (plan.md Phase 118): Scc, CHK, ADDQ/SUBQ, MOVE-to/from-SR/CCR,
    // and LEA/JMP/JSR/PEA indexed. All six eu_seq.sv sites share the same
    // An+Xn-only shape as Stage 1's unary-memory-operand family (CHK's own
    // dyn_bit_get_Dn deferred-register swap for the tested Dn is orthogonal,
    // same as it was for Stage 2's dynamic bit-ops) -- no new decode
    // machinery needed, only the fi_is_full/fi_bd template plus feeding
    // is_memind_full's gate. CMP2/CHK2's own indexed form was, at this
    // phase, a genuine missing-decode gap (no f_mode==110 case existed in
    // eu_seq.sv at all, brief or full -- unlike every other family here,
    // it had never been implemented, not just brief-limited), so it was
    // deliberately excluded here; implemented in Phase 120
    // (is_cmp2chk2_idx_full, below).
    // is_addq_subq_ext and is_pea are both declared later in this file;
    // Icarus's forward-reference limitation (see Stage 2's own comment on
    // is_alu_mem_src above) applies here too, so both conditions are
    // inlined rather than referenced, narrowed to mode=110 directly.
    logic is_chk_mode110, is_scc_mode110, is_move_sr_ccr_mode110, is_addq_subq_mode110;
    logic is_pea_mode110;
    assign is_chk_mode110 = (f_group == 4'h4) && f_dir &&
                            (f_ss == 2'b10 || f_ss == 2'b00) && (f_mode == 3'b110);
    assign is_scc_mode110 = (f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b110);
    assign is_move_sr_ccr_mode110 = (f_group == 4'h4) && !f_dir && (f_ss == 2'b11) &&
                            (f_dn == 3'b000 || f_dn == 3'b011 || f_dn == 3'b010) &&
                            (f_mode == 3'b110);
    assign is_addq_subq_mode110 = (f_group == 4'h5) && (f_ss != 2'b11) && (f_mode == 3'b110);
    assign is_pea_mode110 = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                            (f_ss == 2'b01) && (f_mode == 3'b110);
    logic is_lea_idx;        // LEA (d8,An,Xn)
    assign is_lea_idx = (f_group == 4'h4) && f_dir && (f_ss == 2'b11) && (f_mode == 3'b110);
    logic is_jmp_idx;        // JMP (d8,An,Xn)
    assign is_jmp_idx = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                        (f_ss == 2'b11) && (f_mode == 3'b110);
    logic is_jsr_idx;        // JSR (d8,An,Xn) -- same shape as is_jmp_idx, f_ss=10 not 11
    assign is_jsr_idx = (f_group == 4'h4) && !f_dir && (f_dn == 3'b111) &&
                        (f_ss == 2'b10) && (f_mode == 3'b110);

    // Phase 122 (Sub-scope A, plan.md): MOVE Dn/An,(d8,An,Xn) -- register
    // source, indexed dst. Unlike the other MOVE-mem-to-mem indexed-dst
    // arms (abs.W/PC-rel/imm/abs.L src, which already need 2+ baseline ext
    // words since the source itself occupies one), this arm's src is a
    // plain register -- zero extra src words -- so its own baseline is
    // exactly 1 (just the dst's own brief descriptor), identical in shape
    // to every single-EA-word family from Stages 1-3. Folds straight into
    // the existing mode110_ea_src/is_memind_full/fi_bd override machinery
    // unchanged, unlike every other MOVE-mem-to-mem arm which would need
    // MOVEM/CMP2CHK2-style additive q3_word arithmetic instead (deferred,
    // not attempted this phase -- see plan.md's own scope boundary).
    logic is_move_reg_idx_dst_mode110;
    assign is_move_reg_idx_dst_mode110 =
        (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_move_dst_mode_s == 3'b110) && (f_mode == 3'b000 || f_mode == 3'b001);

    logic mode110_ea_src;
    assign mode110_ea_src = is_move_idx_src || is_tas_mode110 || is_nbcd_mode110 ||
                            is_negx_clr_neg_not_tst_mode110 || is_shift_mode110 ||
                            is_alu_mem_src_mode110 || is_dyn_bit_mode110 ||
                            is_chk_mode110 || is_scc_mode110 || is_move_sr_ccr_mode110 ||
                            is_addq_subq_mode110 || is_lea_idx || is_jmp_idx || is_jsr_idx ||
                            is_move_reg_idx_dst_mode110 ||
                            is_pea_mode110;
    logic is_memind_full;
    assign is_memind_full = mode110_ea_src && peek_fi_full;

    // deferred-items closure follow-up (plan.md, "De-duplicate ext_count's
    // decode primitives against eu_seq.sv" Stage 1's own exhaustive
    // opcode-sweep overlap-detection testbench): MOVE (d8,An,Xn),<memory
    // dst> in full-format form. is_move_idx_src (folded into
    // mode110_ea_src/is_memind_full above) is correct for the "dst is
    // Dn/An" case (a plain indexed-src load into a register, is_move_mm
    // never fires there) but is_memind_full's own generic 1-word-plus-bd
    // formula is WRONG whenever the destination is ALSO memory
    // (f_move_dst_mode_s in {010,011,100,101}) -- that makes this a real
    // MOVE-mem-to-mem instruction, and eu_seq.sv's own dedicated decode
    // for exactly this shape (the `f_mode==3'b110` arm inside its own
    // "dst = memory (An)/(An)+/-(An)/(d16,An)" block) needs ext_count to
    // additionally include the destination's own extension word (0 for
    // dst in {010,011,100}, 1 more for dst==101/(d16,An_dst) -- matching
    // that decode block's own header comment, "ext_count depends on dst:
    // 1 for modes 2/3/4, 2 for mode 5"). Sweeping all 65,536 opcodes
    // found is_memind_full silently winning this case by priority
    // (checked first in the chain) and giving the SOURCE's own word
    // count alone, under-draining the IFU by the destination's own
    // extension word whenever dst==(d16,An) -- confirmed a genuine,
    // previously-undiscovered gap: Harte has zero full-format-extension-
    // word coverage (68000-captured corpus), and this project's own
    // memind test suite never happened to try an indexed SOURCE
    // specifically (every prior phase's own coverage has indexed as a
    // destination, or as a single-operand target for other instruction
    // families, never as MOVE's own mem-to-mem source). Scoped to
    // non-indirect full-format (fi_iis==000) only, matching the
    // established boundary the entire mode=110 EA rollout (Phases
    // 116-147) already drew for genuine memory-indirect -- see
    // eu_seq.sv's own matching fix for the EA-value side of this.
    logic is_move_idx_src_memdst_full;
    assign is_move_idx_src_memdst_full = is_move_idx_src && peek_fi_full &&
        (f_move_dst_mode_s == 3'b010 || f_move_dst_mode_s == 3'b011 ||
         f_move_dst_mode_s == 3'b100 || f_move_dst_mode_s == 3'b101);
    logic [2:0] move_idx_src_memdst_ext_count;
    assign move_idx_src_memdst_ext_count =
        3'd1 + memind_bd_words + ((f_move_dst_mode_s == 3'b101) ? 3'd1 : 3'd0);

    // absolute EA (xxx).W/(xxx).L
    // PC-relative (d16,PC) and (d8,PC,Xn) also use f_mode=111
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

    // Group 0 immediate ALU ops to (An)/(An)+/-(An)
    // ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm, ea  (f_dir=0, f_mode ∈ {010,011,100}, f_dn ∉ {100,111})
    logic is_imm_g0_mem;
    assign is_imm_g0_mem = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                           (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100) &&
                           (f_dn != 3'b100 && f_dn != 3'b111);

    // Group 0 imm ALU to (d16,An)/(xxx).W/(d16,PC)/(d8,PC,Xn) — 2 ext for byte/word, 3 for long
    logic is_imm_g0_d16_or_absw;
    assign is_imm_g0_d16_or_absw = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                                   (f_dn != 3'b100 && f_dn != 3'b111) &&
                                   (f_mode == 3'b101 || f_mode == 3'b110 ||
                                    (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011)));

    // Group 0 imm ALU to (xxx).L — 3 ext for byte/word, 4 for long
    logic is_imm_g0_absl;
    assign is_imm_g0_absl = (f_group == 4'h0) && !f_dir && (f_ss != 2'b11) &&
                             (f_dn != 3'b100 && f_dn != 3'b111) &&
                             (f_mode == 3'b111 && f_reg == 3'b001);

    // ADDA/SUBA/CMPA #imm,An (groups 9/B/D, f_ss=11, f_mode=111, f_reg=100)
    logic is_adda_suba_cmpa_imm;
    assign is_adda_suba_cmpa_imm =
        (f_group == 4'h9 || f_group == 4'hb || f_group == 4'hd) &&
        (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b100);

    // ORI/ANDI/EORI #imm,CCR/SR (group 0, !f_dir, f_mode=111, f_reg=100)
    logic is_ori_andi_eori_sr;
    assign is_ori_andi_eori_sr =
        (f_group == 4'h0) && !f_dir && (f_mode == 3'b111) && (f_reg == 3'b100);

    // MULU.L/MULS.L/DIVU.L/DIVS.L — always 1 extension word
    logic is_muldivl;
    assign is_muldivl = (f_group == 4'h4) && (f_dn == 3'b110) && !f_dir &&
                        (f_ss == 2'b00 || f_ss == 2'b01) && (f_mode == 3'b000);

    // MULU.L/MULS.L/DIVU.L/DIVS.L memory-EA forms (open-items backlog
    // Stage 7, plan.md): same signature as is_muldivl, just f_mode!=000
    // selecting a memory EA instead of Dn. The muldivl descriptor word
    // is always the first extension word (fixed position right after
    // the opcode, same "other data" shape as CMP2/CHK2 -- Phase
    // 119/120), so this is additive on is_muldivl's own baseline of 1,
    // not a replacement classifier. (An)/(An)+/-(An) need no further EA
    // word (baseline stays 1); (d16,An)/abs.W/(d16,PC) need 1 more (2
    // total); abs.L needs 2 more (3 total) -- indexed (d8,An,Xn)/
    // (d8,PC,Xn) and #imm forms deferred, not classified here.
    logic is_muldivl_mem;
    assign is_muldivl_mem = (f_group == 4'h4) && (f_dn == 3'b110) && !f_dir &&
                            (f_ss == 2'b00 || f_ss == 2'b01) &&
                            (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100);
    logic is_muldivl_2ext;
    assign is_muldivl_2ext = (f_group == 4'h4) && (f_dn == 3'b110) && !f_dir &&
                             (f_ss == 2'b00 || f_ss == 2'b01) &&
                             (f_mode == 3'b101 ||
                              (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010)));
    logic is_muldivl_3ext;
    assign is_muldivl_3ext = (f_group == 4'h4) && (f_dn == 3'b110) && !f_dir &&
                             (f_ss == 2'b00 || f_ss == 2'b01) &&
                             (f_mode == 3'b111) && (f_reg == 3'b001);

    // PEA — 1 ext word for (d16,An)/indexed/abs.W/PC-rel, 2 for abs.L
    logic is_pea;
    assign is_pea = (f_group == 4'h4) && !f_dir && (f_dn == 3'b100) &&
                    (f_ss == 2'b01) && (f_mode >= 3'b010);

    // cpSAVE/cpRESTORE (Phase 157 Stage 4) — same EA-field shape as PEA
    // (f_mode/f_reg at bits[5:0]), but F-line (f_group=4'hf), cpid=1
    // (f_dn=001), disambiguated from FPU/MOVE16 by TYPE={f_dir,f_ss}.
    // 0 ext words for An/predec/postinc, 1 for d16An/d8AnXn/absW/d16PC/
    // d8PCXn, 2 for abs.L — same table shape as is_pea's own below.
    logic is_cpsave, is_cprestore;
    assign is_cpsave    = (f_group == 4'hf) && (f_dn == 3'b001) &&
                           (f_dir == 1'b1) && (f_ss == 2'b00);   // {f_dir,f_ss}=100
    assign is_cprestore = (f_group == 4'hf) && (f_dn == 3'b001) &&
                           (f_dir == 1'b1) && (f_ss == 2'b01);   // {f_dir,f_ss}=101

    // RTD — exactly 1 extension word (displacement)
    logic is_rtd;
    assign is_rtd = (instr_word == 16'h4E74);

    // STOP — exactly 1 extension word (new SR immediate)
    logic is_stop_opcode;
    assign is_stop_opcode = (instr_word == 16'h4E72);

    // bit-field instructions — always exactly 1 extension word
    // Group E, f_ss=11 (bits[7:6]=11), f_dn[2]=1 (bit[11]=1)
    logic is_bf;
    assign is_bf = (f_group == 4'he) && (f_ss == 2'b11) && f_dn[2];

    // ALU memory-source forms (OR/SUB/CMP/AND/ADD + DIVU/DIVS/MULU/MULS from memory EA)
    // Groups 8/9/B/C/D with (d16,An), (xxx).W, (xxx).L, (d16,PC) — 1 or 2 extension words
    logic is_alu_mem_src;
    assign is_alu_mem_src =
        (f_group == 4'h8 || f_group == 4'h9 || f_group == 4'hb ||
         f_group == 4'hc || f_group == 4'hd) &&
        (f_mode == 3'b101 || f_mode == 3'b110 ||
         (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001 ||
                               f_reg == 3'b010 || f_reg == 3'b011)));
    logic is_alu_mem_src_long;
    assign is_alu_mem_src_long = is_alu_mem_src && (f_mode == 3'b111) && (f_reg == 3'b001);

    // OR/AND/CMP/ADD/SUB #imm, Dn (groups 8/9/B/C/D, !f_dir) — immediate to register
    // byte/word: 1 ext word; long: 2 ext words
    logic is_alu_imm_dn;
    assign is_alu_imm_dn =
        (f_group == 4'h8 || f_group == 4'h9 ||
         f_group == 4'hb || f_group == 4'hc || f_group == 4'hd) &&
        !f_dir && (f_ss != 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b100);

    // MULU/MULS/DIVU/DIVS #imm, Dn (groups 8/C, f_ss==11 is their own
    // size-independent signature) — always exactly 1 ext word (16-bit
    // immediate); is_alu_imm_dn above explicitly excludes f_ss==11.
    logic is_muldiv_imm;
    assign is_muldiv_imm =
        (f_group == 4'h8 || f_group == 4'hc) &&
        (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b100);

    // ADDQ/SUBQ #n, (d16,An) / (xxx).W / (xxx).L — 1 or 2 ext words
    logic is_addq_subq_ext;
    assign is_addq_subq_ext = (f_group == 4'h5) && (f_ss != 2'b11) &&
        (f_mode == 3'b101 || f_mode == 3'b110 ||
         (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b001)));
    logic is_addq_subq_ext_long;
    assign is_addq_subq_ext_long = is_addq_subq_ext && (f_mode == 3'b111) && (f_reg == 3'b001);

    // PEA abs.L: f_mode=111, f_reg=001
    logic is_pea_abs_long;
    assign is_pea_abs_long = is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b001);

    // MOVE memory→memory — both src and dst are memory EA (not register)
    // Must appear before is_move_d16/is_abs_short in ext_count priority.
    logic is_move_mm;
    assign is_move_mm = (f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
        (f_move_dst_mode_s == 3'b010 || f_move_dst_mode_s == 3'b011 ||
         f_move_dst_mode_s == 3'b100 || f_move_dst_mode_s == 3'b101 ||
         f_move_dst_mode_s == 3'b110 || f_move_dst_mode_s == 3'b111) &&
        (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100 ||
         f_mode == 3'b101 || f_mode == 3'b110 || f_mode == 3'b111);

    // Number of extension words needed by src EA and dst EA independently
    logic [1:0] move_mm_src_ext_w, move_mm_dst_ext_w;
    logic [2:0] move_mm_total_ext_w;  // sum; 3+ = unsupported (not decoded)
    always_comb begin
        if (f_mode == 3'b101 || f_mode == 3'b110 ||
            (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011)))
            move_mm_src_ext_w = 2'd1;
        else if (f_mode == 3'b111 && f_reg == 3'b001)
            move_mm_src_ext_w = 2'd2;
        else if (f_mode == 3'b111 && f_reg == 3'b100)  // immediate: MOVE.L=2 words, .B/.W=1
            move_mm_src_ext_w = (f_group == 4'h2) ? 2'd2 : 2'd1;
        else
            move_mm_src_ext_w = 2'd0;
    end
    always_comb begin
        if (f_move_dst_mode_s == 3'b101 || f_move_dst_mode_s == 3'b110 ||
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
        // Checked first, ahead of every family's own baseline branch below
        // (several of which -- NBCD/TAS/NEGX-etc/shift-rotate -- would
        // otherwise resolve ext_count on their own, earlier match, before
        // ever reaching is_memind_full's old position near the end of this
        // chain). See is_memind_full's own declaration above for why every
        // covered family's baseline is safely 1 word, matching what
        // memind_ext_count degrades to when the extension word turns out to
        // be brief or full-with-null-bd/od.
        // is_movem_idx_full checked ahead of is_memind_full too -- MOVEM is
        // deliberately not part of mode110_ea_src (its own 2-word baseline
        // needs additive, not override, arithmetic -- see its own
        // declaration above), so there's no overlap between the two, but
        // ordering it first keeps the "most specific match wins" convention
        // this whole chain already follows.
        if (is_movem_idx_full)
            ext_count = movem_ext_count;
        else if (is_cmp2chk2_idx_full)
            ext_count = cmp2chk2_ext_count;
        else if (is_move_mm_absw_idxdst_full || is_move_mm_pcrel_idxdst_full)
            ext_count = move_mm_idxdst_ext_count;
        else if (is_move_mm_immw_idxdst_full)
            ext_count = move_mm_immw_idxdst_ext_count;
        else if (is_move_mm_imml_idxdst_full)
            ext_count = move_mm_imml_idxdst_ext_count;
        else if (is_move_mm_absl_idxdst_full)
            ext_count = move_mm_absl_idxdst_ext_count;
        else if (is_move_mm_plainsrc_idxdst_full)
            ext_count = move_mm_plainsrc_idxdst_ext_count;
        else if (is_move_mm_d16src_idxdst_full)
            ext_count = move_mm_d16src_idxdst_ext_count;  // d16-src(1)+descriptor(1)+bd
        // Checked ahead of is_memind_full's own (otherwise-first) match below --
        // MOVE (d8,An,Xn),<memory dst> needs the destination's own extension
        // word counted too, which is_memind_full's generic source-only formula
        // doesn't know about. See is_move_idx_src_memdst_full's own declaration
        // above for the full derivation.
        else if (is_move_idx_src_memdst_full)
            ext_count = move_idx_src_memdst_ext_count;
        else if (is_memind_full)
            ext_count = memind_ext_count;
        else if (is_imm_g0)
            ext_count = ((f_dn != 3'b100) && (f_ss == 2'b10)) ? 3'd2 : 3'd1;
        else if (is_imm_g0_absl)
            ext_count = (f_ss == 2'b10) ? 3'd4 : 3'd3;  // long: 2 imm + 2 addr; byte/word: 1 imm + 2 addr
        else if (is_imm_g0_d16_or_absw)
            ext_count = (f_ss == 2'b10) ? 3'd3 : 3'd2;  // long: 2 imm + 1 ea; byte/word: 1 imm + 1 ea
        else if (is_imm_g0_mem)
            ext_count = (f_ss == 2'b10) ? 3'd2 : 3'd1;  // long imm = 2 ext; byte/word = 1
        // move_mm before is_move_d16/is_abs_short so dual-ext combos get ext_count
        // For MOVE #imm, abs.W/abs.L: total_ext_w is 3 or 4; use separate signals for dst EA
        else if (is_move_mm && move_mm_total_ext_w >= 3'd4)
            ext_count = 3'd4;  // e.g. MOVE.L #imm32, abs.L: 2 imm + 2 addr = 4
        else if (is_move_mm && move_mm_total_ext_w == 3'd3)
            ext_count = 3'd3;  // e.g. MOVE.L #imm32, abs.W: 2 imm + 1 addr = 3
        else if (is_move_mm && move_mm_total_ext_w == 3'd2)
            ext_count = 3'd2;
        else if (is_move_mm && move_mm_total_ext_w == 3'd1)
            ext_count = 3'd1;
        // Scc (xxx).w — 1 ext word (reg=000; NOT TRAPcc.L, see the reg=001/011
        // entry below for that — this priority slot used to mislabel reg=000
        // as "TRAPcc.L" and give it 2 ext words, corrupting the IFU stream)
        else if ((f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b000))
            ext_count = 3'd1;
        // CAS2 always needs 2 extension words (Rn1/Dc1/Du1 + Rn2/Dc2/Du2)
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
        // MOVE.W SR,EA abs.L dst / EA→SR/CCR abs.L src — 2 extension words
        else if ((f_group == 4'h4) && !f_dir && (f_ss == 2'b11) &&
                 (f_dn == 3'b000 || f_dn == 3'b011 || f_dn == 3'b010) &&
                 (f_mode == 3'b111) && (f_reg == 3'b001))
            ext_count = 3'd2;
        // MOVE.W SR,EA (d16,An)/(d8,An,Xn)/(xxx).W / EA→SR/CCR displacement/absW — 1 ext word
        else if ((f_group == 4'h4) && !f_dir && (f_ss == 2'b11) &&
                 (f_dn == 3'b000 || f_dn == 3'b011 || f_dn == 3'b010) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011))))
            ext_count = 3'd1;
        // MOVE #imm, (d8,An,Xn) — indexed dst, immediate src
        // MOVE.L: imm32=2 words + brief_ext=1 word = 3; MOVE.B/W: imm=1 + brief_ext=1 = 2
        else if ((f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                 (f_move_dst_mode_s == 3'b110) &&
                 (f_mode == 3'b111) && (f_reg == 3'b100))
            ext_count = (f_group == 4'h2) ? 3'd3 : 3'd2;
        // MOVE Dn/An, (d8,An,Xn) — indexed dst, register src (1 brief_ext)
        else if ((f_group == 4'h1 || f_group == 4'h2 || f_group == 4'h3) &&
                 (f_move_dst_mode_s == 3'b110) &&
                 (f_mode == 3'b000 || f_mode == 3'b001))
            ext_count = 3'd1;
        // static BTST/BCHG/BCLR/BSET #n with abs.L (bit_num word + 2 addr words)
        else if ((f_group == 4'h0) && !f_dir && (f_dn == 3'b100) &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd3;
        // static BTST/BCHG/BCLR/BSET #n with d16(An)/indexed/abs.W/(d16,PC)/(d8,PC,Xn)
        else if ((f_group == 4'h0) && !f_dir && (f_dn == 3'b100) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011))))
            ext_count = 3'd2;
        // dynamic BTST/BCHG/BCLR/BSET Dn with abs.L (2 addr words)
        else if ((f_group == 4'h0) && f_dir &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd2;
        // dynamic BTST/BCHG/BCLR/BSET Dn with d16(An)/indexed/abs.W/(d16,PC)/(d8,PC,Xn)/#imm
        else if ((f_group == 4'h0) && f_dir &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 ||
                                        f_reg == 3'b011 || f_reg == 3'b100))))
            ext_count = 3'd1;
        // Scc abs.L (reg=001) / TRAPcc.L (reg=011) — 2 ext words
        else if ((f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b111) &&
                 (f_reg == 3'b001 || f_reg == 3'b011))
            ext_count = 3'd2;
        // Scc (d16,An)/(d8,An,Xn) — 1 ext word
        else if ((f_group == 4'h5) && (f_ss == 2'b11) &&
                 (f_mode == 3'b101 || f_mode == 3'b110))
            ext_count = 3'd1;
        // NBCD abs.L — 2 ext words
        else if ((f_group == 4'h4) && !f_dir && (f_dn == 3'b100) && (f_ss == 2'b00) &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd2;
        // NBCD (d16,An)/(d8,An,Xn)/abs.W — 1 ext word
        else if ((f_group == 4'h4) && !f_dir && (f_dn == 3'b100) && (f_ss == 2'b00) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && f_reg == 3'b000)))
            ext_count = 3'd1;
        // TAS.B (d16,An)/(d8,An,Xn)/(xxx).W — 1 ext word
        else if ((f_group == 4'h4) && !f_dir && (f_dn == 3'b101) && (f_ss == 2'b11) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 || (f_mode == 3'b111 && f_reg == 3'b000)))
            ext_count = 3'd1;
        // TAS.B (xxx).L — 2 ext words
        else if ((f_group == 4'h4) && !f_dir && (f_dn == 3'b101) && (f_ss == 2'b11) &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd2;
        // NEGX/CLR/NEG/NOT/TST to (d16,An)/(d8,An,Xn)/(xxx).W/(d16,PC — TST only) — 1 ext word
        else if ((f_group == 4'h4) && !f_dir && (f_ss != 2'b11) &&
                 (f_dn == 3'b000 || f_dn == 3'b001 || f_dn == 3'b010 ||
                  f_dn == 3'b011 || f_dn == 3'b101) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 ||
                                        (f_dn == 3'b101 && f_reg == 3'b010)))))
            ext_count = 3'd1;
        // NEGX/CLR/NEG/NOT/TST to (xxx).L — 2 ext words
        else if ((f_group == 4'h4) && !f_dir && (f_ss != 2'b11) &&
                 (f_dn == 3'b000 || f_dn == 3'b001 || f_dn == 3'b010 ||
                  f_dn == 3'b011 || f_dn == 3'b101) &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd2;
        // memory shift/rotate (d16,An)/(d8,An,Xn)/(xxx).W — 1 ext word
        else if ((f_group == 4'he) && (f_ss == 2'b11) && !f_dn[2] &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && f_reg == 3'b000)))
            ext_count = 3'd1;
        // memory shift/rotate (xxx).L — 2 ext words
        else if ((f_group == 4'he) && (f_ss == 2'b11) && !f_dn[2] &&
                 (f_mode == 3'b111 && f_reg == 3'b001))
            ext_count = 3'd2;
        // CMP2/CHK2 (d16,An)/(d8,An,Xn) brief/(xxx).W/(d16,PC) — 2 ext words.
        // (d8,An,Xn) full-format is handled earlier in this chain by
        // is_cmp2chk2_idx_full (Phase 120) -- this bucket is its brief-form
        // fallback baseline, same relationship every other indexed family
        // in this rollout has with its own full-format override.
        else if ((f_group == 4'h0) && !f_dir && (f_ss == 2'b11) && !f_dn[2] && (f_dn != 3'b011) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010))))
            ext_count = 3'd2;
        // CMP2/CHK2 (An) — 1 ext word (register descriptor)
        else if ((f_group == 4'h0) && !f_dir && (f_ss == 2'b11) && !f_dn[2] && (f_dn != 3'b011) &&
                 (f_mode == 3'b010))
            ext_count = 3'd1;
        // CHK #imm, Dn — 1 ext word (word bound) or 2 (long bound)
        else if ((f_group == 4'h4) && f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                 (f_mode == 3'b111) && (f_reg == 3'b100))
            ext_count = (f_ss == 2'b10) ? 3'd1 : 3'd2;
        // CHK (xxx).L, Dn — 2 ext words
        else if ((f_group == 4'h4) && f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                 (f_mode == 3'b111) && (f_reg == 3'b001))
            ext_count = 3'd2;
        // CHK (d16,An)/(d8,An,Xn)/(xxx).W/(d16,PC)/(d8,PC,Xn), Dn — 1 ext word
        else if ((f_group == 4'h4) && f_dir && (f_ss == 2'b10 || f_ss == 2'b00) &&
                 (f_mode == 3'b101 || f_mode == 3'b110 ||
                  (f_mode == 3'b111 && (f_reg == 3'b000 || f_reg == 3'b010 || f_reg == 3'b011))))
            ext_count = 3'd1;
        else if (is_movem_3ext || is_muldivl_3ext)
            ext_count = 3'd3;
        else if (is_branch_l || is_abs_long || (is_adda_suba_cmpa_imm && f_dir) || is_pea_abs_long ||
                 is_link_l || is_moves_long_ea || is_alu_mem_src_long || is_addq_subq_ext_long ||
                 is_movem_2ext || (is_alu_imm_dn && f_ss == 2'b10) || is_muldivl_2ext ||
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b111) && (f_reg == 3'b001))) // abs.L
            ext_count = 3'd2;
        else if (is_branch_w || is_dbcc || is_move_d16 || is_lea_d16 || is_jsr_jmp_d16 ||
                 is_link || is_abs_short || is_pc_rel ||
                 is_move_idx_src || is_lea_idx || is_jmp_idx || is_jsr_idx || is_movem || is_movep ||
                 is_adda_suba_cmpa_imm || is_ori_andi_eori_sr || is_muldivl || is_muldivl_mem ||
                 is_rtd || is_stop_opcode || is_bf || is_pack_unpk || is_moves ||
                 (is_alu_mem_src && !is_alu_mem_src_long) ||
                 (is_addq_subq_ext && !is_addq_subq_ext_long) ||
                 (is_alu_imm_dn && f_ss != 2'b10) || is_muldiv_imm ||
                 (is_pea && (f_mode == 3'b101)) ||   // (d16,An)
                 (is_pea && (f_mode == 3'b110)) ||   // (d8,An,Xn) indexed
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b000)) || // abs.W
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b010)) || // (d16,PC)
                 (is_pea && (f_mode == 3'b111) && (instr_word[2:0] == 3'b011)) || // (d8,PC,Xn)
                 // cpSAVE/cpRESTORE: (d16,An)/(d8,An,Xn)/abs.W/(d16,PC)/(d8,PC,Xn) — 1 ext word
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b101)) ||
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b110)) ||
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b111) && (f_reg == 3'b000)) ||
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b111) && (f_reg == 3'b010)) ||
                 ((is_cpsave || is_cprestore) && (f_mode == 3'b111) && (f_reg == 3'b011)) ||
                 // TRAPcc.W (reg=010), CAS, BTST/BCHG/BCLR/BSET #n mem — all 1 ext word
                 // (Scc abs.W, reg=000, is handled earlier in the priority chain)
                 ((f_group == 4'h5) && (f_ss == 2'b11) && (f_mode == 3'b111) && (f_reg == 3'b010)) ||
                 ((f_group == 4'h0) && !f_dir && (f_ss == 2'b11) &&
                  (f_dn == 3'b101 || f_dn == 3'b011 || f_dn == 3'b111) && (f_mode == 3'b010)) ||
                 ((f_group == 4'h0) && !f_dir && (f_dn == 3'b100) &&
                  (f_mode == 3'b010 || f_mode == 3'b011 || f_mode == 3'b100)) ||
                 // MOVEC Rc,Rn (0x4E7A) / MOVEC Rn,Rc (0x4E7B) — 1 ext word
                 // (control-register selector + Rn). Never previously exercised
                 // through the IFU drain path (unit-tested directly in
                 // system_tb.sv, bypassing the prefetch queue) — no Harte suite
                 // exists for this 68010+-only instruction, so this gap went
                 // undetected until Phase 100 needed MOVEC in synthesized init
                 // code for VBR relocation.
                 (instr_word == 16'h4E7A || instr_word == 16'h4E7B))
            ext_count = 3'd1;
        // F-line MMU family (PFLUSH/PFLUSHA/PTEST/PMOVE/PLOAD), cpid=0
        // (f_group=4'hF, f_dn=3'b000, matching eu_seq.sv's own
        // "else if (f_dn == 3'b000) begin ... dec_needs_ext = 1'b1" gate
        // exactly) -- previously had NO entry anywhere in this chain,
        // silently falling through to the ext_count=0 default. mmu_op_type
        // (which distinguishes PFLUSH/PMOVE/PLOAD/PTEST from each other)
        // lives in ext_data[15:13], invisible to this opcode-only
        // classifier, so all four share one bucket unconditionally on
        // f_mode/f_reg -- matching eu_seq.sv's own dec_valid=1, which is
        // likewise set regardless of f_mode there.
        //
        // Found via the open-items backlog Stage 2 investigation
        // (plan.md): PFLUSH/PTEST/PMOVE's own existing test coverage
        // (biu_tb.sv/stall_fsm_tb.sv B-19/20/21) never caught this gap
        // because drain was silently short by exactly 1 word regardless,
        // leaving each op's own extension word undrained in the prefetch
        // queue to be misdecoded as the START of the next instruction --
        // but whether that produces a visible failure is entirely
        // data-dependent on what that extension word's own bit pattern
        // happens to decode as when reinterpreted as a fresh opcode.
        // PFLUSH's own ext word (mmu_op_type=001, giving a 0x2xxx-shaped
        // reinterpretation) and PTEST's (100, 0x8xxx-shaped) both happen
        // to decode as harmless register-only ALU ops in every existing
        // test, masking the bug; PLOAD's own ext word (011, giving a
        // 0x6xxx-shaped reinterpretation) decodes as BRA.W, taking a
        // wild, uncontrolled jump using the FOLLOWING word as its own
        // displacement -- reproduced directly (decode_pc landed exactly
        // at the hand-derived target, PC_after_BRA + displacement) before
        // this fix.
        else if ((f_group == 4'hf) && (f_dn == 3'b000))
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
    //
    // Full-format mode=110 EA (memind_full) is a *different* consumer of the
    // same >=2-ext-word case and needs a different layout: eu_seq.sv's own
    // fi_* extraction (fi_is_full/fi_bs/fi_is_s/fi_bdsz/fi_iis/fi_bd) always
    // reads the descriptor word from ext_data[15:0] and, when present, a
    // word-size bd from ext_data[31:16] — a convention that already matches
    // the plain (unswapped) 1-ext-word case above but is backwards for the
    // 2-ext-word case's default {q1,q2} layout (q1, the descriptor, would
    // land in the *high* half instead). Swapping q1/q2 here for this one
    // family keeps eu_seq.sv's existing extraction working unchanged rather
    // than needing a second, ext_count-aware copy of it there. Immediate
    // values (the other >=2-ext-word consumer) are unaffected since a given
    // instruction is never both.
    //
    // Phase 143 (plan.md): MOVE mem-to-mem's own plain-memory-src arm
    // ((An)/(An)+/-(An) src, indexed dst) has the *exact same* problem for
    // an entirely different reason -- its own 1-word baseline (dst
    // descriptor alone, at q1) is what is_memind_full's swap was built for,
    // but that swap is keyed on f_mode==110 (mode110_ea_src), which this
    // arm's own f_mode (010/011/100, the SOURCE's addressing mode) never
    // matches -- the descriptor here lives in a different field
    // (f_move_dst_mode_s==110) that mode110_ea_src was never meant to see.
    // Confirmed via a real hang: with the swap missing, decode read a
    // stale/wrong ext_data half once a real bd pushed ext_count to 2+,
    // corrupting the write address. Folding is_move_mm_plainsrc_idxdst_full
    // into the same swap condition fixes it via the exact same mechanism,
    // with zero new eu_seq.sv extraction code needed (dec_dst_ea_offset
    // already used the standard fi_is_full/fi_bd template). (d16,An)-src
    // is a *different* code shape (2-word baseline, q1=d16/q2=descriptor)
    // that was never affected -- its own dedicated q3_word-based extraction
    // in eu_seq.sv doesn't touch fi_is_full/fi_bd at all.
    //
    // Deferred-items closure follow-up (plan.md, ext_count de-duplication
    // Stage 1 sweep finding): is_move_idx_src_memdst_full's own dst==101
    // ((d16,An_dst)) sub-case is EXCLUDED from this swap, unlike every
    // other is_memind_full-triggering family. Reasoning: for dst in
    // {010,011,100} (this arm's own 1-word baseline), the swap correctly
    // relocates q1 (the source's own descriptor, naturally in
    // ifu_ext_data's HIGH half) into eu_ext_data's LOW half where
    // fi_is_full/fi_bd expect it -- genuinely needed whenever the source's
    // own bd pushes ext_count to 2+ (a null-bd, ext_count==1 case would
    // have landed q1 in the low half via the plain ext_count-based
    // fallback below anyway, but a word/long-bd case would NOT without
    // this swap). For dst==101 specifically, though, q2 is not spare
    // capacity for the source's own bd -- it's the DESTINATION's own d16
    // value, a genuinely different piece of data that must stay at a
    // fixed, known position regardless of the source's own bd size.
    // Swapping it into the high half (where dec_dst_ea_offset would then
    // need to chase it) buys nothing, since eu_seq.sv's own dst==101
    // branch (in its "dst = memory (An)/.../.../(d16,An)" block, the
    // f_mode==3'b110 arm) reads the source's own is_full/bdsz bits
    // directly from the natural, un-swapped high-half position instead
    // (mirroring m68030_seq.sv's own peek_fi_full/bdsz/iis convention
    // exactly) -- scoped to the null-bd sub-case for the source (the
    // common case); word/long bd at dst==101 specifically falls back to
    // treating q2 as the destination's own d16 regardless, the same
    // "least-wrong fallback, documented not fixed" boundary the rest of
    // this EA rollout (Phases 116-147) already established for combinations
    // genuinely needing a 4th extension word this arm doesn't have.
    // -----------------------------------------------------------------------
    assign eu_ext_data = ((is_memind_full && !(is_move_idx_src && f_move_dst_mode_s == 3'b101))
                          || is_move_mm_plainsrc_idxdst_full)
                        ? {ifu_ext_data[15:0], ifu_ext_data[31:16]}
                        : (ext_count >= 3'd2) ? ifu_ext_data
                                              : {16'h0, ifu_ext_data[31:16]};

    // -----------------------------------------------------------------------
    // ext_valid: ensure required words are present before EU dispatches
    // -----------------------------------------------------------------------
    assign eu_ext_valid = (ext_count >= 3'd6) ? ifu_ext7_valid :  // 10-item backlog Stage 8
                          (ext_count == 3'd5) ? ifu_ext6_valid :  // Phase 145
                          (ext_count == 3'd4) ? ifu_ext5_valid :
                          (ext_count == 3'd3) ? ifu_ext4_valid :
                          (ext_count == 3'd1) ? ifu_ext1_valid :  // Phase 163 Stage 1
                                                ifu_ext_valid;    // ext_count==2 (or 0, unused)

    // -----------------------------------------------------------------------
    // Pass-through to EU
    // -----------------------------------------------------------------------
    assign eu_instr_word  = instr_word;
    assign eu_instr_valid = instr_valid;
    assign eu_q3_word     = ifu_q3_word;
    assign eu_ext34_data  = ifu_ext34_data;
    assign eu_q5_word     = ifu_q5_word;
    assign eu_q6_word     = ifu_q6_word;

endmodule

`default_nettype wire

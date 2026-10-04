`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P instruction decoder -- combinational, registered by its consumer.
//
// SCOPE (plan P1/P2): the integer REGISTER-DIRECT core. Every opcode in the
// 65,536-entry space is classified, but only the register-direct forms are
// decoded into executable uops; everything else is reported honestly as
// UC_UNIMPL rather than silently mis-decoded. Later phases fill those in --
// the equivalence testbench (tb/uop_decode_equiv_tb.sv) only compares opcodes
// this decoder actually claims, so it stays meaningful as coverage grows.
//
// This is a genuine ID pipeline stage: its output is registered by
// mh030p_top, unlike rtl/eu_seq_decode.svh whose ~6,200-line single
// always_comb feeds the EX logic combinationally in the same tick. That
// difference is the entire point of the rewrite.
//
// Bit positions come from rtl/opcode_fields.sv, never hand-copied -- that
// file exists precisely because hand-copying them caused four documented bugs
// (Phase 96 Scc, Phase 150 MOVEC, Phase 161 BFCHG, Phase 216 F-line MMU).
//
// Icarus 13: constant bit-selects must live in `wire` assigns, not inside
// always_*; see mh030p_uop.svh's own toolchain notes.
// =============================================================================

module mh030p_decode (
    input  wire [15:0] instr,
    input  wire [31:0] ext,      // extension words, EU convention (see below)
    // The SAME two words WITHOUT the one-word normalisation `ext` carries.
    // Needed because the full-format check has to read a specific extension
    // word by POSITION, and `ext`'s layout depends on ext_words -- reading the
    // full-format bits from it would make ext_words depend on itself.
    // ext_raw and q3 are plain queue registers, so indexing them is free of
    // that circularity, and it is also what keeps mh030p_top's peek decoder out
    // of a combinational loop (see the note on `ext` in mh030p_ifu.sv).
    input  wire [31:0] ext_raw,
    input  wire [15:0] q3,       // third extension word
    output uop_t       uop,
    // Stage 1 scaffold only (plan.md "Full-format addendum profiled" /
    // "write the shallow decoder" session): the independent brief-format
    // ext_words, computed straight from raw opcode-bit wires rather than
    // from uop.*. Not read by mh030p_cpu.sv or mh030p_ifu.sv -- wired only
    // into tb/uop_decode_equiv_tb.sv (correctness oracle) and a dedicated
    // fmax probe (depth measurement) until it is verified and swapped in.
    output logic [2:0] ext_words_fast_o,
    // Stage 1, part 2: the brief leg above plus the full-format addendum,
    // i.e. the complete independent replacement for uop.ext_words. Same
    // scaffold status as ext_words_fast_o.
    output logic [2:0] ext_words_fast_full_o
);

    // ── Positional extension-word access, normalisation-free ────────────────
    // Word 0 and 1 come from ext_raw's two halves, word 2 from q3. No dependence
    // on ext_words, by construction.
    function automatic logic [15:0] rawword(input logic [2:0] i);
        case (i)
            3'd0:    rawword = ext_raw[31:16];
            3'd1:    rawword = ext_raw[15:0];
            default: rawword = q3;
        endcase
    endfunction

    // A 68020+ FULL-FORMAT extension word carries extra displacement words that
    // a brief-format one does not, and miscounting them does not produce a wrong
    // answer -- it derails the instruction stream. Layout:
    //   bit 8    1 = full format
    //   bit 6    IS  (index suppress)
    //   bits 5:4 base displacement size: 01 null, 10 word, 11 long
    //   bits 2:0 I/IS: 000 no memory indirect, x01 null od, x10 word, x11 long
    // Genuine MEMORY INDIRECTION -- I/IS (bits 2:0) nonzero. That needs a memory
    // read in the middle of address generation, which this core has no path for,
    // so it stays declined. I/IS == 000 is "no memory indirect": the EA is just
    // base + base-displacement + scaled index, which is ordinary arithmetic and is
    // implemented.
    function automatic logic ff_indirect(input logic [15:0] w);
        ff_indirect = (w[2:0] != 3'b000);
    endfunction

    // Base-displacement words alone (the od words belong to the indirect case).
    function automatic logic [2:0] ff_bd_words(input logic [15:0] w);
        ff_bd_words = (w[5:4] == 2'b10) ? 3'd1 : (w[5:4] == 2'b11) ? 3'd2 : 3'd0;
    endfunction

    function automatic logic [2:0] ff_extra(input logic [15:0] w);
        logic [2:0] bd, od;
        begin
            bd = (w[5:4] == 2'b10) ? 3'd1 : (w[5:4] == 2'b11) ? 3'd2 : 3'd0;
            od = (w[1:0] == 2'b10) ? 3'd1 : (w[1:0] == 2'b11) ? 3'd2 : 3'd0;
            ff_extra = bd + od;
        end
    endfunction

    // ── Opcode fields (hoisted; see header) ─────────────────────────────────
    wire [3:0] f_group = opf_group(instr);
    wire [2:0] f_dn    = opf_dn(instr);
    wire       f_dir   = opf_dir(instr);
    wire [1:0] f_ss    = opf_ss(instr);
    wire [2:0] f_mode  = opf_mode(instr);
    wire [2:0] f_reg   = opf_reg(instr);

    // Standard size field -> internal siz convention. MUST match eu_seq.sv's
    // own f_siz exactly: 00->byte(01), 01->word(10), 10->long(00).
    wire [1:0] f_siz = (f_ss == 2'b00) ? UZ_BYTE :
                       (f_ss == 2'b01) ? UZ_WORD : UZ_LONG;
    wire       f_ss_valid = (f_ss != 2'b11);   // 11 is not a size for these forms

    // MOVE's size lives in bits[13:12] with its own encoding (01=B,11=W,10=L).
    wire [1:0] f_movesz  = instr[13:12];
    wire [1:0] f_move_siz = (f_movesz == 2'b01) ? UZ_BYTE :
                            (f_movesz == 2'b11) ? UZ_WORD : UZ_LONG;

    // MOVE's destination mode/reg are swapped relative to the source.
    wire [2:0] f_dst_mode = instr[8:6];
    wire [2:0] f_dst_reg  = instr[11:9];

    wire [7:0] f_moveq_imm = instr[7:0];
    wire [3:0] f_cond      = instr[11:8];

    // ADDQ/SUBQ immediate: 0 means 8.
    wire [31:0] f_q_imm = (f_dn == 3'b000) ? 32'd8 : {29'h0, f_dn};

    // Register-direct predicates. mode 000 = Dn, 001 = An.
    wire src_is_dn = (f_mode == 3'b000);
    wire src_is_an = (f_mode == 3'b001);
    // An address register is a legal ALU SOURCE only for ADD (group D), SUB
    // (group 9) and CMP (group B), and never at byte size. OR (8) and AND (C)
    // do not accept one -- the reference decoder rejects those, and the sweep
    // said so in 256 opcodes when this was first written as "any group".
    wire alu_an_src_ok = src_is_an && (f_siz != UZ_BYTE)
                      && (f_group != 4'h8) && (f_group != 4'hC);
    wire dst_is_dn = (f_dst_mode == 3'b000);
    wire dst_is_an = (f_dst_mode == 3'b001);

    // Register-file numbering: 0-7 = D0-D7, 8-15 = A0-A7 (eu_regfile.sv).
    wire [3:0] rn_src_dn = {1'b0, f_reg};
    wire [3:0] rn_src_an = {1'b1, f_reg};
    wire [3:0] rn_dn     = {1'b0, f_dn};
    wire [3:0] rn_dst_dn = {1'b0, f_dst_reg};
    wire [3:0] rn_dst_an = {1'b1, f_dst_reg};

    // Group 0 immediate-ALU selector and its ALU op.
    // instr[8] MUST be excluded: group 0 with bit 8 set is the DYNAMIC bit
    // family (BTST/BCHG/BCLR/BSET Dn,<ea>), not an immediate ALU op. Missing
    // this was the first thing the equivalence sweep caught -- the old
    // decoder correctly reports unit=UU_BIT for 0x0100-0x01FF.
    wire g0_is_alu_imm = !instr[8]
                      && ((f_dn == 3'b000) || (f_dn == 3'b001) || (f_dn == 3'b010)
                       || (f_dn == 3'b011) || (f_dn == 3'b101) || (f_dn == 3'b110));
    wire [3:0] g0_alu_op = (f_dn == 3'b000) ? UA_OR  :
                           (f_dn == 3'b001) ? UA_AND :
                           (f_dn == 3'b010) ? UA_SUB :
                           (f_dn == 3'b011) ? UA_ADD :
                           (f_dn == 3'b101) ? UA_EOR : UA_CMP;

    // Group 4 single-operand selector (bits[11:8]).
    wire [3:0] g4_op = instr[11:8];
    // Hoisted out of the decode process: a constant bit-select inside an
    // always_* block is not fully supported by Icarus, which is why every
    // other field in this file is a wire assign too.
    wire [1:0] g4_op_hi = g4_op[2:1];
    wire g4_is_neg  = (g4_op == 4'h4);
    wire g4_is_not  = (g4_op == 4'h6);
    wire g4_is_clr  = (g4_op == 4'h2);
    wire g4_is_tst  = (g4_op == 4'hA);
    wire g4_is_negx = (g4_op == 4'h0);
    // EXT/EXTB are 0x48xx (g4_op == 8), NOT 0x44xx -- 0x44xx is NEG. An
    // earlier version had this as 4'h4 and swallowed the whole NEG family;
    // the equivalence sweep caught it at 0x4480 (NEG.L D0).
    // EXT.W (0x4880) and EXT.L (0x48C0) have g4_op == 8; EXTB.L (0x49C0) has
    // g4_op == 9, because its bits[8:6] = 111 sets bit 8 and bit 8 is part of
    // g4_op. Writing the EXTB.L case as (g4_op == 8 && sel == 111) is
    // therefore self-contradictory and silently never matches -- it was, until
    // this was spotted while fixing the unit below.
    wire [2:0] g4_ext_sel = instr[8:6];
    wire g4_is_ext = src_is_dn
                  && (((g4_op == 4'h8) && ((g4_ext_sel == 3'b010)
                                        || (g4_ext_sel == 3'b011)))
                   || ((g4_op == 4'h9) && (g4_ext_sel == 3'b111)));
    wire g4_is_swap = (instr[15:3] == 13'b0100_1000_0100_0);

    // Bit ops. Dynamic form is group 0 with bit 8 set (BTST/BCHG/BCLR/BSET
    // Dn,<ea>); static form is 0x08xx (f_dn == 100, bit 8 clear) taking the
    // bit number from an extension word. instr[7:6] selects the operation
    // with the same encoding eu_bitops.sv uses (00=TST,01=CHG,10=CLR,11=SET).
    wire [1:0] b_op       = instr[7:6];
    wire       g0_is_dynbit = instr[8];
    // ORI/ANDI/EORI to CCR (ss=00) or SR (ss=01): mode 111, reg 100.
    wire g0_is_ccr_sr = (f_group == 4'h0) && !instr[8]
                     && ((f_dn == 3'b000) || (f_dn == 3'b001) || (f_dn == 3'b101))
                     && (f_mode == 3'b111) && (f_reg == 3'b100)
                     && ((f_ss == 2'b00) || (f_ss == 2'b01));
    wire       g0_is_statbit = !instr[8] && (f_dn == 3'b100);

    // MULU/MULS (group C) and DIVU/DIVS (group 8), word forms: ss == 11.
    wire g_is_muldiv = ((f_group == 4'hC) || (f_group == 4'h8)) && (f_ss == 2'b11);
    // md_op encoding from rtl/eu_mul_div.sv: MUL_UW=0, MUL_SW=1, DIV_UW=4, DIV_SW=5.
    wire [3:0] g_md_op = (f_group == 4'hC) ? (f_dir ? 4'h1 : 4'h0)
                                           : (f_dir ? 4'h5 : 4'h4);

    // X-chained and BCD register forms. All share "bit 8 set, register EA":
    //   ABCD Dy,Dx = 1100 xxx1 0000 0yyy      SBCD Dy,Dx = 1000 xxx1 0000 0yyy
    //   ADDX Dy,Dx = 1101 xxx1 ss00 0yyy      SUBX Dy,Dx = 1001 xxx1 ss00 0yyy
    // bit 3 picks the -(An) memory form, which is not claimed here (P3).
    wire g_xform_reg = f_dir && (instr[5:4] == 2'b00) && !instr[3];
    // Same families with bit 3 SET are the -(Ay),-(Ax) memory forms.
    wire g_xform_mem = f_dir && (instr[5:4] == 2'b00) && instr[3];
    wire g_is_bcd_mem = g_xform_mem && (f_ss == 2'b00)
                     && ((f_group == 4'hC) || (f_group == 4'h8));
    wire g_is_x_mem   = g_xform_mem && f_ss_valid
                     && ((f_group == 4'hD) || (f_group == 4'h9));
    wire g_is_bcd_reg = g_xform_reg && (f_ss == 2'b00)
                     && ((f_group == 4'hC) || (f_group == 4'h8));
    wire g_is_x_reg   = g_xform_reg && f_ss_valid
                     && ((f_group == 4'hD) || (f_group == 4'h9));

    // EXG: group C, bit 8 set, instr[7:3] selects the register-pair flavour.
    wire [4:0] c_exg_sel = instr[7:3];
    wire g_is_exg = (f_group == 4'hC) && f_dir
                 && ((c_exg_sel == 5'b01000)    // EXG Dx,Dy
                  || (c_exg_sel == 5'b01001)    // EXG Ax,Ay
                  || (c_exg_sel == 5'b10001));  // EXG Dx,Ay

    // Group 5 with ss == 11 is Scc/DBcc rather than ADDQ/SUBQ.
    wire g5_is_cc   = (f_ss == 2'b11);
    wire g5_is_dbcc = g5_is_cc && (f_mode == 3'b001);
    wire g5_is_scc  = g5_is_cc && src_is_dn;

    // ── Effective address ───────────────────────────────────────────────────
    // mode/reg straight from the opcode; mode 111 sub-selects on reg.
    wire imm_is_long_pre = (f_ss == 2'b10);
    wire ea_m7 = (f_mode == 3'b111);
    wire [3:0] ea_mode_w =
        (f_mode == 3'b010) ? UEA_AN_IND  :
        (f_mode == 3'b011) ? UEA_AN_POST :
        (f_mode == 3'b100) ? UEA_AN_PRE  :
        (f_mode == 3'b101) ? UEA_AN_D16  :
        (f_mode == 3'b110) ? UEA_AN_IDX  :
        (ea_m7 && (f_reg == 3'b000)) ? UEA_ABS_W  :
        (ea_m7 && (f_reg == 3'b001)) ? UEA_ABS_L  :
        (ea_m7 && (f_reg == 3'b010)) ? UEA_PC_D16 :
        (ea_m7 && (f_reg == 3'b011)) ? UEA_PC_IDX : UEA_NONE;

    wire ea_is_imm = ea_m7 && (f_reg == 3'b100);

    // True when this instruction's own IMMEDIATE occupies eu_ext_data, so any
    // EA displacement has been pushed out to q3. Only the group 0 immediate
    // family is handled here; other families that can do this are not yet
    // claimed with a displacement.
    wire imm_takes_ext = (f_group == 4'h0) && !instr[8] && imm_is_long_pre;

    wire ea_is_mem = (ea_mode_w != UEA_NONE);
    wire ea_src_ok = ea_is_mem || ea_is_imm;

    // Extension-word fields. CRITICAL CONVENTION, verified in
    // rtl/m68030_seq.sv:1160-1164 rather than inferred:
    //
    //   ext_count == 1 -> eu_ext_data = {16'h0, word1}   (word1 in the LOW half)
    //   ext_count >= 2 -> eu_ext_data = {word1, word2}   (word1 in the HIGH half)
    //
    // So a SINGLE-extension-word mode -- (d16,An), (d8,An,Xn), abs.W, and the
    // register fields of MOVEC/BFEXTU -- reads from [15:0], NOT [31:16].
    // eu_seq.sv's own header describes the IFU's raw {q[1],q[2]} layout, which
    // is what the EU sees only for two-word forms; m68030_seq normalizes the
    // one-word case into the low half. An earlier version of this file read
    // every field from the high half and was silently wrong for every
    // one-word EA mode -- the equivalence sweep could not see it because it
    // did not compare these fields. It does now.
    // When the instruction carries a LONG immediate, that immediate consumes
    // eu_ext_data entirely and any EA displacement moves out to the third
    // extension word -- the reference does exactly this at
    // eu_seq_decode.svh:609. So the displacement source depends on what
    // precedes it, not on the EA mode alone.
    // (imm_is_long_pre is declared above, before first use)

    // Destination EA (MOVE only): the mode/reg fields are swapped relative
    // to the source, which is a documented source of confusion in this
    // codebase -- see feedback_read_write_field_roles_swapped.md.
    wire ea_dm7 = (f_dst_mode == 3'b111);
    wire [3:0] ea_dst_mode_w =
        (f_dst_mode == 3'b010) ? UEA_AN_IND  :
        (f_dst_mode == 3'b011) ? UEA_AN_POST :
        (f_dst_mode == 3'b100) ? UEA_AN_PRE  :
        (f_dst_mode == 3'b101) ? UEA_AN_D16  :
        (f_dst_mode == 3'b110) ? UEA_AN_IDX  :
        (ea_dm7 && (f_dst_reg == 3'b000)) ? UEA_ABS_W :
        (ea_dm7 && (f_dst_reg == 3'b001)) ? UEA_ABS_L : UEA_NONE;
    wire ea_dst_is_mem = (ea_dst_mode_w != UEA_NONE);

    // Extension-word accounting, enough to know whether a displacement's
    // position is unambiguous. This is a deliberate subset of
    // m68030_seq.sv's own ext_count chain, not a replacement for it.
    function automatic logic [2:0] ea_words(input logic [3:0] m);
        case (m)
            UEA_AN_D16, UEA_PC_D16, UEA_AN_IDX, UEA_PC_IDX, UEA_ABS_W: ea_words = 3'd1;
            UEA_ABS_L: ea_words = 3'd2;
            default:   ea_words = 3'd0;
        endcase
    endfunction
    wire [2:0] src_ea_words = ea_words(ea_mode_w);
    wire [2:0] dst_ea_words = ((f_group == 4'h1) || (f_group == 4'h2)
                            || (f_group == 4'h3)) ? ea_words(ea_dst_mode_w) : 3'd0;
    wire [2:0] imm_words    = ea_is_imm ? ((f_move_siz == UZ_LONG) ? 3'd2 : 3'd1)
                            : (imm_takes_ext ? 3'd2 : 3'd0);
    wire [2:0] ea_words_total = src_ea_words + dst_ea_words + imm_words;

    // Extension words are numbered from 0 in instruction order, and each side
    // of the instruction reads the one at its own offset: whatever an
    // immediate consumes comes first, then the SOURCE's own words, then the
    // DESTINATION's. Only indices 0-2 are reachable (ext carries two words,
    // q3 the third), which is what ea_disp_valid reports on.
    //
    // This replaces a narrower imm_takes_ext special case that could only
    // shift the SOURCE past a long immediate. It could not express a
    // displacement at each end, so MOVE.w (d16,A5),(d8,A0,Xn) read both
    // displacements out of the same half of `ext`.
    // The word count the FETCH UNIT normalises against is the decoded
    // uop.ext_words, not this raw-field sum, so it is passed in rather than
    // read here: several families report a count their own low six bits do not
    // imply, and every one of those was a real bug at some point.
    function automatic logic [15:0] xword(input logic [2:0] i,
                                          input logic [2:0] tot);
        case (i)
            3'd0:    xword = (tot <= 3'd1) ? ext[15:0] : ext[31:16];
            3'd1:    xword = ext[15:0];
            default: xword = q3;
        endcase
    endfunction

    // Control addressing modes (no Dn/An/(An)+/-(An)/#imm): what LEA, PEA,
    // JMP and JSR accept.
    wire ea_is_control = (ea_mode_w == UEA_AN_IND) || (ea_mode_w == UEA_AN_D16)
                      || (ea_mode_w == UEA_AN_IDX) || (ea_mode_w == UEA_ABS_W)
                      || (ea_mode_w == UEA_ABS_L)  || (ea_mode_w == UEA_PC_D16)
                      || (ea_mode_w == UEA_PC_IDX);
    // Alterable memory: everything writable, i.e. not PC-relative.
    wire ea_is_alt_mem = ea_is_mem && (ea_mode_w != UEA_PC_D16)
                                   && (ea_mode_w != UEA_PC_IDX);

    // Group 0 with ss == 11 is CMP2/CHK2 (f_dn 000/001/010 = B/W/L) or
    // CAS (f_dn 101/110/111 = B/W/L); ss != 11 with f_dn == 111 is MOVES.
    wire g0_ss11      = (f_group == 4'h0) && !instr[8] && (f_ss == 2'b11);
    // CMP2/CHK2 takes control modes only, and the reference's own set
    // (eu_seq_decode.svh:965) is narrower still: (An), (d16,An), (d8,An,Xn),
    // abs.W and (d16,PC) -- no abs.L and no PC-indexed. Matched exactly, for
    // the usual reason: an opcode the reference rejects cannot be validated.
    wire g0_is_cmp2   = g0_ss11 && (f_dn != 3'b011) && (f_dn[2] == 1'b0)
                     && ((ea_mode_w == UEA_AN_IND) || (ea_mode_w == UEA_AN_D16)
                      || (ea_mode_w == UEA_AN_IDX) || (ea_mode_w == UEA_ABS_W)
                      || (ea_mode_w == UEA_PC_D16));
    // CAS: the reference accepts control-ALTERABLE only -- no (An)+/-(An),
    // no PC-relative.
    // NOTE: f_dn==110 (CAS.W) is excluded because the reference decoder
    // rejects it while accepting CAS.B (101) and CAS.L (111). That looks like
    // another gap in rtl/ rather than an encoding subtlety -- recorded, not
    // claimed, since an opcode the reference rejects cannot be validated here.
    wire g0_is_cas    = g0_ss11 && (f_dn != 3'b110)
                     && (f_dn[2] == 1'b1) && (f_dn != 3'b100)
                     && (ea_mode_w == UEA_AN_IND);   // reference accepts (An) only
    // MOVES is claimed only for (An), the single-extension-word form. With a
    // displacement there are two extension words, so the direction bit and
    // the register field move to the other half -- the same ext_count
    // dependency ea_disp_valid exists for. Claiming those without the
    // ext_count chain would mean guessing at a convention.
    wire g0_is_moves  = (f_group == 4'h0) && !instr[8] && (f_dn == 3'b111)
                     && f_ss_valid && (ea_mode_w == UEA_AN_IND);

    // Group 4 sub-families, all keyed on g4_op (= instr[11:8]) plus [7:6].
    wire [1:0] g4_b76   = instr[7:6];
    wire g4_is_nbcd  = (g4_op == 4'h8) && (g4_b76 == 2'b00);
    wire g4_is_pea   = (g4_op == 4'h8) && (g4_b76 == 2'b01) && ea_is_control;
    wire g4_is_tas   = (g4_op == 4'hA) && (g4_b76 == 2'b11) && ea_is_alt_mem;
    // TAS Dn (register-direct): same g4_op/b76 as the memory form, but mode
    // 000 reads as src_is_dn, not a real EA, so ea_is_alt_mem is false for it
    // and the memory-form guard above never matches it. f_ss_valid is ALSO
    // false here (f_ss == g4_b76 == 11), so it doesn't fall into the generic
    // Dn-destination ALU fallback either -- previously decoded as nothing at
    // all (UC_UNIMPL), confirmed via a Harte vector ("TAS D0") where the
    // register came back completely untouched.
    wire g4_is_tas_dn = (g4_op == 4'hA) && (g4_b76 == 2'b11) && src_is_dn;
    // MOVEM shares 0x48xx/0x4Cxx with EXT/SWAP; bit 7 set plus a non-Dn EA
    // is what separates them (EXT/SWAP are mode 000, which MOVEM cannot use).
    wire g4_movem_to_mem = (g4_op == 4'h8);
    // The two directions accept DIFFERENT mode sets, which is easy to miss:
    //   regs->mem : control alterable plus -(An), but NOT (An)+
    //   mem->regs : control (incl. PC-relative) plus (An)+, but NOT -(An)
    // Treating them alike claimed 61 opcodes the reference calls illegal
    // (caught at 0x4898, MOVEM.W regs,(A0)+).
    wire movem_dst_ok = (ea_mode_w == UEA_AN_IND) || (ea_mode_w == UEA_AN_PRE)
                     || (ea_mode_w == UEA_AN_D16) || (ea_mode_w == UEA_AN_IDX)
                     || (ea_mode_w == UEA_ABS_W)  || (ea_mode_w == UEA_ABS_L);
    wire movem_src_ok = ea_is_control || (ea_mode_w == UEA_AN_POST);
    wire g4_is_movem = ((g4_op == 4'h8) || (g4_op == 4'hC)) && instr[7]
                     && (g4_movem_to_mem ? movem_dst_ok : movem_src_ok);
    wire g4_is_lea   = instr[8] && (g4_b76 == 2'b11) && ea_is_control
                     && (g4_op != 4'hE);
    wire g4_is_jsr   = (g4_op == 4'hE) && (g4_b76 == 2'b10) && ea_is_control;
    wire g4_is_jmp   = (g4_op == 4'hE) && (g4_b76 == 2'b11) && ea_is_control;

    // 0x4E40-0x4E7F: the system/control block.
    wire g4_is_sys   = (instr[15:6] == 10'b0100_1110_01);
    wire [3:0] sys_lo = instr[3:0];
    wire sys_is_trap = g4_is_sys && (instr[5:4] == 2'b00);
    wire sys_is_link = g4_is_sys && (instr[5:3] == 3'b010);
    wire sys_is_unlk = g4_is_sys && (instr[5:3] == 3'b011);
    wire sys_is_usp  = g4_is_sys && (instr[5:3] == 3'b100);  // MOVE An,USP
    wire sys_is_uspr = g4_is_sys && (instr[5:3] == 3'b101);  // MOVE USP,An
    wire sys_is_misc = g4_is_sys && (instr[5:3] == 3'b110);  // 0x4E70-0x4E77

    // ADDA/SUBA/CMPA: ss == 11 in groups D/9/B. bit 8 selects the OPERAND
    // size (0 = word, 1 = long); the write is always a full longword because
    // the destination is An, so the word form sign-extends -- same shape as
    // MOVEA.W.
    wire g_is_xxxa = (f_ss == 2'b11)
                  && ((f_group == 4'hD) || (f_group == 4'h9) || (f_group == 4'hB));
    wire g_xxxa_word = !f_dir;

    // CMPM (An)+,(An)+ : group B, dir=1, mode 001.
    wire g_is_cmpm = (f_group == 4'hB) && f_dir && (f_mode == 3'b001) && f_ss_valid;

    // CHK: group 4, bit 8 set, opmode 110 (word) or 100 (long).
    wire g4_is_chk = instr[8] && ((g4_b76 == 2'b10) || (g4_b76 == 2'b00))
                  && (ea_src_ok || src_is_dn) && (g4_op != 4'hE);

    // MOVE to/from SR/CCR: 0x40C0/0x42C0 (from) and 0x44C0/0x46C0 (to).
    wire g4_is_sr_move = (g4_b76 == 2'b11) && !instr[8]
                      && ((g4_op == 4'h0) || (g4_op == 4'h2)
                       || (g4_op == 4'h4) || (g4_op == 4'h6));
    wire g4_sr_to_ea = (g4_op == 4'h0) || (g4_op == 4'h2);

    // Bit-field ops: 1110 1ooo 11 mmm rrr, ooo = instr[10:8].
    //   000 BFTST 001 BFEXTU 010 BFCHG 011 BFEXTS
    //   100 BFCLR 101 BFFFO  110 BFSET 111 BFINS
    wire [2:0] bf_op    = instr[10:8];
    wire       g_is_bf  = (f_group == 4'hE) && instr[11] && (f_ss == 2'b11);
    // BFEXTU/BFEXTS/BFFFO write the Dn named by the extension word; the
    // mutating ops write back through the EA (Dn or memory).
    wire       bf_reads_dn = (bf_op == 3'b001) || (bf_op == 3'b011)
                          || (bf_op == 3'b101);
    wire       bf_mutates  = (bf_op == 3'b010) || (bf_op == 3'b100)
                          || (bf_op == 3'b110) || (bf_op == 3'b111);

    // TRAPcc: 0101 cccc 11 111 0xx, xx = 010 word / 011 long / 100 none.
    wire g5_is_trapcc = g5_is_cc && ea_m7
                     && ((f_reg == 3'b010) || (f_reg == 3'b011)
                      || (f_reg == 3'b100));

    // MOVEP: group 0, bit 8 set, mode 001. The An-direct mode is what
    // separates it from the dynamic bit ops, which cannot target An.
    wire g0_is_movep = (f_group == 4'h0) && instr[8] && (f_mode == 3'b001);

    // MOVEC: 0x4E7A (control->Rn) and 0x4E7B (Rn->control). The register is
    // named by the extension word, not the opcode.
    wire g4_is_movec = (instr[15:1] == 15'b0100_1110_0111_101);
    wire movec_to_reg = !instr[0];
    // ext[15:12], NOT ext[31:28]. MOVEC carries exactly one extension word, and
    // a single extension word arrives in the LOW half (m68030_seq.sv:1160) --
    // the reference reads ext_data[15:12] here for the same reason. This was
    // written the other way round, and left MOVEC unclaimed while the
    // convention was in doubt; the bit-field work settled it empirically, by
    // reading a register field out of [15:12] and executing correctly.
    // Bit 15 is the D/A select, [14:12] the number.
    wire [3:0] movec_rn = ext[15:12];

    // Group E shift/rotate. bits[4:3] select op, bit[8] direction,
    // bit[5] = count from register.
    wire [1:0] e_optype = instr[4:3];
    wire       e_left   = instr[8];
    wire       e_regcnt = instr[5];
    // Match rtl/eu_shifter.sv's SHF_* encoding.
    wire [3:0] e_shf_op = (e_optype == 2'b00) ? (e_left ? 4'h0 : 4'h1) : // ASL/ASR
                          (e_optype == 2'b01) ? (e_left ? 4'h2 : 4'h3) : // LSL/LSR
                          (e_optype == 2'b10) ? (e_left ? 4'h6 : 4'h7) : // ROXL/ROXR
                                                (e_left ? 4'h4 : 4'h5);  // ROL/ROR

    // The MEMORY shift form encodes its operation in instr[10:9], NOT in
    // instr[4:3] like the register form, and requires instr[11] == 0.
    // Reusing the register selector claimed 336 opcodes the reference
    // decoder correctly calls illegal (caught at 0xE8E2).
    wire [1:0] e_mem_optype = instr[10:9];
    wire       e_mem_legal  = !instr[11];
    wire [3:0] e_mem_shf_op = (e_mem_optype == 2'b00) ? (e_left ? 4'h0 : 4'h1) :
                              (e_mem_optype == 2'b01) ? (e_left ? 4'h2 : 4'h3) :
                              (e_mem_optype == 2'b10) ? (e_left ? 4'h6 : 4'h7) :
                                                        (e_left ? 4'h4 : 4'h5);

    // ── Shallow ext_words (Stage 1, measurement/equivalence scaffold) ────────
    // A from-scratch BRIEF-format word count, computed directly from the raw
    // per-group predicate wires above -- NEVER from uop.uclass/subop/siz/etc.
    // -- so its synthesis cone does not depend on the whole classification
    // decode below. See plan.md's "Full-format addendum profiled" session:
    // the measured 41.70 MHz / 24 ns ext_words cone is deep because the real
    // chain reads uop.* fields that are themselves outputs of the ~1000-line
    // case(f_group) classifier; this function reaches the same raw wires that
    // classifier reaches, in parallel with it, not serially after it.
    //
    // Mirrors the real decoder's if-elseif PRIORITY ORDER exactly, branch for
    // branch, because getting the ORDER wrong (not just the individual
    // conditions) changes the answer whenever two branches' guards overlap --
    // this is not a re-derivation, it is the same decisions, read from the
    // same wires, without round-tripping through uop.* first.
    //
    // The fallback for "nothing in this group's chain matched" (an
    // unclassified/illegal opcode, which stays UC_UNIMPL with ea_mode and
    // dst_ea_mode at their uop_clear() default of NONE) is deliberately
    // `imm_words + dst_ea_words`, NOT the full `ea_words_total` -- excluding
    // src_ea_words is what keeps an illegal opcode's own raw mode/reg bits
    // from being miscounted as a real address when nothing actually claims
    // them as one (see the real decoder's own "NONE/NONE" comment above the
    // equivalent check). Every ACCEPTED (classified) branch below uses the
    // full `ea_words_total` instead, verified case by case while writing this
    // that doing so agrees with the real decoder's own per-branch formula --
    // in every case checked, a branch that leaves ea_mode at its default NONE
    // also has a raw ea_mode_w of NONE (so src_ea_words is 0 and the two
    // formulas coincide), EXCEPT the explicit special cases called out below
    // (MOVEP, STOP, LINK, SYSCTL's USP forms, MOVEC) which are long-standing,
    // independently-verified special cases in the real chain already and are
    // reproduced here as the same flat constants.
    function automatic logic [2:0] ext_words_fast();
        logic [2:0] v;
        logic move_ok1, move_ok2;
        begin
            case (f_group)
            // ── group 0 ──────────────────────────────────────────────────
            4'h0: begin
                if (g0_is_ccr_sr)
                    v = ea_words(ea_mode_w) + (ea_is_imm ? 3'd1 : 3'd0);
                else if (g0_is_movep)
                    v = 3'd1;
                else if (g0_is_cmp2)
                    v = 3'd1 + ea_words(ea_mode_w);
                else if (g0_is_cas)
                    v = ea_is_imm ? 3'd2 : (3'd1 + ea_words(ea_mode_w));
                else if (g0_is_moves)
                    v = 3'd1 + ea_words(ea_mode_w);
                else if (g0_is_dynbit && ea_is_alt_mem)
                    v = ea_words(ea_mode_w);
                // BTST Dn,(d16/d8,PC,Xn) and BTST Dn,#imm: the one dynamic
                // bit op legal against PC-relative/immediate "memory" (read-
                // only), mirroring the two new decode branches above this
                // fast path has to agree with -- a stale mismatch here (this
                // function predicting 0 via the generic fallback below while
                // the real decoder below claims 1) fed the wrong half of
                // `ext` to the real decoder and wrecked the displacement.
                else if (g0_is_dynbit && (b_op == 2'b00)
                         && ((ea_mode_w == UEA_PC_D16)
                          || (ea_mode_w == UEA_PC_IDX)))
                    v = ea_words(ea_mode_w);
                else if (g0_is_dynbit && (b_op == 2'b00) && ea_is_imm)
                    v = 3'd1;
                // BTST #n,(d16/d8,PC,Xn): the static counterpart, one extra
                // word for the bit number on top of the EA's own.
                else if (g0_is_statbit && (b_op == 2'b00)
                         && ((ea_mode_w == UEA_PC_D16)
                          || (ea_mode_w == UEA_PC_IDX)))
                    v = 3'd1 + ea_words(ea_mode_w);
                else if (g0_is_statbit && ea_is_alt_mem)
                    v = 3'd1 + ea_words(ea_mode_w);
                else if ((g0_is_dynbit || g0_is_statbit) && src_is_dn)
                    v = (g0_is_statbit ? 3'd1 : 3'd0) + ea_words(ea_mode_w);
                else if (g0_is_alu_imm && ea_is_alt_mem && f_ss_valid)
                    v = ((f_siz == UZ_LONG) ? 3'd2 : 3'd1) + ea_words(ea_mode_w);
                else if (g0_is_alu_imm && src_is_dn && f_ss_valid)
                    v = (f_siz == UZ_LONG) ? 3'd2 : 3'd1;
                else
                    v = imm_words + dst_ea_words;
            end
            // ── MOVE / MOVEA ─────────────────────────────────────────────
            4'h1, 4'h2, 4'h3: begin
                move_ok1 = (ea_src_ok || ea_dst_is_mem)
                        && !((f_movesz == 2'b01) && (src_is_an || dst_is_an))
                        && (ea_src_ok || src_is_dn || src_is_an)
                        && (ea_dst_is_mem || dst_is_dn || dst_is_an);
                move_ok2 = (src_is_dn || src_is_an) && (dst_is_dn || dst_is_an)
                        && !((f_movesz == 2'b01) && (src_is_an || dst_is_an));
                v = (move_ok1 || move_ok2) ? ea_words_total
                                            : (imm_words + dst_ea_words);
            end
            // ── NEG/NEGX/NOT/CLR/TST/EXT/SWAP/TAS/NBCD/CHK/MOVEM/... ─────
            4'h4: begin
                if (ea_is_alt_mem && f_ss_valid
                    && (g4_is_neg || g4_is_not || g4_is_clr
                     || g4_is_tst || g4_is_negx))
                    v = ea_words_total;
                else if (g4_is_chk)
                    v = ea_is_imm ? ((g4_b76 == 2'b00) ? 3'd2 : 3'd1)
                                  : ea_words(ea_mode_w);
                else if (g4_is_sr_move && (ea_is_alt_mem || src_is_dn
                                           || (!g4_sr_to_ea && ea_src_ok)))
                    v = ea_words(ea_mode_w) + (ea_is_imm ? 3'd1 : 3'd0);
                else if (g4_is_nbcd)
                    v = (src_is_dn || ea_is_alt_mem) ? ea_words_total
                                                      : (imm_words + dst_ea_words);
                else if (g4_is_tas)
                    v = ea_words_total;
                else if (g4_is_pea)
                    v = ea_words_total;
                else if (g4_is_lea)
                    v = ea_words_total;
                else if (g4_is_movem)
                    v = 3'd1 + ea_words(ea_mode_w);
                else if (g4_is_jsr || g4_is_jmp)
                    v = ea_words_total;
                else if (sys_is_trap)
                    v = 3'd0;
                else if (sys_is_link || sys_is_unlk)
                    v = sys_is_link ? 3'd1 : 3'd0;
                else if (sys_is_usp || sys_is_uspr)
                    v = 3'd0;
                else if (g4_is_movec)
                    v = 3'd1;
                else if (sys_is_misc)
                    // RESET/NOP/RTD/RETURN/TRAPV all 0; STOP (sys_lo==2) is
                    // the one with a real operand word.
                    v = (sys_lo == 4'h2) ? 3'd1 : 3'd0;
                else if (g4_is_swap)
                    v = 3'd0;
                else if (g4_is_ext)
                    v = 3'd0;
                else if (src_is_dn && f_ss_valid
                         && (g4_is_neg || g4_is_not || g4_is_clr
                          || g4_is_tst || g4_is_negx))
                    v = 3'd0;
                else
                    v = imm_words + dst_ea_words;
            end
            // ── ADDQ/SUBQ/Scc/DBcc/TRAPcc ────────────────────────────────
            4'h5: begin
                if (g5_is_trapcc)
                    v = (f_reg == 3'b010) ? 3'd1 : (f_reg == 3'b011) ? 3'd2 : 3'd0;
                else if (g5_is_scc)
                    v = 3'd0;
                else if (g5_is_cc && ea_is_alt_mem)
                    v = ea_words_total;
                else if (g5_is_dbcc)
                    v = 3'd1;
                else if (ea_is_alt_mem && f_ss_valid)
                    v = ea_words_total;
                else if (src_is_an && (f_siz != UZ_BYTE))
                    v = 3'd0;
                else if (src_is_dn && f_ss_valid)
                    v = 3'd0;
                else
                    v = imm_words + dst_ea_words;
            end
            // ── F-line ────────────────────────────────────────────────────
            4'hF: v = ((instr[11:9] == 3'b000) || (instr[11:9] == 3'b001))
                      ? 3'd1 : 3'd0;
            // ── A-line ────────────────────────────────────────────────────
            4'hA: v = 3'd0;
            // ── Bcc/BRA/BSR ───────────────────────────────────────────────
            4'h6: v = (instr[7:0] == 8'h00) ? 3'd1 :
                      (instr[7:0] == 8'hFF) ? 3'd2 : 3'd0;
            // ── MOVEQ ─────────────────────────────────────────────────────
            4'h7: v = !instr[8] ? 3'd0 : (imm_words + dst_ea_words);
            // ── OR/SUB/CMP+EOR/AND/ADD, register-direct ──────────────────
            4'h8, 4'h9, 4'hB, 4'hC, 4'hD: begin
                if (g_is_bcd_reg)
                    v = ea_words_total;
                else if (g_is_x_reg)
                    v = ea_words_total;
                else if (g_is_bcd_mem || g_is_x_mem)
                    v = ea_words_total;
                else if (g_is_exg)
                    v = ea_words_total;
                else if (g_is_muldiv && (src_is_dn || ea_src_ok))
                    v = ea_is_imm ? 3'd1 : ea_words_total;
                else if (g_is_xxxa && (ea_src_ok || src_is_dn || src_is_an))
                    v = ea_is_imm ? (g_xxxa_word ? 3'd1 : 3'd2) : ea_words_total;
                else if (g_is_cmpm)
                    v = ea_words_total;
                else if (f_dir && ea_is_alt_mem && f_ss_valid)
                    v = ea_words_total;
                else if ((ea_src_ok || alu_an_src_ok) && !f_dir && f_ss_valid)
                    v = ea_is_imm ? ((f_siz == UZ_LONG) ? 3'd2 : 3'd1)
                                  : ea_words_total;
                else if (src_is_dn && f_ss_valid && ((f_group == 4'hB) || !f_dir))
                    v = ea_words_total;
                else
                    v = imm_words + dst_ea_words;
            end
            // ── Shifts/rotates, register form, and bit-fields ────────────
            4'hE: begin
                if (g_is_bf && (src_is_dn || (ea_mode_w == UEA_AN_IND)
                                          || (ea_mode_w == UEA_AN_D16)
                                          || (ea_mode_w == UEA_ABS_W)
                                          || (ea_mode_w == UEA_PC_D16)))
                    v = 3'd1 + ea_words(ea_mode_w);
                else if (ea_is_alt_mem && (f_ss == 2'b11) && e_mem_legal)
                    v = ea_words(ea_mode_w);
                else if (f_ss_valid)
                    v = 3'd0;
                else
                    v = imm_words + dst_ea_words;
            end
            default: v = imm_words + dst_ea_words;
            endcase
            ext_words_fast = v;
        end
    endfunction

    // A plain `assign` here mis-tracks sensitivity in Icarus: ext_words_fast()
    // reads module-scope wires directly rather than through its own
    // (zero) argument list, and an `assign`-driven function call does not
    // reliably re-evaluate when those wires change (confirmed via a minimal
    // repro: `assign y = f()` held its first value forever while `always_comb
    // y = f()` updated correctly). always_comb's own sensitivity analysis
    // does not have this gap.
    always_comb ext_words_fast_o = ext_words_fast();

    // ── Shallow full-format addendum (Stage 1, part 2) ───────────────────────
    // Same idea as ext_words_fast() above, extended to the full-format extra
    // words: computed from raw wires only, never from uop.ea_mode/
    // uop.dst_ea_mode, so it stays parallel with the classifier instead of
    // serial after it.
    //
    // The real decoder's src_ff/dst_ff check (further below, in the real
    // decode block) tests uop.ea_mode/uop.dst_ea_mode -- the EFFECTIVE,
    // possibly-overridden EA mode -- not the raw ea_mode_w/ea_dst_mode_w.
    // These two are equal for essentially every family (confirmed case by
    // case while writing ext_words_fast() above: every branch that uses a
    // real EA sets uop.ea_mode = ea_mode_w directly). The one family where
    // they genuinely diverge is MOVE: when the source needs no address of
    // its own (register or immediate), the EA slot holds the DESTINATION's
    // raw field instead (`ea_slot_is_dst` in the real decode block), and a
    // genuine memory-to-memory MOVE additionally has a real
    // uop.dst_ea_mode = ea_dst_mode_w, which no other family ever sets to
    // anything but NONE/AN_PRE/AN_POST -- none of which are AN_IDX or
    // PC_IDX, the only two modes src_ff/dst_ff ever test for, so returning
    // NONE for every other family's dst_ea_mode_eff is exact, not an
    // approximation.
    // A first version of this function returned `ea_mode_w` for every
    // non-MOVE group unconditionally, reasoning that every family using a
    // real EA sets uop.ea_mode = ea_mode_w while every family that does NOT
    // happens to have ea_mode_w read as NONE anyway. That second half is
    // true only when the family's own guard actually CONSTRAINS instr[5:3]
    // to a register-direct encoding (e.g. src_is_dn appears in the guard
    // itself) -- it does not hold for a family whose low bits are not an EA
    // field AT ALL (Bcc's displacement, MOVEQ's immediate, the shift
    // REGISTER form's count-source/op-select bits, sys_is_misc's own fixed
    // instr[5:3]==110, MOVEC's fixed instr[15:1]), where instr[5:3] can
    // still coincidentally read as AN_IDX (110) or, for MOVEC specifically,
    // f_reg can read as PC_IDX -- confirmed by the equivalence sweep
    // (tb/uop_decode_equiv_tb.sv's ext_words_fast_full check), which found
    // 24,381 mismatches concentrated exactly in groups 6/7/A/F (thousands
    // each) plus part of 4 and E, the first version's blind spot. Each
    // branch below is therefore explicit about whether its own guard
    // genuinely constrains the EA field or merely happens to read something
    // -- it is not "ea_mode_w unless proven otherwise".
    function automatic logic [3:0] ea_mode_eff_fast();
        logic move_ok1_e, move_ok2_e, move_accepted;
        begin
            case (f_group)
            4'h0: begin
                if ((g0_is_dynbit && ea_is_alt_mem) || (g0_is_statbit && ea_is_alt_mem)
                    || g0_is_cmp2 || g0_is_cas || g0_is_moves
                    || (g0_is_alu_imm && ea_is_alt_mem && f_ss_valid)
                    // BTST Dn/#n,(d16/d8,PC,Xn): see ext_words_fast's own
                    // matching additions above -- needed here too so the
                    // full-format addendum (fff_sff) is computed against the
                    // real index word rather than declining to look at all.
                    || (g0_is_dynbit && (b_op == 2'b00)
                        && ((ea_mode_w == UEA_PC_D16)
                         || (ea_mode_w == UEA_PC_IDX)))
                    || (g0_is_statbit && (b_op == 2'b00)
                        && ((ea_mode_w == UEA_PC_D16)
                         || (ea_mode_w == UEA_PC_IDX))))
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;
            end
            4'h1, 4'h2, 4'h3: begin
                move_ok1_e = (ea_src_ok || ea_dst_is_mem)
                          && !((f_movesz == 2'b01) && (src_is_an || dst_is_an))
                          && (ea_src_ok || src_is_dn || src_is_an)
                          && (ea_dst_is_mem || dst_is_dn || dst_is_an);
                move_ok2_e = (src_is_dn || src_is_an) && (dst_is_dn || dst_is_an)
                          && !((f_movesz == 2'b01) && (src_is_an || dst_is_an));
                move_accepted = move_ok1_e || move_ok2_e;
                if (!move_accepted)
                    ea_mode_eff_fast = UEA_NONE;
                else if (move_ok1_e && ea_dst_is_mem && (!ea_src_ok || ea_is_imm))
                    ea_mode_eff_fast = ea_dst_mode_w;
                else if (move_ok1_e)
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;   // move_ok2: register-only
            end
            4'h4: begin
                // g4_is_movec and sys_is_misc are both checked EXPLICITLY
                // (not folded into the "else NONE") because their own
                // instr[5:3]/f_reg happen to read as AN_IDX (sys_is_misc,
                // by construction: instr[5:3]==110) or PC_IDX (MOVEC Rn,Rc,
                // 0x4E7B: f_reg reads 011 from the fixed 0x4E7A/B pattern)
                // -- real values, not noise, that must not be mistaken for
                // a genuine indexed EA this family does not have.
                if ((ea_is_alt_mem && f_ss_valid
                     && (g4_is_neg || g4_is_not || g4_is_clr
                      || g4_is_tst || g4_is_negx))
                    || g4_is_chk
                    || (g4_is_sr_move && (ea_is_alt_mem || src_is_dn
                                          || (!g4_sr_to_ea && ea_src_ok)))
                    || (g4_is_nbcd && ea_is_alt_mem)
                    || g4_is_tas || g4_is_pea || g4_is_lea || g4_is_movem
                    || g4_is_jsr || g4_is_jmp)
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;
            end
            4'h5: begin
                if ((g5_is_cc && ea_is_alt_mem) || (ea_is_alt_mem && f_ss_valid))
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;
            end
            // Bcc/MOVEQ/F-line/A-line: instr[5:0] is not an EA field for any
            // of these (displacement, immediate, CpID+primitive, or nothing
            // at all) -- always NONE, regardless of what it decodes to.
            4'h6, 4'h7, 4'hF, 4'hA: ea_mode_eff_fast = UEA_NONE;
            4'h8, 4'h9, 4'hB, 4'hC, 4'hD: begin
                if ((g_is_muldiv && (src_is_dn || ea_src_ok))
                    || (g_is_xxxa && (ea_src_ok || src_is_dn || src_is_an))
                    || (f_dir && ea_is_alt_mem && f_ss_valid)
                    || (ea_src_ok && !f_dir && f_ss_valid))
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;
            end
            4'hE: begin
                // The shift REGISTER form's own guard (f_ss_valid alone,
                // after excluding bit-field and memory-shift) does not
                // constrain instr[5:3] at all -- those bits are the
                // count-source and operation select there, not an EA field.
                if (g_is_bf && (src_is_dn || (ea_mode_w == UEA_AN_IND)
                                          || (ea_mode_w == UEA_AN_D16)
                                          || (ea_mode_w == UEA_ABS_W)
                                          || (ea_mode_w == UEA_PC_D16)))
                    ea_mode_eff_fast = ea_mode_w;
                else if (ea_is_alt_mem && (f_ss == 2'b11) && e_mem_legal)
                    ea_mode_eff_fast = ea_mode_w;
                else
                    ea_mode_eff_fast = UEA_NONE;
            end
            default: ea_mode_eff_fast = UEA_NONE;
            endcase
        end
    endfunction

    function automatic logic [3:0] dst_ea_mode_eff_fast();
        begin
            dst_ea_mode_eff_fast =
                (((f_group == 4'h1) || (f_group == 4'h2) || (f_group == 4'h3))
                 && ea_dst_is_mem && ea_src_ok && !ea_is_imm)
                ? ea_dst_mode_w : UEA_NONE;
        end
    endfunction

    // A function-calling-function version of this (ext_words_fast_full()
    // calling ext_words_fast() and ea_mode_eff_fast()) made Yosys's `proc`
    // pass fail with "Non-constant expression in constant function" --
    // apparently a real limitation on two levels of automatic-function
    // nesting, not anything to do with these functions' own content (each
    // one synthesizes fine alone, as ext_words_fast_o already proved).
    // Rewritten as a plain always_comb reusing ext_words_fast_o (already
    // computed above) instead of calling ext_words_fast() a second time,
    // with only single-level calls to ea_mode_eff_fast()/
    // dst_ea_mode_eff_fast()/rawword()/ff_extra() -- the same calling shape
    // the real decode block below already uses without issue.
    logic [2:0] fff_lead, fff_srct, fff_dstat;
    logic [15:0] fff_srcw, fff_dstw;
    logic        fff_sff, fff_dff;
    logic [3:0]  fff_eam, fff_deam;
    always_comb begin
        fff_eam   = ea_mode_eff_fast();
        fff_deam  = dst_ea_mode_eff_fast();
        fff_lead  = (ext_words_fast_o > (src_ea_words + dst_ea_words))
                    ? (ext_words_fast_o - src_ea_words - dst_ea_words) : 3'd0;
        fff_srcw  = rawword(fff_lead);
        fff_sff   = ((fff_eam == UEA_AN_IDX) || (fff_eam == UEA_PC_IDX))
                    && fff_srcw[8];
        fff_srct  = src_ea_words + (fff_sff ? ff_extra(fff_srcw) : 3'd0);
        fff_dstat = fff_lead + fff_srct;
        fff_dstw  = rawword(fff_dstat);
        fff_dff   = (fff_deam == UEA_AN_IDX) && fff_dstw[8];
        ext_words_fast_full_o = ext_words_fast_o
                               + (fff_sff ? ff_extra(fff_srcw) : 3'd0)
                               + (fff_dff ? ff_extra(fff_dstw) : 3'd0);
    end

    // ── Decode ──────────────────────────────────────────────────────────────
    // Scratch for the central EA fill-in at the end of the decode block.
    reg [2:0]  ew_tot;
    reg [2:0]  ew_src_total, ew_dst_at;
    reg [2:0]  ew_lead;
    reg [15:0] ew_srcw, ew_dstw;
    reg [15:0] bd_w1, bd_w2, dbd_w1, dbd_w2;
    reg        src_ff, dst_ff;
    // Set when the single EA slot holds the DESTINATION rather than the source,
    // which happens whenever the source needs no address of its own -- a
    // register or an immediate. The fill-in then has to read the extension word
    // at the DESTINATION's offset, past whatever the immediate consumed.
    reg        ea_slot_is_dst;
    reg [15:0] sxw, dxw;

    always_comb begin
        uop = uop_clear();
        ea_slot_is_dst = 1'b0;
        uop.valid  = 1'b1;
        uop.uclass = UC_UNIMPL;   // honest default; overridden on a real match

        case (f_group)
        // ── ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm,Dn ────────────────────────────
        4'h0: begin
            if (g0_is_ccr_sr) begin
                // ORI/ANDI/EORI #imm,CCR (ss=00) and #imm,SR (ss=01). The
                // size field doubles as the CCR/SR selector on real silicon
                // (0x023C byte=CCR, 0x027C word=SR), so it is carried
                // through as UZ_BYTE/UZ_WORD instead of a fixed UZ_LONG --
                // mh030p_core.sv's execute-side fix for this instruction
                // (previously decoded but never executed at all; see
                // dec_sysctl_ok there) needs it to tell a CCR-only write
                // from one that also touches the system byte.
                uop.uclass      = UC_SYSCTL;
                uop.unit        = UU_MOVE;
                uop.siz         = (f_ss == 2'b00) ? UZ_BYTE : UZ_WORD;
                uop.src_kind    = US_IMM;
                uop.imm         = ext;
                uop.dst_kind    = US_SR;
                // g0_is_ccr_sr's own guard already restricts f_dn to
                // {000,001,101} (OR/AND/EOR), the same encoding g0_alu_op
                // already maps -- reused directly rather than re-deriving it.
                uop.alu_op      = g0_alu_op;
                // 6, not one of the MOVE sub-ops: these AND/OR/EOR into the
                // status register rather than replacing it, and would
                // otherwise alias onto "MOVE SR,<ea>" at sub-op 0.
                uop.subop       = 4'd6;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_movep) begin
                uop.uclass      = UC_MOVEP;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.ea_mode     = UEA_AN_D16;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !instr[7];
                uop.writes_mem  = instr[7];
                uop.first       = 1'b1;
                uop.last        = 1'b0;      // expands to per-byte uops
                uop.x_unchanged = 1'b1;
                // The data register and the transfer width. The reference
                // reports dest_reg=0 here and resolves Dn inside its own MOVEP
                // state machine, so this cannot go in dst_reg without breaking
                // the equivalence sweep -- imm is free, MOVEP's displacement
                // living in ea_disp like any other (d16,An).
                uop.imm         = {28'h0, rn_dn};
                uop.xfer_long   = instr[6];
            end else if (g0_is_cmp2) begin
                uop.uclass      = UC_TRAP;      // CHK2 can trap
                uop.subop       = 4'd3;         // CHK2/CMP2
                uop.unit        = UU_MOVE;
                uop.siz         = (f_dn == 3'b000) ? UZ_BYTE :
                                  (f_dn == 3'b001) ? UZ_WORD : UZ_LONG;
                uop.src_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.x_unchanged = 1'b1;
                // The register being range-checked, and which of the pair this
                // is: extension bit 11 selects CHK2 over CMP2, bit 15 selects An
                // over Dn. The whole word travels in imm, as for every other
                // family whose operands the reference resolves in its own FSM.
                uop.imm         = {16'h0, ext[15:0]};
                uop.dst_reg     = {ext[15], ext[14:12]};
            end else if (g0_is_cas) begin
                uop.uclass      = UC_ATOMIC;
                // CAS2 is the immediate-mode encoding (0x0CFC / 0x0EFC) and
                // carries TWO extension words, which moves every field; kept
                // apart so only real CAS is executed.
                uop.subop       = ea_is_imm ? 4'd2 : 4'd1;
                uop.unit        = UU_ALU;
                uop.alu_op      = UA_CMP;
                // CAS size comes from f_dn: 101=B, 110=W, 111=L.
                uop.siz         = (f_dn == 3'b101) ? UZ_BYTE :
                                  (f_dn == 3'b110) ? UZ_WORD : UZ_LONG;
                uop.src_kind    = US_MEM;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                // Dc (compare) and Du (update), both named by the extension
                // word. dst_reg is safe to use despite writes_reg being 0: the
                // sweep only compares it when writes_reg is set, and Dc IS
                // where a mismatch commits.
                uop.dst_reg     = {1'b0, ext[2:0]};
                uop.imm         = {28'h0, 1'b0, ext[8:6]};
                uop.first       = 1'b1;
                uop.last        = 1'b0;
            end else if (g0_is_moves) begin
                uop.uclass      = UC_MOVEC;
                uop.unit        = UU_MOVE;
                uop.siz         = f_siz;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = ext[15:12];
                uop.writes_reg  = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_dynbit && ea_is_alt_mem) begin
                // Dynamic bit ops on memory: the bit number comes from a data
                // register rather than an immediate word, and the operand is a
                // byte. This form was not decoded AT ALL -- BTST Dn,<mem> and
                // its mutating siblings all fell through to UNIMPL, which the
                // Harte corpus found immediately.
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_BYTE;
                uop.subop       = 4'd0;          // dynamic: no immediate word
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_dn;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = (b_op != 2'b00);
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = (b_op == 2'b00);
                uop.x_unchanged = 1'b1;
            end else if (g0_is_dynbit && (b_op == 2'b00)
                         && ((ea_mode_w == UEA_PC_D16)
                          || (ea_mode_w == UEA_PC_IDX))) begin
                // BTST Dn,(d16/d8,PC,Xn): the one bit op of the 4 legal against
                // PC-relative memory, since it never writes back -- ea_is_alt_mem
                // above deliberately excludes PC-relative for the other three,
                // which is why this is its own branch rather than a widened
                // guard on the one above.
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_BYTE;
                uop.subop       = 4'd0;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_dn;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_dynbit && (b_op == 2'b00) && ea_is_imm) begin
                // BTST Dn,#imm: legal for the same read-only reason, and the
                // tested value is the extension word itself -- already fetched
                // as part of ordinary instruction decode, so no separate bus
                // cycle the way a real memory destination needs (ea_mode stays
                // NONE). Stashed in uop.imm, which the dynamic form otherwise
                // never uses since its bit number comes from Dn, not a word.
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_BYTE;
                uop.subop       = 4'd0;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_dn;
                uop.dst_kind    = US_MEM;
                uop.imm         = {24'h0, ext[7:0]};
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_statbit && (b_op == 2'b00)
                         && ((ea_mode_w == UEA_PC_D16)
                          || (ea_mode_w == UEA_PC_IDX))) begin
                // BTST #n,(d16/d8,PC,Xn): the static-bit-number counterpart of
                // the dynamic PC-relative branch above, for the same read-only
                // reason. The bit-number word is still the LEADING extension
                // word (index 0), exactly as the alterable-memory static
                // branch below -- see its own comment for why a plain `ext`
                // can't be used here either.
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_BYTE;
                uop.src_kind    = US_IMM;
                uop.imm         = {16'h0, xword(3'd0, ea_words(ea_mode_w) + 3'd1)};
                uop.subop       = 4'd1;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_statbit && ea_is_alt_mem) begin
                // Static bit ops on memory are byte-sized and leave both the
                // writeback and the flags to the RMW FSM.
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_BYTE;
                uop.src_kind    = US_IMM;
                // The bit-number word is the LEADING extension word (index 0),
                // with the EA's own word(s) following it -- but ext's own two
                // halves swap which physical half holds index 0 depending on
                // the TOTAL word count (see xword's own comment), so a plain
                // `ext` (both halves) smeared the bit number together with the
                // EA's own index/displacement word whenever the EA itself
                // needed an extension word (indexed, (d16,An), abs). Confirmed
                // via a direct trace: BTST #,(d8,A0,Xn) computed bit_num from
                // the INDEX word's own low bits instead of the real bit-number
                // word, and ALSO fed the same garbled value into the EA index
                // register, producing a wrong effective address at the same
                // time.
                uop.imm         = {16'h0, xword(3'd0, ea_words(ea_mode_w) + 3'd1)};
                uop.subop       = 4'd1;          // static: one immediate word
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = (b_op != 2'b00);
                uop.writes_reg  = 1'b0;
                // BTST writes nothing, so it claims the flags at decode; the
                // mutating forms leave them to the RMW FSM. Same split as
                // TST/CMPI versus the writing memory families.
                uop.updates_ccr = (b_op == 2'b00);
                uop.x_unchanged = 1'b1;
            end else if ((g0_is_dynbit || g0_is_statbit) && src_is_dn) begin
                // Dn destination: the bit number is mod 32 and the operand is
                // a full longword (memory forms are byte-sized -- P3).
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_LONG;
                uop.src_kind    = g0_is_dynbit ? US_DREG : US_IMM;
                uop.src_reg     = rn_dn;
                uop.imm         = ext;
                uop.subop       = g0_is_dynbit ? 4'd0 : 4'd1;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = (b_op != 2'b00);   // BTST writes nothing
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g0_is_alu_imm && ea_is_alt_mem && f_ss_valid) begin
                // Immediate op on memory: read-modify-write, so wr=0/ccr=0
                // exactly as for the group 4 memory forms above.
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.alu_op      = g0_alu_op;
                uop.siz         = f_siz;
                uop.src_kind    = US_IMM;
                uop.imm         = ext;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = (g0_alu_op != UA_CMP);
                uop.writes_reg  = 1'b0;
                // ccr=0 only when there is a memory WRITE, because then the
                // RMW FSM owns the flag update. CMPI writes nothing, so it
                // sets the flags at decode just like TST does.
                uop.updates_ccr = (g0_alu_op == UA_CMP);
                uop.x_unchanged = (g0_alu_op == UA_CMP);
            end else if (g0_is_alu_imm && src_is_dn && f_ss_valid) begin
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.alu_op      = g0_alu_op;
                uop.siz         = f_siz;
                uop.src_kind    = US_IMM;
                uop.imm         = ext;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = (g0_alu_op != UA_CMP);
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = (g0_alu_op == UA_CMP);
            end
        end

        // ── MOVE / MOVEA ────────────────────────────────────────────────────
        4'h1, 4'h2, 4'h3: begin
            // Memory source and/or memory destination. MOVE.B has no An
            // forms at all, in either direction.
            if ((ea_src_ok || ea_dst_is_mem)
                && !((f_movesz == 2'b01) && (src_is_an || dst_is_an))
                && (ea_src_ok || src_is_dn || src_is_an)
                && (ea_dst_is_mem || dst_is_dn || dst_is_an)) begin
                uop.uclass      = UC_MOVE;
                uop.unit        = UU_MOVE;
                uop.siz         = dst_is_an ? UZ_LONG : f_move_siz;
                uop.sext_src    = dst_is_an && (f_move_siz == UZ_WORD);
                uop.opnd_word   = dst_is_an && (f_move_siz == UZ_WORD);

                // Source
                if (ea_src_ok) begin
                    uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                    uop.imm         = ext;
                    uop.ea_mode     = ea_mode_w;
                    uop.ea_reg      = rn_src_an;
                    uop.reads_mem   = !ea_is_imm;
                end else begin
                    uop.src_kind = src_is_dn ? US_DREG : US_AREG;
                    uop.src_reg  = src_is_dn ? rn_src_dn : rn_src_an;
                end

                // Destination
                if (ea_dst_is_mem) begin
                    uop.dst_kind   = US_MEM;
                    uop.writes_mem = 1'b1;
                    uop.writes_reg = 1'b0;
                    // The uop carries ONE effective address. When the source
                    // is a register the EA field is free, so the destination
                    // EA goes there and a register->memory MOVE becomes
                    // executable. A memory-to-memory MOVE needs two addresses
                    // and cannot be expressed this way; it stays unexecutable
                    // (the core's own scope check rejects it) rather than
                    // silently using the wrong one.
                    // An immediate source needs no address either, so the EA
                    // field is just as free as it is for a register source. The
                    // destination's own displacement then sits PAST the
                    // immediate's words, which is what ea_slot_is_dst tells the
                    // fill-in below.
                    if (!ea_src_ok || ea_is_imm) begin
                        uop.ea_mode    = ea_dst_mode_w;
                        uop.ea_reg     = rn_dst_an;
                        ea_slot_is_dst = 1'b1;
                    end else begin
                        // Memory to memory: the source EA stays in ea_*, the
                        // destination goes in dst_ea_*.
                        uop.dst_ea_mode = ea_dst_mode_w;
                        uop.dst_ea_reg  = rn_dst_an;
                    end
                end else begin
                    uop.dst_kind   = dst_is_dn ? US_DREG : US_AREG;
                    uop.dst_reg    = dst_is_dn ? rn_dst_dn : rn_dst_an;
                    uop.writes_reg = 1'b1;
                end

                // MOVEA never touches the CCR. Neither does a MEMORY-TO-
                // MEMORY move at decode time: the reference decoder reports
                // ccr=0 there because a dedicated multi-phase FSM
                // (move_mm_run_r) owns the flag update once the read
                // completes. reg->mem and mem->reg both do set it at decode.
                uop.updates_ccr = !dst_is_an
                               && !(ea_src_ok && !ea_is_imm && ea_dst_is_mem);
                uop.x_unchanged = 1'b1;
            end else if ((src_is_dn || src_is_an) && (dst_is_dn || dst_is_an)) begin
                // MOVE.B has no An forms at all (byte An access is illegal).
                if (!((f_movesz == 2'b01) && (src_is_an || dst_is_an))) begin
                    uop.uclass      = UC_MOVE;
                    uop.unit        = UU_MOVE;
                    // MOVEA writes ALL 32 bits of An regardless of operand
                    // size -- MOVEA.W sign-extends its word source first. So
                    // the uop size (a WRITE size) is long for every MOVEA,
                    // with sext_src carrying the word-source case. The
                    // equivalence sweep caught this: the old decoder reports
                    // dec_siz=long for 0x3040 (MOVEA.W D0,A0).
                    uop.siz         = dst_is_an ? UZ_LONG : f_move_siz;
                    uop.sext_src    = dst_is_an && (f_move_siz == UZ_WORD);
                    uop.opnd_word   = dst_is_an && (f_move_siz == UZ_WORD);
                    uop.src_kind    = src_is_dn ? US_DREG : US_AREG;
                    uop.src_reg     = src_is_dn ? rn_src_dn : rn_src_an;
                    uop.dst_kind    = dst_is_dn ? US_DREG : US_AREG;
                    uop.dst_reg     = dst_is_dn ? rn_dst_dn : rn_dst_an;
                    uop.writes_reg  = 1'b1;
                    // MOVEA does not touch the CCR; MOVE does.
                    uop.updates_ccr = dst_is_dn;
                    uop.x_unchanged = 1'b1;
                end
            end
        end

        // ── NEG/NEGX/NOT/CLR/TST/EXT/SWAP/TAS/NBCD ──────────────────────────
        4'h4: begin
            // Memory single-operand forms. These are read-modify-write, and
            // the reference decoder reports wr=0 AND ccr=0 for them: the RMW
            // FSM owns both the writeback and the flag update. TST and CLR
            // are the exceptions -- TST never writes, and CLR never reads --
            // so both genuinely set the flags at decode.
            if (ea_is_alt_mem && f_ss_valid
                && (g4_is_neg || g4_is_not || g4_is_clr
                 || g4_is_tst || g4_is_negx)) begin
                uop.uclass      = UC_ALU;
                // CLR on memory goes through the MOVE unit (it writes a zero
                // rather than reading anything); CLR on Dn uses the ALU.
                uop.unit        = g4_is_clr ? UU_MOVE : UU_ALU;
                uop.alu_op      = g4_is_neg  ? UA_NEG  :
                                  g4_is_negx ? UA_NEGX :
                                  g4_is_not  ? UA_NOT  :
                                  g4_is_clr  ? UA_CLR  : UA_TST;
                uop.siz         = f_siz;
                uop.src_kind    = US_MEM;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !g4_is_clr;
                uop.writes_mem  = !g4_is_tst;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = g4_is_tst || g4_is_clr;
                uop.x_unchanged = (g4_is_tst || g4_is_clr || g4_is_not);
            // MOVEC is deliberately NOT claimed yet. Its register is named by
            // an extension word, and the reference decoder reads it from
            // ext_data[15:12] (eu_seq_decode.svh:3561) while eu_seq.sv's own
            // header documents ext_data as "first extension word in bits
            // [31:16], second in [15:0]" -- so the reference appears to read
            // the SECOND word's field for a single-extension-word
            // instruction. That may be a real bug in rtl/, or the convention
            // may vary per instruction; either way it must be resolved by
            // reading the IFU drain path, not guessed at from a testbench
            // that drives an arbitrary ext value. Claiming it would bake an
            // unjustified convention into the new core for 2 opcodes.
            end else if (g4_is_chk) begin
                uop.uclass      = UC_TRAP;
                uop.subop       = 4'd2;         // CHK: vector 6 on a bounds fail
                uop.unit        = UU_NONE;
                uop.siz         = (g4_b76 == 2'b10) ? UZ_WORD : UZ_LONG;
                uop.src_kind    = src_is_dn ? US_DREG :
                                  ea_is_imm  ? US_IMM  : US_MEM;
                uop.src_reg     = rn_src_dn;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !ea_is_imm && !src_is_dn;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b1;
                uop.traps       = 1'b1;
            // MOVE CCR,<ea> to memory was missing from the reference decoder
            // and has now been added there (rtl/eu_seq_decode.svh), so it is
            // claimed here and the sweep validates it like any other form.
            end else if (g4_is_sr_move && (ea_is_alt_mem || src_is_dn
                                           || (!g4_sr_to_ea && ea_src_ok))) begin
                uop.uclass      = UC_SYSCTL;
                uop.unit        = UU_MOVE;
                // MOVE #imm,CCR is byte-sized in the reference decoder (CCR
                // is 8 bits and the immediate's high byte is ignored), while
                // MOVE <mem>,CCR and every SR form are word-sized. Only the
                // immediate-to-CCR combination differs.
                uop.siz         = (ea_is_imm && (g4_op == 4'h4)) ? UZ_BYTE : UZ_WORD;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                // 0 = MOVE SR,<ea>   1 = MOVE CCR,<ea>
                // 2 = MOVE <ea>,CCR   3 = MOVE <ea>,SR
                uop.subop       = {2'b00, g4_op_hi};
                if (g4_sr_to_ea) begin
                    uop.src_kind    = US_SR;
                    uop.dst_kind    = src_is_dn ? US_DREG : US_MEM;
                    uop.dst_reg     = rn_src_dn;
                    uop.writes_reg  = src_is_dn;
                    uop.writes_mem  = !src_is_dn;
                    uop.updates_ccr = 1'b0;
                end else begin
                    uop.src_kind    = ea_is_imm ? US_IMM :
                                      src_is_dn ? US_DREG : US_MEM;
                    uop.src_reg     = rn_src_dn;
                    uop.imm         = ext;
                    uop.reads_mem   = !ea_is_imm && !src_is_dn;
                    uop.dst_kind    = US_SR;
                    uop.writes_reg  = 1'b0;
                    uop.updates_ccr = 1'b1;
                end
                uop.x_unchanged = 1'b1;
            end else if (g4_is_nbcd) begin
                uop.uclass      = UC_BCD;
                uop.unit        = UU_BCD;
                uop.alu_op      = 4'h2;          // eu_bcd.sv BCD_NEG
                uop.siz         = UZ_BYTE;
                uop.updates_ccr = 1'b1;
                if (src_is_dn) begin
                    uop.dst_kind   = US_DREG;
                    uop.dst_reg    = rn_src_dn;
                    uop.writes_reg = 1'b1;
                end else if (ea_is_alt_mem) begin
                    uop.dst_kind   = US_MEM;
                    uop.ea_mode    = ea_mode_w;
                    uop.ea_reg     = rn_src_an;
                    uop.reads_mem  = 1'b1;
                    uop.writes_mem = 1'b1;
                    uop.updates_ccr = 1'b0;      // RMW FSM owns the flags
                end else begin
                    uop.uclass = UC_UNIMPL;
                end
            end else if (g4_is_tas) begin
                uop.uclass      = UC_ATOMIC;
                uop.subop       = 4'd0;         // TAS
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_BYTE;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
            end else if (g4_is_tas_dn) begin
                uop.uclass      = UC_ATOMIC;
                uop.subop       = 4'd0;         // TAS
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_BYTE;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
            end else if (g4_is_pea) begin
                uop.uclass      = UC_LEA;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.writes_mem  = 1'b1;          // pushes onto the stack
            end else if (g4_is_lea) begin
                uop.uclass      = UC_LEA;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.dst_kind    = US_AREG;
                uop.dst_reg     = {1'b1, f_dn};
                uop.writes_reg  = 1'b1;
            end else if (g4_is_movem) begin
                uop.uclass      = UC_MOVEM;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;         // matches the reference
                uop.xfer_long   = instr[6];        // the real transfer size
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                // The register mask is the FIRST extension word, so which
                // half of ext holds it depends on whether the EA needs one
                // too: mask alone lands in the low half, mask plus a
                // displacement puts the mask high. Same rule as every other
                // extension field (m68030_seq.sv:1160).
                uop.imm         = (ea_words(ea_mode_w) == 3'd0)
                                ? {16'h0, ext[15:0]}
                                : {16'h0, ext[31:16]};
                uop.reads_mem   = !g4_movem_to_mem;
                uop.writes_mem  = g4_movem_to_mem;
                uop.first       = 1'b1;
                uop.last        = 1'b0;          // expands to a uop sequence
            end else if (g4_is_jsr || g4_is_jmp) begin
                uop.uclass      = UC_JMP;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.writes_mem  = g4_is_jsr;     // pushes a return address
            end else if (sys_is_trap) begin
                uop.uclass      = UC_TRAP;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_WORD;
                // Vector NUMBER, not the opcode's vector field: TRAP #n takes
                // vector 32+n (MC68030UM Table 8-1).
                uop.imm         = {26'h0, 2'b00} | (32'd32 + {28'h0, sys_lo});
                uop.ea_reg      = 4'd15;       // A7, for the stack frame
                uop.traps       = 1'b1;
            end else if (sys_is_link || sys_is_unlk) begin
                uop.uclass      = UC_LINK;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.dst_kind    = US_AREG;
                uop.dst_reg     = rn_src_an;
                // LINK A7 is the one exception: linking the stack pointer
                // itself, the An write is subsumed by the SP manipulation,
                // so the reference reports writes_reg=0 for 0x4E57 only.
                uop.writes_reg  = !(sys_is_link && (f_reg == 3'b111));
                uop.reads_mem   = sys_is_unlk;
                uop.writes_mem  = sys_is_link;
                // LINK's frame size is its extension word. LINK.L (0x4808)
                // takes a longword one; this decodes the word form.
                uop.imm         = {{16{ext[15]}}, ext[15:0]};
                uop.subop       = sys_is_link ? 4'd0 : 4'd1;
            end else if (sys_is_usp || sys_is_uspr) begin
                uop.uclass      = UC_SYSCTL;
                uop.unit        = UU_MOVE;   // reference decoder: unit=MOVE
                uop.siz         = UZ_LONG;
                uop.subop       = sys_is_uspr ? 4'd5 : 4'd4;  // USP -> An / An -> USP
                uop.src_kind    = sys_is_uspr ? US_USP : US_AREG;
                uop.dst_kind    = sys_is_uspr ? US_AREG : US_USP;
                uop.dst_reg     = rn_src_an;
                uop.writes_reg  = sys_is_uspr;
            end else if (g4_is_movec) begin
                // MOVEC Rc,Rn (0x4E7A) and MOVEC Rn,Rc (0x4E7B). Supervisor
                // only on real silicon; this core has no privilege-violation
                // vector yet, so the check is deliberately absent rather than
                // half-built.
                uop.uclass      = UC_MOVEC;
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_LONG;
                uop.subop       = movec_to_reg ? 4'd1 : 4'd2;
                uop.imm         = {20'h0, ext[11:0]};   // which control register
                uop.x_unchanged = 1'b1;
                if (movec_to_reg) begin
                    uop.dst_kind   = movec_rn[3] ? US_AREG : US_DREG;
                    uop.dst_reg    = movec_rn;
                    uop.writes_reg = 1'b1;
                end else begin
                    uop.src_kind   = movec_rn[3] ? US_AREG : US_DREG;
                    uop.src_reg    = movec_rn;
                end
            end else if (sys_is_misc) begin
                // 0x4E70 RESET, 71 NOP, 72 STOP, 73 RTE, 74 RTD, 75 RTS,
                // 76 TRAPV, 77 RTR.
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                case (sys_lo)
                    4'h3, 4'h5, 4'h7: begin
                        // RTS pops the return address; (A7)+ gets the stack
                        // adjustment from the same machinery BSR uses.
                        uop.uclass    = UC_RETURN;
                        uop.ea_mode   = UEA_AN_POST;
                        uop.ea_reg    = 4'd15;
                        uop.reads_mem = 1'b1;
                        // Which return this is: 3 = RTE, 5 = RTS, 7 = RTR.
                        // RTE and RTR pop a status word before the PC.
                        uop.imm       = {28'h0, sys_lo};
                        uop.subop     = sys_lo;
                    end
                    // TRAPV: vector 7, and conditional on V (sub-op 1,
                    // against TRAP #n's unconditional sub-op 0).
                    4'h6: begin uop.uclass = UC_TRAP; uop.traps = 1'b1;
                                uop.imm    = 32'd7;   uop.subop = 4'd1;
                                uop.ea_reg = 4'd15; end
                    // 0 RESET, 1 NOP, 2 STOP. Only STOP does anything, and it
                    // carries the SR value to load in an extension word.
                    4'h0, 4'h1, 4'h2: begin
                        uop.uclass = UC_NOP;
                        uop.subop  = sys_lo;
                        uop.imm    = {16'h0, ext[15:0]};
                    end
                    default: uop.uclass = UC_UNIMPL;            // RTD
                endcase
            end else if (g4_is_swap) begin
                uop.uclass      = UC_SWAP;
                uop.unit        = UU_MOVE;   // reference decoder uses MOVE, not ALU
                uop.siz         = UZ_LONG;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g4_is_ext) begin
                uop.uclass      = UC_EXT;
                uop.unit        = UU_MOVE;   // reference decoder uses MOVE, as for SWAP
                uop.siz         = (g4_ext_sel == 3'b010) ? UZ_WORD : UZ_LONG;
                // Three forms, and siz cannot tell the last two apart: EXT.W
                // widens a byte to a word, EXT.L a word to a long, and EXTB.L a
                // BYTE to a long. Both long forms report siz=long.
                uop.subop       = (g4_ext_sel == 3'b010) ? 4'd0 :
                                  (g4_ext_sel == 3'b011) ? 4'd1 : 4'd2;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (src_is_dn && f_ss_valid
                         && (g4_is_neg || g4_is_not || g4_is_clr
                          || g4_is_tst || g4_is_negx)) begin
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.alu_op      = g4_is_neg  ? UA_NEG  :
                                  g4_is_negx ? UA_NEGX :
                                  g4_is_not  ? UA_NOT  :
                                  g4_is_clr  ? UA_CLR  : UA_TST;
                uop.siz         = f_siz;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = !g4_is_tst;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = (g4_is_tst || g4_is_clr || g4_is_not);
            end
        end

        // ── ADDQ/SUBQ #imm,Dn ───────────────────────────────────────────────
        4'h5: begin
            if (g5_is_trapcc) begin
                uop.uclass      = UC_TRAP;
                uop.subop       = 4'd4;         // TRAPcc: vector 7 on cc true
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.cond        = f_cond;
                uop.traps       = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g5_is_scc) begin
                uop.uclass      = UC_SCC;
                uop.unit        = UU_MOVE;   // reference decoder: unit=MOVE
                uop.siz         = UZ_BYTE;
                uop.cond        = f_cond;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g5_is_cc && ea_is_alt_mem) begin
                uop.uclass      = UC_SCC;
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_BYTE;
                uop.cond        = f_cond;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.x_unchanged = 1'b1;
            end else if (g5_is_dbcc) begin
                uop.uclass      = UC_DBCC;
                // 16-bit displacement in the following extension word.
                uop.imm         = {{16{ext[15]}}, ext[15:0]};
                // The decrement is a real ALU subtract in the reference
                // decoder (unit=ALU, alu_op=SUB), not a bespoke path.
                uop.unit        = UU_ALU;
                uop.alu_op      = UA_SUB;
                uop.siz         = UZ_WORD;
                uop.cond        = f_cond;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (ea_is_alt_mem && f_ss_valid) begin
                uop.uclass      = UC_ADDQ;
                uop.unit        = UU_ALU;
                uop.alu_op      = f_dir ? UA_SUB : UA_ADD;
                uop.siz         = f_siz;
                uop.src_kind    = US_IMM;
                uop.imm         = f_q_imm;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
            end else if (src_is_an && (f_siz != UZ_BYTE)) begin
                // ADDQ/SUBQ #n,An. The whole address register is written
                // whatever the encoded size says, and the flags are NOT
                // affected -- the one ALU operation in the set that writes a
                // register and leaves the CCR alone. Not decoded before, so
                // SUBQ #3,A6 did nothing at all.
                uop.uclass      = UC_ADDQ;
                uop.unit        = UU_ALU;
                uop.alu_op      = f_dir ? UA_SUB : UA_ADD;
                // LONG whatever the encoded size says, which is what the
                // reference reports too: the arithmetic is on the whole
                // register, so the operation size is not the encoded size.
                uop.siz         = UZ_LONG;
                uop.src_kind    = US_IMM;
                uop.imm         = f_q_imm;
                uop.dst_kind    = US_AREG;
                uop.dst_reg     = rn_src_an;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b0;
                uop.x_unchanged = 1'b1;
            end else if (src_is_dn && f_ss_valid) begin
                uop.uclass      = UC_ADDQ;
                uop.unit        = UU_ALU;
                uop.alu_op      = f_dir ? UA_SUB : UA_ADD;
                uop.siz         = f_siz;
                uop.src_kind    = US_IMM;
                uop.imm         = f_q_imm;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
            end
        end

        // ── F-line: MMU (CpID 000), coprocessor (CpID 001) and the trap ─────
        4'hF: begin
            uop.uclass      = (instr[11:9] == 3'b000) ? UC_MMU :
                              (instr[11:9] == 3'b001) ? UC_COPROC : UC_TRAP;
            uop.unit        = UU_NONE;
            uop.siz         = UZ_LONG;
            uop.traps       = (instr[11:9] != 3'b000) && (instr[11:9] != 3'b001);
            uop.x_unchanged = 1'b1;
        end

        // ── A-line: the whole group is the unimplemented-instruction trap ───
        4'hA: begin
            uop.uclass      = UC_TRAP;
            uop.subop       = 4'd5;         // Line-A emulator: vector 10
            uop.unit        = UU_NONE;
            uop.siz         = UZ_LONG;
            uop.traps       = 1'b1;
            uop.x_unchanged = 1'b1;
        end

        // ── Bcc / BRA / BSR ─────────────────────────────────────────────────
        4'h6: begin
            uop.uclass      = UC_BRANCH;
            uop.unit        = UU_NONE;
            uop.siz         = UZ_LONG;   // reference decoder: siz=long
            uop.cond        = f_cond;     // 0000 = BRA, 0001 = BSR
            // Displacement: the 8-bit field in the opcode, or the following
            // extension word when that field is zero (Bcc.W). The 0xFF escape
            // (Bcc.L, 68020+) is not claimed here. imm carries it because a
            // branch has no other use for that field.
            uop.imm         = (instr[7:0] == 8'h00)
                            ? {{16{ext[15]}}, ext[15:0]}
                            : {{24{instr[7]}}, instr[7:0]};
            uop.x_unchanged = 1'b1;
            // BSR pushes a return address. Describing that as -(A7) lets the
            // existing auto-decrement machinery do the stack adjustment, so
            // no separate stack-pointer path is needed. writes_reg stays 0,
            // matching the reference decoder.
            if (f_cond == 4'h1) begin
                uop.ea_mode    = UEA_AN_PRE;
                uop.ea_reg     = 4'd15;          // A7
                uop.siz        = UZ_LONG;
                uop.writes_mem = 1'b1;
            end
        end

        // ── MOVEQ ───────────────────────────────────────────────────────────
        4'h7: begin
            if (!instr[8]) begin
                uop.uclass      = UC_MOVEQ;
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_LONG;
                uop.src_kind    = US_IMM;
                uop.imm         = {{24{f_moveq_imm[7]}}, f_moveq_imm};
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end
        end

        // ── OR / SUB / CMP+EOR / AND / ADD, register-direct ─────────────────
        4'h8, 4'h9, 4'hB, 4'hC, 4'hD: begin
            if (g_is_bcd_reg) begin
                uop.uclass      = UC_BCD;
                uop.unit        = UU_BCD;
                // eu_bcd.sv: BCD_ADD=00 (ABCD, group C), BCD_SUB=01 (SBCD).
                uop.alu_op      = (f_group == 4'hC) ? 4'h0 : 4'h1;
                uop.siz         = UZ_BYTE;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_src_dn;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
            end else if (g_is_x_reg) begin
                uop.uclass      = UC_ADDX;
                uop.unit        = UU_ALU;
                uop.alu_op      = (f_group == 4'hD) ? UA_ADDX : UA_SUBX;
                uop.siz         = f_siz;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_src_dn;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
            end else if (g_is_bcd_mem || g_is_x_mem) begin
                // -(Ay),-(Ax): both operands predecrement through memory, so
                // the writeback and the flags belong to the multi-cycle FSM.
                uop.uclass      = g_is_bcd_mem ? UC_BCD : UC_ADDX;
                uop.unit        = g_is_bcd_mem ? UU_BCD : UU_ALU;
                uop.alu_op      = g_is_bcd_mem ? ((f_group == 4'hC) ? 4'h0 : 4'h1)
                                               : ((f_group == 4'hD) ? UA_ADDX : UA_SUBX);
                uop.siz         = g_is_bcd_mem ? UZ_BYTE : f_siz;
                // TWO addresses: the source predecrements Ay (the low register
                // field) and the destination predecrements Ax (the high one).
                // Only the source was described, so the core treated the whole
                // thing as a single-address read-modify-write and wrote its
                // result back over the SOURCE -- leaving Ax undecremented and
                // the destination byte untouched.
                uop.dst_ea_mode = UEA_AN_PRE;
                uop.dst_ea_reg  = {1'b1, f_dn};
                uop.src_kind    = US_MEM;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = UEA_AN_PRE;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                // Unlike the other memory RMW families, these DO claim the
                // flags at decode -- the reference reports ccr=1 here.
                uop.updates_ccr = 1'b1;
                uop.first       = 1'b1;
                uop.last        = 1'b0;
            end else if (g_is_exg) begin
                uop.uclass      = UC_EXG;
                uop.unit        = UU_NONE;   // reference decoder: unit=NONE
                uop.siz         = UZ_LONG;
                // Which side is the address register differs per flavour:
                //   01000 EXG Dx,Dy -> both data
                //   01001 EXG Ax,Ay -> both address
                //   10001 EXG Dx,Ay -> Dx in bits[11:9], Ay in bits[2:0]
                // The commit register (dec_dest_reg) is bits[11:9], which is
                // the DATA register for the mixed form -- the sweep caught
                // this at 0xC58A (EXG D2,A2), where an A-register guess gave
                // dest=0xA against the reference's 2.
                uop.src_kind    = (c_exg_sel == 5'b01000) ? US_DREG : US_AREG;
                uop.src_reg     = (c_exg_sel == 5'b01000) ? rn_src_dn : rn_src_an;
                uop.dst_kind    = (c_exg_sel == 5'b01001) ? US_AREG : US_DREG;
                uop.dst_reg     = (c_exg_sel == 5'b01001) ? {1'b1, f_dn} : rn_dn;
                uop.writes_reg  = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (g_is_muldiv && (src_is_dn || ea_src_ok)) begin
                uop.uclass      = UC_MULDIV;
                uop.unit        = (f_group == 4'hC) ? UU_MUL : UU_DIV;
                uop.alu_op      = g_md_op;     // md_op shares the alu_op field
                // Word forms, but the WRITTEN result is a full longword: a
                // 32-bit product for MUL, packed {remainder,quotient} for
                // DIV. uop.siz is a write size, so it is long -- the same
                // operand-size-vs-write-size distinction as MOVEA.W.
                uop.siz         = UZ_LONG;
                uop.sext_src    = 1'b0;
                // Group 8/C MUL and DIV are the WORD forms -- the .L forms
                // live in group 4. siz is long because the RESULT is, but the
                // operand fetched from memory is a word.
                uop.opnd_word   = 1'b1;
                uop.src_kind    = src_is_dn ? US_DREG :
                                  ea_is_imm ? US_IMM  : US_MEM;
                uop.src_reg     = rn_src_dn;
                // The immediate itself was never captured, so MULU/DIVU #imm,Dn
                // got a divisor of ZERO -- which for DIVU means it took a
                // divide-by-zero exception the program never asked for and ran
                // off through an uninitialised vector. A hang, not a wrong
                // answer, which is why it showed up as a timeout.
                uop.imm         = ext;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !src_is_dn && !ea_is_imm;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
                uop.traps       = (f_group == 4'h8);  // divide by zero
            end else
            // dir=1 means "Dn,<ea>", whose <ea> must be MEMORY for the plain
            // ALU ops. With a register EA that encoding space belongs to
            // other families entirely: SBCD (8), SUBX (9), ABCD/EXG (C),
            // ADDX (D) -- all UC_UNIMPL for now. Group B is the genuine
            // exception: B/dir=1/mode=000 really is EOR Dn,Dy (mode=001
            // there is CMPM, already excluded by src_is_dn).
            // The sweep caught this at 0x8101 (SBCD), which the reference
            // decoder reports as unit=UU_BCD.
            if (g_is_xxxa && (ea_src_ok || src_is_dn || src_is_an)) begin
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.alu_op      = (f_group == 4'hD) ? UA_ADD :
                                  (f_group == 4'h9) ? UA_SUB : UA_CMP;
                uop.siz         = UZ_LONG;
                uop.sext_src    = g_xxxa_word;
                uop.opnd_word   = g_xxxa_word;
                if (ea_src_ok) begin
                    uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                    uop.imm         = ext;
                    uop.ea_mode     = ea_mode_w;
                    uop.ea_reg      = rn_src_an;
                    uop.reads_mem   = !ea_is_imm;
                end else begin
                    uop.src_kind = src_is_dn ? US_DREG : US_AREG;
                    uop.src_reg  = src_is_dn ? rn_src_dn : rn_src_an;
                end
                // CMPA compares and sets flags; ADDA/SUBA write An and do NOT
                // touch the CCR at all.
                uop.dst_kind    = US_AREG;
                uop.dst_reg     = {1'b1, f_dn};
                uop.writes_reg  = (f_group != 4'hB);
                uop.updates_ccr = (f_group == 4'hB);
                uop.x_unchanged = (f_group == 4'hB);
            end else if (g_is_cmpm) begin
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.alu_op      = UA_CMP;
                uop.siz         = f_siz;
                uop.src_kind    = US_MEM;
                uop.ea_mode     = UEA_AN_POST;
                uop.ea_reg      = rn_src_an;
                // CMPM has TWO memory operands, both postincrementing, and only
                // the source was described -- so the comparison used whatever
                // the destination register happened to hold and Ax never moved.
                uop.dst_kind    = US_MEM;
                uop.dst_ea_mode = UEA_AN_POST;
                uop.dst_ea_reg  = {1'b1, f_dn};
                uop.reads_mem   = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = 1'b1;
            end else if (f_dir && ea_is_alt_mem && f_ss_valid) begin
                // <op> Dn,<ea> with a memory destination: read-modify-write,
                // so wr=0 and ccr=0 exactly as for the other RMW forms.
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.siz         = f_siz;
                uop.alu_op      = (f_group == 4'h8) ? UA_OR  :
                                  (f_group == 4'h9) ? UA_SUB :
                                  (f_group == 4'hB) ? UA_EOR :
                                  (f_group == 4'hC) ? UA_AND : UA_ADD;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_dn;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
            end else if ((ea_src_ok || alu_an_src_ok)
                         && !f_dir && f_ss_valid) begin
                // <ea>,Dn with a MEMORY, IMMEDIATE or ADDRESS-REGISTER source.
                // The destination is always Dn, so dest_reg stays well defined.
                //
                // An-direct was missing entirely: SUB.l A4,D1 and its siblings
                // decoded to UNIMPL and silently did nothing. Restricted to word
                // and long, because a BYTE operation on an address register is
                // genuinely illegal -- the reference decoder accepts it, and
                // copying that over-acceptance is exactly what plan.md's own P1
                // finding says not to do.
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.siz         = f_siz;
                uop.alu_op      = (f_group == 4'h8) ? UA_OR  :
                                  (f_group == 4'h9) ? UA_SUB :
                                  (f_group == 4'hB) ? UA_CMP :
                                  (f_group == 4'hC) ? UA_AND : UA_ADD;
                uop.src_kind    = alu_an_src_ok ? US_AREG :
                                  ea_is_imm     ? US_IMM  : US_MEM;
                uop.src_reg     = rn_src_an;
                uop.imm         = ext;
                uop.ea_mode     = alu_an_src_ok ? UEA_NONE : ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !ea_is_imm && !alu_an_src_ok;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = (f_group != 4'hB);
                uop.updates_ccr = 1'b1;
                uop.x_unchanged = (f_group == 4'hB);
            end else if (src_is_dn && f_ss_valid && ((f_group == 4'hB) || !f_dir)) begin
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.siz         = f_siz;
                uop.alu_op      = (f_group == 4'h8) ? UA_OR  :
                                  (f_group == 4'h9) ? UA_SUB :
                                  (f_group == 4'hB) ? (f_dir ? UA_EOR : UA_CMP) :
                                  (f_group == 4'hC) ? UA_AND : UA_ADD;
                uop.updates_ccr = 1'b1;
                // Direction: bit[8] selects <ea>,Dn vs Dn,<ea>. With both
                // operands register-direct the only difference is which
                // register is written. CMP (group B, dir=0) writes neither.
                if (f_group == 4'hB) begin
                    if (f_dir) begin           // EOR Dn,Dy
                        uop.src_kind   = US_DREG;
                        uop.src_reg    = rn_dn;
                        uop.dst_kind   = US_DREG;
                        uop.dst_reg    = rn_src_dn;
                        uop.writes_reg = 1'b1;
                    end else begin             // CMP Dy,Dn
                        uop.src_kind    = US_DREG;
                        uop.src_reg     = rn_src_dn;
                        uop.dst_kind    = US_DREG;
                        uop.dst_reg     = rn_dn;
                        uop.writes_reg  = 1'b0;
                        uop.x_unchanged = 1'b1;
                    end
                end else if (f_dir) begin      // <op> Dn,Dy  -> writes Dy
                    uop.src_kind   = US_DREG;
                    uop.src_reg    = rn_dn;
                    uop.dst_kind   = US_DREG;
                    uop.dst_reg    = rn_src_dn;
                    uop.writes_reg = 1'b1;
                end else begin                 // <op> Dy,Dn  -> writes Dn
                    uop.src_kind   = US_DREG;
                    uop.src_reg    = rn_src_dn;
                    uop.dst_kind   = US_DREG;
                    uop.dst_reg    = rn_dn;
                    uop.writes_reg = 1'b1;
                end
            end
        end

        // ── Shifts / rotates, register form ─────────────────────────────────
        4'hE: begin
            // The REFERENCE decoder supports only a partial EA set for
            // bit-fields: Dn, (An), d16(An), abs.W and d16(PC). It reports
            // indexed (mode 110), abs.L and PC-indexed as ILLEGAL, though all
            // of them are legal control modes on real silicon -- another
            // apparent gap in rtl/, recorded here rather than papered over.
            // Matching the reference's set is deliberate: an opcode it
            // rejects is one this sweep cannot validate.
            if (g_is_bf && (src_is_dn || (ea_mode_w == UEA_AN_IND)
                                      || (ea_mode_w == UEA_AN_D16)
                                      || (ea_mode_w == UEA_ABS_W)
                                      || (ea_mode_w == UEA_PC_D16))) begin
                uop.uclass      = UC_BITFIELD;
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !src_is_dn;
                uop.writes_mem  = !src_is_dn && bf_mutates;
                uop.dst_kind    = US_DREG;
                // Extension-word register field. The reference reads
                // ext_data[15:12] here, exactly as it does for MOVEC
                // (eu_seq_decode.svh:3561) -- two independent instructions
                // agreeing makes [15:12] the project's effective convention
                // for the first extension word's register field, despite
                // eu_seq.sv's header describing [31:16] as the first word.
                // The discrepancy is real and still worth chasing through the
                // IFU drain path before the EX stage relies on it.
                uop.dst_reg     = bf_reads_dn ? ext[15:12] : rn_src_dn;
                // Memory-form bitfields defer EVERYTHING to the bf_mem FSM:
                // not just the flags but the Dn writeback too, so even
                // BFEXTU reports writes_reg=0 there.
                uop.writes_reg  = src_is_dn && (bf_reads_dn || bf_mutates);
                // Register-form bitfields set the flags at decode; the MEMORY
                // forms do not, because the bf_mem FSM owns them -- the same
                // RMW split as every other memory read-modify-write family.
                uop.updates_ccr = src_is_dn;
                uop.x_unchanged = 1'b1;
                // Which of the eight operations, and the whole specification
                // word: offset in [10:6], width in [4:0], the register field
                // BFINS inserts from in [15:12], and the two "this is in a Dn"
                // flags at [11] and [5]. The spec word is the FIRST extension
                // word, so which half of ext holds it depends on whether the EA
                // needed one too -- the same rule as MOVEM's mask.
                uop.subop       = {1'b0, bf_op};
                uop.imm         = (ea_words(ea_mode_w) == 3'd0)
                                ? {16'h0, ext[15:0]}
                                : {16'h0, ext[31:16]};
            end else if (ea_is_alt_mem && (f_ss == 2'b11) && e_mem_legal) begin
                // Memory shift/rotate: always one bit, always a word.
                uop.uclass      = UC_SHIFT;
                uop.unit        = UU_SHF;
                uop.alu_op      = e_mem_shf_op;
                uop.siz         = UZ_WORD;
                uop.src_kind    = US_IMM;
                uop.imm         = 32'd1;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
            end else if (f_ss_valid) begin
                // REGISTER form. instr[5:3] is NOT an EA mode here: bit 5
                // selects the count source and bits[4:3] the operation, so
                // testing it as one (src_is_dn) claimed only the ASL/ASR
                // immediate forms and silently dropped every LSL/LSR/ROL/ROR/
                // ROXL/ROXR and every register-count form -- most of group E.
                // ss != 11 is the real register-vs-memory discriminator; the
                // destination is always Dn from instr[2:0].
                uop.uclass      = UC_SHIFT;
                uop.unit        = UU_SHF;
                uop.alu_op      = e_shf_op;
                uop.siz         = f_siz;
                uop.src_kind    = e_regcnt ? US_DREG : US_IMM;
                uop.src_reg     = rn_dn;                       // count register
                uop.imm         = e_regcnt ? 32'h0 : f_q_imm;  // 0 means 8
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_src_dn;
                uop.writes_reg  = 1'b1;
                uop.updates_ccr = 1'b1;
            end
        end

        default: ;   // stays UC_UNIMPL
        endcase

        // How far the fetch unit must drain for this instruction. Branches
        // carry their displacement in the opcode unless the 8-bit field is
        // zero, in which case one extension word follows.
        // THIS IS A PRIORITY CHAIN AND IT STAYS ONE, though on weaker evidence
        // than this comment first claimed. 25 conditions deep, every one an equality against uclass or
        // subop, sitting directly between the opcode and the top level's
        // issue/drain: it looks exactly like something to flatten into a case
        // over uclass, a balanced tree six deep instead of a chain of 25. That
        // was written and proven byte-identical for all 65,536 opcodes, and
        // came out at 21.69 MHz against a baseline then believed to be 22.93.
        //
        // CORRECTION: the baseline's own spread over nine placement seeds is
        // 21.81-23.13 MHz and seeds 1-3 (the three used) are its three best, so
        // 21.69 is at the edge of the baseline's range and the change is
        // UNRESOLVED rather than measured slower. It stays reverted because it
        // showed no benefit, not because it was shown to hurt.
        //
        // If the chain really is better, the reason would be that its early
        // arms are cheap constants, so common cases exit in a few levels and
        // ABC9 maps that shape directly while a case makes every arm pay full
        // depth. Untested. See mh030p_ifu.sv's queue note for the companion
        // case.
        uop.ext_words     = (uop.uclass == UC_BRANCH)
                          // 0x00 is the word form (one displacement word)
                          // and 0xFF the LONG form (two). The long form is
                          // not claimed for EXECUTION, but its count still
                          // has to be right: the fetch unit drains
                          // 1 + ext_words even for an instruction the core
                          // declines, so a wrong count derails the stream
                          // after it.
                          ? ((instr[7:0] == 8'h00) ? 3'd1 :
                             (instr[7:0] == 8'hFF) ? 3'd2 : 3'd0)
                          : (uop.uclass == UC_DBCC) ? 3'd1   // displacement word
                          // TRAP #n, TRAPV and the whole A-line group have no
                          // operand at all; TRAPcc names its own operand size
                          // in the low three bits (010 word, 011 long, 100
                          // none), which is NOT an EA field even though it sits
                          // where one would be. TRAPF is 0x51FC -- mode 111
                          // reg 100, which reads as an immediate -- so without
                          // this it claimed an extension word and swallowed the
                          // instruction after it.
                          : ((uop.uclass == UC_TRAP)
                             && ((uop.subop == 4'd0) || (uop.subop == 4'd1)
                              || (uop.subop == 4'd5)))
                            ? 3'd0
                          // The system-control moves. MOVE #imm,SR is word-sized
                          // and takes exactly ONE extension word, but the
                          // generic immediate accounting sized it from a MOVE
                          // opcode's own size field and claimed two -- which
                          // swallowed the following instruction and left the SR
                          // holding half of it. The USP forms take none.
                          //
                          // Sixth instance of this shape. The lesson is that
                          // extension-word count belongs with each instruction's
                          // own decode, not derived from fields that only mean
                          // something for other instructions.
                          : (uop.uclass == UC_SYSCTL)
                            ? (((uop.subop == 4'd4) || (uop.subop == 4'd5))
                               ? 3'd0
                               : (ea_words(ea_mode_w)
                                  + (ea_is_imm ? 3'd1 : 3'd0)))
                          // RTS, RTE and RTR take no extension words. Their own
                          // low six bits read as an indexed EA, so the generic
                          // accounting claimed one -- harmless in practice only
                          // because a return's redirect flushes the queue before
                          // a miscount can be observed, which is exactly the kind
                          // of "got away with it" this check exists to end.
                          : (uop.uclass == UC_RETURN) ? 3'd0
                          // MOVEQ's immediate is IN the opcode.
                          : (uop.uclass == UC_MOVEQ) ? 3'd0
                          // A shift or rotate on a REGISTER has no extension
                          // word at all -- its low six bits are the count
                          // source, the operation and the register, not an EA.
                          // The memory forms do have a real EA.
                          : (uop.uclass == UC_SHIFT)
                            ? ((uop.reads_mem || uop.writes_mem)
                               ? ea_words(ea_mode_w) : 3'd0)
                          // MOVEP always carries a d16, and its own mode field
                          // is An-direct, so the generic EA accounting sees none.
                          : (uop.uclass == UC_MOVEP) ? 3'd1
                          // The whole F-line -- MMU, coprocessor and the F-line
                          // trap -- carries one extension word. None of it is
                          // executable here, which does NOT make the count
                          // irrelevant: the fetch unit drains 1 + ext_words even
                          // for an instruction the core declines, so a wrong
                          // count derails everything after it.
                          : ((uop.uclass == UC_MMU) || (uop.uclass == UC_COPROC))
                            ? 3'd1
                          // The F-line TRAP -- any CpID that is not the MMU's or
                          // the coprocessor's -- carries nothing.
                          : (f_group == 4'hF) ? 3'd0
                          // MUL/DIV with an immediate source: one word for the
                          // word forms, two for long. The generic accounting
                          // sized it from a MOVE opcode's field, which means
                          // nothing here.
                          : ((uop.uclass == UC_MULDIV) && ea_is_imm)
                            ? (uop.opnd_word ? 3'd1 : 3'd2)
                          // The group-0 immediate ALU family: ADDI, SUBI, ANDI,
                          // ORI, EORI, CMPI. Their immediate is ONE word for
                          // byte and word sizes and two for long, on top of
                          // whatever the destination EA needs. Only the long
                          // case was counted (imm_takes_ext), so CMPI.b and
                          // ADDI.b reported zero extension words and their own
                          // immediate was executed as the next instruction --
                          // which ran the program off its end past the STOP.
                          // Any ALU operation with an IMMEDIATE source, in any
                          // group: ADDI/SUBI/ANDI/ORI/EORI/CMPI (group 0, where
                          // the EA field is the destination) and the #imm forms
                          // of ADD/SUB/AND/OR/EOR/CMP and ADDA/SUBA/CMPA (groups
                          // 8-D, where the EA field itself says immediate). One
                          // word for byte and word operands, two for long --
                          // from the uop's OWN size, not from a MOVE opcode's
                          // size field, which is what the generic accounting was
                          // reading and which means nothing here.
                          : ((uop.uclass == UC_ALU) && (uop.src_kind == US_IMM)
                             && ((f_group == 4'h0) || ea_is_imm))
                            ? ((((uop.siz == UZ_LONG) && !uop.opnd_word)
                                ? 3'd2 : 3'd1)
                               + ((f_group == 4'h0) ? ea_words(ea_mode_w) : 3'd0))
                          // CHK's bound can be an immediate too, with the same
                          // rule.
                          : ((uop.uclass == UC_TRAP) && (uop.subop == 4'd2))
                            ? ((ea_is_imm
                                ? ((uop.siz == UZ_LONG) ? 3'd2 : 3'd1) : 3'd0)
                               + (ea_is_imm ? 3'd0 : ea_words(ea_mode_w)))
                          // A STATIC bit operation carries its bit number in an
                          // immediate word, on top of whatever the EA needs;
                          // the dynamic forms take it from a register. Neither
                          // was counted, so even BTST #n,Dn -- a two-word
                          // instruction -- reported zero.
                          //
                          // BTST Dn,#imm is its own case on top of that: ea_mode
                          // is deliberately NONE (no real addressing mode, see
                          // the decode branch) but dst_kind==US_MEM flags that
                          // the extension word carrying the tested value still
                          // has to be drained, which ea_words(NONE) reports as
                          // zero.
                          : (uop.uclass == UC_BITOP)
                            ? (((uop.subop == 4'd1) ? 3'd1 : 3'd0)
                               + ea_words(ea_mode_w)
                               + (((uop.ea_mode == UEA_NONE)
                                   && (uop.dst_kind == US_MEM)) ? 3'd1 : 3'd0))
                          // STOP's operand is the SR value to load.
                          : ((uop.uclass == UC_NOP) && (uop.subop == 4'd2))
                            ? 3'd1
                          : ((uop.uclass == UC_TRAP) && (uop.subop == 4'd4))
                            ? ((f_reg == 3'b010) ? 3'd1 :
                               (f_reg == 3'b011) ? 3'd2 : 3'd0)
                          // LINK carries its frame size in an extension word;
                          // UNLK carries nothing.
                          : ((uop.uclass == UC_LINK) && (uop.subop == 4'd0))
                            ? 3'd1
                          // MOVEM: the mask word plus whatever the EA needs.
                          : (uop.uclass == UC_MOVEM)
                            ? (3'd1 + ea_words(ea_mode_w))
                          // A bit field's specification word is not an EA word
                          // and is not optional -- same shape as MOVEM's mask.
                          // Without this a Dn-direct bit field reported ZERO
                          // extension words and its own specification was
                          // decoded as the following instruction.
                          : (uop.uclass == UC_BITFIELD)
                            ? (3'd1 + ea_words(ea_mode_w))
                          // MOVEC names its control register in an extension
                          // word and has no EA at all, so its own low six bits
                          // must NOT be counted as one. MOVES (sub-op 0) does
                          // have a real EA on top of its extension word.
                          : (uop.uclass == UC_MOVEC)
                            ? ((uop.subop == 4'd0)
                               ? (3'd1 + ea_words(ea_mode_w)) : 3'd1)
                          // CAS names its two registers in an extension word;
                          // CAS2 uses two. TAS (sub-op 0) has none, and its own
                          // EA words are already counted.
                          : ((uop.uclass == UC_ATOMIC) && (uop.subop == 4'd1))
                            ? (3'd1 + ea_words(ea_mode_w))
                          : ((uop.uclass == UC_ATOMIC) && (uop.subop == 4'd2))
                            ? 3'd2
                          // CMP2/CHK2 name their register in an extension word
                          // on top of whatever the EA needs.
                          : ((uop.uclass == UC_TRAP) && (uop.subop == 4'd3))
                            ? (3'd1 + ea_words(ea_mode_w))
                          // An instruction that declares NO effective address
                          // cannot be consuming extension words for one, but
                          // ea_words_total is computed from the raw opcode's EA
                          // field regardless of whether the decoded uop uses
                          // it -- so MOVE USP,A2 (0x4E6A, low bits 101010,
                          // which read as (d16,An)) claimed a displacement word
                          // and swallowed the instruction after it. Harmless
                          // for RTS/RTE, whose own redirect flushes the queue
                          // before the miscount can matter, which is why it
                          // survived this long. Immediates are still counted:
                          // those are real, and independent of the EA field.
                          : ((uop.ea_mode == UEA_NONE)
                             && (uop.dst_ea_mode == UEA_NONE))
                            ? (imm_words + dst_ea_words)
                          : ea_words_total;

        // ── Full-format extension words ─────────────────────────────────────
        // The chain above counts the BRIEF-format case: one word per indexed EA.
        // A full-format word carries a base displacement and an outer
        // displacement on top of that, so the count has to grow -- and a wrong
        // count derails the instruction stream rather than giving a wrong answer.
        //
        // The offset of the EA's own first extension word is what makes this
        // delicate. It is derived by subtraction from the BRIEF count, which is a
        // function of the opcode alone, so it does NOT depend on the full-format
        // extras being computed here -- full format only ever adds words AFTER
        // that first one. That is what keeps this out of a circular definition.
        ew_lead = (uop.ext_words > (src_ea_words + dst_ea_words))
                  ? (uop.ext_words - src_ea_words - dst_ea_words) : 3'd0;

        // Hoisted into variables because Icarus rejects a bit-select applied
        // to a function call.
        ew_srcw = rawword(ew_lead);

        src_ff = ((uop.ea_mode == UEA_AN_IDX) || (uop.ea_mode == UEA_PC_IDX))
                 && ew_srcw[8];

        // How many words the SOURCE EA really occupies, full-format extras
        // included -- which is what the DESTINATION's own offset has to step over.
        ew_src_total = src_ea_words + (src_ff ? ff_extra(ew_srcw) : 3'd0);
        ew_dst_at    = ew_lead + ew_src_total;
        ew_dstw      = rawword(ew_dst_at);
        dst_ff       = (uop.dst_ea_mode == UEA_AN_IDX) && ew_dstw[8];

        // Base displacements follow each EA's own extension word.
        bd_w1  = rawword(ew_lead + 3'd1);
        bd_w2  = rawword(ew_lead + 3'd2);
        dbd_w1 = rawword(ew_dst_at + 3'd1);
        dbd_w2 = rawword(ew_dst_at + 3'd2);

        // Only GENUINE memory indirection is undecodable here. A full-format word
        // with I/IS == 000 is plain arithmetic and is handled below.
        uop.ea_full_fmt = (src_ff && ff_indirect(ew_srcw))
                       || (dst_ff && ff_indirect(ew_dstw));

        // Full-format base and index suppression.
        if (src_ff) begin
            uop.ea_bs = ew_srcw[7];
            uop.ea_is = ew_srcw[6];
        end
        if (dst_ff) begin
            uop.dst_ea_bs = ew_dstw[7];
            uop.dst_ea_is = ew_dstw[6];
        end
        uop.ext_words   = uop.ext_words
                        + (src_ff ? ff_extra(ew_srcw) : 3'd0)
                        + (dst_ff ? ff_extra(ew_dstw) : 3'd0);
        // The leading count and both EA offsets above were all derived from the
        // BRIEF word count, which is correct and must stay that way: they locate
        // the words that TELL us how many extras there are, so deriving them from
        // the adjusted total would be circular. The central fill-in below reuses
        // them rather than recomputing -- recomputing from the adjusted total made
        // sxw read the base-displacement word instead of the EA extension word,
        // which silently wrecked the displacement, index register and scale
        // together. Found via a cosim trace: `add.l ($100,a0,d1.l),d2` read A0
        // with no displacement and no index at all.

        // ── Central EA field fill-in ───────────────────────────────────────
        // Deliberately LAST, because it needs uop.ext_words: extension words
        // are numbered from 0 in instruction order, and each side reads the one
        // at its own offset -- whatever precedes the EA fields (an immediate,
        // a register-spec word) comes first, then the SOURCE's own words, then
        // the DESTINATION's. Deriving the leading count by subtraction reuses
        // the ext_words chain above, which is swept, instead of restating the
        // per-family exceptions a second time and getting a different answer.
        //
        // Only indices 0-2 are reachable (ext carries two words, q3 the
        // third), which is what ea_disp_valid reports on.
        ew_tot  = uop.ext_words;
        sxw     = xword(ea_slot_is_dst ? ew_dst_at : ew_lead, ew_tot);
        dxw     = xword(ew_dst_at, ew_tot);

        // Every branch above sets ea_mode; the displacement and index fields
        // are derived from it exactly once, here. Doing it per-branch meant
        // several families silently carried ea_disp = 0 -- caught the moment
        // the sweep started comparing these fields. One place to be right
        // beats twenty places to remember, which is the same reasoning
        // rtl/opcode_fields.sv exists for.
        if ((uop.ea_mode == UEA_AN_D16) || (uop.ea_mode == UEA_PC_D16)
            || (uop.ea_mode == UEA_ABS_W))
            uop.ea_disp = {{16{sxw[15]}}, sxw};
        else if ((uop.ea_mode == UEA_AN_IDX) || (uop.ea_mode == UEA_PC_IDX))
            // Brief format carries an 8-bit displacement in the extension word
            // itself. Full format carries a base displacement in the NEXT one or
            // two words instead, and its own low byte means something else
            // entirely (BD SIZE / I/IS), so it must not be sign-extended as a
            // displacement.
            uop.ea_disp = !src_ff                    ? {{24{sxw[7]}}, sxw[7:0]}
                        : (ff_bd_words(sxw) == 3'd1) ? {{16{bd_w1[15]}}, bd_w1}
                        : (ff_bd_words(sxw) == 3'd2) ? {bd_w1, bd_w2}
                                                     : 32'h0;   // null bd
        else if (uop.ea_mode == UEA_ABS_L)
            uop.ea_disp = {sxw, xword((ea_slot_is_dst ? ew_dst_at : ew_lead)
                                      + 3'd1, ew_tot)};
        else
            // CLEARED for every mode that has no displacement. The fill-in only
            // OVERRODE the displaced modes, and several branches above assign
            // ea_disp unconditionally -- so (A2)+ carried whatever extension
            // word happened to be there and read from base+disp instead of base.
            // Visible only when the OTHER side of a memory-to-memory move
            // supplied that word.
            uop.ea_disp = 32'h0;

        if ((uop.ea_mode == UEA_AN_IDX) || (uop.ea_mode == UEA_PC_IDX)) begin
            uop.ea_idx_reg   = sxw[15:12];
            uop.ea_idx_long  = sxw[11];
            uop.ea_idx_scale = sxw[10:9];
        end

        // The DESTINATION's own displacement and index, from the same
        // derivation at its own offset. The displacement was never filled in at
        // all, so a memory-to-memory MOVE with a displaced destination --
        // MOVE.b (A2)+,(d16,A2) -- computed its write address as the bare base
        // register; and with a displacement at BOTH ends both sides read the
        // same half of `ext`.
        if ((uop.dst_ea_mode == UEA_AN_D16) || (uop.dst_ea_mode == UEA_ABS_W))
            uop.dst_ea_disp = {{16{dxw[15]}}, dxw};
        else if (uop.dst_ea_mode == UEA_AN_IDX)
            uop.dst_ea_disp = !dst_ff                    ? {{24{dxw[7]}}, dxw[7:0]}
                            : (ff_bd_words(dxw) == 3'd1) ? {{16{dbd_w1[15]}}, dbd_w1}
                            : (ff_bd_words(dxw) == 3'd2) ? {dbd_w1, dbd_w2}
                                                         : 32'h0;
        else if (uop.dst_ea_mode == UEA_ABS_L)
            uop.dst_ea_disp = {dxw, xword(ew_dst_at + 3'd1, ew_tot)};
        else
            uop.dst_ea_disp = 32'h0;

        if (uop.dst_ea_mode == UEA_AN_IDX) begin
            uop.dst_ea_idx_reg   = dxw[15:12];
            uop.dst_ea_idx_long  = dxw[11];
            uop.dst_ea_idx_scale = dxw[10:9];
        end

        // Every displacement word sits at index 0, 1 or 2, so all three are
        // reachable. A fourth is not, which rules out an absolute long at
        // BOTH ends and a long immediate feeding an absolute long.
        uop.ea_disp_valid = (ew_tot <= 3'd3);
    end

endmodule

`default_nettype wire

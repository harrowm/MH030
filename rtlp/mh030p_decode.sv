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
    input  wire [31:0] ext,      // extension words, as a 32-bit immediate
    output uop_t       uop
);

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
    wire ea_is_mem = (ea_mode_w != UEA_NONE);
    wire ea_src_ok = ea_is_mem || ea_is_imm;

    // Index fields live in the first extension word (bit 8 there selects full
    // format, which is P3 -- the brief form is what is decoded here).
    wire [3:0] ea_xn      = ext[31:28];
    wire       ea_xn_long = ext[27];
    wire [1:0] ea_xn_scl  = ext[26:25];
    wire [31:0] ea_d16 = {{16{ext[31]}}, ext[31:16]};
    wire [31:0] ea_d8  = {{24{ext[23]}}, ext[23:16]};

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

    // Control addressing modes (no Dn/An/(An)+/-(An)/#imm): what LEA, PEA,
    // JMP and JSR accept.
    wire ea_is_control = (ea_mode_w == UEA_AN_IND) || (ea_mode_w == UEA_AN_D16)
                      || (ea_mode_w == UEA_AN_IDX) || (ea_mode_w == UEA_ABS_W)
                      || (ea_mode_w == UEA_ABS_L)  || (ea_mode_w == UEA_PC_D16)
                      || (ea_mode_w == UEA_PC_IDX);
    // Alterable memory: everything writable, i.e. not PC-relative.
    wire ea_is_alt_mem = ea_is_mem && (ea_mode_w != UEA_PC_D16)
                                   && (ea_mode_w != UEA_PC_IDX);

    // Group 4 sub-families, all keyed on g4_op (= instr[11:8]) plus [7:6].
    wire [1:0] g4_b76   = instr[7:6];
    wire g4_is_nbcd  = (g4_op == 4'h8) && (g4_b76 == 2'b00);
    wire g4_is_pea   = (g4_op == 4'h8) && (g4_b76 == 2'b01) && ea_is_control;
    wire g4_is_tas   = (g4_op == 4'hA) && (g4_b76 == 2'b11) && ea_is_alt_mem;
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
                  && ea_src_ok && (g4_op != 4'hE);

    // MOVE to/from SR/CCR: 0x40C0/0x42C0 (from) and 0x44C0/0x46C0 (to).
    wire g4_is_sr_move = (g4_b76 == 2'b11) && !instr[8]
                      && ((g4_op == 4'h0) || (g4_op == 4'h2)
                       || (g4_op == 4'h4) || (g4_op == 4'h6));
    wire g4_sr_to_ea = (g4_op == 4'h0) || (g4_op == 4'h2);

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

    // ── Decode ──────────────────────────────────────────────────────────────
    always_comb begin
        uop = uop_clear();
        uop.valid  = 1'b1;
        uop.uclass = UC_UNIMPL;   // honest default; overridden on a real match

        case (f_group)
        // ── ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm,Dn ────────────────────────────
        4'h0: begin
            if ((g0_is_dynbit || g0_is_statbit) && src_is_dn) begin
                // Dn destination: the bit number is mod 32 and the operand is
                // a full longword (memory forms are byte-sized -- P3).
                uop.uclass      = UC_BITOP;
                uop.unit        = UU_BIT;
                uop.alu_op      = {2'b00, b_op};
                uop.siz         = UZ_LONG;
                uop.src_kind    = g0_is_dynbit ? US_DREG : US_IMM;
                uop.src_reg     = rn_dn;
                uop.imm         = ext;
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
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
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

                // Source
                if (ea_src_ok) begin
                    uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                    uop.imm         = ext;
                    uop.ea_mode     = ea_mode_w;
                    uop.ea_reg      = rn_src_an;
                    uop.ea_idx_reg  = ea_xn;
                    uop.ea_idx_long = ea_xn_long;
                    uop.ea_idx_scale= ea_xn_scl;
                    uop.ea_disp     = (ea_mode_w == UEA_AN_IDX) ? ea_d8 : ea_d16;
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
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
                uop.ea_disp     = (ea_mode_w == UEA_AN_IDX) ? ea_d8 : ea_d16;
                uop.reads_mem   = !g4_is_clr;
                uop.writes_mem  = !g4_is_tst;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = g4_is_tst || g4_is_clr;
                uop.x_unchanged = (g4_is_tst || g4_is_clr || g4_is_not);
            end else if (g4_is_chk) begin
                uop.uclass      = UC_TRAP;
                uop.unit        = UU_NONE;
                uop.siz         = (g4_b76 == 2'b10) ? UZ_WORD : UZ_LONG;
                uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = !ea_is_imm;
                uop.dst_kind    = US_DREG;
                uop.dst_reg     = rn_dn;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b1;
                uop.traps       = 1'b1;
            // MOVE CCR,<ea> (0x42xx) is restricted to the Dn form here
            // because the REFERENCE decoder only implements that one and
            // reports every memory destination as illegal. Memory
            // destinations are legal on 68010+/68030, so this looks like a
            // genuine gap in rtl/ -- recorded rather than silently papered
            // over, and deliberately not claimed, since an opcode the
            // reference rejects is one this sweep cannot validate.
            end else if (g4_is_sr_move
                         && ((g4_op == 4'h2) ? src_is_dn
                                             : (ea_is_alt_mem || src_is_dn
                                                || (!g4_sr_to_ea && ea_src_ok)))) begin
                uop.uclass      = UC_SYSCTL;
                uop.unit        = UU_MOVE;
                // MOVE #imm,CCR is byte-sized in the reference decoder (CCR
                // is 8 bits and the immediate's high byte is ignored), while
                // MOVE <mem>,CCR and every SR form are word-sized. Only the
                // immediate-to-CCR combination differs.
                uop.siz         = (ea_is_imm && (g4_op == 4'h4)) ? UZ_BYTE : UZ_WORD;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
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
                uop.unit        = UU_MOVE;
                uop.siz         = UZ_BYTE;
                uop.dst_kind    = US_MEM;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
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
                uop.siz         = UZ_LONG;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
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
                uop.imm         = {28'h0, sys_lo};
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
            end else if (sys_is_usp || sys_is_uspr) begin
                uop.uclass      = UC_SYSCTL;
                uop.unit        = UU_MOVE;   // reference decoder: unit=MOVE
                uop.siz         = UZ_LONG;
                uop.src_kind    = sys_is_uspr ? US_USP : US_AREG;
                uop.dst_kind    = sys_is_uspr ? US_AREG : US_USP;
                uop.dst_reg     = rn_src_an;
                uop.writes_reg  = sys_is_uspr;
            end else if (sys_is_misc) begin
                // 0x4E70 RESET, 71 NOP, 72 STOP, 73 RTE, 74 RTD, 75 RTS,
                // 76 TRAPV, 77 RTR.
                uop.unit        = UU_NONE;
                uop.siz         = UZ_LONG;
                case (sys_lo)
                    4'h3, 4'h5, 4'h7: uop.uclass = UC_RETURN;   // RTE/RTS/RTR
                    4'h6: begin uop.uclass = UC_TRAP; uop.traps = 1'b1; end
                    4'h0, 4'h1, 4'h2: uop.uclass = UC_NOP;      // RESET/NOP/STOP
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
            if (g5_is_scc) begin
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
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
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

        // ── Bcc / BRA / BSR ─────────────────────────────────────────────────
        4'h6: begin
            uop.uclass      = UC_BRANCH;
            uop.unit        = UU_NONE;
            uop.siz         = UZ_LONG;   // reference decoder: siz=long
            uop.cond        = f_cond;     // 0000 = BRA, 0001 = BSR
            uop.x_unchanged = 1'b1;
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
            end else if (g_is_muldiv && src_is_dn) begin
                uop.uclass      = UC_MULDIV;
                uop.unit        = (f_group == 4'hC) ? UU_MUL : UU_DIV;
                uop.alu_op      = g_md_op;     // md_op shares the alu_op field
                // Word forms, but the WRITTEN result is a full longword: a
                // 32-bit product for MUL, packed {remainder,quotient} for
                // DIV. uop.siz is a write size, so it is long -- the same
                // operand-size-vs-write-size distinction as MOVEA.W.
                uop.siz         = UZ_LONG;
                uop.sext_src    = 1'b0;
                uop.src_kind    = US_DREG;
                uop.src_reg     = rn_src_dn;
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
                if (ea_src_ok) begin
                    uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                    uop.imm         = ext;
                    uop.ea_mode     = ea_mode_w;
                    uop.ea_reg      = rn_src_an;
                    uop.ea_idx_reg  = ea_xn;
                    uop.ea_idx_long = ea_xn_long;
                    uop.ea_idx_scale= ea_xn_scl;
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
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
            end else if (ea_src_ok && !f_dir && f_ss_valid) begin
                // <ea>,Dn with a MEMORY or IMMEDIATE source. The destination
                // is always Dn, so dest_reg stays well defined. The Dn,<ea>
                // direction (memory destination) is P3.
                uop.uclass      = UC_ALU;
                uop.unit        = UU_ALU;
                uop.siz         = f_siz;
                uop.alu_op      = (f_group == 4'h8) ? UA_OR  :
                                  (f_group == 4'h9) ? UA_SUB :
                                  (f_group == 4'hB) ? UA_CMP :
                                  (f_group == 4'hC) ? UA_AND : UA_ADD;
                uop.src_kind    = ea_is_imm ? US_IMM : US_MEM;
                uop.imm         = ext;
                uop.ea_mode     = ea_mode_w;
                uop.ea_reg      = rn_src_an;
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
                uop.ea_disp     = (ea_mode_w == UEA_AN_IDX) ? ea_d8 : ea_d16;
                uop.reads_mem   = !ea_is_imm;
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
            if (ea_is_alt_mem && (f_ss == 2'b11) && e_mem_legal) begin
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
                uop.ea_idx_reg  = ea_xn;
                uop.ea_idx_long = ea_xn_long;
                uop.ea_idx_scale= ea_xn_scl;
                uop.reads_mem   = 1'b1;
                uop.writes_mem  = 1'b1;
                uop.writes_reg  = 1'b0;
                uop.updates_ccr = 1'b0;
            end else if (src_is_dn && f_ss_valid) begin
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
    end

endmodule

`default_nettype wire

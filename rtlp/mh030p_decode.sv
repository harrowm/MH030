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

    // ── Decode ──────────────────────────────────────────────────────────────
    always_comb begin
        uop = uop_clear();
        uop.valid  = 1'b1;
        uop.uclass = UC_UNIMPL;   // honest default; overridden on a real match

        case (f_group)
        // ── ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm,Dn ────────────────────────────
        4'h0: begin
            if (g0_is_alu_imm && src_is_dn && f_ss_valid) begin
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
            if ((src_is_dn || src_is_an) && (dst_is_dn || dst_is_an)) begin
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

        // ── NEG/NEGX/NOT/CLR/TST/EXT/SWAP, Dn ───────────────────────────────
        4'h4: begin
            if (g4_is_swap) begin
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
            if (src_is_dn && f_ss_valid) begin
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
            // dir=1 means "Dn,<ea>", whose <ea> must be MEMORY for the plain
            // ALU ops. With a register EA that encoding space belongs to
            // other families entirely: SBCD (8), SUBX (9), ABCD/EXG (C),
            // ADDX (D) -- all UC_UNIMPL for now. Group B is the genuine
            // exception: B/dir=1/mode=000 really is EOR Dn,Dy (mode=001
            // there is CMPM, already excluded by src_is_dn).
            // The sweep caught this at 0x8101 (SBCD), which the reference
            // decoder reports as unit=UU_BCD.
            if (src_is_dn && f_ss_valid && ((f_group == 4'hB) || !f_dir)) begin
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
            if (src_is_dn && f_ss_valid) begin
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

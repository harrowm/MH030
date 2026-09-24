`ifndef MH030P_UOP_SVH
`define MH030P_UOP_SVH
// =============================================================================
// MH030-P micro-operation definition
//
// The pipelined core (rtlp/) decodes each 68k instruction into one or more
// micro-operations. A uop describes exactly what ONE pipeline pass does, so
// the EX stage has a single uniform shape instead of the ~20 bespoke
// multi-cycle FSMs rtl/eu_seq_execute.svh carries today.
//
// WHY THIS SHAPE -- measured, not guessed. rtl/eu_seq_decode.svh emits 171
// distinct dec_* signals. 76 of them are `dec_is_<family>` discriminators,
// 15 are register selectors, and most of the remaining ~80 are
// family-specific fields that are mutually exclusive by construction
// (dec_movem_*, dec_movep_*, dec_bf_*, dec_memind_*, dec_pflush_*, ...).
// That decomposes naturally into: one CLASS field replacing the 76 flags, a
// small orthogonal operand set shared by every class, and a per-family
// payload overlaid on the same bits.
//
// TOOLCHAIN CONSTRAINTS -- each one proven with a scratch compile through
// iverilog -g2012, sv2v AND yosys before this file was written, following
// rtl/opcode_fields.sv's own precedent ("zero SystemVerilog package
// precedent exists anywhere in this repo, so the mechanism was proven with a
// standalone scratch compile first rather than assumed"):
//
//   * NO `typedef enum` for uop fields. Icarus 13 demands an explicit cast on
//     every assignment that is not a bare enum literal -- even `x ? A : B` --
//     which would put a cast on essentially every line of the decoder. Plain
//     `logic [n:0]` fields plus localparam constants need no casts anywhere,
//     and match the existing repo style (UNIT_NONE = 3'h7 in eu_seq.sv).
//   * NO `'0` and NO `'{field: value}` assignment patterns. Icarus 13 rejects
//     both on a packed struct. Use uop_clear() below, then override fields.
//   * Constant bit-selects must be hoisted into `wire` assigns outside
//     always_* blocks (the workaround rtl/eu_mul_div.sv already documents).
//   * `struct packed`, struct ports and field selects are all fine.
//
// ENCODING COMPATIBILITY: every encoding shared with rtl/ is reproduced
// EXACTLY, never "tidied up". The sizes are deliberately not in a natural
// order, the units are deliberately not alphabetical. rtl/eu_alu.sv and
// friends are reused verbatim by this core (plan A5 Tier 1), and the BIU
// speaks the same SIZ encoding on real pins. A second, prettier encoding
// would mean a conversion layer, and conversion layers are where this
// project has historically found bugs.
// =============================================================================

// ── Transfer size. MUST match rtl/eu_seq_decode.svh's dec_siz and the SIZ
//    pin encoding in CLAUDE.md. 00=long is not a typo.
localparam logic [1:0] UZ_LONG = 2'b00,
                       UZ_BYTE = 2'b01,
                       UZ_WORD = 2'b10,
                       UZ_LINE = 2'b11;   // 16-byte burst (BIU only)

// ── Functional unit. MUST match eu_seq.sv's UNIT_* localparams exactly.
localparam logic [2:0] UU_ALU  = 3'h0,
                       UU_SHF  = 3'h1,
                       UU_MUL  = 3'h2,
                       UU_DIV  = 3'h3,
                       UU_MOVE = 3'h4,
                       UU_BCD  = 3'h5,
                       UU_BIT  = 3'h6,
                       UU_NONE = 3'h7;

// ── ALU operation. MUST match rtl/eu_alu.sv's ALU_* localparams exactly;
//    that module is reused verbatim.
localparam logic [3:0] UA_ADD  = 4'h0, UA_ADDX = 4'h1, UA_SUB = 4'h2,
                       UA_SUBX = 4'h3, UA_NEG  = 4'h4, UA_NEGX = 4'h5,
                       UA_AND  = 4'h6, UA_OR   = 4'h7, UA_EOR  = 4'h8,
                       UA_NOT  = 4'h9, UA_CMP  = 4'hA, UA_TST  = 4'hB,
                       UA_CLR  = 4'hC;

// ── uop class: replaces the 76 dec_is_* family flags.
//    Only the classes P2 (integer register-direct core) actually executes are
//    defined as real work; the rest are named here so the decoder can
//    classify the whole opcode space from the start and report UC_UNIMPL
//    honestly rather than silently mis-decoding. Later phases turn them into
//    real uop sequences -- see the plan's P4/P5.
localparam logic [5:0]
    UC_INVALID  = 6'd0,   // not a legal opcode
    UC_UNIMPL   = 6'd1,   // legal, decoded, not yet executable by this core
    UC_ALU      = 6'd2,   // ADD/SUB/AND/OR/EOR/CMP/NEG/NOT/CLR/TST (+I forms)
    UC_MOVE     = 6'd3,   // MOVE / MOVEA
    UC_SHIFT    = 6'd4,   // ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR
    UC_MULDIV   = 6'd5,   // MULU/MULS/DIVU/DIVS
    UC_BITOP    = 6'd6,   // BTST/BCHG/BCLR/BSET
    UC_BCD      = 6'd7,   // ABCD/SBCD/NBCD
    UC_EXT      = 6'd8,   // EXT/EXTB
    UC_SWAP     = 6'd9,   // SWAP
    UC_EXG      = 6'd10,  // EXG
    UC_MOVEQ    = 6'd11,  // MOVEQ
    UC_ADDQ     = 6'd12,  // ADDQ/SUBQ
    UC_SCC      = 6'd13,  // Scc
    UC_BRANCH   = 6'd14,  // Bcc/BRA/BSR
    UC_DBCC     = 6'd15,  // DBcc
    UC_JMP      = 6'd16,  // JMP/JSR
    UC_RETURN   = 6'd17,  // RTS/RTR/RTE
    UC_LEA      = 6'd18,  // LEA/PEA
    UC_LINK     = 6'd19,  // LINK/UNLK
    UC_TRAP     = 6'd20,  // TRAP/TRAPV/TRAPcc/CHK/CHK2
    UC_SYSCTL   = 6'd21,  // MOVE to/from SR/CCR/USP, ANDI/ORI/EORI to SR/CCR
    UC_MOVEM    = 6'd22,  // MOVEM
    UC_MOVEP    = 6'd23,  // MOVEP
    UC_BITFIELD = 6'd24,  // BFxxx
    UC_PACK     = 6'd25,  // PACK/UNPK
    UC_ATOMIC   = 6'd26,  // TAS/CAS/CAS2
    UC_CACHE    = 6'd27,  // CINV/CPUSH via MOVEC/CACR
    UC_MMU      = 6'd28,  // PFLUSH/PLOAD/PMOVE/PTEST
    UC_COPROC   = 6'd29,  // cpBcc/cpDBcc/cpScc/cpTRAPcc/cpSAVE/cpRESTORE
    UC_NOP      = 6'd30,  // NOP/RESET/STOP/ILLEGAL/BKPT
    UC_MOVEC    = 6'd31,  // MOVEC/MOVES
    UC_ADDX     = 6'd32;  // ADDX/SUBX (X-chained, distinct sequencing)

// ── Operand source kind (orthogonal to class).
localparam logic [2:0] US_NONE = 3'd0,  // no operand
                       US_DREG = 3'd1,  // Dn
                       US_AREG = 3'd2,  // An
                       US_IMM  = 3'd3,  // immediate in uop.imm
                       US_MEM  = 3'd4,  // memory at the computed EA
                       US_SR   = 3'd5,  // SR/CCR
                       US_USP  = 3'd6;  // USP

// ── Effective-address mode. Mirrors the 68k mode/reg encoding rather than
//    inventing a new one, so it stays checkable against the opcode directly.
localparam logic [3:0] UEA_NONE     = 4'd0,   // operand is not in memory
                       UEA_AN_IND   = 4'd1,   // (An)
                       UEA_AN_POST  = 4'd2,   // (An)+
                       UEA_AN_PRE   = 4'd3,   // -(An)
                       UEA_AN_D16   = 4'd4,   // (d16,An)
                       UEA_AN_IDX   = 4'd5,   // (d8,An,Xn) and full format
                       UEA_ABS_W    = 4'd6,   // (xxx).W
                       UEA_ABS_L    = 4'd7,   // (xxx).L
                       UEA_PC_D16   = 4'd8,   // (d16,PC)
                       UEA_PC_IDX   = 4'd9,   // (d8,PC,Xn) and full format
                       UEA_MEMIND   = 4'd10;  // ([bd,An],Xn,od) memory-indirect

// ── The micro-operation.
//
// `first`/`last` bracket the uop sequence belonging to one architectural
// instruction. A single-uop instruction has both set. They are what lets the
// EX stage stay uniform while MOVEM, CAS2 and friends expand to many passes
// (plan P5), and what the exception logic needs to know whether it is at an
// instruction boundary -- which is exactly the distinction the $A vs $B
// stack frame formats turn on.
typedef struct packed {
    logic        valid;
    logic [5:0]  uclass;
    logic [2:0]  unit;
    logic [3:0]  alu_op;
    logic [1:0]  siz;

    // Operands. Register numbers use the existing 4-bit convention:
    // 0-7 = D0-D7, 8-15 = A0-A7 (rtl/eu_regfile.sv's rd_a_sel).
    logic [2:0]  src_kind;
    logic [3:0]  src_reg;
    logic [2:0]  dst_kind;
    logic [3:0]  dst_reg;
    logic [31:0] imm;

    // Effective address. `ea_reg` is An for the An-relative modes, Xn's
    // register for indexed modes is in ea_idx_reg.
    logic [3:0]  ea_mode;
    logic [3:0]  ea_reg;
    logic [3:0]  ea_idx_reg;
    logic        ea_idx_long;    // Xn.L (1) vs Xn.W (0)
    logic [1:0]  ea_idx_scale;   // 1/2/4/8 as 00/01/10/11
    logic [31:0] ea_disp;

    // Side effects.
    logic        writes_reg;
    logic        updates_ccr;
    logic        ea_disp_valid;  // ea_disp/ea_idx_* are trustworthy. False when
                                 // the instruction has several extension words
                                 // and this decoder cannot yet say which one
                                 // holds the displacement -- that needs the
                                 // ext_count logic m68030_seq.sv carries.
    logic        sext_src;       // sign-extend a word source to 32 bits
                                 // (MOVEA.W / ADDA.W / CMPA.W: the OPERAND is
                                 // a word but the WRITE is a full longword)
    logic        x_unchanged;    // CCR update leaves X alone (CMP/TST/...)
    logic        reads_mem;
    logic        writes_mem;

    // Sequencing.
    logic        first;
    logic        last;
    logic        traps;          // may raise an exception in EX

    // Condition code selector for Bcc/DBcc/Scc/TRAPcc.
    logic [3:0]  cond;
} uop_t;

// Field-by-field clear. A function rather than a constant because Icarus 13
// accepts neither `'0` nor `'{...}` on a packed struct containing this many
// fields. Call it first, then override -- the same "defaults then override"
// shape rtl/eu_seq_decode.svh already uses.
function automatic uop_t uop_clear();
    uop_t u;
    u.valid        = 1'b0;
    u.uclass       = UC_INVALID;
    u.unit         = UU_NONE;
    u.alu_op       = UA_ADD;
    u.siz          = UZ_LONG;
    u.src_kind     = US_NONE;
    u.src_reg      = 4'h0;
    u.dst_kind     = US_NONE;
    u.dst_reg      = 4'h0;
    u.imm          = 32'h0;
    u.ea_mode      = UEA_NONE;
    u.ea_reg       = 4'h0;
    u.ea_idx_reg   = 4'h0;
    u.ea_idx_long  = 1'b0;
    u.ea_idx_scale = 2'b00;
    u.ea_disp      = 32'h0;
    u.writes_reg   = 1'b0;
    u.updates_ccr  = 1'b0;
    u.ea_disp_valid= 1'b0;
    u.sext_src     = 1'b0;
    u.x_unchanged  = 1'b0;
    u.reads_mem    = 1'b0;
    u.writes_mem   = 1'b0;
    u.first        = 1'b1;
    u.last         = 1'b1;
    u.traps        = 1'b0;
    u.cond         = 4'h0;
    uop_clear      = u;
endfunction

`endif

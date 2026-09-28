`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P integer core -- plan P2 scope: register-direct operands only, no
// memory operands and no exceptions. This exists to answer one question, the
// go/no-go the whole rewrite rests on: what Fmax does a genuinely staged core
// reach, against the 13.78 MHz the existing design measures?
//
// FOUR STAGES, each a real register boundary:
//
//   ID   decode (combinational) -> registered uop; register-file addresses
//        issued this cycle
//   AG   register data arrives (the read was a clock boundary, not a cone);
//        the effective address is computed on its own adder and a memory
//        request is issued FROM REGISTERS
//   EX   memory data has arrived (or the stage stalls until it has);
//        forwarding mux; ALU/shifter; result registered
//   WB   commit to the register file and the CCR
//
// AG exists so the address adder does not share a tick with the register
// file read and the ALU, which is where rtl/ puts it -- one leg of the
// ~3600-hop chain Phase 284 traced. OF is folded into AG rather than given a
// stage of its own: the request already leaves from flip-flops, so it is
// a clock boundary, and a separate stage would add latency without cutting
// any path.
//
// THE BUS CONTRACT (plan A4) is the deliberate divergence from rtl/: the
// request leaves from flip-flops and the ack is consumed into flip-flops.
// No preview_ok, no zero-gap dispatch, so no 17-way ack-dependent mux
// select in the middle of the longest path. Consecutive bus cycles may be
// separated by an idle tick where rtl/ had none; what happens WITHIN a
// cycle is the BIU's business and is unchanged.
//
// WHAT THIS CUTS, versus rtl/:
//   * register reads are registered, not combinational (see mh030p_regfile.sv)
//   * decode output is registered, not fed combinationally into EX --
//     rtl/eu_seq_decode.svh is one ~6,200-line always_comb driving EX in the
//     same tick
//   * no zero-gap dispatch mechanism, so no 17-way ack-dependent mux select
//     (preview_ok) sitting in the middle of the longest path
//
// The forwarding network is what pays for the registered read: back-to-back
// dependent instructions still issue one per cycle.
// =============================================================================

module mh030p_core (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Instruction feed. A real IF stage is P3; for now the instruction is
    // presented directly so the pipeline below can be measured and tested.
    input  wire [15:0] instr,
    input  wire [31:0] ext,
    input  wire [15:0] q3,
    input  wire        instr_valid,
    output wire        instr_ready,   // core can accept an instruction this cycle

    // Program counter and redirect. There is no fetch unit yet, so the caller
    // supplies the address of the instruction it is offering and the core
    // asks for a redirect when a branch is taken. This is the interface a
    // real IF stage will drive.
    input  wire [31:0] pc_in,
    output wire        redirect,
    output wire [31:0] redirect_pc,

    // Memory port -- registered request, registered ack (plan A4).
    output reg         mem_req,
    output reg  [31:0] mem_addr,
    output reg         mem_rw,        // 1 = read, 0 = write
    output reg  [1:0]  mem_siz,
    output reg  [31:0] mem_wdata,
    // Asserted for as long as an indivisible operation needs the bus: from the
    // moment its read is dispatched until its write has been acknowledged. The
    // arbiter refuses instruction fetch in between.
    output wire        mem_lock,
    // High once STOP has executed, until an interrupt arrives. The pin exists
    // for the same reason rtl/ has one: a testbench needs to know the program
    // has finished, and STOP is how a 68k program says so.
    output wire        stopped,
    // Interrupt priority level, already encoded 0-7. Real silicon presents it
    // on three ACTIVE-LOW pins; inverting them is the pin driver's job, not
    // the core's, and the SoC that wires this up owns that.
    input  wire [2:0]  ipl,

    input  wire [31:0] mem_rdata,
    input  wire        mem_ack,

    // Architectural state, exposed for the testbench.
    output wire        wb_wr_en,
    output wire [3:0]  wb_wr_sel,
    output wire [31:0] wb_wr_data,
    output wire [7:0]  ccr_out
);

    // ── Decode (combinational) ──────────────────────────────────────────────
    uop_t dec_uop;
    mh030p_decode u_dec (
        .instr (instr),
        .ext   (ext),
        .q3    (q3),
        .uop   (dec_uop)
    );

    // Only register-direct work is executed in this phase. Anything else
    // decodes fine but is not issued, so it cannot silently produce a wrong
    // architectural result while the pipeline is being measured.
    // Memory SOURCE operands through the simple EA modes are in scope now.
    // Memory destinations and the indexed/indirect modes are later phases;
    // anything outside the set decodes but is never issued, so it cannot
    // silently produce a wrong architectural result.
    wire dec_ea_ok = (dec_uop.ea_mode == UEA_AN_IDX)
                  || (dec_uop.ea_mode == UEA_AN_IND)
                  || (dec_uop.ea_mode == UEA_AN_POST)
                  || (dec_uop.ea_mode == UEA_AN_PRE)
                  || (dec_uop.ea_mode == UEA_AN_D16)
                  || (dec_uop.ea_mode == UEA_ABS_W)
                  || (dec_uop.ea_mode == UEA_ABS_L)
                  // PC-relative: the base is the instruction's own address
                  // plus two, which AG takes from the pipeline rather than
                  // from a register.
                  || (dec_uop.ea_mode == UEA_PC_D16)
                  || (dec_uop.ea_mode == UEA_PC_IDX);

    // A pure memory WRITE (register or immediate source, memory destination)
    // is in scope. A read-modify-write, and a memory-to-memory move, need two
    // bus cycles or two addresses respectively and are not.
    wire dec_pure_wr = dec_uop.writes_mem && !dec_uop.reads_mem;
    // LEA/PEA/JMP/JSR: the effective address is the RESULT, not an operand
    // address. Nothing is read from it -- LEA and JMP never touch memory at
    // all, and the write PEA and JSR do is to the STACK, at a second address
    // the EA adder never sees. That makes them the first shape in this core
    // where the AG output leaves the stage as data.
    wire dec_is_ea_class = (dec_uop.uclass == UC_LEA)
                        || (dec_uop.uclass == UC_JMP);
    wire dec_is_push     = dec_is_ea_class && dec_uop.writes_mem;  // PEA / JSR
    // (An)+ and -(An) are illegal for all four, and a push needs the C port
    // for A7 so it cannot also index with it.
    // LINK/UNLK build and tear down a stack frame; the address register they
    // name is on the DESTINATION field, not the EA field, so they are excluded
    // from the EA-base selection even though both touch memory.
    wire dec_is_link = (dec_uop.uclass == UC_LINK);
    // ── Bit fields ──────────────────────────────────────────────────────────
    // The operand registers do not sit where any other class puts them: the
    // FIELD lives in the register the EA field names, and BFINS's source in the
    // specification word's own [15:12]. The destination is whichever of those
    // two the operation writes, which the decoder has already resolved.
    //
    // Dn-direct only, and only with an immediate offset and width. A Dn offset
    // or width would need two more read ports than exist, and the memory forms
    // need the byte/word/longword sub-access sizing rtl/ only got at Phase 276.
    // Reads memory, writes nothing, and names memory as its DESTINATION: TST
    // and BTST-on-memory. For these the memory value is the operand the unit
    // tests, not an ALU source, and any register named is the bit number rather
    // than a second operand -- so both the read selector and the operand routing
    // differ from an ordinary memory-source instruction like ADD <ea>,Dn.
    wire dec_mem_operand = dec_uop.reads_mem && !dec_uop.writes_mem
                        && (dec_uop.dst_kind == US_MEM);
    wire dec_is_movep = (dec_uop.uclass == UC_MOVEP);
    wire dec_is_cas    = (dec_uop.uclass == UC_ATOMIC)
                      && (dec_uop.subop == 4'd1);
    wire dec_is_bf = (dec_uop.uclass == UC_BITFIELD);
    wire dec_bf_ok = dec_is_bf && !dec_uop.reads_mem && !dec_uop.writes_mem
                  && !dec_uop.imm[11] && !dec_uop.imm[5];
    // Only the register and immediate forms of the system-control moves are in
    // scope here; memory destinations, and the AND/OR/EOR-to-SR forms at
    // sub-op 6, are not.
    wire dec_sysctl_ok = (dec_uop.uclass == UC_SYSCTL)
                      && (dec_uop.subop <= 4'd5)
                      && !dec_uop.reads_mem && !dec_uop.writes_mem;
    wire dec_ea_class_ok = dec_is_ea_class && dec_ea_ok
                        && (dec_uop.ea_mode != UEA_AN_POST)
                        && (dec_uop.ea_mode != UEA_AN_PRE)
                        && !(dec_is_push && (dec_uop.ea_mode == UEA_AN_IDX));
    // Read-modify-write: one EA, read then write, two bus cycles. This is the
    // first instruction shape that needs more than one pass through EX.
    wire dec_rmw     = dec_uop.writes_mem && dec_uop.reads_mem
                    && (dec_uop.dst_ea_mode == UEA_NONE);
    // Memory to memory: read one address, write a DIFFERENT one. Two bus
    // cycles like an RMW, but the second uses dst_ea_*.
    wire dec_mem2mem = dec_uop.writes_mem && dec_uop.reads_mem
                    && (dec_uop.dst_ea_mode != UEA_NONE);
    // Every alterable memory destination is now in scope, indexed included:
    // the uop carries its own dst_ea_idx_* set and the register file has a
    // fourth read port for it, so a move with (d8,An,Xn) at BOTH ends has all
    // four registers -- two bases, two indices -- in the same cycle. PC-relative
    // is correctly absent; it is not alterable.
    wire dec_dst_ea_ok = (dec_uop.dst_ea_mode == UEA_AN_IND)
                      || (dec_uop.dst_ea_mode == UEA_AN_POST)
                      || (dec_uop.dst_ea_mode == UEA_AN_PRE)
                      || (dec_uop.dst_ea_mode == UEA_AN_D16)
                      || (dec_uop.dst_ea_mode == UEA_AN_IDX)
                      || (dec_uop.dst_ea_mode == UEA_ABS_W)
                      || (dec_uop.dst_ea_mode == UEA_ABS_L);

    // How many extension words an EA mode needs. A memory-to-memory move can
    // only be executed when at most ONE side needs any, because with a
    // displacement at each end the decoder cannot say which half of `ext` holds
    // which -- that needs the full ext_count chain ported, and until then saying
    // "cannot do this one" is the honest answer rather than using a wrong value.
    function automatic logic [1:0] ea_disp_words(input logic [3:0] m);
        ea_disp_words = ((m == UEA_AN_D16) || (m == UEA_ABS_W)
                      || (m == UEA_AN_IDX) || (m == UEA_PC_D16)
                      || (m == UEA_PC_IDX)) ? 2'd1
                      : (m == UEA_ABS_L)    ? 2'd2 : 2'd0;
    endfunction
    // The decoder now places each side's displacement at its own extension-word
    // offset, so a displacement at BOTH ends is expressible. What is still not
    // is a fourth extension word -- an absolute long at each end, or a long
    // immediate feeding one -- which is exactly what ea_disp_valid reports.
    wire dec_m2m_disp_ok = dec_uop.ea_disp_valid;

    wire dec_executable = dec_uop.valid
                       && ((dec_uop.uclass == UC_ALU)   || (dec_uop.uclass == UC_MOVE)
                        || (dec_uop.uclass == UC_MOVEQ) || (dec_uop.uclass == UC_ADDQ)
                        || (dec_uop.uclass == UC_SHIFT)
                        || (dec_uop.uclass == UC_MULDIV)
                        || (dec_uop.uclass == UC_BRANCH)
                        || (dec_uop.uclass == UC_SCC)
                        || (dec_uop.uclass == UC_DBCC)
                        || (dec_uop.uclass == UC_RETURN)
                        || (dec_uop.uclass == UC_TRAP)
                        || (dec_uop.uclass == UC_BITOP)
                        || (dec_uop.uclass == UC_BCD)
                        || (dec_uop.uclass == UC_EXT)
                        || (dec_uop.uclass == UC_SWAP)
                        || (dec_uop.uclass == UC_ADDX)
                        || (dec_uop.uclass == UC_NOP)
                        || (dec_uop.uclass == UC_LEA)
                        || (dec_uop.uclass == UC_JMP)
                        || (dec_uop.uclass == UC_EXG)
                        || (dec_uop.uclass == UC_LINK)
                        || (dec_uop.uclass == UC_SYSCTL)
                        || (dec_uop.uclass == UC_ATOMIC)
                        || (dec_uop.uclass == UC_BITFIELD)
                        || (dec_uop.uclass == UC_MOVEC)
                        || (dec_uop.uclass == UC_MOVEP)
                        || (dec_uop.uclass == UC_MOVEM))
                       && ((dec_uop.uclass == UC_BRANCH)
                           || ((dec_uop.uclass == UC_SCC)  && !dec_uop.writes_mem)
                           || (dec_uop.uclass == UC_DBCC)
                           // RTS commits to no register, so it would fail the
                           // destination check below; it needs its EA instead.
                           || ((dec_uop.uclass == UC_RETURN) && dec_ea_ok)
                           || (dec_uop.uclass == UC_TRAP)
                           // TAS only; CAS and CAS2 need a bus lock.
                           || ((dec_uop.uclass == UC_ATOMIC)
                               && (dec_uop.subop <= 4'd1) && dec_ea_ok)
                           || dec_bf_ok
                           // Reads memory and commits nothing at all: TST, CMP
                           // against a memory source, BTST on memory. The
                           // destination check below demands a register, which
                           // none of these have -- so they were not failing,
                           // they were never executing. Stated as the general
                           // shape rather than per class, which is how it came
                           // to miss the bit tests after covering TST.
                           || (dec_uop.reads_mem && !dec_uop.writes_mem
                               && !dec_uop.writes_reg && dec_ea_ok)
                           || (dec_is_movep && dec_ea_ok)
                           // MOVEC only; MOVES (sub-op 0) needs the alternate
                           // function codes to mean something first.
                           || ((dec_uop.uclass == UC_MOVEC)
                               && (dec_uop.subop != 4'd0))
                           || (dec_uop.uclass == UC_NOP)
                           || ((dec_uop.uclass == UC_MOVEM) && dec_ea_ok)
                           || dec_ea_class_ok
                           || (dec_uop.uclass == UC_EXG)
                           || dec_is_link
                           || dec_sysctl_ok
                           || (dec_mem2mem ? (dec_ea_ok && dec_dst_ea_ok
                                              && dec_m2m_disp_ok)
                           :   dec_rmw     ? dec_ea_ok
                           // A pure memory write used to require UC_MOVE, which
                           // silently excluded CLR -- write-only on 68010+ and
                           // the only other instruction of that shape. It was
                           // not failing, it was never executing: no bus cycle,
                           // no An update, no flags.
                           :   dec_pure_wr ? (dec_ea_ok
                                              && ((dec_uop.uclass == UC_MOVE)
                                               || (dec_uop.alu_op == UA_CLR)))
                                           : (dec_uop.dst_kind == US_DREG
                                              || dec_uop.dst_kind == US_AREG)))
                       // UNLK reads memory at the address register it names,
                       // which is on the destination field, so it has no EA
                       // mode for the check above to approve.
                       && (!dec_uop.reads_mem || dec_ea_ok || dec_is_link);

    // ── Commit-stage registers, hoisted ─────────────────────────────────────
    // These sit ahead of everything that reads them: the stall logic, the
    // exception request and the A7 shadow all need a commit that has not yet
    // landed, so the whole writeback register set and its forwarded views are
    // declared before any of it.
    reg  [7:0]  ccr_r;
    reg         wb_valid;
    reg  [3:0]  wb_reg;
    reg  [31:0] wb_data;
    reg         wb_writes;
    reg  [7:0]  wb_ccr;
    reg         wb_upd_ccr;
    // The CCR as EX must see it, not as it has been committed. ccr_r is
    // written in WB, so an instruction in EX is a full stage ahead of its
    // predecessor's flag update -- a Bcc straight after a CMP, an ADDX after
    // an ADD, or a trap capturing the SR for its stack frame all read the
    // PREVIOUS instruction's flags without this. Exactly the same forwarding
    // the register file gets, for the same reason, and one level is enough:
    // ccr_r has already absorbed everything older than WB.
    wire [7:0] ccr_live = wb_upd_ccr ? wb_ccr : ccr_r;
    // The second commit port, registered in WB exactly as the first is, and
    // mirrored one cycle later into wbp2_* for the second forwarding level.
    reg         wb2_en,  wbp2_en;
    reg  [3:0]  wb2_sel, wbp2_sel;
    reg  [31:0] wb2_data, wbp2_data;

    // ── Stage registers ─────────────────────────────────────────────────────
    uop_t ag_uop, ex_uop;
    reg   ag_valid, ex_valid;
    // Declared here because the stall below uses mem_got; assigned further
    // down beside the bus request.
    reg        mem_got;
    reg [31:0] mem_hold;
    reg [31:0] ag_pc, ex_pc;
    // The instruction's own address plus two, REGISTERED rather than added in
    // AG. A PC-relative EA and a BSR/JSR return address both need it, and
    // computing it in AG put a fourth 32-bit adder at the head of the effective-
    // address chain -- which the measurement found as the binding path, rooted
    // literally at this register. pc_in is available a stage early, so this
    // costs one adder's worth of logic and no cycles at all.
    reg [31:0] ag_pc2;
    // Which register the B port carried; needed by the interlock below.
    wire ag_is_trap  = (ag_uop.uclass == UC_TRAP);
    // Which TRAP-class instructions have no operand of their own. TRAP #n,
    // TRAPV, TRAPcc and Line-A read nothing, so the AG stage must not dispatch
    // for them -- the exception sequence owns the bus. CHK and CMP2/CHK2 DO
    // read memory, for a bound and a bounds pair, and suppressing their reads
    // because they happen to share a class left both silently unable to
    // complete: CMP2 hung in EX and a memory-bound CHK could never have worked.
    wire ag_trap_no_ea = (ag_uop.uclass == UC_TRAP)
                      && (ag_uop.subop != 4'd2) && (ag_uop.subop != 4'd3);
    wire ag_is_movem = (ag_uop.uclass == UC_MOVEM);
    wire ag_is_movep = (ag_uop.uclass == UC_MOVEP);
    // LEA/PEA/JMP/JSR need the EA base on the B port exactly as a memory
    // operand does, even though LEA and JMP issue no bus cycle at all.
    wire ag_ea_class = (ag_uop.uclass == UC_LEA) || (ag_uop.uclass == UC_JMP);
    wire ag_mem     = ag_uop.reads_mem || ag_uop.writes_mem || ag_ea_class;
    // Which registers a dual-commit instruction touches on the SECOND port.
    // Selector only -- no data -- so it can be declared this early and used by
    // the interlock below.
    wire ex_dual = ex_valid && ((ex_uop.uclass == UC_EXG)
                             || (ex_uop.uclass == UC_LINK));
    wire [3:0] ex_wr2_sel_e = (ex_uop.uclass == UC_EXG) ? ex_uop.src_reg
                                                        : 4'd15;
    wire ag_is_bsr = (ag_uop.uclass == UC_BRANCH) && (ag_uop.cond == 4'h1);
    // PEA / JSR: the bus cycle goes to -(A7), not to the computed EA.
    wire ag_is_push = ag_ea_class && ag_uop.writes_mem;
    wire ag_is_jsr  = (ag_uop.uclass == UC_JMP) && ag_uop.writes_mem;
    // RTE and RTR pop a 16-bit status word BEFORE the PC; RTS (imm 5) does
    // not. See the two-phase return sequence in EX.
    wire ag_is_rte  = (ag_uop.uclass == UC_RETURN) && (ag_uop.subop != 4'd5);
    wire ag_is_link = (ag_uop.uclass == UC_LINK) && (ag_uop.subop == 4'd0);
    wire ag_is_unlk = (ag_uop.uclass == UC_LINK) && (ag_uop.subop == 4'd1);
    wire ag_is_bf = (ag_uop.uclass == UC_BITFIELD);
    wire [3:0] ag_b_sel = ag_is_bf ? {1'b0, ag_uop.ea_reg[2:0]}
                        : (ag_mem && (ag_uop.uclass != UC_LINK))
                          ? ag_uop.ea_reg : ag_uop.dst_reg;
    // Must mirror rd_a_sel exactly. When these two disagree the AG forwarding
    // and the interlock track a different register than the one actually read.
    wire ag_is_cas = (ag_uop.uclass == UC_ATOMIC) && (ag_uop.subop == 4'd1);
    wire [3:0] ag_c_sel = (ag_is_push || ag_is_link) ? 4'd15
                        : ag_is_cas                  ? ag_uop.imm[3:0]
                                                     : ag_uop.ea_idx_reg;
    // Must mirror rd_d_sel exactly, for the same reason ag_c_sel mirrors
    // rd_c_sel: the index register of an INDEXED DESTINATION, which only a
    // memory-to-memory move has.
    wire [3:0] ag_d_sel = ag_uop.dst_ea_idx_reg;
    wire ag_mem_operand = ag_uop.reads_mem && !ag_uop.writes_mem
                       && (ag_uop.dst_kind == US_MEM);
    wire [3:0] ag_a_sel = ag_is_cas ? ag_uop.dst_reg
                        : ag_is_movep ? ag_uop.imm[3:0]
                        : ag_is_bf ? ag_uop.imm[15:12]
                        : (ag_uop.dst_ea_mode != UEA_NONE) ? ag_uop.dst_ea_reg
                        : ag_mem_operand ? ag_uop.src_reg
                        : (ag_uop.reads_mem && !ag_uop.writes_mem)
                          ? ag_uop.dst_reg : ag_uop.src_reg;

    // EX stalls while its own memory operand is still outstanding. The whole
    // pipeline behind it holds, which is what makes the request safe to leave
    // asserted: it is dropped on ack rather than re-issued every cycle. That
    // re-issue shape is exactly the bug the sequential divider hit in rtl/.
    // An RMW holds EX for two bus cycles: the read, then the write of the
    // computed value. mem_got marks the read captured, rmw_done the write
    // acknowledged; a plain access needs only the first.
    // ── RTE / RTR ───────────────────────────────────────────────────────────
    // A return from exception pops TWO things: a 16-bit status word, then the
    // 32-bit PC above it. RTS pops only the PC, which is why it fits in the
    // ordinary single-access path and these do not -- they are a second EX
    // phase in the same shape as a read-modify-write's write.
    //
    // RTR pops the same two words but restores only the CCR; the system byte
    // is a supervisor resource and RTR is a user instruction. The pop itself
    // is identical, so both share this sequence and differ only at commit.
    wire ex_is_ret = ex_valid && (ex_uop.uclass == UC_RETURN);
    wire ex_is_rte = ex_is_ret && (ex_uop.subop != 4'd5);
    reg        rte_p2_issued, rte_done;
    reg        cmp2_p2_issued;
    reg [31:0] cmp2_lb;
    // Declared here because the bus sequence below needs the stride before the
    // comparison itself exists.
    wire [31:0] cmp2_step = (ex_uop.siz == UZ_BYTE) ? 32'd1
                          : (ex_uop.siz == UZ_WORD) ? 32'd2 : 32'd4;

    reg [15:0] rte_sr;

    // The status register's SYSTEM byte (T/S/M/IPL). The CCR half lives in
    // ccr_r. Until now the SR pushed by a trap was synthesised as a constant
    // 0x20 with a supervisor bit hardcoded, which was enough to build a frame
    // but not to RESTORE one -- an RTE has to put back what was there.
    // Reset leaves S=1 and the interrupt mask at 7 (MC68030UM section 8.1.1).
    reg [7:0] sr_sys_r;
    // The user stack pointer, shadowed while in supervisor state.
    reg [31:0] usp_r;

    // ── Control registers (MOVEC) ───────────────────────────────────────────
    // VBR is the one that matters here: the exception vector base was hardcoded
    // to 0 because there was no register to hold it, so every handler had to
    // live in the bottom 1KB. CACR and CAAR are plain registers with nothing
    // behind them -- this core has no caches -- and SFC/DFC likewise, since
    // MOVES is not executable yet. Readback is real in every case, which is
    // what software actually checks.
    reg [31:0] vbr_r, cacr_r, caar_r;
    reg [2:0]  sfc_r, dfc_r;

    wire ex_rmw = ex_valid && ex_uop.reads_mem && ex_uop.writes_mem;
    // A write-only ALU operation on memory -- CLR. Its flags are not claimed at
    // decode, for the same reason no memory RMW's are.
    wire ex_is_alu_mem_wr = ex_valid && (ex_uop.uclass == UC_ALU)
                         && ex_uop.writes_mem && !ex_uop.reads_mem;
    // Two memory operands. Not tied to ex_rmw any more: CMPM reads two
    // addresses and writes NEITHER, so requiring writes_mem left its
    // destination address uncomputed and its Ax un-incremented.
    wire ex_m2m = ex_valid && ex_uop.reads_mem
               && (ex_uop.dst_ea_mode != UEA_NONE);
    // ── Two-address arithmetic through memory ────────────────────────────────
    // SBCD/ABCD and ADDX/SUBX in their -(Ay),-(Ax) form are the only
    // instructions here that READ TWO different addresses and write one:
    // source, destination, then the result back to the destination. A
    // memory-to-memory MOVE reads one and writes the other, so the existing
    // path is one access short -- it computed with the destination operand it
    // had never fetched.
    // Which of those need the DESTINATION fetched as well: anything whose
    // arithmetic uses the destination's old value. A memory-to-memory MOVE does
    // not, which is the whole distinction -- so it is keyed on class rather than
    // on the operand kinds, which are identical for both shapes.
    wire ex_m2m_2rd = ex_m2m && ((ex_uop.uclass == UC_BCD)
                              || (ex_uop.uclass == UC_ADDX)
                              || (ex_uop.uclass == UC_ALU));
    // An explicit phase, not a set of flags keyed off mem_got: mem_got stays
    // high for the whole stall and so cannot tell "the FIRST read finished" from
    // "the SECOND read finished". Keying the write on it cancelled the second
    // read one cycle after issuing it.
    //   0 = source read outstanding (dispatched by AG)
    //   1 = destination read outstanding
    //   2 = write outstanding
    //   3 = done
    reg [1:0]  bcdm_ph;
    reg [31:0] bcdm_src;
    reg  rmw_wr_issued, rmw_done;
    // Declared here so the ONE always_ff that drives the memory port can use
    // it; assigned below once the ALU result exists. Splitting the port
    // across two blocks would give it two drivers -- the exact fault that had
    // to be fixed in rtl/ (see make lint-drivers).
    wire [31:0] ex_commit;
    // Destination address for a memory-to-memory move. Declared here for the
    // single always_ff that drives the memory port; assigned once the operand
    // registers exist.
    wire [31:0] ex_m2m_addr;
    // Declared here for the single always_ff that drives the memory port; the
    // comparison it depends on only exists once the ALU has run.
    wire cas_skip_wr;

    // Register-file read data; declared here because the MOVEM sequencer
    // below repurposes the C port.
    wire [31:0] rf_a, rf_b, rf_c, rf_d;

    // ── MOVEM ───────────────────────────────────────────────────────────────
    // One register per bus cycle, walking the 16-bit mask in the extension
    // word. This is the widest sequence in the core: up to 16 transfers for a
    // single instruction, and the first one whose LENGTH depends on data
    // rather than on the opcode.
    //
    // Mask order is architectural, not arbitrary: for -(An) the mask runs
    // A7..D0, and for every other mode D0..A7. Getting that backwards stores
    // the right registers at the wrong addresses.
    reg  [3:0]  mvm_idx;       // which register is next
    reg  [31:0] mvm_addr;      // running address
    reg         mvm_run, mvm_done;
    // The C port is a REGISTERED read, so the register data for mvm_reg only
    // arrives a cycle after it is selected. Issuing immediately transferred
    // the PREVIOUS register's value; this gates each transfer on the read
    // having landed.
    reg         mvm_ready;

    wire        ex_is_movem = ex_valid && (ex_uop.uclass == UC_MOVEM);
    wire        mvm_predec  = (ex_uop.ea_mode == UEA_AN_PRE);
    wire [15:0] mvm_mask    = ex_uop.imm[15:0];
    // Walk order: predecrement counts down from A7, everything else up from D0.
    wire [3:0]  mvm_reg     = mvm_predec ? (4'd15 - mvm_idx) : mvm_idx;
    wire        mvm_bit     = mvm_mask[mvm_idx];
    wire        mvm_last    = (mvm_idx == 4'd15);
    wire [31:0] mvm_step    = ex_uop.xfer_long ? 32'd4 : 32'd2;
    // A register-to-memory transfer needs an arbitrary register out of the
    // file every cycle, which no pipeline operand port can supply. The C port
    // is repurposed: an indexed EA and a MOVEM cannot both be in AG at once,
    // since MOVEM's own EA modes exclude indexing here.
    wire [31:0] mvm_wdata   = rf_c;

    // ── MOVEP ───────────────────────────────────────────────────────────────
    // Two or four BYTE accesses at a stride of two, most significant first --
    // the instruction exists to talk to an 8-bit peripheral sitting on half of
    // a 16-bit bus, so the gaps are the point.
    //
    // Simpler than MOVEM in the one way that matters: the byte count is fixed
    // by the opcode rather than by data, so there is no mask to walk and no
    // register-file port to borrow. The address comes from ex_ea, the EA the AG
    // stage already computed, which is cleaner than MOVEM having to rebuild it
    // from a base register.
    reg  [2:0]  mvp_idx;
    reg  [31:0] mvp_addr;
    reg  [31:0] mvp_sh;        // write data, shifted left a byte per beat
    reg  [31:0] mvp_acc;       // read data, shifted in a byte per beat
    reg         mvp_run, mvp_done;

    wire        ex_is_movep = ex_valid && (ex_uop.uclass == UC_MOVEP);
    wire        ex_movep_rd = ex_is_movep && ex_uop.reads_mem;
    wire [2:0]  mvp_n       = ex_uop.xfer_long ? 3'd4 : 3'd2;
    wire        mvp_last    = (mvp_idx == (mvp_n - 3'd1));

    // ── Exception sequence ──────────────────────────────────────────────────
    // A trap is three bus cycles: push the return PC, push the SR, then read
    // the vector and jump to it. That is the first thing in this core with a
    // multi-cycle sequence of its OWN rather than a second phase bolted onto
    // an instruction, so it gets a small state machine that owns the memory
    // port while it runs.
    localparam [1:0] XS_IDLE = 2'd0, XS_PC = 2'd1, XS_SR = 2'd2, XS_VEC = 2'd3;
    // Declared here because the exception FSM below pushes it; assigned near
    // the functional units.

    reg  [1:0]  exc_state;
    reg  [31:0] exc_sp;
    // A7 as the exception sequence needs it. Taking it from an operand port
    // only worked while TRAP #n was the single source: the decoder puts A7 on
    // the EA field for a trap, but a divide has its own operands there. A
    // shadow of A7, forwarded the same way the CCR is, is available to every
    // source without spending a port on any of them.
    reg  [31:0] sp_shadow;
    reg  [31:0] exc_base_r;
    reg  [31:0] exc_vec_addr;
    reg         exc_taken;


    wire ex_wait_mem = ex_valid && (ex_uop.reads_mem || ex_uop.writes_mem)
                    && (ex_m2m_2rd ? (bcdm_ph != 2'd3)
                        : ex_rmw   ? !rmw_done : !mem_got);

    // Divide is multi-cycle: rtl/eu_mul_div.sv iterates one 32-bit
    // compare+subtract per tick rather than instantiating a combinational
    // division array. Multiply stays combinational (it maps to DSPs), so only
    // the divide needs a handshake. div_started is cleared when the
    // instruction actually leaves EX, which is what makes div_start a
    // one-shot rather than a level that re-triggers every stalled cycle --
    // the same shape the (An)+ side effect already had to be fixed for.
    wire ex_is_div = ex_valid && (ex_uop.unit == UU_DIV);
    // A divide that OVERFLOWS leaves its destination completely unaffected --
    // only the flags move. Writing the (meaningless) quotient anyway destroyed
    // the register, which is what every DIVS vector in the corpus objected to.
    // eu_mul_div reports it in v_out, registered at completion. Assigned below,
    // where md_v is selected between the two arithmetic units.
    wire div_ovf;
    reg  div_started;
    // Both arithmetic units LATCH their operands on the start pulse, so neither
    // may be started before the operands exist. For a memory source that means
    // waiting for the read: starting on the divide's first EX cycle handed the
    // divider whatever mem_hold held from the previous instruction, which is why
    // DIVS <mem>,Dn produced a wrong quotient and a bogus overflow. rtl/ hit the
    // same shape at P0 from the other direction -- stale flags rather than a
    // stale operand -- and the note there says exactly this: latch the
    // operand-derived state WITH the operands.
    wire div_can_start = ex_is_div && (!ex_uop.reads_mem || mem_got);
    wire md_div_start  = div_can_start && !div_started;
    wire md_div_busy;
    // Driven by the mul/div unit below; declared here because the exception
    // request above needs it.
    wire md_dbz;
    wire ex_wait_div  = ex_is_div && (!div_started || md_div_busy);

    // Multiply is now two cycles as well, for the same reason the divide became
    // sequential: a combinational one puts its whole composition network in a
    // single tick. Same handshake shape -- a one-tick start so a stalled cycle
    // cannot retrigger it, which is the bug the (An)+ side effect and the
    // divider both had to be fixed for.
    wire ex_is_mul = ex_valid && (ex_uop.unit == UU_MUL);
    reg  mul_started;
    wire mul_can_start = ex_is_mul && (!ex_uop.reads_mem || mem_got);
    wire mul_start     = mul_can_start && !mul_started;
    wire mul_busy;
    wire ex_wait_mul = ex_is_mul && (!mul_started || mul_busy);


    // Address-base interlock. AG needs the base register a full stage before
    // EX does, so a producer still in EX has nothing to forward yet. Rather
    // than add a third forwarding level for a dependency that is rare (An is
    // normally set well ahead of its use), hold AG for a cycle.
    // Interlock: AG needs its operands a stage before EX does, so a producer
    // still in EX has nothing committed to forward. Covers both the address
    // base and, for a store, the data register.
    wire ag_base_busy = ag_valid && (ag_uop.reads_mem || ag_uop.writes_mem)
                     && ex_valid && ex_uop.writes_reg
                     && ((ex_uop.dst_reg == ag_b_sel)
                      || ((ag_uop.writes_mem || ag_uop.reads_mem)
                          && (ex_uop.dst_reg == ag_a_sel))
                      || (((ag_uop.ea_mode == UEA_AN_IDX)
                           || (ag_uop.ea_mode == UEA_PC_IDX) || ag_is_push
                           || ag_is_link || ag_is_cas)
                          && (ex_uop.dst_reg == ag_c_sel))
                           || ((ag_uop.dst_ea_mode == UEA_AN_IDX)
                               && (ex_uop.dst_reg == ag_d_sel)))
                     // The second write port's target has to be interlocked
                     // too, or an EXG/LINK/UNLK in EX is invisible to the AG
                     // stage for half of what it commits.
                     || (ag_valid && (ag_uop.reads_mem || ag_uop.writes_mem)
                         && ex_dual
                         && ((ex_wr2_sel_e == ag_b_sel)
                          || (ex_wr2_sel_e == ag_a_sel)
                          || (ex_wr2_sel_e == ag_c_sel)));

    // TWO stalls, and they must not be conflated. ex_wait_mem freezes the
    // whole pipeline, because EX itself cannot complete. ag_base_busy must
    // NOT freeze EX: the producer it is waiting for IS in EX, so holding EX
    // as well deadlocks -- the interlock can never clear. It holds ID/AG and
    // lets EX drain, inserting a bubble.
    wire ex_wait_rte = ex_is_rte && !rte_done;

    // ── Which exception, and whether one is being taken at all ──────────────
    // Until now the only source was TRAP #n, so "is this a TRAP uop" and "take
    // an exception" were the same signal. They are not: a divide by zero and a
    // TRAPV with V set both take one from instructions that are not traps by
    // class, and TRAPV with V CLEAR is a trap by class that takes nothing.
    // Both of these are resolved far below, where the operands and the
    // condition-code mux live -- but the exception request has to be visible to
    // stall_ex, which comes first. Declared here, assigned there.
    reg  cond_true;
    wire chk_traps;
    // ── The exception decision, taken once, behind a register ────────────────
    // These used to be combinational, and that was a real timing mistake:
    // exc_req fed stall_ex, which gates the AG-to-EX register, the writeback
    // latch, instr_ready and the memory port -- so CHK's signed 32-bit bound
    // compare, CMP2/CHK2's two signed compares and TRAPcc's condition mux all
    // sat in front of everything in the core. Measured: logic delay 8.56 ->
    // 11.89 ns and Fmax 29.11 -> 21.46, with 74 of the worst path's 105 hops
    // being carry-chain cells.
    //
    // Now an instruction that MIGHT trap spends one extra cycle deciding, and
    // the comparators feed only these registers. stall_ex sees nothing but
    // cheap flags. One cycle on a possibly-trapping instruction is
    // architecturally free -- real CHK is eight-plus clocks.
    //
    // Latching the whole decision, not just the fact of it, also removes a
    // class of bug rather than one instance: the vector, the return-PC rule,
    // the interrupt level and both flag contributions were all being re-read
    // from operands the exception sequence itself overwrites.
    // ── Reset vector fetch ──────────────────────────────────────────────────
    // Real 68k reset reads the supervisor stack pointer from address 0 and the
    // initial PC from address 4 before executing anything. The core started at
    // PC=0 instead, which worked only because every testbench so far put its
    // program there. The Harte corpus does not -- its images carry a genuine
    // vector pair -- so this is a real missing behaviour, not a harness detail.
    localparam [1:0] RS_SSP = 2'd0, RS_PC = 2'd1, RS_DONE = 2'd2;
    reg  [1:0]  rst_state;
    reg         rst_issued;
    reg  [31:0] rst_pc;
    wire in_reset_seq = (rst_state != RS_DONE);
    // One tick of redirect, on the cycle the sequence completes, to send the
    // fetch unit at the vector it just read.
    wire rst_redirect = (rst_state == RS_PC) && rst_issued && mem_ack;

    reg        exc_pend, trap_decided;
    // Declared up here because the instruction-issue gate reads it, and that
    // sits far above STOP's own logic.
    reg        stopped_r;
    reg  [9:0] exc_vec_r;
    reg        exc_retself_r, exc_disc_r, exc_isint_r;
    reg  [2:0] exc_ilevel_r;
    reg        chk_n_r, chk_z_r, cmp2_c_r, cmp2_z_r;
    // CMP2/CHK2's out-of-range result, resolved once both bounds have arrived.
    wire cmp2_c;
    reg  cmp2_done;

    // UC_TRAP has SIX producers, and until the sub-op field existed they all
    // looked like TRAP #n: CHK, CHK2/CMP2, TRAPcc and every one of the 4,096
    // A-line opcodes shared sub-op 0 and so took a vector built from an `imm`
    // none of them set -- a bogus jump through address 0. Found by auditing
    // rather than by a test, because nothing in the suite executed one.
    wire ex_trap_cls = ex_valid && (ex_uop.uclass == UC_TRAP);
    wire ex_trap_n   = ex_trap_cls && (ex_uop.subop == 4'd0);   // TRAP #n
    wire ex_trapv    = ex_trap_cls && (ex_uop.subop == 4'd1);   // TRAPV
    wire ex_is_chk   = ex_trap_cls && (ex_uop.subop == 4'd2);   // CHK
    wire ex_is_cmp2  = ex_trap_cls && (ex_uop.subop == 4'd3);   // CMP2 / CHK2
    // Extension bit 11 picks CHK2, which traps on the same condition CMP2 only
    // reports in C.
    wire ex_is_chk2  = ex_is_cmp2 && ex_uop.imm[11];
    wire ex_trapcc   = ex_trap_cls && (ex_uop.subop == 4'd4);   // TRAPcc
    wire ex_linea    = ex_trap_cls && (ex_uop.subop == 4'd5);   // A-line

    // ── CAS ─────────────────────────────────────────────────────────────────
    // Read the operand, compare it with Dc, and then EITHER write Du to memory
    // (on a match) OR write the operand into Dc (on a mismatch) -- never both,
    // and the mismatch path issues no second bus cycle at all.
    //
    // The compare rides the ordinary read-modify-write path: alu_op is already
    // CMP and an RMW routes memory to the ALU's destination and the register to
    // its source, so Z falls out of the machinery that is already there. Dc
    // arrives on the A port and Du on the C port, which an RMW leaves free.
    wire ex_is_cas = ex_valid && (ex_uop.uclass == UC_ATOMIC)
                              && (ex_uop.subop == 4'd1);

    // TAS: read a byte, set its bit 7, write it back. The RMW machinery
    // already does the two bus cycles; only the value and the flags differ.
    wire ex_is_tas = ex_valid && (ex_uop.uclass == UC_ATOMIC)
                              && (ex_uop.subop == 4'd0);
    // The divider reports its zero divisor when it finishes, not when it
    // starts, so this has to wait for the handshake to complete exactly as the
    // result does.
    wire div_zero  = ex_is_div && div_started && !md_div_busy && md_dbz;
    // ── Interrupts ──────────────────────────────────────────────────────────
    // Asynchronous, so two flip-flops before anything looks at it -- the
    // project's own standing rule for every external input.
    //
    // Level 7 is NON-MASKABLE, and a plain `level > mask` comparison can never
    // recognise it: the mask is already 7 out of reset, and 7 > 7 is false
    // forever. So level 7 gets a sticky edge latch instead, set on any
    // TRANSITION into 7 and cleared when the interrupt actually dispatches.
    // rtl/ needed exactly this and did not have it until Phase 278
    // (project_int_pending_level7_mask_gap.md); building it in from the start
    // here is cheaper than finding it again.
    reg [2:0] ipl_s1, ipl_s2, ipl_s3;
    reg       nmi_pend;
    wire      nmi_edge = (ipl_s2 == 3'b111) && (ipl_s3 != 3'b111);

    wire int_pending = (ipl_s2 > sr_sys_r[2:0]) || nmi_pend;
    wire [2:0] int_level = nmi_pend ? 3'd7 : ipl_s2;

    // An interrupt is taken BETWEEN instructions, so the one in EX is
    // abandoned and re-executed after the RTE -- which means it must not have
    // done anything yet. A bus cycle cannot be taken back, and a multi-cycle
    // sequence is already part-way through its own side effects, so those wait.
    // Deliberately NOT written in terms of stall_ex: stall_ex depends on the
    // exception request, which would depend on this, which is a loop.
    wire ex_busy_own = ex_wait_mem || ex_wait_div || ex_wait_mul || ex_wait_rte
                    || (ex_is_movem && !mvm_done)
                    || (ex_is_movep && !mvp_done)
                    || (ex_is_cmp2 && !cmp2_done);
    wire ex_interruptible = ex_valid && !ex_busy_own
                         && !ex_uop.reads_mem && !ex_uop.writes_mem
                         && (ex_uop.uclass != UC_TRAP)
                         && (ex_uop.uclass != UC_MOVEM)
                         && (ex_uop.uclass != UC_LINK)
                         && (ex_uop.uclass != UC_RETURN)
                         && (ex_uop.uclass != UC_LEA)
                         && (ex_uop.uclass != UC_JMP)
                         && (ex_uop.uclass != UC_BRANCH)
                         && (ex_uop.uclass != UC_DBCC);
    wire int_take = int_pending && ex_interruptible;

    // CHK needs its operands, so its own condition lives further down; this
    // takes the resolved signal.
    // ── The decision, and why it has to be held ─────────────────────────────
    // Every one of these conditions is derived from something the exception
    // sequence itself then disturbs. CHK2's is the clearest: cmp2_c compares
    // against mem_hold, and the sequence's own VECTOR FETCH lands in mem_hold,
    // so the condition went false three cycles into the frame push -- after the
    // frame was written and the vector read, but on exactly the cycle the
    // redirect needed it. The handler address was fetched and never jumped to.
    //
    // Same shape as the forwarded-operand snapshot: a decision cannot
    // legitimately change while its own instruction is still in EX, so it is
    // taken once and held. Cleared when the instruction leaves, which is what
    // lets the state machine below see !ex_is_trap and reset.
    wire exc_req_raw = int_take || ex_trap_n || (ex_trapv && ccr_live[1])
                    || (ex_trapcc && cond_true) || ex_linea
                    || (ex_is_chk && chk_traps) || div_zero
                    || (ex_is_chk2 && cmp2_done && cmp2_c);
    // What stall_ex is allowed to see: class comparisons, a three-bit interrupt
    // level compare, and flags. No 32-bit arithmetic.
    wire ex_may_trap = ex_trap_cls || ex_is_div || int_take;
    // The FSM runs off the latched decision alone.
    wire exc_req = exc_pend;
    // An exception that ABANDONS its instruction must suppress that
    // instruction's register and flag writes. CHK and TRAPV are not in that
    // set: both leave defined flags behind even when they trap. Held for the
    // same reason as the request itself.
    wire exc_discards = exc_disc_r;
    // Vectors 5 and 7 are architectural (MC68030UM Table 8-1); TRAP #n carries
    // its own, already resolved to 32+n at decode.
    // Autovectored: level n takes vector 24+n. A real IACK bus cycle fetching a
    // vector FROM the peripheral is the other half of this and is not here yet.
    // Vectors from MC68030UM Table 8-1. TRAPcc shares vector 7 with TRAPV,
    // and CHK takes 6; A-line is the Line-1010 emulator at 10.
    // Resolved at the decision cycle and latched; the sequence reads the
    // register. Autovectored: level n takes vector 24+n. A real IACK bus cycle
    // fetching a vector FROM the peripheral is the other half of this and is not
    // here yet.
    wire [9:0] exc_vec_sel = int_take  ? (10'd24 + {7'h0, int_level})
                           : div_zero  ? 10'd5
                           : (ex_is_chk || ex_is_cmp2) ? 10'd6
                           : ex_linea  ? 10'd10
                           : (ex_trapv || ex_trapcc) ? 10'd7
                                       : ex_uop.imm[9:0];
    wire [9:0] exc_vec_num = exc_vec_r;

    wire ex_is_trap  = exc_req;
    wire exc_running = (exc_state != XS_IDLE);

    // The PC the handler returns to, latched rather than recomputed: it is
    // needed by two different states, and ex_pc is only stable while the
    // instruction is held in EX.
    // A FAULT or a trap returns to the instruction AFTER the one that took it,
    // extension words included -- which the old `ex_pc + 2` got wrong for
    // anything longer than one word, latent until a divide-by-zero on a
    // memory operand could reach it. An INTERRUPT returns to the interrupted
    // instruction itself, because it was abandoned before doing anything.
    // A-line stacks the address of the unimplemented instruction itself, so
    // the emulator handler can decode it -- the same rule as an interrupt, for
    // a different reason.
    wire [31:0] exc_ret_pc = exc_retself_r ? ex_pc
                           : (ex_pc + 32'd2
                              + {27'h0, ex_uop.ext_words, 1'b0});


    // CMP2/CHK2 reads a PAIR of bounds -- the lower at the effective address and
    // the upper one operand-size above it. Two reads, which is a shape nothing
    // else in this core has: every other multi-access family is read-then-write
    // or a run of same-direction beats.
    wire ex_wait_cmp2 = ex_is_cmp2 && !cmp2_done;

    // Everything an instruction waits for that is NOT an exception decision:
    // its own operands, its own multi-cycle sequence. All cheap flags.
    wire ex_other_stall = ex_wait_mem || ex_wait_div || ex_wait_mul
                       || ex_wait_rte || ex_wait_cmp2
                       || (ex_is_movem && !mvm_done)
                       || (ex_is_movep && !mvp_done);

    // The decision cycle: one tick, after the operands have arrived, in which
    // the trap conditions are evaluated and latched. Placed AFTER the operand
    // waits so a CHK reading its bound from memory, a CHK2 reading a pair, and
    // a divide reporting a zero divisor all get a settled answer.
    wire ex_decide = ex_may_trap && !trap_decided && !ex_other_stall;

    wire stall_ex = in_reset_seq
                 || ex_other_stall
                 || (ex_may_trap && !trap_decided)
                 || (exc_pend && !exc_taken);
    wire stall_ag = ag_base_busy;

    assign instr_ready = !stall_ex && !stall_ag;

    // The cycle an interrupt actually lands: used to clear the level-7 latch
    // and to raise the mask. Needs stall_ex, so it sits after it.
    wire int_dispatched = exc_isint_r && exc_taken && !stall_ex;

    // A7 as of right now, including a commit landing this very cycle. Same
    // shape as the register file's own write-first bypass, and needed for the
    // same reason: the exception sequence reads A7 in the cycle its
    // predecessor's write to A7 is still in flight.
    wire [31:0] sp_live = (wb_wr_en && (wb_wr_sel == 4'd15)) ? wb_wr_data
                        : (wb2_en   && (wb2_sel   == 4'd15)) ? wb2_data
                                                             : sp_shadow;
    // The frame base, held for the whole sequence: an older commit to A7 can
    // land during the stall, and the frame must not move under it.
    wire [31:0] exc_base = (exc_state == XS_IDLE) ? sp_live : exc_base_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                                   sp_shadow <= 32'h0;
        else if (wb_wr_en && (wb_wr_sel == 4'd15))    sp_shadow <= wb_wr_data;
        else if (wb2_en   && (wb2_sel   == 4'd15))    sp_shadow <= wb2_data;
    end

    // ── Register file: address in ID, data in AG ────────────────────────────
    // With a memory source the B port carries the EA BASE register instead of
    // the ALU destination; the destination is forwarded in EX.
    // The TRAP class used to be forced onto the EA field here so a trap could
    // read A7 for its stack frame. It no longer needs to -- the frame takes A7
    // from sp_live -- and leaving it in actively broke CHK, whose Dn belongs on
    // this port and was being displaced by an address register the encoding
    // never named.
    wire dec_mem = dec_uop.reads_mem || dec_uop.writes_mem
                || dec_is_ea_class;
    // LINK reads the old frame pointer on B and needs A7 as well, so it takes
    // the C port exactly as a push does.
    wire dec_needs_sp = dec_is_push || (dec_is_link && (dec_uop.subop == 4'd0));

    mh030p_regfile u_rf (
        .clk_4x   (clk_4x),
        .rst_n    (rst_n),
        // Hold the read while anything downstream is stalled; see the
        // regfile header.
        .rd_en    (!stall_ex && !stall_ag),
        // Free-running during a MOVEM so the sequencer sees each register in
        // turn; otherwise it follows the same rule as A and B.
        .rd_c_en  (ex_is_movem || (!stall_ex && !stall_ag)),
        // dst_reg only for a PLAIN memory read, where the source arrives from
        // memory and the ALU destination is a register. For an RMW the
        // register operand is the SOURCE and the destination is memory, so
        // dst_reg is unset -- using it read D0 by accident.
        // For a memory-to-memory move the source comes from memory and there
        // is no register operand, so the A port carries the DESTINATION base.
        .rd_a_sel (dec_is_cas ? dec_uop.dst_reg
                   : dec_is_movep ? dec_uop.imm[3:0]
                   : dec_is_bf ? dec_uop.imm[15:12]
                   : (dec_uop.dst_ea_mode != UEA_NONE) ? dec_uop.dst_ea_reg
                   : dec_mem_operand ? dec_uop.src_reg
                   : (dec_uop.reads_mem && !dec_uop.writes_mem)
                     ? dec_uop.dst_reg : dec_uop.src_reg),
        .rd_b_sel (dec_is_bf ? {1'b0, dec_uop.ea_reg[2:0]}
                   : (dec_mem && !dec_is_link) ? dec_uop.ea_reg
                                              : dec_uop.dst_reg),
        // Index register for an indexed EA; harmlessly reads R0 otherwise.
        // Index register for an indexed EA, or the register MOVEM is about to
        // transfer. Those two never overlap.
        .rd_c_sel (ex_is_movem ? mvm_reg
                   : dec_is_cas   ? dec_uop.imm[3:0]
                   : dec_needs_sp ? 4'd15 : dec_uop.ea_idx_reg),
        .rd_a_data(rf_a),
        .rd_b_data(rf_b),
        .rd_d_sel (dec_uop.dst_ea_idx_reg),
        .rd_c_data(rf_c),
        .rd_d_data(rf_d),
        .wr_en    (wb_wr_en),
        .wr_sel   (wb_wr_sel),
        .wr_data  (wb_wr_data),
        .wr2_en   (wb2_en),
        .wr2_sel  (wb2_sel),
        .wr2_data (wb2_data)
    );

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ag_valid <= 1'b0;
            ag_uop   <= uop_clear();
        end else if (!stall_ex && !stall_ag) begin
            // A taken branch squashes whatever is behind it.
            ag_valid <= instr_valid && dec_executable && !redirect
                                    && !stopped_r && !in_reset_seq;
            ag_uop   <= dec_uop;
            ag_pc    <= pc_in;
            ag_pc2   <= pc_in + 32'd2;
        end else if (redirect) begin
            ag_valid <= 1'b0;
        end
    end

    // ── EX/WB boundary ──────────────────────────────────────────────────────


    // ── Forwarding ──────────────────────────────────────────────────────────
    // TWO levels are needed, which follows from the read being registered:
    // a read issued in cycle M sees the file as it stands DURING M, while a
    // write in cycle N only becomes visible from N+1.
    //
    //   instruction B, one behind A: B reads during M, A commits during M+1,
    //   B is in EX during M+1  -> the current commit (wb_*) covers it.
    //   instruction C, two behind: C reads during M+1 -- the same cycle A
    //   commits, so the read still misses it -- and C is in EX during M+2,
    //   by which point wb_* has moved on. That needs the PREVIOUS commit.
    //
    // Anything older has genuinely landed in the file. Getting this wrong
    // would not show up on independent instructions, only on back-to-back
    // dependent ones, which is exactly what the RAW test covers.
    reg         wbp_valid, wbp_writes;
    reg  [3:0]  wbp_reg;
    reg  [31:0] wbp_data;

    // Written as plain continuous assigns, NOT as a function. A function that
    // reads wb_*/wbp_* from the enclosing scope rather than through its
    // arguments gives a continuous assign whose sensitivity Icarus derives
    // from the arguments alone, so it never re-evaluates when the forwarding
    // registers change. That simulates wrong while synthesising correctly --
    // a sim/synth mismatch, and it showed up here as ADD.L D5,D5 committing
    // 2 instead of 4 with both operands naming the same register.
    // The address base needs BOTH forwarding and the interlock, and they
    // cover different cases:
    //   producer already in WB -> forward it here
    //   producer still in EX    -> nothing committed yet, so the interlock
    //                              holds AG for a cycle
    // The interlock alone is not enough: stalling does not re-issue the
    // register read, so after the stall ag_b would still hold the STALE value
    // read back in ID. That is what made MOVE.L (A3),D4 use A3 = 0.
    wire fwd_g_wb  = wb_valid  && wb_writes  && (wb_reg  == ag_b_sel);
    wire fwd_g_wbp = wbp_valid && wbp_writes && (wbp_reg == ag_b_sel);

    // A memory WRITE consumes its store data in AG, so ag_a needs the same
    // treatment as the address base: forward a producer that has reached WB,
    // and interlock one that is still in EX. Without it a store used the
    // pre-update value of the register written immediately before.
    wire fwd_h_wb  = wb_valid  && wb_writes  && (wb_reg  == ag_a_sel);
    wire fwd_h_wbp = wbp_valid && wbp_writes && (wbp_reg == ag_a_sel);

    // Port 2 sits BELOW port 1 at each level, matching the register file's own
    // conflict rule.
    wire fwd_h_wb2  = wb2_en  && (wb2_sel  == ag_a_sel);
    wire fwd_h_wbp2 = wbp2_en && (wbp2_sel == ag_a_sel);
    wire fwd_g_wb2  = wb2_en  && (wb2_sel  == ag_b_sel);
    wire fwd_g_wbp2 = wbp2_en && (wbp2_sel == ag_b_sel);
    wire [31:0] ag_a = fwd_h_wb  ? wb_data  : fwd_h_wb2  ? wb2_data
                     : fwd_h_wbp ? wbp_data : fwd_h_wbp2 ? wbp2_data : rf_a;
    wire [31:0] ag_b = fwd_g_wb  ? wb_data  : fwd_g_wb2  ? wb2_data
                     : fwd_g_wbp ? wbp_data : fwd_g_wbp2 ? wbp2_data : rf_b;
    wire fwd_i_wb  = wb_valid  && wb_writes  && (wb_reg  == ag_c_sel);
    wire fwd_i_wbp = wbp_valid && wbp_writes && (wbp_reg == ag_c_sel);
    wire fwd_i_wb2  = wb2_en  && (wb2_sel  == ag_c_sel);
    wire fwd_i_wbp2 = wbp2_en && (wbp2_sel == ag_c_sel);
    wire [31:0] ag_c = fwd_i_wb  ? wb_data  : fwd_i_wb2  ? wb2_data
                     : fwd_i_wbp ? wbp_data : fwd_i_wbp2 ? wbp2_data : rf_c;
    wire fwd_j_wb   = wb_valid  && wb_writes  && (wb_reg  == ag_d_sel);
    wire fwd_j_wbp  = wbp_valid && wbp_writes && (wbp_reg == ag_d_sel);
    wire fwd_j_wb2  = wb2_en  && (wb2_sel  == ag_d_sel);
    wire fwd_j_wbp2 = wbp2_en && (wbp2_sel == ag_d_sel);
    wire [31:0] ag_d = fwd_j_wb  ? wb_data  : fwd_j_wb2  ? wb2_data
                     : fwd_j_wbp ? wbp_data : fwd_j_wbp2 ? wbp2_data : rf_d;

    // ── AG: effective address, on its own adder ─────────────────────────────
    // A BYTE access through A7 adjusts the pointer by TWO, not one, because the
    // stack pointer has to stay even -- the one place where the operand size and
    // the pointer step genuinely disagree on a 68k.
    // The autoincrement step follows the OPERAND size, not the write size --
    // the same distinction the bus access needed. DIVU.W -(A7) predecrements by
    // TWO; using the write size stepped by four, read the wrong word AND left
    // the stack pointer four bytes low, which is why those vectors hung rather
    // than merely answering wrongly. Same for MOVEA.W, ADDA.W, SUBA.W and
    // CMPA.W through an autoincrement mode.
    wire [1:0] ag_opnd_siz = ag_uop.opnd_word ? UZ_WORD : ag_uop.siz;
    wire [31:0] ea_step = (ag_opnd_siz == UZ_BYTE)
                          ? ((ag_uop.ea_reg == 4'd15) ? 32'd2 : 32'd1)
                        : (ag_opnd_siz == UZ_WORD) ? 32'd2 : 32'd4;
    // Absolute modes have no base register; the address is the displacement.
    // PC-relative modes take the address of their own EXTENSION WORD as the
    // base, which is the instruction address plus two -- not the address of
    // the next instruction, and not the instruction address itself.
    wire ag_pc_rel = (ag_uop.ea_mode == UEA_PC_D16)
                  || (ag_uop.ea_mode == UEA_PC_IDX);
    wire [31:0] ea_base = ((ag_uop.ea_mode == UEA_ABS_W)
                        || (ag_uop.ea_mode == UEA_ABS_L)) ? 32'h0
                        : ag_pc_rel                       ? ag_pc2
                                                          : ag_b;
    // Predecrement applies to the address used THIS cycle; postincrement
    // does not.
    wire [31:0] ea_adj  = (ag_uop.ea_mode == UEA_AN_PRE) ? (32'h0 - ea_step)
                                                         : 32'h0;
    // Predecrement and indexing are mutually exclusive -- they are different EA
    // modes -- so the two terms collapse into ONE addend instead of two. That
    // takes a whole 32-bit add out of the chain for free, with no behaviour
    // change: whichever of them is non-zero, the other was zero anyway.
    // Index term: Xn as a word (sign-extended) or a longword, scaled by
    // 1/2/4/8. Only the brief format is handled here; the full format with a
    // base displacement and memory indirection is a later phase.
    wire [31:0] ag_xn   = ag_uop.ea_idx_long ? ag_c
                                             : {{16{ag_c[15]}}, ag_c[15:0]};
    wire [31:0] ag_idx  = ((ag_uop.ea_mode == UEA_AN_IDX)
                        || (ag_uop.ea_mode == UEA_PC_IDX))
                        ? (ag_xn << ag_uop.ea_idx_scale) : 32'h0;

    wire [31:0] ea_adj_idx = (ag_uop.ea_mode == UEA_AN_PRE) ? ea_adj : ag_idx;

    // The DESTINATION's index term, scaled here in AG where the adder already
    // lives, and carried into EX as one value. EX adds it to the destination
    // base; re-deriving it there would need a second scaling shifter for no
    // benefit.
    wire [31:0] ag_dxn  = ag_uop.dst_ea_idx_long
                          ? ag_d : {{16{ag_d[15]}}, ag_d[15:0]};
    wire [31:0] ag_didx = (ag_uop.dst_ea_mode == UEA_AN_IDX)
                          ? (ag_dxn << ag_uop.dst_ea_idx_scale) : 32'h0;

    // Two adds in series from registers, where this was four: (ag_pc + 2), then
    // + ea_disp, + ea_adj, + ag_idx.
    wire [31:0] ag_ea   = ea_base + ag_uop.ea_disp + ea_adj_idx;

    // The An update is a SIDE EFFECT and must commit exactly once, when the
    // instruction actually leaves AG. Gating it on ag_valid alone makes it
    // level-sensitive, so every cycle EX spends stalled on memory applies the
    // increment again -- (A3)+ advanced by 12 instead of 4.
    // A push adjusts A7, and a return that pops a status word adjusts A7 by
    // 6 rather than by one operand size -- both are committed from EX instead,
    // because AG's step is derived from the operand size and cannot express
    // either. Leaving the AG update in as well would apply BOTH.
    wire ag_an_upd = ag_valid && ag_mem && !ag_trap_no_ea && !ag_is_movem
                  && !ag_is_movep
                  && !ag_is_push && !ag_is_rte && !ag_ea_class
                  && !stall_ex && !stall_ag
                  && ((ag_uop.ea_mode == UEA_AN_POST)
                   || (ag_uop.ea_mode == UEA_AN_PRE));
    wire [31:0] ag_an_val = (ag_uop.ea_mode == UEA_AN_POST) ? (ag_b + ea_step)
                                                            : (ag_b - ea_step);

    // ── AG -> EX, plus the registered bus request ───────────────────────────
    reg [31:0] ex_a, ex_b;
    // The computed effective address, carried forward. LEA commits it as a
    // result, JMP/JSR redirect to it, PEA pushes it.
    reg [31:0] ex_ea;
    // The C port, carried forward. For a push it holds A7.
    reg [31:0] ex_sp;
    // The destination's scaled index term (memory-to-memory, indexed dst).
    reg [31:0] ex_didx;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid <= 1'b0;
            ex_uop   <= uop_clear();
            ex_a     <= 32'h0;
            ex_b     <= 32'h0;
            ex_ea    <= 32'h0;
            ex_sp    <= 32'h0;
            ex_didx  <= 32'h0;
            mem_req  <= 1'b0;
            mem_addr <= 32'h0;
            mem_rw   <= 1'b1;
            mem_siz  <= UZ_LONG;
            mem_wdata<= 32'h0;
        end else if (!stall_ex) begin
            ex_valid <= ag_valid && !stall_ag && !redirect;
            ex_pc    <= ag_pc;
            ex_uop   <= ag_uop;
            ex_a     <= ag_a;
            ex_didx  <= ag_didx;
            ex_b     <= ag_b;
            ex_ea    <= ag_ea;
            ex_sp    <= ag_c;
            // Gated by !stall_ag as well as ex_valid: while AG is held for
            // the address-base interlock its EA is still computed from the
            // stale base, so issuing the request there sends a wrong address.
            // That is exactly what happened -- the first memory access went
            // out with addr=0 before A3 had been written.
            mem_req  <= ag_valid && (ag_uop.reads_mem || ag_uop.writes_mem)
                                 && !stall_ag && !ag_trap_no_ea && !ag_is_movem
                                 && !ag_is_movep;
            // A push goes to -(A7); everything else to the computed EA.
            // LINK pushes the old frame pointer below A7; UNLK pops from
            // wherever An points. Neither address comes from the EA adder.
            mem_addr <= (ag_is_push || ag_is_link) ? (ag_c - 32'd4)
                      : ag_is_unlk                 ? ag_b
                                                   : ag_ea;
            // Read if the instruction reads, regardless of whether it also
            // writes: an RMW's FIRST bus cycle is the read, and the write is
            // turned around later from EX. Deriving this from writes_mem made
            // every RMW start with a write.
            mem_rw   <= ag_uop.reads_mem;
            // The bus access follows the OPERAND size, not the write size. They
            // differ for MOVEA.W, ADDA.W, SUBA.W, CMPA.W and the word MUL/DIV,
            // all of which write 32 bits from a 16-bit operand. A return that
            // pops a status word reads a WORD too; the PC that follows is a
            // separate longword, issued from EX.
            mem_siz  <= ag_is_rte ? UZ_WORD : ag_opnd_siz;
            // A pure write's data is the source operand, which AG already
            // has: the A port for a register source, or the immediate.
            // BSR stores the RETURN ADDRESS, not a register: the address of
            // the instruction after the branch, which is the branch plus its
            // own extension words.
            // JSR pushes the same return address BSR does. PEA pushes the
            // effective address itself, which is the whole point of it.
            mem_wdata<= (ag_is_bsr || ag_is_jsr)
                        ? (ag_pc2 + {27'h0, ag_uop.ext_words, 1'b0})
                      : ag_is_push ? ag_ea
                      : ag_is_link ? ag_b
                      // CLR writes zero. A pure write takes its data from AG,
                      // which would otherwise send whatever the A port held.
                      : ((ag_uop.uclass == UC_ALU) && (ag_uop.alu_op == UA_CLR))
                        ? 32'h0
                      : (ag_uop.src_kind == US_IMM) ? ag_uop.imm : ag_a;
        end else if (ex_is_movem && !mvm_done) begin
            // Issue a transfer for each set mask bit; skip the clear ones
            // without touching the bus. Predecrement writes BEFORE stepping,
            // every other mode writes at the current address and steps after.
            if (!mvm_run) begin
                mem_req  <= 1'b0;        // first cycle: nothing issued yet
            end else if (mvm_bit && mvm_ready && !mem_req) begin
                mem_req   <= 1'b1;
                mem_rw    <= ex_uop.reads_mem;
                mem_siz   <= ex_uop.xfer_long ? UZ_LONG : UZ_WORD;
                mem_addr  <= mvm_predec ? (mvm_addr - mvm_step) : mvm_addr;
                mem_wdata <= mvm_wdata;
            end else if (mem_ack) begin
                mem_req   <= 1'b0;
            end
        end else if (in_reset_seq) begin
            if (!rst_issued) begin
                mem_req  <= 1'b1;
                mem_rw   <= 1'b1;
                mem_siz  <= UZ_LONG;
                mem_addr <= (rst_state == RS_SSP) ? 32'h0 : 32'h4;
            end else if (mem_ack) begin
                mem_req  <= 1'b0;
            end
        end else if (ex_is_movep && !mvp_done) begin
            if (!mvp_run) begin
                mem_req <= 1'b0;             // first cycle: latch, issue nothing
            end else if (!mem_req) begin
                mem_req   <= 1'b1;
                mem_rw    <= ex_uop.reads_mem;
                mem_siz   <= UZ_BYTE;
                mem_addr  <= mvp_addr;
                mem_wdata <= {24'h0, mvp_sh[31:24]};
            end else if (mem_ack) begin
                mem_req   <= 1'b0;
            end
        end else if (ex_is_trap && !exc_taken) begin
            // Vector 32+n lives at VBR + 4*vector; VBR is 0 here, since a
            // movable vector base needs the control registers this core does
            // not have yet.
            // The Format $0 frame's real byte layout: the SR alone at SP+0,
            // the PC at SP+2, the format/vector word alone at SP+6 -- NOT
            // {format,SR} then PC, which is the shape this core pushed until
            // RTE needed to read one back. rtl/ had to be corrected for the
            // identical mistake at Phase 250: a frame that only its own RTE
            // ever reads is self-consistent whichever way round it goes, so
            // the error is invisible until something external inspects it.
            //
            // Two longword writes, exactly as rtl/ does it:
            //     {SR, PC[31:16]}  then  {PC[15:0], format/vector}
            case (exc_state)
                XS_IDLE: begin
                    mem_req   <= 1'b1;
                    mem_rw    <= 1'b0;
                    mem_siz   <= UZ_LONG;
                    mem_addr  <= exc_base - 32'd8;
                    mem_wdata <= {sr_sys_r, ccr_live, exc_ret_pc[31:16]};
                end
                XS_PC: if (mem_ack) begin
                    mem_req   <= 1'b1;
                    mem_rw    <= 1'b0;
                    mem_addr  <= exc_base - 32'd4;
                    // Format 0, vector OFFSET (4 x the vector number).
                    mem_wdata <= {exc_ret_pc[15:0],
                                  4'h0, exc_vec_num, 2'b00};
                end
                XS_SR: if (mem_ack) begin            // fetch the vector
                    mem_req   <= 1'b1;
                    mem_rw    <= 1'b1;
                    mem_addr  <= vbr_r + {20'h0, exc_vec_num, 2'b00};
                end
                default: if (mem_ack) mem_req <= 1'b0;
            endcase
        end else if (ex_m2m_2rd && (bcdm_ph != 2'd3)) begin
            if (mem_ack) begin
                mem_req <= 1'b0;         // the next phase re-issues
            end else if (!mem_req) begin
                if (bcdm_ph == 2'd1) begin
                    mem_req  <= 1'b1;    // fetch the DESTINATION operand
                    mem_rw   <= 1'b1;
                    mem_addr <= ex_m2m_addr;
                end else if ((bcdm_ph == 2'd2) && ex_uop.writes_mem) begin
                    mem_req   <= 1'b1;   // write the result back to it
                    mem_rw    <= 1'b0;
                    mem_wdata <= ex_commit;
                    mem_addr  <= ex_m2m_addr;
                end
            end
        end else if (ex_rmw && mem_got && !rmw_wr_issued && !cas_skip_wr
                     && !ex_m2m_2rd) begin
            // Read captured: turn the same address around as a write of the
            // ALU result. The address is already in mem_addr, so only the
            // direction and data change.
            mem_req   <= 1'b1;
            mem_rw    <= 1'b0;
            mem_wdata <= ex_commit;
            // A memory-to-memory move writes a DIFFERENT address than it
            // read; an RMW writes the same one, so mem_addr is left alone
            // there. Predecrement on the destination is applied here.
            if (ex_m2m) mem_addr <= ex_m2m_addr;
        end else if (ex_is_cmp2 && mem_got && !cmp2_p2_issued) begin
            // Lower bound captured; the upper sits one operand size above it.
            mem_req  <= 1'b1;
            mem_rw   <= 1'b1;
            mem_addr <= ex_ea + cmp2_step;
        end else if (ex_is_rte && mem_got && !rte_p2_issued) begin
            // Status word captured; the PC sits immediately above it.
            mem_req  <= 1'b1;
            mem_rw   <= 1'b1;
            mem_siz  <= UZ_LONG;
            mem_addr <= ex_ea + 32'd2;
        end else if (mem_ack) begin
            mem_req  <= 1'b0;   // acknowledged: drop it, never re-issue
        end
    end

    // Read data captured on ack and held until the instruction moves on.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mem_got  <= 1'b0;
            mem_hold <= 32'h0;
        end else if (mem_ack) begin
            // mem_got marks "the access completed", for a write as much as a
            // read -- but the DATA must only be captured from a read. A
            // read-modify-write acks twice, and taking mem_rdata on the write's
            // ack replaced the value just read with whatever the bus happened
            // to be carrying: on a shared bus, an interleaved instruction
            // fetch. TAS made this visible because its flags come from the
            // value read, and flags are latched when the instruction leaves EX
            // -- after the write. Every RMW's flags had the same exposure.
            mem_got  <= 1'b1;
            if (mem_rw) mem_hold <= mem_rdata;
        end else if (!stall_ex) begin
            mem_got  <= 1'b0;
        end
    end

    // ── EX operands ─────────────────────────────────────────────────────────
    // Which register each carried port holds depends on the operand shape:
    //   memory source : A = ALU destination, B = EA base
    //   otherwise     : A = ALU source,      B = ALU destination
    wire ex_rmw_op = ex_uop.reads_mem && ex_uop.writes_mem;
    wire ex_is_bf = ex_valid && (ex_uop.uclass == UC_BITFIELD);
    wire ex_mem_operand = ex_uop.reads_mem && !ex_uop.writes_mem
                       && (ex_uop.dst_kind == US_MEM);
    wire [3:0] ex_a_sel = ex_is_cas ? ex_uop.dst_reg
                        : ex_is_movep ? ex_uop.imm[3:0]
                        : ex_is_bf ? ex_uop.imm[15:12]
                        : (ex_uop.dst_ea_mode != UEA_NONE) ? ex_uop.dst_ea_reg
                        : ex_mem_operand ? ex_uop.src_reg
                        : (ex_uop.reads_mem && !ex_uop.writes_mem)
                          ? ex_uop.dst_reg : ex_uop.src_reg;
    // The B port's forwarding compared ex_uop.dst_reg, which is only the right
    // register when the read selector also used dst_reg. It mirrors the read
    // exactly now -- for a memory instruction the B port carries the EA BASE,
    // and comparing a destination against it was checking the wrong register.
    wire ex_b_mem_cls = ex_uop.reads_mem || ex_uop.writes_mem
                     || (ex_uop.uclass == UC_LEA) || (ex_uop.uclass == UC_JMP);
    wire [3:0] ex_b_sel = ex_is_bf ? {1'b0, ex_uop.ea_reg[2:0]}
                        : (ex_b_mem_cls && (ex_uop.uclass != UC_LINK))
                          ? ex_uop.ea_reg : ex_uop.dst_reg;

    wire fwd_a_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_a_sel);
    wire fwd_a_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_a_sel);
    wire fwd_b_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_b_sel);
    wire fwd_b_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_b_sel);

    wire fwd_a_wb2  = wb2_en  && (wb2_sel  == ex_a_sel);
    wire fwd_a_wbp2 = wbp2_en && (wbp2_sel == ex_a_sel);
    wire fwd_b_wb2  = wb2_en  && (wb2_sel  == ex_b_sel);
    wire fwd_b_wbp2 = wbp2_en && (wbp2_sel == ex_b_sel);
    wire [31:0] ex_a_f = fwd_a_wb  ? wb_data  : fwd_a_wb2  ? wb2_data
                       : fwd_a_wbp ? wbp_data : fwd_a_wbp2 ? wbp2_data : ex_a;
    wire [31:0] ex_b_f = fwd_b_wb  ? wb_data  : fwd_b_wb2  ? wb2_data
                       : fwd_b_wbp ? wbp_data : fwd_b_wbp2 ? wbp2_data : ex_b;

    // ── Holding a forwarded operand across a stall ──────────────────────────
    // ex_a/ex_b are the values READ in ID, which can be stale; correctness has
    // been relying on the forwarding above covering the gap. That works only
    // while an instruction passes through EX in one cycle. An instruction that
    // STALLS there -- a memory access, a divide, an exception sequence, CHK
    // deciding whether to trap -- outlives both forwarding levels, and on the
    // cycle they expire its operand silently reverts to the stale register.
    //
    // CHK found this: it correctly saw 20 > 10 in its first EX cycle, started
    // its exception, then lost the 20 on the next cycle and abandoned the trap
    // half-built. Nothing before it had both stalled in EX and depended on a
    // freshly-forwarded operand, so the bug had no way to show.
    //
    // Fixed by capturing the forwarded values once, on the first stalled cycle,
    // and using the captured copy thereafter. An operand cannot legitimately
    // change while its own instruction waits, so a snapshot is exactly right.
    reg [31:0] ex_a_h, ex_b_h;
    reg        ex_held;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_held <= 1'b0;
            ex_a_h  <= 32'h0;
            ex_b_h  <= 32'h0;
        end else if (!stall_ex) begin
            ex_held <= 1'b0;          // instruction leaving EX
        end else if (!ex_held) begin
            ex_held <= 1'b1;
            ex_a_h  <= ex_a_f;        // forwarding is still live this cycle
            ex_b_h  <= ex_b_f;
        end
    end

    wire [31:0] ex_a_u = ex_held ? ex_a_h : ex_a_f;
    wire [31:0] ex_b_u = ex_held ? ex_b_h : ex_b_f;

    // A word transfer moves Dn[15:0], so the working copy is pre-aligned and
    // every beat then sends the top byte.
    wire [31:0] mvp_sh_init = ex_uop.xfer_long ? ex_a_u : {ex_a_u[15:0], 16'h0};
    // The result: a long transfer replaces Dn, a word one only its low half.
    wire [31:0] mvp_result  = ex_uop.xfer_long ? mvp_acc
                                              : {ex_a_u[31:16], mvp_acc[15:0]};

    // Which side the memory value lands on differs between the two shapes:
    //   plain memory read (ADD.L (An),Dn) : memory is the SOURCE
    //   read-modify-write (ADD.L Dn,(An)) : memory is the DESTINATION
    // eu_alu computes dst OP src, so getting this backwards computes the
    // right arithmetic on the wrong operands.
    // Three shapes, and they route memory to different places:
    //   memory-to-memory       : memory is BOTH sides; the A port holds the
    //                            destination ADDRESS, not an operand
    //   read-modify-write      : memory is the destination
    //   plain memory read      : memory is the source
    // Checked in that order, because a mem-to-mem move also satisfies the RMW
    // test -- it reads and writes memory too.
    // A read-modify-write took its non-memory operand from the A port
    // unconditionally, which is wrong whenever that operand is an IMMEDIATE:
    // every ADDQ, SUBQ, ADDI, SUBI, ANDI, ORI, EORI and CMPI with a memory
    // destination was adding a leftover register value instead of its own
    // constant. Found by the Harte corpus in its first forty vectors; no
    // hand-written test had ever used an immediate against memory.
    wire [31:0] ex_src_raw = ex_m2m_2rd              ? bcdm_src
                           : ex_m2m                  ? mem_hold
                       : ex_rmw_op
                         ? ((ex_uop.src_kind == US_IMM) ? ex_uop.imm : ex_a_u)
                       // TST/BTST-on-memory: the register or immediate is the
                       // bit number, and memory is the operand below.
                       : ex_mem_operand
                         ? ((ex_uop.src_kind == US_IMM) ? ex_uop.imm : ex_a_u)
                       : ex_uop.reads_mem            ? mem_hold
                       : (ex_uop.src_kind == US_IMM) ? ex_uop.imm
                                                     : ex_a_u;
    // A word source going to an ADDRESS register is sign-extended to 32 bits
    // before the arithmetic -- ADDA.w, SUBA.w, CMPA.w. The uop already said so
    // with sext_src, but the only consumer treated it as "the result IS the
    // sign-extended source", which is true for MOVEA.w and wrong for these:
    // ADDA.w has to ADD the extended value to the whole register. Every ADDA.w
    // vector in the corpus failed.
    wire [31:0] ex_src = ex_uop.sext_src
                         ? {{16{ex_src_raw[15]}}, ex_src_raw[15:0]}
                         : ex_src_raw;

    // ADDA/SUBA/CMPA -(An),An: the address register is decremented FIRST, and
    // the decremented value is the destination operand. ex_a_u is the value read
    // in ID, before that decrement, so the result came out one step high.
    wire dst_is_src_areg = ex_uop.reads_mem && (ex_uop.dst_kind == US_AREG)
                        && (ex_uop.dst_reg == ex_uop.ea_reg)
                        && (ex_uop.ea_mode == UEA_AN_PRE);

    wire [31:0] ex_dst = ex_m2m           ? mem_hold
                       : ex_rmw_op        ? mem_hold
                       : ex_mem_operand   ? mem_hold
                       : dst_is_src_areg  ? ex_ea
                       : ex_uop.reads_mem ? ex_a_u
                                          : ex_b_u;

    // ── CHK ─────────────────────────────────────────────────────────────────
    // Traps if Dn is negative OR greater than the upper bound, both compared
    // SIGNED at the instruction's size, and leaves defined flags either way:
    // N is the below-bound result when it traps and unchanged when it does not,
    // Z reflects Dn, V and C clear. Taken from rtl/eu_seq_execute.svh's own
    // chk_below_w/chk_above_w rather than re-derived.
    //
    // Which port holds which operand follows the shape already in place: with a
    // memory bound this is an ordinary memory read, so the A port carries Dn
    // and the bound arrives in mem_hold; otherwise the A port carries the bound
    // and the B port Dn.
    wire        chk_word    = (ex_uop.siz == UZ_WORD);
    wire [31:0] chk_val_raw = ex_uop.reads_mem ? ex_a_u : ex_b_u;
    wire [31:0] chk_bnd_raw = ex_uop.reads_mem            ? mem_hold
                            : (ex_uop.src_kind == US_IMM) ? ex_uop.imm : ex_a_u;
    wire [31:0] chk_val = chk_word ? {{16{chk_val_raw[15]}}, chk_val_raw[15:0]}
                                   : chk_val_raw;
    wire [31:0] chk_bnd = chk_word ? {{16{chk_bnd_raw[15]}}, chk_bnd_raw[15:0]}
                                   : chk_bnd_raw;
    wire chk_below = chk_word ? chk_val_raw[15] : chk_val_raw[31];
    wire chk_above = $signed(chk_val) > $signed(chk_bnd);
    wire chk_z     = chk_word ? (chk_val_raw[15:0] == 16'h0)
                              : (chk_val_raw == 32'h0);
    // Gated on the bound having ARRIVED. Without that, a CHK with a memory
    // bound would raise its exception from an uninitialised mem_hold and start
    // pushing a frame while its own read was still outstanding.
    assign chk_traps = ex_is_chk && (!ex_uop.reads_mem || mem_got)
                                 && (chk_below || chk_above);

    // ── CMP2 / CHK2 ─────────────────────────────────────────────────────────
    // Both bounds and the register are sign-extended to 32 bits at the
    // instruction's own size, except that an ADDRESS register is always compared
    // in full. C is set when the register is OUTSIDE the range, and the range
    // may be WRAPPED (upper < lower), which is a documented 68020+ idiom with
    // its own branch of the formula -- rtl/ implemented only the unwrapped
    // branch until Phase 250 found it, so this takes the corrected version
    // directly rather than deriving it again.
    wire        cmp2_is_an = ex_uop.imm[15];

    wire [31:0] cmp2_lb_x = (ex_uop.siz == UZ_BYTE)
                            ? {{24{cmp2_lb[7]}},  cmp2_lb[7:0]}
                          : (ex_uop.siz == UZ_WORD)
                            ? {{16{cmp2_lb[15]}}, cmp2_lb[15:0]} : cmp2_lb;
    wire [31:0] cmp2_ub_x = (ex_uop.siz == UZ_BYTE)
                            ? {{24{mem_hold[7]}},  mem_hold[7:0]}
                          : (ex_uop.siz == UZ_WORD)
                            ? {{16{mem_hold[15]}}, mem_hold[15:0]} : mem_hold;
    wire [31:0] cmp2_rn_x = cmp2_is_an ? ex_a_u
                          : (ex_uop.siz == UZ_BYTE)
                            ? {{24{ex_a_u[7]}},  ex_a_u[7:0]}
                          : (ex_uop.siz == UZ_WORD)
                            ? {{16{ex_a_u[15]}}, ex_a_u[15:0]} : ex_a_u;

    assign cmp2_c = ($signed(cmp2_lb_x) <= $signed(cmp2_ub_x))
                  ? (($signed(cmp2_rn_x) < $signed(cmp2_lb_x))
                  || ($signed(cmp2_rn_x) > $signed(cmp2_ub_x)))
                  : (($signed(cmp2_rn_x) > $signed(cmp2_ub_x))
                  && ($signed(cmp2_rn_x) < $signed(cmp2_lb_x)));
    wire cmp2_z = (cmp2_rn_x == cmp2_lb_x) || (cmp2_rn_x == cmp2_ub_x);

    // ── TAS ─────────────────────────────────────────────────────────────────
    // mem_hold is right-justified for reads, so the byte is in [7:0].
    wire [7:0]  tas_orig = mem_hold[7:0];
    wire [31:0] tas_res  = {24'h0, tas_orig | 8'h80};

    // ── STOP ────────────────────────────────────────────────────────────────
    // Loads the SR from its operand and then halts until an interrupt. The
    // halt is what makes it the natural end of a test program.
    wire ex_is_stop = ex_valid && (ex_uop.uclass == UC_NOP)
                               && (ex_uop.subop == 4'd2);
    assign stopped = stopped_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                          stopped_r <= 1'b0;
        // A real STOP resumes on an interrupt its own new mask permits, which
        // int_pending already expresses -- the mask it is waiting behind is the
        // one STOP itself just loaded.
        else if (int_pending)                stopped_r <= 1'b0;
        else if (ex_is_stop && !stall_ex)    stopped_r <= 1'b1;
    end

    // ── MOVEC ───────────────────────────────────────────────────────────────
    // Control-register numbers from MC68030UM Table 6-1 / section 2.
    wire ex_is_movec = ex_valid && (ex_uop.uclass == UC_MOVEC);
    wire ex_movec_rd = ex_is_movec && (ex_uop.subop == 4'd1);   // Rc -> Rn
    wire ex_movec_wr = ex_is_movec && (ex_uop.subop == 4'd2);   // Rn -> Rc
    wire [11:0] movec_rc = ex_uop.imm[11:0];

    // MSP and ISP are the master and interrupt stack pointers. This core has no
    // M-bit stack split, so both read as the single A7 -- deliberately, and
    // stated here rather than silently returning zero.
    wire [31:0] movec_rd_val =
          (movec_rc == 12'h000) ? {29'h0, sfc_r}
        : (movec_rc == 12'h001) ? {29'h0, dfc_r}
        : (movec_rc == 12'h002) ? cacr_r
        : (movec_rc == 12'h800) ? usp_r
        : (movec_rc == 12'h801) ? vbr_r
        : (movec_rc == 12'h802) ? caar_r
        : (movec_rc == 12'h803) ? sp_live
        : (movec_rc == 12'h804) ? sp_live
                                : 32'h0;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            vbr_r  <= 32'h0;
            cacr_r <= 32'h0;
            caar_r <= 32'h0;
            sfc_r  <= 3'h0;
            dfc_r  <= 3'h0;
        end else if (ex_movec_wr && !stall_ex) begin
            case (movec_rc)
                12'h000: sfc_r  <= ex_a_u[2:0];
                12'h001: dfc_r  <= ex_a_u[2:0];
                12'h002: cacr_r <= ex_a_u;
                12'h801: vbr_r  <= ex_a_u;
                12'h802: caar_r <= ex_a_u;
                default: ;      // USP/MSP/ISP go through their own paths
            endcase
        end
    end

    // ── Bit-field unit ──────────────────────────────────────────────────────
    // rtl/eu_bitfield.sv verbatim: a pure combinational leaf, and a Tier-1
    // reuse. The field comes from the B port, BFINS's inserted value from A.
    wire [31:0] bf_result;
    wire        bf_n, bf_z, bf_v, bf_c;
    eu_bitfield u_bf (
        .bf_data     (ex_b_u),
        .bf_offset   (ex_uop.imm[10:6]),
        .bf_raw_width(ex_uop.imm[4:0]),
        .bf_src      (ex_a_u),
        .bf_op       (ex_uop.subop[2:0]),
        .bf_result   (bf_result),
        .bf_n(bf_n), .bf_z(bf_z), .bf_v(bf_v), .bf_c(bf_c)
    );

    // ── Functional units ────────────────────────────────────────────────────
    // (CAS's own values are assembled below the ALU, which produces the compare.)
    wire [31:0] alu_result, shf_result;
    wire alu_n, alu_z, alu_v, alu_c, alu_x;
    wire shf_n, shf_z, shf_v, shf_c, shf_x;

    eu_alu u_alu (
        .src   (ex_src),
        .dst   (ex_dst),
        .op    (ex_uop.alu_op),
        .siz   (ex_uop.siz),
        .x_in  (ccr_live[4]),
        .z_in  (ccr_live[2]),
        .result(alu_result),
        .n_out (alu_n), .z_out(alu_z), .v_out(alu_v),
        .c_out (alu_c), .x_out(alu_x)
    );

    wire [5:0] shf_count = (ex_uop.src_kind == US_IMM) ? ex_uop.imm[5:0]
                                                       : ex_src[5:0];
    eu_shifter u_shf (
        .operand(ex_dst),
        .count  (shf_count),
        .op     (ex_uop.alu_op),
        .siz    (ex_uop.siz),
        .x_in   (ccr_live[4]),
        .result (shf_result),
        .n_out  (shf_n), .z_out(shf_z), .v_out(shf_v),
        .c_out  (shf_c), .x_out(shf_x)
    );

    // MOVE/MOVEQ pass the source through, sized.
    wire [31:0] md_lo, md_hi;      // selected below from the two units
    wire md_n, md_z, md_v, md_c;   // selected below from the two units
    // The divider only. Its op is driven with bit 2 forced HIGH -- the divide
    // half of the encoding -- so the four multiply arms of its output mux are
    // unreachable by construction and synthesis prunes the multipliers behind
    // them. Without that the old combinational multipliers would still be built
    // and still bind the clock even though nothing reads them.
    wire [31:0] dv_lo, dv_hi;
    wire dv_n, dv_z, dv_v, dv_c;
    eu_mul_div u_md (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .div_start(md_div_start), .div_busy(md_div_busy),
        .src(ex_src), .dst(ex_dst),
        // md_op is 3 bits; the uop keeps it in the shared 4-bit alu_op field.
        .op({1'b1, ex_uop.alu_op[1:0]}),
        .result_lo(dv_lo), .result_hi(dv_hi),
        .n_out(dv_n), .z_out(dv_z), .v_out(dv_v), .c_out(dv_c),
        .div_by_zero(md_dbz)
    );

    wire [31:0] ml_lo, ml_hi;
    wire ml_n, ml_z;
    mh030p_mul u_mul (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .start(mul_start), .busy(mul_busy),
        .src(ex_src), .dst(ex_dst),
        .op(ex_uop.alu_op[1:0]),
        .result_lo(ml_lo), .result_hi(ml_hi),
        .n_out(ml_n), .z_out(ml_z)
    );

    wire is_mul_op = (ex_uop.unit == UU_MUL);
    assign md_lo = is_mul_op ? ml_lo : dv_lo;
    assign md_hi = is_mul_op ? ml_hi : dv_hi;
    assign md_n  = is_mul_op ? ml_n  : dv_n;
    assign md_z  = is_mul_op ? ml_z  : dv_z;
    assign md_v  = is_mul_op ? 1'b0  : dv_v;
    assign div_ovf = ex_is_div && md_v;
    assign md_c  = is_mul_op ? 1'b0  : dv_c;

    // ONE definition of the destination's step. There were two -- this one for
    // the ADDRESS and another for the register UPDATE -- and the A7 byte rule
    // had been added to the second but not the first, so SBCD -(Ay),-(A7)
    // accessed 0x7FF while correctly leaving A7 at 0x7FE.
    wire [31:0] ex_m2m_step = (ex_uop.siz == UZ_BYTE)
                              ? ((ex_uop.dst_ea_reg == 4'd15) ? 32'd2 : 32'd1)
                            : (ex_uop.siz == UZ_WORD) ? 32'd2 : 32'd4;
    // When BOTH operands name the SAME address register -- SBCD -(A1),-(A1) is
    // legal and the corpus tests it -- the destination's adjustment applies to
    // the value the SOURCE already left behind, so the register moves twice.
    // ex_a_u is the base as read in ID, before the source's own decrement, so
    // the source's computed address is the right starting point instead.
    // Only a source that MOVES the register makes the destination's own base
    // differ from the value read in ID. MOVE.w (d16,A7),(A7)+ shares the
    // register but leaves it alone, so the displaced source address must not
    // become the destination's base.
    wire m2m_same_reg = (ex_uop.dst_ea_reg == ex_uop.ea_reg)
                     && ((ex_uop.ea_mode == UEA_AN_POST)
                      || (ex_uop.ea_mode == UEA_AN_PRE));
    wire m2m_dst_abs = (ex_uop.dst_ea_mode == UEA_ABS_W)
                    || (ex_uop.dst_ea_mode == UEA_ABS_L);
    // The source's own step, at the OPERAND size, with the A7 byte rule -- the
    // same computation AG does, needed here because the destination of a
    // same-register pair starts from where the source left the register.
    wire [1:0]  ex_opnd_siz = ex_uop.opnd_word ? UZ_WORD : ex_uop.siz;
    wire [31:0] ex_src_step = (ex_opnd_siz == UZ_BYTE)
                              ? ((ex_uop.ea_reg == 4'd15) ? 32'd2 : 32'd1)
                            : (ex_opnd_siz == UZ_WORD) ? 32'd2 : 32'd4;
    // For a POSTincrement source the register has already moved past the operand,
    // so the destination starts one step further on: CMPM.l (A7)+,(A7)+ compares
    // A7 against A7+4 and leaves A7 eight higher. For a PREdecrement source the
    // source's own computed address IS the new value, so ex_ea serves directly.
    wire [31:0] m2m_base = m2m_dst_abs  ? 32'h0
                         : !m2m_same_reg ? ex_a_u
                         : (ex_uop.ea_mode == UEA_AN_POST) ? (ex_ea + ex_src_step)
                                                           : ex_ea;

    assign ex_m2m_addr = m2m_base + ex_uop.dst_ea_disp + ex_didx
                       + ((ex_uop.dst_ea_mode == UEA_AN_PRE)
                          ? (32'h0 - ex_m2m_step) : 32'h0);

    // Bit operations: BTST/BCHG/BCLR/BSET. The bit number is the source
    // operand mod 32 for a Dn destination.
    wire [31:0] bit_result;
    wire        bit_z;
    // A bit number is taken modulo 8 when the operand is a memory BYTE, and
    // modulo 32 when it is a data register. Using 32 everywhere tested the wrong
    // bit of the right byte.
    wire [4:0] bit_num = (ex_uop.siz == UZ_BYTE) ? {2'b00, ex_src[2:0]}
                                                 : ex_src[4:0];
    eu_bitops u_bit (
        .dst(ex_dst), .bit_num(bit_num),
        .op(ex_uop.alu_op[1:0]), .result(bit_result), .z_out(bit_z)
    );

    // BCD: byte-wide, and the X flag chains between operations.
    wire [7:0] bcd_result;
    wire bcd_c, bcd_x, bcd_z, bcd_n, bcd_v;
    eu_bcd u_bcd (
        .src(ex_src[7:0]), .dst(ex_dst[7:0]), .op(ex_uop.alu_op[1:0]),
        .x_in(ccr_live[4]), .z_in(ccr_live[2]),
        .result(bcd_result), .c_out(bcd_c), .x_out(bcd_x),
        .z_out(bcd_z), .n_out(bcd_n), .v_out(bcd_v)
    );

    // EXT sign-extends in place; EXTB.L reaches from byte to longword.
    // Sub-op 0 = EXT.W (byte -> word, upper half untouched), 1 = EXT.L
    // (word -> long), 2 = EXTB.L (BYTE -> long). The last was being extended
    // from the word, which is a different instruction.
    wire [31:0] ext_result = (ex_uop.subop == 4'd0)
                             ? {ex_dst[31:16], {8{ex_dst[7]}}, ex_dst[7:0]}
                           : (ex_uop.subop == 4'd1)
                             ? {{16{ex_dst[15]}}, ex_dst[15:0]}
                             : {{24{ex_dst[7]}},  ex_dst[7:0]};
    wire [31:0] swap_result = {ex_dst[15:0], ex_dst[31:16]};

    wire [31:0] mv_result = (ex_uop.siz == UZ_BYTE) ? {ex_dst[31:8],  ex_src[7:0]}
                          : (ex_uop.siz == UZ_WORD) ? {ex_dst[31:16], ex_src[15:0]}
                                                    : ex_src;
    wire mv_n = (ex_uop.siz == UZ_BYTE) ? ex_src[7]
              : (ex_uop.siz == UZ_WORD) ? ex_src[15] : ex_src[31];
    wire mv_z = (ex_uop.siz == UZ_BYTE) ? (ex_src[7:0]  == 8'h0)
              : (ex_uop.siz == UZ_WORD) ? (ex_src[15:0] == 16'h0)
                                        : (ex_src == 32'h0);

    wire use_bit  = (ex_uop.unit == UU_BIT);
    wire use_bcd  = (ex_uop.unit == UU_BCD);
    wire use_ext  = (ex_uop.uclass == UC_EXT);
    wire use_swap = (ex_uop.uclass == UC_SWAP);
    wire use_shf = (ex_uop.unit == UU_SHF);
    // CLR's unit is UU_MOVE in the reference decoder, but its result and flags
    // are the ALU's: zero, with Z set. Routing it through the MOVE path derived
    // both from the SOURCE operand instead, so Z came out of whatever happened
    // to be on the A port. The register form passed anyway, because that operand
    // was usually zero -- the memory forms are what exposed it.
    wire use_clr = (ex_uop.uclass == UC_ALU) && (ex_uop.alu_op == UA_CLR);
    wire use_mv  = (ex_uop.unit == UU_MOVE) && !use_clr;
    wire use_md  = (ex_uop.unit == UU_MUL) || (ex_uop.unit == UU_DIV);

    // EXT and SWAP ride the MOVE unit in the reference decoder, so they are
    // selected by class rather than by unit.
    // ── Sizing the result into a data register ──────────────────────────────
    // eu_alu and eu_shifter both MASK their result to the operation size
    // (eu_alu.sv: `arith_result = add_sum[31:0] & result_mask`), so a byte or
    // word operation returns its answer zero-extended. A 68k byte operation on
    // a data register must leave the upper 24 bits ALONE, so the merge has to
    // happen here. mv_result and the BCD path already did it; the ALU and
    // shifter paths did not, which zeroed the top of every destination register
    // for every byte and word ALU operation in the instruction set.
    //
    // Only for a DATA register: an address-register destination is always
    // written in full, and a memory destination takes its bytes from the low
    // end regardless.
    wire ex_merge = (ex_uop.dst_kind == US_DREG);
    function automatic logic [31:0] merge_sz(input logic [31:0] res,
                                             input logic [31:0] old,
                                             input logic [1:0]  sz,
                                             input logic        en);
        merge_sz = (!en)             ? res
                 : (sz == UZ_BYTE)   ? {old[31:8],  res[7:0]}
                 : (sz == UZ_WORD)   ? {old[31:16], res[15:0]}
                                     : res;
    endfunction

    wire [31:0] alu_sized = merge_sz(alu_result, ex_dst, ex_uop.siz, ex_merge);
    wire [31:0] shf_sized = merge_sz(shf_result, ex_dst, ex_uop.siz, ex_merge);

    wire [31:0] ex_result = use_bit  ? bit_result
                          : use_bcd  ? {ex_dst[31:8], bcd_result}
                          : use_ext  ? ext_result
                          : use_swap ? swap_result
                          : use_md   ? md_lo
                          : use_shf  ? shf_sized
                          : use_mv   ? mv_result : alu_sized;

    // EXT.W's result is a WORD, so its flags come from the low half. Reading
    // bit 31 reported the sign of the half the instruction never touched.
    wire mv_like_n = use_ext  ? ((ex_uop.subop == 4'd0) ? ext_result[15]
                                                       : ext_result[31])
                   : use_swap ? swap_result[31] : mv_n;
    wire mv_like_z = use_ext  ? ((ex_uop.subop == 4'd0)
                                 ? (ext_result[15:0] == 16'h0)
                                 : (ext_result == 32'h0))
                   : use_swap ? (swap_result == 32'h0) : mv_z;

    // A divide that OVERFLOWS sets V and leaves N, Z and C exactly as it
    // found them. Verified against six vectors' initial-versus-final SR
    // rather than assumed: forcing them to zero was wrong, and passing the
    // divider's own values through was wrong too.
    wire ex_n = div_ovf ? ccr_live[3] :
                ex_is_cmp2 ? ccr_live[3] :
                ex_is_bf ? bf_n :
                ex_is_chk ? chk_n_r : ex_is_tas ? tas_orig[7] :
                use_bit ? ccr_live[3] : use_bcd ? bcd_n
              : use_md  ? md_n : use_shf ? shf_n
              : (use_mv || use_ext || use_swap) ? mv_like_n : alu_n;
    wire ex_z = div_ovf ? ccr_live[2] :
                ex_is_cmp2 ? cmp2_z_r :
                ex_is_bf ? bf_z :
                ex_is_chk ? chk_z_r : ex_is_tas ? (tas_orig == 8'h0) :
                use_bit ? bit_z : use_bcd ? bcd_z
              : use_md  ? md_z  : use_shf ? shf_z
              : (use_mv || use_ext || use_swap) ? mv_like_z : alu_z;
    wire ex_v = ex_is_cmp2 ? ccr_live[1] :
                ex_is_bf ? bf_v :
                (ex_is_chk || ex_is_tas) ? 1'b0 :
                use_bit ? ccr_live[1] : use_bcd ? bcd_v
              : use_md  ? md_v : use_shf ? shf_v
              : (use_mv || use_ext || use_swap) ? 1'b0 : alu_v;
    // C is ALWAYS cleared by a divide, overflow or not (MC68030UM's own DIVU
    // and DIVS entries), so unlike N and Z it is not preserved here.
    wire ex_c = div_ovf ? 1'b0 :
                ex_is_cmp2 ? cmp2_c_r :
                ex_is_bf ? bf_c :
                (ex_is_chk || ex_is_tas) ? 1'b0 :
                use_bit ? ccr_live[0] : use_bcd ? bcd_c
              : use_md  ? md_c : use_shf ? shf_c
              : (use_mv || use_ext || use_swap) ? 1'b0 : alu_c;
    // alu_x was missing from this mux: every unit's X came from somewhere
    // except the ALU's, so ADD/SUB/NEG/ADDX/SUBX left X at whatever it already
    // held. It went unnoticed because the uop's own x_unchanged flag covers
    // the instructions that genuinely must not touch X (MOVE, CMP, AND, OR,
    // EOR, TST), which is the majority -- so the wrong answer and the right
    // one agree everywhere except on exactly the arithmetic that chains.
    // Only the ADD/SUB family touches X. AND, OR, EOR, NOT, CMP, TST and CLR
    // leave it alone, and taking alu_x for those set X on every logical
    // operation -- a regression introduced by this session's own fix for alu_x
    // being absent from this mux altogether, and caught immediately by the Harte
    // corpus. The two bugs are opposite halves of the same missing distinction.
    wire alu_touches_x = (ex_uop.alu_op == UA_ADD)  || (ex_uop.alu_op == UA_ADDX)
                      || (ex_uop.alu_op == UA_SUB)  || (ex_uop.alu_op == UA_SUBX)
                      || (ex_uop.alu_op == UA_NEG)  || (ex_uop.alu_op == UA_NEGX);

    wire ex_x = (ex_is_bf || ex_is_chk || ex_is_tas || ex_is_cmp2) ? ccr_live[4]
              : use_bit ? ccr_live[4] : use_bcd ? bcd_x
              : use_md  ? ccr_live[4] : use_shf ? shf_x
              : (use_mv || use_ext || use_swap) ? ccr_live[4]
              : alu_touches_x ? alu_x : ccr_live[4];

    // MOVEA writes all 32 bits, sign-extending a word source.
    // ── Branch resolution, in EX where the CCR is settled ───────────────────
    // Resolved rather than predicted: this core has no predictor, so a taken
    // branch squashes whatever is behind it in ID and AG. That is a real
    // two-cycle penalty per taken branch, and the reason a predictor
    // eventually earns its place.
    wire cc_n = ccr_live[3], cc_z = ccr_live[2],
         cc_v = ccr_live[1], cc_c = ccr_live[0];
    always_comb begin
        case (ex_uop.cond)
            // 0000 = T, 0001 = F. For a BRANCH the 0001 encoding is BSR,
            // which is always taken -- that is handled where the branch is
            // resolved, NOT here, because for Scc and DBcc 0001 genuinely
            // means FALSE. Treating them alike made DBF never decrement.
            4'h0: cond_true = 1'b1;                       // T
            4'h1: cond_true = 1'b0;                       // F
            4'h2: cond_true = !cc_c && !cc_z;             // HI
            4'h3: cond_true =  cc_c ||  cc_z;             // LS
            4'h4: cond_true = !cc_c;                      // CC
            4'h5: cond_true =  cc_c;                      // CS
            4'h6: cond_true = !cc_z;                      // NE
            4'h7: cond_true =  cc_z;                      // EQ
            4'h8: cond_true = !cc_v;                      // VC
            4'h9: cond_true =  cc_v;                      // VS
            4'hA: cond_true = !cc_n;                      // PL
            4'hB: cond_true =  cc_n;                      // MI
            4'hC: cond_true = (cc_n == cc_v);             // GE
            4'hD: cond_true = (cc_n != cc_v);             // LT
            4'hE: cond_true = (cc_n == cc_v) && !cc_z;    // GT
            default: cond_true = (cc_n != cc_v) || cc_z;  // LE
        endcase
    end

    // BSR and RTS move the stack and the PC together. A7 is register 15.
    // BSR pushes the return address then redirects; RTS pops it and
    // redirects to what it read. Both are two-part operations that EX holds
    // for, in the same way an RMW does.
    localparam [3:0] REG_A7 = 4'd15;

    wire ex_is_branch = ex_valid && (ex_uop.uclass == UC_BRANCH);
    wire ex_is_bsr    = ex_is_branch && (ex_uop.cond == 4'h1);
    wire ex_is_rts    = ex_is_ret;
    wire ex_ea_class  = (ex_uop.uclass == UC_LEA) || (ex_uop.uclass == UC_JMP);
    wire ex_is_push   = ex_valid && ex_ea_class && ex_uop.writes_mem;  // PEA/JSR
    wire ex_is_jmp    = ex_valid && (ex_uop.uclass == UC_JMP);
    wire ex_is_lea    = ex_valid && (ex_uop.uclass == UC_LEA)
                                 && ex_uop.writes_reg;
    wire ex_is_exg    = ex_valid && (ex_uop.uclass == UC_EXG);
    wire ex_is_link   = ex_valid && (ex_uop.uclass == UC_LINK)
                                 && (ex_uop.subop == 4'd0);
    wire ex_is_unlk   = ex_valid && (ex_uop.uclass == UC_LINK)
                                 && (ex_uop.subop == 4'd1);
    wire ex_is_sys    = ex_valid && (ex_uop.uclass == UC_SYSCTL);
    // MOVE SR,Dn and MOVE CCR,Dn are WORD transfers: the upper half of Dn
    // survives, and for the CCR form so does a zero high byte.
    wire [31:0] sys_rd_val = (ex_uop.subop == 4'd0)
                             ? {ex_b_u[31:16], sr_sys_r, ccr_live}
                             : {ex_b_u[31:16], 8'h00,    ccr_live};
    // The value going INTO the status register, from a data register or an
    // immediate.
    wire [15:0] sys_wr_val = (ex_uop.src_kind == US_IMM) ? ex_uop.imm[15:0]
                                                         : ex_a_u[15:0];
    wire ex_is_scc    = ex_valid && (ex_uop.uclass == UC_SCC);
    wire ex_is_dbcc   = ex_valid && (ex_uop.uclass == UC_DBCC);

    // DBcc: a TRUE condition falls through untouched. A false one decrements
    // the low word of Dn and branches unless that reaches -1. Note the
    // decrement happens on the word only -- the upper half of Dn is
    // preserved, which is what makes it a loop counter rather than a
    // longword subtract.
    wire [15:0] dbcc_next   = ex_dst[15:0] - 16'd1;
    wire        dbcc_dec    = ex_is_dbcc && !cond_true;
    wire        dbcc_branch = dbcc_dec && (dbcc_next != 16'hFFFF);

    // BSR (cond 0001) is unconditional despite the encoding meaning FALSE
    // everywhere else.
    wire branch_taken = ex_is_branch && ((ex_uop.cond == 4'h1) || cond_true);
    assign redirect   = rst_redirect
                     || !stall_ex && (branch_taken || dbcc_branch || ex_is_rts
                                      || ex_is_jmp
                                      || (ex_is_trap && exc_taken));
    // RTS goes to the address it popped; everything else is relative to the
    // instruction plus 2. !stall_ex above guarantees the pop has landed.
    assign redirect_pc = rst_redirect ? mem_rdata
                       : (ex_is_trap && exc_taken) ? exc_vec_addr
                       : ex_is_rts                  ? mem_hold
                       : ex_is_jmp                  ? ex_ea
                                                    : (ex_pc + 32'd2 + ex_uop.imm);

    // Scc writes a byte: all ones or all zeroes, upper bytes untouched.
    wire [31:0] scc_result  = {ex_dst[31:8], {8{cond_true}}};
    wire [31:0] dbcc_result = {ex_dst[31:16], dbcc_next};

    // A7 after a push is one longword lower; after a status-word return it is
    // six bytes higher (a word of status plus a longword of PC).
    // RTE pops a Format $0 frame -- status word, PC, format/vector word, eight
    // bytes. RTR pops only a CCR word and the PC, six. Wider frame formats
    // need the format field decoded, which is a later phase.
    // Sized so a byte or word CAS leaves the rest of Dc alone.
    wire [31:0] cas_rd_sized =
          (ex_uop.siz == UZ_BYTE) ? {ex_a_u[31:8],  mem_hold[7:0]}
        : (ex_uop.siz == UZ_WORD) ? {ex_a_u[31:16], mem_hold[15:0]}
                                  : mem_hold;
    wire cas_eq = alu_z;
    assign cas_skip_wr = ex_is_cas && mem_got && !cas_eq;

    assign ex_commit = ex_is_cas ? (cas_eq ? ex_sp : cas_rd_sized)
                     : ex_movep_rd              ? mvp_result
                     : ex_movec_rd              ? movec_rd_val
                     : ex_is_bf                 ? bf_result
                     : ex_is_tas                ? tas_res
                     : ex_is_exg                ? ex_a_u
                     : ex_is_link               ? (ex_sp - 32'd4)
                     : ex_is_unlk               ? mem_hold
                     : (ex_is_sys && (ex_uop.subop == 4'd5)) ? usp_r
                     : (ex_is_sys && (ex_uop.subop <= 4'd1)) ? sys_rd_val
                     : ex_is_push               ? (ex_sp - 32'd4)
                     : ex_is_rte                ? (ex_ea
                                                   + ((ex_uop.subop == 4'd3)
                                                      ? 32'd8 : 32'd6))
                     : ex_is_lea                ? ex_ea
                     : ex_is_scc                ? scc_result
                     : ex_is_dbcc               ? dbcc_result
                     // MOVEA only: its result genuinely IS the sign-extended
                     // source. For ADDA/SUBA/CMPA the extension has already been
                     // applied to the operand above, and the result is the
                     // arithmetic.
                     : (ex_uop.sext_src && use_mv) ? ex_src
                                              : ex_result;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid   <= 1'b0;
            wb_reg     <= 4'h0;
            wb_data    <= 32'h0;
            wb_writes  <= 1'b0;
            wb_ccr     <= 8'h0;
            wb_upd_ccr <= 1'b0;
        end else if (!stall_ex) begin
            wb_valid   <= ex_valid;
            // A push and a status-word return both commit A7, which is not
            // the destination their encoding names.
            wb_reg     <= (ex_is_push || ex_is_rte) ? REG_A7
                        : ex_movep_rd               ? ex_uop.imm[3:0]
                                                    : ex_uop.dst_reg;
            wb_data    <= ex_commit;
            // DBcc writes Dn only when it actually decrements.
            wb_writes  <= (ex_valid && ex_uop.writes_reg && !ex_is_branch
                                    && !exc_discards && !div_ovf
                                    && !ex_uop.writes_mem
                                    && (!ex_is_dbcc || dbcc_dec)
                                    && !ex_is_rts)
                       || ex_is_push || ex_is_rte
                       // LINK commits An although it also writes memory,
                       // which the clause above excludes.
                       || (ex_is_link && ex_uop.writes_reg)
                       || ex_movep_rd
                       // A CAS that did not match commits the operand into Dc
                       // and writes no memory at all.
                       || (ex_is_cas && mem_got && !cas_eq);
            // MOVE <ea>,CCR and MOVE <ea>,SR write the status register
            // DIRECTLY, in EX. Letting the ordinary WB flag update run as well
            // would land a cycle later and overwrite the transferred value
            // with whatever the datapath happened to compute.
            // The decoder reports updates_ccr=0 for every memory-destination
            // read-modify-write and for TAS, because the reference computes
            // their flags inside its own RMW state machine rather than from the
            // decode flag. This core has no such machine, so the flags are
            // claimed here instead -- without this, NO RMW has ever updated the
            // CCR at all, which nothing noticed because no test read an RMW's
            // flags until TAS needed them.
            wb_upd_ccr <= ex_valid && (ex_uop.updates_ccr || ex_is_tas || ex_rmw
                                       || ex_is_cmp2 || ex_is_alu_mem_wr)
                                   && !ex_is_branch
                       && !exc_discards
                       && !(ex_is_sys && (ex_uop.subop >= 4'd2)
                                      && (ex_uop.subop <= 4'd3));
            wb_ccr     <= {3'b000,
                           ex_uop.x_unchanged ? ccr_live[4] : ex_x,
                           ex_n, ex_z, ex_v, ex_c};
        end else begin
            wb_valid   <= 1'b0;      // bubble while EX waits on memory
            wb_writes  <= 1'b0;
            wb_upd_ccr <= 1'b0;
        end
    end

    // A return that popped a status word restores the CCR from it, in the
    // cycle stall_ex drops -- ahead of an ordinary WB update, because the
    // popped value is the architectural state and must not be overwritten by
    // whatever the pop's own address arithmetic happened to compute.
    wire rte_commit = ex_is_rte && rte_done;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)            ccr_r <= 8'h0;
        else if (rte_commit)   ccr_r <= rte_sr[7:0];
        else if (ex_is_sys && (ex_uop.subop >= 4'd2) && (ex_uop.subop <= 4'd3)
                 && !stall_ex)
                               ccr_r <= sys_wr_val[7:0];
        else if (ex_is_stop && !stall_ex)
                               ccr_r <= ex_uop.imm[7:0];
        else if (wb_upd_ccr)   ccr_r <= wb_ccr;
    end

    // The system byte. Only RTE restores it; RTR is a user instruction and
    // leaves it alone. A trap forces supervisor state and clears tracing,
    // which is what makes the frame it just pushed the only way back.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                           sr_sys_r <= 8'h27;
        else if (rte_commit && (ex_uop.subop == 4'd3))
                                              sr_sys_r <= rte_sr[15:8];
        else if (ex_is_sys && (ex_uop.subop == 4'd3) && !stall_ex)
                                              sr_sys_r <= sys_wr_val[15:8];
        else if (ex_is_stop && !stall_ex)     sr_sys_r <= ex_uop.imm[15:8];
        // An interrupt also raises the mask to its own level, so it cannot
        // immediately re-interrupt its own handler. M survives; T does not.
        else if (int_dispatched)
                                              sr_sys_r <= {2'b00, 1'b1,
                                                           sr_sys_r[4], 1'b0,
                                                           exc_ilevel_r};
        else if (ex_is_trap && exc_taken && !stall_ex)
                                              sr_sys_r <= (sr_sys_r | 8'h20)
                                                          & 8'h3F;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)          div_started <= 1'b0;
        else if (!stall_ex)  div_started <= 1'b0;   // instruction leaving EX
        else if (div_can_start) div_started <= 1'b1;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)          mul_started <= 1'b0;
        else if (!stall_ex)  mul_started <= 1'b0;
        else if (mul_can_start) mul_started <= 1'b1;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mvp_idx  <= 3'd0;
            mvp_addr <= 32'h0;
            mvp_sh   <= 32'h0;
            mvp_acc  <= 32'h0;
            mvp_run  <= 1'b0;
            mvp_done <= 1'b0;
        end else if (!ex_is_movep) begin
            mvp_idx  <= 3'd0;
            mvp_run  <= 1'b0;
            mvp_done <= 1'b0;
        end else if (!mvp_run) begin
            mvp_run  <= 1'b1;
            mvp_addr <= ex_ea;
            mvp_sh   <= mvp_sh_init;
            mvp_acc  <= 32'h0;
        end else if (mem_ack) begin
            mvp_addr <= mvp_addr + 32'd2;        // every OTHER byte
            mvp_sh   <= {mvp_sh[23:0], 8'h0};
            mvp_acc  <= {mvp_acc[23:0], mem_rdata[7:0]};
            if (mvp_last) mvp_done <= 1'b1;
            else          mvp_idx  <= mvp_idx + 3'd1;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mvm_idx  <= 4'd0;
            mvm_addr <= 32'h0;
            mvm_run  <= 1'b0;
            mvm_done <= 1'b0;
        end else if (!ex_is_movem) begin
            mvm_idx   <= 4'd0;
            mvm_run   <= 1'b0;
            mvm_done  <= 1'b0;
            mvm_ready <= 1'b0;
        end else if (!mvm_run) begin
            mvm_run   <= 1'b1;           // latch the starting address
            mvm_addr  <= ex_b;
            mvm_ready <= 1'b0;
        end else if (!mvm_ready) begin
            mvm_ready <= 1'b1;           // C-port read has landed
        end else if (!mvm_bit) begin
            // Clear mask bit: nothing to transfer, just advance.
            if (mvm_last) mvm_done <= 1'b1;
            else begin mvm_idx <= mvm_idx + 4'd1; mvm_ready <= 1'b0; end
        end else if (mem_ack) begin
            mvm_addr <= mvm_predec ? (mvm_addr - mvm_step)
                                   : (mvm_addr + mvm_step);
            if (mvm_last) mvm_done <= 1'b1;
            else begin mvm_idx <= mvm_idx + 4'd1; mvm_ready <= 1'b0; end
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            exc_state    <= XS_IDLE;
            exc_base_r   <= 32'h0;
            exc_sp       <= 32'h0;
            exc_vec_addr <= 32'h0;
            exc_taken    <= 1'b0;
        end else if (!ex_is_trap) begin
            exc_state <= XS_IDLE;
            exc_taken <= 1'b0;
        end else begin
            case (exc_state)
                XS_IDLE: begin
                             exc_state  <= XS_PC;
                             exc_base_r <= sp_live;
                             exc_sp     <= sp_live - 32'd8;
                         end
                XS_PC:   if (mem_ack) exc_state <= XS_SR;
                XS_SR:   if (mem_ack) exc_state <= XS_VEC;
                XS_VEC:  if (mem_ack) begin
                             exc_vec_addr <= mem_rdata;
                             exc_taken    <= 1'b1;
                         end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rst_state  <= RS_SSP;
            rst_issued <= 1'b0;
            rst_pc     <= 32'h0;
        end else if (in_reset_seq) begin
            if (!rst_issued) rst_issued <= 1'b1;
            else if (mem_ack) begin
                rst_issued <= 1'b0;
                if (rst_state == RS_SSP) rst_state <= RS_PC;
                else begin
                    rst_state <= RS_DONE;
                    rst_pc    <= mem_rdata;
                end
            end
        end
    end


    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            exc_pend      <= 1'b0;
            trap_decided  <= 1'b0;
            exc_vec_r     <= 10'h0;
            exc_retself_r <= 1'b0;
            exc_disc_r    <= 1'b0;
            exc_isint_r   <= 1'b0;
            exc_ilevel_r  <= 3'h0;
            chk_n_r       <= 1'b0;
            chk_z_r       <= 1'b0;
            cmp2_c_r      <= 1'b0;
            cmp2_z_r      <= 1'b0;
        end else if (!stall_ex) begin
            // Instruction leaving EX. exc_disc_r must clear here too: it
            // suppresses register and flag writes, and leaving it set made
            // every instruction AFTER a fault -- the handler's own first
            // instruction included -- silently commit nothing.
            exc_pend      <= 1'b0;
            trap_decided  <= 1'b0;
            exc_disc_r    <= 1'b0;
            exc_isint_r   <= 1'b0;
        end else if (ex_decide) begin
            trap_decided  <= 1'b1;
            exc_pend      <= exc_req_raw;
            exc_vec_r     <= exc_vec_sel;
            // An interrupt and an A-line trap both return to the instruction
            // itself: one because nothing of it ran, the other so the emulator
            // handler can decode it.
            exc_retself_r <= int_take || ex_linea;
            // Only an abandoned instruction suppresses its own writes. CHK and
            // TRAPV leave defined flags behind even when they trap.
            exc_disc_r    <= int_take || div_zero;
            exc_isint_r   <= int_take;
            exc_ilevel_r  <= int_level;
            // Both flag contributions, captured here so the comparators stay
            // out of the flag mux as well as out of the stall.
            chk_n_r       <= chk_traps ? chk_below : ccr_live[3];
            chk_z_r       <= chk_z;
            cmp2_c_r      <= cmp2_c;
            cmp2_z_r      <= cmp2_z;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cmp2_p2_issued <= 1'b0;
            cmp2_done      <= 1'b0;
            cmp2_lb        <= 32'h0;
        end else if (!stall_ex) begin
            cmp2_p2_issued <= 1'b0;
            cmp2_done      <= 1'b0;
        end else if (ex_is_cmp2) begin
            if (mem_got && !cmp2_p2_issued) begin
                cmp2_p2_issued <= 1'b1;
                cmp2_lb        <= mem_hold;
            end else if (cmp2_p2_issued && mem_ack) cmp2_done <= 1'b1;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rte_p2_issued <= 1'b0;
            rte_done      <= 1'b0;
            rte_sr        <= 16'h0;
        end else if (!stall_ex) begin
            rte_p2_issued <= 1'b0;          // instruction leaving EX
            rte_done      <= 1'b0;
        end else if (ex_is_rte) begin
            if (mem_got && !rte_p2_issued) begin
                rte_p2_issued <= 1'b1;
                rte_sr        <= mem_hold[15:0];
            end else if (rte_p2_issued && mem_ack) rte_done <= 1'b1;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            bcdm_ph  <= 2'd0;
            bcdm_src <= 32'h0;
        end else if (!stall_ex) begin
            bcdm_ph  <= 2'd0;           // instruction leaving EX
        end else if (ex_m2m_2rd && mem_ack) begin
            // The source value has to be kept: mem_hold is about to be
            // overwritten by the destination read.
            if (bcdm_ph == 2'd0) bcdm_src <= mem_rdata;
            // CMPM compares and writes nothing, so it retires at the end of the
            // second READ rather than going on to a write phase.
            if (bcdm_ph == 2'd1) bcdm_ph <= ex_uop.writes_mem ? 2'd2 : 2'd3;
            else if (bcdm_ph != 2'd3) bcdm_ph <= bcdm_ph + 2'd1;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            rmw_wr_issued <= 1'b0;
            rmw_done      <= 1'b0;
        end else if (!stall_ex) begin
            rmw_wr_issued <= 1'b0;          // instruction leaving EX
            rmw_done      <= 1'b0;
        end else if (ex_rmw) begin
            if (mem_got && !rmw_wr_issued) begin
                rmw_wr_issued <= 1'b1;
                // A CAS mismatch never issues the write, so it must retire the
                // sequence here or the stall would never clear.
                if (cas_skip_wr) rmw_done <= 1'b1;
            end else if (rmw_wr_issued && mem_ack) rmw_done  <= 1'b1;
        end
    end

    // EXG swaps, LINK sets An and A7, UNLK restores An and A7. The register
    // the SECOND port writes, and what it writes there.
    // A memory-to-memory move has TWO address registers to maintain, and only
    // the source's was being updated: ag_an_upd handles ag_uop.ea_reg, and
    // nothing handled dst_ea_reg. So MOVE.b (A7)+,(A4)+ advanced A7 and left A4
    // where it was. The second write port already exists for EXG and LINK, and
    // this is the same shape -- one instruction, two register commits.
    wire [31:0] m2m_step = ex_m2m_step;
    wire ex_m2m_an = ex_m2m
                  && ((ex_uop.dst_ea_mode == UEA_AN_POST)
                   || (ex_uop.dst_ea_mode == UEA_AN_PRE));

    wire        ex_dual_commit = ex_is_exg || ex_is_link || ex_is_unlk
                              || ex_m2m_an;
    wire [3:0]  ex_wr2_sel  = ex_is_exg  ? ex_uop.src_reg
                            : ex_m2m_an  ? ex_uop.dst_ea_reg : REG_A7;
    wire [31:0] ex_wr2_data = ex_is_exg  ? ex_b_u
                            : ex_m2m_an
                              ? ((ex_uop.dst_ea_mode == UEA_AN_POST)
                                 ? (m2m_base + m2m_step)
                                 : (m2m_base - m2m_step))
                            : ex_is_link ? (ex_sp - 32'd4 + ex_uop.imm)
                                         : (ex_b_u + 32'd4);   // UNLK

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            wb2_en   <= 1'b0;
            wb2_sel  <= 4'h0;
            wb2_data <= 32'h0;
        end else if (!stall_ex) begin
            wb2_en   <= ex_dual_commit;
            wb2_sel  <= ex_wr2_sel;
            wb2_data <= ex_wr2_data;
        end else begin
            wb2_en   <= 1'b0;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            wbp2_en   <= 1'b0;
            wbp2_sel  <= 4'h0;
            wbp2_data <= 32'h0;
        end else begin
            wbp2_en   <= wb2_en;
            wbp2_sel  <= wb2_sel;
            wbp2_data <= wb2_data;
        end
    end

    // ── Interrupt input synchroniser and the level-7 latch ──────────────────

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ipl_s1 <= 3'b000; ipl_s2 <= 3'b000; ipl_s3 <= 3'b000;
        end else begin
            ipl_s1 <= ipl;
            ipl_s2 <= ipl_s1;
            ipl_s3 <= ipl_s2;     // one more stage, purely for the 7-edge test
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)              nmi_pend <= 1'b0;
        else if (nmi_edge)       nmi_pend <= 1'b1;
        else if (int_dispatched) nmi_pend <= 1'b0;
    end

    // ── USP ─────────────────────────────────────────────────────────────────
    // A supervisor-only register with no other purpose than to be swapped in
    // and out of A7 by MOVE USP. No privilege check yet -- that needs the
    // privilege-violation vector, which is a later phase.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) usp_r <= 32'h0;
        else if (ex_is_sys && (ex_uop.subop == 4'd4) && !stall_ex)
            usp_r <= ex_b_u;
        else if (ex_movec_wr && (movec_rc == 12'h800) && !stall_ex)
            usp_r <= ex_a_u;
    end

    // One-cycle history of the commit, for the second forwarding level.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            wbp_valid  <= 1'b0;
            wbp_writes <= 1'b0;
            wbp_reg    <= 4'h0;
            wbp_data   <= 32'h0;
        end else begin
            wbp_valid  <= wb_valid;
            wbp_writes <= wb_writes;
            wbp_reg    <= wb_reg;
            wbp_data   <= wb_data;
        end
    end

    // (An)+ / -(An) commit their An update from AG, sharing the write port.
    // Nothing in this phase's subset both updates An and commits an ALU
    // result in the same cycle.
    // A completed trap leaves A7 below the frame it pushed.
    wire exc_commit_sp = ex_is_trap && exc_taken && !stall_ex;
    // The supervisor stack pointer, straight from address 0.
    wire rst_commit_sp = (rst_state == RS_SSP) && rst_issued && mem_ack;
    // MOVEM memory-to-register commits one register per acknowledged read,
    // straight from the sequencer rather than through WB.
    wire mvm_reg_wr = ex_is_movem && ex_uop.reads_mem && mvm_run
                   && mvm_bit && mem_ack;
    assign wb_wr_en   = (wb_valid && wb_writes) || ag_an_upd || exc_commit_sp
                      || mvm_reg_wr || rst_commit_sp;
    assign wb_wr_sel  = rst_commit_sp ? 4'd15
                      : mvm_reg_wr    ? mvm_reg
                      : exc_commit_sp ? 4'd15
                      : ag_an_upd     ? ag_uop.ea_reg : wb_reg;
    assign wb_wr_data = rst_commit_sp ? mem_rdata
                      : mvm_reg_wr    ? (ex_uop.xfer_long ? mem_rdata
                                         : {{16{mem_rdata[15]}}, mem_rdata[15:0]})
                      : exc_commit_sp ? exc_sp
                      : ag_an_upd     ? ag_an_val     : wb_data;
    // Held from the read's dispatch until the write is acknowledged. A CAS
    // mismatch retires early, and rmw_done going high drops this with it.
    assign mem_lock   = ex_rmw && !rmw_done;
    assign ccr_out    = ccr_r;

endmodule

`default_nettype wire

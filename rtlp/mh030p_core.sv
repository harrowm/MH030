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
                  || (dec_uop.ea_mode == UEA_ABS_L);

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
    wire dec_dst_ea_ok = (dec_uop.dst_ea_mode == UEA_AN_IND)
                      || (dec_uop.dst_ea_mode == UEA_AN_POST)
                      || (dec_uop.dst_ea_mode == UEA_AN_PRE)
                      || (dec_uop.dst_ea_mode == UEA_AN_D16);

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
                        || (dec_uop.uclass == UC_MOVEM))
                       && ((dec_uop.uclass == UC_BRANCH)
                           || ((dec_uop.uclass == UC_SCC)  && !dec_uop.writes_mem)
                           || (dec_uop.uclass == UC_DBCC)
                           // RTS commits to no register, so it would fail the
                           // destination check below; it needs its EA instead.
                           || ((dec_uop.uclass == UC_RETURN) && dec_ea_ok)
                           || (dec_uop.uclass == UC_TRAP)
                           || (dec_uop.uclass == UC_NOP)
                           || ((dec_uop.uclass == UC_MOVEM) && dec_ea_ok)
                           || dec_ea_class_ok
                           || (dec_mem2mem ? (dec_ea_ok && dec_dst_ea_ok)
                           :   dec_rmw     ? dec_ea_ok
                           :   dec_pure_wr ? (dec_ea_ok && (dec_uop.uclass == UC_MOVE))
                                           : (dec_uop.dst_kind == US_DREG
                                              || dec_uop.dst_kind == US_AREG)))
                       && (!dec_uop.reads_mem || dec_ea_ok);

    // ── Stage registers ─────────────────────────────────────────────────────
    uop_t ag_uop, ex_uop;
    reg   ag_valid, ex_valid;
    // Declared here because the stall below uses mem_got; assigned further
    // down beside the bus request.
    reg        mem_got;
    reg [31:0] mem_hold;
    reg [31:0] ag_pc, ex_pc;
    // Which register the B port carried; needed by the interlock below.
    wire ag_is_trap  = (ag_uop.uclass == UC_TRAP);
    wire ag_is_movem = (ag_uop.uclass == UC_MOVEM);
    // LEA/PEA/JMP/JSR need the EA base on the B port exactly as a memory
    // operand does, even though LEA and JMP issue no bus cycle at all.
    wire ag_ea_class = (ag_uop.uclass == UC_LEA) || (ag_uop.uclass == UC_JMP);
    wire ag_mem     = ag_uop.reads_mem || ag_uop.writes_mem || ag_is_trap
                   || ag_ea_class;
    wire ag_is_bsr = (ag_uop.uclass == UC_BRANCH) && (ag_uop.cond == 4'h1);
    // PEA / JSR: the bus cycle goes to -(A7), not to the computed EA.
    wire ag_is_push = ag_ea_class && ag_uop.writes_mem;
    wire ag_is_jsr  = (ag_uop.uclass == UC_JMP) && ag_uop.writes_mem;
    // RTE and RTR pop a 16-bit status word BEFORE the PC; RTS (imm 5) does
    // not. See the two-phase return sequence in EX.
    wire ag_is_rte  = (ag_uop.uclass == UC_RETURN) && (ag_uop.imm[3:0] != 4'd5);
    wire [3:0] ag_b_sel = ag_mem ? ag_uop.ea_reg : ag_uop.dst_reg;
    // Must mirror rd_a_sel exactly. When these two disagree the AG forwarding
    // and the interlock track a different register than the one actually read.
    wire [3:0] ag_c_sel = ag_is_push ? 4'd15 : ag_uop.ea_idx_reg;
    wire [3:0] ag_a_sel = (ag_uop.dst_ea_mode != UEA_NONE) ? ag_uop.dst_ea_reg
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
    wire ex_is_rte = ex_is_ret && (ex_uop.imm[3:0] != 4'd5);
    reg        rte_p2_issued, rte_done;
    reg [15:0] rte_sr;

    // The status register's SYSTEM byte (T/S/M/IPL). The CCR half lives in
    // ccr_r. Until now the SR pushed by a trap was synthesised as a constant
    // 0x20 with a supervisor bit hardcoded, which was enough to build a frame
    // but not to RESTORE one -- an RTE has to put back what was there.
    // Reset leaves S=1 and the interrupt mask at 7 (MC68030UM section 8.1.1).
    reg [7:0] sr_sys_r;

    wire ex_rmw = ex_valid && ex_uop.reads_mem && ex_uop.writes_mem;
    wire ex_m2m = ex_rmw && (ex_uop.dst_ea_mode != UEA_NONE);
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

    // Register-file read data; declared here because the MOVEM sequencer
    // below repurposes the C port.
    wire [31:0] rf_a, rf_b, rf_c;

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

    // ── Exception sequence ──────────────────────────────────────────────────
    // A trap is three bus cycles: push the return PC, push the SR, then read
    // the vector and jump to it. That is the first thing in this core with a
    // multi-cycle sequence of its OWN rather than a second phase bolted onto
    // an instruction, so it gets a small state machine that owns the memory
    // port while it runs.
    localparam [1:0] XS_IDLE = 2'd0, XS_PC = 2'd1, XS_SR = 2'd2, XS_VEC = 2'd3;
    // Declared here because the exception FSM below pushes it; assigned near
    // the functional units.
    reg  [7:0]  ccr_r;

    reg  [1:0]  exc_state;
    reg  [31:0] exc_sp;
    // The PC the handler returns to, latched rather than recomputed: it is
    // needed by two different states, and ex_pc is only stable while the
    // instruction is held in EX.
    wire [31:0] exc_ret_pc = ex_pc + 32'd2;
    reg  [31:0] exc_vec_addr;
    reg         exc_taken;

    wire ex_is_trap  = ex_valid && (ex_uop.uclass == UC_TRAP);
    wire exc_running = (exc_state != XS_IDLE);

    wire ex_wait_mem = ex_valid && (ex_uop.reads_mem || ex_uop.writes_mem)
                    && (ex_rmw ? !rmw_done : !mem_got);

    // Divide is multi-cycle: rtl/eu_mul_div.sv iterates one 32-bit
    // compare+subtract per tick rather than instantiating a combinational
    // division array. Multiply stays combinational (it maps to DSPs), so only
    // the divide needs a handshake. div_started is cleared when the
    // instruction actually leaves EX, which is what makes div_start a
    // one-shot rather than a level that re-triggers every stalled cycle --
    // the same shape the (An)+ side effect already had to be fixed for.
    wire ex_is_div = ex_valid && (ex_uop.unit == UU_DIV);
    reg  div_started;
    wire md_div_start = ex_is_div && !div_started;
    wire md_div_busy;
    wire ex_wait_div  = ex_is_div && (!div_started || md_div_busy);

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
                      || (((ag_uop.ea_mode == UEA_AN_IDX) || ag_is_push)
                          && (ex_uop.dst_reg == ag_c_sel)));

    // TWO stalls, and they must not be conflated. ex_wait_mem freezes the
    // whole pipeline, because EX itself cannot complete. ag_base_busy must
    // NOT freeze EX: the producer it is waiting for IS in EX, so holding EX
    // as well deadlocks -- the interlock can never clear. It holds ID/AG and
    // lets EX drain, inserting a bubble.
    wire ex_wait_rte = ex_is_rte && !rte_done;

    wire stall_ex = ex_wait_mem || ex_wait_div || ex_wait_rte
                 || (ex_is_trap && !exc_taken)
                 || (ex_is_movem && !mvm_done);
    wire stall_ag = ag_base_busy;

    assign instr_ready = !stall_ex && !stall_ag;

    // ── Register file: address in ID, data in AG ────────────────────────────
    // With a memory source the B port carries the EA BASE register instead of
    // the ALU destination; the destination is forwarded in EX.
    // A TRAP also needs A7 on the B port, to build its stack frame.
    wire dec_is_trap = (dec_uop.uclass == UC_TRAP);
    wire dec_mem = dec_uop.reads_mem || dec_uop.writes_mem || dec_is_trap
                || dec_is_ea_class;
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
        .rd_a_sel ((dec_uop.dst_ea_mode != UEA_NONE) ? dec_uop.dst_ea_reg
                   : (dec_uop.reads_mem && !dec_uop.writes_mem)
                     ? dec_uop.dst_reg : dec_uop.src_reg),
        .rd_b_sel (dec_mem ? dec_uop.ea_reg   : dec_uop.dst_reg),
        // Index register for an indexed EA; harmlessly reads R0 otherwise.
        // Index register for an indexed EA, or the register MOVEM is about to
        // transfer. Those two never overlap.
        .rd_c_sel (ex_is_movem ? mvm_reg
                   : dec_is_push ? 4'd15 : dec_uop.ea_idx_reg),
        .rd_a_data(rf_a),
        .rd_b_data(rf_b),
        .rd_c_data(rf_c),
        .wr_en    (wb_wr_en),
        .wr_sel   (wb_wr_sel),
        .wr_data  (wb_wr_data)
    );

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ag_valid <= 1'b0;
            ag_uop   <= uop_clear();
        end else if (!stall_ex && !stall_ag) begin
            // A taken branch squashes whatever is behind it.
            ag_valid <= instr_valid && dec_executable && !redirect;
            ag_uop   <= dec_uop;
            ag_pc    <= pc_in;
        end else if (redirect) begin
            ag_valid <= 1'b0;
        end
    end

    // ── EX/WB boundary ──────────────────────────────────────────────────────
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

    wire [31:0] ag_a = fwd_h_wb ? wb_data : fwd_h_wbp ? wbp_data : rf_a;
    wire [31:0] ag_b = fwd_g_wb ? wb_data : fwd_g_wbp ? wbp_data : rf_b;
    wire fwd_i_wb  = wb_valid  && wb_writes  && (wb_reg  == ag_c_sel);
    wire fwd_i_wbp = wbp_valid && wbp_writes && (wbp_reg == ag_c_sel);
    wire [31:0] ag_c = fwd_i_wb ? wb_data : fwd_i_wbp ? wbp_data : rf_c;

    // ── AG: effective address, on its own adder ─────────────────────────────
    wire [31:0] ea_step = (ag_uop.siz == UZ_BYTE) ? 32'd1
                        : (ag_uop.siz == UZ_WORD) ? 32'd2 : 32'd4;
    // Absolute modes have no base register; the address is the displacement.
    wire [31:0] ea_base = ((ag_uop.ea_mode == UEA_ABS_W)
                        || (ag_uop.ea_mode == UEA_ABS_L)) ? 32'h0 : ag_b;
    // Predecrement applies to the address used THIS cycle; postincrement
    // does not.
    wire [31:0] ea_adj  = (ag_uop.ea_mode == UEA_AN_PRE) ? (32'h0 - ea_step)
                                                         : 32'h0;
    // Index term: Xn as a word (sign-extended) or a longword, scaled by
    // 1/2/4/8. Only the brief format is handled here; the full format with a
    // base displacement and memory indirection is a later phase.
    wire [31:0] ag_xn   = ag_uop.ea_idx_long ? ag_c
                                             : {{16{ag_c[15]}}, ag_c[15:0]};
    wire [31:0] ag_idx  = (ag_uop.ea_mode == UEA_AN_IDX)
                        ? (ag_xn << ag_uop.ea_idx_scale) : 32'h0;

    wire [31:0] ag_ea   = ea_base + ag_uop.ea_disp + ea_adj + ag_idx;

    // The An update is a SIDE EFFECT and must commit exactly once, when the
    // instruction actually leaves AG. Gating it on ag_valid alone makes it
    // level-sensitive, so every cycle EX spends stalled on memory applies the
    // increment again -- (A3)+ advanced by 12 instead of 4.
    // A push adjusts A7, and a return that pops a status word adjusts A7 by
    // 6 rather than by one operand size -- both are committed from EX instead,
    // because AG's step is derived from the operand size and cannot express
    // either. Leaving the AG update in as well would apply BOTH.
    wire ag_an_upd = ag_valid && ag_mem && !ag_is_trap && !ag_is_movem
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

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid <= 1'b0;
            ex_uop   <= uop_clear();
            ex_a     <= 32'h0;
            ex_b     <= 32'h0;
            ex_ea    <= 32'h0;
            ex_sp    <= 32'h0;
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
            ex_b     <= ag_b;
            ex_ea    <= ag_ea;
            ex_sp    <= ag_c;
            // Gated by !stall_ag as well as ex_valid: while AG is held for
            // the address-base interlock its EA is still computed from the
            // stale base, so issuing the request there sends a wrong address.
            // That is exactly what happened -- the first memory access went
            // out with addr=0 before A3 had been written.
            mem_req  <= ag_valid && (ag_uop.reads_mem || ag_uop.writes_mem)
                                 && !stall_ag && !ag_is_trap && !ag_is_movem;
            // A push goes to -(A7); everything else to the computed EA.
            mem_addr <= ag_is_push ? (ag_c - 32'd4) : ag_ea;
            // Read if the instruction reads, regardless of whether it also
            // writes: an RMW's FIRST bus cycle is the read, and the write is
            // turned around later from EX. Deriving this from writes_mem made
            // every RMW start with a write.
            mem_rw   <= ag_uop.reads_mem;
            // A return that pops a status word reads it as a WORD; the PC
            // that follows is a separate longword, issued from EX.
            mem_siz  <= ag_is_rte ? UZ_WORD : ag_uop.siz;
            // A pure write's data is the source operand, which AG already
            // has: the A port for a register source, or the immediate.
            // BSR stores the RETURN ADDRESS, not a register: the address of
            // the instruction after the branch, which is the branch plus its
            // own extension words.
            // JSR pushes the same return address BSR does. PEA pushes the
            // effective address itself, which is the whole point of it.
            mem_wdata<= (ag_is_bsr || ag_is_jsr)
                        ? (ag_pc + 32'd2 + {27'h0, ag_uop.ext_words, 1'b0})
                      : ag_is_push ? ag_ea
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
                    mem_addr  <= ex_b - 32'd8;
                    mem_wdata <= {sr_sys_r, ccr_live, exc_ret_pc[31:16]};
                end
                XS_PC: if (mem_ack) begin
                    mem_req   <= 1'b1;
                    mem_rw    <= 1'b0;
                    mem_addr  <= ex_b - 32'd4;
                    // Format 0, vector OFFSET (4 x the vector number).
                    mem_wdata <= {exc_ret_pc[15:0],
                                  4'h0, ex_uop.imm[9:0], 2'b00};
                end
                XS_SR: if (mem_ack) begin            // fetch the vector
                    mem_req   <= 1'b1;
                    mem_rw    <= 1'b1;
                    mem_addr  <= {ex_uop.imm[23:0], 2'b00};
                end
                default: if (mem_ack) mem_req <= 1'b0;
            endcase
        end else if (ex_rmw && mem_got && !rmw_wr_issued) begin
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
            mem_got  <= 1'b1;
            mem_hold <= mem_rdata;
        end else if (!stall_ex) begin
            mem_got  <= 1'b0;
        end
    end

    // ── EX operands ─────────────────────────────────────────────────────────
    // Which register each carried port holds depends on the operand shape:
    //   memory source : A = ALU destination, B = EA base
    //   otherwise     : A = ALU source,      B = ALU destination
    wire ex_rmw_op = ex_uop.reads_mem && ex_uop.writes_mem;
    wire [3:0] ex_a_sel = (ex_uop.dst_ea_mode != UEA_NONE) ? ex_uop.dst_ea_reg
                        : (ex_uop.reads_mem && !ex_uop.writes_mem)
                          ? ex_uop.dst_reg : ex_uop.src_reg;

    wire fwd_a_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_a_sel);
    wire fwd_a_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_a_sel);
    wire fwd_b_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_uop.dst_reg);
    wire fwd_b_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_uop.dst_reg);

    wire [31:0] ex_a_f = fwd_a_wb ? wb_data : fwd_a_wbp ? wbp_data : ex_a;
    wire [31:0] ex_b_f = fwd_b_wb ? wb_data : fwd_b_wbp ? wbp_data : ex_b;

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
    wire [31:0] ex_src = ex_m2m                      ? mem_hold
                       : ex_rmw_op                   ? ex_a_f
                       : ex_uop.reads_mem            ? mem_hold
                       : (ex_uop.src_kind == US_IMM) ? ex_uop.imm
                                                     : ex_a_f;
    wire [31:0] ex_dst = ex_m2m           ? mem_hold
                       : ex_rmw_op        ? mem_hold
                       : ex_uop.reads_mem ? ex_a_f
                                          : ex_b_f;

    // ── Functional units ────────────────────────────────────────────────────
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
    wire [31:0] md_lo, md_hi;
    wire md_n, md_z, md_v, md_c, md_dbz;
    eu_mul_div u_md (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .div_start(md_div_start), .div_busy(md_div_busy),
        .src(ex_src), .dst(ex_dst),
        // md_op is 3 bits; the uop keeps it in the shared 4-bit alu_op field.
        .op(ex_uop.alu_op[2:0]),
        .result_lo(md_lo), .result_hi(md_hi),
        .n_out(md_n), .z_out(md_z), .v_out(md_v), .c_out(md_c),
        .div_by_zero(md_dbz)
    );

    wire [31:0] ex_m2m_step = (ex_uop.siz == UZ_BYTE) ? 32'd1
                            : (ex_uop.siz == UZ_WORD) ? 32'd2 : 32'd4;
    assign ex_m2m_addr = ex_a_f + ex_uop.dst_ea_disp
                       + ((ex_uop.dst_ea_mode == UEA_AN_PRE)
                          ? (32'h0 - ex_m2m_step) : 32'h0);

    // Bit operations: BTST/BCHG/BCLR/BSET. The bit number is the source
    // operand mod 32 for a Dn destination.
    wire [31:0] bit_result;
    wire        bit_z;
    eu_bitops u_bit (
        .dst(ex_dst), .bit_num(ex_src[4:0]),
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
    wire [31:0] ext_result = (ex_uop.siz == UZ_WORD)
                           ? {ex_dst[31:16], {8{ex_dst[7]}}, ex_dst[7:0]}
                           : (ex_uop.ext_words == 3'd0 && ex_uop.siz == UZ_LONG)
                             ? {{16{ex_dst[15]}}, ex_dst[15:0]} : ex_dst;
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
    wire use_mv  = (ex_uop.unit == UU_MOVE);
    wire use_md  = (ex_uop.unit == UU_MUL) || (ex_uop.unit == UU_DIV);

    // EXT and SWAP ride the MOVE unit in the reference decoder, so they are
    // selected by class rather than by unit.
    wire [31:0] ex_result = use_bit  ? bit_result
                          : use_bcd  ? {ex_dst[31:8], bcd_result}
                          : use_ext  ? ext_result
                          : use_swap ? swap_result
                          : use_md   ? md_lo
                          : use_shf  ? shf_result
                          : use_mv   ? mv_result : alu_result;

    wire mv_like_n = use_ext  ? ext_result[31]
                   : use_swap ? swap_result[31] : mv_n;
    wire mv_like_z = use_ext  ? (ext_result == 32'h0)
                   : use_swap ? (swap_result == 32'h0) : mv_z;

    wire ex_n = use_bit ? 1'b0 : use_bcd ? bcd_n
              : use_md  ? md_n : use_shf ? shf_n
              : (use_mv || use_ext || use_swap) ? mv_like_n : alu_n;
    wire ex_z = use_bit ? bit_z : use_bcd ? bcd_z
              : use_md  ? md_z  : use_shf ? shf_z
              : (use_mv || use_ext || use_swap) ? mv_like_z : alu_z;
    wire ex_v = use_bit ? 1'b0 : use_bcd ? bcd_v
              : use_md  ? md_v : use_shf ? shf_v
              : (use_mv || use_ext || use_swap) ? 1'b0 : alu_v;
    wire ex_c = use_bit ? 1'b0 : use_bcd ? bcd_c
              : use_md  ? md_c : use_shf ? shf_c
              : (use_mv || use_ext || use_swap) ? 1'b0 : alu_c;
    // alu_x was missing from this mux: every unit's X came from somewhere
    // except the ALU's, so ADD/SUB/NEG/ADDX/SUBX left X at whatever it already
    // held. It went unnoticed because the uop's own x_unchanged flag covers
    // the instructions that genuinely must not touch X (MOVE, CMP, AND, OR,
    // EOR, TST), which is the majority -- so the wrong answer and the right
    // one agree everywhere except on exactly the arithmetic that chains.
    wire ex_x = use_bit ? ccr_live[4] : use_bcd ? bcd_x
              : use_md  ? ccr_live[4] : use_shf ? shf_x
              : (use_mv || use_ext || use_swap) ? ccr_live[4] : alu_x;

    // MOVEA writes all 32 bits, sign-extending a word source.
    // ── Branch resolution, in EX where the CCR is settled ───────────────────
    // Resolved rather than predicted: this core has no predictor, so a taken
    // branch squashes whatever is behind it in ID and AG. That is a real
    // two-cycle penalty per taken branch, and the reason a predictor
    // eventually earns its place.
    wire cc_n = ccr_live[3], cc_z = ccr_live[2],
         cc_v = ccr_live[1], cc_c = ccr_live[0];
    reg  cond_true;
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
    assign redirect   = !stall_ex && (branch_taken || dbcc_branch || ex_is_rts
                                      || ex_is_jmp
                                      || (ex_is_trap && exc_taken));
    // RTS goes to the address it popped; everything else is relative to the
    // instruction plus 2. !stall_ex above guarantees the pop has landed.
    assign redirect_pc = (ex_is_trap && exc_taken) ? exc_vec_addr
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
    assign ex_commit = ex_is_push               ? (ex_sp - 32'd4)
                     : ex_is_rte                ? (ex_ea
                                                   + ((ex_uop.imm[3:0] == 4'd3)
                                                      ? 32'd8 : 32'd6))
                     : ex_is_lea                ? ex_ea
                     : ex_is_scc                ? scc_result
                     : ex_is_dbcc               ? dbcc_result
                     : (ex_uop.sext_src) ? {{16{ex_src[15]}}, ex_src[15:0]}
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
            wb_reg     <= (ex_is_push || ex_is_rte) ? REG_A7 : ex_uop.dst_reg;
            wb_data    <= ex_commit;
            // DBcc writes Dn only when it actually decrements.
            wb_writes  <= (ex_valid && ex_uop.writes_reg && !ex_is_branch
                                    && !ex_uop.writes_mem
                                    && (!ex_is_dbcc || dbcc_dec)
                                    && !ex_is_rts)
                       || ex_is_push || ex_is_rte;
            wb_upd_ccr <= ex_valid && ex_uop.updates_ccr && !ex_is_branch;
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
        else if (wb_upd_ccr)   ccr_r <= wb_ccr;
    end

    // The system byte. Only RTE restores it; RTR is a user instruction and
    // leaves it alone. A trap forces supervisor state and clears tracing,
    // which is what makes the frame it just pushed the only way back.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                           sr_sys_r <= 8'h27;
        else if (rte_commit && (ex_uop.imm[3:0] == 4'd3))
                                              sr_sys_r <= rte_sr[15:8];
        else if (ex_is_trap && exc_taken && !stall_ex)
                                              sr_sys_r <= (sr_sys_r | 8'h20)
                                                          & 8'h3F;
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)          div_started <= 1'b0;
        else if (!stall_ex)  div_started <= 1'b0;   // instruction leaving EX
        else if (ex_is_div)  div_started <= 1'b1;
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
            exc_sp       <= 32'h0;
            exc_vec_addr <= 32'h0;
            exc_taken    <= 1'b0;
        end else if (!ex_is_trap) begin
            exc_state <= XS_IDLE;
            exc_taken <= 1'b0;
        end else begin
            case (exc_state)
                XS_IDLE: begin exc_state <= XS_PC; exc_sp <= ex_b - 32'd8; end
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
            rmw_wr_issued <= 1'b0;
            rmw_done      <= 1'b0;
        end else if (!stall_ex) begin
            rmw_wr_issued <= 1'b0;          // instruction leaving EX
            rmw_done      <= 1'b0;
        end else if (ex_rmw) begin
            if (mem_got && !rmw_wr_issued) rmw_wr_issued <= 1'b1;
            else if (rmw_wr_issued && mem_ack) rmw_done  <= 1'b1;
        end
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
    // MOVEM memory-to-register commits one register per acknowledged read,
    // straight from the sequencer rather than through WB.
    wire mvm_reg_wr = ex_is_movem && ex_uop.reads_mem && mvm_run
                   && mvm_bit && mem_ack;
    assign wb_wr_en   = (wb_valid && wb_writes) || ag_an_upd || exc_commit_sp
                      || mvm_reg_wr;
    assign wb_wr_sel  = mvm_reg_wr    ? mvm_reg
                      : exc_commit_sp ? 4'd15
                      : ag_an_upd     ? ag_uop.ea_reg : wb_reg;
    assign wb_wr_data = mvm_reg_wr    ? (ex_uop.xfer_long ? mem_rdata
                                         : {{16{mem_rdata[15]}}, mem_rdata[15:0]})
                      : exc_commit_sp ? exc_sp
                      : ag_an_upd     ? ag_an_val     : wb_data;
    assign ccr_out    = ccr_r;

endmodule

`default_nettype wire

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

    // Memory port -- registered request, registered ack (plan A4).
    output reg         mem_req,
    output reg  [31:0] mem_addr,
    output reg         mem_rw,        // 1 = read, 0 = write
    output reg  [1:0]  mem_siz,
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
    wire dec_ea_ok = (dec_uop.ea_mode == UEA_AN_IND)
                  || (dec_uop.ea_mode == UEA_AN_POST)
                  || (dec_uop.ea_mode == UEA_AN_PRE)
                  || (dec_uop.ea_mode == UEA_AN_D16)
                  || (dec_uop.ea_mode == UEA_ABS_W)
                  || (dec_uop.ea_mode == UEA_ABS_L);

    wire dec_executable = dec_uop.valid
                       && ((dec_uop.uclass == UC_ALU)   || (dec_uop.uclass == UC_MOVE)
                        || (dec_uop.uclass == UC_MOVEQ) || (dec_uop.uclass == UC_ADDQ)
                        || (dec_uop.uclass == UC_SHIFT))
                       && (dec_uop.dst_kind == US_DREG || dec_uop.dst_kind == US_AREG)
                       && !dec_uop.writes_mem
                       && (!dec_uop.reads_mem || dec_ea_ok);

    // ── Stage registers ─────────────────────────────────────────────────────
    uop_t ag_uop, ex_uop;
    reg   ag_valid, ex_valid;
    // Declared here because the stall below uses mem_got; assigned further
    // down beside the bus request.
    reg        mem_got;
    reg [31:0] mem_hold;
    // Which register the B port carried; needed by the interlock below.
    wire [3:0] ag_b_sel = ag_uop.reads_mem ? ag_uop.ea_reg : ag_uop.dst_reg;

    // EX stalls while its own memory operand is still outstanding. The whole
    // pipeline behind it holds, which is what makes the request safe to leave
    // asserted: it is dropped on ack rather than re-issued every cycle. That
    // re-issue shape is exactly the bug the sequential divider hit in rtl/.
    wire ex_wait_mem = ex_valid && ex_uop.reads_mem && !mem_got;

    // Address-base interlock. AG needs the base register a full stage before
    // EX does, so a producer still in EX has nothing to forward yet. Rather
    // than add a third forwarding level for a dependency that is rare (An is
    // normally set well ahead of its use), hold AG for a cycle.
    wire ag_base_busy = ag_valid && ag_uop.reads_mem
                     && ex_valid && ex_uop.writes_reg
                     && (ex_uop.dst_reg == ag_b_sel);

    // TWO stalls, and they must not be conflated. ex_wait_mem freezes the
    // whole pipeline, because EX itself cannot complete. ag_base_busy must
    // NOT freeze EX: the producer it is waiting for IS in EX, so holding EX
    // as well deadlocks -- the interlock can never clear. It holds ID/AG and
    // lets EX drain, inserting a bubble.
    wire stall_ex = ex_wait_mem;
    wire stall_ag = ag_base_busy;

    assign instr_ready = !stall_ex && !stall_ag;

    // ── Register file: address in ID, data in AG ────────────────────────────
    // With a memory source the B port carries the EA BASE register instead of
    // the ALU destination; the destination is forwarded in EX.
    wire dec_mem = dec_uop.reads_mem;
    wire [31:0] rf_a, rf_b;
    mh030p_regfile u_rf (
        .clk_4x   (clk_4x),
        .rst_n    (rst_n),
        // Hold the read while anything downstream is stalled; see the
        // regfile header.
        .rd_en    (!stall_ex && !stall_ag),
        .rd_a_sel (dec_mem ? dec_uop.dst_reg : dec_uop.src_reg),
        .rd_b_sel (dec_mem ? dec_uop.ea_reg   : dec_uop.dst_reg),
        .rd_a_data(rf_a),
        .rd_b_data(rf_b),
        .wr_en    (wb_wr_en),
        .wr_sel   (wb_wr_sel),
        .wr_data  (wb_wr_data)
    );

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ag_valid <= 1'b0;
            ag_uop   <= uop_clear();
        end else if (!stall_ex && !stall_ag) begin
            ag_valid <= instr_valid && dec_executable;
            ag_uop   <= dec_uop;
        end
    end

    // ── EX/WB boundary ──────────────────────────────────────────────────────
    reg         wb_valid;
    reg  [3:0]  wb_reg;
    reg  [31:0] wb_data;
    reg         wb_writes;
    reg  [7:0]  wb_ccr;
    reg         wb_upd_ccr;

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

    wire [31:0] ag_a = rf_a;
    wire [31:0] ag_b = fwd_g_wb ? wb_data : fwd_g_wbp ? wbp_data : rf_b;

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
    wire [31:0] ag_ea   = ea_base + ag_uop.ea_disp + ea_adj;

    // The An update is a SIDE EFFECT and must commit exactly once, when the
    // instruction actually leaves AG. Gating it on ag_valid alone makes it
    // level-sensitive, so every cycle EX spends stalled on memory applies the
    // increment again -- (A3)+ advanced by 12 instead of 4.
    wire ag_an_upd = ag_valid && ag_uop.reads_mem
                  && !stall_ex && !stall_ag
                  && ((ag_uop.ea_mode == UEA_AN_POST)
                   || (ag_uop.ea_mode == UEA_AN_PRE));
    wire [31:0] ag_an_val = (ag_uop.ea_mode == UEA_AN_POST) ? (ag_b + ea_step)
                                                            : (ag_b - ea_step);

    // ── AG -> EX, plus the registered bus request ───────────────────────────
    reg [31:0] ex_a, ex_b;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid <= 1'b0;
            ex_uop   <= uop_clear();
            ex_a     <= 32'h0;
            ex_b     <= 32'h0;
            mem_req  <= 1'b0;
            mem_addr <= 32'h0;
            mem_rw   <= 1'b1;
            mem_siz  <= UZ_LONG;
        end else if (!stall_ex) begin
            ex_valid <= ag_valid && !stall_ag;   // bubble while AG is held
            ex_uop   <= ag_uop;
            ex_a     <= ag_a;
            ex_b     <= ag_b;
            // Gated by !stall_ag as well as ex_valid: while AG is held for
            // the address-base interlock its EA is still computed from the
            // stale base, so issuing the request there sends a wrong address.
            // That is exactly what happened -- the first memory access went
            // out with addr=0 before A3 had been written.
            mem_req  <= ag_valid && ag_uop.reads_mem && !stall_ag;
            mem_addr <= ag_ea;
            mem_rw   <= 1'b1;
            mem_siz  <= ag_uop.siz;
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
    wire [3:0] ex_a_sel = ex_uop.reads_mem ? ex_uop.dst_reg : ex_uop.src_reg;

    wire fwd_a_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_a_sel);
    wire fwd_a_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_a_sel);
    wire fwd_b_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_uop.dst_reg);
    wire fwd_b_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_uop.dst_reg);

    wire [31:0] ex_a_f = fwd_a_wb ? wb_data : fwd_a_wbp ? wbp_data : ex_a;
    wire [31:0] ex_b_f = fwd_b_wb ? wb_data : fwd_b_wbp ? wbp_data : ex_b;

    wire [31:0] ex_src = ex_uop.reads_mem            ? mem_hold
                       : (ex_uop.src_kind == US_IMM) ? ex_uop.imm
                                                     : ex_a_f;
    wire [31:0] ex_dst = ex_uop.reads_mem ? ex_a_f : ex_b_f;

    // ── Functional units ────────────────────────────────────────────────────
    wire [31:0] alu_result, shf_result;
    wire alu_n, alu_z, alu_v, alu_c, alu_x;
    wire shf_n, shf_z, shf_v, shf_c, shf_x;
    reg  [7:0]  ccr_r;

    eu_alu u_alu (
        .src   (ex_src),
        .dst   (ex_dst),
        .op    (ex_uop.alu_op),
        .siz   (ex_uop.siz),
        .x_in  (ccr_r[4]),
        .z_in  (ccr_r[2]),
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
        .x_in   (ccr_r[4]),
        .result (shf_result),
        .n_out  (shf_n), .z_out(shf_z), .v_out(shf_v),
        .c_out  (shf_c), .x_out(shf_x)
    );

    // MOVE/MOVEQ pass the source through, sized.
    wire [31:0] mv_result = (ex_uop.siz == UZ_BYTE) ? {ex_dst[31:8],  ex_src[7:0]}
                          : (ex_uop.siz == UZ_WORD) ? {ex_dst[31:16], ex_src[15:0]}
                                                    : ex_src;
    wire mv_n = (ex_uop.siz == UZ_BYTE) ? ex_src[7]
              : (ex_uop.siz == UZ_WORD) ? ex_src[15] : ex_src[31];
    wire mv_z = (ex_uop.siz == UZ_BYTE) ? (ex_src[7:0]  == 8'h0)
              : (ex_uop.siz == UZ_WORD) ? (ex_src[15:0] == 16'h0)
                                        : (ex_src == 32'h0);

    wire use_shf = (ex_uop.unit == UU_SHF);
    wire use_mv  = (ex_uop.unit == UU_MOVE);

    wire [31:0] ex_result = use_shf ? shf_result : use_mv ? mv_result : alu_result;
    wire ex_n = use_shf ? shf_n : use_mv ? mv_n : alu_n;
    wire ex_z = use_shf ? shf_z : use_mv ? mv_z : alu_z;
    wire ex_v = use_shf ? shf_v : use_mv ? 1'b0 : alu_v;
    wire ex_c = use_shf ? shf_c : use_mv ? 1'b0 : alu_c;
    wire ex_x = use_shf ? shf_x : ccr_r[4];

    // MOVEA writes all 32 bits, sign-extending a word source.
    wire [31:0] ex_commit = (ex_uop.sext_src) ? {{16{ex_src[15]}}, ex_src[15:0]}
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
            wb_reg     <= ex_uop.dst_reg;
            wb_data    <= ex_commit;
            wb_writes  <= ex_valid && ex_uop.writes_reg;
            wb_upd_ccr <= ex_valid && ex_uop.updates_ccr;
            wb_ccr     <= {3'b000,
                           ex_uop.x_unchanged ? ccr_r[4] : ex_x,
                           ex_n, ex_z, ex_v, ex_c};
        end else begin
            wb_valid   <= 1'b0;      // bubble while EX waits on memory
            wb_writes  <= 1'b0;
            wb_upd_ccr <= 1'b0;
        end
    end

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)            ccr_r <= 8'h0;
        else if (wb_upd_ccr)   ccr_r <= wb_ccr;
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
    assign wb_wr_en   = (wb_valid && wb_writes) || ag_an_upd;
    assign wb_wr_sel  = ag_an_upd ? ag_uop.ea_reg : wb_reg;
    assign wb_wr_data = ag_an_upd ? ag_an_val     : wb_data;
    assign ccr_out    = ccr_r;

endmodule

`default_nettype wire

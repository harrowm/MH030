`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P integer core -- plan P2 scope: register-direct operands only, no
// memory operands and no exceptions. This exists to answer one question, the
// go/no-go the whole rewrite rests on: what Fmax does a genuinely staged core
// reach, against the 13.78 MHz the existing design measures?
//
// THREE STAGES, each a real register boundary:
//
//   ID   decode (combinational) -> registered uop; register-file addresses
//        issued this cycle
//   EX   register data arrives (the read was a clock boundary, not a cone);
//        forwarding mux; ALU/shifter; result registered
//   WB   commit to the register file and the CCR
//
// This is deliberately NOT the six-stage shape the plan sketches. AG and OF
// only do work once memory operands exist (P3), and adding empty stages now
// would measure nothing while making the first number harder to interpret.
// The stages that exist are the ones carrying real logic.
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
    output wire        instr_ack,

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
    wire dec_executable = dec_uop.valid
                       && ((dec_uop.uclass == UC_ALU)   || (dec_uop.uclass == UC_MOVE)
                        || (dec_uop.uclass == UC_MOVEQ) || (dec_uop.uclass == UC_ADDQ)
                        || (dec_uop.uclass == UC_SHIFT))
                       && (dec_uop.src_kind != US_MEM)
                       && (dec_uop.dst_kind == US_DREG || dec_uop.dst_kind == US_AREG)
                       && !dec_uop.reads_mem && !dec_uop.writes_mem;

    assign instr_ack = instr_valid && dec_executable;

    // ── ID/EX boundary ──────────────────────────────────────────────────────
    uop_t ex_uop;
    reg   ex_valid;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid <= 1'b0;
            ex_uop   <= uop_clear();
        end else begin
            ex_valid <= instr_valid && dec_executable;
            ex_uop   <= dec_uop;
        end
    end

    // ── Register file: address in ID, data in EX ────────────────────────────
    wire [31:0] rf_a, rf_b;
    mh030p_regfile u_rf (
        .clk_4x   (clk_4x),
        .rst_n    (rst_n),
        .rd_a_sel (dec_uop.src_reg),
        .rd_b_sel (dec_uop.dst_reg),
        .rd_a_data(rf_a),
        .rd_b_data(rf_b),
        .wr_en    (wb_wr_en),
        .wr_sel   (wb_wr_sel),
        .wr_data  (wb_wr_data)
    );

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
    wire fwd_a_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_uop.src_reg);
    wire fwd_a_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_uop.src_reg);
    wire fwd_b_wb  = wb_valid  && wb_writes  && (wb_reg  == ex_uop.dst_reg);
    wire fwd_b_wbp = wbp_valid && wbp_writes && (wbp_reg == ex_uop.dst_reg);

    wire [31:0] fwd_a = fwd_a_wb  ? wb_data
                      : fwd_a_wbp ? wbp_data
                                  : rf_a;
    wire [31:0] fwd_b = fwd_b_wb  ? wb_data
                      : fwd_b_wbp ? wbp_data
                                  : rf_b;

    wire [31:0] ex_src = (ex_uop.src_kind == US_IMM) ? ex_uop.imm : fwd_a;
    wire [31:0] ex_dst = fwd_b;

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
        end else begin
            wb_valid   <= ex_valid;
            wb_reg     <= ex_uop.dst_reg;
            wb_data    <= ex_commit;
            wb_writes  <= ex_valid && ex_uop.writes_reg;
            wb_upd_ccr <= ex_valid && ex_uop.updates_ccr;
            wb_ccr     <= {3'b000,
                           ex_uop.x_unchanged ? ccr_r[4] : ex_x,
                           ex_n, ex_z, ex_v, ex_c};
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

    assign wb_wr_en   = wb_valid && wb_writes;
    assign wb_wr_sel  = wb_reg;
    assign wb_wr_data = wb_data;
    assign ccr_out    = ccr_r;

endmodule

`default_nettype wire

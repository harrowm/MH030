`default_nettype none
`include "mh030p_uop.svh"
// Measures ONLY the redirect/redirect_pc cone (mh030p_core.sv lines
// ~2305-2372): registers in, registers out, nothing else.
//
// WHY IT EXISTS. See tb/stall_ex_probe.sv's own header for the full
// context. `redirect`/`redirect_pc` are plain `output wire`s (purely
// combinational, confirmed by direct RTL trace -- no always_ff ever
// touches them), and mh030p_ifu.sv samples redirect_pc directly into
// fetch_pc/head_pc the SAME cycle redirect asserts, with no buffering --
// so this cone's own depth matters for real, unlike the flag mux (which
// only reaches a register, wb_ccr).
//
// Every operand/state input here (mem_rdata, exc_vec_addr, mem_hold,
// ex_ea, ex_pc, cc_n/z/v/c, exc_pend, exc_taken, stall_ex) is a REGISTERED
// STAND-IN for the real signal -- most genuinely are registers already
// (ex_pc/ex_ea/mem_hold), one (stall_ex) was measured separately by
// tb/stall_ex_probe.sv, and cc_n/z/v/c stand in for ccr_live[3:0]
// (itself wb_ccr/ccr_r, both registers) directly rather than re-deriving
// that mux here.
//
// Copied VERBATIM from mh030p_core.sv's own cond_true case (lines
// ~2277-2300), dbcc_next/dbcc_dec/dbcc_branch/branch_taken/redirect/
// redirect_pc (lines ~2348-2372) -- see that file for the real comments.
module redirect_probe (
    input  wire        clk_4x,
    input  wire        rst_n,
    input  wire        ex_valid_i,
    input  wire [5:0]  uclass_i,
    input  wire [3:0]  cond_i,
    input  wire        cc_n_i, cc_z_i, cc_v_i, cc_c_i,
    input  wire [15:0] ex_dst_lo_i,
    input  wire        rst_redirect_i,
    input  wire [31:0] mem_rdata_i,
    input  wire        exc_pend_i,
    input  wire        exc_taken_i,
    input  wire [31:0] exc_vec_addr_i,
    input  wire [31:0] mem_hold_i,
    input  wire [31:0] ex_ea_i,
    input  wire [31:0] ex_pc_i,
    input  wire [31:0] imm_i,
    input  wire        stall_ex_i,
    output reg         redirect_o,
    output reg  [31:0] redirect_pc_o
);
    reg        ex_valid, rst_redirect, exc_pend, exc_taken, stall_ex;
    reg [5:0]  uclass;
    reg [3:0]  cond;
    reg        cc_n, cc_z, cc_v, cc_c;
    reg [15:0] ex_dst_lo;
    reg [31:0] mem_rdata, exc_vec_addr, mem_hold, ex_ea, ex_pc, imm;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            ex_valid<=1'b0; uclass<=6'h0; cond<=4'h0;
            cc_n<=1'b0; cc_z<=1'b0; cc_v<=1'b0; cc_c<=1'b0;
            ex_dst_lo<=16'h0; rst_redirect<=1'b0; mem_rdata<=32'h0;
            exc_pend<=1'b0; exc_taken<=1'b0; exc_vec_addr<=32'h0;
            mem_hold<=32'h0; ex_ea<=32'h0; ex_pc<=32'h0; imm<=32'h0;
            stall_ex<=1'b0;
        end else begin
            ex_valid<=ex_valid_i; uclass<=uclass_i; cond<=cond_i;
            cc_n<=cc_n_i; cc_z<=cc_z_i; cc_v<=cc_v_i; cc_c<=cc_c_i;
            ex_dst_lo<=ex_dst_lo_i; rst_redirect<=rst_redirect_i;
            mem_rdata<=mem_rdata_i; exc_pend<=exc_pend_i;
            exc_taken<=exc_taken_i; exc_vec_addr<=exc_vec_addr_i;
            mem_hold<=mem_hold_i; ex_ea<=ex_ea_i; ex_pc<=ex_pc_i;
            imm<=imm_i; stall_ex<=stall_ex_i;
        end

    reg cond_true;
    always_comb begin
        case (cond)
            4'h0: cond_true = 1'b1;
            4'h1: cond_true = 1'b0;
            4'h2: cond_true = !cc_c && !cc_z;
            4'h3: cond_true =  cc_c ||  cc_z;
            4'h4: cond_true = !cc_c;
            4'h5: cond_true =  cc_c;
            4'h6: cond_true = !cc_z;
            4'h7: cond_true =  cc_z;
            4'h8: cond_true = !cc_v;
            4'h9: cond_true =  cc_v;
            4'hA: cond_true = !cc_n;
            4'hB: cond_true =  cc_n;
            4'hC: cond_true = (cc_n == cc_v);
            4'hD: cond_true = (cc_n != cc_v);
            4'hE: cond_true = (cc_n == cc_v) && !cc_z;
            default: cond_true = (cc_n != cc_v) || cc_z;
        endcase
    end

    wire ex_is_trap  = exc_pend;
    wire ex_is_ret   = ex_valid && (uclass == UC_RETURN);
    wire ex_is_rts   = ex_is_ret;
    wire ex_is_jmp   = ex_valid && (uclass == UC_JMP);
    wire ex_is_branch= ex_valid && (uclass == UC_BRANCH);
    wire ex_is_dbcc  = ex_valid && (uclass == UC_DBCC);

    wire [15:0] dbcc_next   = ex_dst_lo - 16'd1;
    wire        dbcc_dec    = ex_is_dbcc && !cond_true;
    wire        dbcc_branch = dbcc_dec && (dbcc_next != 16'hFFFF);

    wire branch_taken = ex_is_branch && ((cond == 4'h1) || cond_true);

    wire redirect_comb = rst_redirect
                      || !stall_ex && (branch_taken || dbcc_branch
                                       || ex_is_rts || ex_is_jmp
                                       || (ex_is_trap && exc_taken));
    wire [31:0] redirect_pc_comb = rst_redirect ? mem_rdata
                       : (ex_is_trap && exc_taken) ? exc_vec_addr
                       : ex_is_rts                 ? mem_hold
                       : ex_is_jmp                 ? ex_ea
                                                    : (ex_pc + 32'd2 + imm);

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin redirect_o<=1'b0; redirect_pc_o<=32'h0; end
        else begin redirect_o<=redirect_comb; redirect_pc_o<=redirect_pc_comb; end
endmodule
`default_nettype wire

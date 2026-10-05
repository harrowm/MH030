`default_nettype none
`include "mh030p_uop.svh"
// Measures ONLY stall_ex's own combinational cone: registers in, registers
// out, nothing else, so Yosys prunes everything else away.
//
// WHY IT EXISTS. A -noflatten trace (2 seeds, consistent) after the
// ea_idx_reg fix found the worst path entirely inside u_core, with hop
// names mentioning bit_z/bf_c/shf_busy/redirect_pc/mem_wdata. A direct RTL
// trace (mh030p_core.sv) found bit_z/bf_c do NOT reach cond_true/redirect
// in the same cycle (ccr_live is registered, one cycle removed) -- the
// hop names are a synthesis-level naming artifact, not real RTL dataflow
// (this project's own feedback_flattened_attribution_needs_noflatten_
// crosscheck lesson, extended here to signal names WITHIN one module, not
// just module-level attribution). The one REAL, RTL-confirmed same-cycle
// route from a "slow unit" into both `redirect` and `mem_wdata`'s own
// dispatch is shf_busy -> ex_wait_shf -> ex_other_stall -> stall_ex, and
// stall_ex is the top-level gate of both. This probe measures stall_ex's
// own cone directly -- the same "isolate before design" discipline that
// found ext_words' and ea_idx_reg's real costs -- rather than guessing
// from the hop names a second time.
//
// Every input here is a REGISTERED STAND-IN for a real mh030p_core.sv
// signal: most of them (mem_got, div_started, shf_started, shf_busy,
// mul_started, mul_busy, rte_done, cmp2_done, mvm_done, mvp_done,
// trap_decided, exc_pend, exc_taken, ea_done, bcdm_ph, rmw_done, md_div_busy,
// mul_busy, int_take, in_reset_seq) ARE genuinely registers (or, for a
// couple like md_div_busy/exc_taken/int_take, wires fed by their own
// sequential units elsewhere) in the real design, so treating them as
// registered probe inputs is faithful, not a simplification of what they
// are -- only their OWN internal derivation is pruned, which is correct:
// this probe exists to measure stall_ex's OWN OR-tree depth given already-
// settled inputs, not those units' own internal timing (each has/would
// have its own separate probe if it turned out to matter).
//
// The combinational logic below is copied VERBATIM from mh030p_core.sv's
// own ex_wait_mem/ex_wait_div/ex_wait_shf/ex_wait_mul/ex_wait_rte/
// ex_wait_cmp2/ex_needs_ea/ex_wait_ea/ex_other_stall/ex_may_trap/stall_ex
// (lines ~419-1050) -- see that file for the real comments explaining each
// term's own existence.
module stall_ex_probe (
    input  wire        clk_4x,
    input  wire        rst_n,
    input  wire        ex_valid_i,
    input  wire        reads_mem_i,
    input  wire        writes_mem_i,
    input  wire [5:0]  uclass_i,
    input  wire [2:0]  unit_i,
    input  wire [3:0]  subop_i,
    input  wire        ex_m2m_2rd_i,
    input  wire [1:0]  bcdm_ph_i,
    input  wire        rmw_done_i,
    input  wire        mem_got_i,
    input  wire        div_started_i,
    input  wire        md_div_busy_i,
    input  wire        shf_started_i,
    input  wire        shf_busy_i,
    input  wire        mul_started_i,
    input  wire        mul_busy_i,
    input  wire        rte_done_i,
    input  wire        cmp2_done_i,
    input  wire        ea_done_i,
    input  wire        mvm_done_i,
    input  wire        mvp_done_i,
    input  wire        trap_decided_i,
    input  wire        exc_pend_i,
    input  wire        exc_taken_i,
    input  wire        int_take_i,
    input  wire        in_reset_seq_i,
    output reg         stall_ex_o
);
    reg        ex_valid, reads_mem, writes_mem, ex_m2m_2rd, rmw_done,
               mem_got, div_started, md_div_busy, shf_started, shf_busy,
               mul_started, mul_busy, rte_done, cmp2_done, ea_done,
               mvm_done, mvp_done, trap_decided, exc_pend, exc_taken,
               int_take, in_reset_seq;
    reg [5:0]  uclass;
    reg [2:0]  unit;
    reg [3:0]  subop;
    reg [1:0]  bcdm_ph;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            ex_valid<=1'b0; reads_mem<=1'b0; writes_mem<=1'b0;
            uclass<=6'h0; unit<=3'h0; subop<=4'h0;
            ex_m2m_2rd<=1'b0; bcdm_ph<=2'h0; rmw_done<=1'b0; mem_got<=1'b0;
            div_started<=1'b0; md_div_busy<=1'b0; shf_started<=1'b0;
            shf_busy<=1'b0; mul_started<=1'b0; mul_busy<=1'b0;
            rte_done<=1'b0; cmp2_done<=1'b0; ea_done<=1'b0;
            mvm_done<=1'b0; mvp_done<=1'b0; trap_decided<=1'b0;
            exc_pend<=1'b0; exc_taken<=1'b0; int_take<=1'b0;
            in_reset_seq<=1'b0;
        end else begin
            ex_valid<=ex_valid_i; reads_mem<=reads_mem_i;
            writes_mem<=writes_mem_i; uclass<=uclass_i; unit<=unit_i;
            subop<=subop_i; ex_m2m_2rd<=ex_m2m_2rd_i; bcdm_ph<=bcdm_ph_i;
            rmw_done<=rmw_done_i; mem_got<=mem_got_i;
            div_started<=div_started_i; md_div_busy<=md_div_busy_i;
            shf_started<=shf_started_i; shf_busy<=shf_busy_i;
            mul_started<=mul_started_i; mul_busy<=mul_busy_i;
            rte_done<=rte_done_i; cmp2_done<=cmp2_done_i; ea_done<=ea_done_i;
            mvm_done<=mvm_done_i; mvp_done<=mvp_done_i;
            trap_decided<=trap_decided_i; exc_pend<=exc_pend_i;
            exc_taken<=exc_taken_i; int_take<=int_take_i;
            in_reset_seq<=in_reset_seq_i;
        end

    wire ex_rmw        = ex_valid && reads_mem && writes_mem;
    wire ex_wait_mem   = ex_valid && (reads_mem || writes_mem)
                      && (uclass != UC_MOVEM)
                      && (ex_m2m_2rd ? (bcdm_ph != 2'd3)
                          : ex_rmw   ? !rmw_done : !mem_got);

    wire ex_is_div     = ex_valid && (unit == UU_DIV);
    wire ex_wait_div   = ex_is_div && (!div_started || md_div_busy);

    wire ex_is_shf     = ex_valid && (unit == UU_SHF);
    wire ex_wait_shf   = ex_is_shf && (!shf_started || shf_busy);

    wire ex_is_mul     = ex_valid && (unit == UU_MUL);
    wire ex_wait_mul   = ex_is_mul && (!mul_started || mul_busy);

    wire ex_is_ret     = (uclass == UC_RETURN);
    wire ex_is_rte     = ex_is_ret && (subop != 4'd5);
    wire ex_wait_rte   = ex_is_rte && !rte_done;

    wire ex_trap_cls   = ex_valid && (uclass == UC_TRAP);
    wire ex_is_cmp2    = ex_trap_cls && (subop == 4'd3);
    wire ex_wait_cmp2  = ex_is_cmp2 && !cmp2_done;

    wire ex_ea_class_e   = (uclass == UC_LEA) || (uclass == UC_JMP);
    wire ex_trap_no_ea_e = (uclass == UC_TRAP)
                        && (subop != 4'd2) && (subop != 4'd3);
    wire ex_needs_ea   = ex_valid
                      && (reads_mem || writes_mem || ex_ea_class_e)
                      && !ex_trap_no_ea_e;
    wire ex_wait_ea    = ex_needs_ea && !ea_done;

    wire ex_is_movem   = (uclass == UC_MOVEM);
    wire ex_is_movep   = (uclass == UC_MOVEP);

    wire ex_other_stall = ex_wait_mem || ex_wait_div || ex_wait_mul
                       || ex_wait_shf || ex_wait_rte || ex_wait_cmp2
                       || ex_wait_ea
                       || (ex_is_movem && !mvm_done)
                       || (ex_is_movep && !mvp_done);

    wire ex_may_trap   = ex_trap_cls || ex_is_div || int_take;

    wire stall_ex_comb = in_reset_seq
                      || ex_other_stall
                      || (ex_may_trap && !trap_decided)
                      || (exc_pend && !exc_taken);

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) stall_ex_o <= 1'b0; else stall_ex_o <= stall_ex_comb;
endmodule
`default_nettype wire

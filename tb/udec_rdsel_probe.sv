`default_nettype none
`include "mh030p_uop.svh"
// Measures the cone from the offered opcode through mh030p_decode (u_dec)
// to the register file's own rd_a_sel address mux -- registers in,
// registers out, nothing else, so Yosys prunes every other decoder output.
//
// WHY IT EXISTS. After the Stage 3 CAS latch fix (docs/
// mh030p_architecture.md section 8) took u_alu off the critical path, a
// -noflatten trace (2 seeds, consistent) found the new worst path is
// u_ifu.instr -> u_core.u_dec (~22 ns, ~58% of ~38 ns total) ->
// u_core.u_rf, terminating at rd_a_data's own D input -- i.e. through
// u_core's own rd_a_sel mux (mh030p_core.sv, the `.rd_a_sel(...)` port
// connection on u_rf) into the register file's own array read. This probe
// isolates the FIRST half of that chain (decode through the rd_a_sel mux
// itself, not the regfile's own array read/write-bypass logic, which is a
// separate, already-small contributor per the module-walk attribution).
//
// mh030p_core.sv's own dec_is_cas/dec_is_movep/dec_is_bf/dec_push_idx/
// dec_mem_operand/dec_mem/dec_is_link wires are reproduced here verbatim
// (not re-derived or simplified) so this probe measures the REAL mux, not
// an approximation of it.
//
// PROFILED (drive rd_a_sel_o from progressively smaller sub-expressions,
// same technique tb/extw_probe.sv's own investigation used):
//   u.uclass[3:0] alone        149.37 MHz  (~6.7 ns -- matches the
//                                           ext_words investigation's own
//                                           "uclass is cheap" finding)
//   u.dst_reg alone            103.86 MHz  (~9.6 ns)
//   u.src_reg alone            126.57 MHz  (~7.9 ns)
//   u.ea_idx_reg alone          53.44 MHz  (~18.7 ns -- THE DOMINANT COST,
//                                           nearly as expensive as the
//                                           WHOLE mux below)
//   full rd_a_sel_comb mux      57.71 MHz  (~17.3 ns)
// ea_idx_reg traces to `sxw = xword(ea_slot_is_dst ? ew_dst_at : ew_lead,
// ew_tot)` (mh030p_decode.sv) -- the SAME shape of cascading, per-family
// extension-word-position arithmetic that made ext_words itself expensive
// before Stage 1's shallow rewrite. Not yet fixed: an analogous "shallow
// ea_idx_reg" shortcut, computed straight from raw opcode/extension-word
// bits rather than through the cascading ew_lead/ew_dst_at/ew_tot
// classification, would be a comparable-scope undertaking to that
// rewrite, not a quick patch -- flagged for explicit scoping, not
// attempted here. See docs/mh030p_architecture.md section 8.
module udec_rdsel_probe (
    input  wire        clk_4x,
    input  wire        rst_n,
    input  wire [15:0] instr_i,
    input  wire [31:0] extraw_i,
    input  wire [15:0] q3_i,
    input  wire [15:0] q4_i,
    output reg  [3:0]  rd_a_sel_o
);
    reg [15:0] instr_r, q3_r, q4_r;
    reg [31:0] extraw_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            instr_r<=16'h0; extraw_r<=32'h0; q3_r<=16'h0; q4_r<=16'h0;
        end else begin
            instr_r<=instr_i; extraw_r<=extraw_i; q3_r<=q3_i; q4_r<=q4_i;
        end

    uop_t u;
    mh030p_decode u_dec (.instr(instr_r), .ext_raw(extraw_r),
                         .q3(q3_r), .q4(q4_r), .uop(u));

    // Verbatim from mh030p_core.sv -- see that file for the real comments
    // explaining each one.
    wire dec_is_ea_class = (u.uclass == UC_LEA) || (u.uclass == UC_JMP);
    wire dec_is_push     = dec_is_ea_class && u.writes_mem;
    wire dec_mem_operand = u.reads_mem && !u.writes_mem && (u.dst_kind == US_MEM);
    wire dec_is_movep    = (u.uclass == UC_MOVEP);
    wire dec_is_cas      = (u.uclass == UC_ATOMIC) && (u.subop == 4'd1);
    wire dec_is_bf       = (u.uclass == UC_BITFIELD);
    wire dec_push_idx    = dec_is_push && ((u.ea_mode == UEA_AN_IDX)
                                         || (u.ea_mode == UEA_PC_IDX));

    wire [3:0] rd_a_sel_comb =
        dec_is_cas ? u.dst_reg
      : dec_is_movep ? u.imm[3:0]
      : dec_is_bf ? u.imm[15:12]
      : dec_push_idx ? u.ea_idx_reg
      : (u.dst_ea_mode != UEA_NONE) ? u.dst_ea_reg
      : dec_mem_operand ? u.src_reg
      : (u.reads_mem && !u.writes_mem) ? u.dst_reg : u.src_reg;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) rd_a_sel_o <= 4'h0; else rd_a_sel_o <= rd_a_sel_comb;
endmodule
`default_nettype wire

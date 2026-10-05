`default_nettype none
`include "mh030p_uop.svh"
// Measures ONLY the ex_n/ex_z/ex_v/ex_c/ex_x flag-select mux's own
// combinational cone (mh030p_core.sv lines ~2217-2269): registers in,
// registers out, nothing else.
//
// WHY IT EXISTS. See tb/stall_ex_probe.sv's own header for the full
// context (the -noflatten hop-naming investigation that preceded this).
// This mux pulls a result from EVERY execution unit (div, cmp2, bf, chk,
// tas, bit, bcd, md, shf, mv/ext/swap, alu) unconditionally every cycle,
// selected by ex_uop's own classification fields, and its sole destination
// is wb_ccr's own D-input (a register) -- not cond_true/redirect this same
// cycle (confirmed by direct RTL trace: ccr_live reads wb_ccr, which is
// registered one cycle behind). Measuring it anyway because if IT is
// expensive, that still matters for whatever's downstream of wb_ccr next
// cycle, and because `bit_z`/`bf_c` (named in the original -noflatten hop
// trace) are two of this mux's own leaf inputs.
//
// Every per-unit flag input here (bf_n/bf_z/bf_v/bf_c, bit_z, bcd_*, md_*,
// shf_*, alu_*, mv_like_*, chk_*_r, cmp2_*_r, tas_orig, div_ovf) is a
// REGISTERED STAND-IN for that unit's own real output -- this probe
// measures the MUX's own depth given already-settled unit outputs, not
// each unit's own internal computation (each has, or would have, its own
// separate probe if it mattered).
//
// Copied VERBATIM from mh030p_core.sv's own ex_n/ex_z/ex_v/ex_c/ex_x and
// alu_touches_x (lines ~2217-2269) and the use_* classification wires
// (lines ~2157-2169) -- see that file for the real comments.
module ex_flags_probe (
    input  wire        clk_4x,
    input  wire        rst_n,
    input  wire [2:0]  unit_i,
    input  wire [5:0]  uclass_i,
    input  wire [3:0]  subop_i,
    input  wire [3:0]  alu_op_i,
    input  wire        div_ovf_i,
    input  wire        ex_is_cmp2_i,
    input  wire        ex_is_bf_i,
    input  wire        ex_is_chk_i,
    input  wire        ex_is_tas_i,
    input  wire [7:0]  ccr_live_i,
    input  wire        bf_n_i, bf_z_i, bf_v_i, bf_c_i,
    input  wire        chk_n_r_i, chk_z_r_i,
    input  wire [7:0]  tas_orig_i,
    input  wire        bit_z_i,
    input  wire        bcd_n_i, bcd_z_i, bcd_v_i, bcd_c_i, bcd_x_i,
    input  wire        md_n_i, md_z_i, md_v_i, md_c_i,
    input  wire        shf_n_i, shf_z_i, shf_v_i, shf_c_i, shf_x_i,
    input  wire        mv_like_n_i, mv_like_z_i,
    input  wire        alu_n_i, alu_z_i, alu_v_i, alu_c_i, alu_x_i,
    input  wire        cmp2_z_r_i, cmp2_c_r_i,
    output reg  [4:0]  ex_flags_o   // {ex_x, ex_n, ex_z, ex_v, ex_c}
);
    reg [2:0] unit; reg [5:0] uclass; reg [3:0] subop, alu_op;
    reg div_ovf, ex_is_cmp2, ex_is_bf, ex_is_chk, ex_is_tas;
    reg [7:0] ccr_live, tas_orig;
    reg bf_n, bf_z, bf_v, bf_c, chk_n_r, chk_z_r, bit_z;
    reg bcd_n, bcd_z, bcd_v, bcd_c, bcd_x;
    reg md_n, md_z, md_v, md_c;
    reg shf_n, shf_z, shf_v, shf_c, shf_x;
    reg mv_like_n, mv_like_z;
    reg alu_n, alu_z, alu_v, alu_c, alu_x;
    reg cmp2_z_r, cmp2_c_r;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            unit<=3'h0; uclass<=6'h0; subop<=4'h0; alu_op<=4'h0;
            div_ovf<=1'b0; ex_is_cmp2<=1'b0; ex_is_bf<=1'b0;
            ex_is_chk<=1'b0; ex_is_tas<=1'b0;
            ccr_live<=8'h0; tas_orig<=8'h0;
            bf_n<=1'b0; bf_z<=1'b0; bf_v<=1'b0; bf_c<=1'b0;
            chk_n_r<=1'b0; chk_z_r<=1'b0; bit_z<=1'b0;
            bcd_n<=1'b0; bcd_z<=1'b0; bcd_v<=1'b0; bcd_c<=1'b0; bcd_x<=1'b0;
            md_n<=1'b0; md_z<=1'b0; md_v<=1'b0; md_c<=1'b0;
            shf_n<=1'b0; shf_z<=1'b0; shf_v<=1'b0; shf_c<=1'b0; shf_x<=1'b0;
            mv_like_n<=1'b0; mv_like_z<=1'b0;
            alu_n<=1'b0; alu_z<=1'b0; alu_v<=1'b0; alu_c<=1'b0; alu_x<=1'b0;
            cmp2_z_r<=1'b0; cmp2_c_r<=1'b0;
        end else begin
            unit<=unit_i; uclass<=uclass_i; subop<=subop_i; alu_op<=alu_op_i;
            div_ovf<=div_ovf_i; ex_is_cmp2<=ex_is_cmp2_i;
            ex_is_bf<=ex_is_bf_i; ex_is_chk<=ex_is_chk_i;
            ex_is_tas<=ex_is_tas_i;
            ccr_live<=ccr_live_i; tas_orig<=tas_orig_i;
            bf_n<=bf_n_i; bf_z<=bf_z_i; bf_v<=bf_v_i; bf_c<=bf_c_i;
            chk_n_r<=chk_n_r_i; chk_z_r<=chk_z_r_i; bit_z<=bit_z_i;
            bcd_n<=bcd_n_i; bcd_z<=bcd_z_i; bcd_v<=bcd_v_i; bcd_c<=bcd_c_i;
            bcd_x<=bcd_x_i;
            md_n<=md_n_i; md_z<=md_z_i; md_v<=md_v_i; md_c<=md_c_i;
            shf_n<=shf_n_i; shf_z<=shf_z_i; shf_v<=shf_v_i; shf_c<=shf_c_i;
            shf_x<=shf_x_i;
            mv_like_n<=mv_like_n_i; mv_like_z<=mv_like_z_i;
            alu_n<=alu_n_i; alu_z<=alu_z_i; alu_v<=alu_v_i; alu_c<=alu_c_i;
            alu_x<=alu_x_i;
            cmp2_z_r<=cmp2_z_r_i; cmp2_c_r<=cmp2_c_r_i;
        end

    wire use_bit  = (unit == UU_BIT);
    wire use_bcd  = (unit == UU_BCD);
    wire use_ext  = (uclass == UC_EXT);
    wire use_swap = (uclass == UC_SWAP);
    wire use_shf  = (unit == UU_SHF);
    wire use_clr  = (uclass == UC_ALU) && (alu_op == UA_CLR);
    wire use_mv   = (unit == UU_MOVE) && !use_clr;
    wire use_md   = (unit == UU_MUL) || (unit == UU_DIV);

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
    wire ex_c = div_ovf ? 1'b0 :
                ex_is_cmp2 ? cmp2_c_r :
                ex_is_bf ? bf_c :
                (ex_is_chk || ex_is_tas) ? 1'b0 :
                use_bit ? ccr_live[0] : use_bcd ? bcd_c
              : use_md  ? md_c : use_shf ? shf_c
              : (use_mv || use_ext || use_swap) ? 1'b0 : alu_c;

    wire alu_touches_x = (alu_op == UA_ADD)  || (alu_op == UA_ADDX)
                      || (alu_op == UA_SUB)  || (alu_op == UA_SUBX)
                      || (alu_op == UA_NEG)  || (alu_op == UA_NEGX);

    wire ex_x = (ex_is_bf || ex_is_chk || ex_is_tas || ex_is_cmp2) ? ccr_live[4]
              : use_bit ? ccr_live[4] : use_bcd ? bcd_x
              : use_md  ? ccr_live[4] : use_shf ? shf_x
              : (use_mv || use_ext || use_swap) ? ccr_live[4]
              : alu_touches_x ? alu_x : ccr_live[4];

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) ex_flags_o <= 5'h0;
        else ex_flags_o <= {ex_x, ex_n, ex_z, ex_v, ex_c};
endmodule
`default_nettype wire

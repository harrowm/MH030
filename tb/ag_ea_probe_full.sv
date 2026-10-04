`default_nettype none
`include "mh030p_uop.svh"
// Phase 0 of ~/.claude/plans/golden-puzzling-music.md ("Split the AG
// effective-address adder into its own pipeline cycle"): measures ONLY the
// AG-stage EA-computation-and-dispatch cone -- the forwarding muxes for
// ag_a/ag_b/ag_c, the EA adder (ea_base/ag_ea), and the mem_addr dispatch
// mux -- in isolation, mirroring tb/extw_probe.sv's own register-in/
// register-out shape so synthesis prunes everything unrelated.
//
// This is variant (a), "full existing cone": today's REAL logic,
// reproduced verbatim from rtlp/mh030p_core.sv (not refactored, not
// simplified -- a probe that doesn't match production logic measures the
// wrong thing). Compare against ag_ea_probe_pcrel.sv (b) and
// ag_ea_probe_fwd.sv (c): if (b) alone is already near (a)'s ceiling, the
// planned AG/EX split does not address the dominant case and the plan's
// own "stop and report back" condition applies.
module ag_ea_probe_full (
    input  wire        clk_4x,
    input  wire        rst_n,

    input  wire [31:0] rf_a_i, rf_b_i, rf_c_i,
    input  wire        wb_valid_i, wb_writes_i,
    input  wire [3:0]  wb_reg_i,
    input  wire [31:0] wb_data_i,
    input  wire        wbp_valid_i, wbp_writes_i,
    input  wire [3:0]  wbp_reg_i,
    input  wire [31:0] wbp_data_i,
    input  wire        wb2_en_i,
    input  wire [3:0]  wb2_sel_i,
    input  wire [31:0] wb2_data_i,
    input  wire        wbp2_en_i,
    input  wire [3:0]  wbp2_sel_i,
    input  wire [31:0] wbp2_data_i,
    input  wire [31:0] ag_pc2_i,
    input  uop_t        ag_uop_i,

    output reg  [31:0] mem_addr_o
);

    reg  [31:0] rf_a_r, rf_b_r, rf_c_r;
    reg         wb_valid_r, wb_writes_r;
    reg  [3:0]  wb_reg_r;
    reg  [31:0] wb_data_r;
    reg         wbp_valid_r, wbp_writes_r;
    reg  [3:0]  wbp_reg_r;
    reg  [31:0] wbp_data_r;
    reg         wb2_en_r;
    reg  [3:0]  wb2_sel_r;
    reg  [31:0] wb2_data_r;
    reg         wbp2_en_r;
    reg  [3:0]  wbp2_sel_r;
    reg  [31:0] wbp2_data_r;
    reg  [31:0] ag_pc2_r;
    uop_t       ag_uop_r;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            rf_a_r <= 32'h0; rf_b_r <= 32'h0; rf_c_r <= 32'h0;
            wb_valid_r <= 1'b0; wb_writes_r <= 1'b0;
            wb_reg_r <= 4'h0; wb_data_r <= 32'h0;
            wbp_valid_r <= 1'b0; wbp_writes_r <= 1'b0;
            wbp_reg_r <= 4'h0; wbp_data_r <= 32'h0;
            wb2_en_r <= 1'b0; wb2_sel_r <= 4'h0; wb2_data_r <= 32'h0;
            wbp2_en_r <= 1'b0; wbp2_sel_r <= 4'h0; wbp2_data_r <= 32'h0;
            ag_pc2_r <= 32'h0;
            ag_uop_r <= uop_clear();
        end else begin
            rf_a_r <= rf_a_i; rf_b_r <= rf_b_i; rf_c_r <= rf_c_i;
            wb_valid_r <= wb_valid_i; wb_writes_r <= wb_writes_i;
            wb_reg_r <= wb_reg_i; wb_data_r <= wb_data_i;
            wbp_valid_r <= wbp_valid_i; wbp_writes_r <= wbp_writes_i;
            wbp_reg_r <= wbp_reg_i; wbp_data_r <= wbp_data_i;
            wb2_en_r <= wb2_en_i; wb2_sel_r <= wb2_sel_i; wb2_data_r <= wb2_data_i;
            wbp2_en_r <= wbp2_en_i; wbp2_sel_r <= wbp2_sel_i; wbp2_data_r <= wbp2_data_i;
            ag_pc2_r <= ag_pc2_i;
            ag_uop_r <= ag_uop_i;
        end

    // ── Verbatim from rtlp/mh030p_core.sv (the AG stage) ────────────────────
    wire ag_trap_no_ea = (ag_uop_r.uclass == UC_TRAP)
                      && (ag_uop_r.subop != 4'd2) && (ag_uop_r.subop != 4'd3);
    wire ag_is_movem = (ag_uop_r.uclass == UC_MOVEM);
    wire ag_ea_class = (ag_uop_r.uclass == UC_LEA) || (ag_uop_r.uclass == UC_JMP);
    wire ag_mem      = ag_uop_r.reads_mem || ag_uop_r.writes_mem || ag_ea_class;
    wire ag_is_push  = ag_ea_class && ag_uop_r.writes_mem;
    wire ag_is_link  = (ag_uop_r.uclass == UC_LINK) && (ag_uop_r.subop == 4'd0);
    wire ag_is_unlk  = (ag_uop_r.uclass == UC_LINK) && (ag_uop_r.subop == 4'd1);
    wire ag_is_bf    = (ag_uop_r.uclass == UC_BITFIELD);
    wire [3:0] ag_b_sel = ag_is_bf ? {1'b0, ag_uop_r.ea_reg[2:0]}
                        : (ag_mem && (ag_uop_r.uclass != UC_LINK))
                          ? ag_uop_r.ea_reg : ag_uop_r.dst_reg;
    wire ag_is_cas = (ag_uop_r.uclass == UC_ATOMIC) && (ag_uop_r.subop == 4'd1);
    wire [3:0] ag_c_sel = (ag_is_push || ag_is_link) ? 4'd15
                        : ag_is_cas                  ? ag_uop_r.imm[3:0]
                                                     : ag_uop_r.ea_idx_reg;
    wire ag_mem_operand = ag_uop_r.reads_mem && !ag_uop_r.writes_mem
                       && (ag_uop_r.dst_kind == US_MEM);
    wire ag_push_idx = ag_is_push && ((ag_uop_r.ea_mode == UEA_AN_IDX)
                                    || (ag_uop_r.ea_mode == UEA_PC_IDX));
    wire [3:0] ag_a_sel = ag_is_cas ? ag_uop_r.dst_reg
                        : ag_push_idx ? ag_uop_r.ea_idx_reg
                        : (ag_uop_r.dst_ea_mode != UEA_NONE) ? ag_uop_r.dst_ea_reg
                        : ag_mem_operand ? ag_uop_r.src_reg
                        : (ag_uop_r.reads_mem && !ag_uop_r.writes_mem)
                          ? ag_uop_r.dst_reg : ag_uop_r.src_reg;

    wire fwd_h_wb  = wb_valid_r  && wb_writes_r  && (wb_reg_r  == ag_a_sel);
    wire fwd_h_wbp = wbp_valid_r && wbp_writes_r && (wbp_reg_r == ag_a_sel);
    wire fwd_h_wb2  = wb2_en_r  && (wb2_sel_r  == ag_a_sel);
    wire fwd_h_wbp2 = wbp2_en_r && (wbp2_sel_r == ag_a_sel);
    wire fwd_g_wb  = wb_valid_r  && wb_writes_r  && (wb_reg_r  == ag_b_sel);
    wire fwd_g_wbp = wbp_valid_r && wbp_writes_r && (wbp_reg_r == ag_b_sel);
    wire fwd_g_wb2  = wb2_en_r  && (wb2_sel_r  == ag_b_sel);
    wire fwd_g_wbp2 = wbp2_en_r && (wbp2_sel_r == ag_b_sel);
    wire [31:0] ag_a = fwd_h_wb  ? wb_data_r  : fwd_h_wb2  ? wb2_data_r
                     : fwd_h_wbp ? wbp_data_r : fwd_h_wbp2 ? wbp2_data_r : rf_a_r;
    wire [31:0] ag_b = fwd_g_wb  ? wb_data_r  : fwd_g_wb2  ? wb2_data_r
                     : fwd_g_wbp ? wbp_data_r : fwd_g_wbp2 ? wbp2_data_r : rf_b_r;
    wire fwd_i_wb  = wb_valid_r  && wb_writes_r  && (wb_reg_r  == ag_c_sel);
    wire fwd_i_wbp = wbp_valid_r && wbp_writes_r && (wbp_reg_r == ag_c_sel);
    wire fwd_i_wb2  = wb2_en_r  && (wb2_sel_r  == ag_c_sel);
    wire fwd_i_wbp2 = wbp2_en_r && (wbp2_sel_r == ag_c_sel);
    wire [31:0] ag_c = fwd_i_wb  ? wb_data_r  : fwd_i_wb2  ? wb2_data_r
                     : fwd_i_wbp ? wbp_data_r : fwd_i_wbp2 ? wbp2_data_r : rf_c_r;

    wire [1:0] ag_opnd_siz = ag_uop_r.opnd_word ? UZ_WORD : ag_uop_r.siz;
    wire [31:0] ea_step = (ag_opnd_siz == UZ_BYTE)
                          ? ((ag_uop_r.ea_reg == 4'd15) ? 32'd2 : 32'd1)
                        : (ag_opnd_siz == UZ_WORD) ? 32'd2 : 32'd4;
    wire ag_pc_rel = (ag_uop_r.ea_mode == UEA_PC_D16)
                  || (ag_uop_r.ea_mode == UEA_PC_IDX);
    wire [31:0] ag_pc_lead = (((ag_uop_r.uclass == UC_BITOP) && (ag_uop_r.subop == 4'd1))
                           || (ag_uop_r.uclass == UC_MOVEM))
                           ? 32'd2 : 32'd0;
    wire [31:0] ea_base = ((ag_uop_r.ea_mode == UEA_ABS_W)
                        || (ag_uop_r.ea_mode == UEA_ABS_L)) ? 32'h0
                        : ag_uop_r.ea_bs                    ? 32'h0
                        : ag_pc_rel                         ? (ag_pc2_r + ag_pc_lead)
                                                            : ag_b;
    wire [31:0] ea_adj  = (ag_uop_r.ea_mode == UEA_AN_PRE) ? (32'h0 - ea_step)
                                                           : 32'h0;
    wire [31:0] ag_xn_src = ag_push_idx ? ag_a : ag_c;
    wire [31:0] ag_xn   = ag_uop_r.ea_idx_long ? ag_xn_src
                                               : {{16{ag_xn_src[15]}}, ag_xn_src[15:0]};
    wire [31:0] ag_idx  = (((ag_uop_r.ea_mode == UEA_AN_IDX)
                         || (ag_uop_r.ea_mode == UEA_PC_IDX)) && !ag_uop_r.ea_is)
                        ? (ag_xn << ag_uop_r.ea_idx_scale) : 32'h0;
    wire [31:0] ea_adj_idx = (ag_uop_r.ea_mode == UEA_AN_PRE) ? ea_adj : ag_idx;
    wire [31:0] ag_ea   = ea_base + ag_uop_r.ea_disp + ea_adj_idx;

    wire [31:0] mem_addr_comb = (ag_is_push || ag_is_link) ? (ag_c - 32'd4)
                              : ag_is_unlk                 ? ag_b
                                                           : ag_ea;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) mem_addr_o <= 32'h0;
        else        mem_addr_o <= mem_addr_comb;

endmodule
`default_nettype wire

`default_nettype none
// Phase 0 of ~/.claude/plans/golden-puzzling-music.md, variant (c):
// forwarding-plus-indexed. Isolates the register-indirect/indexed EA path --
// (d8,An,Xn) -- where the forwarding mux genuinely shares AG's own cycle
// with the adder, the sub-case the plan's own design is proven to help by
// construction (unlike variant (b), see ag_ea_probe_pcrel.sv's header).
// Hand-reduced to the ORDINARY (non-push, non-CAS, non-bitfield) indexed-EA
// selector shapes, mirroring ag_b_sel/ag_c_sel's own real values for that
// case (`ag_mem && uclass!=LINK` is true, so ag_b_sel=ea_reg; not a push/
// link/CAS, so ag_c_sel=ea_idx_reg) rather than reproducing every special
// case ag_ea_probe_full.sv already covers -- this probe asks one narrower
// question: how much does JUST the forwarding network plus the adder cost.
module ag_ea_probe_fwd (
    input  wire        clk_4x,
    input  wire        rst_n,

    input  wire [31:0] rf_b_i, rf_c_i,
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
    input  wire [3:0]  ea_reg_i,       // ag_b_sel source: the base An
    input  wire [3:0]  ea_idx_reg_i,   // ag_c_sel source: Xn
    input  wire [31:0] ea_disp_i,
    input  wire        ea_idx_long_i,
    input  wire [1:0]  ea_idx_scale_i,

    output reg  [31:0] mem_addr_o
);

    reg  [31:0] rf_b_r, rf_c_r;
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
    reg  [3:0]  ea_reg_r, ea_idx_reg_r;
    reg  [31:0] ea_disp_r;
    reg         ea_idx_long_r;
    reg  [1:0]  ea_idx_scale_r;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            rf_b_r <= 32'h0; rf_c_r <= 32'h0;
            wb_valid_r <= 1'b0; wb_writes_r <= 1'b0;
            wb_reg_r <= 4'h0; wb_data_r <= 32'h0;
            wbp_valid_r <= 1'b0; wbp_writes_r <= 1'b0;
            wbp_reg_r <= 4'h0; wbp_data_r <= 32'h0;
            wb2_en_r <= 1'b0; wb2_sel_r <= 4'h0; wb2_data_r <= 32'h0;
            wbp2_en_r <= 1'b0; wbp2_sel_r <= 4'h0; wbp2_data_r <= 32'h0;
            ea_reg_r <= 4'h0; ea_idx_reg_r <= 4'h0;
            ea_disp_r <= 32'h0; ea_idx_long_r <= 1'b0; ea_idx_scale_r <= 2'h0;
        end else begin
            rf_b_r <= rf_b_i; rf_c_r <= rf_c_i;
            wb_valid_r <= wb_valid_i; wb_writes_r <= wb_writes_i;
            wb_reg_r <= wb_reg_i; wb_data_r <= wb_data_i;
            wbp_valid_r <= wbp_valid_i; wbp_writes_r <= wbp_writes_i;
            wbp_reg_r <= wbp_reg_i; wbp_data_r <= wbp_data_i;
            wb2_en_r <= wb2_en_i; wb2_sel_r <= wb2_sel_i; wb2_data_r <= wb2_data_i;
            wbp2_en_r <= wbp2_en_i; wbp2_sel_r <= wbp2_sel_i; wbp2_data_r <= wbp2_data_i;
            ea_reg_r <= ea_reg_i; ea_idx_reg_r <= ea_idx_reg_i;
            ea_disp_r <= ea_disp_i; ea_idx_long_r <= ea_idx_long_i;
            ea_idx_scale_r <= ea_idx_scale_i;
        end

    // ag_b_sel/ag_c_sel's own ordinary-case values (see header).
    wire [3:0] ag_b_sel = ea_reg_r;
    wire [3:0] ag_c_sel = ea_idx_reg_r;

    wire fwd_g_wb   = wb_valid_r  && wb_writes_r  && (wb_reg_r  == ag_b_sel);
    wire fwd_g_wbp  = wbp_valid_r && wbp_writes_r && (wbp_reg_r == ag_b_sel);
    wire fwd_g_wb2  = wb2_en_r  && (wb2_sel_r  == ag_b_sel);
    wire fwd_g_wbp2 = wbp2_en_r && (wbp2_sel_r == ag_b_sel);
    wire [31:0] ag_b = fwd_g_wb  ? wb_data_r  : fwd_g_wb2  ? wb2_data_r
                     : fwd_g_wbp ? wbp_data_r : fwd_g_wbp2 ? wbp2_data_r : rf_b_r;
    wire fwd_i_wb   = wb_valid_r  && wb_writes_r  && (wb_reg_r  == ag_c_sel);
    wire fwd_i_wbp  = wbp_valid_r && wbp_writes_r && (wbp_reg_r == ag_c_sel);
    wire fwd_i_wb2  = wb2_en_r  && (wb2_sel_r  == ag_c_sel);
    wire fwd_i_wbp2 = wbp2_en_r && (wbp2_sel_r == ag_c_sel);
    wire [31:0] ag_c = fwd_i_wb  ? wb_data_r  : fwd_i_wb2  ? wb2_data_r
                     : fwd_i_wbp ? wbp_data_r : fwd_i_wbp2 ? wbp2_data_r : rf_c_r;

    // ag_xn/ag_idx for UEA_AN_IDX (ea_is==0, push_idx never applies here).
    wire [31:0] ag_xn  = ea_idx_long_r ? ag_c : {{16{ag_c[15]}}, ag_c[15:0]};
    wire [31:0] ag_idx = ag_xn << ea_idx_scale_r;
    wire [31:0] ag_ea  = ag_b + ea_disp_r + ag_idx;

    wire [31:0] mem_addr_comb = ag_ea;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) mem_addr_o <= 32'h0;
        else        mem_addr_o <= mem_addr_comb;

endmodule
`default_nettype wire

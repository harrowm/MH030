`default_nettype none
// Phase 0 of ~/.claude/plans/golden-puzzling-music.md, variant (b):
// PC-relative-only. Isolates the claim in the plan's own "Real, open risk"
// section -- that for UEA_PC_D16, `ea_base = ag_pc2` directly, with NO
// forwarding mux (ag_b/ag_c) in the path at all, since that mode has no base
// register and no index term. Hand-reduced to exactly that case rather than
// left to the synthesizer to prove dead through a parameterised fixed-mode
// copy of the full logic (see ag_ea_probe_full.sv) -- the point of this
// probe is a guaranteed-minimal baseline, not a trust exercise in constant
// propagation.
//
// What is DELIBERATELY NOT HERE, and why: ag_b/ag_c and their whole
// wb_*/wbp_*/wb2_*/wbp2_*/rf_* forwarding network (UEA_PC_D16 has no base
// register and no index); ag_pc_lead's uclass/subop dependency (held at its
// zero/not-applicable case -- this probe measures the ordinary PC-relative
// read, not the static-bit-number/MOVEM leading-word sub-case); the
// mem_addr outer push/link/unlk mux (PEA/JSR COULD target PC-relative too,
// but that is ag_ea_probe_full.sv's job to cover as part of the complete
// cone -- this probe isolates the narrower claim).
module ag_ea_probe_pcrel (
    input  wire        clk_4x,
    input  wire        rst_n,

    input  wire [31:0] ag_pc2_i,
    input  wire [31:0] ea_disp_i,

    output reg  [31:0] mem_addr_o
);

    reg [31:0] ag_pc2_r, ea_disp_r;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin
            ag_pc2_r  <= 32'h0;
            ea_disp_r <= 32'h0;
        end else begin
            ag_pc2_r  <= ag_pc2_i;
            ea_disp_r <= ea_disp_i;
        end

    // ea_base (PC-relative arm, ag_pc_lead == 0) + ag_uop.ea_disp +
    // ea_adj_idx (both AN_PRE's ea_adj and the AN_IDX/PC_IDX index term are
    // unconditionally 0 for UEA_PC_D16).
    wire [31:0] mem_addr_comb = ag_pc2_r + ea_disp_r;

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) mem_addr_o <= 32'h0;
        else        mem_addr_o <= mem_addr_comb;

endmodule
`default_nettype wire

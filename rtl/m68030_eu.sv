`default_nettype none

// MC68030 Execution Unit wrapper
// Instantiates and wires: eu_regfile, eu_alu, eu_shifter, eu_mul_div, eu_seq.
//
// eu_seq is the EU's internal micro-sequencer.  It handles DECODE→EX→WB
// pipeline stages, RAW-hazard stalling, and dispatches to ALU/shifter/mul-div.
// This wrapper exposes the clean external interface to IFU and exception ctrl.
//
// Memory-access (effective address) ports are reserved for eu_agu (Phase 30).
// For now the EU operates only on register-direct EA modes.

module m68030_eu (
    input  logic        clk_4x,
    input  logic        rst_n,

    // ── Instruction stream (from IFU) ─────────────────────────────────────
    input  logic [15:0] instr_word,   // opcode word
    input  logic        instr_valid,  // opcode valid this cycle
    input  logic [31:0] ext_data,     // extension word / immediate (32-bit)
    input  logic        ext_valid,    // ext_data valid this cycle
    output logic        instr_ack,    // EU consumed instruction
    output logic        eu_busy,      // pipeline stall — IFU must hold instr

    // ── PC (managed externally by IFU; written here on exception/branch) ──
    input  logic        pc_wr_en,
    input  logic [31:0] pc_wr_data,
    output logic [31:0] pc_out,

    // ── VBR (MOVEC target; read by exception controller) ─────────────────
    input  logic        vbr_wr_en,
    input  logic [31:0] vbr_wr_data,
    output logic [31:0] vbr_out,

    // ── Stack pointer outputs (exception controller selects one) ──────────
    output logic [31:0] usp_out,
    output logic [31:0] msp_out,
    output logic [31:0] isp_out,

    // ── Status Register outputs ───────────────────────────────────────────
    output logic [15:0] sr_out,       // full SR (read by exception ctrl, BIU FC)
    output logic        supervisor,   // SR[13] — FC[2] for bus cycles
    output logic        master_mode,  // SR[12]
    output logic [2:0]  ipl_mask,     // SR[10:8]

    // ── Exception signals ─────────────────────────────────────────────────
    output logic        div_trap,     // divide-by-zero (m68030_exc handles)

    // ── Exception controller write-back ───────────────────────────────────
    // ssp_wr: update active supervisor stack pointer (A7, routing by S/M bits)
    input  logic        ssp_wr_en,
    input  logic [31:0] ssp_wr_data,
    // exc_sr_wr: set SR after exception (T=0, S=1, IPL updated)
    input  logic        exc_sr_wr_en,
    input  logic [15:0] exc_sr_wr_data
);

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_regfile
    // -----------------------------------------------------------------------
    logic [3:0]  rd_a_sel, rd_b_sel;
    logic [1:0]  rd_a_siz, rd_b_siz;
    logic [31:0] rd_a_data, rd_b_data;
    logic        wr_en;
    logic [3:0]  wr_sel;
    logic [1:0]  wr_siz;
    logic [31:0] wr_data;
    logic        sr_wr_en;
    logic [15:0] sr_wr_data;
    logic        sr_ccr_only;

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_alu
    // -----------------------------------------------------------------------
    logic [31:0] alu_src, alu_dst, alu_result;
    logic [3:0]  alu_op;
    logic [1:0]  alu_siz;
    logic        alu_x_in, alu_z_in;
    logic        alu_n, alu_z, alu_v, alu_c, alu_x;

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_shifter
    // -----------------------------------------------------------------------
    logic [31:0] shf_operand, shf_result;
    logic [5:0]  shf_count;
    logic [3:0]  shf_op;
    logic [1:0]  shf_siz;
    logic        shf_x_in;
    logic        shf_n, shf_z, shf_v, shf_c, shf_x;

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_mul_div
    // -----------------------------------------------------------------------
    logic [31:0] md_src, md_dst, md_result_lo, md_result_hi;
    logic [2:0]  md_op;
    logic        md_n, md_z, md_v, md_c, md_div_by_zero;

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_bcd
    // -----------------------------------------------------------------------
    logic [7:0]  bcd_src, bcd_dst, bcd_result;
    logic [1:0]  bcd_op;
    logic        bcd_x_in, bcd_z_in, bcd_c, bcd_z_flag;

    // -----------------------------------------------------------------------
    // Internal wires: eu_seq ↔ eu_bitops
    // -----------------------------------------------------------------------
    logic [31:0] bit_dst, bit_result;
    logic [4:0]  bit_num;
    logic [1:0]  bit_op;
    logic        bit_z;

    // -----------------------------------------------------------------------
    // eu_seq — DECODE→EX→WB pipeline and dispatch
    // -----------------------------------------------------------------------
    eu_seq u_seq (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .instr_word   (instr_word),
        .instr_valid  (instr_valid),
        .ext_data     (ext_data),
        .ext_valid    (ext_valid),
        .rd_a_sel     (rd_a_sel),
        .rd_a_siz     (rd_a_siz),
        .rd_a_data    (rd_a_data),
        .rd_b_sel     (rd_b_sel),
        .rd_b_siz     (rd_b_siz),
        .rd_b_data    (rd_b_data),
        .wr_en        (wr_en),
        .wr_sel       (wr_sel),
        .wr_siz       (wr_siz),
        .wr_data      (wr_data),
        .sr_wr_en     (sr_wr_en),
        .sr_wr_data   (sr_wr_data),
        .sr_ccr_only  (sr_ccr_only),
        .sr_out       (sr_out),
        .alu_src      (alu_src),
        .alu_dst      (alu_dst),
        .alu_op       (alu_op),
        .alu_siz      (alu_siz),
        .alu_x_in     (alu_x_in),
        .alu_z_in     (alu_z_in),
        .alu_result   (alu_result),
        .alu_n        (alu_n),
        .alu_z        (alu_z),
        .alu_v        (alu_v),
        .alu_c        (alu_c),
        .alu_x        (alu_x),
        .shf_operand  (shf_operand),
        .shf_count    (shf_count),
        .shf_op       (shf_op),
        .shf_siz      (shf_siz),
        .shf_x_in     (shf_x_in),
        .shf_result   (shf_result),
        .shf_n        (shf_n),
        .shf_z        (shf_z),
        .shf_v        (shf_v),
        .shf_c        (shf_c),
        .shf_x        (shf_x),
        .md_src       (md_src),
        .md_dst       (md_dst),
        .md_op        (md_op),
        .md_result_lo (md_result_lo),
        .md_result_hi (md_result_hi),
        .md_n         (md_n),
        .md_z         (md_z),
        .md_v         (md_v),
        .md_c         (md_c),
        .md_div_by_zero(md_div_by_zero),
        .bcd_src      (bcd_src),
        .bcd_dst      (bcd_dst),
        .bcd_op       (bcd_op),
        .bcd_x_in     (bcd_x_in),
        .bcd_z_in     (bcd_z_in),
        .bcd_result   (bcd_result),
        .bcd_c        (bcd_c),
        .bcd_z        (bcd_z_flag),
        .bit_dst      (bit_dst),
        .bit_num      (bit_num),
        .bit_op       (bit_op),
        .bit_result   (bit_result),
        .bit_z        (bit_z),
        .instr_ack    (instr_ack),
        .seq_busy     (eu_busy),
        .div_trap     (div_trap)
    );

    // -----------------------------------------------------------------------
    // Regfile write mux: exception controller overrides eu_seq writes
    //   ssp_wr_en  → write A7 (wr_sel=F) as longword with new SSP value
    //   exc_sr_wr_en → write full SR (not CCR-only) with new exception SR
    // Both take priority; they fire during exception processing when eu_seq
    // pipeline is quiescent (no normal writes in flight).
    // -----------------------------------------------------------------------
    logic        rf_wr_en;
    logic [3:0]  rf_wr_sel;
    logic [1:0]  rf_wr_siz;
    logic [31:0] rf_wr_data;
    logic        rf_sr_wr_en;
    logic [15:0] rf_sr_wr_data;
    logic        rf_sr_ccr_only;

    assign rf_wr_en       = ssp_wr_en    ? 1'b1           : wr_en;
    assign rf_wr_sel      = ssp_wr_en    ? 4'hF           : wr_sel;  // A7
    assign rf_wr_siz      = ssp_wr_en    ? 2'b00          : wr_siz;  // longword
    assign rf_wr_data     = ssp_wr_en    ? ssp_wr_data    : wr_data;
    assign rf_sr_wr_en    = exc_sr_wr_en ? 1'b1           : sr_wr_en;
    assign rf_sr_wr_data  = exc_sr_wr_en ? exc_sr_wr_data : sr_wr_data;
    assign rf_sr_ccr_only = exc_sr_wr_en ? 1'b0           : sr_ccr_only;

    // -----------------------------------------------------------------------
    // eu_regfile — D0-D7, A0-A7, PC, SR, VBR, USP/ISP/MSP
    // -----------------------------------------------------------------------
    eu_regfile u_rf (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .rd_a_sel    (rd_a_sel),
        .rd_a_siz    (rd_a_siz),
        .rd_a_data   (rd_a_data),
        .rd_b_sel    (rd_b_sel),
        .rd_b_siz    (rd_b_siz),
        .rd_b_data   (rd_b_data),
        .wr_en       (rf_wr_en),
        .wr_sel      (rf_wr_sel),
        .wr_siz      (rf_wr_siz),
        .wr_data     (rf_wr_data),
        .pc_wr_en    (pc_wr_en),
        .pc_wr_data  (pc_wr_data),
        .pc_out      (pc_out),
        .sr_wr_en    (rf_sr_wr_en),
        .sr_wr_data  (rf_sr_wr_data),
        .sr_ccr_only (rf_sr_ccr_only),
        .sr_out      (sr_out),
        .vbr_wr_en   (vbr_wr_en),
        .vbr_wr_data (vbr_wr_data),
        .vbr_out     (vbr_out),
        .usp_out     (usp_out),
        .msp_out     (msp_out),
        .isp_out     (isp_out),
        .supervisor  (supervisor),
        .master_mode (master_mode),
        .ipl_mask    (ipl_mask)
    );

    // -----------------------------------------------------------------------
    // eu_alu — purely combinational
    // -----------------------------------------------------------------------
    eu_alu u_alu (
        .src    (alu_src),
        .dst    (alu_dst),
        .op     (alu_op),
        .siz    (alu_siz),
        .x_in   (alu_x_in),
        .z_in   (alu_z_in),
        .result (alu_result),
        .n_out  (alu_n),
        .z_out  (alu_z),
        .v_out  (alu_v),
        .c_out  (alu_c),
        .x_out  (alu_x)
    );

    // -----------------------------------------------------------------------
    // eu_shifter — purely combinational
    // -----------------------------------------------------------------------
    eu_shifter u_shf (
        .operand (shf_operand),
        .count   (shf_count),
        .op      (shf_op),
        .siz     (shf_siz),
        .x_in    (shf_x_in),
        .result  (shf_result),
        .n_out   (shf_n),
        .z_out   (shf_z),
        .v_out   (shf_v),
        .c_out   (shf_c),
        .x_out   (shf_x)
    );

    // -----------------------------------------------------------------------
    // eu_mul_div — purely combinational
    // -----------------------------------------------------------------------
    eu_mul_div u_md (
        .src        (md_src),
        .dst        (md_dst),
        .op         (md_op),
        .result_lo  (md_result_lo),
        .result_hi  (md_result_hi),
        .n_out      (md_n),
        .z_out      (md_z),
        .v_out      (md_v),
        .c_out      (md_c),
        .div_by_zero(md_div_by_zero)
    );

    // -----------------------------------------------------------------------
    // eu_bcd — purely combinational
    // -----------------------------------------------------------------------
    eu_bcd u_bcd (
        .src    (bcd_src),
        .dst    (bcd_dst),
        .op     (bcd_op),
        .x_in   (bcd_x_in),
        .z_in   (bcd_z_in),
        .result (bcd_result),
        .c_out  (bcd_c),
        .x_out  (),           // not used separately (same as c_out)
        .z_out  (bcd_z_flag)
    );

    // -----------------------------------------------------------------------
    // eu_bitops — purely combinational
    // -----------------------------------------------------------------------
    eu_bitops u_bit (
        .dst     (bit_dst),
        .bit_num (bit_num),
        .op      (bit_op),
        .result  (bit_result),
        .z_out   (bit_z)
    );

endmodule

`default_nettype wire

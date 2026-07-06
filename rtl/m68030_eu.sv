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

    // ── VBR (external override from exception controller) ────────────────
    input  logic        vbr_wr_en,
    input  logic [31:0] vbr_wr_data,
    output logic [31:0] vbr_out,

    // ── Stack pointer outputs (exception controller selects one) ──────────
    output logic [31:0] usp_out,
    output logic [31:0] msp_out,
    output logic [31:0] isp_out,

    // ── Control register outputs (Phase 46: CACR/CAAR to BIU) ────────────
    output logic [31:0] cacr_out,
    output logic [31:0] caar_out,

    // ── Status Register outputs ───────────────────────────────────────────
    output logic [15:0] sr_out,       // full SR (read by exception ctrl, BIU FC)
    output logic        supervisor,   // SR[13] — FC[2] for bus cycles
    output logic        master_mode,  // SR[12]
    output logic [2:0]  ipl_mask,     // SR[10:8]

    // ── Branch signals (to IFU via top) ──────────────────────────────────
    input  logic [31:0] decode_pc,    // PC of instruction at decode (from IFU)
    output logic        branch_taken, // combinational: taken branch this cycle
    output logic [31:0] branch_target,// combinational: branch destination

    // ── Memory bus interface (to BIU via m68030_top) ─────────────────────
    output logic        mem_req,
    output logic        mem_rw,
    output logic [1:0]  mem_siz,
    output logic [2:0]  mem_fc,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack,
    input  logic        mem_berr,
    output logic        mem_rmw,      // 1=hold bus for RMW (TAS)

    // ── Phase 52: FPU coprocessor interface (FC=111 CPU Space) ───────────
    output logic        eu_coproc_req,
    output logic        eu_coproc_rw,
    output logic [1:0]  eu_coproc_siz,
    output logic [2:0]  eu_coproc_fc,
    output logic [31:0] eu_coproc_addr,
    output logic [31:0] eu_coproc_wdata,
    input  logic [31:0] eu_coproc_rdata,
    input  logic        eu_coproc_ack,
    input  logic        eu_coproc_berr,

    // ── Phase 54: MMU instruction interface ──────────────────────────────
    output logic        eu_pflush_req,
    output logic        eu_pflush_all,
    output logic [2:0]  eu_pflush_fc,
    output logic [31:0] eu_pflush_va,
    input  logic        eu_pflush_ack,
    output logic        eu_ptest_req,
    output logic [31:0] eu_ptest_va,
    output logic [2:0]  eu_ptest_fc,
    input  logic        eu_ptest_ack,
    input  logic [15:0] eu_ptest_mmusr,
    output logic [31:0] tc_out,
    output logic [31:0] tt0_out,
    output logic [31:0] tt1_out,

    // ── Address register update port ──────────────────────────────────────
    output logic        an_wr_en,
    output logic [2:0]  an_wr_sel,
    output logic [31:0] an_wr_data,

    // ── Exception signals ─────────────────────────────────────────────────
    output logic        div_trap,     // divide-by-zero (m68030_exc handles)
    output logic        chk_trap,     // CHK/CHK2 out-of-bounds trap

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
    // Phase 46: control register read/write wires (eu_seq ↔ eu_regfile)
    logic [2:0]  seq_sfc_out, seq_dfc_out;
    logic [31:0] seq_cacr_out, seq_caar_out;
    logic        seq_vbr_wr_en;
    logic [31:0] seq_vbr_wr_data;
    logic        seq_sfc_wr_en;
    logic [2:0]  seq_sfc_wr_data;
    logic        seq_dfc_wr_en;
    logic [2:0]  seq_dfc_wr_data;
    logic        seq_cacr_wr_en;
    logic [31:0] seq_cacr_wr_data;
    logic        seq_caar_wr_en;
    logic [31:0] seq_caar_wr_data;
    logic        seq_usp_wr_en;
    logic [31:0] seq_usp_wr_data;
    logic        seq_isp_wr_en;
    logic [31:0] seq_isp_wr_data;
    logic        seq_msp_wr_en;
    logic [31:0] seq_msp_wr_data;

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
        .div_trap     (div_trap),
        .chk_trap     (chk_trap),
        .decode_pc    (decode_pc),
        .branch_taken (branch_taken),
        .branch_target(branch_target),
        .mem_req      (mem_req),
        .mem_rw       (mem_rw),
        .mem_siz      (mem_siz),
        .mem_fc       (mem_fc),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_rdata    (mem_rdata),
        .mem_ack      (mem_ack),
        .mem_berr     (mem_berr),
        .mem_rmw      (mem_rmw),
        // Phase 52: FPU coprocessor
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        // Phase 54: MMU instruction interface
        .eu_pflush_req   (eu_pflush_req),
        .eu_pflush_all   (eu_pflush_all),
        .eu_pflush_fc    (eu_pflush_fc),
        .eu_pflush_va    (eu_pflush_va),
        .eu_pflush_ack   (eu_pflush_ack),
        .eu_ptest_req    (eu_ptest_req),
        .eu_ptest_va     (eu_ptest_va),
        .eu_ptest_fc     (eu_ptest_fc),
        .eu_ptest_ack    (eu_ptest_ack),
        .eu_ptest_mmusr  (eu_ptest_mmusr),
        .tc_out          (tc_out),
        .tt0_out         (tt0_out),
        .tt1_out         (tt1_out),
        .an_wr_en     (an_wr_en),
        .an_wr_sel    (an_wr_sel),
        .an_wr_data   (an_wr_data),
        // Phase 46: control register reads (from eu_regfile)
        .sfc_in       (seq_sfc_out),
        .dfc_in       (seq_dfc_out),
        .vbr_in       (vbr_out),
        .usp_in       (usp_out),
        .isp_in       (isp_out),
        .msp_in       (msp_out),
        .cacr_in      (seq_cacr_out),
        .caar_in      (seq_caar_out),
        // Phase 46: control register writes (to eu_regfile)
        .vbr_wr_en    (seq_vbr_wr_en),
        .vbr_wr_data  (seq_vbr_wr_data),
        .sfc_wr_en    (seq_sfc_wr_en),
        .sfc_wr_data  (seq_sfc_wr_data),
        .dfc_wr_en    (seq_dfc_wr_en),
        .dfc_wr_data  (seq_dfc_wr_data),
        .cacr_wr_en   (seq_cacr_wr_en),
        .cacr_wr_data (seq_cacr_wr_data),
        .caar_wr_en   (seq_caar_wr_en),
        .caar_wr_data (seq_caar_wr_data),
        .usp_wr_en    (seq_usp_wr_en),
        .usp_wr_data  (seq_usp_wr_data),
        .isp_wr_en    (seq_isp_wr_en),
        .isp_wr_data  (seq_isp_wr_data),
        .msp_wr_en    (seq_msp_wr_en),
        .msp_wr_data  (seq_msp_wr_data)
    );

    // -----------------------------------------------------------------------
    // Regfile write mux: exception controller overrides eu_seq writes
    //   ssp_wr_en  → write A7 (wr_sel=F) as longword with new SSP value
    //   exc_sr_wr_en → write full SR (not CCR-only) with new exception SR
    // Both take priority; they fire during exception processing when eu_seq
    // pipeline is quiescent (no normal writes in flight).
    // VBR: OR of external override (vbr_wr_en) and MOVEC write (seq_vbr_wr_en);
    //   external takes priority for data.
    // -----------------------------------------------------------------------
    logic        rf_wr_en;
    logic [3:0]  rf_wr_sel;
    logic [1:0]  rf_wr_siz;
    logic [31:0] rf_wr_data;
    logic        rf_sr_wr_en;
    logic [15:0] rf_sr_wr_data;
    logic        rf_sr_ccr_only;
    logic        rf_vbr_wr_en;
    logic [31:0] rf_vbr_wr_data;

    assign rf_wr_en       = ssp_wr_en    ? 1'b1           : wr_en;
    assign rf_wr_sel      = ssp_wr_en    ? 4'hF           : wr_sel;  // A7
    assign rf_wr_siz      = ssp_wr_en    ? 2'b00          : wr_siz;  // longword
    assign rf_wr_data     = ssp_wr_en    ? ssp_wr_data    : wr_data;
    assign rf_sr_wr_en    = exc_sr_wr_en ? 1'b1           : sr_wr_en;
    assign rf_sr_wr_data  = exc_sr_wr_en ? exc_sr_wr_data : sr_wr_data;
    assign rf_sr_ccr_only = exc_sr_wr_en ? 1'b0           : sr_ccr_only;
    assign rf_vbr_wr_en   = vbr_wr_en | seq_vbr_wr_en;
    assign rf_vbr_wr_data = vbr_wr_en ? vbr_wr_data : seq_vbr_wr_data;

    // -----------------------------------------------------------------------
    // eu_regfile — D0-D7, A0-A7, PC, SR, VBR, USP/ISP/MSP
    // -----------------------------------------------------------------------
    eu_regfile u_rf (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .rd_a_sel     (rd_a_sel),
        .rd_a_siz     (rd_a_siz),
        .rd_a_data    (rd_a_data),
        .rd_b_sel     (rd_b_sel),
        .rd_b_siz     (rd_b_siz),
        .rd_b_data    (rd_b_data),
        .wr_en        (rf_wr_en),
        .wr_sel       (rf_wr_sel),
        .wr_siz       (rf_wr_siz),
        .wr_data      (rf_wr_data),
        .pc_wr_en     (pc_wr_en),
        .pc_wr_data   (pc_wr_data),
        .pc_out       (pc_out),
        .sr_wr_en     (rf_sr_wr_en),
        .sr_wr_data   (rf_sr_wr_data),
        .sr_ccr_only  (rf_sr_ccr_only),
        .sr_out       (sr_out),
        .vbr_wr_en    (rf_vbr_wr_en),
        .vbr_wr_data  (rf_vbr_wr_data),
        .vbr_out      (vbr_out),
        .usp_out      (usp_out),
        .msp_out      (msp_out),
        .isp_out      (isp_out),
        .supervisor   (supervisor),
        .master_mode  (master_mode),
        .ipl_mask     (ipl_mask),
        .an_wr_en     (an_wr_en),
        .an_wr_sel    (an_wr_sel),
        .an_wr_data   (an_wr_data),
        // Phase 46: SFC/DFC/CACR/CAAR
        .sfc_wr_en    (seq_sfc_wr_en),
        .sfc_wr_data  (seq_sfc_wr_data),
        .sfc_out      (seq_sfc_out),
        .dfc_wr_en    (seq_dfc_wr_en),
        .dfc_wr_data  (seq_dfc_wr_data),
        .dfc_out      (seq_dfc_out),
        .cacr_wr_en   (seq_cacr_wr_en),
        .cacr_wr_data (seq_cacr_wr_data),
        .cacr_out     (seq_cacr_out),
        .caar_wr_en   (seq_caar_wr_en),
        .caar_wr_data (seq_caar_wr_data),
        .caar_out     (seq_caar_out),
        // Phase 46: explicit USP/ISP/MSP writes
        .usp_wr_en    (seq_usp_wr_en),
        .usp_wr_data  (seq_usp_wr_data),
        .isp_wr_en    (seq_isp_wr_en),
        .isp_wr_data  (seq_isp_wr_data),
        .msp_wr_en    (seq_msp_wr_en),
        .msp_wr_data  (seq_msp_wr_data)
    );

    // Route CACR/CAAR to module outputs for BIU/MMU use
    assign cacr_out = seq_cacr_out;
    assign caar_out = seq_caar_out;

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

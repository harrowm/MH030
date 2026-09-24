`default_nettype none
`timescale 1ns/1ps
`include "mh030p_uop.svh"

// =============================================================================
// Equivalence sweep: mh030p_decode (rtlp/) vs eu_seq (rtl/), all 65,536 opcodes.
//
// The new decoder is checked against the OLD one rather than against the
// manual, because the old one is what passes 702,142 Harte vectors. That
// makes it the authority on every encoding corner this project already got
// right the hard way.
//
// Only opcodes the new decoder actually CLAIMS (valid && uclass != UC_UNIMPL)
// are compared, so this stays meaningful as coverage grows: adding a family
// to the decoder automatically brings it under test. The reverse direction --
// opcodes the old decoder accepts but the new one does not yet -- is reported
// as a coverage number, not a failure, since partial coverage is the whole
// point of a staged rollout.
//
// Reuses tb/ext_count_overlap_tb.sv's exhaustive-sweep technique (Phases
// 221-224), which is how the last real decode bug in this project was found.
// =============================================================================

module uop_decode_equiv_tb;

    logic clk_4x = 1'b0;
    logic rst_n  = 1'b0;
    always #5 clk_4x = ~clk_4x;

    // ── New decoder (combinational) ─────────────────────────────────────────
    logic [15:0] instr;
    logic [31:0] ext;
    uop_t        uop;

    mh030p_decode u_new (
        .instr (instr),
        .ext   (ext),
        .uop   (uop)
    );

    // ── Old decoder, driven through eu_seq's decode inputs ──────────────────
    // eu_seq is instantiated purely so its combinational decode section can be
    // observed hierarchically; nothing is clocked through it here.
    logic [15:0] o_instr;
    logic [31:0] o_ext;
    assign o_instr = instr;
    assign o_ext   = ext;

    // Hierarchical references into eu_seq's decode signals. Same technique
    // tb/cache_tb.sv and tb/mmu_xlate_tb.sv already use for burst_beat_probe.
    `define OLD u_old
    wire       old_valid   = `OLD.dec_valid;
    wire [2:0] old_unit    = `OLD.dec_unit;
    wire [3:0] old_alu_op  = `OLD.dec_alu_op;
    wire [1:0] old_siz     = `OLD.dec_siz;
    wire [3:0] old_src_reg = `OLD.dec_src_reg;
    // dec_dest_reg ("register to commit result into"), NOT dec_dst_reg
    // ("rd_b: destination/second-operand register", i.e. a READ port
    // selector). uop.dst_reg is a writeback destination, so it maps to
    // dec_dest_reg. Comparing against dec_dst_reg produced a wall of false
    // MOVEA failures -- the exact read-vs-write field-role confusion
    // feedback_read_write_field_roles_swapped.md documents.
    wire [3:0] old_dst_reg = `OLD.dec_dest_reg;
    wire       old_wr_reg  = `OLD.dec_writes_reg;
    wire       old_upd_ccr = `OLD.dec_updates_ccr;
    wire       old_use_imm = `OLD.dec_use_imm;
    wire [31:0] old_imm    = `OLD.dec_imm;

    // eu_seq needs its full port list; everything not feeding decode is tied
    // off. Only the combinational decode outputs above are read.
    eu_seq u_old (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr_word(o_instr), .instr_valid(1'b1),
        .ext_data(o_ext), .ext_valid(1'b1),
        .q3_word(16'h0), .ext34_data(32'h0), .q5_word(16'h0), .q6_word(16'h0),
        .rd_a_sel(), .rd_a_siz(), .rd_a_data(32'h0),
        .rd_b_sel(), .rd_b_siz(), .rd_b_data(32'h0),
        .rd_c_sel(), .rd_c_siz(), .rd_c_data(32'h0),
        .rd_prev_a_sel(), .rd_prev_a_siz(), .rd_prev_a_data(32'h0),
        .rd_prev_b_sel(), .rd_prev_b_siz(), .rd_prev_b_data(32'h0),
        .rd_prev_c_sel(), .rd_prev_c_siz(), .rd_prev_c_data(32'h0),
        .wr_en(), .wr_sel(), .wr_siz(), .wr_data(),
        .sr_wr_en(), .sr_wr_data(), .sr_ccr_only(), .sr_out(16'h2700),
        .alu_src(), .alu_dst(), .alu_op(), .alu_siz(), .alu_x_in(), .alu_z_in(),
        .alu_result(32'h0), .alu_n(1'b0), .alu_z(1'b0), .alu_v(1'b0),
        .alu_c(1'b0), .alu_x(1'b0),
        .shf_operand(), .shf_count(), .shf_op(), .shf_siz(), .shf_x_in(),
        .shf_result(32'h0), .shf_n(1'b0), .shf_z(1'b0), .shf_v(1'b0),
        .shf_c(1'b0), .shf_x(1'b0),
        .md_src(), .md_dst(), .md_op(),
        .md_result_lo(32'h0), .md_result_hi(32'h0),
        .md_n(1'b0), .md_z(1'b0), .md_v(1'b0), .md_c(1'b0),
        .md_div_by_zero(1'b0), .md_div_start(), .md_div_busy(1'b0),
        .bcd_src(), .bcd_dst(), .bcd_op(), .bcd_x_in(), .bcd_z_in(),
        .bcd_result(8'h0), .bcd_c(1'b0), .bcd_z(1'b0), .bcd_v(1'b0),
        .bit_dst(), .bit_num(), .bit_op(), .bit_result(32'h0), .bit_z(1'b0),
        .instr_ack(), .seq_busy(), .div_trap(), .chk_trap(), .mmu_config_trap(),
        .eu_need_ext(),
        .int_pending(1'b0), .eu_int_ready(), .exc_active(1'b0),
        .decode_pc(32'h0), .ex_decode_pc_out(), .branch_taken(), .branch_target(),
        .mem_req(), .mem_new_dispatch(), .mem_rw(), .mem_siz(), .mem_fc(),
        .mem_addr(), .mem_wdata(), .mem_rdata(32'h0), .mem_ack(1'b0),
        .mem_berr(1'b0), .mem_rmw(), .mem_rmw_lookup(),
        .eu_is_cas(), .eu_cas_hold(),
        .eu_coproc_req(), .eu_coproc_rw(), .eu_coproc_siz(), .eu_coproc_fc(),
        .eu_coproc_addr(), .eu_coproc_wdata(), .eu_coproc_rdata(32'h0),
        .eu_coproc_ack(1'b0), .eu_coproc_berr(1'b0),
        .eu_bkpt_req(), .eu_bkpt_rw(), .eu_bkpt_siz(), .eu_bkpt_fc(),
        .eu_bkpt_addr(), .eu_bkpt_wdata(), .eu_bkpt_rdata(32'h0),
        .eu_bkpt_ack(1'b0), .eu_bkpt_berr(1'b0), .eu_bkpt_illegal_req(),
        .eu_bkpt_subst_active(), .eu_bkpt_subst_word(),
        .an_wr_en(), .an_wr_sel(), .an_wr_data(),
        .wr2_en()
    );

    // ── Sweep ───────────────────────────────────────────────────────────────
    integer claimed, agreed, mismatches, old_only;
    integer i;
    reg [31:0] first_bad;

    task automatic report(input [15:0] op, input string what,
                          input [31:0] got, input [31:0] exp);
        if (mismatches < 20)
            $display("MISMATCH op=%04h %-12s new=%08h old=%08h", op, what, got, exp);
        mismatches = mismatches + 1;
        if (first_bad == 32'hFFFF_FFFF) first_bad = {16'h0, op};
    endtask

    initial begin
        $display("=== uop decode equivalence sweep (all 65536 opcodes) ===");
        claimed = 0; agreed = 0; mismatches = 0; old_only = 0;
        first_bad = 32'hFFFF_FFFF;
        ext = 32'h0000_1234;      // arbitrary but fixed immediate
        rst_n = 1'b0;
        repeat (2) @(posedge clk_4x);
        rst_n = 1'b1;
        @(posedge clk_4x);

        for (i = 0; i < 65536; i = i + 1) begin
            instr = i[15:0];
            #1;   // settle both combinational decoders

            if (uop.valid && (uop.uclass != UC_UNIMPL)
                          && (uop.uclass != UC_INVALID)) begin
                claimed = claimed + 1;

                // The old decoder must also consider this a real instruction.
                if (!old_valid) begin
                    report(instr, "old-invalid", 32'h1, 32'h0);
                end else begin
                    // Compare the fields both decoders genuinely share.
                    if (uop.siz !== old_siz)
                        report(instr, "siz", {30'h0, uop.siz}, {30'h0, old_siz});
                    else if (uop.unit !== old_unit)
                        report(instr, "unit", {29'h0, uop.unit}, {29'h0, old_unit});
                    else if ((uop.unit == UU_ALU) && (uop.alu_op !== old_alu_op))
                        report(instr, "alu_op", {28'h0, uop.alu_op},
                                                {28'h0, old_alu_op});
                    else if (uop.writes_reg !== old_wr_reg)
                        report(instr, "writes_reg", {31'h0, uop.writes_reg},
                                                    {31'h0, old_wr_reg});
                    else if (uop.updates_ccr !== old_upd_ccr)
                        report(instr, "updates_ccr", {31'h0, uop.updates_ccr},
                                                     {31'h0, old_upd_ccr});
                    else if (uop.writes_reg && (uop.dst_reg !== old_dst_reg))
                        report(instr, "dst_reg", {28'h0, uop.dst_reg},
                                                 {28'h0, old_dst_reg});
                    else
                        agreed = agreed + 1;
                end
            end else if (old_valid) begin
                old_only = old_only + 1;
            end
        end

        $display("");
        $display("claimed by new decoder : %0d", claimed);
        $display("  agreed with old      : %0d", agreed);
        $display("  mismatches           : %0d", mismatches);
        $display("old-only (not yet done): %0d  <- coverage gap, not a failure",
                 old_only);
        $display("");
        if (mismatches == 0) begin
            $display("=== 0 failure(s) ===");
            $display("ALL TESTS PASSED");
        end else begin
            $display("=== %0d failure(s), first at opcode %04h ===",
                     mismatches, first_bad[15:0]);
        end
        $finish;
    end

endmodule

`default_nettype wire

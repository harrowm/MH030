`default_nettype none
`timescale 1ps/1ps

// Phase 36: branches, MOVEQ, ADDQ/SUBQ, Scc, DBcc, SWAP, EXT, NOP
//
// Pipeline timing (always_ff at posedge clk_4x, period=10ps):
//   negedge N  : drive instr_word/instr_valid → combinational logic settles
//   posedge T  : DECODE accepts, EX latch fires (NBA at end of T)
//   negedge T  : EX NBAs settled → branch_taken(EX) stable
//   posedge T+2: regfile write via WB
//   negedge T+2: d_reg[n] committed and stable

module seq36_tb;

    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;
    logic        instr_ack, eu_busy;
    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 0;
    logic [31:0] pc_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;
    logic [31:0] decode_pc    = 0;
    logic        branch_taken;
    logic [31:0] branch_target;

    m68030_eu u_eu (
        .clk_4x        (clk_4x),      .rst_n         (rst_n),
        .instr_word    (instr_word),   .instr_valid   (instr_valid),
        .ext_data      (ext_data),     .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),    .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en),     .pc_wr_data    (pc_wr_data),   .pc_out(pc_out),
        .vbr_wr_en     (1'b0),         .vbr_wr_data   (32'h0),        .vbr_out(),
        .usp_out(),    .msp_out(),     .isp_out(),
        .sr_out        (sr_out),       .supervisor    (supervisor),
        .master_mode   (master_mode),  .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (decode_pc),
        .branch_taken  (branch_taken), .branch_target (branch_target),
        .ssp_wr_en     (1'b0),         .ssp_wr_data   (32'h0),
        .exc_sr_wr_en  (1'b0),         .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    // Instruction encodings
    // -----------------------------------------------------------------------
    localparam [15:0] NOP = 16'h4E71;

    function automatic [15:0] MOVEQ(input [2:0] dn, input [7:0] imm);
        MOVEQ = {4'h7, dn, 1'b0, imm};
    endfunction
    function automatic [15:0] CLR_L(input [2:0] dn);
        CLR_L = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, dn};
    endfunction
    function automatic [15:0] ADDI_L(input [2:0] dn);
        ADDI_L = {4'h0, 3'b011, 1'b0, 2'b10, 3'b000, dn};
    endfunction
    function automatic [15:0] ADDQ(input [2:0] imm3, input [1:0] ss, input [2:0] dn);
        ADDQ = {4'h5, imm3, 1'b0, ss, 3'b000, dn};
    endfunction
    function automatic [15:0] SUBQ(input [2:0] imm3, input [1:0] ss, input [2:0] dn);
        SUBQ = {4'h5, imm3, 1'b1, ss, 3'b000, dn};
    endfunction
    function automatic [15:0] SWAP_DN(input [2:0] dn);
        SWAP_DN = {4'h4, 3'b100, 1'b0, 2'b01, 3'b000, dn};
    endfunction
    function automatic [15:0] EXT_W(input [2:0] dn);
        EXT_W = {4'h4, 3'b100, 1'b0, 2'b10, 3'b000, dn};
    endfunction
    function automatic [15:0] EXT_L(input [2:0] dn);
        EXT_L = {4'h4, 3'b100, 1'b0, 2'b11, 3'b000, dn};
    endfunction
    function automatic [15:0] EXTB_L(input [2:0] dn);
        EXTB_L = {4'h4, 3'b100, 1'b1, 2'b11, 3'b000, dn};
    endfunction
    function automatic [15:0] SCC(input [3:0] cc, input [2:0] dn);
        SCC = {4'h5, cc, 2'b11, 3'b000, dn};
    endfunction
    function automatic [15:0] DBCC(input [3:0] cc, input [2:0] dn);
        DBCC = {4'h5, cc, 2'b11, 3'b001, dn};
    endfunction
    function automatic [15:0] BRA_B(input [7:0] d8);
        BRA_B = {4'h6, 4'h0, d8};
    endfunction
    function automatic [15:0] BCC_B(input [3:0] cc, input [7:0] d8);
        BCC_B = {4'h6, cc, d8};
    endfunction
    function automatic [15:0] MOVE_L(input [2:0] dm, input [2:0] dn);
        MOVE_L = {4'h2, dn, 3'b000, 3'b000, dm};
    endfunction

    localparam [3:0] CC_T=4'h0, CC_F=4'h1, CC_NE=4'h6, CC_EQ=4'h7;

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;

    task automatic check(input string name, input logic cond);
        if (cond) begin $display("  PASS: %s", name); pass_count++; end
        else       begin $display("  FAIL: %s", name); fail_count++; end
    endtask

    // Drive instruction, wait until negedge after WB posedge (regfile stable).
    task automatic run_and_wait(input [15:0] iw,
                                 input [31:0] ed = 32'h0,
                                 input        ev = 1'b0);
        @(negedge clk_4x);
        instr_word=iw; instr_valid=1'b1; ext_data=ed; ext_valid=ev;
        @(posedge clk_4x);
        while (!instr_ack) @(posedge clk_4x);
        @(negedge clk_4x); instr_valid=1'b0; ext_valid=1'b0;
        @(posedge clk_4x);   // WB latch
        @(posedge clk_4x);   // regfile write
        @(negedge clk_4x);   // stable
    endtask

    // Issue branch (decode-stage); branch_taken settled since negedge when instr driven.
    task automatic issue_branch(input [15:0] iw,
                                 output logic taken, output logic [31:0] tgt,
                                 input [31:0] ed = 32'h0, input ev = 1'b0);
        @(negedge clk_4x);
        instr_word=iw; instr_valid=1'b1; ext_data=ed; ext_valid=ev;
        @(posedge clk_4x);
        taken = branch_taken; tgt = branch_target;
        while (!instr_ack) @(posedge clk_4x);
        @(negedge clk_4x); instr_valid=1'b0; ext_valid=1'b0;
        @(posedge clk_4x); @(negedge clk_4x);
    endtask

    // Issue DBcc (EX-stage branch); sampled at negedge T after ack posedge.
    task automatic issue_dbcc(input [15:0] iw, input [15:0] disp16,
                               output logic taken, output logic [31:0] tgt);
        @(negedge clk_4x);
        instr_word=iw; instr_valid=1'b1;
        ext_data={16'h0, disp16}; ext_valid=1'b1;
        @(posedge clk_4x);
        while (!instr_ack) @(posedge clk_4x);
        @(negedge clk_4x);  // EX latch NBAs settled; branch_taken(EX) stable
        taken=branch_taken; tgt=branch_target;
        instr_valid=1'b0; ext_valid=1'b0;
        @(posedge clk_4x); @(posedge clk_4x); @(negedge clk_4x);
    endtask

    // -----------------------------------------------------------------------
    // Test sequence — all local variables declared here (Icarus 13 requirement)
    // -----------------------------------------------------------------------
    logic [15:0] sr_save;
    logic        b_taken;
    logic [31:0] b_tgt;

    initial begin
        $display("=== Phase 36 tests ===");
        rst_n = 1'b0;
        repeat(4) @(posedge clk_4x);
        @(negedge clk_4x); rst_n = 1'b1;
        repeat(2) @(posedge clk_4x);

        // ── P36-1: NOP ────────────────────────────────────────────────────
        $display("P36-1: NOP");
        sr_save = sr_out;
        run_and_wait(NOP);
        check("NOP: SR unchanged", sr_out == sr_save);

        // ── P36-2: MOVEQ #-1, D0 ─────────────────────────────────────────
        $display("P36-2: MOVEQ #-1, D0");
        run_and_wait(MOVEQ(3'd0, 8'hFF));
        check("MOVEQ #-1,D0: D0=0xFFFFFFFF", u_eu.u_rf.d_reg[0] == 32'hFFFFFFFF);
        check("MOVEQ #-1,D0: N=1",             sr_out[3] == 1'b1);
        check("MOVEQ #-1,D0: Z=0",             sr_out[2] == 1'b0);

        // ── P36-3: MOVEQ #0, D1 ──────────────────────────────────────────
        $display("P36-3: MOVEQ #0, D1");
        run_and_wait(MOVEQ(3'd1, 8'h00));
        check("MOVEQ #0,D1: D1=0", u_eu.u_rf.d_reg[1] == 32'h0);
        check("MOVEQ #0,D1: Z=1",  sr_out[2] == 1'b1);
        check("MOVEQ #0,D1: N=0",  sr_out[3] == 1'b0);

        // ── P36-4: ADDQ.L #3, D2 ─────────────────────────────────────────
        $display("P36-4: ADDQ.L #3, D2");
        // D2=0 after reset
        run_and_wait(ADDQ(3'd3, 2'b10, 3'd2));
        check("ADDQ.L #3,D2: D2=3", u_eu.u_rf.d_reg[2] == 32'h3);
        check("ADDQ.L #3,D2: Z=0",  sr_out[2] == 1'b0);

        // ── P36-5: SUBQ.W #4, D2 ─────────────────────────────────────────
        $display("P36-5: SUBQ.W #4, D2");
        // D2[15:0]=3; 3-4 = 0xFFFF with borrow
        run_and_wait(SUBQ(3'd4, 2'b01, 3'd2));
        check("SUBQ.W #4,D2: D2[15:0]=0xFFFF",  u_eu.u_rf.d_reg[2][15:0] == 16'hFFFF);
        check("SUBQ.W #4,D2: D2[31:16]=0",       u_eu.u_rf.d_reg[2][31:16] == 16'h0000);
        check("SUBQ.W #4,D2: N=1",               sr_out[3] == 1'b1);
        check("SUBQ.W #4,D2: C=1",               sr_out[0] == 1'b1);

        // ── P36-6: BRA.B taken ───────────────────────────────────────────
        $display("P36-6: BRA.B taken");
        decode_pc = 32'h1000;
        issue_branch(BRA_B(8'd10), b_taken, b_tgt);
        decode_pc = 32'h0;
        check("BRA.B: taken",          b_taken == 1'b1);
        check("BRA.B: target=0x100C",  b_tgt == 32'h100C);  // 0x1000+2+10

        // ── P36-7: BEQ.B taken when Z=1 ──────────────────────────────────
        $display("P36-7: BEQ.B taken (Z=1)");
        run_and_wait(MOVEQ(3'd3, 8'h00));   // Z=1
        decode_pc = 32'h2000;
        issue_branch(BCC_B(CC_EQ, 8'd6), b_taken, b_tgt);
        decode_pc = 32'h0;
        check("BEQ.B: taken",         b_taken == 1'b1);
        check("BEQ.B: target=0x2008", b_tgt == 32'h2008);  // 0x2000+2+6

        // ── P36-8: BNE.B not taken when Z=1 ──────────────────────────────
        $display("P36-8: BNE.B not taken (Z=1)");
        issue_branch(BCC_B(CC_NE, 8'd10), b_taken, b_tgt);
        check("BNE.B: not taken (Z=1)", b_taken == 1'b0);

        // ── P36-9: SWAP D3 ────────────────────────────────────────────────
        $display("P36-9: SWAP D3");
        run_and_wait(CLR_L(3'd3));
        run_and_wait(ADDI_L(3'd3), 32'hABCD1234, 1'b1);
        run_and_wait(SWAP_DN(3'd3));
        check("SWAP D3: =0x1234ABCD", u_eu.u_rf.d_reg[3] == 32'h1234ABCD);

        // ── P36-10: EXT.W D4 ──────────────────────────────────────────────
        $display("P36-10: EXT.W D4");
        run_and_wait(CLR_L(3'd4));
        run_and_wait(ADDI_L(3'd4), 32'h80, 1'b1);   // D4 = 0x80
        run_and_wait(EXT_W(3'd4));
        check("EXT.W D4: D4[15:0]=0xFF80",  u_eu.u_rf.d_reg[4][15:0] == 16'hFF80);
        check("EXT.W D4: D4[31:16]=0x0000", u_eu.u_rf.d_reg[4][31:16] == 16'h0000);
        check("EXT.W D4: N=1",               sr_out[3] == 1'b1);

        // ── P36-11: EXT.L D5 ──────────────────────────────────────────────
        $display("P36-11: EXT.L D5");
        run_and_wait(CLR_L(3'd5));
        run_and_wait(ADDI_L(3'd5), 32'h8001, 1'b1);  // D5 = 0x8001
        run_and_wait(EXT_L(3'd5));
        check("EXT.L D5: =0xFFFF8001", u_eu.u_rf.d_reg[5] == 32'hFFFF8001);
        check("EXT.L D5: N=1",          sr_out[3] == 1'b1);

        // ── P36-12: EXTB.L D6 ─────────────────────────────────────────────
        $display("P36-12: EXTB.L D6");
        run_and_wait(CLR_L(3'd6));
        run_and_wait(ADDI_L(3'd6), 32'hFF7F, 1'b1);  // D6 = 0xFF7F
        run_and_wait(EXTB_L(3'd6));
        // D6[7:0]=0x7F → sign-extend byte to long → 0x0000007F
        check("EXTB.L D6: =0x0000007F", u_eu.u_rf.d_reg[6] == 32'h0000007F);
        check("EXTB.L D6: N=0",          sr_out[3] == 1'b0);

        // ── P36-13: SEQ D0 (Z=1 → 0xFF) ──────────────────────────────────
        $display("P36-13: SEQ D0 (Z=1)");
        run_and_wait(MOVEQ(3'd7, 8'h00));    // Z=1
        run_and_wait(CLR_L(3'd0));
        run_and_wait(SCC(CC_EQ, 3'd0));
        check("SEQ D0: D0[7:0]=0xFF (Z=1)", u_eu.u_rf.d_reg[0][7:0] == 8'hFF);

        // ── P36-14: SNE D0 (Z=1 → 0x00) ──────────────────────────────────
        $display("P36-14: SNE D0 (Z=1)");
        run_and_wait(SCC(CC_NE, 3'd0));
        check("SNE D0: D0[7:0]=0x00 (Z=1)", u_eu.u_rf.d_reg[0][7:0] == 8'h00);

        // ── P36-15: DBF D7,d16 ────────────────────────────────────────────
        $display("P36-15: DBF D7,d16 (counter=2 → 1, branch taken)");
        run_and_wait(CLR_L(3'd7));
        run_and_wait(ADDI_L(3'd7), 32'h2, 1'b1);   // D7 = 2
        decode_pc = 32'h3000;
        issue_dbcc(DBCC(CC_F, 3'd7), 16'd4, b_taken, b_tgt);
        decode_pc = 32'h0;
        // target = 0x3000 + 2 + 4 = 0x3006
        check("DBF: D7[15:0]=1 (decremented)", u_eu.u_rf.d_reg[7][15:0] == 16'h0001);
        check("DBF: branch taken",              b_taken == 1'b1);
        check("DBF: target=0x3006",             b_tgt == 32'h3006);

        // ── P36-16: MOVE.L Dm,Dn (UNIT_MOVE fix) ─────────────────────────
        $display("P36-16: MOVE.L D0,D1 (UNIT_MOVE fix)");
        run_and_wait(MOVEQ(3'd0, 8'h42));    // D0 = 0x42
        run_and_wait(MOVEQ(3'd1, 8'h00));    // D1 = 0
        run_and_wait(MOVE_L(3'd0, 3'd1));    // D1 = D0 = 0x42
        check("MOVE.L D0,D1: D1=0x42", u_eu.u_rf.d_reg[1] == 32'h00000042);

        // ── Summary ──────────────────────────────────────────────────────
        repeat(4) @(posedge clk_4x);
        $display("=== Phase 36: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL PASS");
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

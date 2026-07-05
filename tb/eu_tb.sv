`default_nettype none
`timescale 1ps/1ps

// Phase 28: m68030_eu integration smoke test.
// Verifies wiring of eu_seq + eu_regfile + eu_alu + eu_shifter + eu_mul_div.
//
// Tests:
//   EU-1: Basic ALU instruction (ADDI.L) flows through the wrapper correctly
//   EU-2: PC write and read-back
//   EU-3: VBR write and read-back
//   EU-4: SR supervisor fields (supervisor, master_mode, ipl_mask)
//   EU-5: USP/ISP/MSP stack pointer outputs after reset (reset value 0x2700 → S=1, M=0)
//   EU-6: div_trap asserts on DIVU.W by zero
//   EU-7: eu_busy asserts on RAW hazard; clears after stall resolves
//   EU-8: CCR propagates correctly (ADDI sets Z when result=0)

module eu_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // -----------------------------------------------------------------------
    // m68030_eu interface
    // -----------------------------------------------------------------------
    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;

    logic        instr_ack, eu_busy;

    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 0;
    logic [31:0] pc_out;

    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    m68030_eu u_eu (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .instr_word  (instr_word),
        .instr_valid (instr_valid),
        .ext_data    (ext_data),
        .ext_valid   (ext_valid),
        .instr_ack   (instr_ack),
        .eu_busy     (eu_busy),
        .pc_wr_en    (pc_wr_en),
        .pc_wr_data  (pc_wr_data),
        .pc_out      (pc_out),
        .vbr_wr_en   (vbr_wr_en),
        .vbr_wr_data (vbr_wr_data),
        .vbr_out     (vbr_out),
        .usp_out     (usp_out),
        .msp_out     (msp_out),
        .isp_out     (isp_out),
        .sr_out      (sr_out),
        .supervisor  (supervisor),
        .master_mode (master_mode),
        .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (32'h0),
        .branch_taken  (),
        .branch_target (),
        .mem_req       (),
        .mem_rw        (),
        .mem_siz       (),
        .mem_fc        (),
        .mem_addr      (),
        .mem_wdata     (),
        .mem_rdata     (32'h0),
        .mem_ack       (1'b0),
        .mem_berr      (1'b0),
        .an_wr_en      (),
        .an_wr_sel     (),
        .an_wr_data    (),
        .ssp_wr_en     (1'b0),
        .ssp_wr_data   (32'h0),
        .exc_sr_wr_en  (1'b0),
        .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    // Hierarchical register file references (verified at check time)
    // -----------------------------------------------------------------------
    // u_eu.u_rf.d_reg[n]  — D0-D7
    // u_eu.u_rf.a_reg[n]  — A0-A6
    // u_eu.u_rf.sr_r      — SR register

    // -----------------------------------------------------------------------
    // Instruction encodings
    // -----------------------------------------------------------------------
    localparam [15:0]
        ADDI_L_D0  = 16'h0680,   // ADDI.L #imm, D0
        ADDI_L_D1  = 16'h0681,   // ADDI.L #imm, D1
        CLR_L_D0   = 16'h4280,   // CLR.L D0
        DIVU_D1_D0 = 16'h80C1,   // DIVU.W D1, D0  (D0 ÷ D1[15:0])
        ADD_L_D0_D1= 16'hD280;   // ADD.L D0, D1   (D1 = D1 + D0, dir=0)

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    // Send one instruction and drain 2 cycles (EX + WB pipeline flush).
    // instr_valid/ext_valid deasserted after #1 following posedge so
    // always_ff samples correctly (Icarus timing).
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        instr_word = iw; instr_valid = 1'b1;
        ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 1'b0; ext_valid = 1'b0;
        // drain: wait for EX and WB stages to flush
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 28: m68030_eu ===");

        // Release reset
        @(posedge clk_4x); #1;
        rst_n = 1'b1;
        @(posedge clk_4x); #1;

        // ================================================================
        // EU-1: Basic ALU instruction through the wrapper
        // ================================================================
        $display("--- EU-1: ADDI through wrapper ---");
        run(ADDI_L_D0, 32'd42, 1'b1);
        check32("EU-1: D0=42", u_eu.u_rf.d_reg[0], 32'd42);

        // ================================================================
        // EU-2: PC write / read-back
        // ================================================================
        $display("--- EU-2: PC write ---");
        pc_wr_data = 32'hCAFE_0000; pc_wr_en = 1'b1;
        @(posedge clk_4x); #1;
        pc_wr_en = 1'b0;
        @(posedge clk_4x); #1;
        check32("EU-2: PC=0xCAFE0000", pc_out, 32'hCAFE_0000);

        // ================================================================
        // EU-3: VBR write / read-back
        // ================================================================
        $display("--- EU-3: VBR write ---");
        vbr_wr_data = 32'h0010_0000; vbr_wr_en = 1'b1;
        @(posedge clk_4x); #1;
        vbr_wr_en = 1'b0;
        @(posedge clk_4x); #1;
        check32("EU-3: VBR=0x00100000", vbr_out, 32'h0010_0000);

        // ================================================================
        // EU-4: SR supervisor fields
        // After reset: SR=0x2700 → T=0, S=1, M=0, IPL=7
        // supervisor=1, master_mode=0, ipl_mask=3'h7
        // ================================================================
        $display("--- EU-4: SR supervisor fields ---");
        check32("EU-4: SR=0x2700", sr_out, 16'h2700);
        check("EU-4: supervisor=1", supervisor);
        check("EU-4: master_mode=0", !master_mode);
        check32("EU-4: ipl_mask=7", {29'h0, ipl_mask}, 32'd7);

        // ================================================================
        // EU-5: Stack pointer outputs after reset
        // USP, ISP, MSP all reset to 0
        // ================================================================
        $display("--- EU-5: Stack pointers at reset ---");
        check32("EU-5: USP=0", usp_out, 32'h0);
        check32("EU-5: ISP=0", isp_out, 32'h0);
        check32("EU-5: MSP=0", msp_out, 32'h0);

        // ================================================================
        // EU-6: div_trap on DIVU.W by zero
        // D0 has a value; D1=0; DIVU.W D1,D0 → div_by_zero → div_trap
        // ================================================================
        $display("--- EU-6: div_trap ---");
        // D0=42 already; ensure D1=0 (just cleared by CLR)
        run(CLR_L_D0, 32'h0, 1'b0);              // D0=0
        run(ADDI_L_D1, 32'd1, 1'b1);             // D1=1
        run(ADDI_L_D0, 32'hDEAD, 1'b1);          // D0=0xDEAD
        // Now issue CLR D1 via immediate: we'll fake D1=0 using CLR.L D1
        // CLR.L D1 = 0x4281
        run(16'h4281, 32'h0, 1'b0);              // CLR D1 → D1=0
        // Issue DIVU.W D1,D0 — D1[15:0]=0 → div by zero
        // div_trap = ex_valid && ex_unit==UNIT_DIV && md_div_by_zero: fires while DIVU is in EX.
        // Check at posedge+#1 immediately after DIVU enters EX (before instr_valid deasserted clears EX).
        instr_word = DIVU_D1_D0; instr_valid = 1'b1;
        ext_data = 32'h0; ext_valid = 1'b0;
        @(posedge clk_4x); #1; // DIVU → EX; div_trap fires now
        check("EU-6: div_trap asserted", div_trap);
        instr_valid = 1'b0;
        @(posedge clk_4x); #1; // EX → bubble; drain
        @(posedge clk_4x); #1;

        // ================================================================
        // EU-7: eu_busy on RAW hazard
        // A writes D0; B reads D0 immediately → 2-cycle stall
        // ================================================================
        $display("--- EU-7: eu_busy stall ---");
        run(CLR_L_D0, 32'h0, 1'b0); // D0=0
        run(16'h4281, 32'h0, 1'b0); // D1=0

        // Feed A: ADDI.L #10, D0
        instr_word = ADDI_L_D0; ext_data = 32'd10; ext_valid = 1'b1;
        instr_valid = 1'b1;
        @(posedge clk_4x); #1; // A → EX

        // Feed B immediately: ADD.L D0,D1 (reads D0 — RAW on A)
        instr_word = ADD_L_D0_D1; ext_valid = 1'b0;
        @(posedge clk_4x); #1; // hazard_ex stall; A → WB
        check("EU-7: eu_busy stall cycle 1", eu_busy);
        @(posedge clk_4x); #1; // hazard_wb stall; D0=10 committed
        // at this point wb cleared → eu_busy=0; keep instr_valid=1 so B enters EX
        @(posedge clk_4x); #1; // stall=0; B → EX
        instr_valid = 1'b0;
        @(posedge clk_4x); #1; // B → WB
        @(posedge clk_4x); #1; // D1 committed
        check32("EU-7: D1=10 (stall resolved)", u_eu.u_rf.d_reg[1], 32'd10);

        // ================================================================
        // EU-8: CCR Z flag — ADDI result = 0 sets Z
        // ================================================================
        $display("--- EU-8: CCR Z flag ---");
        run(CLR_L_D0, 32'h0, 1'b0);            // D0=0, Z=1
        run(ADDI_L_D0, 32'hFFFF_FFFF, 1'b1);  // D0=0+(-1)=0xFFFF_FFFF, Z=0
        // ADDI.L #1, D0 → D0 = 0xFFFF_FFFF + 1 = 0, carry, Z=1
        run(ADDI_L_D0, 32'd1, 1'b1);
        check32("EU-8: D0=0 (wrap)", u_eu.u_rf.d_reg[0], 32'h0);
        check("EU-8: Z=1 (result=0)", u_eu.u_rf.sr_r[2]);

        // ================================================================
        // Done
        // ================================================================
        @(posedge clk_4x); #1;
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED");
        $finish;
    end

endmodule

`default_nettype wire

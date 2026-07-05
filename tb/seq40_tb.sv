`default_nettype none
`timescale 1ps/1ps

// Phase 40 testbench: Absolute EA (xxx).W and (xxx).L
//   P40-1: MOVE.L D0, (xxx).W  — write Dn to absolute short address
//   P40-2: MOVE.L D1, (xxx).L  — write Dn to absolute long address
//   P40-3: MOVE.L (xxx).W, D2  — read from absolute short address to Dn
//   P40-4: MOVE.L (xxx).L, D3  — read from absolute long address to Dn
//   P40-5: MOVEA.L (xxx).W, A1 — load An from absolute short address
//   P40-6: MOVEA.L (xxx).L, A2 — load An from absolute long address
//   P40-7: LEA (xxx).W, A3     — load absolute short address as EA
//   P40-8: LEA (xxx).L, A4     — load absolute long address as EA
//   P40-9: JMP (xxx).W         — jump to absolute short address
//   P40-10: JSR (xxx).L        — call absolute long address, check return PC on stack

module seq40_tb;

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

    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;

    // Simulated branch_target output (for JMP/JSR verification)
    logic        branch_taken;
    logic [31:0] branch_target;

    // -----------------------------------------------------------------------
    // Memory (256 longwords = 1 KB at addresses 0x000-0x3FF)
    // -----------------------------------------------------------------------
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    logic [31:0] ram [0:255];

    assign mem_ack   = mem_req;
    assign mem_berr  = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[9:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;

    // -----------------------------------------------------------------------
    // SSP / An ports
    // -----------------------------------------------------------------------
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 0;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    m68030_eu u_eu (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .instr_word    (instr_word),
        .instr_valid   (instr_valid),
        .ext_data      (ext_data),
        .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),
        .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en),
        .pc_wr_data    (pc_wr_data),
        .pc_out        (pc_out),
        .vbr_wr_en     (vbr_wr_en),
        .vbr_wr_data   (vbr_wr_data),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),
        .msp_out       (msp_out),
        .isp_out       (isp_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (32'h0000_1000),
        .branch_taken  (branch_taken),
        .branch_target (branch_target),
        .mem_req       (mem_req),
        .mem_rw        (mem_rw),
        .mem_siz       (mem_siz),
        .mem_fc        (mem_fc),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_rdata     (mem_rdata),
        .mem_ack       (mem_ack),
        .mem_berr      (mem_berr),
        .an_wr_en      (an_wr_en),
        .an_wr_sel     (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .ssp_wr_en     (ssp_wr_en),
        .ssp_wr_data   (ssp_wr_data),
        .exc_sr_wr_en  (1'b0),
        .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h  exp %08h", name, got, exp); fail_count++; end
    endtask

    // Run 1-word instruction (no extension)
    task run1(input logic [15:0] iw);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = 32'h0; ext_valid = 0;
        @(posedge clk_4x); #1;
        instr_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Run 2-word instruction (1 extension word in ext_data[15:0])
    task run2(input logic [15:0] iw, input logic [15:0] ext1);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1;
        ext_data   = {16'h0, ext1};   // seq.sv sends {16'h0, first_ext} for ext_count=1
        ext_valid  = 1;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Run 3-word instruction (2 extension words → ext_data = {ext1, ext2})
    task run3(input logic [15:0] iw, input logic [31:0] ext32);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1;
        ext_data   = ext32;
        ext_valid  = 1;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Set Dn via CLR.L + ADDI.L
    localparam [15:0] CLR_L_D0  = 16'h4280;
    localparam [15:0] ADDI_L_D0 = 16'h0680;

    task set_d0(input logic [31:0] val);
        run1(CLR_L_D0);
        run2(ADDI_L_D0, val[15:0]);   // only works for ≤16-bit values in these tests
    endtask

    // Set Dn register n (0-7) to val via CLR + ADDI
    task set_dn(input logic [2:0] n, input logic [31:0] val);
        logic [15:0] clr_enc, addi_enc;
        clr_enc  = {4'h4, 3'b010, 2'b10, 3'b000, n};
        addi_enc = {4'h0, 3'b110, 2'b10, 3'b000, n};
        run1(clr_enc);
        // ADDI.L #val, Dn — uses 2 extension words
        @(posedge clk_4x); #1;
        instr_word = addi_enc; instr_valid = 1;
        ext_data   = val;
        ext_valid  = 1;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // -----------------------------------------------------------------------
    // Instruction encoding helpers
    // -----------------------------------------------------------------------
    // MOVE.L Dn, (xxx).W  — 0010 dn 111 000 reg = group 2, dst_mode=111, dst_reg=000
    // MOVE.L Dn, (xxx).L  — 0010 dn 111 001 reg = group 2, dst_mode=111, dst_reg=001
    // encoding: {2'b00, 2'b10, dst_dn[2:0], 3'b111, src_mode[2:0], src_reg[2:0]}
    //   For MOVE.L: group=2 (10), but dst goes in [11:9],[8:6], src in [5:3],[2:0]
    //   Actually: opword = {group[3:0], dst_reg[2:0], dst_mode[2:0], src_mode[2:0], src_reg[2:0]}
    //   group = {size}: byte=0001, long=0010, word=0011
    //   MOVE.L Dn→(xxx).W:  {0010, 000, 111, 000, src_dn}
    //   MOVE.L Dn→(xxx).L:  {0010, 001, 111, 000, src_dn}
    function automatic [15:0] MOVE_L_DN_ABS_W(input logic [2:0] src_dn);
        MOVE_L_DN_ABS_W = {4'h2, 3'b000, 3'b111, 3'b000, src_dn};
    endfunction
    function automatic [15:0] MOVE_L_DN_ABS_L(input logic [2:0] src_dn);
        MOVE_L_DN_ABS_L = {4'h2, 3'b001, 3'b111, 3'b000, src_dn};
    endfunction

    // MOVE.L (xxx).W, Dn — {0010, dst_dn, 000, 111, 000}
    // MOVE.L (xxx).L, Dn — {0010, dst_dn, 000, 111, 001}
    function automatic [15:0] MOVE_L_ABS_W_DN(input logic [2:0] dst_dn);
        MOVE_L_ABS_W_DN = {4'h2, dst_dn, 3'b000, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] MOVE_L_ABS_L_DN(input logic [2:0] dst_dn);
        MOVE_L_ABS_L_DN = {4'h2, dst_dn, 3'b000, 3'b111, 3'b001};
    endfunction

    // MOVEA.L (xxx).W, An — group 2 (MOVE.L), dst_mode=001 (An), src=abs
    // {0010, an, 001, 111, 000}  abs.W
    // {0010, an, 001, 111, 001}  abs.L
    function automatic [15:0] MOVEA_L_ABS_W_AN(input logic [2:0] an);
        MOVEA_L_ABS_W_AN = {4'h2, an, 3'b001, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] MOVEA_L_ABS_L_AN(input logic [2:0] an);
        MOVEA_L_ABS_L_AN = {4'h2, an, 3'b001, 3'b111, 3'b001};
    endfunction

    // LEA (xxx).W, An — {0100, an, 111, 111, 000}  f_dir=1,f_ss=11,f_mode=111,f_reg=000
    // LEA (xxx).L, An — {0100, an, 111, 111, 001}  f_reg=001
    function automatic [15:0] LEA_ABS_W_AN(input logic [2:0] an);
        LEA_ABS_W_AN = {4'h4, an, 3'b111, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] LEA_ABS_L_AN(input logic [2:0] an);
        LEA_ABS_L_AN = {4'h4, an, 3'b111, 3'b111, 3'b001};
    endfunction

    // JMP (xxx).W/L — 0100_111_0_11_111_reg  (f_dn=111, f_dir=0, f_ss=11, f_mode=111)
    // Must include f_dir=0 explicitly to get full 16 bits: 0x4EF8 / 0x4EF9
    localparam [15:0] JMP_ABS_W = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b000};
    localparam [15:0] JMP_ABS_L = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b001};

    // JSR (xxx).W/L — 0100_111_0_10_111_reg  (f_ss=10)  0x4EB8 / 0x4EB9
    localparam [15:0] JSR_ABS_W = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b000};
    localparam [15:0] JSR_ABS_L = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b001};

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 40: Absolute EA (xxx).W / (xxx).L ===");

        // Reset
        repeat(3) @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P40-1: MOVE.L D0, (xxx).W  — write D0=0xDEAD_BEEF to address 0x0100
        // ===================================================================
        $display("--- P40-1: MOVE.L D0, (xxx).W [addr=0x100] ---");
        set_dn(3'd0, 32'hDEAD_BEEF);
        run2(MOVE_L_DN_ABS_W(3'd0), 16'h0100);
        // Allow extra settle cycle for memory write
        @(posedge clk_4x); #1;
        check32("P40-1: ram[0x100]", ram[32'h100>>2], 32'hDEAD_BEEF);

        // ===================================================================
        // P40-2: MOVE.L D1, (xxx).L  — write D1=0x1234_5678 to address 0x01FC
        // ===================================================================
        $display("--- P40-2: MOVE.L D1, (xxx).L [addr=0x1FC] ---");
        set_dn(3'd1, 32'h1234_5678);
        run3(MOVE_L_DN_ABS_L(3'd1), 32'h0000_01FC);
        @(posedge clk_4x); #1;
        check32("P40-2: ram[0x1FC]", ram[32'h1FC>>2], 32'h1234_5678);

        // ===================================================================
        // P40-3: MOVE.L (xxx).W, D2  — read from address 0x0100 into D2
        // ===================================================================
        $display("--- P40-3: MOVE.L (xxx).W, D2 [addr=0x100] ---");
        // ram[0x100>>2] should still have 0xDEAD_BEEF from P40-1
        run2(MOVE_L_ABS_W_DN(3'd2), 16'h0100);
        // WB commits on cycle after run2 — allow 2 extra cycles for regfile settle
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-3: D2 in regfile", u_eu.u_rf.d_reg[2], 32'hDEAD_BEEF);

        // ===================================================================
        // P40-4: MOVE.L (xxx).L, D3  — read from 0x01FC into D3
        // ===================================================================
        $display("--- P40-4: MOVE.L (xxx).L, D3 [addr=0x1FC] ---");
        run3(MOVE_L_ABS_L_DN(3'd3), 32'h0000_01FC);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-4: D3 in regfile", u_eu.u_rf.d_reg[3], 32'h1234_5678);

        // ===================================================================
        // P40-5: MOVEA.L (xxx).W, A1  — load abs short address into A1
        // ===================================================================
        $display("--- P40-5: MOVEA.L (xxx).W, A1 [reads from 0x100] ---");
        run2(MOVEA_L_ABS_W_AN(3'd1), 16'h0100);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-5: A1=0xDEAD_BEEF", u_eu.u_rf.a_reg[1], 32'hDEAD_BEEF);

        // ===================================================================
        // P40-6: MOVEA.L (xxx).L, A2  — load abs long address into A2
        // ===================================================================
        $display("--- P40-6: MOVEA.L (xxx).L, A2 [reads from 0x1FC] ---");
        run3(MOVEA_L_ABS_L_AN(3'd2), 32'h0000_01FC);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-6: A2=0x1234_5678", u_eu.u_rf.a_reg[2], 32'h1234_5678);

        // ===================================================================
        // P40-7: LEA (xxx).W, A3  — A3 ← 0x0100 (the address itself, not the contents)
        // ===================================================================
        $display("--- P40-7: LEA (xxx).W, A3 [addr=0x100] ---");
        run2(LEA_ABS_W_AN(3'd3), 16'h0100);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-7: A3=0x0100", u_eu.u_rf.a_reg[3], 32'h0000_0100);

        // ===================================================================
        // P40-8: LEA (xxx).L, A4  — A4 ← 0x0001FC00 (long abs address)
        // ===================================================================
        $display("--- P40-8: LEA (xxx).L, A4 [addr=0x1FC00] ---");
        run3(LEA_ABS_L_AN(3'd4), 32'h0001_FC00);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P40-8: A4=0x0001FC00", u_eu.u_rf.a_reg[4], 32'h0001_FC00);

        // ===================================================================
        // P40-9: JMP (xxx).W  — branch to absolute address 0x8000
        // branch_target goes valid the cycle JMP is in EX (one posedge after
        // the instruction is presented), so check it right then.
        // ===================================================================
        $display("--- P40-9: JMP (xxx).W [target=0x8000] ---");
        @(posedge clk_4x); #1;
        instr_word = JMP_ABS_W; instr_valid = 1;
        ext_data   = {16'h0, 16'h8000};
        ext_valid  = 1;
        @(posedge clk_4x); #1;   // JMP now in EX; branch_target combinatorially valid
        instr_valid = 0; ext_valid = 0;
        // abs.W sign-extends to 32 bits: 0x8000 → 0xFFFF8000
        check32("P40-9: branch_target=0xFFFF8000", branch_target, 32'hFFFF_8000);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P40-10: JSR (xxx).L  — push return PC and jump to absolute 0xABCD_0000
        //   A7 starts at 0x300, return PC = decode_pc+6 = 0x1006
        //   Push 0x1006 to M[0x2FC]; A7 → 0x2FC
        // JSR fires (branch_target valid, mem_req=1) in the EX cycle.
        // A7 update and ram write complete in the following cycle.
        // ===================================================================
        $display("--- P40-10: JSR (xxx).L [target=0xABCD_0000, retpc=0x1006] ---");
        // Set A7 = 0x300
        @(posedge clk_4x); #1;
        ssp_wr_data = 32'h0000_0300; ssp_wr_en = 1;
        @(posedge clk_4x); #1;
        ssp_wr_en = 0;
        @(posedge clk_4x); #1;

        @(posedge clk_4x); #1;
        instr_word = JSR_ABS_L; instr_valid = 1;
        ext_data   = 32'hABCD_0000;
        ext_valid  = 1;
        @(posedge clk_4x); #1;   // JSR now in EX: branch fires, mem_wdata = return PC
        instr_valid = 0; ext_valid = 0;
        check32("P40-10a: branch_target=0xABCD_0000", branch_target, 32'hABCD_0000);
        @(posedge clk_4x); #1;   // WB fires; ram model captures the write
        check32("P40-10c: M[0x2FC]=0x1006 (ret PC)",  ram[32'h2FC>>2], 32'h0000_1006);
        @(posedge clk_4x); #1;   // regfile write from WB commits
        check32("P40-10b: A7=0x2FC (stack pushed)",   isp_out,       32'h0000_02FC);

        // ===================================================================
        // Done
        // ===================================================================
        @(posedge clk_4x); #1;
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED");
        $finish;
    end

endmodule

`default_nettype wire

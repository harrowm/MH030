`default_nettype none
`timescale 1ps/1ps

// Phase 42 testbench: (d16,PC) and (d8,PC,Xn) PC-relative EA modes
//
// decode_pc = 0x0000 → PC base for EA = decode_pc + 2 = 0x0002
//
// P42-1: MOVE.L (8,PC), D0          d16=8   → EA = 2+8     = 0x000A
// P42-2: MOVE.L (−2,PC), D1         d16=−2  → EA = 2−2     = 0x0000
// P42-3: MOVEA.L (0x1E,PC), A2      d16=0x1E → EA = 2+0x1E = 0x0020
// P42-4: LEA (0x3E,PC), A3          d16=0x3E → A3 = 0x0040 (no read)
// P42-5: MOVE.L (4,PC,D1.L*1), D4   d8=4,D1=8     → EA = 2+4+8    = 0x000E
// P42-6: MOVE.L (0,PC,D2.W*4), D5   d8=0,D2.W=3,×4 → EA = 2+0+12  = 0x000E
// P42-7: LEA (6,PC,D3.L*1), A6      d8=6,D3=0x10  → A6 = 2+6+0x10 = 0x0018
// P42-8: JMP (0x100,PC)             → target = 2+0x100 = 0x0102
// P42-9: JMP (0,PC,D0.L*2)          D0=8,scale×2  → target = 2+16  = 0x0012
// P42-A: JSR (0x200,PC)             → target=0x0202, ret_pc=4; ISP: 0→0xFFFF_FFFC

module seq42_tb;

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
    logic        branch_taken;
    logic [31:0] branch_target;

    // -----------------------------------------------------------------------
    // Memory: 256 longwords (0x000–0x3FC) — EA base = 0x0002, so all EAs fit
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
        if (mem_req && !mem_rw) ram[mem_addr[9:2]] <= mem_wdata;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    m68030_eu u_eu (
        .clk_4x        (clk_4x),        .rst_n          (rst_n),
        .instr_word    (instr_word),     .instr_valid    (instr_valid),
        .ext_data      (ext_data),       .ext_valid      (ext_valid),
        .instr_ack     (instr_ack),      .eu_busy        (eu_busy),
        .pc_wr_en      (pc_wr_en),       .pc_wr_data     (pc_wr_data),
        .pc_out        (pc_out),
        .vbr_wr_en     (vbr_wr_en),      .vbr_wr_data    (vbr_wr_data),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),        .msp_out        (msp_out),
        .isp_out       (isp_out),
        .sr_out        (sr_out),         .supervisor     (supervisor),
        .master_mode   (master_mode),    .ipl_mask       (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (32'h0000_0000),  // PC base = 0x0000; EA base = 0x0002
        .branch_taken  (branch_taken),   .branch_target  (branch_target),
        .mem_req       (mem_req),        .mem_rw         (mem_rw),
        .mem_siz       (mem_siz),        .mem_fc         (mem_fc),
        .mem_addr      (mem_addr),       .mem_wdata      (mem_wdata),
        .mem_rdata     (mem_rdata),      .mem_ack        (mem_ack),
        .mem_berr      (mem_berr),
        .an_wr_en      (an_wr_en),       .an_wr_sel      (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .ssp_wr_en     (1'b0),           .ssp_wr_data    (32'h0),
        .exc_sr_wr_en  (1'b0),           .exc_sr_wr_data (16'h0)
    );

    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h  exp %08h", name, got, exp); fail_count++; end
    endtask

    // Present a 2-word instruction and wait for pipeline to flush
    task run2(input logic [15:0] iw, input logic [15:0] ext1);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = {16'h0, ext1}; ext_valid = 1;
        @(posedge clk_4x); #1; instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
    endtask

    // Set Dn = val via CLR.L + ADDI.L #val
    task set_dn(input logic [2:0] n, input logic [31:0] val);
        logic [15:0] clr_enc;
        logic [15:0] addi_enc;
        clr_enc  = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, n};  // CLR.L Dn = 0x4280+n
        addi_enc = {4'h0, 3'b110, 2'b10, 3'b000, n};         // ADDI.L #imm, Dn = 0x0680+n
        @(posedge clk_4x); #1;
        instr_word = clr_enc; instr_valid = 1; ext_data = 32'h0; ext_valid = 0;
        @(posedge clk_4x); #1; instr_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        instr_word = addi_enc; instr_valid = 1; ext_data = val; ext_valid = 1;
        @(posedge clk_4x); #1; instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
    endtask

    // -----------------------------------------------------------------------
    // Opcode functions
    // -----------------------------------------------------------------------

    // MOVE.L (d16,PC), Dn   : group2, dst=Dn(000), src=mode111, f_reg=010
    function automatic [15:0] MOVE_L_PC_D16(input logic [2:0] dst_dn);
        MOVE_L_PC_D16 = {4'h2, dst_dn, 3'b000, 3'b111, 3'b010};
    endfunction

    // MOVEA.L (d16,PC), An  : group2, dst=An(001), src=mode111, f_reg=010
    function automatic [15:0] MOVEA_L_PC_D16(input logic [2:0] dst_an);
        MOVEA_L_PC_D16 = {4'h2, dst_an, 3'b001, 3'b111, 3'b010};
    endfunction

    // LEA (d16,PC), An      : group4, f_dir=1, f_ss=11, f_mode=111, f_reg=010
    function automatic [15:0] LEA_PC_D16(input logic [2:0] dst_an);
        LEA_PC_D16 = {4'h4, dst_an, 3'b111, 3'b111, 3'b010};
    endfunction

    // MOVE.L (d8,PC,Xn), Dn : group2, dst=Dn(000), src=mode111, f_reg=011
    function automatic [15:0] MOVE_L_PC_IDX(input logic [2:0] dst_dn);
        MOVE_L_PC_IDX = {4'h2, dst_dn, 3'b000, 3'b111, 3'b011};
    endfunction

    // LEA (d8,PC,Xn), An    : group4, f_dir=1, f_ss=11, f_mode=111, f_reg=011
    function automatic [15:0] LEA_PC_IDX(input logic [2:0] dst_an);
        LEA_PC_IDX = {4'h4, dst_an, 3'b111, 3'b111, 3'b011};
    endfunction

    // JMP (d16,PC)  : 0x4EFA
    localparam [15:0] JMP_PC_D16 = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b010};
    // JMP (d8,PC,Xn): 0x4EFB
    localparam [15:0] JMP_PC_IDX = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b011};
    // JSR (d16,PC)  : 0x4EBA
    localparam [15:0] JSR_PC_D16 = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b010};

    // Brief ext word for (d8,PC,Xn): [15]=DA, [14:12]=Xn, [11]=WL, [10:9]=scale, [8]=0, [7:0]=d8
    function automatic [15:0] ext_idx(
        input logic       da,
        input logic [2:0] xn_reg,
        input logic       wl,
        input logic [1:0] scale,
        input logic [7:0] d8
    );
        ext_idx = {da, xn_reg, wl, scale, 1'b0, d8};
    endfunction

    // -----------------------------------------------------------------------
    // Main stimulus (decode_pc = 0, so PC base for EA = 0+2 = 2)
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 42: (d16,PC) and (d8,PC,Xn) PC-relative EA ===");
        $display("decode_pc=0x0000 → EA base = 0x0002");

        // Pre-fill RAM with sentinels at expected PC-relative addresses
        // P42-1: EA = 0x000A → ram[2]
        ram[32'h000A >> 2] = 32'hAABB_0001;
        // P42-2: EA = 0x0000 → ram[0]
        ram[32'h0000 >> 2] = 32'hAABB_0002;
        // P42-3: EA = 0x0020 → ram[8]
        ram[32'h0020 >> 2] = 32'hAABB_0003;
        // P42-5/6: EA = 0x000E → ram[3]
        ram[32'h000C >> 2] = 32'hAABB_0005;  // 0x000E >> 2 = 3 = 0x000C >> 2

        // Reset
        repeat(3) @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P42-1: MOVE.L (8,PC), D0
        //   EA = decode_pc + 2 + 8 = 0x000A
        //   D0 ← ram[0x000A>>2] = ram[2] = 0xAABB_0001
        // ===================================================================
        $display("--- P42-1: MOVE.L (8,PC), D0 ---");
        run2(MOVE_L_PC_D16(3'd0), 16'h0008);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-1: D0=0xAABB_0001", u_eu.u_rf.d_reg[0], 32'hAABB_0001);

        // ===================================================================
        // P42-2: MOVE.L (−2,PC), D1
        //   EA = 2 + (−2) = 0x0000
        //   D1 ← ram[0] = 0xAABB_0002
        // ===================================================================
        $display("--- P42-2: MOVE.L (-2,PC), D1 ---");
        run2(MOVE_L_PC_D16(3'd1), 16'hFFFE);  // d16 = -2 = 0xFFFE sign-extended
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-2: D1=0xAABB_0002", u_eu.u_rf.d_reg[1], 32'hAABB_0002);

        // ===================================================================
        // P42-3: MOVEA.L (0x1E,PC), A2
        //   EA = 2 + 0x1E = 0x0020
        //   A2 ← ram[8] = 0xAABB_0003
        // ===================================================================
        $display("--- P42-3: MOVEA.L (0x1E,PC), A2 ---");
        run2(MOVEA_L_PC_D16(3'd2), 16'h001E);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-3: A2=0xAABB_0003", u_eu.u_rf.a_reg[2], 32'hAABB_0003);

        // ===================================================================
        // P42-4: LEA (0x3E,PC), A3
        //   EA = 2 + 0x3E = 0x0040  (address computation only, no memory read)
        //   A3 = 0x0040
        // ===================================================================
        $display("--- P42-4: LEA (0x3E,PC), A3 ---");
        run2(LEA_PC_D16(3'd3), 16'h003E);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-4: A3=0x0040", u_eu.u_rf.a_reg[3], 32'h0000_0040);

        // ===================================================================
        // P42-5: MOVE.L (4,PC,D1.L*1), D4
        //   D1 contains 0xAABB_0002 from P42-2 — reset to D1=8 first
        //   d8=4, D1.L=8, scale×1 → Xn_scaled=8 → EA = 2+4+8 = 0x000E
        //   D4 ← ram[0x000E>>2] = ram[3] = 0xAABB_0005
        // ===================================================================
        $display("--- P42-5: MOVE.L (4,PC,D1.L*1), D4 ---");
        set_dn(3'd1, 32'd8);
        run2(MOVE_L_PC_IDX(3'd4), ext_idx(0, 3'd1, 1, 2'b00, 8'h04));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-5: D4=0xAABB_0005", u_eu.u_rf.d_reg[4], 32'hAABB_0005);

        // ===================================================================
        // P42-6: MOVE.L (0,PC,D2.W*4), D5
        //   D2=3; WL=0 (word → sign-ext to 32b=3), scale×4 → Xn_scaled=12
        //   EA = 2 + 0 + 12 = 0x000E
        //   D5 ← ram[3] = 0xAABB_0005
        // ===================================================================
        $display("--- P42-6: MOVE.L (0,PC,D2.W*4), D5 ---");
        set_dn(3'd2, 32'd3);
        run2(MOVE_L_PC_IDX(3'd5), ext_idx(0, 3'd2, 0, 2'b10, 8'h00));  // WL=0, scale=10(×4)
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-6: D5=0xAABB_0005", u_eu.u_rf.d_reg[5], 32'hAABB_0005);

        // ===================================================================
        // P42-7: LEA (6,PC,D3.L*1), A6
        //   D3=0x10; d8=6, scale×1 → EA = 2+6+0x10 = 0x0018  (no read)
        //   A6 = 0x0018
        // ===================================================================
        $display("--- P42-7: LEA (6,PC,D3.L*1), A6 ---");
        set_dn(3'd3, 32'h10);
        run2(LEA_PC_IDX(3'd6), ext_idx(0, 3'd3, 1, 2'b00, 8'h06));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P42-7: A6=0x0018", u_eu.u_rf.a_reg[6], 32'h0000_0018);

        // ===================================================================
        // P42-8: JMP (0x100,PC)
        //   branch_target = 2 + 0x100 = 0x0102
        //   Check combinatorially in EX cycle (posedge after instruction presented)
        // ===================================================================
        $display("--- P42-8: JMP (0x100,PC) ---");
        @(posedge clk_4x); #1;
        instr_word = JMP_PC_D16; instr_valid = 1;
        ext_data   = {16'h0, 16'h0100}; ext_valid = 1;
        @(posedge clk_4x); #1;   // EX cycle — branch_target valid
        instr_valid = 0; ext_valid = 0;
        check32("P42-8: branch_target=0x0102", branch_target, 32'h0000_0102);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;

        // ===================================================================
        // P42-9: JMP (0,PC,D0.L*2)
        //   D0 = 0xAABB_0001 from P42-1 — reset to D0=8
        //   EA = 2 + 0 + 8*2 = 0x0012
        // ===================================================================
        $display("--- P42-9: JMP (0,PC,D0.L*2) ---");
        set_dn(3'd0, 32'd8);
        @(posedge clk_4x); #1;
        instr_word = JMP_PC_IDX; instr_valid = 1;
        ext_data   = {16'h0, ext_idx(0, 3'd0, 1, 2'b01, 8'h00)};  // D0.L, scale×2
        ext_valid  = 1;
        @(posedge clk_4x); #1;   // EX cycle
        instr_valid = 0; ext_valid = 0;
        check32("P42-9: branch_target=0x0012", branch_target, 32'h0000_0012);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;

        // ===================================================================
        // P42-A: JSR (0x200,PC)
        //   branch_target = 2 + 0x200 = 0x0202
        //   return_pc = decode_pc + 4 = 0x0004 (pushed to -(ISP))
        //   ISP: 0 → 0xFFFF_FFFC
        //   Check branch_target in EX cycle, ISP 2 posedges later.
        // ===================================================================
        $display("--- P42-A: JSR (0x200,PC) ---");
        @(posedge clk_4x); #1;
        instr_word = JSR_PC_D16; instr_valid = 1;
        ext_data   = {16'h0, 16'h0200}; ext_valid = 1;
        @(posedge clk_4x); #1;   // EX cycle — branch_target combinatorial
        instr_valid = 0; ext_valid = 0;
        check32("P42-A branch_target=0x0202", branch_target, 32'h0000_0202);
        @(posedge clk_4x); #1;   // WB
        @(posedge clk_4x); #1;   // regfile written
        check32("P42-A ISP=0xFFFF_FFFC", isp_out, 32'hFFFF_FFFC);

        // ===================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

endmodule
`default_nettype wire

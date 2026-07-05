`default_nettype none
`timescale 1ps/1ps

// Phase 41 testbench: (d8,An,Xn) brief indexed EA
//   Extension word: [15]=DA, [14:12]=Xn_reg, [11]=WL, [10:9]=scale, [8]=0, [7:0]=d8
//
//   P41-1: MOVE.L (0,A0,D1.L*1), D2   — base load, no scale, long Xn
//   P41-2: MOVE.L (4,A0,D1.L*4), D3   — d8=4, scale×4, long Xn
//   P41-3: MOVE.L (0,A0,D1.W*2), D4   — word Xn, scale×2
//   P41-4: MOVE.L (-4,A0,D1.L*1), D5  — negative d8
//   P41-5: MOVEA.L (0,A1,D2.L*1), A3  — indexed load into An
//   P41-6: LEA (8,A2,D3.L*1), A4      — compute indexed address
//   P41-7: LEA (0,A0,D1.L*4), A5      — scale×4 address
//   P41-8: JMP (0,A6,D0.L*1)          — indexed branch target

module seq41_tb;

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
    // Memory (256 longwords)
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
    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 0;

    m68030_eu u_eu (
        .clk_4x        (clk_4x),       .rst_n         (rst_n),
        .instr_word    (instr_word),    .instr_valid   (instr_valid),
        .ext_data      (ext_data),      .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),     .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en),      .pc_wr_data    (pc_wr_data),
        .pc_out        (pc_out),
        .vbr_wr_en     (vbr_wr_en),     .vbr_wr_data   (vbr_wr_data),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),       .msp_out       (msp_out),
        .isp_out       (isp_out),
        .sr_out        (sr_out),        .supervisor    (supervisor),
        .master_mode   (master_mode),   .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (32'h0000_1000),
        .branch_taken  (branch_taken),  .branch_target (branch_target),
        .mem_req       (mem_req),       .mem_rw        (mem_rw),
        .mem_siz       (mem_siz),       .mem_fc        (mem_fc),
        .mem_addr      (mem_addr),      .mem_wdata     (mem_wdata),
        .mem_rdata     (mem_rdata),     .mem_ack       (mem_ack),
        .mem_berr      (mem_berr),
        .an_wr_en      (an_wr_en),      .an_wr_sel     (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .ssp_wr_en     (ssp_wr_en),     .ssp_wr_data   (ssp_wr_data),
        .exc_sr_wr_en  (1'b0),          .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h  exp %08h", name, got, exp); fail_count++; end
    endtask

    // Run 1-word instruction
    task run1(input logic [15:0] iw);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = 32'h0; ext_valid = 0;
        @(posedge clk_4x); #1; instr_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
    endtask

    // Run 2-word instruction (opcode + 1 ext word in low 16 bits of ext_data)
    task run2(input logic [15:0] iw, input logic [15:0] ext1);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = {16'h0, ext1}; ext_valid = 1;
        @(posedge clk_4x); #1; instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
    endtask

    // Load Dn with a 32-bit constant (via CLR.L + ADDI.L #val)
    task set_dn(input logic [2:0] n, input logic [31:0] val);
        logic [15:0] clr_enc, addi_enc;
        clr_enc  = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, n};  // CLR.L Dn = 0x4280+n
        addi_enc = {4'h0, 3'b110, 2'b10, 3'b000, n};
        run1(clr_enc);
        @(posedge clk_4x); #1;
        instr_word = addi_enc; instr_valid = 1; ext_data = val; ext_valid = 1;
        @(posedge clk_4x); #1; instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
    endtask

    // Load An with a constant via MOVEA.L (abs.L), An
    task set_an(input logic [2:0] n, input logic [31:0] val);
        // MOVEA.L (xxx).L, An: group2, dst=An(001), src=abs.L(111,001)
        logic [15:0] enc;
        enc = {4'h2, n, 3'b001, 3'b111, 3'b001};
        @(posedge clk_4x); #1;
        // Prime ram with val first so the abs load reads it
        ram[32'h0FC>>2] = val;
        instr_word = enc; instr_valid = 1; ext_data = 32'h0000_00FC; ext_valid = 1;
        @(posedge clk_4x); #1; instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        @(posedge clk_4x); #1; // extra settle
    endtask

    // -----------------------------------------------------------------------
    // Brief extension word builder
    //   DA=0→Dn, DA=1→An; WL=0→word, WL=1→long; scale: 00/01/10/11=1/2/4/8
    // -----------------------------------------------------------------------
    function automatic [15:0] ext_idx(
        input logic       da,       // 0=Dn, 1=An
        input logic [2:0] xn_reg,   // register number
        input logic       wl,       // 0=word, 1=long
        input logic [1:0] scale,    // 00=×1, 01=×2, 10=×4, 11=×8
        input logic [7:0] d8        // signed displacement
    );
        ext_idx = {da, xn_reg, wl, scale, 1'b0, d8};
    endfunction

    // MOVE.L (d8,An,Xn), Dn  — group2, dst=Dn(000), src_mode=110, src_reg=An
    function automatic [15:0] move_l_idx_dn(
        input logic [2:0] dst_dn,   // destination Dn
        input logic [2:0] base_an   // base An register
    );
        move_l_idx_dn = {4'h2, dst_dn, 3'b000, 3'b110, base_an};
    endfunction

    // MOVEA.L (d8,An,Xn), An — group2, dst=An(001), src_mode=110, src_reg=An
    function automatic [15:0] movea_l_idx_an(
        input logic [2:0] dst_an,   // destination An
        input logic [2:0] base_an   // base An register
    );
        movea_l_idx_an = {4'h2, dst_an, 3'b001, 3'b110, base_an};
    endfunction

    // LEA (d8,An,Xn), An — group4, f_dir=1,f_ss=11, f_mode=110, f_reg=base_an
    function automatic [15:0] lea_idx(
        input logic [2:0] dst_an,
        input logic [2:0] base_an
    );
        lea_idx = {4'h4, dst_an, 3'b111, 3'b110, base_an};
    endfunction

    // JMP (d8,An,Xn) — group4, f_dir=0,f_dn=111,f_ss=11, f_mode=110, f_reg=base_an
    function automatic [15:0] jmp_idx(input logic [2:0] base_an);
        jmp_idx = {4'h4, 3'b111, 1'b0, 2'b11, 3'b110, base_an};
    endfunction

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 41: (d8,An,Xn) Brief Indexed EA ===");

        // Reset
        repeat(3) @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // Pre-fill RAM with known pattern
        // ram[0x00>>2]=0, ram[0x04>>2]=1, ..., ram[n*4>>2]=0xAA00_0000+n
        begin
            int i;
            for (i = 0; i < 64; i++) ram[i] = 32'hAA00_0000 + i;
            // Place specific values we want to read
            ram[32'h010>>2] = 32'hDEAD_0001;  // at 0x010
            ram[32'h014>>2] = 32'hDEAD_0005;  // at 0x014
            ram[32'h018>>2] = 32'hDEAD_0006;  // at 0x018
            ram[32'h01C>>2] = 32'hDEAD_000C;  // at 0x01C (for -4 test)
            ram[32'h040>>2] = 32'h1234_5678;  // for P41-6 LEA value
        end

        // ===================================================================
        // P41-1: MOVE.L (0,A0,D1.L*1), D2
        //   A0=0x010, D1=0, d8=0, WL=1 (long), scale=×1
        //   EA = 0x010 + 0 + 0*1 = 0x010; D2 ← ram[0x010>>2] = 0xDEAD_0001
        // ===================================================================
        $display("--- P41-1: MOVE.L (0,A0,D1.L*1), D2 ---");
        set_an(3'd0, 32'h0000_0010);
        set_dn(3'd1, 32'h0000_0000);

        run2(move_l_idx_dn(3'd2, 3'd0), ext_idx(0, 3'd1, 1, 2'b00, 8'h00));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-1: D2=0xDEAD_0001", u_eu.u_rf.d_reg[2], 32'hDEAD_0001);

        // ===================================================================
        // P41-2: MOVE.L (4,A0,D1.L*4), D3
        //   A0=0x000, D1=5, d8=4, WL=1, scale=×4
        //   EA = 0x000 + 4 + 5*4 = 0x018; D3 ← ram[0x018>>2] = 0xDEAD_0006
        // ===================================================================
        $display("--- P41-2: MOVE.L (4,A0,D1.L*4), D3 ---");
        set_an(3'd0, 32'h0000_0000);
        set_dn(3'd1, 32'h0000_0005);

        run2(move_l_idx_dn(3'd3, 3'd0), ext_idx(0, 3'd1, 1, 2'b10, 8'h04));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-2: D3=0xDEAD_0006", u_eu.u_rf.d_reg[3], 32'hDEAD_0006);

        // ===================================================================
        // P41-3: MOVE.L (0,A0,D1.W*2), D4
        //   A0=0x010, D1=0x0001_0002 (word part = 0x0002), d8=0, WL=0 (word), scale=×2
        //   WL=0: use sign_ext(D1[15:0]) = 0x0002 → EA = 0x010 + 0 + 2*2 = 0x014
        //   D4 ← ram[0x014>>2] = 0xDEAD_0005
        // ===================================================================
        $display("--- P41-3: MOVE.L (0,A0,D1.W*2), D4 ---");
        set_an(3'd0, 32'h0000_0010);
        set_dn(3'd1, 32'h0001_0002);  // upper half is 0x0001, lower 0x0002

        run2(move_l_idx_dn(3'd4, 3'd0), ext_idx(0, 3'd1, 0, 2'b01, 8'h00));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-3: D4=0xDEAD_0005", u_eu.u_rf.d_reg[4], 32'hDEAD_0005);

        // ===================================================================
        // P41-4: MOVE.L (-4,A0,D1.L*1), D5
        //   A0=0x020, D1=0, d8=-4 (0xFC), WL=1, scale=×1
        //   EA = 0x020 + (-4) + 0 = 0x01C; D5 ← ram[0x01C>>2] = 0xDEAD_000C
        // ===================================================================
        $display("--- P41-4: MOVE.L (-4,A0,D1.L*1), D5 ---");
        set_an(3'd0, 32'h0000_0020);
        set_dn(3'd1, 32'h0000_0000);

        run2(move_l_idx_dn(3'd5, 3'd0), ext_idx(0, 3'd1, 1, 2'b00, 8'hFC));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-4: D5=0xDEAD_000C", u_eu.u_rf.d_reg[5], 32'hDEAD_000C);

        // ===================================================================
        // P41-5: MOVEA.L (0,A1,D2.L*1), A3
        //   A1=0x010, D2=4, d8=0, WL=1, scale=×1
        //   EA = 0x010 + 0 + 4 = 0x014; A3 ← ram[0x014>>2] = 0xDEAD_0005
        // ===================================================================
        $display("--- P41-5: MOVEA.L (0,A1,D2.L*1), A3 ---");
        set_an(3'd1, 32'h0000_0010);
        set_dn(3'd2, 32'h0000_0004);

        run2(movea_l_idx_an(3'd3, 3'd1), ext_idx(0, 3'd2, 1, 2'b00, 8'h00));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-5: A3=0xDEAD_0005", u_eu.u_rf.a_reg[3], 32'hDEAD_0005);

        // ===================================================================
        // P41-6: LEA (8,A2,D3.L*1), A4
        //   A2=0x030, D3=8, d8=8, WL=1, scale=×1
        //   EA = 0x030 + 8 + 8 = 0x040; A4 ← 0x040 (not the memory contents)
        // ===================================================================
        $display("--- P41-6: LEA (8,A2,D3.L*1), A4 ---");
        set_an(3'd2, 32'h0000_0030);
        set_dn(3'd3, 32'h0000_0008);

        run2(lea_idx(3'd4, 3'd2), ext_idx(0, 3'd3, 1, 2'b00, 8'h08));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-6: A4=0x040 (address, not contents)", u_eu.u_rf.a_reg[4], 32'h0000_0040);

        // ===================================================================
        // P41-7: LEA (0,A0,D1.L*4), A5
        //   A0=0x000, D1=4, d8=0, WL=1, scale=×4
        //   EA = 0x000 + 0 + 4*4 = 0x010; A5 ← 0x010
        // ===================================================================
        $display("--- P41-7: LEA (0,A0,D1.L*4), A5 ---");
        set_an(3'd0, 32'h0000_0000);
        set_dn(3'd1, 32'h0000_0004);

        run2(lea_idx(3'd5, 3'd0), ext_idx(0, 3'd1, 1, 2'b10, 8'h00));
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        check32("P41-7: A5=0x010", u_eu.u_rf.a_reg[5], 32'h0000_0010);

        // ===================================================================
        // P41-8: JMP (0,A6,D0.L*1)
        //   A6=0x5000, D0=0x100, d8=0, WL=1, scale=×1
        //   branch_target = 0x5000 + 0 + 0x100 = 0x5100
        //   Check branch_target in the EX cycle (one posedge after presentation)
        // ===================================================================
        $display("--- P41-8: JMP (0,A6,D0.L*1) ---");
        set_an(3'd6, 32'h0000_5000);
        set_dn(3'd0, 32'h0000_0100);

        @(posedge clk_4x); #1;
        instr_word = jmp_idx(3'd6); instr_valid = 1;
        ext_data   = {16'h0, ext_idx(0, 3'd0, 1, 2'b00, 8'h00)};
        ext_valid  = 1;
        @(posedge clk_4x); #1;   // JMP now in EX; branch_target valid
        instr_valid = 0; ext_valid = 0;
        check32("P41-8: branch_target=0x5100", branch_target, 32'h0000_5100);
        @(posedge clk_4x); #1; @(posedge clk_4x); #1;

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

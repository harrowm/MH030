`default_nettype none
`timescale 1ps/1ps

// Phase 39 testbench: LINK and UNLK
//   P39-1: LINK A2, #-16  — push A2, set frame pointer, allocate locals
//   P39-2: UNLK A2        — restore A2 and A7 from frame pointer
//   P39-3: round-trip     — LINK then UNLK restores original register state
//   P39-4: LINK A5, #0    — zero displacement (An = A7-4, A7 unchanged -4)
//   P39-5: nested LINK    — two consecutive LINK calls

module seq39_tb;

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
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;

    // -----------------------------------------------------------------------
    // An write / SSP ports
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
        .branch_taken  (),
        .branch_target (),
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

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h  exp %08h", name, got, exp); fail_count++; end
    endtask

    // Present instruction for 1 cycle then drain 3 more for EX+WB+settle
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Set D0 via CLR.L D0 + ADDI.L #val,D0
    localparam [15:0] CLR_L_D0  = 16'h4280;
    localparam [15:0] ADDI_L_D0 = 16'h0680;

    task set_d0(input logic [31:0] val);
        run(CLR_L_D0,  32'h0, 1'b0);
        run(ADDI_L_D0, val,   1'b1);
    endtask

    // Set An via MOVEA.L D0,An (after set_d0)
    logic [15:0] movea_enc_tmp;
    task set_an(input logic [2:0] an, input logic [31:0] val);
        movea_enc_tmp = {4'h2, an, 3'b001, 3'b000, 3'b000};
        set_d0(val);
        run(movea_enc_tmp, 32'h0, 1'b0);
    endtask

    // Set ISP (supervisor A7) directly
    task set_isp(input logic [31:0] val);
        @(posedge clk_4x); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk_4x); #1;
        ssp_wr_en = 0;
        @(posedge clk_4x); #1;
    endtask

    // Instruction encodings
    // LINK.W An: 0x4E50 + n
    // UNLK  An: 0x4E58 + n
    function automatic [15:0] LINK_W(input logic [2:0] n);
        LINK_W = 16'h4E50 | {13'h0, n};
    endfunction
    function automatic [15:0] UNLK(input logic [2:0] n);
        UNLK = 16'h4E58 | {13'h0, n};
    endfunction

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 39: LINK / UNLK ===");

        // Reset
        repeat(3) @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P39-1: LINK A2, #-16
        //   A7=0x300, A2=0xABCD_1234
        //   After LINK: M[0x2FC] = 0xABCD_1234, A2=0x2FC, A7=0x2EC
        // ===================================================================
        $display("--- P39-1: LINK A2, #-16 ---");
        set_isp(32'h0000_0300);
        set_an(3'b010, 32'hABCD_1234);

        // LINK.W A2, #-16: opcode=0x4E52, ext=0xFFF0 (-16 signed)
        run(LINK_W(3'b010), {16'h0, 16'hFFF0}, 1'b1);

        // M[0x2FC] should contain the old A2 value
        check32("P39-1a: M[0x2FC]=old_A2", ram[32'h2FC>>2], 32'hABCD_1234);
        // A2 should now be the frame pointer = A7-4 = 0x300-4 = 0x2FC
        check32("P39-1b: A2=0x2FC (frame ptr)", u_eu.u_rf.a_reg[2], 32'h0000_02FC);
        // A7 should be frame_ptr + d16 = 0x2FC + (-16) = 0x2EC
        check32("P39-1c: A7=0x2EC", isp_out, 32'h0000_02EC);

        // ===================================================================
        // P39-2: UNLK A2 (continuation from P39-1 state)
        //   A7=0x2EC, A2=0x2FC, M[0x2FC]=0xABCD_1234
        //   After UNLK: A2=0xABCD_1234, A7=0x2FC+4=0x300
        // ===================================================================
        $display("--- P39-2: UNLK A2 ---");

        run(UNLK(3'b010), 32'h0, 1'b0);

        // A2 should be restored to old value from stack
        check32("P39-2a: A2=0xABCD_1234 (restored)", u_eu.u_rf.a_reg[2], 32'hABCD_1234);
        // A7 should be A2_before_unlk + 4 = 0x2FC + 4 = 0x300
        check32("P39-2b: A7=0x300 (restored)", isp_out, 32'h0000_0300);

        // ===================================================================
        // P39-3: Round-trip verification
        //   After LINK A2 + UNLK A2, both A2 and A7 should be back to initial
        // ===================================================================
        $display("--- P39-3: Round-trip (LINK A5 then UNLK A5) ---");
        set_isp(32'h0000_0400);
        set_an(3'b101, 32'h0000_CAFE);

        // LINK.W A5, #-32 (allocate 32 bytes)
        run(LINK_W(3'b101), {16'h0, 16'hFFE0}, 1'b1);
        check32("P39-3a: M[0x3FC]=old_A5", ram[32'h3FC>>2], 32'h0000_CAFE);
        check32("P39-3b: A5=0x3FC",         u_eu.u_rf.a_reg[5], 32'h0000_03FC);
        check32("P39-3c: A7=0x3DC",         isp_out, 32'h0000_03DC);  // 0x3FC+(-32)=0x3DC

        // UNLK A5
        run(UNLK(3'b101), 32'h0, 1'b0);
        check32("P39-3d: A5 restored",       u_eu.u_rf.a_reg[5], 32'h0000_CAFE);
        check32("P39-3e: A7 restored=0x400", isp_out, 32'h0000_0400);

        // ===================================================================
        // P39-4: LINK A0, #0 — zero displacement
        //   A7=0x200, A0=0x1111_2222
        //   After: M[0x1FC]=0x1111_2222, A0=0x1FC, A7=0x1FC+0=0x1FC
        // ===================================================================
        $display("--- P39-4: LINK A0, #0 (zero displacement) ---");
        set_isp(32'h0000_0200);
        set_an(3'b000, 32'h1111_2222);

        run(LINK_W(3'b000), {16'h0, 16'h0000}, 1'b1);

        check32("P39-4a: M[0x1FC]=0x1111_2222", ram[32'h1FC>>2], 32'h1111_2222);
        check32("P39-4b: A0=0x1FC",              u_eu.u_rf.a_reg[0], 32'h0000_01FC);
        // A7 = 0x1FC + 0 = 0x1FC (same as frame pointer)
        check32("P39-4c: A7=0x1FC",              isp_out, 32'h0000_01FC);

        // Restore with UNLK A0
        run(UNLK(3'b000), 32'h0, 1'b0);
        check32("P39-4d: A0 restored",           u_eu.u_rf.a_reg[0], 32'h1111_2222);
        check32("P39-4e: A7 restored=0x200",      isp_out, 32'h0000_0200);

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

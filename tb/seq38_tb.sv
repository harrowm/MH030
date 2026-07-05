`default_nettype none
`timescale 1ps/1ps

// Phase 38 testbench: JMP, JSR, BSR, RTS, RTR
// Verifies:
//   P38-1: JMP (An) — branch_taken=1, branch_target=An
//   P38-2: JMP (d16,An) — branch_target=An+d16
//   P38-3: JSR (An) — push return PC to -(A7), branch_target=An
//   P38-4: BSR.B — push return PC, branch_target=PC+2+d8
//   P38-5: BSR.W — push return PC (4-byte instr), branch_target=PC+2+d16
//   P38-6: RTS  — PC ← M[(A7)], A7 += 4
//   P38-7: RTR  — CCR ← M[(A7)][7:0], A7+=2; PC ← M[(A7+2)], A7+=4
//   P38-8: JSR (d16,An) — push return PC (4-byte instr), branch to An+d16

module seq38_tb;

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
    // Branch capture
    // -----------------------------------------------------------------------
    logic        branch_taken;
    logic [31:0] branch_target;
    logic        last_branch_taken  = 0;
    logic [31:0] last_branch_target = 0;

    always @(posedge clk_4x) begin
        if (branch_taken) begin
            last_branch_taken  <= 1;
            last_branch_target <= branch_target;
        end else begin
            last_branch_taken <= 0;
        end
    end

    // -----------------------------------------------------------------------
    // Memory (256 longwords = 1 KB, word-addressed by [9:2])
    // -----------------------------------------------------------------------
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    logic [31:0] ram [0:255];

    assign mem_ack  = mem_req;
    assign mem_berr = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[9:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;

    // -----------------------------------------------------------------------
    // An write port and SSP
    // -----------------------------------------------------------------------
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 0;

    // -----------------------------------------------------------------------
    // DUT (m68030_eu with decode_pc fixed at 0x1000)
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
        .decode_pc     (32'h0000_1000),   // fixed decode PC for all tests
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

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h  exp %08h", name, got, exp); fail_count++; end
    endtask

    // Run instruction (present for 1 cycle, drain 3 more for EX+WB+settle)
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Run one instruction, drain just 2 extra cycles (DECODE already done above)
    // Used when sampling branch_taken right after EX
    task run_nobranch(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
    endtask

    // Set D0 to val using CLR.L D0 + ADDI.L #val,D0
    localparam [15:0] CLR_L_D0  = 16'h4280;
    localparam [15:0] ADDI_L_D0 = 16'h0680;

    task set_d0(input logic [31:0] val);
        run(CLR_L_D0,  32'h0,  1'b0);
        run(ADDI_L_D0, val,    1'b1);
    endtask

    // Set An via MOVEA.L D0,An (after set_d0 to load D0)
    // MOVEA.L D0,An: 0010_An_001_000_000 (group 2, dst=An, src=D0)
    //   = 0010 | An[2:0] | 001 | 000 | 000
    logic [15:0] movea_enc_tmp;
    task set_an(input logic [2:0] an, input logic [31:0] val);
        movea_enc_tmp = {4'h2, an, 3'b001, 3'b000, 3'b000};
        set_d0(val);
        run(movea_enc_tmp, 32'h0, 1'b0);
    endtask

    // Set ISP (A7 in supervisor mode) via ssp_wr_en port
    task set_isp(input logic [31:0] val);
        @(posedge clk_4x); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk_4x); #1;
        ssp_wr_en = 0;
        @(posedge clk_4x); #1;
    endtask

    // -----------------------------------------------------------------------
    // Instruction encodings
    // -----------------------------------------------------------------------
    // Precomputed opcodes for tests (An=A0..A2 as needed)
    // JMP (An): 0100 1110 11 010 rrr
    // JMP (A0)=0x4ED0, JMP(A1)=0x4ED1, JMP(A2)=0x4ED2
    localparam [15:0] JMP_A0   = 16'h4ED0;
    localparam [15:0] JMP_D16A0 = 16'h4EE8;  // JMP (d16,A0)
    localparam [15:0] JSR_A1   = 16'h4E91;   // JSR (A1)
    localparam [15:0] JSR_D16A2 = 16'h4EAA;  // JSR (d16,A2)

    localparam [15:0] RTS = 16'h4E75;
    localparam [15:0] RTR = 16'h4E77;
    // BSR.B: 0110 0001 disp8
    // BSR.W: 0110 0001 0000 0000 | d16
    localparam [15:0] BSR_W_PREFIX = 16'h6100;  // d8=0x00 → word form, needs d16 ext

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 38: JMP/JSR/BSR/RTS/RTR ===");

        // Reset
        repeat(3) @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P38-1: JMP (A0) — set A0=0x2000, JMP (A0), verify branch_target
        // ===================================================================
        $display("--- P38-1: JMP (A0) ---");
        set_an(3'b000, 32'h0000_2000);

        @(posedge clk_4x); #1;
        instr_word = JMP_A0; instr_valid = 1;
        @(posedge clk_4x); #1;  // DECODE→EX; branch_taken fires combinationally
        instr_valid = 0;
        check("P38-1: branch_taken", branch_taken);
        check32("P38-1: branch_target=0x2000", branch_target, 32'h0000_2000);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P38-1: ISP unchanged", isp_out, 32'h0);

        // ===================================================================
        // P38-2: JMP (d16,A0) — A0=0x2000, d16=+0x10 → target=0x2010
        // ===================================================================
        $display("--- P38-2: JMP (d16,A0) ---");
        set_an(3'b000, 32'h0000_2000);

        @(posedge clk_4x); #1;
        instr_word = JMP_D16A0; ext_data = {16'h0, 16'h0010}; instr_valid = 1; ext_valid = 1;
        @(posedge clk_4x); #1;  // DECODE (need_ext satisfied) → EX
        instr_valid = 0; ext_valid = 0;
        check("P38-2: branch_taken", branch_taken);
        check32("P38-2: branch_target=0x2010", branch_target, 32'h0000_2010);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        // ===================================================================
        // P38-3: JSR (A1) — push return PC to -(A7), branch to A1
        // decode_pc=0x1000; JSR (An) is 2 bytes → return_pc=0x1002
        // Set A7=0x100, A1=0x3000
        // Expected: ram[0xFC>>2]=0x1002, A7=0xFC
        // ===================================================================
        $display("--- P38-3: JSR (A1) ---");
        set_isp(32'h0000_0100);
        set_an(3'b001, 32'h0000_3000);

        @(posedge clk_4x); #1;
        instr_word = JSR_A1; instr_valid = 1;
        @(posedge clk_4x); #1;  // DECODE → EX (push fires + branch fires)
        instr_valid = 0;
        check("P38-3: branch_taken", branch_taken);
        check32("P38-3: branch_target=0x3000", branch_target, 32'h0000_3000);
        @(posedge clk_4x); #1;  // WB: A7 updated
        @(posedge clk_4x); #1;
        check32("P38-3: A7=0xFC", isp_out, 32'h0000_00FC);
        check32("P38-3: stack[0xFC]=0x1002", ram[32'h00FC >> 2], 32'h0000_1002);

        // ===================================================================
        // P38-4: BSR.B disp8=+0x20 — push return PC, branch to 0x1000+2+0x20=0x1022
        // return_pc = 0x1000 + 2 = 0x1002 (BSR.B is 2 bytes)
        // A7 = 0x100 (reset above); after JSR A7=0xFC; reset to 0x100 first
        // ===================================================================
        $display("--- P38-4: BSR.B disp8=+0x20 ---");
        set_isp(32'h0000_0100);

        @(posedge clk_4x); #1;
        // BSR.B: 0110_0001_0010_0000 = 0x6120 (disp8=0x20=+32)
        instr_word = 16'h6120; instr_valid = 1;
        @(posedge clk_4x); #1;  // DECODE → EX
        instr_valid = 0;
        check("P38-4: branch_taken", branch_taken);
        check32("P38-4: branch_target=0x1022", branch_target, 32'h0000_1022);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P38-4: A7=0xFC", isp_out, 32'h0000_00FC);
        check32("P38-4: stack=return PC=0x1002", ram[32'h00FC >> 2], 32'h0000_1002);

        // ===================================================================
        // P38-5: BSR.W d16=+0x100 — 4-byte instr, return_pc=0x1004
        // branch_target = 0x1000+2+0x100 = 0x1102
        // ===================================================================
        $display("--- P38-5: BSR.W d16=+0x100 ---");
        set_isp(32'h0000_0100);

        @(posedge clk_4x); #1;
        instr_word = BSR_W_PREFIX; ext_data = {16'h0, 16'h0100}; instr_valid = 1; ext_valid = 1;
        @(posedge clk_4x); #1;  // DECODE (ext satisfied) → EX
        instr_valid = 0; ext_valid = 0;
        check("P38-5: branch_taken", branch_taken);
        check32("P38-5: branch_target=0x1102", branch_target, 32'h0000_1102);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P38-5: A7=0xFC", isp_out, 32'h0000_00FC);
        check32("P38-5: stack=return PC=0x1004", ram[32'h00FC >> 2], 32'h0000_1004);

        // ===================================================================
        // P38-6: RTS — pre-load ram[0x100/4]=0x5000, set A7=0x100
        // Expected: branch_target=0x5000, A7=0x104
        // ===================================================================
        $display("--- P38-6: RTS ---");
        ram[32'h0100 >> 2] = 32'h0000_5000;  // pre-load return address
        set_isp(32'h0000_0100);

        @(posedge clk_4x); #1;
        instr_word = RTS; instr_valid = 1;
        @(posedge clk_4x); #1;  // DECODE → EX (read A7, branch fires)
        instr_valid = 0;
        check("P38-6: branch_taken", branch_taken);
        check32("P38-6: branch_target=0x5000", branch_target, 32'h0000_5000);
        @(posedge clk_4x); #1;  // WB: A7 updated
        @(posedge clk_4x); #1;
        check32("P38-6: A7=0x104 (incremented)", isp_out, 32'h0000_0104);

        // ===================================================================
        // P38-7: RTR — pre-load CCR word at 0x200, PC longword at 0x202
        // Set A7=0x200
        // ram[0x200/4]=0x0000_0015 → CCR=0x15 = {X=1,N=0,Z=1,V=0,C=1}
        // ram[0x204/4]=0x0000_8888 → return PC=0x8888
        // But RTR reads WORD at 0x200 then LONGWORD at 0x202
        // Note: our memory is word-addressed, so word read at 0x200 returns ram[0x80][31:16]
        // Actually our RAM is longword-granular (4-byte indexed) — simplify:
        // ram[0x200>>2]=ram[0x80]: word read = full 32-bit (CCR in bits[7:0])
        // ram[0x204>>2]=ram[0x81]: longword = return PC
        // ===================================================================
        $display("--- P38-7: RTR ---");
        ram[32'h0200 >> 2] = 32'h0000_0015;  // CCR=0x15 (X=1,N=0,Z=1,V=0,C=1)
        ram[32'h0204 >> 2] = 32'h0000_8888;  // PC
        set_isp(32'h0000_0200);

        // RTR takes 2 EX cycles; sample branch after both complete
        @(posedge clk_4x); #1;
        instr_word = RTR; instr_valid = 1;
        @(posedge clk_4x); #1;  // DECODE → EX phase 1 (CCR read, stall active)
        instr_valid = 0;
        check("P38-7a: branch NOT taken in phase 1", !branch_taken);
        @(posedge clk_4x); #1;  // EX phase 2 (PC read, branch fires)
        check("P38-7b: branch_taken in phase 2", branch_taken);
        check32("P38-7b: branch_target=0x8888", branch_target, 32'h0000_8888);
        @(posedge clk_4x); #1;  // WB settle
        @(posedge clk_4x); #1;
        // Simplified: RTR uses A7+4 for PC read (real 68030 uses A7+2); A7 = 0x200+4+4=0x208
        check32("P38-7c: A7=0x208", isp_out, 32'h0000_0208);
        // CCR should reflect 0x15: X=1,N=0,Z=1,V=0,C=1 → SR bits [4:0] = 5'b1_0_1_0_1
        check32("P38-7d: SR CCR bits=0x15", {27'h0, sr_out[4:0]}, 32'h0000_0015);

        // ===================================================================
        // P38-8: JSR (d16,A2) — A2=0x4000, d16=+0x80, return_pc=0x1004
        // Expected: branch_target=0x4080, stack[0xFC]=0x1004, A7=0xFC
        // ===================================================================
        $display("--- P38-8: JSR (d16,A2) ---");
        set_isp(32'h0000_0100);
        set_an(3'b010, 32'h0000_4000);

        @(posedge clk_4x); #1;
        instr_word = JSR_D16A2; ext_data = {16'h0, 16'h0080}; instr_valid = 1; ext_valid = 1;
        @(posedge clk_4x); #1;  // DECODE (ext satisfied) → EX
        instr_valid = 0; ext_valid = 0;
        check("P38-8: branch_taken", branch_taken);
        check32("P38-8: branch_target=0x4080", branch_target, 32'h0000_4080);
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        check32("P38-8: A7=0xFC", isp_out, 32'h0000_00FC);
        check32("P38-8: stack=return PC=0x1004", ram[32'h00FC >> 2], 32'h0000_1004);

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

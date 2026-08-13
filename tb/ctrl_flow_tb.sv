`default_nettype none
`timescale 1ns/1ps

// Control-flow instruction testbench
// Covers: NOP, MOVEQ, ADDQ/SUBQ, SWAP, EXT/EXTB, Scc, DBcc, Bcc, MOVE.L
//         JMP/JSR/BSR/RTS/RTR, LINK.W/UNLK, PEA/EXG/RTD/CMPM

module ctrl_flow_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk);
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word  = 16'h4E71;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 32'h0;
    logic        ext_valid   = 0;
    logic        instr_ack;
    logic        eu_busy;

    logic        pc_wr_en    = 0;
    logic [31:0] pc_wr_data  = 32'h0;
    logic [31:0] pc_out;
    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 32'h0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic [31:0] decode_pc = 32'h0000_1000;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
    logic        mem_berr   = 0;
    logic        mem_rmw;

    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack  = 0;
    logic        eu_coproc_berr = 0;
    logic [31:0] eu_coproc_rdata= 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack   = 0;
    logic [15:0] eu_ptest_mmusr = 16'h0;
    logic [31:0] tc_out, tt0_out, tt1_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x         (clk),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .q3_word        (16'h0),
        .ext34_data     (32'h0),
        .ext_valid      (ext_valid),
        .instr_ack      (instr_ack),
        .eu_busy        (eu_busy),
        .pc_wr_en       (pc_wr_en),
        .pc_wr_data     (pc_wr_data),
        .pc_out         (pc_out),
        .vbr_wr_en      (vbr_wr_en),
        .vbr_wr_data    (vbr_wr_data),
        .vbr_out        (vbr_out),
        .usp_out        (usp_out),
        .msp_out        (msp_out),
        .isp_out        (isp_out),
        .cacr_out       (cacr_out),
        .caar_out       (caar_out),
        .sr_out         (sr_out),
        .supervisor     (supervisor),
        .master_mode    (master_mode),
        .ipl_mask       (ipl_mask),
        .int_pending    (1'b0),
        .eu_int_ready   (),
        .exc_active     (1'b0),
        .decode_pc      (decode_pc),
        .branch_taken   (branch_taken),
        .branch_target  (branch_target),
        .mem_req        (mem_req),
        .mem_rw         (mem_rw),
        .mem_siz        (mem_siz),
        .mem_fc         (mem_fc),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_rdata      (mem_rdata),
        .mem_ack        (mem_ack),
        .mem_berr       (mem_berr),
        .mem_rmw        (mem_rmw),
        .eu_coproc_req  (eu_coproc_req),
        .eu_coproc_rw   (eu_coproc_rw),
        .eu_coproc_siz  (eu_coproc_siz),
        .eu_coproc_fc   (eu_coproc_fc),
        .eu_coproc_addr (eu_coproc_addr),
        .eu_coproc_wdata(eu_coproc_wdata),
        .eu_coproc_rdata(eu_coproc_rdata),
        .eu_coproc_ack  (eu_coproc_ack),
        .eu_coproc_berr (eu_coproc_berr),
        .eu_pflush_req  (eu_pflush_req),
        .eu_pflush_all  (eu_pflush_all),
        .eu_pflush_fc   (eu_pflush_fc),
        .eu_pflush_va   (eu_pflush_va),
        .eu_pflush_ack  (eu_pflush_ack),
        .eu_ptest_req   (eu_ptest_req),
        .eu_ptest_va    (eu_ptest_va),
        .eu_ptest_fc    (eu_ptest_fc),
        .eu_ptest_ack   (eu_ptest_ack),
        .eu_ptest_mmusr (eu_ptest_mmusr),
        .tc_out         (tc_out),
        .tt0_out        (tt0_out),
        .tt1_out        (tt1_out),
        .an_wr_en       (an_wr_en),
        .an_wr_sel      (an_wr_sel),
        .an_wr_data     (an_wr_data),
        .div_trap       (div_trap),
        .chk_trap       (chk_trap),
        .eu_trap_req    (eu_trap_req),
        .eu_trap_num    (eu_trap_num),
        .eu_trapv_req   (eu_trapv_req),
        .eu_illegal_req (eu_illegal_req),
        .eu_stop        (eu_stop),
        .ssp_wr_en      (ssp_wr_en),
        .ssp_wr_data    (ssp_wr_data),
        .exc_sr_wr_en   (exc_sr_wr_en),
        .exc_sr_wr_data (exc_sr_wr_data)
    );

    // ─── Memory model: 256-entry 32-bit RAM, word-addressed ──────────────────
    logic [31:0] ram [0:255];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[9:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;
    end

    // Latch branch_taken so it can be checked after drain cycles.
    logic saw_branch;
    logic [31:0] last_target;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_branch  <= 1'b0;
            last_target <= 32'h0;
        end else if (branch_taken) begin
            saw_branch  <= 1'b1;
            last_target <= branch_target;
        end
    end

    // ─── Instruction encodings ────────────────────────────────────────────────
    localparam [15:0] NOP         = 16'h4E71;
    localparam [15:0] RTS         = 16'h4E75;
    localparam [15:0] RTR         = 16'h4E77;
    localparam [15:0] JMP_A0      = 16'h4ED0;   // JMP (A0)
    localparam [15:0] JMP_D16_A0  = 16'h4EE8;   // JMP (d16,A0)
    localparam [15:0] JSR_A1      = 16'h4E91;   // JSR (A1)
    localparam [15:0] JSR_D16_A2  = 16'h4EAA;   // JSR (d16,A2)
    localparam [15:0] BSR_W       = 16'h6100;   // BSR.W prefix (d8=0x00 → word form)
    localparam [3:0]  CC_T=4'h0, CC_F=4'h1, CC_NE=4'h6, CC_EQ=4'h7;

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
    function automatic [15:0] LINK_W(input logic [2:0] n);
        LINK_W = 16'h4E50 | {13'h0, n};
    endfunction
    function automatic [15:0] UNLK(input logic [2:0] n);
        UNLK = 16'h4E58 | {13'h0, n};
    endfunction

    // ─── test helpers ─────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        chk(tag, {31'h0, got}, {31'h0, exp});
    endtask

    // Present instruction, wait for instr_ack, drain 8 cycles for WB+mem settle.
    task automatic run_instr(input logic [15:0] w0,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        saw_branch  = 1'b0;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(8) @(posedge clk);
    endtask

    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(CLR_L(n),  1'b0, 32'h0);
        run_instr(ADDI_L(n), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);
        run_instr(16'h0680, 1'b1, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    task automatic set_isp(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk); #1;
        ssp_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // ─── test body ────────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ==================================================================
        // NOP: SR unchanged
        // ==================================================================
        $display("--- NOP ---");
        begin
            logic [15:0] sr_save;
            sr_save = sr_out;
            run_instr(NOP, 1'b0, 32'h0);
            chk("NOP: SR unchanged", {16'h0, sr_out}, {16'h0, sr_save});
        end

        // ==================================================================
        // MOVEQ #-1,D0 → D0=0xFFFFFFFF N=1 Z=0
        // ==================================================================
        $display("--- MOVEQ #-1,D0 ---");
        run_instr(MOVEQ(3'd0, 8'hFF), 1'b0, 32'h0);
        chk ("MOVEQ #-1,D0: D0",  dut.u_rf.d_reg[0], 32'hFFFF_FFFF);
        chk1("MOVEQ #-1,D0: N=1", sr_out[3], 1'b1);
        chk1("MOVEQ #-1,D0: Z=0", sr_out[2], 1'b0);

        // ==================================================================
        // MOVEQ #0,D1 → D1=0 Z=1 N=0
        // ==================================================================
        $display("--- MOVEQ #0,D1 ---");
        run_instr(MOVEQ(3'd1, 8'h00), 1'b0, 32'h0);
        chk ("MOVEQ #0,D1: D1",  dut.u_rf.d_reg[1], 32'h0);
        chk1("MOVEQ #0,D1: Z=1", sr_out[2], 1'b1);
        chk1("MOVEQ #0,D1: N=0", sr_out[3], 1'b0);

        // ==================================================================
        // ADDQ.L #3,D2 → D2=3 Z=0
        // ==================================================================
        $display("--- ADDQ.L #3,D2 ---");
        run_instr(ADDQ(3'd3, 2'b10, 3'd2), 1'b0, 32'h0);
        chk ("ADDQ.L #3,D2: D2",  dut.u_rf.d_reg[2], 32'h3);
        chk1("ADDQ.L #3,D2: Z=0", sr_out[2], 1'b0);

        // ==================================================================
        // SUBQ.W #4,D2 → D2[15:0]=0xFFFF N=1 C=1
        // ==================================================================
        $display("--- SUBQ.W #4,D2 ---");
        run_instr(SUBQ(3'd4, 2'b01, 3'd2), 1'b0, 32'h0);
        chk ("SUBQ.W #4,D2: D2[15:0]",  {16'h0, dut.u_rf.d_reg[2][15:0]}, 32'h0000_FFFF);
        chk ("SUBQ.W #4,D2: D2[31:16]", {16'h0, dut.u_rf.d_reg[2][31:16]}, 32'h0);
        chk1("SUBQ.W #4,D2: N=1", sr_out[3], 1'b1);
        chk1("SUBQ.W #4,D2: C=1", sr_out[0], 1'b1);

        // ==================================================================
        // BRA.B taken: decode_pc=0x1000, d8=10 → target=0x100C
        // ==================================================================
        $display("--- BRA.B taken ---");
        decode_pc = 32'h0000_1000;
        run_instr(BRA_B(8'd10), 1'b0, 32'h0);
        chk1("BRA.B: taken",         saw_branch,  1'b1);
        chk ("BRA.B: target=0x100C", last_target, 32'h0000_100C);

        // ==================================================================
        // BEQ.B taken (Z=1): decode_pc=0x2000, d8=6 → target=0x2008
        // ==================================================================
        $display("--- BEQ.B taken (Z=1) ---");
        run_instr(MOVEQ(3'd3, 8'h00), 1'b0, 32'h0);  // set Z=1
        decode_pc = 32'h0000_2000;
        run_instr(BCC_B(CC_EQ, 8'd6), 1'b0, 32'h0);
        chk1("BEQ.B: taken",         saw_branch,  1'b1);
        chk ("BEQ.B: target=0x2008", last_target, 32'h0000_2008);

        // ==================================================================
        // BNE.B not taken (Z=1): decode_pc=0x2000
        // ==================================================================
        $display("--- BNE.B not taken (Z=1) ---");
        run_instr(BCC_B(CC_NE, 8'd10), 1'b0, 32'h0);
        chk1("BNE.B: not taken", saw_branch, 1'b0);

        // ==================================================================
        // SWAP D3 → D3=0x1234ABCD
        // ==================================================================
        $display("--- SWAP D3 ---");
        decode_pc = 32'h0000_1000;
        set_dn(3'd3, 32'hABCD_1234);
        run_instr(SWAP_DN(3'd3), 1'b0, 32'h0);
        chk("SWAP D3", dut.u_rf.d_reg[3], 32'h1234_ABCD);

        // ==================================================================
        // EXT.W D4: D4=0x80 → D4[15:0]=0xFF80 N=1
        // ==================================================================
        $display("--- EXT.W D4 ---");
        set_dn(3'd4, 32'h80);
        run_instr(EXT_W(3'd4), 1'b0, 32'h0);
        chk ("EXT.W D4: [15:0]",  {16'h0, dut.u_rf.d_reg[4][15:0]}, 32'h0000_FF80);
        chk ("EXT.W D4: [31:16]", {16'h0, dut.u_rf.d_reg[4][31:16]}, 32'h0);
        chk1("EXT.W D4: N=1",     sr_out[3], 1'b1);

        // ==================================================================
        // EXT.L D5: D5=0x8001 → D5=0xFFFF8001 N=1
        // ==================================================================
        $display("--- EXT.L D5 ---");
        set_dn(3'd5, 32'h8001);
        run_instr(EXT_L(3'd5), 1'b0, 32'h0);
        chk ("EXT.L D5",    dut.u_rf.d_reg[5], 32'hFFFF_8001);
        chk1("EXT.L D5: N", sr_out[3], 1'b1);

        // ==================================================================
        // EXTB.L D6: D6=0xFF7F → D6[7:0]=0x7F sign-extend to 0x0000007F N=0
        // ==================================================================
        $display("--- EXTB.L D6 ---");
        set_dn(3'd6, 32'hFF7F);
        run_instr(EXTB_L(3'd6), 1'b0, 32'h0);
        chk ("EXTB.L D6",    dut.u_rf.d_reg[6], 32'h0000_007F);
        chk1("EXTB.L D6: N", sr_out[3], 1'b0);

        // ==================================================================
        // SEQ D0 (Z=1) → D0[7:0]=0xFF
        // ==================================================================
        $display("--- SEQ D0 (Z=1) ---");
        run_instr(MOVEQ(3'd7, 8'h00), 1'b0, 32'h0);  // Z=1
        run_instr(CLR_L(3'd0), 1'b0, 32'h0);
        run_instr(SCC(CC_EQ, 3'd0), 1'b0, 32'h0);
        chk("SEQ D0 (Z=1): D0[7:0]=0xFF", {24'h0, dut.u_rf.d_reg[0][7:0]}, 32'h0000_00FF);

        // ==================================================================
        // SNE D0 (Z=1) → D0[7:0]=0x00
        // ==================================================================
        $display("--- SNE D0 (Z=1) ---");
        run_instr(SCC(CC_NE, 3'd0), 1'b0, 32'h0);
        chk("SNE D0 (Z=1): D0[7:0]=0x00", {24'h0, dut.u_rf.d_reg[0][7:0]}, 32'h0);

        // ==================================================================
        // DBF D7: D7=2, d16=4, decode_pc=0x3000 → D7→1, branch to 0x3006
        // ==================================================================
        $display("--- DBF D7 (counter=2 branch taken) ---");
        set_dn(3'd7, 32'h2);
        decode_pc = 32'h0000_3000;
        run_instr(DBCC(CC_F, 3'd7), 1'b1, {16'h0, 16'd4});
        chk ("DBF D7: D7[15:0]=1",   {16'h0, dut.u_rf.d_reg[7][15:0]}, 32'h0000_0001);
        chk1("DBF D7: branch taken",  saw_branch,  1'b1);
        chk ("DBF D7: target=0x3006", last_target, 32'h0000_3006);

        // ==================================================================
        // MOVE.L D0,D1 → D1=0x42
        // ==================================================================
        $display("--- MOVE.L D0,D1 ---");
        decode_pc = 32'h0000_1000;
        run_instr(MOVEQ(3'd0, 8'h42), 1'b0, 32'h0);
        run_instr(MOVEQ(3'd1, 8'h00), 1'b0, 32'h0);
        run_instr(MOVE_L(3'd0, 3'd1), 1'b0, 32'h0);
        chk("MOVE.L D0,D1: D1=0x42", dut.u_rf.d_reg[1], 32'h0000_0042);

        // ==================================================================
        // JMP (A0): A0=0x2000 → branch to 0x2000
        // ==================================================================
        $display("--- JMP (A0) ---");
        set_an(3'd0, 32'h0000_2000);
        run_instr(JMP_A0, 1'b0, 32'h0);
        chk1("JMP (A0): taken",         saw_branch,  1'b1);
        chk ("JMP (A0): target=0x2000", last_target, 32'h0000_2000);

        // ==================================================================
        // JMP (d16,A0): A0=0x2000, d16=+0x10 → target=0x2010
        // ==================================================================
        $display("--- JMP (d16,A0) ---");
        run_instr(JMP_D16_A0, 1'b1, {16'h0, 16'h0010});
        chk1("JMP (d16,A0): taken",         saw_branch,  1'b1);
        chk ("JMP (d16,A0): target=0x2010", last_target, 32'h0000_2010);

        // ==================================================================
        // JSR (A1): A1=0x3000, A7=0x100, decode_pc=0x1000
        //   return_PC=0x1002 pushed to M[0xFC], A7→0xFC, branch to 0x3000
        // ==================================================================
        $display("--- JSR (A1) ---");
        set_isp(32'h0000_0100);
        set_an(3'd1, 32'h0000_3000);
        run_instr(JSR_A1, 1'b0, 32'h0);
        chk1("JSR (A1): taken",              saw_branch,             1'b1);
        chk ("JSR (A1): target=0x3000",      last_target,            32'h0000_3000);
        chk ("JSR (A1): A7=0xFC",            isp_out,                32'h0000_00FC);
        chk ("JSR (A1): stack=return_PC",    ram[32'h00FC >> 2],     32'h0000_1002);

        // ==================================================================
        // BSR.B disp8=+0x20 (2-byte): return_PC=0x1002, target=0x1022, A7=0xFC
        // ==================================================================
        $display("--- BSR.B disp8=+0x20 ---");
        set_isp(32'h0000_0100);
        run_instr(16'h6120, 1'b0, 32'h0);
        chk1("BSR.B: taken",                saw_branch,             1'b1);
        chk ("BSR.B: target=0x1022",        last_target,            32'h0000_1022);
        chk ("BSR.B: A7=0xFC",              isp_out,                32'h0000_00FC);
        chk ("BSR.B: stack=0x1002",         ram[32'h00FC >> 2],     32'h0000_1002);

        // ==================================================================
        // BSR.W d16=+0x100 (4-byte): return_PC=0x1004, target=0x1102, A7=0xFC
        // ==================================================================
        $display("--- BSR.W d16=+0x100 ---");
        set_isp(32'h0000_0100);
        run_instr(BSR_W, 1'b1, {16'h0, 16'h0100});
        chk1("BSR.W: taken",                saw_branch,             1'b1);
        chk ("BSR.W: target=0x1102",        last_target,            32'h0000_1102);
        chk ("BSR.W: A7=0xFC",              isp_out,                32'h0000_00FC);
        chk ("BSR.W: stack=0x1004",         ram[32'h00FC >> 2],     32'h0000_1004);

        // ==================================================================
        // RTS: M[0x100]=0x5000 pre-loaded, A7=0x100 → branch to 0x5000, A7=0x104
        // ==================================================================
        $display("--- RTS ---");
        ram[32'h0100 >> 2] = 32'h0000_5000;
        set_isp(32'h0000_0100);
        run_instr(RTS, 1'b0, 32'h0);
        chk1("RTS: taken",         saw_branch,  1'b1);
        chk ("RTS: target=0x5000", last_target, 32'h0000_5000);
        chk ("RTS: A7=0x104",      isp_out,     32'h0000_0104);

        // ==================================================================
        // RTR: SSP=0x202 → CCR word popped from (A7)=0x202 (word read, A7+=2),
        // return PC popped from 0x204 (longword read, A7+=4). SSP starts at
        // 0x202 (not 0x200) specifically so the CCR and PC reads land in two
        // *different* slots of this testbench's word-addressed `ram[]` model
        // (indexed by mem_addr[9:2], which ignores the low 2 address bits) —
        // with SSP=0x200 the real A7+2 PC-read address (0x202) would alias
        // the exact same ram[] slot as the CCR read (0x200>>2 == 0x202>>2),
        // which this simplified memory stub can't represent (no byte-lane
        // steering); starting 2 bytes in avoids that aliasing entirely.
        //   CCR=0x15 → X=1,N=0,Z=1,V=0,C=1; branch to 0x8888; A7=0x202+6=0x208
        // ==================================================================
        $display("--- RTR ---");
        ram[32'h0200 >> 2] = 32'h0000_0015;
        ram[32'h0204 >> 2] = 32'h0000_8888;
        set_isp(32'h0000_0202);
        run_instr(RTR, 1'b0, 32'h0);
        chk1("RTR: taken",         saw_branch,          1'b1);
        chk ("RTR: target=0x8888", last_target,         32'h0000_8888);
        chk ("RTR: A7=0x208",      isp_out,             32'h0000_0208);
        chk ("RTR: CCR=0x15",      {27'h0, sr_out[4:0]}, 32'h0000_0015);

        // ==================================================================
        // JSR (d16,A2): A2=0x4000, d16=+0x80, decode_pc=0x1000
        //   return_PC=0x1004, target=0x4080, A7=0xFC
        // ==================================================================
        $display("--- JSR (d16,A2) ---");
        set_isp(32'h0000_0100);
        set_an(3'd2, 32'h0000_4000);
        run_instr(JSR_D16_A2, 1'b1, {16'h0, 16'h0080});
        chk1("JSR (d16,A2): taken",           saw_branch,          1'b1);
        chk ("JSR (d16,A2): target=0x4080",   last_target,         32'h0000_4080);
        chk ("JSR (d16,A2): A7=0xFC",         isp_out,             32'h0000_00FC);
        chk ("JSR (d16,A2): stack=0x1004",    ram[32'h00FC >> 2],  32'h0000_1004);

        // ==================================================================
        // LINK A2,#-16: A7=0x300, A2=0xABCD1234
        //   → M[0x2FC]=0xABCD1234, A2=0x2FC, A7=0x2EC
        // ==================================================================
        $display("--- LINK A2,#-16 ---");
        set_isp(32'h0000_0300);
        set_an(3'd2, 32'hABCD_1234);
        run_instr(LINK_W(3'd2), 1'b1, {16'h0, 16'hFFF0});
        chk("LINK A2: M[0x2FC]=old_A2", ram[32'h02FC >> 2],   32'hABCD_1234);
        chk("LINK A2: A2=0x2FC",        dut.u_rf.a_reg[2],    32'h0000_02FC);
        chk("LINK A2: A7=0x2EC",        isp_out,               32'h0000_02EC);

        // ==================================================================
        // UNLK A2 (continuation: A7=0x2EC, A2=0x2FC, M[0x2FC]=0xABCD1234)
        //   → A2=0xABCD1234, A7=0x300
        // ==================================================================
        $display("--- UNLK A2 ---");
        run_instr(UNLK(3'd2), 1'b0, 32'h0);
        chk("UNLK A2: A2 restored",   dut.u_rf.a_reg[2], 32'hABCD_1234);
        chk("UNLK A2: A7=0x300",      isp_out,           32'h0000_0300);

        // ==================================================================
        // Round-trip LINK A5 + UNLK A5
        // ==================================================================
        $display("--- LINK/UNLK round-trip (A5) ---");
        set_isp(32'h0000_0400);
        set_an(3'd5, 32'h0000_CAFE);
        run_instr(LINK_W(3'd5), 1'b1, {16'h0, 16'hFFE0});
        chk("LINK A5: M[0x3FC]=old_A5", ram[32'h03FC >> 2], 32'h0000_CAFE);
        chk("LINK A5: A5=0x3FC",        dut.u_rf.a_reg[5],  32'h0000_03FC);
        chk("LINK A5: A7=0x3DC",        isp_out,             32'h0000_03DC);
        run_instr(UNLK(3'd5), 1'b0, 32'h0);
        chk("UNLK A5: A5 restored",     dut.u_rf.a_reg[5],  32'h0000_CAFE);
        chk("UNLK A5: A7=0x400",        isp_out,             32'h0000_0400);

        // ==================================================================
        // LINK A0,#0 (zero displacement): A7=0x200, A0=0x11112222
        //   → M[0x1FC]=0x11112222, A0=0x1FC, A7=0x1FC
        // ==================================================================
        $display("--- LINK A0,#0 ---");
        set_isp(32'h0000_0200);
        set_an(3'd0, 32'h1111_2222);
        run_instr(LINK_W(3'd0), 1'b1, {16'h0, 16'h0000});
        chk("LINK A0,#0: M[0x1FC]", ram[32'h01FC >> 2], 32'h1111_2222);
        chk("LINK A0,#0: A0=0x1FC", dut.u_rf.a_reg[0],  32'h0000_01FC);
        chk("LINK A0,#0: A7=0x1FC", isp_out,             32'h0000_01FC);
        run_instr(UNLK(3'd0), 1'b0, 32'h0);
        chk("UNLK A0: A0 restored",  dut.u_rf.a_reg[0],  32'h1111_2222);
        chk("UNLK A0: A7=0x200",     isp_out,             32'h0000_0200);

        // ==================================================================
        // PEA (A0): A0=0x12345600, A7=0x0300 → M[0x02FC]=0x12345600, A7=0x02FC
        // PEA (An): 0100 1000 0101 0rrr, An=A0 → 0x4850
        // ==================================================================
        $display("--- PEA (A0) ---");
        set_an(3'd0, 32'h1234_5600);
        set_isp(32'h0000_0300);
        run_instr(16'h4850, 1'b0, 32'h0);
        chk("PEA (A0): stack=A0",  ram[32'h02FC >> 2], 32'h1234_5600);
        chk("PEA (A0): A7=0x02FC", isp_out,            32'h0000_02FC);

        // ==================================================================
        // PEA (d16,A1): A1=0x5000, d16=+0x20 → push 0x5020; A7=0x02FC
        // Opcode 0x4869 (f_mode=101, f_reg=A1)
        // ==================================================================
        $display("--- PEA (d16,A1) ---");
        set_an(3'd1, 32'h0000_5000);
        set_isp(32'h0000_0300);
        run_instr(16'h4869, 1'b1, {16'h0, 16'h0020});
        chk("PEA (d16,A1): stack=A1+d16", ram[32'h02FC >> 2], 32'h0000_5020);
        chk("PEA (d16,A1): A7=0x02FC",   isp_out,             32'h0000_02FC);

        // ==================================================================
        // PEA (xxx).L: push 0x0001CAFE; A7=0x02FC
        // Opcode 0x4879 (f_mode=111, f_reg=001)
        // ==================================================================
        $display("--- PEA (xxx).L ---");
        set_isp(32'h0000_0300);
        run_instr(16'h4879, 1'b1, 32'h0001_CAFE);
        chk("PEA (xxx).L: stack", ram[32'h02FC >> 2], 32'h0001_CAFE);
        chk("PEA (xxx).L: A7",   isp_out,             32'h0000_02FC);

        // ==================================================================
        // EXG D3,D5: swap → D3=0x55555555, D5=0xAAAAAAAA
        // Opcode 0xC745
        // ==================================================================
        $display("--- EXG D3,D5 ---");
        set_dn(3'd3, 32'hAAAA_AAAA);
        set_dn(3'd5, 32'h5555_5555);
        run_instr(16'hC745, 1'b0, 32'h0);
        chk("EXG D3,D5: D3=D5_orig", dut.u_rf.d_reg[3], 32'h5555_5555);
        chk("EXG D3,D5: D5=D3_orig", dut.u_rf.d_reg[5], 32'hAAAA_AAAA);

        // ==================================================================
        // EXG A2,A3: swap → A2=0x00022222, A3=0x00011111
        // Opcode 0xC54B
        // ==================================================================
        $display("--- EXG A2,A3 ---");
        set_an(3'd2, 32'h0001_1111);
        set_an(3'd3, 32'h0002_2222);
        run_instr(16'hC54B, 1'b0, 32'h0);
        chk("EXG A2,A3: A2=A3_orig", dut.u_rf.a_reg[2], 32'h0002_2222);
        chk("EXG A2,A3: A3=A2_orig", dut.u_rf.a_reg[3], 32'h0001_1111);

        // ==================================================================
        // EXG D2,A4: swap → D2=0x00004444, A4=0x00003333
        // Opcode 0xC58C
        // ==================================================================
        $display("--- EXG D2,A4 ---");
        set_dn(3'd2, 32'h0000_3333);
        set_an(3'd4, 32'h0000_4444);
        run_instr(16'hC58C, 1'b0, 32'h0);
        chk("EXG D2,A4: D2=A4_orig", dut.u_rf.d_reg[2], 32'h0000_4444);
        chk("EXG D2,A4: A4=D2_orig", dut.u_rf.a_reg[4], 32'h0000_3333);

        // ==================================================================
        // RTD #4: A7=0x0200, M[0x0200]=0xCAFE1000 → branch 0xCAFE1000, A7=0x208
        // Opcode 0x4E74, ext=0x0004
        // ==================================================================
        $display("--- RTD #4 ---");
        set_isp(32'h0000_0200);
        ram[32'h0200 >> 2] = 32'hCAFE_1000;
        run_instr(16'h4E74, 1'b1, {16'h0, 16'h0004});
        chk1("RTD: branch taken",     saw_branch,  1'b1);
        chk ("RTD: target=0xCAFE1000", last_target, 32'hCAFE_1000);
        chk ("RTD: A7=0x208",          isp_out,     32'h0000_0208);

        // ==================================================================
        // CMPM.B (A0)+,(A1)+: M[A0]=5, M[A1]=8; CMP=8-5=3 → N=0 Z=0 V=0 C=0
        // A0=0x0100, A1=0x0104; after: A0=0x0101, A1=0x0105
        // Opcode 0xB308
        // ==================================================================
        $display("--- CMPM.B (A0)+,(A1)+ ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0104);
        ram[32'h0100 >> 2] = 32'h0000_0005;
        ram[32'h0104 >> 2] = 32'h0000_0008;
        run_instr(16'hB308, 1'b0, 32'h0);
        chk1("CMPM.B: N=0", sr_out[3], 1'b0);
        chk1("CMPM.B: Z=0", sr_out[2], 1'b0);
        chk1("CMPM.B: V=0", sr_out[1], 1'b0);
        chk1("CMPM.B: C=0", sr_out[0], 1'b0);
        chk ("CMPM.B: A0=0x0101", dut.u_rf.a_reg[0], 32'h0000_0101);
        chk ("CMPM.B: A1=0x0105", dut.u_rf.a_reg[1], 32'h0000_0105);

        // ==================================================================
        // CMPM.W (A0)+,(A1)+: equal values → Z=1
        // A0=0x0110, A1=0x0114; M[A0]=0x1234, M[A1]=0x1234
        // After: A0=0x0112, A1=0x0116
        // Opcode 0xB348
        // ==================================================================
        $display("--- CMPM.W (A0)+,(A1)+ equal ---");
        set_an(3'd0, 32'h0000_0110);
        set_an(3'd1, 32'h0000_0114);
        ram[32'h0110 >> 2] = 32'h0000_1234;
        ram[32'h0114 >> 2] = 32'h0000_1234;
        run_instr(16'hB348, 1'b0, 32'h0);
        chk1("CMPM.W: Z=1", sr_out[2], 1'b1);
        chk1("CMPM.W: N=0", sr_out[3], 1'b0);
        chk ("CMPM.W: A0=0x0112", dut.u_rf.a_reg[0], 32'h0000_0112);
        chk ("CMPM.W: A1=0x0116", dut.u_rf.a_reg[1], 32'h0000_0116);

        // ─── summary ──────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("PASS  ctrl_flow (%0d checks)", pass_cnt);
        else
            $display("FAIL  ctrl_flow: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL  ctrl_flow: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

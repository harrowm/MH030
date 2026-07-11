// Phase 65: ALU memory-source → register destination
// Tests ADD/SUB/AND/OR/CMP + MULU/MULS/DIVU/DIVS from memory EA to Dn.
// EA modes: (d16,An), (xxx).W, (xxx).L, (d16,PC)
// Drives m68030_eu directly.

`default_nettype none
`timescale 1ns/1ps

module seq65_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;   // 100 MHz (4× bus)

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word  = 16'h0;
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

    logic [31:0] decode_pc    = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req;
    logic        mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata   = 32'h0;
    logic        mem_ack     = 0;
    logic        mem_berr    = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;
    logic [31:0] eu_coproc_rdata = 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack   = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack    = 0;
    logic [15:0] eu_ptest_mmusr  = 16'h0;

    logic [31:0] tc_out, tt0_out, tt1_out;
    logic [63:0] crp_out, srp_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;
    logic        eu_reset_req;

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu u_dut (
        .clk_4x        (clk),
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
        .cacr_out      (cacr_out),
        .caar_out      (caar_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .decode_pc     (decode_pc),
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
        .mem_rmw       (mem_rmw),
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
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
        .crp_out         (crp_out),
        .srp_out         (srp_out),
        .an_wr_en        (an_wr_en),
        .an_wr_sel       (an_wr_sel),
        .an_wr_data      (an_wr_data),
        .div_trap        (div_trap),
        .chk_trap        (chk_trap),
        .eu_trap_req     (eu_trap_req),
        .eu_trap_num     (eu_trap_num),
        .eu_trapv_req    (eu_trapv_req),
        .eu_illegal_req  (eu_illegal_req),
        .eu_stop         (eu_stop),
        .eu_reset_req    (eu_reset_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model ─────────────────────────────────────────────────────────
    logic [31:0] ram [0:8191];
    always_ff @(posedge clk) begin
        if (mem_req && mem_rw) begin
            mem_ack   <= 1'b1;
            mem_rdata <= ram[mem_addr[14:2]];
        end else if (mem_req && !mem_rw) begin
            mem_ack   <= 1'b1;
            ram[mem_addr[14:2]] <= mem_wdata;
        end else begin
            mem_ack   <= 1'b0;
            mem_rdata <= 32'h0;
        end
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk32(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk16(input string tag, input logic [15:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %04h exp %04h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic issue(input logic [15:0] iw, input logic has_ext,
                         input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
    endtask

    task automatic issue_wait(input logic [15:0] iw, input logic has_ext,
                              input logic [31:0] ext);
        issue(iw, has_ext, ext);
        repeat(100) begin
            @(posedge clk);
            if (mem_ack) break;
        end
        repeat(3) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        issue(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);   // CLR.L Dn
        repeat(3) @(posedge clk);
        issue(16'h0680 | (16'(n) & 16'h7), 1'b1, val);      // ADDI.L #val,Dn
        repeat(3) @(posedge clk);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        issue({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);  // MOVEA.L D0,An
        repeat(3) @(posedge clk);
    endtask

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;

        @(posedge rst_n); repeat(2) @(posedge clk);

        // ==================================================================
        // P65-01: ADD.L (d16,A0),D1
        // ADD.L (8,A0),D1: opcode 1101_001_0_10_101_000 = 0xD2A8
        // ext_data[15:0] = d16 = 0x0008
        // A0=0x1000, EA=0x1008
        // mem[0x1008] = 0x0000_1234, D1=0x0000_5000
        // Expected: D1 = 0x0000_5000 + 0x0000_1234 = 0x0000_6234
        // ==================================================================
        $display("--- P65-01: ADD.L (8,A0),D1 ---");
        set_an(3'd0, 32'h0000_1000);
        set_dn(1, 32'h0000_5000);
        ram[32'h1008 >> 2] = 32'h0000_1234;
        issue_wait(16'hD2A8, 1'b1, 32'h0000_0008);
        chk32("P65-01 D1", u_dut.u_rf.d_reg[1], 32'h0000_6234);

        // ==================================================================
        // P65-02: SUB.L (xxx).W,D2
        // SUB.L (0x2000).W,D2: opcode 1001_010_0_10_111_000 = 0x94B8
        // ext_data[15:0] = abs_short = 0x2000
        // mem[0x2000] = 0x0000_0300, D2=0x0000_1000
        // Expected: D2 = 0x0000_1000 - 0x0000_0300 = 0x0000_0D00
        // ==================================================================
        $display("--- P65-02: SUB.L (0x2000).W,D2 ---");
        set_dn(2, 32'h0000_1000);
        ram[32'h2000 >> 2] = 32'h0000_0300;
        issue_wait(16'h94B8, 1'b1, 32'h0000_2000);
        chk32("P65-02 D2", u_dut.u_rf.d_reg[2], 32'h0000_0D00);

        // ==================================================================
        // P65-03: AND.L (xxx).L,D3
        // AND.L (0x3000).L,D3: opcode 1100_011_0_10_111_001 = 0xC6B9
        // ext_data[31:0] = abs_long = 0x0000_3000
        // mem[0x3000] = 0xF0F0_F0F0, D3=0xFF00_FF00
        // Expected: D3 = 0xFF00_FF00 & 0xF0F0_F0F0 = 0xF000_F000
        // ==================================================================
        $display("--- P65-03: AND.L (0x3000).L,D3 ---");
        set_dn(3, 32'hFF00_FF00);
        ram[32'h3000 >> 2] = 32'hF0F0_F0F0;
        issue_wait(16'hC6B9, 1'b1, 32'h0000_3000);
        chk32("P65-03 D3", u_dut.u_rf.d_reg[3], 32'hF000_F000);

        // ==================================================================
        // P65-04: OR.L (d16,PC),D4
        // OR.L (d16,PC),D4: opcode 1000_100_0_10_111_010 = 0x88BA
        // decode_pc=0x4000, d16=0x0006 → EA=0x4000+2+6=0x4008
        // ext_data[15:0] = d16 = 0x0006
        // mem[0x4008] = 0xF0F0_0000, D4=0x0000_000F
        // Expected: D4 = 0x0000_000F | 0xF0F0_0000 = 0xF0F0_000F
        // ==================================================================
        $display("--- P65-04: OR.L (d16,PC),D4 ---");
        decode_pc = 32'h0000_4000;
        set_dn(4, 32'h0000_000F);
        ram[32'h4008 >> 2] = 32'hF0F0_0000;
        issue_wait(16'h88BA, 1'b1, 32'h0000_0006);
        decode_pc = 32'h0;
        chk32("P65-04 D4", u_dut.u_rf.d_reg[4], 32'hF0F0_000F);

        // ==================================================================
        // P65-05: CMP.L (d16,A1),D5 — flags only
        // CMP.L (0x10,A1),D5: opcode 1011_101_0_10_101_001 = 0xBAA9
        // ext_data[15:0] = d16 = 0x0010
        // A1=0x5000, EA=0x5010
        // D5=0x0000_0200, mem[0x5010]=0x0000_0200
        // Expected: D5 unchanged, Z=1 (equal)
        // ==================================================================
        $display("--- P65-05: CMP.L (0x10,A1),D5 Z-flag ---");
        set_an(3'd1, 32'h0000_5000);
        set_dn(5, 32'h0000_0200);
        ram[32'h5010 >> 2] = 32'h0000_0200;
        issue_wait(16'hBAA9, 1'b1, 32'h0000_0010);
        chk32("P65-05 D5 unchanged", u_dut.u_rf.d_reg[5], 32'h0000_0200);
        chk16("P65-05 CCR Z=1",     sr_out & 16'h0004, 16'h0004);

        // ==================================================================
        // P65-06: CMP.L (d16,A1),D5 — N-flag (D5 > mem)
        // EA=0x5010, mem=0x0000_0100, D5=0x0000_0200 → D5-mem > 0 → N=0, C=0
        // ==================================================================
        $display("--- P65-06: CMP.L greater ---");
        ram[32'h5010 >> 2] = 32'h0000_0100;
        issue_wait(16'hBAA9, 1'b1, 32'h0000_0010);
        chk32("P65-06 D5 unchanged", u_dut.u_rf.d_reg[5], 32'h0000_0200);
        chk16("P65-06 CCR Z=0",     sr_out & 16'h0004, 16'h0000);
        chk16("P65-06 CCR N=0",     sr_out & 16'h0008, 16'h0000);

        // ==================================================================
        // P65-07: MULU.W (d16,A2),D6
        // MULU.W (4,A2),D6: opcode 1100_110_0_11_101_010 = 0xCCEA
        // ext_data[15:0] = d16 = 0x0004
        // A2=0x6000, EA=0x6004
        // D6=0x0000_0003, mem[0x6004]=0x0000_0004 → multiplier=4
        // Result: D6 = 3*4 = 0x0000_000C
        // ==================================================================
        $display("--- P65-07: MULU.W (4,A2),D6 ---");
        set_an(3'd2, 32'h0000_6000);
        set_dn(6, 32'h0000_0003);
        ram[32'h6004 >> 2] = 32'h0000_0004;
        issue_wait(16'hCCEA, 1'b1, 32'h0000_0004);
        chk32("P65-07 D6", u_dut.u_rf.d_reg[6], 32'h0000_000C);

        // ==================================================================
        // P65-08: MULS.W (xxx).W,D0
        // MULS.W (0x7000).W,D0: opcode 1100_000_1_11_111_000 = 0xC1F8
        // ext_data[15:0] = abs_short = 0x7000
        // D0=0x0000_0005, mem[0x7000]=0x0000_FFFE (-2 as signed 16-bit)
        // Result: D0 = 5 * (-2) = -10 = 0xFFFF_FFF6
        // ==================================================================
        $display("--- P65-08: MULS.W (0x7000).W,D0 ---");
        set_dn(0, 32'h0000_0005);
        ram[32'h7000 >> 2] = 32'h0000_FFFE;  // lower word = -2 as signed
        issue_wait(16'hC1F8, 1'b1, 32'h0000_7000);
        chk32("P65-08 D0", u_dut.u_rf.d_reg[0], 32'hFFFF_FFF6);

        // ==================================================================
        // P65-09: DIVU.W (xxx).W,D7
        // DIVU.W (0x7800).W,D7: opcode 1000_111_0_11_111_000 = 0x8EF8
        // ext_data[15:0] = abs_short = 0x7800
        // D7=0x0000_000C (=12), mem[0x7800]=0x0000_0003 (divisor=3)
        // Result: D7 = quotient(low)=4, remainder(hi)=0 → 0x0000_0004
        // ==================================================================
        $display("--- P65-09: DIVU.W (0x7800).W,D7 ---");
        set_dn(7, 32'h0000_000C);
        ram[32'h7800 >> 2] = 32'h0000_0003;
        issue_wait(16'h8EF8, 1'b1, 32'h0000_7800);
        chk32("P65-09 D7", u_dut.u_rf.d_reg[7], 32'h0000_0004);

        // ==================================================================
        // P65-10: EOR not decoded for mem-src — phase 65 only adds CMP (ea),Dn (f_dir=0).
        //         Verify the AND/SUB/ADD CCR updates via flag check.
        // ADD.L sets C=0 if no carry:
        // ADD.L (xxx).W,D1 where mem=0x10, D1=0x20 → D1=0x30, Z=0,N=0,C=0
        // ADD.L (xxx).W: opcode 1101_001_0_10_111_000 = 0xD2B8
        // ==================================================================
        $display("--- P65-10: ADD.L (xxx).W CCR ---");
        set_dn(1, 32'h0000_0020);
        ram[32'h2000 >> 2] = 32'h0000_0010;
        issue_wait(16'hD2B8, 1'b1, 32'h0000_2000);
        chk32("P65-10 D1", u_dut.u_rf.d_reg[1], 32'h0000_0030);
        chk16("P65-10 Z=0", sr_out & 16'h0004, 16'h0000);
        chk16("P65-10 N=0", sr_out & 16'h0008, 16'h0000);
        chk16("P65-10 C=0", sr_out & 16'h0001, 16'h0000);

        // ==================================================================
        // P65-11: DIVS.W (d16,A3),D2 — signed divide
        // DIVS.W (8,A3),D2: opcode 1000_010_1_11_101_011 = 0x85EB
        // ext_data[15:0] = d16 = 0x0008
        // A3=0x0800, EA=0x0808
        // D2=0x0000_0018 (=24), mem[0x0808]=0x0000_FFFC (-4 as signed 16-bit)
        // Result: 24 / (-4) = -6 quot(0xFFFA), 0 rem(0x0000) → D2 = 0x0000_FFFA
        // ==================================================================
        $display("--- P65-11: DIVS.W (8,A3),D2 ---");
        set_an(3'd3, 32'h0000_0800);
        set_dn(2, 32'h0000_0018);
        ram[32'h0808 >> 2] = 32'h0000_FFFC;  // lower word = -4 as signed
        issue_wait(16'h85EB, 1'b1, 32'h0000_0008);
        chk32("P65-11 D2", u_dut.u_rf.d_reg[2], 32'h0000_FFFA);

        // ==================================================================
        // Summary
        // ==================================================================
        @(posedge clk);
        $display("pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("PASS seq65");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL seq65: timeout");
        $finish;
    end

endmodule

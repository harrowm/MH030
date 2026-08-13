`default_nettype none
`timescale 1ns/1ps

// CMPM postincrement regression tests.
//
// Covers the two bugs fixed in Phase 79:
//   1. dec_an_delta used Ax to determine A7 byte-step; Ay's step was wrong
//      when Ay=A7 (step should be 2) or Ax=A7 while Ay!=A7 (Ay got Ax's step).
//   2. When Ax==Ay (same register), phase-2 EA used pre-increment address so
//      only one postincrement fired instead of two.
//
// CMPM-01: byte, normal distinct registers
// CMPM-02: byte, same register (Ax==Ay)
// CMPM-03: byte, Ay=A7 (A7 byte special step=2 applied to Ay)
// CMPM-04: byte, Ax=A7 (A7 byte special step=2 applied to Ax; Ay gets step=1)
// CMPM-05: word, same register
// CMPM-06: long, same register
// CMPM-07: long equal values — CCR Z=1
// CMPM-08: long Ax>Ay — CCR Z=0, N=0

module cmpm_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

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

    logic [31:0] decode_pc   = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req;
    logic        mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
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
    logic        eu_priv_req;
    logic        eu_trace_req;
    logic        eu_linea_req;
    logic        eu_linef_req;

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    m68030_eu dut (
        .clk_4x          (clk),
        .rst_n           (rst_n),
        .instr_word      (instr_word),
        .instr_valid     (instr_valid),
        .ext_data        (ext_data),
        .ext_valid       (ext_valid),
        .instr_ack       (instr_ack),
        .eu_busy         (eu_busy),
        .pc_wr_en        (pc_wr_en),
        .pc_wr_data      (pc_wr_data),
        .pc_out          (pc_out),
        .vbr_wr_en       (vbr_wr_en),
        .vbr_wr_data     (vbr_wr_data),
        .vbr_out         (vbr_out),
        .usp_out         (usp_out),
        .msp_out         (msp_out),
        .isp_out         (isp_out),
        .cacr_out        (cacr_out),
        .caar_out        (caar_out),
        .sr_out          (sr_out),
        .supervisor      (supervisor),
        .master_mode     (master_mode),
        .ipl_mask        (ipl_mask),
        .int_pending    (1'b0),
        .eu_int_ready   (),
        .exc_active     (1'b0),
        .decode_pc       (decode_pc),
        .branch_taken    (branch_taken),
        .branch_target   (branch_target),
        .mem_req         (mem_req),
        .mem_rw          (mem_rw),
        .mem_siz         (mem_siz),
        .mem_fc          (mem_fc),
        .mem_addr        (mem_addr),
        .mem_wdata       (mem_wdata),
        .mem_rdata       (mem_rdata),
        .mem_ack         (mem_ack),
        .mem_berr        (mem_berr),
        .mem_rmw         (mem_rmw),
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
        .eu_priv_req     (eu_priv_req),
        .eu_trace_req    (eu_trace_req),
        .eu_linea_req    (eu_linea_req),
        .eu_linef_req    (eu_linef_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // Simple word-addressed RAM.  In the direct-EU testbench (no BIU lane
    // steering), the EU reads mem_rdata[7:0] for bytes, [15:0] for words,
    // [31:0] for longs.  Store test values accordingly.
    logic [31:0] ram [0:8191];
    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    int pass_count = 0, fail_count = 0;

    task automatic chk32(input string tag, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    task automatic chk1(input string tag, input logic got, input logic exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0b exp %0b", tag, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    task automatic run_instr(input logic [15:0] iw);
        @(posedge clk); #1;
        instr_word = iw; instr_valid = 1'b1; ext_valid = 1'b0;
        repeat(300) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        repeat(60) begin
            @(posedge clk);
            if (!eu_busy) break;
        end
        repeat(4) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        @(posedge clk); #1;
        instr_word = 16'h4280 | (16'(n) & 16'h7); instr_valid = 1; ext_valid = 0;
        repeat(50) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0;
        repeat(8) @(posedge clk);
        @(posedge clk); #1;
        instr_word = 16'h0680 | (16'(n) & 16'h7); ext_data = val; instr_valid = 1; ext_valid = 1;
        repeat(50) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0; ext_valid = 0;
        repeat(8) @(posedge clk);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        @(posedge clk); #1;
        instr_word = {4'h2, an, 3'b001, 3'b000, 3'b000}; instr_valid = 1; ext_valid = 0;
        repeat(50) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0;
        repeat(8) @(posedge clk);
    endtask

    task automatic set_a7(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_en = 1'b1; ssp_wr_data = val;
        @(posedge clk); #1;
        ssp_wr_en = 1'b0;
        repeat(4) @(posedge clk);
    endtask

    initial begin
        for (int j = 0; j < 8192; j++) ram[j] = 32'h0;
        @(posedge rst_n); repeat(4) @(posedge clk);

        // --------------------------------------------------------------------
        // CMPM-01: CMPM.b (A0)+,(A1)+ — normal distinct registers
        // Encoding: 1011_001_1_00_001_000 = 0xB308  (Ax=A1, Ay=A0, byte)
        // Expected: A0 += 1, A1 += 1
        // --------------------------------------------------------------------
        $display("--- CMPM-01: CMPM.b (A0)+,(A1)+ ---");
        ram[32'h1000 >> 2] = 32'h0000_0042;
        ram[32'h2000 >> 2] = 32'h0000_0043;
        set_an(3'b000, 32'h0000_1000);
        set_an(3'b001, 32'h0000_2000);
        run_instr(16'hB308);
        chk32("CMPM-01:A0", dut.u_rf.a_reg[0], 32'h0000_1001);
        chk32("CMPM-01:A1", dut.u_rf.a_reg[1], 32'h0000_2001);

        // --------------------------------------------------------------------
        // CMPM-02: CMPM.b (A0)+,(A0)+ — same register (Ax==Ay)
        // Encoding: 1011_000_1_00_001_000 = 0xB108  (Ax=A0, Ay=A0, byte)
        // Expected: A0 += 2 (two successive postincrements, not one)
        // --------------------------------------------------------------------
        $display("--- CMPM-02: CMPM.b (A0)+,(A0)+ same reg ---");
        ram[32'h1000 >> 2] = 32'h0000_0055;
        set_an(3'b000, 32'h0000_1000);
        run_instr(16'hB108);
        chk32("CMPM-02:A0", dut.u_rf.a_reg[0], 32'h0000_1002);

        // --------------------------------------------------------------------
        // CMPM-03: CMPM.b (A7)+,(A1)+ — Ay=A7, byte special step=2 for A7
        // Encoding: 1011_001_1_00_001_111 = 0xB30F  (Ax=A1, Ay=A7, byte)
        // Expected: A7 += 2 (A7 byte postincrement), A1 += 1
        // --------------------------------------------------------------------
        $display("--- CMPM-03: CMPM.b (A7)+,(A1)+ Ay=A7 ---");
        ram[32'h3000 >> 2] = 32'h0000_0010;
        ram[32'h4000 >> 2] = 32'h0000_0020;
        set_a7(32'h0000_3000);
        set_an(3'b001, 32'h0000_4000);
        run_instr(16'hB30F);
        chk32("CMPM-03:A7", isp_out,           32'h0000_3002);
        chk32("CMPM-03:A1", dut.u_rf.a_reg[1], 32'h0000_4001);

        // --------------------------------------------------------------------
        // CMPM-04: CMPM.b (A5)+,(A7)+ — Ax=A7, byte special step=2 for A7
        // Encoding: 1011_111_1_00_001_101 = 0xBF0D  (Ax=A7, Ay=A5, byte)
        // Expected: A5 += 1 (normal byte), A7 += 2 (A7 byte step)
        // --------------------------------------------------------------------
        $display("--- CMPM-04: CMPM.b (A5)+,(A7)+ Ax=A7 ---");
        ram[32'h5000 >> 2] = 32'h0000_0077;
        ram[32'h6000 >> 2] = 32'h0000_0088;
        set_an(3'b101, 32'h0000_5000);
        set_a7(32'h0000_6000);
        run_instr(16'hBF0D);
        chk32("CMPM-04:A5", dut.u_rf.a_reg[5], 32'h0000_5001);
        chk32("CMPM-04:A7", isp_out,            32'h0000_6002);

        // --------------------------------------------------------------------
        // CMPM-05: CMPM.w (A0)+,(A0)+ — same register, word size
        // Encoding: 1011_000_1_01_001_000 = 0xB148  (Ax=A0, Ay=A0, word)
        // Expected: A0 += 4 (two word postincrements of 2)
        // --------------------------------------------------------------------
        $display("--- CMPM-05: CMPM.w (A0)+,(A0)+ ---");
        ram[32'h1000 >> 2] = 32'h0000_1234;
        set_an(3'b000, 32'h0000_1000);
        run_instr(16'hB148);
        chk32("CMPM-05:A0", dut.u_rf.a_reg[0], 32'h0000_1004);

        // --------------------------------------------------------------------
        // CMPM-06: CMPM.l (A0)+,(A0)+ — same register, longword
        // Encoding: 1011_000_1_10_001_000 = 0xB188  (Ax=A0, Ay=A0, long)
        // Expected: A0 += 8 (two longword postincrements of 4)
        // --------------------------------------------------------------------
        $display("--- CMPM-06: CMPM.l (A0)+,(A0)+ ---");
        ram[32'h1000 >> 2] = 32'hDEAD_1234;
        ram[32'h1004 >> 2] = 32'hDEAD_5678;
        set_an(3'b000, 32'h0000_1000);
        run_instr(16'hB188);
        chk32("CMPM-06:A0", dut.u_rf.a_reg[0], 32'h0000_1008);

        // --------------------------------------------------------------------
        // CMPM-07: CMPM.l (A0)+,(A1)+ equal data — Z=1
        // Encoding: 1011_001_1_10_001_000 = 0xB388  (Ax=A1, Ay=A0, long)
        // M[0x1000] = M[0x2000] = 0xDEADBEEF → Z=1, N=0, C=0
        // --------------------------------------------------------------------
        $display("--- CMPM-07: CMPM.l equal → Z=1 ---");
        ram[32'h1000 >> 2] = 32'hDEAD_BEEF;
        ram[32'h2000 >> 2] = 32'hDEAD_BEEF;
        set_an(3'b000, 32'h0000_1000);
        set_an(3'b001, 32'h0000_2000);
        run_instr(16'hB388);
        chk32("CMPM-07:A0", dut.u_rf.a_reg[0], 32'h0000_1004);
        chk32("CMPM-07:A1", dut.u_rf.a_reg[1], 32'h0000_2004);
        chk1 ("CMPM-07:Z",  sr_out[2], 1'b1);
        chk1 ("CMPM-07:N",  sr_out[3], 1'b0);
        chk1 ("CMPM-07:C",  sr_out[0], 1'b0);

        // --------------------------------------------------------------------
        // CMPM-08: CMPM.l (A0)+,(A1)+ Ax_val > Ay_val — Z=0, N=0, C=0
        // M[0x1000]=0x100 (Ay), M[0x2000]=0x200 (Ax) → 0x200-0x100 = positive
        // --------------------------------------------------------------------
        $display("--- CMPM-08: CMPM.l Ax>Ay positive ---");
        ram[32'h1000 >> 2] = 32'h0000_0100;
        ram[32'h2000 >> 2] = 32'h0000_0200;
        set_an(3'b000, 32'h0000_1000);
        set_an(3'b001, 32'h0000_2000);
        run_instr(16'hB388);
        chk1("CMPM-08:Z", sr_out[2], 1'b0);
        chk1("CMPM-08:N", sr_out[3], 1'b0);
        chk1("CMPM-08:C", sr_out[0], 1'b0);

        $display("");
        $display("%0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS all CMPM tests");
        $finish;
    end

endmodule

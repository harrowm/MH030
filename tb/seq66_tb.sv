// Phase 66: ADDQ/SUBQ #,An; ADDQ/SUBQ to (d16,An)/abs.W/abs.L;
//           ADDA/SUBA/CMPA from memory EA (all memory modes).
`default_nettype none
`timescale 1ns/1ps

module seq66_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

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

    // ─── Memory model (combinatorial ack, 8K x 32) ───────────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
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

    task automatic chk1(input string tag, input logic got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0b exp %0b", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic run_instr(input logic [15:0] iw,
                             input logic        has_ext,
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
        repeat(10) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);   // CLR.L Dn
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);      // ADDI.L #val,Dn
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0); // MOVEA.L D0,An
    endtask

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // ==================================================================
        // P66-01: ADDQ #4,A0  (0101_100_0_10_001_000 = 0x5888)
        // An target: CCR unchanged, full 32-bit add
        // ==================================================================
        $display("--- P66-01: ADDQ #4,A0 ---");
        set_an(3'd0, 32'h0000_1000);
        run_instr(16'h5888, 1'b0, 32'h0);
        chk32("P66-01 A0", u_dut.u_rf.a_reg[0], 32'h0000_1004);

        // ==================================================================
        // P66-02: SUBQ #8,A7  (0101_000_1_10_001_111 = 0x518F)
        // An=A7 target (supervisor ISP)
        // ==================================================================
        $display("--- P66-02: SUBQ #8,A7 ---");
        set_an(3'd7, 32'h0000_3000);
        run_instr(16'h518F, 1'b0, 32'h0);
        chk32("P66-02 A7", u_dut.u_rf.isp_r, 32'h0000_2FF8);

        // ==================================================================
        // P66-03: ADDQ #3,(d16,A2) — memory RMW with displacement
        // (0101_011_0_10_101_010 = 0x56AA), ext=0x0010
        // A2=0x2000, EA=0x2010; mem[0x2010]=100 → 103
        // ==================================================================
        $display("--- P66-03: ADDQ #3,(0x10,A2) ---");
        set_an(3'd2, 32'h0000_2000);
        ram[32'h2010 >> 2] = 32'h0000_0064;
        run_instr(16'h56AA, 1'b1, 32'h0000_0010);
        chk32("P66-03 mem[0x2010]", ram[32'h2010 >> 2], 32'h0000_0067);

        // ==================================================================
        // P66-04: SUBQ #2,(xxx).W — abs.W memory RMW
        // (0101_010_1_10_111_000 = 0x55B8), ext=0x3000
        // mem[0x3000]=10 → 8
        // ==================================================================
        $display("--- P66-04: SUBQ #2,(0x3000).W ---");
        ram[32'h3000 >> 2] = 32'h0000_000A;
        run_instr(16'h55B8, 1'b1, 32'h0000_3000);
        chk32("P66-04 mem[0x3000]", ram[32'h3000 >> 2], 32'h0000_0008);

        // ==================================================================
        // P66-05: ADDQ #1,(xxx).L — abs.L memory RMW (2 ext words)
        // (0101_001_0_10_111_001 = 0x52B9), ext=0x0000_4000
        // mem[0x4000]=127 → 128
        // ==================================================================
        $display("--- P66-05: ADDQ #1,(0x4000).L ---");
        ram[32'h4000 >> 2] = 32'h0000_007F;
        run_instr(16'h52B9, 1'b1, 32'h0000_4000);
        chk32("P66-05 mem[0x4000]", ram[32'h4000 >> 2], 32'h0000_0080);

        // ==================================================================
        // P66-06: ADDA.L (A3),A4  (1101_100_1_11_010_011 = 0xD9D3)
        // A3=0x5000 (EA base), A4=0x1000; mem[0x5000]=0x1234
        // → A4 = 0x1000 + 0x1234 = 0x2234
        // ==================================================================
        $display("--- P66-06: ADDA.L (A3),A4 ---");
        set_an(3'd3, 32'h0000_5000);
        set_an(3'd4, 32'h0000_1000);
        ram[32'h5000 >> 2] = 32'h0000_1234;
        run_instr(16'hD9D3, 1'b0, 32'h0);
        chk32("P66-06 A4", u_dut.u_rf.a_reg[4], 32'h0000_2234);

        // ==================================================================
        // P66-07: ADDA.W (d16,A3),A4  (1101_100_0_11_101_011 = 0xD8EB), ext=0x0010
        // A3=0x5000, EA=0x5010; mem[0x5010][15:0]=0xFFFE (= -2 signed)
        // sign_ext(0xFFFE) = 0xFFFF_FFFE
        // A4=0x2234; → A4 = 0x2234 + 0xFFFF_FFFE = 0x2232
        // ==================================================================
        $display("--- P66-07: ADDA.W (0x10,A3),A4 ---");
        ram[32'h5010 >> 2] = 32'h0000_FFFE;
        run_instr(16'hD8EB, 1'b1, 32'h0000_0010);
        chk32("P66-07 A4", u_dut.u_rf.a_reg[4], 32'h0000_2232);

        // ==================================================================
        // P66-08: SUBA.L (xxx).W,A4  (1001_100_1_11_111_000 = 0x99F8), ext=0x6000
        // abs.W=0x6000; mem[0x6000]=0x32 (50 decimal)
        // A4=0x2232; → A4 = 0x2232 - 0x32 = 0x2200
        // ==================================================================
        $display("--- P66-08: SUBA.L (0x6000).W,A4 ---");
        ram[32'h6000 >> 2] = 32'h0000_0032;
        run_instr(16'h99F8, 1'b1, 32'h0000_6000);
        chk32("P66-08 A4", u_dut.u_rf.a_reg[4], 32'h0000_2200);

        // ==================================================================
        // P66-09: CMPA.W (xxx).L,A4  (1011_100_0_11_111_001 = 0xB8F9), ext=0x0000_7000
        // abs.L=0x7000; mem[0x7000][15:0]=0x1234
        // A4=0x1234 (reset); sign_ext(0x1234)=0x1234; 0x1234-0x1234=0 → Z=1
        // ==================================================================
        $display("--- P66-09: CMPA.W (0x7000).L,A4 (Z=1) ---");
        set_an(3'd4, 32'h0000_1234);
        ram[32'h7000 >> 2] = 32'h0000_1234;
        run_instr(16'hB8F9, 1'b1, 32'h0000_7000);
        chk1("P66-09 Z", sr_out[2], 1'b1);
        chk1("P66-09 N", sr_out[3], 1'b0);
        chk1("P66-09 C", sr_out[0], 1'b0);

        // ==================================================================
        // P66-10: ADDA.L (A5)+,A6  (1101_110_1_11_011_101 = 0xDDDD)
        // A5=0x5100 (postinc by 4); A6=0x200; mem[0x5100]=0x100
        // → A6 = 0x200 + 0x100 = 0x300; A5 = 0x5104
        // ==================================================================
        $display("--- P66-10: ADDA.L (A5)+,A6 ---");
        set_an(3'd5, 32'h0000_5100);
        set_an(3'd6, 32'h0000_0200);
        ram[32'h5100 >> 2] = 32'h0000_0100;
        run_instr(16'hDDDD, 1'b0, 32'h0);
        chk32("P66-10 A6", u_dut.u_rf.a_reg[6], 32'h0000_0300);
        chk32("P66-10 A5", u_dut.u_rf.a_reg[5], 32'h0000_5104);

        // ==================================================================
        // P66-11: SUBA.W -(A5),A6  (1001_110_0_11_100_101 = 0x9CE5)
        // A5=0x5104; predec by 2 → EA=0x5102, A5=0x5102
        // ram[0x5102>>2 = 0x1440] = ram[0x5100>>2] = 0x0000_0100
        // mem_rdata[15:0] = 0x0100 = 256; sign_ext = 0x0000_0100
        // A6=0x300; → A6 = 0x300 - 0x100 = 0x200; A5 = 0x5102
        // ==================================================================
        $display("--- P66-11: SUBA.W -(A5),A6 ---");
        run_instr(16'h9CE5, 1'b0, 32'h0);
        chk32("P66-11 A6", u_dut.u_rf.a_reg[6], 32'h0000_0200);
        chk32("P66-11 A5", u_dut.u_rf.a_reg[5], 32'h0000_5102);

        // ─── summary ──────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS %0d/%0d", pass_cnt, pass_cnt);
        else
            $display("FAIL %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

endmodule

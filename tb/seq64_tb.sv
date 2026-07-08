// Phase 64: MOVES full EA + PMOVE CRP/SRP (64-bit)
// Tests the new MOVES EA modes and 2-phase PMOVE CRP/SRP FSM.
// Drives m68030_eu directly (no IFU/SEQ layer).

`default_nettype none
`timescale 1ns/1ps

module seq64_tb;

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
    // RAM array addressed by word32 (addr[13:2] for 16KB range)
    logic [31:0] ram [0:4095];
    always_ff @(posedge clk) begin
        if (mem_req && mem_rw) begin        // read: ack next cycle
            mem_ack   <= 1'b1;
            mem_rdata <= ram[mem_addr[13:2]];
        end else if (mem_req && !mem_rw) begin  // write: capture
            mem_ack   <= 1'b1;
            ram[mem_addr[13:2]] <= mem_wdata;
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

    task automatic chk64(input string tag, input logic [63:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %016h exp %016h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    // Issue one instruction: opcode + optional 32-bit ext_data.
    // Waits up to 200 clocks for instr_ack, then de-asserts valid.
    // Returns without waiting for the memory cycle to complete.
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

    // Issue instruction and wait for the first bus cycle to complete.
    task automatic issue_wait(input logic [15:0] iw, input logic has_ext,
                              input logic [31:0] ext);
        issue(iw, has_ext, ext);
        // wait for mem_ack
        repeat(100) begin
            @(posedge clk);
            if (mem_ack) break;
        end
        repeat(3) @(posedge clk);
    endtask

    // Issue instruction and wait for two consecutive bus cycles (PMOVE64).
    task automatic issue_wait2(input logic [15:0] iw, input logic has_ext,
                               input logic [31:0] ext);
        issue(iw, has_ext, ext);
        // wait for first mem_ack
        repeat(100) begin
            @(posedge clk);
            if (mem_ack) break;
        end
        // wait for second mem_ack
        repeat(100) begin
            @(posedge clk);
            if (mem_ack) break;
        end
        repeat(3) @(posedge clk);
    endtask

    // Set Dn to a 32-bit value: CLR.L Dn + ADDI.L #val,Dn
    task automatic set_dn(input int n, input logic [31:0] val);
        issue(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);  // CLR.L Dn
        repeat(3) @(posedge clk);
        issue(16'h0680 | (16'(n) & 16'h7), 1'b1, val);     // ADDI.L #val,Dn
        repeat(3) @(posedge clk);
    endtask

    // Set An via: CLR.L D0 + ADDI.L #val,D0 + MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        // MOVEA.L D0,An: group 2 (MOVEA.L), dst An
        // 0010 aaa 001 000 000 = 0x2040 | (an << 9)
        issue({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
        repeat(3) @(posedge clk);
    endtask

    function automatic [31:0] get_dn(input int n);
        return u_dut.u_seq.wb_result;   // last WB result (use hierarchical in real checks)
    endfunction

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        // init RAM to 0
        for (int i = 0; i < 4096; i++) ram[i] = 32'h0;

        @(posedge rst_n); repeat(2) @(posedge clk);

        // ==================================================================
        // P64-01: MOVES.L (d16,A0),D1  LOAD
        // Opcode: MOVES.L, f_mode=101 (d16,An), f_reg=000 (A0)
        //   = 0000_111_0_10_101_000 = 0x0EA8
        // ext_data = {desc[31:16], d16[15:0]}
        //   desc: D/A=0, Rn=D1=001, dir=1(load) = 0x1800
        //   d16 = 0x0010 (+16)
        // A0=0x100, EA=0x110, ram[0x110/4=68]=0xDEAD_BEEF
        // Expected: D1 = 0xDEAD_BEEF
        // ==================================================================
        $display("--- P64-01: MOVES.L (d16,A0),D1 LOAD ---");
        set_an(3'd0, 32'h0000_0100);
        ram[32'h110 >> 2] = 32'hDEAD_BEEF;

        issue_wait(16'h0EA8, 1'b1, 32'h1800_0010);
        repeat(3) @(posedge clk);
        chk32("P64-01 D1", u_dut.u_rf.d_reg[1], 32'hDEAD_BEEF);

        // ==================================================================
        // P64-02: MOVES.L D1,(d16,A0)  STORE
        // ext_data = {desc[31:16], d16[15:0]}
        //   desc: D/A=0, Rn=D1=001, dir=0(store) = 0x1000
        //   d16 = 0x0020 (+32) → EA = 0x120
        // D1 = 0xDEAD_BEEF (from P64-01), A0 = 0x100
        // Expected: ram[0x120/4=72] = 0xDEAD_BEEF
        // ==================================================================
        $display("--- P64-02: MOVES.L D1,(d16,A0) STORE ---");
        // D1 already has 0xDEAD_BEEF from P64-01

        issue_wait(16'h0EA8, 1'b1, 32'h1000_0020);
        chk32("P64-02 mem[0x120]", ram[32'h120 >> 2], 32'hDEAD_BEEF);

        // ==================================================================
        // P64-03: MOVES.W (d8,A1,D2.L),D3  LOAD
        // Opcode: MOVES.W, f_mode=110, f_reg=001 (A1)
        //   f_ss=01(word): 0000_111_0_01_110_001 = 0x0E71
        // ext_data = {desc, brief}
        //   desc: D/A=0, Rn=D3=011, dir=1(load) = 0x3800
        //   brief: DA=0(D), Xn=010(D2), WL=1(long), scale=00, d8=4
        //          = 0010_1000_0000_0100 = 0x2804
        // A1=0x200, D2=0x20, d8=4 → EA = 0x200+0x20+4 = 0x224
        // ram[0x224/4=137] = 0x0000ABCD (word value 0xABCD)
        // Expected: D3[15:0] = 0xABCD
        // ==================================================================
        $display("--- P64-03: MOVES.W (d8,A1,D2.L),D3 LOAD ---");
        set_an(3'd1, 32'h0000_0200);
        set_dn(2, 32'h0000_0020);
        ram[32'h224 >> 2] = 32'h0000_ABCD;

        issue_wait(16'h0E71, 1'b1, 32'h3800_2804);
        repeat(3) @(posedge clk);
        chk32("P64-03 D3", u_dut.u_rf.d_reg[3], 32'h0000_ABCD);

        // ==================================================================
        // P64-04: MOVES.B (xxx).W,D4  LOAD
        // Opcode: MOVES.B, f_mode=111, f_reg=000
        //   f_ss=00(byte): 0000_111_0_00_111_000 = 0x0E38
        // ext_data = {desc, abs.W}
        //   desc: D/A=0, Rn=D4=100, dir=1(load) = 0x4800
        //   abs.W = 0x0300
        // ram[0x300/4=192] = 0x000000AB
        // Expected: D4[7:0] = 0xAB (byte write, upper preserved)
        // ==================================================================
        $display("--- P64-04: MOVES.B (xxx).W,D4 LOAD ---");
        ram[32'h300 >> 2] = 32'h0000_00AB;

        issue_wait(16'h0E38, 1'b1, 32'h4800_0300);
        repeat(3) @(posedge clk);
        chk32("P64-04 D4", u_dut.u_rf.d_reg[4], 32'h0000_00AB);

        // ==================================================================
        // P64-05: MOVES.W D5,(xxx).W  STORE
        // Opcode: MOVES.W, f_mode=111, f_reg=000
        //   f_ss=01(word): 0000_111_0_01_111_000 = 0x0E78
        // ext_data = {desc, abs.W}
        //   desc: D/A=0, Rn=D5=101, dir=0(store) = 0x5000
        //   abs.W = 0x0400
        // D5 = 0x0000CAFE
        // Expected: ram[0x400/4=256] = 0x0000CAFE
        // ==================================================================
        $display("--- P64-05: MOVES.W D5,(xxx).W STORE ---");
        set_dn(5, 32'h0000_CAFE);

        issue_wait(16'h0E78, 1'b1, 32'h5000_0400);
        chk32("P64-05 mem[0x400]", ram[32'h400 >> 2], 32'h0000_CAFE);

        // ==================================================================
        // P64-06: PMOVE (A0),CRP  — load CRP from memory (2 bus cycles)
        // Opcode: 16'hF010 (f_mode=010/An, f_reg=000=A0)
        // ext_data = 32'h0000_4800
        //   ext[15:13]=010=PMOVE, ext[11:9]=100=CRP, ext[8]=0=EA→reg
        // A0=0x1000
        // ram[0x1000/4=1024] = 0xDEAD_CAFE (CRP hi word)
        // ram[0x1004/4=1025] = 0xBEEF_1234 (CRP lo word)
        // Expected: crp_out = 64'hDEAD_CAFE_BEEF_1234
        // ==================================================================
        $display("--- P64-06: PMOVE (A0),CRP LOAD ---");
        set_an(3'd0, 32'h0000_1000);
        ram[32'h1000 >> 2] = 32'hDEAD_CAFE;
        ram[32'h1004 >> 2] = 32'hBEEF_1234;

        issue_wait2(16'hF010, 1'b1, 32'h0000_4800);
        chk64("P64-06 crp_out", crp_out, 64'hDEAD_CAFE_BEEF_1234);

        // ==================================================================
        // P64-07: PMOVE CRP,(A0)  — write CRP to memory (2 bus cycles)
        // ext_data = 32'h0000_4900
        //   ext[8]=1 → reg→EA (write)
        // CRP from P64-06 = 0xDEAD_CAFE_BEEF_1234
        // Expected: ram[0x1000/4] = 0xDEAD_CAFE, ram[0x1004/4] = 0xBEEF_1234
        // ==================================================================
        $display("--- P64-07: PMOVE CRP,(A0) WRITE ---");
        ram[32'h1000 >> 2] = 32'h0;    // clear first
        ram[32'h1004 >> 2] = 32'h0;

        issue_wait2(16'hF010, 1'b1, 32'h0000_4900);
        chk32("P64-07 crp_hi", ram[32'h1000 >> 2], 32'hDEAD_CAFE);
        chk32("P64-07 crp_lo", ram[32'h1004 >> 2], 32'hBEEF_1234);

        // ==================================================================
        // P64-08: PMOVE (A0),SRP  — load SRP from memory (2 bus cycles)
        // ext_data = 32'h0000_4C00
        //   ext[11:9]=110=SRP, ext[8]=0=EA→reg
        // ram[0x1000/4]=0x1111_2222, ram[0x1004/4]=0x3333_4444
        // Expected: srp_out = 64'h1111_2222_3333_4444
        // ==================================================================
        $display("--- P64-08: PMOVE (A0),SRP LOAD ---");
        ram[32'h1000 >> 2] = 32'h1111_2222;
        ram[32'h1004 >> 2] = 32'h3333_4444;

        issue_wait2(16'hF010, 1'b1, 32'h0000_4C00);
        chk64("P64-08 srp_out", srp_out, 64'h1111_2222_3333_4444);

        // ==================================================================
        // P64-09: PMOVE SRP,(A0)  — write SRP to memory (2 bus cycles)
        // ext_data = 32'h0000_4D00
        //   ext[8]=1 → reg→EA (write)
        // SRP from P64-08 = 0x1111_2222_3333_4444
        // Expected: ram[0x1000/4]=0x1111_2222, ram[0x1004/4]=0x3333_4444
        // ==================================================================
        $display("--- P64-09: PMOVE SRP,(A0) WRITE ---");
        ram[32'h1000 >> 2] = 32'h0;
        ram[32'h1004 >> 2] = 32'h0;

        issue_wait2(16'hF010, 1'b1, 32'h0000_4D00);
        chk32("P64-09 srp_hi", ram[32'h1000 >> 2], 32'h1111_2222);
        chk32("P64-09 srp_lo", ram[32'h1004 >> 2], 32'h3333_4444);

        // ── Summary ──────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: %0d checks passed", pass_cnt);
        else
            $display("FAIL: %0d/%0d checks failed", fail_cnt, pass_cnt + fail_cnt);
        $finish;
    end

    initial #200000 begin
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire

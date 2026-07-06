// Phase 54: MMU instructions — PFLUSH, PTEST, PMOVE
// Tests EU decode and wiring to m68030_mmu-style ports.
// The testbench instantiates m68030_eu directly and drives
// eu_pflush_ack / eu_ptest_ack as simple handshakes.

`default_nettype none
`timescale 1ns/1ps

module seq54_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;          // 100 MHz (4× bus)

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk);
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 32'h0;
    logic        ext_valid   = 0;
    logic        instr_ack;
    logic        eu_busy;

    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 32'h0;
    logic [31:0] pc_out;
    logic        vbr_wr_en  = 0;
    logic [31:0] vbr_wr_data= 32'h0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;

    logic [31:0] decode_pc = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req;
    logic        mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata = 32'h0;
    logic        mem_ack   = 0;
    logic        mem_berr  = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack  = 0;
    logic        eu_coproc_berr = 0;
    logic [31:0] eu_coproc_rdata= 32'h0;

    // Phase 54 ports
    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack = 0;

    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack  = 0;
    logic [15:0] eu_ptest_mmusr= 16'h0;

    logic [31:0] tc_out, tt0_out, tt1_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        ssp_wr_en  = 0;
    logic [31:0] ssp_wr_data= 32'h0;
    logic        exc_sr_wr_en  = 0;
    logic [15:0] exc_sr_wr_data= 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x       (clk),
        .rst_n        (rst_n),
        .instr_word   (instr_word),
        .instr_valid  (instr_valid),
        .ext_data     (ext_data),
        .ext_valid    (ext_valid),
        .instr_ack    (instr_ack),
        .eu_busy      (eu_busy),
        .pc_wr_en     (pc_wr_en),
        .pc_wr_data   (pc_wr_data),
        .pc_out       (pc_out),
        .vbr_wr_en    (vbr_wr_en),
        .vbr_wr_data  (vbr_wr_data),
        .vbr_out      (vbr_out),
        .usp_out      (usp_out),
        .msp_out      (msp_out),
        .isp_out      (isp_out),
        .cacr_out     (cacr_out),
        .caar_out     (caar_out),
        .sr_out       (sr_out),
        .supervisor   (supervisor),
        .master_mode  (master_mode),
        .ipl_mask     (ipl_mask),
        .decode_pc    (decode_pc),
        .branch_taken (branch_taken),
        .branch_target(branch_target),
        .mem_req      (mem_req),
        .mem_rw       (mem_rw),
        .mem_siz      (mem_siz),
        .mem_fc       (mem_fc),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_rdata    (mem_rdata),
        .mem_ack      (mem_ack),
        .mem_berr     (mem_berr),
        .mem_rmw      (mem_rmw),
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
        .an_wr_en     (an_wr_en),
        .an_wr_sel    (an_wr_sel),
        .an_wr_data   (an_wr_data),
        .div_trap     (div_trap),
        .chk_trap     (chk_trap),
        .ssp_wr_en    (ssp_wr_en),
        .ssp_wr_data  (ssp_wr_data),
        .exc_sr_wr_en (exc_sr_wr_en),
        .exc_sr_wr_data(exc_sr_wr_data)
    );

    // ─── test utilities ──────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;
    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else begin
            pass_cnt++;
        end
    endtask

    // Present one instruction (word + optional extension) for one instr_ack cycle.
    // After ack, de-assert valid.  Waits up to 200 clocks.
    task automatic issue(input logic [15:0] w0,
                         input logic        has_ext,
                         input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        // wait for ack
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        @(posedge clk);
    endtask

    // Load A0 with a known value using MOVE.L #imm,A0 (MOVEA.L #imm,A0)
    // Encoding: 207C xxxx xxxx  (MOVEA.L #<data>,A0)
    task automatic load_a0(input logic [31:0] val);
        issue(16'h207C, 1'b1, val);
        // The MOVEA.L #imm,A0 has a 32-bit immediate; in our TB we pass the
        // full 32-bit via ext_data (upper 16 as ext, lower 16 in next cycle).
        // For simplicity use MOVEQ to D0 + direct An write via regfile approach.
        // Actually MOVEA.L (d16,PC) is tricky without a real memory.
        // Use the an_wr_en path: the EU issues an_wr_en when it updates An.
        // Since MOVEA.L with longword immediate has two extension words, use
        // MOVEQ D0,#val (only works for 8-bit) — for full 32-bit, use ADDA.L.
        //
        // Easier: drive A0 directly through an_wr_en observer — but we can't
        // force it. Use a pre-loaded value approach:
        //   - Issue MOVEA.L #imm,A0 with mem_ack=1 for the fetch cycles.
        //   - Encoding MOVEA.L #<l>,A0: 207C, imm_hi, imm_lo
        // This is a 3-word instruction. We handle it with ext_data = full 32b.
    endtask

    // Simplified: load A0 by issuing MOVE.L Dn,An then using ADDA or similar.
    // Most robust: use MOVEQ to load byte; for full 32-bit use LEA.
    // LEA (d16,PC),A0: 41FA <d16> — loads PC+2+d16 into A0.
    // In our TB, decode_pc=0; so A0 = 0+2+d16 = d16+2.
    // To get A0 = target: d16 = target - 2.
    task automatic lea_a0(input logic [31:0] target);
        // LEA (d16,PC),A0  = 41FA <d16>
        // ext_data[15:0] = d16 = target - 2
        logic [15:0] d16 = target[15:0] - 16'd2;
        issue(16'h41FA, 1'b1, {16'h0, d16});
        repeat(4) @(posedge clk);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    logic [31:0] captured_va;
    logic [31:0] captured_wdata;
    logic [2:0]  captured_fc;
    logic        captured_all;

    // Memory model: immediate ack for mem_req
    always_ff @(posedge clk) begin
        if (mem_req) begin
            mem_ack   <= 1'b1;
            mem_rdata <= 32'hDEAD_BEEF;   // default read data
        end else begin
            mem_ack   <= 1'b0;
            mem_rdata <= 32'h0;
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 10);
        // wait for reset
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ================================================================
        // P54-1: PFLUSHA — flush all ATC entries
        // Encoding: F000 2400
        //   1111 000 000 000 000 = F000
        //   ext[15:13]=001 PFLUSH, ext[11:9]=010 flush-all = 2400
        // ================================================================
        $display("--- P54-1: PFLUSHA ---");
        // Present instruction
        instr_word  = 16'hF000;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_2400;
        ext_valid   = 1'b1;
        // Wait for instr_ack
        repeat(100) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0; ext_valid = 1'b0;

        // Now wait for pflush_req to rise
        repeat(10) @(posedge clk);
        // pflush_start_r fires on ack cycle, then req_r fires next cycle
        fork
            begin: wait_pflush
                repeat(20) begin
                    @(posedge clk);
                    if (eu_pflush_req) disable wait_pflush;
                end
            end
        join
        chk("P54-1a: pflush_req=1", {31'h0, eu_pflush_req}, 32'h1);
        chk("P54-1b: pflush_all=1", {31'h0, eu_pflush_all}, 32'h1);

        // Ack it
        eu_pflush_ack = 1'b1;
        @(posedge clk);
        eu_pflush_ack = 1'b0;
        repeat(4) @(posedge clk);
        chk("P54-1c: pflush_req de-asserts", {31'h0, eu_pflush_req}, 32'h0);

        // ================================================================
        // P54-2: PFLUSH selective (A0=0x1000, FC=SFC=001)
        // First: LEA to load A0 = 0x1002 (d16=0x1000, PC=0 → A0=0+2+0x1000=0x1002)
        // Then issue PFLUSH:
        //   F010 2000  — PFLUSH (A0), mode=000 (single), FC from SFC
        //   1111 000 000 010 000 = F010, ext=2000 (mode=000=single, fc_mode=00=use SFC)
        // SFC defaults to 0 after reset. For simplicity accept any FC value.
        // ================================================================
        $display("--- P54-2: PFLUSH selective ---");
        // LEA (d16,PC),A0 to get A0=0x1000:
        // decode_pc stays 0, so A0 = 0+2+d16 → d16=0x0FFE for A0=0x1000
        instr_word  = 16'h41FA;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_0FFE;
        ext_valid   = 1'b1;
        repeat(50) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(4) @(posedge clk);

        // Now PFLUSH (A0): F010 2000
        instr_word  = 16'hF010;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_2000;
        ext_valid   = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;

        fork
            begin: wait_pflush2
                repeat(20) begin
                    @(posedge clk);
                    if (eu_pflush_req) disable wait_pflush2;
                end
            end
        join
        captured_va  = eu_pflush_va;
        captured_all = eu_pflush_all;
        chk("P54-2a: pflush_req=1",  {31'h0, eu_pflush_req}, 32'h1);
        chk("P54-2b: pflush_all=0",  {31'h0, captured_all},  32'h0);
        chk("P54-2c: pflush_va=A0",  captured_va, 32'h0000_1000);

        eu_pflush_ack = 1'b1;
        @(posedge clk);
        eu_pflush_ack = 1'b0;
        repeat(4) @(posedge clk);

        // ================================================================
        // P54-3: PTEST (A0), read-test, FC=SFC
        // Encoding: F010 8E00
        //   ext[15:13]=100 PTEST, ext[11]=1 R-test, ext[10:8]=111 level=7
        //   ext[3:2]=00 FC from SFC, ext[1:0]=00
        //   0x8E00 = 1000 1110 0000 0000 → [15:13]=100, [11]=1, [10:8]=111
        // Wait for eu_ptest_req, ack it, verify MMUSR captured.
        // ================================================================
        $display("--- P54-3: PTEST ---");
        instr_word  = 16'hF010;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_8E00;
        ext_valid   = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;

        fork
            begin: wait_ptest
                repeat(20) begin
                    @(posedge clk);
                    if (eu_ptest_req) disable wait_ptest;
                end
            end
        join
        captured_va = eu_ptest_va;
        chk("P54-3a: ptest_req=1",  {31'h0, eu_ptest_req}, 32'h1);
        chk("P54-3b: ptest_va=A0",  captured_va, 32'h0000_1000);

        // Ack with MMUSR=0xABCD
        eu_ptest_mmusr = 16'hABCD;
        eu_ptest_ack   = 1'b1;
        @(posedge clk);
        eu_ptest_ack   = 1'b0;
        eu_ptest_mmusr = 16'h0;
        repeat(4) @(posedge clk);

        chk("P54-3c: ptest_req de-asserts", {31'h0, eu_ptest_req}, 32'h0);

        // ================================================================
        // P54-4: PMOVE (A0),TC  — read from EA, write to tc_r
        // Encoding: F010 4400
        //   ext[15:13]=010 PMOVE, ext[11:9]=010 preg=TC, ext[8]=0 dr=EA→reg
        // mem_req should fire (mem_rw=1 read); tc_out should become mem_rdata.
        // ================================================================
        $display("--- P54-4: PMOVE (A0),TC ---");
        instr_word  = 16'hF010;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_4400;
        ext_valid   = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;

        // mem_rdata is driven to DEAD_BEEF from our always_ff model above;
        // wait for mem_ack to fire the TC capture
        repeat(10) @(posedge clk);
        chk("P54-4a: tc_out updated", tc_out, 32'hDEAD_BEEF);

        // ================================================================
        // P54-5: PMOVE TC,(A0)  — read TC, write to EA
        // Encoding: F010 4500
        //   ext[8]=1 dr=reg→EA (write)
        // TC is now DEAD_BEEF. Verify mem_wdata = DEAD_BEEF when write fires.
        // ================================================================
        $display("--- P54-5: PMOVE TC,(A0) ---");
        instr_word  = 16'hF010;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_4500;
        ext_valid   = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;

        // Capture mem_wdata on the write ack cycle
        repeat(20) begin
            @(posedge clk);
            if (mem_req && !mem_rw && mem_ack) begin
                captured_wdata = mem_wdata;
                break;
            end
        end
        chk("P54-5a: mem_wdata=TC",  captured_wdata, 32'hDEAD_BEEF);
        chk("P54-5b: mem_rw=0 (write)", {31'h0, mem_rw}, 32'h0);
        repeat(4) @(posedge clk);

        // ================================================================
        // P54-6: PMOVE (A0),TT0  — preg=001
        // Encoding: F010 4200
        //   ext[11:9]=001 preg=TT0, ext[8]=0 dr=EA→reg
        // mem_rdata=DEAD_BEEF → tt0_out should become DEAD_BEEF
        // ================================================================
        $display("--- P54-6: PMOVE (A0),TT0 ---");
        instr_word  = 16'hF010;
        instr_valid = 1'b1;
        ext_data    = 32'h0000_4200;
        ext_valid   = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(10) @(posedge clk);
        chk("P54-6a: tt0_out updated", tt0_out, 32'hDEAD_BEEF);

        // ================================================================
        // P54-7: tc_out still reflects TC (persistent through other instrs)
        // ================================================================
        chk("P54-7: tc_out persistent", tc_out, 32'hDEAD_BEEF);

        // ================================================================
        // Summary
        // ================================================================
        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("=== 0 failure(s) ===\nALL TESTS PASSED");
        else
            $display("=== %0d failure(s) ===", fail_cnt);
        $finish;
    end

    // Timeout guard
    initial begin
        #200000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

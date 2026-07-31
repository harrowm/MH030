`default_nettype none
`timescale 1ns/1ps

// FPU coprocessor bus interface and MMU instruction tests
//
// FPU-01..06: eu_coproc_req handshake, ppp address encoding, BERR, MOVE16 guard
// MMU-01..07: PFLUSH (all / selective), PTEST, PMOVE TC/TT0 read/write

module special_instr_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
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
    logic        mem_berr   = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic [31:0] eu_coproc_rdata = 32'h0;
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack  = 0;

    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack   = 0;
    logic [15:0] eu_ptest_mmusr = 16'h0;

    logic [31:0] tc_out, tt0_out, tt1_out;
    logic [63:0] crp_out, srp_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req, eu_illegal_req;
    logic        eu_stop, eu_reset_req;
    logic        eu_priv_req, eu_trace_req;
    logic        eu_linea_req, eu_linef_req;

    logic        ssp_wr_en     = 0;
    logic [31:0] ssp_wr_data   = 32'h0;
    logic        exc_sr_wr_en  = 0;
    logic [15:0] exc_sr_wr_data= 16'h0;

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

    // Immediate ack; reads return DEAD_BEEF (PMOVE and MOVE16 only care
    // that mem_ack fires, not about specific data values).
    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? 32'hDEAD_BEEF : 32'h0;

    int pass_count = 0, fail_count = 0;

    task automatic chk(input string tag, input logic cond);
        if (!cond) begin
            $display("FAIL %s", tag);
            fail_count++;
        end else
            pass_count++;
    endtask

    task automatic chk32(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    // ── FPU tasks ─────────────────────────────────────────────────────────────

    task automatic wait_coproc_req(input int max_cyc, output logic got);
        got = 0;
        for (int t = 0; t < max_cyc; t++) begin
            @(posedge clk);
            if (eu_coproc_req) begin got = 1; break; end
        end
    endtask

    // Present one Group-F instruction for exactly one posedge then deassert.
    // (Prevents FPU FSM re-triggering after eu_coproc_ack clears.)
    task automatic send_fpu(input logic [15:0] op, input logic [31:0] cir);
        @(posedge clk); #1;
        instr_word  = op; instr_valid = 1'b1;
        ext_data    = cir; ext_valid  = 1'b1;
        @(posedge clk); #1;
        instr_valid = 1'b0; ext_valid = 1'b0;
    endtask

    task ack_coproc;
        @(posedge clk); #1; eu_coproc_ack = 1'b1;
        @(posedge clk); #1; eu_coproc_ack = 1'b0;
    endtask

    task fpu_drain;
        repeat(3) @(posedge clk);
        if (eu_coproc_req) begin ack_coproc; @(posedge clk); end
        repeat(2) @(posedge clk);
    endtask

    // ── MMU tasks ─────────────────────────────────────────────────────────────

    task automatic issue(input logic [15:0] w0, input logic has_ext,
                         input logic [31:0] ext);
        @(posedge clk);
        instr_word = w0; instr_valid = 1'b1;
        ext_data   = ext; ext_valid  = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0; ext_valid = 1'b0;
        @(posedge clk);
    endtask

    // LEA (d16,PC),A0 — loads decode_pc+2+d16 into A0.
    // With decode_pc=0: A0 = 0+2+(target-2) = target.
    task automatic lea_a0(input logic [31:0] target);
        logic [15:0] d16;
        d16 = target[15:0] - 16'd2;
        issue(16'h41FA, 1'b1, {16'h0, d16});
        repeat(4) @(posedge clk);
    endtask

    // ── Test body ─────────────────────────────────────────────────────────────
    initial begin
        logic got_req;
        logic req_held;
        logic saw_coproc, saw_mem;
        logic [31:0] cap_va, cap_wdata;
        logic        cap_all;

        @(posedge rst_n); repeat(4) @(posedge clk);

        // ──────────────────────────────────────────────────────────────────
        // FPU coprocessor bus interface
        // ──────────────────────────────────────────────────────────────────

        // FPU-01: CPI (ppp=000) via -(A0) EA
        // 0xF220 = 1111 001 000 100 000; expected addr 0x0002_0800
        $display("--- FPU-01: CPI (ppp=000) address and handshake ---");
        send_fpu(16'hF220, 32'h0000_04C0);
        wait_coproc_req(10, got_req);
        chk   ("FPU-01a: coproc_req asserts",    got_req);
        chk   ("FPU-01b: rw=1 (read)",           eu_coproc_rw === 1'b1);
        chk   ("FPU-01c: fc=111 (CPU Space)",     eu_coproc_fc === 3'b111);
        chk   ("FPU-01d: A[19:16]=0010",          eu_coproc_addr[19:16] === 4'b0010);
        chk   ("FPU-01e: A[15:13]=000 (CPI)",     eu_coproc_addr[15:13] === 3'b000);
        chk   ("FPU-01f: A[12:11]=01 (cpid=1)",   eu_coproc_addr[12:11] === 2'b01);
        chk32 ("FPU-01g: full CPI addr",           eu_coproc_addr, 32'h0002_0800);
        ack_coproc;
        @(posedge clk);
        chk   ("FPU-01h: req drops after ack",    !eu_coproc_req);
        fpu_drain;

        // FPU-02: eu_coproc_req held high until ack
        $display("--- FPU-02: Req held until ack ---");
        send_fpu(16'hF220, 32'h0000_04C0);
        wait_coproc_req(10, got_req);
        chk("FPU-02a: coproc_req asserts", got_req);
        req_held = 1;
        repeat(3) begin @(posedge clk); if (!eu_coproc_req) req_held = 0; end
        chk("FPU-02b: req held for 3 cycles", req_held);
        ack_coproc;
        @(posedge clk);
        chk("FPU-02c: req drops after ack", !eu_coproc_req);
        fpu_drain;

        // FPU-03: cpScc primitive (ppp=001) — A[15:13] must be 001
        // 0xF260 = 1111 001 001 100 000; expected addr 0x0002_2800
        $display("--- FPU-03: cpScc (ppp=001) address ---");
        send_fpu(16'hF260, 32'h0000_04C0);
        wait_coproc_req(10, got_req);
        chk  ("FPU-03a: coproc_req",           got_req);
        chk  ("FPU-03b: A[15:13]=001 (cpScc)", eu_coproc_addr[15:13] === 3'b001);
        chk32("FPU-03c: full addr",             eu_coproc_addr, 32'h0002_2800);
        ack_coproc;
        fpu_drain;

        // FPU-04: cpBcc primitive (ppp=010) — A[15:13] must be 010
        // 0xF2A0 = 1111 001 010 100 000; expected addr 0x0002_4800
        $display("--- FPU-04: cpBcc (ppp=010) address ---");
        send_fpu(16'hF2A0, 32'h0000_04C0);
        wait_coproc_req(10, got_req);
        chk  ("FPU-04a: coproc_req",           got_req);
        chk  ("FPU-04b: A[15:13]=010 (cpBcc)", eu_coproc_addr[15:13] === 3'b010);
        chk32("FPU-04c: full addr",             eu_coproc_addr, 32'h0002_4800);
        ack_coproc;
        fpu_drain;

        // FPU-05: BERR clears eu_coproc_req
        $display("--- FPU-05: BERR clears coproc_req ---");
        send_fpu(16'hF220, 32'h0000_04C0);
        wait_coproc_req(10, got_req);
        chk("FPU-05a: req asserts before berr", got_req);
        @(posedge clk); #1; eu_coproc_berr = 1'b1;
        @(posedge clk); #1; eu_coproc_berr = 1'b0;
        @(posedge clk);
        chk("FPU-05b: req clears after berr", !eu_coproc_req);
        fpu_drain;

        // FPU-06: MOVE16 uses mem_req, NOT eu_coproc_req (FPU guard must not fire)
        // MOVE16 (A0)+,(A1)+: opcode 0xF208, ext A[14:12]=001(A1)
        $display("--- FPU-06: MOVE16 — no coproc_req, mem_req fires ---");
        dut.u_rf.a_reg[0] = 32'h0000_0100;
        dut.u_rf.a_reg[1] = 32'h0000_0200;
        @(posedge clk); #1;
        instr_word = 16'hF208; instr_valid = 1'b1;
        ext_data   = 32'h0000_9000; ext_valid = 1'b1;
        saw_coproc = 0; saw_mem = 0;
        repeat(20) begin
            @(posedge clk);
            if (eu_coproc_req) saw_coproc = 1;
            if (mem_req)       saw_mem    = 1;
        end
        @(posedge clk); #1; instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(4) @(posedge clk);
        chk("FPU-06a: no coproc_req for MOVE16", !saw_coproc);
        chk("FPU-06b: mem_req fires for MOVE16",  saw_mem);

        // ──────────────────────────────────────────────────────────────────
        // MMU instructions
        // ──────────────────────────────────────────────────────────────────

        // MMU-01: PFLUSHA — flush all ATC entries
        // F000 2400: ext[15:13]=001 PFLUSH, ext[11:9]=010 flush-all
        $display("--- MMU-01: PFLUSHA ---");
        instr_word  = 16'hF000; instr_valid = 1'b1;
        ext_data    = 32'h0000_2400; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(10) @(posedge clk);
        for (int t = 0; t < 20; t++) begin
            @(posedge clk);
            if (eu_pflush_req) break;
        end
        chk("MMU-01a: pflush_req=1", eu_pflush_req === 1'b1);
        chk("MMU-01b: pflush_all=1", eu_pflush_all === 1'b1);
        eu_pflush_ack = 1'b1; @(posedge clk); eu_pflush_ack = 1'b0;
        repeat(4) @(posedge clk);
        chk("MMU-01c: pflush_req de-asserts", eu_pflush_req === 1'b0);

        // MMU-02: PFLUSH selective — flush single entry at A0=0x1000
        // LEA (d16,PC),A0 first; then F010 2000
        $display("--- MMU-02: PFLUSH selective (A0=0x1000) ---");
        lea_a0(32'h0000_1000);
        instr_word  = 16'hF010; instr_valid = 1'b1;
        ext_data    = 32'h0000_2000; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        for (int t = 0; t < 20; t++) begin @(posedge clk); if (eu_pflush_req) break; end
        cap_va  = eu_pflush_va;
        cap_all = eu_pflush_all;
        chk  ("MMU-02a: pflush_req=1",  eu_pflush_req === 1'b1);
        chk  ("MMU-02b: pflush_all=0",  cap_all       === 1'b0);
        chk32("MMU-02c: pflush_va=A0",  cap_va, 32'h0000_1000);
        eu_pflush_ack = 1'b1; @(posedge clk); eu_pflush_ack = 1'b0;
        repeat(4) @(posedge clk);

        // MMU-03: PTEST — read-test with A0=0x1000
        // F010 8E00: ext[15:13]=100 PTEST, ext[11]=1 R-test, ext[10:8]=111 level=7
        $display("--- MMU-03: PTEST ---");
        instr_word  = 16'hF010; instr_valid = 1'b1;
        ext_data    = 32'h0000_8E00; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        for (int t = 0; t < 20; t++) begin @(posedge clk); if (eu_ptest_req) break; end
        cap_va = eu_ptest_va;
        chk  ("MMU-03a: ptest_req=1",  eu_ptest_req === 1'b1);
        chk32("MMU-03b: ptest_va=A0",  cap_va, 32'h0000_1000);
        eu_ptest_mmusr = 16'hABCD; eu_ptest_ack = 1'b1;
        @(posedge clk); eu_ptest_ack = 1'b0; eu_ptest_mmusr = 16'h0;
        repeat(4) @(posedge clk);
        chk("MMU-03c: ptest_req de-asserts", eu_ptest_req === 1'b0);

        // MMU-04: PMOVE (A0),TC — memory read → tc_out
        // F010 4400: ext[15:13]=010 PMOVE, ext[11:9]=010 TC, ext[8]=0 EA→reg
        // mem_rdata=DEAD_BEEF via immediate-ack model
        $display("--- MMU-04: PMOVE (A0),TC ---");
        instr_word  = 16'hF010; instr_valid = 1'b1;
        ext_data    = 32'h0000_4400; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(10) @(posedge clk);
        chk32("MMU-04a: tc_out=mem_rdata", tc_out, 32'hDEAD_BEEF);

        // MMU-05: PMOVE TC,(A0) — tc_out → memory write
        // F010 4500: ext[8]=1 reg→EA (write)
        $display("--- MMU-05: PMOVE TC,(A0) ---");
        instr_word  = 16'hF010; instr_valid = 1'b1;
        ext_data    = 32'h0000_4500; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        cap_wdata = 32'h0;
        repeat(20) begin
            @(posedge clk);
            if (mem_req && !mem_rw && mem_ack) begin cap_wdata = mem_wdata; break; end
        end
        chk32("MMU-05a: mem_wdata=TC",   cap_wdata, 32'hDEAD_BEEF);
        chk  ("MMU-05b: mem_rw=0 write", mem_rw === 1'b0);
        repeat(4) @(posedge clk);

        // MMU-06: PMOVE (A0),TT0 — memory read → tt0_out
        // F010 4200: ext[11:9]=001 TT0, ext[8]=0 EA→reg
        $display("--- MMU-06: PMOVE (A0),TT0 ---");
        instr_word  = 16'hF010; instr_valid = 1'b1;
        ext_data    = 32'h0000_4200; ext_valid = 1'b1;
        repeat(100) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(10) @(posedge clk);
        chk32("MMU-06a: tt0_out=mem_rdata", tt0_out, 32'hDEAD_BEEF);

        // MMU-07: TC still holds its value after other instructions
        chk32("MMU-07: tc_out persistent", tc_out, 32'hDEAD_BEEF);

        $display("");
        if (fail_count == 0)
            $display("PASS: %0d checks passed", pass_count);
        else
            $display("FAIL: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule

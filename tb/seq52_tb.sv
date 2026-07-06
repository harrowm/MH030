`default_nettype none
`timescale 1ps/1ps

// Phase 52 testbench — FPU coprocessor bus interface (EU side)
//
// Verifies that eu_seq detects Group F / cpid=1 FPU opcodes and:
//   1. Asserts eu_coproc_req with FC=111 (CPU Space)
//   2. Drives address: A[19:16]=0010, A[15:13]=ppp, A[12:11]=01 (cpid=1)
//   3. Deasserts eu_coproc_req when eu_coproc_ack fires
//   4. Pipeline stalls while coproc cycle is in progress
//
// Timing note: instr_ack is a one-cycle pulse at the decode posedge (the same
// posedge where fpu_start_r is latched via non-blocking assignment).  Reading
// at #1 after that posedge misses the pulse.  We avoid this by:
//   a) Presenting the instruction for exactly one posedge, then deasserting
//      instr_valid so the FPU cannot re-trigger after eu_coproc_ack clears.
//   b) Using eu_coproc_req (registered, stays high until ack) as the test
//      observable instead of the one-cycle instr_ack pulse.
//
// Opcode encoding (Group F, cpid=1):
//   [15:12]=1111, [11:9]=001 (cpid), [8:6]=ppp, [5:3]=EA mode, [2:0]=EA reg
// Unambiguous FPU EA modes (no MOVE16 conflict): mode 4-7 (f_mode[2]=1).
//   EA mode 100 (-(An)): f_mode=100.
//
// Test opcodes:
//   0xF220 = 1111 001 000 100 000: ppp=000 (cpGEN/CPI),  EA=-(A0)
//   0xF260 = 1111 001 001 100 000: ppp=001 (cpScc/cpDB), EA=-(A0)
//   0xF2A0 = 1111 001 010 100 000: ppp=010 (cpBcc),      EA=-(A0)
//
// Coprocessor address: A[19:16]=0010, A[15:13]=ppp, A[12:11]=01, A[10:0]=0
//   ppp=000: 0x0002_0800   ppp=001: 0x0002_2800   ppp=010: 0x0002_4800

`define DR(n)   u_dut.u_rf.d_reg[n]
`define AR(n)   u_dut.u_rf.a_reg[n]

module seq52_tb;

    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;
    logic        instr_ack, eu_busy;
    logic [31:0] decode_pc   = 0;

    logic [31:0] pc_out, vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap, chk_trap;
    logic        branch_taken;
    logic [31:0] branch_target;

    // Memory bus — immediate ack so MOVE16 (P52-6) completes.
    // For FPU tests, mem_req=0 (FPU drives eu_coproc_req, not mem_req).
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;
    logic [31:0] ram [0:511];

    assign mem_ack   = mem_req;
    assign mem_berr  = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[10:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw) ram[mem_addr[10:2]] <= mem_wdata;

    // Coprocessor interface — testbench drives rdata/ack/berr
    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic [31:0] eu_coproc_rdata = 32'h0;
    logic        eu_coproc_ack   = 1'b0;
    logic        eu_coproc_berr  = 1'b0;

    logic an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    m68030_eu u_dut (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .ext_valid      (ext_valid),
        .instr_ack      (instr_ack),
        .eu_busy        (eu_busy),
        .pc_wr_en       (1'b0),
        .pc_wr_data     (32'h0),
        .pc_out         (pc_out),
        .vbr_wr_en      (1'b0),
        .vbr_wr_data    (32'h0),
        .vbr_out        (vbr_out),
        .usp_out        (usp_out),
        .msp_out        (msp_out),
        .isp_out        (isp_out),
        .cacr_out       (),
        .caar_out       (),
        .sr_out         (sr_out),
        .supervisor     (supervisor),
        .master_mode    (master_mode),
        .ipl_mask       (ipl_mask),
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
        .mem_rmw        (),
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .an_wr_en       (an_wr_en),
        .an_wr_sel      (an_wr_sel),
        .an_wr_data     (an_wr_data),
        .div_trap       (div_trap),
        .chk_trap       (chk_trap),
        .ssp_wr_en      (1'b0),
        .ssp_wr_data    (32'h0),
        .exc_sr_wr_en   (1'b0),
        .exc_sr_wr_data (16'h0)
    );

    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  [%0t] %s", $time, name);
        else begin
            $display("FAIL  [%0t] %s", $time, name);
            fail_count++;
        end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  [%0t] %s (got %08h)", $time, name, got);
        else begin
            $display("FAIL  [%0t] %s: got %08h  exp %08h", $time, name, got, exp);
            fail_count++;
        end
    endtask

    // Wait for eu_coproc_req (registered — safe to read at posedge without #1).
    task automatic wait_coproc_req(input int max_cyc, output logic got);
        got = 0;
        for (int t = 0; t < max_cyc; t++) begin
            @(posedge clk_4x);
            if (eu_coproc_req) begin got = 1; break; end
        end
    endtask

    // Send one FPU instruction: present for exactly one posedge then deassert.
    // This prevents the FPU FSM from re-triggering after eu_coproc_ack clears.
    task automatic send_fpu(input logic [15:0] op, input logic [31:0] cir);
        @(posedge clk_4x); #1;
        instr_word  = op;
        instr_valid = 1'b1;
        ext_data    = cir;
        ext_valid   = 1'b1;
        @(posedge clk_4x); #1;    // instr_ack fires at this posedge; fpu_start_r latched
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
    endtask

    // Acknowledge the in-flight coproc cycle and wait for req to drop.
    task ack_coproc;
        @(posedge clk_4x); #1;
        eu_coproc_ack = 1'b1;
        @(posedge clk_4x); #1;
        eu_coproc_ack = 1'b0;
    endtask

    // Safety drain between tests: let FSM settle, ack any residual cycle.
    task fpu_drain;
        @(posedge clk_4x);
        @(posedge clk_4x);
        @(posedge clk_4x);         // let fpu_start_r→fpu_run_r propagate
        if (eu_coproc_req) begin
            ack_coproc;
            @(posedge clk_4x);
        end
        repeat(2) @(posedge clk_4x);
    endtask

    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 52: FPU Coprocessor Bus Interface ===");

        repeat(4) @(posedge clk_4x);
        rst_n = 1'b1;
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // P52-1: CPI (ppp=000) — cpGEN general FPU instruction
        // Opcode 0xF220 = 1111 001 000 100 000
        //   f_dir=0, f_ss=00 → ppp=000 (cpGEN); f_mode=100 (-(A0))
        // Expected coproc address: A[19:16]=0010, A[15:13]=000, A[12:11]=01
        //   = 0x0002_0800
        // ----------------------------------------------------------------
        $display("--- P52-1: CPI (ppp=000) cpGEN via -(A0) EA ---");
        begin
            logic got_req;
            send_fpu(16'hF220, 32'h0000_04C0);
            wait_coproc_req(10, got_req);
            check("P52-1a: eu_coproc_req asserts",        got_req);
            check("P52-1b: eu_coproc_rw=1 (read)",        eu_coproc_rw === 1'b1);
            check("P52-1c: eu_coproc_fc=111 (CPU Space)", eu_coproc_fc === 3'b111);
            check("P52-1d: A[19:16]=0010 (coproc)",       eu_coproc_addr[19:16] === 4'b0010);
            check("P52-1e: A[15:13]=000 (CPI prim)",      eu_coproc_addr[15:13] === 3'b000);
            check("P52-1f: A[12:11]=01 (cpid=1)",         eu_coproc_addr[12:11] === 2'b01);
            check32("P52-1g: full CPI addr",               eu_coproc_addr, 32'h0002_0800);
            ack_coproc;
            @(posedge clk_4x);
            check("P52-1h: req drops after ack",          !eu_coproc_req);
        end
        fpu_drain;

        // ----------------------------------------------------------------
        // P52-2: eu_coproc_req stays high until ack fires (verifies stall)
        // ----------------------------------------------------------------
        $display("--- P52-2: Coproc req held until ack ---");
        begin
            logic got_req;
            logic req_held;
            send_fpu(16'hF220, 32'h0000_04C0);
            wait_coproc_req(10, got_req);
            check("P52-2a: coproc_req asserts", got_req);
            req_held = 1;
            repeat(3) begin
                @(posedge clk_4x);
                if (!eu_coproc_req) req_held = 0;
            end
            check("P52-2b: req held for 3 cycles (stall)", req_held);
            ack_coproc;
            @(posedge clk_4x);
            check("P52-2c: req drops after ack", !eu_coproc_req);
        end
        fpu_drain;

        // ----------------------------------------------------------------
        // P52-3: cpScc (ppp=001) — A[15:13] must be 001
        // Opcode 0xF260 = 1111 001 001 100 000
        //   f_dir=0, f_ss=01 → ppp=001; f_mode=100 (-(A0))
        // Expected address: 0x0002_2800
        // ----------------------------------------------------------------
        $display("--- P52-3: cpScc prim (ppp=001) address check ---");
        begin
            logic got_req;
            send_fpu(16'hF260, 32'h0000_04C0);
            wait_coproc_req(10, got_req);
            check("P52-3a: coproc_req for ppp=001",    got_req);
            check("P52-3b: A[15:13]=001 (cpScc prim)", eu_coproc_addr[15:13] === 3'b001);
            check("P52-3c: A[12:11]=01 (cpid=1)",      eu_coproc_addr[12:11] === 2'b01);
            check32("P52-3d: full addr for ppp=001",    eu_coproc_addr, 32'h0002_2800);
            ack_coproc;
        end
        fpu_drain;

        // ----------------------------------------------------------------
        // P52-4: cpBcc (ppp=010) — A[15:13] must be 010
        // Opcode 0xF2A0 = 1111 001 010 100 000
        //   f_dir=0, f_ss=10 → ppp=010; f_mode=100 (-(A0))
        // Expected address: 0x0002_4800
        // ----------------------------------------------------------------
        $display("--- P52-4: cpBcc prim (ppp=010) address check ---");
        begin
            logic got_req;
            send_fpu(16'hF2A0, 32'h0000_04C0);
            wait_coproc_req(10, got_req);
            check("P52-4a: coproc_req for ppp=010",    got_req);
            check("P52-4b: A[15:13]=010 (cpBcc prim)", eu_coproc_addr[15:13] === 3'b010);
            check32("P52-4c: full addr for ppp=010",    eu_coproc_addr, 32'h0002_4800);
            ack_coproc;
        end
        fpu_drain;

        // ----------------------------------------------------------------
        // P52-5: BERR on coproc cycle — FSM must clear eu_coproc_req
        // ----------------------------------------------------------------
        $display("--- P52-5: BERR clears eu_coproc_req ---");
        begin
            logic got_req;
            send_fpu(16'hF220, 32'h0000_04C0);
            wait_coproc_req(10, got_req);
            check("P52-5a: coproc_req asserts before berr", got_req);
            @(posedge clk_4x); #1;
            eu_coproc_berr = 1'b1;
            @(posedge clk_4x); #1;
            eu_coproc_berr = 1'b0;
            @(posedge clk_4x);
            check("P52-5b: req clears after berr", !eu_coproc_req);
        end
        fpu_drain;

        // ----------------------------------------------------------------
        // P52-6: MOVE16 decode not broken by the FPU !f_mode[2] guard.
        // MOVE16 (A0)+,(A1)+: opcode 0xF208, ext 0x0000_9000 (Am=A1 at [14:12])
        //   f_mode=001 (f_mode[2]=0) → MOVE16 path, NOT FPU.
        // Verify: eu_coproc_req never asserts; mem_req does.
        // ----------------------------------------------------------------
        $display("--- P52-6: MOVE16 decode not broken by FPU guard ---");
        begin
            `AR(0) = 32'h0000_0100;
            `AR(1) = 32'h0000_0200;

            @(posedge clk_4x); #1;
            instr_word  = 16'hF208;    // MOVE16 (A0)+,(A1)+
            instr_valid = 1'b1;
            ext_data    = 32'h0000_9000;  // Am=A1 at ext[14:12]=001
            ext_valid   = 1'b1;

            // MOVE16 uses mem_req (not eu_coproc_req). Immediate mem_ack completes it.
            begin
                logic saw_coproc_req;
                logic saw_mem_req;
                saw_coproc_req = 0;
                saw_mem_req    = 0;
                repeat(20) begin
                    @(posedge clk_4x);
                    if (eu_coproc_req) saw_coproc_req = 1;
                    if (mem_req)       saw_mem_req     = 1;
                end
                check("P52-6a: no coproc_req for MOVE16",    !saw_coproc_req);
                check("P52-6b: mem_req asserted for MOVE16",  saw_mem_req);
            end
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            ext_valid   = 1'b0;
            repeat(4) @(posedge clk_4x);
        end

        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

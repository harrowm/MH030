`default_nettype none
`timescale 1ns/1ps

// Phase 48 testbench: CHK, CMP2, CHK2
//
// Instruction encodings used:
//   CHK.W Dn_ub, Dn_chk: 0100 DDD1 10 000 rrr  (DDD=Dn_chk, rrr=Dn_ub)
//   CHK.L Dn_ub, Dn_chk: 0100 DDD1 00 000 rrr
//   CHK.W #imm, Dn:      0100 DDD1 10 111 100  + ext (bound in ext_data[15:0])
//   CMP2.L (An),Rn:      0000 100 0 11 010 nnn + ext ([15]=D/A, [14:12]=Rn, [11]=0)
//   CHK2.L (An),Rn:      0000 100 0 11 010 nnn + ext ([11]=1)

module seq48_tb;

    localparam CLK_HALF = 5;  // 100 MHz

    logic clk_4x, rst_n;
    initial clk_4x = 0;
    always #CLK_HALF clk_4x = ~clk_4x;

    // ── DUT wires ────────────────────────────────────────────────────────────
    logic [15:0] instr_word;
    logic        instr_valid, instr_ack;
    logic [31:0] ext_data;
    logic        ext_valid;
    logic        eu_busy;
    logic        branch_taken;
    logic [31:0] branch_target;
    logic [31:0] decode_pc;

    logic        mem_req, mem_rw, mem_rmw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;
    logic        div_trap, chk_trap;

    logic        pc_wr_en;
    logic [31:0] pc_wr_data, pc_out;
    logic        vbr_wr_en;
    logic [31:0] vbr_wr_data, vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        ssp_wr_en;
    logic [31:0] ssp_wr_data;
    logic        exc_sr_wr_en;
    logic [15:0] exc_sr_wr_data;

    assign pc_wr_en       = 1'b0;
    assign pc_wr_data     = 32'h0;
    assign vbr_wr_en      = 1'b0;
    assign vbr_wr_data    = 32'h0;
    assign ssp_wr_en      = 1'b0;
    assign ssp_wr_data    = 32'h0;
    assign exc_sr_wr_en   = 1'b0;
    assign exc_sr_wr_data = 16'h0;
    assign decode_pc      = 32'h0;
    assign mem_berr       = 1'b0;

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
        .an_wr_en      (an_wr_en),
        .an_wr_sel     (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .div_trap      (div_trap),
        .chk_trap      (chk_trap),
        .ssp_wr_en     (ssp_wr_en),
        .ssp_wr_data   (ssp_wr_data),
        .exc_sr_wr_en  (exc_sr_wr_en),
        .exc_sr_wr_data(exc_sr_wr_data)
    );

    // ── Memory model (zero-wait-state) ───────────────────────────────────────
    logic [31:0] mem_store [0:63];
    integer mi;
    initial for (mi = 0; mi < 64; mi++) mem_store[mi] = 32'h0;

    assign mem_rdata = mem_req && mem_rw ? mem_store[mem_addr[7:2]] : 32'h0;
    assign mem_ack   = mem_req;

    always @(posedge clk_4x) begin
        if (mem_req && !mem_rw)
            mem_store[mem_addr[7:2]] <= mem_wdata;
    end

    // ── chk_trap pulse counter ────────────────────────────────────────────────
    integer chk_trap_cnt;
    always @(posedge clk_4x) begin
        if (!rst_n) chk_trap_cnt <= 0;
        else if (chk_trap) chk_trap_cnt <= chk_trap_cnt + 1;
    end

    // ── Helpers ───────────────────────────────────────────────────────────────
    integer pass_count, fail_count;

    task check;
        input [63:0] got;
        input [63:0] exp;
        input [127:0] label;
        begin
            if (got === exp)
                pass_count = pass_count + 1;
            else begin
                $display("FAIL  %s: got %08h  exp %08h", label, got[31:0], exp[31:0]);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Load a 32-bit value into Dn (CLR.L then ADDI.L #val, Dn)
    task set_dn;
        input [2:0] n;
        input [31:0] val;
        begin
            instr_word  = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, n};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
            instr_word  = {4'h0, 3'b011, 1'b0, 2'b10, 3'b000, n};
            instr_valid = 1'b1; ext_data = val; ext_valid = 1'b1;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0; ext_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Load address into An (via D0 then MOVEA.L D0, An)
    task set_an;
        input [2:0] n;
        input [31:0] val;
        begin
            set_dn(3'd0, val);
            instr_word  = {4'h2, n, 3'b001, 3'b000, 3'b000};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Issue one instruction (with optional ext word) and wait for completion
    task run_instr;
        input [15:0] iw;
        input [31:0] ext;
        input        has_ext;
        begin
            instr_word  = iw;
            ext_data    = ext;
            ext_valid   = has_ext;
            instr_valid = 1'b1;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            ext_valid   = 1'b0;
            @(posedge clk_4x); #1;
            while (eu_busy) begin
                @(posedge clk_4x); #1;
            end
            @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    `define SR_N (sr_out[3])
    `define SR_Z (sr_out[2])
    `define SR_V (sr_out[1])
    `define SR_C (sr_out[0])

    // ── Test body ─────────────────────────────────────────────────────────────
    integer trap_before;

    initial begin
        pass_count = 0;
        fail_count = 0;
        instr_word  = 16'h4E71;
        instr_valid = 1'b0;
        ext_data    = 32'h0;
        ext_valid   = 1'b0;

        rst_n = 1'b0;
        repeat(4) @(posedge clk_4x);
        #1; rst_n = 1'b1;
        repeat(4) @(posedge clk_4x);

        // ============================================================
        // CHK.W Dn,Dn — register direct
        // CHK.W D1,D0: opcode = 0100 000 1 10 000 001 = 0x4181
        // D0=checked value, D1=upper bound
        // ============================================================

        // Test 1: D0=5, D1=10 → in range [0..10], no trap
        set_dn(3'd0, 32'd5);
        set_dn(3'd1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd0, "CHK.W Dn in-range: no trap");
        check(`SR_N, 1'b0, "CHK.W Dn in-range: N=0");

        // Test 2: D0=15, D1=10 → above upper bound → trap
        set_dn(3'd0, 32'd15);
        set_dn(3'd1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd1, "CHK.W Dn above bound: trap");
        check(`SR_N, 1'b0, "CHK.W Dn above bound: N=0");

        // Test 3: D0=0xFFFF_FFFE (-2 signed), D1=10 → below 0 → trap, N=1
        set_dn(3'd0, 32'hFFFFFFFE);
        set_dn(3'd1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd1, "CHK.W Dn negative: trap");
        check(`SR_N, 1'b1, "CHK.W Dn negative: N=1");

        // Test 4: D0=0, D1=0 → 0 in [0..0], no trap
        set_dn(3'd0, 32'd0);
        set_dn(3'd1, 32'd0);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd0, "CHK.W Dn zero bound: no trap");

        // ============================================================
        // CHK.L Dn,Dn — longword
        // CHK.L D1,D0: opcode = 0100 000 1 00 000 001 = 0x4101
        // ============================================================

        // Test 5: D0=100, D1=1000 → in range, no trap
        set_dn(3'd0, 32'd100);
        set_dn(3'd1, 32'd1000);
        trap_before = chk_trap_cnt;
        run_instr(16'h4101, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd0, "CHK.L Dn in-range: no trap");

        // Test 6: D0=0x80000001 (large negative), D1=1000 → below 0 → trap, N=1
        set_dn(3'd0, 32'h80000001);
        set_dn(3'd1, 32'd1000);
        trap_before = chk_trap_cnt;
        run_instr(16'h4101, 32'h0, 1'b0);
        check(chk_trap_cnt - trap_before, 64'd1, "CHK.L Dn large neg: trap");
        check(`SR_N, 1'b1, "CHK.L Dn large neg: N=1");

        // ============================================================
        // CHK.W #imm, Dn
        // CHK.W #10, D0: opcode = 0100 000 1 10 111 100 = 0x41BC + ext=10
        // D0=checked, upper bound from immediate
        // ============================================================

        // Test 7: D0=5, #10 → in range, no trap
        set_dn(3'd0, 32'd5);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 32'h0000000A, 1'b1);
        check(chk_trap_cnt - trap_before, 64'd0, "CHK.W imm in-range: no trap");

        // Test 8: D0=20, #10 → above bound → trap
        set_dn(3'd0, 32'd20);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 32'h0000000A, 1'b1);
        check(chk_trap_cnt - trap_before, 64'd1, "CHK.W imm above bound: trap");

        // Test 9: D0=0 in range [0..0], #0 → no trap
        set_dn(3'd0, 32'd0);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 32'h00000000, 1'b1);
        check(chk_trap_cnt - trap_before, 64'd0, "CHK.W imm zero: no trap");

        // ============================================================
        // CMP2.L (A0),D0 — two memory reads: lower at A0, upper at A0+4
        // CMP2.L (A0),D0: instr = 0000 0100 11 010 000 = 0x04D0  (f_dn=010, !f_dn[2])
        //                 ext   = {D(0), D0(000), CMP2(0), ...} = 0x0000
        // Set up: mem_store[A0>>2] = lower_bound, mem_store[(A0>>2)+1] = upper_bound
        // ============================================================

        // A0 = 0x08 → mem_store[2]=lower, mem_store[3]=upper
        set_an(3'd0, 32'h00000008);
        mem_store[2] = 32'h0000_000A;  // lower bound = 10
        mem_store[3] = 32'h0000_0064;  // upper bound = 100

        // Test 10: D0=50, range [10..100] → in range, C=0, Z=0
        set_dn(3'd0, 32'd50);
        run_instr(16'h04D0, 32'h0000, 1'b1);
        check(`SR_C, 1'b0, "CMP2.L in-range: C=0");
        check(`SR_Z, 1'b0, "CMP2.L in-range: Z=0");

        // Test 11: D0=10 (equals lower bound) → Z=1, C=0
        set_dn(3'd0, 32'd10);
        run_instr(16'h04D0, 32'h0000, 1'b1);
        check(`SR_C, 1'b0, "CMP2.L eq lower: C=0");
        check(`SR_Z, 1'b1, "CMP2.L eq lower: Z=1");

        // Test 12: D0=100 (equals upper bound) → Z=1, C=0
        set_dn(3'd0, 32'd100);
        run_instr(16'h04D0, 32'h0000, 1'b1);
        check(`SR_C, 1'b0, "CMP2.L eq upper: C=0");
        check(`SR_Z, 1'b1, "CMP2.L eq upper: Z=1");

        // Test 13: D0=5 (below lower) → C=1
        set_dn(3'd0, 32'd5);
        run_instr(16'h04D0, 32'h0000, 1'b1);
        check(`SR_C, 1'b1, "CMP2.L below lower: C=1");

        // Test 14: D0=150 (above upper) → C=1
        set_dn(3'd0, 32'd150);
        run_instr(16'h04D0, 32'h0000, 1'b1);
        check(`SR_C, 1'b1, "CMP2.L above upper: C=1");

        // ============================================================
        // CHK2.L (A0),D0 — same as CMP2 but ext[11]=1 → fires chk_trap if C=1
        // CHK2.L (A0),D0: instr = 0x04D0, ext = 0x0800 (bit 11 set)
        // ============================================================

        // bounds still: lower=10, upper=100 (mem_store[2/3] unchanged)

        // Test 15: D0=50 (in range) → no trap
        set_dn(3'd0, 32'd50);
        trap_before = chk_trap_cnt;
        run_instr(16'h04D0, 32'h0800, 1'b1);
        check(`SR_C, 1'b0, "CHK2.L in-range: C=0");
        check(chk_trap_cnt - trap_before, 64'd0, "CHK2.L in-range: no trap");

        // Test 16: D0=5 (out of range) → trap fires, C=1
        set_dn(3'd0, 32'd5);
        trap_before = chk_trap_cnt;
        run_instr(16'h04D0, 32'h0800, 1'b1);
        check(`SR_C, 1'b1, "CHK2.L out-range: C=1");
        check(chk_trap_cnt - trap_before, 64'd1, "CHK2.L out-range: trap");

        // ============================================================
        // Summary
        // ============================================================
        $display("seq48: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

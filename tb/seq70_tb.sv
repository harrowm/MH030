// Phase 70: JSR/JMP indexed EA; trace T1/T0; privilege/line-A/line-F routing
//
//   P70-01: JSR (d8,A0,D1.W)  — push return PC to ISP-4, jump to A0+d8+D1
//   P70-02: JSR (d8,PC,D2.W)  — push return PC, jump to (PC+2+d8)+D2
//   P70-03: Trace T1           — eu_trace_req fires after NOP
//   P70-04: Trace T0           — fires after JMP only, not after NOP
//   P70-05: Privilege violation — eu_priv_req fires for STOP in user mode
//   P70-06: Line-A opcode      — eu_linea_req fires for 0xA000
//   P70-07: Line-F non-FPU     — eu_linef_req fires for 0xF400

`default_nettype none
`timescale 1ns/1ps

module seq70_tb;

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
    logic        mem_berr  = 0;
    logic        mem_rmw;

    logic        eu_coproc_req, eu_coproc_rw;
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

    logic        ssp_wr_en     = 0;
    logic [31:0] ssp_wr_data   = 32'h0;
    logic        exc_sr_wr_en  = 0;
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
        .eu_priv_req     (eu_priv_req),
        .eu_trace_req    (eu_trace_req),
        .eu_linea_req    (eu_linea_req),
        .eu_linef_req    (eu_linef_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model ────────────────────────────────────────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── Branch / exception pulse counters ───────────────────────────────────
    int branch_cnt;
    logic [31:0] branch_target_last;
    int trace_req_cnt;
    int priv_req_cnt;
    int linea_req_cnt;
    int linef_req_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            branch_cnt        <= 0;
            branch_target_last <= 32'h0;
            trace_req_cnt     <= 0;
            priv_req_cnt      <= 0;
            linea_req_cnt     <= 0;
            linef_req_cnt     <= 0;
        end else begin
            if (branch_taken) begin
                branch_cnt         <= branch_cnt + 1;
                branch_target_last <= branch_target;
            end
            if (eu_trace_req) trace_req_cnt <= trace_req_cnt + 1;
            if (eu_priv_req)  priv_req_cnt  <= priv_req_cnt  + 1;
            if (eu_linea_req) linea_req_cnt <= linea_req_cnt + 1;
            if (eu_linef_req) linef_req_cnt <= linef_req_cnt + 1;
        end
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
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
        repeat(300) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(16) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    task automatic set_isp(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk); #1;
        ssp_wr_en = 0;
        @(posedge clk); #1;
    endtask

    task automatic set_sr(input logic [15:0] val);
        @(posedge clk); #1;
        exc_sr_wr_data = val; exc_sr_wr_en = 1;
        @(posedge clk); #1;
        exc_sr_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        int base_branch, base_trace, base_priv, base_linea, base_linef;

        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;

        @(posedge rst_n); repeat(2) @(posedge clk);

        // ====================================================================
        // P70-01: JSR (d8,A0,D1.W*1)
        //   Opcode 4EB0: JSR mode=6 f_reg=0 → An=A0  (bits[7:6]=10 → JSR; 11 → JMP)
        //   ext 0x1008: {D1(001), .W(0), *1(00), 0, d8=0x08}
        //   A0=0x3000, D1=0x20, ISP=0x1000, decode_pc=0x5000
        //   Target = 0x3000 + 0x08 + 0x20 = 0x3028
        //   Return PC = 0x5004; push to 0x0FFC; ISP → 0x0FFC
        // ====================================================================
        $display("--- P70-01: JSR (d8,A0,D1.W) ---");
        set_an(3'h0, 32'h0000_3000);
        set_dn(1, 32'h0000_0020);
        set_isp(32'h0000_1000);
        decode_pc   = 32'h0000_5000;
        base_branch = branch_cnt;
        run_instr(16'h4EB0, 1'b1, 32'h0000_1008);   // JSR (d8,A0,D1.W) d8=+8
        decode_pc = 32'h0;
        chk ("P70-01:push[0x0FFC]",    ram[32'h0FFC >> 2],  32'h0000_5004);
        chk ("P70-01:isp",             isp_out,              32'h0000_0FFC);
        chk ("P70-01:branch_target",   branch_target_last,   32'h0000_3028);
        chk ("P70-01:branch_cnt",      branch_cnt - base_branch, 32'd1);

        // ====================================================================
        // P70-02: JSR (d8,PC,D2.W*1)
        //   Opcode 4EBB: JSR mode=7 f_reg=3 → PC-indexed  (bits[7:6]=10 → JSR)
        //   ext 0x2010: {D2(010), .W(0), *1(00), 0, d8=0x10}
        //   D2=0x40, ISP=0x1000, decode_pc=0x6000
        //   Target = (0x6000+2+0x10) + 0x40 = 0x6052
        //   Return PC = 0x6004; push to 0x0FFC; ISP → 0x0FFC
        // ====================================================================
        $display("--- P70-02: JSR (d8,PC,D2.W) ---");
        set_dn(2, 32'h0000_0040);
        set_isp(32'h0000_1000);
        decode_pc   = 32'h0000_6000;
        base_branch = branch_cnt;
        run_instr(16'h4EBB, 1'b1, 32'h0000_2010);   // JSR (d8,PC,D2.W) d8=+0x10
        decode_pc = 32'h0;
        chk ("P70-02:push[0x0FFC]",    ram[32'h0FFC >> 2],  32'h0000_6004);
        chk ("P70-02:isp",             isp_out,              32'h0000_0FFC);
        chk ("P70-02:branch_target",   branch_target_last,   32'h0000_6052);
        chk ("P70-02:branch_cnt",      branch_cnt - base_branch, 32'd1);

        // ====================================================================
        // P70-03: Trace T1 — eu_trace_req fires after every valid instruction
        //   SR = 0xA700: T1=1, S=1, IPL=7
        //   Run NOP (4E71) — eu_trace_req must fire exactly once
        // ====================================================================
        $display("--- P70-03: Trace T1 ---");
        set_sr(16'hA700);
        base_trace = trace_req_cnt;
        run_instr(16'h4E71, 1'b0, 32'h0);
        chk ("P70-03:trace_T1_fired",  trace_req_cnt - base_trace, 32'd1);
        set_sr(16'h2700);   // restore normal SR (no trace)

        // ====================================================================
        // P70-04: Trace T0 — fires only for flow-change instructions
        //   SR = 0x6700: T0=1, S=1, IPL=7
        //   NOP → trace must NOT fire; JMP (A0) → trace must fire
        // ====================================================================
        $display("--- P70-04: Trace T0 ---");
        set_sr(16'h6700);
        base_trace = trace_req_cnt;
        run_instr(16'h4E71, 1'b0, 32'h0);              // NOP — not flow-change
        chk ("P70-04:T0_NOP_no_trace", trace_req_cnt - base_trace, 32'd0);
        // Set A0 for JMP target (CLR/ADDI/MOVEA are not flow-change — no trace)
        set_an(3'h0, 32'h0000_7000);
        base_trace = trace_req_cnt;
        run_instr(16'h4ED0, 1'b0, 32'h0);              // JMP (A0) — flow-change
        chk ("P70-04:T0_JMP_trace",    trace_req_cnt - base_trace, 32'd1);
        set_sr(16'h2700);   // restore normal SR

        // ====================================================================
        // P70-05: Privilege violation — STOP in user mode
        //   SR = 0x0000: S=0 (user mode), no trace
        //   4E72 (STOP) → dec_is_priv=1 → eu_priv_req fires; no ext word needed
        // ====================================================================
        $display("--- P70-05: Privilege violation (STOP in user) ---");
        set_sr(16'h0000);
        base_priv = priv_req_cnt;
        run_instr(16'h4E72, 1'b0, 32'h0);
        chk ("P70-05:priv_req_fired",  priv_req_cnt - base_priv, 32'd1);
        set_sr(16'h2700);   // restore supervisor

        // ====================================================================
        // P70-06: Line-A opcode → eu_linea_req (vector 10)
        //   0xA000: bits[15:12]=1010 → Group A → dec_is_linea=1
        // ====================================================================
        $display("--- P70-06: Line-A opcode ---");
        base_linea = linea_req_cnt;
        run_instr(16'hA000, 1'b0, 32'h0);
        chk ("P70-06:linea_req_fired", linea_req_cnt - base_linea, 32'd1);

        // ====================================================================
        // P70-07: Line-F non-FPU/MMU/MOVE16 → eu_linef_req (vector 11)
        //   0xF400: bits[11:9]=010 → cpid=2 → not FPU(1)/MMU(0)/MOVE16(001+no-dir)
        //   → falls into Group-F else branch → dec_is_linef=1
        // ====================================================================
        $display("--- P70-07: Line-F non-FPU ---");
        base_linef = linef_req_cnt;
        run_instr(16'hF400, 1'b0, 32'h0);
        chk ("P70-07:linef_req_fired", linef_req_cnt - base_linef, 32'd1);

        // ── Report ────────────────────────────────────────────────────────────
        $display("Phase 70: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

endmodule

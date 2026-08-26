// ADDA/SUBA/CMPA; ORI/ANDI/EORI to CCR/SR; MULS.L/MULU.L/DIVS.L/DIVU.L;
// ADDX/SUBX register and memory predecrement; ADDQ/SUBQ to An and memory;
// ADDA/SUBA/CMPA from all memory EA modes.
`default_nettype none
`timescale 1ns/1ps

module alu_reg_tb;

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
    logic [15:0] q3_word     = 16'h0;
    logic [31:0] ext34_data  = 32'h0;
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
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;
    logic [31:0] eu_coproc_rdata = 32'h0;

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

    // Log An writes so ADDX/SUBX memory predecrement tests can verify Ax/Ay updates.
    logic [31:0] an_wr_log [0:15];
    int          an_wr_cnt = 0;
    always_ff @(posedge clk) begin
        if (an_wr_en) begin
            an_wr_log[an_wr_cnt[3:0]] <= an_wr_data;
            an_wr_cnt                 <= an_wr_cnt + 1;
        end
    end

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
    logic        eu_fmt_err_req;

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x          (clk),
        .rst_n           (rst_n),
        .instr_word      (instr_word),
        .instr_valid     (instr_valid),
        .ext_data        (ext_data),
        .q3_word         (q3_word),
        .ext34_data      (ext34_data),
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
        .eu_fmt_err_req  (eu_fmt_err_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (8K × 32; longword write stores EU output directly) ────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── Test infrastructure ─────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;
    int base_cnt;

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

    task automatic chk_ccr(input string tag,
                            input logic exp_x, exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":X"}, sr_out[4], exp_x);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
    endtask

    // Present instruction, poll for ack, drain 15 cycles to cover memory ops.
    task automatic run_instr(input logic [15:0] w0,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(15) @(posedge clk);
    endtask

    // "MUL/DIV timing investigation" (plan.md): DIVS.L/DIVU.L/MULS.L/
    // MULU.L Dn,Dn each gained a new dec_internal_stall_ticks_fixed entry
    // (up to 352 ticks for DIVS.L) matching the manual's own real NCC
    // timing. A first attempt widened run_instr()'s own SHARED settle
    // margin from 15 to 370 to clear this -- wrong: that task is used by
    // every instruction test in this file (dozens of unrelated ADD/SUB/
    // ADDA/ADDQ/etc calls), so the blanket widening added ~355 ticks to
    // EVERY call, not just the handful that need it, and the cumulative
    // extra time blew even a widened #700000 global watchdog. Reverted
    // run_instr() to its original 15-tick margin; this dedicated task
    // instead adds the extra wait ONLY after the specific MUL/DIV .L
    // Dn,Dn calls that actually need it.
    task automatic wait_muldivl_stall;
        repeat(370) @(posedge clk);
    endtask

    // Load Dn via CLR.L Dn followed by ADDI.L #val,Dn.
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);
    endtask

    // Load An via D0 then MOVEA.L D0,An.
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(3'd0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // Run division, capturing whether div_trap fires at any point.
    task automatic run_div(input  logic [15:0] w0,
                           input  logic [31:0] ext,
                           output logic        saw_trap);
        logic fired;
        fired = 0;
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = 1'b1;
        repeat(200) begin
            @(posedge clk);
            if (div_trap) fired = 1;
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(4) begin
            @(posedge clk);
            if (div_trap) fired = 1;
        end
        saw_trap = fired;
    endtask

    // ─── Test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ====================================================================
        // ADDA / SUBA / CMPA — result to An, CCR unchanged
        // ====================================================================
        $display("--- ADDA.L D0,A0 (32-bit add to An, CCR unchanged) ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd0, 32'd200);
            set_dn(3'd0, 32'd100);
            sr_before = sr_out;
            run_instr(16'hD1C0, 1'b0, 32'h0);
            chk ("ADDA-01a: A0=300",        dut.u_rf.a_reg[0], 32'd300);
            chk ("ADDA-01b: CCR unchanged", {16'h0, sr_out},    {16'h0, sr_before});
        end

        $display("--- ADDA.W D1,A1 (sign-extend word source) ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd1, 32'd10);
            set_dn(3'd1, 32'hFFFF_FFFF);   // [15:0]=0xFFFF → sext=-1
            sr_before = sr_out;
            run_instr(16'hD2C1, 1'b0, 32'h0);
            chk ("ADDA-02a: A1=9",          dut.u_rf.a_reg[1], 32'd9);
            chk ("ADDA-02b: CCR unchanged", {16'h0, sr_out},    {16'h0, sr_before});
        end

        $display("--- ADDA.L A2,A2 (An-direct source, doubles A2) ---");
        begin
            set_an(3'd2, 32'd50);
            run_instr(16'hD5CA, 1'b0, 32'h0);
            chk("ADDA-03: A2=100", dut.u_rf.a_reg[2], 32'd100);
        end

        $display("--- ADDA.W #-2,A3 (immediate word, sign-extend) ---");
        begin
            set_an(3'd3, 32'd20);
            run_instr(16'hD6FC, 1'b1, {16'h0, 16'hFFFE});
            chk("ADDA-04: A3=18", dut.u_rf.a_reg[3], 32'd18);
        end

        $display("--- ADDA.L #0x12345678,A4 (immediate longword) ---");
        begin
            set_an(3'd4, 32'h0);
            run_instr(16'hD9FC, 1'b1, 32'h1234_5678);
            chk("ADDA-05: A4=0x12345678", dut.u_rf.a_reg[4], 32'h1234_5678);
        end

        $display("--- SUBA.L D0,A5 (32-bit subtract to An, CCR unchanged) ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd5, 32'd300);
            set_dn(3'd0, 32'd100);
            sr_before = sr_out;
            run_instr(16'h9BC0, 1'b0, 32'h0);
            chk("SUBA-01a: A5=200",        dut.u_rf.a_reg[5], 32'd200);
            chk("SUBA-01b: CCR unchanged", {16'h0, sr_out},    {16'h0, sr_before});
        end

        $display("--- SUBA.W D1,A6 (sign-extend word source) ---");
        begin
            set_dn(3'd1, 32'hFFFF_FFFF);   // [15:0]=0xFFFF → sext=-1
            set_an(3'd6, 32'd0);
            run_instr(16'h9CC1, 1'b0, 32'h0);
            chk("SUBA-02: A6=1", dut.u_rf.a_reg[6], 32'd1);
        end

        $display("--- CMPA.L D2,A0 (compare sets CCR, no writeback) ---");
        begin
            set_dn(3'd2, 32'd0);
            set_an(3'd0, 32'd300);
            run_instr(16'hB1C2, 1'b0, 32'h0);
            chk1("CMPA-01a: Z=0 (300!=0)", sr_out[2], 1'b0);
            set_an(3'd0, 32'd0);
            run_instr(16'hB1C2, 1'b0, 32'h0);
            chk1("CMPA-01b: Z=1 (0==0)",   sr_out[2], 1'b1);
        end

        $display("--- CMPA.W D3,A1 (sign-extend before 32-bit compare) ---");
        begin
            set_dn(3'd3, 32'hFFFF_FFFF);   // [15:0]=0xFFFF → sext=0xFFFFFFFF
            set_an(3'd1, 32'hFFFF_FFFF);
            run_instr(16'hB2C3, 1'b0, 32'h0);
            chk1("CMPA-02: Z=1 (sext equal)", sr_out[2], 1'b1);
        end

        // ====================================================================
        // ORI / ANDI / EORI to CCR and SR
        // ====================================================================
        $display("--- ORI/ANDI/EORI to CCR ---");
        begin
            set_dn(3'd0, 32'h0);
            run_instr(16'h44C0, 1'b0, 32'h0);  // MOVE D0,CCR → CCR=0x00
            chk("CCR-01: CCR=0x00", {24'h0, sr_out[7:0]}, 32'h00);

            run_instr(16'h003C, 1'b1, {16'h0, 8'h00, 8'h1F});
            chk("CCR-02: ORI  #0x1F,CCR → all flags", {24'h0, sr_out[7:0]}, 32'h001F);

            run_instr(16'h023C, 1'b1, {16'h0, 8'h00, 8'h10});
            chk("CCR-03: ANDI #0x10,CCR → X only",   {24'h0, sr_out[7:0]}, 32'h0010);

            run_instr(16'h0A3C, 1'b1, {16'h0, 8'h00, 8'h11});
            chk("CCR-04: EORI #0x11,CCR → C only",   {24'h0, sr_out[7:0]}, 32'h0001);
        end

        $display("--- ORI/ANDI/EORI to SR ---");
        begin
            exc_sr_wr_en   = 1'b1;
            exc_sr_wr_data = 16'h2700;
            @(posedge clk);
            exc_sr_wr_en   = 1'b0;
            repeat(4) @(posedge clk);
            chk("SR-01: SR=0x2700",       {16'h0, sr_out}, 32'h0000_2700);

            run_instr(16'h007C, 1'b1, {16'h0, 16'h0001});
            chk("SR-02: ORI  #1,SR  → C set",   {16'h0, sr_out}, 32'h0000_2701);

            run_instr(16'h027C, 1'b1, {16'h0, 16'hFFFE});
            chk("SR-03: ANDI #~1,SR → C clear", {16'h0, sr_out}, 32'h0000_2700);

            run_instr(16'h0A7C, 1'b1, {16'h0, 16'h0010});
            chk("SR-04: EORI #0x10,SR → X set", {16'h0, sr_out}, 32'h0000_2710);
        end

        // ====================================================================
        // MULS.L / MULU.L / DIVS.L / DIVU.L — 32-bit and 64-bit forms
        // ====================================================================
        $display("--- MULU.L D0,D1 (32-bit: 7×6=42) ---");
        // Opcode 0x4C00 (f_reg=D0); ext Dh=D2(010), sz=0, sign=0, Dl=D1(001) = 0x2001
        set_dn(3'd0, 32'd7);
        set_dn(3'd1, 32'd6);
        begin
            run_instr(16'h4C00, 1'b1, {16'h0, 16'h2001});
            wait_muldivl_stall;
            chk("MUL-01a: D1=42",       dut.u_rf.d_reg[1], 32'd42);
            chk("MUL-01b: D2 untouch",  dut.u_rf.d_reg[2], 32'h0);
            chk1("MUL-01c: N=0", sr_out[3], 1'b0);
            chk1("MUL-01d: Z=0", sr_out[2], 1'b0);
            chk1("MUL-01e: V=0", sr_out[1], 1'b0);
            chk1("MUL-01f: C=0", sr_out[0], 1'b0);
        end

        $display("--- MULU.L D2,D4:D3 (64-bit: 3×0x80000000=0x1_80000000) ---");
        // Opcode 0x4C02; ext Dh=D4(100), sz=1, sign=0, Dl=D3(011) = 0x4403
        set_dn(3'd2, 32'd3);
        set_dn(3'd3, 32'h8000_0000);
        run_instr(16'h4C02, 1'b1, {16'h0, 16'h4403});
        wait_muldivl_stall;
        chk("MUL-02a: D3=0x80000000", dut.u_rf.d_reg[3], 32'h8000_0000);
        chk("MUL-02b: D4=1",          dut.u_rf.d_reg[4], 32'd1);
        chk1("MUL-02c: N=0", sr_out[3], 1'b0);
        chk1("MUL-02d: Z=0", sr_out[2], 1'b0);

        $display("--- MULS.L D4,D5 (32-bit signed: -2×3=-6) ---");
        // Opcode 0x4C04; ext Dh=D6(110), sz=0, sign=1(bit11), Dl=D5(101) = 0x6805
        // (real 68020 sign flag is ext bit 11, not bit 6 -- see eu_seq.sv decode fix)
        set_dn(3'd4, 32'hFFFF_FFFE);  // -2
        set_dn(3'd5, 32'd3);
        begin
            logic [31:0] d6_before;
            d6_before = dut.u_rf.d_reg[6];
            run_instr(16'h4C04, 1'b1, {16'h0, 16'h6805});
            wait_muldivl_stall;
            chk("MUL-03a: D5=-6",       dut.u_rf.d_reg[5], 32'hFFFF_FFFA);
            chk("MUL-03b: D6 untouch",  dut.u_rf.d_reg[6], d6_before);
            chk1("MUL-03c: N=1", sr_out[3], 1'b1);
            chk1("MUL-03d: Z=0", sr_out[2], 1'b0);
        end

        $display("--- MULS.L D4,D6:D5 (64-bit signed: -2×3=0xFFFFFFFF_FFFFFFFA) ---");
        // Opcode 0x4C04; ext Dh=D6(110), sz=1, sign=1(bit11), Dl=D5(101) = 0x6C05
        set_dn(3'd4, 32'hFFFF_FFFE);  // -2
        set_dn(3'd5, 32'd3);
        run_instr(16'h4C04, 1'b1, {16'h0, 16'h6C05});
        wait_muldivl_stall;
        chk("MUL-04a: D5=0xFFFFFFFA", dut.u_rf.d_reg[5], 32'hFFFF_FFFA);
        chk("MUL-04b: D6=0xFFFFFFFF", dut.u_rf.d_reg[6], 32'hFFFF_FFFF);
        chk1("MUL-04c: N=1", sr_out[3], 1'b1);
        chk1("MUL-04d: Z=0", sr_out[2], 1'b0);

        $display("--- DIVU.L D0,D2:D1 (100÷7=14 rem 2) ---");
        // Opcode 0x4C40 (f_ss=01, f_reg=D0); ext Dr=D2(010), sign=0, Dq=D1(001) = 0x2001
        set_dn(3'd0, 32'd7);
        set_dn(3'd1, 32'd100);
        run_instr(16'h4C40, 1'b1, {16'h0, 16'h2001});
        wait_muldivl_stall;
        chk("DIV-01a: D1(Dq)=14", dut.u_rf.d_reg[1], 32'd14);
        chk("DIV-01b: D2(Dr)=2",  dut.u_rf.d_reg[2], 32'd2);
        chk1("DIV-01c: N=0", sr_out[3], 1'b0);
        chk1("DIV-01d: Z=0", sr_out[2], 1'b0);
        chk1("DIV-01e: V=0", sr_out[1], 1'b0);
        chk1("DIV-01f: C=0", sr_out[0], 1'b0);

        $display("--- DIVS.L D1,D3:D2 (17÷-3=quot -5 rem 2) ---");
        // Opcode 0x4C41 (f_reg=D1); ext Dr=D3(011), sign=1(bit11), Dq=D2(010) = 0x3802
        set_dn(3'd1, 32'hFFFF_FFFD);  // -3
        set_dn(3'd2, 32'd17);
        run_instr(16'h4C41, 1'b1, {16'h0, 16'h3802});
        wait_muldivl_stall;
        chk("DIV-02a: D2(Dq)=-5", dut.u_rf.d_reg[2], 32'hFFFF_FFFB);
        chk("DIV-02b: D3(Dr)=2",  dut.u_rf.d_reg[3], 32'd2);
        chk1("DIV-02c: N=1", sr_out[3], 1'b1);
        chk1("DIV-02d: Z=0", sr_out[2], 1'b0);
        chk1("DIV-02e: V=0", sr_out[1], 1'b0);

        $display("--- DIVU.L D0,D1:D1 (Dr=Dq same reg: 10÷3=3) ---");
        // Opcode 0x4C40; ext Dr=D1(001), sign=0, Dq=D1(001) = 0x1001 (Dr==Dq → 32-bit)
        set_dn(3'd0, 32'd3);
        set_dn(3'd1, 32'd10);
        run_instr(16'h4C40, 1'b1, {16'h0, 16'h1001});
        wait_muldivl_stall;
        chk("DIV-03: D1(Dq)=3", dut.u_rf.d_reg[1], 32'd3);

        $display("--- DIVU.L divide-by-zero → div_trap ---");
        // D0=0 (divisor), D1=100 (dividend)
        set_dn(3'd0, 32'd0);
        set_dn(3'd1, 32'd100);
        begin
            logic saw;
            run_div(16'h4C40, {16'h0, 16'h2001}, saw);
            chk1("DIV-04: div_trap fired", saw, 1'b1);
        end

        $display("--- MULU.L D0,D0 (0×5=0: Z flag) ---");
        // Opcode 0x4C00; ext Dh=D1(001), sz=0, sign=0, Dl=D0(000) = 0x1000
        set_dn(3'd0, 32'd0);
        run_instr(16'h4C00, 1'b1, {16'h0, 16'h1000});
        wait_muldivl_stall;
        chk("MUL-05a: D0=0", dut.u_rf.d_reg[0], 32'h0);
        chk1("MUL-05b: Z=1", sr_out[2], 1'b1);
        chk1("MUL-05c: N=0", sr_out[3], 1'b0);

        // ====================================================================
        // ADDX / SUBX — register and memory predecrement forms
        // ====================================================================
        $display("--- ADDX.L D1,D0 (register, X=1 carry-in) ---");
        // Opcode 0xD181. D0=0, D1=0, X=1 → result=1, proves X used.
        set_dn(3'd2, 32'hFFFF_FFFF);
        run_instr(16'h5282, 1'b0, 32'h0);   // ADDQ.L #1,D2 → D2=0, X=1
        run_instr(16'h4280, 1'b0, 32'h0);   // CLR.L D0 (X unchanged)
        run_instr(16'h4281, 1'b0, 32'h0);   // CLR.L D1 (X unchanged)
        run_instr(16'hD181, 1'b0, 32'h0);   // ADDX.L D1,D0
        chk_ccr("ADDX-01", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- SUBX.L D1,D0 (register, 5-3=2) ---");
        // Opcode 0x9181. D0=5, D1=3, X=0 → D0=2.
        set_dn(3'd0, 32'h0000_0005);
        set_dn(3'd1, 32'h0000_0003);
        run_instr(16'h9181, 1'b0, 32'h0);
        chk_ccr("SUBX-01", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        run_instr(16'h0C80, 1'b1, 32'h0000_0002);  // CMPI.L #2,D0
        chk1("SUBX-01:D0=2", sr_out[2], 1'b1);

        $display("--- ADDX.L -(A1),-(A0) (memory predecrement) ---");
        // A1=0x144 (Ay), A0=0x140 (Ax), X=0; M[0x140]=0x11 (src), M[0x13C]=0x22 (dst)
        ram[8'h50] = 32'h0000_0011;    // M[0x140]
        ram[8'h4F] = 32'h0000_0022;    // M[0x13C]
        set_an(3'd1, 32'h0000_0144);
        set_an(3'd0, 32'h0000_0140);
        base_cnt = an_wr_cnt;
        run_instr(16'hD189, 1'b0, 32'h0);
        chk("ADDX-02:mem",   ram[8'h4F],                   32'h0000_0033);
        chk("ADDX-02:Ay",    an_wr_log[base_cnt % 16],     32'h0000_0140);
        chk("ADDX-02:Ax",    an_wr_log[(base_cnt+1) % 16], 32'h0000_013C);
        chk_ccr("ADDX-02", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- SUBX.L -(A3),-(A2) (memory predecrement: 0x50-0x30=0x20) ---");
        // A3=0x150, A2=0x14C, X=0
        ram[8'h53] = 32'h0000_0030;    // M[0x14C]
        ram[8'h52] = 32'h0000_0050;    // M[0x148]
        set_an(3'd3, 32'h0000_0150);
        set_an(3'd2, 32'h0000_014C);
        base_cnt = an_wr_cnt;
        run_instr(16'h958B, 1'b0, 32'h0);
        chk("SUBX-02:mem",   ram[8'h52],                   32'h0000_0020);
        chk("SUBX-02:Ay",    an_wr_log[base_cnt % 16],     32'h0000_014C);
        chk("SUBX-02:Ax",    an_wr_log[(base_cnt+1) % 16], 32'h0000_0148);
        chk_ccr("SUBX-02", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADDX.W -(A1),-(A0) (word memory: 0xABCD+0x1234=0xBE01) ---");
        // A1=0x15A (Ay), A0=0x158 (Ax), X=0; step=2; result in [31:16] (EU convention)
        ram[8'h56] = 32'h0000_1234;    // M[0x158]
        ram[8'h55] = 32'h0000_ABCD;    // M[0x156]
        set_an(3'd1, 32'h0000_015A);
        set_an(3'd0, 32'h0000_0158);
        base_cnt = an_wr_cnt;
        run_instr(16'hD149, 1'b0, 32'h0);
        chk("ADDX-03:mem",   ram[8'h55],                   32'hBE01_0000);
        chk("ADDX-03:Ay",    an_wr_log[base_cnt % 16],     32'h0000_0158);
        chk("ADDX-03:Ax",    an_wr_log[(base_cnt+1) % 16], 32'h0000_0156);
        chk_ccr("ADDX-03", 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);

        $display("--- ADDX.L -(A1),-(A0) (memory with X=1 carry) ---");
        // Set addresses first, then generate X=1 via register ADDX.
        ram[8'h59] = 32'h0000_0001;    // M[0x164]
        ram[8'h58] = 32'h0000_0002;    // M[0x160]
        set_an(3'd1, 32'h0000_0168);
        set_an(3'd0, 32'h0000_0164);
        set_dn(3'd5, 32'hFFFF_FFFF);
        set_dn(3'd6, 32'h0000_0001);
        run_instr(16'hDB86, 1'b0, 32'h0);  // ADDX.L D6,D5 → X=1
        base_cnt = an_wr_cnt;
        run_instr(16'hD189, 1'b0, 32'h0);
        chk("ADDX-04:mem",   ram[8'h58],                   32'h0000_0004);
        chk("ADDX-04:Ay",    an_wr_log[base_cnt % 16],     32'h0000_0164);
        chk("ADDX-04:Ax",    an_wr_log[(base_cnt+1) % 16], 32'h0000_0160);
        chk_ccr("ADDX-04", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADDX Z-flag: result=0, prior Z=0 → Z stays 0 ---");
        // ADDX rule: Z_out = Z_in & (result==0). D0=1, D1=0xFFFFFFFF, X=0 → result=0, Z=0.
        set_dn(3'd0, 32'h0000_0001);
        set_dn(3'd1, 32'hFFFF_FFFF);
        run_instr(16'hD181, 1'b0, 32'h0);  // ADDX.L D1,D0 → result=0
        chk1("ADDX-05:Z=0", sr_out[2], 1'b0);
        chk1("ADDX-05:C=1", sr_out[0], 1'b1);
        chk1("ADDX-05:X=1", sr_out[4], 1'b1);

        $display("--- ADDX Z-flag: result=0, prior Z=1 → Z stays 1 ---");
        // D0=0, D1=0, X=0 → result=0, Z_in=1, Z_out=1.
        set_dn(3'd0, 32'h0000_0000);
        set_dn(3'd1, 32'h0000_0000);
        run_instr(16'hD181, 1'b0, 32'h0);  // ADDX.L D1,D0
        chk1("ADDX-06:Z=1", sr_out[2], 1'b1);
        chk1("ADDX-06:C=0", sr_out[0], 1'b0);
        chk1("ADDX-06:X=0", sr_out[4], 1'b0);

        // ====================================================================
        // ADDQ / SUBQ — quick immediate to An and memory EA
        // ====================================================================
        $display("--- ADDQ #4,A0 (0x5888) ---");
        // An target: CCR unchanged, full 32-bit add.
        set_an(3'd0, 32'h0000_1000);
        run_instr(16'h5888, 1'b0, 32'h0);
        chk("ADDQ-01: A0=0x1004", dut.u_rf.a_reg[0], 32'h0000_1004);

        $display("--- SUBQ #8,A7 (0x518F) ---");
        set_an(3'd7, 32'h0000_3000);
        run_instr(16'h518F, 1'b0, 32'h0);
        chk("SUBQ-01: A7=0x2FF8", dut.u_rf.isp_r, 32'h0000_2FF8);

        $display("--- ADDQ #3,(0x10,A2) — memory RMW via (d16,An) ---");
        // A2=0x2000, EA=0x2010; mem[0x2010]=100 → 103
        set_an(3'd2, 32'h0000_2000);
        ram[32'h2010 >> 2] = 32'h0000_0064;
        run_instr(16'h56AA, 1'b1, 32'h0000_0010);
        chk("ADDQ-02: mem[0x2010]=103", ram[32'h2010 >> 2], 32'h0000_0067);

        $display("--- SUBQ #2,(0x3000).W — abs.W memory RMW ---");
        // mem[0x3000]=10 → 8
        ram[32'h3000 >> 2] = 32'h0000_000A;
        run_instr(16'h55B8, 1'b1, 32'h0000_3000);
        chk("SUBQ-02: mem[0x3000]=8", ram[32'h3000 >> 2], 32'h0000_0008);

        $display("--- ADDQ #1,(0x4000).L — abs.L memory RMW ---");
        // mem[0x4000]=127 → 128
        ram[32'h4000 >> 2] = 32'h0000_007F;
        run_instr(16'h52B9, 1'b1, 32'h0000_4000);
        chk("ADDQ-03: mem[0x4000]=128", ram[32'h4000 >> 2], 32'h0000_0080);

        // ====================================================================
        // ADDA / SUBA / CMPA from memory EA
        // ====================================================================
        $display("--- ADDA.L (A3),A4 (indirect source) ---");
        // A3=0x5000; mem[0x5000]=0x1234; A4=0x1000 → A4=0x2234
        set_an(3'd3, 32'h0000_5000);
        set_an(3'd4, 32'h0000_1000);
        ram[32'h5000 >> 2] = 32'h0000_1234;
        run_instr(16'hD9D3, 1'b0, 32'h0);
        chk("ADDA-06: A4=0x2234", dut.u_rf.a_reg[4], 32'h0000_2234);

        $display("--- ADDA.W (0x10,A3),A4 (sign-extend word from memory) ---");
        // A3=0x5000, EA=0x5010; mem[0x5010][15:0]=0xFFFE → sext=-2; A4=0x2234+(-2)=0x2232
        ram[32'h5010 >> 2] = 32'h0000_FFFE;
        run_instr(16'hD8EB, 1'b1, 32'h0000_0010);
        chk("ADDA-07: A4=0x2232", dut.u_rf.a_reg[4], 32'h0000_2232);

        $display("--- SUBA.L (0x6000).W,A4 (abs.W source) ---");
        // mem[0x6000]=0x32 (50); A4=0x2232 → A4=0x2200
        ram[32'h6000 >> 2] = 32'h0000_0032;
        run_instr(16'h99F8, 1'b1, 32'h0000_6000);
        chk("SUBA-03: A4=0x2200", dut.u_rf.a_reg[4], 32'h0000_2200);

        $display("--- CMPA.W (0x7000).L,A4 (abs.L source; equal → Z=1) ---");
        // A4=0x1234 (reset); mem[0x7000][15:0]=0x1234; sext=0x1234; 0x1234-0x1234=0 → Z=1
        set_an(3'd4, 32'h0000_1234);
        ram[32'h7000 >> 2] = 32'h0000_1234;
        run_instr(16'hB8F9, 1'b1, 32'h0000_7000);
        chk1("CMPA-03:Z=1", sr_out[2], 1'b1);
        chk1("CMPA-03:N=0", sr_out[3], 1'b0);
        chk1("CMPA-03:C=0", sr_out[0], 1'b0);

        $display("--- ADDA.L (A5)+,A6 (postincrement source) ---");
        // A5=0x5100, postinc by 4; A6=0x200; mem[0x5100]=0x100 → A6=0x300, A5=0x5104
        set_an(3'd5, 32'h0000_5100);
        set_an(3'd6, 32'h0000_0200);
        ram[32'h5100 >> 2] = 32'h0000_0100;
        run_instr(16'hDDDD, 1'b0, 32'h0);
        chk("ADDA-08:A6", dut.u_rf.a_reg[6], 32'h0000_0300);
        chk("ADDA-08:A5", dut.u_rf.a_reg[5], 32'h0000_5104);

        $display("--- SUBA.W -(A5),A6 (predecrement word source) ---");
        // A5=0x5104, predec by 2 → 0x5102; mem[0x5102] in same word as mem[0x5100]
        // EU reads word → sign-ext 0x0100; A6=0x300-0x100=0x200
        run_instr(16'h9CE5, 1'b0, 32'h0);
        chk("SUBA-04:A6", dut.u_rf.a_reg[6], 32'h0000_0200);
        chk("SUBA-04:A5", dut.u_rf.a_reg[5], 32'h0000_5102);

        // ─── summary ─────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        $display("");
        if (fail_cnt == 0)
            $display("PASS all %0d checks", pass_cnt);
        else
            $display("FAIL %0d/%0d checks failed", fail_cnt, pass_cnt + fail_cnt);
        $finish;
    end

    initial begin
        // "MUL/DIV timing investigation" (plan.md): widened slightly --
        // the ~6 MUL/DIV .L Dn,Dn tests each now cost ~370 extra ticks
        // (3700 extra time units) via the dedicated wait_muldivl_stall
        // task, not a blanket per-call increase (see that task's own
        // comment for why the first attempt at this was wrong).
        #530000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

`default_nettype none
`timescale 1ns/1ps

// Exception and bounds-checking tests
//
// CHK/CHK2: range check; chk_trap fires on out-of-bounds
// CMP2:     compare against memory bounds; sets C/Z flags only
// TRAPcc:   conditional trap (F/T/W/L forms)
// CAS2:     dual-address atomic compare-and-swap (L-match, L-mismatch, W-match)
// Format Error: RTE with invalid frame format fires eu_fmt_err_req
// RESET:    eu_reset_req stays asserted >= 2047 internal clock ticks

module exception_tb;

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
    logic        eu_priv_req;
    logic        eu_trace_req;
    logic        eu_linea_req;
    logic        eu_linef_req;
    logic        eu_fmt_err_req;

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
        .eu_fmt_err_req  (eu_fmt_err_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // Memory: combinatorial ack, 8K longwords + write log for CAS2 verification
    logic [31:0] ram [0:8191];
    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    int          write_cnt = 0;
    logic [31:0] write_addr[0:7];
    logic [31:0] write_data[0:7];
    logic [1:0]  write_siz[0:7];

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw) begin
            ram[mem_addr[14:2]] <= mem_wdata;
            if (write_cnt < 8) begin
                write_addr[write_cnt] <= mem_addr;
                write_data[write_cnt] <= mem_wdata;
                write_siz[write_cnt]  <= mem_siz;
                write_cnt             <= write_cnt + 1;
            end
        end
    end

    // Pulse counters
    int chk_trap_cnt = 0, trapv_cnt = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            chk_trap_cnt <= 0;
            trapv_cnt    <= 0;
        end else begin
            if (chk_trap)     chk_trap_cnt <= chk_trap_cnt + 1;
            if (eu_trapv_req) trapv_cnt    <= trapv_cnt + 1;
        end
    end

    int pass_count = 0, fail_count = 0;

    task automatic chk(input string tag, input logic [31:0] got, input logic [31:0] exp);
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

    task automatic run_instr(input logic [15:0] iw, input logic has_ext,
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
        repeat(12) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    int          trap_before, prev_trapv;
    logic        fmt_err_seen, saw_branch, saw_fmt_err;
    logic [31:0] high_cycles;
    int          i;

    initial begin
        for (int j = 0; j < 8192; j++) ram[j] = 32'h0;
        @(posedge rst_n); repeat(4) @(posedge clk);

        // ====================================================================
        // CHK.W Dn,Dn — CHK.W D1,D0 = 0x4181
        $display("--- CHK: Dn register ---");

        set_dn(0, 32'd5);  set_dn(1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 1'b0, 32'h0);
        chk("CHK-01:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);
        chk1("CHK-01:N=0", sr_out[3], 1'b0);

        set_dn(0, 32'd15); set_dn(1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 1'b0, 32'h0);
        chk("CHK-02:trap", 32'(chk_trap_cnt - trap_before), 32'd1);
        chk1("CHK-02:N=0", sr_out[3], 1'b0);

        set_dn(0, 32'hFFFFFFFE); set_dn(1, 32'd10);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 1'b0, 32'h0);
        chk("CHK-03:trap", 32'(chk_trap_cnt - trap_before), 32'd1);
        chk1("CHK-03:N=1", sr_out[3], 1'b1);

        set_dn(0, 32'd0); set_dn(1, 32'd0);
        trap_before = chk_trap_cnt;
        run_instr(16'h4181, 1'b0, 32'h0);
        chk("CHK-04:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);

        // CHK.L D1,D0 = 0x4101
        $display("--- CHK.L Dn ---");

        set_dn(0, 32'd100); set_dn(1, 32'd1000);
        trap_before = chk_trap_cnt;
        run_instr(16'h4101, 1'b0, 32'h0);
        chk("CHK-05:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);

        set_dn(0, 32'h80000001); set_dn(1, 32'd1000);
        trap_before = chk_trap_cnt;
        run_instr(16'h4101, 1'b0, 32'h0);
        chk("CHK-06:trap", 32'(chk_trap_cnt - trap_before), 32'd1);
        chk1("CHK-06:N=1", sr_out[3], 1'b1);

        // CHK.W #imm,D0 = 0x41BC + ext
        $display("--- CHK.W immediate ---");

        set_dn(0, 32'd5);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 1'b1, 32'h0000000A);
        chk("CHK-07:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);

        set_dn(0, 32'd20);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 1'b1, 32'h0000000A);
        chk("CHK-08:trap", 32'(chk_trap_cnt - trap_before), 32'd1);

        set_dn(0, 32'd0);
        trap_before = chk_trap_cnt;
        run_instr(16'h41BC, 1'b1, 32'h00000000);
        chk("CHK-09:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);

        // CMP2.L (A0),D0 = 0x04D0 + ext; A0=0x08, lower=10@ram[2], upper=100@ram[3]
        $display("--- CMP2.L memory bounds ---");
        set_an(3'd0, 32'h00000008);
        ram[2] = 32'h0000_000A;
        ram[3] = 32'h0000_0064;

        set_dn(0, 32'd50);
        run_instr(16'h04D0, 1'b1, 32'h0000);
        chk1("CMP2-01:C=0", sr_out[0], 1'b0);
        chk1("CMP2-01:Z=0", sr_out[2], 1'b0);

        set_dn(0, 32'd10);
        run_instr(16'h04D0, 1'b1, 32'h0000);
        chk1("CMP2-02:C=0", sr_out[0], 1'b0);
        chk1("CMP2-02:Z=1", sr_out[2], 1'b1);

        set_dn(0, 32'd100);
        run_instr(16'h04D0, 1'b1, 32'h0000);
        chk1("CMP2-03:C=0", sr_out[0], 1'b0);
        chk1("CMP2-03:Z=1", sr_out[2], 1'b1);

        set_dn(0, 32'd5);
        run_instr(16'h04D0, 1'b1, 32'h0000);
        chk1("CMP2-04:C=1", sr_out[0], 1'b1);

        set_dn(0, 32'd150);
        run_instr(16'h04D0, 1'b1, 32'h0000);
        chk1("CMP2-05:C=1", sr_out[0], 1'b1);

        // CHK2.L (A0),D0 — ext[11]=1 fires chk_trap if out-of-range
        $display("--- CHK2.L memory bounds ---");

        set_dn(0, 32'd50);
        trap_before = chk_trap_cnt;
        run_instr(16'h04D0, 1'b1, 32'h0800);
        chk1("CHK2-01:C=0", sr_out[0], 1'b0);
        chk("CHK2-01:no_trap", 32'(chk_trap_cnt - trap_before), 32'd0);

        set_dn(0, 32'd5);
        trap_before = chk_trap_cnt;
        run_instr(16'h04D0, 1'b1, 32'h0800);
        chk1("CHK2-02:C=1", sr_out[0], 1'b1);
        chk("CHK2-02:trap", 32'(chk_trap_cnt - trap_before), 32'd1);

        // ====================================================================
        // TRAPcc
        $display("--- TRAPcc ---");

        prev_trapv = trapv_cnt;
        run_instr(16'h51FC, 1'b0, 32'h0);     // TRAPcc.F — never
        chk1("TRAPCC-01:no_trap", (trapv_cnt == prev_trapv), 1'b1);

        prev_trapv = trapv_cnt;
        run_instr(16'h50FC, 1'b0, 32'h0);     // TRAPcc.T — always
        chk1("TRAPCC-02:trap_fired", (trapv_cnt > prev_trapv), 1'b1);

        prev_trapv = trapv_cnt;
        run_instr(16'h51FA, 1'b1, 32'h00001234); // TRAPcc.W.F — 1 ext word
        chk1("TRAPCC-03:no_trap", (trapv_cnt == prev_trapv), 1'b1);

        prev_trapv = trapv_cnt;
        run_instr(16'h51F8, 1'b1, 32'hDEADBEEF); // TRAPcc.L.F — 2 ext words
        chk1("TRAPCC-04:no_trap", (trapv_cnt == prev_trapv), 1'b1);

        // ====================================================================
        // CAS2: dual-address atomic compare-and-swap
        $display("--- CAS2 ---");
        @(posedge clk); #1;
        exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
        @(posedge clk); #1; exc_sr_wr_en = 0;
        repeat(2) @(posedge clk);

        set_an(3'd0, 32'h40);
        set_an(3'd1, 32'h50);

        // CAS2-01: CAS2.L match — D0:D2,D1:D3,(A0):(A1); ext=0x2309_0108
        // M[0x40]=4==Dc1=D0, M[0x50]=6==Dc2=D2 → write Du1=D1=5@0x40, Du2=D3=7@0x50
        set_dn(0, 32'd4); set_dn(1, 32'd5); set_dn(2, 32'd6); set_dn(3, 32'd7);
        ram[32'h40>>2] = 32'd4;
        ram[32'h50>>2] = 32'd6;
        write_cnt = 0;
        @(posedge clk); #1;
        instr_word = 16'h0EFC; instr_valid = 1;
        ext_data = 32'h2309_0108; ext_valid = 1;
        repeat(200) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0; ext_valid = 0;
        repeat(80) @(posedge clk);
        chk("CAS2-01:write_cnt", 32'(write_cnt), 32'd2);
        chk("CAS2-01:wr0.addr",  write_addr[0],  32'h40);
        chk("CAS2-01:wr0.data",  write_data[0],  32'd5);
        chk("CAS2-01:wr1.addr",  write_addr[1],  32'h50);
        chk("CAS2-01:wr1.data",  write_data[1],  32'd7);
        chk1("CAS2-01:Z=1", sr_out[2], 1'b1);

        // CAS2-02: CAS2.L mismatch — M[0x40]=0x0F != Dc1=4 → no writes
        ram[32'h40>>2] = 32'h0F;
        ram[32'h50>>2] = 32'h0F;
        write_cnt = 0;
        @(posedge clk); #1;
        instr_word = 16'h0EFC; instr_valid = 1;
        ext_data = 32'h2309_0108; ext_valid = 1;
        repeat(200) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0; ext_valid = 0;
        repeat(80) @(posedge clk);
        chk("CAS2-02:write_cnt", 32'(write_cnt), 32'd0);
        chk1("CAS2-02:Z=0", sr_out[2], 1'b0);

        // CAS2-03: CAS2.W match — D4:D6,D5:D7,(A0):(A1); ext=0x6709_4508
        set_dn(4, 32'h12); set_dn(5, 32'h34); set_dn(6, 32'h56); set_dn(7, 32'h78);
        ram[32'h40>>2] = 32'h0000_0012;
        ram[32'h50>>2] = 32'h0000_0056;
        write_cnt = 0;
        @(posedge clk); #1;
        instr_word = 16'h0CFC; instr_valid = 1;
        ext_data = 32'h6709_4508; ext_valid = 1;
        repeat(200) begin @(posedge clk); if (instr_ack) break; end
        instr_valid = 0; ext_valid = 0;
        repeat(80) @(posedge clk);
        chk("CAS2-03:write_cnt", 32'(write_cnt), 32'd2);
        chk("CAS2-03:wr0.addr",  write_addr[0],  32'h40);
        chk("CAS2-03:wr0.data",  write_data[0],  32'h34);
        chk("CAS2-03:wr1.addr",  write_addr[1],  32'h50);
        chk("CAS2-03:wr1.data",  write_data[1],  32'h78);
        chk1("CAS2-03:Z=1", sr_out[2], 1'b1);

        // ====================================================================
        // Format Error: RTE with invalid frame format code
        $display("--- Format Error ---");
        @(posedge clk); #1;
        exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
        @(posedge clk); #1; exc_sr_wr_en = 0;
        @(posedge clk); #1;
        ssp_wr_data = 32'h100; ssp_wr_en = 1;
        @(posedge clk); #1; ssp_wr_en = 0;
        repeat(2) @(posedge clk);

        // FMTERR-01: format=0x1 (invalid) fires eu_fmt_err_req
        ram[32'h100>>2] = 32'h1000_2700;  // format nibble=1, SR=0x2700
        ram[32'h104>>2] = 32'h0000_5000;
        fmt_err_seen = 0;
        @(posedge clk); #1;
        instr_word = 16'h4E73; instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0;
        for (i = 0; i < 20; i++) begin
            @(posedge clk);
            if (eu_fmt_err_req) fmt_err_seen = 1'b1;
        end
        chk1("FMTERR-01:fires", fmt_err_seen, 1'b1);

        // FMTERR-02: format=0x0 (valid) — no fmt_err, branch taken
        @(posedge clk); #1;
        exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
        @(posedge clk); #1; exc_sr_wr_en = 0;
        @(posedge clk); #1;
        ssp_wr_data = 32'h100; ssp_wr_en = 1;
        @(posedge clk); #1; ssp_wr_en = 0;
        repeat(2) @(posedge clk);
        ram[32'h100>>2] = 32'h0000_2700;  // format nibble=0, SR=0x2700
        ram[32'h104>>2] = 32'h0000_5000;  // new PC
        saw_branch = 0; saw_fmt_err = 0;
        @(posedge clk); #1;
        instr_word = 16'h4E73; instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0;
        for (i = 0; i < 20; i++) begin
            @(posedge clk);
            if (branch_taken)   saw_branch   = 1'b1;
            if (eu_fmt_err_req) saw_fmt_err  = 1'b1;
        end
        chk1("FMTERR-02:no_fmt_err",   saw_fmt_err, 1'b0);
        chk1("FMTERR-02:branch_taken", saw_branch,  1'b1);

        // ====================================================================
        // RESET duration: eu_reset_req stays asserted >= 2047 internal clock ticks
        $display("--- RESET duration ---");
        @(posedge clk); #1;
        exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
        @(posedge clk); #1; exc_sr_wr_en = 0;
        repeat(10) @(posedge clk);

        high_cycles = 0;
        @(posedge clk); #1;
        instr_word = 16'h4E70; instr_valid = 1;  // RESET
        @(posedge clk); #1; instr_valid = 0;

        for (i = 0; i < 10; i++) begin
            @(posedge clk);
            if (eu_reset_req) i = 10;
        end

        if (!eu_reset_req) begin
            $display("FAIL RESET-01: eu_reset_req never rose");
            fail_count++;
        end else begin
            while (eu_reset_req) begin
                @(posedge clk);
                high_cycles++;
            end
            chk1("RESET-01:active>=2047", (high_cycles >= 32'd2047), 1'b1);
            chk1("RESET-01:active<=2052", (high_cycles <= 32'd2052), 1'b1);
        end

        repeat(4) @(posedge clk);
        $display("");
        if (fail_count == 0)
            $display("PASS: %0d checks passed", pass_count);
        else
            $display("FAIL: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule

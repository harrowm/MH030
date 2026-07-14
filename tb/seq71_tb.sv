// Phase 71: CAS2 EU decode, Format Error exception, RESET duration audit
//
// P71-01: CAS2.L match  — Dc1==M[Rn1] && Dc2==M[Rn2] → write Du1,Du2; Z=1
// P71-02: CAS2.L mismatch — M[Rn1]!=Dc1 → write Dc1←rdata1,Dc2←rdata2; Z=0
// P71-03: CAS2.W match  — word-size compare and write
// P71-04: Format Error  — RTE with invalid format code fires eu_fmt_err_req
// P71-05: Valid format  — RTE with format $0 does NOT fire eu_fmt_err_req
// P71-06: RESET duration — eu_reset_req stays high for ≥2048 internal ticks

`default_nettype none
`timescale 1ns/1ps

module seq71_tb;

    // ─── Clock + reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk);
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
    logic        mem_ack    = 0;
    logic        mem_berr   = 0;
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
    logic        eu_pflush_ack  = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack   = 0;
    logic [15:0] eu_ptest_mmusr = 16'h0;
    logic [31:0] tc_out, tt0_out, tt1_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req, eu_illegal_req, eu_stop, eu_reset_req;
    logic        eu_priv_req, eu_trace_req, eu_linea_req, eu_linef_req;
    logic        eu_fmt_err_req;

    // ─── DUT ─────────────────────────────────────────────────────────────────
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
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .eu_coproc_rdata (eu_coproc_rdata),
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
        .an_wr_en        (an_wr_en),
        .an_wr_sel       (an_wr_sel),
        .an_wr_data      (an_wr_data),
        .div_trap        (div_trap),
        .chk_trap        (chk_trap),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data),
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
        .eu_fmt_err_req  (eu_fmt_err_req)
    );

    // ─── Memory model: one-cycle ack, two keyed read addresses ───────────────
    logic [31:0] mem_model_addr1 = 32'h0;
    logic [31:0] mem_model_data1 = 32'h0;
    logic [31:0] mem_model_addr2 = 32'h0;
    logic [31:0] mem_model_data2 = 32'h0;

    always_comb begin
        if (mem_addr == mem_model_addr1)
            mem_rdata = mem_model_data1;
        else if (mem_addr == mem_model_addr2)
            mem_rdata = mem_model_data2;
        else
            mem_rdata = 32'hDEAD_BEEF;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) mem_ack <= 1'b0;
        else        mem_ack <= mem_req && !mem_ack;
    end

    // Track bus writes
    int          write_cnt = 0;
    logic [31:0] write_addr[0:7];
    logic [31:0] write_data[0:7];
    logic [1:0]  write_siz[0:7];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_cnt <= 0;
        end else if (mem_req && !mem_rw && mem_ack && write_cnt < 8) begin
            write_addr[write_cnt] <= mem_addr;
            write_data[write_cnt] <= mem_wdata;
            write_siz[write_cnt]  <= mem_siz;
            write_cnt             <= write_cnt + 1;
        end
    end

    // ─── Test helpers ─────────────────────────────────────────────────────────
    int pass_count = 0, fail_count = 0;

    task automatic chk(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) begin $display("pass  %s", name); pass_count++; end
        else begin $display("FAIL  %s — got %0h  exp %0h", name, got, exp); fail_count++; end
    endtask

    task automatic chk1(input string name, input logic got, input logic exp);
        if (got === exp) begin $display("pass  %s", name); pass_count++; end
        else begin $display("FAIL  %s — got %0b  exp %0b", name, got, exp); fail_count++; end
    endtask

    // Issue one instruction, wait for EX+WB to flush (4 extra cycles)
    task automatic run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk); #1;
        instr_valid = 0; ext_valid = 0;
        repeat(4) @(posedge clk);
    endtask

    // Set Dn to signed-8-bit-range value via MOVEQ
    // MOVEQ #imm,Dn: 0111 nnn 0 iiiiiiii
    task automatic set_dn(input logic [2:0] n, input logic [7:0] v);
        run({4'h7, n, 1'b0, v}, 32'h0, 1'b0);
    endtask

    // Set An via MOVEQ→D0 then MOVEA.L D0,An.
    // MOVEA.L D0,An: 0010 An 001 000 000 (f_move_dst_mode=001=MOVEA, src=D0)
    task automatic set_an(input logic [2:0] an_num, input logic [7:0] v);
        set_dn(3'd0, v);
        run({4'h2, an_num, 3'b001, 3'b000, 3'b000}, 32'h0, 1'b0);
    endtask

    // Module-scope temporaries for test loops
    logic        fmt_err_seen;
    logic        saw_branch_05, saw_fmt_err_05;
    logic [31:0] high_cycles;
    int          i;

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        @(posedge rst_n);
        repeat(4) @(posedge clk);

        // Set supervisor mode for all tests
        @(posedge clk); #1;
        exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
        @(posedge clk); #1;
        exc_sr_wr_en = 0;
        repeat(2) @(posedge clk);

        // ── Setup A0=0x40, A1=0x50 once (used throughout CAS2 tests) ─────────
        // MOVEQ #0x40,D0 then MOVEA.L D0,A0
        set_an(3'd0, 8'h40);   // A0 = 0x40
        set_an(3'd1, 8'h50);   // A1 = 0x50

        // ══════════════════════════════════════════════════════════════════════
        // P71-01: CAS2.L match
        // CAS2.L D0:D2, D1:D3, (A0):(A1)
        // ext_data bits: [30:28]=Dc2=D2, [26:24]=Du2=D3, [19]=Rn2_an=1, [18:16]=A1=1
        //                [14:12]=Dc1=D0, [10:8]=Du1=D1,  [3]=Rn1_an=1,  [2:0]=A0=0
        $display("--- P71-01: CAS2.L match ---");
        begin
            set_dn(3'd0, 8'd4);   // D0 = 4  (Dc1)
            set_dn(3'd1, 8'd5);   // D1 = 5  (Du1 — written to M[Rn1] on match)
            set_dn(3'd2, 8'd6);   // D2 = 6  (Dc2)
            set_dn(3'd3, 8'd7);   // D3 = 7  (Du2 — written to M[Rn2] on match)

            // M[A0=0x40]=4 (==Dc1), M[A1=0x50]=6 (==Dc2) → both match
            mem_model_addr1 = 32'h40; mem_model_data1 = 32'd4;
            mem_model_addr2 = 32'h50; mem_model_data2 = 32'd6;
            write_cnt = 0;

            // CAS2.L D0:D2, D1:D3, (A0):(A1)
            // ext_data = bits computed as:
            //   [30:28]=2=010, [26:24]=3=011, [19]=1, [18:16]=001,
            //   [14:12]=0=000, [10:8]=1=001, [3]=1, [2:0]=000
            // = 0x23090108
            @(posedge clk); #1;
            instr_word  = 16'h0EFC;    // CAS2.L
            instr_valid = 1;
            ext_data    = 32'h2309_0108;
            ext_valid   = 1;
            @(posedge clk); #1;
            instr_valid = 0; ext_valid = 0;
            repeat(80) @(posedge clk);

            chk ("P71-01a: write_cnt=2",     write_cnt,      32'd2);
            chk ("P71-01b: wr0.addr=0x40",   write_addr[0],  32'h40);
            chk ("P71-01c: wr0.data=Du1=5",  write_data[0],  32'd5);
            chk ("P71-01d: wr1.addr=0x50",   write_addr[1],  32'h50);
            chk ("P71-01e: wr1.data=Du2=7",  write_data[1],  32'd7);
            chk1("P71-01f: Z=1 after match", sr_out[2],      1'b1);
        end

        // ══════════════════════════════════════════════════════════════════════
        // P71-02: CAS2.L mismatch — M[Rn1] != Dc1 → update Dc1,Dc2; no bus writes
        $display("--- P71-02: CAS2.L mismatch ---");
        begin
            // D0-D3 still have same values (4,5,6,7); D0 wasn't changed by match
            // M[A0=0x40] = 0x0F  (!=Dc1=4) → mismatch
            mem_model_data1 = 32'h0F;
            mem_model_data2 = 32'h0F;
            write_cnt = 0;

            @(posedge clk); #1;
            instr_word  = 16'h0EFC;
            instr_valid = 1;
            ext_data    = 32'h2309_0108;
            ext_valid   = 1;
            @(posedge clk); #1;
            instr_valid = 0; ext_valid = 0;
            repeat(80) @(posedge clk);

            chk ("P71-02a: write_cnt=0",        write_cnt, 32'd0);
            chk1("P71-02b: Z=0 after mismatch", sr_out[2], 1'b0);
        end

        // ══════════════════════════════════════════════════════════════════════
        // P71-03: CAS2.W match — D4:D6, D5:D7, (A0):(A1)
        // ext_data: [30:28]=6, [26:24]=7, [19]=1, [18:16]=1,
        //           [14:12]=4, [10:8]=5, [3]=1, [2:0]=0
        // = 0x6709_4508
        $display("--- P71-03: CAS2.W match ---");
        begin
            set_dn(3'd4, 8'h12);  // D4 = 0x12 (Dc1.W)
            set_dn(3'd5, 8'h34);  // D5 = 0x34 (Du1.W)
            set_dn(3'd6, 8'h56);  // D6 = 0x56 (Dc2.W)
            set_dn(3'd7, 8'h78);  // D7 = 0x78 (Du2.W)

            // Match: M[A0=0x40]=0x0012, M[A1=0x50]=0x0056
            mem_model_data1 = 32'h0000_0012;
            mem_model_data2 = 32'h0000_0056;
            write_cnt = 0;

            @(posedge clk); #1;
            instr_word  = 16'h0CFC;    // CAS2.W
            instr_valid = 1;
            ext_data    = 32'h6709_4508;
            ext_valid   = 1;
            @(posedge clk); #1;
            instr_valid = 0; ext_valid = 0;
            repeat(80) @(posedge clk);

            chk ("P71-03a: write_cnt=2",       write_cnt,     32'd2);
            chk ("P71-03b: wr0.addr=0x40",     write_addr[0], 32'h40);
            chk ("P71-03c: wr0.data=Du1=0x34", write_data[0], 32'h34);
            chk ("P71-03d: wr1.addr=0x50",     write_addr[1], 32'h50);
            chk ("P71-03e: wr1.data=Du2=0x78", write_data[1], 32'h78);
            chk1("P71-03f: Z=1",               sr_out[2],     1'b1);
        end

        // ══════════════════════════════════════════════════════════════════════
        // P71-04: Format Error — RTE with invalid format code $1 fires eu_fmt_err_req
        $display("--- P71-04: Format Error (code=1) ---");
        begin
            // Set ISP=0x100
            @(posedge clk); #1;
            ssp_wr_data = 32'h100; ssp_wr_en = 1;
            @(posedge clk); #1;
            ssp_wr_en = 0;
            repeat(2) @(posedge clk);

            // M[0x100] = {format=0x1 (invalid), SR=0x2700}
            // rte reads first longword from ISP=0x100; mem_rdata[31:28] is format code
            mem_model_addr1 = 32'h100;
            mem_model_data1 = 32'h1000_2700;   // format nibble = 0x1 → invalid
            mem_model_addr2 = 32'h104;
            mem_model_data2 = 32'h0000_5000;   // PC (unused on fmt_err)

            fmt_err_seen = 0;

            @(posedge clk); #1;
            instr_word  = 16'h4E73; // RTE
            instr_valid = 1;
            @(posedge clk); #1;
            instr_valid = 0;

            // Sample for 20 cycles
            for (i = 0; i < 20; i++) begin
                @(posedge clk);
                if (eu_fmt_err_req) fmt_err_seen = 1'b1;
            end

            chk1("P71-04: fmt_err fires on code=1", fmt_err_seen, 1'b1);
        end

        // ══════════════════════════════════════════════════════════════════════
        // P71-05: Format $0 valid — no eu_fmt_err_req, PC loaded
        $display("--- P71-05: Format $0 valid ---");
        begin
            // Restore supervisor + ISP
            @(posedge clk); #1;
            exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
            @(posedge clk); #1;
            exc_sr_wr_en = 0;
            @(posedge clk); #1;
            ssp_wr_data = 32'h100; ssp_wr_en = 1;
            @(posedge clk); #1;
            ssp_wr_en = 0;
            repeat(2) @(posedge clk);

            // M[0x100] = {format=0x0 (valid), SR=0x2700}; M[0x104]=PC=0x5000
            mem_model_data1 = 32'h0000_2700;   // format nibble = 0x0 → valid
            mem_model_data2 = 32'h0000_5000;   // new PC

            saw_branch_05  = 0;
            saw_fmt_err_05 = 0;

            @(posedge clk); #1;
            instr_word  = 16'h4E73; // RTE
            instr_valid = 1;
            @(posedge clk); #1;
            instr_valid = 0;

            for (i = 0; i < 20; i++) begin
                @(posedge clk);
                if (branch_taken)   saw_branch_05  = 1'b1;
                if (eu_fmt_err_req) saw_fmt_err_05 = 1'b1;
            end

            chk1("P71-05a: no fmt_err for code=0",   saw_fmt_err_05, 1'b0);
            chk1("P71-05b: branch taken (PC=0x5000)", saw_branch_05,  1'b1);
        end

        // ══════════════════════════════════════════════════════════════════════
        // P71-06: RESET duration — eu_reset_req stays high for ≥2048 ticks
        $display("--- P71-06: RESET duration ---");
        begin
            // Ensure supervisor mode and EU is idle
            @(posedge clk); #1;
            exc_sr_wr_data = 16'h2700; exc_sr_wr_en = 1;
            @(posedge clk); #1;
            exc_sr_wr_en = 0;
            repeat(10) @(posedge clk);

            high_cycles = 0;

            @(posedge clk); #1;
            instr_word  = 16'h4E70; // RESET
            instr_valid = 1;
            @(posedge clk); #1;
            instr_valid = 0;

            // Wait up to 10 cycles for eu_reset_req to rise
            for (i = 0; i < 10; i++) begin
                @(posedge clk);
                if (eu_reset_req) i = 10;  // break
            end

            if (!eu_reset_req) begin
                $display("FAIL  P71-06: eu_reset_req never rose (RESET did not execute)");
                fail_count++;
            end else begin
                // Count cycles while asserted
                while (eu_reset_req) begin
                    @(posedge clk);
                    high_cycles++;
                end
                chk1("P71-06a: active >= 2047 ticks", (high_cycles >= 32'd2047), 1'b1);
                chk1("P71-06b: active <= 2052 ticks", (high_cycles <= 32'd2052), 1'b1);
            end
        end

        // ─── Summary ─────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        $display("");
        $display("%0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

    // Timeout watchdog
    initial begin
        #1_000_000_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule

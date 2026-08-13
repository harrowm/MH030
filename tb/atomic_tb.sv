`default_nettype none
`timescale 1ns/1ps

// Atomic read-modify-write instruction tests
//
// TAS.B Dn:   test-and-set register byte; sets bit 7; checks N/Z flags
// TAS.B (An): atomic RMW — reads byte, checks flags, writes byte | 0x80
// CAS.L:      compare-and-swap longword (match → write Du; mismatch → load M into Dc)
// CAS.W:      compare-and-swap word (match → write Du)

module atomic_tb;

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
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // Memory: combinatorial ack, 8K longwords
    // Byte reads: EU reads byte from mem_rdata[7:0]
    // Byte writes: EU places byte in mem_wdata[31:24]
    logic [31:0] ram [0:8191];
    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    logic [31:0] last_mem_waddr;
    logic [31:0] last_mem_wdata;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw) begin
            ram[mem_addr[14:2]] <= mem_wdata;
            last_mem_waddr      <= mem_addr;
            last_mem_wdata      <= mem_wdata;
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

    // Standard instruction: wait for instr_ack then drain 12 cycles
    task automatic run_instr(input logic [15:0] iw, input logic has_ext,
                             input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw; instr_valid = 1'b1; ext_data = ext; ext_valid = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0; ext_valid = 1'b0;
        repeat(12) @(posedge clk);
    endtask

    // TAS.B (An): wait for eu_busy to deassert — RMW needs 2 bus cycles
    task automatic run_tas_mem(input logic [15:0] iw);
        @(posedge clk); #1;
        instr_word = iw; instr_valid = 1'b1; ext_valid = 1'b0;
        @(posedge clk); #1;
        instr_valid = 1'b0;
        repeat(50) begin
            @(posedge clk);
            if (!eu_busy) break;
        end
        repeat(4) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    initial begin
        for (int j = 0; j < 8192; j++) ram[j] = 32'h0;
        @(posedge rst_n); repeat(4) @(posedge clk);

        // ====================================================================
        // TAS.B Dn — register direct; sets bit 7 of byte, checks N/Z
        // TAS.B Dn encoding: 0x4AC0 | n
        $display("--- TAS.B: register direct ---");

        // TAS-01: D0=0x00000000 → byte=0x00: Z=1, N=0; D0 becomes 0x00000080
        set_dn(0, 32'h00000000);
        run_instr(16'h4AC0, 1'b0, 32'h0);
        chk("TAS-01:D0", dut.u_rf.d_reg[0], 32'h00000080);
        chk1("TAS-01:Z=1", sr_out[2], 1'b1);
        chk1("TAS-01:N=0", sr_out[3], 1'b0);
        chk1("TAS-01:V=0", sr_out[1], 1'b0);
        chk1("TAS-01:C=0", sr_out[0], 1'b0);

        // TAS-02: D1=0x41424344 → byte=0x44 (bit7=0): Z=0, N=0; byte → 0xC4
        set_dn(1, 32'h41424344);
        run_instr(16'h4AC1, 1'b0, 32'h0);
        chk("TAS-02:D1", dut.u_rf.d_reg[1], 32'h414243C4);
        chk1("TAS-02:Z=0", sr_out[2], 1'b0);
        chk1("TAS-02:N=0", sr_out[3], 1'b0);

        // TAS-03: D2=0xABCDEF80 → byte=0x80 (bit7=1): Z=0, N=1; byte unchanged
        set_dn(2, 32'hABCDEF80);
        run_instr(16'h4AC2, 1'b0, 32'h0);
        chk("TAS-03:D2", dut.u_rf.d_reg[2], 32'hABCDEF80);
        chk1("TAS-03:Z=0", sr_out[2], 1'b0);
        chk1("TAS-03:N=1", sr_out[3], 1'b1);

        // TAS-04: D3=0x12345600 → byte=0x00: Z=1, N=0; D3 becomes 0x12345680
        set_dn(3, 32'h12345600);
        run_instr(16'h4AC3, 1'b0, 32'h0);
        chk("TAS-04:D3", dut.u_rf.d_reg[3], 32'h12345680);
        chk1("TAS-04:Z=1", sr_out[2], 1'b1);
        chk1("TAS-04:N=0", sr_out[3], 1'b0);

        // ====================================================================
        // TAS.B (An) — memory RMW; byte read from mem_rdata[7:0],
        // written back to mem_wdata[31:24] with bit 7 set
        // TAS.B (An) encoding: 0x4AD0 | n
        $display("--- TAS.B: memory RMW ---");

        // TAS-05: M[0x000]=0x00 → Z=1, N=0; write 0x80 to [31:24]
        ram[0] = 32'h0000_0000;
        set_an(3'd0, 32'h0000_0000);
        run_tas_mem(16'h4AD0);
        chk1("TAS-05:Z=1", sr_out[2], 1'b1);
        chk1("TAS-05:N=0", sr_out[3], 1'b0);
        chk1("TAS-05:V=0", sr_out[1], 1'b0);
        chk1("TAS-05:C=0", sr_out[0], 1'b0);
        chk("TAS-05:wdata", {24'h0, last_mem_wdata[31:24]}, 32'h00000080);
        chk("TAS-05:waddr", last_mem_waddr, 32'h0000_0000);

        // TAS-06: M[0x010]=0x42 (bit7=0) → Z=0, N=0; write 0xC2
        ram[32'h10>>2] = 32'h0000_0042;
        set_an(3'd0, 32'h0000_0010);
        run_tas_mem(16'h4AD0);
        chk1("TAS-06:Z=0", sr_out[2], 1'b0);
        chk1("TAS-06:N=0", sr_out[3], 1'b0);
        chk("TAS-06:wdata", {24'h0, last_mem_wdata[31:24]}, 32'h000000C2);

        // TAS-07: M[0x020]=0x80 (bit7=1) → Z=0, N=1; write 0x80 (unchanged)
        ram[32'h20>>2] = 32'h0000_0080;
        set_an(3'd0, 32'h0000_0020);
        run_tas_mem(16'h4AD0);
        chk1("TAS-07:Z=0", sr_out[2], 1'b0);
        chk1("TAS-07:N=1", sr_out[3], 1'b1);
        chk("TAS-07:wdata", {24'h0, last_mem_wdata[31:24]}, 32'h00000080);

        // TAS-08: TAS.B (A1) at 0x0030, M[0x030]=0x55; A1 must be unchanged after TAS
        ram[32'h30>>2] = 32'h0000_0055;
        set_an(3'd1, 32'h0000_0030);
        run_tas_mem(16'h4AD1);
        chk("TAS-08:A1_unchanged", dut.u_rf.a_reg[1], 32'h0000_0030);
        chk("TAS-08:wdata", {24'h0, last_mem_wdata[31:24]}, 32'h000000D5);

        // ====================================================================
        // CAS — compare-and-swap
        // CAS.L D2,D3,(A0): opcode=0x0ED0, ext={...,Dc=D2(010),Du=D3(011)}=0x0083
        // CAS.W D2,D3,(A0): opcode=0x06D0, same ext=0x0083
        $display("--- CAS: compare-and-swap ---");

        // CAS-01: CAS.L match — M[0x100]=0xABCD_1234=D2 → write D3=0x5678_9ABC; Z=1
        ram[32'h100>>2] = 32'hABCD_1234;
        set_an(3'd0, 32'h0000_0100);
        set_dn(2, 32'hABCD_1234);
        set_dn(3, 32'h5678_9ABC);
        run_instr(16'h0ED0, 1'b1, 32'h0083);
        chk("CAS-01:mem", ram[32'h100>>2], 32'h5678_9ABC);
        chk1("CAS-01:Z=1", sr_out[2], 1'b1);

        // CAS-02: CAS.L mismatch — M[0x104]=0x1111_2222 ≠ D2=0xFFFF_FFFF
        //         M unchanged; D2 loaded with M[EA]=0x1111_2222; Z=0
        ram[32'h104>>2] = 32'h1111_2222;
        set_an(3'd0, 32'h0000_0104);
        set_dn(2, 32'hFFFF_FFFF);
        set_dn(3, 32'h5678_9ABC);
        run_instr(16'h0ED0, 1'b1, 32'h0083);
        chk("CAS-02:mem_unchanged", ram[32'h104>>2], 32'h1111_2222);
        chk1("CAS-02:Z=0", sr_out[2], 1'b0);
        chk("CAS-02:D2_loaded", dut.u_rf.d_reg[2], 32'h1111_2222);

        // CAS-03: CAS.W match — M[0x108]=0x0000_ABCD, D2=0x0000_ABCD → write D3=0x0000_5678; Z=1
        ram[32'h108>>2] = 32'h0000_ABCD;
        set_an(3'd0, 32'h0000_0108);
        set_dn(2, 32'h0000_ABCD);
        set_dn(3, 32'h0000_5678);
        run_instr(16'h06D0, 1'b1, 32'h0083);
        chk("CAS-03:mem", ram[32'h108>>2], 32'h0000_5678);
        chk1("CAS-03:Z=1", sr_out[2], 1'b1);

        repeat(4) @(posedge clk);
        $display("");
        if (fail_count == 0)
            $display("PASS: %0d checks passed", pass_count);
        else
            $display("FAIL: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule

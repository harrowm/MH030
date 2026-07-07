// Phase 58: MULS.L/MULU.L/DIVS.L/DIVU.L — long multiply and divide
//
// Opcode word: 0100 1100 ss 000 Dn_src
//   f_dn=110, f_dir=0; f_ss=00=MUL, f_ss=01=DIV; f_mode=000 (Dn direct)
// Extension word: {0, Dh/Dr[2:0], 0, sz/0, 3'b0, sign, 3'b0, Dl/Dq[2:0]}
//   sz (bit10): MUL only: 0=32-bit (Dl only), 1=64-bit (Dh:Dl)
//   sign (bit6): 0=unsigned, 1=signed
//   DIV 64-bit: inferred by Dr≠Dq; both written when different
//
//   P58-1: MULU.L D0,D1        — unsigned 7×6=42 (32-bit result)
//   P58-2: MULU.L D2,D4:D3    — unsigned 3×0x80000000 (64-bit result)
//   P58-3: MULS.L D4,D5        — signed  (-2)×3=-6 (32-bit result)
//   P58-4: MULS.L D4,D6:D5    — signed  (-2)×3=-6 (64-bit result)
//   P58-5: DIVU.L D0,D2:D1    — unsigned 100÷7, quot=14 rem=2
//   P58-6: DIVS.L D1,D3:D2    — signed   17÷(-3), quot=-5 rem=2
//   P58-7: DIVU.L D0,D1:D1    — Dr=Dq same, only quotient (10÷3=3)
//   P58-8: DIVU.L D0,D2:D1 div-by-zero — div_trap asserts

`default_nettype none
`timescale 1ns/1ps

module seq58_tb;

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
    logic [31:0] decode_pc = 32'h0;
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
    logic        eu_coproc_ack  = 0;
    logic        eu_coproc_berr = 0;
    logic [31:0] eu_coproc_rdata= 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack = 0;
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
    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x         (clk),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .ext_valid      (ext_valid),
        .instr_ack      (instr_ack),
        .eu_busy        (eu_busy),
        .pc_wr_en       (pc_wr_en),
        .pc_wr_data     (pc_wr_data),
        .pc_out         (pc_out),
        .vbr_wr_en      (vbr_wr_en),
        .vbr_wr_data    (vbr_wr_data),
        .vbr_out        (vbr_out),
        .usp_out        (usp_out),
        .msp_out        (msp_out),
        .isp_out        (isp_out),
        .cacr_out       (cacr_out),
        .caar_out       (caar_out),
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
        .mem_rmw        (mem_rmw),
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
        .an_wr_en       (an_wr_en),
        .an_wr_sel      (an_wr_sel),
        .an_wr_data     (an_wr_data),
        .div_trap       (div_trap),
        .chk_trap       (chk_trap),
        .eu_trap_req    (eu_trap_req),
        .eu_trap_num    (eu_trap_num),
        .eu_trapv_req   (eu_trapv_req),
        .eu_illegal_req (eu_illegal_req),
        .eu_stop        (eu_stop),
        .ssp_wr_en      (ssp_wr_en),
        .ssp_wr_data    (ssp_wr_data),
        .exc_sr_wr_en   (exc_sr_wr_en),
        .exc_sr_wr_data (exc_sr_wr_data)
    );

    // ─── combinational memory stub ────────────────────────────────────────────
    assign mem_ack   = mem_req;
    assign mem_rdata = 32'h0;

    // ─── test infrastructure ─────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else begin
            pass_cnt++;
        end
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        chk(tag, {31'h0, got}, {31'h0, exp});
    endtask

    // Issue instruction (with optional extension word), wait for instr_ack, then
    // drain 4 cycles so WB is guaranteed complete on return.
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
        repeat(4) @(posedge clk);
    endtask

    // Load arbitrary value into Dn (CLR.L Dn + ADDI.L #val,Dn).
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        logic [15:0] clr_w, addi_w;
        clr_w  = 16'h4280 | {13'h0, n};
        addi_w = 16'h0680 | {13'h0, n};
        run_instr(clr_w,  1'b0, 32'h0);
        run_instr(addi_w, 1'b1, val);
    endtask

    // Present instruction, drain, and capture whether div_trap was seen in EX.
    // div_trap fires 1 cycle after instr_ack (when instruction enters EX).
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

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ====================================================================
        // P58-1: MULU.L D0, D1 — unsigned 32-bit result (7 × 6 = 42)
        // Opcode: 0x4C00 (f_ss=00, f_reg=0=D0)
        // Extension: Dh=D2(010), sz=0, sign=0, Dl=D1(001) = 0x2001
        // ====================================================================
        $display("--- P58-1: MULU.L D0,D1 (7x6=42, 32-bit) ---");
        set_dn(3'd0, 32'd7);
        set_dn(3'd1, 32'd6);
        begin
            logic [15:0] ccr_before;
            ccr_before = sr_out;
            run_instr(16'h4C00, 1'b1, {16'h0, 16'h2001});
            chk("P58-1a: D1=42",       dut.u_rf.d_reg[1], 32'd42);
            chk("P58-1b: D2 unchanged", dut.u_rf.d_reg[2], 32'h0);  // Dh not written (sz=0)
            chk1("P58-1c: N=0", sr_out[3], 1'b0);
            chk1("P58-1d: Z=0", sr_out[2], 1'b0);
            chk1("P58-1e: V=0", sr_out[1], 1'b0);
            chk1("P58-1f: C=0", sr_out[0], 1'b0);
        end

        // ====================================================================
        // P58-2: MULU.L D2, D4:D3 — unsigned 64-bit result
        // 3 × 0x80000000 = 0x1_8000_0000 → D4=1, D3=0x80000000
        // Opcode: 0x4C02 (f_reg=2=D2)
        // Extension: Dh=D4(100), sz=1, sign=0, Dl=D3(011) = 0x4403
        // ====================================================================
        $display("--- P58-2: MULU.L D2,D4:D3 (64-bit) ---");
        set_dn(3'd2, 32'd3);
        set_dn(3'd3, 32'h8000_0000);
        run_instr(16'h4C02, 1'b1, {16'h0, 16'h4403});
        chk("P58-2a: D3=0x80000000", dut.u_rf.d_reg[3], 32'h8000_0000);
        chk("P58-2b: D4=1",         dut.u_rf.d_reg[4], 32'd1);
        chk1("P58-2c: N=0", sr_out[3], 1'b0);  // product[63]=0 (0x1_8000_0000 fits in 33 bits)
        chk1("P58-2d: Z=0", sr_out[2], 1'b0);  // 64-bit result != 0

        // ====================================================================
        // P58-3: MULS.L D4, D5 — signed 32-bit result ((-2) × 3 = -6)
        // Opcode: 0x4C04 (f_reg=4=D4)
        // Extension: Dh=D6(110), sz=0, sign=1, Dl=D5(101) = 0x6045
        // ====================================================================
        $display("--- P58-3: MULS.L D4,D5 (32-bit signed) ---");
        set_dn(3'd4, 32'hFFFF_FFFE);  // -2
        set_dn(3'd5, 32'd3);
        begin
            logic [31:0] d6_before;
            d6_before = dut.u_rf.d_reg[6];
            run_instr(16'h4C04, 1'b1, {16'h0, 16'h6045});
            chk("P58-3a: D5=-6",       dut.u_rf.d_reg[5], 32'hFFFF_FFFA);
            chk("P58-3b: D6 unchanged", dut.u_rf.d_reg[6], d6_before);  // Dh not written (sz=0)
            chk1("P58-3c: N=1", sr_out[3], 1'b1);
            chk1("P58-3d: Z=0", sr_out[2], 1'b0);
        end

        // ====================================================================
        // P58-4: MULS.L D4, D6:D5 — signed 64-bit result ((-2) × 3 = -6)
        // Full 64-bit: 0xFFFFFFFF_FFFFFFFA → D6=0xFFFFFFFF, D5=0xFFFFFFFA
        // Opcode: 0x4C04 (f_reg=4=D4)
        // Extension: Dh=D6(110), sz=1, sign=1, Dl=D5(101) = 0x6445
        // ====================================================================
        $display("--- P58-4: MULS.L D4,D6:D5 (64-bit signed) ---");
        set_dn(3'd4, 32'hFFFF_FFFE);  // -2
        set_dn(3'd5, 32'd3);
        run_instr(16'h4C04, 1'b1, {16'h0, 16'h6445});
        chk("P58-4a: D5=0xFFFFFFFA", dut.u_rf.d_reg[5], 32'hFFFF_FFFA);
        chk("P58-4b: D6=0xFFFFFFFF", dut.u_rf.d_reg[6], 32'hFFFF_FFFF);
        chk1("P58-4c: N=1", sr_out[3], 1'b1);
        chk1("P58-4d: Z=0", sr_out[2], 1'b0);

        // ====================================================================
        // P58-5: DIVU.L D0, D2:D1 — unsigned 100 ÷ 7 = quot 14 rem 2
        // D0=7 (divisor), D1=100 (dividend→Dq), D2=Dr
        // Opcode: 0x4C40 (f_ss=01, f_reg=0=D0)
        // Extension: Dr=D2(010), sign=0, Dq=D1(001) = 0x2001
        // ====================================================================
        $display("--- P58-5: DIVU.L D0,D2:D1 (100/7=14 rem 2) ---");
        set_dn(3'd0, 32'd7);
        set_dn(3'd1, 32'd100);
        run_instr(16'h4C40, 1'b1, {16'h0, 16'h2001});
        chk("P58-5a: D1(Dq)=14", dut.u_rf.d_reg[1], 32'd14);
        chk("P58-5b: D2(Dr)=2",  dut.u_rf.d_reg[2], 32'd2);
        chk1("P58-5c: N=0", sr_out[3], 1'b0);
        chk1("P58-5d: Z=0", sr_out[2], 1'b0);
        chk1("P58-5e: V=0", sr_out[1], 1'b0);
        chk1("P58-5f: C=0", sr_out[0], 1'b0);

        // ====================================================================
        // P58-6: DIVS.L D1, D3:D2 — signed 17 ÷ (-3) = quot -5 rem 2
        // D1=-3=0xFFFFFFFD (divisor), D2=17 (dividend→Dq), D3=Dr
        // Opcode: 0x4C41 (f_ss=01, f_reg=1=D1)
        // Extension: Dr=D3(011), sign=1, Dq=D2(010) = 0x3042
        // ====================================================================
        $display("--- P58-6: DIVS.L D1,D3:D2 (17/-3=quot -5 rem 2) ---");
        set_dn(3'd1, 32'hFFFF_FFFD);  // -3
        set_dn(3'd2, 32'd17);
        run_instr(16'h4C41, 1'b1, {16'h0, 16'h3042});
        chk("P58-6a: D2(Dq)=-5", dut.u_rf.d_reg[2], 32'hFFFF_FFFB);
        chk("P58-6b: D3(Dr)=2",  dut.u_rf.d_reg[3], 32'd2);
        chk1("P58-6c: N=1", sr_out[3], 1'b1);
        chk1("P58-6d: Z=0", sr_out[2], 1'b0);
        chk1("P58-6e: V=0", sr_out[1], 1'b0);

        // ====================================================================
        // P58-7: DIVU.L D0, D1:D1 — Dr=Dq same register (10 ÷ 3 = 3)
        // Only quotient written to D1; remainder discarded
        // Opcode: 0x4C40 (f_reg=0=D0)
        // Extension: Dr=D1(001), sign=0, Dq=D1(001) = 0x1001  [Dr==Dq → 32-bit mode]
        // ====================================================================
        $display("--- P58-7: DIVU.L D0,D1:D1 (Dr=Dq, 10/3=3) ---");
        set_dn(3'd0, 32'd3);
        set_dn(3'd1, 32'd10);
        run_instr(16'h4C40, 1'b1, {16'h0, 16'h1001});
        chk("P58-7a: D1(Dq)=3", dut.u_rf.d_reg[1], 32'd3);

        // ====================================================================
        // P58-8: DIVU.L divide-by-zero → div_trap
        // D0=0 (divisor), D1=100 (dividend)
        // Opcode: 0x4C40 (f_reg=0=D0)
        // Extension: Dr=D2(010), sign=0, Dq=D1(001) = 0x2001
        // ====================================================================
        $display("--- P58-8: DIVU.L div-by-zero → div_trap ---");
        set_dn(3'd0, 32'd0);
        set_dn(3'd1, 32'd100);
        begin
            logic saw;
            run_div(16'h4C40, {16'h0, 16'h2001}, saw);
            chk1("P58-8: div_trap asserted", saw, 1'b1);
        end

        // ====================================================================
        // P58-9: MULU.L D0,D0 — Z flag (0 × 5 = 0)
        // Opcode: 0x4C00 (f_reg=0=D0)
        // Extension: Dh=D1(001), sz=0, sign=0, Dl=D0(000) = 0x1000
        // ====================================================================
        $display("--- P58-9: MULU.L D0,D0 (0x0=0, Z flag) ---");
        set_dn(3'd0, 32'd0);
        run_instr(16'h4C00, 1'b1, {16'h0, 16'h1000});
        chk("P58-9a: D0=0",  dut.u_rf.d_reg[0], 32'h0);
        chk1("P58-9b: Z=1",  sr_out[2], 1'b1);
        chk1("P58-9c: N=0",  sr_out[3], 1'b0);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("");
        if (fail_cnt == 0)
            $display("PASS all %0d checks", pass_cnt);
        else
            $display("FAIL %0d/%0d checks failed", fail_cnt, pass_cnt + fail_cnt);
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL timeout");
        $finish;
    end

endmodule

`default_nettype wire

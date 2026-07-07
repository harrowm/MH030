// Phase 59: PEA, EXG, RTD, CMPM
//
// PEA (An)/(d16,An)/(xxx).L — push effective address to -(A7)
// EXG Dx,Dy / Ax,Ay / Dx,Ay — register exchange (no memory, no CCR change)
// RTD #d16  — RTS-like but A7 += 4+d16 (reuses RTS FSM)
// CMPM (Ay)+,(Ax)+ — two-phase memory compare with postincrement, CCR update
//
//   P59-1: PEA (A0)                  — push A0 value to -(A7)
//   P59-2: PEA (d16,A1), d16=+0x20   — push A1+0x20 to -(A7)
//   P59-3: PEA (xxx).L, abs=0x1CAFE  — push absolute 0x1CAFE to -(A7)
//   P59-4: EXG D3,D5                 — swap Dx,Dy via wr2 port
//   P59-5: EXG A2,A3                 — swap Ax,Ay via an_wr port
//   P59-6: EXG D2,A4                 — swap Dx,Ay (main WB + an_wr)
//   P59-7: RTD #4                    — PC←M[A7], A7+=8
//   P59-8: CMPM.B (A0)+,(A1)+        — byte compare, A0/A1 postinc by 1
//   P59-9: CMPM.W (A0)+,(A1)+        — word compare equal, Z=1

`default_nettype none
`timescale 1ns/1ps

module seq59_tb;

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
    logic [31:0] decode_pc = 32'h0000_1000;
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

    // ─── Memory model: 256-entry 32-bit RAM, word-addressed ──────────────────
    logic [31:0] ram [0:255];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[9:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;
    end

    // Latch branch_taken so it can be checked after drain cycles.
    logic saw_branch;
    logic [31:0] last_target;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_branch   <= 1'b0;
            last_target  <= 32'h0;
        end else if (branch_taken) begin
            saw_branch  <= 1'b1;
            last_target <= branch_target;
        end
    end

    // ─── test helpers ────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

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

    // Present instruction, wait for instr_ack, then drain 5 cycles for WB.
    task automatic run_instr(input logic [15:0] w0,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        saw_branch  = 1'b0;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(5) @(posedge clk);
    endtask

    // Load Dn: CLR.L Dn + ADDI.L #val,Dn
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);         // CLR.L Dn
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);            // ADDI.L #val,Dn
    endtask

    // Load An via MOVEA.L D0,An (first loads D0 via set_dn)
    // MOVEA.L D0,An: 0010 An[2:0] 001 000 000
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);                       // CLR.L D0
        run_instr(16'h0680, 1'b1, val);                         // ADDI.L #val,D0
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0); // MOVEA.L D0,An
    endtask

    // Set ISP (A7 in supervisor mode) directly via port
    task automatic set_isp(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk); #1;
        ssp_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ==================================================================
        // P59-1: PEA (A0) — push A0's address value to -(A7)
        // PEA (An): opcode = 0100 1000 0101 0rrr, f_mode=010, f_reg=0 → 0x4850
        // A0=0x1234_5600, A7=0x0300 → M[0x02FC]=0x1234_5600, A7=0x02FC
        // ==================================================================
        $display("--- P59-1: PEA (A0) ---");
        set_an(3'd0, 32'h1234_5600);
        set_isp(32'h0000_0300);
        run_instr(16'h4850, 1'b0, 32'h0);
        chk("P59-1a: stack=A0",  ram[32'h02FC >> 2], 32'h1234_5600);
        chk("P59-1b: A7=0x02FC", isp_out,            32'h0000_02FC);

        // ==================================================================
        // P59-2: PEA (d16,A1) — push A1+d16 to -(A7)
        // Opcode: 0100 1000 0110 1001 = 0x4869 (f_mode=101, f_reg=1=A1)
        // A1=0x5000, d16=0x0020 → push 0x5020; A7=0x0300→0x02FC
        // ==================================================================
        $display("--- P59-2: PEA (d16,A1) ---");
        set_an(3'd1, 32'h0000_5000);
        set_isp(32'h0000_0300);
        run_instr(16'h4869, 1'b1, {16'h0, 16'h0020});
        chk("P59-2a: stack=A1+d16", ram[32'h02FC >> 2], 32'h0000_5020);
        chk("P59-2b: A7=0x02FC",    isp_out,            32'h0000_02FC);

        // ==================================================================
        // P59-3: PEA (xxx).L — push 32-bit absolute address to -(A7)
        // Opcode: 0100 1000 0111 1001 = 0x4879 (f_mode=111, f_reg=001)
        // ext (2 words) = 0x0001_CAFE → push 0x0001_CAFE; A7=0x0300→0x02FC
        // ==================================================================
        $display("--- P59-3: PEA (xxx).L ---");
        set_isp(32'h0000_0300);
        run_instr(16'h4879, 1'b1, 32'h0001_CAFE);
        chk("P59-3a: stack=abs",  ram[32'h02FC >> 2], 32'h0001_CAFE);
        chk("P59-3b: A7=0x02FC", isp_out,             32'h0000_02FC);

        // ==================================================================
        // P59-4: EXG D3,D5 — Dx,Dy swap via wr + wr2 port
        // Opcode: 1100 011 1 01 000 101 = 0xC745
        //   f_group=C, f_dn=3, f_dir=1, f_ss=01, f_mode=000, f_reg=5
        // D3=0xAAAAAAAA, D5=0x55555555 → D3=0x55555555, D5=0xAAAAAAAA
        // ==================================================================
        $display("--- P59-4: EXG D3,D5 ---");
        set_dn(3'd3, 32'hAAAA_AAAA);
        set_dn(3'd5, 32'h5555_5555);
        run_instr(16'hC745, 1'b0, 32'h0);
        chk("P59-4a: D3=D5_orig", dut.u_rf.d_reg[3], 32'h5555_5555);
        chk("P59-4b: D5=D3_orig", dut.u_rf.d_reg[5], 32'hAAAA_AAAA);

        // ==================================================================
        // P59-5: EXG A2,A3 — Ax,Ay swap via main WB (A2←A3) + an_wr (A3←A2)
        // Opcode: 1100 010 1 01 001 011 = 0xC54B
        //   f_group=C, f_dn=2, f_dir=1, f_ss=01, f_mode=001, f_reg=3
        // A2=0x0001_1111, A3=0x0002_2222 → A2=0x0002_2222, A3=0x0001_1111
        // ==================================================================
        $display("--- P59-5: EXG A2,A3 ---");
        set_an(3'd2, 32'h0001_1111);
        set_an(3'd3, 32'h0002_2222);
        run_instr(16'hC54B, 1'b0, 32'h0);
        chk("P59-5a: A2=A3_orig", dut.u_rf.a_reg[2], 32'h0002_2222);
        chk("P59-5b: A3=A2_orig", dut.u_rf.a_reg[3], 32'h0001_1111);

        // ==================================================================
        // P59-6: EXG D2,A4 — Dx,Ay swap via main WB (D2←A4) + an_wr (A4←D2)
        // Opcode: 1100 010 1 10 001 100 = 0xC58C
        //   f_group=C, f_dn=2, f_dir=1, f_ss=10, f_mode=001, f_reg=4
        // D2=0x0000_3333, A4=0x0000_4444 → D2=0x0000_4444, A4=0x0000_3333
        // ==================================================================
        $display("--- P59-6: EXG D2,A4 ---");
        set_dn(3'd2, 32'h0000_3333);
        set_an(3'd4, 32'h0000_4444);
        run_instr(16'hC58C, 1'b0, 32'h0);
        chk("P59-6a: D2=A4_orig", dut.u_rf.d_reg[2], 32'h0000_4444);
        chk("P59-6b: A4=D2_orig", dut.u_rf.a_reg[4], 32'h0000_3333);

        // ==================================================================
        // P59-7: RTD #4 — PC←M[A7], A7 += 4+4 = 8
        // Opcode: 0x4E74, ext = 0x0004 (d16=+4)
        // A7=0x0200; ram[0x0200>>2]=0xCAFE_1000 (return PC)
        // Expected: branch_target=0xCAFE_1000, A7=0x0208
        // ==================================================================
        $display("--- P59-7: RTD #4 ---");
        set_isp(32'h0000_0200);
        ram[32'h0200 >> 2] = 32'hCAFE_1000;
        run_instr(16'h4E74, 1'b1, {16'h0, 16'h0004});
        chk1("P59-7a: branch_taken",    saw_branch,    1'b1);
        chk("P59-7b: branch_target",    last_target,   32'hCAFE_1000);
        chk("P59-7c: A7=0x0200+8",     isp_out,       32'h0000_0208);

        // ==================================================================
        // P59-8: CMPM.B (A0)+,(A1)+ — byte compare M[A1]-M[A0], both postinc
        // Opcode: 1011 001 1 00 001 000 = 0xB308
        //   f_group=B, f_dn=A1(001), f_dir=1, f_ss=00=byte, f_mode=001, f_reg=A0(000)
        // A0=0x0100, A1=0x0104; M[0x0100]=5, M[0x0104]=8
        // CMP: M[A1]-M[A0] = 8-5 = 3 → N=0, Z=0, V=0, C=0
        // After: A0=0x0101, A1=0x0105
        // ==================================================================
        $display("--- P59-8: CMPM.B (A0)+,(A1)+ ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0104);
        ram[32'h0100 >> 2] = 32'h0000_0005;  // M[A0] = 5 (byte in [7:0])
        ram[32'h0104 >> 2] = 32'h0000_0008;  // M[A1] = 8 (byte in [7:0])
        run_instr(16'hB308, 1'b0, 32'h0);
        chk1("P59-8a: N=0", sr_out[3], 1'b0);
        chk1("P59-8b: Z=0", sr_out[2], 1'b0);
        chk1("P59-8c: V=0", sr_out[1], 1'b0);
        chk1("P59-8d: C=0", sr_out[0], 1'b0);
        chk("P59-8e: A0=0x0101", dut.u_rf.a_reg[0], 32'h0000_0101);
        chk("P59-8f: A1=0x0105", dut.u_rf.a_reg[1], 32'h0000_0105);

        // ==================================================================
        // P59-9: CMPM.W (A0)+,(A1)+ — equal values → Z=1
        // Opcode: 1011 001 1 01 001 000 = 0xB348
        //   f_ss=01=word, step=2
        // A0=0x0110, A1=0x0114; M[0x0110]=0x1234, M[0x0114]=0x1234 → Z=1
        // After: A0=0x0112, A1=0x0116
        // ==================================================================
        $display("--- P59-9: CMPM.W (A0)+,(A1)+ equal ---");
        set_an(3'd0, 32'h0000_0110);
        set_an(3'd1, 32'h0000_0114);
        ram[32'h0110 >> 2] = 32'h0000_1234;  // M[A0] word
        ram[32'h0114 >> 2] = 32'h0000_1234;  // M[A1] word
        run_instr(16'hB348, 1'b0, 32'h0);
        chk1("P59-9a: Z=1", sr_out[2], 1'b1);
        chk1("P59-9b: N=0", sr_out[3], 1'b0);
        chk("P59-9c: A0=0x0112", dut.u_rf.a_reg[0], 32'h0000_0112);
        chk("P59-9d: A1=0x0116", dut.u_rf.a_reg[1], 32'h0000_0116);

        // ─── summary ─────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("PASS  seq59 (%0d checks)", pass_cnt);
        else
            $display("FAIL  seq59: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

endmodule

`default_nettype wire

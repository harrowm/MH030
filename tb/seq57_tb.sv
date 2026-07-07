// Phase 57: ADDA/SUBA/CMPA + ORI/ANDI/EORI to CCR/SR
//
//   P57-1:  ADDA.L D0,A0   — longword add, CCR unchanged
//   P57-2:  ADDA.W D1,A1   — word add with sign extension (-1)
//   P57-3:  ADDA.L A2,A2   — An-direct source, doubles A2
//   P57-4:  ADDA.W #-2,A3  — immediate word source (sign-extended)
//   P57-5:  ADDA.L #imm,A4 — immediate longword source
//   P57-6:  SUBA.L D0,A5   — longword subtract, CCR unchanged
//   P57-7:  SUBA.W D1,A6   — word subtract with sign extension
//   P57-8:  CMPA.L D2,A0   — unequal then equal, Z-flag check
//   P57-9:  CMPA.W D3,A1   — 32-bit compare after sign extension
//   P57-10: ORI  #0x1F,CCR — sets all CCR bits
//   P57-11: ANDI #0x10,CCR — keeps X, clears rest
//   P57-12: EORI #0x11,CCR — toggles X and C
//   P57-13: ORI  #0x0001,SR — sets C in full SR
//   P57-14: ANDI #0xFFFE,SR — clears C in full SR
//   P57-15: EORI #0x0010,SR — toggles X in full SR

`default_nettype none
`timescale 1ns/1ps

module seq57_tb;

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
            $display("PASS %s", tag);
            pass_cnt++;
        end
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        chk(tag, {31'h0, got}, {31'h0, exp});
    endtask

    // Issue instruction, wait up to 200 cycles for instr_ack, then drain 4
    // cycles so WB (pipeline stage 3) is guaranteed complete on return.
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

    // CLR.L D0 then ADDI.L #val,D0 — loads arbitrary 32-bit value into D0.
    task automatic set_d0(input logic [31:0] val);
        run_instr(16'h4280, 0, 32'h0);  // CLR.L D0
        run_instr(16'h0680, 1, val);     // ADDI.L #val,D0
    endtask

    // Load arbitrary 32-bit value into Dn (CLR.L Dn + ADDI.L #val,Dn).
    // CLR.L Dn = 0x4280|n; ADDI.L #val,Dn = 0x0680|n
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        logic [15:0] clr_w, addi_w;
        clr_w  = 16'h4280 | {13'h0, n};
        addi_w = 16'h0680 | {13'h0, n};
        run_instr(clr_w,  0, 32'h0);
        run_instr(addi_w, 1, val);
    endtask

    // Load val into An by first loading D0=val, then MOVEA.L D0,An.
    // MOVEA.L D0,An = {0010, An, 001, 000, 000}. Clobbers D0.
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        logic [15:0] movea_w;
        movea_w = {4'h2, an, 3'b001, 3'b000, 3'b000};
        set_d0(val);
        run_instr(movea_w, 0, 32'h0);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ====================================================================
        // P57-1: ADDA.L D0,A0 — 32-bit add to An, CCR unchanged
        // D0=100, A0=200 → A0=300
        // Opcode: {4'hD, 3'b000(A0), 1'b1(.L), 2'b11, 3'b000(Dn), 3'b000(D0)} = 0xD1C0
        // ====================================================================
        $display("--- P57-1: ADDA.L D0,A0 ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd0, 32'd200);    // A0=200; D0 clobbered
            set_dn(3'd0, 32'd100);    // D0=100
            sr_before = sr_out;
            run_instr(16'hD1C0, 0, 32'h0);
            chk ("P57-1a: A0 = 300",      dut.u_rf.a_reg[0], 32'd300);
            chk ("P57-1b: CCR unchanged", {16'h0, sr_out},    {16'h0, sr_before});
        end

        // ====================================================================
        // P57-2: ADDA.W D1,A1 — sign-extend D1[15:0] to 32 bits, then add
        // D1=0xFFFFFFFF (D1[15:0]=0xFFFF→sext=-1), A1=10 → A1=9
        // Opcode: {4'hD, 3'b001(A1), 1'b0(.W), 2'b11, 3'b000(Dn), 3'b001(D1)} = 0xD2C1
        // ====================================================================
        $display("--- P57-2: ADDA.W D1,A1 sign-extend ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd1, 32'd10);
            set_dn(3'd1, 32'hFFFF_FFFF);  // D1[15:0]=0xFFFF → sext=-1
            sr_before = sr_out;
            run_instr(16'hD2C1, 0, 32'h0);
            chk ("P57-2a: A1 = 9",         dut.u_rf.a_reg[1], 32'd9);
            chk ("P57-2b: CCR unchanged",  {16'h0, sr_out},    {16'h0, sr_before});
        end

        // ====================================================================
        // P57-3: ADDA.L A2,A2 — An-direct source, doubles A2
        // A2=50 → A2=100
        // Opcode: {4'hD, 3'b010(A2), 1'b1(.L), 2'b11, 3'b001(An), 3'b010(A2)} = 0xD5CA
        // ====================================================================
        $display("--- P57-3: ADDA.L A2,A2 ---");
        begin
            set_an(3'd2, 32'd50);
            run_instr(16'hD5CA, 0, 32'h0);
            chk("P57-3: A2 = 100", dut.u_rf.a_reg[2], 32'd100);
        end

        // ====================================================================
        // P57-4: ADDA.W #-2,A3 — immediate word (sign-extended to -2)
        // A3=20, imm=0xFFFE(sext=-2) → A3=18
        // Opcode: {4'hD, 3'b011(A3), 1'b0(.W), 2'b11, 3'b111, 3'b100(#imm)} = 0xD6FC
        // ====================================================================
        $display("--- P57-4: ADDA.W #-2,A3 ---");
        begin
            set_an(3'd3, 32'd20);
            run_instr(16'hD6FC, 1, {16'h0, 16'hFFFE});
            chk("P57-4: A3 = 18", dut.u_rf.a_reg[3], 32'd18);
        end

        // ====================================================================
        // P57-5: ADDA.L #0x12345678,A4 — immediate longword
        // A4=0, imm=0x12345678 → A4=0x12345678
        // Opcode: {4'hD, 3'b100(A4), 1'b1(.L), 2'b11, 3'b111, 3'b100(#imm)} = 0xD9FC
        // ====================================================================
        $display("--- P57-5: ADDA.L #0x12345678,A4 ---");
        begin
            set_an(3'd4, 32'h0);
            run_instr(16'hD9FC, 1, 32'h1234_5678);
            chk("P57-5: A4 = 0x12345678", dut.u_rf.a_reg[4], 32'h1234_5678);
        end

        // ====================================================================
        // P57-6: SUBA.L D0,A5 — longword subtract to An, CCR unchanged
        // D0=100, A5=300 → A5=200
        // Opcode: {4'h9, 3'b101(A5), 1'b1(.L), 2'b11, 3'b000(Dn), 3'b000(D0)} = 0x9BC0
        // ====================================================================
        $display("--- P57-6: SUBA.L D0,A5 ---");
        begin
            logic [15:0] sr_before;
            set_an(3'd5, 32'd300);    // A5=300; D0 clobbered
            set_dn(3'd0, 32'd100);    // D0=100
            sr_before = sr_out;
            run_instr(16'h9BC0, 0, 32'h0);
            chk("P57-6a: A5 = 200",      dut.u_rf.a_reg[5], 32'd200);
            chk("P57-6b: CCR unchanged", {16'h0, sr_out},    {16'h0, sr_before});
        end

        // ====================================================================
        // P57-7: SUBA.W D1,A6 — sign-extend D1[15:0], then subtract
        // D1=0xFFFFFFFF (→sext=-1), A6=0 → A6=0-(-1)=1
        // Opcode: {4'h9, 3'b110(A6), 1'b0(.W), 2'b11, 3'b000(Dn), 3'b001(D1)} = 0x9CC1
        // ====================================================================
        $display("--- P57-7: SUBA.W D1,A6 (sign-ext) ---");
        begin
            set_dn(3'd1, 32'hFFFF_FFFF);  // D1[15:0]=0xFFFF → sext=-1
            set_an(3'd6, 32'd0);
            run_instr(16'h9CC1, 0, 32'h0);
            chk("P57-7: A6 = 1", dut.u_rf.a_reg[6], 32'd1);
        end

        // ====================================================================
        // P57-8: CMPA.L D2,A0 — 32-bit compare (An−Dn), sets CCR, no writeback
        // Unequal: A0=300, D2=0 → 300-0≠0 → Z=0
        // Equal:   A0=0,   D2=0 → 0-0=0   → Z=1
        // Opcode: {4'hB, 3'b000(A0), 1'b1(.L), 2'b11, 3'b000(Dn), 3'b010(D2)} = 0xB1C2
        // ====================================================================
        $display("--- P57-8: CMPA.L ---");
        begin
            set_dn(3'd2, 32'd0);
            set_an(3'd0, 32'd300);
            run_instr(16'hB1C2, 0, 32'h0);
            chk1("P57-8a: Z=0 (300 ne 0)", sr_out[2], 1'b0);

            set_an(3'd0, 32'd0);
            run_instr(16'hB1C2, 0, 32'h0);
            chk1("P57-8b: Z=1 (0 eq 0)",   sr_out[2], 1'b1);
        end

        // ====================================================================
        // P57-9: CMPA.W D3,A1 — sign-extend D3[15:0] before 32-bit compare
        // D3=0xFFFFFFFF (D3[15:0]=0xFFFF→sext=0xFFFFFFFF), A1=0xFFFFFFFF
        // 0xFFFFFFFF − 0xFFFFFFFF = 0 → Z=1
        // Opcode: {4'hB, 3'b001(A1), 1'b0(.W), 2'b11, 3'b000(Dn), 3'b011(D3)} = 0xB2C3
        // ====================================================================
        $display("--- P57-9: CMPA.W sign-extend ---");
        begin
            set_dn(3'd3, 32'hFFFF_FFFF);
            set_an(3'd1, 32'hFFFF_FFFF);
            run_instr(16'hB2C3, 0, 32'h0);
            chk1("P57-9: Z=1 (0xFFFFFFFF eq sext(0xFFFF))", sr_out[2], 1'b1);
        end

        // ====================================================================
        // P57-10/11/12: ORI / ANDI / EORI to CCR
        // CCR cleared first via MOVE D0,CCR (D0=0).
        // ORI.B  #0x1F,CCR = 0x003C  ext[7:0]=0x1F → all 5 flags set
        // ANDI.B #0x10,CCR = 0x023C  ext[7:0]=0x10 → keep X only
        // EORI.B #0x11,CCR = 0x0A3C  ext[7:0]=0x11 → toggle X(4) and C(0)
        // ====================================================================
        $display("--- P57-10/11/12: ORI/ANDI/EORI to CCR ---");
        begin
            set_dn(3'd0, 32'h0);
            run_instr(16'h44C0, 0, 32'h0);  // MOVE D0,CCR → CCR=0x00
            chk("P57-10-pre: CCR=0x00", {24'h0, sr_out[7:0]}, 32'h00);

            run_instr(16'h003C, 1, {16'h0, 8'h00, 8'h1F});
            chk("P57-10: CCR=0x1F (all flags)", {24'h0, sr_out[7:0]}, 32'h001F);

            run_instr(16'h023C, 1, {16'h0, 8'h00, 8'h10});
            chk("P57-11: CCR=0x10 (X only)",    {24'h0, sr_out[7:0]}, 32'h0010);

            run_instr(16'h0A3C, 1, {16'h0, 8'h00, 8'h11});
            chk("P57-12: CCR=0x01 (C only)",    {24'h0, sr_out[7:0]}, 32'h0001);
        end

        // ====================================================================
        // P57-13/14/15: ORI / ANDI / EORI to SR
        // Restore SR=0x2700 first.
        // ORI.W  #0x0001,SR = 0x007C → SR=0x2701
        // ANDI.W #0xFFFE,SR = 0x027C → SR=0x2700
        // EORI.W #0x0010,SR = 0x0A7C → SR=0x2710
        // ====================================================================
        $display("--- P57-13/14/15: ORI/ANDI/EORI to SR ---");
        begin
            exc_sr_wr_en   = 1'b1;
            exc_sr_wr_data = 16'h2700;
            @(posedge clk);
            exc_sr_wr_en   = 1'b0;
            repeat(4) @(posedge clk);
            chk("P57-13-pre: SR=0x2700", {16'h0, sr_out}, 32'h0000_2700);

            run_instr(16'h007C, 1, {16'h0, 16'h0001});
            chk("P57-13: SR=0x2701 (C set)",   {16'h0, sr_out}, 32'h0000_2701);

            run_instr(16'h027C, 1, {16'h0, 16'hFFFE});
            chk("P57-14: SR=0x2700 (C clear)", {16'h0, sr_out}, 32'h0000_2700);

            run_instr(16'h0A7C, 1, {16'h0, 16'h0010});
            chk("P57-15: SR=0x2710 (X set)",   {16'h0, sr_out}, 32'h0000_2710);
        end

        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("=== 0 failure(s) ===\nALL TESTS PASSED");
        else
            $display("=== %0d failure(s) ===", fail_cnt);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

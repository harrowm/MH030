// BCD and PACK/UNPK instruction tests
//
// PACK Dy,Dx,#adj: temp=Dy[15:0]+adj; result={temp[11:8],temp[3:0]} (byte→Dx)
// PACK -(Ay),-(Ax),#adj: predec Ay by 2 (word read), predec Ax by 1 (byte write)
// UNPK Dy,Dx,#adj: temp={0,Dy[7:4],0,Dy[3:0]}+adj; result=temp[15:0] (word→Dx)
// UNPK -(Ay),-(Ax),#adj: predec Ay by 1 (byte read), predec Ax by 2 (word write)
// LINK.L An,#d32: push An, An←A7-4, A7←A7-4+d32 (2 extension words)
// RESET: assert eu_reset_req for ~512 external cycles
// NBCD (ea): BCD negate with borrow (memory operand)
// ABCD -(Ay),-(Ax): BCD add with predecrement (memory operand)
// SBCD -(Ay),-(Ax): BCD subtract with predecrement (memory operand)

`default_nettype none
`timescale 1ns/1ps

module bcd_pack_tb;

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

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
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
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (combinatorial ack, 8K longwords) ──────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── Helpers ─────────────────────────────────────────────────────────────
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

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        int saw_reset;

        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // Set A7 (stack pointer) for MOVE.L An,-(A7) read-back checks
        set_an(3'b111, 32'h0000_2000);

        // ====================================================================
        // PACK register form: temp=Dy[15:0]+adj; result={temp[11:8],temp[3:0]}
        // ====================================================================
        $display("--- PACK-01: PACK D0,D1,#0 ---");
        set_dn(0, 32'h0000_ABCD);
        set_dn(1, 32'h0);
        run_instr(16'h8340, 1'b1, 32'h0000_0000);   // PACK D0,D1,#0 → D1=0xBD
        run_instr(16'h2F01, 1'b0, 32'h0);            // MOVE.L D1,-(A7) → M[0x1FFC]
        chk("PACK-01:D1", ram[32'h1FFC >> 2], 32'h0000_00BD);

        $display("--- PACK-02: PACK D2,D3,#0x12 ---");
        set_dn(2, 32'h0000_1234);
        set_dn(3, 32'h0);
        run_instr(16'h8742, 1'b1, 32'h0000_0012);   // PACK D2,D3,#0x12 → D3=0x26
        run_instr(16'h2F03, 1'b0, 32'h0);            // MOVE.L D3,-(A7) → M[0x1FF8]
        chk("PACK-02:D3", ram[32'h1FF8 >> 2], 32'h0000_0026);

        // ====================================================================
        // UNPK register form: temp={0,Dy[7:4],0,Dy[3:0]}+adj; result=temp[15:0]
        // ====================================================================
        $display("--- UNPK-01: UNPK D0,D1,#0 ---");
        set_dn(0, 32'h0000_00AB);
        set_dn(1, 32'h0);
        run_instr(16'h8380, 1'b1, 32'h0000_0000);   // UNPK D0,D1,#0 → D1=0x0A0B
        run_instr(16'h2F01, 1'b0, 32'h0);            // MOVE.L D1,-(A7) → M[0x1FF4]
        chk("UNPK-01:D1", ram[32'h1FF4 >> 2], 32'h0000_0A0B);

        $display("--- UNPK-02: UNPK D2,D3,#0x10 ---");
        set_dn(2, 32'h0000_0037);
        set_dn(3, 32'h0);
        run_instr(16'h8782, 1'b1, 32'h0000_0010);   // UNPK D2,D3,#0x10 → D3=0x0317
        run_instr(16'h2F03, 1'b0, 32'h0);            // MOVE.L D3,-(A7) → M[0x1FF0]
        chk("UNPK-02:D3", ram[32'h1FF0 >> 2], 32'h0000_0317);

        $display("--- PACK-03: PACK D0,D1 16-bit adj overflow ---");
        set_dn(0, 32'h0000_FFFF);
        set_dn(1, 32'h0);
        run_instr(16'h8340, 1'b1, 32'h0000_0001);   // PACK D0,D1,#1: 0xFFFF+1=0x0000→0x00
        run_instr(16'h2F01, 1'b0, 32'h0);            // MOVE.L D1,-(A7) → M[0x1FEC]
        chk("PACK-03:D1", ram[32'h1FEC >> 2], 32'h0000_0000);

        // ====================================================================
        // LINK.L An,#d32
        // ====================================================================
        $display("--- LINK-01: LINK.L A0,#-8 ---");
        set_an(3'b111, 32'h0000_2000);   // reset A7 to known value
        set_an(3'b000, 32'h0000_1000);   // A0 = 0x1000
        // ext={0xFFFF,0xFFF8}: 2-word 32-bit displacement = 0xFFFFFFF8 = -8
        run_instr(16'h4808, 1'b1, 32'hFFFF_FFF8);
        // A7 was 0x2000; push old A0=0x1000 at 0x1FFC; A0←0x1FFC; A7←0x1FF4
        chk("LINK-01:pushed_A0", ram[32'h1FFC >> 2], 32'h0000_1000);
        run_instr(16'h2F08, 1'b0, 32'h0);  // MOVE.L A0,-(A7=0x1FF4) → M[0x1FF0]
        chk("LINK-01:A0",        ram[32'h1FF0 >> 2], 32'h0000_1FFC);

        // ====================================================================
        // PACK/UNPK memory forms (predecrement both operands)
        // ====================================================================
        $display("--- PACK-04: PACK -(A0),-(A1),#0 memory ---");
        // PACK: predec Ay(A0) by 2 (word read), predec Ax(A1) by 1 (byte write)
        // A0=0x0104→0x0102; read word at 0x0102 from ram[0x100>>2][15:0]=0xABCD
        // A1=0x0200→0x01FF; write byte 0xBD at 0x01FF → ram[0x01FC>>2][31:24]
        ram[32'h0100 >> 2] = 32'h0000_ABCD;
        set_an(3'b000, 32'h0000_0104);
        set_an(3'b001, 32'h0000_0200);
        run_instr(16'h8348, 1'b1, 32'h0000_0000);   // PACK -(A0),-(A1),#0
        run_instr(16'h2F08, 1'b0, 32'h0);            // MOVE.L A0,-(A7=0x1FF0)→M[0x1FEC]
        chk("PACK-04:A0",     ram[32'h1FEC >> 2], 32'h0000_0102);
        run_instr(16'h2F09, 1'b0, 32'h0);            // MOVE.L A1,-(A7=0x1FEC)→M[0x1FE8]
        chk("PACK-04:A1",     ram[32'h1FE8 >> 2], 32'h0000_01FF);
        chk("PACK-04:result", ram[32'h01FC >> 2], 32'hBD00_0000);

        $display("--- UNPK-03: UNPK -(A0),-(A1),#0 memory ---");
        // UNPK: predec Ay(A0) by 1 (byte read), predec Ax(A1) by 2 (word write)
        // A0=0x0101→0x0100; read byte at 0x0100 from ram[0x100>>2][7:0]=0xAB
        // A1=0x0202→0x0200; write word 0x0A0B at 0x0200 → ram[0x200>>2][31:16]
        ram[32'h0100 >> 2] = 32'h0000_00AB;
        set_an(3'b000, 32'h0000_0101);
        set_an(3'b001, 32'h0000_0202);
        run_instr(16'h8388, 1'b1, 32'h0000_0000);   // UNPK -(A0),-(A1),#0
        run_instr(16'h2F08, 1'b0, 32'h0);            // MOVE.L A0,-(A7=0x1FE8)→M[0x1FE4]
        chk("UNPK-03:A0",     ram[32'h1FE4 >> 2], 32'h0000_0100);
        run_instr(16'h2F09, 1'b0, 32'h0);            // MOVE.L A1,-(A7=0x1FE4)→M[0x1FE0]
        chk("UNPK-03:A1",     ram[32'h1FE0 >> 2], 32'h0000_0200);
        chk("UNPK-03:result", ram[32'h0200 >> 2], 32'h0A0B_0000);

        // ====================================================================
        // RESET: eu_reset_req pulses for ~512 external cycles (2048 internal)
        // ====================================================================
        $display("--- RESET-01: RESET instruction ---");
        saw_reset = 0;
        @(posedge clk); #1;
        instr_word  = 16'h4E70;
        instr_valid = 1'b1;
        ext_data    = 32'h0;
        ext_valid   = 1'b0;
        repeat(20) begin
            @(posedge clk);
            if (instr_ack) begin
                instr_valid = 1'b0;
                break;
            end
        end
        instr_valid = 1'b0;
        repeat(2200) begin
            @(posedge clk);
            if (eu_reset_req) saw_reset = 1;
        end
        chk("RESET-01:pulsed", saw_reset, 1);
        chk1("RESET-01:done",  eu_reset_req, 1'b0);

        // ====================================================================
        // NBCD (A0): memory BCD negate (0 - src - X)
        // M[0x0110]=0x27, X=0 → result=0x73, C=1
        // ====================================================================
        $display("--- NBCD-01: NBCD (A0) ---");
        ram[32'h110>>2] = 32'h0000_0027;
        set_an(3'd0, 32'h0000_0110);
        run_instr(16'h003C, 1'b1, 32'h0000_0000);   // ORI #0,CCR — ensure X=0
        run_instr(16'h4810, 1'b0, 32'h0);
        chk("NBCD-01:mem",  ram[32'h110>>2], 32'h7300_0000);  // byte in [31:24]
        chk1("NBCD-01:C",   sr_out[0], 1'b1);
        chk1("NBCD-01:Z",   sr_out[2], 1'b0);

        // ====================================================================
        // ABCD -(A1),-(A0): memory BCD add with predecrement
        // A0=0x0204→0x0203; A1=0x0208→0x0207
        // M[0x0203]=0x27, M[0x0207]=0x38, X=0 → 0x27+0x38=0x65 BCD, C=0
        // ====================================================================
        $display("--- ABCD-01: ABCD -(A1),-(A0) memory ---");
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);   // ANDI #0xE0,CCR — clear N,Z,V,C,X
        ram[32'h200>>2] = 32'h0000_0027;   // M[0x0203]=0x27 (Ax/dst byte)
        ram[32'h204>>2] = 32'h0000_0038;   // M[0x0207]=0x38 (Ay/src byte)
        set_an(3'd0, 32'h0000_0204);        // Ax=A0: predec→0x0203
        set_an(3'd1, 32'h0000_0208);        // Ay=A1: predec→0x0207
        run_instr(16'hC109, 1'b0, 32'h0);
        chk("ABCD-01:mem",  ram[32'h200>>2], 32'h6500_0000);  // 0x65 in [31:24]
        chk1("ABCD-01:C",   sr_out[0], 1'b0);
        chk1("ABCD-01:Z",   sr_out[2], 1'b0);

        // ====================================================================
        // SBCD -(A1),-(A0): memory BCD subtract with predecrement
        // A0=0x0304→0x0303; A1=0x0308→0x0307
        // M[0x0303]=0x73, M[0x0307]=0x28, X=0 → 0x73-0x28=0x45 BCD, C=0
        // ====================================================================
        $display("--- SBCD-01: SBCD -(A1),-(A0) memory ---");
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);   // ANDI #0xE0,CCR — clear N,Z,V,C,X
        ram[32'h300>>2] = 32'h0000_0073;   // M[0x0303]=0x73 (Ax/dst byte)
        ram[32'h304>>2] = 32'h0000_0028;   // M[0x0307]=0x28 (Ay/src byte)
        set_an(3'd0, 32'h0000_0304);        // Ax=A0: predec→0x0303
        set_an(3'd1, 32'h0000_0308);        // Ay=A1: predec→0x0307
        run_instr(16'h8109, 1'b0, 32'h0);
        chk("SBCD-01:mem",  ram[32'h300>>2], 32'h4500_0000);  // 0x45 in [31:24]
        chk1("SBCD-01:C",   sr_out[0], 1'b0);

        // ─── Report ──────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: %0d checks passed", pass_cnt);
        else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

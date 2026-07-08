// Phase 63: PACK, UNPK, LINK.L, RESET
//
// PACK Dy,Dx,#adj: temp = Dy[15:0]+adj; result = {temp[11:8],temp[3:0]} (byte→Dx)
// PACK -(Ay),-(Ax),#adj: predec Ay by 2 (word read), predec Ax by 1 (byte write)
// UNPK Dy,Dx,#adj: temp = {0,Dy[7:4],0,Dy[3:0]}+adj; result = temp[15:0] (word→Dx)
// UNPK -(Ay),-(Ax),#adj: predec Ay by 1 (byte read), predec Ax by 2 (word write)
// LINK.L An,#d32: push An, An←A7-4, A7←A7-4+d32 (2 extension words)
// RESET: assert eu_reset_req for ~512 sub-clocks, EU stalls
//
// PACK register form: 1000 Dx 1 01 000 Dy | adj16
//   PACK D0,D1,#0:        0x8340 | adj=0x0000
//   PACK D2,D3,#0x0012:   0x8742 | adj=0x0012
// UNPK register form: 1000 Dx 1 10 000 Dy | adj16
//   UNPK D0,D1,#0:        0x8380 | adj=0x0000
//   UNPK D2,D3,#0x0010:   0x8782 | adj=0x0010
// PACK memory form:  1000 Ax 1 01 001 Ay | adj16  (Ax=dest, Ay=src)
//   PACK -(A0),-(A1),#0:  0x8348 | adj=0x0000
// UNPK memory form:  1000 Ax 1 10 001 Ay | adj16
//   UNPK -(A0),-(A1),#0:  0x8388 | adj=0x0000
// LINK.L A0,#d32: 0x4808 | two ext words (32-bit displacement)
// RESET: 0x4E70

`default_nettype none
`timescale 1ns/1ps

module seq63_tb;

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
    logic        eu_reset_req;

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
        .eu_reset_req   (eu_reset_req),
        .ssp_wr_en      (ssp_wr_en),
        .ssp_wr_data    (ssp_wr_data),
        .exc_sr_wr_en   (exc_sr_wr_en),
        .exc_sr_wr_data (exc_sr_wr_data)
    );

    // ─── Memory model ────────────────────────────────────────────────────────
    logic [31:0] ram [0:4095];  // 16 KB; stack at 0x2000, data at 0x0100

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[13:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[13:2]] <= mem_wdata;
    end

    // ─── test helpers ────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;
    int saw_reset_p09 = 0;

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

    // Run single opcode (possibly with extension word(s))
    task automatic run_instr(input logic [15:0] w0,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(1024) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(15) @(posedge clk);
    endtask

    // Load Dn: CLR.L Dn then ADDI.L #val,Dn
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);
    endtask

    // Load An: set D0=val then MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);
        run_instr(16'h0680, 1'b1, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // Read back Dn: MOVE.L Dn,D0 then compare (for Dn != D0)
    // Simpler: just read the regfile via a MOVE.L Dn,-(A7) and check mem
    // Instead, do: CMPI.L #exp,Dn; then check Z=1

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // Set up A7 (stack pointer) high enough for LINK.L tests
        set_an(3'b111, 32'h0000_2000);

        // ==================================================================
        // P63-01: PACK D0,D1,#0
        // D0 = 0xABCD; adj = 0x0000
        // temp = 0xABCD; result = {B,D} = 0xBD
        // Expected D1[7:0] = 0xBD
        // Opcode PACK D0,D1,#0: 0x8340 | adj=0x0000
        // ==================================================================
        $display("--- P63-01: PACK D0,D1,#0 ---");
        set_dn(3'd0, 32'h0000ABCD);
        set_dn(3'd1, 32'h0);
        run_instr(16'h8340, 1'b1, 32'h0000_0000);  // PACK D0,D1,#0
        // Verify by pushing D1 to memory and reading back
        // Use MOVE.L D1,-(A7) then compare via CMPI.L
        // Instead, push D1 to stack and read from ram directly
        run_instr(16'h2F01, 1'b0, 32'h0);  // MOVE.L D1,-(A7) — A7 was 0x2000 → push at 0x1FFC
        chk("P63-01:D1", ram[32'h1FFC >> 2], 32'h0000_00BD);

        // ==================================================================
        // P63-02: PACK D2,D3,#0x0012
        // D2 = 0x1234; adj = 0x0012
        // temp = 0x1234 + 0x0012 = 0x1246; result = {0x2, 0x6} = 0x26
        // Expected D3[7:0] = 0x26
        // Opcode PACK D2,D3,#0x0012: 0x8742
        // ==================================================================
        $display("--- P63-02: PACK D2,D3,#0x0012 ---");
        set_dn(3'd2, 32'h0000_1234);
        set_dn(3'd3, 32'h0);
        run_instr(16'h8742, 1'b1, 32'h0000_0012);  // PACK D2,D3,#0x0012
        // Push D3 to check
        // Restore A7 first
        run_instr(16'h2F03, 1'b0, 32'h0);  // MOVE.L D3,-(A7) — A7 was 0x1FFC → push at 0x1FF8
        chk("P63-02:D3", ram[32'h1FF8 >> 2], 32'h0000_0026);

        // ==================================================================
        // P63-03: UNPK D0,D1,#0
        // D0 = 0xAB; adj = 0
        // temp = {0,A,0,B} + 0 = 0x0A0B; result word = 0x0A0B
        // Expected D1[15:0] = 0x0A0B
        // Opcode UNPK D0,D1,#0: 0x8380
        // ==================================================================
        $display("--- P63-03: UNPK D0,D1,#0 ---");
        set_dn(3'd0, 32'h0000_00AB);
        set_dn(3'd1, 32'h0);
        run_instr(16'h8380, 1'b1, 32'h0000_0000);  // UNPK D0,D1,#0
        run_instr(16'h2F01, 1'b0, 32'h0);           // MOVE.L D1,-(A7) — A7 was 0x1FF8 → push at 0x1FF4
        chk("P63-03:D1", ram[32'h1FF4 >> 2], 32'h0000_0A0B);

        // ==================================================================
        // P63-04: UNPK D2,D3,#0x0010
        // D2 = 0x37; adj = 0x0010
        // temp = {0,3,0,7} + 0x0010 = 0x0307 + 0x0010 = 0x0317
        // Expected D3[15:0] = 0x0317
        // Opcode UNPK D2,D3,#0x0010: 0x8782
        // ==================================================================
        $display("--- P63-04: UNPK D2,D3,#0x0010 ---");
        set_dn(3'd2, 32'h0000_0037);
        set_dn(3'd3, 32'h0);
        run_instr(16'h8782, 1'b1, 32'h0000_0010);  // UNPK D2,D3,#0x0010
        run_instr(16'h2F03, 1'b0, 32'h0);           // MOVE.L D3,-(A7) — A7 was 0x1FF4 → push at 0x1FF0
        chk("P63-04:D3", ram[32'h1FF0 >> 2], 32'h0000_0317);

        // ==================================================================
        // P63-05: PACK edge case — #adj causes nibble carry
        // D0 = 0xFFFF; adj = 0x0001
        // temp = 0xFFFF + 0x0001 = 0x0000 (overflow → temp[11:8]=0, temp[3:0]=0)
        // result = 0x00
        // Opcode: 0x8340, adj=0x0001
        // ==================================================================
        $display("--- P63-05: PACK D0,D1 adj overflow (16-bit carry) ---");
        // D0=0xFFFF, adj=1 → temp=0x0000 (16-bit wrap) → result=0x00
        // dec_siz=long: WB zeroes all 32 bits of D1 → 0x00000000
        set_dn(3'd0, 32'h0000_FFFF);
        set_dn(3'd1, 32'h0);
        run_instr(16'h8340, 1'b1, 32'h0000_0001);  // PACK D0,D1,#1
        run_instr(16'h2F01, 1'b0, 32'h0);           // MOVE.L D1,-(A7) — A7 was 0x1FF0 → push at 0x1FEC
        chk("P63-05:D1", ram[32'h1FEC >> 2], 32'h0000_0000);

        // ==================================================================
        // P63-06: LINK.L A0, #-8 (d32 = 0xFFFFFFF8)
        // Setup: A0 = 0x1000, A7 = current
        // After: push A0=0x1000 at A7_old-4; A0 = A7_old-4; A7 = A7_old-4 + (-8)
        // A7_old = 0x1FE8 (after pushes above: 0x2000-4-4-4-4-4 = 0x1FF8-4... let's track)
        // Actually A7 is hard to track. Use CMPI to verify A0 = old_A7-4.
        //
        // Reset A7 to known value 0x2000 first.
        // ==================================================================
        $display("--- P63-06: LINK.L A0,#-8 ---");
        // Reset A7 = 0x2000
        set_an(3'b111, 32'h0000_2000);
        set_an(3'b000, 32'h0000_1000);  // A0 = 0x1000
        // LINK.L A0,#-8: opcode 0x4808, ext_data = 0xFFFFFFFF_FFFFFFF8 (32-bit only → 0xFFFFFFF8)
        // m68030_seq: ext_count=2 → eu_ext_data = ifu_ext_data = {first_word[15:0], second_word[15:0]}
        //   first ext word  = 0xFFFF, second ext word = 0xFFF8
        //   eu_ext_data = {0xFFFF, 0xFFF8} = 0xFFFFFFF8 ✓
        run_instr(16'h4808, 1'b1, 32'hFFFF_FFF8);  // LINK.L A0,#-8
        // Expected: M[A7_old-4=0x1FFC] = 0x1000, A0 = 0x1FFC, A7 = 0x1FFC-8 = 0x1FF4
        chk("P63-06:M_A7old-4", ram[32'h1FFC >> 2], 32'h0000_1000);
        // Check A0 via CMPI.L #0x1FFC,A0 (uses SUBA.L result indirectly)
        // Simplest: push A0 to M using MOVEA.L and check
        run_instr(16'h2F08, 1'b0, 32'h0);  // MOVE.L A0,-(A7)  (A7=0x1FF4 → M[0x1FF0]=A0)
        chk("P63-06:A0", ram[32'h1FF0 >> 2], 32'h0000_1FFC);

        // ==================================================================
        // P63-07: PACK -(A0),-(A1),#0 — memory form
        // Ay=A0=0x0104, Ax=A1=0x0200
        // Predec A0 by 2 → A0=0x0102, read word from ram[0x40] bits[15:0]
        // Set ram[0x40] = 0x0000_ABCD so bits[15:0] = 0xABCD
        // temp = 0xABCD; result_byte = 0xBD
        // Predec A1 by 1 → A1=0x01FF, write byte 0xBD to M[0x01FF]
        //   mem_wdata = {24'h0, 0xBD} = 0x000000BD
        //   ram[0x01FC >> 2] = ram[0x7F] = 0x000000BD
        // ==================================================================
        $display("--- P63-07: PACK -(A0),-(A1),#0 memory ---");
        ram[32'h0100 >> 2] = 32'h0000_ABCD;  // source longword; bits[15:0] = 0xABCD
        set_an(3'b000, 32'h0000_0104);  // A0 = 0x0104
        set_an(3'b001, 32'h0000_0200);  // A1 = 0x0200
        // PACK -(A0),-(A1),#0: Ax=A1(bits[11:9]=001), Ay=A0(bits[2:0]=000)
        // 1000 001 1 01 001 000 | 0x0000
        // = 0x8348
        run_instr(16'h8348, 1'b1, 32'h0000_0000);
        // A0 should now be 0x0102 (predec by 2)
        run_instr(16'h2F08, 1'b0, 32'h0);  // MOVE.L A0,-(A7) to check
        // A7 was 0x1FF0 → M[0x1FEC] = A0 value
        chk("P63-07:A0", ram[32'h1FEC >> 2], 32'h0000_0102);
        // A1 should be 0x01FF (predec by 1)
        run_instr(16'h2F09, 1'b0, 32'h0);  // MOVE.L A1,-(A7) → M[0x1FE8]
        chk("P63-07:A1", ram[32'h1FE8 >> 2], 32'h0000_01FF);
        // Written byte at M[0x01FF] → ram[0x01FC>>2]=ram[0x7F]
        chk("P63-07:result", ram[32'h01FC >> 2], 32'h0000_00BD);

        // ==================================================================
        // P63-08: UNPK -(A0),-(A1),#0 — memory form
        // Ay=A0=0x0101, Ax=A1=0x0202
        // Predec A0 by 1 → A0=0x0100, read byte from ram[0x40] bits[7:0]
        // Set ram[0x40] = 0x0000_00AB so bits[7:0] = 0xAB
        // temp = {0,A,0,B} = 0x0A0B
        // Predec A1 by 2 → A1=0x0200, write word 0x0A0B to M[0x0200]
        //   mem_wdata = {16'h0, 0x0A0B}
        //   ram[0x0200 >> 2] = ram[0x80] = 0x00000A0B
        // ==================================================================
        $display("--- P63-08: UNPK -(A0),-(A1),#0 memory ---");
        ram[32'h0100 >> 2] = 32'h0000_00AB;  // bits[7:0] = 0xAB
        set_an(3'b000, 32'h0000_0101);  // A0 = 0x0101
        set_an(3'b001, 32'h0000_0202);  // A1 = 0x0202
        // UNPK -(A0),-(A1),#0: Ax=A1(bits[11:9]=001), Ay=A0(bits[2:0]=000), f_ss=10
        // 1000 001 1 10 001 000 | 0x0000
        // = 0x8388
        run_instr(16'h8388, 1'b1, 32'h0000_0000);
        // A0 should be 0x0100 (predec by 1)
        run_instr(16'h2F08, 1'b0, 32'h0);  // MOVE.L A0,-(A7)
        chk("P63-08:A0", ram[32'h1FE4 >> 2], 32'h0000_0100);
        // A1 should be 0x0200 (predec by 2)
        run_instr(16'h2F09, 1'b0, 32'h0);  // MOVE.L A1,-(A7)
        chk("P63-08:A1", ram[32'h1FE0 >> 2], 32'h0000_0200);
        // Written word at M[0x0200] → ram[0x0200>>2] = ram[0x80]
        chk("P63-08:result", ram[32'h0200 >> 2], 32'h0000_0A0B);

        // ==================================================================
        // P63-09: RESET — eu_reset_req pulses high for ~512 sub-clocks.
        // Critical: deassert instr_valid immediately after instr_ack fires
        // so the EU does not restart a second RESET after the countdown
        // completes (the EX stage still holds ex_is_reset during the stall).
        // ==================================================================
        $display("--- P63-09: RESET ---");
        saw_reset_p09 = 0;
        @(posedge clk);
        instr_word  = 16'h4E70;  // RESET
        instr_valid = 1'b1;
        ext_data    = 32'h0;
        ext_valid   = 1'b0;
        // Deassert after instr_ack (fires within 2-3 cycles; 20-cycle guard sufficient)
        repeat(20) begin
            @(posedge clk);
            if (instr_ack) begin
                instr_valid = 1'b0;
                break;
            end
        end
        instr_valid = 1'b0;
        // Wait for ~512-cycle countdown plus margin; monitor eu_reset_req
        repeat(700) begin
            @(posedge clk);
            if (eu_reset_req) saw_reset_p09 = 1;
        end
        chk("P63-09:reset_pulsed", saw_reset_p09, 1);
        chk1("P63-09:reset_done", eu_reset_req, 1'b0);

        // ─── Report ─────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: %0d checks passed", pass_cnt);
        else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    // Timeout guard
    initial begin
        #2_000_000;
        $display("FAIL TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

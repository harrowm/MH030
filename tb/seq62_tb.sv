// Phase 62: Bit-field instructions — BFTST, BFEXTU, BFEXTS, BFFFO, BFCLR, BFSET, BFINS
//
// Opcode encoding (Group E, f_ss=11, f_dn[2]=1):
//   bits[15:12]=1110, bits[11:9]=Dn_field, bits[8]=f_dir, bits[7:6]=11, bits[5:3]=mode, bits[2:0]=reg
//   bf_op = {f_dn[1:0], f_dir}: 000=BFTST 001=BFEXTU 010=BFEXTS 011=BFFFO
//                                100=BFCLR 110=BFSET  111=BFINS
//
// Extension word [15:0]: [14:12]=Dn [11]=Do [10:6]=offset [5]=Dw [4:0]=width(0=32)
//
// Phase 62 restriction: offset+width ≤ 32 (single 32-bit longword access).
//
//   P62-01: BFTST D0{2:4}        — N/Z from field bits, no register write
//   P62-02: BFEXTU D0{8:8},D1   — extract zero-extended byte → D1
//   P62-03: BFEXTS D0{24:8},D1  — extract sign-extended byte → D1
//   P62-04: BFFFO D0{0:32},D1   — find first one in full register → D1
//   P62-05: BFCLR D0{4:4}       — clear 4-bit field, write result back to D0
//   P62-06: BFSET D0{0:8}       — set 8-bit field, write result back to D0
//   P62-07: BFINS D1,D0{8:8}    — insert D1[7:0] into D0 bits[23:16]
//   P62-08: BFTST (A0){4:8}     — N/Z from memory field, no memory write
//   P62-09: BFEXTU (A0){0:8},D2 — extract byte from memory top into D2
//   P62-10: BFCLR (A0){0:8}     — clear top byte in memory
//   P62-11: BFSET (A0){24:8}    — set bottom byte in memory to 0xFF
//   P62-12: BFINS D3,(A0){8:8}  — insert D3[7:0] into memory word middle byte
//   P62-13: BFTST D0{0:8} Z=1  — zero field gives Z=1

`default_nettype none
`timescale 1ns/1ps

module seq62_tb;

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

    // ─── Memory model ────────────────────────────────────────────────────────
    logic [31:0] ram [0:255];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[9:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[9:2]] <= mem_wdata;
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

    // sr_out[4:0] = X,N,Z,V,C
    task automatic chk_nz(input string tag, input logic exp_n, exp_z);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ==================================================================
        // P62-01: BFTST D0{offset=2,width=4}
        // D0 = 0x3C000000: bits[29:26] = 1111 (shift_right=26)
        // field = (D0>>26) & 0xF = 0xF → N=1 (0xF & 0x8=0x8), Z=0
        // Opcode: BFTST D0 = 0xE8C0 (bits[11:8]=1000, bits[7:6]=11, mode=000, reg=000)
        // Ext: [14:12]=000 [10:6]=00010(bit7=1→0x80) [4:0]=00100(bit2=1→0x4) → 0x0084
        // ==================================================================
        $display("--- P62-01: BFTST D0{2:4} ---");
        set_dn(3'd0, 32'h3C00_0000);
        run_instr(16'hE8C0, 1'b1, 32'h0000_0084);
        chk_nz("P62-01", 1'b1, 1'b0);

        // ==================================================================
        // P62-02: BFEXTU D0{offset=8,width=8},D1
        // D0 = 0x00AB0000: shift_right=16, field=(D0>>16)&0xFF=0xAB
        // N=1 (0xAB & 0x80 ≠ 0), Z=0; D1=0xAB
        // Opcode: BFEXTU D0 = 0xE9C0 (bits[11:8]=1001)
        // Ext: [14:12]=001(D1) [10:6]=01000 [4:0]=01000 → 0x1208
        // ==================================================================
        $display("--- P62-02: BFEXTU D0{8:8},D1 ---");
        set_dn(3'd0, 32'h00AB_0000);
        set_dn(3'd1, 32'h0);
        run_instr(16'hE9C0, 1'b1, 32'h0000_1208);
        // Check CCR immediately after BFEXTU: N=1 (0xAB&0x80≠0), Z=0
        chk_nz("P62-02:ccr", 1'b1, 1'b0);
        // Verify D1=0xAB via CMPI (overwrites CCR with equal-result)
        run_instr(16'h0C81, 1'b1, 32'h0000_00AB);
        chk1("P62-02:D1=0xAB", sr_out[2], 1'b1);

        // ==================================================================
        // P62-03: BFEXTS D0{offset=24,width=8},D1
        // D0 = 0x00000080: shift_right=0, field=0x80 → N=1, sign_ext → D1=0xFFFFFF80
        // Opcode: BFEXTS D0 = 0xEAC0 (bits[11:8]=1010)
        // Ext: [14:12]=001(D1) [10:6]=11000(24) [4:0]=01000(8) → 0x1608
        // ==================================================================
        $display("--- P62-03: BFEXTS D0{24:8},D1 ---");
        set_dn(3'd0, 32'h0000_0080);
        run_instr(16'hEAC0, 1'b1, 32'h0000_1608);
        run_instr(16'h0C81, 1'b1, 32'hFFFF_FF80);  // CMPI.L #0xFFFFFF80,D1
        chk1("P62-03:D1=0xFFFFFF80", sr_out[2], 1'b1);

        // ==================================================================
        // P62-04: BFFFO D0{offset=0,width=32},D1
        // D0 = 0x08000000: only bit27 set; field=D0; k=27 wins: ffo=0+31-27=4
        // Opcode: BFFFO D0 = 0xEBC0 (bits[11:8]=1011)
        // Ext: [14:12]=001(D1) [10:6]=00000(0) [4:0]=00000(32) → 0x1000
        // ==================================================================
        $display("--- P62-04: BFFFO D0{0:32},D1 ---");
        set_dn(3'd0, 32'h0800_0000);
        run_instr(16'hEBC0, 1'b1, 32'h0000_1000);
        run_instr(16'h0C81, 1'b1, 32'h0000_0004);  // CMPI.L #4,D1
        chk1("P62-04:D1=4", sr_out[2], 1'b1);

        // ==================================================================
        // P62-05: BFCLR D0{offset=4,width=4}
        // D0 = 0xABCDEF01: shift_right=24, field=(D0>>24)&0xF=0xB
        // mask_pos = 0x0F000000; result = D0 & ~mask = 0xA0CDEF01
        // N=1 (original field 0xB: 0xB & 0x8=0x8≠0), Z=0
        // Opcode: BFCLR D0 = 0xECC0 (bits[11:8]=1100)
        // Ext: [14:12]=000 [10:6]=00100(bit8=1→0x100) [4:0]=00100(bit2=1→0x4) → 0x0104
        // ==================================================================
        $display("--- P62-05: BFCLR D0{4:4} ---");
        set_dn(3'd0, 32'hABCD_EF01);
        run_instr(16'hECC0, 1'b1, 32'h0000_0104);
        run_instr(16'h0C80, 1'b1, 32'hA0CD_EF01);  // CMPI.L #0xA0CDEF01,D0
        chk1("P62-05:D0=0xA0CDEF01", sr_out[2], 1'b1);

        // ==================================================================
        // P62-06: BFSET D0{offset=0,width=8}
        // D0 = 0x00FFFFFF: shift_right=24, mask_pos=0xFF000000
        // result = 0x00FFFFFF | 0xFF000000 = 0xFFFFFFFF
        // N=0 (field=0x00 before set), Z=1 (field=0x00)
        // Opcode: BFSET D0 = 0xEEC0 (bits[11:8]=1110)
        // Ext: [14:12]=000 [10:6]=00000(0) [4:0]=01000(8) → 0x0008
        // ==================================================================
        $display("--- P62-06: BFSET D0{0:8} ---");
        set_dn(3'd0, 32'h00FF_FFFF);
        run_instr(16'hEEC0, 1'b1, 32'h0000_0008);
        run_instr(16'h0C80, 1'b1, 32'hFFFF_FFFF);  // CMPI.L #0xFFFFFFFF,D0
        chk1("P62-06:D0=0xFFFFFFFF", sr_out[2], 1'b1);
        // CCR from BFSET: field was 0x00 → N=0, Z=1
        set_dn(3'd0, 32'h00FF_FFFF);
        run_instr(16'hEEC0, 1'b1, 32'h0000_0008);
        chk_nz("P62-06:ccr", 1'b0, 1'b1);

        // ==================================================================
        // P62-07: BFINS D1,D0{offset=8,width=8}
        // D0=0xFFFFFF00, D1=0x000000AB
        // shift_right=16; src_placed=(0xAB&0xFF)<<16=0x00AB0000
        // mask_pos=0xFF0000; result=(D0 & ~mask)|src = 0xFF00FF00|0xAB0000 = 0xFFABFF00
        // flag_field = 0xAB & 0xFF = 0xAB → N=1 (0xAB&0x80≠0), Z=0
        // Opcode: BFINS D?,D0 = 0xEFC0 (bits[11:8]=1111)
        // Ext: [14:12]=001(D1) [10:6]=01000(8) [4:0]=01000(8) → 0x1208
        // ==================================================================
        $display("--- P62-07: BFINS D1,D0{8:8} ---");
        set_dn(3'd0, 32'hFFFF_FF00);
        set_dn(3'd1, 32'h0000_00AB);
        run_instr(16'hEFC0, 1'b1, 32'h0000_1208);
        run_instr(16'h0C80, 1'b1, 32'hFFAB_FF00);  // CMPI.L #0xFFABFF00,D0
        chk1("P62-07:D0=0xFFABFF00", sr_out[2], 1'b1);

        // ==================================================================
        // P62-08: BFTST (A0){offset=4,width=8} — memory read, no write-back
        // A0=0x100; M[0x100]=0x0FA00000
        // shift_right=20; field=(0x0FA00000>>20)&0xFF=0xFA
        // N=1 (0xFA&0x80≠0), Z=0; memory unchanged
        // Opcode: BFTST (A0) = 0xE8D0 (bits[7:6]=11, mode=010, reg=000)
        // Ext: [14:12]=000 [10:6]=00100(bit8=1→0x100) [4:0]=01000(bit3=1→0x8) → 0x0108
        // ==================================================================
        $display("--- P62-08: BFTST (A0){4:8} ---");
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'h0FA0_0000;   // M[0x100] = ram[0x100>>2=0x40]
        run_instr(16'hE8D0, 1'b1, 32'h0000_0108);
        chk_nz("P62-08", 1'b1, 1'b0);
        // Verify memory not modified
        chk("P62-08:mem_unchanged", ram[8'h40], 32'h0FA0_0000);

        // ==================================================================
        // P62-09: BFEXTU (A0){offset=0,width=8},D2 — extract top byte to D2
        // M[0x100]=0xAB000000; shift_right=24; field=0xAB → D2=0xAB
        // N=1, Z=0
        // Opcode: BFEXTU (A0) = 0xE9D0 (bits[11:8]=1001, mode=010, reg=000)
        // Ext: [14:12]=010(D2) [10:6]=00000(0) [4:0]=01000(8) → 0x2008
        // ==================================================================
        $display("--- P62-09: BFEXTU (A0){0:8},D2 ---");
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hAB00_0000;
        set_dn(3'd2, 32'h0);
        run_instr(16'hE9D0, 1'b1, 32'h0000_2008);
        run_instr(16'h0C82, 1'b1, 32'h0000_00AB);  // CMPI.L #0xAB,D2
        chk1("P62-09:D2=0xAB", sr_out[2], 1'b1);

        // ==================================================================
        // P62-10: BFCLR (A0){offset=0,width=8} — clear top byte
        // M[0x100]=0xDEADBEEF; result=0x00ADBEEF
        // N=1 (field=0xDE: 0xDE&0x80≠0), Z=0
        // Opcode: BFCLR (A0) = 0xECD0 (bits[11:8]=1100, mode=010, reg=000)
        // Ext: [14:12]=000 [10:6]=00000(0) [4:0]=01000(8) → 0x0008
        // ==================================================================
        $display("--- P62-10: BFCLR (A0){0:8} ---");
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hDEAD_BEEF;
        run_instr(16'hECD0, 1'b1, 32'h0000_0008);
        repeat(5) @(posedge clk);
        chk("P62-10:mem=0x00ADBEEF", ram[8'h40], 32'h00AD_BEEF);

        // ==================================================================
        // P62-11: BFSET (A0){offset=24,width=8} — set bottom byte to 0xFF
        // M[0x100]=0xDEADBE00; shift_right=0; mask_pos=0xFF; result=0xDEADBEFF
        // field=0x00 → N=0, Z=1
        // Opcode: BFSET (A0) = 0xEED0 (bits[11:8]=1110, mode=010, reg=000)
        // Ext: [14:12]=000 [10:6]=11000(24) [4:0]=01000(8) → 0x0608
        // ==================================================================
        $display("--- P62-11: BFSET (A0){24:8} ---");
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hDEAD_BE00;
        run_instr(16'hEED0, 1'b1, 32'h0000_0608);
        repeat(5) @(posedge clk);
        chk("P62-11:mem=0xDEADBEFF", ram[8'h40], 32'hDEAD_BEFF);

        // ==================================================================
        // P62-12: BFINS D3,(A0){offset=8,width=8} — insert D3[7:0] into memory
        // M[0x100]=0xFFFFFF00, D3=0xCD
        // shift_right=16; src_placed=0xCD0000; mask_pos=0xFF0000
        // result = (0xFFFFFF00 & 0xFF00FFFF) | 0xCD0000 = 0xFFCDFF00
        // flag_field = 0xCD & 0xFF = 0xCD → N=1, Z=0
        // Opcode: BFINS D?,(A0) = 0xEFD0 (bits[11:8]=1111, mode=010, reg=000)
        // Ext: [14:12]=011(D3) [10:6]=01000(8) [4:0]=01000(8) → 0x3208
        // ==================================================================
        $display("--- P62-12: BFINS D3,(A0){8:8} ---");
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hFFFF_FF00;
        set_dn(3'd3, 32'h0000_00CD);
        run_instr(16'hEFD0, 1'b1, 32'h0000_3208);
        repeat(5) @(posedge clk);
        chk("P62-12:mem=0xFFCDFF00", ram[8'h40], 32'hFFCD_FF00);

        // ==================================================================
        // P62-13: BFTST D0{offset=0,width=8} with zero field → Z=1
        // D0=0x00FFFFFF; shift_right=24; field=0x00 → N=0, Z=1
        // Opcode: 0xE8C0, Ext: 0x0008
        // ==================================================================
        $display("--- P62-13: BFTST D0{0:8} zero-field Z=1 ---");
        set_dn(3'd0, 32'h00FF_FFFF);
        run_instr(16'hE8C0, 1'b1, 32'h0000_0008);
        chk_nz("P62-13", 1'b0, 1'b1);

        // ──────────────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS  seq62  (%0d checks)", pass_cnt);
        else
            $display("FAIL  seq62  (%0d passed, %0d failed)", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT seq62");
        $finish;
    end

endmodule

`default_nettype wire

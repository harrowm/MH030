// Phase 69: Extended EA sweep — MOVEM, Scc, TAS, CHK, Bitfield, CMP2/CHK2
//
//   P69-01: MOVEM.L store (d16,A0) — D0 → mem[A0+8]
//   P69-02: MOVEM.L load  (d16,A0) — D0 ← mem[A0+8]
//   P69-03: MOVEM.L store (xxx).W  — D0 → abs 0x0200
//   P69-04: MOVEM.L load  (xxx).W  — D0 ← abs 0x0200
//   P69-05: MOVEM.L load  (d16,PC) — D0 ← mem[PC+4+d16]
//   P69-06: Scc (d16,A0)  — ST writes 0xFF to A0+8
//   P69-07: Scc (d8,A0,D1.W) — SF writes 0x00 via indexed EA
//   P69-08: TAS.B (A0)+  — post-increment; sets bit7; An updated
//   P69-09: TAS.B -(A0)  — pre-decrement; byte was zero → Z=1
//   P69-10: CHK (A0),D1  — upper bound from mem; in-range → no trap
//   P69-11: CHK.W (d16,A0),D1 — above bound → trap fires
//   P69-12: BFTST (d16,A0){offset=0,width=8} — field is 0 → Z=1
//   P69-13: BFTST (xxx).W {offset=0,width=8}  — field nonzero → Z=0, N=1
//   P69-14: CMP2.W (d16,A0),D0 — in-range → C=0

`default_nettype none
`timescale 1ns/1ps

module seq69_tb;

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
    m68030_eu u_dut (
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

    // ─── Memory model ────────────────────────────────────────────────────────
    // Writes: simple longword (EU keeps byte/word data in [7:0]/[15:0] of wdata).
    // Reads: word accesses use addr[1] to return the right half in [15:0]:
    //   addr[1]=0 → upper word ([31:16]) in [15:0] (big-endian word 0)
    //   addr[1]=1 → lower word ([15:0])  in [15:0] (big-endian word 1)
    // This lets CMP2.W read lower and upper bounds from the same longword.
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw)
        ? ((mem_siz == 2'b10)
               ? (mem_addr[1] ? {16'h0, ram[mem_addr[14:2]][15:0]}
                               : {16'h0, ram[mem_addr[14:2]][31:16]})
               : ram[mem_addr[14:2]])
        : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── chk_trap pulse counter ───────────────────────────────────────────────
    int chk_trap_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) chk_trap_cnt <= 0;
        else if (chk_trap) chk_trap_cnt <= chk_trap_cnt + 1;
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
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

    task automatic chk_ccr(input string tag,
                            input logic exp_n, exp_z, exp_v, exp_c);
        chk1({tag,":N"}, sr_out[3], exp_n);
        chk1({tag,":Z"}, sr_out[2], exp_z);
        chk1({tag,":V"}, sr_out[1], exp_v);
        chk1({tag,":C"}, sr_out[0], exp_c);
    endtask

    // Present instr + optional ext, wait for ack and settle
    task automatic run_instr(input logic [15:0] iw,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(300) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(16) @(posedge clk);
    endtask

    // Set Dn via CLR.L then ADDI.L
    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    // Set An via D0 then MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // Read D0 by copying from regfile via NOP pause then MOVE.L D0,D7
    function automatic logic [31:0] read_dn(input int n);
        // Use regfile peek via the test regfile outputs — not directly available
        // Instead run MOVE.L Dn,D7 and check via mem store
        return 32'h0;  // placeholder; tests use explicit mem reads
    endfunction

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        int prev_chk;

        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        chk_trap_cnt = 0;

        @(posedge rst_n); repeat(2) @(posedge clk);

        // ====================================================================
        // P69-01: MOVEM.L store (d16,A0) — D0 → mem[A0+8]
        //   Opcode 0x48E8: 0100 1000 11 101 000  (store, long, d16, A0)
        //   ext = {mask=0x0001, d16=0x0008} = 32'h0001_0008
        //   A0=0x100; mask bit0=D0 → stores D0 at 0x100+8=0x108
        // ====================================================================
        $display("--- P69-01: MOVEM.L store (d16,A0) ---");
        set_an(3'h0, 32'h0000_0100);   // set A0 first; set_an clobbers D0 internally
        set_dn(0, 32'hDEADBEEF);       // set D0 after so it isn't overwritten
        run_instr(16'h48E8, 1'b1, 32'h0001_0008);
        chk("P69-01:mem[0x108]", ram[32'h108 >> 2], 32'hDEADBEEF);

        // ====================================================================
        // P69-02: MOVEM.L load (d16,A0) — D0 ← mem[A0+8]
        //   Opcode 0x4CE8: 0100 1100 11 101 000  (load, long, d16, A0)
        //   ext = {mask=0x0001, d16=0x0008} = 32'h0001_0008
        //   Pre-load mem[0x10C]=0x12345678; A0=0x104 → EA=0x10C
        // ====================================================================
        $display("--- P69-02: MOVEM.L load (d16,A0) ---");
        set_dn(0, 32'h0);   // clear D0 to prove MOVEM loads it
        ram[32'h10C >> 2] = 32'h12345678;
        set_an(3'h0, 32'h0000_0104);  // A0=0x104; D0 clobbered but MOVEM overwrites it
        run_instr(16'h4CE8, 1'b1, 32'h0001_0008);  // loads D0 from 0x104+8=0x10C
        run_instr(16'h21C0, 1'b1, 32'h0000_0300);  // MOVE.L D0,(0x300).W immediately
        chk("P69-02:D0_via_mem", ram[32'h300 >> 2], 32'h12345678);

        // ====================================================================
        // P69-03: MOVEM.L store (xxx).W — D0 → abs 0x0400
        //   Opcode 0x48F8: 0100 1000 11 111 000  (store, long, (xxx).W)
        //   ext = {mask=0x0001, abs16=0x0400} = 32'h0001_0400
        // ====================================================================
        $display("--- P69-03: MOVEM.L store (xxx).W ---");
        set_dn(0, 32'hCAFEBABE);
        run_instr(16'h48F8, 1'b1, 32'h0001_0400);
        chk("P69-03:mem[0x400]", ram[32'h400 >> 2], 32'hCAFEBABE);

        // ====================================================================
        // P69-04: MOVEM.L load (xxx).W — D0 ← abs 0x0404
        //   Opcode 0x4CF8: 0100 1100 11 111 000  (load, long, (xxx).W)
        //   ext = {mask=0x0001, abs16=0x0404} = 32'h0001_0404
        // ====================================================================
        $display("--- P69-04: MOVEM.L load (xxx).W ---");
        ram[32'h404 >> 2] = 32'hBEEFCAFE;
        run_instr(16'h4CF8, 1'b1, 32'h0001_0404);
        run_instr(16'h21C0, 1'b1, 32'h0000_0408);  // MOVE.L D0,(0x408).W to verify
        chk("P69-04:D0_via_mem", ram[32'h408 >> 2], 32'hBEEFCAFE);

        // ====================================================================
        // P69-05: MOVEM.L load (d16,PC) — D0 ← mem[decode_pc+4+d16]
        //   Opcode 0x4CFA: 0100 1100 11 111 010  (load, long, (d16,PC))
        //   ext = {mask=0x0001, d16=0x0010} = 32'h0001_0010
        //   decode_pc=0x1000 → EA = 0x1000+4+0x10 = 0x1014
        // ====================================================================
        $display("--- P69-05: MOVEM.L load (d16,PC) ---");
        ram[32'h1014 >> 2] = 32'hA5A5A5A5;
        decode_pc = 32'h0000_1000;
        run_instr(16'h4CFA, 1'b1, 32'h0001_0010);
        decode_pc = 32'h0;
        run_instr(16'h21C0, 1'b1, 32'h0000_0410);  // MOVE.L D0,(0x410).W
        chk("P69-05:D0_via_mem", ram[32'h410 >> 2], 32'hA5A5A5A5);

        // ====================================================================
        // P69-06: Scc (d16,A0) — ST (always true) → write 0xFF to A0+8
        //   ST (d16,A0): 0101 0000 11 101 000 = 0x50E8
        //   ext = d16 = 0x0008  (1 ext word in [15:0])
        //   A0=0x500; EA=0x508; Scc RMW writes byte 0xFF
        // ====================================================================
        $display("--- P69-06: Scc (d16,A0) ST ---");
        ram[32'h508 >> 2] = 32'h12345678;  // pre-fill
        set_an(3'h0, 32'h0000_0500);
        run_instr(16'h50E8, 1'b1, 32'h0000_0008);
        // EU writes byte in mem_wdata[7:0]; simple write: ram = 32'h0000_00FF
        chk("P69-06:byte_0x508", ram[32'h508 >> 2], 32'h0000_00FF);

        // ====================================================================
        // P69-07: Scc (d8,A0,D1.W*1) — SF (always false) → write 0x00
        //   SF (d8,A0,D1.W): 0101 0001 11 110 000 = 0x51F0
        //   ext = brief_word = {D1=001, W=0, *1=00, 0, d8=0x10}
        //       = 0001_0_00_0_0001_0000 = 0x1010
        //   A0=0x500, D1=0 → EA = 0x500 + 0*1 + 0x10 = 0x510
        // ====================================================================
        $display("--- P69-07: Scc (d8,A0,D1) SF ---");
        ram[32'h510 >> 2] = 32'hAAAA_AAAA;
        set_an(3'h0, 32'h0000_0500);
        set_dn(1, 32'h0);  // D1=0 (Xn index)
        run_instr(16'h51F0, 1'b1, 32'h0000_1010);
        // EU writes byte in mem_wdata[7:0]; simple write: ram = 32'h0000_0000
        chk("P69-07:byte_0x510", ram[32'h510 >> 2], 32'h0000_0000);

        // ====================================================================
        // P69-08: TAS.B (A0)+ — test-and-set with post-increment
        //   TAS (An)+: 0100 1010 11 011 000 = 0x4AD8
        //   A0=0x600; mem[0x600]=0x42000000 (byte=0x42, non-zero)
        //   Expected: N=0 (bit7=0), Z=0, mem[0x600][31:24]=0xC2 (0x42|0x80)
        //   A0 should be 0x601 after (byte post-inc; A7 is special but we use A0)
        // ====================================================================
        $display("--- P69-08: TAS (A0)+ ---");
        ram[32'h600 >> 2] = 32'h00000042;  // byte 0x42 in [7:0] — EU reads mem_rdata[7:0]
        set_an(3'h0, 32'h0000_0600);
        run_instr(16'h4AD8, 1'b0, 32'h0);
        // TAS sets bit7: wdata[7:0]=0xC2; simple write overwrites full longword
        chk("P69-08:mem_set", ram[32'h600 >> 2], 32'h0000_00C2);
        chk1("P69-08:N", sr_out[3], 1'b0);
        chk1("P69-08:Z", sr_out[2], 1'b0);
        // A0 updated to 0x601 (byte step)
        run_instr(16'h21C8, 1'b1, 32'h0000_0608);  // MOVE.L A0,(0x608).W
        chk("P69-08:A0_postinc", ram[32'h608 >> 2], 32'h0000_0601);

        // ====================================================================
        // P69-09: TAS.B -(A0) — pre-decrement, byte=0 → Z=1
        //   TAS -(An): 0100 1010 11 100 000 = 0x4AE0
        //   A0=0x601; byte at 0x600=0x00 (zero after TAS) → N=0, Z=1
        //   TAS writes 0x80 to the byte; A0 decrements to 0x600
        // ====================================================================
        $display("--- P69-09: TAS -(A0) ---");
        ram[32'h600 >> 2] = 32'h00000000;  // byte at 0x600 = 0
        set_an(3'h0, 32'h0000_0601);
        run_instr(16'h4AE0, 1'b0, 32'h0);
        chk("P69-09:mem_set", ram[32'h600 >> 2], 32'h0000_0080);
        chk1("P69-09:N", sr_out[3], 1'b0);
        chk1("P69-09:Z", sr_out[2], 1'b1);
        run_instr(16'h21C8, 1'b1, 32'h0000_0610);  // MOVE.L A0,(0x610).W
        chk("P69-09:A0_predec", ram[32'h610 >> 2], 32'h0000_0600);

        // ====================================================================
        // P69-10: CHK (A0),D1 — upper bound from mem; D1=5, ub=10 → in-range
        //   CHK.W (An),Dn: 0100 DDD1 10 010 rrr
        //   CHK.W (A0),D1: 0100 001 1 10 010 000 = 0x4390
        //   A0=0x700; mem[0x700] word = 0x000A (=10); D1=5
        //   Expected: no trap
        // ====================================================================
        $display("--- P69-10: CHK (A0),D1 in-range ---");
        ram[32'h700 >> 2] = 32'h000A_0000;  // word at 0x700 = 0x000A = 10
        set_dn(1, 32'h0000_0005);           // D1 = 5
        set_an(3'h0, 32'h0000_0700);
        prev_chk = chk_trap_cnt;
        run_instr(16'h4390, 1'b0, 32'h0);
        chk("P69-10:no_trap", 32'(chk_trap_cnt - prev_chk), 32'h0);

        // ====================================================================
        // P69-11: CHK.W (d16,A0),D1 — D1=20 > ub=10 → trap fires
        //   CHK.W (d16,An),Dn: 0100 DDD1 10 101 rrr
        //   CHK.W (d16,A0),D1: 0100 001 1 10 101 000 = 0x43A8
        //   A0=0x700, d16=8 → EA=0x708; mem[0x708] word = 0x000A; D1=20
        // ====================================================================
        $display("--- P69-11: CHK.W (d16,A0),D1 above bound ---");
        ram[32'h708 >> 2] = 32'h000A_0000;  // word at 0x708 = 10
        set_dn(1, 32'h0000_0014);           // D1 = 20
        set_an(3'h0, 32'h0000_0700);
        prev_chk = chk_trap_cnt;
        run_instr(16'h43A8, 1'b1, 32'h0000_0008);  // d16=8
        chk("P69-11:trap_fired", 32'(chk_trap_cnt - prev_chk), 32'h1);

        // ====================================================================
        // P69-12: BFTST (d16,A0){offset=0,width=8} — field byte = 0 → Z=1,N=0
        //   BFTST (d16,An): 1110 1000 11 101 000 = 0xE8E8  (f_ss must be 11)
        //   ext = {bf_spec=[31:16], d16=[15:0]}
        //   bf_spec for {offset=0,width=8}: 0x0008
        //   d16=0x10: EA = A0+16 = 0x810
        //   mem[0x810] = 0x00AABBCC → MSB byte (offset=0,width=8) = 0 → Z=1, N=0
        // ====================================================================
        $display("--- P69-12: BFTST (d16,A0){0:8} field=0 ---");
        ram[32'h810 >> 2] = 32'h00AABBCC;  // MSByte = 0
        set_an(3'h0, 32'h0000_0800);
        run_instr(16'hE8E8, 1'b1, 32'h0008_0010);  // bf_spec=0x0008, d16=0x0010
        chk1("P69-12:Z", sr_out[2], 1'b1);
        chk1("P69-12:N", sr_out[3], 1'b0);

        // ====================================================================
        // P69-13: BFTST (xxx).W {offset=0,width=8} — field byte=0x80 → N=1,Z=0
        //   BFTST (xxx).W: 1110 1000 11 111 000 = 0xE8F8  (f_ss must be 11)
        //   ext = {bf_spec=[31:16], abs16=[15:0]}
        //   bf_spec for {offset=0,width=8}: 0x0008
        //   abs16=0x0820: read from 0x0820
        //   mem[0x820] = 0x80FFFF00 → field MSByte = 0x80 → N=1
        // ====================================================================
        $display("--- P69-13: BFTST (xxx).W {0:8} field=0x80 ---");
        ram[32'h820 >> 2] = 32'h80FFFF00;  // MSByte = 0x80 → bit7=1 → N=1
        run_instr(16'hE8F8, 1'b1, 32'h0008_0820);  // bf_spec=0x0008, abs=0x820
        chk1("P69-13:N", sr_out[3], 1'b1);
        chk1("P69-13:Z", sr_out[2], 1'b0);

        // ====================================================================
        // P69-14: CMP2.W (d16,A0),D0 — D0=5, lower=3, upper=10 → in-range C=0
        //   CMP2.W (d16,An),Rn: 0000 010 0 11 101 rrr + ext
        //   f_group=0, f_dn=010(=word, since case 010→siz=word), f_dir=0, f_ss=11
        //   Opcode: 0000 0100 11 101 000 = 0x04E8
        //   ext = {cmp2_ext=[31:16], d16=[15:0]}
        //   cmp2_ext for D0 CMP2: [15]=0(Dn), [14:12]=000(D0), [11]=0(CMP2) = 0x0000
        //   d16=0x10 → EA=A0+0x10=0x910; lower at 0x910, upper at 0x912
        //   Word-aware read: lower=ram[0x244][31:16]=3, upper=ram[0x244][15:0]=10
        //   D0=5 → in-range → C=0, Z=0
        // ====================================================================
        $display("--- P69-14: CMP2.W (d16,A0),D0 in-range ---");
        // ram[0x910>>2][31:16]=lower=3, [15:0]=upper=10 (word-aware model)
        ram[32'h910 >> 2] = 32'h0003_000A;
        set_an(3'h0, 32'h0000_0900);        // A0 first; set_an clobbers D0
        set_dn(0, 32'h0000_0005);           // D0=5 after A0 is set
        run_instr(16'h04E8, 1'b1, 32'h0000_0010);  // cmp2_ext=0, d16=0x10
        chk1("P69-14:C", sr_out[0], 1'b0);   // in-range → C=0
        chk1("P69-14:Z", sr_out[2], 1'b0);   // not equal to either bound

        // ====================================================================
        $display("");
        if (fail_cnt == 0)
            $display("PASS seq69 (%0d checks)", pass_cnt);
        else
            $display("FAIL seq69: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL seq69: timeout");
        $finish;
    end

endmodule

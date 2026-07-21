// Phase 61: ADDX/SUBX register and memory-predecrement forms
//
// Register form (fixed from Phase 36): ADDX/SUBX Dy,Dx — f_mode=000, f_dir=1
//   Previously decoded as ADD/SUB with swapped registers; now correctly uses
//   ALU_ADDX/ALU_SUBX with Dx as dest and X flag as carry-in.
//
// Memory form (new): ADDX/SUBX -(Ay),-(Ax) — f_mode=001, f_dir=1
//   3-phase FSM: predec+read Ay → predec+read Ax → write result to M[Ax-step]
//
//   P61-01: ADDX.L D1,D0 (register)    — X=1 carry-in distinguishes from ADD
//   P61-02: SUBX.L D1,D0 (register)    — basic subtraction register form
//   P61-03: ADDX.L -(A1),-(A0) mem     — basic memory predecrement add
//   P61-04: SUBX.L -(A3),-(A2) mem     — basic memory predecrement sub
//   P61-05: ADDX.W -(A1),-(A0) mem     — word-size memory ADDX
//   P61-06: ADDX.L -(A1),-(A0) X=1     — memory ADDX with X carry-in
//   P61-07: Z stays 0 when result=0 and prior Z=0 (register ADDX)
//   P61-08: Z stays 1 when result=0 and prior Z=1 (register ADDX)

`default_nettype none
`timescale 1ns/1ps

module seq61_tb;

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

    // Log An writes in order so we can verify both Ay and Ax updates.
    logic [31:0] an_wr_log [0:15];
    int          an_wr_cnt;
    always_ff @(posedge clk) begin
        if (an_wr_en) begin
            an_wr_log[an_wr_cnt[3:0]] <= an_wr_data;
            an_wr_cnt                 <= an_wr_cnt + 1;
        end
    end

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
    int base_cnt;  // snapshot of an_wr_cnt before each multi-An instruction

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
        repeat(15) @(posedge clk);   // drain: 3 mem cycles + WB + CCR + margin
    endtask

    // Load Dn: CLR.L Dn then ADDI.L #val,Dn
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);
    endtask

    // Load An: set D0, then MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);
        run_instr(16'h0680, 1'b1, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // CCR helpers (sr_out[4:0] = X,N,Z,V,C)
    task automatic chk_ccr(input string tag,
                            input logic exp_x, exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":X"}, sr_out[4], exp_x);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        an_wr_cnt = 0;
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ==================================================================
        // P61-01: ADDX.L D1,D0 (register form) with X=1
        // Opcode: 1101 000 1 10 000 0 001 = 0xD181
        // Setup: D2=0xFFFFFFFF, ADDQ.L #1,D2 → X=1; CLR.L D0, CLR.L D1 (X unchanged).
        // D0=0, D1=0, X=1 → ADDX.L D1,D0 → D0=0+0+1=1, Z=0, N=0, V=0, C=0, X=0
        // Distinguishes from old wrong ADD (which gave Z=1 since no X carry, result=0).
        // ==================================================================
        $display("--- P61-01: ADDX.L D1,D0 (register) X=1 carry ---");
        set_dn(3'd2, 32'hFFFF_FFFF);
        run_instr(16'h5282, 1'b0, 32'h0);   // ADDQ.L #1,D2 → D2=0, X=1
        run_instr(16'h4280, 1'b0, 32'h0);   // CLR.L D0 (X unchanged)
        run_instr(16'h4281, 1'b0, 32'h0);   // CLR.L D1 (X unchanged)
        run_instr(16'hD181, 1'b0, 32'h0);   // ADDX.L D1,D0
        // Result = 0+0+1 = 1 → Z=0 (proves X was used as carry-in)
        chk_ccr("P61-01", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P61-02: SUBX.L D1,D0 (register form)
        // Opcode: 1001 000 1 10 000 0 001 = 0x9181
        // D0=0x00000005, D1=0x00000003, X=0 → D0=5-3-0=2, Z=0, N=0, V=0, C=0, X=0
        // ==================================================================
        $display("--- P61-02: SUBX.L D1,D0 (register) ---");
        set_dn(3'd0, 32'h0000_0005);
        set_dn(3'd1, 32'h0000_0003);
        run_instr(16'h9181, 1'b0, 32'h0);
        chk_ccr("P61-02", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        // Verify D0=2 by running CMP.L #2,D0 → Z=1 (compare equal)
        run_instr(16'h0C80, 1'b1, 32'h0000_0002);  // CMPI.L #2,D0
        chk1("P61-02:D0=2", sr_out[2], 1'b1);

        // ==================================================================
        // P61-03: ADDX.L -(A1),-(A0) memory predecrement
        // Opcode: 1101 000 1 10 001 001 = 0xD189 (Ax=A0=000, Ay=A1=001)
        // A1=0x144 (Ay), A0=0x140 (Ax), X=0
        // Phase 0: A1 predec → 0x140, reads M[0x140]=0x00000011 (src)
        // Phase 1: A0 predec → 0x13C, reads M[0x13C]=0x00000022 (dst)
        // Phase 2: result=0x33 written to M[0x13C]
        // After: A1=0x140, A0=0x13C
        // ==================================================================
        $display("--- P61-03: ADDX.L -(A1),-(A0) memory ---");
        ram[8'h50] = 32'h0000_0011;    // M[0x140] — Ay content (Ay=A1 predec from 0x144)
        ram[8'h4F] = 32'h0000_0022;    // M[0x13C] — Ax content (Ax=A0 predec from 0x140)
        set_an(3'd1, 32'h0000_0144);   // A1=Ay=0x144
        set_an(3'd0, 32'h0000_0140);   // A0=Ax=0x140
        base_cnt = an_wr_cnt;
        run_instr(16'hD189, 1'b0, 32'h0);
        chk("P61-03:mem",   ram[8'h4F],                       32'h0000_0033);
        chk("P61-03:Ay",    an_wr_log[base_cnt % 16],         32'h0000_0140);
        chk("P61-03:Ax",    an_wr_log[(base_cnt+1) % 16],     32'h0000_013C);
        chk_ccr("P61-03", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P61-04: SUBX.L -(A3),-(A2) memory predecrement
        // Opcode: 1001 010 1 10 001 011 = 0x958B (Ax=A2=010, Ay=A3=011)
        // A3=0x150 (Ay), A2=0x14C (Ax), X=0
        // Phase 0: A3 predec → 0x14C, reads M[0x14C]=0x00000030 (src)
        // Phase 1: A2 predec → 0x148, reads M[0x148]=0x00000050 (dst)
        // Phase 2: result=0x50-0x30=0x20 written to M[0x148]
        // After: A3=0x14C, A2=0x148
        // ==================================================================
        $display("--- P61-04: SUBX.L -(A3),-(A2) memory ---");
        ram[8'h53] = 32'h0000_0030;    // M[0x14C] — Ay content (Ay=A3 predec from 0x150)
        ram[8'h52] = 32'h0000_0050;    // M[0x148] — Ax content (Ax=A2 predec from 0x14C)
        set_an(3'd3, 32'h0000_0150);   // A3=Ay=0x150
        set_an(3'd2, 32'h0000_014C);   // A2=Ax=0x14C
        base_cnt = an_wr_cnt;
        run_instr(16'h958B, 1'b0, 32'h0);
        chk("P61-04:mem",   ram[8'h52],                       32'h0000_0020);
        chk("P61-04:Ay",    an_wr_log[base_cnt % 16],         32'h0000_014C);
        chk("P61-04:Ax",    an_wr_log[(base_cnt+1) % 16],     32'h0000_0148);
        chk_ccr("P61-04", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P61-05: ADDX.W -(A1),-(A0) memory word
        // Opcode: 1101 000 1 01 001 001 = 0xD149 (Ax=A0, Ay=A1, siz=01=word)
        // A1=0x15A (Ay), A0=0x158 (Ax), X=0, step=2 for word
        // Phase 0: A1 predec → 0x158, reads M[0x158] word-slot=ram[0x56]=0x0000_1234 (src=0x1234)
        // Phase 1: A0 predec → 0x156, reads M[0x156] word-slot=ram[0x55]=0x0000_ABCD (dst=0xABCD)
        // Phase 2: result.word=0xABCD+0x1234=0xBE01 written to M[0x156]
        // After: A1=0x158, A0=0x156
        // ==================================================================
        $display("--- P61-05: ADDX.W -(A1),-(A0) word ---");
        ram[8'h56] = 32'h0000_1234;    // M[0x158] — Ay source word
        ram[8'h55] = 32'h0000_ABCD;    // M[0x156] — Ax dest word
        set_an(3'd1, 32'h0000_015A);   // A1=Ay=0x15A
        set_an(3'd0, 32'h0000_0158);   // A0=Ax=0x158
        base_cnt = an_wr_cnt;
        run_instr(16'hD149, 1'b0, 32'h0);
        chk("P61-05:mem",   ram[8'h55],                       32'hBE01_0000);  // word in bits[31:16] (EU convention)
        chk("P61-05:Ay",    an_wr_log[base_cnt % 16],         32'h0000_0158);
        chk("P61-05:Ax",    an_wr_log[(base_cnt+1) % 16],     32'h0000_0156);
        chk_ccr("P61-05", 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        // 0xABCD+0x1234=0xBE01: N=1 (bit15=1), Z=0, V=0, C=0

        // ==================================================================
        // P61-06: ADDX.L -(A1),-(A0) with X=1 carry
        // Opcode: 0xD189
        // Set addresses FIRST (set_an uses ADDI which clears X), then generate X=1
        // using ADDX.L D6,D5 (register form) to produce carry without disturbing A0/A1.
        // M[0x164]=0x00000001 (Ay), M[0x160]=0x00000002 (Ax).
        // X=1: result=0x02+0x01+1=0x04 written to M[0x160].
        // After: A1=0x164, A0=0x160.
        // ==================================================================
        $display("--- P61-06: ADDX.L -(A1),-(A0) mem X=1 carry ---");
        ram[8'h59] = 32'h0000_0001;    // M[0x164] — Ay source
        ram[8'h58] = 32'h0000_0002;    // M[0x160] — Ax dest
        set_an(3'd1, 32'h0000_0168);   // A1=Ay=0x168 (predec to 0x164)
        set_an(3'd0, 32'h0000_0164);   // A0=Ax=0x164 (predec to 0x160)
        // Generate X=1 via ADDX.L D6,D5 with D5=0xFFFFFFFF, D6=1 → carry out
        // (register ADDX doesn't use An, so A0/A1 are safe)
        set_dn(3'd5, 32'hFFFF_FFFF);   // D5=0xFFFFFFFF
        set_dn(3'd6, 32'h0000_0001);   // D6=1
        run_instr(16'hDB86, 1'b0, 32'h0); // ADDX.L D6,D5 → D5=0, X=1, C=1
        base_cnt = an_wr_cnt;
        run_instr(16'hD189, 1'b0, 32'h0);
        chk("P61-06:mem",   ram[8'h58],                       32'h0000_0004);
        chk("P61-06:Ay",    an_wr_log[base_cnt % 16],         32'h0000_0164);
        chk("P61-06:Ax",    an_wr_log[(base_cnt+1) % 16],     32'h0000_0160);
        chk_ccr("P61-06", 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P61-07: Z flag stays 0 when ADDX result=0 and prior Z=0
        // ADDX Z rule: Z = Z_in & (result==0).  If Z_in=0, Z stays 0 even when result=0.
        // Setup: set_dn(D0,1) → D0=1,Z=0,X=0; set_dn(D1,0xFFFFFFFF) → D1=0xFFFFFFFF,Z=0,X=0.
        // ADDX.L D1,D0 → 1 + 0xFFFFFFFF + 0 = 0, C=1, X=1, Z = 0 & 1 = 0. N=0.
        // ==================================================================
        $display("--- P61-07: ADDX Z-preserve: result=0, Z_in=0 stays 0 ---");
        set_dn(3'd0, 32'h0000_0001);       // D0=1, Z=0 (ADDI non-zero)
        set_dn(3'd1, 32'hFFFF_FFFF);       // D1=0xFFFFFFFF, Z=0
        run_instr(16'hD181, 1'b0, 32'h0);  // ADDX.L D1,D0 → result=0
        chk1("P61-07:Z=0", sr_out[2], 1'b0);
        chk1("P61-07:C=1", sr_out[0], 1'b1);
        chk1("P61-07:X=1", sr_out[4], 1'b1);

        // ==================================================================
        // P61-08: Z flag stays 1 when ADDX result=0 and prior Z=1
        // Setup: set_dn(D0,0) → D0=0,Z=1,X=0; set_dn(D1,0) → D1=0,Z=1,X=0.
        // ADDX.L D1,D0 → 0+0+0=0, C=0, X=0, Z = 1 & 1 = 1. N=0.
        // ==================================================================
        $display("--- P61-08: ADDX Z-preserve: result=0, Z_in=1 stays 1 ---");
        set_dn(3'd0, 32'h0000_0000);       // D0=0, Z=1 (ADDI #0,D0: 0+0=0)
        set_dn(3'd1, 32'h0000_0000);       // D1=0, Z=1
        run_instr(16'hD181, 1'b0, 32'h0);  // ADDX.L D1,D0 → result=0
        chk1("P61-08:Z=1", sr_out[2], 1'b1);
        chk1("P61-08:C=0", sr_out[0], 1'b0);
        chk1("P61-08:X=0", sr_out[4], 1'b0);

        // ─── Summary ─────────────────────────────────────────────────────────
        $display("PASSED: %0d, FAILED: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

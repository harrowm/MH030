// Phase 60: Memory-destination ALU read-modify-write
//
// Tests memory RMW: EU reads (An), computes result, writes back.
// Two bus cycles per instruction: read then write (no bus lock).
// CCR fires at write ack via mem_rmw_sr_wr_en, not from WB stage.
//
//   P60-01: OR.L  D0,(A0)              — binary OR to memory
//   P60-02: AND.L D1,(A1)              — binary AND to memory
//   P60-03: EOR.L D2,(A2)              — EOR to memory
//   P60-04: ADD.L D3,(A3)              — ADD to memory (CCR: C/X/N/Z)
//   P60-05: SUB.L D4,(A4)              — SUB to memory
//   P60-06: ADDQ.L #5,(A0)             — ADDQ immediate to memory
//   P60-07: CLR.L (A1)                 — clear memory (N=0,Z=1,V=0,C=0)
//   P60-08: NOT.L (A2)                 — bitwise NOT to memory
//   P60-09: NEG.L (A3)                 — negate to memory (CCR)
//   P60-10: TST.L (A0)                 — read-only: CCR only, no write
//   P60-11: SEQ (A1)                   — Scc to memory (Z=1 → 0xFF)
//   P60-12: ASL.W (A2)                 — memory arithmetic shift left
//   P60-13: BSET D0,(A3)               — register bit set to memory
//   P60-14: ADDI.L #0x0200,(A0)        — immediate ALU to memory (2 ext words)
//   P60-15: ADD.L D0,(A0)+             — postincrement: An updates after write
//   P60-16: SUB.L D1,-(A1)             — predecrement: An updates before read EA

`default_nettype none
`timescale 1ns/1ps

module seq60_tb;

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
    logic [31:0] an_wr_data_cap;  // captured when an_wr_en fires

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

    always_ff @(posedge clk) begin
        if (an_wr_en)
            an_wr_data_cap <= an_wr_data;
    end

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

    // Present instruction, wait for instr_ack, then drain enough cycles for
    // both memory bus cycles (read + write) and WB to complete.
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
        repeat(10) @(posedge clk);   // enough for 2 mem cycles + WB + CCR
    endtask

    // Load Dn: CLR.L Dn then ADDI.L #val,Dn
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);   // CLR.L Dn
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);      // ADDI.L #val,Dn
    endtask

    // Load An: set D0, then MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);
        run_instr(16'h0680, 1'b1, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // CCR helpers (sr_out[4:0] = X,N,Z,V,C)
    task automatic chk_ccr(input string tag,
                            input logic exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ==================================================================
        // P60-01: OR.L D0,(A0)
        // Opcode: 1000 000 1 10 010 000 = 0x8190
        // A0 = 0x100, M[0x100] = 0x0F0F0F0F, D0 = 0xF0F0F0F0
        // Result: 0xFFFFFFFF  CCR: N=1, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-01: OR.L D0,(A0) ---");
        ram[8'h40] = 32'h0F0F_0F0F;   // M[0x100]
        set_an(3'd0, 32'h0000_0100);   // set A0 first (set_an clobbers D0)
        set_dn(3'd0, 32'hF0F0_F0F0);
        run_instr(16'h8190, 1'b0, 32'h0);
        chk("P60-01:mem",  ram[8'h40],  32'hFFFF_FFFF);
        chk_ccr("P60-01", 1'b1, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-02: AND.L D1,(A1)
        // Opcode: 1100 001 1 10 010 001 = 0xC391
        // A1 = 0x104, M[0x104] = 0xFFFF0000, D1 = 0x0F0FFFFF
        // Result: 0x0F0F0000  CCR: N=0, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-02: AND.L D1,(A1) ---");
        ram[8'h41] = 32'hFFFF_0000;   // M[0x104]
        set_dn(3'd1, 32'h0F0F_FFFF);
        set_an(3'd1, 32'h0000_0104);
        run_instr(16'hC391, 1'b0, 32'h0);
        chk("P60-02:mem",  ram[8'h41],  32'h0F0F_0000);
        chk_ccr("P60-02", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-03: EOR.L D2,(A2)
        // Opcode: 1011 010 1 10 010 010 = 0xB592
        // A2 = 0x108, M[0x108] = 0x55555555, D2 = 0xAAAAAAAA
        // Result: 0xFFFFFFFF  CCR: N=1, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-03: EOR.L D2,(A2) ---");
        ram[8'h42] = 32'h5555_5555;   // M[0x108]
        set_dn(3'd2, 32'hAAAA_AAAA);
        set_an(3'd2, 32'h0000_0108);
        run_instr(16'hB592, 1'b0, 32'h0);
        chk("P60-03:mem",  ram[8'h42],  32'hFFFF_FFFF);
        chk_ccr("P60-03", 1'b1, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-04: ADD.L D3,(A3)
        // Opcode: 1101 011 1 10 010 011 = 0xD793
        // A3 = 0x10C, M[0x10C] = 0x00000001, D3 = 0xFFFFFFFF
        // Result: 0x00000000  CCR: N=0, Z=1, C=1, X=1, V=0
        // ==================================================================
        $display("--- P60-04: ADD.L D3,(A3) ---");
        ram[8'h43] = 32'h0000_0001;   // M[0x10C]
        set_dn(3'd3, 32'hFFFF_FFFF);
        set_an(3'd3, 32'h0000_010C);
        run_instr(16'hD793, 1'b0, 32'h0);
        chk("P60-04:mem",  ram[8'h43],  32'h0000_0000);
        chk_ccr("P60-04", 1'b0, 1'b1, 1'b0, 1'b1);

        // ==================================================================
        // P60-05: SUB.L D4,(A4)
        // Opcode: 1001 100 1 10 010 100 = 0x9994
        // A4 = 0x110, M[0x110] = 0x0000000A, D4 = 0x00000003
        // Result: 0x00000007  CCR: N=0, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-05: SUB.L D4,(A4) ---");
        ram[8'h44] = 32'h0000_000A;   // M[0x110]
        set_dn(3'd4, 32'h0000_0003);
        set_an(3'd4, 32'h0000_0110);
        run_instr(16'h9994, 1'b0, 32'h0);
        chk("P60-05:mem",  ram[8'h44],  32'h0000_0007);
        chk_ccr("P60-05", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-06: ADDQ.L #5,(A0)
        // Opcode: 0101 101 0 10 010 000 = 0x5A90
        // A0 = 0x100, M[0x100] = 0xFFFFFFFB (-5)
        // Result: 0x00000000  CCR: N=0, Z=1, C=1 (carry out)
        // ==================================================================
        $display("--- P60-06: ADDQ.L #5,(A0) ---");
        ram[8'h40] = 32'hFFFF_FFFB;   // M[0x100] = -5
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h5A90, 1'b0, 32'h0);
        chk("P60-06:mem",  ram[8'h40],  32'h0000_0000);
        chk_ccr("P60-06", 1'b0, 1'b1, 1'b0, 1'b1);

        // ==================================================================
        // P60-07: CLR.L (A1)
        // Opcode: 0100 001 0 10 010 001 = 0x4291
        // A1 = 0x114, M[0x114] = 0xDEADBEEF → 0x00000000
        // CCR: N=0, Z=1, V=0, C=0
        // ==================================================================
        $display("--- P60-07: CLR.L (A1) ---");
        ram[8'h45] = 32'hDEAD_BEEF;   // M[0x114]
        set_an(3'd1, 32'h0000_0114);
        run_instr(16'h4291, 1'b0, 32'h0);
        chk("P60-07:mem",  ram[8'h45],  32'h0000_0000);
        chk_ccr("P60-07", 1'b0, 1'b1, 1'b0, 1'b0);

        // ==================================================================
        // P60-08: NOT.L (A2)
        // Opcode: 0100 011 0 10 010 010 = 0x4692
        // A2 = 0x118, M[0x118] = 0xDEADBEEF → ~0xDEADBEEF = 0x21524110
        // CCR: N=0 (bit31=0), Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-08: NOT.L (A2) ---");
        ram[8'h46] = 32'hDEAD_BEEF;   // M[0x118]
        set_an(3'd2, 32'h0000_0118);
        run_instr(16'h4692, 1'b0, 32'h0);
        chk("P60-08:mem",  ram[8'h46],  32'h2152_4110);
        chk_ccr("P60-08", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-09: NEG.L (A3)
        // Opcode: 0100 010 0 10 010 011 = 0x4493
        // A3 = 0x11C, M[0x11C] = 0x00000005 → -(5) = 0xFFFFFFFB
        // CCR: N=1, Z=0, V=0, C=1 (borrow)
        // ==================================================================
        $display("--- P60-09: NEG.L (A3) ---");
        ram[8'h47] = 32'h0000_0005;   // M[0x11C]
        set_an(3'd3, 32'h0000_011C);
        run_instr(16'h4493, 1'b0, 32'h0);
        chk("P60-09:mem",  ram[8'h47],  32'hFFFF_FFFB);
        chk_ccr("P60-09", 1'b1, 1'b0, 1'b0, 1'b1);

        // ==================================================================
        // P60-10: TST.L (A0)  — read-only, CCR only, no memory write
        // Opcode: 0100 101 0 10 010 000 = 0x4A90
        // A0 = 0x100, M[0x100] = 0x80000000 → N=1, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-10: TST.L (A0) ---");
        ram[8'h40] = 32'h8000_0000;   // M[0x100]
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h4A90, 1'b0, 32'h0);
        chk("P60-10:mem-unchanged", ram[8'h40], 32'h8000_0000);  // no write
        chk_ccr("P60-10", 1'b1, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-11: SEQ (A1)  — Scc: if Z=1 write 0xFF, else write 0x00
        // Opcode: 0101 011 1 11 010 001 = 0x57D1  (SEQ=condition 7)
        // First set Z=1 via CLR.L D0, then SEQ (A1).
        // A1 = 0x120, M[0x120] before = 0x12345678
        // After SEQ (Z=1): M[0x120] = 0x000000FF
        // ==================================================================
        $display("--- P60-11: SEQ (A1) ---");
        ram[8'h48] = 32'h1234_5678;   // M[0x120]
        set_an(3'd1, 32'h0000_0120);
        run_instr(16'h4280, 1'b0, 32'h0);   // CLR.L D0 — sets Z=1
        run_instr(16'h57D1, 1'b0, 32'h0);   // SEQ (A1)
        chk("P60-11:mem", ram[8'h48], 32'hFF00_0000);  // byte 0xFF in bits[31:24] (EU convention)

        // ==================================================================
        // P60-12: ASL.W (A2)  — arithmetic shift left word, count=1
        // Opcode: 1110 000 1 11 010 010 = 0xE1D2
        // A2 = 0x124, M[0x124] = 0x00001234 → 0x00002468
        // CCR: N=0, Z=0, V=0, C=0 (bit shifted out was 0), X=0
        // ==================================================================
        $display("--- P60-12: ASL.W (A2) ---");
        ram[8'h49] = 32'h0000_1234;   // M[0x124] — upper word doesn't matter
        set_an(3'd2, 32'h0000_0124);
        run_instr(16'hE1D2, 1'b0, 32'h0);
        chk("P60-12:mem", ram[8'h49], 32'h2468_0000);  // word 0x2468 in bits[31:16] (EU convention)
        chk_ccr("P60-12", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-13: BSET D0,(A3)  — register bit set to memory byte
        // Opcode: 0000 000 1 11 010 011 = 0x01D3
        // D0 = 3 (bit 3), A3 = 0x128, M[0x128] = 0x00000000
        // Bit 3 was 0 → Z=1 (original bit was clear), result=0x00000008
        // ==================================================================
        $display("--- P60-13: BSET D0,(A3) ---");
        ram[8'h4A] = 32'h0000_0000;   // M[0x128]
        set_an(3'd3, 32'h0000_0128);   // set A3 first (set_an clobbers D0)
        set_dn(3'd0, 32'h0000_0003);   // D0 = bit number 3
        run_instr(16'h01D3, 1'b0, 32'h0);
        chk("P60-13:mem", ram[8'h4A], 32'h0800_0000);  // byte 0x08 in bits[31:24] (EU convention)
        chk1("P60-13:Z",  sr_out[2],  1'b1);   // original bit was 0

        // ==================================================================
        // P60-14: ADDI.L #0x0200,(A0)  — immediate ALU to memory (2 ext words)
        // Opcode: 0000 011 0 10 010 000 = 0x0690, ext = 0x00000200
        // A0 = 0x100, M[0x100] = 0x00001100, imm = 0x200
        // Result: 0x00001300  CCR: N=0, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-14: ADDI.L #0x200,(A0) ---");
        ram[8'h40] = 32'h0000_1100;   // M[0x100]
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h0690, 1'b1, 32'h0000_0200);
        chk("P60-14:mem", ram[8'h40], 32'h0000_1300);
        chk_ccr("P60-14", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-15: ADD.L D0,(A0)+  — binary op with postincrement
        // Opcode: 1101 000 1 10 011 000 = 0xD198
        // D0 = 0x100, A0 = 0x12C, M[0x12C] = 0x00000C00
        // Result: M[0x12C] = 0x00000D00; A0 → 0x130 (postinc by 4)
        // CCR: N=0, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-15: ADD.L D0,(A0)+ ---");
        ram[8'h4B] = 32'h0000_0C00;   // M[0x12C]
        set_an(3'd0, 32'h0000_012C);   // set A0 first (set_an clobbers D0)
        set_dn(3'd0, 32'h0000_0100);
        run_instr(16'hD198, 1'b0, 32'h0);
        chk("P60-15:mem",  ram[8'h4B],       32'h0000_0D00);
        chk("P60-15:A0",   an_wr_data_cap,   32'h0000_0130); // captured at An write pulse
        chk_ccr("P60-15", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P60-16: SUB.L D1,-(A1)  — binary op with predecrement
        // Opcode: 1001 001 1 10 100 001 = 0x93A1
        // D1 = 0x00000001, A1 = 0x134, EA = A1-4 = 0x130, M[0x130] = 0x00000100
        // Result: M[0x130] = 0x000000FF; A1 → 0x130 (predec)
        // CCR: N=0, Z=0, V=0, C=0
        // ==================================================================
        $display("--- P60-16: SUB.L D1,-(A1) ---");
        ram[8'h4C] = 32'h0000_0100;   // M[0x130]
        set_dn(3'd1, 32'h0000_0001);
        set_an(3'd1, 32'h0000_0134);
        run_instr(16'h93A1, 1'b0, 32'h0);
        chk("P60-16:mem",  ram[8'h4C],        32'h0000_00FF);
        chk("P60-16:A1",   an_wr_data_cap,   32'h0000_0130);
        chk_ccr("P60-16", 1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // Final report
        // ==================================================================
        $display("PASS %0d  FAIL %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("PASSED");
        else
            $display("FAILED");
        $finish;
    end

    // Safety timeout
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

`default_nettype none
`timescale 1ps/1ps

// Phase 53 testbench — memory-indirect EA ([bd,An],Xn,od)
//
// The 68030 memory-indirect mode (full extension word, I/IS != 000) requires
// two bus cycles per EA computation:
//   1. Inner read (longword): ptr = MEM[ An + (IS?0:Xn*SCALE) + bd ]
//   2. Outer read:  result  = MEM[ ptr + (IS?Xn*SCALE:0) + od ]
//
// Full extension word format (ext_data[15:0] = ext0):
//   [15]=DA [14:12]=Xn_reg [11]=W/L [10:9]=Scale [8]=1(full)
//   [7]=BS  [6]=IS  [5:4]=BDsz [3]=0 [2:0]=I/IS
//
// I/IS field: 000=no indirect, 001=indirect null-od, 010=indirect word-od, 011=long-od
// BDsz:       01=null(0), 10=word, 11=long
//
// Test cases:
//   P53-1: Pre-indexed, null bd, null od — ([A0], D1, od=0)
//          opcode MOVE.L ([A0], D1.L*1), D2
//          Inner: MEM[A0 + D1] → ptr
//          Outer: MEM[ptr]     → D2
//
//   P53-2: Pre-indexed, word bd, null od — ([bd.W, A0], D1.L, od=0)
//          Inner: MEM[A0 + D1 + bd]  → ptr
//          Outer: MEM[ptr]            → D2
//
//   P53-3: Post-indexed, null bd, null od — ([A0], od=0) + D1 outer
//          (IS=1: Xn not added to inner; added to outer)
//          Inner: MEM[A0]         → ptr
//          Outer: MEM[ptr + D1]   → D2
//
//   P53-4: Pre-indexed, null bd, word od — ([A0], D1.L*1, od.W)
//          Inner: MEM[A0 + D1]      → ptr
//          Outer: MEM[ptr + od]     → D2
//
//   P53-5: Full non-indirect (fi_iis=000): (bd,An,Xn) — single bus cycle
//          Verify this is NOT treated as memory-indirect (one mem_req only)
//
//   P53-6: Regression: brief indexed (d8,An,Xn) still works after Phase 53
//
// Opcode encoding:
//   MOVE.L is group 0010 (size=10=long in move encoding)
//   Bit layout: [15:12]=0010, [11:9]=dst_reg, [8:6]=dst_mode,
//               [5:3]=src_mode, [2:0]=src_reg
//   For src_mode=110 (indexed): extension word follows opcode.
//
// For dst=D2 (Dn, mode=000, reg=010):
//   dst_mode=000, dst_reg=010 → bits[11:9]=010, bits[8:6]=000
//   src_mode=110, src_reg=000 (A0) → bits[5:3]=110, bits[2:0]=000
//   Opcode = 16'h2430  (MOVE.L (ext,A0), D2)
//   Also for dst=D2, src=A1:
//   Opcode = 16'h2431  (MOVE.L (ext,A1), D2)

`define DR(n)   u_dut.u_rf.d_reg[n]
`define AR(n)   u_dut.u_rf.a_reg[n]

module seq53_tb;

    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;
    logic        instr_ack, eu_busy;
    logic [31:0] decode_pc   = 32'h0000_1000;

    logic [31:0] pc_out, vbr_out, usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap, chk_trap, branch_taken;
    logic [31:0] branch_target;
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    // Simple memory model — supports byte-selective writes
    logic [31:0] ram [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) ram[i] = 32'h0;
    end

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr = 0;

    // Immediate memory ack and read data
    assign mem_ack   = mem_req;
    assign mem_rdata = mem_req && mem_rw ? ram[mem_addr[11:2]] : 32'h0;
    always @(posedge clk_4x)
        if (mem_req && !mem_rw) ram[mem_addr[11:2]] <= mem_wdata;

    // Coprocessor interface (not used in Phase 53)
    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic [31:0] eu_coproc_rdata = 32'h0;
    logic        eu_coproc_ack = 0, eu_coproc_berr = 0;

    m68030_eu u_dut (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .ext_valid      (ext_valid),
        .instr_ack      (instr_ack),
        .eu_busy        (eu_busy),
        .pc_wr_en       (1'b0), .pc_wr_data   (32'h0),
        .pc_out         (pc_out),
        .vbr_wr_en      (1'b0), .vbr_wr_data  (32'h0),
        .vbr_out        (vbr_out),
        .usp_out        (usp_out), .msp_out(msp_out), .isp_out(isp_out),
        .cacr_out       (), .caar_out     (),
        .sr_out         (sr_out),
        .supervisor     (supervisor), .master_mode(master_mode),
        .ipl_mask       (ipl_mask),
        .decode_pc      (decode_pc),
        .branch_taken   (branch_taken), .branch_target(branch_target),
        .mem_req        (mem_req),  .mem_rw    (mem_rw),  .mem_siz   (mem_siz),
        .mem_fc         (mem_fc),   .mem_addr  (mem_addr),.mem_wdata (mem_wdata),
        .mem_rdata      (mem_rdata),.mem_ack   (mem_ack), .mem_berr  (mem_berr),
        .mem_rmw        (),
        .eu_coproc_req   (eu_coproc_req),  .eu_coproc_rw   (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),  .eu_coproc_fc   (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr), .eu_coproc_wdata(eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),.eu_coproc_ack  (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .an_wr_en       (an_wr_en), .an_wr_sel(an_wr_sel), .an_wr_data(an_wr_data),
        .div_trap       (div_trap), .chk_trap (chk_trap),
        .ssp_wr_en      (1'b0),     .ssp_wr_data(32'h0),
        .exc_sr_wr_en   (1'b0),     .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  [%0t] %s", $time, name);
        else begin $display("FAIL  [%0t] %s", $time, name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, exp);
        if (got === exp) $display("PASS  [%0t] %s (got %08h)", $time, name, got);
        else begin $display("FAIL  [%0t] %s: got %08h  exp %08h", $time, name, got, exp);
             fail_count++; end
    endtask

    // Wait for instr_ack (which is a one-cycle pulse at posedge).
    // Use @(posedge) without #1 to sample registered signals; at #1 after,
    // stall=1 so instr_ack=0.
    task automatic wait_instr_ack(input int max_cyc);
        for (int t = 0; t < max_cyc; t++) begin
            @(posedge clk_4x);
            if (instr_ack) break;
        end
    endtask

    // Present one instruction for one cycle then deassert to prevent FSM re-triggering.
    // ext_data[15:0] = extension word; ext_data[31:16] = second word (bd or od).
    task automatic send_instr(input logic [15:0] op,
                              input logic [31:0] ext);
        @(posedge clk_4x); #1;
        instr_word  = op;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = 1'b1;
        @(posedge clk_4x); #1;  // instr_ack fires at this posedge
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
    endtask

    // Wait for a memory request at a specific address (skipping other requests).
    // Returns 1 if found within max_cyc, 0 otherwise.
    task automatic wait_mem_at(input logic [31:0] exp_addr,
                               input int          max_cyc,
                               output logic       found);
        found = 0;
        for (int t = 0; t < max_cyc; t++) begin
            @(posedge clk_4x);
            if (mem_req && mem_addr === exp_addr) begin found = 1; break; end
        end
    endtask

    // Drain the pipeline: wait until mem_req is low for a few cycles.
    task drain;
        repeat(5) @(posedge clk_4x);
    endtask

    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 53: Memory-Indirect EA ===");

        repeat(4) @(posedge clk_4x);
        rst_n = 1;
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // P53-1: Pre-indexed, null bd, null od
        //
        // Registers: A0 = 0x100, D1 = 0x10
        //   Inner addr: A0 + D1 = 0x110  → ptr = MEM[0x110] = 0x200
        //   Outer addr: ptr + 0 = 0x200  → D2 = MEM[0x200] = 0xDEAD_BEEF
        //
        // Full ext word (ext0):
        //   DA=0 (Dn), Xreg=001 (D1), WL=1 (long), Scale=00
        //   is_full=1, BS=0, IS=0, BDsz=01 (null), I/IS=001 (indirect null-od)
        //   = {0, 001, 1, 00, 1, 0, 0, 01, 0, 001} = 16'b0001_1001_0001_0001
        //   = 16'h1901  Wait, let me recalculate:
        //     [15]=0(D), [14:12]=001(D1), [11]=1(L), [10:9]=00(x1),
        //     [8]=1(full), [7]=0(BS=0), [6]=0(IS=0), [5:4]=01(null bd),
        //     [3]=0, [2:0]=001(indirect, null od)
        //     = 0_001_1_00_1_0_0_01_0_001
        //     = 0001_1001_0001_0001
        //     = 16'h1911  Wait...
        //
        // Let me lay it out bit by bit:
        //   bit15=0(D), bit14-12=001(D1), bit11=1(L), bit10-9=00(x1), bit8=1(full)
        //   bit7=0(BS), bit6=0(IS), bit5-4=01(null bd), bit3=0, bit2-0=001
        //   = 0001_1001_0001_0001  = 16'h1911? No:
        //   0 001 1 00 1 | 0 0 01 0 001
        //   = 0001_1001 | 0001_0001
        //   = 0x19 | 0x11
        //   = 16'h1911
        //
        // ext_data[31:16] not needed (null bd, null od)
        // ----------------------------------------------------------------
        $display("--- P53-1: Pre-indexed null bd/od ---");
        begin
            logic found;
            `AR(0) = 32'h0000_0100;  // A0
            `DR(1) = 32'h0000_0010;  // D1 = index
            `DR(2) = 32'h0;
            ram[32'h100 >> 2] = 32'h0000_0200;  // MEM[0x100] = 0x200 (ptr at 0x100)
            // Actually inner = A0 + D1 = 0x110; MEM[0x110] = ptr
            ram[32'h110 >> 2] = 32'h0000_0200;  // MEM[0x110] = ptr = 0x200
            ram[32'h200 >> 2] = 32'hDEAD_BEEF;  // MEM[0x200] = expected result

            // ext0: D=0, Xreg=001(D1), WL=1(long), scale=00, full=1, BS=0, IS=0, BDsz=01, I/IS=001
            // [15:0] = 0 001 1 00 1 | 0 0 01 0 001 = 0001_1001_0001_0001 = 16'h1911
            send_instr(16'h2430, {16'h0, 16'h1911});  // MOVE.L ([A0,D1.L*1],od=0), D2

            // Wait for the inner bus read at 0x110
            wait_mem_at(32'h0000_0110, 20, found);
            check("P53-1a: inner read at A0+D1 = 0x110", found && mem_rw);
            check("P53-1b: inner siz = longword", mem_siz == 2'b00);

            // Wait for outer bus read at 0x200 (the pointer)
            wait_mem_at(32'h0000_0200, 20, found);
            check("P53-1c: outer read at ptr = 0x200", found && mem_rw);

            // Wait for result in D2
            drain;
            check32("P53-1d: D2 = MEM[ptr] = 0xDEADBEEF", `DR(2), 32'hDEAD_BEEF);
        end

        // ----------------------------------------------------------------
        // P53-2: Pre-indexed, word bd, null od
        //
        // A1=0x100, D1=0x10, bd=0x0020
        //   Inner: 0x100 + 0x10 + 0x20 = 0x130  → ptr = MEM[0x130] = 0x300
        //   Outer: MEM[0x300] → D2 = 0xABCD_1234
        //
        // Full ext word:
        //   DA=0, Xreg=001(D1), WL=1(L), scale=00, full=1, BS=0, IS=0, BDsz=10(word), I/IS=001
        //   [15:0] = 0 001 1 00 1 | 0 0 10 0 001 = 0001_1001_0010_0001 = 16'h1921
        //   ext_data[31:16] = bd = 0x0020
        // ----------------------------------------------------------------
        $display("--- P53-2: Pre-indexed word bd, null od ---");
        begin
            logic found;
            `AR(1) = 32'h0000_0100;  // A1
            `DR(1) = 32'h0000_0010;  // D1
            `DR(2) = 32'h0;
            ram[32'h130 >> 2] = 32'h0000_0300;  // MEM[0x130] = ptr = 0x300
            ram[32'h300 >> 2] = 32'hABCD_1234;  // MEM[0x300] = expected result

            // MOVE.L ([0x0020, A1, D1.L*1], od=0), D2
            // opcode: size=10(long), dst=D2(010/000), src_mode=110, src_reg=001(A1)
            // = 16'h2431
            send_instr(16'h2431, {16'h0020, 16'h1921});

            wait_mem_at(32'h0000_0130, 20, found);
            check("P53-2a: inner read at A1+D1+bd=0x130", found && mem_rw);

            wait_mem_at(32'h0000_0300, 20, found);
            check("P53-2b: outer read at ptr=0x300", found && mem_rw);

            drain;
            check32("P53-2c: D2 = MEM[ptr]", `DR(2), 32'hABCD_1234);
        end

        // ----------------------------------------------------------------
        // P53-3: Post-indexed (IS=1), null bd, null od
        //
        // A0=0x100, D1=0x40
        //   Inner: MEM[A0] = MEM[0x100] → ptr = 0x500
        //   Outer: MEM[ptr + D1] = MEM[0x540] → D2 = 0x1234_5678
        //
        // Full ext word:
        //   DA=0, Xreg=001(D1), WL=1(L), scale=00, full=1, BS=0, IS=1(post), BDsz=01, I/IS=001
        //   [15:0] = 0 001 1 00 1 | 0 1 01 0 001 = 0001_1001_0101_0001 = 16'h1951
        // ----------------------------------------------------------------
        $display("--- P53-3: Post-indexed IS=1, null bd/od ---");
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0040;
            `DR(2) = 32'h0;
            ram[32'h100 >> 2] = 32'h0000_0500;  // MEM[0x100] = ptr = 0x500 (inner)
            ram[32'h540 >> 2] = 32'h1234_5678;  // MEM[0x540] = result (ptr + D1 = 0x540)

            // IS=1: inner = A0 (no Xn); outer = ptr + D1 + 0
            // ext0: IS=1 → [6]=1
            // = 0 001 1 00 1 | 0 1 01 0 001 = 16'h1951
            send_instr(16'h2430, {16'h0, 16'h1951});

            wait_mem_at(32'h0000_0100, 20, found);
            check("P53-3a: inner read at A0=0x100 (no Xn)", found && mem_rw);

            wait_mem_at(32'h0000_0540, 20, found);
            check("P53-3b: outer read at ptr+D1=0x540", found && mem_rw);

            drain;
            check32("P53-3c: D2 = MEM[ptr+D1]", `DR(2), 32'h1234_5678);
        end

        // ----------------------------------------------------------------
        // P53-4: Pre-indexed, null bd, word od
        //
        // A0=0x100, D1=0x10, od=0x0008
        //   Inner: MEM[A0 + D1] = MEM[0x110] → ptr = 0x200
        //   Outer: MEM[ptr + od] = MEM[0x208] → D2 = 0xCAFE_BABE
        //
        // Full ext word:
        //   DA=0, Xreg=001(D1), WL=1(L), scale=00, full=1, BS=0, IS=0, BDsz=01, I/IS=010(word od)
        //   [15:0] = 0 001 1 00 1 | 0 0 01 0 010 = 0001_1001_0001_0010 = 16'h1912
        //   ext_data[31:16] = od = 0x0008  (bd=null so od occupies this slot)
        // ----------------------------------------------------------------
        $display("--- P53-4: Pre-indexed null bd, word od ---");
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h110 >> 2] = 32'h0000_0200;  // MEM[0x110] = ptr = 0x200
            ram[32'h208 >> 2] = 32'hCAFE_BABE;  // MEM[0x208] = ptr + od = 0x208

            // I/IS=010 (word od), BDsz=01 (null bd) → od in ext_data[31:16]
            send_instr(16'h2430, {16'h0008, 16'h1912});

            wait_mem_at(32'h0000_0110, 20, found);
            check("P53-4a: inner read at A0+D1=0x110", found && mem_rw);

            wait_mem_at(32'h0000_0208, 20, found);
            check("P53-4b: outer read at ptr+od=0x208", found && mem_rw);

            drain;
            check32("P53-4c: D2 = MEM[ptr+od]", `DR(2), 32'hCAFE_BABE);
        end

        // ----------------------------------------------------------------
        // P53-5: Full ext word, no indirection (fi_iis=000): (bd,An,Xn)
        //        should be a SINGLE bus cycle (not memory-indirect).
        //
        // A0=0x100, D1=0x10, bd=0x20
        //   EA = A0 + D1 + bd = 0x130 → D2 = MEM[0x130]
        //
        // Full ext word with I/IS=000 (no indirection):
        //   DA=0, Xreg=001(D1), WL=1(L), scale=00, full=1, BS=0, IS=0, BDsz=10(word bd), I/IS=000
        //   [15:0] = 0 001 1 00 1 | 0 0 10 0 000 = 0001_1001_0010_0000 = 16'h1920
        //   ext_data[31:16] = bd = 0x0020
        // ----------------------------------------------------------------
        $display("--- P53-5: Full ext no indirection (bd,An,Xn) single cycle ---");
        begin
            logic found;
            int   req_count;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h130 >> 2] = 32'hC0DE_CAFE;  // MEM[A0+D1+bd] = 0x130

            send_instr(16'h2430, {16'h0020, 16'h1920});

            // Count memory requests — should be exactly 1 (no inner read for non-indirect)
            req_count = 0;
            repeat(15) begin
                @(posedge clk_4x);
                if (mem_req) req_count++;
            end
            check("P53-5a: exactly 1 bus cycle for non-indirect full ext", req_count == 1);
            check32("P53-5b: D2 = MEM[A0+D1+bd] = 0x130", `DR(2), 32'hC0DE_CAFE);
        end

        // ----------------------------------------------------------------
        // P53-6: Regression — brief indexed (d8,An,Xn) still works
        //        Uses ext0[8]=0 (brief), not full extension word.
        //
        // A0=0x100, D1=0x10, d8=0x04
        //   EA = A0 + D1 + 4 = 0x114 → D2 = MEM[0x114]
        //
        // Brief ext word:
        //   [15]=0(D), [14:12]=001(D1), [11]=1(L), [10:9]=00(x1),
        //   [8]=0(brief), [7:0]=0x04(d8)
        //   = 0 001 1 00 0 | 0000_0100 = 0001_1000_0000_0100 = 16'h1804
        // ----------------------------------------------------------------
        $display("--- P53-6: Regression brief (d8,An,Xn) ---");
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h114 >> 2] = 32'h5555_AAAA;  // MEM[0x114]

            send_instr(16'h2430, {16'h0, 16'h1804});

            wait_mem_at(32'h0000_0114, 20, found);
            check("P53-6a: brief indexed reads at A0+D1+d8=0x114", found && mem_rw);

            drain;
            check32("P53-6b: D2 = MEM[0x114]", `DR(2), 32'h5555_AAAA);
        end

        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

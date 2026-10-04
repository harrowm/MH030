`default_nettype none
`timescale 1ns/1ps

// =============================================================================
// MH030-P core: integer register-direct pipeline.
//
// The interesting cases here are the RAW hazards, because the register read is
// a clock boundary rather than a combinational lookup. That makes forwarding
// load-bearing in a way it is not in rtl/: an instruction one behind needs the
// commit happening this cycle, and an instruction two behind needs the
// PREVIOUS commit, because its read was issued in the same cycle that commit
// occurred and therefore missed it. Independent instructions would pass with
// no forwarding at all, so they prove nothing -- the dependent chains are the
// test.
// =============================================================================

module mh030p_core_tb;

    logic clk_4x = 1'b0;
    logic rst_n  = 1'b0;
    always #5 clk_4x = ~clk_4x;

    logic [15:0] instr = 16'h0;
    logic [31:0] ext   = 32'h0;
    // The core now takes the UNNORMALISED extension words as well, because the
    // full-format check has to read a specific word by position and `ext`'s
    // layout depends on ext_words (see mh030p_decode.sv's ext_raw port). This
    // testbench drives `ext` in the EU's normalised convention -- a single word
    // in the LOW half -- so the raw form is that word moved back to the high
    // half. A two-word `ext` already matches the raw layout.
    wire [31:0] ext_raw = (ext[31:16] == 16'h0) ? {ext[15:0], 16'h0} : ext;
    logic [15:0] q3    = 16'h0;
    logic [15:0] q4    = 16'h0;
    logic        instr_valid = 1'b0;
    wire         instr_ready;
    wire         wb_wr_en;
    wire [3:0]   wb_wr_sel;
    wire [31:0]  wb_wr_data;
    wire [7:0]   ccr_out;

    // Memory model: one-cycle-latency ack, longword granular. Latency is
    // deliberately non-zero so the EX stall and the "drop the request on ack,
    // never re-issue" behaviour are actually exercised.
    wire        mem_req;
    wire [31:0] mem_addr;
    wire        mem_rw;
    wire [1:0]  mem_siz;
    wire [31:0] mem_wdata;
    logic [31:0] mem_rdata = 32'h0;
    logic        mem_ack   = 1'b0;
    logic [31:0] ram [0:1023];
    logic [31:0] pc_in = 32'h0;
    wire         redirect;
    wire [31:0]  redirect_pc;

    always_ff @(posedge clk_4x) begin
        mem_ack <= 1'b0;
        if (mem_req && !mem_ack) begin
            mem_ack   <= 1'b1;
            if (mem_rw) mem_rdata            <= ram[mem_addr[11:2]];
            else        ram[mem_addr[11:2]]  <= mem_wdata;
        end
    end

    mh030p_core dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr(instr), .ext_raw(ext_raw), .q3(q3), .q4(q4),
        .instr_valid(instr_valid), .instr_ready(instr_ready),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .pc_in(pc_in), .redirect(redirect), .redirect_pc(redirect_pc),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_lock(), .stopped(), .ipl(3'b000),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out)
    );

    int fails = 0;
    // Capture the first redirect so its target arithmetic can be asserted.
    logic [31:0] branch_pc_seen   = 32'hFFFF_FFFF;
    logic [31:0] branch_pc_expect = 32'hFFFF_FFFF;
    always @(posedge clk_4x)
        // Not the reset-vector redirect: the core now performs a real 68k
        // vector fetch, and its own redirect is the FIRST one after reset. This
        // check is about the branch base, so skip while that sequence runs.
        if (rst_n && redirect && !dut.in_reset_seq
                 && branch_pc_seen === 32'hFFFF_FFFF) begin
            branch_pc_seen   <= redirect_pc;
            branch_pc_expect <= dut.ex_pc + 32'd2 + 32'd2;   // BRA.B +2
        end
    task automatic chk(input string name, input logic [31:0] got,
                                          input logic [31:0] exp);
        if (got === exp) $display("PASS  %-26s = %08h", name, got);
        else begin
            $display("FAIL  %-26s got %08h exp %08h", name, got, exp);
            fails++;
        end
    endtask

    // One instruction per cycle.
    // Hold the instruction until the core can take it -- the pipeline stalls
    // whenever EX is waiting on memory.
    task automatic issue(input logic [15:0] iw, input logic [31:0] e = 32'h0);
        @(negedge clk_4x);
        instr = iw; ext = e; instr_valid = 1'b1;
        while (!instr_ready) @(negedge clk_4x);
        pc_in = pc_in + 32'd2;
    endtask

    task automatic bubble(input int n);
        @(negedge clk_4x);
        instr_valid = 1'b0;
        repeat (n - 1) @(negedge clk_4x);
    endtask

    // Encodings (verified against the group layouts in mh030p_decode.sv):
    //   MOVEQ #imm,Dn   0111 nnn0 iiiiiiii
    //   ADD.L  Dy,Dn    1101 nnn0 10 000 yyy
    //   SUB.L  Dy,Dn    1001 nnn0 10 000 yyy
    //   AND.L  Dy,Dn    1100 nnn0 10 000 yyy
    //   LSL.L  #c,Dn    1110 ccc1 10 0 01 nnn
    function automatic logic [15:0] MOVEQ(input int n, input int imm);
        MOVEQ = 16'h7000 | (n << 9) | (imm & 8'hFF);
    endfunction
    function automatic logic [15:0] ADDL(input int n, input int y);
        ADDL = 16'hD080 | (n << 9) | y;
    endfunction
    function automatic logic [15:0] SUBL(input int n, input int y);
        SUBL = 16'h9080 | (n << 9) | y;
    endfunction
    function automatic logic [15:0] ANDL(input int n, input int y);
        ANDL = 16'hC080 | (n << 9) | y;
    endfunction
    //   MULU.W Dy,Dn    1100 nnn0 11 000 yyy
    //   DIVU.W Dy,Dn    1000 nnn0 11 000 yyy
    function automatic logic [15:0] MULUW(input int n, input int y);
        MULUW = 16'hC0C0 | (n << 9) | y;
    endfunction
    function automatic logic [15:0] DIVUW(input int n, input int y);
        DIVUW = 16'h80C0 | (n << 9) | y;
    endfunction
    function automatic logic [15:0] LSLL(input int c, input int n);
        LSLL = 16'hE188 | (c << 9) | n;
    endfunction

    initial begin
        $display("=== mh030p_core: integer pipeline (reg-direct + memory src) ===");
        for (int i = 0; i < 1024; i++) ram[i] = 32'h0;
        ram[32'h40 >> 2] = 32'hDEAD_0001;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        @(negedge clk_4x);

        // ── Independent writes ─────────────────────────────────────────────
        issue(MOVEQ(0, 8'h05));
        issue(MOVEQ(1, 8'h03));

        // ── RAW, one behind: ADD.L D1,D0 immediately after D1 is written.
        //    D1 needs the commit happening this cycle; D0 needs the previous
        //    one. A single-level forwarding network fails this.
        issue(ADDL(0, 1));            // D0 = 5 + 3 = 8

        // ── RAW, two behind ────────────────────────────────────────────────
        issue(MOVEQ(4, 8'h01));
        issue(ADDL(4, 0));            // D4 = 1 + 8 = 9  (D0 two instructions back)

        // ── Back-to-back dependent chain ───────────────────────────────────
        issue(MOVEQ(5, 8'h02));
        issue(ADDL(5, 5));            // D5 = 2 + 2 = 4
        issue(ADDL(5, 5));            // D5 = 4 + 4 = 8
        issue(ADDL(5, 5));            // D5 = 8 + 8 = 16

        // ── Subtract, AND, shift ───────────────────────────────────────────
        issue(MOVEQ(6, 8'h0A));
        issue(MOVEQ(7, 8'h04));
        issue(SUBL(6, 7));            // D6 = 10 - 4 = 6
        issue(MOVEQ(2, 8'h0F));
        issue(MOVEQ(3, 8'h09));
        issue(ANDL(2, 3));            // D2 = 0x0F & 0x09 = 0x09
        issue(LSLL(1, 3));            // D3 = 9 << 1 = 18

        bubble(6);
        chk("D0 = 5+3",        dut.u_rf.regs[0],  32'd8);
        chk("D1 = 3",          dut.u_rf.regs[1],  32'd3);
        chk("D4 = 1+D0",       dut.u_rf.regs[4],  32'd9);
        chk("D5 chain x3",     dut.u_rf.regs[5],  32'd16);
        chk("D6 = 10-4",       dut.u_rf.regs[6],  32'd6);
        chk("D2 = 0x0F&0x09",  dut.u_rf.regs[2],  32'h0000_0009);
        chk("D3 = 9<<1",       dut.u_rf.regs[3],  32'd18);

        // ── Memory source operands (P3) ────────────────────────────────────
        // ram is longword granular; these all use .L so the model matches.
        //   MOVE.L (An),Dn     0010 nnn0 00 010 aaa
        //   ADD.L  (An),Dn     1101 nnn0 10 010 aaa
        //   MOVE.L (An)+,Dn    0010 nnn0 00 011 aaa
        issue(MOVEQ(3, 8'h40));           // A3 base via D3 then MOVEA
        issue(16'h2643);                  // MOVEA.L D3,A3   -> A3 = 0x40
        issue(16'h2813);                  // MOVE.L (A3),D4  -> D4 = ram[0x40]
        issue(16'hDA93);                  // ADD.L  (A3),D5  -> D5 = 16 + ram[0x40]
        issue(16'h2C1B);                  // MOVE.L (A3)+,D6 -> D6 = ram[0x40], A3 += 4

        // +2 over the pre-split count: the AG/EX EA-adder split
        // (~/.claude/plans/golden-puzzling-music.md) adds one cycle before
        // a memory-referencing instruction's own mem_req first dispatches.
        bubble(10);
        chk("D4 = (A3)",       dut.u_rf.regs[4],  32'hDEAD_0001);
        chk("D5 = 16+(A3)",    dut.u_rf.regs[5],  32'hDEAD_0011);
        chk("D6 = (A3)+",      dut.u_rf.regs[6],  32'hDEAD_0001);
        chk("A3 post-inc",     dut.u_rf.regs[11], 32'h0000_0044);

        // ── Memory WRITES: register source, memory destination ─────────────
        //   MOVE.L Dn,(An)    0010 aaa1 00 000 nnn
        //   MOVE.L Dn,(An)+   0010 aaa0 11 000 nnn  -> dst mode 011
        issue(MOVEQ(7, 8'h2A));           // D7 = 0x2A
        issue(16'h2687);                  // MOVE.L D7,(A3)   -> ram[A3] = 0x2A
        issue(16'h26C7);                  // MOVE.L D7,(A3)+  -> ram[A3] then A3 += 4

        bubble(12);  // +2, same reason as above
        chk("mem wr (A3)",     ram[32'h44 >> 2],  32'h0000_002A);
        chk("A3 after wr inc", dut.u_rf.regs[11], 32'h0000_0048);

        // ── Multiply and divide ────────────────────────────────────────────
        // The divider is sequential (one compare+subtract per tick), so these
        // exercise the EX stall and the one-shot start as well as the maths.
        issue(MOVEQ(0, 8'd6));
        issue(MOVEQ(1, 8'd7));
        issue(MULUW(0, 1));               // D0 = 6 * 7 = 42
        issue(MOVEQ(2, 8'd40));
        issue(MOVEQ(3, 8'd5));
        issue(DIVUW(2, 3));               // D2 = {rem 0, quot 8} = 0x00000008
        issue(MOVEQ(4, 8'd45));
        issue(MOVEQ(5, 8'd7));
        issue(DIVUW(4, 5));               // 45/7 = 6 rem 3 -> 0x00030006

        // A sequential divide takes ~33 ticks once it reaches EX, so the
        // drain has to outlast it -- 12 cycles left the last DIVU.W still
        // running and its result uncommitted.
        bubble(50);
        chk("MULU.W 6*7",      dut.u_rf.regs[0],  32'd42);
        chk("DIVU.W 40/5",     dut.u_rf.regs[2],  32'h0000_0008);
        chk("DIVU.W 45/7",     dut.u_rf.regs[4],  32'h0003_0006);

        // ── Branches ───────────────────────────────────────────────────────
        // A taken branch must squash the two instructions behind it. The
        // squashed MOVEQ would set D7 to 0x55; if the flush fails it lands
        // and the check catches it.
        //   BRA.B  0110 0000 dddddddd
        //   BEQ.B  0110 0111 dddddddd
        // What can be checked WITHOUT a fetch unit is the squash: the
        // instructions already in ID and AG behind a taken branch must not
        // commit. Whether execution resumes at the right ADDRESS cannot be
        // checked here -- this harness feeds instructions in sequence and
        // never re-fetches from redirect_pc, so it cannot tell a correct
        // two-instruction squash from an over-squash. That needs the IF
        // stage, and the redirect_pc arithmetic is asserted separately below.
        issue(MOVEQ(7, 8'h11));           // D7 = 0x11
        issue(16'h6002);                  // BRA.B, taken
        issue(MOVEQ(7, 8'h55));           // must be squashed
        issue(MOVEQ(7, 8'h66));           // must be squashed
        bubble(12);
        chk("BRA squashes behind", dut.u_rf.regs[7], 32'h0000_0011);

        // Not-taken conditional: nothing is squashed.
        issue(MOVEQ(1, 8'h01));           // D1 = 1 -> Z clear
        issue(16'h6702);                  // BEQ.B +2 -> NOT taken (Z=0)
        issue(MOVEQ(5, 8'h33));           // must RUN
        bubble(12);
        chk("BEQ not taken",      dut.u_rf.regs[5], 32'h0000_0033);

        // redirect_pc arithmetic, checked directly: the 68k branch base is
        // the address of the branch plus 2.
        chk("redirect_pc base",  branch_pc_seen, branch_pc_expect);

        bubble(4);

        chk("MULU.W 6*7",      dut.u_rf.regs[0],  32'd42);
        chk("DIVU.W 40/5",     dut.u_rf.regs[2],  32'h0000_0008);
        chk("DIVU.W 45/7",     dut.u_rf.regs[4],  32'h0003_0006);

        // ── Read-modify-write: two bus cycles on one address ───────────────
        //   ADD.L Dn,(An)   1101 nnn1 10 010 aaa
        //   AND.L Dn,(An)   1100 nnn1 10 010 aaa
        ram[32'h20 >> 2] = 32'h0000_0010;
        issue(MOVEQ(3, 8'h20));   // MOVEQ sign-extends: keep the address positive
        issue(16'h2643);                  // MOVEA.L D3,A3  -> A3 = 0x80
        issue(MOVEQ(0, 8'h05));
        issue(16'hD193);                  // ADD.L D0,(A3)  -> mem = 0x10 + 5
        bubble(16);
        chk("RMW ADD.L D0,(A3)", ram[32'h20 >> 2], 32'h0000_0015);

        ram[32'h24 >> 2] = 32'h0000_00FF;
        issue(MOVEQ(3, 8'h24));
        issue(16'h2643);                  // A3 = 0x84
        issue(MOVEQ(1, 8'h0F));
        issue(16'hC393);                  // AND.L D1,(A3) -> mem = 0xFF & 0x0F
        bubble(16);
        chk("RMW AND.L D1,(A3)", ram[32'h24 >> 2], 32'h0000_000F);


        // ── Indexed EA: (d8,An,Xn) ─────────────────────────────────────────
        // MOVE.L (d8,A3,D4.L),D5 = 0x2A33 + ext. The extension word is
        // 0x4802: Xn=D4 (bits 15:12 = 0100), W/L=1 (long), scale=00, d8=0x02.
        // A3 = 0x20, D4 = 0x10, d8 = 2  ->  EA = 0x32... use scale 0 and a
        // longword-aligned result: A3=0x20, D4=0x10, d8=0x04 -> 0x34.
        ram[32'h34 >> 2] = 32'hC0FF_EE00;
        issue(MOVEQ(3, 8'h20));
        issue(16'h2643);                  // A3 = 0x20
        issue(MOVEQ(4, 8'h10));           // D4 = 0x10 (index)
        issue(16'h2A33, 32'h0000_4804);   // MOVE.L (4,A3,D4.L),D5
        bubble(16);
        chk("indexed (4,A3,D4.L)", dut.u_rf.regs[5], 32'hC0FF_EE00);

        // ── Memory-to-memory MOVE: two different addresses ─────────────────
        // MOVE.L (A3),(A4) = 0010 100 010 010 011 = 0x2893
        ram[32'h30 >> 2] = 32'hBEEF_1234;
        ram[32'h38 >> 2] = 32'h0;
        issue(MOVEQ(3, 8'h30));
        issue(16'h2643);                  // A3 = 0x30 (source)
        issue(MOVEQ(4, 8'h38));
        issue(16'h2844);                  // MOVEA.L D4,A4 -> A4 = 0x38 (dest)
        issue(16'h2893);                  // MOVE.L (A3),(A4)
        bubble(18);
        chk("mem->mem MOVE.L",  ram[32'h38 >> 2], 32'hBEEF_1234);
        chk("mem->mem src kept", ram[32'h30 >> 2], 32'hBEEF_1234);

        // ── Bit ops, BCD, EXT, SWAP, ADDX ──────────────────────────────────
        //   BSET #n,Dn   0000 1000 11 000 rrr + ext(bit number)
        //   BCLR #n,Dn   0000 1000 10 000 rrr
        //   ABCD Dy,Dx   1100 xxx1 0000 0yyy
        //   EXT.W Dn     0100 1000 10 000 rrr
        //   SWAP Dn      0100 1000 0100 0rrr
        //   ADDX.L Dy,Dx 1101 xxx1 10 000 yyy
        issue(MOVEQ(0, 8'h00));
        issue(16'h08C0, 32'h0000_0003);   // BSET #3,D0  -> D0 = 8
        bubble(8);
        chk("BSET #3,D0",     dut.u_rf.regs[0], 32'h0000_0008);

        issue(16'h0880, 32'h0000_0003);   // BCLR #3,D0  -> D0 = 0
        bubble(8);
        chk("BCLR #3,D0",     dut.u_rf.regs[0], 32'h0000_0000);

        // ABCD D1,D2: packed-BCD 12 + 19 = 31. X feeds in, so clear it first
        // with a 0+0 ADD -- there is no direct "clear X" here.
        issue(MOVEQ(6, 8'h00));
        issue(ADDL(6, 6));                // D6 = 0, C=0 -> X=0
        issue(MOVEQ(1, 8'h19));           // D1 = 0x19 (BCD 19)
        issue(MOVEQ(2, 8'h12));           // D2 = 0x12 (BCD 12)
        issue(16'hC501);                  // ABCD D1,D2 -> D2 = 0x31
        bubble(10);
        chk("ABCD 12+19",     dut.u_rf.regs[2], 32'h0000_0031);

        issue(MOVEQ(4, 8'h7F));
        issue(16'h4884);                  // EXT.W D4 -> 0x0000007F stays
        bubble(8);
        chk("EXT.W D4",       dut.u_rf.regs[4], 32'h0000_007F);

        issue(MOVEQ(5, 8'h21));
        issue(16'h4845);                  // SWAP D5 -> 0x00210000
        bubble(8);
        chk("SWAP D5",        dut.u_rf.regs[5], 32'h0021_0000);

        // ── MOVEM: many registers, one bus cycle each ──────────────────────
        // MOVEM.L D0-D2,(A3)  = 0x48D3 + mask 0x0007 (D0,D1,D2)
        // MOVEM.L (A3),D4-D6  = 0x4CD3 + mask 0x0070 (D4,D5,D6)
        issue(MOVEQ(3, 8'h50));
        issue(16'h2643);                  // A3 = 0x50
        issue(MOVEQ(0, 8'h11));
        issue(MOVEQ(1, 8'h22));
        issue(MOVEQ(2, 8'h33));
        issue(16'h48D3, 32'h0000_0007);   // MOVEM.L D0-D2,(A3)
        bubble(32);
        chk("MOVEM store D0",  ram[32'h50 >> 2], 32'h0000_0011);
        chk("MOVEM store D1",  ram[32'h54 >> 2], 32'h0000_0022);
        chk("MOVEM store D2",  ram[32'h58 >> 2], 32'h0000_0033);

        issue(16'h4CD3, 32'h0000_0070);   // MOVEM.L (A3),D4-D6
        bubble(32);
        chk("MOVEM load D4",   dut.u_rf.regs[4], 32'h0000_0011);
        chk("MOVEM load D5",   dut.u_rf.regs[5], 32'h0000_0022);
        chk("MOVEM load D6",   dut.u_rf.regs[6], 32'h0000_0033);

        $display("");
        if (fails == 0) begin
            $display("=== 0 failure(s) ===");
            $display("ALL TESTS PASSED");
        end else begin
            $display("=== %0d failure(s) ===", fails);
        end
        $finish;
    end

endmodule

`default_nettype wire

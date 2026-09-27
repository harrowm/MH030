`default_nettype none
`timescale 1ns/1ps

// =============================================================================
// MH030-P top: the core running a real program out of memory.
//
// This is the first test where the branch TARGET is verifiable. The core-level
// testbench can only check that a taken branch squashes what is behind it,
// because it feeds instructions in sequence and never re-fetches from
// redirect_pc. Here the fetch unit reads from the same memory the program
// lives in, so a wrong target executes the wrong instruction and shows up in
// the register file.
// =============================================================================

module mh030p_top_tb;

    logic clk_4x = 1'b0;
    logic rst_n  = 1'b0;
    always #5 clk_4x = ~clk_4x;

    wire        bus_req, bus_rw;
    wire [31:0] bus_addr, bus_wdata;
    wire [1:0]  bus_siz;
    wire        wb_wr_en;
    wire [3:0]  wb_wr_sel;
    wire [31:0] wb_wr_data;
    wire [7:0]  ccr_out;

    // No interrupt source in these programs; a dedicated test drives it.
    logic [2:0]  ipl       = 3'b000;
    logic [31:0] bus_rdata = 32'h0;
    logic        bus_ack   = 1'b0;

    // ONE memory behind ONE bus, held as 16-bit words. Both instruction
    // fetch and data go through it, which is the point of the arbiter. A
    // word-granular store also handles the unaligned longword fetch a branch
    // target can produce -- a target at byte 6 reads words 3 and 4.
    logic [15:0] prog [0:1023];

    function automatic logic [31:0] rd32(input logic [31:0] a);
        rd32 = {prog[a[10:1]], prog[a[10:1] + 1]};
    endfunction

    // Lane-aware, and right-justified for byte and word: that is the
    // convention the core reads with (mem_rdata[15:0] for a word) and writes
    // with (the low bits of the register). A model that always moved a full
    // longword worked only because nothing had yet issued a narrow access --
    // RTE's status-word pop is the first.
    logic [31:0] rdw;
    always_ff @(posedge clk_4x) begin
        bus_ack <= 1'b0;
        if (bus_req && !bus_ack) begin
            bus_ack <= 1'b1;
            rdw = {prog[bus_addr[10:1]], prog[bus_addr[10:1] + 1]};
            if (bus_rw) begin
                case (bus_siz)
                    2'b01: bus_rdata <= bus_addr[0] ? {24'h0, rdw[23:16]}
                                                    : {24'h0, rdw[31:24]};
                    2'b10: bus_rdata <= {16'h0, rdw[31:16]};
                    default: bus_rdata <= rdw;
                endcase
            end else begin
                case (bus_siz)
                    2'b01: prog[bus_addr[10:1]] <=
                               bus_addr[0] ? {rdw[31:24], bus_wdata[7:0]}
                                           : {bus_wdata[7:0], rdw[23:16]};
                    2'b10: prog[bus_addr[10:1]] <= bus_wdata[15:0];
                    default: begin
                        prog[bus_addr[10:1]]     <= bus_wdata[31:16];
                        prog[bus_addr[10:1] + 1] <= bus_wdata[15:0];
                    end
                endcase
            end
        end
    end

    mh030p_top dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .bus_req(bus_req), .bus_addr(bus_addr), .bus_rw(bus_rw),
        .bus_siz(bus_siz), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack), .ipl(ipl),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out)
    );


    int fails = 0;
    task automatic chk(input string name, input logic [31:0] got,
                                          input logic [31:0] exp);
        if (got === exp) $display("PASS  %-24s = %08h", name, got);
        else begin
            $display("FAIL  %-24s got %08h exp %08h", name, got, exp);
            fails++;
        end
    endtask

    function automatic logic [15:0] MOVEQ(input int n, input int imm);
        MOVEQ = 16'h7000 | (n << 9) | (imm & 8'hFF);
    endfunction
    function automatic logic [15:0] ADDL(input int n, input int y);
        ADDL = 16'hD080 | (n << 9) | y;
    endfunction

    integer i;
    initial begin
        $display("=== mh030p_top: program execution from memory ===");
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;

        // Program at address 0. Word index = byte address / 2.
        //  0: MOVEQ #1,D0
        //  2: MOVEQ #2,D1
        //  4: BRA.B +4          -> target = 4 + 2 + 4 = 10
        //  6: MOVEQ #0x7F,D0    <- must NOT execute
        //  8: MOVEQ #0x7E,D1    <- must NOT execute
        // 10: MOVEQ #4,D2
        // 12: ADD.L D1,D0       -> D0 = 1 + 2 = 3 if the skip worked
        prog[0] = MOVEQ(0, 8'h01);
        prog[1] = MOVEQ(1, 8'h02);
        prog[2] = 16'h6004;                 // BRA.B +4
        prog[3] = MOVEQ(0, 8'h7F);
        prog[4] = MOVEQ(1, 8'h7E);
        prog[5] = MOVEQ(2, 8'h04);
        prog[6] = ADDL(0, 1);

        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (120) @(negedge clk_4x);

        // If the branch target were wrong, D0/D1 would hold 0x7F/0x7E.
        chk("D0 = 1+2 (skipped)", dut.u_core.u_rf.regs[0], 32'd3);
        chk("D1 = 2 (skipped)",   dut.u_core.u_rf.regs[1], 32'd2);
        chk("D2 = 4 (at target)", dut.u_core.u_rf.regs[2], 32'd4);

        // ── DBcc loop and Scc ──────────────────────────────────────────────
        // A DBcc loop is the real test of the redirect path: it takes the
        // branch repeatedly and must terminate at exactly -1.
        //   MOVEQ #3,D3        D3 = 3
        //   MOVEQ #0,D4        D4 = 0
        // L: ADDQ.L #1,D4      D4 += 1          (0x5284)
        //   DBF D3,L           loop while D3.W != -1  (0x51CB + disp)
        //   ST  D5             Scc always-true -> D5 low byte = 0xFF
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(3, 8'd3);
        prog[1] = MOVEQ(4, 8'd0);
        prog[2] = 16'h5284;                 // ADDQ.L #1,D4   <- loop body at 4
        prog[3] = 16'h51CB;                 // DBF D3,<disp>
        prog[4] = 16'hFFFE;                 // disp = -2 -> target = 6 + 2 - 2 = 6? see below
        prog[5] = 16'h50C5;                 // ST D5

        // DBF is at byte 6; its base is 6+2 = 8, so a target of byte 4 (the
        // loop body) needs disp = 4 - 8 = -4.
        prog[4] = 16'hFFFC;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (200) @(negedge clk_4x);

        // D3 counts 3,2,1,0 then -1 terminates: body runs 4 times.
        chk("DBF loop count",  dut.u_core.u_rf.regs[4], 32'd4);
        chk("DBF terminates",  dut.u_core.u_rf.regs[3], 32'h0000_FFFF);
        chk("ST sets byte",    dut.u_core.u_rf.regs[5][7:0] | 32'h0, 32'h0000_00FF);

        // ── BSR / RTS: call and return through the stack ────────────────────
        //  0: MOVEQ #0x40,D7        set up a stack pointer value
        //  2: MOVEA.L D7,A7         A7 = 0x40
        //  4: MOVEQ #1,D0
        //  6: BSR.B  +6             call the routine at byte 12
        //  8: MOVEQ #2,D1           runs AFTER the return
        // 10: NOP
        // 12: MOVEQ #7,D2           the routine
        // 14: RTS                   back to byte 8
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h40);
        prog[1] = 16'h2E47;                 // MOVEA.L D7,A7
        prog[2] = MOVEQ(0, 8'd1);
        prog[3] = 16'h6106;                 // BSR.B +6 -> 6+2+6 = 14? see below
        prog[4] = MOVEQ(1, 8'd2);
        // Park here after the return, otherwise execution falls through into
        // the routine again and RTS pops repeatedly off a stack that is no
        // longer its own -- which is what made A7 look wrong.
        prog[5] = 16'h60FE;                 // BRA.B -2 (to itself, at byte 10)
        prog[6] = MOVEQ(2, 8'd7);
        prog[7] = 16'h4E75;                 // RTS
        // BSR is at byte 6; base 6+2 = 8; the routine is at byte 12, so the
        // displacement is 12 - 8 = 4.
        prog[3] = 16'h6104;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("BSR reached routine", dut.u_core.u_rf.regs[2], 32'd7);
        chk("RTS returned",        dut.u_core.u_rf.regs[1], 32'd2);
        chk("stack restored",      dut.u_core.u_rf.regs[15], 32'h0000_0040);

        // ── TRAP #0: frame pushed, vector fetched, handler entered ──────────
        // TRAP #n takes vector 32+n, whose address is 4*(32+n) = 0x80 for #0.
        //  0: MOVEQ #0x60,D7
        //  2: MOVEA.L D7,A7      A7 = 0x60
        //  4: TRAP #0            -> vector at 0x80 -> handler at byte 0x30
        //  6: MOVEQ #0x7F,D0     must NOT run
        // 0x30: MOVEQ #9,D3 ; BRA self
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;                // MOVEA.L D7,A7
        prog[2]  = 16'h4E40;                // TRAP #0
        prog[3]  = MOVEQ(0, 8'h7F);         // skipped if the trap is taken
        prog[24] = MOVEQ(3, 8'd9);          // handler at byte 0x30
        prog[25] = 16'h60FE;                // park
        prog[32'h80 >> 1]     = 16'h0000;   // vector 32 -> handler at 0x30
        prog[(32'h80 >> 1) + 1] = 16'h0030;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("TRAP entered handler", dut.u_core.u_rf.regs[3], 32'd9);
        chk("TRAP skipped inline",  dut.u_core.u_rf.regs[0], 32'd0);
        chk("TRAP pushed frame",    dut.u_core.u_rf.regs[15], 32'h0000_0058);
        // Format $0: the SR alone at SP+0, the PC at SP+2.
        chk("frame holds PC",       rd32(32'h5A), 32'h0000_0006);
        chk("frame holds SR",       {16'h0, prog[32'h58 >> 1]}, 32'h0000_2700);

        // ── LEA / PEA: the effective address AS the result ──────────────────
        // The second LEA reads the address register the first one just wrote,
        // which is the case that needs the AG interlock: an EA-class
        // instruction wants its base a whole stage before a producer still in
        // EX has anything to forward.
        //  0: MOVEQ #0x50,D7
        //  2: MOVEA.L D7,A7        A7 = 0x50
        //  4: LEA (0x24).W,A1      A1 = 0x24
        //  8: LEA (6,A1),A2        A2 = 0x2A
        // 12: PEA (0x30).W         push 0x30, A7 = 0x4C
        // 16: BRA self
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h50);
        prog[1] = 16'h2E47;                 // MOVEA.L D7,A7
        prog[2] = 16'h43F8; prog[3] = 16'h0024;   // LEA (0x24).W,A1
        prog[4] = 16'h45E9; prog[5] = 16'h0006;   // LEA (6,A1),A2
        prog[6] = 16'h4878; prog[7] = 16'h0030;   // PEA (0x30).W
        prog[8] = 16'h60FE;                 // park

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (200) @(negedge clk_4x);

        chk("LEA absolute",     dut.u_core.u_rf.regs[9],  32'h0000_0024);
        chk("LEA (d16,An)",     dut.u_core.u_rf.regs[10], 32'h0000_002A);
        chk("PEA moved SP",     dut.u_core.u_rf.regs[15], 32'h0000_004C);
        chk("PEA pushed EA",    rd32(32'h4C),             32'h0000_0030);

        // ── JMP / JSR: a redirect to a computed address ──────────────────────
        //  0: MOVEQ #0x50,D7
        //  2: MOVEA.L D7,A7
        //  4: JSR (0x20).W       push 8, A7 = 0x4C, go to 0x20
        //  8: MOVEQ #5,D3        runs after the RTS
        // 10: JMP (0x14).W       go to 0x14
        // 14: MOVEQ #0x7F,D0     must NOT run
        // 0x14: MOVEQ #6,D5 ; park
        // 0x20: MOVEQ #7,D4 ; RTS
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h50);
        prog[1]  = 16'h2E47;
        prog[2]  = 16'h4EB8; prog[3] = 16'h0020;  // JSR (0x20).W
        prog[4]  = MOVEQ(3, 8'd5);
        prog[5]  = 16'h4EF8; prog[6] = 16'h0014;  // JMP (0x14).W
        prog[7]  = MOVEQ(0, 8'h7F);               // skipped by the JMP
        prog[10] = MOVEQ(5, 8'd6);                // 0x14
        prog[11] = 16'h60FE;
        prog[16] = MOVEQ(4, 8'd7);                // 0x20
        prog[17] = 16'h4E75;                      // RTS

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("JSR reached target", dut.u_core.u_rf.regs[4],  32'd7);
        chk("JSR RTS returned",   dut.u_core.u_rf.regs[3],  32'd5);
        chk("JMP reached target", dut.u_core.u_rf.regs[5],  32'd6);
        chk("JMP skipped inline", dut.u_core.u_rf.regs[0],  32'd0);
        chk("JSR SP restored",    dut.u_core.u_rf.regs[15], 32'h0000_0050);

        // ── TRAP then RTE: a full round trip through a stack frame ──────────
        // The CCR is deliberately non-zero when the trap is taken and is
        // changed by the handler, so a restored CCR is distinguishable from a
        // reset one -- otherwise "RTE restored the status" passes for free.
        //  0: MOVEQ #0x60,D7
        //  2: MOVEA.L D7,A7        A7 = 0x60
        //  4: MOVEQ #-1,D0         CCR = 0x08 (N set)
        //  6: TRAP #0              -> handler at 0x30
        //  8: MOVEA.L D0,A1        runs only if the RTE returns here. MOVEA
        //                          is deliberate: a MOVEQ marker would set
        //                          the CCR itself and overwrite the very
        //                          thing the RTE just restored.
        // 10: park
        // 0x30: MOVEQ #9,D3 ; MOVEQ #0,D4 (CCR = Z) ; RTE
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'hFF);         // MOVEQ #-1,D0 -> N set
        prog[3]  = 16'h4E40;                // TRAP #0
        prog[4]  = 16'h2240;                // MOVEA.L D0,A1
        prog[5]  = 16'h60FE;
        prog[24] = MOVEQ(3, 8'd9);          // 0x30 handler
        prog[25] = MOVEQ(4, 8'd0);          // clears N, sets Z
        prog[26] = 16'h4E73;                // RTE
        prog[32'h80 >> 1]       = 16'h0000; // vector 32 -> 0x30
        prog[(32'h80 >> 1) + 1] = 16'h0030;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (300) @(negedge clk_4x);

        chk("RTE handler ran",   dut.u_core.u_rf.regs[3],  32'd9);
        chk("RTE returned",      dut.u_core.u_rf.regs[9],  32'hFFFF_FFFF);
        chk("RTE popped frame",  dut.u_core.u_rf.regs[15], 32'h0000_0060);
        // N was set before the trap and cleared by the handler; the pop must
        // put it back.
        chk("RTE restored CCR",  {24'h0, ccr_out},         32'h0000_0008);

        // ── CCR forwarding: a flag consumer directly behind its producer ─────
        // ccr_r is written in WB, so an instruction in EX is a whole stage
        // ahead of its predecessor's flag update. Without forwarding, a Bcc
        // immediately after a CMP branches on the PREVIOUS instruction's
        // flags and an ADDX adds the previous X. Both are tested here with no
        // filler between producer and consumer, which is the only arrangement
        // that can tell the difference.
        //  0: MOVEQ #5,D0 ; 2: MOVEQ #5,D1
        //  4: CMP.L D1,D0        Z set
        //  6: BEQ.B -> 12        must be taken on THIS CMP's Z
        //  8: MOVEQ #0x7F,D2     must NOT run
        // 12: MOVEQ #-1,D0 ; MOVEQ #1,D1 ; MOVEQ #0,D4 ; MOVEQ #0,D5
        // 20: ADD.L D1,D0        D0 = 0, X = 1
        // 22: ADDX.L D5,D4       D4 = 0 + 0 + X = 1
        // 24: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(0, 8'd5);
        prog[1]  = MOVEQ(1, 8'd5);
        prog[2]  = 16'hB081;                // CMP.L D1,D0 -> Z
        prog[3]  = 16'h6704;                // BEQ.B +4 -> byte 12
        prog[4]  = MOVEQ(2, 8'h7F);         // skipped
        prog[6]  = MOVEQ(0, 8'hFF);         // byte 12: D0 = -1
        prog[7]  = MOVEQ(1, 8'd1);
        prog[8]  = MOVEQ(4, 8'd0);
        prog[9]  = MOVEQ(5, 8'd0);
        prog[10] = 16'hD081;                // ADD.L D1,D0 -> D0 = 0, X = 1
        prog[11] = 16'hD985;                // ADDX.L D5,D4 -> D4 = 1
        prog[12] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (200) @(negedge clk_4x);

        chk("BEQ saw its own CMP",  dut.u_core.u_rf.regs[2], 32'd0);
        chk("ADD wrapped to zero",  dut.u_core.u_rf.regs[0], 32'd0);
        chk("ADDX saw forwarded X", dut.u_core.u_rf.regs[4], 32'd1);

        // ── EXG: two commits from one instruction ───────────────────────────
        // The first genuine need for a second register-file write port. The
        // mixed form is included deliberately: which side is the address
        // register differs per flavour, and the swap has to survive that.
        //  0: MOVEQ #5,D0 ; 2: MOVEQ #9,D1
        //  4: EXG D0,D1           D0 = 9, D1 = 5
        //  6: MOVEQ #3,D2 ; 8: MOVEA.L D2,A3      A3 = 3
        // 10: EXG D0,A3           D0 = 3, A3 = 9
        // 12: MOVEA.L A3,A5       A5 = 9 -- reads the SECOND port's target
        //                         with no filler, so only forwarding can
        //                         supply it
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(0, 8'd5);
        prog[1] = MOVEQ(1, 8'd9);
        prog[2] = 16'hC141;                 // EXG D0,D1
        prog[3] = MOVEQ(2, 8'd3);
        prog[4] = 16'h2642;                 // MOVEA.L D2,A3
        prog[5] = 16'hC18B;                 // EXG D0,A3
        prog[6] = 16'h2A4B;                 // MOVEA.L A3,A5
        prog[7] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (200) @(negedge clk_4x);

        chk("EXG Dx,Dy port 1",  dut.u_core.u_rf.regs[0],  32'd3);
        chk("EXG Dx,Dy port 2",  dut.u_core.u_rf.regs[1],  32'd5);
        chk("EXG Dx,Ay port 2",  dut.u_core.u_rf.regs[11], 32'd9);
        chk("EXG port 2 fwd",    dut.u_core.u_rf.regs[13], 32'd9);

        // ── LINK / UNLK: a stack frame built and torn down ───────────────────
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7     A7 = 0x60
        //  4: MOVEQ #0x11,D0 ; 6: MOVEA.L D0,A2     A2 = 0x11
        //  8: LINK A2,#-8       push A2 at 0x5C, A2 = 0x5C, A7 = 0x54
        // 12: MOVEQ #7,D1
        // 14: UNLK A2          A7 = A2 + 4 = 0x60, A2 = pop = 0x11
        // 16: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h60);
        prog[1] = 16'h2E47;                 // MOVEA.L D7,A7
        prog[2] = MOVEQ(0, 8'h11);
        prog[3] = 16'h2440;                 // MOVEA.L D0,A2
        prog[4] = 16'h4E52; prog[5] = 16'hFFF8;   // LINK A2,#-8
        prog[6] = MOVEQ(1, 8'd7);
        prog[7] = 16'h4E5A;                 // UNLK A2
        prog[8] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("LINK pushed old An",  rd32(32'h5C),             32'h0000_0011);
        chk("UNLK restored An",    dut.u_core.u_rf.regs[10], 32'h0000_0011);
        chk("UNLK restored SP",    dut.u_core.u_rf.regs[15], 32'h0000_0060);
        chk("LINK ran the body",   dut.u_core.u_rf.regs[1],  32'd7);

        // ── MOVE to/from SR, CCR and USP ────────────────────────────────────
        //  0: MOVEQ #-1,D0     CCR = 0x08 (N)
        //  2: MOVE SR,D1       D1 low word = 0x2708
        //  4: MOVE CCR,D2      D2 low word = 0x0008
        //  6: MOVEQ #0x20,D4 ; 8: MOVEA.L D4,A1    A1 = 0x20
        // 10: MOVE A1,USP     USP = 0x20
        // 12: MOVE USP,A2     A2 = 0x20
        // 14: MOVEQ #8,D3     D3 = 8, CCR = 0
        // 16: MOVE D3,CCR     CCR = 0x08 again, from the transfer this time.
        //                     LAST deliberately: any MOVEQ after it would set
        //                     the CCR itself and erase what was transferred.
        // 18: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(0, 8'hFF);
        prog[1] = 16'h40C1;                 // MOVE SR,D1
        prog[2] = 16'h42C2;                 // MOVE CCR,D2
        prog[3] = MOVEQ(4, 8'h20);
        prog[4] = 16'h2244;                 // MOVEA.L D4,A1
        prog[5] = 16'h4E61;                 // MOVE A1,USP
        prog[6] = 16'h4E6A;                 // MOVE USP,A2
        prog[7] = MOVEQ(3, 8'd8);
        prog[8] = 16'h44C3;                 // MOVE D3,CCR
        prog[9] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (400) @(negedge clk_4x);

        // Reset leaves S set and the mask at 7, and the MOVEQ above set N.
        chk("MOVE SR,Dn",   dut.u_core.u_rf.regs[1] & 32'h0000_FFFF, 32'h2708);
        chk("MOVE CCR,Dn",  dut.u_core.u_rf.regs[2] & 32'h0000_FFFF, 32'h0008);
        chk("MOVE Dn,CCR",  {24'h0, ccr_out},                  32'h0000_0008);
        chk("MOVE An,USP",  dut.u_core.usp_r,                  32'h0000_0020);
        chk("MOVE USP,An",  dut.u_core.u_rf.regs[10],          32'h0000_0020);

        // ── PC-relative effective addresses ─────────────────────────────────
        // The base is the address of the instruction's own EXTENSION WORD --
        // its PC plus two -- not the next instruction and not the opcode.
        //  0: MOVEQ #0x10,D2
        //  2: MOVE.L (0x1C,PC),D1      base 4 -> 0x20
        //  6: MOVE.L (0x10,PC,D2.L),D3 base 8 -> 8 + 0x10 + 0x10 = 0x28
        // 10: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(2, 8'h10);
        prog[1]  = 16'h223A; prog[2] = 16'h001C;   // MOVE.L (d16,PC),D1
        prog[3]  = 16'h263B; prog[4] = 16'h2810;   // MOVE.L (d8,PC,D2.L),D3
        prog[5]  = 16'h60FE;
        prog[16] = 16'hDEAD; prog[17] = 16'hBEEF;  // 0x20
        prog[20] = 16'hCAFE; prog[21] = 16'hBABE;  // 0x28

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("(d16,PC)",      dut.u_core.u_rf.regs[1], 32'hDEAD_BEEF);
        chk("(d8,PC,Xn.L)",  dut.u_core.u_rf.regs[3], 32'hCAFE_BABE);

        // ── TRAPV: taken and not taken ───────────────────────────────────────
        // The same opcode twice, with V clear then set, so "the trap fired"
        // and "the trap was conditional" are both actually checked. Vector 7
        // lives at 0x1C.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: MOVEQ #1,D0      V clear
        //  6: TRAPV            NOT taken
        //  8: MOVEQ #5,D1      must run
        // 10: MOVEQ #2,D2 ; 12: MOVE D2,CCR   V set
        // 14: TRAPV           taken -> 0x40
        // 16: MOVEQ #0x7F,D3  must NOT run
        // 18: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'd1);
        prog[3]  = 16'h4E76;                // TRAPV, V clear
        prog[4]  = MOVEQ(1, 8'd5);
        prog[5]  = MOVEQ(2, 8'd2);
        prog[6]  = 16'h44C2;                // MOVE D2,CCR -> V
        prog[7]  = 16'h4E76;                // TRAPV, V set
        prog[8]  = MOVEQ(3, 8'h7F);         // must not run
        prog[9]  = 16'h60FE;
        prog[14] = 16'h0000; prog[15] = 16'h0040;  // vector 7 at 0x1C
        prog[32] = MOVEQ(4, 8'd6);          // handler at 0x40
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("TRAPV not taken on V=0", dut.u_core.u_rf.regs[1],  32'd5);
        chk("TRAPV taken on V=1",     dut.u_core.u_rf.regs[4],  32'd6);
        chk("TRAPV skipped inline",   dut.u_core.u_rf.regs[3],  32'd0);
        chk("TRAPV pushed frame",     dut.u_core.u_rf.regs[15], 32'h0000_0058);

        // ── Divide by zero: vector 5, from an instruction that is not a trap ─
        // The divider reports its zero divisor when it FINISHES, so this also
        // checks the exception waits for the handshake the result does.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: MOVEQ #10,D0 ; 6: MOVEQ #0,D1
        //  8: DIVU.W D1,D0     -> vector 5 at 0x14 -> 0x40
        // 10: MOVEQ #0x7F,D2   must NOT run
        // 12: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'd10);
        prog[3]  = MOVEQ(1, 8'd0);
        prog[4]  = 16'h80C1;                // DIVU.W D1,D0
        prog[5]  = MOVEQ(2, 8'h7F);         // must not run
        prog[6]  = 16'h60FE;
        prog[10] = 16'h0000; prog[11] = 16'h0040;  // vector 5 at 0x14
        prog[32] = MOVEQ(3, 8'd4);          // handler at 0x40
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (400) @(negedge clk_4x);

        chk("DIV0 entered handler", dut.u_core.u_rf.regs[3],  32'd4);
        chk("DIV0 skipped inline",  dut.u_core.u_rf.regs[2],  32'd0);
        chk("DIV0 left D0 alone",   dut.u_core.u_rf.regs[0],  32'd10);
        chk("DIV0 pushed frame",    dut.u_core.u_rf.regs[15], 32'h0000_0058);
        chk("DIV0 frame vector",    {16'h0, prog[32'h5E >> 1]}, 32'h0000_0014);

        // ── Interrupts ───────────────────────────────────────────────────────
        // Autovectored: level n takes vector 24+n, so level 5 is vector 29 at
        // 0x74. The mask starts at 7 out of reset, so the program lowers it
        // first -- and that is also what makes the level-7 case below a real
        // test rather than a repeat of this one.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: MOVEQ #0,D6 ; 6: MOVE D6,SR      mask = 0, S = 0
        //  8: NOP                              the interruptible instruction
        // 10: BRA -4 (back to the NOP)         a branch is NOT interruptible,
        //                                      so the interrupt can only land
        //                                      on byte 8 -- which is what makes
        //                                      the return-PC check exact
        // 0x50: handler: MOVEQ #9,D3 ; park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h60);
        prog[1] = 16'h2E47;
        prog[2] = MOVEQ(6, 8'd0);
        prog[3] = 16'h46C6;                 // MOVE D6,SR -> mask 0
        prog[4] = 16'h4E71;                 // NOP at byte 8
        prog[5] = 16'h60FC;                 // BRA -4 -> back to byte 8
        prog[40] = MOVEQ(3, 8'd9);          // handler at 0x50
        prog[41] = 16'h60FE;
        prog[32'h74 >> 1]       = 16'h0000; // vector 29 (level 5) at 0x74
        prog[(32'h74 >> 1) + 1] = 16'h0050;

        ipl   = 3'b000;
        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        // Let the program lower the mask and reach its spin loop first,
        // otherwise the interrupt races the MOVE to SR that permits it.
        repeat (60) @(negedge clk_4x);
        ipl = 3'b101;                        // level 5
        repeat (40) @(negedge clk_4x);
        ipl = 3'b000;                        // the handler has taken it
        repeat (200) @(negedge clk_4x);

        chk("INT entered handler", dut.u_core.u_rf.regs[3],  32'd9);
        chk("INT pushed frame",    dut.u_core.u_rf.regs[15], 32'h0000_0058);
        // The frame's return PC is the INTERRUPTED instruction, not the one
        // after it: nothing of it ran, so an RTE has to re-execute it.
        chk("INT frame return PC", rd32(32'h5A), 32'h0000_0008);
        chk("INT raised the mask", {29'h0, dut.u_core.sr_sys_r[2:0]}, 32'd5);

        // ── Level 7 with the mask already at 7 ───────────────────────────────
        // A plain level>mask comparison can NEVER fire here, since 7 > 7 is
        // false and 7 is the reset mask. rtl/ shipped that bug for 278 phases.
        // This program deliberately does NOT lower the mask.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: NOP ; 6: BRA -4
        // 0x50: handler: MOVEQ #8,D4 ; park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h60);
        prog[1] = 16'h2E47;
        prog[2] = 16'h4E71;                 // NOP at byte 4
        prog[3] = 16'h60FC;                 // BRA -4 -> back to byte 4
        prog[40] = MOVEQ(4, 8'd8);          // handler at 0x50
        prog[41] = 16'h60FE;
        prog[32'h7C >> 1]       = 16'h0000; // vector 31 (level 7) at 0x7C
        prog[(32'h7C >> 1) + 1] = 16'h0050;

        ipl   = 3'b000;
        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (60) @(negedge clk_4x);
        ipl = 3'b111;                        // level 7, mask still 7
        repeat (40) @(negedge clk_4x);
        ipl = 3'b000;
        repeat (200) @(negedge clk_4x);

        chk("NMI at mask 7",       dut.u_core.u_rf.regs[4],  32'd8);
        chk("NMI pushed frame",    dut.u_core.u_rf.regs[15], 32'h0000_0058);

        // ── Interrupt with no request: nothing happens ───────────────────────
        // The mask is lowered to 0 and IPL held at 0 for the whole run, so a
        // recognition condition that is merely "not equal" rather than
        // "greater than" would fire here and be caught.
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = MOVEQ(7, 8'h60);
        prog[1] = 16'h2E47;
        prog[2] = MOVEQ(6, 8'd0);
        prog[3] = 16'h46C6;                 // MOVE D6,SR -> mask 0
        prog[4] = MOVEQ(5, 8'd6);
        prog[5] = 16'h60FE;
        prog[40] = MOVEQ(4, 8'h7F);         // any handler: must NOT run
        prog[41] = 16'h60FE;
        for (i = 24; i < 32; i++) begin
            prog[(i * 4) >> 1]       = 16'h0000;
            prog[((i * 4) >> 1) + 1] = 16'h0050;
        end

        ipl   = 3'b000;
        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("no spurious INT",  dut.u_core.u_rf.regs[4],  32'd0);
        chk("program ran",      dut.u_core.u_rf.regs[5],  32'd6);
        chk("SP untouched",     dut.u_core.u_rf.regs[15], 32'h0000_0060);

        // ── CHK: not taken, taken above, taken below ─────────────────────────
        // All three outcomes, because CHK traps on TWO independent conditions
        // and leaves defined flags in every case. Vector 6 lives at 0x18.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: MOVEQ #5,D0 ; 6: MOVEQ #10,D1
        //  8: CHK.L D1,D0      5 <= 10, no trap
        // 10: MOVEQ #3,D2      must run
        // 12: MOVEQ #20,D3
        // 14: CHK.L D1,D3      20 > 10 -> trap
        // 16: MOVEQ #0x7F,D4   must NOT run
        // 18: park
        // 0x40: handler: MOVEQ #7,D5 ; park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'd5);
        prog[3]  = MOVEQ(1, 8'd10);
        prog[4]  = 16'h4181;                // CHK.L D1,D0
        prog[5]  = MOVEQ(2, 8'd3);
        prog[6]  = MOVEQ(3, 8'd20);
        prog[7]  = 16'h4781;                // CHK.L D1,D3
        prog[8]  = MOVEQ(4, 8'h7F);         // must not run
        prog[9]  = 16'h60FE;
        prog[12] = 16'h0000; prog[13] = 16'h0040;  // vector 6 at 0x18
        prog[32] = MOVEQ(5, 8'd7);          // handler at 0x40
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("CHK in bounds passed", dut.u_core.u_rf.regs[2], 32'd3);
        chk("CHK above bound trap", dut.u_core.u_rf.regs[5], 32'd7);
        chk("CHK skipped inline",   dut.u_core.u_rf.regs[4], 32'd0);
        chk("CHK frame vector",     {16'h0, prog[32'h5E >> 1]}, 32'h0000_0018);

        // Below-bound is the other trap condition and a DIFFERENT comparison:
        // a negative value fails however small the bound is.
        //  4: MOVEQ #-1,D0 ; 6: MOVEQ #10,D1 ; 8: CHK.W D1,D0 -> trap
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'hFF);         // D0 = -1
        prog[3]  = MOVEQ(1, 8'd10);
        prog[4]  = 16'h4181;                // CHK.W D1,D0
        prog[5]  = MOVEQ(4, 8'h7F);         // must not run
        prog[6]  = 16'h60FE;
        prog[12] = 16'h0000; prog[13] = 16'h0040;
        // MOVEA, not MOVEQ: the marker must not set the CCR itself, or it
        // erases the N the trap just recorded.
        prog[32] = 16'h2C40;                // MOVEA.L D0,A6 -> A6 = -1
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("CHK below zero trap", dut.u_core.u_rf.regs[14], 32'hFFFF_FFFF);
        chk("CHK below skipped",   dut.u_core.u_rf.regs[4], 32'd0);
        // N is the below-bound result when CHK traps.
        chk("CHK set N on below",  {28'h0, ccr_out[3]}, 32'h0000_0001);

        // ── TRAPcc and Line-A ────────────────────────────────────────────────
        // TRAPcc shares vector 7 with TRAPV (Table 8-1); Line-A is the
        // Line-1010 emulator at vector 10 (0x28), and it stacks the address of
        // the UNIMPLEMENTED instruction so a handler could decode it.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: TRAPF            condition false -> NOT taken (0x51FC)
        //  6: MOVEQ #2,D1      must run
        //  8: 0xA123           Line-A -> vector 10 -> 0x40
        // 10: MOVEQ #0x7F,D2   must NOT run
        // 12: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = 16'h51FC;                // TRAPF -- never taken
        prog[3]  = MOVEQ(1, 8'd2);
        prog[4]  = 16'hA123;                // Line-A
        prog[5]  = MOVEQ(2, 8'h7F);         // must not run
        prog[6]  = 16'h60FE;
        prog[20] = 16'h0000; prog[21] = 16'h0040;  // vector 10 at 0x28
        prog[32] = MOVEQ(3, 8'd5);          // handler at 0x40
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("TRAPF not taken",   dut.u_core.u_rf.regs[1], 32'd2);
        chk("Line-A trapped",    dut.u_core.u_rf.regs[3], 32'd5);
        chk("Line-A skipped",    dut.u_core.u_rf.regs[2], 32'd0);
        // The stacked PC is the A-line opcode's own address, byte 8.
        chk("Line-A stacked PC", rd32(32'h5A), 32'h0000_0008);

        // TRAPcc with a TRUE condition must actually fire.
        //  4: MOVEQ #2,D6 ; 6: MOVE D6,CCR   V set
        //  8: TRAPVS         V set -> taken (0x59FC, cc = VS)
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(6, 8'd2);
        prog[3]  = 16'h44C6;                // MOVE D6,CCR -> V
        prog[4]  = 16'h59FC;                // TRAPVS
        prog[5]  = MOVEQ(2, 8'h7F);         // must not run
        prog[6]  = 16'h60FE;
        prog[14] = 16'h0000; prog[15] = 16'h0040;  // vector 7 at 0x1C
        prog[32] = MOVEQ(4, 8'd6);
        prog[33] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("TRAPcc taken on VS", dut.u_core.u_rf.regs[4], 32'd6);
        chk("TRAPcc skipped",     dut.u_core.u_rf.regs[2], 32'd0);

        // ── TAS: read-modify-write on a byte, flags from the ORIGINAL ────────
        // Two runs: one where the byte starts clear (Z set, bit 7 set by us)
        // and one where it starts with bit 7 already set (N set).
        //  0: MOVEQ #0x30,D7 ; 2: MOVEA.L D7,A7 -- A7 unused, just a base
        //  4: MOVEQ #0x40,D0 ; 6: MOVEA.L D0,A1   A1 = 0x40
        //  8: TAS (A1)        0x4AD1
        // 10: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h30);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'h40);
        prog[3]  = 16'h2240;                // MOVEA.L D0,A1
        prog[4]  = 16'h4AD1;                // TAS (A1)
        prog[5]  = 16'h60FE;
        prog[32] = 16'h0000;                // the byte at 0x40 starts at 0

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("TAS set bit 7",   {24'h0, prog[32][15:8]}, 32'h0000_0080);
        chk("TAS Z on zero",   {28'h0, ccr_out[2]},     32'h0000_0001);
        chk("TAS N clear",     {28'h0, ccr_out[3]},     32'h0000_0000);

        // Same again with bit 7 already set: N set, Z clear, byte unchanged.
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h30);
        prog[1]  = 16'h2E47;
        prog[2]  = MOVEQ(0, 8'h40);
        prog[3]  = 16'h2240;
        prog[4]  = 16'h4AD1;                // TAS (A1)
        prog[5]  = 16'h60FE;
        prog[32] = 16'h8500;                // byte at 0x40 = 0x85

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("TAS keeps its bits", {24'h0, prog[32][15:8]}, 32'h0000_0085);
        chk("TAS N on negative",  {28'h0, ccr_out[3]},     32'h0000_0001);
        chk("TAS Z clear",        {28'h0, ccr_out[2]},     32'h0000_0000);

        // ── RMW flags on a shared bus ────────────────────────────────────────
        // The flags of a read-modify-write come from the value it READ, and are
        // latched when it leaves EX -- after its write has acked. On a bus
        // shared with instruction fetch, an unrelated fetch lands between those
        // two acks, so this only fails when the arbiter is in the picture: the
        // core-level testbench has no second requester and cannot see it.
        //  0: MOVEQ #0x40,D0 ; 2: MOVEA.L D0,A1   A1 = 0x40
        //  4: MOVEQ #0,D1
        //  6: ADD.L D1,(A1)     0x7FFFFFFF + 1 -> 0x80000000, N set. The
        //                       operand must CHANGE, or a clobbered read and a
        //                       correct one store the same thing.
        //  8: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(0, 8'h40);
        prog[1]  = 16'h2240;                // MOVEA.L D0,A1
        prog[2]  = MOVEQ(1, 8'd1);
        prog[3]  = 16'hD391;                // ADD.L D1,(A1)
        prog[4]  = 16'h60FE;
        prog[32] = 16'h7FFF; prog[33] = 16'hFFFF;   // 0x40 = 0x7FFFFFFF

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("RMW stored result", rd32(32'h40),        32'h8000_0000);
        // N from the result, V from the signed overflow: 0x7FFFFFFF + 1.
        chk("RMW flags N",  {28'h0, ccr_out[3]}, 32'h0000_0001);
        chk("RMW flags V",  {28'h0, ccr_out[1]}, 32'h0000_0001);

        // ── Bit fields, register-direct ──────────────────────────────────────
        // Offsets are counted from the MSB, which is the part that is easy to
        // get backwards, so every check below names the bits it expects.
        // D0 = 0xF0F0F0F0, so bits 8..15 from the MSB are 0xF0 -- a field whose
        // own top bit is set, which is what separates EXTU from EXTS.
        //  0: MOVE.L #0xF0F0F0F0,D0
        //  6: BFEXTU D0{8:8},D1      -> 0x000000F0
        // 10: BFEXTS D0{8:8},D2      -> 0xFFFFFFF0
        // 14: BFFFO  D0{0:32},D5     -> 0 (bit 0 from the MSB is already set)
        // 18: MOVEQ #0x0F,D3 ; 20: MOVEQ #0,D4
        // 22: BFINS  D3,D4{8:8}      -> 0x000F0000
        // 26: BFCLR  D0{0:4}         -> 0x00F0F0F0, and N set from the field
        // 30: park
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = 16'h203C; prog[1] = 16'hF0F0; prog[2] = 16'hF0F0;
        prog[3]  = 16'hE9C0; prog[4] = 16'h1208;   // BFEXTU D0{8:8},D1
        prog[5]  = 16'hEBC0; prog[6] = 16'h2208;   // BFEXTS D0{8:8},D2
        prog[7]  = 16'hEDC0; prog[8] = 16'h5000;   // BFFFO  D0{0:32},D5
        prog[9]  = MOVEQ(3, 8'h0F);
        prog[10] = MOVEQ(4, 8'd0);
        prog[11] = 16'hEFC4; prog[12] = 16'h3208;  // BFINS D3,D4{8:8}
        prog[13] = 16'hECC0; prog[14] = 16'h0004;  // BFCLR D0{0:4}
        prog[15] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (350) @(negedge clk_4x);

        chk("BFEXTU zero-extends", dut.u_core.u_rf.regs[1], 32'h0000_00F0);
        chk("BFEXTS sign-extends", dut.u_core.u_rf.regs[2], 32'hFFFF_FFF0);
        chk("BFFFO finds bit 0",   dut.u_core.u_rf.regs[5], 32'd0);
        chk("BFINS places field",  dut.u_core.u_rf.regs[4], 32'h000F_0000);
        chk("BFCLR clears field",  dut.u_core.u_rf.regs[0], 32'h00F0_F0F0);
        // BFCLR ran last; its field was 0xF (width 4), whose top bit is set.
        chk("BF flags N from field", {28'h0, ccr_out[3]}, 32'h0000_0001);
        chk("BF flags Z clear",      {28'h0, ccr_out[2]}, 32'h0000_0000);

        // BFTST writes no register at all, only flags -- and a zero field must
        // set Z. Bits 8..12 of 0x00F0F0F0 are 0, so this is the zero case.
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0] = 16'h203C; prog[1] = 16'h00F0; prog[2] = 16'hF0F0;
        prog[3] = 16'hE8C0; prog[4] = 16'h0104;    // BFTST D0{4:4}
        prog[5] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("BFTST left D0",   dut.u_core.u_rf.regs[0], 32'h00F0_F0F0);
        chk("BFTST Z on zero", {28'h0, ccr_out[2]},     32'h0000_0001);

        // ── MOVEC and a movable vector base ──────────────────────────────────
        // The vector base was hardcoded to 0, so every handler had to live in
        // the bottom 1KB. This moves VBR to 0x100 and takes a TRAP through it:
        // vector 32 is then read from 0x180, and the old location is left
        // holding a DIFFERENT address so a stale base would jump somewhere
        // visibly wrong rather than somewhere that happens to work.
        //  0: MOVEQ #0x60,D7 ; 2: MOVEA.L D7,A7
        //  4: MOVE.L #0x100,D0
        // 10: MOVEC D0,VBR          0x4E7B 0x0801
        // 14: MOVEC VBR,D1          0x4E7A 0x1801   -> D1 = 0x100
        // 18: MOVEQ #0x2A,D2 ; 20: MOVEC D2,CACR    0x4E7B 0x2002
        // 24: MOVEC CACR,D3         0x4E7A 0x3002   -> D3 = 0x2A
        // 28: TRAP #0               -> vector 32 at VBR+0x80 = 0x180
        // 30: MOVEQ #0x7F,D4        must NOT run
        // 32: park
        // 0x60 is the stack, so the handler goes at 0x90.
        for (i = 0; i < 1024; i++) prog[i] = 16'h4E71;
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;
        prog[2]  = 16'h203C; prog[3] = 16'h0000; prog[4] = 16'h0100;
        prog[5]  = 16'h4E7B; prog[6]  = 16'h0801;   // MOVEC D0,VBR
        prog[7]  = 16'h4E7A; prog[8]  = 16'h1801;   // MOVEC VBR,D1
        prog[9]  = MOVEQ(2, 8'h2A);
        prog[10] = 16'h4E7B; prog[11] = 16'h2002;   // MOVEC D2,CACR
        prog[12] = 16'h4E7A; prog[13] = 16'h3002;   // MOVEC CACR,D3
        prog[14] = 16'h4E40;                        // TRAP #0
        prog[15] = MOVEQ(4, 8'h7F);                 // must not run
        prog[16] = 16'h60FE;
        prog[72] = MOVEQ(5, 8'd9);                  // handler at 0x90
        prog[73] = 16'h60FE;
        // Vector 32 through the MOVED base, at 0x180.
        prog[32'h180 >> 1]       = 16'h0000;
        prog[(32'h180 >> 1) + 1] = 16'h0090;
        // The OLD location holds a decoy: if VBR were still 0 the handler would
        // be entered at 0xB0 and D6, not D5, would be set.
        prog[32'h80 >> 1]        = 16'h0000;
        prog[(32'h80 >> 1) + 1]  = 16'h00B0;
        prog[88] = MOVEQ(6, 8'd9);                  // decoy handler at 0xB0
        prog[89] = 16'h60FE;

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (450) @(negedge clk_4x);

        chk("MOVEC read back VBR",  dut.u_core.u_rf.regs[1], 32'h0000_0100);
        chk("MOVEC read back CACR", dut.u_core.u_rf.regs[3], 32'h0000_002A);
        chk("VBR moved the vector", dut.u_core.u_rf.regs[5], 32'd9);
        chk("old base NOT used",    dut.u_core.u_rf.regs[6], 32'd0);
        chk("TRAP skipped inline",  dut.u_core.u_rf.regs[4], 32'd0);

        $display("");
        if (fails == 0) begin
            $display("=== 0 failure(s) ===");
            $display("ALL TESTS PASSED");
        end else $display("=== %0d failure(s) ===", fails);
        $finish;
    end

endmodule

`default_nettype wire

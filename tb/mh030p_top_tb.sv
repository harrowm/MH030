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

    wire        if_req, mem_req, mem_rw;
    wire [31:0] if_addr, mem_addr, mem_wdata;
    wire [1:0]  mem_siz;
    wire        wb_wr_en;
    wire [3:0]  wb_wr_sel;
    wire [31:0] wb_wr_data;
    wire [7:0]  ccr_out;

    logic [31:0] if_rdata = 32'h0, mem_rdata = 32'h0;
    logic        if_ack   = 1'b0,  mem_ack   = 1'b0;

    // One memory, two ports. Word-addressed program image in prog[].
    logic [15:0] prog [0:255];
    logic [31:0] ram  [0:255];

    // Instruction port: one-cycle latency, returns the longword at if_addr.
    always_ff @(posedge clk_4x) begin
        if_ack <= 1'b0;
        if (if_req && !if_ack) begin
            if_ack   <= 1'b1;
            if_rdata <= {prog[if_addr[9:1]], prog[if_addr[9:1] + 1]};
        end
    end

    // Data port: one-cycle latency.
    always_ff @(posedge clk_4x) begin
        mem_ack <= 1'b0;
        if (mem_req && !mem_ack) begin
            mem_ack <= 1'b1;
            if (mem_rw) mem_rdata           <= ram[mem_addr[9:2]];
            else        ram[mem_addr[9:2]]  <= mem_wdata;
        end
    end

    mh030p_top dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .if_req(if_req), .if_addr(if_addr),
        .if_rdata(if_rdata), .if_ack(if_ack),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack),
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
        for (i = 0; i < 256; i++) begin prog[i] = 16'h4E71; ram[i] = 32'h0; end

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
        for (i = 0; i < 256; i++) begin prog[i] = 16'h4E71; ram[i] = 32'h0; end
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
        for (i = 0; i < 256; i++) begin prog[i] = 16'h4E71; ram[i] = 32'h0; end
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
        for (i = 0; i < 256; i++) begin prog[i] = 16'h4E71; ram[i] = 32'h0; end
        prog[0]  = MOVEQ(7, 8'h60);
        prog[1]  = 16'h2E47;                // MOVEA.L D7,A7
        prog[2]  = 16'h4E40;                // TRAP #0
        prog[3]  = MOVEQ(0, 8'h7F);         // skipped if the trap is taken
        prog[24] = MOVEQ(3, 8'd9);          // handler at byte 0x30
        prog[25] = 16'h60FE;                // park
        ram[32'h80 >> 2] = 32'h0000_0030;   // vector 32 -> handler address

        rst_n = 1'b0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (250) @(negedge clk_4x);

        chk("TRAP entered handler", dut.u_core.u_rf.regs[3], 32'd9);
        chk("TRAP skipped inline",  dut.u_core.u_rf.regs[0], 32'd0);
        chk("TRAP pushed frame",    dut.u_core.u_rf.regs[15], 32'h0000_0058);
        chk("frame holds PC",       ram[32'h5C >> 2], 32'h0000_0006);

        $display("");
        if (fails == 0) begin
            $display("=== 0 failure(s) ===");
            $display("ALL TESTS PASSED");
        end else $display("=== %0d failure(s) ===", fails);
        $finish;
    end

endmodule

`default_nettype wire

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
    logic [15:0] q3    = 16'h0;
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
    logic [31:0] mem_rdata = 32'h0;
    logic        mem_ack   = 1'b0;
    logic [31:0] ram [0:1023];

    always_ff @(posedge clk_4x) begin
        mem_ack <= 1'b0;
        if (mem_req && !mem_ack) begin
            mem_ack   <= 1'b1;
            mem_rdata <= ram[mem_addr[11:2]];
        end
    end

    mh030p_core dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr(instr), .ext(ext), .q3(q3),
        .instr_valid(instr_valid), .instr_ready(instr_ready),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out)
    );

    int fails = 0;


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

        bubble(8);                     // let the pipeline drain

        chk("D4 = (A3)",       dut.u_rf.regs[4],  32'hDEAD_0001);
        chk("D5 = 16+(A3)",    dut.u_rf.regs[5],  32'hDEAD_0011);
        chk("D6 = (A3)+",      dut.u_rf.regs[6],  32'hDEAD_0001);
        chk("A3 post-inc",     dut.u_rf.regs[11], 32'h0000_0044);

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

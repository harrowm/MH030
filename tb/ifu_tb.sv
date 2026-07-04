`default_nettype none
`timescale 1ps/1ps

// Phase 30: m68030_ifu prefetch queue test.
//
// BIU stub responds after BIU_LAT cycles.  Cancels in-flight requests when
// ifu_req goes low (e.g. after pc_wr_en flush) so stale acks never corrupt
// a freshly-started queue.
//
// Tests:
//   IFU-1:  Queue fills on first pc_wr_en; instr_valid / ext_valid flags
//   IFU-2:  instr_word = rdata[31:16] of first fetch (correct opcode)
//   IFU-3:  ext_data = {q[1],q[2]} (two extension words, MSW-first layout)
//   IFU-4:  drain=1: queue shifts, decode_pc advances by 2
//   IFU-5:  drain=3: decode_pc advances by 6, queue empties
//   IFU-6:  Auto-refetch after queue drains to ≤ 2 words
//   IFU-7:  pc_wr_en flushes queue; instr_valid=0 then refills
//   IFU-8:  Non-long-aligned PC (pc[1]=1) → skip_first discards rdata[31:16]
//   IFU-9:  Bus error: bus_err asserted, fetching stops
//   IFU-10: addr_err when decode_pc is odd
//   IFU-11: fc_out: 3'b110 in supervisor mode, 3'b010 in user mode

module ifu_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // -----------------------------------------------------------------------
    // DUT interface
    // -----------------------------------------------------------------------
    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 0;
    logic [1:0]  drain      = 0;

    logic [15:0] instr_word;
    logic [31:0] ext_data;
    logic        instr_valid;
    logic        ext_valid;
    logic [31:0] decode_pc;

    logic [31:0] ifu_addr;
    logic        ifu_req;
    logic [31:0] ifu_rdata;
    logic        ifu_ack;
    logic        ifu_berr;

    logic        supervisor = 1;
    logic [2:0]  fc_out;
    logic        bus_err;
    logic [31:0] bus_err_addr;
    logic        addr_err;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    m68030_ifu u_ifu (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .pc_wr_en    (pc_wr_en),
        .pc_wr_data  (pc_wr_data),
        .drain       (drain),
        .instr_word  (instr_word),
        .ext_data    (ext_data),
        .instr_valid (instr_valid),
        .ext_valid   (ext_valid),
        .decode_pc   (decode_pc),
        .ifu_addr    (ifu_addr),
        .ifu_req     (ifu_req),
        .ifu_rdata   (ifu_rdata),
        .ifu_ack     (ifu_ack),
        .ifu_berr    (ifu_berr),
        .supervisor  (supervisor),
        .fc_out      (fc_out),
        .bus_err     (bus_err),
        .bus_err_addr(bus_err_addr),
        .addr_err    (addr_err)
    );

    // -----------------------------------------------------------------------
    // BIU stub
    //
    // Protocol:
    //   - On seeing ifu_req asserted (with req_lat_r=0), latch address and
    //     count down BIU_LAT cycles then assert ack/berr for one cycle.
    //   - If ifu_req deasserts while a fetch is in-flight (req_lat_r=1),
    //     CANCEL the request so stale acks never reach the IFU after a flush.
    // -----------------------------------------------------------------------
    localparam int BIU_LAT = 4;

    logic [31:0] stub_addr [0:7];
    logic [31:0] stub_data [0:7];
    logic        stub_berr [0:7];
    logic [2:0]  stub_cnt  = 0;

    task stub_clear;
        stub_cnt = 0;
    endtask

    task stub_add(input logic [31:0] addr, data, input logic is_berr);
        stub_addr[stub_cnt] = addr;
        stub_data[stub_cnt] = data;
        stub_berr[stub_cnt] = is_berr;
        stub_cnt = stub_cnt + 1;
    endtask

    // Stub state
    logic        req_pend  = 0;
    logic [31:0] req_addr  = 0;
    int          req_timer = 0;
    integer      si;
    logic        si_found;

    initial begin
        ifu_rdata = 32'h0;
        ifu_ack   = 1'b0;
        ifu_berr  = 1'b0;
    end

    always @(posedge clk_4x) begin
        ifu_ack  <= 1'b0;
        ifu_berr <= 1'b0;

        if (req_pend && !ifu_req) begin
            // IFU deasserted req (pc_wr_en flush or similar) — cancel
            req_pend <= 1'b0;

        end else if (!req_pend) begin
            if (ifu_req) begin
                req_pend  <= 1'b1;
                req_addr  <= ifu_addr;
                req_timer <= BIU_LAT - 1;
            end

        end else begin
            if (req_timer > 0) begin
                req_timer <= req_timer - 1;
            end else begin
                req_pend <= 1'b0;
                // Lookup in stub table
                si_found = 1'b0;
                for (si = 0; si < 8; si++) begin
                    if (!si_found && si < stub_cnt &&
                        stub_addr[si] == req_addr) begin
                        si_found = 1'b1;
                        if (stub_berr[si]) begin
                            ifu_berr <= 1'b1;
                        end else begin
                            ifu_rdata <= stub_data[si];
                            ifu_ack   <= 1'b1;
                        end
                    end
                end
                if (!si_found) ifu_berr <= 1'b1;  // unmapped address
            end
        end
    end

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    function int q_cnt_f; q_cnt_f = u_ifu.q_cnt; endfunction

    task wait_valid(input int min_cnt);
        integer tmout;
        tmout = 30;
        while (q_cnt_f() < min_cnt && tmout > 0) begin
            @(posedge clk_4x); #1;
            tmout = tmout - 1;
        end
    endtask

    task write_pc(input logic [31:0] addr);
        pc_wr_data = addr;
        pc_wr_en   = 1'b1;
        @(posedge clk_4x); #1;
        pc_wr_en   = 1'b0;
    endtask

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    task check16(input string name, input logic [15:0] got, exp);
        if (got === exp) $display("PASS  %s (got %04h)", name, got);
        else begin $display("FAIL  %s: got %04h exp %04h", name, got, exp); fail_count++; end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 30: m68030_ifu ===");

        @(posedge clk_4x); #1;
        rst_n = 1'b1;
        @(posedge clk_4x); #1;

        // Before first pc_wr_en: initialized_r=0, no fetch started
        check("init: ifu_req=0 before pc_wr_en", !ifu_req);
        check("init: instr_valid=0", !instr_valid);

        // ================================================================
        // IFU-1/2/3: Fill queue via pc_wr_en and two BIU fetches
        //   Fetch 1: addr=0x1000 → rdata = {0xABCD, 0x1234}  → q[0..1]
        //   Fetch 2: addr=0x1004 → rdata = {0x5678, 0x9ABC}  → q[2..3]
        // ================================================================
        stub_clear();
        stub_add(32'h0000_1000, 32'hABCD_1234, 1'b0);
        stub_add(32'h0000_1004, 32'h5678_9ABC, 1'b0);
        stub_add(32'h0000_1008, 32'h0001_0002, 1'b0);
        write_pc(32'h0000_1000);

        $display("--- IFU-1: pc_wr_en triggers fill ---");
        wait_valid(1);
        check("IFU-1: instr_valid after first fill", instr_valid);

        wait_valid(3);
        check("IFU-1: ext_valid when q_cnt>=3", ext_valid);

        $display("--- IFU-2: instr_word ---");
        check16("IFU-2: instr_word=0xABCD", instr_word, 16'hABCD);

        $display("--- IFU-3: ext_data layout ---");
        // q[0]=0xABCD q[1]=0x1234 q[2]=0x5678 q[3]=0x9ABC
        // ext_data = {q[1],q[2]} = 0x1234_5678
        check32("IFU-3: ext_data={q1,q2}=0x12345678", ext_data, 32'h1234_5678);
        check32("IFU-3: decode_pc=0x1000", decode_pc, 32'h0000_1000);

        // ================================================================
        // IFU-4: drain=1 → queue shifts by 1 word, decode_pc += 2
        // ================================================================
        $display("--- IFU-4: drain=1 ---");
        // State: q=[0xABCD, 0x1234, 0x5678, 0x9ABC], q_cnt=4
        drain = 2'd1;
        @(posedge clk_4x); #1;
        drain = 2'd0;
        // After drain: q=[0x1234, 0x5678, 0x9ABC, 0x0000], q_cnt=3
        check16("IFU-4: instr_word=0x1234", instr_word, 16'h1234);
        check32("IFU-4: decode_pc=0x1002", decode_pc, 32'h0000_1002);
        check32("IFU-4: ext_data={0x5678,0x9ABC}", ext_data, 32'h5678_9ABC);

        // ================================================================
        // IFU-5: drain=3 → decode_pc advances by 6, queue empties
        //   (q_cnt=3 after IFU-4; IFU won't pre-fetch until q_cnt drops ≤ 2)
        // ================================================================
        $display("--- IFU-5: drain=3 ---");
        drain = 2'd3;
        @(posedge clk_4x); #1;
        drain = 2'd0;
        // q[0] was q[3]=0x0000 (tail slot zeroed by drain-1 shift); q_cnt=0
        check32("IFU-5: decode_pc=0x1008 after drain=3", decode_pc, 32'h0000_1008);
        check("IFU-5: queue empty after drain=3", !instr_valid);

        // ================================================================
        // IFU-6: Auto-refetch after queue empties (q_cnt_d=0 ≤ 2)
        //   drain-only branch fires fetch for 0x1008 at next posedge.
        // ================================================================
        $display("--- IFU-6: auto-refetch ---");
        wait_valid(1);
        check("IFU-6: instr_valid after auto-refetch", instr_valid);
        // rdata for 0x1008 = 0x0001_0002 → q[0]=rdata[31:16]=0x0001
        check16("IFU-6: instr_word=0x0001 (from 0x1008)", instr_word, 16'h0001);

        // ================================================================
        // IFU-7: pc_wr_en flushes queue and restarts at new address
        // ================================================================
        $display("--- IFU-7: pc_wr_en flush ---");
        stub_clear();
        stub_add(32'h0000_2000, 32'h0640_0000, 1'b0);
        stub_add(32'h0000_2004, 32'h1234_5678, 1'b0);
        stub_add(32'h0000_2008, 32'hAAAA_BBBB, 1'b0);
        write_pc(32'h0000_2000);
        // Queue flushed at this posedge → instr_valid=0 now
        check("IFU-7: instr_valid=0 immediately after flush", !instr_valid);
        wait_valid(1);
        check("IFU-7: instr_valid after refill", instr_valid);
        check32("IFU-7: decode_pc=0x2000", decode_pc, 32'h0000_2000);
        check16("IFU-7: instr_word=0x0640", instr_word, 16'h0640);

        // ================================================================
        // IFU-8: Non-long-aligned PC (pc[1]=1) → skip_first
        //   PC=0x2002: fetch from 0x2000 (aligned), discard rdata[31:16],
        //   use rdata[15:0] = word@0x2002 as q[0].
        // ================================================================
        $display("--- IFU-8: skip_first (PC word- not long-aligned) ---");
        stub_clear();
        stub_add(32'h0000_2000, 32'hDEAD_CAFE, 1'b0);  // [31:16]=junk, [15:0]=word@0x2002
        stub_add(32'h0000_2004, 32'h1111_2222, 1'b0);
        stub_add(32'h0000_2008, 32'h3333_4444, 1'b0);
        write_pc(32'h0000_2002);
        wait_valid(1);
        check16("IFU-8: instr_word=0xCAFE (skip_first)", instr_word, 16'hCAFE);
        check32("IFU-8: decode_pc=0x2002", decode_pc, 32'h0000_2002);

        // ================================================================
        // IFU-9: Bus error: bus_err asserted, fetching stops
        // ================================================================
        $display("--- IFU-9: bus error ---");
        stub_clear();
        stub_add(32'h0000_3000, 32'h0, 1'b1);   // berr=1
        write_pc(32'h0000_3000);
        repeat(BIU_LAT + 3) @(posedge clk_4x); #1;
        check("IFU-9: bus_err asserted", bus_err);
        check32("IFU-9: bus_err_addr=0x3000", bus_err_addr, 32'h0000_3000);
        check("IFU-9: ifu_req=0 after berr", !ifu_req);

        // ================================================================
        // IFU-10: addr_err when decode_pc is odd
        // ================================================================
        $display("--- IFU-10: addr_err ---");
        stub_clear();
        stub_add(32'h0000_4000, 32'h1234_5678, 1'b0);
        stub_add(32'h0000_4004, 32'hAAAA_BBBB, 1'b0);
        write_pc(32'h0000_4001);   // odd → addr_err=1
        @(posedge clk_4x); #1;
        check("IFU-10: addr_err=1 for odd PC", addr_err);
        write_pc(32'h0000_4000);   // even → addr_err=0
        @(posedge clk_4x); #1;
        check("IFU-10: addr_err=0 for even PC", !addr_err);

        // ================================================================
        // IFU-11: fc_out supervisor vs user
        // ================================================================
        $display("--- IFU-11: fc_out ---");
        check("IFU-11: fc=110 when supervisor=1", fc_out === 3'b110);
        supervisor = 1'b0;
        @(posedge clk_4x); #1;
        check("IFU-11: fc=010 when supervisor=0", fc_out === 3'b010);
        supervisor = 1'b1;

        // ================================================================
        // Done
        // ================================================================
        @(posedge clk_4x); #1;
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED");
        $finish;
    end

endmodule

`default_nettype wire

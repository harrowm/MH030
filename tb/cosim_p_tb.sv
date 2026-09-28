`default_nettype none
`timescale 1ps/1ps

// =============================================================================
// Opcode-group cosimulation for MH030-P (rtlp/) -- bus TRANSACTION ORDER.
//
// Usage: vvp sim/cosim_p +hexfile=tests/grpN.hex [+grp=name] [+expected_d0=HEX]
//
// Emits the same `BUS R|W addr data fc=b siz=b` log tb/cosim_grp_tb.sv does, so
// tools/buscmp.py compares either core against Musashi unchanged.
//
// WHY THIS IS NEEDED even though the full Harte corpus already passes: Harte
// compares architectural state at the end of one instruction and nothing else.
// It cannot see the ORDER of memory accesses, so a memory-to-memory move that
// writes before it reads, a MOVEM that walks its registers backwards, or PACK's
// two reversed byte accesses would all pass it. That order is what buscmp.py
// checks, and no part of it had ever been checked against this core.
//
// TWO THINGS THIS CORE DOES NOT HAVE, and how they are supplied here:
//
//   * No function-code output. rtlp/ has no FC pins at all -- the bus is
//     abstract. FC is synthesised from the two facts that determine it:
//     program-vs-data comes from which requester the arbiter granted (its own
//     `owner`), and supervisor-vs-user from the core's sr_sys_r. That is the
//     definition of FC for the four spaces this core can generate, not a guess.
//
//   * A deeper prefetch queue than rtl/ and no instruction cache, so it runs
//     further ahead. buscmp.py's --allow-fetch-interleave exists for exactly
//     this and is applied per target, never blanket -- both streams must still
//     match exactly and in order.
// =============================================================================

module cosim_p_tb;

    logic clk_4x = 1'b0;
    always #5 clk_4x = ~clk_4x;
    logic rst_n = 1'b0;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    string hexfile;
    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        if (!$value$plusargs("hexfile=%s", hexfile))
            hexfile = "tests/smoke.hex";
        $readmemh(hexfile, rom);
    end

    wire        bus_req, bus_rw;
    wire [31:0] bus_addr, bus_wdata;
    wire [1:0]  bus_siz;
    wire        stopped;
    wire        wb_wr_en;
    wire [3:0]  wb_wr_sel;
    wire [31:0] wb_wr_data;
    wire [7:0]  ccr_out;
    logic [31:0] bus_rdata = 32'h0;
    logic        bus_ack   = 1'b0;

    mh030p_top dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .bus_req(bus_req), .bus_addr(bus_addr), .bus_rw(bus_rw),
        .bus_siz(bus_siz), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack),
        .ipl(3'b000), .stopped(stopped),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out)
    );

    // ── Byte-granular access over the word array ──────────────────────────────
    // Index with a[13:2], i.e. ALIAS rather than range-check, exactly as
    // tb/cosim_grp_tb.sv does. A range check returning a poison value instead
    // sends the core off through garbage the moment a test touches an address
    // above 16K -- which most of these do -- and the whole comparison becomes
    // a report about the testbench. Aliasing is harmless here because what is
    // being compared is the sequence of bus transactions, not memory contents.
    function automatic logic [7:0] rdb(input logic [23:0] a);
        logic [31:0] w;
        w = rom[a[13:2]];
        case (a[1:0])
            2'b00:   rdb = w[31:24];
            2'b01:   rdb = w[23:16];
            2'b10:   rdb = w[15:8];
            default: rdb = w[7:0];
        endcase
    endfunction

    function automatic logic [31:0] setb(input logic [31:0] w,
                                        input logic [1:0]  sel,
                                        input logic [7:0]  v);
        setb = w;
        case (sel)
            2'b00:   setb[31:24] = v;
            2'b01:   setb[23:16] = v;
            2'b10:   setb[15:8]  = v;
            default: setb[7:0]   = v;
        endcase
    endfunction

    function automatic int nbytes(input logic [1:0] siz);
        nbytes = (siz == 2'b01) ? 1 : (siz == 2'b10) ? 2 : 4;
    endfunction

    // ── Bus model: one-cycle ack, right-justified data both ways ──────────────
    // The log line is emitted here, at the ack, which is the one unambiguous
    // moment a transaction happened -- there is no DS edge to watch on this bus.
    // The value logged is TOP-justified to match rtl/'s pin-level log: a byte
    // read of 0x12 at an even address logs 12000000 there, and buscmp.py
    // compares against that.
    logic [31:0] nw0, nw1;
    logic [23:0] ba;
    logic [31:0] acc;
    int k, nb;

    // Supervisor-vs-user and program-vs-data: the two bits FC is made of.
    wire sup    = dut.u_core.sr_sys_r[5];
    wire is_ifu = (dut.u_arb.owner == 2'd2);
    wire [2:0] bus_fc = is_ifu ? (sup ? 3'b110 : 3'b010)
                               : (sup ? 3'b101 : 3'b001);

    always_ff @(posedge clk_4x) begin
        bus_ack <= 1'b0;
        if (bus_req && !bus_ack) begin
            bus_ack <= 1'b1;
            ba = bus_addr[23:0];
            nb = nbytes(bus_siz);
            if (bus_rw) begin
                acc = 32'h0;
                for (k = 0; k < nb; k++)
                    acc = (acc << 8) | {24'h0, rdb(ba + k[23:0])};
                bus_rdata <= acc;
                $display("BUS R %h %h fc=%b siz=%b", {8'h0, ba},
                         acc << (8 * (4 - nb)), bus_fc, bus_siz);
            end else begin
                nw0 = rom[ba[13:2]];
                nw1 = rom[(ba[13:2] + 12'd1) & 12'hFFF];
                for (k = 0; k < nb; k++) begin
                    logic [23:0] a;
                    logic [7:0]  v;
                    a = ba + k[23:0];
                    v = bus_wdata[8*(nb - 1 - k) +: 8];
                    if (a[13:2] == ba[13:2]) nw0 = setb(nw0, a[1:0], v);
                    else                     nw1 = setb(nw1, a[1:0], v);
                end
                rom[ba[13:2]]                    <= nw0;
                rom[(ba[13:2] + 12'd1) & 12'hFFF] <= nw1;
                $display("BUS W %h %h fc=%b siz=%b", {8'h0, ba},
                         bus_wdata << (8 * (4 - nb)), bus_fc, bus_siz);
            end
        end
    end

    // ── Cycle accounting ──────────────────────────────────────────────────────
    // Detects the SAME event tb/cosim_grp_tb.sv does -- the STOP opcode
    // appearing in a program-space read -- so cycles-to-here is a like-for-like
    // throughput comparison between the two cores. Comparing each core's own
    // "stopped executing" point would not be: this core's `stopped` is an
    // execution event while rtl/ watches the fetch.
    longint unsigned cyc = 0;
    longint unsigned stop_cyc = 0;
    logic stop_fetched = 1'b0;
    always_ff @(posedge clk_4x) if (rst_n) cyc <= cyc + 1;
    always_ff @(posedge clk_4x) begin
        if (bus_req && !bus_ack && bus_rw && is_ifu) begin
            if ((rdb(bus_addr[23:0]) == 8'h4E && rdb(bus_addr[23:0] + 24'd1) == 8'h72)
             || (rdb(bus_addr[23:0] + 24'd2) == 8'h4E
                 && rdb(bus_addr[23:0] + 24'd3) == 8'h72)) begin
                if (!stop_fetched) stop_cyc <= cyc;
                stop_fetched <= 1'b1;
            end
        end
    end

    // ── Run control ───────────────────────────────────────────────────────────
    int  fail_count = 0;
    task automatic check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    initial begin
        string grpname;
        longint unsigned exp_d0;
        bit check_d0;
        integer cycles;

        rst_n = 1'b0;
        repeat (20) @(posedge clk_4x);
        #1 rst_n = 1'b1;

        if (!$value$plusargs("grp=%s", grpname)) grpname = "grp?";
        if (!$value$plusargs("cycles=%d", cycles)) cycles = 8000;
        check_d0 = $value$plusargs("expected_d0=%h", exp_d0);

        fork
            begin : blk_timeout
                repeat (cycles) @(posedge clk_4x);
                disable blk_stop;
            end
            begin : blk_stop
                wait (stopped == 1'b1);
                repeat (20) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        $display("CYCLES %0d", stop_cyc);
        check({grpname, " STOP reached"}, stopped);
        if (check_d0)
            check({grpname, " D0 correct"},
                  dut.u_core.u_rf.regs[0] == exp_d0[31:0]);

        if (fail_count == 0) $display("PASS  cosim_p_%s", grpname);
        else                 $display("FAIL  cosim_p_%s (%0d)", grpname, fail_count);
        $finish;
    end

endmodule

`default_nettype wire

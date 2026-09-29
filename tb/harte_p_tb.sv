`default_nettype none
`timescale 1ps/1ps

// =============================================================================
// Tom Harte SingleStepTests against MH030-P (rtlp/), the pipelined core.
//
// Usage: vvp sim/harte_p +hexfile=<path> [+cycles=<N>]
//
// Emits the SAME contract tb/harte_tb.sv does, so scripts/run_harte.py drives
// either core unchanged:
//   REGSTATE D0=.. .. A7=.. SR=.. PC=..
//   MEMWRITE <24-bit-addr> <byte-val>        one line per byte written
//
// The runner compares D0-D7, A0-A7, the CCR's X N Z V C, and changed memory
// bytes. It does NOT compare PC, so the PC field is reported for diagnostics
// only -- which is fortunate, because "the PC" of a pipelined core at the
// moment it stops is not a single well-defined register.
//
// WHY THIS IS A SEPARATE FILE from harte_tb.sv rather than a parameter: the two
// cores present completely different external interfaces. rtl/ drives real
// 68030 pins with S-states and DSACK; rtlp/ has an abstract single-transaction
// bus. Nothing about the memory model is shareable.
//
// ONE CONVENTION THAT MATTERS. This core's bus is RIGHT-JUSTIFIED in both
// directions: a byte read returns its value in bits [7:0], and a byte write
// presents it there too. rtl/'s bus is lane-based big-endian. Getting this
// backwards produces plausible-looking wrong answers, which is exactly how it
// was found the first time (project_bf_mem_longword_sizing_bug.md).
// =============================================================================

module harte_p_tb;

    logic clk_4x = 1'b0;
    always #5 clk_4x = ~clk_4x;
    logic rst_n = 1'b0;

    // ── Memory: 4M x 32-bit words, the full 24-bit space, word index a[23:2] ──
    // Same indexing as tb/harte_tb.sv so gen_harte_hex.py's images load
    // unchanged.
    localparam int MEM_WORDS = 1 << 22;
    logic [31:0] mem [0:MEM_WORDS-1];

    string hexfile;
    initial begin
        if (!$value$plusargs("hexfile=%s", hexfile))
            hexfile = "tests/harte/test.hex";
        $readmemh(hexfile, mem);
    end

    // ── The core ──────────────────────────────────────────────────────────────
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
    // Every alignment is handled uniformly by going byte at a time, which also
    // covers the misaligned longword a 68020+ core is allowed to issue.
    function automatic logic [7:0] rdb(input logic [23:0] a);
        logic [31:0] w;
        w = mem[a[23:2]];
        case (a[1:0])
            2'b00: rdb = w[31:24];
            2'b01: rdb = w[23:16];
            2'b10: rdb = w[15:8];
            default: rdb = w[7:0];
        endcase
    endfunction

    // Overlay one byte into a word value, returning the new word.
    function automatic logic [31:0] setb(input logic [31:0] w,
                                        input logic [1:0]  sel,
                                        input logic [7:0]  v);
        setb = w;
        case (sel)
            2'b00: setb[31:24] = v;
            2'b01: setb[23:16] = v;
            2'b10: setb[15:8]  = v;
            default: setb[7:0] = v;
        endcase
    endfunction

    function automatic int nbytes(input logic [1:0] siz);
        nbytes = (siz == 2'b01) ? 1 : (siz == 2'b10) ? 2 : 4;
    endfunction

    // ── Bus model: one-cycle ack, right-justified data ────────────────────────
    logic [31:0] w0, w1, nw0, nw1;
    logic [23:0] ba;
    logic [31:0] acc;
    int k, nb;
    // +bustrace dumps every transaction, which is how a wrong SIZ or a wrong
    // address gets found without guessing.
    logic bustrace = 1'b0;
    initial bustrace = $test$plusargs("bustrace");

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
                bus_rdata <= acc;        // right-justified, N bytes big-endian
                if (bustrace)
                    $display("BUS  R %06x siz=%b n=%0d -> %08h", ba, bus_siz,
                             nb, acc);
            end else begin
                // Read-modify-write the one or two words the access spans, so
                // the array is only assigned once per word.
                nw0 = mem[ba[23:2]];
                nw1 = mem[ba[23:2] + 1];
                for (k = 0; k < nb; k++) begin
                    logic [23:0] a;
                    logic [7:0]  v;
                    a = ba + k[23:0];
                    v = bus_wdata[8*(nb - 1 - k) +: 8];
                    if (a[23:2] == ba[23:2]) nw0 = setb(nw0, a[1:0], v);
                    else                     nw1 = setb(nw1, a[1:0], v);
                    $display("MEMWRITE %06x %02x", a, v);
                end
                if (bustrace)
                    $display("BUS  W %06x siz=%b n=%0d <- %08h", ba, bus_siz,
                             nb, bus_wdata);
                mem[ba[23:2]]     <= nw0;
                mem[ba[23:2] + 1] <= nw1;
            end
        end
    end

    // ── Main ──────────────────────────────────────────────────────────────────
    // The CCR must be sampled BEFORE the program's terminating STOP overwrites
    // it with its own operand -- the same trap tb/harte_tb.sv documents at
    // length for rtl/. stopped_r is the level that makes that easy: it goes
    // high on the edge STOP commits and stays high, so freezing capture on it
    // keeps whatever the CCR held the cycle before.
    // +ccrtrace shows every committed CCR change with the instruction that
    // caused it, which is how a stray flag gets attributed.
    logic ccrtrace = 1'b0;
    initial ccrtrace = $test$plusargs("ccrtrace");
    always_ff @(posedge clk_4x) begin
        // Sampled in EX, not WB: wb_upd_ccr belongs to the PREVIOUS instruction,
        // so printing it beside ex_uop mixes two stages.
        if (ccrtrace && rst_n && dut.u_cpu.u_core.ex_valid && !dut.u_cpu.u_core.stall_ex)
            $display("EX cls=%0d aluop=%0d siz=%0d src=%08h dst=%08h res=%08h commit=%08h wr=%b r=%0d ccr_r=%02h",
                     dut.u_cpu.u_core.ex_uop.uclass, dut.u_cpu.u_core.ex_uop.alu_op,
                     dut.u_cpu.u_core.ex_uop.siz, dut.u_cpu.u_core.ex_src, dut.u_cpu.u_core.ex_dst,
                     dut.u_cpu.u_core.ex_result, dut.u_cpu.u_core.ex_commit,
                     dut.u_cpu.u_core.ex_uop.writes_reg, dut.u_cpu.u_core.ex_uop.dst_reg,
                     dut.u_cpu.u_core.ccr_r);
    end

    logic [7:0] ccr_shadow = 8'hFF;
    always_ff @(posedge clk_4x) begin
        if (ccrtrace && rst_n && (ccr_out !== ccr_shadow)) begin
            $display("ccr %02h -> %02h  t=%0t stopped=%b", ccr_shadow, ccr_out,
                     $time, dut.u_cpu.u_core.stopped_r);
            ccr_shadow <= ccr_out;
        end else if (rst_n) ccr_shadow <= ccr_out;
    end

    logic [7:0] ccr_before_stop;
    always_ff @(posedge clk_4x) begin
        if (!dut.u_cpu.u_core.stopped_r) ccr_before_stop <= ccr_out;
    end

    initial begin
        integer cycles;
        rst_n = 1'b0;
        repeat (20) @(posedge clk_4x);
        #1 rst_n = 1'b1;

        if (!$value$plusargs("cycles=%d", cycles)) cycles = 8000;

        fork
            begin : blk_timeout
                repeat (cycles) @(posedge clk_4x);
                disable blk_stop;
            end
            begin : blk_stop
                wait (stopped == 1'b1);
                repeat (4) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        if (ccrtrace)
            $display("DBG ccr_before_stop=%02h ccr_out=%02h sr_sys=%02h stopped=%b",
                     ccr_before_stop, ccr_out, dut.u_cpu.u_core.sr_sys_r, dut.u_cpu.u_core.stopped_r);
        $display("REGSTATE D0=%h D1=%h D2=%h D3=%h D4=%h D5=%h D6=%h D7=%h A0=%h A1=%h A2=%h A3=%h A4=%h A5=%h A6=%h A7=%h SR=%h PC=%h",
            dut.u_cpu.u_core.u_rf.regs[0],  dut.u_cpu.u_core.u_rf.regs[1],
            dut.u_cpu.u_core.u_rf.regs[2],  dut.u_cpu.u_core.u_rf.regs[3],
            dut.u_cpu.u_core.u_rf.regs[4],  dut.u_cpu.u_core.u_rf.regs[5],
            dut.u_cpu.u_core.u_rf.regs[6],  dut.u_cpu.u_core.u_rf.regs[7],
            dut.u_cpu.u_core.u_rf.regs[8],  dut.u_cpu.u_core.u_rf.regs[9],
            dut.u_cpu.u_core.u_rf.regs[10], dut.u_cpu.u_core.u_rf.regs[11],
            dut.u_cpu.u_core.u_rf.regs[12], dut.u_cpu.u_core.u_rf.regs[13],
            dut.u_cpu.u_core.u_rf.regs[14], dut.u_cpu.u_core.u_rf.regs[15],
            {dut.u_cpu.u_core.sr_sys_r, ccr_before_stop}, dut.if_pc);

        if (!stopped) $display("TIMEOUT");
        else          $display("OK");
        $finish;
    end

endmodule

`default_nettype wire

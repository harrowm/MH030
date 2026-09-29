`default_nettype none
`timescale 1ps/1ps

// =============================================================================
// Batched Harte testbench for MH030-P (rtlp/), compiled with Verilator.
//
// Stands to tb/harte_p_tb.sv exactly as tb/harte_verilator_tb.sv stands to
// tb/harte_tb.sv: same memory model, same bus model, same CCR-before-STOP
// capture, but clk_4x/rst_n come from C++ (tb/harte_p_verilator_main.cpp),
// memory is poked directly into mem[] via rootp access rather than
// $readmemh, and written bytes are read back out of mem[] afterwards instead
// of being reported line by line as they happen. Harte's own JSON format
// specifies nothing but initial and final snapshots, so a final-state read
// loses no verification fidelity -- it just skips all the print formatting
// in the hot loop.
//
// This exists because the Icarus runner is far too slow for a full-corpus
// sweep of the new core: the same reasoning, and the same measured gap, that
// produced the rtl/ Verilator backend in the first place.
// =============================================================================

module harte_p_verilator_tb (
    input  logic clk_4x,
    input  logic rst_n,
    output logic stop_out
);

    // Same indexing as tb/harte_p_tb.sv, so the same images load unchanged.
    localparam int MEM_WORDS = 1 << 22;
    logic [31:0] mem [0:MEM_WORDS-1];

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

    function automatic logic [7:0] rdb(input logic [23:0] a);
        logic [31:0] w;
        w = mem[a[23:2]];
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

    // One-cycle ack, right-justified data in both directions -- see
    // tb/harte_p_tb.sv's header for why that convention matters.
    logic [31:0] nw0, nw1;
    logic [23:0] ba;
    logic [31:0] acc;
    int k, nb;

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
            end else begin
                nw0 = mem[ba[23:2]];
                nw1 = mem[ba[23:2] + 1];
                for (k = 0; k < nb; k++) begin
                    logic [23:0] a;
                    logic [7:0]  v;
                    a = ba + k[23:0];
                    v = bus_wdata[8*(nb - 1 - k) +: 8];
                    if (a[23:2] == ba[23:2]) nw0 = setb(nw0, a[1:0], v);
                    else                     nw1 = setb(nw1, a[1:0], v);
                end
                mem[ba[23:2]]     <= nw0;
                mem[ba[23:2] + 1] <= nw1;
            end
        end
    end

    // The CCR must be sampled before the terminating STOP overwrites it with
    // its own operand. stopped_r is a level, not a pulse, so freezing capture
    // on it keeps whatever the CCR held the cycle before.
    logic [7:0] ccr_before_stop;
    always_ff @(posedge clk_4x) begin
        if (!dut.u_cpu.u_core.stopped_r) ccr_before_stop <= ccr_out;
    end

    logic stop_seen;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)       stop_seen <= 1'b0;
        else if (stopped) stop_seen <= 1'b1;
    end
    assign stop_out = stop_seen;

endmodule

`default_nettype wire

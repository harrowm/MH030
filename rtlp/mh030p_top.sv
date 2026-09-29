`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P top, abstract-bus configuration: CPU + a single-tick bus arbiter.
//
// This is the configuration every existing rtlp testbench and gate drives, and
// its behaviour is unchanged. A transaction completes whenever the memory model
// asserts bus_ack, with no S-states and no DSACK -- deliberately, because the
// pipeline was built and measured against it.
//
// The CPU itself now lives in mh030p_cpu.sv, shared with mh030p_biu_top.sv
// (the A4 configuration, which puts the real 68030 BIU underneath instead).
// Everything above the bus is identical between the two.
//
// Instruction fetch and data share ONE external bus, arbitrated by
// mh030p_arb.sv with data winning over fetch, as rtl/biu_arbiter.sv does.
// =============================================================================

module mh030p_top (
    input  wire        clk_4x,
    input  wire        rst_n,

    // The single external bus.
    output wire        bus_req,
    output wire [31:0] bus_addr,
    output wire        bus_rw,
    output wire [1:0]  bus_siz,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ack,

    // Interrupt priority level, encoded 0-7 (see the core).
    input  wire [2:0]  ipl,

    // Architectural state, exposed for the testbench.
    output wire        wb_wr_en,
    output wire [3:0]  wb_wr_sel,
    output wire [31:0] wb_wr_data,
    output wire        stopped,
    output wire [7:0]  ccr_out
);

    // Internal request/ack pairs, joined by the arbiter below.
    wire        if_req,  mem_req, mem_rw, mem_lock;
    wire [31:0] if_addr, mem_addr, mem_wdata;
    wire [1:0]  mem_siz;
    wire [31:0] if_rdata, mem_rdata;
    wire        if_ack,  mem_ack;
    wire [31:0] if_pc;

    mh030p_cpu u_cpu (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .if_req(if_req), .if_addr(if_addr),
        .if_rdata(if_rdata), .if_ack(if_ack),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_lock(mem_lock),
        .ipl(ipl),
        .sr_sys(), .cacr(),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .stopped(stopped), .ccr_out(ccr_out),
        .if_pc(if_pc)
    );

    mh030p_arb u_arb (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .if_req(if_req), .if_addr(if_addr),
        .if_rdata(if_rdata), .if_ack(if_ack),
        .d_req(mem_req), .d_addr(mem_addr), .d_rw(mem_rw),
        .d_siz(mem_siz), .d_wdata(mem_wdata), .d_lock(mem_lock),
        .d_rdata(mem_rdata), .d_ack(mem_ack),
        .bus_req(bus_req), .bus_addr(bus_addr), .bus_rw(bus_rw),
        .bus_siz(bus_siz), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .bus_ack(bus_ack)
    );

endmodule

`default_nettype wire

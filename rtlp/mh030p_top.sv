`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P top: fetch unit + core.
//
// This is the first configuration that runs a program rather than a
// testbench-fed instruction sequence, which is what makes a branch TARGET
// verifiable end to end -- until now only the squash could be checked.
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

    wire [15:0] if_instr, if_q3;
    wire [31:0] if_ext, if_pc;
    wire [2:0]  if_avail;
    wire        redirect;
    wire [31:0] redirect_pc;
    wire        core_ready;

    // Decode the offered opcode once, here, purely to learn how many
    // extension words it needs: the fetch unit cannot know that, and the core
    // needs the words before it can decode. One shared decoder instance would
    // be tidier but would create a loop through the core's own decode.
    uop_t peek;
    mh030p_decode u_peek (
        .instr(if_instr), .ext(if_ext), .q3(if_q3), .uop(peek)
    );

    // Issue only once the whole instruction is in the queue.
    wire have_all = (if_avail >= (3'd1 + peek.ext_words));
    wire issue    = have_all && core_ready;
    wire [2:0] drain = issue ? (3'd1 + peek.ext_words) : 3'd0;

    mh030p_ifu u_ifu (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .if_req(if_req), .if_addr(if_addr),
        .if_rdata(if_rdata), .if_ack(if_ack),
        .redirect(redirect), .redirect_pc(redirect_pc),
        .instr(if_instr), .ext(if_ext), .q3(if_q3),
        .words_avail(if_avail), .pc_out(if_pc),
        .drain(drain), .ext_words(peek.ext_words)
    );

    mh030p_core u_core (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr(if_instr), .ext(if_ext), .q3(if_q3),
        .ipl(ipl),
        .instr_valid(have_all), .instr_ready(core_ready),
        .pc_in(if_pc), .redirect(redirect), .redirect_pc(redirect_pc),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_lock(mem_lock),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out), .stopped(stopped)
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

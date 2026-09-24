`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P top: fetch unit + core.
//
// This is the first configuration that runs a program rather than a
// testbench-fed instruction sequence, which is what makes a branch TARGET
// verifiable end to end -- until now only the squash could be checked.
//
// The instruction and data ports are separate. Real 68030 silicon arbitrates
// one bus between them (rtl/biu_arbiter.sv); see mh030p_ifu.sv's header for
// why that is deliberately not modelled yet.
// =============================================================================

module mh030p_top (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Instruction port.
    output wire        if_req,
    output wire [31:0] if_addr,
    input  wire [31:0] if_rdata,
    input  wire        if_ack,

    // Data port.
    output wire        mem_req,
    output wire [31:0] mem_addr,
    output wire        mem_rw,
    output wire [1:0]  mem_siz,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ack,

    // Architectural state, exposed for the testbench.
    output wire        wb_wr_en,
    output wire [3:0]  wb_wr_sel,
    output wire [31:0] wb_wr_data,
    output wire [7:0]  ccr_out
);

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
        .instr_valid(have_all), .instr_ready(core_ready),
        .pc_in(if_pc), .redirect(redirect), .redirect_pc(redirect_pc),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out)
    );

endmodule

`default_nettype wire

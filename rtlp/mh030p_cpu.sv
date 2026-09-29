`default_nettype none
`include "mh030p_uop.svh"

// =============================================================================
// MH030-P CPU: fetch unit + core + the peek decoder that joins them.
//
// WHY THIS MODULE EXISTS. Everything here used to live directly inside
// mh030p_top.sv, which also instantiated the abstract bus arbiter. That was
// fine while there was one bus, but there are now two configurations that need
// exactly this content and differ only in what sits below it:
//
//   mh030p_top.sv      cpu + mh030p_arb       -- abstract single-tick bus
//   mh030p_biu_top.sv  cpu + m68030_biu       -- the real BIU, real pins (A4)
//
// So the split is along the line the A4 contract draws: above it, the core and
// its fetch unit; below it, whatever provides transactions. Nothing about the
// pipeline changes between the two -- that is the point of the contract.
//
// The ports below are the abstract request/ack pairs the core and fetch unit
// already spoke. mh030p_arb joins them onto one abstract port; m68030_biu
// takes them on its eu_* and ifu_* ports instead.
// =============================================================================

module mh030p_cpu (
    input  wire        clk_4x,
    input  wire        rst_n,

    // Instruction fetch port.
    output wire        if_req,
    output wire [31:0] if_addr,
    input  wire [31:0] if_rdata,
    input  wire        if_ack,

    // Data port -- registered request, registered ack (plan A4).
    output wire        mem_req,
    output wire [31:0] mem_addr,
    output wire        mem_rw,
    output wire [1:0]  mem_siz,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ack,
    // Hold the bus across an indivisible operation (TAS/CAS).
    output wire        mem_lock,

    // Interrupt priority level, encoded 0-7 (see the core).
    input  wire [2:0]  ipl,

    // Control state a real BIU needs and an abstract bus does not: the upper
    // half of SR (for the function code and the I-cache's supervisor tag) and
    // CACR (for the cache enables). Both are plain registers inside the core;
    // exposing them costs nothing and the abstract configuration simply leaves
    // them unconnected.
    output wire [7:0]  sr_sys,
    output wire [31:0] cacr,

    // Architectural state, exposed for the testbench.
    output wire        wb_wr_en,
    output wire [3:0]  wb_wr_sel,
    output wire [31:0] wb_wr_data,
    output wire        stopped,
    output wire [7:0]  ccr_out,
    // The PC of the instruction being offered, which the Harte harness reads.
    output wire [31:0] if_pc
);

    wire [15:0] if_instr, if_q3;
    wire [31:0] if_ext, if_ext_raw;
    wire [2:0]  if_avail;
    wire        redirect;
    wire [31:0] redirect_pc;
    wire        core_ready;

    // Decode the offered opcode once, here, purely to learn how many
    // extension words it needs: the fetch unit cannot know that, and the core
    // needs the words before it can decode. One shared decoder instance would
    // be tidier but would create a loop through the core's own decode.
    //
    // ext_raw, NOT ext. The fetch unit's `ext` is muxed BY ext_words (a single
    // extension word is normalised into the low half), so feeding it here
    // closes a combinational cycle through this decoder. It is a false cycle --
    // ext_words is a function of the opcode alone -- but place-and-route
    // unrolls it anyway and charges two passes through the decoder to one
    // clock: 78% of the core's worst path, 151 of its 179 hops, before this.
    uop_t peek;
    mh030p_decode u_peek (
        .instr(if_instr), .ext(if_ext_raw), .ext_raw(if_ext_raw),
        .q3(if_q3), .uop(peek)
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
        .instr(if_instr), .ext(if_ext), .ext_raw(if_ext_raw), .q3(if_q3),
        .words_avail(if_avail), .pc_out(if_pc),
        .drain(drain), .ext_words(peek.ext_words)
    );

    mh030p_core u_core (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .instr(if_instr), .ext(if_ext), .ext_raw(if_ext_raw), .q3(if_q3),
        .ipl(ipl),
        .instr_valid(have_all), .instr_ready(core_ready),
        .pc_in(if_pc), .redirect(redirect), .redirect_pc(redirect_pc),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rw(mem_rw),
        .mem_siz(mem_siz), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_lock(mem_lock),
        .sr_sys_o(sr_sys), .cacr_o(cacr),
        .wb_wr_en(wb_wr_en), .wb_wr_sel(wb_wr_sel),
        .wb_wr_data(wb_wr_data), .ccr_out(ccr_out), .stopped(stopped)
    );

endmodule

`default_nettype wire

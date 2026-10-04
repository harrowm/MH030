`default_nettype none
`include "mh030p_uop.svh"
// Companion to tb/extw_probe.sv: measures ONLY the ext_words_fast_o cone
// (rtlp/mh030p_decode.sv's from-scratch, raw-wire brief-format decoder,
// Stage 1 of the 100 MHz programme's ext_words work -- see plan.md's "Full-
// format addendum profiled" / shallow-decoder session) instead of the real
// uop.ext_words. Same wrapper shape as extw_probe.sv so the two numbers are
// directly comparable: `make fmax-extw` vs `make fmax-extw-fast`.
module extw_fast_probe (
    input  wire        clk_4x,
    input  wire        rst_n,
    input  wire [15:0] instr_i,
    input  wire [31:0] extraw_i,
    input  wire [15:0] q3_i,
    output reg  [2:0]  extw_o
);
    reg [15:0] instr_r, q3_r;
    reg [31:0] extraw_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) begin instr_r<=16'h0; extraw_r<=32'h0; q3_r<=16'h0; end
        else begin instr_r<=instr_i; extraw_r<=extraw_i; q3_r<=q3_i; end

    uop_t u;
    wire [2:0] fast_w;
    mh030p_decode u_d (.instr(instr_r), .ext(extraw_r), .ext_raw(extraw_r),
                       .q3(q3_r), .q4(16'h0), .uop(u), .ext_words_fast_o(fast_w));

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) extw_o <= 3'd0; else extw_o <= fast_w;
endmodule
`default_nettype wire

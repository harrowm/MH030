`default_nettype none
`include "mh030p_uop.svh"
// Measures ONLY the ext_words cone of mh030p_decode: registers in, registers
// out, nothing else, so Yosys prunes every other decoder output away.
//
// WHY IT EXISTS. The A4 configuration's worst path runs
//   q[0] -> u_peek (ext_words) -> mh030p_ifu.sv's `ext` mux -> u_core.u_dec
// i.e. two decoder passes in series, and a -noflatten report attributed 50
// levels to the peek leg. That attribution was suspect, because -noflatten
// cannot prune a module's unused outputs. This probe settles it: with
// everything but ext_words pruned, the cone still measures 41.70 MHz -- about
// 24 ns for a 3-bit function of 16 opcode bits. So the depth is real, and
// ext_words alone caps the whole design near 41 MHz however the serial pass is
// restructured.
//
// It is a MEASUREMENT TOOL, not a test: `make fmax-extw` gives a 30-second
// answer on the one cone that matters, instead of a 5-minute full-design sweep
// whose netlist noise (~2 MHz) can swallow the effect being looked for.
module extw_probe (
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
    mh030p_decode u_d (.instr(instr_r), .ext(extraw_r), .ext_raw(extraw_r),
                       .q3(q3_r), .uop(u));

    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) extw_o <= 3'd0; else extw_o <= u.ext_words;
endmodule
`default_nettype wire

`default_nettype none

// =============================================================================
// MH030-P multiply: a two-stage 32x32, replacing the combinational one.
//
// WHY THIS EXISTS. Measurement, not preference. The third growth measurement
// (12,106 LUTs, 28.21 MHz) found 83.7% of the worst path -- 29.68 ns over 61
// hops -- inside rtl/eu_mul_div.sv, and reading that module explains why: it
// builds FOUR independent multipliers that all evaluate every cycle, and two of
// them are far wider than the arithmetic needs.
//
//     muluw_lo = mw_u_src * mw_u_dst                       32 x 32
//     mulsw_lo = $signed(mw_s_src) * $signed(mw_s_dst)     32 x 32
//     mulul_64 = {32'h0,src} * {32'h0,dst}                 64 x 64
//     mulsl_64 = $signed({{32{src[31]}},src}) * ...         64 x 64
//
// The word forms are 16x16 products computed as 32x32, and the long forms are
// 32x32 products computed as 64x64 because both operands were widened to the
// result width before the operator saw them. Only the low half of each 64-bit
// product's own operand range is ever significant.
//
// This module computes the same four results from FIVE 17x17 partial products,
// which is what the ECP5's own MULT18X18D block natively is, and splits the
// composition adders behind a register. rtl/eu_mul_div.sv is left alone: it is
// the frozen golden reference, its results are correct, and the cost is area
// and depth rather than behaviour.
//
// TWO CYCLES, and that is more faithful rather than less: real 68030 MULU.W is
// about 28 clocks and MULS.L about 44. The handshake is the same shape the
// sequential divider already uses -- a one-tick start, a busy flag the EX stage
// stalls on.
// =============================================================================

module mh030p_mul (
    input  wire        clk_4x,
    input  wire        rst_n,

    input  wire        start,      // one tick: operands are valid, begin
    output reg         busy,       // high until the result is ready

    input  wire [31:0] src,        // multiplier
    input  wire [31:0] dst,        // multiplicand
    input  wire [1:0]  op,         // 00 MULU.W, 01 MULS.W, 10 MULU.L, 11 MULS.L

    output wire [31:0] result_lo,
    output wire [31:0] result_hi,
    output wire        n_out,
    output wire        z_out
);

    localparam [1:0] M_UW = 2'b00, M_SW = 2'b01, M_UL = 2'b10, M_SL = 2'b11;

    // ── Stage 1: five partial products ──────────────────────────────────────
    // The high halves are signed only for MULS.L; the low halves are always
    // unsigned, because a 32-bit value's low 16 bits carry no sign. That
    // asymmetry is the whole reason a signed 32x32 decomposes into three
    // differently-signed products rather than four identical ones.
    wire        hi_s = (op == M_SL);
    wire [15:0] al = dst[15:0], ah = dst[31:16];
    wire [15:0] bl = src[15:0], bh = src[31:16];

    wire signed [16:0] s_ah = {hi_s & ah[15], ah};
    wire signed [16:0] s_bh = {hi_s & bh[15], bh};
    wire signed [16:0] u_al = {1'b0, al};
    wire signed [16:0] u_bl = {1'b0, bl};
    wire signed [16:0] w_al = {al[15], al};     // MULS.W treats these as signed
    wire signed [16:0] w_bl = {bl[15], bl};

    reg        [31:0] pp_ll;    // unsigned low x low, also the whole MULU.W
    reg signed [31:0] pp_sw;    // signed   low x low, the whole MULS.W
    reg signed [33:0] pp_lh, pp_hl, pp_hh;
    reg        [1:0]  op_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            pp_ll <= 32'h0;  pp_sw <= 32'h0;
            pp_lh <= 34'h0;  pp_hl <= 34'h0;  pp_hh <= 34'h0;
            op_r  <= 2'b00;
            busy  <= 1'b0;
        end else if (start) begin
            pp_ll <= al * bl;
            pp_sw <= w_al * w_bl;
            pp_lh <= u_al * s_bh;
            pp_hl <= s_ah * u_bl;
            pp_hh <= s_ah * s_bh;
            op_r  <= op;
            busy  <= 1'b1;
        end else begin
            busy  <= 1'b0;     // one tick of latency; the products are ready
        end
    end

    // ── Stage 2: compose ────────────────────────────────────────────────────
    wire signed [63:0] hh_sh = {{30{pp_hh[33]}}, pp_hh} <<< 32;
    wire signed [63:0] lh_sh = {{30{pp_lh[33]}}, pp_lh} <<< 16;
    wire signed [63:0] hl_sh = {{30{pp_hl[33]}}, pp_hl} <<< 16;
    wire signed [63:0] full  = hh_sh + lh_sh + hl_sh + {32'h0, pp_ll};

    wire is_long = (op_r == M_UL) || (op_r == M_SL);
    wire [31:0] full_lo = full[31:0];
    wire [31:0] full_hi = full[63:32];
    wire [31:0] word_lo = (op_r == M_SW) ? pp_sw : pp_ll;

    assign result_lo = is_long ? full_lo : word_lo;
    assign result_hi = is_long ? full_hi : 32'h0;
    assign n_out     = is_long ? full[63] : word_lo[31];
    assign z_out     = is_long ? (full == 64'h0) : (word_lo == 32'h0);

endmodule

`default_nettype wire

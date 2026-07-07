`default_nettype none

// MC68030 multiply/divide unit — purely combinational.
// Implements MULU.W, MULS.W, MULU.L, MULS.L, DIVU.W, DIVS.W, DIVU.L, DIVS.L.
//
// Operand convention (matches 68030 instruction encoding):
//   src = source (<ea> field, multiplier / divisor)
//   dst = destination (Dn, multiplicand / dividend)
//
// Word multiply:  src[15:0] × dst[15:0] → result_lo (32-bit)
// Long multiply:  src[31:0] × dst[31:0] → {result_hi, result_lo} (64-bit)
// Word divide:    dst[31:0] ÷ src[15:0] → result_lo = {remainder[15:0], quotient[15:0]}
//
// All intermediate signals via assign to avoid "sorry: constant selects in always_*"
// in Icarus 13.  Constant bit-selects inside always_comb are the Icarus problem;
// in assign statements they are fine.

module eu_mul_div (
    input  logic [31:0] src,        // source operand (multiplier / divisor)
    input  logic [31:0] dst,        // destination operand (multiplicand / dividend)
    input  logic [2:0]  op,
    output logic [31:0] result_lo,  // lower 32 bits; DIV: {rem[15:0], quot[15:0]}
    output logic [31:0] result_hi,  // upper 32 bits (long multiply only)
    output logic        n_out,
    output logic        z_out,
    output logic        v_out,      // set on div overflow or div-by-zero
    output logic        c_out,      // always 0
    output logic        div_by_zero // trap signal for zero divisor
);

    localparam [2:0]
        MUL_UW = 3'h0,   // MULU.W: unsigned 16×16 → 32
        MUL_SW = 3'h1,   // MULS.W: signed   16×16 → 32
        MUL_UL = 3'h2,   // MULU.L: unsigned 32×32 → 64
        MUL_SL = 3'h3,   // MULS.L: signed   32×32 → 64
        DIV_UW = 3'h4,   // DIVU.W: unsigned 32÷16 → 16r:16q
        DIV_SW = 3'h5,   // DIVS.W: signed   32÷16 → 16r:16q
        DIV_UL = 3'h6,   // DIVU.L: unsigned 32÷32 → 32r:32q
        DIV_SL = 3'h7;   // DIVS.L: signed   32÷32 → 32r:32q

    // -----------------------------------------------------------------------
    // Word multiply operands — sign/zero extended to 32 bits
    // -----------------------------------------------------------------------
    logic [31:0] mw_u_src, mw_u_dst;   // zero-extended (unsigned)
    logic [31:0] mw_s_src, mw_s_dst;   // sign-extended (signed)

    assign mw_u_src = {16'h0, src[15:0]};
    assign mw_u_dst = {16'h0, dst[15:0]};
    assign mw_s_src = {{16{src[15]}}, src[15:0]};
    assign mw_s_dst = {{16{dst[15]}}, dst[15:0]};

    // -----------------------------------------------------------------------
    // Word multiply results (32-bit; 16×16 product always fits)
    // -----------------------------------------------------------------------
    logic [31:0] muluw_lo, mulsw_lo;
    assign muluw_lo = mw_u_src * mw_u_dst;
    assign mulsw_lo = $signed(mw_s_src) * $signed(mw_s_dst);

    // Precompute N flags (constant bit-select in assign: OK)
    logic muluw_n, mulsw_n;
    assign muluw_n = muluw_lo[31];
    assign mulsw_n = mulsw_lo[31];

    // -----------------------------------------------------------------------
    // Long multiply results (64-bit)
    // -----------------------------------------------------------------------
    logic [63:0] mulul_64, mulsl_64;
    assign mulul_64 = {32'h0, src} * {32'h0, dst};
    assign mulsl_64 = $signed({{32{src[31]}}, src}) * $signed({{32{dst[31]}}, dst});

    // Split for always_comb (avoids wide-vector constant selects inside always_*)
    logic [31:0] mulul_lo_p, mulul_hi_p;
    logic [31:0] mulsl_lo_p, mulsl_hi_p;
    logic        mulul_n, mulsl_n;
    assign mulul_lo_p = mulul_64[31:0];
    assign mulul_hi_p = mulul_64[63:32];
    assign mulsl_lo_p = mulsl_64[31:0];
    assign mulsl_hi_p = mulsl_64[63:32];
    assign mulul_n    = mulul_64[63];
    assign mulsl_n    = mulsl_64[63];

    // -----------------------------------------------------------------------
    // DIVU.W — unsigned 32-bit ÷ 16-bit
    // -----------------------------------------------------------------------
    logic [15:0] divu_divisor;
    logic [31:0] divu_quot, divu_rem;
    logic        divu_zero, divu_ovf;
    logic [31:0] divu_res;
    logic        divu_n, divu_z;

    assign divu_divisor = src[15:0];
    assign divu_zero    = (divu_divisor == 16'h0);
    assign divu_quot    = divu_zero ? 32'h0 : (dst / {16'h0, divu_divisor});
    assign divu_rem     = divu_zero ? 32'h0 : (dst % {16'h0, divu_divisor});
    // Overflow: quotient doesn't fit in 16 bits (bits 31:16 non-zero)
    assign divu_ovf     = !divu_zero && (divu_quot[31:16] != 16'h0);
    assign divu_res     = {divu_rem[15:0], divu_quot[15:0]};
    assign divu_n       = divu_quot[15];
    assign divu_z       = (divu_quot[15:0] == 16'h0);

    // -----------------------------------------------------------------------
    // DIVS.W — signed 32-bit ÷ 16-bit signed
    //
    // $signed() in assign does not force signed division in Icarus 13.
    // Declare operands and result as "logic signed" so the / and % operators
    // see signed types natively without needing a $signed() cast.
    // -----------------------------------------------------------------------
    logic signed [31:0] divs_dividend_s;   // signed alias for dst
    logic signed [31:0] divs_divisor_s;    // sign-extended src[15:0]
    logic signed [31:0] divs_quot_s;       // signed quotient
    logic signed [31:0] divs_rem_s;        // signed remainder

    logic [31:0] divs_quot, divs_rem;      // unsigned aliases (same bits)
    logic        divs_zero, divs_ovf;
    logic [31:0] divs_res;
    logic        divs_n, divs_z;

    assign divs_dividend_s = dst;                          // copy bits; type gives sign
    assign divs_divisor_s  = {{16{src[15]}}, src[15:0]};  // sign-extend 16→32
    assign divs_zero       = (src[15:0] == 16'h0);
    // Signed division: operands are "logic signed", so / and % are signed ops
    assign divs_quot_s     = divs_zero ? 32'sh0 : (divs_dividend_s / divs_divisor_s);
    assign divs_rem_s      = divs_zero ? 32'sh0 : (divs_dividend_s % divs_divisor_s);
    assign divs_quot       = divs_quot_s;
    assign divs_rem        = divs_rem_s;
    // Overflow: quotient not in [-32768, 32767]
    assign divs_ovf        = !divs_zero && (divs_quot[31:16] != {16{divs_quot[15]}});
    assign divs_res        = {divs_rem[15:0], divs_quot[15:0]};
    assign divs_n          = divs_quot[15];
    assign divs_z          = (divs_quot[15:0] == 16'h0);

    // -----------------------------------------------------------------------
    // DIVU.L — unsigned 32-bit ÷ 32-bit → result_lo=quotient, result_hi=remainder
    // -----------------------------------------------------------------------
    logic [31:0] divul_quot, divul_rem;
    logic        divul_zero, divul_n, divul_z;
    assign divul_zero = (src == 32'h0);
    assign divul_quot = divul_zero ? 32'h0 : (dst / src);
    assign divul_rem  = divul_zero ? 32'h0 : (dst % src);
    assign divul_n    = divul_quot[31];
    assign divul_z    = (divul_quot == 32'h0);

    // -----------------------------------------------------------------------
    // DIVS.L — signed 32-bit ÷ 32-bit → result_lo=quotient, result_hi=remainder
    // Overflow: INT_MIN / -1 (undefined result; set V, no trap)
    // -----------------------------------------------------------------------
    logic signed [31:0] divsl_dividend_s, divsl_divisor_s, divsl_quot_s, divsl_rem_s;
    logic [31:0] divsl_quot, divsl_rem;
    logic        divsl_zero, divsl_ovf, divsl_n, divsl_z;
    assign divsl_dividend_s = dst;
    assign divsl_divisor_s  = src;
    assign divsl_zero       = (src == 32'h0);
    assign divsl_ovf        = !divsl_zero && (dst == 32'h8000_0000) && (src == 32'hFFFF_FFFF);
    assign divsl_quot_s     = (divsl_zero || divsl_ovf) ? 32'sh0 : (divsl_dividend_s / divsl_divisor_s);
    assign divsl_rem_s      = (divsl_zero || divsl_ovf) ? 32'sh0 : (divsl_dividend_s % divsl_divisor_s);
    assign divsl_quot       = divsl_quot_s;
    assign divsl_rem        = divsl_rem_s;
    assign divsl_n          = divsl_quot[31];
    assign divsl_z          = (divsl_quot == 32'h0);

    // -----------------------------------------------------------------------
    // Output mux — no constant bit-selects here; all extracted above
    // -----------------------------------------------------------------------
    always_comb begin
        result_lo   = 32'h0;
        result_hi   = 32'h0;
        n_out       = 1'b0;
        z_out       = 1'b1;
        v_out       = 1'b0;
        c_out       = 1'b0;
        div_by_zero = 1'b0;

        case (op)
            MUL_UW: begin
                result_lo = muluw_lo;
                n_out     = muluw_n;
                z_out     = (muluw_lo == 32'h0);
            end
            MUL_SW: begin
                result_lo = mulsw_lo;
                n_out     = mulsw_n;
                z_out     = (mulsw_lo == 32'h0);
            end
            MUL_UL: begin
                result_lo = mulul_lo_p;
                result_hi = mulul_hi_p;
                n_out     = mulul_n;
                z_out     = (mulul_64 == 64'h0);
            end
            MUL_SL: begin
                result_lo = mulsl_lo_p;
                result_hi = mulsl_hi_p;
                n_out     = mulsl_n;
                z_out     = (mulsl_64 == 64'h0);
            end
            DIV_UW: begin
                div_by_zero = divu_zero;
                v_out       = divu_zero | divu_ovf;
                if (!divu_zero && !divu_ovf) begin
                    result_lo = divu_res;
                    n_out     = divu_n;
                    z_out     = divu_z;
                end
            end
            DIV_SW: begin
                div_by_zero = divs_zero;
                v_out       = divs_zero | divs_ovf;
                if (!divs_zero && !divs_ovf) begin
                    result_lo = divs_res;
                    n_out     = divs_n;
                    z_out     = divs_z;
                end
            end
            DIV_UL: begin
                div_by_zero = divul_zero;
                v_out       = divul_zero;
                if (!divul_zero) begin
                    result_lo = divul_quot;
                    result_hi = divul_rem;
                    n_out     = divul_n;
                    z_out     = divul_z;
                end
            end
            DIV_SL: begin
                div_by_zero = divsl_zero;
                v_out       = divsl_zero | divsl_ovf;
                if (!divsl_zero && !divsl_ovf) begin
                    result_lo = divsl_quot;
                    result_hi = divsl_rem;
                    n_out     = divsl_n;
                    z_out     = divsl_z;
                end
            end
            default: ;
        endcase
    end

endmodule

`default_nettype wire

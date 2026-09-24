`timescale 1ns/1ps
`default_nettype none

// MC68030 multiply/divide unit.
// Implements MULU.W, MULS.W, MULU.L, MULS.L, DIVU.W, DIVS.W, DIVU.L, DIVS.L.
//
// MULTIPLY is purely combinational (it maps to ECP5 MULT18X18D DSP blocks,
// of which only 5 of 156 were in use).
//
// DIVIDE is SEQUENTIAL (MH030-P plan, P0 finding).  It used to be purely
// combinational: four independent 32-bit dividers, each instantiating both
// `/` and `%` -- eight divide operators, every one of them a full restoring-
// division array, all evaluating every single cycle and feeding the writeback
// mux.  A real ECP5 measurement attributed 191.18 ns of the 406.99 ns worst
// critical path (47.0%, 1920 hops, a repeating ~60-hop block about 30 times
// over) to this one module.  Statically that is a register-to-register path
// that must settle in one clock; functionally it never needed to, because the
// EU already holds DIVS.L/DIVU.L stalled for 352/304 ticks to match real
// 68030 cycle counts.  Making the iteration structural rather than relying on
// a multicycle-path promise is the honest fix.
//
// The sequential divider computes the IDENTICAL mathematical values the
// combinational one did -- same truncate-toward-zero signed semantics, same
// overflow rules, same flags -- so every Harte-verified behaviour is
// preserved exactly.  Only the timing changes.
//
// Handshake: assert div_start for one tick once the operands are genuinely
// valid; div_busy is high from that tick until the result registers are
// loaded.  Results persist until the next div_start.
//
// EVERY divide output -- including div_by_zero -- is registered, latched from
// the operands at div_start.  A first attempt left div_by_zero combinational,
// reasoning that it depends only on the divisor and never on an iteration.
// That was wrong for a real reason worth recording: for a MEMORY-source
// divide, `src` is only valid on the mem_ack tick itself, and the result is
// now consumed ~32 ticks later, by which time src reads stale (often zero) --
// producing a spurious divide-by-zero trap that aborted the instruction.
// Caught by alu_mem_tb's DIVU-01/DIVS-01.  Because the flags are now valid
// one tick after div_start, div_busy is asserted for the start tick even in
// the short-circuited cases, so the consumer always gets a settled value.
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
    input  logic        clk_4x,
    input  logic        rst_n,
    input  logic        div_start,  // 1-tick: operands valid, begin dividing
    output logic        div_busy,   // high while iterating (incl. the start tick)
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

    // =======================================================================
    // SEQUENTIAL DIVIDER
    //
    // One shared restoring-division engine replaces the four independent
    // combinational dividers.  Every downstream signal below keeps the exact
    // name and meaning it had when this was combinational, so the output mux
    // needs no change at all.
    //
    // Strategy: always perform a full UNSIGNED 32/32 division on operand
    // MAGNITUDES, then re-apply signs.  That reproduces SystemVerilog's own
    // signed `/` and `%` semantics exactly (truncate toward zero; the
    // remainder takes the dividend's sign), which is what the combinational
    // version used and what every Harte vector was verified against.
    //
    // Magnitude note: negating 32'h8000_0000 yields itself, and read as an
    // unsigned value that IS the correct magnitude 2**31 -- so the usual
    // two's-complement edge case needs no special handling here.
    // -----------------------------------------------------------------------

    // Divisor-zero / overflow flags (declared here; assigned below).
    // These are the REGISTERED, operand-latched versions used by every
    // output; div_zero_now below is the combinational one used only to
    // decide, at div_start, whether there is anything to iterate.
    logic divu_zero, divs_zero, divul_zero, divsl_zero, divsl_ovf;

    // Per-op operand selection (all constant bit-selects in assigns: OK)
    logic        div_is_div;      // op is any divide
    logic        div_is_signed;
    logic [31:0] div_dividend;    // as a signed bit pattern
    logic [31:0] div_divisor;     // as a signed/unsigned bit pattern, 32-bit

    assign div_is_div    = (op == DIV_UW) || (op == DIV_SW) ||
                           (op == DIV_UL) || (op == DIV_SL);
    assign div_is_signed = (op == DIV_SW) || (op == DIV_SL);
    assign div_dividend  = dst;
    assign div_divisor   = ((op == DIV_UW) ? {16'h0, src[15:0]}          :
                           (op == DIV_SW) ? {{16{src[15]}}, src[15:0]}  :
                                            src);

    // Signs and magnitudes
    logic        div_dvd_neg, div_dsr_neg;
    logic [31:0] div_dvd_mag, div_dsr_mag;
    assign div_dvd_neg = div_is_signed && div_dividend[31];
    assign div_dsr_neg = div_is_signed && div_divisor[31];
    assign div_dvd_mag = div_dvd_neg ? (~div_dividend + 32'd1) : div_dividend;
    assign div_dsr_mag = div_dsr_neg ? (~div_divisor  + 32'd1) : div_divisor;

    // Combinational, operand-time versions -- used ONLY at div_start, to
    // decide whether there is anything to iterate and what to latch.
    logic div_zero_now, div_sl_ovf_now, div_skip;
    assign div_zero_now   = ((op == DIV_UW) || (op == DIV_SW)) ? (src[15:0] == 16'h0)
                                                               : (src == 32'h0);
    assign div_sl_ovf_now = (op == DIV_SL) && !div_zero_now &&
                            (dst == 32'h8000_0000) && (src == 32'hFFFF_FFFF);
    // Nothing to iterate for a zero divisor, or for DIVS.L's overflow case.
    assign div_skip = div_zero_now || div_sl_ovf_now;

    // Registered, operand-latched versions -- what every output below uses.
    logic div_zero_r, div_sl_ovf_r;
    assign divu_zero  = div_zero_r;
    assign divs_zero  = div_zero_r;
    assign divul_zero = div_zero_r;
    assign divsl_zero = div_zero_r;
    assign divsl_ovf  = div_sl_ovf_r;

    // ── The engine ─────────────────────────────────────────────────────────
    localparam [1:0] DS_IDLE = 2'd0, DS_RUN = 2'd1;

    logic [1:0]  div_state;
    logic [5:0]  div_iter;
    logic [32:0] div_rem_r;    // 33 bits: one shift-in headroom
    logic [31:0] div_quo_r;    // starts as the dividend, ends as the quotient
    logic [31:0] div_dsr_r;    // latched divisor magnitude
    logic        div_qneg_r, div_rneg_r;

    // Result registers, held until the next div_start.
    logic [31:0] div_quot_mag_r, div_rem_mag_r;
    logic        div_qneg_res_r, div_rneg_res_r;

    // Shift one bit of the dividend into the remainder, then conditionally
    // subtract.  This is the whole point: ONE 32-bit compare+subtract per
    // tick instead of 32 of them chained combinationally.
    logic [32:0] div_rem_shifted;
    logic        div_ge;
    assign div_rem_shifted = {div_rem_r[31:0], div_quo_r[31]};
    assign div_ge          = (div_rem_shifted >= {1'b0, div_dsr_r});

    assign div_busy = (div_state != DS_IDLE) || (div_start && div_is_div);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            div_state      <= DS_IDLE;
            div_iter       <= 6'd0;
            div_rem_r      <= 33'd0;
            div_quo_r      <= 32'd0;
            div_dsr_r      <= 32'd0;
            div_qneg_r     <= 1'b0;
            div_rneg_r     <= 1'b0;
            div_quot_mag_r <= 32'd0;
            div_rem_mag_r  <= 32'd0;
            div_qneg_res_r <= 1'b0;
            div_rneg_res_r <= 1'b0;
            div_zero_r     <= 1'b0;
            div_sl_ovf_r   <= 1'b0;
        end else begin
            case (div_state)
                DS_IDLE: begin
                    if (div_start && div_is_div) begin
                        // Latch the operand-time flags alongside the operands
                        // themselves; see the header note.
                        div_zero_r   <= div_zero_now;
                        div_sl_ovf_r <= div_sl_ovf_now;
                        if (div_skip) begin
                            // Result is defined without iterating; the output
                            // mux forces zero for these cases anyway.
                            div_quot_mag_r <= 32'd0;
                            div_rem_mag_r  <= 32'd0;
                            div_qneg_res_r <= 1'b0;
                            div_rneg_res_r <= 1'b0;
                        end else begin
                            div_rem_r  <= 33'd0;
                            div_quo_r  <= div_dvd_mag;
                            div_dsr_r  <= div_dsr_mag;
                            div_qneg_r <= div_dvd_neg ^ div_dsr_neg;
                            div_rneg_r <= div_dvd_neg;
                            div_iter   <= 6'd32;
                            div_state  <= DS_RUN;
                        end
                    end
                end

                DS_RUN: begin
                    if (div_ge) div_rem_r <= div_rem_shifted - {1'b0, div_dsr_r};
                    else        div_rem_r <= div_rem_shifted;
                    div_quo_r <= {div_quo_r[30:0], div_ge};
                    div_iter  <= div_iter - 6'd1;
                    if (div_iter == 6'd1) begin
                        div_state      <= DS_IDLE;
                        div_quot_mag_r <= {div_quo_r[30:0], div_ge};
                        div_rem_mag_r  <= div_ge
                                        ? (div_rem_shifted[31:0] - div_dsr_r)
                                        : div_rem_shifted[31:0];
                        div_qneg_res_r <= div_qneg_r;
                        div_rneg_res_r <= div_rneg_r;
                    end
                end

                default: div_state <= DS_IDLE;
            endcase
        end
    end

    // ── Sign re-application (shallow, from registers) ──────────────────────
    logic [31:0] div_quot_signed, div_rem_signed;
    assign div_quot_signed = div_qneg_res_r ? (~div_quot_mag_r + 32'd1) : div_quot_mag_r;
    assign div_rem_signed  = div_rneg_res_r ? (~div_rem_mag_r  + 32'd1) : div_rem_mag_r;

    // ── DIVU.W ─────────────────────────────────────────────────────────────
    logic [31:0] divu_quot, divu_rem;
    logic        divu_ovf;
    logic [31:0] divu_res;
    logic        divu_n, divu_z;
    assign divu_quot = div_quot_mag_r;
    assign divu_rem  = div_rem_mag_r;
    assign divu_ovf  = !divu_zero && (divu_quot[31:16] != 16'h0);
    assign divu_res  = {divu_rem[15:0], divu_quot[15:0]};
    assign divu_n    = divu_quot[15];
    assign divu_z    = (divu_quot[15:0] == 16'h0);

    // ── DIVS.W ─────────────────────────────────────────────────────────────
    logic [31:0] divs_quot, divs_rem;
    logic        divs_ovf;
    logic [31:0] divs_res;
    logic        divs_n, divs_z;
    assign divs_quot = div_quot_signed;
    assign divs_rem  = div_rem_signed;
    // Overflow: quotient not representable in 16 signed bits
    assign divs_ovf  = !divs_zero && (divs_quot[31:16] != {16{divs_quot[15]}});
    assign divs_res  = {divs_rem[15:0], divs_quot[15:0]};
    assign divs_n    = divs_quot[15];
    assign divs_z    = (divs_quot[15:0] == 16'h0);

    // ── DIVU.L ─────────────────────────────────────────────────────────────
    logic [31:0] divul_quot, divul_rem;
    logic        divul_n, divul_z;
    assign divul_quot = div_quot_mag_r;
    assign divul_rem  = div_rem_mag_r;
    assign divul_n    = divul_quot[31];
    assign divul_z    = (divul_quot == 32'h0);

    // ── DIVS.L ─────────────────────────────────────────────────────────────
    logic [31:0] divsl_quot, divsl_rem;
    logic        divsl_n, divsl_z;
    assign divsl_quot = div_quot_signed;
    assign divsl_rem  = div_rem_signed;
    assign divsl_n    = divsl_quot[31];
    assign divsl_z    = (divsl_quot == 32'h0);

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

`default_nettype none

// =============================================================================
// MH030-P shift/rotate unit: SEQUENTIAL, one bit per tick.
//
// ASL/ASR, LSL/LSR, ROL/ROR, ROXL/ROXR for byte/word/long, producing values and
// flags IDENTICAL to rtl/eu_shifter.sv, which stays the reference and is left
// untouched.
//
// WHY SEQUENTIAL. eu_shifter is combinational and needs about fourteen
// variable-distance barrel shifters to do it -- lsl, lsr, asr plus its sign
// fill, two each for rol and ror, two 33-bit ones each for roxl and roxr, and
// three mask generators of the form `result_mask >> eff_shift`. That came to
// 2,084 combinational cells, 6.9% of this core, all of it re-evaluating every
// cycle whether or not the instruction is a shift. Stepping one bit at a time
// needs exactly one fixed 1-bit shift per direction, which the synthesiser gets
// for free as wiring.
//
// It is also the more faithful implementation: MC68030UM's own shift timing is
// 6 + 2n, linear in the count, because real silicon iterates too. The cost is
// that a shift now takes up to 63 ticks instead of one.
//
// SINGLE-BIT ITERATION IS THE GROUND TRUTH for the awkward corners, which is
// why they need no special cases here:
//   * `count > size_bits` clearing C and X falls out -- by then the value is
//     zero and every further step shifts a zero out.
//   * ROXL/ROXR's period of size_bits+1 falls out of rotating through X.
//   * ASL's V ("the MSB changed at any point") is a running OR, rather than the
//     reference's windowed-mask reconstruction of the same question.
//
// Counts are 0-63 and NOT reduced modulo the size first: 68k register-form
// shifts take Dn mod 64, and the iteration count is that value.
// =============================================================================

module mh030p_shift (
    input  wire        clk_4x,
    input  wire        rst_n,

    // One-tick start: operands are valid, begin shifting. Everything is latched
    // here -- see feedback_sequentializing_combinational_unit: for a
    // memory-source form the operand is only valid on the ack tick, and the
    // result is read many ticks later.
    input  wire        start,
    output wire        busy,

    input  wire [31:0] operand,
    input  wire [5:0]  count,
    input  wire [3:0]  op,
    input  wire [1:0]  siz,
    input  wire        x_in,

    output wire [31:0] result,
    output wire        n_out,
    output wire        z_out,
    output wire        v_out,
    output wire        c_out,
    output wire        x_out
);

    // Same encoding as rtl/eu_shifter.sv. Reproduced rather than shared because
    // these are localparams there too; they must not drift.
    localparam [3:0]
        SHF_ASL  = 4'h0,
        SHF_ASR  = 4'h1,
        SHF_LSL  = 4'h2,
        SHF_LSR  = 4'h3,
        SHF_ROL  = 4'h4,
        SHF_ROR  = 4'h5,
        SHF_ROXL = 4'h6,
        SHF_ROXR = 4'h7;

    reg [31:0] val;
    reg [5:0]  rem;
    reg [3:0]  op_r;
    reg [1:0]  siz_r;
    reg        x_r, c_r, v_r;
    reg        running;

    assign busy = running;

    // Size masks, from the LATCHED size.
    wire [31:0] mask_r = (siz_r == 2'b01) ? 32'h0000_00FF
                       : (siz_r == 2'b10) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    wire [31:0] msb_r  = (siz_r == 2'b01) ? 32'h0000_0080
                       : (siz_r == 2'b10) ? 32'h0000_8000 : 32'h8000_0000;

    wire msb_bit = (val & msb_r)  != 32'h0;
    wire lsb_bit = (val & 32'h1)  != 32'h0;

    // The one step, in each direction. Fixed 1-bit shifts: no barrel shifter.
    wire [31:0] up   = (val << 1) & mask_r;
    wire [31:0] down = (val >> 1) & mask_r;

    wire [31:0] step_asl  = up;
    wire [31:0] step_asr  = down | (msb_bit ? msb_r   : 32'h0);  // sign fill
    wire [31:0] step_lsl  = up;
    wire [31:0] step_lsr  = down;
    wire [31:0] step_rol  = up   | (msb_bit ? 32'h1   : 32'h0);
    wire [31:0] step_ror  = down | (lsb_bit ? msb_r   : 32'h0);
    wire [31:0] step_roxl = up   | (x_r     ? 32'h1   : 32'h0);
    wire [31:0] step_roxr = down | (x_r     ? msb_r   : 32'h0);

    // ASL's V is a running OR of "did this step change the MSB".
    wire asl_v_step = msb_bit != ((up & msb_r) != 32'h0);

    // Masks for the OUTPUT flags follow the latched size too.
    assign result = val;
    assign n_out  = (val & msb_r) != 32'h0;
    assign z_out  = (val == 32'h0);
    assign v_out  = v_r;
    assign c_out  = c_r;
    assign x_out  = x_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            val     <= 32'h0;
            rem     <= 6'd0;
            op_r    <= 4'h0;
            siz_r   <= 2'b00;
            x_r     <= 1'b0;
            c_r     <= 1'b0;
            v_r     <= 1'b0;
            running <= 1'b0;
        end else if (start) begin
            // The count==0 answers, latched up front. C clears for every op
            // except ROXL/ROXR, which take the current X instead (68k PRM: "if
            // the rotate count is zero, the C bit is set to the value of the
            // extend bit"). X is unchanged, V is clear, and the value passes
            // through masked -- so if count is zero there is nothing to do and
            // `running` never asserts.
            val     <= operand & ((siz == 2'b01) ? 32'h0000_00FF
                               : (siz == 2'b10) ? 32'h0000_FFFF : 32'hFFFF_FFFF);
            rem     <= count;
            op_r    <= op;
            siz_r   <= siz;
            x_r     <= x_in;
            c_r     <= ((op == SHF_ROXL) || (op == SHF_ROXR)) ? x_in : 1'b0;
            v_r     <= 1'b0;
            running <= (count != 6'd0);
        end else if (running) begin
            rem <= rem - 6'd1;
            if (rem == 6'd1) running <= 1'b0;
            case (op_r)
                SHF_ASL:  begin val <= step_asl;  c_r <= msb_bit; x_r <= msb_bit;
                                if (asl_v_step) v_r <= 1'b1; end
                SHF_LSL:  begin val <= step_lsl;  c_r <= msb_bit; x_r <= msb_bit; end
                SHF_ASR:  begin val <= step_asr;  c_r <= lsb_bit; x_r <= lsb_bit; end
                SHF_LSR:  begin val <= step_lsr;  c_r <= lsb_bit; x_r <= lsb_bit; end
                // ROL and ROR do not touch X.
                SHF_ROL:  begin val <= step_rol;  c_r <= msb_bit; end
                SHF_ROR:  begin val <= step_ror;  c_r <= lsb_bit; end
                // Through X: the bit leaving becomes both the new X and C.
                SHF_ROXL: begin val <= step_roxl; c_r <= msb_bit; x_r <= msb_bit; end
                SHF_ROXR: begin val <= step_roxr; c_r <= lsb_bit; x_r <= lsb_bit; end
                default:  ;
            endcase
        end
    end

endmodule

`default_nettype wire

`default_nettype none

// MC68030 shift/rotate unit — purely combinational.
// Implements ASL/ASR, LSL/LSR, ROL/ROR, ROXL/ROXR for byte/word/long.
// All signals via assign to avoid "sorry: constant selects in always_*" in Icarus 13.

module eu_shifter (
    input  logic [31:0] operand,   // value to shift/rotate
    input  logic [5:0]  count,     // shift count (0-63)
    input  logic [3:0]  op,        // SHF_* operation
    input  logic [1:0]  siz,       // 00=long, 01=byte, 10=word
    input  logic        x_in,      // X flag (ROXL/ROXR uses it; others leave X←C)
    output logic [31:0] result,
    output logic        n_out,
    output logic        z_out,
    output logic        v_out,
    output logic        c_out,
    output logic        x_out      // new X; = c_out when count>0, = x_in when count=0
);

    localparam [3:0]
        SHF_ASL  = 4'h0,
        SHF_ASR  = 4'h1,
        SHF_LSL  = 4'h2,
        SHF_LSR  = 4'h3,
        SHF_ROL  = 4'h4,
        SHF_ROR  = 4'h5,
        SHF_ROXL = 4'h6,
        SHF_ROXR = 4'h7;

    // -----------------------------------------------------------------------
    // Size helpers
    // -----------------------------------------------------------------------
    logic [5:0]  size_bits;
    logic [31:0] result_mask, msb_mask;
    assign size_bits   = (siz == 2'b01) ? 6'd8  : (siz == 2'b10) ? 6'd16  : 6'd32;
    assign result_mask = (siz == 2'b01) ? 32'h0000_00FF :
                         (siz == 2'b10) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    assign msb_mask    = (siz == 2'b01) ? 32'h0000_0080 :
                         (siz == 2'b10) ? 32'h0000_8000 : 32'h8000_0000;

    logic [31:0] op_m;
    assign op_m = operand & result_mask;

    // -----------------------------------------------------------------------
    // Effective counts
    // -----------------------------------------------------------------------
    logic [5:0] eff_shift;  // clamped to size_bits for LSx/ASx
    logic [5:0] eff_rot;    // count mod size_bits  (size_bits is power-of-2)
    logic [5:0] eff_rox;    // count mod (size_bits+1)  for ROXx

    assign eff_shift = (count >= size_bits) ? size_bits : count;
    assign eff_rot   = count & (size_bits - 6'd1);
    assign eff_rox   = count % (size_bits + 6'd1);

    // -----------------------------------------------------------------------
    // Shift results
    // -----------------------------------------------------------------------
    logic [31:0] lsl_res, lsr_res, asr_res;
    logic        sign_bit;
    logic [31:0] asr_fill;

    assign lsl_res  = (op_m << eff_shift) & result_mask;
    assign lsr_res  = (op_m >> eff_shift) & result_mask;

    assign sign_bit = (op_m & msb_mask) != 32'h0;
    assign asr_fill = result_mask & ~(result_mask >> eff_shift); // top eff_shift bits
    assign asr_res  = ((op_m >> eff_shift) | (sign_bit ? asr_fill : 32'h0)) & result_mask;

    // -----------------------------------------------------------------------
    // Shift carries (last bit shifted out)
    // LSL/ASL: C = op_m[size_bits - eff_shift]  (variable shift; =0 when eff_shift=0)
    // LSR/ASR: C = op_m[eff_shift - 1]           (=0 when eff_shift=0)
    // -----------------------------------------------------------------------
    logic [31:0] lsl_c_raw, lsr_c_raw;
    logic        lsl_c_bit, lsr_c_bit;

    assign lsl_c_raw = op_m >> (size_bits - eff_shift);   // bit 0 = C for LSL/ASL
    assign lsr_c_raw = (eff_shift == 0) ? 32'h0 : (op_m >> (eff_shift - 6'd1));
    assign lsl_c_bit = (lsl_c_raw & 32'h1) != 32'h0;
    assign lsr_c_bit = (lsr_c_raw & 32'h1) != 32'h0;

    // -----------------------------------------------------------------------
    // ASL overflow: V=1 if any of the top (eff_shift+1) bits of op_m differ.
    // Mask covers bits [size_bits-1 : size_bits-1-eff_shift], i.e., eff_shift+1 bits.
    // -----------------------------------------------------------------------
    logic [31:0] asl_v_mask, asl_v_window;
    logic        asl_v;

    assign asl_v_mask   = result_mask & ~(result_mask >> (eff_shift + 6'd1));
    assign asl_v_window = op_m & asl_v_mask;
    assign asl_v        = (asl_v_window != 32'h0) && (asl_v_window != asl_v_mask);

    // -----------------------------------------------------------------------
    // Rotate results (ROL/ROR)
    // -----------------------------------------------------------------------
    logic [31:0] rol_res, ror_res;

    assign rol_res = ((op_m << eff_rot) | (op_m >> (size_bits - eff_rot))) & result_mask;
    assign ror_res = ((op_m >> eff_rot) | (op_m << (size_bits - eff_rot))) & result_mask;

    // ROL C = bit 0 of result; ROR C = MSB of result
    logic rol_c_bit, ror_c_bit;
    assign rol_c_bit = (rol_res & 32'h1) != 32'h0;
    assign ror_c_bit = (ror_res & msb_mask) != 32'h0;

    // -----------------------------------------------------------------------
    // Rotate-through-X results (ROXL/ROXR)
    // Extended (size_bits+1)-bit value: x_in at bit[size_bits], op_m at bits[size_bits-1:0].
    // -----------------------------------------------------------------------
    logic [32:0] rox_ext, rox_ext_mask;
    logic [5:0]  rox_period;

    assign rox_period  = size_bits + 6'd1;                          // 9, 17, or 33
    assign rox_ext     = (x_in ? (33'h1 << size_bits) : 33'h0) | {1'b0, op_m};
    assign rox_ext_mask = {1'b0, result_mask} | (33'h1 << size_bits);

    logic [32:0] roxl_ext_rot, roxr_ext_rot;
    assign roxl_ext_rot = ((rox_ext << eff_rox) | (rox_ext >> (rox_period - eff_rox))) & rox_ext_mask;
    assign roxr_ext_rot = ((rox_ext >> eff_rox) | (rox_ext << (rox_period - eff_rox))) & rox_ext_mask;

    logic [31:0] roxl_res, roxr_res;
    logic        roxl_c_bit, roxr_c_bit;

    assign roxl_res   = roxl_ext_rot[31:0] & result_mask;   // [31:0] range in assign: OK
    assign roxr_res   = roxr_ext_rot[31:0] & result_mask;
    assign roxl_c_bit = ((roxl_ext_rot >> size_bits) & 33'h1) != 33'h0;
    assign roxr_c_bit = ((roxr_ext_rot >> size_bits) & 33'h1) != 33'h0;

    // -----------------------------------------------------------------------
    // Output mux — no constant bit-selects inside always_comb
    // -----------------------------------------------------------------------
    always_comb begin
        // count=0 defaults: N/Z from operand, C=0, V=0, X unchanged
        result = op_m;
        n_out  = (op_m & msb_mask) != 32'h0;
        z_out  = (op_m == 32'h0);
        v_out  = 1'b0;
        c_out  = 1'b0;
        x_out  = x_in;

        if (count != 0) begin
            case (op)
                SHF_LSL: begin
                    result = lsl_res;
                    n_out  = (lsl_res & msb_mask) != 32'h0;
                    z_out  = (lsl_res == 32'h0);
                    c_out  = lsl_c_bit;
                    x_out  = lsl_c_bit;
                end
                SHF_ASL: begin
                    result = lsl_res;
                    n_out  = (lsl_res & msb_mask) != 32'h0;
                    z_out  = (lsl_res == 32'h0);
                    v_out  = asl_v;
                    c_out  = lsl_c_bit;
                    x_out  = lsl_c_bit;
                end
                SHF_LSR: begin
                    result = lsr_res;
                    n_out  = (lsr_res & msb_mask) != 32'h0;
                    z_out  = (lsr_res == 32'h0);
                    c_out  = lsr_c_bit;
                    x_out  = lsr_c_bit;
                end
                SHF_ASR: begin
                    result = asr_res;
                    n_out  = (asr_res & msb_mask) != 32'h0;
                    z_out  = (asr_res == 32'h0);
                    c_out  = lsr_c_bit;   // same last-bit-shifted-out as LSR
                    x_out  = lsr_c_bit;
                end
                SHF_ROL: begin
                    result = rol_res;
                    n_out  = (rol_res & msb_mask) != 32'h0;
                    z_out  = (rol_res == 32'h0);
                    c_out  = rol_c_bit;
                    // x_out = x_in (ROL does not update X)
                end
                SHF_ROR: begin
                    result = ror_res;
                    n_out  = (ror_res & msb_mask) != 32'h0;
                    z_out  = (ror_res == 32'h0);
                    c_out  = ror_c_bit;
                    // x_out = x_in (ROR does not update X)
                end
                SHF_ROXL: begin
                    result = roxl_res;
                    n_out  = (roxl_res & msb_mask) != 32'h0;
                    z_out  = (roxl_res == 32'h0);
                    c_out  = roxl_c_bit;
                    x_out  = roxl_c_bit;
                end
                SHF_ROXR: begin
                    result = roxr_res;
                    n_out  = (roxr_res & msb_mask) != 32'h0;
                    z_out  = (roxr_res == 32'h0);
                    c_out  = roxr_c_bit;
                    x_out  = roxr_c_bit;
                end
                default: ; // keep defaults
            endcase
        end
    end

endmodule

`default_nettype wire

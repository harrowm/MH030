`default_nettype none

// eu_bitfield — combinational bit-field unit.
//
// Phase 62 restriction: bf_offset + actual_width ≤ 32 (field fits in one 32-bit value).
// Bit ordering: bit 0 of the field is bf_data[31-bf_offset] (MSB side), per 68030 convention.
//
// bf_op encoding (= {f_dn[1:0], f_dir} from opcode):
//   000 = BFTST   set N/Z, no register output
//   001 = BFEXTU  extract zero-extended
//   010 = BFEXTS  extract sign-extended
//   011 = BFFFO   find first one (returns bit position of first 1 from MSB)
//   100 = BFCLR   clear field; result = modified data
//   110 = BFSET   set field; result = modified data
//   111 = BFINS   insert bf_src into field; result = modified data
//
// N/Z flags: set from original field for TST/EXTU/EXTS/FFO/CLR/SET;
//            set from inserted value for BFINS. V and C are always 0.

module eu_bitfield (
    input  logic [31:0] bf_data,        // register or memory longword
    input  logic [4:0]  bf_offset,      // field start bit from MSB (0-31)
    input  logic [4:0]  bf_raw_width,   // raw width (0=32, 1-31)
    input  logic [31:0] bf_src,         // BFINS: value to insert
    input  logic [2:0]  bf_op,
    output logic [31:0] bf_result,      // EXTU/EXTS/FFO: extracted; CLR/SET/INS: modified data
    output logic        bf_n,
    output logic        bf_z,
    output logic        bf_v,
    output logic        bf_c
);

    // Actual width (0 encodes 32)
    logic [5:0] actual_width;
    assign actual_width = (bf_raw_width == 5'h0) ? 6'd32 : {1'b0, bf_raw_width};

    // Right-shift to place field at LSB: shift = 32 - offset - width
    logic [5:0] shift_right;
    assign shift_right = 6'd32 - {1'b0, bf_offset} - actual_width;

    // Width mask (actual_width lower bits set); use 33-bit to avoid overflow at width=32
    logic [32:0] mask33;
    assign mask33 = (33'h1 << actual_width) - 33'h1;
    logic [31:0] width_mask;
    assign width_mask = mask33[31:0];

    // Extract field right-justified
    logic [31:0] field;
    assign field = (bf_data >> shift_right) & width_mask;

    // Sign bit mask: bit (actual_width-1) of field
    logic [31:0] sign_bit_mask;
    assign sign_bit_mask = 32'h1 << (actual_width - 6'd1);

    // For BFINS: N/Z come from the inserted value (bf_src & mask), not the original field
    logic [31:0] flag_field;
    assign flag_field = (bf_op == 3'b111) ? (bf_src & width_mask) : field;

    assign bf_n = |(flag_field & sign_bit_mask);
    assign bf_z = (flag_field == 32'h0);
    assign bf_v = 1'b0;
    assign bf_c = 1'b0;

    // Sign extension mask for BFEXTS
    logic [31:0] exts_sign_mask;
    assign exts_sign_mask = bf_n ? ~width_mask : 32'h0;

    // In-position field mask and placed source (for modify ops)
    logic [31:0] field_pos_mask;
    assign field_pos_mask = width_mask << shift_right;
    logic [31:0] src_placed;
    assign src_placed = (bf_src & width_mask) << shift_right;

    // BFFFO: find first 1 from MSB of field.
    // Iterating k 0→31: k=actual_width-1 is the MSB of field.
    // Higher k (closer to MSB) wins last-write in the for loop → gives BFFFO correct answer.
    logic [31:0] ffo_result;
    always_comb begin
        ffo_result = {27'h0, bf_offset} + {1'b0, actual_width};  // default: no 1 found
        for (int k = 0; k < 32; k++) begin
            if (k < actual_width && field[k])
                ffo_result = {27'h0, bf_offset} + 32'(actual_width) - 32'd1 - 32'(k);
        end
    end

    always_comb begin
        case (bf_op)
            3'b000:  bf_result = 32'h0;                              // BFTST: no reg output
            3'b001:  bf_result = field;                              // BFEXTU: zero-extended
            3'b010:  bf_result = field | exts_sign_mask;             // BFEXTS: sign-extended
            3'b011:  bf_result = ffo_result;                         // BFFFO
            3'b100:  bf_result = bf_data & ~field_pos_mask;          // BFCLR
            3'b110:  bf_result = bf_data |  field_pos_mask;          // BFSET
            3'b111:  bf_result = (bf_data & ~field_pos_mask) | src_placed; // BFINS
            default: bf_result = 32'h0;
        endcase
    end

endmodule

`default_nettype wire

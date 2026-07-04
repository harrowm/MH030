`default_nettype none

// MC68030 bit-manipulation unit — purely combinational.
//
// Implements BTST / BCHG / BCLR / BSET on a 32-bit register operand.
// Z flag reflects the OLD bit value (before modification):
//   Z = 1 if the selected bit was 0, Z = 0 if the selected bit was 1.
// Only Z is updated; N, V, C, X are unchanged (caller preserves them).
//
// bit_num: for Dn destinations the caller supplies bit_num[4:0] (mod 32
//   applied by the regfile read); for memory destinations the hardware
//   masks to bit_num[2:0] (mod 8), but memory EA is not handled here.

module eu_bitops (
    input  logic [31:0] dst,       // destination register (full 32-bit)
    input  logic [4:0]  bit_num,   // bit position (0-31)
    input  logic [1:0]  op,        // 00=BTST  01=BCHG  10=BCLR  11=BSET
    output logic [31:0] result,
    output logic        z_out      // 1 if original bit was 0
);
    localparam [1:0] BIT_TST=2'b00, BIT_CHG=2'b01, BIT_CLR=2'b10, BIT_SET=2'b11;

    logic [31:0] mask;
    assign mask  = 32'h1 << bit_num;

    logic bit_val;
    assign bit_val = |(dst & mask);   // value of selected bit before op
    assign z_out   = ~bit_val;

    always_comb begin
        case (op)
            BIT_TST: result = dst;
            BIT_CHG: result = dst ^ mask;
            BIT_CLR: result = dst & ~mask;
            BIT_SET: result = dst | mask;
        endcase
    end

endmodule

`default_nettype wire

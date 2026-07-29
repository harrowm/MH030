`timescale 1ns/1ps
`default_nettype none

// MC68030 BCD arithmetic unit — purely combinational.
//
// Implements ABCD (add), SBCD (subtract), NBCD (negate).
// All operate byte-wide only (8-bit src/dst).
//
// Algorithms match Musashi's implementation exactly, including behavior
// for invalid BCD inputs (nibbles > 9).
//
// BCD Z-flag rule: Z is only cleared, never set.
//   z_out = z_in & (result == 0)
// C/X flag: set if decimal carry (ABCD) or borrow (SBCD/NBCD) occurred.

module eu_bcd (
    input  logic [7:0]  src,    // source byte (NBCD ignores: src treated as 0)
    input  logic [7:0]  dst,    // destination byte (NBCD: value to negate)
    input  logic [1:0]  op,     // 00=ABCD  01=SBCD  10=NBCD
    input  logic        x_in,   // X flag in (extend)
    input  logic        z_in,   // Z flag in (accumulated zero)
    output logic [7:0]  result,
    output logic        c_out,
    output logic        x_out,  // always equals c_out for BCD ops
    output logic        z_out
);
    localparam [1:0] BCD_ADD = 2'b00, BCD_SUB = 2'b01, BCD_NEG = 2'b10;

    // -----------------------------------------------------------------------
    // ABCD: dst + src + X  (Musashi-accurate)
    // Algorithm: compute low-nibble sum, apply correction if > 9,
    // then add high nibbles in position; carry = result > 0x99.
    // -----------------------------------------------------------------------
    logic [4:0] add_lo;
    assign add_lo = {1'b0, dst[3:0]} + {1'b0, src[3:0]} + {4'b0, x_in};

    logic        add_lc;
    assign add_lc = (add_lo > 5'd9);

    logic [8:0] add_bin;
    assign add_bin = {1'b0, dst} + {1'b0, src} + {8'b0, x_in};

    logic [8:0] add_adj1;
    assign add_adj1 = add_lc ? (add_bin + 9'd6) : add_bin;

    // Carry condition matches Musashi: res > 0x99 (not just bit[8] or high-nibble > 9).
    // This correctly handles invalid BCD inputs where adj1 is in 0x9A-0x9F.
    logic add_hc;
    assign add_hc = (add_adj1 > 9'h099);

    logic [8:0] add_adj2;
    assign add_adj2 = add_hc ? (add_adj1 + 9'h060) : add_adj1;  // +0x60 ≡ -0xA0 mod 256

    logic [7:0] add_res; assign add_res = add_adj2[7:0];
    logic       add_c;   assign add_c   = add_hc;

    // -----------------------------------------------------------------------
    // SBCD / NBCD: dst_s - src_s - X  (Musashi-accurate, 16-bit intermediates)
    //
    // Musashi algorithm (C, 32-bit unsigned):
    //   res = LOW(dst) - LOW(src) - X
    //   if (res > 9) res -= 6               // low correction
    //   res += HIGH_NIBBLE(dst) - HIGH_NIBBLE(src)   // HIGH = x & 0xF0 (in position)
    //   carry = (res > 0x99)
    //   if (carry) res += 0xA0
    //   result = res & 0xFF
    //
    // 16-bit arithmetic naturally replicates the 32-bit wrapping behavior for
    // all inputs in the 0x00–0xFF range that the test exercises.
    // -----------------------------------------------------------------------
    logic [7:0] sub_s, sub_d;
    assign sub_s = (op == BCD_NEG) ? dst  : src;   // NBCD: src=dst, dst=0
    assign sub_d = (op == BCD_NEG) ? 8'h0 : dst;

    // Step 1: low-nibble subtraction (16-bit to handle unsigned-wrapping borrow)
    logic [15:0] sbcd_lo;
    assign sbcd_lo = {12'h0, sub_d[3:0]} - {12'h0, sub_s[3:0]} - {15'h0, x_in};

    // Low correction: if sbcd_lo > 9 (catches borrow and invalid BCD nibble > 9)
    logic [15:0] sbcd_lo_adj;
    assign sbcd_lo_adj = (sbcd_lo > 16'h0009) ? (sbcd_lo - 16'd6) : sbcd_lo;

    // Step 2: add high nibbles in position (16-bit)
    logic [15:0] sbcd_mid;
    assign sbcd_mid = sbcd_lo_adj + {8'h0, sub_d[7:4], 4'h0} - {8'h0, sub_s[7:4], 4'h0};

    // Carry: result > 0x99 (catches borrow via 16-bit wrap and invalid BCD overflow)
    logic sub_hc;
    assign sub_hc = (sbcd_mid > 16'h0099);

    // High correction: add 0xA0 (matches Musashi)
    logic [15:0] sbcd_adj;
    assign sbcd_adj = sub_hc ? (sbcd_mid + 16'h00A0) : sbcd_mid;

    logic [7:0] sub_res; assign sub_res = sbcd_adj[7:0];
    logic       sub_c;   assign sub_c   = sub_hc;

    // -----------------------------------------------------------------------
    // Output mux
    // -----------------------------------------------------------------------
    always_comb begin
        if (op == BCD_ADD) begin
            result = add_res;
            c_out  = add_c;
        end else begin
            result = sub_res;
            c_out  = sub_c;
        end
        x_out = c_out;
        z_out = z_in & (result == 8'h00);
    end

endmodule

`default_nettype wire

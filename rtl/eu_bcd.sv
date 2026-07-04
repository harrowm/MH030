`default_nettype none

// MC68030 BCD arithmetic unit — purely combinational.
//
// Implements ABCD (add), SBCD (subtract), NBCD (negate).
// All operate byte-wide only (8-bit src/dst).
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
    // ABCD: dst + src + X
    // -----------------------------------------------------------------------
    // Low-nibble carry: if raw low-nibble sum > 9 → add 6 correction
    logic [4:0] add_lo;
    assign add_lo  = {1'b0, dst[3:0]} + {1'b0, src[3:0]} + {4'b0, x_in};
    logic        add_lc;
    assign add_lc  = (add_lo > 5'd9);

    logic [8:0] add_bin;
    assign add_bin = {1'b0, dst} + {1'b0, src} + {8'b0, x_in};

    logic [8:0] add_adj1;
    assign add_adj1 = add_lc ? (add_bin + 9'd6) : add_bin;

    logic add_hc;
    assign add_hc = add_adj1[8] | (add_adj1[7:4] > 4'd9);

    logic [8:0] add_adj2;
    assign add_adj2 = add_hc ? (add_adj1 + 9'h060) : add_adj1;

    logic [7:0] add_res; assign add_res = add_adj2[7:0];
    logic       add_c;   assign add_c   = add_hc;

    // -----------------------------------------------------------------------
    // SBCD / NBCD: dst_s - src_s - X
    // NBCD: src_s=dst, dst_s=0  (negate dst)
    // SBCD: src_s=src, dst_s=dst
    // -----------------------------------------------------------------------
    logic [7:0] sub_s, sub_d;
    assign sub_s = (op == BCD_NEG) ? dst  : src;
    assign sub_d = (op == BCD_NEG) ? 8'h0 : dst;

    logic [4:0] sub_lo_rhs;
    assign sub_lo_rhs = {1'b0, sub_s[3:0]} + {4'b0, x_in};
    logic sub_lc;
    assign sub_lc = ({1'b0, sub_d[3:0]} < sub_lo_rhs);

    logic [8:0] sub_bin;
    assign sub_bin = {1'b0, sub_d} - {1'b0, sub_s} - {8'b0, x_in};

    logic [8:0] sub_adj1;
    assign sub_adj1 = sub_lc ? (sub_bin - 9'd6) : sub_bin;

    logic sub_hc;
    assign sub_hc = sub_adj1[8];

    logic [8:0] sub_adj2;
    assign sub_adj2 = sub_hc ? (sub_adj1 - 9'h060) : sub_adj1;

    logic [7:0] sub_res; assign sub_res = sub_adj2[7:0];
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

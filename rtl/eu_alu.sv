`default_nettype none

// MC68030 ALU — purely combinational
//
// Implements ADD/ADDX, SUB/SUBX, NEG/NEGX, CMP, AND, OR, EOR, NOT, TST, CLR.
// All outputs are purely combinational (no flip-flops).
// Upper bits of result are zeroed for byte/word operations; eu_regfile's
// write logic preserves upper bits of Dn on sub-32-bit register writes.
//
// Operation codes (ALU_*) must match what the sequencer drives on `op`.

module eu_alu (
    input  logic [31:0] src,       // source (B) operand
    input  logic [31:0] dst,       // destination (A) operand
    input  logic [3:0]  op,        // ALU_* operation
    input  logic [1:0]  siz,       // 00=long, 01=byte, 10=word
    input  logic        x_in,      // current X flag (for ADDX/SUBX/NEGX)
    input  logic        z_in,      // current Z flag (ADDX/SUBX/NEGX preserve Z if result=0)

    output logic [31:0] result,    // ALU result (upper bits 0 for byte/word ops)
    output logic        n_out,
    output logic        z_out,
    output logic        v_out,
    output logic        c_out,
    output logic        x_out      // new X; = c_out for arith ops; = x_in for logic/CMP
);

    // -----------------------------------------------------------------------
    // Operation codes (used by sequencer; replicate in any module that drives op)
    // -----------------------------------------------------------------------
    localparam [3:0]
        ALU_ADD  = 4'h0,   // dst + src
        ALU_ADDX = 4'h1,   // dst + src + X
        ALU_SUB  = 4'h2,   // dst - src
        ALU_SUBX = 4'h3,   // dst - src - X
        ALU_NEG  = 4'h4,   // 0  - dst
        ALU_NEGX = 4'h5,   // 0  - dst - X
        ALU_AND  = 4'h6,   // dst & src
        ALU_OR   = 4'h7,   // dst | src
        ALU_EOR  = 4'h8,   // dst ^ src
        ALU_NOT  = 4'h9,   // ~dst
        ALU_CMP  = 4'hA,   // dst - src  (flags only; X unchanged)
        ALU_TST  = 4'hB,   // test dst   (N,Z; V=C=0; X unchanged)
        ALU_CLR  = 4'hC;   // 0          (Z=1; N=V=C=0; X unchanged)

    // -----------------------------------------------------------------------
    // Size-masked operands and helper masks — all via assign to avoid
    // "sorry: constant selects in always_* processes" in Icarus 13
    // -----------------------------------------------------------------------
    logic [31:0] src_m, dst_m, result_mask, msb_mask;

    assign src_m      = (siz == 2'b01) ? {24'b0, src[7:0]}  :
                        (siz == 2'b10) ? {16'b0, src[15:0]} : src;
    assign dst_m      = (siz == 2'b01) ? {24'b0, dst[7:0]}  :
                        (siz == 2'b10) ? {16'b0, dst[15:0]} : dst;
    assign result_mask = (siz == 2'b01) ? 32'h0000_00FF :
                         (siz == 2'b10) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
    assign msb_mask    = (siz == 2'b01) ? 32'h0000_0080 :
                         (siz == 2'b10) ? 32'h0000_8000 : 32'h8000_0000;

    // -----------------------------------------------------------------------
    // Adder (handles ADD/ADDX, SUB/SUBX/CMP, NEG/NEGX)
    //
    // ADD:   a = dst,  b = src,  cin = 0
    // ADDX:  a = dst,  b = src,  cin = X
    // SUB:   a = dst,  b = ~src, cin = 1   (two's complement: dst + ~src + 1)
    // SUBX:  a = dst,  b = ~src, cin = ~X  (dst - src - X)
    // CMP:   a = dst,  b = ~src, cin = 1   (identical to SUB)
    // NEG:   a = 0,    b = ~dst, cin = 1   (0 - dst)
    // NEGX:  a = 0,    b = ~dst, cin = ~X  (0 - dst - X)
    // -----------------------------------------------------------------------
    logic [32:0] add_a, add_b;
    logic        add_cin;
    logic [32:0] add_sum;

    assign add_a   = (op == ALU_NEG || op == ALU_NEGX) ? 33'h0
                                                        : {1'b0, dst_m};
    // For SUB/NEG, invert only the active byte/word bits so upper zeros
    // don't corrupt the carry bit at position 8 or 16.
    assign add_b   = (op == ALU_ADD || op == ALU_ADDX) ? {1'b0,  src_m}
                   : (op == ALU_NEG || op == ALU_NEGX) ? {1'b0, ~dst_m & result_mask}
                                                        : {1'b0, ~src_m & result_mask};
    assign add_cin = (op == ALU_ADD)  ? 1'b0   :
                     (op == ALU_ADDX) ? x_in   :
                     (op == ALU_NEGX) ? ~x_in  :
                     (op == ALU_SUBX) ? ~x_in  : 1'b1;  // SUB, CMP, NEG: cin=1

    assign add_sum = add_a + add_b + {32'b0, add_cin};

    // Carry extracted at the correct bit position for the operation size.
    // For ADD: C = carry-out (set on unsigned overflow).
    // For SUB/NEG: C = NOT(carry-out) = borrow (set when dst < src, unsigned).
    logic carry_raw;
    assign carry_raw = (siz == 2'b01) ? add_sum[8]  :
                       (siz == 2'b10) ? add_sum[16] : add_sum[32];

    logic [31:0] arith_result;
    assign arith_result = add_sum[31:0] & result_mask;

    // MSB signals for overflow and N-flag computation
    logic src_msb, dst_msb, res_msb;
    assign src_msb = (siz == 2'b01) ? src_m[7]         :
                     (siz == 2'b10) ? src_m[15]        : src_m[31];
    assign dst_msb = (siz == 2'b01) ? dst_m[7]         :
                     (siz == 2'b10) ? dst_m[15]        : dst_m[31];
    assign res_msb = (siz == 2'b01) ? arith_result[7]  :
                     (siz == 2'b10) ? arith_result[15] : arith_result[31];

    // Pre-computed logical results (avoids computing them inside always_comb)
    logic [31:0] and_res, or_res, eor_res, not_res;
    assign and_res = dst_m & src_m;
    assign or_res  = dst_m | src_m;
    assign eor_res = dst_m ^ src_m;
    assign not_res = ~dst_m & result_mask;

    // -----------------------------------------------------------------------
    // Output mux — uses only pre-computed signals, no constant bit-selects
    // -----------------------------------------------------------------------
    always_comb begin
        // Safe defaults (overridden below)
        result = 32'h0;
        n_out  = 1'b0;
        z_out  = 1'b1;
        v_out  = 1'b0;
        c_out  = 1'b0;
        x_out  = x_in;   // logic ops and CMP leave X unchanged

        case (op)
            ALU_ADD: begin
                result = arith_result;
                n_out  = res_msb;
                z_out  = (arith_result == 32'h0);
                v_out  = (src_msb == dst_msb) && (res_msb != dst_msb);
                c_out  = carry_raw;
                x_out  = carry_raw;
            end
            ALU_ADDX: begin
                result = arith_result;
                n_out  = res_msb;
                // ADDX: Z cleared if nonzero; unchanged (z_in) if zero
                z_out  = (arith_result != 32'h0) ? 1'b0 : z_in;
                v_out  = (src_msb == dst_msb) && (res_msb != dst_msb);
                c_out  = carry_raw;
                x_out  = carry_raw;
            end
            ALU_SUB: begin
                result = arith_result;
                n_out  = res_msb;
                z_out  = (arith_result == 32'h0);
                v_out  = (dst_msb != src_msb) && (res_msb != dst_msb);
                c_out  = ~carry_raw;   // borrow convention
                x_out  = ~carry_raw;
            end
            ALU_SUBX: begin
                result = arith_result;
                n_out  = res_msb;
                // SUBX: Z cleared if nonzero; unchanged if zero
                z_out  = (arith_result != 32'h0) ? 1'b0 : z_in;
                v_out  = (dst_msb != src_msb) && (res_msb != dst_msb);
                c_out  = ~carry_raw;
                x_out  = ~carry_raw;
            end
            ALU_NEG: begin
                result = arith_result;
                n_out  = res_msb;
                z_out  = (arith_result == 32'h0);
                v_out  = dst_msb & res_msb;    // only 0x80/8000/80000000 overflows
                c_out  = ~carry_raw;
                x_out  = ~carry_raw;
            end
            ALU_NEGX: begin
                result = arith_result;
                n_out  = res_msb;
                // NEGX: Z cleared if nonzero; unchanged if zero
                z_out  = (arith_result != 32'h0) ? 1'b0 : z_in;
                v_out  = dst_msb & res_msb;
                c_out  = ~carry_raw;
                x_out  = ~carry_raw;
            end
            ALU_CMP: begin   // flags as SUB; X unchanged
                result = arith_result;
                n_out  = res_msb;
                z_out  = (arith_result == 32'h0);
                v_out  = (dst_msb != src_msb) && (res_msb != dst_msb);
                c_out  = ~carry_raw;
                // x_out = x_in (default)
            end
            ALU_AND: begin
                result = and_res;
                n_out  = (and_res & msb_mask) != 32'h0;
                z_out  = (and_res == 32'h0);
            end
            ALU_OR: begin
                result = or_res;
                n_out  = (or_res & msb_mask) != 32'h0;
                z_out  = (or_res == 32'h0);
            end
            ALU_EOR: begin
                result = eor_res;
                n_out  = (eor_res & msb_mask) != 32'h0;
                z_out  = (eor_res == 32'h0);
            end
            ALU_NOT: begin
                result = not_res;
                n_out  = (not_res & msb_mask) != 32'h0;
                z_out  = (not_res == 32'h0);
            end
            ALU_TST: begin
                result = dst_m;
                n_out  = dst_msb;
                z_out  = (dst_m == 32'h0);
                // v=0, c=0, x=x_in (defaults)
            end
            ALU_CLR: begin
                result = 32'h0;
                z_out  = 1'b1;
                // n=0, v=0, c=0, x=x_in (defaults)
            end
            default: begin
                result = dst_m;
                n_out  = dst_msb;
                z_out  = (dst_m == 32'h0);
            end
        endcase
    end

endmodule

`default_nettype wire

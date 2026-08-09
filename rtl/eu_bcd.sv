`timescale 1ns/1ps
`default_nettype none

// MC68030 BCD arithmetic unit — purely combinational.
//
// Implements ABCD (add), SBCD (subtract), NBCD (negate).
// All operate byte-wide only (8-bit src/dst).
//
// N and V are officially "undefined" per the 68k PRM for these three
// instructions, but real silicon produces specific, deterministic values
// (a side effect of the internal BCD-correction adder) that the Tom Harte
// SingleStepTests corpus captures and checks. The formulas below were
// reverse-engineered empirically against that corpus (every register-direct
// test vector in ABCD.json.gz/SBCD.json.gz/NBCD.json.gz — 4004/3948/1315
// cases respectively) since Musashi's own "undefined behavior" replication
// (m68kops.c) does not match real hardware for either flag, nor for the
// result byte itself in SBCD/NBCD's invalid-BCD-digit edge cases (see
// plan.md Phase 91 for the full derivation writeup). Verified: N, V, C, and
// result all match 100% of register-direct test vectors with the formulas
// implemented here.
//
// Key findings vs. the naive/Musashi approach:
//   - The low-nibble decimal correction must be gated by a true signed
//     borrow (dst_lo - src_lo - X < 0), not by "raw digit > 9" — those
//     differ whenever an operand has an invalid BCD nibble (10-15).
//   - The high-nibble carry/borrow (C/X, and whether the final +-0xA0
//     correction fires) must be a true signed check on the nibble-combined
//     value, not a magnitude threshold like ">0x99" (ABCD) or a plain
//     byte-level comparison (SBCD/NBCD) — those also diverge on invalid
//     BCD digit inputs.
//   - N = bit 7 of the final (corrected) result byte.
//   - V = N & ~(bit 7 of the UNCORRECTED nibble-combined sum) for ABCD;
//     V = ~N & (bit 7 of the UNCORRECTED nibble-combined difference) for
//     SBCD/NBCD. "Uncorrected" means before the low-nibble decimal
//     adjustment is folded in — i.e. it's simply the plain binary
//     dst+src+X (ABCD) or dst-src-X (SBCD/NBCD), since nibble
//     decomposition is exact before any BCD correction is applied.
//
// BCD Z-flag rule: Z is only cleared, never set.
//   z_out = z_in & (result == 0)

module eu_bcd (
    input  logic [7:0]  src,    // source byte (NBCD ignores: src treated as 0)
    input  logic [7:0]  dst,    // destination byte (NBCD: value to negate)
    input  logic [1:0]  op,     // 00=ABCD  01=SBCD  10=NBCD
    input  logic        x_in,   // X flag in (extend)
    input  logic        z_in,   // Z flag in (accumulated zero)
    output logic [7:0]  result,
    output logic        c_out,
    output logic        x_out,  // always equals c_out for BCD ops
    output logic        z_out,
    output logic        n_out,
    output logic        v_out
);
    localparam [1:0] BCD_ADD = 2'b00, BCD_SUB = 2'b01, BCD_NEG = 2'b10;

    // -----------------------------------------------------------------------
    // ABCD: dst + src + X
    // -----------------------------------------------------------------------
    logic [4:0] add_lo;
    assign add_lo = {1'b0, dst[3:0]} + {1'b0, src[3:0]} + {4'b0, x_in};

    // Low-nibble correction is a true carry-out of the nibble add (>9), which
    // for addition coincides with Musashi's magnitude check — no discrepancy
    // here (unlike the subtraction case below).
    logic        add_lc;
    assign add_lc = (add_lo > 5'd9);

    // add_bin = plain binary dst+src+X, uncorrected — algebraically identical
    // to add_lo + HIGH(dst) + HIGH(src) (nibble decomposition is exact before
    // any BCD correction), so this doubles as the "prelo" reference for V.
    logic [8:0] add_bin;
    assign add_bin = {1'b0, dst} + {1'b0, src} + {8'b0, x_in};

    // add_bin (max 0x1FF) + 6 can reach 0x205 — needs 10 bits, not 9; a 9-bit
    // add_adj1 silently wraps for invalid-BCD-digit inputs near the top of
    // add_bin's range (found via Tom Harte test cf00 [ABCD D0,D7]: D0=0xff,
    // D7=0xfb produced add_bin=0x1fa, add_adj1=0x200, which wrapped to 0x000
    // in a 9-bit field and corrupted the result from the correct 0x60 to 0x00).
    logic [9:0] add_adj1;
    assign add_adj1 = add_lc ? ({1'b0, add_bin} + 10'd6) : {1'b0, add_bin};

    // High-nibble carry: true threshold is >=0xA0, not Musashi's >0x99 — the
    // 0x9A-0x9F band only arises from invalid BCD digits (>9) surviving into
    // this stage, and real hardware does NOT correct for it (verified: fixes
    // 28/4004 C-flag mismatches against Tom Harte with zero regressions).
    logic add_hc;
    assign add_hc = (add_adj1 >= 10'h0A0);

    logic [9:0] add_adj2;
    assign add_adj2 = add_hc ? (add_adj1 - 10'h0A0) : add_adj1;

    logic [7:0] add_res; assign add_res = add_adj2[7:0];
    logic       add_c;   assign add_c   = add_hc;
    logic       add_n;   assign add_n   = add_res[7];
    // V = N & NOT(bit7 of the uncorrected binary sum) — verified 0 mismatches
    // across all 4004 register-direct ABCD.json.gz vectors.
    logic       add_v;   assign add_v   = add_n & ~add_bin[7];

    // -----------------------------------------------------------------------
    // SBCD / NBCD: dst_s - src_s - X
    //
    // Signed intermediates throughout (unlike the old unsigned/Musashi-style
    // magnitude-threshold approach) because the correct correction triggers
    // are true borrows, not raw-digit-magnitude checks — the two diverge
    // whenever an operand nibble is > 9 (invalid BCD digit), which the Tom
    // Harte corpus deliberately exercises. Verified: N, V, C, and result all
    // match 100% of the 3948 register-direct SBCD.json.gz vectors and all
    // 1315 register-direct NBCD.json.gz vectors with this formulation.
    // -----------------------------------------------------------------------
    logic [7:0] sub_s, sub_d;
    assign sub_s = (op == BCD_NEG) ? dst  : src;   // NBCD: src=dst, dst=0
    assign sub_d = (op == BCD_NEG) ? 8'h0 : dst;

    // Step 1: low-nibble subtraction, true signed borrow (not "raw > 9").
    logic signed [5:0] sbcd_lo_s;
    assign sbcd_lo_s = $signed({2'b0, sub_d[3:0]}) - $signed({2'b0, sub_s[3:0]})
                      - $signed({5'b0, x_in});

    logic sbcd_borrow_lo;
    assign sbcd_borrow_lo = sbcd_lo_s[5];   // sign bit: true iff negative

    logic signed [5:0] sbcd_loc;
    assign sbcd_loc = sbcd_borrow_lo ? (sbcd_lo_s - 6'sd6) : sbcd_lo_s;

    // Step 2: add high nibbles in position (signed, low-corrected).
    // NOTE: {4'b0, sbcd_loc} is a concatenation, NOT a sign-extension — it
    // would zero-pad a negative sbcd_loc into a large positive garbage value.
    // Must replicate the sign bit explicitly.
    logic signed [9:0] sbcd_s2;
    assign sbcd_s2 = $signed({{4{sbcd_loc[5]}}, sbcd_loc}) + $signed({2'b0, sub_d[7:4], 4'b0})
                    - $signed({2'b0, sub_s[7:4], 4'b0});

    // High-nibble borrow: true signed check (s2 < 0), not a byte-level
    // dst<src+X comparison — those diverge when the low-nibble correction
    // alone pushes the combined value negative despite dst_byte >= src_byte.
    logic sbcd_borrow_hi;
    assign sbcd_borrow_hi = sbcd_s2[9];

    logic signed [9:0] sbcd_s3;
    assign sbcd_s3 = sbcd_borrow_hi ? (sbcd_s2 + 10'sh0A0) : sbcd_s2;

    logic [7:0] sub_res; assign sub_res = sbcd_s3[7:0];
    logic       sub_c;   assign sub_c   = sbcd_borrow_hi;
    logic       sub_n;   assign sub_n   = sub_res[7];

    // Uncorrected (pre-low-correction) nibble-combined difference — the
    // "prelo" reference for V, algebraically dst-src-X exactly (same
    // nibble-decomposition identity as ABCD's add_bin).
    logic signed [9:0] sbcd_s2_prelo;
    assign sbcd_s2_prelo = $signed({{4{sbcd_lo_s[5]}}, sbcd_lo_s}) + $signed({2'b0, sub_d[7:4], 4'b0})
                          - $signed({2'b0, sub_s[7:4], 4'b0});
    // V = NOT(N) & (bit7 of the uncorrected difference's low byte).
    logic       sub_v;   assign sub_v   = ~sub_n & sbcd_s2_prelo[7];

    // -----------------------------------------------------------------------
    // Output mux
    // -----------------------------------------------------------------------
    always_comb begin
        if (op == BCD_ADD) begin
            result = add_res;
            c_out  = add_c;
            n_out  = add_n;
            v_out  = add_v;
        end else begin
            result = sub_res;
            c_out  = sub_c;
            n_out  = sub_n;
            v_out  = sub_v;
        end
        x_out = c_out;
        z_out = z_in & (result == 8'h00);
    end

endmodule

`default_nettype wire

`default_nettype none

// =============================================================================
// MH030-P bit-field unit: SEQUENTIAL, two fixed 32-tick passes.
//
// *** NOT CURRENTLY INSTANTIATED. *** mh030p_core.sv uses rtl/eu_bitfield.sv.
// This module is complete, and proven equivalent to it over 50,688 vectors by
// tb/bf_equiv_tb.sv (which is in `make test`, so it cannot rot) -- but it was
// measured and did NOT pay:
//
//     arm                      n  mean    min    max
//     combinational eu_bitfield 9  29.16  28.39  30.14
//     this module               9  28.29  27.26  29.38
//
// The ranges overlap heavily, 7 of 9 seeds are lower, and the mean is 0.87 MHz
// down -- unresolved and leaning negative, against a real cost of ~66 ticks per
// bit-field instruction. Kept rather than deleted because it is finished and
// verified, and because the reason it failed where the shifter succeeded is
// informative: the shifter went 2,084 -> 220 cells with almost no new state,
// while this goes 1,459 -> 845 and adds 324 flip-flops (nine 32-bit registers),
// leaving a combinational output mux that still computes ~pmask, ^pmask, |pmask
// and the FFO arithmetic. Removing variable shifters only wins if you do not
// spend the depth again on the way out.
//
// A version that kept less state might pay. That would be the thing to try if
// this is revisited.
//
// BFTST/BFEXTU/BFCHG/BFEXTS/BFCLR/BFFFO/BFSET/BFINS, producing values and flags
// IDENTICAL to rtl/eu_bitfield.sv, which stays the reference and is untouched.
// tb/bf_equiv_tb.sv proves the equivalence by exhaustive sweep.
//
// WHY SEQUENTIAL. eu_bitfield is combinational and pays for it twice over:
//   * FIVE variable-distance shifters -- `(1<<aw)-1`, `data >> sr`,
//     `1 << (aw-1)`, `wmask << sr` and `(src & wmask) << sr`.
//   * A 32-deep FFO priority chain, whose loop body also contains a 32-bit
//     subtract per iteration.
// 1,459 combinational cells, re-evaluating every cycle whether or not the
// instruction is a bit-field one. The sequential form below contains **no
// variable shift and no priority chain at all**: every step is a fixed 1-bit
// shift, which the synthesiser gets as wiring.
//
// This is the same lever that took the shifter from 2,084 cells to 220 and the
// core from 21.60 to 29.16 MHz -- see feedback_sequentialise_always_evaluating_
// blocks. Bit-field instructions are rare and MC68030UM already makes them slow,
// so 64 ticks is an acceptable price.
//
// HOW THE VARIABLE SHIFTS ARE AVOIDED
//   pass 1, k = 0..31:  wmask <= (wmask<<1)|1  while k < aw   -> (1<<aw)-1
//                       dsh   <= dsh >> 1      while k < sr   -> data >> sr
//   pass 2, k = 0..31:  pmask <= pmask << 1    while k < sr   -> wmask << sr
//                       splc  <= splc  << 1    while k < sr   -> (src&wmask)<<sr
//                       fsh   <= fsh   >> 1    while k < aw   -> scans the field
//
// The field scan in pass 2 does double duty. Shifting right and recording k
// whenever the outgoing bit is 1 leaves the HIGHEST set bit index, because a
// later write wins -- which is exactly the semantics of the reference's own
// for-loop comment. The same scan yields N: the sign bit is bit aw-1, which is
// the last bit the scan examines.
//
// The scan runs on flag_field, not on field, because BFINS takes N and Z from
// the value being inserted rather than from the field it overwrites -- and BFFFO
// is never BFINS, so the two uses cannot conflict.
//
// eu_bitfield's restriction holds here too: offset + width <= 32, so sr >= 0.
// =============================================================================

module mh030p_bitfield (
    input  wire        clk_4x,
    input  wire        rst_n,

    // One-tick start; everything is latched here.
    input  wire        start,
    output wire        busy,

    input  wire [31:0] bf_data,
    input  wire [4:0]  bf_offset,
    input  wire [4:0]  bf_raw_width,
    input  wire [31:0] bf_src,
    input  wire [2:0]  bf_op,

    output wire [31:0] bf_result,
    output wire        bf_n,
    output wire        bf_z,
    output wire        bf_v,
    output wire        bf_c
);

    localparam [2:0] BF_TST  = 3'b000, BF_EXTU = 3'b001, BF_CHG = 3'b010,
                     BF_EXTS = 3'b011, BF_CLR  = 3'b100, BF_FFO = 3'b101,
                     BF_SET  = 3'b110, BF_INS  = 3'b111;

    localparam [1:0] ST_IDLE = 2'd0, ST_P1 = 2'd1, ST_P2 = 2'd2;

    reg [1:0]  state;
    reg [5:0]  k;
    reg [31:0] data_r, src_r;
    reg [4:0]  off_r;
    reg [5:0]  aw_r, sr_r;
    reg [2:0]  op_r;
    reg [31:0] wmask, dsh;
    reg [31:0] field_r, flag_r;
    reg [31:0] fsh, pmask, splc;
    reg [5:0]  ffo_h;
    reg        ffo_found;
    reg        n_r;

    assign busy = (state != ST_IDLE);

    // Width of 0 encodes 32; sr is what the reference calls shift_right.
    wire [5:0] aw_in = (bf_raw_width == 5'h0) ? 6'd32 : {1'b0, bf_raw_width};
    wire [5:0] sr_in = 6'd32 - {1'b0, bf_offset} - aw_in;

    // Seeds for pass 2, from pass 1's results.
    wire [31:0] field_w = dsh & wmask;
    wire [31:0] flag_w  = (op_r == BF_INS) ? (src_r & wmask) : field_w;

    // BFFFO's answer, and the reference's own "nothing found" default.
    wire [5:0]  ffo_base = {1'b0, off_r} + aw_r;
    wire [31:0] ffo_res  = ffo_found ? ({26'h0, ffo_base} - 32'd1 - {26'h0, ffo_h})
                                     : {26'h0, ffo_base};

    assign bf_n = n_r;
    assign bf_z = (flag_r == 32'h0);
    assign bf_v = 1'b0;
    assign bf_c = 1'b0;

    wire [31:0] exts_sign = n_r ? ~wmask : 32'h0;

    assign bf_result = (op_r == BF_TST)  ? 32'h0
                     : (op_r == BF_EXTU) ? field_r
                     : (op_r == BF_CHG)  ? (data_r ^  pmask)
                     : (op_r == BF_EXTS) ? (field_r | exts_sign)
                     : (op_r == BF_CLR)  ? (data_r & ~pmask)
                     : (op_r == BF_FFO)  ? ffo_res
                     : (op_r == BF_SET)  ? (data_r |  pmask)
                     :                     ((data_r & ~pmask) | splc);

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; k <= 6'd0;
            data_r <= 32'h0; src_r <= 32'h0; off_r <= 5'h0;
            aw_r <= 6'd0; sr_r <= 6'd0; op_r <= 3'b000;
            wmask <= 32'h0; dsh <= 32'h0;
            field_r <= 32'h0; flag_r <= 32'h0;
            fsh <= 32'h0; pmask <= 32'h0; splc <= 32'h0;
            ffo_h <= 6'd0; ffo_found <= 1'b0; n_r <= 1'b0;
        end else if (start) begin
            data_r <= bf_data;  src_r <= bf_src;
            off_r  <= bf_offset; aw_r <= aw_in; sr_r <= sr_in;
            op_r   <= bf_op;
            wmask  <= 32'h0;
            dsh    <= bf_data;
            ffo_found <= 1'b0;
            ffo_h  <= 6'd0;
            n_r    <= 1'b0;
            k      <= 6'd0;
            state  <= ST_P1;
        end else if (state == ST_P1) begin
            if (k < aw_r) wmask <= (wmask << 1) | 32'h1;
            if (k < sr_r) dsh   <= dsh >> 1;
            if (k == 6'd31) begin
                // Seeded from this tick's FINAL values, which the two
                // assignments above have just produced.
                state   <= ST_P2;
                k       <= 6'd0;
            end else begin
                k <= k + 6'd1;
            end
        end else if (state == ST_P2) begin
            if (k == 6'd0) begin
                // First tick of pass 2 also captures what pass 1 produced.
                field_r <= field_w;
                flag_r  <= flag_w;
                fsh     <= flag_w;
                pmask   <= wmask;
                splc    <= src_r & wmask;
                k       <= k + 6'd1;
            end else begin
                if (k <= sr_r) begin
                    pmask <= pmask << 1;
                    splc  <= splc  << 1;
                end
                // Scan bit (k-1) of flag_field. A later hit overwrites an
                // earlier one, so ffo_h ends as the HIGHEST set bit index.
                if ((k - 6'd1) < aw_r) begin
                    if (fsh[0]) begin
                        ffo_h     <= k - 6'd1;
                        ffo_found <= 1'b1;
                    end
                    // The sign bit is bit aw-1, the last one examined.
                    if ((k - 6'd1) == (aw_r - 6'd1)) n_r <= fsh[0];
                    fsh <= fsh >> 1;
                end
                if (k == 6'd32) state <= ST_IDLE;
                else            k     <= k + 6'd1;
            end
        end
    end

endmodule

`default_nettype wire

`default_nettype none
`timescale 1ps/1ps

// =============================================================================
// Equivalence sweep: rtlp/mh030p_bitfield.sv (sequential) vs rtl/eu_bitfield.sv
// (combinational, the reference), over every offset, every width, every op and a
// spread of data/source values.
//
// WHY THIS EXISTS. Bit-field instructions are 68020+, so the Tom Harte corpus --
// which is 68000-captured -- has ZERO coverage of them. Sequentialising this
// unit with no functional net would have been unverifiable, so the net is built
// here instead, and it is stronger than Harte would have been: 8 ops x 32
// offsets x 32 widths x 12 operand pairs, comparing the result and all four
// flags on every one.
//
// The reference's documented restriction is offset + width <= 32, so vectors
// outside that envelope are skipped -- the real decoder never produces them.
// =============================================================================

module bf_equiv_tb;

    logic clk_4x = 1'b0;
    always #5 clk_4x = ~clk_4x;
    logic rst_n = 1'b0;

    logic [31:0] bf_data, bf_src;
    logic [4:0]  bf_offset, bf_raw_width;
    logic [2:0]  bf_op;

    // Reference: purely combinational.
    wire [31:0] r_result;
    wire        r_n, r_z, r_v, r_c;
    eu_bitfield u_ref (
        .bf_data(bf_data), .bf_offset(bf_offset), .bf_raw_width(bf_raw_width),
        .bf_src(bf_src), .bf_op(bf_op),
        .bf_result(r_result), .bf_n(r_n), .bf_z(r_z), .bf_v(r_v), .bf_c(r_c)
    );

    // Under test: sequential.
    logic       start = 1'b0;
    wire        busy;
    wire [31:0] d_result;
    wire        d_n, d_z, d_v, d_c;
    mh030p_bitfield u_dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .start(start), .busy(busy),
        .bf_data(bf_data), .bf_offset(bf_offset), .bf_raw_width(bf_raw_width),
        .bf_src(bf_src), .bf_op(bf_op),
        .bf_result(d_result), .bf_n(d_n), .bf_z(d_z), .bf_v(d_v), .bf_c(d_c)
    );

    int unsigned checked = 0;
    int unsigned bad = 0;

    task automatic one(input logic [31:0] dat, input logic [31:0] src,
                       input logic [4:0] off, input logic [4:0] rw,
                       input logic [2:0] o);
        logic [5:0] aw;
        begin
            aw = (rw == 5'h0) ? 6'd32 : {1'b0, rw};
            if (({1'b0, off} + aw) > 6'd32) return;   // outside the envelope

            bf_data = dat; bf_src = src;
            bf_offset = off; bf_raw_width = rw; bf_op = o;
            @(negedge clk_4x);
            start = 1'b1;
            @(negedge clk_4x);
            start = 1'b0;
            while (busy) @(negedge clk_4x);

            checked = checked + 1;
            if ((d_result !== r_result) || (d_n !== r_n) || (d_z !== r_z)
                                       || (d_v !== r_v) || (d_c !== r_c)) begin
                if (bad < 20)
                    $display("MISMATCH op=%03b off=%0d rw=%0d data=%08h src=%08h | res %08h vs %08h | nzvc %b%b%b%b vs %b%b%b%b",
                             o, off, rw, dat, src, d_result, r_result,
                             d_n, d_z, d_v, d_c, r_n, r_z, r_v, r_c);
                bad = bad + 1;
            end
        end
    endtask

    logic [31:0] dats [0:11];
    logic [31:0] srcs [0:11];

    integer o, off, rw, v;

    initial begin
        dats[0]  = 32'h0000_0000; srcs[0]  = 32'hFFFF_FFFF;
        dats[1]  = 32'hFFFF_FFFF; srcs[1]  = 32'h0000_0000;
        dats[2]  = 32'h8000_0000; srcs[2]  = 32'h0000_0001;
        dats[3]  = 32'h0000_0001; srcs[3]  = 32'h8000_0000;
        dats[4]  = 32'hA5A5_A5A5; srcs[4]  = 32'h5A5A_5A5A;
        dats[5]  = 32'h5A5A_5A5A; srcs[5]  = 32'hA5A5_A5A5;
        dats[6]  = 32'hDEAD_BEEF; srcs[6]  = 32'hC0FF_EE00;
        dats[7]  = 32'h1234_5678; srcs[7]  = 32'h9ABC_DEF0;
        dats[8]  = 32'h0000_FFFF; srcs[8]  = 32'hFFFF_0000;
        dats[9]  = 32'hFFFF_0000; srcs[9]  = 32'h0000_FFFF;
        dats[10] = 32'h8000_0001; srcs[10] = 32'h7FFF_FFFE;
        dats[11] = 32'h0F0F_0F0F; srcs[11] = 32'hF0F0_F0F0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk_4x);
        #1 rst_n = 1'b1;
        @(posedge clk_4x);

        for (o = 0; o < 8; o = o + 1)
            for (off = 0; off < 32; off = off + 1)
                for (rw = 0; rw < 32; rw = rw + 1)
                    for (v = 0; v < 12; v = v + 1)
                        one(dats[v], srcs[v], off[4:0], rw[4:0], o[2:0]);

        $display("=== bitfield equivalence: %0d vectors, %0d mismatch(es) ===",
                 checked, bad);
        if (bad == 0) $display("PASS  bf_equiv");
        else          $display("FAIL  bf_equiv");
        $finish;
    end

endmodule

`default_nettype wire

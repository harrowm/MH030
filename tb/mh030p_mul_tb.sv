`default_nettype none
`timescale 1ns/1ps

// =============================================================================
// mh030p_mul vs rtl/eu_mul_div's own multiply, over random and edge operands.
//
// The new multiplier decomposes a 32x32 into five 17x17 partial products with
// three DIFFERENT signednesses, which is exactly the kind of arithmetic that
// looks right and is wrong at one corner. So it is checked against the frozen
// reference directly rather than through a handful of program-level cases:
// same operands, same op, both results compared including N and Z.
//
// The reference is combinational and the new unit takes a cycle, so the
// comparison is made after the handshake completes.
// =============================================================================

module mh030p_mul_tb;

    logic clk_4x = 1'b0;
    logic rst_n  = 1'b0;
    always #5 clk_4x = ~clk_4x;

    logic [31:0] src, dst;
    logic [1:0]  op;
    logic        start;
    wire         busy;
    wire [31:0]  n_lo, n_hi;
    wire         n_n, n_z;

    mh030p_mul dut (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .start(start), .busy(busy),
        .src(src), .dst(dst), .op(op),
        .result_lo(n_lo), .result_hi(n_hi), .n_out(n_n), .z_out(n_z)
    );

    // The reference, with its divider idle.
    wire [31:0] r_lo, r_hi;
    wire        r_n, r_z, r_v, r_c, r_dbz;
    eu_mul_div ref_md (
        .clk_4x(clk_4x), .rst_n(rst_n),
        .div_start(1'b0), .div_busy(),
        .src(src), .dst(dst), .op({1'b0, op}),
        .result_lo(r_lo), .result_hi(r_hi),
        .n_out(r_n), .z_out(r_z), .v_out(r_v), .c_out(r_c),
        .div_by_zero(r_dbz)
    );

    int fails = 0, checked = 0;
    string opname [0:3];

    task automatic one(input [31:0] a, input [31:0] b, input [1:0] o);
        // The reference's word forms use only the low halves, and its long
        // forms produce a 64-bit result; both are read after the new unit's
        // own one-cycle latency so the two are compared on the same operands.
        logic [31:0] e_lo, e_hi;
        logic        e_n, e_z;
        src = a; dst = b; op = o;
        @(negedge clk_4x);
        e_lo = r_lo; e_hi = (o[1] ? r_hi : 32'h0); e_n = r_n; e_z = r_z;
        start = 1'b1;
        @(negedge clk_4x);
        start = 1'b0;
        while (busy) @(negedge clk_4x);
        checked++;
        if ((n_lo !== e_lo) || (n_hi !== e_hi) || (n_n !== e_n)
                                              || (n_z !== e_z)) begin
            $display("FAIL %s a=%08h b=%08h : got %08h_%08h n=%b z=%b  exp %08h_%08h n=%b z=%b",
                     opname[o], a, b, n_hi, n_lo, n_n, n_z, e_hi, e_lo, e_n, e_z);
            fails++;
        end
    endtask

    logic [31:0] edges [0:9];
    int i, j, k, t;
    initial begin
        opname[0] = "MULU.W"; opname[1] = "MULS.W";
        opname[2] = "MULU.L"; opname[3] = "MULS.L";
        $display("=== mh030p_mul vs eu_mul_div ===");
        start = 1'b0; src = 0; dst = 0; op = 0;
        repeat (3) @(negedge clk_4x);
        rst_n = 1'b1;
        repeat (2) @(negedge clk_4x);

        // Edge operands: zero, one, both signs of the smallest and largest
        // magnitudes, and values whose halves straddle the 16-bit boundary --
        // where a wrong signedness on one partial product shows up.
        edges[0] = 32'h0000_0000; edges[1] = 32'h0000_0001;
        edges[2] = 32'hFFFF_FFFF; edges[3] = 32'h8000_0000;
        edges[4] = 32'h7FFF_FFFF; edges[5] = 32'h0000_8000;
        edges[6] = 32'h0000_FFFF; edges[7] = 32'hFFFF_8000;
        edges[8] = 32'h1234_5678; edges[9] = 32'hDEAD_BEEF;

        for (k = 0; k < 4; k++)
            for (i = 0; i < 10; i++)
                for (j = 0; j < 10; j++)
                    one(edges[i], edges[j], k[1:0]);

        for (t = 0; t < 400; t++)
            for (k = 0; k < 4; k++)
                one($random, $random, k[1:0]);

        $display("");
        $display("checked %0d, %0d failure(s)", checked, fails);
        if (fails == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule

`default_nettype wire

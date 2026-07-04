`default_nettype none
`timescale 1ns/1ps

// eu_bcd standalone testbench — Phase 27
// Verifies ABCD, SBCD, NBCD corner cases.
// Run: iverilog -g2012 -o /tmp/phase27b.vvp -I rtl rtl/eu_bcd.sv tb/eu_bcd_tb.sv
//      vvp /tmp/phase27b.vvp

module eu_bcd_tb;

    logic [7:0] src, dst;
    logic [1:0] op;
    logic       x_in, z_in;
    logic [7:0] result;
    logic       c_out, x_out, z_out;

    eu_bcd dut (.*);

    integer fail;
    initial fail = 0;

    // Convenience task — purely procedural, no clocks needed
    task check;
        input [255:0] name;
        input [7:0]   exp_result;
        input         exp_c, exp_z;
        begin
            #1; // let combinational settle
            if (result !== exp_result || c_out !== exp_c || z_out !== exp_z) begin
                $display("FAIL %0s: result=%02h c=%b z=%b  exp result=%02h c=%b z=%b",
                         name, result, c_out, z_out, exp_result, exp_c, exp_z);
                fail = fail + 1;
            end else begin
                $display("PASS %0s", name);
            end
        end
    endtask

    initial begin
        // ----------------------------------------------------------------
        // ABCD tests
        // ----------------------------------------------------------------
        op = 2'b00; // BCD_ADD

        // BCD-1: 12 + 34 + 0 = 46
        src=8'h34; dst=8'h12; x_in=0; z_in=1;
        check("BCD-1 ABCD 12+34", 8'h46, 0, 0);

        // BCD-2: 99 + 01 + 0 = 00, carry
        src=8'h01; dst=8'h99; x_in=0; z_in=1;
        check("BCD-2 ABCD 99+01", 8'h00, 1, 1);

        // BCD-3: 55 + 45 + 0 = 00, carry
        src=8'h45; dst=8'h55; x_in=0; z_in=1;
        check("BCD-3 ABCD 55+45", 8'h00, 1, 1);

        // BCD-4: 09 + 01 + 0 = 10 (low nibble carry)
        src=8'h01; dst=8'h09; x_in=0; z_in=1;
        check("BCD-4 ABCD 09+01", 8'h10, 0, 0);

        // BCD-5: 99 + 99 + 1 = 99 with carry (99+99=198 → 98+carry; +X=99)
        src=8'h99; dst=8'h99; x_in=1; z_in=1;
        check("BCD-5 ABCD 99+99+X", 8'h99, 1, 0);

        // BCD-6: 00 + 00 + 0 = 00, no carry, Z preserved (z_in=1→z_out=1)
        src=8'h00; dst=8'h00; x_in=0; z_in=1;
        check("BCD-6 ABCD 00+00 Z=1", 8'h00, 0, 1);

        // BCD-7: Z cleared when result nonzero
        src=8'h01; dst=8'h00; x_in=0; z_in=1;
        check("BCD-7 ABCD 00+01 Z clr", 8'h01, 0, 0);

        // BCD-8: Z remains 0 if z_in=0
        src=8'h00; dst=8'h00; x_in=0; z_in=0;
        check("BCD-8 ABCD z_in=0", 8'h00, 0, 0);

        // ----------------------------------------------------------------
        // SBCD tests
        // ----------------------------------------------------------------
        op = 2'b01; // BCD_SUB

        // BCD-9: 72 - 55 - 0 = 17
        src=8'h55; dst=8'h72; x_in=0; z_in=1;
        check("BCD-9 SBCD 72-55", 8'h17, 0, 0);

        // BCD-10: 00 - 00 - 0 = 00, Z preserved
        src=8'h00; dst=8'h00; x_in=0; z_in=1;
        check("BCD-10 SBCD 00-00", 8'h00, 0, 1);

        // BCD-11: 21 - 45 - 0 = 76 (borrow, BCD complement)
        src=8'h45; dst=8'h21; x_in=0; z_in=1;
        check("BCD-11 SBCD 21-45", 8'h76, 1, 0);

        // BCD-12: 10 - 01 - 0 = 09
        src=8'h01; dst=8'h10; x_in=0; z_in=1;
        check("BCD-12 SBCD 10-01", 8'h09, 0, 0);

        // BCD-13: 50 - 50 - 1 = 99 (borrow from X)
        src=8'h50; dst=8'h50; x_in=1; z_in=1;
        check("BCD-13 SBCD 50-50-X", 8'h99, 1, 0);

        // BCD-14: 30 - 09 - 0 = 21 (low nibble borrow)
        src=8'h09; dst=8'h30; x_in=0; z_in=1;
        check("BCD-14 SBCD 30-09", 8'h21, 0, 0);

        // ----------------------------------------------------------------
        // NBCD tests
        // ----------------------------------------------------------------
        op = 2'b10; // BCD_NEG

        // BCD-15: -(0x45) + X=0 → 55 with borrow
        dst=8'h45; src=8'hXX; x_in=0; z_in=1;
        check("BCD-15 NBCD 0x45", 8'h55, 1, 0);

        // BCD-16: -(0x00) + X=0 → 00 no borrow, Z preserved
        dst=8'h00; src=8'hXX; x_in=0; z_in=1;
        check("BCD-16 NBCD 0x00", 8'h00, 0, 1);

        // BCD-17: -(0x00) + X=1 → 99 with borrow
        dst=8'h00; src=8'hXX; x_in=1; z_in=1;
        check("BCD-17 NBCD 0x00 X=1", 8'h99, 1, 0);

        // BCD-18: -(0x99) + X=0 → 01 with borrow
        dst=8'h99; src=8'hXX; x_in=0; z_in=1;
        check("BCD-18 NBCD 0x99", 8'h01, 1, 0);

        // BCD-19: x_out == c_out (always)
        op=2'b00; src=8'h01; dst=8'h99; x_in=0; z_in=1;
        #1;
        if (x_out !== c_out) begin
            $display("FAIL BCD-19 x_out(%b) != c_out(%b)", x_out, c_out);
            fail = fail + 1;
        end else $display("PASS BCD-19 x_out==c_out");

        // ----------------------------------------------------------------
        if (fail == 0)
            $display("ALL BCD TESTS PASSED");
        else
            $display("%0d BCD TEST(S) FAILED", fail);

        $finish;
    end

endmodule

`default_nettype wire

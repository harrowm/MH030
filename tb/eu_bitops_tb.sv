`default_nettype none
`timescale 1ns/1ps

// eu_bitops standalone testbench — Phase 28
// Verifies BTST, BCHG, BCLR, BSET.
// Run: iverilog -g2012 -o /tmp/phase28b.vvp -I rtl rtl/eu_bitops.sv tb/eu_bitops_tb.sv
//      vvp /tmp/phase28b.vvp

module eu_bitops_tb;

    logic [31:0] dst;
    logic [4:0]  bit_num;
    logic [1:0]  op;
    logic [31:0] result;
    logic        z_out;

    eu_bitops dut (.*);

    integer fail;
    initial fail = 0;

    task check;
        input [255:0] name;
        input [31:0]  exp_result;
        input         exp_z;
        begin
            #1;
            if (result !== exp_result || z_out !== exp_z) begin
                $display("FAIL %0s: result=%08h z=%b  exp result=%08h z=%b",
                         name, result, z_out, exp_result, exp_z);
                fail = fail + 1;
            end else begin
                $display("PASS %0s", name);
            end
        end
    endtask

    initial begin
        // ----------------------------------------------------------------
        // BTST — no write, only Z
        // ----------------------------------------------------------------
        op = 2'b00;

        // BIT-1: bit 0 of 0x01 → set, Z=0, result unchanged
        dst=32'h0000_0001; bit_num=5'd0;
        check("BIT-1 BTST bit0 set", 32'h0000_0001, 0);

        // BIT-2: bit 0 of 0x02 → clear, Z=1
        dst=32'h0000_0002; bit_num=5'd0;
        check("BIT-2 BTST bit0 clr", 32'h0000_0002, 1);

        // BIT-3: bit 31 of 0x8000_0000 → set, Z=0
        dst=32'h8000_0000; bit_num=5'd31;
        check("BIT-3 BTST bit31 set", 32'h8000_0000, 0);

        // BIT-4: bit 7 of 0xFFFFFF7F → clear, Z=1
        dst=32'hFFFF_FF7F; bit_num=5'd7;
        check("BIT-4 BTST bit7 clr", 32'hFFFF_FF7F, 1);

        // ----------------------------------------------------------------
        // BCHG — flip bit
        // ----------------------------------------------------------------
        op = 2'b01;

        // BIT-5: flip bit 3 of 0x00 → 0x08, Z=1 (bit was 0)
        dst=32'h0000_0000; bit_num=5'd3;
        check("BIT-5 BCHG bit3 clr", 32'h0000_0008, 1);

        // BIT-6: flip bit 3 of 0x08 → 0x00, Z=0 (bit was 1)
        dst=32'h0000_0008; bit_num=5'd3;
        check("BIT-6 BCHG bit3 set", 32'h0000_0000, 0);

        // BIT-7: flip bit 31 of 0xFFFFFFFF → 0x7FFFFFFF, Z=0
        dst=32'hFFFF_FFFF; bit_num=5'd31;
        check("BIT-7 BCHG bit31 set", 32'h7FFF_FFFF, 0);

        // ----------------------------------------------------------------
        // BCLR — clear bit
        // ----------------------------------------------------------------
        op = 2'b10;

        // BIT-8: clear bit 4 of 0xFF → 0xEF, Z=0 (bit was 1)
        dst=32'h0000_00FF; bit_num=5'd4;
        check("BIT-8 BCLR bit4 set", 32'h0000_00EF, 0);

        // BIT-9: clear bit 4 of 0xEF → 0xEF unchanged, Z=1 (was already 0)
        dst=32'h0000_00EF; bit_num=5'd4;
        check("BIT-9 BCLR bit4 clr", 32'h0000_00EF, 1);

        // BIT-10: clear bit 0 of 0xFFFF_FFFF → 0xFFFF_FFFE
        dst=32'hFFFF_FFFF; bit_num=5'd0;
        check("BIT-10 BCLR bit0 all1", 32'hFFFF_FFFE, 0);

        // ----------------------------------------------------------------
        // BSET — set bit
        // ----------------------------------------------------------------
        op = 2'b11;

        // BIT-11: set bit 5 of 0x00 → 0x20, Z=1 (was 0)
        dst=32'h0000_0000; bit_num=5'd5;
        check("BIT-11 BSET bit5 clr", 32'h0000_0020, 1);

        // BIT-12: set bit 5 of 0x20 → 0x20 unchanged, Z=0 (was 1)
        dst=32'h0000_0020; bit_num=5'd5;
        check("BIT-12 BSET bit5 set", 32'h0000_0020, 0);

        // BIT-13: set bit 31 of 0x7FFF_FFFF → 0xFFFF_FFFF, Z=1
        dst=32'h7FFF_FFFF; bit_num=5'd31;
        check("BIT-13 BSET bit31 clr", 32'hFFFF_FFFF, 1);

        // BIT-14: all-bits set with BSET (idempotent)
        dst=32'hFFFF_FFFF; bit_num=5'd15;
        check("BIT-14 BSET bit15 set nop", 32'hFFFF_FFFF, 0);

        // ----------------------------------------------------------------
        if (fail == 0)
            $display("ALL BITOPS TESTS PASSED");
        else
            $display("%0d BITOPS TEST(S) FAILED", fail);

        $finish;
    end

endmodule

`default_nettype wire

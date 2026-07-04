`default_nettype none
`timescale 1ps/1ps

// Phase 23: eu_regfile unit testbench
// Tests: RF-1 (D-reg), RF-2 (A-reg), RF-3 (SR/A7 routing),
//        RF-4 (PC/VBR), RF-5 (dual-port), RF-6 (CCR-only/outputs), RF-7 (generate loops)

module eu_regfile_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;   // 100 MHz

    logic rst_n = 0;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic [3:0]  rd_a_sel  = 0;
    logic [1:0]  rd_a_siz  = 0;
    logic [31:0] rd_a_data;

    logic [3:0]  rd_b_sel  = 0;
    logic [1:0]  rd_b_siz  = 0;
    logic [31:0] rd_b_data;

    logic        wr_en   = 0;
    logic [3:0]  wr_sel  = 0;
    logic [1:0]  wr_siz  = 2'b00;
    logic [31:0] wr_data = 0;

    logic        pc_wr_en   = 0;
    logic [31:0] pc_wr_data = 0;
    logic [31:0] pc_out;

    logic        sr_wr_en   = 0;
    logic [15:0] sr_wr_data = 0;
    logic        sr_ccr_only = 0;
    logic [15:0] sr_out;

    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;

    eu_regfile u_rf (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .rd_a_sel    (rd_a_sel),
        .rd_a_siz    (rd_a_siz),
        .rd_a_data   (rd_a_data),
        .rd_b_sel    (rd_b_sel),
        .rd_b_siz    (rd_b_siz),
        .rd_b_data   (rd_b_data),
        .wr_en       (wr_en),
        .wr_sel      (wr_sel),
        .wr_siz      (wr_siz),
        .wr_data     (wr_data),
        .pc_wr_en    (pc_wr_en),
        .pc_wr_data  (pc_wr_data),
        .pc_out      (pc_out),
        .sr_wr_en    (sr_wr_en),
        .sr_wr_data  (sr_wr_data),
        .sr_ccr_only (sr_ccr_only),
        .sr_out      (sr_out),
        .vbr_wr_en   (vbr_wr_en),
        .vbr_wr_data (vbr_wr_data),
        .vbr_out     (vbr_out),
        .usp_out     (usp_out),
        .msp_out     (msp_out),
        .isp_out     (isp_out),
        .supervisor  (supervisor),
        .master_mode (master_mode),
        .ipl_mask    (ipl_mask)
    );

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  [%0t] %s", $time, name);
        else begin
            $display("FAIL  [%0t] %s", $time, name);
            fail_count++;
        end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  [%0t] %s (got %08h)", $time, name, got);
        else begin
            $display("FAIL  [%0t] %s: got %08h exp %08h", $time, name, got, exp);
            fail_count++;
        end
    endtask

    // Write a general register.
    // Inputs must be stable BEFORE the clock edge so always_ff samples them.
    // Deassert happens AFTER #1 (past the NBA region) to avoid the race where
    // the initial block sets wr_en=0 in the same Active region as always_ff.
    task write_reg(input logic [3:0] sel, input logic [1:0] siz, input logic [31:0] data);
        wr_en = 1; wr_sel = sel; wr_siz = siz; wr_data = data;
        @(posedge clk_4x);
        #1;       // move past NBA region before deasserting
        wr_en = 0;
    endtask

    task write_sr(input logic [15:0] data, input logic ccr_only);
        sr_wr_en = 1; sr_wr_data = data; sr_ccr_only = ccr_only;
        @(posedge clk_4x);
        #1;
        sr_wr_en = 0;
    endtask

    task write_pc(input logic [31:0] data);
        pc_wr_en = 1; pc_wr_data = data;
        @(posedge clk_4x);
        #1;
        pc_wr_en = 0;
    endtask

    task write_vbr(input logic [31:0] data);
        vbr_wr_en = 1; vbr_wr_data = data;
        @(posedge clk_4x);
        #1;
        vbr_wr_en = 0;
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 23: eu_regfile ===");

        repeat(4) @(posedge clk_4x);
        rst_n = 1'b1;
        @(posedge clk_4x); #1;

        // ================================================================
        // RF-1: Data register R/W
        // ================================================================
        $display("--- RF-1: Data register R/W ---");

        // RF-1a: long write D0, read back
        write_reg(4'd0, 2'b00, 32'h1234_5678);
        rd_a_sel = 4'd0; rd_a_siz = 2'b00; #1;
        check32("RF-1a: D0 long write/read", rd_a_data, 32'h1234_5678);

        // RF-1b: byte write D1 — upper bits preserved
        write_reg(4'd1, 2'b00, 32'hDEAD_BE00);   // set known base value
        write_reg(4'd1, 2'b01, 32'h0000_0042);    // byte write, upper unchanged
        rd_a_sel = 4'd1; rd_a_siz = 2'b00; #1;
        check32("RF-1b: D1 byte write, upper bits preserved", rd_a_data, 32'hDEAD_BE42);

        // RF-1c: word write D2 — upper bits preserved
        write_reg(4'd2, 2'b00, 32'hAAAA_BBBB);
        write_reg(4'd2, 2'b10, 32'h0000_CCCC);
        rd_a_sel = 4'd2; rd_a_siz = 2'b00; #1;
        check32("RF-1c: D2 word write, upper bits preserved", rd_a_data, 32'hAAAA_CCCC);

        // ================================================================
        // RF-2: Address register R/W
        // ================================================================
        $display("--- RF-2: Address register R/W ---");

        // RF-2a: long write A0, read back
        write_reg(4'd8, 2'b00, 32'hDEAD_BEEF);
        rd_a_sel = 4'd8; rd_a_siz = 2'b00; #1;
        check32("RF-2a: A0 long write/read", rd_a_data, 32'hDEAD_BEEF);

        // RF-2b: word write A1 with 0xFF80 sign-extends to 0xFFFF_FF80
        write_reg(4'd9, 2'b10, 32'h0000_FF80);
        rd_a_sel = 4'd9; rd_a_siz = 2'b00; #1;
        check32("RF-2b: A1 word 0xFF80 sign-extends", rd_a_data, 32'hFFFF_FF80);

        // RF-2c: byte write A2 with 0x80 sign-extends to 0xFFFF_FF80
        write_reg(4'd10, 2'b01, 32'h0000_0080);
        rd_a_sel = 4'd10; rd_a_siz = 2'b00; #1;
        check32("RF-2c: A2 byte 0x80 sign-extends", rd_a_data, 32'hFFFF_FF80);

        // ================================================================
        // RF-3: SR, supervisor mode, A7 routing, stack pointer switch
        // ================================================================
        $display("--- RF-3: SR and A7 routing ---");

        // RF-3a: after reset SR = 0x2700 (supervisor, IPL=7)
        check("RF-3a: sr_out = 0x2700",    sr_out == 16'h2700);
        check("RF-3a: supervisor set",      supervisor == 1'b1);
        check("RF-3a: master_mode clear",   master_mode == 1'b0);
        check("RF-3a: ipl_mask = 3'b111",  ipl_mask == 3'b111);

        // RF-3b: write A7 in supervisor mode (S=1,M=0) → goes to ISP
        write_reg(4'd15, 2'b00, 32'hAAAA_0000);
        rd_a_sel = 4'd15; rd_a_siz = 2'b00; #1;
        check32("RF-3b: A7 routes to ISP in supervisor mode",  rd_a_data, 32'hAAAA_0000);
        check32("RF-3b: isp_out reflects write",               isp_out,   32'hAAAA_0000);

        // RF-3c: set M=1 in SR → A7 switches from ISP to MSP
        write_sr(16'h3700, 1'b0);   // T=0,S=1,M=1,IPL=7
        check("RF-3c: master_mode set after SR write",  master_mode == 1'b1);
        rd_a_sel = 4'd15; rd_a_siz = 2'b00; #1;
        check32("RF-3c: A7 now routes to MSP (=0)",  rd_a_data, 32'h0000_0000);

        // RF-3e: ISP preserved across the ISP→MSP switch
        check32("RF-3e: ISP preserved after A7 switch",  isp_out, 32'hAAAA_0000);

        // RF-3d: clear S → user mode, A7 routes to USP
        write_sr(16'h0000, 1'b0);
        check("RF-3d: supervisor cleared",    supervisor == 1'b0);
        check("RF-3d: master_mode cleared",   master_mode == 1'b0);
        rd_a_sel = 4'd15; rd_a_siz = 2'b00; #1;
        check32("RF-3d: A7 routes to USP (=0)",  rd_a_data, 32'h0000_0000);

        // Restore supervisor for remaining tests
        write_sr(16'h2700, 1'b0);

        // ================================================================
        // RF-4: PC and VBR
        // ================================================================
        $display("--- RF-4: PC and VBR ---");

        write_pc(32'hCAFE_BABE);
        check32("RF-4a: PC write/read",  pc_out, 32'hCAFE_BABE);

        write_vbr(32'h0000_1000);
        check32("RF-4b: VBR write/read",  vbr_out, 32'h0000_1000);

        // ================================================================
        // RF-5: Dual read ports
        // ================================================================
        $display("--- RF-5: Dual read ports ---");

        // D0=0x12345678 (from RF-1a), A0=0xDEADBEEF (from RF-2a)
        rd_a_sel = 4'd0;  rd_a_siz = 2'b00;
        rd_b_sel = 4'd8;  rd_b_siz = 2'b00;
        #1;
        check32("RF-5a: port A = D0 = 0x12345678",  rd_a_data, 32'h1234_5678);
        check32("RF-5a: port B = A0 = 0xDEADBEEF",  rd_b_data, 32'hDEAD_BEEF);

        // RF-5b: write D3, new value visible on port A next cycle
        rd_a_sel = 4'd3; rd_a_siz = 2'b00;
        write_reg(4'd3, 2'b00, 32'h5555_AAAA);
        check32("RF-5b: D3 readable after write",  rd_a_data, 32'h5555_AAAA);

        // ================================================================
        // RF-6: sr_ccr_only and convenience outputs
        // ================================================================
        $display("--- RF-6: CCR-only write and convenience outputs ---");

        // SR is 0x2700 (restored above)
        // RF-6a: CCR-only write sets CCR bits, system byte unchanged
        write_sr(16'h001F, 1'b1);   // CCR only: X=N=Z=V=C=1
        check("RF-6a: SR[15:8] unchanged after CCR write",  sr_out[15:8] == 8'h27);
        check("RF-6a: SR[7:0] updated to 0x1F",            sr_out[7:0]  == 8'h1F);

        // RF-6b: supervisor output follows SR[S]
        write_sr(16'h0000, 1'b0);
        check("RF-6b: supervisor=0 when S=0",  supervisor == 1'b0);
        write_sr(16'h2000, 1'b0);   // S=1, M=0, IPL=0
        check("RF-6b: supervisor=1 when S=1",  supervisor == 1'b1);

        // RF-6c: ipl_mask follows SR[10:8]
        write_sr(16'h2500, 1'b0);   // S=1, IPL=5
        check("RF-6c: ipl_mask=5 when SR[10:8]=101",  ipl_mask == 3'b101);
        write_sr(16'h2700, 1'b0);   // restore S=1, IPL=7

        // ================================================================
        // RF-7: Generate loop coverage (all 8 D-regs, all 7 A-regs)
        // ================================================================
        $display("--- RF-7: Generate loop coverage ---");

        // RF-7a: write all 8 D-regs, read back each
        begin : rf7a
            int i;
            logic [31:0] tv;
            int local_fail;
            local_fail = 0;
            for (i = 0; i < 8; i++) begin
                tv = 32'hA000_0000 | (32'(i) << 4);
                write_reg(4'(i), 2'b00, tv);
            end
            for (i = 0; i < 8; i++) begin
                tv = 32'hA000_0000 | (32'(i) << 4);
                rd_a_sel = 4'(i); rd_a_siz = 2'b00;
                #1;
                if (rd_a_data !== tv) begin
                    $display("FAIL  RF-7a D%0d: got %08h exp %08h", i, rd_a_data, tv);
                    fail_count++;
                    local_fail++;
                end
            end
            if (local_fail == 0) $display("PASS  RF-7a: all 8 D-regs write/read");
        end

        // RF-7b: write all 7 A-regs (A0-A6), read back each
        begin : rf7b
            int i;
            logic [31:0] tv;
            int local_fail;
            local_fail = 0;
            for (i = 0; i < 7; i++) begin
                tv = 32'hB000_0000 | (32'(i) << 4);
                write_reg(4'(8 + i), 2'b00, tv);
            end
            for (i = 0; i < 7; i++) begin
                tv = 32'hB000_0000 | (32'(i) << 4);
                rd_a_sel = 4'(8 + i); rd_a_siz = 2'b00;
                #1;
                if (rd_a_data !== tv) begin
                    $display("FAIL  RF-7b A%0d: got %08h exp %08h", i, rd_a_data, tv);
                    fail_count++;
                    local_fail++;
                end
            end
            if (local_fail == 0) $display("PASS  RF-7b: all 7 A-regs (A0-A6) write/read");
        end

        // ================================================================
        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

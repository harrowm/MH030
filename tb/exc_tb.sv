`default_nettype none
`timescale 1ns/1ps

// m68030_exc testbench — Phase 33
//
// Compile:
//   iverilog -g2012 -o /tmp/phase33.vvp -I rtl rtl/m68030_exc.sv tb/exc_tb.sv
//   vvp /tmp/phase33.vvp
//
// Immediate-ack BIU stub (exc_ack = exc_req).
//
// Frame address formula:
//   new_ssp  = ssp_in - ssp_delta
//   push_addr[step] = new_ssp + step_rem*4, step_rem = total_steps-1-step
//   step 0 → ssp_in - 4  (highest, pushed first)
//   last step → new_ssp   (lowest, ssp_out = new_ssp)

module exc_tb;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    logic        bus_err_req  = 0, addr_err_req = 0;
    logic [2:0]  ipl_sync     = 0, ipl_mask     = 0;
    logic        illegal_req  = 0, priv_req      = 0;
    logic        trace_req    = 0, linea_req      = 0;
    logic        linef_req    = 0, fmt_err_req    = 0;
    logic        div_zero_req = 0, chk_req        = 0;
    logic        trapv_req    = 0, trap_req        = 0;
    logic [3:0]  trap_num     = 0;
    logic [31:0] fault_pc     = 0;
    logic [15:0] fault_sr     = 0;
    logic [31:0] fault_addr   = 0;
    logic [15:0] fault_ssw    = 0;
    logic [31:0] ssp_in       = 0, vbr_in = 0;
    logic [31:0] ssp_out;
    logic        ssp_wr_en;
    logic [31:0] exc_addr, exc_wdata;
    logic        exc_rw;
    logic [1:0]  exc_siz;
    logic        exc_req;
    logic        exc_ack;
    logic [31:0] exc_rdata    = 32'hCAFE_0001;  // default test vector value
    logic [31:0] new_pc;
    logic        new_pc_wr;
    logic [15:0] new_sr;
    logic        new_sr_wr;
    logic        exc_active;
    logic [7:0]  exc_vector_num;

    // Immediate-ack stub
    assign exc_ack = exc_req;

    m68030_exc dut (.*);

    // -----------------------------------------------------------------------
    // BIU transaction capture (async-reset via cap_nrst)
    // -----------------------------------------------------------------------
    logic cap_nrst = 0;
    logic [4:0]  trans_cnt;
    logic [31:0] t_addr  [0:31];
    logic [31:0] t_wdata [0:31];
    logic        t_rw    [0:31];
    logic [31:0] last_ssp, last_new_pc;
    logic [15:0] last_new_sr;

    // Use separate capture always_ff driven by cap_nrst
    always_ff @(posedge clk_4x or negedge cap_nrst) begin
        if (!cap_nrst) begin
            trans_cnt   <= 5'd0;
            last_ssp    <= 32'h0;
            last_new_pc <= 32'h0;
            last_new_sr <= 16'h0;
        end else begin
            if (exc_req && exc_ack) begin
                t_addr [trans_cnt] <= exc_addr;
                t_wdata[trans_cnt] <= exc_wdata;
                t_rw   [trans_cnt] <= exc_rw;
                trans_cnt <= trans_cnt + 5'd1;
            end
            if (ssp_wr_en) last_ssp    <= ssp_out;
            if (new_pc_wr) last_new_pc <= new_pc;
            if (new_sr_wr) last_new_sr <= new_sr;
        end
    end

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    integer fail;

    task automatic chk32;
        input [127:0] lbl;
        input [31:0]  got, exp;
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got=%08h exp=%08h", lbl, got, exp);
                fail = fail + 1;
            end else $display("PASS %0s: %08h", lbl, got);
        end
    endtask

    task automatic chk16;
        input [127:0] lbl;
        input [15:0]  got, exp;
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got=%04h exp=%04h", lbl, got, exp);
                fail = fail + 1;
            end else $display("PASS %0s: %04h", lbl, got);
        end
    endtask

    task automatic chk_bit;
        input [127:0] lbl;
        input         got, exp;
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got=%b exp=%b", lbl, got, exp);
                fail = fail + 1;
            end else $display("PASS %0s: %b", lbl, got);
        end
    endtask

    // Reset DUT + capture hardware, deassert all requests
    task automatic begin_test;
        begin
            // Deassert all exception sources
            bus_err_req=0; addr_err_req=0;
            ipl_sync=0; ipl_mask=0;
            illegal_req=0; priv_req=0; trace_req=0;
            linea_req=0; linef_req=0; fmt_err_req=0;
            div_zero_req=0; chk_req=0; trapv_req=0;
            trap_req=0; trap_num=0;
            fault_pc=0; fault_sr=0; fault_addr=0; fault_ssw=0;
            ssp_in=0; vbr_in=0;

            // Pulse capture reset
            cap_nrst = 0; #1; cap_nrst = 1;
        end
    endtask

    // Wait until exception FSM returns to IDLE (up to 100 cycles)
    task automatic wait_idle;
        integer n;
        begin
            n = 0;
            @(posedge clk_4x);     // wait at least one cycle past request
            #1;
            while (exc_active && n < 100) begin
                @(posedge clk_4x); #1;
                n = n + 1;
            end
            if (n >= 100) begin
                $display("TIMEOUT wait_idle");
                fail = fail + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Test body
    // -----------------------------------------------------------------------
    initial begin
        fail = 0;

        // Power-on reset
        rst_n = 0; cap_nrst = 0;
        @(posedge clk_4x); @(posedge clk_4x); #1;
        rst_n = 1; cap_nrst = 1;
        @(posedge clk_4x); #1;

        // ================================================================
        // EXC-1: TRAP #0, format $0
        //   ssp=0x2000, vbr=0, fault_pc=0x1000, fault_sr=0xA700 (T1=1)
        //   exc_rdata=0xCAFE0001 (handler address)
        //
        //   new_ssp = 0x2000 - 8 = 0x1FF8
        //   push[0]: addr=0x1FFC, data=fault_pc=0x00001000
        //   push[1]: addr=0x1FF8, data={fmtvec,sr}
        //     fmtvec={4'h0,2'b00,8'd32,2'b00}=0x0080
        //     data = 0x0080_A700
        //   fetch:   addr=VBR+32*4=0x80 (rw=1)
        //   ssp_out = 0x1FF8
        //   new_pc  = 0xCAFE0001
        //   new_sr  = {00,1,0,0,7,0x00} = 0x2700  (T cleared, S kept, IPL kept)
        // ================================================================
        $display("--- EXC-1: TRAP #0 ---");
        begin_test;
        ssp_in    = 32'h0000_2000;
        vbr_in    = 32'h0000_0000;
        fault_pc  = 32'h0000_1000;
        fault_sr  = 16'hA700;      // T1=1, S=1, IPL=7, CCR=0x00
        exc_rdata = 32'hCAFE_0001;
        trap_req  = 1; trap_num = 4'd0;
        @(posedge clk_4x); #1;    // FSM latches snap at this posedge
        trap_req  = 0;             // deassert (already snapped)
        wait_idle;

        chk32("EXC-1 push0_addr",  t_addr[0],  32'h0000_1FFC);
        chk32("EXC-1 push0_data",  t_wdata[0], 32'h0000_1000);
        chk32("EXC-1 push1_addr",  t_addr[1],  32'h0000_1FF8);
        chk32("EXC-1 push1_data",  t_wdata[1], 32'h0080_A700);
        chk32("EXC-1 fetch_addr",  t_addr[2],  32'h0000_0080);
        chk_bit("EXC-1 fetch_rw",  t_rw[2],    1'b1);
        chk32("EXC-1 ssp_out",     last_ssp,   32'h0000_1FF8);
        chk32("EXC-1 new_pc",      last_new_pc, 32'hCAFE_0001);
        chk16("EXC-1 new_sr",      last_new_sr, 16'h2700); // T=0, S=1, IPL=7

        // ================================================================
        // EXC-2: Illegal instruction, vec=4, VBR=0
        //   fmtvec = {4'h0,2'b00,8'd4,2'b00} = 0x0010
        //   fetch_addr = 4*4 = 0x10
        // ================================================================
        $display("--- EXC-2: Illegal instruction ---");
        begin_test;
        ssp_in    = 32'h0000_3000;
        fault_pc  = 32'h0000_2000;
        fault_sr  = 16'h2700;
        exc_rdata = 32'h0000_5000;
        illegal_req = 1;
        @(posedge clk_4x); #1;
        illegal_req = 0;
        wait_idle;

        chk32("EXC-2 push1_data",  t_wdata[1], 32'h0010_2700);
        chk32("EXC-2 fetch_addr",  t_addr[2],  32'h0000_0010);
        chk32("EXC-2 new_pc",      last_new_pc, 32'h0000_5000);

        // ================================================================
        // EXC-3: Priority — bus_err beats illegal
        //   bus_err → vec=2, fmt=$A (FMT_BUS_INS), 8 LW writes + 1 read = 9 trans
        //   fmtvec = {4'hA,2'b00,8'd2,2'b00} = 0xA008
        //   ssp_delta = 32, new_ssp = 0x4000-32 = 0x3FE0
        //   push1_data = {0xA008, 0x2700} = 0xA008_2700
        // ================================================================
        $display("--- EXC-3: Priority bus_err > illegal ---");
        begin_test;
        ssp_in    = 32'h0000_4000;
        fault_pc  = 32'h0000_3000;
        fault_sr  = 16'h2700;
        exc_rdata = 32'h0000_8000;
        bus_err_req = 1; illegal_req = 1;
        @(posedge clk_4x); #1;
        bus_err_req = 0; illegal_req = 0;
        wait_idle;

        chk32("EXC-3 push1_data",  t_wdata[1], 32'hA008_2700);  // vec=2, fmt=$A
        if (trans_cnt !== 5'd9) begin
            $display("FAIL EXC-3 trans_cnt=%0d (exp 9)", trans_cnt);
            fail = fail + 1;
        end else $display("PASS EXC-3 trans_cnt=9 (8 writes + 1 read)");
        chk32("EXC-3 ssp_out",     last_ssp,   32'h0000_3FE0);  // 0x4000-32

        // ================================================================
        // EXC-4: CHK → format $2, vec=6, 3 LW writes + 1 read = 4 trans
        //   ssp=0x3000, ssp_delta=12, new_ssp=0x2FF4
        //   fmtvec = {4'h2,2'b00,8'd6,2'b00} = 0x2018
        //   push[0]: addr=0x2FFC  data=fault_pc
        //   push[1]: addr=0x2FF8  data={0x2018,0x2700}
        //   push[2]: addr=0x2FF4  data=fault_addr
        // ================================================================
        $display("--- EXC-4: CHK format $2 ---");
        begin_test;
        ssp_in    = 32'h0000_3000;
        fault_pc  = 32'h0000_2500;
        fault_sr  = 16'h2700;
        fault_addr = 32'hDEAD_BEEF;
        exc_rdata = 32'h0000_7000;
        chk_req  = 1;
        @(posedge clk_4x); #1;
        chk_req  = 0;
        wait_idle;

        chk32("EXC-4 push0_addr",  t_addr[0],  32'h0000_2FFC);
        chk32("EXC-4 push0_data",  t_wdata[0], 32'h0000_2500);
        chk32("EXC-4 push1_addr",  t_addr[1],  32'h0000_2FF8);
        chk32("EXC-4 push1_data",  t_wdata[1], 32'h2018_2700);
        chk32("EXC-4 push2_addr",  t_addr[2],  32'h0000_2FF4);
        chk32("EXC-4 push2_data",  t_wdata[2], 32'hDEAD_BEEF);
        chk32("EXC-4 ssp_out",     last_ssp,   32'h0000_2FF4);
        if (trans_cnt !== 5'd4) begin
            $display("FAIL EXC-4 trans_cnt=%0d (exp 4)", trans_cnt);
            fail = fail + 1;
        end else $display("PASS EXC-4 trans_cnt=4");

        // ================================================================
        // EXC-5: Interrupt auto-vector level 3
        //   ipl_sync=3 > ipl_mask=1 → int_pending=1
        //   vec = VEC_AV1-1+3 = 25-1+3 = 27
        //   fetch_addr = VBR + 27*4 = 0x6C
        //   new_sr: T=0, S=1, M=0, IPL=3 (updated), CCR from fault_sr=0x00
        //   fault_sr=0x2200 → [7:0]=0x00 → new_sr={00,1,0,0,011,00000000}=0x2300
        // ================================================================
        $display("--- EXC-5: Interrupt level 3 auto-vector ---");
        begin_test;
        ssp_in    = 32'h0000_5000;
        fault_pc  = 32'h0000_4000;
        fault_sr  = 16'h2200;  // S=1, IPL=1 (old mask)
        exc_rdata = 32'h0000_9000;
        ipl_mask  = 3'd1;
        ipl_sync  = 3'd3;
        @(posedge clk_4x); #1;  // FSM snaps ipl_sync=3
        ipl_sync  = 3'd0;
        wait_idle;

        chk32("EXC-5 fetch_addr",  t_addr[2],  32'h0000_006C);  // 27*4=108=0x6C
        chk16("EXC-5 new_sr",      last_new_sr, 16'h2300);  // IPL updated to 3

        // ================================================================
        // EXC-6: Divide-by-zero, VBR=0x10000, vec=5
        //   fetch_addr = 0x10000 + 5*4 = 0x10014
        //   fault_sr=0x2014 → T=0, S=1, IPL=0, CCR=0x14 → new_sr=0x2014
        // ================================================================
        $display("--- EXC-6: Divide-by-zero, non-zero VBR ---");
        begin_test;
        ssp_in    = 32'h0000_6000;
        vbr_in    = 32'h0001_0000;
        fault_pc  = 32'h0001_0100;
        fault_sr  = 16'h2014;  // S=1, IPL=0, X=1 Z=1
        exc_rdata = 32'hFFFF_0000;
        div_zero_req = 1;
        @(posedge clk_4x); #1;
        div_zero_req = 0;
        wait_idle;

        chk32("EXC-6 fetch_addr",  t_addr[2],  32'h0001_0014);
        chk32("EXC-6 new_pc",      last_new_pc, 32'hFFFF_0000);
        chk16("EXC-6 new_sr",      last_new_sr, 16'h2014);  // T already 0, S=1

        // ================================================================
        // EXC-7: Privilege violation, vec=8
        //   fault_sr=0x0000 (user mode, T=0) → new_sr has S=1
        // ================================================================
        $display("--- EXC-7: Privilege violation ---");
        begin_test;
        ssp_in    = 32'h0000_7000;
        fault_pc  = 32'h0000_6000;
        fault_sr  = 16'h0000;  // user mode
        exc_rdata = 32'h0000_A000;
        priv_req  = 1;
        @(posedge clk_4x); #1;
        priv_req  = 0;
        wait_idle;

        // fmtvec={4'h0,2'b00,8'd8,2'b00}=0x0020
        chk32("EXC-7 push1_data",  t_wdata[1], 32'h0020_0000);  // {fmtvec,sr}
        // fetch_addr = 8*4 = 0x20
        chk32("EXC-7 fetch_addr",  t_addr[2],  32'h0000_0020);
        // new_sr: T=0, S=1, M=0, IPL=0, CCR=0x00 → 0x2000
        chk16("EXC-7 new_sr",      last_new_sr, 16'h2000);

        // ================================================================
        // EXC-8: Address error → format $3, vec=3, 4 LW writes
        //   ssp=0x8000, ssp_delta=16, new_ssp=0x7FF0
        //   push[0]: 0x7FFC  data=fault_pc
        //   push[1]: 0x7FF8  data={fmtvec,sr}  fmtvec={4'h3,2'b00,8'd3,2'b00}=0x300C
        //   push[2]: 0x7FF4  data=fault_addr
        //   push[3]: 0x7FF0  data={fault_ssw,16'h0}
        // ================================================================
        $display("--- EXC-8: Address error format $3 ---");
        begin_test;
        ssp_in     = 32'h0000_8000;
        fault_pc   = 32'h0000_7500;
        fault_sr   = 16'h2000;
        fault_addr = 32'h0000_0001;  // odd address
        fault_ssw  = 16'h0041;       // example SSW value
        exc_rdata  = 32'h0000_B000;
        addr_err_req = 1;
        @(posedge clk_4x); #1;
        addr_err_req = 0;
        wait_idle;

        // fmtvec = {4'h3,2'b00,8'd3,2'b00} = {0011_00_00000011_00} = 0x300C
        chk32("EXC-8 push1_data",  t_wdata[1], 32'h300C_2000);
        chk32("EXC-8 push2_data",  t_wdata[2], 32'h0000_0001);  // fault_addr
        chk32("EXC-8 push3_data",  t_wdata[3], 32'h0041_0000);  // {ssw,0}
        chk32("EXC-8 ssp_out",     last_ssp,   32'h0000_7FF0);
        if (trans_cnt !== 5'd5) begin
            $display("FAIL EXC-8 trans_cnt=%0d (exp 5)", trans_cnt);
            fail = fail + 1;
        end else $display("PASS EXC-8 trans_cnt=5 (4 writes + 1 read)");

        // ================================================================
        if (fail == 0)
            $display("ALL EXC TESTS PASSED");
        else
            $display("%0d EXC TEST(S) FAILED", fail);

        $finish;
    end

    // Watchdog
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

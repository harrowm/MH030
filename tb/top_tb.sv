`default_nettype none
`timescale 1ps/1ps

// MC68030 m68030_top smoke-test (Phase 22 + Phase 34)
//
//   P22-1: init_done fires; init_ssp/init_pc hold the reset vector values.
//   P22-2: post-init pin checks (RSTOUT# deasserted; IFU active).
//   P22-3: bus_halted asserts while halt_n is low; AS# silent; resumes after.
//   P22-4: eu_addr_err / ifu_addr_err are not spuriously asserted.
//   P34-1: EU pc_out equals init_pc one cycle after boot_pulse.
//   P34-2: EU isp_out equals init_ssp one cycle after boot_pulse.
//   P34-3: IFU begins fetching from init_pc (ifu_req asserted, addr matches).

module top_tb;

    // -----------------------------------------------------------------------
    // Clock + reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;   // 100 MHz → 10 ps period

    logic rst_n = 0;

    // -----------------------------------------------------------------------
    // External pin buses
    // -----------------------------------------------------------------------
    logic [31:0] ext_a;
    logic [31:0] ext_d_out;    // BIU → bus (writes)
    wire  [31:0] ext_d_in;     // bus → BIU (reads, driven by mem_model)
    logic        ext_d_oe;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_e;
    logic        ext_bg_n;

    // Async input pins — mem_model drives dsack*_n; rest are testbench-driven
    wire         dsack0_n;     // driven by mem_model
    wire         dsack1_n;
    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic        vpa_n    = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b0;   // CBACK# asserted (burst ok)

    // Phase 19/20 outputs from top
    logic        bus_halted;
    logic        eu_addr_err;
    logic        ifu_addr_err;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    m68030_top #(.POWERON_RSTO_CLKS(40)) u_top (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .ext_a        (ext_a),
        .ext_d_out    (ext_d_out),
        .ext_d_oe     (ext_d_oe),
        .ext_d_in     (ext_d_in),
        .ext_as_n     (ext_as_n),
        .ext_ds_n     (ext_ds_n),
        .ext_rw       (ext_rw),
        .ext_fc       (ext_fc),
        .ext_siz      (ext_siz),
        .ext_ecs_n    (ext_ecs_n),
        .ext_ocs_n    (ext_ocs_n),
        .ext_rstout_n (ext_rstout_n),
        .ext_cbreq_n  (ext_cbreq_n),
        .ext_e        (ext_e),
        .ext_bg_n     (ext_bg_n),
        .bus_halted   (bus_halted),
        .eu_addr_err  (eu_addr_err),
        .ifu_addr_err (ifu_addr_err),
        .dsack0_n     (dsack0_n),
        .dsack1_n     (dsack1_n),
        .sterm_n      (sterm_n),
        .berr_n       (berr_n),
        .halt_n       (halt_n),
        .avec_n       (avec_n),
        .vpa_n        (vpa_n),
        .ipl_n        (ipl_n),
        .br_n         (br_n),
        .bgack_n      (bgack_n),
        .cback_n      (cback_n)
    );

    // -----------------------------------------------------------------------
    // 32-bit memory model — responds with DSACK0+DSACK1
    // -----------------------------------------------------------------------
    mem_model #(.DEPTH(256), .PORT_WIDTH(32), .WAIT_STATES(0)) u_mem (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .ext_a       (ext_a),
        .ext_as_n    (ext_as_n),
        .ext_ds_n    (ext_ds_n),
        .ext_rw      (ext_rw),
        .ext_siz     (ext_siz),
        .ext_d_write (ext_d_out),
        .ext_d_oe    (ext_d_oe),
        .ext_d_in    (ext_d_in),
        .dsack0_n    (dsack0_n),
        .dsack1_n    (dsack1_n)
    );

    // -----------------------------------------------------------------------
    // Failure counter
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

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 22: m68030_top Integration Smoke Test ===");

        // Pre-load reset vectors
        u_mem.mem[0] = 32'hDEAD_BEF0;   // SSP @ 0x000000
        u_mem.mem[1] = 32'hCAFE_0010;   // PC  @ 0x000004

        // Release reset after 20 clocks
        repeat(20) @(posedge clk_4x);
        rst_n = 1'b1;

        // ----------------------------------------------------------------
        // P22-1: init_done fires; reset vectors correct; AS# toggles during init
        // All three checks happen inside one combined wait loop so we can
        // capture AS# activity that occurs *before* init_done rises.
        // ----------------------------------------------------------------
        $display("--- P22-1: init_done + reset vectors + AS# during init ---");
        begin
            int t; logic saw_init, saw_as_low, saw_as_deassert;
            saw_init = 0; saw_as_low = 0; saw_as_deassert = 0;
            for (t = 0; t < 300; t++) begin
                @(posedge clk_4x);
                if (!ext_as_n) saw_as_low = 1;
                if (saw_as_low && ext_as_n) saw_as_deassert = 1;
                if (u_top.u_biu.init_done) begin saw_init = 1; break; end
            end
            check("P22-1a: init_done fires",              saw_init);
            check32("P22-1b: init_ssp=$DEADBEF0",         u_top.u_biu.init_ssp, 32'hDEAD_BEF0);
            check32("P22-1c: init_pc=$CAFE0010",          u_top.u_biu.init_pc,  32'hCAFE_0010);
            check("P22-1d: AS# asserted during init",     saw_as_low);
            check("P22-1e: AS# deasserted (cycle ended)", saw_as_deassert);
        end
        // ----------------------------------------------------------------
        // P34-1/2: EU registers written by boot_pulse (fired inside P22-1 loop).
        // EU always_ff updates land 1 cycle after the boot_pulse posedge.
        // Wait 3 more cycles to be safe, then sample.
        // ----------------------------------------------------------------
        $display("--- P34-1/2: EU registers set from reset vectors ---");
        repeat(3) @(posedge clk_4x);
        begin
            check32("P34-1: EU pc_out == init_pc",
                    u_top.u_eu.pc_out, 32'hCAFE_0010);
            check32("P34-2: EU isp_out == init_ssp",
                    u_top.u_eu.isp_out, 32'hDEAD_BEF0);
        end

        // ----------------------------------------------------------------
        // P34-3: IFU begins fetching from init_pc.
        // boot_pulse clears fetch_pend_r; 1 cycle later the IFU reasserts it.
        // Check over 10 cycles for ifu_req high at addr 0xCAFE0010.
        // ----------------------------------------------------------------
        $display("--- P34-3: IFU fetching from init_pc ---");
        begin
            logic saw_ifu_req;
            logic [31:0] init_pc_val;
            int t;
            init_pc_val = 32'hCAFE_0010;
            saw_ifu_req = 0;
            for (t = 0; t < 10; t++) begin
                @(posedge clk_4x);
                if (u_top.ifu_bus_req &&
                    u_top.ifu_bus_addr[31:2] == init_pc_val[31:2])
                    saw_ifu_req = 1;
            end
            check("P34-3: IFU request at init_pc address seen", saw_ifu_req);
        end
        repeat(5) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // P22-2: post-init external pin checks
        // ----------------------------------------------------------------
        $display("--- P22-2: post-init pin state ---");
        begin
            @(posedge clk_4x);
            check("P22-2a: RSTOUT# deasserted after init", ext_rstout_n === 1'b1);
            // IFU is now live and immediately begins fetching — bus_idle=0 is correct.
            check("P22-2b: IFU active after boot (bus not idle)", !u_top.u_biu.bus_idle);
        end
        repeat(8) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // P22-3: bus_halted asserts while halt_n low; AS# silent; resumes after
        // ----------------------------------------------------------------
        $display("--- P22-3: bus_halted via top-level HALT# pin ---");
        begin
            int t; logic saw_halted, saw_as_during_halt;
            // Wait for any in-progress cycle to end (AS# deasserted)
            for (t = 0; t < 50; t++) begin
                @(posedge clk_4x);
                if (ext_as_n) break;
            end
            halt_n = 1'b0;
            saw_halted = 0; saw_as_during_halt = 0;
            repeat(40) @(posedge clk_4x) begin
                if (bus_halted) saw_halted = 1;
                if (!ext_as_n)  saw_as_during_halt = 1;
            end
            check("P22-3a: bus_halted asserts",           saw_halted);
            check("P22-3b: AS# not driven during HALT#",  !saw_as_during_halt);
            halt_n = 1'b1;
            begin
                logic halted_cleared;
                halted_cleared = 0;
                for (t = 0; t < 40; t++) begin
                    @(posedge clk_4x);
                    if (!bus_halted) begin halted_cleared = 1; break; end
                end
                check("P22-3c: bus_halted clears after HALT# release", halted_cleared);
            end
        end
        repeat(8) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // P22-4: addr_err outputs stable at idle (no spurious assertions)
        // ----------------------------------------------------------------
        $display("--- P22-4: addr_err outputs not spuriously asserted ---");
        begin
            @(posedge clk_4x);
            check("P22-4a: eu_addr_err quiescent",  !eu_addr_err);
            check("P22-4b: ifu_addr_err quiescent", !ifu_addr_err);
        end

        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

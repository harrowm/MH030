`default_nettype none
`timescale 1ps/1ps

// MC68030 m68030_top integration smoke-test
//
// Tests the top-level chip integration: reset/init sequence, EU register
// initialisation from reset vectors, IFU prefetch startup, HALT# pin
// behaviour, address-error quiescence, and basic instruction execution.
//
// Checks:
//   - init_done fires and SSP/PC are fetched from reset vectors
//   - RSTOUT# deasserts after init; IFU goes active
//   - bus_halted asserts while HALT# low; AS# is silent; bus resumes after
//   - eu_addr_err / ifu_addr_err are not spuriously asserted at idle
//   - EU pc_out and isp_out reflect reset vector values after boot
//   - IFU begins fetching from init_pc
//   - MOVEQ #42,D0 and MOVEQ #17,D1 execute correctly (no deadlock)

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
    logic        ciin_n   = 1'b1;   // Phase 158 Stage 7: CIIN# deasserted (not asserted)

    // Additional top-level outputs
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
        .cback_n      (cback_n),
        .ciin_n       (ciin_n),
        .ciout_n      ()
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
        $display("=== m68030_top Integration Smoke Test ===");

        // Pre-load reset vectors (PC=0x8 keeps code within mem_model range)
        u_mem.mem[0] = 32'hDEAD_BEF0;   // SSP @ 0x000000
        u_mem.mem[1] = 32'h0000_0008;   // PC  @ 0x000004 → start at 0x8

        // Instruction code starting at 0x8 (word index 2)
        // 0x08: MOVEQ #42,D0 (702A) | MOVEQ #17,D1 (7211) — consecutive
        // 0x0C: NOP (4E71) | NOP (4E71)
        // 0x10: NOP (4E71) | NOP (4E71)  — just NOPs after; no BRA needed
        u_mem.mem[2] = 32'h702A_7211;
        u_mem.mem[3] = 32'h4E71_4E71;
        u_mem.mem[4] = 32'h4E71_4E71;

        // Release reset after 20 clocks
        repeat(20) @(posedge clk_4x);
        rst_n = 1'b1;

        // ----------------------------------------------------------------
        // Reset init: init_done fires; reset vectors fetched; AS# cycles
        // ----------------------------------------------------------------
        $display("--- init_done + reset vectors + AS# during init ---");
        begin
            int t; logic saw_init, saw_as_low, saw_as_deassert;
            saw_init = 0; saw_as_low = 0; saw_as_deassert = 0;
            for (t = 0; t < 300; t++) begin
                @(posedge clk_4x);
                if (!ext_as_n) saw_as_low = 1;
                if (saw_as_low && ext_as_n) saw_as_deassert = 1;
                if (u_top.u_biu.init_done) begin saw_init = 1; break; end
            end
            check("init_done fires",              saw_init);
            check32("init_ssp=$DEADBEF0",         u_top.u_biu.init_ssp, 32'hDEAD_BEF0);
            check32("init_pc=$00000008",          u_top.u_biu.init_pc,  32'h0000_0008);
            check("AS# asserted during init",     saw_as_low);
            check("AS# deasserted (cycle ended)", saw_as_deassert);
        end
        // EU registers loaded from reset vectors one cycle after boot_pulse
        $display("--- EU registers set from reset vectors ---");
        repeat(3) @(posedge clk_4x);
        begin
            check32("EU pc_out == init_pc",    u_top.u_eu.pc_out,  32'h0000_0008);
            check32("EU isp_out == init_ssp",  u_top.u_eu.isp_out, 32'hDEAD_BEF0);
        end

        // IFU begins fetching: boot_pulse clears fetch_pend_r; IFU reasserts next cycle
        $display("--- IFU fetching from init_pc ---");
        begin
            logic saw_ifu_req;
            logic [31:0] init_pc_val;
            int t;
            init_pc_val = 32'h0000_0008;
            saw_ifu_req = 0;
            for (t = 0; t < 10; t++) begin
                @(posedge clk_4x);
                if (u_top.ifu_bus_req &&
                    u_top.ifu_bus_addr[31:2] == init_pc_val[31:2])
                    saw_ifu_req = 1;
            end
            check("IFU request at init_pc seen", saw_ifu_req);
        end
        repeat(5) @(posedge clk_4x);

        // Post-init pin state
        $display("--- post-init pin state ---");
        begin
            @(posedge clk_4x);
            check("RSTOUT# deasserted after init", ext_rstout_n === 1'b1);
            // IFU is now live and immediately begins fetching — bus_idle=0 is correct.
            check("IFU active after boot (bus not idle)", !u_top.u_biu.bus_idle);
        end
        repeat(8) @(posedge clk_4x);

        // HALT# assertion: bus_halted asserts; AS# silent; bus resumes on release
        $display("--- bus_halted via top-level HALT# pin ---");
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
            check("bus_halted asserts",           saw_halted);
            check("AS# not driven during HALT#",  !saw_as_during_halt);
            halt_n = 1'b1;
            begin
                logic halted_cleared;
                halted_cleared = 0;
                for (t = 0; t < 40; t++) begin
                    @(posedge clk_4x);
                    if (!bus_halted) begin halted_cleared = 1; break; end
                end
                check("bus_halted clears after HALT# release", halted_cleared);
            end
        end
        repeat(8) @(posedge clk_4x);

        // Address error outputs must not assert spuriously at idle
        $display("--- addr_err outputs quiescent ---");
        begin
            @(posedge clk_4x);
            check("eu_addr_err quiescent",  !eu_addr_err);
            check("ifu_addr_err quiescent", !ifu_addr_err);
        end

        // Instruction execution: MOVEQ #42,D0 + MOVEQ #17,D1
        $display("--- instruction execution (MOVEQ → D0, D1) ---");
        begin
            int t;
            logic got_d0, got_d1;
            got_d0 = 0; got_d1 = 0;
            for (t = 0; t < 800; t++) begin
                @(posedge clk_4x);
                if (u_top.u_eu.u_rf.d_reg[0] == 32'd42) got_d0 = 1;
                if (u_top.u_eu.u_rf.d_reg[1] == 32'd17) got_d1 = 1;
                if (got_d0 && got_d1) break;
            end
            check("D0 = 42 after MOVEQ #42,D0", got_d0);
            check("D1 = 17 after MOVEQ #17,D1", got_d1);
            check("No deadlock (completed in time)", t < 800);
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

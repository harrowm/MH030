`default_nettype none
`timescale 1ps/1ps

// Phase 159 Stage 0: Instruction Execution Timing measurement testbench.
//
// Measures, for ONE isolated instruction under test, the elapsed external-
// bus-clock count (external clock = 4 clk_4x ticks, per this project's own
// 4x-oversampling design) between the first bus request for the
// instruction's own opcode word (its "Head=0, no overlap" starting point,
// matching MC68030UM.pdf Section 11's CC/NCC definition) and a
// caller-specified register reaching a caller-specified value (its own
// retirement marker). Also tallies (r/p/w) bus-cycle counts in that same
// window, categorized by FC + R/W, for comparison against the manual's own
// per-instruction (read/prefetch/write) breakdown.
//
// Usage: vvp sim/timing +hexfile=tests/timing0.hex +target_pc=1c
//        +watch_reg=2 +watch_val=deadbeef
//        [+expect_r=1 +expect_p=2 +expect_w=0] [+expect_clocks=9]
//
// The test program itself must isolate the instruction under test with a
// taken branch landing directly on it (so the IFU has no real prefetch
// head start), matching NCC's own "no overlap with the preceding
// instruction" definition -- see tests/timing0.s for the established
// pattern.
//
// Phase 161 Part A Stage A0: +expect_r/+expect_p/+expect_w, when supplied,
// are asserted (real pass/fail) against the manual's own per-instruction
// resource-count tables -- this is what the §11.6 sweep actually checks.
// +expect_clocks remains informational only (see the comment further down):
// total-clock parity is Part B's own separate, not-yet-attempted goal.

module timing_tb;

    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_e, ext_bg_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic        vpa_n    = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b0;
    logic        ciin_n   = 1'b1;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    string hexfile;
    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        if (!$value$plusargs("hexfile=%s", hexfile))
            hexfile = "tests/timing0.hex";
        $readmemh(hexfile, rom);
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    logic ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) ds_active_r <= 1'b0;
        else        ds_active_r <= !ext_ds_n & !ext_as_n;
    end

    wire dsack0_n = ~ds_active_r;
    wire dsack1_n = ~ds_active_r;

    wire [31:0] ext_d_in = (!ext_ds_n & ext_rw) ? rd_word : {32{1'bz}};

    always_ff @(posedge clk_4x) begin
        if (ds_active_r && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
            if (ext_a[13:2] < MEM_WORDS) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: rom[ext_a[13:2]]        <= ext_d_out;
                    4'b10_00: rom[ext_a[13:2]][31:16] <= ext_d_out[31:16];
                    4'b10_10: rom[ext_a[13:2]][15:0]  <= ext_d_out[15:0];
                    4'b01_00: rom[ext_a[13:2]][31:24] <= ext_d_out[31:24];
                    4'b01_01: rom[ext_a[13:2]][23:16] <= ext_d_out[23:16];
                    4'b01_10: rom[ext_a[13:2]][15:8]  <= ext_d_out[15:8];
                    4'b01_11: rom[ext_a[13:2]][7:0]   <= ext_d_out[7:0];
                    default:  rom[ext_a[13:2]]        <= ext_d_out;
                endcase
            end
        end
    end

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

    // ── Free-running tick counter (clk_4x ticks; /4 = external bus clocks) ──
    longint unsigned sim_ticks = 0;
    always_ff @(posedge clk_4x) sim_ticks <= sim_ticks + 1;

    // ── Bus event edge detection (address-phase, i.e. AS falling edge) ──────
    logic        as_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) as_prev_r <= 1'b1;
        else        as_prev_r <= ext_as_n;
    end
    wire as_fall = as_prev_r && !ext_as_n;   // address phase begins this tick

    // ── Measurement window ───────────────────────────────────────────────
    logic [31:0] target_pc;
    int          watch_reg;
    logic [31:0] watch_val;

    logic        t_start_seen = 1'b0;
    logic        t_end_seen   = 1'b0;
    longint unsigned t_start = 0;
    longint unsigned t_end   = 0;

    int r_count = 0, p_count = 0, w_count = 0;

    wire is_prog_fc = (ext_fc == 3'b110) || (ext_fc == 3'b010);
    wire is_data_fc = (ext_fc == 3'b101) || (ext_fc == 3'b001);

    logic dbg_on = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (as_fall) begin
            if (!t_start_seen && is_prog_fc && ext_rw && (ext_a == target_pc)) begin
                t_start_seen <= 1'b1;
                t_start      <= sim_ticks;
                dbg_on       <= 1'b1;
            end
            if (!t_end_seen &&
                (t_start_seen || (is_prog_fc && ext_rw && ext_a == target_pc))) begin
                if (is_prog_fc && ext_rw)      p_count <= p_count + 1;
                else if (is_data_fc && ext_rw) r_count <= r_count + 1;
                else if (!ext_rw)              w_count <= w_count + 1;
            end
            if (dbg_on && !t_end_seen)
                $display("  [tick=%0d] AS-fall  %s %h fc=%b siz=%b",
                          sim_ticks, ext_rw ? "R" : "W", ext_a, ext_fc, ext_siz);
        end
        if (dbg_on && !t_end_seen && !as_prev_r && ext_as_n)
            $display("  [tick=%0d] AS-rise", sim_ticks);
    end

    logic [31:0] watch_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) watch_prev_r <= 32'h0;
        else        watch_prev_r <= u_top.u_eu.u_rf.d_reg[watch_reg];
    end

    always_ff @(posedge clk_4x) begin
        if (t_start_seen && !t_end_seen &&
            u_top.u_eu.u_rf.d_reg[watch_reg] == watch_val &&
            watch_prev_r != watch_val) begin
            t_end_seen <= 1'b1;
            t_end      <= sim_ticks;
            $display("  [tick=%0d] WATCH d%0d == %h (retirement)", sim_ticks, watch_reg, watch_val);
        end
    end

    // ── STOP detection (safety net) ─────────────────────────────────────
    logic stop_seen = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (!ext_as_n && !ext_ds_n && ext_rw &&
            (ext_fc == 3'b110 || ext_fc == 3'b010)) begin
            if (rd_word[31:16] == 16'h4E72 || rd_word[15:0] == 16'h4E72)
                stop_seen <= 1'b1;
        end
    end

    // ── Test ─────────────────────────────────────────────────────────────
    int  fail_count = 0;
    task automatic check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    initial begin
        longint unsigned tpc_arg, wreg_arg, wval_arg, exp_clocks;
        int exp_r, exp_p, exp_w;
        bit have_exp, have_rpw;

        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        if (!$value$plusargs("target_pc=%h", tpc_arg)) tpc_arg = 32'h0;
        target_pc = tpc_arg[31:0];
        if (!$value$plusargs("watch_reg=%d", wreg_arg)) wreg_arg = 0;
        watch_reg = wreg_arg[2:0];
        if (!$value$plusargs("watch_val=%h", wval_arg)) wval_arg = 32'h0;
        watch_val = wval_arg[31:0];
        have_exp = $value$plusargs("expect_clocks=%d", exp_clocks);
        exp_r = 0; exp_p = 0; exp_w = 0;
        begin
            bit got_r, got_p, got_w;
            got_r = $value$plusargs("expect_r=%d", exp_r);
            got_p = $value$plusargs("expect_p=%d", exp_p);
            got_w = $value$plusargs("expect_w=%d", exp_w);
            have_rpw = got_r || got_p || got_w;
        end

        fork
            begin : blk_timeout
                repeat(20000) @(posedge clk_4x);
            end
            begin : blk_stop
                wait(t_end_seen == 1'b1);
                repeat(20) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        check("target instruction's own opcode fetch observed", t_start_seen);
        check("watch register reached expected value",          t_end_seen);

        if (t_start_seen && t_end_seen) begin
            longint unsigned total_ticks, total_clocks, rem;
            total_ticks  = t_end - t_start;
            total_clocks = total_ticks / 4;
            rem          = total_ticks % 4;
            $display("MEASURED ticks=%0d clocks=%0d rem=%0d  r=%0d p=%0d w=%0d",
                      total_ticks, total_clocks, rem, r_count, p_count, w_count);
            // Phase 160 Stage 1: t_end is an internal register-file commit, not
            // a pin transition -- it need not land on a 4-tick (real-clock)
            // boundary the way AS/DS assert/deassert must, so "total_ticks is
            // a multiple of 4" is not a meaningful invariant here (confirmed
            // via debug trace: every AS transition consistently lands at the
            // same tick residue mod 4, i.e. real pin timing stays clock-
            // aligned; only the internal WB-commit tick, measured relative to
            // it, differs by a fixed sub-clock offset). Not asserted.
            // total_clocks is reported for visibility, not asserted against
            // expect_clocks: NCC also includes real 68030 "internal" (non-bus)
            // microcode clocks (see MC68030UM.pdf 11-25's own worked example)
            // this RTL's simplified comb-decode/1-cycle-EX/WB pipeline was
            // never designed to reproduce cycle-for-cycle -- see plan.md
            // Phase 159 Stage 0 / Phase 160 Stage 9. What Stage 1 actually
            // gates on is the r/p/w bus-cycle breakdown, which the manual's
            // own tables predict exactly regardless of this gap.
            if (have_exp)
                $display("  (expected total clocks: %0d -- informational only, not asserted)",
                          exp_clocks);
            if (have_rpw) begin
                check($sformatf("r/p/w == %0d/%0d/%0d (MC68030UM.pdf Section 11)",
                                 exp_r, exp_p, exp_w),
                      (r_count == exp_r) && (p_count == exp_p) && (w_count == exp_w));
            end
        end

        if (fail_count == 0) $display("PASS  timing");
        else                 $display("FAIL  timing (%0d)", fail_count);
        $finish;
    end

endmodule

`default_nettype wire

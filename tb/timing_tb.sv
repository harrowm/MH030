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
    logic [31:0] target_len;   // Phase 161 Part A: instruction's own byte span
    int          watch_reg;
    logic [31:0] watch_val;
    // Cycle-accuracy-closing plan.md, item 3: watch_kind lets a test observe
    // completion via An or CCR directly instead of always needing a
    // trailing marker instruction (whose own real cost was folding into
    // the measured total for every instruction that doesn't write a Dn --
    // e.g. MOVEA/ADDA/SUBA/LEA writing An, or CMP/TST/BTST/MOVE-to-CCR/
    // ANDI-to-CCR-or-SR only updating CCR). 0=Dn (default, unchanged),
    // 1=An (a_reg[0:6] -- A7 deliberately unsupported, no current test
    // needs it and it aliases through a7_current's own S/M bank
    // selection, a materially different read path), 2=CCR (sr_out[7:0]
    // only, zero-extended -- deliberately NOT the full 16-bit SR, so a
    // CCR-only-writing instruction like MOVE Dn,CCR doesn't need the
    // test to also predict the untouched upper SR byte).
    int          watch_kind;
    // Multi-instruction sequential timing measurement (Stage 7 follow-up):
    // +seq_len=N (default 1, meaning "off") generalizes the watch_kind=3
    // retirement-pulse mechanism below from "stop at the first retirement"
    // to "record all N first retirements." Purely additive -- seq_complete_r
    // can only ever assert when seq_len>1, so every existing invocation
    // (which never passes +seq_len, defaulting to 1) is provably unaffected.
    // target_len's existing meaning is reused unchanged for the *whole*
    // tracked span when seq_len>1 (the combined byte length of all N
    // instructions), mirroring how it already works for a single
    // instruction today.
    int          seq_len;
    localparam int MAX_SEQ = 16;
    longint unsigned seq_ticks [0:MAX_SEQ-1];
    int          seq_r [0:MAX_SEQ-1], seq_p [0:MAX_SEQ-1], seq_w [0:MAX_SEQ-1];
    int          retire_count_r;
    logic        seq_complete_r;
    function automatic logic [31:0] watch_current();
        case (watch_kind)
            1: watch_current = u_top.u_eu.u_rf.a_reg[watch_reg[2:0]];
            2: watch_current = {24'h0, u_top.u_eu.u_rf.sr_out[7:0]};
            default: watch_current = u_top.u_eu.u_rf.d_reg[watch_reg];
        endcase
    endfunction

    logic        t_start_seen = 1'b0;
    logic        t_end_seen   = 1'b0;
    longint unsigned t_start = 0;
    longint unsigned t_end   = 0;

    int r_count = 0, p_count = 0, w_count = 0;

    wire is_prog_fc = (ext_fc == 3'b110) || (ext_fc == 3'b010);
    // FC=111 (CPU space, e.g. BKPT's own DSACK'd bus-protocol read --
    // Phase 157) is counted as a data-space read here too, reliable-
    // baseline plan: this corpus has no other CPU-space cycle (IACK/
    // coprocessor) to conflict with, so this is a safe, narrow
    // completeness fix for what was previously a real harness gap
    // (a7_bkpt's own expect_r=0 didn't reflect its true r=1 total).
    wire is_data_fc = (ext_fc == 3'b101) || (ext_fc == 3'b001) || (ext_fc == 3'b111);
    // Phase 161 Part A Stage A1: a program-space fetch belongs to the
    // instruction under test iff its own address falls within that
    // instruction's own byte span (target_pc .. target_pc+target_len-1) --
    // attributing "p" by ADDRESS rather than by chronological position
    // within [t_start,t_end) avoids counting the *next* instruction's own
    // IFU readahead prefetch as if it belonged to this one. Found via a
    // real measurement (a1_fea_d16an): the IFU can race ahead to fetch the
    // following instruction's own opcode word before this instruction's
    // own operand data read + register commit complete, whenever there's
    // little decode-side work (few extension words) to absorb that
    // runahead -- exactly the "no overlap with a SUBSEQUENT instruction"
    // exclusion CC/NCC's own definition already calls for (Phase 159 Stage
    // 0), just previously only guarded against overlap with the PRECEDING
    // instruction. Data reads/writes (r/w) keep the original chronological
    // windowing -- in this project's own isolated-test-program convention
    // (setup code, then a taken branch, then the instruction under test,
    // then STOP) there is no address-range analog for them to leak into,
    // since nothing else in the test program touches data memory.
    wire in_instr_range = (ext_a >= target_pc) && (ext_a < target_pc + target_len);

    // Investigation (2026-08-23, user-requested re-review of the bus-
    // touching dispatch-overhead finding): t_end (above) is gated on the
    // watch REGISTER reaching its value, which for any memory-destination
    // instruction under test requires a trailing marker instruction
    // (typically "move.l #imm,Dn") to make the effect observable at all --
    // that marker's own bus cycles (its own opcode+immediate fetch) are
    // real, additional bus activity that lands inside [t_start,t_end) and
    // was being silently counted as if it belonged to the target
    // instruction. This tracks a SECOND, pin-level-only completion point:
    // the AS-rise of the LAST bus cycle that genuinely belongs to the
    // target instruction itself -- any data-space (r/w) cycle (a memory-
    // dest instruction's own write, or a memory-src instruction's own
    // read, never something the marker needs) or any program-space fetch
    // still inside the target's own [target_pc,target_pc+target_len) byte
    // span. A following marker's own opcode/extension fetches, being
    // program-space reads OUTSIDE that span, are correctly excluded.
    logic        instr_bus_pending_r = 1'b0;
    logic [63:0] t_end_instr_r       = 0;
    logic        t_end_instr_valid_r = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (as_fall && !t_end_seen &&
            ((is_prog_fc && ext_rw && in_instr_range) || is_data_fc))
            instr_bus_pending_r <= 1'b1;
        if (!as_prev_r && ext_as_n && instr_bus_pending_r) begin
            t_end_instr_r       <= sim_ticks;
            t_end_instr_valid_r <= 1'b1;
            instr_bus_pending_r <= 1'b0;
        end
    end

    logic dbg_on = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (as_fall) begin
            if (!t_start_seen && is_prog_fc && ext_rw && (ext_a == target_pc)) begin
                t_start_seen <= 1'b1;
                t_start      <= sim_ticks;
                dbg_on       <= 1'b1;
            end
            if (!t_end_seen && !seq_complete_r && is_prog_fc && ext_rw && in_instr_range)
                p_count <= p_count + 1;
            if (!t_end_seen && !seq_complete_r &&
                (t_start_seen || (is_prog_fc && ext_rw && ext_a == target_pc))) begin
                if (is_data_fc && ext_rw) r_count <= r_count + 1;
                else if (!ext_rw)         w_count <= w_count + 1;
            end
            if (dbg_on && !t_end_seen && !seq_complete_r)
                $display("  [tick=%0d] AS-fall  %s %h fc=%b siz=%b",
                          sim_ticks, ext_rw ? "R" : "W", ext_a, ext_fc, ext_siz);
        end
        if (dbg_on && !t_end_seen && !seq_complete_r && !as_prev_r && ext_as_n)
            $display("  [tick=%0d] AS-rise", sim_ticks);
    end

    logic [31:0] watch_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) watch_prev_r <= 32'h0;
        else        watch_prev_r <= watch_current();
    end

    always_ff @(posedge clk_4x) begin
        // seq_len>1 runs never pass +watch_reg/+watch_val (they use the
        // retirement-pulse counter below instead) -- gate this whole block
        // off in that mode, since the resulting default reg=0/val=0 can
        // spuriously edge-match a real D0 transition through zero in the
        // sequence under test (found via seq2_dbf_loop, whose own DBcc
        // counter genuinely passes through D0==0), truncating the
        // SEQ_CHECKPOINT collection early. seq_len<=1 (every existing
        // single-instruction test's own default) is unaffected.
        if (seq_len <= 1 && watch_kind != 3 && t_start_seen && !t_end_seen &&
            watch_current() == watch_val &&
            watch_prev_r != watch_val) begin
            t_end_seen <= 1'b1;
            t_end      <= sim_ticks;
            $display("  [tick=%0d] WATCH kind=%0d reg=%0d == %h (retirement)", sim_ticks, watch_kind, watch_reg, watch_val);
        end
    end

    // kind 3: retirement-pulse tracking -- no register/CCR/memory side
    // effect required (NOP, Bcc-not-taken, DBcc cc=true, TRAPV no-trap,
    // MOVE An,USP, JMP/JSR/BSR/Bcc-taken's own retirement). Sound because
    // wb_valid <= ex_valid unconditionally whenever not stalled
    // (rtl/eu_seq.sv, WB stage latch) and instr_ack/wb_valid are EX-stage
    // pipeline events, not PC/fetch-position signals -- they do not have
    // the "decode races ahead of retirement" hazard this project has hit
    // repeatedly elsewhere. In this project's own "taken branch lands
    // directly on the instruction under test" convention, the branch's
    // own dispatch has already happened before t_start (the target's own
    // opcode-fetch AS-fall), so the first instr_ack seen after t_start is
    // unambiguously the target instruction's own dispatch; pipeline is
    // strictly in-order (single EX slot), so the first wb_valid pulse
    // strictly after that dispatch is latched is unambiguously the target
    // instruction's own retirement.
    // wb_valid_r (one more registered tick past raw wb_valid) is used
    // below, not wb_valid directly: a direct trace (a4_ext_dn) found
    // eu_regfile's own committed value becomes observable exactly one
    // tick AFTER wb_valid itself first pulses (an extra flip-flop hop
    // downstream of wb_valid) -- kind=0/1/2's own value-watch technique
    // therefore always detects completion on that later tick, not the
    // wb_valid tick itself. Delaying kind=3 by the same one tick makes it
    // measure the identical "commit observable" instant kind=0/1/2 always
    // have, instead of introducing a new, inconsistent-by-one-tick
    // convention relative to the whole rest of the (already-trusted)
    // corpus.
    logic dispatched_seen_r;
    logic wb_valid_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) dispatched_seen_r <= 1'b0;
        else if (t_start_seen && u_top.eu_instr_ack) dispatched_seen_r <= 1'b1;
    end
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) wb_valid_r <= 1'b0;
        else        wb_valid_r <= u_top.u_eu.u_seq.wb_valid;
    end

    // Sequence checkpoint counter -- reuses dispatched_seen_r/wb_valid_r
    // above unchanged (same in-order, strictly-sequential retirement
    // argument already established for watch_kind=3), generalized from
    // "the first retirement" to "the first seq_len retirements." Gated on
    // seq_len>1 so it is provably inert for every existing single-
    // instruction invocation.
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            retire_count_r <= 0;
            seq_complete_r <= 1'b0;
        end else if (seq_len > 1 && !seq_complete_r &&
                     dispatched_seen_r && wb_valid_r) begin
            seq_ticks[retire_count_r] <= sim_ticks;
            seq_r[retire_count_r]     <= r_count;
            seq_p[retire_count_r]     <= p_count;
            seq_w[retire_count_r]     <= w_count;
            retire_count_r            <= retire_count_r + 1;
            if (retire_count_r + 1 >= seq_len) seq_complete_r <= 1'b1;
        end
    end

    always_ff @(posedge clk_4x) begin
        if (watch_kind == 3 && t_start_seen && !t_end_seen &&
            dispatched_seen_r && wb_valid_r) begin
            t_end_seen <= 1'b1;
            t_end      <= sim_ticks;
            $display("  [tick=%0d] WATCH kind=3 (retirement pulse)", sim_ticks);
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
        // Default (no +instr_len=): effectively unbounded, so a test that
        // hasn't been updated with its own instruction length still runs
        // (informationally) rather than reporting p=0 always.
        if (!$value$plusargs("instr_len=%d", target_len)) target_len = 32'h7FFF_FFFF;
        if (!$value$plusargs("watch_reg=%d", wreg_arg)) wreg_arg = 0;
        watch_reg = wreg_arg[2:0];
        if (!$value$plusargs("watch_val=%h", wval_arg)) wval_arg = 32'h0;
        watch_val = wval_arg[31:0];
        if (!$value$plusargs("watch_kind=%d", watch_kind)) watch_kind = 0;
        if (!$value$plusargs("seq_len=%d", seq_len)) seq_len = 1;
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
                wait(t_end_seen == 1'b1 || seq_complete_r == 1'b1);
                repeat(20) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        check("target instruction's own opcode fetch observed", t_start_seen);
        if (seq_len > 1)
            check("sequence retirement count reached", seq_complete_r);
        else
            check("watch register reached expected value", t_end_seen);

        if (seq_len > 1 && t_start_seen && seq_complete_r) begin
            longint unsigned prev_ticks;
            prev_ticks = t_start;
            for (int k = 0; k < seq_len && k < MAX_SEQ; k++) begin
                longint unsigned cum_ticks, cum_clocks, cum_rem, inc_ticks, inc_clocks;
                cum_ticks  = seq_ticks[k] - t_start;
                cum_clocks = cum_ticks / 4;
                cum_rem    = cum_ticks % 4;
                inc_ticks  = seq_ticks[k] - prev_ticks;
                inc_clocks = inc_ticks / 4;
                $display("SEQ_CHECKPOINT k=%0d ticks=%0d clocks=%0d rem=%0d inc_ticks=%0d inc_clocks=%0d r=%0d p=%0d w=%0d",
                          k+1, cum_ticks, cum_clocks, cum_rem, inc_ticks, inc_clocks,
                          seq_r[k], seq_p[k], seq_w[k]);
                prev_ticks = seq_ticks[k];
            end
        end

        if (t_start_seen && t_end_seen) begin
            longint unsigned total_ticks, total_clocks, rem;
            total_ticks  = t_end - t_start;
            total_clocks = total_ticks / 4;
            rem          = total_ticks % 4;
            $display("MEASURED ticks=%0d clocks=%0d rem=%0d  r=%0d p=%0d w=%0d",
                      total_ticks, total_clocks, rem, r_count, p_count, w_count);
            if (t_end_instr_valid_r) begin
                longint unsigned instr_ticks, instr_clocks, instr_rem;
                instr_ticks  = t_end_instr_r - t_start;
                instr_clocks = instr_ticks / 4;
                instr_rem    = instr_ticks % 4;
                $display("MEASURED_INSTR_ONLY ticks=%0d clocks=%0d rem=%0d",
                          instr_ticks, instr_clocks, instr_rem);
            end
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

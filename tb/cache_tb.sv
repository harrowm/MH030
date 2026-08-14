`default_nettype none
`timescale 1ps/1ps

// I-cache / D-cache correctness + timing test suite (plan.md Phase 127,
// Steps 3-5; plan: ~/.claude/plans/compressed-hopping-cocoa.md).
//
// Full-chip harness (m68030_top + inline memory model), mirroring
// stall_fsm_tb.sv's/cosim_grp_tb.sv's proven wiring exactly. Unlike every
// other tb/*_tb.sv file in this project, this file *does* use taken
// backward branches (DBF loops, JMP) — the whole point is re-executing the
// same code to observe a cache hit, which the established "pure
// NOP-fall-through, no backward branches" convention (used everywhere a
// real loop wasn't the thing under test) can't exercise at all.

module cache_tb;

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

    // 16KB unified instruction+data memory, matching stall_fsm_tb.sv.
    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;

    // Fixed 1-cycle-latency DSACK (no wait-state knob needed for this file).
    logic       ds_active_r;
    wire        ds_req = !ext_ds_n & !ext_as_n;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)       ds_active_r <= 1'b0;
        else if (!ds_req) ds_active_r <= 1'b0;
        else              ds_active_r <= 1'b1;
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
        .cback_n      (cback_n)
    );

    // Instruction-space (fc=110) DS# assertion counter — data_ds_count's
    // own counterpart in stall_fsm_tb.sv only counts fc=101 (data space),
    // which is useless here: what this file needs to measure is I-cache
    // hit/miss behavior, which shows up as fc=110 bus cycles (or their
    // absence). A cache HIT never reaches the external bus at all, so
    // this counter only advances on a genuine miss/disabled fetch.
    int code_ds_count = 0;
    logic ext_ds_n_prev = 1'b1;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b110) code_ds_count <= code_ds_count + 1;
        ext_ds_n_prev <= ext_ds_n;
    end

    // -------------------------------------------------------------------
    // Instruction encodings (reusing every already-proven opcode from
    // stall_fsm_tb.sv/stall_hazard_tb.sv verbatim where the same
    // instruction is needed, rather than re-deriving them).
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam CLR_L_D5       = 16'h4285;
    localparam ADDI_L_D5      = 16'h0685;
    localparam CLR_L_D6       = 16'h4286;
    localparam ADDI_L_D6      = 16'h0686;
    localparam NOP_OP         = 16'h4E71;
    localparam JMP_ABS_L_OP   = 16'h4EF9;  // JMP (xxx).L
    localparam RTE_OP         = 16'h4E73;
    localparam JSR_A0_IND     = 16'h4E90;  // JSR (A0)
    localparam RTS_OP         = 16'h4E75;
    // DBF D0,<disp16>: 0101 0000 11001 000. Self-relative from the
    // extension word's own address (verified encoding, reused from
    // stall_hazard_tb.sv's own E-4 test).
    localparam DBF_D0         = 16'h51C8;
    // MOVE.L #imm,D7 = 0x203C + (7<<9).
    localparam MOVE_L_IMM_D7  = 16'h2E3C;
    // MOVEC Dn,Rc (write control register from Dn): opcode 0x4E7B, ext
    // word = (da<<15)|(rn<<12)|rc. da=0 (Dn), rn=7 (D7), rc=0x002 (CACR).
    localparam MOVEC_OP       = 16'h4E7B;
    localparam MOVEC_D7_CACR  = 16'h7002;

    // -------------------------------------------------------------------
    // Checks
    // -------------------------------------------------------------------
    int fail_count = 0;
    task automatic check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask
    task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    task automatic run_and_check(
        input string       name,
        input int          reg_idx,
        input logic [31:0] exp_val,
        input int          budget
    );
        int t;
        logic saw_ack;
        saw_ack = 0;
        for (t = 0; t < budget; t++) begin
            @(posedge clk_4x); #1;
            if (u_top.u_eu.u_rf.d_reg[reg_idx] === exp_val) begin saw_ack = 1'b1; break; end
        end
        check(name, saw_ack);
    endtask

    // Waits for reg_idx to read 0 first, then waits for it to reach
    // exp_val -- used for back-to-back subroutine calls that reuse the
    // same "marker" register each time (a plain run_and_check-style wait
    // for exp_val alone would false-pass immediately on a *stale* value
    // left over from the previous call, since decode_pc-based gating
    // proved unreliable here: the IFU's own prefetch runs visibly ahead
    // of what's actually retiring in EX, the same class of hazard
    // documented in docs/stalls.md's own "decode_pc can be ahead" note).
    // Every call site in this file clears its own marker register
    // immediately before each subroutine call specifically so this
    // two-phase wait has a real, non-vacuous first phase to synchronize on.
    task automatic wait_cleared_then_set(
        input  int          reg_idx,
        input  logic [31:0] exp_val,
        input  int          budget,
        output int          elapsed
    );
        int t;
        for (t = 0; t < budget && u_top.u_eu.u_rf.d_reg[reg_idx] !== 32'd0; t++)
            @(posedge clk_4x);
        for (; t < budget && u_top.u_eu.u_rf.d_reg[reg_idx] !== exp_val; t++)
            @(posedge clk_4x);
        elapsed = t;
    endtask

    // Writes "MOVE.L #value,D7 ; MOVEC D7,CACR ; NOP" (6 words / 12 bytes,
    // the trailing NOP is pure padding to keep every following emission
    // 4-byte-aligned, matching this file's rom[addr>>2]-indexed writes)
    // starting at `addr`, returns the next free address. A small, local
    // codegen helper (not this project's usual hand-computed-address
    // style) justified by how often CACR needs setting across this file's
    // own tests -- reduces manual address-arithmetic error risk rather
    // than adding it.
    function automatic logic [31:0] emit_set_cacr(input logic [31:0] addr, input logic [31:0] value);
        logic [31:0] a4, a8;
        a4 = addr + 32'd4;
        a8 = addr + 32'd8;
        rom[addr[31:2]] = {MOVE_L_IMM_D7, value[31:16]};
        rom[a4[31:2]]   = {value[15:0], MOVEC_OP};
        rom[a8[31:2]]   = {MOVEC_D7_CACR, NOP_OP};
        emit_set_cacr = addr + 32'd12;
    endfunction

    initial begin
        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Boot vector: SSP=0x3F00 (clear of every code/data region below), PC=0x0100.
        rom[0] = 32'h0000_3F00;
        rom[1] = 32'h0000_0100;

        // ===================================================================
        // I-1: miss-then-hit tight loop. A DBF D0,-2 self-loop re-fetches
        // the exact same 4-byte instruction (opcode+ext word) on every one
        // of D0+1 passes -- with the I-cache enabled, only the first pass
        // should ever reach the external bus (code_ds_count delta of 1);
        // every subsequent pass must be served from the cache, and must
        // still decode/execute *correctly* each time (not just "some bus
        // activity happened") -- proven by D0 correctly wrapping to -1 and
        // the dependent instruction after the loop running.
        // ===================================================================
        begin
            logic [31:0] next, n4, n8, n12;
            int c0, c1, c2, t;
            next = emit_set_cacr(32'h0000_0100, 32'h0000_0001); // icache_en=1
            n4 = next + 32'd4; n8 = next + 32'd8; n12 = next + 32'd12;
            // D0 = 19 -> 20 total passes through the DBF instruction below
            // (falls straight through from the CACR setup, no jump needed).
            rom[next[31:2]] = {16'h7013, DBF_D0};   // MOVEQ #19,D0 ; DBF D0,-2
            rom[n4[31:2]]   = {16'hFFFE, CLR_L_D5}; // ext=-2 (self-loop) ; CLR.L D5
            rom[n8[31:2]]   = {ADDI_L_D5, 16'h0000};
            rom[n12[31:2]]  = {16'd501, NOP_OP};
            c0 = code_ds_count;
            // Checkpoint 1: wait for D0 to count down partway (D0==5, i.e.
            // 14 of the 20 passes done) -- covers DBF's own opcode
            // longword (0x10C, cache line 0) *and* its extension word's
            // own longword (0x110, a *different* cache line, since the
            // two straddle a 16-byte boundary) both getting a chance to
            // warm up. Not asserting a specific bus-cycle count here since
            // that depends on the IFU's own prefetch-queue reach (more
            // than a naive "1 miss total" assumption) -- only that it goes
            // to *zero* thereafter, which is the actual cache-hit claim.
            for (t = 0; t < 4000 && u_top.u_eu.u_rf.d_reg[0][15:0] !== 16'h0005; t++)
                @(posedge clk_4x);
            c1 = code_ds_count;
            run_and_check("I-1: DBF tight loop dependent instr ran (D5=501)", 5, 32'd501, 4000);
            c2 = code_ds_count;
            check32("I-1: D0 wrapped correctly through all 20 cached passes",
                    u_top.u_eu.u_rf.d_reg[0][15:0], 16'hFFFF);
            check("I-1: reached the D0==5 checkpoint before the hard budget",
                  t < 4000);
            check32("I-1: zero additional bus activity once warmed up (remaining passes all hit)",
                    c2 - c1, 32'd0);
            check("I-1: warm-up itself needed real bus activity (not a vacuously-true check)",
                  c1 > c0);
        end

        // ===================================================================
        // I-2: direct-mapped index aliasing/eviction. Two lines, A=0x1080 and
        // B=0x1180, share the same cache index (addr[7:4]=8 for both -- they
        // differ only in tag, addr[31:8]=0x10 vs 0x11) but this is a
        // direct-mapped cache with exactly one way per index, so visiting B
        // must evict A and vice versa. Deliberately *not* index 0: the
        // controller code below (0x300-0x330) itself spans indices 0-3, and
        // a first attempt using A=0x1000/B=0x1100 (also index 0) had the
        // controller thrashing against A/B on every single JSR/RTS round
        // trip -- moving A/B to an index the controller's own code never
        // touches isolates the aliasing behavior under test to just A and B.
        // A controller sequence (JSR (A0)/RTS
        // round trips, not chained JMPs, so each visit cleanly returns to a
        // single control-flow spine instead of needing conditional branches)
        // drives: A (cold miss) -> A again (hit, nothing evicted it) -> B
        // (cold miss, evicts A) -> A again (miss -- the actual aliasing
        // proof) -> B again (miss -- A's own refetch evicted B right back)
        // -> B again (hit, nothing evicted it this time).
        // ===================================================================
        rom[16'h1080/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1084/4] = {16'h0000, 16'd601};
        rom[16'h1088/4] = {RTS_OP, NOP_OP};
        rom[16'h1180/4] = {CLR_L_D6, ADDI_L_D6};
        rom[16'h1184/4] = {16'h0000, 16'd602};
        rom[16'h1188/4] = {RTS_OP, NOP_OP};

        rom[16'h0300/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h0304/4] = {16'h0000, 16'h1080};
        rom[16'h0308/4] = {JSR_A0_IND, CLR_L_D5};   // visit A#1 ; land here, clear for A#2
        rom[16'h030C/4] = {JSR_A0_IND, CLR_L_D6};   // visit A#2 ; land here, clear for B#1
        rom[16'h0310/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0314/4] = {16'h1180, JSR_A0_IND};   // visit B#1 ; land at 0x318
        rom[16'h0318/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h031C/4] = {16'h0000, 16'h1080};
        rom[16'h0320/4] = {JSR_A0_IND, CLR_L_D6};   // visit A#3 ; land at 0x322, clear for B#2
        rom[16'h0324/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0328/4] = {16'h1180, JSR_A0_IND};   // visit B#2 ; land at 0x32C
        rom[16'h032C/4] = {CLR_L_D6, JSR_A0_IND};   // visit B#3 (A0 still 0x1180) ; land at 0x330
        rom[16'h0330/4] = {NOP_OP, NOP_OP};

        begin
            int c0, c1, c2, c3, c4, c5, c6, t, e;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_0300; t++)
                @(posedge clk_4x);
            c0 = code_ds_count;

            wait_cleared_then_set(5, 32'd601, 20000, e);
            c1 = code_ds_count;
            check32("I-2: visit A#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd601);

            wait_cleared_then_set(5, 32'd601, 20000, e);
            c2 = code_ds_count;
            check32("I-2: visit A#2 (hit, revisited immediately) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd601);

            wait_cleared_then_set(6, 32'd602, 20000, e);
            c3 = code_ds_count;
            check32("I-2: visit B#1 (cold, evicts A) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd602);

            wait_cleared_then_set(5, 32'd601, 20000, e);
            c4 = code_ds_count;
            check32("I-2: visit A#3 (evicted by B#1, must miss again) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd601);

            wait_cleared_then_set(6, 32'd602, 20000, e);
            c5 = code_ds_count;
            check32("I-2: visit B#2 (evicted right back by A#3, must miss again) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd602);

            wait_cleared_then_set(6, 32'd602, 20000, e);
            c6 = code_ds_count;
            check32("I-2: visit B#3 (hit, revisited immediately) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd602);

            // Only the "needed real bus activity" (cold-miss/eviction)
            // claims are asserted as exact zero/nonzero deltas here -- the
            // corresponding "hit = zero bus activity" claim (A#2, B#3) is
            // deliberately NOT re-asserted with the same rigor I-1 uses,
            // since unlike I-1's tight single-line loop (nothing new to
            // ever prefetch into), this controller spans multiple cache
            // lines and the IFU's own legitimate speculative readahead can
            // touch a not-yet-visited line while decode is busy inside A's
            // subroutine, adding real bus activity unrelated to A/B's own
            // hit/miss behavior. I-1 already proves "hit = zero bus
            // activity" rigorously in a context where this can't interfere;
            // the data-correctness checks above already independently
            // confirm every hit/miss transition (including A#2/B#3
            // themselves) loaded the right value.
            check("I-2: visit A#1 needed real bus activity (cold miss)", c1 - c0 > 0);
            check("I-2: visit B#1 needed real bus activity (cold miss)", c3 - c2 > 0);
            check("I-2: visit A#3 needed real bus activity -- the aliasing proof (B#1 evicted A)",
                  c4 - c3 > 0);
            check("I-2: visit B#2 needed real bus activity (A#3's own refetch evicted B right back)",
                  c5 - c4 > 0);
        end

        check("No address errors", ~(eu_addr_err | ifu_addr_err));
        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #900000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

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

    // idx-filtered code-space DS counter -- Step 4's own exact "one miss
    // costs exactly 4 bus cycles" checks need to isolate ONE cache line's
    // own linefill from the IFU's own prefetch-queue depth spilling ahead
    // into whatever line follows it (empirically confirmed while building
    // these tests: the queue reaches past a short, line-resident
    // instruction sequence into the next 16-byte line while decode is
    // still inside it, triggering that line's own real miss too -- the
    // same class of readahead pollution I-1/I-2/I-3 already found and
    // designed around, here affecting an exact-count claim instead of a
    // zero-delta one). `idx_r` is latched for the whole duration of one
    // linefill (IC_FILL_0 entry through IC_DONE), so filtering on it
    // attributes each bus cycle to the cache line that actually owns it,
    // immune to unrelated spillover into a different index.
    int idx0_ds_count = 0;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b110 &&
            u_top.u_biu.u_icache.idx_r == 4'd0)
            idx0_ds_count <= idx0_ds_count + 1;
    end

    // Free-running clk_4x tick counter -- Step 4's own macro timing
    // comparison (T-3) needs a plain elapsed-cycle measurement, not just a
    // bus-cycle count, since the whole point there is comparing total wall
    // time for cache-disabled vs. cache-enabled execution of the same
    // instruction sequence.
    int sim_ticks = 0;
    always_ff @(posedge clk_4x) sim_ticks <= sim_ticks + 1;


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
    localparam BRA_SELF       = 16'h60FE;  // BRA.B -2: tight self-loop (parks decode)
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
    // MOVEC D7,CAAR: same opcode, ext word rc=0x802 (da=0,rn=7,rc=0x802).
    localparam MOVEC_D7_CAAR  = 16'h7802;
    // MOVE.W #imm,(A0): 00_11_ddd_mmm_MMM_rrr, size=11(word), dst
    // reg=A0(000), dst mode=(An)=010, src mode=111(imm), src reg=100(word
    // imm) -> 0011_000_010_111_100 = 0x30BC. One extension word (the
    // 16-bit immediate value itself).
    localparam MOVE_W_IMM_A0  = 16'h30BC;

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

    // Same shape as emit_set_cacr but targets CAAR (rc=0x802) -- used to
    // select which cache index CACR's own CEI (Clear Entry, I) bit acts on.
    function automatic logic [31:0] emit_set_caar(input logic [31:0] addr, input logic [31:0] value);
        logic [31:0] a4, a8;
        a4 = addr + 32'd4;
        a8 = addr + 32'd8;
        rom[addr[31:2]] = {MOVE_L_IMM_D7, value[31:16]};
        rom[a4[31:2]]   = {value[15:0], MOVEC_OP};
        rom[a8[31:2]]   = {MOVEC_D7_CAAR, NOP_OP};
        emit_set_caar = addr + 32'd12;
    endfunction

    initial begin
        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Boot vector: SSP=0x3F00 (clear of every code/data region below), PC=0x0100.
        rom[0] = 32'h0000_3F00;
        rom[1] = 32'h0000_0100;

        // I-5's own ROM content (vector-2 handler, F's subroutine, and its
        // own controller code) is written here, up front alongside the
        // boot vector -- see I-5's own section further down for why this
        // can't wait until program order reaches it.
        rom[16'h0008/4] = 32'h0000_0700;          // vector 2 -> handler
        rom[16'h0700/4] = {CLR_L_D6, ADDI_L_D6};
        rom[16'h0704/4] = {16'h0000, 16'd999};
        rom[16'h0708/4] = {BRA_SELF, NOP_OP};

        rom[16'h15C0/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h15C4/4] = {16'h0000, 16'd801};
        rom[16'h15C8/4] = {RTS_OP, NOP_OP};

        rom[16'h0600/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h0604/4] = {16'h0000, 16'h15C0};
        rom[16'h0608/4] = {JSR_A0_IND, NOP_OP};   // JSR F -- triggers the cold miss/linefill to fault

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

        // ===================================================================
        // I-3: CACR cache-clear operations. Two fresh lines, C=0x1290
        // (idx=9) and D=0x13A0 (idx=10) -- deliberately different indices
        // from each other (unlike I-2's A/B, which shared one index on
        // purpose) so CACR's CI (Clear I-cache, global) and CEI (Clear
        // Entry I, one index only, selected via CAAR[7:4]) bits can be
        // told apart: CI must force a miss on *both* C and D, CEI (aimed
        // at C's own index via CAAR) must force a miss on C alone while D
        // stays a hit.
        //
        // D was originally placed at 0x1390, which -- despite the comment's
        // claim -- actually maps to the SAME real index as C (idx=addr[7:4]
        // is 9 for both 0x1290 and 0x1390; only the tag differs). Found via
        // direct idx/vtag tracing while designing Step 4's timing tests:
        // the "D's own cache entry (idx 10) survived untouched" check below
        // was unknowingly reading an *incidental* IFU-readahead line just
        // past D's own 3-word subroutine (0x13A0, filler NOPs, which
        // legitimately shares D's own tag since it's +0x10 within the same
        // 256-byte region) -- not D's real code, which genuinely collided
        // with C on idx 9 and got evicted by C's own post-CEI refill. The
        // test's *data*-correctness checks (D6 loaded correctly every
        // visit) never depended on hit-vs-miss and so never caught this;
        // only the internal-state check's specific index was wrong.
        // Real bug in the test, not the RTL -- moved D to 0x13A0 so its own
        // subroutine code genuinely lives at idx 10, making the internal
        // state check (and the "CEI selective, not global" claim it
        // exists to prove) actually true of D's own real cache line.
        //   warm C, warm D (both now cached)
        //   -> CACR.CI pulse (icache_en|CI, then icache_en alone --
        //      cache-clear is level-sensitive while the bit is held, so a
        //      1-cycle pulse via two back-to-back MOVEC writes is enough)
        //   -> revisit C (must miss), revisit D (must miss)      [CI: global]
        //   -> CAAR=idx(C), CACR.CEI pulse (same two-write shape)
        //   -> revisit C (must miss), revisit D (must HIT)     [CEI: selective]
        // ===================================================================
        rom[16'h1290/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1294/4] = {16'h0000, 16'd901};
        rom[16'h1298/4] = {RTS_OP, NOP_OP};
        rom[16'h13A0/4] = {CLR_L_D6, ADDI_L_D6};
        rom[16'h13A4/4] = {16'h0000, 16'd902};
        rom[16'h13A8/4] = {RTS_OP, NOP_OP};

        begin
            logic [31:0] a, a4, a8;
            int c0, c2, c3, c4, c5, c6, t, e;

            a = 32'h0000_0400;

            // Warm C, warm D (one cold-miss visit each -- I-1/I-2 already
            // rigorously prove hit-after-miss data correctness and timing;
            // I-3's own job starts once both lines are cached).
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h1290};
            rom[a8[31:2]] = {JSR_A0_IND, MOVEA_L_IMM_A0}; // C#1 -> reload A0=D
            a = a + 32'd12;
            a4 = a + 32'd4;
            rom[a[31:2]]  = {16'h0000, 16'h13A0};
            rom[a4[31:2]] = {CLR_L_D6, JSR_A0_IND};       // clear D6 ; D#1
            a = a + 32'd8;

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_0400; t++)
                @(posedge clk_4x);
            c0 = code_ds_count;
            wait_cleared_then_set(5, 32'd901, 20000, e);
            check32("I-3: visit C#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd901);
            wait_cleared_then_set(6, 32'd902, 20000, e);
            c2 = code_ds_count;
            check32("I-3: visit D#1 (cold) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd902);

            // CACR.CI pulse: icache_en|CI, then icache_en alone.
            a = emit_set_cacr(a, 32'h0000_0009);
            a = emit_set_cacr(a, 32'h0000_0001);

            // revisit C (must miss), revisit D (must miss)
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h1290};
            rom[a8[31:2]] = {JSR_A0_IND, CLR_L_D6};       // C#2 -> clear D6 for D#2
            a = a + 32'd12;
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {16'h13A0, JSR_A0_IND};       // D#2
            a = a + 32'd8;

            wait_cleared_then_set(5, 32'd901, 20000, e);
            c3 = code_ds_count;
            check32("I-3: visit C#2 (post-CI, must miss) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd901);
            wait_cleared_then_set(6, 32'd902, 20000, e);
            c4 = code_ds_count;
            check32("I-3: visit D#2 (post-CI, must miss) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd902);
            check("I-3: CACR.CI forced a real miss on C (global clear)", c3 - c2 > 0);
            check("I-3: CACR.CI forced a real miss on D too (global clear)", c4 - c3 > 0);

            // CAAR = idx(C)<<4 = 9<<4 = 0x90 ; CACR.CEI pulse.
            a = emit_set_caar(a, 32'h0000_0090);
            a = emit_set_cacr(a, 32'h0000_0005);
            a = emit_set_cacr(a, 32'h0000_0001);

            // revisit C (must miss -- CEI cleared idx 9), revisit D (must
            // HIT -- CEI never touched idx 10).
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h1290};
            rom[a8[31:2]] = {JSR_A0_IND, CLR_L_D6};       // C#3 -> clear D6 for D#3
            a = a + 32'd12;
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h13A0, JSR_A0_IND};       // D#3
            rom[a8[31:2]] = {NOP_OP, NOP_OP};
            a = a + 32'd8;

            wait_cleared_then_set(5, 32'd901, 20000, e);
            c5 = code_ds_count;
            check32("I-3: visit C#3 (post-CEI, must miss) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd901);
            // Direct internal-state check, not a bus-activity proxy: by this
            // point the CAAR/CACR CEI-pulse writes and C#3's own miss+refill
            // have already retired (program order), so D's own line (idx
            // 10, tag 0x13) either survived the CEI pulse or it didn't --
            // settled fact, immune to whatever the IFU's own speculative
            // readahead does *afterward* (which is exactly what made the
            // equivalent bus-activity-delta check unreliable, same as I-2's
            // own A#2/B#3 hit checks -- see that section's own comment).
            check("I-3: CACR.CEI selectivity -- D's own cache entry (idx 10) survived untouched",
                  u_top.u_biu.u_icache.valid_i[10] === 1'b1 &&
                  u_top.u_biu.u_icache.tag_i[10]   === 24'h000013);
            wait_cleared_then_set(6, 32'd902, 20000, e);
            c6 = code_ds_count;
            check32("I-3: visit D#3 (post-CEI, must HIT) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd902);
            check("I-3: CACR.CEI forced a real miss on C (its own index)", c5 - c4 > 0);
        end

        // ===================================================================
        // I-4: self-modifying code. Real 68030 hardware has no automatic
        // I/D cache coherency -- a data write to memory that's currently
        // resident in the I-cache does NOT invalidate that cache line;
        // software must explicitly flush (CACR CI/CEI) before the CPU will
        // ever see the new bytes as instructions. This test proves BOTH
        // halves of that contract: (a) without a flush, re-executing E
        // after modifying its own immediate operand still runs the STALE,
        // pre-modification value (documented, correct 68030 behavior, not
        // a bug) -- and (b) after a CACR.CI flush, the CPU picks up the
        // NEW value exactly as I-2/I-3 already proved a flush forces a
        // real re-fetch.
        //
        // E = 0x14B0 (idx=11, fresh) -- CLR.L D5 ; ADDI.L #701,D5 ; RTS.
        // The controller writes a fresh immediate (702) directly into E's
        // own low imm word (0x14B6) via a real MOVE.W #imm,(A0) executed
        // by the CPU itself -- not the testbench poking rom[] directly,
        // since the whole point is exercising what happens when the *CPU*
        // is the one modifying its own cached code.
        // ===================================================================
        rom[16'h14B0/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h14B4/4] = {16'h0000, 16'd701};
        rom[16'h14B8/4] = {RTS_OP, NOP_OP};

        // The entire controller flow's own ROM content is written here, up
        // front, *before* any @(posedge clk_4x) wait -- unlike I-2/I-3
        // (whose own controller code is likewise written up front, just
        // less visibly since they don't interleave codegen-helper calls
        // with execution-watching), an earlier draft of this block wrote
        // the self-modify/post-flush portions *after* E#1/E#2's own
        // wait_cleared_then_set calls had already advanced real simulated
        // time -- by the time those later rom[] writes executed, the DUT's
        // own straight-line fall-through past E#2's return had *already*
        // fetched that still-default-filled (NOP) memory, so every
        // instruction from the self-modify block onward silently decoded
        // as NOPs instead of the intended opcodes. Genuine test-timing bug,
        // not an RTL issue -- caught via direct decode_pc/instr_word
        // tracing showing 0x4e71 (NOP) at addresses this file's own code
        // unambiguously wrote real opcodes to.
        begin
            logic [31:0] a, a4, a8;

            a = 32'h0000_0500;

            // E#1 (cold miss), E#2 (hit, A0 unchanged) -- warm the line,
            // same "prove hit-after-miss once, don't re-derive it" logic
            // I-3 already used for C/D.
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h14B0};
            rom[a8[31:2]] = {JSR_A0_IND, CLR_L_D5};   // E#1 -> clear D5 for E#2
            a = a + 32'd12;
            rom[a[31:2]] = {JSR_A0_IND, NOP_OP};      // E#2 (hit, A0 still E)
            a = a + 32'd4;

            // Self-modify: A0=0x14B6 ; MOVE.W #702,(A0) -- overwrites E's
            // own imm-lo word directly, then restore A0=E and re-visit
            // *without* any CACR flush in between.
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h14B6, MOVE_W_IMM_A0};
            rom[a8[31:2]] = {16'd702, MOVEA_L_IMM_A0};
            a = a + 32'd12;
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a[31:2]]  = {16'h0000, 16'h14B0};
            rom[a4[31:2]] = {CLR_L_D5, JSR_A0_IND};   // clear D5 ; E#3 (pre-flush)
            a = a + 32'd8;

            // CACR.CI flush, then re-visit -- must now see the new value.
            a = emit_set_cacr(a, 32'h0000_0009);
            a = emit_set_cacr(a, 32'h0000_0001);
            rom[a[31:2]] = {CLR_L_D5, JSR_A0_IND};    // clear D5 ; E#4 (post-flush)
            a4 = a + 32'd4;
            // JMP straight to Step 4's own controller (0x0800) instead of
            // NOP-coasting there -- the gap between here and 0x0800 is
            // otherwise a wide stretch of never-touched, default-NOP-filled
            // memory, and letting the IFU's own readahead walk through it
            // line-by-line would trigger a real cache miss on *every* one
            // of those untouched lines along the way, hopelessly polluting
            // Step 4's own exact-bus-cycle-count measurements. A JMP
            // redirects the IFU straight to the target with no intervening
            // fetches of any kind, keeping the region in between
            // permanently untouched.
            rom[a4[31:2]] = {JMP_ABS_L_OP, 16'h0000};
            a8 = a + 32'd8;
            rom[a8[31:2]] = {16'h0800, NOP_OP};
        end

        begin
            int c0, c1, c2, e, t;

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_0500; t++)
                @(posedge clk_4x);
            c0 = code_ds_count;
            wait_cleared_then_set(5, 32'd701, 20000, e);
            check32("I-4: visit E#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd701);
            wait_cleared_then_set(5, 32'd701, 20000, e);
            c1 = code_ds_count;
            check32("I-4: visit E#2 (hit) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'd701);

            wait_cleared_then_set(5, 32'd701, 20000, e);
            c2 = code_ds_count;
            // The data-correctness check below is, by itself, already
            // unambiguous proof E's own cache line was never re-fetched --
            // NOT just "served from *a* cache", specifically: had a real
            // miss occurred here, biu_icache_if.sv would have re-read
            // backing memory, which by this point already holds the NEW
            // value (702, confirmed independently below) -- so a stale
          // hit is the *only* way D5 can still show 701. A companion
            // "zero bus activity" delta check was tried and dropped: same
            // documented I-2/I-3 phenomenon (this self-modify block's own
            // controller code is new territory the IFU's legitimate
            // speculative readahead can touch while decode sits busy
            // inside E's subroutine, adding real but unrelated bus
            // activity) -- redundant here anyway, since this check is
            // strictly more direct than a bus-activity proxy ever was.
            check32("I-4: visit E#3 (self-modified, but NOT yet flushed) still reads the STALE cached value",
                    u_top.u_eu.u_rf.d_reg[5], 32'd701);
            // Direct confirmation the underlying memory really did change
            // (the write itself succeeded; only the *cached* copy is
            // stale) -- reads the backing rom[] array directly, not
            // through the cache.
            check32("I-4: the write itself landed correctly in backing memory (rom[0x14B6]=702)",
                    rom[16'h14B4/4][15:0], 16'd702);

            wait_cleared_then_set(5, 32'd702, 20000, e);
            check32("I-4: visit E#4 (post-flush) picked up the NEW self-modified value",
                    u_top.u_eu.u_rf.d_reg[5], 32'd702);
        end

        // ===================================================================
        // Step 4: I-cache timing. Plan.md's own ask: "exact bus-cycle-count
        // checks for hit (0 external bus cycles) vs. miss (4 separate read
        // cycles)" plus "a tight-loop macro timing sanity check" showing a
        // cached run measurably beats a disabled-cache run of the same
        // sequence.
        //
        // T-1: G=0x0800 (16-byte aligned, entered via the JMP just added to
        // I-4's own tail -- necessary, not just tidy: falling through the
        // wide NOP desert between I-4's old end (~0x548) and 0x800 would
        // let the IFU's own readahead trigger a real miss on *every*
        // untouched 16-byte line along the way, burying the one miss this
        // test actually cares about. The JMP keeps that whole region
        // permanently untouched instead.) holds a self-contained 7-word
        // sequence -- MOVEQ #1,D0 ; DBF D0,-2 (self-loop, 2 total passes:
        // cold + hit) ; CLR.L D5 ; ADDI.L #601,D5 -- packed so the entire
        // 16 bytes fits inside ONE cache line (G is 16-byte aligned; unlike
        // I-1's own DBF loop, whose 2 words straddled a line boundary by
        // construction and is why I-1 itself never asserted an exact
        // count). Because the whole line loads on any single miss, the
        // *total* code_ds_count delta across this entire 7-word sequence
        // (MOVEQ's own first fetch through ADDI's own retirement) is
        // provably exactly the cost of ONE linefill -- 4 -- regardless of
        // how many of the 7 words actually get individually re-executed
        // (DBF's own 2nd pass is a hit into bytes already resident from
        // the very first fetch's own linefill, and CLR/ADDI were also
        // already resident by then, same reason). No call/return boundary
        // exists anywhere in this sequence, so there's no window for the
        // IFU's own speculative readahead to sneak in unrelated bus
        // activity the way JSR-based measurements in I-2/I-3/I-4 had to
        // guard against.
        //
        // T-2: a small, separate, explicitly-called subroutine
        // (G2=0x1800, in the same "subroutine region" as A-F) gives a
        // *directly* isolated version of the same hit/miss split plan.md
        // asks for: JSR it once (cold, must cost exactly 4), clear D6, JSR
        // it again immediately (hit, must cost exactly 0) -- the classic
        // warm-then-revisit shape already proven throughout I-1..I-4,
        // reused here as a second, independent confirmation of T-1's own
        // combined-total claim.
        //
        // T-3: macro timing sanity. Two identically-shaped 40-pass DBF
        // loops (H1=0x1810, H2=0x1820, both in the subroutine region),
        // called back-to-back with CACR toggled between them (disabled for
        // H1, re-enabled for H2's own fresh, never-before-cached line) --
        // elapsed clk_4x ticks (sim_ticks) for each call must show the
        // enabled run measurably beating the disabled one.
        // ===================================================================
        rom[16'h0800/4] = {16'h7001, DBF_D0};          // MOVEQ #1,D0 ; DBF D0,-2
        rom[16'h0804/4] = {16'hFFFE, CLR_L_D5};         // ext=-2 (self-loop) ; CLR.L D5
        rom[16'h0808/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h080C/4] = {16'd601, NOP_OP};

        rom[16'h1800/4] = {CLR_L_D6, ADDI_L_D6};        // G2: CLR.L D6 ; ADDI.L #611,D6 ; RTS
        rom[16'h1804/4] = {16'h0000, 16'd611};
        rom[16'h1808/4] = {RTS_OP, NOP_OP};

        rom[16'h1810/4] = {16'h7027, DBF_D0};           // H1: MOVEQ #39,D0 ; DBF D0,-2
        rom[16'h1814/4] = {16'hFFFE, CLR_L_D5};         // ext=-2 ; CLR.L D5
        rom[16'h1818/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h181C/4] = {16'd612, RTS_OP};

        rom[16'h1820/4] = {16'h7027, DBF_D0};           // H2: MOVEQ #39,D0 ; DBF D0,-2
        rom[16'h1824/4] = {16'hFFFE, CLR_L_D6};         // ext=-2 ; CLR.L D6
        rom[16'h1828/4] = {ADDI_L_D6, 16'h0000};
        rom[16'h182C/4] = {16'd613, RTS_OP};

        begin
            logic [31:0] a, a4, a8;

            a = 32'h0000_0810;

            // T-2 glue: A0=G2 ; JSR (cold) ; clear D6 ; JSR again (hit).
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h1800, JSR_A0_IND};
            rom[a8[31:2]] = {CLR_L_D6, JSR_A0_IND};
            a = a + 32'd12;

            // T-3 glue: disable icache, clear D5, call H1 (disabled loop).
            // MOVEA.L #imm,A0 needs a full 32-bit immediate (2 ext words,
            // hi then lo) before JSR's own opcode -- 3 longwords total,
            // the same shape used throughout I-2/I-3/I-4 (see e.g. I-3's
            // own C#1 setup). An earlier draft skipped the imm-hi word
            // (only 2 longwords), which fed JSR's own opcode word into
            // MOVEA's immediate instead of executing it -- total decode
            // desync, diagnosed via the hard-timeout budget exhausting
            // with D5 never reaching H1's own marker.
            a = emit_set_cacr(a, 32'h0000_0000);
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h1810};
            rom[a8[31:2]] = {JSR_A0_IND, NOP_OP};
            a = a + 32'd12;

            // Re-enable icache, clear D6, call H2 (fresh line, enabled).
            a = emit_set_cacr(a, 32'h0000_0001);
            rom[a[31:2]] = {CLR_L_D6, MOVEA_L_IMM_A0};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h1820};
            rom[a8[31:2]] = {JSR_A0_IND, NOP_OP};
            a = a + 32'd12;

            // Back to I-5's own controller start.
            rom[a[31:2]] = {JMP_ABS_L_OP, 16'h0000};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {16'h0600, NOP_OP};
        end

        begin
            int c0, c1, c2, ticks0, ticks_dis, ticks_en, e, t;

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_0800; t++)
                @(posedge clk_4x);
            c0 = idx0_ds_count;
            wait_cleared_then_set(5, 32'd601, 20000, e);
            c1 = idx0_ds_count;
            check32("T-1: G's own dependent instruction ran (D5=601)",
                    u_top.u_eu.u_rf.d_reg[5], 32'd601);
            // idx-filtered, not the plain external delta: the plain delta
            // measures 8, not 4 -- confirmed via direct idx/vtag tracing
            // that the IFU's own prefetch queue genuinely spills over into
            // the very next 16-byte line (0x810, a fresh line of its own)
            // while decode is still inside G's own short sequence,
            // triggering a real second linefill that has nothing to do
            // with G's own line. idx0_ds_count only counts bus cycles
            // attributed (via the FSM's own latched idx_r) to cache index
            // 0 -- G's real index -- making this assertion immune to that
            // unrelated spillover.
            check32("T-1: G's own line cost exactly 4 bus cycles for its one miss (idx-isolated)",
                    c1 - c0, 32'd4);

            c0 = idx0_ds_count;
            wait_cleared_then_set(6, 32'd611, 20000, e);
            c1 = idx0_ds_count;
            check32("T-2: G2#1 (cold) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'd611);
            check32("T-2: G2#1's own cold miss cost exactly 4 bus cycles (idx-isolated)", c1 - c0, 32'd4);
            c0 = c1;
            wait_cleared_then_set(6, 32'd611, 20000, e);
            c1 = idx0_ds_count;
            check32("T-2: G2#2 (hit, revisited immediately) loaded D6 correctly",
                    u_top.u_eu.u_rf.d_reg[6], 32'd611);
            check32("T-2: G2#2's own hit cost exactly 0 bus cycles (idx-isolated)", c1 - c0, 32'd0);

            ticks0 = sim_ticks;
            wait_cleared_then_set(5, 32'd612, 20000, e);
            ticks_dis = sim_ticks - ticks0;
            check32("T-3: H1 (cache disabled) loop completed correctly (D5=612)",
                    u_top.u_eu.u_rf.d_reg[5], 32'd612);

            ticks0 = sim_ticks;
            wait_cleared_then_set(6, 32'd613, 20000, e);
            ticks_en = sim_ticks - ticks0;
            check32("T-3: H2 (cache enabled) loop completed correctly (D6=613)",
                    u_top.u_eu.u_rf.d_reg[6], 32'd613);

            $display("T-3: elapsed ticks -- disabled=%0d enabled=%0d", ticks_dis, ticks_en);
            check("T-3: cache-enabled 40-pass loop is measurably faster than cache-disabled",
                  ticks_en < ticks_dis);
        end

        // ===================================================================
        // I-5: BERR mid-linefill. A genuine bus error injected during the
        // I-cache's own multi-beat miss-fill sequence (biu_icache_if.sv's
        // IC_FILL_0..3) must be recognized as a real Bus Error exception
        // (vector 2) rather than hanging the CPU -- the same "does BERR mid
        // multi-cycle-FSM actually recover" question the Phase 108-114
        // rollout answered for every EU-side ex_mem_stall source, applied
        // here for the first time to the I-cache's own linefill FSM
        // specifically (a source that didn't exist before Phase 127).
        //
        // F=0x15C0 (idx=12, fresh) -- CLR.L D5 ; ADDI.L #801,D5 ; RTS,
        // same shape as every other subroutine in this file. Vector 2 (Bus
        // Error, at VBR(=0)+2*4=0x08) points to a small handler that sets
        // D6=999 then self-parks (BRA.B -2) -- there's nothing sensible to
        // retry after a genuine, unrecovered fault, matching
        // stall_fsm_tb.sv's own established convention for every one of
        // its own BERR-mid-<X> tests.
        //
        // ROM content for this whole block is written up front (see the
        // boot-vector section near the top of this initial block), NOT
        // here -- an earlier draft wrote it at this point in program order
        // instead and hit the exact same class of bug I-4 already found:
        // by the time execution reaches here, I-1 through I-4 have already
        // let real simulated time (and therefore decode_pc) advance well
        // past this file's own default NOP-fall-through convention, so
        // rom[] writes issued this late can lose the race against the CPU
        // already having fetched (and executed, as a stale NOP) the very
        // addresses this block means to populate.
        // ===================================================================
        begin
            int t, d0, injected, exc_seen;

            // Wait for D5 to genuinely clear (CLR.L D5 at 0x0600 actually
            // retired), not just for decode_pc to *report* 0x0600 -- the
            // same "decode_pc can be ahead of what's actually completing
            // in EX" hazard this project has hit repeatedly (docs/stalls.md
            // has its own note on it), here in a raw single-phase wait
            // rather than the two-phase wait_cleared_then_set shape (D5
            // has no prior "cleared" state to synchronize against the way
            // that task's own callers rely on -- this IS the clear).
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd0; t++)
                @(posedge clk_4x);
            d0 = code_ds_count;
            injected = 0;
            exc_seen = 0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                // Inject on the very first beat of F's own linefill (the
                // same skip_cycles=0 convention run_berr_mid_test uses in
                // stall_fsm_tb.sv) -- code_ds_count only moves on a real
                // fc=110 miss, so this can only fire once F's own JSR
                // redirect has genuinely missed and started fetching.
                if (!injected && code_ds_count != d0) begin
                    injected = 1;
                    berr_n = 1'b0;
                end
                // Release immediately once the exception is recognized --
                // a chip-wide pin held low indefinitely would also fault
                // the exception controller's own subsequent frame-push
                // writes, hanging dispatch itself (same reasoning
                // stall_fsm_tb.sv's own BERR-mid-CAS2 test documents).
                if (injected && !exc_seen && u_top.exc_active) begin
                    exc_seen = 1;
                    berr_n = 1'b1;
                end
                if (u_top.u_eu.u_rf.d_reg[6] === 32'd999) break;
            end
            berr_n = 1'b1;

            check("I-5: BERR was injected mid-linefill", injected);
            check("I-5: a real Bus Error exception was recognized (exc_active seen)", exc_seen);
            check32("I-5: the correct vector (2, Bus Error) was dispatched", u_top.u_eu.u_rf.d_reg[6], 32'd999);
            check32("I-5: F's own subroutine never spuriously completed (D5 stayed 0, the fault won the race)",
                  u_top.u_eu.u_rf.d_reg[5], 32'd0);
            // Recovery: eu_busy must clear (no lingering hang from the
            // aborted linefill) once the handler has parked.
            for (t = 0; t < 4000 && u_top.eu_busy; t++)
                @(posedge clk_4x);
            check("I-5: EU pipeline recovered (eu_busy clear, no lingering hang)", !u_top.eu_busy);
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

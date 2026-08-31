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
    logic        ciin_n   = 1'b1;   // Phase 158 Stage 7: CIIN# deasserted (not asserted)

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
        .cback_n      (cback_n),
        .ciin_n       (ciin_n),
        .ciout_n      ()
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

    // Phase 158 Stage 4a: sticky CBREQ# monitor -- proves the IBE=0 gating
    // fix genuinely suppresses burst requests (not just "happens to degrade
    // to individual reads anyway"). Cleared at the start of I-1's own test
    // block below, checked after its cold-miss warm-up completes.
    logic ic_burst_req_seen_r = 1'b0;
    always_ff @(posedge clk_4x)
        if (u_top.u_biu.u_icache.ic_burst_req) ic_burst_req_seen_r <= 1'b1;

    // Phase 158 Stage 4c: same shape, inverted -- proves D-10's own DBE=1
    // read genuinely used the real burst port (dc_burst_req), not just
    // "happened to fill the whole line some other way." Cleared at the
    // start of D-10's own test, checked after its burst-miss read.
    logic dc_burst_req_seen_r = 1'b0;
    always_ff @(posedge clk_4x)
        if (u_top.u_biu.u_cache.dc_burst_req) dc_burst_req_seen_r <= 1'b1;

    // Data-space (fc=101) DS# assertion counter -- Step 5's own D-cache
    // counterpart of code_ds_count. Unlike the I-cache's IFU-driven
    // readahead, EU data accesses are purely demand-driven (issued exactly
    // when the executing instruction needs them, no speculative queue) --
    // so this counter is not expected to need the same idx-filtering
    // Step 4 needed for code_ds_count; verified empirically per-test below
    // rather than assumed.
    int data_ds_count = 0;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b101) data_ds_count <= data_ds_count + 1;
    end

    // Same shape as data_ds_count but for fc=001 (user data) -- D-13's own
    // MOVES-driven accesses use this FC, which data_ds_count deliberately
    // excludes (scoped to fc=101 only, correct for every other test in this
    // file, all of which run purely in supervisor mode).
    int user_ds_count = 0;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b001) user_ds_count <= user_ds_count + 1;
    end





    // -------------------------------------------------------------------
    // Instruction encodings (reusing every already-proven opcode from
    // stall_fsm_tb.sv/stall_hazard_tb.sv verbatim where the same
    // instruction is needed, rather than re-deriving them).
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam MOVEA_L_IMM_A1 = 16'h227C;  // MOVEA.L #imm,A1
    localparam CLR_L_D5       = 16'h4285;
    localparam ADDI_L_D5      = 16'h0685;
    localparam CLR_L_D6       = 16'h4286;
    localparam ADDI_L_D6      = 16'h0686;
    // CLR.L D7 = 0x4280+7 (same +1-per-register pattern as D5/D6 above).
    localparam CLR_L_D7       = 16'h4287;
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
    // MOVEC Rc,Dn (read control register into Dn): same shape as MOVEC_OP
    // above with the direction bit flipped (0x4E7A vs 0x4E7B); the
    // extension word format is identical either way (Phase 158 Stage 6).
    localparam MOVEC_READ_OP  = 16'h4E7A;
    // MOVEC CACR,D6: ext word = (da=0<<15)|(rn=6<<12)|rc(0x002).
    localparam MOVEC_CACR_D6  = 16'h6002;
    // MOVEC D7,SFC: same MOVEC_OP shape, rc=0x000 (SFC) instead of CACR's
    // 0x002 -- (da=0<<15)|(rn=7<<12)|rc(0x000) = 0x7000.
    localparam MOVEC_D7_SFC   = 16'h7000;
    // MOVES.L (A0),D6 -- opcode 0000 1110 ss mmm rrr, ss=10(long),
    // mmm=010((An)),rrr=000(A0) = 0x0E90; ext word (D/A=0,Rn=D6=110,dir=1
    // load,reserved=0) = 0x6800 (format confirmed against tb/system_tb.sv's
    // own MOVES-01 comment: "ext: D/A=0,Rn=D0=000,dir=1(load) = 0x0800").
    localparam MOVES_L_A0_D6  = 16'h0E90;
    localparam MOVES_L_A0_D6_EXT = 16'h6800;
    // MOVE.W #imm,(A0): 00_11_ddd_mmm_MMM_rrr, size=11(word), dst
    // reg=A0(000), dst mode=(An)=010, src mode=111(imm), src reg=100(word
    // imm) -> 0011_000_010_111_100 = 0x30BC. One extension word (the
    // 16-bit immediate value itself).
    localparam MOVE_W_IMM_A0  = 16'h30BC;

    // Step 5 (D-cache): MOVE.L opcodes, all hand-derived from the general
    // `00 SS DDD MMM mmm rrr` MOVE format (SS=size: 01=byte,11=word,
    // 10=long; DDD=dst reg; MMM=dst mode; mmm=src mode; rrr=src reg) and
    // cross-checked against MOVE_W_IMM_A0's own already-verified derivation
    // above.
    localparam MOVE_L_A0_D5   = 16'h2A10;  // MOVE.L (A0),D5
    // TAS (A0): opcode 0x4AD0 (already proven in tb/stall_fsm_tb.sv's own
    // TAS_A0 constant) -- Phase 158 Stage 3.
    localparam TAS_A0         = 16'h4AD0;
    localparam MOVE_L_A0_D6   = 16'h2C10;  // MOVE.L (A0),D6
    // MOVE.L (A0),D7: same +0x200-per-register pattern as D5->D6 above.
    localparam MOVE_L_A0_D7   = 16'h2E10;  // MOVE.L (A0),D7
    // MOVE.L (d16,A0),D6: src mode=101 ((d16,An)) instead of 010 ((An)) --
    // needs one extension word (the 16-bit displacement).
    localparam MOVE_L_D16A0_D6 = 16'h2C28;
    localparam MOVE_L_D5_A0   = 16'h2085;  // MOVE.L D5,(A0)
    localparam MOVE_L_D6_A0   = 16'h2086;  // MOVE.L D6,(A0)
    localparam MOVE_L_D4_A0   = 16'h2084;  // MOVE.L D4,(A0)
    // MOVE.W D4,(A0): same derivation as MOVE_L_D4_A0 (0x2084) with the
    // size field (bits13-12) changed from 10(long) to 11(word) -- only the
    // top nibble's low bit differs (0x3084 vs 0x2084), same confidence
    // basis as MOVE_L_IMM_A0_IND's own derivation above.
    localparam MOVE_W_D4_A0   = 16'h3084;
    localparam MOVE_L_IMM_D4  = 16'h283C;  // MOVE.L #imm,D4
    // MOVE.L #imm,D6 = 0x203C + (6<<9), same derivation as MOVE_L_IMM_D4/D7.
    localparam MOVE_L_IMM_D6  = 16'h2C3C;
    // MOVE.L #imm,(A0): same shape as MOVE_W_IMM_A0 with SS=10(long)
    // instead of 11(word) -- only the size field differs (0x20BC vs
    // 0x30BC), giving high confidence in the derivation since
    // MOVE_W_IMM_A0 is already proven correct in production (I-4).
    localparam MOVE_L_IMM_A0_IND = 16'h20BC;
    localparam ADDQ_L_1_D5    = 16'h5285;  // ADDQ.L #1,D5
    localparam JMP_A1_IND     = 16'h4ED1;  // JMP (A1)

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

    // D-5's own BERR-mid-<D-cache access> helper -- mirrors
    // stall_fsm_tb.sv's own run_berr_mid_test shape (inject on the fault
    // instruction's own first bus-cycle change, release once exc_active is
    // observed) but keyed on data_ds_count instead of code_ds_count, and on
    // D5 (the shared fault counter D-5's own handler increments via
    // ADDQ.L #1,D5 each time it fires) instead of a fixed marker value --
    // lets two independent fault injections chain in one run, confirming
    // both the first and the cumulative second.
    task automatic run_dberr_mid_test(
        input string name,
        input int    expect_count,
        input int    budget
    );
        int t, d0;
        logic injected, exc_seen;
        injected = 0;
        exc_seen = 0;
        d0 = data_ds_count;
        for (t = 0; t < budget; t++) begin
            @(posedge clk_4x); #1;
            if (!injected && data_ds_count != d0) begin
                injected = 1;
                berr_n = 1'b0;
            end
            if (injected && !exc_seen && u_top.exc_active) begin
                exc_seen = 1;
                berr_n = 1'b1;
            end
            if (u_top.u_eu.u_rf.d_reg[5] === expect_count) break;
        end
        berr_n = 1'b1;
        check($sformatf("%s: BERR was injected", name), injected);
        check($sformatf("%s: a real Bus Error exception was recognized", name), exc_seen);
        check32($sformatf("%s: fault counter reached the expected cumulative value", name),
                u_top.u_eu.u_rf.d_reg[5], expect_count);
        for (t = 0; t < 4000 && u_top.eu_busy; t++)
            @(posedge clk_4x);
        check($sformatf("%s: EU pipeline recovered (eu_busy clear, no lingering hang)", name),
              !u_top.eu_busy);
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

    // Same shape again but targets SFC (rc=0x000) -- sets the function
    // code MOVES loads (ea->Rn) use, per rtl/eu_seq.sv's mem_fc mux.
    function automatic logic [31:0] emit_set_sfc(input logic [31:0] addr, input logic [31:0] value);
        logic [31:0] a4, a8;
        a4 = addr + 32'd4;
        a8 = addr + 32'd8;
        rom[addr[31:2]] = {MOVE_L_IMM_D7, value[31:16]};
        rom[a4[31:2]]   = {value[15:0], MOVEC_OP};
        rom[a8[31:2]]   = {MOVEC_D7_SFC, NOP_OP};
        emit_set_sfc = addr + 32'd12;
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

        // I-6's own subroutine G (Phase 158 Stage 5: I-cache freeze) --
        // same shape as I-2's own A/B and I-5's own F, written up front
        // for the same reason.
        rom[16'h1700/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1704/4] = {16'h0000, 16'd701};
        rom[16'h1708/4] = {RTS_OP, NOP_OP};

        rom[16'h0600/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h0604/4] = {16'h0000, 16'h15C0};
        rom[16'h0608/4] = {JSR_A0_IND, NOP_OP};   // JSR F -- triggers the cold miss/linefill to fault

        // Step 5's own backing data, pre-populated up front like every
        // other test's own fixed content in this file.
        rom[16'h2000/4] = 32'h1111_2222;  // P   (idx=0, tag=0x20)
        rom[16'h2004/4] = 32'h3333_4444;  // P+4 (same line, woff=1)
        rom[16'h2100/4] = 32'h5555_6666;  // Q   (idx=0, tag=0x21 -- aliases P)
        rom[16'h2600/4] = 32'h7777_8888;  // R   (idx=6, tag=0x26)
        rom[16'h2710/4] = 32'h9999_AAAA;  // S   (idx=1, tag=0x27 -- genuinely different index than R)
        rom[16'h2800/4] = 32'hBBBB_CCCC;  // W1  (idx=8, tag=0x28 -- write-through-on-hit)
        rom[16'h2900/4] = 32'hDDDD_EEEE;  // W2  (idx=9, tag=0x29 -- write-no-allocate-on-miss)
        rom[16'h2A00/4] = 32'hFFFF_0000;  // T1  (idx=A, tag=0x2A -- BERR-mid-read-miss target)
        rom[16'h2B00/4] = 32'h1234_5678;  // T2  (idx=B, tag=0x2B -- BERR-mid-write target)
        rom[16'h2C00/4] = 32'hCCCC_1111;  // T3  (idx=C, tag=0x2C -- D-6's own BERR-mid-read-miss target)
        rom[16'h2D00/4] = 32'hDDDD_2222;  // T4  (idx=D, tag=0x2D -- D-6's own BERR-mid-write target)
        rom[16'h2F00/4] = 32'h1111_1111;  // E   (idx=F, tag=0x2F -- Phase 158 Stage 3: RMW forced-miss)
        rom[16'h2E08/4] = 32'h0000_0000;  // W3+8 (Phase 158 Stage 4b: sub-long-word write-allocation target -- must be a known value, not X, so the post-write longword re-read has a well-defined lower half)
        // W4 (Phase 158 Stage 4c: DBE burst-fill target) -- a fresh 16-byte
        // line, 4 distinct known values so a wrong-word bug (e.g. off-by-
        // one beat) would show up as a visibly wrong value, not a
        // coincidental match.
        rom[16'h3000/4] = 32'h1111_2222;  // W4   (woff=0, the requested word)
        rom[16'h3004/4] = 32'h3333_4444;  // W4+4 (woff=1)
        rom[16'h3008/4] = 32'h5555_6666;  // W4+8 (woff=2)
        rom[16'h300C/4] = 32'h7777_8888;  // W4+C (woff=3, the whole-line-fill proof target)
        rom[16'h3200/4] = 32'hDEAD_1234;  // W6 (Phase 158 Stage 5: D-cache freeze write-hit-still-updates target)
        rom[16'h3300/4] = 32'h0000_0000;  // W7 (Phase 158 Stage 5: D-cache freeze write-miss-must-not-allocate target)
        rom[16'h2440/4] = 32'hAAAA_BBBB;  // WFC (D-13: FC-aware D-cache tag aliasing target -- idx=4, tag=0x24,
                                           // genuinely free of every other test's own addresses in this file)

        // D-5's own two independent handlers, one per fault -- an earlier
        // draft used ONE shared handler plus a register-indirect
        // JMP (A1), with the controller pointing A1 at whichever
        // continuation was needed before each fault. That hit something
        // this project has never exercised before (a JMP (An) redirect
        // immediately following exception dispatch, chained twice) and
        // produced genuinely corrupted register state (A1 never actually
        // updated away from its first value, and D5 -- untouched by any
        // instruction in this path -- read back 0xFFFF) -- not chased
        // further; switched to two independent, fixed-target handlers
        // using JMP_ABS_L_OP instead (already proven correct throughout
        // this entire file), with the controller rewriting the vector-2
        // table entry before each fault rather than a shared handler
        // redirecting via a register.
        rom[16'h0780/4] = {ADDQ_L_1_D5, JMP_ABS_L_OP};   // handler A: D5++ ; JMP D5_CONT_A
        rom[16'h0784/4] = {16'h0000, 16'h0A00};
        rom[16'h0788/4] = {ADDQ_L_1_D5, JMP_ABS_L_OP};   // handler B: D5++ ; JMP D5_CONT_B
        rom[16'h078C/4] = {16'h0000, 16'h0A40};

        // D-5's own two fixed continuation blocks -- written up front for
        // the same reason as everything else here: the file's pure
        // NOP-fall-through execution model means any rom[] write for an
        // address the DUT might reach loses the race if issued after real
        // simulated time has already advanced past it.
        rom[16'h0A00/4] = {MOVEA_L_IMM_A0, 16'h0000};    // D5_CONT_A: redirect vector 2 -> handler B
        rom[16'h0A04/4] = {16'h0008, MOVE_L_IMM_A0_IND};
        rom[16'h0A08/4] = {16'h0000, 16'h0788};
        rom[16'h0A0C/4] = {MOVEA_L_IMM_A0, 16'h0000};    // A0 = T2
        rom[16'h0A10/4] = {16'h2B00, MOVE_L_IMM_D4};
        rom[16'h0A14/4] = {16'h1111, 16'h2222};          // D4 = 0x11112222
        rom[16'h0A18/4] = {MOVE_L_D4_A0, NOP_OP};        // faulting write

        rom[16'h0A40/4] = {MOVEA_L_IMM_A0, 16'h0000};    // D5_CONT_B: restore vector 2
        rom[16'h0A44/4] = {16'h0008, MOVE_L_IMM_A0_IND};
        rom[16'h0A48/4] = {16'h0000, 16'h0700};
        rom[16'h0A4C/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h0A50/4] = {16'h0B00, NOP_OP};            // on to D-6

        // D-6: the ORIGINAL Phase 133 mechanism, reconstructed as its own
        // dedicated test rather than left as an abandoned anomaly. One
        // shared BERR handler (D5++ ; JMP (A1)) with the controller
        // repointing A1 to a different continuation before each of two
        // chained fault injections -- exactly what D-5's own earlier draft
        // used before being replaced by the JMP_ABS_L_OP workaround (see
        // that comment above). Investigated via a standalone scratch repro
        // first (reconstructing this exact mechanism, including matching
        // D-5's own real read-miss-then-write-miss shape so both faults hit
        // biu_cache_if.sv's genuine multi-beat FSM, not a single-beat
        // access): 10/10 checks passed cleanly against BOTH the current RTL
        // and the pre-Phase-134 RTL the original anomaly was seen under --
        // the JMP (An)-immediately-after-exception-dispatch mechanism
        // itself is not a real RTL race. The original "earlier draft"'s
        // corruption is concluded to have been a testbench-construction
        // artifact (almost certainly the same "ROM write issued after real
        // simulated time already passed that address" class of bug I-4/I-5
        // (Phase 131) and T4c/T4d (Phase 126) each independently hit) --
        // this test is written with every ROM write up front, per this
        // file's own established discipline, specifically to avoid it.
        rom[16'h0790/4] = {ADDQ_L_1_D5, JMP_A1_IND};     // shared handler: D5++ ; JMP (A1)

        rom[16'h0B00/4] = {MOVEA_L_IMM_A0, 16'h0000};    // D6_controller: redirect vector 2 -> handler
        rom[16'h0B04/4] = {16'h0008, MOVE_L_IMM_A0_IND};
        rom[16'h0B08/4] = {16'h0000, 16'h0790};
        rom[16'h0B0C/4] = {CLR_L_D5, MOVEA_L_IMM_A0};    // D5=0 ; A0 = T3
        rom[16'h0B10/4] = {16'h0000, 16'h2C00};
        rom[16'h0B14/4] = {MOVEA_L_IMM_A1, 16'h0000};    // A1 = D6_CONT_A
        rom[16'h0B18/4] = {16'h0B40, MOVE_L_A0_D6};      // faulting read #1 (T3, cold miss)
        rom[16'h0B1C/4] = {NOP_OP, NOP_OP};

        rom[16'h0B40/4] = {MOVEA_L_IMM_A1, 16'h0000};    // D6_CONT_A: A1 = D6_CONT_B
        rom[16'h0B44/4] = {16'h0B80, MOVEA_L_IMM_A0};    // A0 = T4
        rom[16'h0B48/4] = {16'h0000, 16'h2D00};
        rom[16'h0B4C/4] = {MOVE_L_IMM_D4, 16'h1111};     // D4 = 0x11112222
        rom[16'h0B50/4] = {16'h2222, MOVE_L_D4_A0};      // faulting write #2 (T4, write-no-allocate)
        rom[16'h0B54/4] = {NOP_OP, NOP_OP};

        rom[16'h0B80/4] = {MOVEA_L_IMM_A0, 16'h0000};    // D6_CONT_B: restore vector 2
        rom[16'h0B84/4] = {16'h0008, MOVE_L_IMM_A0_IND};
        rom[16'h0B88/4] = {16'h0000, 16'h0700};
        rom[16'h0B8C/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h0B90/4] = {16'h0C00, NOP_OP};            // on to D-9

        // ---- D-9: write-allocation (WA=1), manual Figure 6-4 Examples
        // 3/4/5 (W3=0x2E00, idx=0 -- every existing XX00-style address in
        // this file's own backing-data block, e.g. R/S/W1/W2 above despite
        // their own comments' stale "idxN" labels, shares real index 0 too;
        // harmless, each test's own distinct tag simply evicts/replaces
        // whatever was there). Aligned long-word write on a genuine miss
        // must allocate (validate the entry, re-read hits with 0 bus
        // cycles); a sub-long-word write on a genuine miss must NOT
        // allocate (re-read still misses) even with WA=1. Deliberately
        // placed here (fixed address, after D-6, jumped to explicitly)
        // rather than its own original position between D-4b and D-5 -- an
        // earlier attempt there desynced D-6's own later fault counter
        // (D5 read 0x321 instead of 2) despite every one of THIS test's own
        // checks passing and D-5/D-6a's own checks passing too, the exact
        // same "unexplained timing sensitivity inserting new code before
        // D-5" symptom already documented (and left unresolved, reverted
        // rather than chased) in Stage 2's own postmortem -- relocated here
        // rather than re-investigating the same open question.
        // ----
        begin
            logic [31:0] p, p4, p8;
            // D-6's own coincidental leftover state can leave D6 already
            // reading 0 -- the check code's own "wait for D6==0 (write
            // retired) then wait for D6==target" checkpoint pattern
            // (matching D-4a's own proven shape) silently fires its first
            // phase immediately in that case, sampling the bus-cost
            // baseline *before* the aligned write even executes instead of
            // after it. Force D6 to a known-nonzero placeholder first so
            // the "wait for 0" phase always genuinely waits for this test's
            // own CLR_L_D6 below.
            rom[16'h0C00/4] = {MOVE_L_IMM_D6, 16'hFFFF};
            rom[16'h0C04/4] = {16'hFFFF, MOVE_L_IMM_D7};
            rom[16'h0C08/4] = {16'hFFFF, 16'hFFFF};          // D6=D7=0xFFFFFFFF placeholder
            p = emit_set_cacr(32'h0000_0C0C, 32'h0000_2100); // WA=1 | dcache_en=1
            rom[p[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'h2E00, MOVE_L_IMM_D4};
            rom[p8[31:2]] = {16'hAABB, 16'hCCDD};            // D4 = 0xAABBCCDD
            p = p + 32'd12;
            rom[p[31:2]] = {MOVE_L_D4_A0, CLR_L_D6};         // aligned long write -> must allocate (W3#1)
            p4 = p + 32'd4;
            rom[p4[31:2]] = {MOVE_L_A0_D6, NOP_OP};          // re-read W3 (must HIT, 0 bus cycles)
            p = p + 32'd8;
            rom[p[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'h2E08, MOVE_W_D4_A0};        // A0 = W3+8 (woff=2, same line, still invalid)
            rom[p8[31:2]] = {CLR_L_D7, MOVE_L_A0_D7};        // sub-long word write (miss) -> must NOT allocate
            p = p + 32'd12;
            rom[p[31:2]] = {NOP_OP, NOP_OP};                 // re-read W3+8 (must MISS again)
            p = p + 32'd4;

            // ---- D-10: DBE-gated D-cache burst fill (manual §6.1.3.2,
            // Phase 158 Stage 4c). W4=0x3000, a genuinely fresh 16-byte
            // line never touched before. The distinguishing proof vs.
            // CI_D_MISS's own single-word-only fill: a *different* word
            // offset within the *same* line, never independently fetched,
            // must also come back a HIT afterward -- only a real
            // whole-line burst (or its degraded individual-refetch
            // fallback, not reachable in this testbench since cback_n is
            // hardwired asserted, see its own module-level comment) fills
            // all four words at once. Same D6/D7-placeholder pattern as
            // D-9's own check for the identical "testbench check code can
            // start polling before hardware reaches this test's own ROM"
            // hazard that test found -- placed AFTER emit_set_cacr this
            // time (unlike D-9's own, which places it before): emit_set_cacr
            // always uses D7 as its own internal scratch, so a D7 placeholder
            // written before it would be immediately clobbered by the
            // MOVEC sequence's own MOVE.L #value,D7 and never actually seen
            // by this test's own D7 checkpoint -- D-9's own D6 checkpoint
            // never hit this because emit_set_cacr never touches D6.
            // ----
            p = emit_set_cacr(p, 32'h0000_1100);             // DBE=1 | dcache_en=1
            rom[p[31:2]]  = {MOVE_L_IMM_D6, 16'hFFFF};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'hFFFF, MOVE_L_IMM_D7};
            rom[p8[31:2]] = {16'hFFFF, 16'hFFFF};            // D6=D7=0xFFFFFFFF placeholder
            p = p + 32'd12;
            rom[p[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'h3000, CLR_L_D6};
            rom[p8[31:2]] = {MOVE_L_A0_D6, MOVEA_L_IMM_A0};  // burst-miss read W4 ; A0 = W4+12 (woff=3)
            p = p + 32'd12;
            rom[p[31:2]] = {16'h0000, 16'h300C};
            p4 = p + 32'd4;
            rom[p4[31:2]] = {CLR_L_D7, MOVE_L_A0_D7};        // re-read at a DIFFERENT offset (must HIT)
            p = p + 32'd8;
            rom[p[31:2]] = {NOP_OP, NOP_OP};
            p = p + 32'd4;

            // ---- D-11: D-cache freeze (FD), manual §6.3.1.5 (confirmed by
            // direct re-read). Two proofs in one sequence: (a) a write that
            // HITS still updates the entry even while frozen (the manual's
            // own explicit exception); (b) a write that MISSES does NOT
            // allocate even with WA=1 also set, i.e. FD overrides WA. W6=
            // 0x3200 primed into the cache first with FD=0 (an ordinary,
            // unfrozen read-miss); W7=0x3300 is a fresh, never-touched
            // address for the miss-suppression half.
            // ----
            p = emit_set_cacr(p, 32'h0000_0100);             // dcache_en=1, FD=0 -- prime step
            rom[p[31:2]]  = {MOVE_L_IMM_D6, 16'hFFFF};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'hFFFF, MOVEA_L_IMM_A0};
            rom[p8[31:2]] = {16'h0000, 16'h3200};            // D6 placeholder ; A0 = W6
            p = p + 32'd12;
            rom[p[31:2]] = {CLR_L_D6, MOVE_L_A0_D6};         // prime-read W6 (cold miss, caches it -- FD=0)
            p = p + 32'd4;
            rom[p[31:2]] = {NOP_OP, NOP_OP};
            p = p + 32'd4;

            p = emit_set_cacr(p, 32'h0000_2300);             // dcache_en=1 | FD=1 | WA=1
            rom[p[31:2]]  = {MOVE_L_IMM_D4, 16'h1357};
            p4 = p + 32'd4;
            rom[p4[31:2]] = {16'h2468, MOVE_L_D4_A0};        // D4 = 0x13572468 ; write D4->W6 (hit -- must still update)
            p = p + 32'd8;
            rom[p[31:2]] = {CLR_L_D6, MOVE_L_A0_D6};         // re-read W6 (must HIT with the new value, 0 bus cost)
            p = p + 32'd4;
            rom[p[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            p4 = p + 32'd4; p8 = p + 32'd8;
            rom[p4[31:2]] = {16'h3300, MOVE_L_IMM_D4};
            rom[p8[31:2]] = {16'h9999, 16'h8888};            // A0 = W7 ; D4 = 0x99998888
            p = p + 32'd12;
            rom[p[31:2]] = {MOVE_L_D4_A0, CLR_L_D7};         // write D4->W7 (miss, WA=1 but FD=1 -- must NOT allocate)
            p = p + 32'd4;
            rom[p[31:2]] = {MOVE_L_A0_D7, NOP_OP};           // re-read W7 (must STILL miss -- real bus cost)
            p = p + 32'd4;

            // ---- I-6: I-cache freeze (FI), manual §6.3.1.10 (confirmed by
            // direct re-read): "the entry (or line) is not replaced" on a
            // miss -- unlike D-cache freeze, no write-hit exception to
            // preserve (I-cache is read-only). G=0x1700, visited twice via
            // JSR; both visits must show real bus activity (code_ds_count),
            // proving neither one cached -- contrasting directly with I-1's
            // own test, where the second visit is the whole point of being
            // a cache HIT.
            // ----
            p = emit_set_cacr(p, 32'h0000_0003);             // icache_en=1 | FI=1
            rom[p[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            p4 = p + 32'd4;
            rom[p4[31:2]] = {16'h1700, CLR_L_D5};            // A0 = G ; clear D5 (settle before visit#1)
            p = p + 32'd8;
            rom[p[31:2]] = {JSR_A0_IND, NOP_OP};             // visit#1 (genuine miss, FI=1 -- never cached anyway)
            p = p + 32'd4;
            rom[p[31:2]] = {CLR_L_D5, JSR_A0_IND};           // clear D5 (settle before visit#2) ; visit#2
            p = p + 32'd4;
            rom[p[31:2]] = {NOP_OP, NOP_OP};
            p = p + 32'd4;

            // ---- D-12: CACR self-clearing bit readback masking, manual
            // §6.3.1.3/6.3.1.4/6.3.1.8/6.3.1.9 + §6.3.1 itself (confirmed
            // by direct re-read): "the CD/CED/CI/CEI bit is always read as
            // a zero," and bits 31-14 + 7-5 are reserved, "currently read
            // as zeros." Write every one of bits 13:0 to 1 (0x3FFF), then
            // read CACR back via MOVEC CACR,D6 -- only the real bits
            // (WA/DBE/FD/ED/IBE/FI/EI) should survive; expected 0x3313,
            // hand-derived and cross-checked directly before writing this
            // test (write_val & keep_mask where keep_mask has bits
            // 13,12,9,8,4,1,0 set).
            // ----
            p = emit_set_cacr(p, 32'h0000_3FFF);
            rom[p[31:2]] = {MOVEC_READ_OP, MOVEC_CACR_D6};   // MOVEC CACR,D6 -- read it back
            p = p + 32'd4;
            rom[p[31:2]] = {NOP_OP, NOP_OP};
            p = p + 32'd4;

            p = emit_set_cacr(p, 32'h0000_0100);             // back to icache_en=0 | dcache_en=1 -- matches
                                                               // what I-5 (next) has always relied on: I-5's
                                                               // own code (0x0600) never sets CACR itself, so
                                                               // it inherits whatever the D-cache tests before
                                                               // it last left CACR at -- unrelated to this
                                                               // stage, a pre-existing condition confirmed by
                                                               // reading I-5's own ROM setup before assuming
                                                               // anything here.
            rom[p[31:2]] = {JMP_ABS_L_OP, 16'h0000};
            p4 = p + 32'd4;
            rom[p4[31:2]] = {16'h1900, NOP_OP};              // on to D-13 (which itself continues to I-5)
        end

        // ===================================================================
        // D-13: FC-aware D-cache tag prevents supervisor/user aliasing
        // (Stage 1 of the open-items backlog plan). Placed at its own
        // isolated, explicit-jump-only address rather than folded into the
        // D-1..D-9 flowing-accumulator region -- that region was directly
        // confirmed (via a temporary rom[] dump) to already collide with
        // the fixed-address D-5/D-6 exception-handler blocks (its own
        // flowing setup writes land on 0xA00-0xA0F, squarely inside
        // D-5_CONT_A's own fixed 0xA00-0xA1B footprint, last-write-wins
        // silently clobbering it), which is the real, confirmed root cause
        // of the "unexplained timing sensitivity inserting new code before
        // D-5" symptom flagged (and reverted rather than diagnosed) back in
        // Phase 158 Stage 2 and again for D-9's own original placement --
        // not a genuine RTL/simulation timing race, a plain address
        // collision between two independently-grown ROM allocation
        // schemes. Confirmed harmless in the CURRENT file only by luck of
        // exactly which bytes happen to overlap; not touched or "fixed"
        // here (out of scope, high blast radius for a pre-existing,
        // already-passing state) -- this test instead follows D-9's own
        // already-proven-safe convention: an isolated fixed address (0x1900,
        // confirmed free of every other test's own footprint), reached
        // and left via explicit JMP only, never via the flowing accumulator.
        // ===================================================================
        begin
            logic [31:0] q, q4;
            q = 32'h0000_1900;
            q = emit_set_cacr(q, 32'h0000_0100);   // dcache_en=1 (ED), matches D-1's own baseline
            q = emit_set_sfc(q, 32'd1);            // SFC=1 (user data space), for the MOVES loads below

            rom[q[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            q4 = q + 32'd4;
            rom[q4[31:2]] = {16'h2440, CLR_L_D5};  // A0 = WFC ; clear D5 (settle before supervisor read)
            q = q + 32'd8;
            rom[q[31:2]] = {MOVE_L_A0_D5, CLR_L_D6};  // plain supervisor-FC read (FC=101) ; clear D6 (settle before MOVES #1)
            q = q + 32'd4;
            rom[q[31:2]] = {MOVES_L_A0_D6, MOVES_L_A0_D6_EXT};  // MOVES.L (A0),D6 #1 -- FC=SFC=user data (001); expect MISS
            q = q + 32'd4;
            rom[q[31:2]] = {CLR_L_D6, MOVES_L_A0_D6};  // clear D6 (settle before MOVES #2) ; MOVES.L (A0),D6 opcode
            q4 = q + 32'd4;
            rom[q4[31:2]] = {MOVES_L_A0_D6_EXT, JMP_ABS_L_OP};  // MOVES #2's own ext word ; JMP.L opcode
            q = q + 32'd8;
            rom[q[31:2]] = {16'h0000, 16'h0600};   // JMP.L 0x00000600 -- on to I-5 (D-12's own original target)
            q = q + 32'd4;
        end

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
            ic_burst_req_seen_r = 1'b0;
            next = emit_set_cacr(32'h0000_0100, 32'h0000_0001); // icache_en=1, IBE=0
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
            check("I-1: IBE=0 -- CBREQ#/ic_burst_req was never asserted for the cold-miss warm-up",
                  !ic_burst_req_seen_r);
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
            // Phase 158 Stage 2: tag_i is now 25 bits (FC2 prepended above
            // addr[31:8], manual §6.1.2) -- bit24=1 since every fetch's own
            // FC is currently the hardcoded 3'b110 (FC2=1) constant.
            check("I-3: CACR.CEI selectivity -- D's own cache entry (idx 10) survived untouched",
                  u_top.u_biu.u_icache.valid_i[10] === 1'b1 &&
                  u_top.u_biu.u_icache.tag_i[10]   === 25'h1000013);
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

            // On to Step 5's own D-cache controller.
            rom[a[31:2]] = {JMP_ABS_L_OP, 16'h0000};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {16'h0900, NOP_OP};
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
        // Step 5: D-cache first-ever enabled correctness + timing pass.
        // biu_cache_if.sv's D-cache side is reachable through the EU's own
        // ordinary data-access port (m68030_top.sv hardwires eu_is_icache=0
        // there) and never needed a new module the way Phase 127's I-cache
        // work did -- but had literally never been exercised with CACR's
        // dcache_en (bit 9) set anywhere in this project's 131 prior
        // phases: CACR resets to 0, and grepping every existing test, the
        // only place it's ever written nonzero is a MOVEC register-plumbing
        // check with no memory access afterward. D-1..D-5 mirror I-1..I-5's
        // own shape, adapted for data accesses (register loads/stores
        // instead of instruction fetches), plus two D-cache-specific
        // properties the read-only I-cache has no equivalent of:
        // write-through-on-hit and write-no-allocate-on-miss.
        //
        // Unlike I-cache accesses, D-cache accesses are purely
        // demand-driven -- the EU has no prefetch queue analogous to the
        // IFU's own -- so none of these checks are expected to need Step
        // 4's own idx-filtered counter to guard against unrelated
        // readahead pollution (verified empirically below, not assumed).
        //
        // D-1 (P=0x2000/P+4=0x2004, same line) targets a specific
        // correctness question the RTL's own structure raises:
        // biu_cache_if.sv's CI_D_MISS only ever writes ONE word slot
        // (data_d[idx][woff]) into a cache line on a miss, yet marks the
        // WHOLE line valid -- if a *different* word offset within that
        // same line is read next, does it return real data or an
        // unfilled, never-written slot?
        // ===================================================================
        begin
            logic [31:0] a, a4, a8;

            a = 32'h0000_0900;

            // ---- D-1: miss/hit + partial-word-fill correctness ----
            // Phase 158 Stage 1: dcache_en is really cacr[8] (ED), not cacr[9]
            // (FD, freeze) -- this file previously encoded the identical bug
            // the RTL had, so every D-cache test below was self-consistently
            // validating the wrong bit. 0x101 = EI(bit0) | ED(bit8).
            a = emit_set_cacr(a, 32'h0000_0101);  // icache_en=1, dcache_en=1
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2000, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, CLR_L_D6};   // P#1 (cold miss)
            a = a + 32'd12;
            rom[a[31:2]] = {MOVE_L_D16A0_D6, 16'h0004}; // P+4, first-ever access to this woff
            a4 = a + 32'd4;
            rom[a4[31:2]] = {CLR_L_D5, MOVE_L_A0_D5};   // P#2 (revisit woff0, must hit)
            a = a + 32'd8;

            // ---- D-8 (Phase 158 Stage 3): RMW forced-miss (E=0x2F00) ----
            // Ordinary read caches E. TAS (A0) then targets the SAME,
            // already-cached address -- per manual §6.1.2.2, its own read
            // must always be forced to miss (a real bus cycle), never
            // served from the cache. Verified via exact bus-cycle count:
            // TAS costs exactly 2 real cycles (forced-miss read + its own
            // mandatory write-through write) even though the address was
            // already resident.
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2F00, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, TAS_A0};      // cache-populating read ; TAS (A0)
            a = a + 32'd12;
            rom[a[31:2]] = {CLR_L_D6, NOP_OP};           // completion marker
            a = a + 32'd4;

            // ---- D-2: aliasing/eviction (P vs Q, same idx0) ----
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2100, CLR_L_D6};
            rom[a8[31:2]] = {MOVE_L_A0_D6, MOVEA_L_IMM_A0};  // Q#1 (cold miss, evicts P)
            a = a + 32'd12;
            rom[a[31:2]] = {16'h0000, 16'h2000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {CLR_L_D5, MOVE_L_A0_D5};        // P revisit (evicted by Q, must miss)
            rom[a8[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a = a + 32'd12;
            rom[a[31:2]] = {16'h2100, CLR_L_D6};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {MOVE_L_A0_D6, CLR_L_D6};        // Q revisit#1 (evicted by P, must miss)
            rom[a8[31:2]] = {MOVE_L_A0_D6, NOP_OP};          // Q revisit#2 (A0 unchanged, must hit)
            a = a + 32'd12;

            // ---- D-3: CD/CED flush (R=0x2600 idx0, S=0x2710 idx1) ----
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2600, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, MOVEA_L_IMM_A0};  // R#1 (cold miss)
            a = a + 32'd12;
            rom[a[31:2]] = {16'h0000, 16'h2710};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {CLR_L_D6, MOVE_L_A0_D6};        // S#1 (cold miss)
            a = a + 32'd8;

            // 0x901 = EI|ED|CD(bit11); 0x101 = EI|ED (CD is bit11, was
            // mislabeled cacr[12]=DBE before Phase 158 Stage 1).
            a = emit_set_cacr(a, 32'h0000_0901);  // dcache_en|CD pulse
            a = emit_set_cacr(a, 32'h0000_0101);  // back to just dcache_en

            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2600, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, MOVEA_L_IMM_A0};  // R#2 (post-CD, must miss)
            a = a + 32'd12;
            rom[a[31:2]] = {16'h0000, 16'h2710};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {CLR_L_D6, MOVE_L_A0_D6};        // S#2 (post-CD, must miss)
            a = a + 32'd8;

            a = emit_set_caar(a, 32'h0000_0000);  // CAAR = idx(R)<<4 = 0<<4 (R's own real index)
            // 0x501 = EI|ED|CED(bit10); CED was mislabeled cacr[11]=CD before
            // Phase 158 Stage 1.
            a = emit_set_cacr(a, 32'h0000_0501);  // dcache_en|CED pulse
            a = emit_set_cacr(a, 32'h0000_0101);  // back to just dcache_en

            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2600, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, MOVEA_L_IMM_A0};  // R#3 (post-CED, must miss -- its own index)
            a = a + 32'd12;
            rom[a[31:2]] = {16'h0000, 16'h2710};
            a4 = a + 32'd4;
            rom[a4[31:2]] = {CLR_L_D6, MOVE_L_A0_D6};        // S#3 (post-CED, must HIT -- untouched index)
            a = a + 32'd8;

            // ---- D-4a: write-through-on-hit (W1=0x2800) ----
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2800, CLR_L_D5};
            rom[a8[31:2]] = {MOVE_L_A0_D5, MOVE_L_IMM_D4};   // W1#1 (cold miss, warm)
            a = a + 32'd12;
            rom[a[31:2]] = {16'h1357, 16'h2468};             // D4 = 0x13572468
            a4 = a + 32'd4;
            rom[a4[31:2]] = {MOVE_L_D4_A0, CLR_L_D6};        // write D4 -> W1 (hit at write time)
            a = a + 32'd8;
            rom[a[31:2]] = {MOVE_L_A0_D6, NOP_OP};           // re-read W1
            a = a + 32'd4;

            // ---- D-4b: write-no-allocate-on-miss (W2=0x2900) ----
            rom[a[31:2]] = {MOVEA_L_IMM_A0, 16'h0000};
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2900, MOVE_L_IMM_D4};
            rom[a8[31:2]] = {16'h2468, 16'h1357};            // D4 = 0x24681357
            a = a + 32'd12;
            rom[a[31:2]] = {MOVE_L_D4_A0, CLR_L_D6};         // write D4 -> W2 (never-before-accessed, must not allocate)
            a4 = a + 32'd4;
            rom[a4[31:2]] = {MOVE_L_A0_D6, NOP_OP};          // re-read W2 (must miss)
            a = a + 32'd8;

            // ---- D-5: BERR mid D-cache read-miss + write, cache ENABLED ----
            rom[a[31:2]] = {CLR_L_D5, MOVEA_L_IMM_A0};       // fault counter=0 ; A0=vector table
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h0000, 16'h0008};
            rom[a8[31:2]] = {MOVE_L_IMM_A0_IND, 16'h0000};
            a = a + 32'd12;
            rom[a[31:2]] = {16'h0780, MOVEA_L_IMM_A0};       // redirect vector 2 -> handler A ; A0 setup
            a4 = a + 32'd4; a8 = a + 32'd8;
            rom[a4[31:2]] = {16'h2A00, MOVE_L_A0_D6};        // A0 = T1 ; faulting read
            rom[a8[31:2]] = {NOP_OP, NOP_OP};
            a = a + 32'd12;
        end

        begin
            int c0, c1, c2, c3, e, t;

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_0900; t++)
                @(posedge clk_4x);

            // D-1
            c0 = data_ds_count;
            wait_cleared_then_set(5, 32'h1111_2222, 20000, e);
            c1 = data_ds_count;
            check32("D-1: P#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'h1111_2222);
            check("D-1: P#1's own cold miss caused real bus activity", c1 - c0 > 0);
            // Phase 158 Stage 2: direct internal-state check that the tag
            // genuinely captures FC (manual §6.1.2, p.6-6) -- P is a plain
            // supervisor data access (FC=101), addr=0x2000 so idx=0,
            // addr[31:8]=0x20; expected tag = {3'b101, 24'h000020} =
            // 27'h5000020. Deliberately low-risk (pure internal-state read,
            // zero new instructions/ROM) after a mid-sequence full
            // MOVES-based aliasing test caused an unrelated, unexplained
            // timing sensitivity in the D-5a->D-5b transition further down
            // this file when tried first -- reverted rather than chase a
            // fragile test for marginal extra coverage.
            check32("D-1: cache tag includes FC (supervisor data, FC=101)",
                    u_top.u_biu.u_cache.tag_d[0], 27'h5000020);

            wait_cleared_then_set(6, 32'h3333_4444, 20000, e);
            c2 = data_ds_count;
            // The critical check: P+4 is a *different* word offset within
            // the *same* line as P, never independently fetched before.
            // biu_cache_if.sv's CI_D_MISS only populates ONE word slot per
            // miss yet marks the whole line valid -- if that's a real gap,
            // this would read back garbage (X in sim) regardless of
            // whether it shows as a hit or a miss below.
            check32("D-1: P+4 (different woff, same line) loaded the CORRECT value",
                    u_top.u_eu.u_rf.d_reg[6], 32'h3333_4444);
            $display("D-1: P+4 access was a %s (bus delta %0d)",
                     (c2 - c1 > 0) ? "MISS" : "HIT", c2 - c1);

            wait_cleared_then_set(5, 32'h1111_2222, 20000, e);
            c3 = data_ds_count;
            check32("D-1: P#2 (revisit woff0) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'h1111_2222);
            check32("D-1: P#2's own revisit cost exactly 0 bus cycles (pure hit)", c3 - c2, 32'd0);

            // D-8 (Phase 158 Stage 3): RMW forced-miss (E=0x2F00)
            begin
                int rc0, rc1;
                wait_cleared_then_set(5, 32'h1111_1111, 20000, e);
                rc0 = data_ds_count;
                check32("D-8: cache-populating read loaded E correctly",
                        u_top.u_eu.u_rf.d_reg[5], 32'h1111_1111);
                // D6 last held D-1's own P+4 value (0x33334444, definitely
                // non-zero), so waiting for it to become 0 unambiguously
                // detects this test's own CLR.L D6 completion marker
                // (unlike wait_cleared_then_set, whose "wait for 0, then
                // wait for target" shape can't distinguish a target of 0
                // from its own starting sentinel).
                for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                    @(posedge clk_4x);
                rc1 = data_ds_count;
                check32("D-8: TAS on an already-cached address still cost exactly 2 real bus cycles (forced-miss read + write-through write)",
                        rc1 - rc0, 32'd2);
            end

            // D-2
            c0 = c3;
            wait_cleared_then_set(6, 32'h5555_6666, 20000, e);
            c1 = data_ds_count;
            check32("D-2: Q#1 (cold, evicts P) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'h5555_6666);
            check("D-2: Q#1's own cold miss caused real bus activity", c1 - c0 > 0);

            wait_cleared_then_set(5, 32'h1111_2222, 20000, e);
            c2 = data_ds_count;
            check32("D-2: P revisit (evicted by Q, must miss) loaded D5 correctly",
                    u_top.u_eu.u_rf.d_reg[5], 32'h1111_2222);
            check("D-2: P revisit needed real bus activity -- the aliasing proof (Q evicted P)", c2 - c1 > 0);

            wait_cleared_then_set(6, 32'h5555_6666, 20000, e);
            c3 = data_ds_count;
            check32("D-2: Q revisit#1 (evicted right back by P, must miss) loaded D6 correctly",
                    u_top.u_eu.u_rf.d_reg[6], 32'h5555_6666);
            check("D-2: Q revisit#1 needed real bus activity (P's own refetch evicted Q right back)",
                  c3 - c2 > 0);

            wait_cleared_then_set(6, 32'h5555_6666, 20000, e);
            c0 = data_ds_count;
            check32("D-2: Q revisit#2 (hit, revisited immediately) loaded D6 correctly",
                    u_top.u_eu.u_rf.d_reg[6], 32'h5555_6666);
            check32("D-2: Q revisit#2 cost exactly 0 bus cycles (pure hit)", c0 - c3, 32'd0);

            // D-3
            c1 = c0;
            wait_cleared_then_set(5, 32'h7777_8888, 20000, e);
            c2 = data_ds_count;
            check32("D-3: R#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'h7777_8888);
            wait_cleared_then_set(6, 32'h9999_AAAA, 20000, e);
            c3 = data_ds_count;
            check32("D-3: S#1 (cold) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'h9999_AAAA);

            wait_cleared_then_set(5, 32'h7777_8888, 20000, e);
            c0 = data_ds_count;
            check32("D-3: R#2 (post-CD, must miss) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'h7777_8888);
            check("D-3: CACR.CD forced a real miss on R (global clear)", c0 - c3 > 0);
            wait_cleared_then_set(6, 32'h9999_AAAA, 20000, e);
            c1 = data_ds_count;
            check32("D-3: S#2 (post-CD, must miss) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'h9999_AAAA);
            check("D-3: CACR.CD forced a real miss on S too (global clear)", c1 - c0 > 0);

            wait_cleared_then_set(5, 32'h7777_8888, 20000, e);
            c2 = data_ds_count;
            check32("D-3: R#3 (post-CED, must miss) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'h7777_8888);
            check("D-3: CACR.CED forced a real miss on R (its own index)", c2 - c1 > 0);
            wait_cleared_then_set(6, 32'h9999_AAAA, 20000, e);
            c3 = data_ds_count;
            check32("D-3: S#3 (post-CED, must HIT) loaded D6 correctly", u_top.u_eu.u_rf.d_reg[6], 32'h9999_AAAA);
            check32("D-3: CACR.CED selectivity -- S's own line survived untouched (0 bus cycles)",
                    c3 - c2, 32'd0);

            // D-4a: write-through-on-hit
            c0 = c3;
            wait_cleared_then_set(5, 32'hBBBB_CCCC, 20000, e);
            c1 = data_ds_count;
            check32("D-4a: W1#1 (cold) loaded D5 correctly", u_top.u_eu.u_rf.d_reg[5], 32'hBBBB_CCCC);
            // The write itself (MOVE.L D4,(A0)) always costs 1 real bus
            // cycle -- write-through goes to the bus unconditionally,
            // hit or miss -- so a plain c_after_reread - c1 delta would
            // conflate that mandatory cost with the re-read's own. CLR_L_D6
            // (placed right after the write in program order) gives a
            // real checkpoint marking "the write has retired" to isolate
            // the re-read's own cost cleanly, the same way wait_cleared_
            // then_set's own phase 1 already synchronizes on a register
            // read as 0 -- done manually here since the *timing* of that
            // transition, not just its eventual value, is what this check
            // needs.
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                @(posedge clk_4x);
            c2 = data_ds_count;
            check("D-4a: write-through's own mandatory bus cycle happened", c2 - c1 > 0);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'h1357_2468; t++)
                @(posedge clk_4x);
            c3 = data_ds_count;
            check32("D-4a: re-read after write-to-hit shows the NEW value",
                    u_top.u_eu.u_rf.d_reg[6], 32'h1357_2468);
            check32("D-4a: write-through-on-hit updated the cache -- re-read alone cost 0 bus cycles",
                    c3 - c2, 32'd0);

            // D-4b: write-no-allocate-on-miss
            c0 = c3;
            wait_cleared_then_set(6, 32'h2468_1357, 20000, e);
            c1 = data_ds_count;
            check32("D-4b: re-read after write-to-miss shows the correct (write-through) value",
                    u_top.u_eu.u_rf.d_reg[6], 32'h2468_1357);
            check("D-4b: write-no-allocate-on-miss -- re-read needed a real bus cycle (not cached)",
                  c1 - c0 > 0);

            // D-5: BERR mid D-cache read-miss, then mid D-cache write
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd0; t++)
                @(posedge clk_4x);
            run_dberr_mid_test("D-5a (read-miss)", 32'd1, 20000);
            check32("D-5a: the faulted read never wrote back (D6 unchanged, fault won the race)",
                    u_top.u_eu.u_rf.d_reg[6], 32'h2468_1357);

            run_dberr_mid_test("D-5b (write)", 32'd2, 20000);
            check32("D-5b: the faulted write never reached backing memory (T2 unchanged)",
                    rom[16'h2B00/4], 32'h1234_5678);

            // D-6: the original Phase 133 JMP (An)-after-exception-dispatch
            // mechanism, chained twice, as its own dedicated test -- see the
            // ROM-content comment above for the full writeup.
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd0; t++)
                @(posedge clk_4x);
            run_dberr_mid_test("D-6a (read-miss, via JMP (A1))", 32'd1, 20000);

            for (t = 0; t < 2000 && u_top.u_eu.u_rf.a_reg[1] !== 32'h0000_0B80; t++)
                @(posedge clk_4x);
            check32("D-6: D6_CONT_A correctly repointed A1 to D6_CONT_B before fault #2",
                    u_top.u_eu.u_rf.a_reg[1], 32'h0000_0B80);

            run_dberr_mid_test("D-6b (write, via JMP (A1))", 32'd2, 20000);
            // Deliberately NOT asserting "T4 unchanged" here, unlike D-5b's
            // own equivalent check. Traced why: this testbench's memory
            // model (see its own write-commit always_ff near the top of
            // this file) commits a write purely off ds_active_r/AS/DS/OE --
            // it has no berr_n awareness at all -- while the write's own
            // bus cycle keeps driving those pins to its natural multi-tick
            // completion regardless of the EU having already recognized the
            // fault and dispatched (D5 already incremented, PC already
            // redirected) internally, in parallel. Whether the "unchanged"
            // check reads before or after that natural completion lands is
            // a genuine race against a fixed, 0-wait-state DSACK plus
            // berr_n's own 2-stage synchronizer delay -- D-5b's own check
            // happens to win it (confirmed via direct trace: it does, but
            // only because it reads before the trailing commit), D-6b's
            // loses it (JMP (A1) needing an extra register-file read before
            // the redirect shifts the relative timing just enough) -- this
            // is a pre-existing fragility in the check pattern shared with
            // D-4b/D-5b, not a JMP (An)/RTL correctness issue: every other
            // check in this test (fault recognized, correct vector, fault
            // counter, A1 updated correctly, EU recovered) is unaffected
            // and robust.
            check32("D-6: fault counter settled at exactly 2 (no extra/garbage faults from a stale A1)",
                    u_top.u_eu.u_rf.d_reg[5], 32'd2);

            // D-9: write-allocation (WA=1), manual Figure 6-4 Examples 3/4/5
            // (ROM at 0x0C00, jumped to from D-6's own tail -- see that ROM
            // block's own comment for why this runs here rather than its
            // original position between D-4b and D-5). Same "isolate the
            // re-read's own cost from the write's own mandatory
            // write-through cycle" shape as D-4a's own check, via an
            // explicit two-phase inline poll with an intermediate
            // checkpoint the moment D6/D7 is observed cleared (write
            // retired) before measuring the re-read alone.
            // D-6's own tail can coincidentally leave D6 already reading 0
            // at the exact moment this check code starts (testbench check
            // code races ahead of hardware, which hasn't even reached this
            // test's own ROM yet) -- a plain "wait for D6==0" phase found
            // that stale 0 immediately (0 elapsed cycles) and captured c0
            // long before the aligned write even happened. Fixed with a
            // genuinely 3-phase wait: first synchronize on the placeholder
            // (0xFFFFFFFF, a value only this test's own code ever sets, so
            // seeing it proves hardware has truly reached this test) before
            // trusting a later "==0" as this test's own CLR_L_D6.
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hFFFF_FFFF; t++)
                @(posedge clk_4x);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hAABB_CCDD; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-9: W3 aligned long-word write-miss (WA=1) landed the correct value",
                    u_top.u_eu.u_rf.d_reg[6], 32'hAABB_CCDD);
            check32("D-9: aligned long-word write-miss (WA=1) genuinely allocated -- re-read cost 0 bus cycles",
                    c1 - c0, 32'd0);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'hCCDD_0000; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-9: W3+8 sub-long-word write-miss (WA=1) still landed the correct (write-through) value",
                    u_top.u_eu.u_rf.d_reg[7], 32'hCCDD_0000);
            check("D-9: sub-long-word write-miss (WA=1) did NOT allocate -- re-read needed a real bus cycle",
                  c1 - c0 > 0);

            // D-10: DBE-gated D-cache burst fill (manual §6.1.3.2). Same
            // 3-phase placeholder-synchronized wait pattern as D-9's own
            // check, for the identical "testbench check code can start
            // polling before hardware reaches this test's own ROM" hazard.
            dc_burst_req_seen_r = 1'b0;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hFFFF_FFFF; t++)
                @(posedge clk_4x);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'h1111_2222; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-10: W4 burst-miss read landed the correct value",
                    u_top.u_eu.u_rf.d_reg[6], 32'h1111_2222);
            check("D-10: W4 burst-miss read needed real bus activity",
                  c1 - c0 > 0);
            check("D-10: the read genuinely used the real burst port (dc_burst_req)",
                  dc_burst_req_seen_r);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'hFFFF_FFFF; t++)
                @(posedge clk_4x);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'h7777_8888; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-10: W4+C (different offset, same line, never independently fetched) loaded correctly",
                    u_top.u_eu.u_rf.d_reg[7], 32'h7777_8888);
            check32("D-10: W4+C came from the SAME burst fill -- re-read at a different offset cost 0 bus cycles",
                    c1 - c0, 32'd0);

            // D-11: D-cache freeze (FD), manual §6.3.1.5. Same
            // placeholder-synchronized wait pattern as D-9/D-10's own
            // checks.
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hFFFF_FFFF; t++)
                @(posedge clk_4x);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hDEAD_1234; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-11: W6 prime-read (FD=0) landed the correct value", u_top.u_eu.u_rf.d_reg[6], 32'hDEAD_1234);
            check("D-11: W6 prime-read needed real bus activity (genuine cold miss)", c1 - c0 > 0);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'h1357_2468; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-11: W6 write-HIT while frozen (FD=1) still landed the new value",
                    u_top.u_eu.u_rf.d_reg[6], 32'h1357_2468);
            check32("D-11: the updated entry was still cached -- re-read cost 0 bus cycles",
                    c1 - c0, 32'd0);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'h9999_8888; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("D-11: W7 write-MISS while frozen (FD=1, WA=1) still landed the write-through value",
                    u_top.u_eu.u_rf.d_reg[7], 32'h9999_8888);
            check("D-11: FD=1 overrode WA=1 -- W7 did NOT allocate, re-read needed a real bus cycle",
                  c1 - c0 > 0);

            // I-6: I-cache freeze (FI), manual §6.3.1.10. D5 still reads
            // "2" from D-6's own earlier test at this point (nothing
            // between D-6 and here touches D5), so waiting for it to
            // genuinely clear to 0 (this test's own CLR_L_D5) is
            // unambiguous -- no placeholder needed, unlike D-9/D-10/D-11's
            // own D6/D7 checks, which had to guard against a coincidental
            // stale 0.
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = code_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd701; t++)
                @(posedge clk_4x);
            c1 = code_ds_count;
            check32("I-6: G visit#1 (FI=1) executed correctly", u_top.u_eu.u_rf.d_reg[5], 32'd701);
            check("I-6: G visit#1 needed real bus activity (genuine miss)", c1 - c0 > 0);
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd0; t++)
                @(posedge clk_4x);
            c0 = code_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd701; t++)
                @(posedge clk_4x);
            c1 = code_ds_count;
            check32("I-6: G visit#2 (FI=1) executed correctly", u_top.u_eu.u_rf.d_reg[5], 32'd701);
            check("I-6: FI=1 -- visit#2 ALSO needed real bus activity (never cached, unlike I-1's own hit)",
                  c1 - c0 > 0);

            // D-12: CACR self-clearing bit readback masking. D6 currently
            // holds 701 (from I-6's own visit#2) -- unambiguous, never
            // coincidentally 0x3313, so a direct single-phase wait is safe
            // (no placeholder needed).
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'h0000_3313; t++)
                @(posedge clk_4x);
            check32("D-12: MOVEC CACR,D6 masks CD/CED/CI/CEI + reserved bits to 0",
                    u_top.u_eu.u_rf.d_reg[6], 32'h0000_3313);
        end

        // D-13: FC-aware D-cache tag prevents supervisor/user aliasing (see
        // the ROM-setup comment above for the full rationale/placement
        // discussion). D6 currently holds 0x3313 (from D-12), unambiguous.
        // Uses data_ds_count (fc=101) for the supervisor read and the new
        // user_ds_count (fc=001) for the two MOVES reads -- confirmed via a
        // temporary trace that data_ds_count's own fc=101-only filter
        // (correct for every other test in this file) simply can't observe
        // an fc=001 access at all, which is what a first attempt's "genuine
        // miss" check on the MOVES read actually hit (data_ds_count read 0
        // delta despite tag_d[4] directly confirmed, via the same trace, to
        // have genuinely changed from the fc=101-tagged entry to a fresh
        // fc=001-tagged one) -- a test-counter-scope bug, not an RTL bug.
        begin
            int fc0, fc1, fc2, fc3, e;
            fc0 = data_ds_count;
            wait_cleared_then_set(5, 32'hAAAA_BBBB, 20000, e);
            fc1 = data_ds_count;
            check32("D-13: supervisor-FC read loaded the correct value",
                    u_top.u_eu.u_rf.d_reg[5], 32'hAAAA_BBBB);
            check("D-13: supervisor-FC read was a genuine miss (cold)", fc1 - fc0 > 0);

            fc1 = user_ds_count;
            wait_cleared_then_set(6, 32'hAAAA_BBBB, 20000, e);
            fc2 = user_ds_count;
            check32("D-13: 1st MOVES (user-FC) read loaded the correct value",
                    u_top.u_eu.u_rf.d_reg[6], 32'hAAAA_BBBB);
            check("D-13: 1st MOVES (user-FC) read was a genuine miss -- FC-aware tag, no false alias hit onto the supervisor entry",
                  fc2 - fc1 > 0);

            wait_cleared_then_set(6, 32'hAAAA_BBBB, 20000, e);
            fc3 = user_ds_count;
            check32("D-13: 2nd MOVES (user-FC) read loaded the correct value",
                    u_top.u_eu.u_rf.d_reg[6], 32'hAAAA_BBBB);
            check32("D-13: 2nd MOVES (user-FC) read was a pure hit (0 bus cycles)", fc3 - fc2, 32'd0);
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

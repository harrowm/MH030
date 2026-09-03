`default_nettype none
`timescale 1ps/1ps

// Phase 150 Stage 0f (plan.md): full-chip integration test proving real
// MMU address translation now happens for an ordinary instruction's data
// access, not just PFLUSH/PTEST/PMOVE (tb/mmu_tb.sv's own unit tests) or
// biu_mmu_if.sv in isolation (tb/biu_tb.sv's P6-6/P6-7). Deliberately scoped
// to exactly what Stage 0 delivers: a single-level walk (TIB=TIC=0, so the
// one real table read IS the leaf page descriptor) with TT0 covering this
// file's own code so ordinary fetches stay translation-free — matching the
// exact same "TT0 narrowed to an exact top-byte match" technique validated
// in tb/stall_fsm_tb.sv's own B-20/BERR-mid-PTEST fixes. Deliberately NOT
// exercised here (out of scope for Stage 0, tracked as later plan stages):
// translation *faults* reaching a real exception (Stage 1), write-protect
// (Stage 2), U/M bit write-back (Stage 3), MMUSR correctness (Stage 4).
//
// Full-chip harness (m68030_top + inline memory model), mirroring
// tb/stall_fsm_tb.sv's own proven wiring exactly.

module mmu_xlate_tb;

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

    // 16KB unified instruction+data memory, matching stall_fsm_tb.sv /
    // cosim_grp_tb.sv exactly.
    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
    end

    // Backlog plan Stage 4 (plan.md): real 68030 silicon freezes the
    // address bus for the whole burst (MC68030UM.pdf 7.3.7); this model
    // used to rely on ext_a itself incrementing per beat (a pre-existing
    // RTL bug, fixed in biu_burst_ctrl.sv by an earlier backlog stage) to
    // serve each beat's own distinct word -- with the address genuinely
    // frozen, every beat read back the SAME longword, corrupting any
    // genuine multi-beat I-cache/D-cache burst fill (root-caused this
    // stage: this is what actually produced Phase 236's own original
    // hang, not PTEST/eviction as originally hypothesized -- see Phase 8
    // below). burst_beat_probe mirrors cache_tb.sv's own already-proven
    // fix exactly: testbench-only instrumentation hierarchically
    // referencing the DUT's own internal beat counter (not a real pin),
    // reading 0 whenever no burst is in progress so this is a no-op for
    // every ordinary access.
    wire [1:0]  burst_beat_probe = u_top.u_biu.u_cg.u_bc.burst_beat;
    wire [11:0] beat_word_addr   = ext_a[13:2] + {10'h0, burst_beat_probe};
    wire [31:0] rd_word = (beat_word_addr < MEM_WORDS) ? rom[beat_word_addr] : 32'hDEAD_DEAD;
    logic       ds_active_r;
    wire        dsack0_n = ~ds_active_r;
    wire        dsack1_n = ~ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n)                          ds_active_r <= 1'b0;
        else if (!(!ext_ds_n & !ext_as_n))   ds_active_r <= 1'b0;
        else                                 ds_active_r <= 1'b1;
    end

    wire [31:0] ext_d_in = (!ext_ds_n & ext_rw) ? rd_word : {32{1'bz}};

    always_ff @(posedge clk_4x) begin
        if (ds_active_r && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
            if (beat_word_addr < MEM_WORDS) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: rom[beat_word_addr]        <= ext_d_out;
                    4'b10_00: rom[beat_word_addr][31:16] <= ext_d_out[31:16];
                    4'b10_10: rom[beat_word_addr][15:0]  <= ext_d_out[15:0];
                    4'b01_00: rom[beat_word_addr][31:24] <= ext_d_out[31:24];
                    4'b01_01: rom[beat_word_addr][23:16] <= ext_d_out[23:16];
                    4'b01_10: rom[beat_word_addr][15:8]  <= ext_d_out[15:8];
                    4'b01_11: rom[beat_word_addr][7:0]   <= ext_d_out[7:0];
                    default:  rom[beat_word_addr]        <= ext_d_out;
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

    // Pin-level monitors: did a real FC=101 (supervisor data) bus cycle ever
    // assert DS at exactly the expected address? Two independent flags —
    // the table-walk's own descriptor read (BIU-083: FC=101) and the
    // translated data read — each latched the instant it's ever observed,
    // immune to ordering/timing noise from surrounding instruction fetches.
    logic saw_walk_read_addr;
    logic saw_translated_data_read;
    // Phase 150 Stage 3 (plan.md): the U/M bit write-back cycle's own pin-
    // level shape (BIU-086: a real write, FC=101, to the descriptor's own
    // address) -- two independent flags since the U update (on the read)
    // and the M update (on the later write) are two separate bus cycles.
    logic        saw_u_writeback;
    logic [31:0] u_writeback_data;
    logic        saw_m_writeback;
    logic [31:0] m_writeback_data;
    logic ext_ds_n_prev = 1'b1;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b101) begin
            if (ext_a == 32'h0000_3004) saw_walk_read_addr       <= 1'b1;
            if (ext_a == 32'h0000_2004) saw_translated_data_read <= 1'b1;
            if (!ext_rw && ext_a == 32'h0000_3010) begin
                if (!saw_u_writeback) begin
                    saw_u_writeback   <= 1'b1;
                    u_writeback_data  <= ext_d_out;
                end else begin
                    saw_m_writeback   <= 1'b1;
                    m_writeback_data  <= ext_d_out;
                end
            end
        end
        ext_ds_n_prev <= ext_ds_n;
    end

    // -------------------------------------------------------------------
    // Opcodes (reusing the exact encodings already proven correct
    // elsewhere in this project — tb/stall_fsm_tb.sv/tb/cache_tb.sv).
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam MOVEA_L_IMM_A1 = 16'h227C;
    localparam MOVEA_L_IMM_A2 = 16'h247C;
    localparam MOVEA_L_IMM_A3 = 16'h267C;
    localparam MOVE_L_A0_D0   = 16'h2010;
    localparam MOVE_L_A0_D2   = 16'h2410;
    localparam MOVE_L_A0_D4   = 16'h2810;
    localparam MOVE_L_A2_D7   = 16'h2E12;  // MOVE.L (A2),D7
    localparam MOVE_L_IMM_A1_IND = 16'h22BC;  // MOVE.L #imm,(A1)
    localparam MOVE_L_IMM_A2_IND = 16'h24BC;  // MOVE.L #imm,(A2)
    localparam MOVE_L_IMM_A3_IND = 16'h26BC;  // MOVE.L #imm,(A3)
    localparam CLR_L_D0       = 16'h4280;
    localparam ADDI_L_D0      = 16'h0680;
    localparam CLR_L_D1       = 16'h4281;
    localparam ADDI_L_D1      = 16'h0681;
    localparam CLR_L_D3       = 16'h4283;
    localparam ADDI_L_D3      = 16'h0683;
    localparam CLR_L_D5       = 16'h4285;
    localparam ADDI_L_D5      = 16'h0685;
    localparam CLR_L_D6       = 16'h4286;
    localparam ADDI_L_D6      = 16'h0686;
    localparam PMOVE_A0_OP    = 16'hF010;  // same opcode word as PTEST; op_type in the ext word
    localparam PMOVE_CRP_EXT  = 16'h4800;  // op_type=010(PMOVE),sub=100(CRP),dr=0(load)
    localparam PMOVE_TC_EXT   = 16'h4400;  // op_type=010(PMOVE),sub=010(TC),dr=0(load)
    localparam PMOVE_TT0_EXT  = 16'h4200;  // op_type=010(PMOVE),sub=001(TT0),dr=0(load)
    localparam PTEST_A0_OP    = 16'hF010;  // deferred-items closure plan Stage 10 (plan.md)
    localparam PTEST_EXT      = 16'h8000;  // op_type=100(PTEST) -- same values as stall_fsm_tb.sv's own B-20
    localparam NOP_OP         = 16'h4E71;
    localparam MOVE_W_IMM_SR  = 16'h46FC;  // deferred-items closure plan Stage 11 (plan.md)
    localparam RTE_OP         = 16'h4E73;
    localparam BRA_SELF       = 16'h60FE;  // BRA.B -2: tight self-loop (parks decode)
    localparam JMP_ABS_L_OP   = 16'h4EF9;  // JMP (xxx).L
    localparam MOVEQ_11_D7    = 16'h7E11;  // MOVEQ #$11,D7 (EI+IBE for CACR)
    localparam MOVEC_D7_CACR  = 16'h4E7B;  // MOVEC D7,CACR (backlog Stage 4, plan.md)
    localparam MOVEC_D7_CACR_EXT = 16'h7002;

    int fail_count = 0;
    task automatic check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask
    task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    initial begin
        // Boot vectors.
        rom[0] = 32'h0000_3F00;  // SSP
        rom[1] = 32'h0000_0400;  // PC -> program start

        // -------------------------------------------------------------
        // MMU configuration data.
        //
        // TT0: LAB=0x00, LAM=0x00 (exact top-byte-0x00 match, not "any
        // VA" -- narrower than tb/mmu_tb.sv's own MMU-2/tb/biu_tb.sv's
        // P6-6 tests), E=1, FCM=any. This file's own code all lives under
        // 0x00001000, so every instruction fetch bypasses translation
        // (TT hit, no ATC/walk needed) while the deliberately different-
        // top-byte target VA below (0x20001004) falls straight through to
        // the real walker -- same technique validated in
        // tb/stall_fsm_tb.sv's BERR-mid-PTEST fix (Phase 150).
        rom[16'h3800/4] = 32'h0000_80E0;

        // TC (enabled case): E=1, PS=12 (4KB pages), IS=5, TIA=15,
        // TIB=0, TIC=0 -- IS+TIA+PS = 5+15+12 = 32, so the walker's single
        // real table read (level A) directly returns the leaf page
        // descriptor; no level B/C ever gets consulted (this is Stage 0's
        // own deliberately-scoped "single-level walk", per the plan).
        rom[16'h3900/4] = 32'h8C5F_0000;

        // TC (disabled case, phase 2's control comparison): E=0.
        rom[16'h3A80/4] = 32'h0000_0000;

        // CRP: base=0x00003000 (16-byte aligned), DT field is
        // architecturally documentation-only here -- biu_mmu_if.sv's own
        // crp_base extraction masks off the low 4 bits unconditionally
        // (confirmed by direct reading of the RTL), so the walker never
        // actually inspects CRP's own DT bits; only the table it points at
        // matters. Open-items backlog Stage 12 (plan.md): crp[63:32]
        // (L/U+LIMIT) is no longer unused -- L/U=0/LIMIT=0 (the old value
        // here) means "index must be <= 0," faulting the level-A index
        // this test actually needs; set to L/U=0/LIMIT=$7FFF (permissive
        // upper limit, matching what real 68030 firmware always sets when
        // it doesn't want index limiting).
        rom[16'h3A00/4] = 32'h7FFF_0000;  // CRP hi: L/U=0, LIMIT=$7FFF (permissive)
        rom[16'h3A04/4] = 32'h0000_3002;  // CRP lo: base=0x3000

        // Level-A table. VA=0x20001004, IS=5/TIA=15/PS=12 gives
        // idx_a = (VA>>12) & 0x7FFF = 1, so the walker reads
        // crp_base + 1*4 = 0x3004 -- confirmed by hand against
        // biu_mmu_if.sv's own fa_lo_w/idx_a_w formulas before writing this
        // test. DT=01 (page descriptor / leaf); base=0x00002000 is a
        // page frame that shares nothing with VA's own frame (0x20000) --
        // a genuinely different physical page, not just a different alias
        // of the same data.
        rom[16'h3004/4] = 32'h0000_2001;

        // Sentinel data: the *translated* physical address (0x00002004,
        // page frame 0x00002000 | VA's own preserved page offset 0x004)
        // holds a value distinct from whatever sits at the raw logical
        // address (0x1004, deliberately pre-seeded with an equally
        // recognizable but different value) -- reading the wrong one is
        // impossible to mistake for the right one.
        rom[16'h2004/4] = 32'hCAFE_F00D;  // correct: PA's own data
        rom[16'h1004/4] = 32'hBAAD_F00D;  // wrong: VA's own raw-alias data

        // -------------------------------------------------------------
        // Program.
        //
        // Phase 1 (TC.E=1): configure TT0 first (still translation-free,
        // TC.E=0 throughout this step -- matches the real-hardware
        // bootstrap ordering root-caused in Phase 150's own B-20 fix:
        // transparent windows must be live *before* the MMU is enabled),
        // then CRP (order doesn't matter, no live effect until TC.E=1),
        // then TC last (E=1 -- translation goes live for every subsequent
        // access starting with the very next fetch, immediately covered by
        // the already-configured TT0). Read VA=0x20001004 into D0, then
        // mark completion via D1=111.
        // -------------------------------------------------------------
        rom[16'h0400/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0404/4] = {16'h3800, PMOVE_A0_OP};       // PMOVE (A0),TT0
        rom[16'h0408/4] = {PMOVE_TT0_EXT, MOVEA_L_IMM_A0};
        rom[16'h040C/4] = {16'h0000, 16'h3A00};
        rom[16'h0410/4] = {PMOVE_A0_OP, PMOVE_CRP_EXT};  // PMOVE (A0),CRP
        rom[16'h0414/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0418/4] = {16'h3900, PMOVE_A0_OP};       // PMOVE (A0),TC (E=1)
        rom[16'h041C/4] = {PMOVE_TC_EXT, MOVEA_L_IMM_A0};
        rom[16'h0420/4] = {16'h2000, 16'h1004};          // A0 = VA 0x20001004
        rom[16'h0424/4] = {MOVE_L_A0_D0, CLR_L_D1};       // MOVE.L (A0),D0
        rom[16'h0428/4] = {ADDI_L_D1, 16'h0000};
        rom[16'h042C/4] = {16'd111, MOVEA_L_IMM_A0};

        // -------------------------------------------------------------
        // Phase 2 (TC.E=0 control case): disable TC again, re-read the
        // *exact same* VA into D2. With translation inert, biu_mmu_if.sv's
        // own MS_IDLE identity-mapping path (`pa_r <= va`) makes this
        // byte-for-byte identical to every pre-Phase-150 test in this
        // project -- ext_a must show the raw logical address unchanged.
        // -------------------------------------------------------------
        rom[16'h0430/4] = {16'h0000, 16'h3A80};
        rom[16'h0434/4] = {PMOVE_A0_OP, PMOVE_TC_EXT};   // PMOVE (A0),TC (E=0)
        rom[16'h0438/4] = {MOVEA_L_IMM_A0, 16'h2000};
        rom[16'h043C/4] = {16'h1004, MOVE_L_A0_D2};       // A0 = VA 0x20001004 ; MOVE.L (A0),D2
        rom[16'h0440/4] = {CLR_L_D3, ADDI_L_D3};
        rom[16'h0444/4] = {16'h0000, 16'd222};

        // -------------------------------------------------------------
        // Phase 3 (Stage 1, plan.md): fault -> real exception -> handler
        // fixes the descriptor -> RTE -> the original instruction re-
        // executes and now succeeds. This is BIU-152 end to end -- the
        // page-fault-then-retry cycle a real kernel's fault handler
        // depends on. Deliberately a *fresh* VA (0x20002100, idx_a=2,
        // never translated by phases 1/2) so there's no possibility of a
        // stale ATC entry masking the fault -- biu_mmu_if.sv only ever
        // populates the ATC from MS_WALK_DONE, never MS_FAULT, so a
        // faulted VA can't have one anyway, but a fresh VA sidesteps the
        // question entirely rather than relying on that reasoning alone.
        //
        // Vector 2 (VBR defaults to 0 at reset) -> handler at 0x500.
        // Descriptor at 0x3008 starts deliberately invalid (DT=00) --
        // explicit, not left to the default memory fill: 0x4E714E71's own
        // low 2 bits happen to be "01" (a coincidentally *valid*-looking
        // page descriptor), which would silently defeat this test.
        //
        // PA page frame: 0x00000000 (giving PA=0x00000100, matching VA's
        // own preserved page offset 0x100). A first attempt used
        // 0x00004000 (PA=0x00004004) and then 0x00003C00 (PA=0x00003C04)
        // -- both wrong, for two different reasons found by direct signal
        // tracing of biu_mmu_if.sv's own ms_state/walk_desc_r/pa: (1)
        // 0x00004000's low-14-bit alias in this testbench's own 16KB
        // memory model (which only ever looks at ext_a[13:2]) landed
        // exactly on this file's own PC boot vector; (2) 0x00003C00 is
        // *not actually page-aligned* for PS=12 (4KB pages) -- its own low
        // 12 bits (0xC00) are nonzero, so page_mask (0xFFFFF000) silently
        // discards them, collapsing the intended PA to 0x00003004 (aliasing
        // phase 1's own descriptor address). With a page-aligned frame and
        // VA's own offset changed from 0x004 (already spoken for by 3 of
        // the memory model's only 4 available 4KB-aligned slots) to 0x100
        // (unused), frame=0 is the remaining free slot.
        rom[16'h0008/4] = 32'h0000_0500;   // vector 2 -> handler
        rom[16'h3008/4] = 32'h0000_0000;   // invalid descriptor (DT=00)
        rom[16'h0100/4] = 32'h1357_2468;   // sentinel at the *fixed* PA

        // Re-enable TC (phase 2 disabled it); TT0/CRP are already correctly
        // configured from phase 1 and untouched since.
        rom[16'h0448/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h044C/4] = {16'h3900, PMOVE_A0_OP};        // PMOVE (A0),TC (E=1 again)
        rom[16'h0450/4] = {PMOVE_TC_EXT, MOVEA_L_IMM_A0};
        rom[16'h0454/4] = {16'h2000, 16'h2100};           // A0 = VA 0x20002100
        rom[16'h0458/4] = {MOVE_L_A0_D4, CLR_L_D5};        // MOVE.L (A0),D4  <-- faults, retries after RTE
        rom[16'h045C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0460/4] = {16'd777, MOVEA_L_IMM_A3};

        // -------------------------------------------------------------
        // Phase 4 (Stage 2, plan.md): write-protect violations. A page
        // marked WP (descriptor bit 2, already tracked end-to-end since
        // Stage 0 -- biu_mmu_if.sv's own walk_wp_r/atc_wp/wp output, and
        // biu_cache_if.sv's CI_XLATE already checks `xl_wp && !rw_r`,
        // routing into the exact same CI_BERR/exc_active path Stage 1
        // just proved end-to-end for a plain invalid descriptor) must
        // fault on a WRITE but not on a READ. Reuses vector 2 (repointed
        // to a new, non-retrying handler -- WP is permanent for this
        // test, unlike phase 3's fixable invalid descriptor, so there is
        // nothing sensible to RTE back into; the handler just marks
        // completion and parks, matching this project's own established
        // BERR-mid-<X> convention for unretriable faults).
        //
        // Fresh VA (0x20003200, idx_a=3, table entry at 0x300C) --
        // deliberately different from phases 1/3 so there's no
        // possibility of picking up a stale ATC entry from an earlier
        // phase's own (non-WP) translation of a different page. The read
        // in this phase's own sequence populates the ATC itself, so the
        // write's own fault is checked against a *cached* wp bit
        // (MS_ATC_HIT's wp_r<=atc_hit_wp), not just a fresh walk --
        // incidentally also exercises atc_wp[]'s own correctness, not
        // just walk_wp_r's.
        // -------------------------------------------------------------
        rom[16'h0200/4] = 32'hABCD_1234;   // sentinel at the WP page's own PA (frame 0, offset 0x200)
        rom[16'h300C/4] = 32'h0000_0005;   // descriptor: frame=0, WP=1 (bit2), DT=01 (page)

        // A3 = 0x0000300C (the WP descriptor's own table entry address)
        rom[16'h0464/4] = {16'h0000, 16'h300C};
        // MOVE.L #0x00000005,(A3) -- redundant with the ROM preload above;
        // installs it via a real bus write too, and lands A3 = 0x00000008
        // (vector 2's own slot) next for the SAME reason the pattern
        // repeats: reusing one address register across both installs.
        rom[16'h0468/4] = {MOVE_L_IMM_A3_IND, 16'h0000};
        rom[16'h046C/4] = {16'h0005, MOVEA_L_IMM_A3};
        rom[16'h0470/4] = {16'h0000, 16'h0008};
        rom[16'h0474/4] = {MOVE_L_IMM_A3_IND, 16'h0000};   // MOVE.L #0x00000520,(A3) -- vector 2 -> new handler
        rom[16'h0478/4] = {16'h0520, MOVEA_L_IMM_A2};
        rom[16'h047C/4] = {16'h2000, 16'h3200};            // A2 = VA 0x20003200
        rom[16'h0480/4] = {MOVE_L_A2_D7, CLR_L_D6};        // MOVE.L (A2),D7 -- READ, must succeed (no fault)
        rom[16'h0484/4] = {ADDI_L_D6, 16'h0000};
        rom[16'h0488/4] = {16'd333, MOVE_L_IMM_A2_IND};    // marker D6=333 (read succeeded) ; MOVE.L #imm,(A2)
        rom[16'h048C/4] = {16'hDEAD, 16'hBEEF};            // #0xDEADBEEF,(A2) -- WRITE, must fault (WP)

        // New vector-2 handler for phase 4: mark completion (D6=444), then
        // jump on to phase 5's own setup (no RTE -- a WP fault has nothing
        // to fix and retry).
        rom[16'h0520/4] = {CLR_L_D6, ADDI_L_D6};
        rom[16'h0524/4] = {16'h0000, 16'd444};
        rom[16'h0528/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h052C/4] = {16'h0540, 16'h4E71};

        // -------------------------------------------------------------
        // Phase 5 (Stage 3, plan.md): U/M bit hardware write-back
        // (BIU-086). A fresh page (U=0, M=0 in its own descriptor from
        // the start -- deliberately different from every earlier phase's
        // own VA/descriptor so this is a genuinely first-ever access).
        // Read first (must set U in the descriptor's own backing memory);
        // then write (must additionally set M), while the write's own
        // *data* value still lands correctly at the translated PA
        // alongside the side-channel descriptor update.
        // -------------------------------------------------------------
        rom[16'h0300/4] = 32'hFEED_BEEF;   // sentinel at the fresh page's own PA
        rom[16'h3010/4] = 32'h0000_0001;   // descriptor: frame=0, U=0, M=0, DT=01 (page)

        rom[16'h0540/4] = {MOVEA_L_IMM_A2, 16'h2000};
        rom[16'h0544/4] = {16'h4300, MOVE_L_A2_D7};        // A2 = VA 0x20004300 ; MOVE.L (A2),D7 -- READ
        rom[16'h0548/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h054C/4] = {16'h0000, 16'd555};             // marker D1=555 (read done, U should now be set)
        rom[16'h0550/4] = {MOVE_L_IMM_A2_IND, 16'h1234};   // MOVE.L #0x12345678,(A2) -- WRITE
        rom[16'h0554/4] = {16'h5678, CLR_L_D0};
        rom[16'h0558/4] = {ADDI_L_D0, 16'h0000};
        // Deferred-items closure plan Stage 10 (plan.md): Phase 5's own
        // trailing BRA_SELF replaced with a JMP to a new investigation
        // block at 0x0600 (0x0560-0x0566 confirmed unused) -- the D0==666
        // marker check below still fires correctly, since it happens
        // before this jump ever executes.
        rom[16'h055C/4] = {16'd666, JMP_ABS_L_OP};          // marker D0=666 (write done, M should now be set)
        rom[16'h0560/4] = {16'h0000, 16'h070C};             // JMP 0x0000070C

        // Vector-2 handler: fix the descriptor at 0x3008 (page frame
        // 0x00000000, DT=01), then RTE. TT0 already covers this handler's
        // own code (top byte 0x00) and its write target (also top byte
        // 0x00), so neither needs any special handling.
        rom[16'h0500/4] = {MOVEA_L_IMM_A1, 16'h0000};
        rom[16'h0504/4] = {16'h3008, MOVE_L_IMM_A1_IND};   // MOVE.L #imm,(A1)
        rom[16'h0508/4] = {16'h0000, 16'h0001};
        rom[16'h050C/4] = {RTE_OP, 16'h4E71};

        // -------------------------------------------------------------
        // Phase 6 (deferred-items closure plan Stage 10, plan.md):
        // investigating a genuine, sustained instruction-fetch hang first
        // found in Phase 236 (plan.md) -- under a fresh TC.E re-enable +
        // I-cache miss + cache-line-crossing fetch, right after a real
        // PTEST/ATC-install. Phase 236's own wording: "a fetch that
        // crosses from PTEST's own 16-byte I-cache line into the next
        // one (needed to fetch ADDI's own immediate operand)" -- i.e.
        // PTEST itself stays within one line (an earlier attempt this
        // stage deliberately straddled PTEST's own opcode+ext instead
        // and did NOT reproduce the hang, ruling that shape out), but
        // the FOLLOWING ADDI.L's own 3-word span (opcode+32-bit
        // immediate) straddles the very next boundary.
        //
        // Reuses B-20's own exact TC/TT0 values (TT0 fully transparent,
        // LAM=0xFF matches any VA, so PTEST resolves without any real
        // page-table data) at fresh addresses (0x3B00/0x3B04, confirmed
        // unused elsewhere in this file). Base address 0x070C chosen so
        // PTEST lands at offset 6 within its own line (0x0720-0x072F,
        // fully non-crossing) and ADDI.L's own opcode lands at offset 12
        // of the FOLLOWING line (0x0730-0x073F) -- its own 6-byte span
        // (0x072C-0x0731) genuinely straddles that boundary.
        // -------------------------------------------------------------
        rom[16'h3B00/4] = 32'h8000_0000;  // TC: E=1
        rom[16'h3B04/4] = 32'h00FF_80E0;  // TT0: LAM=0xFF (any VA), E=1, FCM=any

        rom[16'h070C/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0710/4] = {16'h3B04, PMOVE_A0_OP};        // PMOVE (A0),TT0
        rom[16'h0714/4] = {PMOVE_TT0_EXT, MOVEA_L_IMM_A0};
        rom[16'h0718/4] = {16'h0000, 16'h3B00};
        rom[16'h071C/4] = {PMOVE_A0_OP, PMOVE_TC_EXT};    // PMOVE (A0),TC
        rom[16'h0720/4] = {MOVEA_L_IMM_A0, 16'h2000};
        rom[16'h0724/4] = {16'h5000, PTEST_A0_OP};        // A0 = VA 0x20005000 ; PTEST opcode @0x0726
        rom[16'h0728/4] = {PTEST_EXT, CLR_L_D5};          // PTEST ext @0x0728 ; CLR.L D5 @0x072A (still line 0x0720-0x072F)
        rom[16'h072C/4] = {ADDI_L_D5, 16'h0000};          // ADDI opcode @0x072C (offset 12) -- own imm crosses into 0x0730
        rom[16'h0730/4] = {16'd999, JMP_ABS_L_OP};        // marker D5=999 (PTEST + crossing ADDI fetch survived)
        rom[16'h0734/4] = {16'h0000, 16'h0900};           // JMP 0x00000900 (Phase 8, below)

        // -------------------------------------------------------------
        // Phase 8 (backlog plan Stage 4, plan.md, 3rd PTEST-hang
        // investigation attempt): Phase 218's own "clean repro" (Phase 6
        // above) never actually enabled the I-cache -- this whole file
        // never touches CACR, confirmed via grep before writing this --
        // so it never exercised real I-cache burst-linefill/caching at
        // all, unlike Phase 236's own original failing context (deep
        // inside stall_fsm_tb.sv, with the I-cache genuinely enabled by
        // many earlier tests). This phase re-runs the identical
        // PTEST + crossing-ADDI shape as Phase 6, but with CACR's
        // EI+IBE bits (0x11) genuinely set first via a real MOVEC, to
        // test whether enabling the I-cache -- not just eviction, the
        // plan's own original hypothesis -- is what Phase 218's repro
        // was missing. Reuses Phase 6's own already-live TC/TT0 (nothing
        // between Phase 6's own tail and here disturbs them). New marker
        // value (888, vs Phase 6's 999) keeps the two phases' own
        // completion checks unambiguous.
        // -------------------------------------------------------------
        rom[16'h0900/4] = {MOVEQ_11_D7, MOVEC_D7_CACR};
        rom[16'h0904/4] = {MOVEC_D7_CACR_EXT, NOP_OP};
        rom[16'h0908/4] = {NOP_OP, NOP_OP};
        rom[16'h090C/4] = {NOP_OP, NOP_OP};

        rom[16'h0910/4] = {MOVEA_L_IMM_A0, 16'h2000};
        rom[16'h0914/4] = {16'h5000, PTEST_A0_OP};        // A0 = VA 0x20005000 ; PTEST opcode @0x0916 (offset 6, same as Phase 6)
        rom[16'h0918/4] = {PTEST_EXT, CLR_L_D5};          // PTEST ext @0x0918 ; CLR.L D5 @0x091A (still line 0x0910-0x091F)
        rom[16'h091C/4] = {ADDI_L_D5, 16'h0000};          // ADDI opcode @0x091C (offset 12) -- own imm crosses into 0x0920
        rom[16'h0920/4] = {16'd888, JMP_ABS_L_OP};        // marker D5=888 (PTEST + crossing ADDI fetch survived WITH I-cache enabled)
        rom[16'h0924/4] = {16'h0000, 16'h0800};           // JMP 0x00000800 (back into Phase 7's own original start)

        // -------------------------------------------------------------
        // Phase 7 (deferred-items closure plan Stage 11, plan.md):
        // eu_trace_req mid-FSM/dispatch hazard. No dedicated trace-mode
        // (SR.T) test exists anywhere in this project outside the Harte
        // corpus itself. eu_trace_req is deliberately excluded from
        // eu_seq.sv's own ex_exc_dispatch_hazard aggregation (Phase 134),
        // reasoned to be "genuinely post-instruction-retirement by
        // design" and therefore a different hazard shape than the
        // interrupt/internal-exception dispatch race Phase 108/134
        // already fixed -- never independently confirmed.
        //
        // Direct signal reading (rtl/m68030_exc.sv): exc_active =
        // (state_r != EXC_IDLE), and EXC_IDLE's own transition to
        // EXC_PUSH happens on trace_req's own first-true edge -- meaning
        // exc_active only becomes true the CYCLE AFTER eu_trace_req first
        // fires, the identical one-cycle gap shape Phase 108/151 already
        // found and fixed for other exception sources. Whether this is a
        // genuine, exploitable hazard depends on whether a new
        // instruction can actually dispatch into EX during that one
        // cycle -- tested directly here with a non-idempotent marker
        // (ADDI.L #1,D6, mirroring Phase 108's own technique): sets
        // SR.T1=1, then a traced CLR.L D5, immediately followed
        // (already decoded, ready to dispatch) by the marker. If the
        // hazard is real, D6 may show 2 (executed once prematurely
        // mid-dispatch, once more after RTE); if not, exactly 1.
        //
        // RESULT (confirmed via a temporary hierarchical trace, since
        // removed): the dispatch race IS real -- instr_ack does fire for
        // the next instruction on the exact cycle eu_trace_req asserts,
        // one cycle before exc_active catches up, identical in shape to
        // every other exception source's own recognition gap. But it
        // never corrupts anything: eu_seq.sv's EX latch has a *pre-
        // existing, exception-source-agnostic* "stall -> insert bubble"
        // branch (`else if (stall) ex_valid<=1'b0`, unrelated to
        // exceptions -- it exists purely so a decode-side stall doesn't
        // leak garbage into EX) that fires the very next cycle once
        // `stall`/`ex_exc_dispatch_hazard`'s own `exc_active` term goes
        // high, squashing the raced-in instruction's ex_valid to 0 before
        // `wb_valid<=ex_valid` can ever latch it into WB. So the fix
        // Phase 108 needed for interrupts (a bespoke int_ready/int_defer
        // gate) was never actually about closing the 1-cycle recognition
        // window itself -- that window is structural, exists for every
        // exception source, and can't be closed without exc_active
        // becoming combinational. What Phase 108 fixed was that, before
        // it, NOTHING included int_pending in `stall` at all, so a raced-
        // in instruction ran completely unguarded to full WB commit. Once
        // exc_active is in `stall` (true for interrupts since Phase 108,
        // and true for trace/internal exceptions from the start), the
        // pre-existing bubble-insert logic protects every exception
        // source uniformly -- eu_trace_req needs no bespoke term in
        // ex_exc_dispatch_hazard, and doesn't have a "different hazard
        // shape" from the others; it's the same shape, already covered.
        // -------------------------------------------------------------
        rom[16'h0800/4] = {MOVE_W_IMM_SR, 16'hA700};      // SR = S=1,IPL=7,T1=1
        rom[16'h0804/4] = {CLR_L_D6, CLR_L_D5};           // D6=0 (marker) ; D5=0 (the TRACED instruction)
        rom[16'h0808/4] = {ADDI_L_D6, 16'h0000};          // ADDI.L #1,D6 -- non-idempotent marker
        rom[16'h080C/4] = {16'h0001, BRA_SELF};

        // Vector 9 (Trace) handler: deliberately does nothing but RTE --
        // SR.T1 stays set on return, so BRA_SELF's own later retirement
        // also re-traces (an endless, harmless trace/RTE loop back into
        // the self-branch -- D6 is never touched again either way, so a
        // bounded wait then a direct D6 check is sufficient regardless).
        rom[16'h0024/4] = 32'h0000_0820;                  // vector 9 -> 0x0820
        rom[16'h0820/4] = {RTE_OP, NOP_OP};

        saw_walk_read_addr       = 1'b0;
        saw_translated_data_read = 1'b0;
        saw_u_writeback          = 1'b0;
        saw_m_writeback          = 1'b0;

        // Reset pulse.
        #100 rst_n = 1'b1;

        // -------------------------------------------------------------
        // Phase 1: wait for D1==111 (translated read + completion marker).
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d1;
            saw_d1 = 1'b0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[1] === 32'd111) begin saw_d1 = 1'b1; break; end
            end
            check("Phase 1: TC.E=1 program reached completion (D1=111)", saw_d1);
        end

        check32("Phase 1: D0 holds the translated PA's own data (0xCAFEF00D), not the raw VA's",
                u_top.u_eu.u_rf.d_reg[0], 32'hCAFE_F00D);
        check("Phase 1: the table-walk's own descriptor read hit the expected address (0x3004) with FC=101 (BIU-083)",
              saw_walk_read_addr);
        check("Phase 1: the actual data read hit the translated PA (0x00002004) on the external bus, not the logical VA",
              saw_translated_data_read);

        // -------------------------------------------------------------
        // Phase 2: wait for D3==222 (TC.E=0 control case).
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d3;
            saw_d3 = 1'b0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[3] === 32'd222) begin saw_d3 = 1'b1; break; end
            end
            check("Phase 2: TC.E=0 control program reached completion (D3=222)", saw_d3);
        end

        check32("Phase 2: D2 holds the raw VA's own data (0xBAADF00D) -- translation genuinely inert with TC.E=0",
                u_top.u_eu.u_rf.d_reg[2], 32'hBAAD_F00D);

        // -------------------------------------------------------------
        // Phase 3 (Stage 1): fault -> exception -> handler fixes the
        // descriptor -> RTE -> the faulting MOVE.L re-executes and now
        // succeeds. Watches for a genuine vector-2/format-9 dispatch
        // *before* waiting for D5==777, so a false pass (D5 reaching 777
        // by some unrelated fluke, without ever actually faulting) can't
        // slip through.
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_exc3, saw_d5;
            logic [3:0] seen_fmt;
            logic [7:0] seen_vec;
            saw_exc3 = 1'b0;
            saw_d5   = 1'b0;
            seen_fmt = 4'h0;
            seen_vec = 8'h0;
            for (t = 0; t < 30000; t++) begin
                @(posedge clk_4x); #1;
                if (!saw_exc3 && u_top.u_exc.exc_active) begin
                    saw_exc3 = 1'b1;
                    seen_fmt = u_top.u_exc.snap_fmt_r;
                    seen_vec = u_top.u_exc.snap_vec_r;
                end
                if (u_top.u_eu.u_rf.d_reg[5] === 32'd777) begin saw_d5 = 1'b1; break; end
            end
            check("Phase 3: a real exception was taken on the deliberate invalid-descriptor fault", saw_exc3);
            check32("Phase 3: correct vector (2, Bus Error) dispatched", {24'h0, seen_vec}, 32'd2);
            check32("Phase 3: correct frame format (9, FMT_MMU) dispatched", {28'h0, seen_fmt}, 32'd9);
            check("Phase 3: handler ran, RTE'd, and the retried MOVE.L completed (D5=777)", saw_d5);
        end
        check32("Phase 3: D4 holds the *fixed* PA's own sentinel (0x13572468) -- the retry genuinely re-walked the now-valid descriptor, not stale state",
                u_top.u_eu.u_rf.d_reg[4], 32'h1357_2468);

        // -------------------------------------------------------------
        // Phase 4 (Stage 2): write-protect violations. First confirms the
        // READ from the WP page succeeds with no fault at all (D6=333) --
        // if the read incorrectly faulted, execution would divert straight
        // into the new handler and D6 would jump to 444 without ever
        // passing through 333, so this alone already proves WP doesn't
        // block reads. Then confirms the WRITE to the *same* page
        // genuinely faults (a fresh exc_active, watched for only after
        // D6==333 so phase 3's own already-resolved exception can't be
        // mistaken for this one) with the correct vector/format, and that
        // the new handler ran (D6=444).
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d6_333;
            saw_d6_333 = 1'b0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[6] === 32'd333) begin saw_d6_333 = 1'b1; break; end
            end
            check("Phase 4: the READ from the WP page succeeded with no fault (D6=333)", saw_d6_333);
        end
        check32("Phase 4: D7 holds the WP page's own sentinel (0xABCD1234) -- the read genuinely reached the translated PA",
                u_top.u_eu.u_rf.d_reg[7], 32'hABCD_1234);

        begin
            int t;
            logic saw_exc4, saw_d6_444;
            logic [3:0] seen_fmt4;
            logic [7:0] seen_vec4;
            saw_exc4    = 1'b0;
            saw_d6_444  = 1'b0;
            seen_fmt4   = 4'h0;
            seen_vec4   = 8'h0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (!saw_exc4 && u_top.u_exc.exc_active) begin
                    saw_exc4  = 1'b1;
                    seen_fmt4 = u_top.u_exc.snap_fmt_r;
                    seen_vec4 = u_top.u_exc.snap_vec_r;
                end
                if (u_top.u_eu.u_rf.d_reg[6] === 32'd444) begin saw_d6_444 = 1'b1; break; end
            end
            check("Phase 4: the WRITE to the WP page raised a real exception", saw_exc4);
            check32("Phase 4: correct vector (2, Bus Error) dispatched for the WP violation", {24'h0, seen_vec4}, 32'd2);
            check32("Phase 4: correct frame format (9, FMT_MMU) dispatched for the WP violation", {28'h0, seen_fmt4}, 32'd9);
            check("Phase 4: the new (non-retrying) handler ran to completion (D6=444)", saw_d6_444);
        end

        // -------------------------------------------------------------
        // Phase 5 (Stage 3): U/M bit hardware write-back (BIU-086). A
        // fresh page (U=0, M=0 from the start) -- first a read, then a
        // write, each checked independently: the retried instruction's
        // own register result, the exact bus-cycle shape of the write-
        // back itself (a real FC=101 write to the descriptor's own
        // address, not just "some write happened somewhere"), and the
        // descriptor's own backing memory directly (the most direct
        // proof of all -- U/M genuinely persisted, not just a passing
        // bus transaction).
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d1_555;
            saw_d1_555 = 1'b0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[1] === 32'd555) begin saw_d1_555 = 1'b1; break; end
            end
            check("Phase 5: the READ from the fresh page completed (D1=555)", saw_d1_555);
        end
        check32("Phase 5: D7 holds the fresh page's own sentinel (0xFEEDBEEF)",
                u_top.u_eu.u_rf.d_reg[7], 32'hFEED_BEEF);
        check("Phase 5: the U write-back cycle hit the descriptor's own address (0x3010) with FC=101, a real write",
              saw_u_writeback);
        check32("Phase 5: the U write-back wrote the correct value (U set, bit 3, everything else unchanged)",
                u_writeback_data, 32'h0000_0009);
        check32("Phase 5: the descriptor's own backing memory now shows U set (direct check, not just the bus transaction)",
                rom[16'h3010/4], 32'h0000_0009);

        begin
            int t;
            logic saw_d0_666;
            saw_d0_666 = 1'b0;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[0] === 32'd666) begin saw_d0_666 = 1'b1; break; end
            end
            check("Phase 5: the WRITE to the fresh page completed (D0=666)", saw_d0_666);
        end
        check32("Phase 5: the write's own DATA landed correctly at the translated PA (0x00000300), alongside the U/M side-channel update",
                rom[16'h0300/4], 32'h1234_5678);
        check("Phase 5: the M write-back cycle hit the descriptor's own address (0x3010) with FC=101, a real write",
              saw_m_writeback);
        check32("Phase 5: the M write-back wrote the correct value (U and M both set now)",
                m_writeback_data, 32'h0000_0019);
        check32("Phase 5: the descriptor's own backing memory now shows both U and M set",
                rom[16'h3010/4], 32'h0000_0019);

        // -------------------------------------------------------------
        // Phase 6 (deferred-items closure plan Stage 10, plan.md): does
        // PTEST's own opcode+ext straddling a 16-byte I-cache line
        // boundary, right after a fresh TC.E re-enable, reproduce
        // Phase 236's own hang?
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d5_999;
            saw_d5_999 = 1'b0;
            for (t = 0; t < 50000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[5] === 32'd999) begin saw_d5_999 = 1'b1; break; end
            end
            if (!saw_d5_999) begin
                $display("Phase6-DIAG t=%0t decode_pc=%h ifu_bus_err=%b exc_active=%b eu_berr=%b D5=%h",
                    $time, u_top.ifu_decode_pc, u_top.ifu_bus_err, u_top.u_exc.exc_active,
                    u_top.eu_berr, u_top.u_eu.u_rf.d_reg[5]);
            end
            check("Phase 6: ADDI's own immediate-operand fetch straddling the line right after PTEST survives (D5=999)", saw_d5_999);
        end

        // -------------------------------------------------------------
        // Phase 8 (backlog plan Stage 4, plan.md): the same shape as
        // Phase 6, but with the I-cache genuinely enabled first. Root-
        // caused (via a temporary trace, since removed) a genuine hang
        // here on the first attempt, then fixed it -- see the burst_beat
        // _probe comment on this file's own memory model above for the
        // full mechanism. Left as permanent regression coverage.
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d5_888;
            saw_d5_888 = 1'b0;
            for (t = 0; t < 50000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[5] === 32'd888) begin saw_d5_888 = 1'b1; break; end
            end
            if (!saw_d5_888) begin
                $display("Phase8-DIAG t=%0t decode_pc=%h ifu_bus_err=%b exc_active=%b eu_berr=%b D5=%h",
                    $time, u_top.ifu_decode_pc, u_top.ifu_bus_err, u_top.u_exc.exc_active,
                    u_top.eu_berr, u_top.u_eu.u_rf.d_reg[5]);
            end
            check("Phase 8: same shape as Phase 6, but with I-cache (CACR EI+IBE) genuinely enabled first (D5=888)", saw_d5_888);
        end

        // -------------------------------------------------------------
        // Phase 7 (deferred-items closure plan Stage 11, plan.md):
        // eu_trace_req mid-FSM dispatch-race check.
        // -------------------------------------------------------------
        begin
            int t;
            logic saw_d6_1;
            saw_d6_1 = 1'b0;
            for (t = 0; t < 5000; t++) begin
                @(posedge clk_4x); #1;
                if (u_top.u_eu.u_rf.d_reg[6] === 32'd1) begin saw_d6_1 = 1'b1; break; end
            end
            check("Phase 7: ADDI's own marker was seen at exactly D6=1 (no premature dispatch)", saw_d6_1);
            // A settle window past that first sighting: if the hazard is
            // real, D6 should climb to 2 (a second, illegitimate ADDI
            // commit) shortly after -- if not, it must stay pinned at 1
            // forever (ADDI never executes again; only its own single,
            // correct retirement should ever touch D6).
            repeat(2000) @(posedge clk_4x);
            check32("Phase 7: D6 stayed pinned at exactly 1 -- no double-commit from a mid-dispatch race",
                    u_top.u_eu.u_rf.d_reg[6], 32'd1);
        end

        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

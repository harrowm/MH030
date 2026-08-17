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

    // 16KB unified instruction+data memory, matching stall_fsm_tb.sv /
    // cosim_grp_tb.sv exactly.
    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
    end

    wire [31:0] rd_word = (ext_a[13:2] < MEM_WORDS) ? rom[ext_a[13:2]] : 32'hDEAD_DEAD;
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

    // Pin-level monitors: did a real FC=101 (supervisor data) bus cycle ever
    // assert DS at exactly the expected address? Two independent flags —
    // the table-walk's own descriptor read (BIU-083: FC=101) and the
    // translated data read — each latched the instant it's ever observed,
    // immune to ordering/timing noise from surrounding instruction fetches.
    logic saw_walk_read_addr;
    logic saw_translated_data_read;
    logic ext_ds_n_prev = 1'b1;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b101) begin
            if (ext_a == 32'h0000_3004) saw_walk_read_addr       <= 1'b1;
            if (ext_a == 32'h0000_2004) saw_translated_data_read <= 1'b1;
        end
        ext_ds_n_prev <= ext_ds_n;
    end

    // -------------------------------------------------------------------
    // Opcodes (reusing the exact encodings already proven correct
    // elsewhere in this project — tb/stall_fsm_tb.sv/tb/cache_tb.sv).
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam MOVE_L_A0_D0   = 16'h2010;
    localparam MOVE_L_A0_D2   = 16'h2410;
    localparam CLR_L_D1       = 16'h4281;
    localparam ADDI_L_D1      = 16'h0681;
    localparam CLR_L_D3       = 16'h4283;
    localparam ADDI_L_D3      = 16'h0683;
    localparam PMOVE_A0_OP    = 16'hF010;  // same opcode word as PTEST; op_type in the ext word
    localparam PMOVE_CRP_EXT  = 16'h4800;  // op_type=010(PMOVE),sub=100(CRP),dr=0(load)
    localparam PMOVE_TC_EXT   = 16'h4400;  // op_type=010(PMOVE),sub=010(TC),dr=0(load)
    localparam PMOVE_TT0_EXT  = 16'h4200;  // op_type=010(PMOVE),sub=001(TT0),dr=0(load)
    localparam BRA_SELF       = 16'h60FE;  // BRA.B -2: tight self-loop (parks decode)

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
        // matters. crp[63:32] (limit) is unused by this simplified model.
        rom[16'h3A00/4] = 32'h0000_0000;  // CRP hi (limit, unused)
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
        rom[16'h0448/4] = {BRA_SELF, 16'h4E71};

        saw_walk_read_addr       = 1'b0;
        saw_translated_data_read = 1'b0;

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

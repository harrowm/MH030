`default_nettype none
`timescale 1ps/1ps

// Pipeline stall/hazard test suite — Category B (multi-cycle FSM decode
// holdoff), per plan.md's "Pipeline Stall/Hazard Test Suite". Tom Harte's
// SingleStepTests corpus is structurally single-instruction, so it has
// already exhaustively verified every one of these FSM instructions'
// *functional* correctness (see plan.md Phases 90-102) — but every one of
// those tests' "next instruction" is a STOP runway, never real code. This
// file's job is different: verify decode stays correctly held off for each
// FSM's *entire* duration on the real, full m68030_top + external bus, and
// that a genuinely unrelated dependent instruction placed immediately after
// it decodes and executes correctly once the FSM finishes — the thing
// Harte's single-instruction structure cannot reach.
//
// Full-chip harness (m68030_top + inline memory model), mirroring
// cosim_grp_tb.sv's proven wiring exactly (fixed 1-cycle-latency DSACK,
// same byte-lane write-back case statement) rather than the lighter
// IFU+SEQ+EU-only harness used for Category A/E — these are genuinely
// multi-bus-cycle instructions, so the real BIU/arbiter path matters here.
//
// Scope: a representative cross-section of the ~23 ex_mem_stall sources
// inventoried in plan.md, not the full set — TAS (single-instruction RMW
// lock), MOVEM (multi-beat register-list transfer), CMPM (2-phase register-
// pair read+compare), and BCHG (generic memory-RMW, the shape shared by
// most of ORI/ANDI/ADDQ/Scc/shift-memory/etc.). These span the distinct
// stall mechanisms without hand-encoding all 23 by hand, which carries a
// meaningfully higher opcode-encoding-error risk for the ones needing
// MMU/coprocessor setup (PFLUSH/PTEST/PMOVE64) or multi-phase addressing
// (CAS2) — left for a follow-up phase per plan.md's "rows can land
// incrementally" delivery note.

module stall_fsm_tb;

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

    // 16KB unified instruction+data memory, matching cosim_grp_tb.sv.
    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
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
        .cback_n      (cback_n)
    );

    // -------------------------------------------------------------------
    // Instruction encodings
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam MOVEA_L_IMM_A1 = 16'h227C;
    localparam TAS_A0         = 16'h4AD0;  // TAS (A0)
    localparam MOVEM_L_A0P    = 16'h4CD8;  // MOVEM.L (A0)+,<mask ext word>
    localparam CMPM_B_A0P_A1P = 16'hB109;  // CMPM.B (A0)+,(A1)+
    localparam BCHG_D2_A0     = 16'h0550;  // BCHG D2,(A0)
    localparam CLR_L_D2       = 16'h4282;
    localparam CLR_L_D3       = 16'h4283;
    localparam CLR_L_D4       = 16'h4284;
    localparam ADDI_L_D2      = 16'h0682;
    localparam ADDI_L_D3      = 16'h0683;
    localparam ADDI_L_D4      = 16'h0684;
    localparam NOP_OP         = 16'h4E71;

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
    task automatic check8(input string name, input logic [7:0] got, input logic [7:0] exp);
        if (got === exp) $display("PASS  %s (got %02h)", name, got);
        else begin $display("FAIL  %s: got %02h exp %02h", name, got, exp); fail_count++; end
    endtask

    // Jumps PC to base_addr by forcibly patching the EU's PC register
    // (there is no direct pc_wr_en port at the m68030_top level — the real
    // chip only ever moves PC via reset/exception/branch — so each test
    // case is instead reached by falling through from the previous one;
    // see the sequential layout below), then polls up to `budget` cycles
    // for the dependent register to reach its expected value.
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

    initial begin
        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Boot vector: m68030_top fetches initial SSP/PC from addresses
        // 0x0/0x4 on reset (same convention as cosim_grp_tb.sv/smoke.s).
        // SSP = 0x3F00 (well clear of every data/code region below); PC =
        // 0x0100 (first test case; test case boundaries below are chosen so
        // each one falls straight through into the next, avoiding needing
        // a branch instruction — which would reintroduce Category E's own
        // redirect mechanics into what should be a pure FSM-holdoff test).
        rom[0] = 32'h0000_3F00;
        rom[1] = 32'h0000_0100;

        // -----------------------------------------------------------------
        // B-1: TAS (A0) — single-instruction indivisible RMW lock.
        // -----------------------------------------------------------------
        // 0x0100: MOVEA.L #0x2000,A0 ; TAS (A0)
        rom[16'h0100/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0104/4] = {16'h2000, TAS_A0};
        // 0x0108: CLR.L D2 ; ADDI.L #111,D2 (unrelated dependent instr)
        rom[16'h0108/4] = {CLR_L_D2, ADDI_L_D2};
        rom[16'h010C/4] = {16'h0000, 16'd111};
        // rom[0x2000] left at its default fill (0x4E71_4E71); TAS
        // unconditionally sets bit7 of the addressed byte (the top byte,
        // 0x4E -> 0xCE) regardless of the tested value.

        // -----------------------------------------------------------------
        // B-2: MOVEM.L (A0)+,D0-D1 — multi-beat register-list load.
        // -----------------------------------------------------------------
        // 0x0200: MOVEA.L #0x2100,A0 ; MOVEM.L (A0)+,D0/D1
        rom[16'h0200/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0204/4] = {16'h2100, MOVEM_L_A0P};
        // 0x0208: mask ext word (D0,D1) ; CLR.L D2
        rom[16'h0208/4] = {16'h0003, CLR_L_D2};
        // 0x020C: ADDI.L #222,D2 (unrelated dependent instr)
        rom[16'h020C/4] = {ADDI_L_D2, 16'h0000};
        rom[16'h0210/4] = {16'd222, NOP_OP};
        // Source data for the two beats.
        rom[16'h2100/4] = 32'h1111_1111;
        rom[16'h2104/4] = 32'h2222_2222;

        // -----------------------------------------------------------------
        // B-3: CMPM.B (A0)+,(A1)+ — 2-phase register-pair read+compare.
        // -----------------------------------------------------------------
        // 0x0300: MOVEA.L #0x2200,A0 ; MOVEA.L #0x2200,A1
        rom[16'h0300/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0304/4] = {16'h2200, MOVEA_L_IMM_A1};
        rom[16'h0308/4] = {16'h0000, 16'h2200};
        // 0x030C: CMPM.B (A0)+,(A1)+ ; CLR.L D3
        rom[16'h030C/4] = {CMPM_B_A0P_A1P, CLR_L_D3};
        // 0x0310: ADDI.L #333,D3 (unrelated dependent instr)
        rom[16'h0310/4] = {ADDI_L_D3, 16'h0000};
        rom[16'h0314/4] = {16'd333, NOP_OP};

        // -----------------------------------------------------------------
        // B-4: BCHG D2,(A0) — generic memory-RMW representative (the same
        // decode shape as ORI/ANDI/ADDQ/Scc/memory-shift/NBCD/etc.).
        // -----------------------------------------------------------------
        // 0x0400: MOVEA.L #0x2300,A0 ; CLR.L D2
        rom[16'h0400/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0404/4] = {16'h2300, CLR_L_D2};
        // 0x0408: ADDI.L #3,D2 (bit position 3)
        rom[16'h0408/4] = {ADDI_L_D2, 16'h0000};
        rom[16'h040C/4] = {16'd3, BCHG_D2_A0};
        // 0x0410: CLR.L D4 ; ADDI.L #444,D4 (unrelated dependent instr)
        rom[16'h0410/4] = {CLR_L_D4, ADDI_L_D4};
        rom[16'h0414/4] = {16'h0000, 16'd444};
        // rom[0x2300] left at default fill (0x4E71_4E71); top byte 0x4E =
        // 0b0100_1110 already has bit3 set, so BCHG clears it -> 0x46.

        // ----- run to completion, checking each case in turn -----
        run_and_check("B-1: TAS dependent instr ran (D2=111)", 2, 32'd111, 3000);
        check8("B-1: TAS set bit7 of tested byte", rom[16'h2000/4][31:24], 8'hCE);

        run_and_check("B-2: MOVEM dependent instr ran (D2=222)", 2, 32'd222, 3000);
        check32("B-2: MOVEM D0 loaded", u_top.u_eu.u_rf.d_reg[0], 32'h1111_1111);
        check32("B-2: MOVEM D1 loaded", u_top.u_eu.u_rf.d_reg[1], 32'h2222_2222);
        check32("B-2: MOVEM A0 post-increment (2 beats)", u_top.u_eu.u_rf.a_reg[0], 32'h0000_2108);

        run_and_check("B-3: CMPM dependent instr ran (D3=333)", 3, 32'd333, 3000);

        run_and_check("B-4: BCHG dependent instr ran (D4=444)", 4, 32'd444, 3000);
        check8("B-4: BCHG toggled bit3 of tested byte", rom[16'h2300/4][31:24], 8'h46);

        check("No address errors", ~(eu_addr_err | ifu_addr_err));

        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

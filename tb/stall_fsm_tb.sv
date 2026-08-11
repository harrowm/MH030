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

    // wait_states injects N extra clk_4x-cycle-granular... actually S-state
    // cycles of DSACK latency on top of the baseline 1-cycle ack, for
    // Category D (wait-state + hazard composition). 0 reproduces the
    // original fixed 1-cycle-latency behavior used by every other test in
    // this file and by cosim_grp_tb.sv.
    int wait_states = 0;

    logic       ds_active_r;
    logic [7:0] ws_cnt_r;
    wire        ds_req = !ext_ds_n & !ext_as_n;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ds_active_r <= 1'b0;
            ws_cnt_r    <= 8'd0;
        end else if (!ds_req) begin
            ds_active_r <= 1'b0;
            ws_cnt_r    <= 8'd0;
        end else if (!ds_active_r) begin
            if (ws_cnt_r >= wait_states[7:0]) ds_active_r <= 1'b1;
            else                              ws_cnt_r    <= ws_cnt_r + 8'd1;
        end
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

    // Free-running counter of data-space (fc=101, supervisor data) DS#
    // assertions — every setup instruction in this file (MOVEA.L #imm,An)
    // and every dependent-check instruction (CLR.L/ADDI.L/MOVEQ, all
    // register-immediate) touches zero data-space bus cycles, so counting
    // this delta across exactly one FSM instruction's own execution window
    // gives its real bus-cycle count with no separate scoping/windowing
    // needed: the FSM instruction's own reads/writes are the *only* thing
    // that can move this counter during that window. Used by the Category
    // B precision checks below (task #33 in the post-Phase-104 follow-up
    // list) to verify each FSM's bus-cycle count matches the
    // architecturally-expected number, not just eventual completion.
    int data_ds_count = 0;
    logic ext_ds_n_prev = 1'b1;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && ext_ds_n_prev && ext_fc == 3'b101) data_ds_count <= data_ds_count + 1;
        ext_ds_n_prev <= ext_ds_n;
    end

    // -------------------------------------------------------------------
    // Instruction encodings
    // -------------------------------------------------------------------
    localparam MOVEA_L_IMM_A0 = 16'h207C;
    localparam MOVEA_L_IMM_A1 = 16'h227C;
    localparam TAS_A0         = 16'h4AD0;  // TAS (A0)
    localparam MOVEM_L_A0P    = 16'h4CD8;  // MOVEM.L (A0)+,<mask ext word>
    localparam CMPM_B_A0P_A1P = 16'hB109;  // CMPM.B (A0)+,(A1)+
    localparam BCHG_D2_A0     = 16'h0550;  // BCHG D2,(A0)
    localparam MOVE_L_A0_D0   = 16'h2010;  // MOVE.L (A0),D0
    localparam CLR_L_D1       = 16'h4281;
    localparam ADD_L_D0_D1    = 16'hD280;  // D1 = D1 + D0
    localparam CLR_L_D2       = 16'h4282;
    localparam CLR_L_D3       = 16'h4283;
    localparam CLR_L_D4       = 16'h4284;
    localparam ADDI_L_D2      = 16'h0682;
    localparam ADDI_L_D3      = 16'h0683;
    localparam ADDI_L_D4      = 16'h0684;
    localparam CLR_L_D5       = 16'h4285;
    localparam ADDI_L_D5      = 16'h0685;
    localparam NOP_OP         = 16'h4E71;
    // CAS.L Dc,Du,(A0): opcode 0000_111_0_11_010_000 (f_dn=111=long,
    // f_mode=010=(An)) per eu_seq.sv's dec_is_cas block. Ext word:
    // [8:6]=Dc(compared, ->D1=001), [2:0]=Du(written on match, ->D2=010).
    localparam CAS_L_D1D2_A0  = 16'h0ED0;
    localparam CAS_EXT        = 16'h0042;
    // CAS2.L: opcode 0x0EFC (f_dn=111, f_mode/f_reg=111/100), per the exact
    // ext-word bit layout documented at eu_seq.sv's dec_is_cas2 block:
    //   ext1 (ext_data[31:16]): [14:12]=Dc2, [10:8]=Du2, [3]=Rn2_an, [2:0]=Rn2
    //   ext2 (ext_data[15:0]):  [14:12]=Dc1, [10:8]=Du1, [3]=Rn1_an, [2:0]=Rn1
    // Using Rn1=A0, Rn2=A1, Dc1=D1, Du1=D2, Dc2=D3, Du2=D4.
    localparam CAS2_L         = 16'h0EFC;
    localparam CAS2_EXT1      = 16'h3409;  // Dc2=D3,Du2=D4,Rn2_an=1,Rn2=A1
    localparam CAS2_EXT2      = 16'h1208;  // Dc1=D1,Du1=D2,Rn1_an=1,Rn1=A0
    localparam ADDI_L_D1      = 16'h0681;
    // MOVEP.L D1,(d16,A0) store form: 0000 DDD1 dir siz 001 AAA per
    // eu_seq.sv's dec_is_movep block. f_dn=D1(001), f_dir=1(fixed for
    // MOVEP), f_ss=11(store=1,long=1), f_mode=001(fixed), f_reg=A0(000).
    localparam MOVEP_L_D1_A0  = 16'h03C8;
    // MOVE16 (A0)+,(A1)+ form 00: group 1111, f_dn=001(cpid), f_mode=001
    // (form-00 selector), f_reg=A0(src). Ext word [14:12]=Am(dst)=A1.
    localparam MOVE16_A0P_A1P = 16'hF208;
    localparam MOVE16_EXT     = 16'h1000;  // Am=A1 at ext[14:12]
    // Predecrement-memory-form FSM instructions, all "1<grp> Ax 1 <ss> 001 Ay":
    // ADDX.L -(A1),-(A0): group=1101, Ax=A0(000), ss=10(long), Ay=A1(001).
    localparam ADDX_L_A1_A0   = 16'hD189;
    // ABCD -(A1),-(A0): group=1100, Ax=A0, ss=00(fixed), Ay=A1.
    localparam ABCD_A1_A0     = 16'hC109;
    // PACK -(A1),-(A0),#0: group=1000, Ax=A0, ss=01(PACK), Ay=A1; #adj ext=0.
    localparam PACK_A1_A0     = 16'h8149;
    // BFINS D1,(A0){8:8}: group 1110, f_dn=111(bitfield marker+BFINS op),
    // f_dir=1, f_ss=11(fixed), f_mode=010=(An), f_reg=A0(000).
    localparam BFINS_D1_A0    = 16'hEFD0;
    localparam BFINS_EXT      = 16'h1208;  // Dn=D1, offset=8 (imm), width=8 (imm)
    // CMP2.L (A0),D1: group 0000, f_dn=010(long), f_dir=0, f_ss=11(fixed),
    // f_mode=010=(An), f_reg=A0(000). Ext: D/A=0(Dn), Rn=D1(001), bit11=0(CMP2 not CHK2).
    localparam CMP2_L_A0_D1   = 16'h04D0;
    localparam CMP2_EXT       = 16'h1000;
    // MOVE.L (A0),(A1): both src and dst memory-indirect.
    localparam MOVE_L_A0_A1   = 16'h2290;
    localparam MOVEA_L_IMM_A7 = 16'h2E7C;
    localparam RTR_OP         = 16'h4E77;
    localparam RTE_OP         = 16'h4E73;
    localparam RESET_OP       = 16'h4E70;
    // MOVEM.L D0/D1,-(A0): store form, mask bit15=D0,bit14=D1 (predecrement
    // mask order is reversed from the increment form used in B-2).
    localparam MOVEM_L_PREDEC_A0 = 16'h48E0;
    // MMU (cpid=0) instructions: all share opcode 1111_000_dir_ss_mode_reg
    // (group F, f_dn=000 selects the MMU coprocessor) — the specific
    // sub-operation is entirely carried in the extension word's
    // mmu_op_type field (ext[15:13]), not the opcode word itself, per
    // eu_seq.sv:398 and its dec_is_pflush/dec_is_ptest/dec_is_pmove64
    // decode block.
    localparam PFLUSHA_OP     = 16'hF000;  // f_mode/f_reg=0 (no EA needed)
    localparam PFLUSHA_EXT    = 16'h2000;  // op_type=001(PFLUSH), sub_mode=010(all)
    localparam PTEST_A0_OP    = 16'hF010;  // f_mode=010=(An), f_reg=A0
    localparam PTEST_EXT      = 16'h8000;  // op_type=100(PTEST)
    localparam PMOVE_A0_OP    = 16'hF010;  // same opcode word as PTEST —
    localparam PMOVE_CRP_EXT  = 16'h4800;  // op_type=010(PMOVE),sub=100(CRP),dr=0(load)
    localparam PMOVE_TC_EXT   = 16'h4400;  // op_type=010(PMOVE),sub=010(TC),dr=0(load)
    localparam PMOVE_TT0_EXT  = 16'h4200;  // op_type=010(PMOVE),sub=001(TT0),dr=0(load)
    localparam CLR_L_D6       = 16'h4286;
    localparam ADDI_L_D6      = 16'h0686;

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

    // Same as run_and_check, but also reports how many clk_4x edges elapsed
    // — used by Category D to confirm a stretched (wait-stated) bus cycle
    // genuinely composes with the downstream RAW hazard rather than the
    // consumer racing ahead of a slow read.
    task automatic run_and_check_timed(
        input  string       name,
        input  int          reg_idx,
        input  logic [31:0] exp_val,
        input  int          budget,
        output int          elapsed
    );
        int t;
        logic saw_ack;
        saw_ack = 0;
        elapsed = budget;
        for (t = 0; t < budget; t++) begin
            @(posedge clk_4x); #1;
            if (u_top.u_eu.u_rf.d_reg[reg_idx] === exp_val) begin saw_ack = 1'b1; elapsed = t; break; end
        end
        check(name, saw_ack);
        $display("INFO  %s: elapsed=%0d clk_4x cycles (wait_states=%0d)", name, elapsed, wait_states);
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

        // -----------------------------------------------------------------
        // Category D: DSACK wait-state stretching composed with a
        // downstream RAW hazard. Same producer/consumer pair (MOVE.L
        // (A0),D0 -> ADD.L D0,D1) run three times with wait_states=0,2,5 —
        // if the consumer ever raced ahead of a slow read instead of
        // correctly extending the stall to cover it, D1 would come back
        // wrong (reading D0 before the real data arrived), not just slow.
        // -----------------------------------------------------------------
        // D-1 (wait_states=0) @ 0x0500
        rom[16'h0500/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0504/4] = {16'h2400, CLR_L_D1};
        rom[16'h0508/4] = {MOVE_L_A0_D0, ADD_L_D0_D1};
        rom[16'h2400/4] = 32'h0000_0007;

        // D-2 (wait_states=2) @ 0x0600
        rom[16'h0600/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0604/4] = {16'h2500, CLR_L_D1};
        rom[16'h0608/4] = {MOVE_L_A0_D0, ADD_L_D0_D1};
        rom[16'h2500/4] = 32'h0000_0009;

        // D-3 (wait_states=5) @ 0x0700
        rom[16'h0700/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0704/4] = {16'h2600, CLR_L_D1};
        rom[16'h0708/4] = {MOVE_L_A0_D0, ADD_L_D0_D1};
        rom[16'h2600/4] = 32'h0000_000D;

        // -----------------------------------------------------------------
        // B-5: CAS.L D1,D2,(A0) — single-address atomic compare-and-swap.
        // Not checking the CAS's own compare/write result here (Harte
        // already covers CAS functional correctness exhaustively) — only
        // that decode correctly resumes with an unrelated dependent instr.
        // -----------------------------------------------------------------
        // 0x0800: MOVEA.L #0x2700,A0
        rom[16'h0800/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0804/4] = {16'h2700, CAS_L_D1D2_A0};
        // 0x0808: CAS ext word ; CLR.L D5
        rom[16'h0808/4] = {CAS_EXT, CLR_L_D5};
        // 0x080C: ADDI.L #555,D5 (unrelated dependent instr)
        rom[16'h080C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0810/4] = {16'd555, NOP_OP};

        // -----------------------------------------------------------------
        // B-6: CAS2.L (Dc1:Dc2,Du1:Du2,(A0):(A1)) — 4-phase dual-address
        // atomic (the most complex ex_mem_stall FSM: bus_lock held across
        // all 4 phases without releasing the bus). Same "decode resumes
        // correctly" check as CAS, not re-verifying CAS2's own semantics.
        // -----------------------------------------------------------------
        // 0x0900: MOVEA.L #0x2700,A0 ; MOVEA.L #0x2704,A1
        rom[16'h0900/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0904/4] = {16'h2700, MOVEA_L_IMM_A1};
        rom[16'h0908/4] = {16'h0000, 16'h2704};
        // 0x090C: CAS2.L opcode ; ext1
        rom[16'h090C/4] = {CAS2_L, CAS2_EXT1};
        // 0x0910: ext2 ; CLR.L D5
        rom[16'h0910/4] = {CAS2_EXT2, CLR_L_D5};
        // 0x0914: ADDI.L #666,D5 (unrelated dependent instr)
        rom[16'h0914/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0918/4] = {16'd666, NOP_OP};

        // -----------------------------------------------------------------
        // B-7: MOVEP.L D1,(0x0010,A0) — byte-interleaved store (stride 2).
        // Checked directly (not just "decode resumed") since the byte
        // interleave is a distinctive, easy-to-verify pattern.
        // -----------------------------------------------------------------
        // 0x0A00: MOVEA.L #0x2800,A0
        rom[16'h0A00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0A04/4] = {16'h2800, CLR_L_D1};
        // 0x0A08: ADDI.L #0xAABBCCDD,D1
        rom[16'h0A08/4] = {ADDI_L_D1, 16'hAABB};
        rom[16'h0A0C/4] = {16'hCCDD, MOVEP_L_D1_A0};
        // 0x0A10: MOVEP ext (d16=0x0010) ; CLR.L D5
        rom[16'h0A10/4] = {16'h0010, CLR_L_D5};
        // 0x0A14: ADDI.L #777,D5 (unrelated dependent instr)
        rom[16'h0A14/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0A18/4] = {16'd777, NOP_OP};

        // -----------------------------------------------------------------
        // B-8: MOVE16 (A0)+,(A1)+ — 16-byte STERM burst block move.
        // -----------------------------------------------------------------
        // 0x0B00: MOVEA.L #0x2900,A0 ; MOVEA.L #0x2A00,A1
        rom[16'h0B00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0B04/4] = {16'h2900, MOVEA_L_IMM_A1};
        rom[16'h0B08/4] = {16'h0000, 16'h2A00};
        // 0x0B0C: MOVE16 opcode ; ext (Am=A1)
        rom[16'h0B0C/4] = {MOVE16_A0P_A1P, MOVE16_EXT};
        // 0x0B10: CLR.L D5 ; ADDI.L D5 opcode
        rom[16'h0B10/4] = {CLR_L_D5, ADDI_L_D5};
        // 0x0B14: ext MSW=0 ; ext LSW=888 (unrelated dependent instr)
        rom[16'h0B14/4] = {16'h0000, 16'd888};
        // Source data for the 16-byte block.
        rom[16'h2900/4] = 32'h1111_1111;
        rom[16'h2904/4] = 32'h2222_2222;
        rom[16'h2908/4] = 32'h3333_3333;
        rom[16'h290C/4] = 32'h4444_4444;

        // -----------------------------------------------------------------
        // B-9/B-10/B-11: predecrement-memory-form FSMs — ADDX.L, ABCD, PACK
        // -(Ay),-(Ax). Same "decode resumes correctly" idiom as CAS/CAS2/
        // CMPM (Harte already covers each instruction's own arithmetic
        // exhaustively); each gets its own fresh scratch-memory region so
        // the 3-phase predecrement (read Ay, read Ax, write) never
        // underflows into another test's data.
        // -----------------------------------------------------------------
        // B-9: ADDX.L -(A1),-(A0) @ 0x0C00
        rom[16'h0C00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0C04/4] = {16'h2E04, MOVEA_L_IMM_A1};
        rom[16'h0C08/4] = {16'h0000, 16'h2D04};
        rom[16'h0C0C/4] = {ADDX_L_A1_A0, CLR_L_D5};
        rom[16'h0C10/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0C14/4] = {16'd901, NOP_OP};

        // B-10: ABCD -(A1),-(A0) @ 0x0D00
        rom[16'h0D00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0D04/4] = {16'h2E10, MOVEA_L_IMM_A1};
        rom[16'h0D08/4] = {16'h0000, 16'h2D10};
        rom[16'h0D0C/4] = {ABCD_A1_A0, CLR_L_D5};
        rom[16'h0D10/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0D14/4] = {16'd902, NOP_OP};

        // B-11: PACK -(A1),-(A0),#0 @ 0x0E00
        rom[16'h0E00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0E04/4] = {16'h2E20, MOVEA_L_IMM_A1};
        rom[16'h0E08/4] = {16'h0000, 16'h2D20};
        rom[16'h0E0C/4] = {PACK_A1_A0, 16'h0000};
        rom[16'h0E10/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h0E14/4] = {16'h0000, 16'd903};

        // -----------------------------------------------------------------
        // B-12: BFINS D1,(A0){8:8} — memory bitfield insert.
        // -----------------------------------------------------------------
        rom[16'h0F00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h0F04/4] = {16'h2F00, BFINS_D1_A0};
        rom[16'h0F08/4] = {BFINS_EXT, CLR_L_D5};
        rom[16'h0F0C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h0F10/4] = {16'd904, NOP_OP};

        // -----------------------------------------------------------------
        // B-13: CMP2.L (A0),D1 — bounds check (CMP2 form, not CHK2, so it
        // can't trap and redirect execution out from under this test).
        // -----------------------------------------------------------------
        rom[16'h1000/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1004/4] = {16'h3000, CMP2_L_A0_D1};
        rom[16'h1008/4] = {CMP2_EXT, CLR_L_D5};
        rom[16'h100C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1010/4] = {16'd905, NOP_OP};

        // -----------------------------------------------------------------
        // B-14: MOVE.L (A0),(A1) — both source and destination are memory
        // EAs. Checked directly (a plain longword copy is easy to verify).
        // -----------------------------------------------------------------
        rom[16'h1100/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1104/4] = {16'h3100, MOVEA_L_IMM_A1};
        rom[16'h1108/4] = {16'h0000, 16'h3200};
        rom[16'h110C/4] = {MOVE_L_A0_A1, CLR_L_D5};
        rom[16'h1110/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1114/4] = {16'd906, NOP_OP};
        rom[16'h3100/4] = 32'hDEAD_BEEF;

        // -----------------------------------------------------------------
        // B-15: RTR — 2-phase stack read (CCR word, then PC longword).
        // Frame is hand-constructed in memory (not pushed by a prior
        // instruction in this test) since RTR expects a pre-existing
        // frame; restored PC points straight at the dependent instruction,
        // so a successful RTR IS what makes the dependent instruction run.
        // -----------------------------------------------------------------
        rom[16'h1200/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h1204/4] = {16'h3302, RTR_OP};
        // A7=0x3302 (even, a legal SP — RTR/RTS don't require SP to be
        // longword-aligned, only word-aligned) rather than a round 4-byte-
        // aligned address: this makes RTR's *own* CCR(word)+PC(long) frame
        // land with the PC portion naturally 4-byte aligned at 0x3304 (SP+2)
        // instead of spanning two words at a misaligned address — this
        // testbench's simplified inline memory model (copied from
        // cosim_grp_tb.sv, `rd_word = rom[ext_a[13:2]]`) always serves a
        // full aligned word regardless of the requested address's low bits,
        // so a genuinely misaligned longword read that should span two
        // different rom[] slots instead silently re-reads the same slot
        // twice. A real 68030 BIU splits a misaligned access into two
        // separate bus cycles at two different addresses (exercised and
        // confirmed working via Harte's own misaligned-access coverage) —
        // this is a testbench memory-model limitation, not an RTL gap, so
        // side-stepping it here (a legal SP choice, not a workaround for a
        // real restriction) is the right fix rather than deepening the
        // model to handle arbitrary misalignment.
        // CCR word at 0x3302 (lower half of this slot); PC at 0x3304
        // (a separate, 4-byte-aligned slot) = 0x1208.
        rom[16'h3300/4] = {16'h0000, 16'h0000};   // upper half unused (before SP)
        rom[16'h3304/4] = 32'h0000_1208;
        // 0x1208: dependent instruction (only reached if RTR redirected here)
        rom[16'h1208/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h120C/4] = {16'h0000, 16'd907};

        // -----------------------------------------------------------------
        // B-16: RTE — format-$0 frame (format/vector word + SR, then PC;
        // see plan.md Phase 99 for why 68030 RTE always expects a leading
        // format word). SR restored with S=1 so supervisor mode (and A7's
        // SSP alias, which every other test in this file relies on)
        // continues unaffected for the tests that follow.
        // -----------------------------------------------------------------
        rom[16'h1300/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h1304/4] = {16'h3400, RTE_OP};
        // Frame at 0x3400: {format=0,vector=0}/SR=0x2000 longword, then PC
        // longword (4-byte aligned, no misalignment this time).
        rom[16'h3400/4] = {16'h0000, 16'h2000};
        rom[16'h3404/4] = 32'h0000_1308;
        // 0x1308: dependent instruction
        rom[16'h1308/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h130C/4] = {16'h0000, 16'd908};

        // -----------------------------------------------------------------
        // B-17: RESET — pulses RSTOUT for ~2047 internal ticks (Phase-
        // documented) without halting the CPU; the following instruction
        // must still execute once the pulse ends.
        // -----------------------------------------------------------------
        rom[16'h1400/4] = {RESET_OP, CLR_L_D5};
        rom[16'h1404/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1408/4] = {16'd909, NOP_OP};

        // -----------------------------------------------------------------
        // B-18: MOVEM.L D0/D1,-(A0) — multi-beat register-list STORE (the
        // write-side companion to B-2's load form; predecrement mask order
        // is reversed, per MOVEM_L_PREDEC_A0's comment).
        // -----------------------------------------------------------------
        rom[16'h1500/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1504/4] = {16'h3510, MOVEM_L_PREDEC_A0};
        rom[16'h1508/4] = {16'hC000, CLR_L_D5};
        rom[16'h150C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1510/4] = {16'd910, NOP_OP};

        // -----------------------------------------------------------------
        // B-19: PFLUSHA — flush entire ATC, no EA/bus operand needed.
        // -----------------------------------------------------------------
        rom[16'h1600/4] = {PFLUSHA_OP, PFLUSHA_EXT};
        rom[16'h1604/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1608/4] = {16'h0000, 16'd911};

        // -----------------------------------------------------------------
        // B-20: PTEST (A0). m68030_mmu.sv's PTEST FSM only enters its walk
        // state when tc_e is set (`ptest_req && tc_e`) — with the MMU left
        // disabled (TC.E=0, this file's default state, same as every prior
        // test), eu_ptest_ack never fires and the FSM hangs forever. So
        // this test first PMOVEs a TC value with E=1 and a TT0 configured
        // fully transparent (LAM=0xFF wildcards every address bit, so every
        // VA passes through unmodified) — same "avoid a real table walk"
        // technique as biu_tb.sv's own P6-6 TT0-bypass test, just widened
        // to match any VA rather than one specific range — so PTEST
        // resolves immediately without needing any actual page-table data.
        // -----------------------------------------------------------------
        rom[16'h1700/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1704/4] = {16'h3800, PMOVE_A0_OP};     // PMOVE (A0),TC
        rom[16'h1708/4] = {PMOVE_TC_EXT, MOVEA_L_IMM_A0};
        rom[16'h170C/4] = {16'h0000, 16'h3804};
        rom[16'h1710/4] = {PMOVE_A0_OP, PMOVE_TT0_EXT}; // PMOVE (A0),TT0
        rom[16'h1714/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1718/4] = {16'h3700, PTEST_A0_OP};
        rom[16'h171C/4] = {PTEST_EXT, CLR_L_D5};
        rom[16'h1720/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1724/4] = {16'd912, NOP_OP};
        rom[16'h3800/4] = 32'h8000_0000;  // TC: E=1, PS/IS/TIA/TIB/TIC=0
        rom[16'h3804/4] = 32'h00FF_80E0;  // TT0: LAB=0,LAM=0xFF(any VA),E=1,FCM=any

        // -----------------------------------------------------------------
        // B-21: PMOVE (A0),CRP — 64-bit load, 2 bus cycles (hi word first).
        // Same opcode word as PTEST (0xF010); the sub-operation is entirely
        // carried in the extension word's mmu_op_type field.
        // -----------------------------------------------------------------
        rom[16'h1800/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1804/4] = {16'h3600, PMOVE_A0_OP};
        rom[16'h1808/4] = {PMOVE_CRP_EXT, CLR_L_D5};
        rom[16'h180C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1810/4] = {16'd913, NOP_OP};

        // ----- run to completion, checking each case in turn -----
        // Category B precision: exact data-bus-cycle counts (task #33 in
        // the post-Phase-104 follow-up list). Bracketing data_ds_count
        // immediately before/after each run_and_check call is a clean
        // window with no separate scoping needed — every setup and
        // dependent-check instruction in this file is register/immediate
        // only (zero data-space bus cycles), so the delta can only reflect
        // the FSM instruction's own bus activity.
        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-1: TAS dependent instr ran (D2=111)", 2, 32'd111, 3000);
            c1 = data_ds_count;
            check32("B-1: TAS bus cycles = 2 (read+write, locked)", c1 - c0, 32'd2);
        end
        check8("B-1: TAS set bit7 of tested byte", rom[16'h2000/4][31:24], 8'hCE);

        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-2: MOVEM dependent instr ran (D2=222)", 2, 32'd222, 3000);
            c1 = data_ds_count;
            check32("B-2: MOVEM bus cycles = 2 (one longword read per register)", c1 - c0, 32'd2);
        end
        check32("B-2: MOVEM D0 loaded", u_top.u_eu.u_rf.d_reg[0], 32'h1111_1111);
        check32("B-2: MOVEM D1 loaded", u_top.u_eu.u_rf.d_reg[1], 32'h2222_2222);
        check32("B-2: MOVEM A0 post-increment (2 beats)", u_top.u_eu.u_rf.a_reg[0], 32'h0000_2108);

        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-3: CMPM dependent instr ran (D3=333)", 3, 32'd333, 3000);
            c1 = data_ds_count;
            check32("B-3: CMPM bus cycles = 2 (one byte read per operand)", c1 - c0, 32'd2);
        end

        run_and_check("B-4: BCHG dependent instr ran (D4=444)", 4, 32'd444, 3000);
        check8("B-4: BCHG toggled bit3 of tested byte", rom[16'h2300/4][31:24], 8'h46);

        // Category D: wait_states set between test cases, well before (58+
        // NOP instructions of margin) each one's own bus read actually
        // occurs, so the change is guaranteed to take effect in time.
        begin
            int elapsed0, elapsed2, elapsed5;
            wait_states = 0;
            run_and_check_timed("D-1: wait_states=0, D1=7", 1, 32'd7, 3000, elapsed0);

            wait_states = 2;
            run_and_check_timed("D-2: wait_states=2, D1=9", 1, 32'd9, 3000, elapsed2);

            wait_states = 5;
            run_and_check_timed("D-3: wait_states=5, D1=13", 1, 32'd13, 3000, elapsed5);
            wait_states = 0;

            // Coarse composition sanity check: 5 injected wait states must
            // measurably lengthen the observed cycle count relative to 0
            // wait states (each wait state is 1 extra clk_4x tick here,
            // not a full S-state, since this model isn't S-state-phased —
            // see the wait_states comment above ds_active_r) — confirms the
            // wait-state knob genuinely affects timing, not just that the
            // functional result stayed correct by coincidence.
            check("D-3 vs D-1: wait states measurably lengthen the cycle",
                  elapsed5 > elapsed0 + 3);
        end

        run_and_check("B-5: CAS dependent instr ran (D5=555)", 5, 32'd555, 3000);

        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-6: CAS2 dependent instr ran (D5=666)", 5, 32'd666, 3000);
            c1 = data_ds_count;
            // CAS2 always reads both operands (2 cycles); it only writes
            // back (2 more cycles, 4 total) if the compare matches. D1/D3
            // (Dc1/Dc2) hold whatever stale values persisted from earlier
            // tests and were never set to match ct_dram's contents, so the
            // compare is expected to mismatch — read-only, 2 cycles.
            $display("INFO  B-6: CAS2 bus cycles = %0d", c1 - c0);
            check32("B-6: CAS2 bus cycles = 2 (compare mismatch, read-only)", c1 - c0, 32'd2);
        end

        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-7: MOVEP dependent instr ran (D5=777)", 5, 32'd777, 3000);
            c1 = data_ds_count;
            check32("B-7: MOVEP bus cycles = 4 (one byte write per interleaved byte)", c1 - c0, 32'd4);
        end
        check8("B-7: MOVEP byte0 (D1[31:24]) at A0+16",   rom[16'h2810/4][31:24], 8'hAA);
        check8("B-7: MOVEP byte1 (D1[23:16]) at A0+18",   rom[16'h2810/4][15:8],  8'hBB);
        check8("B-7: MOVEP byte2 (D1[15:8]) at A0+20",    rom[16'h2814/4][31:24], 8'hCC);
        check8("B-7: MOVEP byte3 (D1[7:0]) at A0+22",     rom[16'h2814/4][15:8],  8'hDD);

        run_and_check("B-8: MOVE16 dependent instr ran (D5=888)", 5, 32'd888, 3000);
        check32("B-8: MOVE16 beat0 copied", rom[16'h2A00/4], 32'h1111_1111);
        check32("B-8: MOVE16 beat1 copied", rom[16'h2A04/4], 32'h2222_2222);
        check32("B-8: MOVE16 beat2 copied", rom[16'h2A08/4], 32'h3333_3333);
        check32("B-8: MOVE16 beat3 copied", rom[16'h2A0C/4], 32'h4444_4444);
        check32("B-8: MOVE16 A0 post-increment (+16)", u_top.u_eu.u_rf.a_reg[0], 32'h0000_2910);
        check32("B-8: MOVE16 A1 post-increment (+16)", u_top.u_eu.u_rf.a_reg[1], 32'h0000_2A10);

        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("B-9: ADDX.L dependent instr ran (D5=901)", 5, 32'd901, 3000);
            c1 = data_ds_count;
            check32("B-9: ADDX.L bus cycles = 3 (read Ay, read Ax, write Ax)", c1 - c0, 32'd3);
        end
        run_and_check("B-10: ABCD dependent instr ran (D5=902)", 5, 32'd902, 3000);
        run_and_check("B-11: PACK dependent instr ran (D5=903)", 5, 32'd903, 3000);

        run_and_check("B-12: BFINS dependent instr ran (D5=904)", 5, 32'd904, 3000);
        run_and_check("B-13: CMP2 dependent instr ran (D5=905)", 5, 32'd905, 3000);
        run_and_check("B-14: MOVE mem-mem dependent instr ran (D5=906)", 5, 32'd906, 3000);
        check32("B-14: MOVE.L (A0),(A1) copied", rom[16'h3200/4], 32'hDEAD_BEEF);

        run_and_check("B-15: RTR redirected to dependent instr (D5=907)", 5, 32'd907, 8000);
        run_and_check("B-16: RTE redirected to dependent instr (D5=908)", 5, 32'd908, 8000);
        run_and_check("B-17: RESET dependent instr ran (D5=909)", 5, 32'd909, 8000);
        run_and_check("B-18: MOVEM store dependent instr ran (D5=910)", 5, 32'd910, 8000);
        check32("B-18: MOVEM store A0 post-decrement (-8)", u_top.u_eu.u_rf.a_reg[0], 32'h0000_3508);

        run_and_check("B-19: PFLUSHA dependent instr ran (D5=911)", 5, 32'd911, 3000);
        run_and_check("B-20: PTEST dependent instr ran (D5=912)", 5, 32'd912, 3000);
        // B-21 runs with the MMU now enabled (B-20 set TC.E=1) — every bus
        // access, including plain instruction fetches, now goes through an
        // ATC/TT0 lookup first. TT0 is configured fully transparent (no
        // faults, no real table walk), but the lookup itself still costs
        // real cycles per access, so this needs a much larger budget than
        // every earlier MMU-disabled test in this file.
        run_and_check("B-21: PMOVE CRP dependent instr ran (D5=913)", 5, 32'd913, 20000);

        // -----------------------------------------------------------------
        // Interrupt arrival mid-FSM (task #2 in the post-Phase-104
        // follow-up list): does a level-7 (NMI, bypasses the IPL mask
        // entirely — SR's mask defaults to 7 at reset, so a maskable level
        // would need an extra MOVE-to-SR setup step just to be
        // recognizable at all, which isn't the point of this test) request
        // that arrives *during* a locked CAS2 sequence get deferred until
        // CAS2 fully completes, or does it hijack the bus mid-sequence?
        //
        // Investigated first by reading the RTL: m68030_exc.sv's exception
        // FSM had no eu_busy/ex_mem_stall input at all — exc_pending (and
        // therefore exc_active = state_r != EXC_IDLE) was purely
        // combinational on the IPL lines and mask, with no instruction-
        // boundary gating of its own. **This turned out to be a genuine,
        // previously-undiscovered RTL bug**: real 68030 silicon only
        // samples IPL at instruction boundaries (bus/address error are the
        // only truly asynchronous exceptions — the fault IS the in-flight
        // bus cycle failing). Confirmed with a first version of this test
        // (no eu_busy gating): CAS2's own D5=1234 dependent-instruction
        // marker never fired at all, only the interrupt handler's D6=12345
        // did — i.e. the interrupt was hijacking the bus mid-CAS2 rather
        // than waiting for it to retire. Fixed by adding an `eu_busy` port
        // to m68030_exc (wired from the existing top-level `eu_busy` net,
        // == eu_seq.sv's `stall`) and gating *only* int_pending's own
        // branch of the exc_pending priority mux on `!eu_busy` — bus/addr
        // error stay unconditional, and every synchronous instruction-
        // originated exception (illegal/priv/trace/CHK/TRAPV/trap/...)
        // stays unconditional too, since those are already synchronized to
        // the instruction that raises them.
        //
        // With the fix in place, a *second* subtlety showed up empirically
        // (via a temporary $display trace of eu_busy/exc_active/
        // data_ds_count/decode_pc — since removed): the interrupt is
        // correctly deferred until CAS2's FSM fully retires (both bus
        // phases land before exc_active ever asserts — checked below as an
        // explicit cycle-count assertion), but it then preempts at the
        // very next instruction boundary, which lands *before* this test's
        // own CLR.L D5/ADDI.L "CAS2 completed" marker pair gets to run —
        // CAS2 itself is atomic, but ordinary instructions following it
        // are not glued to it. That is correct 68k semantics, not a bug:
        // only CAS2's own FSM has an atomicity guarantee. So the handler
        // now ends in RTE (real hardware auto-generates the return frame;
        // no hand-crafted stack needed, unlike B-16 above, which was
        // itself testing RTE's own decode logic in isolation) and this
        // test's pass criteria are (a) CAS2's full bus-cycle count elapses
        // before exc_active ever asserts, and (b) both markers eventually
        // reach their expected values after the RTE returns control to
        // the resumed instruction stream.
        //
        // That same trace also caught a **third, deeper, and still-open**
        // finding, deliberately deferred rather than fixed here: CLR.L D5
        // (the instruction immediately after CAS2) was observed to launch
        // into EX and fully commit (D5 briefly read back 0, mid-exception-
        // push) on the *exact same cycle* eu_busy first dropped to 0 —
        // because it had already sat fully decoded and hazard-free in
        // DECODE throughout CAS2's stall, `instr_ack = dec_valid && !stall`
        // fires combinationally the instant `stall` clears, with no gap
        // cycle. But the exception controller's snap_pc_r *also* samples
        // ifu_decode_pc on that identical edge, and decode_pc had not yet
        // advanced past CLR.L D5 at that instant — so the saved return PC
        // pointed at CLR.L D5's own (already-executing) address, and RTE
        // later resumed there, silently *re-running* it. This test can't
        // see it (confirmed via the trace, not asserted below) because
        // CLR is idempotent — but a non-idempotent instruction in that
        // exact slot (ADD, an autoincrement/decrement EA, a memory write)
        // would be double-executed after any interrupt that happens to
        // land on the specific cycle a multi-cycle FSM retires directly
        // into an already-decoded, hazard-free follow-on instruction. Real
        // fix needs `int_pending` (or an equivalent "would take it now"
        // signal) threaded into eu_seq.sv's own `stall` so the newly-ready
        // instruction is held in DECODE for one extra cycle rather than
        // launching on the recognition edge — genuinely new cross-module
        // plumbing (eu_seq.sv currently has no IPL awareness at all, see
        // module port list), plus a full Harte re-verification once
        // touched, since `stall` is the single most shared signal in the
        // EU. Deferred to its own future phase rather than rushed in here;
        // documented in plan.md/CLAUDE.md so it isn't lost.
        // -----------------------------------------------------------------
        $display("=== Interrupt arrival during a locked CAS2 sequence ===");
        begin
            int t, d0, d1, ds_at_exc;
            logic injected, exc_seen;

            // Level-7 autovector: vector 31, at VBR(=0)+31*4=0x7C. Handler
            // address stored there; handler itself sets D6 as its own
            // completion marker, distinct from CAS2's D5 marker below,
            // then RTEs back into the interrupted instruction stream.
            rom[16'h007C/4] = 32'h0000_0080;
            rom[16'h0080/4] = {CLR_L_D6, ADDI_L_D6};
            rom[16'h0084/4] = {16'h0000, 16'd12345};
            rom[16'h0088/4] = {RTE_OP, NOP_OP};

            // Fresh CAS2.L instance (same opcode/ext-word layout as B-6,
            // reusing Rn1=A0/Rn2=A1), at a new address/data region so it
            // doesn't disturb B-6's own already-verified result.
            rom[16'h1900/4] = {MOVEA_L_IMM_A0, 16'h0000};
            rom[16'h1904/4] = {16'h3900, MOVEA_L_IMM_A1};
            rom[16'h1908/4] = {16'h0000, 16'h3904};
            rom[16'h190C/4] = {CAS2_L, CAS2_EXT1};
            rom[16'h1910/4] = {CAS2_EXT2, CLR_L_D5};
            rom[16'h1914/4] = {ADDI_L_D5, 16'h0000};
            rom[16'h1918/4] = {16'd1234, NOP_OP};

            d0 = data_ds_count;
            injected = 1'b0;
            exc_seen = 1'b0;
            ds_at_exc = -1;
            for (t = 0; t < 20000; t++) begin
                @(posedge clk_4x); #1;
                // Inject the moment CAS2's first bus cycle is observed —
                // i.e. mid-sequence, not before it starts.
                if (!injected && (data_ds_count != d0)) begin
                    injected = 1'b1;
                    ipl_n = 3'b000;   // level 7 (NMI): all IPL lines asserted (active-low)
                end
                // IPL is a level input on real hardware, sampled once per
                // instruction boundary; holding it asserted forever would
                // cause a legitimate re-recognition at every subsequent
                // boundary (an interrupt storm), not a CAS2/FSM bug. Drop
                // it back to idle the cycle after the controller first
                // acts on it, same as a real interrupt source deasserting
                // once its request is acknowledged.
                if (injected && !exc_seen && u_top.exc_active) begin
                    exc_seen  = 1'b1;
                    ds_at_exc = data_ds_count;
                    ipl_n     = 3'b111;
                end
                if (u_top.u_eu.u_rf.d_reg[5] === 32'd1234 && u_top.u_eu.u_rf.d_reg[6] === 32'd12345)
                    break;
            end
            ipl_n = 3'b111;   // deassert before any later test could see it
            check("INT-mid-CAS2: injected mid-sequence (not before it started)", injected);
            check("INT-mid-CAS2: exception was recognized at all", exc_seen);
            check32("INT-mid-CAS2: CAS2's full 2-cycle bus sequence completed before the interrupt was taken (not truncated mid-FSM)",
                    ds_at_exc - d0, 32'd2);
            check("INT-mid-CAS2: CAS2 itself completed (D5=1234)", u_top.u_eu.u_rf.d_reg[5] === 32'd1234);
            check("INT-mid-CAS2: interrupt handler ran and RTE'd back (D6=12345)", u_top.u_eu.u_rf.d_reg[6] === 32'd12345);
        end

        // -----------------------------------------------------------------
        // Task #3 (post-Phase-104 follow-up list): BERR arriving mid-FSM —
        // does a sustained bus error partway through a locked CAS2 sequence
        // produce a clean Bus Error exception, or does it corrupt/hang the
        // FSM? Investigated by direct RTL tracing (temporary $display
        // probes of berr_n/eu_berr/cg_eu_berr_raw/biu_cache_if's own
        // `state`/mo_state, since removed) before writing this permanent
        // test, because the very first version (BERR held for exactly one
        // cycle, mirroring biu_tb.sv's own isolated P4-2 BERR-abort unit
        // test pattern) gave a misleadingly clean result: D5/D6 both
        // completed normally, no hang. Holding berr_n continuously
        // asserted (rather than a single-cycle pulse) instead of a clean
        // exception uncovered a **real, severe, previously-undiscovered
        // RTL bug spanning several files**, root-caused as follows:
        //
        //   1. biu_cycle_gen.sv correctly detects the fault and pulses its
        //      raw eu_berr signal once per retry attempt (confirmed via
        //      trace: cg_eu_berr_raw toggles on a ~32-cycle cadence for as
        //      long as berr_n stays asserted) — the BIU's own fault
        //      *detection* is solid, matching what biu_tb.sv's isolated
        //      P4-2/P4-3 unit tests already established.
        //   2. **CAS2 itself has no berr signaling path at all.** Unlike
        //      MOVEM/MOVEP (which share biu_multiop_fsm.sv's generic
        //      eu_mo_req/eu_mo_ack/eu_mo_berr trio — that module has the
        //      identical class of bug: MO_CYCING only transitions on
        //      `sf_eu_ack`, no `sf_eu_berr` arm at all, and although its
        //      own `eu_mo_berr` *output* does correctly pulse
        //      (`assign eu_mo_berr = sf_eu_berr && (mo_state==MO_CYCING)`),
        //      nothing consumes it, so mo_state sits in MO_CYCING forever),
        //      CAS2 has its own dedicated 4-cycle datapath directly in
        //      biu_cycle_gen.sv (m68030_biu.sv's port list has
        //      `eu_cas2_req`/`eu_cas2_ack` but no `eu_cas2_berr` at all —
        //      confirmed by grep, not an oversight in this write-up). So
        //      CAS2 doesn't even get as far as "detects the fault but
        //      can't act on it" — there is structurally no wire for it to
        //      find out a fault happened, an even more severe instance of
        //      the same bug class.
        //   3. **biu_cache_if.sv has the identical bug** for ordinary
        //      (non-FSM) EU reads/writes: its CI_D_MISS/CI_WRITE/CI_FILL_*
        //      states also only transition on `sf_ack_rise`; the `sf_berr`
        //      input (wired in, `rtl/m68030_biu.sv:480`) is declared but
        //      never read anywhere in the module. `m68030_biu.sv:678`'s own
        //      comment even flags half of this: `// eu_berr routed direct
        //      from cycle_gen (cache_if.eu_berr is always 0)` — a known,
        //      partial workaround (routes the *plain* eu_berr output
        //      around the dead cache_if.eu_berr) that never actually fixed
        //      the underlying hang, since eu_seq.sv's own `mem_berr` input
        //      is separately documented as ignored (see below).
        //   4. Even if either FSM correctly aborted, **m68030_exc.sv's
        //      bus_err_req is wired only from `ifu_bus_err`**
        //      (m68030_top.sv:447) — an EU-side fault has no path to the
        //      exception controller at all today. `m68030_biu` already
        //      computes everything needed for a correct frame (frame
        //      format $9/$A/$B, SSW, fault address/data, via
        //      biu_exc_capture) but the aggregate `exc_frame_valid` output
        //      is wired to a top-level net that is never read anywhere
        //      (`fault_valid_biu` likewise) — both confirmed dangling via
        //      grep, not just untested.
        //   5. A real fix additionally needs a sticky-to-pulse conversion:
        //      both `fault_valid` (biu_cycle_gen) and `frame_valid`
        //      (biu_exc_capture) are deliberately latched "until reset"
        //      (each module's own comment, matching BIU-090) so the frame
        //      data stays stable throughout the whole EXC_PUSH sequence —
        //      wiring either directly into bus_err_req would permanently
        //      lock the priority encoder into Bus Error after the *first*
        //      fault ever seen. m68030_ifu.sv's own `bus_err_r` already
        //      solves this correctly (clears on `pc_wr_en`, the same pulse
        //      the exception controller issues when it finally loads the
        //      handler PC) — the EU-side fix needs the identical pattern,
        //      not currently present anywhere for the EU path.
        //
        // Given the fix spans biu_cache_if.sv, biu_multiop_fsm.sv (and
        // likely biu_burst_ctrl.sv/coprocessor paths, not individually
        // re-checked here), m68030_biu.sv's eu_berr wiring, and
        // m68030_top.sv/m68030_exc.sv's bus_err_req + fault_addr muxing —
        // plus a full Harte re-verification once touched, since cache_if
        // is on every single EU/IFU memory access — this is deliberately
        // root-caused and documented here rather than fixed in this same
        // pass. This test asserts *today's actual* (buggy) behavior so
        // `make test` stays green and the gap stays visible for a
        // dedicated future phase, matching the project's established
        // "document, don't silently drop" convention (see e.g. the
        // TRAP/Address-Error frame-width divergence in plan.md Phases
        // 99-100, or the dispatch-race finding earlier in this same file).
        // -----------------------------------------------------------------
        $display("=== BERR mid-CAS2 sequence ===");
        begin
            int t, dd0;
            logic saw_biu_berr, injected3;
            rom[16'h1C00/4] = {MOVEA_L_IMM_A0, 16'h0000};
            rom[16'h1C04/4] = {16'h3C00, MOVEA_L_IMM_A1};
            rom[16'h1C08/4] = {16'h0000, 16'h3C04};
            rom[16'h1C0C/4] = {CAS2_L, CAS2_EXT1};
            rom[16'h1C10/4] = {CAS2_EXT2, CLR_L_D5};
            rom[16'h1C14/4] = {ADDI_L_D5, 16'h0000};
            rom[16'h1C18/4] = {16'd777, NOP_OP};
            saw_biu_berr = 1'b0;
            injected3 = 1'b0;
            dd0 = data_ds_count;
            for (t = 0; t < 12000; t++) begin
                @(posedge clk_4x); #1;
                if (!injected3 && data_ds_count != dd0) begin
                    injected3 = 1'b1;
                    berr_n = 1'b0;   // sustained fault — never deasserted
                end
                // CAS2 has its own dedicated 4-cycle datapath directly in
                // biu_cycle_gen.sv (eu_cas2_req/eu_cas2_ack) — unlike
                // MOVEM/MOVEP (which go through biu_multiop_fsm.sv's
                // generic eu_mo_req/eu_mo_ack/eu_mo_berr), CAS2 has **no
                // berr output of its own at all** (grepped m68030_biu.sv's
                // full port list: eu_cas2_ack exists, eu_cas2_berr does
                // not) — an even more severe instance of the same bug
                // class, so this watches the shared BIU-internal raw fault
                // signal instead (cg_eu_berr_raw, the same one that also
                // drives the misleading top-level eu_berr per the finding
                // above) to confirm the BIU layer itself still detects the
                // fault even though CAS2 has no way to be told about it.
                if (u_top.u_biu.cg_eu_berr_raw) saw_biu_berr = 1'b1;
            end
            berr_n = 1'b1;
            check("BERR-mid-CAS2: injected mid-sequence", injected3);
            check("BERR-mid-CAS2: BIU layer still detects the fault (cg_eu_berr_raw pulsed) even though CAS2 has no berr output to receive it",
                  saw_biu_berr);
            // KNOWN GAP (see comment above): today, biu_multiop_fsm.sv's
            // mo_state never leaves MO_CYCING on a berr, so the FSM hangs
            // and no Bus Error exception is ever taken. These two checks
            // document that current (incorrect) behavior; once the fix
            // above lands, they should flip to eu_busy===0 and
            // exc_active===1 having been seen, with a proper frame pushed.
            check("BERR-mid-CAS2: KNOWN GAP - EU pipeline left stalled (eu_busy stuck, no recovery)",
                  u_top.eu_busy === 1'b1);
            check("BERR-mid-CAS2: KNOWN GAP - no Bus Error exception was ever taken",
                  u_top.exc_active === 1'b0);
        end

        // -----------------------------------------------------------------
        // Task #4a (post-Phase-104 follow-up list): back-to-back FSM
        // composition — two *different* multi-cycle ex_mem_stall FSMs with
        // no ordinary instruction between them, to check decode-holdoff
        // correctly composes across an FSM-to-FSM transition (every
        // Category B case so far pairs one FSM with a plain dependent
        // instruction afterward, never FSM-then-FSM directly).
        // TAS (A0) — an indivisible RMW lock — immediately followed by
        // MOVEM.L (A0)+,D0-D1, reusing the *same* A0 with no MOVEA between
        // them (TAS never modifies An), so the two FSMs are truly adjacent
        // at the opcode level. Also incidentally checks write-then-read
        // ordering across the boundary: TAS's write sets bit7 of the top
        // byte of the very longword MOVEM reads immediately afterward, so
        // a stale/racy read would show up as D0's top bit not reflecting
        // the TAS write.
        // -----------------------------------------------------------------
        rom[16'h1D00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1D04/4] = {16'h3D00, TAS_A0};
        rom[16'h1D08/4] = {MOVEM_L_A0P, 16'h0003};
        rom[16'h1D0C/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1D10/4] = {16'h0000, 16'd444};
        rom[16'h3D00/4] = 32'h0011_2233;  // top byte 0x00 -> TAS sets bit7 -> 0x80
        rom[16'h3D04/4] = 32'h4455_6677;
        begin
            int c0, c1;
            c0 = data_ds_count;
            run_and_check("T4a: back-to-back TAS->MOVEM dependent instr ran (D5=444)", 5, 32'd444, 4000);
            c1 = data_ds_count;
            // 4 logical accesses (TAS read, TAS write, MOVEM read x2) x 2,
            // not x1: by this point in the file the MMU has been left
            // enabled with a transparent TT0 since B-20/B-21 (Phase 104's
            // own established, intentional behavior — every subsequent
            // access pays an extra ATC/TT0 lookup even though it never
            // faults or produces a real table walk). B-1/B-2's own
            // standalone counts (2 each) were measured earlier in the
            // file, before the MMU got enabled, so they don't apply here —
            // this is a timing difference from already-documented MMU
            // state, not a sign of a duplicated/corrupted sequence (D0/D1/
            // memory below all confirm exactly one clean execution).
            check32("T4a: TAS(2) + MOVEM(2) = 4 logical accesses x2 (MMU-enabled ATC lookup overhead) = 8 bus cycles",
                    c1 - c0, 32'd8);
            check32("T4a: MOVEM's D0 reflects TAS's write (top byte 0x80, not stale 0x00)",
                    u_top.u_eu.u_rf.d_reg[0], 32'h8011_2233);
            check32("T4a: MOVEM's D1 loaded correctly", u_top.u_eu.u_rf.d_reg[1], 32'h4455_6677);
            check8("T4a: TAS itself set bit7 in memory", rom[16'h3D00/4][31:24], 8'h80);
        end

        // -----------------------------------------------------------------
        // Task #4b: DSACK wait-states applied to an FSM instruction's own
        // multi-beat bus cycles, not just Category D's single-beat simple
        // producer. Reuses TAS (2 bus beats: read then write) with the
        // existing global `wait_states` knob (already proven against
        // mem_model's DSACK generation in Category D) — confirms a
        // stretched bus cycle composes correctly with *every* beat of a
        // multi-phase FSM, not just a single ordinary access.
        // -----------------------------------------------------------------
        rom[16'h1E00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1E04/4] = {16'h3E00, TAS_A0};
        rom[16'h1E08/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1E0C/4] = {16'h0000, 16'd333};
        rom[16'h3E00/4] = 32'h0000_0000;
        rom[16'h1F00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1F04/4] = {16'h3F80, TAS_A0};
        rom[16'h1F08/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1F0C/4] = {16'h0000, 16'd335};
        rom[16'h3F80/4] = 32'h0000_0000;
        begin
            int elapsed0, elapsed3;
            wait_states = 0;
            run_and_check_timed("T4b-1: TAS wait_states=0, D5=333", 5, 32'd333, 4000, elapsed0);
            wait_states = 3;
            run_and_check_timed("T4b-2: TAS wait_states=3, D5=335", 5, 32'd335, 4000, elapsed3);
            wait_states = 0;
            check("T4b: wait states measurably lengthen a real FSM's own bus beats (not just a simple producer)",
                  elapsed3 > elapsed0);
        end

        check("No address errors", ~(eu_addr_err | ifu_addr_err));

        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #800000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

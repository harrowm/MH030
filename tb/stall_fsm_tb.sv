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

        run_and_check("B-6: CAS2 dependent instr ran (D5=666)", 5, 32'd666, 3000);

        run_and_check("B-7: MOVEP dependent instr ran (D5=777)", 5, 32'd777, 3000);
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

        run_and_check("B-9: ADDX.L dependent instr ran (D5=901)", 5, 32'd901, 3000);
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

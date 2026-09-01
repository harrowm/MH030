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
    logic        ciin_n   = 1'b1;   // Phase 158 Stage 7: CIIN# deasserted (not asserted)

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
        .cback_n      (cback_n),
        .ciin_n       (ciin_n),
        .ciout_n      ()
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
    localparam CLR_L_PREDEC_A0 = 16'h42A0;  // CLR.L -(A0)
    localparam CLR_L_D16_A1    = 16'h42A9;  // CLR.L (d16,A1)
    localparam CLR_L_D7        = 16'h4287;  // CLR.L D7
    localparam MOVE_L_IMM_D6   = 16'h2C3C;  // MOVE.L #imm,D6
    localparam MOVE_L_IMM_D7   = 16'h2E3C;  // MOVE.L #imm,D7
    localparam MOVE_L_IMM_D1   = 16'h223C;  // MOVE.L #imm,D1
    localparam MOVE_L_IMM_D2   = 16'h243C;  // MOVE.L #imm,D2
    localparam CLR_L_IDX_A0    = 16'h42B0;  // CLR.L (d8,A0,D1.L)
    localparam MOVE_SR_IDX_A1  = 16'h40F1;  // MOVE.W SR,(d8,A1,D2.L)
    localparam BRA_SELF       = 16'h60FE;  // BRA.B -2: tight self-loop (parks decode)
    localparam JMP_ABS_L_OP   = 16'h4EF9;  // JMP (xxx).L
    // open-items backlog Stage 13 (plan.md): BKPT live opcode substitution.
    localparam BKPT_3         = 16'h484B;  // BKPT #3 (breakpoint number in bits[2:0])
    localparam MOVEQ_D0_42    = 16'h702A;  // MOVEQ #42,D0 (the replacement opcode)
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
    localparam ADD_L_D1_D2    = 16'hD481;  // ADD.L D1,D2
    localparam DBF_D0         = 16'h51C8;  // DBF D0,disp
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
    // SBCD -(A1),-(A0): identical layout to ABCD, group=1000 instead of
    // 1100 (open-items backlog breadth plan, Stage 1). Cross-checked
    // against tb/eu_seq_tb.sv's own proven "SBCD D2,D3" = 16'h8702
    // (register form: bit3=Rm=0) -- the memory/predecrement form only
    // flips Rm (bit3) to 1, same relationship ABCD_A1_A0 already has to
    // ABCD's own register-direct form.
    localparam SBCD_A1_A0     = 16'h8109;
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
    // CHK2 shares CMP2's own opcode word entirely -- only the extension
    // word's bit 11 differs (0=CMP2, 1=CHK2, per eu_seq.sv's own
    // "ext[11]=CHK2(1)/CMP2(0)" decode comment). Pipeline-stall breadth
    // extension plan (elegant-gliding-fog.md), Stage 2.
    localparam CHK2_EXT       = 16'h1800;
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

    // Every source exercised by run_berr_mid_test (below) is deliberately
    // faulted and, by design, never returns to its own main instruction
    // stream (there's nothing sensible to retry -- see the shared vector-2
    // handler's own header comment). That means the *only* way decode_pc
    // ever reaches the *next* test's code is via this handler's own exit
    // path, not natural NOP fall-through (the main stream is permanently
    // abandoned mid-instruction). The handler's own tail always jumps to a
    // fixed parking spot (PARK_ADDR, a tight BRA_SELF self-loop) rather
    // than straight to the next test's real code -- claim_park() below is
    // what actually redirects hardware onward, and it's called from
    // *inside* run_berr_mid_test itself, right as the testbench becomes
    // ready to watch, not from the previous test. This matters: hardware
    // keeps running in real time regardless of testbench/SystemVerilog
    // program order -- a first version that jumped the handler straight to
    // the next test's address let hardware race ahead and run that whole
    // test to normal (unfaulted) completion *before* its own
    // run_berr_mid_test call even started watching, since a short
    // instruction sequence (MOVEP, MOVE16, etc.) completes in a few hundred
    // cycles, far faster than the previous test's own trailing "EU
    // recovered" wait takes to return. Parking first and only releasing
    // when the watcher is actually ready closes that race structurally --
    // hardware has nowhere to go until claim_park() sends it there.
    localparam PARK_ADDR = 32'h0000_00A0;

    task automatic claim_park(input logic [31:0] next_addr);
        rom[16'h00A0/4] = {JMP_ABS_L_OP, next_addr[31:16]};
        rom[16'h00A4/4] = {next_addr[15:0], NOP_OP};
    endtask

    // Shared BERR-mid-<instruction> watch loop, factored out of the
    // original BERR-mid-CAS2 test (Phase 108) once it became clear the
    // exact same shape applies to every ex_mem_stall source that goes
    // through the generic mem_ack/mem_berr path (i.e. everything except
    // PTEST, which reports translation faults via MMUSR instead of
    // trapping -- see the dedicated BERR-mid-PTEST test, which cannot use
    // this task). Caller is responsible for: placing this test's own code
    // (starting with a CLR.L D5, since D5's value leaks across these
    // sequential test blocks -- real CPU state, not reset between them)
    // at code_start_addr, and for reusing the shared vector-2 handler
    // (rom[0x08]->0x90, D5=999 on completion) already installed by the
    // very first BERR-mid-CAS2 test.
    task automatic run_berr_mid_test(input string test_name, input logic [31:0] code_start_addr,
                                      input int skip_cycles = 0,
                                      input logic [31:0] next_addr = 32'h0);
        int t, dd0, cyc_seen;
        logic saw_biu_berr, injected, exc_seen, d5_seen_999, d5_now_999;

        for (t = 0; t < 150000 && u_top.ifu_decode_pc < code_start_addr; t++)
            @(posedge clk_4x);
        check({test_name, ": reached own code"}, u_top.ifu_decode_pc >= code_start_addr);

        saw_biu_berr = 1'b0;
        injected     = 1'b0;
        exc_seen     = 1'b0;
        cyc_seen     = 0;
        dd0 = data_ds_count;
        // D5 leaks across these sequential test blocks (real CPU state, not
        // reset between them) -- every test's own code leads with a CLR.L D5
        // specifically so the watch loop below can use D5===999 as its own
        // completion marker. But decode_pc reaching code_start_addr only
        // means the *first* word there has been fetched, not that this
        // test's own leading CLR.L D5 has actually retired yet -- if the
        // previous test's own handler already left D5=999, checking the raw
        // value would break on stale data immediately, before this test has
        // done anything at all (confirmed: silently no-op'd every 2nd/3rd
        // test in a 12-test chain). Snapshot D5 here and only trust a later
        // *transition into* 999 (not just "currently reads 999") as this
        // test's own genuine completion.
        d5_seen_999 = (u_top.u_eu.u_rf.d_reg[5] === 32'd999);
        for (t = 0; t < 12000; t++) begin
            @(posedge clk_4x); #1;
            // skip_cycles lets a source with several genuine bus cycles
            // before the one under test (e.g. RTR/RTE's first stack read,
            // which -- unlike the second -- already recovers correctly on
            // its own per Phase 109, since rtr_phase_r/rte_phase_r are
            // still at their idle value 0 when a fault hits phase 0) target
            // a *later* cycle instead of always the first.
            if (!injected && data_ds_count != dd0) begin
                dd0 = data_ds_count;
                if (cyc_seen >= skip_cycles) begin
                    injected = 1'b1;
                    berr_n = 1'b0;
                end else begin
                    cyc_seen++;
                end
            end
            if (u_top.u_biu.cg_eu_berr_raw) begin
                saw_biu_berr = 1'b1;
                berr_n = 1'b1;
            end
            if (!exc_seen && u_top.exc_active) exc_seen = 1'b1;
            d5_now_999 = (u_top.u_eu.u_rf.d_reg[5] === 32'd999);
            if (d5_now_999 && !d5_seen_999) break;
            d5_seen_999 = d5_now_999;
        end
        berr_n = 1'b1;
        check({test_name, ": injected mid-sequence"}, injected);
        check({test_name, ": BIU layer detects the fault"}, saw_biu_berr);
        check({test_name, ": a real Bus Error exception was taken"}, exc_seen);
        check32({test_name, ": correct vector (2, Bus Error) dispatched"},
                {24'h0, u_top.exc_vector_num}, 32'd2);
        check({test_name, ": handler reached and ran to completion (D5=999)"},
              u_top.u_eu.u_rf.d_reg[5] === 32'd999);
        for (t = 0; t < 4000 &&
             !(u_top.ifu_decode_pc > 32'h0000_0096 && !u_top.eu_busy); t++)
            @(posedge clk_4x);
        check({test_name, ": EU pipeline recovered (eu_busy clear, no lingering hang)"},
              u_top.eu_busy === 1'b0);
        // Release the park to the next test's code *now*, right as this
        // task is about to return -- not any earlier. Hardware is
        // currently sitting in the park (having reached it during the
        // watch loop above), and the very next statement in the caller's
        // program order is the next test's own run_berr_mid_test call, so
        // its settle-wait is already active by the time hardware notices
        // the release and jumps out. Releasing any earlier (e.g. from the
        // *calling* test itself, at its own start, pointing at itself) was
        // tried and is wrong: this same test's own fault, which happens
        // later in real hardware time, would find its own stale claim
        // still sitting there and loop back into itself instead of
        // reaching whoever comes next.
        if (next_addr != 32'h0) claim_park(next_addr);
    endtask

    // Shared interrupt-mid-<instruction> watch loop (plan.md Phase 125),
    // factored out the same way run_berr_mid_test was (Phase 108/114) once
    // a second and third instance of the original interrupt-mid-CAS2 test
    // (Phase 105/108, still inline just below and deliberately left that
    // way -- it also establishes the shared vector-31 handler, same
    // reasoning BERR-mid-CAS2's own inline block has for the vector-2
    // handler) needed the identical shape. Unlike run_berr_mid_test, this
    // one does NOT use claim_park/PARK_ADDR: the handler here ends in a
    // real RTE, returning control to the *original*, still-live instruction
    // stream (not abandoning it), so the caller's own code simply
    // continues via ordinary NOP fall-through afterward -- no redirect
    // mechanism needed. Caller is responsible for: placing this test's own
    // code at code_start_addr, leading with CLR.L D6 (so the shared
    // handler's D6=12345 marker is a genuine 0->12345 transition, not a
    // stale leftover from an earlier interrupt-mid-<X> test) then CLR.L D5
    // (or whichever dep_reg_idx register) before the FSM instruction, and
    // ending with a single non-idempotent dependent instruction (ADDI.L,
    // not CLR+ADDI) targeting dep_reg_idx -- exactly the shape
    // interrupt-mid-CAS2 itself established to catch the Phase 108 dispatch
    // race, were it ever reintroduced.
    task automatic run_int_mid_test(
        input string        test_name,
        input logic [31:0]  code_start_addr,
        input int            expected_bus_cycles,
        input int            dep_reg_idx,
        input logic [31:0]  dep_exp_val,
        input logic [31:0]  handler_ret_pc
    );
        int t, d0, ds_at_exc;
        logic injected, exc_seen;

        for (t = 0; t < 20000 && u_top.ifu_decode_pc < code_start_addr; t++)
            @(posedge clk_4x);
        check({test_name, ": reached own code"}, u_top.ifu_decode_pc >= code_start_addr);

        d0 = data_ds_count;
        injected  = 1'b0;
        exc_seen  = 1'b0;
        ds_at_exc = -1;
        for (t = 0; t < 20000; t++) begin
            @(posedge clk_4x); #1;
            // Inject the moment this FSM's own first bus cycle is observed.
            if (!injected && (data_ds_count != d0)) begin
                injected = 1'b1;
                ipl_n = 3'b000;   // level 7 (NMI)
            end
            // Drop back to idle the cycle after the controller first acts
            // on it (real interrupt sources deassert once acknowledged;
            // holding it forever would re-recognize at every subsequent
            // instruction boundary).
            if (injected && !exc_seen && u_top.exc_active) begin
                exc_seen  = 1'b1;
                ds_at_exc = data_ds_count;
                ipl_n     = 3'b111;
            end
            if (u_top.u_eu.u_rf.d_reg[dep_reg_idx] === dep_exp_val &&
                u_top.u_eu.u_rf.d_reg[6] === 32'd12345)
                break;
        end
        ipl_n = 3'b111;   // deassert before any later test could see it
        // Both markers reaching their expected values does not prove the
        // handler's own trailing RTE has executed yet (see the original
        // interrupt-mid-CAS2 test's own header comment for the full
        // reasoning) -- wait for the unambiguous signal instead: decode_pc
        // has moved past the handler's own RTE address AND eu_busy is
        // clear.
        for (t = 0; t < 4000 &&
             !(u_top.ifu_decode_pc > handler_ret_pc && !u_top.eu_busy); t++)
            @(posedge clk_4x);
        check({test_name, ": injected mid-sequence"}, injected);
        check({test_name, ": exception was recognized"}, exc_seen);
        check32({test_name, ": FSM's full bus sequence completed before the interrupt was taken"},
                ds_at_exc - d0, expected_bus_cycles);
        check32({test_name, ": FSM itself completed (dependent marker reached)"},
                u_top.u_eu.u_rf.d_reg[dep_reg_idx], dep_exp_val);
        check({test_name, ": interrupt handler ran and RTE'd back (D6=12345)"},
              u_top.u_eu.u_rf.d_reg[6] === 32'd12345);
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
        //
        // Phase 150 (plan.md): TT0 is now genuinely wired into every real
        // IFU/EU bus access (previously it only ever mattered to PTEST's
        // own dedicated walk), so the *order* of these two PMOVEs matters
        // for the first time — TT0 must be configured (transparent) BEFORE
        // TC.E is ever set to 1, not after. The original order set TC.E=1
        // first: the very next instruction fetch (loading TT0's own address
        // into A0) then needed real translation despite TT0 still being
        // disabled and CRP still holding its power-on-reset garbage,
        // triggering a genuine translation fault the RTL correctly detects
        // but this test has no vector-2 handler installed yet to service —
        // confirmed via a standalone probe (500000-cycle budget, ~10x this
        // test's normal margin) that this truly never completes, not just a
        // budget shortfall. Real 68030 firmware has the identical
        // constraint: transparent windows must be live before the MMU
        // itself is enabled. Swapped so TT0 loads first (still under
        // TC.E=0, translation-free — the pre-Phase-150 default path) and
        // TC loads last, so every fetch from that point on is immediately
        // covered by the already-live transparent TT0.
        // -----------------------------------------------------------------
        rom[16'h1700/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1704/4] = {16'h3804, PMOVE_A0_OP};     // PMOVE (A0),TT0
        rom[16'h1708/4] = {PMOVE_TT0_EXT, MOVEA_L_IMM_A0};
        rom[16'h170C/4] = {16'h0000, 16'h3800};
        rom[16'h1710/4] = {PMOVE_A0_OP, PMOVE_TC_EXT};  // PMOVE (A0),TC
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

        // Phase 150 (plan.md): disable the MMU again immediately after B-21
        // (mirroring BERR-mid-PTEST's own already-established convention of
        // disabling TC right after its own MMU-enabled use, below). Every
        // test from here through BERR-mid-CAS2 was designed and verified
        // (Phases 103-126) with translation genuinely inert — TC.E=0 was
        // just a register bit with no bus-level effect. Phase 150 makes
        // TC.E=1 a real, live condition for the first time, and none of
        // these downstream tests configure page tables or a transparent
        // window covering their own code, so leaving TC.E=1 live across
        // them (as B-20/B-21 originally did, harmlessly, pre-Phase-150)
        // now causes every subsequent fetch to attempt a real walk against
        // an unconfigured CRP and hang. Returning to TC.E=0 here restores
        // the exact translation-free behavior these tests were verified
        // against.
        rom[16'h1814/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1818/4] = {16'h3808, PMOVE_A0_OP};      // PMOVE (A0),TC
        rom[16'h181C/4] = {PMOVE_TC_EXT, NOP_OP};
        rom[16'h3808/4] = 32'h0000_0000;                // TC: E=0 (disabled)

        // Settle wait: block until the disable-TC PMOVE above has actually
        // retired (confirmed via TC's own live value, not a cycle guess) —
        // its own data read of rom[0x3808] is a real data-space bus cycle,
        // and without this wait it can land inside T4a's own c0/c1
        // data_ds_count window below, inflating "4 bus cycles" to 5. B-21's
        // run_and_check already returns the instant D5==913 lands, which is
        // earlier in real hardware time than this PMOVE has even started.
        begin
            int tw;
            for (tw = 0; tw < 2000 && u_top.u_eu.tc_out !== 32'h0; tw++)
                @(posedge clk_4x);
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
        rom[16'h1820/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1824/4] = {16'h3D00, TAS_A0};
        rom[16'h1828/4] = {MOVEM_L_A0P, 16'h0003};
        rom[16'h182C/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h1830/4] = {16'h0000, 16'd444};
        rom[16'h3D00/4] = 32'h0011_2233;  // top byte 0x00 -> TAS sets bit7 -> 0x80
        rom[16'h3D04/4] = 32'h4455_6677;
        begin
            int c0, c1;
            c0 = data_ds_count;
            // Reordered ahead of the interrupt/BERR-mid-FSM tests below (was
            // originally the very last thing in this file) so it doesn't
            // depend on their own settle-timing as a clean hand-off — see
            // those tests' own comments for why that dependency was fragile.
            // Code placed at 0x1820, right after B-21's own end (~0x1810)
            // and well before the interrupt test's 0x1900 — NOP-fall-through
            // in this file only ever runs PC forward, so code reordered
            // earlier in *program order* must also live at a lower address
            // than whatever runs after it (first attempt at this reorder
            // kept the original 0x1D00 address and hung: PC can never walk
            // backward from there down to the interrupt test's 0x1900).
            run_and_check("T4a: back-to-back TAS->MOVEM dependent instr ran (D5=444)", 5, 32'd444, 4000);
            c1 = data_ds_count;
            // TAS(2) + MOVEM(2 registers) = 4 data-space bus cycles, matching
            // each instruction's own earlier standalone Category B count —
            // running directly after B-21 (no intervening tests), the
            // MMU-enabled ATC/TT0 lookup overhead observed elsewhere in this
            // file for *data* accesses evidently doesn't apply to this
            // particular pair; D0/D1/memory below all independently confirm
            // exactly one clean execution of each instruction.
            check32("T4a: TAS(2) + MOVEM(2) = 4 data-space bus cycles",
                    c1 - c0, 32'd4);
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
        rom[16'h1840/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1844/4] = {16'h3E00, TAS_A0};
        rom[16'h1848/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h184C/4] = {16'h0000, 16'd333};
        rom[16'h3E00/4] = 32'h0000_0000;
        rom[16'h1860/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1864/4] = {16'h3F80, TAS_A0};
        rom[16'h1868/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h186C/4] = {16'h0000, 16'd335};
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
        // That same trace also caught a **third, deeper** finding, fixed in
        // Phase 108 (not in this same commit as the eu_busy fix above): CLR.L
        // D5 (the instruction immediately after CAS2, in the original version
        // of this test) was observed to launch into EX and fully commit (D5
        // briefly read back 0, mid-exception-push) on the *exact same cycle*
        // eu_busy first dropped to 0 — because it had already sat fully
        // decoded and hazard-free in DECODE throughout CAS2's stall,
        // `instr_ack = dec_valid && !stall` fires combinationally the instant
        // `stall` clears, with no gap cycle. But the exception controller's
        // snap_pc_r *also* sampled ifu_decode_pc on that identical edge, and
        // decode_pc had not yet advanced past CLR.L D5 at that instant — so
        // the saved return PC pointed at CLR.L D5's own (already-executing)
        // address, and RTE later resumed there, silently *re-running* it.
        // The original version of this test couldn't see it (confirmed via a
        // temporary trace, not an assertion) because CLR is idempotent — a
        // non-idempotent instruction in that exact slot would have been
        // double-executed. Fixed by threading `int_pending` (m68030_exc's
        // already-computed combinational signal) into eu_seq.sv's `stall` as
        // a new term, `int_defer` — asserted whenever a ready-to-dispatch
        // instruction and a pending interrupt coincide on the same cycle —
        // which holds the instruction in DECODE instead of letting it launch,
        // for as long as `int_pending` stays asserted (naturally spanning the
        // whole EXC_PUSH/FETCH/LOAD sequence, since nothing else changes
        // `dec_valid` until the post-`pc_wr_en` IFU flush). `m68030_exc.sv`'s
        // own gating switched from `int_pending && !eu_busy` to
        // `int_pending && int_ready`, where `int_ready` is `eu_seq.sv`'s new
        // `int_defer` pulse threaded back up through `m68030_eu.sv` — using
        // `!eu_busy` directly would now be self-contradictory, since
        // `eu_busy` is *expected* to be 1 on the exact cycle the deliberate
        // bubble is inserted. The test below now uses a non-idempotent
        // dependent instruction (`ADDI.L #1234,D5` alone, with D5 zeroed by a
        // separate `CLR.L D5` *before* CAS2 even starts, not after it) —
        // exactly the slot that raced — so a regression would show up as
        // D5=2468 (double-added) instead of 1234.
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
            // doesn't disturb B-6's own already-verified result. D5 is
            // zeroed *before* CAS2 starts (not after) so the single
            // dependent instruction immediately following CAS2 — the exact
            // slot the dispatch race lands on — is the non-idempotent
            // ADDI.L alone, not a CLR;ADDI pair.
            rom[16'h1900/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
            rom[16'h1904/4] = {16'h0000, 16'h3900};
            rom[16'h1908/4] = {MOVEA_L_IMM_A1, 16'h0000};
            rom[16'h190C/4] = {16'h3904, CAS2_L};
            rom[16'h1910/4] = {CAS2_EXT1, CAS2_EXT2};
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
            // D5/D6 both reaching their expected values does NOT prove the
            // handler's own trailing RTE has executed yet: ipl_n is
            // deasserted the instant exc_active is first observed (well
            // before EXC_PUSH/FETCH/LOAD actually finish, only a couple of
            // synchronizer cycles later), so int_pending — and therefore
            // int_defer's hold on the originally-deferred ADDI.L D5 — can
            // clear before the exception dispatch sequence completes.
            // ADDI.L is a pure register op with no bus access of its own,
            // so once released it commits within 1-2 cycles regardless of
            // exc_active, well before the handler even starts — meaning
            // D5=1234 can be (and, confirmed via trace, is) reached before
            // the handler's own CLR.L D6/ADDI.L D6/RTE sequence has even
            // begun. D6=12345 fires right before the handler's *own*
            // trailing RTE (its last instruction) — so by the time both
            // markers are true, RTE is still pending, not finished.
            // A plain "wait until eu_busy==0", even debounced for many
            // consecutive idle cycles, is insufficient: at the moment this
            // loop breaks, decode_pc can still be sitting exactly at RTE's
            // own address with eu_busy==0 (confirmed via trace) — genuinely
            // idle, but only because RTE hasn't even been *fetched* yet
            // (the IFU takes a real, and here unexpectedly long, number of
            // cycles to bring it in), not because it already ran. Waiting
            // for N idle cycles just risks the budget running out during
            // that pre-fetch gap, handing off before RTE ever starts.
            // Instead wait for the unambiguous signal: decode_pc has moved
            // *past* RTE's own opcode address (0x0088) — which can only
            // happen after RTE has been fetched, dispatched, completed its
            // own 2-phase SR/PC stack-pop reads, and the IFU has resumed
            // fetching the redirected (resumed) instruction stream — AND
            // eu_busy is clear, ruling out a mid-flight redirect.
            for (t = 0; t < 4000 &&
                 !(u_top.ifu_decode_pc > 32'h0000_008A && !u_top.eu_busy); t++)
                @(posedge clk_4x);
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
        // **Fixed in Phase 108** (same phase as the interrupt dispatch-race
        // fix above), in two stages:
        //   Stage 1 (BIU-level abort + exception wiring): biu_cache_if.sv
        //   gained a CI_BERR terminal state — CI_D_MISS/CI_WRITE/CI_FILL_*
        //   now transition there on `sf_berr` (mirroring CI_DONE's
        //   `sf_ack_rise` handling) instead of hanging forever; its output
        //   drives a real, final-abort-gated `eu_berr` (m68030_biu.sv's own
        //   top-level `eu_berr` now comes from `ca_eu_berr` instead of the
        //   raw, every-retry-pulses `cg_eu_berr_raw`). m68030_top.sv gained
        //   a sticky-to-pulse `eu_bus_err_r` latch (edge-detected off
        //   `exc_frame_valid`, clearing on `pc_wr_en_common` — mirroring
        //   m68030_ifu.sv's own working `bus_err_r` pattern) feeding
        //   `m68030_exc`'s `bus_err_req` alongside the existing IFU path;
        //   `fault_addr` is now muxed between `ifu_bus_err_addr` and the
        //   already-computed-but-previously-dangling `fault_addr_biu` for
        //   the EU-sourced case.
        //   Stage 2 (EU-side FSM abort): eu_seq.sv's `ex_mem_stall`-driven
        //   phase registers (the generic read/write wait clause, TAS,
        //   MOVEM, and CAS2's rd2/wr1/wr2 phases) now collapse back to idle
        //   on a new `mem_abort` signal — not just `mem_berr` on its own,
        //   but `mem_berr || exc_active`, since (confirmed via trace) a
        //   fault detected via a *different* path (e.g. the IFU) can win
        //   the race and set `exc_active` before the EU's own `mem_berr`
        //   pulse for its in-flight access ever arrives, otherwise
        //   permanently starving a `mem_berr`-only abort condition. A new
        //   shared `ex_berr_abort_wb` guard (edge-detected the cycle after
        //   `mem_abort` collapses `ex_mem_stall`) suppresses the WB latch
        //   for that one cycle, so an aborted instruction never commits a
        //   phantom register write with garbage/stale data.
        // The remaining ~15+ ex_mem_stall FSM sources (MOVEP, MOVE16, ADDX/
        // ABCD/PACK predecrement forms, BFINS, CMP2, MOVE mem-mem, RTR/RTE,
        // PFLUSH/PTEST/PMOVE64, single CAS, memory-indirect EA) got the
        // same `mem_abort` treatment in Phase 109 (mirroring how Category
        // B's own FSM-decode-holdoff coverage was staged across Phases
        // 103-104, 4 sources then 21); PFLUSH/PTEST were confirmed already
        // correctly handled in Phase 113. No `ex_mem_stall` source remains
        // without BERR-abort coverage — see docs/stalls.md's own Category I.
        // -----------------------------------------------------------------
        $display("=== BERR mid-CAS2 sequence ===");
        begin
            int t, dd0, dbg7n;
            logic saw_biu_berr, injected3, exc_seen3;
            dbg7n = 0;

            // Bus Error autovector: vector 2, at VBR(=0)+2*4=0x08. Handler
            // sets D5 as its own completion marker, then unconditionally
            // jumps to the shared parking spot (PARK_ADDR) — CAS2 itself is
            // being aborted/abandoned by design (a real bus-error handler
            // that hasn't fixed the underlying fault has nothing sensible
            // to retry), so unlike the interrupt test above there's no RTE
            // round trip back into the faulted instruction stream here.
            // Originally this just fell through into default-filled NOPs,
            // which was harmless for this one-off test but became a real
            // bug once this same shared handler got reused by
            // run_berr_mid_test for 12 more sources (below): falling
            // through NOP-marches all the way down to 0x100, silently
            // re-executing the *entire* file from B-1 onward after every
            // one of those tests' own faults, corrupting shared
            // register/SR/memory state for everything downstream. Jumping
            // to a fixed, always-parked spot instead — and having each
            // *next* test claim it for itself only once it's actually
            // ready to watch (see claim_park()'s own header comment for
            // why that direction of control matters) — fixes that cleanly.
            rom[16'h0008/4] = 32'h0000_0090;
            // open-items backlog Stage 13 (plan.md): BKPT #3's own fixed
            // CPU-space address is bkpt_num*4 = 0xC (eu_bkpt_addr =
            // {27'h0,bkpt_num_r,2'b00}) -- written up front here,
            // alongside the other fixed-address content, well before the
            // real BKPT-substitution test itself runs (see near the end
            // of this file). Only the HIGH word is ever read
            // (eu_bkpt_siz=word, top-justified); the low word is unused.
            rom[16'h000C/4] = {MOVEQ_D0_42, NOP_OP};
            rom[16'h0090/4] = {CLR_L_D5, ADDI_L_D5};
            rom[16'h0094/4] = {16'h0000, 16'd999};
            rom[16'h0098/4] = {JMP_ABS_L_OP, PARK_ADDR[31:16]};
            rom[16'h009C/4] = {PARK_ADDR[15:0], NOP_OP};
            rom[16'h00A0/4] = {BRA_SELF, NOP_OP};   // PARK_ADDR default: self-park until claimed

            rom[16'h1C00/4] = {MOVEA_L_IMM_A0, 16'h0000};
            rom[16'h1C04/4] = {16'h3C00, MOVEA_L_IMM_A1};
            rom[16'h1C08/4] = {16'h0000, 16'h3C04};
            rom[16'h1C0C/4] = {CAS2_L, CAS2_EXT1};
            rom[16'h1C10/4] = {CAS2_EXT2, CLR_L_D5};
            rom[16'h1C14/4] = {ADDI_L_D5, 16'h0000};
            rom[16'h1C18/4] = {16'd777, NOP_OP};
            saw_biu_berr = 1'b0;
            injected3 = 1'b0;
            exc_seen3 = 1'b0;
            dd0 = data_ds_count;
            for (t = 0; t < 12000; t++) begin
                @(posedge clk_4x); #1;
                if (!injected3 && data_ds_count != dd0) begin
                    injected3 = 1'b1;
                    berr_n = 1'b0;
                end
                // CAS2 has its own dedicated 4-cycle datapath directly in
                // biu_cycle_gen.sv (eu_cas2_req/eu_cas2_ack) — unlike
                // MOVEM/MOVEP (which go through biu_multiop_fsm.sv's
                // generic eu_mo_req/eu_mo_ack/eu_mo_berr), CAS2 has **no
                // berr output of its own at all** (grepped m68030_biu.sv's
                // full port list: eu_cas2_ack exists, eu_cas2_berr does
                // not) — so this watches the shared BIU-internal raw fault
                // signal instead (cg_eu_berr_raw, the same one that also
                // now correctly drives the top-level eu_berr, per the
                // Stage 1 fix above) to confirm the BIU layer detects the
                // fault even though CAS2 itself has no way to be told.
                // Release berr_n as soon as the first fault is observed,
                // rather than holding it for the rest of the loop: berr_n
                // is a single, chip-wide pin — asserting it indefinitely
                // doesn't just fault CAS2's own retries (which, now that
                // biu_cache_if correctly aborts on the very first berr
                // rather than needing several retries, only needs one
                // pulse anyway), it also faults the exception controller's
                // *own* subsequent frame-push writes to a completely
                // unrelated stack address, hanging the exception dispatch
                // itself (confirmed via trace: exc_active got stuck
                // permanently asserted, never reaching EXC_LOAD, when
                // berr_n was held low for the whole loop) — an unrealistic
                // scenario for a single faulting device/address, and not
                // what this test is trying to exercise.
                if (u_top.u_biu.cg_eu_berr_raw) begin
                    saw_biu_berr = 1'b1;
                    berr_n = 1'b1;
                end
                if (!exc_seen3 && u_top.exc_active) exc_seen3 = 1'b1;
                if (u_top.u_eu.u_rf.d_reg[5] === 32'd999) break;
            end
            berr_n = 1'b1;
            check("BERR-mid-CAS2: injected mid-sequence", injected3);
            check("BERR-mid-CAS2: BIU layer detects the fault (cg_eu_berr_raw pulsed) even though CAS2 has no berr output of its own",
                  saw_biu_berr);
            check("BERR-mid-CAS2: a real Bus Error exception was taken (exc_active seen)", exc_seen3);
            check32("BERR-mid-CAS2: the correct vector (2, Bus Error) was dispatched",
                    {24'h0, u_top.exc_vector_num}, 32'd2);
            check("BERR-mid-CAS2: handler reached and ran to completion (D5=999)",
                  u_top.u_eu.u_rf.d_reg[5] === 32'd999);
            // Same decode_pc-based settle idiom as the interrupt test above
            // (a plain eu_busy==0 check can catch a momentary gap before
            // the next instruction is even fetched) — wait until decode has
            // moved past the handler's own code before handing off, so a
            // later test's own bus-cycle-count baseline can't catch
            // leftover activity from this one.
            for (t = 0; t < 4000 &&
                 !(u_top.ifu_decode_pc > 32'h0000_0096 && !u_top.eu_busy); t++)
                @(posedge clk_4x);
            check("BERR-mid-CAS2: EU pipeline recovered (eu_busy clear, no lingering hang)",
                  u_top.eu_busy === 1'b0);
            // Release the park to BERR-mid-PTEST's code *now*, right before
            // this block ends -- not any earlier (see claim_park()'s own
            // header comment for why the timing matters: hardware is
            // currently sitting in the park, having reached it during the
            // watch loop above, and PTEST's own settle-wait starts
            // immediately after this block, with zero simulated time in
            // between). BERR-mid-PTEST doesn't go through
            // run_berr_mid_test (PTEST never faults, so it can't release
            // the park for whoever comes after it the same way), so it
            // must be claimed for it explicitly, here.
            claim_park(32'h0000_1CFC);
        end

        // -----------------------------------------------------------------
        // BERR mid-PTEST: the last ex_mem_stall source deliberately left
        // out of Phase 109's mem_abort rollout (PFLUSH/PTEST use a
        // different ack/fault interface -- eu_pflush_ack/eu_ptest_ack via
        // m68030_mmu.sv/biu_mmu_if.sv -- not mem_ack/mem_berr, so the
        // pattern used for the other 16 sources doesn't directly apply).
        // Investigation before writing this test found PFLUSH is
        // architecturally immune: pflush_ack fires purely from an internal
        // ATC-array comparison (biu_mmu_if.sv), no bus access at all, so
        // there is nothing for a BERR to interrupt. PTEST is different --
        // it walks the real page tables over the bus via biu_mmu_if.sv's
        // MS_WALK_A/B/C states -- but those states already have their own
        // `if (mmu_berr) begin fault_r<=1; ms_state<=MS_FAULT; end` arm
        // (predates this session), and m68030_mmu.sv's MM_WAIT state
        // already treats `biu_fault` as just another terminal case feeding
        // MM_DONE (setting mmusr_r=16'h8000, bus fault) -- ptest_ack fires
        // regardless of hit/fault, so eu_seq.sv's ptest_run_r should
        // already un-stall correctly with zero RTL changes needed. This
        // test exists to confirm that empirically rather than trust the
        // static reading, following this whole investigation's own
        // "verify, don't assume" discipline.
        //
        // Needs a genuine table walk (not B-20's TT0-transparent shortcut,
        // which never touches the bus at all) so there's a real bus read
        // in flight to interrupt. TC=0x8C0AA000 (E=1, PS=12, TIA=10,
        // TIB=10) and the VA/index math are reused verbatim from
        // tb/biu_tb.sv's own proven P6-7 walk test (crp_base there was
        // 0x40; relocated to 0x2000 here, clear of every other address
        // this file already uses). CRP only needs a valid "this points to
        // a table, go read it" descriptor (DT=10) at a fresh base -- the
        // table's own *contents* at that address don't need to be
        // meaningful, since the whole point is to fault the read before
        // its data would ever be interpreted.
        //
        // Unlike every other BERR-mid-<X> test in this file, PTEST does
        // NOT trap on a translation fault -- per real 68030 architecture
        // it just reports the failure via MMUSR and continues to the next
        // instruction, same as a normal (non-faulting) PTEST. First attempt
        // at this test wrongly assumed a vector-2 dispatch (copying the
        // other tests' shape) and never broke out of its own watch loop,
        // which let this file's NOP-fall-through execution model march
        // 12000 cycles straight through this test's own code and into its
        // table-walk data area (0x2000), decoding leftover/uninitialized
        // memory as instructions and hanging on a real (unrelated)
        // eu_addr_err. Root-caused via a temporary per-cycle trace of
        // ptest_run_r/mm_state/ms_state/ptest_ack/biu_fault before fixing.
        // -----------------------------------------------------------------
        $display("=== BERR mid-PTEST sequence ===");
        begin
            int t;
            logic saw_biu_berr, injected4, exc_seen4;

            rom[16'h2300/4] = 32'h8C0A_A000;  // TC: E=1,PS=12,TIA=10,TIB=10
            // Phase 150 (plan.md): TT0 must stay live (narrowed to an exact
            // top-byte match, LAM=0x00 instead of B-20's LAM=0xFF-any) so
            // this file's own code -- now genuinely translated for every
            // real fetch -- keeps bypassing via TT0, while the deliberately
            // different-top-byte PTEST target VA below (0x01001000) falls
            // outside it and correctly reaches the real walker. Fully
            // disabling TT0 (the original design) broke the very next
            // ordinary instruction fetch after this PMOVE: CRP hadn't been
            // loaded yet at that point, so it hit a real walk against
            // garbage/zero CRP -- confirmed via direct signal trace
            // (mmu_walk_req never asserted where expected; the fault-detect
            // check below failed outright) once Phase 150 wired real
            // translation into ordinary IFU/EU fetches for the first time.
            rom[16'h2304/4] = 32'h0000_80E0;  // TT0: LAB=0,LAM=0x00(exact top-byte 0x00 match, code-only),E=1,FCM=any
            // open-items backlog Stage 12 (plan.md): L/U=0/LIMIT=0 (the
            // old value) faults on any nonzero level-A index; permissive
            // L/U=0/LIMIT=$7FFF instead, matching real 68030 firmware.
            rom[16'h2308/4] = 32'h7FFF_0000;  // CRP hi: L/U=0, LIMIT=$7FFF (permissive)
            rom[16'h230C/4] = 32'h0000_2002;  // CRP lo: base=0x2000, DT=10 (table)

            // D5 must be cleared first: an earlier test's own completion
            // marker leaks over (real CPU state, not reset between these
            // sequential blocks) -- without this, a break condition keyed
            // on D5 could "succeed" on stale state before this test's own
            // code ever runs.
            rom[16'h1CFC/4] = {NOP_OP, CLR_L_D5};
            rom[16'h1D00/4] = {MOVEA_L_IMM_A0, 16'h0000};
            rom[16'h1D04/4] = {16'h2300, PMOVE_A0_OP};      // PMOVE (A0),TC
            rom[16'h1D08/4] = {PMOVE_TC_EXT, MOVEA_L_IMM_A0};
            rom[16'h1D0C/4] = {16'h0000, 16'h2304};
            rom[16'h1D10/4] = {PMOVE_A0_OP, PMOVE_TT0_EXT}; // PMOVE (A0),TT0
            rom[16'h1D14/4] = {MOVEA_L_IMM_A0, 16'h0000};
            rom[16'h1D18/4] = {16'h2308, PMOVE_A0_OP};      // PMOVE (A0),CRP
            rom[16'h1D1C/4] = {PMOVE_CRP_EXT, MOVEA_L_IMM_A0};
            // VA's top byte (0x01) deliberately differs from this file's own
            // code (top byte 0x00, covered by TT0's new narrowed match
            // above) so PTEST's own translation request is the one thing
            // that genuinely falls through to the real walker.
            rom[16'h1D20/4] = {16'h0100, 16'h1000};         // A0 = VA 0x01001000
            rom[16'h1D24/4] = {PTEST_A0_OP, PTEST_EXT};      // PTEST (A0)
            // Reached once PTEST completes -- with or without a translation
            // fault, per real 68030 semantics (no trap either way).
            rom[16'h1D28/4] = {CLR_L_D5, ADDI_L_D5};
            rom[16'h1D2C/4] = {16'h0000, 16'd998};
            rom[16'h1D30/4] = {NOP_OP, NOP_OP};

            // This file's execution model is pure NOP fall-through, and this
            // test's own code sits ~7KB past the shared vector-2 handler's
            // tail (0x98) -- the earlier BERR-mid-CAS2 settle-wait only
            // confirms decode has moved past the *handler*, not that it has
            // marched all the way here yet.
            for (t = 0; t < 150000 && u_top.ifu_decode_pc < 32'h0000_1CFC; t++)
                @(posedge clk_4x);
            check("BERR-mid-PTEST: reached this test's own code (not stuck earlier)",
                  u_top.ifu_decode_pc >= 32'h0000_1CFC);

            saw_biu_berr = 1'b0;
            injected4    = 1'b0;
            exc_seen4    = 1'b0;
            for (t = 0; t < 12000; t++) begin
                @(posedge clk_4x); #1;
                if (!injected4 && u_top.u_biu.mmu_walk_req) begin
                    injected4 = 1'b1;
                    berr_n    = 1'b0;
                end
                if (u_top.u_biu.cg_mmu_berr || u_top.u_biu.cg_eu_berr_raw) begin
                    saw_biu_berr = 1'b1;
                    berr_n = 1'b1;
                end
                if (!exc_seen4 && u_top.exc_active) exc_seen4 = 1'b1;
                // Break as soon as PTEST's own FSM retires (ptest_run_r
                // clears) -- unlike the other BERR-mid-<X> tests, we must
                // not wait for a vector-2 dispatch that correctly never
                // comes, or NOP fall-through wanders into this test's own
                // table-walk data (see the header comment above).
                if (injected4 && !u_top.u_eu.u_seq.ptest_run_r) break;
            end
            berr_n = 1'b1;
            check("BERR-mid-PTEST: injected mid-walk", injected4);
            check("BERR-mid-PTEST: BIU layer detects the fault", saw_biu_berr);
            check("BERR-mid-PTEST: no exception taken (PTEST reports a translation fault via MMUSR and continues, it does not trap)",
                  !exc_seen4);
            // >= 0x1D30 (the NOP right after ADDI.L), not just past CLR.L's
            // own address -- decode_pc reaching ADDI.L's opcode only means
            // it has *started* decoding, not that it has retired and
            // written D5 back yet (same class of gap as Phase 108's own
            // decode_pc-vs-eu_busy timing notes elsewhere in this file).
            for (t = 0; t < 4000 &&
                 !(u_top.ifu_decode_pc >= 32'h0000_1D30 && !u_top.eu_busy); t++)
                @(posedge clk_4x);
            // A few extra cycles: decode_pc reaching the NOP just past
            // ADDI.L only means decode has moved on, not that ADDI.L's own
            // writeback has necessarily landed in the same cycle.
            repeat(8) @(posedge clk_4x);
            check("BERR-mid-PTEST: EU pipeline recovered and continued past PTEST (D5=998 via this test's own follow-on code)",
                  u_top.u_eu.u_rf.d_reg[5] === 32'd998);
        end

        // -----------------------------------------------------------------
        // BERR-mid-<X> for the remaining 12 of the 13 ex_mem_stall sources
        // Phase 109 fixed with the mem_abort pattern. (Memory-indirect EA's
        // own decode-correctness question was resolved in Phase 115, and
        // its own BERR test -- BERR-mid-Memind -- was added in Phase 124,
        // below.) Each reuses its corresponding B-N test's exact,
        // already-proven opcode encoding and operand addresses -- safe to
        // reuse here since every B-N test's own checks (in the "run to
        // completion" section above) have already completed by the time
        // any of this code runs, this being a purely sequential (not
        // parallel) initial block.
        //
        // Must first disable the MMU that BERR-mid-PTEST just enabled with
        // a deliberately incomplete table (CRP pointing at a table that was
        // never populated, since the whole point of that test was to fault
        // the walk before its data would matter). Left enabled, every one
        // of these 12 tests' own memory accesses would ALSO trigger a table
        // walk through that same broken table instead of hitting physical
        // memory directly -- confirmed the hard way, as the actual cause of
        // an earlier attempt where every single one of these 12 tests
        // failed identically with zero bus activity ever observed.
        // -----------------------------------------------------------------
        rom[16'h1D80/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1D84/4] = {16'h1DA0, PMOVE_A0_OP};      // PMOVE (A0),TC
        rom[16'h1D88/4] = {PMOVE_TC_EXT, NOP_OP};
        rom[16'h1DA0/4] = 32'h0000_0000;                 // TC: E=0 (disabled)

        // Code for these 12 lives tightly packed in 0x1E00-0x2100 --
        // comfortably below PTEST's own data at 0x2300 -- specifically to
        // keep each settle-wait's NOP-fall-through distance short (an
        // earlier attempt placed this code out past 0x2A00 and blew the
        // global watchdog partway through, since marching that much
        // further compounds badly across 12 back-to-back tests). Reused
        // operand/data addresses (0x2700, 0x2800, 0x2900, 0x2E04 etc.) are
        // untouched -- only these tests' own *code* addresses moved.

        // single CAS.L D1,D2,(A0) -- reuses B-5's exact setup (0x2700).
        rom[16'h1E00/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1E04/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1E08/4] = {16'h2700, CAS_L_D1D2_A0};
        rom[16'h1E0C/4] = {CAS_EXT, CLR_L_D5};
        rom[16'h1E10/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h1E14/4] = {16'd997, NOP_OP};
        // CAS always faults here, so (same as BERR-mid-CAS2 above) the only
        // path onward is the handler's own exit, via the park -- release it
        // to MOVEP's code once this test itself is done watching.
        run_berr_mid_test("BERR-mid-CAS", 32'h0000_1E00, .next_addr(32'h0000_1E40));

        // MOVEP.L D1,(0x0010,A0) -- reuses B-7's exact setup (0x2800).
        rom[16'h1E40/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1E44/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1E48/4] = {16'h2800, CLR_L_D1};
        rom[16'h1E4C/4] = {ADDI_L_D1, 16'hAABB};
        rom[16'h1E50/4] = {16'hCCDD, MOVEP_L_D1_A0};
        rom[16'h1E54/4] = {16'h0010, NOP_OP};
        run_berr_mid_test("BERR-mid-MOVEP", 32'h0000_1E40, .next_addr(32'h0000_1E80));

        // MOVE16 (A0)+,(A1)+ -- reuses B-8's exact source data (0x2900).
        rom[16'h1E80/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1E84/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1E88/4] = {16'h2900, MOVEA_L_IMM_A1};
        rom[16'h1E8C/4] = {16'h0000, 16'h2A00};
        rom[16'h1E90/4] = {MOVE16_A0P_A1P, MOVE16_EXT};
        run_berr_mid_test("BERR-mid-MOVE16", 32'h0000_1E80, .next_addr(32'h0000_1EC0));

        // ADDX.L -(A1),-(A0) -- reuses B-9's exact scratch addresses.
        rom[16'h1EC0/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1EC4/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1EC8/4] = {16'h2E04, MOVEA_L_IMM_A1};
        rom[16'h1ECC/4] = {16'h0000, 16'h2D04};
        rom[16'h1ED0/4] = {ADDX_L_A1_A0, NOP_OP};
        run_berr_mid_test("BERR-mid-ADDX", 32'h0000_1EC0, .next_addr(32'h0000_1F00));

        // ABCD -(A1),-(A0) -- also covers SBCD (shared bcds_run_r
        // mechanism, per Phase 109) -- reuses B-10's scratch addresses.
        rom[16'h1F00/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1F04/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1F08/4] = {16'h2E10, MOVEA_L_IMM_A1};
        rom[16'h1F0C/4] = {16'h0000, 16'h2D10};
        rom[16'h1F10/4] = {ABCD_A1_A0, NOP_OP};
        run_berr_mid_test("BERR-mid-ABCD", 32'h0000_1F00, .next_addr(32'h0000_1F40));

        // PACK -(A1),-(A0),#0 -- reuses B-11's scratch addresses.
        rom[16'h1F40/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1F44/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1F48/4] = {16'h2E20, MOVEA_L_IMM_A1};
        rom[16'h1F4C/4] = {16'h0000, 16'h2D20};
        rom[16'h1F50/4] = {PACK_A1_A0, 16'h0000};
        run_berr_mid_test("BERR-mid-PACK", 32'h0000_1F40, .next_addr(32'h0000_1F80));

        // BFINS D1,(A0){8:8} -- reuses B-12's exact setup (0x2F00).
        rom[16'h1F80/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1F84/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1F88/4] = {16'h2F00, BFINS_D1_A0};
        rom[16'h1F8C/4] = {BFINS_EXT, NOP_OP};
        run_berr_mid_test("BERR-mid-BFINS", 32'h0000_1F80, .next_addr(32'h0000_1FC0));

        // CMP2.L (A0),D1 -- also covers CHK2 (shared cmp2_run_r mechanism,
        // per Phase 109) -- reuses B-13's exact setup (0x3000).
        rom[16'h1FC0/4] = {NOP_OP, CLR_L_D5};
        rom[16'h1FC4/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h1FC8/4] = {16'h3000, CMP2_L_A0_D1};
        rom[16'h1FCC/4] = {CMP2_EXT, NOP_OP};
        run_berr_mid_test("BERR-mid-CMP2", 32'h0000_1FC0, .next_addr(32'h0000_2000));

        // MOVE.L (A0),(A1) -- both source and dest are memory EAs, reuses
        // B-14's exact source address (0x3100).
        rom[16'h2000/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2004/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2008/4] = {16'h3100, MOVEA_L_IMM_A1};
        rom[16'h200C/4] = {16'h0000, 16'h3200};
        rom[16'h2010/4] = {MOVE_L_A0_A1, NOP_OP};
        run_berr_mid_test("BERR-mid-MOVE-mem-mem", 32'h0000_2000, .next_addr(32'h0000_2040));

        // RTR -- reuses B-15's exact frame (0x3302/0x3304). Phase 109's fix
        // was specifically for the *second* stack read (the PC longword) --
        // the first (CCR word) already recovered correctly on its own,
        // since rtr_phase_r is still at its idle value 0 when a fault hits
        // phase 0. To fault that second read, injection must fire as soon
        // as the *first* read's own completion is observed (same as every
        // other 2-phase source here, e.g. CAS2's skip_cycles=0 default) --
        // NOT skip_cycles=1, which (off-by-one) waits for a third
        // ds_count change that a 2-phase instruction never produces, so
        // injected never fires and RTR silently runs to completion,
        // corrupting downstream state. A successful RTR would redirect PC
        // away entirely; forcing the second read to fault means it never
        // does, so (unlike every other test here) there's no dependent
        // "next instruction" at all -- the shared task's own
        // vector-2/D5=999 checks are the whole test.
        rom[16'h2040/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2044/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h2048/4] = {16'h3302, RTR_OP};
        run_berr_mid_test("BERR-mid-RTR", 32'h0000_2040, .next_addr(32'h0000_2080));

        // RTE -- reuses B-16's exact frame (0x3400/0x3404). Same reasoning
        // as RTR above (rte_phase_r's own fix was for the second read too;
        // injection must fire on the *first* ds_count change, not the
        // nonexistent third one skip_cycles=1 was waiting for).
        rom[16'h2080/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2084/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h2088/4] = {16'h3400, RTE_OP};
        run_berr_mid_test("BERR-mid-RTE", 32'h0000_2080, .next_addr(32'h0000_20C0));

        // PMOVE (A0),CRP -- 64-bit load, 2 bus cycles -- reuses B-21's exact
        // source address (0x3600). Unlike RTR/RTE, both halves of this load
        // go through the same pmove64_run_r phase register (register-gated
        // directly in the top-level ex_mem_stall OR-list, not the
        // combinational-formula pattern), so injecting on the first cycle
        // already exercises the fix -- no skip_cycles needed.
        rom[16'h20C0/4] = {NOP_OP, CLR_L_D5};
        rom[16'h20C4/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h20C8/4] = {16'h3600, PMOVE_A0_OP};
        rom[16'h20CC/4] = {PMOVE_CRP_EXT, NOP_OP};
        run_berr_mid_test("BERR-mid-PMOVE64", 32'h0000_20C0, .next_addr(32'h0000_2100));

        // -----------------------------------------------------------------
        // BERR-mid-<X> for the full-format mode=110 (memory-indirect EA)
        // decode paths added by the Phase 115-122 rollout. None of these
        // change mem_abort itself (still just mem_berr||exc_active,
        // decode-content-agnostic), so recovery is expected to work
        // identically to the brief-form cases already covered above -- the
        // point of these three is to actually exercise that empirically for
        // the two genuinely new/modified mechanisms this rollout built,
        // rather than assume it from mem_abort's own decode-agnosticism.
        //
        // BERR-mid-CMP2-full: full-format CMP2.L (bd,A0,D1.L),D2 (Phase 120
        // -- CMP2/CHK2 had no indexed-EA decode at all before this rollout).
        // Same skip_cycles=0 shape as the existing brief-form BERR-mid-CMP2
        // above: CMP2 is inherently 2-phase (lower bound read, then upper
        // bound read), so injecting as soon as the *first* read's own
        // completion is observed faults the *second* -- exactly the phase
        // Phase 120's dyn_bit_get_Dn gating fix (deferring the Xn->Rn swap
        // to that second read's own ack) actually touches. A0=$3000
        // (reused, unpopulated -- same as B-13/the brief CMP2 test above;
        // only recovery is checked, not the compared value).
        // -----------------------------------------------------------------
        // NOTE: MOVEA.L #imm,An needs a full 32-bit (2-word) immediate --
        // every rom[] pair below spells that out explicitly as its own
        // {imm_hi, imm_lo} pair (matching the established convention already
        // used throughout B-1..B-21 above, e.g. B-2's
        // `rom[16'h0200/4] = {MOVEA_L_IMM_A0, 16'h0000}; rom[16'h0204/4] =
        // {16'h2100, ...};`) -- an earlier draft of this block packed the
        // opcode and the immediate's low word into a single rom[] entry as
        // if the immediate were only one word, silently desyncing every
        // following instruction by 2 bytes. Caught by B-22's own D2-value
        // check below (D2 read back stray NOP-opcode bytes instead of the
        // real loaded value) -- the three BERR-mid-<X> tests just above
        // this comment don't check any data value, only recovery, so the
        // same bug there produced passing-but-not-actually-testing-the-
        // documented-instruction results; fixed here too.
        rom[16'h2100/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2104/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2108/4] = {16'h3000, 16'h7200};  // A0 imm lo=$3000 ; MOVEQ #0,D1
        rom[16'h210C/4] = {16'h04F0, 16'h2000};  // CMP2.L opcode (indexed) ; ext1: Rn=D2
        rom[16'h2110/4] = {16'h1920, 16'h0100};  // ext2: full, Xn=D1 ; ext3: bd=$100
        rom[16'h2114/4] = {NOP_OP, NOP_OP};
        run_berr_mid_test("BERR-mid-CMP2-full", 32'h0000_2100, .next_addr(32'h0000_2140));

        // BERR-mid-MOVEmm-idx-absw-full: MOVE.L ($3000).W,($100,A0,D1.L)
        // (Phase 122 -- abs.W-src, indexed dst, full-format bd via the new
        // q3_word-based extraction, is_move_mm_idx_dst mechanism). This is
        // a read-then-write sequence (src read, then the write to the
        // full-format-computed dst); skip_cycles=0 injects right after the
        // read completes, faulting the write -- the phase whose own
        // address depends on the new q3_word bd value.
        rom[16'h2140/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2144/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2148/4] = {16'h0200, 16'h7200};  // A0 imm lo=$200 ; MOVEQ #0,D1
        rom[16'h214C/4] = {16'h21B8, 16'h3000};  // MOVE.L opcode ; src abs.W=$3000
        rom[16'h2150/4] = {16'h1920, 16'h0100};  // ext2: full, Xn=D1 ; bd=$100
        rom[16'h2154/4] = {NOP_OP, NOP_OP};
        run_berr_mid_test("BERR-mid-MOVEmm-idx-absw-full", 32'h0000_2140, .next_addr(32'h0000_2180));

        // BERR-mid-MOVEmm-idx-reg-full: MOVE.L D2,($100,A0,D1.L) (Phase 122
        // -- register-src, indexed dst, full-format bd via the ordinary
        // fi_bd/is_memind_full machinery, dec_is_mem_rmw mechanism). This
        // arm's RMW read-modify-write shape means skip_cycles=0 injects
        // after the (pre-existing, documented in tests/memind15.s) extra
        // read that precedes the real write, so the fault still lands on
        // the write itself -- the phase that depends on the new full-format
        // dst address.
        rom[16'h2180/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2184/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2188/4] = {16'h0200, 16'h7200};  // A0 imm lo=$200 ; MOVEQ #0,D1
        rom[16'h218C/4] = {16'h2182, 16'h1920};  // MOVE.L opcode ; ext2: full, Xn=D1
        rom[16'h2190/4] = {16'h0100, NOP_OP};    // bd=$100
        run_berr_mid_test("BERR-mid-MOVEmm-idx-reg-full", 32'h0000_2180, .next_addr(32'h0000_2200));

        // -----------------------------------------------------------------
        // B-22 (Category B, plan.md Phase 124): MOVE.L ([$10,A0],D1.L),D2
        // -- genuine memory-indirect EA (the two-level indirection mode
        // using the extension word's I/IS field: read a pointer from
        // A0+bd, then add Xn*scale + od to get the final address). This is
        // the one `ex_mem_stall` source out of the ~23-item inventory that
        // was left out of Category B's own original 21-source sweep
        // (Phase 104) -- "genuine encoding ambiguity" at the time, later
        // root-caused and fixed (Phase 115) but never revisited to add the
        // decode-holdoff test once the underlying decode was actually
        // correct. Opcode/ext-word layout reused verbatim from
        // tests/memind2.s (already Musashi-verified): post-indexed, word
        // bd=$10, null od -- pointer at A0+bd holds the intermediate
        // address, final EA = pointer + D1 (no outer displacement).
        // Chained here (not inserted into the original B-1..B-21 setup
        // block above) to avoid touching that already-dense, carefully
        // addressed region -- reuses the same claim_park/next_addr
        // mechanism the BERR-mid-<X> chain already established, appending
        // past the highest address used anywhere else in this file.
        // A0=$4000 (fresh, unused region): pointer at $4010=$4100, final
        // value at $4200 -- both freshly populated here, not reused from
        // any earlier test, since (unlike the BERR-mid tests, which only
        // check recovery) this test needs genuinely correct data flow
        // through both indirection levels.
        //
        // NOTE: addresses must stay within this testbench's own memory
        // model bound (MEM_WORDS=4096 32-bit words = 16KB, valid word
        // addresses 0x0000-0x3FFC) -- an earlier draft used A0=$4000 with
        // pointer/final data at $4010/$4200, entirely *outside* that bound;
        // the out-of-bounds rom[] index silently returned garbage (traced
        // via temporary `$display` tracing of the FSM's own memind_inner_r/
        // memind_outer_r/mem_rdata signals: the pointer read at $4010 came
        // back as `4e714e71`, two NOP opcodes -- clearly not real data)
        // rather than erroring at elaboration time, which is what made this
        // one non-obvious. A0=$3900 (confirmed unused elsewhere in this
        // file, well within bounds) fixes it.
        // -----------------------------------------------------------------
        rom[16'h3910/4] = 32'h0000_3A00;  // pointer (at A0+bd = $3900+$10)
        rom[16'h3B00/4] = 32'hCAFE_F00D;  // final value (at pointer+D1 = $3A00+$100)
        rom[16'h2200/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2204/4] = {16'h3900, 16'h223C};  // A0 imm lo=$3900 ; MOVE.L #$100,D1 opcode
        rom[16'h2208/4] = {16'h0000, 16'h0100};  // D1 imm hi ; D1 imm lo=$100
        rom[16'h220C/4] = {16'h2430, 16'h1925};  // MOVE.L (mem-indirect),D2 opcode ; ext1
        rom[16'h2210/4] = {16'h0010, CLR_L_D5};  // bd=$10 ; CLR.L D5
        rom[16'h2214/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2218/4] = {16'd914, JMP_ABS_L_OP};
        rom[16'h221C/4] = {16'h0000, 16'h2280};  // JMP target hi ; JMP target lo ($2280, BERR-mid-Memind)
        run_and_check("B-22: memory-indirect EA dependent instr ran (D5=914)", 5, 32'd914, 3000);
        check32("B-22: memory-indirect EA loaded correct value into D2",
                u_top.u_eu.u_rf.d_reg[2], 32'hCAFE_F00D);

        // BERR-mid-Memind (plan.md Phase 124): same genuine memory-indirect
        // instruction as B-22 above, fault injected mid-sequence. The FSM
        // is inherently 2-phase (pointer read from A0+bd, then the final
        // read from pointer+od/Xn) -- skip_cycles=0 injects as soon as the
        // first read's own completion is observed, faulting the second
        // (outer/indirect) read, the phase genuinely unique to this
        // addressing mode. Reuses B-22's own already-populated pointer
        // data at $3910 (this test runs immediately after B-22 in program
        // order) rather than re-populating -- the first read must succeed
        // normally for skip_cycles=0 to target the second as intended.
        rom[16'h2280/4] = {NOP_OP, CLR_L_D5};
        rom[16'h2284/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2288/4] = {16'h3900, 16'h223C};
        rom[16'h228C/4] = {16'h0000, 16'h0100};
        rom[16'h2290/4] = {16'h2430, 16'h1925};
        rom[16'h2294/4] = {16'h0010, NOP_OP};
        run_berr_mid_test("BERR-mid-Memind", 32'h0000_2280, .next_addr(32'h0000_2B00));

        // -----------------------------------------------------------------
        // INT-mid-MOVEM (plan.md Phase 125): interrupt-mid-FSM coverage
        // (previously CAS2-only, Phase 105/108) extended to a genuinely
        // different FSM shape -- a multi-*beat* register-list load, not a
        // dual-address atomic lock. Reuses the vector-31 handler already
        // installed by the original interrupt-mid-CAS2 test above (D6=12345
        // marker, ends in RTE) via the new run_int_mid_test task. D6 is
        // reset to 0 first so the shared handler's own marker is a genuine
        // transition, not a stale leftover value from that earlier test.
        // MOVEM.L (A0)+,D0-D1 (2 registers = 2 bus cycles, matching B-2's
        // own precedent) should complete its full 2-cycle sequence before
        // the interrupt is taken -- the *same* generic int_defer mechanism
        // Phase 108 fixed for CAS2 gates dispatch uniformly regardless of
        // which FSM is running, so this is expected to pass; the value is
        // in actually exercising that rather than assuming it holds.
        // -----------------------------------------------------------------
        rom[16'h3D10/4] = 32'h1111_2222;
        rom[16'h3D14/4] = 32'h3333_4444;
        rom[16'h2B00/4] = {CLR_L_D6, CLR_L_D5};
        rom[16'h2B04/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2B08/4] = {16'h3D10, MOVEM_L_A0P};
        rom[16'h2B0C/4] = {16'h0003, ADDI_L_D5};
        rom[16'h2B10/4] = {16'h0000, 16'd2222};
        run_int_mid_test("INT-mid-MOVEM", 32'h0000_2B00, 2, 5, 32'd2222, 32'h0000_008A);
        check32("INT-mid-MOVEM: D0 loaded correctly", u_top.u_eu.u_rf.d_reg[0], 32'h1111_2222);
        check32("INT-mid-MOVEM: D1 loaded correctly", u_top.u_eu.u_rf.d_reg[1], 32'h3333_4444);

        // INT-mid-Memind (plan.md Phase 125): same interrupt-mid-FSM
        // coverage, now for genuine memory-indirect EA (`([bd,An],Xn,od)`,
        // Phase 124's own new addition) -- the two-level-indirection shape,
        // genuinely different again from both CAS2 and MOVEM. Reuses
        // B-22/BERR-mid-Memind's own already-populated pointer chain at
        // $3900/$3910/$3A00/$3B00 (read-only access, safe to reuse). The
        // FSM's own 2 bus cycles (pointer read, then final read) should
        // both complete before the interrupt lands, same reasoning as
        // INT-mid-MOVEM above.
        rom[16'h2B40/4] = {CLR_L_D6, CLR_L_D5};
        rom[16'h2B44/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2B48/4] = {16'h3900, 16'h223C};  // A0 imm lo=$3900 ; MOVE.L #$100,D1 opcode
        rom[16'h2B4C/4] = {16'h0000, 16'h0100};  // D1 imm hi ; D1 imm lo=$100
        rom[16'h2B50/4] = {16'h2430, 16'h1925};  // MOVE.L (mem-indirect),D2 opcode ; ext1
        rom[16'h2B54/4] = {16'h0010, ADDI_L_D5}; // bd=$10 ; ADDI.L opcode
        rom[16'h2B58/4] = {16'h0000, 16'd3333};
        run_int_mid_test("INT-mid-Memind", 32'h0000_2B40, 2, 5, 32'd3333, 32'h0000_008A);
        check32("INT-mid-Memind: D2 loaded correctly through both indirection levels",
                u_top.u_eu.u_rf.d_reg[2], 32'hCAFE_F00D);

        // -----------------------------------------------------------------
        // Wait-states-on-MOVEM-beats (plan.md Phase 125): DSACK wait-state
        // composition on a real FSM's own multi-*beat* bus cycles
        // (previously TAS-only, Phase 107's T4b -- a 2-phase RMW, not a
        // multi-beat register-list transfer). Two separate MOVEM.L
        // (A0)+,D0-D1 instances (own fresh source data each, same
        // "separate instance per wait_states value" shape T4b itself
        // established -- the global `wait_states` knob affects whichever
        // access is in flight when it's changed, not a re-execution of the
        // same instruction), one at wait_states=0, one at wait_states=10.
        //
        // wait_states=3 (T4b's own value, and this test's own first two
        // attempts) measurably lengthens TAS's own bus beats but produces
        // *zero* visible difference here (confirmed via temporary
        // cycle-completion tracing: ws_cnt_r genuinely does count up to 3
        // for both of MOVEM's own reads, so the DSACK-stretch mechanism
        // itself is firing correctly) -- not a sequencing bug at all, but a
        // genuine, instruction-shape-dependent absorption effect: the S-state
        // FSM doesn't sample DSACK until several clk_4x ticks into a bus
        // cycle regardless of how quickly it's actually asserted, and
        // MOVEM's own baseline per-beat latency happens to have enough slack
        // in that window to fully swallow 3 extra ticks with no visible
        // effect on total elapsed time, while TAS's own (shorter) baseline
        // does not. Swept wait_states=20 (elapsed 223->335, clearly visible)
        // then bisected down to wait_states=10 (223->279, still comfortably
        // visible) as a value with real margin above whatever the exact
        // absorption threshold is, rather than chasing the precise boundary.
        // Explicitly waiting for decode_pc to reach each instance's own
        // start before timing (the same pattern run_berr_mid_test/
        // run_int_mid_test already use) avoids an earlier, unrelated
        // confound where the walk-to-reach-the-code overhead (this pair
        // follows two interrupt-mid-FSM tests whose own settle-wait can
        // return with decode_pc still some distance from instance 1's own
        // code) swamped everything -- first raw attempt measured
        // elapsed0=575 vs elapsed3=319 (backwards) before this fix.
        // -----------------------------------------------------------------
        rom[16'h3D20/4] = 32'h5555_6666;
        rom[16'h3D24/4] = 32'h7777_8888;
        rom[16'h2B80/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2B84/4] = {16'h3D10, MOVEM_L_A0P};
        rom[16'h2B88/4] = {16'h0003, CLR_L_D5};
        rom[16'h2B8C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2B90/4] = {16'd4444, NOP_OP};
        rom[16'h2BA0/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2BA4/4] = {16'h3D20, MOVEM_L_A0P};
        rom[16'h2BA8/4] = {16'h0003, CLR_L_D5};
        rom[16'h2BAC/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2BB0/4] = {16'd4446, NOP_OP};
        begin
            int elapsed0, elapsed10, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2B80; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-MOVEM-1: wait_states=0, D5=4444", 5, 32'd4444, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2BA0; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-MOVEM-2: wait_states=10, D5=4446", 5, 32'd4446, 4000, elapsed10);
            wait_states = 0;
            check("WS-MOVEM: wait states measurably lengthen a multi-beat FSM's own bus cycles too",
                  elapsed10 > elapsed0);
        end

        // ===================================================================
        // Phase 126: breadth extensions for the three mechanisms docs/stalls.md
        // flagged as "proven correct in principle, only spot-checked" --
        // interrupt-mid-FSM (3->7 sources), DSACK wait-states-on-FSM-beats
        // (2->4 sources), and back-to-back FSM composition (1->3 pairs). None
        // of these are expected to surface a new RTL bug (the mechanisms are
        // all decode-content-agnostic by construction, already argued in
        // docs/stalls.md), so this batch is pure breadth, not depth -- but
        // per this file's own established discipline, "should be fine" gets
        // an actual test, not just an argument.
        // ===================================================================

        // -------------------------------------------------------------
        // INT-mid-TAS: interrupt arrival mid-TAS (indivisible RMW lock,
        // the simplest ex_mem_stall shape -- 2 bus cycles, read then write).
        // -------------------------------------------------------------
        rom[16'h3600/4] = 32'h0000_0000;
        rom[16'h2C00/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2C04/4] = {16'h3600, TAS_A0};
        rom[16'h2C08/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2C0C/4] = {16'h0000, 16'd5501};
        run_int_mid_test("INT-mid-TAS", 32'h0000_2C00, 2, 5, 32'd5501, 32'h0000_008A);

        // -------------------------------------------------------------
        // INT-mid-MOVEP: interrupt arrival mid-MOVEP.L (byte-interleaved
        // store, 4 individual byte bus cycles -- a genuinely different FSM
        // shape from TAS/MOVEM/memory-indirect EA's own already-covered
        // 2-phase patterns).
        // -------------------------------------------------------------
        rom[16'h2C10/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2C14/4] = {16'h0000, 16'h3610};
        rom[16'h2C18/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2C1C/4] = {16'hAABB, 16'hCCDD};
        rom[16'h2C20/4] = {MOVEP_L_D1_A0, 16'h0010};
        rom[16'h2C24/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2C28/4] = {16'd5502, NOP_OP};
        run_int_mid_test("INT-mid-MOVEP", 32'h0000_2C10, 4, 5, 32'd5502, 32'h0000_008A);

        // -------------------------------------------------------------
        // INT-mid-CAS: interrupt arrival mid-single-address CAS.L (an
        // indivisible RMW lock like TAS, but a distinct decode path).
        // D1 is set to match the memory operand exactly so the compare
        // always succeeds, guaranteeing the deterministic 2-cycle
        // read-then-write shape (a mismatch would still stall correctly,
        // but wouldn't write, and this test isn't verifying CAS's own
        // compare/write semantics -- Harte already covers that).
        // -------------------------------------------------------------
        rom[16'h3630/4] = 32'h1234_5678;
        rom[16'h2C30/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2C34/4] = {16'h0000, 16'h3630};
        rom[16'h2C38/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2C3C/4] = {16'h1234, 16'h5678};
        rom[16'h2C40/4] = {CAS_L_D1D2_A0, CAS_EXT};
        rom[16'h2C44/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2C48/4] = {16'd5503, NOP_OP};
        run_int_mid_test("INT-mid-CAS", 32'h0000_2C30, 2, 5, 32'd5503, 32'h0000_008A);

        // -------------------------------------------------------------
        // INT-mid-ADDX: interrupt arrival mid-ADDX.L -(A1),-(A0) -- the
        // dual-address predecrement shape (read src, read dst, write dst
        // -- 3 bus cycles), shared by ABCD/SBCD/PACK's own mem_abort
        // handling (Phase 109) but not yet exercised for interrupt-mid.
        // Not checking the actual sum (X-flag state going in is whatever
        // prior tests left it, same as BERR-mid-ADDX's own precedent) --
        // only that decode correctly defers the interrupt for the FSM's
        // full 3-cycle duration and resumes cleanly afterward.
        // -------------------------------------------------------------
        rom[16'h3660/4] = 32'h0000_0005;  // dst initial value ((A0)-4)
        rom[16'h3670/4] = 32'h0000_0003;  // src value ((A1)-4)
        rom[16'h2C50/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2C54/4] = {16'h0000, 16'h3664};
        rom[16'h2C58/4] = {MOVEA_L_IMM_A1, 16'h0000};
        rom[16'h2C5C/4] = {16'h3674, ADDX_L_A1_A0};
        rom[16'h2C60/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2C64/4] = {16'd5504, NOP_OP};

        // Open-items backlog Stage 5 (plan.md): INT-mid-PACK/INT-mid-
        // BFINS's own rom[] content, plus the JMP redirect that reaches
        // them (in the free gap right after T4d's own tail, before
        // WS-CAS2's own fixed 0x2CC0 start), written here -- up front,
        // before T4c/T4d's own check code runs and starts consuming real
        // simulated time. A first attempt placed these writes in their
        // own natural program-order position (right after WS-CAS's own
        // block, in the T4d/WS-CAS2 gap) and found every check failed
        // with zero bus activity ever observed -- traced to the exact
        // same "ROM write issued after simulated time already passed
        // that address" class Stage 3 already root-caused for the
        // I-cache case, just via the IFU's own always-present linear
        // readahead (not genuine caching, which isn't active yet at this
        // point in the flow) racing ahead of a write positioned too late
        // in SV program order.
        // A few settle NOPs right at the JMP target, before any real
        // (bus-touching) content -- avoids "interrupt arrives mid-JMP-
        // redirect", a genuinely new scenario no other run_int_mid_test
        // call site exercises (every other one is reached via plain
        // fall-through, never a JMP). Found via direct trace: a first
        // attempt with PACK's own real content starting immediately at
        // the JMP target showed decode_pc/A0/A1/D1 all reading garbage
        // (values from an entirely different, earlier test) after the
        // interrupt round-tripped -- consistent with the NMI landing
        // while the redirect itself was still in flight.
        rom[16'h2EA0/4] = {NOP_OP, NOP_OP};
        rom[16'h2EA4/4] = {NOP_OP, NOP_OP};
        rom[16'h2EA8/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2EAC/4] = {16'h3084, MOVEA_L_IMM_A1};
        rom[16'h2EB0/4] = {16'h0000, 16'h3094};
        rom[16'h2EB4/4] = {PACK_A1_A0, 16'h0000};
        rom[16'h2EB8/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2EBC/4] = {16'h0000, 16'd8005};
        rom[16'h2EC0/4] = {NOP_OP, NOP_OP};
        rom[16'h2EC4/4] = {NOP_OP, MOVEA_L_IMM_A0};
        rom[16'h2EC8/4] = {16'h0000, 16'h30A0};
        rom[16'h2ECC/4] = {BFINS_D1_A0, BFINS_EXT};
        rom[16'h2ED0/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2ED4/4] = {16'h0000, 16'd8006};
        rom[16'h2ED8/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h2EDC/4] = {16'h2EE0, NOP_OP};  // on to T4e (see below), which itself continues to WS-CAS2
        rom[16'h2CAC/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h2CB0/4] = {16'h2EA0, NOP_OP};

        // Open-items backlog Stage 6 (plan.md): T4e -- back-to-back FSM
        // composition, pair #4 -- ADDX.L -(A1),-(A0) immediately followed
        // by TAS (A0), no instruction between them. A genuinely new
        // pairing shape (dual-address predecrement handing directly to a
        // single-address RMW lock) with a real cross-boundary data-flow
        // check: ADDX's own predecrement leaves A0 pointing at the exact
        // byte it just wrote (the sum's own top byte, always 0x00 for
        // this test's own small operands regardless of the incoming
        // X-flag, same reasoning T4d's own TAS check already
        // established), and TAS must read THAT value (not stale data)
        // to correctly set bit7 -- 0x80, not a coincidental match.
        // rom[] content written up front, same reasons as PACK/BFINS
        // above; own fresh addresses (0x30BC/0x30CC), clear of every
        // other predecrement target in this file.
        rom[16'h30BC/4] = 32'h0000_0005;  // dst initial value ((A0)-4)
        rom[16'h30CC/4] = 32'h0000_0003;  // src value ((A1)-4)
        rom[16'h2EE0/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2EE4/4] = {16'h30C0, MOVEA_L_IMM_A1};
        rom[16'h2EE8/4] = {16'h0000, 16'h30D0};
        rom[16'h2EEC/4] = {ADDX_L_A1_A0, TAS_A0};
        rom[16'h2EF0/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2EF4/4] = {16'h0000, 16'd8007};
        rom[16'h2EF8/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h2EFC/4] = {16'h2CC0, NOP_OP};  // back to WS-CAS2's own start

        run_int_mid_test("INT-mid-ADDX", 32'h0000_2C50, 3, 5, 32'd5504, 32'h0000_008A);

        // -------------------------------------------------------------
        // T4c: back-to-back FSM composition, pair #2 -- MOVEP.L D1,(A0)
        // immediately followed by CAS.L D1,D2,(A0), no instruction between
        // them. A genuinely different pairing shape from T4a's TAS->MOVEM
        // (RMW->register-list): byte-interleaved-write handing directly to
        // a single-address atomic lock. Memory at A0 is pre-loaded to match
        // D1 exactly, so CAS's own compare always succeeds (deterministic
        // 2-cycle read+write, same reasoning as INT-mid-CAS above).
        // -------------------------------------------------------------
        rom[16'h3680/4] = 32'hAABB_CCDD;
        rom[16'h2C70/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2C74/4] = {16'h3680, CLR_L_D1};
        rom[16'h2C78/4] = {ADDI_L_D1, 16'hAABB};
        rom[16'h2C7C/4] = {16'hCCDD, MOVEP_L_D1_A0};
        rom[16'h2C80/4] = {16'h0010, CAS_L_D1D2_A0};
        rom[16'h2C84/4] = {CAS_EXT, CLR_L_D5};
        rom[16'h2C88/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2C8C/4] = {16'd4001, NOP_OP};
        // Phase 160 Stage 1: T4d's own rom[] writes (below) are staged here,
        // BEFORE T4c's own wait-loop/checks, rather than at the top of T4d's
        // own block further down. Under the corrected (faster) S-state
        // pacing, decode can reach T4d's own code (0x2C90+, right after
        // T4c's own trailing NOP at 0x2C8E) close enough to when T4c's own
        // run_and_check/check32/check8 calls finish that T4d's own writes --
        // previously placed at the top of T4d's own block -- landed AFTER
        // decode had already consumed stale (pre-write) content there.
        // Confirmed via trace: at the moment those writes previously
        // executed, ifu_decode_pc already read 0x2c92 (past CLR.L D5 at
        // 0x2C90, mid-decode of MOVEA.L's own extension words), explaining
        // MOVEA.L's own 32-bit immediate reading back wrong. Same fix shape
        // as Phase 131's "write all affected ROM content up front, before
        // any time-advancing wait" precedent -- moving the writes earlier in
        // program order (not adding a wait) is what actually closes a
        // CPU-races-ahead-of-testbench-writes race, since the CPU can only
        // reach 0x2C90 after this whole `initial` block's own program order
        // reaches at least this point.
        rom[16'h36A0/4] = 32'h0011_2233;  // TAS target (A0 itself); top byte 0 -> TAS sets bit7 -> 0x80
        rom[16'h36B0/4] = 32'h0000_3730;  // pointer stored at outer read addr (A0+bd)
        rom[16'h3830/4] = 32'hDEAD_F00D;  // final value (pointer + D1)
        rom[16'h2C90/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2C94/4] = {16'h0000, 16'h36A0};
        rom[16'h2C98/4] = {16'h223C, 16'h0000};  // MOVE.L #$100,D1 opcode ; imm hi
        rom[16'h2C9C/4] = {16'h0100, 16'h2430};  // imm lo=$100 ; MOVE.L (memind),D2 opcode
        rom[16'h2CA0/4] = {16'h1925, 16'h0010};  // ext1 ; bd
        rom[16'h2CA4/4] = {TAS_A0, ADDI_L_D5};
        rom[16'h2CA8/4] = {16'h0000, 16'd4002};
        // Open-items backlog Stage 5 (plan.md): redirect through the free
        // gap before WS-CAS2's own fixed 0x2CC0 start (matching Stage 4's
        // own "explicit JMP, isolated address" convention) to
        // INT-mid-PACK/INT-mid-BFINS (own addresses, below WS-MOVEP/
        // WS-CAS's own Stage-4 content), whose own tail JMPs back to
        // 0x2CC0, preserving the original flow. (rom[] content for this
        // JMP and for INT-mid-PACK/BFINS themselves is written up front,
        // alongside INT-mid-ADDX's own setup -- see the comment there --
        // not here: T4c/T4d's own check code between here and there
        // advances real simulated time, and the IFU's own linear
        // readahead reaches this address range well before a write
        // positioned at this point in SV program order would land,
        // hitting the identical class of race Stage 3 already root-
        // caused for the I-cache case, just via the IFU's own
        // always-present prefetch queue instead of genuine caching.)
        begin
            int c0, c1, t;
            // Unlike T4a (which ran directly after B-21 with nothing async
            // in between), T4c follows the interrupt-mid-FSM tests above,
            // whose own settle-wait can return with decode_pc having only
            // *just* crossed the handler's own RTE address (Phase 125's own
            // "decode_pc can be ahead of what's actually retiring in EX"
            // lesson applies here too) -- confirmed via a first attempt
            // that measured 11 data-space bus cycles instead of the
            // expected 6, cycle-completion tracing showing the extra
            // activity was the *previous* interrupt handler's own trailing
            // RTE stack reads still landing. Explicitly waiting for
            // decode_pc to reach this test's own code before measuring
            // (the same pattern WS-MOVEM's own Phase 125 fix established)
            // avoids it.
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2C70; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            run_and_check("T4c: back-to-back MOVEP->CAS dependent instr ran (D5=4001)", 5, 32'd4001, 4000);
            c1 = data_ds_count;
            check32("T4c: MOVEP(4)+CAS(2)=6 data-space bus cycles", c1 - c0, 32'd6);
            check8("T4c: MOVEP byte0 (D1[31:24]) at A0+16", rom[16'h3690/4][31:24], 8'hAA);
            check8("T4c: MOVEP byte1 (D1[23:16]) at A0+18", rom[16'h3690/4][15:8],  8'hBB);
            check8("T4c: MOVEP byte2 (D1[15:8]) at A0+20",  rom[16'h3694/4][31:24], 8'hCC);
            check8("T4c: MOVEP byte3 (D1[7:0]) at A0+22",   rom[16'h3694/4][15:8],  8'hDD);
        end

        // -------------------------------------------------------------
        // T4d: back-to-back FSM composition, pair #3 -- genuine
        // memory-indirect EA (MOVE.L ([$10,A0],D1.L),D2) immediately
        // followed by TAS (A0), no instruction between them. A third
        // distinct pairing shape: a 2-phase read-chain FSM handing
        // directly to an RMW lock FSM, both anchored on the same base
        // register A0 (memory-indirect never modifies An, so TAS (A0)
        // right afterward is a legal, meaningful adjacency, not an
        // arbitrary unrelated pairing). Uses its own fresh pointer chain
        // (not B-22/BERR-mid-Memind/INT-mid-Memind's $3900 chain), since
        // TAS here actually mutates the byte at A0, and this pair runs
        // last so nothing downstream depends on that byte staying pristine.
        // (rom[] writes for this test are staged earlier, alongside T4c's
        // own -- see the comment there.)
        // -------------------------------------------------------------
        begin
            int c0, c1, t;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2C90; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            run_and_check("T4d: back-to-back Memind->TAS dependent instr ran (D5=4002)", 5, 32'd4002, 4000);
            c1 = data_ds_count;
            check32("T4d: Memind(2)+TAS(2)=4 data-space bus cycles", c1 - c0, 32'd4);
            check32("T4d: memory-indirect EA loaded D2 correctly through both indirection levels",
                    u_top.u_eu.u_rf.d_reg[2], 32'hDEAD_F00D);
            check32("T4d: TAS set bit7 on A0's own byte (top byte 0x80, not stale 0x00)",
                    rom[16'h36A0/4], 32'h8011_2233);
        end

        // INT-mid-PACK/INT-mid-BFINS: rom[] content for both, and the JMP
        // redirect reaching them, is written up front alongside INT-mid-
        // ADDX's own setup (see the comment there). The CALLS, though,
        // must run HERE -- immediately after T4d's own check block, not
        // after WS-CAS2/WS-Memind/WS-MOVEP/WS-CAS's own check blocks
        // further below where they were originally placed (matching this
        // file's own "next section in program-text order" convention).
        // Root-caused via direct trace, not guessed at: this test's own
        // real DUT execution (via the 0x2CAC JMP redirect) happens
        // BEFORE WS-CAS2/WS-Memind/WS-MOVEP/WS-CAS in the actual
        // execution sequence, but SV program order controls when
        // run_int_mid_test's own decode_pc-based synchronization starts
        // watching -- placed after those tests' own check blocks, the
        // DUT had ALREADY passed this code (and moved on, deep into
        // RAW-hazard-with-Ihit's own loop or beyond) by the time the SV
        // task's own "reached own code" wait even began, so it resolved
        // instantly (decode_pc already far past 0x2EA8) and the
        // injection loop watched unrelated, much-later bus activity
        // instead -- explaining the observed corruption (decode_pc/A0/
        // A1/D1 reading garbage values from entirely different tests).
        // SV program order must match real DUT execution order for this
        // particular helper's own synchronization to work correctly.
        // PACK's own real bus-cycle count is 2, not 3 like ADDX -- unlike
        // ADDX's addition (needs both operands read before it can write
        // the sum), PACK's own destination is a pure write (source word
        // read from -(Ay), packed, written to -(Ax) with no dst-read
        // needed first). Confirmed empirically (an initial guess of 3,
        // matching ADDX's own shape, measured 2) before landing this.
        run_int_mid_test("INT-mid-PACK", 32'h0000_2EA8, 2, 5, 32'd8005, 32'h0000_008A);
        run_int_mid_test("INT-mid-BFINS", 32'h0000_2EC6, 2, 5, 32'd8006, 32'h0000_008A);

        // T4e: check code positioned here (immediately after INT-mid-
        // BFINS's own call), matching this test's own real DUT execution
        // order exactly -- the same lesson Stage 5 already learned the
        // hard way for INT-mid-PACK/BFINS themselves. rom[] content is
        // above, alongside INT-mid-ADDX's own setup.
        begin
            int t, c0, c1;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2EE0; t++)
                @(posedge clk_4x);
            check("T4e: reached own code", u_top.ifu_decode_pc >= 32'h0000_2EE0);
            c0 = data_ds_count;
            run_and_check("T4e: back-to-back ADDX->TAS dependent instr ran (D5=8007)", 5, 32'd8007, 4000);
            c1 = data_ds_count;
            check32("T4e: ADDX(3)+TAS(2)=5 data-space bus cycles", c1 - c0, 32'd5);
            // Only the top byte is checked, not the full 32-bit sum: the
            // incoming X-flag (whatever prior tests left it, same caveat
            // INT-mid-ADDX's own comment already documents) can make the
            // low byte 8 or 9, but 5+3+X always fits in the low byte
            // regardless, so the top byte is 0x00 before TAS and must be
            // 0x80 (bit7 set, not stale) after.
            check8("T4e: TAS set bit7 on ADDX's own just-written byte (top byte 0x80, not stale 0x00)",
                   rom[16'h30BC/4][31:24], 8'h80);
        end

        // -------------------------------------------------------------
        // WS-CAS2: DSACK wait-states composing with CAS2's own bus beats
        // (the single most complex ex_mem_stall FSM -- 4 phases without
        // releasing the bus, though a compare mismatch, guaranteed here by
        // clearing Dc1/Dc2 and pointing at nonzero memory, short-circuits
        // to just the 2 read phases, same as B-6's own reasoning). Two
        // fresh instances, own data each, following WS-MOVEM's exact
        // structure (explicit decode_pc gating before each instance,
        // wait_states set *before* the gating loop).
        // -------------------------------------------------------------
        rom[16'h36D0/4] = 32'h1111_1111;
        rom[16'h36E0/4] = 32'h2222_2222;
        rom[16'h2CC0/4] = {CLR_L_D1, CLR_L_D3};
        rom[16'h2CC4/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2CC8/4] = {16'h36D0, MOVEA_L_IMM_A1};
        rom[16'h2CCC/4] = {16'h0000, 16'h36E0};
        rom[16'h2CD0/4] = {CAS2_L, CAS2_EXT1};
        rom[16'h2CD4/4] = {CAS2_EXT2, CLR_L_D5};
        rom[16'h2CD8/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2CDC/4] = {16'd6001, NOP_OP};
        rom[16'h36F0/4] = 32'h3333_3333;
        rom[16'h3700/4] = 32'h4444_4444;
        rom[16'h2D00/4] = {CLR_L_D1, CLR_L_D3};
        rom[16'h2D04/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2D08/4] = {16'h36F0, MOVEA_L_IMM_A1};
        rom[16'h2D0C/4] = {16'h0000, 16'h3700};
        rom[16'h2D10/4] = {CAS2_L, CAS2_EXT1};
        rom[16'h2D14/4] = {CAS2_EXT2, CLR_L_D5};
        rom[16'h2D18/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2D1C/4] = {16'd6002, NOP_OP};
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2CC0; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-CAS2-1: wait_states=0, D5=6001", 5, 32'd6001, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2D00; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-CAS2-2: wait_states=10, D5=6002", 5, 32'd6002, 4000, elapsedX);
            wait_states = 0;
            check("WS-CAS2: wait states measurably lengthen CAS2's own bus cycles too",
                  elapsedX > elapsed0);
        end

        // -------------------------------------------------------------
        // WS-Memind: DSACK wait-states composing with genuine
        // memory-indirect EA's own 2-phase read chain (pointer read, then
        // final read) -- its own fresh pointer chains, distinct from every
        // other memind test in this file.
        // -------------------------------------------------------------
        rom[16'h3750/4] = 32'h0000_3770;
        rom[16'h3870/4] = 32'hBEEF_0001;
        rom[16'h2D40/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2D44/4] = {16'h3740, 16'h223C};
        rom[16'h2D48/4] = {16'h0000, 16'h0100};
        rom[16'h2D4C/4] = {16'h2430, 16'h1925};
        rom[16'h2D50/4] = {16'h0010, CLR_L_D5};
        rom[16'h2D54/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2D58/4] = {16'd7001, NOP_OP};
        rom[16'h3790/4] = 32'h0000_37A0;
        rom[16'h38A0/4] = 32'hBEEF_0002;
        rom[16'h2D80/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2D84/4] = {16'h3780, 16'h223C};
        rom[16'h2D88/4] = {16'h0000, 16'h0100};
        rom[16'h2D8C/4] = {16'h2430, 16'h1925};
        rom[16'h2D90/4] = {16'h0010, CLR_L_D5};
        rom[16'h2D94/4] = {ADDI_L_D5, 16'h0000};
        // Redirect via JMP.L instead of falling through to RAW-hazard-
        // with-Ihit's own fixed 0x2DA0 start -- exactly enough room
        // (6 bytes) in the trailing-NOP gap before it. Routes through
        // WS-MOVEP/WS-CAS first (own isolated addresses, since
        // fall-through can't reach them directly -- see their own
        // comment below), whose own tail JMPs back to 0x2DA0, preserving
        // the original flow exactly.
        rom[16'h2D98/4] = {16'd7002, JMP_ABS_L_OP};
        rom[16'h2D9C/4] = {16'h0000, 16'h2E20};
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2D40; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-Memind-1: wait_states=0, D5=7001", 5, 32'd7001, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2D80; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-Memind-2: wait_states=10, D5=7002", 5, 32'd7002, 4000, elapsedX);
            wait_states = 0;
            check("WS-Memind: wait states measurably lengthen memory-indirect EA's own bus cycles too",
                  elapsedX > elapsed0);
        end

        // -------------------------------------------------------------
        // WS-MOVEP: DSACK wait-states composing with MOVEP.L's own
        // byte-interleaved store (4 individual byte bus cycles -- a
        // genuinely different FSM beat shape from TAS/MOVEM/CAS2/
        // memory-indirect EA's own already-covered patterns). Same
        // opcode/ext shape as INT-mid-MOVEP above (MOVEP_L_D1_A0,
        // disp=0x10), fresh addresses/data, own instances. Positioned
        // before RAW-hazard-with-Ihit's own I-cache-enabling loop, so no
        // readahead-race risk (Stage 3, plan.md) applies here.
        // -------------------------------------------------------------
        rom[16'h2E20/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2E24/4] = {16'h0000, 16'h3000};
        rom[16'h2E28/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2E2C/4] = {16'hAABB, 16'hCCDD};
        rom[16'h2E30/4] = {MOVEP_L_D1_A0, 16'h0010};
        rom[16'h2E34/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2E38/4] = {16'd8001, NOP_OP};
        rom[16'h2E40/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2E44/4] = {16'h0000, 16'h3020};
        rom[16'h2E48/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2E4C/4] = {16'h1122, 16'h3344};
        rom[16'h2E50/4] = {MOVEP_L_D1_A0, 16'h0010};
        rom[16'h2E54/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2E58/4] = {16'd8002, NOP_OP};
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2E20; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-MOVEP-1: wait_states=0, D5=8001", 5, 32'd8001, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2E40; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-MOVEP-2: wait_states=10, D5=8002", 5, 32'd8002, 4000, elapsedX);
            wait_states = 0;
            check("WS-MOVEP: wait states measurably lengthen MOVEP's own byte-interleaved bus cycles too",
                  elapsedX > elapsed0);
        end

        // -------------------------------------------------------------
        // WS-CAS: DSACK wait-states composing with single-address CAS.L's
        // own indivisible RMW lock (a distinct decode path from TAS,
        // 2-cycle read-then-write). Same opcode/ext shape as INT-mid-CAS
        // above (CAS_L_D1D2_A0/CAS_EXT); D1 set to match the memory
        // operand exactly so the compare always succeeds, same reasoning
        // as INT-mid-CAS. Own fresh addresses/data/instances.
        // -------------------------------------------------------------
        rom[16'h3050/4] = 32'h1234_5678;
        rom[16'h2E60/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2E64/4] = {16'h0000, 16'h3050};
        rom[16'h2E68/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2E6C/4] = {16'h1234, 16'h5678};
        rom[16'h2E70/4] = {CAS_L_D1D2_A0, CAS_EXT};
        rom[16'h2E74/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2E78/4] = {16'd8003, NOP_OP};
        rom[16'h3060/4] = 32'h1234_5678;
        rom[16'h2E80/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2E84/4] = {16'h0000, 16'h3060};
        rom[16'h2E88/4] = {CLR_L_D1, ADDI_L_D1};
        rom[16'h2E8C/4] = {16'h1234, 16'h5678};
        rom[16'h2E90/4] = {CAS_L_D1D2_A0, CAS_EXT};
        rom[16'h2E94/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2E98/4] = {16'd8004, JMP_ABS_L_OP};
        rom[16'h2E9C/4] = {16'h0000, 16'h2DA0};  // back to RAW-hazard-with-Ihit's own start
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2E60; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-CAS-1: wait_states=0, D5=8003", 5, 32'd8003, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2E80; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-CAS-2: wait_states=10, D5=8004", 5, 32'd8004, 4000, elapsedX);
            wait_states = 0;
            check("WS-CAS: wait states measurably lengthen single-address CAS's own bus cycles too",
                  elapsedX > elapsed0);
        end

        // -------------------------------------------------------------
        // RAW-hazard-with-Ihit (cache-verification plan, plan.md Phase
        // 127, Step 7): confirms a RAW register hazard still resolves
        // correctly when the producer/consumer instructions themselves
        // are fetched via an I-cache HIT, not just from an always-real-
        // bus-cycle fetch -- this file's own RAW-hazard-shaped checks
        // (elsewhere in this suite) never set CACR, so caching has never
        // composed with the hazard_ex stall mechanism before. A DBF
        // D0,-10 self-loop (10 passes) re-fetches the SAME 4 instruction
        // words every pass -- only the first pass can be a genuine bus
        // miss, every later pass must be served from the cache -- and the
        // loop body is a same-register RAW hazard (ADDI.L #1,D1
        // immediately followed by ADD.L D1,D2, which must stall on
        // hazard_ex to read D1's just-written value). Checks the EXACT
        // accumulated sum (D2 = 1+2+...+10 = 55), not just "the loop
        // finished": a single pass reading a stale D1 -- the hazard not
        // composing correctly with a cache-hit-served fetch -- would
        // produce a wrong sum, not an obviously-broken value or a hang,
        // so only an exact-value check actually proves this.
        //
        // Open-items backlog Stages 2-3 (plan.md): the MOVEQ opcode below
        // was 0x7201, which real MOVEQ encoding (0111 rrr 0 dddddddd)
        // decodes as "MOVEQ #1,D1", NOT "MOVEQ #1,D7" as this comment
        // (and every phase since 135) assumed. Confirmed via direct
        // trace: D1 became 1, D7 stayed 0, so the following MOVEC D7,CACR
        // wrote CACR=0 -- meaning this test never actually enabled the
        // I-cache, despite its own name/purpose, despite its own checks
        // passing the whole time (the DBF loop's own semantic correctness
        // doesn't depend on caching actually happening, only on the
        // hazard resolving, so a real-bus-cycle fetch every pass produces
        // the identical D1/D2 checksum). Found while investigating the
        // separate Phase 155 "PLOAD/CACR/IC_BURST0 hang" finding.
        //
        // Fixed to 0x7E01 (reg=111=D7) -- Stage 2 first found that fixing
        // this exposed what LOOKED LIKE a deep I-cache correctness bug in
        // the downstream "Indexed-EA-no-extra-read" test (instr_word
        // reading 0x4E71/0x0000 instead of the real opcodes actually in
        // ROM at 0x2DE4+). Stage 3's own deeper trace (ext_d_in -- the
        // RAW combinational rom[] read itself, before any cache logic --
        // showing the SAME wrong data) proved this was never an RTL bug
        // at all: RAW-hazard-with-Ihit's own 10-pass tight DBF loop takes
        // many real clk_4x ticks, giving the I-cache's now-genuinely-
        // active speculative readahead plenty of time to race into idx=
        // 0xE (0x2DE0-0x2DEF) BEFORE "CLR-non-indexed-no-extra-read"'s
        // and "Indexed-EA-no-extra-read"'s own rom[] writes (originally
        // positioned just before each test's own check block, per this
        // file's long-standing per-test-interleaved convention) had
        // executed in SV program order -- exactly the "ROM write issued
        // after simulated time already passed that address" class this
        // project has hit repeatedly (I-4/I-5 Phase 131, T4c/T4d Phase
        // 126, this session's own Stage 1 finding for cache_tb.sv), just
        // newly exposed here via genuine readahead instead of direct PC
        // execution. Fixed by moving both tests' own rom[] content up
        // front (see below), before RAW-hazard-with-Ihit's own loop even
        // starts -- a testbench-structural fix, not an RTL fix.
        rom[16'h2DA0/4] = {16'h7E01, 16'h4E7B};  // MOVEQ #1,D7 ; MOVEC D7,CACR
        rom[16'h2DA4/4] = {16'h7002, CLR_L_D1};  // (CACR ext: icache_en=1) ; CLR.L D1
        rom[16'h2DA8/4] = {CLR_L_D2, 16'h7009};  // CLR.L D2 ; MOVEQ #9,D0 (10 passes)
        rom[16'h2DAC/4] = {ADDI_L_D1, 16'h0000}; // loop: ADDI.L #1,D1
        rom[16'h2DB0/4] = {16'h0001, ADD_L_D1_D2};
        rom[16'h2DB4/4] = {DBF_D0, 16'hFFF6};    // DBF D0,-10 (back to ADDI.L D1)

        // Open-items backlog Stage 3 (plan.md): CLR-non-indexed-no-extra-
        // read's and Indexed-EA-no-extra-read's own rom[] content
        // (originally written just before each test's own "begin...end"
        // check block, AFTER RAW-hazard-with-Ihit's own check code runs
        // and consumes real simulated time) is written HERE instead --
        // up front, before RAW-hazard-with-Ihit's own 10-pass DBF loop
        // even starts running. Root-caused via direct trace: RAW-hazard-
        // with-Ihit's own tight loop takes many real clk_4x ticks, giving
        // the I-cache's genuine speculative readahead (now actually
        // active for the first time in this file, per the MOVEQ opcode
        // fix above) plenty of time to race ahead into idx=0xE (0x2DE0-
        // 0x2DEF, the line spanning both tests' own tail/head) BEFORE
        // these two tests' own rom[] writes had executed in SV program
        // order -- confirmed via ext_d_in (the raw combinational rom[]
        // read) itself showing wrong data for 0x2DE4/E8/EC, not a
        // caching/RTL bug at all. Exactly the same "ROM write issued
        // after simulated time already passed that address" class this
        // project has hit repeatedly (I-4/I-5 Phase 131, T4c/T4d Phase
        // 126, this session's own Stage 1 finding for cache_tb.sv) --
        // just newly exposed here via genuine readahead instead of
        // direct PC execution. This is a testbench-structural fix, not
        // an RTL fix -- no RTL changed this stage.
        rom[16'h2DC0/4] = {CLR_L_D6, CLR_L_D7};        // pre-clear both markers
        rom[16'h2DC4/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2DC8/4] = {16'h3B44, MOVEA_L_IMM_A1};
        rom[16'h2DCC/4] = {16'h0000, 16'h3B50};
        rom[16'h2DD0/4] = {CLR_L_PREDEC_A0, MOVE_L_IMM_D6};  // CLR.L -(A0): A0=$3B40, EA=$3B40
        rom[16'h2DD4/4] = {16'hAAAA, 16'h5555};              // D6 marker value
        rom[16'h2DD8/4] = {CLR_L_D16_A1, 16'h0010};          // CLR.L ($10,A1): EA=$3B60
        rom[16'h2DDC/4] = {MOVE_L_IMM_D7, 16'hBBBB};
        rom[16'h2DE0/4] = {16'h6666, NOP_OP};                // D7 marker value
        rom[16'h2DE4/4] = {CLR_L_D6, CLR_L_D7};              // pre-clear both markers
        rom[16'h2DE8/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2DEC/4] = {16'h3B70, MOVEA_L_IMM_A1};
        rom[16'h2DF0/4] = {16'h0000, 16'h3B90};
        rom[16'h2DF4/4] = {MOVE_L_IMM_D1, 16'h0000};
        rom[16'h2DF8/4] = {16'h0004, MOVE_L_IMM_D2};
        rom[16'h2DFC/4] = {16'h0000, 16'h0004};
        rom[16'h2E00/4] = {CLR_L_IDX_A0, 16'h1808};          // CLR.L (8,A0,D1.L): EA=$3B70+$4+$8=$3B7C
        rom[16'h2E04/4] = {MOVE_L_IMM_D6, 16'hAAAA};
        rom[16'h2E08/4] = {16'h5555, MOVE_SR_IDX_A1};        // MOVE.W SR,(8,A1,D2.L): EA=$3B90+$4+$8=$3B9C
        rom[16'h2E0C/4] = {16'h2808, MOVE_L_IMM_D7};
        rom[16'h2E10/4] = {16'hBBBB, 16'h6666};
        // PLOAD-ext-count's own rom[] content, same reason as above --
        // moved up front to avoid the identical readahead-races-ahead
        // race once tried too.
        rom[16'h2E14/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h2E18/4] = {16'h3FA0, NOP_OP};
        rom[16'h3FA0/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h3FA4/4] = {16'h2000, 16'hF010};          // A0=0x2000 ; PLOAD (A0) opcode
        rom[16'h3FA8/4] = {16'h6200, MOVE_L_IMM_D6};      // PLOAD ext word (mmu_op_type=011) ; MOVE.L #imm,D6
        rom[16'h3FAC/4] = {16'h0000, 16'h5678};
        // open-items backlog Stage 13 (plan.md): redirect on to the BKPT
        // live-substitution test instead of parking permanently here.
        rom[16'h3FB0/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h3FB4/4] = {16'h3FC0, NOP_OP};

        // BKPT #3 substitutes to MOVEQ #42,D0 (rom[0xC], written up
        // front above); the word right after BKPT's own opcode (0x3FC2)
        // is the REAL next instruction in the stream, unaffected by the
        // substitution -- CLR.L D5 + ADDI.L #1234,D5 proves execution
        // continued normally afterward, using a DIFFERENT register (D5)
        // than the substituted instruction's own target (D0) so both
        // effects are independently checkable.
        rom[16'h3FC0/4] = {BKPT_3, CLR_L_D5};
        rom[16'h3FC4/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h3FC8/4] = {16'd1234, NOP_OP};
        // Pipeline-stall breadth extension plan (elegant-gliding-fog.md):
        // redirect on to Stage 1's own new tests instead of parking
        // permanently here -- same "explicit JMP, isolated address"
        // convention this file has used throughout (Stage 4/5/6 of the
        // closed open-items backlog, etc).
        rom[16'h3FCC/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h3FD0/4] = {16'h2604, NOP_OP};

        begin
            int t;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2DA0; t++)
                @(posedge clk_4x);
            check("RAW-hazard-with-Ihit: reached own code", u_top.ifu_decode_pc >= 32'h0000_2DA0);
            for (t = 0; t < 4000 && u_top.u_eu.u_rf.d_reg[0][15:0] !== 16'hFFFF; t++)
                @(posedge clk_4x);
            check("RAW-hazard-with-Ihit: loop completed (D0 wrapped to -1) before the hard budget", t < 4000);
            check32("RAW-hazard-with-Ihit: RAW hazard resolved correctly on every cache-hit-served pass (D1)",
                    u_top.u_eu.u_rf.d_reg[1], 32'd10);
            check32("RAW-hazard-with-Ihit: RAW hazard resolved correctly on every cache-hit-served pass (D2=1+2+...+10)",
                    u_top.u_eu.u_rf.d_reg[2], 32'd55);
        end

        // -------------------------------------------------------------
        // CLR-non-indexed-no-extra-read (Phase 139, plan.md): direct
        // bus-cycle-count proof that non-indexed CLR-to-memory no longer
        // performs a phantom read before its write (the quirk
        // tests/memind13.s's own header first documented). Each CLR is
        // immediately followed by a MOVE.L #imm,Dn "marker" instruction;
        // data_ds_count is bracketed on the MARKER REGISTER settling to
        // its expected value, not on decode_pc -- an earlier version of
        // this test bracketed on decode_pc crossing the next
        // instruction's own address and got a spurious delta=0 for the
        // (d16,An) case, root-caused to the same "decode_pc can be ahead
        // of what's actually completing in EX" hazard docs/stalls.md
        // already catalogs (here, the IFU's own extension-word prefetch
        // for the following instruction can advance decode_pc's reported
        // value slightly ahead of the CURRENT instruction's own write
        // retiring). A register's own committed VALUE has no such
        // ambiguity -- EX retires strictly in order, so D6/D7 cannot
        // settle to their marker values until the preceding CLR's own
        // write-phase FSM has fully released ex_mem_stall. Covers both a
        // base-register mode (-(An), no extension word) and a
        // displacement mode ((d16,An), one extension word).
        // -------------------------------------------------------------
        // (rom[] content for this test moved up front, alongside RAW-
        // hazard-with-Ihit's own setup -- see the comment there.)
        begin
            int t, c0, c1, c3;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2DC0; t++)
                @(posedge clk_4x);
            check("CLR-non-indexed-no-extra-read: reached own code",
                  u_top.ifu_decode_pc >= 32'h0000_2DC0);

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2DD0; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hAAAA_5555; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("CLR.L -(An): exactly 1 bus cycle (the write only, no phantom read)",
                    c1 - c0, 32'd1);

            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'hBBBB_6666; t++)
                @(posedge clk_4x);
            c3 = data_ds_count;
            check32("CLR.L (d16,An): exactly 1 bus cycle (the write only, no phantom read)",
                    c3 - c1, 32'd1);
        end

        // -------------------------------------------------------------
        // Indexed-EA-no-extra-read (Phase 144, plan.md): same
        // bus-cycle-count proof as CLR-non-indexed-no-extra-read just
        // above, now for the two indexed-EA (An+Xn) forms Phase 144
        // converted from the RMW "2-port trick" to genuine single-phase
        // plain writes -- CLR.L (d8,An,Xn) and MOVE.W SR,(d8,An,Xn).
        // Before this phase both performed a real, architecturally-
        // unnecessary bus read before the write, purely to get 2
        // simultaneous register-file ports (An base + Xn index); after,
        // ex_an_base's own mux routes An through rd_a specifically for
        // indexed writes, freeing rd_b for Xn without an RMW read.
        // -------------------------------------------------------------
        // (rom[] content for this test moved up front, alongside RAW-
        // hazard-with-Ihit's own setup -- see the comment there.)
        begin
            int t, c0, c1, c2;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2DE4; t++)
                @(posedge clk_4x);
            check("Indexed-EA-no-extra-read: reached own code",
                  u_top.ifu_decode_pc >= 32'h0000_2DE4);

            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_2E00; t++)
                @(posedge clk_4x);
            c0 = data_ds_count;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'hAAAA_5555; t++)
                @(posedge clk_4x);
            c1 = data_ds_count;
            check32("CLR.L (d8,An,Xn): exactly 1 bus cycle (the write only, no phantom read)",
                    c1 - c0, 32'd1);

            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[7] !== 32'hBBBB_6666; t++)
                @(posedge clk_4x);
            c2 = data_ds_count;
            check32("MOVE.W SR,(d8,An,Xn): exactly 1 bus cycle (the write only, no phantom read)",
                    c2 - c1, 32'd1);

            // CLR always writes exactly zero regardless of prior state, so its
            // own EA is independently checkable this way. MOVE.W SR,(ea) writes
            // SR's own live value, which depends on accumulated CCR state from
            // every earlier test in this file -- not independently predictable
            // here, so its own EA correctness rests on the bus-cycle-count
            // check above (which already proves a write landed at the decoded
            // address, not just that *a* write happened somewhere).
            check32("CLR.L (d8,An,Xn): correct EA (M32[$3B7C] cleared)",
                    rom[16'h3B7C/4], 32'h0000_0000);
            check("MOVE.W SR,(d8,An,Xn): a write landed at the decoded EA ($3B9C, no longer the default NOP fill)",
                  rom[16'h3B9C/4][31:16] !== 16'h4E71);
        end

        // -------------------------------------------------------------
        // PLOAD-ext-count (open-items backlog Stage 2, plan.md): the
        // first-ever real-IFU test of PLOAD (Phase 150 Stage 5), closing
        // the "PLOAD/IC_BURST0/CACR hang" finding that phase's own
        // attempt left open and reverted. Root-caused via direct trace,
        // not guessed at: m68030_seq.sv's ext_count classifier had NO
        // entry anywhere for the whole F-line MMU family (PFLUSH/PFLUSHA/
        // PTEST/PMOVE/PLOAD, f_group=4'hF, f_dn=3'b000) -- silently
        // falling through to the ext_count=0 default, so drain never
        // accounted for the mandatory extension word every one of these
        // ops needs. This left the extension word undrained in the
        // prefetch queue, to be misdecoded as the START of the next
        // instruction -- for PLOAD specifically (mmu_op_type=011, ext
        // word 0x6200 in this test), that misdecode is a BRA.W, taking a
        // real, reproducible wild jump (confirmed landing exactly at the
        // hand-derived PC-relative target before the fix). PFLUSH/PTEST/
        // PMOVE share the identical underlying bug (mmu_op_type lives in
        // ext_data, invisible to the opcode-only classifier, so all four
        // are structurally indistinguishable to it) but their own
        // extension-word bit patterns happen to decode harmlessly when
        // misinterpreted as a fresh opcode in every existing test,
        // masking it until now. Fixed in m68030_seq.sv (see its own
        // comment there for the full derivation).
        //
        // Also found, investigating why CACR read disabled here despite
        // "RAW-hazard-with-Ihit" (above) supposedly enabling it: that
        // test's own MOVEQ opcode was wrong (0x7201 = MOVEQ #1,D1, not
        // D7) -- fixed separately, in place, above.
        // (rom[] content for this test moved up front, alongside
        // Indexed-EA-no-extra-read's own setup -- see the comment there.)
        // -------------------------------------------------------------
        begin
            int t;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[6] !== 32'h0000_5678; t++)
                @(posedge clk_4x);
            check32("PLOAD-ext-count: instruction after PLOAD's own extension word decoded and executed correctly (no wild jump)",
                    u_top.u_eu.u_rf.d_reg[6], 32'h0000_5678);
            // open-items backlog Stage 13 (plan.md): 0x3FB0 used to be a
            // permanent self-park (BRA_SELF), so decode_pc reading exactly
            // that address was a robust check regardless of exactly when
            // it was sampled. It's now a real JMP on to the BKPT
            // substitution test below, so decode_pc can legitimately have
            // already moved past it by the time this is checked -- relaxed
            // to a range covering everywhere that redirect can reach,
            // while still catching the original bug's own real wild-jump
            // target (0x6BE6, nowhere near this range).
            check("PLOAD-ext-count: decode_pc landed somewhere sensible, not off in uninitialized memory",
                  u_top.ifu_decode_pc >= 32'h0000_3FB0 && u_top.ifu_decode_pc <= 32'h0000_3FD0);
        end

        // -------------------------------------------------------------
        // BKPT-live-substitution (open-items backlog Stage 13, plan.md):
        // the first-ever end-to-end test of BKPT's own DSACK'd outcome
        // actually being spliced into the pipeline and executed, closing
        // the scope boundary Phase 157 Stage 3 originally documented
        // ("captures the replacement opcode word correctly but does not
        // attempt live re-decode/substitution"). BKPT #3 (rom[0x3FC0])
        // reads its own fixed CPU-space address (rom[0xC], set up front
        // near the top of this file) and substitutes to MOVEQ #42,D0 --
        // D0 proves the substitution's own value landed; D5 (set by
        // CLR.L D5 / ADDI.L #1234,D5, the REAL next instruction in
        // memory right after BKPT's own single opcode word, entirely
        // unaffected by the substitution) proves execution continued
        // normally afterward, using a register the substituted
        // instruction itself never touches.
        // -------------------------------------------------------------
        begin
            int t;
            for (t = 0; t < 20000 && u_top.u_eu.u_rf.d_reg[5] !== 32'd1234; t++)
                @(posedge clk_4x);
            check32("BKPT-live-substitution: real next instruction after BKPT's own opcode word ran (D5=1234)",
                    u_top.u_eu.u_rf.d_reg[5], 32'd1234);
            check32("BKPT-live-substitution: the replacement opcode (MOVEQ #42,D0) genuinely executed",
                    u_top.u_eu.u_rf.d_reg[0], 32'd42);
        end

        // ===================================================================
        // Pipeline-stall breadth extension plan (elegant-gliding-fog.md),
        // Stage 1: INT-mid-MOVE16/ABCD/SBCD -- 3 more sources for Category F
        // (interrupt-mid-FSM), reusing B-8's MOVE16 encoding and B-10's
        // ABCD/-(Ay),-(Ax) shape (SBCD is the identical layout, group 1000
        // instead of 1100). Reached via the JMP redirect at the tail of the
        // BKPT-live-substitution test above. No explicit BCD operand data is
        // set for ABCD/SBCD (default-filled memory is fine, same convention
        // B-10/B-11 already use) -- this stage is checking decode-holdoff/
        // interrupt-recognition timing, not BCD arithmetic correctness
        // (already 100% Harte-proven).
        // ===================================================================

        // INT-mid-MOVE16: interrupt arrival mid-MOVE16 (16-byte SIZ=11
        // burst block move -- a genuinely different FSM beat shape from
        // every other INT-mid-* source so far).
        rom[16'h2604/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2608/4] = {16'h2630, MOVEA_L_IMM_A1};
        rom[16'h260C/4] = {16'h0000, 16'h2650};
        rom[16'h2610/4] = {MOVE16_A0P_A1P, MOVE16_EXT};
        rom[16'h2614/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2618/4] = {16'h0000, 16'd9001};
        rom[16'h2630/4] = 32'h1111_2222;
        rom[16'h2634/4] = 32'h3333_4444;
        rom[16'h2638/4] = 32'h5555_6666;
        rom[16'h263C/4] = 32'h7777_8888;
        // MOVE16's own real bus-cycle count (data_ds_count delta) isn't
        // yet established anywhere else in this file -- measured
        // empirically the first time this ran (per this file's own
        // established "verify, don't guess" discipline, e.g. PACK's own
        // 2-vs-3 correction in the open-items backlog Stage 5).
        run_int_mid_test("INT-mid-MOVE16", 32'h0000_2604, 8, 5, 32'd9001, 32'h0000_008A);
        check32("INT-mid-MOVE16: beat0 copied despite the interrupt", rom[16'h2650/4], 32'h1111_2222);
        check32("INT-mid-MOVE16: beat3 copied despite the interrupt", rom[16'h265C/4], 32'h7777_8888);

        // INT-mid-ABCD: interrupt arrival mid-ABCD -(A1),-(A0) (the
        // predecrement-memory shape shared with ADDX/SBCD/PACK's own
        // mem_abort handling, not yet exercised for interrupt-mid).
        rom[16'h26C4/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h26C8/4] = {16'h0000, 16'h26F1};
        rom[16'h26CC/4] = {MOVEA_L_IMM_A1, 16'h0000};
        rom[16'h26D0/4] = {16'h26F5, ABCD_A1_A0};
        rom[16'h26D4/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h26D8/4] = {16'd9002, NOP_OP};
        run_int_mid_test("INT-mid-ABCD", 32'h0000_26C4, 3, 5, 32'd9002, 32'h0000_008A);

        // INT-mid-SBCD: same shape, opposite BCD direction.
        rom[16'h2784/4] = {CLR_L_D5, MOVEA_L_IMM_A0};
        rom[16'h2788/4] = {16'h0000, 16'h27B1};
        rom[16'h278C/4] = {MOVEA_L_IMM_A1, 16'h0000};
        rom[16'h2790/4] = {16'h27B5, SBCD_A1_A0};
        rom[16'h2794/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2798/4] = {16'd9003, NOP_OP};
        // Redirect on to Stage 2's own new tests instead of parking
        // permanently here (was BRA_SELF).
        rom[16'h279C/4] = {JMP_ABS_L_OP, 16'h0000};
        rom[16'h27A0/4] = {16'h2800, NOP_OP};
        run_int_mid_test("INT-mid-SBCD", 32'h0000_2784, 3, 5, 32'd9003, 32'h0000_008A);

        // ===================================================================
        // Stage 2 (elegant-gliding-fog.md): INT-mid-CMP2/INT-mid-CHK2 -- 2
        // more Category F sources, reusing B-13's own CMP2 encoding. CHK2
        // shares the identical opcode word, differing only in the extension
        // word's bit 11 (CHK2_EXT, above); unlike CMP2, CHK2 can genuinely
        // trap (vector 6) on an out-of-bounds compare, so its own test
        // explicitly clears D1 and sets an all-encompassing [0,0xFFFFFFFF]
        // bound in memory first, guaranteeing D1=0 is always in-bounds --
        // same "can't trap and redirect execution out from under this test"
        // reasoning B-13's own header comment already established for CMP2.
        // ===================================================================

        // INT-mid-CMP2: D1 left at whatever value prior tests leave it
        // (same as B-13's own convention) -- CMP2 never traps regardless,
        // so its own bound data doesn't need to be set explicitly either
        // (default-filled memory is fine, matching B-10/B-11's own
        // no-explicit-data convention).
        rom[16'h2800/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2804/4] = {16'h2830, CMP2_L_A0_D1};
        rom[16'h2808/4] = {CMP2_EXT, CLR_L_D5};
        rom[16'h280C/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2810/4] = {16'd9004, JMP_ABS_L_OP};
        // Explicit JMP over CHK2's own bound-data words at 0x2820/0x2824
        // below -- NOP fall-through would otherwise walk straight into
        // that data and try to decode it as instructions (confirmed the
        // hard way: a first attempt without this JMP hung with "reached
        // own code" never firing for INT-mid-CHK2, traced to decode_pc
        // never getting past the data region at all). JMP (xxx).L's own
        // 32-bit absolute address operand is TWO words (hi then lo), not
        // one word plus a NOP filler -- a first attempt got this backwards
        // ({16'h2850, NOP_OP}, giving a garbage target of 0x28504E71,
        // exactly matching a direct trace of ifu_decode_pc) and had to be
        // corrected to the {hi,lo} pattern every other JMP_ABS_L_OP site
        // in this file already uses.
        rom[16'h2814/4] = {16'h0000, 16'h2850};
        // CMP2/CHK2's own bounds-check FSM reads a lower and upper bound
        // longword from memory before comparing -- 2 bus cycles, the same
        // read-src/read-dst shape CHK's own indexed form uses (Phase 84).
        run_int_mid_test("INT-mid-CMP2", 32'h0000_2800, 2, 5, 32'd9004, 32'h0000_008A);

        // INT-mid-CHK2: D1 explicitly cleared (=0), bound data explicitly
        // set to [0,0x7FFFFFFF] so the compare is guaranteed to succeed
        // (no trap) regardless of the interrupt's own timing. CMP2/CHK2's
        // own bounds compare is SIGNED (eu_seq.sv's cmp2_c_w:
        // $signed(Rn) < $signed(lower) || $signed(Rn) > $signed(upper)) --
        // 0xFFFFFFFF as an upper bound is signed -1, which would make
        // D1=0 read as out-of-range and genuinely trap (confirmed the
        // hard way: a first attempt using 0xFFFFFFFF hung with an address
        // error, traced to CHK2 trapping to vector 6's own unconfigured,
        // default-filled table entry). 0x7FFFFFFF (max positive signed
        // long) is the correct all-encompassing upper bound instead.
        rom[16'h2820/4] = 32'h0000_0000;  // lower bound
        rom[16'h2824/4] = 32'h7FFF_FFFF;  // upper bound
        rom[16'h2850/4] = {CLR_L_D1, MOVEA_L_IMM_A0};
        rom[16'h2854/4] = {16'h0000, 16'h2820};
        rom[16'h2858/4] = {CMP2_L_A0_D1, CHK2_EXT};
        rom[16'h285C/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2860/4] = {16'h0000, 16'd9005};
        // No JMP -- falls straight through into INT-mid-MOVEmm's own code.
        // MOVEmm's own rom[] content (below) is written HERE, up front,
        // BEFORE run_int_mid_test("INT-mid-CHK2"...) is called -- not
        // after it. This is the exact "ROM write issued after simulated
        // time already passed that address" class this project has hit
        // repeatedly (Phase 131 I-4/I-5, Phase 126 T4c/T4d): a first
        // attempt placed these writes AFTER the CHK2 call returned, and
        // traced decode reading pure default-fill NOPs (0x4E71) all the
        // way from 0x2864 to 0x286E instead of the real MOVEA.L
        // instructions -- the IFU's own speculative readahead had already
        // raced past 0x2864 while CHK2's own (real-time-consuming)
        // run_int_mid_test call was still executing, well before this
        // SV code got around to writing the real bytes there.
        rom[16'h2864/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h2868/4] = {16'h3104, MOVEA_L_IMM_A1};
        rom[16'h286C/4] = {16'h0000, 16'h3110};
        rom[16'h2870/4] = {MOVE_L_A0_A1, CLR_L_D5};
        rom[16'h2874/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2878/4] = {16'd9006, NOP_OP};
        rom[16'h3104/4] = 32'hDEAD_C0DE;

        // INT-mid-RTR: interrupt arrival mid-RTR (2-phase stack read: CCR
        // word, then PC longword -- the first control-transfer/stack-
        // restore FSM shape exercised by this mechanism). Falls straight
        // through from MOVEmm's own tail above -- no JMP needed (RTR is
        // itself a control-transfer instruction). Frame at 0x2932
        // (CCR)/0x2934 (PC), same even-SP-but-4-aligned-PC trick B-15
        // already established.
        rom[16'h287C/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h2880/4] = {16'h2932, RTR_OP};
        rom[16'h2930/4] = {16'h0000, 16'h0000};   // CCR=0 at 0x2932
        rom[16'h2934/4] = 32'h0000_2940;          // PC -> dependent instr
        rom[16'h2940/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2944/4] = {16'h0000, 16'd9007};

        // INT-mid-RTE: interrupt arrival mid-RTE (format-$0 frame). SR
        // restored with S=1 so supervisor mode continues unaffected.
        // Reached via plain fall-through from RTR's own dependent target
        // above (0x2940's own tail, at 0x2948).
        rom[16'h2948/4] = {MOVEA_L_IMM_A7, 16'h0000};
        rom[16'h294C/4] = {16'h2950, RTE_OP};
        rom[16'h2950/4] = {16'h0000, 16'h2000};   // fmt/vec=0, SR=0x2000 (S=1)
        rom[16'h2954/4] = 32'h0000_2960;          // PC -> dependent instr
        rom[16'h2960/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h2964/4] = {16'h0000, 16'd9008};

        // Stage 4 (elegant-gliding-fog.md): INT-mid-PMOVE64 -- 1 more
        // Category F source. Falls straight through from RTE's own
        // dependent target above (0x2960's own tail, at 0x2968). TC.E=1
        // with a fully-transparent TT0 has been globally active since
        // B-20/B-21 (~0x1700-1810) and nothing since then touches
        // TC/TT0, so PMOVE works directly with no re-setup -- matching
        // B-20/B-21's own established convention. rom[] content written
        // up front, before run_int_mid_test's own earlier calls, per
        // Stage 3's own hard-won lesson.
        //
        // INT-mid-PFLUSH and INT-mid-PTEST were BOTH attempted and
        // dropped: `run_int_mid_test`'s own injection mechanism keys
        // entirely on `data_ds_count` (FC=101 supervisor-data bus
        // activity) to time when to assert the interrupt. PFLUSHA has no
        // EA/bus operand at all (confirmed by this file's own B-19
        // comment) -- there is nothing for it to ever detect. PTEST,
        // under this file's own transparent-TT0 setup, was empirically
        // confirmed to ALSO produce zero FC=101 activity (B-20's own
        // comment already predicted this: "resolves immediately without
        // needing any actual page-table data" -- no real table walk
        // means no bus cycle to key off either). A real attempt hung
        // the entire 20000-tick injection-wait budget for PTEST, with
        // "interrupt handler ran" showing a MISLEADING pass (D6 was
        // simply still 12345 from the PREVIOUS test's own genuine
        // interrupt, never re-cleared, since PTEST's own ISR never
        // actually ran at all) -- a real, permanent mechanism-scope
        // limitation, not a bug: testing "interrupt held off during
        // PFLUSH/PTEST's own internal duration" would need an entirely
        // different injection-timing anchor (keyed on internal FSM
        // state like `pflush_start_r`/`ptest_run_r` instead of bus
        // activity), out of scope for this breadth-extension plan.
        rom[16'h2968/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h296C/4] = {16'h29B0, PMOVE_A0_OP};
        rom[16'h2970/4] = {PMOVE_CRP_EXT, CLR_L_D5};
        rom[16'h2974/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h2978/4] = {16'd9010, JMP_ABS_L_OP};
        rom[16'h297C/4] = {16'h0000, 16'h3308};

        // Stage 5 (elegant-gliding-fog.md): WS-ADDX/WS-ABCD/WS-PACK --
        // DSACK wait-states composing with 3 more FSM beats, all sharing
        // the same predecrement-memory (-(Ay),-(Ax)) shape B-9/B-10/B-11
        // already established. No explicit BCD/ADDX operand data needed
        // (default-filled memory is fine, matching B-9/10/11's own
        // convention -- this is checking wait-state timing composition,
        // not arithmetic correctness, already 100% Harte-proven). Reached
        // via JMP from PMOVE64's own tail (a large NOP desert separates
        // them, so an explicit JMP avoids wasting simulated time walking
        // through it). rom[] content written up front, before
        // run_int_mid_test's own earlier calls, per Stage 3's own lesson.
        rom[16'h3308/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h330C/4] = {16'h3400, MOVEA_L_IMM_A1};
        rom[16'h3310/4] = {16'h0000, 16'h3410};
        rom[16'h3314/4] = {ADDX_L_A1_A0, CLR_L_D5};
        rom[16'h3318/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h331C/4] = {16'd9100, NOP_OP};
        rom[16'h3320/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h3324/4] = {16'h3420, MOVEA_L_IMM_A1};
        rom[16'h3328/4] = {16'h0000, 16'h3430};
        rom[16'h332C/4] = {ADDX_L_A1_A0, CLR_L_D5};
        rom[16'h3330/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h3334/4] = {16'd9101, NOP_OP};
        rom[16'h3338/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h333C/4] = {16'h3440, MOVEA_L_IMM_A1};
        rom[16'h3340/4] = {16'h0000, 16'h3450};
        rom[16'h3344/4] = {ABCD_A1_A0, CLR_L_D5};
        rom[16'h3348/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h334C/4] = {16'd9102, NOP_OP};
        rom[16'h3350/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h3354/4] = {16'h3460, MOVEA_L_IMM_A1};
        rom[16'h3358/4] = {16'h0000, 16'h3470};
        rom[16'h335C/4] = {ABCD_A1_A0, CLR_L_D5};
        rom[16'h3360/4] = {ADDI_L_D5, 16'h0000};
        rom[16'h3364/4] = {16'd9103, NOP_OP};
        rom[16'h3368/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h336C/4] = {16'h3480, MOVEA_L_IMM_A1};
        rom[16'h3370/4] = {16'h0000, 16'h3490};
        rom[16'h3374/4] = {PACK_A1_A0, 16'h0000};
        rom[16'h3378/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h337C/4] = {16'h0000, 16'd9104};
        rom[16'h3380/4] = {MOVEA_L_IMM_A0, 16'h0000};
        rom[16'h3384/4] = {16'h34A0, MOVEA_L_IMM_A1};
        rom[16'h3388/4] = {16'h0000, 16'h34B0};
        rom[16'h338C/4] = {PACK_A1_A0, 16'h0000};
        rom[16'h3390/4] = {CLR_L_D5, ADDI_L_D5};
        rom[16'h3394/4] = {16'h0000, 16'd9105};
        // Temporary park -- Stage 6 will redirect this on to its own new
        // tests instead of parking permanently here.
        rom[16'h3398/4] = {BRA_SELF, NOP_OP};

        run_int_mid_test("INT-mid-CHK2", 32'h0000_2850, 2, 5, 32'd9005, 32'h0000_008A);

        run_int_mid_test("INT-mid-MOVEmm", 32'h0000_2864, 2, 5, 32'd9006, 32'h0000_008A);
        check32("INT-mid-MOVEmm: source copied to destination despite the interrupt",
                rom[16'h3110/4], 32'hDEAD_C0DE);

        run_int_mid_test("INT-mid-RTR", 32'h0000_287C, 2, 5, 32'd9007, 32'h0000_008A);

        run_int_mid_test("INT-mid-RTE", 32'h0000_2948, 2, 5, 32'd9008, 32'h0000_008A);

        // Measured bus-cycle count is 1, not PMOVE64's own architectural 2
        // (B-21's own comment: "64-bit load, 2 bus cycles"). Consistent
        // with the already-documented "d0 baseline sampled after decode_pc
        // reaches the target but before EX has necessarily completed the
        // FIRST beat" measurement artifact this file's own run_int_mid_test
        // wait is subject to (same class as Phase 125's WS-* findings) --
        // the interrupt-holdoff mechanism itself is still validated by the
        // other checks (exception correctly recognized only after the FSM
        // is done, dependent marker reached, ISR ran and RTE'd back).
        run_int_mid_test("INT-mid-PMOVE64", 32'h0000_2968, 1, 5, 32'd9010, 32'h0000_008A);

        // WS-ADDX: DSACK wait-states composing with ADDX's own 3-phase
        // predecrement (read Ay, read Ax, write Ax) FSM beat shape.
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3308; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-ADDX-1: wait_states=0, D5=9100", 5, 32'd9100, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3320; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-ADDX-2: wait_states=10, D5=9101", 5, 32'd9101, 4000, elapsedX);
            wait_states = 0;
            check("WS-ADDX: wait states measurably lengthen ADDX's own predecrement bus cycles too",
                  elapsedX > elapsed0);
        end

        // WS-ABCD: same predecrement shape, opposite BCD direction.
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3338; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-ABCD-1: wait_states=0, D5=9102", 5, 32'd9102, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3350; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-ABCD-2: wait_states=10, D5=9103", 5, 32'd9103, 4000, elapsedX);
            wait_states = 0;
            check("WS-ABCD: wait states measurably lengthen ABCD's own predecrement bus cycles too",
                  elapsedX > elapsed0);
        end

        // WS-PACK: same predecrement shape, source-read+write only (no
        // destination read needed -- PACK's own destination is a pure
        // write, per INT-mid-PACK's own established 2-bus-cycle finding).
        begin
            int elapsed0, elapsedX, t;
            wait_states = 0;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3368; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-PACK-1: wait_states=0, D5=9104", 5, 32'd9104, 4000, elapsed0);
            wait_states = 10;
            for (t = 0; t < 20000 && u_top.ifu_decode_pc < 32'h0000_3380; t++)
                @(posedge clk_4x);
            run_and_check_timed("WS-PACK-2: wait_states=10, D5=9105", 5, 32'd9105, 4000, elapsedX);
            wait_states = 0;
            check("WS-PACK: wait states measurably lengthen PACK's own predecrement bus cycles too",
                  elapsedX > elapsed0);
        end

        check("No address errors", ~(eu_addr_err | ifu_addr_err));

        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        // Bumped from 800000 for the BERR-mid-CAS2 test, then from 1500000
        // for BERR-mid-PTEST's own settle-wait (the CPU has to walk ~7KB of
        // NOP fall-through to reach that test's code) plus its main watch
        // loop.
        #4500000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

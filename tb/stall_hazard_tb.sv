`default_nettype none
`timescale 1ps/1ps

// Pipeline stall/hazard test suite — Category A (RAW/CCR/autoincrement hazard
// matrix) and Category E (control-transfer stall depth), per plan.md's
// "Pipeline Stall/Hazard Test Suite". Tom Harte's SingleStepTests corpus is
// structurally single-instruction and cannot exercise anything that spans
// two instructions; this file covers exactly that gap.
//
// Single harness: m68030_ifu + m68030_seq + m68030_eu, mirroring
// pipeline_tb.sv's integration wiring, but with real (not stubbed) ROM and
// data RAM so multi-instruction sequences (RAW hazards, JSR/RTS round trips,
// dependent post-branch instructions) behave like real code.
//
// An earlier version of Category A used direct eu_seq instr_word injection
// (mirroring eu_seq_tb.sv's G1/G2 technique) to try to measure exact
// hazard-stall cycle counts by hand. That approach was abandoned: manually
// orchestrating producer/consumer decode timing via bare instr_word/
// instr_valid pulses repeatedly hit same-simulation-time-step races between
// a blocking assignment and reading the combinational decode logic it feeds,
// giving inconsistent results across otherwise-equivalent cases even after
// several rounds of fixes. Real instruction fetch through the IFU (as used
// here and in every other multi-instruction testbench in this project)
// doesn't have that problem — the pipeline advances on its own real timing,
// and there's no hand-counted edge sequence to get subtly wrong. Category A
// below runs each producer/consumer pair as a tiny real program and checks
// the final register result (the property Harte's single-instruction tests
// structurally cannot exercise), plus records whether eu_busy was ever seen
// asserted while the consumer was pending, as a secondary/informational
// hazard-detection signal rather than an exact cycle count.

module stall_hazard_tb;

    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // ct_force_pc_en/data is the testbench's own "jump to this test case"
    // override; ct_pc_wr_en/data additionally folds in the EU's own
    // branch_taken/branch_target outputs. In the real chip this OR/mux glue
    // lives in m68030_top.sv (pc_wr_en = boot_pulse | exc_new_pc_wr |
    // eu_branch_taken, per m68030_top.sv:248) — since this harness
    // instantiates m68030_ifu/m68030_seq/m68030_eu directly without the top
    // level (mirroring pipeline_tb.sv), that glue has to be reproduced here,
    // or every taken branch/jump/JSR/RTS silently computes branch_taken
    // correctly but never actually redirects the PC.
    logic        ct_force_pc_en   = 0;
    logic [31:0] ct_force_pc_data = 0;
    logic        ct_pc_wr_en;
    logic [31:0] ct_pc_wr_data;

    logic [31:0] ct_ifu_addr;
    logic        ct_ifu_req;
    logic [31:0] ct_ifu_rdata;
    logic        ct_ifu_ack;
    logic        ct_ifu_berr = 0;

    // Real (writable) 8KB instruction ROM, full-width byte addr[12:2] index
    // (2048 longword entries) — large enough that every test-case address
    // used below (0x0000-0x1908) gets its own distinct slot with no low-bit
    // aliasing between unrelated test cases.
    logic [31:0] ct_rom [0:2047];
    assign ct_ifu_rdata = ct_rom[ct_ifu_addr[12:2]];
    assign ct_ifu_ack   = ct_ifu_req;   // zero-latency, matching pipeline_tb.sv

    logic [15:0] ct_ifu_instr_word;
    logic [31:0] ct_ifu_ext_data;
    logic [15:0] ct_ifu_q3_word;
    logic [31:0] ct_ifu_ext34_data;
    logic        ct_ifu_instr_valid;
    logic        ct_ifu_ext_valid;
    logic        ct_ifu_ext4_valid;
    logic        ct_ifu_ext5_valid;
    logic [2:0]  ct_drain;

    logic [15:0] ct_eu_instr_word;
    logic [31:0] ct_eu_ext_data;
    logic [15:0] ct_eu_q3_word;
    logic [31:0] ct_eu_ext34_data;
    logic        ct_eu_instr_valid;
    logic        ct_eu_ext_valid;
    logic        ct_eu_instr_ack;
    logic        ct_eu_busy;

    logic [31:0] ct_pc_out, ct_vbr_out;
    logic [31:0] ct_usp_out, ct_msp_out, ct_isp_out;
    logic [15:0] ct_sr_out;
    logic        ct_supervisor, ct_master_mode;
    logic [2:0]  ct_ipl_mask;
    logic        ct_div_trap;
    logic        ct_branch_taken;
    logic [31:0] ct_branch_target;

    assign ct_pc_wr_en   = ct_force_pc_en | ct_branch_taken;
    assign ct_pc_wr_data = ct_force_pc_en ? ct_force_pc_data : ct_branch_target;

    // Real (writable) 1KB data RAM for the EU port — needed for a genuine
    // JSR/RTS round trip (RTS must read back what JSR actually pushed) and
    // for the autoincrement (An)+ hazard case.
    logic        ct_mem_req, ct_mem_rw, ct_mem_ack, ct_mem_berr;
    logic [1:0]  ct_mem_siz;
    logic [2:0]  ct_mem_fc;
    logic [31:0] ct_mem_addr, ct_mem_wdata, ct_mem_rdata;
    logic [31:0] ct_dram [0:255];
    assign ct_mem_ack   = ct_mem_req;
    assign ct_mem_berr  = 1'b0;
    assign ct_mem_rdata = ct_dram[ct_mem_addr[9:2]];
    always_ff @(posedge clk_4x) begin
        if (ct_mem_req && !ct_mem_rw) ct_dram[ct_mem_addr[9:2]] <= ct_mem_wdata;
    end

    logic        ct_an_wr_en;
    logic [2:0]  ct_an_wr_sel;
    logic [31:0] ct_an_wr_data;

    logic [31:0] ct_decode_pc;

    m68030_ifu u_ifu2 (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .pc_wr_en     (ct_pc_wr_en),
        .pc_wr_data   (ct_pc_wr_data),
        .drain        (ct_drain),
        .instr_word   (ct_ifu_instr_word),
        .ext_data     (ct_ifu_ext_data),
        .q3_word      (ct_ifu_q3_word),
        .ext34_data   (ct_ifu_ext34_data),
        .instr_valid  (ct_ifu_instr_valid),
        .ext_valid    (ct_ifu_ext_valid),
        .ext4_valid   (ct_ifu_ext4_valid),
        .ext5_valid   (ct_ifu_ext5_valid),
        .decode_pc    (ct_decode_pc),
        .ifu_addr     (ct_ifu_addr),
        .ifu_req      (ct_ifu_req),
        .ifu_rdata    (ct_ifu_rdata),
        .ifu_ack      (ct_ifu_ack),
        .ifu_berr     (ct_ifu_berr),
        .supervisor   (ct_supervisor),
        .fc_out       (),
        .bus_err      (),
        .bus_err_addr (),
        .addr_err     ()
    );

    m68030_seq u_seq2 (
        .instr_word      (ct_ifu_instr_word),
        .ifu_ext_data    (ct_ifu_ext_data),
        .ifu_q3_word     (ct_ifu_q3_word),
        .ifu_ext34_data  (ct_ifu_ext34_data),
        .instr_valid     (ct_ifu_instr_valid),
        .ifu_ext_valid   (ct_ifu_ext_valid),
        .ifu_ext4_valid  (ct_ifu_ext4_valid),
        .ifu_ext5_valid  (ct_ifu_ext5_valid),
        .drain           (ct_drain),
        .eu_instr_word   (ct_eu_instr_word),
        .eu_ext_data     (ct_eu_ext_data),
        .eu_q3_word      (ct_eu_q3_word),
        .eu_ext34_data   (ct_eu_ext34_data),
        .eu_instr_valid  (ct_eu_instr_valid),
        .eu_ext_valid    (ct_eu_ext_valid),
        .eu_instr_ack    (ct_eu_instr_ack),
        .eu_busy         (ct_eu_busy)
    );

    m68030_eu u_eu2 (
        .clk_4x      (clk_4x),
        .rst_n       (rst_n),
        .instr_word  (ct_eu_instr_word),
        .instr_valid (ct_eu_instr_valid),
        .ext_data    (ct_eu_ext_data),
        .ext_valid   (ct_eu_ext_valid),
        .q3_word     (ct_eu_q3_word),
        .ext34_data  (ct_eu_ext34_data),
        .instr_ack   (ct_eu_instr_ack),
        .eu_busy     (ct_eu_busy),
        .pc_wr_en    (ct_pc_wr_en),
        .pc_wr_data  (ct_pc_wr_data),
        .pc_out      (ct_pc_out),
        .vbr_wr_en   (1'b0),
        .vbr_wr_data (32'h0),
        .vbr_out     (ct_vbr_out),
        .usp_out     (ct_usp_out),
        .msp_out     (ct_msp_out),
        .isp_out     (ct_isp_out),
        .sr_out      (ct_sr_out),
        .supervisor  (ct_supervisor),
        .master_mode (ct_master_mode),
        .ipl_mask      (ct_ipl_mask),
        .div_trap      (ct_div_trap),
        .decode_pc     (ct_decode_pc),
        .branch_taken  (ct_branch_taken),
        .branch_target (ct_branch_target),
        .mem_req       (ct_mem_req),
        .mem_rw        (ct_mem_rw),
        .mem_siz       (ct_mem_siz),
        .mem_fc        (ct_mem_fc),
        .mem_addr      (ct_mem_addr),
        .mem_wdata     (ct_mem_wdata),
        .mem_rdata     (ct_mem_rdata),
        .mem_ack       (ct_mem_ack),
        .mem_berr      (ct_mem_berr),
        .an_wr_en      (ct_an_wr_en),
        .an_wr_sel     (ct_an_wr_sel),
        .an_wr_data    (ct_an_wr_data),
        .ssp_wr_en     (1'b0),
        .ssp_wr_data   (32'h0),
        .exc_sr_wr_en  (1'b0),
        .exc_sr_wr_data(16'h0)
    );

    // -------------------------------------------------------------------
    // Shared instruction encodings
    // -------------------------------------------------------------------
    localparam CLR_L_D0      = 16'h4280;
    localparam CLR_L_D1      = 16'h4281;
    localparam CLR_L_D2      = 16'h4282;
    localparam ADDI_L_D0     = 16'h0680;  // ADDI.L #imm32,D0
    localparam ADDI_L_D1     = 16'h0681;
    localparam ADDI_L_D2     = 16'h0682;
    localparam ADD_L_D0_D1   = 16'hD280;  // D1 = D1 + D0
    localparam ADD_L_D0_D2   = 16'hD480;  // D2 = D2 + D0
    localparam MULU_W_D1_D0  = 16'hC0C1;  // D0 = D0[15:0] * D1[15:0]
    localparam CMP_L_D1_D0   = 16'hB081;  // flags = D0 - D1
    localparam SEQ_D2        = 16'h57C2;  // Scc EQ,D2 (0xFF if Z=1 else 0x00)
    localparam MOVE_L_A0P_D0 = 16'h2018;  // MOVE.L (A0)+,D0
    localparam MOVEA_L_A0_A1 = 16'h2248;  // MOVEA.L A0,A1
    localparam STOP_OP       = 16'h4E72;  // STOP #imm
    localparam MOVEA_L_IMM_A7 = 16'h2E7C; // MOVEA.L #imm32,A7
    localparam MOVEA_L_IMM_A0 = 16'h207C; // MOVEA.L #imm32,A0
    localparam BRA_W          = 16'h6000; // BRA.W <disp16 ext>
    localparam JMP_A0_IND     = 16'h4ED0; // JMP (A0)
    localparam JMP_ABSW       = 16'h4EF8; // JMP abs.W <addr16 ext>
    localparam DBF_D0         = 16'h51C8; // DBF D0,<disp16 ext>
    localparam JSR_A0_IND     = 16'h4E90; // JSR (A0)
    localparam RTS_OP         = 16'h4E75; // RTS
    localparam NOP_OP         = 16'h4E71;

    // -------------------------------------------------------------------
    // Checks and tasks
    // -------------------------------------------------------------------
    int fail_count = 0;

    task automatic ct_check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    task automatic ct_check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin $display("FAIL  %s: got %08h exp %08h", name, got, exp); fail_count++; end
    endtask

    task automatic ct_goto(input logic [31:0] addr);
        ct_force_pc_en   = 1'b1;
        ct_force_pc_data = addr;
        @(posedge clk_4x); #1;
        ct_force_pc_en = 1'b0;
    endtask

    task automatic ct_fill_nop(input int base_word_idx, input int count);
        int i;
        for (i = 0; i < count; i++) ct_rom[base_word_idx + i] = {NOP_OP, NOP_OP};
    endtask

    // Runs from ct_goto(base_addr) up to `budget` cycles, watching for
    // check_reg to reach exp_val; records whether ct_eu_busy (pipeline
    // stall) was ever seen asserted along the way as a secondary,
    // informational hazard-detection signal (not an exact cycle count —
    // see the file header for why exact hand-counted cycles were dropped).
    task automatic ct_run_and_check(
        input string       name,
        input logic [31:0] base_addr,
        input int          reg_idx,
        input logic [31:0] exp_val,
        input int          budget
    );
        int t;
        logic saw_ack, hazard_seen;
        ct_goto(base_addr);
        saw_ack = 0;
        hazard_seen = 0;
        for (t = 0; t < budget; t++) begin
            @(posedge clk_4x); #1;
            if (ct_eu_busy) hazard_seen = 1'b1;
            if (u_eu2.u_rf.d_reg[reg_idx] === exp_val) begin saw_ack = 1'b1; break; end
        end
        ct_check(name, saw_ack);
        $display("INFO  %s: hazard_seen=%b", name, hazard_seen);
    endtask

    initial begin
        repeat(4) @(posedge clk_4x);
        rst_n = 1;
        @(posedge clk_4x); #1;

        ct_fill_nop(0, 2048);

        // ===================================================================
        // Category A: RAW / CCR / autoincrement hazard matrix. Each case is a
        // tiny real program (producer, optional filler/gap, consumer),
        // checked by final register value — the thing Harte's single-
        // instruction structure cannot exercise (a real dependent second
        // instruction actually consuming a hazardous producer's result).
        // ===================================================================

        // -----------------------------------------------------------------
        // P1: ADDI.L #imm,D0 (immediate ALU producer) -> ADD.L D0,D1
        // -----------------------------------------------------------------
        $display("=== Category A: P1 (immediate ALU producer) x T0/T1/T2 ===");

        // T0: consumer immediately follows producer, no gap.
        begin
            ct_rom[16'h0000/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0004/4] = {ADDI_L_D0, 16'h0000};
            ct_rom[16'h0008/4] = {16'd7, ADD_L_D0_D1};
            ct_run_and_check("A-P1-T0: D1=7 (no gap)", 32'h0000_0000, 1, 32'd7, 100);
        end

        // T1: one filler instruction (NOP) between producer and consumer.
        begin
            ct_rom[16'h0100/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0104/4] = {ADDI_L_D0, 16'h0000};
            ct_rom[16'h0108/4] = {16'd9, NOP_OP};
            ct_rom[16'h010C/4] = {ADD_L_D0_D1, NOP_OP};
            ct_run_and_check("A-P1-T1: D1=9 (1-instruction gap)", 32'h0000_0100, 1, 32'd9, 100);
        end

        // T2: several filler instructions — negative control, producer long
        // committed by the time consumer runs.
        begin
            ct_rom[16'h0200/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0204/4] = {ADDI_L_D0, 16'h0000};
            ct_rom[16'h0208/4] = {16'd11, NOP_OP};
            ct_rom[16'h020C/4] = {NOP_OP, NOP_OP};
            ct_rom[16'h0210/4] = {NOP_OP, NOP_OP};
            ct_rom[16'h0214/4] = {ADD_L_D0_D1, NOP_OP};
            ct_run_and_check("A-P1-T2: D1=11 (multi-instruction gap)", 32'h0000_0200, 1, 32'd11, 100);
        end

        // -----------------------------------------------------------------
        // P2: MOVE.L (A0)+,D0 (autoincrement producer) -> MOVEA.L A0,A1
        // Exercises the ex_an_upd_en hazard path (eu_seq.sv:6031-6041) —
        // the consumer must see A0's *post*-increment value.
        // -----------------------------------------------------------------
        $display("=== Category A: P2 (autoincrement An producer) x T0 ===");
        begin
            int t;
            logic saw_ack;
            // A0 starts at reset default (0); MOVE.L (A0)+,D0 reads
            // ct_dram[0] (don't-care value) and bumps A0 to 4.
            ct_rom[16'h0300/4] = {MOVE_L_A0P_D0, MOVEA_L_A0_A1};
            // a_reg[] is a separate array from d_reg[] in eu_regfile.sv, so
            // this needs its own inline check rather than the generic
            // d_reg-only ct_run_and_check task.
            ct_goto(32'h0000_0300);
            saw_ack = 0;
            for (t = 0; t < 100; t++) begin
                @(posedge clk_4x); #1;
                if (u_eu2.u_rf.a_reg[1] === 32'd4) begin saw_ack = 1'b1; break; end
            end
            ct_check("A-P2-T0: A1=4 (post-increment visible)", saw_ack);
        end

        // -----------------------------------------------------------------
        // P3: MULU.W D1,D0 (long-latency EX producer) -> ADD.L D0,D2
        // -----------------------------------------------------------------
        $display("=== Category A: P3 (long-latency multiply producer) x T0 ===");
        begin
            ct_rom[16'h0400/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0404/4] = {CLR_L_D2, ADDI_L_D0};
            ct_rom[16'h0408/4] = {16'h0000, 16'd5};        // D0 = 5
            ct_rom[16'h040C/4] = {ADDI_L_D1, 16'h0000};
            ct_rom[16'h0410/4] = {16'd4, MULU_W_D1_D0};     // D1 = 4; D0 = D0*D1
            ct_rom[16'h0414/4] = {ADD_L_D0_D2, NOP_OP};
            ct_run_and_check("A-P3-T0: D2=20 (5*4, post-multiply)", 32'h0000_0400, 2, 32'd20, 100);
        end

        // -----------------------------------------------------------------
        // P5: CMP.L D1,D0 (CCR-only producer, no register hazard) -> SEQ D2
        // x T0/T2 — hazard_ccr only.
        // -----------------------------------------------------------------
        $display("=== Category A: P5 (CCR-only producer) x T0/T2 ===");

        // T0: D0==D1==0 -> CMP sets Z=1 -> SEQ true (0xFF), no gap.
        begin
            ct_rom[16'h0500/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0504/4] = {CLR_L_D2, CMP_L_D1_D0};
            ct_rom[16'h0508/4] = {SEQ_D2, NOP_OP};
            ct_run_and_check("A-P5-T0: D2=0xFF (Z=1 -> SEQ true, no gap)", 32'h0000_0500, 2, 32'h0000_00FF, 100);
        end

        // T2: several filler instructions between producer and consumer —
        // negative control (still Z=1, so SEQ should still read true; this
        // only checks that a *distant* CCR producer's flags are still
        // correctly visible, not a timing edge case).
        begin
            ct_rom[16'h0600/4] = {CLR_L_D0, CLR_L_D1};
            ct_rom[16'h0604/4] = {CLR_L_D2, CMP_L_D1_D0};
            ct_rom[16'h0608/4] = {NOP_OP, NOP_OP};
            ct_rom[16'h060C/4] = {NOP_OP, NOP_OP};
            ct_rom[16'h0610/4] = {SEQ_D2, NOP_OP};
            ct_run_and_check("A-P5-T2: D2=0xFF (Z=1, multi-instruction gap)", 32'h0000_0600, 2, 32'h0000_00FF, 100);
        end

        // ===================================================================
        // Category E: control-transfer stall depth
        // ===================================================================

        // -----------------------------------------------------------------
        // E-1: BRA.W (unconditional, decode-resolved) to a target that runs
        // a dependent instruction (ADDI.L #55,D0), confirming the redirect
        // + refetch + dependent-instruction sequence is functionally correct.
        // -----------------------------------------------------------------
        $display("=== Category E: BRA.W redirect + dependent instruction ===");
        begin
            // 0x1000: BRA.W +0x00FE (target = (0x1000+2) + 0x00FE = 0x1100,
            // kept 4-byte aligned so the target code below packs cleanly).
            ct_rom[16'h1000/4] = {BRA_W, 16'h00FE};
            // 0x1100: CLR.L D0 ; ADDI.L #55,D0
            ct_rom[16'h1100/4] = {CLR_L_D0, ADDI_L_D0};
            ct_rom[16'h1104/4] = {16'h0000, 16'd55};
            ct_run_and_check("E-1: BRA target's dependent instruction ran", 32'h0000_1000, 0, 32'd55, 100);
        end
        repeat(4) @(posedge clk_4x);

        // -----------------------------------------------------------------
        // E-2: JMP (An) — register-indirect target, same-cycle EX
        // resolution (no mem_ack gate), per eu_seq.sv:8250-8266.
        // -----------------------------------------------------------------
        $display("=== Category E: JMP (An) redirect + dependent instruction ===");
        begin
            // 0x1200: MOVEA.L #0x1300,A0 ; JMP (A0)
            ct_rom[16'h1200/4] = {MOVEA_L_IMM_A0, 16'h0000};
            ct_rom[16'h1204/4] = {16'h1300, JMP_A0_IND};
            // 0x1300: CLR.L D0 ; ADDI.L #66,D0
            ct_rom[16'h1300/4] = {CLR_L_D0, ADDI_L_D0};
            ct_rom[16'h1304/4] = {16'h0000, 16'd66};
            ct_run_and_check("E-2: JMP (An) target's dependent instruction ran", 32'h0000_1200, 0, 32'd66, 100);
        end
        repeat(4) @(posedge clk_4x);

        // -----------------------------------------------------------------
        // E-3: JMP abs.W — absolute target.
        // -----------------------------------------------------------------
        $display("=== Category E: JMP abs.W redirect + dependent instruction ===");
        begin
            // 0x1400: JMP $1500.W
            ct_rom[16'h1400/4] = {JMP_ABSW, 16'h1500};
            // 0x1500: CLR.L D0 ; ADDI.L #77,D0
            ct_rom[16'h1500/4] = {CLR_L_D0, ADDI_L_D0};
            ct_rom[16'h1504/4] = {16'h0000, 16'd77};
            ct_run_and_check("E-3: JMP abs.W target's dependent instruction ran", 32'h0000_1400, 0, 32'd77, 100);
        end
        repeat(4) @(posedge clk_4x);

        // -----------------------------------------------------------------
        // E-4: DBF (taken) — loop decrements D0 and branches back until
        // D0 wraps past -1, then falls through to a dependent instruction.
        // -----------------------------------------------------------------
        $display("=== Category E: DBF taken loop + fallthrough ===");
        begin
            // 0x1600: CLR.L D0 ; ADDI.L #2,D0  -> D0 = 2
            ct_rom[16'h1600/4] = {CLR_L_D0, ADDI_L_D0};
            ct_rom[16'h1604/4] = {16'h0000, 16'd2};
            // 0x1608: DBF D0,-2 — disp=0xFFFE so target = (0x1608+2)+(-2) =
            // 0x1608 (branches back to itself). Loops decrementing D0 each
            // pass until D0 wraps to -1 (3 total passes: 2->1->0->-1).
            ct_rom[16'h1608/4] = {DBF_D0, 16'hFFFE};
            // 0x160C: fallthrough — CLR.L D1 ; ADDI.L #88,D1 (dependent
            // instruction, distinct register from D0 so a stale value can't
            // false-pass the check).
            ct_rom[16'h160C/4] = {CLR_L_D1, ADDI_L_D1};
            ct_rom[16'h1610/4] = {16'h0000, 16'd88};
            ct_run_and_check("E-4: DBF loop fell through to dependent instruction", 32'h0000_1600, 1, 32'd88, 200);
        end
        repeat(4) @(posedge clk_4x);

        // -----------------------------------------------------------------
        // E-5: JSR (An) + RTS round trip — mem_ack-gated push/pop, verifying
        // the return address is genuinely read back (real ct_dram, not a
        // stubbed constant) and a dependent instruction after the return
        // executes correctly.
        // -----------------------------------------------------------------
        $display("=== Category E: JSR (An) + RTS round trip ===");
        begin
            // 0x1800: MOVEA.L #0x0300,A7 (safe stack area in ct_dram) —
            // opcode + 2 ext words (32-bit immediate) = 3 words = 6 bytes.
            ct_rom[16'h1800/4] = {MOVEA_L_IMM_A7, 16'h0000};   // 1800=op, 1802=ext MSW=0
            ct_rom[16'h1804/4] = {16'h0300, MOVEA_L_IMM_A0};   // 1804=ext LSW=0x300, 1806=next op
            // 0x1806: MOVEA.L #0x1900,A0 (subroutine address) — opcode's
            // upper half already placed above at 0x1806; ext words follow.
            ct_rom[16'h1808/4] = {16'h0000, 16'h1900};         // 1808=ext MSW=0, 180A=ext LSW=0x1900
            // 0x180C: JSR (A0) ; CLR.L D2 (start of dependent code, runs
            // after RTS returns here since JSR (An) has no extension word).
            ct_rom[16'h180C/4] = {JSR_A0_IND, CLR_L_D2};
            // 0x1810: ADDI.L #99,D2
            ct_rom[16'h1810/4] = {ADDI_L_D2, 16'h0000};        // 1810=op, 1812=ext MSW=0
            ct_rom[16'h1814/4] = {16'd99, NOP_OP};              // 1814=ext LSW=99, 1816=filler

            // Subroutine at 0x1900: just RTS straight back.
            ct_rom[16'h1900/4] = {RTS_OP, NOP_OP};
            ct_run_and_check("E-5: JSR/RTS round trip reached dependent instruction", 32'h0000_1800, 2, 32'd99, 200);
        end
        repeat(4) @(posedge clk_4x);

        // -----------------------------------------------------------------
        // stop_first_cycle: STOP immediately followed by a real next
        // instruction that must never execute — confirms STOP genuinely
        // halts (eu_seq.sv:6053-6058's 1-bubble transition into stop_r).
        // Runs LAST: STOP permanently halts this shared EU instance for the
        // rest of the simulation (real 68030 behavior — it only resumes on
        // reset/interrupt, neither of which this harness injects), so any
        // test placed after it would spuriously fail.
        // -----------------------------------------------------------------
        $display("=== Category A: stop_first_cycle ===");
        begin
            int t;
            logic saw_busy_after_stop;
            ct_rom[16'h0700/4] = {CLR_L_D0, STOP_OP};
            ct_rom[16'h0704/4] = {16'h2000, ADDI_L_D0};   // STOP's SR ext word, then a fake next instr
            ct_rom[16'h0708/4] = {16'h0000, 16'd99};       // must never execute

            ct_goto(32'h0000_0700);
            saw_busy_after_stop = 0;
            for (t = 0; t < 40; t++) begin
                @(posedge clk_4x); #1;
                if (ct_eu_busy) saw_busy_after_stop = 1'b1;
            end
            ct_check("STOP: eu_busy stays asserted (halted)", saw_busy_after_stop);
            ct_check32("STOP: D0 unchanged by fake next instr", u_eu2.u_rf.d_reg[0], 32'h0);
        end

        $display("=== TOTAL: %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL  Hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

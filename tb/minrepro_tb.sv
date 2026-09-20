`default_nettype none
`timescale 1ps/1ps

// Minimal, standalone regression test for
// project_skiptx_branch_target_regwrite_bug.md: a taken branch's redirect
// doesn't discard the *result* of a bus read that was already dispatched,
// before the flush, for the abandoned fall-through path. That stale read
// completes normally and gets pushed into the freshly-flushed prefetch
// queue anyway, indistinguishable from a genuine fetch of the real
// redirect target -- it gets decoded as a fresh opcode, and that spurious
// decode's own (wrong, coincidental) drain count eats real queue words,
// silently consuming the real opcode and/or its own real extension word.
//
// Found via mackerel-030f integration testing (a separate ULX3S FPGA SoC
// project using this repo's rtl/ as a git dependency), then narrowed down
// by delta-debugging the real repro program until only the essential
// shape remained. Getting *this* file to actually reproduce it (rather
// than just running clean) took two more rounds of narrowing beyond that:
//
//   1. The bug needs a genuine reset boot, not a JMP into a mid-file entry
//      point -- every attempt built the second way (this file's own first
//      few attempts included, and every attempt in tb/stall_fsm_tb.sv)
//      passed cleanly.
//   2. The bug also needs the memory model's own read data to be
//      *registered* (one clk_4x cycle after the address is valid) while
//      DSACK asserts *immediately* (the same cycle) -- matching a real
//      memory-mapped peripheral's natural timing (see mackerel_030f.v's
//      own ROM: `rom_dout_r <= rom[...]` registered, `dsack0_n` immediate
//      on address decode). A zero-latency combinational memory model
//      (tb/stall_fsm_tb.sv's own convention, and this file's own first
//      attempt) never exposes the race: the one-cycle gap between "DSACK
//      says the word is ready" and "the registered data actually updates"
//      is exactly what lets the IFU's queue end up holding data from one
//      cycle before the address it's supposed to correspond to, for the
//      specific in-flight-during-a-redirect case this bug depends on.
//
// Neither of these two ingredients alone was sufficient; both attempts
// (reset boot + combinational memory; JMP entry + registered memory) still
// passed cleanly on their own. Confirmed via direct q_cnt/drain/dec_*/
// wb_* tracing (see plan.md's own writeup for this session) that this is
// the exact same mechanism found in the full mackerel-030f SoC repro, not
// a different bug: at the moment of failure, `instr_word` shows 0x0000 (a
// stray fall-through data word, not the real opcode at the redirect
// target), decodes as a spurious ORI.B-shaped "instruction" with
// dest=D0, and commits garbage to D0 with `drain=2` -- silently consuming
// the real `MOVE.L #imm,D1` opcode in the process, so D1 is never
// written.
//
// Program (each rom[] line's own comment gives the exact instruction):
//   MOVEA.L #$FFFFFF00,A0
//   MOVE.L  #0,D0
//   MOVEA.L #0,A1                  (points at ROM, not a real peripheral --
//                                   already confirmed in the full SoC sim
//                                   that the peripheral type doesn't matter)
//   MOVE.L  D0,(A0)                (a write; unrelated to the bug, just
//                                   matches the real repro's own LOOP shape)
//   ADDQ.L  #1,D0
//   MOVE.B  (5,A1),D2              (real memory read; D2 = 0x08, bit5=0)
//   BTST    #5,D2                  (Z=1)
//   BEQ.S   SKIP_TX                (taken -- the redirect under test)
//   <filler, abandoned fall-through path>
// SKIP_TX (deliberately misaligned, offset+2 within its own fetched
// longword -- matching the real repro's exact layout):
//   MOVE.L  #$0000BEEF,D1
//   BRA_SELF                       (park)
//
// If the bug is present, D1 never receives 0x0000BEEF.

module minrepro_tb;

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
    logic        ext_bg_n;
    logic        ext_ipend_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    logic        cback_n  = 1'b0;
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;

        rom[16'h0000/4] = 32'h0000_1000; // initial SSP (placeholder, never dereferenced)
        rom[16'h0004/4] = 32'h0000_0008; // initial PC = 0x08 (START)
        // 0x08-0x0D: MOVEA.L #$FFFFFF00,A0
        rom[16'h0008/4] = {16'h207C, 16'hFFFF};
        rom[16'h000C/4] = {16'hFF00, 16'h203C};  // (imm lo) ; MOVE.L #0,D0 opcode
        // 0x0E-0x13: MOVE.L #0,D0
        rom[16'h0010/4] = {16'h0000, 16'h0000};
        // 0x14-0x19: MOVEA.L #0,A1
        rom[16'h0014/4] = {16'h227C, 16'h0000};
        rom[16'h0018/4] = {16'h0000, 16'h2080}; // (imm lo) ; MOVE.L D0,(A0) opcode
        // 0x1C-0x1D: ADDQ.L #1,D0 ; 0x1E-0x21: MOVE.B (5,A1),D2
        rom[16'h001C/4] = {16'h5280, 16'h1429};
        rom[16'h0020/4] = {16'h0005, 16'h0802}; // (disp=5) ; BTST #5,D2 opcode
        // 0x24-0x25: (bit#=5) ; 0x26-0x27: BEQ.S +6 -> 0x2E
        rom[16'h0024/4] = {16'h0005, 16'h6706};
        // 0x28-0x2D: unreachable filler (abandoned fall-through path)
        rom[16'h0028/4] = {16'h4E71, 16'h4E71};
        rom[16'h002C/4] = {16'h4E71, 16'h223C}; // NOP ; MOVE.L opcode, misaligned at 0x2E
        // 0x30-0x33: MOVE.L's own two extension words
        rom[16'h0030/4] = {16'h0000, 16'hBEEF};
        // 0x34-0x35: BRA_SELF park
        rom[16'h0034/4] = {16'h60FE, 16'h0000};
    end

    wire [11:0] beat_word_addr = ext_a[13:2];

    // Registered read (one clk_4x cycle after the address is valid),
    // matching mackerel_030f.v's own ROM convention exactly -- see this
    // file's own header comment for why this specific timing shape is
    // required to expose the bug.
    reg [31:0] rd_word_reg;
    always @(posedge clk_4x)
        rd_word_reg <= (beat_word_addr < MEM_WORDS) ? rom[beat_word_addr] : 32'hDEAD_DEAD;
    wire [31:0] rd_word = rd_word_reg;

    // Immediate (combinational) DSACK, matching mackerel_030f.v's own ROM
    // response exactly (dsack0_n=0 the same cycle the address decodes,
    // regardless of the registered data path above).
    wire ds_req    = !ext_ds_n & !ext_as_n;
    wire dsack0_n  = ~ds_req;
    wire dsack1_n  = ~ds_req;
    wire avec_n    = 1'b1;

    wire [31:0] ext_d_in = (!ext_ds_n & ext_rw) ? rd_word : {32{1'bz}};

    always_ff @(posedge clk_4x) begin
        if (ds_req && !ext_rw && ext_d_oe) begin
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
        .ext_bg_n     (ext_bg_n),
        .ext_ipend_n  (ext_ipend_n),
        .bus_halted   (bus_halted),
        .eu_addr_err  (eu_addr_err),
        .ifu_addr_err (ifu_addr_err),
        .dsack0_n     (dsack0_n),
        .dsack1_n     (dsack1_n),
        .sterm_n      (sterm_n),
        .berr_n       (berr_n),
        .halt_n       (halt_n),
        .avec_n       (avec_n),
        .ipl_n        (ipl_n),
        .br_n         (br_n),
        .bgack_n      (bgack_n),
        .cback_n      (cback_n),
        .ciin_n       (ciin_n),
        .cdis_n       (cdis_n),
        .mmudis_n     (mmudis_n),
        .ciout_n      ()
    );

    `include "common_helpers.svh"

    initial begin
        rst_n = 0;
        // 20-cycle reset hold, matching tb/stall_fsm_tb.sv's own proven
        // convention exactly -- a too-short hold (e.g. a single timestep)
        // leaves biu_config.sv's own poweron_rstout_n counter at X forever
        // in Icarus, which silently prevents the CPU from ever booting at
        // all (found the hard way while building this file).
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        run_and_check("EXTWORD-RACE: MOVE.L #imm,D1 right after a taken BEQ.S commits its own real value, not a stale-fetch-derived spurious decode (D1=$0000BEEF)",
                      1, 32'h0000_BEEF, 3000);

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

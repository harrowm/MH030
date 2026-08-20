`default_nettype none
`timescale 1ps/1ps

// Batched Harte testbench, compiled with Verilator.
//
// clk_4x/rst_n are driven from C++ main (tb/harte_verilator_main.cpp), no
// `always #5`. Memory is poked directly into mem[] between tests by C++ via
// direct rootp access (mirrors tb/mustest_tb.sv's established pattern) --
// no $readmemh, no per-test SV loop. Same dense 24-bit memory model and
// byte-lane write-capture logic as tb/harte_batch_tb.sv, but MEMWRITE
// reporting is NOT done via $display here: C++ reads mem[] directly after
// each run instead, since Harte's own JSON test format only ever specifies
// initial/final snapshots, never intermediate bus traces -- there is
// nothing a cycle-accurate write log would catch that a final-state
// comparison wouldn't, so this loses no verification fidelity while
// avoiding all print-formatting overhead in the hot loop.

module harte_verilator_tb (
    input  logic clk_4x,
    input  logic rst_n,
    output logic stop_out,
    output logic addr_err_out
);

    logic [31:0] ext_a;
    logic [31:0] ext_d_out;
    logic        ext_d_oe;
    logic        ext_as_n, ext_ds_n, ext_rw;
    logic [2:0]  ext_fc;
    logic [1:0]  ext_siz;
    logic        ext_ecs_n, ext_ocs_n, ext_rstout_n, ext_cbreq_n;
    logic        ext_e, ext_bg_n;
    logic        bus_halted, eu_addr_err, ifu_addr_err;
    logic        eu_stop_out;

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

    // Same dense model as harte_tb.sv/harte_batch_tb.sv (full 24-bit space).
    localparam int MEM_WORDS = 1 << 22;   // 4M words = 16 MB
    logic [31:0] mem [0:MEM_WORDS-1];

    wire [21:0] mem_idx = ext_a[23:2];

    logic [31:0] rd_word_r;
    always_ff @(posedge clk_4x) begin
        if (!ext_ds_n && !ext_as_n && ext_rw) begin
            if (ext_siz == 2'b00 && ext_a[1:0] == 2'b10)
                rd_word_r <= {mem[mem_idx][15:0], mem[mem_idx+1][31:16]};
            else
                rd_word_r <= mem[mem_idx];
        end
    end

    logic ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) ds_active_r <= 1'b0;
        else        ds_active_r <= !ext_ds_n & !ext_as_n;
    end
    wire dsack0_n = ~ds_active_r;
    wire dsack1_n = ~ds_active_r;

    wire [31:0] ext_d_in = ds_active_r ? rd_word_r : '0;

    always_ff @(posedge clk_4x) begin
        if (ds_active_r && !ext_ds_n && !ext_as_n && !ext_rw && ext_d_oe) begin
            case ({ext_siz, ext_a[1:0]})
                4'b00_00: begin
                    mem[mem_idx]        <= ext_d_out;
                end
                4'b00_10: begin
                    mem[mem_idx][15:0]    <= ext_d_out[31:16];
                    mem[mem_idx+1][31:16] <= ext_d_out[15:0];
                end
                4'b10_00: mem[mem_idx][31:16] <= ext_d_out[31:16];
                4'b10_10: mem[mem_idx][15:0]  <= ext_d_out[15:0];
                4'b01_00: mem[mem_idx][31:24] <= ext_d_out[31:24];
                4'b01_01: mem[mem_idx][23:16] <= ext_d_out[23:16];
                4'b01_10: mem[mem_idx][15:8]  <= ext_d_out[15:8];
                4'b01_11: mem[mem_idx][7:0]   <= ext_d_out[7:0];
                default:  mem[mem_idx]        <= ext_d_out;
            endcase
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
        .eu_stop      (eu_stop_out),
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

    logic stop_seen;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) stop_seen <= 1'b0;
        else if (eu_stop_out) stop_seen <= 1'b1;
    end

    // Capture SR just before STOP overwrites it (STOP #$2700 clobbers CCR).
    // Originally gated on !eu_stop_out, on the false assumption that it
    // always asserts exactly one cycle after the last real instruction's
    // own sr_r commit (true for every fetch-timing profile this project
    // exercised before the I-cache existed, not a real invariant -- an
    // I-cache hit on STOP's own opcode fetch can land eu_stop_out the
    // *same* cycle as that commit, silently dropping it). A second attempt
    // gated on !stop_seen ("capture one more cycle") overcorrected the
    // other way for RMW-style memory-dest instructions. A third attempt
    // gated on !stop_sr_wr_en (eu_seq.sv's own combinational
    // ex_valid && ex_is_stop && !stop_r, exactly the cycle STOP's own SR
    // write is about to land) looked right but stop_sr_wr_en is a
    // ONE-CYCLE PULSE, not a level: it drops back to 0 the very next
    // cycle (once stop_r itself becomes 1), which re-opens the capture
    // gate and immediately picks up STOP's now-already-landed "#$2700"
    // value anyway (all found via Phase 127's own cache plan Step 6,
    // confirmed by direct sr_r/stop_r/stop_sr_wr_en tracing at each
    // step). stop_r itself is the level that actually matters: it goes 1
    // on the same edge stop_sr_wr_en fires and *stays* 1 thereafter, so
    // gating on !stop_r permanently freezes capture from that edge on,
    // correctly keeping whatever sr_r held the cycle before.
    logic [15:0] sr_before_stop;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) sr_before_stop <= 16'h0;
        else if (!u_top.u_eu.u_seq.stop_r)
            sr_before_stop <= u_top.u_eu.u_rf.sr_r;
    end

    logic any_addr_err;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) any_addr_err <= 1'b0;
        else if (eu_addr_err || ifu_addr_err) any_addr_err <= 1'b1;
    end

    assign stop_out     = stop_seen;
    assign addr_err_out = any_addr_err;

endmodule

`default_nettype wire

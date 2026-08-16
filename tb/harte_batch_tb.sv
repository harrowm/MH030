`default_nettype none
`timescale 1ps/1ps

// PROTOTYPE — batched Tom Harte SingleStepTests runner.
//
// Same DUT wiring and memory model as tb/harte_tb.sv, but loops over many
// hex files inside a single vvp process instead of one process per test, to
// amortize Icarus's fixed per-process elaboration cost (measured ~0.18-0.2s,
// the dominant cost of a full sweep — see plan.md's Harte-sweep-performance
// investigation). Not yet wired into scripts/run_harte.py or the Makefile —
// this is a standalone timing/correctness prototype.
//
// Usage: vvp sim/harte_batch +manifest=<path> [+cycles=<N>]
//   manifest = a text file, one hex-file path per line.
//
// Output per test, delimited so a driver script can split reliably:
//   === TEST <idx> ===
//   REGSTATE ...
//   MEMWRITE ...            (zero or more)
//   OK | TIMEOUT | ADDRERR
//   ENDTEST

module harte_batch_tb;

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
    logic        eu_stop_out;

    logic        sterm_n = 1'b1;
    logic        berr_n  = 1'b1;
    logic        halt_n  = 1'b1;
    logic        avec_n  = 1'b1;
    logic        vpa_n   = 1'b1;
    logic [2:0]  ipl_n   = 3'b111;
    logic        br_n    = 1'b1;
    logic        bgack_n = 1'b1;
    logic        cback_n = 1'b0;

    // Same dense model as harte_tb.sv (full 24-bit space, no aliasing).
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
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b00}, ext_d_out[31:24]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b01}, ext_d_out[23:16]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b10}, ext_d_out[15:8]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b11}, ext_d_out[7:0]);
                end
                4'b00_10: begin
                    mem[mem_idx][15:0]    <= ext_d_out[31:16];
                    mem[mem_idx+1][31:16] <= ext_d_out[15:0];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b10},   ext_d_out[31:24]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b11},   ext_d_out[23:16]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2]+22'd1,2'b00}, ext_d_out[15:8]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2]+22'd1,2'b01}, ext_d_out[7:0]);
                end
                4'b10_00: begin
                    mem[mem_idx][31:16] <= ext_d_out[31:16];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b00}, ext_d_out[31:24]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b01}, ext_d_out[23:16]);
                end
                4'b10_10: begin
                    mem[mem_idx][15:0]  <= ext_d_out[15:0];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b10}, ext_d_out[15:8]);
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b11}, ext_d_out[7:0]);
                end
                4'b01_00: begin
                    mem[mem_idx][31:24] <= ext_d_out[31:24];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b00}, ext_d_out[31:24]);
                end
                4'b01_01: begin
                    mem[mem_idx][23:16] <= ext_d_out[23:16];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b01}, ext_d_out[23:16]);
                end
                4'b01_10: begin
                    mem[mem_idx][15:8]  <= ext_d_out[15:8];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b10}, ext_d_out[15:8]);
                end
                4'b01_11: begin
                    mem[mem_idx][7:0]   <= ext_d_out[7:0];
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b11}, ext_d_out[7:0]);
                end
                default: begin
                    mem[mem_idx]        <= ext_d_out;
                    $display("MEMWRITE %06x %02x", {ext_a[23:2],2'b00}, ext_d_out[31:24]);
                end
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
        .cback_n      (cback_n)
    );

    // Reset-gated on the same rst_n edge as every DUT register, so a mid-run
    // reset pulse clears these deterministically instead of racing a
    // procedural blocking-assignment "clear" in the initial block against
    // the nonblocking update from a still-high eu_stop_out/eu_addr_err left
    // over from the previous test on the very same clock edge.
    logic stop_seen;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) stop_seen <= 1'b0;
        else if (eu_stop_out) stop_seen <= 1'b1;
    end

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
    // value anyway (all three found via Phase 127's own cache plan Step
    // 6, confirmed by direct sr_r/stop_r/stop_sr_wr_en tracing at each
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

    // ── Main: loop over the manifest ────────────────────────────────────────
    initial begin
        string manifest_path;
        string hexfile;
        integer cycles;
        integer clear_mem;
        int mfd;
        int idx;
        int i;
        int code;

        if (!$value$plusargs("manifest=%s", manifest_path)) begin
            $display("ERROR: +manifest=<path> required");
            $finish;
        end
        if (!$value$plusargs("cycles=%d", cycles)) cycles = 8000;
        if (!$value$plusargs("clearmem=%d", clear_mem)) clear_mem = 1;

        mfd = $fopen(manifest_path, "r");
        if (mfd == 0) begin
            $display("ERROR: cannot open manifest %s", manifest_path);
            $finish;
        end

        idx = 0;
        while (!$feof(mfd)) begin
            code = $fgets(hexfile, mfd);
            if (code == 0) begin
                // fgets returns 0 at EOF with nothing read
            end else begin
                // $sscanf %s reads one whitespace-delimited token, which
                // drops the trailing newline/CR $fgets leaves in place.
                code = $sscanf(hexfile, "%s", hexfile);

                if (hexfile.len() > 0) begin
                    if (clear_mem)
                        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = '0;

                    $readmemh(hexfile, mem);

                    // Printed BEFORE the run (not after) so live MEMWRITE
                    // output from the concurrent memory-model always_ff —
                    // which fires DURING the fork/join below, chronologically
                    // before any post-join $display — lands inside this
                    // test's own block instead of leaking into the previous
                    // one's. A driver script splits on this marker.
                    $display("=== TEST %0d ===", idx);

                    // stop_seen/any_addr_err/sr_before_stop are cleared by
                    // the rst_n pulse below (same async-reset discipline as
                    // the DUT), not by a procedural blocking assignment here.
                    rst_n = 0;
                    repeat(20) @(posedge clk_4x);
                    #1; rst_n = 1;

                    fork
                        begin : blk_timeout
                            repeat(cycles) @(posedge clk_4x);
                            disable blk_stop;
                        end
                        begin : blk_stop
                            wait(stop_seen == 1'b1);
                            repeat(4) @(posedge clk_4x);
                            disable blk_timeout;
                        end
                    join

                    $display("REGSTATE D0=%h D1=%h D2=%h D3=%h D4=%h D5=%h D6=%h D7=%h A0=%h A1=%h A2=%h A3=%h A4=%h A5=%h A6=%h A7=%h SR=%h PC=%h",
                        u_top.u_eu.u_rf.d_reg[0], u_top.u_eu.u_rf.d_reg[1],
                        u_top.u_eu.u_rf.d_reg[2], u_top.u_eu.u_rf.d_reg[3],
                        u_top.u_eu.u_rf.d_reg[4], u_top.u_eu.u_rf.d_reg[5],
                        u_top.u_eu.u_rf.d_reg[6], u_top.u_eu.u_rf.d_reg[7],
                        u_top.u_eu.u_rf.a_reg[0], u_top.u_eu.u_rf.a_reg[1],
                        u_top.u_eu.u_rf.a_reg[2], u_top.u_eu.u_rf.a_reg[3],
                        u_top.u_eu.u_rf.a_reg[4], u_top.u_eu.u_rf.a_reg[5],
                        u_top.u_eu.u_rf.a_reg[6], u_top.u_eu.u_rf.a7_current,
                        sr_before_stop,            u_top.u_eu.u_rf.pc_r);

                    if (!stop_seen)
                        $display("TIMEOUT");
                    else if (any_addr_err)
                        $display("ADDRERR");
                    else
                        $display("OK");

                    $display("ENDTEST");

                    idx = idx + 1;
                end
            end
        end

        $fclose(mfd);
        $finish;
    end

endmodule

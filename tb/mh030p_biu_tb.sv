`default_nettype none
`timescale 1ps/1ps

// =============================================================================
// MH030-P on the REAL BIU: the first testbench that drives rtlp through genuine
// 68030 pins -- AS/DS, SIZ, FC, DSACK, burst, and both real caches under CACR.
//
// Usage: vvp sim/mh030p_biu +hexfile=tests/bench2.hex [+expected_d0=HEX]
//                           [+cycles=N] [+buslog]
//
// WHY A NEW FILE rather than extending tb/cosim_p_tb.sv: that testbench models
// an abstract bus that acks in one tick. This one is a pin-level peripheral --
// it watches AS/DS, answers with DSACK, and tracks burst beats. The memory model
// is taken from tb/cosim_grp_tb.sv deliberately, not reinvented, so that a tick
// count measured here is comparable with the reference core's: the same model,
// the same wait-state behaviour, the same burst handling. Any difference in the
// numbers is then the CPU, which is the whole point.
//
// EXECCYCLES is the core's own execution-stop point (stopped_r), matching what
// tb/cosim_p_tb.sv and tb/cosim_grp_tb.sv report, so the three are comparable.
// A fetch-based event would not be: the two cores prefetch to different depths.
// =============================================================================

module mh030p_biu_tb;

    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    wire [31:0] ext_a;
    wire [31:0] ext_d_out;
    wire        ext_d_oe;
    wire        ext_as_n, ext_ds_n, ext_rw;
    wire [2:0]  ext_fc;
    wire [1:0]  ext_siz;
    wire        ext_ecs_n, ext_ocs_n, ext_rstout_n, ext_cbreq_n;
    wire        ext_bg_n, ext_rmc_n, ext_dben_n, ciout_n;
    wire        bus_halted, status_n;

    logic        sterm_n  = 1'b1;
    logic        berr_n   = 1'b1;
    logic        halt_n   = 1'b1;
    logic        avec_n   = 1'b1;
    logic [2:0]  ipl_n    = 3'b111;
    logic        br_n     = 1'b1;
    logic        bgack_n  = 1'b1;
    // Held asserted for the WHOLE burst, as a real peripheral would. Pulsing it
    // only on beat 0 is the bug Phase 280 found in the Figure 7-38 diagram's own
    // testbench, and it only ever "worked" via a sticky-latch bug that has since
    // been fixed -- so mirroring CBREQ here would now genuinely abort the burst.
    logic        cback_n  = 1'b0;
    logic        ciin_n   = 1'b1;
    logic        cdis_n   = 1'b1;
    logic        mmudis_n = 1'b1;

    localparam int MEM_WORDS = 4096;
    logic [31:0] rom [0:MEM_WORDS-1];

    string hexfile;
    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        if (!$value$plusargs("hexfile=%s", hexfile))
            hexfile = "tests/smoke.hex";
        $readmemh(hexfile, rom);
    end

    // Burst-beat aware read -- the DUT holds ext_a at the line base through a
    // burst and counts beats internally, so indexing on ext_a alone returns the
    // same word four times. See tb/cosim_grp_tb.sv's own copy of this note.
    wire [1:0]  burst_beat_probe = dut.u_biu.u_cg.u_bc.burst_beat;
    wire [11:0] beat_word_addr   = ext_a[13:2] + {10'h0, burst_beat_probe};
    wire [31:0] rd_word = (beat_word_addr < MEM_WORDS) ? rom[beat_word_addr]
                                                       : 32'hDEAD_DEAD;

    logic ds_active_r;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) ds_active_r <= 1'b0;
        else        ds_active_r <= !ext_ds_n & !ext_as_n;
    end

    // 32-bit port, zero wait states.
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

    wire        stopped;
    wire        wb_wr_en;
    wire [3:0]  wb_wr_sel;
    wire [31:0] wb_wr_data;
    wire [7:0]  ccr_out;

    mh030p_biu_top #(.POWERON_RSTO_CLKS(40)) dut (
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
        .ext_rmc_n    (ext_rmc_n),
        .ext_dben_n   (ext_dben_n),
        .ciout_n      (ciout_n),
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
        .bus_halted   (bus_halted),
        .status_n     (status_n),
        .wb_wr_en     (wb_wr_en),
        .wb_wr_sel    (wb_wr_sel),
        .wb_wr_data   (wb_wr_data),
        .stopped      (stopped),
        .ccr_out      (ccr_out)
    );

    // ── Bus transaction logging, in buscmp.py's format ──────────────────────
    // Off unless +buslog is given: the throughput measurement does not need it
    // and a 9,000-tick run produces a lot of lines.
    logic buslog;
    initial buslog = $test$plusargs("buslog");

    logic ds_prev_r;
    integer n_bus, n_fetch, n_data;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ds_prev_r <= 1'b1;
            n_bus   <= 0;
            n_fetch <= 0;
            n_data  <= 0;
        end else begin
            // One transaction per DS falling edge. A burst asserts DS once per
            // beat with AS held, so each beat counts -- which is what a
            // transaction count should mean here.
            if (ds_prev_r && !ext_ds_n) begin
                n_bus <= n_bus + 1;
                // Program space is FC 010/110; data space 001/101.
                if (ext_fc[1]) n_fetch <= n_fetch + 1;
                else           n_data  <= n_data  + 1;
                if (buslog) begin
                    if (ext_rw)
                        $display("BUS R %08h %08h fc=%b siz=%b",
                                 ext_a, rd_word, ext_fc, ext_siz);
                    else
                        $display("BUS W %08h %08h fc=%b siz=%b",
                                 ext_a, ext_d_out, ext_fc, ext_siz);
                end
            end
            ds_prev_r <= ext_ds_n;
        end
    end

    // ── Instruction retire trace (+extrace) ────────────────────────────────
    // Prints the PC and class of every instruction that commits, plus any
    // architectural register write. Added because the first real-BIU run got a
    // wrong ANSWER rather than a hang, and a bus log alone cannot distinguish
    // "the core executed the wrong instructions" from "the bus returned the
    // wrong data" -- this shows which.
    logic extrace;
    initial extrace = $test$plusargs("extrace");

    always_ff @(posedge clk_4x) begin
        if (extrace && rst_n && dut.u_cpu.u_core.ex_valid
                             && !dut.u_cpu.u_core.stall_ex)
            $display("EX  t=%0t pc=%08h cls=%0d wr=%b sel=%0d data=%08h",
                     $time, dut.u_cpu.u_core.ex_pc,
                     dut.u_cpu.u_core.ex_uop.uclass,
                     wb_wr_en, wb_wr_sel, wb_wr_data);
    end

    // ── Core-port data trace (+datatrace) ──────────────────────────────────
    // Every completed data transaction as the CORE sees it. This is what
    // isolated the burst-ownership bug below: the bus log said address 0x1000
    // returned 0, this said the core received instruction words for it, and the
    // two together placed the fault inside the BIU rather than at either end.
    always_ff @(posedge clk_4x) begin
        if ($test$plusargs("datatrace") && rst_n && dut.mem_ack)
            $display("DAT t=%0t rw=%b addr=%08h rdata=%08h wdata=%08h siz=%b",
                     $time, dut.mem_rw, dut.mem_addr, dut.mem_rdata,
                     dut.mem_wdata, dut.mem_siz);
    end

    // ── Cycle accounting ───────────────────────────────────────────────────
    integer cyc, exec_cyc;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            cyc      <= 0;
            exec_cyc <= 0;
        end else begin
            cyc <= cyc + 1;
            if (dut.u_cpu.u_core.stopped_r && (exec_cyc == 0)) exec_cyc <= cyc;
        end
    end

    integer fails = 0;
    task automatic check(input string name, input bit ok);
        begin
            if (ok) $display("PASS  %s", name);
            else begin
                $display("FAIL  %s", name);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        longint unsigned exp_d0;
        bit check_d0;
        integer cycles;

        rst_n = 1'b0;
        repeat (20) @(posedge clk_4x);
        #1 rst_n = 1'b1;

        if (!$value$plusargs("cycles=%d", cycles)) cycles = 40000;
        check_d0 = $value$plusargs("expected_d0=%h", exp_d0);

        fork
            begin : blk_timeout
                repeat (cycles) @(posedge clk_4x);
                disable blk_stop;
            end
            begin : blk_stop
                wait (stopped == 1'b1);
                repeat (20) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        $display("EXECCYCLES %0d", exec_cyc);
        $display("BUSTXN total=%0d fetch=%0d data=%0d", n_bus, n_fetch, n_data);
        $display("CACR %08h", dut.cacr);
        check("STOP reached", stopped);
        if (check_d0) begin
            check("D0 correct", dut.u_cpu.u_core.u_rf.regs[0] == exp_d0[31:0]);
            if (dut.u_cpu.u_core.u_rf.regs[0] !== exp_d0[31:0])
                $display("  D0=%08h want=%08h D1=%08h D3=%08h D7=%08h A1=%08h A2=%08h A3=%08h",
                         dut.u_cpu.u_core.u_rf.regs[0], exp_d0[31:0],
                         dut.u_cpu.u_core.u_rf.regs[1],
                         dut.u_cpu.u_core.u_rf.regs[3],
                         dut.u_cpu.u_core.u_rf.regs[7],
                         dut.u_cpu.u_core.u_rf.regs[9],
                         dut.u_cpu.u_core.u_rf.regs[10],
                         dut.u_cpu.u_core.u_rf.regs[11]);
        end

        $display("");
        if (fails == 0) $display("=== 0 failure(s) ===\nALL TESTS PASSED");
        else            $display("=== %0d failure(s) ===", fails);
        $finish;
    end

endmodule

`default_nettype wire

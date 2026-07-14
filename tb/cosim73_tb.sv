`default_nettype none
`timescale 1ps/1ps

// Phase 73: Bare-metal toolchain verification testbench
//
// Loads tests/smoke.hex (assembled from tests/smoke.s via vasmm68k_mot + bin2hex.py).
// smoke.s: NOP → MOVEQ #42,D0 → ADD.L D0,D0 → STOP #$2700
//   0x0008: 0x4E71 (NOP)
//   0x000A: 0x702A (MOVEQ #42,D0)
//   0x000C: 0xD080 (ADD.L D0,D0)  ← requires second bus fetch at 0x000C
//   0x000E: 0x4E72 (STOP opcode)   stop_seen fires on second fetch (rd_word=0xD0804E72)
//   0x0010: 0x2700 (STOP immediate)
//
// P73-01: STOP opcode fetched within 3000 cycles (toolchain produced valid code).
// P73-02: D0 = 84 after NOP+MOVEQ+ADD.L sequence executes correctly.
// P73-03: No address errors.

module cosim73_tb;

    // ── Clock & reset ────────────────────────────────────────────────────────
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;

    logic rst_n = 0;

    // ── External pin buses ───────────────────────────────────────────────────
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

    // ── Inline memory model (32-bit port, 0 wait states, 4KB) ────────────────
    localparam int MEM_WORDS = 1024;
    logic [31:0] rom [0:MEM_WORDS-1];

    initial begin : rom_init
        integer i;
        for (i = 0; i < MEM_WORDS; i++) rom[i] = 32'h4E714E71;
        $readmemh("tests/smoke.hex", rom);
    end

    wire [31:0] rd_word = (ext_a[11:2] < MEM_WORDS) ? rom[ext_a[11:2]] : 32'hDEAD_DEAD;

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
            if (ext_a[11:2] < MEM_WORDS) begin
                case ({ext_siz, ext_a[1:0]})
                    4'b00_00: rom[ext_a[11:2]]        <= ext_d_out;
                    4'b10_00: rom[ext_a[11:2]][31:16] <= ext_d_out[31:16];
                    4'b10_10: rom[ext_a[11:2]][15:0]  <= ext_d_out[15:0];
                    4'b01_00: rom[ext_a[11:2]][31:24] <= ext_d_out[31:24];
                    4'b01_01: rom[ext_a[11:2]][23:16] <= ext_d_out[23:16];
                    4'b01_10: rom[ext_a[11:2]][15:8]  <= ext_d_out[15:8];
                    4'b01_11: rom[ext_a[11:2]][7:0]   <= ext_d_out[7:0];
                    default:  rom[ext_a[11:2]]        <= ext_d_out;
                endcase
            end
        end
    end

    // ── DUT ─────────────────────────────────────────────────────────────────
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

    // ── Bus logger ───────────────────────────────────────────────────────────
    logic        as_prev_r;
    logic [31:0] log_addr_r;
    logic [2:0]  log_fc_r;
    logic [1:0]  log_siz_r;
    logic        log_rw_r;
    logic [31:0] log_data_r;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            as_prev_r  <= 1'b1;
            log_addr_r <= 32'h0;
            log_fc_r   <= 3'b0;
            log_siz_r  <= 2'b0;
            log_rw_r   <= 1'b1;
            log_data_r <= 32'h0;
        end else begin
            as_prev_r <= ext_as_n;
            if (!ext_as_n) begin
                log_addr_r <= ext_a;
                log_fc_r   <= ext_fc;
                log_siz_r  <= ext_siz;
                log_rw_r   <= ext_rw;
                log_data_r <= ext_rw ? rd_word : (ext_d_oe ? ext_d_out : 32'h0);
            end
        end
    end

    always_ff @(posedge clk_4x) begin
        if (!as_prev_r && ext_as_n) begin
            if (log_rw_r)
                $display("BUS R %h %h fc=%b siz=%b",
                         log_addr_r, log_data_r, log_fc_r, log_siz_r);
            else
                $display("BUS W %h %h fc=%b siz=%b",
                         log_addr_r, log_data_r, log_fc_r, log_siz_r);
        end
    end

    // ── STOP detection ───────────────────────────────────────────────────────
    logic stop_seen = 1'b0;

    always_ff @(posedge clk_4x) begin
        if (!ext_as_n && !ext_ds_n && ext_rw &&
            (ext_fc == 3'b110 || ext_fc == 3'b010)) begin
            if (rd_word[31:16] == 16'h4E72 || rd_word[15:0] == 16'h4E72)
                stop_seen <= 1'b1;
        end
    end

    // ── Address error tracking ────────────────────────────────────────────────
    logic any_addr_err = 1'b0;
    always_ff @(posedge clk_4x) begin
        if (eu_addr_err || ifu_addr_err) any_addr_err <= 1'b1;
    end

    // ── Test ─────────────────────────────────────────────────────────────────
    int fail_count = 0;

    task automatic check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin $display("FAIL  %s", name); fail_count++; end
    endtask

    initial begin
        rst_n = 0;
        repeat(20) @(posedge clk_4x);
        #1; rst_n = 1;

        // Wait until STOP fetched or timeout
        fork
            begin : blk_timeout
                repeat(3000) @(posedge clk_4x);
            end
            begin : blk_stop
                wait(stop_seen == 1'b1);
                // 500 cycles: enough for EU to drain NOP+MOVEQ+ADD.L+STOP
                repeat(500) @(posedge clk_4x);
                disable blk_timeout;
            end
        join

        check("P73-01 STOP opcode fetched",        stop_seen);
        check("P73-02 D0 = 84 after NOP+MOVEQ+ADD",  u_top.u_eu.u_rf.d_reg[0] == 32'd84);
        check("P73-03 No address errors",           ~any_addr_err);

        if (fail_count == 0) $display("PASS  cosim73");
        else                 $display("FAIL  cosim73 (%0d)", fail_count);
        $finish;
    end

endmodule

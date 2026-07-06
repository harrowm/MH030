`default_nettype none
`timescale 1ns/1ps

// Phase 47 testbench: TAS.B Dn (register direct) and TAS.B (An) (memory RMW)
//
// Instruction encodings:
//   TAS.B Dn:   4'h4_f_dn=101_f_dir=0_f_ss=11_f_mode=000_f_reg=n
//             = {4'h4, 3'b101, 1'b0, 2'b11, 3'b000, 3'b<n>}
//             = 16'h4AC0 | n
//   TAS.B (An): same but f_mode=010 → 16'h4AD0 | n

module seq47_tb;

    localparam CLK_HALF = 5;  // 100 MHz

    logic clk_4x, rst_n;
    initial clk_4x = 0;
    always #CLK_HALF clk_4x = ~clk_4x;

    // ── DUT wires ────────────────────────────────────────────────────────────
    logic [15:0] instr_word;
    logic        instr_valid, instr_ack;
    logic [31:0] ext_data;
    logic        ext_valid;
    logic        eu_busy;
    logic        branch_taken;
    logic [31:0] branch_target;
    logic [31:0] decode_pc;

    logic        mem_req, mem_rw, mem_rmw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;
    logic        div_trap;

    // Phase 46 ports (unused here)
    logic        pc_wr_en;
    logic [31:0] pc_wr_data, pc_out;
    logic        vbr_wr_en;
    logic [31:0] vbr_wr_data, vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        ssp_wr_en;
    logic [31:0] ssp_wr_data;
    logic        exc_sr_wr_en;
    logic [15:0] exc_sr_wr_data;

    assign pc_wr_en       = 1'b0;
    assign pc_wr_data     = 32'h0;
    assign vbr_wr_en      = 1'b0;
    assign vbr_wr_data    = 32'h0;
    assign ssp_wr_en      = 1'b0;
    assign ssp_wr_data    = 32'h0;
    assign exc_sr_wr_en   = 1'b0;
    assign exc_sr_wr_data = 16'h0;
    assign decode_pc      = 32'h0;
    assign mem_berr       = 1'b0;

    m68030_eu u_eu (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .instr_word   (instr_word),
        .instr_valid  (instr_valid),
        .ext_data     (ext_data),
        .ext_valid    (ext_valid),
        .instr_ack    (instr_ack),
        .eu_busy      (eu_busy),
        .pc_wr_en     (pc_wr_en),
        .pc_wr_data   (pc_wr_data),
        .pc_out       (pc_out),
        .vbr_wr_en    (vbr_wr_en),
        .vbr_wr_data  (vbr_wr_data),
        .vbr_out      (vbr_out),
        .usp_out      (usp_out),
        .msp_out      (msp_out),
        .isp_out      (isp_out),
        .cacr_out     (cacr_out),
        .caar_out     (caar_out),
        .sr_out       (sr_out),
        .supervisor   (supervisor),
        .master_mode  (master_mode),
        .ipl_mask     (ipl_mask),
        .decode_pc    (decode_pc),
        .branch_taken (branch_taken),
        .branch_target(branch_target),
        .mem_req      (mem_req),
        .mem_rw       (mem_rw),
        .mem_siz      (mem_siz),
        .mem_fc       (mem_fc),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_rdata    (mem_rdata),
        .mem_ack      (mem_ack),
        .mem_berr     (mem_berr),
        .mem_rmw      (mem_rmw),
        .an_wr_en     (an_wr_en),
        .an_wr_sel    (an_wr_sel),
        .an_wr_data   (an_wr_data),
        .div_trap     (div_trap),
        .ssp_wr_en    (ssp_wr_en),
        .ssp_wr_data  (ssp_wr_data),
        .exc_sr_wr_en (exc_sr_wr_en),
        .exc_sr_wr_data(exc_sr_wr_data)
    );

    // ── Instant-ack memory model ──────────────────────────────────────────────
    // For TAS (An): mem_rdata provides the byte in [7:0].
    // For writes: we capture mem_wdata[7:0].
    logic [31:0] mem_store [0:63];  // 64 word array (addresses 0x000..0xFC)
    integer mi;
    initial for (mi = 0; mi < 64; mi++) mem_store[mi] = 32'h0;

    assign mem_rdata = mem_req && mem_rw ? mem_store[mem_addr[7:2]] : 32'h0;
    assign mem_ack   = mem_req;  // zero-wait-state

    // Capture writes
    logic [31:0] last_mem_waddr;
    logic [31:0] last_mem_wdata;
    always @(posedge clk_4x) begin
        if (mem_req && !mem_rw) begin
            last_mem_waddr <= mem_addr;
            last_mem_wdata <= mem_wdata;
            mem_store[mem_addr[7:2]] <= mem_wdata;
        end
    end

    // ── Helpers ───────────────────────────────────────────────────────────────
    integer pass_count, fail_count;

    task check;
        input [63:0] got;
        input [63:0] exp;
        input [127:0] label;
        begin
            if (got === exp)
                pass_count = pass_count + 1;
            else begin
                $display("FAIL  %s: got %08h  exp %08h", label, got[31:0], exp[31:0]);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Load a value into Dn by issuing MOVEQ #imm, Dn (only works for -128..127)
    // For larger values, use CLR.L Dn then ADDI.L #val, Dn
    task set_dn_byte;
        input [2:0] n;      // D0..D7
        input [7:0] byte_val;
        begin
            // CLR.L Dn: 0100 001 010 000 nnn
            instr_word  = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, n};
            instr_valid = 1'b1;
            ext_valid   = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
            // MOVEQ #byte, Dn (only low 8 bits, sign-extended)
            instr_word  = {4'h7, n, 1'b0, byte_val};
            instr_valid = 1'b1;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Load a 32-bit value into Dn (via CLR + ADDI.L #val,Dn)
    task set_dn;
        input [2:0] n;
        input [31:0] val;
        begin
            // CLR.L Dn
            instr_word  = {4'h4, 3'b001, 1'b0, 2'b10, 3'b000, n};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
            // ADDI.L #val, Dn: 0000 0110 10 000 nnn | val[31:0]
            instr_word  = {4'h0, 3'b011, 1'b0, 2'b10, 3'b000, n};
            instr_valid = 1'b1;
            ext_data    = val;
            ext_valid   = 1'b1;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0; ext_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Load address into An: uses MOVEA.L #abs, An via absolute EA (Phase 40)
    // Actually easier: use set_dn(D0, addr) then MOVEA.L D0, An
    task set_an;
        input [2:0] n;
        input [31:0] val;
        begin
            // Load val into D0 first
            set_dn(3'd0, val);
            // MOVEA.L D0, An: 0010 nnn 001 000 000 (group 2, dst_mode=001=MOVEA.L, src=D0)
            instr_word  = {4'h2, n, 3'b001, 3'b000, 3'b000};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Issue TAS.B Dn and wait for completion
    task run_tas_dn;
        input [2:0] n;
        begin
            instr_word  = {4'h4, 3'b101, 1'b0, 2'b11, 3'b000, n};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            @(posedge clk_4x); #1; @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // Issue TAS.B (An) and wait for completion (read + write RMW)
    task run_tas_an;
        input [2:0] n;
        begin
            instr_word  = {4'h4, 3'b101, 1'b0, 2'b11, 3'b010, n};
            instr_valid = 1'b1; ext_valid = 1'b0;
            @(posedge clk_4x); #1;
            instr_valid = 1'b0;
            // Wait for stall to clear (TAS memory takes 2 bus cycles + stall cycles)
            @(posedge clk_4x); #1;
            while (eu_busy) begin
                @(posedge clk_4x); #1;
            end
            @(posedge clk_4x); #1; @(posedge clk_4x); #1;
        end
    endtask

    // ── SR CCR helpers ────────────────────────────────────────────────────────
    // CCR in sr_out[4:0] = {X, N, Z, V, C}
    `define SR_N (sr_out[3])
    `define SR_Z (sr_out[2])
    `define SR_V (sr_out[1])
    `define SR_C (sr_out[0])

    // ── Test body ─────────────────────────────────────────────────────────────
    initial begin
        pass_count = 0;
        fail_count = 0;
        instr_word  = 16'h4E71; // NOP (idle)
        instr_valid = 1'b0;
        ext_data    = 32'h0;
        ext_valid   = 1'b0;

        // Reset
        rst_n = 1'b0;
        repeat(4) @(posedge clk_4x);
        rst_n = 1'b1;
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // TAS-1: TAS.B D0, D0 = 0x00000000
        //   Original byte = 0x00 → Z=1, N=0; result = 0x80
        // ----------------------------------------------------------------
        set_dn(3'd0, 32'h00000000);
        run_tas_dn(3'd0);
        check(u_eu.u_rf.d_reg[0], 32'h00000080, "TAS-1a D0");
        check(`SR_Z, 1'b1, "TAS-1b Z");
        check(`SR_N, 1'b0, "TAS-1c N");
        check(`SR_V, 1'b0, "TAS-1d V");
        check(`SR_C, 1'b0, "TAS-1e C");

        // ----------------------------------------------------------------
        // TAS-2: TAS.B D1, D1 = 0x41424344 (byte = 0x44 = 01000100)
        //   Original byte = 0x44 → Z=0, N=0 (bit7=0); result = 0xC4, rest unchanged
        // ----------------------------------------------------------------
        set_dn(3'd1, 32'h41424344);
        run_tas_dn(3'd1);
        check(u_eu.u_rf.d_reg[1], 32'h414243C4, "TAS-2a D1");
        check(`SR_Z, 1'b0, "TAS-2b Z");
        check(`SR_N, 1'b0, "TAS-2c N");

        // ----------------------------------------------------------------
        // TAS-3: TAS.B D2, D2 = 0xABCDEF80 (byte = 0x80 = 10000000)
        //   Original byte = 0x80 → Z=0, N=1 (bit7=1); result = 0x80 (no change)
        // ----------------------------------------------------------------
        set_dn(3'd2, 32'hABCDEF80);
        run_tas_dn(3'd2);
        check(u_eu.u_rf.d_reg[2], 32'hABCDEF80, "TAS-3a D2");
        check(`SR_Z, 1'b0, "TAS-3b Z");
        check(`SR_N, 1'b1, "TAS-3c N");

        // ----------------------------------------------------------------
        // TAS-4: TAS.B D3, D3 = 0x12345600 (byte = 0x00)
        //   Z=1, N=0; result byte = 0x80
        // ----------------------------------------------------------------
        set_dn(3'd3, 32'h12345600);
        run_tas_dn(3'd3);
        check(u_eu.u_rf.d_reg[3], 32'h12345680, "TAS-4a D3");
        check(`SR_Z, 1'b1, "TAS-4b Z");
        check(`SR_N, 1'b0, "TAS-4c N");

        // ----------------------------------------------------------------
        // TAS-5: TAS.B (A0), memory byte at A0 = 0x00
        //   A0 points to mem_store[0] (address 0x0).
        //   Read byte 0x00: Z=1, N=0; write 0x80 back.
        // ----------------------------------------------------------------
        mem_store[0] = 32'h00000000;
        set_an(3'd0, 32'h00000000);  // A0 = 0x00
        run_tas_an(3'd0);
        // CCR from read value
        check(`SR_Z, 1'b1, "TAS-5a Z");
        check(`SR_N, 1'b0, "TAS-5b N");
        check(`SR_V, 1'b0, "TAS-5c V");
        check(`SR_C, 1'b0, "TAS-5d C");
        // Write: mem_wdata[7:0] should be 0x80
        check(last_mem_wdata[7:0], 8'h80, "TAS-5e wdata");
        check(last_mem_waddr, 32'h0, "TAS-5f waddr");

        // ----------------------------------------------------------------
        // TAS-6: TAS.B (A0), memory byte at A0 = 0x42 (01000010)
        //   Z=0, N=0; write 0xC2 back.
        // ----------------------------------------------------------------
        mem_store[4] = 32'h00000042;  // address 0x10
        set_an(3'd0, 32'h00000010);
        run_tas_an(3'd0);
        check(`SR_Z, 1'b0, "TAS-6a Z");
        check(`SR_N, 1'b0, "TAS-6b N");
        check(last_mem_wdata[7:0], 8'hC2, "TAS-6c wdata");

        // ----------------------------------------------------------------
        // TAS-7: TAS.B (A0), memory byte at A0 = 0x80 (10000000)
        //   Z=0, N=1; write 0x80 (no change).
        // ----------------------------------------------------------------
        mem_store[8] = 32'h00000080;  // address 0x20
        set_an(3'd0, 32'h00000020);
        run_tas_an(3'd0);
        check(`SR_Z, 1'b0, "TAS-7a Z");
        check(`SR_N, 1'b1, "TAS-7b N");
        check(last_mem_wdata[7:0], 8'h80, "TAS-7c wdata");

        // ----------------------------------------------------------------
        // TAS-8: TAS.B (A1), verify A1 unchanged after TAS
        //   (An) mode should not modify An)
        // ----------------------------------------------------------------
        mem_store[12] = 32'h00000055;  // address 0x30
        set_an(3'd1, 32'h00000030);
        run_tas_an(3'd1);
        check(u_eu.u_rf.a_reg[1], 32'h00000030, "TAS-8a A1 unchanged");
        check(last_mem_wdata[7:0], 8'hD5, "TAS-8b wdata 0x55|0x80");

        // Done
        $display("");
        $display("%0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

endmodule
`default_nettype wire

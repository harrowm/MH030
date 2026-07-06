`default_nettype none
`timescale 1ps/1ps

// Phase 50 testbench — MOVE16 16-byte block move
//
// 68040-compatible MOVE16 encoding (Group F, f_dn=001, f_dir=0, f_ss=00):
//   f_mode=001: MOVE16 (An)+,(Am)+  — both postincrement; Am in ext[14:12]
//   f_mode=010: MOVE16 (An)+,(xxx).L — src An postinc, dst = 32-bit abs in ext
//   f_mode=011: MOVE16 (xxx).L,(An)+ — src = 32-bit abs in ext, dst An postinc
//   f_mode=000: MOVE16 (An),(An)     — both indirect, no postincrement; Am in ext[14:12]
//
// Opcode word: 1111 001 0 00 fmod nnn
//   [15:12]=1111, [11:9]=001, [8]=0, [7:6]=00, [5:3]=f_mode, [2:0]=nnn
//   With nnn=000 (A0): base = 0xF208|f_mode<<3
//
// Examples:
//   MOVE16 (A0)+,(A1)+: f_mode=001, nnn=000 = 0xF208; ext_data[15:0]=0x9000 (Am=A1 at [14:12])
//   MOVE16 (A0)+,(xxx).L: f_mode=010, nnn=000 = 0xF210; ext_data = 32-bit absolute dst
//   MOVE16 (xxx).L,(A0)+: f_mode=011, nnn=000 = 0xF218; ext_data = 32-bit absolute src
//   MOVE16 (A0),(A1):     f_mode=000, nnn=000 = 0xF200; ext_data[15:0]=0x9000 (Am=A1 at [14:12])

`define DR(n)   u_dut.u_rf.d_reg[n]
`define AR(n)   u_dut.u_rf.a_reg[n]

module seq50_tb;

    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;
    logic        instr_ack, eu_busy;
    logic [31:0] decode_pc   = 0;

    logic [31:0] pc_out, vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap, chk_trap;
    logic        branch_taken;
    logic [31:0] branch_target;

    // 32-bit word-addressable RAM; addr[31:2] indexes longwords
    logic [31:0] ram [0:511];

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    assign mem_ack   = mem_req;
    assign mem_berr  = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[10:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[10:2]] <= mem_wdata;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;
    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 0;

    m68030_eu u_dut (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .instr_word    (instr_word),
        .instr_valid   (instr_valid),
        .ext_data      (ext_data),
        .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),
        .eu_busy       (eu_busy),
        .pc_wr_en      (1'b0),
        .pc_wr_data    (32'h0),
        .pc_out        (pc_out),
        .vbr_wr_en     (1'b0),
        .vbr_wr_data   (32'h0),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),
        .msp_out       (msp_out),
        .isp_out       (isp_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .chk_trap      (chk_trap),
        .decode_pc     (decode_pc),
        .branch_taken  (branch_taken),
        .branch_target (branch_target),
        .mem_req       (mem_req),
        .mem_rw        (mem_rw),
        .mem_siz       (mem_siz),
        .mem_fc        (mem_fc),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_rdata     (mem_rdata),
        .mem_ack       (mem_ack),
        .mem_berr      (mem_berr),
        .an_wr_en      (an_wr_en),
        .an_wr_sel     (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .ssp_wr_en     (ssp_wr_en),
        .ssp_wr_data   (ssp_wr_data),
        .exc_sr_wr_en  (1'b0),
        .exc_sr_wr_data(16'h0)
    );

    int fail_count = 0;

    task check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin
            $display("FAIL  %s: got %08h  exp %08h", name, got, exp);
            fail_count++;
        end
    endtask

    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    task set_d0(input logic [31:0] val);
        run(16'h4280, 32'h0, 1'b0);
        run(16'h0680, val, 1'b1);
    endtask

    task set_an(input logic [2:0] an, input logic [31:0] val);
        set_d0(val);
        run({4'h2, an, 3'b001, 3'b000, 3'b000}, 32'h0, 1'b0);
    endtask

    // Run a MOVE16 instruction.
    // n_beats = 8 (4 reads + 4 writes) always.
    task run_move16(input logic [15:0] op, input logic [31:0] imm,
                    input int extra_cycles);
        @(posedge clk_4x); #1;
        instr_word  = op;
        ext_data    = imm;
        instr_valid = 1;
        ext_valid   = 1;
        @(posedge clk_4x); #1;
        instr_valid = 0;
        ext_valid   = 0;
        // start_r=1 + run_r phase0 (4 reads) + run_r phase1 (4 writes) + pipeline drain
        repeat (1 + 8 + extra_cycles) @(posedge clk_4x);
        #1;
    endtask

    // Load 16 bytes (4 longwords) into RAM starting at byte address base_addr
    task load_block(input logic [31:0] base_addr,
                    input logic [31:0] w0, w1, w2, w3);
        ram[base_addr[10:2] + 0] = w0;
        ram[base_addr[10:2] + 1] = w1;
        ram[base_addr[10:2] + 2] = w2;
        ram[base_addr[10:2] + 3] = w3;
    endtask

    // Read 4 longwords from RAM starting at byte address base_addr
    function automatic logic [31:0] rd_lw(input logic [31:0] base_addr, input int idx);
        return ram[base_addr[10:2] + idx];
    endfunction

    initial begin
        @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        // Clear all RAM
        for (int i = 0; i < 512; i++) ram[i] = 32'h0;

        // ─── Test 1: MOVE16 (A0)+,(xxx).L ─────────────────────────────────────
        // src = A0 = 0x100 (block: 4 known longwords)
        // dst = absolute 0x200
        // After: ram[0x200..0x20F] = same data; A0 += 16 = 0x110
        //
        // Opcode: f_mode=010, nnn=000 = 0xF210
        // ext_data = 32-bit absolute dst = 0x200
        load_block(32'h100, 32'hAABBCCDD, 32'h11223344, 32'hDEADBEEF, 32'hCAFEBABE);
        set_an(3'd0, 32'h0000_0100);  // A0 = 0x100

        run_move16(16'hF210, 32'h0000_0200, 8);  // MOVE16 (A0)+,(0x200).L

        check("M16 An+/abs: dst[0]",   rd_lw(32'h200, 0), 32'hAABBCCDD);
        check("M16 An+/abs: dst[1]",   rd_lw(32'h200, 1), 32'h11223344);
        check("M16 An+/abs: dst[2]",   rd_lw(32'h200, 2), 32'hDEADBEEF);
        check("M16 An+/abs: dst[3]",   rd_lw(32'h200, 3), 32'hCAFEBABE);
        check("M16 An+/abs: A0+=16",   `AR(0),             32'h0000_0110);

        // ─── Test 2: MOVE16 (xxx).L,(A0)+ ─────────────────────────────────────
        // src = absolute 0x300 (block: different data)
        // dst = A0 = 0x400; A0 += 16 → 0x410
        //
        // Opcode: f_mode=011, nnn=000 = 0xF218
        // ext_data = 32-bit absolute src = 0x300
        load_block(32'h300, 32'h12345678, 32'h9ABCDEF0, 32'hFEDCBA98, 32'h87654321);
        set_an(3'd0, 32'h0000_0400);  // A0 = 0x400

        run_move16(16'hF218, 32'h0000_0300, 8);  // MOVE16 (0x300).L,(A0)+

        check("M16 abs/An+: dst[0]",   rd_lw(32'h400, 0), 32'h12345678);
        check("M16 abs/An+: dst[1]",   rd_lw(32'h400, 1), 32'h9ABCDEF0);
        check("M16 abs/An+: dst[2]",   rd_lw(32'h400, 2), 32'hFEDCBA98);
        check("M16 abs/An+: dst[3]",   rd_lw(32'h400, 3), 32'h87654321);
        check("M16 abs/An+: A0+=16",   `AR(0),             32'h0000_0410);

        // ─── Test 3: MOVE16 (A0)+,(A1)+ ─────────────────────────────────────
        // src = A0 = 0x500; dst = A1 = 0x600; both += 16
        //
        // Opcode: f_mode=001, nnn=000 = 0xF208
        // ext word: 1aaa 0000 0000 0000 where aaa=A1=001 → 0x9000
        load_block(32'h500, 32'hAAAA0000, 32'hBBBB1111, 32'hCCCC2222, 32'hDDDD3333);
        set_an(3'd0, 32'h0000_0500);  // A0 = 0x500 (src)
        set_an(3'd1, 32'h0000_0600);  // A1 = 0x600 (dst)

        run_move16(16'hF208, 32'h0000_9000, 8);  // MOVE16 (A0)+,(A1)+; ext word 0x9000 in [15:0]

        check("M16 An+/Am+: dst[0]",   rd_lw(32'h600, 0), 32'hAAAA0000);
        check("M16 An+/Am+: dst[1]",   rd_lw(32'h600, 1), 32'hBBBB1111);
        check("M16 An+/Am+: dst[2]",   rd_lw(32'h600, 2), 32'hCCCC2222);
        check("M16 An+/Am+: dst[3]",   rd_lw(32'h600, 3), 32'hDDDD3333);
        check("M16 An+/Am+: A0+=16",   `AR(0),             32'h0000_0510);
        check("M16 An+/Am+: A1+=16",   `AR(1),             32'h0000_0610);

        // ─── Test 4: MOVE16 (A0),(A1) — no postincrement ─────────────────────
        // src = A0 = 0x700; dst = A1 = 0x780; registers unchanged
        //
        // Opcode: f_mode=000, nnn=000 = 0xF200
        // ext word: 1001 0000 0000 0000 = 0x9000 (A1=001)
        load_block(32'h700, 32'h11112222, 32'h33334444, 32'h55556666, 32'h77778888);
        set_an(3'd0, 32'h0000_0700);  // A0 = 0x700 (src)
        set_an(3'd1, 32'h0000_0780);  // A1 = 0x780 (dst)

        run_move16(16'hF200, 32'h0000_9000, 8);  // MOVE16 (A0),(A1); ext word 0x9000 in [15:0]

        check("M16 An/Am: dst[0]",     rd_lw(32'h780, 0), 32'h11112222);
        check("M16 An/Am: dst[1]",     rd_lw(32'h780, 1), 32'h33334444);
        check("M16 An/Am: dst[2]",     rd_lw(32'h780, 2), 32'h55556666);
        check("M16 An/Am: dst[3]",     rd_lw(32'h780, 3), 32'h77778888);
        check("M16 An/Am: A0 unchanged", `AR(0),           32'h0000_0700);
        check("M16 An/Am: A1 unchanged", `AR(1),           32'h0000_0780);

        // ─── Final report ─────────────────────────────────────────────────────
        #100;
        if (fail_count == 0)
            $display("seq50: %0d passed, 0 failed\nPASS", 5 + 5 + 6 + 6);
        else
            $display("seq50: %0d failed\nFAIL", fail_count);
        $finish;
    end

endmodule

`default_nettype none
`timescale 1ps/1ps

// Phase 43 testbench — MOVEM register save/restore
//   Registers are set via instruction sequences (CLR/ADDI/MOVEA — same style as seq38).
//   Verification uses hierarchical reads (constant indices) and RAM contents.

module seq43_tb;

    // ── Clock / reset ──────────────────────────────────────────────────────
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // ── EU interface ───────────────────────────────────────────────────────
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
    logic        div_trap;
    logic        branch_taken;
    logic [31:0] branch_target;

    // ── Memory model (combinational ack, like seq38) ───────────────────────
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    logic [31:0] ram [0:511];   // 2 KB, byte-addressed by [10:2]

    assign mem_ack   = mem_req;
    assign mem_berr  = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[10:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[10:2]] <= mem_wdata;

    // ── An write + ISP backdoor ────────────────────────────────────────────
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 0;

    // ── DUT ───────────────────────────────────────────────────────────────
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

    // ── Helpers ────────────────────────────────────────────────────────────
    int fail_count = 0;

    task chk(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s  (got %08h)", name, got);
        else begin
            $display("FAIL  %s: got %08h  exp %08h", name, got, exp);
            fail_count++;
        end
    endtask

    // Run one instruction (present for 2 cycles to ensure DECODE+EX drain)
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Set D0 to val: CLR.L D0 + ADDI.L #val,D0
    task set_d0(input logic [31:0] val);
        run(16'h4280, 32'h0, 1'b0);   // CLR.L D0
        run(16'h0680, val,  1'b1);    // ADDI.L #val,D0
    endtask

    // Set D1-D7 similarly (CLR.L Dn = 0x4280|n, ADDI.L Dn = 0x0680|n)
    task set_dn(input int n, input logic [31:0] val);
        run(16'h4280 | (16'(n) & 16'h7), 32'h0, 1'b0);
        run(16'h0680 | (16'(n) & 16'h7), val,  1'b1);
    endtask

    // Set An via MOVEA.L D0,An (first load D0, then MOVEA)
    // MOVEA.L D0,An encoding: {4'h2, an, 3'b001, 3'b000, 3'b000}
    task set_an(input logic [2:0] an, input logic [31:0] val);
        set_d0(val);
        run({4'h2, an, 3'b001, 3'b000, 3'b000}, 32'h0, 1'b0);
    endtask

    // Set ISP (A7 in supervisor mode) via backdoor port
    task set_isp(input logic [31:0] val);
        @(posedge clk_4x); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk_4x); #1;
        ssp_wr_en = 0;
        @(posedge clk_4x); #1;
    endtask

    // Run a MOVEM instruction (1 ext word = register mask).
    // Presents instr_valid for exactly ONE posedge (no while-loop; same style as run()).
    // The while-loop approach caused a double-trigger: the loop kept iterating through
    // the MOVEM FSM's stall (instr_ack=0), exited when stall cleared, then waited one
    // more posedge — which fired the FSM again with instr_valid still asserted.
    task run_movem(input logic [15:0] op, input logic [15:0] mask,
                   input int n_regs);
        @(posedge clk_4x); #1;
        instr_word  = op;
        ext_data    = {16'h0, mask};
        instr_valid = 1;
        ext_valid   = 1;
        @(posedge clk_4x); #1;    // FSM fires at THIS posedge; deassert before next
        instr_valid = 0;
        ext_valid   = 0;
        // movem_start_r phase = 1 cycle, movem_run_r = n_regs cycles, plus 6 drain
        repeat (n_regs + 6) @(posedge clk_4x);
        #1;
    endtask

    // ── Main test body ─────────────────────────────────────────────────────
    initial begin
        $display("=== Phase 43: MOVEM ===");

        // Reset
        rst_n = 0;
        for (int i = 0; i < 512; i++) ram[i] = 32'hDEAD_BEEF;
        repeat(4) @(posedge clk_4x); #1;
        rst_n = 1;
        repeat(2) @(posedge clk_4x); #1;

        // =================================================================
        // P43-1: MOVEM.L {D0,D1,D2}, -(A0)  —  predecrement store
        //   opcode 0x48E0: f_dn=100(store), f_ss=11(L), f_mode=100(predec), f_reg=000(A0)
        //   predec mask (reversed): D0=bit15, D1=bit14, D2=bit13 → 0xE000
        //   A0=0x30; FSM writes: D2→0x2C, D1→0x28, D0→0x24; A0_new=0x24
        //   NOTE: set_an must come first — it internally uses set_d0 which clobbers D0.
        // =================================================================
        $display("\n--- P43-1: MOVEM.L {D0,D1,D2}, -(A0) ---");
        set_an(3'b000, 32'h0000_0030);   // A0 = 0x30  (must be before set_dn — clobbers D0)
        set_dn(0, 32'hAAAA_0000);
        set_dn(1, 32'hBBBB_0001);
        set_dn(2, 32'hCCCC_0002);
        run_movem(16'h48E0, 16'hE000, 3);
        // LSB of 0xE000 is bit13 → reg_sel=15-13=2=D2 → addr=0x2C
        // next bit14 → D1 → 0x28; next bit15 → D0 → 0x24; A0_new=0x24
        chk("P43-1 mem[0x24]=D0", ram[9],  32'hAAAA_0000);  // 0x24>>2=9
        chk("P43-1 mem[0x28]=D1", ram[10], 32'hBBBB_0001);  // 0x28>>2=10
        chk("P43-1 mem[0x2C]=D2", ram[11], 32'hCCCC_0002);  // 0x2C>>2=11
        chk("P43-1 A0_new=0x24",  u_dut.u_rf.a_reg[0], 32'h0000_0024);

        // =================================================================
        // P43-2: MOVEM.L (A0)+, {D0,D1,D2}  —  post-increment load
        //   opcode 0x4CD8: f_dn=110(load), f_ss=11(L), f_mode=011(postinc), f_reg=000(A0)
        //   normal mask: D0=bit0, D1=bit1, D2=bit2 → 0x0007
        //   A0=0x40; reads: D0←M[0x40], D1←M[0x44], D2←M[0x48]; A0_new=0x4C
        // =================================================================
        $display("\n--- P43-2: MOVEM.L (A0)+, {D0,D1,D2} ---");
        ram[32'h40>>2] = 32'h1111_1111;
        ram[32'h44>>2] = 32'h2222_2222;
        ram[32'h48>>2] = 32'h3333_3333;
        set_an(3'b000, 32'h0000_0040);   // A0 = 0x40
        run_movem(16'h4CD8, 16'h0007, 3);
        chk("P43-2 D0=0x1111_1111", u_dut.u_rf.d_reg[0], 32'h1111_1111);
        chk("P43-2 D1=0x2222_2222", u_dut.u_rf.d_reg[1], 32'h2222_2222);
        chk("P43-2 D2=0x3333_3333", u_dut.u_rf.d_reg[2], 32'h3333_3333);
        chk("P43-2 A0_new=0x4C",    u_dut.u_rf.a_reg[0], 32'h0000_004C);

        // =================================================================
        // P43-3: MOVEM.L {A1,A2}, -(A3)  —  predec store of A registers
        //   opcode 0x48E3: f_dn=100, f_ss=11, f_mode=100, f_reg=011(A3)
        //   predec mask: A1=bit6, A2=bit5 → 0x0060
        //   A3=0x50; writes: A2→0x4C, A1→0x48; A3_new=0x48
        //   (bit5 LSB → reg_sel=15-5=10 → a_reg[010]=A2; bit6 → reg_sel=9 → A1)
        // =================================================================
        $display("\n--- P43-3: MOVEM.L {A1,A2}, -(A3) ---");
        set_an(3'b001, 32'hA1A1_A1A1);
        set_an(3'b010, 32'hA2A2_A2A2);
        set_an(3'b011, 32'h0000_0050);   // A3 = 0x50
        run_movem(16'h48E3, 16'h0060, 2);
        chk("P43-3 mem[0x48]=A1", ram[32'h48>>2], 32'hA1A1_A1A1);
        chk("P43-3 mem[0x4C]=A2", ram[32'h4C>>2], 32'hA2A2_A2A2);
        chk("P43-3 A3_new=0x48",  u_dut.u_rf.a_reg[3], 32'h0000_0048);

        // =================================================================
        // P43-4: MOVEM.L (A1), {D5}  —  fixed (An) load, single register, no An update
        //   opcode 0x4CD1: f_dn=110, f_ss=11, f_mode=010((An)), f_reg=001(A1)
        //   normal mask: D5=bit5 → 0x0020
        //   A1=0x80; D5←M[0x80]; A1 unchanged
        // =================================================================
        $display("\n--- P43-4: MOVEM.L (A1), {D5} ---");
        ram[32'h80>>2] = 32'h5555_5555;
        set_an(3'b001, 32'h0000_0080);   // A1 = 0x80
        run_movem(16'h4CD1, 16'h0020, 1);
        chk("P43-4 D5=0x5555_5555",       u_dut.u_rf.d_reg[5], 32'h5555_5555);
        chk("P43-4 A1_unchanged=0x80",    u_dut.u_rf.a_reg[1], 32'h0000_0080);

        // =================================================================
        // P43-5: MOVEM.L {D3}, (A2)  —  fixed (An) store, single register, no An update
        //   opcode 0x48D2: f_dn=100, f_ss=11, f_mode=010((An)), f_reg=010(A2)
        //   non-predec mask: D3=bit3 → 0x0008
        //   A2=0xC0; M[0xC0]←D3; A2 unchanged
        // =================================================================
        $display("\n--- P43-5: MOVEM.L {D3}, (A2) ---");
        set_dn(3, 32'hFACE_BEEF);
        set_an(3'b010, 32'h0000_00C0);   // A2 = 0xC0
        run_movem(16'h48D2, 16'h0008, 1);
        chk("P43-5 mem[0xC0]=D3",       ram[32'hC0>>2], 32'hFACE_BEEF);
        chk("P43-5 A2_unchanged=0xC0",  u_dut.u_rf.a_reg[2], 32'h0000_00C0);

        // =================================================================
        // P43-6: MOVEM.W (A0)+, {D4,D5}  —  word load with sign-extension
        //   opcode 0x4C98: f_dn=110, f_ss=10(W), f_mode=011, f_reg=000(A0)
        //   normal mask: D4=bit4, D5=bit5 → 0x0030
        //   A0=0x100; M[0x100]=0x????_8001 → D4=sign_ext(0x8001)=0xFFFF8001
        //              M[0x102]→ same longword word read → verify sign-extension
        //   step=2 so A0_new=0x104
        //   In our simple memory model, both reads (0x100 and 0x102) return the
        //   same longword ram[0x40]. WB picks mem_rdata[15:0] and sign-extends.
        //   For positive word: ram[0x40][15:0]=0x7FFF → D4=0x00007FFF
        //   Since D4 and D5 come from sequential addr increments (both in same lword
        //   in our RAM model), D4=D5=sign_ext(ram[0x40][15:0])=0x00007FFF
        //   Use two separate longword-aligned addresses to get distinct values:
        //   A0=0x100 (even boundary), step=2 → 0x100 and 0x102 both → ram[0x40]
        //   Both reads get mem_rdata=ram[0x40]; both take [15:0]; both sign-extend.
        //   Set ram[0x40]=0x0000_8001; D4=0xFFFF8001, D5=0xFFFF8001 (both from [15:0])
        //   A0_new = 0x100 + 2 + 2 = 0x104
        // =================================================================
        $display("\n--- P43-6: MOVEM.W (A0)+, {D4,D5} ---");
        ram[32'h100>>2] = 32'h0000_8001;   // word at [15:0] = 0x8001 (negative)
        set_an(3'b000, 32'h0000_0100);     // A0 = 0x100
        run_movem(16'h4C98, 16'h0030, 2);
        // Both reads map to ram[0x100>>2] = ram[64]; mem_rdata[15:0]=0x8001
        // sign_ext → 0xFFFF_8001
        chk("P43-6 D4=0xFFFF8001 (sign-ext word)",   u_dut.u_rf.d_reg[4], 32'hFFFF_8001);
        chk("P43-6 D5=0xFFFF8001 (sign-ext word)",   u_dut.u_rf.d_reg[5], 32'hFFFF_8001);
        chk("P43-6 A0_new=0x104 (+2 per reg)",        u_dut.u_rf.a_reg[0], 32'h0000_0104);

        // =================================================================
        // P43-7: MOVEM.L {D4,D5,D6,D7}, -(A7)  —  4-reg predec to ISP
        //   opcode 0x48E7: f_dn=100, f_ss=11, f_mode=100, f_reg=111(A7)
        //   predec mask: D4=bit11, D5=bit10, D6=bit9, D7=bit8 → 0x0F00
        //   ISP=0x200; writes (LSB-first of 0x0F00):
        //     bit8=D7 → addr=0x1FC; bit9=D6 → 0x1F8; bit10=D5 → 0x1F4; bit11=D4 → 0x1F0
        //   ISP_new=0x1F0
        // =================================================================
        $display("\n--- P43-7: MOVEM.L {D4-D7}, -(A7) ---");
        set_dn(4, 32'h0000_0004);
        set_dn(5, 32'h0000_0005);
        set_dn(6, 32'h0000_0006);
        set_dn(7, 32'h0000_0007);
        set_isp(32'h0000_0200);
        run_movem(16'h48E7, 16'h0F00, 4);
        chk("P43-7 mem[0x1F0]=D4", ram[32'h1F0>>2], 32'h0000_0004);
        chk("P43-7 mem[0x1F4]=D5", ram[32'h1F4>>2], 32'h0000_0005);
        chk("P43-7 mem[0x1F8]=D6", ram[32'h1F8>>2], 32'h0000_0006);
        chk("P43-7 mem[0x1FC]=D7", ram[32'h1FC>>2], 32'h0000_0007);
        chk("P43-7 ISP_new=0x1F0", isp_out,         32'h0000_01F0);

        // =================================================================
        // P43-8: MOVEM.L (A7)+, {D4,D5,D6,D7}  —  restore D4-D7 from stack
        //   opcode 0x4CDF: f_dn=110, f_ss=11, f_mode=011, f_reg=111(A7)
        //   normal mask: D4=bit4, D5=bit5, D6=bit6, D7=bit7 → 0x00F0
        //   ISP=0x1F0 (from P43-7); reads: D4←M[0x1F0], D5←M[0x1F4], ...
        //   ISP_new=0x1F0+16=0x200
        // =================================================================
        $display("\n--- P43-8: MOVEM.L (A7)+, {D4-D7} restore ---");
        // Clear D4-D7 first with zeroes so we can tell if loads worked
        set_dn(4, 32'h0);
        set_dn(5, 32'h0);
        set_dn(6, 32'h0);
        set_dn(7, 32'h0);
        // ISP should still be 0x1F0 from P43-7 (or re-set it)
        set_isp(32'h0000_01F0);
        run_movem(16'h4CDF, 16'h00F0, 4);
        chk("P43-8 D4=0x0000_0004", u_dut.u_rf.d_reg[4], 32'h0000_0004);
        chk("P43-8 D5=0x0000_0005", u_dut.u_rf.d_reg[5], 32'h0000_0005);
        chk("P43-8 D6=0x0000_0006", u_dut.u_rf.d_reg[6], 32'h0000_0006);
        chk("P43-8 D7=0x0000_0007", u_dut.u_rf.d_reg[7], 32'h0000_0007);
        chk("P43-8 ISP_new=0x200",  isp_out,              32'h0000_0200);

        // ── Summary ────────────────────────────────────────────────────────
        $display("\n=== P43 result: %0d fail ===", fail_count);
        if (fail_count == 0) $display("ALL PASS");
        else                 $display("FAILURES DETECTED");
        $finish;
    end

    // Timeout guard
    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

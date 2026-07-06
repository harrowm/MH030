`default_nettype none
`timescale 1ps/1ps

// Phase 49 testbench — MOVEP byte-interleaved memory access
//
// MOVEP Dn,(d16,An): store Dn bytes to alternating addresses
// MOVEP (d16,An),Dn: load bytes from alternating addresses into Dn
//
// Opcode: 0000 DDD1 dir siz 001 AAA + d16
//   dir=0 (f_ss[1]=0): mem→Dn load
//   dir=1 (f_ss[1]=1): Dn→mem store
//   siz=0 (f_ss[0]=0): word (2 bytes)
//   siz=1 (f_ss[0]=1): longword (4 bytes)
//   f_ss = {dir,siz}
//
// Encoding examples (DDD=Dn, 001=EA-mode, AAA=An):
//   MOVEP.W D1,(0,A0):  0000 001 1 10 001 000 + 0x0000 = 0x0318, 0x0000
//   MOVEP.L D1,(0,A0):  0000 001 1 11 001 000 + 0x0000 = 0x0338, 0x0000
//   MOVEP.W (0,A0),D1:  0000 001 1 00 001 000 + 0x0000 = 0x02D8...
//
// Wait — let me work out the encoding from the field layout:
//   [15:12]=0000, [11:9]=DDD, [8]=1, [7:6]=f_ss={dir,siz}, [5:3]=001, [2:0]=AAA
//   MOVEP.W D1,(0,A0): DDD=001, dir=1,siz=0 → f_ss=10 → [7:6]=10
//     = 0000 001 1 10 001 000 = 0000_0011_1000_1000 = 0x0388
//   MOVEP.L D1,(0,A0): f_ss=11
//     = 0000 001 1 11 001 000 = 0000_0011_1100_1000 = 0x03C8
//   MOVEP.W (0,A0),D1: f_ss=00
//     = 0000 001 1 00 001 000 = 0000_0011_0000_1000 = 0x0308
//   MOVEP.L (0,A0),D1: f_ss=01
//     = 0000 001 1 01 001 000 = 0000_0011_0100_1000 = 0x0348

`define DR(n)   u_dut.u_rf.d_reg[n]
`define AR(n)   u_dut.u_rf.a_reg[n]

module seq49_tb;

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

    // Byte-addressable RAM: addr[10:0] → 2 KB
    // For byte writes: mem_wdata[7:0] written at byte addr
    // For byte reads:  mem_rdata[7:0] = byte at addr
    logic [7:0] ram [0:2047];

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    assign mem_ack  = mem_req;
    assign mem_berr = 1'b0;

    // Read: return byte at addr in [7:0]; upper bytes zero
    assign mem_rdata = (mem_req && mem_rw) ? {24'h0, ram[mem_addr[10:0]]} : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[10:0]] <= mem_wdata[7:0];  // byte write

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

    task set_dn(input int n, input logic [31:0] val);
        run(16'h4280 | (16'(n) & 16'h7), 32'h0, 1'b0);
        run(16'h0680 | (16'(n) & 16'h7), val, 1'b1);
    endtask

    task set_an(input logic [2:0] an, input logic [31:0] val);
        set_d0(val);
        run({4'h2, an, 3'b001, 3'b000, 3'b000}, 32'h0, 1'b0);
    endtask

    // Run a MOVEP instruction — 1 ext word (d16 displacement).
    // n_bytes: 2 for word, 4 for long (bus cycles after start_r).
    task run_movep(input logic [15:0] op, input logic [15:0] disp,
                   input int n_bytes);
        @(posedge clk_4x); #1;
        instr_word  = op;
        ext_data    = {16'h0, disp};
        instr_valid = 1;
        ext_valid   = 1;
        @(posedge clk_4x); #1;
        instr_valid = 0;
        ext_valid   = 0;
        // start_r = 1 cycle, run_r = n_bytes cycles, pipeline drain = 6 cycles
        repeat (n_bytes + 8) @(posedge clk_4x);
        #1;
    endtask

    // Initialize all RAM locations to 0
    task clear_ram();
        for (int i = 0; i < 2048; i++) ram[i] = 8'h0;
    endtask

    // ─── Reset ────────────────────────────────────────────────────────────────
    initial begin
        @(posedge clk_4x); #1;
        rst_n = 1;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        clear_ram();

        // ──────────────────────────────────────────────────────────────────────
        // Test 1: MOVEP.W D1,(0,A0) — store word (2 bytes)
        //   D1 = 0x1234_5678 → writes byte 0x56 at A0+0, 0x78 at A0+2
        //   (lower word 0x5678: high byte → addr+0, low byte → addr+2)
        // Encoding: DDD=001, f_ss=10, 001, AAA=000 + d16=0
        //   [15:12]=0000, [11:9]=001, [8]=1, [7:6]=10, [5:3]=001, [2:0]=000
        //   = 0000_0011_1000_1000 = 0x0388
        // ──────────────────────────────────────────────────────────────────────
        set_an(3'd0, 32'h0000_0100);   // A0 = 0x100
        set_dn(1, 32'h1234_5678);      // D1 = 0x12345678
        run_movep(16'h0388, 16'h0000, 2);  // MOVEP.W D1,(0,A0)

        check("MOVEP.W store: byte0 at A0+0", {24'h0, ram[32'h100]}, 32'h56);
        check("MOVEP.W store: byte1 at A0+2", {24'h0, ram[32'h102]}, 32'h78);
        check("MOVEP.W store: A0+1 unmoved",  {24'h0, ram[32'h101]}, 32'h00);
        check("MOVEP.W store: A0+3 unmoved",  {24'h0, ram[32'h103]}, 32'h00);

        // ──────────────────────────────────────────────────────────────────────
        // Test 2: MOVEP.L D1,(0,A0) — store longword (4 bytes)
        //   D1 = 0xAABBCCDD → bytes at A0+0,A0+2,A0+4,A0+6 = AA,BB,CC,DD
        // Encoding: f_ss=11
        //   0000_0011_1100_1000 = 0x03C8
        // ──────────────────────────────────────────────────────────────────────
        set_an(3'd0, 32'h0000_0200);   // A0 = 0x200
        set_dn(1, 32'hAABBCCDD);       // D1
        run_movep(16'h03C8, 16'h0000, 4);  // MOVEP.L D1,(0,A0)

        check("MOVEP.L store: byte0 (AA) at A0+0", {24'h0, ram[32'h200]}, 32'hAA);
        check("MOVEP.L store: byte1 (BB) at A0+2", {24'h0, ram[32'h202]}, 32'hBB);
        check("MOVEP.L store: byte2 (CC) at A0+4", {24'h0, ram[32'h204]}, 32'hCC);
        check("MOVEP.L store: byte3 (DD) at A0+6", {24'h0, ram[32'h206]}, 32'hDD);
        check("MOVEP.L store: A0+1 unmoved",        {24'h0, ram[32'h201]}, 32'h00);
        check("MOVEP.L store: A0+3 unmoved",        {24'h0, ram[32'h203]}, 32'h00);

        // ──────────────────────────────────────────────────────────────────────
        // Test 3: MOVEP.W (0,A0),D1 — load word (2 bytes) into D1[15:0]
        //   RAM at 0x300: [0]=0xAB, [2]=0xCD → D1[15:8]=0xAB, D1[7:0]=0xCD
        //   D1[31:16] unchanged.  Pre-load D1=0xFFFF_0000 to verify upper word intact.
        // Encoding: f_ss=00
        //   0000_0011_0000_1000 = 0x0308
        // ──────────────────────────────────────────────────────────────────────
        ram[32'h300] = 8'hAB;
        ram[32'h302] = 8'hCD;
        set_an(3'd0, 32'h0000_0300);      // A0 = 0x300
        set_dn(1, 32'hFFFF_0000);         // D1 upper half = 0xFFFF (should be preserved)
        run_movep(16'h0308, 16'h0000, 2); // MOVEP.W (0,A0),D1

        // D1 pre-loaded with 0xFFFF_0000; MOVEP.W writes lower 16 bits → 0xFFFF_ABCD
        check("MOVEP.W load: D1 (upper preserved, lower loaded)", `DR(1), 32'hFFFF_ABCD);

        // ──────────────────────────────────────────────────────────────────────
        // Test 4: MOVEP.L (0,A0),D1 — load longword (4 bytes)
        //   RAM at 0x400: [0]=0x11,[2]=0x22,[4]=0x33,[6]=0x44 → D1=0x11223344
        // Encoding: f_ss=01
        //   0000_0011_0100_1000 = 0x0348
        // ──────────────────────────────────────────────────────────────────────
        ram[32'h400] = 8'h11;
        ram[32'h402] = 8'h22;
        ram[32'h404] = 8'h33;
        ram[32'h406] = 8'h44;
        set_an(3'd0, 32'h0000_0400);      // A0 = 0x400
        set_dn(1, 32'hDEAD_BEEF);         // D1 garbage initial
        run_movep(16'h0348, 16'h0000, 4); // MOVEP.L (0,A0),D1

        check("MOVEP.L load: D1", `DR(1), 32'h11223344);

        // ──────────────────────────────────────────────────────────────────────
        // Test 5: MOVEP.W with non-zero displacement
        //   MOVEP.W D2,(4,A1): d16=4, A1=0x500 → writes to 0x504, 0x506
        //   D2 = 0x0000_AABB → byte A1 at 0x504, byte BB at 0x506
        // MOVEP.W D2,(4,A1): DDD=010, f_ss=10, 001, AAA=001
        //   0000_0100_1000_1001 = 0x0489 + d16=0x0004
        //   Wait: DDD=010=D2, so [11:9]=010; AAA=001=A1 so [2:0]=001
        //   = 0000 010 1 10 001 001 = 0x0589
        // ──────────────────────────────────────────────────────────────────────
        set_an(3'd1, 32'h0000_0500);      // A1 = 0x500
        set_dn(2, 32'h0000_AABB);         // D2
        run_movep(16'h0589, 16'h0004, 2); // MOVEP.W D2,(4,A1)

        check("MOVEP.W disp: byte0 at 0x504", {24'h0, ram[32'h504]}, 32'hAA);
        check("MOVEP.W disp: byte1 at 0x506", {24'h0, ram[32'h506]}, 32'hBB);
        check("MOVEP.W disp: A1 not modified", `AR(1), 32'h0000_0500);

        // ──────────────────────────────────────────────────────────────────────
        // Test 6: MOVEP.L with negative displacement
        //   MOVEP.L D0,(-8,A0): d16=-8 = 0xFFF8, A0=0x610 → writes to 0x608-0x60E
        //   D0 = 0x11223344
        // MOVEP.L D0,(-8,A0): DDD=000, f_ss=11, 001, AAA=000
        //   = 0000 000 1 11 001 000 = 0x01C8 + d16=0xFFF8
        // ──────────────────────────────────────────────────────────────────────
        set_an(3'd0, 32'h0000_0610);      // A0 = 0x610
        set_d0(32'h11223344);
        run_movep(16'h01C8, 16'hFFF8, 4); // MOVEP.L D0,(-8,A0)

        check("MOVEP.L neg disp: byte0 at 0x608", {24'h0, ram[32'h608]}, 32'h11);
        check("MOVEP.L neg disp: byte1 at 0x60A", {24'h0, ram[32'h60A]}, 32'h22);
        check("MOVEP.L neg disp: byte2 at 0x60C", {24'h0, ram[32'h60C]}, 32'h33);
        check("MOVEP.L neg disp: byte3 at 0x60E", {24'h0, ram[32'h60E]}, 32'h44);

        // ──────────────────────────────────────────────────────────────────────
        // Test 7: Round-trip — store then load
        //   Store D3=0xCAFEBABE to (0,A0), then load back into D4.
        // ──────────────────────────────────────────────────────────────────────
        set_an(3'd0, 32'h0000_0700);
        set_dn(3, 32'hCAFEBABE);
        // MOVEP.L D3,(0,A0): DDD=011, f_ss=11, 001, 000 = 0000 011 1 11 001 000 = 0x07C8
        run_movep(16'h07C8, 16'h0000, 4);

        set_dn(4, 32'h0);
        // MOVEP.L (0,A0),D4: DDD=100, f_ss=01, 001, 000 = 0000 100 1 01 001 000 = 0x0948
        run_movep(16'h0948, 16'h0000, 4);
        check("MOVEP round-trip: D4", `DR(4), 32'hCAFEBABE);

        // ─── Final report ─────────────────────────────────────────────────────
        #100;
        if (fail_count == 0)
            $display("seq49: %0d passed, 0 failed\nPASS",
                     4 + 6 + 1 + 1 + 2 + 4 + 1);  // 19 checks
        else
            $display("seq49: %0d failed\nFAIL", fail_count);
        $finish;
    end

endmodule

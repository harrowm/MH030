`default_nettype none
`timescale 1ps/1ps

// Phase 37 testbench: EU memory access via inline EA computation.
//
// Tests: MOVE.L (An),Dn; MOVE.L (An)+,Dn; MOVE.L -(An),Dn;
//        MOVE.L (d16,An),Dn; MOVEA.L (An),An; LEA (An),An;
//        LEA (d16,An),An; MOVE.L Dn,(An); MOVE.L Dn,(An)+;
//        MOVE.L Dn,-(An); MOVE.L Dn,(d16,An).
//
// Memory model: combinational zero-wait-state response.
//   Reads:  mem_rdata = mem_addr | 32'hA0000001  (unique per address)
//   Writes: captured in wr_cap_addr/wr_cap_data for verification.

module seq37_tb;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    logic rst_n  = 0;
    always #5 clk_4x = ~clk_4x;

    // -----------------------------------------------------------------------
    // m68030_eu ports
    // -----------------------------------------------------------------------
    logic [15:0] instr_word  = 0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 0;
    logic        ext_valid   = 0;
    logic        instr_ack;
    logic        eu_busy;

    logic        pc_wr_en    = 0;
    logic [31:0] pc_wr_data  = 0;
    logic [31:0] pc_out;
    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 0;
    logic [31:0] vbr_out;
    logic [31:0] usp_out, msp_out, isp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;

    // Memory bus
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;

    // An update port (outputs from EU, observed but not driven here)
    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    // -----------------------------------------------------------------------
    // Memory model
    // -----------------------------------------------------------------------
    // Immediate (0 wait-state) combinational response.
    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? (mem_addr | 32'hA0000001) : 32'h0;

    // Write capture — holds last write until overwritten.
    logic [31:0] wr_cap_addr = 0;
    logic [31:0] wr_cap_data = 0;

    // Last bus transaction capture for address/direction checks.
    logic [31:0] last_mem_addr = 0;
    logic [2:0]  last_mem_fc   = 0;
    logic        last_mem_rw   = 0;
    logic        last_mem_seen = 0;

    always @(posedge clk_4x) begin
        if (mem_req) begin
            last_mem_addr <= mem_addr;
            last_mem_fc   <= mem_fc;
            last_mem_rw   <= mem_rw;
            last_mem_seen <= 1'b1;
            if (!mem_rw) begin
                wr_cap_addr <= mem_addr;
                wr_cap_data <= mem_wdata;
            end
        end else
            last_mem_seen <= 1'b0;
    end

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    m68030_eu u_eu (
        .clk_4x        (clk_4x),
        .rst_n         (rst_n),
        .instr_word    (instr_word),
        .instr_valid   (instr_valid),
        .ext_data      (ext_data),
        .ext_valid     (ext_valid),
        .instr_ack     (instr_ack),
        .eu_busy       (eu_busy),
        .pc_wr_en      (pc_wr_en),
        .pc_wr_data    (pc_wr_data),
        .pc_out        (pc_out),
        .vbr_wr_en     (vbr_wr_en),
        .vbr_wr_data   (vbr_wr_data),
        .vbr_out       (vbr_out),
        .usp_out       (usp_out),
        .msp_out       (msp_out),
        .isp_out       (isp_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .div_trap      (div_trap),
        .decode_pc     (32'h0),
        .branch_taken  (),
        .branch_target (),
        .mem_req       (mem_req),
        .mem_rw        (mem_rw),
        .mem_siz       (mem_siz),
        .mem_fc        (mem_fc),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_rdata     (mem_rdata),
        .mem_ack       (mem_ack),
        .mem_berr      (1'b0),
        .an_wr_en      (an_wr_en),
        .an_wr_sel     (an_wr_sel),
        .an_wr_data    (an_wr_data),
        .ssp_wr_en     (1'b0),
        .ssp_wr_data   (32'h0),
        .exc_sr_wr_en  (1'b0),
        .exc_sr_wr_data(16'h0)
    );

    // -----------------------------------------------------------------------
    // Instruction encodings
    // -----------------------------------------------------------------------
    // Non-memory setup instructions
    localparam [15:0]
        CLR_L_D0 = 16'h4280,
        CLR_L_D5 = 16'h4285,
        ADDI_L_D0 = 16'h0680,   // ADDI.L #imm, D0
        ADDI_L_D5 = 16'h0685,   // ADDI.L #imm, D5
        // MOVEA.L D0,An: group 2, dst_mode=001, src=D0
        // 0010_An_001_000_000 = 0x2040 | (An<<9)
        MOVEA_D0_A0 = 16'h2040, // [11:9]=000
        MOVEA_D0_A1 = 16'h2240, // [11:9]=001
        MOVEA_D0_A2 = 16'h2440, // [11:9]=010
        MOVEA_D0_A3 = 16'h2640, // [11:9]=011
        MOVEA_D0_A4 = 16'h2840; // [11:9]=100

    // Memory read instructions (dst = Dn)
    // MOVE.L: group 2 = 0010, dst_mode=000 (Dn)
    // Encoding: 0010_Dn_000_mode_An
    localparam [15:0]
        // MOVE.L (A0),D1: [11:9]=001, [8:6]=000, [5:3]=010, [2:0]=000 → 0x2210
        MOVE_L_iA0_D1   = 16'h2210,
        // MOVE.L (A0)+,D2: [11:9]=010, [8:6]=000, [5:3]=011, [2:0]=000 → 0x2418
        MOVE_L_A0inc_D2 = 16'h2418,
        // MOVE.L -(A1),D3: [11:9]=011, [8:6]=000, [5:3]=100, [2:0]=001 → 0x2621
        MOVE_L_A1dec_D3 = 16'h2621,
        // MOVE.L (d16,A0),D4: [11:9]=100, [8:6]=000, [5:3]=101, [2:0]=000 → 0x2828
        MOVE_L_d16A0_D4 = 16'h2828,
        // MOVEA.L (A0),A2: group2, dst_mode=001, dst_reg=2, src_mode=010, src_reg=0
        // [15:12]=0010, [11:9]=010, [8:6]=001, [5:3]=010, [2:0]=000 → 0x2450
        MOVEA_L_iA0_A2  = 16'h2450,
        // LEA (A0),A3: group4, f_dn=011, f_dir=1, f_ss=11, f_mode=010, f_reg=000
        // [15:12]=0100, [11:9]=011, [8:6]=111, [5:3]=010, [2:0]=000 → 0x47D0
        LEA_iA0_A3      = 16'h47D0,
        // LEA (d16,A0),A3: [11:9]=011, f_mode=101
        // [15:12]=0100, [11:9]=011, [8:6]=111, [5:3]=101, [2:0]=000 → 0x47E8
        LEA_d16A0_A3    = 16'h47E8,
        // LEA (d16,A0),A4: same but f_mode=101
        // [15:12]=0100, [11:9]=100, [8:6]=111, [5:3]=101, [2:0]=000 → 0x49E8
        LEA_d16A0_A4    = 16'h49E8;

    // Memory write instructions: MOVE.L D5,(dst_ea)
    // Group 2, src=D5=[2:0]=101, src_mode=000=[5:3]=000
    // dst encoded in [11:9]=An, [8:6]=dst_mode
    localparam [15:0]
        // MOVE.L D5,(A0): dst_reg=A0=0,[11:9]=000,[8:6]=010 → 0x2085
        MOVE_L_D5_iA0   = 16'h2085,
        // MOVE.L D5,(A0)+: [11:9]=000,[8:6]=011 → 0x20C5
        MOVE_L_D5_A0inc = 16'h20C5,
        // MOVE.L D5,-(A1): dst_reg=A1=1,[11:9]=001,[8:6]=100 → 0x2305
        MOVE_L_D5_A1dec = 16'h2305,
        // MOVE.L D5,(d16,A0): [11:9]=000,[8:6]=101 → 0x2145
        MOVE_L_D5_d16A0 = 16'h2145;

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("  PASS: %s", name);
        else begin $display("  FAIL: %s", name); fail_count++; end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("  PASS: %s (0x%08h)", name, got);
        else begin $display("  FAIL: %s: got 0x%08h exp 0x%08h", name, got, exp); fail_count++; end
    endtask

    // Present instruction for 1 cycle; drain 2 more cycles for EX→WB pipeline flush.
    // deassert after #1 per Icarus timing convention.
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        instr_word = iw; instr_valid = 1'b1;
        ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 1'b0; ext_valid = 1'b0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Set D0 to val (CLR then ADDI).
    task set_d0(input logic [31:0] val);
        run(CLR_L_D0, 32'h0, 1'b0);
        run(ADDI_L_D0, val, 1'b1);
    endtask

    // Set An to val via D0 → MOVEA.L D0,An.
    // an_movea_enc: MOVEA_D0_A0/A1/A2/A3/A4 localparam.
    task set_an(input logic [15:0] an_movea_enc, input logic [31:0] val);
        set_d0(val);
        run(an_movea_enc, 32'h0, 1'b0);
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $display("=== Phase 37: EU memory access instructions ===");

        // Release reset
        @(posedge clk_4x); #1;
        rst_n = 1'b1;
        @(posedge clk_4x); #1;

        // ================================================================
        // P37-1: MOVE.L (A0),D1  — basic indirect read
        // ================================================================
        $display("--- P37-1: MOVE.L (A0),D1 ---");
        set_an(MOVEA_D0_A0, 32'h1000);              // A0 = 0x1000
        run(MOVE_L_iA0_D1, 32'h0, 1'b0);            // D1 ← M[0x1000]
        check32("P37-1: D1 = M[0x1000]",
                u_eu.u_rf.d_reg[1], 32'h1000 | 32'hA0000001);
        check32("P37-1: mem_addr", last_mem_addr, 32'h1000);
        check  ("P37-1: mem_rw=read",  last_mem_rw);
        // Supervisor data space after reset (SR=0x2700 → S=1)
        check32("P37-1: mem_fc=101",   {29'h0, last_mem_fc}, 32'h5);

        // ================================================================
        // P37-2: MOVE.L (A0)+,D2  — post-increment read; A0 advances by 4
        // ================================================================
        $display("--- P37-2: MOVE.L (A0)+,D2 ---");
        // A0 still 0x1000 from P37-1 (indirect read didn't modify it)
        run(MOVE_L_A0inc_D2, 32'h0, 1'b0);          // D2 ← M[A0]; A0 += 4
        check32("P37-2: D2 = M[0x1000]",
                u_eu.u_rf.d_reg[2], 32'h1000 | 32'hA0000001);
        check32("P37-2: A0 post-inc to 0x1004",
                u_eu.u_rf.a_reg[0], 32'h1004);
        check32("P37-2: mem_addr", last_mem_addr, 32'h1000);

        // ================================================================
        // P37-3: MOVE.L -(A1),D3  — pre-decrement read; A1 drops by 4
        // ================================================================
        $display("--- P37-3: MOVE.L -(A1),D3 ---");
        set_an(MOVEA_D0_A1, 32'h1004);              // A1 = 0x1004
        run(MOVE_L_A1dec_D3, 32'h0, 1'b0);          // A1 -= 4; D3 ← M[A1=0x1000]
        check32("P37-3: D3 = M[0x1000]",
                u_eu.u_rf.d_reg[3], 32'h1000 | 32'hA0000001);
        check32("P37-3: A1 pre-dec to 0x1000",
                u_eu.u_rf.a_reg[1], 32'h1000);
        check32("P37-3: mem_addr", last_mem_addr, 32'h1000);

        // ================================================================
        // P37-4: MOVE.L (d16,A0),D4  — displacement read; addr = A0+8
        // ================================================================
        $display("--- P37-4: MOVE.L (d16,A0),D4 ---");
        set_an(MOVEA_D0_A0, 32'h1000);              // A0 = 0x1000
        // ext_data[15:0] = displacement = 8; addr = 0x1000 + 8 = 0x1008
        run(MOVE_L_d16A0_D4, 32'h0000_0008, 1'b1);
        check32("P37-4: D4 = M[0x1008]",
                u_eu.u_rf.d_reg[4], 32'h1008 | 32'hA0000001);
        check32("P37-4: A0 unchanged", u_eu.u_rf.a_reg[0], 32'h1000);
        check32("P37-4: mem_addr", last_mem_addr, 32'h1008);

        // ================================================================
        // P37-5: MOVEA.L (A0),A2  — indirect load into address register
        // ================================================================
        $display("--- P37-5: MOVEA.L (A0),A2 ---");
        set_an(MOVEA_D0_A0, 32'h1000);              // A0 = 0x1000
        run(MOVEA_L_iA0_A2, 32'h0, 1'b0);           // A2 ← M[0x1000]
        check32("P37-5: A2 = M[0x1000]",
                u_eu.u_rf.a_reg[2], 32'h1000 | 32'hA0000001);
        check32("P37-5: mem_addr", last_mem_addr, 32'h1000);

        // ================================================================
        // P37-6: LEA (A0),A3  — load effective address (no memory access)
        // ================================================================
        $display("--- P37-6: LEA (A0),A3 ---");
        set_an(MOVEA_D0_A0, 32'h2000);              // A0 = 0x2000
        run(LEA_iA0_A3, 32'h0, 1'b0);               // A3 = A0 = 0x2000
        check32("P37-6: A3 = 0x2000", u_eu.u_rf.a_reg[3], 32'h2000);
        check  ("P37-6: no mem_req",  !last_mem_seen);

        // ================================================================
        // P37-7: LEA (d16,A0),A4  — displacement EA (no memory access)
        // ================================================================
        $display("--- P37-7: LEA (d16,A0),A4 ---");
        // A0 = 0x2000 from P37-6 setup; displacement = 12 → A4 = 0x200C
        run(LEA_d16A0_A4, 32'h0000_000C, 1'b1);
        check32("P37-7: A4 = 0x200C", u_eu.u_rf.a_reg[4], 32'h200C);
        check  ("P37-7: no mem_req",  !last_mem_seen);

        // ================================================================
        // P37-8: MOVE.L D5,(A0)  — basic indirect write
        // ================================================================
        $display("--- P37-8: MOVE.L D5,(A0) ---");
        set_an(MOVEA_D0_A0, 32'h1000);              // A0 = 0x1000
        run(CLR_L_D5, 32'h0, 1'b0);
        run(ADDI_L_D5, 32'hDEAD_BEEF, 1'b1);        // D5 = 0xDEADBEEF
        run(MOVE_L_D5_iA0, 32'h0, 1'b0);            // M[0x1000] ← D5
        check32("P37-8: wr_cap_addr", wr_cap_addr, 32'h1000);
        check32("P37-8: wr_cap_data", wr_cap_data, 32'hDEAD_BEEF);
        check  ("P37-8: mem_rw=write", !last_mem_rw);
        check32("P37-8: A0 unchanged", u_eu.u_rf.a_reg[0], 32'h1000);

        // ================================================================
        // P37-9: MOVE.L D5,(A0)+  — post-increment write; A0 advances
        // ================================================================
        $display("--- P37-9: MOVE.L D5,(A0)+ ---");
        // A0 = 0x1000, D5 = 0xDEADBEEF from above
        run(MOVE_L_D5_A0inc, 32'h0, 1'b0);          // M[0x1000] ← D5; A0 += 4
        check32("P37-9: wr_cap_addr", wr_cap_addr, 32'h1000);
        check32("P37-9: wr_cap_data", wr_cap_data, 32'hDEAD_BEEF);
        check32("P37-9: A0 post-inc to 0x1004", u_eu.u_rf.a_reg[0], 32'h1004);

        // ================================================================
        // P37-10: MOVE.L D5,-(A1)  — pre-decrement write
        // ================================================================
        $display("--- P37-10: MOVE.L D5,-(A1) ---");
        set_an(MOVEA_D0_A1, 32'h1004);              // A1 = 0x1004
        // D5 = 0xDEADBEEF still
        run(MOVE_L_D5_A1dec, 32'h0, 1'b0);          // A1 -= 4; M[A1=0x1000] ← D5
        check32("P37-10: wr_cap_addr", wr_cap_addr, 32'h1000);
        check32("P37-10: wr_cap_data", wr_cap_data, 32'hDEAD_BEEF);
        check32("P37-10: A1 pre-dec to 0x1000", u_eu.u_rf.a_reg[1], 32'h1000);

        // ================================================================
        // P37-11: MOVE.L D5,(d16,A0)  — displacement write
        // ================================================================
        $display("--- P37-11: MOVE.L D5,(d16,A0) ---");
        set_an(MOVEA_D0_A0, 32'h1000);              // A0 = 0x1000
        // displacement = 4 → addr = 0x1004
        run(MOVE_L_D5_d16A0, 32'h0000_0004, 1'b1);  // M[0x1004] ← D5
        check32("P37-11: wr_cap_addr", wr_cap_addr, 32'h1004);
        check32("P37-11: wr_cap_data", wr_cap_data, 32'hDEAD_BEEF);
        check32("P37-11: A0 unchanged", u_eu.u_rf.a_reg[0], 32'h1000);

        // ================================================================
        // P37-12: Negative displacement on LEA
        // ================================================================
        $display("--- P37-12: LEA (d16,A0),A3 with negative d16 ---");
        set_an(MOVEA_D0_A0, 32'h1010);              // A0 = 0x1010
        // d16 = -16 = 0xFFF0; ext_data[15:0] = 0xFFF0; addr = 0x1010 + (-16) = 0x1000
        run(LEA_d16A0_A3, 32'h0000_FFF0, 1'b1);
        check32("P37-12: A3 = 0x1000 (neg disp)", u_eu.u_rf.a_reg[3], 32'h1000);

        // ================================================================
        // P37-13: MOVEA.L D0,An register path (non-memory MOVEA)
        // ================================================================
        $display("--- P37-13: MOVEA.L D0,A0 (register) ---");
        set_d0(32'hCAFE_BABE);
        run(MOVEA_D0_A0, 32'h0, 1'b0);              // A0 = D0 = 0xCAFEBABE
        check32("P37-13: A0 = 0xCAFEBABE", u_eu.u_rf.a_reg[0], 32'hCAFEBABE);
        check  ("P37-13: no mem_req", !last_mem_seen);

        // ================================================================
        // Done
        // ================================================================
        @(posedge clk_4x); #1;
        $display("=== Phase 37: %0d passed, %0d failed ===",
                 (33 - fail_count), fail_count);
        if (fail_count == 0) $display("ALL PASS");
        else $display("TESTS FAILED");
        $finish;
    end

endmodule

`default_nettype wire

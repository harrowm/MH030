`default_nettype none
`timescale 1ps/1ps

// Phase 46 testbench — MOVEC and MOVES
//   MOVEC Rc,Rn — read from control register (VBR, SFC, DFC, USP, ISP, MSP, CACR, CAAR)
//   MOVEC Rn,Rc — write to control register
//   MOVES (An),Rn — load from alternate FC (SFC)
//   MOVES Rn,(An) — store to alternate FC (DFC)

module seq46_tb;

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
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic        div_trap;
    logic        branch_taken;
    logic [31:0] branch_target;

    // ── Memory model ──────────────────────────────────────────────────────
    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_ack, mem_berr;

    logic [31:0] ram [0:511];

    assign mem_ack   = mem_req;
    assign mem_berr  = 1'b0;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[10:2]] : 32'h0;

    always @(posedge clk_4x)
        if (mem_req && !mem_rw)
            ram[mem_addr[10:2]] <= mem_wdata;

    // Record last FC seen on a bus cycle (for MOVES verification)
    logic [2:0] last_mem_fc;
    always @(posedge clk_4x)
        if (mem_req) last_mem_fc <= mem_fc;

    // ── An write port + SSP backdoor ───────────────────────────────────────
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
        .cacr_out      (cacr_out),
        .caar_out      (caar_out),
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

    task chk3(input string name, input logic [2:0] got, input logic [2:0] exp);
        if (got === exp) $display("PASS  %s  (got %0h)", name, got);
        else begin
            $display("FAIL  %s: got %0h  exp %0h", name, got, exp);
            fail_count++;
        end
    endtask

    // Present one instruction for exactly one clock; let pipeline drain 3 more.
    task run(input logic [15:0] iw, input logic [31:0] imm, input logic has_ext);
        @(posedge clk_4x); #1;
        instr_word = iw; instr_valid = 1; ext_data = imm; ext_valid = has_ext;
        @(posedge clk_4x); #1;
        instr_valid = 0; ext_valid = 0;
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
    endtask

    // Set D0: CLR.L D0 + ADDI.L #val,D0
    task set_d0(input logic [31:0] val);
        run(16'h4280, 32'h0, 1'b0);
        run(16'h0680, val,  1'b1);
    endtask

    // Set Dn (n=0..7)
    task set_dn(input int n, input logic [31:0] val);
        run(16'h4280 | (16'(n) & 16'h7), 32'h0, 1'b0);
        run(16'h0680 | (16'(n) & 16'h7), val,  1'b1);
    endtask

    // Set An via MOVEA.L D0,An (load D0 first, then MOVEA)
    task set_an(input logic [2:0] an, input logic [31:0] val);
        set_d0(val);
        run({4'h2, an, 3'b001, 3'b000, 3'b000}, 32'h0, 1'b0);
    endtask

    // Read Dn into a 32-bit variable via hierarchical reference
    function automatic [31:0] get_dn(input int n);
        return u_dut.u_rf.d_reg[n];
    endfunction

    function automatic [31:0] get_an(input int n);
        if (n < 7) return u_dut.u_rf.a_reg[n];
        else       return u_dut.u_rf.a7_current;
    endfunction

    // MOVEC Rc,Rn: 4E7A + ext_word{D/A[15], Rn[14:12], Rc[11:0]}
    // Using ext_data = {16'h0, ext_word}
    task movec_rc_rn(input logic        da,
                     input logic [2:0]  rn,
                     input logic [11:0] rc);
        run(16'h4E7A, {16'h0, da, rn, rc}, 1'b1);
    endtask

    // MOVEC Rn,Rc: 4E7B + same ext_word
    task movec_rn_rc(input logic        da,
                     input logic [2:0]  rn,
                     input logic [11:0] rc);
        run(16'h4E7B, {16'h0, da, rn, rc}, 1'b1);
    endtask

    // ── Test sequences ─────────────────────────────────────────────────────
    initial begin
        // ── Reset ──────────────────────────────────────────────────────────
        repeat (4) @(posedge clk_4x); #1;
        rst_n = 1;
        repeat (2) @(posedge clk_4x); #1;

        // ──────────────────────────────────────────────────────────────────
        // MV-1: MOVEC D0,VBR then MOVEC VBR,D1  (write then read VBR)
        // ──────────────────────────────────────────────────────────────────
        set_d0(32'hDEAD_C0DE);
        movec_rn_rc(1'b0, 3'b000, 12'h801);  // MOVEC D0,VBR
        // Wait one more drain cycle for WB to fire
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        // Verify via hierarchical: vbr_r register
        chk("MV-1a vbr_r", u_dut.u_rf.vbr_r, 32'hDEAD_C0DE);
        chk("MV-1b vbr_out", vbr_out,         32'hDEAD_C0DE);

        // MOVEC VBR,D1 (4E7A + ext: D/A=0, Rn=001=D1, Rc=801=VBR)
        movec_rc_rn(1'b0, 3'b001, 12'h801);
        @(posedge clk_4x); #1;
        chk("MV-1c D1=VBR", get_dn(1), 32'hDEAD_C0DE);

        // ──────────────────────────────────────────────────────────────────
        // MV-2: MOVEC D0,SFC / MOVEC SFC,D2  (SFC = 3-bit function code)
        // ──────────────────────────────────────────────────────────────────
        set_d0(32'h0000_0005);   // supervisor data space FC=101
        movec_rn_rc(1'b0, 3'b000, 12'h000);  // MOVEC D0,SFC
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk3("MV-2a sfc_r", u_dut.u_rf.sfc_r, 3'b101);

        movec_rc_rn(1'b0, 3'b010, 12'h000);  // MOVEC SFC,D2
        @(posedge clk_4x); #1;
        chk("MV-2b D2=SFC", get_dn(2), 32'h0000_0005);

        // ──────────────────────────────────────────────────────────────────
        // MV-3: MOVEC D0,DFC / MOVEC DFC,D3  (DFC = destination FC)
        // ──────────────────────────────────────────────────────────────────
        set_d0(32'h0000_0001);   // user data space FC=001
        movec_rn_rc(1'b0, 3'b000, 12'h001);  // MOVEC D0,DFC
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk3("MV-3a dfc_r", u_dut.u_rf.dfc_r, 3'b001);

        movec_rc_rn(1'b0, 3'b011, 12'h001);  // MOVEC DFC,D3
        @(posedge clk_4x); #1;
        chk("MV-3b D3=DFC", get_dn(3), 32'h0000_0001);

        // ──────────────────────────────────────────────────────────────────
        // MV-4: MOVEC A0,USP / MOVEC USP,A1  (USP bypasses S/M routing)
        // ──────────────────────────────────────────────────────────────────
        set_an(3'h0, 32'hA000_1234);
        movec_rn_rc(1'b1, 3'b000, 12'h800);  // MOVEC A0,USP  (DA=1)
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk("MV-4a usp_r", u_dut.u_rf.usp_r, 32'hA000_1234);
        chk("MV-4b usp_out", usp_out,         32'hA000_1234);

        movec_rc_rn(1'b1, 3'b001, 12'h800);  // MOVEC USP,A1  (DA=1, A1)
        @(posedge clk_4x); #1;
        chk("MV-4c A1=USP", get_an(1), 32'hA000_1234);

        // ──────────────────────────────────────────────────────────────────
        // MV-5: MOVEC D0,CACR / MOVEC CACR,D4
        // ──────────────────────────────────────────────────────────────────
        set_d0(32'h0000_0101);   // enable I-cache + D-cache (bits 8 and 0)
        movec_rn_rc(1'b0, 3'b000, 12'h002);  // MOVEC D0,CACR
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk("MV-5a cacr_r", u_dut.u_rf.cacr_r, 32'h0000_0101);
        chk("MV-5b cacr_out", cacr_out,         32'h0000_0101);

        movec_rc_rn(1'b0, 3'b100, 12'h002);  // MOVEC CACR,D4
        @(posedge clk_4x); #1;
        chk("MV-5c D4=CACR", get_dn(4), 32'h0000_0101);

        // ──────────────────────────────────────────────────────────────────
        // MV-6: MOVEC A0,ISP / MOVEC ISP,A2  (ISP = interrupt stack ptr)
        // ──────────────────────────────────────────────────────────────────
        set_an(3'h0, 32'hB000_5678);
        movec_rn_rc(1'b1, 3'b000, 12'h804);  // MOVEC A0,ISP
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk("MV-6a isp_r", u_dut.u_rf.isp_r, 32'hB000_5678);

        movec_rc_rn(1'b1, 3'b010, 12'h804);  // MOVEC ISP,A2
        @(posedge clk_4x); #1;
        chk("MV-6b A2=ISP", get_an(2), 32'hB000_5678);

        // ──────────────────────────────────────────────────────────────────
        // MV-7: MOVES (A3),D0 — load using SFC (FC should equal SFC value)
        //   SFC was set to 3'b101 in MV-2; set it to 3'b001 (user data) here.
        //   Place 0xCAFEBABE in ram; point A3 at it.
        // ──────────────────────────────────────────────────────────────────
        // SFC = 1 (user data space)
        set_d0(32'h0000_0001);
        movec_rn_rc(1'b0, 3'b000, 12'h000);  // MOVEC D0,SFC
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        // Point A3 at RAM address 0x100
        set_an(3'h3, 32'h0000_0100);

        // Pre-load RAM[0x100/4 = 64] with test value
        ram[64] = 32'hCAFE_BABE;

        // MOVES.L (A3),D0 — opcode 0x0E91 + ext{D/A=0, D0=000, load=1}
        // MOVES.L (A3): f_group=0, f_dn=7, f_dir=0, f_ss=10(long), f_mode=010, f_reg=011(A3)
        // Recompute opcode for A3: f_reg=011 → bits[2:0]=011
        // 0x0E91 was for A1; for A3: bits[2:0]=011 → 0x0E93
        // ext word: D/A=0, Rn=000(D0), dir=1(load) → 0x0800
        run(16'h0E93, 32'h0000_0800, 1'b1);  // MOVES.L (A3),D0
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        chk("MV-7a D0=mem", get_dn(0), 32'hCAFE_BABE);
        chk3("MV-7b FC=SFC", last_mem_fc, 3'b001);

        // ──────────────────────────────────────────────────────────────────
        // MV-8: MOVES D1,(A3) — store using DFC
        //   DFC was set to 3'b001 (user data) in MV-3.
        //   Write D1 = 0x11223344 to [A3].
        // ──────────────────────────────────────────────────────────────────
        set_dn(1, 32'h1122_3344);

        // MOVES.L D1,(A3) — same opcode 0x0E93
        // ext word: D/A=0, Rn=001(D1), dir=0(store) → 0x1000
        run(16'h0E93, 32'h0000_1000, 1'b1);  // MOVES.L D1,(A3)
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        chk("MV-8a ram", ram[64], 32'h1122_3344);
        chk3("MV-8b FC=DFC", last_mem_fc, 3'b001);

        // ──────────────────────────────────────────────────────────────────
        // MV-9: MOVES (A3)+,D2 — post-increment load; A3 should advance by 4
        // ──────────────────────────────────────────────────────────────────
        // Set A3 back to 0x100
        set_an(3'h3, 32'h0000_0100);
        ram[64] = 32'hFEED_F00D;

        // MOVES.L (A3)+,D2 — opcode: f_mode=011(post-inc), f_reg=011(A3)
        // 0x0E91 was f_mode=010, f_reg=001. For f_mode=011, f_reg=011:
        // [5:3]=011, [2:0]=011 → [7:0] = f_ss=10, f_mode=011, f_reg=011
        // = 1 0 0 1 1 0 1 1 = 0x9B
        // opcode = 0x0E9B
        // ext word: D/A=0, Rn=010(D2), dir=1(load) → {0, 010, 1, ...} = 0x2800
        run(16'h0E9B, 32'h0000_2800, 1'b1);  // MOVES.L (A3)+,D2
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;

        chk("MV-9a D2=mem", get_dn(2), 32'hFEED_F00D);
        chk("MV-9b A3+=4",  get_an(3), 32'h0000_0104);
        chk3("MV-9c FC=SFC", last_mem_fc, 3'b001);

        // ──────────────────────────────────────────────────────────────────
        // MV-10: MOVEC D0,MSP / MOVEC MSP,A4  (MSP = master stack ptr)
        // ──────────────────────────────────────────────────────────────────
        set_d0(32'hC000_9ABC);
        movec_rn_rc(1'b0, 3'b000, 12'h803);  // MOVEC D0,MSP
        @(posedge clk_4x); #1;
        @(posedge clk_4x); #1;
        chk("MV-10a msp_r",  u_dut.u_rf.msp_r, 32'hC000_9ABC);

        movec_rc_rn(1'b1, 3'b100, 12'h803);  // MOVEC MSP,A4
        @(posedge clk_4x); #1;
        chk("MV-10b A4=MSP", get_an(4), 32'hC000_9ABC);

        // ──────────────────────────────────────────────────────────────────
        // Done
        // ──────────────────────────────────────────────────────────────────
        @(posedge clk_4x); #1;
        if (fail_count == 0)
            $display("PASS  all seq46 tests (%0d checks)", 22);
        else
            $display("FAIL  %0d test(s) failed", fail_count);
        $finish;
    end

    // Watchdog
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire

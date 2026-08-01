// ALU to memory (read-modify-write): OR/AND/EOR/ADD/SUB/ADDQ/CLR/NOT/NEG/TST/Scc/ASL/BSET/ADDI
// ALU from memory to register: ADD/SUB/AND/OR/CMP + MULU/MULS/DIVU/DIVS, all memory EA modes.
`default_nettype none
`timescale 1ns/1ps

module alu_mem_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk);
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word  = 16'h4E71;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 32'h0;
    logic [15:0] q3_word     = 16'h0;
    logic [31:0] ext34_data  = 32'h0;
    logic        ext_valid   = 0;
    logic        instr_ack;
    logic        eu_busy;

    logic        pc_wr_en    = 0;
    logic [31:0] pc_wr_data  = 32'h0;
    logic [31:0] pc_out;
    logic        vbr_wr_en   = 0;
    logic [31:0] vbr_wr_data = 32'h0;
    logic [31:0] vbr_out;

    logic [31:0] usp_out, msp_out, isp_out;
    logic [31:0] cacr_out, caar_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic [31:0] decode_pc   = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
    logic        mem_berr   = 0;
    logic        mem_rmw;

    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;
    logic [31:0] eu_coproc_rdata = 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack  = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack   = 0;
    logic [15:0] eu_ptest_mmusr = 16'h0;
    logic [31:0] tc_out, tt0_out, tt1_out;
    logic [63:0] crp_out, srp_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;
    logic [31:0] an_wr_data_cap;  // latest An value written (for postinc/predec checks)

    always_ff @(posedge clk) begin
        if (an_wr_en)
            an_wr_data_cap <= an_wr_data;
    end

    logic        div_trap, chk_trap;
    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;
    logic        eu_reset_req;
    logic        eu_priv_req;
    logic        eu_trace_req;
    logic        eu_linea_req;
    logic        eu_linef_req;
    logic        eu_fmt_err_req;

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x          (clk),
        .rst_n           (rst_n),
        .instr_word      (instr_word),
        .instr_valid     (instr_valid),
        .ext_data        (ext_data),
        .q3_word         (q3_word),
        .ext34_data      (ext34_data),
        .ext_valid       (ext_valid),
        .instr_ack       (instr_ack),
        .eu_busy         (eu_busy),
        .pc_wr_en        (pc_wr_en),
        .pc_wr_data      (pc_wr_data),
        .pc_out          (pc_out),
        .vbr_wr_en       (vbr_wr_en),
        .vbr_wr_data     (vbr_wr_data),
        .vbr_out         (vbr_out),
        .usp_out         (usp_out),
        .msp_out         (msp_out),
        .isp_out         (isp_out),
        .cacr_out        (cacr_out),
        .caar_out        (caar_out),
        .sr_out          (sr_out),
        .supervisor      (supervisor),
        .master_mode     (master_mode),
        .ipl_mask        (ipl_mask),
        .decode_pc       (decode_pc),
        .branch_taken    (branch_taken),
        .branch_target   (branch_target),
        .mem_req         (mem_req),
        .mem_rw          (mem_rw),
        .mem_siz         (mem_siz),
        .mem_fc          (mem_fc),
        .mem_addr        (mem_addr),
        .mem_wdata       (mem_wdata),
        .mem_rdata       (mem_rdata),
        .mem_ack         (mem_ack),
        .mem_berr        (mem_berr),
        .mem_rmw         (mem_rmw),
        .eu_coproc_req   (eu_coproc_req),
        .eu_coproc_rw    (eu_coproc_rw),
        .eu_coproc_siz   (eu_coproc_siz),
        .eu_coproc_fc    (eu_coproc_fc),
        .eu_coproc_addr  (eu_coproc_addr),
        .eu_coproc_wdata (eu_coproc_wdata),
        .eu_coproc_rdata (eu_coproc_rdata),
        .eu_coproc_ack   (eu_coproc_ack),
        .eu_coproc_berr  (eu_coproc_berr),
        .eu_pflush_req   (eu_pflush_req),
        .eu_pflush_all   (eu_pflush_all),
        .eu_pflush_fc    (eu_pflush_fc),
        .eu_pflush_va    (eu_pflush_va),
        .eu_pflush_ack   (eu_pflush_ack),
        .eu_ptest_req    (eu_ptest_req),
        .eu_ptest_va     (eu_ptest_va),
        .eu_ptest_fc     (eu_ptest_fc),
        .eu_ptest_ack    (eu_ptest_ack),
        .eu_ptest_mmusr  (eu_ptest_mmusr),
        .tc_out          (tc_out),
        .tt0_out         (tt0_out),
        .tt1_out         (tt1_out),
        .crp_out         (crp_out),
        .srp_out         (srp_out),
        .an_wr_en        (an_wr_en),
        .an_wr_sel       (an_wr_sel),
        .an_wr_data      (an_wr_data),
        .div_trap        (div_trap),
        .chk_trap        (chk_trap),
        .eu_trap_req     (eu_trap_req),
        .eu_trap_num     (eu_trap_num),
        .eu_trapv_req    (eu_trapv_req),
        .eu_illegal_req  (eu_illegal_req),
        .eu_stop         (eu_stop),
        .eu_reset_req    (eu_reset_req),
        .eu_priv_req     (eu_priv_req),
        .eu_trace_req    (eu_trace_req),
        .eu_linea_req    (eu_linea_req),
        .eu_linef_req    (eu_linef_req),
        .eu_fmt_err_req  (eu_fmt_err_req),
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (8K × 32, combinatorial read, synchronous write) ───────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── Test infrastructure ─────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        chk(tag, {31'h0, got}, {31'h0, exp});
    endtask

    task automatic chk_ccr(input string tag,
                            input logic exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
    endtask

    // Present instruction, poll for ack, drain 15 cycles for 2 mem + WB.
    task automatic run_instr(input logic [15:0] w0,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk);
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(15) @(posedge clk);
    endtask

    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(3'd0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // ─── Test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ====================================================================
        // Memory RMW: EU reads (An), computes result, writes back
        // ====================================================================
        $display("--- OR.L D0,(A0) ---");
        // M[0x100]=0x0F0F0F0F, D0=0xF0F0F0F0 → 0xFFFFFFFF; N=1
        ram[8'h40] = 32'h0F0F_0F0F;
        set_an(3'd0, 32'h0000_0100);
        set_dn(3'd0, 32'hF0F0_F0F0);
        run_instr(16'h8190, 1'b0, 32'h0);
        chk("OR-01:mem",  ram[8'h40], 32'hFFFF_FFFF);
        chk_ccr("OR-01", 1'b1, 1'b0, 1'b0, 1'b0);

        $display("--- AND.L D1,(A1) ---");
        // M[0x104]=0xFFFF0000, D1=0x0F0FFFFF → 0x0F0F0000; N=0
        ram[8'h41] = 32'hFFFF_0000;
        set_dn(3'd1, 32'h0F0F_FFFF);
        set_an(3'd1, 32'h0000_0104);
        run_instr(16'hC391, 1'b0, 32'h0);
        chk("AND-01:mem", ram[8'h41], 32'h0F0F_0000);
        chk_ccr("AND-01", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- EOR.L D2,(A2) ---");
        // M[0x108]=0x55555555, D2=0xAAAAAAAA → 0xFFFFFFFF; N=1
        ram[8'h42] = 32'h5555_5555;
        set_dn(3'd2, 32'hAAAA_AAAA);
        set_an(3'd2, 32'h0000_0108);
        run_instr(16'hB592, 1'b0, 32'h0);
        chk("EOR-01:mem", ram[8'h42], 32'hFFFF_FFFF);
        chk_ccr("EOR-01", 1'b1, 1'b0, 1'b0, 1'b0);

        $display("--- ADD.L D3,(A3) (carry out: 1+0xFFFFFFFF=0, Z=1, C=1) ---");
        // M[0x10C]=0x00000001, D3=0xFFFFFFFF → 0x00000000
        ram[8'h43] = 32'h0000_0001;
        set_dn(3'd3, 32'hFFFF_FFFF);
        set_an(3'd3, 32'h0000_010C);
        run_instr(16'hD793, 1'b0, 32'h0);
        chk("ADD-01:mem", ram[8'h43], 32'h0000_0000);
        chk_ccr("ADD-01", 1'b0, 1'b1, 1'b0, 1'b1);

        $display("--- SUB.L D4,(A4) (10-3=7) ---");
        // M[0x110]=0x0000000A, D4=0x00000003 → 0x00000007
        ram[8'h44] = 32'h0000_000A;
        set_dn(3'd4, 32'h0000_0003);
        set_an(3'd4, 32'h0000_0110);
        run_instr(16'h9994, 1'b0, 32'h0);
        chk("SUB-01:mem", ram[8'h44], 32'h0000_0007);
        chk_ccr("SUB-01", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADDQ.L #5,(A0) (-5+5=0, Z=1, C=1) ---");
        // M[0x100]=0xFFFFFFFB, imm=5 → 0x00000000
        ram[8'h40] = 32'hFFFF_FFFB;
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h5A90, 1'b0, 32'h0);
        chk("ADDQ-01:mem", ram[8'h40], 32'h0000_0000);
        chk_ccr("ADDQ-01", 1'b0, 1'b1, 1'b0, 1'b1);

        $display("--- CLR.L (A1) ---");
        // M[0x114]=0xDEADBEEF → 0x00000000; N=0, Z=1
        ram[8'h45] = 32'hDEAD_BEEF;
        set_an(3'd1, 32'h0000_0114);
        run_instr(16'h4291, 1'b0, 32'h0);
        chk("CLR-01:mem", ram[8'h45], 32'h0000_0000);
        chk_ccr("CLR-01", 1'b0, 1'b1, 1'b0, 1'b0);

        $display("--- NOT.L (A2) ---");
        // M[0x118]=0xDEADBEEF → ~0xDEADBEEF=0x21524110; N=0
        ram[8'h46] = 32'hDEAD_BEEF;
        set_an(3'd2, 32'h0000_0118);
        run_instr(16'h4692, 1'b0, 32'h0);
        chk("NOT-01:mem", ram[8'h46], 32'h2152_4110);
        chk_ccr("NOT-01", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- NEG.L (A3) (negate 5 → -5=0xFFFFFFFB; N=1, C=1) ---");
        // M[0x11C]=0x00000005 → 0xFFFFFFFB
        ram[8'h47] = 32'h0000_0005;
        set_an(3'd3, 32'h0000_011C);
        run_instr(16'h4493, 1'b0, 32'h0);
        chk("NEG-01:mem", ram[8'h47], 32'hFFFF_FFFB);
        chk_ccr("NEG-01", 1'b1, 1'b0, 1'b0, 1'b1);

        $display("--- TST.L (A0) (read-only, CCR only, N=1) ---");
        // M[0x100]=0x80000000 → no write back; N=1
        ram[8'h40] = 32'h8000_0000;
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h4A90, 1'b0, 32'h0);
        chk("TST-01:mem-unchanged", ram[8'h40], 32'h8000_0000);
        chk_ccr("TST-01", 1'b1, 1'b0, 1'b0, 1'b0);

        $display("--- SEQ (A1) (Z=1 → write 0xFF byte; EU puts byte in [31:24]) ---");
        // CLR.L D0 sets Z=1; SEQ writes 0xFF to M[0x120]
        ram[8'h48] = 32'h1234_5678;
        set_an(3'd1, 32'h0000_0120);
        run_instr(16'h4280, 1'b0, 32'h0);   // CLR.L D0 → Z=1
        run_instr(16'h57D1, 1'b0, 32'h0);   // SEQ (A1)
        chk("SEQ-01:mem", ram[8'h48], 32'hFF00_0000);

        $display("--- ASL.W (A2) (shift left word by 1: 0x1234→0x2468) ---");
        // M[0x124]=0x00001234; result word=0x2468 in [31:16]
        ram[8'h49] = 32'h0000_1234;
        set_an(3'd2, 32'h0000_0124);
        run_instr(16'hE1D2, 1'b0, 32'h0);
        chk("ASL-01:mem", ram[8'h49], 32'h2468_0000);
        chk_ccr("ASL-01", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- BSET D0,(A3) (bit 3 of byte; was 0 → Z=1, result=0x08) ---");
        // D0=3, M[0x128]=0x00; byte 0x08 written in [31:24]
        ram[8'h4A] = 32'h0000_0000;
        set_an(3'd3, 32'h0000_0128);
        set_dn(3'd0, 32'h0000_0003);
        run_instr(16'h01D3, 1'b0, 32'h0);
        chk("BSET-01:mem", ram[8'h4A], 32'h0800_0000);
        chk1("BSET-01:Z",  sr_out[2],  1'b1);

        $display("--- ADDI.L #0x200,(A0) (immediate to memory: 0x1100+0x200=0x1300) ---");
        // M[0x100]=0x1100 → 0x1300
        ram[8'h40] = 32'h0000_1100;
        set_an(3'd0, 32'h0000_0100);
        run_instr(16'h0690, 1'b1, 32'h0000_0200);
        chk("ADDI-01:mem", ram[8'h40], 32'h0000_1300);
        chk_ccr("ADDI-01", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADD.L D0,(A0)+ (postincrement: A0 advances after write) ---");
        // M[0x12C]=0x0C00, D0=0x100 → 0x0D00; A0 → 0x130
        ram[8'h4B] = 32'h0000_0C00;
        set_an(3'd0, 32'h0000_012C);
        set_dn(3'd0, 32'h0000_0100);
        run_instr(16'hD198, 1'b0, 32'h0);
        chk("ADD-02:mem", ram[8'h4B],     32'h0000_0D00);
        chk("ADD-02:A0",  an_wr_data_cap, 32'h0000_0130);
        chk_ccr("ADD-02", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- SUB.L D1,-(A1) (predecrement: A1 decrements before access) ---");
        // A1=0x134, EA=0x130, M[0x130]=0x100; D1=1; result=0xFF; A1→0x130
        ram[8'h4C] = 32'h0000_0100;
        set_dn(3'd1, 32'h0000_0001);
        set_an(3'd1, 32'h0000_0134);
        run_instr(16'h93A1, 1'b0, 32'h0);
        chk("SUB-02:mem", ram[8'h4C],     32'h0000_00FF);
        chk("SUB-02:A1",  an_wr_data_cap, 32'h0000_0130);
        chk_ccr("SUB-02", 1'b0, 1'b0, 1'b0, 1'b0);

        // ====================================================================
        // ALU memory-source → register destination
        // ====================================================================
        $display("--- ADD.L (8,A0),D1 (d16,An source) ---");
        // A0=0x1000, EA=0x1008; mem=0x1234; D1=0x5000 → 0x6234
        set_an(3'd0, 32'h0000_1000);
        set_dn(3'd1, 32'h0000_5000);
        ram[32'h1008 >> 2] = 32'h0000_1234;
        run_instr(16'hD2A8, 1'b1, 32'h0000_0008);
        chk("ADD-03:D1", dut.u_rf.d_reg[1], 32'h0000_6234);

        $display("--- SUB.L (0x2000).W,D2 (abs.W source) ---");
        // mem[0x2000]=0x300; D2=0x1000 → 0x0D00
        set_dn(3'd2, 32'h0000_1000);
        ram[32'h2000 >> 2] = 32'h0000_0300;
        run_instr(16'h94B8, 1'b1, 32'h0000_2000);
        chk("SUB-03:D2", dut.u_rf.d_reg[2], 32'h0000_0D00);

        $display("--- AND.L (0x3000).L,D3 (abs.L source) ---");
        // mem[0x3000]=0xF0F0F0F0; D3=0xFF00FF00 → 0xF000F000
        set_dn(3'd3, 32'hFF00_FF00);
        ram[32'h3000 >> 2] = 32'hF0F0_F0F0;
        run_instr(16'hC6B9, 1'b1, 32'h0000_3000);
        chk("AND-02:D3", dut.u_rf.d_reg[3], 32'hF000_F000);

        $display("--- OR.L (d16,PC),D4 (PC-relative source) ---");
        // decode_pc=0x4000, d16=6 → EA=0x4008; mem=0xF0F00000; D4=0xF → 0xF0F0000F
        decode_pc = 32'h0000_4000;
        set_dn(3'd4, 32'h0000_000F);
        ram[32'h4008 >> 2] = 32'hF0F0_0000;
        run_instr(16'h88BA, 1'b1, 32'h0000_0006);
        decode_pc = 32'h0;
        chk("OR-02:D4", dut.u_rf.d_reg[4], 32'hF0F0_000F);

        $display("--- CMP.L (0x10,A1),D5 (equal → Z=1) ---");
        // A1=0x5000, EA=0x5010; D5=0x200, mem=0x200 → equal
        set_an(3'd1, 32'h0000_5000);
        set_dn(3'd5, 32'h0000_0200);
        ram[32'h5010 >> 2] = 32'h0000_0200;
        run_instr(16'hBAA9, 1'b1, 32'h0000_0010);
        chk("CMP-01:D5-unch", dut.u_rf.d_reg[5], 32'h0000_0200);
        chk1("CMP-01:Z=1", sr_out[2], 1'b1);

        $display("--- CMP.L (0x10,A1),D5 (D5>mem → Z=0, N=0) ---");
        ram[32'h5010 >> 2] = 32'h0000_0100;
        run_instr(16'hBAA9, 1'b1, 32'h0000_0010);
        chk1("CMP-02:Z=0", sr_out[2], 1'b0);
        chk1("CMP-02:N=0", sr_out[3], 1'b0);

        $display("--- MULU.W (4,A2),D6 (3×4=12) ---");
        // A2=0x6000, EA=0x6004; D6=3, mem[0x6004][15:0]=4 → D6=12
        set_an(3'd2, 32'h0000_6000);
        set_dn(3'd6, 32'h0000_0003);
        ram[32'h6004 >> 2] = 32'h0000_0004;
        run_instr(16'hCCEA, 1'b1, 32'h0000_0004);
        chk("MULU-01:D6", dut.u_rf.d_reg[6], 32'h0000_000C);

        $display("--- MULS.W (0x7000).W,D0 (5×(-2)=-10=0xFFFFFFF6) ---");
        // D0=5, mem[0x7000][15:0]=0xFFFE → -2 signed
        set_dn(3'd0, 32'h0000_0005);
        ram[32'h7000 >> 2] = 32'h0000_FFFE;
        run_instr(16'hC1F8, 1'b1, 32'h0000_7000);
        chk("MULS-01:D0", dut.u_rf.d_reg[0], 32'hFFFF_FFF6);

        $display("--- DIVU.W (0x7800).W,D7 (12÷3=4) ---");
        // D7=12, mem[0x7800][15:0]=3 → quot=4 rem=0
        set_dn(3'd7, 32'h0000_000C);
        ram[32'h7800 >> 2] = 32'h0000_0003;
        run_instr(16'h8EF8, 1'b1, 32'h0000_7800);
        chk("DIVU-01:D7", dut.u_rf.d_reg[7], 32'h0000_0004);

        $display("--- ADD.L (0x2000).W,D1 (CCR: Z=0, N=0, C=0) ---");
        // D1=0x20, mem[0x2000]=0x10 → D1=0x30
        set_dn(3'd1, 32'h0000_0020);
        ram[32'h2000 >> 2] = 32'h0000_0010;
        run_instr(16'hD2B8, 1'b1, 32'h0000_2000);
        chk("ADD-04:D1", dut.u_rf.d_reg[1], 32'h0000_0030);
        chk1("ADD-04:Z=0", sr_out[2], 1'b0);
        chk1("ADD-04:N=0", sr_out[3], 1'b0);
        chk1("ADD-04:C=0", sr_out[0], 1'b0);

        $display("--- DIVS.W (8,A3),D2 (24÷(-4)=-6 quot; rem=0) ---");
        // A3=0x0800, EA=0x0808; D2=24, mem[0x0808][15:0]=0xFFFC (-4)
        // Result: D2=0x0000_FFFA (rem=0 in [31:16], quot=-6=0xFFFA in [15:0])
        set_an(3'd3, 32'h0000_0800);
        set_dn(3'd2, 32'h0000_0018);
        ram[32'h0808 >> 2] = 32'h0000_FFFC;
        run_instr(16'h85EB, 1'b1, 32'h0000_0008);
        chk("DIVS-01:D2", dut.u_rf.d_reg[2], 32'h0000_FFFA);

        // ─── Phase 78: new/extended decoder paths ────────────────────────────

        // ADD/SUB #imm, Dn — new decode branch in eu_seq.sv (groups 9/D)
        $display("--- ADD.B #5, D0 (imm->Dn byte) ---");
        set_dn(3'd0, 32'h0000_0012);
        run_instr(16'hD03C, 1'b1, 32'h0000_0005);
        chk("ADDI-B:D0", dut.u_rf.d_reg[0], 32'h0000_0017);
        chk_ccr("ADDI-B", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADD.W #0x100, D1 (imm->Dn word) ---");
        set_dn(3'd1, 32'h0000_0200);
        run_instr(16'hD27C, 1'b1, 32'h0000_0100);
        chk("ADDI-W:D1", dut.u_rf.d_reg[1], 32'h0000_0300);
        chk_ccr("ADDI-W", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- ADD.L #0x1000, D2 (imm->Dn long) ---");
        set_dn(3'd2, 32'h0000_2000);
        run_instr(16'hD4BC, 1'b1, 32'h0000_1000);
        chk("ADDI-L:D2", dut.u_rf.d_reg[2], 32'h0000_3000);
        chk_ccr("ADDI-L", 1'b0, 1'b0, 1'b0, 1'b0);

        $display("--- SUB.W #0x50, D3 (imm->Dn word, group 9) ---");
        set_dn(3'd3, 32'h0000_0060);
        run_instr(16'h967C, 1'b1, 32'h0000_0050);
        chk("SUBI-W:D3", dut.u_rf.d_reg[3], 32'h0000_0010);
        chk_ccr("SUBI-W", 1'b0, 1'b0, 1'b0, 1'b0);

        // ADD Dn, (d16,An) — extended decoder to include f_mode=101 as mem dest
        // opcode 0xD1A9: ADD.L D0,(8,A1); d16=8 → EA=A1+8
        $display("--- ADD.L D0,(8,A1) (Dn->mem d16 dest) ---");
        set_an(3'd1, 32'h0000_7000);
        set_dn(3'd0, 32'h0000_0300);
        ram[32'h7008 >> 2] = 32'h0000_2000;
        run_instr(16'hD1A9, 1'b1, 32'h0000_0008);
        chk("ADD-d16:mem", ram[32'h7008 >> 2], 32'h0000_2300);
        chk_ccr("ADD-d16",  1'b0, 1'b0, 1'b0, 1'b0);

        // ADD Dn, (d8,An,Xn) — indexed memory dest: NOT tested here.
        // This path uses dyn_bit_ea_r pre-latch which requires at least one EX
        // cycle before mem_ack to capture the correct EA before dyn_bit_get_Dn
        // fires.  The 0-latency mem model (mem_ack=mem_req) in this testbench
        // violates that requirement.  Coverage provided by Harte ADD.l suite
        // (harte_tb.sv uses 1-cycle dsack latency → path works correctly).

        // SUB Dn, (xxx).W — new absolute-short memory destination in eu_seq.sv
        // opcode 0x93B8: SUB.L D1,(0x7200).W
        $display("--- SUB.L D1,(0x7200).W (Dn->mem abs.W dest) ---");
        set_dn(3'd1, 32'h0000_0100);
        ram[32'h7200 >> 2] = 32'h0000_1000;
        run_instr(16'h93B8, 1'b1, 32'h0000_7200);
        chk("SUB-absW:mem", ram[32'h7200 >> 2], 32'h0000_0F00);
        chk_ccr("SUB-absW", 1'b0, 1'b0, 1'b0, 1'b0);

        // ADD Dn, (xxx).L — new absolute-long memory destination in eu_seq.sv
        // opcode 0xDBB9: ADD.L D5,(0x7300).L
        $display("--- ADD.L D5,(0x7300).L (Dn->mem abs.L dest) ---");
        set_dn(3'd5, 32'h0000_0500);
        ram[32'h7300 >> 2] = 32'h0000_A000;
        run_instr(16'hDBB9, 1'b1, 32'h0000_7300);
        chk("ADD-absL:mem", ram[32'h7300 >> 2], 32'h0000_A500);
        chk_ccr("ADD-absL", 1'b0, 1'b0, 1'b0, 1'b0);

        // ADDQ to indexed EA — new f_mode=110 case in eu_seq.sv ADDQ decoder
        // opcode 0x56B4: ADDQ.L #3,(4,A4,D6.L); brief ext 0x6804 → EA=A4+D6+4
        $display("--- ADDQ.L #3,(4,A4,D6.L) (ADDQ indexed dest) ---");
        set_an(3'd4, 32'h0000_7400);
        set_dn(3'd6, 32'h0000_0008);
        ram[32'h740C >> 2] = 32'h0000_1000;
        run_instr(16'h56B4, 1'b1, 32'h0000_6804);
        chk("ADDQ-idx:mem", ram[32'h740C >> 2], 32'h0000_1003);
        chk_ccr("ADDQ-idx", 1'b0, 1'b0, 1'b0, 1'b0);

        // ─── summary ─────────────────────────────────────────────────────────
        repeat(4) @(posedge clk);
        $display("");
        if (fail_cnt == 0)
            $display("PASS all %0d checks", pass_cnt);
        else
            $display("FAIL %0d/%0d checks failed", fail_cnt, pass_cnt + fail_cnt);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

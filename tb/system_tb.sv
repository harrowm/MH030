// System control instruction tests
//
// MOVEC: read/write VBR, SFC, DFC, USP, CACR, ISP, MSP control registers
// MOVES: alternate function code load/store, all EA modes
// PMOVE: 64-bit CRP/SRP load and store (2-bus-cycle FSM)
// MOVE SR/CCR/USP: status register and USP access
// TRAP/TRAPV/ILLEGAL: software exception request signals
// STOP: halt until interrupt, cleared by exc_sr_wr_en
// RTE: pop SR+PC from stack, assert branch_taken
// JSR indexed EA: (d8,An,Dn.W) and (d8,PC,Dn.W)
// Trace T1/T0: eu_trace_req after every / flow-change instruction
// Privilege violation: supervisor-only instruction in user mode
// Line-A / Line-F: unimplemented opcode exception requests

`default_nettype none
`timescale 1ns/1ps

module system_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word  = 16'h0;
    logic        instr_valid = 0;
    logic [31:0] ext_data    = 32'h0;
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

    logic [31:0] decode_pc    = 32'h0;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req;
    logic        mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr;
    logic [31:0] mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
    logic        mem_berr    = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack   = 0;
    logic        eu_coproc_berr  = 0;
    logic [31:0] eu_coproc_rdata = 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack   = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack    = 0;
    logic [15:0] eu_ptest_mmusr  = 16'h0;

    logic [31:0] tc_out, tt0_out, tt1_out;
    logic [63:0] crp_out, srp_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

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

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x        (clk),
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
        .cacr_out      (cacr_out),
        .caar_out      (caar_out),
        .sr_out        (sr_out),
        .supervisor    (supervisor),
        .master_mode   (master_mode),
        .ipl_mask      (ipl_mask),
        .int_pending    (1'b0),
        .eu_int_ready   (),
        .exc_active     (1'b0),
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
        .mem_rmw       (mem_rmw),
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
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (combinatorial ack, 8K longwords) ──────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // Capture FC on last bus cycle (for MOVES FC verification)
    logic [2:0] last_mem_fc;
    always_ff @(posedge clk)
        if (mem_req) last_mem_fc <= mem_fc;

    // Counters for edge-triggered signals
    int branch_cnt;
    logic [31:0] branch_target_last;
    int trace_req_cnt;
    int priv_req_cnt;
    int linea_req_cnt;
    int linef_req_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            branch_cnt         <= 0;
            branch_target_last <= 32'h0;
            trace_req_cnt      <= 0;
            priv_req_cnt       <= 0;
            linea_req_cnt      <= 0;
            linef_req_cnt      <= 0;
        end else begin
            if (branch_taken) begin
                branch_cnt         <= branch_cnt + 1;
                branch_target_last <= branch_target;
            end
            if (eu_trace_req) trace_req_cnt <= trace_req_cnt + 1;
            if (eu_priv_req)  priv_req_cnt  <= priv_req_cnt  + 1;
            if (eu_linea_req) linea_req_cnt <= linea_req_cnt + 1;
            if (eu_linef_req) linef_req_cnt <= linef_req_cnt + 1;
        end
    end

    // ─── Helpers ─────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0b exp %0b", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk3(input string tag, input logic [2:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0h exp %0h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic chk64(input string tag, input logic [63:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %016h exp %016h", tag, got, exp);
            fail_cnt++;
        end else
            pass_cnt++;
    endtask

    task automatic run_instr(input logic [15:0] iw,
                             input logic        has_ext,
                             input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(16) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    task automatic set_isp(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk); #1;
        ssp_wr_en = 0;
        @(posedge clk); #1;
    endtask

    task automatic set_sr(input logic [15:0] val);
        @(posedge clk); #1;
        exc_sr_wr_data = val; exc_sr_wr_en = 1;
        @(posedge clk); #1;
        exc_sr_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // MOVEC Rn,Rc: write general register to control register
    task automatic movec_rn_rc(input logic da, input logic [2:0] rn,
                               input logic [11:0] rc);
        run_instr(16'h4E7B, 1'b1, {16'h0, da, rn, rc});
    endtask

    // MOVEC Rc,Rn: read control register into general register
    task automatic movec_rc_rn(input logic da, input logic [2:0] rn,
                               input logic [11:0] rc);
        run_instr(16'h4E7A, 1'b1, {16'h0, da, rn, rc});
    endtask

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        int base_branch, base_trace, base_priv, base_linea, base_linef;

        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // ====================================================================
        // MOVEC: write and read back control registers
        // ====================================================================
        $display("--- MOVEC-01: VBR write/read ---");
        set_dn(0, 32'hDEAD_C0DE);
        movec_rn_rc(1'b0, 3'b000, 12'h801);    // MOVEC D0,VBR
        chk("MOVEC-01:vbr_r",   dut.u_rf.vbr_r, 32'hDEAD_C0DE);
        chk("MOVEC-01:vbr_out", vbr_out,         32'hDEAD_C0DE);
        movec_rc_rn(1'b0, 3'b001, 12'h801);    // MOVEC VBR,D1
        chk("MOVEC-01:D1",      dut.u_rf.d_reg[1], 32'hDEAD_C0DE);

        $display("--- MOVEC-02: SFC write/read ---");
        set_dn(0, 32'h0000_0005);               // supervisor data space
        movec_rn_rc(1'b0, 3'b000, 12'h000);    // MOVEC D0,SFC
        chk3("MOVEC-02:sfc_r", dut.u_rf.sfc_r, 3'b101);
        movec_rc_rn(1'b0, 3'b010, 12'h000);    // MOVEC SFC,D2
        chk("MOVEC-02:D2",     dut.u_rf.d_reg[2], 32'h0000_0005);

        $display("--- MOVEC-03: DFC write/read ---");
        set_dn(0, 32'h0000_0001);               // user data space
        movec_rn_rc(1'b0, 3'b000, 12'h001);    // MOVEC D0,DFC
        chk3("MOVEC-03:dfc_r", dut.u_rf.dfc_r, 3'b001);
        movec_rc_rn(1'b0, 3'b011, 12'h001);    // MOVEC DFC,D3
        chk("MOVEC-03:D3",     dut.u_rf.d_reg[3], 32'h0000_0001);

        $display("--- MOVEC-04: USP write/read ---");
        set_an(3'h0, 32'hA000_1234);
        movec_rn_rc(1'b1, 3'b000, 12'h800);    // MOVEC A0,USP
        chk("MOVEC-04:usp_r",   dut.u_rf.usp_r, 32'hA000_1234);
        chk("MOVEC-04:usp_out", usp_out,         32'hA000_1234);
        movec_rc_rn(1'b1, 3'b001, 12'h800);    // MOVEC USP,A1
        chk("MOVEC-04:A1",      dut.u_rf.a_reg[1], 32'hA000_1234);

        $display("--- MOVEC-05: CACR write/read ---");
        set_dn(0, 32'h0000_0101);               // I-cache + D-cache enable
        movec_rn_rc(1'b0, 3'b000, 12'h002);    // MOVEC D0,CACR
        chk("MOVEC-05:cacr_r",   dut.u_rf.cacr_r, 32'h0000_0101);
        chk("MOVEC-05:cacr_out", cacr_out,         32'h0000_0101);
        movec_rc_rn(1'b0, 3'b100, 12'h002);    // MOVEC CACR,D4
        chk("MOVEC-05:D4",       dut.u_rf.d_reg[4], 32'h0000_0101);

        $display("--- MOVEC-06: ISP write/read ---");
        set_an(3'h0, 32'hB000_5678);
        movec_rn_rc(1'b1, 3'b000, 12'h804);    // MOVEC A0,ISP
        chk("MOVEC-06:isp_r",  dut.u_rf.isp_r, 32'hB000_5678);
        movec_rc_rn(1'b1, 3'b010, 12'h804);    // MOVEC ISP,A2
        chk("MOVEC-06:A2",     dut.u_rf.a_reg[2], 32'hB000_5678);

        $display("--- MOVEC-07: MSP write/read ---");
        set_dn(0, 32'hC000_9ABC);
        movec_rn_rc(1'b0, 3'b000, 12'h803);    // MOVEC D0,MSP
        chk("MOVEC-07:msp_r",  dut.u_rf.msp_r, 32'hC000_9ABC);
        movec_rc_rn(1'b1, 3'b100, 12'h803);    // MOVEC MSP,A4
        chk("MOVEC-07:A4",     dut.u_rf.a_reg[4], 32'hC000_9ABC);

        // ====================================================================
        // MOVES: alternate function code load/store, basic EA modes
        // ====================================================================
        // Set SFC=1 (user data) for MOVES loads
        set_dn(0, 32'h0000_0001);
        movec_rn_rc(1'b0, 3'b000, 12'h000);    // MOVEC D0,SFC=1

        $display("--- MOVES-01: MOVES.L (A3),D0 load using SFC ---");
        set_an(3'h3, 32'h0000_0100);
        ram[32'h100>>2] = 32'hCAFE_BABE;
        // MOVES.L (A3),D0: opcode 0x0E93, ext: D/A=0,Rn=D0=000,dir=1(load) = 0x0800
        run_instr(16'h0E93, 1'b1, 32'h0000_0800);
        chk("MOVES-01:D0",  dut.u_rf.d_reg[0], 32'hCAFE_BABE);
        chk3("MOVES-01:FC", last_mem_fc, 3'b001);

        $display("--- MOVES-02: MOVES.L D1,(A3) store using DFC ---");
        set_dn(1, 32'h1122_3344);
        // MOVES.L D1,(A3): opcode 0x0E93, ext: D/A=0,Rn=D1=001,dir=0(store) = 0x1000
        run_instr(16'h0E93, 1'b1, 32'h0000_1000);
        chk("MOVES-02:mem", ram[32'h100>>2], 32'h1122_3344);
        chk3("MOVES-02:FC", last_mem_fc, 3'b001);

        $display("--- MOVES-03: MOVES.L (A3)+,D2 post-increment load ---");
        set_an(3'h3, 32'h0000_0100);
        ram[32'h100>>2] = 32'hFEED_F00D;
        // MOVES.L (A3)+,D2: opcode 0x0E9B (mode=011 post-inc, reg=011=A3)
        //   ext: D/A=0, Rn=D2=010, dir=1(load) = 0x2800
        run_instr(16'h0E9B, 1'b1, 32'h0000_2800);
        chk("MOVES-03:D2",  dut.u_rf.d_reg[2], 32'hFEED_F00D);
        chk("MOVES-03:A3",  dut.u_rf.a_reg[3], 32'h0000_0104);
        chk3("MOVES-03:FC", last_mem_fc, 3'b001);

        // ====================================================================
        // MOVES full EA modes
        // ====================================================================
        $display("--- MOVES-04: MOVES.L (d16,A0),D1 load ---");
        set_an(3'd0, 32'h0000_0100);
        ram[32'h110>>2] = 32'hDEAD_BEEF;
        // MOVES.L (d16,A0): opcode 0x0EA8, ext: {desc=0x1800(D1,load), d16=0x0010}
        run_instr(16'h0EA8, 1'b1, 32'h1800_0010);
        repeat(3) @(posedge clk);
        chk("MOVES-04:D1", dut.u_rf.d_reg[1], 32'hDEAD_BEEF);

        $display("--- MOVES-05: MOVES.L D1,(d16,A0) store ---");
        // ext: {desc=0x1000(D1,store), d16=0x0020} → EA=0x120
        run_instr(16'h0EA8, 1'b1, 32'h1000_0020);
        chk("MOVES-05:mem", ram[32'h120>>2], 32'hDEAD_BEEF);

        $display("--- MOVES-06: MOVES.W (d8,A1,D2.L),D3 load ---");
        set_an(3'd1, 32'h0000_0200);
        set_dn(2, 32'h0000_0020);
        ram[32'h224>>2] = 32'h0000_ABCD;   // word at byte 0x224; EU reads [15:0]=0xABCD
        // MOVES.W (d8,A1,D2.L): opcode 0x0E71, ext: {desc=0x3800(D3,load), brief=0x2804}
        //   brief: DA=0,Xn=D2=010,WL=1(long),scale=00,d8=4 → 0x2804
        run_instr(16'h0E71, 1'b1, 32'h3800_2804);
        repeat(3) @(posedge clk);
        chk("MOVES-06:D3", dut.u_rf.d_reg[3], 32'h0000_ABCD);

        $display("--- MOVES-07: MOVES.B (xxx).W,D4 load ---");
        set_dn(4, 32'h0);                           // clear D4 (MOVES.B only updates [7:0])
        ram[32'h300>>2] = 32'h0000_00AB;   // byte at 0x300; EU reads [7:0]=0xAB
        // MOVES.B (xxx).W: opcode 0x0E38, ext: {desc=0x4800(D4,load), abs.W=0x0300}
        run_instr(16'h0E38, 1'b1, 32'h4800_0300);
        repeat(3) @(posedge clk);
        chk("MOVES-07:D4", dut.u_rf.d_reg[4], 32'h0000_00AB);

        $display("--- MOVES-08: MOVES.W D5,(xxx).W store ---");
        set_dn(5, 32'h0000_CAFE);
        // MOVES.W (xxx).W: opcode 0x0E78, ext: {desc=0x5000(D5,store), abs.W=0x0400}
        // EU writes word in mem_wdata[31:16]; raw RAM stores 0xCAFE_0000
        run_instr(16'h0E78, 1'b1, 32'h5000_0400);
        chk("MOVES-08:mem", ram[32'h400>>2], 32'hCAFE_0000);

        // ====================================================================
        // PMOVE: 64-bit CRP/SRP load and store (2 bus cycles each)
        // ====================================================================
        $display("--- PMOVE-01: PMOVE (A0),CRP load ---");
        set_an(3'd0, 32'h0000_1000);
        ram[32'h1000>>2] = 32'hDEAD_CAFE;
        ram[32'h1004>>2] = 32'hBEEF_1234;
        // F010: PMOVE (A0); ext: ext[15:13]=010=PMOVE, ext[11:9]=100=CRP, ext[8]=0(EA→reg)
        run_instr(16'hF010, 1'b1, 32'h0000_4800);
        chk64("PMOVE-01:crp", crp_out, 64'hDEAD_CAFE_BEEF_1234);

        $display("--- PMOVE-02: PMOVE CRP,(A0) write ---");
        ram[32'h1000>>2] = 32'h0;
        ram[32'h1004>>2] = 32'h0;
        // ext[8]=1 → reg→EA
        run_instr(16'hF010, 1'b1, 32'h0000_4900);
        chk("PMOVE-02:crp_hi", ram[32'h1000>>2], 32'hDEAD_CAFE);
        chk("PMOVE-02:crp_lo", ram[32'h1004>>2], 32'hBEEF_1234);

        $display("--- PMOVE-03: PMOVE (A0),SRP load ---");
        ram[32'h1000>>2] = 32'h1111_2222;
        ram[32'h1004>>2] = 32'h3333_4444;
        // ext[11:9]=110=SRP, ext[8]=0
        run_instr(16'hF010, 1'b1, 32'h0000_4C00);
        chk64("PMOVE-03:srp", srp_out, 64'h1111_2222_3333_4444);

        $display("--- PMOVE-04: PMOVE SRP,(A0) write ---");
        ram[32'h1000>>2] = 32'h0;
        ram[32'h1004>>2] = 32'h0;
        run_instr(16'hF010, 1'b1, 32'h0000_4D00);
        chk("PMOVE-04:srp_hi", ram[32'h1000>>2], 32'h1111_2222);
        chk("PMOVE-04:srp_lo", ram[32'h1004>>2], 32'h3333_4444);

        // ====================================================================
        // MOVE SR/CCR/USP: status register access
        // Clear CCR first so P56-style checks see clean SR=0x2700
        // ====================================================================
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);  // ANDI #0xE0,CCR — clear N,Z,V,C,X

        $display("--- MOVE_SR-01: MOVE SR,D0 ---");
        run_instr(16'h40C0, 1'b0, 32'h0);          // MOVE SR,D0
        repeat(4) @(posedge clk);
        chk("MOVE_SR-01:D0", dut.u_rf.d_reg[0], 32'h0000_2700);

        $display("--- MOVE_SR-02: MOVE CCR,D1 ---");
        set_dn(1, 32'h0);                           // clear D1 (sets Z=1 in CCR as side effect)
        run_instr(16'h023C, 1'b1, 32'h0000_00E0);  // ANDI #0xE0,CCR → re-clear CCR to 0x00
        run_instr(16'h42C1, 1'b0, 32'h0);          // MOVE CCR,D1
        repeat(4) @(posedge clk);
        chk("MOVE_SR-02:D1", dut.u_rf.d_reg[1], 32'h0000_0000);

        $display("--- MOVE_SR-03: MOVE D2,CCR ---");
        set_dn(2, 32'h0000_001F);
        run_instr(16'h44C2, 1'b0, 32'h0);          // MOVE D2,CCR (CCR=0x1F)
        repeat(4) @(posedge clk);
        chk("MOVE_SR-03:sr", {16'h0, sr_out}, 32'h0000_271F);

        $display("--- MOVE_SR-04: MOVE D3,SR round-trip ---");
        run_instr(16'h40C3, 1'b0, 32'h0);          // MOVE SR,D3
        repeat(4) @(posedge clk);
        chk("MOVE_SR-04a:D3", dut.u_rf.d_reg[3], 32'h0000_271F);
        run_instr(16'h46C3, 1'b0, 32'h0);          // MOVE D3,SR
        repeat(4) @(posedge clk);
        chk("MOVE_SR-04b:sr", {16'h0, sr_out}, 32'h0000_271F);

        $display("--- MOVE_SR-05: MOVE An,USP / MOVE USP,An ---");
        set_an(3'd1, 32'h0000_1234);
        run_instr(16'h4E61, 1'b0, 32'h0);          // MOVE A1,USP
        repeat(4) @(posedge clk);
        chk("MOVE_SR-05a:USP", usp_out, 32'h0000_1234);
        run_instr(16'h4E6A, 1'b0, 32'h0);          // MOVE USP,A2
        repeat(4) @(posedge clk);
        chk("MOVE_SR-05b:A2",  dut.u_rf.a_reg[2], 32'h0000_1234);

        // ====================================================================
        // TRAP #5: eu_trap_req fires with eu_trap_num=5
        // ====================================================================
        $display("--- TRAP-01: TRAP #5 ---");
        begin
            logic saw_trap; logic [3:0] saw_num;
            saw_trap = 0; saw_num = 4'hF;
            @(posedge clk); #1;
            instr_word = 16'h4E45; instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_trap_req) begin saw_trap = 1; saw_num = eu_trap_num; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("TRAP-01:req", saw_trap, 1'b1);
            chk("TRAP-01:num", {28'h0, saw_num}, 32'h5);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // TRAPV: fires when V=1, silent when V=0
        // ====================================================================
        $display("--- TRAPV-01: TRAPV with V=1 ---");
        // Set V=1 explicitly (set_an/set_dn helpers modify CCR)
        set_dn(5, 32'h0000_0002);
        run_instr(16'h44C5, 1'b0, 32'h0);          // MOVE D5,CCR → CCR=0x02 (V=1)
        begin
            logic saw_trapv;
            saw_trapv = 0;
            @(posedge clk); #1;
            instr_word = 16'h4E76; instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_trapv_req) begin saw_trapv = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("TRAPV-01:fires", saw_trapv, 1'b1);
            repeat(4) @(posedge clk);
        end

        $display("--- TRAPV-02: TRAPV with V=0 (silent) ---");
        set_dn(4, 32'h0);
        run_instr(16'h44C4, 1'b0, 32'h0);     // MOVE D4,CCR (CCR=0, V=0)
        repeat(2) @(posedge clk);
        chk1("TRAPV-02:V_clear", sr_out[1], 1'b0);
        begin
            logic saw_trapv;
            saw_trapv = 0;
            @(posedge clk); #1;
            instr_word = 16'h4E76; instr_valid = 1'b1;
            repeat(30) begin
                @(posedge clk);
                if (eu_trapv_req) begin saw_trapv = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("TRAPV-02:silent", saw_trapv, 1'b0);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // ILLEGAL: eu_illegal_req fires
        // ====================================================================
        $display("--- ILLEGAL-01: ILLEGAL instruction ---");
        begin
            logic saw_illegal;
            saw_illegal = 0;
            @(posedge clk); #1;
            instr_word = 16'h4AFC; instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_illegal_req) begin saw_illegal = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("ILLEGAL-01:req", saw_illegal, 1'b1);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // STOP: eu_stop asserts, clears when exc_sr_wr_en pulses
        // ====================================================================
        $display("--- STOP-01/02: STOP then clear ---");
        begin
            logic saw_stop;
            saw_stop = 0;
            @(posedge clk); #1;
            instr_word = 16'h4E72; instr_valid = 1'b1;
            ext_data = 32'h0000_2700; ext_valid = 1'b1;
            repeat(200) begin
                @(posedge clk);
                if (eu_stop) begin saw_stop = 1; break; end
                if (instr_ack) begin instr_valid = 1'b0; ext_valid = 1'b0; end
            end
            instr_valid = 1'b0; ext_valid = 1'b0;
            chk1("STOP-01:assert", saw_stop, 1'b1);
            repeat(4) @(posedge clk);
            exc_sr_wr_en = 1'b1;
            exc_sr_wr_data = 16'h2700;
            @(posedge clk);
            exc_sr_wr_en = 1'b0; exc_sr_wr_data = 16'h0;
            repeat(4) @(posedge clk);
            chk1("STOP-02:clear", eu_stop, 1'b0);
        end

        // ====================================================================
        // RTE: pops SR+PC from stack, asserts branch_taken
        // Pre-load stack frame at SSP=0x1000 (Format $0: SR then PC)
        // ====================================================================
        $display("--- RTE-01/02/03: RTE reads stack frame ---");
        begin
            logic saw_branch; logic [31:0] rte_pc; logic [15:0] rte_sr;
            saw_branch = 0; rte_pc = 32'h0; rte_sr = 16'h0;
            ssp_wr_en = 1'b1; ssp_wr_data = 32'h0000_1000;
            @(posedge clk); ssp_wr_en = 1'b0;
            repeat(2) @(posedge clk);
            ram[32'h1000>>2] = 32'h0000_2700;   // SR at SSP
            ram[32'h1004>>2] = 32'h0000_2000;   // PC at SSP+4
            @(posedge clk); #1;
            instr_word = 16'h4E73; instr_valid = 1'b1;
            repeat(300) begin
                @(posedge clk);
                if (instr_ack) instr_valid = 1'b0;
                if (branch_taken) begin
                    saw_branch = 1; rte_pc = branch_target; break;
                end
            end
            instr_valid = 1'b0;
            repeat(4) @(posedge clk);
            rte_sr = sr_out;
            chk1("RTE-01:branch", saw_branch, 1'b1);
            chk("RTE-02:target",  rte_pc,           32'h0000_2000);
            chk("RTE-03:sr",      {16'h0, rte_sr},  32'h0000_2700);
        end

        // ====================================================================
        // JSR indexed EA: push return PC, jump to computed address
        // ====================================================================
        $display("--- JSR-01: JSR (d8,A0,D1.W) ---");
        set_an(3'h0, 32'h0000_3000);
        set_dn(1, 32'h0000_0020);
        set_isp(32'h0000_1000);
        decode_pc   = 32'h0000_5000;
        base_branch = branch_cnt;
        // JSR (d8,A0,D1.W): opcode 0x4EB0, brief ext 0x1008 (D1.W, d8=+8)
        // Target = 0x3000 + 0x08 + 0x20 = 0x3028; return PC = 0x5004
        run_instr(16'h4EB0, 1'b1, 32'h0000_1008);
        decode_pc = 32'h0;
        chk("JSR-01:push",   ram[32'h0FFC>>2],    32'h0000_5004);
        chk("JSR-01:isp",    isp_out,              32'h0000_0FFC);
        chk("JSR-01:target", branch_target_last,   32'h0000_3028);
        chk("JSR-01:taken",  branch_cnt - base_branch, 32'd1);

        $display("--- JSR-02: JSR (d8,PC,D2.W) ---");
        set_dn(2, 32'h0000_0040);
        set_isp(32'h0000_1000);
        decode_pc   = 32'h0000_6000;
        base_branch = branch_cnt;
        // JSR (d8,PC,D2.W): opcode 0x4EBB, brief ext 0x2010 (D2.W, d8=0x10)
        // Target = (0x6000+2+0x10) + 0x40 = 0x6052; return PC = 0x6004
        run_instr(16'h4EBB, 1'b1, 32'h0000_2010);
        decode_pc = 32'h0;
        chk("JSR-02:push",   ram[32'h0FFC>>2],    32'h0000_6004);
        chk("JSR-02:isp",    isp_out,              32'h0000_0FFC);
        chk("JSR-02:target", branch_target_last,   32'h0000_6052);
        chk("JSR-02:taken",  branch_cnt - base_branch, 32'd1);

        // ====================================================================
        // Trace T1: eu_trace_req fires after every instruction
        // ====================================================================
        $display("--- TRACE-01: T1 fires after NOP ---");
        set_sr(16'hA700);                           // T1=1, S=1, IPL=7
        base_trace = trace_req_cnt;
        run_instr(16'h4E71, 1'b0, 32'h0);          // NOP
        chk("TRACE-01:count", trace_req_cnt - base_trace, 32'd1);
        set_sr(16'h2700);

        // ====================================================================
        // Trace T0: fires only after flow-change instructions
        // ====================================================================
        $display("--- TRACE-02: T0 does not fire after NOP ---");
        set_sr(16'h6700);                           // T0=1, S=1, IPL=7
        base_trace = trace_req_cnt;
        run_instr(16'h4E71, 1'b0, 32'h0);          // NOP — not flow-change
        chk("TRACE-02:no_trace", trace_req_cnt - base_trace, 32'd0);

        $display("--- TRACE-03: T0 fires after JMP (A0) ---");
        set_an(3'h0, 32'h0000_7000);               // A0 for JMP target
        base_trace = trace_req_cnt;
        run_instr(16'h4ED0, 1'b0, 32'h0);          // JMP (A0) — flow-change
        chk("TRACE-03:trace", trace_req_cnt - base_trace, 32'd1);
        set_sr(16'h2700);

        // ====================================================================
        // Privilege violation: supervisor instruction in user mode
        // ====================================================================
        $display("--- PRIV-01: STOP in user mode ---");
        set_sr(16'h0000);                           // S=0 (user mode)
        base_priv = priv_req_cnt;
        run_instr(16'h4E72, 1'b0, 32'h0);          // STOP — privilege violation
        chk("PRIV-01:fired", priv_req_cnt - base_priv, 32'd1);
        set_sr(16'h2700);                           // restore supervisor

        // ====================================================================
        // Line-A / Line-F unimplemented opcodes
        // ====================================================================
        $display("--- LINEA-01: 0xA000 ---");
        base_linea = linea_req_cnt;
        run_instr(16'hA000, 1'b0, 32'h0);
        chk("LINEA-01:fired", linea_req_cnt - base_linea, 32'd1);

        $display("--- LINEF-01: 0xF400 non-FPU/MMU ---");
        base_linef = linef_req_cnt;
        run_instr(16'hF400, 1'b0, 32'h0);
        chk("LINEF-01:fired", linef_req_cnt - base_linef, 32'd1);

        // ─── Report ──────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("PASS: %0d checks passed", pass_cnt);
        else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

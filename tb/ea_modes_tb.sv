`default_nettype none
`timescale 1ns/1ps

// Addressing-mode testbench
// Covers: (An)/(An)+/-(An)/(d16,An); abs.W/abs.L; (d8,An,Xn); (d16,PC)/(d8,PC,Xn);
//         memory-indirect ([bd,An],Xn,od)

`define DR(n)  dut.u_rf.d_reg[n]
`define AR(n)  dut.u_rf.a_reg[n]

module ea_modes_tb;

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
    logic [31:0] crp_out, srp_out;
    logic [15:0] sr_out;
    logic        supervisor, master_mode;
    logic [2:0]  ipl_mask;
    logic [31:0] decode_pc = 32'h0000_1000;
    logic        branch_taken;
    logic [31:0] branch_target;

    logic        mem_req, mem_rw;
    logic [1:0]  mem_siz;
    logic [2:0]  mem_fc;
    logic [31:0] mem_addr, mem_wdata;
    logic [31:0] mem_rdata;
    logic        mem_ack;
    logic        mem_berr  = 0;
    logic        mem_rmw;

    logic        eu_coproc_req, eu_coproc_rw;
    logic [1:0]  eu_coproc_siz;
    logic [2:0]  eu_coproc_fc;
    logic [31:0] eu_coproc_addr, eu_coproc_wdata;
    logic        eu_coproc_ack  = 0;
    logic        eu_coproc_berr = 0;
    logic [31:0] eu_coproc_rdata= 32'h0;

    logic        eu_pflush_req, eu_pflush_all;
    logic [2:0]  eu_pflush_fc;
    logic [31:0] eu_pflush_va;
    logic        eu_pflush_ack = 0;
    logic        eu_ptest_req;
    logic [31:0] eu_ptest_va;
    logic [2:0]  eu_ptest_fc;
    logic        eu_ptest_ack   = 0;
    logic [15:0] eu_ptest_mmusr = 16'h0;
    logic [31:0] tc_out, tt0_out, tt1_out;

    logic        an_wr_en;
    logic [2:0]  an_wr_sel;
    logic [31:0] an_wr_data;

    logic        div_trap, chk_trap;
    logic        eu_trap_req, eu_trapv_req, eu_illegal_req, eu_stop, eu_reset_req;
    logic [3:0]  eu_trap_num;
    logic        eu_priv_req, eu_trace_req, eu_linea_req, eu_linef_req, eu_fmt_err_req;

    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x         (clk),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
        .q3_word        (16'h0),
        .ext34_data     (32'h0),
        .ext_valid      (ext_valid),
        .instr_ack      (instr_ack),
        .eu_busy        (eu_busy),
        .pc_wr_en       (pc_wr_en),
        .pc_wr_data     (pc_wr_data),
        .pc_out         (pc_out),
        .vbr_wr_en      (vbr_wr_en),
        .vbr_wr_data    (vbr_wr_data),
        .vbr_out        (vbr_out),
        .usp_out        (usp_out),
        .msp_out        (msp_out),
        .isp_out        (isp_out),
        .cacr_out       (cacr_out),
        .caar_out       (caar_out),
        .sr_out         (sr_out),
        .supervisor     (supervisor),
        .master_mode    (master_mode),
        .ipl_mask       (ipl_mask),
        .int_pending    (1'b0),
        .eu_int_ready   (),
        .exc_active     (1'b0),
        .decode_pc      (decode_pc),
        .branch_taken   (branch_taken),
        .branch_target  (branch_target),
        .mem_req        (mem_req),
        .mem_rw         (mem_rw),
        .mem_siz        (mem_siz),
        .mem_fc         (mem_fc),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_rdata      (mem_rdata),
        .mem_ack        (mem_ack),
        .mem_berr       (mem_berr),
        .mem_rmw        (mem_rmw),
        .eu_coproc_req  (eu_coproc_req),
        .eu_coproc_rw   (eu_coproc_rw),
        .eu_coproc_siz  (eu_coproc_siz),
        .eu_coproc_fc   (eu_coproc_fc),
        .eu_coproc_addr (eu_coproc_addr),
        .eu_coproc_wdata(eu_coproc_wdata),
        .eu_coproc_rdata(eu_coproc_rdata),
        .eu_coproc_ack  (eu_coproc_ack),
        .eu_coproc_berr (eu_coproc_berr),
        .eu_pflush_req  (eu_pflush_req),
        .eu_pflush_all  (eu_pflush_all),
        .eu_pflush_fc   (eu_pflush_fc),
        .eu_pflush_va   (eu_pflush_va),
        .eu_pflush_ack  (eu_pflush_ack),
        .eu_ptest_req   (eu_ptest_req),
        .eu_ptest_va    (eu_ptest_va),
        .eu_ptest_fc    (eu_ptest_fc),
        .eu_ptest_ack   (eu_ptest_ack),
        .eu_ptest_mmusr (eu_ptest_mmusr),
        .tc_out         (tc_out),
        .tt0_out        (tt0_out),
        .tt1_out        (tt1_out),
        .crp_out        (crp_out),
        .srp_out        (srp_out),
        .an_wr_en       (an_wr_en),
        .an_wr_sel      (an_wr_sel),
        .an_wr_data     (an_wr_data),
        .div_trap       (div_trap),
        .chk_trap       (chk_trap),
        .eu_trap_req    (eu_trap_req),
        .eu_trap_num    (eu_trap_num),
        .eu_trapv_req   (eu_trapv_req),
        .eu_illegal_req (eu_illegal_req),
        .eu_stop        (eu_stop),
        .eu_reset_req   (eu_reset_req),
        .eu_priv_req    (eu_priv_req),
        .eu_trace_req   (eu_trace_req),
        .eu_linea_req   (eu_linea_req),
        .eu_linef_req   (eu_linef_req),
        .eu_fmt_err_req (eu_fmt_err_req),
        .ssp_wr_en      (ssp_wr_en),
        .ssp_wr_data    (ssp_wr_data),
        .exc_sr_wr_en   (exc_sr_wr_en),
        .exc_sr_wr_data (exc_sr_wr_data)
    );

    // ─── Memory model ─────────────────────────────────────────────────────────
    // Formula mode (mem_use_formula=1): reads return mem_addr|0xA0000001.
    // RAM mode (default): 512-entry 32-bit array addressed by [11:2].
    logic [31:0] ram [0:511];
    logic        mem_use_formula = 0;

    // Write-capture registers for seq37 write verification
    logic [31:0] wr_cap_addr = 0;
    logic [31:0] wr_cap_data = 0;

    // Last-transaction registers for seq37 bus-signal checks
    logic [31:0] last_mem_addr = 0;
    logic [2:0]  last_mem_fc   = 0;
    logic        last_mem_rw   = 0;
    logic        last_mem_seen = 0;

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw)
                       ? (mem_use_formula ? (mem_addr | 32'hA000_0001)
                                          : ram[mem_addr[11:2]])
                       : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req) begin
            last_mem_addr <= mem_addr;
            last_mem_fc   <= mem_fc;
            last_mem_rw   <= mem_rw;
            last_mem_seen <= 1'b1;
            if (!mem_rw) begin
                wr_cap_addr <= mem_addr;
                wr_cap_data <= mem_wdata;
                if (!mem_use_formula) ram[mem_addr[11:2]] <= mem_wdata;
            end
        end else
            last_mem_seen <= 1'b0;
    end

    // Memory read history log for post-hoc address verification.
    // Populated by a background process so tasks can look back after run_instr.
    logic [31:0] mem_log_addr [0:63];
    int          mem_log_wp    = 0;    // write pointer (wraps mod 64)
    int          mem_log_start = 0;    // snapshot taken at start of each run_instr

    initial fork
        forever begin
            @(posedge clk);
            if (mem_req && mem_rw) begin
                mem_log_addr[mem_log_wp % 64] = mem_addr;
                mem_log_wp = mem_log_wp + 1;
            end
        end
    join_none

    // Branch latch — saw_branch/last_target settle after drain cycles.
    logic        saw_branch;
    logic [31:0] last_target;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_branch  <= 1'b0;
            last_target <= 32'h0;
        end else if (branch_taken) begin
            saw_branch  <= 1'b1;
            last_target <= branch_target;
        end
    end

    // ─── Test helpers ─────────────────────────────────────────────────────────
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

    // Present instruction, poll for ack, drain 5 cycles for WB settle.
    task automatic run_instr(input logic [15:0] w0,
                              input logic        has_ext,
                              input logic [31:0] ext);
        @(posedge clk);
        mem_log_start = mem_log_wp;   // snapshot log before instruction
        instr_word  = w0;
        instr_valid = 1'b1;
        ext_data    = ext;
        ext_valid   = has_ext;
        saw_branch  = 1'b0;
        repeat(200) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        // Cycle-accuracy-closing plan.md, item 3: widened from 5 to cover
        // LEA (An),An's own new +4-tick artificial-stall entry (eu_seq.sv's
        // dec_internal_stall_ticks_fixed) -- this fixed post-ack margin
        // predates that stall and was too tight for it, caught by the
        // "basic-EA LEA(An) A3" check reading a stale (still-zero) A3.
        repeat(10) @(posedge clk);
    endtask

    // Load Dn: CLR.L Dn + ADDI.L #val,Dn
    task automatic set_dn(input logic [2:0] n, input logic [31:0] val);
        run_instr(16'h4280 | {13'h0, n}, 1'b0, 32'h0);
        run_instr(16'h0680 | {13'h0, n}, 1'b1, val);
    endtask

    // Load An via D0: CLR.L D0 + ADDI.L #val,D0 + MOVEA.L D0,An
    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        run_instr(16'h4280, 1'b0, 32'h0);
        run_instr(16'h0680, 1'b1, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // Set ISP (supervisor A7) directly via port
    task automatic set_isp(input logic [31:0] val);
        @(posedge clk); #1;
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk); #1;
        ssp_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // Poll for a read at exp_addr. Searches the history log first (for accesses
    // that happened during run_instr), then polls forward for max_cyc cycles.
    task automatic wait_mem_at(input  logic [31:0] exp_addr,
                                input  int          max_cyc,
                                output logic        found);
        found = 0;
        for (int i = mem_log_start; i < mem_log_wp; i++)
            if (mem_log_addr[i % 64] === exp_addr) begin found = 1; break; end
        if (!found) for (int t = 0; t < max_cyc; t++) begin
            @(posedge clk);
            if (mem_req && mem_rw && mem_addr === exp_addr) begin found = 1; break; end
        end
    endtask

    task drain; repeat(5) @(posedge clk); endtask

    // ─── Instruction encodings ─────────────────────────────────────────────────
    // seq37 / seq40 / seq41 shared
    localparam [15:0]
        MOVEA_D0_A0 = 16'h2040,
        MOVEA_D0_A1 = 16'h2240,
        MOVEA_D0_A2 = 16'h2440,
        MOVEA_D0_A3 = 16'h2640,
        MOVEA_D0_A4 = 16'h2840;

    // seq37: basic EA opcodes
    localparam [15:0]
        MOVE_L_iA0_D1   = 16'h2210,
        MOVE_L_A0inc_D2 = 16'h2418,
        MOVE_L_A1dec_D3 = 16'h2621,
        MOVE_L_d16A0_D4 = 16'h2828,
        MOVEA_L_iA0_A2  = 16'h2450,
        LEA_iA0_A3      = 16'h47D0,
        LEA_d16A0_A3    = 16'h47E8,
        LEA_d16A0_A4    = 16'h49E8,
        MOVE_L_D5_iA0   = 16'h2085,
        MOVE_L_D5_A0inc = 16'h20C5,
        MOVE_L_D5_A1dec = 16'h2305,
        MOVE_L_D5_d16A0 = 16'h2145;

    // seq40: absolute EA functions
    function automatic [15:0] MOVE_L_DN_ABS_W(input logic [2:0] dn);
        MOVE_L_DN_ABS_W = {4'h2, 3'b000, 3'b111, 3'b000, dn};
    endfunction
    function automatic [15:0] MOVE_L_DN_ABS_L(input logic [2:0] dn);
        MOVE_L_DN_ABS_L = {4'h2, 3'b001, 3'b111, 3'b000, dn};
    endfunction
    function automatic [15:0] MOVE_L_ABS_W_DN(input logic [2:0] dn);
        MOVE_L_ABS_W_DN = {4'h2, dn, 3'b000, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] MOVE_L_ABS_L_DN(input logic [2:0] dn);
        MOVE_L_ABS_L_DN = {4'h2, dn, 3'b000, 3'b111, 3'b001};
    endfunction
    function automatic [15:0] MOVEA_L_ABS_W_AN(input logic [2:0] an);
        MOVEA_L_ABS_W_AN = {4'h2, an, 3'b001, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] MOVEA_L_ABS_L_AN(input logic [2:0] an);
        MOVEA_L_ABS_L_AN = {4'h2, an, 3'b001, 3'b111, 3'b001};
    endfunction
    function automatic [15:0] LEA_ABS_W_AN(input logic [2:0] an);
        LEA_ABS_W_AN = {4'h4, an, 3'b111, 3'b111, 3'b000};
    endfunction
    function automatic [15:0] LEA_ABS_L_AN(input logic [2:0] an);
        LEA_ABS_L_AN = {4'h4, an, 3'b111, 3'b111, 3'b001};
    endfunction
    localparam [15:0] JMP_ABS_W = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b000};
    localparam [15:0] JMP_ABS_L = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b001};
    localparam [15:0] JSR_ABS_W = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b000};
    localparam [15:0] JSR_ABS_L = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b001};

    // seq41: indexed EA functions
    function automatic [15:0] ext_idx(
        input logic da, input logic [2:0] xn_reg,
        input logic wl, input logic [1:0] scale, input logic [7:0] d8
    );
        ext_idx = {da, xn_reg, wl, scale, 1'b0, d8};
    endfunction
    function automatic [15:0] move_l_idx_dn(input logic [2:0] dst, input logic [2:0] base);
        move_l_idx_dn = {4'h2, dst, 3'b000, 3'b110, base};
    endfunction
    function automatic [15:0] movea_l_idx_an(input logic [2:0] dst, input logic [2:0] base);
        movea_l_idx_an = {4'h2, dst, 3'b001, 3'b110, base};
    endfunction
    function automatic [15:0] lea_idx(input logic [2:0] dst, input logic [2:0] base);
        lea_idx = {4'h4, dst, 3'b111, 3'b110, base};
    endfunction
    function automatic [15:0] jmp_idx(input logic [2:0] base);
        jmp_idx = {4'h4, 3'b111, 1'b0, 2'b11, 3'b110, base};
    endfunction

    // seq42: PC-relative EA functions
    function automatic [15:0] MOVE_L_PC_D16(input logic [2:0] dn);
        MOVE_L_PC_D16 = {4'h2, dn,      3'b000, 3'b111, 3'b010};
    endfunction
    function automatic [15:0] MOVEA_L_PC_D16(input logic [2:0] an);
        MOVEA_L_PC_D16 = {4'h2, an,     3'b001, 3'b111, 3'b010};
    endfunction
    function automatic [15:0] LEA_PC_D16(input logic [2:0] an);
        LEA_PC_D16 = {4'h4, an,         3'b111, 3'b111, 3'b010};
    endfunction
    function automatic [15:0] MOVE_L_PC_IDX(input logic [2:0] dn);
        MOVE_L_PC_IDX = {4'h2, dn,      3'b000, 3'b111, 3'b011};
    endfunction
    function automatic [15:0] LEA_PC_IDX(input logic [2:0] an);
        LEA_PC_IDX = {4'h4, an,         3'b111, 3'b111, 3'b011};
    endfunction
    localparam [15:0] JMP_PC_D16 = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b010};
    localparam [15:0] JMP_PC_IDX = {4'h4, 3'b111, 1'b0, 2'b11, 3'b111, 3'b011};
    localparam [15:0] JSR_PC_D16 = {4'h4, 3'b111, 1'b0, 2'b10, 3'b111, 3'b010};

    // ─── Test: basic EA modes — (An)/(An)+/-(An)/(d16,An), LEA ───────────────
    task automatic test_basic_ea();
        // Formula-based memory: reads return (mem_addr | 0xA0000001)
        mem_use_formula = 1;
        $display("--- Basic EA: indirect/postinc/predec/disp/LEA ---");

        set_an(3'd0, 32'h1000);
        run_instr(MOVE_L_iA0_D1, 1'b0, 32'h0);
        chk("basic-EA (An)→D1",        dut.u_rf.d_reg[1], 32'h1000 | 32'hA000_0001);
        chk("basic-EA last_addr",       last_mem_addr,     32'h1000);
        chk1("basic-EA fc=101",         last_mem_fc == 3'b101, 1'b1);
        chk1("basic-EA rw=read",        last_mem_rw, 1'b1);

        run_instr(MOVE_L_A0inc_D2, 1'b0, 32'h0);
        chk("basic-EA (An)+ D2",        dut.u_rf.d_reg[2], 32'h1000 | 32'hA000_0001);
        chk("basic-EA (An)+ A0=1004",   dut.u_rf.a_reg[0], 32'h1004);
        chk("basic-EA (An)+ addr",      last_mem_addr,     32'h1000);

        set_an(3'd1, 32'h1004);
        run_instr(MOVE_L_A1dec_D3, 1'b0, 32'h0);
        chk("basic-EA -(An) D3",        dut.u_rf.d_reg[3], 32'h1000 | 32'hA000_0001);
        chk("basic-EA -(An) A1=1000",   dut.u_rf.a_reg[1], 32'h1000);

        set_an(3'd0, 32'h1000);
        run_instr(MOVE_L_d16A0_D4, 1'b1, 32'h0000_0008);
        chk("basic-EA (d16,A0) D4",     dut.u_rf.d_reg[4], 32'h1008 | 32'hA000_0001);
        chk("basic-EA (d16,A0) addr",   last_mem_addr,     32'h1008);
        chk("basic-EA (d16,A0) A0 unch",dut.u_rf.a_reg[0], 32'h1000);

        run_instr(MOVEA_L_iA0_A2, 1'b0, 32'h0);
        chk("basic-EA MOVEA(An) A2",    dut.u_rf.a_reg[2], 32'h1000 | 32'hA000_0001);

        set_an(3'd0, 32'h2000);
        run_instr(LEA_iA0_A3, 1'b0, 32'h0);
        chk("basic-EA LEA(An) A3",      dut.u_rf.a_reg[3], 32'h2000);
        chk1("basic-EA LEA no mem",     last_mem_seen, 1'b0);

        run_instr(LEA_d16A0_A4, 1'b1, 32'h0000_000C);
        chk("basic-EA LEA(d16,An) A4",  dut.u_rf.a_reg[4], 32'h200C);
        chk1("basic-EA LEA disp no mem",last_mem_seen, 1'b0);

        set_dn(3'd5, 32'hDEAD_BEEF);
        set_an(3'd0, 32'h1000);
        run_instr(MOVE_L_D5_iA0, 1'b0, 32'h0);
        chk("basic-EA write (An)",      wr_cap_addr, 32'h1000);
        chk("basic-EA write data",      wr_cap_data, 32'hDEAD_BEEF);
        chk1("basic-EA rw=write",       last_mem_rw, 1'b0);
        chk("basic-EA write A0 unch",   dut.u_rf.a_reg[0], 32'h1000);

        run_instr(MOVE_L_D5_A0inc, 1'b0, 32'h0);
        chk("basic-EA (An)+ write addr",wr_cap_addr, 32'h1000);
        chk("basic-EA (An)+ A0 adv",   dut.u_rf.a_reg[0], 32'h1004);

        set_an(3'd1, 32'h1004);
        run_instr(MOVE_L_D5_A1dec, 1'b0, 32'h0);
        chk("basic-EA -(An) write addr",wr_cap_addr, 32'h1000);
        chk("basic-EA -(An) A1 dec",   dut.u_rf.a_reg[1], 32'h1000);

        set_an(3'd0, 32'h1000);
        run_instr(MOVE_L_D5_d16A0, 1'b1, 32'h0000_0004);
        chk("basic-EA (d16,An) write",  wr_cap_addr, 32'h1004);
        chk("basic-EA (d16,An) A0 unch",dut.u_rf.a_reg[0], 32'h1000);

        set_an(3'd0, 32'h1010);
        run_instr(LEA_d16A0_A3, 1'b1, 32'h0000_FFF0);
        chk("basic-EA LEA neg disp",    dut.u_rf.a_reg[3], 32'h1000);

        mem_use_formula = 0;
    endtask

    // ─── Test: absolute EA — (xxx).W and (xxx).L ──────────────────────────────
    task automatic test_absolute_ea();
        $display("--- Absolute EA: (xxx).W / (xxx).L ---");

        set_dn(3'd0, 32'hDEAD_BEEF);
        run_instr(MOVE_L_DN_ABS_W(3'd0), 1'b1, {16'h0, 16'h0100});
        @(posedge clk);
        chk("abs-EA write.W",   ram[32'h100>>2], 32'hDEAD_BEEF);

        set_dn(3'd1, 32'h1234_5678);
        run_instr(MOVE_L_DN_ABS_L(3'd1), 1'b1, 32'h0000_01FC);
        @(posedge clk);
        chk("abs-EA write.L",   ram[32'h1FC>>2], 32'h1234_5678);

        run_instr(MOVE_L_ABS_W_DN(3'd2), 1'b1, {16'h0, 16'h0100});
        repeat(2) @(posedge clk);
        chk("abs-EA read.W D2", dut.u_rf.d_reg[2], 32'hDEAD_BEEF);

        run_instr(MOVE_L_ABS_L_DN(3'd3), 1'b1, 32'h0000_01FC);
        repeat(2) @(posedge clk);
        chk("abs-EA read.L D3", dut.u_rf.d_reg[3], 32'h1234_5678);

        run_instr(MOVEA_L_ABS_W_AN(3'd1), 1'b1, {16'h0, 16'h0100});
        repeat(2) @(posedge clk);
        chk("abs-EA MOVEA.W A1",dut.u_rf.a_reg[1], 32'hDEAD_BEEF);

        run_instr(MOVEA_L_ABS_L_AN(3'd2), 1'b1, 32'h0000_01FC);
        repeat(2) @(posedge clk);
        chk("abs-EA MOVEA.L A2",dut.u_rf.a_reg[2], 32'h1234_5678);

        run_instr(LEA_ABS_W_AN(3'd3), 1'b1, {16'h0, 16'h0100});
        repeat(2) @(posedge clk);
        chk("abs-EA LEA.W A3",  dut.u_rf.a_reg[3], 32'h0000_0100);

        run_instr(LEA_ABS_L_AN(3'd4), 1'b1, 32'h0001_FC00);
        repeat(2) @(posedge clk);
        chk("abs-EA LEA.L A4",  dut.u_rf.a_reg[4], 32'h0001_FC00);

        // JMP (xxx).W — abs short sign-extends: 0x8000 → 0xFFFF8000
        run_instr(JMP_ABS_W, 1'b1, {16'h0, 16'h8000});
        chk1("abs-EA JMP.W taken",      saw_branch, 1'b1);
        chk("abs-EA JMP.W target",      last_target, 32'hFFFF_8000);

        // JSR (xxx).L — push return PC, branch to 0xABCD0000
        // decode_pc=0x1000, JSR.L is 6-byte instr → retPC=0x1006
        set_isp(32'h0000_0300);
        run_instr(JSR_ABS_L, 1'b1, 32'hABCD_0000);
        chk1("abs-EA JSR.L taken",      saw_branch, 1'b1);
        chk("abs-EA JSR.L target",      last_target, 32'hABCD_0000);
        chk("abs-EA JSR.L A7",          isp_out,    32'h0000_02FC);
        chk("abs-EA JSR.L retPC",       ram[32'h2FC>>2], 32'h0000_1006);
    endtask

    // ─── Test: indexed EA — (d8,An,Xn) ───────────────────────────────────────
    task automatic test_indexed_ea();
        $display("--- Indexed EA: (d8,An,Xn) ---");

        // Pre-fill RAM
        ram[32'h010>>2] = 32'hDEAD_0001;
        ram[32'h014>>2] = 32'hDEAD_0005;
        ram[32'h018>>2] = 32'hDEAD_0006;
        ram[32'h01C>>2] = 32'hDEAD_000C;

        // (0,A0,D1.L*1): A0=0x010, D1=0 → EA=0x010
        set_an(3'd0, 32'h0000_0010);
        set_dn(3'd1, 32'h0000_0000);
        run_instr(move_l_idx_dn(3'd2, 3'd0), 1'b1, {16'h0, ext_idx(0, 3'd1, 1, 2'b00, 8'h00)});
        repeat(2) @(posedge clk);
        chk("idx (0,A0,D1.L*1)",        dut.u_rf.d_reg[2], 32'hDEAD_0001);

        // (4,A0,D1.L*4): A0=0, D1=5, d8=4, scale=4 → EA=0+4+20=0x018
        set_an(3'd0, 32'h0000_0000);
        set_dn(3'd1, 32'h0000_0005);
        run_instr(move_l_idx_dn(3'd3, 3'd0), 1'b1, {16'h0, ext_idx(0, 3'd1, 1, 2'b10, 8'h04)});
        repeat(2) @(posedge clk);
        chk("idx (4,A0,D1.L*4)",        dut.u_rf.d_reg[3], 32'hDEAD_0006);

        // (0,A0,D1.W*2): A0=0x010, D1[15:0]=2, d8=0, scale=2 → EA=0x010+0+4=0x014
        set_an(3'd0, 32'h0000_0010);
        set_dn(3'd1, 32'h0001_0002);
        run_instr(move_l_idx_dn(3'd4, 3'd0), 1'b1, {16'h0, ext_idx(0, 3'd1, 0, 2'b01, 8'h00)});
        repeat(2) @(posedge clk);
        chk("idx (0,A0,D1.W*2)",        dut.u_rf.d_reg[4], 32'hDEAD_0005);

        // (-4,A0,D1.L*1): A0=0x020, D1=0, d8=-4 → EA=0x020-4=0x01C
        set_an(3'd0, 32'h0000_0020);
        set_dn(3'd1, 32'h0000_0000);
        run_instr(move_l_idx_dn(3'd5, 3'd0), 1'b1, {16'h0, ext_idx(0, 3'd1, 1, 2'b00, 8'hFC)});
        repeat(2) @(posedge clk);
        chk("idx (-4,A0,D1.L*1)",       dut.u_rf.d_reg[5], 32'hDEAD_000C);

        // MOVEA.L (0,A1,D2.L*1),A3: A1=0x010, D2=4 → EA=0x014 → A3
        set_an(3'd1, 32'h0000_0010);
        set_dn(3'd2, 32'h0000_0004);
        run_instr(movea_l_idx_an(3'd3, 3'd1), 1'b1, {16'h0, ext_idx(0, 3'd2, 1, 2'b00, 8'h00)});
        repeat(2) @(posedge clk);
        chk("idx MOVEA (0,A1,D2.L)",    dut.u_rf.a_reg[3], 32'hDEAD_0005);

        // LEA (8,A2,D3.L*1),A4: A2=0x030, D3=8, d8=8 → A4=0x040
        set_an(3'd2, 32'h0000_0030);
        set_dn(3'd3, 32'h0000_0008);
        run_instr(lea_idx(3'd4, 3'd2), 1'b1, {16'h0, ext_idx(0, 3'd3, 1, 2'b00, 8'h08)});
        repeat(2) @(posedge clk);
        chk("idx LEA (8,A2,D3)",        dut.u_rf.a_reg[4], 32'h0000_0040);

        // LEA (0,A0,D1.L*4),A5: A0=0, D1=4, scale=4 → A5=0x010
        set_an(3'd0, 32'h0000_0000);
        set_dn(3'd1, 32'h0000_0004);
        run_instr(lea_idx(3'd5, 3'd0), 1'b1, {16'h0, ext_idx(0, 3'd1, 1, 2'b10, 8'h00)});
        repeat(2) @(posedge clk);
        chk("idx LEA (0,A0,D1.L*4)",    dut.u_rf.a_reg[5], 32'h0000_0010);

        // JMP (0,A6,D0.L*1): A6=0x5000, D0=0x100 → target=0x5100
        set_an(3'd6, 32'h0000_5000);
        set_dn(3'd0, 32'h0000_0100);
        run_instr(jmp_idx(3'd6), 1'b1, {16'h0, ext_idx(0, 3'd0, 1, 2'b00, 8'h00)});
        chk1("idx JMP taken",           saw_branch, 1'b1);
        chk("idx JMP target",           last_target, 32'h0000_5100);
    endtask

    // ─── Test: PC-relative EA — (d16,PC) and (d8,PC,Xn) ─────────────────────
    task automatic test_pc_relative_ea();
        $display("--- PC-relative EA: (d16,PC) / (d8,PC,Xn) ---");
        // decode_pc = 0x0000; EA base = decode_pc + 2 = 0x0002
        decode_pc = 32'h0000_0000;

        ram[32'h000A >> 2] = 32'hAABB_0001;
        ram[32'h0000 >> 2] = 32'hAABB_0002;
        ram[32'h0020 >> 2] = 32'hAABB_0003;
        ram[32'h000C >> 2] = 32'hAABB_0005;

        // (8,PC): EA = 0+2+8 = 0x000A
        run_instr(MOVE_L_PC_D16(3'd0), 1'b1, {16'h0, 16'h0008});
        repeat(2) @(posedge clk);
        chk("pc-rel (8,PC) D0",         dut.u_rf.d_reg[0], 32'hAABB_0001);

        // (-2,PC): EA = 0+2-2 = 0x0000
        run_instr(MOVE_L_PC_D16(3'd1), 1'b1, {16'h0, 16'hFFFE});
        repeat(2) @(posedge clk);
        chk("pc-rel (-2,PC) D1",        dut.u_rf.d_reg[1], 32'hAABB_0002);

        // MOVEA.L (0x1E,PC),A2: EA = 0+2+0x1E = 0x0020
        run_instr(MOVEA_L_PC_D16(3'd2), 1'b1, {16'h0, 16'h001E});
        repeat(2) @(posedge clk);
        chk("pc-rel MOVEA (0x1E,PC) A2",dut.u_rf.a_reg[2], 32'hAABB_0003);

        // LEA (0x3E,PC),A3: A3 = 0+2+0x3E = 0x0040
        run_instr(LEA_PC_D16(3'd3), 1'b1, {16'h0, 16'h003E});
        repeat(2) @(posedge clk);
        chk("pc-rel LEA (0x3E,PC) A3",  dut.u_rf.a_reg[3], 32'h0000_0040);

        // (4,PC,D1.L*1): D1=8, d8=4, scale=1 → EA=2+4+8=0x000E
        set_dn(3'd1, 32'd8);
        run_instr(MOVE_L_PC_IDX(3'd4), 1'b1, {16'h0, ext_idx(0, 3'd1, 1, 2'b00, 8'h04)});
        repeat(2) @(posedge clk);
        chk("pc-rel (4,PC,D1.L*1) D4",  dut.u_rf.d_reg[4], 32'hAABB_0005);

        // (0,PC,D2.W*4): D2=3, d8=0, scale=4 → EA=2+0+12=0x000E
        set_dn(3'd2, 32'd3);
        run_instr(MOVE_L_PC_IDX(3'd5), 1'b1, {16'h0, ext_idx(0, 3'd2, 0, 2'b10, 8'h00)});
        repeat(2) @(posedge clk);
        chk("pc-rel (0,PC,D2.W*4) D5",  dut.u_rf.d_reg[5], 32'hAABB_0005);

        // LEA (6,PC,D3.L*1),A6: D3=0x10, d8=6 → A6=2+6+0x10=0x0018
        set_dn(3'd3, 32'h10);
        run_instr(LEA_PC_IDX(3'd6), 1'b1, {16'h0, ext_idx(0, 3'd3, 1, 2'b00, 8'h06)});
        repeat(2) @(posedge clk);
        chk("pc-rel LEA (6,PC,D3) A6",  dut.u_rf.a_reg[6], 32'h0000_0018);

        // JMP (0x100,PC): target = 0+2+0x100 = 0x0102
        run_instr(JMP_PC_D16, 1'b1, {16'h0, 16'h0100});
        chk1("pc-rel JMP taken",         saw_branch, 1'b1);
        chk("pc-rel JMP target",         last_target, 32'h0000_0102);

        // JMP (0,PC,D0.L*2): D0=8, scale=2 → target=2+0+16=0x0012
        set_dn(3'd0, 32'd8);
        run_instr(JMP_PC_IDX, 1'b1, {16'h0, ext_idx(0, 3'd0, 1, 2'b01, 8'h00)});
        chk1("pc-rel JMP idx taken",     saw_branch, 1'b1);
        chk("pc-rel JMP idx target",     last_target, 32'h0000_0012);

        // JSR (0x200,PC): target=0+2+0x200=0x0202, retPC=0+4=4
        // ISP reset to 0 so push wraps to 0xFFFF_FFFC
        set_isp(32'h0);
        run_instr(JSR_PC_D16, 1'b1, {16'h0, 16'h0200});
        chk1("pc-rel JSR taken",         saw_branch, 1'b1);
        chk("pc-rel JSR target",         last_target, 32'h0000_0202);
        chk("pc-rel JSR ISP",            isp_out, 32'hFFFF_FFFC);

        decode_pc = 32'h0000_1000;   // restore
    endtask

    // ─── Test: memory-indirect EA — ([bd,An],Xn,od) ──────────────────────────
    task automatic test_memory_indirect();
        $display("--- Memory-indirect EA: ([bd,An],Xn,od) ---");

        // P53-1: pre-indexed, null bd, null od
        // A0=0x100, D1=0x10; inner: A0+D1=0x110 → ptr; outer: MEM[ptr] → D2
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h110 >> 2] = 32'h0000_0200;
            ram[32'h200 >> 2] = 32'hDEAD_BEEF;
            // ext0: D=0,Xreg=001(D1),WL=1,scale=00,full=1,BS=0,IS=0,BDsz=01,I/IS=001
            // = 0001_1001_0001_0001 = 16'h1911
            run_instr(16'h2430, 1'b1, {16'h0, 16'h1911});
            wait_mem_at(32'h0000_0110, 20, found);
            chk1("mem-ind P1 inner@0x110", found, 1'b1);
            wait_mem_at(32'h0000_0200, 20, found);
            chk1("mem-ind P1 outer@0x200", found, 1'b1);
            drain;
            chk("mem-ind P1 D2",           `DR(2), 32'hDEAD_BEEF);
        end

        // P53-2: pre-indexed, word bd, null od
        // A1=0x100, D1=0x10, bd=0x0020; inner: 0x100+0x10+0x20=0x130 → ptr; outer: MEM[ptr]
        begin
            logic found;
            `AR(1) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h130 >> 2] = 32'h0000_0300;
            ram[32'h300 >> 2] = 32'hABCD_1234;
            // ext0: BDsz=10(word) = 0001_1001_0010_0001 = 16'h1921; bd=0x0020 in high 16
            run_instr(16'h2431, 1'b1, {16'h0020, 16'h1921});
            wait_mem_at(32'h0000_0130, 20, found);
            chk1("mem-ind P2 inner@0x130", found, 1'b1);
            wait_mem_at(32'h0000_0300, 20, found);
            chk1("mem-ind P2 outer@0x300", found, 1'b1);
            drain;
            chk("mem-ind P2 D2",           `DR(2), 32'hABCD_1234);
        end

        // P53-3: pre-indexed, IS=1 (index register suppressed entirely),
        // null bd, null od. A0=0x100, D1=0x40; inner: MEM[A0]=ptr; outer: ptr
        // (unmodified -- IS=1 means no index register anywhere in the EA,
        // independent of pre/post-indexed selection; D1 is never added).
        //
        // This test's own comment/expected values used to read "post-indexed
        // (IS=1)" with outer = MEM[ptr+D1] = 0x540, conflating IS (Index
        // Suppress, ext bit 6 -- "is there an index register at all") with
        // the *separate* pre/post-indexed selector (I/IS bits[2:0], ext bits
        // 2:0 here = 001 = genuinely pre-indexed) -- the exact same bug
        // found and fixed in eu_seq.sv's dec_memind_is_post/dec_is_idx via a
        // dedicated Musashi-cosim investigation (plan.md Phase 107/115,
        // tests/memind4.s reproduces this exact opcode/ext encoding and
        // confirms Musashi reads the final value from the *pointer itself*,
        // 0x500 -- not 0x540 -- for IS=1). The DUT's old (buggy) decode
        // happened to match this test's old (also wrong) expectation, which
        // is why both agreed before; fixed together here.
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0040;
            `DR(2) = 32'h0;
            ram[32'h100 >> 2] = 32'h0000_0500;
            ram[32'h500 >> 2] = 32'h1234_5678;
            // IS=1 → [6]=1; ext0 = 0001_1001_0101_0001 = 16'h1951
            run_instr(16'h2430, 1'b1, {16'h0, 16'h1951});
            wait_mem_at(32'h0000_0100, 20, found);
            chk1("mem-ind P3 inner@A0",    found, 1'b1);
            wait_mem_at(32'h0000_0500, 20, found);
            chk1("mem-ind P3 outer@0x500", found, 1'b1);
            drain;
            chk("mem-ind P3 D2",           `DR(2), 32'h1234_5678);
        end

        // P53-4: pre-indexed, null bd, word od
        // A0=0x100, D1=0x10, od=0x0008; inner: 0x110→ptr=0x200; outer: MEM[0x208]
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h110 >> 2] = 32'h0000_0200;
            ram[32'h208 >> 2] = 32'hCAFE_BABE;
            // I/IS=010(word od), BDsz=01; od in high 16
            // = 0001_1001_0001_0010 = 16'h1912; od=0x0008
            run_instr(16'h2430, 1'b1, {16'h0008, 16'h1912});
            wait_mem_at(32'h0000_0110, 20, found);
            chk1("mem-ind P4 inner@0x110", found, 1'b1);
            wait_mem_at(32'h0000_0208, 20, found);
            chk1("mem-ind P4 outer@0x208", found, 1'b1);
            drain;
            chk("mem-ind P4 D2",           `DR(2), 32'hCAFE_BABE);
        end

        // P53-5: full ext, no indirection (I/IS=000) — single bus cycle
        begin
            int log_before, log_after;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h130 >> 2] = 32'hC0DE_CAFE;
            // I/IS=000, BDsz=10(word bd); = 0001_1001_0010_0000 = 16'h1920; bd=0x0020
            run_instr(16'h2430, 1'b1, {16'h0020, 16'h1920});
            log_after = mem_log_wp;
            log_before = mem_log_start;
            chk1("mem-ind P5 single cycle", (log_after - log_before) == 1, 1'b1);
            chk("mem-ind P5 D2",            `DR(2), 32'hC0DE_CAFE);
        end

        // P53-6: regression — brief indexed (d8,An,Xn) still works (ext0[8]=0)
        begin
            logic found;
            `AR(0) = 32'h0000_0100;
            `DR(1) = 32'h0000_0010;
            `DR(2) = 32'h0;
            ram[32'h114 >> 2] = 32'h5555_AAAA;
            // Brief ext: D=0, Xreg=001(D1), WL=1, scale=00, full=0, d8=0x04
            // = 0001_1000_0000_0100 = 16'h1804
            run_instr(16'h2430, 1'b1, {16'h0, 16'h1804});
            wait_mem_at(32'h0000_0114, 20, found);
            chk1("mem-ind P6 brief@0x114", found, 1'b1);
            drain;
            chk("mem-ind P6 D2",           `DR(2), 32'h5555_AAAA);
        end
    endtask

    // ─── Main sequence ────────────────────────────────────────────────────────
    initial begin
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        test_basic_ea();
        test_absolute_ea();
        test_indexed_ea();
        test_pc_relative_ea();
        test_memory_indirect();

        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("PASS ea_modes (%0d checks)", pass_cnt);
        else
            $display("FAIL ea_modes: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL ea_modes: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

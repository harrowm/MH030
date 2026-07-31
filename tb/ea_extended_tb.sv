`default_nettype none
`timescale 1ns/1ps

// Extended addressing mode tests
//
// MOVEM.L with (d16,An), (xxx).W, (d16,PC) EA modes
// Scc with (d16,An) and (d8,An,Dn.W) indexed EA
// TAS.B with (An)+  post-increment and -(An) pre-decrement
// CHK.W  with (An) and (d16,An) memory bound EA
// BFTST  with (d16,An) and (xxx).W EA
// CMP2.W with (d16,An) EA

module ea_extended_tb;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
    end

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

    m68030_eu dut (
        .clk_4x          (clk),
        .rst_n           (rst_n),
        .instr_word      (instr_word),
        .instr_valid     (instr_valid),
        .ext_data        (ext_data),
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
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // Memory model with word-aware reads for CMP2.W bounds
    // Word reads: addr[1]=0 → upper word [31:16] in [15:0]; addr[1]=1 → lower word [15:0]
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw)
        ? ((mem_siz == 2'b10)
               ? (mem_addr[1] ? {16'h0, ram[mem_addr[14:2]][15:0]}
                               : {16'h0, ram[mem_addr[14:2]][31:16]})
               : ram[mem_addr[14:2]])
        : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    int chk_trap_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) chk_trap_cnt <= 0;
        else if (chk_trap) chk_trap_cnt <= chk_trap_cnt + 1;
    end

    int pass_count = 0, fail_count = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %0b exp %0b", tag, got, exp);
            fail_count++;
        end else
            pass_count++;
    endtask

    task automatic run_instr(input logic [15:0] iw, input logic has_ext,
                             input logic [31:0] ext);
        @(posedge clk); #1;
        instr_word  = iw; instr_valid = 1'b1; ext_data = ext; ext_valid = has_ext;
        repeat(300) begin
            @(posedge clk);
            if (instr_ack) break;
        end
        instr_valid = 1'b0; ext_valid = 1'b0;
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

    initial begin
        int prev_chk;
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        chk_trap_cnt = 0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // MOVEM.L store (d16,A0): 0x48E8; mask=0x0001(D0), d16=0x0008; A0=0x100
        $display("--- MOVEM: (d16,An) and (xxx).W ---");
        set_an(3'h0, 32'h0000_0100);
        set_dn(0, 32'hDEADBEEF);
        run_instr(16'h48E8, 1'b1, 32'h0001_0008);
        chk("MOVEM-01:store_d16An", ram[32'h108>>2], 32'hDEADBEEF);

        // MOVEM.L load (d16,A0): 0x4CE8; D0 ← mem[A0+8=0x10C]
        set_dn(0, 32'h0);
        ram[32'h10C>>2] = 32'h12345678;
        set_an(3'h0, 32'h0000_0104);
        run_instr(16'h4CE8, 1'b1, 32'h0001_0008);
        run_instr(16'h21C0, 1'b1, 32'h0000_0300);   // MOVE.L D0,(0x300).W
        chk("MOVEM-02:load_d16An", ram[32'h300>>2], 32'h12345678);

        // MOVEM.L store (xxx).W: 0x48F8; D0 → abs 0x0400
        set_dn(0, 32'hCAFEBABE);
        run_instr(16'h48F8, 1'b1, 32'h0001_0400);
        chk("MOVEM-03:store_absW", ram[32'h400>>2], 32'hCAFEBABE);

        // MOVEM.L load (xxx).W: 0x4CF8; D0 ← abs 0x0404
        ram[32'h404>>2] = 32'hBEEFCAFE;
        run_instr(16'h4CF8, 1'b1, 32'h0001_0404);
        run_instr(16'h21C0, 1'b1, 32'h0000_0408);   // MOVE.L D0,(0x408).W
        chk("MOVEM-04:load_absW", ram[32'h408>>2], 32'hBEEFCAFE);

        // MOVEM.L load (d16,PC): 0x4CFA; D0 ← mem[decode_pc+4+d16=0x1014]
        ram[32'h1014>>2] = 32'hA5A5A5A5;
        decode_pc = 32'h0000_1000;
        run_instr(16'h4CFA, 1'b1, 32'h0001_0010);
        decode_pc = 32'h0;
        run_instr(16'h21C0, 1'b1, 32'h0000_0410);   // MOVE.L D0,(0x410).W
        chk("MOVEM-05:load_d16PC", ram[32'h410>>2], 32'hA5A5A5A5);

        // Scc (d16,A0) — ST: 0x50E8, d16=8; A0=0x500 → write 0xFF at 0x508
        $display("--- Scc: (d16,An) and indexed ---");
        ram[32'h508>>2] = 32'h1234_5678;
        set_an(3'h0, 32'h0000_0500);
        run_instr(16'h50E8, 1'b1, 32'h0000_0008);
        chk("SCC-01:ST_d16An", ram[32'h508>>2], 32'hFF00_0000);

        // Scc (d8,A0,D1.W) — SF: 0x51F0, brief={D1,W,*1,d8=0x10}=0x1010; A0=0x500, D1=0 → 0x510
        ram[32'h510>>2] = 32'hAAAA_AAAA;
        set_an(3'h0, 32'h0000_0500);
        set_dn(1, 32'h0);
        run_instr(16'h51F0, 1'b1, 32'h0000_1010);
        chk("SCC-02:SF_indexed", ram[32'h510>>2], 32'h0000_0000);

        // TAS.B (A0)+ — post-increment: 0x4AD8; A0=0x600, M[0x600]=0x42 in [7:0]
        $display("--- TAS: post-increment and pre-decrement ---");
        ram[32'h600>>2] = 32'h0000_0042;
        set_an(3'h0, 32'h0000_0600);
        run_instr(16'h4AD8, 1'b0, 32'h0);
        chk("TAS-01:mem_postinc", ram[32'h600>>2], 32'hC200_0000);
        chk1("TAS-01:N=0", sr_out[3], 1'b0);
        chk1("TAS-01:Z=0", sr_out[2], 1'b0);
        run_instr(16'h21C8, 1'b1, 32'h0000_0608);   // MOVE.L A0,(0x608).W
        chk("TAS-01:A0_postinc", ram[32'h608>>2], 32'h0000_0601);

        // TAS.B -(A0) — pre-decrement: 0x4AE0; A0=0x601, M[0x600]=0x00 → Z=1
        ram[32'h600>>2] = 32'h0000_0000;
        set_an(3'h0, 32'h0000_0601);
        run_instr(16'h4AE0, 1'b0, 32'h0);
        chk("TAS-02:mem_predec", ram[32'h600>>2], 32'h8000_0000);
        chk1("TAS-02:N=0", sr_out[3], 1'b0);
        chk1("TAS-02:Z=1", sr_out[2], 1'b1);
        run_instr(16'h21C8, 1'b1, 32'h0000_0610);   // MOVE.L A0,(0x610).W
        chk("TAS-02:A0_predec", ram[32'h610>>2], 32'h0000_0600);

        // CHK (A0),D1 — in-range: 0x4390; A0=0x700, M[0x700] word=10, D1=5
        $display("--- CHK: memory bound EA ---");
        ram[32'h700>>2] = 32'h000A_0000;
        set_dn(1, 32'h0000_0005);
        set_an(3'h0, 32'h0000_0700);
        prev_chk = chk_trap_cnt;
        run_instr(16'h4390, 1'b0, 32'h0);
        chk("CHK-01:no_trap", 32'(chk_trap_cnt - prev_chk), 32'h0);

        // CHK.W (d16,A0),D1 — above bound: 0x43A8; d16=8, M[0x708] word=10, D1=20
        ram[32'h708>>2] = 32'h000A_0000;
        set_dn(1, 32'h0000_0014);
        set_an(3'h0, 32'h0000_0700);
        prev_chk = chk_trap_cnt;
        run_instr(16'h43A8, 1'b1, 32'h0000_0008);
        chk("CHK-02:trap_d16An", 32'(chk_trap_cnt - prev_chk), 32'h1);

        // BFTST (d16,A0){0:8}: 0xE8E8; bf=0x0008, d16=0x10; M[0x810] MSByte=0 → Z=1
        $display("--- BFTST: (d16,An) and (xxx).W ---");
        ram[32'h810>>2] = 32'h00AABBCC;
        set_an(3'h0, 32'h0000_0800);
        run_instr(16'hE8E8, 1'b1, 32'h0008_0010);
        chk1("BFTST-01:Z=1", sr_out[2], 1'b1);
        chk1("BFTST-01:N=0", sr_out[3], 1'b0);

        // BFTST (xxx).W{0:8}: 0xE8F8; bf=0x0008, abs=0x820; M[0x820] MSByte=0x80 → N=1
        ram[32'h820>>2] = 32'h80FFFF00;
        run_instr(16'hE8F8, 1'b1, 32'h0008_0820);
        chk1("BFTST-02:N=1", sr_out[3], 1'b1);
        chk1("BFTST-02:Z=0", sr_out[2], 1'b0);

        // CMP2.W (d16,A0),D0 — in-range: 0x02E8; d16=0x10; lower=3,upper=10 @0x910; D0=5
        $display("--- CMP2.W: memory bounds with word EA ---");
        ram[32'h910>>2] = 32'h0003_000A;
        set_an(3'h0, 32'h0000_0900);
        set_dn(0, 32'h0000_0005);
        run_instr(16'h02E8, 1'b1, 32'h0000_0010);
        chk1("CMP2-01:C=0", sr_out[0], 1'b0);
        chk1("CMP2-01:Z=0", sr_out[2], 1'b0);

        $display("");
        if (fail_count == 0)
            $display("PASS: %0d checks passed", pass_count);
        else
            $display("FAIL: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule

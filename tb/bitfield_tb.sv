// Bit-field instructions: BFTST, BFEXTU, BFEXTS, BFFFO, BFCLR, BFSET, BFINS
// (register and memory forms); plus memory bit-op BSET #imm,(An).
`default_nettype none
`timescale 1ns/1ps

module bitfield_tb;

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

    task automatic chk_nz(input string tag, input logic exp_n, exp_z);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
    endtask

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
        // Bit-field register forms
        // ====================================================================
        $display("--- BFTST D0{2:4} (N=1, Z=0) ---");
        // D0=0x3C000000: bits[29:26]=1111 → field=0xF; N=1, Z=0
        // Opcode: 0xE8C0; ext [10:6]=00010, [4:0]=00100 → 0x0084
        set_dn(3'd0, 32'h3C00_0000);
        run_instr(16'hE8C0, 1'b1, 32'h0000_0084);
        chk_nz("BFTST-01", 1'b1, 1'b0);

        $display("--- BFEXTU D0{8:8},D1 (extract byte=0xAB; N=1, Z=0) ---");
        // D0=0x00AB0000; field=(D0>>16)&0xFF=0xAB; D1=0xAB
        // Opcode: 0xE9C0; ext [14:12]=001(D1), [10:6]=01000, [4:0]=01000 → 0x1208
        set_dn(3'd0, 32'h00AB_0000);
        set_dn(3'd1, 32'h0);
        run_instr(16'hE9C0, 1'b1, 32'h0000_1208);
        chk_nz("BFEXTU-01:ccr", 1'b1, 1'b0);
        run_instr(16'h0C81, 1'b1, 32'h0000_00AB);  // CMPI.L #0xAB,D1 → Z=1 if D1=0xAB
        chk1("BFEXTU-01:D1=0xAB", sr_out[2], 1'b1);

        $display("--- BFEXTS D0{24:8},D1 (sign-extend 0x80 → 0xFFFFFF80) ---");
        // D0=0x00000080; field=0x80 → sign_ext→D1=0xFFFFFF80; N=1
        // Opcode: 0xEAC0; ext [14:12]=001(D1), [10:6]=11000(24), [4:0]=01000(8) → 0x1608
        set_dn(3'd0, 32'h0000_0080);
        run_instr(16'hEAC0, 1'b1, 32'h0000_1608);
        run_instr(16'h0C81, 1'b1, 32'hFFFF_FF80);  // CMPI.L #0xFFFFFF80,D1
        chk1("BFEXTS-01:D1=0xFFFFFF80", sr_out[2], 1'b1);

        $display("--- BFFFO D0{0:32},D1 (find first one; D0=0x08000000 → offset=4) ---");
        // D0=0x08000000: highest set bit is bit27; BFFFO result = offset+31-27 = 4
        // Opcode: 0xEBC0; ext [14:12]=001(D1), [10:6]=00000(0), [4:0]=00000(32) → 0x1000
        set_dn(3'd0, 32'h0800_0000);
        run_instr(16'hEBC0, 1'b1, 32'h0000_1000);
        run_instr(16'h0C81, 1'b1, 32'h0000_0004);  // CMPI.L #4,D1
        chk1("BFFFO-01:D1=4", sr_out[2], 1'b1);

        $display("--- BFCLR D0{4:4} (clear 4-bit field at offset 4) ---");
        // D0=0xABCDEF01; field bits[27:24]=0xB; clear → D0=0xA0CDEF01
        // Opcode: 0xECC0; ext [10:6]=00100(4), [4:0]=00100(4) → 0x0104
        set_dn(3'd0, 32'hABCD_EF01);
        run_instr(16'hECC0, 1'b1, 32'h0000_0104);
        run_instr(16'h0C80, 1'b1, 32'hA0CD_EF01);  // CMPI.L #0xA0CDEF01,D0
        chk1("BFCLR-01:D0=0xA0CDEF01", sr_out[2], 1'b1);

        $display("--- BFSET D0{0:8} (set top byte; field=0x00 before → Z=1) ---");
        // D0=0x00FFFFFF; field=0x00 → N=0, Z=1; result=0xFFFFFFFF
        // Opcode: 0xEEC0; ext [10:6]=00000(0), [4:0]=01000(8) → 0x0008
        set_dn(3'd0, 32'h00FF_FFFF);
        run_instr(16'hEEC0, 1'b1, 32'h0000_0008);
        chk_nz("BFSET-01:ccr", 1'b0, 1'b1);
        run_instr(16'h0C80, 1'b1, 32'hFFFF_FFFF);
        chk1("BFSET-01:D0=0xFFFFFFFF", sr_out[2], 1'b1);

        $display("--- BFINS D1,D0{8:8} (insert D1[7:0]=0xAB into D0 bits[23:16]) ---");
        // D0=0xFFFFFF00, D1=0x000000AB → result=0xFFABFF00; N=1, Z=0
        // Opcode: 0xEFC0; ext [14:12]=001(D1), [10:6]=01000(8), [4:0]=01000(8) → 0x1208
        set_dn(3'd0, 32'hFFFF_FF00);
        set_dn(3'd1, 32'h0000_00AB);
        run_instr(16'hEFC0, 1'b1, 32'h0000_1208);
        run_instr(16'h0C80, 1'b1, 32'hFFAB_FF00);
        chk1("BFINS-01:D0=0xFFABFF00", sr_out[2], 1'b1);

        $display("--- BFTST D0{0:8} (zero field → Z=1) ---");
        // D0=0x00FFFFFF; field=0x00 → N=0, Z=1
        set_dn(3'd0, 32'h00FF_FFFF);
        run_instr(16'hE8C0, 1'b1, 32'h0000_0008);
        chk_nz("BFTST-02", 1'b0, 1'b1);

        // ====================================================================
        // Bit-field memory forms
        // ====================================================================
        $display("--- BFTST (A0){4:8} (read-only, no write; N=1) ---");
        // M[0x100]=0x0FA00000; field=(0x0FA00000>>20)&0xFF=0xFA; N=1
        // Opcode: 0xE8D0; ext [10:6]=00100(4), [4:0]=01000(8) → 0x0108
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'h0FA0_0000;
        run_instr(16'hE8D0, 1'b1, 32'h0000_0108);
        chk_nz("BFTST-03", 1'b1, 1'b0);
        chk("BFTST-03:mem-unch", ram[8'h40], 32'h0FA0_0000);

        $display("--- BFEXTU (A0){0:8},D2 (extract top byte 0xAB → D2) ---");
        // M[0x100]=0xAB000000; field=0xAB; D2=0xAB
        // Opcode: 0xE9D0; ext [14:12]=010(D2), [10:6]=00000(0), [4:0]=01000(8) → 0x2008
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hAB00_0000;
        set_dn(3'd2, 32'h0);
        run_instr(16'hE9D0, 1'b1, 32'h0000_2008);
        run_instr(16'h0C82, 1'b1, 32'h0000_00AB);  // CMPI.L #0xAB,D2
        chk1("BFEXTU-02:D2=0xAB", sr_out[2], 1'b1);

        $display("--- BFCLR (A0){0:8} (clear top byte: 0xDEADBEEF → 0x00ADBEEF) ---");
        // Opcode: 0xECD0; ext [10:6]=00000(0), [4:0]=01000(8) → 0x0008
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hDEAD_BEEF;
        run_instr(16'hECD0, 1'b1, 32'h0000_0008);
        chk("BFCLR-02:mem", ram[8'h40], 32'h00AD_BEEF);

        $display("--- BFSET (A0){24:8} (set bottom byte: 0xDEADBE00 → 0xDEADBEFF) ---");
        // Opcode: 0xEED0; ext [10:6]=11000(24), [4:0]=01000(8) → 0x0608
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hDEAD_BE00;
        run_instr(16'hEED0, 1'b1, 32'h0000_0608);
        chk("BFSET-02:mem", ram[8'h40], 32'hDEAD_BEFF);

        $display("--- BFINS D3,(A0){8:8} (insert D3[7:0]=0xCD into memory byte at offset 8) ---");
        // M[0x100]=0xFFFFFF00, D3=0xCD; result=0xFFCDFF00
        // Opcode: 0xEFD0; ext [14:12]=011(D3), [10:6]=01000(8), [4:0]=01000(8) → 0x3208
        set_an(3'd0, 32'h0000_0100);
        ram[8'h40] = 32'hFFFF_FF00;
        set_dn(3'd3, 32'h0000_00CD);
        run_instr(16'hEFD0, 1'b1, 32'h0000_3208);
        chk("BFINS-02:mem", ram[8'h40], 32'hFFCD_FF00);

        // ====================================================================
        // Memory bit-op: BSET with immediate bit number
        // ====================================================================
        $display("--- BSET #3,(A0) (immediate bit set: bit 3 of byte; was 0 → Z=1) ---");
        // M[0x400]=0x00; after BSET #3: byte 0x08 written in [31:24]; Z=1
        // Opcode: 0x08D0; ext [2:0]=3 → 0x0003
        ram[32'h400 >> 2] = 32'h0000_0000;
        set_an(3'd0, 32'h0000_0400);
        run_instr(16'h08D0, 1'b1, 32'h0003);
        chk("BSET-03:mem", ram[32'h400 >> 2], 32'h0800_0000);
        chk1("BSET-03:Z",  sr_out[2], 1'b1);

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
        #300000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

`default_nettype none
`timescale 1ns/1ps

// Data movement testbench: MOVEM, MOVEP, MOVE16, MOVE mem→mem
// Sources: seq43 (MOVEM), seq49 (MOVEP), seq50 (MOVE16), seq67 (MOVE mem→mem)

`define DR(n)  dut.u_rf.d_reg[n]
`define AR(n)  dut.u_rf.a_reg[n]

module data_move_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin repeat(4) @(posedge clk); rst_n = 1; end

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
    // Byte-selective 32-bit RAM.  Covers all four test groups:
    // MOVEM uses 0x024..0x200, MOVEP uses 0x100..0x700, MOVE16 uses 0x100..0x790,
    // MOVE-mem uses 0x100..0x500.  RAM size: 8 KB (2048 longwords).
    logic [31:0] ram [0:2047];

    // Normalise a read: siz=00→full lw, siz=10→upper/lower word, siz=01→byte
    function automatic logic [31:0] extract_rd(
        input logic [31:0] raw,
        input logic [1:0]  siz,
        input logic [1:0]  lo
    );
        case (siz)
            2'b01: case (lo)
                2'b00: extract_rd = {24'h0, raw[31:24]};
                2'b01: extract_rd = {24'h0, raw[23:16]};
                2'b10: extract_rd = {24'h0, raw[15:8]};
                2'b11: extract_rd = {24'h0, raw[7:0]};
            endcase
            2'b10: extract_rd = lo[1] ? {16'h0, raw[15:0]} : {16'h0, raw[31:16]};
            default: extract_rd = raw;
        endcase
    endfunction

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw)
                     ? extract_rd(ram[mem_addr[12:2]], mem_siz, mem_addr[1:0])
                     : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw) begin
            case ({mem_siz, mem_addr[1:0]})
                // EU always puts words in [31:16] and bytes in [31:24]; model steers to correct lane
                4'b10_00: ram[mem_addr[12:2]][31:16] <= mem_wdata[31:16];
                4'b10_10: ram[mem_addr[12:2]][15:0]  <= mem_wdata[31:16];
                4'b01_00: ram[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
                4'b01_01: ram[mem_addr[12:2]][23:16] <= mem_wdata[31:24];
                4'b01_10: ram[mem_addr[12:2]][15:8]  <= mem_wdata[31:24];
                4'b01_11: ram[mem_addr[12:2]][7:0]   <= mem_wdata[31:24];
                default:  ram[mem_addr[12:2]]        <= mem_wdata;
            endcase
        end
    end

    // ─── An write logger (for MOVE mem→mem An-update ordering) ───────────────
    logic [31:0] an_wr_log [0:15];
    int          an_wr_cnt = 0;

    always_ff @(posedge clk) begin
        if (an_wr_en) begin
            an_wr_log[an_wr_cnt[3:0]] <= an_wr_data;
            an_wr_cnt                 <= an_wr_cnt + 1;
        end
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;
    int base_cnt;

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

    // Poll-for-ack runner (for standard instructions)
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
        repeat(5) @(posedge clk);
    endtask

    // One-shot runner for multi-cycle FSM instructions (MOVEM/MOVEP/MOVE16).
    // Presents instr_valid for exactly ONE clock edge to prevent double-trigger
    // of the FSM when instr_ack and instr_valid overlap.
    task automatic run_oneshot(input logic [15:0] w0,
                                input logic [31:0] ext,
                                input int          drain_cyc);
        @(posedge clk);
        instr_word  = w0;
        ext_data    = ext;
        instr_valid = 1'b1;
        ext_valid   = 1'b1;
        @(posedge clk);
        instr_valid = 1'b0;
        ext_valid   = 1'b0;
        repeat(drain_cyc) @(posedge clk);
    endtask

    task automatic run_movem(input logic [15:0] op, input logic [15:0] mask,
                              input int n_regs);
        run_oneshot(op, {16'h0, mask}, n_regs + 6);
    endtask

    task automatic run_movep(input logic [15:0] op, input logic [15:0] disp,
                              input int n_bytes);
        run_oneshot(op, {16'h0, disp}, n_bytes + 8);
    endtask

    task automatic run_move16(input logic [15:0] op, input logic [31:0] imm,
                               input int extra_cycles);
        run_oneshot(op, imm, 1 + 8 + extra_cycles);
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
        @(posedge clk);
        ssp_wr_data = val; ssp_wr_en = 1;
        @(posedge clk);
        ssp_wr_en = 0;
        repeat(2) @(posedge clk);
    endtask

    // ─── MOVEM tests (seq43) ──────────────────────────────────────────────────
    task automatic test_movem();
        $display("--- MOVEM ---");
        for (int i = 0; i < 2048; i++) ram[i] = 32'hDEAD_BEEF;

        // MOVEM.L {D0,D1,D2},-(A0) predecrement store
        // A0=0x30; writes D2→0x2C, D1→0x28, D0→0x24; A0_new=0x24
        set_an(3'd0, 32'h0000_0030);
        set_dn(0, 32'hAAAA_0000);
        set_dn(1, 32'hBBBB_0001);
        set_dn(2, 32'hCCCC_0002);
        run_movem(16'h48E0, 16'hE000, 3);
        chk("M43-1 mem[0x24]=D0", ram[32'h24>>2],   32'hAAAA_0000);
        chk("M43-1 mem[0x28]=D1", ram[32'h28>>2],   32'hBBBB_0001);
        chk("M43-1 mem[0x2C]=D2", ram[32'h2C>>2],   32'hCCCC_0002);
        chk("M43-1 A0_new=0x24",  `AR(0),            32'h0000_0024);

        // MOVEM.L (A0)+,{D0,D1,D2} post-increment load
        // A0=0x40; reads D0←M[0x40], D1←M[0x44], D2←M[0x48]; A0_new=0x4C
        ram[32'h40>>2] = 32'h1111_1111;
        ram[32'h44>>2] = 32'h2222_2222;
        ram[32'h48>>2] = 32'h3333_3333;
        set_an(3'd0, 32'h0000_0040);
        run_movem(16'h4CD8, 16'h0007, 3);
        chk("M43-2 D0", `DR(0), 32'h1111_1111);
        chk("M43-2 D1", `DR(1), 32'h2222_2222);
        chk("M43-2 D2", `DR(2), 32'h3333_3333);
        chk("M43-2 A0_new=0x4C", `AR(0), 32'h0000_004C);

        // MOVEM.L {A1,A2},-(A3) predec store of A registers
        // A3=0x50; writes A2→0x4C, A1→0x48; A3_new=0x48
        set_an(3'd1, 32'hA1A1_A1A1);
        set_an(3'd2, 32'hA2A2_A2A2);
        set_an(3'd3, 32'h0000_0050);
        run_movem(16'h48E3, 16'h0060, 2);
        chk("M43-3 mem[0x48]=A1", ram[32'h48>>2], 32'hA1A1_A1A1);
        chk("M43-3 mem[0x4C]=A2", ram[32'h4C>>2], 32'hA2A2_A2A2);
        chk("M43-3 A3_new=0x48",  `AR(3),          32'h0000_0048);

        // MOVEM.L (A1),{D5} fixed (An) load, no An update
        ram[32'h80>>2] = 32'h5555_5555;
        set_an(3'd1, 32'h0000_0080);
        run_movem(16'h4CD1, 16'h0020, 1);
        chk("M43-4 D5",        `DR(5),  32'h5555_5555);
        chk("M43-4 A1 unchanged", `AR(1), 32'h0000_0080);

        // MOVEM.L {D3},(A2) fixed (An) store, no An update
        set_dn(3, 32'hFACE_BEEF);
        set_an(3'd2, 32'h0000_00C0);
        run_movem(16'h48D2, 16'h0008, 1);
        chk("M43-5 mem[0xC0]=D3", ram[32'hC0>>2], 32'hFACE_BEEF);
        chk("M43-5 A2 unchanged", `AR(2),           32'h0000_00C0);

        // MOVEM.W (A0)+,{D4,D5} word load with sign-extension
        // extract_rd for lo=00 returns raw[31:16]; lo=10 returns raw[15:0]
        // Both reads map to same longword; set both halves to 0x8001 for sign-ext
        ram[32'h100>>2] = 32'h8001_8001;
        set_an(3'd0, 32'h0000_0100);
        run_movem(16'h4C98, 16'h0030, 2);
        chk("M43-6 D4 sign-ext", `DR(4), 32'hFFFF_8001);
        chk("M43-6 D5 sign-ext", `DR(5), 32'hFFFF_8001);
        chk("M43-6 A0_new=0x104", `AR(0), 32'h0000_0104);

        // MOVEM.L {D4-D7},-(A7) 4-reg predec to ISP
        // ISP=0x200; D7→0x1FC, D6→0x1F8, D5→0x1F4, D4→0x1F0; ISP_new=0x1F0
        set_dn(4, 32'h0000_0004);
        set_dn(5, 32'h0000_0005);
        set_dn(6, 32'h0000_0006);
        set_dn(7, 32'h0000_0007);
        set_isp(32'h0000_0200);
        run_movem(16'h48E7, 16'h0F00, 4);
        chk("M43-7 mem[0x1F0]=D4", ram[32'h1F0>>2], 32'h0000_0004);
        chk("M43-7 mem[0x1F4]=D5", ram[32'h1F4>>2], 32'h0000_0005);
        chk("M43-7 mem[0x1F8]=D6", ram[32'h1F8>>2], 32'h0000_0006);
        chk("M43-7 mem[0x1FC]=D7", ram[32'h1FC>>2], 32'h0000_0007);
        chk("M43-7 ISP_new=0x1F0", isp_out,          32'h0000_01F0);

        // MOVEM.L (A7)+,{D4-D7} restore D4-D7 from stack
        set_dn(4, 32'h0); set_dn(5, 32'h0); set_dn(6, 32'h0); set_dn(7, 32'h0);
        set_isp(32'h0000_01F0);
        run_movem(16'h4CDF, 16'h00F0, 4);
        chk("M43-8 D4", `DR(4), 32'h0000_0004);
        chk("M43-8 D5", `DR(5), 32'h0000_0005);
        chk("M43-8 D6", `DR(6), 32'h0000_0006);
        chk("M43-8 D7", `DR(7), 32'h0000_0007);
        chk("M43-8 ISP_new=0x200", isp_out, 32'h0000_0200);
    endtask

    // ─── MOVEP tests (seq49) ──────────────────────────────────────────────────
    // Memory uses byte-selective model. Byte at byte-addr A lives in:
    //   A[1:0]=00 → ram[A>>2][31:24], A[1:0]=01 → [23:16], 10 → [15:8], 11 → [7:0]
    task automatic test_movep();
        $display("--- MOVEP ---");
        for (int i = 0; i < 2048; i++) ram[i] = 32'h0;

        // Test 1: MOVEP.W D1,(0,A0) store word (2 bytes)
        // D1=0x1234_5678; lower word 0x5678: byte 0x56@A0+0, byte 0x78@A0+2
        // A0=0x100; 0x100: lo=00→[31:24]; 0x102: lo=10→[15:8]
        // Opcode: DDD=001,f_ss=10,001,AAA=000 = 0x0388
        set_an(3'd0, 32'h0000_0100);
        set_dn(1, 32'h1234_5678);
        run_movep(16'h0388, 16'h0000, 2);
        chk("byte0@0x100", {24'h0, ram[32'h100>>2][31:24]}, 32'h56);
        chk("byte1@0x102", {24'h0, ram[32'h100>>2][15:8]},  32'h78);
        chk("0x101=0",     {24'h0, ram[32'h100>>2][23:16]}, 32'h00);
        chk("0x103=0",     {24'h0, ram[32'h100>>2][7:0]},   32'h00);

        // Test 2: MOVEP.L D1,(0,A0) store longword (4 bytes)
        // D1=0xAABBCCDD; bytes AA@0x200, BB@0x202, CC@0x204, DD@0x206
        // Opcode: f_ss=11 = 0x03C8
        set_an(3'd0, 32'h0000_0200);
        set_dn(1, 32'hAABBCCDD);
        run_movep(16'h03C8, 16'h0000, 4);
        chk("AA@0x200", {24'h0, ram[32'h200>>2][31:24]}, 32'hAA);
        chk("BB@0x202", {24'h0, ram[32'h200>>2][15:8]},  32'hBB);
        chk("CC@0x204", {24'h0, ram[32'h204>>2][31:24]}, 32'hCC);
        chk("DD@0x206", {24'h0, ram[32'h204>>2][15:8]},  32'hDD);
        chk("0x201=0",  {24'h0, ram[32'h200>>2][23:16]}, 32'h00);
        chk("0x203=0",  {24'h0, ram[32'h200>>2][7:0]},   32'h00);

        // Test 3: MOVEP.W (0,A0),D1 load word from 0x300; pre-init bytes
        // D1=0xFFFF_0000 (upper half should be preserved)
        // Opcode: f_ss=00 = 0x0308
        ram[32'h300>>2] = {8'hAB, 8'h00, 8'hCD, 8'h00};
        set_an(3'd0, 32'h0000_0300);
        set_dn(1, 32'hFFFF_0000);
        run_movep(16'h0308, 16'h0000, 2);
        chk("D1 word load", `DR(1), 32'hFFFF_ABCD);

        // Test 4: MOVEP.L (0,A0),D1 load longword from 0x400
        // Opcode: f_ss=01 = 0x0348
        ram[32'h400>>2] = {8'h11, 8'h00, 8'h22, 8'h00};
        ram[32'h404>>2] = {8'h33, 8'h00, 8'h44, 8'h00};
        set_an(3'd0, 32'h0000_0400);
        set_dn(1, 32'hDEAD_BEEF);
        run_movep(16'h0348, 16'h0000, 4);
        chk("D1 lw load", `DR(1), 32'h11223344);

        // Test 5: MOVEP.W D2,(4,A1) with non-zero displacement
        // D2=0x0000_AABB; A1=0x500; writes 0xAA@0x504, 0xBB@0x506
        // Opcode: DDD=010,f_ss=10,001,AAA=001 = 0x0589
        set_an(3'd1, 32'h0000_0500);
        set_dn(2, 32'h0000_AABB);
        run_movep(16'h0589, 16'h0004, 2);
        chk("AA@0x504", {24'h0, ram[32'h504>>2][31:24]}, 32'hAA);
        chk("BB@0x506", {24'h0, ram[32'h504>>2][15:8]},  32'hBB);
        chk("A1 unchanged", `AR(1), 32'h0000_0500);

        // Test 6: MOVEP.L D0,(-8,A0) negative displacement
        // D0=0x11223344; A0=0x610; writes to 0x608, 0x60A, 0x60C, 0x60E
        // Opcode: DDD=000,f_ss=11,001,AAA=000 = 0x01C8
        set_an(3'd0, 32'h0000_0610);
        set_dn(0, 32'h11223344);
        run_movep(16'h01C8, 16'hFFF8, 4);
        chk("11@0x608", {24'h0, ram[32'h608>>2][31:24]}, 32'h11);
        chk("22@0x60A", {24'h0, ram[32'h608>>2][15:8]},  32'h22);
        chk("33@0x60C", {24'h0, ram[32'h60C>>2][31:24]}, 32'h33);
        chk("44@0x60E", {24'h0, ram[32'h60C>>2][15:8]},  32'h44);

        // Test 7: Round-trip store then load
        // Store D3=0xCAFEBABE via MOVEP.L, load back into D4
        // Store opcode: DDD=011,f_ss=11,001,000 = 0x07C8
        // Load  opcode: DDD=100,f_ss=01,001,000 = 0x0948
        set_an(3'd0, 32'h0000_0700);
        set_dn(3, 32'hCAFEBABE);
        run_movep(16'h07C8, 16'h0000, 4);
        set_dn(4, 32'h0);
        run_movep(16'h0948, 16'h0000, 4);
        chk("round-trip D4", `DR(4), 32'hCAFEBABE);
    endtask

    // ─── MOVE16 tests (seq50) ─────────────────────────────────────────────────
    task automatic test_move16();
        $display("--- MOVE16 ---");
        for (int i = 0; i < 2048; i++) ram[i] = 32'h0;

        // Helper: load 4 longwords at byte address base
        // Helper: verify 4 longwords at byte address base
        // (inlined per test for clarity)

        // Note: parentheses required — >> has lower precedence than + in SV.

        // Test 1: MOVE16 (A0)+,(xxx).L  src=A0=0x100, dst=abs 0x200; A0+=16
        // Opcode: f_mode=010, nnn=000 = 0xF210; ext_data=abs dst=0x200
        ram[(32'h100>>2)+0] = 32'hAABBCCDD;
        ram[(32'h100>>2)+1] = 32'h11223344;
        ram[(32'h100>>2)+2] = 32'hDEADBEEF;
        ram[(32'h100>>2)+3] = 32'hCAFEBABE;
        set_an(3'd0, 32'h0000_0100);
        run_move16(16'hF210, 32'h0000_0200, 8);
        chk("M16-1 dst[0]", ram[(32'h200>>2)+0], 32'hAABBCCDD);
        chk("M16-1 dst[1]", ram[(32'h200>>2)+1], 32'h11223344);
        chk("M16-1 dst[2]", ram[(32'h200>>2)+2], 32'hDEADBEEF);
        chk("M16-1 dst[3]", ram[(32'h200>>2)+3], 32'hCAFEBABE);
        chk("M16-1 A0+=16", `AR(0),               32'h0000_0110);

        // Test 2: MOVE16 (xxx).L,(A0)+  src=abs 0x300, dst=A0=0x400; A0+=16
        // Opcode: f_mode=011, nnn=000 = 0xF218; ext_data=abs src=0x300
        ram[(32'h300>>2)+0] = 32'h12345678;
        ram[(32'h300>>2)+1] = 32'h9ABCDEF0;
        ram[(32'h300>>2)+2] = 32'hFEDCBA98;
        ram[(32'h300>>2)+3] = 32'h87654321;
        set_an(3'd0, 32'h0000_0400);
        run_move16(16'hF218, 32'h0000_0300, 8);
        chk("M16-2 dst[0]", ram[(32'h400>>2)+0], 32'h12345678);
        chk("M16-2 dst[1]", ram[(32'h400>>2)+1], 32'h9ABCDEF0);
        chk("M16-2 dst[2]", ram[(32'h400>>2)+2], 32'hFEDCBA98);
        chk("M16-2 dst[3]", ram[(32'h400>>2)+3], 32'h87654321);
        chk("M16-2 A0+=16", `AR(0),               32'h0000_0410);

        // Test 3: MOVE16 (A0)+,(A1)+  src=A0=0x500, dst=A1=0x600; both+=16
        // Opcode: f_mode=001, nnn=000 = 0xF208; ext word Am=A1 → 0x9000
        ram[(32'h500>>2)+0] = 32'hAAAA0000;
        ram[(32'h500>>2)+1] = 32'hBBBB1111;
        ram[(32'h500>>2)+2] = 32'hCCCC2222;
        ram[(32'h500>>2)+3] = 32'hDDDD3333;
        set_an(3'd0, 32'h0000_0500);
        set_an(3'd1, 32'h0000_0600);
        run_move16(16'hF208, 32'h0000_9000, 8);
        chk("M16-3 dst[0]", ram[(32'h600>>2)+0], 32'hAAAA0000);
        chk("M16-3 dst[1]", ram[(32'h600>>2)+1], 32'hBBBB1111);
        chk("M16-3 dst[2]", ram[(32'h600>>2)+2], 32'hCCCC2222);
        chk("M16-3 dst[3]", ram[(32'h600>>2)+3], 32'hDDDD3333);
        chk("M16-3 A0+=16", `AR(0),               32'h0000_0510);
        chk("M16-3 A1+=16", `AR(1),               32'h0000_0610);

        // Test 4: MOVE16 (A0),(A1)  no postincrement
        // Opcode: f_mode=000, nnn=000 = 0xF200; ext word Am=A1 → 0x9000
        ram[(32'h700>>2)+0] = 32'h11112222;
        ram[(32'h700>>2)+1] = 32'h33334444;
        ram[(32'h700>>2)+2] = 32'h55556666;
        ram[(32'h700>>2)+3] = 32'h77778888;
        set_an(3'd0, 32'h0000_0700);
        set_an(3'd1, 32'h0000_0780);
        run_move16(16'hF200, 32'h0000_9000, 8);
        chk("M16-4 dst[0]",       ram[(32'h780>>2)+0], 32'h11112222);
        chk("M16-4 dst[1]",       ram[(32'h780>>2)+1], 32'h33334444);
        chk("M16-4 dst[2]",       ram[(32'h780>>2)+2], 32'h55556666);
        chk("M16-4 dst[3]",       ram[(32'h780>>2)+3], 32'h77778888);
        chk("M16-4 A0 unchanged", `AR(0),               32'h0000_0700);
        chk("M16-4 A1 unchanged", `AR(1),               32'h0000_0780);
    endtask

    // ─── MOVE mem→mem tests (seq67) ───────────────────────────────────────────
    task automatic test_move_mm();
        $display("--- MOVE mem-to-mem ---");
        for (int i = 0; i < 2048; i++) ram[i] = 32'h0;
        an_wr_cnt = 0;

        // Pre-load known patterns
        ram[32'h100>>2] = 32'hDEAD_BEEF;
        ram[32'h104>>2] = 32'h1234_5678;
        ram[32'h108>>2] = 32'hCAFE_BABE;
        ram[32'h1C0>>2] = 32'hFEED_FACE;

        // MOVE.L (A0),(A1) basic indirect
        // opcode: group=2, dst_reg=1(A1), dst_mode=010, src_mode=010, src_reg=0(A0)
        // = 0010_001_010_010_000 = 0x2290
        $display("--- MOVE.L (A0),(A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0200);
        run_instr(16'h2290, 1'b0, 32'h0);
        chk("MM67-01 mem",  ram[32'h200>>2], 32'hDEAD_BEEF);
        chk_ccr("MM67-01",  1'b1, 1'b0, 1'b0, 1'b0);

        // MOVE.L (A0)+,(A1)+ postincrement both
        // opcode: 0010_001_011_011_000 = 0x22D8
        // dst A1 updates first (at write ack), src A0 from WB
        $display("--- MOVE.L (A0)+,(A1)+ ---");
        set_an(3'd0, 32'h0000_0104);
        set_an(3'd1, 32'h0000_0204);
        base_cnt = an_wr_cnt;
        run_instr(16'h22D8, 1'b0, 32'h0);
        chk("MM67-02 mem",  ram[32'h204>>2],              32'h1234_5678);
        chk_ccr("MM67-02",  1'b0, 1'b0, 1'b0, 1'b0);
        chk("MM67-02 A1",   an_wr_log[(base_cnt)   % 16], 32'h0000_0208);
        chk("MM67-02 A0",   an_wr_log[(base_cnt+1) % 16], 32'h0000_0108);

        // MOVE.L -(A0),(A1) src predecrement
        // opcode: 0010_001_010_100_000 = 0x22A0; A0=0x108→EA=0x104
        $display("--- MOVE.L -(A0),(A1) ---");
        set_an(3'd0, 32'h0000_0108);
        set_an(3'd1, 32'h0000_0308);
        base_cnt = an_wr_cnt;
        run_instr(16'h22A0, 1'b0, 32'h0);
        chk("MM67-03 mem",  ram[32'h308>>2],              32'h1234_5678);
        chk("MM67-03 A0",   an_wr_log[base_cnt % 16],     32'h0000_0104);
        chk_ccr("MM67-03",  1'b0, 1'b0, 1'b0, 1'b0);

        // MOVE.L (A0),-(A1) dst predecrement
        // opcode: 0010_001_100_010_000 = 0x2310; A1=0x030C→EA=0x0308
        $display("--- MOVE.L (A0),-(A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_030C);
        base_cnt = an_wr_cnt;
        run_instr(16'h2310, 1'b0, 32'h0);
        chk("MM67-04 mem",  ram[32'h308>>2],              32'hDEAD_BEEF);
        chk("MM67-04 A1",   an_wr_log[base_cnt % 16],     32'h0000_0308);
        chk_ccr("MM67-04",  1'b1, 1'b0, 1'b0, 1'b0);

        // MOVE.W (d16,A0),(d16,A1) dual displacement, 2 ext words
        // opcode: 0011_001_101_101_000 = 0x3368; ext={src_d16=0x0004, dst_d16=0x0008}
        // src: 0x0100+4=0x0104; value=0x1234_5678; EU reads upper word 0x1234
        $display("--- MOVE.W (d16,A0),(d16,A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0200);
        run_instr(16'h3368, 1'b1, {16'h0004, 16'h0008});
        chk("MM67-05 mem",  ram[32'h208>>2], 32'h1234_0000);
        chk_ccr("MM67-05",  1'b0, 1'b0, 1'b0, 1'b0);

        // MOVE.L (xxx).L,(A1) abs.L src, 2 ext words
        // opcode: 0010_001_010_111_001 = 0x22B9; ext={0x0000, 0x01C0}
        $display("--- MOVE.L (xxx).L,(A1) ---");
        set_an(3'd1, 32'h0000_0400);
        run_instr(16'h22B9, 1'b1, {16'h0000, 16'h01C0});
        chk("MM67-06 mem",  ram[32'h400>>2], 32'hFEED_FACE);
        chk_ccr("MM67-06",  1'b1, 1'b0, 1'b0, 1'b0);

        // MOVE.L (A0),(xxx).W abs.W dst; data=0 → Z=1
        // opcode: 0010_000_111_010_000 = 0x21D0; ext={16'h0, 0x0500}
        $display("--- MOVE.L (A0),(xxx).W ---");
        ram[32'h120>>2] = 32'h0000_0000;
        set_an(3'd0, 32'h0000_0120);
        run_instr(16'h21D0, 1'b1, {16'h0, 16'h0500});
        chk("MM67-07 mem",  ram[32'h500>>2], 32'h0000_0000);
        chk_ccr("MM67-07",  1'b0, 1'b1, 1'b0, 1'b0);
    endtask

    // ─── Main ─────────────────────────────────────────────────────────────────
    initial begin
        @(posedge rst_n); repeat(2) @(posedge clk);

        test_movem();
        test_movep();
        test_move16();
        test_move_mm();

        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("PASS data_move (%0d checks)", pass_cnt);
        else
            $display("FAIL data_move: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL data_move: hard timeout");
        $finish;
    end

endmodule

`default_nettype wire

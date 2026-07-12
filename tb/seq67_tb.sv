// Phase 67: MOVE (src_ea),(dst_ea) — memory-to-memory forms
//   Part A: Groups 1/2/3, both src and dst are memory EA.
//   2-phase FSM: read src → capture data → write to dst.
//
//   P67-01: MOVE.L (A0),(A1)          — basic indirect, no ext
//   P67-02: MOVE.L (A0)+,(A1)+        — postincrement both (An update check)
//   P67-03: MOVE.L -(A0),(A1)         — src predecrement (An update check)
//   P67-04: MOVE.L (A0),-(A1)         — dst predecrement (An update check)
//   P67-05: MOVE.W (d16,A0),(d16,A1)  — dual d16 displacement (2 ext words)
//   P67-06: MOVE.L (xxx).L,(A1)       — abs.L src (2 ext words)
//   P67-07: MOVE.L (A0),(xxx).W       — abs.W dst (1 ext word, zero data Z=1)
`default_nettype none
`timescale 1ns/1ps

module seq67_tb;

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

    logic        ssp_wr_en    = 0;
    logic [31:0] ssp_wr_data  = 32'h0;
    logic        exc_sr_wr_en = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu u_dut (
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
        .ssp_wr_en       (ssp_wr_en),
        .ssp_wr_data     (ssp_wr_data),
        .exc_sr_wr_en    (exc_sr_wr_en),
        .exc_sr_wr_data  (exc_sr_wr_data)
    );

    // ─── Memory model (combinatorial ack, 8K x 32) ───────────────────────────
    logic [31:0] ram [0:8191];

    assign mem_ack   = mem_req;
    assign mem_rdata = (mem_req && mem_rw) ? ram[mem_addr[14:2]] : 32'h0;

    always_ff @(posedge clk) begin
        if (mem_req && !mem_rw)
            ram[mem_addr[14:2]] <= mem_wdata;
    end

    // ─── An write logger ─────────────────────────────────────────────────────
    logic [31:0] an_wr_log [0:15];
    logic [2:0]  an_sel_log [0:15];
    int          an_wr_cnt;

    always_ff @(posedge clk) begin
        if (an_wr_en) begin
            an_wr_log[an_wr_cnt[3:0]] <= an_wr_data;
            an_sel_log[an_wr_cnt[3:0]] <= an_wr_sel;
            an_wr_cnt                  <= an_wr_cnt + 1;
        end
    end

    // ─── Helpers ──────────────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;
    int base_cnt;  // snapshot of an_wr_cnt before each multi-An instruction

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

    task automatic chk_ccr(input string tag,
                            input logic exp_n, exp_z, exp_v, exp_c);
        chk1({tag, ":N"}, sr_out[3], exp_n);
        chk1({tag, ":Z"}, sr_out[2], exp_z);
        chk1({tag, ":V"}, sr_out[1], exp_v);
        chk1({tag, ":C"}, sr_out[0], exp_c);
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
        repeat(12) @(posedge clk);
    endtask

    task automatic set_dn(input int n, input logic [31:0] val);
        run_instr(16'h4280 | (16'(n) & 16'h7), 1'b0, 32'h0);
        run_instr(16'h0680 | (16'(n) & 16'h7), 1'b1, val);
    endtask

    task automatic set_an(input logic [2:0] an, input logic [31:0] val);
        set_dn(0, val);
        run_instr({4'h2, an, 3'b001, 3'b000, 3'b000}, 1'b0, 32'h0);
    endtask

    // ─── MOVE.L encoding helpers ──────────────────────────────────────────────
    // MOVE.L (src_mode,src_reg),(dst_mode,dst_reg)
    // Groups: 1=byte, 2=long, 3=word
    function automatic logic [15:0] mov(
        input logic [3:0] grp,
        input logic [2:0] dst_reg, dst_mode, src_mode, src_reg);
        mov = {grp, dst_reg, dst_mode, src_mode, src_reg};
    endfunction

    // ─── Test body ────────────────────────────────────────────────────────────
    initial begin
        for (int i = 0; i < 8192; i++) ram[i] = 32'h0;
        an_wr_cnt = 0;
        @(posedge rst_n); repeat(2) @(posedge clk);

        // Pre-load memory with known patterns
        // 0x0100 (idx 0x40=64): 0xDEAD_BEEF
        // 0x0104 (idx 0x41=65): 0x1234_5678
        // 0x0108 (idx 0x42=66): 0xCAFE_BABE
        // 0x01C0 (idx 0x70=112): 0xFEED_FACE (for abs.L test)
        ram[64]  = 32'hDEAD_BEEF;
        ram[65]  = 32'h1234_5678;
        ram[66]  = 32'hCAFE_BABE;
        ram[112] = 32'hFEED_FACE;

        // ==================================================================
        // P67-01: MOVE.L (A0),(A1) — basic indirect
        //   opcode: group=2, dst_reg=1(A1), dst_mode=010, src_mode=010, src_reg=0(A0)
        //   = 0010_001_010_010_000 = 0x2290
        //   A0=0x0100→read 0xDEAD_BEEF, A1=0x0200→write
        //   CCR: N=1 (bit31=1), Z=0, V=0, C=0
        // ==================================================================
        $display("--- P67-01: MOVE.L (A0),(A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0200);
        run_instr(16'h2290, 1'b0, 32'h0);
        chk("P67-01:mem",  ram[32'h200>>2], 32'hDEAD_BEEF);
        chk_ccr("P67-01",  1'b1, 1'b0, 1'b0, 1'b0);  // N=1 (DEAD bit31=1)

        // ==================================================================
        // P67-02: MOVE.L (A0)+,(A1)+ — postincrement both An
        //   opcode: group=2, dst_reg=1(A1), dst_mode=011(postinc), src_mode=011, src_reg=0(A0)
        //   = 0010_001_011_011_000 = 0x22D8
        //   A0=0x0104→read 0x1234_5678, A1=0x0204→write
        //   Dst An A1 updated to 0x0208 (fires at write ack via move_mm_dst_an_wr_en)
        //   Src An A0 updated to 0x0108 (fires from WB 2 cycles later)
        // ==================================================================
        $display("--- P67-02: MOVE.L (A0)+,(A1)+ ---");
        set_an(3'd0, 32'h0000_0104);
        set_an(3'd1, 32'h0000_0204);
        base_cnt = an_wr_cnt;
        run_instr(16'h22D8, 1'b0, 32'h0);
        chk("P67-02:mem",  ram[32'h204>>2],         32'h1234_5678);
        chk_ccr("P67-02",  1'b0, 1'b0, 1'b0, 1'b0); // N=0, Z=0
        // dst An fires first (at write ack), src An fires from WB (+2 clocks)
        chk("P67-02:A1",   an_wr_log[(base_cnt)   % 16], 32'h0000_0208);
        chk("P67-02:A0",   an_wr_log[(base_cnt+1) % 16], 32'h0000_0108);

        // ==================================================================
        // P67-03: MOVE.L -(A0),(A1) — src predecrement
        //   opcode: group=2, dst_reg=1(A1), dst_mode=010(indirect), src_mode=100(predec), src_reg=0(A0)
        //   = 0010_001_010_100_000 = 0x22A0
        //   A0=0x0108: EA=0x0104, A0→0x0104 (src An update in WB)
        //   A1=0x0308→write dest
        // ==================================================================
        $display("--- P67-03: MOVE.L -(A0),(A1) ---");
        set_an(3'd0, 32'h0000_0108);
        set_an(3'd1, 32'h0000_0308);
        base_cnt = an_wr_cnt;
        run_instr(16'h22A0, 1'b0, 32'h0);
        chk("P67-03:mem",  ram[32'h308>>2],         32'h1234_5678); // value at 0x104
        // no dst An update (simple (A1)); src An (A0) updates in WB
        chk("P67-03:A0",   an_wr_log[base_cnt % 16], 32'h0000_0104);
        chk_ccr("P67-03",  1'b0, 1'b0, 1'b0, 1'b0);

        // ==================================================================
        // P67-04: MOVE.L (A0),-(A1) — dst predecrement
        //   opcode: group=2, dst_reg=1(A1), dst_mode=100(predec), src_mode=010(indirect), src_reg=0(A0)
        //   = 0010_001_100_010_000 = 0x2310
        //   A1=0x030C: dst EA=0x0308, A1→0x0308 (dst An update at write ack)
        //   A0=0x0100→read 0xDEAD_BEEF
        // ==================================================================
        $display("--- P67-04: MOVE.L (A0),-(A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_030C);
        base_cnt = an_wr_cnt;
        run_instr(16'h2310, 1'b0, 32'h0);
        chk("P67-04:mem",  ram[32'h308>>2],         32'hDEAD_BEEF); // at 0x308 (predec target)
        chk("P67-04:A1",   an_wr_log[base_cnt % 16], 32'h0000_0308); // A1 → 0x030C-4
        chk_ccr("P67-04",  1'b1, 1'b0, 1'b0, 1'b0); // N=1

        // ==================================================================
        // P67-05: MOVE.W (d16,A0),(d16,A1) — dual displacement, 2 ext words
        //   opcode: group=3, dst_reg=1(A1), dst_mode=101(d16,An), src_mode=101(d16,An), src_reg=0(A0)
        //   = 0011_001_101_101_000 = 0x3368
        //   ext_data = {src_d16=0x0004, dst_d16=0x0008}
        //   A0=0x0100: src addr=0x0104, A1=0x0200: dst addr=0x0208
        //   Value at 0x104: 0x1234_5678, word: mem_rdata[15:0]=0x5678 → N(15)=0
        // ==================================================================
        $display("--- P67-05: MOVE.W (d16,A0),(d16,A1) ---");
        set_an(3'd0, 32'h0000_0100);
        set_an(3'd1, 32'h0000_0200);
        run_instr(16'h3368, 1'b1, {16'h0004, 16'h0008});
        chk("P67-05:mem",  ram[32'h208>>2], 32'h1234_5678); // full lword written
        chk_ccr("P67-05",  1'b0, 1'b0, 1'b0, 1'b0); // N=0 (mem_rdata[15]=0x5678[15]=0)

        // ==================================================================
        // P67-06: MOVE.L (xxx).L,(A1) — abs.L src, 2 ext words
        //   opcode: group=2, dst_reg=1(A1), dst_mode=010(indirect), src_mode=111(abs), src_reg=001(abs.L)
        //   = 0010_001_010_111_001 = 0x22B9
        //   ext_data = {0x0000, 0x01C0} = full abs.L address 0x000001C0
        //   A1=0x0400→write dest; src at 0x01C0 contains 0xFEED_FACE
        // ==================================================================
        $display("--- P67-06: MOVE.L (xxx).L,(A1) ---");
        set_an(3'd1, 32'h0000_0400);
        run_instr(16'h22B9, 1'b1, {16'h0000, 16'h01C0});
        chk("P67-06:mem",  ram[32'h400>>2], 32'hFEED_FACE);
        chk_ccr("P67-06",  1'b1, 1'b0, 1'b0, 1'b0); // N=1 (0xFEED_FACE bit31=1)

        // ==================================================================
        // P67-07: MOVE.L (A0),(xxx).W — abs.W dst, 1 ext word; data=0 → Z=1
        //   opcode: group=2, dst_reg=000(abs.W f_dn=000), dst_mode=111, src_mode=010, src_reg=0(A0)
        //   = 0010_000_111_010_000 = 0x21D0
        //   ext_data = {16'h0, 0x0500} → abs.W dst = 0x0000_0500
        //   A0=0x0500 region pre-loaded with 0; also write 0 to 0x0500
        //   Use a source address that we already know contains 0 (cleared ram slot)
        // ==================================================================
        $display("--- P67-07: MOVE.L (A0),(xxx).W ---");
        ram[32'h120>>2] = 32'h0000_0000; // explicit zero for Z test
        set_an(3'd0, 32'h0000_0120);     // src at 0x120 = 0
        run_instr(16'h21D0, 1'b1, {16'h0, 16'h0500});
        chk("P67-07:mem",  ram[32'h500>>2], 32'h0000_0000); // zero written to abs.W dest
        chk_ccr("P67-07",  1'b0, 1'b1, 1'b0, 1'b0); // N=0, Z=1

        // ─── Summary ──────────────────────────────────────────────────────────
        $display("");
        if (fail_cnt == 0)
            $display("pass  seq67 (%0d checks)", pass_cnt);
        else
            $display("FAIL  seq67: %0d/%0d checks failed", fail_cnt, pass_cnt+fail_cnt);
        $finish;
    end

endmodule

// Phase 56: OS control instructions
//   MOVE SR/CCR/USP, RTE, STOP, TRAP #n, TRAPV, ILLEGAL

`default_nettype none
`timescale 1ns/1ps

module seq56_tb;

    // ─── clock / reset ───────────────────────────────────────────────────────
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n = 0;
    initial begin
        repeat(4) @(posedge clk);
        rst_n = 1;
    end

    // ─── EU ports ────────────────────────────────────────────────────────────
    logic [15:0] instr_word;
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

    logic [31:0] decode_pc = 32'h0;
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
    logic        mem_berr   = 0;
    logic        mem_rmw;

    logic        eu_coproc_req;
    logic        eu_coproc_rw;
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
    logic        ssp_wr_en   = 0;
    logic [31:0] ssp_wr_data = 32'h0;
    logic        exc_sr_wr_en   = 0;
    logic [15:0] exc_sr_wr_data = 16'h0;

    // Phase 56 outputs
    logic        eu_trap_req;
    logic [3:0]  eu_trap_num;
    logic        eu_trapv_req;
    logic        eu_illegal_req;
    logic        eu_stop;

    // ─── DUT ─────────────────────────────────────────────────────────────────
    m68030_eu dut (
        .clk_4x         (clk),
        .rst_n          (rst_n),
        .instr_word     (instr_word),
        .instr_valid    (instr_valid),
        .ext_data       (ext_data),
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
        .ssp_wr_en      (ssp_wr_en),
        .ssp_wr_data    (ssp_wr_data),
        .exc_sr_wr_en   (exc_sr_wr_en),
        .exc_sr_wr_data (exc_sr_wr_data)
    );

    // ─── memory model ────────────────────────────────────────────────────────
    // Combinational ack model (matches all other seq testbenches).
    // rte_mode: route reads by mem_addr for RTE test.
    logic        rte_mode = 0;
    logic [31:0] mem_rdata_reg = 32'hDEAD_BEEF;

    always_comb begin
        if (mem_req && mem_rw) begin  // read
            mem_ack = 1'b1;
            if (rte_mode) begin
                // RTE stack frame: SR longword at A7=0x1000, PC longword at A7+4=0x1004
                case (mem_addr[11:0])
                    12'h000: mem_rdata = 32'h0000_2700;  // {vector/fmt, SR} at A7
                    12'h004: mem_rdata = 32'h0000_2000;  // PC at A7+4
                    default: mem_rdata = mem_rdata_reg;
                endcase
            end else begin
                mem_rdata = mem_rdata_reg;
            end
        end else begin
            mem_ack   = 1'b0;
            mem_rdata = 32'h0;
        end
    end

    // ─── test utilities ──────────────────────────────────────────────────────
    int pass_cnt = 0, fail_cnt = 0;

    task automatic chk(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", tag, got, exp);
            fail_cnt++;
        end else begin
            $display("PASS %s", tag);
            pass_cnt++;
        end
    endtask

    task automatic chk1(input string tag, input logic got, exp);
        chk(tag, {31'h0, got}, {31'h0, exp});
    endtask

    // Present an instruction and wait for instr_ack.  Timeout at 200 cycles.
    task automatic issue_wait(input logic [15:0] w0,
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
        @(posedge clk);
    endtask

    // ─── test body ───────────────────────────────────────────────────────────
    initial begin
        $timeformat(-9, 0, " ns", 10);
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // ====================================================================
        // P56-1: MOVE SR,D0  ($40C0)
        // At reset SR = 0x2700 (supervisor, IPL=7).
        // After execute D0 = 0x2700.
        // ====================================================================
        $display("--- P56-1: MOVE SR,D0 ---");
        issue_wait(16'h40C0, 1'b0, 32'h0);
        repeat(4) @(posedge clk);
        chk("P56-1: D0 = initial SR (0x2700)", dut.u_rf.d_reg[0], 32'h0000_2700);

        // ====================================================================
        // P56-2: MOVE CCR,D1  ($42C1)
        // CCR = SR[7:0] = 0x00 at reset.
        // ====================================================================
        $display("--- P56-2: MOVE CCR,D1 ---");
        issue_wait(16'h42C1, 1'b0, 32'h0);
        repeat(4) @(posedge clk);
        chk("P56-2: D1 = CCR (0x00)", dut.u_rf.d_reg[1], 32'h0000_0000);

        // ====================================================================
        // P56-3: MOVE D2,CCR  ($44C2) — D2[4:0] write to CCR
        // Load D2 = 0x1F via MOVEQ #31,D2 ($741F), then MOVE D2,CCR ($44C2).
        // SR[7:0] becomes 0x1F; SR[15:8] stays 0x27.
        // ====================================================================
        $display("--- P56-3: MOVE D2,CCR ---");
        issue_wait(16'h741F, 1'b0, 32'h0);   // MOVEQ #31,D2
        repeat(4) @(posedge clk);
        issue_wait(16'h44C2, 1'b0, 32'h0);   // MOVE D2,CCR
        repeat(4) @(posedge clk);
        chk("P56-3: SR after MOVE D2,CCR (CCR=0x1F)", {16'h0, sr_out}, 32'h0000_271F);

        // ====================================================================
        // P56-4: MOVE D3,SR  ($46C3) — full SR write
        // First read current SR into D3 via MOVE SR,D3 ($40C3), then write back.
        // Verifies full SR write path with sr_ccr_only=0.
        // ====================================================================
        $display("--- P56-4: MOVE D3,SR (supervisor round-trip) ---");
        issue_wait(16'h40C3, 1'b0, 32'h0);   // MOVE SR,D3 ($40C3)
        repeat(4) @(posedge clk);
        chk("P56-4a: D3 = SR (0x271F)", dut.u_rf.d_reg[3], 32'h0000_271F);
        issue_wait(16'h46C3, 1'b0, 32'h0);   // MOVE D3,SR ($46C3)
        repeat(4) @(posedge clk);
        chk("P56-4b: SR after MOVE D3,SR round-trip (0x271F)", {16'h0, sr_out}, 32'h0000_271F);

        // ====================================================================
        // P56-5: MOVE An,USP ($4E61) and MOVE USP,An ($4E6A)
        // Load A1 = 0x1234 via LEA (d16,PC),A1 = $43FA d16 (d16=0x1232 → A1=0x1234).
        // Write A1 to USP; read USP back into A2.
        // ====================================================================
        $display("--- P56-5: MOVE An,USP / MOVE USP,An ---");
        issue_wait(16'h43FA, 1'b1, 32'h0000_1232);   // LEA (d16,PC),A1 → A1=0x1234
        repeat(4) @(posedge clk);
        issue_wait(16'h4E61, 1'b0, 32'h0);           // MOVE A1,USP
        repeat(4) @(posedge clk);
        chk("P56-5a: USP after MOVE A1,USP", usp_out, 32'h0000_1234);
        issue_wait(16'h4E6A, 1'b0, 32'h0);           // MOVE USP,A2
        repeat(4) @(posedge clk);
        chk("P56-5b: A2 = USP", dut.u_rf.a_reg[2], 32'h0000_1234);

        // ====================================================================
        // P56-6: TRAP #5  ($4E45) — eu_trap_req pulses, eu_trap_num=5
        // ====================================================================
        $display("--- P56-6: TRAP #5 ---");
        begin
            logic saw_trap;
            logic [3:0] saw_num;
            saw_trap = 0; saw_num = 4'hF;
            @(posedge clk);
            instr_word  = 16'h4E45;
            instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_trap_req) begin
                    saw_trap = 1;
                    saw_num  = eu_trap_num;
                    break;
                end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("P56-6a: eu_trap_req pulses", saw_trap, 1'b1);
            chk("P56-6b: eu_trap_num = 5", {28'h0, saw_num}, 32'h5);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // P56-7: TRAPV  ($4E76)
        //   a) CCR=0x1F from P56-3: V bit (bit 1) is 1. TRAPV fires.
        //   b) After clearing V (MOVEQ #0,D4 + MOVE D4,CCR), TRAPV silent.
        // ====================================================================
        $display("--- P56-7: TRAPV with V set ---");
        begin
            logic saw_trapv;
            saw_trapv = 0;
            @(posedge clk);
            instr_word  = 16'h4E76;
            instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_trapv_req) begin saw_trapv = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("P56-7a: TRAPV fires when V=1", saw_trapv, 1'b1);
            repeat(4) @(posedge clk);
        end

        // Clear all CCR flags: MOVEQ #0,D4 ($7800), then MOVE D4,CCR ($44C4)
        $display("--- P56-7b: clear V, TRAPV silent ---");
        issue_wait(16'h7800, 1'b0, 32'h0);    // MOVEQ #0,D4
        repeat(2) @(posedge clk);
        issue_wait(16'h44C4, 1'b0, 32'h0);    // MOVE D4,CCR (CCR=0)
        repeat(4) @(posedge clk);
        chk1("P56-7b-setup: V cleared", sr_out[1], 1'b0);
        begin
            logic saw_trapv;
            saw_trapv = 0;
            @(posedge clk);
            instr_word  = 16'h4E76;
            instr_valid = 1'b1;
            repeat(30) begin
                @(posedge clk);
                if (eu_trapv_req) begin saw_trapv = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("P56-7c: TRAPV silent when V=0", saw_trapv, 1'b0);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // P56-8: ILLEGAL  ($4AFC) — eu_illegal_req pulses
        // ====================================================================
        $display("--- P56-8: ILLEGAL ---");
        begin
            logic saw_illegal;
            saw_illegal = 0;
            @(posedge clk);
            instr_word  = 16'h4AFC;
            instr_valid = 1'b1;
            repeat(50) begin
                @(posedge clk);
                if (eu_illegal_req) begin saw_illegal = 1; break; end
                if (instr_ack) instr_valid = 1'b0;
            end
            instr_valid = 1'b0;
            chk1("P56-8: eu_illegal_req pulses", saw_illegal, 1'b1);
            repeat(4) @(posedge clk);
        end

        // ====================================================================
        // P56-9: STOP #$2700  ($4E72 2700)
        // eu_stop asserts; clears when exc_sr_wr_en pulses.
        // ====================================================================
        $display("--- P56-9: STOP ---");
        begin
            logic saw_stop;
            saw_stop = 0;
            @(posedge clk);
            instr_word  = 16'h4E72;
            instr_valid = 1'b1;
            ext_data    = 32'h0000_2700;
            ext_valid   = 1'b1;
            repeat(200) begin
                @(posedge clk);
                if (eu_stop) begin saw_stop = 1; break; end
                if (instr_ack) begin instr_valid = 1'b0; ext_valid = 1'b0; end
            end
            instr_valid = 1'b0; ext_valid = 1'b0;
            chk1("P56-9a: eu_stop asserts after STOP", saw_stop, 1'b1);

            // Simulate interrupt taken: write new SR (keep supervisor mode) and clear stop
            repeat(4) @(posedge clk);
            exc_sr_wr_en   = 1'b1;
            exc_sr_wr_data = 16'h2700;   // stay supervisor so P56-10 RTE uses SSP
            @(posedge clk);
            exc_sr_wr_en   = 1'b0;
            exc_sr_wr_data = 16'h0;
            repeat(4) @(posedge clk);
            chk1("P56-9b: eu_stop clears after exc_sr_wr_en", eu_stop, 1'b0);
        end

        // ====================================================================
        // P56-10: RTE  ($4E73)
        // Set SSP=0x1000. Memory model returns SR=0x2700 at A7 and PC=0x2000 at A7+2.
        // After RTE: SR=0x2700, branch_target=0x2000.
        // ====================================================================
        $display("--- P56-10: RTE ---");
        begin
            logic saw_branch;
            logic [31:0] rte_pc;
            logic [15:0] rte_sr;
            saw_branch = 0; rte_pc = 0; rte_sr = 0;

            // Load SSP = 0x1000 (A7 in supervisor mode)
            @(posedge clk);
            ssp_wr_en   = 1'b1;
            ssp_wr_data = 32'h0000_1000;
            @(posedge clk);
            ssp_wr_en   = 1'b0;
            repeat(2) @(posedge clk);

            // Enable address-based memory model for RTE
            rte_mode = 1'b1;

            @(posedge clk);
            instr_word  = 16'h4E73;
            instr_valid = 1'b1;
            repeat(300) begin
                @(posedge clk);
                if (instr_ack) instr_valid = 1'b0;
                if (branch_taken) begin
                    saw_branch = 1;
                    rte_pc     = branch_target;
                    break;
                end
            end
            instr_valid = 1'b0;
            repeat(4) @(posedge clk);
            rte_sr = sr_out;

            rte_mode = 1'b0;

            chk1("P56-10a: RTE branch_taken", saw_branch, 1'b1);
            chk("P56-10b: RTE target PC = 0x2000", rte_pc, 32'h0000_2000);
            chk("P56-10c: SR after RTE = 0x2700",  {16'h0, rte_sr}, 32'h0000_2700);
        end

        // ====================================================================
        // Summary
        // ====================================================================
        repeat(4) @(posedge clk);
        if (fail_cnt == 0)
            $display("=== 0 failure(s) ===\nALL TESTS PASSED");
        else
            $display("=== %0d failure(s) ===", fail_cnt);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

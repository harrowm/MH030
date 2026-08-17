`default_nettype none
`timescale 1ps/1ps

// m68030_mmu testbench
//
// Instantiates m68030_mmu + biu_mmu_if (the ATC/walker) and connects them.
// A simple walk-memory stub responds to biu_mmu_if's mmu_req port.
//
// Tests:
//   MMU-1: MMU disabled (TC=0) — identity mapping, 1-cycle ack
//   MMU-2: TT0 transparent translation hit — identity + CI flag
//   MMU-3: ATC miss → 2-level table walk → PA=0xDEAD1678
//   MMU-4: ATC hit (same VA from MMU-3) — no walk needed
//   MMU-5: PFLUSH single VA/FC entry → ATC miss on next access
//   MMU-6: PFLUSH all FC=001 entries → confirmed via walk on repeat
//   MMU-7: Walk fault (mmu_berr from stub) → fault_out asserted
//   MMU-8: PTEST — walk returns mmusr_out with B=0 (no bus fault)
//   MMU-9:  PTEST fresh walk on a WP-set page — explicit MMUSR bit check
//   MMU-10: PTEST ATC hit (same VA as MMU-9) — MMUSR.ATC set
//   MMU-11: PTEST on an invalid (DT=00) descriptor — MMUSR.T/I set
//   MMU-12: PTEST hitting a genuine bus error mid-walk — MMUSR==0x8000
//   MMU-13: PTEST must NOT write U/M back (no write cycle on walk bus)
//   MMU-14: control — a real (non-PTEST) read DOES write U back

// Walk memory layout (4KB pages, TIA=8, TIB=8, CRP base=0x00010000):
//   VA = 0x1234_5678, FC=001
//   Level A addr = 0x10000 + (VA[31:24]=0x12)*4 = 0x10048
//   Level A desc = 0x0000_2002  (DT=10=table, next_base=0x2000)
//   Level B addr = 0x02000 + (VA[23:16]=0x34)*4 = 0x20D0
//   Level B desc = 0xDEAD_1001  (DT=01=page, PA=0xDEAD1xxx)
//   Expected PA  = 0xDEAD_1678

module mmu_tb;
    localparam logic [31:0] TC_MMU_ON = 32'h8C08_8000;
    // E=1, PS=12(4KB), IS=0, TIA=8, TIB=8, TIC=0
    localparam logic [63:0] CRP_VAL   = 64'h0000_0000_0001_0000;
    // crp_base = {crp[31:4],4'h0} = 0x10000

    localparam logic [31:0] VA_TEST    = 32'h1234_5678;
    localparam logic [31:0] PA_EXPECT  = 32'hDEAD_1678;
    localparam logic [31:0] ADDR_A     = 32'h0001_0048;
    localparam logic [31:0] ADDR_B     = 32'h0000_20D0;
    localparam logic [31:0] DESC_A     = 32'h0000_2002; // table desc DT=10
    localparam logic [31:0] DESC_B_OK  = 32'hDEAD_1001; // page desc DT=01

    // Phase 150 Stage 4: fresh routes for MMUSR bit-level tests (MMU-9..14).
    // Same CRP/2-level-walk shape as VA_TEST (TIA=8,TIB=8,TIC=0): level-A
    // table entry at crp_base+VA[31:24]*4, level-B page leaf at
    // next_base+VA[23:16]*4.
    localparam logic [31:0] VA2        = 32'h9876_5432; // WP=1 page
    localparam logic [31:0] ADDR_A2    = 32'h0001_0260;
    localparam logic [31:0] ADDR_B2    = 32'h0000_31D8;
    localparam logic [31:0] DESC_A2    = 32'h0000_3002; // table desc DT=10
    localparam logic [31:0] DESC_B2    = 32'hBEEF_2005; // page, WP=1,U=0,M=0

    localparam logic [31:0] VA4        = 32'h1111_1111; // WP=0 page, fresh
    localparam logic [31:0] ADDR_A4    = 32'h0001_0044;
    localparam logic [31:0] ADDR_B4    = 32'h0000_5044;
    localparam logic [31:0] DESC_A4    = 32'h0000_5002;
    localparam logic [31:0] DESC_B4    = 32'hCAFE_4001; // page, WP=0,U=0,M=0

    localparam logic [31:0] VA5        = 32'h2222_2222; // WP=0 page, fresh
    localparam logic [31:0] ADDR_A5    = 32'h0001_0088;
    localparam logic [31:0] ADDR_B5    = 32'h0000_6088;
    localparam logic [31:0] DESC_A5    = 32'h0000_6002;
    localparam logic [31:0] DESC_B5    = 32'hFACE_5001; // page, WP=0,U=0,M=0

    // -----------------------------------------------------------------------
    // Clock + reset
    // -----------------------------------------------------------------------
    logic clk_4x = 0;
    always #5 clk_4x = ~clk_4x;
    logic rst_n = 0;

    // -----------------------------------------------------------------------
    // Control registers
    // -----------------------------------------------------------------------
    logic [31:0] tc  = 32'h0;
    logic [63:0] crp = CRP_VAL;
    logic [63:0] srp = CRP_VAL;
    logic [31:0] tt0 = 32'h0;
    logic [31:0] tt1 = 32'h0;

    // -----------------------------------------------------------------------
    // m68030_mmu ↔ biu_mmu_if wires
    // -----------------------------------------------------------------------
    // m68030_mmu → biu_mmu_if translation request
    logic [31:0] mm_biu_va;
    logic [2:0]  mm_biu_fc;
    logic        mm_biu_rw;
    logic        mm_biu_req;
    logic        mm_biu_is_ptest;  // Phase 150 Stage 4
    // biu_mmu_if → m68030_mmu translation result
    logic [31:0] bm_pa;
    logic        bm_hit, bm_walk_done, bm_fault, bm_ci;
    logic        bm_done;          // hit | walk_done
    logic [15:0] bm_mmusr;         // Phase 150 Stage 4 (declared here, ahead of use in u_mmu below)
    assign bm_done = bm_hit | bm_walk_done;

    // m68030_mmu → biu_mmu_if pflush
    logic        mm_pflush_req, mm_pflush_all;
    logic [2:0]  mm_pflush_fc;
    logic [31:0] mm_pflush_va;
    logic        bm_pflush_ack;

    // biu_mmu_if walk bus → stub
    logic [31:0] bm_walk_addr;
    logic [2:0]  bm_walk_fc;
    logic        bm_walk_req;
    logic        bm_walk_rw;     // Phase 150 Stage 4 test: 1=read, 0=write
    logic [31:0] bm_walk_wdata;  // Phase 150 Stage 4 test: U/M write-back data
    // stub → biu_mmu_if (stub_rdata driven combinatorially below)
    logic [31:0] stub_rdata;
    logic        stub_ack   = 1'b0;
    logic        stub_berr  = 1'b0;

    // -----------------------------------------------------------------------
    // m68030_mmu ports
    // -----------------------------------------------------------------------
    logic [31:0] va_in   = 32'h0;
    logic [2:0]  fc_in   = 3'b001;
    logic        rw_in   = 1'b1;
    logic        req_in  = 1'b0;
    logic [31:0] pa_out;
    logic        ack_out, fault_out, ci_out;

    logic        pflush_req = 0, pflush_all = 0;
    logic [2:0]  pflush_fc  = 0;
    logic [31:0] pflush_va  = 0;
    logic        pflush_ack;

    logic        ptest_req = 0;
    logic [31:0] ptest_va  = 0;
    logic [2:0]  ptest_fc  = 3'b001;
    logic [15:0] mmusr_out;
    logic        ptest_ack;
    logic        mmu_active;

    // -----------------------------------------------------------------------
    // DUT: m68030_mmu
    // -----------------------------------------------------------------------
    m68030_mmu u_mmu (
        .clk_4x         (clk_4x),
        .rst_n          (rst_n),
        .tc             (tc),
        .va_in          (va_in),
        .fc_in          (fc_in),
        .rw_in          (rw_in),
        .req_in         (req_in),
        .pa_out         (pa_out),
        .ack_out        (ack_out),
        .fault_out      (fault_out),
        .ci_out         (ci_out),
        .pflush_req     (pflush_req),
        .pflush_all     (pflush_all),
        .pflush_fc      (pflush_fc),
        .pflush_va      (pflush_va),
        .pflush_ack     (pflush_ack),
        .ptest_req      (ptest_req),
        .ptest_va       (ptest_va),
        .ptest_fc       (ptest_fc),
        .mmusr_out      (mmusr_out),
        .ptest_ack      (ptest_ack),
        // BIU translation port → wired to biu_mmu_if
        .biu_va         (mm_biu_va),
        .biu_fc         (mm_biu_fc),
        .biu_rw         (mm_biu_rw),
        .biu_req        (mm_biu_req),
        .biu_is_ptest   (mm_biu_is_ptest), // Phase 150 Stage 4
        .biu_mmusr      (bm_mmusr),        // Phase 150 Stage 4
        .biu_pa         (bm_pa),
        .biu_done       (bm_done),
        .biu_fault      (bm_fault),
        .biu_ci         (bm_ci),
        // BIU pflush port → wired to biu_mmu_if
        .biu_pflush_req (mm_pflush_req),
        .biu_pflush_all (mm_pflush_all),
        .biu_pflush_fc  (mm_pflush_fc),
        .biu_pflush_va  (mm_pflush_va),
        .biu_pflush_ack (bm_pflush_ack),
        .mmu_active     (mmu_active)
    );

    // -----------------------------------------------------------------------
    // DUT: biu_mmu_if (ATC + table walker)
    // -----------------------------------------------------------------------
    biu_mmu_if u_bm (
        .clk_4x       (clk_4x),
        .rst_n        (rst_n),
        .va           (mm_biu_va),
        .fc           (mm_biu_fc),
        .rw           (mm_biu_rw),
        .req          (mm_biu_req),
        .is_ptest     (mm_biu_is_ptest), // Phase 150 Stage 4
        .pa           (bm_pa),
        .hit          (bm_hit),
        .walk_done    (bm_walk_done),
        .fault        (bm_fault),
        .ci           (bm_ci),
        .mmu_req_addr (bm_walk_addr),
        .mmu_req_fc   (bm_walk_fc),
        .mmu_req      (bm_walk_req),
        .mmu_req_rw   (bm_walk_rw),     // Phase 150 Stage 4 test
        .mmu_req_wdata(bm_walk_wdata),  // Phase 150 Stage 4 test
        .mmu_rdata    (stub_rdata),
        .mmu_ack      (stub_ack),
        .mmu_berr     (stub_berr),
        .tc           (tc),
        .crp          (crp),
        .srp          (srp),
        .tt0          (tt0),
        .tt1          (tt1),
        .mmusr        (bm_mmusr),
        .pflush_req   (mm_pflush_req),
        .pflush_all   (mm_pflush_all),
        .pflush_fc    (mm_pflush_fc),
        .pflush_va    (mm_pflush_va),
        .pflush_ack   (bm_pflush_ack)
    );

    // -----------------------------------------------------------------------
    // Walk memory stub
    // Responds to biu_mmu_if's mmu_req with descriptor data.
    //
    // Key design points:
    //   - stub_rdata is COMBINATORIAL so it tracks bm_walk_addr in the same
    //     cycle that biu_mmu_if updates walk_req_addr_r (A→B NBA).
    //   - WS_IDLE only re-arms when stub_ack=0 AND stub_berr=0, preventing a
    //     spurious second read in the ack cycle itself.
    // inject_berr: fires mmu_berr instead of mmu_ack for the current walk.
    // -----------------------------------------------------------------------
    logic inject_berr = 0;

    // Combinatorial read data — tracks bm_walk_addr immediately.
    always_comb begin
        case (bm_walk_addr)
            ADDR_A:  stub_rdata = DESC_A;
            ADDR_B:  stub_rdata = DESC_B_OK;
            ADDR_A2: stub_rdata = DESC_A2;
            ADDR_B2: stub_rdata = DESC_B2;
            ADDR_A4: stub_rdata = DESC_A4;
            ADDR_B4: stub_rdata = DESC_B4;
            ADDR_A5: stub_rdata = DESC_A5;
            ADDR_B5: stub_rdata = DESC_B5;
            default: stub_rdata = 32'h0;    // invalid DT=00 → fault
        endcase
    end

    // -----------------------------------------------------------------------
    // Phase 150 Stage 4 test: write-cycle monitor on the walk bus.
    // Sticky within a test's own window (cleared via blocking assignment
    // right before each window starts, same convention as inject_berr).
    // Proves PTEST (MMU-13) never issues mmu_req with rw=0, and that a real
    // access (MMU-14) genuinely does (positive control for the monitor
    // itself, not just an untested absence).
    // -----------------------------------------------------------------------
    logic saw_write_r = 1'b0;
    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) saw_write_r <= 1'b0;
        else if (bm_walk_req && !bm_walk_rw) saw_write_r <= 1'b1;
    end

    typedef enum logic [1:0] {WS_IDLE, WS_WAIT, WS_ACK} ws_t;
    ws_t ws_state = WS_IDLE;
    logic [1:0] ws_cnt = 2'd0;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ws_state  <= WS_IDLE;
            stub_ack  <= 1'b0;
            stub_berr <= 1'b0;
            ws_cnt    <= 2'd0;
        end else begin
            stub_ack  <= 1'b0;
            stub_berr <= 1'b0;
            case (ws_state)
                WS_IDLE: begin
                    // Guard: don't re-arm in the same cycle ack/berr is asserted.
                    if (bm_walk_req && !stub_ack && !stub_berr) begin
                        ws_cnt   <= 2'd1;
                        ws_state <= WS_WAIT;
                    end
                end
                WS_WAIT: begin
                    if (ws_cnt > 0) ws_cnt <= ws_cnt - 2'd1;
                    else            ws_state <= WS_ACK;
                end
                WS_ACK: begin
                    if (inject_berr) stub_berr <= 1'b1;
                    else             stub_ack  <= 1'b1;
                    ws_state <= WS_IDLE;
                end
                default: ws_state <= WS_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Helper tasks
    // -----------------------------------------------------------------------
    int fail_count = 0;

    task check(input string name, input logic cond);
        if (cond) $display("PASS  %s", name);
        else begin
            $display("FAIL  %s", name);
            fail_count++;
        end
    endtask

    task check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) $display("PASS  %s (got %08h)", name, got);
        else begin
            $display("FAIL  %s: got %08h exp %08h", name, got, exp);
            fail_count++;
        end
    endtask

    // Issue one translation request; poll for ack_out up to 200 cycles.
    task translate(
        input  logic [31:0] va,
        input  logic [2:0]  fc,
        input  logic        rw,
        output logic [31:0] pa,
        output logic        fault,
        output logic        ci
    );
        int t;
        @(posedge clk_4x); #1;
        va_in = va; fc_in = fc; rw_in = rw; req_in = 1'b1;
        @(posedge clk_4x); #1;
        req_in = 1'b0;
        for (t = 0; t < 200; t++) begin
            if (ack_out) break;
            @(posedge clk_4x); #1;
        end
        pa    = pa_out;
        fault = fault_out;
        ci    = ci_out;
    endtask

    // Wait for pflush_ack up to 30 cycles.
    task do_pflush(
        input logic        pf_all,
        input logic [2:0]  pf_fc,
        input logic [31:0] pf_va
    );
        int t;
        @(posedge clk_4x); #1;
        pflush_req = 1; pflush_all = pf_all;
        pflush_fc  = pf_fc; pflush_va = pf_va;
        @(posedge clk_4x); #1;
        pflush_req = 0;
        for (t = 0; t < 30; t++) begin
            if (pflush_ack) break;
            @(posedge clk_4x); #1;
        end
        check("PFLUSH ack received", pflush_ack);
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $display("=== m68030_mmu unit tests ===");
        repeat(10) @(posedge clk_4x);
        rst_n = 1'b1;
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-1: MMU disabled → identity mapping, fast ack
        // ----------------------------------------------------------------
        $display("--- MMU-1: disabled identity ---");
        begin
            logic [31:0] pa; logic fault, ci;
            tc = 32'h0;
            translate(32'hCAFE_0000, 3'b001, 1'b1, pa, fault, ci);
            check32("MMU-1: pa==va",  pa, 32'hCAFE_0000);
            check  ("MMU-1: no fault", !fault);
            check  ("MMU-1: no CI",    !ci);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-2: TT0 transparent hit — VA=0x1234_5678 hits TT0, CI=1
        // TT0: LAB=0x12, LAM=0x00(exact), E=1, CI=1, FCM=7(any FC)
        // tt0[31:24]=0x12, [23:16]=0x00, [15]=1(E), [13]=1(CI),
        //     [7:5]=111(FCM=all), [4:2]=000(FCB=0), [1:0]=00
        // ----------------------------------------------------------------
        $display("--- MMU-2: TT0 transparent ---");
        begin
            logic [31:0] pa; logic fault, ci;
            tc  = TC_MMU_ON;
            tt0 = 32'h1200_A0E0;    // match VA[31:24]==0x12, CI=1, any FC
            translate(VA_TEST, 3'b001, 1'b1, pa, fault, ci);
            check32("MMU-2: pa==va (identity)",  pa, VA_TEST);
            check  ("MMU-2: no fault",            !fault);
            check  ("MMU-2: CI flag set",          ci);
            tt0 = 32'h0;
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-3: ATC miss → 2-level table walk → PA=0xDEAD1678
        // (TT0 cleared; VA=0x12345678 misses ATC; walk stub provides
        //  DESC_A at ADDR_A and DESC_B_OK at ADDR_B)
        // ----------------------------------------------------------------
        $display("--- MMU-3: ATC miss → walk ---");
        begin
            logic [31:0] pa; logic fault, ci;
            tc = TC_MMU_ON; tt0 = 32'h0;
            translate(VA_TEST, 3'b001, 1'b1, pa, fault, ci);
            check32("MMU-3: PA after walk", pa, PA_EXPECT);
            check  ("MMU-3: no fault",      !fault);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-4: ATC hit (same VA — loaded by MMU-3 walk)
        // ----------------------------------------------------------------
        $display("--- MMU-4: ATC hit ---");
        begin
            logic [31:0] pa; logic fault, ci;
            translate(VA_TEST, 3'b001, 1'b1, pa, fault, ci);
            check32("MMU-4: PA from ATC", pa, PA_EXPECT);
            check  ("MMU-4: no fault",    !fault);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-5: PFLUSH single entry → next access causes ATC miss + walk
        // ----------------------------------------------------------------
        $display("--- MMU-5: PFLUSH single ---");
        do_pflush(1'b0, 3'b001, VA_TEST);
        repeat(4) @(posedge clk_4x);
        begin
            logic [31:0] pa; logic fault, ci;
            translate(VA_TEST, 3'b001, 1'b1, pa, fault, ci);
            check32("MMU-5: walk after flush", pa, PA_EXPECT);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-6: PFLUSH all (FC=001) — clears all FC=001 entries
        // ----------------------------------------------------------------
        $display("--- MMU-6: PFLUSH all ---");
        do_pflush(1'b1, 3'b001, 32'h0);
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-7: Walk fault (stub fires mmu_berr) → fault_out asserted
        // MMU-6 flushed ATC, so 0xABCD0000 needs a walk; inject_berr=1
        // ----------------------------------------------------------------
        $display("--- MMU-7: walk fault ---");
        begin
            logic [31:0] pa; logic fault, ci;
            inject_berr = 1'b1;
            translate(32'hABCD_0000, 3'b001, 1'b1, pa, fault, ci);
            check("MMU-7: fault_out asserted", fault);
            inject_berr = 1'b0;
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-8: PTEST — walk returns mmusr_out with B=0 (no bus fault)
        // ATC was flushed by MMU-6, so VA_TEST needs a walk.
        // ----------------------------------------------------------------
        $display("--- MMU-8: PTEST ---");
        begin
            int t;
            tc = TC_MMU_ON;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = VA_TEST; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check("MMU-8: ptest_ack fires",      ptest_ack);
            check("MMU-8: mmusr B=0 (no fault)", !mmusr_out[15]);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-9: PTEST fresh walk (not ATC'd) on a WP=1 page — explicit
        // MMUSR bit check. build_mmusr(b=0,t=0,wp=1,i=0,m=0,u=1,atc=0).
        // ----------------------------------------------------------------
        $display("--- MMU-9: PTEST walk, WP page, MMUSR bits ---");
        begin
            int t;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = VA2; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check  ("MMU-9: ptest_ack fires",        ptest_ack);
            check32("MMU-9: mmusr (fresh walk, WP)", mmusr_out, 16'h1100);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-10: PTEST again on VA2 — now an ATC hit (a real 68030's own
        // PTEST does load the ATC, unlike U/M write-back which it must
        // skip — MMUSR.ATC becomes 1).
        // build_mmusr(b=0,t=0,wp=1,i=0,m=0,u=1,atc=1).
        // ----------------------------------------------------------------
        $display("--- MMU-10: PTEST ATC hit, MMUSR bits ---");
        begin
            int t;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = VA2; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check  ("MMU-10: ptest_ack fires",      ptest_ack);
            check32("MMU-10: mmusr (ATC hit, WP)",  mmusr_out, 16'h1104);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-11: PTEST on an unmapped VA — level-A descriptor DT=00
        // (invalid). build_mmusr(b=0,t=1,wp=0,i=1,m=0,u=0,atc=0).
        // ----------------------------------------------------------------
        $display("--- MMU-11: PTEST invalid descriptor, MMUSR bits ---");
        begin
            int t;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = 32'h5555_5555; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check  ("MMU-11: ptest_ack fires",             ptest_ack);
            check32("MMU-11: mmusr (invalid descriptor)",  mmusr_out, 16'h2800);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-12: PTEST hits a genuine bus error mid-walk (inject_berr).
        // MS_FAULT's fault_is_berr_r branch: mmusr == 16'h8000 exactly,
        // regardless of build_mmusr's usual field layout.
        // ----------------------------------------------------------------
        $display("--- MMU-12: PTEST bus error, MMUSR bits ---");
        begin
            int t;
            inject_berr = 1'b1;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = 32'h6666_6666; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check  ("MMU-12: ptest_ack fires",    ptest_ack);
            check32("MMU-12: mmusr (bus error)",  mmusr_out, 16'h8000);
            inject_berr = 1'b0;
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-13: PTEST must NEVER write U/M back — confirm no write
        // cycle (mmu_req with rw=0) occurs anywhere during a fresh PTEST
        // walk of a U=0,M=0 page (VA4, never touched by an earlier test).
        // ----------------------------------------------------------------
        $display("--- MMU-13: PTEST does not write U/M back ---");
        begin
            int t;
            saw_write_r = 1'b0;
            @(posedge clk_4x); #1;
            ptest_req = 1'b1; ptest_va = VA4; ptest_fc = 3'b001;
            @(posedge clk_4x); #1;
            ptest_req = 1'b0;
            for (t = 0; t < 200; t++) begin
                if (ptest_ack) break;
                @(posedge clk_4x); #1;
            end
            check  ("MMU-13: ptest_ack fires",              ptest_ack);
            check32("MMU-13: mmusr (fresh walk, no WP)",    mmusr_out, 16'h0100);
            check  ("MMU-13: no write cycle on walk bus (PTEST must not touch U/M)",
                     !saw_write_r);
        end
        repeat(4) @(posedge clk_4x);

        // ----------------------------------------------------------------
        // MMU-14: control/positive proof — a REAL (non-PTEST) read of a
        // fresh U=0,M=0 page (VA5) DOES trigger a U write-back cycle.
        // Proves the write monitor genuinely catches a real write (so
        // MMU-13's negative result means something), and that Stage 3's
        // write-back mechanism is live end-to-end through this harness.
        // ----------------------------------------------------------------
        $display("--- MMU-14: real read triggers U write-back ---");
        begin
            logic [31:0] pa; logic fault, ci;
            saw_write_r = 1'b0;
            translate(VA5, 3'b001, 1'b1, pa, fault, ci);
            check("MMU-14: no fault",                        !fault);
            check("MMU-14: write cycle seen (U write-back)", saw_write_r);
        end

        $display("=== %0d failure(s) ===", fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("TESTS FAILED");
        $finish;
    end

    initial begin #10_000_000; $display("FAIL  Hard timeout"); $finish; end

endmodule

`default_nettype wire

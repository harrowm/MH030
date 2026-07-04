`default_nettype none

// MC68030 MMU — Phase 35
//
// EU-facing wrapper around the BIU's biu_mmu_if ATC + table walker.
// Provides:
//   - Virtual-to-physical address translation (ATC + 3-level walk)
//   - Transparent Translation (TT0/TT1) — handled inside biu_mmu_if
//   - PFLUSH instruction support (ATC invalidation via BIU pflush port)
//   - PTEST: basic level-0 walk returning MMUSR (fault/wp/ci bits)
//
// When TC[31]=0 (MMU disabled), identity mapping is applied immediately
// without touching biu_mmu_if (1-cycle latency from req to ack).
// When TC[31]=1, every translation goes through biu_mmu_if (ATC lookup
// or full table walk), giving 2+ cycles depending on ATC state.
//
// Priority: PFLUSH > translation request (never issued simultaneously
// in practice since PFLUSH stalls the pipeline).

module m68030_mmu (
    input  logic        clk_4x,
    input  logic        rst_n,

    // ── Translation control registers ────────────────────────────────────
    input  logic [31:0] tc,        // TC[31]=E enables MMU

    // ── EU translation request ────────────────────────────────────────────
    input  logic [31:0] va_in,
    input  logic [2:0]  fc_in,
    input  logic        rw_in,
    input  logic        req_in,    // one-cycle strobe; hold ack until ack_out
    output logic [31:0] pa_out,    // physical address (valid when ack_out=1)
    output logic        ack_out,   // one-cycle: translation complete
    output logic        fault_out, // one-cycle with ack_out: translation fault
    output logic        ci_out,    // one-cycle with ack_out: cache inhibit

    // ── PFLUSH ────────────────────────────────────────────────────────────
    input  logic        pflush_req,
    input  logic        pflush_all,    // 0=single VA/FC entry, 1=all with FC
    input  logic [2:0]  pflush_fc,
    input  logic [31:0] pflush_va,
    output logic        pflush_ack,    // one-cycle; 1 cycle after req (tc=1) or same (tc=0)

    // ── PTEST ─────────────────────────────────────────────────────────────
    input  logic        ptest_req,
    input  logic [31:0] ptest_va,
    input  logic [2:0]  ptest_fc,
    output logic [15:0] mmusr_out,     // result (latched at walk completion)
    output logic        ptest_ack,

    // ── BIU mmu translation port (connects to biu_mmu_if via m68030_biu) ─
    output logic [31:0] biu_va,
    output logic [2:0]  biu_fc,
    output logic        biu_rw,
    output logic        biu_req,       // one-cycle strobe to biu_mmu_if
    input  logic [31:0] biu_pa,
    input  logic        biu_done,      // mmu_done_ext from BIU (hit|walk_done)
    input  logic        biu_fault,     // mmu_fault from BIU
    input  logic        biu_ci,        // mmu_ci from BIU

    // ── BIU pflush port ───────────────────────────────────────────────────
    output logic        biu_pflush_req,
    output logic        biu_pflush_all,
    output logic [2:0]  biu_pflush_fc,
    output logic [31:0] biu_pflush_va,
    input  logic        biu_pflush_ack,

    output logic        mmu_active     // 1 while processing
);

    wire tc_e = tc[31];

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    typedef enum logic [2:0] {
        MM_IDLE   = 3'd0,
        MM_REQ    = 3'd1,   // driving biu_req (one cycle), then waiting
        MM_WAIT   = 3'd2,   // waiting for biu_done / biu_fault
        MM_DONE   = 3'd3,   // emit ack for one cycle
        MM_PFLUSH = 3'd4    // waiting for biu_pflush_ack
    } mm_state_t;

    mm_state_t mm_state;

    logic [31:0] pa_r;
    logic        fault_r, ci_r;
    logic [15:0] mmusr_r;
    logic        ptest_pending_r;  // set when the pending request is a PTEST

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            mm_state        <= MM_IDLE;
            pa_r            <= 32'h0;
            fault_r         <= 1'b0;
            ci_r            <= 1'b0;
            mmusr_r         <= 16'h0;
            ptest_pending_r <= 1'b0;
            biu_req         <= 1'b0;
            biu_va          <= 32'h0;
            biu_fc          <= 3'b0;
            biu_rw          <= 1'b1;
            biu_pflush_req  <= 1'b0;
            biu_pflush_all  <= 1'b0;
            biu_pflush_fc   <= 3'b0;
            biu_pflush_va   <= 32'h0;
        end else begin
            // Default: deassert one-cycle strobes
            biu_req        <= 1'b0;
            biu_pflush_req <= 1'b0;

            case (mm_state)

                // ── Idle ─────────────────────────────────────────────────
                MM_IDLE: begin
                    if (pflush_req && tc_e) begin
                        // Forward PFLUSH to biu_mmu_if (tc=0 case: immediate ack,
                        // no state change needed — handled combinationally below)
                        biu_pflush_req <= 1'b1;
                        biu_pflush_all <= pflush_all;
                        biu_pflush_fc  <= pflush_fc;
                        biu_pflush_va  <= pflush_va;
                        mm_state       <= MM_PFLUSH;

                    end else if (ptest_req && tc_e) begin
                        // PTEST: walk without installing ATC entry.
                        // We reuse the normal translation path through biu_mmu_if;
                        // the result is captured in mmusr_r.
                        biu_req         <= 1'b1;
                        biu_va          <= ptest_va;
                        biu_fc          <= ptest_fc;
                        biu_rw          <= 1'b1;  // PTEST is always a read walk
                        ptest_pending_r <= 1'b1;
                        mm_state        <= MM_WAIT;

                    end else if (req_in) begin
                        if (!tc_e) begin
                            // MMU disabled: identity mapping, 1-cycle
                            pa_r            <= va_in;
                            fault_r         <= 1'b0;
                            ci_r            <= 1'b0;
                            ptest_pending_r <= 1'b0;
                            mm_state        <= MM_DONE;
                        end else begin
                            // MMU enabled: forward to biu_mmu_if for one cycle
                            biu_req         <= 1'b1;
                            biu_va          <= va_in;
                            biu_fc          <= fc_in;
                            biu_rw          <= rw_in;
                            ptest_pending_r <= 1'b0;
                            mm_state        <= MM_WAIT;
                        end
                    end
                end

                // ── Wait for BIU result ───────────────────────────────────
                MM_WAIT: begin
                    if (biu_fault) begin
                        pa_r     <= 32'h0;
                        fault_r  <= 1'b1;
                        ci_r     <= 1'b0;
                        // Build minimal MMUSR: B=1 (bus error), L=level, other=0
                        mmusr_r  <= 16'h8000;  // Bus fault
                        mm_state <= MM_DONE;
                    end else if (biu_done) begin
                        pa_r     <= biu_pa;
                        fault_r  <= 1'b0;
                        ci_r     <= biu_ci;
                        // MMUSR: PA[7:0] = 0, T=0, L=0, S=supervisor(implicit)
                        // WP and CI come from the walk result (BIU drives mmu_ci)
                        mmusr_r  <= {8'h00, biu_ci, 7'h00};
                        mm_state <= MM_DONE;
                    end
                end

                // ── Emit ack (one cycle) ──────────────────────────────────
                MM_DONE: begin
                    ptest_pending_r <= 1'b0;
                    mm_state        <= MM_IDLE;
                end

                // ── Wait for PFLUSH completion ────────────────────────────
                MM_PFLUSH: begin
                    if (biu_pflush_ack) begin
                        mm_state <= MM_IDLE;
                    end
                end

                default: mm_state <= MM_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Combinational outputs
    // -----------------------------------------------------------------------
    assign pa_out    = pa_r;
    assign ack_out   = (mm_state == MM_DONE) && !ptest_pending_r;
    assign fault_out = fault_r && (mm_state == MM_DONE);
    assign ci_out    = ci_r    && (mm_state == MM_DONE);
    assign mmu_active = (mm_state != MM_IDLE);

    // ptest_ack: fires one cycle (MM_DONE with ptest_pending_r)
    assign ptest_ack  = (mm_state == MM_DONE) && ptest_pending_r;
    assign mmusr_out  = mmusr_r;

    // pflush_ack:
    //   TC=0: immediate same-cycle (no ATC to flush)
    //   TC=1: comes from biu_mmu_if one cycle after biu_pflush_req
    assign pflush_ack = (pflush_req && !tc_e) | biu_pflush_ack;

endmodule

`default_nettype wire

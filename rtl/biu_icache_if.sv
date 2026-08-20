`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Instruction Cache Interface
//
// Interposed between m68030_ifu's existing longword-fetch port and
// biu_cycle_gen's existing ifu_* port — same protocol on both sides, so
// this is a drop-in insertion (Phase 127, plan: cache correctness+timing).
// Read-only (no write state, unlike biu_cache_if.sv's combined I+D module).
//
// icache_en=0: pure combinational bypass, zero added latency, byte-for-byte
// identical to the pre-existing direct-to-cycle_gen IFU path (the mode
// every regression test has run in for the entire project until now).
//
// icache_en=1, hit: served from the cache array, no bus cycle at all.
// icache_en=1, miss: genuine SIZ=11 pin-level burst linefill (Phase 127
// cache plan Step 8) via ic_burst_req/addr, muxed by m68030_biu.sv into
// biu_cycle_gen's own pre-existing eu_burst_req/addr/fc port (CBREQ#/
// CBACK# handshake and all, tested since Phase 7 via tb/biu_tb.sv's own
// direct eu_burst_req cases — this module is simply the first-ever real
// consumer). A single ic_burst_req at the line's own base address either
// completes as a genuine 4-beat burst (peripheral asserted CBACK#, all of
// ic_burst_rdata0..3 valid in one shot) or degrades to a single beat
// (CBACK# never asserted, matching real 68030 hardware's own fallback) —
// in the degraded case, IC_FILL_1B/2B/3B individually re-request each
// remaining word (each itself subject to the same possible degrade, but
// architecturally CBACK# support is a property of the addressed region,
// not the individual request, so each one only ever needs to actually
// fetch the single word it's asking for). Earlier versions (Steps 1-7)
// used 4 separate ordinary read cycles (IC_FILL_0..3 via cg_req) instead —
// correct, but not pin-level-accurate to CLAUDE.md's own documented burst
// cycle type; this closes that gap.
//
// Phase 158 Stage 4a: IBE (CACR bit 4) now genuinely gates whether CBREQ#
// is ever asserted at all, per manual Figure 6-13 ("The processor does not
// assert CBREQ if... burst filling for the cache is not enabled") — a
// prior version of this comment claimed "IBE only ever meant 'use burst
// pin protocol'", which does not match the manual and was corrected. When
// IBE=0, a miss dispatches into a REINSTATED IC_SINGLE_0..3 sequence (4
// separate ordinary reads via the same cg_req/cg_addr port the fully-
// disabled bypass above already uses, otherwise idle whenever the cache is
// enabled) instead of IC_BURST0 — genuinely never asserting CBREQ#, unlike
// the hardware-degraded case (CBACK# never asserted, IC_FILL_1B/2B/3B),
// which still asserts CBREQ# throughout per the manual's own distinction
// between "burst not requested" and "burst requested but not supported".

module biu_icache_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // IFU side — identical protocol to the port m68030_ifu already drives
    input  logic [31:0] ifu_addr,
    input  logic [2:0]  ifu_fc,    // Phase 158 Stage 2 — see header comment
    input  logic        ifu_req,
    output logic [31:0] ifu_rdata,
    output logic        ifu_ack,
    output logic        ifu_berr,

    // biu_cycle_gen side — identical protocol to its existing ifu_* port.
    // Only ever driven in the icache_en=0 bypass case now (see header
    // comment) — the enabled-cache miss path uses ic_burst_* below instead.
    output logic [31:0] cg_addr,
    output logic        cg_req,
    input  logic [31:0] cg_rdata,
    input  logic        cg_ack,    // 1-tick pulse
    input  logic        cg_berr,

    // Burst-linefill request, muxed by m68030_biu.sv into biu_cycle_gen's
    // own eu_burst_req/addr/fc port. FC is fixed at the caller (Supervisor
    // Program Space, matching cg_addr's own ordinary-read FC convention).
    // Phase 158 Stage 2 finding (confirmed, out of scope for this stage):
    // biu_cycle_gen.sv's own ordinary ifu_req path (line ~666) ALSO
    // hardcodes cyc_fc=3'b110 for every instruction fetch, unconditionally
    // -- real 68030 silicon uses FC=010 (User Program) vs 110 (Supervisor
    // Program) depending on the CPU's actual current mode, but nothing in
    // this project's own instruction-fetch pipeline threads the S-bit that
    // far today. This module's own new ifu_fc input (below) is wired to
    // the SAME still-hardcoded 3'b110 constant for now, consolidating what
    // were two independent hardcoded-FC sites (this file's own former
    // xl_fc literal, fixed this stage, plus biu_cycle_gen.sv's own) into
    // one clearly-flagged constant -- genuine dynamic S-bit-awareness for
    // instruction fetches is a separate, deeper, chip-wide undertaking
    // (would need to thread supervisor/user mode into the whole
    // instruction-fetch address/FC path, currently zero such input exists
    // anywhere in it), documented in plan.md/CLAUDE.md as a confirmed,
    // real, but out-of-scope gap for a future phase.
    output logic         ic_burst_req,
    output logic [31:0]  ic_burst_addr,
    input  logic [31:0]  ic_burst_rdata0,
    input  logic [31:0]  ic_burst_rdata1,
    input  logic [31:0]  ic_burst_rdata2,
    input  logic [31:0]  ic_burst_rdata3,
    input  logic [1:0]   ic_burst_beat,   // beat reached when ic_burst_ack fires (3=full, 0=degraded)
    input  logic         ic_burst_ack,
    input  logic         ic_burst_berr,

    // Control registers (written by EU via MOVEC)
    input  logic [31:0] cacr,
    input  logic [31:0] caar,

    // Phase 158 Stage 7: CIIN (already synchronized by biu_config.sv) --
    // see biu_cache_if.sv's own identical port for the manual citation.
    // No CIOUT here: the manual's own CIOUT description (p.6-9) is
    // specifically about the *data* cache's write-allocation interaction;
    // biu_cache_if.sv computes the one CIOUT this project implements.
    input  logic         ciin,

    // MMU translation control (Phase 150, plan.md)
    input  logic [31:0] tc,

    // MMU translation request/response (Phase 150, plan.md) — arbitrated
    // via biu_mmu_arb.sv, shared with biu_cache_if.sv's own D-side request
    // and the existing top-level (PTEST) requester. Instruction fetches are
    // always reads, so there's no xl_wp equivalent here (WP only matters
    // for writes) — xl_ci is threaded through but not yet acted on, same
    // documented deferral as biu_cache_if.sv's own xl_ci.
    output logic [31:0] xl_va,
    output logic [2:0]  xl_fc,
    output logic        xl_rw,
    output logic        xl_req,
    input  logic [31:0] xl_pa,
    input  logic        xl_hit,
    input  logic        xl_walk_done,
    input  logic        xl_fault,
    input  logic        xl_fault_is_berr, // see biu_cache_if.sv's own
                                           // identical port for the reasoning
    input  logic        xl_ci,

    // Synthetic fault-capture pulse for biu_exc_capture (Phase 150,
    // plan.md) — see biu_cache_if.sv's own identical port for the reasoning.
    output logic         xlate_fault_pulse,
    output logic [31:0]  xlate_fault_addr,
    output logic [2:0]   xlate_fault_fc,
    output logic         xlate_fault_rw,
    output logic [1:0]   xlate_fault_siz
);

    wire tc_e = tc[31];

    // CACR bit aliases (shared encoding with biu_cache_if.sv)
    wire icache_en = cacr[0];
    // Phase 158 Stage 4a: IBE now genuinely gates whether a burst is ever
    // requested at all, per manual Figure 6-13's own CBREQ-suppression
    // rule ("The processor does not assert CBREQ if... burst filling for
    // the cache is not enabled") -- the header comment's own prior
    // reasoning ("IBE only ever meant 'use burst pin protocol'") did not
    // match the manual and has been corrected; see IC_SINGLE_0..3 below.
    wire iburst_en = cacr[4];
    // Phase 158 Stage 5: manual §6.3.1.10 (confirmed by direct re-read):
    // "When the FI bit is set and a miss occurs in the instruction cache,
    // the entry (or line) is not replaced." Unlike the D-cache, the I-cache
    // has no write-hit exception to preserve (reads only) -- a frozen miss
    // just needs a single ordinary fetch (IC_FROZEN_MISS below) with the
    // cache array left untouched.
    wire ifreeze_en = cacr[1];

    // Cache storage: 16 lines x 4 longwords x 32 bits = 256 bytes.
    // Phase 158 Stage 2: tag widened from 24 to 25 bits (addr[31:8] alone)
    // to include FC2, per manual §6.1.2 (p.6-5/6-6): the instruction-cache
    // comparator matches "the 24 most significant logical address bits, the
    // FC2 function code bit... used to distinguish user and supervisor
    // accesses." Confirmed directly against the manual before fixing.
    logic        valid_i [0:15];
    logic [24:0] tag_i   [0:15];
    logic [31:0] data_i  [0:15][0:3];

    // cg_ack is a 1-tick pulse — edge detect for safety (mirrors
    // biu_cache_if.sv's own sf_ack_rise technique). ic_burst_ack is already
    // a registered one-tick pulse from biu_burst_ctrl.sv itself (see its
    // own eu_burst_ack_r), so no separate edge-detect is needed for it.
    logic cg_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) cg_ack_prev_r <= 1'b0;
        else        cg_ack_prev_r <= cg_ack;
    wire cg_ack_rise = cg_ack && !cg_ack_prev_r;

    // Disabled-cache accesses never enter this state machine at all (see
    // the combinational bypass in the output block below), so there is no
    // dedicated "single passthrough fetch" state here.
    typedef enum logic [3:0] {
        IC_IDLE    = 4'd0,
        IC_HIT     = 4'd1,
        IC_BURST0  = 4'd2,   // full-line burst attempt from fill_base_r
        IC_FILL_1B = 4'd3,   // degraded-fallback: word 1 individually
        IC_FILL_2B = 4'd4,   // degraded-fallback: word 2 individually
        IC_FILL_3B = 4'd5,   // degraded-fallback: word 3 individually
        IC_DONE    = 4'd6,
        IC_XLATE   = 4'd7,   // Phase 150, plan.md
        // Phase 158 Stage 4a: IBE=0 path -- 4 genuinely separate ordinary
        // reads via cg_req/cg_addr, CBREQ# never asserted at all (see
        // header comment for the distinction from IC_FILL_1B/2B/3B above).
        IC_SINGLE_0 = 4'd8,
        IC_SINGLE_1 = 4'd9,
        IC_SINGLE_2 = 4'd10,
        IC_SINGLE_3 = 4'd11,
        // Phase 158 Stage 5: FI=1 miss -- a single ordinary fetch (reusing
        // cg_single_req_r/addr_r, same registered-request shape IC_SINGLE_0
        // uses) that returns data to the IFU without touching
        // data_i/tag_i/valid_i at all, matching "the entry is not replaced."
        IC_FROZEN_MISS = 4'd12
    } ic_state_t;
    // BERR is signalled via a dedicated flag rather than a separate state,
    // since a BERR-vs-normal IC_DONE would otherwise be identical except
    // for which output fires — kept as one "finishing" state to halve the
    // state space; see the output block below.
    ic_state_t state;
    logic      berr_r;
    // Set when the in-flight transaction's own bus/fill cycle completes
    // (ic_burst_ack or ic_burst_berr) but the IFU has, in the meantime,
    // moved on to a different fetch (dropped ifu_req, or changed ifu_addr
    // to a different line/word — e.g. a JSR/RTS/branch flush arriving
    // mid-miss). Real 68030 hardware can't abort an S-state bus cycle
    // already in progress either, so the fill itself is still allowed to
    // complete and update the cache array (harmless, and a legitimate
    // future-use cache fill) — but IC_DONE must NOT hand a now-meaningless
    // ifu_ack/ifu_berr to a requester who no longer wants it, since
    // m68030_ifu.sv's own fetch_pend_r may have already re-armed for the
    // NEW address by then, causing it to misattribute this stale ack as
    // the delivery for its *new* request (confirmed via direct trace: q[0]
    // ended up holding an unrelated, already-consumed opcode word instead
    // of the freshly requested one — found building the I-2 aliasing/
    // eviction test, plan.md Phase 128).
    logic      abandoned_r;
    logic      xlate_fault_r;  // Phase 150: distinguishes IC_DONE reached via
                                // a pure translation fault from berr_r's own
                                // real-bus-error path

    logic [31:0] fill_base_r, fill_rdata_r;
    logic [3:0]  idx_r;
    logic [1:0]  woff_r;
    logic [24:0] vtag_r;

    // ic_burst_req/addr are registered (not driven combinationally from
    // `state`), mirroring biu_sizing_fsm.sv's own documented reason for
    // existing: "one cycle of latency (registered to break combinatorial
    // loops with cycle_gen)". The raw IFU->cycle_gen wiring this module
    // replaces always drove biu_cycle_gen's ifu_* port from an
    // already-registered source (fetch_pend_r); a purely combinational
    // case(state)-driven request here reproducibly hung biu_cycle_gen's
    // S6->S7 transition on the very first real linefill miss back in
    // Phase 128 (found via this project's own bisection-against-a-known-
    // working-path technique) — the same hazard applies identically to
    // the burst request port, so it gets the same registered treatment.
    logic        ic_burst_req_r;
    logic [31:0] ic_burst_addr_r;
    // Phase 158 Stage 4a: same reasoning applies identically to cg_req/
    // cg_addr when driven from IC_SINGLE_0..3 -- the disabled-bypass case
    // (cg_req=ifu_req directly) is safe because ifu_req is itself already
    // registered at the IFU; a state-machine-driven cg_req here needs the
    // same registered treatment as ic_burst_req_r above (found via a real
    // hang: 30+ seconds of 100% CPU with zero output on the very first
    // I-cache miss, since IBE resets to 0 so every existing test's own
    // first miss now routes through this path).
    logic        cg_single_req_r;
    logic [31:0] cg_single_addr_r;

    wire [3:0]  idx  = ifu_addr[7:4];
    wire [1:0]  woff = ifu_addr[3:2];
    wire [24:0] vtag = {ifu_fc[2], ifu_addr[31:8]};
    wire        ihit = icache_en && valid_i[idx] && (tag_i[idx] == vtag);

    // Is the IFU, right now, still asking for the exact longword this
    // in-flight transaction (idx_r/woff_r/vtag_r, latched at dispatch) is
    // servicing? False means the requester has moved on — see abandoned_r.
    wire same_req = ifu_req && (idx == idx_r) && (woff == woff_r) && (vtag == vtag_r);

    integer k;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IC_IDLE;
            berr_r          <= 1'b0;
            abandoned_r     <= 1'b0;
            xlate_fault_r   <= 1'b0;
            ic_burst_req_r  <= 1'b0;
            ic_burst_addr_r <= 32'h0;
            cg_single_req_r  <= 1'b0;
            cg_single_addr_r <= 32'h0;
            for (k = 0; k < 16; k++) valid_i[k] <= 1'b0;
        end else begin
            // CACR cache-clear operations (level-sensitive while asserted,
            // same convention as biu_cache_if.sv).
            if (cacr[3]) for (k = 0; k < 16; k++) valid_i[k] <= 1'b0; // CI
            if (cacr[2]) valid_i[caar[7:4]] <= 1'b0;                  // CEI

            case (state)
                IC_IDLE: begin
                    // Only the enabled-state-machine path (cache enabled,
                    // OR the MMU enabled and needing to translate every
                    // fetch regardless of caching, Phase 150) passes through
                    // IC_IDLE; the fully-disabled path is a pure
                    // combinational bypass below and never touches `state`.
                    if (ifu_req && (icache_en || tc_e)) begin
                        idx_r       <= idx;
                        woff_r      <= woff;
                        vtag_r      <= vtag;
                        fill_base_r <= {ifu_addr[31:4], 4'h0};
                        abandoned_r <= 1'b0;
                        if (ihit) begin
                            // ihit already requires icache_en, so this can
                            // only fire when the cache is genuinely enabled
                            // — no bus cycle at all, so no translation
                            // needed (BIU-154's own "0 additional bus
                            // cycles" hit penalty).
                            state <= IC_HIT;
                        end else if (tc_e) begin
                            state <= IC_XLATE;
                        end else if (ifreeze_en) begin
                            // Phase 158 Stage 5: FI=1 -- never replace the
                            // entry on a miss, regardless of IBE. Fetches
                            // the exact requested word (not the line base --
                            // there's no line-fill happening here), matching
                            // "the entry is not replaced" rather than the
                            // burst/single-fill paths' own whole-line intent.
                            state            <= IC_FROZEN_MISS;
                            cg_single_req_r  <= 1'b1;
                            cg_single_addr_r <= {ifu_addr[31:2], 2'b00};
                        end else if (iburst_en) begin
                            state           <= IC_BURST0;
                            ic_burst_req_r  <= 1'b1;
                            ic_burst_addr_r <= {ifu_addr[31:4], 4'h0};
                        end else begin
                            // Phase 158 Stage 4a: IBE=0 -- never assert
                            // CBREQ# at all.
                            state            <= IC_SINGLE_0;
                            cg_single_req_r  <= 1'b1;
                            cg_single_addr_r <= {ifu_addr[31:4], 4'h0};
                        end
                    end
                end

                IC_HIT: state <= IC_IDLE; // eu-style: ack fires combinationally, one-shot

                // Phase 150 (plan.md): translate before starting the real
                // burst/fill. xl_req held (output block, below) for the
                // whole time this state is active. fill_base_r must also be
                // updated to the translated line base — IC_FILL_1B/2B/3B's
                // own degraded-fallback addressing depends on it.
                IC_XLATE: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (xl_fault) begin
                        berr_r        <= 1'b1;
                        // Suppress the synthetic pulse for a real bus error
                        // during the walk -- biu_cycle_gen's own
                        // fault_valid_r already captured it independently
                        // (see biu_cache_if.sv's own identical comment).
                        xlate_fault_r <= !xl_fault_is_berr;
                        state         <= IC_DONE;
                    end else if (xl_hit || xl_walk_done) begin
                        fill_base_r     <= {xl_pa[31:4], 4'h0};
                        if (ifreeze_en) begin
                            // Phase 158 Stage 5: same FI=1 gate as IC_IDLE's
                            // own branch above, for the post-translation
                            // case -- fetches the translated word address
                            // directly, not the line base.
                            state            <= IC_FROZEN_MISS;
                            cg_single_req_r  <= 1'b1;
                            cg_single_addr_r <= {xl_pa[31:2], 2'b00};
                        end else if (iburst_en) begin
                            ic_burst_req_r  <= 1'b1;
                            ic_burst_addr_r <= {xl_pa[31:4], 4'h0};
                            state           <= IC_BURST0;
                        end else begin
                            state            <= IC_SINGLE_0;
                            cg_single_req_r  <= 1'b1;
                            cg_single_addr_r <= {xl_pa[31:4], 4'h0};
                        end
                    end
                end

                IC_BURST0: begin
                    // Latch "abandoned" the moment the requester moves on,
                    // not just at completion — same as the fill states in
                    // every other cache module in this project.
                    if (!same_req) abandoned_r <= 1'b1;
                    if (ic_burst_ack) begin
                        if (ic_burst_beat == 2'd3) begin
                            // Full 4-beat burst: CBACK# was asserted, all
                            // four words arrived in this one request.
                            data_i[idx_r][0] <= ic_burst_rdata0;
                            data_i[idx_r][1] <= ic_burst_rdata1;
                            data_i[idx_r][2] <= ic_burst_rdata2;
                            data_i[idx_r][3] <= ic_burst_rdata3;
                            case (woff_r)
                                2'd0: fill_rdata_r <= ic_burst_rdata0;
                                2'd1: fill_rdata_r <= ic_burst_rdata1;
                                2'd2: fill_rdata_r <= ic_burst_rdata2;
                                2'd3: fill_rdata_r <= ic_burst_rdata3;
                            endcase
                            // Phase 158 Stage 7: ciin checked once, for the
                            // whole line -- same "not true per-beat CIIN"
                            // documented simplification as biu_cache_if.sv's
                            // own identical burst-completion gate.
                            if (!ciin) begin
                                tag_i[idx_r]   <= vtag_r;
                                valid_i[idx_r] <= 1'b1;
                            end
                            state          <= IC_DONE;
                            ic_burst_req_r <= 1'b0;
                        end else begin
                            // Degraded: CBACK# never asserted, only word 0
                            // (this request's own beat 0) actually arrived —
                            // fall back to individually re-requesting the
                            // remaining three words.
                            data_i[idx_r][0] <= ic_burst_rdata0;
                            if (woff_r == 2'd0) fill_rdata_r <= ic_burst_rdata0;
                            state           <= IC_FILL_1B;
                            ic_burst_addr_r <= fill_base_r + 32'd4;
                            // ic_burst_req_r stays asserted for the next request.
                        end
                    end else if (ic_burst_berr) begin
                        berr_r         <= 1'b1;
                        xlate_fault_r  <= 1'b0;  // real bus error, not a translation fault
                        state          <= IC_DONE;
                        ic_burst_req_r <= 1'b0;
                    end
                end

                IC_FILL_1B: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (ic_burst_ack) begin
                        data_i[idx_r][1] <= ic_burst_rdata0;
                        if (woff_r == 2'd1) fill_rdata_r <= ic_burst_rdata0;
                        state           <= IC_FILL_2B;
                        ic_burst_addr_r <= fill_base_r + 32'd8;
                    end else if (ic_burst_berr) begin
                        berr_r         <= 1'b1;
                        xlate_fault_r  <= 1'b0;  // real bus error, not a translation fault
                        state          <= IC_DONE;
                        ic_burst_req_r <= 1'b0;
                    end
                end
                IC_FILL_2B: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (ic_burst_ack) begin
                        data_i[idx_r][2] <= ic_burst_rdata0;
                        if (woff_r == 2'd2) fill_rdata_r <= ic_burst_rdata0;
                        state           <= IC_FILL_3B;
                        ic_burst_addr_r <= fill_base_r + 32'd12;
                    end else if (ic_burst_berr) begin
                        berr_r         <= 1'b1;
                        xlate_fault_r  <= 1'b0;  // real bus error, not a translation fault
                        state          <= IC_DONE;
                        ic_burst_req_r <= 1'b0;
                    end
                end
                IC_FILL_3B: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (ic_burst_ack) begin
                        data_i[idx_r][3] <= ic_burst_rdata0;
                        if (woff_r == 2'd3) fill_rdata_r <= ic_burst_rdata0;
                        // Phase 158 Stage 7: same "checked once, at final
                        // completion" ciin gate as IC_BURST0's own full-
                        // burst branch above.
                        if (!ciin) begin
                            tag_i[idx_r]   <= vtag_r;
                            valid_i[idx_r] <= 1'b1;
                        end
                        state          <= IC_DONE;
                        ic_burst_req_r <= 1'b0;
                    end else if (ic_burst_berr) begin
                        berr_r         <= 1'b1;
                        xlate_fault_r  <= 1'b0;  // real bus error, not a translation fault
                        state          <= IC_DONE;
                        ic_burst_req_r <= 1'b0;
                    end
                end

                // Phase 158 Stage 4a: IBE=0 path -- 4 genuinely separate
                // ordinary reads via cg_req/cg_addr (driven in the output
                // block below), CBREQ# never asserted. Same per-word data
                // capture and tag/valid-on-last-word shape as
                // IC_BURST0/IC_FILL_1B/2B/3B above, just addressed off
                // fill_base_r directly instead of ic_burst_addr_r.
                // Root cause of the earlier stale-repeat bug (found via
                // direct cycle-counted tracing, see the "phase_r==2'd3"
                // discovery below): biu_cycle_gen only advances its own
                // internal state on 1 of every 4 clk_4x edges (the "4 ticks
                // per external bus cycle" design), so a combinational
                // ifu_ack tied to state==ST_READ_S7 genuinely reads high for
                // 4 consecutive clk_4x edges, not 1 -- reacting to raw
                // cg_ack (as an earlier draft did) re-triggered on every one
                // of those 4 edges, racing ahead through all 4 words in a
                // single real S7 window with 3 of the 4 "acks" reading
                // stale/repeated data. cg_ack_rise (declared above,
                // mirroring biu_cache_if.sv's own sf_ack_rise for the
                // identical reason) fixes it with no gap states needed --
                // same continuous-hold-req-and-advance-address shape as
                // IC_FILL_1B/2B/3B's own ic_burst_addr_r above, which never
                // hit this because ic_burst_ack is already a registered,
                // genuinely-one-tick pulse from biu_burst_ctrl.sv itself.
                IC_SINGLE_0: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (cg_ack_rise) begin
                        data_i[idx_r][0] <= cg_rdata;
                        if (woff_r == 2'd0) fill_rdata_r <= cg_rdata;
                        state            <= IC_SINGLE_1;
                        cg_single_addr_r <= fill_base_r + 32'd4;
                        // cg_single_req_r stays asserted for the next request.
                    end else if (cg_berr) begin
                        berr_r           <= 1'b1;
                        xlate_fault_r    <= 1'b0;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end
                end
                IC_SINGLE_1: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (cg_ack_rise) begin
                        data_i[idx_r][1] <= cg_rdata;
                        if (woff_r == 2'd1) fill_rdata_r <= cg_rdata;
                        state            <= IC_SINGLE_2;
                        cg_single_addr_r <= fill_base_r + 32'd8;
                    end else if (cg_berr) begin
                        berr_r           <= 1'b1;
                        xlate_fault_r    <= 1'b0;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end
                end
                IC_SINGLE_2: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (cg_ack_rise) begin
                        data_i[idx_r][2] <= cg_rdata;
                        if (woff_r == 2'd2) fill_rdata_r <= cg_rdata;
                        state            <= IC_SINGLE_3;
                        cg_single_addr_r <= fill_base_r + 32'd12;
                    end else if (cg_berr) begin
                        berr_r           <= 1'b1;
                        xlate_fault_r    <= 1'b0;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end
                end
                IC_SINGLE_3: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (cg_ack_rise) begin
                        data_i[idx_r][3] <= cg_rdata;
                        if (woff_r == 2'd3) fill_rdata_r <= cg_rdata;
                        // Phase 158 Stage 7: ciin, checked once at the
                        // line's final word -- the I-cache's own valid_i is
                        // one bit per whole line (not per word like the
                        // D-cache's valid_d), so there was only ever one
                        // real decision point to gate regardless of any
                        // per-word CIIN nuance across the 4 individual
                        // single-entry-mode reads.
                        if (!ciin) begin
                            tag_i[idx_r]     <= vtag_r;
                            valid_i[idx_r]   <= 1'b1;
                        end
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end else if (cg_berr) begin
                        berr_r           <= 1'b1;
                        xlate_fault_r    <= 1'b0;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end
                end

                // Phase 158 Stage 5: FI=1 -- a single ordinary fetch,
                // deliberately never touching data_i/tag_i/valid_i at all
                // ("the entry is not replaced"), unlike every other miss
                // path above which all end up validating the full line.
                IC_FROZEN_MISS: begin
                    if (!same_req) abandoned_r <= 1'b1;
                    if (cg_ack_rise) begin
                        fill_rdata_r     <= cg_rdata;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end else if (cg_berr) begin
                        berr_r           <= 1'b1;
                        xlate_fault_r    <= 1'b0;
                        state            <= IC_DONE;
                        cg_single_req_r  <= 1'b0;
                    end
                end

                IC_DONE: begin
                    berr_r        <= 1'b0;
                    abandoned_r   <= 1'b0;
                    xlate_fault_r <= 1'b0;
                    state         <= IC_IDLE;
                end

                default: state <= IC_IDLE;
            endcase
        end
    end

    // Output logic — disabled path is a pure combinational bypass (zero
    // added latency vs. the pre-existing direct ifu->cycle_gen wiring);
    // enabled path's ic_burst_req/addr come from the registers driven
    // above (see their own declaration comment for why), everything else
    // is still simple combinational state decode. cg_req/cg_addr are only
    // ever driven in the disabled branch now — the enabled-cache miss path
    // no longer touches biu_cycle_gen's ordinary ifu_* port at all.
    always_comb begin
        // Phase 150 (plan.md): MMU translation request, defaults
        xl_va  = fill_base_r;
        // Phase 158 Stage 2: was a separate hardcoded 3'b110 literal here;
        // now driven from the new ifu_fc input instead, consolidating to a
        // single source of truth with the fetch path's own FC (still tied
        // to the same 3'b110 constant at the call site today — see the
        // ic_burst_req port comment above for the full "genuine dynamic
        // S-bit-awareness is a separate, deeper, out-of-scope gap" writeup).
        xl_fc  = ifu_fc;
        xl_rw  = 1'b1;     // instruction fetches are always reads
        xl_req = 1'b0;

        xlate_fault_pulse = 1'b0;
        xlate_fault_addr  = fill_base_r;
        xlate_fault_fc    = ifu_fc;
        xlate_fault_rw    = 1'b1;
        xlate_fault_siz   = 2'b00;

        if (!icache_en && !tc_e) begin
            cg_addr       = ifu_addr;
            cg_req        = ifu_req;
            ifu_rdata     = cg_rdata;
            ifu_ack       = cg_ack;
            ifu_berr      = cg_berr;
            ic_burst_req  = 1'b0;
            ic_burst_addr = 32'h0;
        end else begin
            // Phase 158 Stage 4a: cg_req/cg_addr, like ic_burst_req/addr
            // above, must come from registers (cg_single_req_r/addr_r) while
            // the cache is enabled -- an earlier draft drove them
            // combinationally per-state here (case(state): cg_req=1;
            // cg_addr=fill_base_r+offset), which reproduced the exact Phase
            // 128 combinational-loop hazard documented on ic_burst_req_r's
            // own declaration comment (hung biu_cycle_gen's S6->S7
            // transition on the very first real single-word-fallback fetch).
            // The disabled-bypass branch above can stay combinational since
            // there cg_req/addr just mirror the raw ifu_req/addr inputs
            // directly, not a locally-computed case(state) value.
            cg_addr       = cg_single_addr_r;
            cg_req        = cg_single_req_r;
            ic_burst_req  = ic_burst_req_r;
            ic_burst_addr = ic_burst_addr_r;
            ifu_rdata     = 32'h0;
            ifu_ack       = 1'b0;
            ifu_berr      = 1'b0;

            case (state)
                IC_XLATE: begin
                    xl_req = 1'b1;   // held for the whole translation window
                end

                IC_HIT: begin
                    // Single-cycle transaction: check same_req live rather
                    // than via abandoned_r (which only ever gets set from
                    // the multi-cycle fill states) — if the requester moved
                    // on in the one cycle between dispatch and this HIT
                    // resolving, don't hand back a now-stale ack either.
                    if (same_req) begin
                        ifu_rdata = data_i[idx_r][woff_r];
                        ifu_ack   = 1'b1;
                    end
                end
                IC_DONE: begin
                    if (abandoned_r) begin
                        // Requester moved on mid-fill/mid-berr — the array
                        // update (if any) already happened; silently drop
                        // this stale ack/berr instead of misattributing it
                        // to whatever the IFU has since re-armed for.
                    end else if (berr_r) begin
                        ifu_berr = 1'b1;
                        // Phase 150 (plan.md): a pure translation fault (no
                        // real bus error) needs a synthetic fault-capture
                        // pulse, since biu_cycle_gen's own fault_valid_r
                        // never fires for one.
                        xlate_fault_pulse = xlate_fault_r;
                    end else begin
                        ifu_rdata = fill_rdata_r;
                        ifu_ack   = 1'b1;
                    end
                end
                default: ; // IC_IDLE, IC_BURST0, IC_FILL_1B/2B/3B (ic_burst_req/addr already set above)
            endcase
        end
    end

endmodule

`default_nettype wire

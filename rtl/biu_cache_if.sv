`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Cache Interface
// Implements D-cache hit/miss detection and linefill sequencing for the
// EU's own data accesses. (An earlier revision also carried a parallel,
// EU-side I-cache array, gated by an `eu_is_icache` port m68030_top.sv
// always tied to 1'b0 -- fully dead code, since Phase 127 wired the real
// I-cache through the IFU's own dedicated biu_icache_if.sv instead. Removed
// in the efficiency/clarity backlog's own Stage 1 -- see plan.md.)
// On D-cache read miss (ED): issues 1 longword read, stores one word.
// On any write (ED): write-through — always issues write to bus; updates cache on hit.
// Cache inhibit (mmu_ci): bypasses cache allocation even if enabled.

module biu_cache_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // EU side
    input  logic [31:0] eu_addr,
    input  logic [2:0]  eu_fc,
    input  logic        eu_rw,         // 1=read, 0=write
    input  logic [1:0]  eu_siz,
    input  logic [31:0] eu_wdata,
    input  logic        eu_req,
    output logic [31:0] eu_rdata,
    output logic        eu_ack,
    output logic        eu_berr,

    // Phase 158 Stage 3: true for the entire read phase of TAS/CAS/CAS2
    // (manual §6.1.2.2: "The read portion of a read-modify-write cycle is
    // always forced to miss in the data cache"). Forces dhit=0 on the
    // lookup only -- the read's own returned data still populates/updates
    // the cache entry afterward as normal (not a full cache-bypass).
    input  logic        mem_rmw_lookup,

    // Cache Inhibit from MMU
    input  logic        mmu_ci,

    // Phase 158 Stage 7: CIIN (peripheral says "this data isn't
    // cacheable" -- already synchronized by biu_config.sv). Manual
    // §6.1.3.1/6.1.3.2 (confirmed by direct re-read): ignored on write
    // cycles, so this only ever suppresses caching on a fill/read-miss.
    input  logic         ciin,
    // CIOUT (CPU says "this access is definitely non-cacheable") --
    // combinational, reflects the currently-dispatched access, manual
    // Figure 6-3/p.6-9's own listed conditions: MMU CI-page (mmu_ci, this
    // module's own pre-existing input -- see its own header note on why
    // this doesn't yet reflect a live per-access MMU translation result,
    // a separate, already-documented Phase 150 deferral this stage
    // deliberately doesn't also fix), the forced-miss RMW read
    // (mem_rmw_lookup), CPU space (FC=111), or the D-cache simply
    // disabled.
    output logic          ciout,

    // Sizing-FSM side (for miss / write cycles)
    output logic [31:0] sf_addr,
    output logic [2:0]  sf_fc,
    output logic        sf_rw,
    output logic [1:0]  sf_siz,
    output logic [31:0] sf_wdata,
    output logic        sf_is_op,
    output logic        sf_req,
    input  logic [31:0] sf_rdata,
    input  logic        sf_ack,    // 1-tick pulse from sizing_fsm SS_DONE
    input  logic        sf_berr,

    // Phase 158 Stage 4c: D-cache burst-linefill request, muxed by
    // m68030_biu.sv into biu_cycle_gen's own eu_burst_req/addr/fc port --
    // same mechanism biu_icache_if.sv's own ic_burst_req already uses
    // (Phase 127 cache plan Step 8), just a second, D-side client sharing
    // it. FC is fixed at the caller to fc_r (this access's own real FC),
    // matching sf_fc's own convention above -- unlike the I-side, which
    // hardcodes Supervisor Program Space, the D-side already threads real
    // FC through everywhere else in this module.
    output logic         dc_burst_req,
    output logic [31:0]  dc_burst_addr,
    output logic [2:0]   dc_burst_fc,
    input  logic [31:0]  dc_burst_rdata0,
    input  logic [31:0]  dc_burst_rdata1,
    input  logic [31:0]  dc_burst_rdata2,
    input  logic [31:0]  dc_burst_rdata3,
    input  logic [1:0]   dc_burst_beat,   // beat reached when dc_burst_ack fires (3=full, 0=degraded)
    // Deferred-items closure plan Stage 9 (plan.md): the beat that was in
    // flight when dc_burst_berr fired -- see biu_burst_ctrl.sv's own
    // burst_beat_at_berr port comment. Only meaningful the same cycle
    // dc_burst_berr pulses.
    input  logic [1:0]   dc_burst_beat_at_berr,
    // 10-item backlog Stage 3 (plan.md): per-beat CIIN, captured by
    // biu_burst_ctrl.sv at the same cadence as dc_burst_rdataN above --
    // used to gate valid_d PER WORD on a completed burst fill, instead of
    // the old whole-line all-or-nothing decision (see the CI_D_BURST0/
    // CI_D_FILL_3B bodies below).
    input  logic         dc_burst_ciin0,
    input  logic         dc_burst_ciin1,
    input  logic         dc_burst_ciin2,
    input  logic         dc_burst_ciin3,
    input  logic         dc_burst_ack,
    input  logic         dc_burst_berr,

    // Control registers (written by EU via MOVEC)
    input  logic [31:0] cacr,
    input  logic [31:0] caar,

    // MMU translation control (Phase 150, plan.md) — only tc[31]=E is used
    // here; the actual walk/ATC logic lives entirely in biu_mmu_if.sv.
    input  logic [31:0] tc,

    // MMU translation request/response (Phase 150, plan.md) — arbitrated
    // via biu_mmu_arb.sv, one physical biu_mmu_if instance shared with the
    // I-cache side (biu_icache_if.sv) and the existing top-level (PTEST)
    // requester. va/fc/rw/req held as a level for the whole CI_XLATE
    // window (see biu_mmu_arb.sv's own header for why this is safe).
    output logic [31:0] xl_va,
    output logic [2:0]  xl_fc,
    output logic        xl_rw,
    output logic        xl_req,
    input  logic [31:0] xl_pa,
    input  logic        xl_hit,
    input  logic        xl_walk_done,
    input  logic        xl_fault,
    input  logic        xl_fault_is_berr, // 1=real bus error during the walk
                                           // (biu_cycle_gen already captured
                                           // it independently -- suppress
                                           // the synthetic pulse below to
                                           // avoid a stale double-capture)
    input  logic        xl_ci,   // acted on since 10-item backlog Stage 2
    input  logic        xl_wp,

    // Synthetic fault-capture pulse for biu_exc_capture (Phase 150,
    // plan.md) — fires the cycle a pure translation/WP fault (no real bus
    // error at all) is detected. biu_cycle_gen's own fault_valid_r only
    // ever fires for a genuine external BERR sampled during a real bus
    // cycle, which an invalid-descriptor or WP fault never generates.
    output logic         xlate_fault_pulse,
    output logic [31:0]  xlate_fault_addr,
    output logic [2:0]   xlate_fault_fc,
    output logic         xlate_fault_rw,
    output logic [1:0]   xlate_fault_siz
);

    // Phase 150 (plan.md): mmu_ci (input above) still gates the
    // pre-translation dhit lookup in CI_IDLE, unavoidably (see dhit's own
    // declaration comment). 10-item backlog Stage 2 (plan.md): every LATER
    // use (ciout, dhit_r, the CI_D_MISS populate decision) now uses xl_ci_r
    // instead -- this access's own genuinely-translated CI bit, captured
    // once from xl_ci at the exact cycle CI_XLATE completes (see xl_ci_r's
    // own declaration comment for why the raw mmu_ci/xl_ci ports, both
    // literally the same shared arbiter broadcast, aren't safe to re-read
    // in a later cycle).
    wire tc_e = tc[31];

    // CACR bit aliases (Figure 6-14: 13=WA,12=DBE,11=CD,10=CED,9=FD,8=ED,
    // 4=IBE,3=CI,2=CEI,1=FI,0=EI — confirmed directly against the manual).
    // Phase 158 Stage 1: dcache_en previously read cacr[9] (FD, freeze) instead
    // of cacr[8] (ED, enable) -- a real, previously-undiscovered bug meaning
    // software that set ED the textbook-correct way got a D-cache that never
    // activated. See plan.md Phase 158 Stage 1 for the full derivation.
    wire dcache_en = cacr[8];
    wire wa_en     = cacr[13];
    wire dburst_en = cacr[12];
    // Phase 158 Stage 5: manual §6.3.1.5 (confirmed by direct re-read):
    // "When the FD bit is set and a miss occurs during a read or write of
    // the data cache, the indexed entry is not replaced. However, write
    // cycles that hit in the data cache cause the entry to be updated even
    // when the cache is frozen." -- gates every miss-side allocate/replace
    // path below (CI_D_MISS/CI_D_BURST0 dispatch, CI_WRITE's own WA-driven
    // allocate); CI_WRITE's write-*hit* update (`if (dhit_r)`) is
    // deliberately left completely ungated, matching that exception
    // exactly.
    wire dfreeze_en = cacr[9];

    // Cache storage arrays
    // Phase 158 Stage 2: tag width widened from 24 to 27 bits (was
    // addr[31:8] alone) to include FC0-2, per manual §6.1.2 (p.6-6): "The
    // tag of each line in the data cache contains function code bits FC0,
    // FC1, and FC2 in addition to address bits A31-A8." Without this, a
    // supervisor and user access to the same logical address alias onto
    // the same cache line and can hit each other's data -- a real
    // correctness bug, confirmed against the manual before fixing (not
    // guessed at).

    // valid_d is per-WORD, not per-line -- a D-cache miss
    // (CI_D_MISS, below) only ever fetches and fills the ONE word offset
    // actually requested (matching real 68030 hardware's own documented
    // single-longword D-cache fill, unlike the I-cache's 4-word burst
    // linefill), so a single per-line valid bit would incorrectly mark
    // the other 3, never-fetched word slots in that line as "valid" too --
    // a real bug found empirically in Phase 133 (a same-line, different-
    // offset D-cache read returned uninitialized garbage, reported as a
    // cache HIT).
    logic        valid_d [0:15][0:3];
    logic [26:0] tag_d   [0:15];
    logic [31:0] data_d  [0:15][0:3];

    // Extract byte/word from raw longword into EU-convention LSB position.
    // The cache always fetches full longwords; the EU expects byte in [7:0],
    // word in [15:0], longword in [31:0].
    function automatic logic [31:0] extract_rd(
        input logic [31:0] raw,
        input logic [1:0]  siz,
        input logic [1:0]  addr_lo
    );
        case (siz)
            2'b01: // byte
                case (addr_lo)
                    2'b00: extract_rd = {24'b0, raw[31:24]};
                    2'b01: extract_rd = {24'b0, raw[23:16]};
                    2'b10: extract_rd = {24'b0, raw[15:8]};
                    2'b11: extract_rd = {24'b0, raw[7:0]};
                endcase
            2'b10: // word
                extract_rd = addr_lo[1] ? {16'b0, raw[15:0]}
                                        : {16'b0, raw[31:16]};
            default: extract_rd = raw; // longword or line: passthrough
        endcase
    endfunction

    // Merge a write into one cached longword slot, for the write-through
    // cache-update path. wdata is TOP-justified (eu_seq.sv's own eu_lane()
    // convention for mem_wdata: byte in [31:24], word in [31:16],
    // regardless of the real target address) -- NOT the same LSB-justified
    // convention extract_rd() returns to the EU on a read. Re-positions the
    // meaningful bits into the correct byte lane of the raw (big-endian,
    // byte0=[31:24]) longword the cache actually stores, merging with the
    // slot's own existing bytes for a sub-longword write so the OTHER
    // bytes -- genuinely unrelated to this write -- are preserved rather
    // than clobbered. A prior version wrote wdata_r into the cache slot
    // directly and unconditionally, which only ever happened to be correct
    // when the write address was 4-byte aligned (addr_lo=00, where
    // TOP-justified and raw-longword-byte0 positions coincide) --
    // otherwise it silently corrupted the slot's other, unrelated bytes
    // with garbage (found via code inspection alongside the CI_D_MISS read
    // bug during Step 6's D-cache investigation; both bugs share the same
    // root cause, this module's cache-array bookkeeping never accounting
    // for its own callers' byte-lane conventions).
    function automatic logic [31:0] merge_wr(
        input logic [31:0] cur,
        input logic [31:0] wdata,
        input logic [1:0]  siz,
        input logic [1:0]  addr_lo
    );
        case (siz)
            2'b01: // byte
                case (addr_lo)
                    2'b00: merge_wr = {wdata[31:24], cur[23:0]};
                    2'b01: merge_wr = {cur[31:24], wdata[31:24], cur[15:0]};
                    2'b10: merge_wr = {cur[31:16], wdata[31:24], cur[7:0]};
                    2'b11: merge_wr = {cur[31:8],  wdata[31:24]};
                endcase
            2'b10: // word
                merge_wr = addr_lo[1] ? {cur[31:16], wdata[31:16]}
                                      : {wdata[31:16], cur[15:0]};
            default: merge_wr = wdata; // longword: full replace
        endcase
    endfunction

    // sf_ack is a 1-tick pulse — edge detect is same as raw, but kept for safety
    logic sf_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) sf_ack_prev_r <= 1'b0;
        else        sf_ack_prev_r <= sf_ack;
    wire sf_ack_rise = sf_ack && !sf_ack_prev_r;

    // State machine
    typedef enum logic [3:0] {
        CI_IDLE   = 4'd0,
        CI_HIT    = 4'd1,
        // 4'd2-4'd5 previously CI_FILL_0..3, the dead EU-side I-cache
        // linefill sequence -- removed (see this file's own header).
        CI_D_MISS = 4'd6,
        CI_WRITE  = 4'd7,
        CI_DONE   = 4'd8,
        CI_BERR   = 4'd9,
        CI_XLATE  = 4'd10,  // Phase 150, plan.md
        // Phase 158 Stage 4c: DBE=1 D-cache burst linefill -- same
        // full-burst-vs-degraded-fallback shape as biu_icache_if.sv's own
        // IC_BURST0/IC_FILL_1B/2B/3B, applied to data_d/tag_d/valid_d
        // instead of the I-side arrays. Unlike CI_D_MISS (which only ever
        // fetches and validates the ONE word slot actually requested), a
        // burst fetches and validates the WHOLE line, matching real 68030
        // hardware's own line-fill semantics for a burst-capable miss.
        CI_D_BURST0  = 4'd11,
        CI_D_FILL_1B = 4'd12,
        CI_D_FILL_2B = 4'd13,
        CI_D_FILL_3B = 4'd14
    } ci_state_t;

    ci_state_t state;

    // Latched request parameters
    logic [31:0] addr_r, wdata_r, fill_base_r;
    logic [2:0]  fc_r;
    logic        rw_r;
    logic [1:0]  siz_r;
    logic [3:0]  idx_r;
    logic [1:0]  woff_r;
    logic [26:0] vtag_r;
    logic [31:0] fill_rdata_r;  // captured rdata for CI_DONE return
    // 10-item backlog Stage 3 (plan.md): degraded-burst-fallback per-beat
    // CIIN capture. dc_burst_ciin0 is reused for every individual degraded
    // request (mirroring dc_burst_rdata0's own reuse), so by the time
    // CI_D_FILL_3B's own completion is reached it only reflects beat 3's
    // own value -- each earlier beat's own CIIN must be stashed here as it
    // arrives (same reasoning data_d[]'s own progressive-population-then-
    // atomic-valid_d/tag_d-commit pattern already established: committing
    // valid_d/tag_d piecemeal, before the whole line's own tag is settled,
    // would open a transient window where a concurrent access could hit
    // with a stale tag).
    logic        degraded_ciin_r [0:3];
    logic        xlate_fault_r; // Phase 150: distinguishes a CI_BERR entered
                                 // from CI_XLATE (pure translation/WP fault,
                                 // no real bus error) from one entered via a
                                 // genuine sf_berr elsewhere
    // 10-item backlog Stage 2 (plan.md): this access's own genuinely
    // translated CI bit, captured exactly once (CI_XLATE's own
    // xl_hit/xl_walk_done transition, below) -- unlike the raw mmu_ci/
    // xl_ci PORTS (both literally the same shared arbiter broadcast,
    // biu_mmu_arb.sv's own "harmless to broadcast... valid the whole
    // time" contract only guarantees correctness on the EXACT cycle this
    // requester's own hit/walk_done/fault pulses fire -- reading it any
    // LATER cycle risks showing a completely different, concurrently
    // in-flight I-side/EXT-side walk's result instead), xl_ci_r stays
    // correct for this access's own entire remaining lifetime regardless
    // of what the shared MMU resource does afterward. Reset to 0 at every
    // fresh dispatch (CI_IDLE, below) -- correctly represents "no CI info"
    // for an untranslated (tc_e=0) access without needing a separate
    // was-this-access-translated flag.
    logic        xl_ci_r;

    // Phase 158 Stage 4c: dc_burst_req/addr must come from registers, not a
    // combinational case(state) computation -- the exact Phase 128 hazard
    // biu_icache_if.sv's own ic_burst_req_r declaration comment documents
    // (a state-machine-driven request into biu_cycle_gen needs one cycle of
    // registered latency to avoid a combinatorial loop) applies identically
    // here, so this is built registered from the start rather than
    // repeating that discovery.
    logic        dc_burst_req_r;
    logic [31:0] dc_burst_addr_r;

    // 10-item backlog Stage 6 (plan.md): a BERR on a beat AT OR BEFORE the
    // CPU's own actually-requested word (woff_r >= dc_burst_beat_at_berr)
    // used to fault unconditionally -- real 68030 silicon (and this RTL,
    // for the "after" sub-case, Stage 9 of the earlier deferred-items
    // closure plan) allows a fresh attempt, so one genuine retry is
    // warranted before escalating to a real Bus Error. Reset to 0 at both
    // CI_D_BURST0 dispatch sites below; set once the first retry is spent
    // so a second failure at/before the requested word escalates for real
    // rather than retrying forever.
    logic        dc_retry_used_r;

    // Combinatorial hit detection (in CI_IDLE, before latching)
    wire [3:0]  idx  = eu_addr[7:4];
    wire [1:0]  woff = eu_addr[3:2];
    wire [26:0] vtag = {eu_fc, eu_addr[31:8]};

    // d_size_ok: this single-slot cache model (one valid_d/data_d entry per
    // 4-byte-aligned word) can only ever represent an access that fits
    // entirely within ONE aligned slot -- true for any byte/word access
    // (always <=2 bytes, and extract_rd()/merge_wr() handle sub-slot
    // positioning) and for a naturally-aligned longword (siz=00,
    // addr[1:0]=00, exactly one whole slot). A MISALIGNED longword access
    // (siz=00, addr[1:0]!=00) genuinely spans TWO different slots (e.g.
    // addr[1:0]=10 needs the top 2 bytes of this slot and the bottom 2
    // bytes of the NEXT one) -- there is no single data_d[idx][woff] entry
    // that can hold or serve that. A prior version had no such exclusion:
    // dhit/CI_D_MISS's caching logic treated "the aligned slot containing
    // the request" as if it fully answered ANY request touching that
    // address, silently returning half-real-half-wrong data for the
    // misaligned-longword case -- found via Step 6's D-cache sweep tracing
    // RTR (CCR-word-pop then PC-longword-pop from SP+2, an inherently
    // 2-byte-offset stack layout every RTR/RTE naturally produces) through
    // to a wild PC value and a corrupted A7. Excluding this shape from
    // ever hitting or being cached falls back to the same per-access
    // passthrough fetch already proven correct for the disabled-cache
    // case (sizing_fsm/cycle_gen already handle a misaligned longword
    // bus transfer correctly on their own) -- a deliberate "don't try to
    // cache this rare shape" scope boundary, not a full multi-slot
    // cache-fetch implementation.
    wire d_size_ok   = !(eu_siz   == 2'b00 && eu_addr[1:0]   != 2'b00);
    wire d_size_ok_r = !(siz_r    == 2'b00 && addr_r[1:0]    != 2'b00);

    // Phase 158 Stage 3: !mem_rmw_lookup forces a miss for the read half of
    // TAS/CAS/CAS2, per manual §6.1.2.2 -- only gates the read-time LOOKUP
    // (this combinational dhit, sampled at dispatch in CI_IDLE); dhit_r
    // below (used later for the RMW's own write-phase update) is
    // deliberately untouched, since by the write phase mem_rmw_lookup has
    // already gone low and the write should update the cache normally on
    // a genuine hit, same as any other write.
    //
    // 10-item backlog Stage 2 (plan.md): dhit deliberately still reads the
    // live mmu_ci broadcast, NOT xl_ci_r -- this check happens in CI_IDLE,
    // before this access's own translation (if any) has even started, so
    // no per-access CI value exists yet to use. This is a genuine, real
    // structural limitation of the virtually-indexed/virtually-tagged
    // lookup this cache uses (the hit/miss decision is made before the
    // physical address, and therefore the real page attributes, are known)
    // -- fixing it would need a fast pre-translation CI-check mechanism
    // (e.g. a combinational TT0/TT1 transparent-window check) this
    // simplified model doesn't have. Documented, not attempted this stage.
    wire dhit = dcache_en && d_size_ok && valid_d[idx][woff] && (tag_d[idx] == vtag) && !mmu_ci && !mem_rmw_lookup;

    // Also need dhit based on latched idx_r/vtag_r for write update in
    // CI_WRITE -- unlike dhit above, this is evaluated well after dispatch
    // (CI_WRITE's own sf_ack_rise, possibly many cycles later), so it uses
    // xl_ci_r (this access's own captured value), not the live mmu_ci
    // broadcast, which could show a different, concurrently in-flight
    // requester's result by then.
    wire dhit_r = dcache_en && d_size_ok_r && valid_d[idx_r][woff_r] && (tag_d[idx_r] == vtag_r) && !xl_ci_r;

    integer k, m;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state       <= CI_IDLE;
            fill_rdata_r <= 32'h0;
            xlate_fault_r <= 1'b0;
            dc_burst_req_r  <= 1'b0;
            dc_burst_addr_r <= 32'h0;
            dc_retry_used_r <= 1'b0;
            for (k = 0; k < 16; k++) begin
                for (m = 0; m < 4; m++) valid_d[k][m] <= 1'b0;
            end
        end else begin
            // CACR cache-clear operations (level-sensitive while bit asserted)
            // Phase 158 Stage 1: CD/CED were off by one bit (cacr[12]/cacr[11]
            // are really DBE/CD, not CD/CED) — fixed to cacr[11]/cacr[10].
            if (cacr[11]) for (k = 0; k < 16; k++) for (m = 0; m < 4; m++) valid_d[k][m] <= 1'b0; // CD
            if (cacr[10]) for (m = 0; m < 4; m++) valid_d[caar[7:4]][m] <= 1'b0;  // CED

            case (state)
                CI_IDLE: begin
                    if (eu_req) begin
                        addr_r      <= eu_addr;
                        wdata_r     <= eu_wdata;
                        fc_r        <= eu_fc;
                        rw_r        <= eu_rw;
                        siz_r       <= eu_siz;
                        idx_r       <= idx;
                        woff_r      <= woff;
                        vtag_r      <= vtag;
                        fill_base_r <= {eu_addr[31:4], 4'h0};
                        xl_ci_r     <= 1'b0;  // default "no CI"; CI_XLATE
                                               // overwrites with the real
                                               // value if this access is
                                               // actually translated below

                        if (eu_rw && dhit) begin
                            // Cache hit — serve from cache array (idx_r/woff_r
                            // latched above). No bus cycle at all, so no
                            // translation needed either way (Phase 150,
                            // plan.md) — matches BIU-154's own "0 additional
                            // bus cycles" hit-penalty spec.
                            state <= CI_HIT;
                        end else if (tc_e) begin
                            // Phase 150 (plan.md): any access that DOES need
                            // a real bus cycle (a miss, or any write —
                            // write-through always goes to the bus even on a
                            // hit) needs its address translated first when
                            // the MMU is enabled.
                            state <= CI_XLATE;
                        end else if (!eu_rw) begin
                            state <= CI_WRITE;
                        end else if (dcache_en && dburst_en && d_size_ok && !dfreeze_en) begin
                            // Phase 158 Stage 4c: DBE=1 -- genuine burst
                            // linefill instead of CI_D_MISS's own
                            // single-longword fill. Gated on d_size_ok (not
                            // d_size_ok_r -- addr_r isn't latched yet this
                            // cycle) for the same reason CI_D_MISS's own
                            // cache-populate branch is: a misaligned
                            // long-word access already permanently bypasses
                            // the D-cache entirely (Phase 134's own
                            // single-slot-model boundary), so it must not
                            // start a burst either.
                            //
                            // 10-item backlog Stage 2 (plan.md): no mmu_ci
                            // check here -- this branch is reached only when
                            // !tc_e (the `tc_e` branch above already claimed
                            // that case), so this access is never MMU-
                            // translated at all. MMU-derived CI is
                            // architecturally meaningless without a
                            // translation; the shared mmu_ci broadcast could
                            // still show a stale 1 left over from an earlier,
                            // unrelated translated/PTESTed access (it only
                            // ever resets on chip reset), which would have
                            // wrongly blocked D-cache bursting here forever
                            // after any one-time MMU use, however unrelated.
                            state           <= CI_D_BURST0;
                            dc_burst_req_r  <= 1'b1;
                            dc_burst_addr_r <= {eu_addr[31:4], 4'h0};
                            dc_retry_used_r <= 1'b0;
                        end else begin
                            state <= CI_D_MISS;
                        end
                    end
                end

                CI_HIT: begin
                    // eu_ack fires combinatorially this cycle; return next cycle
                    state <= CI_IDLE;
                end

                // Phase 150 (plan.md): translate addr_r (still logical here)
                // before proceeding to the real bus cycle. xl_req is held
                // (output block, below) for the whole time this state is
                // active — see biu_mmu_arb.sv's own header for why that's
                // safe. A write to a write-protected page aborts exactly
                // like a genuine translation fault.
                CI_XLATE: begin
                    if (xl_fault || (xl_wp && !rw_r)) begin
                        // A WP violation is always a purely logical fault
                        // (checked before any real access, no bus cycle
                        // involved). xl_fault might be a real bus error
                        // during the walk (biu_cycle_gen's own
                        // fault_valid_r already captured it independently)
                        // or a purely logical one (invalid descriptor) --
                        // only the logical case needs our own synthetic
                        // capture pulse; firing it for the real-BERR case
                        // too would double-capture and stomp the correct
                        // first capture with a later, stale one.
                        xlate_fault_r <= xl_fault ? !xl_fault_is_berr : 1'b1;
                        state         <= CI_BERR;
                    end else if (xl_hit || xl_walk_done) begin
                        // Overwrite the logical address with the translated
                        // PA in place. Safe: page-offset bits (including
                        // addr_r[1:0], which CI_WRITE's merge_wr() depends
                        // on) pass through translation unchanged — only the
                        // page-frame bits above the page boundary differ.
                        addr_r  <= xl_pa;
                        // 10-item backlog Stage 2 (plan.md): capture THIS
                        // access's own just-completed translation result for
                        // every later cycle to use instead of re-reading the
                        // shared (and by then possibly reused-by-someone-
                        // else) mmu_ci broadcast -- see xl_ci_r's own
                        // declaration comment. The `!mmu_ci` check
                        // immediately below is deliberately left reading the
                        // live port, not xl_ci_r, since it's evaluated the
                        // SAME cycle xl_ci_r is being written here
                        // (non-blocking assignment -- xl_ci_r's new value
                        // isn't visible until next cycle) and the arbiter's
                        // own contract guarantees mmu_ci is already correct
                        // for this exact requester on this exact cycle.
                        xl_ci_r <= xl_ci;
                        if (!rw_r) begin
                            state <= CI_WRITE;
                        end else if (dcache_en && dburst_en && !mmu_ci && d_size_ok_r && !dfreeze_en) begin
                            // Phase 158 Stage 4c: same DBE-gated burst
                            // dispatch as CI_IDLE's own branch above, for
                            // the post-translation case.
                            state           <= CI_D_BURST0;
                            dc_burst_req_r  <= 1'b1;
                            dc_burst_addr_r <= {xl_pa[31:4], 4'h0};
                            dc_retry_used_r <= 1'b0;
                        end else begin
                            state <= CI_D_MISS;
                        end
                    end
                end

                CI_D_MISS: begin
                    if (sf_ack_rise) begin
                        // Phase 158 Stage 5: !dfreeze_en added -- FD=1 means
                        // "a miss does not replace the indexed entry" (manual
                        // §6.3.1.5), so a frozen miss falls into the same
                        // else branch a disabled/inhibited cache already
                        // uses (plain passthrough at the CPU's own requested
                        // size, cache array untouched).
                        //
                        // Phase 158 Stage 7: ciin (sampled live at the
                        // fill's own completion -- this is a read-only
                        // state, CI_WRITE handles writes separately,
                        // matching the manual's own "CIIN is ignored on
                        // write cycles") is checked *separately* from the
                        // would-cache decision below, not folded into the
                        // same if/else as dfreeze_en etc: the bus request
                        // itself (output block, sf_addr/sf_siz forced to a
                        // longword) is already committed before CIIN's own
                        // value is even knowable (it only arrives alongside
                        // the peripheral's own DSACK/ack), so sf_rdata here
                        // still genuinely holds a full longword regardless
                        // of whether CIIN ends up asserted -- unlike the
                        // genuinely-disabled/inhibited case below (where
                        // the output block requests siz_r, the CPU's own
                        // real size, and a raw passthrough is correct),
                        // a CIIN-blocked would-have-cached fetch still needs
                        // extract_rd() for its own return value, just
                        // without the array-population side effects.
                        // 10-item backlog Stage 2 (plan.md): xl_ci_r, not
                        // mmu_ci -- sf_ack_rise can land many cycles after
                        // this access's own dispatch/translation, by which
                        // point the shared mmu_ci broadcast may already
                        // reflect an unrelated, concurrently in-flight
                        // I-side/EXT-side walk.
                        if (dcache_en && !xl_ci_r && d_size_ok_r && !dfreeze_en) begin
                            // Cache-enabled miss: the combinational output
                            // block below forces sf_siz=2'b00 (longword) and
                            // sf_addr to the 4-byte-aligned slot address for
                            // this case, so sf_rdata here genuinely holds
                            // the FULL longword regardless of how small the
                            // CPU's own request was -- extract its specific
                            // sub-portion for the return value (same
                            // extract_rd() CI_HIT already uses for a cache
                            // hit) whether or not it also ends up cached.
                            // A prior version cached sf_rdata directly-as-
                            // fetched at the CPU's own (possibly sub-
                            // longword) size and still marked the whole
                            // word-slot valid -- silently caching only PART
                            // of the slot as if the rest were also freshly
                            // fetched, when sizing_fsm's own normalization
                            // for a byte/word request has no obligation to
                            // reflect the other bytes' real memory content
                            // at all. A later access to a DIFFERENT byte
                            // range within that same 4-byte slot (e.g.
                            // RTR's own back-to-back CCR-word + PC-longword
                            // pop, both landing in one slot) would then hit
                            // and be served that bogus data -- root-caused
                            // via Step 6's D-cache-only Harte sweep (RTR
                            // index 0: both reads returned the identical
                            // raw CCR word, one of them silently wrong)
                            // before this fix.
                            fill_rdata_r <= extract_rd(sf_rdata, siz_r, addr_r[1:0]);
                            if (!ciin) begin
                                data_d[idx_r][woff_r] <= sf_rdata; // full, genuinely-fetched longword
                                // A tag mismatch means this line's other 3
                                // word slots belong to a completely
                                // different, now-replaced address --
                                // invalidate them too, not just the one
                                // word this fill actually populates. If the
                                // tag already matches (same line, just a
                                // different word offset that was never
                                // independently fetched before), leave the
                                // other slots' own validity untouched.
                                if (tag_d[idx_r] != vtag_r)
                                    for (m = 0; m < 4; m++) valid_d[idx_r][m] <= 1'b0;
                                tag_d[idx_r]            <= vtag_r;
                                valid_d[idx_r][woff_r]  <= 1'b1;
                            end
                            // ciin=1: peripheral says this data isn't
                            // cacheable -- fill_rdata_r above still returns
                            // it to the CPU, but the array is left
                            // completely untouched (Phase 158 Stage 7).
                        end else begin
                            // Cache disabled (or MMU-inhibited): unchanged
                            // passthrough -- sizing_fsm already normalizes
                            // byte/word for the 32-bit port at the CPU's own
                            // requested size; for IFU (sf_siz=00 LW),
                            // sf_rdata is a full longword passthrough.
                            fill_rdata_r <= sf_rdata;
                        end
                        // Bus-pipelining-overlap plan.md, Track D Stage D1:
                        // goes straight to CI_IDLE, not CI_DONE -- mirrors
                        // Stage D0's own CI_WRITE fix exactly (see that
                        // stage's comment for why skipping CI_DONE outright,
                        // rather than trying to suppress its own eu_ack
                        // conditionally, is the safe way to avoid a
                        // double-pulsed eu_ack). The cache-populate side
                        // effects above (data_d/tag_d/valid_d, and this
                        // now-redundant-but-harmless fill_rdata_r write) stay
                        // on their existing registered schedule, completely
                        // unchanged -- only the EU-visible eu_ack/eu_rdata
                        // move earlier, via the output block's own new
                        // CI_D_MISS fast-path arm below (computing the exact
                        // same extract_rd(sf_rdata,...)/sf_rdata split
                        // combinationally, since dcache_en/mmu_ci/
                        // d_size_ok_r/dfreeze_en/siz_r/addr_r/sf_rdata are
                        // all already live this same cycle -- ciin is
                        // deliberately NOT part of this split, matching the
                        // comment above: it only gates the array-population
                        // side effect, never the returned value). CI_DONE
                        // itself is untouched and still serves the 2
                        // remaining entry points (CI_D_BURST0/
                        // CI_D_FILL_3B) -- Track D's later stages.
                        state <= CI_IDLE;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end

                // Phase 158 Stage 4c: DBE=1 burst linefill -- same shape as
                // biu_icache_if.sv's own IC_BURST0/IC_FILL_1B/2B/3B (see
                // that module's own comments for the full CBREQ#/CBACK#
                // protocol description), applied to data_d/tag_d/valid_d.
                // Unlike CI_D_MISS, every path through here ends up
                // fetching and validating the WHOLE line (all 4 words),
                // matching real hardware's own burst-fill semantics --
                // tag/valid are replaced unconditionally, not gated on
                // whether the old tag matched, since a burst always
                // represents a genuine full-line fill.
                CI_D_BURST0: begin
                    if (dc_burst_ack) begin
                        if (dc_burst_beat == 2'd3) begin
                            // Full 4-beat burst: CBACK# was asserted, all
                            // four words arrived in this one request.
                            data_d[idx_r][0] <= dc_burst_rdata0;
                            data_d[idx_r][1] <= dc_burst_rdata1;
                            data_d[idx_r][2] <= dc_burst_rdata2;
                            data_d[idx_r][3] <= dc_burst_rdata3;
                            case (woff_r)
                                2'd0: fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                                2'd1: fill_rdata_r <= extract_rd(dc_burst_rdata1, siz_r, addr_r[1:0]);
                                2'd2: fill_rdata_r <= extract_rd(dc_burst_rdata2, siz_r, addr_r[1:0]);
                                2'd3: fill_rdata_r <= extract_rd(dc_burst_rdata3, siz_r, addr_r[1:0]);
                            endcase
                            // 10-item backlog Stage 3 (plan.md): per-beat
                            // CIIN gating -- was "ciin checked once, for the
                            // whole line" (Phase 158 Stage 7); the manual's
                            // own CIIN-during-burst text describes real
                            // per-beat granularity ("assert CIIN when the
                            // data in a long word is not cachable"), and
                            // biu_burst_ctrl.sv now captures it per-beat
                            // (dc_burst_ciinN) even though all four words
                            // still arrive via one combined ack. data_d
                            // above is written unconditionally (harmless --
                            // invalid entries are never read); tag_d is
                            // always replaced too (harmless if every word
                            // ends up invalid -- valid_d already gates hit
                            // detection). Only the per-word valid_d bits are
                            // gated, individually, by that word's own
                            // captured CIIN.
                            tag_d[idx_r]      <= vtag_r;
                            valid_d[idx_r][0] <= !dc_burst_ciin0;
                            valid_d[idx_r][1] <= !dc_burst_ciin1;
                            valid_d[idx_r][2] <= !dc_burst_ciin2;
                            valid_d[idx_r][3] <= !dc_burst_ciin3;
                            // Bus-pipelining-overlap plan.md, Track D Stage
                            // D2: goes straight to CI_IDLE, not CI_DONE --
                            // same pattern as Stage D0/D1 above.
                            // The output block's own new CI_D_BURST0 fast-
                            // path arm below only fires eu_ack for this FULL
                            // (dc_burst_beat==3) branch -- the degraded
                            // (else) branch below is untouched, it
                            // genuinely doesn't complete yet.
                            state          <= CI_IDLE;
                            dc_burst_req_r <= 1'b0;
                        end else begin
                            // Degraded: CBACK# never asserted, only word 0
                            // (this request's own beat 0) actually arrived —
                            // fall back to individually re-requesting the
                            // remaining three words.
                            data_d[idx_r][0] <= dc_burst_rdata0;
                            if (woff_r == 2'd0) fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                            degraded_ciin_r[0] <= dc_burst_ciin0;
                            state           <= CI_D_FILL_1B;
                            dc_burst_addr_r <= fill_base_r + 32'd4;
                            // dc_burst_req_r stays asserted for the next request.
                        end
                    end else if (dc_burst_berr) begin
                        // Deferred-items closure plan Stage 9 (plan.md):
                        // per MC68030UM.pdf p.6-19, a BERR on a beat AFTER
                        // the CPU's own actually-requested word (woff_r)
                        // does not fault at all -- the microsequencer
                        // "has not yet requested" that later data. This
                        // RTL previously faulted unconditionally on any
                        // beat's own BERR. dc_burst_beat_at_berr tells us
                        // which beat was in flight; if the requested word's
                        // own beat already completed strictly before it
                        // (woff_r < dc_burst_beat_at_berr), that word's own
                        // data is already live on dc_burst_rdataN (a pure
                        // combinational passthrough of biu_burst_ctrl.sv's
                        // own internal capture array, not something that
                        // needs the final combined ack to become visible)
                        // -- complete successfully with it. Only the words
                        // that actually arrived (0..dc_burst_beat_at_berr-1)
                        // get marked valid; the failed beat and anything
                        // after it stay invalid, so a later real access to
                        // THOSE words still takes its own genuine fault --
                        // correctly, since they were never actually
                        // fetched. The harder "beat is at or before the
                        // requested word" case (woff_r >=
                        // dc_burst_beat_at_berr) gets one genuine retry
                        // (10-item backlog Stage 6, plan.md) before
                        // escalating to a real fault -- see the final
                        // else below.
                        if (woff_r < dc_burst_beat_at_berr) begin
                            case (woff_r)
                                2'd0: fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                                2'd1: fill_rdata_r <= extract_rd(dc_burst_rdata1, siz_r, addr_r[1:0]);
                                2'd2: fill_rdata_r <= extract_rd(dc_burst_rdata2, siz_r, addr_r[1:0]);
                                default: fill_rdata_r <= extract_rd(dc_burst_rdata3, siz_r, addr_r[1:0]);
                                // woff_r==2'd3 (the default arm) is
                                // structurally unreachable here (nothing
                                // can be strictly "before" beat 3), kept
                                // only for case exhaustiveness.
                            endcase
                            // 10-item backlog Stage 3 (plan.md): per-beat
                            // CIIN, same reasoning as the full-success
                            // branch above -- a word only ends up valid if
                            // it BOTH actually arrived (m < beat-at-berr)
                            // AND wasn't itself CIIN-inhibited.
                            tag_d[idx_r] <= vtag_r;
                            valid_d[idx_r][0] <= (2'd0 < dc_burst_beat_at_berr) && !dc_burst_ciin0;
                            valid_d[idx_r][1] <= (2'd1 < dc_burst_beat_at_berr) && !dc_burst_ciin1;
                            valid_d[idx_r][2] <= (2'd2 < dc_burst_beat_at_berr) && !dc_burst_ciin2;
                            valid_d[idx_r][3] <= (2'd3 < dc_burst_beat_at_berr) && !dc_burst_ciin3;
                            state          <= CI_IDLE;
                            dc_burst_req_r <= 1'b0;
                        end else if (!dc_retry_used_r) begin
                            // 10-item backlog Stage 6 (plan.md): first
                            // failure at/before the requested word -- retry
                            // once. dc_burst_addr_r is deliberately left
                            // untouched here (NOT re-derived from
                            // fill_base_r, unlike the degraded-fallback
                            // path's own +4/+8/+12 continuations above) --
                            // fill_base_r is only ever latched from the
                            // pre-translation eu_addr (CI_IDLE) and is
                            // genuinely wrong for a translated access (the
                            // real burst address for that case comes from
                            // xl_pa instead, see CI_XLATE's own dispatch
                            // above); dc_burst_addr_r itself, by contrast,
                            // already holds whichever of the two was
                            // actually used for the just-failed attempt, so
                            // simply not reassigning it re-requests the
                            // exact same (correct) frozen address either
                            // way. dc_burst_req_r stays asserted (same
                            // established pattern as the degraded-fallback
                            // path above) and state stays at CI_D_BURST0
                            // (no reassignment needed), so biu_cycle_gen's
                            // own FSM -- which always returns cleanly to
                            // ST_IDLE after any burst outcome, success or
                            // BERR-abort (berr_abort_r self-clears at S7) --
                            // sees eu_burst_req still held and redispatches
                            // a genuinely fresh ST_BURST_S0, which
                            // biu_burst_ctrl.sv's own "at_idle && eu_burst_
                            // req" latch treats identically to any other
                            // fresh burst request (burst_beat_r/cback_ok_r
                            // reset to 0, burst_addr_r/fc_r re-latched).
                            // The retry re-enters this exact branch of code
                            // on its own outcome, so a partial success
                            // (this attempt's own failure beat landing
                            // after woff_r this time) is already handled by
                            // the `if` above with no special-casing needed.
                            dc_retry_used_r <= 1'b1;
                        end else begin
                            xlate_fault_r  <= 1'b0;  // real bus error, not a translation fault
                            state          <= CI_BERR;
                            dc_burst_req_r <= 1'b0;
                        end
                    end
                end

                CI_D_FILL_1B: begin
                    if (dc_burst_ack) begin
                        data_d[idx_r][1] <= dc_burst_rdata0;
                        if (woff_r == 2'd1) fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                        degraded_ciin_r[1] <= dc_burst_ciin0;
                        state           <= CI_D_FILL_2B;
                        dc_burst_addr_r <= fill_base_r + 32'd8;
                    end else if (dc_burst_berr) begin
                        xlate_fault_r  <= 1'b0;
                        state          <= CI_BERR;
                        dc_burst_req_r <= 1'b0;
                    end
                end
                CI_D_FILL_2B: begin
                    if (dc_burst_ack) begin
                        data_d[idx_r][2] <= dc_burst_rdata0;
                        if (woff_r == 2'd2) fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                        degraded_ciin_r[2] <= dc_burst_ciin0;
                        state           <= CI_D_FILL_3B;
                        dc_burst_addr_r <= fill_base_r + 32'd12;
                    end else if (dc_burst_berr) begin
                        xlate_fault_r  <= 1'b0;
                        state          <= CI_BERR;
                        dc_burst_req_r <= 1'b0;
                    end
                end
                CI_D_FILL_3B: begin
                    if (dc_burst_ack) begin
                        data_d[idx_r][3] <= dc_burst_rdata0;
                        if (woff_r == 2'd3) fill_rdata_r <= extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                        // 10-item backlog Stage 3 (plan.md): per-beat CIIN,
                        // same reasoning as CI_D_BURST0's own full-success
                        // branch -- beats 0-2's own captured values (this
                        // degraded path's own last real request always
                        // reuses dc_burst_ciin0, so each earlier beat's own
                        // value had to be stashed as it arrived, see
                        // degraded_ciin_r's own declaration comment); beat
                        // 3's own value is live right now.
                        tag_d[idx_r]      <= vtag_r;
                        valid_d[idx_r][0] <= !degraded_ciin_r[0];
                        valid_d[idx_r][1] <= !degraded_ciin_r[1];
                        valid_d[idx_r][2] <= !degraded_ciin_r[2];
                        valid_d[idx_r][3] <= !dc_burst_ciin0;
                        // Bus-pipelining-overlap plan.md, Track D Stage D2:
                        // goes straight to CI_IDLE, not CI_DONE -- same
                        // pattern as every other Track D site.
                        state          <= CI_IDLE;
                        dc_burst_req_r <= 1'b0;
                    end else if (dc_burst_berr) begin
                        xlate_fault_r  <= 1'b0;
                        state          <= CI_BERR;
                        dc_burst_req_r <= 1'b0;
                    end
                end

                CI_WRITE: begin
                    if (sf_ack_rise) begin
                        // Write-through: if D-cache hit, update cache line
                        // too -- merge_wr() (see its own comment above)
                        // repositions wdata_r's TOP-justified bits into the
                        // correct byte lane of the cached longword and
                        // preserves the slot's other, unrelated bytes for a
                        // sub-longword write.
                        if (dhit_r) begin
                            // Phase 158 Stage 5: deliberately ungated by
                            // dfreeze_en -- manual §6.3.1.5's own explicit
                            // exception, "write cycles that hit... cause the
                            // entry to be updated even when the cache is
                            // frozen."
                            data_d[idx_r][woff_r] <= merge_wr(data_d[idx_r][woff_r], wdata_r, siz_r, addr_r[1:0]);
                        end else if (wa_en && !dfreeze_en) begin
                            // Phase 158 Stage 4b: write-allocation on a
                            // write MISS, manual §6.1.2.1/Figure 6-4
                            // (confirmed by direct re-read). Aligned
                            // long-word write (Example 3/4): always allocate
                            // -- replace the tag, write the data, validate
                            // only this word slot, invalidate the other 3
                            // (whether the old tag matched or not; Example 4
                            // shows a full tag replacement clearing all four
                            // V-bits before setting the one just written).
                            // Misaligned or sub-long-word write (Example 5):
                            // never write data -- only clear this word
                            // slot's own valid bit (a no-op if it was
                            // already invalid, matching Example 2's b6-b7
                            // sub-case). d_size_ok_r already excludes a
                            // longword write that spans two word slots from
                            // ever reaching dhit_r/this cache-array logic
                            // at all (Phase 134's own single-slot-model
                            // boundary) -- this stage doesn't attempt to
                            // widen that, so a genuinely cross-slot
                            // misaligned long write's write-allocation
                            // behavior (Example 2's own dual-entry shape)
                            // is intentionally not replicated.
                            if (siz_r == 2'b00 && addr_r[1:0] == 2'b00) begin
                                tag_d[idx_r]           <= vtag_r;
                                data_d[idx_r][woff_r]  <= wdata_r;
                                for (m = 0; m < 4; m++)
                                    valid_d[idx_r][m] <= (m == woff_r);
                            end else begin
                                valid_d[idx_r][woff_r] <= 1'b0;
                            end
                        end
                        // Bus-pipelining-overlap plan.md, Track D Stage D0:
                        // goes straight to CI_IDLE, not CI_DONE -- the
                        // output block's own CI_WRITE arm below now
                        // presents eu_ack combinationally the same cycle
                        // sf_ack_rise fires, so CI_DONE's own registered
                        // eu_ack=1 (unconditional whenever state==CI_DONE)
                        // would otherwise double-pulse eu_ack one cycle
                        // later for the identical completion -- the exact
                        // bug class Track C's own SS_DONE fix hit and had
                        // to fix by removing the old OR'd term entirely.
                        // Skipping CI_DONE outright (rather than trying to
                        // suppress its own eu_ack conditionally) is cleaner
                        // here since nothing else needs the extra tick: a
                        // write never returns eu_rdata (defaults to 32'h0,
                        // same as before -- the old path returned whatever
                        // stale fill_rdata_r a write's own CI_WRITE logic
                        // never touched anyway), and CI_IDLE's own
                        // next-state logic is purely combinational off live
                        // inputs with no dependency on how it was reached
                        // (already proven by CI_BERR's own identical direct-
                        // to-CI_IDLE return). CI_DONE remains completely
                        // unchanged and still serves every OTHER entry
                        // point (CI_D_MISS/CI_D_BURST0/CI_D_FILL_3B) --
                        // Track D's later stages, not this one.
                        state <= CI_IDLE;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end

                CI_DONE: begin
                    // eu_ack fires this cycle; return to idle
                    state <= CI_IDLE;
                end

                CI_BERR: begin
                    // eu_berr fires this cycle; return to idle. Mirrors
                    // CI_DONE's structure exactly, just for the abort path —
                    // previously this state didn't exist at all, so a fault
                    // during any multi-beat state left `state` stuck forever
                    // waiting for an `sf_ack_rise` that a genuinely faulted
                    // cycle will never produce.
                    state <= CI_IDLE;
                end

                default: state <= CI_IDLE;
            endcase
        end
    end

    // Output logic
    always_comb begin
        eu_rdata = 32'h0;
        eu_ack   = 1'b0;
        eu_berr  = 1'b0;
        sf_addr  = addr_r;
        sf_fc    = fc_r;
        sf_rw    = rw_r;
        sf_siz   = siz_r;
        sf_wdata = wdata_r;
        sf_is_op = 1'b0;
        sf_req   = 1'b0;

        // Phase 158 Stage 7: CIOUT, reflecting the latched (dispatched)
        // transaction's own FC alongside mem_rmw_lookup/dcache_en. 10-item
        // backlog Stage 2 (plan.md): xl_ci_r, not the live mmu_ci broadcast
        // -- ciout is evaluated continuously, including while this access
        // sits in CI_D_MISS/CI_WRITE/etc waiting for its own bus cycle,
        // long after this access's own translation (if any) completed and
        // the shared MMU resource has potentially moved on to servicing a
        // different requester.
        ciout = xl_ci_r || mem_rmw_lookup || (fc_r == 3'b111) || !dcache_en;

        // Phase 158 Stage 4c: driven unconditionally from the registered
        // dc_burst_req_r/addr_r (see their own declaration comment for why
        // this can't be a combinational case(state) computation instead).
        dc_burst_req  = dc_burst_req_r;
        dc_burst_addr = dc_burst_addr_r;
        dc_burst_fc   = fc_r;

        // Phase 150 (plan.md): MMU translation request, defaults
        xl_va  = addr_r;
        xl_fc  = fc_r;
        xl_rw  = rw_r;
        xl_req = 1'b0;

        xlate_fault_pulse = 1'b0;
        xlate_fault_addr  = addr_r;
        xlate_fault_fc    = fc_r;
        xlate_fault_rw    = rw_r;
        xlate_fault_siz   = siz_r;

        case (state)
            CI_XLATE: begin
                xl_req = 1'b1;   // held for the whole translation window
            end

            CI_HIT: begin
                // Serve directly from cache; no sf_req
                eu_rdata = extract_rd(data_d[idx_r][woff_r], siz_r, addr_r[1:0]);
                eu_ack = 1'b1;
            end

            CI_D_MISS: begin
                // 10-item backlog Stage 2 (plan.md): xl_ci_r here too -- must
                // stay bit-for-bit consistent with the sequential block's own
                // identical condition (both else branches determine sf_addr/
                // sf_siz for the SAME bus request the sequential block
                // decides whether to cache).
                if (dcache_en && !xl_ci_r && d_size_ok_r && !dfreeze_en) begin
                    // Cache-enabled miss: always fill at longword
                    // granularity from the bus (the D-cache's own per-word
                    // valid_d tracking unit), regardless of the CPU's own
                    // requested access size -- matches real 68030 D-cache
                    // fill behavior and is required for correctness: see
                    // the sequential CI_D_MISS block's own comment for the
                    // bug this fixes (a sub-longword fetch silently cached
                    // as if the whole 4-byte slot were freshly fetched).
                    // Phase 158 Stage 5: !dfreeze_en matches the sequential
                    // block's own identical addition.
                    sf_addr = {addr_r[31:2], 2'b00};
                    sf_siz  = 2'b00;
                end else begin
                    sf_siz  = siz_r;  // pass actual size; sizing_fsm normalizes byte/word
                end
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
                // Bus-pipelining-overlap plan.md, Track D Stage D1: present
                // eu_ack/eu_rdata the same cycle sf_ack_rise fires, instead
                // of waiting for the registered CI_D_MISS->CI_DONE hop (now
                // skipped -- see the always_ff block's own comment on the
                // matching state<=CI_IDLE edit). Same would-cache condition
                // as sf_addr/sf_siz above and the always_ff block's own
                // extract_rd() split -- deliberately excludes ciin, which
                // only gates the array-population side effect (still on its
                // existing registered schedule), never the returned value.
                if (sf_ack_rise) begin
                    eu_ack   = 1'b1;
                    eu_rdata = (dcache_en && !xl_ci_r && d_size_ok_r && !dfreeze_en)
                             ? extract_rd(sf_rdata, siz_r, addr_r[1:0])
                             : sf_rdata;
                end
            end

            // Bus-pipelining-overlap plan.md, Track D Stage D2: neither of
            // these two states had ANY case arm here before this stage --
            // dc_burst_req/dc_burst_addr are already driven unconditionally
            // from the registered dc_burst_req_r/addr_r above (Phase 158
            // Stage 4c), and eu_ack/eu_rdata used to come exclusively from
            // the later registered hop through CI_DONE. dc_burst_ack is
            // already a genuine 1-tick pulse (biu_burst_ctrl.sv's own
            // eu_burst_ack_r: cleared to 0 every cycle by default, set for
            // exactly one cycle on completion) -- confirmed by reading that
            // module before adding this, since an accidentally-multi-tick
            // ack here would double-pulse eu_ack exactly like Track C's own
            // mistake. No _rise edge-detector needed, matching how the
            // always_ff block above already gates directly on dc_burst_ack.
            CI_D_BURST0: begin
                // Only the FULL 4-beat success case (dc_burst_beat==3)
                // completes here -- the degraded case (else, in the
                // always_ff block above) falls through to CI_D_FILL_1B and
                // must NOT fire eu_ack yet.
                if (dc_burst_ack && dc_burst_beat == 2'd3) begin
                    eu_ack = 1'b1;
                    case (woff_r)
                        2'd0: eu_rdata = extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                        2'd1: eu_rdata = extract_rd(dc_burst_rdata1, siz_r, addr_r[1:0]);
                        2'd2: eu_rdata = extract_rd(dc_burst_rdata2, siz_r, addr_r[1:0]);
                        2'd3: eu_rdata = extract_rd(dc_burst_rdata3, siz_r, addr_r[1:0]);
                    endcase
                // Deferred-items closure plan Stage 9 (plan.md): the
                // "BERR after the requested word's own beat" success path
                // -- same combinational-fast-path shape as the ack arm
                // above (mirrors the always_ff block's own identical
                // condition), needed since that block's own registered
                // transition to CI_IDLE doesn't by itself produce eu_ack.
                end else if (dc_burst_berr && (woff_r < dc_burst_beat_at_berr)) begin
                    eu_ack = 1'b1;
                    case (woff_r)
                        2'd0: eu_rdata = extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0]);
                        2'd1: eu_rdata = extract_rd(dc_burst_rdata1, siz_r, addr_r[1:0]);
                        2'd2: eu_rdata = extract_rd(dc_burst_rdata2, siz_r, addr_r[1:0]);
                        default: eu_rdata = extract_rd(dc_burst_rdata3, siz_r, addr_r[1:0]);
                        // woff_r==2'd3 structurally unreachable here, same
                        // reasoning as the always_ff block's own case.
                    endcase
                end
            end

            CI_D_FILL_3B: begin
                // Degraded fallback's own final beat. woff_r==3 means THIS
                // beat's own dc_burst_rdata0 is the CPU's requested word;
                // otherwise fill_rdata_r already holds the correct value,
                // latched by an earlier CI_D_BURST0/CI_D_FILL_1B/2B beat and
                // untouched since.
                if (dc_burst_ack) begin
                    eu_ack   = 1'b1;
                    eu_rdata = (woff_r == 2'd3)
                             ? extract_rd(dc_burst_rdata0, siz_r, addr_r[1:0])
                             : fill_rdata_r;
                end
            end

            CI_WRITE: begin
                sf_rw   = 1'b0;
                sf_req  = !sf_ack;
                // Bus-pipelining-overlap plan.md, Track D Stage D0: present
                // eu_ack the same cycle sf_ack_rise fires, instead of
                // waiting for the registered CI_WRITE->CI_DONE hop (now
                // skipped entirely for this path -- see the always_ff
                // block's own comment on the matching state<=CI_IDLE edit).
                // eu_rdata stays at its default 32'h0 (correct -- a write
                // never returns read data).
                if (sf_ack_rise) eu_ack = 1'b1;
            end

            CI_DONE: begin
                eu_rdata = fill_rdata_r;
                eu_ack   = 1'b1;
            end

            CI_BERR: begin
                eu_berr  = 1'b1;
                // Phase 150 (plan.md): a pure translation/WP fault (no real
                // bus error) needs a synthetic fault-capture pulse, since
                // biu_cycle_gen's own fault_valid_r never fires for one.
                xlate_fault_pulse = xlate_fault_r;
            end

            // Bus-pipelining-overlap plan.md, Track A: a write request
            // (eu_req && !eu_rw), with the MMU disabled (!tc_e, so no
            // CI_XLATE detour), never needs the dhit lookup the read
            // side's own CI_IDLE branch makes (module header: "On any
            // write: write-through -- always issues write to bus") --
            // present sf_addr/sf_wdata/sf_fc/sf_siz/sf_rw/sf_req
            // combinationally from the raw eu_ inputs THIS cycle, instead
            // of waiting for the registered addr_r/wdata_r/etc (latched
            // this same cycle in the always_ff block above, but not
            // valid until next cycle) and the CI_IDLE->CI_WRITE state
            // transition a cycle later. Mirrors biu_sizing_fsm.sv's own
            // SS_IDLE "zero added latency" pass-through exactly. The
            // registered CI_IDLE->CI_WRITE transition (unchanged, still
            // happens next cycle) is harmless once this fires -- it just
            // re-presents the identical values a cycle later from addr_r/
            // wdata_r, and a real bus cycle always takes far longer (>=8
            // ticks) than the 1-tick gap between this combinational
            // fast-path and that catch-up, so there's no window where
            // sf_ack could arrive before CI's own state has caught up to
            // CI_WRITE. Read/hit/translate/burst paths (CI_IDLE's own
            // registered next-state logic in the always_ff block above)
            // are completely untouched by this arm.
            CI_IDLE: begin
                if (eu_req && !eu_rw && !tc_e) begin
                    sf_addr  = eu_addr;
                    sf_fc    = eu_fc;
                    sf_rw    = 1'b0;
                    sf_siz   = eu_siz;
                    sf_wdata = eu_wdata;
                    sf_req   = 1'b1;
                end
            end

            default: ;  // CI_IDLE (no eu_req, or a read/xlate case): sf_req=0, eu_ack=0
        endcase
    end

endmodule

`default_nettype wire

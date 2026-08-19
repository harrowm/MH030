`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — Cache Interface
// Implements I-cache + D-cache hit/miss detection and linefill sequencing.
// On I-cache miss (EI+IBE): issues 4 sequential longword reads (linefill).
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
    input  logic        eu_is_icache,  // 1=use I-cache, 0=use D-cache
    output logic [31:0] eu_rdata,
    output logic        eu_ack,
    output logic        eu_berr,

    // Cache Inhibit from MMU
    input  logic        mmu_ci,

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
    input  logic        xl_ci,   // deferred this phase — see header note
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

    // Phase 150 (plan.md): CI (mmu_ci input above, pre-existing) still gates
    // hit detection using its own pre-existing, never-yet-live semantics —
    // deliberately NOT touched by this phase. The new xl_ci result above is
    // read but not yet acted on: real CI-driven "don't allocate this page
    // into the cache" behavior on a fresh miss is deferred to a documented
    // follow-up, out of Stage 0's own scope (translation + fault handling
    // only). xl_ci is threaded through end-to-end now so that follow-up is
    // a pure behavioral addition, not new plumbing.
    wire tc_e = tc[31];

    // CACR bit aliases (Figure 6-14: 13=WA,12=DBE,11=CD,10=CED,9=FD,8=ED,
    // 4=IBE,3=CI,2=CEI,1=FI,0=EI — confirmed directly against the manual).
    // Phase 158 Stage 1: dcache_en previously read cacr[9] (FD, freeze) instead
    // of cacr[8] (ED, enable) -- a real, previously-undiscovered bug meaning
    // software that set ED the textbook-correct way got a D-cache that never
    // activated. See plan.md Phase 158 Stage 1 for the full derivation.
    wire icache_en = cacr[0];
    wire iburst_en = cacr[4];
    wire dcache_en = cacr[8];

    // Cache storage arrays
    // Phase 158 Stage 2: tag width widened from 24 to 27 bits (was
    // addr[31:8] alone) to include FC0-2, per manual §6.1.2 (p.6-6): "The
    // tag of each line in the data cache contains function code bits FC0,
    // FC1, and FC2 in addition to address bits A31-A8." Without this, a
    // supervisor and user access to the same logical address alias onto
    // the same cache line and can hit each other's data -- a real
    // correctness bug, confirmed against the manual before fixing (not
    // guessed at). tag_i/valid_i (this module's own vestigial I-cache-shaped
    // arrays) are permanently dead -- m68030_top.sv hardwires
    // eu_is_icache=1'b0 -- widened only for type-compatibility with the
    // shared vtag/vtag_r below, zero behavioral effect on dead code. The
    // REAL I-cache is rtl/biu_icache_if.sv, fixed separately this stage.
    logic        valid_i [0:15];
    logic [26:0] tag_i   [0:15];
    logic [31:0] data_i  [0:15][0:3];

    // valid_d is per-WORD, not per-line, unlike valid_i -- a D-cache miss
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
        CI_FILL_0 = 4'd2,
        CI_FILL_1 = 4'd3,
        CI_FILL_2 = 4'd4,
        CI_FILL_3 = 4'd5,
        CI_D_MISS = 4'd6,
        CI_WRITE  = 4'd7,
        CI_DONE   = 4'd8,
        CI_BERR   = 4'd9,
        CI_XLATE  = 4'd10   // Phase 150, plan.md
    } ci_state_t;

    ci_state_t state;

    // Latched request parameters
    logic [31:0] addr_r, wdata_r, fill_base_r;
    logic [2:0]  fc_r;
    logic        rw_r;
    logic [1:0]  siz_r;
    logic        is_icache_r;
    logic [3:0]  idx_r;
    logic [1:0]  woff_r;
    logic [26:0] vtag_r;
    logic [31:0] fill_rdata_r;  // captured rdata for CI_DONE return
    logic        xlate_fault_r; // Phase 150: distinguishes a CI_BERR entered
                                 // from CI_XLATE (pure translation/WP fault,
                                 // no real bus error) from one entered via a
                                 // genuine sf_berr elsewhere

    // Combinatorial hit detection (in CI_IDLE, before latching)
    wire [3:0]  idx  = eu_addr[7:4];
    wire [1:0]  woff = eu_addr[3:2];
    wire [26:0] vtag = {eu_fc, eu_addr[31:8]};
    wire ihit = icache_en && valid_i[idx] && (tag_i[idx] == vtag) && !mmu_ci;

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

    wire dhit = dcache_en && d_size_ok && valid_d[idx][woff] && (tag_d[idx] == vtag) && !mmu_ci;

    // Also need dhit based on latched idx_r/vtag_r for write update in CI_WRITE
    wire dhit_r = dcache_en && d_size_ok_r && valid_d[idx_r][woff_r] && (tag_d[idx_r] == vtag_r) && !mmu_ci;

    integer k, m;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            state       <= CI_IDLE;
            fill_rdata_r <= 32'h0;
            xlate_fault_r <= 1'b0;
            for (k = 0; k < 16; k++) begin
                valid_i[k] <= 1'b0;
                for (m = 0; m < 4; m++) valid_d[k][m] <= 1'b0;
            end
        end else begin
            // CACR cache-clear operations (level-sensitive while bit asserted)
            // Phase 158 Stage 1: CD/CED were off by one bit (cacr[12]/cacr[11]
            // are really DBE/CD, not CD/CED) — fixed to cacr[11]/cacr[10].
            if (cacr[3])  for (k = 0; k < 16; k++) valid_i[k] <= 1'b0; // CI
            if (cacr[11]) for (k = 0; k < 16; k++) for (m = 0; m < 4; m++) valid_d[k][m] <= 1'b0; // CD
            if (cacr[2])  valid_i[caar[7:4]] <= 1'b0;  // CEI
            if (cacr[10]) for (m = 0; m < 4; m++) valid_d[caar[7:4]][m] <= 1'b0;  // CED

            case (state)
                CI_IDLE: begin
                    if (eu_req) begin
                        addr_r      <= eu_addr;
                        wdata_r     <= eu_wdata;
                        fc_r        <= eu_fc;
                        rw_r        <= eu_rw;
                        siz_r       <= eu_siz;
                        is_icache_r <= eu_is_icache;
                        idx_r       <= idx;
                        woff_r      <= woff;
                        vtag_r      <= vtag;
                        fill_base_r <= {eu_addr[31:4], 4'h0};

                        if (eu_rw && (eu_is_icache ? ihit : dhit)) begin
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
                        end else if (eu_is_icache && icache_en && iburst_en) begin
                            state <= CI_FILL_0;
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
                        addr_r <= xl_pa;
                        if (!rw_r) begin
                            state <= CI_WRITE;
                        end else if (is_icache_r && icache_en && iburst_en) begin
                            state <= CI_FILL_0;
                        end else begin
                            state <= CI_D_MISS;
                        end
                    end
                end

                CI_FILL_0: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][0] <= sf_rdata;
                        if (woff_r == 2'd0) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_1;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end
                CI_FILL_1: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][1] <= sf_rdata;
                        if (woff_r == 2'd1) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_2;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end
                CI_FILL_2: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][2] <= sf_rdata;
                        if (woff_r == 2'd2) fill_rdata_r <= sf_rdata;
                        state <= CI_FILL_3;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end
                CI_FILL_3: begin
                    if (sf_ack_rise) begin
                        data_i[idx_r][3] <= sf_rdata;
                        if (woff_r == 2'd3) fill_rdata_r <= sf_rdata;
                        tag_i[idx_r]   <= vtag_r;
                        valid_i[idx_r] <= 1'b1;
                        state <= CI_DONE;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
                    end
                end

                CI_D_MISS: begin
                    if (sf_ack_rise) begin
                        if (dcache_en && !mmu_ci && d_size_ok_r) begin
                            // Cache-enabled miss: the combinational output
                            // block below forces sf_siz=2'b00 (longword) and
                            // sf_addr to the 4-byte-aligned slot address for
                            // this case, so sf_rdata here genuinely holds
                            // the FULL longword regardless of how small the
                            // CPU's own request was -- extract its specific
                            // sub-portion for the return value (same
                            // extract_rd() CI_HIT already uses for a cache
                            // hit) while caching the complete, correctly-
                            // fetched longword. A prior version cached
                            // sf_rdata directly-as-fetched at the CPU's own
                            // (possibly sub-longword) size and still marked
                            // the whole word-slot valid -- silently caching
                            // only PART of the slot as if the rest were also
                            // freshly fetched, when sizing_fsm's own
                            // normalization for a byte/word request has no
                            // obligation to reflect the other bytes' real
                            // memory content at all. A later access to a
                            // DIFFERENT byte range within that same 4-byte
                            // slot (e.g. RTR's own back-to-back CCR-word +
                            // PC-longword pop, both landing in one slot)
                            // would then hit and be served that bogus
                            // data -- root-caused via Step 6's D-cache-only
                            // Harte sweep (RTR index 0: both reads returned
                            // the identical raw CCR word, one of them
                            // silently wrong) before this fix.
                            fill_rdata_r <= extract_rd(sf_rdata, siz_r, addr_r[1:0]);
                            data_d[idx_r][woff_r] <= sf_rdata; // full, genuinely-fetched longword
                            // A tag mismatch means this line's other 3
                            // word slots belong to a completely different,
                            // now-replaced address -- invalidate them too,
                            // not just the one word this fill actually
                            // populates. If the tag already matches (same
                            // line, just a different word offset that was
                            // never independently fetched before), leave
                            // the other slots' own validity untouched.
                            if (tag_d[idx_r] != vtag_r)
                                for (m = 0; m < 4; m++) valid_d[idx_r][m] <= 1'b0;
                            tag_d[idx_r]            <= vtag_r;
                            valid_d[idx_r][woff_r]  <= 1'b1;
                        end else begin
                            // Cache disabled (or MMU-inhibited): unchanged
                            // passthrough -- sizing_fsm already normalizes
                            // byte/word for the 32-bit port at the CPU's own
                            // requested size; for IFU (sf_siz=00 LW),
                            // sf_rdata is a full longword passthrough.
                            fill_rdata_r <= sf_rdata;
                        end
                        state <= CI_DONE;
                    end else if (sf_berr) begin
                        xlate_fault_r <= 1'b0;  // real bus error, not a translation fault
                        state <= CI_BERR;
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
                            data_d[idx_r][woff_r] <= merge_wr(data_d[idx_r][woff_r], wdata_r, siz_r, addr_r[1:0]);
                        end
                        state <= CI_DONE;
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
                    // during CI_D_MISS/CI_WRITE/CI_FILL_* left `state` stuck
                    // forever waiting for an `sf_ack_rise` that a genuinely
                    // faulted cycle will never produce.
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
                if (is_icache_r)
                    eu_rdata = data_i[idx_r][woff_r]; // I-cache: full longword (IFU uses it)
                else
                    eu_rdata = extract_rd(data_d[idx_r][woff_r], siz_r, addr_r[1:0]);
                eu_ack = 1'b1;
            end

            CI_FILL_0: begin
                sf_addr = fill_base_r;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_1: begin
                sf_addr = fill_base_r + 32'd4;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_2: begin
                sf_addr = fill_base_r + 32'd8;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end
            CI_FILL_3: begin
                sf_addr = fill_base_r + 32'd12;
                sf_siz  = 2'b00;
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end

            CI_D_MISS: begin
                if (dcache_en && !mmu_ci && d_size_ok_r) begin
                    // Cache-enabled miss: always fill at longword
                    // granularity from the bus (the D-cache's own per-word
                    // valid_d tracking unit), regardless of the CPU's own
                    // requested access size -- matches real 68030 D-cache
                    // fill behavior and is required for correctness: see
                    // the sequential CI_D_MISS block's own comment for the
                    // bug this fixes (a sub-longword fetch silently cached
                    // as if the whole 4-byte slot were freshly fetched).
                    sf_addr = {addr_r[31:2], 2'b00};
                    sf_siz  = 2'b00;
                end else begin
                    sf_siz  = siz_r;  // pass actual size; sizing_fsm normalizes byte/word
                end
                sf_rw   = 1'b1;
                sf_req  = !sf_ack;
            end

            CI_WRITE: begin
                sf_rw   = 1'b0;
                sf_req  = !sf_ack;
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

            default: ;  // CI_IDLE: sf_req=0, eu_ack=0
        endcase
    end

endmodule

`default_nettype wire

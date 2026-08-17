`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — MMU Interface
// Implements:
//   - TT0/TT1 transparent translation (address bypass, no ATC)
//   - 22-entry fully-associative ATC (Address Translation Cache)
//   - 3-level table walker using the existing mmu_req port on cycle_gen
//
// TC register layout (68030 manual):
//   [31]    = E   (MMU enable)
//   [30]    = SRE (use SRP for supervisor FC[2]=1)
//   [27:24] = PS  (page size in bits: PS=12 → 4096-byte pages)
//   [23:20] = IS  (initial shift: skip IS bits from top of VA)
//   [19:16] = TIA (table index A field width in bits)
//   [15:12] = TIB (table index B field width in bits)
//   [11:8]  = TIC (table index C field width in bits)
//   [7:4]   = TID (table index D — unused in tests)
//
// TT register layout:
//   [31:24] = LAB (logical address base, VA[31:24])
//   [23:16] = LAM (address mask: 1 bits = don't care)
//   [15]    = E   (enable this TT register)
//   [13]    = CI  (cache inhibit for this range)
//   [7:5]   = FCM (function code mask)
//   [4:2]   = FCB (function code base)
//   [1]     = RWM (read/write mask)
//   [0]     = RW  (when RWM=1)
//
// Descriptor format (short, 4-byte):
//   [31:4] = base address (next table base or page frame base, 16B aligned)
//   [3]    = CI (cache inhibit bit in page descriptor)
//   [1:0]  = DT: 00=invalid, 01=page(leaf), 10=table, 11=long-table(treat as table)

module biu_mmu_if (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Translation request
    input  logic [31:0] va,
    input  logic [2:0]  fc,
    input  logic        rw,
    input  logic        req,

    // Translation result (registered; hold until next req)
    output logic [31:0] pa,
    output logic        hit,        // ATC hit
    output logic        walk_done,  // TT bypass or walk complete
    output logic        fault,
    output logic        fault_is_berr, // Phase 150 (plan.md): see fault_is_berr_r's own comment
    output logic        ci,
    output logic        wp,         // write-protect (Phase 150, plan.md)

    // Bus port → cycle_gen mmu_req
    output logic [31:0] mmu_req_addr,
    output logic [2:0]  mmu_req_fc,
    output logic        mmu_req,
    output logic         mmu_req_rw,    // Phase 150 Stage 3: 1=read, 0=write (U/M write-back)
    output logic [31:0]  mmu_req_wdata, // Phase 150 Stage 3: write data for the U/M write-back cycle
    input  logic [31:0] mmu_rdata,
    input  logic        mmu_ack,    // combinatorial, holds for 4 ticks at S7
    input  logic        mmu_berr,

    // Control registers
    input  logic [31:0] tc,
    input  logic [63:0] crp,        // [31:0] = lower longword used as root base
    input  logic [63:0] srp,
    input  logic [31:0] tt0,
    input  logic [31:0] tt1,

    output logic [15:0] mmusr,

    // PFLUSH — invalidate ATC entries (synchronous, 1-cycle ack)
    input  logic        pflush_req,
    input  logic        pflush_all,     // 0=single VA, 1=all matching FC
    input  logic [2:0]  pflush_fc,
    input  logic [31:0] pflush_va,
    output logic        pflush_ack
);

    // -----------------------------------------------------------------------
    // mmu_ack rising-edge detection (mmu_ack holds for 4 ticks in S7)
    // -----------------------------------------------------------------------
    logic mmu_ack_prev_r;
    always_ff @(posedge clk_4x or negedge rst_n)
        if (!rst_n) mmu_ack_prev_r <= 1'b0;
        else        mmu_ack_prev_r <= mmu_ack;
    wire mmu_ack_rise = mmu_ack && !mmu_ack_prev_r;

    // -----------------------------------------------------------------------
    // TC field extraction
    // -----------------------------------------------------------------------
    wire        tc_e   = tc[31];
    wire [4:0]  ps     = {1'b0, tc[27:24]};   // page size in bits (e.g. 12 for 4KB)
    wire [4:0]  is_b   = {1'b0, tc[23:20]};   // initial shift
    wire [3:0]  tia    = tc[19:16];
    wire [3:0]  tib    = tc[15:12];
    wire [3:0]  tic    = tc[11:8];

    // Page mask (0 in page offset bits, 1 elsewhere)
    wire [31:0] page_mask = ~((32'h1 << ps) - 32'h1);

    // CRP/SRP base (use lower 32-bit, bits[31:4] give base >> 4)
    wire [31:0] crp_base = {crp[31:4], 4'h0};

    // -----------------------------------------------------------------------
    // TT match function
    // -----------------------------------------------------------------------
    function automatic logic tt_match(
        input logic [31:0] tt_r,
        input logic [31:0] va_in,
        input logic [2:0]  fc_in,
        input logic        rw_in
    );
        logic addr_m, fc_m, rw_m;
        addr_m = tt_r[15] &&
                 ((va_in[31:24] & ~tt_r[23:16]) == (tt_r[31:24] & ~tt_r[23:16]));
        fc_m   = (fc_in & ~tt_r[7:5]) == (tt_r[4:2] & ~tt_r[7:5]);
        rw_m   = !tt_r[1] || (rw_in == tt_r[0]);
        tt_match = addr_m && fc_m && rw_m;
    endfunction

    // -----------------------------------------------------------------------
    // ATC (22-entry, fully associative, round-robin replacement)
    // -----------------------------------------------------------------------
    localparam int ATC_SIZE = 22;
    logic        atc_valid [0:ATC_SIZE-1];
    logic [31:0] atc_va    [0:ATC_SIZE-1];
    logic [2:0]  atc_fc    [0:ATC_SIZE-1];
    logic [31:0] atc_pa    [0:ATC_SIZE-1];
    logic        atc_ci    [0:ATC_SIZE-1];
    logic        atc_wp    [0:ATC_SIZE-1];
    // Phase 150 Stage 3 (plan.md): per-entry M-bit shadow + the leaf
    // descriptor's own physical address, needed so a later write through
    // an already-cached ATC entry can still find the descriptor and mark
    // M without re-walking. U is NOT tracked here -- every ATC entry is
    // only ever populated once U is already guaranteed 1 (MS_UPDATE
    // always resolves U before MS_WALK_DONE caches anything), so there is
    // nothing for an ATC hit to ever need to update on that bit.
    logic        atc_m         [0:ATC_SIZE-1];
    logic [31:0] atc_desc_addr [0:ATC_SIZE-1];
    logic [4:0]  atc_victim;
    logic        pflush_ack_r;

    // ATC lookup (fully associative, unrolled for loop)
    logic        atc_hit_found;
    logic [4:0]  atc_hit_idx;
    logic [31:0] atc_hit_pa;
    logic        atc_hit_ci;
    logic        atc_hit_wp;
    logic        atc_hit_m;
    logic [31:0] atc_hit_desc_addr;
    always_comb begin
        atc_hit_found = 1'b0;
        atc_hit_idx   = 5'd0;
        atc_hit_pa    = 32'h0;
        atc_hit_ci    = 1'b0;
        atc_hit_wp    = 1'b0;
        atc_hit_m     = 1'b0;
        atc_hit_desc_addr = 32'h0;
        for (int i = 0; i < ATC_SIZE; i++) begin
            if (atc_valid[i] && (atc_fc[i] == fc) &&
                ((va & page_mask) == (atc_va[i] & page_mask))) begin
                atc_hit_found = 1'b1;
                atc_hit_idx   = 5'(i);
                atc_hit_pa    = (atc_pa[i] & page_mask) | (va & ~page_mask);
                atc_hit_ci    = atc_ci[i];
                atc_hit_wp    = atc_wp[i];
                atc_hit_m     = atc_m[i];
                atc_hit_desc_addr = atc_desc_addr[i];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Walk index calculations (combinatorial, based on current va + latched state)
    // -----------------------------------------------------------------------
    // Field A: VA bits [31-IS : 31-IS-TIA+1]
    wire [4:0] fa_lo_w  = 5'd31 - is_b - {1'b0, tia} + 5'd1;
    wire [31:0] idx_a_w = (va >> fa_lo_w) & ((32'h1 << {1'b0, tia}) - 32'h1);
    wire [31:0] walk_a_addr_w = crp_base + (idx_a_w << 2);

    // -----------------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------------
    typedef enum logic [3:0] {
        MS_IDLE      = 4'd0,
        MS_TT_HIT    = 4'd1,
        MS_ATC_HIT   = 4'd2,
        MS_WALK_A    = 4'd3,
        MS_WALK_B    = 4'd4,
        MS_WALK_C    = 4'd5,
        MS_WALK_DONE = 4'd6,
        MS_FAULT     = 4'd7,
        MS_UPDATE    = 4'd8   // Phase 150 Stage 3 (plan.md): U/M bit write-back
    } ms_state_t;

    ms_state_t ms_state;

    // Walk registers
    logic [31:0] walk_va_r;
    logic [2:0]  walk_fc_r;
    logic        walk_rw_r;
    logic [31:0] walk_desc_r;     // last read descriptor
    logic [31:0] walk_req_addr_r; // address to issue in current walk state
    logic [4:0]  fa_lo_r;         // latched fa_lo for B index computation
    logic [31:0] walk_pa_r;
    logic        walk_ci_r;
    logic        walk_wp_r;

    // Phase 150 Stage 3 (plan.md): U (Accessed, descriptor bit 3) / M
    // (Modified, descriptor bit 4) hardware write-back (BIU-086). Real
    // 68030 short-format PAGE descriptor bit layout (confirmed against
    // Motorola's own MMU documentation and the Linux m68k port's own
    // motorola_pgtable.h, which must match real hardware exactly since it
    // walks real 68030 page tables): bits[1:0]=DT, bit2=WP, bit3=U,
    // bit4=M, bit5=reserved, bit6=CI, bit7=reserved. This ALSO corrects a
    // real, previously-undiscovered bug found while researching this
    // stage: every existing walk_ci_r assignment below read CI from bit 3
    // (`mmu_rdata[3]`) instead of bit 6 -- bit 3 is actually U, a
    // completely different field, never previously read at all. CI's
    // live effect was limited enough (Stage 0's own notes: biu_cache_if's
    // mmu_ci input is fed from the EXT-owner-only demuxed value, a
    // documented pre-existing follow-up, not a live per-access signal)
    // that this was never caught by any test; fixed as part of this stage
    // since U/M work touches the exact same bits.
    logic [31:0] walk_desc_addr_r; // physical address the leaf descriptor was read from
    logic        walk_m_r;         // final M-bit state this walk will result in
    logic [31:0] update_wdata_r;   // write-back data for MS_UPDATE
    logic        update_from_atc_r;// 1 = M-only update via a cached ATC hit; 0 = walk-path U/M update
    logic [4:0]  atc_m_update_idx_r;

    // Latched outputs (hold until next req)
    logic [31:0] pa_r;
    logic        ci_r;
    logic        wp_r;   // write-protect (Phase 150, plan.md): mirrors ci_r exactly
    logic        hit_r, walk_done_r, fault_r;
    // Phase 150 (plan.md): distinguishes a real bus error during the walk
    // (already correctly captured by biu_cycle_gen's own generic S4-S6
    // fault_valid_r sampling, completely independent of this module) from a
    // purely logical fault (invalid descriptor / WP violation, no real bus
    // error at all) that needs a NEW synthetic capture path instead (see
    // m68030_biu.sv's own xlate_fault_pulse muxing) — consumers must gate
    // on this to avoid double-capturing the same real BERR event twice and
    // overwriting biu_exc_capture's correct first capture with a later,
    // stale one (its own frame_valid has no re-capture guard by design).
    logic        fault_is_berr_r;

    integer m;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            ms_state       <= MS_IDLE;
            pa_r           <= 32'h0;
            ci_r           <= 1'b0;
            wp_r           <= 1'b0;
            hit_r          <= 1'b0;
            walk_done_r    <= 1'b0;
            fault_r        <= 1'b0;
            fault_is_berr_r <= 1'b0;
            atc_victim      <= 5'd0;
            walk_req_addr_r <= 32'h0;
            fa_lo_r         <= 5'd22;
            pflush_ack_r    <= 1'b0;
            walk_desc_addr_r   <= 32'h0;
            walk_m_r           <= 1'b0;
            update_wdata_r     <= 32'h0;
            update_from_atc_r  <= 1'b0;
            atc_m_update_idx_r <= 5'd0;
            for (m = 0; m < ATC_SIZE; m++) begin
                atc_valid[m]     <= 1'b0;
                atc_ci[m]        <= 1'b0;
                atc_wp[m]        <= 1'b0;
                atc_m[m]         <= 1'b0;
                atc_desc_addr[m] <= 32'h0;
            end
        end else begin
            // Default: clear one-cycle pulse outputs
            hit_r        <= 1'b0;
            walk_done_r  <= 1'b0;
            fault_r      <= 1'b0;
            pflush_ack_r <= 1'b0;

            case (ms_state)
                MS_IDLE: begin
                    if (pflush_req) begin
                        // Invalidate matching ATC entries; ack next cycle
                        for (int i = 0; i < ATC_SIZE; i++) begin
                            if (pflush_all
                                    ? (atc_fc[i] == pflush_fc)
                                    : (atc_fc[i] == pflush_fc &&
                                       (atc_va[i] & page_mask) ==
                                       (pflush_va  & page_mask)))
                                atc_valid[i] <= 1'b0;
                        end
                        pflush_ack_r <= 1'b1;
                    end else if (req) begin
                        walk_va_r  <= va;
                        walk_fc_r  <= fc;
                        walk_rw_r  <= rw;

                        if (!tc_e) begin
                            // MMU disabled: identity mapping
                            pa_r     <= va;
                            ci_r     <= 1'b0;
                            wp_r     <= 1'b0;
                            ms_state <= MS_TT_HIT;
                        end else if (tt_match(tt0, va, fc, rw)) begin
                            pa_r     <= va;
                            ci_r     <= tt0[13];
                            wp_r     <= 1'b0;   // TT bypass: no page descriptor, no WP
                            ms_state <= MS_TT_HIT;
                        end else if (tt_match(tt1, va, fc, rw)) begin
                            pa_r     <= va;
                            ci_r     <= tt1[13];
                            wp_r     <= 1'b0;
                            ms_state <= MS_TT_HIT;
                        end else if (atc_hit_found) begin
                            // Phase 150 Stage 3 (plan.md): a write through
                            // an already-cached entry whose M bit hasn't
                            // been marked yet still needs a real write-back
                            // cycle (BIU-086) before this access can be
                            // reported as translated -- U is never checked
                            // here since every cached entry already has it
                            // guaranteed 1 (see atc_m's own declaration
                            // comment).
                            pa_r <= atc_hit_pa;
                            ci_r <= atc_hit_ci;
                            wp_r <= atc_hit_wp;
                            if (!rw && !atc_hit_m) begin
                                walk_desc_addr_r  <= atc_hit_desc_addr;
                                update_wdata_r    <= (atc_hit_pa & page_mask) |
                                                      (atc_hit_ci ? 32'h40 : 32'h0) |
                                                      (atc_hit_wp ? 32'h4  : 32'h0) |
                                                      32'h8  /* U, already guaranteed set */ |
                                                      32'h10 /* M, being newly set */ |
                                                      32'h1  /* DT = 01, page descriptor */;
                                update_from_atc_r  <= 1'b1;
                                atc_m_update_idx_r <= atc_hit_idx;
                                ms_state <= MS_UPDATE;
                            end else begin
                                ms_state <= MS_ATC_HIT;
                            end
                        end else begin
                            // ATC miss → start table walk level A
                            walk_req_addr_r <= walk_a_addr_w;
                            fa_lo_r         <= fa_lo_w;
                            ms_state        <= MS_WALK_A;
                        end
                    end
                end

                MS_TT_HIT: begin
                    walk_done_r <= 1'b1;
                    ms_state    <= MS_IDLE;
                end

                MS_ATC_HIT: begin
                    hit_r    <= 1'b1;
                    ms_state <= MS_IDLE;
                end

                MS_WALK_A: begin
                    if (mmu_berr) begin
                        fault_r        <= 1'b1;
                        fault_is_berr_r <= 1'b1;  // Phase 150: real bus error
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        walk_desc_r <= mmu_rdata;
                        case (mmu_rdata[1:0])
                            2'b00: begin  // invalid descriptor
                                fault_r         <= 1'b1;
                                fault_is_berr_r <= 1'b0;  // Phase 150: purely logical fault
                                ms_state <= MS_FAULT;
                            end
                            2'b01: begin  // page descriptor (leaf at level A)
                                walk_pa_r  <= (mmu_rdata & page_mask) |
                                              (walk_va_r & ~page_mask);
                                walk_ci_r  <= mmu_rdata[6];  // Phase 150 Stage 3: CI is bit 6 (see walk_desc_addr_r's own comment)
                                walk_wp_r  <= mmu_rdata[2];
                                if (!mmu_rdata[3] || (!walk_rw_r && !mmu_rdata[4])) begin
                                    // U and/or M needs setting -- a real write-back
                                    // cycle (BIU-086) before this access can complete.
                                    walk_desc_addr_r  <= walk_req_addr_r;
                                    update_wdata_r     <= mmu_rdata |
                                                           (!mmu_rdata[3] ? 32'h8 : 32'h0) |
                                                           ((!walk_rw_r && !mmu_rdata[4]) ? 32'h10 : 32'h0);
                                    walk_m_r           <= walk_rw_r ? mmu_rdata[4] : 1'b1;
                                    update_from_atc_r  <= 1'b0;
                                    ms_state <= MS_UPDATE;
                                end else begin
                                    walk_desc_addr_r <= walk_req_addr_r;
                                    walk_m_r <= mmu_rdata[4];
                                    ms_state <= MS_WALK_DONE;
                                end
                            end
                            default: begin  // 2'b10 or 2'b11: table descriptor
                                if (tib == 4'h0) begin
                                    // No level B defined → use current descriptor as leaf
                                    walk_pa_r  <= ({mmu_rdata[31:4], 4'h0} & page_mask) |
                                                  (walk_va_r & ~page_mask);
                                    walk_ci_r  <= 1'b0;
                                    walk_wp_r  <= 1'b0;
                                    ms_state   <= MS_WALK_DONE;
                                end else begin
                                    // Compute level B address
                                    begin
                                        logic [4:0]  fb_lo;
                                        logic [31:0] idx_b;
                                        logic [31:0] next_base;
                                        fb_lo    = fa_lo_r - {1'b0, tib};
                                        idx_b    = (walk_va_r >> fb_lo) &
                                                   ((32'h1 << {1'b0, tib}) - 32'h1);
                                        next_base = {mmu_rdata[31:4], 4'h0};
                                        walk_req_addr_r <= next_base + (idx_b << 2);
                                    end
                                    ms_state <= MS_WALK_B;
                                end
                            end
                        endcase
                    end
                end

                MS_WALK_B: begin
                    if (mmu_berr) begin
                        fault_r        <= 1'b1;
                        fault_is_berr_r <= 1'b1;  // Phase 150: real bus error
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        walk_desc_r <= mmu_rdata;
                        case (mmu_rdata[1:0])
                            2'b00: begin
                                fault_r         <= 1'b1;
                                fault_is_berr_r <= 1'b0;  // Phase 150: purely logical fault
                                ms_state <= MS_FAULT;
                            end
                            2'b01: begin  // page descriptor (leaf at level B)
                                walk_pa_r  <= (mmu_rdata & page_mask) |
                                              (walk_va_r & ~page_mask);
                                walk_ci_r  <= mmu_rdata[6];  // Phase 150 Stage 3: CI is bit 6
                                walk_wp_r  <= mmu_rdata[2];
                                if (!mmu_rdata[3] || (!walk_rw_r && !mmu_rdata[4])) begin
                                    walk_desc_addr_r  <= walk_req_addr_r;
                                    update_wdata_r     <= mmu_rdata |
                                                           (!mmu_rdata[3] ? 32'h8 : 32'h0) |
                                                           ((!walk_rw_r && !mmu_rdata[4]) ? 32'h10 : 32'h0);
                                    walk_m_r           <= walk_rw_r ? mmu_rdata[4] : 1'b1;
                                    update_from_atc_r  <= 1'b0;
                                    ms_state <= MS_UPDATE;
                                end else begin
                                    walk_desc_addr_r <= walk_req_addr_r;
                                    walk_m_r <= mmu_rdata[4];
                                    ms_state <= MS_WALK_DONE;
                                end
                            end
                            default: begin  // table descriptor → level C
                                if (tic == 4'h0) begin
                                    walk_pa_r  <= ({mmu_rdata[31:4], 4'h0} & page_mask) |
                                                  (walk_va_r & ~page_mask);
                                    walk_ci_r  <= 1'b0;
                                    walk_wp_r  <= 1'b0;
                                    ms_state   <= MS_WALK_DONE;
                                end else begin
                                    begin
                                        logic [4:0]  fc_lo;
                                        logic [31:0] idx_c;
                                        logic [31:0] next_base;
                                        fc_lo    = fa_lo_r - {1'b0, tib} - {1'b0, tic};
                                        idx_c    = (walk_va_r >> fc_lo) &
                                                   ((32'h1 << {1'b0, tic}) - 32'h1);
                                        next_base = {mmu_rdata[31:4], 4'h0};
                                        walk_req_addr_r <= next_base + (idx_c << 2);
                                    end
                                    ms_state <= MS_WALK_C;
                                end
                            end
                        endcase
                    end
                end

                MS_WALK_C: begin
                    if (mmu_berr) begin
                        fault_r        <= 1'b1;
                        fault_is_berr_r <= 1'b1;  // Phase 150: real bus error
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        // Must be a page descriptor
                        if (mmu_rdata[1:0] == 2'b01) begin
                            walk_pa_r  <= (mmu_rdata & page_mask) |
                                          (walk_va_r & ~page_mask);
                            walk_ci_r  <= mmu_rdata[6];  // Phase 150 Stage 3: CI is bit 6
                            walk_wp_r  <= mmu_rdata[2];
                            if (!mmu_rdata[3] || (!walk_rw_r && !mmu_rdata[4])) begin
                                walk_desc_addr_r  <= walk_req_addr_r;
                                update_wdata_r     <= mmu_rdata |
                                                       (!mmu_rdata[3] ? 32'h8 : 32'h0) |
                                                       ((!walk_rw_r && !mmu_rdata[4]) ? 32'h10 : 32'h0);
                                walk_m_r           <= walk_rw_r ? mmu_rdata[4] : 1'b1;
                                update_from_atc_r  <= 1'b0;
                                ms_state <= MS_UPDATE;
                            end else begin
                                walk_desc_addr_r <= walk_req_addr_r;
                                walk_m_r <= mmu_rdata[4];
                                ms_state <= MS_WALK_DONE;
                            end
                        end else begin
                            fault_r         <= 1'b1;
                            fault_is_berr_r <= 1'b0;  // Phase 150: purely logical fault
                            ms_state <= MS_FAULT;
                        end
                    end
                end

                MS_WALK_DONE: begin
                    // Load ATC entry
                    atc_valid[atc_victim]     <= 1'b1;
                    atc_va[atc_victim]        <= walk_va_r;
                    atc_fc[atc_victim]        <= walk_fc_r;
                    atc_pa[atc_victim]        <= walk_pa_r;
                    atc_ci[atc_victim]        <= walk_ci_r;
                    atc_wp[atc_victim]        <= walk_wp_r;
                    atc_m[atc_victim]         <= walk_m_r;         // Phase 150 Stage 3
                    atc_desc_addr[atc_victim] <= walk_desc_addr_r; // Phase 150 Stage 3
                    atc_victim <= (atc_victim == 5'd21) ? 5'd0 : atc_victim + 5'd1;
                    // Output PA
                    pa_r        <= walk_pa_r;
                    ci_r        <= walk_ci_r;
                    wp_r        <= walk_wp_r;
                    walk_done_r <= 1'b1;
                    ms_state    <= MS_IDLE;
                end

                // Phase 150 Stage 3 (plan.md): U/M bit hardware write-back
                // (BIU-086) -- a real FC=101 supervisor-data WRITE bus
                // cycle to the leaf descriptor's own physical address,
                // setting whichever of U/M was found to still be 0.
                // Reached either from a fresh walk (update_from_atc_r=0,
                // continues on to MS_WALK_DONE exactly as if this state
                // had never existed) or from an already-cached ATC hit
                // needing only its M bit marked (update_from_atc_r=1,
                // completes directly like MS_ATC_HIT since there is
                // nothing left to cache).
                MS_UPDATE: begin
                    if (mmu_berr) begin
                        fault_r        <= 1'b1;
                        fault_is_berr_r <= 1'b1;
                        ms_state <= MS_FAULT;
                    end else if (mmu_ack_rise) begin
                        if (update_from_atc_r) begin
                            atc_m[atc_m_update_idx_r] <= 1'b1;
                            pa_r     <= walk_pa_r;
                            ci_r     <= walk_ci_r;
                            wp_r     <= walk_wp_r;
                            hit_r    <= 1'b1;
                            ms_state <= MS_IDLE;
                        end else begin
                            ms_state <= MS_WALK_DONE;
                        end
                    end
                end

                MS_FAULT: begin
                    fault_r  <= 1'b1;
                    ms_state <= MS_IDLE;
                end

                default: ms_state <= MS_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------------
    assign pa        = pa_r;
    assign ci        = ci_r;
    assign wp        = wp_r;
    assign hit       = hit_r;
    assign walk_done = walk_done_r;
    assign fault     = fault_r;
    assign fault_is_berr = fault_is_berr_r;
    assign pflush_ack = pflush_ack_r;
    assign mmusr     = 16'h0;  // placeholder: PTEST result not yet implemented

    // mmu_req: assert while issuing walk read cycles, or the Phase 150
    // Stage 3 U/M write-back cycle. mmu_req_rw/mmu_req_wdata (1=read,
    // 0=write, matching this project's universal rw convention) are 0
    // (write) only in MS_UPDATE; every walk read leaves them at their
    // read-cycle defaults, matching the pre-Stage-3 behavior exactly.
    assign mmu_req      = (ms_state == MS_WALK_A) ||
                          (ms_state == MS_WALK_B) ||
                          (ms_state == MS_WALK_C) ||
                          (ms_state == MS_UPDATE);
    assign mmu_req_addr = (ms_state == MS_UPDATE) ? walk_desc_addr_r : walk_req_addr_r;
    assign mmu_req_fc   = 3'b101;  // supervisor data space for all walk/update cycles
    assign mmu_req_rw   = (ms_state == MS_UPDATE) ? 1'b0 : 1'b1;
    assign mmu_req_wdata = update_wdata_r;

endmodule

`default_nettype wire

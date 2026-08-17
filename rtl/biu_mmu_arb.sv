`timescale 1ns/1ps
`default_nettype none

// MC68030 BIU — MMU translation-request arbiter (Phase 150, plan.md)
//
// biu_mmu_if.sv is a single-request-at-a-time resource (one ATC, one walker
// FSM). Before this phase it only ever had one real requester (the EXT port,
// driven by m68030_mmu.sv for PTEST/explicit translation requests). Phase
// 150 wires real address translation into the live cache-miss paths, adding
// two more requesters that need the same underlying biu_mmu_if instance:
// biu_cache_if.sv (D-cache/EU side) and biu_icache_if.sv (I-cache/IFU side).
//
// Priority: EXT > D > I, matching BIU-097's own MMU-related priority
// ordering (biu_spec.md) — PTEST/explicit MMU ops already stall the whole
// pipeline by construction (m68030_mmu.sv's own comment), so giving them
// top priority here can't starve anything new.
//
// EXT's own request (m68030_mmu.sv's `biu_req`) is a genuine one-shot pulse
// (asserted for exactly one cycle, per its own MM_IDLE->MM_WAIT transition)
// — if it arrives while the arbiter is busy servicing D or I, it must not be
// lost. Latched into ext_pend_r until granted. D and I are designed
// (biu_cache_if.sv's CI_XLATE / biu_icache_if.sv's IC_XLATE) to hold their
// own request line asserted for the entire time they're waiting — level,
// not pulse — so they need no equivalent latch: the level simply stays
// visible until granted. All three requesters hold their own va/fc/rw
// stable at least until granted (EXT: m68030_mmu.sv's biu_va/fc/rw are
// plain registers, never cleared after the req pulse passes; D/I: driven
// from addr_r-style registers that don't change until the next miss), so
// no separate va/fc/rw latch is needed here either — only the pend flag.
//
// Result demux: biu_mmu_if.sv's pa/ci/wp are combinational passthroughs of
// its own latched output (valid the whole time, harmless to broadcast to
// all three), but hit/walk_done/fault are one-cycle pulses that must only
// ever reach the requester actually being serviced — gated on owner_r.

module biu_mmu_arb (
    input  logic        clk_4x,
    input  logic        rst_n,

    // Requester EXT — existing top-level port (m68030_mmu.sv: PTEST today)
    input  logic [31:0] ext_va,
    input  logic [2:0]  ext_fc,
    input  logic        ext_rw,
    input  logic        ext_req,
    output logic [31:0] ext_pa,
    output logic        ext_hit,
    output logic        ext_walk_done,
    output logic        ext_fault,
    output logic        ext_fault_is_berr,
    output logic        ext_ci,
    output logic        ext_wp,

    // Requester D — biu_cache_if.sv (D-cache/EU side miss-path translation)
    input  logic [31:0] d_va,
    input  logic [2:0]  d_fc,
    input  logic        d_rw,
    input  logic        d_req,
    output logic [31:0] d_pa,
    output logic        d_hit,
    output logic        d_walk_done,
    output logic        d_fault,
    output logic        d_fault_is_berr,
    output logic        d_ci,
    output logic        d_wp,

    // Requester I — biu_icache_if.sv (I-cache/IFU side miss-path translation)
    input  logic [31:0] i_va,
    input  logic [2:0]  i_fc,
    input  logic        i_rw,
    input  logic        i_req,
    output logic [31:0] i_pa,
    output logic        i_hit,
    output logic        i_walk_done,
    output logic        i_fault,
    output logic        i_fault_is_berr,
    output logic        i_ci,
    output logic        i_wp,

    // Arbitrated port to biu_mmu_if.sv
    output logic [31:0] mmu_va,
    output logic [2:0]  mmu_fc,
    output logic        mmu_rw,
    output logic        mmu_req,
    input  logic [31:0] mmu_pa,
    input  logic        mmu_hit,
    input  logic        mmu_walk_done,
    input  logic        mmu_fault,
    input  logic        mmu_fault_is_berr,
    input  logic        mmu_ci,
    input  logic        mmu_wp
);

    typedef enum logic [1:0] {
        OWN_NONE = 2'd0,
        OWN_EXT  = 2'd1,
        OWN_D    = 2'd2,
        OWN_I    = 2'd3
    } owner_t;

    owner_t owner_r;
    logic   ext_pend_r;

    wire ext_want = ext_req || ext_pend_r;

    // Grant combinational logic: EXT > D > I, only when idle
    logic grant_ext, grant_d, grant_i;
    assign grant_ext = (owner_r == OWN_NONE) && ext_want;
    assign grant_d   = (owner_r == OWN_NONE) && !ext_want && d_req;
    assign grant_i   = (owner_r == OWN_NONE) && !ext_want && !d_req && i_req;

    assign mmu_va  = grant_ext ? ext_va : (grant_d ? d_va : i_va);
    assign mmu_fc  = grant_ext ? ext_fc : (grant_d ? d_fc : i_fc);
    assign mmu_rw  = grant_ext ? ext_rw : (grant_d ? d_rw : i_rw);
    assign mmu_req = grant_ext || grant_d || grant_i;

    always_ff @(posedge clk_4x or negedge rst_n) begin
        if (!rst_n) begin
            owner_r    <= OWN_NONE;
            ext_pend_r <= 1'b0;
        end else begin
            // Latch EXT's own one-shot request if it arrives while busy;
            // clear the instant it's actually granted. Clear-first priority
            // so a request immediately granted the same cycle it arrives
            // never gets spuriously latched for a later, stale re-grant.
            if (grant_ext)     ext_pend_r <= 1'b0;
            else if (ext_req)  ext_pend_r <= 1'b1;

            if (owner_r == OWN_NONE) begin
                if (grant_ext)      owner_r <= OWN_EXT;
                else if (grant_d)   owner_r <= OWN_D;
                else if (grant_i)   owner_r <= OWN_I;
            end else if (mmu_hit || mmu_walk_done || mmu_fault) begin
                owner_r <= OWN_NONE;
            end
        end
    end

    // Result demux — pa/ci/wp broadcast freely (harmless outside the owner's
    // own window); hit/walk_done/fault gated so a pulse only ever reaches
    // the requester actually being serviced.
    assign ext_pa       = mmu_pa;
    assign ext_ci        = mmu_ci;
    assign ext_wp        = mmu_wp;
    assign ext_fault_is_berr = mmu_fault_is_berr;
    assign ext_hit        = mmu_hit       && (owner_r == OWN_EXT);
    assign ext_walk_done  = mmu_walk_done && (owner_r == OWN_EXT);
    assign ext_fault      = mmu_fault     && (owner_r == OWN_EXT);

    assign d_pa       = mmu_pa;
    assign d_ci        = mmu_ci;
    assign d_wp        = mmu_wp;
    assign d_fault_is_berr = mmu_fault_is_berr;
    assign d_hit        = mmu_hit       && (owner_r == OWN_D);
    assign d_walk_done  = mmu_walk_done && (owner_r == OWN_D);
    assign d_fault      = mmu_fault     && (owner_r == OWN_D);

    assign i_pa       = mmu_pa;
    assign i_ci        = mmu_ci;
    assign i_wp        = mmu_wp;
    assign i_fault_is_berr = mmu_fault_is_berr;
    assign i_hit        = mmu_hit       && (owner_r == OWN_I);
    assign i_walk_done  = mmu_walk_done && (owner_r == OWN_I);
    assign i_fault      = mmu_fault     && (owner_r == OWN_I);

endmodule

`default_nettype wire

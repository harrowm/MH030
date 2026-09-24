# EU/BIU pipeline cut-point investigation (read-only, not yet implemented)

## Context

`plan.md`'s Phase 285 scoped "Phase C" as if `eu_seq`'s own failing-endpoint
population were a self-contained, eu_seq-local timing problem, separable from
Phase A's cache work. Module-level endpoint counts (from the latest, post-
Phase-A `timing_report.json`) still show `u_seq` owning 60.8% of the failing
population — but per-cell synthesized names (e.g. `wb_result_TRELLIS_FF_...`)
are **not reliable signal attribution**: ABC9 names newly-created intermediate
LUT/mux cells after the nearest still-traceable ancestor register, which can
be many hops removed from the actual RTL cause. Only the hierarchical
instance-path *prefix* (`u_cpu.u_eu.u_seq.*`) is trustworthy; the suffix is
synthesis narrative, not RTL identity.

nextpnr's own single worst critical path (`critical_paths[0]`, 3249 hops) has
**both** endpoints tracing back to `u_cpu.u_biu.u_cache.addr_r` — the same
structural chain already documented in Phase 284
(`project_fpga_real_timing_closure.md`): BIU cycle-gen state → cache
interface → register file → address ALU → write-data steering → external
bus, no register boundary anywhere in it. This is a whole-system chain, not
an eu_seq-local one.

## The real shape of the chain: it's the Track 1-3 mechanism itself

Traced `mem_addr`'s own dispatch mux (`eu_seq_execute.svh:5669`):

```
mem_addr = preview_ok ? preview_addr
         : movem_run_r ? movem_addr_r
         : ... (15 more special-FSM "_r" registers) ...
         : ex_ea;
```

Every arm is **already a registered value** (`preview_addr` is continuously,
unconditionally computed every cycle from `rd_prev_a_data`/`rd_prev_b_data` +
decode-time constants — Track 2's whole point was to make it depend on
nothing gated by `mem_ack`; every other arm is a genuine `_r` flip-flop).
`ex_ea` (the one fallback) is the current EX-stage instruction's own EA, also
already latched.

**So the mux inputs are not the depth problem. The mux *select*
(`preview_ok`, `eu_seq_preview.svh:707`) is.** `preview_ok` is gated on
`preview_current_ready`, which is a ~17-way OR of every family's own
`*_final_ack` signal — and **every one of those is itself `&& mem_ack`
(THIS cycle's ack)**, ANDed with a ~14-way hazard/exclusion chain
(`hazard_ex`, `hazard_wb`, `hazard_ccr`, `movem_hazard`, ...,
`ex_redirect_pending_older`, `need_ext`). Several individual terms are
deeper than a flag check — e.g. `cas_final_ack = (cas_get_du_r && !cas_z_r)
|| cas_after_r`, where `cas_z_r` is a live compare of `mem_rdata` (this
cycle's read data) against `Dc`; `cmp2_final_ack` excludes `chk_trap`, itself
a live bounds compare.

**This is not a narrow 5-instruction exception.** `preview_ok`'s "decide the
next address the instant this cycle's ack arrives" behavior is the literal,
deliberate mechanism the entire Track 1-3 effort (~20 phases,
`wobbly-honking-cascade.md`) built to guarantee real-silicon-matching
zero-gap back-to-back bus dispatch — for *every* instruction pair in the
machine, not just `dyn_bit_get_Dn`'s 5 families (which is a narrower,
separate same-cycle dependency: the register *number* to read, not the
address). Real 68030 silicon achieves this with asynchronous combinational
gates completing within one external bus period; this project's clk_4x
synchronous model can only approximate that by doing the equivalent decision
as pure combinational logic within one `clk_4x` tick — which is exactly what
now spans ~3600 hops across BIU+EU+arbiter.

## Category (a): staged-one-cycle-early candidates — genuinely narrow

Almost nothing here is free. The one real opportunity found:

| Candidate | What | Why it's safe | Rough impact |
|---|---|---|---|
| Split `preview_current_ready`'s OR into "ordinary read/write" (shallow: `ex_valid && (ex_is_mem_rd\|\|ex_is_mem_wr) && ... && mem_ack && !ex_mem_stall`) vs. "16 special FSMs" (deep, includes live compares) as two separately-timed paths feeding the same final `preview_ok` | Restructure only — no behavior change. The special-FSM instructions are already inherently multi-cycle (MOVEM, CAS, CAS2, bitfield-mem, ...); an extra `clk_4x` tick of *internal combinational settling* for their own final-ack decision does not change their externally observed S-state cycle count if it only affects logic depth, not registered state. | Unclear/unverified — would need a synthesis measurement. This is a *logic restructuring* (balance the tree, hoist the common case), not new registers, so it carries much lower correctness risk than genuine pipelining. |
| Re-balance the ~14-term hazard AND-chain (`!hazard_ex && !hazard_wb && ... && !need_ext`) into a tree instead of a flat chain | Same shape as the already-fixed `ext_count` else-if chain (`feedback_elseif_priority_chain.md`) — flat AND/OR chains synthesize to linear depth in the worst case even though functionally a balanced tree would do the same job in log depth | Small, unverified |

Neither of these changes any instruction's cycle count or the zero-gap
guarantee. Both are speculative until measured — flagged honestly as
inference from RTL structure, not confirmed via synthesis.

## Category (b): genuinely same-cycle-reactive, NOT pipelineable without a real cycle-count change

This category is now understood to be **much larger than `plan.md`'s
existing scoping note anticipated**. It's not "`dyn_bit_get_Dn` plus a
handful of siblings" — it's the entire `preview_ok`/`mem_addr` dispatch
mechanism for every back-to-back bus cycle in the machine. Genuinely
pipelining "ack arrives → next address computed" (inserting a real register
between them) would, by construction, insert at least one extra `clk_4x`
tick of gap between *every* consecutive bus cycle for *every* instruction —
a far bigger behavioral change than the plan.md note's framing, and would
directly reverse Track 1-3's ~20-phase zero-gap achievement, not just carve
out 5 special cases. **Do not attempt without fresh, explicit scoping and
sign-off** — this needs to go back to the user as a much bigger question
than "Phase C: pipeline eu_seq."

`dyn_bit_get_Dn` itself (`eu_seq_execute.svh:2509`, already documented in
Phase 285/`feedback_downstream_register_needs_upstream_slack.md`) is a
narrower, separate instance of the same shape — the target register *number*
for 5 dynamic-bit-instruction families isn't known until the memory read
that names it acks, so it can't be predicted a cycle early the way
`preview_addr` can.

## Structurally risky / off-limits

The TAS/CAS/CAS2 bus-lock mechanism (`bus_lock` in `biu_arbiter.sv`, driven
from `biu_cycle_gen.sv`'s own internal FSM state) depends on razor-precise
cycle timing of exactly this same reactive path — Track 3 #14/#15/#16's own
extensive re-derivation (`eu_seq_preview.svh:458-599`) exists specifically
because getting this wrong breaks the "indivisible operation" guarantee.
**Any restructuring here must not touch `cas_active_r`/`eu_cas_hold`/
`bus_lock` timing** (`feedback_live_address_during_held_grant.md`'s lesson
applies directly — a requester's address must stay stable for the arbiter's
whole held grant).

## Bottom line

There is no clean, low-risk "stage X one cycle earlier" fix comparable to
Phase A's cache BRAM work. The dominant chain is the deliberate, central
zero-gap dispatch mechanism itself. The only real category-(a) lever found
is restructuring `preview_ok`'s own logic depth (balance vs. flatten) without
changing any instruction's behavior — unverified, modest, worth trying first
since it's cheap and reversible. Actually reducing the *scope* of what's
computed same-cycle (true pipelining) is a much bigger effort than
previously scoped and needs the user's explicit go-ahead on a redefined,
larger-scale Phase C before any RTL is touched.

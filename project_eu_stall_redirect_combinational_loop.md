# EU stall/redirect combinational feedback loop (Phase 284, FIXED AND VERIFIED)

## Discovery

Found in the same investigation as
[project_biu_dcache_hit_combinational_loop.md](project_biu_dcache_hit_combinational_loop.md).
After implementing and verifying that fix, re-running real FPGA synthesis
showed **no improvement** (1.73 MHz vs the original 1.66 MHz) — confirming
a second, genuinely separate combinational loop, confined entirely to
`eu_seq_execute.svh`/`eu_seq_preview.svh` (no BIU involvement).

`ex_mem_stall`'s own BKPT-hazard term directly reads `ex_redirect_pending`
(`rtl/eu_seq_execute.svh`), which depends on `branch_taken` →
`dec_branch_taken`, which depends on `stall` → `stall_base`, which depends
directly back on `ex_mem_stall` (`stall_base = ex_mem_stall || ...`) — a
real combinational cycle with no register anywhere in it.

This loop protects a real, previously-fixed bug ("Bug 2",
`plan.md.old2:4497-4570`): a raw BKPT opcode's own early stall-trigger
could fire on a stale, about-to-be-flushed decode slot the same cycle an
older JSR/BSR/RTS/RTR/RTE (or a taken Bcc/JMP/DBcc, which has no
multi-cycle EX-pending state of its own) is genuinely redirecting. So this
term could not simply be deleted the way the D-cache one was.

## Analysis

`branch_taken`'s formula is `dec_branch_taken | ex_dbcc_taken |
cpcc_branch_taken | cpdbcc_branch_taken | ex_jmp_taken | ex_jsr_taken |
ex_bsr_taken | ex_rts_taken | ex_rtr_taken | ex_rte_taken`.
`dec_branch_taken` is the *only* term that is about the *current* decode
slot (`q[0]`, live, same-cycle) — every other term is `ex_*`-prefixed,
referring to an *older* instruction already latched into EX.

`dec_is_bkpt` and `dec_is_branch` are structurally mutually exclusive for
the same `dec_valid`/`q[0]` slot (an opcode can't be both), so
`dec_branch_taken` is provably irrelevant to the BKPT hazard check
specifically — it's exactly the one term that closes the loop, and the
one term that was never actually load-bearing for this consumer. The same
mutual-exclusion argument holds for the *other* real combinational
consumer, `preview_ok` in `eu_seq_preview.svh` (gated on
`dec_is_mem_rd`/`dec_is_mem_wr`, also mutually exclusive with
`dec_is_branch`). A third consumer (inside an `always_ff` block gating
`bkpt_start_r`) is unaffected — registered logic naturally breaks the loop
there, no change needed.

## Fix

Added `ex_redirect_pending_older` (`rtl/eu_seq_execute.svh`, declared near
`ex_redirect_pending`, assigned after `branch_taken` where all its inputs
are available) — exactly `branch_taken`'s formula with `dec_branch_taken`
dropped, OR'd with the same "still waiting on `mem_ack`" term
`ex_redirect_pending` already has. Both real combinational consumers
(`ex_mem_stall`'s BKPT term; `preview_ok`) now read this narrower signal
instead. `ex_redirect_pending` itself is untouched, still used by the
safe `always_ff` consumer.

The new signal's declaration (early, bare `logic`) is deliberately
separated from its assign (late, after `branch_taken` and every
constituent `ex_*_taken` signal is available) to work around this
project's own documented Icarus forward-reference limitation — a
`wire X = Y;` inline declaration doesn't bind correctly when referenced by
an earlier continuous assign. Confirmed via `make sim/eu_tb` that this
pattern compiles cleanly.

## Verification

`make test` 38/38 (including `stall_fsm`, the BKPT test suite),
`cosim_grp`/`cosim_memind`/`dat-synth` clean, full Harte sweep
bit-identical to baseline. Critically, a dedicated re-run of
`JSR.json.gz`/`RTS.json.gz`/`BSR.json.gz`/`RTR.json.gz`/`RTE.json.gz` (the
exact suites Bug 2's own original regression was found in) all 100%, zero
timeouts, confirming Bug 2 is not reintroduced. A fresh Verilator
elaboration confirmed all four originally-flagged `UNOPTFLAT` warnings
(`preview_ok`, `ex_redirect_pending`, `rd_a_sel`, `rd_b_sel`) gone
entirely.

## Important: this fix, combined with the D-cache fix, still did NOT resolve the real-hardware timing problem

Re-running FPGA synthesis with **both** fixes in place gave `1.78 MHz` —
barely different from the 1.66 MHz baseline. Both loops were genuine bugs
worth fixing (Verilator's `UNOPTFLAT` warnings are gone, and the design is
now free of every combinational cycle these tools can detect), but neither
was ever the dominant contributor to the achieved frequency. Pulling the
actual `nextpnr` critical-path report for the `$glbnet$clk_4x` domain
showed the real bottleneck: a single **562.30 ns** (189.84 ns logic +
372.46 ns routing), ~3600-hop **acyclic** combinational chain spanning
nearly the entire design — BIU cycle-gen state → cache interface →
dynamic-bit/CAS2 logic → register file → address ALU (full carry chain) →
write-data steering → out onto the external bus → into whichever
peripheral is selected — with no register boundary anywhere in it.
1/562ns ≈ 1.78 MHz, matching the reported number exactly.

This is a fundamentally different, much larger problem than a
combinational loop: it's simply that an entire instruction's worth of
combinational logic happens within one `clk_4x` edge, a direct consequence
of this project's S-state FSM / zero-delay-simulation design premise,
which was never checked against real propagation delay before. Closing it
requires genuine pipelining — inserting registers through the middle of
that chain without changing the externally-visible S-state cycle count —
tracked as a new, separate, much larger effort (see `plan.md` Phase 285+,
not yet started as of this writing).

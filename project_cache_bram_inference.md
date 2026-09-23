# D-cache `data_d` BRAM-inference investigation (Phase 285, Phase A — PARTIAL: real RTL fixes shipped, BRAM mapping still not achieved)

## Context

Phase 285's own real-hardware timing investigation found 80.6% of the
design's 9,040 failing (>10ns) endpoints concentrate in 3 modules —
`eu_seq` (31.6%), the D-cache interface (25.6%), the I-cache interface
(23.3%). `biu_cache_if.sv`'s `data_d` array alone accounted for 2,048 of
those endpoints (100% of its own 64×32 bits), root-caused to Yosys's own
`Warning: Replacing memory \data_d with list of registers` — confirmed
via the synthesis log to be driven by 7 distinct, scattered non-blocking
write sites (far more than ECP5's DP16KD BRAM's own 2-port maximum), so
`memory_collect` gave up early and fell back to flip-flops for the whole
array.

## Fix 1: consolidate 7 write sites into one shared write port

Every `data_d[idx][woff] <= value;` site was converted to stage
`data_d_wr_en/idx/woff/data` via blocking assignment (using each site's
own exact, unchanged gating condition), with one final
`if (data_d_wr_en) data_d[...] <= ...;` at the end of the same process.
The one genuinely simultaneous write (`CI_D_BURST0`'s own full-CBACK-
success completion, which needs to write all 4 word-offsets of a line
at once — real BRAM write ports can only write one address per cycle)
was restructured: the CPU's own requested word (`woff_r`) writes
immediately via this shared port (zero timing change, since
`fill_rdata_r` already forwards the value to `eu_rdata` independently of
`data_d` — the exact "critical word forwarding" pattern
`CI_D_FILL_1B/2B/3B`'s own pre-existing degraded-burst-fallback path
already established); the other 3 words are written by a new background
sequencer (`dtrickle_*`) over the following up to 4 ticks, marking each
word's own `valid_d` bit only once its own write actually lands (so a
premature access to a not-yet-trickled word correctly misses instead of
reading stale data).

**Empirically confirmed via a real `make test` regression** that this
mechanism was necessary, not hypothetical: `tb/biu_tb.sv`'s own "MOVE16
burst write" tests drive `eu_m16_req` directly at `biu_cycle_gen`'s own
module port (bypassing `m68030_top.sv`'s hardwired-0 tie-off — this
specific burst-write path is permanently unreachable from the real
integrated chip, MOVE16 having been removed entirely, Phase 250 F8, but
is still exercised by this unit test), which initially failed with stale
data until `is_burst_write` was used to exclude it from the new register
path and keep it reading live, exactly matching its original behavior.

## Finding: a `always_ff` write nested inside an async-reset `if/else` defeats `memory_collect`

A first implementation computed `data_d_wr_en/idx/woff/data` via blocking
assignment *within* this file's own big, reset-wrapped FSM `always_ff`,
performing the actual write at the end of that same process (the
standard "next-state logic inside the clocked process" idiom used
elsewhere in this project). This compiled and passed the full mandatory
gate, but a minimal, isolated Yosys repro (built specifically to root-
cause this) confirmed it does **not** let `memory_collect` infer a clean
`$mem` cell at all: nesting the final `data_d[...] <= ...;` inside an
`if (!rst_n) ... else begin ... end` structure defeats it, regardless of
how the address/data/enable are computed upstream. The write has to live
in its own process with no enclosing reset branch — `data_d` was never
explicitly reset anyway (only `valid_d` gates whether its contents are
ever meaningfully read), so this costs nothing.

**A second, real risk was found and avoided while fixing this**: the
naive fix (a second, separate `always @(posedge clk)` reading
`wr_en`/`wr_idx`/etc. from the *other*, reset-wrapped process's own
blocking-assigned locals) is a genuine simulation/synthesis mismatch
risk — two `always` blocks triggered by the same edge have an undefined
relative execution order in simulation, but real synthesis would treat a
signal only ever driven inside a clocked process as an actual register
(valid one tick later) regardless of that ordering. Not used. Instead,
`data_d_wr_en/idx/woff/data` were rebuilt as genuine combinational wires,
driven by a dedicated `always_comb` computing directly from
already-registered signals (`state`, `idx_r`, `woff_r`, `vtag_r`,
`siz_r`, `addr_r`, `wdata_r`) and live inputs (`sf_ack_rise`,
`dc_burst_ack`, `dc_burst_beat`, `dc_burst_rdataN`, `ciin`, `dcache_en`,
`xl_ci_r`, `d_size_ok_r`, `dfreeze_en`, `dhit_r`, `wa_en`) — mirroring
each of the 7 sites' own exact original condition, verified one at a
time against the corresponding state's own body in the main FSM. The
two copies are independent by necessity (no shared source) and need to
be kept in sync if either changes.

## Fix 2: merge two independent reads into one shared read

`eu_rdata`'s own `extract_rd(data_d[idx_r][woff_r], ...)` (in the output
`always_comb`) and `merge_wr`'s own old-value argument,
`merge_wr(data_d[idx_r][woff_r], ...)` (in the write-decision
`always_comb`), both read the identical address from two different
processes. Merged into one shared `wire [31:0] data_d_rd =
data_d[idx_r][woff_r];`, reused by both.

## Finding: `memory_share`'s own SAT check rejects the two write ports as non-mergeable

With the two writes structured as genuinely separate ports (Port A: the
main FSM; Port B: the `dtrickle_*` trickle sequencer, each its own
reset-free `always_ff`), a real full synthesis run's own `MEMORY_SHARE`
log reported explicitly: `Checking group clocked with posedge \clk_4x,
width 32: ports 0, 1. ... According to SAT solver sharing of port 0
with port 1 is not possible.` Almost certainly a conservative, tool-
level limitation — SAT-based combinational equivalence checking reasons
about the write-enable logic in isolation, not the real reachable FSM
state space this design's own arbiter/state machine actually restricts
it to (a genuinely new bus transaction requires `sf_ack_rise`/
`dc_burst_ack`, both of which take many `clk_4x` ticks to arrive,
structurally unable to collide with the trickle's own ≤4-tick window) —
but Yosys won't merge automatically either way, and DP16KD only has 2
total ports for what would then be 3 accesses (2 writes + 1 read) to
share.

## Fix 3: explicit RTL arbitration onto one shared physical write port

Rather than rely on inference, the two writes were explicitly arbitrated
in RTL: `main_wr_en/idx/woff/data` (the main FSM's own 7-site decision,
renamed from the original `data_d_wr_*`) feeds a final priority-mux
`always_comb` — the main FSM always wins; the trickle sequencer only
gets the shared port on a cycle the main FSM isn't using it. The
trickle's own advance (`dtrickle_next_r` incrementing, that word's own
`valid_d` bit committing) is gated on `!main_wr_en`, so it never
advances past a word it didn't actually get to write — it simply retries
the same word next cycle on a collision. `data_d` now has exactly one
write statement anywhere in this file.

**Verified**: re-running the isolated diagnostic confirmed `data_d`
collects with exactly 1 write port (down from 2), and the
`MEMORY_SHARE`/SAT-solver "not possible" message disappeared entirely
(nothing left to consolidate).

## Remaining, unresolved finding: `memory_libmap` still chooses FF mapping over BRAM

Even with a structurally clean 1-write + 1-read `$mem` cell (exactly
matching DP16KD's own 2-port `srsw` template shape), `memory_libmap`
still reports `using FF mapping for memory biu_cache_if.data_d` instead
of mapping it to a real `DP16KD`. Directly ruled out a cost/size
heuristic (data_d is only 2,048 bits against DP16KD's 16Kbit capacity)
as the explanation: re-running with `-logic-cost-ram` overridden to
progressively larger values, up to an extreme 1,000,000, produced
*zero* change in the outcome — this is a genuine structural mismatch
against the library's own matching rules
(`~/oss-cad-suite/share/yosys/lattice/brams_16kd.txt`), not a tunable
cost trade-off. The specific remaining requirement (possibly related to
the rules file's own `rdinit zero;`/`init no_undef;` clauses, since
`data_d` has no explicit reset/init value at all) was not identified
before this investigation's own time budget for this specific sub-
problem was exhausted.

## Verification

All 3 fixes shipped so far are independently verified correct: full
mandatory gate clean (`make test` 38/38, `cosim_grp` 8/8, `cosim_memind`
33/33, `dat-synth` 50/50), full 124-suite Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2`), `tb/cache_tb.sv`'s own dedicated D-cache
suite clean including D-10 (burst-miss read, directly exercising the
trickle sequencer's own correctness: a different word offset within the
same burst-filled line, accessed later, correctly hits with 0 bus
cycles — proof the background trickle genuinely completes and populates
the array correctly).

## Status

The RTL is now measurably cleaner and more correct than before this
investigation (a single, explicitly-arbitrated write port instead of 7
scattered ones; no read duplication) — worth keeping regardless of the
BRAM outcome. But the original goal (moving `data_d`'s 2,048 failing
endpoints off the critical-endpoint population via real BRAM inference)
is **not yet achieved**. Real timing impact from this specific
investigation has not yet been measured via a full synthesis run.
`tag_d`, `valid_d` (this same module), and the I-cache's own equivalent
arrays (`biu_icache_if.sv`) were deliberately not attempted this session
— see `plan.md`'s own Phase 285 section for how to prioritize picking
this back up.

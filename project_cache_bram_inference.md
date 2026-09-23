# D-cache/I-cache `data_d`/`data_i` BRAM-inference investigation (Phase 285, Phase A — RESOLVED: real BRAM mapping achieved for both)

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
before this investigation's own initial time budget for this specific
sub-problem was exhausted — **later resolved, see below.** A cost-based
explanation was directly ruled out first: re-running with
`-logic-cost-ram` overridden to progressively larger values, up to an
extreme 1,000,000, produced zero change in the outcome.

## Fix 4 (the real resolution): the read had to be registered, not just consolidated

Two research angles, both explicitly requested rather than continuing to
guess: a web search for known Yosys/ECP5 BRAM-inference gotchas, and a
from-scratch minimal reproduction built up incrementally from a working
case to find exactly where the BRAM decision breaks.

The web search surfaced `YosysHQ/yosys#3400` — a maintainer's own
answer to an extremely similar "same-clock read+write doesn't map to
DP16KD" symptom, suggesting `(* no_rw_check *)`. Applied to `data_d`'s
own declaration first; **empirically did not fix it** (confirmed via
the same isolated repro this whole investigation used throughout).

The real answer came from re-running the exact pass sequence
`synth_lattice` actually uses (found via `help synth_lattice`/`help
memory`: `memory -nomap -no-rw-check -bram <rules>` then a separate
`memory_libmap -lib <rules>` — the earlier manual diagnostic had been
missing `memory_dff`, one of `memory`'s own constituent passes). Its
own diagnostic output was unambiguous: `Checking read port `\data_d'[0]
... no output FF found. Checking read port address `\data_d'[0] ... no
address FF found.` `data_d_rd` (feeding both `merge_wr`'s own old-value
argument and `eu_rdata`'s own `CI_HIT` use) was **purely
combinational** — but every port in DP16KD's own template
(`brams_16kd.txt`) requires `clock anyedge`: real block RAM read ports
are physically synchronous silicon, and Yosys cannot map an
asynchronous read onto one, no matter how the write side is shaped.
Confirmed directly: registering that one read (nothing else changed)
was what actually got `memory_libmap` to report `mapping memory ...
via $__PDPW16KD_` instead of `using FF mapping`, in isolation.

The real fix required two separate signals, since the two consumers
need the read at genuinely different moments:

- **`data_d_rd_hit`** (Port B, `data_d`'s own dedicated read-only port):
  `data_d_rd_hit <= data_d[idx][woff];`, unconditional every tick, keyed
  off the *live*, pre-latch `idx`/`woff` (not `idx_r`/`woff_r`) — this
  settles exactly one tick after *any* dispatch, matching `CI_HIT`'s own
  pre-existing, Phase-284-established one-cycle-later hit latency
  exactly. `eu_rdata`'s own `CI_HIT` use now reads this directly — zero
  timing change.
- **`data_d_rd_write_r`**: `merge_wr`'s own old-value need is different
  — it's needed at `CI_WRITE`'s own `sf_ack_rise`, many ticks after
  dispatch, keyed off `idx_r`/`woff_r` specifically (which may no longer
  match the *live* `idx`/`woff` by then). Rather than a third BRAM read
  port (DP16KD only has 2 total, both already spoken for by Port A and
  Port B), this is an ordinary register, latched exactly once — on
  `CI_WRITE`'s own first active tick (`in_ci_write_r` edge-detects this)
  — directly from `data_d_rd_hit`'s own already-correct value at that
  exact moment (one tick after the `CI_IDLE`→`CI_WRITE` dispatch edge,
  precisely when `data_d_rd_hit` holds *this* dispatch's own old value)
  — then held stable for the rest of `CI_WRITE`'s own multi-tick
  duration (safe: `idx_r`/`woff_r`, and therefore `data_d[idx_r]
  [woff_r]`'s own content, cannot change during this window — this
  project's own single-outstanding-bus-transaction model guarantees
  nothing else can write it meanwhile).

`(* no_rw_check *)` was removed once the fix above was confirmed
sufficient on its own (verified empirically, with and without the
attribute) — with each port now doing exactly one thing (Port A
write-only, Port B read-only), there's no same-port read-during-write
ambiguity left for it to resolve.

## Verification (data_d)

All 4 fixes are independently verified correct: full mandatory gate
clean (`make test` 38/38, `cosim_grp` 8/8, `cosim_memind` 33/33,
`dat-synth` 50/50), full 124-suite Harte sweep bit-identical to baseline
(`PASS 702142 FAIL 2`), `tb/cache_tb.sv`'s own dedicated D-cache suite
clean including D-10 (burst-miss read, directly exercising the trickle
sequencer's own correctness: a different word offset within the same
burst-filled line, accessed later, correctly hits with 0 bus cycles) and
D-11 (write-hit while frozen, directly exercising `data_d_rd_write_r`'s
own correctness: the merged, partially-updated value lands correctly
and the entry stays cached). **`data_d` genuinely maps to a real DP16KD
BRAM primitive** — confirmed directly via an isolated Yosys run
(`memory_libmap` reports `mapping memory biu_cache_if.data_d via
$__PDPW16KD_`), not just inferred from the absence of a warning.

**Confirmed again in the full design context**, not just in isolation: a
real `synth_lattice` run against the whole `mackerel_030f` SoC reports
`mapping memory mackerel_030f.u_cpu.u_biu.u_cache.data_d via
$__PDPW16KD_`, DP16KD count 2→3, and resource usage dropped
substantially as predicted: LUT4 51,525→47,610 (-7.6%), TRELLIS_FF
13,569→11,626 (-14.3%).

## Extension: `biu_icache_if.sv`'s `data_i` (same session, same fix, one real difference)

Applied the identical, now-proven fix to the I-cache's own equivalent
array — flagged by the identical `Replacing memory \data_i with list of
registers` warning, and per Phase 285's own module-level breakdown, a
comparably large share of the design's own failing-endpoint population
(23.3% vs `data_d`'s 25.6%). Genuinely simpler in one respect: this
module is read-only from software's own perspective (no write-hit/
`merge_wr` equivalent at all), so only one registered read
(`data_i_rd_hit`, mirroring `data_d_rd_hit` exactly) is needed, not two.

**One real, new correctness issue found and fixed along the way**:
`valid_i` is per-LINE here, unlike `data_d`'s own per-WORD `valid_d`.
The original code committed `tag_i`/`valid_i` in the same cycle as the
(atomic, 4-simultaneous) full-CBACK-success write. Splitting that write
across Port A (the requested word, immediate) and a background trickle
sequencer (`itrickle_*`, the other 3 words) the same way `data_d` was
fixed would have left a real window where `valid_i` claims the whole
line is valid while 3 of its 4 words are still mid-trickle — a later
access to any of those *other* words would hit and read genuinely
stale/uninitialized `data_i` content. Fixed by moving `tag_i`/`valid_i`'s
own commit to the trickle sequencer's own final step instead of the
main FSM's dispatch-completion cycle — `itrickle_tag_r`/
`itrickle_valid_ok_r` latch the values needed for that commit (`vtag_r`,
`!ciin`) at `itrickle_start`, since `ciin` itself is only meaningful
right at burst completion, not several ticks later when the trickle
actually finishes.

**A real test-coverage gap found while verifying**: none of
`tb/cache_tb.sv`'s own existing I-cache tests (I-1 through I-6) exercise
`IC_BURST0`'s own full-CBACK-success path at all — every one uses
IBE=0 (the non-burst, sequential `IC_SINGLE_0..3` fill), meaning the new
`itrickle_*` mechanism was entirely untested by the regression suite as
shipped. Found `tb/biu_tb.sv`'s own dedicated `u_icache`-instance test
(`P-ICI-B`) does exercise a full 4-beat burst directly, but checked
`valid_i` immediately after `ic_burst_ack` (one cycle too soon for the
new deferred-commit timing) and never checked the other 3 words'
own content at all. Fixed both: waits for
`u_icache.itrickle_active_r` to clear before inspecting internal state
(external `ifu_ack`/`ifu_rdata` timing, already checked, is completely
unaffected), and added direct checks that all 3 non-requested words
landed correctly (mirroring `data_d`'s own D-10 test).

## Verification (data_i)

Full mandatory gate clean (`make test` 38/38, `cosim_grp` 8/8,
`cosim_memind` 33/33, `dat-synth` 50/50), full Harte sweep bit-identical
to baseline, `tb/biu_tb.sv`'s own extended `P-ICI-B` test directly
proving the trickle sequencer populates all 4 words correctly and
`valid_i` only commits once it's genuinely safe to. Confirmed via an
isolated Yosys run: `memory_libmap` reports `mapping memory
biu_icache_if.data_i via $__PDPW16KD_`.

## Status

Both `data_d` and `data_i`'s BRAM-inference goals are achieved: the RTL
is correct (fully re-verified for both) and both map to real hardware
block RAM instead of flip-flops plus wide read-select/tag-compare
logic.

**Real-hardware timing impact confirmed, and it's genuinely positive**:
a full synthesis + place-and-route run with the `data_d` fix alone (the
`data_i` fix landed just after this run was launched) achieved
`$glbnet$clk_4x` = **2.39 MHz, up from the 1.79 MHz Phase 285 baseline —
a ~33% improvement from this one fix alone.** A second run with both
`data_d` and `data_i` fixes together achieved **2.46 MHz** — a further,
smaller gain from the I-cache fix on top (`data_i` is a somewhat smaller
share of the failing population than `data_d`, 23.3% vs 25.6%, so a
smaller incremental gain is expected). **Combined: 1.79 MHz → 2.46 MHz,
~37% real improvement from Phase A overall.** This is a real, measured
result, not just a resource-usage inference — and a meaningfully
different outcome from this session's earlier `wdata_hold_r` attempt
(project_write_data_critical_path.md), which was also fully verified
correct but had *zero* measured frequency effect.

**Honest framing**: this confirms the BRAM-inference approach genuinely
works and was worth doing, but Phase A was never expected to reach
100 MHz on its own — `data_d`/`data_i` together were only ~49% of the
failing-endpoint population Phase 285 mapped, and achieved frequency is
set by the single worst remaining path, not an average. The remaining
gap to 100 MHz is dominated by Phase C (`eu_seq`, 31.6% of the failing
population, including the `dyn_bit_get_Dn` architectural dependency
found during the write-data investigation) — a much larger effort,
scoped but not started, needing explicit user sign-off before beginning
given it includes a real cycle-count trade-off decision.

`tag_d`/`valid_d` and `tag_i`/`valid_i` (both modules, small, lower
priority per Phase 285's own module-level breakdown — the 64-bit-per-
line `data_d`/`data_i` arrays dominate that share by a wide margin)
were deliberately not attempted this session.

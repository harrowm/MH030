# Caches — Architecture, Timing, and Test Coverage

This document catalogs the I-cache and D-cache: where each one lives in the RTL, how
each works (hit/miss/fill/flush), and which testbench proves it. It exists for the
same reason `docs/stalls.md` exists: the Tom Harte SingleStepTests corpus — the
project's primary correctness oracle — never exercises either cache at all. `CACR`
resets to 0 (both caches disabled) and no Harte-driven test ever sets it otherwise, so
for 126 phases of this project's history the caches were fully built (Phase 6) but
never once run with caching actually enabled. `tb/cache_tb.sv` (Phase 127 onward) is
the only place in the project that turns them on. See `plan.md` Phases 127-137 for the
full phase-by-phase history this document summarizes.

## Where the caches live

There is no top-level `m68030_cache` module. Each cache is its own controller living
*inside* `m68030_biu`:

- **I-cache**: `rtl/biu_icache_if.sv`, interposed directly between `m68030_ifu`'s
  existing longword-fetch port and `biu_cycle_gen`'s existing `ifu_*` port — same
  protocol on both sides, a drop-in insertion (Phase 127).
- **D-cache**: lives inside `rtl/biu_cache_if.sv`, on the EU-facing side. This module
  also contains a *second*, unused I-cache-shaped array — see "A dead code note"
  below before assuming `eu_is_icache` does anything.

Both are **direct-mapped, 16 lines × 4 longwords (256 bytes)**, matching the
architecture spec. Both default to disabled at reset and are only ever enabled by
software writing `CACR` via `MOVEC`.

### CACR/CAAR bit map (as implemented)

| Bit | Name | Meaning |
|---|---|---|
| 0 | IE | I-cache enable |
| 2 | CEI | Clear I-cache Entry (the line at `CAAR[7:4]`) |
| 3 | CI | Clear I-cache (all 16 lines) |
| 4 | IBE | I-cache Burst Enable (selects burst vs. ordinary pin protocol on a miss — does **not** gate whether the cache fills at all, see below) |
| 9 | DE | D-cache enable |
| 11 | CED | Clear D-cache Entry (the line at `CAAR[7:4]`) |
| 12 | CD | Clear D-cache (all 16 lines) |

`CAAR[7:4]` selects the line index for both `CEI` and `CED` — shared between the two
caches, matching real 68030 hardware.

## I-cache (`biu_icache_if.sv`)

**Disabled (`IE=0`)**: pure combinational bypass, zero added latency — byte-for-byte
identical to the direct-to-`biu_cycle_gen` wiring every regression test ran on before
Phase 127 existed.

**Hit**: served straight from the cache array, zero bus cycles.

**Miss**: a genuine `SIZ=11` pin-level 4-beat burst (`ic_burst_req`/`ic_burst_addr`,
muxed by `m68030_biu.sv` into `biu_cycle_gen`'s own `eu_burst_req` port) with a real
CBREQ#/CBACK# handshake. If the peripheral asserts CBACK#, all 4 words of the line
arrive in one burst; if not, the request degrades to 4 individual single-beat
re-requests (`IC_FILL_1B`/`2B`/`3B` states) — matching real 68030 hardware's own
fallback behavior. The burst mechanism itself (`biu_burst_ctrl.sv`,
`biu_cycle_gen.sv`'s `ST_BURST_*` states) has existed and been unit-tested since
Phase 7 via `tb/biu_tb.sv`'s own direct `eu_burst_req` cases — the I-cache is simply
the first real, integrated *consumer* of it (Phase 136, closing the cache-verification
plan's own Step 8).

**IBE's actual role**: a line is marked valid on any fill regardless of `IBE` — `IBE`
only selects *which pin protocol* a miss uses (burst vs. an earlier ordinary-read
placeholder used in Steps 1-7), never whether the cache fills at all. This is
deliberately asymmetric with the D-cache side's own IBE-gated behavior — see the next
section.

**Flush**: `CI` (global) and `CEI` (index-selective via `CAAR[7:4]`), both level-
sensitive while held — a write asserting the bit followed immediately by a write
clearing it back is enough to invalidate.

## D-cache (`biu_cache_if.sv`, EU-facing side)

**Miss**: unlike the I-cache's 4-word burst, a D-cache miss fetches and fills **only
the one word offset actually requested** — a real, aligned-longword bus read, with
`extract_rd()` slicing out the CPU's own requested byte/word/longword afterward. This
matches real 68030 hardware's documented single-longword D-cache fill behavior.

**Valid bits are per-word, not per-line** (`valid_d[16][4]`, not `valid_d[16]`) — a
genuine bug found empirically in Phase 133: a same-line, different-offset D-cache read
returned uninitialized garbage reported as a cache **hit**, because the old per-line
valid bit marked the *entire* line valid after a miss that had only ever fetched one
of its four words.

**Write-through, with correct cache update on a hit**: every write goes to the bus
unconditionally (never write-back); if the write also hits, `merge_wr()` repositions
the write into the correct byte lane of the cached slot so the cache's own copy stays
current too (avoiding an extra bus cycle on the next read of that same word). Before
Phase 134, the cache-update path wrote the CPU's own top-justified write data directly
into the slot regardless of size/alignment, corrupting neighboring bytes on any
sub-longword or misaligned write.

**Misaligned longword accesses are excluded from the cache entirely** (`d_size_ok`
gate, Phase 134) — a genuinely misaligned longword access (e.g. `RTR`'s own PC-pop
from `SP+2`) spans two cache slots, which this single-slot-per-word model can't
represent; rather than mis-cache it, these fall back to the disabled-cache passthrough
fetch.

**Flush**: `CD` (global) and `CED` (index-selective via `CAAR[7:4]`), same
level-sensitive shape as the I-cache's `CI`/`CEI`.

### A dead-code note: `eu_is_icache`

`biu_cache_if.sv` also contains a *second*, full I-cache-shaped array
(`valid_i`/`tag_i`/`data_i`) and an `eu_is_icache` select input, gating an EU-facing
I-cache access path distinct from the D-cache path described above. **This path is
never live**: `m68030_top.sv` hardwires `eu_is_icache` to `1'b0` permanently. Only the
IFU's own, separate array in `biu_icache_if.sv` is ever exercised — the EU (data
path) has no architectural reason to fetch through the instruction cache on real
68030 silicon either. Worth knowing if you're reading this file cold: there are two
identically-shaped I-cache storage arrays in the RTL, and only one of them does
anything.

## Arbitration (both caches)

`biu_arbiter.sv`'s fixed priority order — **MMU > EU > IFU > external DMA** — is
unchanged by either cache; a cache miss is just another bus request competing under
the same rules as an uncached access.

**Two real bugs found integrating the I-cache's genuine burst mechanism (Phase 136,
closing the cache plan's Step 8)**, both invisible until this phase made bursting a
real, concurrent participant in the integrated chip for the first time:

1. `ic_burst_req` initially bypassed `biu_arbiter.sv` entirely, muxed into
   `biu_cycle_gen`'s own `eu_burst_req` port *above* `grant_eu`/`grant_ifu` in its
   idle-priority chain — letting a burst unconditionally win the bus over a
   simultaneously-pending, *higher-priority* ordinary EU access. Found via direct
   `mem_req`/`mem_ack` tracing on a JSR/RTS test that hung after a stack push
   silently lost the arbitration race. Fixed by routing `ic_burst_req` through
   `biu_arbiter.sv`'s own `ifu_req` input (`ic_cg_req | ic_burst_req`), gated on
   `grant_ifu` like any other IFU request.
2. `biu_cycle_gen.sv`'s unified `SP_S7` completion `case` (shared across every cycle
   type) had no exclusion for `is_burst` — a burst's own S7, landing while the
   arbiter's own `grant_eu` was stale-registered `1` from an unrelated,
   already-completed transaction, fell through into the *ordinary* `eu_ack` path and
   handed back `captured_rdata` from a completely different, earlier access, silently
   corrupting a D-cache miss-fill. Fixed with an explicit no-op arm for `is_burst`
   (burst completion is already handled entirely separately, via
   `biu_burst_ctrl.sv`'s own `eu_burst_ack`).

## Two IFU-integration timing bugs (Phase 127's Step 1 wiring)

Both invisible until `biu_icache_if.sv` made the IFU's own fetch port a genuinely
different kind of client than it had ever had before:

1. **Combinational-loop hazard** (Phase 128): `biu_icache_if.sv`'s `cg_req`/`cg_addr`
   outputs were first driven purely combinationally, mirroring `biu_cache_if.sv`'s own
   style — but the EU-facing path has always gone through `biu_sizing_fsm.sv` first,
   whose own header comment explains it exists specifically to register that
   interface and break a combinational loop with `biu_cycle_gen`. The raw `ifu_*` port
   this module attaches to had never needed that protection before, since the native
   IFU always drove it from an already-registered signal. Fixed by registering
   `cg_req_r`/`cg_addr_r` one cycle later, matching `biu_sizing_fsm.sv`'s own pattern.
2. **Flush-mid-fill data corruption** (Phase 129), more serious — silently wrong data,
   not a hang: `biu_icache_if.sv` had no awareness of `pc_wr_en` (the IFU's own flush
   signal). The native IFU protocol is safe against a flush arriving mid-fetch by
   construction (`fetch_pend_r` clears immediately, so a stale ack can only ever
   arrive *before* it re-arms) — but this module's own `ifu_ack` sits low for the
   *entire* multi-cycle fill instead of a brief native-style pulse, so the IFU's own
   re-arm condition could fire, and a *new* fetch begin, before the *stale* one
   finished — handing the new requester data from an address it never asked for.
   Found via a direct-mapped aliasing test (two lines sharing one cache index,
   visited via JSR/RTS) where one subroutine's own code silently failed to execute;
   traced to `q[0]` holding an unrelated, already-retired earlier fetch's opcode.
   Fixed with `same_req` (checks the *live* `ifu_addr` still matches the in-flight
   fill's own latched address) and a sticky `abandoned_r` flag — the fill is still
   allowed to complete and update the cache array (harmless, and matches real
   hardware's own inability to abort an in-flight bus cycle), but a requester who's
   moved on no longer receives its result.

## Test coverage — `tb/cache_tb.sv`

Unlike every other `tb/*_tb.sv` file in this project, `cache_tb.sv` *does* use taken
backward branches (`DBF` loops, `JMP`) — re-executing the same code to observe a
cache hit is the entire point, which the project's usual "pure NOP-fall-through, no
backward branches" convention can't exercise at all.

| Test | What it checks |
|---|---|
| **I-1** | I-cache miss/hit: a tight `DBF` self-loop across 20 passes — real bus activity warming up, then zero further activity once the touched line(s) are cached |
| **I-2** | Aliasing/eviction: two lines sharing one cache index, visited via `JSR`/`RTS` in a pattern that forces eviction both directions — each hit/miss transition also verified to load the *correct* value, not just "did it unstick" |
| **I-3** | `CACR.CI`/`CEI` flush: `CI` misses both of two lines at different indices; `CEI` targeted at one index misses only that line, confirmed via direct internal-state reads (`valid_i`/`tag_i`) rather than a bus-activity proxy, after a Phase 130 fix found the original two test lines had accidentally aliased to the *same* index |
| **I-4** | Self-modifying code: the CPU itself overwrites its own cached immediate operand; a re-visit with no flush still sees the stale cached value (backing memory independently confirmed already holds the new value), a `CACR.CI` flush then makes it visible — the real 68030's documented no-automatic-I/D-coherency contract, end to end |
| **I-5** | BERR mid-linefill: a sustained bus fault injected on the first beat of a real cold miss — vector-2 dispatch reached, handler runs, `eu_busy` recovers cleanly (no lingering hang) |
| **T-1 / T-2** | Exact bus-cycle counts: a cold miss costs exactly 4 (one full burst), a hit costs exactly 0 — measured via a per-index bus-cycle counter immune to unrelated IFU readahead landing on a different line mid-test |
| **T-3** | Macro timing: the same 40-pass loop with the cache disabled vs. enabled — enabled is measurably faster (~3.3× in the specific loop shape tested) |
| **D-1** | D-cache miss/hit: single-word-granularity fill, confirmed a same-line *different-offset* read loads the correct value (not the Phase 133 stale-valid-bit bug) and a same-offset revisit costs exactly 0 bus cycles |
| **D-2** | Aliasing/eviction, same shape as I-2 but for the D-cache |
| **D-3** | `CACR.CD`/`CED` flush, same shape as I-3 |
| **D-4a / D-4b** | Write-through: a write-to-a-hit updates the cache (a following read costs 0 bus cycles) and still costs its own mandatory write bus cycle; a write-to-a-miss doesn't allocate (a following read still needs a real bus cycle) |
| **D-5a / D-5b** | BERR mid-read and mid-write: the faulted access never commits (register/backing-memory unchanged, fault wins the race) |
| **D-6** | Self-contained regression for an anomaly flagged in Phase 133 (`JMP (An)` immediately after exception dispatch appeared to corrupt state) — Phase 137 rebuilt the exact mechanism standalone and could not reproduce it on either current RTL or the pre-Phase-134 revision; concluded to be a testbench-construction artifact in the original draft, not a real RTL race. This test is the permanent regression coverage for that conclusion, not a currently-open bug |

**Result**: `tb/cache_tb.sv` 0 failures, 46 checks total (Phase 137). `RAW-hazard-with-Ihit`
(`tb/stall_fsm_tb.sv`, Phase 135) is the one cache-composition test that lives outside
this file — see `docs/stalls.md`'s Category A row — because it needed
`stall_fsm_tb.sv`'s own `claim_park()`/NOP-fall-through machinery, which
`cache_tb.sv`'s own backward-branch-heavy program structure doesn't have room for.

## Combined 4-config regression (Step 6)

Every RTL change with pipeline- or cache-wide reach gets re-verified across all four
`CACR` configurations — baseline (both disabled), I-cache-only, D-cache-only, both
enabled — via `gen_harte_hex.py`'s `HARTE_CACR` env-var override, which injects a
`MOVEC D7,CACR` into each test's own init code. Current results: baseline
`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`; all three enabled configs
`PASS 702134 FAIL 2 SKIP 281229 TIMEOUT 0` — the 8-test PASS→SKIP delta is a fixed,
identical-across-all-three-configs cost of widening `INIT_CODE_END` to fit the
`MOVEC`, not cache-specific; `FAIL=2` is the same documented `ASL.b` corpus anomaly in
every configuration; zero `TIMEOUT` anywhere.

**This sweep found three real pipeline hazards, none of them cache-specific bugs** —
the I-cache's shorter, more variable fetch latency was simply the first thing in 133
prior phases to expose timing windows that had always existed. Documented in
`docs/stalls.md` as Categories J (internal exception dispatch stall) and K (STOP
SR-write collision); the third was the D-cache byte-lane/alignment trio described
above (per-word valid bits, `merge_wr()`, `d_size_ok`).

## Later additions: the 8-stage cache-correctness plan (Phase 158, `plan.md` §Phase 158
## Stages 1-8) — not yet folded into the sections above

Everything above this point in the document was written covering Phases 127-137 and
never revised afterward. A separate, later 8-stage plan (Phase 158, closed in full)
found and fixed 6 real, previously-undiscovered gaps against a direct re-read of
MC68030UM.pdf Section 6 — summarized here rather than woven into the (now slightly
outdated) narrative above, to avoid rewriting sections that are otherwise still
accurate:

1. **CACR bit-position fix** (Stage 1): every D-cache CACR bit in `biu_cache_if.sv` was
   wrong (`ED` read from the `FD`/freeze bit's own position, `CD`/`CED` read from the
   wrong positions too) — software setting `ED` the textbook-correct way got a D-cache
   that silently never activated. The I-cache's own bits were already correct. Fixed;
   `tb/cache_tb.sv`'s own D-cache tests (self-consistently validating the same wrong
   bits) needed matching literal updates.
2. **Function-code bits added to both cache tags** (Stage 2) — neither tag included FC
   before this, so a supervisor and user access to the same logical address could alias
   onto the same line. Also found, documented, **not** fixed: ordinary instruction
   fetches hardcode FC=110 (supervisor) regardless of the real S-bit, limiting the new
   I-cache tag bit's practical effect until that's fixed too (**this was later fixed
   separately** — see "instruction-fetch FC hardcoding" below).
3. **RMW read forced-miss** (Stage 3) — the manual requires a locked RMW's own read
   phase to always miss the D-cache lookup (still populating the cache afterward);
   this RTL had no such gate.
4. **IBE/WA/DBE** (Stage 4, three sub-stages) — I-cache burst-enable gating was
   previously backwards (a comment claiming IBE only selected the pin protocol,
   contradicting the manual's "must not assert CBREQ# when burst filling is not
   enabled"); write-allocate (`WA`, CACR bit 13) was a pure no-op; and — **the item
   most relevant to the stale claim this section replaces** — **D-cache burst-mode
   fill (DBE, CACR bit 12) was added from scratch** (Stage 4c): a burst-capable
   read-miss, with `DBE` set and the D-cache enabled, now fills and validates the
   *entire* line via a genuine `CBREQ#`/`CBACK#` handshake (`dc_burst_req`/
   `CI_D_BURST0`/`CI_D_FILL_1B..3B` in `biu_cache_if.sv`), mirroring the I-cache's own
   mechanism (Phase 136) exactly. **The "D-cache burst is intentionally unimplemented"
   claim that used to be the first bullet in this section was true when originally
   written (Phases 127-137) and is no longer true — DBE-gated D-cache burst fill has
   existed since Phase 158 Stage 4c.**
5. **Freeze (FD/FI)** (Stage 5) — a miss under `FD`/`FI` no longer replaces the indexed
   entry; a D-cache write-*hit* under `FD` still correctly updates (the manual's own
   explicit exception).
6. **CACR self-clearing-bit readback masking** (Stage 6) — `MOVEC CACR,Dn` no longer
   echoes back the momentary `1` software last wrote into `CD`/`CED`/`CI`/`CEI` (always
   reads 0 per the manual), plus reserved bits masked to 0.
7. **CIIN/CIOUT pins** (Stage 7) — neither pin existed anywhere in the RTL before this
   stage; both added (`ciin_n` async input, `ciout_n` computed output on the D-cache
   side). Largest blast radius of any stage in this plan (touches every testbench that
   instantiates `m68030_top` directly) — verified inert wherever left tied off, since no
   dedicated CIIN-asserted test exists yet.
8. **BERR-during-fill entry-invalidation investigation** (Stage 8) — confirmed real via
   direct tracing (every beat's own BERR unconditionally faults the whole fill,
   regardless of which beat failed, diverging from the manual's "only the actually-
   requested word's own beat should fault") but not fixed in Phase 158 itself — the fix
   needed a genuine per-beat discrimination mechanism the burst controller didn't yet
   expose. **Partially fixed later**: `deferred-items closure plan Stage 9` (`plan.md`
   §Phase 217) added `burst_beat_at_berr` to `biu_burst_ctrl.sv` and used it in both
   cache-if modules to resolve the "beat is *after* the requested word" sub-case
   cleanly (the requested word's data was already captured in an earlier successful
   beat — no fault needed, mark only the words that genuinely arrived valid). The harder
   "beat is *at or before* the requested word" sub-case still needs a genuine retry
   mechanism and remains open — see the next section.

Every stage passed the full mandatory gate (`make test`/`cosim_grp`/`cosim_memind`/full
124-suite Harte sweep, bit-identical to baseline at every RTL-touching stage — Harte
never sets `TC.E=1` or enables either cache, so none of this plan's own work was ever
exercised by the Harte corpus itself; `tb/cache_tb.sv`/`tb/biu_tb.sv` are the real gates
throughout).

**Instruction-fetch FC hardcoding** (flagged as an open blocker by Stage 2 above): fixed
separately by the open-items backlog's own Stage 8 (`plan.md` §Phase 193) — real S-bit
now threads through `biu_cycle_gen.sv`'s instruction-fetch dispatch, `m68030_biu.sv`'s
`biu_icache_if` instantiation, and the icache-burst-fallback FC mux (three previously-
hardcoded sites, not just one). Confirmed functionally inert for the entire Harte corpus
(Harte never sets `TC.E=1` or enables the I-cache), as predicted before implementing it.

## What's left, if anything

- **BERR-during-fill, the harder sub-case** (Stage 8 above): a beat failing *at or
  before* the actually-requested word still unconditionally faults the whole fill —
  real hardware would, in principle, need a genuine retry there. Confirmed real,
  deliberately not attempted — this sits directly on top of the extensively-hardened
  BERR-abort machinery from Phases 108-114, and this project has consistently avoided
  touching that machinery without overwhelming justification.
- A related possible improvement, never pursued: **genuine per-beat CIIN checking
  during a burst** — this RTL currently checks CIIN once, for the whole line, at final
  burst completion (Stage 7 above), not per-beat as the manual's own text describes;
  would need reworking the beat-tracking mechanism itself.
- **`mmu_ci`** (used for `ciout_n`'s own computation, Stage 7) is fed from the
  EXT/PTEST port, not the real, live, per-access MMU translation CI result — flagged
  since the Phase 150-era MMU work as "threaded through but not yet acted on"; wiring
  it into real cache-inhibit behavior is a separate, deeper MMU-integration item.
- A full MOVES-based D-cache FC-aliasing test was attempted once (predating Phase 158)
  and caused an unexplained timing sensitivity elsewhere in `tb/cache_tb.sv` when
  inserted mid-sequence — **root-caused and closed** by the open-items backlog's own
  Stage 1 (`plan.md` §Phase 215): a plain ROM-address-space collision between that
  test's own flowing accumulator and a fixed exception-handler block placed earlier in
  the file, not a simulation-timing race. A real FC-aliasing test now exists at an
  isolated address (D-13).
- Two dead-code items are documented above (the unused EU-side I-cache array in
  `biu_cache_if.sv`, gated by a permanently-0 `eu_is_icache`) rather than removed —
  harmless, and removing them is a cleanup task independent of cache *correctness*,
  out of scope for this document.
- The `JMP (An)`-after-exception-dispatch anomaly (Phase 133) was investigated and
  closed in Phase 137 (see D-6 above) — not an open item, listed here only so a
  future reader doesn't go looking for it as unresolved.

`tb/cache_tb.sv`'s own check count has grown considerably past the "46 checks total
(Phase 137)" figure quoted in the table above, via Phase 158's own 8 stages and the
open-items backlog's own Stage 1 — no single up-to-date count is maintained here; run
`make test` for the current pass/fail state of the `cache` suite. **No known
correctness gap remains in either cache except the one item above** (BERR-during-fill's
harder sub-case), which is confirmed real but deliberately deferred, not overlooked.

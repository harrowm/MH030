# MH030-P architecture and the path to 100 MHz

This document exists because the Fmax programme (see `plan.md`'s own dated
sections) had started re-deriving things a prior session already measured,
and one stale claim (`eu_bitfield` as an untried candidate) nearly got
re-attempted after it had already been built, measured, and found not to
pay off. This is the consolidated, current-as-of-2026-10-04 picture: what
`rtlp/` actually is, what has been measured, what worked, what didn't, and
a concrete staged plan for the real target. It does not replace `plan.md`'s
own session-by-session history — that remains the record of *how* each
number was reached — but it is where to start before proposing a new Fmax
change, so the next session spends its time on something genuinely
unexplored.

**The target, stated plainly up front**: 100 MHz `clk_4x` is not a stretch
goal. §2 works out why: it is the clock rate this design needs just to
match the *slowest* 68030 Motorola ever shipped (25 MHz external bus). That
is the real bar, not an aspirational one, and it is well above anything
measured so far.

## 1. What `rtlp/` is, and why it exists

`rtl/` is a cycle-accurate MC68030 model: pin-exact, verified against the
real manual over ~280 phases, and it works — but its one combinational
decode/execute cone cannot be pipelined without a rewrite, and it measures
~13.6-14.2 MHz `clk_4x` on a real ECP5-85K. `rtlp/` is a parallel,
from-scratch pipelined core built to answer one question: what Fmax does a
genuinely staged design reach, with `rtl/` kept frozen and green as the
golden reference. Four scope decisions were made before any RTL was
written (see `project_mh030_pipelined_rewrite_planning.md`):

1. **Bus fidelity: protocol-exact, timing-free.** Every pin, every S-state,
   every stagger stays exactly as the manual specifies; the *spacing
   between* bus cycles may differ. This is the one signed-off divergence.
2. **A parallel core**, not an in-place rewrite — `rtl/` stays the oracle.
3. **Target 25-50 MHz `clk_4x`.** This was the original band approved
   before the clock-rate/real-chip-speed relationship (§2) was spelled out
   explicitly anywhere. Converted to real terms (§2), even the TOP of that
   band (50 MHz `clk_4x` → 12.5 MHz bus-equivalent) is still below the
   slowest real 68030. **This document corrects that framing**: the actual
   requirement is 100 MHz `clk_4x` (§2), and that is now the standing
   target, not a later or optional stretch goal.
4. **Integer core first**, MMU/caches staged in later.

Two configurations share everything above the bus:

| top module | what's underneath | measured role |
|---|---|---|
| `mh030p_top` | `mh030p_arb` — a single-tick abstract bus | what every rtlp-only gate/testbench drives; the pipeline was built and tuned against this |
| `mh030p_biu_top` | `rtl/m68030_biu` — the real, verified BIU, real pins, real S-states, DSACK, bursts, both genuine 68030 caches | "plan A4" — the configuration that actually matters for a real FPGA build, and the one every number in this document means unless stated otherwise |

Both instantiate the identical `mh030p_cpu` (fetch unit + core + the peek
decoder, see §4) — nothing above the bus differs between them.

## 2. Clock convention: `clk_4x` vs. a real chip's rated speed

Every Fmax number this project has ever quoted — 24.71 MHz, 27.36 MHz,
27.25 MHz, the "100 MHz" figure itself — is a **`clk_4x`** number: the
*internal* clock, run at 4× the external bus frequency, per this project's
own standing clock strategy (`CLAUDE.md`'s "Design Constraints" section —
"Run the Verilog design at 4× the external bus frequency... This gives 4
clean ticks per external clock cycle"). This convention is baked into the
reused BIU (`m68030_biu` and everything under it), and the A4 configuration
drives that BIU directly, so for `mh030p_biu_top` the conversion is exact
and unconditional: **divide `clk_4x` by 4 to get the number directly
comparable to a real 68030's datasheet speed grade.** (The abstract-bus
`mh030p_top` config has no real external bus at all — there is nothing to
convert there; it's a different measurement for a different purpose, see
§6.)

| | `clk_4x` | ÷4 = real-bus-equivalent |
|---|---|---|
| `rtl/` reference core, real FPGA measurement | ~13.6-14.2 MHz | ~3.4-3.6 MHz |
| `rtlp/` A4, current (this session) | 27.25 MHz | **~6.8 MHz** |
| Real MC68030, slowest production part | — | **16 MHz** |
| Real MC68030, common mid-range parts | — | 20, 25 MHz |
| Real MC68030, fastest production parts | — | 33, 40, 50 MHz |
| **This project's real target: match the slowest real chip** | **100 MHz** | **25 MHz** |

So: matching the *slowest 68030 Motorola ever sold* needs **100 MHz
`clk_4x`**, not 50. The current build, at 27.25 MHz `clk_4x` (~6.8 MHz
bus-equivalent), is roughly **3.7x** short of that, and it is already
slower in real terms than the slowest real chip by more than 2x.

One honest mitigating factor, not a reason to discount the gap: `rtlp/` is
genuinely pipelined and does more useful work per bus cycle than `rtl/`
does once caches are on (fewer idle ticks between transactions — see
`make bench`'s own tick counts in `plan.md`). So "6.8 MHz bus-equivalent"
slightly understates real throughput versus a naive clock-for-clock
comparison. It does not change the answer to "what clock does this chip
run at," which is the question §2's table answers directly, and which is
the number that matters for "is this as fast as a real 25 MHz 68030."

## 3. Module hierarchy

```
mh030p_top (abstract bus)  /  mh030p_biu_top (A4, real BIU)
└── mh030p_cpu
    ├── mh030p_decode  (u_peek)   -- ext_words only, see §4.2
    ├── mh030p_ifu     (u_ifu)    -- 8-word prefetch queue, redirect/epoch handling
    └── mh030p_core    (u_core)
        ├── mh030p_decode (u_dec) -- the real decoder, ID stage
        ├── mh030p_regfile (u_rf) -- 4 read ports, 3 write ports, §5
        ├── eu_alu        -- reused from rtl/ verbatim, combinational
        ├── mh030p_shift  -- SEQUENTIAL (rewritten from rtl/eu_shifter.sv)
        ├── eu_mul_div    -- reused from rtl/ (MUL_ENABLE=0 here)
        ├── mh030p_mul    -- this core's own multiplier (uses the DSPs)
        ├── eu_bitfield   -- reused from rtl/ verbatim, combinational
        ├── eu_bitops, eu_bcd -- reused from rtl/ verbatim
        └── (standalone sequencer FSMs: MOVEM, MOVEP, CAS/RMW, exceptions,
             RTE/RTR, the AG/EX EA-adder dispatch branch — all inside
             mh030p_core's own always_ff blocks, not separate modules)
mh030p_arb       -- abstract-bus-only arbiter (fetch vs data, data wins)
```

`mh030p_bitfield.sv` exists in the tree and is **not instantiated anywhere**
— it's a finished, proven-equivalent (50,688-vector sweep) sequential
bit-field unit that was measured and found not to pay off. See §6.3.

## 4. Pipeline: four stages, each a real register boundary

```
ID    decode (combinational) -> registered uop; regfile addresses issued
AG    register data arrives (the read was a clock boundary, not a cone);
      the effective address is computed on its own adder; a memory
      request is issued FROM REGISTERS
EX    memory data has arrived (or the stage stalls until it has);
      forwarding mux; ALU/shifter/mul/div; result registered
WB    commit to the register file and the CCR
```

This is the entire point of the rewrite, contrasted directly with `rtl/`:
register reads are **registered**, not combinational; decode output is
**registered**, not fed straight into execute (`rtl/eu_seq_decode.svh` is
one ~6,200-line `always_comb` driving EX in the same tick); and there is no
zero-gap/`preview_ok` dispatch mechanism, so no 17-way ack-dependent mux
sitting in the middle of the longest path.

### 4.1 The AG/EX split (2026-10-04, `~/.claude/plans/golden-puzzling-music.md`)

Originally AG did three things in one cycle: the forwarding mux, the EA
adder, and the `mem_addr`/mem-field dispatch mux. The EA adder and dispatch
mux were moved into a new, one-shot-gated EX cycle (`ea_done`/`ex_wait_ea`),
reading `ex_b`/`ex_sp`/`ex_a`/`ex_pc2` — registers the AG→EX transfer
already carries unconditionally, so the forwarding network stayed 2-level
rather than needing to grow a third level. This closed a real,
independently-discovered bug along the way: the register file's single
first write port was multiplexing `ag_an_upd` (AG's same-cycle
autoincrement commit) against the ordinary WB/MOVEM/exception commits by
priority, silently dropping whichever lost — real whenever a retiring
register-only instruction (`moveq #0,d1`) was immediately followed by a
post/pre-incrementing memory instruction. Fixed with a genuine, dedicated
third write port (see §5).

**In hindsight, measured against §8's priority order below, this was done
out of the recommended sequence.** It is "Stage 3" work (core-side cone
splitting) in the staged plan §8 presents, and that plan explicitly demotes
Stage 3 below Stages 1/2 because the BIU and the decoder chain bind first —
which is exactly what happened: the split measured flat (27.36→27.25 MHz,
within noise) because it didn't touch the cone that was actually dominant
(§4.2). The work itself is sound and the bug fix was real and necessary;
the lesson is to re-profile and confirm what's dominant *before* choosing
which stage to attack next, not after.

### 4.2 The two-decoder problem — the single biggest structural finding in this file

`mh030p_cpu.sv` instantiates **two** full `mh030p_decode` instances:

- `u_peek`, fed the raw opcode the instant it's offered, whose only
  consumed output is `ext_words_fast_full_o` — how many extension words
  this opcode needs, which the fetch unit must know before it can tell
  `u_core`'s own decoder (`u_dec`) how many words are even available.
- `u_core.u_dec`, the real ID-stage decoder, fed `ext` — which is itself a
  mux *driven by* `u_peek`'s own output (`ext_words == 1 ? low-half : both
  halves`, `mh030p_ifu.sv`).

So the chain is **q[0] → peek decode → ext mux → full decode → regfile
select**, two decoder passes in one clock. `ext_raw` (the un-normalised
words) exists so `u_peek` itself doesn't depend on the mux it drives — that
would be a genuine combinational loop — but it never addressed `u_dec`'s
own dependence on `u_peek`'s output, which is the real serial pass.

**This was investigated in full once already** (plan.md's "Stage 1
investigation" section, 2026-09-28). An isolated probe (`tb/extw_probe.sv`,
`make fmax-extw`) proved the depth is real, not a `-noflatten`-DCE artifact
(driving the probe from progressively smaller sub-expressions found the
cost is diffuse across EA-mode/immediate-sizing *arithmetic*, not the
~25-arm priority chain everyone assumed — a balanced `case` recovers only
~4 ns of the ~24 ns). The investigation's own conclusion was blunt about
scope:

> What Stage 1 actually requires is not a patch. To remove the serial pass
> the core's decoder must normalise `ext` itself from `ext_raw`... Done
> properly it pays twice: `u_peek` can then be deleted outright... That is
> a real refactor of the most intricate file in `rtlp/`... it is the right
> Stage 1, but it is not the cheap one this plan assumed.

So the session that followed (the one actually called "Stage 1" in
`CLAUDE.md`) deliberately did the **cheaper** half instead: rewrite
`ext_words_fast_full_o` as an independent shallow decoder, straight from
raw opcode-bit wires, bit-exact-verified against the real decoder across
all 65,536 opcodes. That shipped (+10.7% design-wide, 24.71→27.36 MHz) and
was explicitly scoped from the start as *not* the full fix, and *not*
sufficient alone even if it worked perfectly — see §8.

**Both decoders still exist today, unmerged.** A `-noflatten` cross-check
this session (2026-10-04, after the AG/EX split) found `u_peek` is *still*
the single largest attributed cost in the A4 configuration's worst path
(~19 ns, ~45% of the total, consistent across 2 independent seeds) — not a
new regression, just the same already-quantified residual the 2026-09-28
investigation found and the Stage 1 session knowingly left in place. The
merge remains the correct, already-scoped, not-yet-built fix for this
specific structural cost — it is "Stage 1, part 2" in §8's plan.

## 5. Register file (`mh030p_regfile.sv`)

16×32, registered reads (the structural reason this core needs a
forwarding network at all — `rtl/eu_regfile.sv` reads combinationally,
which is the ~3600-hop chain this whole rewrite exists to avoid). Four
read ports (A/B/C/D — C and D exist specifically because an indexed EA at
both ends of a memory-to-memory MOVE needs base+index on each side at
once), write-first bypass (a read issued the same cycle as a write to the
same register sees the new value — needed because the read-to-use distance
is long enough that a 2-cycle-forwarding network alone would miss it for
an instruction 3 behind its producer).

**Three write ports**, not two, as of 2026-10-04:
- **Port 1** (`wr_en`/`wr_sel`/`wr_data`): the ordinary WB commit, plus
  MOVEM's register/base commits and the exception/reset frame-pointer
  commits, muxed by priority. These remain mutually exclusive by
  construction (verified, not assumed — see `plan.md`).
- **Port 2** (`wr2_en`/`wr2_sel`/`wr2_data`): EXG/LINK/UNLK's own dual
  commit, and a memory-to-memory MOVE's destination-side autoincrement.
  Port 1 wins a same-register conflict (UNLK A7 sets A7 then pops into it;
  the pop is architecturally the result).
- **Port 3** (`wr3_en`/`wr3_sel`/`wr3_data`, new): `ag_an_upd` alone — AG's
  own same-cycle address-register autoincrement/predecrement, now
  structurally unable to collide with anything else, since `ag_base_busy`
  already interlocks AG against both other ports' targets whenever AG
  needs a register `ag_an_upd` would also write.

Forwarding is **two levels** (`wb_*` = one instruction back, `wbp_*` = two
back), each level checked against both write ports' targets, following
directly from the registered-read design (worked out from first
principles in the module's own header: an instruction one behind its
producer sees the producer's commit from the *current* cycle's `wb_*`; an
instruction two behind needs the *previous* cycle's commit, since by the
time it reaches EX the current `wb_*` has already moved on).

## 6. Functional units: reuse vs. rebuild

The project's one proven Fmax lever — confirmed across every real win —
is **removing a large, always-evaluating combinational block from the
timing graph**, not restructuring one in place. Three units got this
treatment; two others were reused verbatim because the lever didn't pay
for them.

### 6.1 Sequential shifter (`mh030p_shift.sv`) — adopted

`rtl/eu_shifter.sv` is combinational, ~14 variable-distance barrel
shifters, 2,084 cells, re-evaluating every cycle regardless of whether the
current instruction is a shift. The replacement steps one bit per tick
with a single fixed 1-bit shifter, 220 cells, almost no new state.
**21.60 → 29.16 MHz.** The single largest proven win in this programme.

### 6.2 Sequential divider (inside `eu_mul_div`, `MUL_ENABLE=0` here)

Same shape, applied earlier (standalone-core era): one 32-bit
compare+subtract per tick, 32 ticks, replacing four independent
combinational dividers. **2.46 → 14.24 MHz (5.8x)**, the largest single
win in the whole project's history (predates the AG/EX/WB 4-stage design).
Multiply stays combinational, in its own module (`mh030p_mul.sv`), using
the ECP5 DSPs — `MUL_ENABLE=0` on the reused `eu_mul_div` instance prunes
its own combinational multiply arms so this core doesn't build multiply
hardware twice.

### 6.3 Sequential bit-field unit (`mh030p_bitfield.sv`) — **built, measured, NOT adopted**

The obvious next candidate of the same shape: `eu_bitfield` is
combinational, 1,459 cells, with five variable-distance shifters and a
32-deep find-first-one priority chain with a 32-bit subtract per level.
A sequential replacement was built, proven bit-exact (50,688-vector sweep,
`tb/bf_equiv_tb.sv`, permanently in `make test`), and measured:

| arm | mean (9 seeds) | min | max | bitfield comb cells |
|---|---|---|---|---|
| combinational `eu_bitfield` (current) | **29.16** | 28.39 | 30.14 | 1,459 |
| `mh030p_bitfield` (not instantiated) | 28.29 | 27.26 | 29.38 | 845 (+324 FF) |

Overlapping ranges, 7 of 9 seeds lower, mean 0.87 MHz down —
**unresolved, leaning negative**. The reason it failed where the shifter
succeeded is the transferable lesson: the shifter went 2,084→220 cells
with almost no new state; this one goes 1,459→845 **and adds 324 flip-flops**
(nine 32-bit registers) while still leaving a combinational output mux
computing `~pmask`/`^pmask`/`|pmask`/the FFO arithmetic, now fed from those
registers. Removing a variable shifter only wins if the depth isn't spent
again on the way out. **Do not re-attempt this without a version that
keeps materially less state** — that's the module's own documented
condition for revisiting it, not a vague "try harder."

### 6.4 `eu_alu`, `eu_bitops`, `eu_bcd` — reused verbatim, correctly

592, ~0 (folded into bitops path), and 117 combinational cells
respectively. Too small to matter, and `eu_alu` in particular "genuinely
must be single-cycle" (plan.md's own phrasing) — there's no always-
evaluating waste to remove.

### 6.5 Register-file / prefetch-queue area packing — tried, reverted, not a speed lever

A separate effort (write-first bypass redundancy removal on ports C/D,
serialising EXG/LINK/UNLK through one write port, a head-pointer circular
buffer for the prefetch queue instead of the current shift network) cut
**17.9% of the design's combinational cells** — and measured **1.67 MHz
slower**. Confirms cell count is not just a poor Fmax proxy here but an
*anti-correlated* one. Deliberately not adopted; recorded as "the right
change at the wrong time" — worth doing eventually for area headroom (an
FPU/MMU/caches campaign), never attempt it again as a speed fix.

The prefetch queue's own shift-vs-head-pointer question (`mh030p_ifu.sv`'s
own header) was investigated on its own terms too and left **unresolved**
in the same direction: a head-pointer version measured 21.80 MHz against a
baseline whose own 9-seed spread is 21.81-23.13 MHz — inside the noise
floor, not a measured regression, reverted because it showed no benefit
either, not because it was shown worse.

## 7. Current measured state (2026-10-04)

**Methodology note, binding for anything in this section and beyond**:
`fmax-pbiu-sweep` (flattened synthesis, 9 seeds) is the tracked metric.
ABC9 can and does attribute a merged cell to a totally unrelated module's
hierarchy (confirmed twice now: `mh030p_mul`'s DSPs named
`u_ifu.req_epoch_*`; and, this session, a flattened-sweep "worst path"
claim that named `biu_cache_if.sv` registers that direct source inspection
showed aren't even on that data path). **A flattened sweep's per-module
attribution — single-cell or the coarser "module walk" percentage style —
must be cross-checked with at least one `-noflatten` seed before it is
used to justify a new conclusion.** `-noflatten` itself is not perfectly
trustworthy either (weaker cross-module dead-code elimination can inflate
a mostly-unused module's own apparent weight — true of `u_peek`, see §4.2
— though in that specific case an independent isolated-probe measurement
already confirmed the depth is real, not inflated). See
`feedback_flattened_attribution_needs_noflatten_crosscheck.md`.

### 7.1 Fmax

- **A4 (`mh030p_biu_top`), flattened, tracked sweep, POST-Stage-1
  (2026-10-04, commit `e06c722`)**: **26.49 MHz `clk_4x` mean** (9 seeds,
  range 24.88-27.50) — **~6.6 MHz real-bus-equivalent** (§2) — flat to
  slightly down against the pre-Stage-1 27.25 MHz baseline, inside the
  documented ~1-2 MHz noise floor. **Stage 1 (merging the two decoder
  instances) did not move the tracked mean measurably.**
- **A4, `-noflatten`, POST-Stage-1 (2 seeds, cross-check, not the tracked
  metric)**: 23.57 MHz (seed 4) / 23.65 MHz (seed 1) — consistent across
  both seeds. **The worst path is no longer the two-decoder chain** (§4.2's
  `u_peek`/`u_dec` chain is gone, confirmed structurally and in this
  measurement). **It is now entirely internal to `u_cpu.u_core`**: `
  instr_ready` (the AG/EX stall-gating decision) → a detour through
  `u_core.u_alu` → back into `u_core`'s own logic → `mem_addr` (the
  registered bus-dispatch address), 65 hops, ~83-84% attributed to
  `u_core` itself. **This directly contradicts the 2026-09-28 plan's own
  prediction that the BIU's 27.78 MHz standalone ceiling would bind almost
  immediately after Stage 1** — it has not: the core itself is still the
  binding constraint, with real headroom below the BIU's own ceiling
  apparently unreachable without addressing this core-internal chain
  first. This is closer to Stage 3's own territory (core-side AG/EX/CCR
  pipelining) than Stage 2 (the BIU). See §8's own updated staging note.
- **A4, flattened, tracked sweep, POST-Stage-3-CAS-fix (2026-10-04, commit
  `e1404a2`)**: **27.45 MHz mean** (9 seeds: 26.65, 27.55, 27.70, 28.68,
  27.93, 27.90, 26.15, 28.50, 25.98; range 25.98-28.68) — up from the
  26.49 MHz pre-fix mean, and notably the WHOLE range shifted upward (old
  min 24.88 → new min 25.98), not just the mean — a real-looking
  improvement, though still within shouting distance of the documented
  ~1-2 MHz noise floor for this sweep.
- **A4, `-noflatten`, POST-Stage-3-CAS-fix (2 seeds, consistent: 26.40 MHz
  seed 4 / 25.98 MHz seed 1)**: **`u_core.u_alu` is confirmed GONE from the
  critical path** — the fix worked exactly as designed. The worst path is
  now `u_ifu.instr` → `u_core.u_dec` (21.82-22.61 ns, 57.6-58.7% of the
  total, 44-46 hops — the real decoder's own classification depth, with
  nothing else now stacked on top of it) → `u_core` → `u_core.u_rf.rd_a_data`.
  This is structurally the SAME shape of problem §4.2 already solved for
  the front decoder (`u_peek`) before the Stage 1 merge — a decoder being
  too deep — now showing up in the SOLE remaining decoder instance, once
  everything else that used to sit in front of or alongside it (the second
  decoder instance, then the ALU) has been removed. Not yet investigated;
  no probe built.
- **The reused BIU, standalone, no core at all** (`m68030_biu` alone):
  **27.78 MHz `clk_4x`** (1 seed, 2026-09-28, not yet re-measured this
  session). Still the eventual ceiling once the core-internal chain above
  is addressed, just not the CURRENT binding constraint — `u_dec`'s own
  ~22 ns is still well short of it.
- **Abstract-bus `mh030p_top`** (no real BIU, no caches — the config the
  pipeline itself was tuned against): 29.16 MHz with the sequential
  shifter; this is a different, smaller design than A4, has no real
  external bus to convert against, and is not directly comparable to the
  numbers above.
- **100 MHz `clk_4x` (25 MHz bus-equivalent, §2) is the real target and
  has not been met.** The current build is ~3.8x short of it.

### 7.2 Area (real, `-noflatten`, A4 configuration — `make area-pbiu`)

Per-module-*definition* combinational cell counts (not per-instance: a
module instantiated twice, like `mh030p_decode`, is counted once here —
double it for `mh030p_decode`'s true live cost, since both `u_peek` and
`u_core.u_dec` are real, simultaneously-present instances):

| module | comb cells | % | FF |
|---|---|---|---|
| `mh030p_core` | 9,632 | 19.6% | 1,507 |
| `mh030p_regfile` | 8,753 | 17.8% | 640 |
| `biu_mmu_if` (reused rtl/) | 6,893 | 14.0% | 2,591 |
| `biu_cache_if` (reused rtl/) | 5,733 | 11.6% | 948 |
| `biu_icache_if` (reused rtl/) | 4,010 | 8.1% | 819 |
| `mh030p_decode` (×2 live instances) | 3,430 each | 7.0% each | 0 |
| `biu_cycle_gen` (reused rtl/) | 2,595 | 5.3% | 515 |
| `mh030p_ifu` | 2,188 | 4.4% | 231 |
| `eu_bitfield` (reused rtl/) | 1,459 | 3.0% | 0 |
| `biu_sizing_fsm` (reused rtl/) | 965 | 2.0% | 140 |
| `eu_mul_div` (reused rtl/, `MUL_ENABLE=0`) | 710 | 1.4% | 173 |
| `eu_alu` (reused rtl/) | 592 | 1.2% | 0 |
| `mh030p_mul` | 310 | 0.6% | 167 |
| `mh030p_shift` | 206 | 0.4% | 54 |
| `eu_bcd` (reused rtl/) | 117 | 0.2% | 0 |

Two things worth noting that aren't, on their own, a call to action:

- **`mh030p_regfile` is nearly as large as the entire rest of the pipelined
  core.** This is *not* a fresh lever — §6.5 already tried shrinking it
  (packing the write-first bypass, serialising the second write port) and
  measured it Fmax-*negative*. Its size comes from four read ports each
  carrying a 16-way array select plus a 3-level write-port bypass check,
  not from waste.
- **The reused BIU interfaces (`biu_mmu_if`+`biu_cache_if`+`biu_icache_if`)
  are 33.7% of A4's own area combined**, larger than `mh030p_core` and
  `mh030p_regfile` together. §8 explains why this is now the central
  target, not a boundary to avoid.

## 8. The path to 100 MHz: an already-staged plan, partially executed

A full investigation on 2026-09-28 (`plan.md`'s "Measured baseline for the
100 MHz target" section) already answered "what would it take," in detail,
with real measurements. It was never finished — the session that did it
moved to other priorities (a correctness pass, then the AG/EX split) before
reaching its own Stage 2. Restated here as the current roadmap, with status
updated for everything that's happened since.

**The central fact as understood on 2026-09-28**: the reused BIU's own
standalone ceiling is **27.78 MHz `clk_4x`**, measured with no core
attached at all, and the pre-Stage-1 A4 design measured 27.25 MHz, within
2% of it — so the BIU was expected to bind almost immediately once the
core-side decoder cost was removed. **This has not held up.**

### Stage 1 — the decoder merge (§4.2) — DONE (2026-10-04, commit `e06c722`)

Implemented as scoped: `u_peek` deleted, `mh030p_decode` normalises `ext`
internally. Found and fixed two real, previously-latent decode bugs the
merge exposed (MOVES direction never checked; bit-field register field
read 4 bits instead of 3) — see §4.2 and the commit message. Full
verification gate clean (`make test` 43/43, Harte bit-identical, `make
bench` EXECCYCLES unchanged on all four arms).

**Measured result: 26.49 MHz mean (9 seeds), flat to slightly down versus
the 27.25 MHz pre-Stage-1 baseline — not the ~28 MHz the 2026-09-28
estimate predicted, and the reason is itself the important finding.** A
`-noflatten` cross-check (2 seeds, consistent) shows the two-decoder chain
is genuinely gone, exactly as designed — but **the BIU did NOT become the
new binding constraint**. The real worst path is entirely internal to
`u_cpu.u_core`: `instr_ready` (the AG/EX stall-gating decision) → a detour
through `u_core.u_alu` → `mem_addr` (the registered bus-dispatch address).
See §7.1 for the full measurement. **The 2026-09-28 plan's own sequencing
(decoder merge, then the BIU) was reasoned from the BEST EVIDENCE
AVAILABLE AT THE TIME, and that evidence has now been superseded by a
direct measurement** — the core's own stall/dispatch logic, not the BIU,
is what's currently binding, which points at Stage 3's own territory
(core-side AG/EX/CCR pipelining) rather than Stage 2.

### Stage 2 — fork the BIU into `rtlp/`, then cut `biu_cycle_gen`'s FSM depth

**The decision to do this was already taken on 2026-09-28**
(`project_mh030_pipelined_rewrite_planning.md`: "Fork the BIU into `rtlp/`.
`rtl/` stays frozen... BIU fixes will have to be applied twice; nothing
already verified is put at risk.") **but the work itself was never
started.** `rtlp/` today has only an *adapter* (`mh030p_biu_top.sv`) that
drives `rtl/`'s own `m68030_biu` unmodified — no forked copy exists yet.

**Why this does not require re-litigating scope decision 1** (bus
fidelity): `biu_cycle_gen` is "a ~100-state FSM whose next-state and
pin-output decode are wide and flat" (2.16:1 LUT:FF, not a deep cone) — the
candidate fixes are one-hot state encoding, registering pin outputs one
tick later, and splitting next-state decode by cycle type. **None of these
change which S-state asserts which pin, or how many S-states a cycle takes
— they change how fast the FSM decides, not what it decides.** A pin
registered one tick later than its triggering state, with the state
sequence itself unchanged, is still protocol-exact. This is a genuinely
different category of change from Stage 2b below.

**Status (2026-10-04): the fork itself is DONE** (`rtlp/mh030p_biu.sv` +
`rtlp/mh030p_biu_cycle_gen.sv`, verified behaviourally identical — `make
test` 43/43, `make bench` all four arms with `EXECCYCLES` byte-identical).
**The FSM depth restructuring is explicitly DEFERRED, by direct user
decision after seeing §7.1's own finding**: the BIU's own 27.78 MHz
standalone ceiling is already *above* the current full design's 26.49 MHz,
so restructuring `biu_cycle_gen` right now would spend real regression
risk on the most complex, protocol-critical file in the project for a
currently-unmeasurable payoff — the core, not the BIU, is what's binding.
**Re-ordered: Stage 3 (below) goes next, and this FSM work resumes once
Stage 3's own re-measurement confirms the BIU has actually become the
limiter**, rather than following the original 1→2→3 sequence literally
against evidence that it's not yet Stage 2's turn. The fork stays in place
either way — it's real, necessary, already-decided work (Stage 2b and any
future BIU-side fix depend on it existing), just not blocking Stage 3.

### Stage 2b — synchronous-termination (STERM) fast path — NEEDS EXPLICIT SIGN-OFF

Potentially the single biggest lever on the board, and different in kind
from Stage 2: **this one does spend the "protocol-exact, timing-free" bus
fidelity decision**, because it changes the real tick cost of a bus cycle
(the 68030's own STERM mechanism gives a synchronous 2-clock cycle instead
of the normal 3-clock asynchronous one). Measured motivation: a real bus
access currently costs ~14.3 ticks against a 12-tick protocol floor, and
231 transactions in the `make bench` workload consume 3,310 of 8,603 total
ticks — the bus protocol itself, not the clock or the decode chain, is the
single largest consumer of time in that benchmark. Cutting this toward the
protocol floor was estimated to take `bench2` from 8,603 to roughly 5,900
ticks (1.46x) *and compound with every clock-rate gain from Stages 1-2*.

**Given this session's reframing of 100 MHz as the required target, not a
stretch goal, this sign-off question needs to be asked directly rather than
left flagged indefinitely: do you want to spend the protocol-exact-timing
decision for this fast path?** It was deliberately left unspent through
three prior sessions that each had the chance to raise it. Saying yes here
unlocks the single largest estimated single-item win in this whole plan;
saying no caps the realistic ceiling at whatever Stages 1-2-3-4 reach on
protocol-timing alone (see §9).

### Stage 3 — core-internal critical paths — first fix DONE, next target identified

The original plan's own "split AG into address-mux-then-adder, split EX
into operand-select-then-ALU/shifter/BCD/bitfield" framing. The AG/EX
EA-adder split (§4.1) was a first instance, done earlier but measured
flat since it wasn't the dominant cost at the time. **The original plan
demoted this stage below Stage 2b on the assumption the BIU would already
be binding by this point — that assumption did not hold (§7.1), so this
stage was promoted ahead of Stage 2's FSM work instead**, by direct user
decision.

**First concrete fix: DONE and measured (2026-10-04, commit `e1404a2`).**
Direct `-noflatten` trace found `instr_ready` → a detour through `u_alu`
→ `mem_addr`, root-caused to `cas_eq = alu_z` (CAS's own live ALU-derived
compare result) feeding `cas_skip_wr`, which gates a branch of the SAME
shared `always_ff` that commits `mem_addr`/`mem_rw` for every
instruction's own dispatch — so the ALU's combinational depth was
bleeding into the critical path for instructions that aren't even CAS.
Fixed by latching the compare result one cycle after `mem_got`
(`cas_cmp_done_r`/`cas_eq_r`), mirroring this file's own existing
`trap_decided` and memory-form-shift `shf_busy` precedents exactly,
including the matching gate needed in the `rmw_wr_issued`/`rmw_done`
latch per an explicit prior-documented precedent about that exact failure
mode. New dedicated regression (`tests/cas_stage3.s`, `make
test-cas-stage3` — CAS has zero Harte coverage) confirms both match and
mismatch cases stay correct and shows the expected +1-tick-per-CAS cost.
Full gate clean (`make test` 43/43, `make lint-drivers` clean, Harte
bit-identical, `make bench` unchanged — CAS isn't used by bench1/bench2).

**Measured**: 26.49 → **27.45 MHz mean** (9 seeds, range shifted entirely
upward: 24.88-27.50 → 25.98-28.68). A `-noflatten` cross-check (2 seeds,
consistent) confirms `u_alu` is genuinely gone from the critical path —
the fix worked exactly as intended.

**Next target, identified not guessed**: with the ALU gone, the worst
path is now `u_ifu.instr` → `u_core.u_dec` (~22 ns, ~58% of the total,
44-46 hops, consistent across both `-noflatten` seeds) → `u_core.u_rf`.
This is structurally the identical shape of problem §4.2 already solved
once for the FRONT decoder (`u_peek`) — a decoder being too deep — now
exposed in the SOLE remaining decoder instance, once everything that used
to sit alongside it (the second decoder, then the ALU detour) has been
removed one layer at a time.

**Isolated and profiled (2026-10-04, `tb/udec_rdsel_probe.sv`, `make
fmax-udec-rdsel`)**: this cone — `u_dec`'s own classification through the
register file's `rd_a_sel` address mux (the exact chain the `-noflatten`
trace found, stopping just short of the regfile's own array read) —
measures **57.71 MHz (~17.3 ns) in isolation**, somewhat faster than the
~22 ns the full-design trace attributed to `u_dec`, consistent with real
fan-out/loading on `dec_uop`'s own many other consumers in the full
design rather than a `-noflatten` DCE artifact (the computation itself is
genuinely most of the cost). Driving the probe from progressively smaller
sub-expressions, the same technique that found `ext_words`' own real
cost:

| sub-expression | Fmax | ns |
|---|---|---|
| `uclass` alone | 149.37 MHz | ~6.7 |
| `dst_reg` alone | 103.86 MHz | ~9.6 |
| `src_reg` alone | 126.57 MHz | ~7.9 |
| **`ea_idx_reg` alone** | **53.44 MHz** | **~18.7** |
| full `rd_a_sel` mux | 57.71 MHz | ~17.3 |

**`ea_idx_reg` alone is nearly as expensive as the entire mux** — it
dominates. It traces to `sxw = xword(ea_slot_is_dst ? ew_dst_at :
ew_lead, ew_tot)` in `mh030p_decode.sv`: the SAME shape of cascading,
per-family extension-word-position arithmetic that made `ext_words`
itself expensive before Stage 1's shallow rewrite — not a priority-chain
inefficiency, real computed depth.

**Not yet fixed.** The analogous fix — a "shallow `ea_idx_reg`" shortcut
computed straight from raw opcode/extension-word bits in parallel with
classification, rather than through the cascading `ew_lead`/`ew_dst_at`/
`ew_tot` chain — is a comparable-scope undertaking to the entire
`ext_words_fast()` rewrite from Stage 1 (new independent logic, a
65,536-opcode equivalence sweep, bit-exact verification before swapping
in), not a quick patch. Flagged for explicit scoping and sign-off before
attempting, matching this project's own standing discipline for changes
of this size.

**Every further core-side split still costs ticks** (more pipeline stages
= more latency per instruction), so each one must be judged on
`Fmax / ticks` via `make bench` alongside every sweep, never on the clock
number alone.

### Stage 4 — routing locality

Deferred until after 1-3: the A4 worst path currently splits ~74-80%
routing / ~20-25% logic, but that's mostly a *symptom* of long combinational
chains giving the placer nothing local to work with, not an independent
problem. Revisit once Stages 1-3 have shortened the chains; floorplan
constraints and re-checking ABC9 mapping choices belong here, not before.

### Stage 5 — re-decide the target against real measurements

With Stages 1-4 actually measured, either 100 MHz is in reach on this FPGA
or it demonstrably is not, and the choice becomes informed rather than
estimated: accept whatever real number results, spend more cycles per
instruction deliberately to buy clock, or move to a different device
family. See §9 for what the existing evidence already suggests about this.

## 9. Honest ceiling estimate, stated plainly

The 2026-09-28 investigation gave an estimate, flagged explicitly as an
estimate rather than a measurement, and it should be repeated here exactly
rather than softened:

> Stages 1-2 reach 30-40 MHz with reasonable confidence; Stages 3-5
> plausibly reach 45-65 MHz for an effort comparable to Track 1-3 [the
> ~20-phase `rtl/` zero-gap-dispatch programme]. **100 MHz I would not
> commit to on ECP5 at all.**

Two things would change that answer, named explicitly by the same
investigation: a different FPGA family (ECP5 is a 40 nm, 2014-era part; a
Lattice Nexus/CertusPro or a Xilinx Artix-7 would make 100 MHz far more
attainable on comparable logic), or deliberately accepting more cycles per
instruction to buy clock rate (trading `Fmax` for `Fmax/ticks` in the
other direction — the opposite of what every stage above tries to do, but
a legitimate lever if the clock number itself is the hard requirement).

This estimate has been wrong in both directions before in this exact
project — a pivot-decision estimate predicted 3-5 MHz for the next bounded
fix and one delivered 14.24 MHz — so it is reported as a prior, not a
verdict, and the staged gates in §8 exist precisely to replace it with
real measurements rather than resolve the question by estimation. But
given the target is now fixed rather than negotiable, the honest statement
is: **getting to 100 MHz on this exact FPGA, with this exact architecture,
is not something the best existing analysis in this project is confident
about** — proceeding means either accepting that uncertainty and running
the staged gates to find out for real, or treating one of the two listed
alternatives (different device, or more cycles per instruction) as part
of the plan from the start rather than a fallback.

# Timing Diagrams

Generates side-by-side comparisons of MC68030UM.pdf's own bus-timing
diagrams against an equivalent diagram rendered directly from this
project's own RTL, simulated with Icarus Verilog. See the top-level
`README.md`'s own "Timing Diagrams" section for the embedded result.

## Why not GTKWave

GTKWave isn't installed on the machine this was built on, and Homebrew's
own cask for it is marked deprecated/disabled upstream. Even installed,
it's a live GUI trace viewer — not well suited to a scripted, repeatable
"regenerate N diagrams" pipeline, and its own oscilloscope-style visual
convention doesn't match the manual's own datasheet-style timing-diagram
convention anyway.

**[WaveDrom](https://wavedrom.com/)** is used instead — the standard tool
for rendering clean digital timing diagrams from a JSON spec, in exactly
the visual style the manual's own figures already use. `wavedrom-cli`
renders headlessly (`npx wavedrom-cli -i spec.json -p out.png`, no
display server needed) — no local install required beyond Node/npm.

## Pipeline (per diagram)

1. **A dedicated testbench** (`tb/<name>_tb.sv`) instantiates `m68030_biu`
   directly (mirroring `tb/biu_int_tb.sv`'s own signal-level harness
   shape — reset, power-on init via `tb/mem_model.sv`, then drive
   `eu_req`/`eu_addr`/`eu_siz`/`eu_rw` directly for exactly the cycle(s)
   the target diagram needs) and dumps a VCD (`$dumpfile`/`$dumpvars`,
   the same mechanism `tb/biu_tb.sv`/`tb/biu_int_tb.sv` already use).
   `read_cycle_tb.sv` drives three back-to-back reads (word then two
   bytes, all within the same test longword), keeping `eu_req` asserted
   continuously across all three so the BIU dispatches each one the
   instant its predecessor's `ST_IDLE` tick sees a fresh request.
2. **`scripts/vcd_to_wavedrom.py`** parses the VCD (stdlib only — no
   pip install needed; this machine's system Python is externally
   managed (PEP 668), and this project's own Python tooling has never
   needed a third-party dependency either) and emits a WaveDrom JSON
   spec. It samples one column per rising edge of `clk_4x` within a
   window spanning the *last* `--cycles N` (default 3) back-to-back
   assert/deassert windows of a chosen "start signal" (default `/AS`) —
   the last N, not the first, because most testbenches' own power-on
   boot sequence (SSP/PC fetch) asserts `/AS` earlier in the trace too;
   the diagram-worthy cycles are always the final bus activity before
   `$finish`, since that's what the test explicitly drives via
   `eu_req`/`eu_ack`.
   - Address is split into `A2-A31` (low 2 bits masked off, so it reads
     as constant across a same-longword chain, matching the manual)
     plus separate `A1`/`A0` single-bit lanes.
   - The data bus is split into the manual's own four byte-lane rows
     (`D24-D31`/`D16-D23`/`D8-D15`/`D0-D7`); each column only shows a
     value in the lane(s) actually selected by `SIZ`+`A[1:0]` for that
     access (mirroring `biu_byte_lane_ctrl.sv`'s own real steering rule,
     re-derived here for display rather than read off an RTL signal),
     gated on `/DBEN` so a lane's box appears only once the bus cycle
     has actually reached the point real hardware would call the data
     valid — this project's own `mem_model.sv` drives the full stored
     longword continuously regardless of `SIZ`, unlike real silicon,
     where an unselected lane may not be driven by anything at all.
   - A synthetic `S-STATE (RTL)` lane reports the BIU's own `s_state`
     output, relabeled sequentially (`S0`, `S1`, ...) and reset to `S0`
     at the start of each new bus cycle — either on leaving `ST_IDLE`,
     or on a fresh `/AS` assert edge, since chained cycles with zero
     idle gap between them never pass through `ST_IDLE` at all and
     would otherwise number straight through an unbroken chain instead
     of resetting per cycle the way the manual's own labeling does. An
     honest report of how many distinct internal states this RTL
     actually visits per cycle, not a claim that it matches the
     manual's own `S0`/`S2`/`S4` numbering label-for-label (the manual
     labels only every other real S-state; this RTL's own `state` enum
     skips two *different* named states for an ordinary read — see
     `CLAUDE.md`'s own "S-State Signal Timing" section).
3. **`wavedrom-cli`** renders the JSON spec to a PNG.
4. **`scripts/crop_manual_page.sh`** extracts and crops the corresponding
   manual page (via `pdftoppm`/`imagemagick`) to just the diagram +
   caption, excluding the manual's own page furniture (NXP logo,
   chapter-number tab, footer).

`diagrams.md` is the manifest — name, manual figure/page, crop geometry,
testbench — and the place to look before adding a new diagram (it also
documents the PDF-page-vs-printed-page-number gotcha).

## A real bug this diagram found: `/OCS` never asserted

The first version of this diagram showed `/OCS` flat (never asserting)
while the manual's Figure 7-21 shows it toggling in lockstep with
`/ECS`. Investigating that visual mismatch (rather than just noting it)
found two real, previously-undiscovered RTL bugs, both now fixed:

1. **`biu_cache_if.sv`'s own `sf_is_op` output was hardwired `1'b0`**,
   permanently telling the rest of the chip "this is never an operand
   transfer" for every ordinary EU read/write routed through it (i.e.
   almost everything a running CPU does) — `biu_multiop_fsm.sv` (MOVEM/
   MOVEP's own dedicated path) already had the correct `1'b1` for the
   identical purpose, which is what made the wrong value here stand out.
2. **`biu_cycle_gen.sv`'s own `/OCS` assert/negate window was two states
   later than the manual specifies.** MC68030UM.pdf S5.6.10/S7.3.1 state
   `/OCS` is "asserted with `/ECS`" (State 0) and negated at State 1,
   alongside it — the RTL instead asserted it at SP_S2 through SP_S5 and
   negated it at SP_S6.

Both are fixed in `rtl/biu_cache_if.sv` and `rtl/biu_cycle_gen.sv` (not
just in this diagram's own testbench) — see `CLAUDE.md`'s own phase
history for the full writeup and verification. `tb/biu_tb.sv`'s
pre-existing OCS timing test had encoded the old, wrong timing as its
expected result (with an explicit comment noting it as "a separate,
out-of-scope question, documented but not acted on" from an earlier
investigation) — that test now asserts the corrected timing instead.

## Known differences from the manual (`read_cycle`)

What's now matched: all 3 chained cycles (word + 2 byte reads), the
A2-A31/A1/A0 split, `/ECS`/`/OCS` (toggling together, matching the
manual exactly — see below), and the 4-way byte-lane data split with
values landing in the same lanes at the same cycles as the manual's own
`OP2`/`OP3`/`OP3`/`OP3` boxes. What's still different, and why it's left
alone rather than "fixed":

- **The `CLK` lane is a different clock.** The manual's `CLK` is the
  external bus clock (one period per `S0`/`S2`/`S4` label group). Ours
  is the RTL's own internal 4× clock (`clk_4x`) — 4 ticks per external
  bus cycle — since that's what this project's FSM actually runs on.
  This is the single biggest *visual* difference, but it doesn't affect
  the actual protocol timing being compared.
- **A small idle gap appears between the 3 chained cycles that the
  manual doesn't show — but this is a property of THIS diagram's own
  testbench, not of the RTL.** `read_cycle_tb.sv` drives `eu_addr`/
  `eu_rw` directly into a standalone `m68030_biu`, bypassing the real
  EU/decode pipeline entirely — there is no "next instruction" for the
  preview mechanism (below) to see, so `biu_cache_if.sv`'s own
  `CI_IDLE` transit (the one layer of the original three-layer dispatch
  floor that turned out to need real EU-side visibility to close, Phase
  253) is unavoidable here by construction, regardless of how complete
  that mechanism has since become. **`read_cycle_eu` (below) proves
  this directly**: the exact same word/byte/byte scenario, driven
  through the real pipeline instead, shows zero gap.
- **`SIZ1`/`SIZ0` are one combined 2-bit lane**, not two separate rows
  like the manual. The combined decimal value (`2`=word, `1`=byte)
  already conveys the same information; splitting it further is a
  cosmetic refinement, not attempted here.
- **Rendering style.** The manual is a hand-drafted datasheet diagram
  (crosshatched "don't care" address transitions, hexagonal data-value
  boxes). WaveDrom renders a generic digital-waveform style — a tooling
  difference, not a correctness one.

## `read_cycle_eu`: the same Figure 7-21 scenario, driven for real

`read_cycle` (above) can never show the dispatch-gap fix at all, for the
structural reason explained above — there's no EU/decode pipeline in
that testbench for `preview_ok` to run in. `read_cycle_eu`
(`tb/read_cycle_eu_tb.sv`) answers the direct question this raises: if
the SAME word/byte/byte chain Figure 7-21 depicts is driven through a
REAL decoded instruction stream instead, does it actually close the gap?

It instantiates the full `m68030_top` (not just the BIU, mirroring
`preview_dispatch`'s own approach) and boots `tests/timing_manual_chain.s`
— `MOVE.W (A0),D0` / `MOVE.B (2,A0),D1` / `MOVE.B (3,A0),D2` against a
preloaded `$1234_5678` at the base address, the same address pattern and
values `read_cycle_tb.sv` itself uses (word @ `+0`, byte @ `+2`, byte @
`+3`). A leading `MULU.L` (bus-silent, ~168 ticks) gives the IFU genuine
idle time to prefetch the `(d16,An)` forms' own extension words ahead of
need — the established technique for exercising live preview engagement
in this project's own otherwise zero-head-start test convention
(`CLAUDE.md`'s own Phase 256 entry).

**Result: zero gap, matching the manual exactly.** `S-STATE` resets to
`S0` at the start of each of the three chained cycles (`S0`-`S5`
repeated 3 times, same as the manual's own per-cycle `S0`/`S2`/`S4`
labeling) with no `--` idle marker anywhere between them — this is not
a narrow, one-addressing-mode-only result. Tracks 1-3 (`CLAUDE.md`'s own
Phase 254-273 entries) generalized the EU-side preview mechanism, in
stages, from the single narrow `(An)`-only case first demonstrated here
to every
plain/absolute/indexed EA shape, plain register-source writes, and all
16 special multi-cycle instruction FSMs (MOVEM, CAS/CAS2, memory-
indirect, etc.) — and, as directly confirmed while investigating this
very diagram, to every access SIZE (byte/word/longword) uniformly, not
just longword as an earlier draft of this README's own text assumed.
The only case left showing the gap is a diagram like `read_cycle` itself
that bypasses the EU on purpose — a property of that testbench, not a
remaining RTL gap.

Needs its own test hex (`../tests/timing_manual_chain.hex`, already
assembled and committed) — see `Makefile`'s own `TOP_SRCS` for the
fuller RTL file list a full-CPU diagram needs versus a standalone-BIU one.

## `preview_dispatch`: the original, narrowest-case proof

`tb/preview_dispatch_tb.sv` boots `tests/timing_preview.s` (two
back-to-back plain `(An)` LONGWORD reads, no extension words needed at
all) — the first, simplest case Phase 254 closed, and the same program
`tb/timing_tb.sv` uses to *measure* the improvement numerically (an
8-tick to 6-tick AS-fall-to-AS-fall reduction). Kept alongside
`read_cycle_eu` as the original, minimal demonstration; `read_cycle_eu`
is the one that maps directly onto a manual figure.

## One-time setup

- `npx` (bundled with Node.js) — fetches `wavedrom-cli` automatically on
  first run, no persistent install needed.
- `pdftoppm` + ImageMagick's `magick` (both already used elsewhere in
  this project, e.g. `docs/MC68030UM.pdf` inspection during RTL work) —
  for the manual-page cropping step.
- Icarus Verilog (`iverilog`/`vvp`) — already a project-wide dependency.

## Regenerating

```bash
cd timing_diagrams
make read_cycle       # rebuilds sim -> VCD -> spec -> both PNGs
make read_cycle_eu    # same Figure 7-21 scenario, driven through the real EU
make preview_dispatch # the original, narrowest-case (An)-only proof
make all               # all of the above
```

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
2. **`scripts/vcd_to_wavedrom.py`** parses the VCD (stdlib only — no
   pip install needed; this machine's system Python is externally
   managed (PEP 668), and this project's own Python tooling has never
   needed a third-party dependency either) and emits a WaveDrom JSON
   spec. It samples one column per rising edge of `clk_4x` within the
   *last* assertion window of a chosen "start signal" (default `/AS`) —
   the last one, not the first, because most testbenches' own power-on
   boot sequence (SSP/PC fetch) asserts `/AS` earlier in the trace too;
   the diagram-worthy cycle is the one the test explicitly drives via
   `eu_req`/`eu_ack`, which is always the final bus activity before
   `$finish`.
3. **`wavedrom-cli`** renders the JSON spec to a PNG.
4. **`scripts/crop_manual_page.sh`** extracts and crops the corresponding
   manual page (via `pdftoppm`/`imagemagick`) to just the diagram +
   caption, excluding the manual's own page furniture (NXP logo,
   chapter-number tab, footer).

`diagrams.md` is the manifest — name, manual figure/page, crop geometry,
testbench — and the place to look before adding a new diagram (it also
documents the PDF-page-vs-printed-page-number gotcha).

## Known simplifications (this first diagram, `read_cycle`)

- Only ONE bus cycle is rendered (a single word read), not the manual's
  own Figure 7-21's full three chained cycles (word + 2 byte reads).
  Extending the testbench to drive all three back-to-back, matching the
  figure exactly, is a natural next step, not yet done.
- The data bus is shown as one merged 32-bit lane (`D0-D31`), not split
  into the manual's own four separate byte-lane rows (`D24-D31`,
  `D16-D23`, `D8-D15`, `D0-D7`) with only the actually-used lane
  populated. Splitting this out is a refinement for a later pass, not
  required to prove the pipeline works.
- `/ECS` and `/OCS` (shown in the manual's own figure) aren't rendered —
  this project's own `m68030_biu` doesn't expose them as distinct
  top-level testbench-observable signals the way `/AS`/`/DS` are.

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
make read_cycle    # rebuilds sim -> VCD -> spec -> both PNGs
```

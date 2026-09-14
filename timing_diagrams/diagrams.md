# Diagram manifest

Maps each generated timing diagram back to its source testbench and its
corresponding figure in `docs/MC68030UM.pdf`, so a new diagram can be added
by following the same recipe (see `README.md` in this directory for the
full pipeline explanation).

| Name | Manual figure | PDF page | Printed page | Crop geometry | Testbench |
|------|---------------|----------|---------------|----------------|-----------|
| `read_cycle` | Figure 7-21, "Asynchronous Byte and Word Read Cycles — 32-Bit Port" — all 3 chained cycles reproduced (word read @0x10, then byte reads @0x12/@0x13, all within the same test longword, matching the figure's own WORD/BYTE/BYTE region layout and A1/A0 transitions). Driven directly at `m68030_biu` (`eu_req`/`eu_addr` hand-toggled), bypassing the EU entirely -- shows a one-tick idle gap between each cycle the manual doesn't have, a property of this testbench, not the RTL (see `read_cycle_eu`). | 194 | 7-33 | `1150x1400+0+190` | `tb/read_cycle_tb.sv` |
| `read_cycle_eu` | Same Figure 7-21 scenario as `read_cycle` (word @+0, byte @+2, byte @+3), this time driven through the REAL EU/decode pipeline via `tests/timing_manual_chain.s` (`MOVE.W (A0),D0`/`MOVE.B (2,A0),D1`/`MOVE.B (3,A0),D2`, preceded by a bus-silent `MULU.L` stall so the IFU has prefetched each instruction's own `(d16,An)` extension word ahead of need). Result: `S-STATE` runs continuously `S0`-`S17` across all 3 cycles with zero `--` -- matches the manual exactly, confirming the gap `read_cycle` shows is that testbench's own limitation, not a remaining RTL gap, and confirming (found while building this) that the preview mechanism already covers byte/word sizes uniformly, not just longword. | 194 | 7-33 | (shares `read_cycle_manual.png`) | `tb/read_cycle_eu_tb.sv` |
| `preview_dispatch` | No manual figure (project-specific, not a datasheet cycle) — the original, narrowest-case demonstration of the EU-side dispatch-gap fix (`CLAUDE.md`'s own Phase 254 entry), through the REAL EU/decode pipeline. Shows 3 consecutive bus cycles from `tests/timing_preview.s`: the opcode fetch for `MOVE.L (A0),D0` (`--` idle gap follows, ordinary case), then that instruction's own data read @`$3000`, then `MOVE.L (A1),D1`'s own data read @`$3010` chained directly onto it with **no** idle gap (`S-STATE` runs `S6..S11` straight on from `S0..S5`, no `--`) — the single plain-`(An)`-longword-read case Phase 254 closed first, before Tracks 1-3 (`CLAUDE.md`) generalized it to every EA shape, every size, and all 16 special multi-cycle FSMs (see `read_cycle_eu` for the generalized result mapped onto a real manual figure). | n/a | n/a | n/a (sim-only, no manual crop) | `tb/preview_dispatch_tb.sv` |

**Crop geometry** is an ImageMagick `WxH+X+Y` box, in pixels, against a
`pdftoppm -r 200` render of the given PDF page (200 DPI). Figure it out by
rendering the whole page first (`scripts/crop_manual_page.sh` does this
into a temp file internally — pass an oversized crop box first, inspect
the result, and narrow down) and excluding the manual's own page
furniture: the NXP logo (top-left), the black chapter-number tab
(right margin, mid-page), and the MOTOROLA/MC68030 USER'S MANUAL/page-
number footer.

**PDF page vs. printed page**: `docs/MC68030UM.pdf`'s own page index
(what `pdftoppm -f/-l` and the Read tool's own `pages` parameter expect)
does not match the manual's own printed page number in its footer — the
front matter shifts everything. Always confirm by rendering/viewing the
candidate PDF page directly before trusting a printed-page-based guess
(`pdftotext -layout -f <guess> -l <guess> docs/MC68030UM.pdf -` to check
the caption text lands where expected, or just view the page as an image).

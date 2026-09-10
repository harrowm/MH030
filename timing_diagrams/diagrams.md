# Diagram manifest

Maps each generated timing diagram back to its source testbench and its
corresponding figure in `docs/MC68030UM.pdf`, so a new diagram can be added
by following the same recipe (see `README.md` in this directory for the
full pipeline explanation).

| Name | Manual figure | PDF page | Printed page | Crop geometry | Testbench |
|------|---------------|----------|---------------|----------------|-----------|
| `read_cycle` | Figure 7-21, "Asynchronous Byte and Word Read Cycles — 32-Bit Port" (leftmost cycle only — a single word read; the manual's own figure chains 3 cycles: word read, then 2 byte reads) | 194 | 7-33 | `1150x1400+0+190` | `tb/read_cycle_tb.sv` |

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

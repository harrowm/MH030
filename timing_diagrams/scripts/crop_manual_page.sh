#!/usr/bin/env bash
# Extract and crop one page of docs/MC68030UM.pdf to a PNG for side-by-side
# comparison against an RTL-derived timing diagram.
#
# Usage: crop_manual_page.sh <page> <crop WxH+X+Y> <output.png>
#
# <page> is the PDF's own page index (not the printed page number in the
# manual's own footer -- see timing_diagrams/diagrams.md for the mapping
# from figure/printed-page to PDF page for every diagram this project has
# generated so far). <crop> is an ImageMagick-style geometry string;
# figure out the right box by first rendering the whole page (this script
# does that internally to a temp file) and inspecting it, then narrowing
# down -- the manual's own page furniture (NXP logo top-left, the black
# chapter-number tab on the right margin, the MOTOROLA/page-number
# footer) needs to be cropped out, not just the diagram + caption kept in.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <pdf-page> <crop WxH+X+Y> <output.png>" >&2
    exit 1
fi

PAGE="$1"
CROP="$2"
OUT="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDF="$SCRIPT_DIR/../../docs/MC68030UM.pdf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pdftoppm -png -f "$PAGE" -l "$PAGE" -r 200 "$PDF" "$TMP/page"
# pdftoppm names its output <prefix>-<page>.png (or just <prefix>.png for
# a single-page range on some poppler versions) -- pick whichever exists.
SRC="$TMP/page-$PAGE.png"
[ -f "$SRC" ] || SRC="$TMP/page.png"

magick "$SRC" -crop "$CROP" +repage "$OUT"
echo "Wrote $OUT (page $PAGE, crop $CROP)"

#!/usr/bin/env bash
# Phase 74: WinUAE reference log extraction
#
# Usage: tools/uae_run.sh [test_name]
#   test_name defaults to "smoke"
#
# Steps:
#   1. Build <test>.bin from <test>.s (if needed)
#   2. Build winuae/roms/<test>_test.rom via make_kickrom.py
#   3. Run WinUAE under Wine in debugger mode; pipe "t 30\nq\n" to stdin so
#      it traces 30 instructions then quits (no manual interaction needed)
#   4. Capture combined stdout+stderr → winuae/tests/<test>_uae_raw.log
#   5. Parse via uae_parse.py  → winuae/tests/<test>_uae.log  (BUS R/W format)
#
# Address note: WinUAE fetches instructions at $FC0008+ (ROM space), while the
# DUT testbench fetches at $0008+ (RAM-based ROM).  buscmp.py (Phase 75) uses
# --addr-mask=0x000FFFFF to strip the upper bits before comparing.

set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST="${1:-smoke}"

BIN="$DIR/tests/${TEST}.bin"
ROM="$DIR/winuae/roms/${TEST}_test.rom"
RAW="$DIR/winuae/tests/${TEST}_uae_raw.log"
OUT="$DIR/winuae/tests/${TEST}_uae.log"
CONFIG="$DIR/winuae/configs/smoke_bare.uae"
WINLOG="$HOME/.wine/drive_c/users/Public/Documents/Amiga Files/WinUAE/winuaelog.txt"

echo "=== Phase 74: WinUAE reference log — $TEST ==="

# ── 1. Assemble test binary ──────────────────────────────────────────────────
if [[ ! -f "$BIN" ]] || [[ "$DIR/tests/${TEST}.s" -nt "$BIN" ]]; then
    echo "Assembling ${TEST}.s → ${TEST}.bin"
    vasmm68k_mot -Fbin -m68030 "$DIR/tests/${TEST}.s" -o "$BIN"
fi

# ── 2. Build ROM image ───────────────────────────────────────────────────────
echo "Building ROM image..."
python3 "$DIR/tools/make_kickrom.py" "$BIN" "$ROM"

mkdir -p "$(dirname "$RAW")"

# ── 3. Run WinUAE: pipe debugger trace commands to stdin ────────────────────
# WinUAE starts with use_debugger=true (paused at first instruction).
# Piping "t 30\nq\n": trace 30 instructions, then quit.
WIN_CONFIG="Z:$(echo "$CONFIG" | sed 's|/|\\\\|g')"
echo "Launching WinUAE (debugger trace, 30s timeout)..."

printf 't 30\nq\n' \
    | timeout 30 wine "$DIR/winuae/winuae64.exe" -config "$WIN_CONFIG" 2>&1 \
    | grep -vE '^\s+VK_|\[mvk-info\]|fixme:|^00[0-9a-f]{2}:' \
    > "$RAW" || true

LINES=$(wc -l < "$RAW")
echo "Raw log: $RAW ($LINES lines)"

# ── 4. Also grab the WinUAE log file (written by win32.logfile=true) ─────────
if [[ -f "$WINLOG" ]]; then
    echo "WinUAE log: $WINLOG (last 10 lines:)"
    tail -10 "$WINLOG"
    echo "---"
fi

# ── 5. Parse raw capture → BUS R/W format ───────────────────────────────────
echo "Parsing..."
python3 "$DIR/tools/uae_parse.py" "$RAW" "$OUT"
echo "Reference log: $OUT"

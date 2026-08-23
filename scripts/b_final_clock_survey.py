#!/usr/bin/env python3
"""Phase 161 Part B Stage B_final: broaden total-clock-parity checking
across the ~150 tests Part A already built, reusing that same
infrastructure (no new RTL, no new test authoring) rather than the single
worked example Phase 160 Stage 7 relied on.

For each manifest entry, runs sim/timing (informational -- +expect_clocks
is never asserted, matching every earlier stage's own convention) and
parses the printed "MEASURED ticks=N clocks=M" line, then extracts the
manual's own predicted total from the entry's own `desc` field (summing
every "N(...)" -- (r/p/w) -- occurrence, which correctly handles both
plain rows and composed rows like "NCC=4(.../...) + fea(...)=3(.../...)").
Reports the per-test gap (measured - manual) and an aggregate summary.
"""
import json
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).parent.parent
SIM_BIN = REPO / 'sim' / 'timing'

TOTAL_RE = re.compile(r'(\d+)\([\d/]+\)')
MEASURED_RE = re.compile(r'MEASURED ticks=(\d+) clocks=(\d+)')


def to_int(v):
    if isinstance(v, int):
        return v
    return int(v, 16) if v.lower().startswith('0x') else int(v)


def manual_total(desc):
    totals = [int(m) for m in TOTAL_RE.findall(desc)]
    return sum(totals) if totals else None


def run_one(entry):
    hexpath = REPO / entry['hex']
    if not hexpath.exists():
        return None
    args = [
        str(SIM_BIN),
        f"+hexfile={hexpath.relative_to(REPO)}",
        f"+target_pc={to_int(entry['target_pc']):x}",
        f"+watch_reg={entry['watch_reg']}",
        f"+watch_val={to_int(entry['watch_val']):x}",
        f"+expect_r={entry['expect_r']}",
        f"+expect_p={entry['expect_p']}",
        f"+expect_w={entry['expect_w']}",
    ]
    if 'instr_len' in entry:
        args.append(f"+instr_len={entry['instr_len']}")
    try:
        r = subprocess.run(args, cwd=REPO, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None
    m = MEASURED_RE.search(r.stdout)
    if not m:
        return None
    return int(m.group(2))  # clocks


def main():
    manifests = sorted((REPO / 'tests' / 'timing').glob('a[1-7]_*.json'))
    rows = []
    for mpath in manifests:
        with open(mpath) as f:
            entries = json.load(f)
        for e in entries:
            mt = manual_total(e['desc'])
            measured = run_one(e)
            if measured is None or mt is None:
                continue
            rows.append((mpath.stem, e['name'], mt, measured, measured - mt))

    print(f"{'stage':10s} {'test':28s} {'manual':>7s} {'measured':>9s} {'gap':>5s}")
    for stage, name, mt, meas, gap in rows:
        print(f"{stage:10s} {name:28s} {mt:7d} {meas:9d} {gap:5d}")

    gaps = [g for *_, g in rows]
    n = len(gaps)
    if n:
        print(f"\n{n} tests compared")
        print(f"gap min={min(gaps)} max={max(gaps)} mean={sum(gaps)/n:.2f}")
        # distribution
        from collections import Counter
        c = Counter(gaps)
        print("gap distribution:", dict(sorted(c.items())))


if __name__ == '__main__':
    main()

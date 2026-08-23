#!/usr/bin/env python3
"""
run_timing.py — Phase 161 Part A: batch runner for the Chapter 11 (MC68030UM.pdf
Section 11, Instruction Execution Timing) r/p/w verification sweep.

Each test case is an isolated, hand-written assembly program (following the
tests/timing0.s pattern: setup code, then a taken branch landing directly on
a physically-distant instruction-under-test, so the IFU has no real prefetch
head start -- matching NCC's own "no overlap with the preceding instruction"
definition) plus a manifest entry describing where to look and what the
manual's own table predicts.

Usage:
    python3 scripts/run_timing.py tests/timing/a1_fea.json [more.json ...]
        [--verbose]      show each PASS/FAIL line, not just the summary
        [--stop-on-fail] stop after the first failing test case

Manifest format (JSON list of objects):
    {
      "name":       "fea_An",              # short id, used as the .hex basename lookup
      "hex":        "tests/timing/fea_an.hex",  # or "asm" (see below) -- one required
      "asm":        "tests/timing/fea_an.s",    # optional; built via `make <hex>` if hex missing
      "target_pc":  "0x200",               # hex string or int
      "watch_reg":  2,                     # 0-7 (Dn)
      "watch_val":  "0xdeadbeef",          # hex string or int
      "expect_r":   1,
      "expect_p":   1,
      "expect_w":   0,
      "desc":       "fea (An) NCC=3(1/0/0), MC68030UM.pdf 11-26"
    }
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO    = Path(__file__).parent.parent
SIM_BIN = REPO / 'sim' / 'timing'

RESULT_RE = re.compile(r'^(PASS|FAIL)\s+(.*)$')


def to_int(v):
    if isinstance(v, int):
        return v
    return int(v, 16) if v.lower().startswith('0x') else int(v)


def ensure_hex(entry):
    """Return a Path to the test's .hex, building it via `make` if only .asm was given."""
    if 'hex' in entry:
        hexpath = REPO / entry['hex']
    elif 'asm' in entry:
        hexpath = (REPO / entry['asm']).with_suffix('.hex')
    else:
        raise ValueError(f"entry {entry.get('name')} needs 'hex' or 'asm'")

    if not hexpath.exists():
        rel = hexpath.relative_to(REPO)
        r = subprocess.run(['make', str(rel)], cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0 or not hexpath.exists():
            raise RuntimeError(f"failed to build {rel}:\n{r.stdout}\n{r.stderr}")
    return hexpath


def run_one(entry, verbose=False):
    hexpath = ensure_hex(entry)
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
    r = subprocess.run(args, cwd=REPO, capture_output=True, text=True, timeout=60)
    lines = r.stdout.splitlines()

    checks = []
    measured = None
    for line in lines:
        m = RESULT_RE.match(line)
        if m:
            checks.append((m.group(1), m.group(2)))
        if line.startswith('MEASURED'):
            measured = line.strip()

    overall_pass = any(status == 'PASS' and name == 'timing' for status, name in checks)
    if verbose or not overall_pass:
        print(f"{'PASS' if overall_pass else 'FAIL'}  {entry['name']}: {entry.get('desc', '')}")
        if measured:
            print(f"      {measured}")
        if not overall_pass:
            for status, name in checks:
                if status == 'FAIL':
                    print(f"      FAIL  {name}")
            if not checks:
                print("      (no PASS/FAIL lines parsed -- raw stdout follows)")
                print('\n'.join('      ' + l for l in lines[-15:]))

    return overall_pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('manifests', nargs='+', help='JSON manifest file(s)')
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--stop-on-fail', action='store_true')
    args = ap.parse_args()

    if not SIM_BIN.exists():
        print(f"ERROR: {SIM_BIN} not built -- run `make sim/timing` first", file=sys.stderr)
        sys.exit(1)

    total = 0
    passed = 0
    for manifest_path in args.manifests:
        with open(manifest_path) as f:
            entries = json.load(f)
        print(f"=== {manifest_path} ({len(entries)} tests) ===")
        for entry in entries:
            total += 1
            ok = run_one(entry, verbose=args.verbose)
            if ok:
                passed += 1
            elif args.stop_on_fail:
                print(f"\nSTOPPED after first failure: {entry['name']}")
                sys.exit(1)

    print(f"\n{passed}/{total} passed")
    sys.exit(0 if passed == total else 1)


if __name__ == '__main__':
    main()

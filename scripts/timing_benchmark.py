#!/usr/bin/env python3
"""
timing_benchmark.py — the canonical, single entry point for comparing this
RTL's own instruction timing against MC68030UM.pdf Section 11's own NCC
tables, on a per-instruction or whole-corpus basis.

Consolidates two previously-separate, overlapping scripts into one hardened
tool (see plan.md's "Master timing-benchmark script" phase for the full
background -- an ad hoc one-off script bypassed the correct measurement-field
selection and reported a materially wrong gap for 3 new tests, which is
exactly the class of mistake this tool exists to make structurally hard to
repeat):

  - scripts/run_timing.py's own r/p/w PASS/FAIL check and auto-hex-build
    (`make <hex>` if only `.s` exists) are reused here, not reimplemented.
  - scripts/b_final_clock_survey.py's own MEASURED vs MEASURED_INSTR_ONLY
    field-selection logic (`needs_marker = expect_r>0 or expect_w>0`) is
    reused here VERBATIM -- this project has exactly one place that decision
    gets made now.

New in this tool, not present in either predecessor:
  - The r/p/w PASS/FAIL the simulation itself already computes is surfaced
    in the SAME report row as the gap number, not silently dropped -- a test
    with a wrong bus-cycle count now shows MISMATCH right next to its own
    gap, instead of the gap looking like an ordinary (if surprising) result.
  - `--filter SUBSTR`: run/report only tests whose name or desc contains
    SUBSTR (case-insensitive) -- the per-instruction spot-check capability
    that was missing, intended to replace the temptation to write a fresh
    one-off script for a single instruction.
  - Known-issues annotation via the optional sidecar tests/timing/known_
    issues.json ({test_name: {"reason": ..., "ref": ...}}) -- already-
    investigated, documented non-bugs (e.g. CHK's own -5 gap, a6_andi_to_sr/
    ccr's own p=1-not-2 combined-fetch alignment property) are tagged
    [KNOWN: reason] in the report instead of looking like unexplained
    anomalies. Summary stats are reported BOTH with and without known-issue
    rows included, so neither view is hidden.
  - Optional per-entry "manual_ref" field (e.g. ["ALU", "ADD Rn,Dn"], or a
    list of such pairs for a composite row) cross-checks the desc-parsed
    manual total against scripts/timing_tables.py's own structured ncc_
    total()/ncc_rpw() lookups and flags a REF_MISMATCH if they disagree.
    Opt-in per test -- the existing ~150-test corpus is NOT retrofitted
    with this field (that would be its own real transcription-risk
    migration), only new tests that choose to add it get the extra check.
  - `--json OUTFILE`: machine-readable report for any future automated
    regression-tracking.

scripts/run_timing.py and scripts/b_final_clock_survey.py are left
completely unchanged (both are referenced by name throughout plan.md's own
permanent phase history) -- this is the tool to reach for going forward.

Usage:
    python3 scripts/timing_benchmark.py                        # everything
    python3 scripts/timing_benchmark.py --filter neg            # just NEG*
    python3 scripts/timing_benchmark.py tests/timing/a4_bcd_single.json
    python3 scripts/timing_benchmark.py --filter chk --verbose
    python3 scripts/timing_benchmark.py --json /tmp/report.json
    python3 scripts/timing_benchmark.py --strict                # exit 1 on
                                                                  # any MISMATCH
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent
SIM_BIN = REPO / 'sim' / 'timing'
KNOWN_ISSUES_PATH = REPO / 'tests' / 'timing' / 'known_issues.json'

TOTAL_RE = re.compile(r'(\d+)\([\d/]+\)')
MEASURED_RE = re.compile(r'MEASURED ticks=(\d+) clocks=(\d+)')
INSTR_ONLY_RE = re.compile(r'MEASURED_INSTR_ONLY ticks=(\d+) clocks=(\d+)')
RESULT_RE = re.compile(r'^(PASS|FAIL)\s+(.*)$')
RPW_CHECK_RE = re.compile(r'^r/p/w == ')


def to_int(v):
    if isinstance(v, int):
        return v
    return int(v, 16) if v.lower().startswith('0x') else int(v, 0)


def manual_total(desc):
    """Sum every 'N(...)' occurrence in desc -- handles both plain rows
    ("NCC=4(0/1/0)") and composed rows ("NCC=4(...) + fea(...)=3(...)")."""
    totals = [int(m) for m in TOTAL_RE.findall(desc)]
    return sum(totals) if totals else None


def ensure_hex(entry):
    """Return a Path to the test's .hex, building it via `make` if only
    .s/.asm was given. Reused from run_timing.py's own ensure_hex()."""
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


def load_known_issues():
    if not KNOWN_ISSUES_PATH.exists():
        return {}
    with open(KNOWN_ISSUES_PATH) as f:
        return json.load(f)


def check_manual_ref(entry, desc_total):
    """Optional cross-check: if entry['manual_ref'] is present, look it up
    in scripts/timing_tables.py and compare against the desc-parsed total.
    Returns None if no manual_ref given (nothing to check), else a string
    describing a mismatch, or '' if it matches."""
    ref = entry.get('manual_ref')
    if not ref:
        return None
    try:
        import timing_tables as tt
    except ImportError:
        sys.path.insert(0, str(REPO / 'scripts'))
        import timing_tables as tt

    # A single [table, mode] pair, or a list of such pairs for a composite row.
    refs = ref if isinstance(ref[0], list) else [ref]
    total = 0
    for table_name, mode in refs:
        table = getattr(tt, table_name)
        total += tt.ncc_total(table, mode)
    if desc_total is not None and total != desc_total:
        return f"manual_ref total={total} but desc-parsed total={desc_total}"
    return ''


def run_one(entry, timeout=30):
    """Run one test, returning a dict with all raw fields -- never raises
    for a timeout/hang, reports it as such instead."""
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
    if 'instr_len' in entry:
        args.append(f"+instr_len={entry['instr_len']}")
    if 'watch_kind' in entry:
        args.append(f"+watch_kind={entry['watch_kind']}")

    try:
        r = subprocess.run(args, cwd=REPO, capture_output=True, text=True, timeout=timeout)
        stdout = r.stdout
    except subprocess.TimeoutExpired:
        return dict(hang=True, checks=[], rpw_ok=None, measured=None, instr_only=None, stdout='')

    checks = []
    for line in stdout.splitlines():
        m = RESULT_RE.match(line)
        if m:
            checks.append((m.group(1), m.group(2)))

    rpw_ok = None
    for status, name in checks:
        if RPW_CHECK_RE.match(name):
            rpw_ok = (status == 'PASS')

    m = MEASURED_RE.search(stdout)
    mi = INSTR_ONLY_RE.search(stdout)
    measured = int(m.group(2)) if m else None
    instr_only = int(mi.group(2)) if mi else None

    return dict(hang=False, checks=checks, rpw_ok=rpw_ok,
                measured=measured, instr_only=instr_only, stdout=stdout)


def resolved_measurement(entry, result):
    """The one, canonical field-selection decision for this whole project:
    marker-needing tests (expect_r>0 or expect_w>0) use MEASURED_INSTR_ONLY;
    everything else uses the raw MEASURED figure. Ported verbatim from
    b_final_clock_survey.py's own already-correct logic."""
    needs_marker = (entry.get('expect_r', 0) > 0) or (entry.get('expect_w', 0) > 0)
    if needs_marker and result['instr_only'] is not None:
        return result['instr_only']
    return result['measured']


def matches_filter(entry, filt):
    if not filt:
        return True
    filt = filt.lower()
    return filt in entry['name'].lower() or filt in entry.get('desc', '').lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('manifests', nargs='*', help='JSON manifest file(s); default: all tests/timing/a[1-7]_*.json')
    ap.add_argument('--filter', help='only tests whose name/desc contains this substring (case-insensitive)')
    ap.add_argument('--verbose', action='store_true', help='show FAIL/hang detail per test')
    ap.add_argument('--json', metavar='OUTFILE', help='also write a machine-readable JSON report')
    ap.add_argument('--strict', action='store_true', help='exit 1 if any test has an r/p/w MISMATCH or hangs')
    args = ap.parse_args()

    if not SIM_BIN.exists():
        print(f"ERROR: {SIM_BIN} not built -- run `make sim/timing` first", file=sys.stderr)
        sys.exit(1)

    manifest_paths = [Path(p) for p in args.manifests] if args.manifests \
        else sorted((REPO / 'tests' / 'timing').glob('a[1-7]_*.json'))

    known = load_known_issues()

    rows = []
    any_mismatch = False
    for mpath in manifest_paths:
        with open(mpath) as f:
            entries = json.load(f)
        for e in entries:
            if not matches_filter(e, args.filter):
                continue
            desc_total = manual_total(e.get('desc', ''))
            ref_note = check_manual_ref(e, desc_total)
            result = run_one(e)
            gap = None
            if not result['hang'] and desc_total is not None:
                meas = resolved_measurement(e, result)
                if meas is not None:
                    gap = meas - desc_total

            issue = known.get(e['name'])
            mismatch = result['hang'] or (result['rpw_ok'] is False) or (ref_note not in (None, ''))
            if mismatch:
                any_mismatch = True

            rows.append(dict(
                stage=mpath.stem, name=e['name'], manual=desc_total,
                measured=resolved_measurement(e, result) if not result['hang'] else None,
                gap=gap, rpw_ok=result['rpw_ok'], hang=result['hang'],
                ref_note=ref_note, known=issue, stdout=result['stdout'],
            ))

    # ── Report ──────────────────────────────────────────────────────────
    print(f"{'stage':16s} {'test':28s} {'manual':>7s} {'measured':>9s} {'gap':>5s}  {'status'}")
    for row in rows:
        manual_s = f"{row['manual']:7d}" if row['manual'] is not None else "      ?"
        meas_s = f"{row['measured']:9d}" if row['measured'] is not None else "        ?"
        gap_s = f"{row['gap']:+5d}" if row['gap'] is not None else "    ?"
        status = ""
        if row['hang']:
            status = "HANG"
        elif row['rpw_ok'] is False:
            status = "MISMATCH(r/p/w)"
        elif row['ref_note']:
            status = f"REF_MISMATCH({row['ref_note']})"
        if row['known']:
            status = (status + " " if status else "") + f"[KNOWN: {row['known'].get('reason', '')}]"
        print(f"{row['stage']:16s} {row['name']:28s} {manual_s} {meas_s} {gap_s}  {status}")
        if args.verbose and (row['hang'] or row['rpw_ok'] is False):
            for line in row['stdout'].splitlines()[-12:]:
                print(f"      {line}")

    # ── Summary ─────────────────────────────────────────────────────────
    all_gaps = [r['gap'] for r in rows if r['gap'] is not None]
    clean_gaps = [r['gap'] for r in rows if r['gap'] is not None and not r['known']]
    mismatches = [r['name'] for r in rows if r['hang'] or r['rpw_ok'] is False]

    print(f"\n{len(rows)} tests run, {len(all_gaps)} produced a gap figure")
    if mismatches:
        print(f"{len(mismatches)} r/p/w MISMATCH or HANG: {', '.join(mismatches)}")
    if all_gaps:
        n = len(all_gaps)
        print(f"gap (all):            min={min(all_gaps)} max={max(all_gaps)} mean={sum(all_gaps)/n:.2f}  (n={n})")
    if clean_gaps:
        n = len(clean_gaps)
        print(f"gap (known excluded):  min={min(clean_gaps)} max={max(clean_gaps)} mean={sum(clean_gaps)/n:.2f}  (n={n})")

    if args.json:
        with open(args.json, 'w') as f:
            json.dump([{k: v for k, v in r.items() if k != 'stdout'} for r in rows], f, indent=2)
        print(f"\nJSON report written to {args.json}")

    if args.strict and any_mismatch:
        sys.exit(1)


if __name__ == '__main__':
    main()

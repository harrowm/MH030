#!/usr/bin/env python3
"""
run_harte.py — run Tom Harte SingleStepTests m68000 vectors through the MC68030 DUT.

For each test case:
  1. Filter unsupported cases (PC-relative EA, address conflicts)
  2. Generate a hex file via gen_harte_hex.py
  3. Run vvp sim/harte_dat +hexfile=...
  4. Parse REGSTATE and MEMWRITE output
  5. Compare D0-D7, A0-A6, A7, CCR bits against test.final

Usage:
  python3 scripts/run_harte.py tests/harte/ADD.b.json.bin [ADD.w.json.bin ...]
      [--limit N]          only run first N tests per file
      [--verbose]          show each PASS/FAIL with details
      [--timeout-cycles N] vvp cycle budget per test (default 8000)
      [--stop-on-fail N]   stop after N failures
"""

import argparse
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO     = Path(__file__).parent.parent
SIM_BIN  = REPO / 'sim' / 'harte_dat'

sys.path.insert(0, str(Path(__file__).parent))
from parse_harte  import decode_file
from gen_harte_hex import gen_hex, can_run, get_scale_remap


# ── Output parsing ────────────────────────────────────────────────────────────

def parse_output(text):
    """
    Parse vvp stdout.  Returns:
      regs  : dict name→int  (D0..D7, A0..A7, SR, PC) or None on timeout
      writes: dict byte_addr→byte_val
      status: 'ok' | 'timeout' | 'addrerr'
    """
    regs   = None
    writes = {}
    status = 'timeout'

    for line in text.splitlines():
        if line.startswith('REGSTATE '):
            parts = line[9:].split()
            regs = {}
            for p in parts:
                k, v = p.split('=')
                try:
                    regs[k] = int(v, 16)
                except ValueError:
                    regs[k] = 0  # X-value propagation from Verilog

        elif line.startswith('MEMWRITE '):
            parts = line[9:].split()
            if len(parts) >= 2:
                try:
                    addr = int(parts[0], 16)
                    val  = int(parts[1], 16) & 0xFF
                    writes[addr] = val
                except ValueError:
                    pass  # skip X-valued writes from Icarus

        elif line.strip() == 'OK':
            status = 'ok'
        elif line.strip() == 'TIMEOUT':
            status = 'timeout'
        elif line.strip() == 'ADDRERR':
            status = 'addrerr'

    return regs, writes, status


# ── Comparison ────────────────────────────────────────────────────────────────

# SR bits we compare:  X N Z V C  (bits 4:0).
# We skip S/T/M/I bits because:
#   - We force supervisor mode for STOP compatibility → S may differ
#   - Trace/interrupt bits are unaffected by ADD
CCR_MASK = 0x001F


def compare(test, regs, writes, verbose):
    """
    Return list of failure strings (empty = PASS).
    """
    ini   = test['initial']
    final = test['final']
    fails = []

    if regs is None:
        return ['no REGSTATE output']

    def chk(name, got, exp, mask=0xFFFFFFFF):
        g = got & mask
        e = exp & mask
        if g != e:
            fails.append(f"{name}: got {g:#010x}, exp {e:#010x}")

    # Data registers
    for n in range(8):
        chk(f'D{n}', regs[f'D{n}'], final[f'd{n}'])

    # Address registers A0-A6
    for n in range(7):
        chk(f'A{n}', regs[f'A{n}'], final[f'a{n}'])

    # A7: compare to ssp (we always run supervisor) or usp if initial was user
    exp_a7 = final['ssp'] if (ini['sr'] & 0x2000) else final['usp']
    chk('A7', regs['A7'], exp_a7)

    # CCR (X N Z V C only)
    chk('CCR', regs['SR'], final['sr'], CCR_MASK)

    # Memory writes: check bytes that CHANGED between initial.ram and final.ram
    ini_map   = {a: v for a, v in ini['ram']}
    final_map = {a: v for a, v in final['ram']}

    # Scale remap: when indexed EA has non-zero scale the DUT writes to EA_68030
    # rather than the 68000 reference EA.  Redirect expected writes (and the
    # corresponding initial values) so the address comparison is correct.
    for remap in get_scale_remap(test):
        ea0, ea1, nb = remap['ea_68000'], remap['ea_68030'], remap['siz_bytes']
        def _remap(m, ea0=ea0, ea1=ea1, nb=nb):
            out = {}
            for a, v in m.items():
                if ea0 <= a < ea0 + nb:
                    out[ea1 + (a - ea0)] = v
                else:
                    out[a] = v
            return out
        ini_map   = _remap(ini_map)
        final_map = _remap(final_map)

    for addr, exp_byte in final_map.items():
        if ini_map.get(addr) == exp_byte:
            continue   # unchanged — don't require a MEMWRITE for it
        got_byte = writes.get(addr)
        if got_byte is None:
            fails.append(f"mem[{addr:#08x}]: no write seen, exp {exp_byte:#04x}")
        elif got_byte != exp_byte:
            fails.append(f"mem[{addr:#08x}]: wrote {got_byte:#04x}, exp {exp_byte:#04x}")

    return fails


# ── Per-test runner ───────────────────────────────────────────────────────────

def run_test(test, cycles, verbose):
    """Run one test.  Returns (result_str, fail_list)."""
    ok, reason = can_run(test)
    if not ok:
        return f'SKIP ({reason})', []

    hex_content = gen_hex(test)

    with tempfile.NamedTemporaryFile(suffix='.hex', mode='w',
                                     delete=False) as f:
        f.write(hex_content)
        hexpath = f.name

    try:
        result = subprocess.run(
            ['vvp', str(SIM_BIN), f'+hexfile={hexpath}',
             f'+cycles={cycles}'],
            capture_output=True, text=True, timeout=30
        )
        out = result.stdout
    except subprocess.TimeoutExpired:
        return 'TIMEOUT (vvp)', [f'vvp process timed out']
    finally:
        os.unlink(hexpath)

    regs, writes, status = parse_output(out)

    if status == 'timeout':
        return 'TIMEOUT', [f'no STOP within {cycles} cycles']
    if status == 'addrerr':
        return 'ADDRERR', ['address error during execution']

    fails = compare(test, regs, writes, verbose)

    if verbose and fails:
        print(f"  [{test['name']}]")
        for f in fails:
            print(f"    MISMATCH: {f}")
        if regs:
            ini = test['initial']
            fin = test['final']
            print(f"    initial SR={ini['sr']:#06x}  final SR={fin['sr']:#06x}  got SR={regs['SR']:#06x}")

    return ('PASS' if not fails else 'FAIL'), fails


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+', help='.json.bin/.json.gz test files')
    ap.add_argument('--limit',          type=int, default=None)
    ap.add_argument('--verbose',        action='store_true')
    ap.add_argument('--timeout-cycles', type=int, default=8000)
    ap.add_argument('--stop-on-fail',   type=int, default=None)
    ap.add_argument('--jobs', '-j',     type=int, default=6,
                    help='parallel vvp workers (default 6)')
    args = ap.parse_args()

    if not SIM_BIN.exists():
        print(f"ERROR: {SIM_BIN} not found — run: make sim/harte_dat", file=sys.stderr)
        sys.exit(1)

    total_pass = total_fail = total_skip = total_timeout = 0
    fail_count = 0

    for path in args.files:
        tests = decode_file(path)
        if args.limit:
            tests = tests[:args.limit]

        fname = Path(path).name
        print(f"\n=== {fname} ({len(tests)} tests) ===", flush=True)

        indexed = list(enumerate(tests))

        def _run(item):
            i, test = item
            return i, test, *run_test(test, args.timeout_cycles, args.verbose)

        results_by_idx = {}
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(_run, item): item for item in indexed}
            for fut in as_completed(futures):
                i, test, result, fails = fut.result()
                results_by_idx[i] = (test, result, fails)

        for i in range(len(indexed)):
            test, result, fails = results_by_idx[i]
            if result == 'PASS':
                total_pass += 1
                if args.verbose:
                    print(f"  PASS  [{i:4d}] {test['name']}")
            elif result.startswith('SKIP'):
                total_skip += 1
                if args.verbose:
                    print(f"  SKIP  [{i:4d}] {test['name']}  — {result}")
            elif 'TIMEOUT' in result:
                total_timeout += 1
                total_fail += 1
                fail_count += 1
                print(f"  TIMEOUT [{i:4d}] {test['name']}")
            else:
                total_fail += 1
                fail_count += 1
                print(f"  FAIL  [{i:4d}] {test['name']}")
                for f in fails:
                    print(f"           {f}")

            if args.stop_on_fail and fail_count >= args.stop_on_fail:
                print(f"\nStopped after {args.stop_on_fail} failure(s).")
                break

    print(f"\n{'='*60}")
    print(f"PASS {total_pass}  FAIL {total_fail}  SKIP {total_skip}  "
          f"TIMEOUT {total_timeout}")
    total_run = total_pass + total_fail
    if total_run:
        pct = 100 * total_pass / total_run
        print(f"{total_pass}/{total_run} passed ({pct:.1f}%)")

    sys.exit(0 if total_fail == 0 else 1)


if __name__ == '__main__':
    main()

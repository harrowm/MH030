#!/usr/bin/env python3
"""run_mustest.py — run Musashi instruction test suite through DUT and Musashi.

For each .bin in the test directory:
  1. Run through tools/mustest (Musashi test driver) — exit-0 = PASS
  2. Convert to hex with scripts/bin2hex.py
  3. Run through sim/mustest (DUT testbench via vvp)
  4. Report pass/fail comparison

Usage:
    python3 scripts/run_mustest.py [--dir DIR] [--cycles N] [-v]
"""

import argparse, pathlib, subprocess, sys, tempfile

MUSTEST_BIN = "tools/mustest"
DEFAULT_SIM = "sim/vmustest"
BIN2HEX     = "scripts/bin2hex.py"
DEFAULT_DIR = "tools/musashi/test/mc68000"


def musashi_pass(binpath):
    r = subprocess.run([MUSTEST_BIN, str(binpath)],
                       capture_output=True, text=True, timeout=30)
    pass_n = fail_n = 0
    for line in r.stdout.splitlines():
        if "test_pass_count" in line:
            pass_n = int(line.split("=")[1].strip())
        if "test_fail_count" in line:
            fail_n = int(line.split("=")[1].strip())
    return r.returncode == 0 and pass_n > 0 and fail_n == 0


def dut_pass(binpath, cycles, sim_bin):
    with tempfile.NamedTemporaryFile(suffix='.hex', delete=False, mode='w') as tf:
        hexpath = pathlib.Path(tf.name)
    try:
        subprocess.run(
            ["python3", BIN2HEX, str(binpath), str(hexpath)],
            check=True, capture_output=True, timeout=10)

        name = binpath.stem
        r = subprocess.run(
            [sim_bin,
             f"+hexfile={hexpath}",
             f"+cycles={cycles}",
             f"+testname={name}"],
            capture_output=True, text=True, timeout=300)

        for line in r.stdout.splitlines():
            if line.startswith("PASS"):
                return True
            if line.startswith("FAIL"):
                return False
        return False   # no verdict line = timeout / crash
    finally:
        hexpath.unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir",    default=DEFAULT_DIR,
                    help="directory containing .bin test files")
    ap.add_argument("--sim",    default=DEFAULT_SIM,
                    help=f"DUT simulator binary (default {DEFAULT_SIM})")
    ap.add_argument("--cycles", type=int, default=5_000_000,
                    help="DUT simulation cycle limit per test (default 5000000)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    bins = sorted(pathlib.Path(args.dir).glob("*.bin"))
    if not bins:
        print(f"No .bin files found in {args.dir}", file=sys.stderr)
        sys.exit(1)

    passed = failed = skipped = 0

    for b in bins:
        name = b.stem

        ref_ok = musashi_pass(b)
        if not ref_ok:
            # Musashi itself fails — skip rather than blame DUT
            print(f"  {name:<22} SKIP  (Musashi fail)")
            skipped += 1
            continue

        dut_ok = dut_pass(b, args.cycles, args.sim)

        if dut_ok:
            if args.verbose:
                print(f"  {name:<22} PASS")
            else:
                print(f"  {name:<22} PASS")
            passed += 1
        else:
            print(f"  {name:<22} FAIL")
            failed += 1

    total = passed + failed + skipped
    print(f"\n{passed}/{total} PASS  {failed} FAIL  {skipped} SKIP")
    sys.exit(0 if failed == 0 else 1)


if __name__ == '__main__':
    main()

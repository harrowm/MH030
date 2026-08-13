#!/usr/bin/env python3
"""
run_harte_batch.py — batched Tom Harte SingleStepTests runner.

Same correctness path as run_harte.py (can_run/gen_hex/compare are imported
unchanged, not reimplemented), but groups many tests into one vvp process
instead of spawning one process per test — amortizes Icarus's fixed
per-process elaboration cost, which dominates wall time for cheap
(single-bus-cycle) instructions. Uses tb/harte_batch_tb.sv / sim/harte_batch,
which loops over a manifest of hex files, doing a real rst_n pulse (not a
memory clear — deliberately not needed, see plan.md's batching investigation)
between tests.

Validated against ADD.b (2500 tests) and MOVEM.l (8065 tests, a genuine
multi-beat FSM instruction) with zero result differences vs run_harte.py.
Speedup is instruction-class-dependent: ~5x for cheap register/immediate
instructions, ~1.1x for expensive multi-cycle FSM ones, since batching only
amortizes the FIXED per-process cost, not actual simulated bus-cycle time.

Usage:
  python3 scripts/run_harte_batch.py tests/harte/ADD.b.json.bin [...]
      [--limit N]          only run first N tests per file
      [--verbose]          show each FAIL with details
      [--timeout-cycles N] vvp cycle budget per test (default 8000)
      [--chunk-size N]     tests per vvp process (default 300)
      [--jobs N] / -j N    parallel vvp processes (default 8)
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO    = Path(__file__).parent.parent
SIM_BIN = REPO / 'sim' / 'harte_batch'

sys.path.insert(0, str(Path(__file__).parent))
from parse_harte   import decode_file
from gen_harte_hex import gen_hex, can_run
from run_harte     import compare   # identical comparison logic, not reimplemented


# ── Batched-output parsing ──────────────────────────────────────────────────

def split_batch_output(text):
    """Split vvp stdout into {test_idx: [lines]} using the === TEST N === /
    ENDTEST markers tb/harte_batch_tb.sv prints. The header is emitted BEFORE
    the run (not after) so live MEMWRITE output — printed by a concurrent
    always_ff DURING the fork/join, chronologically before any post-join
    $display — lands inside the right test's block. See plan.md's batching
    write-up for the two testbench bugs (reset race, this ordering issue)
    found and fixed while prototyping this."""
    blocks = {}
    cur, buf = None, []
    for line in text.splitlines():
        if line.startswith('=== TEST'):
            cur, buf = int(line.split()[2]), []
        elif line.strip() == 'ENDTEST':
            if cur is not None:
                blocks[cur] = buf
            cur = None
        elif cur is not None:
            buf.append(line)
    return blocks


def parse_block(buf):
    """Same shape as run_harte.parse_output, applied to one test's lines."""
    regs, writes, status = None, {}, 'timeout'
    for line in buf:
        if line.startswith('REGSTATE '):
            regs = {}
            for p in line[9:].split():
                k, v = p.split('=')
                try:
                    regs[k] = int(v, 16)
                except ValueError:
                    regs[k] = 0
        elif line.startswith('MEMWRITE '):
            parts = line[9:].split()
            if len(parts) >= 2:
                try:
                    writes[int(parts[0], 16)] = int(parts[1], 16) & 0xFF
                except ValueError:
                    pass
        elif line.strip() == 'OK':
            status = 'ok'
        elif line.strip() == 'TIMEOUT':
            status = 'timeout'
        elif line.strip() == 'ADDRERR':
            status = 'addrerr'
    return regs, writes, status


# ── Chunk runner ─────────────────────────────────────────────────────────────

def run_chunk(tests, cycles, timeout_s):
    """Write one manifest + N hex files for this chunk, run ONE vvp process,
    return list of (test, regs, writes, status) in order."""
    hexdir = tempfile.mkdtemp(prefix='harte_batch_')
    try:
        manifest_path = os.path.join(hexdir, 'manifest.txt')
        paths = []
        for i, t in enumerate(tests):
            p = os.path.join(hexdir, f'{i:05d}.hex')
            with open(p, 'w') as f:
                f.write(gen_hex(t))
            paths.append(p)
        with open(manifest_path, 'w') as f:
            f.write('\n'.join(paths) + '\n')

        try:
            result = subprocess.run(
                ['vvp', str(SIM_BIN), f'+manifest={manifest_path}',
                 f'+cycles={cycles}', '+clearmem=0'],
                capture_output=True, text=True, timeout=timeout_s
            )
            out = result.stdout
        except subprocess.TimeoutExpired:
            out = ''   # whole chunk times out -> every test in it reports TIMEOUT below

        blocks = split_batch_output(out)
        rows = []
        for i, t in enumerate(tests):
            regs, writes, status = parse_block(blocks.get(i, []))
            rows.append((t, regs, writes, status))
        return rows
    finally:
        shutil.rmtree(hexdir, ignore_errors=True)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+')
    ap.add_argument('--limit',          type=int, default=None)
    ap.add_argument('--verbose',        action='store_true')
    ap.add_argument('--timeout-cycles', type=int, default=8000)
    ap.add_argument('--chunk-size',     type=int, default=300)
    ap.add_argument('--jobs', '-j',     type=int, default=8,
                    help='parallel vvp batch processes (default 8)')
    args = ap.parse_args()

    if not SIM_BIN.exists():
        print(f"ERROR: {SIM_BIN} not found — run: make sim/harte_batch", file=sys.stderr)
        sys.exit(1)

    total_pass = total_fail = total_skip = total_timeout = 0

    for path in args.files:
        tests = decode_file(path)
        if args.limit:
            tests = tests[:args.limit]

        fname = Path(path).name
        runnable, skip_n = [], 0
        for t in tests:
            ok, _ = can_run(t)
            if ok:
                runnable.append(t)
            else:
                skip_n += 1

        print(f"\n=== {fname} ({len(tests)} tests, {len(runnable)} runnable) ===", flush=True)

        chunks = [runnable[i:i + args.chunk_size]
                  for i in range(0, len(runnable), args.chunk_size)]

        # Generous per-chunk timeout: worst case every test in the chunk
        # burns its full cycle budget. clk_4x period is 10 time units in the
        # testbench's own timescale; empirically ~3ms of wall time per
        # forced-timeout test (measured), so this is a large safety margin,
        # not a tuned estimate.
        chunk_timeout = max(120, len(chunks[0]) * 5) if chunks else 120

        results = []
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futs = [pool.submit(run_chunk, c, args.timeout_cycles, chunk_timeout)
                    for c in chunks]
            for fut in as_completed(futs):
                results.extend(fut.result())

        pass_n = fail_n = timeout_n = 0
        for t, regs, writes, status in results:
            if status == 'timeout':
                timeout_n += 1
                print(f"  TIMEOUT  {t['name']}")
                continue
            fails = compare(t, regs, writes, args.verbose)
            if fails:
                fail_n += 1
                print(f"  FAIL  {t['name']}")
                for f in fails:
                    print(f"           {f}")
            else:
                pass_n += 1

        total_pass    += pass_n
        total_fail    += fail_n + timeout_n
        total_skip    += skip_n
        total_timeout += timeout_n

        run_n = pass_n + fail_n + timeout_n
        pct = (100 * pass_n / run_n) if run_n else 0.0
        print(f"PASS {pass_n}  FAIL {fail_n}  SKIP {skip_n}  TIMEOUT {timeout_n}")
        print(f"{pass_n}/{run_n} passed ({pct:.1f}%)")

    print(f"\n{'='*60}")
    print(f"TOTAL: PASS {total_pass}  FAIL {total_fail}  SKIP {total_skip}  "
          f"TIMEOUT {total_timeout}")

    sys.exit(0 if total_fail == 0 else 1)


if __name__ == '__main__':
    main()

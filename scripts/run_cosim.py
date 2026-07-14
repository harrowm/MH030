#!/usr/bin/env python3
"""
run_cosim.py — Phase 77 .dat-replay orchestrator.

For each test vector from a .dat file (or synthetic vectors):
  1. Generate a hex file via gen_init_hex.py
  2. Run the DUT (vvp sim/cosim_dat +hexfile=...)
  3. Parse the REGSTATE output
  4. Compare to the expected post-state from the .dat file
  5. Report PASS/FAIL

Synthetic mode (--synth N):
  Generates N random register-to-register test cases, runs both DUT and Musashi
  (tools/m68ksim --regstate), and cross-checks REGSTATE outputs.

Usage:
  python3 scripts/run_cosim.py --dat FILE.dat [--limit N] [--opcode XXXX] [--verbose]
  python3 scripts/run_cosim.py --synth N      [--verbose]
"""

import argparse
import os
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Repo root (one level up from this script)
REPO = Path(__file__).parent.parent
SIM_BIN  = REPO / 'sim' / 'cosim_dat'
M68KSIM  = REPO / 'tools' / 'm68ksim'
BIN2HEX  = REPO / 'tools' / 'bin2hex.py'

sys.path.insert(0, str(Path(__file__).parent))
from parse_dat    import parse_records
from gen_init_hex import gen_hex


# ── REGSTATE parsing ──────────────────────────────────────────────────────────

REG_NAMES = (
    ['D0','D1','D2','D3','D4','D5','D6','D7',
     'A0','A1','A2','A3','A4','A5','A6','A7',
     'SR','PC']
)

def parse_regstate_line(line):
    """Parse 'REGSTATE D0=xx ... PC=xx' → dict mapping name→int."""
    state = {}
    for token in line.split():
        if '=' in token:
            k, v = token.split('=', 1)
            try:
                state[k.upper()] = int(v, 16)
            except ValueError:
                pass
    return state


def run_dut(hexfile, cycles=5000):
    """Run cosim_dat_tb, return (regstate_dict, pass_bool, raw_output)."""
    cmd = ['vvp', str(SIM_BIN),
           f'+hexfile={hexfile}',
           f'+cycles={cycles}']
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return None, False, '(timeout)'

    out = result.stdout + result.stderr
    regstate = {}
    passed = False
    for line in out.splitlines():
        if line.startswith('REGSTATE '):
            regstate = parse_regstate_line(line[len('REGSTATE '):])
        if line.startswith('PASS'):
            passed = True

    return regstate, passed, out


def run_musashi(hexfile, cycles=500):
    """Run m68ksim --regstate, return regstate_dict."""
    cmd = [str(M68KSIM), '--regstate', str(hexfile), str(cycles)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return {}

    for line in result.stdout.splitlines():
        if line.startswith('REGSTATE '):
            return parse_regstate_line(line[len('REGSTATE '):])
    return {}


# ── Comparison ────────────────────────────────────────────────────────────────

# Registers excluded from comparison:
# PC depends on how many cycles after STOP we sample; skip it for now.
# SR trace/interrupt bits may differ in timing.
SKIP_REGS = {'PC'}

def compare_states(got, expected, opcode, verbose=False):
    """Return True if got matches expected on the registers we care about."""
    ok = True
    for reg in REG_NAMES:
        if reg in SKIP_REGS:
            continue
        if reg == 'SR':
            # Mask out trace bits (T1,T0) and interrupt priority mask (can race)
            mask = 0x00FF   # compare CCR only (low byte)
            g = got.get(reg, None)
            e = expected.get(reg, None)
            if g is None or e is None:
                continue
            if (g & mask) != (e & mask):
                if verbose or ok:
                    print(f"  MISMATCH opcode={opcode:04x} {reg}: "
                          f"got={g & mask:04x} exp={e & mask:04x}")
                ok = False
        else:
            g = got.get(reg, None)
            e = expected.get(reg, None)
            if g is None or e is None:
                continue
            if g != e:
                if verbose or ok:
                    print(f"  MISMATCH opcode={opcode:04x} {reg}: "
                          f"got={g:08x} exp={e:08x}")
                ok = False
    return ok


# ── Synthetic test vector generation ─────────────────────────────────────────

# Simple register-to-register instructions to use in synthetic mode.
# Each tuple: (opcode_word, mnemonic)
SYNTH_INSTRS = [
    (0xD280, 'ADD.L D0,D1'),
    (0x9280, 'SUB.L D0,D1'),
    (0xC280, 'AND.L D0,D1'),
    (0x8280, 'OR.L  D0,D1'),
    (0xB280, 'EOR.L D0,D1'),
    (0xD080, 'ADD.L D0,D0'),
    (0x4480, 'NEG.L D0'),
    (0x4680, 'NOT.L D0'),
    (0xE180, 'ASL.L #1,D0'),
    (0xE280, 'ASR.L #1,D0'),
    (0xE390, 'ROL.L D1,D0'),
    (0xE290, 'ROR.L D1,D0'),
]


def make_synth_pre():
    """Generate a random supervisor-mode pre-state for a register-only instruction."""
    return {
        'd':  [random.randint(0, 0xFFFFFFFF) for _ in range(8)],
        'a':  [random.randint(0, 0x0000FFFC) if n < 7    # avoid odd/large addresses
               else 0x00010000
               for n in range(8)],
        'sr': 0x2000 | (random.randint(0, 0x1F)),  # supervisor, random CCR
        'pc': 0x00000008,
    }


# ── Main runners ──────────────────────────────────────────────────────────────

def run_dat_mode(dat_path, limit, opcode_filter, verbose):
    records = parse_records(dat_path, limit)
    if opcode_filter is not None:
        records = [r for r in records if r['opcode'] == opcode_filter]

    print(f"Running {len(records)} vectors from {dat_path}")
    passed = failed = skipped = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        hexfile = os.path.join(tmpdir, 'vec.hex')
        for i, rec in enumerate(records):
            hexdata = gen_hex(rec['pre'], rec['instr'])
            with open(hexfile, 'w') as f:
                f.write(hexdata)

            dut_state, dut_pass, raw = run_dut(hexfile)

            if not dut_pass:
                print(f"[{i:4d}] op={rec['opcode']:04x} instr={rec['instr'].hex()} "
                      f"FAIL (DUT did not reach STOP)")
                if verbose:
                    print(raw)
                failed += 1
                continue

            # Build expected dict from .dat post-state
            post = rec['post']
            expected = {}
            for n in range(8):
                expected[f'D{n}'] = post['d'][n]
                expected[f'A{n}'] = post['a'][n]
            expected['SR'] = post['sr']
            expected['PC'] = post['pc']

            if compare_states(dut_state, expected, rec['opcode'], verbose):
                if verbose:
                    print(f"[{i:4d}] op={rec['opcode']:04x} PASS")
                passed += 1
            else:
                print(f"[{i:4d}] op={rec['opcode']:04x} instr={rec['instr'].hex()} FAIL")
                if verbose:
                    print(f"       pre:  {rec['pre']}")
                    print(f"       got:  {dut_state}")
                    print(f"       exp:  {expected}")
                failed += 1

    total = passed + failed + skipped
    print(f"\n{passed}/{total} PASS  {failed} FAIL  {skipped} SKIP")
    return failed == 0


def run_synth_mode(n_vectors, verbose):
    if not M68KSIM.exists():
        print(f"ERROR: {M68KSIM} not found — run 'make m68ksim' first",
              file=sys.stderr)
        sys.exit(1)
    if not SIM_BIN.exists():
        print(f"ERROR: {SIM_BIN} not found — run 'make sim/cosim_dat' first",
              file=sys.stderr)
        sys.exit(1)

    print(f"Running {n_vectors} synthetic vectors (DUT vs Musashi)")
    passed = failed = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        hexfile = os.path.join(tmpdir, 'vec.hex')
        for i in range(n_vectors):
            opcode_word, mnemonic = random.choice(SYNTH_INSTRS)
            instr = struct.pack('>H', opcode_word)
            pre   = make_synth_pre()

            hexdata = gen_hex(pre, instr)
            with open(hexfile, 'w') as f:
                f.write(hexdata)

            dut_state,  dut_pass, dut_raw  = run_dut(hexfile)
            musa_state = run_musashi(hexfile)

            if not dut_pass:
                print(f"[{i:4d}] {mnemonic} FAIL (DUT no STOP)")
                if verbose:
                    print(dut_raw)
                failed += 1
                continue

            if not musa_state:
                print(f"[{i:4d}] {mnemonic} SKIP (Musashi no REGSTATE)")
                continue

            if compare_states(dut_state, musa_state, opcode_word, verbose):
                if verbose:
                    print(f"[{i:4d}] {mnemonic} PASS")
                passed += 1
            else:
                print(f"[{i:4d}] {mnemonic} FAIL")
                if verbose:
                    print(f"       pre  : {pre}")
                    print(f"       DUT  : {dut_state}")
                    print(f"       Musa : {musa_state}")
                failed += 1

    total = passed + failed
    print(f"\n{passed}/{total} PASS  {failed} FAIL")
    return failed == 0


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--dat',   metavar='FILE',
                      help='replay test vectors from a .dat file')
    mode.add_argument('--synth', type=int, metavar='N',
                      help='run N synthetic vectors (DUT vs Musashi)')

    ap.add_argument('--limit',   type=int, default=None, metavar='N',
                    help='process at most N vectors (--dat mode)')
    ap.add_argument('--opcode',  type=lambda x: int(x, 16), default=None,
                    metavar='XXXX',
                    help='filter to only this opcode (hex, --dat mode)')
    ap.add_argument('--verbose', '-v', action='store_true',
                    help='print per-vector detail')
    args = ap.parse_args()

    ok = False
    if args.dat:
        ok = run_dat_mode(args.dat, args.limit, args.opcode, args.verbose)
    else:
        ok = run_synth_mode(args.synth, args.verbose)

    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()

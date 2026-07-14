#!/usr/bin/env python3
"""
parse_dat.py — parse Toni Wilen WinUAE cputest .dat binary test vectors.

Assumed binary format (big-endian):
  4 bytes  : magic / version (u32, ignored)
  4 bytes  : N, number of test records (u32)
  N records:
    70 bytes : pre RegState
    1 byte   : instruction length in bytes (2–10)
    instr_len bytes : instruction (opcode + extension words)
    70 bytes : post RegState

RegState (70 bytes):
  8 × u32  : D0–D7          (32 bytes)
  8 × u32  : A0–A7          (32 bytes)
  u16      : SR             ( 2 bytes)
  u32      : PC             ( 4 bytes)

NOTE: The exact on-disk format is not publicly documented.  If the file does
not parse cleanly, run with --probe to inspect raw bytes and adjust REGSTATE_FMT
and RECORD_LAYOUT below.

Usage:
  python3 scripts/parse_dat.py file.dat [--limit N] [--probe N] [--json]
"""

import struct
import sys
import json
import argparse

# ── Format constants ──────────────────────────────────────────────────────────

REGSTATE_FMT  = '>8I 8I H I'     # D0-D7, A0-A7, SR, PC (no padding word)
REGSTATE_SIZE = struct.calcsize(REGSTATE_FMT)   # must be 70

assert REGSTATE_SIZE == 70, f"RegState size mismatch: {REGSTATE_SIZE}"

HEADER_FMT  = '>II'   # magic, N
HEADER_SIZE = struct.calcsize(HEADER_FMT)   # 8


# ── Helpers ───────────────────────────────────────────────────────────────────

def _parse_regstate(data, offset):
    fields = struct.unpack_from(REGSTATE_FMT, data, offset)
    return {
        'd':  list(fields[0:8]),
        'a':  list(fields[8:16]),
        'sr': fields[16],
        'pc': fields[17],
    }, offset + REGSTATE_SIZE


def parse_records(path, limit=None):
    """Return list of dicts: {opcode, instr (bytes), pre, post}."""
    with open(path, 'rb') as f:
        data = f.read()

    if len(data) < HEADER_SIZE:
        raise ValueError(f"{path}: file too small ({len(data)} bytes)")

    _magic, n_records = struct.unpack_from(HEADER_FMT, data, 0)
    offset = HEADER_SIZE

    if limit is not None:
        n_records = min(n_records, limit)

    records = []
    for i in range(n_records):
        if offset + REGSTATE_SIZE + 1 > len(data):
            print(f"[parse_dat] warning: truncated at record {i}/{n_records}",
                  file=sys.stderr)
            break

        pre, offset = _parse_regstate(data, offset)

        instr_len = data[offset]; offset += 1
        if instr_len < 2 or instr_len > 10 or instr_len % 2 != 0:
            print(f"[parse_dat] warning: unusual instr_len={instr_len} at record {i}; "
                  f"file offset {offset-1:#x}", file=sys.stderr)

        instr = data[offset:offset + instr_len]; offset += instr_len

        if offset + REGSTATE_SIZE > len(data):
            print(f"[parse_dat] warning: post-state truncated at record {i}",
                  file=sys.stderr)
            break

        post, offset = _parse_regstate(data, offset)

        opcode = struct.unpack_from('>H', instr, 0)[0]
        records.append({
            'opcode': opcode,
            'instr':  instr,
            'pre':    pre,
            'post':   post,
        })

    return records


def probe(path, n_records=4):
    """Dump raw bytes of the first n_records to help diagnose format mismatches."""
    with open(path, 'rb') as f:
        data = f.read()

    print(f"File size: {len(data)} bytes")
    header_bytes = data[:8]
    print(f"Header: {header_bytes.hex()}")
    magic, count = struct.unpack_from('>II', data, 0)
    print(f"  magic=0x{magic:08x}  count={count}")
    print()

    offset = 8
    for i in range(min(n_records, count)):
        print(f"--- Record {i} (offset 0x{offset:x}) ---")
        chunk = data[offset:offset + REGSTATE_SIZE + 1 + 10 + REGSTATE_SIZE]
        print(f"  raw[0:16]: {chunk[:16].hex()}")
        try:
            pre, o2 = _parse_regstate(data, offset)
            print(f"  pre D0={pre['d'][0]:08x}  A0={pre['a'][0]:08x}"
                  f"  SR={pre['sr']:04x}  PC={pre['pc']:08x}")
            instr_len = data[o2]; o2 += 1
            instr = data[o2:o2 + instr_len]; o2 += instr_len
            print(f"  instr_len={instr_len}  bytes={instr.hex()}")
            post, _ = _parse_regstate(data, o2)
            print(f"  post D0={post['d'][0]:08x}  A0={post['a'][0]:08x}"
                  f"  SR={post['sr']:04x}  PC={post['pc']:08x}")
            record_size = REGSTATE_SIZE + 1 + instr_len + REGSTATE_SIZE
            offset += record_size
        except Exception as e:
            print(f"  parse error: {e}")
            break
        print()


def regstate_str(rs):
    """One-line human-readable dump of a RegState dict."""
    d = ' '.join(f'D{i}={v:08x}' for i, v in enumerate(rs['d']))
    a = ' '.join(f'A{i}={v:08x}' for i, v in enumerate(rs['a']))
    return f"{d} {a} SR={rs['sr']:04x} PC={rs['pc']:08x}"


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('datfile', nargs='?', help='.dat file to parse')
    ap.add_argument('--limit',  type=int, default=None, metavar='N',
                    help='process at most N records')
    ap.add_argument('--probe',  type=int, default=None, metavar='N',
                    help='dump raw bytes for first N records and exit')
    ap.add_argument('--json',   action='store_true',
                    help='emit JSON instead of text')
    args = ap.parse_args()

    if not args.datfile:
        ap.print_help(); sys.exit(1)

    if args.probe is not None:
        probe(args.datfile, args.probe)
        return

    records = parse_records(args.datfile, args.limit)

    if args.json:
        out = []
        for r in records:
            out.append({
                'opcode': r['opcode'],
                'instr':  r['instr'].hex(),
                'pre':    r['pre'],
                'post':   r['post'],
            })
        print(json.dumps(out, indent=2))
    else:
        print(f"Parsed {len(records)} records from {args.datfile}")
        for i, r in enumerate(records[:20]):
            print(f"[{i:4d}] op={r['opcode']:04x}  instr={r['instr'].hex()}")
            print(f"       pre:  {regstate_str(r['pre'])}")
            print(f"       post: {regstate_str(r['post'])}")


if __name__ == '__main__':
    main()

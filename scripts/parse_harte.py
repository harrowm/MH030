#!/usr/bin/env python3
"""
parse_harte.py — decode Tom Harte / SingleStepTests m68000 .json.bin files.

Binary format documented by the repo's decode.py:
  File header: magic=0x1A3F5D71, num_tests (both u32 LE)
  Per test:    magic=0xABC12367, size; name block; initial state; final state; transactions

State fields: d0-d7, a0-a6, usp, ssp, sr, pc, prefetch[2], ram[]
  ram[] entries: [(byte_addr, byte_value), ...]  — always byte-granular
Transaction fields: [kind, cycles, fc, addr, width, data, uds, lds]
  kind: 'r' read, 'w' write, 't' TAS, 're'/'we' address-error, 'n' no-op

Usage:
  python3 scripts/parse_harte.py tests/harte/ADD.b.json.bin [--limit N] [--probe IDX]
"""

import sys
import json
import struct
import argparse
from pathlib import Path
from struct import unpack_from


# ── Binary format constants ───────────────────────────────────────────────────

MAGIC_FILE   = 0x1A3F5D71
MAGIC_TEST   = 0xABC12367
MAGIC_NAME   = 0x89ABCDEF
MAGIC_STATE  = 0x01234567
MAGIC_TRANS  = 0x456789AB

REG_ORDER = ['d0','d1','d2','d3','d4','d5','d6','d7',
             'a0','a1','a2','a3','a4','a5','a6','usp',
             'ssp','sr','pc']


# ── Low-level readers ─────────────────────────────────────────────────────────

def _read_name(content, ptr):
    _nbytes, magic = unpack_from('<II', content, ptr); ptr += 8
    assert magic == MAGIC_NAME, f"bad name magic {magic:#010x}"
    strlen = unpack_from('<I', content, ptr)[0]; ptr += 4
    name = unpack_from(f'{strlen}s', content, ptr)[0].decode('utf-8'); ptr += strlen
    return ptr, name


def _read_state(content, ptr):
    _nbytes, magic = unpack_from('<II', content, ptr); ptr += 8
    assert magic == MAGIC_STATE, f"bad state magic {magic:#010x}"
    st = {}
    for reg in REG_ORDER:
        st[reg] = unpack_from('<I', content, ptr)[0]; ptr += 4
    pf0, pf1 = unpack_from('<II', content, ptr); ptr += 8
    st['prefetch'] = [pf0, pf1]
    num_ram = unpack_from('<I', content, ptr)[0]; ptr += 4
    st['ram'] = []
    for _ in range(num_ram):
        addr, data16 = unpack_from('<IH', content, ptr); ptr += 6
        # Each record encodes one 16-bit word as two byte entries
        st['ram'].append([addr,     (data16 >> 8) & 0xFF])
        st['ram'].append([addr | 1, data16 & 0xFF])
    return ptr, st


def _read_transactions(content, ptr):
    _nbytes, magic = unpack_from('<II', content, ptr); ptr += 8
    assert magic == MAGIC_TRANS, f"bad txn magic {magic:#010x}"
    num_cycles, num_txn = unpack_from('<II', content, ptr); ptr += 8
    txns = []
    for _ in range(num_txn):
        tw, cycles = unpack_from('<BI', content, ptr); ptr += 5
        if tw == 0:
            txns.append({'kind': 'n', 'cycles': cycles})
            continue
        fc, addr, data, uds, lds = unpack_from('<IIIII', content, ptr); ptr += 20
        width = '.w' if (uds + lds) == 2 else '.b'
        kind  = {1: 'w', 2: 'r', 3: 't', 4: 're', 5: 'we'}.get(tw, '?')
        txns.append({'kind': kind, 'cycles': cycles, 'fc': fc,
                     'addr': addr, 'data': data, 'width': width,
                     'uds': uds, 'lds': lds})
    return ptr, txns, num_cycles


def _read_test(content, ptr):
    _nbytes, magic = unpack_from('<II', content, ptr)
    assert magic == MAGIC_TEST, f"bad test magic {magic:#010x}"
    ptr += 8
    ptr, name         = _read_name(content, ptr)
    ptr, initial      = _read_state(content, ptr)
    ptr, final        = _read_state(content, ptr)
    ptr, txns, length = _read_transactions(content, ptr)
    return ptr, {'name': name, 'initial': initial, 'final': final,
                 'transactions': txns, 'length': length}


# ── Public API ────────────────────────────────────────────────────────────────

def decode_file(path):
    """Decode a .json.bin file and return list of test dicts."""
    content = Path(path).read_bytes()
    magic, num_tests = unpack_from('<II', content, 0)
    assert magic == MAGIC_FILE, f"bad file magic {magic:#010x}"
    ptr = 8
    tests = []
    for _ in range(num_tests):
        ptr, test = _read_test(content, ptr)
        tests.append(test)
    return tests


# ── CLI ───────────────────────────────────────────────────────────────────────

def _fmt_state(st):
    regs = ' '.join(f"{r}={st[r]:#010x}" for r in REG_ORDER)
    ram  = ' '.join(f"[{a:#08x}]={v:#04x}" for a,v in st['ram'][:8])
    ram_suffix = f" +{len(st['ram'])-8} more" if len(st['ram']) > 8 else ''
    return f"  regs: {regs}\n  ram:  {ram}{ram_suffix}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file', help='.json.bin file to decode')
    ap.add_argument('--limit', type=int, default=5, help='tests to print (default 5)')
    ap.add_argument('--probe', type=int, default=None, help='print full detail for test IDX')
    ap.add_argument('--count', action='store_true', help='just print total test count')
    args = ap.parse_args()

    tests = decode_file(args.file)

    if args.count:
        print(f"{len(tests)} tests in {args.file}")
        return

    if args.probe is not None:
        t = tests[args.probe]
        print(json.dumps(t, indent=2))
        return

    for i, t in enumerate(tests[:args.limit]):
        pc0 = t['initial']['pc']
        pcf = t['final']['pc']
        print(f"[{i:4d}] {t['name']}  pc:{pc0:#010x}→{pcf:#010x}"
              f"  instr_len={pcf-pc0}  ram_in={len(t['initial']['ram'])/2:.0f}w"
              f"  ram_out={len(t['final']['ram'])/2:.0f}w"
              f"  txns={len(t['transactions'])}")
        print(f"       initial sr={t['initial']['sr']:#06x}"
              f"  final sr={t['final']['sr']:#06x}"
              f"  prefetch=[{t['initial']['prefetch'][0]:#06x},{t['initial']['prefetch'][1]:#06x}]")


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""tools/buscmp.py — Phase 75: compare DUT and reference bus cycle logs.

Usage:
    python tools/buscmp.py <dut.log> <ref.log> [options]

Options:
    --skip N          Skip the first N cycles of BOTH logs (default 0).
    --skip-dut N      Skip the first N cycles of the DUT log only.
    --skip-ref N      Skip the first N cycles of the reference log only.
    --reads-only      Ignore BUS W lines (DUT may produce spurious writes
                      after STOP while the reference does not).
    --addr-mask HEX   AND address with mask before comparing, e.g. 0x000FFFFF
                      strips the upper bits so WinUAE ROM addresses ($FCxxxx)
                      compare equal to testbench addresses ($00xxxx).
    --max N           Compare at most N cycles then stop (default unlimited).
    --dut-may-continue
                      Allow DUT to have extra cycles beyond the reference end
                      (IFU prefetch after STOP/RTS is expected). Exit 0 when
                      all reference cycles matched, even if DUT has more.
    --allow-adjacent-swap
                      Phase 160 Stage 1: tolerate two ADJACENT, INDEPENDENT
                      bus cycles appearing in swapped relative order (i.e.
                      DUT[i]==REF[i+1] and DUT[i+1]==REF[i] exactly) without
                      failing. This is the same benign "prefetch race" this
                      project has hand-verified many times since Phase 115
                      (an IFU readahead prefetch and a data read/write that
                      don't depend on each other can legitimately interleave
                      either way depending on exact relative bus timing) --
                      it does not mask a genuine data-value mismatch, since
                      it only fires on an EXACT transposition of the next
                      cycle, never a value substitution.

Exit codes:
    0  All compared cycles match.
    1  Mismatch found (details printed to stdout).
    2  Logs differ in length after skipping (unless --dut-may-continue).
    3  Usage error.

Log format (one line per bus cycle):
    BUS R 00000008 4e71702a fc=110 siz=10
    BUS W 00001000 deadbeef fc=101 siz=00
"""

import sys
import re
import argparse


_LINE_RE = re.compile(
    r'^BUS\s+(R|W)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+fc=([01]+)\s+siz=([01]+)'
)


def parse_log(path, skip=0, reads_only=False, addr_mask=None, max_cycles=None):
    """Return list of (rw, addr, data, fc, siz) tuples."""
    cycles = []
    skipped = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            m = _LINE_RE.match(line)
            if not m:
                continue
            rw, addr_s, data_s, fc_s, siz_s = m.groups()
            if reads_only and rw == 'W':
                continue
            if skipped < skip:
                skipped += 1
                continue
            raw_addr = int(addr_s, 16)
            addr = raw_addr
            if addr_mask is not None:
                addr &= addr_mask
            data = int(data_s, 16)
            # Stage 9c fix (plan.md §Phase 245): the DUT's own bus trace
            # reflects the REAL 32-bit D[31:0] pin state for byte/word
            # transfers, not just the meaningful value -- for WRITES,
            # biu_byte_lane_ctrl.sv replicates the byte/word across all four
            # lanes (real 68030 pin-level behavior, per its own header
            # comment: "so that a peripheral reading D[31:0] sees the
            # byte/word on the correct pins"); for READS, the OTHER lanes
            # simply carry whatever else happens to be in the addressed
            # word's neighboring bytes (this testbench's own memory model
            # returns the whole containing longword regardless of siz).
            # Musashi's own reference log (tools/m68ksim.c) instead always
            # prints just the canonical value with a size-matched field
            # width (%02x/%04x/%08x for byte/word/longword) -- genuinely
            # "the byte value" or "the word value," never a 32-bit pin
            # trace at all, so its own field is NEVER wider than the
            # transfer size and needs no shift. The DUT's own $display
            # always uses Verilog's %h on a [31:0] signal, which
            # unconditionally pads to 8 hex digits regardless of value --
            # that field-width difference is what distinguishes the two
            # log conventions here (data_s's own captured string length),
            # not which file is being parsed (both dut and ref go through
            # this same function). Every prior full (non-reads-only) bus
            # comparison test happened to only ever compare LONGWORD
            # transfers, where this never mattered -- found via a genuine
            # TAS-via-memind cosim mismatch, the first test to full-compare
            # a genuine byte READ (and separately, a byte WRITE) via this
            # tool. Fixed by extracting the real, address-aligned
            # big-endian byte/word LANE from the wide (DUT-style) field
            # only (not just masking the low bits, since a byte at an odd
            # address or a word at addr&2!=0 lives in the UPPER lanes, not
            # the lower ones) and zero-extending it the same way Musashi's
            # own narrow field already is -- a genuine wrong data VALUE in
            # that same lane is still caught exactly as before.
            if siz_s == '01' and len(data_s) > 2:
                shift = (3 - (raw_addr & 3)) * 8
                data = (data >> shift) & 0xFF
            elif siz_s == '10' and len(data_s) > 4:
                shift = 16 if (raw_addr & 2) == 0 else 0
                data = (data >> shift) & 0xFFFF
            cycles.append((rw, addr, data, fc_s, siz_s))
            if max_cycles and len(cycles) >= max_cycles:
                break
    return cycles


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('dut', help='DUT bus log (from Verilog $display)')
    p.add_argument('ref', help='Reference bus log (from tools/m68ksim or WinUAE)')
    p.add_argument('--skip',      type=int, default=0,    metavar='N')
    p.add_argument('--skip-dut',  type=int, default=0,    metavar='N')
    p.add_argument('--skip-ref',  type=int, default=0,    metavar='N')
    p.add_argument('--reads-only', action='store_true')
    p.add_argument('--addr-mask', type=lambda x: int(x, 16), default=None, metavar='HEX')
    p.add_argument('--max',       type=int, default=None, metavar='N')
    p.add_argument('--dut-may-continue', action='store_true',
                   help='Allow DUT to have extra trailing cycles (IFU prefetch after halt)')
    p.add_argument('--allow-adjacent-swap', action='store_true',
                   help='Tolerate two adjacent cycles appearing in swapped order')
    args = p.parse_args()

    dut = parse_log(args.dut, skip=args.skip + args.skip_dut,
                    reads_only=args.reads_only, addr_mask=args.addr_mask,
                    max_cycles=args.max)
    ref = parse_log(args.ref, skip=args.skip + args.skip_ref,
                    reads_only=args.reads_only, addr_mask=args.addr_mask,
                    max_cycles=args.max)

    ctx = 5  # context lines before/after mismatch
    n_common = min(len(dut), len(ref))
    swapped_at = set()

    i = 0
    while i < n_common:
        d, r = dut[i], ref[i]
        if d != r:
            if (args.allow_adjacent_swap and i + 1 < n_common and
                    dut[i] == ref[i + 1] and dut[i + 1] == ref[i]):
                swapped_at.add(i + 1)  # 1-indexed cycle number of the pair's first line
                i += 2
                continue
            print(f"FAIL  mismatch at cycle {i+1}:")
            lo = max(0, i - ctx)
            hi = min(len(dut), len(ref), i + ctx + 1)
            for j in range(lo, hi):
                marker_d = '>>' if j == i else '  '
                marker_r = '>>' if j == i else '  '
                rd = dut[j] if j < len(dut) else None
                rr = ref[j] if j < len(ref) else None
                fmt = lambda c: (f"BUS {c[0]} {c[1]:08x} {c[2]:08x} fc={c[3]} siz={c[4]}"
                                 if c else '<missing>')
                print(f"  DUT{marker_d} [{j+1:4d}] {fmt(rd)}")
                print(f"  REF{marker_r} [{j+1:4d}] {fmt(rr)}")
            sys.exit(1)
        i += 1

    if swapped_at:
        print(f"NOTE  {len(swapped_at)} adjacent-swap pair(s) tolerated at cycle(s) "
              f"{sorted(swapped_at)}")

    n_dut, n_ref = len(dut), len(ref)
    if n_dut != n_ref:
        if args.dut_may_continue and n_dut > n_ref:
            print(f"OK    {n_ref} cycles match (DUT has {n_dut - n_ref} extra trailing cycles)")
            sys.exit(0)
        print(f"FAIL  length mismatch: DUT={n_dut} cycles, REF={n_ref} cycles")
        if n_dut > n_ref:
            extra = dut[n_ref:n_ref + ctx]
        else:
            extra = ref[n_dut:n_dut + ctx]
        for c in extra:
            print(f"  extra: BUS {c[0]} {c[1]:08x} {c[2]:08x} fc={c[3]} siz={c[4]}")
        sys.exit(2)

    print(f"OK    {n_dut} cycles match")
    sys.exit(0)


if __name__ == '__main__':
    main()

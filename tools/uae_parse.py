#!/usr/bin/env python3
"""Phase 74: Parse WinUAE log output → standard BUS R/W format.

Output format (matches cosim73_tb.sv bus logger):
    BUS R <addr32hex> <data32hex> fc=<3b> siz=<2b>
    BUS W <addr32hex> <data32hex> fc=<3b> siz=<2b>

WinUAE log format varies by version and debug settings.  This parser
tries several known patterns in priority order.  Unknown lines are
silently skipped.

Run:
    python3 tools/uae_parse.py <raw.log> [out.log]

With no output file, writes to stdout.  Unrecognised log content is
reported to stderr so it can be used to add new patterns.

Address note:
    WinUAE fetches smoke test code from $FC0008+ (ROM space).
    The DUT testbench fetches the same code from $0008+ (RAM).
    buscmp.py (Phase 75) strips the ROM-base offset before comparing.
"""
import sys, re, pathlib

# ── Pattern library ─────────────────────────────────────────────────────────
# Each entry: (compiled_re, rw_group, sz_group, addr_group, data_group)
# If a group name is None, use a fixed default.

PATTERNS = [
    # WinUAE cycle-exact CPU log (CE mode):
    #   "CE: R.W 00FC0008 4E71"
    #   "CE: W.L 00010000 00000000"
    re.compile(
        r'\bCE:\s*(?P<rw>[RW])\.(?P<sz>[BWL])\s+'
        r'(?P<addr>[0-9A-Fa-f]{6,8})\s+(?P<data>[0-9A-Fa-f]{1,8})',
        re.IGNORECASE),

    # WinUAE mc68030 bus log:
    #   "MC68030 READ.W @$00FC0008 = $4E71"
    #   "MC68030 WRITE.L @$00010000 = $DEADBEEF"
    re.compile(
        r'(?:MC68030|M68030|cpu)\s+'
        r'(?P<rw>READ|WRITE)\.(?P<sz>[BWL])\s*'
        r'@?\$?(?P<addr>[0-9A-Fa-f]{6,8})\s*[->=]+\s*\$?(?P<data>[0-9A-Fa-f]{1,8})',
        re.IGNORECASE),

    # UAE memory-access style:
    #   "get_word(0x00FC0008) -> 0x4E71"
    #   "put_long(0x00010000) <- 0x00000000"
    re.compile(
        r'(?P<rw>get|put)_(?P<sz>byte|word|long)'
        r'\s*\(\s*(?:0x)?(?P<addr>[0-9A-Fa-f]{1,8})\s*\)'
        r'\s*(?:->|<-|=)\s*(?:0x)?(?P<data>[0-9A-Fa-f]{1,8})',
        re.IGNORECASE),

    # WinUAE debug console instruction fetch (when use_debugger=true + T command):
    #   "00FC0008 4E71   NOP"
    # Captures only the address and first opcode word; marks as instruction fetch (R, siz=10)
    re.compile(
        r'^(?P<addr>[0-9A-Fa-f]{6,8})\s+(?P<data>[0-9A-Fa-f]{4})\s+\S',
        re.IGNORECASE | re.MULTILINE),
]

# Fixed-field mappings
RW_MAP = {
    'r': 'R', 'read': 'R', 'get': 'R',
    'w': 'W', 'write': 'W', 'put': 'W',
}
SZ_MAP = {
    'b': '01', 'byte': '01',
    'w': '10', 'word': '10',
    'l': '00', 'long': '00',
}
DEFAULT_SZ  = '10'   # word — typical for instruction fetches
DEFAULT_FC  = '110'  # supervisor program space


def _parse_line(line: str):
    """Return (rw, sz_bits, addr32, data32, fc) or None."""
    for pat in PATTERNS:
        m = pat.search(line)
        if not m:
            continue
        gd = m.groupdict()
        rw   = RW_MAP.get(gd['rw'].lower(), 'R')
        sz   = SZ_MAP.get(gd['sz'].lower(), DEFAULT_SZ)
        addr = int(gd['addr'], 16) & 0xFFFFFFFF
        data = int(gd['data'], 16) & 0xFFFFFFFF
        # Pad data to full 32-bit based on size
        if sz == '01':   data &= 0xFF
        elif sz == '10': data &= 0xFFFF
        return rw, sz, f'{addr:08X}', f'{data:08X}', DEFAULT_FC
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(f'usage: {sys.argv[0]} <raw.log> [out.log]')

    raw_path = pathlib.Path(sys.argv[1])
    if not raw_path.exists():
        sys.exit(f'file not found: {raw_path}')

    out = open(sys.argv[2], 'w') if len(sys.argv) >= 3 else sys.stdout
    lines = raw_path.read_text(errors='replace').splitlines()

    count = 0
    unknown = []
    for line in lines:
        result = _parse_line(line)
        if result:
            rw, sz, addr, data, fc = result
            out.write(f'BUS {rw} {addr} {data} fc={fc} siz={sz}\n')
            count += 1
        elif line.strip() and not line.startswith(('---', '===')):
            unknown.append(line)

    if out is not sys.stdout:
        out.close()

    print(f'Parsed {count} bus transactions from {len(lines)} log lines.',
          file=sys.stderr)
    if count == 0 and unknown:
        print('WARNING: no bus transactions found. First 20 unmatched lines:',
              file=sys.stderr)
        for ln in unknown[:20]:
            print(f'  {ln}', file=sys.stderr)
        print('\nAdd a new pattern to PATTERNS in tools/uae_parse.py to handle '
              'this WinUAE log format.', file=sys.stderr)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
timing_tables.py — Phase 161 Part A: machine-readable transcription of
MC68030UM.pdf Section 11's own instruction-timing tables, read directly from
the manual (PDF pages 489-527 covering §11.6.1-11.6.18, offset = manual page
+ 463 within this project's own copy).

Each table is a dict: address-mode-string -> (head, tail, icache_total,
icache_r, icache_p, icache_w, nocache_total, nocache_r, nocache_p, nocache_w).
head/tail of None means '—' (register-direct forms, no EA calculation at
all). This project's own r/p/w sweep (scripts/run_timing.py) only ever
checks the No-Cache Case (NCC) columns, since every existing testbench in
this project runs with the I-cache disabled (CACR=0) -- matching every prior
verification method's own convention (Harte, cosim, stall/hazard).

Only the No-Cache (r, p, w) tuple is exposed via the NCC_RPW helper below;
the rest of each row is kept for completeness / a future I-cache-enabled
sweep, not currently exercised.
"""

# ── 11.6.1 Fetch Effective Address (fea) — PDF 489-490, manual 11-26/11-27 ──
# "The fetch effective address table indicates the number of clock periods
# needed for the processor to calculate AND FETCH the specified effective
# address." Used by instructions with a footnote '*' = "Add Fetch Effective
# Address Time" (e.g. MOVE EA,Dn).
FEA = {
    'Dn':                       (None, None, 0,  0,0,0,  0,  0,0,0),
    'An':                       (None, None, 0,  0,0,0,  0,  0,0,0),
    '(An)':                     (1, 1,   3, 1,0,0,   3, 1,0,0),
    '(An)+':                    (0, 1,   3, 1,0,0,   3, 1,0,0),
    '-(An)':                    (2, 2,   4, 1,0,0,   4, 1,0,0),
    '(d16,An)':                 (2, 2,   4, 1,0,0,   4, 1,0,0),
    '(xxx).W':                  (2, 2,   4, 1,0,0,   4, 1,0,0),
    '(xxx).L':                  (1, 0,   4, 1,0,0,   5, 1,1,0),
    '#(data).B':                (2, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).W':                (2, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).L':                (4, 0,   4, 0,0,0,   4, 0,1,0),
    # Brief format extension word
    '(d8,An,Xn)':               (4, 2,   6, 1,0,0,   6, 1,1,0),
    # Full format extension word(s)
    '(d16,An)_full':            (2, 0,   6, 1,0,0,   7, 1,1,0),
    '(d16,An,Xn)_full':         (4, 0,   6, 1,0,0,   7, 1,1,0),
    '([d16,An])':               (2, 0,  10, 2,0,0,  10, 2,1,0),
    '([d16,An],Xn)':            (2, 0,  12, 2,0,0,  13, 2,2,0),
    '([d16,An],d16)':           (2, 0,  12, 2,0,0,  13, 2,2,0),
    '([d16,An],Xn,d16)':        (2, 0,  14, 2,0,0,  15, 2,2,0),
    '([d16,An],d32)':           (2, 0,  12, 2,0,0,  14, 2,2,0),
    '([d16,An],Xn,d32)':        (2, 0,  12, 2,0,0,  14, 2,2,0),
    '(B)':                      (4, 0,   6, 1,0,0,   7, 1,1,0),
    '(d16,B)':                  (4, 0,   8, 1,0,0,  10, 1,1,0),
    '(d32,B)':                  (4, 0,  12, 1,0,0,  13, 1,2,0),
    '([B])':                    (4, 0,  10, 2,0,0,  10, 2,1,0),
    '([B],I)':                  (4, 0,  10, 1,0,0,  11, 1,1,0),
    '([B],d16)':                (4, 0,  12, 1,0,0,  13, 2,1,0),
    '([B],I,d16)':               (4, 0,  12, 1,0,0,  13, 2,1,0),
    '([B],d32)':                (4, 0,  12, 2,0,0,  14, 2,2,0),
    '([B],I,d32)':               (4, 0,  12, 2,0,0,  14, 2,2,0),
    '(d16,B])':                 (4, 0,  12, 2,0,0,  13, 2,1,0),
    '(d16,B],I)':                (4, 0,  12, 2,0,0,  13, 2,1,0),
    '(d16,B],d16)':              (4, 0,  14, 2,0,0,  16, 2,2,0),
    '(d16,B],I,d16)':            (4, 0,  14, 2,0,0,  16, 2,2,0),
    '(d16,B],d32)':              (4, 0,  14, 2,0,0,  17, 2,2,0),
    '(d16,B],I,d32)':            (4, 0,  14, 2,0,0,  17, 2,2,0),
    '(d32,B])':                 (4, 0,  16, 2,0,0,  17, 2,2,0),
    '(d32,B],I)':                (4, 0,  16, 2,0,0,  17, 2,2,0),
    '(d32,B],d16)':              (4, 0,  18, 2,0,0,  20, 2,2,0),
    '(d32,B],I,d16)':            (4, 0,  18, 2,0,0,  20, 2,2,0),
    '(d32,B],d32)':              (4, 0,  18, 2,0,0,  21, 2,3,0),
    '(d32,B],I,d32)':            (4, 0,  18, 2,0,0,  21, 2,3,0),
}

# ── 11.6.2 Fetch Immediate Effective Address (fiea) — PDF 491-494 ──────────
# "...fetch the immediate SOURCE operand and to calculate and fetch the
# specified DESTINATION operand." Transcribed for completeness; exercised
# via footnote by later instruction tables (e.g. ADD #imm,EA), not swept
# standalone in Stage A1 (no single opcode isolates fiea alone the way
# 'MOVE EA,Dn' isolates fea).
FIEA = {
    '#(data).W,Dn':             (None, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).L,Dn':             (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).W,(An)':           (1, 1,   3, 1,0,0,   4, 1,1,0),
    '#(data).L,(An)':           (1, 0,   4, 1,0,0,   5, 1,1,0),
    '#(data).W,(An)+':          (2, 1,   5, 1,0,0,   5, 1,1,0),
    '#(data).L,(An)+':          (4, 1,   7, 1,0,0,   7, 1,1,0),
    '#(data).W,-(An)':          (2, 2,   4, 1,0,0,   4, 1,1,0),
    '#(data).L,-(An)':          (2, 0,   4, 1,0,0,   5, 1,1,0),
    '#(data).W,(d16,An)':       (2, 0,   6, 1,0,0,   8, 1,2,0),
    '#(data).L,(d16,An)':       (4, 0,   6, 1,0,0,   8, 1,1,0),
    '#(data).W,$XXX.W':         (4, 0,   6, 1,0,0,   6, 1,1,0),
    '#(data).L,$XXX.W':         (6, 0,   8, 1,0,0,   8, 1,2,0),
    '#(data).W,$XXX.L':         (3, 0,   6, 1,0,0,   7, 1,2,0),
    '#(data).L,$XXX.L':         (5, 0,   8, 1,0,0,   9, 1,2,0),
    '#(data).W,#(data).L':      (None, 0,   6, 0,0,0,   6, 0,2,0),
    # Brief format extension word
    '#(data).W,(d8,An,Xn)':     (6, 2,   8, 1,0,0,   8, 1,2,0),
    '#(data).L,(d8,An,Xn)':     (8, 2,  10, 1,0,0,  10, 1,2,0),
    # Full format extension word(s) -- only the shallowest few transcribed;
    # deep memory-indirect fiea variants deferred, same rationale as FEA.
    '#(data).W,(d16,An)_full':  (4, 0,   8, 1,0,0,   9, 1,2,0),
    '#(data).L,(d16,An)_full':  (6, 0,  10, 1,0,0,  11, 1,2,0),
    '#(data).W,(d16,An,Xn)_full': (6, 0,   8, 1,0,0,   9, 1,2,0),
    '#(data).L,(d16,An,Xn)_full': (8, 0,  10, 1,0,0,  11, 1,2,0),
}

# ── 11.6.3 Calculate Effective Address (cea) — PDF 494-495 ─────────────────
# "...calculate the specified effective address" (no data fetch -- unlike
# fea, this is address computation ONLY, e.g. for LEA/PEA-style consumers
# and MOVE's own destination side). Transcribed for completeness; exercised
# via footnote by MOVE (§11.6.6, destination side) and elsewhere.
CEA = {
    'Dn':                (None, None, 0, 0,0,0,  0, 0,0,0),
    'An':                (None, None, 0, 0,0,0,  0, 0,0,0),
    '(An)':               (None, 0,   2, 0,0,0,  2, 0,0,0),
    '(An)+':              (0,    0,   2, 0,0,0,  2, 0,0,0),
    '-(An)':              (None, 0,   2, 0,0,0,  2, 0,0,0),
    '(d16,An)':           (None, 0,   2, 0,0,0,  2, 0,1,0),
    '(xxx).W':            (None, 0,   2, 0,0,0,  2, 0,1,0),
    '(xxx).L':            (None, 0,   4, 0,0,0,  4, 0,1,0),
    # Brief format extension word
    '(d8,An,Xn)':          (None, 0,   4, 0,0,0,  4, 0,1,0),
    # Full format extension word(s)
    '(d16,An)_full':       (2, 0,   6, 0,0,0,   6, 0,1,0),
    '(d16,An,Xn)_full':    (None, 0,   6, 0,0,0,   6, 0,1,0),
    '([d16,An])':          (2, 0,  10, 1,0,0,  10, 1,1,0),
    '([d16,An],Xn)':       (2, 0,  10, 1,0,0,  10, 1,1,0),
    '([d16,An],d16)':      (2, 0,  12, 1,0,0,  13, 1,2,0),
    '([d16,An],Xn,d16)':   (2, 0,  12, 1,0,0,  13, 1,2,0),
    '([d16,An],d32)':      (2, 0,  12, 1,0,0,  13, 1,2,0),
    '([d16,An],Xn,d32)':   (2, 0,  12, 2,0,0,  13, 1,2,0),
    '(B)':                 (None, 0,   6, 0,0,0,   6, 0,1,0),
    '(d16,B)':              (4, 0,   8, 0,0,0,   9, 0,2,0),
    '(d32,B)':              (4, 0,  12, 0,0,0,  12, 0,2,0),
    '([B])':                (4, 0,  10, 1,0,0,  10, 1,1,0),
    '([B],I)':               (4, 0,  10, 1,0,0,  10, 1,1,0),
    '([B],d16)':             (4, 0,  12, 1,0,0,  13, 1,1,0),
    '([B],I,d16)':            (4, 0,  12, 1,0,0,  13, 1,1,0),
    '([B],d32)':             (4, 0,  12, 1,0,0,  13, 1,2,0),
    '([B],I,d32)':            (4, 0,  12, 2,0,0,  13, 1,2,0),
    '(d16,B])':              (4, 0,  12, 1,0,0,  13, 1,1,0),
    '(d16,B],I)':             (4, 0,  12, 1,0,0,  13, 1,1,0),
    '(d16,B],d16)':           (4, 0,  14, 1,0,0,  16, 1,2,0),
    '(d16,B],I,d16)':         (4, 0,  14, 1,0,0,  16, 1,2,0),
    '(d16,B],d32)':           (4, 0,  14, 1,0,0,  16, 1,2,0),
    '(d16,B],I,d32)':         (4, 0,  14, 1,0,0,  16, 1,2,0),
    '(d32,B])':              (4, 0,  16, 1,0,0,  17, 1,2,0),
    '(d32,B],I)':             (4, 0,  16, 1,0,0,  17, 1,2,0),
    '(d32,B],d16)':           (4, 0,  18, 1,0,0,  20, 1,2,0),
    '(d32,B],I,d16)':         (4, 0,  18, 1,0,0,  20, 1,2,0),
    '(d32,B],d32)':           (4, 0,  18, 1,0,0,  20, 1,3,0),
    '(d32,B],I,d32)':         (4, 0,  18, 1,0,0,  20, 1,3,0),
}

# ── 11.6.4 Calculate Immediate Effective Address (ciea) — PDF 495-499 ──────
# Analogous to cea but for the 2-word #(data),EA case (immediate source,
# calculated-only destination). Transcribed for completeness; not swept
# standalone.
CIEA = {
    '#(data).W,Dn':          (None, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).L,Dn':          (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).W,(An)':        (None, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).L,(An)':        (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).W,(An)+':        (2, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).L,(An)+':        (4, 0,   6, 0,0,0,   6, 0,1,0),
    '#(data).W,-(An)':        (None, 0,   2, 0,0,0,   2, 0,1,0),
    '#(data).L,-(An)':        (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).W,(d16,An)':     (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).L,(d16,An)':     (None, 0,   6, 0,0,0,   7, 0,2,0),
    '#(data).W,$XXX.W':       (None, 0,   4, 0,0,0,   4, 0,1,0),
    '#(data).L,$XXX.W':       (None, 0,   6, 0,0,0,   6, 0,2,0),
    '#(data).W,$XXX.L':       (None, 0,   6, 0,0,0,   6, 0,1,0),
    '#(data).L,$XXX.L':       (None, 0,   8, 0,0,0,   8, 0,2,0),
    # Brief format extension word
    '#(data).W,(d8,An,Xn)':   (None, 0,   6, 0,0,0,   6, 0,2,0),
    '#(data).L,(d8,An,Xn)':   (None, 0,   8, 0,0,0,   8, 0,2,0),
    # Full format extension word(s) -- shallowest few, same rationale as FEA
    '#(data).W,(d16,An)_full': (4, 0,   8, 0,0,0,   8, 0,2,0),
    '#(data).L,(d16,An)_full': (6, 0,  10, 0,0,0,  10, 0,2,0),
    '#(data).W,(d16,An,Xn)_full': (8, 0,   8, 0,0,0,   9, 0,1,0),
    '#(data).L,(d16,An,Xn)_full': (10, 0,  10, 0,0,0,  10, 0,1,0),
}

# ── 11.6.5 Jump Effective Address (jea) — PDF 499-500 ───────────────────────
# For JMP/JSR. Transcribed for completeness; exercised via footnote in
# Stage A6 (Control Instructions), not swept standalone here.
JEA = {
    '(An)':                (None, 0,   2, 0,0,0,   2, 0,0,0),
    '(d16,An)':             (None, 0,   4, 0,0,0,   4, 0,0,0),
    '(xxx).W':              (None, 0,   2, 0,0,0,   2, 0,0,0),
    '(xxx).L':              (None, 0,   2, 0,0,0,   2, 0,0,0),
    # Brief format extension word
    '(d8,An,Xn)':            (None, 0,   6, 0,0,0,   6, 0,0,0),
    # Full format extension word(s)
    '(d16,An)_full':         (2, 0,   6, 0,0,0,   6, 0,0,0),
    '(d16,An,Xn)_full':      (None, 0,   6, 0,0,0,   6, 0,0,0),
    '([d16,An])':            (2, 0,  10, 1,0,0,  10, 1,1,0),
    '([d16,An],Xn)':         (2, 0,  10, 1,0,0,  10, 1,1,0),
    '([d16,An],d16)':        (2, 0,  12, 1,0,0,  12, 1,1,0),
    '([d16,An],Xn,d16)':     (2, 0,  12, 1,0,0,  12, 1,1,0),
    '([d16,An],d32)':        (2, 0,  12, 1,0,0,  12, 1,1,0),
    '([d16,An],Xn,d32)':     (None, 0,   6, 0,0,0,   6, 0,1,0),
    '(B)':                   (4, 0,   8, 0,0,0,   9, 0,1,0),
    '(d16,B)':                (4, 0,  12, 0,0,0,  13, 0,1,0),
    '(d32,B)':                (4, 0,  10, 0,0,0,  10, 0,1,0),
    '([B])':                  (4, 0,  10, 0,0,0,  10, 0,1,0),
    '([B],I)':                 (4, 0,  10, 0,0,0,  10, 0,1,0),
    '([B],d16)':               (4, 0,  12, 0,0,0,  12, 0,1,0),
    '([B],I,d16)':              (4, 0,  12, 0,0,0,  12, 0,1,0),
    '([B],d32)':               (4, 0,  12, 0,0,0,  12, 0,1,0),
    '([B],I,d32)':              (4, 0,  12, 0,0,0,  12, 0,1,0),
    '(d16,B])':                (4, 0,  14, 0,0,0,  14, 0,1,0),
    '(d16,B],I)':               (4, 0,  14, 0,0,0,  14, 0,1,0),
    '(d16,B],d16)':             (4, 0,  16, 0,0,0,  17, 0,1,0),
    '(d16,B],I,d16)':           (4, 0,  16, 0,0,0,  17, 0,1,0),
    '(d16,B],d32)':             (4, 0,  18, 0,0,0,  19, 0,1,0),
    '(d16,B],I,d32)':           (4, 0,  18, 0,0,0,  19, 0,1,0),
}


def ncc_rpw(table, mode):
    """Return (r, p, w) from the No-Cache-Case column for a table row."""
    row = table[mode]
    return row[7], row[8], row[9]


def ncc_total(table, mode):
    row = table[mode]
    return row[6]


if __name__ == '__main__':
    for name, table in [('FEA', FEA), ('FIEA', FIEA), ('CEA', CEA),
                         ('CIEA', CIEA), ('JEA', JEA)]:
        print(f"{name}: {len(table)} rows")

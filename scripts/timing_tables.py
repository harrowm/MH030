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


# ── 11.6.6 MOVE Instruction — PDF 500-501, manual 11-37/11-38 ──────────────
# "...the number of clock periods needed for the processor to calculate the
# destination effective address and perform the MOVE or MOVEA instruction,
# including the first level of indirection on memory indirect addressing
# modes." Rows without '*' are register-source (Rn) forms -- no fea needed.
# Rows with '*' need the SOURCE's own fea (or 0 if source is Dn/An) added.
MOVE = {
    'Rn,Dn':                    (2, 0,   2, 0,0,0,   2, 0,1,0),
    'Rn,An':                    (2, 0,   2, 0,0,0,   2, 0,1,0),
    '*EA,An':                   (0, 0,   2, 0,0,0,   2, 0,1,0),
    '*EA,Dn':                   (0, 0,   2, 0,0,0,   2, 0,1,0),
    'Rn,(An)':                  (2, 0,   3, 0,0,1,   4, 0,1,1),
    '*SOURCE,(An)':             (2, 0,   4, 0,0,1,   5, 0,1,1),
    'Rn,(An)+':                 (0, 1,   3, 0,0,1,   4, 0,1,1),
    '*SOURCE,(An)+':            (2, 0,   4, 0,0,1,   5, 0,1,1),
    'Rn,-(An)':                 (0, 2,   4, 0,0,1,   4, 0,1,1),
    '*SOURCE,-(An)':            (2, 0,   4, 0,0,1,   5, 0,1,1),
    '*EA,(d16,An)':             (2, 0,   4, 0,0,1,   5, 0,1,1),
    '*EA,XXX.W':                (2, 0,   4, 0,0,1,   5, 0,1,1),
    '*EA,XXX.L':                (0, 0,   6, 0,0,1,   7, 0,2,1),
    # Brief format extension word
    '*EA,(d8,An,Xn)':           (4, 0,   6, 0,0,1,   7, 0,1,1),
    # Full format extension word(s)
    '*EA,(d16,An)_full':        (2, 0,   8, 0,0,1,   9, 0,2,1),
    '*EA,(d16,An,Xn)_full':     (2, 0,   8, 0,0,1,   9, 0,2,1),
    '*EA,([d16,An],Xn)':        (2, 0,  10, 1,0,1,  11, 1,2,1),
    '*EA,([d16,An],d16)':       (2, 0,  12, 1,0,1,  14, 1,2,1),
    '*EA,([d16,An],Xn,d16)':    (2, 0,  12, 1,0,1,  14, 1,2,1),
    '*EA,([d16,An],d32)':       (2, 0,  14, 1,0,1,  16, 1,3,1),
    '*EA,([d16,An],Xn,d32)':    (2, 0,  14, 1,0,1,  16, 1,3,1),
    '*EA,(B)':                  (4, 0,   8, 0,0,1,   9, 0,1,1),
    '*EA,(d16,B)':               (4, 0,  10, 0,0,1,  12, 0,2,1),
    '*EA,(d32,B)':               (4, 0,  14, 0,0,1,  16, 0,2,1),
    '*EA,([B])':                 (4, 0,  10, 1,0,1,  11, 1,1,1),
    '*EA,([B],I)':                (4, 0,  10, 1,0,1,  11, 1,1,1),
    '*EA,([B],d16)':              (4, 0,  12, 1,0,1,  14, 1,2,1),
    '*EA,([B],I,d16)':             (4, 0,  12, 1,0,1,  14, 1,2,1),
    '*EA,([B],d32)':              (4, 0,  14, 1,0,1,  16, 1,2,1),
    '*EA,([B],I,d32)':             (4, 0,  14, 1,0,1,  16, 1,2,1),
    '*EA,(d16,B])':               (4, 0,  12, 1,0,1,  14, 1,2,1),
    '*EA,(d16,B],I)':              (4, 0,  12, 1,0,1,  17, 1,2,1),
    '*EA,(d16,B],d16)':            (4, 0,  14, 1,0,1,  17, 1,2,1),
    '*EA,(d16,B],I,d16)':          (4, 0,  14, 1,0,1,  17, 1,2,1),
    '*EA,(d16,B],d32)':            (4, 0,  16, 1,0,1,  19, 1,3,1),
    '*EA,(d16,B],I,d32)':          (4, 0,  16, 1,0,1,  19, 1,3,1),
    '*EA,(d32,B])':               (4, 0,  16, 1,0,1,  18, 1,2,1),
    '*EA,(d32,B],I)':              (4, 0,  16, 1,0,1,  18, 1,2,1),
    '*EA,(d32,B],d16)':            (4, 0,  18, 1,0,1,  21, 1,3,1),
    '*EA,(d32,B],I,d16)':          (4, 0,  18, 1,0,1,  21, 1,3,1),
    '*EA,(d32,B],d32)':            (4, 0,  20, 1,0,1,  23, 1,3,1),
    '*EA,(d32,B],I,d32)':          (4, 0,  20, 1,0,1,  23, 1,3,1),
}

# ── 11.6.7 Special-Purpose MOVE Instruction — PDF 502, manual 11-39 ────────
# EXG/MOVEC/MOVE-CCR-SR/MOVEM/MOVEP/MOVES/SWAP/MOVE-USP. MOVEM's own two
# rows are n(register-count)-dependent formulas (footnote '+'), transcribed
# for completeness but not swept in Stage A2 (needs its own per-n test
# generation, deferred).
MOVE_SPECIAL = {
    'EXG Ry,Rx':                (4, 0,   4, 0,0,0,   4, 0,1,0),
    'MOVEC Cr,Rn':               (6, 0,   6, 0,0,0,   6, 0,1,0),
    'MOVEC Rn,Cr-A':             (6, 0,   6, 0,0,0,   6, 0,1,0),
    'MOVEC Rn,Cr-B':             (4, 0,  12, 0,0,0,  12, 0,1,0),
    'MOVE CCR,Dn':               (2, 0,   4, 0,0,0,   4, 0,1,0),
    '*MOVE CCR,Mem':             (2, 0,   4, 0,0,1,   5, 0,1,1),
    'MOVE Dn,CCR':               (4, 0,   4, 0,0,0,   4, 0,1,0),
    '*MOVE EA,CCR':              (0, 0,   4, 0,0,0,   4, 0,1,0),
    'MOVE SR,Dn':                (2, 0,   4, 0,0,0,   4, 0,1,0),
    '*MOVE SR,Mem':              (2, 0,   4, 0,0,1,   5, 0,1,1),
    '#MOVE EA,SR':               (0, 0,   8, 0,0,0,  10, 0,2,0),
    'MOVEP.W Dn,(d16,An)':       (4, 0,  10, 0,0,2,  10, 0,1,2),
    'MOVEP.W (d16,An),Dn':       (4, 0,  10, 0,2,0,  10, 2,1,0),
    'MOVEP.L Dn,(d16,An)':       (4, 0,  14, 0,0,4,  14, 0,1,4),
    'MOVEP.L (d16,An),Dn':       (4, 0,  14, 0,4,0,  14, 4,1,0),
    '%MOVES EA,Rn':              (3, 0,   7, 1,0,2,   5, 0,1,1),
    '%MOVES Rn,EA':              (2, 1,   5, 0,0,1,   6, 0,1,1),
    'MOVE USP,An':               (4, 0,   4, 0,0,0,   4, 0,1,0),
    'MOVE An,USP':               (4, 0,   4, 0,0,0,   4, 0,1,0),
    'SWAP Dn':                   (4, 0,   4, 0,0,0,   4, 0,1,0),
}


# ── 11.6.8 Arithmetical/Logical Instructions — PDF 503-504, manual 11-40/41 ─
# '*' = Add Fetch Effective Address Time. '**' = Add Fetch Immediate
# Effective Address Time (same meaning as FEA/FIEA elsewhere in this file --
# kept as a single leading-'*'-count marker in the key, not a separate dict,
# since Stage A3 only needs the printed row values directly).
ALU = {
    'ADD Rn,Dn':          (2, 0,  2, 0,0,0,  2, 0,1,0),
    'ADDA.W Rn,An':       (4, 0,  4, 0,0,0,  4, 0,1,0),
    'ADDA.L Rn,An':       (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*ADD EA,Dn':         (0, 0,  2, 0,0,0,  2, 0,1,0),
    '*ADD.W EA,An':       (0, 0,  4, 0,0,0,  4, 0,1,0),
    '*ADDA.L EA,An':      (0, 0,  2, 0,0,0,  2, 0,1,0),
    '*ADD Dn,EA':         (0, 1,  3, 0,0,1,  4, 0,1,1),
    'AND Dn,Dn':          (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*AND EA,Dn':         (0, 0,  2, 0,0,0,  2, 0,1,0),
    '*AND Dn,EA':         (0, 1,  3, 0,0,1,  4, 0,1,1),
    'EOR Dn,Dn':          (2, 0,  2, 0,0,0,  2, 0,1,0),
    'EOR Dn,EA':          (0, 1,  3, 0,0,1,  4, 0,1,1),
    'OR Dn,Dn':           (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*OR EA,Dn':          (0, 0,  2, 0,0,0,  2, 0,1,0),
    '*OR Dn,EA':          (0, 1,  3, 0,0,1,  4, 0,1,1),
    'SUB Rn,Dn':          (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*SUB EA,Dn':         (0, 0,  2, 0,0,0,  2, 0,1,0),
    '*SUB Dn,EA':         (0, 1,  3, 0,0,1,  4, 0,1,1),
    'SUBA.W Rn,An':       (4, 0,  4, 0,0,0,  4, 0,1,0),
    'SUBA.L Rn,An':       (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*SUBA.W EA,An':      (0, 0,  4, 0,0,0,  4, 0,1,0),
    '*SUBA.L EA,An':      (0, 0,  2, 0,0,0,  2, 0,1,0),
    'CMP Rn,Dn':          (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*CMP EA,Dn':         (0, 0,  2, 0,0,0,  2, 0,1,0),
    'CMPA.W Rn,An':       (4, 0,  4, 0,0,0,  4, 0,1,0),
    '*CMPA.W EA,An':      (0, 0,  4, 0,0,0,  4, 0,1,0),
    '**+CMP2 EA,Rn':      (2, 0, 20, 1,0,0, 20, 1,1,0),
    '*+MULS.W EA,Dn':     (2, 0, 28, 0,0,0, 28, 0,1,0),
    '**+MULS.L EA,Dn':    (2, 0, 44, 0,0,0, 44, 0,1,0),
    '*+MULU.W EA,Dn':     (2, 0, 28, 0,0,0, 28, 0,1,0),
    '**+MULU.L EA,Dn':    (2, 0, 44, 0,0,0, 44, 0,1,0),
    '+DIVS.W Dn,Dn':      (2, 0, 56, 0,0,0, 56, 0,1,0),
    '*+DIVS.W EA,Dn':     (0, 0, 56, 0,0,0, 56, 0,1,0),
    '**+DIVS.L Dn,Dn':    (6, 0, 90, 0,0,0, 90, 0,1,0),
    '**+DIVS.L EA,Dn':    (0, 0, 90, 0,0,0, 90, 0,1,0),
    '+DIVU.W Dn,Dn':      (2, 0, 44, 0,0,0, 44, 0,1,0),
    '*+DIVU.W EA,Dn':     (0, 0, 44, 0,0,0, 44, 0,1,0),
    '**+DIVU.L Dn,Dn':    (6, 0, 78, 0,0,0, 78, 0,1,0),
    '**+DIVU.L EA,Dn':    (0, 0, 78, 0,0,0, 78, 0,1,0),
}

# ── 11.6.9 Immediate Arithmetical/Logical Instructions — PDF 505, 11-42 ─────
ALU_IMM = {
    'MOVEQ #(data),Dn':   (2, 0,  2, 0,0,0,  2, 0,1,0),
    'ADDQ #(data),Rn':    (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*ADDQ #(data),Mem':  (0, 1,  3, 0,0,1,  4, 0,1,1),
    'SUBQ #(data),Rn':    (2, 0,  2, 0,0,0,  2, 0,1,0),
    '*SUBQ #(data),Mem':  (0, 1,  3, 0,0,1,  4, 0,1,1),
    '**ADDI #(data),Dn':  (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**ADDI #(data),Mem': (0, 1,  3, 0,0,1,  4, 0,1,1),
    'ANDI #(data),Dn':    (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**ANDI #(data),Mem': (0, 1,  3, 0,0,1,  4, 0,1,1),
    '**EORI #(data),Dn':  (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**EORI #(data),Mem': (0, 1,  3, 0,0,1,  4, 0,1,1),
    '**ORI #(data),Dn':   (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**ORI #(data),Mem':  (0, 1,  3, 0,0,1,  4, 0,1,1),
    '**SUBI #(data),Dn':  (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**SUBI #(data),Mem': (0, 1,  3, 0,0,1,  4, 0,1,1),
    '**CMPI #(data),Dn':  (2, 0,  2, 0,0,0,  2, 0,1,0),
    '**CMPI #(data),Mem': (0, 0,  2, 0,0,0,  2, 0,1,0),
}

# ── 11.6.10 Binary-Coded Decimal and Extended Instructions — PDF 506, 11-43 ─
# No footnotes needed -- these tables are already self-contained totals.
# Transcribed here (Stage A3) for reuse in Stage A4.
BCD_EXT = {
    'ABCD Dn,Dn':              (0, 0,   4, 0,0,0,   4, 0,1,0),
    'ABCD -(An),-(An)':        (2, 1,  13, 2,0,1,  14, 2,1,1),
    'SBCD Dn,Dn':               (0, 0,   4, 0,0,0,   4, 0,1,0),
    'SBCD -(An),-(An)':         (2, 1,  13, 2,0,1,  14, 2,1,1),
    'ADDX Dn,Dn':               (2, 0,   2, 0,0,0,   2, 0,1,0),
    'ADDX -(An),-(An)':         (2, 1,   9, 2,0,1,  10, 2,1,1),
    'SUBX Dn,Dn':               (2, 0,   2, 0,0,0,   2, 0,1,0),
    'SUBX -(An),-(An)':         (2, 1,   9, 2,0,1,  10, 2,1,1),
    'CMPM (An)+,(An)+':         (6, 0,   8, 2,0,0,   8, 2,1,0),
    'PACK Dn,Dn,#(data)':       (6, 0,   6, 0,0,0,   6, 0,1,0),
    'PACK -(An),-(An),#(data)': (2, 1,  11, 1,0,1,  11, 1,1,1),
    'UNPK Dn,Dn,#(data)':       (8, 0,   8, 0,0,0,   8, 0,1,0),
    'UNPK -(An),-(An),#(data)': (2, 1,  11, 1,0,1,  11, 1,1,1),
}


# ── 11.6.11 Single Operand Instructions — PDF 507, manual 11-44 ────────────
# '*' = Add Fetch Effective Address Time. '**' = Add Calculate Effective
# Address Time (cea, NOT fea/fiea -- this table's own footnote wording
# differs from every earlier table's '**'=fiea convention; confirmed by
# direct re-read of the footnote text on this specific page).
SINGLE_OP = {
    'CLR Dn':        (2, 0,   2, 0,0,0,   2, 0,1,0),
    '**CLR Mem':     (0, 1,   3, 0,0,1,   4, 0,1,1),
    'NEG Dn':        (2, 0,   2, 0,0,0,   2, 0,1,0),
    '*NEG Mem':      (0, 1,   3, 0,0,1,   4, 0,1,1),
    'NEGX Dn':       (2, 0,   2, 0,0,0,   2, 0,1,0),
    '*NEGX Mem':     (0, 1,   3, 0,0,1,   4, 0,1,1),
    'NOT Dn':        (2, 0,   2, 0,0,0,   2, 0,1,0),
    '*NOT Mem':      (0, 1,   3, 0,0,1,   4, 0,1,1),
    'EXT Dn':        (4, 0,   4, 0,0,0,   4, 0,1,0),
    'NBCD Dn':       (0, 0,   6, 0,0,0,   6, 0,1,0),
    'Scc Dn':        (4, 0,   4, 0,0,0,   4, 0,1,0),
    '**Scc Mem':     (0, 1,   5, 0,0,1,   5, 0,1,1),
    'TAS Dn':        (4, 0,   4, 0,0,0,   4, 0,1,0),
    '**TAS Mem':     (3, 0,  12, 1,0,1,  12, 1,1,1),
    'TST Dn':        (0, 0,   2, 0,0,0,   2, 0,1,0),
    '*TST Mem':      (0, 0,   2, 0,0,0,   2, 0,1,0),
}

# ── 11.6.12 Shift/Rotate Instructions — PDF 508, manual 11-45 ──────────────
# Transcribed opportunistically while reading §11.6.11's own pages (Stage
# A4); reserved for Stage A5, NOT independently re-verified digit-by-digit
# yet (same caveat as FEA's own deep memory-indirect rows) -- re-confirm
# against a fresh page read before relying on it in Stage A5.
# d = direction (L or R). '*'=fea. '%'=shift count <= data size.
# '+'=shift count > data size.
SHIFT_ROTATE = {
    'LSd #(data),Dy':  (4, 0,   4, 0,0,0,   4, 0,1,0),
    '%LSd Dx,Dy':      (6, 0,   6, 0,0,0,   6, 0,1,0),
    '+LSd Dx,Dy':      (8, 0,   8, 0,0,0,   8, 0,1,0),
    '*LSd Mem by 1':   (0, 1,   4, 0,0,1,   4, 0,1,1),
    'ASL #(data),Dy':  (2, 0,   4, 0,0,0,   4, 0,1,0),
    'ASL Dx,Dy':       (4, 0,   8, 0,0,0,   8, 0,1,0),
    '*ASL Mem by 1':   (0, 1,   6, 0,0,1,   6, 0,1,1),
    'ASR #(data),Dy':  (4, 0,   4, 0,0,0,   4, 0,1,0),
    '%ASR Dx,Dy':      (6, 0,   6, 0,0,0,   6, 0,1,0),
    '+ASR Dx,Dy':      (10, 0, 10, 0,0,0,  10, 0,1,0),
    '*ASR Mem by 1':   (0, 1,   4, 0,0,1,   4, 0,1,1),
    'ROd #(data),Dy':  (4, 0,   6, 0,0,0,   6, 0,1,0),
    'ROd Dx,Dy':       (6, 0,   8, 0,0,0,   8, 0,1,0),
    '*ROd Mem by 1':   (0, 1,   6, 0,0,1,   6, 0,1,1),
    'ROXd Dn':         (10, 0, 12, 0,0,0,  12, 0,1,0),
    '*ROXd Mem by 1':  (0, 1,   4, 0,0,0,   4, 0,1,0),
}


# ── 11.6.13 Bit Manipulation Instructions — PDF 509, manual 11-46 ──────────
# '*' = Add Fetch Effective Address Time. '#' = Add Fetch Immediate
# Effective Address Time (fiea).
BIT_MANIP = {
    'BTST #(data),Dn':   (4, 0,   4, 0,0,0,   4, 0,1,0),
    'BTST Dn,Dn':        (4, 0,   4, 0,0,0,   4, 0,1,0),
    '#BTST #(data),Mem': (0, 0,   4, 0,0,0,   4, 0,1,0),
    '*BTST Dn,Mem':      (0, 0,   4, 0,0,0,   4, 0,1,0),
    'BCHG #(data),Dn':   (6, 0,   6, 0,0,0,   6, 0,1,0),
    'BCHG Dn,Dn':        (6, 0,   6, 0,0,0,   6, 0,1,0),
    '#BCHG #(data),Mem': (0, 0,   6, 0,0,1,   6, 0,1,1),
    '*BCHG Dn,Mem':      (0, 0,   6, 0,0,1,   6, 0,1,1),
    'BCLR #(data),Dn':   (6, 0,   6, 0,0,0,   6, 0,1,0),
    'BCLR Dn,Dn':        (6, 0,   6, 0,0,0,   6, 0,1,0),
    '#BCLR #(data),Mem': (0, 0,   6, 0,0,1,   6, 0,1,1),
    '*BCLR Dn,Mem':      (0, 0,   6, 0,0,1,   6, 0,1,1),
    'BSET #(data),Dn':   (6, 0,   6, 0,0,0,   6, 0,1,0),
    'BSET Dn,Dn':        (6, 0,   6, 0,0,0,   6, 0,1,0),
    '#BSET #(data),Mem': (0, 0,   6, 0,0,1,   6, 0,1,1),
    '*BSET Dn,Mem':      (0, 0,   6, 0,0,1,   6, 0,1,1),
}

# ── 11.6.14 Bit Field Manipulation Instructions — PDF 510, manual 11-47 ────
# '*' = Add Calculate Immediate Effective Address Time (ciea). NOTE: a
# 32-bit bit field may span 5 bytes (two operand cycles) or 4 bytes (one).
BIT_FIELD = {
    'BFTST Dn':              (8, 0,   8, 0,0,0,   8, 0,1,0),
    '*BFTST Mem(<5 Bytes)':  (6, 0,  10, 1,0,0,  10, 1,1,0),
    '*BFTST Mem(5 Bytes)':   (6, 0,  14, 2,0,0,  14, 2,1,0),
    'BFCHG Dn':              (14, 0, 14, 0,0,0,  14, 0,1,0),
    '*BFCHG Mem(<5 Bytes)':  (6, 0,  14, 1,0,1,  14, 1,1,1),
    '*BFCHG Mem(5 Bytes)':   (6, 0,  22, 2,0,2,  22, 2,1,2),
    'BFCLR Dn':              (14, 0, 14, 0,0,0,  14, 0,1,0),
    '*BFCLR Mem(<5 Bytes)':  (6, 0,  14, 1,0,1,  14, 1,1,1),
    '*BFCLR Mem(5 Bytes)':   (6, 0,  22, 2,0,2,  22, 2,1,2),
    'BFSET Dn':              (14, 0, 14, 0,0,0,  14, 0,1,0),
    '*BFSET Mem(<5 Bytes)':  (6, 0,  14, 1,0,1,  14, 1,1,1),
    '*BFSET Mem(5 Bytes)':   (6, 0,  22, 2,0,2,  22, 2,1,2),
    'BFEXTS Dn':             (10, 0, 10, 0,0,0,  10, 0,1,0),
    '*BFEXTS Mem(<5 Bytes)': (6, 0,  12, 1,0,0,  12, 1,1,0),
    '*BFEXTS Mem(5 Bytes)':  (6, 0,  18, 2,0,0,  18, 2,1,0),
    'BFEXTU Dn':             (10, 0, 10, 0,0,0,  10, 0,1,0),
    '*BFEXTU Mem(<5 Bytes)': (6, 0,  12, 1,0,0,  12, 1,1,0),
    '*BFEXTU Mem(5 Bytes)':  (6, 0,  18, 2,0,0,  18, 2,1,0),
    'BFINS Dn':              (12, 0, 12, 0,0,0,  12, 0,1,0),
    '*BFINS Mem(<5 Bytes)':  (6, 0,  12, 1,0,1,  12, 1,1,1),
    '*BFINS Mem(5 Bytes)':   (6, 0,  18, 2,0,2,  18, 2,1,2),
    'BFFFO Dn':              (20, 0, 20, 0,0,0,  20, 0,1,0),
    '*BFFFO Mem(<5 Bytes)':  (6, 0,  22, 1,1,0,  22, 1,1,0),
    '*BFFFO Mem(5 Bytes)':   (6, 0,  28, 2,0,0,  28, 2,1,0),
}

# ── 11.6.15 Conditional Branch Instructions — PDF 511, manual 11-48 ────────
# Opportunistically captured while reading §11.6.13-14 (Stage A5); reserved
# for Stage A6.
COND_BRANCH = {
    'Bcc (Taken)':                     (6, 0,   6, 0,0,0,   8, 0,2,0),
    'Bcc.B (Not Taken)':               (4, 0,   4, 0,0,0,   4, 0,1,0),
    'Bcc.W (Not Taken)':               (6, 0,   6, 0,0,0,   6, 0,1,0),
    'Bcc.L (Not Taken)':               (6, 0,   6, 0,0,0,   8, 0,2,0),
    'DBcc (cc=False,Count Not Expired)': (6, 0,   6, 0,0,0,   8, 0,2,0),
    'DBcc (cc=False,Count Expired)':   (10, 0,  10, 0,0,0,  13, 0,3,0),
    'DBcc (cc=True)':                  (6, 0,   6, 0,0,0,   8, 0,1,0),
}


# ── 11.6.16 Control Instructions — PDF 512, manual 11-49 ───────────────────
# '*'=fea '**'=cea '#'=fiea '##'=ciea '%'=Add Jump Effective Address Time
# (jea) '+'=Indicates Maximum Time (actual time is data dependent).
# RTD/RTR/RTS/UNLK rows not yet independently cross-verified digit-by-digit
# (UNLK's own I-cache(9) > No-Cache(5) looks like a possible mis-transcription
# -- re-confirm against a fresh page read before relying on those 4 rows
# specifically; every other row in this table is used with confidence).
CONTROL_INSTR = {
    'ANDI to SR':                  (4, 0,  12, 0,0,0,  14, 0,2,0),
    'EORI to SR':                  (4, 0,  12, 0,0,0,  14, 0,2,0),
    'ORI to SR':                   (4, 0,  12, 0,0,0,  14, 0,2,0),
    'ANDI to CCR':                 (4, 0,  12, 0,0,0,  14, 0,2,0),
    'EORI to CCR':                 (4, 0,  12, 0,0,0,  14, 0,2,0),
    'ORI to CCR':                  (4, 0,  12, 0,0,0,  14, 0,2,0),
    'BSR':                         (2, 0,   6, 0,0,1,   9, 0,2,1),
    '##CAS (Successful Compare)':  (1, 0,  13, 1,0,1,  13, 1,1,1),
    '##CAS (Unsuccessful Compare)': (1, 0, 11, 1,0,0,  11, 1,1,0),
    '+CAS2 (Successful Compare)':  (2, 0,  24, 2,0,2,  26, 2,2,2),
    '+CAS2 (Unsuccessful Compare)': (2, 0, 24, 2,0,0,  24, 2,2,0),
    'CHK Dn,Dn (No Exception)':    (8, 0,   8, 0,0,0,   8, 0,1,0),
    'CHK Dn,Dn (Exception Taken)': (4, 0,  28, 1,0,4,  30, 1,3,4),
    '*CHK EA,Dn (No Exception)':   (0, 0,   8, 0,0,0,   8, 0,1,0),
    '*+CHK EA,Dn (Exception Taken)': (0, 0, 28, 1,0,4,  30, 1,3,4),
    '#+CHK2 Mem,Rn (No Exception)': (2, 0, 18, 1,0,0,  18, 1,1,0),
    '#+CHK2 Mem,Rn (Exception Taken)': (2, 0, 40, 2,0,4, 42, 2,3,4),
    '%JMP':                        (4, 0,   4, 0,0,0,   6, 0,2,0),
    '%JSR':                        (0, 0,   4, 0,0,1,   7, 0,2,1),
    '**LEA':                       (2, 0,   2, 0,0,0,   2, 0,1,0),
    'LINK.W':                      (2, 0,   4, 0,0,1,   5, 0,1,1),
    'LINK.L':                      (2, 0,   6, 0,0,1,   7, 0,2,1),
    'NOP':                         (0, 0,   2, 0,0,0,   2, 0,1,0),
    '**PEA':                       (0, 2,   4, 0,0,1,   4, 0,1,1),
    'RTD':                         (2, 0,  10, 1,0,0,  12, 1,2,0),
    'RTR':                         (1, 0,  12, 2,0,0,  14, 2,2,0),
    'RTS':                         (1, 0,  12, 2,0,0,  14, 1,2,0),
    'UNLK':                        (0, 0,   9, 1,0,0,   5, 1,1,0),
}

# ── 11.6.17 Exception-Related Instructions and Operations — PDF 513, 11-50 ─
# Opportunistically captured while reading §11.6.16 (Stage A6); reserved for
# Stage A7, not yet independently re-verified digit-by-digit.
EXCEPTION_RELATED = {
    'BKPT':                (1, 0,   9, 1,0,0,   9, 1,0,0),
    'Interrupt (I-Stack)': (0, 0,  23, 2,0,4,  24, 2,2,8),
    'Interrupt (M-Stack)': (0, 0,  33, 2,0,8,  34, 2,2,8),
    'RESET Instruction':   (0, 0, 518, 0,0,0, 518, 0,1,0),
    'STOP':                (0, 0,   8, 0,0,0,   8, 0,2,0),
    'TRACE':               (0, 0,  22, 1,0,5,  24, 1,2,5),
    'TRAP #n':             (0, 0,  18, 1,0,4,  20, 1,2,4),
    'Illegal Instruction': (0, 0,  18, 1,0,4,  20, 1,2,4),
    'A-Line Trap':         (0, 0,  18, 1,0,4,  20, 1,2,4),
    'F-Line Trap':         (0, 0,  18, 1,0,4,  20, 1,2,4),
    'Privilege Violation': (0, 0,  18, 1,0,4,  20, 1,2,4),
    'TRAPcc (Trap)':       (2, 0,  22, 1,0,5,  24, 1,2,5),
    'TRAPcc (No Trap)':    (4, 0,   4, 0,0,0,   4, 0,1,0),
    'TRAPcc.W (Trap)':     (5, 0,  24, 1,0,5,  26, 1,3,5),
    'TRAPcc.W (No Trap)':  (6, 0,   6, 0,0,0,   6, 0,1,0),
    'TRAPcc.L (Trap)':     (6, 0,  26, 1,0,5,  28, 1,3,5),
    'TRAPcc.L (No Trap)':  (8, 0,   8, 0,0,0,   8, 0,2,0),
    'TRAPV (Trap)':        (2, 0,  22, 1,0,5,  24, 1,2,5),
    'TRAPV (No Trap)':     (4, 0,   4, 0,0,0,   4, 0,1,0),
}

# ── 11.6.18 Save and Restore Operations — PDF 514, manual 11-51 ───────────
# Opportunistically captured alongside §11.6.17; reserved for Stage A7, not
# yet independently re-verified digit-by-digit.
SAVE_RESTORE = {
    'Bus Cycle Fault (Short)': (0, 0,  36, 1,0,10,  38, 1,2,10),
    'Bus Cycle Fault (Long)':  (0, 0,  62, 1,0,24,  64, 1,2,24),
    'RTE (Normal Four Word)':  (1, 0,  18, 4,0,0,   20, 4,2,0),
    'RTE (Six Word)':          (1, 0,  18, 4,0,0,   20, 4,2,0),
    'RTE (Throwaway)':         (1, 0,  12, 4,0,0,   12, 4,0,0),
    'RTE (Coprocessor)':       (1, 0,  26, 7,0,0,   26, 7,2,0),
    'RTE (Short Fault)':       (1, 0,  36, 10,0,0,  26, 10,2,0),
    'RTE (Long Fault)':        (1, 0,  76, 25,0,0,  76, 25,2,0),
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
                         ('CIEA', CIEA), ('JEA', JEA), ('MOVE', MOVE),
                         ('MOVE_SPECIAL', MOVE_SPECIAL), ('ALU', ALU),
                         ('ALU_IMM', ALU_IMM), ('BCD_EXT', BCD_EXT),
                         ('SINGLE_OP', SINGLE_OP), ('SHIFT_ROTATE', SHIFT_ROTATE),
                         ('BIT_MANIP', BIT_MANIP), ('BIT_FIELD', BIT_FIELD),
                         ('COND_BRANCH', COND_BRANCH), ('CONTROL_INSTR', CONTROL_INSTR),
                         ('EXCEPTION_RELATED', EXCEPTION_RELATED),
                         ('SAVE_RESTORE', SAVE_RESTORE)]:
        print(f"{name}: {len(table)} rows")

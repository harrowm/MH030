#!/usr/bin/env python3
"""Generator for a larger multi-instruction sequential timing corpus
(tests/timing/seq2_*.s + tests/timing/seq_tests2.json), following up the
initial 5-test pilot (tests/timing/seq_*.s / seq_tests.json). Not part of
the regular Makefile flow -- a one-shot authoring tool, kept for
reference/regeneration.

Each entry: name, setup lines (run before the sequence, NOT measured),
body lines (the measured sequence -- for straight-line tests this is
exactly the retirement sequence; for the one loop test the body is
shorter than the dynamic retirement count and seq_len is given
explicitly), seq_len (expected number of retirements), seq_isolated_ncc
(list of each retirement's own manual NCC, from scripts/timing_tables.py,
read directly from MC68030UM.pdf Section 11), instr_len (byte span used
for r/p/w chronological/address-range attribution -- for the loop test
this is the loop body's own span, reused every pass), desc.

Byte lengths for instr_len were cross-checked against already-established
single-instruction test manifests (a2_*/a3_*/a4_*/a5_*/a6_*.json) rather
than re-derived by hand:
  - Register-direct ALU/MOVE/shift(imm or reg count)/SWAP: 2 bytes
  - Bit-field register-direct (needs an extension word): 4 bytes
  - #(data).L immediate ALU (SUBI/CMPI/ANDI/ORI/EORI): 6 bytes
  - NEG.L (An)/-(An)/(An)+ : 2 bytes; NEG.L (d8,An,Xn) indexed: 4 bytes
  - CLR.L (An): 2 bytes; JSR (An)/RTS: 2 bytes each; DBcc: 4 bytes
"""
import json
import subprocess
from pathlib import Path

REPO = Path(__file__).parent.parent
OUTDIR = REPO / 'tests' / 'timing'

TEMPLATE = """; tests/timing/{name}.s -- multi-instruction sequential timing corpus
; (follow-up to the initial 5-test pilot, seq_tests.json). {desc_short}
        org     0
        dc.l    $00010000
        dc.l    start

start:
{setup}
        bra.w   target

        org     $200
target:
{body}
after:
        stop    #$2700
        dc.w    $2700
{tail}"""

TESTS = []


def add(name, desc_short, setup_lines, body_lines, seq_len, seq_isolated_ncc,
        instr_len, desc, tail_lines=None):
    TESTS.append(dict(name=name, desc_short=desc_short, setup_lines=setup_lines,
                       body_lines=body_lines, seq_len=seq_len,
                       seq_isolated_ncc=seq_isolated_ncc, instr_len=instr_len,
                       desc=desc, tail_lines=tail_lines or []))


# ── Cluster A: register ALU pairs (confirm ADD's own finding generalizes
# across the whole ALU family) — ALU table, NCC=2(0/1/0) each ─────────────
add('seq2_and_pair', "AND Dn,Dn x2",
    ["move.l  #$0F0F0F0F,d1", "move.l  #$FFFFFFFF,d2"],
    ["and.l   d1,d2", "and.l   d1,d2"], 2, [2, 2], 2,
    "Two AND Dn,Dn back to back. ALU 'AND Dn,Dn' NCC=2(0/1/0) each.")

add('seq2_or_pair', "OR Dn,Dn x2",
    ["move.l  #$0F0F0F0F,d1", "move.l  #$F0000000,d2"],
    ["or.l    d1,d2", "or.l    d1,d2"], 2, [2, 2], 2,
    "Two OR Dn,Dn back to back. ALU 'OR Dn,Dn' NCC=2(0/1/0) each.")

add('seq2_eor_pair', "EOR Dn,Dn x2",
    ["move.l  #$FFFFFFFF,d1", "move.l  #$0F0F0F0F,d2"],
    ["eor.l   d1,d2", "eor.l   d1,d2"], 2, [2, 2], 2,
    "Two EOR Dn,Dn back to back (second toggles back to original). "
    "ALU 'EOR Dn,Dn' NCC=2(0/1/0) each.")

add('seq2_sub_pair', "SUB Rn,Dn x2",
    ["move.l  #5,d1", "move.l  #$10,d2"],
    ["sub.l   d1,d2", "sub.l   d1,d2"], 2, [2, 2], 2,
    "Two SUB Rn,Dn back to back. ALU 'SUB Rn,Dn' NCC=2(0/1/0) each.")

add('seq2_cmp_pair', "CMP Rn,Dn x2",
    ["move.l  #5,d1", "move.l  #$10,d2"],
    ["cmp.l   d1,d2", "cmp.l   d1,d2"], 2, [2, 2], 2,
    "Two CMP Rn,Dn back to back (compare-only, CCR side effect, no "
    "destination write -- confirms the retirement-pulse mechanism fires "
    "for CCR-only writers too). ALU 'CMP Rn,Dn' NCC=2(0/1/0) each.")

# ── Cluster B: shift/rotate (already-exact via Stage D2's internal-stall
# fix) — confirm the artificial-stall mechanism composes correctly with
# real sequencing, not just isolation ──────────────────────────────────────
add('seq2_asl_imm_pair', "ASL #1,Dn x2",
    ["move.l  #1,d2"],
    ["asl.l   #1,d2", "asl.l   #1,d2"], 2, [4, 4], 2,
    "Two ASL #1,Dn back to back. SHIFT_ROTATE 'ASL #(data),Dy' NCC=4(0/1/0) "
    "each. Also checks dec_internal_stall_ticks's two-stage resolving "
    "load doesn't misbehave under real back-to-back dispatch.")

add('seq2_lsl_reg_pair', "LSL Dx,Dy x2",
    ["move.l  #3,d1", "move.l  #1,d2"],
    ["lsl.l   d1,d2", "lsl.l   d1,d2"], 2, [6, 6], 2,
    "Two LSL Dx,Dy (register count) back to back. SHIFT_ROTATE '%LSd Dx,Dy' "
    "(count<=32) NCC=6(0/1/0) each.")

add('seq2_rol_imm_pair', "ROL #1,Dn x2",
    ["move.l  #1,d2"],
    ["rol.l   #1,d2", "rol.l   #1,d2"], 2, [6, 6], 2,
    "Two ROL #1,Dn back to back. SHIFT_ROTATE 'ROd #(data),Dy' NCC=6(0/1/0) "
    "each.")

# ── Cluster C: bit-field register forms (already-exact via Stage D3) ──────
add('seq2_bfchg_pair', "BFCHG Dn{0:8} x2",
    ["move.l  #0,d2"],
    ["bfchg   d2{0:8}", "bfchg   d2{0:8}"], 2, [14, 14], 4,
    "Two BFCHG Dn{0:8} back to back (second toggles back). BIT_FIELD "
    "'BFCHG Dn' NCC=14(0/1/0) each.")

add('seq2_bfffo_pair', "BFFFO Dn,Dm x2",
    ["move.l  #$00800000,d2"],
    ["bfffo   d2{0:8},d3", "bfffo   d2{0:8},d3"], 2, [20, 20], 4,
    "Two BFFFO Dn,Dm back to back (same field scanned twice, idempotent). "
    "BIT_FIELD 'BFFFO Dn' NCC=20(0/1/0) each.")

# ── Cluster D: MOVE-variant pairs ──────────────────────────────────────────
add('seq2_move_dn_dn_pair', "MOVE.L Dn,Dn x2",
    ["move.l  #$11111111,d1"],
    ["move.l  d1,d2", "move.l  d1,d2"], 2, [2, 2], 2,
    "Two MOVE.L Dn,Dn back to back. MOVE 'Rn,Dn' NCC=2(0/1/0) each.")

add('seq2_movea_pair', "MOVEA.L Dn,An x2",
    ["move.l  #$11111111,d1"],
    ["movea.l d1,a2", "movea.l d1,a2"], 2, [2, 2], 2,
    "Two MOVEA.L Dn,An back to back. MOVE 'Rn,An' NCC=2(0/1/0) each.")

add('seq2_swap_pair', "SWAP Dn x2",
    ["move.l  #$12340000,d1"],
    ["swap    d1", "swap    d1"], 2, [4, 4], 2,
    "Two SWAP Dn back to back (second undoes the first). "
    "MOVE_SPECIAL 'SWAP Dn' NCC=4(0/1/0) each.")

# ── Cluster E: more ext_count==2 immediates (confirm ADDI's finding
# generalizes across the whole immediate-ALU family) — imm chosen outside
# ADDQ/SUBQ's 1-8 quick range isn't needed for AND/OR/EOR (no quick form
# exists for them), but SUBI still needs it ───────────────────────────────
add('seq2_subi_pair', "SUBI.L #20,Dn x2",
    ["move.l  #100,d2"],
    ["subi.l  #20,d2", "subi.l  #20,d2"], 2, [4, 4], 6,
    "Two SUBI.L #(data),Dn back to back -- imm=20 (not 5), same "
    "ADDQ/SUBQ quick-immediate-folding avoidance as the original a3 tests. "
    "ALU_IMM 'SUBI #(data),Dn' NCC=2 + FIEA(#imm.L,Dn)=2 = 4 each.")

add('seq2_cmpi_pair', "CMPI.L #20,Dn x2",
    ["move.l  #100,d2"],
    ["cmpi.l  #20,d2", "cmpi.l  #20,d2"], 2, [4, 4], 6,
    "Two CMPI.L #(data),Dn back to back. ALU_IMM 'CMPI #(data),Dn' "
    "NCC=2 + FIEA(#imm.L,Dn)=2 = 4 each.")

add('seq2_andi_pair', "ANDI.L #imm,Dn x2",
    ["move.l  #$FFFFFFFF,d2"],
    ["andi.l  #$0F0F0F0F,d2", "andi.l  #$0F0F0F0F,d2"], 2, [4, 4], 6,
    "Two ANDI.L #(data),Dn back to back (second is idempotent). "
    "ALU_IMM 'ANDI #(data),Dn' NCC=2 + FIEA(#imm.L,Dn)=2 = 4 each "
    "(same reasoning as a3_andi_dn's own established figure).")

add('seq2_ori_pair', "ORI.L #imm,Dn x2",
    ["move.l  #$F0F0F0F0,d2"],
    ["ori.l   #$0F0F0F0F,d2", "ori.l   #$0F0F0F0F,d2"], 2, [4, 4], 6,
    "Two ORI.L #(data),Dn back to back (second is idempotent). "
    "ALU_IMM 'ORI #(data),Dn' NCC=2 + FIEA(#imm.L,Dn)=2 = 4 each.")

add('seq2_eori_pair', "EORI.L #imm,Dn x2",
    ["move.l  #$FFFFFFFF,d2"],
    ["eori.l  #$0F0F0F0F,d2", "eori.l  #$0F0F0F0F,d2"], 2, [4, 4], 6,
    "Two EORI.L #(data),Dn back to back (second toggles back). "
    "ALU_IMM 'EORI #(data),Dn' NCC=2 + FIEA(#imm.L,Dn)=2 = 4 each.")

# ── Cluster F: RMW EA-mode variants — follow up Phase 168/169/201's own
# finding (predec/postinc/indexed all measure a FLAT isolated gap, not the
# initially-mis-measured x2-x3 gap) at scale, in a real back-to-back
# sequence rather than isolation ───────────────────────────────────────────
add('seq2_neg_predec_pair', "NEG.L -(An) x2",
    ["movea.l #$3008,a0", "move.l  #5,($3000)", "move.l  #5,($3004)"],
    ["neg.l   -(a0)", "neg.l   -(a0)"], 2, [8, 8], 2,
    "Two NEG.L -(An) at different addresses ($3004 then $3000), back to "
    "back. SINGLE_OP '*NEG Mem' NCC=4 + FEA(-(An))=4 = 8 each.")

add('seq2_neg_postinc_pair', "NEG.L (An)+ x2",
    ["movea.l #$3000,a0", "move.l  #5,($3000)", "move.l  #5,($3004)"],
    ["neg.l   (a0)+", "neg.l   (a0)+"], 2, [7, 7], 2,
    "Two NEG.L (An)+ at different addresses ($3000 then $3004), back to "
    "back. SINGLE_OP '*NEG Mem' NCC=4 + FEA((An)+)=3 = 7 each.")

add('seq2_neg_idx_pair', "NEG.L (d8,An,Xn) x2",
    ["movea.l #$3000,a0", "move.l  #0,d1",
     "move.l  #5,($3000)", "move.l  #5,($3004)"],
    ["neg.l   (0,a0,d1.l)", "neg.l   (4,a0,d1.l)"], 2, [10, 10], 4,
    "Two NEG.L (d8,An,Xn) indexed, different displacements, back to back "
    "-- Phase 201's own correction found this EA mode's isolated gap is "
    "FLAT (not the originally-mis-measured x3), confirming here whether "
    "that holds under real sequencing too. SINGLE_OP '*NEG Mem' NCC=4 + "
    "FEA((d8,An,Xn))=6 = 10 each.")

# ── Cluster G: real steady-state loop + genuine call/return ───────────────
add('seq2_dbf_loop', "ADDQ.L #1,Dn / DBF loop, 4 passes",
    ["move.l  #3,d0", "clr.l   d2"],
    ["loop:", "        addq.l  #1,d2", "        dbf     d0,loop"],
    8, [2, 8, 2, 8, 2, 8, 2, 13], 4,
    "A real 4-pass DBF loop (ADDQ.L#1,Dn / DBF), not two copies of the "
    "same isolated instruction -- the first genuine steady-state loop "
    "measurement in this corpus. ALU_IMM 'ADDQ #(data),Rn' NCC=2 each "
    "(x4) + COND_BRANCH 'DBcc(cc=False,Count Not Expired)' NCC=8 (x3 "
    "taken) + 'DBcc(cc=False,Count Expired)' NCC=13 (x1, final "
    "fall-through) = 8+24+13=45 manual total.")

add('seq2_jsr_rts_pair', "JSR (An) / RTS / ADD Rn,Dn",
    ["movea.l #sub,a0", "move.l  #$10,d1", "clr.l   d2"],
    ["jsr     (a0)", "add.l   d1,d2"], 3, [7, 14, 2], 4,
    "A genuine call/return: JSR (An) to a real subroutine containing only "
    "RTS, then an ADD after the return -- the first real call/return "
    "sequence in this corpus (earlier BSR/JSR investigations, Phase 163 "
    "Track B, only ever measured the redirect in isolation). CONTROL_INSTR "
    "'%JSR' NCC=7 + 'RTS' NCC=14 + ALU 'ADD Rn,Dn' NCC=2 = 23 manual total.",
    tail_lines=["", "        org     $300", "sub:", "        rts"])

# ── Cluster H: longer heterogeneous chains (do longer real sequences keep
# shrinking the gap, plateau, or ever regress partway through?) ───────────
add('seq2_chain4', "ADD / NEG.L(An) / MOVE / SUB, 4 mixed instructions",
    ["movea.l #$3000,a0", "move.l  #5,($3000)",
     "move.l  #$10,d1", "clr.l   d2", "clr.l   d3"],
    ["add.l   d1,d2", "neg.l   (a0)", "move.l  d2,d3", "sub.l   d1,d3"],
    4, [2, 7, 2, 2], 8,
    "4-instruction heterogeneous chain: ADD Rn,Dn(2) / NEG.L(An)(7) / "
    "MOVE.L Dn,Dn(2) / SUB Rn,Dn(2). Manual sum=13.")

add('seq2_chain6', "6 mixed instructions: ALU/RMW/shift/MOVE",
    ["movea.l #$3000,a0", "move.l  #5,($3000)",
     "move.l  #$10,d1", "clr.l   d2"],
    ["add.l   d1,d2", "and.l   d1,d2", "neg.l   (a0)",
     "asl.l   #1,d2", "move.l  d2,d3", "clr.l   (a0)"],
    6, [2, 2, 7, 4, 2, 4], 12,
    "6-instruction heterogeneous chain: ADD(2)/AND(2)/NEG.L(An)(7)/"
    "ASL#1,Dn(4)/MOVE.L(2)/CLR.L(An)(4). Manual sum=21.")

add('seq2_chain8', "8 mixed instructions: full ALU family + RMW",
    ["movea.l #$3000,a0", "move.l  #5,($3000)",
     "move.l  #$10,d1", "clr.l   d2"],
    ["add.l   d1,d2", "and.l   d1,d2", "or.l    d1,d2", "eor.l   d1,d2",
     "sub.l   d1,d2", "cmp.l   d1,d2", "neg.l   (a0)", "clr.l   (a0)"],
    8, [2, 2, 2, 2, 2, 2, 7, 4], 16,
    "8-instruction heterogeneous chain covering the whole register ALU "
    "family plus two memory RMW ops. Manual sum=23.")

# ── Cluster I: hot-loop unrolled steady-state (does the incremental cost
# keep improving past instruction 2, or does it plateau immediately?) ────
add('seq2_hot_add_x8', "ADD Rn,Dn x8 unrolled",
    ["move.l  #1,d1", "clr.l   d2"],
    ["add.l   d1,d2"] * 8, 8, [2] * 8, 16,
    "8x unrolled ADD Rn,Dn (register-only steady state, not a loop -- "
    "straight-line repetition to see whether the incremental cost found "
    "for instruction 2 in the pilot corpus holds flat for instructions "
    "3-8 too, or keeps changing). Manual sum=16.")

add('seq2_hot_neg_x4', "NEG.L (An) x4 at 4 distinct addresses, unrolled",
    ["movea.l #$3000,a0", "movea.l #$3010,a1",
     "movea.l #$3020,a2", "movea.l #$3030,a3",
     "move.l  #5,($3000)", "move.l  #5,($3010)",
     "move.l  #5,($3020)", "move.l  #5,($3030)"],
    ["neg.l   (a0)", "neg.l   (a1)", "neg.l   (a2)", "neg.l   (a3)"],
    4, [7, 7, 7, 7], 8,
    "4x unrolled NEG.L (An) at 4 distinct addresses (RMW steady state, "
    "not a loop -- checks whether bus-contention-limited partial overlap "
    "found for the RMW pilot pair holds flat across more repetitions or "
    "degrades/improves further). Manual sum=28.")


def emit():
    manifest = []
    for t in TESTS:
        setup = "\n".join("        " + l for l in t['setup_lines'])
        body_lines = []
        for l in t['body_lines']:
            if l.endswith(':') and not l.startswith(' '):
                body_lines.append(l)
            else:
                body_lines.append("        " + l if not l.startswith('        ') else l)
        body = "\n".join(body_lines)
        tail = "\n".join(t['tail_lines'])
        src = TEMPLATE.format(name=t['name'], desc_short=t['desc_short'],
                               setup=setup, body=body, tail=tail)
        spath = OUTDIR / f"{t['name']}.s"
        spath.write_text(src)

        bpath = OUTDIR / f"{t['name']}.bin"
        r = subprocess.run(['vasmm68k_mot', '-Fbin', '-m68030', '-no-opt',
                             '-o', str(bpath), str(spath)],
                            capture_output=True, text=True)
        if r.returncode != 0 or 'warning' in (r.stdout + r.stderr).lower():
            print(f"ASSEMBLE ISSUE {t['name']}:\n{r.stdout}\n{r.stderr}")
            if r.returncode != 0:
                continue
        bpath.unlink()

        manifest.append({
            "name": t['name'],
            "hex": f"tests/timing/{t['name']}.hex",
            "target_pc": "0x200",
            "instr_len": t['instr_len'],
            "seq_len": t['seq_len'],
            "seq_isolated_ncc": t['seq_isolated_ncc'],
            "desc": t['desc'],
        })
        print(f"{t['name']}: OK (seq_len={t['seq_len']}, "
              f"manual_sum={sum(t['seq_isolated_ncc'])})")

    with open(OUTDIR / 'seq_tests2.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nWrote {len(manifest)} entries to seq_tests2.json")


if __name__ == '__main__':
    emit()

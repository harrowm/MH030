; tests/timing/seq_rmw_pair.s -- multi-instruction sequential timing
; measurement (Stage 7 follow-up plan). Two NEG.L (An) instructions at
; different addresses, back to back, no branch/marker between them.
; Tests whether the RMW-to-memory dispatch floor (already documented,
; ~+4 clocks for the plain-(An) cluster) shrinks in a real sequence the
; way the register-only and ext_count==2 clusters do, or whether real,
; unavoidable bus contention (both instructions need the SAME physical
; bus) limits how much overlap is actually possible here.
;
; MC68030UM.pdf 11-43/44: NEG Mem NCC=4(0/1/1) + fea((An))=3(1/0/0) = 7
; total (both instructions).
; Isolated (instr1, k=1): expect the already-documented +4 gap
; (measured 11 clocks vs manual 7). Sequential (instr2, k=2
; incremental): confirmed by hand-probing before this file was written
; to be a PARTIAL improvement only (49 ticks isolated via the
; retirement-pulse mechanism, 36 ticks/9 clocks incremental vs manual's
; 7 -- gap +4 -> +2), unlike the register-only/ext_count==2 clusters'
; own near-complete closure -- plausibly genuine bus-arbitration
; contention (a single physical bus can't serve two masters at once),
; not a bug.
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        movea.l #$3010,a1
        move.l  #5,($3000)
        move.l  #5,($3010)
        bra.w   target

        org     $200
target:
        neg.l   (a0)
        neg.l   (a1)
after:
        stop    #$2700
        dc.w    $2700

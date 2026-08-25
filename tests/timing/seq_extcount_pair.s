; tests/timing/seq_extcount_pair.s -- multi-instruction sequential
; timing measurement (Stage 7 follow-up plan). Two ADDI.L #imm,Dn
; instructions back to back (each ext_count==2, needing a genuine
; second IFU fetch when the queue starts empty -- Phase 165's own
; already-documented mechanism). Tests whether that second-fetch cost
; is hidden by overlap once a real sequence is running, not just for
; the isolated first instruction.
;
; MC68030UM.pdf 11-40/42: ADDI #(data),Dn NCC=2(0/1/0) +
; FIEA(#imm.L,Dn)=2(0/1/0) = 4 total (both instructions).
; Isolated (instr1, k=1): expect the already-documented +4 gap
; (measured 8 clocks vs manual 4). Sequential (instr2, k=2
; incremental): expect this to shrink substantially -- confirmed by
; hand-probing before this file was written (34 ticks isolated, 20
; ticks/5 clocks incremental, vs manual's 4 -- gap +4 -> +1).
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$10,d2
        move.l  #$10,d3
        bra.w   target

        org     $200
target:
        addi.l  #20,d2
        addi.l  #20,d3
after:
        stop    #$2700
        dc.w    $2700

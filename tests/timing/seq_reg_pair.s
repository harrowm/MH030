; tests/timing/seq_reg_pair.s -- multi-instruction sequential timing
; measurement (Stage 7 follow-up plan). Two ADD Dn,Dn instructions back
; to back, NO branch/marker between them -- ordinary sequential flow,
; so the second instruction genuinely benefits from whatever queue-fill
; work the IFU already did (independent of EX/WB, m68030_ifu.sv's own
; fetch_pend_r) while the first instruction was executing.
;
; MC68030UM.pdf 11-40/41: ADD Rn,Dn NCC=2(0/1/0) (both instructions).
; Isolated (instr1, k=1): expect this RTL's own already-established
; register-only floor, ~3 clocks (see known_issues.json's own
; a3_add_rn_dn entry). Sequential (instr2, k=2 incremental): expect
; this to be dramatically smaller, closer to or under NCC=2 -- this is
; the whole point of this test, confirmed by hand-probing before this
; file was written (14 ticks isolated, 3 ticks incremental).
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$10,d1
        clr.l   d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        add.l   d1,d2
        add.l   d2,d3
after:
        stop    #$2700
        dc.w    $2700

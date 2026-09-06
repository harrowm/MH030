; tests/timing/a8_cas_success.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS (Successful Compare)
; MC68030UM.pdf 11-49: ##CAS (Successful Compare) NCC=13(1/1/1)
;
;   cas.l   d1,d2,(a0)   (D1==mem -> compare succeeds, D2 writes to mem)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1000,a0
        move.l  #$11111111,($1000)
        move.l  #$11111111,d1        ; Dc -- matches memory
        move.l  #$22222222,d2        ; Du -- new value to write on success
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas.l   d1,d2,(a0)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700

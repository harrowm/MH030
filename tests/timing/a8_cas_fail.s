; tests/timing/a8_cas_fail.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS (Unsuccessful Compare)
; MC68030UM.pdf 11-49: ##CAS (Unsuccessful Compare) NCC=11(1/1/0)
;
;   cas.l   d1,d2,(a0)   (D1!=mem -> compare fails, D1 reloaded, no write)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1100,a0
        move.l  #$11111111,($1100)
        move.l  #$99999999,d1        ; Dc -- deliberately mismatched
        move.l  #$22222222,d2        ; Du -- must NOT reach memory
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas.l   d1,d2,(a0)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700

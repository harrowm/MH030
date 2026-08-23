; tests/timing/a1_fea_anpostinc.s — Phase 161 Part A Stage A1: fea "(An)+" row.
; MC68030UM.pdf 11-26: (An)+ Head=0,Tail=1, NCC=3(1/0/0) -- same r/p/w as
; (An), differs only in Head/Tail (overlap potential, not this stage's own
; r/p/w-only scope). Combined with MOVE EA,Dn op-table: total r/p/w=1/1/0.
;
;   MOVE.L (A0)+,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$DEADBEEF,d1
        move.l  d1,(a0)
        bra.w   target

        org     $200
target:
        move.l  (a0)+,d2
        stop    #$2700
        dc.w    $2700

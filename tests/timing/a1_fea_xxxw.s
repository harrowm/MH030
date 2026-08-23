; tests/timing/a1_fea_xxxw.s — Phase 161 Part A Stage A1: fea "(xxx).W" row.
; MC68030UM.pdf 11-26: (xxx).W Head=2,Tail=2, NCC=4(1/0/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=1/1/0.
;
;   MOVE.L $1000.W,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$DEADBEEF,d1
        move.l  d1,$1000
        bra.w   target

        org     $200
target:
        move.l  $1000.w,d2
        stop    #$2700
        dc.w    $2700

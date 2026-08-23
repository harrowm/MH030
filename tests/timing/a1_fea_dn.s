; tests/timing/a1_fea_dn.s — Phase 161 Part A Stage A1: fea "Dn" row.
; MC68030UM.pdf 11-26: Dn Head=—,Tail=—, NCC=0(0/0/0).
; Combined with MOVE EA,Dn op-table (11-37, NCC=2(0/1/0)): total r/p/w=0/1/0.
;
;   MOVE.L D0,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$DEADBEEF,d0
        bra.w   target

        org     $200
target:
        move.l  d0,d2
        stop    #$2700
        dc.w    $2700

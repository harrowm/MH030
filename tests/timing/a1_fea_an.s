; tests/timing/a1_fea_an.s — Phase 161 Part A Stage A1: fea "An" row.
; MC68030UM.pdf 11-26: An Head=—,Tail=—, NCC=0(0/0/0).
; Combined with MOVE EA,Dn op-table (11-37, NCC=2(0/1/0)): total r/p/w=0/1/0.
;
;   MOVE.L A1,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$DEADBEEF,a1
        bra.w   target

        org     $200
target:
        move.l  a1,d2
        stop    #$2700
        dc.w    $2700

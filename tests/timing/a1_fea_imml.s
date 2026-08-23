; tests/timing/a1_fea_imml.s — Phase 161 Part A Stage A1: fea "#(data).L" row.
; MC68030UM.pdf 11-26: #(data).L Head=4,Tail=0, NCC=4(0/1/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=0/2/0.
;
;   MOVE.L #$DEADBEEF,D2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.l  #$DEADBEEF,d2
        stop    #$2700
        dc.w    $2700

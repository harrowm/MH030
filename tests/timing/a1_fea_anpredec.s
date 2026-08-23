; tests/timing/a1_fea_anpredec.s — Phase 161 Part A Stage A1: fea "-(An)" row.
; MC68030UM.pdf 11-26: -(An) Head=2,Tail=2, NCC=4(1/0/0) -- same r/p/w as
; (An)/(An)+, one extra internal (non-bus) clock for the predecrement
; itself. Combined with MOVE EA,Dn op-table: total r/p/w=1/1/0.
;
;   MOVE.L -(A0),D2   (A0 pre-set to point one longword PAST the data)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2004,a0
        move.l  #$DEADBEEF,d1
        move.l  d1,($2000)
        bra.w   target

        org     $200
target:
        move.l  -(a0),d2
        stop    #$2700
        dc.w    $2700

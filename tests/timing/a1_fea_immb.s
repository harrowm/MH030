; tests/timing/a1_fea_immb.s — Phase 161 Part A Stage A1: fea "#(data).B" row.
; MC68030UM.pdf 11-26: #(data).B Head=2,Tail=0, NCC=2(0/1/0).
; Combined with MOVE EA,Dn op-table: total r/p/w=0/2/0.
;
;   MOVE.B #$AB,D2   (D2 cleared first so the byte-only write leaves a
;                     known, distinctive full-longword marker value)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        move.b  #$AB,d2
        stop    #$2700
        dc.w    $2700

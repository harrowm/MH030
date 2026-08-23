; tests/timing/a2_movec_read.s -- Phase 161 Part A Stage A2: Special-Purpose
; MOVE table "MOVEC Cr,Rn" row. MC68030UM.pdf 11-39: Head=6,Tail=0,
; NCC=6(0/1/0).
;
;   MOVEC VBR,D1   (after VBR set to $2000 in setup)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$2000,d0
        movec   d0,vbr
        clr.l   d1
        bra.w   target

        org     $200
target:
        movec   vbr,d1
        stop    #$2700
        dc.w    $2700

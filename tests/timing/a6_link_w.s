; tests/timing/a6_link_w.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'LINK.W'
; MC68030UM.pdf 11-48/49: LINK.W NCC=5(0/1/1)
;
;   link.w  a1,#-4
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1234,a1
        clr.l   d2
        bra.w   target

        org     $200
target:
        link.w  a1,#-4
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

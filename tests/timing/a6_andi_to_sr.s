; tests/timing/a6_andi_to_sr.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'ANDI to SR'
; MC68030UM.pdf 11-48/49: ANDI to SR NCC=14(0/2/0)
;
;   andi.w  #$FFFF,sr
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        andi.w  #$FFFF,sr
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

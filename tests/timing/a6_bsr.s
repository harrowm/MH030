; tests/timing/a6_bsr.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'BSR'
; MC68030UM.pdf 11-48/49: BSR NCC=9(0/2/1)
;
;   bsr.w   sub
        org     0
        dc.l    $00010000
        dc.l    start

start:

        bra.w   target

        org     $200
target:
        bsr.w   sub
        move.l  #$deadbeef,d2
sub:
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

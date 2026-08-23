; tests/timing/a6_chk_dn_dn_noexc.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'CHK Dn,Dn (No Exception)'
; MC68030UM.pdf 11-48/49: CHK Dn,Dn (No Exception) NCC=8(0/1/0)
;
;   chk     d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #10,d1
        move.l  #5,d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        chk     d1,d2
        move.l  #$cafebabe,d3
after:
        stop    #$2700
        dc.w    $2700

; tests/timing/a5_bset_dn_mem.s -- Phase 161 Part A Stage A5: BIT_MANIP '*BSET Dn,Mem'
; MC68030UM.pdf 11-45/46/47: BSET Dn,Mem NCC=6(0/1/1) + fea((An))=3(1/0/0)
;
;   bset    d1,(a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #0,($3000)
        move.l  #0,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        bset    d1,(a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

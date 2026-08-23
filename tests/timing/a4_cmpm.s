; tests/timing/a4_cmpm.s -- Phase 161 Part A Stage A4: BCD_EXT 'CMPM (An)+,(An)+'
; MC68030UM.pdf 11-43/11-44: CMPM (An)+,(An)+ NCC=8(2/1/0)
;
;   cmpm.l  (a0)+,(a1)+
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #1,($3000)
        movea.l #$3010,a1
        move.l  #1,($3010)
        clr.l   d2
        bra.w   target

        org     $200
target:
        cmpm.l  (a0)+,(a1)+
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

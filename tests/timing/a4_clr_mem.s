; tests/timing/a4_clr_mem.s -- Phase 161 Part A Stage A4: SINGLE_OP '**CLR Mem'
; MC68030UM.pdf 11-43/11-44: CLR Mem NCC=4(0/1/1) + cea((An))=2(0/0/0)
;
;   clr.l   (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #$FFFFFFFF,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        clr.l   (a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

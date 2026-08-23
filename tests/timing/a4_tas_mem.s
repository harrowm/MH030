; tests/timing/a4_tas_mem.s -- Phase 161 Part A Stage A4: SINGLE_OP '**TAS Mem'
; MC68030UM.pdf 11-43/11-44: TAS Mem NCC=12(1/1/1) + cea((An))=2(0/0/0)
;
;   tas     (a0)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #0,($3000)
        clr.l   d2
        bra.w   target

        org     $200
target:
        tas     (a0)
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

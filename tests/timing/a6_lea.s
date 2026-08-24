; tests/timing/a6_lea.s -- Phase 161 Part A Stage A6: CONTROL_INSTR '**LEA'
; MC68030UM.pdf 11-48/49: LEA NCC=2(0/1/0) + cea((An))=2(0/0/0)
; Cycle-accuracy-closing plan.md, item 3: watches A1 directly
; (watch_kind=1), no marker needed.
;
;   lea     (a0),a1
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        bra.w   target

        org     $200
target:
        lea     (a0),a1
after:
        stop    #$2700
        dc.w    $2700

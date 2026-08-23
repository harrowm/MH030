; tests/timing/a2_move_rn_an.s -- Phase 161 Part A Stage A2: MOVE table
; "Rn,An" row (MOVEA). MC68030UM.pdf 11-37: Head=2,Tail=0, NCC=2(0/1/0).
; An is not directly watchable -- a marker MOVE #imm,D2 follows to signal
; retirement; marker's own opcode fetch is program-space (excluded from
; both r_count and p_count, which is address-range-gated to the tested
; instruction alone) and has no bus write, so it can't perturb the count.
;
;   MOVE.L D1,A2

        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #$11111111,d1
        clr.l   d2
        bra.w   target

        org     $200
target:
        movea.l d1,a2
        move.l  #$cafebabe,d2
        stop    #$2700
        dc.w    $2700

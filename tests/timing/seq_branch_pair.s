; tests/timing/seq_branch_pair.s -- multi-instruction sequential timing
; measurement (Stage 7 follow-up plan). A real ALU op (whose own result
; sets Z=1) immediately followed by a taken BEQ, whose own condition
; genuinely depends on that preceding instruction's own result -- not
; isolated setup code. Checks whether the branch-redirect finding from
; this session's own direct trace (pc_wr_en fires the SAME cycle as
; instr_ack, combinationally, no wait for EX/WB) holds up when
; something real precedes the branch, not just idle setup.
;
; D1=0, D2=0 -> add.l d1,d2 leaves D2=0, sets Z=1 (clears N/V/C) --
; beq.w skip is then genuinely taken based on that real result.
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #0,d1
        move.l  #0,d2
        bra.w   target

        org     $200
target:
        add.l   d1,d2   ; sets Z=1 genuinely (0+0=0)
        beq.w   skip    ; taken, based on the ADD's own real result
skip:
after:
        stop    #$2700
        dc.w    $2700

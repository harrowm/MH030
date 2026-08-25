; tests/timing/seq_mixed3.s -- multi-instruction sequential timing
; measurement (Stage 7 follow-up plan). A heterogeneous 3-instruction
; sequence (register ALU op, then a memory RMW op, then another
; register ALU op) -- the first test of a realistic *mixed* sequence
; rather than two copies of the same instruction, to check whether the
; overlap benefit generalizes across instruction-class boundaries, not
; just within one repeated shape.
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        move.l  #5,($3000)
        move.l  #$10,d1
        clr.l   d2
        clr.l   d3
        bra.w   target

        org     $200
target:
        add.l   d1,d2   ; register-only ALU op
        neg.l   (a0)    ; memory RMW op
        add.l   d2,d3   ; register-only ALU op again
after:
        stop    #$2700
        dc.w    $2700

; tests/memind10.s — Stage 3 (plan.md Phase 118): full-format mode=110 EA
; with a non-null word base displacement for PEA and JSR indexed. JSR's own
; ext_count classifier (is_jsr_idx) was found missing entirely during this
; phase's survey -- is_jmp_idx only ever matched f_ss==2'b11 (JMP), never
; f_ss==2'b10 (JSR) -- a genuine pre-existing gap, fixed alongside the
; fi_is_full/fi_bd extension in the same m68030_seq.sv edit.
;
;   PEA ($100,A0,D1.L)        -- push EA=A0+$100+D1=$304 to -(A7); popped
;                                 back and dereferenced to prove the value
;   JSR ($100,A1,D1.L)        -- target = A1+$100+D1 = $404; a landing pad
;                                 placed there proves the jump target
;
; A0=$200, A1=$300, D1=$4.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$300,a1
        move.l  #$4,d1

        move.l  #$0000BEEF,d4
        move.l  d4,($304)      ; PEA target value

        pea     ($100,a0,d1.l)         ; push $304
        movea.l (a7)+,a3                ; pop it back, A3 = $304
        move.l  (a3),d3                  ; read M32[$304] -> proves PEA's EA

        move.l  #$DEAD0000,d6          ; poison; landing pad overwrites it

        jsr     ($100,a1,d1.l)          ; target = $404

        ; unreachable if JSR's EA is wrong
        stop    #$2700
        dc.w    $2700

        org     $404
        move.l  #$600DF00D,d6
        stop    #$2700
        dc.w    $2700

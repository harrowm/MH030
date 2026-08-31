; tests/memind25.s — open-items backlog Stage 7 (plan.md): MULU.L/MULS.L/
; DIVU.L/DIVS.L memory-EA forms. dec_is_muldivl was previously only ever
; set for the register-direct form (f_mode==000) -- the <ea>,Dl memory-
; source forms were entirely undecoded. This exercises 4 of the newly-
; added EA modes: (An), (An)+, (d16,An), (xxx).L -- one MUL and one DIV
; each of a register-indirect and a displacement/absolute shape, mixing
; signed and unsigned. Each result is written to a distinct memory
; address afterward so the actual computed value (not just the source
; read) is directly visible on the bus trace for buscmp.py.
;
;   MULU.L (A0),D2       -- A0=$200, M32[$200]=$50,          D2=$10  -> D2=$500
;   MULS.L (A1)+,D3       -- A1=$210, M32[$210]=-2,            D3=3    -> D3=-6, A1=$214
;   DIVU.L ($8,A2),D4     -- A2=$200, M32[$208]=7,             D4=100  -> D4=14
;   DIVS.L ($300).L,D5    -- M32[$300]=-4,                     D5=20   -> D5=-5

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$50,d7
        move.l  d7,(a0)
        move.l  #$10,d2
        mulu.l  (a0),d2
        move.l  d2,($400)

        movea.l #$210,a1
        move.l  #$FFFFFFFE,d7
        move.l  d7,(a1)
        move.l  #3,d3
        muls.l  (a1)+,d3
        move.l  d3,($404)
        move.l  a1,($408)

        movea.l #$200,a2
        move.l  #7,d7
        move.l  d7,($208)
        move.l  #100,d4
        divu.l  ($8,a2),d4
        move.l  d4,($40c)

        move.l  #$FFFFFFFC,d7
        move.l  d7,($300)
        move.l  #20,d5
        divs.l  ($300).l,d5
        move.l  d5,($410)

        stop    #$2700
        dc.w    $2700

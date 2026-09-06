; tests/memind40.s — docs/*.md review (plan.md §Phase 247): MULU.L/MULS.L/
; DIVU.L/DIVS.L indexed EA and #imm forms. Phase 192 (open-items backlog
; Stage 7) added the non-indexed memory-EA forms ((An)/(An)+/-(An)/(d16,An)/
; (xxx).W/(xxx).L/(d16,PC)) but explicitly deferred two: indexed
; (d8,An,Xn)/(d8,PC,Xn) (needs the dyn_bit_get_Dn 3rd-operand-deferred-
; register trick for the Xn-vs-Dl/Dq register-port conflict, same shape as
; CHK's own indexed form) and #imm (a 2nd 32-bit immediate word on top of
; the descriptor). Both were entirely undecoded until this phase -- real
; code using either form would hit an illegal-instruction fault. This
; exercises brief-indexed, full-format-indexed (word bd), and #imm, mixing
; MUL/DIV and signed/unsigned. Each result is written to a distinct memory
; address afterward so the actual computed value (not just the source read)
; is directly visible on the bus trace for buscmp.py.
;
;   MULU.L ($8,A0,D1.W),D2   -- brief indexed, A0=$200,D1=$8 -> EA=$210,
;                                M32[$210]=$50, D2=$10 -> D2=$500
;   DIVS.L ($8,A1,D1.L),D3   -- brief indexed, A1=$300,D1=$8 -> EA=$310,
;                                M32[$310]=-4, D3=20 -> D3=-5
;   MULS.L ($100,A2,D1.L),D4 -- full-format (word bd), A2=$400,D1=$8 ->
;                                EA=$508, M32[$508]=-3, D4=15 -> D4=-45
;   DIVU.L #12,D5            -- #imm, D5=100 -> D5=8 (quotient only, 32-bit form)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$8,d1
        move.l  #$50,d7
        move.l  d7,($210)
        move.l  #$10,d2
        mulu.l  ($8,a0,d1.w),d2
        move.l  d2,($600)

        movea.l #$300,a1
        move.l  #$FFFFFFFC,d7
        move.l  d7,($310)
        move.l  #20,d3
        divs.l  ($8,a1,d1.l),d3
        move.l  d3,($604)

        movea.l #$400,a2
        move.l  #$FFFFFFFD,d7
        move.l  d7,($508)
        move.l  #15,d4
        muls.l  ($100,a2,d1.l),d4
        move.l  d4,($608)

        move.l  #100,d5
        divu.l  #12,d5
        ; #imm forms get the same LONG artificial-internal-stall as the
        ; register-direct form (dec_is_mem_src is deliberately unset, no
        ; natural bus-read timing to spend real time on instead) -- three
        ; NOPs here let the IFU's own readahead settle before the result
        ; write, avoiding a benign but buscmp-visible reordering (the write
        ; landing several fetches later than program order) that a
        ; deliberately non-pipelined reference trace can't reproduce.
        nop
        nop
        nop
        move.l  d5,($60c)

        stop    #$2700
        dc.w    $2700

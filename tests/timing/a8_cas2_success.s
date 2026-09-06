; tests/timing/a8_cas2_success.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS2 (Successful Compare)
; MC68030UM.pdf 11-49: +CAS2 (Successful Compare) NCC=26(2/2/2)
;
;   cas2.l  d1:d3,d2:d4,(a0):(a1)   (both compares succeed -> both writes)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1200,a0
        movea.l #$1300,a1
        move.l  #$AAAA1111,($1200)
        move.l  #$BBBB2222,($1300)
        move.l  #$AAAA1111,d1        ; Dc1 -- matches mem[A0]
        move.l  #$CCCC3333,d2        ; Du1 -- new value for mem[A0]
        move.l  #$BBBB2222,d3        ; Dc2 -- matches mem[A1]
        move.l  #$DDDD4444,d4        ; Du2 -- new value for mem[A1]
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas2.l  d1:d3,d2:d4,(a0):(a1)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700

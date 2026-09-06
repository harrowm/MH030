; tests/timing/a8_cas2_fail.s -- docs/*.md review (plan.md §Phase 247
; item #9): CAS2 (Unsuccessful Compare)
; MC68030UM.pdf 11-49: +CAS2 (Unsuccessful Compare) NCC=24(2/2/0)
;
;   cas2.l  d1:d3,d2:d4,(a0):(a1)  (first compare fails -> neither writes)
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1400,a0
        movea.l #$1500,a1
        move.l  #$AAAA1111,($1400)
        move.l  #$BBBB2222,($1500)
        move.l  #$99999999,d1        ; Dc1 -- deliberately mismatched
        move.l  #$CCCC3333,d2        ; Du1 -- must NOT reach memory
        move.l  #$BBBB2222,d3        ; Dc2 -- matches mem[A1] (only Dc1 fails)
        move.l  #$DDDD4444,d4        ; Du2 -- must NOT reach memory either
        clr.l   d5
        bra.w   target

        org     $200
target:
        cas2.l  d1:d3,d2:d4,(a0):(a1)
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700

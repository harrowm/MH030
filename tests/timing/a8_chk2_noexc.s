; tests/timing/a8_chk2_noexc.s -- docs/*.md review (plan.md §Phase 247
; item #9): CHK2 Mem,Rn (No Exception)
; MC68030UM.pdf 11-49: #+CHK2 Mem,Rn (No Exception) NCC=18(1/1/0)
;
;   chk2.w  (a0),d1   (bounds [10,20], D1=15 -- in range, no exception)
;
; .w size deliberately chosen (not .l, used elsewhere in this project's own
; memind36.s/37.s cosim tests): a .w pair of bounds (lower word + upper word)
; packs into exactly ONE longword read, matching this row's own NCC r=1
; directly -- .l bounds need two separate longword reads instead (8 bytes),
; which is a different row shape this table doesn't have a dedicated entry
; for.
        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1600,a0
        move.l  #$000A0014,($1600)   ; lower=10 ($000A), upper=20 ($0014)
        move.l  #15,d1                ; in [10,20] -- no exception
        clr.l   d5
        bra.w   target

        org     $200
target:
        chk2.w  (a0),d1
        move.l  #$cafebabe,d5
after:
        stop    #$2700
        dc.w    $2700

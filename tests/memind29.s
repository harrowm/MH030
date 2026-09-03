; tests/memind29.s — 10-item backlog Stage 9a (plan.md): PEA's own genuine
; memory-indirect EA, ([bd,An],Xn,od) with fi_iis != 0 -- unlike LEA, PEA
; still needs a real outer bus cycle (it pushes the resolved EA to the
; stack), but that cycle is a WRITE at the stack address (not a read at
; the resolved address). This test's own bus trace should show the SAME
; inner pointer read memind28.s already proved, plus exactly one WRITE at
; A7-4 (the stack), carrying the resolved EA as its own data -- and no
; other access at the resolved address itself.
;
;   Post-indexed, word bd, null od:
;     ([$100,A0],D1.L) -> EA = M32[A0+$100] + D1
;
; A0=$1000, D1=$4, pointer at M32[$1100]=$2000 -> EA = $2000+$4 = $2004.
; Boot SSP=$10000 (from the reset vector below), so A7-4 = $FFFC after
; the push -- PEA's own predecrement -- and the pushed value at M32[$FFFC]
; is compared directly by buscmp.py's own full (not reads-only) mode.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1000,a0
        move.l  #$4,d1

        move.l  #$2000,d4
        move.l  d4,($1100)       ; M32[a0+$100] = $2000 (pointer)

        pea     ([$100,a0],d1.l)   ; post-indexed, word bd, null od
                                    ; pushes $2004 to [A7-4]

        stop    #$2700
        dc.w    $2700

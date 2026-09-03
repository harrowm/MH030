; tests/memind28.s — 10-item backlog Stage 9a (plan.md): LEA's own genuine
; memory-indirect EA, ([bd,An],Xn,od) with fi_iis != 0 -- the first family
; beyond MOVE/MOVEA to support this. LEA never dereferences its own final
; EA (no outer bus cycle at all, unlike MOVE's own memind arm, which needs
; a further access to LOAD a value); this test's own bus trace directly
; proves that: only the instruction fetch words and the ONE inner pointer
; read should appear, never a second access at the resolved EA.
;
;   Post-indexed, word bd, null od:
;     ([$100,A0],D1.L) -> EA = M32[A0+$100] + D1
;
; A0=$1000, D1=$4, pointer at M32[$1100]=$2000 -> EA = $2000+$4 = $2004.
; The computed EA is then stored to memory (a genuine bus WRITE) so
; buscmp.py's own full comparison (not just reads-only) can directly prove
; the resolved address itself, not just the reads leading up to it.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$1000,a0
        move.l  #$4,d1

        move.l  #$2000,d4
        move.l  d4,($1100)       ; M32[a0+$100] = $2000 (pointer)

        lea     ([$100,a0],d1.l),a2   ; post-indexed, word bd, null od
        move.l  a2,($1200)             ; store the computed EA for comparison

        stop    #$2700
        dc.w    $2700

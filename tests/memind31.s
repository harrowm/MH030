; tests/memind31.s — 10-item backlog Stage 9b (plan.md): JSR's own genuine
; memory-indirect EA, ([bd,An],Xn,od) with fi_iis != 0. Same outer-write
; shape as PEA's own memind arm, but JSR pushes the RETURN PC (not the
; resolved EA) and then jumps to the resolved address. Deliberately kept
; entirely within tools/m68ksim's own 4KB reference window (see
; memind30.s's own header comment for why).
;
;   Post-indexed, word bd, null od:
;     ([$100,A0],D1.L) -> target = M32[A0+$100] + D1
;
; A0=$200, D1=$500, pointer at M32[$300]=$800 -> target = $D00.
; Code at $D00 sets D2=$7777 then stops -- reachable only if the jump
; itself worked; the pushed return-PC VALUE is checked by buscmp.py's own
; full comparison against Musashi's own reference push.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$500,d1

        move.l  #$800,d4
        move.l  d4,($300)        ; M32[a0+$100] = $800 (pointer)

        jsr     ([$100,a0],d1.l)   ; post-indexed, word bd, null od -> $D00

        ; not reached (JSR doesn't fall through)
        move.l  #$DEAD,d3
        stop    #$2700

        org     $D00
        move.l  #$7777,d2
        stop    #$2700
        dc.w    $2700

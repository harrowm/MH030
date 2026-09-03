; tests/memind30.s — 10-item backlog Stage 9b (plan.md): JMP's own genuine
; memory-indirect EA, ([bd,An],Xn,od) with fi_iis != 0. JMP shares LEA's
; own address-only shape: no outer bus cycle at all, becomes the new PC
; directly once the inner pointer read lands. Verified by landing on code
; at the resolved address that sets a distinct marker value.
;
; Deliberately kept entirely within tools/m68ksim's own 4KB (1024-word)
; reference-memory window (every address here is < $1000, so nothing
; aliases) -- unlike memind13/16/17/21's own large-magnitude-displacement
; technique (deliberately relying on that same aliasing to force
; full-format encoding while the two real operands still land on
; consistent, matching locations in both DUT and reference), a JMP TARGET
; landing on an aliased address is genuinely unsafe here: the reference
; tool would silently read/execute whatever else already lives at the
; wrapped address instead of this test's own intended landing code.
;
;   Post-indexed, word bd, null od:
;     ([$100,A0],D1.L) -> target = M32[A0+$100] + D1
;
; A0=$200, D1=$500, pointer at M32[$300]=$800 -> target = $D00.
; Code at $D00 sets D2=$7777 then stops.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$500,d1

        move.l  #$800,d4
        move.l  d4,($300)        ; M32[a0+$100] = $800 (pointer)

        jmp     ([$100,a0],d1.l)   ; post-indexed, word bd, null od -> $D00

        ; not reached
        move.l  #$DEAD,d3
        stop    #$2700

        org     $D00
        move.l  #$7777,d2
        stop    #$2700
        dc.w    $2700

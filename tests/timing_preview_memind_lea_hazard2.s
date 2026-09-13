; tests/timing_preview_memind_lea_hazard2.s -- Track 3 #12 (memory-
; indirect) verification, variant 2: non-hazard control for
; timing_preview_memind_lea_hazard.s. NEXT's own base register (A3) is
; NOT the register LEA writes (A2), so memind_addr_hazard should read 0
; and preview_ok should actually fire (=1).
;
;   LEA ([$100,A0],D1.L),A2   ; producer: A2 <- $314 -- does NOT touch A3
;   MOVE.L (A3),D3            ; <-- NEXT: base=A3 (untouched by LEA)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$300,a0
        move.l  #$4,d1
        move.l  #$310,d4
        move.l  d4,$400          ; M32[A0+$100] = $310 (the pointer LEA reads)
        movea.l #$330,a3
        move.l  #$C0FFEE00,d4
        move.l  d4,(a3)          ; M[$330] -- NEXT's own real read target
        bra.w   target

        org     $200
target:
        lea     ([$100,a0],d1.l),a2   ; <-- producer: A2 <- $314 (A3 untouched)
        move.l  (a3),d3               ; <-- NEXT: base=A3, should read M[$330]=$C0FFEE00
        stop    #$2700
        dc.w    $2700

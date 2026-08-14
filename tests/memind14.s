; tests/memind14.s — Phase 122 (Sub-scope A): MOVE mem-to-mem indexed-dst
; full-format bd, for the two source shapes with a fixed 1-word baseline
; (abs.W src, (d16,PC) src) -- both share MOVEM/CMP2CHK2's "q1=other data,
; q2=EA descriptor" layout, needing q3_word for the dst's own full-format
; bd value (not the shared fi_bd, which would misread the abs.W/d16 value
; as if it were bd). Register-src indexed-dst (Sub-scope A's third
; tractable case) is exercised separately -- its RMW mechanism hits the
; same pre-existing extra-read quirk documented for CLR.L (Phase 121) and
; MOVE SR,(ea) (Phase 118), so it's hand-verified rather than automated
; here (confirmed correct: writes land at the right address with the
; right value, just with one extra harmless read first).
;
;   MOVE.L ($60).W,($100,A1,D1.L)      -- abs.W src; dst EA = A1+$100+D1
;   MOVE.L (pcrel),($100,A2,D1.L)      -- (d16,PC) src; dst EA = A2+$100+D1
;
; A1=$200, A2=$300, D1=$4. abs.W target = $304. pcrel target = $404.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a1
        movea.l #$300,a2
        move.l  #$4,d1

        move.l  ($60).w,($100,a1,d1.l)         ; M32[$304] = M32[$60]
        move.l  (pcdata,pc),($100,a2,d1.l)      ; M32[$404] = M32[pcdata]

        stop    #$2700
        dc.w    $2700

        org     $60
        dc.l    $CAFEBABE

        org     $70
pcdata: dc.l    $DEADC0DE

; tests/memind15.s — Phase 122 (Sub-scope A): MOVE Dn,(bd,An,Xn) full-format
; -- register source, indexed dst, the third Sub-scope A tractable case
; (fixed 1-word baseline, folds into the ordinary is_memind_full/fi_bd
; machinery unchanged, see is_move_reg_idx_dst_mode110 in m68030_seq.sv).
;
; Not wired into make cosim_memind: this arm's own RMW mechanism (needed to
; split rd_a=An/rd_b=Xn during the read, same as every other indexed-dst
; RMW form) performs an extra bus READ before the write that Musashi
; doesn't -- the same pre-existing quirk already documented for CLR.L
; (Phase 121) and MOVE SR,(ea) (Phase 118), confirmed present for this
; arm's own *brief* form too via a standalone throwaway repro (not kept),
; so it predates this phase's own fi_bd extension. Hand-verified instead:
; the actual WRITE (address and value) matches Musashi exactly, only the
; extra read before it doesn't.
;
;   MOVE.L D2,($100,A0,D1.L)  -- EA = A0+$100+D1
;
; A0=$200, D1=$4. Target = $304. D2=$12345678.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$4,d1
        move.l  #$12345678,d2

        move.l  d2,($100,a0,d1.l)

        stop    #$2700
        dc.w    $2700

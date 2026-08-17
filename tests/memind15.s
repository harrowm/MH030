; tests/memind15.s — Phase 122 (Sub-scope A): MOVE Dn,(bd,An,Xn) full-format
; -- register source, indexed dst, the third Sub-scope A tractable case
; (fixed 1-word baseline, folds into the ordinary is_memind_full/fi_bd
; machinery unchanged, see is_move_reg_idx_dst_mode110 in m68030_seq.sv).
;
; FIXED (Phase 149, plan.md): this arm used to be RMW (a real, unnecessary
; extra bus READ before the write, purely to get An+Xn on 2 simultaneous
; register-file ports -- the same pre-existing quirk documented for CLR.L
; (Phase 121) and MOVE SR,(ea) (Phase 118) before Phase 144 fixed those
; two). MOVE Dn,(d8,An,Xn) needed a genuine 3rd register-file read port
; (rd_c) since An+Xn+the source register are all needed live in the same
; write cycle, with no bus-ack event to key a 2-port deferred swap off --
; Phase 148 added rd_c, Phase 149 wired this arm to use it. Now a genuine
; single-phase write; wired into `make cosim_memind` as `buscmp-memind15`,
; comparing the FULL trace (reads and the write), not just --reads-only.
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

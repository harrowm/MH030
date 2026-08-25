; tests/timing/a6_dbcc_true.s -- Phase 161 Part A Stage A6: COND_BRANCH 'DBcc (cc=True)'
; MC68030UM.pdf 11-48/49: DBcc (cc=True) NCC=8(0/1/0)
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): DBcc
; with cc=true does not decrement Dn (rtl/eu_seq.sv's own wb_writes_reg
; formula explicitly suppresses the write in this case) and never writes
; CCR either, so no trailing marker is needed -- completion is detected
; directly via DBcc's own EX->WB retirement.
;
;   dbeq    d0,land
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d0
        move.w  #4,ccr
        bra.w   target

        org     $200
target:
        dbeq    d0,land
after:
        stop    #$2700
land:
        dc.w    $2700

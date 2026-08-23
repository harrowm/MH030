; tests/timing/a6_dbcc_false_notexp.s -- Phase 161 Part A Stage A6: COND_BRANCH 'DBcc (cc=False,Count Not Expired)'
; MC68030UM.pdf 11-48/49: DBcc (cc=False,Count Not Expired) NCC=8(0/2/0)
;
;   dbeq    d0,land
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #5,d0
        clr.l   d2
        move.w  #0,ccr
        bra.w   target

        org     $200
target:
        dbeq    d0,land
        move.l  #$deadbeef,d2
        bra.s   after2
land:
        move.l  #$cafebabe,d2
after2:
after:
        stop    #$2700
        dc.w    $2700

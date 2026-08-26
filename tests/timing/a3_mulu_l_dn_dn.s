; tests/timing/a3_mulu_l_dn_dn.s -- MUL timing investigation
; MC68030UM.pdf 11-40/41/42: MULU.L Dr,Dq (32-bit x 32-bit) NCC=44(0/1/0)
;
;   mulu.l  d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #7,d1
        move.l  #123,d2
        bra.w   target

        org     $200
target:
        mulu.l  d1,d2
after:
        stop    #$2700
        dc.w    $2700

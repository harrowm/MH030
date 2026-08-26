; tests/timing/a3_divs_l_dn_dn.s -- DIV timing investigation
; MC68030UM.pdf 11-40/41/42: DIVS.L Dr,Dq (32-bit/32-bit) NCC=90(0/1/0)
;
;   divs.l  d1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #7,d1
        move.l  #1000000,d2
        bra.w   target

        org     $200
target:
        divs.l  d1,d2
after:
        stop    #$2700
        dc.w    $2700

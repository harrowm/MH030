; tests/grp2.s — Group 2 (bits[15:12]=0010)
; MOVE.L register-to-register
; Expected: D0=$55, D1=$55, D2=$7f, D3=$7f, D4=0, D5=0

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #$55,d0
        move.l  d0,d1           ; D1 = $55
        moveq   #$7f,d2
        move.l  d2,d3           ; D3 = $7f
        moveq   #0,d4
        move.l  d4,d5           ; D5 = 0
        moveq   #-1,d6
        move.l  d6,d7           ; D7 = $FFFFFFFF
        stop    #$2700
        dc.w    $2700

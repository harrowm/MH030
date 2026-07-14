; tests/grp3.s — Group 3 (bits[15:12]=0011)
; MOVE.W register-to-register
; MOVE.W sets destination low word; upper word unchanged
; Expected: D0=$55, D1=$55, D2=$7f, D3=$7f, D4=0, D5=$FFFF0000

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #$55,d0
        moveq   #0,d1
        move.w  d0,d1           ; D1[15:0] = $0055
        moveq   #$7f,d2
        moveq   #0,d3
        move.w  d2,d3           ; D3[15:0] = $007f
        moveq   #0,d4
        moveq   #-1,d5          ; D5 = $FFFFFFFF
        move.w  d4,d5           ; D5[15:0] = 0; upper = $FFFF → D5 = $FFFF0000
        stop    #$2700
        dc.w    $2700

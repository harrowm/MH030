; tests/grp1.s — Group 1 (bits[15:12]=0001)
; MOVE.B register-to-register
; Expected: D0=$55, D1=$55, D2=7, D3=7, D4=0, D5=0

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #$55,d0
        moveq   #0,d1
        move.b  d0,d1           ; D1[7:0] = $55
        moveq   #7,d2
        moveq   #0,d3
        move.b  d2,d3           ; D3[7:0] = 7
        moveq   #0,d4
        moveq   #$7f,d5
        move.b  d4,d5           ; D5[7:0] = 0
        stop    #$2700
        dc.w    $2700

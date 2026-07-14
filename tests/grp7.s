; tests/grp7.s — Group 7 (bits[15:12]=0111)
; MOVEQ — sign-extends 8-bit immediate to 32 bits
; Expected: D0=1, D1=$FFFFFFFF, D2=$7F, D3=0, D4=$FFFFFF80

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #1,d0           ; D0 = $00000001
        moveq   #-1,d1          ; D1 = $FFFFFFFF
        moveq   #$7f,d2         ; D2 = $0000007F (max positive)
        moveq   #0,d3           ; D3 = $00000000
        moveq   #-128,d4        ; D4 = $FFFFFF80 (min negative)
        stop    #$2700
        dc.w    $2700

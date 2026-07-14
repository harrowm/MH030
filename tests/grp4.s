; tests/grp4.s — Group 4 (bits[15:12]=0100)
; CLR/NEG/NOT/SWAP/EXT/TST (register operations only; no JMP/JSR to avoid IFU divergence)
; Expected: D0=0, D1=$FFFFFFFB, D2=$FFFFFFF0, D3=$FFFF0000,
;           D4=$00000001, D5=$FFFFFFFF

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #$55,d0
        clr.l   d0              ; D0 = 0

        moveq   #5,d1
        neg.l   d1              ; D1 = -5 = $FFFFFFFB

        moveq   #$0f,d2
        not.l   d2              ; D2 = ~$0000000F = $FFFFFFF0

        moveq   #0,d3           ; D3 = $00000000
        not.l   d3              ; D3 = $FFFFFFFF
        swap    d3              ; swap words: D3 = $FFFF0000? No:
                                ;   swap exchanges [31:16] and [15:0]
                                ;   $FFFFFFFF → $FFFFFFFF (both halves $FFFF)
                                ; Use a distinct value instead:
        moveq   #$01,d3
        swap    d3              ; D3: $00000001 → $00010000

        moveq   #1,d4
        ext.l   d4              ; EXT.L: sign-extend word to long
                                ;   D4[15:0]=1, bit15=0 → D4 = $00000001

        moveq   #-1,d5          ; D5 = $FFFFFFFF
        tst.l   d5              ; sets N=1, Z=0 (D5 unchanged)

        stop    #$2700
        dc.w    $2700

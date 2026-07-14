; tests/grp5.s — Group 5 (bits[15:12]=0101)
; ADDQ/SUBQ/Scc
; (DBcc avoided: always-false loop would require branches causing IFU divergence)
; Expected: D0=14, D1=0, D2=$FF, D3=0

        org     0
        dc.l    $00010000
        dc.l    start

start:
        moveq   #10,d0
        addq.l  #7,d0           ; D0 = 17
        subq.l  #3,d0           ; D0 = 14

        moveq   #0,d1           ; D1 = 0, sets Z=1
        tst.l   d1              ; confirm Z=1

        seq     d2              ; SEQ: D2[7:0]=$FF if Z=1 → D2=$000000FF
        sne     d3              ; SNE: D3[7:0]=$00 if Z=1 → D3=$00000000

        addq.w  #1,d0           ; D0 word increment: low word 14→15
        subq.w  #1,d0           ; D0 word decrement: 15→14

        stop    #$2700
        dc.w    $2700

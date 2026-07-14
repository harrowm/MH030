; tests/grp0.s — Group 0 (bits[15:12]=0000)
; ORI/ANDI/SUBI/ADDI/EORI/CMPI, BTST/BCHG/BCLR/BSET
; Sequential program; expected D0=$12CB00FF, D1=12, D2=8

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        moveq   #0,d0
        ori.l   #$12345678,d0   ; D0 = $12345678
        andi.l  #$FFFF00FF,d0   ; D0 = $12340078
        eori.l  #$00FF0087,d0   ; D0 = $12CB00FF

        moveq   #10,d1
        addi.l  #5,d1           ; D1 = 15
        subi.l  #3,d1           ; D1 = 12
        cmpi.l  #12,d1          ; Z=1 (D1 unchanged)

        moveq   #0,d2
        bset    #3,d2           ; D2 = $00000008  (bit 3 set)
        btst    #3,d2           ; test bit 3 → Z=0
        bchg    #3,d2           ; D2 = $00000000  (bit 3 cleared)
        bset    #3,d2           ; D2 = $00000008  (set again)
        bclr    #3,d2           ; D2 = $00000000

        stop    #$2700
        dc.w    $2700

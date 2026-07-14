; tests/grp6.s — Group 6 (bits[15:12]=0110)
; BRA/BSR/Bcc
;
; Only NOT-TAKEN conditional branches appear before the BRA, so the initial
; instruction fetches are sequential and match Musashi exactly.  The BRA at
; the end causes IFU refetch divergence; use --max 6 when running buscmp.
;
; Expected: D0=1 (all not-taken branches fell through; BRA jumped to done)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        ; After MOVEQ #1,d0: Z=0, N=0, V=0, C=0
        moveq   #1,d0

        ; NOT-TAKEN branches (condition false → fall through)
        beq.b   fail            ; Z=0 → not taken
        bmi.b   fail            ; N=0 → not taken
        bcs.b   fail            ; C=0 → not taken
        bvs.b   fail            ; V=0 → not taken
        blt.b   fail            ; N^V=0 → not taken
        ble.b   fail            ; Z|(N^V)=0 → not taken

        ; BRA (always taken) — at end so divergence is trailing
        bra.b   done

fail:
        moveq   #-1,d0          ; D0=$FFFFFFFF indicates unexpected branch taken

done:
        stop    #$2700
        dc.w    $2700

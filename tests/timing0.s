; tests/timing0.s — Phase 159 Stage 0: measurement-protocol calibration target.
;
; MOVE.L ($1000,A0,D1.L),D2  -- full-format indexed src EA, register dest.
; Per MC68030UM.pdf Section 11 (manual pages 11-27 fea table + 11-37 MOVE
; table, both read directly this session):
;   fea "(d16,An,Xn) or (d16,PC,Xn)" (full-format ext word): NCC=7(1/1/0)
;   MOVE "EA,Dn" op-table entry:                              NCC=2(0/1/0)
;   Combined (additive, footnote '*' on MOVE EA,Dn):           NCC=9(1/2/0)
;
; A0=$2000, D1=4 (long index, scale 1) -> EA = $2000+$1000+4 = $3004.
; Preceding code writes $DEADBEEF there, then a taken BRA.W lands directly
; on the instruction under test. `target` is placed far (0x200 bytes)
; past the branch's own physical location -- well outside the IFU's own
; prefetch-queue readahead distance -- so linear speculative prefetch
; can never reach it before the jump actually redirects PC there. (An
; earlier draft placed `target` immediately after the branch in program
; order; ordinary linear readahead had already fetched its opcode word
; long before the branch executed, silently defeating the whole
; isolation technique -- caught via the r/p bus-event counts coming out
; far lower than expected.) This is the isolation technique NCC's own
; "no overlap with the preceding instruction" definition calls for.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$2000,a0
        moveq   #4,d1
        move.l  #$DEADBEEF,d4
        move.l  d4,($1004,a0)
        bra.w   target

        org     $200
target:
        move.l  ($1000,a0,d1.l),d2      ; <-- instruction under test
        stop    #$2700
        dc.w    $2700

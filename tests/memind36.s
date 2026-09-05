; tests/memind36.s — CMP2's own genuine memory-indirect EA (plan.md, deferred
; item from Phase 238, now implemented): the FSM merge between the shared
; memind FSM (resolving the lower bound's own address) and cmp2_run_r's own
; pre-existing two-read FSM (which then independently reads the upper bound
; at lower_addr+size). Verified via CONTROL FLOW: CMP2 sets no register
; result directly comparable, so the C flag (out-of-bounds) is proven via a
; conditional branch immediately after -- a wrong C flag (or a bug in the
; lower-bound address itself) would take the DUT down the wrong path,
; producing a completely different (and therefore mismatching) bus trace.
;
;   Pre-indexed, word bd, null od: ([$100,A0,D1.L])
;
; A0=$2000, D1=$8 -> inner=$2108, pointer at M32[$2108]=$3000 -> lower bound
; EA=$3000, upper bound EA=$3004 (size=L, so +4). Lower=10, upper=20,
; D2=15 (within [10,20]) -> C=0 -> BCC taken -> D5=$600D.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.l  #10,d4
        move.l  d4,($3000)      ; lower bound

        move.l  #20,d4
        move.l  d4,($3004)      ; upper bound

        move.l  #15,d2          ; tested value, within [10,20] -> C=0 expected

        cmp2.l  ([$100,a0,d1.l]),d2   ; pre-indexed, word bd, null od

        bcc.b   inrange
        move.l  #$00000BAD,d5
        bra.b   done
inrange:
        move.l  #$0000600D,d5
done:
        move.l  d5,($3100)      ; store the branch outcome for comparison

        stop    #$2700
        dc.w    $2700

; tests/memind8.s — Stage 2 (plan.md Phase 116/117): full-format mode=110 EA
; with a non-null word base displacement for dynamic BSET (representative of
; BTST/BCHG/BCLR/BSET Dn,ea, which all share the same dyn_bit_get_Dn
; deferred-register decode path). Confirms the register-conflict handling
; is orthogonal to the EA-offset fix -- no new mechanism needed, only reuse
; of Stage 1's template.
;
;   BSET D4,($100,A0,D1.L)  -- EA = A0+$100+D1
;
; A0=$200, D1=$4. Target = $304. Byte at $304 starts at $00 (top byte of
; longword $00000005 written beforehand); bit 3 set -> $08.
;
; Not wired into make cosim_memind: BSET's own memory destination is a byte
; RMW, and this testbench's bus logger shows the full 32-bit internal
; register for a byte-sized transfer rather than just the transferred byte
; (confirmed the same pattern for TAS's own byte writes in Stage 1/
; tests/memind5.s -- a pre-existing, recurring limitation for any byte-
; sized RMW, unrelated to memory-indirect EA specifically). Hand-verified
; instead: DUT's own byte read ($304, top byte of the logged word = $00)
; and write ($304, top byte = $08) both match Musashi's own $00/$08 exactly
; once the irrelevant lower 3 bytes of the DUT's wider log line are
; ignored.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        move.l  #$4,d1

        move.l  #$00000005,d4
        move.l  d4,($304)      ; target longword; top byte = $00

        moveq   #3,d4           ; bit 3
        bset    d4,($100,a0,d1.l)

        stop    #$2700
        dc.w    $2700

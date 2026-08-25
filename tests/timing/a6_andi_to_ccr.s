; tests/timing/a6_andi_to_ccr.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'ANDI to CCR'
; MC68030UM.pdf 11-48/49: ANDI to CCR NCC=14(0/2/0)
;
; reliable-baseline plan (investigated, deliberately kept as-is): same
; finding as a6_andi_to_sr.s -- a direct trace confirmed this test's own
; measured 13-clock total (with the marker) matches ANDI-to-SR's own
; single-word-at-a-time IFU queue-refill pattern exactly, even though
; ANDI-to-CCR only touches CCR (no S/M/T bits). Empirically this RTL
; doesn't distinguish CCR-only writes from full-SR writes for that queue-
; refill behavior. Do not "fix" this by switching to watch_kind=2 -- see
; a6_andi_to_sr.s and plan.md's reliable-baseline-plan writeup.
;
;   andi    #$FF,ccr
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        andi    #$FF,ccr
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

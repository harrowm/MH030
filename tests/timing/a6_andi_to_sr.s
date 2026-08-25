; tests/timing/a6_andi_to_sr.s -- Phase 161 Part A Stage A6: CONTROL_INSTR 'ANDI to SR'
; MC68030UM.pdf 11-48/49: ANDI to SR NCC=14(0/2/0)
;
; reliable-baseline plan (investigated, deliberately kept as-is): this
; test's own trailing marker looks like the same "marker inflation" bug
; fixed elsewhere in that plan, but it is NOT one -- a direct trace
; confirmed ANDI-to-SR forces the IFU to refill its prefetch queue one
; word at a time afterward (matching Phase 96/98's own documented S/M
; bank-switch queue-flush finding), a real cost that blocks the *next*
; instruction's own dispatch, which is exactly what NCC's own "no overlap
; with the following instruction" definition means to capture. A
; value-based watch (kind 0/1/2/3, all of which fire at ANDI's own
; internal CCR/SR commit) fires BEFORE that refill completes and would
; silently under-measure this instruction by ~10 clocks -- the marker's
; own dispatch, which genuinely has to wait for the refill, is the
; only way to capture the NCC-relevant time this instruction actually
; costs. Do not "fix" this by switching to watch_kind=2 -- see plan.md's
; reliable-baseline-plan writeup for the trace that established this.
;
;   andi.w  #$FFFF,sr
        org     0
        dc.l    $00010000
        dc.l    start

start:
        clr.l   d2
        bra.w   target

        org     $200
target:
        andi.w  #$FFFF,sr
        move.l  #$cafebabe,d2
after:
        stop    #$2700
        dc.w    $2700

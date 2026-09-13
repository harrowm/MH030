; tests/timing_preview_two_writes.s -- investigation (temporary): does
; biu_cache_if.sv's own PRE-EXISTING CI_IDLE combinational pass-through
; (Track A, Phase 163; the D-cache hit fast-path, Phase 247 item #10)
; already give back-to-back ordinary writes zero added latency, entirely
; independent of the EU-side preview mechanism (Track 1/2)? Mirrors
; tests/timing_preview.s's own back-to-back (An) READ pair exactly, but
; for WRITES, to isolate biu_cache_if.sv's own CI_IDLE transit specifically
; from any EU-side decode/dispatch latency (a 3rd, separately-fetched
; instruction would confound the measurement -- see the write_hazard
; test's own inconclusive result).

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$3000,a0
        movea.l #$3010,a1
        move.l  #$11111111,d4
        move.l  #$22222222,d5
        bra.w   target

        org     $200
target:
        move.l  d4,(a0)         ; <-- instruction under test #1: plain write
        move.l  d5,(a1)         ; <-- instruction under test #2, immediately follows
        stop    #$2700
        dc.w    $2700

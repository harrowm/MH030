; tests/timing/a6_bcc_b_not_taken.s -- Phase 161 Part A Stage A6: COND_BRANCH 'Bcc.B (Not Taken)'
; MC68030UM.pdf 11-48/49: Bcc.B (Not Taken) NCC=4(0/1/0)
;
; watch_kind=3 (retirement-pulse tracking, reliable-baseline plan): Bcc
; not-taken writes no register/CCR (Bcc never writes CCR), so no trailing
; marker is needed -- completion is detected directly via Bcc's own
; EX->WB retirement.
;
; timing-gaps-largest-first plan, Stage 3 (real bug found, not RTL):
; `skip:` used to sit immediately after this branch (displacement=0),
; which vasm silently substitutes with its own "LEA (An),An" 2-byte
; NOP-equivalent placeholder for a degenerate zero-distance short branch
; (confirmed via vasm's own listing/warning output: "short-branch to
; following instruction turned into a nop") -- this test had NEVER
; actually exercised a real Bcc.B opcode since Phase 161 first created
; it; its own "exact gap=0 match" was really measuring LEA (An),An
; (which happens to share Bcc.B-not-taken's own manual NCC=4 purely by
; coincidence, via the pre-existing, unrelated LEA whitelist entry).
; Fixed by inserting a real NOP so the branch has a genuine, non-
; degenerate 4-byte displacement and assembles to the real bne.b opcode.
;
;   bne.b   skip
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.w  #4,ccr
        bra.w   target

        org     $200
target:
        bne.b   skip
        nop
skip:
after:
        stop    #$2700
        dc.w    $2700

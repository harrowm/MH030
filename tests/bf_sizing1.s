; tests/bf_sizing1.s -- bitfield-mem real minimal-footprint sizing fix
; (project_bf_mem_longword_sizing_bug.md, plan.md Phase 276): span==1
; case, BFCLR (A0){0:8} -- clears the top byte only. Real 68030 (and
; Musashi's own reference) issue a single BYTE read then a single BYTE
; write at $100, not a full longword access. ($100, not a larger address
; like $3010: tools/m68ksim's own 4KB reference window means an address
; outside it silently aliases onto code space -- matches this project's
; own established memind test convention.)

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #$DEADBEEF,d0
        move.l  d0,(a0)
        bfclr   (a0){0:8}
        stop    #$2700
        dc.w    $2700

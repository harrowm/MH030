; tests/bf_sizing2.s -- bitfield-mem real minimal-footprint sizing fix
; (project_bf_mem_longword_sizing_bug.md, plan.md Phase 276): span==3
; case (word + byte, the 2-sub-access shape this fix adds), BFCLR
; (A0){0:20} -- clears the top 20 bits. Real 68030 (and Musashi's own
; reference) issue a WORD read then a BYTE read at $102, then a WORD
; write then a BYTE write, not a single 4-byte longword access. ($100,
; not a larger address like $3010: tools/m68ksim's own 4KB reference
; window means an address outside it silently aliases onto code space --
; matches this project's own established memind test convention; found
; the hard way here, via a genuine corrupted-execution failure, not
; guessed at up front.)

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

start:
        movea.l #$100,a0
        move.l  #$FFFFFFFF,d0
        move.l  d0,(a0)
        bfclr   (a0){0:20}
        stop    #$2700
        dc.w    $2700

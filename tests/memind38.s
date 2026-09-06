; tests/memind38.s — TAS.B's own genuine memory-indirect EA (Stage 9c, plan.md
; §Phase 245): the RMW-LOCKED bus protocol's own dispatch trigger (mem_rmw)
; now waits for the shared memind FSM's own inner pointer read to resolve
; the final RMW target address, instead of firing directly off ex_is_mem_rd
; (which is deliberately suppressed for memind dispatch). Verified via the
; full (not reads-only) bus trace: the actual read+write pair at the
; resolved address (not just the pointer read leading up to it) proves both
; address resolution AND that the write phase reused the SAME resolved
; address (mem_addr's own new tas_memind_addr_r mux entry), not the stale
; inner-pointer address.
;
;   Pre-indexed, word bd, null od: ([$100,A0,D1.L])
;
; A0=$2000, D1=$8 -> inner=$2108, pointer at M32[$2108]=$3000 -> TAS target
; = $3000. Original byte = $05 (bit7 clear) -> TAS reads $05, writes $85
; (bit7 set, original value ORed with $80).

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.b  #$05,($3000)    ; TAS target byte, bit7 clear

        tas.b   ([$100,a0,d1.l])   ; pre-indexed, word bd, null od

        move.w  #$600D,d5
        move.w  d5,($3100)      ; marker: execution continued cleanly

        stop    #$2700
        dc.w    $2700

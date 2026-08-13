; tests/memind7.s — Stage 2 (plan.md Phase 116/117): full-format mode=110 EA
; with a non-null word base displacement for ALU-mem-src, both directions
; (memory source and memory-dest RMW). Confirms the generalized
; is_memind_full/mode110_ea_src mechanism (Stage 1's template) covers this
; family correctly.
;
;   ADD.L ($100,A0,D1.L),D2   -- memory source:  EA = A0+$100+D1
;   OR.L  D3,($100,A1,D1.L)   -- memory dest (RMW): EA = A1+$100+D1
;
; A0=$200, A1=$300, D1=$4. ADD target = $304. OR target = $404.
; (Dynamic BTST is covered separately in tests/memind8.s -- BSET's own byte
; RMW hits a different, pre-existing testbench limitation unrelated to this
; family, so keeping it out of this cleanly-automatable test.)

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$200,a0
        movea.l #$300,a1
        move.l  #$4,d1

        move.l  #$00000005,d4
        move.l  d4,($304)      ; ADD target
        move.l  #$0000000F,d4
        move.l  d4,($404)      ; OR target

        move.l  #$00000003,d2  ; ADD addend
        add.l   ($100,a0,d1.l),d2      ; D2 = 3 + M32[$304](5) = 8

        move.l  #$000000F0,d3
        or.l    d3,($100,a1,d1.l)      ; M32[$404] = $F0 | $0F = $FF

        stop    #$2700
        dc.w    $2700

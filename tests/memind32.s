; tests/memind32.s — general ALU-with-EA-source genuine memory-indirect EA
; (plan.md, Phase 238's own deferred proposal, now implemented): ADD.L's own
; ([bd,An,Xn],od) PRE-indexed genuine indirect EA -- the first of the 8
; general ALU-EA families (ADD/SUB/AND/OR/CMP/MULU/MULS/DIVU/DIVS/ADDA/CMPA)
; to get this support. Unlike LEA/PEA/JMP/JSR (address-only or outer-write),
; ADD genuinely reads the resolved value AND combines it with Dn via the
; ALU -- this is the first test exercising dyn_bit_get_Dn's own new
; memind-outer-completion term.
;
;   Pre-indexed, word bd, null od:
;     ([$100,A0,D1.L]) -> inner = A0+$100+D1, EA = M32[inner] + 0
;
; A0=$2000, D1=$8 -> inner = $2108, pointer at M32[$2108]=$3000 -> EA=$3000.
; M32[$3000]=5 (pre-loaded), D2=3 (accumulator) -> ADD.L result = D2=8.
; Stored to $3100 so buscmp.py's own full comparison directly proves the
; combined ALU result, not just the reads leading up to it.

        org     0
        dc.l    $00010000
        dc.l    start

start:
        movea.l #$2000,a0
        move.l  #$8,d1

        move.l  #$3000,d4
        move.l  d4,($2108)      ; M32[a0+$100+d1] = $3000 (pointer)

        move.l  #5,d4
        move.l  d4,($3000)      ; M32[pointer] = 5 (the value ADD reads)

        move.l  #3,d2           ; accumulator, pre-loaded

        add.l   ([$100,a0,d1.l]),d2   ; pre-indexed, word bd, null od

        move.l  d2,($3100)      ; store the combined result for comparison

        stop    #$2700
        dc.w    $2700

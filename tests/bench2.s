; tests/bench2.s -- tests/bench1.s with the 68030's OWN caches ENABLED.
;
; WHY THIS EXISTS. Only two programs in this repo (timing_manual_738/739) ever
; write CACR, so every other measurement -- including bench1 and therefore the
; whole rtl/-vs-rtlp/ tick comparison -- has been running rtl/ with BOTH caches
; DISABLED, since the 68030 comes out of reset that way. That makes the
; comparison unfair to rtl/ and means this project has never measured what its
; own caches are worth.
;
; CACR = $1111: bit 0 EI (instruction cache), bit 4 IBE (instruction burst),
; bit 8 ED (data cache), bit 12 DBE (data burst). This is the fastest measured
; configuration: 24,689 ticks with the caches off, 8,929 with this.
;
; bit 13 WA (write allocate) is deliberately NOT set. It measures SLOWER here
; (10,273), because this program's SRC and DST alias exactly -- the D-cache index
; is addr[7:4], so 0x1000 and 0x1400 map to identical lines -- and allocating on
; write then evicts the very line the next read needs.
;
; THIS PROGRAM IS ALSO THE REGRESSION FOR A REAL BUG IT FOUND. With IBE and DBE
; both set, m68030_biu.sv gave BOTH caches the same unqualified eu_burst_ack, so
; a burst completing for one was consumed by the other as its own line fill, and
; this program's D0 check failed. Either burst alone was fine, which is why it
; survived: the stray ack reached a module in an idle state whose own
; `state == ..._BURST0 && ack` guard then failed. Now grant-qualified, matching
; how the request side was already gated.
;
; Getting this far also needed burst_beat_probe added to tb/cosim_grp_tb.sv --
; one of the dormant gaps CLAUDE.md records as "structurally inapplicable
; because none of those testbenches ever enable CACR", which stopped being true
; the moment this file did.
;
; Otherwise identical to bench1.s, so the two are directly comparable.

        org     0
        dc.l    $00010000       ; reset SSP
        dc.l    start           ; reset PC

SRC     equ     $1000
DST     equ     $1400
N       equ     64

start:
        ; ── enable both caches ─────────────────────────────────────────────
        move.l  #$00001111,d0
        movec   d0,cacr

        ; ── fill the source block: N longwords, value = index ──────────────
        lea     SRC,a0
        moveq   #0,d1                   ; index
fill:
        move.l  d1,(a0)+
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     fill

        ; ── phase 1: memory copy, bus-bound (read + write per iteration) ───
        lea     SRC,a1
        lea     DST,a2
        moveq   #0,d1
copy:
        move.l  (a1)+,(a2)+
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     copy

        ; ── phase 2: register ALU, execute-bound, no bus traffic ───────────
        moveq   #0,d7
        moveq   #0,d1
alu:
        add.l   d1,d7
        eor.l   #$5A,d7
        lsl.l   #1,d7
        lsr.l   #1,d7
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     alu

        ; ── phase 3: indexed read, address-generation bound ────────────────
        lea     DST,a3
        moveq   #0,d0                   ; running sum
        moveq   #0,d1                   ; index
sum:
        move.l  d1,d2
        lsl.l   #2,d2                   ; index*4
        move.l  (0,a3,d2.l),d3
        add.l   d3,d0
        addq.l  #1,d1
        cmpi.l  #N,d1
        bne     sum

        stop    #$2700

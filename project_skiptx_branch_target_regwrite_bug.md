# Bug: destination-register decode corrupted for the first instruction fetched at a taken-branch target

**Status: OPEN, not yet root-caused inside this repo's own RTL — found from
the outside (mackerel-030f integration testing), needs a dedicated MH030
debugging session.**

## Summary

The first instruction fetched and executed immediately after a taken
conditional branch can have its own destination-register decode silently
corrupted — the register file receives a write to the **wrong register**,
carrying **wrong data**, while the instruction's own real destination
register is never written at all. Confirmed via direct `eu_regfile.sv`
write-port tracing (`wr_en`/`wr_sel`/`wr_data`), not inferred from bus
addresses or program behavior alone.

## How this was found

Building/simulating Mackerel-030F (`../mackerel-030f`, a separate ULX3S
FPGA SoC project using this repo's `rtl/` as a git dependency) surfaced a
real hang in a hand-assembled 68000 boot program (`pld/mackerel-030f/
boot.s`) that made no sense at the source level. Chasing it down (full
writeup of the whole session in mackerel-030f's own `plan.md`) eventually
ruled out every layer of that project's own code and landed here, on this
repo's own EU/sequencer.

## Repro (self-contained, no mackerel-030f needed to reproduce)

The failing instruction sequence, in context (addresses as fetched from a
32-bit-wide on-chip ROM at `clk_4x` = 100 MHz, real 68030 timing):

```
        ...
        MOVE.B  (5,A1),D2        ; D2 = LSR            (0x52)
        BTST    #5,D2            ; test THRE            (0x56)
        BEQ.S   SKIP_TX          ; disp=+6, -> 0x62     (0x5A)
        MOVE.B  #$55,(0,A1)      ; THR = 'U' (skipped)  (0x5C)
SKIP_TX:
        MOVE.L  #$00000004,D1    ; opcode 223C 0000 0004 (0x62)  <-- branch target
DELAY:
        SUBQ.L  #1,D1            ; opcode 5381           (0x68)
        BNE.S   DELAY            ; opcode 66FC            (0x6A)
        BRA.S   LOOP             ; opcode 60E0             (0x6C)
```

`BEQ.S` is taken (THRE was not yet ready), redirecting the IFU to fetch
from `0x62` — the `MOVE.L #$00000004,D1` instruction, i.e. **the very
first instruction at the branch target**.

Confirmed via direct `wr_sel`/`wr_data` tracing on `eu_regfile.sv`'s
write port (see Evidence below) that this specific `MOVE.L` **never
writes D1 at all**. Instead:

- The register file receives a spurious write of `D4 = 0x000000DB`
  (D1's own intended immediate value, `0x00000004`, appears nowhere in
  the trace).
- D4 already held `0x5A5A5A5A` from an *earlier*, unrelated instruction
  several bus cycles before (`MOVE.L (A2),D4`, the SDRAM read-back
  test's own destination register) — nothing in the program touches D4
  again at this point.
- D1 is left at its stale prior value (`0x00000000` here, straight off
  reset) instead of being loaded with `0x00000004`.

The next instruction, `SUBQ.L #1,D1`, then correctly decrements D1 from
its (wrongly-stale) `0x00000000`, producing `0xFFFFFFFF` (a real,
correct underflow given the wrong starting value) — so the loop, instead
of running 4 times, needs ~4 billion iterations to reach zero. Confirmed
this reproduces **identically regardless of the actual immediate value**
used for the delay count (tested with `0x00000004`, `0x00000100`, and
the original `0x00030000` — all three show the exact same D4/D1
corruption pattern; only the eventual wrap-around time differs, which is
why this looked at first like "the delay loop just takes a long time"
rather than a real bug).

## Evidence (from the mackerel-030f full-chip simulation)

Register-file write-port trace (`eu_regfile.sv`: `wr_en`, `wr_sel`,
`wr_data`), consecutive writes, no gaps:

```
D-WRITE #6:  wr_sel=3  wr_data=5a5a5a5a   ; D3 = test pattern (MOVE.L #$5A5A5A5A,D3)
D-WRITE #7:  wr_sel=4  wr_data=5a5a5a5a   ; D4 = SDRAM read-back (MOVE.L (A2),D4)
D-WRITE #8:  wr_sel=0  wr_data=00000001   ; D0 = 1 (ADDQ.L #1,D0, in LOOP)
D-WRITE #9:  wr_sel=2  wr_data=00000000   ; D2 = LSR value (MOVE.B (5,A1),D2)
D-WRITE #10: wr_sel=4  wr_data=000000db   ; *** SPURIOUS: D4 written again, garbage value,
                                          ;     no source instruction for this at all ***
D-WRITE #11: wr_sel=1  wr_data=ffffffff   ; SUBQ.L's own result: 0x00000000 - 1
D-WRITE #12: wr_sel=1  wr_data=fffffffe   ; ... decrementing correctly from here on ...
D-WRITE #13: wr_sel=1  wr_data=fffffffd
...
```

PC-redirect trace (`m68030_top.sv`'s `pc_wr_en_common`/`pc_wr_data_common`,
`eu_branch_taken`/`eu_branch_target`, `ifu_decode_pc`/`eu_ex_decode_pc`)
across the same window:

```
PC-WRITE #3: eu_branch_taken=1 pc_wr_data=00000062   ; BEQ.S SKIP_TX taken, decode_pc=0x5a (the BEQ itself)
PC-WRITE #4: eu_branch_taken=1 pc_wr_data=00000068   ; BNE.S DELAY taken, decode_pc=0x6a, ex_decode_pc=0x66
PC-WRITE #5: eu_branch_taken=1 pc_wr_data=00000068   ; BNE.S taken again, decode_pc=0x6a, ex_decode_pc=0x68 (now frozen)
PC-WRITE #6..N: identical to #5, forever              ; ex_decode_pc never advances past 0x68 again
```

Bus-level trace around the same moment (`ext_a`/`ext_rw`/`dsack0_n`/
`dsack1_n`/`berr_n`, sampled every `posedge cyc_active`) additionally
shows one genuinely unexplained bus access — a cleanly-acknowledged
(no BERR, proper DSACK) READ then WRITE to address `0x00000000`,
sandwiched between the `0x64` fetch (the `MOVE.L`'s own second immediate
word) and the first `0x68` fetch — not yet connected with certainty to
the register-write corruption above, but landing in the same few-cycle
window and worth checking together. (`berr_n` was directly confirmed to
never assert anywhere in this whole sequence — this is not a bus-error
or exception dispatch of any kind, unlike an earlier, separate,
already-fixed issue in mackerel-030f's own SDRAM adapter that *did*
produce a real internal Bus Error via `biu_error_handler.sv`'s
`TIMEOUT_CLKS=128` watchdog. That issue is fully closed; this is a
different, later-occurring bug in the same session's investigation.)

## What's confirmed vs. not yet confirmed

**Confirmed:**
- Real, reproducible, deterministic (not a testbench artifact — same
  result across three different immediate values, two independent debug
  builds, direct register-file signal tracing).
- Specific to the instruction immediately following a taken branch's own
  redirect (the branch itself, `BEQ.S`, executes and redirects
  correctly; it's the *next* instruction's own destination-register
  decode that's wrong).
- Not a `boot.s`/ROM-encoding bug — the opcode bytes at `0x62-0x67`
  (`223C 0000 0004`) were independently re-derived and confirmed correct
  for `MOVE.L #imm,D1`, and were confirmed to be fetched cleanly (proper
  DSACK, no BERR) in the same trace.
- Not related to the separate, already-fixed SDRAM timeout bug (that one
  produced a real internal Bus Error via `berr_n`; this one produces no
  BERR of any kind).

**Not yet confirmed (next investigation steps for a dedicated session):**
- *Why* the decode reuses D4's own destination-register field/write
  strobe instead of D1's. The `MOVE.L (A2),D4` (dest=D4) and `MOVE.L
  #imm,D1` (dest=D1) instructions are several bus cycles apart in
  program order but this could still be a stale-latch/hazard-signal
  reuse bug of the same general shape as `feedback_stale_broadcast_
  signal.md`'s "CI"/"WP" cases or `feedback_shared_decode_prefix.md`'s
  register-capture-prefix cases (both already-known bug *classes* in
  this codebase) — worth checking `eu_seq_decode.svh`'s own MOVE-
  immediate-to-Dn decode path for anything gated on `!ex_redirect_
  pending` or similar (Track 1's own Phase 254-255 fix, described in
  CLAUDE.md, fixed two conceptually similar "stale `dec_*` fields right
  after a redirect" bugs for RTS/RTR/RTE and CMPM — this may be a third,
  undiscovered instance of that same bug shape, for a *plain taken
  branch* redirect rather than a multi-phase-stall redirect).
- Whether the mystery `0x00000000` bus read+write is a symptom of the
  same root cause or a separate, coincidental finding.
- Whether this affects only `MOVE.L #imm,Dn` at a branch target, or any
  instruction whose decode captures a destination register in the same
  pipeline stage.

## Suggested first step for the real debugging session

Reproduce with a much smaller, standalone testbench (no mackerel-030f
SoC needed — just `m68030_top` + a tiny ROM model) running exactly:
`BEQ.S <label>` (forced taken) immediately followed by `MOVE.L
#$00000004,D1` at `<label>`, then inspect `eu_seq_decode.svh`'s own
`dec_dst_reg`/equivalent register-capture signal cycle-by-cycle across
the redirect, the same way Track 1's Phase 254-255 RTS/RTR/RTE fix was
diagnosed (per CLAUDE.md's own description of that fix).

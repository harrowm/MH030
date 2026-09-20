# Bug: decode mis-reads a still-in-flight instruction's own extension word as a fresh opcode, corrupting the eventual register commit

**Status: OPEN — root cause now precisely identified and reproduced via
direct cycle-by-cycle pipeline tracing (see Evidence below), but not yet
fixed. Needs a dedicated MH030 session with the full Harte regression gate
before landing any change, since this touches the core DEC→EX handoff
used by every instruction.**

## Summary (revised — supersedes the original theory below)

This bug has **nothing to do with branches** as a mechanism — that was
this file's original (wrong) hypothesis, based on the fact that the
failure was only ever observed at a branch target. The real trigger is
narrower and more general: **any multi-extension-word instruction whose
extension words are not yet sitting in the prefetch queue (i.e. must be
freshly fetched from the bus, taking multiple cycles) is vulnerable.** A
branch redirect is simply the easiest way to force that condition (it
flushes the queue, guaranteeing the extension words for the next
instruction aren't pre-buffered) — but the underlying gap is in the
IFU/decode handoff, not in branch handling.

**Mechanism, confirmed via signal tracing:**

1. `m68030_ifu.sv` exposes `instr_word = q[0]` / `instr_valid = (q_cnt >=
   1)` combinationally — whatever sits at the head of the 7-entry
   prefetch queue *right now*. `eu_seq_decode.svh`'s `dec_*` outputs are
   pure combinational functions of this live `instr_word` (confirmed:
   Phase 226 split, CLAUDE.md).
2. For a 3-word instruction like `MOVE.L #$00000004,D1` (opcode `223C`,
   then two 16-bit immediate words `0000`/`0004`), the EU-side sequencer
   correctly decodes the opcode word, sets `dec_dest_reg=1`, and asserts
   a `need_ext`-shaped stall term (part of `stall_base` in
   `eu_seq_execute.svh`) while it waits for the 32-bit immediate
   (`ext_data`/`ext_valid`) to actually arrive.
3. **While that wait is in progress, the IFU's own queue keeps
   advancing** — `q[0]` moves past the opcode word and its first
   extension word, exposing the instruction's own **second** extension
   word (`0x0004` in this repro) as `instr_word`.
4. Because decode is purely combinational off `instr_word`, it now
   **re-decodes `0x0004` as if it were a brand-new opcode** — `0x0004`
   happens to fall in the ALU-immediate-to-Dn opcode family, decoding as
   some ALU-immediate op with **destination register field = 4** (bits
   `[2:0]` of `0x0004`). This sets `dec_valid=1`, `dec_dest_reg=4`,
   `dec_writes_reg=1` — a completely spurious "instruction" that exists
   only because a data word happened to look like an opcode.
5. This spurious decode has its *own*, coincidentally similar,
   `need_ext`-shaped stall (an immediate ALU op also wants an extension
   word), so `stall` stays asserted for a few more cycles — for the
   *wrong* reason, decoupled from the real `MOVE.L`'s own actual
   completion state.
6. When that (spurious) wait resolves, `instr_ack = dec_valid && !stall`
   fires — and the DEC→EX latch (`eu_seq_execute.svh`, `ex_dest_reg <=
   dec_dest_reg`, `ex_writes_reg <= dec_writes_reg`, unconditional on the
   "normal advance" path) commits **whatever `dec_dest_reg`/`dec_writes_
   reg` currently say** — which by now reflects the spurious `0x0004`
   decode (dest=4), not the real `MOVE.L #imm,D1`'s own dest=1. One cycle
   later this reaches `eu_regfile.sv`'s write port as a real, committed
   write to the wrong register.
7. The real `MOVE.L`'s own destination register (D1) is *never* written
   — nothing ever re-asserts its own dest=1 once the queue has moved on.

In short: **the EX-latch trusts the live, combinational `dec_dest_reg`/
`dec_writes_reg` at the moment a wait resolves, instead of holding the
value that was correctly decoded when the *original* instruction's
opcode word was first seen.** As long as an instruction's extension
words are already sitting in the queue (the common case — ordinary
sequential execution keeps the queue full via prefetch), this race
window doesn't exist and everything works. It only becomes visible when
the extension words must be freshly fetched from the bus, which takes
long enough for the queue head to visibly move past them — which is
exactly what a branch redirect (queue flush) forces, but is not
inherently branch-specific.

## Repro

Self-contained, no mackerel-030f needed — any sequence that forces a
32-bit-immediate `MOVE.L #imm,Dn` to need a genuine multi-cycle
extension-word fetch will do. The one this was found with (real
addresses, real 68030 timing, `clk_4x` = 100 MHz):

```
        MOVE.B  (5,A1),D2        ; D2 = LSR            (0x52)
        BTST    #5,D2            ; test THRE            (0x56)
        BEQ.S   SKIP_TX          ; disp=+6, -> 0x62     (0x5A)
        MOVE.B  #$55,(0,A1)      ; THR = 'U' (skipped)  (0x5C)
SKIP_TX:
        MOVE.L  #$00000004,D1    ; opcode 223C 0000 0004 (0x62)  <-- forces a fresh, uncached fetch
DELAY:
        SUBQ.L  #1,D1            ; opcode 5381           (0x68)
        BNE.S   DELAY            ; opcode 66FC            (0x6A)
```

`BEQ.S` taken flushes the queue, so `MOVE.L #$00000004,D1`'s own two
extension words are not pre-buffered and must be freshly fetched —
triggering the race. `SUBQ.L #1,D1` then decrements D1 from its
never-updated stale value (`0x00000000` here, straight off reset),
underflowing to `0xFFFFFFFF` — so a "4-iteration" delay loop instead
needs ~4 billion iterations. Reproduces identically for delay-loop
immediates `0x00000004`, `0x00000100`, and `0x00030000` (only the
eventual wrap-around time differs).

## Evidence

Per-cycle pipeline trace (`eu_seq.sv`'s `dec_*`/`ex_*`/`wb_*`, plus
`m68030_top.sv`'s `seq_eu_instr_word`/`seq_eu_instr_valid`), one line per
`clk_4x` edge, showing the exact moment of corruption:

```
#66195..66207: instr_word=0004 (!) dec_valid=1 dec_dest_reg=4 dec_writes_reg=1 dec_unit=0(ALU)
               stall=1 the whole time -- decode is looking at the MOVE.L's
               OWN second extension word (0x0004) and mis-decoding it as a
               fresh ALU-immediate-to-D4 opcode.
#66208:        stall=0, ext_valid=1, instr_ack=1 -- the spurious "instruction"'s
               own (coincidental, unrelated) extension-word wait resolves.
#66209:        ex_valid=1 ex_dest_reg=4 ex_writes_reg=1  -- DEC->EX latch commits
               the WRONG (spurious) decode. instr_word has ALREADY moved on
               to 66fc (BNE.S, the real next real instruction) by this point.
#66210:        wb_valid=1 wb_writes_reg=1 wb_dest_reg=4  -- reaches eu_regfile.sv's
               write port: D4 = 0x000000DB (garbage, an artifact of whatever
               ext_data happened to be live for the spurious ALU op).
```

Register-file write-port trace (`eu_regfile.sv`: `wr_en`/`wr_sel`/
`wr_data`) across the same window, consecutive writes, no gaps:

```
D-WRITE #7:  wr_sel=4  wr_data=5a5a5a5a   ; D4 = SDRAM read-back (MOVE.L (A2),D4) -- real, correct
D-WRITE #8:  wr_sel=0  wr_data=00000001   ; D0 = 1 (ADDQ.L #1,D0, in LOOP) -- real, correct
D-WRITE #9:  wr_sel=2  wr_data=00000000   ; D2 = LSR value (MOVE.B (5,A1),D2) -- real, correct
D-WRITE #10: wr_sel=4  wr_data=000000db   ; *** THE BUG: spurious D4 write, matches #66210 above ***
D-WRITE #11: wr_sel=1  wr_data=ffffffff   ; SUBQ.L's own result: 0x00000000 - 1 (D1 never got its real value)
D-WRITE #12: wr_sel=1  wr_data=fffffffe   ; ... decrementing "correctly" from the wrong start ...
```

Confirmed via the same trace, all on the standard (non-special-FSM)
`wb_dest_reg`/`wb_result_final` writeback path (`eu_seq_execute.svh`'s
`wr_sel`/`wr_data` mux) — none of `movem_wr_en`/`movep_wr_en`/
`memind_wr_en`/`memind_addr_wr_en`/`bf_dn_wr_en`/`cpdbcc_wr_en`/
`cpscc_wr_en` are active at the corruption cycle, ruling out every
special multi-cycle FSM as the source.

Also confirmed: `berr_n` never asserts anywhere in this sequence — not a
BERR/exception-dispatch issue of any kind (that's a separate,
already-fixed mackerel-030f bug — see CLAUDE.md's `biu_error_handler.sv`
`TIMEOUT_CLKS=128` history — unrelated to this one).

## What's confirmed vs. still open

**Confirmed:**
- Exact mechanism: `instr_word`'s own combinational decode is read at
  the wrong time relative to a still-in-flight multi-extension-word
  instruction's own completion, letting a data word (the instruction's
  own second extension word) get misread as a fresh opcode.
- The DEC→EX latch (`ex_dest_reg <= dec_dest_reg`, `ex_writes_reg <=
  dec_writes_reg` in `eu_seq_execute.svh`'s "normal advance" branch) has
  no protection against `dec_*` having moved on to unrelated content by
  the time `instr_ack`/the latch-advance actually fires.
- Reproduces deterministically, independent of the specific immediate
  value, independent of which register is the real destination (traced
  with D1; D4's own earlier, ordinarily-prefetched `MOVE.L (A2),D4`
  executed correctly, consistent with the "already in queue, no wait"
  explanation for why this doesn't corrupt every multi-word MOVE).
- Branches are not the root cause — they're just the easiest way to
  force "extension words not yet in the queue." The original theory in
  this file (a branch-redirect-specific stale-latch bug, analogous to
  Track 1's RTS/RTR/RTE/CMPM `ex_redirect_pending` fixes) is **not**
  what's happening here; no `pc_wr_en`/`branch_taken` signal is involved
  in the actual corruption window (#66195-66210 above has no branch
  activity at all — the BEQ.S redirect already completed earlier).

**Still open (for the real fix session):**
- The precise, minimal fix. Candidates to evaluate:
  - Latch `dec_dest_reg`/`dec_writes_reg` (and any other DEC-stage
    fields needed for correct writeback) into a dedicated register **at
    the moment the ORIGINAL opcode word is first decoded**, and hold
    that latch — rather than the live `dec_*` combinational output —
    for use by the eventual DEC→EX advance when the extension-word wait
    resolves. This is the most direct fix but touches every
    multi-extension-word instruction's own decode path, so needs full
    Harte re-validation.
  - Alternatively: make the IFU withhold advancing `q[0]` past an
    instruction's own extension words until the *whole* instruction
    (opcode + all its own extension words) has been consumed by the
    sequencer, rather than exposing them individually as soon as
    they're fetched. Also invasive — same testing burden.
  - Whichever fix, confirm it also protects the *symmetric* case: an
    instruction needing 3 or more extension words (e.g. full-format
    memory-indirect EA), not just the 2-word case reproduced here.
- Not yet checked: whether this same race can also corrupt `dec_src_reg`/
  `dec_c_reg` or CCR-update flags for other multi-extension-word
  instruction families (bitfield ops, CAS2, full-format EA) — the
  `MOVE.L #imm,Dn` case was the first and only one traced so far.
- This repo's own Harte-based validation (`make sim/harte_vbatch`) may
  not currently catch this class at all: Harte tests one instruction in
  isolation per vector, and the trigger here specifically requires an
  extension-word fetch that's *not yet buffered*, i.e. a genuinely fresh
  queue state — worth checking whether any existing Harte harness
  construction accidentally always pre-warms the queue before the
  instruction under test, which would explain why 124/124 suites passing
  never caught this.

## Suggested first step for the real fix session

Build a minimal standalone testbench (`m68030_top` + a small ROM model,
no mackerel-030f SoC needed) that:
1. Flushes the prefetch queue (any taken branch, or just a cold reset
   with the target instruction placed so its extension words require a
   fresh multi-cycle fetch — a branch is simplest).
2. Redirects directly into a `MOVE.L #imm,Dn` (or any 3-word
   instruction) whose extension words are *not* already prefetched.
3. Traces `instr_word`/`dec_valid`/`dec_dest_reg`/`dec_writes_reg`/
   `stall`/`instr_ack`/`ex_valid`/`ex_dest_reg` cycle-by-cycle across the
   whole extension-word wait, the same way this investigation did (see
   Evidence above for the exact per-cycle shape to expect) — confirm
   `instr_word` visibly changes to the instruction's own extension-word
   content mid-wait, and that a spurious `dec_valid=1` with a
   coincidentally different `dec_dest_reg` appears before the real
   completion.
4. Prototype fix option 1 above (latch the original decode at opcode-
   fetch time) and re-run the same trace to confirm `ex_dest_reg`/
   `ex_writes_reg` now correctly reflect the *original* instruction
   throughout the wait, then run the full mandatory gate (`make test`)
   plus a full Harte sweep (`make sim/harte_vbatch`) before considering
   it done.

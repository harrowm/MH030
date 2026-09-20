# Bug: a redirect doesn't discard an already-in-flight speculative fetch for the abandoned fall-through path, corrupting the next instruction's own decode

**Status: OPEN — root cause now confirmed precisely via direct `q_cnt`/
`drain` signal tracing (not inferred), including watching the exact
moment stale data gets misdecoded and its wrong drain count eats the
real opcode. Not yet fixed. A minimal, controlled MH030-only regression
test has NOT yet been achieved (see "Reproduction status" below) despite
several attempts matching every structural element identified so far —
this needs more work before a fix can be safely validated.**

## Summary (second revision — supersedes both earlier theories in this file's own history)

This file has now gone through two wrong-but-plausible theories before
landing on the confirmed mechanism:

1. **First theory (wrong):** branch-redirect-specific stale-latch bug,
   analogous to Track 1's `ex_redirect_pending` fixes.
2. **Second theory (wrong in the specifics, right in spirit):** decode
   reads a live, already-advanced `instr_word` and misinterprets a data
   word as a fresh opcode. This was directionally correct (the actual
   *symptom* — a data word decoded as an opcode — is real) but the
   proposed cause (`drain` firing prematurely, before `instr_ack`) was
   directly disproven: `drain = eu_instr_ack ? (1+ext_count) : 0`
   (`m68030_seq.sv`) is correctly gated and never advances the queue
   speculatively.

**Confirmed mechanism (this revision):** the real 68030 IFU speculatively
prefetches down the fall-through path of a conditional branch before the
branch's own condition is known (this is normal, expected, necessary
pipelining — real hardware does this too). When the branch is taken, the
redirect logic (`m68030_ifu.sv`'s `pc_wr_en` branch) correctly flushes
the *queue* (`q[]<=0`, `q_cnt<=0`) and clears `fetch_pend_r`. **What it
does not do — and, for an already-dispatched bus cycle, arguably cannot
do without adding new logic — is discard the *result* of a bus read that
was already in flight for the abandoned fall-through address before the
flush.** That read completes normally (DSACK arrives, data is valid) and
gets pushed into the now-flushed queue anyway, because nothing tags it
as belonging to a stale fetch epoch. From the sequencer's point of view
this stale data is indistinguishable from a genuine fetch of the real
redirect target — it gets decoded as if it were the first instruction at
the new PC.

Confirmed directly, via `dut.u_cpu.u_ifu.q_cnt` / `dut.u_cpu.seq_drain`
tracing across a real branch-taken event in the original mackerel-030f
repro (see the exact trace under Evidence): the queue genuinely goes to
`q_cnt=0` immediately after the redirect (a correct flush), then
`q_cnt=1` a few cycles later holding `0x0055` — a literal byte of the
`MOVE.B #$55,(0,A1)` instruction that lives on the *abandoned*
fall-through path (address `0x5C`), not anything from the real redirect
target (`0x62`). This stale word, decoded as a fresh opcode, computes
its own (wrong, coincidental) extension-word requirement and eventually
dispatches with `drain=2` — **consuming two words from the queue that
include the real opcode (`0x223C`) and/or its own real extension word,
silently discarding them.** Everything decoded after that point is
reading data that was really meant to be extension words for the *real*
`MOVE.L #imm,D1`, now misaligned by the stolen slots and misdecoded as
yet another fresh "instruction" — which is the `0x0004`-decoded-as-
opcode symptom this file originally reported.

In short: **a branch redirect can silently corrupt the next real
instruction's own decode if a speculative fetch for the abandoned
fall-through path is still in flight at the moment of redirect.** This
has nothing to do with the destination register mechanism per se (that
was just the visible symptom) — it's a genuine "stale speculative fetch
result surviving a flush" bug in the IFU/redirect interaction.

## Evidence

Direct `q_cnt`/`drain`/`dec_*`/`ext_valid`/`instr_ack` trace, armed the
moment `pc_wr_en_common && pc_wr_data_common==0x62` fires (the real
`BEQ.S SKIP_TX` redirect in the original mackerel-030f repro program),
one line per `clk_4x` cycle, no gaps:

```
#1  : instr_word=6706 q_cnt=1 drain=1 dec_valid=1 need_ext=0 instr_ack=1
      -- BEQ.S itself dispatching (its own opcode IS its own displacement,
      -- no extension word needed) -- this is the redirect firing.
#2-5: instr_word=0000 q_cnt=0 -- queue correctly empty right after the
      -- flush (q[]<=0/q_cnt<=0 on the pc_wr_en edge, confirmed correct).
#6  : instr_word=0055(!) q_cnt=1 dec_valid=1 need_ext=1
      -- 0x0055 is a real byte of "MOVE.B #$55,(0,A1)" at address 0x5C --
      -- the ABANDONED fall-through instruction, not anything at the
      -- real redirect target 0x62. This is the stale, already-in-flight
      -- speculative fetch's own result, delivered AFTER the flush and
      -- pushed into the (supposedly just-flushed) queue anyway.
#6-21: (16 cycles) instr_word stays 0055, dec_valid=1, need_ext=1 --
      -- decode is genuinely treating this stale data as a real pending
      -- instruction, waiting on ITS OWN (bogus) extension-word need.
#22 : instr_word=0055 q_cnt=3 drain=2(!) ext_valid=1 instr_ack=1
      -- the spurious "instruction" dispatches, draining 2 words --
      -- CONSUMING the real opcode (0x223C) and/or its own real first
      -- extension word that had arrived in the meantime, discarding them.
#23-61: (39 cycles!) instr_word=0004 dec_dest_reg=4 dec_writes_reg=1
      -- 0x0004 is genuinely real data (this run's own D1 delay-loop
      -- immediate, correctly fetched from its real address 0x66) --
      -- but by now the queue has lost track of where the real opcode
      -- was, so this real data word gets misdecoded as a fresh opcode
      -- in its own right (the original "0x0004-as-opcode" finding).
#62 : q_cnt=3 drain=2 ext_valid=1 instr_ack=1 -- this SECOND spurious
      -- instruction dispatches too.
#63 : instr_word=66fc(!) ex_dest_reg=4 ex_writes_reg=1 -- already onto
      -- BNE.S's own opcode; #64 commits wb_dest_reg=4 -- the corrupted
      -- register-file write this file originally reported.
```

The real `MOVE.L #imm,D1` opcode (`0x223C`) and both its real extension
words never appear as a correctly-decoded, correctly-committed
instruction anywhere in this trace — they were silently consumed as
"extension data" by the two spurious, stale-data-derived dispatches
above.

Register-file write-port trace (`eu_regfile.sv`), matching the original
finding exactly:

```
D-WRITE #10: wr_sel=4  wr_data=000000db   ; the corrupted commit, now explained precisely
D-WRITE #11: wr_sel=1  wr_data=ffffffff   ; SUBQ.L's own result: D1 was never loaded, underflows
```

## Reproduction status

**Not yet achieved in an isolated, MH030-only unit test**, despite
several attempts, each matching a structural element identified along
the way:

1. Plain redirect immediately followed by `MOVE.L #imm,Dn` — passed
   (no corruption).
2. Same, with the opcode deliberately misaligned to a non-4-byte
   boundary (matching the original's exact byte layout, opcode at
   offset+2 within its own fetched longword) — passed.
3. Same, with extra DSACK wait states (`wait_states=3`) injected — passed.
4. The full original instruction shape — `MOVEA.L`, a real `MOVE.B`
   memory read, `BTST`, a data-dependent `BEQ.S` taken, landing on the
   misaligned `MOVE.L` — passed.
5. Same, with the test's own memory model changed from combinational to
   a registered read (matching `mackerel_030f.v`'s own ROM timing
   exactly) — passed.
6. Same, with an 8-bit-port DSACK response forced for the `MOVE.B` read
   (matching the original's real UART LSR access, an 8-bit port, instead
   of a 32-bit-port ROM access) — passed.

All six attempts were run in `tb/stall_fsm_tb.sv` (this repo's own
pipeline-hazard regression harness) using the same `run_and_check`
convention as every other test there; none are currently committed,
since a test that doesn't reproduce the bug provides false confidence
if left in place.

**Working theory for why the isolated attempts don't reproduce:** the
bug requires the IFU to have *already dispatched* a speculative
fall-through fetch at the exact moment the branch's own condition
resolves — which depends on the prefetch queue's own fill level at that
moment (the IFU only dispatches a new fetch once `q_cnt` drops low
enough; see `m68030_ifu.sv`'s own `q_cnt_d<=3'd5 || (need_ext &&
q_cnt_d<=3'd6)` gate). The original repro's queue-fill trajectory is
shaped by everything that ran before it (an SDRAM test, a GPIO write, an
`ADDQ.L`) — a completely different history than any isolated test's own
few preceding instructions can easily reproduce. Getting an isolated
test into the same queue state at the same moment likely needs either:
deliberately priming the queue to a specific fill level with a crafted
instruction sequence beforehand, or a more surgical approach: force
`q_cnt` into the right window directly via hierarchical testbench
access, bypassing the need to organically reproduce the exact
instruction-timing history.

## Suggested next steps for the real fix session

1. **Reproduce first.** Use the "working theory" above to deliberately
   drain the queue to the right fill level before a branch, or force
   `q_cnt`/`fetch_pend_r` into the vulnerable state directly via
   hierarchical access in a throwaway testbench, to get a fast,
   controlled repro before attempting any fix. Don't skip this — a fix
   for a pipeline hazard this subtle needs a real regression test to
   validate against, not just re-running the original (slow, multi-
   minute) mackerel-030f full-chip simulation each time.
2. **Fix approach**: tag each dispatched fetch with the redirect epoch
   it belongs to (e.g. a small counter incremented on every `pc_wr_en`),
   and discard (don't push into `q[]`) any fetch result that arrives
   tagged with a stale epoch. This is more surgical than either
   candidate this file previously proposed (latching decode state, or
   withholding `instr_word` advancement) — it fixes the actual defect
   (a stale bus-cycle result surviving a flush) rather than working
   around its downstream symptom.
3. Confirm real 68030 silicon's own documented behavior here for
   reference (MC68030UM.pdf's own IFU/prefetch section) — real hardware
   cannot abort an in-flight bus cycle either, so real silicon likely
   has its own explicit mechanism for tagging/discarding stale prefetch
   results across a redirect; worth checking whether the manual
   describes this explicitly before designing the fix from scratch.
4. Whichever fix, re-run the full mandatory gate (`make test`) and a
   full Harte sweep (`make sim/harte_vbatch`) before considering it
   done — and specifically check whether Harte's own harness construction
   ever exercises a taken branch with a live speculative fall-through
   fetch in flight, since 124/124 suites passing to date suggests it may
   not.

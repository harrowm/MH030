# Bug: a redirect doesn't discard an already-in-flight speculative fetch for the abandoned fall-through path, corrupting the next instruction's own decode

**Status: FIXED AND VERIFIED. `m68030_ifu.sv` now holds `fetch_addr_r`/
`fetch_pend_r`/`skip_first_r` completely stable across a redirect
(`pc_wr_en`) whenever a bus fetch is genuinely still outstanding at that
moment, instead of immediately switching them to the new target. The
outstanding cycle is left running to its natural completion (real
silicon can't cancel an S-state bus cycle already in progress either),
and its eventual `ifu_ack`/`ifu_berr` is discarded (`fetch_abort_pend_r`)
rather than filled into the just-flushed queue or misattributed to
whatever the IFU has since re-armed for. `tb/minrepro_tb.sv` now PASSES
and has been moved into `ALL_TESTS` (`make test`: 38/38). Full mandatory
gate clean; full 124-suite Tom Harte sweep bit-identical to baseline
(`PASS 702142 FAIL 2` documented ASL.b anomaly, `SKIP 281221 TIMEOUT 0`).
See "Fix (implemented)" below for the full mechanism and why the fix
lives in `m68030_ifu.sv` rather than `biu_icache_if.sv`'s own
already-existing `same_req`/`abandoned_r` mechanism (Phase 128), which
only covers the cache/MMU-*enabled* path.**

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

## Reproduction (achieved — `tb/minrepro_tb.sv`)

A minimal, standalone, fast (~30ns simulated, sub-second wall-clock)
regression test now exists and reliably fails, confirming the exact same
mechanism as the full mackerel-030f repro (same `q_cnt`/`drain` shape,
same "data word decoded as opcode" symptom). Getting there took six
failed attempts before finding the two real missing ingredients:

**Six failed attempts** (all in `tb/stall_fsm_tb.sv`, reached via a JMP
into a mid-file entry point, matching that file's own established
convention — none committed, since a non-reproducing test would give
false confidence):
1. Plain redirect immediately followed by `MOVE.L #imm,Dn` — passed.
2. Same, with the opcode deliberately misaligned to a non-4-byte
   boundary (matching the original's exact byte layout) — passed.
3. Same, with extra DSACK wait states (`wait_states=3`) injected — passed.
4. The full original instruction shape (`MOVEA.L`, a real `MOVE.B`
   memory read, `BTST`, a data-dependent `BEQ.S` taken) — passed.
5. Same, with the memory model changed to a registered read — passed.
6. Same, with an 8-bit-port DSACK response forced for the `MOVE.B`
   read (matching the original's real UART access) — passed.

**The two real missing ingredients**, found by porting the exact
mackerel-030f repro program into a brand-new standalone testbench
(`tb/minrepro_tb.sv`) instead of continuing to vary `stall_fsm_tb.sv`:

1. **A genuine reset boot, not a JMP into a mid-file entry point.**
   Every one of the six failed attempts above (and every earlier
   `stall_fsm_tb.sv`-based one) reached its test code via a JMP from an
   unrelated prior test's own tail. Reaching the same code via an actual
   `m68030_top` reset sequence instead is necessary — apparently the
   prefetch queue's own fill-level trajectory differs enough between
   "just landed via JMP" and "walked here from a cold reset" for the
   race window to open.
2. **A registered (one-`clk_4x`-cycle-delayed) memory read, with DSACK
   asserted immediately** (the same cycle the address decodes) — i.e.
   the exact same timing relationship as `mackerel_030f.v`'s own real
   ROM (`rom_dout_r <= rom[...]`, one cycle late; `dsack0_n` combinational
   on address decode, immediate). `tb/stall_fsm_tb.sv`'s own memory model
   is zero-latency combinational throughout — this never exposes the
   race, since there's no gap between "DSACK says the word is ready" and
   "the data is actually valid." The one-cycle gap in a registered
   model is exactly what lets the IFU's queue end up holding a word from
   one cycle before the address it's nominally fetching, for the
   specific in-flight-during-a-redirect case this bug needs.

Neither ingredient alone was sufficient — reset boot + combinational
memory passed cleanly; JMP entry + registered memory (tried earlier,
per the six failed attempts) also passed cleanly. Both together
reproduce it reliably.

Two genuine testbench setup bugs were found and fixed along the way
(both documented in `tb/minrepro_tb.sv`'s own comments): a too-short
reset hold (`#1` instead of `stall_fsm_tb.sv`'s own proven
`repeat(20) @(posedge clk_4x)`) left `biu_config.sv`'s own
`poweron_rstout_n` counter at X forever in Icarus, silently preventing
the CPU from ever booting; and forgetting to initialize the reset
vector's own SSP value at address 0 (defaulting to the ROM's own
`4E71...` NOP fill pattern) caused a completely different, much louder
failure (the CPU treating garbage as a stack pointer) that looked like
but was not the real bug — both are exactly the kind of setup mistake
that can produce a false "FAIL" for the wrong reason, so anyone touching
this test should re-verify a genuine PASS after any setup change, not
just trust a FAIL matches the intended failure mode.

Run it: `make sim/minrepro && vvp sim/minrepro`. Now part of `ALL_TESTS`/
`make test` (38/38) since the fix below landed — PASSes reliably.

## Fix (implemented)

While reading `m68030_ifu.sv` to implement the epoch-tagging idea this
file originally proposed, a deeper, more fundamental problem surfaced
that made a simpler fix both necessary and sufficient — tracing the real
address path confirmed the bug is not just "a stale ack gets
misattributed," it's that **the address driven onto the real external bus
pins during an ordinary (cache/MMU-disabled) instruction fetch is never
latched for the duration of the bus cycle at all**:

- `biu_arbiter.sv` holds `grant_ifu` asserted for the *entire* bus cycle
  once granted (by design — see its own header comment), regardless of
  what `ifu_req`/`ifu_addr` do afterward.
- `biu_icache_if.sv`'s disabled-cache bypass path (`!icache_en && !tc_e`,
  the default reset state and this repo's own most common configuration)
  wires `cg_addr = ifu_addr` **combinationally, live, unlatched** — unlike
  its own *enabled*-cache path, which already latches the dispatched
  address into `cg_single_addr_r`/`ic_burst_addr_r` specifically to avoid
  this class of bug (Phase 128, see that file's own `abandoned_r`/
  `same_req` comments).
- `biu_cycle_gen.sv`'s own `cyc_addr = ifu_addr` (for the IFU grant case)
  is likewise live, and every S-state re-asserts `ext_a = cyc_addr`
  combinationally.

Chained together: `m68030_ifu.sv`'s old `pc_wr_en` handler updated
`fetch_addr_r` (which IS `ifu_addr`) immediately on every redirect, even
while a fetch was still genuinely in-flight — meaning the address on the
**real external bus pins could mutate mid-cycle**, after AS/DS were
already asserted for the old address. The previously-documented "stale
ack gets pushed into the queue" symptom is a direct consequence of this:
the old bus cycle keeps running (real hardware can't cancel it either),
using whatever address happens to be live at each S-state, and eventually
asserts `ifu_ack` — landing back on an IFU that has, by then, re-armed
`fetch_pend_r` for the real new target, causing the misattribution this
file originally traced in detail.

**The fix**: `m68030_ifu.sv`'s `pc_wr_en` branch now checks whether a
fetch is genuinely still outstanding (`fetch_pend_r && !ifu_ack &&
!ifu_berr`) at the moment of redirect. If so, it deliberately leaves
`fetch_addr_r`/`fetch_pend_r`/`skip_first_r` **completely untouched** —
letting the already-committed bus cycle run to its natural completion
with a stable, correct address — and instead sets a new `fetch_abort_pend_r`
flag plus latches the real target into a new `pending_pc_r` register. The
queue (`q[]`/`q_cnt`) is still flushed immediately, same as before. Once
that outstanding cycle's own `ifu_ack`/`ifu_berr` finally arrives (checked
first, ahead of the ordinary fill/error branches, in the main non-redirect
path), its data/fault is discarded unconditionally — no queue fill, no
`bus_err_r` latch — and only then does `fetch_addr_r`/`skip_first_r` switch
over to `pending_pc_r`, with `fetch_pend_r` left at 0 so the ordinary
ambient fetch-issue logic dispatches the real fetch on a later cycle, same
as an ordinary post-flush restart. If no fetch was outstanding (or its
ack/berr lands the very same cycle as the redirect, fully retiring it
before any address-mutation risk), the switchover happens immediately,
exactly as before this fix.

This is more surgical than the originally-proposed "epoch tag every
fetch" design (which would have fixed only the misattribution symptom,
not the underlying live-address-mutation defect) and needed no new BIU
port or cross-module signal — the entire fix is local to `m68030_ifu.sv`.
It was NOT applied inside `biu_icache_if.sv`'s own bypass path (mirroring
its already-existing `same_req`/`abandoned_r` mechanism) because the
address-latching defect is really an `m68030_ifu.sv`-side contract
violation (an unlatched, freely-mutating `ifu_addr` output during a
committed bus cycle) that would need fixing regardless of which
downstream module consumes it.

**Fallout found and fixed while verifying**: `tb/ifu_tb.sv`'s own
IFU-12a/12a2 (instruction-fetch-BERR-pending-until-use) started failing
after this fix — not a regression, but a stale timing assumption. The
IFU's own continuous ambient prefetching means a `write_pc()` call can
now always land mid-flight of some unrelated, already-in-progress
background fetch, adding a variable (bounded by `BIU_LAT`) extra delay
before the real target's own fetch chain even begins — exactly mirroring
real hardware's own equivalent limitation. IFU-12a's fixed `repeat(2*BIU_LAT+6)`
cycle budget no longer reliably covered this variable delay. Fixed by
adding a `wait_bus_err_r()` polling task (mirroring the file's own
existing `wait_valid()` convention) that polls the internal `bus_err_r`
latch directly rather than assuming a fixed cycle count from `write_pc`
to fault — a general, correct fix for the test's own now-inherently-
variable timing, not a hack.

**Verification**: `tb/minrepro_tb.sv` flips from FAIL to PASS with no
changes to the test itself; moved into `ALL_TESTS` (`make test`: 38/38,
was 37/37). Full 124-suite Tom Harte sweep via
`make sim/harte_vbatch` + `scripts/run_harte_batch.py --backend
verilator`: bit-identical to baseline, `PASS 702142 FAIL 2` (documented
ASL.b anomaly) `SKIP 281221 TIMEOUT 0` — confirming (as this file's own
earlier revision suspected) that the Harte corpus's own harness
construction never exercises this exact race, so this fix closes a real
gap the corpus itself is structurally blind to.

# Pipeline Stalls — Types, RTL Locations, and Test Coverage

This document catalogs every source of pipeline stall in the MC68030 implementation:
what triggers it, where it lives in the RTL, and which testbench proves it works. It
exists because the Tom Harte SingleStepTests corpus (the project's primary correctness
oracle) is structurally single-instruction — it resets state, executes exactly one
instruction, and checks the result — so it can never exercise anything that spans two
instructions or an asynchronous event arriving mid-instruction. Everything in this
document is tested by the `tb/stall_*_tb.sv` suite instead (Phases 103–126; see
`plan.md` for the full phase-by-phase history).

## Signal hierarchy

The EU's pipeline stall is `eu_seq.sv`'s `stall` signal (mirrored out as `seq_busy` /
`eu_busy`). It's assembled in three layers:

```systemverilog
assign stall_base = ex_mem_stall
                  || ex_exc_dispatch_hazard
                  || (ex_jmp_taken | ex_jsr_taken | ex_bsr_taken
                     | ex_rts_taken | ex_rtr_taken | ex_rte_taken | ex_dbcc_taken)
                  || (dec_valid && (hazard_ex || hazard_wb || hazard_ccr || need_ext
                                    || stop_first_cycle || stop_wb_hazard));

assign int_defer  = dec_valid && !stall_base && int_pending;
assign stall      = stall_base || int_defer;
assign eu_int_ready = int_defer;
assign seq_busy    = stall;
assign instr_ack   = dec_valid && !stall;
```
(`ex_exc_dispatch_hazard` and `stop_wb_hazard` were added in Phase 134 — see Categories
J and K below.)

`stall_base` is the "normal" reasons DECODE can't hand its instruction to EX this
cycle. `int_defer` is a separate, additive layer specifically for interrupt
recognition — see Category F below for why it has to be layered on top rather than
folded into `stall_base`.

Everything below is a *cause* that feeds into one of these terms.

## Category A — RAW / WAW register hazards

**What**: the instruction in DECODE reads a register the instruction currently in EX
or WB is about to write, and hasn't committed yet.

**RTL**: `eu_seq.sv`, `hazard_ex` / `hazard_wb`:
```systemverilog
assign hazard_ex = ex_valid && ex_writes_reg && (
                        (dec_reads_src && ex_dest_reg == dec_src_reg) ||
                        (dec_reads_dst && ex_dest_reg == dec_dst_reg)) || ...
assign hazard_wb = wb_valid && wb_writes_reg && ( ... same shape against wb_dest_reg ... );
```
Both also have a variant for 64-bit `MULS.L`/`DIVS.L` results (`ex_md_dst2`/
`wb_md_dst2`, the second destination register), and `hazard_ex` additionally covers
An autoincrement writeback (`ex_an_upd_en`) for non-RMW instructions, since that
commits one cycle later than the base result.

**Duration**: exactly 2 cycles if the consumer follows immediately after the producer
enters EX (one `hazard_ex` cycle, then one `hazard_wb` cycle once the producer moves to
WB), 1 cycle if there's already a 1-instruction gap, 0 if there's a 2+ instruction gap.
Verified as exact cycle counts, not just "eventually resolves" — see Test Coverage.

## Category B — CCR hazard

**What**: DECODE reads condition codes (`Scc`, `Bcc`, `DBcc`, `ADDX`/`SUBX`'s X input,
etc.) that the instruction in EX or WB is still in the process of updating.

**RTL**: `eu_seq.sv`, `hazard_ccr`:
```systemverilog
assign hazard_ccr = dec_reads_ccr && (
                        (ex_valid && ex_updates_ccr) ||
                        (wb_valid && wb_updates_ccr));
```

**Duration**: same 2/1/0-cycle shape as Category A. One easy mistake this project hit
directly (Phase 105 precision testing): a "neutral" filler instruction between producer
and consumer must genuinely touch neither registers nor CCR — `CLR` looks neutral for a
register-hazard test but *also* sets Z unconditionally, silently reintroducing a CCR
hazard one cycle later than expected. Use `NOP` for CCR-neutral filler, not `CLR`.

## Category C — missing extension word

**What**: DECODE needs an extension word (displacement, immediate, brief/full index
word) that the IFU hasn't delivered yet — the queue was drained faster than the BIU
could refill it.

**RTL**: `eu_seq.sv`, `need_ext = dec_needs_ext && !ext_valid;` — folded directly into
`stall_base`'s hazard OR-chain.

## Category D — multi-cycle EX-stage FSMs (`ex_mem_stall`)

**What**: an instruction whose execution genuinely spans multiple bus cycles — RMW
locks, register-list loads/stores, block moves, byte-interleaved transfers, memory
compare-and-swap, BCD adjust with memory operands, bit-field ops, MMU control
instructions, genuine two-level memory-indirect EA, and more. This is the single
largest stall source by RTL surface area: `eu_seq.sv` has roughly two dozen independent
phase-tracking register groups, all OR'd together into one signal:

```systemverilog
assign ex_mem_stall = tas_run_r || tas_read_ack || movem_start_r || movem_run_r ||
                      movep_start_r || movep_pre_r || movep_run_r ||
                      move16_start_r || move16_run_r ||
                      fpu_start_r || fpu_run_r ||
                      memind_start_r || memind_inner_r || memind_outer_r ||
                      pflush_start_r || pflush_req_r ||
                      ptest_start_r  || ptest_run_r  ||
                      cmp2_run_r || cmp2_first_ack ||
                      mem_rmw_run_r || mem_rmw_read_ack ||
                      move_mm_run_r || move_mm_read_ack ||
                      addx_mem_stall || bf_mem_stall || pack_mem_stall ||
                      cas_read_ack || cas_active_r || cas_write_r || cas_after_r || bcds_stall ||
                      cas2_rd1_ack || cas2_active_r ||
                      pmove64_run_r ||
                      (<generic mem_rd/mem_wr wait, exclusion-gated — see below>) ||
                      rtr_stall || rte_stall || cmpm_stall || stop_r || reset_run_r;
```

The generic clause (a plain, non-FSM-tracked read/write) is:
```systemverilog
(!tas_after_write_r && !cmp2_run_r && ... && !ex_cas2_done_r &&
 (ex_is_mem_rd || ex_is_mem_wr) && !mem_ack && !mem_abort)
```
— i.e. "this is an ordinary bus access, no dedicated FSM owns it, and it hasn't
acked (or aborted) yet." The long exclusion list exists so this catch-all clause
doesn't double-stall on top of an FSM-specific term that's already covering the wait.
Genuine memory-indirect EA (`memind_inner_r`/`memind_outer_r`) is itself one of the
dedicated FSM terms in this list, not routed through the generic clause — its own
pointer read and final read are two distinct phases.

**Important, project-specific fact**: `eu_cas2_req`/`eu_mo_req` (the "dedicated"
4-phase CAS2 datapath in `biu_cycle_gen.sv` and `biu_multiop_fsm.sv`'s generic
multi-op FSM) are **hardwired to `1'b0`** in `m68030_top.sv` — dead code. Every one
of the FSMs above, including CAS2, actually issues its bus cycles as ordinary
`eu_req`/`eu_ack` transactions through `biu_cache_if.sv`, sequenced entirely by the
phase registers listed above. Don't assume those "dedicated" BIU modules are in the
data path — trace `biu_cache_if.sv`'s own `state` register instead (see Phase 106/108
in `plan.md` for how this was discovered the hard way).

**Duration**: exact bus-cycle counts verified for a representative set (TAS=2,
MOVEM-2-registers=2, CMPM=2, CAS2=2, MOVEP=4, ADDX.L=3, genuine memory-indirect EA=2)
— see Test Coverage. **All ~23 originally-inventoried sources now have their own
dedicated decode-holdoff test** (Category B in `tb/stall_fsm_tb.sv`'s own internal
naming, B-1 through B-22) — the last gap, genuine memory-indirect EA, was closed in
Phase 124; its own test (B-22) goes further than a plain "did it unstick" check,
verifying the consuming register actually receives the correct value read through
*both* indirection levels.

## Category E — control-transfer stall (branch-taken bubble)

**What**: `BSR`/`JSR`/`RTS`/`RTR`/`RTE`/`JMP`/`DBcc` all resolve in EX and flush the
IFU the same posedge. The sequential instruction sitting in DECODE (fetched under the
old, now-stale PC) must not be allowed into EX — it has to wait exactly one cycle for
the flush to clear `dec_valid`.

**RTL**: `eu_seq.sv`, folded into `stall_base`:
```systemverilog
|| (ex_jmp_taken | ex_jsr_taken | ex_bsr_taken | ex_rts_taken | ex_rtr_taken | ex_rte_taken | ex_dbcc_taken)
```
Plain `Bcc`/`BRA` are *not* in this list — they resolve in DECODE, one pipeline stage
earlier, so they don't need this particular bubble.

## Category F — interrupt dispatch stall (`int_defer`)

**What**: a pending interrupt (`int_pending`, computed in `m68030_exc.sv` from
`ipl_sync`/`ipl_mask`) needs to be recognized *between* instructions, never mid-flight.
Real 68030 silicon only samples IPL at instruction boundaries.

**RTL**: `eu_seq.sv`:
```systemverilog
assign int_defer  = dec_valid && !stall_base && int_pending;
assign stall      = stall_base || int_defer;
assign eu_int_ready = int_defer;
```
`m68030_exc.sv`'s exception priority mux gates `int_pending`'s branch on
`int_pending && int_ready` (`int_ready` = `eu_int_ready`, threaded up through
`m68030_eu.sv`/`m68030_top.sv`).

**Why this is a separate layer, not folded into `stall_base`'s hazard clause**: the
naive approach — recognize the interrupt the instant `!eu_busy` — has a genuine race.
`instr_ack = dec_valid && !stall` fires combinationally the instant `stall` clears, so
if a ready instruction is sitting in DECODE the moment a multi-cycle FSM retires, it
launches into EX on the *exact same cycle* the exception controller would otherwise
recognize the interrupt and sample the return PC — the saved PC then points at an
instruction that's already executing (or, for a 1-cycle op, already committed), and
RTE silently re-runs it after returning. `int_defer` closes this by holding the ready
instruction in DECODE for the interrupt-recognition cycle instead of letting it race —
`m68030_exc.sv` then samples `ifu_decode_pc` on a cycle where nothing is simultaneously
launching. This was a real bug, found and fixed in Phase 108 — see `plan.md §Phase 108`
and `plan.md §Phase 105` for the original discovery.

**Duration**: held for as long as `int_pending` stays asserted — spans the entire
`EXC_PUSH`/`EXC_FETCH`/`EXC_LOAD` sequence in `m68030_exc.sv`, clearing naturally once
the IFU flush on `pc_wr_en` changes `dec_valid` out from under it.

**Coverage depth**: fixed and tested against 18 FSM sources — CAS2 (Phase 105,
the original discovery), MOVEM and genuine memory-indirect EA (Phase 125), TAS, MOVEP,
single CAS, and ADDX predecrement (Phase 126), PACK and BFINS (open-items backlog Stage
5, Phase 189), and MOVE16, ABCD, SBCD, CMP2, CHK2, MOVE mem-mem, RTR, RTE, and PMOVE64
(pipeline-stall breadth extension plan, elegant-gliding-fog.md Stages 1-4), via the
shared `run_int_mid_test` task, chosen to span the RMW-lock, byte-interleaved,
dual-address-predecrement, burst, two-read-bounds-check, control-transfer/
stack-restore, and 64-bit-load FSM shapes. The mechanism is decode-content-agnostic (it
gates purely on `int_pending`/`dec_valid`/`stall_base`, none of which vary by which FSM
is running), so there's no structural reason to expect a per-source bug, but this is now
the practical ceiling for this mechanism specifically: **PFLUSH and PTEST were both
attempted and found permanently untestable this way** — `run_int_mid_test`'s own
injection keys entirely on `data_ds_count` (FC=101 data-space bus activity), and
PFLUSHA has no bus operand at all while PTEST (under this file's own transparent-TT0
setup) produces zero such activity either (confirmed empirically, Stage 4) — neither
gives the mechanism anything to time an injection against. Testing "interrupt held off
during PFLUSH/PTEST's own internal duration" would need a different injection-timing
anchor (keyed on internal FSM state like `pflush_start_r`/`ptest_run_r` instead of bus
activity), a real but separate piece of work, not attempted here.

## Category G — bus arbitration contention

**What**: a BIU-level stall, not an EU-pipeline stall — MMU table-walk, EU, and IFU
requests can all be pending simultaneously; only one can drive the bus per cycle.

**RTL**: `biu_arbiter.sv` implements a fixed priority order (BIU-097–101): **MMU > EU
> IFU > external DMA**. `grant_mmu`/`grant_eu`/`grant_ifu` are mutually exclusive
per-cycle grants. A DMA request (`br`/`bgack`) is held off entirely while `bus_lock` is
asserted (RMW/CAS2/locked sequences in progress).

**Duration**: bounded by whatever's ahead of you in priority order finishing its own
current cycle — this is where an IFU prefetch can be starved for the full duration of
a long EU burst (MOVE16, MOVEM) before finally getting a grant.

## Category H — DSACK wait states

**What**: an external device hasn't asserted `DSACK0`/`DSACK1`/`STERM` yet; the BIU
must hold the bus cycle in S4/S5 indefinitely (well, up to the BERR watchdog timeout)
until it does.

**RTL**: `biu_cycle_gen.sv`:
```systemverilog
assign dsack_wait = !dsack0_s & !dsack1_s;
...
end else if (!dsack_wait) begin  // S4/S5 loop only advances once DSACK arrives
```

**Duration**: however many extra S-state cycles the device takes to respond — this
composes correctly with every other stall category (a stretched bus cycle for a
multi-beat FSM's *own* beats, not just a single ordinary access; see Test Coverage).

**Instruction-shape-dependent absorption effect (Phase 125)**: the S-state FSM doesn't
sample DSACK until several `clk_4x` ticks into a bus cycle regardless of how early it's
actually asserted, so a small number of injected wait states can be fully absorbed by
an instruction's own baseline per-beat latency with *zero* visible effect on total
elapsed time. Confirmed directly: `wait_states=3` (the value that works for TAS,
Phase 107's T4b) produces bit-identical elapsed cycle counts for MOVEM regardless of
whether it's applied — not a bug, just less slack available for TAS than for MOVEM.
`wait_states=10` reliably exceeds the absorption threshold for MOVEM. When adding a new
wait-state test for a different FSM, don't assume a value proven for one instruction
transfers to another — verify the effect is actually visible (via cycle-completion
tracing if the first attempt shows no difference) before trusting the check. Phase 126
reused `wait_states=10` directly for CAS2 and genuine memory-indirect EA and both
showed a clearly measurable delta on the first attempt (no repeat of the absorption
surprise) — but this was *verified*, not assumed, per the guidance above; a future
source could still land back in the absorbed regime.

**Coverage depth**: 12 FSM sources — TAS (`wait_states=3`), MOVEM, CAS2, genuine
memory-indirect EA (Phases 125-126), MOVEP, single-address CAS (Phase 188), ADDX, ABCD,
and PACK predecrement (pipeline-stall breadth extension plan, elegant-gliding-fog.md
Stage 5 -- all three added `wait_states=10`, verified against the absorption-effect
guidance above: each showed a clearly measurable delta on the first attempt, no
absorption surprise this time), and BFINS, CMP2, and MOVE mem-mem (Stage 6 -- see below,
`wait_states=60`, needed to overcome a *reversal*, not mere absorption).

**Head-start variant of the absorption effect (Stage 6)**: for BFINS/CMP2/MOVE-mem-mem,
`wait_states=10` didn't just get absorbed with zero visible effect — it produced a
*reversed* comparison (the wait_states=10 run measured *fewer* elapsed ticks than the
wait_states=0 run: 146 < 208 for BFINS). Root cause, confirmed via direct decode_pc/D5
tracing: the *first* run's own long RMW stall gives the IFU's linear readahead plenty of
real time to fetch all the way past the *second* run's own setup opcode while decode is
blocked waiting for EX to free up — so by the moment the first run's own completion is
observed and the wait-state knob is bumped for the second run, the second run's own
gate-loop (`for (...; decode_pc < target; ...)`) can exit after **zero** iterations,
starting that run's own measurement window with a head start large enough to swallow a
small wait-state addition outright, not just hide it. `wait_states=60` overwhelms the
head start with an unambiguous margin (measured 458 vs 208 for BFINS; 451 vs 96 for CMP2;
458 vs 150 for MOVEmm) — same tuning technique as the ordinary absorption effect above,
just needing a larger value for this shape. Not seen for ADDX/ABCD/PACK/MOVEM/CAS2/
Memind/MOVEP/CAS, whose own setup/FSM shapes apparently don't give the IFU enough of a
head-start window for this specific reversal to manifest at `wait_states=10`.

## Category I — bus error abort (`mem_abort`)

**What**: a bus cycle faults (`/BERR`) instead of completing normally. Every FSM in
Category D needs to abandon whatever it was doing and let the exception controller
take over, rather than waiting forever for a `mem_ack` that will never come.

**RTL**: `eu_seq.sv`:
```systemverilog
wire mem_abort = mem_berr || exc_active;
```
**Not just `mem_berr`** — `exc_active` has to be in the OR too. Trace evidence (Phase
108): once *any* fault is recognized and `exc_active` fires, `m68030_top.sv`'s arbiter
mux (`biu_eu_req = exc_active ? exc_req_w : eu_mem_req`) masks the EU's own bus request
out of the arbiter entirely, and `mem_ack`/`mem_berr` are both forced to 0 for the EU
(`.mem_ack(eu_ack && !exc_active)`, same for `mem_berr`) — permanently. If `exc_active`
wins the race before the EU's own `mem_berr` pulse for its in-flight access arrives (it
can, since exception recognition and the EU's own fault detection are asynchronous to
each other), a `mem_berr`-only abort condition would never fire, hanging forever despite
the BIU having correctly detected and reported the fault.

Each FSM that reacts to `mem_abort` needs its own abort transition — there's no single
central switch, because each phase-register group has its own "return to idle" shape.
Example (TAS):
```systemverilog
end else if (tas_run_r && (mem_ack || mem_abort)) begin
    tas_run_r <= 1'b0;   // write ack, or fault aborting the write phase — either way, done
end
```
A shared guard, `ex_berr_abort_wb`, suppresses one cycle of WB commit right after an
abort collapses `ex_mem_stall`, so an aborted instruction never writes back stale
`ex_valid`/`ex_writes_reg` data as if it had completed normally:
```systemverilog
logic ex_mem_stall_r, mem_abort_r, ex_berr_abort_wb;
always_ff @(posedge clk_4x or negedge rst_n) begin
    if (!rst_n) begin ex_mem_stall_r <= 0; mem_abort_r <= 0; end
    else        begin ex_mem_stall_r <= ex_mem_stall; mem_abort_r <= mem_abort; end
end
assign ex_berr_abort_wb = ex_mem_stall_r && mem_abort_r;
```
used in the WB latch as `else if (ex_mem_stall || ex_berr_abort_wb) begin <bubble> end`.

At the BIU level, the actual fault detection/reporting chain is:
`biu_cache_if.sv`'s `CI_D_MISS`/`CI_WRITE`/`CI_FILL_*` states → `CI_BERR` terminal
state (added Phase 108, mirrors `CI_DONE`) → `m68030_biu.sv`'s `eu_berr` (from
`ca_eu_berr`, not the raw every-retry-pulses `cg_eu_berr_raw`) → `m68030_top.sv`'s
`eu_bus_err_r`, latched directly off the `eu_berr` pulse itself (**not** an
edge-detector on `exc_frame_valid` — an earlier version did that and could only ever
fire once per *session*, since `exc_frame_valid` is deliberately sticky "until reset"
per BIU-090 and never returns to 0 for an edge-detector to re-arm on; `eu_berr` itself
is a genuine one-cycle pulse per fault via `biu_cache_if.sv`'s `CI_BERR` state
unconditionally returning to `CI_IDLE`, so it naturally re-arms every time — found and
fixed in Phase 114 after chaining a second, independent fault into one simulation for
the first time ever) → `m68030_exc.sv`'s `bus_err_req`.

### Coverage status — closed

**All ~19 `ex_mem_stall` FSM sources are confirmed correctly handled, with dedicated
fault-injection test coverage for every one of them.** History:

- **Phase 108** fixed the generic read/write clause, `tas_run_r` (TAS), `movem_run_r`
  (MOVEM), and CAS2's `rd2`/`wr1`/`wr2` phases (4 of ~19).
- **Phase 109** extended the identical fix pattern to 12 more sources: MOVEP, MOVE16,
  ADDX/ABCD/PACK predecrement forms, BFINS, CMP2/CHK2, MOVE mem-mem, single CAS, and
  RTR/RTE (16 of ~19 total). Two coding shapes needed slightly different treatment —
  sources gated directly in the top-level `ex_mem_stall` OR-list just needed a new
  abort arm; sources using a combinational stall formula needed *both* the formula
  updated *and* a separate phase-register reset arm, or the register stays stuck
  forever after the stall clears, silently corrupting the next instance of that
  instruction.
- **Phase 113** investigated the last two (PFLUSH/PTEST) and found them **already
  correctly handled** by pre-existing code — PFLUSH is architecturally immune (its ack
  comes from a pure internal ATC comparison, no bus access at all), and PTEST's table
  walker already had its own `mmu_berr`→`MS_FAULT` path predating this session. Zero
  RTL changes.
- **Phase 114** added dedicated BERR-mid-`<instruction>` tests for the 12 sources
  Phase 109 fixed but had never individually verified — in the process, chaining 12
  independent faults into one simulation for the first time surfaced a real,
  previously-undiscovered RTL bug (the `exc_frame_valid`-sticky "only first-ever fault
  per session gets reported" issue described above) plus three testbench-only bugs
  (a handler with no `RTE` silently re-executing the whole file after every fault; a
  stale-register-value false-positive at watch-loop entry; hardware racing ahead of a
  short instruction's own watcher before it had even started).
- **Phase 123** added 3 more dedicated tests for the full-format mode=110 EA paths
  added by the Phases 115–122 rollout (full-format CMP2, and MOVE mem-to-mem
  indexed-dst full-format via both its abs.W-src and register-src mechanisms) — all
  passed on the first run, confirming empirically (not just by inspection) that
  `mem_abort` really is decode-content-agnostic.
- **Phase 124** added the last dedicated test, `BERR-mid-Memind`, for genuine
  memory-indirect EA — the one `ex_mem_stall` source that had never had one.

No known gap remains in BERR-abort coverage.

## Category J — internal exception dispatch stall

**What**: an internal trap (privilege violation, illegal instruction, Line-A/Line-F,
TRAP/TRAPV, CHK/CHK2 bound trap, divide-by-zero, RTE format error) reaching EX has the
identical race Category F solves for external interrupts, but for a different trigger:
nothing previously blocked `dec_valid`'s continued advance behind it. `m68030_exc.sv`'s
actual flush (`new_pc_wr`, at the end of the `EXC_PUSH`/`EXC_FETCH`/`EXC_LOAD` sequence)
doesn't fire until several cycles after the trap is recognized, so — unblocked — decode
kept fetching and committing side effects (e.g. an EA autodecrement) from stale/garbage
bytes for the entire dispatch window.

**RTL**: `eu_seq.sv`:
```systemverilog
assign ex_will_except = ex_valid && (ex_is_trap || ex_is_trapv || ex_is_illegal ||
                                      ex_is_priv || ex_is_linea || ex_is_linef) ||
                         chk_trap || div_trap || eu_fmt_err_req;
assign ex_exc_dispatch_hazard = ex_will_except || exc_active;
```
Folded into `stall_base`'s own top-level OR (see Signal hierarchy above) using plain
bubble semantics, not `ex_mem_stall`'s frozen-EX shape — `m68030_exc.sv`'s `EXC_IDLE`
case only needs a single-cycle pulse to see the request, so nothing is lost by letting EX
advance immediately afterward; what matters is that `exc_active` itself, folded into the
same OR term, keeps blocking new dispatch for the rest of the window regardless of what
EX holds. Excludes `eu_reset_req` (RESET pulses RSTOUT directly, no frame dispatch to
race) and `eu_trace_req` (a genuinely different, post-retirement hazard shape, not
reproduced here — left as its own follow-up).

**Duration**: held for the entire `EXC_PUSH`/`EXC_FETCH`/`EXC_LOAD` window, same shape as
Category F's `int_defer`.

**Found**: Phase 134, while running the cache-verification plan's Step 6 (a 4-config
Harte sweep with the I-cache/D-cache enabled) — see `docs/cache.md`. Not
cache-*specific*: the bug is a plain pipeline race that an I-cache hit's shorter fetch
latency was simply the first thing in 133 prior phases to expose, by shrinking the
window between a trap firing and the next instruction's own opcode already sitting ready
in decode. No dedicated `tb/stall_fsm_tb.sv` test exists for this by name; verified via
the full 4-config Harte re-run coming back bit-identical to the disabled-cache baseline
across all ~700k tests.

## Category K — STOP SR-write collision

**What**: a narrower, WAW-shaped variant of Category B. `STOP`'s own SR write
(`stop_sr_wr_en`) fires unconditionally the instant STOP reaches EX, with nothing
previously gating it against a *different*, still-in-flight instruction's own same-cycle
CCR/SR commit — `sr_wr_data`'s priority mux would silently discard the real result,
corrupting the following instruction's own decode (traced symptom: STOP's own 2-word
opcode+operand desynced, and the operand word got misdecoded as a fresh, unrelated
instruction with a real side effect — an address register corrupted by exactly the
autodecrement amount of the accidental "instruction").

**RTL**: `eu_seq.sv`:
```systemverilog
assign stop_wb_hazard = dec_is_stop && !need_ext && (
                            sr_wr_en ||
                            (ex_valid && (ex_updates_ccr || ex_is_move_sr_w || ex_is_move_ccr_w)));
```
The `ex_valid` check covers all three of `sr_wr_data`'s own WB-delayed source flags, not
just the ordinary ALU-CCR-commit one — `MOVE Dn,SR`/`MOVE Dn,CCR` commit via
`wb_is_move_sr_w`/`wb_is_move_ccr_w`, a completely different flag an early version of
this fix didn't check, leaving that specific pairing (the shortest-EX-residency
instruction forms, so the most likely to still be in EX when STOP reaches decode)
exposed. Gated on `!need_ext` so it doesn't fire before STOP's own operand word has
actually arrived — otherwise it would collide with, rather than compose with, the
pre-existing Category C stall already handling that wait.

**Duration**: one cycle — resolves as soon as the colliding write commits.

**Found**: same Phase 134 investigation as Category J, same discovery mechanism (4-config
Harte sweep) — see `docs/cache.md`.

## Test coverage map

| Category | File | Representative checks |
|---|---|---|
| A. RAW/WAW hazard | `tb/stall_hazard_tb.sv`, `tb/stall_fsm_tb.sv` | 4 producer types × no-gap/1-gap/multi-gap timing; exact 2/1/0-cycle counts via direct signal reads. `RAW-hazard-with-Ihit` (Phase 135, `stall_fsm_tb.sv`) additionally confirms the hazard still resolves correctly across 10 passes of a loop served entirely from I-cache hits after the first — see `docs/cache.md` |
| B. CCR hazard | `tb/stall_hazard_tb.sv` | Same shape as A, using `CMP`→`Scc`; exact 2/1/0-cycle counts |
| C. Missing ext word | *(folded into A's harness where reachable; see file header for scope note)* | |
| D. Multi-cycle FSM | `tb/stall_fsm_tb.sv` | All 23 of ~23 sources (closed Phase 124), decode-holdoff + a real dependent instruction after; exact bus-cycle counts for TAS/MOVEM/CMPM/CAS2/MOVEP/ADDX.L/memory-indirect EA; the memory-indirect EA check (B-22) also verifies the loaded register's actual value, not just "did it unstick" |
| E. Control-transfer | `tb/stall_hazard_tb.sv` | BRA/JMP(register-indirect+abs)/DBF-taken/JSR+RTS round trip through real memory |
| F. Interrupt dispatch | `tb/stall_fsm_tb.sv` | Level-7 NMI mid-instruction, 18 sources (CAS2/MOVEM/memory-indirect EA/TAS/MOVEP/CAS/ADDX/PACK/BFINS/MOVE16/ABCD/SBCD/CMP2/CHK2/MOVEmm/RTR/RTE/PMOVE64, Phases 105/125/126/189, elegant-gliding-fog.md Stages 1-4 -- practical ceiling for this mechanism; PFLUSH/PTEST confirmed permanently untestable this way, no FC=101 bus activity to anchor an injection on); non-idempotent dependent-instruction marker (regression would show up as a doubled value); exact bus-cycle count before the interrupt was recognized |
| G. Bus arbitration | `tb/biu_tb.sv` | MMU>EU>IFU 3-way priority; IFU starvation+recovery under a real multi-beat burst; DMA held off by `bus_lock` |
| H. DSACK wait states | `tb/stall_fsm_tb.sv` | 0/2/5 wait states on a simple access, and separately on every beat of a real multi-phase FSM — 12 sources (TAS at wait_states=3; MOVEM/CAS2/memory-indirect EA/MOVEP/CAS/ADDX/ABCD/PACK at wait_states=10; BFINS/CMP2/MOVEmm at wait_states=60, Phases 125/126/188, elegant-gliding-fog.md Stages 5-6; see Category H's own absorption-effect note, including the Stage 6 "head start" reversal variant, for why the values differ) |
| I. BERR abort | `tb/stall_fsm_tb.sv` | Sustained fault injected mid-instruction for **every one of the ~19 `ex_mem_stall` sources** (closed Phases 108/109/113/114/123/124) — real vector-2 dispatch, handler reached, `eu_busy` recovers (no lingering hang), for each |
| J. Internal exception dispatch | *(no dedicated unit test — see Category J above)* | Verified via the full 4-config Harte re-run (`tb/harte_vbatch`) coming back bit-identical to the disabled-cache baseline, Phase 134 |
| K. STOP SR-write collision | *(no dedicated unit test — see Category K above)* | Same 4-config Harte re-run as Category J, Phase 134 |
| Back-to-back FSMs | `tb/stall_fsm_tb.sv` | 4 pairs (Phases 107/126/191): TAS→MOVEM, MOVEP→CAS, memory-indirect-EA→TAS, ADDX→TAS, each a genuinely different FSM-shape handoff, no instruction between them |

Run everything with `make test` (35/35, includes all of the above except Categories J/K,
which are verified via the Harte sweep instead — see those categories' own entries). See
`plan.md`
Phases 103–126 for the full session-by-session narrative, including dead ends that
are worth knowing about before extending this suite:

- **Direct `eu_seq` instruction injection** (mirroring `eu_seq_tb.sv`'s own low-level
  technique) was tried first for Category A/B and abandoned — same-simulation-time-step
  races between a blocking assignment and the combinational decode logic it feeds gave
  inconsistent results. Driving real instruction sequences through the actual IFU
  converged cleanly on the first attempt instead; prefer that.
- **This file's test programs execute via pure NOP-fall-through** (PC only ever
  increases, never branches back). Any code moved earlier in *program order* also needs
  a numerically lower ROM address than whatever runs after it, or PC can never walk
  backward to reach it — this bit Phase 108 directly when back-to-back-FSM tests were
  reordered without renumbering their addresses.
- **A test that starts measuring/watching immediately (no `decode_pc` pre-wait), placed
  right after an interrupt-mid-FSM or BERR-mid-FSM test, can catch that prior test's own
  trailing bus activity** (RTE's stack reads, a handler's tail) instead of its own —
  `decode_pc` crossing a threshold doesn't guarantee the instruction at that address has
  actually finished retiring in EX. This bit both `WS-MOVEM` (Phase 125) and `T4c`
  (Phase 126) the identical way; the fix both times was an explicit `decode_pc`-gating
  loop before the measurement window starts, not just before the test's own code region.
  Any *new* test placed immediately after an async-event test should default to this
  gating rather than assuming `run_and_check`'s own bare poll is enough.

## What's left, if anything

As of Phase 126, no known *correctness* gap remains anywhere in this document — every
stall category has RTL and at least one passing test, every `ex_mem_stall` FSM source
has both decode-holdoff and BERR-abort coverage, and the two mechanisms layered on top
(interrupt dispatch, DSACK wait states) are proven correct in principle across several
FSM shapes each. What remains is purely *breadth*, not depth:

- **Back-to-back FSM composition** (Category D→D handoff) has 4 pairs (TAS→MOVEM,
  MOVEP→CAS, memory-indirect-EA→TAS, ADDX→TAS, Phases 107/126/191) out of the many
  possible combinations. Nothing suggests a further pairing would behave differently,
  but only these four have been checked.
- **Interrupt-mid-FSM** (Category F) has 18 of ~19-23 possible FSM sources checked
  individually (CAS2/MOVEM/memory-indirect EA/TAS/MOVEP/CAS/ADDX/PACK/BFINS -- Phase 189's
  own open-items backlog Stage 5 added the last two -- plus MOVE16/ABCD/SBCD/CMP2/CHK2/
  MOVEmm/RTR/RTE/PMOVE64, added by the pipeline-stall breadth extension plan's own
  Stages 1-4, elegant-gliding-fog.md). Same reasoning as above — the mechanism is
  decode-agnostic by construction, but only spot-checked, not exhaustively swept the way
  Category I was. **This is now the practical ceiling**: PFLUSH/PTEST were both
  attempted (Stage 4) and confirmed permanently untestable via this specific mechanism
  (`run_int_mid_test` keys on FC=101 bus activity; neither instruction produces any
  under this file's own transparent-TT0 MMU setup) -- a real, documented limitation of
  the injection technique itself, not a gap in FSM coverage.
- **DSACK wait-states-on-FSM-beats** (Category H) has 12 sources checked (TAS, MOVEM,
  CAS2, memory-indirect EA, MOVEP, single-address CAS -- Phase 188's own open-items
  backlog Stage 4 added the last two -- plus ADDX, ABCD, and PACK predecrement, added by
  the pipeline-stall breadth extension plan's own Stage 5, and BFINS, CMP2, and MOVE
  mem-mem, added by that same plan's Stage 6, elegant-gliding-fog.md).
  Given Phase 125's own absorption-effect finding, a new source needs its own
  wait-state-value sanity check (don't assume `wait_states=3` or `=10` transfers
  automatically) rather than a purely mechanical extension -- Stage 5's own three
  additions all showed a clearly visible delta at `wait_states=10` on the first try
  (ADDX 227->255, ABCD 113->255, PACK 99->233 ticks), but Stage 6's own three needed
  `wait_states=60` after `=10` produced an outright *reversed* comparison (see Category
  H's own "head start" note above) -- verified, not assumed, in both directions.
  Remaining: MOVE16, PTEST, PMOVE64.

None of these block using the CPU today; they're the natural next increment if more
confidence is wanted in the generic mechanisms specifically.

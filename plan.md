# Phase Log

Running writeup of each completed phase in this project, in order. For
Phases 1-161 (through the Chapter 11 Part A/B timing-verification plan),
see `plan.md.old` -- archived here because it had grown to ~9500 lines.
`CLAUDE.md` keeps a one-paragraph summary of each phase plus the current
overall project state; this file holds the full writeup each summary
links back to.

## Phase 162 Stage D0

First stage of the new full-clock-cycle-accuracy plan
(`~/.claude/plans/compressed-hopping-cocoa.md`), scoped after Phase 161
Part B found the total-clock gap is bidirectional: bus-touching
instructions run slower than the manual (dispatch overhead, already
characterized in Stage B0), register-only instructions net close to even
but hide two canceling effects -- shift/rotate-by-register-count and
bit-field ops run substantially *faster* than the manual.

Stage D0's own job: confirm whether that "faster" gap is FLAT per
instruction class (matching a simple lookup-table fix) or scales with a
runtime parameter (shift count, field width/scan depth -- which would need
a real formula-driven microsequencer instead, a materially bigger design).
Built 4 new tests (`tests/timing/d0_*.s` + `d0_confirm.json`): `LSL.L
Dx,Dy` at count=1 vs count=30 (both within the manual's own "count≤32"
bucket), and `BFFFO Dn` with the set bit at the shallowest possible scan
position (offset 0) vs the deepest (offset 31, the full 32-bit field).

**Result: completely flat in both cases.** `d0_lsl_cnt1`/`d0_lsl_cnt30`
both measure `ticks=14` (identical, not just close); `d0_bfffo_early`/
`d0_bfffo_late` both measure `ticks=34` (identical). Confirms `eu_shifter.
sv`/`eu_bitfield.sv`'s own fully-combinational, single-EX-cycle
computation genuinely takes the same time regardless of shift count or
scan depth -- as expected given `eu_bitfield.sv`'s own `ffo_result`
computation is a fully-unrolled 32-iteration `for` loop resolved
combinationally, not an iterative search. **Confirms the Part D lookup-
table design from the approved plan**: the fix is N fixed extra stall
cycles per instruction class (2 buckets for register-count shift/rotate,
1 flat value for everything else), computed directly as `manual_NCC_total
- this_project's_own_already-measured_baseline` -- no runtime-dependent
formula needed anywhere in Part D's own scope.

Also clarified, while designing the confirmation tests, a subtlety that
matters for Stage D1's own upcoming lookup-table derivation: comparing a
4-byte (2-word) register-only instruction's own measured clocks against a
2-byte (1-word) one's isn't apples-to-apples, since the longer encoding
alone costs more prefetch ticks regardless of any internal-microcode gap
(confirmed via `a2_movec_read`, a 4-byte register-only instruction with no
internal-microcode complexity at all, measuring the *same* 8 clocks as
BFFFO's own -- meaning BFFFO's own entire measured total is just its
"free" 2-word baseline, with literally zero cycles attributable to the
scan itself). The correct per-instruction stall amount is therefore
directly `manual_total - measured` (i.e. the already-computed `gap`
column from `scripts/b_final_clock_survey.py`), not something requiring a
separate word-count correction.

### Results

4/4 new tests pass, `make test` 36/36 (no RTL changes this stage --
confirmed via `git diff --stat rtl/`, no Harte/cosim re-run needed).

### Status

Stage D0 closed. Stage D1 (design the stall mechanism) is next.

## Phase 162 Stage D1

Designed and implemented the artificial-internal-stall mechanism as pure,
inert plumbing (mirroring Phase 148's own "add `rd_c` port — pure
plumbing, no consumer yet" precedent) -- Stage D2 will populate it for a
real instruction family.

Studied `ex_mem_stall`'s own existing semantics before designing anything
new, since it turned out to already be exactly the right shape to reuse
rather than invent something parallel: `ex_mem_stall=1` freezes every
`ex_*` EX-stage latch unchanged (`rtl/eu_seq.sv`'s own EX-latch `always_ff`
has an explicit `else if (ex_mem_stall) begin end` branch — un-driven
signals retain their value) and bubbles WB (`wb_valid<=0` in the matching
WB-stage `always_ff`) for as long as it holds, with the *already-computed*
`ex_*` values committing untouched the instant it clears. That's precisely
what an artificial stall needs: hold the instruction "in EX" (its result
already correct, computed combinationally as always) for N extra cycles
before letting WB observe it.

**`rtl/eu_seq.sv`**: new `dec_internal_stall_ticks` (combinational,
decode-time, `8'd0` for every instruction until Stage D2+ populates real
whitelist entries), `internal_stall_cnt_r` (a down-counter, loaded with
`dec_internal_stall_ticks` on the exact cycle a whitelisted instruction
dispatches into EX -- gated on `instr_ack`, the same "entering EX right
now" condition every other one-shot EX-entry latch in this file already
keys off, e.g. `tas_run_r`'s own trigger), and `ex_internal_stall`
(`internal_stall_cnt_r != 0`). Wired into the three places `ex_mem_stall`
itself needed to reach for its own freeze semantics to work: `stall_base`
(so decode stays frozen while counting down), the EX-latch freeze branch,
and the WB-bubble branch — plus `eu_trace_req`, which needed the same
`!ex_internal_stall` guard `!ex_mem_stall` already has (trace shouldn't
request its own post-instruction exception before an artificially-delayed
instruction has actually finished). Traced through the cycle-by-cycle
timing by hand before committing to the load-on-`instr_ack` design: since
`instr_ack` fires at decode→EX handoff, the counter only becomes visible
(`ex_internal_stall=1`) the cycle *after* dispatch — exactly matching when
`ex_mem_stall`-style freezing needs to first take hold, since the
dispatching cycle itself is decode's own last legal chance to hand off
before it must stay put.

Deliberately did **not** touch two CAS/CAS2-specific `!ex_mem_stall`
checks elsewhere in the file (`ex_cas_mem_done_r`/`ex_cas2_done_r`'s own
"EX advancing to a new instruction" bookkeeping) — reasoned through
rather than reflexively touched: `ex_internal_stall` and `ex_mem_stall`
are structurally mutually exclusive per-instruction (single-issue
pipeline, and Part D's own whitelist only ever targets simple
register-direct ALU/shift/bit-field-shaped instructions, never the
memory-FSM instructions `ex_mem_stall` itself covers), so these two
signals can never simultaneously matter for the same in-flight
instruction — touching them would add risk to already-proven CAS/CAS2
logic for zero actual behavioral difference.

### Results

Confirmed fully inert: `git diff --stat rtl/` shows only `rtl/eu_seq.sv`
touched; `make test` 36/36; `make cosim_grp` 8/8; `make cosim_memind`
12/12; Stage D0's own 4 tests still pass unchanged (`ticks=` identical to
before this stage); full 124-suite Harte sweep (mandatory — `eu_seq.sv`
changed, and this specific change touches `stall_base`/the EX-freeze/WB-
bubble branches shared by every instruction in the corpus) — PASS 702142,
FAIL 2 (same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0,
bit-identical to baseline, confirming the new mechanism has zero effect
anywhere it isn't explicitly populated.

### Status

Stage D1 closed. Stage D2 (implement for shift/rotate register forms,
the first real whitelist entries) is next.

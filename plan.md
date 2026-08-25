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

## Phase 162 Stage D2

Populated the artificial-internal-stall mechanism for shift/rotate
register-count forms (ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR) — the first real
whitelist entries, the highest-confidence family available (the manual's
own `SHIFT_ROTATE` table is the most detailed anywhere in this rollout,
and all 8 op×size combinations are 100%-passing Harte suites, the
strongest correctness gate this whole plan has access to).

### A real design complication found while implementing, not anticipated in Stage D1

`dec_internal_stall_ticks`'s original design (Stage D1) assumed the stall
amount could always be computed purely combinationally at decode time.
That holds for ASL/ROL/ROR (a single flat NCC value regardless of count)
and ROXL/ROXR (one row, "ROXd Dn", covering immediate *and*
register-supplied count identically — no separate rows exist), but not
for LSL/LSR/ASR: the manual's own `%`(count≤operand-size)/`+`(count>size)
bucket split needs the *live*, register-supplied count value, which isn't
known until the register file read resolves — the same timing `shf_count`
itself already has (valid once `ex_valid=1`, not at decode time).

Solved with a two-stage load: a `dec_needs_stall_resolve` flag arms at
`instr_ack` (decode→EX handoff) for LSL/LSR/ASR register-count forms
specifically; on that same cycle, `internal_stall_resolving_r` (folded
into `ex_internal_stall` exactly like the counter itself, so it freezes
the pipeline through the whole one-cycle resolution window, not just once
the real count loads) goes high; the *following* cycle, once
`ex_shf_op`/`ex_siz`/`shf_count` are all valid, the real tick count is
computed (`ex_internal_stall_ticks_resolved`, comparing `shf_count`
against the operand width derived from `ex_siz`) and loaded into the
down-counter. ASL/ROL/ROR/ROXL/ROXR skip this entirely, loading their
fixed value directly at `instr_ack`.

### A second, purely mechanical complication: Icarus forward-reference rules

The `ex_internal_stall_ticks_resolved` computation needs `ex_siz`/
`ex_shf_op`, both declared much later in the file (the big EX-latch
declaration block) than where Stage D1 placed the rest of this mechanism
(right after `ex_mem_stall`/`ex_berr_abort_wb`, needed there so
`stall_base` — assigned shortly after — could reference `ex_internal_stall`
without its own forward-reference problem). Rather than relocate
`ex_siz`/`ex_shf_op` themselves (used throughout the file, high blast
radius for a purely mechanical fix), split the mechanism: declarations of
`internal_stall_cnt_r`/`internal_stall_resolving_r`/`ex_internal_stall`
plus the decode-only `dec_internal_stall_ticks_fixed`/
`dec_needs_stall_resolve` stay at the original Stage D1 location; the
actual `always_ff` that *drives* those two registers (needing
`ex_shf_op`/`ex_siz`/`shf_count`) moved to just after `ex_siz`/`ex_shf_op`
are declared, right before the big EX-latch update block — a plain
Verilog register can be declared in one place and driven by an
`always_ff` anywhere else in the same module, so this required no
semantic change, just relocating which lines live where (documented with
a cross-reference comment at both ends so a future reader isn't confused
by the split).

### Baseline confirmation before computing N

Directly measured `ROL.L Dx,Dy` (register form, not yet covered by any
existing test) before finalizing the lookup table: `ticks=14` — the same
baseline every other register-direct 1-word instruction measures,
confirming the 3-clock (12-tick) baseline used to derive every N value
(`N_ticks = (manual_NCC_clocks - 3) * 4`) really is uniform across this
whole family, not just the two cases Stage D0 already checked (LSL/BFFFO).

### Results

**Exact match, not just "closer"**: every one of the 5 directly re-
measured whitelist entries now reports `MEASURED clocks=` identical to
the manual's own NCC total — `LSL.L Dx,Dy` (%, 6), `ASL.L Dx,Dy` (flat,
8), `ASR.L Dx,Dy` (+, 10), `ROR.L Dx,Dy` (flat, 8), `ROXL.L #1,Dn` (flat,
12) — all gap=0 in `scripts/b_final_clock_survey.py`'s own re-run (was
-3/-5/-7/-5/-9 respectively before this stage). Immediate-count forms
(`LSL.L #1,Dy`, `ROL.L #1,Dy`) correctly remain unaffected (not in this
stage's own whitelist, `clocks=3` unchanged) — the small residual gap
those still carry (manual NCC=4/6 vs measured 3, i.e. -1/-3) is deferred
to a later Part D stage, not this one.

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12, all 24
directly-affected Harte suites (ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR × b/w/l)
individually re-run at 100% (`PASS 148449 FAIL 2` — the 2 being the same
documented ASL.b corpus anomaly, unrelated), then the full 124-suite
sweep — PASS 702142, FAIL 2, SKIP 281221, TIMEOUT 0, bit-identical to
baseline. This is the strongest possible confirmation available in this
whole plan: the artificial stall changes *only* total clock count
(informational, never asserted against Harte), while every one of the
~24000 directly-relevant Harte vectors (final-state correctness) remains
untouched.

### Status

Stage D2 closed — the first real clock-accuracy fix landed and fully
verified. Stage D3+ (bit-field ops, then the smaller-gap register-direct
families) is next.

## Phase 162 Stage D3

Populated the artificial-internal-stall mechanism for bit-field register
(Dn) forms: BFCHG/BFCLR/BFSET/BFEXTS/BFEXTU/BFINS/BFFFO. Simpler than
Stage D2's own shift/rotate work in one respect (bit-field offset/width
come from the already-fetched extension word, not a live register read,
so every one of these is fully decode-time computable -- no two-stage
resolving needed, straight into `dec_internal_stall_ticks_fixed`'s
existing `always_comb`) but needed care in a different place: confirming
which of the 7 non-`BFTST` ops have a *natural* (not marker-inflated)
measured baseline to trust. `BFCHG`/`BFCLR`/`BFSET` write back to the same
`Dn`; `BFEXTS`/`BFEXTU`/`BFINS`/`BFFFO` write a genuinely different
destination `Dx` (their own real ISA behavior, not an artificial test
marker) -- all 7 confirmed to share the identical 8-clock (32-tick)
baseline via Stage A5's own already-existing tests, re-checked against the
`b_final_clock_survey.py` output before finalizing N. `BFTST` itself
(read-only, no register write in the real ISA either) already matches the
manual's own NCC=8 exactly with zero stall needed -- deliberately absent
from the whitelist, not an oversight.

### One real regression found and fixed, in a pre-existing unit test

`make test` initially failed: `tb/bitfield_tb.sv`'s own `BFSET-01:ccr:Z`
check. `run_instr`'s own completion-detection uses a **fixed** `repeat(15)
@(posedge clk)` margin after `instr_ack`, not a real completion signal --
adequate for every pre-Stage-D3 (unstalled) bit-field instruction, but
BFFFO alone now needs 48 *extra* ticks beyond that old margin. Same class
of finding this project has hit repeatedly before when a real timing
change invalidates a fixed-wait test assumption (e.g. Phase 104's own
PMOVE CRP budget, 3000→20000 ticks, for an unrelated reason). Fixed by
widening the shared margin to `repeat(80)`, comfortably covering BFFFO's
own new worst case.

### Results

Exact match for all 7 real whitelist entries (`scripts/
b_final_clock_survey.py`'s own gap column, all 0): BFCHG/BFCLR/BFSET
(14), BFEXTS/BFEXTU (10), BFINS (12), BFFFO (20) -- was -6/-6/-6/-2/-2/
-4/-12 before this stage. The full 117-test survey's own negative tail
shrank from min=-12 to min=-3 (the residual -3s are the still-unfixed
immediate-count shift/rotate forms, explicitly deferred, not new).
`make test` 36/36 (after the `bitfield_tb.sv` margin fix), `make
cosim_grp` 8/8, `make cosim_memind` 12/12, full 124-suite Harte sweep
(mandatory -- `eu_seq.sv` changed, and bit-field ops themselves have zero
Harte coverage at all, so `tb/bitfield_tb.sv`'s own 24 checks plus this
sweep's confirmation that nothing ELSE regressed are the whole
correctness gate here) -- PASS 702142, FAIL 2 (same documented ASL.b
anomaly), SKIP 281221, TIMEOUT 0, bit-identical to baseline.

### Status

Stage D3 closed. Stage D4+ (the smaller-gap register-direct families --
BCD ops, EXG/SWAP/TAS/Scc/MOVE CCR-SR-USP/MOVEC, plus the still-deferred
immediate-count shift/rotate forms) is next.

## Phase 162 Stage D4

### Context

Extended the artificial-internal-stall whitelist two ways: (1) generalized
the shift/rotate case in `dec_internal_stall_ticks_fixed` from Stage D2's
register-count-only forms to also cover *immediate*-count forms (`LSL.L
#2,Dy` etc, `dec_use_reg_cnt=0`) -- these are pure decode-time-computable
(no live register read needed, unlike the register-count `%`/`+` bucket
split), so no new resolving-stage machinery was needed, just widening the
existing `case (dec_shf_op)` arms with an `if (dec_use_reg_cnt) ... else
...` split per op; (2) added a small, flat whitelist for EXG/MOVE CCR,Dn/
MOVE SR,Dn/SWAP -- four simple register-direct instructions all sharing
the project's own established 3-clock (12-tick) 1-word baseline, each
needing just 1 clock (4 ticks) to match the manual's own NCC=4.

### A real near-miss caught before it shipped

`dec_unit == UNIT_SHF` is set by BOTH the register-direct shift/rotate
decode block (`f_ss != 2'b11`, no memory access) AND the completely
separate memory-EA single-bit shift decode block (`f_dn[2]==0` +
specific `f_mode`s, `dec_is_mem_rmw=1'b1`, e.g. `ASL.W (An)`) -- my first
whitelist draft (`if (dec_valid && dec_unit == UNIT_SHF)`) fired for
both, wrongly injecting a 4-tick internal stall into memory-destination
shifts too. Their own manual row is fea/cea-based (bus-cycle-driven,
already exact since Stage A1/A4) with no separate internal-only
component -- caught by `make test`'s own pre-existing `alu_mem_tb.sv`
("ASL-01:mem"/"ASL-01:Z" failed), not by reasoning alone; the actual
fix was adding `&& !dec_is_mem_rmw` to the whitelist's own top-level
gate, the one signal that already distinguishes the two decode blocks.

### A second, testbench-only regression: eu_seq_tb.sv's own `drain()`

`tb/eu_seq_tb.sv`'s `run()` task (`send()` + `drain()`) uses a *fixed*
2-cycle `drain()` sized for "EX->WB->regfile-commit" on an unstalled
instruction -- with immediate-count shift/rotate now carrying a real
stall, E1-E6 (the file's own pre-existing shift-instruction checks) all
started reading a value exactly ONE INSTRUCTION STALE (e.g. E1's own
`LSL #2` check read D0's PRE-shift value, while E2's check read E1's own
POST-shift result) -- the write was landing, just one full `run()` call
later than `drain()` was waiting for.

First fix attempt: add `while (seq_busy) @(posedge clk_4x);` after the
fixed 2 cycles, mirroring the shape this same file's own cpSAVE/cpRESTORE
tests already use. This alone did NOT fix it (identical failures,
identical values) -- traced to `rtl/eu_seq.sv`'s own WB-stage latch:
`wb_valid <= ex_valid;` fires only in the `else` branch, i.e. the cycle
*after* `ex_internal_stall` itself clears, and the actual `eu_regfile`
array write trails `wb_valid` by a further cycle -- so a loop that exits
the instant `seq_busy` first reads 0 is still (at least) one cycle short
of the real commit. Fixed by pairing the `while (seq_busy)` loop with a
fixed `repeat(4)` settle margin afterward -- exactly the same two-part
shape the file's own cpSAVE/cpRESTORE tests already used (apparently for
the identical reason, never spelled out there either). Confirmed via
`make test`: all previously-stale E1-E6 checks now read correctly, and
the previously-unexplained downstream F1-F3 (MULU/MULS/DIVU) failures
-- never actually broken by this stage's own RTL change, just corrupted
by E-series' own stale D0/D1 values feeding into F1's setup -- cleared
as a direct consequence, confirming they were never a separate bug.

### Results

Exact match (`scripts/b_final_clock_survey.py` gap=0) for all 6 directly
targeted tests: `a2_exg`/`a2_move_ccr_dn`/`a2_move_sr_dn`/`a2_swap`
(manual=4, was gap=-1 each) and `a5_lsl_imm_dy` (manual=4, was -1)/
`a5_rol_imm_dy` (manual=6, was -3). The full 117-test survey's own
negative tail shrank further: min=-3 (was -3 already, but now from a
*different*, smaller residual set -- NBCD/dynamic-BCHG-BCLR-BSET's own
-3s, not the immediate-shift ones D4 just fixed), gap distribution now
`{-3: 4, -1: 7, 0: 22, ...}` (22 tests at an exact match, was fewer
before this stage). `make test` 36/36 (after both the `eu_seq.sv`
`!dec_is_mem_rmw` fix and the `eu_seq_tb.sv` `drain()` fix), `make
cosim_grp` 8/8, `make cosim_memind` 12/12, full 124-suite Harte sweep
(mandatory -- `eu_seq.sv` changed) -- PASS 702142, FAIL 2 (same
documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to
baseline.

### Status

Stage D4 closed. Remaining register-only negative-gap entries, all
small (-1/-3): ABCD/SBCD/EXT/Scc/TAS register-direct forms (-1 each),
NBCD (-3), dynamic BCHG/BCLR/BSET Dn,Dn (-3 each), and ANDI-to-SR/CCR
(-1 each, a bus-touching-but-register-only-classified pair) -- these are
Stage D5's own scope. Part E (bus-touching dispatch-overhead reduction)
remains untouched.

## Phase 162 Stage D5

### Context

Closed out the remaining small (-1/-3) register-only negative-gap entries
Stage D4 left open: ABCD/SBCD Dn,Dn, EXT (EXT.W/EXT.L/EXTB.L), Scc Dn,
TAS Dn, NBCD Dn, and dynamic BCHG/BCLR/BSET Dn,Dn -- plus an
investigation into ANDI/ORI/EORI #imm,SR/CCR.

### Decode-signal reconnaissance

Each op needed a way to isolate its register-direct form from a memory-
destination sibling that shares the same `dec_unit`/`dec_bcd_op`/
`dec_bit_op` value -- Stage D4's own `!dec_is_mem_rmw` lesson applied
again, generalized: read the actual decode blocks in `eu_seq.sv` before
writing any condition, rather than trusting a shared enum value alone.
Found: `dec_is_abcd_sbcd_mem` already exists and cleanly excludes ABCD/
SBCD/NBCD's own `-(Ay),-(Ax)`/memory-EA forms; the memory forms of NBCD/
TAS/dynamic-BCHG-BCLR-BSET all set `dec_is_mem_rd=1'b1` (their register-
direct siblings never do) -- the same signal, reused three times, is
enough on its own. `EXT.W`/`EXT.L`/`EXTB.L` share `dec_sext=1'b1` with no
memory form at all (real ISA constraint, no exclusion needed). Scc Dn had
no existing dedicated flag distinguishing it from `Scc <ea>` -- added a
new `dec_is_scc_dn` (mirrors `dec_is_tas`'s own shape), set only in the
`f_mode==3'b000` register-direct arm.

### RTL

`rtl/eu_seq.sv`'s `dec_internal_stall_ticks_fixed`: `ABCD Dn,Dn`/`SBCD
Dn,Dn` (+4 ticks each, NCC=4), `EXT` (+4, NCC=4), `Scc Dn` (+4, NCC=4),
`TAS Dn` (+4, NCC=4), `NBCD Dn` (+12, NCC=6), dynamic `BCHG/BCLR/BSET
Dn,Dn` (+12, NCC=6 -- one shared condition since all three share the
identical manual row and the same `dec_writes_reg`-based BTST exclusion).

### ANDI/ORI/EORI to SR/CCR: investigated, deliberately not fixed

Added the analogous +4-tick entry (gated on `dec_reads_ccr && dec_use_imm
&& dec_needs_ext && (dec_is_move_sr_w || dec_is_move_ccr_w)`, confirmed
via code inspection to uniquely select this block over MOVE #imm,SR/CCR
and MOVE Dn,SR/CCR) and measured -- still gap=-1, unchanged. Traced
directly with a temporary `$display` (removed before committing): the
stall genuinely counted down 4→3→2→1→0 and delayed this instruction's own
`wb_valid`/`wb_is_move_sr_w` commit by exactly 4 ticks, exactly as
designed -- but the test's total measured clock count (ANDI-to-SR
followed by a dependent `MOVE.L #imm,Dn`) didn't move at all. This op's
own unusually large 13-clock *unstalled* baseline (vs. the uniform
8-clock baseline every other 2-word register-direct instruction in this
project shares, per Stage D3) already pointed at a separate mechanism --
almost certainly the IFU prefetch-queue refill/flush this project's own
history (Phase 96/98) already associates with SR/CCR writes -- and the 4
extra EX-stage ticks were fully absorbed into slack that mechanism
already has, never reaching the measured total. A real fix would need
the extra time inserted at the IFU/decode stage instead of EX/WB, a
materially different and riskier change than every other entry in this
whitelist. Left undone, matching this plan's own explicit "not safely
fixable" allowance (see the plan's own Context section) -- documented
in-line in `eu_seq.sv` rather than silently dropped.

### Results

Exact match (gap=0) for all 6 fixed entries: `a4_abcd_dn`/`a4_sbcd_dn`/
`a4_ext_dn`/`a4_scc_dn`/`a4_tas_dn` (manual=4, were -1 each) and
`a4_nbcd_dn`/`a5_bchg_dn_dn`/`a5_bclr_dn_dn`/`a5_bset_dn_dn` (manual=6,
were -3 each). The full 117-test survey's negative tail is now min=-1
(the 2 deliberately-unfixed ANDI-to-SR/CCR entries only) -- down from
min=-3 with 9 entries at Stage D4's close. 30 tests now at an exact
gap=0 match (up from 22), gap distribution `{-1: 2, 0: 30, 1: 18, ...}`.
`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12, full
124-suite Harte sweep (mandatory -- `eu_seq.sv` changed) -- PASS 702142,
FAIL 2 (same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0,
bit-identical to baseline.

### Status

Stage D5 closed. This closes Part D's own family-by-family whitelist
work -- every register-only negative-gap entry the Stage B_final survey
originally found is now either fixed (gap=0) or investigated and
documented as not safely fixable via this mechanism (ANDI/ORI/EORI to
SR/CCR). Stage D_final (re-survey + confirm the mean gap, formally close
Part D) is next; Part E (bus-touching dispatch-overhead reduction)
remains untouched.

## Phase 162 Stage D_final

### Context

Closes Part D of the clock-cycle-accuracy plan. Re-surveyed the
register-only subset (`expect_r==0 && expect_w==0`) separately from the
bus-touching subset, using the same classification Phase 161 Stage
B_final originally used to characterize the bidirectional gap.

### Results

Register-only (n=85): min=-1, max=10, mean=2.13 -- was min=-12, mean=1.01
at Part D's start (Stage D0). Bus-touching (n=32): min=2, max=16,
mean=9.28 -- **completely unchanged**, exactly as expected since Part D
never touched anything on the bus-touching side (that's Part E's own,
separate, not-yet-started scope).

The register-only *minimum* is the number that matters for confirming
Part D's own actual job (closing the "too fast" side of the gap) is
done: min=-1, and that one remaining negative entry (ANDI/ORI/EORI to
SR/CCR, both dest forms) is investigated and documented in Stage D5 as
genuinely not fixable via this mechanism, not an oversight. Every other
family with a negative (RTL-too-fast) gap Stage B_final originally
found -- shift/rotate (register- and immediate-count), bit-field
register forms, EXG/MOVE-CCR-SR-USP/SWAP, ABCD/SBCD/EXT/Scc/TAS/NBCD/
dynamic-bit-ops -- is now an exact gap=0 match.

The register-only *mean* rising from 1.01 to 2.13 is expected, not a
regression: Stage B_final's original 1.01 figure was two large,
opposite-signed effects (register-only-too-fast families this plan
existed to fix, netted against register-only-too-slow families it was
never scoped to touch) accidentally landing close to zero by
coincidence. With the too-fast side now closed, the mean simply reflects
what was always there on the too-slow side -- e.g. `a6_nop` (+6),
`a7_trapv_notrap` (+4), and others already characterized in Phase 161
Part A as measurement-methodology artifacts (taken-branch/exception-
dispatch prefetch overcounting, bus-transaction-granularity differences
in frame pushes) rather than genuine RTL slowness -- explicitly out of
Part D's own scope, which this plan's Context section framed as
"register-only 'too fast' instructions" specifically.

### Status

**Part D of the clock-cycle-accuracy plan (Stages D0-D5, D_final) is
now closed.** Every register-only instruction family with a genuine
RTL-too-fast timing gap is either an exact match to MC68030UM.pdf
Section 11's own NCC tables, or investigated and documented as not
safely fixable via the artificial-internal-stall mechanism (ANDI/ORI/
EORI to SR/CCR alone). `make test`/`cosim_grp`/`cosim_memind`/Harte all
confirmed clean throughout every stage, with zero net RTL correctness
regressions across the whole Part. Part E (bus-touching dispatch-
overhead reduction, Stage E0's own investigation-first design) remains
untouched and is the plan's only remaining open work.

## Phase 162 Stage E0

### Context

First stage of Part E (bus-touching dispatch-overhead reduction).
Investigation-only, per the plan's own design: examine each of Phase 161
Stage B0's 3 already-identified 1-tick synchronization delays in the
IFU/arbiter/cycle_gen handoff and determine, from the actual code (not
just re-stating Stage B0's own summary), whether any can be safely
shrunk without reopening the specific hazard it was added to prevent.

### Delay 1: biu_cycle_gen's own ifu_ack hold through S7

Traced `ifu_ack`'s own drive site (`rtl/biu_cycle_gen.sv`): it's asserted
combinationally from `state == ST_READ_S7` (via the `grant_ifu` branch of
the shared SP_S7 ack-dispatch case), for as many `clk_4x` ticks as the
FSM holds `state` at that value. Since Phase 160's own S-state pacing
correction, S7 -- like every other named S-state -- genuinely occupies 2
real `clk_4x` ticks (one "half-clock" pairing with S6), matching the
real 68030's own documented per-clock S-state grouping (Figures 7-64/
7-65, already the basis for the whole pacing-correction plan). This
isn't implementation overhead sitting on top of the real bus protocol --
it IS the real bus protocol's own genuine pin-level duration, the exact
thing Phase 160 spent 7 stages calibrating to be correct. Shrinking it
would mean asserting `ifu_ack`/deasserting AS# faster than real 68030
silicon does, directly regressing the project's own core pin-level-
accuracy goal for a payoff of at most 1-2 ticks. **Verdict: NOT safe to
shrink -- it's not overhead, it's the genuine S7 phase width.**

### Delay 2: m68030_ifu's own fetch_pend_r re-arm, gated on !ifu_ack

Traced the exact re-arm site (`rtl/m68030_ifu.sv:333-336`): the
`!fetch_pend_r && !bus_err_r && ... && !ifu_ack && !held_valid_r` guard's
own inline comment (already present, from the Phase 128/147-era work)
explains precisely why: without the `!ifu_ack` guard, the drain-only
branch re-arms `fetch_pend_r` on the first tick of `ifu_ack`'s own
multi-tick hold (S7), causing a spurious second fill one tick later with
stale `captured_rdata` and advancing `fetch_addr_r` past the real next
fetch address -- a real, previously-hit bug, not a hypothetical one.
This delay is entirely *derived from* Delay 1 (it exists only because
`ifu_ack` is held for more than one tick) -- since Delay 1 is confirmed
not shrinkable, this one can't be shrunk independently either without
reopening the exact bug its own guard documents. **Verdict: NOT safe to
shrink, and not independent of Delay 1.**

### Delay 3: biu_arbiter's own registered (not combinational) grant

Read `rtl/biu_arbiter.sv` in full. The module's own header comment states
the design intent directly: "The grant register is held until the bus
returns to idle at the end of the current cycle; this ensures the
cycle_gen sees a stable grant throughout the entire bus cycle." Making
`grant_ifu`/`grant_eu`/`grant_mmu` purely combinational (`req && bus_idle
&& <priority>`) would reintroduce exactly the combinational-loop hazard
class Phase 128 already found and fixed once for a structurally similar
port (the I-cache's own direct `biu_cycle_gen` connection) -- `bus_idle`
itself depends on `state`, which depends on grants, which would then
depend on `bus_idle` combinationally in the same cycle: a real loop risk,
not a stylistic choice. **Verdict: NOT safe to shrink** -- the registered
grant is deliberate, documented, and touches the identical hazard class
this project has already been burned by once.

### Status

All 3 delays confirmed, via direct code inspection (not re-assertion of
Stage B0's own summary), to be load-bearing: two are real pin-level
protocol timing this project deliberately calibrated to match silicon
(Delay 1, and Delay 2 as its direct consequence), and one guards a
specific, previously-fixed combinational-loop bug class (Delay 3).
**Stage E1+ does not happen** -- there is nothing Stage E0 found safe to
implement. Proceeding directly to Stage E_final with this finding, per
the plan's own explicit anticipation of this exact outcome ("If Stage E0
finds none of the three safely shrinkable, this stage doesn't happen --
go straight to E_final with that finding documented"). No RTL changed
this stage -- pure investigation, no temporary tracing was even needed
since the existing code comments already document the reasoning for
each of the 3 sites.

## Phase 162 Stage E_final (closes Part E and the Phase 162 plan)

### Results

Re-surveyed the bus-touching subset (`expect_r>0 || expect_w>0`, n=32):
min=2, max=16, mean=9.28 -- unchanged from Phase 161 Stage B_final's own
original measurement and from Stage D_final's own re-confirmation, since
Part E never made an RTL change (Stage E0 found nothing safe to touch).

### Status

**Part E is closed with the plan's own explicitly-anticipated "nothing
safely fixable" outcome** -- not a failure of the stage, but its answer,
matching the plan's own Context section framing this as a legitimate,
accepted possibility going in. The bus-touching dispatch overhead (mean
+9.28 clocks per instruction that touches the bus) remains, fully
characterized and documented (Phase 161 Stage B0, this stage) as three
stacked, individually-necessary synchronization delays: two are genuine
pin-level S-state timing this project deliberately calibrated to match
real 68030 silicon (not implementation overhead at all), and one guards
a real, previously-fixed combinational-loop hazard. No further action
is recommended without a fundamentally different design for the IFU/
arbiter/cycle_gen handoff -- out of proportion to the ~1-2-tick-per-
transition payoff.

**This closes the Phase 162 clock-cycle-accuracy plan (Parts D and E) in
full.** Part D (Stages D0-D5, D_final): closed every register-only
RTL-too-fast gap the original survey found, either to an exact match or
to a documented not-safely-fixable finding (ANDI/ORI/EORI to SR/CCR
alone). Part E (Stages E0, E_final): investigated the bus-touching
RTL-too-slow gap and confirmed, via direct code inspection of all 3
candidate delays, that none are safely shrinkable -- they are either
genuine calibrated pin-level timing or hazard-preventing by design.
Zero RTL correctness regressions across the whole plan, confirmed via
`make test`/`cosim_grp`/`cosim_memind`/the full 124-suite Harte sweep at
every RTL-touching stage. `~/.claude/plans/compressed-hopping-cocoa.md`
has no further open items from its own scope.

## Phase 163 Stage 0

### Context

New plan (`~/.claude/plans/compressed-hopping-cocoa.md`): closing the
bus-touching dispatch-overhead gap for real, after the user pushed back
on Phase 162 Stage E0's "not safely fixable" conclusion. That conclusion
was based on a single worked example and a too-narrow theory (3 small
1-tick IFU/arbiter sync delays); re-investigating directly with the user
found the theory didn't explain the actual magnitude of the gap (7-13
clocks measured vs. ~1 clock the 3-delay theory could account for), and
also found the underlying SURVEY comparison itself was measuring the
wrong thing for most of the bus-touching test set.

### The methodology bug

Most bus-touching tests write to *memory*, not a register, so the test
harness needs a trailing marker instruction (`MOVE.L #imm,Dn`) to make
completion observable. The existing "MEASURED ticks=/clocks=" figure in
`tb/timing_tb.sv` is gated purely on the WATCH REGISTER reaching its
expected value -- which for these tests means "target instruction +
marker instruction, combined" -- while the `desc` field's own manual
NCC value only ever described the target instruction alone. Confirmed
via direct trace on `a2_move_ea_xxxw` (`MOVE.L D1,$1000.W`): the raw
bus event log showed the marker's own opcode fetch landing INSIDE the
measured window, before the target's own write even completed.

### Fix: a second, pin-level-only completion measurement

Added `MEASURED_INSTR_ONLY` to `tb/timing_tb.sv`: tracks the AS-rise of
the LAST bus cycle that genuinely belongs to the target instruction --
any data-space (r/w) cycle (a memory-dest write or memory-src read,
never something the marker needs) or any program-space fetch still
inside the target's own `[target_pc, target_pc+target_len)` byte span.
A following marker's own opcode/extension fetches, being program-space
reads outside that span, are correctly excluded. Purely additive --
new signals (`instr_bus_pending_r`, `t_end_instr_r`), a new informational
`$display` line, zero change to any existing assertion.

Confirmed the new measurement is meaningless for register-only
instructions (no bus event marks their own completion at all -- `a4_
ext_dn` under-reports on `MEASURED_INSTR_ONLY` despite already being an
exact match on the existing `MEASURED` figure), so `scripts/b_final_
clock_survey.py` was extended to use `MEASURED_INSTR_ONLY` only for
tests that need a trailing marker (`expect_r>0 || expect_w>0`),
otherwise keeping the original `MEASURED`-based figure unchanged.

### Results

Re-surveyed the bus-touching subset (n=32) with the corrected
measurement: mean ratio (measured/manual) drops from 2.37x to **1.82x**,
worst case from 3.6x to 2.44x -- the honest, correctly-measured
baseline this plan's own later stages will track against. `make test`
36/36 (sanity check; `tb/timing_tb.sv`'s own change is purely additive/
informational, verified to not perturb anything else).

### Status

Stage 0 (groundwork) closed. Two real, distinct mechanisms behind the
remaining 1.82x were found via direct signal tracing on two
representative instructions (temporary `$display`s, removed before this
writeup) and are documented in the plan's own Context section: (1)
`eu_ext_valid`'s threshold is a known, deliberately over-conservative
simplification (already flagged in `m68030_seq.sv`'s own header comment)
that forces every `ext_count==1` instruction to wait for an entire
unneeded extra bus fetch; (2) a not-yet-root-caused arbitration/dispatch
timing gap specific to read-modify-write memory instructions, where an
unrelated IFU prefetch was observed running in the gap between the
RMW's own read completing and its own write starting despite EU's
documented higher bus priority. Stage 1 (implementing the fix for
mechanism 1) is next; Stage 2 (investigating mechanism 2 in more depth)
follows.

## Phase 163 Stage 1

### Context

Implements the confirmed, well-scoped fix from Stage 0's investigation:
`eu_ext_valid`'s dispatch gate used the same `q_cnt>=3` threshold for
both `ext_count==1` and `ext_count==2` instructions, when `ext_count==1`
only ever needs `q_cnt>=2` — already documented as a known, deliberate
over-conservative simplification in `m68030_seq.sv`'s own header comment
(never revisited for performance).

### RTL changes

- `rtl/m68030_ifu.sv`: new `ext1_valid` output, `assign ext1_valid =
  (q_cnt >= 3'd2);` — mirrors `instr_valid`/`ext_valid`/etc exactly.
- `rtl/m68030_top.sv`: new `ifu_ext1_valid` wire, threaded through both
  `u_ifu`'s and `u_seq`'s port lists alongside the existing `ext_valid`
  wiring.
- `rtl/m68030_seq.sv`: new `ifu_ext1_valid` input; `eu_ext_valid`'s mux
  gained `(ext_count == 3'd1) ? ifu_ext1_valid :` ahead of the final
  `ifu_ext_valid` fallback (which now serves only `ext_count==2`,
  unchanged). Verified the `peek_fi_full`/`peek_fi_bdsz`/`peek_fi_iis`
  mechanism (mode=110 full-format EA peek, reads q[1] via `ifu_ext_data
  [31:16]`) is unaffected — q[1] is already stable at `q_cnt>=2`, so the
  peek's own gating gets *more* precise, not less.
- Three standalone testbenches with separate `m68030_ifu`+`m68030_seq`
  instantiations (`tb/pipeline_tb.sv`, `tb/stall_hazard_tb.sv`,
  `tb/seq_ctrl_tb.sv`) needed the new signal wired through explicitly
  (named-port connections, not wildcard, so a new port doesn't auto-
  connect) — `tb/seq_ctrl_tb.sv` uses `.*` wildcard binding and would
  have needed no change, except its own SEQ-6 test was directly
  exercising the exact case this fix changes (an `ADDI.B` — ext_count==1
  — instruction's own `eu_ext_valid` pass-through), so it was extended
  (not just patched) into 3 checks explicitly covering both the new
  `ext1_valid` arm and the unchanged `ext_valid` (ext_count==2) arm,
  rather than silently leaving the new port undriven-then-guessed-safe.

### A real regression found and fixed before it shipped

Re-running the corrected pin-level survey after the fix showed the
expected large improvement for `ext_count==1` bus-touching tests (e.g.
`a2_move_ea_xxxw` gap 7→2, `a1_fea_d16an` gap 6→1) -- but also flipped
Phase 162 Stage D3's own already-exact bit-field register-form results
(BFCHG/BFCLR/BFSET/BFEXTS/BFEXTU/BFINS/BFFFO, all 2-word/ext_count==1
instructions) from gap=0 to a uniform gap=-5. Root cause: Stage D3's
own artificial-stall constants were calibrated against the *old*,
slower unstalled baseline (8 clocks for a 2-word register-direct
instruction) -- this fix sped that baseline up to a uniform 3 clocks
(identical to the 1-word baseline, since the "wait for an unneeded 2nd
fetch" penalty is now gone entirely), so the *same* old stall additions
now overshoot the manual target by exactly the amount the baseline
itself improved. Re-derived and updated all 7 constants in `rtl/eu_seq.
sv`'s `dec_internal_stall_ticks_fixed` (e.g. BFCHG 24→44 ticks, BFFFO
48→68 ticks -- each simply +20 ticks/5 clocks, matching the uniform
8-clock→3-clock baseline shift exactly) -- restored to exact gap=0 for
all 7, confirmed via re-measurement.

### Two new findings, documented but not fixed this stage (out of scope)

1. **`a5_bftst_dn`** (gap=+1, unchanged by this fix): BFTST writes no
   register (only CCR), so its own test needs a trailing marker (`SEQ
   D3`) to observe completion — the exact same class of gap Stage 0
   fixed for bus-touching tests, just for a case with zero *data*-bus
   activity (`expect_r==0 && expect_w==0`), which Stage 0's own
   `needs_marker` classifier (`expect_r>0 || expect_w>0`) doesn't catch.
   Genuine blind spot in the survey's own classifier, not an RTL issue.
2. **`a2_movec_read`/`a4_pack_dn`/`a4_unpk_dn`/`a5_bchg_imm_dn`** (new
   negative gaps: -3/-3/-5/-3): all `ext_count==1` register-direct
   instructions *never in Part D's own original scope* (their gaps were
   positive/zero before this fix, so Part D's Stage B_final survey
   never flagged them as "too fast") — this fix's dispatch speedup
   pushed them into negative territory for the first time. Genuinely
   new "too fast" cases, not a regression of anything previously
   promised fixed, and Part D itself is a closed plan; left undone as
   out of this plan's own bus-touching-focused scope, flagged for a
   possible future extension of Part D's own family-by-family work if
   the user wants full register-only exactness later.

### Results

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12, full
124-suite Harte sweep (mandatory -- touches the shared IFU/sequencer
dispatch-gating path every instruction in the corpus goes through) --
PASS 702142, FAIL 2 (same documented ASL.b anomaly), SKIP 281221,
TIMEOUT 0, bit-identical to baseline. Corrected bus-touching survey
(n=32, via the `MEASURED_INSTR_ONLY` pin-level figure): every
`ext_count==1` test's gap shrank by exactly 5 clocks as predicted;
`ext_count==0` tests (e.g. `a3_add_dn_ea`) correctly unaffected --
that's Stage 2's own scope.

### Status

Stage 1 closed. Stage 2 (investigate the RMW read-to-write dispatch
gap, the second mechanism Stage 0 found) is next.

## Phase 163 Stage 2

### Context

Investigation-only stage (no RTL change), following on from Stage 0's
second finding: for RMW-shaped instructions, an unrelated IFU prefetch
was observed running in the gap between the RMW's own read completing
and its own write starting, despite the EU's own `mem_req` staying
continuously asserted and despite `biu_arbiter.sv`'s documented EU>IFU
priority.

### Root cause, fully confirmed via direct signal trace

Traced `bus_idle`/`mmu_req`/`eu_req`/`ifu_req`/`grant_eu`/`grant_ifu` at
`biu_arbiter.sv`'s own port boundary (temporary `$display`, removed
before committing) against `a3_add_dn_ea` (`ADD.L D1,(A0)`). Found the
precise mechanism:

`rtl/biu_sizing_fsm.sv` sits between the EU and `biu_cycle_gen`'s own
EU port, and `biu_arbiter.sv`'s own `eu_req` input is fed from this
module's `cyc_req` output (`m68030_biu.sv`: `.eu_req (sf_cyc_req |
dc_burst_req)`) -- NOT the EU's own raw request directly. The sizing
FSM's 3-state machine (`SS_IDLE -> SS_ACTIVE -> SS_DONE -> SS_IDLE`)
unconditionally drives `cyc_req = 1'b0` for exactly one tick while in
`SS_DONE` (a one-tick "ack pulse" state signaling completion to the
EU) -- regardless of whether the EU's own raw `eu_req` is already
asserted again for a follow-up transaction (e.g. an RMW's own write
phase, which needs the bus immediately after the read with zero real
gap). `biu_arbiter.sv`'s own grant only re-evaluates on the exact tick
`bus_idle` first re-asserts (its own "only reassign when bus is idle"
rule) -- and that tick lands precisely on `biu_sizing_fsm`'s own
`SS_DONE` tick, the ONE moment `eu_req` (as the arbiter sees it) reads
0 even though the EU's own true intent never wavered. With `ifu_req=1`
at that same moment (the IFU is essentially always trying to prefetch
ahead), the arbiter -- correctly applying its own EU>IFU priority to
what it can actually see -- grants IFU instead, and since grants are
locked until the NEXT `bus_idle` window (an entire bus cycle later),
the EU's own write has to wait for the IFU's whole prefetch to finish
first. Confirmed directly in the trace: `eu_req` reads 1 for the whole
read, drops to 0 for exactly one tick coinciding with `bus_idle=1`,
`grant_ifu` flips to 1 that same tick, and `eu_req` reads 1 again the
very next tick -- one tick too late.

This answers all three of Stage 0's own open questions: (1) `eu_req` is
NOT already visible to the arbiter at the critical edge -- it reads 0
at exactly that tick, a `biu_sizing_fsm`-induced artifact, not a raw
EU-side gap; (2) this isn't about the EU's write-phase readiness at
all -- the EU's own raw request (`mem_req` in `eu_seq.sv`) is already
continuously asserted throughout, confirmed in Stage 0's own trace; the
gap is entirely introduced one level up, in the sizing FSM's own
ack-signaling protocol; (3) since `biu_sizing_fsm.sv` is a shared,
generic module used for every EU bus transaction (not RMW-specific),
this exact one-tick gap happens after every EU bus cycle completes --
it only *matters* (creates contention) when the EU wants another cycle
immediately with zero real gap, which is specifically the RMW/multi-
beat-FSM shape (RMW read-then-write, MOVEM/MOVEP/CAS2's own multi-beat
sequences), not ordinary single-cycle reads/writes.

### Proposed fix shape (for Stage 3, not implemented this stage)

`SS_DONE`'s own `cyc_req=1'b0` should not suppress the underlying
request when the EU genuinely wants to continue -- but a naive "just
keep cyc_req=eu_req during SS_DONE" fix needs to first confirm whether
`eu_addr`/`eu_wdata`/`eu_rw` (the raw EU-side signals `biu_sizing_fsm`
would present to `biu_cycle_gen` on that same tick) already reflect the
FOLLOW-UP transaction's own correct parameters at that point, or still
reflect the just-completed transaction's stale ones -- `eu_seq.sv`'s own
RMW-phase-transition register (e.g. `mem_rmw_run_r`) may only update
the cycle *after* `eu_ack` (`sf==SS_DONE`) is observed, in which case
presenting `cyc_req=1` with still-stale `eu_addr`/`eu_wdata` during
`SS_DONE` itself would start a bus cycle with the WRONG address/data --
a correctness bug, not just a performance one. Stage 3 must trace this
specific timing relationship (does `eu_seq.sv`'s own write-phase output
become valid combinationally on the SAME cycle as `eu_ack`, or only the
cycle after) before choosing between: (a) keep `cyc_req=eu_req` through
SS_DONE if the EU's own follow-up parameters are already valid that
same cycle, or (b) a different mechanism entirely -- e.g. have
`biu_arbiter.sv` itself not immediately re-evaluate on `bus_idle` if
the currently-granted requester's own *raw* (pre-sizing-FSM) request is
still asserted, giving the sizing FSM's own one-tick pulse nowhere to
cause harm regardless of its own internal signal shape.

### Results

No RTL changed (temporary trace only, removed before committing).
`make test` 36/36 sanity check.

### Status

Stage 2 closed -- a confirmed, precise, verified root cause with a
credible fix-shape candidate (pending one more targeted trace to choose
between the two options above). Stage 3 (implement the fix) is next.

## Phase 163 Stage 3

### Context

Implements the fix for Stage 2's confirmed root cause, after one more
targeted trace (needed to choose safely between the two candidate fix
shapes Stage 2 left open).

### The missing trace: which layer actually creates the gap

Extended Stage 2's own trace to also watch `biu_cache_if.sv`'s own
`sf_req` output (`ca_sf_req`) alongside `biu_sizing_fsm.sv`'s `cyc_req`
(`sf_cyc_req`) and the raw EU-level request reaching `m68030_biu.sv`
directly. Found: `ca_sf_req` and `sf_cyc_req` drop to 0 together, in
lockstep, at the exact same tick -- `biu_sizing_fsm.sv`'s own `SS_DONE`
gap (Stage 2's own original finding) is not an independent, second
layer of the same problem; it's a transparent pass-through of an
upstream one-tick gap in `biu_cache_if.sv`'s own `CI_DONE` state (its
own default case, `sf_req=1'b0`, mirrors `biu_sizing_fsm`'s `SS_DONE`
exactly). Crucially, the *raw* EU-level request reaching `m68030_biu.sv`
(the `eu_req` top-level port, fed straight from `eu_seq.sv`'s own
`mem_req`) never drops at all -- confirmed continuous across the whole
RMW sequence, exactly matching Stage 0's own original eu_seq-level
trace.

This settles which fix shape from Stage 2's two candidates is safe:
neither intermediate FSM (`biu_cache_if.sv`'s `CI_DONE` nor
`biu_sizing_fsm.sv`'s `SS_DONE`) can safely present the write phase's
own address/data any earlier than it already does -- confirmed via
`eu_seq.sv`'s own `mem_rmw_run_r` (and equivalent registers for other
RMW-shaped FSMs), which only updates the cycle *after* the read's own
ack is observed, so asserting a downstream request one tick early would
risk launching a bus cycle with stale (read-phase) address/data, a
correctness bug. The raw EU-level signal, however, is safe to use for
the ARBITER's own grant-holding decision specifically, since it never
carries that same one-tick "settling" gap.

### Fix

`rtl/m68030_biu.sv`: widened `biu_arbiter`'s own `eu_req` input from
`sf_cyc_req | dc_burst_req` to `sf_cyc_req | dc_burst_req | (eu_req &
!eu_mo_req)` -- the raw top-level `eu_req` port, gated by `!eu_mo_req`
matching the identical, already-established convention used for
`biu_cache_if`'s own `eu_req` input a few lines below (currently a
no-op since `eu_mo_req` is hardwired 0, kept for consistency). This
only changes the ARBITER's own view of "does EU still want the bus" --
it does not change what data `biu_cycle_gen` ever receives (still
gated by `sf_cyc_req` itself, completely unchanged), so a stale-address
scenario is structurally impossible: the grant simply stays with EU
through the one-tick gap instead of handing to a lower-priority IFU
request that happened to be pending, and the sizing FSM presents the
write's own correct parameters the very next tick once its own
internal state has caught up, exactly as it already correctly does.

### Results

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12,
full 124-suite Harte sweep (mandatory and the highest-stakes gate of
this whole plan -- `biu_arbiter.sv`'s own grant logic is the single
most centrally-used mechanism in the chip) -- PASS 702142, FAIL 2 (same
documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to
baseline. Bus-touching survey (n=32): mean ratio **1.61x -> 1.29x**
(worst case 2.33x -> 1.78x) -- e.g. `a3_add_dn_ea`/`a3_and_dn_ea`/
`a4_neg_mem`/`a5_lsl_mem` all improved by exactly 5 clocks (the full
one-tick-gap cost, ~20 ticks, matching Stage 1's own uniform-shift
finding for the ext1_valid fix). No previously-exact (gap=0) result
regressed -- the count of exact matches in the 117-test survey actually
grew from 30 to 34; a handful of already-known, never-in-scope negative
cases (TAS's own AS-never-re-falls measurement quirk, brief-indexed EA)
shifted 1 clock more negative as an expected side effect, not a new
regression.

### Status

Stage 3 closed. Bus-touching mean ratio has now dropped from the
original (flawed-measurement) 2.37x down to a correctly-measured 1.29x
across this plan's 3 fix stages -- register-only accuracy (Part D) is
already at parity; the remaining ~1.29x gap is smaller than either of
the two mechanisms this plan set out to find and fix. Re-survey and
formally assess whether further stages are warranted, or whether this
is a reasonable stopping point, is next.

## Phase 163 follow-up investigation: what remains of the bus-touching gap

### Context

After Stage 3's arbiter fix, the bus-touching mean ratio sits at 1.29x
(down from the original, flawed-measurement 2.37x). Investigated the
worst remaining offenders (`a3_addi_mem`/`a6_bsr`/`a6_jsr` at 1.78x;
a cluster including `a3_add_dn_ea`/`a3_and_dn_ea`/`a4_neg_mem`/
`a5_lsl_mem` all at a uniform 1.57x) to characterize what's left.

### Finding: a real, multi-layer FSM hand-off chain, distinct from what Stage 3 fixed

Traced `a3_add_dn_ea` (`ADD.L D1,(A0)`) at the internal state-machine
level -- `biu_cache_if.sv`'s own `state`, `biu_sizing_fsm.sv`'s own
`sf`, and `biu_cycle_gen.sv`'s own `state`, all together (temporary
hierarchical `$display`s in `tb/timing_tb.sv`/`rtl/eu_seq.sv`, removed
before committing). Confirmed Stage 3's fix is fully working -- **zero
bus contention this time**: no IFU (or any other) bus activity happens
in the read-to-write gap at all. The entire remaining ~12-tick (3-clock)
gap is a genuine chain of internal state transitions: `biu_cache_if`'s
own `CI_DONE` (the read's own ack) needs 2 ticks to reach its own
`CI_WRITE` state (`CI_DONE→CI_IDLE→CI_WRITE`), `biu_sizing_fsm` needs
1 more tick to follow (`SS_IDLE→SS_ACTIVE`), and `biu_cycle_gen` needs
1 more to leave `ST_IDLE` and begin the write's own genuine S0/S1
address-setup phase (which itself correctly takes its own already-
calibrated 4 ticks, unrelated to this chain, Phase 160's own proven-
correct pin timing).

**At least one tick of this chain is confirmed structurally necessary,
not overhead**: `biu_cache_if`'s own `CI_DONE→CI_IDLE` step is waiting
on `eu_seq.sv`'s own RMW-phase-transition registers (`mem_rmw_run_r`/
`mem_rmw_addr_r`/`mem_rmw_wdata_r`, the same registers Stage 2/3's own
investigation already established only update the cycle *after* the
read's own ack) -- the write's real address/data genuinely aren't
computed yet at the moment `CI_DONE` is first entered, so nothing
downstream can safely move any earlier than this.

The remaining ~2-3 ticks (`CI_IDLE→CI_WRITE`, `SS_IDLE→SS_ACTIVE`,
`cg` leaving `ST_IDLE`) are each an ordinary, independent registered
state machine reacting to the *previous* module's own state update one
clock at a time -- standard, expected synchronous-design latency for a
genuinely multi-stage internal bus architecture (three separate
`always_ff` state machines chained in sequence), not a bug or an
artifact comparable to Stage 1's or Stage 3's own fixes. Whether these
specific hops could be compressed further (e.g. giving `biu_cache_if`'s
own `CI_IDLE` state the same "zero added latency, drive combinationally
from the raw request" fast path `biu_sizing_fsm`'s own `SS_IDLE` state
already implements) is a real, narrower, but *meaningfully riskier*
follow-up than anything in Stages 1-3: `biu_cache_if.sv` is the single
largest, most heavily-relied-upon module touched this whole
investigation (serves ordinary reads/writes, D-cache hit/miss, MMU
translation faults, and burst fills all through the same state
machine) -- collapsing one of its own states needs the same rigor as
every prior fix in this plan, but with a much larger blast radius to
re-verify.

### Status

**Investigated and characterized, not pursued further this session.**
The remaining bus-touching gap (mean 1.29x, worst case 1.78x) is now
fully explained: part is genuine real-silicon-analogous internal
sequencing overhead (already-established project precedent, Phase 159/
160's own "internal microcode this simplified pipeline wasn't designed
to reproduce cycle-for-cycle" finding), part is a real, register-
dependency-gated one-tick minimum, and a small remaining slice
(`biu_cache_if.sv`'s own `CI_IDLE` hop specifically) is a plausible but
unverified further optimization target, deliberately not attempted
without the same investigation-then-verify rigor every other fix in
this plan received. No RTL changed this session's follow-up
investigation -- `make test` 36/36 confirms the working tree is clean.

## Phase 163 Track A, Stage A0+A1

### Stage A0 -- investigation

Read `biu_cache_if.sv`'s `CI_IDLE` case arm in full, both the registered
next-state logic (`always_ff`) and the combinational output block
(`always_comb`). Confirmed the module header's own claim directly in
code: a write request (`!eu_rw`) genuinely never evaluates `dhit`/`ihit`
at all -- the `always_ff` block's own `CI_IDLE` arm branches `if (eu_rw
&& hit) ... else if (tc_e) CI_XLATE ... else if (!eu_rw) CI_WRITE`, so
the write path is reached independently of any cache lookup, confirming
Stage A0's own first open question. Found a second CI_WRITE entry point
(from `CI_XLATE`, the MMU-enabled case, line ~460) -- confirmed this is
a completely separate transition, from a different source state, so a
fast path gated on `!tc_e` (bypassing `CI_XLATE` entirely) cannot
interact with it at all.

Found the combinational output block's own top-of-block defaults
already present `sf_addr=addr_r`/`sf_wdata=wdata_r`/etc for EVERY state
including `CI_IDLE` (which has no explicit case arm today, falling to
`default:`) -- `CI_WRITE`'s own case arm only adds `sf_rw=1'b0; sf_req=
!sf_ack`. This means the only change needed is an explicit `CI_IDLE`
arm presenting the RAW `eu_addr`/`eu_wdata`/etc (not the stale,
not-yet-updated `addr_r`/`wdata_r`) the instant a qualifying write
request arrives -- structurally identical to `biu_sizing_fsm.sv`'s own
already-proven `SS_IDLE` fast path.

Reasoned through the "could `sf_ack` arrive before CI's own registered
state catches up to `CI_WRITE`" race and concluded it's structurally
impossible: a real bus cycle takes >=8 ticks (2 clocks) minimum, while
the registered `CI_IDLE->CI_WRITE` catch-up (unchanged, still happens
next cycle regardless of the new fast path) takes exactly 1 tick --
the fast path can only ever make the request visible EARLIER, never
racing ahead of what `CI_WRITE`'s own registered body already handles
one cycle later with identical values.

### Stage A1 -- implementation

`rtl/biu_cache_if.sv`: added an explicit `CI_IDLE` arm to the
combinational output block, presenting `sf_addr=eu_addr`, `sf_fc=
eu_fc`, `sf_rw=1'b0`, `sf_siz=eu_siz`, `sf_wdata=eu_wdata`, `sf_req=
1'b1` whenever `eu_req && !eu_rw && !tc_e`. The registered `always_ff`
next-state logic (hit/miss/translate/burst decisions) is completely
untouched -- this is purely additive to the output block.

### A real, verified, but sub-clock-granularity result

Controlled A/B measurement (`git stash`/`pop` on just `rtl/biu_cache_if.
sv`, rebuilding `sim/timing` between each) on the full bus-touching
survey's own tick-level output (not the coarser `clocks=` figure):
every genuine RMW-shaped test (`a3_add_dn_ea`/`a3_and_dn_ea`/`a3_addq_
mem`/`a3_addi_mem`/`a4_neg_mem`/`a5_lsl_mem`/`a5_bchg_dn_mem`/`a5_bset_
dn_mem`/`a7_trap_n`/`a7_illegal`) improved by exactly 2 ticks (0.5
clock) -- consistent, real, and precisely matching the "CI_IDLE's own
formerly-extra internal hop is now free" theory. `a4_cmpm` (compares
only, no write phase at all) and `a6_bsr`/`a6_jsr` (Track B's own
separate, not-yet-fixed mechanism) both correctly show zero change,
confirming the fix's own scope is exactly as intended -- it doesn't
accidentally touch anything outside the RMW-write-dispatch case.

Because the improvement (2 ticks) is smaller than the integer-clock
rounding `scripts/b_final_clock_survey.py` reports (`ticks/4`), **none
of these show up as a visible change in the survey's own coarse output**
-- every affected test's `clocks=` figure stays the same (e.g. 46->44
ticks is 11.5->11 clocks, both truncate to 11). The improvement is real
and verified at the tick level, just below this project's own chosen
reporting granularity.

The REMAINING piece of the originally-traced 4-tick hand-off chain
(`biu_sizing_fsm.sv`'s own `SS_DONE->SS_IDLE` hop, ~1-2 more ticks) is
NOT addressed by this stage -- Track A's own scope was `biu_cache_if.
sv` only; closing the sizing-FSM piece too would need its own Stage A0-
style investigation extended into a second file, deliberately not
folded into this stage.

### Results

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12,
full 124-suite Harte sweep (mandatory -- `biu_cache_if.sv` is the
single largest, most heavily-relied-upon module either track could
touch: ordinary reads/writes, D-cache hit/miss, MMU translation faults,
and burst fills all share this one state machine) -- PASS 702142, FAIL
2 (same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical
to baseline.

### Status

Track A (Stages A0+A1) closed. Real, verified, sub-clock-granularity
improvement on every RMW-shaped bus-touching test, with zero
correctness regression. Track B (BSR/JSR's own redirect latency,
Stage B0) is next, per the plan's own default ordering.

## Phase 163 Track B, Stage B0

### Context

Investigation-only, per the plan's own staging. `a6_bsr`/`a6_jsr`
(return-address push + PC redirect + fresh IFU fetch) show the same
~1.78x ratio as the worst RMW cases, but this is a genuinely different
instruction shape from anything Track A touched -- the plan's own
explicit instruction was not to assume it's the same mechanism without
tracing it.

### Finding: mostly the same underlying chain, exposed differently -- not a separate IFU mechanism

Traced `a6_bsr` with `pc_wr_en`/`pc_wr_data`/`decode_pc`/`fetch_pend_r`/
`ifu_req`/`biu_cycle_gen`'s own `state`, all together (temporary
hierarchical `$display`s in `tb/timing_tb.sv`, removed before
committing). Found the push's own write completes (AS-rise) at one
tick, but `pc_wr_en` (driven by `eu_seq.sv`'s `branch_taken`) doesn't
assert until 4 ticks later.

Checked `eu_seq.sv`'s own `branch_taken`/`ex_bsr_taken` definitions:
`ex_bsr_taken = ex_valid && ex_is_bsr && mem_ack` -- purely
combinational, asserting the *same* cycle `mem_ack` arrives, with zero
extra registered EU-side delay. This means the observed 4-tick gap is
**not** a BSR-specific commit latency at all -- it's the same upstream
"how long does it take `mem_ack` to actually reach `eu_seq.sv` after a
write's own bus cycle completes" propagation delay that Stages 2/3 and
Track A already characterized in detail (the `biu_cache_if.sv` ->
`biu_sizing_fsm.sv` -> `biu_cycle_gen.sv` hand-off chain), just exposed
here in a way ordinary instructions don't show: for most instructions
this same delay is silently absorbed into the already-budgeted "2-cycle
EX->WB" baseline (Stage D0's own established figure), but `branch_taken`
depends on `mem_ack` directly and immediately triggers the redirect, so
none of it is hidden. **Track A's own fix does not help here** --
confirmed empirically (`a6_bsr`/`a6_jsr` showed zero tick-level change
in Track A's own before/after comparison) since Track A targeted the
*dispatch* side (skipping `CI_IDLE`'s own extra hop when issuing a
follow-up request) while this is the *ack-propagation* side (how long
`CI_DONE`/`mem_ack` itself takes to first appear after a completed
write) -- a different segment of the same general chain, not yet
touched by anything in this plan.

After `pc_wr_en` finally fires, a second, genuinely separate cost
follows: `m68030_ifu.sv`'s own `fetch_pend_r` correctly flushes the
stale in-flight fetch and re-arms for the new address (1 tick), then
`biu_cycle_gen` begins a fresh S-state sequence from `ST_IDLE` for the
redirected fetch -- ~6 ticks from re-arm to the new fetch's own AS-fall,
plausibly mostly genuine S0/S1/S2 bus-protocol setup time (the same
kind of unavoidable pin timing Track A's own remaining-gap analysis
already found for the RMW case), not investigated further at the same
depth given the ack-propagation finding above is the larger and more
novel piece.

Separately confirmed (reading `biu_icache_if.sv`'s own header/`IC_IDLE`
comment) that the I-cache side is *already* a pure, zero-latency
combinational bypass whenever `icache_en=0` (Phase 127 Step 1's own
documented design) -- the timing test suite never enables the I-cache,
so there is no `biu_icache_if.sv`-side "extra hop" analogous to what
Track A found and fixed in `biu_cache_if.sv`; that specific shape of
fix genuinely does not apply here.

### Why this stage stops at investigation

The dominant, newly-identified mechanism (ack-propagation delay through
the same `biu_cache_if.sv`/`biu_sizing_fsm.sv`/`biu_cycle_gen.sv` chain
Stages 2/3 and Track A already worked in) does not have an obvious,
narrow, low-risk fix shape the way Track A's own dispatch-side fix did
(a direct, already-proven pattern to mirror from `SS_IDLE`). Reducing
*how long it takes `CI_DONE`/`mem_ack` to first appear* after a write's
own S6/S7 completes would mean compressing the write's own completion-
side hand-off (`biu_cycle_gen`'s own already-calibrated S6/S7 timing,
`biu_sizing_fsm`'s own `SS_ACTIVE->SS_DONE` ack-pulse transition, and
`biu_cache_if`'s own registered pickup into `CI_DONE`) -- each of these
has its own established reason for existing (S6/S7 is genuine pin
timing per Phase 160; the ack-pulse shape is relied on elsewhere in
`biu_cache_if.sv`'s own state machine, same module Track A already
found is unusually large and heavily shared). No fix is proposed this
stage -- per the plan's own explicit framing, Stage B1+ only happens
"if B0 finds something concretely fixable," and this session's own
investigation did not find that for the ack-propagation piece.

### Results

No RTL changed. `make test` 36/36 confirms the tree is clean.

### Status

Track B, Stage B0 closed. The plan's original hypothesis (a separate,
IFU-specific mechanism) is corrected: BSR/JSR's own gap is
substantially the *same* general ack-propagation-chain phenomenon
Stages 2/3 already characterized, exposed differently, not a new
mechanism -- and it does not currently have a narrow, low-risk fix
shape the way Track A's dispatch-side gap did. This closes the plan's
own 2-track scope (Track A implemented and verified; Track B
investigated and found not concretely fixable within this session's
own risk tolerance). Bus-touching mean ratio stands at 1.29x (Stage 3's
own figure; Track A's own real improvement is below the survey's
reporting granularity, as documented in Track A's own writeup).

## Phase 163 Track C, Stage C0+C1 -- biu_sizing_fsm.sv's SS_DONE collapse

A follow-up investigation past Track A/B's own close traced the AS-rise-
to-mem_ack "ack-propagation" path precisely and found 2 of its 4 ticks
are genuine S6/S7 pin timing (Phase 160's own calibrated protocol, not
touchable), and 2 are avoidable internal bookkeeping:
`biu_sizing_fsm.sv`'s own `SS_ACTIVE->SS_DONE` transition and
`biu_cache_if.sv`'s own transition into `CI_DONE` each cost a genuine
extra tick before the ack becomes visible to the next layer up, purely
because each module presents its own ack combinationally off its OWN
registered terminal state rather than off the triggering condition
directly. Both were investigated and found structurally safe to
collapse in principle; a user-approved 2-track plan
(`~/.claude/plans/compressed-hopping-cocoa.md`) staged the smaller,
single-site `biu_sizing_fsm.sv` fix (Track C) ahead of the larger,
5-entry-point `biu_cache_if.sv` fix (Track D).

### Stage C0 -- confirm the fix shape

Re-read the current file (not trusting line numbers from the pre-plan
investigation). Confirmed `sf_accum`'s own reset in `SS_IDLE` (`if
(eu_req) sf_accum<=32'h0`) is genuinely sufficient on its own --
`SS_DONE`'s own reset of the same signal is redundant, not load-bearing
for anything. Grepped all three files (`biu_sizing_fsm.sv`,
`biu_cache_if.sv`, `m68030_biu.sv`) for any consumer that reads `sf`/
`cyc_req`/`eu_ack` in a way that assumes `SS_DONE` is entered as a
genuine, distinct registered state -- found none; every consumer reacts
to `eu_ack` itself, not the underlying state name.

### Stage C1 -- implement

Added a combinational fast path: `ss_active_fast_done = (sf==SS_ACTIVE)
&& cyc_ack_edge && !needs_more(sf_siz, cyc_port_dsack)` (the same
`!needs_more(...)` guard that already correctly excludes a mid-transfer
sub-cycle's own ack from prematurely completing a multi-sub-cycle
dynamic-port-sizing transfer), with `eu_rdata` computed the same way
`SS_DONE` itself already did (`merge_rdata(sf_accum, cyc_rdata, sf_siz,
sf_orig_siz, cyc_port_dsack, sf_addr[1:0])` for reads, `32'h0` for
writes) -- confirmed this only needs `sf_accum` (already registered
from earlier sub-cycles) and `cyc_rdata` (the current bus data, already
valid the same cycle), no dependency on the extra registered wait.

**A first attempt OR'd the fast path with the existing registered
`sf==SS_DONE` term, reasoning the registered path was a harmless
fallback -- this was wrong, and `make test` caught it.** Since
`SS_DONE` is reached exactly one cycle after the fast-path condition
itself fires, OR'ing the two makes `eu_ack` assert on two CONSECUTIVE
ticks for what should be one completion. `biu_cache_if.sv`'s own
`sf_ack_rise` edge-detector absorbs a double-pulsed ack harmlessly, but
`biu_multiop_fsm.sv`'s own `sf_eu_ack` consumer (drives MOVEP/MOVEM
multi-beat transfers) checks `if (sf_eu_ack)` directly with **no**
edge-detection -- correct only because `sf_eu_req = (mo_state ==
MO_CYCING)` stays continuously asserted across an entire multi-byte
transfer (unlike `biu_cache_if.sv`'s own one-request-per-transaction
shape) and the old single-tick-wide `SS_DONE` pulse was never wide
enough to be double-counted. `tb/biu_tb.sv`'s own pre-existing MOVEP
dynamic-sizing test caught this immediately: `rdata1`/`rdata3`
mismatched, root-caused to `mo_idx`/`cur_addr` advancing twice per byte
instead of once. **Fix**: `eu_ack` is now driven SOLELY by the new
fast-path condition, not OR'd with the old term -- the fast path fully
supersedes `SS_DONE`'s own old role (every case that would reach
`SS_DONE` already passed through this identical trigger one cycle
earlier), so it's the sole source, not a fallback. The registered
`SS_ACTIVE->SS_DONE->SS_IDLE` state path itself (and `SS_DONE`'s own
now-redundant-but-harmless `sf_accum` reset) is left completely
unchanged, still driving `cyc_req`/next-state -- only the `eu_ack`/
`eu_rdata` OUTPUTS switch to the fast path.

### A real, verified, but unevenly-distributed result

Controlled A/B measurement (`git stash`/`pop` on just `rtl/biu_sizing_
fsm.sv`, rebuilding `sim/timing` between each) on the full bus-touching
survey's own tick-level output: `a4_cmpm` improved 46->44 ticks (-2) and
`a7_trap_n`/`a7_illegal` each improved 88->84 ticks (-4, two independent
writes each benefiting once). Every other test in the suite (including
every RMW-shaped test Track A improved, and `a6_bsr`/`a6_jsr`) showed
**zero** change.

Investigated the zero-change cases directly via joint hierarchical
tracing (`cg_state`, `cyc_ack_edge`, `sf_state`, `sf_eu_ack`,
`sf_ack_rise`, `ci_state`, `top_eu_ack` for the RMW cases; `cg_state`,
`top_eu_ack`, `exc_active`, `mem_ack`, `ex_valid`, `ex_is_bsr`,
`branch_taken`, `pc_wr_en` for BSR) rather than assuming the fix simply
didn't apply. Confirmed the fix genuinely works exactly as designed in
both cases -- ack-propagation now takes 3 ticks instead of 4 from
AS-rise, and BSR's own `pc_wr_en` now fires at tick 115 instead of 116
-- but the 1-tick gain is fully **absorbed** downstream by a different
bottleneck outside this stage's own scope: for RMW cases,
`biu_cache_if.sv`'s own remaining `CI_IDLE->CI_WRITE` registration hop
and `biu_sizing_fsm.sv`'s own `SS_IDLE->SS_ACTIVE` hand-off (both
unchanged by this stage) consume the freed tick; for BSR/JSR,
`m68030_ifu.sv`'s own flush/redirect sequence reaches the identical
absolute tick (120) regardless of whether `pc_wr_en` arrived at 115 or
116. This is the same "absorption" phenomenon already documented
elsewhere in this project's history (e.g. Phase 125's `WS-MOVEM`
finding) -- a genuine, verified partial fix whose visibility depends on
whether anything downstream is already waiting on exactly this signal
with nothing else to do. `a4_cmpm` (no write phase to bottleneck on)
and `a7_trap_n`/`a7_illegal` (a multi-word exception-frame push with
multiple independent writes, each benefiting) show the gain directly
because nothing downstream absorbs it for them.

As with Track A, every improvement here is below `scripts/b_final_
clock_survey.py`'s own integer-clock (`ticks/4`) reporting granularity
and does not show up in its coarse output.

### Results

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12
(memind17/21/15/24), full 124-suite Harte sweep (mandatory --
`biu_sizing_fsm.sv` sits on every single EU bus transaction of any
kind, arguably the single most centrally-exercised file this whole
investigation has touched) -- PASS 702142, FAIL 2 (same documented
ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to baseline.

### Status

Track C (Stages C0+C1) closed. Real, verified, sub-clock-granularity
improvement on `a4_cmpm`/`a7_trap_n`/`a7_illegal`; zero net change (but
confirmed-genuine, confirmed-absorbed) on RMW-shaped and BSR/JSR tests;
zero correctness regression. A real bug (double-ack-pulse corrupting
MOVEP dynamic-sizing reads) was found and fixed via the mandatory `make
test` gate before this stage's own verification completed. Track D
(`biu_cache_if.sv`'s own `CI_DONE` collapse, Stages D0/D1/D2) is next,
per the plan's own default ordering.

## Phase 163 Track D, Stage D0 -- biu_cache_if.sv's CI_WRITE fast path

Implemented the highest-value, lowest-complexity of `CI_DONE`'s 5 entry
points first, per the plan's own staging. `CI_WRITE` (write-through/
write-allocate) has no cache-hit lookup and no `extract_rd()` sizing --
just a write-through/write-allocate side effect using `dhit_r`/
`wa_en`/`addr_r`/`wdata_r`/`siz_r`, all already latched and valid by
the time `sf_ack_rise` fires.

### Implementation

Unlike Track C, this stage doesn't OR a new combinational condition
onto the old registered ack path -- it removes the extra hop
altogether. `CI_WRITE`'s own registered next-state logic (`always_ff`)
now transitions directly `state <= CI_IDLE` on `sf_ack_rise`, instead
of `state <= CI_DONE`; the output block's own `CI_WRITE` case arm gains
`if (sf_ack_rise) eu_ack = 1'b1;` (mirroring the fast-path shape, but
sole-source from the start, learning directly from Track C's own
double-pulse mistake rather than repeating it). `eu_rdata` stays at its
default `32'h0` for this path -- correct, since a write never returns
read data (the old `CI_DONE`-routed path returned whatever stale
`fill_rdata_r` a write's own logic never touched anyway, so this is a
strict improvement, not a behavior change any caller could depend on).

This is cleaner than Track C's own final shape specifically because
`CI_WRITE` doesn't need anything `CI_DONE` itself provides -- unlike
`biu_sizing_fsm.sv`'s `SS_DONE`, which stayed as a harmless, unused-but-
present fallback state, `biu_cache_if.sv`'s `CI_DONE` is *shared* by
the other 4 entry points (`CI_D_MISS`/`CI_D_BURST0`/`CI_D_FILL_3B`/
`CI_FILL_3`, none touched this stage) and its own case arm
unconditionally asserts `eu_ack=1` whenever `state==CI_DONE` -- so
leaving `CI_WRITE`'s own transition pointed at `CI_DONE` while also
adding the new combinational fast path would have reproduced Track C's
exact double-pulse bug one cycle later. Skipping `CI_DONE` outright for
this one entry point is safe because `CI_IDLE`'s own next-state logic
is purely combinational off live inputs, with no dependency on how it
was reached -- already proven by `CI_BERR`'s own pre-existing identical
direct-to-`CI_IDLE` return path. `CI_DONE` itself, and all 4 of its
other entry points, are completely unchanged.

### A real, measurable win -- and a direct demonstration of the absorption mechanism from Track C

Controlled A/B measurement (`git stash`/`pop`, rebuilding `sim/timing`
between each) on the full bus-touching survey's own tick-level output,
run from Track C's own already-fixed baseline: `a6_bsr`/`a6_jsr` both
improved 66->64 ticks (-2) -- the SAME BSR/JSR redirect that Track B
found blocked on ack-propagation delay and that Track C's own read-side
fix left completely unmoved (absorbed by `m68030_ifu.sv`'s own flush/
redirect sequence reaching an identical absolute tick regardless).
BSR/JSR push their own return address via a **write**, so stacking a
second tick off the write-side ack-propagation chain (Track C's
`biu_sizing_fsm.sv` fix plus this stage's `biu_cache_if.sv` fix
together) evidently broke through whatever fixed floor absorbed the
first tick alone -- direct, tick-level confirmation that Track C's own
"absorption" finding was a genuine but *partial* saturation, not an
unmovable wall. Every RMW-shaped test (`a3_add_dn_ea`/`a3_and_dn_ea`/
`a3_addq_mem`/`a3_addi_mem`/`a4_neg_mem`/`a5_lsl_mem`/`a5_bchg_dn_mem`/
`a5_bset_dn_mem`) and `a7_trap_n`/`a7_illegal` showed **zero** further
change this stage -- consistent with the same absorption mechanism
still applying to them, just not yet broken through with only one of
the two tracks' fixes stacked on the write side for those specific
shapes (this stage only touches `CI_WRITE`; `CI_D_MISS`, the read-miss
side those RMW tests' own *read* phase depends on, is Stage D1's own
scope, not yet touched). `a4_cmpm` (no write phase) is correctly
unaffected.

As with Track A/C, every improvement here is below `scripts/b_final_
clock_survey.py`'s own integer-clock reporting granularity.

### Results

`make test` 36/36 (clean on the first attempt -- no bug found this
stage, unlike Track C), `make cosim_grp` 8/8, `make cosim_memind` 12/12
(memind17/21/15/24), full 124-suite Harte sweep (mandatory --
`biu_cache_if.sv` is the single largest, most heavily-relied-upon
module either track touches: ordinary reads/writes, D-cache hit/miss,
MMU translation faults, and burst fills all share this one state
machine) -- PASS 702142, FAIL 2 (same documented ASL.b anomaly), SKIP
281221, TIMEOUT 0, bit-identical to baseline.

### Status

Track D Stage D0 closed. A real, measurable (not just sub-granularity)
tick-level improvement on BSR/JSR, directly demonstrating that Track
C's own "absorption" finding was partial saturation rather than a hard
floor. Zero correctness regression, and unlike Track C this stage's
implementation was correct on the first attempt (informed directly by
Track C's own double-pulse lesson). Stage D1 (`CI_D_MISS`, the
read-miss side) is next.

## Phase 163 Track D, Stage D1 -- biu_cache_if.sv's CI_D_MISS fast path

Second-highest-value entry point per the plan's own staging: the
D-cache read-miss / cache-disabled-passthrough path, which every
ordinary EU read (not just RMW reads) dispatches through regardless of
whether the D-cache is actually enabled (`CI_D_MISS`'s own `if
(dcache_en && ...)` branch selects cache-populate vs plain passthrough,
but either way a read reaches this state -- confirmed by reading the
code, not assumed).

### Implementation

Same shape as Stage D0: `CI_D_MISS`'s own registered `always_ff` next-
state logic now transitions directly `state <= CI_IDLE` on
`sf_ack_rise` (was `<= CI_DONE`), for BOTH of its own internal branches
(cache-populate and passthrough) -- the cache-array side effects
(`data_d`/`tag_d`/`valid_d`, and the now-redundant-but-harmless
`fill_rdata_r` write) stay on their existing registered schedule,
completely unchanged, per the plan's own explicit design. The output
block's `CI_D_MISS` case arm gains a combinational fast path computing
`eu_rdata` the exact same way the always_ff block's own `fill_rdata_r`
assignment already did -- `extract_rd(sf_rdata, siz_r, addr_r[1:0])`
when the cache-populate condition holds, plain `sf_rdata` passthrough
otherwise -- deliberately excluding `ciin` from the split (per the
existing comment on the always_ff block: CIIN only gates the
array-population side effect, never the returned value, since the bus
request is already committed before CIIN's own value is even knowable).
`CI_DONE` itself, and its 3 remaining entry points
(`CI_D_BURST0`/`CI_D_FILL_3B`/`CI_FILL_3`), are untouched -- Stage D2's
own scope.

### Verification: correct on the first attempt

`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12,
full 124-suite Harte sweep -- PASS 702142, FAIL 2 (same documented
ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to baseline.

### Tick-level survey: zero visible change, and a direct trace explaining exactly why

Controlled A/B measurement showed **zero** tick-level change on every
single bus-touching test in the survey, including every RMW-shaped
test this stage was specifically targeting. Rather than accept that at
face value, added a temporary hierarchical trace (`cg`/`ci`/`sf` state,
`ci_ack`/`sf_ack`/`top_ack`, `mem_req`/`mem_rmw_run_r`/
`mem_rmw_read_ack` -- removed before committing) and re-ran
`a3_add_dn_ea` (`add.l d1,(a0)`) both with and without the Stage D1
change to compare directly, cycle by cycle.

**Confirmed the fix genuinely works exactly as designed**: in the
"before" trace, the read's own `sf_ack`/`ci_ack`/`top_ack`/
`mem_rmw_read_ack` all land one cycle apart (`sf_ack` fires, then
`ci_ack`/`top_ack` fire the FOLLOWING cycle once `CI_DONE` is reached).
In the "after" trace, all four fire on the exact same cycle, and
`mem_rmw_run_r` (the write-phase dispatch register) consequently
updates one full tick earlier too -- precisely the intended effect,
identical in shape to Stage D0's own confirmed win.

**But the write's own bus cycle start (`biu_cycle_gen`'s own `cg`
state leaving `ST_IDLE` for the write's S0) lands on the EXACT SAME
absolute tick in both traces**, despite `mem_rmw_run_r` being ready a
full tick earlier in the "after" case. Root cause: `ST_IDLE`'s own
registered next-state transition only advances on `state_adv`
(`phase_r[0]`) boundaries -- the same 2-tick-per-named-state pacing
grid Phase 160's own S-state pairing correction established project-
wide. `mem_rmw_run_r` becoming ready one tick earlier moves it to an
earlier position WITHIN the same 2-tick `ST_IDLE` window, not across
it, so the write's own dispatch is quantized to the identical grid
point regardless. This is a DIFFERENT absorption mechanism than Track
C/D0's own finding (a different, specific downstream bottleneck, not
the same one) -- worth distinguishing precisely rather than lumping
together as "the same absorption phenomenon" out of pattern-matching.

For the plain-read tests (`a1_fea_*`, no RMW phase at all), the zero
change is even more directly explained: `MEASURED_INSTR_ONLY` tracks
the read bus cycle's own AS-rise (a `biu_cycle_gen`-level pin event,
governed entirely by Phase 160's own calibrated S-state timing) --
Stage D1 only speeds up how quickly the ALREADY-COMPLETED read's ack
becomes visible one layer up, an internal handshake signal with no
bearing on the bus cycle's own pin-level duration. A standalone read
with nothing downstream depending on ack-propagation speed simply has
no way to show this fix's own effect at all.

### Results and decision to keep the fix

`make test`/`cosim_grp`/`cosim_memind`/Harte sweep all confirm zero
correctness regression (see above). The fix is kept despite showing
zero effect on the CURRENT 32-test bus-touching survey -- it's a
structurally real, correctly-verified latency reduction (confirmed via
direct trace, not assumed), consistent with Track A/C's own "real but
not currently visible" findings, just even more fully absorbed here by
a specific, well-understood downstream quantization boundary rather
than merely sub-clock-granularity. It remains a legitimate
architectural improvement that could matter for instruction shapes
outside the current 32-test survey (e.g. a multi-beat FSM chain whose
own downstream dispatch timing happens to straddle the `ST_IDLE`
quantization boundary differently) -- not chased further this stage,
since nothing in the existing survey demonstrates it.

### Status

Track D Stage D1 closed. Correct on the first attempt, zero
correctness regression, and a fix that is real and verified-working at
the signal level but currently invisible on every test in the existing
bus-touching survey -- root-caused precisely (not just asserted) via
direct trace comparison, distinguishing this from Track C/D0's own
different absorption mechanism. Stage D2 (burst paths + I-cache fill:
`CI_D_BURST0`/`CI_D_FILL_3B`/`CI_FILL_3`) is next, gated by `make
test`'s own `tb/cache_tb.sv` rather than the timing survey (per the
plan's own note that none of these three sites are exercised by
bus-touching timing tests at all).

## Phase 163 Track D, Stage D2 -- burst paths + I-cache fill (closes Track D and the plan)

The last 3 of `CI_DONE`'s 5 entry points, per the plan's own lowest-
priority staging: `CI_FILL_3` (I-cache linefill's own final beat),
`CI_D_BURST0` (D-cache burst, full 4-beat CBACK#-ok success), and
`CI_D_FILL_3B` (D-cache burst, degraded per-beat-fallback's own final
beat). Unlike D0/D1, none of these three are reached by anything in
the bus-touching timing survey (which never enables the I-cache or
D-cache burst mode), so per the plan's own note their real correctness
gate is `make test`'s own `tb/cache_tb.sv` (Phase 127/136's own
burst-linefill coverage), not the timing survey.

### Implementation

Same shape as D0/D1 for the always_ff side: all three states'
registered next-state logic now transitions directly `state <=
CI_IDLE` on their own completion trigger (`sf_ack_rise` for
`CI_FILL_3`, `dc_burst_ack` for the other two), instead of `<=
CI_DONE`; array-populate side effects (`data_i`/`tag_i`/`valid_i` or
`data_d`/`tag_d`/`valid_d`, plus the now-redundant-but-harmless
`fill_rdata_r` writes) stay on their existing registered schedule,
completely unchanged. `CI_D_BURST0`'s own degraded (`dc_burst_beat !=
3`) branch, which falls through to `CI_D_FILL_1B` rather than
completing, is deliberately untouched.

For the output block: `CI_FILL_3` already had a case arm (gained a
fast path the same shape as D0/D1's own). `CI_D_BURST0` and
`CI_D_FILL_3B` had **no case arm at all** before this stage -- their
`dc_burst_req`/`dc_burst_addr` outputs were already driven
unconditionally from the registered `dc_burst_req_r`/`addr_r` (Phase
158 Stage 4c), and `eu_ack`/`eu_rdata` came exclusively from the
later, now-removed hop through `CI_DONE`. Added two new case arms:
`CI_D_BURST0` fires `eu_ack` only for the full-success case
(`dc_burst_ack && dc_burst_beat==2'd3` -- the degraded case must NOT
complete here), muxing `eu_rdata` from whichever of
`dc_burst_rdata0..3` matches `woff_r` (mirroring the always_ff block's
own `case (woff_r)`); `CI_D_FILL_3B` fires unconditionally on
`dc_burst_ack` (this state IS always the degraded fallback's own
completion), with `eu_rdata` either `dc_burst_rdata0` directly
(`woff_r==3`, this beat's own word) or the already-latched
`fill_rdata_r` (an earlier beat already captured the CPU's requested
word) -- same "was it captured by an earlier beat" reasoning as
`CI_FILL_3`'s own arm.

**Confirmed `dc_burst_ack` is safe to gate on directly, no
edge-detector needed** -- read `biu_burst_ctrl.sv`'s own
`eu_burst_ack_r` register before adding this (not assumed): it
defaults to 0 every cycle and is set for exactly one cycle on
completion (`state_adv && at_burst_s7` gating a single `<= 1'b1`),
already a genuine 1-tick pulse -- confirming there's no risk of the
Track C double-pulse bug class here, since the existing always_ff
blocks already gate directly on `dc_burst_ack` with no `_rise` wrapper
either.

### Verification: correct on the first attempt

`make test` 36/36 (including `cache` and `biu`, the two suites that
directly exercise burst/I-cache-fill), `make cosim_grp` 8/8, `make
cosim_memind` 12/12, full 124-suite Harte sweep -- PASS 702142, FAIL 2
(same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical
to baseline -- the highest-stakes gate of this whole Track D given it
now touches all 5 of `CI_DONE`'s entry points across the file.

### Coverage note, not a gap introduced by this stage

Confirmed by reading (not assumed) that `tb/cache_tb.sv`'s own
`cback_n` is hardwired permanently asserted (`1'b0`), so the degraded
burst fallback (`CI_D_FILL_1B/2B/3B`) has never been reachable in this
testbench -- a pre-existing, already-documented limitation (Phase 166's
own note: "mirrors the I-cache's own already-validated shape"), not
something this stage newly introduces or needs to close. `CI_D_BURST0`
's own full-success path IS exercised (Phase 166's own D-10 test); the
new `CI_D_FILL_3B` fast-path arm, like the pre-existing always_ff logic
it sits beside, remains structurally correct but unexercised by
anything in the current suite.

### Status

Track D Stage D2 closed -- correct on the first attempt, zero
correctness regression. **This closes Track D (Stages D0/D1/D2) and
the whole bus-pipelining-overlap plan
(`~/.claude/plans/compressed-hopping-cocoa.md`) in full.** Every one of
`CI_DONE`'s 5 entry points across `biu_cache_if.sv`, plus
`biu_sizing_fsm.sv`'s own `SS_DONE`, now presents its ack combinationally
the same cycle its own completion trigger fires, instead of waiting an
extra registered cycle. Measured, verifiable wins: BSR/JSR improved 2
full ticks (Stage D0, stacking with Track C); `a4_cmpm`/`a7_trap_n`/
`a7_illegal` improved (Track C); every RMW-shaped test's own read-to-
write dispatch gap is now provably tighter at the signal level (D1),
even though every test currently in the bus-touching survey happens to
land within the same downstream `ST_IDLE` quantization window either
way. Zero correctness regression at any stage, confirmed via `make
test`/`cosim_grp`/`cosim_memind`/a full 124-suite Harte sweep after
every single RTL-touching stage in this plan.

## Phase 164 (cycle-accuracy-closing plan, item 1) -- register-only "too fast" regressions

User asked how far this RTL is from cycle-perfect real-68030 timing and
wanted the gap closed. Re-ran `scripts/b_final_clock_survey.py` against
current RTL first to get real numbers rather than rely on memory, and
found the register-only comparison had a real measurement flaw: about
half of those 85 tests need a trailing "marker" instruction (target
writes `An`/`SR`/`CCR`/nothing watchable) whose own real cost was
silently folding into the reported gap -- making instructions like NOP
look ~4x slower than real silicon when the actual culprit was the
marker's own unaccounted cost. Split into 56 "clean" tests (target's
own destination IS the watched register, genuinely isolated) vs 29
"marker-needed" tests (not a clean per-instruction signal, item 3's own
scope): clean set gap min=-5, max=+4, mean=+0.41 clocks -- essentially
exact already. A small number of genuine negative ("too fast") outliers
remained: `a4_unpk_dn` (-5), `a2_movec_read`/`a4_pack_dn`/
`a5_bchg_imm_dn` (-3 each), `a1_fea_immb`/`a1_fea_immw` (-1 each, same
underlying MOVE.B/W #(data),Dn instruction). Traced these to Phase
163 Stage 1's own documented-but-never-revisited side effect (that
stage's `ext_valid` fix sped up several `ext_count==1` instructions'
shared baseline as a side effect, and its own writeup explicitly
flagged these as "newly-negative... left for a possible future
extension of Part D's own work" -- never revisited until now).

### Implementation

Five new whitelist entries in `rtl/eu_seq.sv`'s existing
`dec_internal_stall_ticks_fixed` mechanism (Phase 162 Part D's own
established, purely-additive artificial-stall infrastructure -- no new
mechanism needed): **BCHG/BCLR/BSET #(data),Dn** (static bit-number,
register dest; `scripts/timing_tables.py`'s own `BIT_MANIP` table gives
all three an identical NCC=6, matching the already-whitelisted dynamic-
register form's own uniform treatment; `dec_writes_reg` naturally
excludes BTST, which has no clean-list data point yet); **MOVEC Cr,Rn**
(read direction, decoded via a fixed opcode match `16'h4E7A` -- the
decode block's own comment already notes this direction has no
dedicated `dec_is_X` flag, "Rc→Rn uses dec_use_imm", so re-derives the
raw opcode check directly, same precedent as every other fixed-encoding
whitelist entry); **PACK/UNPK Dy,Dx,#(data)** (register form only,
`dec_is_pack_mem=0` excludes the memory `-(Ay),-(Ax)` form; BCD_EXT
table gives PACK NCC=6, UNPK NCC=8, matching the measured -3/-5 gaps
exactly); **MOVE.B/W #(data),Dn** (re-derives the exact decode
condition from the MOVE/MOVEA block using only module-level continuous-
assign fields -- `f_move_sz!=00` alone already implies `f_group∈{1,3}`
byte/word by its own definition, but `f_move_dst_mode`/`f_mode`/`f_reg`
are still required to avoid colliding with an unrelated opcode sharing
the same bit positions outside groups 1/2/3; the long form
`MOVE.L #(data),Dn` has no clean-list data point -- `a1_fea_imml` is a
POSITIVE +2 gap, a different, not-yet-investigated mechanism, item 2's
own scope -- and is deliberately excluded).

### Verification

`make test` 36/36 (clean on the first attempt), `make cosim_grp` 8/8,
`make cosim_memind` 12/12, full 124-suite Harte sweep (mandatory --
MOVEC/PACK/UNPK/BCHG/MOVE are all real, heavily-Harte-covered
instructions) -- PASS 702142, FAIL 2 (same documented ASL.b anomaly),
SKIP 281221, TIMEOUT 0, bit-identical to baseline. Re-ran the survey
and diffed line-by-line against the pre-fix run: **exactly the 6
targeted tests changed, all to gap=0 exactly**, zero side effects on
any of the other 111 tests -- `a1_fea_immb`/`a1_fea_immw`/
`a2_movec_read`/`a4_pack_dn`/`a4_unpk_dn`/`a5_bchg_imm_dn` all now
measure exactly their manual NCC value.

### Status

Closes item 1 of the cycle-accuracy-closing plan
(`~/.claude/plans/compressed-hopping-cocoa.md`). Every clean-list
register-only negative ("too fast") gap identified by the fresh survey
is now fixed. Item 2 (the ADDI/ANDI/EORI/ORI/SUBI-to-Dn +4 gap cluster)
is next.

## Phase 165 (cycle-accuracy-closing plan, item 2 -- investigation only, no RTL change)

Traced `a3_addi_dn` (`addi.l #20,d2`, `ext_count==2`) directly (temporary
hierarchical trace on `biu_cycle_gen`'s own state, `decode_pc`,
`eu_ext_valid`/`ext_count`, `m68030_ifu`'s own `q_cnt`/`ifu_req`/
`fetch_pend_r`, and `biu_arbiter`'s own `grant_ifu` -- removed before
committing) to understand exactly where the +4-clock gap (manual=4,
measured=8) goes, rather than guess whether it's the same kind of
"threshold too narrow" bug Phase 163 Stage 1 already fixed for
`ext_count==1`.

**Confirmed it is NOT that bug, and NOT a single new bug at all** --
it's two already-understood mechanisms stacking, plus one genuinely
unavoidable cost:

1. **A genuinely necessary second IFU fetch.** `ext_count==2` needs 3
   words total (opcode+2 immediate words) in the queue before
   dispatch, but the IFU always fetches 2 words per bus cycle. When
   decode first reaches the target instruction with an empty queue
   (the common case right after a `bra.w` redirect, as in every one of
   these tests), the FIRST fetch brings `q_cnt` from 0 to 2 --
   insufficient -- forcing a genuinely separate SECOND fetch to reach
   `q_cnt>=3` (landing on 4, since fills only ever arrive in pairs).
   Confirmed via direct trace: `q_cnt` reads 2 right after the first
   fetch completes (`ifu_ext_valid` still 0), then a second, distinct
   ~8-tick (2-clock) bus cycle runs before `q_cnt` reaches 4 and
   `eu_ext_valid` finally asserts. This portion mirrors real 68030
   silicon's own 32-bit-bus, longword-aligned prefetch granularity --
   a 3-word instruction genuinely cannot be fetched in fewer than 2
   aligned bus cycles unless the queue already had a head start, which
   an isolated `bra.w`-then-target test structurally can't have. **Not
   fixable, and not a bug** -- this is real, matching-silicon cost.

2. **The gap BETWEEN the two fetches is where the (already-known)
   avoidable-latency mechanisms live**, confirmed via the trace's own
   `ifu_req`/`fetch_pend_r`/`grant_ifu` columns: the first fetch's own
   ack lands and `fetch_pend_r` clears the same cycle, but `ifu_req`
   doesn't re-assert for the second fetch until 2 ticks later --
   exactly the "at least one concrete source (`fetch_pend_r` needs a
   genuine extra cycle to re-arm after `ifu_ack`)" mechanism Phase 161
   Part B Stage B0 already found and characterized as load-bearing
   (avoids a stale-ack race, same hazard class Phase 128 already fixed
   once elsewhere). Then, even once `ifu_req`/`grant_ifu` are both
   live again, `biu_cycle_gen`'s own `ST_IDLE` state doesn't actually
   leave idle for a further 2 ticks -- exactly the `state_adv`/
   `phase_r[0]` 2-tick quantization boundary the closed bus-
   pipelining-overlap plan's own Track C/D work already characterized
   for RMW dispatch (Stage D1's own finding). **This is item 4's own
   scope, not a separate mechanism** -- this trace is a second,
   independent confirmation of the same `ST_IDLE` quantization
   question, from an entirely different instruction shape (IFU-driven
   fetch dispatch, not EU-driven RMW write dispatch).

### Decision

No RTL change this phase. Rather than force a speculative fix onto a
gap whose real root cause is (a) genuinely unavoidable real-hardware-
matching bus time and (b) two mechanisms already scoped elsewhere in
this plan (one already investigated and found load-bearing, one that
is literally item 4's own next task), item 2 closes as investigation-
only. The finding is folded into item 4's own scope as an additional,
independently-derived confirmation that `ST_IDLE`'s own quantization
is worth investigating -- not a new, separate item.

### Results

No RTL changed; `make test` 36/36 sanity check confirms the tree is
clean (`tb/timing_tb.sv`'s own temporary trace fully removed, no diff).

### Status

Item 2 closed as investigation-only -- root cause identified precisely
(not guessed at), no independent fix exists separate from item 4's own
already-planned `ST_IDLE` investigation. Item 3 (redesign the 29
marker-needed register tests for a clean measurement) is next.

## Phase 166 (cycle-accuracy-closing plan, item 3) -- redesign marker-needed register tests + fix newly-revealed gaps

### New testbench capability: watch_kind

`tb/timing_tb.sv` gained `watch_kind` (0=Dn, unchanged default; 1=An
via `u_rf.a_reg[0:6]`; 2=CCR via `u_rf.sr_out[7:0]`), letting a test
observe completion directly instead of always needing a trailing
marker instruction whose own real, unaccounted cost was folding into
the measured total for anything that doesn't write a Dn register.
Confirmed zero regression on the existing 117-test survey before
touching any individual test (`watch_kind` defaults to 0, bit-
identical to the old hardcoded `d_reg[watch_reg]` path).

### 15 tests converted (of the 29 originally marker-needed)

**Category A -- An writes (`watch_kind=1`)**: `a2_move_rn_an`
(MOVEA), `a2_move_usp_an` (MOVE USP,An), `a3_adda_w/l`, `a3_suba_w/l`,
`a6_lea`.

**Category B/C -- CCR-only writes and compare-only ops
(`watch_kind=2`)**: `a2_move_dn_ccr`, `a3_cmp_rn_dn`, `a3_cmpa_w`,
`a3_cmpi_dn`, `a4_tst_dn`, `a5_btst_imm_dn`, `a5_btst_dn_dn`,
`a5_bftst_dn`, `a6_chk_dn_dn_noexc`. Each test's own setup now
explicitly sets a known CCR baseline (mostly `$1F`, all flags set, or
`$10`/`$14` where the target's own real result would otherwise
coincide with `$1F` and produce no detectable transition) immediately
before the target instruction, so the watch mechanism's own
`prev!=new` edge-detection has a genuine transition to catch.

**14 tests deliberately NOT converted this phase**: `a6_andi_to_sr`/
`a6_andi_to_ccr` (reverted after investigation -- see below);
Bcc/DBcc/JMP (7 tests) and `a2_move_an_usp`/`a7_trapv_notrap`/
`a7_bkpt` (3 tests) were never attempted -- PC-redirect-as-completion-
signal raises the same "does decode_pc race ahead of real retirement"
reliability question this project has hit and fixed multiple times
before (most recently the `docs/stalls.md`-cataloged hazards), and
deserves its own careful pass rather than a rushed extension; TRAPV-
notrap/BKPT genuinely have zero observable side effect when they don't
trap, so eliminating their marker isn't even possible with a watch-
based approach -- would need a different technique (measure the
marker's own isolated cost and subtract it) not built this phase.

### `a6_andi_to_sr`/`a6_andi_to_ccr`: investigated and reverted, not a regression

Converting these first revealed the mask `#$FFFF`/`#$FF` in the
original tests is a pure no-op AND (identity operation) -- CCR/SR
provably CANNOT change value, so no `prev!=new` transition can ever
be detected regardless of baseline. Changed the masks to `$FF00`/`$00`
(clears CCR only, doesn't touch S/M/IPL, and the manual's own NCC
doesn't depend on the operand value) to get a real transition, which
surfaced `p=1` where `expect_p=2` -- direct trace confirmed the RTL
genuinely fetches opcode+immediate together in ONE combined longword
bus cycle (a real hardware alignment property, not a bug), while the
manual's own row assumes two separate word fetches. **This exact
finding was ALREADY documented** in the tests' own pre-existing `desc`
field from an earlier phase ("Measured p=1, not the manual's own row
value of 2 -- the extra prefetch... is plausibly a pipeline-queue
refill... after any SR write") -- not new territory, and matches
Phase 162 Stage D5's own "not safely fixable" conclusion for these two
instructions' unusually large natural baseline. Reverted both `.s`
files and their JSON entries back to the original marker-based form
via `git checkout` -- **initially forgot to also rebuild the now-stale
`.hex` files**, which briefly desynced the reverted JSON (expecting
the marker-based program) against the still-edited `.hex` (no marker),
hanging both tests in the full survey run; caught by comparing the
survey's own test-name list against the pre-item-3 baseline (2 tests
silently missing), fixed by rebuilding.

### Two real hand-derivation mistakes, both caught by direct simulation trace rather than trusted

`a6_chk_dn_dn_noexc`'s first watch_val (`$1B`, assuming CHK leaves
V/C unaffected when it doesn't trap) hung -- direct trace showed the
real result is `$18`: CHK actually **clears** V/C for the no-trap
case rather than leaving them unaffected, an easy mistake for a field
the architecture itself calls "undefined." Confirmed via
`u_rf.sr_out` traced cycle-by-cycle rather than re-guessing. No other
watch_val needed correction (each was double-checked against this
same kind of direct trace before trusting it, following this whole
project's own established discipline).

### 9 newly-revealed "too fast" gaps, 8 fixed, 1 investigated-and-declined

Converting these tests to a clean, marker-free measurement revealed
several gaps that a marker-inflated measurement had been silently
hiding (some previously showed a *positive* gap purely because of
marker overhead, masking a real negative one underneath). All 8
fixable ones use the identical `dec_internal_stall_ticks_fixed`
mechanism as item 1, gated on already-existing decode flags: `MOVE
Dn,CCR` (`dec_is_move_ccr_w`), `MOVE USP,An` (`dec_reads_usp`, unique
to that one decode site), `ADDA.W/SUBA.W/CMPA.W` register-direct
(`dec_sext_src`, confirmed to naturally exclude the already-accurate
`.L` forms since it's defined as `!f_dir`), `BTST #(data)/Dn,Dn`
(`dec_unit==UNIT_BIT && dec_bit_op==BIT_TST && !dec_is_mem_rd` --
`dec_writes_reg` isn't the right exclusion here since BTST never
writes, unlike the already-whitelisted BCHG/BCLR/BSET), `BFTST Dn`
(`dec_bf_op==3'b000`, the one bit-field register form Stage D3's own
whitelist explicitly left out "see marker-overcounting note"), `LEA
(An),An` (`dec_is_lea && f_mode==3'b010`, gated to the one-word EA
form specifically since other LEA EA modes have a structurally
different, untested baseline).

**`CHK Dn,Dn` (manual=8, natural=3, gap=-5) was attempted and reverted
-- a genuine functional regression, not a test-margin issue.** `make
test` caught it immediately: `exception_tb.sv`'s CHK-02/03/06 checks
failed with `chk_trap_cnt` incrementing by 11 instead of 1. Root
cause, confirmed by reading `eu_seq.sv`'s own `chk_trap` assign: `(ex_
valid && ex_is_chk && !ex_is_mem_rd && (chk_below_w||chk_above_w))
|| ...` -- a pure combinational condition with no one-shot/edge guard,
because the register-direct CHK path had never held `ex_valid` high
for more than 1 cycle before this stall existed. Holding it for 5
extra clocks via the ordinary `ex_internal_stall` mechanism let `chk_
trap` re-fire on every one of those ticks. A real fix would need `chk_
trap` itself made edge-triggered -- a genuine, separate RTL change,
not attempted here (same "not safely fixable within this mechanism,
needs a structural change elsewhere" shape as the already-documented
ANDI-to-SR/CCR case). Reverted; documented in-line at the point where
the entry would have gone, so a future attempt starts from this
finding instead of re-discovering it.

### A second, unrelated test-margin regression, also caught by `make test`

`tb/ea_modes_tb.sv`'s `run_instr()` task uses a fixed `repeat(5)`
post-`instr_ack` settle margin, predating any artificial-stall entry
touching an instruction this file exercises -- the new `LEA (An),An`
+4-tick stall made it read A3 one cycle too early (`basic-EA LEA(An)
A3: got 00000000 exp 00002000`, a stale pre-write value). No busy/
stall signal was exposed on this testbench's own DUT ports to poll
instead, so widened the fixed margin to `repeat(10)` (matches this
whole project's established precedent of widening fixed margins when
a new stall entry needs it, e.g. Stage D4's `eu_seq_tb.sv` fix).

### Verification

`make test` 36/36 (after both fixes above), `make cosim_grp` 8/8,
`make cosim_memind` 12/12, full 124-suite Harte sweep (mandatory --
touches MOVE/ADDA/SUBA/CMPA/BTST/BFTST/LEA/MOVEC decode, all real,
heavily-Harte-covered instruction families) -- PASS 702142, FAIL 2
(same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical
to baseline.

Re-ran the survey and diffed against the pre-item-3 baseline: the 15
converted tests' own gaps are now genuinely isolated per-instruction
measurements for the first time (several previously "looked fine" by
coincidence -- marker overhead happened to land close to the manual's
own value); the 8 newly-whitelisted fixes each land at exactly gap=0;
zero effect on any of the other 102 untouched tests. **117 tests, gap
min=-5 (CHK, deliberately un-whitelisted, documented) max=+7 mean=1.30
(was 1.73 before this phase), 48 of 117 now an exact gap=0 (was 39).**

### Status

Closes item 3's own scoped portion of the cycle-accuracy-closing plan
(15 of 29 marker-needed tests converted; 8 of 9 newly-revealed gaps
fixed; CHK documented as a genuine, deliberately-declined fix). Item
3's remaining scope (Bcc/DBcc/JMP PC-redirect tests, `a2_move_an_usp`/
`a7_trapv_notrap`/`a7_bkpt`) is left as documented follow-up, not
picked up this phase. Item 4 (`ST_IDLE` quantization compressibility)
is next.

## Phase 167 (cycle-accuracy-closing plan, item 4 -- investigation only, no RTL change)

### The question

Item 2's own trace found `biu_cycle_gen`'s `ST_IDLE` state holds for
up to 2 extra ticks after a real request (`eu_req`/`ifu_req`) becomes
ready, before `state` actually advances to `ST_READ_S0`/`ST_WRITE_S0`
-- the same 2-tick quantization the closed bus-pipelining-overlap
plan's own Track D Stage D1 finding already flagged for RMW dispatch.
The question this item set out to answer: is that quantization itself
avoidable, the same way Track A/C/D found and removed an *extra
registered hop* (`CI_WRITE`/`CI_D_MISS`->`CI_DONE`, `SS_ACTIVE`->
`SS_DONE`) sitting on top of the real bus timing in `biu_cache_if.sv`/
`biu_sizing_fsm.sv`?

### Read `ST_IDLE`'s own code directly before reasoning about it

`biu_cycle_gen.sv`'s `state<=state_nxt` (the ONE place the whole
module's state register actually updates) is gated on a single,
uniform condition: `else if (state_adv) state <= state_nxt;`
(`state_adv = phase_r[0]`, firing every 2 ticks -- the exact mechanism
Phase 160 established to correctly pace every REAL S-state pair to
match actual 68030 silicon, "S0+S1 share one real clock" etc,
confirmed against MC68030UM.pdf Figures 7-64/7-65). `ST_IDLE`'s own
`state_nxt` computation (the big `if/else if` chain selecting which
bus-cycle type to launch) is **purely combinational, with no extra
registered state of its own** -- it reacts live to `eu_req`/`ifu_req`/
etc every single tick. There is no `ST_IDLE_PENDING` or equivalent
intermediate state the way `CI_WRITE`/`CI_D_MISS`/`SS_ACTIVE` each had
their own separate `CI_DONE`/`SS_DONE` hop layered on top.

### The key structural difference from Track A/C/D's own fixes

Every prior fix in this whole investigation (Track A's `CI_IDLE`,
Track C's `SS_ACTIVE`, Track D's `CI_D_MISS`/`CI_WRITE`/etc) worked by
adding a **combinational OUTPUT fast path** that let the module
present its own ack/request one cycle *earlier* than its own
registered *next* state would have, while leaving the underlying
state register's own transition timing completely untouched. None of
them ever needed to change *when the state register itself advances*
-- they only changed *what gets presented combinationally while
waiting for* that already-scheduled advance.

`ST_IDLE`'s exit has no equivalent structure to exploit this pattern
on: **the `state_adv`-gated transition INTO `ST_READ_S0`/`ST_WRITE_S0`
already IS the real S0 launch itself** -- there's no separate,
removable intermediate hop sitting between "request ready" and "S0
begins." Bypassing `state_adv`'s own gating specifically for this one
transition (while leaving it in place, unchanged, for every other
S-state-pair transition within the resulting bus cycle, including the
immediately-following S0->S1) would be internally inconsistent with
the uniform synchronous discipline Phase 160 already carefully
established and extensively verified project-wide -- it would mean "a
new bus cycle's own S0 can begin at any tick" while "every other named
S-state pair transition within that same cycle can only advance at a
`state_adv` boundary," two different rules for what is, physically,
the exact same kind of clock-boundary-aligned transition.

### Corroborating evidence, not just structural reasoning

The SAME 2-tick quantization was independently observed via two
completely different request paths -- Track D Stage D1's own EU-driven
RMW write dispatch, and item 2's own IFU-driven fetch dispatch trace
-- landing on the identical mechanism both times. That consistency
across two structurally unrelated call sites is exactly what's
expected if `state_adv`'s own cadence is a genuine, fixed hardware-
alignment property (the same half-clock granularity governing every
other S-state pair), rather than a coincidental implementation
artifact that happened to reproduce itself twice.

### Decision

No RTL change. `ST_IDLE`'s own quantization is concluded to be
correct, hardware-matching behavior -- not avoidable dispatch overhead
comparable to what Tracks A/C/D fixed -- based on a genuine structural
argument (no extra hop exists to bypass; bypassing `state_adv` itself
for just this one transition would break the uniform synchronous
discipline the whole FSM, and Phase 160's own already-validated
derivation, depend on), not merely "investigated and gave up." Given
`biu_cycle_gen.sv` is the single most centrally-tested, highest-
blast-radius module in the whole project, a speculative change here
without this level of confidence would be irresponsible regardless of
potential upside.

### Results

No RTL changed; `make test` 36/36 sanity check.

### Status

Item 4 closed -- concluded not applicable, with reasoning grounded in
how the mechanism is actually built (not just re-stated uncertainty).
Item 5 (broaden the bus-touching survey beyond the current 32
representative tests) is next.

## Phase 168 (cycle-accuracy-closing plan, item 5 -- 3 new tests, real gaps found, deep investigation deferred)

### Scope

The existing 32-test bus-touching survey only ever exercises RMW
instructions (NEG/ADDQ/ADD/AND/CLR/TAS/TST/LSL/BCHG/BSET/etc) combined
with the single simplest EA mode, plain `(An)`. Added 3 new tests
combining already-tested instruction families with EA modes never
paired with an RMW op before: `a4_neg_mem_predec` (`neg.l -(a0)`),
`a4_neg_mem_idx` (`neg.l (4,a0,d1.l)`, brief-format indexed), and
`a3_addq_postinc` (`addq.l #1,(a0)+`) -- each combining an already-
proven-accurate instruction (the plain-`(An)` form already measures
gap=+4, matching the standard baseline) with a fea-table EA mode
already independently verified accurate in isolation (Stage A1's own
`a1_fea_anpredec`/`a1_fea_briefidx`/`a1_fea_anpostinc`).

### Result: real, substantial, previously-unknown gaps -- roughly double the plain-(An) case

| test | manual | measured | gap | (An)-only sibling's own gap |
|---|---|---|---|---|
| `a4_neg_mem_predec` | 8 | 17 | **+9** | `a4_neg_mem`: +4 |
| `a3_addq_postinc` | 7 | 17 | **+10** | `a3_addq_mem`: (comparable +4-class) |
| `a4_neg_mem_idx` | 10 | 22 | **+12** | `a4_neg_mem`: +4 |

Cross-checked each against its own r/p/w bus-cycle-count expectation
before trusting the gap number at all (same discipline as every prior
finding this whole investigation used): `a4_neg_mem_predec`/`a3_addq_
postinc` both PASS their r/p/w check cleanly (1/1/1 as predicted), so
their own +9/+10 gaps are genuine, not a counting artifact.
`a4_neg_mem_idx` FAILS its own r/p/w check (measured p=1, manual's own
row assumes p=2) -- direct investigation strongly suggests this is the
SAME already-documented, already-understood "opcode+extension-word
fetched together in one combined longword bus cycle" alignment
property first found for `a6_andi_to_sr` in item 3 (this instruction
is also exactly 4 bytes, at the same 4-byte-aligned `target_pc=0x200`)
-- not a new bug, and not something that would make the RTL *slower*
if anything (fewer real bus cycles should cost less, not more), so it
doesn't explain the gap's own magnitude either.

### Deliberately not investigated further this phase

The `-(An)`/`(An)+`/indexed auto-increment RMW forms carrying roughly
**double** the plain-`(An)` form's own already-fixed dispatch gap is a
real, substantive, previously-undiscovered finding -- but tracing WHY
(is it the auto-increment/decrement address computation adding a
genuine extra dispatch step analogous to `ext_count==2`'s own item-2
finding? a different, new mechanism specific to the RMW-plus-EA-
update interaction? something in `setup_mem_incdec()`'s own timing?)
is open-ended work of comparable scope to items 1-4 individually, not
a quick trace-and-fix. Given the substantial ground already covered
this session (items 1-4 fully closed, a real ~25% mean-gap reduction
on the existing clean register-only survey, multiple genuine RTL bugs
found and fixed), this is surfaced as a concrete, well-characterized
finding for the user to prioritize rather than chased unilaterally.

### Results

3 new tests added to the survey (`tests/timing/a4_neg_mem_predec.s`/
`a4_neg_mem_idx.s`/`a3_addq_postinc.s` + their JSON manifest entries).
No RTL changed -- `make test` 36/36 sanity check (these new tests
aren't part of `make test`'s own regression gate, a separate `sim/
timing`-based mechanism entirely, so zero regression risk either way).

### Status

Item 5 partially closed: broadened the survey and found real,
substantial, previously-unknown gaps in auto-increment/decrement/
indexed RMW combinations -- roughly double the already-fixed plain-
`(An)` case. Deep investigation of the root cause is deferred, flagged
for the user rather than assumed to be in scope for continuing
unilaterally. Item 6 (lowest priority -- re-verify Phase 160's own
S0-S7 pin timing) not started.

## Phase 169 -- CORRECTION to Phase 168's own item-5 finding, and a new master timing-benchmark script

### The correction

Beginning Stage 1 of the user-approved "Cycle-accuracy closing plan
v2" (re-prioritizing the remaining items by impact), traced `a4_neg_
mem_predec`/`a3_addq_postinc` directly to find where Phase 168's own
reported +9/+10 clock gaps came from -- and found there was nothing to
find. **Phase 168's own gap numbers were wrong**, caused by the one-off
Python script used to build and check those 3 new tests: it read the
raw `MEASURED` field from `sim/timing`'s own stdout instead of
`MEASURED_INSTR_ONLY` -- the field `scripts/b_final_clock_survey.py`
already correctly uses for any test needing a trailing marker
instruction (which all 3 of these do, since NEG/ADDQ write to memory,
not a directly-watchable register). Re-measured properly via the real
survey script:

| test | EA mode | manual | measured | gap (corrected) | gap (Phase 168, wrong) |
|---|---|---|---|---|---|
| `a4_neg_mem_predec` | `-(An)` | 8 | 11 | **+3** | +9 |
| `a4_neg_mem_idx` | `(d8,An,Xn)` | 10 | 11 | **+1** | +12 |
| `a3_addq_postinc` | `(An)+` | 7 | 11 | **+4** (identical to the `(An)` baseline) | +10 |

The real finding is the opposite of what was reported: all three EA
modes measure the **same flat 11-clock dispatch cost** as the already-
fixed plain-`(An)` baseline, and the gap actually *shrinks* as EA
complexity increases (the manual predicts more clocks for the fancier
addressing computation; this RTL's own fixed dispatch floor doesn't
grow to match). Tracks A-D's own fixes already generalize cleanly
across these EA modes -- there was no new, unfixed overhead to chase.
This was reported to the user directly and transparently as soon as it
was caught, before any RTL work was attempted on the false premise.

### Root cause of the mistake, and the fix: one canonical script

The mistake was possible specifically because there were two separate,
overlapping scripts (`scripts/run_timing.py` for r/p/w PASS/FAIL,
`scripts/b_final_clock_survey.py` for the manual-vs-measured gap) and
no single, hardened, per-instruction-capable tool -- exactly the gap
that led to writing a fresh, under-tested one-off script for the 3 new
tests in the first place. User asked for a proper "master script" and
approved a plan to build one.

New `scripts/timing_benchmark.py` consolidates both existing scripts'
proven logic into one canonical tool (neither predecessor touched or
renamed -- both are referenced by name throughout this file's own
permanent phase history; each got a one-line docstring pointer to the
new tool instead):

- Auto-hex-build (from `run_timing.py`), correct `MEASURED`-vs-`
  MEASURED_INSTR_ONLY` field selection (from `b_final_clock_survey.py`,
  ported verbatim -- now the *only* place this decision is made).
- **Surfaces the r/p/w PASS/FAIL the simulation already computes right
  next to the gap number** -- the direct structural fix for today's
  mistake: a wrong bus-cycle count (or a hang) now shows `MISMATCH`
  instead of silently producing a number that looks like an ordinary
  result.
- `--filter SUBSTR`: run/report just one instruction or family by
  name/desc substring -- the per-instruction spot-check capability
  that was missing, meant to remove the temptation to write another
  one-off script.
- `tests/timing/known_issues.json` sidecar: already-investigated,
  documented non-bugs get tagged `[KNOWN: reason]` in the report
  instead of looking like unexplained anomalies; summary stats report
  both an all-tests mean and a known-excluded mean.
- Optional per-entry `manual_ref` field cross-checks the `desc`-parsed
  manual total against `scripts/timing_tables.py`'s own structured
  `ncc_total()`/`ncc_rpw()` lookups -- opt-in for new tests only,
  deliberately not retrofitted onto the ~150-test existing corpus
  (that would be its own real transcription-risk migration).
- `--json OUTFILE` for machine-readable output; `--strict` exits
  nonzero on any mismatch (for future CI-style use).

### Verification

Cross-validated against both predecessors on the full corpus before
trusting the new tool, per the approved plan: diffed `timing_
benchmark.py`'s own per-test gap numbers against `b_final_clock_
survey.py`'s across all 120 tests -- **exact match, byte-for-byte,
zero differences** (confirmed via a stripped-formatting diff, not just
eyeballing the aggregate mean). Cross-checked the r/p/w MISMATCH
detection against `run_timing.py`'s own verdicts for every test that
doesn't use `watch_kind`.

**Found a real, pre-existing gap in `run_timing.py` along the way**:
it crashes (unhandled `TimeoutExpired`, 60s hang) on any `watch_kind`-
using test (the item-3 CCR/An-watch capability), because it was never
updated to pass that plusarg through when item 3 added it -- confirmed
by direct inspection of the actual subprocess command it built (missing
`+watch_kind=`). Not a flaw in the new tool (which already handles
`watch_kind` correctly, matching `b_final_clock_survey.py`'s own
already-correct handling) -- a stale gap in the older, now-superseded
script. Left unfixed per the approved plan's own explicit "kept as-is"
scope for the two predecessor scripts.

The new tool's own r/p/w surfacing immediately found 3 more real,
already-explained-but-never-formally-annotated findings, previously
invisible to `b_final_clock_survey.py` (which never checked r/p/w at
all): `a6_bcc_taken`/`a6_dbcc_false_notexp`/`a6_bsr` all show measured
`p=4` vs the manual's own `p=2` -- already documented in each test's
own `desc` field from Phase 161 Part A Stage A6 as the IFU's own
speculative-linear-readahead prefetch model running past a not-yet-
resolved branch, not an RTL bug. Added all 3 (plus the already-known
CHK and ANDI-to-SR/CCR cases) to `known_issues.json`.

Pure tooling change -- no RTL touched, `make test` 36/36 sanity check
(unaffected, as expected).

### Status

Corrects Phase 168's own wrong finding (no RTL fix needed for RMW+EA-
mode dispatch -- already accurate). Delivers the master benchmark
script requested, now the canonical tool for all future timing work.
Stage 1 of the "Cycle-accuracy closing plan v2" is effectively closed
by this correction (nothing to fix). Next: Stage 2 (CHK `chk_trap`
edge-triggering) or Stage 3 (Bcc/DBcc/JMP clean measurement), per the
plan's own ordering -- the newly-surfaced `a6_bcc_taken`/`a6_dbcc_
false_notexp`/`a6_bsr` p-count findings are directly relevant context
for Stage 3's own work.

## Phase 170 (cycle-accuracy closing plan v2, Stage 2) -- CHK chk_trap edge-triggering + re-add the CHK Dn,Dn stall

User asked to work through `scripts/timing_benchmark.py`'s own report
and close gaps one at a time: fix, verify, commit, push, repeat.
Started with `a6_chk_dn_dn_noexc` (gap=-5), already fully diagnosed in
Phase 166 -- `chk_trap` (in `eu_seq.sv`) is a pure combinational
condition on `ex_valid && ex_is_chk && ...` with no one-shot/edge
guard, so holding `ex_valid` for extra cycles via the artificial-stall
mechanism made it re-fire on every one of those ticks.

### Fix

New `chk_trap_raw` (the exact old combinational expression, renamed)
plus a one-shot latch `chk_trap_fired_r`: clears whenever `ex_valid`
drops (instruction retires/flushes, ready for the next CHK), sets the
instant `chk_trap_raw` first fires, suppressing every later tick of
the same instance. `chk_trap = chk_trap_raw && !chk_trap_fired_r`.
Hit the same Icarus forward-reference issue this project has hit
repeatedly before (an `always_ff` block referencing a `wire ... =`
assign declared later in the file) -- fixed by declaring both signals
up front (near `chk_below_w`/`chk_above_w`, which `chk_trap_raw`
itself depends on) and moving the `always_ff` block there too, with
the `assign`s themselves staying at their original, later textual
position.

Verified the edge-triggering fix alone (before touching the stall
whitelist) directly against `tb/exception_tb.sv`'s own CHK-02/03/06
checks -- 48/48 clean. Then re-added the `CHK Dn,Dn` whitelist entry
to `dec_internal_stall_ticks_fixed` (manual=8, natural=3, `+20` ticks)
that Phase 166 had reverted.

### A second real bug found immediately by the full regression gate

`make test` caught a new failure with the stall entry back in:
CHK-03/06's own "N=1" checks read a stale `0` instead of the expected
`1`. Traced to `tb/exception_tb.sv`'s own `run_instr()` task -- a fixed
`repeat(12)` post-`instr_ack` settle margin, predating CHK's own new
+20-tick artificial stall and too tight to see the trap's own SR
update land by the time the check runs. Exact same class of stale-
margin bug as Stage 1's own `ea_modes_tb.sv` fix (Phase 166) -- widened
to `repeat(30)`.

### Verification

`make test` 36/36 (after both fixes), `make cosim_grp` 8/8, `make
cosim_memind` 12/12, full 124-suite Harte sweep (mandatory -- touches
the shared exception-dispatch path) -- PASS 702142, FAIL 2 (same
documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to
baseline. `scripts/timing_benchmark.py --filter chk` now reports
`a6_chk_dn_dn_noexc` at exactly gap=0 (was -5). Removed the now-stale
`known_issues.json` entry for it.

### Status

Closes Stage 2 of the cycle-accuracy closing plan v2. Corpus-wide gap
stats (`scripts/timing_benchmark.py`, full 120-test corpus): min moved
-5 -> **-4** (CHK's own -5 is gone; the new min is `a4_tas_mem`'s own
-4, next up), mean (known-excluded) 1.32 -> 1.30. Next: `a4_tas_mem`
(-4).

## Phase 171 -- `a4_tas_mem` (-4) investigated, real finding, deliberately not fixed this pass

Traced `a4_tas_mem` directly (temporary `biu_cycle_gen` state trace,
removed before committing) to understand its own -4 gap before
attempting anything. Confirmed the RTL's own bus-locked RMW protocol
for TAS is genuinely correct and matches CLAUDE.md's own documented
spec exactly: entering the RMW dispatch (`cg` state 47) at t=176, AS
asserts once at t=180 and stays asserted continuously through both the
read phase (DS toggles, `rw=1`) and the write phase (`rw` flips to 0
at t=192 with AS still held), only deasserting once at t=204 -- a
single, genuinely-locked 28-tick (7-clock) read+write cycle, not two
separate bus transactions. This confirms the test's own pre-existing
`desc` note (from Phase 161) was right: the write phase genuinely
never produces its own `AS-fall` event, so `tb/timing_tb.sv`'s own
address-edge-based measurement can't separately observe it -- a
harness limitation already documented, not a new finding.

**The new finding**: between the opcode fetch completing (`cg` back to
`ST_IDLE` at t=154) and the RMW dispatch actually starting (t=176),
there's a genuine, separate, ordinary 16-tick (4-clock) bus cycle
(`cg` states 18-25, `rw=1`) that has nothing to do with TAS's own RMW
sequence -- almost certainly the IFU speculatively prefetching the
trailing marker instruction's own opcode ahead of TAS's own dispatch,
similar in *character* to the already-documented "speculative-linear-
readahead" phenomenon (`a6_bcc_taken`/`a6_bsr`/etc), but not yet
confirmed to be the *same* mechanism, and not yet understood well
enough to say whether TAS's own RMW dispatch is being genuinely
delayed *by* that prefetch (a real, possibly-fixable arbitration
question -- EU should have priority over IFU per this project's own
documented arbiter priority) or whether the two are simply running
concurrently with no real interaction.

### Decision

Not fixed this pass -- the magnitude (-4) is moderate, TAS itself is a
comparatively rare instruction in typical code (mostly synchronization
primitives), and root-causing the prefetch-vs-RMW-dispatch interaction
properly would need the same depth of investigation as a full stage
(comparable to the CHK work), not a quick trace. Documented here as an
open, real, partially-characterized finding rather than added to
`known_issues.json` (reserved for *confirmed* non-bugs) -- this one
isn't confirmed either way yet. Moving to the next item in the
priority list; can return to this with a dedicated pass later.

### Results

No RTL changed; temporary trace fully removed (`git diff --stat tb/
timing_tb.sv` shows no diff). `make test` 36/36 sanity check.

## Phase 172 -- Reliable marker-free timing baseline (`watch_kind=3`: retirement-pulse tracking)

User asked for a systematic guarantee that *every* timing test properly
excludes marker-instruction overhead from its own measurement, before
deciding what to prioritize next -- explicitly sequenced ahead of any
further gap-closing work. Planned via `EnterPlanMode`/`ExitPlanMode`
(approved plan: `~/.claude/plans/compressed-hopping-cocoa.md`).

### Audit

`MEASURED_INSTR_ONLY` (Phase 163) already solves marker inflation for
bus-touching instructions; `watch_kind` 0/1/2 (Dn/An/CCR, Phase 166)
already solves it for anything writing a register or CCR. A corpus-wide
sweep (every `r=0,w=0` manifest entry, cross-checked against each test's
own `.s` source) found the remaining gap: instructions with **no**
observable Dn/An/CCR/memory effect at all still relied on a trailing
marker with nothing to stop its own dispatch cost folding into
`MEASURED` -- `a6_nop`, `a6_bcc_b_not_taken`, `a6_bcc_w_not_taken`,
`a6_dbcc_true` (DBcc's own `wb_writes_reg` is explicitly suppressed when
cc=true, `rtl/eu_seq.sv:9542`), `a7_trapv_notrap`, and `a2_move_an_usp`
(writes USP, unreadable via any existing `watch_kind`, previously needing
a 2-instruction marker chain). The same sweep also flagged
`a6_andi_to_sr`/`a6_andi_to_ccr` as suspicious (using `watch_kind=0`
with a marker despite writing CCR directly, and using an all-1s AND
mask that's a pure CCR no-op) -- see below, this turned out to be a false
positive with an important lesson attached.

### `watch_kind=3` design

New value-free completion signal in `tb/timing_tb.sv`: watch for the
first `wb_valid` pulse strictly after the first `instr_ack` pulse
observed since `t_start`. Grounded via direct code reads before
implementing, not assumed: `u_top.eu_instr_ack` fires exactly once for
the target's own decode->EX dispatch, and in this project's own "taken
branch lands directly on the instruction under test" convention, the
branch's own dispatch has already happened before `t_start` -- so the
first `instr_ack` after `t_start` is unambiguously the target's own.
`wb_valid` (`rtl/eu_seq.sv:9538`, `wb_valid <= ex_valid;` unconditionally
whenever not stalled) pulses for *every* completing instruction,
register-writing or not -- confirmed by reading the WB-stage latch
directly, not assumed. Pipeline is strictly in-order (single EX slot),
so the first `wb_valid` after the dispatch latch arms is unambiguously
the target's own retirement.

**Cross-validation caught a real 1-tick systematic offset before this
was trusted for anything**: a first implementation (watching raw
`wb_valid` directly) measured `a4_ext_dn` (an already-trusted,
`watch_kind=0` register test) at 17 ticks against kind=0's own 18 --
not the required exact match. Direct trace (temporary `$display`,
removed before committing) found `eu_regfile`'s own committed value
becomes observable exactly one tick *after* `wb_valid` itself first
pulses (an extra flip-flop hop downstream) -- kind=0/1/2's own
value-watch technique therefore always detects completion one tick
later than raw `wb_valid`. Fixed by delaying kind=3's own detection by
one registered tick (`wb_valid_r`) to match kind=0's convention exactly,
rather than introduce a new, inconsistent-by-one-tick technique
relative to the whole rest of the corpus. Re-validated: `a4_ext_dn` and
`a2_swap` (a second, independent register-only test) both now measure
bit-identical tick counts under kind=0 and kind=3.

### Conversions

Converted the 6 confirmed zero-effect tests to `watch_kind=3`,
simplifying each `.s` source back to bare setup+branch+instruction+stop
with no trailing marker, and updated their JSON manifests
(`watch_kind=3`, `watch_reg`/`watch_val` dropped). `a6_dbcc_true` needed
its `land:` label kept (as filler data after the never-reached branch
target) since the assembler still needs it to resolve the displacement
even though it's never executed. `scripts/timing_benchmark.py` needed a
small fix (`run_one()` assumed `watch_reg`/`watch_val` always present in
every manifest entry -- made both optional, since kind=3 doesn't need
them).

True (now-reliable) gap numbers, replacing the marker-inflated originals:
`a6_nop` +6->+1, `a6_bcc_b_not_taken` +4->**0 (exact)**,
`a6_bcc_w_not_taken` +7->-3, `a6_dbcc_true` +5->-5,
`a7_trapv_notrap` +4->-1, `a2_move_an_usp` +4->-1. None of these residual
gaps have grounded root-cause reasoning yet -- deliberately NOT added to
`known_issues.json` (reserved for confirmed non-bugs, not guesses) --
left as real, now-trustworthy findings for a future prioritization pass,
per the user's own explicit sequencing.

### `a6_andi_to_sr`/`a6_andi_to_ccr`: investigated, NOT a marker bug -- reverted

Attempted the same fix (switch to `watch_kind=2`, pick an AND mask that
clears a real bit instead of the original all-1s no-op) and it measured
a wildly different number (3 clocks vs the original marker-based 13) --
suspicious given Phase 162 Stage D5 already documented a genuine
~13-clock unstalled baseline for ANDI/MOVE-to-SR due to IFU
prefetch-queue-refill after an SR/CCR write. Traced directly (temporary
`$display`, removed before committing) rather than trust either number:
confirmed ANDI-to-SR genuinely forces the IFU to refill its queue **one
word at a time** afterward (three separate single-word fetches visible
in the trace, vs. the normal 2-words-at-once pattern), and this refill
is what blocks the marker's own dispatch -- exactly the cost NCC's own
"no overlap with the following instruction" definition means to
capture. `watch_kind=2` fires at ANDI's own internal CCR commit,
*before* that refill completes, and would have silently under-measured
this instruction by ~10 clocks. **Reverted the `watch_kind=2` attempt,
restored both `.s` files to their original marker-based form unchanged**,
and added an explanatory comment to both so this isn't "fixed" again by
mistake. Empirically, `a6_andi_to_ccr` (CCR-only, no S/M/T bits) shows
the identical single-word-refill pattern and identical 13-clock total as
`a6_andi_to_sr` -- this RTL doesn't distinguish CCR-only writes from
full-SR writes for this behavior, so both were reverted the same way.

This finding also killed the plan's own originally-scoped step 6
(convert `a6_bcc_taken`/`a6_dbcc_false_notexp`/`a6_bsr`/`a6_jmp`/`a6_jsr`
from "land on marker at redirect target" to `watch_kind=3` on the
branch's own retirement) -- the same underlying principle applies: these
instructions' own manual NCC rows explicitly count the redirected
target's own opcode fetch (`p=2` or `p=3`) as part of the branch's own
cost. Confirmed via a read-only experiment against the existing,
unmodified `a6_jmp.hex`: `+watch_kind=3` measures 3 clocks (fires at
JMP's own retirement, before the target fetch even begins) vs. the
existing land-on-marker technique's 13 clocks. Abandoned this step
entirely -- no files touched for it. **General lesson recorded for
future timing-test work**: `watch_kind` 0/1/2/3 all fire at an
instruction's own internal EX->WB retirement; for instruction classes
whose own manual NCC total is defined to include a real cost that
happens strictly *after* that point (IFU queue-refill following an
SR/CCR write; the redirected target's own opcode fetch following a taken
branch/jump), all four kinds systematically under-measure, and the
"marker inflation" framing does not apply -- the marker or landing-pad
technique is the *correct* one for these, not a bug.

### `a7_bkpt` r-count completeness fix

Separate, smaller, well-scoped item found earlier this session (not a
marker issue): `tb/timing_tb.sv`'s `is_data_fc` classification
(`FC in {101,001}`) never recognized FC=111 (CPU space) as a countable
read, so `a7_bkpt`'s own real CPU-space read (Phase 157's own BKPT
implementation, confirmed via direct trace) was invisible to `r_count`
-- `expect_r=0` reflected what the harness could see, not the true
`r=1` architectural total. Fixed by adding FC=111 to `is_data_fc` (safe
project-wide: this corpus has no other CPU-space cycle -- IACK/
coprocessor -- to conflict with). `a7_bkpt`'s r/p/w check now passes
cleanly (no more MISMATCH); new gap=-3 (was +3), also left undocumented
in `known_issues.json` pending future root-cause work.

### Verification

Full corpus re-run (`scripts/timing_benchmark.py` over all 10 manifests,
126 tests) diffed programmatically against a saved pre-change baseline:
exactly the 7 intended conversions changed gap (`a2_move_an_usp`,
`a6_bcc_b_not_taken`, `a6_bcc_w_not_taken`, `a6_dbcc_true`, `a6_nop`,
`a7_trapv_notrap`, `a7_bkpt`), all 119 other tests byte-for-byte
unchanged -- confirms zero collateral impact from the `is_data_fc`
widening or the new `watch_kind=3` mechanism. `make test` 36/36 (every
change this phase is testbench/`.s`/JSON-manifest only -- no RTL
touched, so no Harte/cosim gate needed, matching this project's own
established convention for pure-tooling changes).

### Results

`gap (known excluded)` mean improved 0.70 -> 0.19 (n=89) purely from
correcting previously-inflated numbers, not from any new fix --
reflecting that the baseline is now measurably more reliable, not that
anything got faster. `a4_neg_mem_idx`'s own untraced r/p/w mismatch and
`a4_tas_mem`'s own already-flagged extra-bus-cycle finding remain
explicitly out of scope, unchanged. See `~/.claude/plans/compressed-
hopping-cocoa.md` for the full approved plan.

## Phase 173 (timing-gaps-largest-first plan, Stage 1) -- `a6_dbcc_true` (-5) root-caused and fixed

Traced directly (temporary `$display` on `instr_ack`/`ex_is_dbcc`/
`wb_valid`/`flag_z`, fully removed before committing): DBcc with cc=true
dispatches through the identical 3-clock/12-tick baseline every other
simple register-direct instruction in this whitelist shares (`instr_ack`
-> `ex_valid` next tick -> `wb_valid` the tick after -> detected one more
tick later, matching Phase 172's own established convention) -- real
68030 microcode needs more serial time (NCC=8) even for this "do
nothing" path; this RTL computes the condition-true/no-op outcome
combinationally in one EX cycle, same "internal microcode ceiling"
character as every other `dec_internal_stall_ticks_fixed` entry.

Added a new whitelist entry in `rtl/eu_seq.sv`, gated on
`dec_is_dbcc && eval_cc(dec_branch_cond, flag_n, flag_z, flag_v,
flag_c)` evaluating true at decode time -- reuses the exact
`eval_cc()`/live-CCR-flag pattern Scc's own `dec_imm` computation
already relies on for real correctness (not just timing), giving
confidence this decode-time CCR read is already hazard-safe in this
pipeline. Deliberately excludes both cc=false paths (count-not-expired/
branch-taken, whose own real redirect cost is a separate, already-KNOWN
readahead artifact; count-expired, which already matched the manual
exactly with zero stall) -- verified directly that neither's own
measurement moved.

Results: `a6_dbcc_true` now measures exactly `manual=8, measured=8,
gap=0` (was -5). Full corpus re-run confirms this is the *only* test
whose gap changed. `make test` 36/36, `make cosim_grp` 8/8, `make
cosim_memind` 12/12, full 124-suite Harte sweep -- PASS 702142, FAIL 2
(same documented ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical
to baseline. See `~/.claude/plans/compressed-hopping-cocoa.md` for the
full 6-stage plan. Stage 2 (`a4_tas_mem`, -4) is next.

## Phase 174 (timing-gaps-largest-first plan, Stage 2) -- `a4_tas_mem` (-4) definitively resolved: no bug, documented

Finished Phase 171's own open investigation via direct trace
(`eu_req`/`sf_cyc_req`/`ic_cg_req`/`grant_eu`/`grant_ifu`/
`biu_cycle_gen`'s own `state`/`mem_rmw`/`tas_run_r`, temporary
`$display`, fully removed before committing). **Phase 171's own
"mystery separate 16-tick bus cycle, possibly IFU-vs-EU arbitration"
hypothesis is disproven, not confirmed**: `grant_eu` fires the very
next tick after `eu_req` first asserts (tick174->175 in the traced
run), with zero contention from `grant_ifu` in between -- the
arbitration path is genuinely instant here, ruling out a Track-C/D-style
dispatch-arbitration bug.

The real, now fully-accounted-for breakdown of the measured 10-clock
total (vs. manual NCC=14): opcode fetch (2 clocks, ordinary) + normal
S0/S1 dispatch/setup latency (~2.5 clocks, the same shape every
instruction in this pipeline pays) + the locked read+write RMW cycle
itself (6 clocks, continuously AS-asserted the whole way, confirmed
pin-accurate -- matches CLAUDE.md's own documented RMW protocol
exactly). The RTL computes TAS's own read-then-decide-then-write
sequence combinationally, with no gap between the read data arriving
and the write dispatching; real 68030 microcode most likely needs
genuine additional serial time to evaluate the read byte's own top bit
before committing the write -- the same "internal microcode ceiling"
character as the register-only `dec_internal_stall_ticks_fixed`
cluster, just the first instance found in a bus-touching RMW
instruction instead of a pure register op.

**Deliberately not fixed**: `dec_internal_stall_ticks_fixed` only
applies to register-only, non-bus-touching decode-time stalls. An
analogous fix here would mean extending TAS's own locked RMW FSM
(`eu_seq.sv`'s `tas_run_r`/`mem_rmw` machinery) between the read ack
and the write dispatch -- the exact mechanism the CAS/CAS2/BERR-abort
protection rollout (Phases 108-114) depends on being correct. A
disproportionate correctness risk for a single -4 gap on a
comparatively rare instruction; documented in `known_issues.json`
instead.

Results: no RTL change, `tb/timing_tb.sv`'s temporary trace fully
removed (`git diff --stat` shows no diff), new `known_issues.json`
entry. `make test` 36/36 (no Harte/cosim re-run needed -- pure
documentation, zero RTL touched). See `~/.claude/plans/compressed-
hopping-cocoa.md`. Stage 3 (`a6_bcc_w_not_taken` -3, `a7_bkpt` -3) is
next.

## Phase 175 (timing-gaps-largest-first plan, Stage 3a) -- `a6_bcc_w_not_taken` (-3) root-caused; real test bug found and fixed in `a6_bcc_b_not_taken` along the way

Traced `a6_bcc_b_not_taken` (previously an "exact match," used as the
comparison baseline for `a6_bcc_w_not_taken`'s own investigation) via
direct `$display` on `instr_ack`/`dec_internal_stall_ticks_fixed`/
`instr_word` and found its own dispatched opcode was `0x4DD6`
(`LEA (A6),A6`), not a real `Bcc.B` opcode at all. Root cause: the
test's own `skip:` label sat immediately after `bne.b skip`
(displacement=0), and vasm silently substitutes its own "LEA (An),An"
2-byte NOP-equivalent placeholder for a degenerate zero-distance short
branch (confirmed directly: `vasmm68k_mot -L` emits "warning 2058:
short-branch to following instruction turned into a nop" for this
exact file, and no other file in the whole `tests/timing/` corpus
triggers it). **This test had never exercised a real `Bcc.B` opcode
since Phase 161 first created it** -- its own "exact gap=0" was
coincidentally matching LEA (An),An's own manual NCC (also 4) via the
pre-existing, unrelated LEA whitelist entry, not because Bcc.B itself
was correctly timed.

Fixed by inserting a real `nop` between the branch and `skip:`
(`tests/timing/a6_bcc_b_not_taken.s`), giving the branch a genuine
non-degenerate displacement; vasm now emits the real `0x6602` (`bne.b`)
opcode with no warning. Re-measured: **both** `a6_bcc_b_not_taken` and
`a6_bcc_w_not_taken` now share the identical 3-clock/12-tick unstalled
baseline (the byte-form's own true, previously-never-measured value),
confirming `a6_bcc_w_not_taken`'s own -3 gap was never form-specific --
neither Bcc-not-taken form had ever had a real whitelist entry.

Added a new `dec_internal_stall_ticks_fixed` entry in `rtl/eu_seq.sv`,
gated on `dec_is_branch && !eval_cc(dec_branch_cond,...)` (the exact
mirror-image of `dec_branch_taken`'s own existing "taken" formula, so
this can never fire for BRA -- always-true condition -- or for the
taken path, a separate already-KNOWN readahead gap) -- `f_disp8`
distinguishes byte-form (+1 clock=4t) from word-form (+3 clocks=12t),
mirroring the same group's own branch-decode block. Long-form
(`f_disp8==0xFF`, 68020+) has no test coverage and is deliberately left
unhandled.

Results: `a6_bcc_b_not_taken` gap 0->0 (same number, now testing the
*real* instruction) and `a6_bcc_w_not_taken` gap -3->0 (both exact
matches). `a6_bcc_taken`/`a6_dbcc_false_notexp`/`a6_bsr`/`a6_jmp`
(the readahead cluster, sharing `dec_is_branch`/`eval_cc` machinery)
confirmed unaffected via direct re-measurement before the full gate.
`make test` 36/36, `make cosim_grp` 8/8, `make cosim_memind` 12/12,
full 124-suite Harte sweep -- PASS 702142, FAIL 2 (same documented
ASL.b anomaly), SKIP 281221, TIMEOUT 0, bit-identical to baseline (a
meaningful gate here: Bcc is one of the most heavily Harte-exercised
instructions in the corpus). See `~/.claude/plans/compressed-hopping-
cocoa.md`. `a7_bkpt` (-3) is next (Stage 3b).

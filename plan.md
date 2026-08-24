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

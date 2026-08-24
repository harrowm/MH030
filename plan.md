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

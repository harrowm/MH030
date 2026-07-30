# RTL Line-Count Reduction Plan

Original: 15,776 lines across 29 RTL files. eu_seq.sv was 7,549 lines (48%).
After items #2 and #1: eu_seq.sv = 7,226 lines; total RTL = 15,453 lines (-323).

Run `make test` (51/51) **and** `make mustest` (60/60) after each item. Commit and push before starting the next.

---

## #3 — Merge parallel mem_* ternary chains [SKIPPED]

**Attempted and reverted.** The `always_comb` form requires 5 default assignments
plus multi-line override blocks per arm; the net result was +25 lines, not -100.
Compact parallel ternary chains are already shorter than the equivalent priority block.

---

## #5 — S4/S5 DSACK sampling in biu_cycle_gen.sv [SKIPPED]

**Analysed and skipped.** Sharing the 9 S4/S5 blocks requires a new
`next_s5`/`next_s6` lookup mux (~20 lines), new `is_S4`/`is_S5` predicates
(~10 lines), and a `terminate_cond` signal (~10 lines). After accounting for
that infrastructure, net saving drops to ~50 lines while risk of FSM bugs is
meaningful. Not worth it.

---

## #4 — Group 4 unary-to-memory EA merger (eu_seq.sv) [SKIPPED]

**Analysed and skipped.** The current block at lines 2181–2216 already shares
EA setup across all five instructions (NEGX/CLR/NEG/NOT/TST): a single
`case(f_mode)` handles 010/011/100 and a single `case(f_dn)` selects the
alu_op. There are no separate per-instruction blocks to merge.

Extended modes (101/110/111) for these instructions are not yet implemented,
so there is nothing to consolidate. Adding extended mode support would be a
feature addition, not a refactor.

---

## #2 — Shared EA auto-inc/dec task (eu_seq.sv) [DONE]

**Lines saved:** 146  **Risk:** Low

**Problem:** The `case(f_mode)` 011/100/default block for `(An)+`/`-(An)` EA
update (`dec_an_upd_en`, `dec_an_upd_reg`, `dec_an_delta`, `dec_ea_offset`)
appeared 13 identical times across Group 4/8/9/B/C/D decoders.

**Fix:** Extracted to `task setup_mem_incdec(siz, inout en, areg, adelta, eaoff)`.
Call site: `setup_mem_incdec(f_siz, dec_an_upd_en, dec_an_upd_reg, dec_an_delta, dec_ea_offset);`

**Note:** Icarus Verilog 13 cannot write module-scope variables from a task body
directly (task scope does not inherit module scope for writes). Worked around by
using `inout` parameters to pass the target variables explicitly. The broader
6-mode `case(f_mode)` EA expansion (arms 010–111) could not be similarly
extracted because each call site has unique EA-dependent fields (dec_imm, PC
offsets, dec_abs_ea_val expressions) that vary too much for a single task.

---

## #1 — Merge Groups 9/D (SUB/ADD) into shared arm (eu_seq.sv) [DONE]

**Lines saved:** 177  **Risk:** Medium

**Problem:** Groups 9 (SUB/SUBX/SUBA) and D (ADD/ADDX/ADDA) were structurally
identical — same EA modes, same ADDX/SUBX memory form, same SUBA/ADDA block.
Only `dec_alu_op` differed: ALU_SUB/SUBX vs ALU_ADD/ADDX.

**Fix:** Merged into a single `4'h9, 4'hd: begin` arm. Added two pure helper
functions `grp_aop(f_group)` and `grp_xop(f_group)` that select the right op
based on which group is active. All 8 ALU_SUB/SUBX assignments replaced with
function calls. Group D arm deleted.

**Note:** Groups B (CMP/EOR) and C (AND+MUL+BCD+EXG) could not be merged with
9/D — Group B uses both ALU_CMP and ALU_EOR in asymmetric ways (f_dir selects
which), and Group C has MULU/MULS/ABCD/EXG sub-cases unique to that group.

---

## Status

| # | Description                      | Saved | Risk   | Status  |
|---|----------------------------------|-------|--------|---------|
| 3 | Merge mem_* ternary chains       | ~100  | Low    | SKIPPED |
| 5 | biu_cycle_gen S4/S5 dedup        | ~150  | Low    | SKIPPED |
| 4 | Group 4 unary-to-memory EA merge | ~150  | Low-med| SKIPPED |
| 2 | Shared EA auto-inc/dec task      | 146   | Low    | DONE    |
| 1 | Merge Groups 9/D (SUB/ADD)       | 177   | Medium | DONE    |

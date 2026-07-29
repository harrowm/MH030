# RTL Readability Improvement Notes

All changes are structural/cosmetic — no functional intent. Run `make test` (51/51) after each.

---

## #1 — Repeated `case(f_dn)` body (eu_seq.sv ~826–950) [DONE]

**Problem:** The same 6-arm ALU-op decode appears four times consecutively, once per EA mode:
(d16,An), (d8,An,Xn), (xxx).W, (xxx).L. Only the preamble (imm/offset setup) differs.

```sv
case (f_dn)
    3'b000: begin dec_alu_op=ALU_OR;  ... end
    3'b001: begin dec_alu_op=ALU_AND; ... end
    3'b010: begin dec_alu_op=ALU_SUB; ... end
    3'b011: begin dec_alu_op=ALU_ADD; ... end
    3'b101: begin dec_alu_op=ALU_EOR; ... end
    3'b110: begin dec_alu_op=ALU_CMP; ... end
endcase
```

**Fix:** Factor the shared body into a single `case(f_dn)` that runs after the EA-mode
preamble sets `dec_imm`, `dec_ea_offset`/`dec_abs_ea_val`. Removes ~100 lines of copy-paste.

**Risk:** Low — pure structural refactor of combinational decode.

---

## #2 — `eu_lane()` helper function (eu_seq.sv ~7486–7510) [DONE]

**Problem:** The byte-lane shift pattern appears 4× inline in the `mem_wdata` assign:

```sv
(ex_siz==2'b01) ? {data[7:0],  24'h0}
: (ex_siz==2'b10) ? {data[15:0], 16'h0}
:                    data
```

**Fix:** Extract to `function automatic logic [31:0] eu_lane(input logic [31:0] d, input logic [1:0] siz)`.
Collapses 12 lines to 4; a future bug fix propagates to all callsites automatically.

**Risk:** Very low — pure combinational function, identical logic.

---

## #3 — Parallel ternary chains → `always_comb` block (eu_seq.sv ~7213–7415) [DONE]

**Problem:** `mem_rw`, `mem_siz`, `mem_addr`, `mem_wdata`, `an_wr_sel`, `an_wr_data` are each
12–20-arm ternary chains. `an_wr_sel` and `an_wr_data` are parallel chains with the same 15
conditions — they must be kept in sync manually with no language-level enforcement.

**Fix:** Replace with a single `always_comb` priority block where both assignments share each
arm. Lets each case have an explanatory comment and makes sync-errors impossible.

**Risk:** Medium — large block, needs careful verification.

---

## #4 — Default-init block grouping (eu_seq.sv ~568–713)

**Problem:** ~80 signals initialised to zero in a single wall of text before `if (instr_valid)`.
Hard to find a specific signal and check its default.

**Fix:** Group defaults by category (ALU, branch, memory, shifts, multi-cycle, exceptions)
with blank lines between groups and a brief category comment.

**Risk:** Very low — cosmetic only.

---

## #5 — `ext_count` flat if-else → `case(f_group)` (m68030_seq.sv ~304–430)

**Problem:** 130-line flat if-else chain testing `f_group`, `f_ss`, `f_mode`, `f_reg`
independently with implicit ordering dependencies that aren't visible.

**Fix:** Outer `case(f_group)` switch with nested branches inside each group, matching
the decode structure in eu_seq.sv.

**Risk:** Medium-high — ordering dependencies must be preserved exactly.

---

## #6 — Inner `if/else if` → `case(f_mode)` in Group 0 (eu_seq.sv ~714–1050)

**Problem:** Third and fourth nesting levels both use `if/else if` chains on `f_mode`
(a 3-bit value). Four levels of nesting makes control flow hard to follow.

**Fix:** Switch innermost decode to `case(f_mode)` with nested `case(f_reg)` for mode=111.
Removes one nesting level; makes coverage obviously complete.

**Risk:** Low — structural only.

---

## #7 — `inside{}` for state-group predicates (biu_cycle_gen.sv ~309–330)

**Problem:** Six predicates written as 4–8 explicit `|` comparisons:
```sv
assign is_init_ssp = (state == ST_INIT_SSP_S0) | ... | (state == ST_INIT_SSP_S7);
```

**Fix:** Use SystemVerilog `inside` operator:
```sv
assign is_init_ssp = state inside {ST_INIT_SSP_S0, ..., ST_INIT_SSP_S7};
```

**Risk:** Very low — semantically identical.

---

## #8 — EX-latch as a packed struct (eu_seq.sv ~5595–5677)

**Problem:** ~80-line `always_ff` block of sequential `ex_foo <= dec_foo` assignments.

**Fix:** Wrap `dec_*` outputs in a packed struct `decode_ctrl_t`; latch collapses to
`ex_ctrl <= dec_ctrl`. Downside: adds `.field` verbosity at every use site.

**Risk:** High refactor cost, low net readability gain — probably not worth it.

---

## #9 — Named `normal_bus_idle` signal (eu_seq.sv ~7406–7414)

**Problem:** `mem_req` gate has 12 negations joined by AND — reads as a wall of `!foo_r`.

**Fix:** Assign `logic no_special_bus_op = !tas_after_write_r && !cmp2_run_r && ...`
separately, then use it in the `mem_req` expression.

**Risk:** Very low — cosmetic.

---

## #10 — FSM output/transition split (biu_cycle_gen.sv)

**Problem:** Next-state logic and Moore outputs are interleaved across the file.

**Fix:** Two distinct `always_comb` blocks — one for next-state, one for output mux —
matching the standard two-process FSM pattern.

**Risk:** Large mechanical refactor; medium readability gain.

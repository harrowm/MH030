# Plan: Add a 3rd combinational read port to `eu_regfile`

Status: **Phase 0 (Bucket A) and Phase 0.5 (Bucket B confirmation) done. Phase 0.75
(BCHG root-cause) and Phase 1+ (the port itself) not started — no register-file port
added yet.**

**Update after Phase 0**: Bucket A is confirmed and closed. CLR.b/NEG.w/NOT.b/TST.b/
TAS/ASL.w all went from their previous partial pass rates to **100%**, zero remaining
fails of any kind, purely by adding `(d8,An,Xn)` decode using the existing 2-port
`An`(rd_a)/`Xn`(rd_b) pattern — no port change. See `plan.md §Phase 81`.

**Update after Phase 0.5**: Bucket B is fully confirmed — OR/EOR/SUB/CMP.b and
ADDA/SUBA/CMPA.w all retested at 100%, matching AND.b. Also found something not
anticipated in the original draft: **MOVE's indexed-dst failures have nothing to do
with Bucket C at all.** All 545 MOVE.b failures are TIMEOUT, none involve the
register-source form (the one that actually shares BCHG's mechanism) — it's purely
missing decode coverage for 6 source addressing modes on `dec_is_move_mm_idx_dst`.
See the updated Bucket C section below — this looks fixable the same way as Phase 81,
no port needed, but wasn't implemented this session.

## TL;DR

- Adding a 3rd read port is cheap here: `eu_regfile` is a small flip-flop array read
  through combinational muxes, not a true multi-port SRAM. A 3rd port is another mux,
  not a structural redesign. Low risk, low cost, mechanically simple.
- **But before committing to it**: a diagnostic this session shows the "indexed-dst
  arch gap" documented since Phase 79 is not one problem. I re-ran `AND.b` — which
  uses the *exact same* 2-port time-multiplexing trick (`dyn_bit_get_Dn`) that
  BCHG/BCLR/BSET use for their indexed-dst forms — and it's **100% pass, 0 fails**
  (8064/8064). That means the existing 2-port scheme *does* work for at least one
  instruction family that needs a genuine 3rd operand (Dn + An + Xn simultaneously in
  spirit, even if fetched across two cycles). So BCHG/BCLR/BSET's failure is most
  likely an isolated bug in their specific RMW path, not proof that 2 ports are
  insufficient in general.
- Separately, a large chunk of what's labeled "arch gap" in `CLAUDE.md`/`plan.md`
  (CLR/NEG/NOT/NEGX/TST/TAS/shift-memory → indexed dst) is for **unary** memory ops
  that only ever need `An` + `Xn` (2 ports) — they were just never decoded for
  `(d8,An,Xn)` at all. That's a plain feature-gap fix, no port change needed.
- **Recommendation**: do the cheap, low-risk fixes first (Phase 0 below) and use their
  results to decide how much of the true 3rd-port work is still needed. This doc still
  gives the full 3rd-port design (Phase 1+) since you asked for it and it's a
  legitimate simplification regardless — it replaces a fragile multi-cycle register
  swap with a clean single-cycle 3-operand read — but I'd size it down substantially
  once Phase 0 lands.

---

## 1. What's actually broken — an honest audit

The `(d8,An,Xn)` "architectural gap" note has been carried in `CLAUDE.md` since Phase
79 as one blanket explanation. Digging into *why* each instruction fails shows three
different root causes, only one of which is a real port-count limitation.

### Bucket A — Unary memory ops: no 3rd operand needed at all, just missing decode

**DONE (Phase 81, `plan.md`).** CLR.b/NEG.w/NOT.b/TST.b/TAS/ASL.w all confirmed at
100% after adding `(d8,An,Xn)` decode with no port change — hypothesis validated.

CLR / NEG / NOT / NEGX / TST / TAS / shift-memory (ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR
1-bit memory forms) operate on the memory operand itself. There is no separate data
register — the only registers involved are `An` (EA base) and `Xn` (EA index), which
is exactly what LEA/PEA already do today with 2 ports and 100% pass. These
instructions' `eu_seq.sv` decode blocks currently only implement `(An)/(An)+/-(An)`
(this session added `(d16,An)`/abs.W/abs.L for CLR/NEG/NOT/NEGX/TST — see Phase 80);
`(d8,An,Xn)` was explicitly left out and mislabeled as the arch gap. It isn't — it's
a missing `case (f_mode)` arm using the *existing* `dec_src_reg=An(rd_a)` /
`dec_dst_reg=Xn(rd_b)` pattern already used by LEA/PEA/ADDA-src-indexed.

**No port change required.** This is the same shape of fix as the Phase 80 EA-mode
extension, just adding one more mode. Affects: CLR.b (1306 remaining fails), NEG.w
(511), TST.b (1324), TAS (630), ASL.w (388), and presumably the untested
NEGX/NOT/CLR.w-l/NEG.b-l/TST.w-l/other-shift-size suites.

### Bucket B — Genuinely needs 3 operands, but the existing time-multiplex trick already works

`AND`/`OR`/`EOR`/`SUB`/`CMP` `Dn,(d8,An,Xn)` (register source written to an indexed
memory destination) and `ADDA`/`SUBA`/`CMPA` `(d8,An,Xn),An` (indexed memory source
combined with an address register) all use `dec_is_dyn_bit_idx` +
`dyn_bit_get_Dn`/`ex_dyn_bit_reg` — the same "read `An`+`Xn` for the EA over the bus
read phase, then swap `rd_b` to the 3rd register at the ack cycle" mechanism BCHG uses.
`AND.b` retested this session at **8064/8064 (100%)**, so this mechanism is not
fundamentally broken for this shape of instruction (source register value only
needed *after* the EA/bus phase completes — never simultaneously with `Xn`, so the
2-port swap is safe).

**No port change required here either.** **UPDATE (Phase 0.5, `plan.md`)**: confirmed —
OR.b/EOR.b/SUB.b/CMP.b and ADDA.w/SUBA.w/CMPA.w all retested at **100%**. Bucket B is
fully closed; the 2-port time-multiplex mechanism is solid for every instruction that
uses it this way.

### Bucket C — Confirmed broken, mechanism unclear, needs investigation

BCHG/BCLR/BSET `Dn,(d8,An,Xn)` — confirmed broken this session (`mem[addr]: no write
seen` on every indexed vector, 100% of BCHG/BCLR/BSET's remaining failures). This uses
the *identical* `dyn_bit_get_Dn` mechanism that works for AND, which is the strongest
evidence yet that BCHG's bug is instruction-specific, not structural. Candidates,
roughly in order of likelihood:
- Something in the bit-op RMW capture (`mem_rmw_wdata_r`/`mem_rmw_addr_r`,
  `mem_rmw_read_ack`) interacts differently with `dyn_bit_ea_r`'s pre-latch than the
  ALU-op RMW path does — bit ops are the only RMW consumer where the *read* result
  (`mem_rdata`) feeds directly into computing the write value (`bit_result` via
  `eu_bitops`) in the same cycle the register swap also fires, which AND's
  write-only-a-register-value path doesn't do.
- A timing edge specific to `dec_is_mem_rmw` + `dec_is_dyn_bit_idx` both being set
  (BCHG is RMW; AND `Dn,(d8,An,Xn)` write is *not* RMW — no memory read-before-write —
  so it doesn't share the exact same FSM path as BCHG despite reusing
  `dyn_bit_get_Dn`).

**This is the bucket the 3rd port would definitively fix** if it's needed at all, and
it's also the bucket worth a half-day of waveform debugging first, since if it's a
small BCHG-specific bug (most likely, given AND works), fixing that bug directly is
far cheaper than adding a register-file port and migrating N decode sites.

**UPDATE (Phase 0.5, `plan.md`)**: `MOVE Dn/An,(d8,An,Xi)` — the one MOVE sub-case that
actually shares BCHG's `dyn_bit_get_Dn` mechanism — turns out to be a red herring for
this bucket. Re-ran MOVE.b: 545 failures, **all TIMEOUT, zero involve a register
source** (`grep`ing for `MOVE.b D0,`/`A0,`-style failures returns nothing). The
register-swap form isn't broken — consistent with Bucket B, not Bucket C. Every single
MOVE.b indexed-dst failure is `dec_is_move_mm_idx_dst` (memory-to-memory move) with a
**source** addressing mode that was simply never decoded: `eu_seq.sv`'s
`f_move_dst_mode==3'b110` block only covers src = Dn/An (register), abs.W, abs.L,
`(d16,PC)`, and `#imm` — it's missing src = `(An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/
(d8,PC,Xn)`, and the failure list matches that gap exactly, mode for mode.

This is really a 5th bucket (or an extension of Bucket A): TIMEOUT-only, missing
decode coverage, and *not proven to need a 3rd port* — `move_mm`'s existing FSM
already does "read src (whatever addressing mode), then compute dst EA and write" as
two naturally sequential phases elsewhere (that's how the abs.W/abs.L/(d16,PC) src
cases already work with just 2 ports: `rd_a`=dst An, `rd_b`=dst Xn, with no register
needed for the abs/PC-relative src read). Adding a register-based src address
(`src_An`) is a 3rd register only if it's needed *simultaneously* with dst
`An`+`Xn` — and it isn't, since the src read fully completes before the dst EA is
ever computed. This looks like straightforward missing-decode work, same shape as
Phase 81, not a Bucket C/D problem. Not implemented this session — flagged for
whoever picks up the MOVE indexed-dst gap next.

### Bucket D — Never had decode, genuinely needs 3 operands, would benefit from the port

`CHK (d8,An,Xn),Dn` — CHK reads its upper bound from memory (`An`+`Xn` for indexed EA)
*and* separately needs `Dn` (the tested value) for the comparison. Currently
undecoded (Phase 80 explicitly skipped it, citing the arch gap). Unlike Bucket A, CHK
does need a real 3rd register value, and unlike Bucket B/C, there's no natural
"after the bus ack" sequencing available — CHK's non-indexed memory forms already use
`rd_a=An` + `rd_b=Dn` simultaneously (see `eu_seq.sv` ~2540), so adding `Xn` for the
indexed EA is the one case in this whole audit that unambiguously needs a 3rd port
(or an equivalent 2-cycle register-fetch scheme copied from the dyn_bit trick, which
would need its own new plumbing since CHK's existing memory-source path doesn't have
one).

---

## 2. Recommended sequencing

1. **Phase 0 — DONE (`plan.md §Phase 81`)**: added `(d8,An,Xn)` decode for Bucket A
   instructions (CLR/NEG/NOT/NEGX/TST/TAS/shift-memory), reusing the `An`(rd_a)/
   `Xn`(rd_b) pattern already proven by LEA/PEA. CLR.b/NEG.w/NOT.b/TST.b/TAS/ASL.w all
   confirmed at 100%, zero remaining fails. `make test` (32/32) and `make cosim_grp`
   (8/8) both still pass.
2. **Phase 0.5 — DONE**: swept OR.b/EOR.b/SUB.b/CMP.b and ADDA.w/SUBA.w/CMPA.w indexed
   forms — all 100%, Bucket B fully confirmed. Also split MOVE.b's indexed-dst
   failures: all 545 are TIMEOUT, zero involve the register-source form, all are
   missing decode for 6 source EA modes on `dec_is_move_mm_idx_dst`. This turned out
   not to be a Bucket C question at all — see the updated Bucket C section above.
3. **Phase 0.75 (targeted debug, moderate) — next up**: root-cause BCHG/BCLR/BSET's
   indexed-dst failure specifically — waveform one failing vector
   (e.g. `0d71 BCHG D6,(d8,A1,Xn)`) through the RMW read-ack/write-phase and compare
   against a working AND-indexed-dst vector to find the actual divergence. If this
   turns out to be a small, isolated bug (most likely, per every piece of evidence so
   far), fix it directly — no port needed for Bucket C after all.
4. **Phase X (not port-related, but worth doing)**: add the 6 missing source EA modes
   to `eu_seq.sv`'s `f_move_dst_mode==3'b110` block for MOVE indexed-dst — same shape
   of change as Phase 81, likely closes most of MOVE's remaining ~9% gap with no port.
5. **Phase 1+ (the 3rd port itself)**: at this point, only clearly required for CHK
   indexed (Bucket D). Worth it as a structural cleanup for Bucket C only if Phase
   0.75 finds the existing multi-cycle scheme too fragile to trust going forward even
   after the immediate bug is fixed — increasingly looking optional rather than
   required, the more of this gap turns out to be ordinary missing-feature work.
   Design below.

If you'd rather skip straight to the port regardless of Phase 0's findings (e.g.
because you want the cleaner single-cycle design on principle, not just to fix bugs),
that's a reasonable call too — say so and I'll scope Phase 1 as the primary work item
instead of the fallback.

---

## 3. Why a 3rd port is cheap here

`eu_regfile.sv` is **not** a synthesized multi-port SRAM/register-file macro. Storage
is a plain `logic [31:0] d_reg [0:7]` / `a_reg [0:6]` array of flops. Each read "port"
is just a combinational mux chain:

```systemverilog
assign rd_a_raw  = !rd_a_sel[3] ? d_reg[rd_a_sel[2:0]] :
                   (rd_a_sel != 4'd15) ? a_reg[rd_a_sel[2:0]] : a7_current;
assign rd_a_data = <size-extend rd_a_raw by rd_a_siz>;
```

A 3rd port (`rd_c_sel`/`rd_c_siz`/`rd_c_data`) is a straight copy of this block with a
new selector — no interaction with the write side, no arbitration, no extra flops.
Timing/area impact: a few more LUTs of 8:1 muxing, nothing that threatens the 4×
internal clock budget. This is the opposite of a general "does this design support
N-port register files" question — for this specific FF-array implementation, ports
are structurally free.

---

## 4. Design

### 4.1 `eu_regfile.sv`

Add, mirroring the existing `rd_a`/`rd_b` port pair exactly:

```systemverilog
input  logic [3:0]  rd_c_sel,
input  logic [1:0]  rd_c_siz,
output logic [31:0] rd_c_data,
```

Plus the matching `rd_c_raw`/`rd_c_is_addr` combinational block (copy-paste of the
`rd_a`/`rd_b` pattern, ~12 lines). No changes to the write side, A7 routing, or any
other logic.

### 4.2 `m68030_eu.sv`

Add `rd_c_sel`/`rd_c_siz`/`rd_c_data` wires; wire them straight through between the
`eu_seq` and `eu_regfile` instantiations, same as the existing `rd_a`/`rd_b` wiring
(2 more lines in the internal-wire block, 3 more port connections in each
instantiation).

### 4.3 `eu_seq.sv`

This is where the actual behavior change lives. Add `rd_c_sel`/`rd_c_siz`/`rd_c_data`
to the port list, then:

- **New `dec_*`/`ex_*` signals**: `dec_reads_c` / `ex_reads_c`? — actually simplest to
  follow the existing convention: a `dec_c_reg`/`ex_c_reg` (register selector) plus
  reuse of `dec_reads_dst`-style enable naming, e.g. `dec_reads_c`, mirroring how
  `dec_src_reg`/`dec_reads_src` and `dec_dst_reg`/`dec_reads_dst` already work. Thread
  through the `dec_*` → `ex_*` pipeline latch exactly like the existing `ex_dst_reg`
  plumbing (same two `always_ff` reset blocks that currently zero `ex_is_dyn_bit_idx`
  etc., plus the main latch block around line ~5956).
- **`rd_c_sel`/`rd_c_siz` drive**: a flat assign, no multi-way ternary needed the way
  `rd_a_sel`/`rd_b_sel` require today, *because* `rd_c` only exists to serve the
  handful of true-3-operand cases — it can default to `4'd0`/don't-care when unused.
  This is simpler than `rd_a`/`rd_b`'s mux chains, which have to arbitrate many modal
  overrides (CAS, CAS2, MOVEM, dyn_bit). `rd_c` starts with zero modal conflicts.
- **CHK indexed (Bucket D, the clear case)**: new decode arm for
  `f_mode==3'b110` in the CHK memory-source block (`eu_seq.sv` ~2531). Set
  `dec_src_reg={1,f_reg}` (An→rd_a), `dec_dst_reg=Xn` (→rd_b) for the EA exactly like
  BCHG's indexed EA setup, and **new**: `dec_c_reg={0,f_dn}` (tested value → rd_c),
  read simultaneously. `chk_below_w`/`chk_above_w`/`chk_z_w` (fixed this session in
  Phase 80) switch from consuming `rd_b_data` to consuming `rd_c_data` for the tested
  value in this one case (or, cleaner: always route the "tested value" through `rd_c`
  for every CHK form, register/imm/memory alike, so there's exactly one code path
  instead of a mode-conditional — worth considering during implementation, since it
  removes a special case rather than adding one).
- **If Phase 0.75 concludes BCHG/BCLR/BSET genuinely need the port** (rather than a
  local bug): replace `dyn_bit_get_Dn`'s cycle-delayed `rd_b_sel` override with a
  direct `rd_c_sel = {ex_dyn_bit_is_an, ex_dyn_bit_reg}` held constant across the
  whole RMW sequence. This removes the need for `dyn_bit_ea_r` (the EA pre-latch
  workaround) entirely, since `rd_b` would stay on `Xn` for the instruction's full
  lifetime and `ex_ea` would never glitch. Also removes `dyn_bit_get_Dn` as a concept
  for this instruction family — `bit_num`/`bit_dst` read `rd_c_data` instead of the
  time-multiplexed `rd_b_data`. This is a genuine simplification, not just a
  workaround for a workaround.
- **If MOVE `Dn/An→(d8,An,Xi)` needs it**: same treatment — `move_result_w`'s
  `ex_is_move_reg_idx_dst && dyn_bit_get_Dn` special case (eu_seq.sv ~6752) collapses
  to a plain `rd_c_data` read, and since there's no actual memory read dependency for
  a MOVE write, `dec_is_mem_rmw` could potentially be dropped for this instruction
  too (it was only ever set "so rd_a=An_base and rd_b=Xn" per the existing comment —
  a vehicle for the register dance, not a real RMW). That would shorten the bus cycle
  by removing the fake read phase. Worth confirming this doesn't have a subtle timing
  dependency elsewhere before removing it.

---

## 5. What does *not* need to change

- `AND`/`OR`/`EOR`/`SUB`/`CMP` `Dn,(d8,An,Xn)` — leave alone, already correct (pending
  Phase 0.5 confirming OR/EOR/SUB/CMP match AND's result).
- `ADDA`/`SUBA`/`CMPA` `(d8,An,Xn),An` — leave alone; the register swap happens after
  the memory read completes, never simultaneously with `Xn`, so no port needed.
- CAS/CAS2/MOVEM's use of `rd_a_sel`/`rd_b_sel` overrides — untouched, `rd_c` is a
  disjoint new signal.
- `eu_bitops`/`eu_alu`/`eu_shifter` etc. — none of these care which physical port
  their operand arrived on; they take flat `bit_dst`/`bit_num`/etc. inputs already.
  Only the `eu_seq.sv` mux feeding those inputs changes.

---

## 6. Regression risk

- `eu_regfile.sv` change is additive only (new port, existing ports/logic untouched)
  — near-zero risk of regressing anything not touching `rd_c`.
- `eu_seq.sv` changes are concentrated in the specific decode blocks being migrated
  (CHK indexed = new code; BCHG/BCLR/BSET dyn-idx and MOVE reg-idx-dst = modifying
  existing code paths that are *currently broken anyway* for the indexed case, so
  regression risk is bounded to "does this also break the already-working non-indexed
  forms of the same instructions" — needs the full BCHG/BCLR/BSET/MOVE Harte suites
  re-run, not just the indexed subset, after the change).
- `tb/eu_regfile_tb.sv` directly instantiates `eu_regfile` and will need `rd_c_sel`/
  `rd_c_siz`/`rd_c_data` wired (even if just tied to a default/unused value) plus
  ideally one new test case exercising the 3rd port read. `tb/eu_seq_tb.sv`,
  `tb/pipeline_tb.sv`, `tb/eu_tb.sv` also instantiate pieces of this chain — check each
  compiles cleanly with the new ports (Verilog tolerates unconnected inputs, but the
  new `eu_seq` port list changes need mirroring in any testbench that names ports
  explicitly rather than using `.*`).

---

## 7. Verification plan

Same pattern as Phase 80:
1. `make sim/harte_dat` rebuild after each RTL change.
2. Targeted Harte suite for the instruction just migrated (e.g. `CHK.json.gz` after
   the CHK indexed addition) — confirm the new indexed vectors pass and nothing else
   regresses (compare non-indexed pass count before/after).
3. `make test` (32/32 regression) after every change.
4. `make cosim_grp` (8/8 vs Musashi bus traces) after every change — this is the one
   most likely to catch a subtle bus-timing regression from touching `ex_ea`/RMW
   plumbing.
5. Full Harte sweep of every touched instruction family at the end (BCHG/BCLR/BSET,
   MOVE.b/w/l, CHK, and the Bucket A unary-op suites) to get final pass-rate numbers
   for `plan.md`.

---

## 8. Rough effort sizing

- Phase 0 (unary EA-mode decode, ~6-7 instruction families, same shape as Phase 80):
  similar scope to this session's Phase 80 work.
- Phase 0.5 (sweep + compare): a few Harte runs, no RTL.
- Phase 0.75 (BCHG root-cause): unpredictable — could be a one-line fix once found,
  or reveal something deeper. Budget for waveform-level debugging (GTKWave).
- Phase 1 (the port itself: `eu_regfile.sv` + `m68030_eu.sv` + testbench wiring):
  small, mechanical, low-risk — maybe an hour of careful editing + rebuild/retest.
- Phase 1+ (migrating CHK indexed, and BCHG/BCLR/BSET/MOVE indexed *if* Phase 0.75
  shows they need it): the bulk of the real work, concentrated in `eu_seq.sv`.

---

## Open questions for you

1. ~~Do you want Phase 0 (quick unary-op EA-mode wins) done first, or go straight to
   the 3rd port regardless of what Phase 0.75 finds?~~ Resolved — Phase 0 done, and
   0.5 further shrank the case for the port (MOVE's gap looks like missing decode too,
   not a port issue). Worth deciding now: still want Phase 0.75 (BCHG root-cause) and
   the Phase X MOVE EA-mode work before touching the register file at all, or do you
   want the port built regardless, now that CHK indexed is the only confirmed case for
   it?
2. For CHK indexed — fine to add `rd_c` as a CHK-only special case initially, or do
   you want it designed from the start as the general mechanism BCHG/MOVE would also
   migrate to (more upfront design, less rework later)?
3. Any objection to potentially dropping the fake RMW read phase for MOVE
   `Dn/An→(d8,An,Xi)` if it turns out to be pure vestigial scaffolding for the register
   dance (per §4.3)? That would change bus cycle count/timing for that one
   instruction form — worth flagging since this project cares about pin-exact cycle
   counts.

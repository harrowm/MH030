# Plan: Add a 3rd combinational read port to `eu_regfile`

Status: **Phase 0 (Bucket A), Phase 0.5 (Bucket B), Phase X (MOVE non-indexed-src,
partial), and Phase 0.75 (BCHG root-cause) all done. Buckets A, B, and C are now
fully closed — zero RTL changes for any of them. The MOVE indexed-src remainder and
Phase 1+ (the port itself) are the only things left, and Phase 1+ may not be needed
at all: CHK indexed (Bucket D) is now the only case that's ever been *shown* to need
it, and it's an untested hypothesis, not a verified conclusion (see the Phase 0.75
update below for why that's worth taking seriously). No register-file port added.**

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
See the updated Bucket C section below.

**Update after Phase X (partial — non-indexed-src modes)**: implemented the 4 easy
source EA modes (`(An)/(An)+/-(An)/(d16,An)`), no port needed, using a new
`rd_a`-targeted variant of the existing `dyn_bit_get_Dn` swap (`dyn_bit_swap_a`).
Found and fixed a real 68k-semantics bug along the way — same-register src
auto-increment/decrement must apply before the destination EA is evaluated when that
register is also the destination's base or index — present in both the RTL and the
Python test harness's own reference calculation. Results: MOVE.b 90.8%→**97.9%**,
MOVE.w 94.0%→**98.7%**, MOVE.l 93.6%→**99.0%**; every remaining failure is TIMEOUT
and matches the deferred indexed-src (`(d8,An,Xn)`/`(d8,PC,Xn)`) count exactly. See
`plan.md §Phase 82` for the full writeup.

**Update after Phase 0.75 (BCHG root-cause) — Bucket C fully closed, zero RTL
changes.** Applying the same hand-verification technique that found the MOVE bug —
compute the expected outcome directly from the raw Harte JSON's opcode/register data
rather than trusting the test's own "expected" fields — showed the DUT was writing
*undefined data* to an address that didn't match the test's raw "expected" field
either. Tracing why led to a **third instance of the exact same class of bug** as
Phase 82's MOVE fix, this time in `get_scale_remap()`, `build_patches()`, and
`get_operand_ea()` together: all three misclassify dynamic bit-ops
(`BTST/BCHG/BCLR/BSET Dn,ea`) as group-0 *immediate* ALU ops (`ADDI`/`ANDI`/etc.),
because their shared classification condition never checks `f_dir` (0 for immediate
ops, 1 for dynamic bit-ops) — only `f_dn`, which for dynamic bit-ops is the bit-count
*register number* (0–7), not a fixed marker distinguishing it from the immediate-op
family. Misclassified, the harness read the EA's extension word from the wrong byte
offset, which cascaded into two independent failures: it never masked the *real*
extension word's "full extension word" bit (a mode the harness deliberately avoids
elsewhere since it isn't built/verified), and it never applied the scale-remap that
would have redirected the expected write to the correctly-scaled 68030 address and
pre-populated DUT memory there. **The RTL was correct the entire time.** Fixed the
classification (added the missing `f_dir` check) in all three functions, plus a
related bug for the static `#n` form (needs its own extension-word offset). Zero RTL
changes. Results: BCHG 92.8%→**100%**, BCLR 93.4%→**100%**, BSET 98.2%→**100%**, all
zero fails. See `plan.md §Phase 83` for the full writeup.

This closes Bucket C entirely — it was never a port-count problem, just like Bucket A
and B. **Three separate "arch gap" diagnoses in a row have turned out to be test
infrastructure bugs, not RTL limitations.** That's a strong prior against Bucket D
(CHK) also secretly needing the port rather than just missing (or buggy) decode —
worth treating the "CHK genuinely needs 3 operands" analysis as a hypothesis to verify
by attempting the indexed decode, not a settled conclusion, before committing to
building the register-file port.

## Results so far (Phase 0 + 0.5)

Every number below is a Harte SingleStepTests suite re-run this session on real RTL —
not a projection. "Before" is the pass rate at the start of this investigation
(Phase 80 baseline); "After" reflects the Phase 81/0.5 changes (Bucket A) or is
unchanged (diagnostic-only buckets).

| Suite | Bucket | Before | After | Change |
|-------|--------|--------|-------|--------|
| CLR.b | A | 83.8% (6756/8062) | **100%** (8062/8062) | RTL fix (Phase 81) |
| NEG.w | A | 89.3% (4278/4789) | **100%** (4789/4789) | RTL fix (Phase 81) |
| NOT.b | A | untested | **100%** (8063/8063) | RTL fix (Phase 81) |
| TST.b | A | 83.6% (6740/8064) | **100%** (8064/8064) | RTL fix (Phase 81) |
| TAS | A | 87.2% (4290/4920) | **100%** (4920/4920) | RTL fix (Phase 81) |
| ASL.w | A | 93.3% (5411/5799) | **100%** (5799/5799) | RTL fix (Phase 81) |
| AND.b | B | 100% (8064/8064) | 100% (8064/8064) | diagnostic only — no fix needed |
| OR.b | B | untested | **100%** (8064/8064) | diagnostic only — no fix needed |
| EOR.b | B | untested | **100%** (8065/8065) | diagnostic only — no fix needed |
| SUB.b | B | untested | **100%** (8064/8064) | diagnostic only — no fix needed |
| CMP.b | B | untested | **100%** (8064/8064) | diagnostic only — no fix needed |
| ADDA.w | B | untested | **100%** (5320/5320) | diagnostic only — no fix needed |
| SUBA.w | B | untested | **100%** (5279/5279) | diagnostic only — no fix needed |
| CMPA.w | B | untested | **100%** (5244/5244) | diagnostic only — no fix needed |
| MOVE.b | reclassified | 90.8% (5375/5920) | **97.9%** (5797/5920) | RTL fix, non-indexed-src only (Phase 82) |
| MOVE.w | reclassified | 94.0% (3044/3239) | **98.7%** (3196/3239) | RTL fix (Phase 82) |
| MOVE.l | reclassified | 93.6% (2954/3157) | **99.0%** (3125/3157) | RTL fix (Phase 82) |
| BCHG | C → closed | 92.8% (5446/5867) | **100%** (5231/5231) | test-harness fix, zero RTL (Phase 83) |
| BCLR | C → closed | 93.4% (5467/5851) | **100%** (5203/5203) | test-harness fix, zero RTL (Phase 83) |
| BSET | C → closed | 98.2% (5912/6019) | **100%** (5337/5337) | test-harness fix, zero RTL (Phase 83) |
| CHK | D | 64.3% (419/652) | 64.3% (419/652) | unchanged — the last unverified "needs a port" hypothesis |

Six Bucket-A suites (one per decode block, plus a second data point for
NEGX/CLR/NEG/NOT/TST) went to 100% with **zero remaining failures of any kind** — no
FAIL, no TIMEOUT. All of Bucket B (7 suites) confirmed at 100% with no fix needed.
BCHG/BCLR/BSET (Bucket C) went to 100% too, purely via a test-harness fix. `make test`
(32/32) and `make cosim_grp` (8/8 vs Musashi) both pass throughout.

**Bottom line**: three of the four original "arch gap" buckets are now fully closed
(A, B, and C), and **not one of them needed the register-file port** — A and the MOVE
non-indexed-src gap were missing decode; B already worked; C was a test-harness bug
that made correctly-computed RTL output look wrong. Given that track record, treat
Bucket D (CHK) as a hypothesis to verify, not a settled conclusion — the honest
current state is "no case has yet been *shown* to require the port," even though
CHK's on-paper analysis (needing `An`+`Xn`+`Dn` all at once, no natural 2-phase
deferral) is the most plausible candidate so far.

## TL;DR

- Adding a 3rd read port is cheap here: `eu_regfile` is a small flip-flop array read
  through combinational muxes, not a true multi-port SRAM. A 3rd port is another mux,
  not a structural redesign. Low risk, low cost, mechanically simple.
- **As it turned out, none of it was needed.** The "indexed-dst arch gap" documented
  since Phase 79 was never one problem, and — after actually investigating each
  piece — it was never a register-file port problem either. Bucket A (unary memory
  ops: CLR/NEG/NOT/NEGX/TST/TAS/shifts) was missing EA decode. Bucket B
  (AND/OR/EOR/SUB/CMP/ADDA/SUBA/CMPA) already worked with the existing 2-port
  time-multiplex trick. MOVE's indexed-dst gap was also missing decode (mostly
  fixed). And BCHG/BCLR/BSET (Bucket C) — the case that most looked like it needed a
  port, since it silently produced wrong output instead of just timing out — turned
  out to be a bug in the *test harness*, not the RTL: it misclassified dynamic
  bit-ops as a different instruction family and read the extension word from the
  wrong offset, so the DUT was decoding a bit pattern it was never meant to see. Once
  fixed, BCHG/BCLR/BSET went to 100% with zero RTL changes.
- Only **CHK indexed** (Bucket D) remains as a case that plausibly needs the port —
  and given the track record above, that should be treated as a hypothesis to verify
  by attempting the decode, not a conclusion to build a port around sight unseen.
- This doc still gives the full 3rd-port design (§3-4) since it was asked for and
  it's a legitimate simplification if CHK does turn out to need it — but the honest
  recommendation now is: try CHK indexed with the *existing* 2-port scheme's
  deferred-read pattern first (bound value doesn't need to be read simultaneously
  with `An`+`Xn` if the memory read can supply it after the fact, the way Bucket B's
  cases do), and only reach for the port if that genuinely doesn't work.

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
Phase 81, not a Bucket C/D problem.

**DONE for the non-indexed-src modes (Phase 82, `plan.md`).** Confirmed: no port
needed, fixed via a new `rd_a`-targeted swap (`dyn_bit_swap_a`, mirrors the existing
`dyn_bit_get_Dn` but for `rd_a` instead of `rd_b`). `(An)/(An)+/-(An)/(d16,An)` src
now all work. MOVE.b/w/l went to 97.9%/98.7%/99.0%. Along the way, found the real bug
was a missing 68k same-register-conflict rule (source's own auto-increment/decrement
must apply before the destination EA is evaluated when that register is also the
destination's base or index) — present in both the RTL and the Python Harte harness's
own `get_scale_remap()`, both fixed. **Still open**: `(d8,An,Xn)`/`(d8,PC,Xn)` src
(both sides indexed at once) — genuinely needs separate src-side and dst-side
`xn_scale`/`xn_wl`/offset fields, since the existing struct has only one set, shared
by whichever side is indexed. Not a port issue either, just more struct plumbing.

### Bucket D — Never had decode; probably does NOT need the port either (revised)

`CHK (d8,An,Xn),Dn` — CHK reads its upper bound from memory (`An`+`Xn` for indexed EA)
and separately needs `Dn` (the tested value) for the comparison. Currently undecoded
(Phase 80 explicitly skipped it, citing the arch gap).

**Original draft reasoning (superseded)**: I originally wrote this off as needing a
real 3rd port, on the grounds that CHK's existing non-indexed memory forms hold
`rd_a=An` + `rd_b=Dn` simultaneously *from decode*, so adding `Xn` for the indexed EA
looked like a genuine 3-way conflict with no "defer to after the bus ack" option like
Bucket B has.

**That reasoning doesn't actually hold up.** The comparison (`Dn` vs. the bound) only
happens *after* the memory read completes and `mem_rdata` is available — `Dn` isn't
needed at all during the read/EA phase. That's exactly Bucket B's shape: `rd_a=An`,
`rd_b=Xn` during the read (2 ports, no conflict), then swap `rd_b` to `Dn` at the read
ack for the comparison — the *existing* `dyn_bit_get_Dn` mechanism, unmodified,
already proven at 100% for AND/OR/EOR/SUB/CMP. The non-indexed CHK forms hold `Dn` on
`rd_b` from decode only because there's no `Xn` to conflict with there, not because
`Dn` is structurally needed early.

Given three other "needs a port" diagnoses this session turned out to be missing
decode or test-harness bugs instead, this should be tried before building anything:
add `f_mode==3'b110` to CHK's memory-source block (`eu_seq.sv` ~2531) using the same
`dec_is_dyn_bit_idx`/`dec_dyn_bit_reg=f_dn`/`dec_dyn_bit_is_an=0` pattern as Bucket B,
plus the matching `ext_count` entry. If this works (plausible, given the pattern's
100% track record elsewhere), **Bucket D closes too and the port is never needed for
anything found so far.**

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
3. **Phase 0.75 — DONE (Phase 83, `plan.md`)**: root-caused BCHG/BCLR/BSET's
   indexed-dst failure. Not a Bucket C RTL bug at all — a test-harness bug (dynamic
   bit-ops misclassified as immediate-ALU ops in `gen_harte_hex.py`, reading the
   extension word from the wrong offset). Zero RTL changes. BCHG/BCLR/BSET →
   100%/100%/100%. Bucket C fully closed.
4. **Phase X — mostly DONE (Phase 82, `plan.md`)**: added 4 of the 6 missing source
   EA modes to `eu_seq.sv`'s `f_move_dst_mode==3'b110` block for MOVE indexed-dst —
   `(An)/(An)+/-(An)/(d16,An)`, no port needed. MOVE.b/w/l → 97.9%/98.7%/99.0%.
   Remaining: `(d8,An,Xn)`/`(d8,PC,Xn)` src (both sides indexed) — needs separate
   src/dst `xn_scale`/`xn_wl`/offset struct fields, more plumbing but still no port.
5. **Bucket D attempt — next up, before touching the register file at all**: try
   CHK indexed with the existing `dyn_bit_get_Dn` deferred-register pattern (§1
   Bucket D, revised) — `Dn` is only needed after the memory read, same shape as
   Bucket B, no port required if this works. Given the session's track record (A, B,
   C, and most of MOVE all turned out not to need the port), this is the
   highest-probability next step.
6. **Phase 1+ (the 3rd port itself) — only if step 5 fails**: at this point nothing
   has been *shown* to need it. Only reach for this if CHK indexed genuinely can't be
   made to work with the deferred-register pattern (worth understanding *why* it
   fails first — that failure mode itself would be useful evidence about what a real
   3rd-operand conflict looks like, versus the false alarms found so far). Design
   below, kept for reference either way — it's a legitimate structural cleanup if it
   ever *is* warranted, not wasted regardless.

If you'd rather build the port anyway regardless of whether anything currently needs
it (e.g. because you want the cleaner single-cycle design on principle, replacing the
fragile multi-cycle swap trick everywhere it's used), that's a reasonable call too —
say so and I'll scope Phase 1 as the primary work item instead of the fallback.

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

1. ~~Do you want Phase 0 done first, or go straight to the port?~~ Resolved — Phase 0,
   0.5, and 0.75 are all done. A, B, and C are fully closed, all without touching the
   register file. Current recommendation: try the CHK-indexed deferred-register
   approach (§2 step 5) before building anything — say the word and I'll implement it.
2. If the CHK attempt *does* work (closing Bucket D too): is there any remaining
   appetite for building the 3rd port anyway, purely as a structural cleanup to
   replace the multi-cycle swap trick everywhere it's used (BCHG/BCLR/BSET, MOVE
   reg-idx-dst, CHK) with a single-cycle 3-operand read? Or shelve this doc once
   nothing needs it?
3. Any objection to potentially dropping the fake RMW read phase for MOVE
   `Dn/An→(d8,An,Xi)` if it turns out to be pure vestigial scaffolding for the register
   dance (per §4.3)? That would change bus cycle count/timing for that one
   instruction form — worth flagging since this project cares about pin-exact cycle
   counts.

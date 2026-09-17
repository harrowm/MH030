# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cycle-accurate Motorola MC68030 CPU implementation in SystemVerilog/Verilog. The goal is pin-level cycle accuracy: every external bus signal (AS, DS, RW, FC, SIZ, etc.) must assert and deassert on the exact S-state cycle the real silicon does. `output.txt` contains the architectural design conversation that established the requirements and module structure.

## Design Constraints

**Clock strategy**: Run the Verilog design at **4× the external bus frequency** (e.g., 100 MHz internal for 25 MHz bus). This gives 4 clean ticks per external clock cycle to map S-states without relying on `negedge` triggers. All logic must be synchronous — no latches, no asynchronous resets.

**No cheating cycles**: If an instruction takes N cycles on real silicon, the FSM must take exactly N cycles. Do not collapse or optimize timing.

**External inputs are asynchronous**: `BERR`, `BR`, `IPL`, `HALT`, `DSACK0`, `DSACK1`, `STERM` must pass through 2-stage synchronizer flip-flops before any logic uses them. (The 68030 uses DSACK, not DTACK. `VPA`/`VMA`/`VSTB`/E-clock — the 68000/68010's own legacy 6800-style synchronous-peripheral mechanism — do not exist on the 68030 at all; confirmed by direct search of MC68030UM.pdf and removed from the RTL, Phase 248 item #6.)

**Single DS, not LDS/UDS**: The 68030 is a true 32-bit processor and uses a single `/DS` (Data Strobe) pin. The `/LDS`+`/UDS` pair belongs to the 68000/68010 (16-bit bus). Byte-lane selection is conveyed to peripherals via `SIZ[1:0]` + `A[1:0]` — `SIZ0`/`SIZ1` are **outputs** from the chip, not inputs. Bus width is determined dynamically per-cycle by the DSACK0/1 response encoding. `biu_byte_lane_ctrl` steers write data to the correct bus lane so a peripheral receives the byte on the right D[31:0] pin.

**Write-through D-Cache**: The 68030 D-cache is write-through only. Every write goes to the external bus simultaneously. No write-back cycles.

## Module Hierarchy

```
m68030_top
├── m68030_biu          Bus Interface Unit (most critical; drives external pins)
│   ├── biu_arbiter         Priority: MMU > EU > IFU > External DMA
│   ├── biu_cycle_generator S-state FSM (~2000 lines; one branch per cycle type)
│   ├── biu_pin_driver      Output pin control + tri-state management
│   ├── biu_byte_lane_ctrl  Write-data steering + byte-enable mask from SIZ+A[1:0]
│   ├── biu_burst_ctrl      Burst linefill (+ MOVE16's own dead burst-write
│   │                       stub, retained but unreachable — Phase 250 F8)
│   ├── biu_error_handler   BERR detection, timeout, fault data capture
│   ├── biu_cache_interface Cache hit/miss signaling and CBREQ/CBACK handshake
│   ├── biu_mmu_interface   MMU table-walk bus hijack port
│   └── biu_config          Reset sequencing; tri-state release timing
├── m68030_ifu          Instruction Fetch Unit + 4-word prefetch queue
├── m68030_eu           Execution Unit (ALU, AGU, barrel shifter, register file)
├── m68030_mmu          MMU (TLB, 3-level table walker, TT0/TT1, CRP/SRP)
├── m68030_cache        I-Cache + D-Cache (256 bytes each, direct-mapped, 16-byte lines)
├── m68030_seq          Micro-sequencer / decode (pipeline hazard detection, µ-op dispatch)
└── m68030_exc          Exception/interrupt controller (all 9 stack frame formats)
```

Keep each module under ~3000 lines. Do not put everything in one file.

## BIU Cycle Types

`biu_cycle_generator` must implement a separate S-state sequence for each of these cycle types:

- Normal read / Normal write (S0–S7)
- RMW read → RMW write (no bus release between phases; AS stays asserted or reasserts immediately)
- Burst read — first longword (AS asserts) vs. subsequent longwords (AS does not reassert; only DS toggles; address increments at specific S-state)
- Interrupt Acknowledge — FC=111 (CPU Space), AS and DS both assert; address bus encodes interrupt level in A[3:1] with A[31:4]=all-1s ($FFFFFFF2–$FFFFFFFE for levels 1–7); peripheral responds with DSACK and drives vector on D[7:0]
- Coprocessor interface (FPU) — FC=111 (CPU Space) cycles with A[19:16]=0010 identifying CPU Space type 2 (coprocessor access, distinct from IACK's own A[19:16]=1111 pattern); A[15:13] selects the CpID (which of up to 7 coprocessors, matching the F-line operation word's own bits[11:9] — confirmed against MC68030UM.pdf Figure 10-3/10-1 during Phase 157's own research, correcting an earlier "A[15:13] = primitive type" description here); A[4:0] selects a specific Coprocessor Interface Register (CIR) within that coprocessor's own register block (Figure 10-5: Response/Control/Save/Restore/Operation-Word/Command/Condition/Operand/Register-Select/Instruction-Address/Operand-Address). The response primitive code itself is a *data value* read back from the Response CIR (offset 0x00), not encoded in the address at all.
- CAS2 dual-address atomic lock (most complex: 4 bus cycles without releasing the bus)
- MOVEP byte-interleaved (individual byte cycles, address increments by 2)

**Coprocessor conditional instructions (cpBcc/cpDBcc/cpScc/cpTRAPcc) —
IN PROGRESS, cpBcc/cpDBcc done (Phase 281, `wobbly-honking-cascade.md`
cross-repo item)**: Phase 157/199 implemented the CIR access bus
protocol itself and cpSAVE/cpRESTORE's own full state-transfer
handshake. This item was originally documented here as a deliberate
scope boundary (Phase 248 item #7) because meaningfully testing it
needs a real attached coprocessor evaluating genuine condition
predicates — MH882 (`/Users/malcolm/MH882`, this project's own
standalone MC68881/68882 companion FPU implementation), once its own
Phase 10 gave it real 32-predicate Condition CIR logic, is exactly that
missing piece, closing the original blocker. **cpBcc.W/.L and cpDBcc
are now decoded and implemented** (`dec_is_cpbcc`/`dec_is_cpdbcc`,
`rtl/eu_seq_decode.svh`; the shared `cpcc_*` CIR dispatch FSM,
`rtl/eu_seq_execute.svh` — cpDBcc reuses this FSM completely unchanged
from cpBcc, only its own completion action differs) — see `plan.md`
Phase 281 (both sub-phases) for the full protocol/encoding derivation,
the response-word bit-layout resolution (read directly from MH882's
own tested `response_word()` rather than the manual's self-
contradictory OCR'd prose), and cpDBcc's own genuine new problem (a
dedicated FSM-completion register-write port for Dn's decrement, since
its timing can't go through the normal single-cycle ALU→WB pipeline
plain DBcc uses). Coprocessor Protocol Violation (vector 13,
MC68030UM.pdf §10.5.1.1/§10.5.4) is likewise wired end-to-end
(`eu_cpviol_req`, `m68030_exc.sv`'s new `VEC_CPVIOL`) — mirroring
`eu_fmt_err_req`'s existing shape — but not yet directly tested (no
dedicated coverage of an unrecognized primitive triggering it yet).
Real cpScc and cpTRAPcc remain NOT YET implemented (confirmed via grep
— zero occurrences of either mnemonic anywhere in `rtl/`) — see
`plan.md` Phase 281's own "Remaining sub-phases" for the planned order
(cpScc next, Dn-direct/simple-EA-only first, matching this project's
established "non-indexed EA first" precedent; cpTRAPcc reuses the
existing `dec_is_trapv`/`eu_trapv_req` path directly; dedicated
Protocol Violation coverage last).

## S-State Signal Timing (Critical)

**Corrected against MC68030UM.pdf Section 7.3.1/7.3.2/7.3.3 directly** (a
later investigation phase found the table below — and the RTL's own
matching 8-state-per-cycle convention — trace back to `output.txt`'s
original, never-manual-verified design conversation, which asserted "if
you assert AS and DS in the same phase, you violate the datasheet" and
elsewhere used `ext_lds_n`/`ext_uds_n`, the 68000's own split byte
strobes — the same 68000-vs-68030 conflation this file already had to
correct once for the LDS/UDS-vs-single-DS question itself. The real
datasheet's own text does not support the 8-state, staggered-AS/DS
model for every cycle type):

**Real 68030 read cycle — 6 states (S0-S5), exactly 3 clocks, 0 wait states:**

| S-State | Action |
|---------|--------|
| S0 | Drive Address, FC, SIZ, R/W; **assert ECS** (same state as the address) |
| S1 | **Assert AS and DS together** (same state); negate ECS |
| S2 | Assert DBEN; device presents data + asserts DSACKx |
| S3 | DSACKx recognized (by end of S2) → data latched next falling edge, cycle terminates; else insert wait states instead of proceeding to S4/S5 |
| S4 | Sample CIIN; data latched at end of S4 |
| S5 | Negate AS, DS, DBEN (address/data hold time) — **next cycle's S0 begins immediately, zero idle time** (Figure 7-25 shows chained read-write-write-read cycles with no gap) |

**Real 68030 write cycle — also 6 states (S0-S5), 3 clocks, but AS and DS
do NOT assert together** (a real, necessary difference from reads, not
an implementation artifact — DS's job is "data is now stable on the
bus," which isn't true until S2 has placed it there):

| S-State | Action |
|---------|--------|
| S0 | Drive Address, FC, SIZ, R/W=write; assert ECS/OCS |
| S1 | Assert AS and DBEN; negate ECS |
| S2 | Place write data on D0-D31; **sample DSACKx at the end of S2** |
| S3 | Assert DS ("indicating the data is stable on the data bus") |
| S4 | No new control signals |
| S5 | Negate AS and DS (address/data hold time) — next cycle's S0 immediate |

RMW cycles (`RMC` asserted throughout): the read phase's own State 0/1
match the plain read cycle exactly (AS+DS together at S1); the write
phase matches the plain write cycle's own S1/S3 stagger by the same
symmetry — **confirmed directly against MC68030UM.pdf Section 7.3.3**
(Phase 207, deferred-items closure Stage 1): real RMW is a 12-state
cycle (S0-S11), with S6-S11 identical in shape to an ordinary write
cycle (ECS+addr, AS+DBEN, data placed, DS asserted, negate).

**AS/DS# genuinely negate between the read and write phases, then
reassert for the write (Phase 250 F1, corrects the claim this section
used to make)** — confirmed by visually inspecting both Figure 7-29
(Asynchronous RMW Flowchart) and Figure 7-35 (Synchronous RMW Flowchart)
directly, not just OCR'd text: the read-completion box explicitly reads
"...Negate AS and DS..." and the write-start box explicitly reads
"...Assert AS..." (a fresh ECS+AS dispatch, same shape as starting any
new bus cycle) — independently in BOTH flowcharts, both of which also
explicitly cover CAS2's own chained sub-cycles via the identical
protocol. Only `RMC`/bus arbitration (the real "indivisible operation"
guarantee — bus *ownership* never releases) stays continuous; the AS/DS
*pins* toggle. A prior derivation here (Phases 108-114/207, generalized
to CAS2, then reused by Phase 242's CAS bus-lock fix) held AS
continuously instead, based on a misapplied quote — direct full-text
search confirms "maintains AS, DS...throughout" appears exactly once in
the whole manual, describing **Burst Mode's own State 3** (§7.3.7), a
different cycle type, not RMW/CAS/CAS2 at all. `biu_cycle_gen.sv`'s
`rmw_as_hold`/`cas2_as_hold`/`cas_as_hold` overrides (which suppressed
the state machine's own otherwise-correct natural negate/reassert
behavior) were removed; `tb/biu_tb.sv`'s P15-1 and
`tb/stall_fsm_tb.sv`'s AS-LOCK tests were rewritten to assert the
corrected behavior (AS negates twice across CAS's own read+write, not
once) — full mandatory gate clean, Harte bit-identical to baseline.

**This has since been fixed in full** (the RTL originally used the wrong
8-state-per-cycle-type model described above; see CLAUDE.md.old for the
complete derivations). `biu_cycle_gen.sv`'s ordinary READ, WRITE, RMW,
IACK, and the SSP/PC init-fetch sequence were each independently
compressed to match the manual's real state count/sequence: READ skips
S1/S3 (6 states, matching the table above exactly); WRITE and RMW's
write phase skip S1 and eliminate S7 (6 states, AS/DS staggered as
required); IACK and init reuse the plain-read skip (they are
architecturally ordinary reads); RMW's read phase matches ordinary READ.
Burst mode and CAS2 don't reduce to a literal 6 states each (burst's
first beat is 4 states/2 clocks matching a synchronous read, each
subsequent beat only 2; CAS2 chains 4 RMW-shaped sub-cycles) but were
independently redesigned against the manual and compressed the same way,
in the process finding and fixing one real pin-continuity bug (burst's
DS# was dropping between beats instead of staying held, contradicting
the manual's own explicit "maintains AS, DS... throughout" text — this
part of the original finding was correct, since that quote genuinely
does describe burst mode; CAS2's own analogous "fix" at the same time
was not, see the AS/DS# correction above). The only remaining,
confirmed-unavoidable gap to real silicon's absolute clock count is a
small, structural per-cycle dispatch floor (the `ST_IDLE`-to-`S0`
hand-off) and burst's own already-manual-derived internal state count —
both investigated and found genuinely load-bearing, not implementation
overhead.

**IACK note**: IACK is architecturally a plain read cycle (FC=111, CPU
Space) — AS and DS assert together at S1, exactly as the read table
above. The peripheral identifies the cycle via FC+AS+DS and drives the
vector on D[7:0].

## Function Code (FC) Values

| FC[2:0] | Meaning |
|---------|---------|
| 001     | User Data Space |
| 010     | User Program Space |
| 101     | Supervisor Data Space |
| 110     | Supervisor Program Space |
| 111     | CPU Space (IACK when A[19:16]=1111; coprocessor when A[19:16]=0010) |
| 000,011,100 | Undefined / reserved |

FC must transition at the same time as the address, never mid-cycle.

**CPU Space sub-types** (distinguished by A[19:16]):
- `1111` — Interrupt Acknowledge (level in A[3:1])
- `0010` — Coprocessor communication (FPU: A[15:13]=CpID, A[4:0]=CIR — see the Design Constraints section above for the full, corrected breakdown)

## Exception Stack Frame Formats

The EU + BIU together must produce all 8 real 68030 frame formats (a 9th,
"Format $3," was previously documented here too — see the removal note
below):

| Format | Size | Trigger |
|--------|------|---------|
| $0 | 4 words | Most exceptions |
| $1 | 4 words | Throwaway frame pushed to ISP when an interrupt is taken with M=1 (§8.1.9) |
| $2 | 6 words | TRAPV, CHK, CHK2, Zero Divide, MMU Configuration |
| $4 | 8 words | FPU post-instruction (not implemented — unreachable) |
| $8 | 29 words | FPU pre-instruction (not implemented — unreachable) |
| $9 | 10 words | Coprocessor Mid-Instruction (not implemented — see Coprocessor conditional instructions note below) |
| $A | 16 words | Bus error/address error at instruction boundary (incl. MMU faults) |
| $B | 46 words | Bus error/address error mid-instruction-execution (incl. MMU faults) |

(Phase 250 F5: $9 was previously documented here as "12 words, MMU short
bus fault" — confirmed against MC68030UM.pdf Table 8-6 this format doesn't
exist; real Format $9 is the unrelated Coprocessor Mid-Instruction frame.
MMU-detected bus faults correctly use the ordinary $A/$B like any other
bus error, distinguished by R/W, not a dedicated format code.)

**"Format $3" removed (Phase 250, frame layout fix)**: this file used to
list "$3, 8 words, Address Error" as a 9th format. Confirmed against
MC68030UM.pdf this never existed on real silicon — Table 8-6 has no $3
entry in either sheet, and §8.1.3 states plainly that Address Error uses
"either a short or long bus fault stack frame" — the same $A/$B selection
Bus Error already uses. The same fabrication shape already found once for
the old "$9, MMU short bus fault" claim above. Address errors now select
$A directly (this project's own address-error detection is instruction-
fetch-only; EU-side data address errors are computed but never wired into
the exception controller at all — a separate, pre-existing, out-of-scope
gap).

**Byte layout (Phase 250, frame layout fix)**: every format's own first 8
bytes follow the same real layout, confirmed directly against Table 8-6/
Figure 4-1 (identical across every format shown, not previously
independently verified — no existing test inspected raw frame memory):
SR alone at SP+0, PC (32-bit) at SP+2, the format/vector word alone at
SP+6. As two longword bus writes (this RTL's own `exc_siz` is fixed at
longword): `{SR,PC[31:16]}` then `{PC[15:0],fmtvec}` — **not**
`{fmtvec,SR}` then `PC`, which every frame format previously implemented
(an RTE-consistent but real-silicon-wrong layout, since the same code
both pushes and later pops its own frames — internally self-consistent,
so it never surfaced as an observable failure). `$A`/`$B`'s own longer
tail also needed remapping to match the real diagram: Special Status Word
moved from its old (wrong) position to SP+$A, Data Cycle Fault Address
(this project's own `fault_addr`) moved from SP+8 to its real SP+$10, and
Data Output Buffer moved from SP+$10 to its real SP+$18 — Instruction
Pipe Stage C/B (SP+$C/$E) have no real content this project tracks and
stay zero, matching the existing "FPU not implemented, internal pipeline
state left zero" precedent. `$2`/`$9`'s own Instruction Address field
(SP+8) was already correctly positioned and needed no change (naturally
longword-aligned regardless of the prefix fix). RTE's own two-phase read
(`eu_seq_execute.svh`) reads the identical new longword pairs back in the
same new order.

The BIU must capture and hold (fault address, data, FC, R/W, internal pipeline state) at the moment of fault to populate these frames.

## Verification Approach

**Trace-driven co-simulation** is the intended strategy:
1. Run binaries in WinUAE or Musashi (cycle-accurate 68030 software emulator) and log every bus transaction.
2. Run the same binary through the Verilog sim (Verilator preferred for speed).
3. Diff the bus logs cycle-by-cycle. Any divergence is a failure.

**Tools**: Verilator (simulation), GTKWave (waveform debug), Python (trace parser + testbench generator), ModelSim/Questa (formal assertions).

**Completed phases** (do not re-implement) — condensed summary. **Full phase-by-phase
derivations are archived verbatim across three files — read them directly if you need the
detailed history behind any of the summary points below** (e.g. "why is X done this way,"
"what exactly did phase N find"): `CLAUDE.md.old` (Phases 1-224, from the file's original
Phase 225 condensation), `CLAUDE.md.old2` (Phases 225-273, from this file's second
condensation), and `plan.md`/`plan.md.old`/`plan.md.old2` (the parallel plan-file history,
archived on the same schedule). This file has now been condensed twice — first at Phase 225
(~670 lines/~513KB → compact summary, mirroring the `plan.md` → `plan.md.old` precedent set
at that project's own Phase 162), then again here (Phase 273+, ~2827 lines/~196KB → this
summary) once every major initiative below had closed with no outstanding plan, to stop
paying the full historical narrative's token cost on every future session.

**Core build-out (Phases 1-76)**: BIU (bus interface, S-state FSM, sizing, byte-lane
steering, burst/MOVE16, error handling, cache/MMU interface ports), EU (regfile, ALU,
shifter, mul/div, BCD/bitops, AGU), IFU (prefetch queue), sequencer/decode, exception
controller (all 9 frame formats), MMU (ATC/table-walker skeleton), I+D cache skeleton —
built, wired into `m68030_top`, and integration-tested (`cosim_grp_tb.sv`, 8 opcode-group
comparisons vs Musashi).

**Full ISA correctness via Tom Harte SingleStepTests (Phases 77-112)**: built the cosim
harness (`.dat` replay, then the full 124-suite Harte corpus with parser/hex-generator/
diff-tool scripts), then root-caused every non-100% suite one at a time. **Every one of the
124 Harte suites is now either 100% pass or one of exactly two permanent, documented,
unfixable non-bugs**: ASL.b's 2 corpus data anomalies (a Tom Harte corpus data error, not
an RTL bug — Phase 87) and TRAP/TRAPV-taken's exception-frame-width divergence (our
correct 68030 8-word frame vs. the 68000-captured reference's native 3-word frame — an
inherent, permanent 68000-vs-68030 architectural difference, not fixable without building
the wrong chip).

**Memory-indirect / full-format EA rollout (Phases 115-149, closed in full at Phase 251)**:
extended indexed/memory-indirect addressing (`(d8,An,Xn)`, `([bd,An],Xn,od)`, full-format
base/outer displacements) across every instruction family that needed it — MOVE, ALU-mem-
src, dynamic bit-ops, Scc/CHK/ADDQ-SUBQ/MOVE-SR-CCR, LEA/JMP/JSR/PEA (Phases 236-237),
general ALU-EA + CMP2/CHK2 (Phases 243-244), TAS + Scc (Phase 245, finding a real Scc-
modeled-as-RMW bug along the way), and finally MOVEM (Phase 251, the last family) — plus
long (32-bit) displacements and a 7th IFU prefetch-queue word to support them all. Found the
one genuine case in the whole project needing a 3rd register-file read port (`MOVE
Dn/An,(d8,An,Xn)`'s phantom-read quirk — added `rd_c`, Phases 148-149). "Genuine two-level
memory-indirect EA" was investigated and found never to have been a real 68020+ capability
at all (Phase 251) — a stale doc claim, corrected, not a missing feature.

**Pipeline stall/hazard coverage (Phases 103-136, 201-208)**: built the first inter-
instruction pipeline test coverage in the project — bus arbitration contention, RAW/CCR/
autoincrement hazards, control-transfer stall depth, all known multi-cycle FSM decode-
holdoff sources, DSACK wait-state composition, interrupt-mid-FSM, BERR-mid-FSM (fixed a
real CPU hang), and back-to-back FSM composition, growing both generic mechanisms
(interrupt-mid-FSM: 18 sources; DSACK wait-states-on-FSM-beats: 14 sources; back-to-back
FSM composition: 9 pairs, closed at Phase 240) to their own practical ceilings. See
`docs/stalls.md` for the full catalog.

**Cache correctness (Phase 158, 8 stages; MMU-CI-awareness closed at Phase 246)**: fixed a
real CACR bit-position bug (D-cache enable bits were simply wrong for 132 prior phases),
added FC bits to both cache tags, RMW forced-miss, IBE/WA/DBE, Freeze, CACR self-clearing-
bit readback masking, CIIN/CIOUT pins, then closed the D-cache's own stale-`mmu_ci`-
broadcast bug (Phase 228) and the I-cache's own equivalent gap (Phase 246, via the existing
`IC_FROZEN_MISS` state, needing no new register). BERR-during-fill per-beat discrimination
closed later (deferred-items closure plan). **No known correctness gap remains in
`docs/cache.md` as of Phase 246.**

**MMU hardening (Phase 150, 6 stages)**: wired real address translation into the live
IFU/EU datapath, translation-fault → real exception → RTE-driven retry, write-protect
violations, U/M hardware bit write-back, correct MMUSR, PLOAD, and long-format (8-byte)
descriptors. LIMIT/S-bit enforcement and genuine indirect descriptors closed later
(open-items backlog).

**Gap-closure plan (Phase 157)**: doc fixes (a stale CPUSH/CINVA/CINVL claim), SRP
selection, BKPT instruction bus protocol, cpSAVE/cpRESTORE one-CIR-read stub (full transfer
protocol closed later).

**Timing-accuracy program (Phases 159-220)**: found and fixed a major structural bus-cycle
pacing bug (every S-state was given a full clock instead of the real half-clock pairing,
~2x real duration), then a deeper investigation found the wrong *state count* too — see the
"S-State Signal Timing" section above for the current, verified-correct model. Also: swept
all 18 of MC68030UM.pdf §11.6's own timing tables, finding and fixing a MOVE-USP hazard and
a bit-field opcode-encoding bug; closed every register-only "too fast" timing gap via an
artificial-stall mechanism; found and fixed a real DIVS.L/DIVU.L sign-bit decode bug;
removed several genuine extra registered pipeline hops; redesigned burst mode and CAS2
timing against the manual.

**Open-items backlog (14 stages) + deferred-items closure plan (12 stages) (Phases
186-220)**: worked through essentially every previously-deferred or newly-surfaced finding.
Real bugs found and fixed: an I-cache stale-fill testbench artifact; MUL/DIV.L memory-EA
forms (previously undecoded); instruction-fetch FC hardcoding; burst-cycle address freeze +
beat-counter reset; MMU S-bit/LIMIT enforcement and genuine indirect descriptors; BKPT live
opcode substitution; cpSAVE/cpRESTORE's full transfer protocol; BERR-during-fill per-beat
discrimination. Investigated-and-deliberately-deferred at the time (later closed — see
below): CAS's own genuine bus-level lock; instruction-fetch BERR pending-until-use (closed
Phase 231). **No open RTL correctness gap of any kind remained as of Phase 220.**

**ext_count de-duplication plan (Phases 221-224)**: found and fixed a genuine decode bug
(`MOVE (d8,An,Xn),<memory dst>` under-counting extension words in full-format) via a new
exhaustive opcode-sweep overlap-detection testbench (`tb/ext_count_overlap_tb.sv`, now
permanent regression coverage), then centralized every hand-copied opcode-field/extension-
word bit position into `rtl/opcode_fields.sv` as the single source of truth.

**Doc/testbench maintainability (Phase 225)**: this file was first condensed here (see
above); also de-duplicated `tb/stall_fsm_tb.sv`/`tb/cache_tb.sv`'s own identical helper
tasks into `tb/common_helpers.svh`.

**`rtl/eu_seq.sv` split (Phase 226)**: the 11,001-line `eu_seq.sv` was split via `` `include
`` into `rtl/eu_seq_decode.svh` (pure combinational decode) and `rtl/eu_seq_execute.svh`
(stall/hazard, EX/WB latches, per-instruction FSMs), with `rtl/eu_seq.sv` reduced to a spine
— same compiled module, byte-identical elaborated output. This same technique was reused
twice more later: once for the Track 3 preview mechanism's own extraction into
`rtl/eu_seq_preview.svh` (post-Track-3 cleanup, see below), confirming it as a proven,
repeatable pattern for this project.

**10-item backlog plan (Phases 227-240, `elegant-gliding-fog.md`)**: dead I-cache array
removal; `ciout_n` live-CI staleness fix; per-beat CIIN; a real PTEST translation-fault hang
(root-caused to a testbench burst-address-freeze modeling gap, `burst_beat_probe`); IFU BERR
pending-until-use; BERR-during-fill retry (one new register, `dc_retry_used_r`); CAS bus-
lock (investigated, deferred at this point — later closed, see below); MOVEM's own genuine
memory-indirect EA word-count sizing (value resolution closed later at Phase 251); memory-
indirect EA beyond `MOVE <ea>,dst` (LEA/PEA/JMP/JSR shipped; ALU-EA/CMP2-CHK2/TAS-Scc
deferred, all later closed — see above); Stage 10 (2 more back-to-back FSM composition
pairs). **Closed in full at Phase 240.**

**CAS bus-lock plan (Phases 194/213/233/241-242, `silent-copper-latch.md`, closed in
full)**: CAS's own genuine bus-level lock was attempted and reverted twice before a
5th attempt succeeded — `eu_is_cas`/`eu_cas_hold` from `eu_seq.sv` drive a new
`cas_as_hold` override in `biu_cycle_gen.sv` plus a `bus_lock`-gated sticky-grant branch in
`biu_arbiter.sv`'s own internal re-arbitration, closing a real one-cycle arbitration-steal
window unique to CAS's own read-to-write gap. Single-address CAS now has the same genuine
bus-level lock guarantee RMW and CAS2 already had.

**Manual compliance review, round 1 (Phase 248, 10 items, all closed)**: real IACK cycles
(vector fetching was always autovectored before this); SR's M-bit + Format $1 throwaway
frame for M=1 interrupts; MMU Configuration Exception (vector 56); CED single-longword
clearing; 5 new real pins (RMC#/DBEN#/IPEND#/CDIS#/MMUDIS#, 2 more deferred as no-
faithful-analogue emulator-support signals); removed the non-existent VPA#/E-clock
mechanism; documented the coprocessor-conditional-instruction scope boundary; fixed 2 real
transcription errors in the RTS/UNLK timing tables; documented the RESET bidirectional-pin
split and corrected the HALT-output/double-bus-fault conflation (later fully resolved, see
Phase 250 Part B below).

**Phase 249 (code-review pass, 2 real bugs found)**: MMUDIS# was missing its 4th consumer
(`m68030_mmu.sv`'s own local `tc_e` copy); a real IACK BERR was wired to the wrong signal
(`eu_berr` instead of a dedicated `eu_iack_berr`), so a genuine BERR during IACK silently
redispatched forever instead of taking Spurious Interrupt — found via a new `SPURIOUS-INT`
test, not Harte (no real-interrupt vectors in that corpus).

**Manual compliance review, round 2 (Phase 250, 10 items — F1-F5/F7/F8/F10 implemented,
F9 confirmed not a bug, F6 deferred)**: MOVES/PFLUSH-PLOAD-PMOVE-PTEST privilege checks
(F2/F3); CHK2/CMP2 wrapped-bounds C-flag formula (F4); removed a fabricated Format $9 "MMU
short bus fault" (F5); exception priority-chain reorder to match Table 8-5 (F7); MOVE16
removed entirely — confirmed 68040-only, never existed on the 68030 (F8); STATUS pin's
double-bus-fault sub-case wired to `halt_out` (F10, later found to be the wrong signal, see
Part B); RTE's own STOP+trace interaction investigated and confirmed correct by
construction (F9); RTE's Format $B version-number check investigated and deferred as more
invasive than scoped (F6, later closed at Phase 251) — the real, structural AS/DS# RMW/
CAS2/CAS continuity model was also corrected this phase (F1): AS/DS# genuinely negate
between read and write phases and reassert, contradicting a misapplied "maintains AS,DS...
throughout" quote (that text actually describes Burst Mode's own State 3, not RMW/CAS/
CAS2) that every prior RMW/CAS2/CAS timing derivation back to Phase 108 had been built on.

**Exception frame layout fix (Phase 250, a side finding from the F9 investigation)**: every
frame format packed `{format/vector,SR}` then PC — real silicon's layout is SR alone at
SP+0, PC at SP+2, format/vector alone at SP+6 (a different grouping, not just reordering),
confirmed directly against Table 8-6/Figure 4-1. Internally self-consistent (the same code
both pushes and pops its own frames), so it had never surfaced as a functional failure in
250 prior phases — no existing test had ever inspected raw frame memory before. Also
removed a second fabrication, "Format $3, Address Error" (never existed; Address Error uses
the same $A/$B shape Bus Error does). Found and fixed a genuine Harte-sweep regression at
the same time, root-caused to `scripts/gen_harte_hex.py`'s own stale RTE-synthesis SSP-
shift logic (hand-tuned for the old, now-fixed layout) plus a missing vector-9 Trace-
handler installation for RTE tests — a second, independent, previously-latent gap this same
investigation surfaced.

**Phase 250 Part B (genuine double-bus-fault detection, a later session)**: real double bus
fault (§7.5.4/§8.1.2/§8.1.3) is a bus/address error occurring WHILE the exception controller
is already dispatching a prior one — a materially narrower condition than `halt_out`
(BERR+HALT retry exhaustion, which the manual explicitly excludes from double bus fault).
Confirmed via a throwaway test that a persistent fault on the exception controller's own
frame-push write causes infinite silent retry with zero reported condition — the real,
confirmed gap. New `snap_is_berr_r`/`dispatch_berr` divert into a terminal `EXC_DBLFAULT`
state with a new sticky `double_fault` output; `halt_out` renamed `retry_exhausted` and
`status_n` rewired to the new signal. Found and fixed a real, previously-undiscovered MMU
bug while verifying: `biu_mmu_arb.sv`'s own `d_wp` was a raw, ungated broadcast of a
register only valid at completion (the same "stale broadcast" shape Phase 228 already fixed
for CI, never extended to WP) — caused spurious, self-resolving WP re-faults, harmless
before this phase's own new detection made them visible. **Closes the 2-part plan in full.**

**Phase 251 (standing-gaps survey + 2 implementations, closes the memory-indirect-EA
rollout in full)**: a full accounting of every documented-but-not-done item as of Phase 250
Part B. F6 (RTE Format $B version-number check) implemented — widened `rte_phase_r` to a
3-phase FSM, and fixed 2 adjacent pre-existing bugs in the bad-format-code path
(`ex_rte_taken` had no validity gate of its own; `fault_pc` used the wrong PC source during
RTE's own multi-cycle stall). MOVEM's own genuine memory-indirect EA implemented — the last
family needing it, mirroring TAS's own hand-off shape; found and fixed a real bug (Xn's own
capture needed to be a shared prefix, not moved into the non-indirect-only branch, the same
class of bug `feedback_shared_decode_prefix` documents). "Genuine two-level memory-indirect
EA" confirmed via direct manual citation to never have been a real 68020+ capability — a
stale doc claim corrected, not a missing feature.

**Phase 252 (`/OCS` never asserted, found while building `timing_diagrams/`)**: two real
bugs — `biu_cache_if.sv`'s own "is this a genuine operand transfer" output was hardwired
`1'b0` with no way to derive a real value (fixed by mirroring `biu_multiop_fsm.sv`'s own
already-correct convention); independently, `biu_cycle_gen.sv`'s own `/OCS` assert/negate
window was two states later than the manual specifies (fixed to assert-with-ECS/negate-at-
S1, matching `/ECS` itself).

**Phase 253 (back-to-back EU bus-cycle dispatch gap, 2 of 3 layers fixed)**: traced the
diagram's own small idle gap (vs. Figure 7-25's zero-gap chained cycles) to three separate,
independently-discovered FSM layers between `eu_req` and the pins, each inserting its own
mandatory "return to idle" state even when the next request was already pending. Fixed
`biu_cycle_gen.sv` (a new `eu_continue_ok` fast path) and `biu_sizing_fsm.sv` (removed a
now-redundant `SS_DONE` state). **Attempted the third layer, `biu_cache_if.sv`, twice and
reverted both times** — its own `eu_req` is the raw, unmediated EU request with no buffering
cycle, so "still asserted the instant ack fires" cannot be safely distinguished from "a
genuinely new request" without giving the EU a reaction cycle first, which is exactly what
the existing `CI_IDLE` state already provides. Confirmed structurally unfixable by this
technique, not a bug of the same shape as the other two layers — left as the project's own
established binding constraint on the dispatch gap (later addressed differently by Tracks
1-3, see below).

**Tracks 1-3 (Phases 254-273, `wobbly-honking-cascade.md`): closing the back-to-back
dispatch gap for real, via EU-side preview instead of BIU-side inference.** Phase 253
confirmed the BIU-side "infer novelty from `eu_req`" approach is structurally unsound for
the one layer that actually dominates the gap (`biu_cache_if.sv`). Tracks 1-3 instead teach
the EU to preview the *next* decoded instruction's own address/data one cycle early, using
an explicit `mem_new_dispatch`/`eu_new_dispatch` signal (never inferred from register
values) to tell the BIU it can trust it. **Track 1 (Phase 254-255)**: a narrow `(An)`-only
EU-side fast path, generalized in stages to plain absolute EA, `(d16,An)`, and indexed/full-
format EA (reusing `rd_b`/`rd_c` when the *current* instruction wasn't itself using them) —
found and fixed 2 further real regressions along the way (RTE/RTR/CMPM's own multi-phase
stall needing `!ex_mem_stall`; RTS/RTR/RTE's own stale `dec_*` fields right after a redirect
needing `!ex_redirect_pending`), both invisible to every suite except the mandatory full
Harte sweep. **Track 2 (Phase 256)**: dedicated `rd_prev_a`/`rd_prev_b`/`rd_prev_c`
register-file ports, touched by nothing but the preview mechanism, removing Track 1's own
"is CURRENT using this port" restriction entirely and structurally eliminating a whole bug
class (`dyn_bit_get_Dn`-corrupts-`ex_ea`) as a side effect. **Track 3 (Phase 257 scoping +
Phases 258-273 full implementation)**: extended the identical mechanism to all 16 special
multi-cycle instruction FSMs (MOVEM, CMP2/CHK2, MOVEP, ADDX/SUBX-mem, bitfield-mem,
PACK/UNPK-mem, PMOVE64, cpSAVE/cpRESTORE, BCD-mem, MOVE mem-to-mem indexed-dst, CMPM,
memory-indirect, general RMW, TAS, CAS, CAS2) — the user explicitly rejected a risk-tiered
subset ("we need to do them all .. it isn't optional not to be cycle accurate"), so every
family was implemented safest-to-riskiest, each with its own dedicated cosim hazard test and
full mandatory gate + Harte sweep before the next. Found and fixed one genuine regression
mid-track (PMOVE64's own ordinary-read clause misfiring one beat early, a first fix
extending the shared `ex_mem_stall` causing an unrelated sim hang, reverted in favor of a
narrow per-family exclusion — see `feedback_shared_stall_signal_blast_radius.md`) and
documented two genuine, pre-existing, out-of-scope bugs found along the way (bitfield-mem's
always-longword sizing, later fixed at Phase 276; PACK's source-byte read order vs.
Musashi, later fixed at Phase 277). **This closes Track 3,
and the entire `wobbly-honking-cascade.md` plan, in full** — real 68030 silicon's own
chained back-to-back bus-cycle timing is now matched for essentially every instruction
combination in the chip. RTR/RTE remain the one confirmed structural exception (not a risk
exclusion): there is no "next" instruction to preview at the moment a return's own final
beat acks, since the return address itself isn't known until that beat completes — real
silicon has this identical floor.

**Post-Track-3 design-review cleanup (same session, `wobbly-honking-cascade.md`,
superseding its own prior Track-1/2/3 content)**: after Track 3 closed, a design retrospective
found and fixed one real duplication bug-class: 10 of Track 3's own 12 hazard signals were
hand-copied instances of the identical `wr_en && (dec_src_reg==target ||
dec_dst_reg==target)` template — centralized into one shared `reg_hazard()` function,
mirroring the `opcode_fields.sv` precedent (Phase 221-224) for the same hand-copied-field
bug shape. A second pass, grounded directly in current code measurements rather than
narrative, found `eu_seq_execute.svh`/`eu_seq_decode.svh` both still exceed this file's own
~3000-line module guideline (6010/6320 lines) despite the Phase 226 split — investigated
and found the ~20 special-FSM implementations are scattered throughout the file (not one
contiguous block), so a full per-family extraction would be high-risk for zero functional
benefit; instead extracted the genuinely contiguous, self-contained Track 3 preview
mechanism itself (`reg_hazard`, every family's `*_final_ack`/`*_hazard` signal,
`preview_current_ready`/`preview_ok`) into a new `rtl/eu_seq_preview.svh`, `` `include ``d
from `eu_seq.sv` — the same proven, byte-identical-elaborated-output technique Phase 226
established. Full compliance with the 3000-line guideline is explicitly NOT attempted (would
need a per-family extraction effort of comparable size/risk to Track 3 itself) and is
documented here as a deliberately deferred future item, not silently dropped. Two further
retrospective findings were investigated and found not worth acting on: the dormant
testbench inline-memory-model gap (11 files still lack `burst_beat_probe`, but none of them
ever enable CACR, so the bug class they're exposed to is confirmed structurally
inapplicable, not just currently untriggered) and `burst_beat_probe`'s own "duplication"
across `cache_tb.sv`/`mmu_xlate_tb.sv` (on inspection, a trivial, already-identical 2-line
hierarchical-reference idiom, not a structurally-duplicated *decision* the way the hazard
signals were — too small to be worth centralizing).

**Phases 274-275 (post-Track-3 gap closure, a later session, `wobbly-honking-cascade.md`,
found while building `timing_diagrams/`'s Figure 7-25 diagram, both IMPLEMENTED AND
VERIFIED)**: two more real dispatch-gap bugs, both surfaced by the Read-Write-Write-Read
chain Figure 7-25 demonstrates — a case Track 3's own 16 special-FSM families never
exercised, since all of them are read-final-beat families. **Phase 274**: `preview_current_
ready`'s own ordinary clause (`rtl/eu_seq_preview.svh`) only ever fired when CURRENT was a
READ — an ordinary WRITE as CURRENT never triggered a preview of NEXT at all. Fixed by
mirroring the read clause for writes, re-verifying its two exclusions fresh
(`!ex_is_move_reg_idx_dst`, `!ex_is_pmove64` — the latter the identical regression shape as
the original Phase 264 read-side PMOVE64 bug, caught by inspection this time before it could
ship). No new hazard signal needed — `hazard_ex`'s own generic An-update clause already
covers it. **Phase 275**: `biu_cache_if.sv`'s `CI_WRITE` completion, unlike `CI_D_MISS`'s
own completion right above it, never checked `eu_new_dispatch` at all, so any access
following a write always took the one-tick `CI_IDLE` detour even after Phase 274 landed —
explaining why write→write chaining had looked gap-free already (via the unrelated,
pre-existing "Track A" fast path, Phase 163/247 item #10) while write→read-miss still
showed a real gap. Fixed by copying `CI_D_MISS`'s own fast-path condition and register-set
block verbatim into `CI_WRITE`'s completion branch. Both fixes: full mandatory gate clean,
Harte bit-identical to baseline. See `plan.md` Phases 274-275 for the full writeups
(including the Musashi `MOVE.L Dn,-(An)`-splits-into-2-words reference quirk found while
verifying Phase 274's own hazard test).

**Phase 276 (bitfield-mem always-longword bus access sizing, a later session,
`project_bf_mem_longword_sizing_bug.md`, IMPLEMENTED AND VERIFIED)**: closes the real,
pre-existing gap documented (and deliberately deferred) at Phase 262 — `bf_mem_run_r`
always dispatched a fixed 4-byte longword read/write regardless of the bit-field's own
offset+width footprint. Re-derived Musashi's own `m68ki_load_bitfield`/
`m68ki_store_bitfield` algorithm (`tools/musashi/m68kcpu.h`) against this project's own
framing — real minimal footprint is a BYTE, WORD, LONGWORD, or (3-byte case) a WORD then a
BYTE sub-access, computed from `offset%8+width`, keeping `eu_bitfield.sv`'s own unpatched
0-31 `bf_offset` convention completely untouched; scoped to the `offset+width<=32` envelope
(the only one where the old fixed-longword access was ever value-correct — the `>32` case
is a separate, deeper, pre-existing gap in `eu_bitfield.sv` itself, left as-is). Two real
bugs found and fixed before shipping, neither obvious from static inspection: (1)
`mem_rdata` is RIGHT-justified for reads (byte@[7:0], word@[15:0]) — the OPPOSITE of
`eu_lane`'s own TOP-justified WRITE-side convention — a first attempt wrongly assumed the
same convention for both directions, caught via a real cosim mismatch, confirmed via a
direct debug trace on the real BIU-backed pipeline; (2) two independent testbench-only
memory-model gaps (`tb/bitfield_tb.sv` and `tb/ea_extended_tb.sv` both lacked genuine
lane-aware byte/word read+write support, dormant since `bf_mem_run_r` had never dispatched
anything but a longword before), the second of which also surfaced a THIRD, independent,
previously-latent bug: `ea_extended_tb.sv`'s own pre-existing TAS-01 test had its own byte
test value at the wrong bit position, masked for years by two unrelated testbench bugs
canceling out by coincidence — fixed the test's own setup to match its own
already-correct expected value. New dedicated cosim tests (`tests/bf_sizing1.s`/
`bf_sizing2.s`, spans 1 and 3) match Musashi exactly, wired into `make cosim_memind`
(31/31). Full mandatory gate clean, Harte bit-identical to baseline (bitfield memory-EA
forms have zero Harte coverage, 68020+-only). **Closes
`project_bf_mem_longword_sizing_bug.md` in full.**

**Phase 277 (PACK/UNPK-mem source/destination byte access order, a later session,
`project_pack_source_read_order_bug.md`, IMPLEMENTED AND VERIFIED)**: closes the other real
gap documented (and deliberately deferred) at Phase 263. PACK's own memory-to-memory
source read (`-(Ay)`) and UNPK's own destination write (`-(Ax)`) were each a single 16-bit
word access in this RTL; real 68030 silicon (confirmed against Musashi's own
`m68k_op_pack_16_mm`/`m68k_op_unpk_16_mm`) issues 2 SEPARATE BYTE accesses via 2
independent 1-byte predecrements instead, with the FIRST landing in the HIGH half and the
SECOND in the LOW half — the OPPOSITE of a standard big-endian access. PACK's own
destination write and UNPK's own source read were already correct (both genuinely are a
single byte). Extended the existing 2-phase `pack_mem_run_r` FSM with an optional
2-sub-access shape for whichever phase needs it, gated throughout by a new
`pack_mem_sub_last` signal mirroring Phase 276's own `bf_mem_sub_last`; reused Phase 276's
own already-confirmed "`mem_rdata` is right-justified for reads" fact directly rather than
re-deriving it. Found and fixed one real, previously-latent testbench-only regression
(`INT-mid-PACK`'s own hardcoded bus-cycle-count expectation, 2→3) and, while fixing
`tb/bcd_pack_tb.sv`'s own memory model to be lane-aware (the same gap already found and
fixed twice earlier this session), surfaced THREE more independent, previously-latent bugs
in this file's own existing NBCD-01/ABCD-01/SBCD-01 tests — the exact same shape as the
TAS-01 bug Phase 276 found (byte values/expected results placed at the wrong bit position
relative to their own real target address's own real lane, masked for years by two
testbench bugs canceling out). New dedicated cosim tests (`tests/pack_order1.s`/
`pack_order2.s`) match Musashi exactly, wired into `make cosim_memind` (33/33). Full
mandatory gate clean, Harte bit-identical to baseline (PACK/UNPK have zero Harte coverage,
68020+-only). **Closes `project_pack_source_read_order_bug.md` in full** — both real bugs
Track 3's own Phase 262/263 investigation found and deferred are now fixed.

**Phase 278 (level-7/NMI interrupt-mask-tie recognition gap, a later session,
`project_int_pending_level7_mask_gap.md`, IMPLEMENTED AND VERIFIED)**: closes the
real gap found (and deliberately deferred) while building `timing_diagrams/`'s
Figure 7-44/7-45 diagram. `m68030_exc.sv`'s own `int_pending` formula
(`ipl_sync_l > ipl_mask_l`) was a plain level comparison identical for every IPL
level — but level 7 (NMI) is architecturally non-maskable and must be recognized
on any TRANSITION into level 7 regardless of the current mask; since `7>7` is
always false, a level-7 request asserted while the mask already sat at 7 (SR's
own reset default) was silently never recognized. Fixed via a new sticky
edge-detect latch, `nmi_pending_r` — set on any synchronized-IPL transition into
`3'b111`, cleared once the interrupt actually dispatches — ORed into
`int_pending`. Found a genuinely separate, pre-existing test-construction bug
while verifying end-to-end (not introduced by this fix, not an RTL bug):
`tests/timing_manual_744.s` placed the level-7 handler's own code directly at
the vector table address instead of storing a pointer there (real 68k
semantics), so a full RTE round-trip would hang — masked because the diagram
only ever needed the early dispatch waveform. Fixed alongside the RTL change
(vector table now stores a real pointer; the diagram test's own now-obsolete
SR-lowering workaround was removed; the diagram's own testbench needed to wait
for its read cycle to genuinely complete before asserting the interrupt, since
recognition is now fast enough to have preempted it entirely on the first
rebuild attempt) — both the manual crop and sim waveform were regenerated and
re-verified. New dedicated regression test, `tb/stall_fsm_tb.sv`'s
`INT-mask-tie`, confirmed via a temporary disabled-fix rebuild to fail cleanly
(no hang) without the fix. Full mandatory gate clean, Harte bit-identical to
baseline. **Closes `project_int_pending_level7_mask_gap.md` in full.**

**Phase 279 (BERR-without-HALT infinite retry loop, a later session,
`project_berr_no_halt_retry_loop.md`, IMPLEMENTED AND VERIFIED)**: closes the
real gap found (and not root-caused at the time) while building
`timing_diagrams/`'s Figure 7-49 diagram. Root cause, found via direct per-tick
signal tracing: `rtl/biu_sizing_fsm.sv` (sitting between `biu_cache_if.sv` and
`biu_cycle_gen.sv`) had no BERR-abort path at all — its state machine only
ever exited its active sub-cycle state on a successful ack, which a genuinely
faulted cycle never produces, so it got stuck forever re-driving the STALE
faulting address into `biu_cycle_gen` regardless of what `biu_cache_if.sv`
(already correctly aborted via its own `CI_BERR` state) or the exception
controller wanted to dispatch next — confirmed this silently prevented the
exception controller's own frame-push write from ever reaching the bus,
misfiring a bogus double-bus-fault instead. Fixed via a new `cyc_berr` input
(wired from `cg_eu_berr_raw`, the same signal `biu_cache_if.sv`'s own
`sf_berr` already uses) that resets it cleanly back to idle. Found and fixed
a second, genuinely separate bug while verifying end-to-end: `tb/biu_tb.sv`'s
own pre-existing "Retry exhausted" test relied on an implicit synchronizer
race (asserting HALT and the EU request in the same delta) that this fix's
own correctness elsewhere in the same run shifted unfavorably — confirmed via
a clean-baseline check that the race, not the fix, was at fault — fixed by
making the test explicitly wait for the cycle to start before asserting HALT.
New dedicated regression in `tb/biu_tb.sv`, confirmed via a temporary
disabled-fix rebuild to fail cleanly without the fix. The Figure 7-49
diagram's own testbench needed its run length re-tuned to stop right after
the fault cycle (not a large fixed budget) now that the exception genuinely
completes, so the diagram's own "last N cycles" capture window doesn't drift
onto the frame-push/handler activity that now legitimately follows. Full
mandatory gate clean, Harte bit-identical to baseline. **Closes
`project_berr_no_halt_retry_loop.md` in full.**

**Phase 280 (CBACK beat-0-only sampling bug + 3 new representative timing
diagrams, a later session, `project_cback_beat0_only_sampling_bug.md`,
IMPLEMENTED AND VERIFIED)**: completed the remaining `timing_diagrams/`
categories (synchronous RMW — Figure 7-36; a burst-abort variant — Figure
7-39; a BERR+HALT retry variant — Figure 7-54). While building Figure 7-39,
found a real RTL gap: `rtl/biu_burst_ctrl.sv`'s own `cback_ok_r` sampled
`/CBACK` only once, at beat 0, as a sticky OR-latch — once granted, a real
peripheral negating `/CBACK` on a LATER beat was silently ignored and the
burst ran to completion regardless, contrary to MC68030UM.pdf §6.1.4/6.2's
own confirmed text ("premature negation of CBACK... causes the current
cycle to complete normally... however, the burst operation aborts"). Fixed
by resampling `/CBACK` every beat instead of only the first (widened the
gate from `burst_beat_r==0` to `at_burst_data` alone; changed from OR-
accumulation to a plain resample). Found and fixed two more bugs while
re-verifying the existing Figure 7-38 diagram against this fix: its own
testbench mirrored `/CBREQ`'s brief beat-0-only pulse for `/CBACK` instead
of modeling a real peripheral holding it asserted for the whole burst
(confirmed via direct trace this never actually overlapped any beat's own
sampling window, even beat 0's — only "worked" via the old sticky-latch bug
plus a synchronizer-delay coincidence) — fixed to hold `/CBACK` asserted
for the whole burst, matching `tb/cache_tb.sv`'s own already-proven
convention; and the test program's own burst-triggering read raced
`CACR`'s write with no settling gap, dispatching a spurious non-burst
access first — fixed with an artificial stall matching this project's own
established `timing_manual_725.s` convention. Full mandatory gate clean
(`make test` 37/37 including `biu`/`cache`, the two suites that actually
exercise burst mode), Harte bit-identical to baseline (no suite exercises
burst mode). No dedicated module-level regression added — the fix is
directly exercised and visually verified via the new Figure 7-39 diagram
itself. **Closes `project_cback_beat0_only_sampling_bug.md` in full.**

**Current state**: `make test` 37/37, `make cosim_grp` 8/8, `make cosim_memind` 33/33,
`make dat-synth` 50/50. Full 124-suite Tom Harte sweep: `PASS 702142 FAIL 2` (the documented
ASL.b corpus anomaly) `SKIP 281221 TIMEOUT 0`, unchanged since Phase 112 (only the SKIP/PASS
split has shifted slightly across later phases as harness gaps closed; the corpus doesn't
cover any 68020+-only family, coprocessor conditionals included, so this count is unaffected
by Phase 281). **One active cross-repo plan item as of Phase 281** (`plan.md`'s own Phase 281
section, `wobbly-honking-cascade.md`): coprocessor conditional instructions — cpBcc.W/.L and
cpDBcc done, cpScc/cpTRAPcc/dedicated-Protocol-Violation-coverage remaining, in that order. No
other outstanding plan of any kind remains. Permanently out of scope by design, not started
(re-confirmed, do not re-suggest): STATUS's other 3 sub-cases + REFILL#; PTEST's DSACK-breadth
exclusion + I-cache CEI's per-line-only limitation (pre-existing architecture boundaries, not
bugs).

## Verification Commands

```bash
make test          # 32/32 unit + integration regression
make buscmp        # smoke.s DUT vs Musashi bus log
make cosim_grp     # all 8 opcode group bus comparisons (grp0–grp7)
make buscmp-grp0   # single group (replace 0 with 1–7)
make dat-synth     # 50-vector synthetic register-state cosim (DUT vs Musashi)
make sim/harte_dat # (re)compile Harte testbench binary after RTL changes
# Tom Harte SingleStepTests (68000 one-instruction vectors):
python3 -u scripts/run_harte.py tests/harte/ADD.b.json.gz    # 100%
python3 -u scripts/run_harte.py tests/harte/SUB.b.json.gz    # 100%
python3 -u scripts/run_harte.py tests/harte/MOVE.b.json.gz   # 90.8% (arch gap)
# Run all: for f in tests/harte/*.json.gz; do python3 -u scripts/run_harte.py "$f"; done
```

**Fast path (Phases 110-111)**: `run_harte.py` above is what RTL-change verification gates
actually use (proven, one `vvp` process per test). For quick full-corpus checks,
`scripts/run_harte_batch.py` batches many tests per process — same `can_run`/`gen_hex`/
`compare` logic, validated to produce identical verdicts:

```bash
make sim/harte_vbatch                             # Verilator backend (build once)
python3 -u scripts/run_harte_batch.py tests/harte/*.json.gz tests/harte/*.json.bin \
    --backend verilator -j 10 --chunk-size 300     # full 124-suite corpus in ~3m18s
```

**Use the Verilator backend (`--backend verilator`) for the full 124-suite
sweep, not Icarus.** `make sim/harte_batch` (Icarus backend) exists and is
still valid for a single suite or a quick spot-check, but running the FULL
corpus through it is dramatically slower than Verilator's ~3m18s — a real
attempt (Phase 281 verification) was still running after 8+ minutes at
`-j 8 --chunk-size 150` and had to be killed and redone with Verilator
instead. Don't default to Icarus for this specific full-sweep gate; reach
for `sim/harte_vbatch` directly.

Bus log format: `BUS R|W %08x %08x fc=%b siz=%b` (siz: 00=longword, 01=byte, 10=word, 11=line)

`--dut-may-continue`: DUT may have extra trailing reads after STOP (IFU prefetch); REF ends at STOP.

`m68k_read_memory_32` fix (Phase 76): after first instruction word fetch, program-space 32-bit reads route through the siz=10 word cache so Musashi's extension-word fetches match DUT IFU bus cycles.

## SIZ[1:0] Encoding

| SIZ[1:0] | Transfer |
|----------|----------|
| 00 | Longword (32-bit) |
| 01 | Byte (8-bit) |
| 10 | Word (16-bit) |
| 11 | Line (16-byte burst) |

Bus width is determined dynamically per-cycle by the DSACK0/1 response. SIZ[1:0] are **outputs** that tell the peripheral the requested transfer size; the peripheral uses SIZ+A[1:0] to select which byte lanes to respond on.

## Style Rules

- Use SystemVerilog (`always_ff`, `always_comb`, `typedef enum`, `struct`) rather than plain Verilog-2001.
- Use `generate` loops for the 8 data registers, 8 address registers, and other replicated structures — do not copy-paste.
- The BIU's `biu_cycle_generator` is the only place S-state transitions live. Other modules consume `s_state` as an output — they do not drive it.
- Never combine two pipeline stages in the same `always` block; each stage needs its own flip-flop barrier.

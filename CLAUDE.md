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
deliberate, currently out of scope**: Phase 157/199 implemented the CIR
access bus protocol itself and cpSAVE/cpRESTORE's own full state-transfer
handshake, closing those items. The four coprocessor-conditional
instructions (Branch/Test-Decrement-Branch/Set/Trap on Coprocessor
Condition, MC68030UM.pdf §10.2.2/§10.2.3/§10.2.4/§10.2.5) are NOT decoded
or implemented anywhere in this RTL (confirmed via grep — zero occurrences
of any of the four mnemonics in `rtl/`) and were never previously flagged
as a known gap. Unlike cpSAVE/cpRESTORE (a fixed-shape state-transfer
protocol this project could fully specify and test without a real
coprocessor attached), the four conditional instructions require the
MAIN PROCESSOR to read back a genuine coprocessor-evaluated condition
(via the Condition CIR / "evaluate and return condition" primitive) and
act on it — meaningfully testing this needs an actual attached
coprocessor model (a real or emulated FPU) exercising its own condition-
evaluation semantics, which this project has never built and has no
current plan to. Documented here as a deliberate scope boundary (Phase
248 item #7, docs/*.md review), not silently dropped. Coprocessor
Protocol Violation (vector 13, MC68030UM.pdf §10.5.1.1/§10.5.4) — the
exception either the main processor or a coprocessor can signal when
the CIR handshake itself is malformed — is likewise unimplemented for
the same reason (nothing in this project ever drives a genuine
protocol-violation condition to detect).

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
derivations (all 253 numbered entries, every root-cause trace, every bug fix's exact
mechanism) are archived verbatim in `CLAUDE.md.old` — read it directly if you need the
detailed history behind any of the summary points below** (e.g. "why is X done this way,"
"what exactly did phase N find"). This file was condensed from ~670 lines / ~513KB down to
a compact summary at the point where every major initiative below had closed with no
outstanding plan, to stop paying the full historical narrative's token cost on every future
session (mirrors the `plan.md` → `plan.md.old` precedent set at that project's own Phase 162).

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
the wrong chip). Along the way, most "architecture gap" diagnoses (the `port3.md` 3rd
register-file-port investigation) turned out to be missing decode or test-harness bugs, not
real port-count limitations — **the investigation concluded nothing needs a 3rd port**,
with exactly one later exception found (see below).

**Memory-indirect / full-format EA rollout (Phases 115-149)**: extended indexed/memory-
indirect addressing (`(d8,An,Xn)`, `([bd,An],Xn,od)`, full-format base/outer displacements)
across every instruction family that needed it — MOVE, ALU-mem-src, dynamic bit-ops, Scc/
CHK/ADDQ-SUBQ/MOVE-SR-CCR, LEA/JMP/JSR/PEA, MOVEM, CMP2/CHK2 — plus long (32-bit)
displacements and a 5th/6th IFU prefetch-queue word (`q5`/`q6`) to support them. Found the
one genuine case in the whole project that needed a 3rd register-file read port
(`MOVE Dn/An,(d8,An,Xn)`'s phantom-read quirk — added `rd_c`, Phases 148-149). Two items
remain deliberately out of scope for a future dedicated plan: genuine two-level
memory-indirect EA extended beyond `MOVE <ea>,dst`, and MOVEM's own genuine
memory-indirect (needs a 7th IFU queue word).

**Pipeline stall/hazard coverage (Phases 103-136, 201-208)**: built the first inter-
instruction pipeline test coverage in the project — bus arbitration contention, RAW/CCR/
autoincrement hazards, control-transfer stall depth, all known multi-cycle FSM decode-
holdoff sources, DSACK wait-state composition, interrupt-mid-FSM, BERR-mid-FSM (fixed a
real CPU hang: BERR during an EU-initiated multi-beat access used to hang forever instead
of raising Bus Error — fixed for every `ex_mem_stall` source), and back-to-back FSM
composition. The pipeline-stall breadth extension plan then grew both generic mechanisms
to their own practical ceilings: interrupt-mid-FSM (18 sources), DSACK wait-states-on-FSM-
beats (14 sources, PTEST permanently excluded — see `docs/stalls.md`), back-to-back FSM
composition (7 pairs). See `docs/stalls.md` for the full catalog and what open-ended
breadth, if any, remains.

**Cache correctness (Phase 158, 8 stages)**: fixed a real CACR bit-position bug (D-cache
enable bits were simply wrong, so ED-enabled D-cache silently never activated for 132
prior phases), added FC bits to both cache tags, RMW forced-miss, IBE/WA/DBE (burst-
enable, write-allocate, D-cache burst fill), Freeze (FD/FI), CACR self-clearing-bit
readback masking, CIIN/CIOUT pins. BERR-during-fill per-beat discrimination was fully
closed later (deferred-items closure plan, below).

**MMU hardening (Phase 150, 6 stages)**: wired real address translation into the live
IFU/EU datapath (previously TC.E had zero effect on any real access), translation-fault →
real exception → RTE-driven retry, write-protect violations, U/M hardware bit write-back,
correct MMUSR, PLOAD, and long-format (8-byte) descriptors (bit layout confirmed directly
against the real MC68030UM.pdf manual). LIMIT/S-bit enforcement and genuine indirect
descriptors were closed later (open-items backlog, below).

**Gap-closure plan (Phase 157)**: doc fixes (a stale CPUSH/CINVA/CINVL claim — those are
'040-only, not '030), SRP (Supervisor Root Pointer) selection, BKPT instruction (bus
protocol; live opcode substitution closed later), cpSAVE/cpRESTORE (one-CIR-read stub;
full transfer protocol closed later).

**Timing-accuracy program (Phases 159-220, several stacked plans)**: found and fixed a
major, structural bus-cycle pacing bug — `biu_cycle_gen.sv` originally gave every named
S-state a full clock instead of the real half-clock pairing real 68030 silicon uses, making
every bus cycle in the project run at roughly 2x real duration. Fixed in stages (S-state
pacing correction, then a deeper bus-cycle round-trip overhead investigation that found the
RTL was using the wrong *state count* too — see the corrected "S-State Signal Timing"
section above for the current, verified-correct model). Also: transcribed and swept all 18
of MC68030UM.pdf §11.6's own timing tables (Chapter 11 timing verification plan),
finding and fixing two real, previously-undiscovered bugs neither Harte nor any other
method had caught (a MOVE-USP hazard; a 3-way bit-field opcode-encoding bug affecting
BFCHG/BFEXTS/BFFFO); closed every register-only "too fast" timing gap via an artificial-
stall mechanism (purely-combinational execution units computing instantly what real
silicon's serial microcode takes many cycles for); found and fixed a real DIVS.L/DIVU.L
sign-bit decode bug (every real-encoded DIVS.L was silently computing DIVU.L's result);
removed several genuine extra registered pipeline hops (bus-pipelining-overlap plan);
redesigned burst mode and CAS2 timing against the manual (finding and fixing two more
pin-continuity bugs, burst's DS# and CAS2's AS# both incorrectly dropping between
beats/sub-cycles). Burst-mode and per-cycle dispatch-floor residuals are confirmed
already at their practical, load-bearing floor — not further fixable without regressing
proven-correct pin timing.

**Open-items backlog (14 stages) + deferred-items closure plan (12 stages) (Phases
186-220)**: worked through essentially every previously-deferred or newly-surfaced finding
across the project's history. Real bugs found and fixed: an I-cache stale-fill testbench-
timing artifact (root-caused, confirmed testbench-only); MUL/DIV.L memory-EA forms
(previously entirely undecoded); instruction-fetch FC hardcoding (every fetch used to claim
Supervisor Program Space regardless of the real S-bit); burst-cycle address freeze (real
silicon holds the burst address constant; this RTL was incrementing it, plus a related
beat-counter reset bug); MMU S-bit/LIMIT enforcement and genuine indirect descriptors;
BKPT live opcode substitution (finishing what Phase 157 stubbed); cpSAVE/cpRESTORE's
full transfer protocol for `(An)`/predecrement/postincrement EA plus EMPTY/INVALID test
coverage; BERR-during-fill per-beat discrimination (the most architecturally delicate stage
in either plan, closing the last cache-correctness gap). Investigated-and-deliberately-
deferred, with documented correct-shape proposals: CAS's own genuine bus-level lock
(attempted, found architecturally incompatible with `biu_cycle_gen`'s hardwired
always-writes RMW schedule, reverted); instruction-fetch BERR pending-until-use (real,
needs cross-module IFU/decode visibility not available today); a PTEST translation-fault
hang (confirmed real once, not reproduced in a clean isolated repro). Corrected one stale
earlier claim (CAS write-on-mismatch — real silicon does *not* always write back on
mismatch; a "fix" in that direction would have been a regression). Confirmed safe (not a
bug): `eu_trace_req`'s mid-FSM dispatch race is real but already caught by a pre-existing,
exception-agnostic bubble-insert mechanism, uniformly protecting every exception source.
**No open RTL correctness gap of any kind remains in this project as of Phase 220.**

**ext_count de-duplication plan (Phases 221-224)**: found and fixed a genuine,
previously-undiscovered decode bug (`MOVE (d8,An,Xn),<memory dst>` under-counting
extension words in full-format) via a new exhaustive opcode-sweep overlap-detection
testbench (`tb/ext_count_overlap_tb.sv`, now permanent regression coverage in
`make test`), then eliminated the actual mechanism behind that bug class and several
prior instances of it (Phases 96/150/161/216): every hand-copied opcode-field and
mode=110 extension-word bit position across `eu_seq.sv`/`m68030_seq.sv` is now
centralized in `rtl/opcode_fields.sv` as the single source of truth.

**Doc/testbench maintainability follow-up (Phase 225, no formal plan)**: this
file was condensed from ~670 lines / 513KB down to its current size (full
history archived verbatim in `CLAUDE.md.old`) at exactly this point, since
every major initiative above had closed with no open plan. Also
de-duplicated `tb/stall_fsm_tb.sv`/`tb/cache_tb.sv`'s own byte-for-byte-
identical `check`/`check32`/`run_and_check` helpers into a shared
`tb/common_helpers.svh` — the testbench-side analogue of the ext_count
de-duplication effort above. See `plan.md §Phase 225` for the full writeup.

**rtl/eu_seq.sv split (Phase 226)**: the 11,001-line `eu_seq.sv` (3.7x over this
file's own "~3000 lines per module" guideline, by far the largest file in the
project) was split via `` `include `` — not a real module split (would need
~70+ `dec_*` decode signals turned into module ports, real port-plumbing-bug
risk) — into `rtl/eu_seq_decode.svh` (pure combinational decode) and
`rtl/eu_seq_execute.svh` (stall/hazard, EX/WB latches, every per-instruction
FSM), with `rtl/eu_seq.sv` itself reduced to a 599-line spine (ports,
parameters, shared helpers) that `` `include ``s both back in at the exact
point they used to live — same compiled module, byte-identical elaborated
output. Along the way, found the Verilator backend (`sim/vmustest`,
`sim/harte_vbatch`) had never needed an `-I` flag before (nothing in `rtl/`
had used `` `include `` until now) and fixed both `VLATOR_FLAGS` variables;
also found GNU Make 3.81's own no-recipe dependency-only rules do *not*
propagate staleness (confirmed empirically, `make -n` reports "Nothing to be
done") — fixed with a `@touch $@` recipe, the standard idiom for this case.
Full 124-suite Harte sweep bit-identical to baseline, as expected for a pure
text-relocation change. See `plan.md §Phase 226` for the full writeup.

**10-item backlog plan (Phase 227+, `~/.claude/plans/elegant-gliding-fog.md`)**:
after the efficiency/clarity survey closed, the user asked what else remains open —
got a 10-item list of everything previously investigated, documented, and
deliberately deferred (`docs/stalls.md`/`docs/cache.md`'s own "What's left"
sections). Working through it sequentially, smallest/safest first. **Stage 1
(Phase 227)**: removed a fully dead EU-side I-cache array in `biu_cache_if.sv`
(`eu_is_icache`, hardwired `1'b0` since Phase 127 moved the real I-cache to
`biu_icache_if.sv`) — a full parallel array + 4-state linefill FSM + dispatch/
output-block wiring across `biu_cache_if.sv`/`m68030_biu.sv`/`m68030_top.sv`, plus
2 now-meaningless dedicated tests in `tb/biu_tb.sv` (their own coverage is already
extensive elsewhere, `tb/cache_tb.sv`'s I-1..I-6). Full Harte sweep bit-identical to
baseline. See `plan.md §Phase 227` for the full writeup. **Stage 2 (Phase 228)**:
`ciout_n` used a stale-prone broadcast (`mmu_ci`) that's only guaranteed correct on
the exact cycle a requester's own translation completes — reading it any later cycle
(the whole time a D-cache miss/write waits for its own bus cycle) risked showing a
concurrently in-flight I-side/EXT-side requester's own result instead. New `xl_ci_r`
register captures this access's own translated CI bit at the one correct cycle, used
by every later consumer (`ciout`, `dhit_r`, the `CI_D_MISS` populate decision).
Found and fixed a real bug along the way: an untranslated-access burst-dispatch check
was also reading the same stale broadcast, capable of permanently blocking D-cache
bursting after any one unrelated MMU use. Verified via a new signal-level test in
`tb/biu_tb.sv` (made `xl_hit`/`xl_pa`/`xl_ci`/`ciout` testbench-controllable) that
directly injects the exact staleness scenario. Found, documented, deliberately not
fixed: `biu_icache_if.sv` has zero MMU-CI-awareness at all for its own linefill — a
bigger, different gap than Stage 2's own "stale broadcast" scope. Full Harte sweep
bit-identical to baseline. See `plan.md §Phase 228` for the full writeup. **Stage 3
(Phase 229)**: CIIN was checked once for a whole burst-filled line, not per-beat as
the manual describes. Fixed with a D-cache-only scope refinement (the I-cache's own
per-LINE `valid_i` makes true per-word CIIN gating architecturally impossible there,
unlike the D-cache's per-WORD `valid_d`) — new per-beat CIIN capture threaded through
`biu_burst_ctrl.sv`/`biu_cycle_gen.sv`/`m68030_biu.sv` into `biu_cache_if.sv`, gating
each of the 4 `valid_d` bits individually instead of the whole line at once. Verified
via a new `tb/biu_tb.sv` test with a deliberately mixed per-beat CIIN pattern (beats
0/3 inhibited, 1/2 not), proving genuine per-word discrimination. Full Harte sweep
bit-identical to baseline. See `plan.md §Phase 229` for the full writeup. **Stage 4
(Phase 230)**: PTEST translation-fault hang, third investigation attempt — genuinely
reproduced this time (unlike the plan's own "stale I-cache line eviction" hypothesis),
root-caused, and fixed. Real cause: `tb/mmu_xlate_tb.sv`'s own Phase 6 test never
touched CACR, so it never actually exercised a genuine multi-beat I-cache burst fill
before — a new "Phase 8" test (same shape as Phase 6, but with CACR's EI+IBE genuinely
enabled via `MOVEC D7,CACR` first) reproduced a real, reliable hang on the first
attempt: a `JMP_ABS_L_OP` retired with duplicated/wrong operand words, computing a
wild odd jump target, taking a real Address Error that then hung forever. Root cause
(via a temporary trace, since removed): `tb/mmu_xlate_tb.sv`'s own inline memory
model predates the burst-address-freeze fix (real 68030 silicon holds the address
bus constant for a whole burst, MC68030UM.pdf 7.3.7) — with the address genuinely
frozen, this model's purely address-keyed read served the *identical* longword for
every beat instead of 4 distinct ones. `tb/mem_model.sv`/`tb/cache_tb.sv` were already
fixed for this (`burst_beat_probe`); `tb/mmu_xlate_tb.sv` was not — and neither is
`tb/stall_fsm_tb.sv` (confirmed via grep, byte-for-byte the same unfixed line),
almost certainly the real explanation for Phase 236's own original hang. Not an RTL
bug — a testbench-only gap shared by 8 files with their own inline memory models,
dormant everywhere none of their existing tests exercise a genuine multi-beat burst.
Fixed `tb/mmu_xlate_tb.sv`'s own model this stage (mirroring `cache_tb.sv`'s already-
proven pattern); the other 7 files' shared exposure is flagged as a real, dormant,
documented follow-up, not fixed here (disproportionate scope for one investigation
stage). Testbench-only, `git diff --stat rtl/` empty, no Harte re-run needed. See
`plan.md §Phase 230` for the full writeup. **Stage 5 (Phase 231)**: instruction-fetch
BERR should defer until decode actually needs the data. The earlier deferred-items
closure plan's own Stage 3 had confirmed this gap (MC68030UM p.6-19's "faults
immediately (data) or pending-on-use (instruction)" distinction) but left it unfixed
— a first attempt gating `bus_err` on `decode_pc_r >= bus_err_addr_r` alone broke
`tb/cache_tb.sv`'s own I-5, since `decode_pc_r` never advances to reach a faulted
word that's needed as the CURRENT instruction's own extension word (dispatch itself
requires that missing data). Fixed by threading a new `eu_need_ext` signal
end to end — `eu_seq.sv` (mirroring its own already-existing internal
`need_ext = dec_needs_ext && !ext_valid`) → `m68030_eu.sv` → `m68030_top.sv` → a new
`need_ext` input on `m68030_ifu.sv` — gating `bus_err` on
`decode_pc_r >= bus_err_addr_r || need_ext`. `bus_err_r` itself still latches
unconditionally at fault time; only the OUTPUT is gated, so either condition
becoming true later pops the fault visible with no new state machine. `tb/ifu_tb.sv`'s
own IFU-12a now asserts the fixed "stays pending" behavior directly, plus a new
IFU-12a2 proves dispatch once `need_ext` asserts; `tb/cache_tb.sv`'s own I-5 (the case
that broke the earlier attempt) stays green. Full Harte sweep bit-identical to
baseline. See `plan.md §Phase 231` for the full writeup. **Stage 6 (Phase 232, the
plan's own flagged riskiest RTL stage)**: BERR-during-fill's harder sub-case — a burst
beat failing AT OR BEFORE the CPU's own requested word (`woff_r >= dc_burst_beat_at_
berr`) used to fault unconditionally (the easier "after" sub-case was already fixed
by the earlier deferred-items closure plan's own Stage 9). Investigated the mechanism
first: `biu_cycle_gen.sv`'s FSM always returns cleanly to `ST_IDLE` after any burst
outcome (`berr_abort_r` self-clears at S7 unconditionally), so simply keeping `dc_
burst_req_r` asserted across the failure — an idiom `biu_cache_if.sv` already uses
for its own degraded-fallback continuation path — causes a genuinely fresh burst
redispatch with no new cross-module plumbing needed at all. Implemented as one new
register, `dc_retry_used_r`, gating one retry before escalating to `CI_BERR`; the
retry re-enters the exact same code on its own outcome, so a partial success falls
through to the existing success branch automatically. Found and deliberately avoided
inheriting a related pre-existing gap while designing this: the degraded-fallback
path's own `fill_base_r` is latched pre-translation and is wrong for a translated
burst (the real address comes from `xl_pa` instead, never re-synced into `fill_base_
r`) — documented, not fixed (out of scope), and sidestepped by leaving `dc_burst_
addr_r` untouched on retry rather than re-deriving it. Verified via two new `tb/biu_
tb.sv` tests (Stage 6a: retry succeeds; Stage 6b: retry also fails, escalates for
real), finding and fixing two testbench-only bugs along the way (a registered-signal
sampled-too-early timing issue; a cache-line address collision with a later,
pre-existing test). Full Harte sweep bit-identical to baseline. **Closed cleanly** —
the plan's own explicit permission to defer this stage wasn't needed. See `plan.md
§Phase 232` for the full writeup. **Stage 7 (Phase 233)**: CAS's own genuine
bus-level lock — investigated a third time (prior attempts: Phase 194 investigated,
Phase 213/242 attempted+reverted), re-deferred with a MORE PRECISE proposal than
before. Key new finding: `cas2_as_hold` (CAS2's own working fix) works only because
CAS2's 4 sub-cycles are a single self-contained state sequence `biu_cycle_gen.sv`
owns end to end, letting it reuse `state_nxt`'s own already-computed "staying inside
the sequence" decision directly. Single-address CAS has no such self-contained
sequence — its read and its conditional write are two independent dispatches through
the SAME generic `ST_READ_*`/`ST_WRITE_*` machinery every other access in the chip
shares, so there's no existing transition-table decision to reuse; any fix needs new
signal plumbing into that *shared* logic instead. Confirmed the timing IS feasible
though (traced `eu_seq_execute.svh`: `cas_z_r <= ex_z` is captured the same cycle
`mem_ack` fires, meaning the compare result is combinationally available before the
read's own AS-negate point, S5) — so the blocker is risk/blast-radius, not physics.
Updated proposal: a new combinational `eu_cas_write_pending` output from `eu_seq.sv`
(mirroring `cas_read_ack`'s own exact gating), threaded into a new `biu_cycle_gen.sv`
input, gating a new hold condition on the shared ordinary-read S5 AS-negate logic.
Deferred rather than implemented — this touches the single highest-blast-radius
shared pin logic in the project, a prior attempt in adjacent territory already
produced a hard-to-diagnose hang, and the project's own verification has no
multi-bus-master test that could even demonstrate today's gap being violated (CAS's
own single-CPU value semantics are unaffected and already fully verified). No RTL or
testbench changed. See `plan.md §Phase 233` for the full writeup. **Stage 8 (Phase
234, partial)**: MOVEM's own genuine memory-indirect EA. Widened the prefetch queue
from 6 to 7 words (`q[6]`/`ext7_valid`), mirroring Phase 145's own already-proven
pattern exactly, threaded through `m68030_seq.sv`'s own `eu_ext_valid` mux into
`eu_seq.sv`. **Found and fixed a real, self-introduced regression before it left this
session**: a first attempt widened the IFU's ambient-readahead fetch trigger
unconditionally (`q_cnt_d<=5`→`<=6`, mirroring how Phase 147 once widened `<=4`→`<=5`)
— passed `tb/ifu_tb.sv`'s own full suite but broke `tb/cache_tb.sv`'s own I-3 test
hard (decode desynced into unrelated NOP-filled memory, loading marker constants from
other test sections entirely) — the exact "readahead reaches into unintended memory"
fragility `tb/cache_tb.sv`'s own I-3 comment already documents once having had to
work around. Root-caused via a two-phase trace and confirmed by bisection that the
trigger's own unconditional aggressiveness, not the queue-depth widening, was the
cause. **Fix**: gated the deeper trigger on `need_ext` (Stage 5's own signal —
decode is genuinely blocked needing an extension word not yet queued) instead of
unconditional — `q_cnt_d<=5 || (need_ext && q_cnt_d<=6)`. Ambient readahead now
behaves exactly as before Stage 8 (zero behavior change), and the queue only reaches
for the 7th word when decode is actually stalled needing it. **Scope decision**:
investigating the remaining half (MOVEM's own genuine-indirect EA *value*, not just
word count — `movem_ext_count` already sizes the drain correctly, but the EA arm in
`eu_seq_decode.svh` still falls back to brief-format for genuine indirection) found
it needs a real extra bus read merged with the project's own existing `ex_is_memind`
3-phase FSM (already used by every OTHER family's own genuine-indirect EA,
`eu_seq_execute.svh`) — resolving the EA *once* per MOVEM instruction, then handing
it to MOVEM's own existing register-iteration logic as its starting address. This is
a genuine merge of two independently-complex state machines, materially larger than
the queue-widening just completed and closer in shape to Stage 9's own explicitly-
flagged scope — deferred as a separate follow-up rather than rushed. Full Harte sweep
bit-identical to baseline. See `plan.md §Phase 234` for the full writeup. **Stage 9
(Phase 235, survey)**: memory-indirect EA beyond MOVE. Only MOVE/MOVEA support genuine
indirect (`fi_iis!=000`) today, via `ex_is_memind` — a 3-phase FSM hardwired to MOVE's
own register-load semantics, not a reusable primitive. Every other family (LEA, CHK,
JSR/JMP, general ALU-with-EA-source, CMP2/CHK2, TAS) has the same shallow gap (indexed
EA works, `fi_iis` never checked) but needs its own execute-side work. Risk-tiered:
LEA+PEA safe to batch (no outer memory access needed); JMP/JSR, ALU-with-EA-source,
CMP2/CHK2 need outer-stage generalization; TAS (and likely Scc) needs a second bespoke
FSM extension, already flagged once before as deliberately deferred. User chose to
push through the full scope. See `plan.md §Phase 235`. **Stage 9a (Phase 236)**: LEA
and PEA now support genuine memory-indirect EA — the first families beyond MOVE/MOVEA.
LEA needed a new `memind_addr_only_r` path (skips the outer bus cycle entirely,
completing via a direct register write the moment the inner pointer read lands —
matches real hardware, which never dereferences LEA's own final EA). PEA needed a
real outer cycle but shaped as a WRITE (push to the stack) rather than a read;
found and resolved a real conflict with PEA's own existing `dec_is_pea_idx` mechanism
along the way (setting it for the memind case would have broken the FSM's own
inner-address capture — resolved by extending `ex_an_new`'s own mux with an
independent `(ex_is_pea && ex_is_memind)` arm instead of reusing that flag). Confirmed
word-count sizing needs zero changes for any of these families — `m68030_seq.sv`'s
generic `mode110_ea_src`/`memind_ext_count` mechanism (already proven for Stage 8's
own MOVEM work) already handles them all. Two new cosim tests (`tests/memind28.s`,
`tests/memind29.s`) matched Musashi's own bus trace exactly on the first real attempt.
Full Harte sweep bit-identical to baseline. See `plan.md §Phase 236` for the full
writeup. **Stage 9b (Phase 237), part 1 (JMP+JSR)**: JMP turned out to be a genuine
bolt-on, sharing LEA's own `memind_addr_only_r` shape directly. JSR needed PEA's own
outer-write shape but pushes the return PC (not the resolved EA) and jumps to the
resolved address once that completes. **Found and fixed two real bugs**: `dec_return_
pc` was hardcoded `decode_pc+4` in JSR's own mode=110 arm — wrong for ANY full-format
encoding (indirect or not), a genuine pre-existing bug never caught before since
full-format JSR is 68020+-only, outside Harte's 68000-captured corpus; fixed by
sizing it from the instruction's own actual word count. A first JSR attempt also
forgot to suppress `dec_is_mem_wr` for the memind branch (unlike PEA's own arm),
tripping `ex_an_base`'s own `(ex_is_mem_wr && !ex_is_idx) ? rd_b_data : rd_a_data`
special case (built for JSR/PEA's simple non-indexed forms) and substituting Xn for
An in the memind FSM's own inner-address capture — caught directly via a `buscmp.py`
mismatch against Musashi's own reference before fixing. Two new cosim tests
(`tests/memind30.s`, `tests/memind31.s`), both deliberately kept within `tools/
m68ksim`'s own 4KB reference window after discovering a jump target landing outside
it silently aliases onto whatever else lives at the wrapped address. Full Harte
sweep bit-identical to baseline (mandatory — the `dec_return_pc` fix touches the
ordinary, Harte-covered JSR path too). See `plan.md §Phase 237` for the full
writeup. **Stage 9b (Phase 238), part 2 -- closes Stage 9b, investigated and
deferred**: general ALU-with-EA-source (ADD/SUB/AND/OR/CMP/DIVU/DIVS/MULU/MULS/ADDA/
CMPA `<ea>,Dn`) and CMP2/CHK2. A fork survey found ALU-EA's own decode side is
genuinely tractable (10+ separate `f_mode==110` arms, but all structurally identical
to LEA/PEA/JMP/JSR's own pattern — "same small edit, repeated ~10 times"). The real
risk is entirely on the execute side: all ~10 families (plus CHK, dynamic bit-ops,
MOVE mem-to-mem indexed-dst) share ONE deferred-register-swap gate, `dyn_bit_get_Dn`
(`eu_seq_execute.svh`) — already delicately tuned across 5 existing consumer
families (its own code comments document a hand-tuned CMP2/CHK2 exclusion).
Extending it to also fire on the memind FSM's own outer-read completion risks a
regression across all five existing families at once, a fundamentally different risk
shape than LEA/PEA/JMP/JSR's own additions (none of which touched shared,
multi-consumer execute machinery). CMP2/CHK2 independently confirmed as its own hard
case: it already has a dedicated two-read FSM (`cmp2_run_r`) that would need the
memind FSM's own inner phase prepended before its existing sequence starts — the
same class of two-FSM merge Stage 8 deferred for MOVEM. **Deferred both, with a
precise proposal documented in `plan.md §Phase 238`**, matching this project's own
established precedent (Phase 158 Stage 8; Phase 213/242's CAS attempt; Stage 8's own
MOVEM half) for genuinely-harder-than-expected work found via real investigation, not
guessed at. No RTL/testbench changed this phase. **Closes Stage 9b in full** (LEA+PEA
Phase 236, JMP+JSR Phase 237, ALU-EA+CMP2/CHK2 deferred Phase 238). Stage 9c (TAS/Scc,
the plan's own hardest tier, deliberately deferred once before at Phase 116) is next.

**Stage 9c (Phase 239), final part of Stage 9 — investigated fresh, re-confirmed
deferred**: TAS/Scc's own genuine memory-indirect EA. Re-investigated from scratch
rather than just citing Phase 116's own prior conclusion. TAS's own mode=110 arm
already carries an in-code comment stating the gap directly: needs `tas_run_r` taught
an extra pointer-read phase ahead of its existing read+write sequence. Confirmed why:
TAS dispatches through the RMW-LOCKED bus protocol (`mem_rmw = ex_valid && ex_is_tas
&& ex_is_mem_rd && !tas_run_r && !tas_after_write_r`, driving `biu_cycle_gen.sv`'s own
`ST_RMW_READ_*`/`ST_RMW_WRITE_*` sequence) — the single most hardened, delicately-
tuned mechanism in the project (AS held continuously across the whole indivisible
read+write). Genuine indirect support needs the memind FSM's inner phase to complete
BEFORE `mem_rmw` ever asserts — a structural change to the RMW-lock's own dispatch
trigger, not an additive extension. Confirmed Scc shares the identical shape
(`dec_is_mem_rmw=1'b1`, same RMW path, same missing `fi_iis` check, no in-code
comment but same underlying gap). **Deferred, matching Phase 116's own original
call, now independently re-confirmed**: restructuring `mem_rmw`'s own dispatch
condition carries real risk of reintroducing exactly the class of AS-continuity bug
this project's own RMW/CAS2 hardening work (Phases 108-114, the RMW/CAS2 timing
redesign, this very backlog's own Stage 6) already fixed, for a narrow 68020+-only
addressing-mode combination with no dedicated verification coverage and no Harte
corpus presence — the same "no existing test could even prove a fix" consideration
that weighed into Stage 7's own CAS deferral. Documented a precise updated proposal
in `plan.md §Phase 239`. No RTL/testbench changed. **Closes Stage 9c, and Stage 9 in
full** — 4 genuinely new, fully-verified families added (LEA, PEA, JMP, JSR); 3
investigated fresh and deferred with precise proposals (ALU-EA, CMP2/CHK2, TAS/Scc).
Stage 10 (more back-to-back FSM composition pairs, the plan's own last item) is next.

**Stage 10 (Phase 240), final stage — closes the entire 10-item backlog plan**: added
2 new back-to-back FSM composition pairs to `tb/stall_fsm_tb.sv`, beyond the 7
already there (4 from the earlier, already-closed pipeline-stall breadth extension
plan, plus 3 — T4f/g/h — added by that same plan's own Phase 208; an in-file comment
labeling those "the last stage of this plan" is a stale artifact of that earlier plan
having once reused this same `elegant-gliding-fog.md` filename, confirmed via `git
log --follow` — not a reference to the current plan). New pairs: **T4i, MOVEM.L
(store) → CAS** — MOVEM's first appearance as a producer/store (previously only
tested as a load/consumer), feeding CAS's own compare with its fresh write; **T4j,
ABCD → SBCD** — two byte-granularity predecrement BCD FSMs chained for the first
time, SBCD's own source address deliberately equal to ABCD's own destination address
(the same "adjacent register reuse" cross-check shape T4c/T4d/T4f already
established). Both reached via a redirect from T4h's old permanent park into a
freshly-confirmed-clear ROM gap (0x3ba0-0x3c58). **Found and fixed one real
testbench-only bug** while writing the redirect: a first attempt mis-packed the
`JMP_ABS_L_OP`'s own 32-bit target across two `rom[]` slots (duplicated the address's
high word into the low-word position instead of the real low word), sending the jump
to address 0 instead of 0x3C00 — both new pairs failed with huge timeout-driven cycle
deltas on the first run; fixed by matching the file's own already-proven identical-
shape precedent two pairs earlier. `make test` 37/37; `git diff --stat rtl/` empty,
so no Harte re-run needed (testbench-only, per this stage's own plan text). See
`plan.md §Phase 240` for the full writeup, including the plan's own final tally across
all 10 stages.

**Phase 241 (`~/.claude/plans/silent-copper-latch.md`, CAS bus-lock plan, 4th
attempt)**: started implementing the AS-continuity fix for single-address CAS's own
genuine bus-level lock (a real, confirmed, previously-deferred gap — see Phase
213/242 and Phase 233). Building the plan's own mandatory AS-continuity proof test
required first tracing the real cycle-by-cycle relationship between AS-negate and
`mem_ack`, which found **Phase 233's own timing-feasibility conclusion was factually
wrong**: AS negates at `ST_READ_S6`, one full state BEFORE `mem_ack` becomes visible
at `ST_READ_S7` — there is no headroom to gate the hold decision on the compare
result (`ex_z`) as Phase 233 proposed; that mechanism cannot work. Found the correct
redesign (gate on `ex_valid && ex_is_cas` + the FSM's own existing `cas_active_r`
instead, neither of which needs the compare result) AND a third, previously
undocumented problem: the one-cycle `cas_get_du_r` gap between CAS's read and write
is a genuine arbitration re-entry point (`mem_req` really drops to 0 there, unlike
RMW/CAS2 which never release the bus mid-sequence) — fixing only the AS pin without
also defending the EU's own arbitration grant through that gap would produce a
misleadingly-continuous AS signal while a different master (most plausibly the IFU)
could actually run an unrelated transaction underneath it, worse than today's
honestly-negated gap. Deferred again with a fully corrected, trace-verified
proposal (`silent-copper-latch.md`, updated) — no RTL or testbench changed (a
temporary investigation trace was built and reverted, `git diff --stat` clean).

**Phase 242 (`~/.claude/plans/silent-copper-latch.md`, CAS bus-lock plan, 5th
attempt — IMPLEMENTED AND VERIFIED, closes the plan)**: implemented Phase 241's own
corrected proposal in full. Two new signals from `eu_seq.sv` (`eu_is_cas =
ex_valid && ex_is_cas`; `eu_cas_hold = cas_active_r` — neither needs the compare
result, sidestepping Phase 241's own timing-infeasibility finding) threaded through
`m68030_eu.sv`/`m68030_top.sv`/`m68030_biu.sv` into `biu_cycle_gen.sv`, driving a
new `cas_as_hold` override (holds AS across the read's own `ST_READ_S6`/`S7` and
the entire post-read-ack window, excluding the write's own final `ST_WRITE_S6` so
its already-correct natural negate is untouched) plus a `bus_lock` extension. The
part Phase 233 never identified: `bus_lock` reaching `biu_arbiter.sv` alone isn't
enough — its own internal `if (bus_idle)` re-arbitration needed a new `bus_lock`-
gated branch keeping the EU's grant sticky through CAS's one-cycle return to real
`ST_IDLE` (`eu_seq.sv`'s own `cas_get_du_r` step), something RMW/CAS2 never trigger
since their own dedicated state sequences never let `bus_idle` become true
mid-sequence. **Found and fixed one real testbench-only regression**: `tb/
biu_tb.sv` instantiates `biu_cycle_gen` standalone and left the two new ports
unconnected, X-propagating through `bus_lock` and breaking 4 unrelated DMA-
arbitration tests — fixed by tying both to `1'b0` there (this file never exercises
a genuine CAS sequence directly). New `tb/stall_fsm_tb.sv` tests (AS-LOCK,
AS-LOCK-MISMATCH) built and confirmed to fail on baseline BEFORE the fix (per the
plan's own mandated order), then confirmed passing after — including new
arbitration-continuity checks proving `grant_ifu` never rises and `grant_eu` never
drops during CAS's own execution window even with a genuine pending IFU request
present. Full mandatory gate: `make test` 37/37, `cosim_grp` 8/8, `cosim_memind`
18/18, full Harte sweep bit-identical to baseline despite touching the project's
single highest-blast-radius shared pin/arbitration logic. **This closes
`silent-copper-latch.md` in full** — CAS now has the same genuine bus-level lock
guarantee RMW and CAS2 already had.

**Phase 243 (general ALU-with-EA-source genuine memory-indirect EA — IMPLEMENTED
AND VERIFIED)**: implemented Phase 238's own deferred item — ADD/SUB/AND/OR/CMP/
MULU/MULS/DIVU/DIVS/ADDA/CMPA's own `([bd,An],Xn,od)` support. Decode side (8
`f_mode==110` arms in `eu_seq_decode.svh`) matched Phase 238's own "same small edit"
characterization exactly, following LEA's own template; also added a new
`dec_memind_rd_siz` field decoupling the memind FSM's own bus-read size from
`dec_siz` (needed since MULU/MULS/DIVU/DIVS's `dec_siz` reflects their 32-bit result,
not their 16-bit operand read — MOVE/MOVEA's own pre-existing memind arms backfilled
to set it explicitly, zero behavior change). Execute side needed four fixes, not the
single `dyn_bit_get_Dn` extension Phase 238 anticipated — found one at a time via
real cosim mismatches and a genuine simulation hang: (1) `dyn_bit_get_Dn`'s new
OR-term for the memind outer-read (as anticipated); (2) `memind_wr_en` gated on
`!ex_is_mem_src` (its raw-value write path fires on ANY memind read regardless of
family — would have corrupted CMP/CMPA, which write no register at all); (3)
`div_trap_raw`'s divide-by-zero check excluding memind's own INNER read (mem_ack
fires twice for memind; checking the still-in-flight pointer value as a divisor
caused a real hang); (4) a genuine one-cycle timing mismatch — `ex_mem_stall`'s own
memind term is the raw registered `memind_outer_r`, clearing one cycle after
`mem_ack` (unlike the ordinary path, which clears the same cycle) — both the
register swap and the memory operand's own value needed re-timing to a new
`memind_outer_done_r`, with a new `memind_read_val_r` latch holding the value across
the gap (`mem_rdata` itself reverts the cycle after `mem_ack`). New cosim tests
(`tests/memind32.s`-`35.s`: ADD.L, DIVU.W, CMP.L via branch-on-CCR, ADDA.L) all match
Musashi exactly; wired into `make cosim_memind` (22 total). Cross-family regression
for `dyn_bit_get_Dn`'s 5 existing consumers is structural (the new term requires
`ex_is_memind`, which none of them ever set), confirmed via unchanged `make test`
37/37. Full mandatory gate clean, Harte sweep bit-identical to baseline. Remaining
Stage 9b/9c deferred items (CMP2/CHK2, TAS/Scc genuine indirect EA) are unaffected
and still stand as documented (`plan.md §Phase 238/239`).

**Phase 244 (CMP2/CHK2 genuine memory-indirect EA — IMPLEMENTED AND VERIFIED, closes
Stage 9b's own last deferred item)**: implemented the FSM merge Phase 238 proposed —
the shared memind FSM resolves the lower bound's address/value, then hands off to
`cmp2_run_r` (CMP2/CHK2's own pre-existing two-read FSM), which independently
dispatches/captures the upper bound completely unchanged. Decode side needed a real,
family-unique derivation: CMP2/CHK2's own extra leading extension word (the
Rn+CHK2-flag word) shifts bd AND od one q-slot later than every other memind
family's generic formulas assume (the pre-existing non-indirect branch already
special-cased this for bd alone; this phase extended the same shift to od, which no
prior family needed) — resolving this required empirically re-deriving the real
`fi_iis[1:0]` od-size encoding (`01=null,10=word,11=long`) against two already-proven
tests' own raw assembled bytes, correcting a misleading (but harmlessly dead-code-safe
elsewhere) comment on `fi_od` in `eu_seq.sv`. Execute side: `cmp2_run_r`'s own start
condition gained a parallel memind-dispatch branch; `dyn_bit_get_Dn` and
`memind_wr_en` each needed a new `!ex_is_cmp2chk2` exclusion so Phase 243's general
ALU-EA memind terms don't misfire on CMP2/CHK2's own lower-bound completion. **Found
and fixed a second real, previously-latent bug** while building the cosim tests: a
genuine one-cycle `ex_mem_stall` gap specific to this family's own memind dispatch
(between `memind_outer_r` clearing and `cmp2_run_r` actually starting, since the
latter keys off the already-one-cycle-delayed `memind_outer_done_r`) let EX
prematurely accept the next instruction and corrupt `ex_is_cmp2chk2` before the
second read completed — manifesting as a spurious, well-formed CHK2 trap despite the
tested value being genuinely in range. Root-caused via direct signal tracing (not
guessed at) and fixed with a new `cmp2_memind_first_ack` stall-hold term mirroring
`cmp2_first_ack`'s own existing shape. Two new cosim tests (`memind36.s` CMP2
pre-indexed, `memind37.s` CHK2 post-indexed) both match Musashi exactly; wired into
`make cosim_memind` (24 total). Full mandatory gate clean, Harte sweep bit-identical
to baseline.

**Phase 245 (TAS/Scc genuine memory-indirect EA — IMPLEMENTED AND VERIFIED, closes
Stage 9c and Stage 9 of the 10-item backlog in full)**: implemented both remaining
Stage 9c families, which needed almost entirely different treatment. **Bug found
first, blocking**: Scc-to-memory was modeled as a genuine read-modify-write
(`dec_is_mem_rd`+`dec_is_mem_rmw`), but direct inspection of Musashi's own
`m68kops.c` (`m68k_op_scc_8_*`, one handler shared across every CPU type it
models, `tools/m68ksim.c` configured for `M68K_CPU_TYPE_68030`) showed every
Scc-to-memory form is a single plain write with no preceding read at all — a
real, previously-undiscovered bus-behavior bug invisible to Harte's
register/memory-END-STATE-only checks, found only because this phase's own new
test was the first to ever full-compare Scc's own bus trace. Fixed to
`dec_is_mem_wr` (no read phase); this flipped which branch of `ex_an_base`'s own
established "An on rd_b for plain writes, rd_a for indexed writes" convention
applies, exposing a second, self-induced `ex_ea=0` bug fixed the same session
(caught via `tb/alu_mem_tb.sv`'s own pre-existing SEQ-01 unit test before it
shipped). **Scc's own genuine indirect EA** then mirrors PEA's shape (memind
outer phase = a WRITE of the decode-time FF/00 value, new `dec_is_scc_mem`
flag). **TAS's own genuine indirect EA** (the structurally hard case Phase 239
anticipated): the RMW-LOCKED bus protocol's own dispatch trigger (`mem_rmw`/
`eu_rmw`) needed to wait for the memind FSM's own inner-pointer read to resolve
the final target address first — implemented via a clean `tas_memind_pending_r`/
`tas_memind_addr_r` hand-off (set at `memind_inner_r&&mem_ack`, using the same
live-`mem_rdata` formula LEA/JMP's own address-only completion already uses),
driving `mem_rmw`/`mem_req`/`mem_addr` until the real locked read acks, at which
point TAS's own pre-existing `tas_run_r` FSM takes over unchanged for the write.
**Found a third real bug, exposed by TAS's BYTE size specifically**: `rd_a_siz`
was missing `ex_is_memind` from its own "force longword" exclusion list (unlike
`rd_b_siz`'s directly analogous, already-correct formula) — every prior memind
family dodged this by coincidence (LEA/JMP/JSR/PEA default to longword;
Phase 243's own DIVU.W test's An value happened to survive 16-bit truncation
unchanged), but TAS's byte `dec_siz` corrupted An's own read to its
sign-extended low byte, breaking EA resolution. Fixed generally (also fixes
Scc's identical exposure). **Found two test-infrastructure gaps** while
building the cosim tests (neither an RTL bug): `tb/cosim_grp_tb.sv`'s bus
logger bracketed cycles on AS's own edge, which only logs ONE line for an
entire RMW-locked read+write pair (AS stays asserted throughout; DS toggles
per sub-phase) — fixed by triggering on DS's edges instead; `tools/buscmp.py`
didn't account for the DUT's own real address-aligned byte-lane positioning
vs. Musashi's own canonical zero-extended logging convention — fixed with
lane-aware extraction, distinguishing the two conventions by field width.
New cosim tests `memind38`/`39` both match Musashi exactly. Full mandatory
gate clean (`make test` 37/37, `cosim_grp` 8/8, `dat-synth` 50/50,
`cosim_memind` 26/26), Harte sweep bit-identical to baseline despite touching
the project's single highest-risk shared bus-protocol logic (the RMW lock).

**This closes Stage 9 (genuine memory-indirect EA beyond `MOVE <ea>,dst`) in
full** — 6 families now fully implemented and verified (LEA, PEA, JMP, JSR;
general ALU-EA and CMP2/CHK2; TAS and Scc).

**Phase 246 (`biu_icache_if.sv`'s own MMU-CI-awareness gap — IMPLEMENTED AND
VERIFIED, closes the last open item `docs/cache.md` documented)**: fixed the one
item Phase 228 had found-but-not-fixed while closing the D-cache's own analogous
`mmu_ci` staleness bug — the I-cache had zero MMU-CI-awareness at all for its own
linefill. Turned out simpler than the D-cache's own fix once investigated: rather
than needing a captured `xl_ci_r` register (the D-cache's populate decision happens
long after translation, when the shared MMU broadcast may have moved on), the
I-cache already has an existing state, `IC_FROZEN_MISS` (Phase 158 Stage 5's own
`FI=1` "fetch the requested word directly, cache array untouched"), that's
architecturally exactly right for a CI page too — CI means "not cacheable," so
there's nothing to gain from a whole-line fetch or a burst either. Routing a CI'd
translated fetch through `IC_FROZEN_MISS` (one new `|| xl_ci` term, gated on the
live port at the exact translation-complete cycle) means the cache array is never
touched for a CI access at all, sidestepping the staleness question entirely — no
new register needed. New `tb/biu_tb.sv` test (P-ICI, a new standalone `u_icache`
instance — no prior testbench exercised this module outside the full pipeline)
proves a CI=1 fetch neither bursts nor caches, with a CI=0 control proving the fix
doesn't disturb the normal path. Found and fixed one real testbench-only bug while
building it: driving a response signal via `@(posedge); signal=1;` inside a
toggling poll loop raced the DUT's own same-edge register update, hanging the
edge-detector — fixed with the same settle-before/after-edge idiom `u_cache`'s own
Stage 6 test already established. Full mandatory gate clean, Harte sweep
bit-identical to baseline (expected — Harte never enables either cache).

**Phase 247 (full documentation audit, in progress)**: user asked for a sweep of
every doc in the project for anything deferred/skipped and never closed. Found 10
items (2 real correctness gaps, the rest doc staleness or low-priority). **Item #1
(IMPLEMENTED AND VERIFIED)**: `MULU.L`/`MULS.L`/`DIVU.L`/`DIVS.L`'s own indexed EA
(`(d8,An,Xn)`/`(bd,An,Xn)`) and `#imm` forms were entirely undecoded since Phase 192
explicitly deferred them — real 68020+ code using either form hit an
illegal-instruction fault. Implemented both: indexed via the same
`dyn_bit_get_Dn` 3-operand-deferred-register trick CHK's own indexed form (Phase
84) uses (Xn on `rd_b` during the read, swaps to Dl/Dq at the ack); `#imm` needed
zero EX-stage changes (`md_src`'s own mux already had an unused
`ex_use_imm ? ex_imm : ...` branch). **Found and fixed a real bug in the first
attempt**: the full-format indexed case's own word-sized bd computed a wild EA —
this family has the SAME "extra leading descriptor word shifts every subsequent
word one q-slot later" shape CMP2/CHK2 needed a custom extraction for (Phase 244),
and the naive generic `fi_bd` formula was silently reading the muldivl descriptor
word itself as if it were the bd value. Fixed by reusing CMP2/CHK2's own exact
shifted-extraction derivation. New `tests/memind40.s` (brief-indexed, full-format-
indexed, and `#imm`, mixing MUL/DIV/signed/unsigned) matches Musashi exactly
(needed one 3-NOP settle fix for a benign IFU-readahead reordering — the first
test to combine the `#imm` form's own long artificial stall with an immediate
result-write). Full mandatory gate clean, Harte sweep bit-identical to baseline
(no Harte coverage of `.L` mul/div forms at all — 68000-captured corpus). **Item #2
(IMPLEMENTED AND VERIFIED)**: `biu_cache_if.sv`'s degraded-burst-fallback path
(`CI_D_FILL_1B`/`2B` — beats 1-3 of a burst that degrades to individual single-beat
requests, CBACK# never asserted) derived its own fallback addresses from
`fill_base_r`, a register only ever latched from the pre-translation `eu_addr` at
`CI_IDLE` — never re-synced to the translated `xl_pa` at `CI_XLATE`'s own
translated-burst-dispatch point, unlike `dc_burst_addr_r` (beat 0's own dispatch
address), which was already correct. A genuine, narrow-window bug (MMU-translated +
`CACR.DBE`-burst-enabled + degrades-to-fallback, all three at once) flagged but
never fixed since Phase 232. Fixed with one new line re-syncing `fill_base_r` at
`CI_XLATE`'s own dispatch, mirroring the pre-existing `dc_burst_addr_r` line right
above it. New `tb/biu_tb.sv` test **P-DXLB** (same manual-`xl_pa`/`xl_hit` rig as
the pre-existing P6-CI test) proves it: checks `fill_base_r` directly post-
translation, then drives a degraded burst and checks `dc_burst_addr_r` at each
fallback stage uses `xl_pa+4/8/12`, not `eu_addr+4/8/12` — confirmed to fail on
baseline (stashed the fix, reran: 4 checks failed showing the exact wrong
addresses) and pass after restoring it. Found and fixed one test-construction bug
along the way (P-DXLB's first draft cleared the shared `use_cache` testbench flag,
breaking the next test, P6-5, which — like P6-CI right before P-DXLB — relies on it
already being 1; fixed by leaving it untouched, matching P6-CI's own convention).
Full mandatory gate clean, Harte sweep bit-identical to baseline (this bug's
trigger needs a translated+burst+degraded D-cache access no Harte vector
constructs). **Items #3-#5 (FIXED)**: pure doc corrections — `docs/cache.md`'s own
closing line contradicted an earlier bullet about the (now-fixed) `fill_base_r` gap;
`port3.md` still listed MOVE indexed-src and CHK's remaining EA modes as open
(actually closed at Phase 85/86, `plan.md.old`); `README.md` claimed the Verilator
batch Harte runner isn't the default verification gate (it's been the actual
practice throughout). **Items #6-#7 (REVIEWED)**: `improve.md`/`reduce.md`'s
cosmetic refactor lists — both self-flagged historical/inactive; tagged
`improve.md`'s two untagged items `[NOT ATTEMPTED]`, `reduce.md` needed nothing.
**Item #8 (testbench bug FIXED, new coverage deliberately deferred)**:
`tb/stall_fsm_tb.sv` had the same unfixed burst-address-freeze inline-memory-model
bug Phase 230 found and fixed in `tb/mmu_xlate_tb.sv` (real silicon holds the
address bus constant for a whole burst; an address-keyed read without
`burst_beat_probe` serves the identical longword for every beat) — applied the
identical proven fix here too, zero regressions (`vvp sim/stall_fsm` still 0
failures, `make test` 37/37, `git diff --stat rtl/` empty so no Harte re-run
needed). Deliberately did NOT reconstruct the actual `WS-PTEST`/`INT-mid-PTEST`
tests in this same pass (needs a new collision-free ROM block in a file whose own
history flags that as a recurring real risk) — scoped to fixing the known bug and
documenting precisely, matching this project's own deferred-item precedent.
**Item #9 (started as a test-coverage gap, uncovered a genuine correctness bug,
FIXED)**: building CAS/CAS2/CHK2's own missing §11.6 timing benchmarks (deferred
since the original Chapter 11 rollout's own Stage A6, `plan.md.old`) found that
**CAS's Dc/Du register-field bits were swapped, and CAS2's had both its
extension-word order and within-word bit positions wrong, relative to real 68030
hardware** — confirmed against Musashi's own `m68k_op_cas_32_ai`/`m68k_op_cas2_32`
and independently via `vasm`'s own assembled bytes. Never caught in 246 prior
phases because CAS/CAS2 are 68020+-only (zero Harte coverage) and — confirmed via
grep — no cosim/bus-trace test had ever exercised either against Musashi; every
existing CAS/CAS2 test hand-picked its own opcode bytes to match whichever
convention the RTL happened to use. User consulted (`AskUserQuestion`) before
fixing, given the scope jump and the CAS/CAS2 bus-lock mechanism's own
high-blast-radius history (Phases 213/233/241/242) — chose to fix now. Fixed the
decode in `rtl/eu_seq_decode.svh` (zero `eu_seq_execute.svh` changes needed, every
consumer is register-index-agnostic); recomputed ~10 existing hand-encoded opcode
constants across `tb/stall_fsm_tb.sv`/`tb/atomic_tb.sv`/`tb/exception_tb.sv` that
encoded specific intended Dc/Du/Rn assignments under the old (wrong) convention;
added `tests/memind41.s`, the first-ever CAS/CAS2 bus-trace cosim test against
Musashi (35/35 cycles, bit-identical), closing the actual root cause. Full
mandatory gate clean (`make test` 37/37, `cosim_grp` 8/8, `cosim_memind` 28/28,
`dat-synth` 50/50, Harte bit-identical to baseline — zero CAS/CAS2/CHK2 coverage
in that corpus). **Item #10 (IMPLEMENTED AND VERIFIED)**: the bus-pipelining-
overlap plan's own Track A (Phase 163) added a CI_IDLE fast path for D-cache
writes but never for a genuine read HIT, which still took a registered
`CI_IDLE`→`CI_HIT`→`CI_IDLE` round trip — `dhit`/`idx`/`woff` are already
computed combinationally at `CI_IDLE`, the same shape Track A already proved
safe, and actually lower-risk (a hit issues no bus request, so none of Track
A's own bus-race reasoning even applies). Added a new `CI_IDLE` arm presenting
`eu_ack`/`eu_rdata` immediately on a hit. Unlike Track A's own controlled
tick-level A/B measurement, no existing harness could independently
re-confirm the tick-level win (every `tb/timing_tb.sv` test runs cache-
disabled; a `tb/biu_tb.sv` P6-3 A/B attempt showed no visible change, traced
to that test's own polling-loop structure being unable to see a same-cycle
assertion) — building fresh cache-enabled tick-precise infrastructure was
judged disproportionate for this final, explicitly speculative item. The fix
itself is verified correct (full mandatory gate clean) and structurally sound
(same proven template as Track A), just not independently tick-remeasured.
**This closes the entire 10-item documentation audit (Phase 247) in full.**

**Phase 248 (MC68030UM.pdf chapter-by-chapter compliance review, in progress)**:
user asked for a systematic direct-manual-text-vs-RTL review (distinct from the
project's existing entirely-behavioral verification — Harte, Musashi cosim,
hand-built pipeline tests), specifically flagging pin-level compliance. Produced a
10-item findings list across all 14 chapters + Appendix A; working through fixes
in order. **Item #1 (IMPLEMENTED AND VERIFIED)**: interrupt vector fetching was
always autovectored — `m68030_top.sv` hardwired `eu_iack_req=0`, so the fully-built
CPU-space IACK bus cycle (`biu_cycle_gen.sv`) never actually ran; `m68030_exc.sv`
computed every interrupt's vector as `24+level` unconditionally, so peripheral-
vectored interrupts, Spurious Interrupt (vector 24), and Uninitialized Interrupt
(vector 15) could never occur. Fixed by adding a new `EXC_IACK` state to
`m68030_exc.sv`'s dispatch FSM (reached only for interrupts) that drives a real
IACK cycle and uses its own response (`iack_vec` on ack, vector 24 unconditionally
on `iack_berr`) to determine the vector, wired through `m68030_top.sv` into the
BIU's previously-dangling `eu_iack_req`/`eu_iack_ack`/`eu_iack_vec` ports. Found
and fixed a real regression while verifying: `tb/stall_fsm_tb.sv`'s own 6
interrupt-injection tests broke because a real IACK cycle now needs an external
device to respond — fixed with a generic auto-AVEC responder (confirmed via grep
this is the *only* one of 15 `m68030_top`-instantiating testbenches that ever
triggers a real interrupt). Added `tb/exc_tb.sv` coverage for both new response
paths (EXC-12 peripheral-vectored, EXC-13 spurious). Full mandatory gate clean,
Harte bit-identical to baseline (never exercises real IPL-based interrupts).
**Item #2 (IMPLEMENTED AND VERIFIED)**: SR's M bit was hardcoded cleared for
every exception, not just interrupts (`m68030_exc.sv`'s `new_sr_comb`) — a
real bug that would silently corrupt the Master/Interrupt stack selector on
any non-interrupt exception taken with M=1 (e.g. Illegal Instruction).
Fixed by keying the clear on `snap_is_int_r` (Item #1's own dispatch-time
interrupt flag). Also implemented the Format $1 "throwaway" stack frame
§8.1.9 requires be pushed directly to ISP when an interrupt is taken with
M=1 — new `EXC_PUSH2` FSM state plus a dedicated `isp_in`/`isp_out`/
`isp_wr_en` port trio on `m68030_exc.sv`, threaded through `m68030_eu.sv`
via the same "external override OR'd with MOVEC write" pattern already
proven for VBR. Found and fixed a real regression: `tb/system_tb.sv`
instantiates `m68030_eu` directly with an explicit port list that predated
the two new ports, X-propagating into an unrelated `MOVEC An,ISP` test —
fixed with a tie-off matching the file's own existing `vbr_wr_en`
convention. New `tb/exc_tb.sv` coverage (EXC-14 non-interrupt M-preservation,
EXC-15 full M=1 interrupt with both real and throwaway frames). Full
mandatory gate clean, Harte bit-identical to baseline.

**Item #3 (IMPLEMENTED AND VERIFIED)**: MMU Configuration Exception
(vector 56) was entirely missing — PMOVE writes to TC/CRP/SRP landed
unconditionally with zero validation. Added the manual's own consistency
checks (TC: TIx/PS/IS sum must equal 32 when E=1, PS reserved values
$0-$7 rejected, E forced clear on violation; CRP/SRP: DT=0 always
invalid, register still loaded regardless) via a new `mmu_config_trap`
signal threaded `eu_seq.sv`→`m68030_eu.sv`→`m68030_top.sv`→a new
`mmu_config_req` input on `m68030_exc.sv`, dispatched Format $2/vector 56.
Found and fixed two adjacent real bugs while implementing this: Zero
Divide was using Format $0 instead of the Format $2 six-word frame Table
8-6 specifies (invisible to Harte, whose 68000 corpus has no format
words at all); and `fault_addr`'s top-level mux fed every non-bus-error
Format $2 exception (CHK/TRAPV/div_zero, and now MMU Config) the same
stale bus-fault-capture register instead of the excepting instruction's
own PC — a latent, previously-untested gap across every Format $2 user,
fixed by muxing on `bus_err_req_w || ifu_addr_err_int` specifically.
Also found and fixed a testbench-only issue: several pre-existing ROM
values in `stall_fsm_tb.sv`/`mmu_xlate_tb.sv` PMOVE-loaded TC/CRP with
degenerate all-zero placeholder data that now genuinely violates the new
check — updated to valid (if arbitrary) configs. New coverage in
`tb/special_instr_tb.sv` (MMU-08/09/10). Full mandatory gate clean,
Harte bit-identical to baseline.

**Item #4 (IMPLEMENTED AND VERIFIED)**: CED (Clear Entry in Data Cache)
cleared all 4 longwords of the CAAR-indexed cache line instead of only
the ONE longword CAAR's own index+long-word-select field names
(MC68030UM.pdf §6.3.1.4) — one-line fix, `valid_d[caar[7:4]][caar[3:2]]`
instead of a 4-iteration loop. CEI (I-cache equivalent) shares the same
manual requirement but the I-cache's own `valid_i` array is per-line
only, a pre-existing documented limitation, not touched. New `tb/
cache_tb.sv` D-14 test (same-line, different-longword selectivity) added
as a fully isolated fixed-address block (D-13's own established
convention) after an inline attempt was found to corrupt an unrelated
later test via D-cache state carryover. Full mandatory gate clean
(Harte re-run mandatory since `rtl/` changed), bit-identical to
baseline.

**Item #5 (5/7 IMPLEMENTED AND VERIFIED, 2 DEFERRED)**: 7 real pins had
zero prior RTL presence. Implemented RMC# (mirrors the existing RMW/CAS/
CAS2 lock condition minus burst), DBEN# (a precisely-derived one-state-
delayed-for-reads/same-state-for-writes AS mirror, matching MC68030UM.pdf
§7.1.6's exact timing text), IPEND# (direct one-line mirror of
`m68030_exc.sv`'s own already-computed interrupt-pending condition), and
CDIS#/MMUDIS# (new synchronized input pins overriding the D-cache/I-cache/
MMU enable logic in all three consumer modules, including duplicated
local `tc_e` copies Item #3 also had to reason about). Deferred REFILL#/
STATUS# — both are emulator-support debug signals whose semantics tie to
real 68030 silicon's own internal microsequencer staging with no faithful
analogue in this project's structurally-different microarchitecture; a
guessed implementation risked being confidently wrong with no test able
to catch it, so documented precisely instead of guessed at (matching this
project's own precedent for genuinely-hard deferrals). Found and fixed a
testbench-only regression: `tb/biu_tb.sv` instantiates the cache/MMU
submodules directly and left the new `cdis_n`/`mmudis_n` inputs
unconnected, X-propagating into every D-cache-burst test — fixed with
tie-offs, plus the same fix batch-applied to all 13 testbenches that
instantiate `m68030_top`. New pin-level tests in `tb/biu_tb.sv` (RMC/DBEN/
CDIS/MMUDIS) and `tb/stall_fsm_tb.sv` (IPEND, free across all 15 existing
interrupt-injection tests). Full mandatory gate clean, Harte bit-identical
to baseline.

**Item #6 (REMOVED, IMPLEMENTED AND VERIFIED)**: `vpa_n`/`ext_e`
(VPA#/E-clock, the 68000/68010's own legacy 6800-style synchronous-
peripheral mechanism) do not exist anywhere in the MC68030 manual
(confirmed by direct search of the full text) — the RTL's own citation
justifying it ("UM section 7.4.2") pointed to "Breakpoint Acknowledge
Cycle," an uncaught error. Consulted the user given the mechanism reached
into `biu_cycle_gen.sv`'s own core read/write/IACK termination logic;
chose full removal. Deleted `biu_eclk_gen.sv` entirely, all
`vpa_terminate`/`eclk_cnt` usage in `biu_cycle_gen.sv`, the `vpa_n`/
`vpa_s` synchronizer in `biu_config.sv`, and all pin wiring through
`m68030_biu.sv`/`m68030_top.sv`. Removed the corresponding dedicated
tests in `tb/biu_tb.sv` (P18-1/P18-2, `test_eclk_timing`) and batch-fixed
tie-offs across all 15 testbenches that instantiate `m68030_top`/
`m68030_biu`. Full mandatory gate clean, Harte bit-identical to baseline.
**Item #7 (DOCUMENTED)**: cpBcc/cpDBcc/cpScc/cpTRAPcc (coprocessor-
conditional instructions) and Coprocessor Protocol Violation (vector 13)
are unimplemented and were never previously flagged — documented as a
deliberate scope boundary above (see "Coprocessor conditional
instructions" note), since meaningfully testing them needs a real
attached coprocessor model this project doesn't have. Also fixed a
stale duplicate claim in the CPU Space sub-types bullet list below.
**Item #9 (RESOLVED BY ITEM #5)**: DBEN#'s doc/implementation mismatch
closed once item #5 made it a real, precisely-timed pin.

**Item #8 (FIXED)**: `scripts/timing_tables.py`'s own RTS/UNLK rows
(flagged for years as "not yet independently cross-verified") had real
transcription errors, confirmed by direct re-read of MC68030UM.pdf
§11.6.16: RTS's I-cache figure was `12(2/0/0)` (real: `9(1/0/0)`) and
no-cache total was `14` (real: `11`); UNLK's I-cache figure was
`9(1/0/0)` (real: `5(1/0/0)`, confirming the table's own long-standing
"I-cache > No-Cache looks wrong" suspicion). RTD/RTR already matched
exactly. Fixed the table and one downstream hardcoded stale value in
`scripts/gen_seq_tests2.py`. Pure Python data-table fix, no RTL touched.

**Item #10 (RESET input/output split + HALT-output question — DOCUMENTED, no
RTL functional change, closes the Phase 248 10-item list in full)**: the
original grounding pass (`~/.claude/plans/elegant-gliding-fog.md`) flagged two
questions items #1-9 never addressed: whether RESET's own real bidirectional
open-drain pin was being modeled correctly by this RTL's `rst_n`
(input)/`ext_rstout_n` (output) split, and whether real silicon drives HALT as
an output on double bus fault (this project already has an internal `halt_out`
signal in `biu_error_handler.sv` whose own comment called it "the MC68030
double bus fault condition," which reads as if it were a pin). Resolved both by
direct re-read of MC68030UM.pdf's own Table 5-1 and §5.10.1/§5.10.2 text:
**RESET** is confirmed genuinely "bidirectional open-drain" — the RTL's
existing `rst_n`/`ext_rstout_n` split is correct, just previously undocumented
as a deliberate real-pin split; added an explicit comment at both ports in
`m68030_top.sv`. **HALT** is confirmed **Input-only** in Table 5-1 (unlike the
68000, which does drive HALT out on double bus fault) — real 68030 silicon
signals double bus fault by continuously asserting **STATUS** instead
(§7.5.4/§8.1.2), an emulator-support pin already deliberately deferred at item
#5 for the same "no faithful analogue in this project's own microarchitecture"
reason. This project's own `halt_out` is therefore correct as an *internal*
execution-stop control signal, but its doc comment was misleading about a pin
association that doesn't exist on real silicon — fixed the comment in
`biu_error_handler.sv` to state this precisely, and added a matching note at
`halt_n`'s own port declaration in `m68030_top.sv`. Pure documentation/comment
fix — `git diff` confirmed zero non-comment lines changed in either file — so
`make test` (37/37, sanity only) was sufficient; no Harte re-run needed. **This
closes the Phase 248 10-item compliance-review list in full.**

**Superseded by Phase 250 Part B** (see below): this item's own framing —
"`halt_out` is the MC68030 double bus fault condition" — turned out to be
the actual bug, not just a misleading doc comment. `halt_out` (renamed
`retry_exhausted`) models BERR+HALT retry exhaustion, which
MC68030UM.pdf §7.5.4 explicitly excludes from double bus fault ("a bus
cycle that is retried does not constitute a bus error or contribute to a
double bus fault"). Real double bus fault is a materially different,
previously entirely undetected condition — see Phase 250 Part B for the
full fix.

**Phase 249 (code-review pass over Phase 248's own items #5/#1 — IMPLEMENTED AND
VERIFIED, two real bugs found)**: a general code-review pass over the item #5/#1
diffs (not itself one of the numbered items) found two real, previously-
undiscovered bugs. **Bug A**: MMUDIS# (item #5) was wired into three consumers'
own local `tc_e` copies but missed `m68030_mmu.sv`'s own 4th, independent copy —
with MMUDIS# asserted, PFLUSH/PTEST/PLOAD there would still dispatch a real
`biu_req` instead of the immediate no-op every other consumer now correctly
takes. Fixed with the same `tc_e = tc[31] && mmudis_n` pattern the other three
consumers already use, plus the missing `.mmudis_n(mmudis_n)` connection at
`m68030_top.sv`'s own `u_mmu` instantiation (the new port had been added to the
module but never wired at its call site — caught before it shipped, since an
unconnected input to a submodule is silently tied to X in simulation, not a
compile error). **Bug B (the more serious one)**: item #1's own real IACK
implementation wired `m68030_exc.sv`'s `iack_berr` input to the generic top-level
`eu_berr` net — which is actually `biu_cache_if.sv`'s own "properly gated
final-abort" output for the EU's ordinary cache-request path (`ca_eu_berr`,
Phase 163's own bus-pipelining-overlap fix), completely unrelated to IACK's
independent bypass route straight into `biu_cycle_gen.sv` via its own dedicated
`eu_iack_req`/`eu_iack_ack`/`eu_iack_vec` port trio. `biu_cycle_gen.sv`'s own
IACK-timeout case set the shared *generic* `eu_berr` output on `berr_abort_r`
(the same signal `biu_cache_if.sv` drives from, an entirely different
instantiation), which never reaches `m68030_exc.sv` at all — so a genuine BERR
during IACK (a peripheral that never asserts AVEC# or DSACK) was never seen by
the exception controller; `EXC_IACK` just silently redispatched a brand-new IACK
bus cycle forever (each one individually timing out via the BERR watchdog and
correctly re-entering, restarting the watchdog each time) instead of ever taking
Spurious Interrupt. Found via the new `SPURIOUS-INT` test (below) — not via Harte
(no 68000-captured corpus vector exercises this) or any pre-existing coverage
(`tb/exc_tb.sv`'s own EXC-13 only proves the standalone controller's own response
to an already-asserted `iack_berr`, never the real `biu_cycle_gen`→`m68030_top`
wiring). Root-caused with a temporary instrumented trace (dumping
`u_exc.state_r`/`u_biu.eu_iack_ack`/`u_biu.u_cg.berr_abort_r`/`u_biu.u_cg.state`/
`u_biu.u_err.wdog_r` every 20 ticks, since removed) showing the FSM cycling
`ST_IACK_S0`→`S2`→`S4`↔`S5`→(watchdog trips, `berr_abort_r` pulses one tick)→
`S6`→`S7`→`ST_IDLE`→fresh `ST_IACK_S0` — over and over — while `m68030_exc.sv`'s
own `state_r` never left `EXC_IACK`. Fixed with a new, dedicated
`eu_iack_berr` output on `biu_cycle_gen.sv` (mirroring `eu_iack_ack`'s own
existing shape exactly — set on `berr_abort_r` in the same completion branch that
used to fall through to the generic `eu_berr`), threaded through
`m68030_biu.sv`/`m68030_top.sv` into `m68030_exc.sv`'s `iack_berr` port in place
of the generic net. New `tb/stall_fsm_tb.sv` test **SPURIOUS-INT**: a new
`suppress_iack_resp` testbench flag (gating both the file's own auto-AVEC
responder added by item #1 and its generic DSACK memory-model response — a first
attempt suppressing only AVEC# still got a real, if garbage-vectored, DSACK
response instead of a genuine timeout) forces a real IACK cycle to receive
neither AVEC# nor DSACK, confirming it correctly times out and dispatches vector
24 (previously failed reliably pre-fix, confirmed via the trace above; passes
post-fix). Found and fixed one testbench-only construction issue while building
it: an early draft held `ipl_n` asserted for the entire wait loop instead of
following this file's own established convention (clear it the instant
`exc_active` is first observed, since holding IPL asserted after the controller
has already acted on it causes a legitimate re-recognition storm at every
subsequent instruction boundary on real hardware too) — not actually the cause
of the failure (the bug reproduced regardless), but fixed to match the file's own
precedent (`plan.md`'s CAS2-interrupt test, line ~1361) before the test was
considered done. Full mandatory gate clean (`make test` 37/37, `cosim_grp` 8/8,
`cosim_memind` 28/28, `dat-synth` 50/50), Harte bit-identical to baseline
(`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` — no real-interrupt vectors in that
corpus at all).

**Current state**: `make test` 37/37, `make cosim_grp` 8/8, `make cosim_memind` 28/28,
`make dat-synth` 50/50. Full 124-suite Tom Harte sweep: `PASS 702142 FAIL 2 [documented
ASL.b corpus anomaly] SKIP 281221 TIMEOUT 0`, unchanged since Phase 112 (only the SKIP/PASS
split has shifted slightly across later phases as harness gaps closed). The 10-item
backlog plan (`~/.claude/plans/elegant-gliding-fog.md`), the CAS bus-lock plan
(`~/.claude/plans/silent-copper-latch.md`), and the Phase 247 documentation audit
(10/10 items) are all CLOSED IN FULL. Stage 9's own genuine-memory-indirect-EA work
closed at Phase 245, and `docs/cache.md`'s own last open item closed at Phase 246.
The manual compliance review (Phase 248, `~/.claude/plans/elegant-gliding-fog.md`)
is CLOSED IN FULL — all 10 items resolved. Phase 249 (a code-review pass over
items #1/#5, two real bugs found and fixed) is also closed.

**`plan.md` was archived a second time at Phase 250** (grown to ~8800 lines,
same reason/pattern as the original Phase 162 archival) — the pre-Phase-250
full history now lives in `plan.md.old2` (Phases 162-249), alongside the
original `plan.md.old` (Phases 1-161); the live `plan.md` now starts fresh
at Phase 250. **Phase 250 (a second, independent MC68030UM.pdf chapter-by-
chapter compliance review)** covered Ch.2/3/4/12 plus a fresh look at
Ch.8's exception vector/priority table and Ch.7's CAS2/MOVEP cycles,
producing a 10-item findings list — see `plan.md §Phase 250` for full
citations. Status: **F1/F2/F3/F4/F5/F7/F8/F10 IMPLEMENTED AND VERIFIED**;
F9 investigated and confirmed NOT a bug; F6 investigated, found more
invasive than scoped, deferred.

**F2 (MOVES) + F3 (PFLUSH/PLOAD/PMOVE/PTEST) — IMPLEMENTED AND VERIFIED**:
both were entirely missing their own privilege check (§4.2/Table 3-14
both require supervisor state) — user-mode code could read/write
supervisor address spaces via MOVES, or reconfigure the MMU/flush the ATC
via the four PFLUSH/PLOAD/PMOVE/PTEST forms, with no trap. Fixed with the
same `if (!sr_live[13]) dec_is_priv=1` idiom every other privileged
instruction in `eu_seq_decode.svh` already uses. New `tb/system_tb.sv`
tests PRIV-02..06 confirmed to fail on baseline, pass after.

**F4 (CHK2/CMP2 wrapped bounds) — IMPLEMENTED AND VERIFIED**: Table
3-12's real C-flag formula has a second branch for a wrapped range
(UB<LB, a documented 68020+ idiom); the RTL unconditionally implemented
only the `LB<=UB` branch — also wrong for the actual CHK2 trap decision,
not just the flag. Fixed in `eu_seq_execute.svh`'s `cmp2_c_w`. New
`tb/ea_extended_tb.sv` tests CMP2-02/03 confirm the diverging case fails
on baseline, passes after.

**F5 (fabricated Format $9) — IMPLEMENTED AND VERIFIED**:
`biu_exc_capture.sv`'s `determine_format()` no longer special-cases
`mmu_fault` — MMU-detected bus faults now correctly select the ordinary
$A/$B frame like any other bus error (by R/W, matching every other bus
error), exactly as real silicon does. `m68030_exc.sv`'s own `FMT_MMU`
constant was renamed `FMT_CPMID` and corrected to its real size/shape
(10 words, matching the actual Format $9/Coprocessor Mid-Instruction
frame Table 8-6 defines — unreachable via any implemented trigger, kept
defined only for shape-consistency with `FMT_FPU_PI`/`FMT_FPU_PR`'s own
already-established "defined but never dispatched" treatment). Updated
`tb/exc_tb.sv`'s EXC-9 (now tests the generic frame-shape infrastructure
directly, not a fictional "MMU fault") and `tb/mmu_xlate_tb.sv`'s Phase
3/4 (now correctly expect $A for the read-fault case, $B for the
write-fault case) — both confirmed passing. The frame-format table above
was also corrected (previously self-documented the same fabrication).

**F7 (exception priority-chain order) — IMPLEMENTED AND VERIFIED**:
`m68030_exc.sv`'s `always_comb` priority chain didn't match Table 8-5 —
`bus_err_req` was checked before `addr_err_req` (Address Error is
strictly higher priority per 1.0 vs 1.1), and `int_pending` was checked
3rd, ahead of `illegal_req`/`priv_req`/`trace_req`/`chk_req`/
`div_zero_req`/`trapv_req`/`trap_req`, every one of which Table 8-5 ranks
strictly higher priority than Interrupt (4.2, the lowest priority of any
exception in the table). Reordered to match Table 8-5 exactly. New
`tb/exc_tb.sv` test EXC-16 proved the race is genuinely reachable
(drives `illegal_req` and a pending unmasked interrupt the same cycle) —
baseline dispatched the interrupt (wrong), the fix dispatches Illegal
Instruction (correct).

**F6 (RTE version-number check) — investigated, deferred, more invasive
than scoped**: implementing this properly turned out to require RTE to
perform a genuinely NEW bus read it doesn't do today — `rte_phase_r`'s
own FSM only ever reads 2 words (format/vector+SR, then PC) and
determines the extra byte count to SKIP via `rte_frame_extra()`, never
actually reading back any of the rest of the frame's own content (SSW,
fault address, DOB, internal registers, or the version-number word at
SP+$36). A correct fix needs a new conditional read step in RTE's own
delicate FSM, specifically for Format $B. Given the check's own stated
purpose ("required in a multiprocessor system," per §8.1.8 — not
applicable to this single-CPU project, which only ever constructs and
pops its own frames) and the risk of adding new bus-read machinery to
RTE's return path without dedicated care, this was deferred rather than
rushed — matches this project's own precedent for "found harder than
expected mid-implementation" (Phase 238/239). Not implemented this
session.

**F1 (RMW/CAS2/CAS AS# continuity) — IMPLEMENTED AND VERIFIED, same
session, following a dedicated investigation**: the initial finding was
confirmed with a second, independent source before touching anything —
Figure 7-35 (Synchronous RMW Flowchart) shows the identical "negate then
reassert" pattern as Figure 7-29 (Asynchronous), both visually inspected
directly from the rendered PDF pages, not OCR text. Root cause found: a
full-text search confirms "maintains AS, DS...throughout" (the quote
Phases 108-114/207/242 built the AS-continuity model on) appears exactly
once in the whole manual, describing **Burst Mode's own State 3**
(§7.3.7) — a different cycle type, misapplied to RMW/CAS2/CAS. RTL trace
confirmed the fix is cleanly isolated: `bus_lock`/`rmc_active` (the real
"indivisible operation"/bus-ownership guarantee) are independently
derived from `is_rmw_write`/`is_cas2`/`eu_cas_hold`, never gated on the
three AS-hold overrides — removing them doesn't touch arbitration at
all, only the AS *pin's* own toggling. Removed `rmw_as_hold`,
`cas2_as_hold`, and `cas_as_hold` from `biu_cycle_gen.sv` — the
underlying S0-S11 RMW/CAS2 state shape (Phase 207's own derivation)
already naturally produces the correct negate-then-reassert behavior via
its existing per-state `ext_as_n` logic once the overrides suppressing
it are gone; no other RTL change was needed. Rewrote
`tb/biu_tb.sv`'s P15-1 (now proves AS genuinely negates then reasserts,
was the opposite) and `tb/stall_fsm_tb.sv`'s AS-LOCK match-case test (now
expects AS to negate exactly twice across CAS's own read+write, was
expecting exactly once) — AS-LOCK's own arbitration-continuity checks
(IFU never preempts, EU grant never drops during the gap) needed no
change and still pass, confirming the ownership-lock/pin-toggling
distinction directly. AS-LOCK-MISMATCH (read-only, no write phase) was
already correct and unaffected. Full mandatory gate clean (`make test`
37/37, `cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50), Harte
bit-identical to baseline — despite touching the single highest-risk
shared bus-protocol logic in the project (Phases 108-114/207/232/241/242
all previously built on the wrong premise this corrects).

**F8 (MOVE16 doesn't exist on the MC68030) — IMPLEMENTED AND VERIFIED**:
it's an MC68040 instruction (exhaustive MC68030UM.pdf text search found
zero occurrences); this project had fully implemented it as real 68030
silicon behavior. User chose removal. Key finding that shaped scope:
`m68030_top.sv` hardwired `eu_m16_req=1'b0` at the `m68030_biu`
instantiation — the BIU's own dedicated MOVE16 burst-write mechanism
(`biu_burst_ctrl.sv`'s write mux, `biu_cycle_gen.sv`'s `ST_BWRITE_*`
states, `m68030_biu.sv`'s own `eu_m16_*` ports) had **never fired in this
project's history**, fully dead code unreachable from the live datapath —
the real, working implementation lived entirely in `eu_seq_execute.svh`'s
own `move16_run_r` FSM (4 ordinary longword reads then 4 ordinary
longword writes via the generic `mem_req` path, the same shape
`movem_run_r` uses, not a genuine burst cycle at all). Removed the live
decode arm (`rtl/eu_seq_decode.svh` — the freed opcode space now falls
naturally into the existing generic FPU-coprocessor fallback, exactly
matching real 68030 behavior for any cpid=1 F-line encoding not otherwise
claimed) and the entire `move16_run_r` FSM (`rtl/eu_seq_execute.svh`).
Deliberately left the already-dead BIU-side plumbing untouched
(documented, not fixed — it shares plumbing with the live burst-READ
path, untangling it is separate, higher-risk work with no functional
benefit since it's already provably unreachable); added a comment at
`m68030_top.sv`'s own tie-off marking it a *permanent* stub. Testbench:
removed `tb/data_move_tb.sv`'s MOVE16 tasks/tests; flipped
`tb/special_instr_tb.sv`'s FPU-06 (now proves the former MOVE16 opcode
genuinely dispatches as FPU coprocessor space); five `tb/stall_fsm_tb.sv`
removal sites (B-8, BERR-mid-MOVE16, INT-mid-MOVE16, WS-MOVE16-1/2, T4f
CAS2→MOVE16), each retargeting a JMP to skip the removed block. **Found
and fixed two real, previously-latent testbench bugs while re-verifying
this removal, neither an RTL bug**: (1) retargeting the JMP entry point
for INT-mid-ABCD/SBCD directly to `0x26C4` (skipping MOVE16's own code)
exposed that `INT-mid-ABCD`'s own test was missing the explicit JMP
redirect to its own next test that every other test in this file uses —
it fell through NOP-padding all the way to `0x2784` (SBCD's start), a
span that includes `0x26F0`, ABCD's OWN predecrement write destination
(`A0=0x26F1`). That write legitimately turns the NOP sitting at `0x26F0`
into a real, non-NOP opcode via genuine self-modifying-code semantics —
and since `0x26F0` sat directly on the fall-through execution path, the
CPU decoded and executed the corrupted opcode instead of ever reaching
SBCD's code, hanging `INT-mid-SBCD` and cascading into every test after
it (~48 failures). This exact hazard was already latent before the F8
retarget (B-10's own ABCD test avoids it by using isolated scratch
addresses far from any code — this test didn't), just newly exposed by
the timing change. Fixed with a one-line explicit JMP from ABCD's tail
straight to SBCD's start, matching this file's own established
convention. (2) That fix alone still left one failure: `WS-PMOVE64`'s
own `elapsedX > elapsed0` timing check inverted (155 > 143) because
retargeting the WS-MOVE16 JMP to land directly on `0x3E34` made
`WS-PMOVE64-1`'s own timed run the very first fetch of that I-cache line
(EI=1/IBE=0 degraded single-beat mode has been active since ~0x2DA0) — a
cold-miss penalty that used to be masked by ambient-readahead getting a
head start while falling through WS-MOVE16's own longer instruction
stream. Fixed by restoring a short, collision-free NOP runway
(`0x3E04`-`0x3E33`) between the JMP landing and the real code, giving
readahead the same head start the old flow provided incidentally. Full
mandatory gate clean (`make test` 37/37, `cosim_grp` 8/8, `cosim_memind`
28/28, `dat-synth` 50/50), Harte bit-identical to baseline (MOVE16 has
zero Tom Harte coverage — 68000-captured corpus, MOVE16 is 68040-only).
See `docs/stalls.md` for the corresponding count corrections (Category F
18→17, Category H 14→13, back-to-back FSM pairs 9→8).

**F9 (STOP + trace interaction) — INVESTIGATED, CONFIRMED NOT A BUG**:
§8.1.7 requires STOP that begins execution with tracing (T1) already
enabled to force a Trace exception immediately after loading SR, and to
never actually enter the stopped condition. Flagged "plausible, not
confirmed" since `stop_r`'s own presence in `ex_mem_stall`'s OR-chain
could plausibly gate `eu_trace_req` shut before it ever fires. Built a
real end-to-end test (`tb/stall_fsm_tb.sv`, new **F9**) rather than
reasoning about it in the abstract: `MOVE.W #imm,SR` sets T1=1, then
`STOP` immediately follows. Traced the exact cycle-by-cycle timing and
confirmed the mechanism is correct by construction: `dec_is_trace` is
computed combinationally at DECODE time (using the OLD SR, before
STOP's own SR write ever commits, since decode strictly precedes EX),
so `ex_is_trace`/`eu_trace_req` are already latched true by the same
cycle STOP first enters EX — one full cycle *before* `stop_r` itself
transitions to 1 (a registered signal, visible only starting the *next*
cycle) even reaches `ex_mem_stall`'s own OR-chain. `m68030_exc.sv`'s own
`EXC_IDLE`→`EXC_PUSH` transition only needs `exc_pending` true for that
one cycle to latch its dispatch decision (and independently snapshots
`fault_sr` the same edge, correctly capturing the OLD T1=1 SR before
STOP's own write — two independent flip-flops sampling their own
combinational inputs on the identical edge, no race). `stop_r` does
still assert for one internal cycle (confirmed via direct trace,
`eu_stop` briefly 1) before `exc_sr_wr_en` (fired by ANY exception
reaching `EXC_LOAD`, not just interrupts — the same existing mechanism
that already resumes STOP on a real interrupt) clears it — this is a
purely internal, non-externally-observable transient (STOP produces no
bus cycles either way), not a real "entered the stopped condition"
violation. Confirmed execution correctly resumes at the instruction
after STOP post-RTE (not re-executing STOP, not staying halted).
**Found and fixed one real bug in the test's own construction, not the
RTL**: a direct `rom[]` memory dump (needed to debug why the trace
handler's own `ANDI.W #$7FFF,(A7)` fix — meant to clear T1 in the
stacked frame before RTE, else every subsequent instruction retraces
forever — didn't work) found this RTL's own Format $0 frame packs
`{fmtvec, SR}` together as one longword at the frame's LOW address
(fmtvec upper 16 bits, SR lower 16 bits) with PC at the HIGH address —
`(A7)` alone addresses the fmtvec half, not the SR half; fixed to
`(2,A7)`. **Flagging this layout as a separate, NOT independently
verified compliance question** for a future session: this ordering
appears to differ from the real 68030's own documented SR/PC/format-
vector arrangement (SR lowest, PC middle, format/vector highest), and —
confirmed via grep — no existing test in this project has ever
independently dumped raw frame memory to check byte-for-byte layout
(every existing frame-format test checks a derived format-code/register
end-state, never the physical bytes); the RTL is internally
self-consistent (the same code both pushes and later pops its own
frames) so this has never surfaced as a functional failure, but it may
be a genuine, previously-undiscovered structural bug worth its own
dedicated investigation (re-derive against MC68030UM.pdf's actual frame
diagrams directly, not from memory) before concluding either way. Also
found a real, previously-latent testbench bug reusing the exact "ROM
write issued after simulated time already passed that address" class
this file's own history already documents: the JMP redirect skipping
this test's own ROM setup was first placed in the *runtime* polling
section (after AS-LOCK-MISMATCH's own checks) instead of upfront
alongside every other test's own setup — fixed by moving it there. Full
mandatory gate: `make test` 37/37 (testbench-only, `git diff --stat
rtl/` empty, no Harte re-run needed).

**F10 (STATUS pin, double-bus-fault sub-case) — IMPLEMENTED AND
VERIFIED**: MC68030UM.pdf Table 12-4/§7.5.4/§8.1.2's real STATUS pin
(confirmed active-low, Output, per the Chapter 5 signal summary table)
has 4 distinct meanings; 3 (1/2/3-clock pulses tied to instruction-
boundary/trace-interrupt/MMU-dispatch microsequencer staging) need real
microsequencer-cycle correlation this project's structurally different
microarchitecture has no faithful analogue for, matching Phase 248 item
#5's own REFILL#/STATUS# deferral reasoning — left deliberately
unimplemented. The 4th — continuously asserted = processor halted due
to double bus fault — is NOT microsequencer-timing-dependent at all,
just a sticky bit, and this project already computes exactly that
condition (`biu_error_handler.sv`'s `halt_out`) but never latched or
wired it to any pin; `halt_out`'s own header comment already says "the
top-level should register it to avoid glitches" — this closes that gap.
Added a new sticky register (`m68030_biu.sv`'s `status_r`, set on
`halt_out`, cleared only on reset) and a new `status_n` output port,
threaded straight through `m68030_top.sv` as a genuine top-level pin.
New output ports never need existing-testbench tie-offs (unlike new
*input* ports, per item #5's own precedent) — confirmed via `make test`
37/37 with zero testbench changes beyond the one dedicated new test.
New coverage in `tb/biu_int_tb.sv` (the only file that instantiates the
real `m68030_biu` directly, rather than testing its submodules in
isolation): a genuine BERR+HALT retry (via a new `suppress_dsack`
testbench override, since `mem_model.sv` has no address-range gating to
exploit for "no device responds") proves `status_n` asserts on a real
double bus fault and stays asserted (sticky) long after the underlying
condition passes, clearing only on reset. **Found and fixed one real
test-construction bug while building it**: asserting `halt_n` before or
simultaneously with `eu_req` never even started the bus cycle at all
(real HALT# gates cycle *initiation* itself, via `bus_halted`'s own
`!halt_s` term keeping the FSM parked in `ST_IDLE`) — fixed by letting
the cycle dispatch first, then asserting HALT# partway through,
matching what real hardware actually requires (HALT#/BERR# sampled
together at fault recognition, not from the cycle's own start). Also
noted, not fixed (out of scope for a pin-wiring task): `halt_out`
itself fires on the SAME cycle as `retry_pending` in this exact test
scenario, since `berr_timeout` is a sticky latch held until `bus_idle`
rather than a one-cycle pulse — a pre-existing nuance of `halt_out`'s
own formula that `tb/biu_tb.sv`'s own existing test never distinguished
either. Full mandatory gate clean: `make test` 37/37, `cosim_grp` 8/8,
`cosim_memind` 28/28, `dat-synth` 50/50, full 124-suite Harte sweep
bit-identical to baseline.

**Superseded by Phase 250 Part B** (see below, a later session):
`status_n` here was wired to `halt_out`/a genuine BERR+HALT retry, which
is explicitly NOT what MC68030UM.pdf §7.5.4 calls double bus fault (a
retried cycle "does not constitute a bus error or contribute to a double
bus fault"). This item's own "proves `status_n` asserts on a real double
bus fault" claim above was wrong — it proved `status_n` asserts on
*retry exhaustion*, a different, real, but differently-named condition.
Part B rewires `status_n` to a genuine new `double_fault` signal from
`m68030_exc.sv` and renames `halt_out` to `retry_exhausted` to stop
conflating the two. This test (`tb/biu_int_tb.sv`) was split into two
accordingly.

**This closes the entire Phase 250 10-item findings list** except F6
(investigated, deferred, documented above) — the last one to remain
open, by explicit choice given its own real risk to RTE's delicate FSM.

**Exception frame layout fix (Phase 250, IMPLEMENTED AND VERIFIED) — a
side finding from F9's own investigation, not one of the original 10
items**: every exception frame format packed `{format/vector, SR}` as
the first longword and PC as the second — confirmed via direct
inspection of MC68030UM.pdf Table 8-6/Figure 4-1 that real silicon's own
layout is different in kind, not just order (SR alone at SP+0, PC at
SP+2, format/vector alone at SP+6). Internally self-consistent (the same
code both pushes and later pops its own frames via RTE), so it never
surfaced as an observable failure in 250 prior phases — no existing test
ever inspected raw frame memory. Also found and removed a second,
closely related fabrication while re-deriving the layout: "Format $3, 8
words, Address Error" never existed either (Table 8-6 has no $3 entry;
§8.1.3 says Address Error uses the same $A/$B shape Bus Error does) —
the same shape as the already-fixed old "$9, MMU short bus fault" claim
(Phase 250 F5). Fixed `rtl/m68030_exc.sv`'s own `push_data` table (byte-
correct longword pairs; `$A`/`$B`'s own SSW/DCFA/DOB remapped to their
real offsets; `$9`'s own stray unconditional SSW write at step 3, a
third small adjacent bug, also fixed) and `rtl/eu_seq_execute.svh`'s own
RTE two-phase read to match. **Found and fixed one real, previously-
latent bug in the RTE fix's own first attempt**, caught via a live
regression (not guessed at): a same-cycle read-before-write hazard on a
new `rte_fmt_skip_r` register (needed to size RTE's own final A7 write,
now computed from phase 1's read instead of phase 0's, since fmtvec
moved) — its own consumer fires the identical cycle the register would
have updated, reading the stale value. Fixed by computing the skip
combinationally from the live `mem_rdata` at the point of use instead of
through a register. Also found and fixed roughly a dozen hand-crafted
test frames across `tb/stall_fsm_tb.sv`/`tb/system_tb.sv`/
`tb/exception_tb.sv`/`tb/exc_tb.sv` that encoded the old (now-wrong)
layout by hand — `tb/exc_tb.sv`'s own detailed push-data checks (every
implemented format, every step position) now directly verify the
byte-exact new layout, the closest thing this project has to independent
frame-content verification.

**Found a genuine full-Harte-sweep regression this time (RTE suite:
4011 runnable, most FAIL/TIMEOUT) — root-caused to the SCRIPT, not the
RTL, and fixed at its source.** `scripts/gen_harte_hex.py` has its own
long-standing, hand-built workaround for RTE specifically: the Harte
corpus is 68000-captured, whose native RTE frame is just {SR,PC} (3
words, no format field — a 68010+ concept), so the script synthesizes a
format word and shifts the test's own initial SSP by -2 bytes to line
those synthetic+real bytes up with whatever this RTL's RTE actually
reads. That shift was hand-tuned for the OLD (now-fixed) `{fmtvec,SR}`+
`PC` layout specifically — updated to match the new layout (no initial
shift needed; the synthesized format word instead goes at `a7_val+6`,
past the reference's own 6 real bytes) and `scripts/run_harte.py`'s own
`compare()` gained a matching `+2` final-SSP compensation (the old
version absorbed this into the shift itself; the new layout has no
shift left to absorb it into). **A second, deeper, previously-latent gap
surfaced during this same investigation, independent of the frame-layout
fix**: some RTE test vectors restore a `T1=1` (or `T0=1` with a
flow-change next instruction) SR — real, architecturally-correct
behavior this project's own trace mechanism (already hardened during
this same session's F9 investigation) handles correctly, confirmed via
direct signal tracing (`decode_pc` genuinely advanced past the restored
PC's own first instruction, side effects already retired, before a real
Trace exception dispatched) — but `gen_harte_hex.py` never installed a
vector-9 (Trace) handler for RTE tests, only vector-3 (Address Error,
for `is_ret_taken`'s own odd-PC case) and vector-8 (Privilege
Violation). The OLD, wrong RTL frame layout apparently never triggered
this in practice (its own garbled reconstruction essentially never
produced a genuinely valid, directly-executable restored PC with a real
`T1=1` SR at the same time), so the gap was invisible until the layout
fix made RTE's own reconstruction correct enough to actually reach it.
Fixed by installing vector 9 unconditionally for every RTE test,
pointing at the same STOP+NOP runway vector-3 already uses (mirrors the
existing pattern exactly). Full mandatory gate clean: `make test`
37/37, `cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50, full
124-suite Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2`
— the documented ASL.b corpus anomaly — `SKIP 281221 TIMEOUT 0`),
including the previously-broken RTE suite now at a clean 4011/4011.

**Phase 250 Part B (genuine double-bus-fault detection — IMPLEMENTED AND
VERIFIED, a later session, `~/.claude/plans/wobbly-honking-cascade.md`)**:
closes out the second side finding from the same F9 investigation that
led to the frame layout fix above. §7.5.4/§8.1.2/§8.1.3 are explicit that
double bus fault is a bus or address error occurring WHILE the exception
controller is already dispatching a PRIOR bus or address error (or a
reset) — a materially different, narrower condition than `halt_out`
(BERR+HALT retry exhaustion, wired to the Phase 250 F10 `status_n` pin),
which the manual explicitly excludes ("a bus cycle that is retried does
not constitute a bus error or contribute to a double bus fault").
**B1 (empirical confirmation, not just code-reading)**: built a
throwaway test injecting a genuine, persistent BERR onto the exception
controller's own frame-push write specifically (not just the original
faulting access). Found the real mechanism is subtler than a classic
"stuck FSM waiting for an ack that never comes": `m68030_exc.sv`'s own
`exc_req`/`exc_addr`/`exc_wdata` are purely combinational off
`state_r`/`push_step_r`, with zero reaction to any berr signal anywhere
in `EXC_PUSH`/`EXC_FETCH`/`EXC_PUSH2` — so when `biu_cache_if.sv`'s own
`CI_BERR` state aborts and returns to `CI_IDLE`, the still-unconditionally-
asserted request causes an immediate, silent redispatch of the identical
write. A transient fault therefore self-heals (retries until it
succeeds) with zero reported condition; a *persistent* fault retries
forever with zero forward progress and zero reported condition — the
real, confirmed gap, just via infinite silent retry rather than a
classic deadlock. **B2 (implementation)**: new `snap_is_berr_r` (captures
`addr_err_req||bus_err_req` at dispatch, mirrors `snap_is_int_r`'s own
pattern) plus a new `dispatch_berr` input (fed from the top level's own
`eu_berr` — already a clean one-shot-per-fault signal from Phase
108/109/113/114's own earlier fix — gated to `exc_active` so only this
module's own bus requests trigger it) detect the real condition and
divert into a new terminal `EXC_DBLFAULT` state (reachable from
`EXC_PUSH`/`EXC_FETCH`/`EXC_PUSH2`/`EXC_IACK`, though the last two are
structurally unreachable in practice since `snap_is_berr_r` and
`EXC_IACK`/`EXC_PUSH2` are mutually exclusive by construction — an
interrupt dispatch is never a bus/address-error dispatch). No second
frame is attempted (real silicon doesn't either); a new sticky
`double_fault` output stays asserted until reset. Confirmed
`exc_active`'s own existing "gates new EU instruction issue" behavior
already halts forward progress for free once `state_r` never returns to
`EXC_IDLE` — no separate freeze mechanism was needed. **Found and fixed a
real, previously-undiscovered PRE-EXISTING bug while verifying this**:
the full mandatory gate's own `mmu_xlate_tb.sv` Phase 4 test (a
write-protect violation) started failing — traced (not guessed at) to
`biu_mmu_arb.sv`'s own `d_wp = mmu_wp`, a raw, ENTIRELY UNGATED broadcast
of the MMU's own WP-status register (unlike `d_hit`/`d_walk_done`, which
already ARE gated on `owner_r==OWN_D`) — sourced from `biu_mmu_if.sv`'s
own `wp_r`, a register that only updates when a request genuinely
completes, exactly the same shape Phase 228's own `xl_ci_r` fix already
guards `xl_ci` against, but never extended to WP at the time. Checking
it unconditionally every `CI_XLATE` cycle (as `biu_cache_if.sv` used to)
reads the PREVIOUS request's own stale WP result for however many cycles
the NEW request's own translation takes to complete — confirmed via
direct trace: a supervisor frame-push immediately following an unrelated
WP-faulting user access spuriously re-faulted 3 times (each
indistinguishable from a genuine, independent WP violation to anything
watching for a second fault, exactly matching B2's own new detection)
before a 4th, genuinely-completed lookup finally returned the correct
non-WP result. This bug was harmless before B2 (nothing ever reacted to
a spurious, self-resolving WP re-fault); B2's own new detection was
simply the first thing to ever notice it. Fixed by gating the WP check
on `(xl_hit||xl_walk_done)` — the same condition the success branch
already requires — mirroring `xl_ci_r`'s own "captured at completion"
discipline instead of reading a raw live broadcast. `xl_fault` itself was
left unchanged (Phase 3's own fault+RTE-retry test already exercises it
back-to-back with other translated accesses and passes both before and
after this fix). **B3 (rewiring)**: renamed `halt_out`→`retry_exhausted`
throughout (`biu_error_handler.sv`/`m68030_biu.sv`/`m68030_top.sv`) and
corrected every doc comment that used to call it the double-bus-fault
condition; `status_n` now registers off the new `double_fault` signal
instead (threaded `m68030_exc.sv`→`m68030_top.sv`→`m68030_biu.sv` as a
new input port, alongside `m68030_biu.sv`'s own existing `retry_exhausted`
output — siblings under `m68030_top`, not nested). `tb/biu_int_tb.sv`'s
own Phase 250 F10 test (the only file instantiating real `m68030_biu`
directly) was split into two: one exercising `retry_exhausted` via a
genuine BERR+HALT retry (proving it's no longer wired to `status_n`),
and one exercising `status_n` via a new testbench-driven `double_fault_tb`
input directly (this module has no real `m68030_exc` to produce a
genuine one — `tb/exc_tb.sv`'s own EXC-* tests cover the detection logic
itself). `tb/biu_tb.sv`'s own standalone `biu_error_handler` test and
`tb/exc_tb.sv` both updated for the renamed port. Full mandatory gate
clean: `make test` 37/37, `cosim_grp` 8/8, `cosim_memind` 28/28,
`dat-synth` 50/50, full 124-suite Harte sweep bit-identical to baseline
(`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`). **This closes the 2-part
plan (`~/.claude/plans/wobbly-honking-cascade.md`) in full.**

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
make sim/harte_batch                              # Icarus backend (build once)
make sim/harte_vbatch                             # Verilator backend (build once)
python3 -u scripts/run_harte_batch.py tests/harte/*.json.gz tests/harte/*.json.bin \
    --backend verilator -j 10 --chunk-size 300     # full 124-suite corpus in ~3m18s
# (chunk-size 150 is the tuned default for the Icarus backend specifically;
#  the Verilator full-sweep timing above was measured at chunk-size 300)
```

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

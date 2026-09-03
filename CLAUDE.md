# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cycle-accurate Motorola MC68030 CPU implementation in SystemVerilog/Verilog. The goal is pin-level cycle accuracy: every external bus signal (AS, DS, RW, FC, SIZ, etc.) must assert and deassert on the exact S-state cycle the real silicon does. `output.txt` contains the architectural design conversation that established the requirements and module structure.

## Design Constraints

**Clock strategy**: Run the Verilog design at **4× the external bus frequency** (e.g., 100 MHz internal for 25 MHz bus). This gives 4 clean ticks per external clock cycle to map S-states without relying on `negedge` triggers. All logic must be synchronous — no latches, no asynchronous resets.

**No cheating cycles**: If an instruction takes N cycles on real silicon, the FSM must take exactly N cycles. Do not collapse or optimize timing.

**External inputs are asynchronous**: `BERR`, `BR`, `IPL`, `HALT`, `VPA`, `DSACK0`, `DSACK1`, `STERM` must pass through 2-stage synchronizer flip-flops before any logic uses them. (The 68030 uses DSACK, not DTACK.)

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
│   ├── biu_burst_ctrl      Burst linefill + MOVE16 burst control
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
- MOVE16 (four distinct opcode forms; each has a different burst pattern)
- Interrupt Acknowledge — FC=111 (CPU Space), AS and DS both assert; address bus encodes interrupt level in A[3:1] with A[31:4]=all-1s ($FFFFFFF2–$FFFFFFFE for levels 1–7); peripheral responds with DSACK and drives vector on D[7:0]
- Coprocessor interface (FPU) — FC=111 (CPU Space) cycles with A[19:16]=0010 identifying CPU Space type 2 (coprocessor access, distinct from IACK's own A[19:16]=1111 pattern); A[15:13] selects the CpID (which of up to 7 coprocessors, matching the F-line operation word's own bits[11:9] — confirmed against MC68030UM.pdf Figure 10-3/10-1 during Phase 157's own research, correcting an earlier "A[15:13] = primitive type" description here); A[4:0] selects a specific Coprocessor Interface Register (CIR) within that coprocessor's own register block (Figure 10-5: Response/Control/Save/Restore/Operation-Word/Command/Condition/Operand/Register-Select/Instruction-Address/Operand-Address). The response primitive code itself is a *data value* read back from the Response CIR (offset 0x00), not encoded in the address at all.
- CAS2 dual-address atomic lock (most complex: 4 bus cycles without releasing the bus)
- MOVEP byte-interleaved (individual byte cycles, address increments by 2)

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
cycle (ECS+addr, AS+DBEN, data placed, DS asserted, negate). AS stays
continuously asserted across the whole indivisible read+write sequence
(Figure 7-30), never negating between the two phases.

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
in the process finding and fixing two real pin-continuity bugs (burst's
DS# and CAS2's AS# were both dropping between beats/sub-cycles instead
of staying held, contradicting the manual's own explicit "maintains
AS, DS... throughout" text). The only remaining, confirmed-unavoidable
gap to real silicon's absolute clock count is a small, structural
per-cycle dispatch floor (the `ST_IDLE`-to-`S0` hand-off) and burst's own
already-manual-derived internal state count — both investigated and
found genuinely load-bearing, not implementation overhead.

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
- `0010` — Coprocessor communication (FPU: A[15:13]=primitive type)

## Exception Stack Frame Formats

The EU + BIU together must produce all 9 68030 frame formats:

| Format | Size | Trigger |
|--------|------|---------|
| $0 | 4 words | Most exceptions |
| $2 | 6 words | TRAPV, CHK, CHK2 |
| $3 | 8 words | Address error |
| $4 | 8 words | FPU post-instruction |
| $8 | 29 words | FPU pre-instruction |
| $9 | 12 words | MMU short bus fault |
| $A | 16 words | Bus error during instruction |
| $B | 46 words | Bus error during data cycle |

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
§Phase 232` for the full writeup. Stage 7 (CAS's own genuine bus-level lock) is next
— also flagged high-risk, RTL surgery on `biu_cycle_gen.sv`'s shared per-state AS pin
logic used by every bus access in the project.

**Current state**: `make test` 37/37, `make cosim_grp` 8/8, `make cosim_memind` 14/14,
`make dat-synth` 50/50. Full 124-suite Tom Harte sweep: `PASS 702142 FAIL 2 [documented
ASL.b corpus anomaly] SKIP 281221 TIMEOUT 0`, unchanged since Phase 112 (only the SKIP/PASS
split has shifted slightly across later phases as harness gaps closed). **In progress:
10-item backlog plan (`~/.claude/plans/elegant-gliding-fog.md`), Stages 1-6 of 10 done
(Phase 227-232); Stage 7 (CAS's own genuine bus-level lock) is next.**

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

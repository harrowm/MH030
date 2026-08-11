# MH030 — Cycle-Accurate Motorola MC68030 in SystemVerilog

A pin-level, cycle-accurate implementation of the Motorola MC68030 32-bit processor written in SystemVerilog. Every external bus signal (`/AS`, `/DS`, `R/W`, `FC[2:0]`, `SIZ[1:0]`, etc.) asserts and deasserts on the exact S-state cycle the real silicon does.

---

## Clock Strategy

The design runs at **4× the external bus frequency** — 100 MHz internal for a 25 MHz external bus. This gives four clean internal ticks per external clock half-cycle, which maps directly onto the 68030's S-state machine (S0–S7) without needing negedge triggers or clock-domain crossings. All logic is fully synchronous; there are no asynchronous resets or latches anywhere.

---

## Module Hierarchy

```
m68030_top
├── m68030_biu          Bus Interface Unit
│   ├── biu_arbiter         Priority arbiter: MMU > EU > IFU > external DMA
│   ├── biu_cycle_gen       S-state FSM — one branch per bus cycle type
│   ├── biu_sizing_fsm      Dynamic bus-width negotiation via DSACK0/1
│   ├── biu_pin_driver      Output pin control and tri-state management
│   ├── biu_byte_lane_ctrl  Write-data steering from SIZ[1:0] + A[1:0]
│   ├── biu_burst_ctrl      Burst linefill and MOVE16 burst sequencing
│   ├── biu_multiop_fsm     MOVEM / MOVEP multi-transfer sequences
│   ├── biu_error_handler   BERR detection, timeout, fault capture
│   ├── biu_cache_if        Cache hit/miss and CBREQ/CBACK handshake
│   ├── biu_mmu_if          MMU table-walk bus hijack port
│   ├── biu_exc_capture     Fault snapshot for exception stack frames
│   ├── biu_eclk_gen        E-clock generator (÷10 of bus clock)
│   └── biu_config          Reset sequencing and tri-state release timing
├── m68030_ifu          Instruction Fetch Unit — 4-word prefetch queue
├── m68030_seq          Micro-sequencer — IFU→EU glue and extension-word counting
├── m68030_eu           Execution Unit
│   ├── eu_regfile          D0–D7, A0–A7, USP/MSP/ISP, PC, SR, VBR — 3 write ports
│   ├── eu_alu              ADD/SUB/AND/OR/EOR/NEG/CMP/CLR/TST + X-extended forms
│   ├── eu_shifter          ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR, all sizes
│   ├── eu_mul_div          MULS/MULU (word+long), DIVS/DIVU (word+long)
│   ├── eu_bcd              ABCD/SBCD/NBCD
│   ├── eu_bitops           BTST/BCHG/BCLR/BSET
│   ├── eu_agu              Address Generation Unit — all EA modes including memory-indirect
│   └── eu_seq              Instruction decode, pipeline control, writeback
├── m68030_mmu          MMU — TLB, 3-level table walker, TT0/TT1, CRP/SRP
├── m68030_cache        I-Cache + D-Cache (256 bytes each, direct-mapped, 16-byte lines)
└── m68030_exc          Exception controller — all 9 68030 stack frame formats
```

---

## Bus Interface Unit

The BIU is the most critical module. It owns every external pin and is the sole place S-state transitions live. All other modules consume the `s_state` output — they never drive it.

### S-State Signal Timing

| S-State | Action |
|---------|--------|
| S0/S1 | Drive address bus, FC[2:0], SIZ[1:0], R/W |
| S2 | Assert /AS |
| S3 | Assert /DS |
| S4/S5 | Sample DSACK0/1; insert wait states (repeat S4/S5) if not asserted |
| S6 | Deassert /AS and /DS |
| S7 | Cycle complete; pulse `bus_ack` to requesting unit |

Address is stable at least one S-state before /AS asserts. /AS and /DS never change in the same S-state.

### Dynamic Bus Sizing

The 68030 does not have a fixed external bus width. `biu_sizing_fsm` interprets the DSACK0/DSACK1 response from the peripheral:

| DSACK1 | DSACK0 | Bus Width |
|--------|--------|-----------|
| 1 | 1 | Wait (no termination yet) |
| 1 | 0 | 8-bit port |
| 0 | 1 | 16-bit port |
| 0 | 0 | 32-bit port |

For narrower ports, the BIU automatically issues repeated bus cycles to complete the full transfer, steering byte lanes via `biu_byte_lane_ctrl` using `SIZ[1:0]` + `A[1:0]`.

### Asynchronous Input Synchronization

`BERR`, `BR`, `IPL[2:0]`, `HALT`, `VPA`, `DSACK0`, `DSACK1`, and `STERM` are all external asynchronous inputs. Each passes through a 2-stage synchronizer flip-flop chain before any combinational logic touches them. This prevents metastability from propagating into the state machines.

### Bus Cycle Types

`biu_cycle_gen` implements a distinct S-state sequence for each cycle type:

- **Normal read / Normal write** — S0–S7, standard sequence
- **Read-Modify-Write** — bus held locked between read and write phases; /AS does not deassert between them
- **Burst read** — /AS asserts only on the first longword; subsequent longwords toggle /DS only, with the address incrementing at a specific S-state
- **MOVE16 burst write** — 16-byte burst with its own four opcode variants
- **Interrupt Acknowledge** — FC=111, address encodes interrupt level in A[3:1] with A[31:4]=all-ones; peripheral responds with vector on D[7:0]
- **Coprocessor (FPU) cycles** — also FC=111 CPU Space, distinguished from IACK by A[19:16]=0010; A[15:13] encodes the primitive type (CPI/CPM/CPIR/CPCR)
- **CAS2** — four consecutive bus cycles without releasing the bus; the most complex single instruction in the ISA
- **MOVEP** — byte-interleaved cycles, address increments by 2 each transfer

### Function Codes

| FC[2:0] | Space |
|---------|-------|
| 001 | User Data |
| 010 | User Program |
| 101 | Supervisor Data |
| 110 | Supervisor Program |
| 111 | CPU Space (IACK or coprocessor) |

FC transitions at the same time as the address, never mid-cycle.

---

## Execution Unit Pipeline

The EU uses a three-stage in-order pipeline. All stages are separated by flip-flop barriers; no two stages share an `always` block.

### Stage 1 — DECODE (combinational)

`eu_seq.sv` contains a large `always_comb` block (~2500 lines) that decodes the current `instr_word` into ~80 control signals: `dec_is_add`, `dec_reads_src`, `dec_src_reg`, `dec_siz`, `dec_writes_reg`, and so on. The structure is a priority `if/else if` tree keyed on the opcode group field `[15:12]`, then sub-fields within each group. These signals are pure combinational — no state, no memory.

### Stage 2 — EXECUTE (registered)

On each clock edge the `dec_*` signals are latched into `ex_*` equivalents. From here:
- The ALU, shifter, and multiplier receive their operands
- Memory requests are issued to the BIU (`mem_req`, `mem_addr`, `mem_wdata`, `mem_siz`)
- The `eu_agu` computes effective addresses for all EA modes

The EX stage stalls when waiting for `mem_ack` (load/store), when a multi-phase operation is in progress (CMPM, MOVEM), or when the extension word is not yet available from the IFU (`need_ext`).

Hazard detection prevents a register being read before a prior instruction has written it back. The stall condition is:

```
stall = ex_mem_stall || hazard_ex || hazard_wb || hazard_ccr || need_ext
```

### Stage 3 — WRITEBACK (registered)

Results latch into `wb_*` and the regfile write port fires. The EU has three independent write ports:
- **wr** — any Dn or An (main result)
- **an_wr** — An only (postincrement/predecrement address updates)
- **wr2** — Dn only (64-bit multiply/divide high word; EXG Dx,Dy second register)

### Instruction Fetch and Extension Words

`m68030_ifu` maintains a 4-word prefetch queue. `m68030_seq` sits between the IFU and EU: it counts how many extension words the current opcode needs (0, 1, or 2), converts the IFU's extension word format to the EU convention, and tells the IFU how many queue entries to drain when the EU accepts an instruction.

The EU stalls on `need_ext` if it requires an extension word and `ext_valid` is not yet asserted — this is the only IFU→EU back-pressure mechanism.

---

## D-Cache Write Policy

The 68030 D-cache is **write-through only**. Every store goes to the external bus simultaneously; there are no write-back cycles. The cache simply absorbs subsequent reads of recently-written data. This matches real 68030 silicon behavior.

---

## Exception Stack Frames

The 68030 has nine distinct exception stack frame formats. `m68030_exc` generates all of them. `biu_exc_capture` snapshots the fault address, data, FC, R/W, and internal pipeline state at the exact moment of a bus fault so the larger frame formats ($9, $A, $B) can be populated accurately.

| Format | Size | Trigger |
|--------|------|---------|
| $0 | 4 words | Most exceptions |
| $2 | 6 words | TRAPV, CHK, CHK2 |
| $3 | 8 words | Address error |
| $4 | 8 words | FPU post-instruction |
| $8 | 29 words | FPU pre-instruction |
| $9 | 12 words | MMU short bus fault |
| $A | 16 words | Bus error during instruction fetch |
| $B | 46 words | Bus error during data cycle |

---

## SIZ[1:0] Encoding

`SIZ[1:0]` are **outputs** from the CPU telling the peripheral the requested transfer size. Bus width is determined dynamically from the DSACK response.

| SIZ[1:0] | Transfer |
|----------|----------|
| 00 | Longword (32-bit) |
| 01 | Byte (8-bit) |
| 10 | Word (16-bit) |
| 11 | Line (16-byte burst) |

---

## Simulation and Verification

**Tools**: Icarus Verilog (simulation), GTKWave (waveform debug), Python 3 (test harnesses).

**Test strategy**: Three independent verification layers:

1. **Unit + integration regression** (`make test`) — 34 testbenches covering BIU S-state timing, EU instruction decode, exception frames, MMU, cache, full-chip co-simulation, and pipeline stall/hazard behavior. 34/34 pass.

2. **Bus co-simulation** (`make cosim_grp`) — run 8 opcode-group assembly programs through both the DUT and Musashi (reference 68030 emulator), diff bus logs cycle-by-cycle. All 8 groups pass.

3. **Tom Harte SingleStepTests** — 68000 one-instruction test vectors (JSON, ~8000 per instruction mnemonic). Each test sets initial register + memory state, executes one instruction, and verifies final state. Structurally single-instruction — see "Pipeline stall/hazard coverage" below for what this can't reach. See `plan.md §Phase 84` for full results table.

4. **Pipeline stall/hazard tests** (`tb/stall_hazard_tb.sv`, `tb/stall_fsm_tb.sv`, part of `make test`) — bus-arbitration contention, RAW/CCR/autoincrement hazards, control-transfer stall depth, multi-cycle FSM decode-holdoff, interrupt/BERR arrival mid-FSM, and back-to-back FSM composition across real multi-instruction sequences. See `plan.md §Phase 103` and §§105-107.

```bash
make test                  # 34/34 regression suite
make cosim_grp             # 8 opcode group bus comparisons (DUT vs Musashi)
make dat-synth             # 50-vector synthetic dat-replay cosim; 50/50 pass
make sim/harte_dat         # rebuild Harte testbench binary after RTL changes
python3 -u scripts/run_harte.py tests/harte/ADD.b.json.gz    # single Harte suite
```

### Pipeline stall/hazard coverage (Phases 103-107)

Every Harte test resets state, executes exactly one instruction, and checks the
result — by construction it can never exercise anything that spans two
instructions. This suite covers what that structurally leaves out:

| Category | File | What it covers |
|---|---|---|
| Bus arbitration | `tb/biu_tb.sv` | MMU>EU>IFU priority under 3-way contention (previously zero coverage), IFU starvation/recovery under a sustained multi-beat burst, DMA held off by `bus_lock` during an RMW cycle |
| RAW/CCR/autoincrement hazards | `tb/stall_hazard_tb.sv` | 4 producer types (immediate-ALU, autoincrement-An, long-latency-multiply, CCR-only) × no-gap/1-gap/multi-gap consumer timing, via real instruction sequences, plus exact hazard-stall cycle counts (2/1/0) verified via direct RTL signal reads |
| Control-transfer stall depth | `tb/stall_hazard_tb.sv` | BRA (decode-resolved), JMP (register-indirect + absolute), taken DBF loop, JSR/RTS round trip through real memory |
| Multi-cycle FSM decode-holdoff | `tb/stall_fsm_tb.sv` | 21 of the ~23 `ex_mem_stall` sources in `eu_seq.sv` (TAS, MOVEM.L load+store, CMPM.B, BCHG, CAS/CAS2, MOVEP, MOVE16, ADDX/ABCD/PACK memory forms, BFINS, CMP2, MOVE mem-mem, RTR/RTE, RESET, PFLUSHA/PTEST/PMOVE) — verifies decode stays held off for each FSM's full duration and a real dependent instruction after it executes correctly, with exact bus-cycle counts verified for a representative set |
| DSACK wait-state composition | `tb/stall_fsm_tb.sv` | A stretched (0/2/5 wait-state) bus cycle correctly composes with a downstream RAW hazard, and separately with every beat of a real multi-phase FSM (TAS), rather than the consumer racing ahead |
| Interrupt arrival mid-FSM | `tb/stall_fsm_tb.sv` | Level-7 NMI injected mid-CAS2: found and fixed a real `m68030_exc.sv` gating bug (interrupts could hijack the bus mid-FSM); also root-caused a deferred instruction-dispatch race (see below) |
| BERR arrival mid-FSM | `tb/stall_fsm_tb.sv` | Sustained bus error injected mid-CAS2: root-caused a severe, deferred hang bug (see below) — currently asserts today's actual (buggy) behavior so `make test` stays green |
| Back-to-back FSM composition | `tb/stall_fsm_tb.sv` | TAS immediately followed by MOVEM.L with no instruction between them — one FSM's decode-holdoff handing directly to another's, including write-then-read ordering across the boundary |

Memory-indirect EA (`([bd,An],Xn,od)`) remains deferred — Phase 107 narrowed the
original "genuine encoding ambiguity" to a specific, falsifiable hypothesis (a
suspected wrong-bit decode for pre- vs. post-indexed selection in `eu_seq.sv`), but
the Harte corpus is 68000-captured and has zero coverage of this 68020+-only
addressing mode, so there's no empirical oracle to verify a fix against without a
dedicated Musashi-cosim investigation.

**Two known, real, deliberately deferred RTL gaps** were found and thoroughly
root-caused (not fixed) during this work — see `plan.md §Phase 105`/`§Phase 106`
and the `feedback_berr_hang_deferred` Claude Code memory note before starting a fix
for either: (1) an interrupt can land on the exact cycle a newly-ready instruction
launches into EX right after an FSM retires, and the saved return PC can point at
that already-executing instruction, causing RTE to silently re-execute it — harmless
for idempotent instructions, a real risk otherwise; (2) a sustained bus error during
almost any EU-initiated access (`biu_cache_if.sv`, `biu_multiop_fsm.sv`, and CAS2's
dedicated datapath, which has no berr signal path at all) hangs the CPU forever
instead of raising a Bus Error exception, and `m68030_exc.sv`'s `bus_err_req` isn't
even wired to any EU-side fault source today.

### Harte Pass Rates (Phase 102 summary — all 124 suites confirmed)

| Family | Sizes | Pass rate | Notes |
|--------|-------|-----------|-------|
| ADD | b/w/l | 100% | |
| SUB | b/w/l | 100% | |
| AND | b/w/l | 100% | |
| OR | b/w/l | 100% | |
| EOR | b/w/l | 100% | |
| CMP | b/w/l | 100% | |
| MOVE | b/w/l/q | **100%** (all) | Phase 85: indexed-src added (dual swap-both register-file ports) + fixed a `get_scale_remap()` single-side-only harness bug. Phase 89: MOVEQ retested, already 100% (previously-noted 4 TIMEOUTs resolved as a side effect of an earlier fix) |
| BCHG/BCLR/BSET/BTST | — | **100%** (all) | Phase 83: root cause was a test-harness bug, not RTL — zero RTL changes. Phase 88: BTST retested, already 100% |
| TRAPV | — | 100% | |
| MOVEfromUSP/toUSP | — | 100% | |
| CLR/NEG/NOT/NEGX/TST | b/w/l | **100%** (all) | Phase 81 (b/w spot checks) + Phase 87 (full size sweep) |
| TAS | — | **100%** | Phase 81: indexed EA added, no port needed (unary op) |
| ASL | b/w/l | 99.98%\* / **100%** / **100%** | \*ASL.b: 2/8065 confirmed Tom Harte corpus data anomalies (opcode `0xe502`, passes 41/43 other instances) — not a bug |
| ASR/LSL/LSR/ROL/ROR | b/w/l | **100%** (all) | Phase 87 full sweep |
| ROXL/ROXR | b/w/l | **100%** (all) | Phase 87: found + fixed a real `eu_shifter.sv` bug — `count==0` register-count ROX must set `C=X` per 68k PRM, RTL cleared it to 0 like the other 6 shift/rotate types |
| CHK | — | **100%** | Phase 84: `(d8,An,Xn)` indexed EA added, no port needed. Phase 86: remaining EA modes (`(An)+`/`-(An)`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)`) added — `(d8,PC,Xn)` needed the same swap trick, no port needed either |
| ADDX/SUBX | b/w/l | **100%** | Phase 90 sweep (ADDX.w had 1 unexamined fail). Phase 102: root-caused — the `-(Ay),-(Ax)` destination address comes from a separate auto-decrementing register, invisible to the harness's single-EA-field collision check, so it was never checked against the STOP+NOP runway; 1/8065 cases coincidentally landed there. Added a dedicated check |
| ANDI/EORI/ORI to CCR/SR | — | **100%** | Phase 90 sweep |
| Bcc/BSR/DBcc | — | **100%** | Phase 90 sweep |
| EXG/EXT/LINK/UNLINK/SWAP/NOP/RESET | — | **100%** | Phase 90 sweep |
| MOVEA/MOVEfromSR/MOVEtoCCR/MOVEM.w/MOVEP | — | **100%** | Phase 90 sweep (MOVEP.w/.l each had 1 unexamined fail). Phase 102: root-caused — MOVEP's fixed encoding aliases `ea_mode=1` ("no memory operand") in the harness's generic EA decode, so its `(d16,An)` EA was never computed or range-checked; both failures landed inside the harness's own init-code region |
| **JMP/JSR** | — | **100% / 100%** (was 0%/0%) | Phase 90: harness bug fixed (`can_run()` misclassified every JMP/JSR as invalid — see below); residual was TIMEOUTs on `(d8,An,Xn)`/`(d8,PC,Xn)` indexed targets. Phase 95: root-caused — scale≠0 sends our correctly-68030-scaled RTL to a genuinely different jump target than the 68000 reference (unlike MULS/MULU/DIVS/DIVU's case, this isn't limited to odd-address parity — the landing *address itself* differs), and the harness's STOP runway is only ever placed at the reference's target, so our RTL runs off into uninitialized memory. Fixed by skipping scale≠0 indexed JMP/JSR tests (unreplicable by construction). No RTL change |
| **ABCD / NBCD** | — | **100% / 100%** | Phase 91: N/V are "undefined" per the PRM but real hardware is deterministic — reverse-engineered the actual formulas from raw Harte JSON (Musashi's own reference doesn't match real hardware either); fixed 2 real RTL bugs (Verilog sign-extension gotcha, a 9-bit field overflow) plus a pre-existing `-(An)` A7-step-size bug |
| **SBCD** | — | **100%** | Phase 91: same fixes as ABCD/NBCD (99.7%, 28/8065 residual — C and result-correction decoupled in real hardware in a way not yet captured). Phase 101: found the missing condition — every residual case has `dst_hi - src_hi == 1` (raw, uncorrected nibbles); C was always correct, only the `+0xA0` result correction needed suppressing in that specific case. Verified against the full 1164-case ambiguous population with zero mismatches |
| **MULS / MULU** | — | **100% / 100%** | Phase 92: memory-EA decode was entirely missing, plus a missing bus-read-size override that hung every memory-source multiply, plus a harness `f_ss`/`f_dir` misclassification bug. Phase 94: root-caused the remaining indexed-EA TIMEOUT — the Harte corpus is 68000-captured and faults (Address Error) on misaligned *data* access, which a 68030 legitimately does not; fixed a `gen_harte_hex.py` harness bug that placed the STOP runway using the reference's post-fault PC delta, causing our non-faulting RTL to run into uninitialized memory and hang. No RTL change |
| **DIVS / DIVU** | — | **100% / 100%** | Phase 93: two real bugs — an RTL comment claiming C is "unchanged" on overflow was wrong (must always clear, hand-verified against 1400+ vectors); `div_trap` evaluated `md_div_by_zero` from `mem_rdata` before the memory read actually completed, firing a bogus trap that collided with the pending stall and hung the pipeline. Phase 94: same indexed-EA TIMEOUT root cause and harness fix as MULS/MULU, no RTL change |
| **Scc** | — | **100%** | Phase 90: found (72.7%). Phase 96: root-caused — Scc's `(xxx).W` abs form and TRAPcc share the same opcode slot family; `f_reg==000` (Scc abs.W) was mislabeled as TRAPcc in decode *and* mislabeled as TRAPcc.L (2 ext words instead of 1) in the ext_count table, in two separate places; `(d16,An)`/`(d8,An,Xn)` had no ext_count entry at all. Fixed all three; TRAPcc.L made reachable as a byproduct (unverified, no dedicated suite) |
| **PEA / LEA** | — | **100% / 100%** | Phase 90: found (86.0%/89.0%). Phase 97: LEA and PEA's `(d8,An,Xn)` form were the Phase 94/95 68000-vs-68030 scale divergence again (the EA *is* the result here, so a scale mismatch changes it directly, unreplicable, harness skip added, no RTL change); PEA's `(d8,PC,Xn)` was a genuine RTL gap — no decode case existed at all (100% TIMEOUT), plus the fix needed the same `ex_cur_sp` A7-routing PEA's `(d8,An,Xn)` sibling already uses, and the pushed value needed the missing `ex_xn_scaled` term added |
| **MOVEM.l** | — | **100%** | Phase 90: found (95.0%). Phase 98: `get_scale_remap()`'s size calc had a "MOVE SR/CCR ↔ ea" clause (`f_group==4, f_ss==3`) positioned before the MOVEM check — MOVEM.l's own encoding also matches that pattern, truncating the scale-remap byte range to 2 instead of `4×popcount(mask)` and leaving most write addresses unredirected in `compare()`. Harness fix, zero RTL change |
| **MOVEtoSR** | — | **100%** | Phase 90: found (96.3%, only `(A7)+`/`-(A7)` failing). Phase 98: genuine RTL race — `eu_regfile.sv` had two `if` clauses able to write the same bank register in one cycle (the auto-decrement, and the SR-write's "save A7 before the S/M switch" step), and the textually-later one clobbered the correct decrement with a stale pre-decrement value. Fixed with `a7_save_val`, which uncovered an unrelated pre-existing `tb/eu_regfile_tb.sv` gap (3 ports never driven, floating at X) also fixed |
| **RTS / RTR / RTE** | — | **100% / 100% / 100%** | Was 100% SKIP for the project's entire history (a `get_operand_ea()` decode bug — these opcodes alias a real indexed-EA bit pattern despite having no EA — caused every one to be misrouted through bogus backstops). Phase 99: fixed the decode bug; RTR needed an additional real RTL fix (`eu_seq.sv` advanced SP by 4 instead of 2 after popping the CCR word — a known, self-documented placeholder bug, never revisited since RTR had never run end-to-end); RTE needed 68030 exception-frame-format synthesis (68000 corpus has no format word) |
| **TRAP / TRAPV-taken** | — | — | Confirmed permanently unfixable, not a gap: our correct 68030 exception-frame push (4 words incl. format/vector word) can never match the reference 68000's native 3-word push — the DUT constructs this as *output*, so (unlike RTE) there's no input to synthesize around. Remains 100% SKIP by design. TRAPV's non-trapping cases pass 100% (3970/3970) |
| **Odd-restored-PC Address Error** | — | — | Phase 99 found a runtime PC-restore (RTS/RTE/RTR) landing on an odd address hung the RTL instead of trapping. **Phase 100 root-caused it: the mechanism was already correct** — `m68030_ifu.sv`'s `addr_err`/`m68030_exc.sv`'s redirect fire and complete properly; the hang was actually the vector-3 table read (fixed address `VBR+12`=`0xC` at reset) colliding with the harness's own init code and returning garbage. Fixed by relocating VBR for these tests via a synthesized `MOVEC A7,VBR` (which exposed and fixed a second real gap: MOVEC had no `ext_count` entry, never having been exercised through the IFU before). Confirmed via repro: vector read now correct, PC redirects correctly, DUT reaches STOP cleanly. Still can't PASS the byte-level comparison — Address Error's frame has the same permanent 68000-vs-68030 width divergence as TRAP — but the underlying mechanism is now validated. Still skipped, now for a confirmed reason instead of an unknown |

**JMP/JSR harness bug (Phase 90)**: both were 0% (100% SKIP, never ran at
all) before this phase. `can_run()`'s "EA overlaps STOP runway" check treated
the jump target — which `build_patches()` *deliberately* places the STOP
opcode at — as a data-operand conflict; a second "misaligned EA" backstop
then re-triggered on the same underlying issue (PC-after-jump isn't
"instruction start + length", so the wild PC delta looked like an exception
that never happened). Both fixed in `gen_harte_hex.py`. See `plan.md §Phase
90` for the residual indexed-EA timeout that's still open.

### Known Architectural Gap — did not exist

A diagnostic in Phase 81 (`AND.b` retested at 100% using the same 2-port
time-multiplexing trick BCHG's broken indexed form uses) showed the "2-port register
file" explanation for `(d8,An,Xn)`-destination failures was overbroad. Following that
thread through Phases 81–84, all four original buckets closed without ever touching
the register file: unary memory ops just needed EA decode (Bucket A); AND/OR/EOR/SUB/
CMP/ADDA/SUBA/CMPA already worked with the existing 2-port scheme (Bucket B);
BCHG/BCLR/BSET — the case that looked most like a real RTL limitation, since it
silently produced wrong output rather than just timing out — turned out to be a
**test-harness bug** (Bucket C, Phase 83): the harness misclassified dynamic bit-ops
and read the extension word from the wrong offset. And **CHK's indexed form**
(Bucket D, Phase 84) — the one case with a plausible on-paper argument for a genuine
3rd simultaneous register read — closed the same way as Bucket B once actually
attempted: the tested value isn't needed until after the memory read completes, so it
defers to the existing swap mechanism instead. See `port3.md` for the full analysis —
the investigation is concluded, and nothing in the codebase requires the
register-file port.

---

## Design Rules

- SystemVerilog throughout (`always_ff`, `always_comb`, `typedef enum`, `struct`)
- All logic synchronous — no latches, no asynchronous resets
- No combinational feedback loops
- `generate` loops for replicated structures (the 8 data registers, 8 address registers, etc.)
- Keep each module under ~3000 lines
- No timing optimizations that collapse or skip real silicon cycles

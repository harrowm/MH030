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
- Coprocessor interface (FPU) — FC=111 (CPU Space) cycles with A[19:16] encoding the coprocessor type and A[15:13] encoding the primitive type (CPI/CPM/CPIR/CPCR); distinct from IACK by address pattern
- CAS2 dual-address atomic lock (most complex: 4 bus cycles without releasing the bus)
- MOVEP byte-interleaved (individual byte cycles, address increments by 2)

## S-State Signal Timing (Critical)

| S-State | Action |
|---------|--------|
| S0/S1   | Drive Address, FC, SIZ, RW |
| S2      | Assert AS |
| S3/S4   | Assert DS (except IACK — see below) |
| S4/S5   | Sample DSACK; if not asserted, loop S5/S6 (wait states) |
| S6      | Deassert AS and DS |
| S7      | Cycle complete; signal `bus_ack` |

Address must be stable at least one clock phase before AS asserts. AS and DS may not change in the same phase.

**IACK note**: DS asserts at S3 just like a normal read. The peripheral uses FC=111 + AS + DS to identify the cycle and drives the vector on D[7:0].

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

**Completed phases** (do not re-implement):

*BIU (Phases 1–22)*:
1. Reset hold, phase counter, E-clock
2. Power-on SSP/PC fetch, EU read/write S-state timing
3. Dynamic bus sizing via DSACK (16-bit and 8-bit ports)
4. STERM fast termination, BERR fault capture, BERR+HALT retry, IACK (DSACK + AVEC), RSTOUT
5. RMW atomic lock, CAS2 four-cycle atomic, MOVEM/MOVEP (biu_multiop_fsm), bus_lock
6. I+D cache (biu_cache_if), MMU ATC + table walker (biu_mmu_if)
7. Burst linefill read, MOVE16 burst write, biu_exc_capture (fault snapshot, frame format)
8. biu_byte_lane_ctrl (write-data steering), mem_model byte-selective writes

*EU and integration (Phases 23–76)*:
23–31. eu_regfile, eu_alu, eu_shifter, eu_mul_div, eu_bcd/bitops, eu_agu, m68030_eu, m68030_ifu, m68030_seq, m68030_exc, m68030_mmu
36–37. eu_seq non-memory instrs + branches; eu_seq memory EA (An)/(An)+/-(An)/(d16,An)
38–55. Full ISA: JMP/JSR/RTS, LINK/UNLK, absolute EA, indexed/PC-relative EA, MOVEM, exception frames, BERR watchdog, MOVEC/MOVES, TAS/CAS, CHK/CHK2/CMP2, MOVEP, MOVE16, biu_pin_driver, FPU coprocessor bus, memory-indirect EA, MMU instructions, m68030_top final wiring
56–71. RTE/STOP/TRAP/TRAPV, ADDA/SUBA/CMPA/ORI-ANDI-EORI-to-SR, MULS.L/MULU.L/DIVS.L/DIVU.L, PEA/EXG/RTD/CMPM, memory-dest ALU, ADDX/SUBX, bit-field ops, PACK/UNPK/LINK.L/RESET, MOVES/PMOVE 64-bit, ALU mem→reg, extended EA sweep, trace/priv/Line-A/Line-F, CAS2/Format-Error
72–76. cosim72_tb (full-chip testbench), smoke.s bare-metal test, Musashi reference generator, buscmp.py diff tool, 8 opcode group tests (`tests/grp0.s`–`grp7.s`, `tb/cosim_grp_tb.sv`)
77. Toni Wilen `.dat` replay harness: `tb/cosim_dat_tb.sv` (runtime hex load, eu_stop detection), `scripts/gen_init_hex.py` (reg-state init scaffold with NOP bubble after MOVE.W #,SR), `scripts/parse_dat.py` (.dat binary parser, --probe mode), `scripts/run_cosim.py` (50-vector synthetic suite, 50/50 PASS). RTL fixes: eu_stop exposed as top-level port; ext_count=1 for MOVE.W #,SR/CCR by direct opcode match (was broken f_ss field condition).
78. Tom Harte SingleStepTests harness (`scripts/parse_harte.py`, `scripts/gen_harte_hex.py`, `scripts/run_harte.py`, `tb/harte_tb.sv`, `tests/harte/`). RTL fixes: ADD/SUB #imm,Dn handler in eu_seq.sv (groups 9/D); `is_alu_imm_dn` + `is_addq_subq_ext` f_mode=110 fix in m68030_seq.sv. Harness fixes: bad-instr-len guard; indexed EA scale from RAM for group-0; init-region data conflict filter; misaligned longword testbench read/write. Scale-remap: tests with non-zero scale run via `get_scale_remap()`. Results: ADD.b/w/l 100%.
79. Harte sweep — SUB/AND/OR/EOR/CMP/MOVE + bit-ops + shifts + misc. RTL fixes: (a) MOVE An,(dst) CCR bug: `dec_updates_ccr=(f_mode==3'b000)` suppressed Z/N/V/C update for An-source MOVE to memory; changed to `1'b1` in both indirect-dst and abs-dst blocks → MOVE.w/l 82.3%→94%/93.6%; (b) BCHG/BCLR/BSET CCR Z-flag bug: explicit `dec_updates_ccr=1'b0` overrode block-level `1'b1` for memory RMW bit-ops, and #imm forms lacked it entirely; fixed both locations (**this fix was itself buggy — see Phase 80**). See `plan.md` for full Harte results table.
80. Phase 79 regression fix + CHK CCR fix + EA-mode extension. RTL fixes: (a) Phase 79's BCHG/BCLR/BSET fix double-fired CCR (once correctly via `mem_rmw_sr_wr_en`, once incorrectly one cycle later via WB using stale `mem_rdata`) — reverted `dec_updates_ccr` back to 0 for the memory-RMW CHG/CLR/SET cases → BCHG 58.1%→92.8%, BCLR→93.4%, BSET→98.2%; (b) CHK Z/N flags backwards from Musashi semantics: Z must be `(value==0)` unconditionally (RTL never updated it), N must be `(value<0)` only when CHK actually traps and left unchanged otherwise (RTL forced it every time); also fixed missing sign-extension on the CHK.W bound comparison → CHK 17.8%→64.3% with zero logic mismatches remaining; (c) TAS/NEGX/CLR/NEG/NOT/TST memory-EA decode only covered `(An)/(An)+/-(An)`; added `(d16,An)`/abs.W/abs.L (+`(d16,PC)` for TST) in eu_seq.sv with matching `ext_count` entries in m68030_seq.sv → TAS 69.4%→87.2%, CLR.b 64.1%→83.8%, NEG.w→89.3%, TST.b→83.6%. See `plan.md §Phase 80` for full writeup.
81. "3rd port" investigation (`port3.md`). Diagnostic found the "(d8,An,Xn) indexed-dst arch gap" label was overbroad: re-ran AND.b (uses the identical 2-port `dyn_bit_get_Dn` time-multiplex trick BCHG's broken indexed form uses) → 100% pass, proving the 2-port scheme works fine for at least that shape of instruction. `port3.md` splits the gap into buckets; this phase closed two of them, no port added:
    - **Bucket A** (Phase 0): CLR/NEG/NOT/NEGX/TST/TAS/memory-word-shift are unary memory ops needing only `An`+`Xn` (2 ports, like LEA/PEA indexed already does) — added `(d8,An,Xn)` decode (+ `(d16,An)`/abs.W/abs.L for shifts, which had no extended-EA support at all) to the 3 shared eu_seq.sv blocks, with matching `ext_count` entries in m68030_seq.sv. Results: CLR.b/NEG.w/NOT.b/TST.b/TAS/ASL.w all → **100%**, zero remaining fails of any kind.
    - **Bucket B** (Phase 0.5, diagnostic only): swept OR/EOR/SUB/CMP.b + ADDA/SUBA/CMPA.w — all **100%**, confirming the `dyn_bit_get_Dn` mechanism is solid whenever the swapped-in register is only needed after the EA/bus phase, never simultaneously with `Xn`.
    - **MOVE reclassified** (Phase 0.5, diagnostic only): MOVE.b's 545 failures are 100% TIMEOUT, zero involve the register-source form — turns out unrelated to Bucket C. `eu_seq.sv`'s indexed-dst MOVE block only decodes 4 of 10 source addressing modes (Dn/An, abs.W, abs.L, `(d16,PC)`, `#imm`); missing `(An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(d8,PC,Xn)` matches the failure list exactly. Looks like ordinary missing-decode work (same shape as Phase 81/Bucket A), not proven to need a port. Not implemented yet.
    See `plan.md §Phase 81` and `port3.md` for full writeups. Remaining open items: Bucket C (BCHG/BCLR/BSET indexed — confirmed broken, root cause not yet found, Phase 0.75 pending); Bucket D (CHK indexed — the one case confirmed to need the 3rd port); the MOVE source-EA gap (fixed next, see Phase 82).
82. MOVE indexed-dst source EA fix (`port3.md`'s Phase X — no port needed). Added `(An)/(An)+/-(An)/(d16,An)` source decode for MOVE→indexed-dst (`(d8,An,Xn)` and `(d8,PC,Xn)` src remain deferred — need separate src/dst Xn scale fields, genuinely harder). New mechanism: `dec_dyn_bit_swap_a`/`ex_dyn_bit_swap_a` — mirrors the existing `dyn_bit_get_Dn` swap but retargets `rd_a` instead of `rd_b` (default 0, zero effect on any existing use). Found and fixed two real bugs along the way: (a) `dyn_bit_get_Dn`'s move_mm branch was missing the `!move_mm_after_r` guard the RMW branch already has (added defensively, not the actual root cause); (b) the actual cause — neither the RTL nor the Python Harte harness's `get_scale_remap()` applied the 68k rule that a source register's own auto-increment/decrement happens *before* the destination EA is evaluated when that register is also referenced by the destination (as its base OR its index register). The DUT's computed address was correct the whole time; the *test's own expected value* was wrong. Fixed in both `eu_seq.sv` (compensate `dec_dst_ea_offset` by the src delta, scaled by `1<<xn_scale` when it's the index-register match) and `scripts/gen_harte_hex.py`. Results: MOVE.b 90.8%→97.9%, MOVE.w 94.0%→98.7%, MOVE.l 93.6%→99.0%, every remaining failure is TIMEOUT and matches the deferred indexed-src count exactly. See `plan.md §Phase 82`.

83. Bucket C resolved (`port3.md` Phase 0.75) — root-caused BCHG/BCLR/BSET's indexed-dst failure. **Not an RTL bug at all.** A test-harness bug in `scripts/gen_harte_hex.py`: `get_scale_remap()`/`build_patches()`/`get_operand_ea()` all misclassify dynamic bit-ops (`BTST/BCHG/BCLR/BSET Dn,ea`, `f_dir=1`) as group-0 immediate ALU ops (`ADDI`/`ANDI`/etc, always `f_dir=0`) because their shared classification never checks `f_dir` — only `f_dn`, which for dynamic bit-ops is the bit-count register (0-7), not a fixed marker. Misclassified, the harness read the EA extension word from the wrong offset, which left a "full extension word" bit unmasked (a mode the harness deliberately avoids elsewhere) and failed to apply the scale-remap, so the DUT was reading uninitialized memory at an address the test's own "expected" data never accounted for. Added the missing `f_dir` check to all three functions, plus a related fix for the static `#n` form's own extra extension word. **Zero RTL changes.** Results: BCHG 92.8%→**100%**, BCLR 93.4%→**100%**, BSET 98.2%→**100%**, all zero fails. This is the third "arch gap" diagnosis in a row (after Bucket A and MOVE) to turn out to be missing decode or a test-harness bug rather than a port-count limitation — see `plan.md §Phase 83`.

84. Bucket D resolved (`port3.md` §2 step 5) — **the `port3.md` "3rd register-file port" investigation is concluded.** Added CHK's indexed form (`CHK (d8,An,Xn),Dn`) using the existing `dyn_bit_get_Dn` deferred-register pattern (`Dn`, the tested value, is only needed after the memory read completes — same shape as Bucket B, not a true 3-simultaneous-operand case). Worked exactly as predicted: zero remaining failures on the indexed form, no new capture-register plumbing needed (CHK's WB fires the same cycle as the read ack, unlike BCHG/MOVE). Also found and fixed a **second, unrelated** test-harness bug along the way: `gen_harte_hex.py`'s `is_movem` classification heuristic (`f_group==4 and f_dn in (4,6) and f_ss>=2`) collides with CHK whenever the *tested register* happens to be D4 or D6 at word size, since MOVEM's `f_dn∈{4,6}` is a fixed direction marker while CHK's `f_dn` is the (arbitrary 0-7) tested-register selector — same missing `f_dir` disambiguator pattern as Phase 83's bug, fixed the same way in all three functions that share it. Diagnosed via the same hand-verification + targeted `$display`-tracing technique that found the Phase 82/83 bugs (traced X-propagation from a corrupted `mem_rdata` back to the harness never populating the DUT's correctly-computed read address). CHK 64.3%→**70.3%** (419/652→468/666), zero remaining failures for `(d8,An,Xn)` specifically — the residual gap is entirely other, unrelated, never-attempted EA modes (`(An)+`/`-(An)`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)`). **All four original "arch gap" buckets (A/B/C/D) are now closed. None of them ever needed the register-file port.** See `plan.md §Phase 84` and `port3.md` (status: concluded) for the full write-up.

85. MOVE indexed-source `(d8,An,Xn)`/`(d8,PC,Xn)` (with indexed dst) added — extended `dyn_bit_get_Dn` to swap both register-file read ports at once (`dec_dyn_bit_swap_both`) so indexed-src+indexed-dst MOVE's 4 logical operands resolve through the existing 2 physical ports, same deferred-register shape as every prior case. Found a fourth harness bug, but a new structural class (not the recurring `f_dir` pattern): `get_scale_remap()` could only ever compute a remap for one side of an instruction (derived from the opcode's own low-6-bit field, always the source for MOVE), so it silently missed the destination's independent scale whenever the source was *also* indexed. Refactored to return a list of 0-2 remaps (source-side, destination-side, both, or neither) computed independently; updated all 4 call sites. Results: MOVE.b 99.2%→**100%** (5922/5922), MOVE.w→**100%** (3235/3235), MOVE.l→**100%** (3148/3148), zero remaining failures of any kind. See `plan.md §Phase 85`.

86. CHK's remaining EA modes (`(An)+`/`-(An)`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)`) added, closing the gap left after Phase 84. `(An)+`/`-(An)` reuse the existing `setup_mem_incdec()` task; `(xxx).L`/`(d16,PC)` are plain absolute/PC-relative EAs with no register-port conflict. `(d8,PC,Xn)` needed the same `dyn_bit_get_Dn` deferred-swap trick as `(d8,An,Xn)` (Phase 84) — the EX-stage EA datapath hardwires the scaled index register to `rd_b` regardless of whether the base is register-relative or PC-relative, so `Xn` (read phase) and `Dn` (post-read comparison) still collide on `rd_b`; verified the swap-at-ack condition doesn't care which one supplies the base, so the existing mechanism worked unmodified with `dec_abs_ea_en` substituted for `dec_src_reg`. `m68030_seq.sv`: added `ext_count=2` for `(xxx).L`, added `(d16,PC)`/`(d8,PC,Xn)` to the existing `ext_count=1` entry. No harness bugs this time — reasoned through the register-port collision up front. CHK 70.3%→**100%** (666/666), zero remaining failures. See `plan.md §Phase 86`.

87. Swept the previously-untested NEGX/NOT/CLR/NEG/TST sizes plus the full shift/rotate family (ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR × b/w/l, 24 suites, first time run). All came back 100% except: (a) ASL.b 8063/8065 — hand-verified both failures share opcode `0xe502` (which passes 41/43 other times with different data) and the claimed expected value doesn't match the initial value's upper bytes for a byte-size op under any size/count/type — a **Tom Harte test-corpus data anomaly**, nothing to fix; (b) **ROXL/ROXR all 6 suites ~99.6-99.7%** (118 failures), a real RTL bug: `eu_shifter.sv`'s `count==0` default path unconditionally set `c_out=1'b0`, correct for ASL/ASR/LSL/LSR/ROL/ROR but wrong for ROXL/ROXR, which per the 68k PRM must set `C=X` (not clear it) when the register-supplied rotate count is zero — the op-specific `case` statement that has the correct `c_out=roxl_c_bit`/`roxr_c_bit` assignment is skipped entirely when `count==0`, so that exception never fired. Fixed with a one-line conditional in the default. Also fixed `eu_shifter_tb.sv`'s `F5a` unit test, which had encoded the old wrong behavior as its expected value. Results: ROXL.b/w/l and ROXR.b/w/l all 70.3%→**100%**. First RTL bug this session not related to indexed EA/register-port mechanics — a plain zero-count CCR edge case, unexercised until this sweep ran register-count ROX at scale. See `plan.md §Phase 87`.

88. BTST retest — re-verified `BTST.json.gz` after Phases 79-83's fixes to the shared dynamic-bit-op decode path (BCHG/BCLR/BSET). Already **100%** (8064/8064), zero failures, no RTL or harness changes needed. See `plan.md §Phase 88`.

89. MOVEQ 4-TIMEOUT investigation — re-verified `MOVE.q.json.gz`. Already **100%** (6089/6089), 0 TIMEOUT, 0 FAIL. Whatever caused the previously-noted 4 TIMEOUTs was resolved as a side effect of an earlier `ext_count`/IFU-desync fix; no RTL or harness changes needed this phase. See `plan.md §Phase 89`.

90. Swept all 44 previously-never-tested Harte suites (ABCD/ADDX/ANDItoCCR-SR/Bcc/BSR/DBcc/DIVS/DIVU/EORItoCCR-SR/EXG/EXT/JMP/JSR/LEA/LINK/MOVEA/MOVEfromSR/MOVEM/MOVEP/MOVEtoCCR-SR/MULS/MULU/NBCD/NOP/ORItoCCR-SR/PEA/RESET/SBCD/Scc/SUBX/SWAP/UNLINK). Most are 100% or a single stray fail, but this uncovered by far the largest cluster of unresolved gaps to date, none yet root-caused except JMP/JSR (below): **NBCD 6.9%**, **SBCD 33.1%**, **ABCD 51.0%**, **DIVS 15.7%**, **DIVU 18.2%**, **MULS 24.5%**, **MULU 25.1%**, **Scc 72.7%**, **PEA 86.0%**, **LEA 89.0%**, **MOVEM.l 95.0%**, **MOVEtoSR 96.3%**. Each needs its own root-cause phase.
    - **JMP/JSR**: were **100% SKIP** (0/8065 tests ever ran) — a two-part `gen_harte_hex.py` harness bug, both stemming from `instr_len = final_pc - ini_pc` being computed as if every instruction were straight-line, which is false for control transfers (PC-after ≠ instr_start+length, it's the jump target). (a) The "EA overlaps STOP runway" check flagged every JMP/JSR test as conflicting with a runway that's *deliberately* placed at the jump target (by design, so execution halts the instant it lands) — fixed by exempting JMP/JSR (`f_group==4,!f_dir,f_dn==7,f_ss∈{2,3}`) since there's no real data there to protect. (b) A later "misaligned EA" backstop (`1<=instr_len<=24`) assumes a wild PC delta means the reference hit an exception; for JMP/JSR a "wild" delta is normal (it's the jump target), so it re-fired the moment (a) let tests through — fixed by gating the backstop on `get_operand_ea()` having returned `None` (its only intended scope). Results: JMP/JSR 0%→**88.6%/89.1%**. Residual: every remaining failure is a TIMEOUT, 100% on the `(d8,An,Xn)`/`(d8,PC,Xn)` indexed target forms. Traced with temporary `$display`s and confirmed the RTL computes the correct 32-bit target (low 24 bits match expected) — the memory model already ignores address bits above 23, so that's not it — yet zero further bus activity occurs afterward at all, even at 10x cycle budget. Root cause not found; something in the IFU-redirect handshake (`pc_wr_en`/`fetch_pend_r`/`eu_instr_ack`/`drain`) stalls specifically when an indexed EA combines with a control-transfer instruction. Deprioritized in favor of surfacing the full sweep to the user; needs a dedicated follow-up. See `plan.md §Phase 90` for the full writeup and repro steps.

91. Root-caused ABCD/SBCD/NBCD (51.0%/33.1%/6.9% → 100%/99.7%/100%). N and V are "undefined" per the 68k PRM but real silicon produces specific deterministic values — the RTL never computed them at all (`ex_n=1'b0`/`ex_v=1'b0` hardcoded), and **Musashi's own reference implementation doesn't match real hardware either** (hand-verified: `ABCD D2,D4` src=0x3d dst=0x49 X=1 — Musashi predicts V=1, real hardware has V=0). Reverse-engineered the actual formulas empirically from raw Harte JSON (exhaustive bit-formula search against every register-direct vector, 4004/3948/1315 cases, until 0-mismatch): N = bit7 of final result; ABCD V = `N & ~bit7(uncorrected dst+src+X)`; SBCD/NBCD V = `~N & bit7(uncorrected dst-src-X)`; ABCD carry threshold is `>=0xA0` not Musashi's `>0x99`; SBCD/NBCD's corrections must be gated by true *signed* borrows, not Musashi's raw-digit-magnitude checks — both diverge from real hardware on invalid BCD digit (>9) inputs, which Tom Harte deliberately exercises (Musashi gets the *result byte* wrong here too, not just flags). Found 2 real RTL bugs along the way: a Verilog `{4'b0, negative_signed_value}` concatenation-instead-of-sign-extension bug (own mistake, symptom: every result off by exactly 0x40) and a pre-existing 9-bit field overflow in `add_adj1` (`add_bin+6` can reach 0x205, doesn't fit in 9 bits — found via `ABCD D0,D7` with D0=0xff,D7=0xfb). Also found and fixed a genuine pre-existing memory-form bug unrelated to any of this: `-(Ay),-(Ax)` predecrement always stepped by 1, missing the standard-in-this-codebase A7-byte-op-steps-by-2 rule, plus a same-register-conflict case (`-(A1),-(A1)`) needing the same Phase-82-style compounding fix. Added NBCD's missing `(d16,An)`/`(d8,An,Xn)`/`(xxx).L` EA decode. Results: ABCD **100%**, SBCD **99.7%** (28/8065 residual — a genuine algorithmic subtlety where the C flag and result-correction decisions are decoupled in real hardware in a way the current single-condition model doesn't capture; documented, not guessed at), NBCD **100%**. See `plan.md §Phase 91` for the full derivation writeup.

92. Root-caused MULS/MULU (24.5%/25.1% → 97.4%/97.3%); DIVS/DIVU turned out to need a much deeper separate investigation. Three stacked bugs, same shape as MULS's sibling AND/OR: (1) the shared AND/OR-memory-source decode blocks explicitly exclude `f_ss==11` (MUL/DIV's own opcode signature, not a size field for them — operand is always a fixed 16-bit word), so MULS/MULU's `(An)/(An)+/-(An)`/`(d8,An,Xn)`/`#imm` forms were **never decoded at all**; added four new blocks mirroring AND/OR's EA computation, plus the missing `is_muldiv_imm` `ext_count` classifier entry. (2) Even the pre-existing memory-source block never set `dec_mem_rd_siz` (a dedicated bus-read-size override for exactly this "32-bit result, but the read itself must stay a different size" situation, already used by other dual-size ops) — so every memory-source MUL requested a **longword** bus read for what should be word-sized, hanging forever waiting for an ack that specific access pattern never got. Confirmed via `$display` tracing (`ex_mem_stall`/`mem_ack` stuck forever, zero bus activity) before finding the fix. (1)+(2) took MULS/MULU 24.5%/25.1%→94.7%/94.8%. (3) The remaining ~5% (all indexed-form wrong-value FAILs) was a fourth instance of the recurring `gen_harte_hex.py` "f_ss/f_dir means something different for this instruction family" harness-bug shape: `get_scale_remap()`'s `siz_bytes` fallback silently defaults to 1 byte for MUL/DIV's `f_ss==3`, only copying half the scale-remapped test data; `get_operand_ea()` had a related but different bug in the same spot (its `f_ss==3` branch assumes ADDA/SUBA/CMPA-style `f_dir`-selects-size semantics, but for MUL/DIV `f_dir` selects signed/unsigned instead). Fixed both. Results: MULS **97.4%** (4816/4943), MULU **97.3%** (4858/4991); residual is 100% TIMEOUT on `(d8,An,Xn)`/`(d8,PC,Xn)` indexed forms — same symptom shape as Phase 90's still-open JMP/JSR indexed-EA stall (not confirmed to share a root cause), not investigated further this phase. **DIVS/DIVU are unrelated and much deeper**: even pure register-direct divides fail (CCR mismatches), and both suites show thousands of TIMEOUTs (barely moved by any of the above fixes, since register-direct forms never touch the memory-EA path) — points to a fundamental `eu_mul_div.sv` divide-FSM problem, likely around overflow-trap/divide-by-zero handling given the TIMEOUT volume. Needs its own from-scratch investigation. See `plan.md §Phase 92` for the full writeup.

93. Root-caused DIVS/DIVU (17.2%/19.8% → 97.6%/97.6%) — two bugs, unrelated to the MULS/MULU fixes. (1) **RTL comment was wrong**: DIVS/DIVU overflow's CCR handling was labeled `N/Z/C unchanged (matches Musashi)`, setting `ex_c = flag_c`. Hand-verified against 887 DIVS + 536 DIVU register-direct overflow vectors: N/Z genuinely are unchanged, but **C is 0 in 100% of cases** regardless of the incoming value — same "Musashi's undefined-behavior replication doesn't match real hardware" shape as Phase 91's BCD flags. One-line fix: `ex_c = 1'b0`. (2) **The actual mass-TIMEOUT cause**: `div_trap` was wired as a pure combinational `ex_valid && ex_unit==UNIT_DIV && md_div_by_zero`, with no gate on whether a memory-source operand had actually arrived — `md_src` reads `mem_rdata` live, which sits at its idle value of 0 before the bus read acks, so `eu_mul_div`'s `divs_zero=(src==0)` fired true on that transient zero, triggering a bogus divide-by-zero trap *while the pipeline was still stalled waiting for the real read* — the two mechanisms colliding hung the pipeline permanently. `$display` tracing confirmed: `mem_ack=0, mem_rdata=0, md_div_by_zero=1, ex_mem_stall=1`, forever. The fix already existed one line below as `chk_trap`'s pattern (CHK has the identical "memory-source operand not ready yet" hazard, already correctly gated on `mem_ack`) — applied the same structure to `div_trap`. This explains the overwhelming majority of both suites' TIMEOUT counts, since `mem_rdata`'s zero idle value made the bogus trap fire on essentially every memory-source divide's first evaluation. Results: DIVS **97.6%** (4856/4975), DIVU **97.6%** (4814/4931); residual is 100% TIMEOUT on `(d8,An,Xn)`/`(d8,PC,Xn)` indexed forms — now the *fourth* independent instruction family (after JMP/JSR, MULS/MULU) showing the identical indexed-EA-timeout symptom, strong evidence of one shared root cause, still not isolated. See `plan.md §Phase 93` for the full writeup.

94. Root-caused the shared indexed-EA TIMEOUT (JMP/JSR/MULS/MULU/DIVS/DIVU, Phases 90/92/93) for the MUL/DIV side — **not an RTL bug**. Traced a MULS `(d8,An,Xn)` TIMEOUT repro and found the multiply itself completes fine; a *subsequent, unrelated* garbage instruction hangs because execution ran past where it should have stopped. Root cause: the Tom Harte test corpus is captured on real **68000** hardware, which (unlike 68020/68030) faults with an Address Error on *any* misaligned word/long access, not just instruction fetch. `(d8,An,Xn)`'s brief-extension-word scale field (bits 10-9) is a 68020+-only feature — real 68000 silicon ignores those bits entirely (effective scale is always 1). For the ~2.5% of indexed-EA tests where scale-vs-no-scale changes the effective address's parity, the reference 68000 legitimately takes an Address Error (confirmed via the classic 7-word fault frame + vector-3 handler jump in the raw JSON) while our correctly-68030-accurate RTL legitimately does not fault on misaligned *data* access — an unreplicable, inherent 68000-vs-68030 divergence, not a bug. The TIMEOUT itself was a separate, fixable harness bug: `gen_harte_hex.py` placed the `STOP` runway using the reference's post-fault PC delta (`final.pc - initial.pc`, wildly large for these cases), so our non-faulting RTL ran straight past it into uninitialized memory and hung decoding garbage. Added a second backstop skip condition (alongside the existing `ea_info is None` one) for `ea_info` that *does* resolve but `instr_len` is still outside `[1,24]` and the instruction isn't JMP/JSR (whose own wild delta is a legitimate jump target, checked separately). Results: **MULS 100%, MULU 100%, DIVS 100%, DIVU 100%** (up from 97.3-97.6%), zero FAIL/TIMEOUT remaining in any of the four. Spot-checked MOVE.b/BCHG/CHK unchanged (no over-skipping). **JMP/JSR are unaffected by this fix** (explicitly exempted, correctly) and remain at 88.6%/89.1% — their TIMEOUT is a different, still-open issue, most likely a genuine RTL gap: unlike data access, 68030 *does* still fault on a misaligned instruction-fetch address, so an odd indexed jump target may need Address Error trapping we don't yet implement. See `plan.md §Phase 94` for the full writeup.

95. Root-caused JMP/JSR's own indexed-EA TIMEOUT (explicitly left open by Phase 94 as a *different* bug) — **also not an RTL bug, and also not an Address Error trap gap** as hypothesized. Reproduced JMP `(d8,A2,Xn)` index 4 and traced `eu_branch_target` in `m68030_top.sv`: the RTL correctly computed `0x4d5e9ede` (= `A2 + D2×4 + 18`, genuine 68030 scale-4 arithmetic per the extension word's scale bits), redirected PC there, then issued zero further bus activity — matching Phase 90's original observation exactly. Recomputing the same extension word with scale forced to 1 (68000 semantics, per Phase 94's finding that real 68000 ignores the scale field) gives `0x647ec5ef` — a **completely different address**, not just different parity. That's the key distinction from MULS/MULU/DIVS/DIVU: there, a scale mismatch only ever changes whether a *data* address is odd (irrelevant to 68030, which doesn't fault on misaligned data, so execution just continues with a different operand value). For JMP/JSR the "EA" *is* the new PC — a scale mismatch sends the reference and our RTL to two *entirely different places in memory*, regardless of parity. `gen_harte_hex.py`'s `build_patches()` places the `STOP` runway at the 68000 reference's own (unscaled) landing address; whichever CPU doesn't land there runs into uninitialized memory and hangs — for scale=0 (the vast majority) both interpretations agree so it already worked, but every scale≠0 case was unreplicable by construction. Fix: extended `can_run()`'s existing scale-remap skip loop — moved the `is_jmp_jsr` opcode check earlier so it's available there, and for JMP/JSR, skip unconditionally on ANY non-empty `get_scale_remap()` result (not just the odd/init-region conditions that apply to ordinary data instructions). Results: **JMP 100% (3758/3758), JSR 100% (3738/3738)**, up from 88.6%/89.1% — same PASS counts as before, confirming pure TIMEOUT→SKIP conversion with zero regression. **Zero RTL changes.** See `plan.md §Phase 95` for the full writeup.

**Current state**: 32/32 regression tests pass (`make test`). All 8 opcode groups pass vs Musashi (`make cosim_grp`). 50/50 synthetic dat-replay vectors pass (`make dat-synth`). Harte results: ADD/SUB/AND/OR/EOR/CMP b/w/l all 100%; MOVE.b/w/l/q all **100%** (Phase 85/89); BCHG/BCLR/BSET/BTST all **100%** (Phase 83/88); **CHK all 100%** (Phase 86); CLR/NEG/NOT/NEGX/TST all sizes **100%** (Phase 81/87); **ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR all sizes 100%** except ASL.b's 2 confirmed corpus anomalies (Phase 87); **ABCD/NBCD 100%, SBCD 99.7%** (Phase 91); **MULS/MULU/DIVS/DIVU all 100%** (Phases 92-94); **JMP/JSR all 100%** (Phase 95). **The 3rd-register-file-port investigation (`port3.md`) is concluded — nothing in the codebase requires it.** **Remaining unresolved gaps**: Scc, LEA, PEA, MOVEM.l, MOVEtoSR — none yet root-caused.

**Architectural gap — did not exist.** Every "needs a 3rd port" diagnosis investigated across Phases 81-84 (Bucket A, most of MOVE, Bucket C, Bucket D/CHK) turned out to be missing decode or a test-harness bug, not an RTL port-count limitation — Bucket B (AND/OR/EOR/SUB/CMP/ADDA/SUBA/CMPA) already worked with the existing 2-port time-multiplex trick, and even CHK's indexed form (the one case that looked architecturally justified on paper) closed the same way once actually tried. See `port3.md` for the full analysis, kept as a reference design in case a genuine 3-simultaneous-operand case ever turns up.

**Next phase**: Scc, PEA, LEA, MOVEM.l, MOVEtoSR — the last unresolved Harte gaps, none yet root-caused. TRAP/RTE/RTR supervisor-state harness limitation remains separately tracked.

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

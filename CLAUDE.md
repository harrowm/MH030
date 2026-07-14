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

**Current state**: 51/51 regression tests pass (`make test`). All 8 opcode groups pass vs Musashi reference (`make cosim_grp`).

**Next phase**: Phase 77 — Toni Wilen `.dat` suite replay harness (see `plans/cpu_phases_plan.md`).

## Verification Commands

```bash
make test          # 51/51 unit + integration regression
make buscmp        # smoke.s DUT vs Musashi bus log
make cosim_grp     # all 8 opcode group bus comparisons (grp0–grp7)
make buscmp-grp0   # single group (replace 0 with 1–7)
make cosim_grp     # rebuild cosim_grp sim binary if needed
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

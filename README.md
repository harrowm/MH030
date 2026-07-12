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

**Tools**: Icarus Verilog (simulation), GTKWave (waveform debug).

**Test strategy**: trace-driven co-simulation against WinUAE / Musashi. A reference run logs every bus transaction; the Verilog simulation runs the same binary and the bus logs are diffed cycle-by-cycle. Any divergence is a failure.

```
make test          # compile and run all tests
make run TEST=seq59  # compile and run one test
make compile       # compile all without running
make clean
```

Each `seq<N>_tb.sv` testbench corresponds to a phase of the implementation. Tests use a word-addressed 32-bit RAM model and the `run_instr()` pattern: feed an opcode sequence, wait for `instr_ack`, then drain the pipeline and check register and memory state.

---

## Design Rules

- SystemVerilog throughout (`always_ff`, `always_comb`, `typedef enum`, `struct`)
- All logic synchronous — no latches, no asynchronous resets
- No combinational feedback loops
- `generate` loops for replicated structures (the 8 data registers, 8 address registers, etc.)
- Keep each module under ~3000 lines
- No timing optimizations that collapse or skip real silicon cycles

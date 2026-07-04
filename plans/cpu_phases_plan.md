# MC68030 CPU — Post-BIU Development Plan

## Status (as of Phase 33)

Phases 23–31 complete:
- eu_regfile (23), eu_alu (24), eu_shifter (25), eu_mul_div (26) — arithmetic units
- eu_bcd (27), eu_bitops (28) — decimal and bit operations
- m68030_eu wrapper (29), eu_agu (30), m68030_ifu (31) — EU wrapper and IFU
- m68030_seq (32) — purely combinational IFU→EU glue; drain + ext_data format conversion

Integration milestone reached: IFU + SEQ + EU run a 4-instruction program end-to-end
(CLR.L / ADDI.L / CLR.L / ADD.L) with correct RAW-hazard stalling (tb/seq_int_tb.sv).
m68030_exc (33): exception controller complete — priority encoder, frame push FSM,
vector fetch, new PC/SR load. All 9 frame formats structurally handled; $0/$2/$3 fully tested.

The BIU (`m68030_biu`) is complete through Phase 22:
- All 8 bus cycle types implemented and tested
- BERR timeout watchdog, STERM, VPA/E-clock, HALT#, address errors
- `m68030_top` wrapper with all ports wired
- Two test suites: `tb/biu_tb.sv` (full) and `tb/top_tb.sv` (smoke)

All other CPU modules (`m68030_eu`, `m68030_ifu`, `m68030_seq`, `m68030_exc`, `m68030_mmu`) are stubs.

---

## Assessment of output2.txt (prior AI design)

The prior AI produced reasonable high-level architecture with correct module decomposition and useful flag-semantics notes. Key issues that must be corrected:

| Issue | Severity |
|-------|---------|
| Uses plain Verilog-2001 (`reg`/`wire`/`always @(*)`) — CLAUDE.md requires SystemVerilog | **Critical** |
| Register file reads are **registered** (1-cycle latency) — needs to be **combinational** | High |
| Barrel shifter L-stage 4 uses `l_stage1` instead of `l_stage3` (copy-paste bug) | High |
| `r_fill` uses invalid replication syntax `{24{sign_bit}, 8{sign_bit}}` | High |
| Divider iterates 32 times for a 16÷16 division (should be 16 iterations) | High |
| `increment_size` is `[1:0]` but encodes 4 bytes — needs `[2:0]` | Medium |
| `scaled_index = xn << (scale * 3'd1)` — `scale * 3'd1` is just `scale`, but expression is confusing | Low |
| Missing 68030-specific MSP (Master Stack Pointer) and M-bit in regfile | High |
| seq_decode_rom has duplicate `4'b0010` and `4'b1100` case arms | High |
| seq_microcode_rom is essentially a placeholder (2 real entries) | High |
| IFU fill/drain counter update has concurrent +2/-1 race | Medium |
| All modules use `clk`/`reset_n` not `clk_4x`/`rst_n` | High |
| No `generate` loops for register arrays | Medium |
| 68030 long-multiply (MULS.L/MULU.L) and 64÷32 divide not mentioned | Medium |

**Bottom line**: Use the other AI's design as a reference for module interfaces and flag semantics. Rewrite all code in SystemVerilog with our project conventions.

---

## High-Level Phase Roadmap

| Phase | Module | Key Output | Milestone |
|-------|--------|-----------|-----------|
| 23 | `eu_regfile` | D0-D7, A0-A7, USP/MSP/SSP, PC, SR | Register R/W works |
| 24 | `eu_alu` | ADD/SUB/AND/OR/EOR/NOT/NEG/CMP/ADDX/SUBX | Arithmetic with correct flags |
| 25 | `eu_shifter` | ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR | Barrel shift all sizes |
| 26 | `eu_mul_div` | MULS.W/MULU.W/MULS.L/MULU.L; DIVS/DIVU | Variable-cycle mul/div |
| 27 | `eu_bcd` | ABCD/SBCD/NBCD | BCD arithmetic |
| 28 | `eu_bitops` | BTST/BSET/BCLR/BCHG | Single-cycle bit ops |
| 29 | `m68030_eu` | EU wrapper integrating all above | EU compiles and passes unit tests |
| 30 | `eu_agu` | All 9 addressing modes + 68030 full ext | EA calculation |
| 31 | `m68030_ifu` | 4-word prefetch queue, PC tracking | Instruction stream works |
| 32 | `m68030_seq` | Opcode decode + micro-sequencer | Simple instruction execution |
| 33 | `m68030_exc` | Exception controller, all 9 frame formats | Exceptions work |
| 34 | Integration | EU+IFU+BIU+SEQ+EXC wired in `m68030_top` | First program runs |
| 35+ | MMU | TLB, table walker, PFLUSH/PTEST | Virtual memory |

---

## Clock / Reset Convention

All modules use:
- `clk_4x` — 100 MHz (4× the 25 MHz external bus)
- `rst_n` — active-low async reset

The EU runs at the same clock as the BIU. EU operations complete in multiples of 4 ticks (= 1 external bus cycle). The 4× clock gives the sequencer fine-grained control over when bus requests fire relative to S-states.

---

## Module Placement

```
rtl/
  eu_regfile.sv       Phase 23
  eu_alu.sv           Phase 24
  eu_shifter.sv       Phase 25
  eu_mul_div.sv       Phase 26
  eu_bcd.sv           Phase 27
  eu_bitops.sv        Phase 28
  m68030_eu.sv        Phase 29  (wrapper)
  eu_agu.sv           Phase 30
  m68030_ifu.sv       Phase 31
  m68030_seq.sv       Phase 32
  m68030_exc.sv       Phase 33

tb/
  eu_regfile_tb.sv    Phase 23
  eu_alu_tb.sv        Phase 24
  eu_shifter_tb.sv    Phase 25
  eu_mul_div_tb.sv    Phase 26
  eu_bcd_tb.sv        Phase 27
  eu_bitops_tb.sv     Phase 28
  eu_tb.sv            Phase 29
  agu_tb.sv           Phase 30
  ifu_tb.sv           Phase 31
  cpu_tb.sv           Phase 34  (integration)
```

---

## Integration Dependencies

```
m68030_top
├── m68030_biu      ✅ DONE (Phases 1–22)
├── m68030_eu       ← Phases 23–29
│   ├── eu_regfile
│   ├── eu_alu
│   ├── eu_shifter
│   ├── eu_mul_div
│   ├── eu_bcd
│   ├── eu_bitops
│   └── eu_agu      ← Phase 30 (touches BIU for mem indirect)
├── m68030_ifu      ← Phase 31
├── m68030_seq      ← Phase 32 (ties EU+IFU+BIU together)
├── m68030_exc      ← Phase 33
└── m68030_mmu      ← Phase 35+ (last; most complex)
```

See `plans/phase23_eu_regfile.md` for the immediate detailed plan.

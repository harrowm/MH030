# MC68030 CPU — Development Plan

## Status (as of Phase 64)

### BIU — complete (Phases 1–22)
All 8 bus cycle types, BERR/HALT/STERM/VPA, IACK, RMW, CAS2, MOVEM/MOVEP bus cycles,
burst linefill, MOVE16 burst, biu_exc_capture (fault snapshot, SSW), m68030_biu wrapper,
m68030_top stub. `biu_pin_driver`, `biu_config`, `biu_error_handler` fully fleshed out in
Phases 45 and 51.

### EU — complete through Phase 64

| Phase | Module / Feature | Status |
|-------|-----------------|--------|
| 23 | `eu_regfile` — D0-D7, A0-A7, USP/MSP/ISP, PC, SR, VBR | ✅ done |
| 24 | `eu_alu` — ADD/SUB/AND/OR/EOR/NEG/CMP/CLR/TST + X variants | ✅ done |
| 25 | `eu_shifter` — ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR | ✅ done |
| 26 | `eu_mul_div` — MULS/MULU word+long, DIVS.W/DIVU.W | ✅ done |
| 27 | `eu_bcd` + `eu_bitops` — ABCD/SBCD/NBCD, BTST/BCHG/BCLR/BSET | ✅ done |
| 28–35 | `eu_agu`, `m68030_eu`, `m68030_ifu`, `m68030_seq`, `m68030_exc`, `m68030_top`, `m68030_mmu` | ✅ done |
| 36 | Non-memory instrs + branches: NOP, SWAP, EXT/EXTB, ADDQ/SUBQ, Scc, DBcc, BRA/Bcc, MOVEQ | ✅ done |
| 37 | Memory EA reads/writes: (An), (An)+, -(An), (d16,An); MOVE, MOVEA, LEA | ✅ done |
| 38 | JMP, JSR, BSR, RTS, RTR — stack push/pop, subroutine calls | ✅ done |
| 39 | LINK, UNLK — C function frame setup/teardown | ✅ done |
| 40 | Absolute EA (xxx).W/(xxx).L — global variables, MMIO access | ✅ done |
| 41 | (d8,An,Xn) brief indexed EA — array/struct access | ✅ done |
| 42 | (d16,PC), (d8,PC,Xn) PC-relative — PIC/ROM code | ✅ done |
| 43 | MOVEM — register list save/restore | ✅ done |
| 44 | Exception stack frame EU integration — formats $9/$A/$B push sequence | ✅ done |
| 45 | BERR timeout watchdog — biu_error_handler (already done in BIU Phase 11) | ✅ done |
| 46 | MOVEC, MOVES — control-register and alternate-FC moves | ✅ done |
| 47 | TAS, CAS — atomic RMW | ✅ done |
| 48 | CHK, CHK2, CMP2 — bounds checking | ✅ done |
| 49 | MOVEP EU decode | ✅ done |
| 50 | MOVE16 EU decode | ✅ done |
| 51 | biu_pin_driver + biu_config — tri-state OE management, RSTOUT counter | ✅ done |
| 52 | FPU coprocessor bus interface — FC=111 CPU Space CPI/CPM/CPIR/CPCR cycles | ✅ done |
| 53 | Memory-indirect EA ([bd,An],Xn,od) — 030-specific inner dereference | ✅ done |
| 54 | MMU instructions: PFLUSH, PTEST, PMOVE | ✅ done |
| 55 | m68030_biu + m68030_top final — full external pin integration | ✅ done |
| 56 | RTE, MOVE SR/CCR/USP, STOP, TRAP #n, TRAPV, ILLEGAL | ✅ done |
| 57 | ADDA/SUBA/CMPA, ORI/ANDI/EORI to SR/CCR | ✅ done |
| 58 | MULS.L/MULU.L/DIVS.L/DIVU.L decode | ✅ done |
| 59 | PEA, EXG, RTD, CMPM | ✅ done |
| 60 | Memory-destination ALU operations (read-modify-write) | ✅ done |
| 61 | ADDX/SUBX register fix + -(An) predecrement form | ✅ done |
| 62 | Bit-field instructions: BFTST/BFEXTU/BFEXTS/BFFFO/BFCLR/BFSET/BFINS | ✅ done |
| 63 | PACK, UNPK (register + memory forms), LINK.L (#d32, 2 ext words), RESET | ✅ done |
| 64 | MOVES full EA + PMOVE CRP/SRP 64-bit 2-phase FSM | ✅ done |

**42/42 regression tests pass** (`make test`).

### ISA gap analysis (post Phase 64)

A systematic audit of `eu_seq.sv` decode against the MC68030 programmer's reference manual
identified the following gaps. Phases 65–69 close all of them.

**Critical — present in nearly every compiled binary**:
- ALU ops (ADD/SUB/AND/OR/EOR/CMP) with memory source → register destination
  (e.g. `ADD (An),Dn`, `CMP (d16,An),Dn`) — *entirely absent*
- `ADDQ/SUBQ #n,An` — address register target missing (only Dn and memory handled)
- `ADDA/SUBA/CMPA (ea),An` — memory source forms missing (only Dn/An/#imm)
- `MULS.W/MULU.W/DIVS.W/DIVU.W (ea),Dn` — memory source forms missing
- `MOVE (src),(dst)` where both src and dst are memory modes — missing

**Medium — OS paths, less common compiled code**:
- `TRAPcc` (no-operand, .W, .L) — 68020+ instruction, not decoded at all
- `CAS` EU decode — BIU has the 4-phase bus FSM; EU decode missing
- `ABCD/SBCD -(Ay),-(Ax)` — predecrement-memory BCD form missing
- `NBCD.B (An)/(An)+/-(An)` — memory NBCD forms missing
- `BTST/BCHG/BCLR/BSET #imm,(memory)` — immediate bit-ops to memory missing
- `MOVE (An),SR` / `MOVE (An),CCR` / `MOVE SR,(An)` / `MOVE CCR,(An)` — memory forms missing

**Lower priority — extended EA coverage for existing instructions**:
- `MOVEM (d16,An)/(d8,An,Xn)/abs.W/abs.L/(d16,PC)` — only (An)/(An)+/-(An) handled
- `Scc (d16,An)/abs.W` — only (An)/(An)+/-(An) handled
- `CHK (memory ea),Dn` — only Dn and #imm upper-bound sources
- `TAS (An)+`, `TAS -(An)` — only `(An)` handled
- Bitfield ops with `(d16,An)/abs.W/abs.L/(d16,PC)/(d8,PC,Xn)` — only Dn and (An) EA
- `CMP2/CHK2 (d16,An)/abs.W/abs.L` — only `(An)` handled

**Deliberate omissions** (not being added):
- `MOVES (xxx).L` — requires 3 extension words; ext_count is capped at 2
- `MOVES (d8,An,Xn)` STORE — 3-register conflict (Rn + An + Xn simultaneously)
- `PLOAD` — not commonly used; MMU ATC is managed by PFLUSH/PTEST

---

## Verification Strategy: WinUAE cputest

### What the tool is

WinUAE cputest (`cputest/main.c` in the WinUAE repository) is an **Amiga OS application**
that runs on a real Amiga or in WinUAE emulation. It:

1. Loads per-instruction test data from `.dat` files generated by the UAE CPU core reference
2. For each test case: initialises registers + memory from the `.dat` data, executes one
   instruction, compares resulting state (registers, CCR, memory writes, exception frames)
   against the expected state embedded in the `.dat` file
3. Reports mismatches to stdout

The expected values come from WinUAE's internal UAE 68030 softcore, which has been
validated against real hardware. Coverage: every CCR combination × every addressing
mode × every opcode encoding.

### Practical approach: .dat replay harness

```
WinUAE (68030 mode)
  └─ cputest binary generates .dat files via UAE reference core
       └─ Python parser reads .dat files
            └─ Extracts: (instr_bytes, initial_state, expected_state)
                 ├─ Feeds initial_state to Verilator simulation
                 ├─ Injects instruction bytes into simulation memory
                 ├─ Runs simulation until instruction retires
                 └─ Compares actual final_state vs expected_state
```

| Component | Description |
|-----------|-------------|
| `scripts/gen_dat.sh` | Drive WinUAE headless to generate `.dat` files for each opcode group |
| `scripts/parse_dat.py` | Parse WinUAE `.dat` binary format → JSON test vectors |
| `scripts/run_vsim.py` | Feed test vectors to Verilator via DPI or testbench SV task |
| `scripts/compare.py` | Diff actual vs expected; report per-test pass/fail with instruction disasm |
| `tb/cosim_tb.sv` | Verilator-compatible testbench that exposes state inspection hooks |

Verification checkpoints:
- **Checkpoint α** (after Phase 43) ✅ — BRA/Bcc, MOVE, ALU, shifts, MOVEM
- **Checkpoint β** (after Phase 50) ✅ — extended EA modes, control flow, atomics, MOVEM/MOVEP/MOVE16
- **Checkpoint γ** (after Phase 64) — near-complete instruction set; run cputest `basic/all` suite

---

## Completed Phases — Summary Notes

### Phases 38–43 (subroutine/EA/MOVEM) ✅
See inline sections below for original specs. All passed at Checkpoint α.

### Phases 44–50 (OS primitives + bus ops) ✅
Exception frames, MOVEC/MOVES, TAS/CAS, CHK/CHK2/CMP2, MOVEP, MOVE16. All passed at Checkpoint β.

### Phases 51–55 (BIU polish + top integration) ✅
biu_pin_driver/biu_config, FPU coprocessor bus, memory-indirect EA, MMU instructions, m68030_top final.

### Phase 56 — RTE, MOVE SR/CCR/USP, STOP, TRAP, TRAPV, ILLEGAL ✅
- RTE: two-phase longword reads from stack (SR then PC); full SR restore; A7 += 8
- MOVE SR,Dn / MOVE CCR,Dn: dec_imm = sr_out at decode time
- MOVE Dn,SR / MOVE Dn,CCR: fire sr_wr_en from WB stage
- MOVE An,USP / MOVE USP,An: usp_wr_en port
- STOP #imm: dec_needs_ext; stop_r holds eu_stop until exc_sr_wr_en clears it
- TRAP #n / TRAPV / ILLEGAL: eu_trap_req / eu_trapv_req / eu_illegal_req combinational outputs

### Phase 57 — ADDA/SUBA/CMPA, ORI/ANDI/EORI to SR/CCR ✅
- ADDA/SUBA (Groups D/9, f_ss=11): CCR unchanged; dec_sext_src sign-extends src[15:0] for .W
- CMPA (Group B, f_ss=11): dec_updates_ccr=1, dec_x_unchanged=1, dec_writes_reg=0
- ORI/ANDI/EORI to CCR/SR (Group 0, f_mode=111, f_reg=100): result pre-computed at DECODE
  using sr_out OP ext_data[7:0 or 15:0]; reuses dec_is_move_ccr_w / dec_is_move_sr_w paths
- m68030_seq: added f_reg declaration; updated ext_count for .L (2 ext words) vs .W (1)

### Phases 58–62 ✅
- Phase 58: MULS.L/MULU.L 32×32→64 and DIVS.L/DIVU.L 64÷32; wr2 port for Dh/Dr; 64-bit N flag from product[63]
- Phase 59: PEA (push EA value), EXG (register swap via an_wr), RTD (RTS + imm delta), CMPM (2-phase postinc reads)
- Phase 60: Memory-destination ALU (ADD/SUB/AND/OR/EOR/CLR/NOT/NEG/Scc/shift/bit to (An));
  mem_rmw_run_r FSM captures result+CCR at read ack, issues write, fires sr_wr_en at write ack
- Phase 61: ADDX/SUBX register form fix (src/dst registers were swapped); -(An) 3-phase FSM
  (predec+read Ay, predec+read Ax, write result); Z only cleared rule verified
- Phase 62: Bit-field instructions via new `eu_bitfield.sv` combinational unit;
  register EA single-cycle through WB; memory EA 2-phase FSM (read→write for CLR/SET/INS);
  bf_dn_wr_en and bf_mem_sr_wr_en bypass paths for Dn+CCR at ack; 33-bit mask handles width=32;
  ext word bits[10:6]=offset, bits[4:0]=width(0→32); BFINS CCR from inserted value, not field

---

## Completed Phase Specs

### Phase 58 — MULS.L / MULU.L / DIVS.L / DIVU.L decode ✅ done

**Why first**: The functional units for 32-bit multiply and divide already exist in
`eu_mul_div.sv`. Only the decode in `eu_seq.sv` is missing. Quickest win.

| Instruction | Opcode | Action |
|-------------|--------|--------|
| MULU.L ea,Dl | 0100 1100 00 EA, ext={Dl,0,0,…,Dl} | Dl ← ea × Dl (32×32→32 unsigned) |
| MULS.L ea,Dl | 0100 1100 00 EA, ext={Dl,0,1,…,Dl} | Dl ← ea × Dl (32×32→32 signed) |
| MULU.L ea,Dh:Dl | 0100 1100 00 EA, ext={Dh,0,0,…,Dl} | Dh:Dl ← ea × Dl (32×32→64 unsigned) |
| MULS.L ea,Dh:Dl | 0100 1100 00 EA, ext={Dh,0,1,…,Dl} | Dh:Dl ← ea × Dl (32×32→64 signed) |
| DIVU.L ea,Dr:Dq | 0100 1100 01 EA, ext={Dr,0,0,…,Dq} | Dq ← Dr:Dq ÷ ea; Dr ← remainder |
| DIVS.L ea,Dr:Dq | 0100 1100 01 EA, ext={Dr,0,1,…,Dq} | Dq ← Dr:Dq ÷ ea; Dr ← remainder |

Extension word format: [15:12]=Dh/Dr, [11]=0, [10]=size (0=32-bit result, 1=64-bit),
[9:7]=0, [6]=signed, [5:3]=0, [2:0]=Dl/Dq.

`eu_mul_div` already implements MUL_UL/MUL_SL/DIV_UL/DIV_SL; `eu_seq` needs:
- Decode 0x4C00 (MUL) and 0x4C40 (DIV) patterns
- Parse extension word for register pair and signed/unsigned flag
- dec_needs_ext=1 to capture the extension word
- Wire 64-bit result (Dh, Dl) to two separate register writes (WB stage)

Files: `rtl/eu_seq.sv`, `tb/seq58_tb.sv`

---

### Phase 59 — PEA, EXG, RTD, CMPM ✅ done

**Why here**: Four small, independent instructions. Each takes only a few lines in eu_seq.
Knocking them out together keeps momentum.

| Instruction | Opcode | Action |
|-------------|--------|--------|
| PEA ea | 0100 1000 01 EA (0x4840) | A7-=4; M[A7] ← effective_address (not contents) |
| EXG Dx,Dy | 1100 Dx 1 01000 Dy | Swap two data registers |
| EXG Ax,Ay | 1100 Ax 1 01001 Ay | Swap two address registers |
| EXG Dx,Ay | 1100 Dx 1 10001 Ay | Swap data and address register |
| RTD #imm | 0100 1110 0111 0100, ext=imm16 | PC ← M[(A7)]; A7 += 4 + sign_ext(imm) |
| CMPM (Ay)+,(Ax)+ | 1011 Ax 1 ss 001 Ay | CCR from (Ax)+ − (Ay)+; both postincrement |

**PEA**: Use existing EA computation; push `ex_ea` rather than `mem_rdata`.
Set `dec_is_mem_wr=1`, `dec_use_imm=1` (imm = computed EA), `dec_an_delta[7]=-4`.

**EXG**: Single-cycle register swap. Two register reads (rd_a, rd_b), two register writes
(dec_dest_reg for one, an_wr_en for the other). No memory, no CCR.

**RTD**: Like RTS but A7 += 4 + imm instead of just 4. Reuses rts FSM; dec_an_delta
absorbs the extra displacement from the extension word.

**CMPM**: Two sequential postincrement memory reads. The existing -(An)/+(An) machinery
applies; needs a 2-phase stall (similar to RTR) to sequence both reads before the compare.
CCR updated from the compare result; no register write.

Files: `rtl/eu_seq.sv`, `tb/seq59_tb.sv`

---

### Phase 60 — Memory-destination ALU operations ✅ done

**Why here**: This is the largest remaining gap. Every ALU instruction that can write
back to a memory EA (not just Dn) must be handled. This covers a substantial fraction
of the 68030 encoding space.

Operations that need memory-destination support:
- `ADD Dn,ea` / `SUB Dn,ea` / `AND Dn,ea` / `OR Dn,ea` / `EOR Dn,ea`
- `ADDQ #imm,ea` / `SUBQ #imm,ea`
- `CLR ea` / `NOT ea` / `NEG ea` / `NEGX ea`
- `Scc ea` — set byte at ea from condition code
- `ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR ea` (single-bit memory shifts, f_ss=11)
- `BSET/BCLR/BCHG ea` (bit ops to memory)
- Immediate ops to memory: `ADDI ea`, `SUBI ea`, `ANDI ea`, `ORI ea`, `EORI ea`, `CMPI ea`

**Approach**: All of these share the same read-modify-write pattern:
1. Compute EA (existing machinery)
2. Issue memory read (existing mem_req/ack)
3. Execute ALU op on mem_rdata
4. Issue memory write with result

The key new signal is `dec_is_mem_rmw`: instructs eu_seq to hold the address
through both the read and write phases, suppressing the normal WB register write and
instead issuing a second mem_req (write) with `wb_result` as `mem_wdata`.

`CMPI ea` and `TST ea` (read + CCR update, no write) are covered by existing
`dec_is_mem_rd + dec_updates_ccr + dec_writes_reg=0`.

Files: `rtl/eu_seq.sv`, `tb/seq60_tb.sv`

---

### Phase 61 — ADDX/SUBX -(An) and X-flag precision ✅ done

**Why here**: Extended-precision arithmetic (multi-word addition) is heavily used in
compilers for 64-bit integer support. The -(An) memory form requires two predecrement
reads and a write.

| Instruction | Opcode | Action |
|-------------|--------|--------|
| ADDX -(Ay),-(Ax) | 1101 Ax 1 ss 000 1 Ay | -(Ax) ← -(Ax) + -(Ay) + X; update X/N/V/C; Z only cleared |
| SUBX -(Ay),-(Ax) | 1001 Ax 1 ss 000 1 Ay | -(Ax) ← -(Ax) − -(Ay) − X; update X/N/V/C; Z only cleared |

Register-direct ADDX/SUBX (f_mode=000, f_reg=0—no memory bit) already work via
the existing eu_alu ADDX/SUBX ops. The -(An) form (bit 3 of the low byte = 1) adds:
- Predecrement Ay, read M[Ay]
- Predecrement Ax, read M[Ax]
- Execute ADDX/SUBX with carry-in from X flag
- Write result to M[Ax]

Requires a 3-phase stall sequence: (1) decrement+read Ay, (2) decrement+read Ax,
(3) write result to Ax address.

Also fix: verify X-flag Z-flag rule is correctly applied throughout — Z is cleared if
result ≠ 0 but **never set** if result = 0 (allows chaining multi-word adds).

Files: `rtl/eu_seq.sv`, `tb/seq61_tb.sv`

---

### Phase 62 — Bit-field instructions (BFXXX) ✅ done

**Why here**: Required for the cputest `all` suite to pass cleanly. The bit-field ops
are a 68020+ extension; the cputest exercises them heavily.

| Instruction | Opcode | Action |
|-------------|--------|--------|
| BFTST ea {offset:width} | 1110 1000 11 EA | Test field, set N/Z from it |
| BFEXTU ea {offset:width},Dn | 1110 1001 11 EA | Extract field zero-extended into Dn |
| BFEXTS ea {offset:width},Dn | 1110 1010 11 EA | Extract field sign-extended into Dn |
| BFFFO ea {offset:width},Dn | 1110 1011 11 EA | Find first one; Dn ← bit position |
| BFCLR ea {offset:width} | 1110 1100 11 EA | Clear field |
| BFSET ea {offset:width} | 1110 1110 11 EA | Set field |
| BFINS Dn,ea {offset:width} | 1110 1111 11 EA | Insert Dn into field |

Extension word: [11:6]=offset (6 bits; bit 11=register flag), [5:0]=width (6 bits; 0=32).

A field can span up to 32 bits across multiple bytes. The EA is a byte address;
offset and width select the exact bit range.

**New submodule** `eu_bitfield.sv` (combinational): given a 64-bit window (two longwords
from memory at ea and ea+4 if field crosses a boundary), offset, width — extracts or
inserts the field. `eu_seq` issues one or two memory reads as needed, feeds the window,
then one memory write for mutating ops.

Files: `rtl/eu_bitfield.sv` (new), `rtl/eu_seq.sv`, `tb/seq62_tb.sv`

---

### Phase 63 — PACK, UNPK, LINK.L, RESET

**Why here**: Completeness. Each is small and independent.

| Instruction | Opcode | Action |
|-------------|--------|--------|
| PACK -(Ay),-(Ax),#adj | 1000 Ax 1 01 000 1 Ay | Merge two BCD nibbles + adj; -(An) form |
| UNPK -(Ay),-(Ax),#adj | 1000 Ax 1 10 000 1 Ay | Split one BCD byte into two ASCII digits + adj |
| LINK.L An,#imm32 | 0100 1000 0000 1 An, ext=imm32 | Like LINK.W but 32-bit displacement (2 ext words) |
| RESET | 0100 1110 0111 0000 | Assert RSTOUT for 512 ext clocks; EU stalls |

**PACK**: Two memory reads (-(Ay), -(Ax) for source byte and prior destination),
one memory write. BCD packing logic can reuse eu_bcd infrastructure.

**LINK.L**: Identical to LINK.W but dec_needs_ext=1 with 2 extension words
(dec_imm = ext_data[31:0]). m68030_seq ext_count=2 for this opcode.

**RESET**: Assert biu_rstout_req signal from eu_seq; BIU drives RSTOUT for the
required duration; eu_seq stalls (eu_stop=1) during the reset pulse.

Files: `rtl/eu_seq.sv`, `rtl/m68030_seq.sv`, `rtl/m68030_top.sv` (RESET wire), `tb/seq63_tb.sv`

---

### Phase 64 — MOVES full EA, PMOVE CRP/SRP (64-bit) ✅

**Why last**: These are wiring-heavy finishes that require co-ordination between
EU, BIU, and MMU. Low risk of breaking other paths; best left until the instruction
set is otherwise complete.

**MOVES full EA**: Phase 46 implemented MOVES for register-direct EA only. Extend to
all indirect modes: (An), (An)+, -(An), (d16,An), (d8,An,Xn), absolute.
EU picks SFC (read) or DFC (write) from eu_regfile and passes it as mem_fc override.
m68030_seq: add ext_count entries for (d16,An) and indexed forms (MOVES uses 2 ext words
for the extension word + displacement).

**PMOVE CRP/SRP**: CPU Root Pointer and Supervisor Root Pointer are 64-bit registers
in the MMU. A PMOVE to/from CRP or SRP requires two 32-bit bus cycles (high longword
then low longword). eu_seq must sequence two memory reads (load) or two writes (store)
and pass both halves to/from the MMU via the existing `m68030_mmu` interface.

Files: `rtl/eu_seq.sv`, `rtl/m68030_seq.sv`, `rtl/m68030_top.sv`, `tb/seq64_tb.sv`

---

---

## Remaining Phases (65–69)

---

### Phase 65 — ALU memory-source → register destination

**Why critical**: The most common instruction pattern in compiled C — loading a value from
memory and combining it with a register — is entirely absent. `ADD (An),Dn`,
`CMP (d16,An),Dn`, `AND (xxx).W,Dn`, `OR (d16,PC),Dn` etc. all fall through the decoder
silently. This is present in virtually every function body and will cause immediate failures
in any WinUAE trace comparison.

**Scope**: Groups 8/9/B/C/D (OR/SUB/CMP/AND/ADD and their A-register variants) with
`f_dir=0` and `f_mode ∈ {010, 011, 100, 101, 111}` (any memory EA mode). The operation is:

```
Dn ← Dn  op  M[ea]       (ADD/SUB/AND/OR/EOR — register updated, CCR updated)
CCR ← Dn − M[ea]          (CMP — CCR only, no register write)
```

**Implementation**: Single memory read cycle (existing `dec_is_mem_rd` path). WB stage
needs a new `dec_mem_src_op` path: after `mem_ack`, feed `mem_rdata` as one ALU operand
and the EX-latched register value as the other. The result goes to Dn (not back to memory).
This is simpler than Phase 60 (memory-destination RMW) — no second bus cycle needed.

**EA modes required**: (An), (An)+, -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L,
(d16,PC), (d8,PC,Xn) — all the existing read-capable modes.

**Sizes**: .B, .W, .L for all arithmetic ops.

**Also add**: MULS.W/MULU.W/DIVS.W/DIVU.W and MULS.L/MULU.L/DIVS.L/DIVU.L from memory
EA (same pattern: read operand from memory, feed to multiplier/divider already instantiated).

| Instruction examples | Opcode pattern |
|---------------------|----------------|
| ADD (An),Dn | 1101 Dn 0 ss 010 An |
| SUB (d16,An),Dn | 1001 Dn 0 ss 101 An, ext=d16 |
| AND abs.W,Dn | 1100 Dn 0 ss 111 000, ext=abs |
| CMP (d16,PC),Dn | 1011 Dn 0 ss 111 010, ext=d16 |
| OR (An)+,Dn | 1000 Dn 0 ss 011 An |
| MULS.W (An),Dn | 1100 Dn 1 11 010 An |

Files: `rtl/eu_seq.sv`, `tb/seq65_tb.sv`

---

### Phase 66 — Address arithmetic + ADDQ/SUBQ #,An

**Why next**: `ADDQ #4,A7` and `SUBQ #8,A7` are in every C function prologue/epilogue for
stack frame management. Additionally `ADDA.L (An),A0` / `CMPA.W (d16,An),A5` appear
constantly in pointer arithmetic.

**Part A — ADDQ/SUBQ #imm,An (Group 5, f_mode=001)**

`ADDQ/SUBQ #3bit,An` — the address-register target form is missing. `f_mode=001` (An
direct) is not handled. This is a single-cycle register op: An ← An ± zero-extended imm3.
CCR is *not* updated (architecturally defined for address-register operand).

Also extend `ADDQ/SUBQ` to full memory EA: `(d16,An)`, `abs.W/L`, indexed — these follow
the same memory-destination RMW pattern already built in Phase 60.

**Part B — ADDA/SUBA/CMPA from memory source**

Groups 9/D/B with `f_ss=11` currently only handle `f_mode ∈ {000, 001, 111 f_reg=100}`
(Dn, An, #imm). Extend to all memory EA modes:

```
An ← An + sign_ext(M[ea])    (ADDA.W: sign-extend 16-bit; ADDA.L: full 32-bit)
An ← An − sign_ext(M[ea])    (SUBA)
CCR ← An − sign_ext(M[ea])   (CMPA — CCR only, no An write)
```

| Instruction examples | Opcode pattern |
|---------------------|----------------|
| ADDQ #4,A7 | 0101 100 1 00 001 111 |
| SUBQ #8,SP | 0101 100 1 ss 001 111 |
| ADDA.L (An),A0 | 1101 000 1 11 010 An |
| SUBA.W (d16,An),A3 | 1001 011 0 11 101 An, ext=d16 |
| CMPA.L (xxx).W,A5 | 1011 101 1 11 111 000, ext=abs |

Files: `rtl/eu_seq.sv`, `tb/seq66_tb.sv`

---

### Phase 67 — MOVE memory→memory; MOVE ea,SR/CCR from/to memory

**Part A — MOVE (src_ea),(dst_ea)**

Groups 1/2/3 (MOVE.B/L/W) where the destination mode `dst_mode ∈ {010,011,100,101,111}`
(any memory write target) currently only accept `src_mode ∈ {000, 001}` (register source).
`MOVE (A0)+,-(A1)` — the archetypal block-copy idiom — is not decoded.

This requires a 2-phase bus operation:
1. Read from src EA → latch as `move_mm_data_r`
2. Write `move_mm_data_r` to dst EA

The dst EA must be computed after the src EA. For most modes both EAs are known at decode
time (EA is a pure function of An + displacement). For -(An) dst the predecrement fires
on the write phase.

A new `dec_is_move_mm` flag drives a `move_mm_run_r` FSM (similar in structure to the
existing `mem_rmw_run_r` but using separate src and dst addresses). No ALU op — pure copy.

**Part B — MOVE ea,SR / MOVE ea,CCR from memory**

`MOVE (An),SR` (Group 4, `f_dn=011, f_ss=11, f_mode=010`) and `MOVE (An),CCR`
(Group 4, `f_dn=010, f_ss=11, f_mode=010`) currently only decode `f_mode=000` (Dn).
Extend to all readable memory EA modes. The read yields `mem_rdata`; WB fires
`sr_wr_en` or `ccr_wr_en` with the read value.

Symmetrically add `MOVE SR,(An)` and `MOVE CCR,(An)` (memory-write destination).

| Instruction examples | Opcode pattern |
|---------------------|----------------|
| MOVE (A0)+,-(A1) | 0010 001 100 011 000 |
| MOVE (d16,A0),(A1) | 0010 001 010 101 000, ext=d16 |
| MOVE (An),SR | 0100 011 011 010 An |
| MOVE (An),CCR | 0100 010 011 010 An |
| MOVE SR,(An) | 0100 000 011 010 An |

Files: `rtl/eu_seq.sv`, `tb/seq67_tb.sv`

---

### Phase 68 — TRAPcc; CAS EU decode; BCD/bit-op memory forms

**Part A — TRAPcc (68020+ instruction)**

Opcode group 5, `f_ss=11`, `f_mode=111`: TRAP if condition true, else fall through.
Three operand variants:
- `TRAPcc` (no operand): `f_reg=100` — 1 word, no extension
- `TRAPcc.W #imm`: `f_reg=010` — 1 extension word (ignored by hardware, consumed for PC advance)
- `TRAPcc.L #imm`: `f_reg=000` — 2 extension words (similarly ignored)

If the condition is false: NOP (advance PC past extension words, no side effect).  
If the condition is true: raise Trap #7 exception (same vector as TRAPV but with the
actual condition code evaluated).

`m68030_seq.sv`: add `ext_count = 2'd1` for .W form and `2'd2` for .L form.

**Part B — CAS EU decode**

Phase 47 implemented the BIU's 4-phase RMW bus machinery for CAS. The EU decode in
`eu_seq.sv` is missing. CAS encoding:

```
Group 0, f_ss=11, f_dn ∈ {101=byte, 011=word, 111=long}
f_mode ∈ {010,011,100,101,111} (memory EA)
ext[2:0]=Du (update reg), ext[8:6]=Dc (compare reg)
```

Operation: `if M[ea] == Dc: M[ea] ← Du; Dc ← M[ea]; CCR ← M[ea] - Dc`.
EU sets `dec_is_cas`, `dec_mem_rmw=1`; BIU issues locked RMW cycle.

**Part C — BCD/bit-op memory gaps**

- `ABCD -(Ay),-(Ax)` / `SBCD -(Ay),-(Ax)`: Group C/8, `f_mode=001` (predecrement memory).
  Two predecrement reads + BCD op + write. Reuse -(An) infrastructure from Phase 61.

- `NBCD.B (An)/(An)+/-(An)`: Group 4, `f_dn=100` in the memory-RMW block. Currently
  excluded; add it alongside the existing NEG/CLR/NOT/NEGX/TST memory forms.

- `BTST/BCHG/BCLR/BSET #imm,(memory)`: Group 0, `f_dn=100 f_dir=0`, `f_mode ∈ {010,011,100}`.
  Read memory byte, apply bit op, write back. Reuses Phase 60 memory-RMW path.

Files: `rtl/eu_seq.sv`, `rtl/m68030_seq.sv`, `tb/seq68_tb.sv`

---

### Phase 69 — Extended EA sweep (MOVEM, Scc, CHK, TAS, Bitfield, CMP2/CHK2)

This phase closes all remaining EA-coverage gaps in instructions that already exist
but only handle a subset of the legal addressing modes.

**MOVEM extended EA** (currently only (An)/(An)+/-(An)):

| Form | Missing modes |
|------|--------------|
| MOVEM list,(dst) — store | (d16,An), (d8,An,Xn), (xxx).W, (xxx).L |
| MOVEM (src),list — load | (d16,An), (d8,An,Xn), (xxx).W, (xxx).L, (d16,PC), (d8,PC,Xn) |

The multiop FSM in `biu_multiop_fsm.sv` already walks the register list; only the base
address computation and EA decode in `eu_seq.sv` need extension.

**Scc extended EA** (currently only (An)/(An)+/-(An)):

Add `(d16,An)`, `(xxx).W`, `(xxx).L` as memory-write destinations. The existing
memory-write path from Phase 60 handles this; only the decode condition needs widening.

**CHK memory source** (currently only Dn and #imm upper-bound):

`CHK (An),Dn`, `CHK (d16,An),Dn`, `CHK (xxx).W,Dn` — read upper bound from memory,
compare against Dn, trap if out of range. Single memory read then compare.

**TAS extended EA** — add `(An)+` and `-(An)` forms alongside existing `(An)`.

**Bitfield extended EA** (currently only Dn and (An)):

Add `(d16,An)`, `(xxx).W`, `(xxx).L`, `(d16,PC)`, `(d8,PC,Xn)` for all 8 BFXXX ops.
The existing `eu_bitfield.sv` unit is already combinational; only the EA decode path
and address wiring in `eu_seq.sv` need extension.

**CMP2/CHK2 extended EA** (currently only (An)):

Add `(d16,An)`, `(xxx).W`, `(xxx).L`, `(d16,PC)`, `(d8,PC,Xn)`.

Files: `rtl/eu_seq.sv`, `tb/seq69_tb.sv`

---

**CHECKPOINT γ — WinUAE cputest near-full-binary execution**

After Phase 69 the MC68030 encoding space is fully covered (excluding the three deliberate
omissions listed above). Strategy:
1. Extract `.dat` test vectors from WinUAE (run cputest in WinUAE 68030 mode)
2. Python parser reads `.dat` binary format → JSON vectors:
   `(instr_bytes, initial_D[0..7], initial_A[0..7], initial_SR, expected_D/A/SR/memory)`
3. Verilator testbench (`tb/cosim_tb.sv`) applies each vector:
   - Pre-load registers via hierarchical DPI calls
   - Write instruction bytes to simulation memory
   - Run for fixed cycle budget
   - Read back register file state via DPI
   - Compare with expected
4. Run the full `basic/all` cputest suite for 68030; target <10 failures per opcode group

Files: `scripts/parse_dat.py`, `scripts/run_cosim.py`, `scripts/compare.py`, `tb/cosim_tb.sv`

---

## Summary Table

| Phase | Content | Status | Enables |
|-------|---------|--------|---------|
| **38** | JMP, JSR, BSR, RTS, RTR | ✅ | Subroutine calls — any real program |
| **39** | LINK, UNLK | ✅ | C function prologues/epilogues |
| **40** | Absolute EA (xxx).W/(xxx).L | ✅ | Global variables, MMIO |
| **41** | (d8,An,Xn) brief indexed | ✅ | Array/struct access |
| **42** | (d16,PC), (d8,PC,Xn) PC-relative | ✅ | PIC code, ROM routines |
| **43** | MOVEM — register list save/restore | ✅ | Register save/restore, exception entry/exit |
| **α** | Checkpoint α | ✅ | |
| **44** | Exception frame EU integration | ✅ | Correct $9/$A/$B frames |
| **45** | BERR timeout watchdog | ✅ | Prevents simulation hangs |
| **46** | MOVEC, MOVES (register EA) | ✅ | OS-level control register access |
| **47** | TAS, CAS bus | ✅ | Atomic primitives |
| **48** | CHK, CHK2, CMP2 | ✅ | Bounds-checked array access |
| **49** | MOVEP EU decode | ✅ | Byte-wide peripheral access |
| **50** | MOVE16 EU decode | ✅ | 68030-specific 16-byte burst |
| **β** | Checkpoint β | ✅ | |
| **51** | biu_pin_driver + biu_config | ✅ | Clean tri-state / reset behaviour |
| **52** | FPU coprocessor bus interface | ✅ | MC68881/68882 bus cycles |
| **53** | Memory-indirect EA | ✅ | 030-specific ([bd,An],Xn,od) modes |
| **54** | MMU instructions: PFLUSH/PTEST/PMOVE | ✅ | MMU management code |
| **55** | m68030_biu + m68030_top final | ✅ | Fully wired top-level |
| **56** | RTE, MOVE SR/CCR/USP, STOP, TRAP, TRAPV, ILLEGAL | ✅ | OS control flow |
| **57** | ADDA/SUBA/CMPA (register), ORI/ANDI/EORI→SR/CCR | ✅ | Pointer arithmetic, flag manipulation |
| **58** | MULS.L/MULU.L/DIVS.L/DIVU.L | ✅ | 64-bit multiply/divide |
| **59** | PEA, EXG, RTD, CMPM | ✅ | Stack frames, register exchange |
| **60** | Memory-destination ALU (RMW) | ✅ | Memory operand modification |
| **61** | ADDX/SUBX -(An) + X-flag precision | ✅ | Extended-precision arithmetic |
| **62** | Bit-field instructions (BFXXX) | ✅ | Packed data, bit manipulation |
| **63** | PACK/UNPK, LINK.L, RESET | ✅ | BCD, large frames, hardware reset |
| **64** | MOVES full EA, PMOVE CRP/SRP (64-bit) | ✅ | Alternate-space moves, MMU root ptrs |
| **65** | ALU memory-source → register (ADD/SUB/AND/OR/EOR/CMP/MUL/DIV from memory) | — | *Most* compiled code patterns |
| **66** | ADDQ/SUBQ #,An; ADDA/SUBA/CMPA from memory | — | Every C function prologue/epilogue |
| **67** | MOVE memory→memory; MOVE ea,SR/CCR | — | Block copy, OS SR manipulation |
| **68** | TRAPcc; CAS EU decode; BCD/bit-op memory forms | — | OS traps, atomics, BCD memory |
| **69** | Extended EA sweep: MOVEM/Scc/CHK/TAS/Bitfield/CMP2CHK2 | — | Full EA coverage |
| **γ** | Checkpoint γ: WinUAE cputest full suite | — | Pass/fail per opcode group |

---

## Dependency Notes

- Phase 65 is independent — no new infrastructure, just decode widening
- Phase 66 is independent — depends only on existing mem-read path
- Phase 67 needs a `move_mm_run_r` FSM (new, ~30 lines); otherwise independent
- Phase 68 CAS depends on Phase 47 BIU machinery (already done); BCD memory depends on Phase 61 -(An) FSM
- Phase 69 is purely decode/EA widening — all infrastructure exists; can partly parallel Phase 68
- Checkpoint γ requires Phases 65–69 all complete

---

## Key Compile Command

```bash
cd /Users/malcolm/MH030
make test        # compile and run all 42 tests; should report "42 passed, 0 failed"
make run TEST=seq58   # compile and run a single testbench
```

Individual testbench compilation follows the pattern:
```bash
iverilog -g2012 -I rtl -o sim/seqNN \
  rtl/eu_regfile.sv rtl/eu_alu.sv rtl/eu_shifter.sv rtl/eu_mul_div.sv \
  rtl/eu_bcd.sv rtl/eu_bitops.sv rtl/eu_agu.sv rtl/eu_seq.sv rtl/m68030_eu.sv \
  tb/seqNN_tb.sv
vvp sim/seqNN
```

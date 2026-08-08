# MC68030 Instruction Gap Coverage Plan

Generated 2026-07-06 from the post-Phase-55 instruction coverage audit.
All Phases 23–55 are complete (33/33 tests pass). This plan covers the
remaining gaps before Checkpoint γ (WinUAE cputest full replay).

---

## Gap Summary

| Priority | Item | Blocking γ? |
|---|---|---|
| Critical | RTE, MOVE SR/CCR/USP, STOP, TRAP, TRAPV, ILLEGAL | Yes |
| Critical | ADDA/SUBA, CMPA, ORI/ANDI/EORI→SR/CCR | Yes |
| Medium | MULS.L/MULU.L/DIVS.L/DIVU.L decode | Yes |
| Medium | PEA, EXG, RTD, CMPM | Soft |
| Medium | Memory-EA ALU (ADD/SUB/AND/OR/EOR/ADDQ/imm-ops to mem) | Yes |
| Medium | ADDX/SUBX -(An) form + X-flag correctness | Soft |
| Lower | Bit-field (BFCHG/BFCLR/BFEXTS/BFEXTU/BFFFO/BFINS/BFTST/BFSET) | No |
| Lower | PACK/UNPK, LINK.L, RESET | No |

---

## Phase 56 — OS control: RTE, MOVE SR/CCR/USP, STOP, TRAP, TRAPV, ILLEGAL

**Why first**: These are prerequisites for any OS-level code. RTE is the return
path from every exception handler. MOVE SR/CCR is used by every interrupt
prologue. TRAP is the syscall mechanism. Without these, Checkpoint γ cannot
exercise a single interrupt-driven test case.

All decode from Group 4 (`f_grp == 4'h4`) or existing exception paths already
wired in `m68030_exc.sv`.

### RTE (0x4E73)
- Pop SR from (A7)+, then pop PC from (A7)+: two sequential memory reads
- For format $0: 6 bytes total (SR word + PC longword); validate format field == 0
- For longer formats: eu_seq detects format field > 0 and passes frame type to
  `m68030_exc` for the full pop sequence (already handles frame push; now needs
  pop mirror)
- Sets supervisor vs. user mode from the restored SR

### MOVE SR,Dn (0x40C0+Dn)
- SR → Dn (zero-extended to 32 bits); supervisor privilege required
- Opcode: Group 4, f_ss=00, f_mode=000, f_reg=Dn; decode as `4'h4, 2'b00, 3'b000, reg`

### MOVE Dn,SR (0x46C0+Dn)
- Dn[15:0] → SR; supervisor only; may change interrupt mask level
- After write: re-evaluate interrupt priority (eu_seq must pulse `sr_changed` to `m68030_exc`)

### MOVE Dn,CCR (0x44C0+Dn)
- Dn[7:0] → CCR (SR[7:0]); user mode allowed
- Only CCR bits (X N Z V C) updated; upper SR byte unchanged

### MOVE CCR,Dn (0x42C0+Dn)
- CCR → Dn (zero-extended); user mode allowed

### MOVE USP,An / MOVE An,USP (0x4E60–0x4E6F)
- Supervisor only; accesses eu_regfile USP
- 0x4E60+An: An → USP; 0x4E68+An: USP → An

### STOP #imm (0x4E72 + imm16)
- SR ← imm; BIU must halt issuing new fetch requests until interrupt arrives
- eu_seq asserts `eu_stop` output; BIU treats this like HALT (no AS)
- Resume when interrupt level > SR[10:8]

### TRAP #n (0x4E40–0x4E4F)
- n = opcode[3:0]; vector = VBR + (32 + n)*4
- Push format-$0 frame: SR, PC; load vector; branch
- Route through m68030_exc existing format-$0 push path

### TRAPV (0x4E76)
- If V set: push format-$0 frame + take vector 7; else NOP

### ILLEGAL (0x4AFC)
- Push format-$0 frame; take vector 4 (illegal instruction exception)

**Files**: `rtl/eu_seq.sv`, `rtl/m68030_exc.sv`, `rtl/m68030_top.sv` (eu_stop wire),
`tb/seq56_tb.sv`

**New tests**: TRAP#0 takes vector; RTE restores SR+PC; MOVE D0,SR then MOVE SR,D1
round-trips; STOP resumes on synthesized interrupt; TRAPV fires on V=1, skips on V=0.

---

## Phase 57 — ADDA/SUBA/CMPA + ORI/ANDI/EORI to SR/CCR

**Why second**: Virtually every pointer manipulation uses ADDA. All C-compiled
stack frame setup (LINK done, but stack pointer arithmetic in subroutine bodies)
uses ADDA/SUBA. CMPA is used in every bounds check on a pointer.

### ADDA (Group D, f_ss=11)
```
f_grp = 4'hD, f_ss = 2'b11, f_mode = f_mode, f_reg = An_dst
```
- EA sourced (any mode); sign-extend to 32 bits if ADDA.W (f_dir=0), use full 32
  bits if ADDA.L (f_dir=1); An ← An + src; **CCR not affected**

### SUBA (Group 9, f_ss=11)
- Mirror of ADDA: An ← An - src; CCR not affected

### CMPA (Group B, f_ss=11)
- Compare An with EA (sign-extended if .W); set CCR; no writeback; An unchanged

### ORI/ANDI/EORI #imm,CCR (0x003C, 0x023C, 0x0A3C)
- Decode: f_grp=0, f_mode=001/010, f_reg=111 with ext_reg=100
- Immediate byte modifies CCR field of SR only; upper byte preserved

### ORI/ANDI/EORI #imm,SR (0x007C, 0x027C, 0x0A7C)
- Decode: f_grp=0, f_mode=001/010, f_reg=111 with ext_reg=100, size=1
- Supervisor only; full SR modified; re-evaluate interrupt priority after write

**Files**: `rtl/eu_seq.sv`, `tb/seq57_tb.sv`

**New tests**: ADDA.L D0,A0 pointer offset; CMPA.L #n,A0 with correct CCR; SUBA.W
D1,A1 sign extension; ORI #0x0F,CCR sets low nibble; ANDI #0xFFFE,SR clears C.

---

## Phase 58 — Long multiply/divide decode

**Why here**: The functional units are already complete in `eu_mul_div.sv` — only
`eu_seq.sv` decode is missing. These are among the easiest wins in the plan.
32-bit multiply and divide appear in almost all integer math in compiled C code.

### MULS.L / MULU.L (0x4C00–0x4C3F)
```
Opcode: 4'h4, 2'b11, 6'b000_xxx
Extension word: [15]=0 (32-bit result), [10:8]=Dh (high), [2:0]=Dl (low)
                [11]=signed/unsigned, [6]=64-bit/32-bit result select
```
- 32×32→32 (Dl only) or 32×32→64 (Dh:Dl) product
- Route to existing `eu_mul_div` with `op_long=1` and `op_64=ext[11]`
- 64-bit result: Dh ← product[63:32], Dl ← product[31:0]

### DIVS.L / DIVU.L (0x4C40–0x4C7F)
```
Opcode: 4'h4, 2'b11, 6'b001_xxx
Extension word same encoding; Dr=Dh (remainder), Dq=Dl (quotient)
```
- 64÷32→32q:32r; route to existing divider with `op_long=1`
- Overflow flag set if quotient does not fit in 32 bits

**Files**: `rtl/eu_seq.sv`, `tb/seq58_tb.sv`

**New tests**: MULS.L D0,D1 (32-bit result); MULU.L D0,D2:D1 (64-bit result);
DIVS.L D1,D2:D0 quotient+remainder; divide-by-zero exception.

---

## Phase 59 — PEA, EXG, RTD, CMPM

These are independent; they share a phase because each is small.

### PEA ea (0x4840–0x487F)
- Compute EA (control mode only; no Dn/An/immediate); push it as a longword to -(A7)
- Reuses existing eu_agu EA calculation; result goes to mem_wdata, not a register
- Decode: f_grp=4, f_ss=10, f_mode≠0 (must be control mode)

### EXG (Group C, dir=1)
```
EXG Dx,Dy:  0xC140 + (Dx<<9) + Dy   (f_ss=01, f_mode=000)
EXG Ax,Ay:  0xC148 + (Ax<<9) + Ay   (f_ss=01, f_mode=001)
EXG Dx,Ay:  0xC188 + (Dx<<9) + Ay   (f_ss=10, f_mode=001)
```
- No memory access; pure register swap via two eu_regfile write ports in same cycle

### RTD #d16 (0x4E74 + d16)
- PC ← M[(A7)]; A7 += 4 + sign_ext(d16)
- One memory read (same as RTS), then An writeback with additional displacement

### CMPM (An)+,(An)+ (Group B, f_ss≠11, f_dir=1)
```
0xB108 + (Ay<<0) + (Ax<<9)  for .B
0xB148 for .W; 0xB188 for .L
```
- Read (Ay)+; read (Ax)+; compare; set CCR; both An postincrement

**Files**: `rtl/eu_seq.sv`, `tb/seq59_tb.sv`

**New tests**: PEA (d16,PC) pushes correct address; EXG D3,A5 swaps values; RTD #8
leaves SP advanced by 12; CMPM (A0)+,(A1)+ sets Z on equal strings.

---

## Phase 60 — Memory-EA ALU operations

**Why here**: This is the largest single coverage gap. Every line of compiled C
that does `ADD.L D0,(A1)` or `ADDQ.L #1,address` hits these paths. Without
memory-destination ALU operations, Checkpoint γ will miss ~30% of opcode variants.

### ADD/SUB ea,Dn (memory source, d=0)
```
Group D/9; f_ss != 11; f_dir=0; f_mode != 000
```
- Read EA from memory; ALU op with Dn; write result back to Dn
- Currently only Dn,Dn (mode=000) works; extend to all EA modes

### ADD/SUB Dn,ea (memory destination, d=1)
```
Group D/9; f_ss != 11; f_dir=1; f_mode != 000, 001
```
- Read EA from memory into temp; ALU op with Dn; write result back to EA
- Requires read-modify-write sequence: mem_read stall, ALU, mem_write stall

### AND/OR/EOR ea,Dn and Dn,ea (Groups C/8/B)
- Same pattern; both source and destination memory forms

### ADDQ/SUBQ to memory (Group 5, f_dir=0/1, f_mode != 000/001)
- imm3 already decoded; extend destination from Dn-only to memory EA
- Also: ADDQ/SUBQ to An (ADDQ to An doesn't affect CCR)

### ORI/ANDI/SUBI/ADDI/EORI/CMPI to memory EA (Group 0)
- Currently only Dn destination works (f_mode=000)
- Extend: if f_mode != 000/001, EA is a memory address → RMW cycle

### Scc to memory (Group 5, f_dir=1)
- Decode f_mode != 000; write 0x00 or 0xFF to memory EA

### BTST/BCHG/BCLR/BSET to memory (Groups 0 and 4)
```
#n,ea  (Group 0, f_grp=0, bit 8=1)
Dn,ea  (Group 0, f_grp=0, bit 8=0)
```
- Memory destination: operate on byte at EA; bit number mod 8
- Already works for Dn destination (mode=000); extend to memory

### Shift/rotate memory word form (Group E, f_ss=11 excluded; f_mode=3'b011)
```
ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR  ea
Encoding: 0xE0C0 + (dir<<8) + (type<<9) + ea_mode + ea_reg
```
- One-bit shift only; memory word; no count field
- Currently shifts work only on Dn; memory form is the f_mode check that currently
  falls through

### CLR/TST/NEG/NEGX/NOT to memory
- These may already work if eu_seq issues mem_rd + mem_wr for mode != 000;
  verify and fix any that fall through

**Implementation note**: All memory-destination forms need the read-before-write
stall sequence already used by Phase 37 (An)/(An)+/-(An). The main change is
extending the EA decode mux in `eu_seq` to accept f_mode != 000/001 for these
instruction groups.

**Files**: `rtl/eu_seq.sv`, `tb/seq60_tb.sv`

**New tests**: ADD.L D0,(A1); ADDI.L #1,(A2); BSET #3,(A3); Scc (A4) on Z=1;
ASL.W (A5) shifts memory word by one; ADDQ.L #4,A6 doesn't affect CCR.

---

## Phase 61 — ADDX/SUBX -(An),-(An) + X-flag correctness

**Why separate**: The -(An) form of ADDX/SUBX requires two predecrement memory
reads plus a predecrement memory write — a 3-bus-cycle sequence more complex than
Phase 60. The X-flag issue also affects the existing Dn,Dn form.

### X-flag fix (Dn form, already decoded)
- The existing ADDX/SUBX decode in eu_seq maps to the ADD/SUB path but does not
  pass `use_x=1` to eu_alu. eu_alu has the ADDX/SUBX functional path; wire `x_flag`
  through when the instruction is ADDX/SUBX.

### ADDX/SUBX -(Ay),-(Ax) (f_dir=0, f_mode=001 encoding in Groups D/9)
```
f_grp=D/9; f_ss=00/01/10; opcode[3]=1; opcode[8]=1
```
- Predecrement Ay → read byte/word/long; predecrement Ax → read byte/word/long
- ALU ADDX/SUBX with X flag; write result back to Ax (predecrement already done)
- Three memory operations: 2 reads, 1 write, serialised in eu_seq FSM

**Files**: `rtl/eu_seq.sv`, `rtl/eu_alu.sv` (check X-flag path), `tb/seq61_tb.sv`

---

## Phase 62 — Bit-field instructions

The entire `BFXXX` block (Group E, f_ss=11) is currently skipped by an `if (f_ss
!= 2'b11)` guard. These are 68020/030 extensions; real-world code uses them
mainly in graphics and packed data. Not strictly needed for cputest basic, but
required for the full suite.

| Opcode | Operation |
|--------|-----------|
| BFTST ea,{offset:width} | test field; set N/Z |
| BFCHG ea,{offset:width} | complement field |
| BFCLR ea,{offset:width} | clear field |
| BFSET ea,{offset:width} | set field |
| BFEXTU ea,{offset:width},Dn | unsigned extract |
| BFEXTS ea,{offset:width},Dn | signed extract |
| BFINS Dn,ea,{offset:width} | insert field |
| BFFFO ea,{offset:width},Dn | find first one |

Extension word: `[14:6]` = offset, `[5]` = Do (offset is Dn), `[4:0]` = width,
`[11]` = Dw (width is Dn). Offset and width can each be a register or immediate.

Field may cross up to 5 bytes; requires byte-level memory access with masking.

**Implementation approach**: Add a `eu_bitfield` submodule (similar to eu_bitops)
that accepts (base_addr, offset, width, src_data) and returns extracted/modified
bytes. eu_seq handles the 1–5 byte read-modify-write bus sequence.

**Files**: `rtl/eu_bitfield.sv` (new), `rtl/eu_seq.sv`, `rtl/m68030_eu.sv`,
`tb/seq62_tb.sv`

---

## Phase 63 — PACK/UNPK, LINK.L, RESET

These are independent and low-impact on Checkpoint γ.

### PACK Dy,Dx,#adj / PACK -(Ay),-(Ax),#adj (Group 8, f_dir=1, f_ss=01)
- Take 16-bit BCD unpacked value + adj; pack to 8-bit BCD
- Two forms: Dn operands or -(An) memory operands

### UNPK Dy,Dx,#adj / UNPK -(Ay),-(Ax),#adj (Group 8, f_dir=1, f_ss=10)
- Take 8-bit packed BCD + adj; unpack to 16-bit representation
- CCR not affected by either

### LINK.L An,#d32 (68020+; 0x4808–0x480F + d32)
- Long-displacement form: same as LINK.W but extension is two words (d32)
- Only difference from Phase 39 LINK.W is reading 2 extension words for displacement

### RESET (0x4E70)
- Supervisor only; asserts external RESET pin for 512 clock periods; CPU continues
- In eu_seq: assert `eu_reset_out` pulse; route to BIU via `m68030_top`; BIU
  manages the 512-cycle assertion (biu_config already has RSTOUT infrastructure)

**Files**: `rtl/eu_seq.sv`, `rtl/m68030_top.sv`, `tb/seq63_tb.sv`

---

## Phase 64 — MOVES full EA + PMOVE CRP/SRP (64-bit)

### MOVES remaining EA modes (Phase 46 partial gap)
MOVES currently supports (An)/(An)+/-(An). Extend to:
- (d16,An), (d8,An,Xn), (xxx).W, (xxx).L — same alternate-FC BIU path

### PMOVE CRP/SRP (64-bit registers)
PMOVE for TC/TT0/TT1/MMUSR (32-bit) is done. CRP and SRP are 64-bit:
- Two consecutive longword bus cycles (address, then address+4)
- eu_seq must issue two memory operations and route both halves to m68030_mmu

**Files**: `rtl/eu_seq.sv`, `rtl/m68030_mmu.sv`, `tb/seq64_tb.sv`

---

## Verification Checkpoints

### Checkpoint γ readiness

After Phase 61 (all critical + medium gaps closed), run the WinUAE `.dat` replay
against the cputest `basic` suite. Target: ≥95% pass rate per opcode group.
Expected remaining failures: bit-field (Phases 62–63 not done), PACK/UNPK.

After Phase 64, run the cputest `all` suite. Target: <10 failures per opcode
group excluding FPU (Phase 52 stub only) and user/supervisor boundary edge cases.

---

## Execution Order Summary

| Phase | Content | Why this order |
|-------|---------|----------------|
| **56** | RTE, MOVE SR/CCR/USP, STOP, TRAP/TRAPV, ILLEGAL | OS fundamentals; unblocks interrupt testing |
| **57** | ADDA/SUBA/CMPA, ORI/ANDI/EORI→SR/CCR | Pointer arithmetic; almost universal |
| **58** | MULS.L/MULU.L/DIVS.L/DIVU.L decode | Easiest win; units already exist |
| **59** | PEA, EXG, RTD, CMPM | Small independent ops |
| **60** | Memory-EA ALU (ADD/SUB/AND/OR/EOR/ADDQ/imm/Scc/bits/shifts to mem) | Largest coverage gap |
| **61** | ADDX/SUBX -(An) + X-flag fix | Correct extended arithmetic |
| **62** | Bit-field (BFXXX) | Full cputest all suite |
| **63** | PACK/UNPK, LINK.L, RESET | Completeness |
| **64** | MOVES full EA, PMOVE CRP/SRP | Final wiring cleanup |
| **γ** | WinUAE cputest basic → all | Pass/fail per opcode group |

---

## Dependency Notes

- Phase 56 depends on m68030_exc push path (done in Phase 32) — RTE uses its mirror
- Phase 57 (ADDA/SUBA) is independent of Phase 56
- Phase 58 is independent of both 56 and 57
- Phase 60 (memory ALU) depends on the EA stall infrastructure from Phase 37 (done);
  the RMW sequence for memory-destination ops already exists for MOVES/TAS
- Phase 61 X-flag fix should be done before Checkpoint γ to avoid false passes on
  extended-precision math tests
- Phase 62 (bit-field) can be deferred past γ basic; needed only for γ all suite
- Phases 63–64 are completeness items; do not block either γ checkpoint

## Files Touched Per Phase

| Phase | Primary | Secondary |
|-------|---------|-----------|
| 56 | rtl/eu_seq.sv | rtl/m68030_exc.sv, rtl/m68030_top.sv, tb/seq56_tb.sv |
| 57 | rtl/eu_seq.sv | tb/seq57_tb.sv |
| 58 | rtl/eu_seq.sv | tb/seq58_tb.sv |
| 59 | rtl/eu_seq.sv | tb/seq59_tb.sv |
| 60 | rtl/eu_seq.sv | tb/seq60_tb.sv |
| 61 | rtl/eu_seq.sv, rtl/eu_alu.sv | tb/seq61_tb.sv |
| 62 | rtl/eu_bitfield.sv (new), rtl/eu_seq.sv, rtl/m68030_eu.sv | tb/seq62_tb.sv |
| 63 | rtl/eu_seq.sv | rtl/m68030_top.sv, tb/seq63_tb.sv |
| 64 | rtl/eu_seq.sv, rtl/m68030_mmu.sv | tb/seq64_tb.sv |

---

## Phase 80 — BCHG/BCLR/BSET regression fix, CHK CCR fix, TAS/CLR/NEG/NOT/NEGX/TST EA-mode extension

**Goal**: Rebuild and retest the Phase 79 BCHG/BCLR/BSET fix, then investigate the
CLR.b/TAS/CHK failures flagged "under investigation" at the end of Phase 79.

### Bug 1 (regression) — Phase 79's BCHG/BCLR/BSET "fix" double-fired CCR

Retesting the Phase 79 commit showed BCHG at only **58.1%** — worse than the ~92%
baseline the fix was meant to improve. Root cause: memory-RMW BCHG/BCLR/BSET already
update CCR correctly via the `mem_rmw_sr_wr_en` path — captured combinationally at
`mem_rmw_read_ack` into `mem_rmw_ccr_r`, gated by `mem_rmw_ccr_en_r <= ex_mem_rmw_ccr`,
which fires **unconditionally** for any non-UNIT_MOVE RMW op regardless of
`dec_updates_ccr`. This is the documented convention (see the "CCR fires via
mem_rmw_sr_wr_en, not WB" comments already present at several other RMW blocks in
eu_seq.sv).

Phase 79 set `dec_updates_ccr=1` for the BCHG/BCLR/BSET memory-RMW forms (both
register-src and #imm-src blocks), which was redundant with the always-on mem_rmw
path — and worse, actively wrong: `ex_mem_stall` deasserts for exactly one cycle
during `mem_rmw_after_r` (the cycle after the write ack), and since the EX-stage
pipeline register still holds the same BCHG instruction, `wb_updates_ccr` fires a
**second**, later CCR write using `ex_z = bit_z` recomputed from `bit_dst = mem_rdata`
— which by that cycle no longer holds the read-phase data. The first (correct) write
from `mem_rmw_sr_wr_en` gets clobbered one cycle later by the second (stale) write from
WB. The observed symptom matched exactly: Z was spuriously set to 1 across nearly all
failing vectors.

**Fix**: restore `dec_updates_ccr=1'b0` for the CHG/CLR/SET cases in both memory-RMW
decode blocks (`rtl/eu_seq.sv`, register-src block ~line 1092 and #imm block ~line
1179), leaving BTST (which is not RMW and has no mem_rmw path) at `dec_updates_ccr=1`.

**Result**: BCHG 58.1%→92.8%, BCLR →93.4%, BSET →98.2%. All remaining failures are
exclusively `(d8,An,Xn)` indexed-dst — the documented register-file arch gap.

### Bug 2 — CHK Z/N flag semantics wrong (17.8%→64.3%, zero logic mismatches left)

`rtl/eu_seq.sv`'s CHK CCR mux had it backwards from real hardware / Musashi
(`tools/musashi/m68kops.c: m68k_op_chk_16_d` etc.):
- **Z** must be `(tested_value == 0)`, computed **unconditionally** every CHK. The RTL
  left `ex_z = flag_z` (i.e. never updated it — carried over whatever CCR Z already was).
- **N** must be `(tested_value < 0)` **only when CHK actually traps** (value below zero
  or above the upper bound); if the value is in range (no trap), N is **left unchanged**
  (Musashi's early-return path never touches `FLAG_N`). The RTL set
  `ex_n = chk_below_w` unconditionally, forcing N=0 on every non-trapping in-range CHK
  even when the previous instruction had left N=1.
- Also fixed: CHK.W compared the **full 32-bit** `rd_b_data`/bound against each other
  without sign-extending from the low 16 bits first, so garbage in the upper 16 bits of
  either operand corrupted the signed "above bound" comparison (Musashi:
  `sint src = MAKE_INT_16(DX)`). Added `chk_val_ext_w`/`chk_ub_ext_w` sign-extension and
  fixed `chk_mem_ub_w` to sign- rather than zero-extend the memory-sourced bound.

**Result**: CHK 17.8%→64.3%. Every remaining failure is a TIMEOUT from an unimplemented
EA mode (`(An)+`, `-(An)`, `(d8,An,Xn)`, abs.L, `(d16,PC)`) — zero CCR/logic mismatches
on any mode that does decode.

### Bug 3 (missing feature, not a logic bug) — TAS/CLR/NEG/NOT/NEGX/TST only supported 3 of 7 alterable EA modes

TAS and the NEGX/CLR/NEG/NOT/TST shared memory-EA decode block in `eu_seq.sv` only
recognized `(An)`/`(An)+`/`-(An)`. `(d16,An)`, `(xxx).W`, and `(xxx).L` don't need a 3rd
register-file read port (unlike `(d8,An,Xn)`, which is the real arch gap) and were
straightforward to add, following the same pattern already used by NBCD's abs.W/L
support. TST additionally got `(d16,PC)` since it's read-only (not a valid destination
for the RMW forms). Each addition required a matching `ext_count` entry in
`m68030_seq.sv` (`rtl/m68030_seq.sv`'s per-instruction extension-word-count table) so
the IFU prefetch queue drains the right number of extension words — the eu_seq.sv EA
decode and the m68030_seq.sv ext_count table must agree or the pipeline desyncs.

**Result**: TAS 69.4%→87.2%, CLR.b 64.1%→83.8%, NEG.w 89.3% (spot check), TST.b
83.6% (spot check, `(d16,PC)` included). All remaining failures across all six
instructions are exclusively `(d8,An,Xn)` — the same register-file arch gap. NEGX/NOT/
CLR.w/l/NEG.b/l/TST.w/l share the identical decode block and should follow the same
pattern but were not individually swept this phase (time-boxed).

**Verification**: `make test` (32/32) and `make cosim_grp` (all 8 groups match Musashi
bus traces) both still pass after all three fixes.

---

## Phase 79 — Tom Harte SingleStepTests Full Sweep

**Goal**: Run every available Harte instruction suite against the DUT, fix wrong-result failures, and document TIMEOUTs (which indicate either the architectural gap or an unhandled decode path).

The Harte test vectors are 68000 one-instruction tests stored in `tests/harte/*.json.gz`. Each test sets up initial register + memory state, executes one instruction, and checks final register + memory state. Run with `python3 -u scripts/run_harte.py tests/harte/INSTR.json.gz`.

**IMPORTANT — rebuild sim before testing**: After any RTL change run `make sim/harte_dat` to recompile the Harte testbench binary. It is NOT rebuilt by `make test`.

### Harte Results Table (as of Phase 79)

| Suite | Non-skip | Pass | Fail | Timeout | Pass% | Status |
|-------|----------|------|------|---------|-------|--------|
| ADD.b | 2461 | 2461 | 0 | 0 | 100% | ✅ done Phase 78 |
| ADD.w | 1461 | 1461 | 0 | 0 | 100% | ✅ done Phase 78 |
| ADD.l | 1490 | 1490 | 0 | 0 | 100% | ✅ done Phase 78 |
| SUB.b | 8064 | 8064 | 0 | 0 | 100% | ✅ |
| SUB.w | 5000 | 5000 | 0 | 0 | 100% | ✅ |
| SUB.l | 4992 | 4992 | 0 | 0 | 100% | ✅ |
| AND.b | 8064 | 8064 | 0 | 0 | 100% | ✅ |
| AND.w | 4554 | 4554 | 0 | 0 | 100% | ✅ |
| AND.l | 4616 | 4616 | 0 | 0 | 100% | ✅ |
| OR.b | 8064 | 8064 | 0 | 0 | 100% | ✅ |
| OR.w | 4523 | 4523 | 0 | 0 | 100% | ✅ |
| OR.l | 4596 | 4596 | 0 | 0 | 100% | ✅ |
| EOR.b | 8065 | 8065 | 0 | 0 | 100% | ✅ |
| EOR.w | 4831 | 4831 | 0 | 0 | 100% | ✅ |
| EOR.l | 4797 | 4797 | 0 | 0 | 100% | ✅ |
| CMP.b | 8064 | 8064 | 0 | 0 | 100% | ✅ |
| CMP.w | 4921 | 4921 | 0 | 0 | 100% | ✅ |
| CMP.l | 4944 | 4944 | 0 | 0 | 100% | ✅ |
| MOVE.b | 5920 | 5375 | 545 | 545 | 90.8% | ⚠ TIMEOUT=FAIL (arch gap) |
| MOVE.w | 3239 | 3044 | 195 | 195 | 94.0% | ⚠ TIMEOUT=FAIL (arch gap) |
| MOVE.l | 3156 | 2954 | 202 | 202 | 93.6% | ⚠ TIMEOUT=FAIL (arch gap) |
| MOVEQ | 6089 | 6085 | 4 | 4 | 99.9% | ⚠ 4 TIMEOUTs (investigate) |
| MOVEA.w | TBD | — | — | — | — | sweep pending |
| MOVEA.l | TBD | — | — | — | — | sweep pending |
| MOVEM.w | TBD | — | — | — | — | sweep pending |
| MOVEM.l | TBD | — | — | — | — | sweep pending |
| MOVEP.w | TBD | — | — | — | — | sweep pending |
| MOVEP.l | TBD | — | — | — | — | sweep pending |
| MOVEfromSR | TBD | — | — | — | — | sweep pending |
| MOVEfromUSP | 4027 | 4027 | 0 | 0 | 100% | ✅ |
| MOVEtoUSP | 4494 | 4494 | 0 | 0 | 100% | ✅ |
| BCHG | 5867 | 5446 | 421 | 0 | 92.8% | ✅ Phase 80 fix; remaining = indexed-dst arch gap |
| BCLR | 5851 | 5467 | 384 | 0 | 93.4% | ✅ Phase 80 fix; remaining = indexed-dst arch gap |
| BSET | 6019 | 5912 | 107 | 0 | 98.2% | ✅ Phase 80 fix; remaining = indexed-dst arch gap |
| BTST | TBD | — | — | — | — | retest pending (not affected by Phase 80 fix) |
| CLR.b | 8062 | 6756 | 1306 | 1306 | 83.8% | ✅ Phase 80 EA-mode fix; remaining = indexed-dst arch gap |
| CLR.w | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| CLR.l | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| NEG.b/l | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| NEG.w | 4789 | 4278 | 511 | 511 | 89.3% | ✅ Phase 80 EA-mode fix; remaining = indexed-dst arch gap |
| NEGX.b/w/l | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| NOT.b/w/l | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| TST.b | 8064 | 6740 | 1324 | 1324 | 83.6% | ✅ Phase 80 EA-mode fix (+ (d16,PC)); remaining = indexed-dst arch gap |
| TST.w/l | TBD | — | — | — | — | same fix applies (shared decode block); sweep pending |
| ASL.b | 8065 | 8063 | 2 | 0 | 100% | ✅ (~100%, 2 non-TIMEOUT fails TBD) |
| ASL.w | 5799 | 5411 | 388 | 388 | 93.3% | ⚠ TIMEOUT=FAIL (shift-mem arch gap?) |
| ASL.l/ASR/LSL/LSR | TBD | — | — | — | — | sweep pending |
| ROL/ROR/ROXL/ROXR | TBD | — | — | — | — | sweep pending |
| TAS | 4920 | 4290 | 630 | 630 | 87.2% | ✅ Phase 80 EA-mode fix; remaining = indexed-dst arch gap |
| CHK | 652 | 419 | 233 | 233 | 64.3% | ✅ Phase 80 CCR fix; remaining = unimplemented EA modes (TIMEOUT only, no logic fails) |
| Scc | TBD | — | — | — | — | sweep pending |
| ADDA.w/l | TBD | — | — | — | — | sweep pending |
| SUBA.w/l | TBD | — | — | — | — | sweep pending |
| CMPA.w/l | TBD | — | — | — | — | sweep pending |
| ADDX/SUBX | TBD | — | — | — | — | sweep pending |
| ABCD/SBCD/NBCD | TBD | — | — | — | — | sweep pending |
| ASL/ASR/LSL/LSR/ROL/ROR/ROXL/ROXR b/w/l | TBD | — | — | — | — | sweep pending |
| ANDItoCCR/SR | TBD | — | — | — | — | sweep pending |
| ORItoCCR/SR | TBD | — | — | — | — | sweep pending |
| EORItoCCR/SR | TBD | — | — | — | — | sweep pending |
| MOVEtoCCR/SR | TBD | — | — | — | — | sweep pending |
| MULS/MULU | TBD | — | — | — | — | sweep pending |
| DIVS/DIVU | TBD | — | — | — | — | sweep pending |
| LEA/PEA | TBD | — | — | — | — | sweep pending |
| LINK/UNLINK | TBD | — | — | — | — | sweep pending |
| JSR/JMP/RTS/BSR | TBD | — | — | — | — | sweep pending |
| Bcc/DBcc | TBD | — | — | — | — | sweep pending |
| EXG/SWAP | TBD | — | — | — | — | sweep pending |
| EXT/NOP | TBD | — | — | — | — | sweep pending |
| TRAP/RTE/RTR | — | — | — | — | — | all SKIP (supervisor state) |
| TRAPV | 1981 | 1981 | 0 | 0 | 100% | ✅ |

### Architectural Gap — Indexed Destination Register Conflict

**Root cause**: The EU register file has **2 read ports**. Instructions with an indexed destination EA `(d8,An,Xn)` require reading up to 3 registers in the same cycle:
- `rd_a` = source data register (e.g., Dn for MOVE Dn,(d8,An,Xn))  
- `rd_b` = dst_An (EA base address)
- implicit = dst_Xn (EA index)

The 2-port file cannot supply all three simultaneously, so the DUT stalls waiting for register data that never arrives → TIMEOUT.

**Affected instructions** (any that write to `(d8,An,Xn)` with a separate src register):
- MOVE.b/w/l src,(d8,An,Xn) — all three MOVE sizes
- CLR/NEG/NOT/TST/NEGX (d8,An,Xn) — likely share this issue
- ASL/ASR/LSL/LSR/ROL/ROR memory word forms → (d8,An,Xn)
- TAS (d8,An,Xn)
- BCHG/BCLR/BSET Dn,(d8,An,Xn)

**Scale**: ~9% of MOVE tests; varies by instruction. Affects all sizes.

**Fix**: Requires adding a 3rd read port to `eu_regfile` and plumbing it through `eu_seq`. Complex architectural change; deferred.

**Workaround for testing**: These tests are counted as TIMEOUT and excluded from pass-rate denominator. The pass rate reported above is PASS/(PASS+non-TIMEOUT-FAIL).

### RTL Bugs Fixed in Phase 79

**Fix A — MOVE An,(dst) CCR suppressed (eu_seq.sv)**
- Location: indirect-dst MOVE block (line ~1707) and abs-dst MOVE block (line ~2087)
- Bug: `dec_updates_ccr = (f_mode == 3'b000)` — only Dn source updated CCR; An source (f_mode=1) silently left CCR unchanged
- 68000 spec: MOVE (not MOVEA) always updates N/Z/V/C regardless of source type
- Fix: `dec_updates_ccr = 1'b1` in both blocks
- Impact: MOVE.w 82.3%→94.0%, MOVE.l 82.3%→93.6%

**Fix B — BCHG/BCLR/BSET CCR Z-flag suppressed (eu_seq.sv)**
- Location 1: register-src memory bit-op case (lines 1092–1094)
  - Bug: `dec_updates_ccr=1'b0` explicitly overrode the block-level `=1'b1` set at line 995
- Location 2: #imm-src memory BCHG/BCLR/BSET (lines 1176–1178)
  - Bug: no `dec_updates_ccr` set (defaulted to 0); only BTST had it
- 68000 spec: BTST/BCHG/BCLR/BSET all set Z based on original bit value
- Fix: remove `dec_updates_ccr=1'b0` overrides; add `dec_updates_ccr=1'b1` to #imm BCHG/BCLR/BSET
- Impact: expected BCHG/BCLR/BSET 92–93%→~100% (retest pending)

---

## Phase 78 — mustest Suite Debug (39/60 → target 60/60)

Current state: 39/60 mustest tests pass. 21 tests fail.
Phases 1–77 complete; 51/51 unit + integration tests pass.

### Root-cause analysis (2026-07-21)

**RMW write-data normalization** (fixed, in commit b2537f4):
- `mem_rmw_wdata_r <= ex_result` stored ALU byte result in bits[7:0].
- `biu_byte_lane_ctrl` for siz=01 takes bits[31:24] → d_out was all zeros.
- Fix: normalize at capture: `{ex_result[7:0], 24'h0}` for byte, `{ex_result[15:0], 16'h0}` for word.
- Also normalized ADDX memory write path (`addx_mem_run_r`).
- Result: 26→39/60. Unit test expected values updated in seq60/61/68/69 testbenches.

### Remaining 21 failures — prioritised attack order

#### Priority 1 — Byte read lane routing (est. 7+ tests: btst, bset, bclr, bchg, scc, nbcd, op_cmp_i)

`btst` is **read-only** (no write-back) yet fails. This points at the **read** path, not
the write path. The 68030 bus delivers a byte at addr[1:0]=00 on D[31:24]. The testbench
returns a full 32-bit word; the byte written there is in bits[31:24]. If the EU extracts
bits[7:0] of `biu_rdata` for all byte reads, it reads garbage (DEADBEEF init).

Investigation: look at how `biu_rdata` is consumed in eu_seq when the EU receives a byte
read result. Check whether `biu_byte_lane_ctrl` rotates read data, or whether eu_seq does
addr[1:0]-based extraction.

Fix: ensure that for a byte read the EU operand = `biu_rdata >> (8*(3-addr[1:0]))` so
bits[31:24] for align=00, bits[23:16] for align=01, etc., all arrive in bits[7:0].

This single fix cascades to bset/bclr/bchg (RMW — read is wrong → write result wrong),
scc (cmpi.b reads the byte back), nbcd memory, op_cmp_i memory forms, and partially
to subx/addx/abcd/sbcd.

#### Priority 2 — TRAPV/CHK saved-PC (est. 2 tests: trapv, chk)

Both tests run an exception handler (set register, RTE) and check the register on return.
If the saved PC is the trap instruction itself instead of PC+N (next instruction), RTE
re-executes the trap → infinite loop → timeout.

For the 68030: TRAPV and CHK are post-execution exceptions — they save the PC of the
instruction **following** the faulting instruction. Verify in m68030_exc.sv that
`exc_push_pc` for vector 6 (CHK) and vector 7 (TRAPV) is `trap_pc + instruction_size`,
not `trap_pc`.

#### Priority 3 — -(An) memory ops (est. 4 tests: subx, addx, abcd, sbcd)

SUBX/ADDX -(An) write path was normalized (Fix 2). ABCD/SBCD use a separate `bcds_run_r`
path — check if that path is also normalized. After read-lane fix (Priority 1), re-assess
whether read side was the only remaining problem.

#### Priority 4 — Indexed EA write completeness (est. 2 tests: move, move_xxx_flags)

`move` exercises `(d8,An,Xn)` with `.L`-size index register and non-zero scale.
Decode fix for MOVE #,(d8,An,Xn) was applied but write data is still 0.
`move_xxx_flags` times out — likely the RMW write cycle never fires for this form.

Investigate: does the AGU correctly handle W/L index-size bit[11] in brief ext word?
Is the write path entered at all for indexed-dst MOVE?

#### Priority 5 — MOVEM / MOVEP (2 tests)

MOVEM writes 16 word-size registers sequentially; MOVEP does byte-interleaved writes
to alternating addresses. Both need investigation of the multi-op sequencing.

#### Priority 6 — DIVS / DIVU (2 tests)

Register-only divide with accumulated result/flag check. Likely a divide overflow or
flag-bit bug — isolated from memory issues.

#### Priority 7 — LEA_PEA / LEA_TAS (2 tests)

PEA pushes computed EA to stack (-(sp) write). TAS is byte RMW — likely fixed by
Priority 1 read fix. LEA is address-only, no memory write.

### Commit discipline

Commit and push after every improvement to the pass rate. Each commit message should
include the new pass count (e.g., "mustest 41/60 — byte read lane routing fix").

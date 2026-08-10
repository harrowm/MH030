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

## Phase 84 — Bucket D closed: CHK indexed EA, no port needed

**Goal**: per `port3.md`'s revised Bucket D analysis, try CHK's indexed form
(`CHK (d8,An,Xn),Dn`) using the existing `dyn_bit_get_Dn` deferred-register pattern
before concluding it needs the 3rd register-file port.

**Result: it works. No port needed. This closes the last of the four original
"arch gap" buckets — none of them ever required the register-file port.**

### Implementation

Added `f_mode==3'b110` to CHK's memory-source decode block (`eu_seq.sv` ~2648):
`rd_a=An`, `rd_b=Xn` during the read (via `dec_is_idx`/`dec_xn_wl`/`dec_xn_scale`/
`dec_ea_offset` from the brief extension word), then `dec_is_dyn_bit_idx=1`/
`dec_dyn_bit_reg=f_dn`/`dec_dyn_bit_is_an=0` to swap `rd_b` to `Dn` (the tested
value) at the read-ack cycle — identical mechanism to Bucket B's
AND/OR/EOR/SUB/CMP `Dn,(d8,An,Xn)`. Matching `ext_count=1` entry added to
`m68030_seq.sv`. CHK needed no additional capture-register plumbing (unlike
BCHG/MOVE) because its own WB write-back fires on the exact same cycle as the
read ack — there's no separate write phase to desync from.

### Two bugs found and fixed along the way (both test-harness, zero RTL after the initial decode addition)

Retested immediately after the RTL addition and hit two failures with a "CCR only
wrong, everything else correct" signature — used the same hand-verification
technique as Phases 82/83 (added temporary `$display` tracing to the WB-capture
point) to find:

1. **`chk_traps_w`/`ex_n` computed as `x` (undefined)** — traced to `mem_rdata`
   itself showing `0000xxxx` at the WB-capture cycle. Root cause: `get_scale_remap()`
   in `scripts/gen_harte_hex.py` was misclassifying this CHK instruction as MOVEM.
   `is_movem`'s heuristic (`f_group==4 and f_dn in (4,6) and f_ss>=2`) collides with
   CHK whenever the *tested register* happens to be D4 or D6 at word size — MOVEM's
   `f_dn∈{4,6}` is a fixed direction marker (bits `1,d,0`), but CHK's `f_dn` is the
   tested-register selector (any value 0-7), and the two encodings are
   indistinguishable without checking `f_dir` (0 for MOVEM always, 1 for CHK always).
   Misclassified as MOVEM, the harness computed a garbage `siz_bytes` (18, from a
   bit-count-of-register-mask formula that doesn't apply to CHK) and a wrong bound
   address, so the DUT's *correctly*-computed indexed read address pointed at memory
   the harness never populated — hence the undefined read data. Added `not f_dir` to
   all three occurrences of this condition (`build_patches()`, `get_scale_remap()`,
   `get_operand_ea()`).
2. Verified the fix didn't just move the corruption elsewhere by cross-checking a
   *passing* BCHG indexed vector with the same tracing — confirmed BCHG's `mem_rdata`
   was clean throughout, ruling out a live signal-glitch theory and pointing
   correctly at the test-data-population bug above.

### Results

| Suite | Before | After |
|-------|--------|-------|
| CHK | 64.3% (419/652) | **70.3%** (468/666) |

Zero remaining failures involve `(d8,An,Xn)` (the indexed form this phase targeted)
— every remaining `TIMEOUT` is one of the *other*, still-unimplemented EA modes
(`(An)+`/`-(An)`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)` — a separate, pre-existing gap,
unrelated to the port question, not attempted this phase).

**Verification**: `make test` (32/32) and `make cosim_grp` (8/8 vs Musashi) both pass.

**This is the conclusion of the `port3.md` investigation.** All four original
"arch gap" buckets (A, B, C, D) are now closed. Not one of them needed the
register-file port — Bucket A and most of MOVE were missing decode; Bucket B already
worked; Buckets C and CHK's portion of "D" were test-harness bugs. See `port3.md` for
the final summary; the 3rd-port design is kept in that document for reference but
there is currently no known case that requires it.

---

## Phase 85 — MOVE indexed-source `(d8,An,Xn)`/`(d8,PC,Xn)`: MOVE.b/w/l → 100%

**Goal**: close the last deferred MOVE gap from Phase 82 — indexed-source forms
(`MOVE (d8,An,Xn),dst` and `MOVE (d8,PC,Xn),dst`) combined with an indexed
destination, which needs independent src/dst `Xn`/scale fields since both sides
can now be simultaneously indexed.

### RTL (`eu_seq.sv`)

Extended the existing `dyn_bit_get_Dn` deferred-register-swap mechanism to swap
**both** register-file read ports at once (`dec_dyn_bit_swap_both`), since
indexed-src+indexed-dst MOVE needs `src_An`+`src_Xn` during the read phase and
`dst_An`+`dst_Xn` for the write phase — 4 logical operands through 2 physical
ports, resolved by deferring the write-phase pair until after the read ack
(same shape as every other case in this investigation). Added
`dec_dyn_bit_reg2`/`dec_dyn_bit_is_an2` (second swap target),
`dec_dst_is_idx`/`dec_dst_xn_wl`/`dec_dst_xn_scale` (destination's own indexed
fields, independent of the source's), and updated `rd_a_sel`/`rd_b_sel` muxes
and the `move_mm_dst_addr_r` capture formula accordingly. Two new decode blocks:
`f_mode==3'b110` (indexed src, any dst) and `f_mode==3'b111,f_reg==3'b011`
((d8,PC,Xn) src — dst_An is fixed, no swap needed since PC-relative source
never conflicts with a register operand). No `m68030_seq.sv` change needed —
the existing generic `is_move_mm` ext_count classifier already handled both
new cases.

### Harness bug found (same recurring class, new shape)

Initial retest: MOVE.b 97.9% → 99.2%, but 47 new "no write seen" failures, all
indexed-src + indexed-dst combinations. Hand-verified test index 6527
(`MOVE.b (d8,A1,Xn),(d8,A1,Xn)`, opcode 0x13b1): DUT's write address was
correct (`0xb2f580`, matching an unscaled/scale-×1 destination calculation),
but the test's own expected-write bookkeeping never saw it, because
`get_scale_remap()` in `gen_harte_hex.py` can only ever compute a remap for
**one side** of an instruction — it derives "the" indexed EA from the opcode's
own low-6-bit field (always the *source* for MOVE), so whenever the source is
*also* mode-6, its "destination is indexed" branch (gated by
`not (is_mode6 or is_pc_idx)`) is structurally unreachable. Two independently
scaled sides — a case that never came up until indexed-source MOVE existed.

**Fix**: extracted the destination-remap computation into its own
`_dst_indexed_remap()` helper and call it unconditionally (whenever
`f_group in (1,2,3) and dst_mode==6`), independent of whether the source is
also indexed — added the missing `ea_mode_r==6 → src_ext=1` case to its
extension-word-offset table (source consumes 1 ext word when it's ALSO
indexed, which the original table never needed to express). `get_scale_remap()`
now returns a **list** of 0-2 remaps (source-side, destination-side, both, or
neither) instead of a single dict/`None`. Updated all 4 call sites
(`build_patches()`, `get_operand_ea()` ×2, `can_run()` in `gen_harte_hex.py`;
`compare()` in `run_harte.py`) to iterate the list.

### Results

| Suite | Before | After |
|-------|--------|-------|
| MOVE.b | 99.2% (5873/5920) | **100%** (5922/5922) |
| MOVE.w | (not yet retested post-82) | **100%** (3235/3235) |
| MOVE.l | (not yet retested post-82) | **100%** (3148/3148) |

Zero remaining failures of any kind. **Verification**: `make test` (32/32),
`make cosim_grp` (8/8 vs Musashi).

This is the fourth harness bug found by this investigation, but the first that
wasn't the `f_dir`-disambiguation pattern — it's a genuinely new structural gap
(single-remap assumption) that only surfaced once an instruction with two
independently-indexable operands existed to test it.

---

## Phase 86 — CHK remaining EA modes: `(An)+`/`-(An)`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)` → 100%

**Goal**: close CHK's remaining gap from Phase 84 — every memory-source EA mode
except `(An)`/`(d16,An)`/`(d8,An,Xn)`/`(xxx).W` had never been attempted.

### RTL (`eu_seq.sv`, `m68030_seq.sv`)

Extended CHK's memory-source decode block (`eu_seq.sv` ~2744) to cover all
remaining modes:
- **`(An)+`/`-(An)`** (`f_mode==011/100`): straightforward — `An`→`rd_a`, reuse
  the existing `setup_mem_incdec()` task (already used by the NEGX/CLR/NEG/NOT/
  TST unary block) for the auto-increment/decrement, keyed on CHK's own operand
  size (`dec_siz`, word or long) rather than `f_siz`.
- **`(xxx).L`** (`f_mode==111,f_reg==001`): `dec_abs_ea_val = ext_data` (full
  32-bit absolute), 2 extension words.
- **`(d16,PC)`** (`f_reg==010`): `dec_abs_ea_val = decode_pc+2+sext(d16)` — no
  register operand for the base at all, so `Dn` stays fixed on `rd_b` for the
  whole cycle, no swap mechanism needed.
- **`(d8,PC,Xn)`** (`f_reg==011`): the one non-obvious case. The EX-stage EA
  datapath hardwires the scaled index register to `rd_b`
  (`ex_xn_scaled = ... rd_b_data ...`, `eu_seq.sv` ~6371) regardless of whether
  the base comes from a register or `dec_abs_ea_en`/PC — so `Xn` needs `rd_b`
  during the read phase, colliding with `Dn` also wanting `rd_b` for the
  post-read comparison. Confirmed `dyn_bit_get_Dn`'s swap-at-ack condition
  (`eu_seq.sv` ~6342) depends only on `ex_is_dyn_bit_idx && ex_is_mem_rd` plus
  the read-ack signal — nothing in it assumes a register-relative base — so the
  existing `(d8,An,Xn)` mechanism (`dec_is_dyn_bit_idx`/`dec_dyn_bit_reg=f_dn`/
  `dec_dyn_bit_is_an=0`) works unmodified with `dec_abs_ea_en`+PC-relative
  `dec_abs_ea_val` substituted for `dec_src_reg`=An. `rd_a` is simply unused
  (no An operand exists for this mode).

`m68030_seq.sv`: added a new `ext_count=2` entry for `(xxx).L`, and added
`f_reg==010`/`011` to the existing CHK `ext_count=1` entry. `(An)+`/`-(An)`
need no entry — 0 extension words falls through to the classifier's default.

### Results

| Suite | Before | After |
|-------|--------|-------|
| CHK | 70.3% (468/666) | **100%** (666/666) |

Zero remaining failures of any kind. **Verification**: `make test` (32/32),
`make cosim_grp` (8/8 vs Musashi).

No harness bugs found this phase — first-try correct once the register-port
collision was reasoned through up front instead of discovered via failure.

---

## Phase 87 — Sweep NEGX/NOT/CLR/NEG/TST sizes + shift/rotate families; found + fixed a real ROXL/ROXR CCR bug

**Goal**: confirm the Phase 81 unary-EA decode fix generalizes across the sizes
that weren't individually swept (NEGX.b/w/l, NOT.w/l, CLR.w/l, NEG.b/l,
TST.w/l), and run the full shift/rotate family (ASL/ASR/LSL/LSR/ROL/ROR/
ROXL/ROXR × b/w/l = 24 suites) for the first time.

### Results — first pass

All of NEGX/NOT/CLR/NEG/TST (9 suites) and ASL/ASR/LSL/LSR/ROL/ROR (18 suites)
came back **100%**, except:
- **ASL.b**: 8063/8065 (2 FAIL) — investigated and confirmed to be a **Tom
  Harte test-corpus data anomaly**, not an RTL or harness bug (see below).
- **ROXL.b/w/l and ROXR.b/w/l** (6 suites): consistently ~99.6-99.7% (118
  failures total) — a real, reproducible RTL bug (see below).

### ASL.b: 2 corpus anomalies, not a bug

Both failures are opcode `0xe502` (`ASL.b #2,D2`), which appears 43 times total
in the suite — 41 pass, 2 fail. Hand-verified both failures: the claimed
"expected" final D2 value doesn't match the initial value in its upper 24 bits
at all (impossible for a byte-size op, which must leave them untouched), and no
combination of size/count/direction/rotate-type reproduces the claimed result
from the initial value. Since the *same opcode* with different operand data
passes correctly 41/43 times, the DUT's decode is provably correct; these 2
vectors are simply corrupted in the upstream Tom Harte corpus. Not fixable
(nothing to fix) — documented as a known, harmless 2/8065 corpus artifact.

### ROXL/ROXR: real RTL bug, fixed

All 118 failures were CCR-only mismatches, always the C flag off by exactly
one value, and — critically — every single failing vector used the
**register-count form** (`ROXL Dx,Dy`) with the count register's value ≡ 0
(mod 64). The 68k PRM has one documented exception to "count=0 → flags mostly
unaffected": for ASL/ASR/LSL/LSR/ROL/ROR a zero count clears C, but for
**ROXL/ROXR specifically, a zero count sets C to the current X flag** instead.

Root cause in `eu_shifter.sv`: the `count==0` default block (before the
`if (count != 0)` guard that gates the whole op-specific `case` statement)
unconditionally set `c_out = 1'b0` — correct for the 6 non-ROX ops, but wrong
for ROXL/ROXR, whose correct `c_out = roxl_c_bit`/`roxr_c_bit` (which itself
naturally evaluates to `x_in` when count=0, verified by hand) never got a
chance to run because the whole case statement is skipped. Fixed by making the
default's `c_out` conditional: `(op == SHF_ROXL || op == SHF_ROXR) ? x_in : 1'b0`.

Also fixed the existing `eu_shifter_tb.sv` unit test (`F5a`), which had encoded
the *old, incorrect* behavior (`ROXL by 0, C=0`) as its expected value — updated
to assert `C=x_in` per spec, and added a matching `F5b` case for ROXR with
`x_in=0` to cover both flag polarities.

### Results — after fix

| Suite | Before | After |
|-------|--------|-------|
| ROXL.b | 99.6% (7274/7305) | **100%** (7305/7305) |
| ROXL.w | 99.7% (4341/4353) | **100%** (4353/4353) |
| ROXL.l | 99.7% (4270/4284) | **100%** (4284/4284) |
| ROXR.b | 99.6% (7299/7330) | **100%** (7330/7330) |
| ROXR.w | 99.6% (4320/4337) | **100%** (4337/4337) |
| ROXR.l | 99.7% (4289/4302) | **100%** (4302/4302) |

**Verification**: `make test` (32/32, after fixing `eu_shifter_tb.sv`'s stale
expectation), `make cosim_grp` (8/8 vs Musashi).

This is the first RTL bug found by the debug technique in this session that
wasn't triggered by an indexed/register-port EA case — it's a plain CCR
edge-case bug in the shifter's zero-count path, present since whenever
register-count ROX was first implemented, simply never exercised by the
regression suite or by any Harte suite until this sweep ran the register-count
form at scale.

---

## Phase 88 — BTST retest: already 100%

**Goal**: re-verify `BTST.json.gz` after all the intervening bit-op fixes
(Phases 79-83 touched BCHG/BCLR/BSET's shared dynamic-bit-op decode paths,
which BTST also runs through).

**Result**: BTST.json.gz **100%** (8064/8064), zero failures. No RTL or
harness changes needed — this suite was already passing; retested purely to
close out the remaining-work list item and confirm none of the BCHG/BCLR/BSET
fixes (particularly Phase 83's harness classification fix, which affects the
same `f_group==0`+mode-6 dynamic-bit-op decode shared by BTST) introduced any
regression specific to the read-only bit-test form.

**Verification**: Harte suite only — no RTL changed, so `make test`/
`make cosim_grp` were already covered by Phase 87's checkpoint.

---

## Phase 89 — MOVEQ 4-TIMEOUT investigation: already resolved, 100%

**Goal**: track down the 4 TIMEOUTs noted against MOVEQ (`MOVE.q.json.gz`) in
earlier status logs.

**Result**: `MOVE.q.json.gz` **100%** (6089/6089), 0 TIMEOUT, 0 FAIL. Whatever
caused the 4 TIMEOUTs was resolved as a side effect of an earlier phase's IFU/
`ext_count` fix (most likely the Phase 78/79 `m68030_seq.sv` classification
fixes, which touched the same extension-word-count machinery TIMEOUTs
typically trace back to — an IFU prefetch-queue desync from a wrong
`ext_count`). No RTL or harness changes needed this phase.

**Verification**: Harte suite only — no RTL changed.

---

## Phase 90 — Sweep of never-tested instruction families: major findings

**Goal**: run every remaining Harte suite that had never been exercised at
scale (only covered by the 32-test regression + 8-group cosim, not the full
8065-vector corpus): ABCD, ADDX, ANDItoCCR/SR, Bcc, BSR, DBcc, DIVS, DIVU,
EORItoCCR/SR, EXG, EXT, JMP, JSR, LEA, LINK, MOVEA, MOVEfromSR, MOVEM, MOVEP,
MOVEtoCCR/SR, MULS, MULU, NBCD, NOP, ORItoCCR/SR, PEA, RESET, SBCD, Scc, SUBX,
SWAP, UNLINK (44 suites total; TRAP/RTE/RTR excluded, tracked separately as
Phase 91).

### Result: mostly clean, but this uncovered by far the largest cluster of
### real gaps found in the entire Harte verification effort to date.

**Clean (100%, or a single stray fail not yet investigated):** ADDX.b/l
(ADDX.w has 1 fail), ANDItoCCR/SR, Bcc, BSR, DBcc, EORItoCCR/SR, EXG, EXT.w/l,
LINK, MOVEA.w/l, MOVEfromSR, MOVEM.w, MOVEP.w/l (1 fail each), MOVEtoCCR, NOP,
ORItoCCR/SR, RESET, SUBX.b/w/l, SWAP, UNLINK.

**Substantially broken — real, unfixed RTL gaps found this phase:**

| Suite | Pass rate | Fail | Timeout | Notes |
|-------|-----------|------|---------|-------|
| NBCD | 6.9% | 4811 | 2698 | worst of the three BCD ops |
| SBCD | 33.1% | 5393 | 0 | |
| ABCD | 51.0% | 3953 | 0 | |
| DIVS | 15.7% | 458 | 3636 | |
| DIVU | 18.2% | 271 | 3665 | |
| MULS | 24.5% | 867 | 2771 | |
| MULU | 25.1% | 951 | 2686 | |
| Scc | 72.7% | 526 | 812 | |
| PEA | 86.0% | 439 | 154 | |
| LEA | 89.0% | 449 | 0 | |
| MOVEM.l | 95.0% | 201 | 0 | |
| MOVEtoSR | 96.3% | 89 | 0 | |

None of these have been root-caused yet — this phase focused on the sweep
itself plus the one deep-dive below (JMP/JSR). Given the scale of this list,
each will need its own root-cause phase, likely following the same
hand-verification technique that has worked throughout this investigation.

### JMP/JSR: two-part harness bug found + fixed (0% → ~89%), one RTL gap identified but not yet fixed

**Before this phase, JMP and JSR were 100% SKIP — 0 of 8065 tests in either
suite ever ran.** Root cause: two compounding bugs in `gen_harte_hex.py`'s
`can_run()`, both stemming from the same wrong assumption — that
`instr_len = final['pc'] - ini['pc']` is always "the instruction's own byte
length." That's true for straight-line instructions (PC advances
sequentially) but **not** for JMP/JSR, where PC-after-execution is the *jump
target*, unrelated to the instruction's encoded length.

1. **"EA overlaps STOP runway" false positive.** For JMP/JSR,
   `get_operand_ea()` returns the jump target as "ea" (not a data operand —
   JMP/JSR never read/write memory there). `build_patches()` *intentionally*
   places the STOP+NOP runway starting exactly at that target, using the same
   `instr_len` identity (`stop_addr = instr_src + instr_len` reduces
   algebraically to `final_pc - 4`, i.e. the jump target — by design, so
   execution halts immediately after landing). But `can_run()`'s overlap
   check had no exemption for this: it flagged every JMP/JSR test as
   "conflicting" with a runway that was deliberately placed to coincide with
   its own target. Fixed by adding an `is_jmp_jsr` opcode check (`f_group==4,
   !f_dir, f_dn==7, f_ss∈{2,3}`) and skipping the overlap check for those two
   instructions specifically, since there's no real data being protected.
2. **"misaligned EA" backstop false positive.** A second, later check —
   `if not (1 <= instr_len <= 24): return False, 'misaligned EA'` — exists to
   catch instructions where `get_operand_ea()` returned `None` (EA too
   complex to compute statically) and a wild PC delta implies the reference
   took an address-error exception. But it ran unconditionally, so once fix
   #1 let JMP/JSR tests reach this point, they hit it too: `instr_len` is
   *always* "wild" for a jump (PC legitimately goes somewhere else), which
   isn't a signal of an exception in this case, since `get_operand_ea()` DID
   return a concrete EA and its misalignment was already checked earlier.
   Fixed by gating the backstop on `ea_info is None`.

**Results**: JMP 0% → **88.6%** (3758/4240 run), JSR 0% → **89.1%**
(3738/4194 run). `make test` (32/32) and `make cosim_grp` (8/8) both pass —
Python-only change, no RTL rebuild strictly required, but rebuilt anyway as
part of the investigation below.

**Residual RTL gap (not fixed, root cause narrowed but not found):** every
remaining JMP/JSR failure is a TIMEOUT, and 100% of them are the
`(d8,An,Xn)`/`(d8,PC,Xn)` indexed target forms (confirmed via
`grep TIMEOUT | sort | uniq -c` — every An register and PC, all indexed,
zero non-indexed failures). Added temporary `$display` tracing (`eu_seq.sv`,
`ex_jmp_taken`) and confirmed the RTL computes the jump target **correctly**:
`rd_a_data + ex_jump_offset + ex_xn_scaled` produces a 32-bit value whose low
24 bits exactly match the test's expected target (verified against test index
22, `JMP (d8,A4,Xn)`: computed `0x0bcbf118`, expected target `0xcbf118` —
matches after masking). The memory model (`mem_idx = ext_a[23:2]`) already
ignores address bits above 23, so bus-level access to the correct physical
location should work regardless of the stray high byte. Yet **zero further
bus activity of any kind occurs after the jump** — the simulation doesn't
even attempt a subsequent fetch, even at 10x the normal cycle budget. This
means the target-address computation is not the culprit; something in the
IFU-redirect/pipeline-restart handshake (`pc_wr_en`/`fetch_pend_r`/
`eu_instr_ack`/`drain`) fails to complete specifically when `ex_is_idx` is
combined with a control-transfer instruction. Spent significant effort
tracing `branch_target`, `pc_wr_en_common`, and the IFU's queue-flush logic in
`m68030_ifu.sv` without finding the exact stall condition — deprioritized in
favor of surfacing the full sweep's findings; needs a dedicated follow-up
phase with more `$display` tracing on the IFU's `fetch_pend_r`/`ifu_req`/
`ifu_ack` sequence in the cycles immediately following `pc_wr_en`.

**Also note**: the computed 32-bit target legitimately differs from the
68000 reference whenever `rd_a_data + ex_jump_offset + ex_xn_scaled` exceeds
24 bits — real 68000 hardware only has 24 address pins and silently drops the
upper byte, while the 68030 has genuine 32-bit addressing and does not. This
is the same class of 68000-vs-68030 architectural difference the scale-remap
and misalignment filters already account for elsewhere; some fraction of the
"indexed timeout" cases may turn out to be more of this (unreplayable on our
DUT, should SKIP) rather than a pure RTL bug — worth checking during the
follow-up.

**Debugging notes for next attempt**: temporary trace was added at
`eu_seq.sv`'s `assign branch_taken = ...` block (an `always_ff` firing on
`ex_jmp_taken`) and has been removed. Reproduction: `tests/harte/JMP.json.gz`
index 22 (`JMP (d8,A4,Xn)`) via a small Python script calling
`gen_harte_hex.gen_hex(test)` + `vvp sim/harte_dat +hexfile=... +cycles=20000`
— same pattern used throughout this investigation.

---

## Phase 91 — ABCD/SBCD/NBCD root-caused: reverse-engineered real-hardware N/V flags, fixed genuine RTL bugs → 51%/33%/6.9% → 100%/99.7%/100%

**Goal**: root-cause the Phase 90 BCD cluster (ABCD 51.0%, SBCD 33.1%, NBCD 6.9%).

### The core problem: N and V are "undefined" per the 68k PRM, but real hardware isn't random

ABCD/SBCD/NBCD's N and V flags are officially undefined, but real silicon
produces specific, deterministic values (a side effect of the internal BCD
adder), and Tom Harte's corpus — captured from real hardware — checks them.
The existing `eu_bcd.sv` never computed N/V at all (`ex_n=1'b0`/`ex_v=1'b0`
hardcoded at the register-direct WB path in `eu_seq.sv`; `1'b0` hardcoded at
the memory-form CCR-write path too), so almost every non-trivial test failed
on CCR alone even when the result byte was correct.

**Musashi (`tools/musashi/m68kops.c`) does not match real hardware either**,
for N/V *or* for the result byte in SBCD/NBCD's invalid-BCD-digit edge cases
(operand nibbles 10-15, which Tom Harte deliberately exercises). Confirmed by
hand-simulating Musashi's exact algorithm in Python against raw Harte JSON:
for `ABCD D2,D4` (src=0x3d, dst=0x49, X=1), Musashi's formula predicts V=1;
the actual hardware-captured expected CCR has V=0.

### Reverse-engineering the real formulas

Since neither the PRM nor Musashi gave a usable reference, the flags were
derived empirically: gather (operand, expected-CCR) tuples straight from the
raw Harte JSON for each op's register-direct form, hypothesize candidate bit
formulas, and brute-force/exhaustively search 1-2-feature boolean combinations
of intermediate signals until a 0-mismatch formula was found. Verified against
every register-direct vector in each suite (4004 ABCD, 3948 SBCD, 1315 NBCD).

Findings:
- **N** = bit 7 of the final (BCD-corrected) result byte — this one was
  already implicit and correct via `bcd_result[7]`, just never wired to `ex_n`.
- **ABCD V** = `N & ~(bit7 of the UNCORRECTED binary sum dst+src+X)`. The
  "uncorrected" sum is algebraically identical to `add_lo + HIGH(dst) +
  HIGH(src)` (nibble decomposition is exact before any BCD correction), which
  is exactly what the RTL already computed as `add_bin` — reused directly.
- **SBCD/NBCD V** = `~N & (bit7 of the UNCORRECTED binary difference
  dst-src-X)` — same shape, sign flipped, matching the subtraction case.
- **ABCD carry (C/X)**: Musashi's `>0x99` threshold is wrong — the true
  threshold is `>=0xA0`. The `0x9A-0x9F` band only arises from invalid BCD
  digits surviving into the high-nibble stage; real hardware does not correct
  for it. (Fixed 28/4004 C-flag mismatches.)
- **SBCD/NBCD's low-nibble correction** must be gated by a true *signed
  borrow* (`dst_lo - src_lo - X < 0`), not Musashi's `raw_digit > 9` — those
  diverge whenever an operand nibble is invalid (>9), a whole class of cases
  Musashi gets outright wrong even for the *result byte*, independent of flags.
- **SBCD/NBCD's high-nibble borrow (C/X)**: a true *signed* check on the
  nibble-combined intermediate (`s2 < 0`), not Musashi's byte-level
  `dst < src+X` comparison or its `>0x99` magnitude check — both diverge from
  real hardware on invalid-digit inputs.

### Two real RTL implementation bugs found along the way

1. **Verilog sign-extension bug** (own mistake while implementing the above):
   `{4'b0, sbcd_loc}` is a *concatenation*, which does NOT sign-extend a
   negative signed value — it just zero-pads, silently corrupting the result
   whenever `sbcd_loc` was negative (the common case). Symptom: every BCD op
   result off by exactly `0x40`. Fixed with explicit sign-bit replication
   (`{{4{sbcd_loc[5]}}, sbcd_loc}`).
2. **9-bit overflow in `add_adj1`** (pre-existing, unrelated to the flag work):
   `add_bin` (max `0x1FF`) `+ 6` can reach `0x205`, which doesn't fit in the
   9-bit field the RTL declared — it silently wrapped for invalid-BCD-digit
   inputs near the top of `add_bin`'s range. Found via Harte test `cf00 [ABCD
   D0,D7]` (D0=0xff, D7=0xfb): correct result 0x60, RTL produced 0x00 after
   the 9→10-bit wrap. Widened `add_adj1`/`add_adj2` to 10 bits.

### A genuine pre-existing memory-form addressing bug, unrelated to any of the above

The `-(Ay),-(Ax)` memory-form ABCD/SBCD predecrement FSM (`bcds_ay_addr_r`/
`bcds_ax_addr_r` in `eu_seq.sv`) always stepped by 1, missing the standard
68k rule that a *byte*-sized `-(An)` on **A7** steps by 2 to keep the stack
word-aligned (the same rule already correctly applied elsewhere in this
codebase for other byte-op `-(A7)` cases). Symptom: `A7: got 0x7ff, exp
0x7fe`. Fixed by computing per-register step sizes (`bcds_ay_step`/
`bcds_ax_step`).

A second, related bug: when Ay and Ax are the **same register**
(`-(A1),-(A1)`), Ay's predecrement (applied while evaluating the source
operand) must be visible to Ax's own predecrement — the RTL computed both
from the original (pre-decrement) register value. Fixed by compounding Ax's
address on top of Ay's already-decremented value when the registers match
(same "same-register conflict" pattern fixed for MOVE in Phase 82).

### NBCD's missing extended EA modes

Separately from all of the above, NBCD's memory-EA decode only ever covered
`(An)/(An)+/-(An)/(xxx).W`/(a pre-existing `(xxx).L` decode that turned out to
be missing its `ext_count` classification). Added `(d16,An)`/`(d8,An,Xn)`
decode (mirroring the same pattern used for TAS/CLR/NEG/NOT/NEGX/TST in
Phases 80-81) plus the missing `ext_count=1`/`ext_count=2` classifier entries
for `(d16,An)`/`(d8,An,Xn)`/`(xxx).L` in `m68030_seq.sv`.

### Results

| Suite | Before | After |
|-------|--------|-------|
| ABCD | 51.0% (4112/8065) | **100%** (8065/8065) |
| SBCD | 33.1% (2672/8065) | **99.7%** (8037/8065) |
| NBCD | 6.9% (555/8064) | **100%** (8064/8064) |

**SBCD's residual 28/8065 (0.35%) is a genuine, not-yet-solved algorithmic
subtlety**: hand-verified that the C flag and the result-byte correction are
*decoupled* in real hardware in a way the current `s2 < 0` single-condition
model doesn't capture — two operand pairs producing the identical
nibble-combined intermediate (`s2 = -1`) need opposite treatment (one wants
the `+0xA0` wraparound applied to the result, the other wants the plain
two's-complement truncation), distinguished by *how* they arrived at that
intermediate (whether the low-nibble correction fired), not by the
intermediate's own value — the current formula loses that path information
by combining everything into one number. A brute-force search over the
available intermediate signals didn't find a clean replacement condition;
whichever single condition was tried either matched the known-good 3939/3948
cases or the residual 9, never both. Left as a known gap rather than
introducing an untested guess.

**Verification**: `make test` (32/32, after adding `n_out`/`v_out` wires to
`eu_bcd_tb.sv`'s wildcard `.*` port connection), `make cosim_grp` (8/8 vs
Musashi).

---

## Phase 92 — MULS/MULU root-caused: memory-EA decode was entirely missing → 24.5%/25.1% → 97.4%/97.3%

**Goal**: root-cause the Phase 90 MULS (24.5%)/MULU (25.1%) cluster.
DIVS/DIVU turned out to need a much deeper, separate investigation — see below.

### Finding 1: `(An)/(An)+/-(An)/(d8,An,Xn)`/immediate forms were never decoded at all

Exactly the same shape as MULS/MULU's sibling AND/OR: the shared
AND-memory-source and OR-memory-source decode blocks in `eu_seq.sv`
explicitly gate on `f_ss != 2'b11`, since MUL/DIV repurpose those two size
bits as their own opcode signature (the operand is always a fixed 16-bit
word, never byte/word/long-selectable) rather than a size field. That
exclusion meant MULS/MULU's `(An)/(An)+/-(An)`, `(d8,An,Xn)`, and `#imm`
forms were **never decoded at all** — only the pre-existing block covering
`(d16,An)`/`(xxx).W`/`(xxx).L`/`(d16,PC)`/`(d8,PC,Xn)` worked. Added four new
decode blocks mirroring the AND/OR blocks' EA-computation exactly, with
`dec_unit=UNIT_MUL`/`dec_md_op` substituted for the ALU op. Also added the
missing `is_muldiv_imm` `ext_count` classifier entry in `m68030_seq.sv` (the
existing `is_alu_imm_dn` explicitly excludes `f_ss==11` for the same reason).

### Finding 2: the bus read size was never overridden from the 32-bit result size

Even the pre-existing memory-source block set `dec_siz=2'b00` (correct for
the 32-bit result write to Dn) but never told the bus layer that the READ
itself must stay word-sized — there's a dedicated `dec_mem_rd_siz` override
signal (sentinel `00` = "no override, use `dec_siz`") that other dual-size
instructions (visible at several existing call sites) already use for
exactly this situation, but MUL's block never set it. Result: every
memory-source MUL requested a **longword** bus read for what should be a
16-bit word, which — depending on the specific address — either silently
hung waiting for an ack the bus never gave for that access pattern, or
returned data that the multiply then read from the wrong byte lanes.
Confirmed via `$display` tracing (`ex_mem_stall`/`mem_ack` stayed asserted
forever, zero bus activity) then found the fix by grep-ing for other
`dec_mem_rd_siz` users. This single fix (plus Finding 1) took MULS/MULU from
24.5%/25.1% to 94.7%/94.8%, eliminating nearly all TIMEOUTs.

### Finding 3: a fourth instance of the `get_scale_remap()`/`get_operand_ea()` size-classification bug

The remaining ~5% (all `(d8,An,Xn)`/`(d8,PC,Xn)` indexed forms, showing wrong
results with a suspiciously structured error — e.g. `0xfa2df100` vs expected
`0xfa33a735`, low byte always `00`) traced to `gen_harte_hex.py`'s
`get_scale_remap()`: its `siz_bytes` determination has a generic
`{0:1,1:2,2:4}.get(f_ss, 1)` fallback that silently defaults to **1 byte**
for MUL/DIV's `f_ss==3` signature (not in the dict), so the scale-remap only
copied half the test data to the scaled address, leaving the other byte
stale/zero — the DUT's *correctly* 68030-scaled address computation was
right, the harness's own data placement wasn't. `get_operand_ea()` had a
related but different bug in the same spot: its `elif f_ss==3` branch
assumes ADDA/SUBA/CMPA-style semantics (`f_dir` selects word vs long), but
for MUL/DIV `f_dir` selects signed vs unsigned, unrelated to size — so MULS
(f_dir=1) got `siz_bytes=4` instead of 2 (MULU got the right answer by
coincidence, since f_dir=0 there too). Fixed both with an explicit
`f_group in (0x8, 0xC) and f_ss==3 → siz_bytes=2` branch ahead of the
generic fallback in each function — this is the same recurring
"f_ss/f_dir field means something different for this instruction family"
harness-bug shape found repeatedly across this whole Harte investigation,
just newly triggered because MUL/DIV's indexed-source form had never existed
in the RTL before this phase to exercise it.

### Results

| Suite | Before | After |
|-------|--------|-------|
| MULS | 24.5% (1178/4816) | **97.4%** (4816/4943) |
| MULU | 25.1% (1221/4858) | **97.3%** (4858/4991) |

**Residual (both suites, ~2.6%): TIMEOUT, 100% on `(d8,An,Xn)`/`(d8,PC,Xn)`
indexed forms specifically** — the same symptom shape as Phase 90's
still-unsolved JMP/JSR indexed-EA IFU-redirect stall (though MUL's indexed
block additionally uses the `dyn_bit_get_Dn` deferred-register-swap
mechanism, which JMP/JSR's doesn't, so these may or may not share a root
cause — not yet determined). Not investigated further this phase given the
time already spent; tracked as a follow-up alongside JMP/JSR's.

**DIVS/DIVU are a separate, much deeper problem, NOT resolved by any of the
above.** Even pure **register-direct** divides (`DIVS D4,D5`, `DIVU D3,D7`)
fail with CCR mismatches, and both suites show **thousands** of TIMEOUTs
(DIVS: 3603/4975, DIVU: 3631/4931) — a scale and a symptom (register-direct
failures) that the memory-EA/bus-size fixes above cannot explain, since
those forms never touch the memory-EA decode path at all. This points to a
fundamental problem in the divide FSM itself (`eu_mul_div.sv`), most likely
around overflow-trap or divide-by-zero handling given the sheer TIMEOUT
volume. Barely moved by this phase's fixes (DIVS 15.7%→17.2%, DIVU
18.2%→19.8%) — needs its own dedicated investigation from scratch, not a
continuation of the MULS/MULU work. Tracked separately.

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi).

---

## Phase 93 — DIVS/DIVU root-caused: two real bugs, unrelated to the MULS/MULU fixes → 17.2%/19.8% → 97.6%/97.6%

**Goal**: root-cause the deep DIVS/DIVU problem left open by Phase 92 —
register-direct divides failing and thousands of TIMEOUTs, a symptom shape
the MULS/MULU memory-EA fixes couldn't explain.

### Bug 1: DIVS/DIVU overflow always clears C — the RTL's own comment was wrong

Hand-verified against 887 DIVS.json.gz and 536 DIVU.json.gz register-direct
overflow vectors (cases where the result is unchanged, meaning the divide
overflowed and aborted per spec): **C is 0 in 100% of these cases**,
regardless of the incoming C value. The existing RTL's overflow branch —
labeled `// N/Z/C unchanged (matches Musashi)` — set `ex_c = flag_c` (leave
C as whatever it was before the divide). That comment was simply wrong: N/Z
genuinely are unchanged (887/887 and 536/536 match), but C must always be
cleared. This is the exact same shape of bug as Phase 91's BCD flags —
Musashi's own reference doesn't match real hardware for this "what happens
to unaffected flags on trap/abort" edge case either. One-line fix:
`ex_c = 1'b0;` in the overflow branch.

### Bug 2: `div_trap` evaluated `md_div_by_zero` before the memory read completed — the actual mass-TIMEOUT cause

`$display` tracing on a failing memory-source `DIVS (A6),D4` test (Harte
index 3 — nearly every *other* memory-source DIVS/DIVU test in the file was
failing this way) showed: `mem_ack=0`, `mem_rdata=00000000`,
`md_div_by_zero=1`, `ex_mem_stall=1` — **forever**, no further bus activity
at all. `md_src = ex_is_mem_src ? mem_rdata : ...` reads `mem_rdata` live;
before the bus read actually acks, that wire sits at its idle value of zero.
`eu_mul_div`'s combinational `divs_zero = (src[15:0]==0)` correctly computes
true for that *momentarily* all-zero operand — and `div_trap` was wired as a
**pure combinational** `assign div_trap = ex_valid && (ex_unit==UNIT_DIV) &&
md_div_by_zero`, with no gate on whether the memory-source operand had
actually arrived yet. That fired a bogus divide-by-zero trap sequence *while
the pipeline was still stalled waiting for the real memory read*, and the
two mechanisms fighting over control locked the pipeline permanently.

The fix already existed as a pattern one line below: `chk_trap` (CHK's own
out-of-bounds trap, which has exactly the same "memory-source operand not
ready yet" hazard) is correctly gated as `ex_is_mem_rd && mem_ack` for its
memory-source case. Applied the identical structure to `div_trap`: trap
combinationally for register/immediate sources (always valid), but for a
memory source, only trust `md_div_by_zero` on the cycle `mem_ack` actually
fires.

This single fix explains the overwhelming majority of both suites' TIMEOUT
counts — every memory-source divide whose *first* combinational evaluation
(before the read completed) happened to see `mem_rdata==0` triggered this,
which given `mem_rdata`'s zero idle value is unconditional for every
memory-source divide that reaches this window.

### Results

| Suite | Before | After |
|-------|--------|-------|
| DIVS | 17.2% (857/4975) | **97.6%** (4856/4975) |
| DIVU | 19.8% (978/4931) | **97.6%** (4814/4931) |

**Residual (~2.4% both suites): TIMEOUT, 100% on `(d8,An,Xn)`/`(d8,PC,Xn)`
indexed forms** — after this fix, DIVS/DIVU's remaining failure list is
*exactly* the same shape as MULS/MULU's (Phase 92) and JMP/JSR's (Phase 90)
residual indexed-EA timeouts. Four independent instruction families now show
the identical symptom (indexed EA + TIMEOUT, everything else passing) —
strong circumstantial evidence they share one root cause somewhere in the
IFU-redirect or register-swap machinery that indexed addressing touches, but
this still hasn't been isolated. Worth a dedicated phase now that the
evidence base is much stronger (4 repro cases across 3 different instruction
shapes — JMP/JSR use no register-swap at all, MUL/DIV use
`dyn_bit_get_Dn`/`dec_is_idx` — ruling out anything specific to one
mechanism).

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi).

---

## Phase 94 — Shared indexed-EA TIMEOUT root-caused: reference-side 68000 Address Error our 68030 correctly doesn't replicate → MULS/MULU/DIVS/DIVU 97.3–97.6% → 100%/100%/100%/100%

**Goal**: root-cause the indexed-EA TIMEOUT shared by JMP/JSR (Phase 90), MULS/MULU
(Phase 92), and DIVS/DIVU (Phase 93) — four instruction families, all with the
identical residual symptom (every `(d8,An,Xn)`/`(d8,PC,Xn)` test TIMEOUTs, everything
else passes), diverse register-swap mechanisms ruling out any single instruction's
decode logic as the cause.

### Investigation

Added a temporary `$display` trace in `eu_seq.sv`, gated on `ex_valid && ex_unit ==
UNIT_MUL/UNIT_DIV`, plus a second trace (a 60-cycle counter armed at `mem_ack`) printing
`dec_valid`/`hazard_*`/`need_ext`/`ex_unit`/`stall`/`instr_ack` every cycle after the
multiplicand read completes. Reproduced Harte `MULS.json.gz` index 75 (`MULS
(d8,A1,Xn),D0`, a known TIMEOUT) via `gen_harte_hex.gen_hex()` into a standalone `.hex`
file and ran it directly against `sim/harte_dat`.

The trace showed the MULS instruction's own memory read completing correctly (`mem_ack`
fires, the `dyn_bit_get_Dn` register swap retargets `rd_b_sel` from `Xn` to `Dn`
exactly as designed) and the instruction retiring normally. The **next** instruction
then entered EX as `ex_unit == UNIT_MOVE` and stalled on `ex_mem_stall` forever — i.e.
the MULS instruction itself was fine; some *subsequent*, unrelated instruction was
hanging. That pointed away from MULS's own decode/register-swap logic entirely and
toward the test's instruction stream layout.

Cross-checking the raw Harte JSON for the three known-bad MULS indices (75, 87, 170)
against three matched-shape passing indices found the smoking gun: **all three bad
cases have `final.pc - initial.pc == 2048` bytes**, versus 2 bytes for a normal
register-form MULS. Decoding the `final` register/RAM state confirmed this is not a
branch — it's a **real 68000 Address Error exception**: `final.sr == initial.sr`, a
classic 7-word 68000 (pre-68010, format-less) fault frame is visible on the stack
(opcode-capture word, the faulting access address split across two words, SR, PC), and
reads at vector-table addresses 12/14 (vector 3 = Address Error) return `0x1400` — the
handler address the reference model jumped to.

Hand-computing the effective address two ways confirmed why: with the index register
scaled per the 68020+ brief-extension-word scale field (bits 10–9, which our RTL — and
real 68030 silicon — implement, and which is exactly correct 68030 behavior), the EA
lands on an even address. Recomputing the *same* extension word **without** applying
scale (scale forced to 1, since scale bits don't exist in 68000 hardware at all — a
68000 CPU physically ignores those bit positions) gives an EA that is **odd**, and its
high/low words are bit-for-bit the two mystery words in the reference's fault frame.
This is unambiguous: the Tom Harte test corpus this project uses was captured on real
**68000** hardware (`CLAUDE.md`'s own comment already noted this: "68000 one-instruction
vectors"), which faults on any misaligned *word/long* access — including data, not just
instruction fetch. A 68020/68030 explicitly does **not** fault on misaligned data
accesses (only misaligned PC/instruction-fetch is still an Address Error on 68030) — so
for this narrow subset of indexed-EA tests where scale-vs-no-scale changes address
parity, the reference legitimately traps and our correctly-68030-accurate RTL
legitimately does not. There is no RTL fix that makes both correct simultaneously.

### The actual TIMEOUT mechanism (a harness bug, distinct from the above)

The permanent hang itself is *not* inherent to this divergence — `tb/mem_model.sv`
acks every read regardless of address range (out-of-bounds reads return `32'hDEAD_DEAD`
via a normal DSACK cycle, never withholding ack). The hang happens because
`gen_harte_hex.py` places the `STOP #$2700` runway at `instr_src + instr_len`, where
`instr_len = final.pc - initial.pc`. For these specific tests `instr_len` is 2048 (the
reference's post-fault PC delta, not the instruction's real length), so the runway lands
2048 bytes away from where our non-faulting RTL actually continues execution. Since our
RTL just proceeds normally after the multiply (no fault), it walks straight past the
mislocated STOP into never-initialized memory, decodes whatever garbage is there as a
real (bogus) instruction, and *that* instruction's own memory access is what hangs
forever (some computed address the simple `mem_model` genuinely never resolves due to
downstream X-propagation in the decode of essentially random opcode bits) — a
consequence of running off the end of the intended single-instruction test, not a
property of the original fault.

An existing backstop (`if ea_info is None and not (1 <= instr_len <= 24): return False,
'misaligned EA'`) already handled this shape of bug for EA modes `get_operand_ea()`
can't statically resolve — but MUL/DIV's indexed EA *is* resolvable, so `ea_info is not
None` took the earlier "does EA overlap the STOP runway" branch instead, which never
fires here (the wild runway is 2048 bytes away from anything real). Added a second,
narrower backstop right after the existing one: whenever `ea_info` resolves (a genuine
data-referencing instruction) *and* the instruction is not JMP/JSR (whose own wild
`instr_len` is legitimate — it's the jump target, checked separately) *and* `instr_len`
is still outside `[1, 24]`, skip the test as an unreplicable reference-side exception.

### Results

| Suite | Before | After |
|-------|--------|-------|
| MULS | 97.4% (4816/4943) | **100%** (4816/4816) |
| MULU | 97.3% (4858/4991) | **100%** (4858/4858) |
| DIVS | 97.6% (4856/4975) | **100%** (4856/4856) |
| DIVU | 97.6% (4814/4931) | **100%** (4814/4814) |

Zero FAIL, zero TIMEOUT across all four suites — every remaining case in each suite is
now either a genuine PASS or a clean SKIP (no more hangs). Spot-checked previously-100%
suites (`MOVE.b` 5922/5922, `BCHG` 5231/5231, `CHK` 666/666) to confirm the new skip
condition doesn't over-trigger on legitimate tests — all unchanged.

**JMP/JSR are explicitly exempted from this fix (`is_jmp_jsr` guard) and remain at
88.6%/89.1% with the same TIMEOUT counts as Phase 90.** Their wild `instr_len` is
expected (a real jump target, not a fault signal), so this backstop correctly leaves
them alone — but that means their TIMEOUT is a *different* bug. The leading hypothesis:
unlike data accesses, a 68030 genuinely *does* still fault on an odd (misaligned)
*instruction-fetch* address — including a JMP/JSR target — so if our RTL has no Address
Error trap for an odd computed jump target, an indexed JMP/JSR that lands on an odd
address would need to trap on real 68030 silicon but currently just... doesn't, and
whatever happens next (fetching from a misaligned PC) may be what hangs. This is a
plausible genuine RTL gap, not a test-corpus incompatibility like the MUL/DIV case, and
needs its own dedicated investigation (tracked as the remaining JMP/JSR item).

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi), full
MULS/MULU/DIVS/DIVU/JMP/JSR re-run plus spot-checks on MOVE.b/BCHG/CHK.

---

## Phase 95 — JMP/JSR indexed-EA TIMEOUT root-caused: same 68000-vs-68030 scale divergence as Phase 94, but the target itself, not an operand → 88.6%/89.1% → 100%/100%

**Goal**: root-cause JMP/JSR's own indexed-EA TIMEOUT, explicitly identified in Phase 94
as a *different* bug from MULS/MULU/DIVS/DIVU's (that fix's `is_jmp_jsr` guard correctly
exempts JMP/JSR, since their wild `instr_len` is a legitimate jump target, not a fault
signal — so it needed its own investigation).

### Investigation

Sampling indexed JMP tests one at a time via `run_test()` (bypassing the slow full-suite
run) found the TIMEOUT rate is much higher for JMP/JSR than it looked from spot checks —
scanning all 2588 indexed JMP tests directly gave 482 TIMEOUT / 840 PASS / 1266 SKIP,
matching the full-suite numbers exactly (a first pass with a broken `if not ok:` truthy
check on the `run_test()` string-status return silently reported zero failures — worth
remembering: `run_test()` returns a status *string* like `'PASS'`/`'TIMEOUT (...)'`, not a
bool, so `if not ok` is always false).

Reproduced index 4 (`JMP (d8,A2,Xn)`) via `gen_harte_hex.gen_hex()` and added a temporary
trace in `m68030_top.sv` on `eu_branch_taken`/`eu_branch_target`/`pc_wr_en_common`/
`ifu_addr_err_int`/`exc_active`/`u_exc.state_r` (hierarchical reference to the exception
FSM's internal state register, for debug visibility only). The RTL computed
`eu_branch_target = 0x4d5e9ede` and drove `pc_wr_en_common` with it — then issued **zero**
further bus requests, exactly matching Phase 90's original "confirmed correct target, then
total silence" observation.

Hand-decoding the extension word (`0x2c12`: Xn=D2.L, **scale=4** (bits 10-9 = `10`),
displacement=+18) and recomputing the target four ways confirmed the RTL's `0x4d5e9ede` is
*exactly* `A2 + D2×4 + 18` — genuinely correct 68030 arithmetic (scale applied). Recomputing
with scale forced to 1 (68000 semantics, matching Phase 94's finding that real 68000
silicon ignores the scale field) gives `0x647ec5ef` instead — a *completely different*
address, not just a different parity. That's the real distinction from the MULS/MULU/
DIVS/DIVU case: there, a scale mismatch only changes whether a *data* address happens to
be odd (irrelevant to a 68030, which doesn't fault on misaligned data access, so execution
just continues normally afterward with a merely-different operand). For JMP/JSR, the "EA"
*is* the new PC — a scale mismatch sends the reference and our RTL to two **completely
different places in memory**, and whichever one the test's `STOP` runway isn't at, that
execution path runs into uninitialized memory and hangs, regardless of odd/even parity.

Confirmed in `scripts/gen_harte_hex.py`: `build_patches()` places the `STOP`+`NOP` runway
at `instr_src + instr_len` where `instr_len = final.pc - initial.pc` — i.e. at the 68000
reference's own (unscaled) landing address. `get_operand_ea()` (used elsewhere for EA
range/overlap checks) computes the *68030-scaled* target via `get_scale_remap()`'s
`ea_68030`. For scale=0 these are identical (the overwhelming majority of indexed JMP/JSR
tests, hence the existing 840/3738 PASS counts already achieved pre-fix), but whenever
scale≠0 they diverge — the runway sits at the reference's target, our RTL lands at a
different, uninitialized address, and hangs.

### Fix

Unlike Phase 94 (a narrow subset — only the odd-parity cases needed skipping), JMP/JSR's
divergence applies to **every** scale≠0 indexed case, since the landing address itself
differs regardless of parity. Added an unconditional skip in `can_run()`'s existing
scale-remap loop: computed `is_jmp_jsr` earlier (before the loop, so it's available inside)
and, when true, skip on ANY non-empty `get_scale_remap()` result (scale≠0 detected for this
instruction's own indexed EA) rather than only on the odd/init-region conditions that apply
to ordinary data instructions.

### Results

| Suite | Before | After |
|-------|--------|-------|
| JMP | 88.6% (3758/4240) | **100%** (3758/3758) |
| JSR | 89.1% (3738/4194) | **100%** (3738/3738) |

Same PASS counts as before (3758/3738) — confirms this is purely a TIMEOUT→SKIP
conversion with zero regression, not a behavior change to any passing case.

**Zero RTL changes** — same shape as Phase 94: a real, understood, permanent 68000-vs-
68030 architectural divergence (68000 ignores the scale field entirely; a correct 68030
must not), made unreplicable-in-principle by the test harness's runway-placement design,
fixed by skipping rather than by (incorrectly) trying to make the RTL match a real 68000's
undefined-for-68030 behavior.

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi), full JMP/JSR
re-run.

---

## Phase 96 — Scc root-caused: real RTL missing-decode + a genuine ext_count mislabeling bug (a real one this time) → 72.7% → 100%

**Goal**: root-cause Scc's 72.7% pass rate, found in Phase 90's sweep and never investigated.

### Investigation

`run_harte.py --verbose` broken down by EA mode showed an unmistakable pattern: `Dn`,
`(An)`, `(An)+`, `-(An)`, and `(xxx).L` were all 100% PASS, while `(d16,An)`,
`(d8,An,Xn)`, and `(xxx).W` were all heavily FAIL/TIMEOUT — `(xxx).W` was **100%
TIMEOUT** (61/61), the others a mix of FAIL and TIMEOUT. The clean split by addressing
mode (not opcode, not operand data) pointed straight at missing/broken EA decode rather
than a data-dependent RTL bug.

### Bug 1 — Scc `(xxx).W` was never decoded at all; its opcode slot was stolen by TRAPcc

68k's `0101 cccc 11 mmm rrr` (group 5, `f_ss=11`) encoding is shared between Scc (mode
selects the write-destination EA) and TRAPcc (mode=111 only, `reg` selects the operand
size: 100=none, 010=word, 011=long). Scc's own `mode=111` forms use `reg=000` (abs.W)
and `reg=001` (abs.L) — reg values TRAPcc never uses, since (d16,PC)/(d8,PC,Xn)/#imm
would be invalid Scc write destinations, so Motorola reused exactly those slots for
TRAPcc's own operand-size selector instead. `eu_seq.sv`'s Scc memory-EA decode block
only checked `f_reg == 3'b001` (abs.L) — missing `f_reg == 3'b000` (abs.W) — so every
Scc abs.W instruction fell through to the **TRAPcc branch**, whose own condition
(`f_reg == 100 || 010 || 000`) incorrectly included `000` (should have been `011`,
TRAPcc.L, which was consequently *unreachable* until this fix). TRAPcc doesn't write
memory, so the intended Scc write silently never happened.

### Bug 2 — `m68030_seq.sv`'s ext_count table had the identical reg=000 mislabel, twice

Even after adding the missing abs.W decode branch in `eu_seq.sv`, `(xxx).W` still
TIMEOUT out 100%. Traced with a temporary `$display` on `dec_abs_ea_val`/`ext_data` at
the decode→EX capture point: `ext_data` showed the *raw*, un-remapped `{q[1],q[2]}`
32-bit form instead of the 1-extension-word convention (`{16'h0, q[1]}` in the low
half) — meaning `ext_count` was computing to 2, not 1, for this instruction. Added a
matching debug trace directly on `ext_count` in `m68030_seq.sv`, which showed the value
oscillating between 1 and 2 within the same clock edge (multiple `always_comb`
re-evaluations) — the *final* settled value came from an **earlier, higher-priority**
`else if` in the chain: a pre-existing entry literally commented `// TRAPcc.L has
2-word operand` matching `f_group==5 && f_ss==11 && f_mode==111 && f_reg==000` —
**the exact same reg=000-as-TRAPcc.L mislabel as Bug 1, in a completely separate part of
the file**, assigning `ext_count=2` before the (correctly-fixed) later entry for Scc's
real abs.L/TRAPcc.L pair (`reg==001||011`) was ever reached. First fix attempt edited
the *wrong* (later, unreachable) occurrence — a reminder that this file's `else if`
priority chain means only the *first* match matters, and grepping for all occurrences
of a suspect condition is essential before declaring a fix complete.

### Fix

- `eu_seq.sv`: added `f_reg == 3'b000` to Scc's memory-EA branch condition; the
  `(xxx)` case now branches on `f_reg` to pick 1-word sign-extended (abs.W) vs.
  full 32-bit (abs.L) for `dec_abs_ea_val`. Corrected the TRAPcc branch to
  `f_reg == 100 || 010 || 011` (was `100 || 010 || 000`), making TRAPcc.L reachable
  for the first time.
- `m68030_seq.sv`: fixed the original `reg==000` mislabel to `ext_count=1` (was 2,
  labeled "TRAPcc.L"); extended the *correct* Scc-abs.L entry to also cover
  `reg==011` (real TRAPcc.L, 2 ext words); added a new 1-ext-word entry for Scc's
  `(d16,An)`/`(d8,An,Xn)` modes, which had **no ext_count entry at all** — falling to
  the `default: ext_count=0` catch-all and corrupting the IFU stream exactly like
  every prior "missing ext_count entry" bug in this project's history; removed the
  now-dead/redundant `reg==000` from the later 1-ext-word OR-chain (unreachable
  after the earlier, corrected entry).

### Results

| Mode | Before | After |
|------|--------|-------|
| Scc overall | 72.7% (3557/4895 run) | **100%** (4895/4895) |
| `(xxx).w` | 0% (61/61 TIMEOUT) | 100% |
| `(d16,An)` | ~5-10% | 100% |
| `(d8,An,Xn)` | ~5-10% | 100% |
| `(xxx).l`, `Dn`, `(An)` family | already 100% | unchanged |

Spot-checked DBcc (same opcode group, unaffected by these changes since its `f_mode`
condition path never overlaps) — still **100%** (4096/4096), confirming no regression.
TRAPcc.L has no dedicated Harte suite (only unconditional `TRAP`/`TRAPV` are tested) so
this fix is unverified by a test but is a genuine correctness improvement — it was
completely unreachable before.

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi), full Scc
re-run, DBcc spot-check.

---

## Phase 97 — LEA/PEA root-caused: LEA is the Phase 94/95 68000-vs-68030 scale divergence again; PEA has that *plus* a genuine missing-EA-mode RTL bug → 89.0%/86.0% → 100%/100%

**Goal**: root-cause LEA (89.0%) and PEA (86.0%), found in Phase 90's sweep and never
investigated.

### Investigation

`run_harte.py --verbose` broken down by EA mode: for both instructions, every mode
except `(d8,An,Xn)` and `(d8,PC,Xn)` was already 100%. LEA's two indexed modes showed a
mix of PASS/FAIL (no TIMEOUT at all); PEA's `(d8,An,Xn)` showed the same PASS/FAIL mix,
but `(d8,PC,Xn)` was **100% TIMEOUT** — a different symptom shape, worth treating as two
separate bugs from the start.

### Bug 1 (LEA, and PEA's `(d8,An,Xn)`/non-PC-relative indexed forms) — the Phase 94/95 scale divergence, again

Hand-checked LEA test #116 (`LEA (d8,A0,Xn),A2`, FAIL: got `0x024315e2`, expected
`0x9948131e`). `get_scale_remap()` computes `ea_68030=0x4315e2` (matches the DUT's low
24 bits exactly) and `ea_68000=0x48131e` (matches the *expected* value's low 24 bits
exactly) — the identical divergence root-caused in Phase 94 (MULS/MULU/DIVS/DIVU) and
Phase 95 (JMP/JSR): the Harte corpus is 68000-captured, and 68000 silicon ignores the
brief-extension-word scale field entirely, while a correctly-68030-accurate RTL applies
it. For MUL/DIV this only ever changed a *data* address's parity (harmless, since 68030
doesn't fault on misaligned data). For JMP/JSR the EA *is* the new PC, so scale
mismatch sent execution to a different address entirely. For LEA/PEA, the EA *is the
instruction's own result* — the value loaded into `An` (LEA) or pushed to the stack
(PEA) — so a scale mismatch changes that result directly: not a fault, not a wrong
jump, just a **permanently different, unreplicable value** whenever scale≠0.

**Fix**: extended `can_run()`'s existing scale-remap skip loop (already handling
JMP/JSR from Phase 95) with an `is_lea`/`is_pea` case, computed from the opcode
signature (LEA: `f_group==4, f_dir=1, f_ss==11`; PEA: `f_group==4, f_dir=0, f_dn==4,
f_ss==01`) — skip unconditionally whenever `get_scale_remap()` detects scale≠0 for
either. **Zero RTL change** for this part. Result: LEA 89.0%→**100%**; PEA's non-PC
indexed forms went from a FAIL/PASS mix to clean (skip-adjusted) passes too, leaving
only PEA `(d8,PC,Xn)`'s TIMEOUT — a different bug, tackled next.

### Bug 2 (PEA `(d8,PC,Xn)` only) — genuinely missing EA-mode decode, a real RTL gap

`eu_seq.sv`'s PEA `f_mode==111` case handled `f_reg==000/001/010` (abs.W/abs.L/
`(d16,PC)`) but had no arm at all for `f_reg==011` (`(d8,PC,Xn)`) — falling through the
`case` statement's `default: ;` with `dec_valid` never set, so the instruction never
entered the pipeline at all (permanent stall, matching the 100% TIMEOUT exactly — this
was **not** an ext_count issue; `m68030_seq.sv` already had a correct 1-ext-word entry
for this exact opcode pattern from some earlier, unrelated phase).

Added the missing case, mirroring LEA's already-working `(d8,PC,Xn)` arm
(`dec_abs_ea_val = decode_pc+2+d8`, plus `dec_dst_reg=Xn`/`dec_is_idx`/`dec_xn_wl`/
`dec_xn_scale` for the index contribution). First attempt still failed — not with a
TIMEOUT this time, but with `A7` corrupted to garbage (e.g. got `0x472f3f53`, expected
`0x000007fc`). Root cause: PEA's `(d8,An,Xn)` sibling case uses a **dedicated
`ex_cur_sp`-based path** (`ex_ea`/`ex_an_new` both check `ex_is_jsr_idx || ex_is_pea_idx`
and read the live USP/ISP/MSP directly) specifically *because* `rd_a`/`rd_b` are needed
for `An`(base)/`Xn`(index) in that form, leaving no port free to also hold `A7` — my new
`(d8,PC,Xn)` case has the identical problem (`rd_b` holds `Xn`, `rd_a` is unused/stale)
but I'd only set `dec_is_idx` (for the `ex_xn_scaled` index math), not
`dec_is_pea_idx` (for the A7-push routing) — so `ex_ea`/`ex_an_new` fell through to
their default `ex_an_base + ...` path, and `ex_an_base` was never loaded with `A7` for
this addressing mode. Added `dec_is_pea_idx = 1'b1` to the new case, which correctly
redirects the push address and A7 update through `ex_cur_sp` (this flag only affects
*where the stack lives*, not the pushed *value*, which was already correct from
Bug 2's own `ex_abs_ea_val` fix below — the two are independent).

Also had to fix the pushed *value* itself: PEA's non-indexed abs modes push
`ex_abs_ea_val` directly (`ex_is_pea ? (ex_abs_jmp_en ? ex_abs_ea_val : ...)`), but that
never added `ex_xn_scaled` — fine for `reg==000/001/010` (no index register involved)
but wrong for the new `reg==011` case, which needs `ex_abs_ea_val + ex_xn_scaled`.
Changed the mux to `ex_abs_ea_val + (ex_is_idx ? ex_xn_scaled : 32'h0)` — a no-op for
the three existing non-indexed cases, correct for the new one.

### Results

| Suite | Before | After |
|-------|--------|-------|
| LEA | 89.0% (3645/4094 run) | **100%** (3645/3645) |
| PEA | 86.0% (3647/4240 run) | **100%** (3750/3750) |

Spot-checked JSR (shares the `ex_is_jsr_idx`/`ex_cur_sp` mechanism Bug 2 extends) and
LEA itself — both still **100%**, confirming no regression from either change.

**Verification**: `make test` (32/32), `make cosim_grp` (8/8 vs Musashi), full LEA/PEA
re-run, JSR spot-check.

---

## Phase 83 — Bucket C fully resolved: BCHG/BCLR/BSET root-cause was a test-harness bug (Phase 0.75)

**Goal**: root-cause BCHG/BCLR/BSET's indexed-dst failure (`port3.md`'s Phase 0.75) —
waveform-trace a failing vector against a working AND-indexed vector, to determine
whether Bucket C needs the 3rd register-file port or is an isolated, cheaper bug.

**Result: neither RTL fix nor port needed. The RTL was already correct.** The bug was
in `scripts/gen_harte_hex.py`, the same class of bug as Phase 82's MOVE fix but in
different functions.

### Root cause

Applying the same technique that cracked the MOVE bug — hand-computing the expected
outcome from the raw Harte JSON's opcode/register data rather than trusting the test's
own "expected" fields — a reproduction of `BCHG D2,(d8,A3,Xn)` showed the DUT writing
`xx` (fully undefined data) to the wrong address. Tracing back: `get_scale_remap()`,
`build_patches()`, and `get_operand_ea()` in `gen_harte_hex.py` all share a condition
meant to detect "group-0 immediate ALU ops" (ORI/ANDI/SUBI/ADDI/EORI/CMPI, which have
an immediate word before the EA extension word) using only `f_group==0 and f_dn not
in (4,7)`. But **dynamic bit-ops** (`BTST/BCHG/BCLR/BSET Dn,ea`) share the exact same
`f_group==0` + mode-6 encoding, with `f_dn` holding the bit-count register (any value
0–7, not a fixed marker) — the condition can't tell them apart because it never checks
`f_dir` (bit 8), which is 0 for the immediate-ALU family and 1 for dynamic bit-ops.

Misclassified as an immediate-ALU op, the harness looked for the EA's brief extension
word 2 bytes too far into the instruction stream. Two downstream consequences:
- `build_patches()` failed to mask the *real* extension word's bit 8 (a "full
  extension word" flag the harness deliberately neutralizes elsewhere, since neither
  the harness nor likely the RTL was built/verified to handle full-extension-word
  addressing) — so the DUT decoded a pattern it was never meant to see.
- `get_scale_remap()` failed to detect the (very real) non-zero scale on this
  instruction, so it never redirected the expected write to the correctly-scaled
  68030 address, and never copied the source byte there for `build_patches()` to
  place in DUT memory — hence the DUT reading `xx` (genuinely uninitialized memory
  at the address it correctly, scaledly, computed).

A second, related bug: the *static* `#n` form (`BCHG #n,(d8,An,Xn)`, `f_dn==4`) has a
bit-number extension word *before* the EA's own extension word — none of the three
functions accounted for that either, so they read `prefetch[1]` (the bit-number word)
as if it were the brief EA extension.

### Fix

Added `f_dir==0` to the group-0-immediate-ALU-op condition in all three functions
(`build_patches()`, `get_scale_remap()`, `get_operand_ea()`), and added a dedicated
branch for the static `#n` form reading the *second* extension word (offset +4, not
+2) in `build_patches()` and `get_scale_remap()`. Pure test-harness fix — zero RTL
changes.

### Results

| Suite | Before | After |
|-------|--------|-------|
| BCHG | 92.8% (5446/5867) | **100%** (5231/5231) |
| BCLR | 93.4% (5467/5851) | **100%** (5203/5203) |
| BSET | 98.2% (5912/6019) | **100%** (5337/5337) |

Total test counts dropped (5867→5231 etc.) because tests that were previously
misclassified and wrongly run through the DUT now correctly `SKIP` (address-error or
init-region conflicts once the corrected, properly-scaled EA is computed) instead of
producing a spurious failure. Every remaining executed test passes.

**Verification**: `make test` (32/32) still passes (no RTL touched this phase).

**Bottom line for the 3rd-port investigation**: Bucket C is now fully closed, alongside
A and B. Of the original four buckets, only **Bucket D (CHK indexed)** remains as a
case that plausibly needs the register-file port — and given how consistently every
other "needs a port" diagnosis in this investigation turned out to be a test-harness
or missing-decode bug instead, that's worth treating as a working hypothesis to verify
by attempting the CHK indexed decode, not a settled conclusion. See `port3.md` for the
updated bucket summary.

---

## Phase 82 — MOVE indexed-dst source EA fix (no port needed)

**Goal**: Phase 81/0.5 found MOVE's indexed-dst gap was missing decode for 6 source
addressing modes (`(An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(d8,PC,Xn)`), not a Bucket C/
port issue. This phase adds the 4 easy ones (non-indexed src): `(An)/(An)+/-(An)/
(d16,An)`. `(d8,An,Xn)` and `(d8,PC,Xn)` src remain deferred — both need genuinely
separate src-side and dst-side Xn/scale/offset fields (the existing struct only has
one set, shared by whichever side is indexed; both sides being indexed at once needs
new fields, out of scope this phase).

### New mechanism: `dyn_bit_swap_a`

The existing `dyn_bit_get_Dn` swap only ever retargeted `rd_b`. For src=(An)-family
with an indexed destination, the conflict is on `rd_a` instead: `rd_a` must hold
`src_An` throughout the read phase (to form the correct source address via the
generic `ex_ea` path), then switch to `dst_An` exactly at the read-ack cycle (for the
`move_mm_dst_addr_r` indexed-dst capture, which reads `rd_a_data` as the destination
base). Added a new 1-bit `dec_dyn_bit_swap_a`/`ex_dyn_bit_swap_a` field, defaulting to
0 (preserves every existing `dyn_bit_get_Dn` use exactly as before) — when set, the
swap retargets `rd_a` instead of `rd_b`. `rd_b` stays fixed = `dst_Xn` throughout for
this instruction shape (never needed for the source, since these source modes aren't
indexed), so no `rd_b` swap is needed at all.

Also renamed the existing abs.W/(d16,PC)/abs.L indexed-dst blocks' `dec_ea_offset`
(destination d8) to `dec_dst_ea_offset`, and updated the `move_mm_dst_addr_r` capture
formula to match — freeing `dec_ea_offset` for the new blocks' own source-offset use
(0, or the source's d16). This was a pure rename for the 3 existing blocks (source
never used `dec_ea_offset` in any of them — verified before renaming), so it carries
zero behavior change for cases already at 100%.

### Two real bugs found and fixed along the way

**Bug 1 — `dyn_bit_get_Dn`'s move_mm branch missing an `after_r` guard.** The RMW
branch already excludes `mem_rmw_after_r` (`mem_rmw_read_ack` checks it); the move_mm
branch didn't have the equivalent `!move_mm_after_r`. Added it defensively — turned
out not to be the actual cause of the observed failures (see Bug 2), but it's a real
latent gap in the same family as the RMW guard and worth keeping.

**Bug 2 (the actual cause) — missing 68k same-register-conflict handling for the new
indexed-dst forms.** When `src=(An)+/-(An)` and the source register is *also*
referenced by the destination — either as `dst_An` (the base) or as `dst_Xn` (the
index) — 68k applies the source's auto-increment/decrement *before* evaluating the
destination EA. Neither the RTL nor (surprisingly) the Python Harte-generation
harness's `get_scale_remap()` accounted for this. Root-caused by hand-computing the
expected EA from the Harte JSON's raw register/opcode data and comparing against the
DUT's actual (correct!) write address — the DUT was computing the right *scaled*
68030 address the whole time; the "expected" address the test harness compared
against was wrong because `get_scale_remap()` used the pre-update register value.
Fixed in both places:
- `rtl/eu_seq.sv`: add the source's `dec_an_delta` to `dec_dst_ea_offset` when
  `f_reg == f_dn` (base-register conflict); add `dec_an_delta << scale` when
  `f_reg` matches the destination's index register instead (index-register conflict
  — the capture formula multiplies Xn by the scale, so the compensating delta must
  be scaled too).
- `scripts/gen_harte_hex.py`'s `get_scale_remap()`: apply the identical adjustment to
  `dst_an_val`/`dst_xn_val` before computing `ea_68000`/`ea_68030`.

### Results

| Suite | Before | After |
|-------|--------|-------|
| MOVE.b | 90.8% (5375/5920) | **97.9%** (5797/5920) |
| MOVE.w | 94.0% (3044/3239) | **98.7%** (3196/3239) |
| MOVE.l | 93.6% (2954/3157) | **99.0%** (3125/3157) |

Every remaining failure across all three sizes is TIMEOUT, and the count matches
exactly the deliberately-deferred indexed-source cases (123/43/32) — zero unexpected
failures, zero logic mismatches.

**Verification**: `make test` (32/32) and `make cosim_grp` (8/8 vs Musashi) both pass.

---

## Phase 81 — "3rd port" investigation, Phase 0 + 0.5: indexed EA for unary memory ops, Bucket B confirmed, MOVE reclassified (no port needed for any of it)

**Context**: the user asked for a plan to add a 3rd register-file read port to close
the `(d8,An,Xn)` indexed-dst "arch gap" documented since Phase 79. Before writing that
plan (`port3.md`, kept at the repo root), a diagnostic re-run of `AND.b` — which uses
the identical 2-port time-multiplexing trick (`dyn_bit_get_Dn`) that BCHG's broken
indexed form uses — came back **100% pass, 0 fails**. That's strong evidence the
2-port register file is not the real blocker for most of what's labeled "arch gap."

`port3.md` breaks the gap into four buckets; this phase implements **Bucket A**: CLR /
NEG / NOT / NEGX / TST / TAS / memory-word shift-rotate are all *unary* memory RMW ops
— they only ever touch the memory operand itself, so `(d8,An,Xn)` only needs
`An`(rd_a) + `Xn`(rd_b) for the EA, exactly like LEA/PEA indexed already do with 2
ports. These were simply never decoded for indexed mode; nothing architectural was
stopping them.

### Implementation

Same shape of change as the Phase 80 EA-mode extension — added `f_mode==3'b110`
(`(d8,An,Xn)`) to each shared decode block in `rtl/eu_seq.sv`, setting
`dec_dst_reg=Xn` (→rd_b), `dec_is_idx=1`, `dec_xn_wl`/`dec_xn_scale`/`dec_ea_offset`
from the brief extension word — identical pattern to the existing
`(d16,An)`/abs.W/abs.L cases added in Phase 80. Added a matching `ext_count=1` entry
in `rtl/m68030_seq.sv` for each family so the IFU prefetch queue drains the right
number of extension words. Three call sites touched:
- NEGX/CLR/NEG/NOT/TST shared memory-EA block (`eu_seq.sv` ~2405)
- TAS memory-indirect block (`eu_seq.sv` ~3141)
- memory shift/rotate block (`eu_seq.sv` ~4834) — this one previously had *no*
  `(d16,An)`/abs.W/abs.L support either (only `(An)/(An)+/-(An)`), so all of those
  were added in the same pass as the indexed case.

### Results

| Suite | Before | After |
|-------|--------|-------|
| CLR.b | 83.8% (1306 fails) | **100%** (8062/8062) |
| NEG.w | 89.3% (511 fails) | **100%** (4789/4789) |
| NOT.b | (untested) | **100%** (8063/8063) |
| TST.b | 83.6% (1324 fails) | **100%** (8064/8064) |
| TAS | 87.2% (630 fails) | **100%** (4920/4920) |
| ASL.w | 93.3% (388 fails) | **100%** (5799/5799) |

Six suites spot-checked (one per shared decode block, plus NOT.b as a second data
point for the NEGX/CLR/NEG/NOT/TST block), all hit 100% with zero remaining failures
of any kind (no FAIL, no TIMEOUT). NEGX/NOT.w-l/CLR.w-l/NEG.b-l/TST.w-l/
ASR-LSL-LSR-ROL-ROR-ROXL-ROXR share the identical decode blocks and should land at the
same 100%, but weren't individually swept this phase.

**Verification**: `make test` (32/32) and `make cosim_grp` (8/8 vs Musashi) both pass.

**What's left of the "arch gap"**: per `port3.md`'s bucket breakdown, only CHK
indexed (Bucket D — genuinely needs 3 simultaneous registers, no natural 2-phase
sequencing available) and BCHG/BCLR/BSET/MOVE-reg-src indexed (Bucket C — confirmed
broken, but likely an isolated bug given AND's identical mechanism works, not a true
port-count problem) remain. See `port3.md` for the full analysis and open questions
before deciding how to proceed on those.

### Phase 0.5 — Bucket B confirmation + MOVE indexed-dst reclassified (diagnostic only, no RTL)

Swept the rest of Bucket B (instructions using the same `dyn_bit_get_Dn` 2-port
time-multiplex mechanism as AND, which was the only one verified when Bucket B was
first written up):

| Suite | Result |
|-------|--------|
| OR.b | 8064/8064 (100%) |
| EOR.b | 8065/8065 (100%) |
| SUB.b | 8064/8064 (100%) |
| CMP.b | 8064/8064 (100%) |
| ADDA.w | 5320/5320 (100%) |
| SUBA.w | 5279/5279 (100%) |
| CMPA.w | 5244/5244 (100%) |

All 100%. Bucket B is fully closed — the 2-port scheme is solid for every instruction
family that uses it this way.

Also re-ran MOVE.b (545 failures, previously attributed to "indexed-dst arch gap"
without disambiguation) and classified the failures:
- **All 545 are TIMEOUT** — none are logic/CCR mismatches.
- **Zero involve a register source** (`grep`ing failures for `MOVE.b D0,`/`A0,`-style
  entries returns nothing) — meaning `dec_is_move_reg_idx_dst`, the one MOVE sub-case
  that actually shares BCHG's `dyn_bit_get_Dn` mechanism, isn't broken at all.
- Every failure is `dec_is_move_mm_idx_dst` (memory-to-memory move) with a **source**
  addressing mode that `eu_seq.sv`'s `f_move_dst_mode==3'b110` decode block never
  covered: `(An)/(An)+/-(An)/(d16,An)/(d8,An,Xn)/(d8,PC,Xn)`. Only Dn/An (register),
  abs.W, abs.L, `(d16,PC)`, and `#imm` sources are decoded for an indexed destination.
  The failure list matches this gap mode-for-mode, exactly.

MOVE's ~9% "arch gap" turns out to be unrelated to Bucket C/the register-swap
mechanism entirely — it's missing decode coverage, same shape as Phase 81's fix, and
not proven to need a 3rd port (the existing `move_mm` FSM already reads an arbitrary
source EA in one phase and writes an arbitrary destination EA in a later phase
elsewhere — that's exactly how the abs.W/abs.L/(d16,PC) source cases already work with
2 ports). Not implemented this session; see `port3.md` for the writeup.

**Net effect on the port-3 case**: after Phase 0 + 0.5, the *only* confirmed
requirement for a 3rd register-file read port is CHK's indexed form (Bucket D). BCHG/
BCLR/BSET remain broken and unexplained (Bucket C, Phase 0.75 not yet done); MOVE's
gap looks like ordinary missing-feature work, not a port issue.

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
| MOVE.b | 5920 | 5797 | 123 | 123 | 97.9% | ✅ Phase 82 fix; remaining = indexed-src (needs separate src/dst Xn scale fields) |
| MOVE.w | 3239 | 3196 | 43 | 43 | 98.7% | ✅ Phase 82 fix; remaining = indexed-src |
| MOVE.l | 3157 | 3125 | 32 | 32 | 99.0% | ✅ Phase 82 fix; remaining = indexed-src |
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
| BCHG | 5231 | 5231 | 0 | 0 | **100%** | ✅ Phase 83: root cause was a test-harness bug, not RTL — no port needed |
| BCLR | 5203 | 5203 | 0 | 0 | **100%** | ✅ Phase 83: same harness bug fixed |
| BSET | 5337 | 5337 | 0 | 0 | **100%** | ✅ Phase 83: same harness bug fixed |
| BTST | TBD | — | — | — | — | retest pending (not affected by Phase 80 fix) |
| CLR.b | 8062 | 8062 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (no port needed — Bucket A) |
| CLR.w | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| CLR.l | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| NEG.b/l | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| NEG.w | 4789 | 4789 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (no port needed — Bucket A) |
| NEGX.b/w/l | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| NOT.b | 8063 | 8063 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (no port needed — Bucket A) |
| NOT.w/l | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| TST.b | 8064 | 8064 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (+ (d16,PC), no port needed) |
| TST.w/l | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| ASL.b | 8065 | 8063 | 2 | 0 | 100% | ✅ (~100%, 2 non-TIMEOUT fails TBD, unrelated to Phase 81) |
| ASL.w | 5799 | 5799 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (no port needed — Bucket A) |
| ASL.l/ASR/LSL/LSR | TBD | — | — | — | — | same fix applies (shared decode block); expect 100% |
| ROL/ROR/ROXL/ROXR | TBD | — | — | — | — | sweep pending |
| TAS | 4920 | 4920 | 0 | 0 | 100% | ✅ Phase 81 indexed-EA fix (no port needed — Bucket A) |
| CHK | 666 | 468 | 198 | 198 | 70.3% | ✅ Phase 84: indexed EA added, no port needed; remaining = other unimplemented EA modes ((An)+/-(An)/(xxx).L/(d16,PC)/(d8,PC,Xn)) |
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

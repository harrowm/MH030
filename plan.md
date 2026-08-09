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

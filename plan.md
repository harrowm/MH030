# Phase Log

Running writeup of each completed phase in this project, in order. For
Phases 1-161 (through the Chapter 11 Part A/B timing-verification plan),
see `plan.md.old` -- archived because it had grown to ~9500 lines. For
Phases 162-249 (through Phase 248's own MC68030UM.pdf compliance review
and Phase 249's IACK-BERR wiring fix), see `plan.md.old2` -- archived
because it had, in turn, grown to ~8800 lines, mirroring the exact same
pattern. `CLAUDE.md` keeps a one-paragraph summary of each phase plus the
current overall project state (and itself has a `CLAUDE.md.old` for its
own full pre-condensation history, archived separately at Phase 225); this
file holds the full writeup each summary links back to.

## Phase 250 (second MC68030UM.pdf chapter-by-chapter compliance review --
findings list built, none fixed yet)

User asked for a second, independent chapter-by-chapter review of the RTL
against MC68030UM.pdf, following on from Phase 248's own first pass (10
items, closed in full). Rather than re-covering the chapters Phase 248
already exhaustively worked (Ch.5 Signal Description, Ch.6 Cache, Ch.7 Bus
Operation, Ch.8 frame formats, Ch.9 MMU, Ch.11 Timing), this pass focused
on the chapters that got only indirect/"light touch" coverage last time --
Ch.2 (Data Organization and Addressing), Ch.3 (Instruction Set Summary),
Ch.4 (Processing States), Ch.12 (Applications Information) -- plus a fresh,
independent re-derivation of Ch.8's exception vector table/priority scheme
(never exhaustively cross-checked even by Phase 248) and a regression-
focused spot-check of Ch.7's CAS2/MOVEP cycles. Three parallel research
forks covered Ch.2/3, Ch.4, and Ch.12+spot-checks; the exception-vector/
priority work and the RMW/CAS2 AS# re-derivation were done directly in the
main session, the latter specifically because it contradicts a large body
of prior, heavily-verified work (Phases 108-114, 207, 232, 241, 242) and
warranted independent visual confirmation against the actual PDF page
images (not just OCR'd text, which this manual's own extraction has
proven repeatedly unreliable on -- garbled `$` signs, ambiguous nibble
digits, misplaced table rows) before being trusted at all.

**This phase is investigation only -- a findings list, matching Phase
248's own "build the list, then decide what to fix and in what order"
discipline. Nothing below has been fixed yet.** Ten findings, tiered by
risk/confidence:

### Tier 1 -- highest stakes, needs a dedicated re-investigation before any code changes

**F1. RMW/CAS2/CAS may be holding AS# asserted when real silicon negates it
between the read and write phases.** Visually confirmed directly against
Figure 7-29 (Asynchronous Read-Modify-Write Cycle Flowchart, MC68030UM.pdf
p.7-44/PDF page 205) and cross-checked against Figure 7-30's own timing
diagram (p.7-45/PDF page 206) -- not from the OCR text dump, which is
unreliable in exactly this area, but from the rendered page images
themselves. Figure 7-29's "ACQUIRE DATA" box (the read-phase completion)
reads, verbatim: "1) Sample cache inhibit in (CIIN) / 2) Latch data /
**3) Negate AS and DS** / 4) Negate DBEN / 5) Start data modification".
Its "START OUTPUT TRANSFER" box (write-phase start) reads: "1) Assert
ECS/OCS for one-half clock / 2) Drive address on A0-A31 (if different) /
3) Drive size / 4) Set R/W to write / 5) CIOUT becomes valid /
**6) Assert AS** / 7) Assert DBEN / 8) Place data on D0-D31 / 9) Assert
DS" -- ECS/OCS reasserting and AS explicitly re-asserting, exactly like a
fresh S0/S1 bus-cycle dispatch. RMC stays asserted throughout (confirmed,
matches this project's own model -- the CPU never releases bus ownership,
so no other master can interrupt the sequence), but the **AS/DS pins
themselves toggle** between the read and write phases on real silicon.
This appears to directly contradict:
  - `rtl/biu_cycle_gen.sv`'s `rmw_as_hold` (suppresses AS-negate between
    RMW read and write), `cas2_as_hold` (holds AS across all 4 CAS2
    sub-cycles), and `cas_as_hold` (Phase 242's own CAS bus-lock fix,
    modeled explicitly on "the same genuine bus-level lock guarantee RMW
    and CAS2 already had" per that phase's own writeup -- meaning if RMW/
    CAS2's own model is wrong, Phase 242 imported and extended the same
    mistake rather than fixing a real gap).
  - CLAUDE.md's own current "S-State Signal Timing" section, which states
    as project doctrine: "AS stays continuously asserted across the whole
    indivisible read+write sequence (Figure 7-30), never negating between
    the two phases" -- directly contradicted by Figure 7-29's own explicit
    "Negate AS and DS" / "Assert AS" flowchart steps just described.

This is flagged, not fixed. Given the blast radius (Phases 108-114 RMW/
CAS2 timing redesign, Phase 207 RMW S1/S3 stagger, Phase 232 BERR-during-
fill, Phase 241/242 the CAS bus-lock plan -- all built on the "AS never
negates" premise, and Phase 233/241's own investigation history already
shows how easy it is to get RMW/CAS2 pin-continuity subtly wrong even
when trying hard to get it right), the next step should be a dedicated
investigation phase: re-derive Figure 7-29/7-30 fresh, build a `tb/
biu_tb.sv`-level direct-signal test proving today's actual AS behavior one
way or the other, and only then decide whether this is a real regression
to fix or a documentation-only correction (e.g. if some other passage
elsewhere in Chapter 7, not yet found, genuinely does describe AS staying
asserted for some narrower RMW/CAS2 sub-case this flowchart doesn't
cover). Do not touch `biu_cycle_gen.sv`'s hold logic without that
dedicated pass -- this is the single highest-blast-radius shared pin/
arbitration logic in the project by this file's own repeated framing
(Phase 233, 241, 242).

### Tier 2 -- confirmed bugs, clear fixes, moderate risk

**F2. `MOVES` has no privilege check.** MC68030UM.pdf §4.2 states
supervisor programs use MOVES to access other address spaces via SFC/DFC
-- it is a privileged instruction. All four MOVES decode arms in
`rtl/eu_seq_decode.svh` (register-indirect ~1096-1121, `(d16,An)` ~1123,
`(d8,An,Xn)` ~1150, `(xxx).W` ~1173) have no `sr_live[13]` gate and never
set `dec_is_priv`, unlike every other privileged instruction in the file.
User-mode code can currently read/write supervisor address spaces with no
trap. Confirmed bug.

**F3. `PFLUSH`/`PLOAD`/`PMOVE`/`PTEST` have no privilege check.** Table
3-14 states each of these four MMU instructions traps if not in supervisor
state. The MMU cpid=0 dispatch block in `rtl/eu_seq_decode.svh` (~6117-
6230, covering `mmu_op_type` cases for all four) has no `sr_live[13]`
check -- notable by direct contrast with the immediately preceding
cpSAVE/cpRESTORE block (same F-line region, cpid=1) which correctly gates
on `!sr_live[13]`. User-mode code can currently reconfigure the MMU
(PMOVE to TC/CRP/SRP/TT0/TT1), flush the ATC (PFLUSH/PFLUSHA), or issue
PLOAD/PTEST with no trap. Confirmed bug.

**F4. CHK2/CMP2's C-flag formula omits the wrapped-range case (UB<LB).**
Table 3-12 gives: `C = (LB<=UB) AND ((R<LB) OR (R>UB))  OR  (UB<LB) AND
(R>UB) AND (R<LB)` -- a documented 68020+ feature: when the upper bound
is numerically less than the lower bound, the pair is interpreted as a
wrapped/circular range. `rtl/eu_seq_execute.svh:724-725`
(`cmp2_c_w = (R<LB) || (R>UB)`) only implements the `LB<=UB` branch
unconditionally. Concrete failure: LB=10, UB=5 (a wrapped range), R=3 --
manual gives C=0 (R is within the wrapped-valid region), RTL computes C=1.
This same signal directly gates the CHK2 trap condition
(`eu_seq_execute.svh:4677`), so real software using the documented
wrapped-bounds idiom would get spurious or missing CHK2 traps, not just a
wrong flag value. Zero Tom Harte coverage (68020+-only). Confirmed bug.

**F5. Format $9 ("MMU short bus fault," 12 words) does not exist on real
MC68030 silicon.** Visually confirmed against Table 8-6 Sheet 1
(MC68030UM.pdf p.8-33/PDF page 300): Format $9 is the **Coprocessor
Mid-Instruction stack frame, 10 words**, used for Coprocessor
Mid-Instruction / Main-Detected Protocol Violation / Interrupt Detected
During Coprocessor Instruction -- entirely unrelated to the MMU. Real
MMU-detected bus faults on the 68030 use the ordinary Format $A (16
words, bus error at instruction boundary) or Format $B (46 words, bus
error mid-instruction-execution) like any other bus error, distinguished
only by the SSW/DF bits, not by a dedicated format code.
`rtl/biu_exc_capture.sv`'s `determine_format()` invents Format $9
specifically for `mmu_fault`, self-consistently baked into
`rtl/m68030_exc.sv`'s `FMT_MMU` constant, `rte_frame_extra()`, and
CLAUDE.md's own top-level frame-format table (which lists "$9 | 12 words
| MMU short bus fault" -- itself wrong on this same basis and needing a
correction once this is resolved). Self-consistent (this RTL's own RTE
accepts what its own BIU produces) but diverges from real 68030
architecture -- any comparison against a real hardware or Musashi bus
trace for an MMU fault would mismatch on the format code and frame size.
Existing test coverage (`tb/exc_tb.sv` EXC-9, `tb/mmu_xlate_tb.sv` Phase
3/4) directly asserts the *invented* Format $9 behavior, so a fix here
needs those tests re-derived to expect $A/$B instead, keyed on whatever
distinguishes "at instruction boundary" from "mid-execution" for an MMU
fault specifically (the manual's own SSW/pipe-stage bits, already
partially modeled via `pipe_b_active`/`pipe_c_active` stubs in
`biu_exc_capture.sv`). Confirmed bug, moderate-to-large fix.

**F6. RTE never checks the long-bus-fault-frame version number.**
§8.1.8: for Format $B specifically, RTE must compare the version-number
nibble at SP+$36 (bits[15:12]) against the processor's own internal
version, raising Format Error (vector 14) on mismatch -- "This validity
check is required in a multiprocessor system to ensure the data is
properly interpreted." `rte_fmt_valid()` in `rtl/eu_seq_execute.svh` only
checks the format-code nibble (accepting $0/$2/$3/$4/$8/$9/$A/$B), never
this field. No version-number value is populated anywhere when
constructing Format $B frames either. Confirmed gap; low urgency (single-
CPU project, but a real compliance gap for any software that manually
constructs/patches a Format $B frame with a bad version field, which
real 68030 code is documented to be able to detect).

**F7. Exception priority-chain order in `m68030_exc.sv` doesn't match
Table 8-5.** Two specific mismatches found in the `always_comb` priority
chain (~lines 178-218):
  - `bus_err_req` is checked before `addr_err_req`. Table 8-5 ranks
    Address Error (1.0) strictly higher priority than Bus Error (1.1).
    `bus_err_req_w = ifu_bus_err | eu_bus_err_r` and `addr_err_req =
    ifu_addr_err_int` come from independent sources (IFU fetch-parity
    check vs. an external BERR on a completed bus cycle), so they are not
    obviously mutually exclusive -- plausible, not yet proven reachable.
  - `int_pending && int_ready` is checked 3rd in the chain -- immediately
    after bus/addr error, ahead of `illegal_req`/`priv_req`/`trace_req`/
    `chk_req`/`div_zero_req`/`trapv_req`/`trap_req`. Table 8-5 places
    Interrupt at priority 4.2, the single LOWEST priority of every
    exception in the entire table -- strictly below all of the above
    (Illegal/Priv/LineA/LineF are tier 3; CHK/CHK2/TRAPcc/TRAPV/Zero
    Divide/MMU-Config/TRAP#n are tier 2). `eu_int_ready = int_defer =
    dec_valid && !stall_base && int_pending` fires as soon as an
    instruction reaches decode with an interrupt pending -- if that exact
    cycle also has, say, `illegal_req` or `chk_req` true for an
    instruction already in EX, this chain would incorrectly let the
    interrupt preempt an exception the manual ranks strictly higher.
    Reachability (can these two conditions genuinely coincide given this
    project's actual pipeline staging) was not confirmed this phase --
    needs dedicated tracing of `dec_valid`/`ex_valid` relative timing, or
    a constructed test, before treating this as a live bug rather than a
    latent one. Plausible, needs investigation.

### Tier 3 -- scope/identity question, not a simple bug fix

**F8. MOVE16 does not exist on the MC68030 -- it is an MC68040
instruction.** Exhaustive text search of the full manual (~27,800 lines,
`pdftotext -layout`) found zero occurrences of "MOVE16" anywhere.
Appendix A's own complete "MC68020 and MC68030 Instruction Set
Extensions" table (p.A-3/A-4) -- which correctly lists CAS/CAS2/CHK2/
CMP2/PACK/UNPK/BFxxxx/TRAPcc/PFLUSH/PLOAD/PMOVE/PTEST, and correctly
flags CALLM/RTM as "New Instruction (MC68020 only)" -- does not include
MOVE16 at all. MOVE16 is a real M68000-family instruction, but it belongs
to the 68040 (introduced for its cache-line burst move), not the 68020 or
68030. This project fully implements it as real, working, cycle-accurate
silicon behavior: `rtl/eu_seq_decode.svh:6008-6034` decodes the four
`$F6xx` forms, `rtl/biu_burst_ctrl.sv`/`rtl/biu_cycle_gen.sv`/
`rtl/m68030_biu.sv:1091` implement its own dedicated burst-write bus
protocol, `rtl/eu_seq_execute.svh` has a dedicated MOVE16 FSM
(`ex_is_move16`/`ex_move16_form`), and CLAUDE.md's own "BIU Cycle Types"
list documents it as a required cycle type. On real 68030 silicon this
opcode range ($F600-$F7FF, cpID=1 by the F-line encoding) is coprocessor
space; real hardware would attempt genuine coprocessor communication (or
fault) rather than perform a memory-to-memory burst move. This is very
likely inherited from `output.txt`'s original, never-manual-verified
design conversation -- the same root-cause class CLAUDE.md's own
"S-State Signal Timing" section already found once for the LDS/UDS-vs-
single-DS conflation, and Phase 248 item #6 found again for VPA/E-clock.
Needs a decision, not just a fix: remove MOVE16 entirely and let that
opcode space fall through to whatever real coprocessor-space handling
this project has (out-of-scope per Phase 248 item #7 for the conditional
coprocessor instructions specifically, but general CIR access IS
implemented per Phase 157/199), or deliberately keep MOVE16 as a
documented, intentional extension beyond real 68030 scope. This is a
structural, multi-file removal/rework if the former is chosen -- not
attempted this phase.

### Tier 4 -- low risk / opportunities, not urgent

**F9. STOP + trace (T1=1,T0=0) interaction -- plausible, not confirmed.**
§8.1.7: STOP that begins execution with tracing enabled must force a
trace exception after loading SR, and never actually enter the stopped
condition. The RTL's SR write (`stop_sr_wr_en`) fires unconditionally
(correct -- SR loads regardless of tracing) and the generic trace
mechanism evaluates T1/T0 correctly, but the STOP FSM
(`eu_seq_execute.svh:2543-2553`) sets `stop_r <= 1'b1` with no exclusion
for `ex_is_trace`, before it self-clears once the trace exception's own
dispatch reaches `EXC_LOAD`. Appears self-correcting with no externally
observable STOPPED-state behavior (bus cycles don't pause on `stop_r`
alone), but timing was not fully traced to rule out a race. Worth a
closer look, not confirmed as a functional bug.

**F10. STATUS pin's double-bus-fault case is a narrow, tractable
follow-up to Phase 248 item #5/#10's own deferral.** Chapter 12's own
STATUS-encoding table (Table 12-4) shows STATUS has 4 distinct meanings:
1-clock (instruction boundary), 2-clock (trace/interrupt dispatch),
3-clock (MMU/reset/BERR/etc. dispatch) -- all three needing real
microsequencer-cycle correlation this project's structurally different
microarchitecture has no faithful analogue for, matching Phase 248 item
#5's existing deferral reasoning exactly -- and **continuously asserted
= processor halted due to double bus fault**, which is NOT
microsequencer-timing-dependent at all: it's just a sticky bit, and this
project already computes exactly that condition
(`rtl/biu_error_handler.sv`'s `halt_out`, confirmed correct and precisely
documented as of Phase 248 item #10) but never wires it to any output
pin. Low-risk, narrow, optional enhancement if the user wants a real
STATUS pin for this one sub-case specifically, distinct from the full
microsequencer-status decode which should stay deferred.

**Confirmed compliant, re-verified, no action needed**: MOVEP's byte-
interleaved addressing pattern (`Dn[31:24]<->An+d`, etc., matches Table
exactly); HALT input-only (reconfirms Phase 248 item #10 against Chapter
12's own independent restatement); every OTHER privilege check already in
place (STOP/RESET/RTE/MOVE-to-SR/ANDI-ORI-EORI-to-SR/MOVE-An-USP/MOVEC-
write/cpSAVE/cpRESTORE); STOPPED-state exit conditions (clears on reset
or any exception reaching `EXC_LOAD`, not just interrupts as a stale code
comment undersold); privilege-level S/M-bit save-and-force-supervisor
transitions (already fixed, Phase 248 item #2); full/brief extension-word
bit layout and Table 2-1's IS/I-IS indirection encodings (centralized
since the ext_count de-duplication plan, Phase 221-224); CAS/CAS2
register-field bit positions (already fixed, Phase 247 item #9, not
re-flagged); CCR-effect spot-checks for SWAP/EXG/TAS.

### Proposed next steps (as originally scoped; see "Execution update" below
for what was actually done)

Suggested order once resumed: F2/F3 (privilege checks) -> F4 (CHK2/CMP2
wrapped bounds) -> F6/F7 (RTE version check, priority-chain order) -> F5
(Format $9, including the CLAUDE.md frame-table correction and the two
existing tests that assert the wrong behavior today) as a batch of
well-understood, moderate-risk fixes with a normal mandatory-gate re-run
each; then a **dedicated, investigation-only phase on F1** (re-derive
Figure 7-29/7-30 fresh, build a direct-signal proof one way or the other,
decide fix-vs-document) before touching any RTL there, given the stakes;
and a **decision conversation on F8** (MOVE16) before any code changes,
since removal is a real scope change touching 4+ files and CLAUDE.md's
own architecture description, not a bug fix.

### Execution update (same session, immediately following the findings pass)

User asked to execute the plan. Worked the batch in the proposed order,
with one deviation: **F6 turned out significantly more invasive than
scoped once actually investigated**, and was deferred rather than pushed
through -- see below.

**F2/F3 (IMPLEMENTED AND VERIFIED)**: added the missing `if
(!sr_live[13]) dec_is_priv=1` gate to all 4 MOVES decode arms and the
whole MMU cpid=0 dispatch block (PFLUSH/PLOAD/PMOVE/PTEST) in
`eu_seq_decode.svh`, matching the exact idiom the directly-adjacent
cpSAVE/cpRESTORE block already used. New `tb/system_tb.sv` tests
PRIV-02..06 (one per instruction) confirmed to FAIL on baseline (stashed
the RTL fix, reran: all 5 failed with `priv_req` never firing) before
being confirmed to pass with the fix restored. Full mandatory gate clean.

**F4 (IMPLEMENTED AND VERIFIED)**: `eu_seq_execute.svh`'s `cmp2_c_w`
rewritten to implement Table 3-12's full formula (`LB<=UB` branch
unchanged; new `UB<LB` wrapped-range branch added). New
`tb/ea_extended_tb.sv` tests CMP2-02 (LB=10,UB=5,R=3 -- the exact
diverging case from the original finding, confirmed to fail on baseline
with C=1 instead of the correct C=0) and CMP2-03 (a non-diverging control
case, confirming the fix doesn't disturb an already-correct result). Full
mandatory gate clean.

**F7 (IMPLEMENTED AND VERIFIED)**: reordered `m68030_exc.sv`'s
`always_comb` priority chain to match Table 8-5 exactly: `addr_err_req`
now checked before `bus_err_req` (was reversed); `int_pending && int_ready`
moved from 3rd position to last (after `trap_req`), since Table 8-5 ranks
Interrupt (4.2) as the single lowest-priority exception in the entire
table. New `tb/exc_tb.sv` test EXC-16 -- built specifically to answer the
"is this race even reachable" question the original F7 finding left
open -- drives `illegal_req` and a genuinely-pending, unmasked interrupt
(`ipl_sync=3 > ipl_mask=1`, the same shape EXC-5 already uses) in the
exact same cycle. **Confirmed the race IS reachable**: baseline dispatched
the interrupt (fetching the autovector at VBR+0x6C, wrong per Table 8-5),
the fix dispatches Illegal Instruction (VBR+0x10, correct). Full
mandatory gate clean.

**F5 (IMPLEMENTED AND VERIFIED)**: `biu_exc_capture.sv`'s
`determine_format()` no longer takes an `mmu` parameter at all -- MMU
faults now fall through to the exact same `!rw ? $B : $A` rule every
other bus error already uses (the function's `mmu_fault` input port is
left connected but genuinely unused now, documented as such; removing it
entirely would require touching the module's callers in `m68030_biu.sv`,
judged unnecessary churn for a value that was never used for anything
else in this file). `m68030_exc.sv`'s own `FMT_MMU` constant renamed
`FMT_CPMID` and corrected to ITS real shape per Table 8-6 (10 words / 5
LW writes, not 12/6 -- the real Format $9 is Coprocessor Mid-Instruction,
which this project doesn't implement, same documented scope boundary as
the cpBcc/cpDBcc/cpScc/cpTRAPcc note); removed from `fmt_is_fault`'s
membership too, since the real Coprocessor Mid-Instruction frame has no
Data Output Buffer field the way $A/$B do (that field's step now defaults
to 0, matching every other unpopulated internal-register step). This
constant is now unreachable via any implemented trigger, kept defined
only for shape-consistency with `FMT_FPU_PI`/`FMT_FPU_PR`'s own
already-established "defined but never dispatched" treatment for other
out-of-scope coprocessor-related formats.

Updated two existing tests that directly asserted the old, fabricated
behavior: `tb/exc_tb.sv`'s EXC-9 (re-derived for the new 10-word/5-step
frame shape -- confirmed passing; now framed as testing the generic
format-$9 frame-shape infrastructure directly via injection, since
nothing in the real pipeline can reach it anymore) and
`tb/mmu_xlate_tb.sv`'s Phase 3/4 (which exercise a REAL MMU fault
end-to-end through the live pipeline -- Phase 3's fault is on a read
(`MOVE.L (A0),D4`), Phase 4's is on a write; predicted $A for Phase 3 and
$B for Phase 4 from the new `!rw` rule before running, then confirmed
both exactly as predicted). CLAUDE.md's own top-level frame-format table
corrected too (previously self-documented the same fabrication this
finding flagged). Full mandatory gate clean.

**F6 (investigated, deferred -- NOT implemented, more invasive than
scoped)**: building the fix immediately hit a scope surprise: RTE's own
`rte_phase_r` FSM only ever performs 2 bus reads total (format/vector+SR,
then PC) and determines how many EXTRA bytes to skip via
`rte_frame_extra()` -- it never actually reads back ANY of the rest of a
fault frame's own content (SSW, fault address, DOB, internal registers,
or critically the version-number word at SP+$36 this item needs to
check). A correct fix needs a genuinely NEW conditional bus read added to
RTE's own return-path FSM, specifically gated on Format $B. Weighed
against the check's own stated purpose (MC68030UM.pdf: "required in a
multiprocessor system" -- not applicable to this single-CPU project,
which only ever constructs and pops its own frames, so the check would
never fire in real usage, only via a deliberately-corrupted test frame)
and the risk of bolting new bus-read machinery onto RTE's delicate return
path without dedicated care, this was deferred with the precise scope
found above documented, rather than rushed through in the same batch as
the other four items -- matching this project's own established
precedent for "found harder than expected mid-implementation" (Phase
238/239's own TAS/Scc and ALU-EA/CMP2-CHK2 deferrals). No RTL or
testbench changed for F6.

**F8 remains untouched**, exactly as scoped in the original findings
pass above -- needs a user decision before any code changes.

Full mandatory gate (`make test` 37/37, `cosim_grp` 8/8, `cosim_memind`
28/28, `dat-synth` 50/50, full Harte sweep bit-identical to baseline --
`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`) re-run and confirmed clean
after EACH of F2/F3, F4, F7, and F5 individually, not just once at the
end.

### F1 dedicated investigation and fix (same session, user asked to
proceed directly to F1 after the batch above)

**Re-confirmed the finding with a second, independent manual source
before touching any RTL.** Beyond Figure 7-29 (Asynchronous RMW
Flowchart) already cited in the original finding, visually inspected
Figure 7-35 (Synchronous RMW Flowchart, PDF p.7-55) directly from the
rendered page image: identical pattern -- "TERMINATE INPUT TRANSFER"
box negates AS/DS ("1) Negate AS (and DS)"), "START OUTPUT TRANSFER" box
reasserts AS ("6) Assert AS"). Both flowcharts independently confirm the
same protocol, and both have CAS2-specific branch decisions built
directly into them (the "IF CAS2 INSTRUCTION AND ONLY ONE OPERAND
READ/WRITTEN..." diamond boxes), confirming the same negate-then-
reassert protocol was always intended to cover CAS2's own chained
sub-cycles too, not just plain single-operand RMW.

**Root-caused the original mistake.** Full-text search of the entire
~27,800-line manual for "maintains AS" returns exactly ONE match, and
it's not in the RMW section at all -- it's in **7.3.6/7.3.7 Burst
Operation Cycles**, State 3: "The processor maintains AS, DS, and DBEN
asserted during S3... for continuation of the burst." Burst mode's own
DS-continuity fix (same phases, 108-114/207) was a CORRECT application
of this text -- burst genuinely does hold AS/DS asserted across beats.
RMW/CAS2's own AS-continuity "fix," and Phase 242's CAS bus-lock
extension explicitly built on the same precedent ("the same genuine
bus-level lock guarantee RMW and CAS2 already had"), misapplied the
identical burst-mode quote to a different cycle type three separate
times.

**Traced the RTL to confirm the fix is cleanly isolated before touching
anything.** `bus_lock` (suppresses DMA/re-arbitration) and `rmc_active`
(drives the real `RMC#` pin) are both derived from `is_rmw_write`/
`is_cas2`/`eu_cas_hold` directly -- NEITHER is gated on
`rmw_as_hold`/`cas2_as_hold`/`cas_as_hold` in any way. This confirms
removing the three AS-hold overrides cannot touch bus arbitration or
RMC continuity at all -- only the AS *pin's* own toggling changes. Also
confirmed the underlying RMW/CAS2 state machine (Phase 207's own S0-S11
shape) already naturally produces the correct negate-then-reassert
behavior via its own existing per-sphase `ext_as_n` logic (`SP_S2`
asserts, `SP_S6`/`S7` default-negates for non-burst cycles) -- the three
overrides existed purely to SUPPRESS this already-correct behavior, so
removing them needed no compensating change anywhere else.

**Fix**: removed `rmw_as_hold`, `cas2_as_hold`, and `cas_as_hold` (and
the now-dead `is_cas2_r1_next`/`is_cas2_w1_next`/`is_cas2_r2_next`/
`is_cas2_w2_next`/`is_cas2_next` helper wires that only fed
`cas2_as_hold`) from `biu_cycle_gen.sv`, replacing each with a comment
explaining the correction and citing both flowcharts plus the burst-mode
root-cause finding. `eu_is_cas`'s own input port is now unused within
this module (only `cas_as_hold` consumed it) -- left in place rather
than threading its removal through every caller, documented as such.

**Test updates** (both previously asserted the OLD, now-confirmed-wrong
behavior as correct -- not something to preserve):
- `tb/biu_tb.sv`'s P15-1 (`--- RMW byte: AS# held through read→write
  gap ---`) rewritten to `--- RMW byte: AS# genuinely negates then
  reasserts through read→write gap ---`, asserting `ext_as_n` goes HIGH
  at least once between `ST_RMW_READ_S6` and `ST_RMW_WRITE_S1`, then LOW
  again by `ST_RMW_WRITE_S2`. Confirmed the ORIGINAL test failed reliably
  pre-fix (`FAIL [42525000] AS# no glitch through RMW gap`) via a full
  `sim/biu` run before making any RTL change; confirmed the rewritten
  test passes post-fix, along with the file's own separate, unrelated
  RMC-continuity checks (`RMC_n low during RMW read phase` /
  `RMC_n still low between RMW phases` / `RMC_n still low during RMW
  write phase` / `bus_lock asserted during RMW`) all still passing
  unchanged -- direct proof RMC/bus_lock are unaffected, not just an
  inference from the trace above.
- `tb/stall_fsm_tb.sv`'s AS-LOCK (CAS match case) rewritten: was
  `check32("...AS# negates exactly once across the whole read+write
  sequence...", negate_edges, 32'd1)`, now expects `32'd2` (once for the
  read's own completion, once for the write's own completion) --
  confirmed passing, with the file's OWN pre-existing arbitration-
  continuity checks in the same test (`IFU never granted the bus during
  CAS's own entire execution window` / `EU's own grant never dropped
  during CAS's own entire execution window`) needing NO changes and
  still passing -- this is the clearest available proof that the
  ownership-lock/pin-toggling distinction holds: a real, pending IFU
  contender genuinely never got the bus during CAS's execution, even
  though AS itself visibly toggled twice. AS-LOCK-MISMATCH (CAS's
  no-write mismatch path) needed no change -- it only ever has one
  assert/negate pair regardless of this fix, since there's no write
  phase to toggle between.

**Full mandatory gate re-run and confirmed clean**: `make test` 37/37
(including the two rewritten tests, `sim/biu` and `sim/stall_fsm`
individually re-verified beyond the aggregate `make test` pass),
`cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50, full 124-suite
Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2 SKIP 281221
TIMEOUT 0`) -- zero regressions anywhere despite touching the single
highest-blast-radius shared bus-protocol logic in the project (Phases
108-114/207/232/241/242 all previously built on the premise this
corrects). CLAUDE.md's own "S-State Signal Timing" section corrected to
match (previously stated the wrong model as established, verified fact).

**This closes F1.** Of the original 10-item Phase 250 findings list, F1/
F2/F3/F4/F5/F7/F8 are now IMPLEMENTED AND VERIFIED; F6 is investigated and
deferred (documented scope above); F9/F10 remain low-priority,
not yet actioned.

## F8 (MOVE16 removal) — IMPLEMENTED AND VERIFIED

User decision: remove MOVE16 rather than keep it as a documented
extension, since exhaustive full-text search of MC68030UM.pdf found zero
occurrences of "MOVE16" anywhere, and Appendix A's own complete
MC68020/68030 instruction-extension table (which correctly lists
CAS/CAS2/CHK2/CMP2/PACK/UNPK/etc., and correctly flags CALLM/RTM as
68020-only and absent from this RTL) does not include it. MOVE16 is a
real M68000-family instruction, but belongs to the MC68040 (cache-line
burst move), not the 68020 or 68030. This project had fully implemented
it as real, working, cycle-accurate 68030 silicon behavior.

**Key finding that shaped scope**: `m68030_top.sv` hardwired
`eu_m16_req = 1'b0` at the `m68030_biu` instantiation ("MOVE16 (stub)").
The BIU's own dedicated MOVE16 burst-write mechanism
(`biu_burst_ctrl.sv`'s write-data mux, `biu_cycle_gen.sv`'s `ST_BWRITE_*`
state family, `m68030_biu.sv`'s `eu_m16_*` port plumbing) has **never
fired in this project's history** — fully dead code, unreachable from
the live datapath. The real, working implementation lived entirely in
`eu_seq_execute.svh`'s own `move16_run_r` FSM, which performed 4 ordinary
longword reads then 4 ordinary longword writes via the generic
`mem_req`/`mem_addr`/`mem_wdata` path — the same pattern `movem_run_r`
uses, not a genuine burst bus cycle at all.

**Decision**: remove the live decode/execute implementation; leave the
already-dead BIU-side plumbing in place, documented explicitly as a
deliberate scope decision (matching this project's own established
pattern — e.g. Phase 248 item #7's coprocessor-conditional-instructions
boundary). Untangling the dead BIU-side code is separate, higher-risk
work with no functional benefit (it's already provably unreachable) and
real risk of breaking the live, heavily-verified burst-READ path by
mistake, since they share significant plumbing (`is_burst =
is_burst_read | is_burst_write`, the shared `sphase` case statement, the
shared burst DS-continuity fix).

**Implementation**:
- `rtl/eu_seq_decode.svh`: removed the MOVE16 decode arm entirely. The
  freed opcode range now falls straight through into the existing
  generic `else if (f_dn == 3'b001) begin ... dec_is_fpu = 1'b1; ... end`
  fallback — exactly correct real-hardware behavior (any cpid=1 F-line
  encoding not otherwise claimed is FPU coprocessor space), needing no
  new code, just removal. Also removed `dec_is_move16`/`dec_move16_form`
  declarations/resets and fixed 3 stale comments.
- `rtl/eu_seq_execute.svh`: removed the entire `move16_run_r` FSM —
  every `move16_*` register/wire, the `move16_wdata_w` case statement,
  the dispatch/run `always_ff` block, `move16_an1_wr_en` and its
  postinc-mux terms, and every `move16_run_r`/`move16_*` term feeding the
  shared `mem_req`/`mem_wr`/`mem_siz`/`mem_addr`/`mem_wdata` muxes and
  `ex_mem_stall`'s own OR-chain.
- `rtl/m68030_seq.sv`: one-line stale-comment fix (cpSAVE/cpRESTORE
  decode comment referenced MOVE16).
- `rtl/m68030_top.sv`: added a comment at the existing `eu_m16_req(1'b0)`
  tie-off marking it a *permanent* stub (MOVE16 doesn't exist on real
  68030 silicon), not a "not yet wired up" placeholder.
- `tb/data_move_tb.sv`: removed `run_move16`/`test_move16` tasks and
  their call site; fixed the file's own header comment.
- `tb/special_instr_tb.sv`: rewrote FPU-06 completely — it used to prove
  opcode `0xF208` (formerly MOVE16 (A0)+,(A1)+) triggers `mem_req`, NOT
  `eu_coproc_req`; the new test proves the OPPOSITE using the existing
  `send_fpu` helper (same pattern as FPU-01..05), confirming
  `coproc_req` fires and `mem_req` does not.
- `tb/stall_fsm_tb.sv`: 5 removal sites (B-8; BERR-mid-MOVE16;
  INT-mid-MOVE16; WS-MOVE16-1/2; T4f CAS2→MOVE16), each removing the ROM
  block/check and retargeting a JMP to skip straight to the next test.
  Removed unused `MOVE16_A0P_A1P`/`MOVE16_EXT` localparams.

**Two real, previously-latent testbench bugs found and fixed while
re-verifying this removal (neither an RTL bug)**:

1. Retargeting `rom[0x3FD0]`'s JMP from `0x2604` (INT-mid-MOVE16's start)
   directly to `0x26C4` (INT-mid-ABCD's start) exposed that
   `INT-mid-ABCD`'s own test was missing the explicit JMP redirect to its
   own next test that every other test in this file uses — it fell
   through NOP-padding all the way to `0x2784` (SBCD's start), a span
   that includes `0x26F0`, ABCD's OWN predecrement write destination
   (`A0=0x26F1`, predecrements to `0x26F0`). That write legitimately
   turns the NOP sitting at `0x26F0` (`0x4e71`) into a real, non-NOP
   opcode (`0x0271` — only the high byte changes, exactly matching a
   1-byte BCD-result write) via genuine self-modifying-code semantics.
   Since `0x26F0` sat directly on the fall-through execution path
   (unlike B-10's own ABCD test, which deliberately uses isolated
   scratch addresses far from any code), the CPU decoded and executed
   the corrupted opcode instead of ever reaching SBCD's code — hanging
   `INT-mid-SBCD` and cascading into every test after it (~48 failures,
   confirmed via full test-log capture before the fix). This hazard was
   already latent before the F8 retarget; the retarget's timing change
   is what newly exposed it (previously, execution reached the same
   ABCD code via a different path — through MOVE16's own longer
   instruction stream first — which happened to change exactly when the
   corrupted word was reached relative to other test state). Root-caused
   via direct signal tracing (`ifu_ack`/`ifu_rdata`/I-cache internal
   state), not guessed at — confirmed the corruption originates
   genuinely at `biu_icache_if.sv`'s own `fill_rdata_r` capture, from a
   real (not stale/hazard-timing) bus read of already-modified memory.
   **Fixed** with a one-line explicit JMP from ABCD's tail (`0x26DC`)
   straight to SBCD's start (`0x2784`), matching this file's own
   established "explicit JMP, isolated address" convention used
   everywhere else.
2. With (1) fixed, one failure remained: `WS-PMOVE64`'s own
   `elapsedX > elapsed0` timing check inverted (measured 155 > 143 —
   `wait_states=10` looked FASTER than `wait_states=0`). Retargeting the
   WS-MOVE16 JMP to land directly on `0x3E34` made `WS-PMOVE64-1`'s own
   timed run the very first-ever fetch of that I-cache line (EI=1/IBE=0
   degraded single-beat mode has been active since ~0x2DA0's own
   `MOVEC D7,CACR`) — a genuine cold-miss penalty that used to be masked
   because falling through WS-MOVE16's own longer instruction stream
   gave the IFU's ambient-readahead mechanism enough of a head start to
   already have that line cached by the time execution naturally
   arrived. With the direct jump, that cold-miss overhead landed
   entirely inside `elapsed0`, inverting the intended comparison. Not an
   RTL bug — the same I-cache warm/cold measurement-asymmetry class this
   project's own history already documents for back-to-back timed runs.
   **Fixed** by restoring a short, collision-free NOP runway
   (`0x3E04`-`0x3E33`, confirmed clear — `0x3E00` alone is TAS's own data
   operand) between the JMP landing and `0x3E34`'s real code, giving
   readahead the same head start the old MOVE16-preceded flow provided
   incidentally. Verified deterministic across 6+ repeated `vvp` runs of
   the same compiled binary before and after.

**Verification**: `make sim/stall_fsm` compiled clean (zero dangling
`move16` references — would have been a hard compile error); full
`stall_fsm` suite went from ~48 cascading failures (the ABCD/SBCD hang)
down to 1 (`WS-PMOVE64`) after fix (1), then to 0 after fix (2),
confirmed deterministic across repeated runs. Full mandatory gate:
`make test` 37/37, `make cosim_grp` 8/8, `make cosim_memind` 28/28,
`make dat-synth` 50/50, full 124-suite Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2 [documented ASL.b corpus anomaly]
SKIP 281221 TIMEOUT 0` — MOVE16 has zero Tom Harte coverage, 68000-
captured corpus, MOVE16 is 68040-only, and no cosim/`tests/*.s` file ever
referenced it).

**This closes F8**, and with it the entire Phase 250 10-item findings
list except F6 (deferred, documented above) and F9/F10 (low-priority,
not yet actioned). See `docs/stalls.md` for the corresponding coverage-
count corrections (Category F 18→17 sources, Category H 14→13 sources,
back-to-back FSM pairs 9→8) and `CLAUDE.md`'s own Phase 250 F8 summary
for the condensed version of this writeup.

## F9 (STOP + trace interaction) — INVESTIGATED, CONFIRMED NOT A BUG

MC68030UM.pdf §8.1.7: STOP that begins execution with tracing (T1)
already enabled must force a Trace exception immediately after loading
SR, and must never actually enter the stopped condition. Flagged
"plausible, not confirmed" in the original findings list — `stop_r`'s
own presence in `ex_mem_stall`'s OR-chain could plausibly gate
`eu_trace_req` shut before it ever fires, and the RTL's own timing
history (F1's AS/DS misconception, several genuine cycle-adjacent races
found elsewhere in this project) made "appears self-correcting on paper"
not good enough on its own — built a real end-to-end test instead of
reasoning about it in the abstract.

**Test**: new `tb/stall_fsm_tb.sv` test **F9**, reached via a JMP
redirect from AS-LOCK-MISMATCH's own tail (was `BRA_SELF`) into freed
MOVE16 opcode space (`0x2604`-`0x263C`, confirmed clear via grep — Phase
250 F8 removed INT-mid-MOVE16's own code from here). Sequence:
`MOVE.W #$A000,SR` (sets T1=1, S=1) immediately followed by
`STOP #$2000`. Vector 9 (Trace) points at a handler that clears the
stacked frame's own T1 bit (needed so subsequent instructions don't
retrace forever) and sets D6=54321 as a marker, then RTEs. The
instruction after STOP (`CLR.L D5`/`ADDI.L D5,#8001`) proves execution
resumed correctly; a trailing `BRA_SELF` re-parks the CPU exactly as
before this test was added, so `SPURIOUS-INT` (the next test) still
finds it quiescent.

**Finding: not a bug**. Direct cycle-by-cycle tracing confirmed the
mechanism is correct by construction: `dec_is_trace` is computed
combinationally at DECODE time using the OLD SR (T1 as it stood before
STOP's own SR write, since decode strictly precedes EX) — so
`ex_is_trace`/`eu_trace_req` are already latched true the very cycle
STOP first enters EX, a full cycle *before* `stop_r` itself (a
registered signal, visible only starting the next cycle) ever reaches
`ex_mem_stall`'s own OR-chain. `m68030_exc.sv`'s `EXC_IDLE`→`EXC_PUSH`
transition only needs `exc_pending` true for that one cycle to latch,
and independently snapshots `fault_sr` on the identical edge — two
separate flip-flops sampling their own combinational inputs on the same
clock edge, no race, correctly capturing the OLD (T1=1) SR before
STOP's own write commits. `stop_r`/`eu_stop` does assert for one
internal cycle before `exc_sr_wr_en` (fired by ANY exception reaching
`EXC_LOAD`, not just interrupts — the same pre-existing mechanism that
already resumes STOP on a real interrupt) clears it, but this is a
purely internal, non-externally-observable transient (STOP produces no
bus cycles either way, so nothing pin-visible differs) — not a real
"entered the stopped condition" violation. Confirmed execution correctly
resumes at the instruction after STOP post-RTE, not re-executing STOP
and not staying halted.

**Found and fixed one real bug in the test's own construction (not the
RTL)**: the trace handler's own `ANDI.W #$7FFF,(A7)` (meant to clear T1
in the stacked frame before RTE) didn't work — confirmed via a direct
`rom[]` memory dump that this RTL's own Format $0 frame packs
`{fmtvec, SR}` together as ONE longword at the frame's LOW address
(fmtvec in the upper 16 bits, SR in the lower 16 bits), with PC at the
HIGH address instead. `(A7)` alone addresses the fmtvec half, not the SR
half — fixed to `(2,A7)` (opcode `0x026F`, mode=101/(d16,An), reg=111/
A7, displacement=+2).

**Flagging a separate, NOT independently verified compliance question
for a future session**: this frame layout (fmtvec+SR low, PC high)
appears to differ from the real 68030's own documented arrangement (SR
lowest, PC middle, format/vector highest per every reference this
project has otherwise used). Confirmed via grep: no existing test in
this project has ever independently dumped raw frame memory to check
its physical byte layout — every existing frame-format test
(`tb/mmu_xlate_tb.sv` Phase 3/4, `tb/exc_tb.sv` EXC-9, etc.) checks a
derived format-code/register end-state, never the actual pushed bytes.
The RTL is internally self-consistent (the same code both constructs
and later pops its own frames via RTE, using matching offsets), so this
has never surfaced as an observable functional failure in 250 prior
phases of cosim/Harte verification — but it may be a genuine,
previously-undiscovered structural compliance bug, distinct from and
unrelated to F9 itself, worth its own dedicated investigation (re-derive
against MC68030UM.pdf's actual frame diagrams directly — visually, not
from OCR text or memory, matching this project's own F1 precedent for
exactly this class of mistake) before concluding either way. Not
investigated further this phase — out of scope for F9, and discovered
only as a side effect of debugging the test's own handler.

**Also found and fixed one real, previously-latent testbench-
construction bug** reusing the exact "ROM write issued after simulated
time already passed that address" class this file's own history
already documents (`feedback_rom_write_ordering.md`): the JMP redirect
skipping this test's own ROM setup was first written in the *runtime*
polling section (physically after AS-LOCK-MISMATCH's own `check32`
calls), racing real elapsed simulation time against this file's own
giant upfront sequential setup block — by the time that statement
executed, the CPU had already reached and started looping on the OLD
`BRA_SELF` it was supposed to have overwritten. Fixed by moving all of
this test's own `rom[]` writes to the upfront setup section, alongside
AS-LOCK-MISMATCH's own (matching every other test's established
convention), keeping only the runtime poll/check code in its original
position.

**Verification**: confirmed deterministic across 4+ repeated `vvp`
reruns of the same compiled binary (0 failures each time) after both
fixes. Full mandatory gate: `make test` 37/37 (testbench-only, `git
diff --stat rtl/` empty, no Harte re-run needed).

**This closes F9.** Of the original 10-item Phase 250 findings list,
F1/F2/F3/F4/F5/F7/F8 are IMPLEMENTED AND VERIFIED, F9 is investigated
and confirmed not a bug, F6 is investigated and deferred (documented
above). The frame-layout question F9 surfaced as a side effect is
documented above as a distinct, unconfirmed follow-up candidate, not
part of this findings list.

## F10 (STATUS pin, double-bus-fault sub-case) — IMPLEMENTED AND VERIFIED

MC68030UM.pdf's real STATUS pin (Table 12-4/§7.5.4/§8.1.2; confirmed
Output, active-low, per the Chapter 5 signal summary table's own "Output
Low" entry) has 4 distinct meanings. Table 8-2 describes 3 of them as
1/2/3-clock pulses tied to instruction-boundary/trace-interrupt/MMU-
dispatch microsequencer staging — these need real microsequencer-cycle
correlation this project's structurally different microarchitecture has
no faithful analogue for, matching Phase 248 item #5's own REFILL#/
STATUS# deferral reasoning exactly. Left deliberately unimplemented.

The 4th meaning — continuously asserted, until reset, signaling the
processor halted due to double bus fault — is NOT microsequencer-
timing-dependent at all; it's just a sticky bit. This project already
computes exactly that condition (`biu_error_handler.sv`'s `halt_out`,
`assign halt_out = (berr_s | berr_timeout_r) & retry_pending;`) but
never latched or wired it to any output pin — `halt_out`'s own header
comment already says "halt_out is combinational — the top-level should
register it to avoid glitches propagating to the halt pin," a genuine,
never-closed gap this finding is the natural opportunity to close.

**Implementation**: added a new sticky register in `rtl/m68030_biu.sv`
(`status_r`, set when `halt_out` fires, cleared only on `!rst_n`) and a
new `status_n` output port (`assign status_n = ~status_r;`), threaded
straight through `rtl/m68030_top.sv` as a genuine top-level chip pin.
Documented at both sites that this deliberately implements only the
sticky-halt sub-case; the other 3 STATUS meanings remain out of scope.
New output ports don't need tie-offs in existing testbenches (unlike
new *input* ports, which X-propagate if left unconnected — Phase 248
item #5's own precedent) — confirmed via `make test` 37/37 with zero
changes to any file besides the one new dedicated test.

**Test**: new coverage in `tb/biu_int_tb.sv` — the only testbench that
instantiates the real `m68030_biu` module directly (every other BIU
test either drives `biu_error_handler`/`biu_cycle_gen` standalone, or
goes through the full `m68030_top`, neither of which is the right unit
boundary for a BIU-level pin like this). Added a `suppress_dsack`
testbench override (`mem_model.sv` has no address-range gating to
exploit for "no device responds," unlike some other testbenches' own
inline models) to simulate a genuinely unanswered bus cycle. Drove a
real BERR+HALT retry sequence and confirmed `status_n` asserts on the
resulting double bus fault and stays asserted (sticky) for 200+ cycles
after the underlying condition has long since passed and the bus has
gone back to responding normally, clearing only on a genuine reset.

**Found and fixed one real bug in the test's own construction (not the
RTL)**: an early attempt asserted `halt_n` before/simultaneously with
`eu_req`, and the bus cycle never started at all for the full 2000-cycle
budget (confirmed via direct trace: `s_state` frozen, `phase` cycling
0-3 forever, `retry_pending`/`halt_out` never firing). Root cause: real
HALT# gates bus-cycle *initiation* itself — `biu_cycle_gen.sv`'s own
`bus_halted = (state==ST_IDLE) && init_done_r && !retry_r && !halt_s`
keeps the FSM parked in `ST_IDLE` while HALT# is asserted, so asserting
it before the cycle starts prevents it from ever reaching the S4/S5/S6
states where the real BERR+HALT retry decision lives at all. Fixed by
letting the cycle genuinely dispatch first (10 cycles with HALT#
deasserted), then asserting HALT# partway through — matching what real
hardware actually requires (HALT# and BERR# sampled together at the
point a fault is recognized, not necessarily present from the cycle's
own start).

**Noted, not fixed (out of scope for a pin-wiring task)**: direct
tracing during test construction found `halt_out` itself asserts on the
SAME cycle as `retry_pending` in this exact scenario, not a cycle later
as `tb/biu_tb.sv`'s own existing "Double bus fault" test comment
describes ("Retry cycle: also no DSACK → second timeout fires while
retry_pending=1 → halt_out asserts"). Root cause: `berr_timeout` is a
sticky latch held until `bus_idle` (not a one-cycle pulse), so it can
still read 1 from the ORIGINAL fault at the exact cycle `retry_pending`
freshly asserts, making `halt_out`'s formula fire immediately rather
than requiring a genuinely independent second timeout during the retry.
`tb/biu_tb.sv`'s own existing, already-passing test never distinguished
same-cycle from later either (it only checks `saw_halt` at any point
over up to 500 cycles), so this isn't a regression — just a pre-existing
timing nuance in `halt_out`'s own formula, noted here for a future
session rather than touched, since fixing it isn't what F10 asked for
and risks the same class of subtle timing mistake this project's own
BERR/RMW history has repeatedly warned about.

**Verification**: confirmed deterministic across 3 repeated `vvp`
reruns of the same compiled binary. Full mandatory gate: `make test`
37/37, `cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50, full
124-suite Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2
[documented ASL.b corpus anomaly] SKIP 281221 TIMEOUT 0`).

**This closes F10**, and with it the entire Phase 250 10-item findings
list except F6 (investigated, deferred, documented above — the only
item left open, by explicit choice given its own real risk to RTE's
delicate FSM). See `CLAUDE.md`'s own Phase 250 F10 summary for the
condensed version of this writeup.

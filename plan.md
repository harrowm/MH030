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

## Exception frame layout fix (Part A of a 2-part plan, IMPLEMENTED AND VERIFIED)

A side finding from F9's own investigation (not one of the original
10-item findings list): every exception frame format packed
`{format/vector, SR}` as the first longword and PC as the second.
Confirmed real via direct inspection of MC68030UM.pdf Table 8-6 (both
sheets) and Figure 4-1 — identical across every format shown — real
silicon's layout is genuinely different in kind, not just reordered: SR
alone at SP+0, PC (32-bit) at SP+2, the format/vector word alone at
SP+6. Internally self-consistent (the same code both pushes and later
pops its own frames via RTE), so it never surfaced as an observable
failure across 250 prior phases — confirmed via grep that no existing
test ever inspected raw frame memory.

A second, closely related fabrication was found and removed while
re-deriving the layout: "Format $3, 8 words, Address Error" never
existed on real silicon either. Table 8-6 has no $3 entry in either
sheet, and §8.1.3 states plainly that Address Error uses "either a short
or long bus fault stack frame" — the same $A/$B selection Bus Error
already uses. The same shape as the already-fixed old "$9, MMU short bus
fault" fabrication (Phase 250 F5). Address errors now select $A
unconditionally, since this project's own `addr_err_req` is fed only
from instruction-fetch address errors (`ifu_addr_err_int`) — EU-side
data address errors are computed (`eu_addr_err`) but never wired into
the exception controller at all, a separate, pre-existing, out-of-scope
gap confirmed via grep, not touched here.

**Implementation**: `rtl/m68030_exc.sv`'s `push_data` table reshaped to
the byte-correct longword pairs (`{SR,PC[31:16]}` then
`{PC[15:0],fmtvec}`); `$A`/`$B`'s own longer tail remapped to its real
offsets (SSW moved from its old step-3 position to step 2/SP+$A; Data
Cycle Fault Address — this project's own `fault_addr` — moved from step
2/SP+8 to its real step 4/SP+$10; Data Output Buffer moved from step
4/SP+$10 to its real step 6/SP+$18; Instruction Pipe Stage C/B, SP+$C/E,
have no real content this project tracks and stay zero, same "FPU not
implemented" treatment as steps 5+/7+ elsewhere); `$9`'s own stray
unconditional SSW write at the old step 3 — a third, small, adjacent bug
found during this same re-derivation, since real Format $9 has no SSW
field at all there — fixed with the same `fmt_is_fault` exclusion step 4
(DOB) already had. `$2`/`$9`'s own Instruction Address field (step
2/SP+8) needed no change — already correctly longword-aligned regardless
of the prefix fix. `FMT_ADDR` removed entirely (localparam, its
`total_steps`/`ssp_delta` case entry, its `pend_fmt` assignment). The
throwaway Format $1 frame (`push2_data`/`push2_addr`, pushed to ISP on
an M=1 interrupt) had the identical bug shape and got the identical fix.

`rtl/eu_seq_execute.svh`'s RTE two-phase read reshaped to match: phase 0
(read at `ex_ea`=A7) now captures `mem_rdata[31:16]` as SR (was
`mem_rdata[15:0]`) and a new `rte_pc_hi_r` register captures
`mem_rdata[15:0]` as PC's own high half (previously unnecessary — the
whole PC arrived in one phase-1 read under the old layout). Phase 1
(read at `rte_a7_next_r`=A7+4) now supplies PC's low half
(`mem_rdata[31:16]`, combined with `rte_pc_hi_r` in `branch_target`'s own
`ex_rte_taken` branch) and the format nibble (`mem_rdata[15:12]`, moved
from phase 0's own top nibble) for both `eu_fmt_err_req`'s format-
validity check and `rte_frame_extra`'s own byte-skip sizing — both
functions had their own `4'h3` case removed too, matching the `FMT_ADDR`
removal (a real RTE now correctly rejects format nibble 3 as Format
Error, same as any other unrecognized code).

**Found and fixed one real, previously-latent bug in the RTE fix's own
first attempt, caught via a live regression (not guessed at)**: a new
`rte_fmt_skip_r` register, introduced to hold the format-derived skip
amount from phase 1's read for use in the final A7 write, created a
genuine same-cycle read-before-write hazard — its own consumer
(`rte_an_wr_en`/`ex_rte_taken`, `an_wr_data`'s own formula) fires the
IDENTICAL cycle the register's own non-blocking update lands, reading
the stale (pre-update) value. First symptom: `tb/system_tb.sv`'s
JSR-01/JSR-02 corrupted ISP after an intervening RTE test (RTE's own
final A7 write used a stale skip amount, later silently overwriting
JSR's own explicit `set_isp` call after a pipeline delay). Root-caused
via direct comparison against a git-stashed true baseline (which showed
these tests passing silently, confirming a real regression, not a
pre-existing gap) and fixed by computing the skip amount combinationally
from the live `mem_rdata` at the point of use (`an_wr_data`'s own
formula calls `rte_frame_extra(mem_rdata[15:12])` directly) instead of
through a register — `rte_fmt_skip_r` removed entirely.

**Testbench fixes**: roughly a dozen hand-crafted RTE/format-error test
frames across `tb/stall_fsm_tb.sv` (B-16's own shared frame at
0x3400/0x3404, reused by BERR-mid-RTE; INT-mid-RTE's own frame at
0x2950/0x2954; T4h's own frame at 0x3970/0x3974; this session's own F9
trace-handler ANDI, which needs to revert from `(2,A7)` back to plain
`(A7)` now that SR genuinely lives at the frame's own lowest address),
`tb/system_tb.sv` (RTE-01/02/03's own hand-loaded `ram[]` frame),
`tb/exception_tb.sv` (FMTERR-01/02's own hand-loaded format-nibble
bytes), and `tb/exc_tb.sv` (every EXC-N test's own detailed push-data
expected values, re-derived by hand and cross-checked against the RTL's
own actual output before committing to new expected constants) all
encoded the old (now-wrong) layout and needed updating. `tb/exc_tb.sv`'s
own detailed push-data checks (every implemented format, every step
position) are now the closest thing this project has to independent
frame-content verification, since no test anywhere dumps raw frame bytes
end-to-end through the full pipeline.

**A genuine full Harte-sweep regression surfaced during verification,
root-caused to test-harness scripts, not this project's own RTL, and
fixed at its source** — the most involved part of this whole fix.
Initial full-sweep runs showed the RTE suite (4011 runnable vectors)
mostly FAIL/TIMEOUT. Direct investigation (comparing a git-stashed true
baseline against the fixed code through the SAME freshly-rebuilt
`sim/harte_batch` binary — the tool CLAUDE.md documents as what
verification gates actually use, `sim/harte_dat`/`run_harte.py`'s own
single-process tool turned out to be independently stale/broken and
unrelated to this investigation, a dead end not worth chasing further)
confirmed: baseline was genuinely clean (4011/4011), the fixed code
genuinely regressed. Root cause: `scripts/gen_harte_hex.py` has a
long-standing, hand-built workaround for RTE specifically, since the
Harte corpus is captured on real 68000 hardware, whose native RTE frame
is just {SR,PC} (3 words, no format field at all — a 68010+ concept).
The script synthesizes a format word and shifts the test's own initial
SSP by -2 bytes so the synthetic-plus-real bytes line up with whatever
this RTL's own RTE actually reads — a shift hand-tuned specifically for
the OLD `{fmtvec,SR}`+`PC` layout. Fixed: no initial shift needed at all
for the new layout (Harte's own real SR/PC bytes already sit exactly
where phase 0/1 expect them), the synthesized format word instead goes
at `a7_val+6` (immediately past the reference's own 6 real bytes, still
provably collision-free), and `scripts/run_harte.py`'s own `compare()`
gained a matching `+2` final-SSP compensation (the old version absorbed
this into the shift itself; the new layout has no shift left to absorb
it into).

A second, deeper, previously-latent gap surfaced during this SAME
investigation, independent of the frame-layout fix itself: some RTE test
vectors restore a `T1=1` (or `T0=1` with a flow-change next instruction)
SR. Direct signal tracing (`u_top.ifu_decode_pc`, `u_top.exc_active`,
temporary and since removed) confirmed this project's own trace
mechanism handles it correctly — decode_pc genuinely advanced past the
restored PC's own first instruction (its side effects already retired)
before a real Trace exception dispatched, exactly matching real
architecture (and exactly matching this same session's own F9
investigation of STOP+trace interaction). But `gen_harte_hex.py` never
installed a vector-9 (Trace) handler for RTE tests — only vector-3
(Address Error, for `is_ret_taken`'s own odd-restored-PC case) and
vector-8 (Privilege Violation) ever got real handler installations. With
no real vector-9 entry, the CPU fetched a garbage PC from VBR+36 and the
test hung. The OLD (wrong) RTL frame layout apparently never triggered
this in 250 prior phases of Harte sweeps: its own garbled reconstruction
essentially never produced a genuinely valid, directly-executable
restored PC with a real `T1=1` SR at the same time, so the gap sat
latent until the layout fix made RTE's own reconstruction correct enough
to actually reach it. Fixed by installing vector 9 unconditionally for
every RTE test, pointing at the same STOP+NOP runway vector-3 already
uses (`instr_src + instr_len`) — mirrors the existing pattern exactly,
verified harmless when trace never actually fires.

**Verification**: `tb/exc_tb.sv` ALL EXC TESTS PASSED (29 individually
re-derived checks); full mandatory gate clean (`make test` 37/37,
`cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50); full 124-suite
Harte sweep bit-identical to true baseline (`PASS 702142 FAIL 2`
[documented ASL.b corpus anomaly] `SKIP 281221 TIMEOUT 0`), including
the RTE suite specifically now at a clean 4011/4011 (was failing before
the two script fixes above).

**This closes Part A.** Part B (genuine double-bus-fault detection,
correcting `halt_out`/the F10 STATUS pin) follows as a fully separate,
independently-verified effort per the approved 2-part plan
(`~/.claude/plans/wobbly-honking-cascade.md`).

## Part B (genuine double-bus-fault detection, IMPLEMENTED AND VERIFIED)

Closes the second side finding from F9's own investigation (the first
was Part A above). MC68030UM.pdf §7.5.4/§8.1.2/§8.1.3: real double bus
fault is a bus or address error occurring WHILE the exception controller
is already dispatching a PRIOR bus or address error (or a reset — this
project has no reset-exception source, so that trigger doesn't apply
here). This is explicitly, textually distinct from `halt_out` (BERR+HALT
retry exhaustion, the signal Phase 250 F10 wired to `status_n`): "a bus
cycle that is retried does not constitute a bus error or contribute to a
double bus fault."

### B1 — empirical confirmation before designing a fix

Built a throwaway test in `tb/stall_fsm_tb.sv` (temporary ROM block at
0x2614-0x262C redirecting from F9's own tail, plus a runtime check block
— both fully removed once the investigation concluded, per this
project's own established discipline for one-shot confirmation tests)
injecting a genuine `berr_n` fault, held through the exception
controller's OWN first frame-push write specifically (not just the
original faulting EU access that triggers dispatch in the first place).

**First attempt had a real bug in the test itself**: counted raw
`cg_eu_berr_raw` (biu_cycle_gen's own per-attempt abort pulse) HIGH
*levels*, but that signal stays high for 2 consecutive cycles per real
fault — double-counting one fault as two, releasing the injected
`berr_n` before the push write's own bus cycle could genuinely be
affected. Fixed with proper rising-edge detection (`cg_eu_berr_raw &&
!cg_berr_prev`), mirroring the exact debounce fix this session had to
apply to its own B1 test construction — caught by reading the raw trace
carefully, not by assuming the first result.

**With the debounce fixed**, a *transient* fault (released after the
second detected edge) showed `push_step_r` advancing normally and
`exc_active` clearing — i.e., apparent "recovery," which on first glance
looked like it refuted the predicted hang. A deeper trace (adding
`biu_cache_if`'s own `state`/`biu_cycle_gen`'s own `state`/`exc_req`/
`exc_ack` alongside) explained why: `m68030_exc.sv`'s own
`exc_req`/`exc_addr`/`exc_wdata` are purely combinational off
`state_r`/`push_step_r` — there is NO explicit reaction to any berr
signal anywhere in `EXC_PUSH`/`EXC_FETCH`/`EXC_PUSH2`. When
`biu_cache_if.sv`'s own `CI_BERR` state aborts a cycle, it unconditionally
returns to `CI_IDLE` the very next cycle (Phase 108/109's own "BERR
hangs" fix) — and since the exception controller's own request line was
NEVER de-asserted (it doesn't know a fault happened), `CI_IDLE` sees a
still-live request and redispatches the IDENTICAL write immediately.
This produces an ACCIDENTAL, EMERGENT retry loop — not a deliberate
mechanism, and not a classic "stuck FSM waiting for an ack that never
arrives" deadlock either. A transient fault self-heals via this loop
(matches real hardware's own "a retried cycle isn't a bus error" carve-
out, coincidentally). To confirm the REAL, persistent-fault case (what
actually matters for double-bus-fault detection), rewrote the test to
hold `berr_n` PERMANENTLY asserted rather than releasing after the
second edge: confirmed `push_step_r` NEVER advances and `exc_active`
NEVER clears for the full 4000-cycle test budget, then confirmed
releasing `berr_n` afterward lets the very same retry loop finally
succeed (proving it's a live retry loop, not a truly dead FSM — the
distinction matters for how B2 characterizes the bug). **This is the
real, confirmed gap**: a persistent fault during frame-push spins
forever with zero forward progress and zero reported condition — real
silicon would instead detect this and signal double bus fault
immediately, no retry at all.

### B2 — implementation

`rtl/m68030_exc.sv`:
- New `snap_is_berr_r`, captured at the `EXC_IDLE` dispatch decision
  (`addr_err_req || bus_err_req`), mirroring `snap_is_int_r`'s own
  existing pattern exactly.
- New input `dispatch_berr`, fed from the top level's own `eu_berr` net
  (m68030_top.sv's `.dispatch_berr(eu_berr && exc_active)` at the
  `u_exc` instantiation) — `eu_berr` is ALREADY a clean, one-shot-per-
  fault signal (Phase 108/109/113/114's own earlier "only first-ever
  fault reported" fix made it so), so no new debounce/edge-detection
  logic was needed on the RTL side at all — confirmed via direct trace
  (a temporary probe watching `eu_berr`/`biu_cache_if`'s own `state`
  during a genuine, non-injected MMU write-protect fault, see below)
  that it fires cleanly on every distinct `CI_BERR` entry.
- New terminal state `EXC_DBLFAULT` (enum value 6; the existing 3-bit
  `exc_state_t` already had room). Entered via a new priority check
  placed BEFORE the state's own case arm in the sequential block:
  `if (state_r != EXC_IDLE && state_r != EXC_DBLFAULT && dispatch_berr
  && snap_is_berr_r) state_r <= EXC_DBLFAULT;` — preempts whatever the
  current state's own arm would otherwise do. No second frame is ever
  attempted (real silicon doesn't either); the case statement's own new
  `EXC_DBLFAULT` arm is an explicit no-op (state simply holds, since
  only `!rst_n` can leave this state).
- New sticky output `double_fault`, `assign double_fault = (state_r ==
  EXC_DBLFAULT);` — no separate register needed, `state_r` itself is
  already the sticky latch (never returns to `EXC_IDLE`).
- Confirmed (per the plan's own B2 checklist item) that the EXISTING
  `exc_active = (state_r != EXC_IDLE)` already halts forward progress
  for free once `state_r` reaches `EXC_DBLFAULT` and never leaves —
  whatever gates new EU instruction issue on `exc_active` today
  continues to do so permanently, with zero new freeze machinery
  needed.
- Reachability note: `EXC_DBLFAULT` is only actually reachable from
  `EXC_PUSH`/`EXC_FETCH` in practice — `EXC_IACK`/`EXC_PUSH2` are both
  interrupt-only states, and `snap_is_berr_r`/`snap_is_int_r` are
  mutually exclusive by construction (a dispatch is either a bus/
  address-error one or an interrupt one, never both), so the detection
  check is harmlessly unreachable there rather than needing an explicit
  exclusion.

`rtl/m68030_top.sv`: new `exc_double_fault_w` net carrying `u_exc`'s own
`double_fault` output into `m68030_biu`'s new `double_fault` input (see
B3).

### Found and fixed a real, previously-undiscovered PRE-EXISTING MMU bug while verifying B2

The full mandatory gate's own `make test` broke: `tb/mmu_xlate_tb.sv`'s
Phase 4 (a write-protect violation, format `$B`) started failing at "the
new (non-retrying) handler ran to completion" — the exception itself
dispatched correctly (right vector, right format), but the handler never
ran. Root-caused via direct trace (not guessed at): a genuine, real
SECOND `eu_berr` fired on the frame-push write's OWN translation
(`CI_XLATE`→`CI_BERR`) immediately after the original fault's own
dispatch began — B2's new detection correctly caught it and diverted to
`EXC_DBLFAULT`, but this was a FALSE POSITIVE, not a real double fault.

Traced deeper (stashed the Part B RTL changes momentarily to compare
against true baseline with a compatible probe, confirming the SAME
underlying behavior exists on baseline too — just silently, since
nothing reacted to it before): the push write's own translation for
address 0x3f1c spuriously WP-faulted 3 times in a row (each one a
genuine, distinct `CI_XLATE`→`CI_BERR` cycle, confirmed via `data_ds_count`
incrementing each time — not one elongated cycle) before a 4th,
genuinely-completed lookup finally returned the correct (non-WP) result
and the write succeeded normally.

Root cause: `biu_mmu_arb.sv`'s own `assign d_wp = mmu_wp;` is a raw,
COMPLETELY UNGATED broadcast — unlike `d_hit`/`d_walk_done` right next to
it, which ARE correctly gated on `(owner_r == OWN_D)`. `mmu_wp` itself
traces back to `biu_mmu_if.sv`'s own `wp_r` register, which (per its own
comment, "mirrors ci_r exactly") only updates when a request genuinely
completes (ATC hit or walk done) — exactly the same shape Phase 228's own
`xl_ci_r` fix was built to guard `xl_ci` against (a raw broadcast that's
only guaranteed correct on the exact cycle a requester's own translation
completes), but that fix was never extended to WP at the time.
`biu_cache_if.sv`'s own `CI_XLATE` state checked `xl_wp` UNCONDITIONALLY
every cycle it was active (`if (xl_fault || (xl_wp && !rw_r))`) — not
gated on `(xl_hit||xl_walk_done)` the way the success branch right below
it already is — so for however many cycles a NEW request's own
translation takes to complete, it was reading the PREVIOUS, unrelated
request's own stale WP result instead.

This bug is real and pre-existing (confirmed present on true baseline
via the stash-and-compare above), but was entirely HARMLESS before B2:
nothing ever reacted to a spurious, self-resolving WP re-fault, so it
silently retried (via the same B1-documented emergent retry mechanism)
and succeeded a few cycles later with no observable effect. B2's own new
double-fault detection was simply the FIRST thing in this project's
history to ever notice and react to a second fault during dispatch —
exposing a bug that had nothing to do with double-bus-fault detection
itself.

**Fixed** in `biu_cache_if.sv`'s `CI_XLATE` state: gated the WP check on
`(xl_hit || xl_walk_done)`, the identical condition the success branch
already requires — WP is only meaningful once THIS request's own
translation has actually finished, mirroring `xl_ci_r`'s own "captured at
completion" discipline instead of reading a raw live broadcast. `xl_fault`
itself was deliberately left unchanged (out of scope — Phase 3's own
fault+RTE-retry test already exercises it back-to-back with other
translated accesses and passes both before and after this fix; no
evidence it shares the same staleness in practice).

### B3 — rewiring `status_n` + renaming `halt_out`

- `biu_error_handler.sv`: renamed `halt_out`→`retry_exhausted` (port and
  internal signal), rewrote the header comment and the assignment's own
  comment to state precisely that this is BERR+HALT retry exhaustion, a
  real and useful simulation-only escape hatch, but NOT double bus fault.
- `m68030_biu.sv`: renamed the `halt_out` port to `retry_exhausted`
  (renamed the `u_err` connection too); added a new `double_fault` INPUT
  port; `status_r`'s own registering condition changed from `halt_out` to
  `double_fault`. Updated the STATUS-pin header comment to explain the
  correction.
- `m68030_top.sv`: renamed the `halt_out` net to `retry_exhausted`;
  threaded the new `exc_double_fault_w` net from `u_exc`'s own
  `double_fault` output into `u_biu`'s new `double_fault` input (both
  modules are direct siblings under `m68030_top`, so no intermediate
  module needed touching); updated port-declaration comments.
- Testbench fixes: `tb/biu_error_handler` consumers
  (`tb/biu_tb.sv`'s standalone unit test, `tb/biu_int_tb.sv`'s full-BIU
  integration test) both had explicit `.halt_out(...)` port connections
  needing renaming to `.retry_exhausted(...)`; `tb/biu_int_tb.sv` also
  needed a new `double_fault_tb` tie-off (this file instantiates
  `m68030_biu` standalone, no real `m68030_exc` to produce a genuine
  double-fault condition).
- `tb/biu_int_tb.sv`'s own Phase 250 F10 test (the one that used to
  assert `status_n` from a BERR+HALT retry scenario — now understood to
  be the WRONG condition per B1/B2's own findings) was split into two:
  (1) a `retry_exhausted` test using the exact same BERR+HALT-retry
  scenario as before, now checking `retry_exhausted` (not `status_n`) —
  plus an explicit new check that `status_n` is genuinely UNAFFECTED by
  this scenario alone; (2) a new, separate `status_n` test driving
  `double_fault_tb` directly (asserts/stays sticky/clears-on-reset) —
  this module has no real exception controller to produce a genuine
  double fault authentically, so `tb/exc_tb.sv`'s own detection-logic
  coverage (see below) is what actually proves the real condition;
  this test only proves `status_n`'s own wiring reacts correctly.
- `tb/exc_tb.sv`: added `dispatch_berr`/`double_fault` signals to the
  standalone `m68030_exc` unit-test harness (tied off `dispatch_berr=0`
  by default; the module's own new detection logic is exercised
  implicitly by every existing dispatch test continuing to pass with no
  false positives).

### Verification

Full mandatory gate clean: `make test` 37/37, `make cosim_grp` 8/8,
`make cosim_memind` 28/28, `make dat-synth` 50/50, full 124-suite Harte
sweep bit-identical to baseline (`PASS 702142 FAIL 2` [documented ASL.b
corpus anomaly] `SKIP 281221 TIMEOUT 0`) — the Harte sweep needed a full
Verilator batch-binary rebuild first (a silent Homebrew Verilator
5.050→5.052 upgrade mid-session broke the stale `obj_harte_vbatch/` include
paths from an earlier phase in this same session; fixed with a clean
`rm -rf obj_harte_vbatch sim/harte_vbatch && make sim/harte_vbatch`
rebuild, unrelated to this plan's own RTL).

**This closes Part B, and the entire 2-part plan
(`~/.claude/plans/wobbly-honking-cascade.md`) in full.**

## Phase 251 (standing-gaps survey — findings list, work starting on the first 3)

User asked "what's outstanding" after Part B closed; this is the full
list of every documented-but-not-done item in the project's history as
of Phase 250 Part B, split into two categories. Recorded here as a
findings list before starting work, matching this project's own
established convention (Phase 248/250's own opening sections).

### Real gaps, deferred with a documented proposal (work starting on these 3)

1. **F6 — RTE should check the Format $B version-number field
   (MC68030UM.pdf §8.1.8).** Deferred at Phase 250 (see F6 above):
   `rte_phase_r`'s own FSM only ever reads 2 words (format/vector+SR,
   then PC) and determines the extra byte count to SKIP via
   `rte_frame_extra()`, never actually reading back any of the rest of
   the frame's own content (SSW, fault address, DOB, internal registers,
   or the version-number word at SP+$36 specifically). A correct fix
   needs a new conditional read step in RTE's own FSM, specific to
   Format $B. Real-world value is genuinely low (the check exists "for
   a multiprocessor system," per §8.1.8 — not applicable to this
   single-CPU project, which only ever constructs and pops its own
   frames) but it's a real, precisely-scoped gap worth closing for
   completeness now that Part A's own frame-layout fix makes the
   byte positions trustworthy.

2. **MOVEM's own genuine memory-indirect EA.** Word-count sizing was
   fixed at Phase 234 (7th IFU prefetch-queue word, `q[6]`/
   `ext7_valid`) — `movem_ext_count` already sizes the drain correctly
   for a genuinely-indirect encoding. The EA arm in
   `eu_seq_decode.svh` still falls back to brief-format addressing for
   genuine indirection, though (`fi_iis` never checked for MOVEM).
   Phase 234 itself scoped this as needing "a real extra bus read
   merged with the project's own existing `ex_is_memind` 3-phase FSM
   ... resolving the EA once per MOVEM instruction, then handing it to
   MOVEM's own existing register-iteration logic as its starting
   address" — the same shape of FSM merge Phase 244 later proved out
   for CMP2/CHK2 (shared memind FSM resolves one address, hands off to
   the family's own pre-existing multi-step FSM unchanged).

3. ~~Genuine two-level memory-indirect EA beyond `MOVE <ea>,dst`.~~
   **INVESTIGATED, NOT A REAL GAP — corrected below.** This item's
   original framing (written at the Phases 115-149 era: "real 68020+
   full-format addressing supports a SECOND level of indirection... vs.
   this project's existing `ex_is_memind` FSM, which only ever resolves
   ONE level") was checked directly against MC68030UM.pdf rather than
   taken on trust, and found to be a documentation error. **Table 2-1**
   ("IS-I/IS Memory Indirection Encodings," p. 2-22) exhaustively
   enumerates all 16 combinations of the 1-bit `IS` field crossed with
   the 3-bit `I/IS` field (this project's own RTL calls the latter
   `fi_iis`) — every non-reserved, non-"No Memory Indirection" row is
   exactly one of: preindexed-indirect, postindexed-indirect, or (PC-
   relative) memory-indirect, each varying only in its outer
   displacement's size (null/word/long). None chains a second
   dereference. **Figure 2-4** (p. 2-23) confirms the field widths (1-bit
   `IS`, 3-bit `I/IS`) directly from the extension-word layout diagram.
   **§2.4.9 "Memory Indirect Postindexed Mode"** (p. 2-14) and **§2.4.10
   "Memory Indirect Preindexed Mode"** (p. 2-15) give the actual EA-
   generation diagrams and formulas — `EA = (bd+An) + Xn.SIZE*SCALE + od`
   (postindexed) and `EA = (bd+An+Xn.SIZE*SCALE) + od` (preindexed) — both
   diagrams show one memory access ("accesses a long word at this
   address," the manual's own words) fetching a pointer, which is then
   *arithmetically combined* (not dereferenced again) with the index/
   outer-displacement to yield the final EA. §2.4.14/§2.4.15 (PC-relative
   variants, pp. 2-18/2-19) are structurally identical. This project's
   own `ex_is_memind` FSM (`rtl/eu_seq_execute.svh:3110-3214`) already
   matches this exactly (`memind_inner_r` performs the one pointer fetch;
   `memind_outer_r`'s address is `mem_rdata + memind_post_xn_r +
   memind_od_r` — arithmetic, not a second read of `mem_rdata` as an
   address) and has already been extended to MOVE, LEA, PEA, JMP, JSR,
   general ALU-EA ops, CMP2/CHK2, TAS, and Scc (Phases 236-245) — i.e. it
   is already architecturally complete for the real addressing mode.
   **Corrected in `CLAUDE.md`** (both its original ~line 304 mention and
   this Phase's own findings-list entry) to remove the "real, deferred
   feature" framing. No RTL/testbench change — this was a doc-only fix.

### Permanently out of scope by design (documented boundaries, not started)

4. **Coprocessor conditional instructions** (cpBcc/cpDBcc/cpScc/
   cpTRAPcc) + **Coprocessor Protocol Violation** (vector 13) — need a
   real attached coprocessor model (a real or emulated FPU) exercising
   genuine condition-evaluation semantics, which this project has never
   built and has no current plan to (documented at Phase 248 item #7).
5. **STATUS pin's other 3 sub-cases** (instruction-boundary/trace-
   interrupt/MMU-dispatch pulses) and **REFILL#** — tied to real
   silicon's own internal microsequencer staging with no faithful
   analogue in this project's structurally different microarchitecture
   (documented at Phase 248 item #5; only the 4th STATUS sub-case,
   double bus fault, has a faithful analogue and was implemented at
   Phase 250 F10/Part B).
6. **PTEST excluded from the DSACK wait-state breadth catalog**, and
   **I-cache CEI stays per-line-only** (unlike CED's now-correct
   per-longword fix, Phase 248 item #4) — both are pre-existing
   architecture-boundary limitations (`docs/stalls.md`'s own PTEST
   exclusion; the I-cache's own per-LINE `valid_i` array structurally
   can't support per-word CEI without a bigger redesign), not bugs.

Items 1-3 are picked up next, in order, each independently verified per
this project's own established discipline (confirm scope/design first,
implement, full mandatory gate, commit) before moving to the next.

### Item 1 (F6) — IMPLEMENTED AND VERIFIED

Full plan in `~/.claude/plans/wobbly-honking-cascade.md` (Part A); this
entry is the closing writeup.

Investigation (a dedicated Explore agent reading MC68030UM.pdf §8.1.8/
§8.1.13/Table 8-6 directly, and the current `rtl/eu_seq_execute.svh` RTE
FSM) confirmed the version-number field lives at SP+$36, bits[15:12],
Format $B only, and — while tracing the exact commit-ordering needed to
implement it safely — found the scope needed to grow to include **two
adjacent, pre-existing bugs** in the *already-shipped* bad-format-code
path, both closed as part of this same fix:

1. `ex_rte_taken` fired from the identical `rte_phase_r && mem_ack`
   condition as `eu_fmt_err_req`, with no format-validity gate of its
   own — an invalid (but non-$B) format code today would BOTH commit
   the bad frame's SR/A7/PC-redirect AND request Format Error the same
   cycle, contradicting §8.1.13's "the faulty stack frame remains
   intact." Confirmed via a live before/after test (see below) — this
   was a real, previously-undiscovered, already-shipped bug, not
   something F6 introduced.
2. `fault_pc` for `fmt_err_req` used `ifu_decode_pc`, not
   `eu_ex_decode_pc` (`m68030_top.sv`) — RTE stalls in EX across its
   multi-cycle bus phases exactly like the file's own pre-existing "Bug
   2" comment already documents, so `ifu_decode_pc` likely raced ahead
   by the time `fmt_err_req` fires. Fixed to match `bus_err_req_w`'s
   own already-proven precedent for the identical race.

**Implementation** (`rtl/eu_seq_execute.svh`): widened `rte_phase_r`
from a 1-bit 2-phase FSM to a 2-bit, up-to-3-phase one (0=await
{SR,PC hi}, 1=await {PC lo,fmtvec}, 2=await the version-check word,
Format $B only). New `rte_pc_lo_r` register captures PC's low half ONLY
at the phase-1→2 transition (needed one cycle later at phase 2's own
completion, when `mem_rdata` no longer holds it — the phase-1-direct-
complete case still reads it live, unaffected, avoiding the exact
same-cycle read-before-write hazard this file's own header comment
already documents from the earlier `rte_fmt_skip_r` mistake). New
`rte_ver_valid()` function (valid = `4'h0`, matching this RTL's own
constructed frames, which always emit $0 there as an emergent property
of unpopulated fields defaulting to zero). `ex_rte_taken`/`rte_stall`
both now require a GENUINE completion (phase 1 acking with a non-$B
format, or phase 2 acking at all) AND `!eu_fmt_err_req`, closing bug #1
above as a direct byproduct (real silicon must never commit from a
frame it's simultaneously rejecting). `an_wr_data`'s own byte-skip
lookup hardcodes `8'd176` (Format $B's own known size) when completing
via phase 2, rather than re-reading `mem_rdata[15:12]` (which by then
holds the version-check word, not the format nibble). `m68030_top.sv`:
`fault_pc` ORs `eu_fmt_err_req_w` into the existing `bus_err_req_w`
condition selecting `eu_ex_decode_pc`, closing bug #2.

**Verification**: `tb/exception_tb.sv`'s existing FMTERR-01 (bad format
code) gained a new check that `branch_taken` never asserts; new
FMTERR-03 (Format $B, version=$0, valid — regression, confirms RTE
completes normally through all 3 phases, checked `branch_target`
directly) and FMTERR-04 (Format $B, bad version — confirms Format Error
fires and no branch/commit occurs). Confirmed both new checks
(FMTERR-01's new one and FMTERR-04) FAIL on a temporarily-reverted
`ex_rte_taken` (the pre-fix formula) and PASS once restored, per this
project's own "prove it fails first" discipline. The A3.2 fix
(`fault_pc` source) is a small, structurally-identical mux change to
`bus_err_req_w`'s own already-proven precedent — not independently
re-verified with a dedicated full-chip decode-race test, given real
ROM-address-collision risk in `tb/stall_fsm_tb.sv`'s own already-dense
shared address map; the full regression suite below would catch any
resulting misbehavior. Full mandatory gate clean: `make test` 37/37,
`cosim_grp` 8/8, `cosim_memind` 28/28, `dat-synth` 50/50, full 124-suite
Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2 SKIP 281221
TIMEOUT 0` — Harte's own 68000-captured corpus has no format/version
field at all).

### Item 2 (MOVEM genuine memory-indirect EA) — IMPLEMENTED AND VERIFIED

Full plan detail in `~/.claude/plans/wobbly-honking-cascade.md` (Part
B); this entry is the closing writeup. Closes this project's own
memory-indirect-EA rollout in full — MOVEM was the one remaining family
without genuine `([bd,An],Xn,od)`/`([bd,An,Xn],od)` support (word-count
sizing was already fixed at Phase 234).

**Decode** (`rtl/eu_seq_decode.svh`, MOVEM's `f_mode==3'b110` arm): new
`fi_iis != 3'b000` branch reusing CMP2/CHK2's own shifted bd/od
extraction verbatim (Phase 244) — MOVEM's leading register-mask word
shifts bd/od one q-slot later than the generic single-word-baseline
formulas assume, identically to CMP2/CHK2's own leading Rn+flag word.
`movem_ext_count` (`m68030_seq.sv`) needed zero changes — it already
sized bd/od's own extra words generically, even before the EA *value*
itself was resolved correctly.

**Execute hand-off** (`rtl/eu_seq_execute.svh`): MOVEM is closer to
LEA/JMP/TAS's own "address-only" completion than to CMP2/CHK2's "outer
read produces a value" one — it wants the resolved address as
`movem_run_r`'s own starting point, not an operand. New
`movem_memind_pending_r`/`movem_memind_addr_r` registers (mirroring
`tas_memind_pending_r`) hand off from the memind FSM's own inner-read
completion to a new start branch in `movem_run_r`'s own FSM.
`memind_addr_only_r` extended to include `dec_is_movem`.
`movem_start_r`'s own original dispatch gains `&& !dec_is_memind`
(mask/load/predec/etc. capture stays unconditional — only the
`movem_start_r<=1` transition is gated). Two required exclusions, both
load-bearing: `memind_addr_wr_en` needs `&& !ex_is_movem` (else MOVEM's
resolved address would ALSO commit as a plain register write to
`memind_dest_r`, which defaults to 0/D0 since MOVEM never sets
`dec_dest_reg` — silent D0 corruption); `ex_mem_stall` needs
`movem_memind_pending_r` added (a genuine one-cycle gap between the
inner read's ack and `movem_run_r` actually starting, the same bug
class already found and fixed for `tas_memind_pending_r`/
`cmp2_memind_first_ack`).

**Found and fixed a real bug via a genuine cosim mismatch while building
the test, not guessed at**: the first decode implementation moved
Xn's own capture (`dec_dst_reg`/`dec_reads_dst`/`dec_xn_wl`/
`dec_xn_scale`, Xn → rd_b) into the non-indirect-only `else` branch,
mirroring the ORIGINAL code's own structure too literally. This broke
pre-indexed genuine-indirect MOVEM specifically (pre-indexed adds Xn
BEFORE the dereference, at the same `ex_ea` computation the inner
pointer read uses) — the inner read computed a wildly wrong address
(confirmed via a real buscmp mismatch: DUT read from `0x00004322`
instead of the expected `0x00002108`, since Xn's own register value was
never routed to `rd_b` for the indirect case). Root-caused via direct
opcode-encoding decode (not guessed) and fixed by hoisting Xn's capture
to be unconditional, matching CMP2/CHK2's own exact shared-prefix-then-
branch structure — only `dec_is_idx`'s own value (whether Xn is added
at THIS `ex_ea` specifically, vs. deferred to the memind FSM's own
`memind_post_xn_r` for post-indexed) actually differs between the two
cases, not whether Xn is read into `rd_b` at all.

**Test-construction findings** (neither an RTL bug): a genuine
single-register MOVEM list (`movem.w ...,a2`) is silently rewritten by
`vasmm68k_mot` into the equivalent plain `MOVEA.W` instruction — a real,
different opcode, confirmed via direct disassembly listing (`0x3470`,
not a MOVEM encoding at all) after a trace showed `dec_is_movem=0`
where `dec_is_memind=1` was expected together. Separately, two ADJACENT
word-sized MOVEM register transfers hit an already-known, pre-existing
benign Musashi-side quirk (coalescing them into one 32-bit reference
read where real 68030 silicon, and this DUT correctly, issues two
separate word-sized bus cycles) — the same "prefetch/read-granularity"
divergence class already documented for several earlier memind test
files in this project's history. `tests/memind42.s` was designed around
both: 2 registers each (forces genuine MOVEM encoding) and long size
(sidesteps the word-coalescing quirk entirely) — covers store+pre-
indexed and load+post-indexed. Confirmed an exact 37-cycle bus-trace
match against Musashi (`make cosim_memind`, wired in as
`buscmp-memind42`) — this exact match is itself strong evidence for
both B3 exclusions (a missing `memind_addr_wr_en` exclusion would have
shown up as a wrong stored value at Part 1's own target address; a
missing `ex_mem_stall` term would have shown up as a misplaced/extra
bus cycle in the trace — neither occurred).

Full mandatory gate clean: `make test` 37/37, `cosim_grp` 8/8,
`cosim_memind` 29/29 (28 existing + new memind42), `dat-synth` 50/50,
full 124-suite Harte sweep bit-identical to baseline (`PASS 702142 FAIL
2 SKIP 281221 TIMEOUT 0` — MOVEM's own genuine-indirect EA is
68020+-only, zero Harte coverage in the 68000-captured corpus).

**This closes Phase 251 in full** (item 1/F6 and item 2/MOVEM
implemented and verified; item 3/two-level-indirect corrected as a
documentation fix, see above) — and with it, the entire
`~/.claude/plans/wobbly-honking-cascade.md` plan the user approved for
this session's work.

## Phase 274 (post-Track-3 gap closure: preview now fires when CURRENT
is an ordinary write — IMPLEMENTED AND VERIFIED, a later session,
`~/.claude/plans/wobbly-honking-cascade.md`)

Found while building `timing_diagrams/`'s Figure 7-25 (Read-Write-
Write-Read chain) test program: `preview_current_ready`'s own ordinary
clause (`rtl/eu_seq_preview.svh`, the Track 3 preview mechanism's own
entry point) only ever fired when CURRENT was a READ (`ex_is_mem_rd`)
— an ordinary WRITE as CURRENT never triggered a preview of NEXT at
all, regardless of what NEXT was. Neither Track 2 (Stage 2.2 only ever
extended what NEXT is allowed to be — a plain write as the *upcoming*
instruction, never touching what CURRENT is allowed to be) nor any of
Track 3's 16 special-FSM families closed this gap either, since every
one of them is a read-final-beat family (their own `*_final_ack`
signals all key off a READ's own completing beat). Confirmed
empirically before touching any RTL: a throwaway write-then-write test
showed zero `preview_ok` engagement on either transition despite both
writes acking cleanly — the gap was real, not a rendering artifact.

**Fix**: mirrored the read clause exactly (`(ex_is_mem_rd ||
ex_is_mem_wr)`), re-verifying both of the read clause's own existing
exclusions fresh for the write side rather than assuming they carry
over unchanged:

- `!ex_is_move_reg_idx_dst` (MOVE Dn/An→`(d8,An,Xn)`, the Phase 149
  3rd-register-file-port case): confirmed via decode inspection it
  never sets `dec_is_mem_rd` (so it never collided with the pre-existing
  read clause — that exclusion there was dead code, though harmless),
  but it DOES set `dec_is_mem_wr` — kept excluded here too, matching the
  read clause's own conservative posture, since its own original
  rd_c-port-contention rationale, while stale post-Track-2, costs
  nothing to keep excluding for a rare instruction form.
- `!ex_is_pmove64`: confirmed PMOVE64's own STORE direction also sets
  `dec_is_mem_wr=1'b1` for its phase-0 write (`rtl/eu_seq_decode.svh`
  line ~6266) — the identical regression shape as the original Phase
  264 read-side PMOVE64 regression (Track 3 #7) — caught by direct
  inspection this time, before it could ship as a live bug, rather than
  discovered the hard way via a sim hang as Phase 264 was.

**No new hazard signal needed**: confirmed via direct inspection that
`hazard_ex`'s own generic An-update clause (`ex_valid && ex_an_upd_en
&& !ex_is_mem_rmw && (dec_reads_src/dst/c matches ex_an_upd_reg)`) —
already asserted for the whole EX residency of any auto-inc/dec write,
including the new trigger's own cycle — already fully covers every
ordinary write's own EA-register hazard. `ex_is_mem_rmw` is the clause's
only pre-existing exclusion (mem_rmw has its own dedicated
`mem_rmw_hazard` from Track 3 #13), irrelevant here since ordinary
writes never set it.

**Verification**: two new dedicated cosim tests,
`tests/timing_preview_write_chain.s` (zero-hazard write→write chain,
matches Musashi's own bus trace exactly) and
`tests/timing_preview_write_chain_hazard.s` (a predecrement write
immediately followed by a dependent write to the same
just-decremented address, confirmed blocked via direct debug trace).
The hazard test's own `buscmp.py` comparison is NOT clean, for a
reason unrelated to this fix: Musashi's own reference model splits
`MOVE.L Dn,-(An)` into 2 separate WORD writes (confirmed via an
isolated single-instruction check, `MOVE.L D0,-(A1)` alone with no
preview involved at all, reproducing the split regardless of any
change made this session) — real 68030 silicon with a 32-bit port does
one longword write, matching this DUT; Musashi's own model appears to
default to word-granularity for predecrement addressing. Verified the
hazard-blocking behavior via debug trace instead, matching this
project's own established precedent for this exact situation (e.g. the
PACK/bitfield-mem Musashi-divergence findings, Track 3 #5/#6).

Full mandatory gate clean (`make test` 37/37, `cosim_grp` 8/8,
`cosim_memind` 29/29, `dat-synth` 50/50), full 124-suite Harte sweep
bit-identical to baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`).

## Phase 275 (`biu_cache_if.sv`'s `CI_WRITE` completion missing its own
`eu_new_dispatch` fast-path check — IMPLEMENTED AND VERIFIED, closes
this session's own post-Track-3 work, `~/.claude/plans/
wobbly-honking-cascade.md`)

Found while re-testing the Figure 7-25 diagram after Phase 274's own
write-as-CURRENT preview fix landed: write→write chaining now looked
gap-free, but write→read-miss still showed a real one-tick `--` gap in
the rendered diagram, even though `preview_ok`/`eu_new_dispatch` were
confirmed (via direct trace) already asserted at the exact cycle
`CI_WRITE`'s own completion runs.

**Root cause** (found by direct inspection, not guessed at): `grep`
for `eu_new_dispatch` in `rtl/biu_cache_if.sv` showed it used in
exactly one place — `CI_D_MISS`'s own `sf_ack_rise` completion block
(the Phase 254 fast path: when NEXT is a genuine read-miss ready to
dispatch, skip the one-tick `CI_IDLE` detour and land directly back in
`CI_D_MISS`). `CI_WRITE`'s own analogous completion block, reached on
the identical `sf_ack_rise` condition, had no equivalent check at all
— it unconditionally executed a plain `state <= CI_IDLE;`, so ANY
access following a write always took the one-tick `CI_IDLE` detour
regardless of what `eu_new_dispatch` said. This also explained why
write→write chaining had looked gap-free even BEFORE Phase 274's own
fix: that gap-free appearance came entirely from a separate,
pre-existing mechanism — "Track A" (Phase 163/Phase 247 item #10), an
unconditional write/cache-hit fast path inside `CI_IDLE` itself that
never consulted `eu_new_dispatch` at all — not from the `eu_new_dispatch`
mechanism this phase closes. Write→read-miss specifically needs the
`eu_new_dispatch`-gated path that, until this fix, only `CI_D_MISS`'s
own completion ever checked.

**Fix**: copied `CI_D_MISS`'s own fast-path condition and full
register-set block verbatim into `CI_WRITE`'s own completion branch —
`if (eu_req && eu_new_dispatch && eu_rw && !dhit && !tc_e &&
!(dcache_en && dburst_en && d_size_ok && !dfreeze_en))` dispatches
directly into a fresh `CI_D_MISS` (loading `addr_r`/`wdata_r`/`fc_r`/
`rw_r`/`siz_r`/`idx_r`/`woff_r`/`vtag_r`/`fill_base_r`/`xl_ci_r` exactly
as `CI_D_MISS`'s own completion does); otherwise falls through to the
original, unmodified `state <= CI_IDLE;`. Reusing the identical,
already-twice-hardened `eu_new_dispatch`-gated condition (an explicit
signal, never inferred from address inequality — see the Phase 254
history and `feedback_post_ack_signal_reuse.md`) rather than inventing
a new one, matching this module's own established precedent that any
new fast path here must reuse proven-safe machinery given its own
extensively-documented delicacy (Phase 228/246/250-Part-B, the
bus-pipelining-overlap plan, and Phase 253's own two-attempt/revert
history for a structurally similar fast path in this exact module).

**Verification**: `make test` 37/37 (including the `cache` suite),
`cosim_grp` 8/8, `cosim_memind` 29/29, `dat-synth` 50/50,
`tb/cache_tb.sv` run standalone (all D-cache write-hit/write-allocate
tests pass — extra-confidence given this fix directly touches the
D-cache write path), full 124-suite Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`). The Figure 7-25
diagram now shows zero `--` gap across all 4 chained cycles
(read→write→write→read), regenerated and re-verified via direct JSON
inspection post-fix.

**Closes this session's own post-Track-3 work** — both gaps the
Figure 7-25 diagram's own construction surfaced (Phase 274's
write-as-CURRENT preview gap and this phase's `CI_WRITE` fast-path
gap) are now fixed, matching real 68030 silicon's own zero-idle-gap
chained-cycle timing (MC68030UM.pdf Figure 7-25) for this instruction
sequence shape.

## Phase 276 (bitfield-mem always-longword bus access sizing —
IMPLEMENTED AND VERIFIED, `project_bf_mem_longword_sizing_bug.md`, a
later session)

Real, pre-existing, previously-documented-but-deferred gap: found at
Phase 262 (Track 3 #5, while building the bitfield-mem preview cosim
test) and explicitly left unfixed at the time as out of scope for that
track's own dispatch-gap work. User asked to fix it directly this
session.

**The bug**: `rtl/eu_seq_execute.svh`'s `bf_mem_run_r` FSM (the shared
memory-EA dispatch path for BFCHG/BFCLR/BFSET/BFINS/BFEXTU/BFEXTS/
BFFFO/BFTST) always issued a fixed 4-byte LONGWORD read (and, for the
4 mutating ops, write) at the field's own base address, regardless of
the field's real offset+width footprint. Real 68030 silicon (confirmed
against Musashi's own `m68ki_load_bitfield`/`m68ki_store_bitfield`,
`tools/musashi/m68kcpu.h`) computes the MINIMAL real footprint instead:
`bcount = (offset%8 + width + 7) / 8`, giving 1 (BYTE), 2 (WORD), 3
(WORD then BYTE, two sub-accesses), 4 (LONGWORD), or 5 (LONGWORD then
BYTE — this last case only when the field spans a 5th byte, i.e.
offset+width>32) bytes, starting at `ea + offset/8`, not always a fixed
4 bytes at `ea`.

**Root cause / fix, re-derived directly against this project's own
framing** (not a literal port of Musashi's own patched-address model):
`eu_bitfield.sv`'s own `bf_offset` input is UNPATCHED (0-31, treating
byte 0 = the field's base address itself), so rather than patching the
address AND re-deriving a patched sub-8 offset (Musashi's own
approach), this fix keeps `eu_bitfield.sv` completely untouched and
instead computes, at dispatch time (`bf_disp_*` combinational signals,
derived from the live `ex_imm` the moment a bit-field memory-EA
instruction is about to dispatch):
- `byte_start` (0-3) = `offset[4:3]` — which byte of the virtual,
  4-byte-wide "as if fully read/written" span the footprint starts at.
- `span` (1-4) = `byte_end - byte_start + 1`, where `byte_end =
  (offset+width-1)>>3` — how many bytes the real footprint covers.
  Scoped to `offset+width<=32` (`bf_disp_in_envelope_v`) — the ONLY
  envelope in which the CURRENT (pre-fix) longword-only access was
  even value-correct to begin with (`eu_bitfield.sv`'s own header
  comment already states its own `offset+width<=32` restriction
  directly — the `>32` case is a separate, deeper, pre-existing gap in
  that module too, not introduced or worsened here, and deliberately
  left exactly as before: falls back to the old fixed-longword-at-
  byte_start-0 access, matching this project's own established
  precedent for "found harder than expected, document don't fix" when
  a gap is discovered mid-implementation but is genuinely out of
  scope).
- `siz1` (the only, or first, sub-access's SIZ) = byte/word/long
  matching `span` (1→01, 2 or 3→10, 4→00).
- `has_sub2` = `(span==3)` — the one case needing a second (BYTE)
  sub-access 2 bytes past the first (WORD) sub-access.

New FSM state: `bf_mem_byte_start_r`/`bf_mem_siz1_r`/
`bf_mem_has_sub2_r` (captured once at dispatch) plus `bf_mem_sub_r`
(0=first sub-access in flight, 1=second) and `bf_mem_word_contrib_r`
(holds the first sub-read's own shifted contribution while waiting for
the second). `mem_addr`/`mem_siz` for the `bf_mem_run_r` branch now
compute the real per-sub-access address/size instead of the fixed
`bf_mem_addr_r`/`2'b00`. A new `bf_mem_sub_last` wire (`!has_sub2 ||
sub_r`) gates every "this phase is genuinely done" transition
(`bf_mem_stall`'s own completion, `bf_dn_wr_en`, `bf_mem_sr_wr_en`, and
the FSM's own phase-advance logic) so a 3-byte footprint's own
intermediate (first) sub-access ack is never mistaken for real
completion.

**Two new helper functions, `bf_place`/`bf_extract`** (`rtl/
eu_seq_execute.svh`), convert between a real bus transfer and the
"virtual full-longword-relative" position `eu_bitfield.sv`'s own
unpatched `bf_offset` expects (byte0@[31:24], byte1@[23:16], etc.,
big-endian). `bf_data_mux`'s own read-phase branch (feeding
`eu_bitfield`) and the register capture (`bf_mem_data_r`) both now use
`bf_place`'s assembled value instead of raw `mem_rdata` directly;
`mem_wdata`'s own write-phase branch uses `bf_extract` to pull the
correct sub-portion out of the assembled write-back result
(`bf_result_w`).

**Bug found and fixed before shipping, via a real cosim mismatch, not
guessed at**: `bf_place`'s own first implementation assumed READS use
the SAME top-justified convention `eu_lane`'s own header comment
documents for WRITES (byte@[31:24]) — this is WRONG for reads.
Confirmed via a direct debug trace on the real, full BIU-backed
pipeline (`cosim_grp_tb.sv`, not a simplified unit testbench) that
`mem_rdata` for reads is instead RIGHT-justified (byte@[7:0],
word@[15:0]) — an asymmetric read/write convention this project's own
existing code already relied on elsewhere (e.g. `alu_src_mem`'s own
sign-extension from bit 15, treating a word read as already
right-justified) but had never been stated explicitly anywhere `bf_place`
could have referenced it. The wrong assumption produced an all-zero
assembled value, caught by `tests/bf_sizing2.s`'s own cosim mismatch
before it shipped. Fixed by top-justifying the right-justified raw
value FIRST (mirroring `eu_lane`'s own write-side transform), then
shifting into the virtual position — `bf_extract` (the write side)
needed no equivalent fix, since its own job (assembled-value →
top-justified write lane) was already correctly oriented.

**Two more real, previously-latent bugs found while building the
dedicated cosim tests, both pure testbench gaps, neither an RTL
issue**: `tb/bitfield_tb.sv`'s own inline memory model always read/
wrote the WHOLE longword regardless of `mem_siz` — harmless as long as
`bf_mem_run_r` never dispatched anything but a longword (true before
this fix), but exposed once it started dispatching genuine narrow
accesses: a byte/word WRITE would silently clobber the OTHER,
untouched bytes of the same memory word (three existing mutating-op
tests, BFCLR-02/BFSET-02/BFINS-02, are the first in this file to write
a narrow size onto a location with non-zero surrounding bytes — every
earlier byte/word-write test here happened to pre-zero its own target
first, masking the gap entirely), and a byte/word READ at non-zero
A[1:0] would return the wrong lane. Fixed with a proper lane-aware
read/write model, matching the SAME asymmetric convention just
confirmed for the real pipeline (write: top-justified, replicated
byte-lane-style per `mem_addr[1:0]`; read: right-justified, gathered
from the correct real lane per `mem_addr[1:0]`) — an initial attempt at
this fix used the WRONG (top-justified) convention for the read side
too, caught immediately by BFTST-03/BFEXTU-02 regressing, fixed the
same way `bf_place`'s own analogous mistake was.

Separately, `tb/ea_extended_tb.sv`'s own memory model had NO byte-size
read case at all (always fell through to the raw full-longword
branch) — adding one (right-justified, matching the now-confirmed real
convention) surfaced a THIRD, independent, previously-latent bug: the
pre-existing TAS-01 test's own memory SETUP placed its byte test value
at bits[7:0], inconsistent with this SAME array's own established
big-endian convention every other test in the file uses (byte at
address%4==0 → bits[31:24] — confirmed by TAS-01's own ALREADY-CORRECT
expected post-TAS value, `0xC2000000`, at that SAME standard
position). This was previously masked by two independent testbench
bugs silently canceling out: the OLD memory model's own byte-read
fallback returned the raw, unmodified longword (0x00000042, i.e. the
value AT bits[7:0] where the test had — wrongly — placed it), and
TAS's own real `mem_rdata` consumption (confirmed right-justified, the
SAME convention this whole investigation established) happens to
expect the value at bits[7:0] too — so the WRONG data placement
"worked" purely by coincidence with the WRONG memory-model fallback.
Fixed the test's own setup (`32'h4200_0000` instead of
`32'h0000_0042`) to match the array's own already-correct convention,
rather than touching the (now correct) memory model.

**Verification**: two new dedicated cosim tests, `tests/bf_sizing1.s`
(`BFCLR (A0){0:8}`, the span==1 case — matches the narrow field Phase
262's own original finding used) and `tests/bf_sizing2.s` (`BFCLR
(A0){0:20}`, the harder span==3 word+byte case), both match Musashi's
own bus trace exactly, wired into `make cosim_memind` as
`buscmp-bf_sizing1`/`buscmp-bf_sizing2` (31/31 total). Both deliberately
use address `$100`, not a larger address like `$3010` — an early
attempt at `$3010` was found, via a genuine corrupted-execution
failure (not guessed at), to alias onto code space within `tools/
m68ksim`'s own 4KB reference window, corrupting the test program's own
not-yet-fetched instructions; `$100` matches this project's own
established memind-test convention for exactly this reason. Neither
test needs the `MULU.L`-stall trick Track 3's own preview tests use
(that trick exists specifically to give the IFU's prefetch queue a
head start before a PREVIEW trigger fires — irrelevant here, since
`bf_mem_run_r` dispatches on ordinary EX-stage entry, not a preview);
an early attempt included it anyway and produced extra, benign
IFU-readahead prefetch cycles that shifted the DUT/reference cycle
alignment, confirmed via inspection to be the same already-documented
benign reordering artifact this project has seen many times before,
not a new bug — removed rather than worked around.

Full mandatory gate clean: `make test` 37/37 (including `bitfield`
24/24 and `ea_extended` 27/27), `cosim_grp` 8/8, `cosim_memind` 31/31,
`dat-synth` 50/50, full 124-suite Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` — bitfield
memory-EA forms have zero Harte coverage, 68020+-only).

**Closes `project_bf_mem_longword_sizing_bug.md` in full.**

## Phase 277 (PACK/UNPK-mem source/destination byte access order —
IMPLEMENTED AND VERIFIED, `project_pack_source_read_order_bug.md`, a
later session)

Real, pre-existing, previously-documented-but-deferred gap: found at
Phase 263 (Track 3 #6, while building the PACK/UNPK-mem preview cosim
test) and explicitly left unfixed at the time as out of scope for that
track's own dispatch-gap work. User asked to fix it directly this
session, immediately following Phase 276's own bitfield-mem sizing fix
(the two bugs were found in the same investigation and share several
techniques and lessons).

**The bug**: `rtl/eu_seq_execute.svh`'s `pack_mem_run_r` FSM (the
shared 2-phase read/write dispatch path for PACK/UNPK's memory-to-
memory forms, `PACK -(Ay),-(Ax),#data`/`UNPK -(Ay),-(Ax),#data`) issued
PACK's own source read as a SINGLE 16-bit WORD access, and UNPK's own
destination write as a SINGLE 16-bit WORD access. Real 68030 silicon
does neither — confirmed directly against Musashi's own
`m68k_op_pack_16_mm`/`m68k_op_unpk_16_mm` (`tools/musashi/m68kops.c`):

```c
/* PACK's own source read */
uint ea_src = EA_AY_PD_8();       /* Ay -= 1 */
uint src = m68ki_read_8(ea_src);
ea_src = EA_AY_PD_8();            /* Ay -= 1 again */
src = ((src << 8) | m68ki_read_8(ea_src)) + OPER_I_16();
```

Each is genuinely TWO SEPARATE BYTE accesses via two independent
1-byte predecrements — a direct artifact of the real microcode
literally being "decrement, read/write, shift-and-combine; decrement
again, read/write, combine again," not a real 16-bit bus transfer. The
FIRST access (at the address closer to the original An, i.e. An-1)
lands in the HIGH half of the intermediate 16-bit value; the SECOND
(An-2, the final An) lands in the LOW half — the OPPOSITE of a
standard big-endian word access, where the LOWER address holds the
HIGH byte. UNPK's own destination write is the exact mirror image:
`m68ki_write_8(EA_AX_PD_8(), (src>>8)&0xff)` (HIGH byte, first) then
`m68ki_write_8(EA_AX_PD_8(), src&0xff)` (LOW byte, second) — same
reversed order. PACK's own destination write (one BYTE, `-(Ax)`) and
UNPK's own source read (one BYTE, `-(Ay)`) were both already correct
in this RTL (each genuinely is just one byte on real hardware too;
confirmed by direct inspection, not assumed).

**Fix**: extended the existing 2-phase `pack_mem_run_r` FSM
(`pack_mem_phase_r`: 0=read, 1=write) with a new `pack_mem_sub_r` bit
(0=first sub-access in flight, 1=second) and `pack_mem_byte1_r`
(captures PACK's own first sub-read byte, the future HIGH byte, while
waiting for the second). A new `pack_mem_needs_sub2 = pack_mem_is_unpk_r ?
pack_mem_phase_r : !pack_mem_phase_r` wire identifies the one case (of
the four phase×instruction combinations) needing a second sub-access
for each instruction: PACK's own READ phase, or UNPK's own WRITE
phase. `pack_mem_sub_last = !pack_mem_needs_sub2 || pack_mem_sub_r`
mirrors `bf_mem_sub_last`'s own identical role in Phase 276's bitfield
fix exactly, gating every "this phase is genuinely done" transition:
`pack_mem_stall`'s own completion condition, `pack_ay_wr_en`/
`pack_ax_wr_en` (the An-register commit — without this gate, a 2-sub-
access phase would commit the SAME correct final address twice, once
per sub-access, a harmless value-wise but structurally wrong double-
fire), and Track 3's own `pack_mem_final_ack` preview trigger
(`rtl/eu_seq_preview.svh`) — without this last one, UNPK's own preview
would fire one beat early, off the first (intermediate) sub-write's
own ack rather than the true final one.

`mem_addr`'s own `pack_mem_run_r` branch now adds `+1` to the base
(already-fully-predecremented) address for the FIRST sub-access of
whichever phase needs 2, `+0` for the second/only access — the base
address itself (`pack_mem_ay_addr_r`/`pack_mem_ax_addr_r`) is unchanged,
still computed once at dispatch as the FINAL predecremented value; only
the per-sub-access OFFSET from it is new. `pack_mem_cur_siz` simplifies
to a plain constant `2'b01` — EVERY PACK/UNPK-mem sub-access is now
byte-sized (PACK's read: 2 byte sub-reads, was 1 word; UNPK's write: 2
byte sub-writes, was 1 word; PACK's write and UNPK's read: already 1
byte each, unchanged). `pack_mem_wdata_w`'s own UNPK branch now
extracts `pack_mem_temp_w[15:8]` (HIGH byte, sub 0) or `[7:0]` (LOW
byte, sub 1) instead of writing the whole 16-bit `temp` as one word;
PACK's own write-side formula is untouched (was always correct).
`pack_mem_src_r`'s own PACK-read assembly (`{16'h0, pack_mem_byte1_r,
mem_rdata[7:0]}`, built on the SECOND sub-read's own ack) reconstructs
the exact same `{high,low}` 16-bit value Musashi's own `(src<<8)|byte2`
formula produces — confirmed via the dedicated cosim tests below, not
just by symbolic derivation.

**Confirmed `mem_rdata` for reads is RIGHT-justified** (the same fact
Phase 276's own `bf_place` investigation established, reused directly
here rather than re-derived): `mem_rdata[7:0]` is the correct
extraction for each byte sub-read, needing no additional shifting —
this reuse, not a fresh re-derivation, is why this fix needed no
equivalent "wrong justification assumption" debugging round the
bitfield fix went through.

**Real, previously-latent regressions found while updating this
session's own tests — none an RTL bug, all pre-existing testbench-only
gaps, several matching the exact TAS-01 shape Phase 276 already
found once**:

1. `tb/stall_fsm_tb.sv`'s own `INT-mid-PACK` test had a hardcoded
   `expected_bus_cycles=2` (1 word read + 1 byte write, matching the
   OLD, buggy RTL exactly — this test's own comment even documented
   having empirically confirmed "2, not 3" against the pre-fix RTL at
   the time it was written). Now genuinely 3 (2 source byte reads + 1
   destination byte write) — updated to match. A second reference to
   this same "2-bus-cycle" fact, in `WS-PACK`'s own comment (a
   different test, checking only a RELATIVE wait-states-lengthen-it
   comparison, not an absolute count, so functionally unaffected),
   was also corrected to avoid leaving stale documentation nearby.

2. `tb/bcd_pack_tb.sv`'s own inline memory model had the identical
   "always reads/writes the WHOLE longword regardless of `mem_siz`"
   gap already found and fixed twice earlier this same session
   (`tb/bitfield_tb.sv`, `tb/ea_extended_tb.sv`) — dormant here too
   since PACK/UNPK-mem had never dispatched a genuine sub-access at a
   real, non-coincidentally-aligned byte address before. Fixed with
   the same lane-aware read (right-justified)/write (top-justified,
   per-lane, preserving untouched bytes) model.

3. Fixing that memory model surfaced THREE more independent,
   previously-latent bugs in this file's own EXISTING, unrelated
   NBCD-01/ABCD-01/SBCD-01 tests — the exact same shape as the TAS-01
   bug Phase 276 found: each test's own byte value (NBCD-01's own
   SETUP) or expected result (ABCD-01's/SBCD-01's own CHECK) had been
   placed at the WRONG bit position relative to its real target
   address's own real big-endian lane (address `mod 4`, per this
   array's own established convention — confirmed directly, not
   assumed, by checking every other correctly-behaving test in the
   same file). Masked for years by the OLD memory model's own address-
   blind read/write behavior coincidentally canceling out against each
   instruction's own real mem_rdata/mem_wdata convention, for whichever
   specific address happened to be used — NBCD-01's target (offset 0)
   happened to need the fix in its SETUP; ABCD-01's and SBCD-01's
   targets (offset 3 in both cases) happened to need it in their own
   CHECK instead, a data point that by itself confirms this was
   genuinely address-dependent, not a single systematic transcription
   error. Fixed each to match its own real target address's own real
   lane, re-deriving from first principles rather than guessing at a
   single global convention.

**Verification**: two new dedicated cosim tests, `tests/pack_order1.s`
(`PACK -(A0),-(A1),#0`, confirms the reversed 2-byte READ order) and
`tests/pack_order2.s` (`UNPK -(A0),-(A1),#0`, confirms the reversed
2-byte WRITE order), both match Musashi's own bus trace exactly, wired
into `make cosim_memind` as `buscmp-pack_order1`/`buscmp-pack_order2`
(33/33 total). Both deliberately use addresses within `tools/m68ksim`'s
own 4KB reference window (`$120`/`$140`, `$160`/`$182`), matching this
project's own established memind-test convention (Phase 274 already
found the hard way, via a genuine corrupted-execution failure, that an
address outside that window silently aliases onto code space).

Full mandatory gate clean: `make test` 37/37 (including `bcd_pack`
23/23 and `stall_fsm`), `cosim_grp` 8/8, `cosim_memind` 33/33,
`dat-synth` 50/50, full 124-suite Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` — PACK/UNPK have
zero Harte coverage, 68020+-only).

**Closes `project_pack_source_read_order_bug.md` in full**, and with
it, both of the two real, previously-deferred bugs Track 3's own
Phase 262/263 investigation found and documented but didn't fix at the
time.

## Phase 278 (level-7/NMI interrupt-mask-tie recognition gap —
IMPLEMENTED AND VERIFIED, `project_int_pending_level7_mask_gap.md`, a
later session)

Real, pre-existing, previously-documented-but-deferred gap: found while
building `timing_diagrams/`'s Figure 7-44/7-45 diagram (a materially
different task than an RTL-correctness investigation, so deliberately
not chased at the time) and explicitly flagged as unfixed. User asked
to fix it directly this session.

**The bug**: `rtl/m68030_exc.sv`'s `int_pending` formula —
`(ipl_sync_l != 3'b000) && (ipl_sync_l > ipl_mask_l)` — is a plain
LEVEL comparison, identical for every IPL level 1-7. Real 68k
architecture requires level 7 to be effectively non-maskable: it must
be recognized on any TRANSITION into level 7 regardless of the current
SR interrupt mask, not gated by the same `requested > mask` check every
other level uses. Since `7 > 7` is always false, this formula silently
dropped any level-7 request asserted while the mask already sat at 7 —
which is exactly SR's own reset-default state (`SR=$2700`), so a
level-7 request asserted before anything ever lowered the mask was
never recognized. Confirmed via direct signal trace
(`ipl_sync_l`/`ipl_mask_l`/`int_pending` all sampled explicitly) before
fixing, not assumed. Never caught before because every existing
Level-7 test (`tb/stall_fsm_tb.sv`'s own Category F, 17 sources)
injects the interrupt deep into an already-running program that has
long since executed a mask-lowering instruction.

**Fix**: a new sticky edge-detect latch, `nmi_pending_r`, ORed into
`int_pending` alongside the existing formula. A 1-cycle-delayed
`ipl_sync_prev_r` register detects any transition of the synchronized
IPL lines into `3'b111` (level 7); on that edge `nmi_pending_r` sets
unconditionally (bypassing the mask entirely), and clears again once
the interrupt actually dispatches (`state_r==EXC_IDLE && exc_pending &&
pend_is_int`, the same dispatch point `snap_is_int_r` already captures
at) — so a later IPL drop-then-re-assert-to-7 can latch again, matching
real silicon's own "recognized once per transition" behavior rather
than turning one held request into a re-triggering storm. Icarus
required the new `always_ff` block placed textually after
`state_r`/`exc_pending`/`pend_is_int` are declared (a procedural-block
forward-reference restriction, not a real dependency — the block is
otherwise fully independent of the main FSM's own sequential block);
the `nmi_pending_r`/`ipl_sync_prev_r` declarations and the `int_pending`
assign itself stayed at their original location near the top of the
file, only the `always_ff` body moved.

**A genuinely separate, pre-existing test-construction bug found while
verifying this fix end-to-end** (unrelated to the RTL, and not
introduced by this fix): `tests/timing_manual_744.s` placed the level-7
handler's own code directly at the vector table address (`org $7C \n
handler7: rte`) instead of storing a POINTER there — real 68k vector-
table semantics, confirmed directly against `m68030_exc.sv`'s own
`EXC_FETCH` state, which performs a genuine bus read of the table entry
and loads THAT VALUE as the new PC, not the table address's own literal
opcode bytes. A full RTE round-trip through this handler would hang
(confirmed by directly re-running the ORIGINAL, un-modified diagram
test in isolation — it hung identically, entirely independent of this
session's own RTL fix), but this was never caught because the diagram
itself only needs the early IACK/frame-push dispatch waveform, not full
completion. Fixed alongside this RTL fix: the vector table entry at
`$7C` now stores a pointer to the real handler at `$200`; the test
program's own SR-lowering workaround (`move.w #$2000,sr`, needed only
because of the RTL bug above) was also removed, so the diagram now
exercises the real, harder scenario (mask stays at its reset-default 7
throughout) directly. The diagram's own testbench
(`timing_diagrams/tb/manual_744_tb.sv`) additionally needed to wait for
the test program's own read cycle to genuinely complete
(`d_reg[0]===32'hCAFE_F00D`) before asserting the interrupt — recognition
is now fast enough that asserting it immediately at reset (the
testbench's own original approach, written before this fix existed)
preempted the read cycle entirely, breaking the diagram's own intended
"read, then interrupt" narrative (confirmed via a direct look at the
first rebuilt waveform, which showed the IACK cycle jumping straight off
the reset-vector fetch with no `$3010` access anywhere in it). Both the
manual crop and sim waveform for Figure 7-44/7-45 were regenerated and
re-verified correct.

**Verification**: a new dedicated regression test, `tb/stall_fsm_tb.sv`'s
`INT-mask-tie` — explicitly re-elevates SR's mask back to 7 mid-program
via `MOVE.W #$2700,SR` (rather than relying on being first in program
order, which is fragile in this shared, single-continuous-program
testbench), then asserts a fresh level-7 edge and confirms recognition
via `exc_active` leaving `EXC_IDLE`. Confirmed via a temporary disabled-
fix rebuild (`assign int_pending = 1'b0 && nmi_pending_r || ...`) that
this test correctly and cleanly fails (without hanging — the CPU keeps
running its own unstalled register-only code regardless) when the fix
is absent. An earlier version of this test also tried to pre-clear D6
(the shared handler's own completion marker) via a `CLR.L D6` placed in
the test's own code just before the injection point, guarding against a
stale `12345` left over from an earlier interrupt test — this raced
against `int_defer` itself (Phase 108) and produced a false failure,
documented as its own lesson in `feedback_interrupt_defer_marker_race.md`;
the final test avoids the class entirely by checking `exc_active`
(the direct, decisive signal) rather than a marker register shared with
the handler.

Full mandatory gate clean: `make test` 37/37 (including the new
`INT-mask-tie` case), `cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth`
50/50, full 124-suite Harte sweep bit-identical to baseline (`PASS
702142 FAIL 2 SKIP 281221 TIMEOUT 0` — interrupt-mask edge cases have no
Harte coverage, the corpus captures 68000-single-step vectors with no
real interrupt sequences).

**Closes `project_int_pending_level7_mask_gap.md` in full.**

## Phase 279 (BERR-without-HALT infinite retry loop — IMPLEMENTED AND
VERIFIED, `project_berr_no_halt_retry_loop.md`, a later session)

Real, pre-existing, previously-documented-but-not-root-caused gap:
found while building `timing_diagrams/`'s Figure 7-49 diagram and
explicitly flagged as unfixed at the time (out of scope for a
pin-timing task). User asked to fix it directly this session,
immediately following Phase 278's own level-7 fix.

**The bug**: an ordinary EU-initiated read to a non-responding address,
terminated by a plain `/BERR` (no `/HALT`), made the CPU repeatedly
re-dispatch the same faulting access roughly every 8 ticks instead of
ever completing Bus Error exception dispatch.

**Root cause**, found via direct per-tick signal tracing (a standalone
testbench mirroring `timing_diagrams/tb/manual_749_tb.sv`'s own
scenario, instrumented across every layer from the EU port down to the
external pins): `rtl/biu_sizing_fsm.sv` — the dynamic bus-sizing module
sitting between `biu_cache_if.sv` and `biu_cycle_gen.sv`
(`EU → biu_cache_if → biu_sizing_fsm → biu_cycle_gen`) — had **no
BERR-abort path of any kind** (confirmed via grep: zero occurrences of
"berr" anywhere in the file before this fix). Its `SS_IDLE ->
SS_ACTIVE -> SS_IDLE` state machine only ever exits `SS_ACTIVE` on
`cyc_ack_edge` (a rising edge of cycle_gen's own success ack), which a
genuinely faulted cycle never produces. `biu_cache_if.sv` itself
already had a correct, working abort path (`CI_BERR`, added back in
Phase 108/109) and cleanly returned to `CI_IDLE` on a fault — but
`biu_sizing_fsm.sv`, one layer further down, had zero visibility into
`cg_eu_berr_raw` at all, and was left stuck in `SS_ACTIVE` forever,
continuously re-presenting the STALE faulting `sf_addr`/`cyc_req=1` to
`biu_cycle_gen` regardless of what `biu_cache_if.sv` (already idle) or
the exception controller (trying to dispatch its own frame-push write)
actually wanted to send next. Confirmed via trace exactly what this
caused downstream: once the exception controller recognized the fault
and tried to write its stack frame (e.g. to `$FFFC`), `biu_eu_addr`
correctly showed the new address at the EU-port level, but
`biu_sizing_fsm.sv`'s own `cyc_addr` output (feeding `biu_cycle_gen`
directly) stayed latched at the ORIGINAL faulting address the entire
time — the frame-push write never reached the bus at all; instead the
same faulting read kept re-executing, which (since the exception
controller was already mid-dispatch) got misinterpreted as a second bus
error occurring DURING dispatch of the first, incorrectly triggering
the genuine double-bus-fault path (`EXC_DBLFAULT`, Phase 250 Part B)
even though no real double fault ever occurred.

**Fix**: added a new `cyc_berr` input to `biu_sizing_fsm.sv`, wired from
`cg_eu_berr_raw` — the exact same raw signal `biu_cache_if.sv`'s own
`sf_berr` input already uses (`rtl/m68030_biu.sv`'s `u_sf`
instantiation, plus `tb/biu_tb.sv`'s own standalone unit-test
instantiation). When `cyc_berr` pulses while `sf==SS_ACTIVE`, both the
sequential (`sf_accum` reset, mirroring `SS_IDLE`'s own fresh-request
reset) and next-state (`sf_nxt=SS_IDLE`) logic now abort cleanly back
to idle, mirroring `biu_cache_if.sv`'s own `CI_BERR` treatment exactly
— checked before `cyc_ack_edge` in the next-state logic (the two are
mutually exclusive per cycle_gen's own combinational eu_ack/eu_berr
split, but this ordering documents the abort as taking priority). No
new output was needed: `biu_cache_if.sv`'s own abort reaction was
already correct and independent (it reads `cg_eu_berr_raw` directly,
not through `biu_sizing_fsm.sv`), so this fix only needed to stop
`biu_sizing_fsm.sv` from continuing to feed it stale requests.

**A second, real bug found and fixed while verifying end-to-end**:
`tb/biu_tb.sv`'s own pre-existing "Retry exhausted" test (BERR+HALT
retry-exhaustion coverage) started failing once this fix was in place —
not because the fix was wrong, but because the test's own construction
asserted `halt_tb` and `eu_req_tb` in the same simulation delta,
implicitly relying on `halt_s`'s own 2-stage synchronizer not yet
having caught up by the time the first cycle dispatched (the BERR+HALT
retry mechanism requires HALT to be recognized only AFTER a cycle has
already started — `biu_cycle_gen.sv`'s own ST_IDLE case has an explicit
"Retry takes priority over HALT# — bus was already committed" comment,
and a SEPARATE "HALT# asserted (standalone, no BERR): suspend new bus
cycles" rule that permanently blocks dispatch if HALT is already
asserted before any cycle starts). This fix's own correctness change
elsewhere in the same simulation run shifted that implicit race
unfavorably, exposing the test's own latent fragility (confirmed by
checking the SAME test against the unmodified baseline RTL first,
before assuming the new RTL change was at fault — it passed there,
proving the race, not the fix, was the problem). Fixed by making the
test explicitly wait for the cycle to genuinely start (`bus_idle`
drops) before asserting HALT, matching the test's own already-documented
intent directly instead of depending on an implicit race.

**Verification**: a new dedicated regression in `tb/biu_tb.sv` ("Plain
BERR (no HALT) then a fresh dispatch to a different address") —
triggers a plain BERR at one address, then immediately issues a FRESH
dispatch to a different, working address, and checks (a) the
dispatched `cyc_addr` is the NEW address, not the stale fault address,
and (b) the fresh dispatch completes cleanly (`eu_ack`, not stuck or
re-faulted). Confirmed via a temporary disabled-fix rebuild
(`if (1'b0 && cyc_berr) ...`) that the decisive address check correctly
fails without the fix. Also independently confirmed end-to-end via a
standalone testbench reproducing the exact
`timing_diagrams/tests/timing_manual_749.s` scenario: the exception now
genuinely completes (`d_reg[5]` reaches 99, the handler's own
completion marker; `decode_pc` settles inside the handler's own
self-loop) where before it hung forever. The Figure 7-49 diagram's own
testbench (`timing_diagrams/tb/manual_749_tb.sv`) needed its own run
length re-tuned as a direct consequence of the fix actually working:
the diagram only needs the ONE faulting bus cycle's own pin-level
timing, but now that the exception genuinely completes within any
generous fixed tick budget, letting the run continue that far pushed
`vcd_to_wavedrom.py`'s own "last N cycles" capture window onto the
frame-push writes and eventually the handler's own trailing self-loop
refetches instead of the fault itself — fixed by explicitly stopping
right after the faulted cycle's own `/AS` negates (plus a small hold
margin), rather than running for a large fixed tick count. Manual crop
and sim waveform regenerated and re-verified correct.

Full mandatory gate clean: `make test` 37/37 (including the new BERR
regression and the re-tuned retry-exhaustion test), `cosim_grp` 8/8,
`cosim_memind` 33/33, `dat-synth` 50/50, full 124-suite Harte sweep
bit-identical to baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` —
BERR-without-HALT has no Harte coverage, the corpus captures
68000-single-step vectors with no bus-fault sequences).

**Closes `project_berr_no_halt_retry_loop.md` in full.**

## Phase 280 (CBACK beat-0-only sampling bug + 3 new representative
timing diagrams — IMPLEMENTED AND VERIFIED,
`project_cback_beat0_only_sampling_bug.md`, a later session)

User asked to complete the remaining `timing_diagrams/` categories still
flagged as "not attempted" in `INDEX.md`'s own Scope section: synchronous
RMW timing (Figure 7-36), a burst-fill variant (Figures 7-39/7-40), and
a late-BERR/retry variant (Figures 7-50 through 7-56). Scoped to 3 new
representative diagrams (one per remaining category, matching this set's
own established convention), skipping the misaligned-transfer examples
(Figures 7-5 through 7-18) already flagged as low-value/redundant.

**Figure 7-36 (Synchronous RMW Cycle Timing — CIIN Asserted)**: built
directly by combining two already-proven models — `manual_730_tb.sv`'s
own RMW-lock shape (`TAS (A0)`'s locked read-then-write, RMC held
throughout) and `manual_732_tb.sv`'s own always-ready `/STERM`-terminated
synchronous-device model — plus write support (the earlier STERM diagram
was read-only; TAS's own write phase needs somewhere to land). No RTL
gap found; straightforward composition of existing, verified pieces.

**Figure 7-54 (Asynchronous Late Retry)**: a write cycle where the
device asserts `/DSACKx` (indicating success) but also asserts `/BERR` +
`/HALT` on the same access (a "late" fault, detected after the transfer
appeared to succeed), forcing a genuine BERR+HALT retry — distinct from
Figure 7-49's own plain-BERR-to-exception path, this exercises
`biu_cycle_gen.sv`'s own `retry_r`/`in_retry_r` mechanism that no
existing diagram had shown. The retried write completes cleanly. Two
testbench-construction lessons found while tuning the capture window
(both already-established patterns from earlier phases this session,
reapplied here): the trailing instruction (`bra.s loop`) generated extra
refetch cycles that displaced the fault+retry pair from the "last N
cycles" window — switched to `stop #$2700` (matching `manual_730.s`'s
own convention); and a trailing read-back instruction added a 3rd access
to the same address for the same reason — removed, checking the write's
own landing directly against memory instead.

**Figure 7-39 (Burst Request — CBACK Negated Early), the real find**:
while building this diagram (the peripheral needs to genuinely negate
`/CBACK` partway through a burst, which `manual_738_tb.sv`'s own
always-grant model never exercised), direct inspection of
`rtl/biu_burst_ctrl.sv` found a real, previously-undocumented RTL gap:
`cback_ok_r` (whether the burst may continue to the next beat) was
sampled **only once, at beat 0**, as a sticky OR-latch
(`if (burst_beat_r==0 && at_burst_data) cback_ok_r <= cback_ok_r |
!cback_s;`) — once granted, it stayed granted for the rest of the burst
regardless of what `/CBACK` did on beats 1-3. Confirmed directly against
MC68030UM.pdf §6.1.4/6.2's own text before implementing (not assumed):
*"The premature negation of the CBACK signal during the burst operation
causes the current cycle to complete normally... However, the burst
operation aborts and CBREQ negates"* — real silicon requires per-beat
sampling. **Fixed**: widened the sample gate from `burst_beat_r==0` to
every beat (`at_burst_data` alone), and changed from OR-accumulation to
a plain resample (`cback_ok_r <= !cback_s`) — `biu_cycle_gen.sv`'s own
`ST_BURST_S6`/`ST_BWRITE_S6` continue-vs-terminate check already reads
this same signal immediately after each beat, so no other RTL change was
needed.

**A second bug found while re-verifying the EXISTING Figure 7-38 diagram
against this fix**: `manual_738_tb.sv` modeled `/CBACK` as a direct
mirror of `/CBREQ` (`cback_n = ext_cbreq_n`) — but `/CBREQ` itself is
only asserted during beat 0's own S0/S1 (confirmed via direct trace: the
pin, and therefore the mirrored `/CBACK`, negates at S2, two states
before S4's own data-sample window even begins) — so this mirror never
actually overlapped ANY beat's own sampling window, not even beat 0's.
It only ever produced a correct-looking 4-beat diagram by masking
through the OLD sticky-latch bug combined with a 2-stage-synchronizer-
delay coincidence (confirmed via direct per-tick trace of `cback_ok_r`/
`cback_s`/`state_adv` before concluding this, not guessed at). Once
`/CBACK` was correctly resampled every beat, this test's own burst
immediately degraded to a single beat. **Fixed** by holding `/CBACK`
permanently asserted for the whole burst instead (`logic cback_n =
1'b0;`), matching `tb/cache_tb.sv`'s own already-proven, already-passing
convention for a real burst-capable peripheral.

**A third, unrelated timing artifact found in the same investigation**:
`tests/timing_manual_738.s` dispatched the burst-triggering read with
only one register-only instruction between it and `MOVEC D7,CACR` — not
enough of a gap for CACR's own write to settle, so the read raced it and
the FIRST attempt dispatched as a plain non-burst miss, with the real
burst only starting on a SEPARATE, second access to the same address
(confirmed via direct trace: `is_burst=0` for the first access,
`is_burst=1` only for the second). Fixed by adding an artificial
`MULU.L` stall between the CACR write and the read, matching this
project's own established `timing_manual_725.s` convention; applied to
both `timing_manual_738.s` and the new `timing_manual_739.s`.

**Verification**: full mandatory gate (`make test` 37/37 — including
`biu`/`cache`, the two suites that actually exercise burst mode —
`cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth` 50/50), full
124-suite Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2
SKIP 281221 TIMEOUT 0` — no suite in this corpus exercises burst mode).
No dedicated module-level regression test was added for the CBACK fix
(unlike the level-7 and BERR-retry fixes earlier this session) — the
fix is directly exercised and visually verified via the new Figure 7-39
diagram itself, which shows the burst completing beats 0/1 normally
then aborting instead of continuing to beats 2/3, and via the corrected
Figure 7-38 diagram, which shows a clean, undisturbed full 4-beat burst.

`timing_diagrams/INDEX.md`'s own Scope section updated to reflect all
three new categories now covered (synchronous RMW, burst-abort, BERR
retry), narrowing the remaining "not attempted" list to Figures 7-50
through 7-53, 7-56, and 7-40 specifically (previously stated more
broadly as whole ranges). `diagrams.md`'s manifest updated with the 3
new rows plus corrected descriptions for `manual_738`/`manual_744`/
`manual_749` (previously described as "found, not chased further" or
"worked around" — now describing the real fixes).

**Closes `project_cback_beat0_only_sampling_bug.md` in full.**

## Phase 281 (cpBcc.W/.L, a later session, `wobbly-honking-cascade.md`
cross-repo item, sub-phase 1 of 5 — cpDBcc/cpScc/cpTRAPcc/Coprocessor-
Protocol-Violation-test-coverage still to come)

Closes the FIRST of the four coprocessor conditional instructions this
project's own `CLAUDE.md` had long documented as a deliberate,
out-of-scope gap (Phase 248 item #7) — unblocked by MH882's own Phase
10 (real 32-predicate Condition CIR logic, `/Users/malcolm/MH882`),
exactly as that item's own scope note anticipated.

**Encoding** (MC68030UM.pdf Figures 10-9/10-10, confirmed directly):
F-line, CpID=001 in bits[11:9], TYPE={f_dir,f_ss}=010 (cpBcc.W) or 011
(cpBcc.L) in bits[8:6], condition selector in bits[5:0]. This project's
coprocessor scope needs no coprocessor-defined extension words for
condition evaluation (MH882's own Condition CIR takes the selector
directly), so exactly 1 (W) or 2 (L) extension words follow — the
16-bit or 32-bit branch displacement, identical shape/formula to plain
Bcc.W/Bcc.L (`branch_target = decode_pc + 2 + displacement`).

**Protocol** (Figure 10-8/10.2.2.1.2): write the condition selector to
the Condition CIR ($0E), poll the Response CIR ($00) until a
recognized Null primitive (CA=0) arrives, branch iff its TF bit (bit
0) is set. New `cpcc_*` dispatch FSM (`rtl/eu_seq_execute.svh`) mirrors
the existing cpSAVE/cpRESTORE `cpsr_*` FSM's own shape exactly (same
`ex_mem_stall` membership, same "decide live off the exact ack cycle"
convention for the branch decision) — deliberately named generically
since cpDBcc/cpScc/cpTRAPcc (this same plan item's remaining
sub-phases) reuse this identical FSM, differing only in what happens
once TF is known.

**Response-word bit layout resolved by reading the actual producer,
not re-deriving from the manual's own OCR'd prose** — a deliberate
verification-discipline choice, not a shortcut: MC68030UM.pdf's
general response-primitive-format prose ("Bit[4], the PC bit") directly
contradicts its own Null Primitive figure's column layout (PC one bit
below CA), a single-digit OCR loss ("Bit[14]" read as "Bit[4]") that's
plausible given this project's own prior experience with this exact
PDF's OCR artifacts. Rather than trust either garbled source, read
MH882's own already-tested `rtl/m68882_cir_pkg.sv` `response_word()`
directly (`{CA,PC,DR,13-bit payload}`, PRIM_NULL=13'h0 so only bit0 of
the payload carries TF) — the actual bits the real companion
coprocessor this project will interoperate with puts on the bus,
authoritative regardless of which manual reading is correct. Only the
Null primitive is recognized and the PC bit isn't serviced (MH882's own
Condition CIR path never sets it) — anything else routes to a new
Coprocessor Protocol Violation request (vector 13, `eu_cpviol_req`,
wired end-to-end: `eu_seq.sv` → `m68030_eu.sv` → `m68030_top.sv` →
`m68030_exc.sv`'s new `VEC_CPVIOL`/`FMT_SHORT` priority-chain arm,
mirroring `eu_fmt_err_req`'s existing wiring shape exactly, including
the Control-CIR abort-mask write per 10.3.2 and the same
`eu_ex_decode_pc`-vs-`ifu_decode_pc` `fault_pc` mux fix format error
already needed) — not yet directly tested (no test currently drives an
unrecognized primitive), noted as a real gap for the Protocol-Violation
sub-phase of this plan item to close with dedicated coverage.

**Testing**: `tb/ctrl_flow_tb.sv` gained a new `run_cpbcc()` helper task
and 3 checks (taken/not-taken/cpBcc.L-taken) driving a testbench-side
CIR stub — the same established precedent `tb/eu_seq_tb.sv` already
set for cpSAVE/cpRESTORE (no live MH882 coprocessor instance in THIS
test; a genuine cross-repo cosim is this plan item's own longer-term
aspiration, not required for each sub-phase). **A real testbench race
was found and fixed while writing this test**: asserting `eu_coproc_ack`
via a blocking assignment in immediate reaction to a polling loop's own
`break` (same simulation edge that revealed `eu_coproc_req`) raced the
DUT's own `always_ff` sampling of `eu_coproc_ack` on that identical
edge — confirmed via a direct `$display` trace showing the FSM's
`cpcc_resp_r` state and `eu_coproc_ack=1` appearing together on
`cpcc_resp_r`'s own very first cycle, causing a stray extra ack the FSM
incorrectly consumed one instruction late (each test's own branch
result appeared to leak into the NEXT test). Fixed by adopting
`tb/special_instr_tb.sv`'s own already-proven `ack_coproc` idiom (a
FRESH `@(posedge clk)` before asserting ack, not an immediate reaction
to the same edge that revealed the request) — a genuine, reusable
testbench-construction lesson, not merely a style preference.

**A second, genuine pre-existing-test collision found and fixed**:
`tb/special_instr_tb.sv`'s own FPU-04 test used opcode `0xF2A0`
(F-line, CpID=1, TYPE=010) purely as a made-up "ppp=010" label to
exercise the generic-FPU-stub's own documented address-encoding bug
(Phase 55) — TYPE=010 is now genuinely, correctly decoded as cpBcc.W
instead, correctly no longer reaching that stub at all. Retargeted to
TYPE=110 (still unclaimed by any real instruction) to keep exercising
the same stub path; not a regression, an expected and correct
consequence of real cpBcc.W now owning that opcode-space slot per
Figure 10-9. (TYPE=001, used by FPU-03, will need the identical
retargeting once cpScc/cpDBcc/cpTRAPcc's own sub-phase lands.)

**Files**: `rtl/eu_seq_decode.svh` (`dec_is_cpbcc`/`dec_cpcc_sel`, 2 new
decode arms), `rtl/m68030_seq.sv` (`is_cpbcc_w`/`is_cpbcc_l`, 2 new
`ext_count` entries), `rtl/eu_seq_execute.svh` (EX-stage capture,
`cpcc_*` FSM, `cpcc_protoviol_raw`/`_w` one-shot debounce mirroring
`cpsr_fmt_err_raw`/`_w`, `branch_taken`/`branch_target`/`eu_coproc_*`
wiring, `eu_cpviol_req` assign), `rtl/eu_seq.sv`/`rtl/m68030_eu.sv`/
`rtl/m68030_top.sv`/`rtl/m68030_exc.sv` (the new vector-13 port chain),
`tb/ctrl_flow_tb.sv` (new tests), `tb/special_instr_tb.sv` (FPU-04
retarget), `tb/exc_tb.sv` (new `cpviol_req` wildcard-port signal).

**`make test`: 37/37 suites clean, zero regressions. `make cosim_grp`:
8/8 clean.** Full 124-suite Harte sweep re-run and confirmed clean
(cpBcc is a 68020+-only instruction family with zero Harte coverage,
matching every other coprocessor/memory-indirect family in this
project — this run is a pure regression check, not new coverage).

**Remaining sub-phases of this same plan item** (in the order stated by
`wobbly-honking-cascade.md`'s own Phase 15 section, sequenced this way
since cpDBcc/cpScc/cpTRAPcc share the identical TYPE=001 opcode slot
and the identical `cpcc_*` FSM this sub-phase already built): cpDBcc
(Dn counter + branch, no EA — next lowest risk), cpScc (Dn-direct and
simple-EA-only first, matching this project's own repeated "non-indexed
EA first" precedent), cpTRAPcc (reuses the existing `dec_is_trapv`/
`eu_trapv_req` path directly, trivial once TF is known), then dedicated
Coprocessor Protocol Violation test coverage (currently wired but
unverified — see above).

## Phase 281 sub-phase 2 (cpDBcc, a later session, `wobbly-honking-cascade.md`
cross-repo item)

Closes the second of the four coprocessor conditional instructions.

**Encoding** (MC68030UM.pdf Figure 10-12, confirmed directly): F-line,
CpID=001, TYPE={f_dir,f_ss}=001, mode=001 (bits[8:3]=001001) --
disambiguates from cpScc the same way plain DBcc's own mode=001
carve-out disambiguates it from Scc within the shared Group-0101 opcode
line. Dn counter in bits[2:0]. Unlike cpBcc, the condition selector is
NOT in the F-line op word -- it's the FIRST of 2 fixed extension words
(selector in bits[5:0], the SECOND word being the 16-bit displacement),
assembled into `ext_data` via this project's established "first extra
word → high 16 bits" convention (matching Bcc.L's own 2-word assembly):
`dec_cpcc_sel = ext_data[21:16]`, `dec_branch_disp =
sext(ext_data[15:0])`.

**Reused the cpBcc `cpcc_*` FSM UNCHANGED** — only its own start-trigger
condition needed broadening (`dec_is_cpbcc || dec_is_cpdbcc`); the
Condition-CIR-write/Response-CIR-poll/abort bus wiring was already fully
generic. This is exactly what that FSM's own header comment anticipated
when cpBcc landed.

**Completion protocol** (10.2.2.3.2): TF=1 → no operation (fall
through, no decrement, no branch) — the same "coprocessor says true, do
nothing" shape cpBcc's own false case has, just mirrored. TF=0 →
decrement the low word of Dn; if the result is `$FFFF`, fall through
(loop terminates); otherwise branch, with `scanPC` pointing to the word
*following* the condition specifier (10.4.1) — `decode_pc+4`, one word
later than cpBcc's own `+2`, since cpDBcc has that extra selector word
before the displacement.

**A genuine new register-write-timing problem, absent from cpBcc**:
Dn's decrement can't go through the normal single-cycle ALU→WB pipeline
plain DBcc uses (`ex_writes_reg`/`wb_valid`), because that pipeline
commits on the cycle immediately following EX-entry — but cpDBcc must
wait for the multi-cycle CIR round-trip to even know whether to
decrement, and `ex_valid` stays asserted across that ENTIRE wait
(`ex_mem_stall` holds it there), so a normal WB dispatch would fire far
too early (or every stall cycle, if not gated some other way). Solved
via the same "dedicated FSM completion write port" pattern this
project already uses for MOVEM/bitfield/memory-indirect writebacks
(`wr_en`'s own mux in `eu_seq_execute.svh`, alongside `movem_wr_en`/
`bf_dn_wr_en`/etc.) — a new `cpdbcc_wr_en` term fires exactly once, the
same cycle `cpcc_resp_done` does, gated on `!TF`. Dn's CURRENT value is
read live via `rd_b_data` (not a separately captured register) at that
exact moment — safe because `rd_b_sel` already resolves to `ex_dst_reg`
(captured generically at decode, `dec_dst_reg={1'b0,f_reg}`) throughout
the whole multi-cycle FSM, and nothing else can decode (hence nothing
else can change Dn) while `stall` holds — the same "read the
still-stable EX-stage register live" convention CMP2/MOVEP's own
multi-cycle FSMs already established.

**Testing**: `tb/ctrl_flow_tb.sv` gained a `run_cpdbcc()` wrapper
(delegates straight to `run_cpbcc()` with the 2 extension words
pre-assembled) and 3 checks: TF=1 (Dn unchanged, no branch), TF=0 with
Dn=5→4 (decrement + branch, target verified), TF=0 with Dn=0→`$FFFF`
(decrement but no branch, confirming the loop-termination case AND
that the upper 16 bits of Dn are preserved by the word-sized write).
All 3 passed on the first run with no debugging needed, unlike cpBcc's
own testbench-race detour — attributed directly to reusing the
already-hardened `run_cpbcc()`/`ack_coproc` idiom rather than writing
a new CIR-driving task from scratch.

**Files**: `rtl/eu_seq_decode.svh` (`dec_is_cpdbcc`, 1 new decode arm,
added to the trace flow-change list), `rtl/m68030_seq.sv` (`is_cpdbcc`,
1 new fixed-`ext_count=2` entry), `rtl/eu_seq_execute.svh` (`ex_is_cpdbcc`
capture, `cpdbcc_dn_new`/`cpdbcc_not_taken`/`cpdbcc_wr_en`/
`cpdbcc_branch_taken` wires, the new `wr_en`/`wr_sel`/`wr_siz`/`wr_data`
mux arm, `branch_taken`/`branch_target` extension), `tb/ctrl_flow_tb.sv`
(new tests).

**`make test`: 37/37 clean, zero regressions. `make cosim_grp`: 8/8
clean.** Full 124-suite Harte sweep (Verilator backend) re-run and
confirmed bit-identical to the pre-existing baseline (`PASS 702142 FAIL
2 SKIP 281221 TIMEOUT 0`) — cpDBcc is 68020+-only, zero Harte coverage,
same as cpBcc.

**Remaining sub-phases**: cpScc (Dn-direct + simple-EA-only), cpTRAPcc,
dedicated Coprocessor Protocol Violation test coverage — same order as
stated in sub-phase 1's own writeup above.

## Phase 281 sub-phase 3 (cpScc, Dn-direct only, a later session,
`wobbly-honking-cascade.md` cross-repo item)

Closes the third of the four coprocessor conditional instructions —
**scope deliberately narrowed to Dn-direct only** this sub-phase
(memory-EA cpScc explicitly deferred, matching this project's own
repeated "register EA before memory EA" incremental precedent, e.g.
cpSAVE/cpRESTORE's own (An)-only start).

**Encoding** (MC68030UM.pdf Figure 10-11, confirmed directly): F-line,
CpID=001, TYPE={f_dir,f_ss}=001 (the SAME TYPE cpDBcc uses — cpScc,
cpDBcc, and cpTRAPcc all share this one TYPE value, disambiguated by
the low 6 bits, exactly mirroring how plain Scc/DBcc/TRAPcc share
Group-0101 in the real, non-coprocessor ISA). `f_mode==000` (Dn direct)
selects THIS sub-phase's own arm; `f_mode==001` was already claimed by
cpDBcc (checked first in decode priority) and `f_mode==111` with
`f_reg∈{010,011,100}` is reserved for cpTRAPcc (not yet implemented,
so those encodings still fall through to the generic FPU stub — an
already-existing gap, not worsened here). The condition selector is
the ONE extension word's own bits[5:0] — unlike cpDBcc, there's no
second (displacement) word, so it occupies `ext_data`'s LOW 16 bits
directly (`ext_data[5:0]`), not the high 16 bits cpDBcc's own 2-word
convention uses.

**Reused the cpBcc/cpDBcc `cpcc_*` FSM UNCHANGED again** — only the
start-trigger condition needed one more broadening
(`dec_is_cpbcc || dec_is_cpdbcc || dec_is_cpscc`).

**Completion** (10.2.2.2.2): TF=1 → write `$FF` to the destination;
TF=0 → write `$00`. Dn-direct write reuses the exact same "dedicated
FSM completion write port" pattern cpDBcc's own decrement introduced
(`cpscc_wr_en`, a new `wr_en` mux arm) — byte-sized (`wr_siz=2'b01`),
so the regfile's own existing byte-write merge logic (`{d_reg[31:8],
wr_data[7:0]}`) naturally preserves Dn's upper 3 bytes, matching real
Scc's own documented behavior. cpScc never branches (Scc doesn't
change program flow, same as plain Scc) — no `branch_taken`/
`branch_target` involvement at all, the simplest completion of the
three implemented so far.

**Testing**: `tb/ctrl_flow_tb.sv` gained `run_cpscc()` (delegates to
`run_cpbcc()`, single extension word in the low 16 bits) and 2 checks
(TF=1→`$FF`, TF=0→`$00`, both confirming the upper 3 bytes of Dn are
preserved and neither branches). Both passed on the first run.

**Files**: `rtl/eu_seq_decode.svh` (`dec_is_cpscc`, 1 new decode arm),
`rtl/m68030_seq.sv` (`is_cpscc_dn`, 1 new fixed-`ext_count=1` entry),
`rtl/eu_seq_execute.svh` (`ex_is_cpscc` capture, `cpscc_wr_en`/
`cpscc_byte` wires, the new `wr_en`/`wr_sel`/`wr_siz`/`wr_data` mux
arm), `tb/ctrl_flow_tb.sv` (new tests).

**`make test`: 37/37 clean, zero regressions. `make cosim_grp`: 8/8
clean.** Full 124-suite Harte sweep (Verilator backend) re-run and
confirmed bit-identical to the pre-existing baseline.

**Remaining sub-phases**: memory-EA cpScc (deferred, not currently
planned as its own dedicated near-term sub-phase — revisit if/when
asked), cpTRAPcc, dedicated Coprocessor Protocol Violation test
coverage.

## Phase 281 sub-phase 4 (cpTRAPcc, a later session, `wobbly-honking-cascade.md`
cross-repo item)

Closes the fourth and last of the four coprocessor conditional
instructions.

**Encoding** (MC68030UM.pdf Figure 10-13/Table 10-1, confirmed
directly): F-line, CpID=001, TYPE=001 (the same TYPE cpScc/cpDBcc use),
mode=111, opmode (`f_reg`, bits[2:0]) = 010 (1 operand word) / 011 (2
operand words) / 100 (0 operand words). The condition selector is the
FIRST extension word's own bits[5:0] (`ext_data[5:0]`, mirroring
cpScc's single-relevant-word convention) — any TRAPcc-handler-only
operand words the opmode specifies are opaque to the EU (`ext_count`,
`m68030_seq.sv`, now computes 1/2/3 total ext words per-opmode) and are
never represented in `ext_data` at all, matching the manual's own text
("not explicitly used by the MC68030").

**Reused the cpBcc/cpDBcc/cpScc `cpcc_*` FSM unchanged a third time**
— only the start-trigger condition needed one more broadening.

**Completion** (10.2.2.4.2): TF=1 → initiate exception processing;
TF=0 → next instruction. Per Table 8-1, cpTRAPcc shares vector 7
(Format $2/`FMT_INST`) with plain TRAPcc/TRAPV — rather than building
any new exception-request plumbing, TF=1 asserts the EXISTING
`eu_trapv_req` output directly (`cptrapcc_taken_w` OR'd into its
assign). **A new one-shot debounce was needed that plain TRAPV never
required**: `eu_trapv_req` for plain TRAPcc/TRAPV is `ex_valid &&
ex_is_trapv` with no debounce at all, safe because that instruction
resolves and retires within 1-2 cycles; cpTRAPcc's own `ex_valid` stays
asserted across the ENTIRE multi-cycle CIR wait, so an undebounced
version would either fire before TF is known or re-fire every stall
cycle once it is — solved with the identical one-shot
raw/`_fired_r`/debounced-`_w` shape `chk_trap`/`cpsr_fmt_err_w`/
`cpcc_protoviol_w` already established.

**A genuine Icarus declaration-order problem, not previously hit by
this plan item**: `ex_will_except` (a combinational `assign` used at
line ~1731, near the very top of `eu_seq_execute.svh`) needed to
include the new debounced pulse, but the natural place to compute it
(alongside `cpcc_branch_taken`/`cpdbcc_*`/`cpscc_*`, ~3500 lines later,
depending on the `cpcc_resp_done` wire declared there) is textually
*after* its own first use — Icarus enforces "declared before used" even
for a plain module-level `wire`/continuous-assign (not just the
procedural-block case this project has hit before). Fixed by moving
`ex_is_cptrapcc`'s own declaration and the ENTIRE `cptrapcc_taken_raw`/
`_fired_r`/`_w` computation up to right after `cpcc_protoviol_raw`
(~line 758, already the established "declared early for `ex_mem_stall`"
zone this file uses for exactly this class of problem), expanding its
own condition inline from `cpcc_resp_r`/`eu_coproc_ack`/
`eu_coproc_rdata` directly (all of which — usefully — are ALSO already
available that early) instead of depending on the later `cpcc_resp_done`
convenience wire.

**A deliberate, documented correctness gap**: `dec_is_cptrapcc` is
NOT included in `dec_is_flow_chg`'s own decode-time OR-list (unlike
plain `dec_is_trapv`, which IS included unconditionally — safe there
only because `dec_is_trapv` itself is already gated on `eval_cc` having
already resolved true at decode time). cpTRAPcc's own outcome isn't
known until long after decode, so correctly recognizing it as a T0
"change of flow" instruction only when TF=1 would need deferring the
trace decision the same way everything else about this instruction is
deferred — a real additional mechanism, not attempted here. Net effect:
T0 tracing will NOT fire for a taken cpTRAPcc (a narrow, likely
rarely-exercised edge case — T0 tracing interacting with the
transcendentally-rare combination of "tracing enabled" + "cpTRAPcc
executed" + "condition true"). Documented here rather than silently
left broken; revisit if ever actually needed.

**Testing**: `tb/ctrl_flow_tb.sv` gained a `CPTRAPCC` (opmode=100, 0
operand words) constant, `run_cptrapcc()` (delegates to `run_cpbcc()`),
a new `saw_trapv` latch (mirrors `saw_branch`'s own shape, watching
`eu_trapv_req`), and 2 checks (TF=1 fires, TF=0 doesn't). Both passed
on the first run.

**Files**: `rtl/eu_seq_decode.svh` (`dec_is_cptrapcc`, 1 new decode
arm), `rtl/m68030_seq.sv` (`is_cptrapcc`, 3 new per-opmode `ext_count`
entries), `rtl/eu_seq_execute.svh` (`ex_is_cptrapcc`/`cptrapcc_taken_*`
moved to the early declaration zone, `eu_trapv_req`/`ex_will_except`
extended), `tb/ctrl_flow_tb.sv` (new tests).

**`make test`: 37/37 clean, zero regressions. `make cosim_grp`: 8/8
clean.** Full 124-suite Harte sweep (Verilator backend) re-run and
confirmed bit-identical to the pre-existing baseline.

**This closes real decode/implementation work for all four coprocessor
conditional instructions** (cpBcc.W/.L, cpDBcc, cpScc Dn-direct,
cpTRAPcc). **Remaining, deliberately scoped-out items for this plan
item**: memory-EA cpScc (deferred indefinitely); dedicated Coprocessor
Protocol Violation test coverage (the mechanism is wired and has been
since sub-phase 1, but no test has yet driven an unrecognized response
primitive through it); the T0-tracing gap noted above; and, per the
plan's own original scoping, a genuine cross-repo cosim using a live
MH882 instance as the coprocessor (every sub-phase so far used the
same testbench-side CIR stub this project's own cpSAVE/cpRESTORE
precedent already established, not a live coprocessor).

## Phase 281 sub-phase 5 (Coprocessor Protocol Violation test coverage,
a later session, `wobbly-honking-cascade.md` cross-repo item — closes
this plan item's own last remaining un-deferred sub-phase)

Closes the one item explicitly flagged as "wired but unverified" in
every prior sub-phase's own writeup: Coprocessor Protocol Violation
(vector 13) had real RTL (`eu_cpviol_req`, `cpcc_abort_r`) since
sub-phase 1, but no test had ever driven an unrecognized Response CIR
primitive through the `cpcc_*` FSM to confirm it actually works.

**Test design**: a new `tb/ctrl_flow_tb.sv` task, `run_cpbcc_protoviol()`,
drives cpBcc's own Condition-CIR-write step normally, then replies to
the Response CIR read with a MALFORMED primitive — either the PC bit
set (`eu_coproc_rdata[30]=1`, a request this implementation doesn't
service) or a non-zero function code in `payload[12:1]`
(`eu_coproc_rdata[28:17]!=0`, anything but the Null primitive) — and
confirms three things: (1) the FSM issues the documented (10.3.2)
Control-CIR abort-mask write (address, direction, and the `$0001` data
value all checked explicitly, not just "a write happened"), (2)
`eu_cpviol_req` fires exactly once (via a new `saw_cpviol` latch,
mirroring `saw_trapv`'s own shape), and (3) no side effect from the
aborted instruction occurs (`saw_branch`/`saw_trapv` both stay 0 — the
same 3-way check applies regardless of which of the 4 coprocessor-
conditional families is used as the vehicle, since the response-decode
path is completely shared; cpBcc was picked as the simplest).

**A small testbench-wiring gap found while writing this**:
`eu_cpviol_req` (added to `m68030_eu`'s own port list back in
sub-phase 1) was never actually connected in `tb/ctrl_flow_tb.sv`'s
own explicit (non-wildcard) `m68030_eu` instantiation — left silently
floating, unconnected, the whole time (a real but harmless gap, since
nothing in sub-phases 1-4 needed to observe it directly). Fixed by
adding the missing port connection alongside `eu_trapv_req`'s own.

**Testing**: 2 new test cases (PC-bit-set, bad-function-code), 8 checks
total (3 abort-write-mechanics checks + 3 outcome checks per case, plus
2 more) — all passed on the first run, no debugging needed.

**Files**: `tb/ctrl_flow_tb.sv` (`eu_cpviol_req` port wiring,
`saw_cpviol` latch, `run_cpbcc_protoviol()`, 2 new test cases).

**`make test`: 37/37 clean, zero regressions. `make cosim_grp`: 8/8
clean.** Full 124-suite Harte sweep (Verilator backend) re-run and
confirmed bit-identical to the pre-existing baseline.

**This closes `wobbly-honking-cascade.md`'s own coprocessor-conditional-
instructions plan item in full**, except for the two items explicitly
left as deliberate, documented, indefinitely-deferred scope boundaries
(not bugs, not silently dropped): memory-EA cpScc, and a genuine
cross-repo cosim using a live MH882 instance rather than a testbench-
side CIR stub. No outstanding plan of any kind remains in this project.

## To Do

No outstanding plan of any kind remains for RTL correctness as of Phase
280 — every known real gap found across this project's history has been
fixed and verified (see `CLAUDE.md`'s own "Current state" for the
standing summary). The items below are optional, deliberately-deferred
`timing_diagrams/` coverage and one unconfirmed lead, not known bugs —
listed here so a future session doesn't have to reconstruct them from
scratch. None are blocking; pick any of these up only if/when asked.

**Further `timing_diagrams/` coverage** (`INDEX.md`'s own Scope section
has the live version of this list — keep both in sync if either
changes):
- Figures 7-50 through 7-53 — the remaining late-BERR/retry variants
  beyond Figure 7-49 (plain exception) and Figure 7-54 (async retry
  that succeeds): late BERR arriving after DSACKx has already been
  seen (7-50/7-51), and late BERR landing on the 2nd/3rd access of a
  dynamically-sized multi-beat transfer (7-52/7-53).
- Figure 7-56 — late retry specifically during a burst fill (combines
  the Figure 7-54 retry mechanism with Figure 7-38/7-39's own burst
  machinery); likely the most involved of the remaining diagrams to
  construct correctly.
- Figure 7-40 — "burst fill deferred": starting a new cache-block burst
  request while a previous one is still being serviced. Not yet
  investigated against this RTL's own arbitration/dispatch behavior at
  all — unlike Figure 7-39, no prior scoping work has been done here to
  know whether it's a clean fit or exposes another gap the way 7-39 did.
- Figures 7-5 through 7-18 — the misaligned-transfer example diagrams.
  Already assessed (Phase 280's own scoping pass, `INDEX.md`) as mostly
  restating the dynamic-sizing behavior Figures 7-22/7-23/7-28 already
  demonstrate — lowest priority of this list, likely not worth building
  unless specifically requested.

**One unconfirmed lead from the Phase 280 CBACK investigation**
(`project_cback_beat0_only_sampling_bug.md`): MC68030UM.pdf's own
§6.1.4/6.2 text, in the same paragraph group as the CBACK-negation rule
that fix addressed, also states that CIIN asserting during the 2nd/3rd/
4th cycle of a burst "prevents the data during that cycle from being
loaded into the appropriate cache and causes CBREQ to negate, aborting
the burst operation" — i.e. CIIN may carry the identical "checked once
vs. every beat" requirement CBACK did. `rtl/biu_burst_ctrl.sv`'s own
per-beat CIIN capture (Phase 229, `burst_ciin0..3`) was built for
`biu_cache_if.sv`'s own per-word caching decision, not for aborting the
burst itself — whether it ALSO needs to feed the same
continue-vs-terminate decision `cback_ok` drives has not been checked.
Investigate by re-reading `rtl/biu_burst_ctrl.sv`'s own beat-advance
logic (`ST_BURST_S6`/`ST_BWRITE_S6` in `rtl/biu_cycle_gen.sv`) the same
way the CBACK gap was found, before assuming either way.

**FIXED AND VERIFIED bug found via mackerel-030f integration testing (a
later session), root cause CONFIRMED via direct `q_cnt`/`drain` signal
tracing, then fixed and verified in a follow-on session**
(`project_skiptx_branch_target_regwrite_bug.md`, third revision — the
file's own original branch-redirect theory and its first revision
("`instr_word` advances past the opcode during a `need_ext` wait") were
both superseded by the confirmed mechanism below): a taken branch's
redirect correctly flushes the IFU's own queue (`q[]<=0`/`q_cnt<=0` on
`pc_wr_en`) but does **not** discard the *result* of a bus read that was
already dispatched, before the flush, for the abandoned fall-through
path — that read completes normally and gets pushed into the
freshly-flushed queue anyway, indistinguishable from a genuine fetch of
the real redirect target, gets mis-decoded as a fresh opcode, and that
spurious decode's own (wrong, coincidental) `drain` value eats 2 real
queue words, silently consuming the real opcode and/or its real
extension word — producing the wrong-register-write symptom this file
originally reported. Confirmed directly via `q_cnt`/`seq_drain` tracing
in the original repro.

Six attempts to reproduce this in an isolated `tb/stall_fsm_tb.sv` test
(reached via a JMP into a mid-file entry point, that file's own
convention) all failed. A seventh attempt — a brand-new standalone
testbench (`tb/minrepro_tb.sv`, now committed) reached via a genuine
`m68030_top` reset boot instead of a JMP, with the memory model changed
to a registered read (one `clk_4x` cycle delayed) alongside immediate
DSACK (matching `mackerel_030f.v`'s own real ROM timing exactly) —
**succeeded**. Neither ingredient alone was sufficient; both together
are. Two genuine, separate testbench setup bugs were found and fixed
along the way (a too-short reset hold left an internal counter at X
forever in Icarus, silently preventing the CPU from ever booting; a missing
SSP initialization at address 0 caused a different, much louder failure
that's easy to confuse for the real bug) — both documented in the test file's
own comments as a caution for anyone touching it further.

**Fix (a later session)**: tracing the real address path while
implementing the originally-proposed "epoch tag" idea found a deeper,
more fundamental defect than mere ack-misattribution — `biu_arbiter.sv`
holds `grant_ifu` for a whole bus cycle, and `biu_icache_if.sv`'s
disabled-cache bypass path (`cg_addr = ifu_addr`, live/unlatched, unlike
its own already-fixed *enabled*-cache path's `cg_single_addr_r`/
`ic_burst_addr_r` latches, Phase 128) feeds straight into
`biu_cycle_gen.sv`'s own live `cyc_addr`/`ext_a` — meaning the old
`m68030_ifu.sv` code, by updating `fetch_addr_r` (=`ifu_addr`)
immediately on every redirect, could silently mutate the address on the
*real external bus pins* mid-cycle, after AS/DS were already asserted
for the old address. Fixed entirely within `m68030_ifu.sv`: a new
`fetch_abort_pend_r`/`pending_pc_r` pair means a redirect landing while a
fetch is genuinely still outstanding now leaves `fetch_addr_r`/
`fetch_pend_r`/`skip_first_r` completely untouched (the queue itself
still flushes immediately) — letting that bus cycle run to its natural
completion with a stable address, then discarding its eventual
`ifu_ack`/`ifu_berr` unconditionally before switching over to the real
target. No epoch counter or new BIU port needed. Found and fixed one
piece of fallout while verifying: `tb/ifu_tb.sv`'s IFU-12a/12a2 had a
fixed cycle-count timing budget that no longer reliably covers the now-
variable (but bounded) extra delay a redirect can incur landing mid an
unrelated ambient fetch — fixed with a `wait_bus_err_r()` polling task
mirroring the file's own existing `wait_valid()` convention, not a hack.
`tb/minrepro_tb.sv` flips to PASS unchanged and is now in `ALL_TESTS`
(`make test`: 38/38). Full 124-suite Tom Harte sweep confirmed
bit-identical to baseline (`PASS 702142 FAIL 2` documented ASL.b
anomaly, `SKIP 281221 TIMEOUT 0`) — confirming the corpus's own harness
never exercised this exact race, so this closes a real gap Harte itself
is structurally blind to. See the project file's own "Fix (implemented)"
section for the full derivation. **Closes
`project_skiptx_branch_target_regwrite_bug.md` in full.**

**BIU narrow-port read justification bug (same later session,
`project_biu_narrow_port_read_justification_bug.md`, FIXED AND
VERIFIED)**: found via the same mackerel-030f SoC integration — after the
branch-redirect fix above let the CPU run correctly for the first time,
a real UART LSR/THRE poll (`MOVE.B (5,A1),D2` from an 8-bit dynamically-
sized external port) never worked, always reading THRE as clear. Traced
the real value (`0x60`, correct) all the way from the UART core's own
`lsr` register through `biu_sizing_fsm`/`biu_cache_if` to `m68030_eu`'s
`mem_rdata` input -- landing at `mem_rdata[31:24]` instead of the
right-justified `mem_rdata[7:0]` every other consumer in
`eu_seq_execute.svh` expects. Root cause: `biu_sizing_fsm.sv`'s
`merge_rdata()` already normalizes byte/word reads to right-justified
for a 32-bit port, but the 8-bit/16-bit-port branches positioned each
byte at its natural big-endian *longword* lane regardless of the
*original* request size -- correct by construction for a longword
transfer (all four lanes fill either way, matching every existing
`tb/biu_tb.sv` test, which only ever exercised longword transfers
through narrow ports), silently wrong for byte/word. Fixed by computing
the shift from `orig_bytes`/`done` directly instead of a fixed lookup --
reduces to the exact same shifts as before for `orig_bytes==4`, newly
right-justifies `orig_bytes==1/2`. Deliberately left unfixed: a BYTE
request via a 16-bit port (needs an `addr_lo`-based half-selection this
module has never had; no real peripheral in this project exercises it).
New `tb/biu_tb.sv` coverage (byte-via-8-bit, word-via-8-bit,
word-via-16-bit) confirmed to fail cleanly pre-fix, pass post-fix.
**Found and fixed a related test-tooling gap while running the full
mandatory gate**: 4 of 33 `cosim_memind` targets (memind10/30/31/34/36)
regressed from the branch-redirect fix above, each hand-confirmed
against its own `.s` source to be the exact same expected consequence
(a taken `Bcc` or unconditional `JSR`/`JMP` now correctly lets an
in-flight ambient fetch complete as its own real, separate bus cycle
before the redirect, which Musashi's own purely-functional emulator
never models) -- `tools/buscmp.py` gained a new `--allow-dut-extra-fetch`
flag (mirroring the existing `--allow-adjacent-swap` precedent) applied
to just those 4 targets. Full mandatory gate clean (`make test` 38/38),
`cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth` 50/50, Harte
bit-identical to baseline. **Closes
`project_biu_narrow_port_read_justification_bug.md` in full.**

**Phase 284 (two real-hardware combinational feedback loops,
`project_biu_dcache_hit_combinational_loop.md` +
`project_eu_stall_redirect_combinational_loop.md`, FIXED AND VERIFIED --
see CLAUDE.md's own condensed writeup for the full derivation)**: the
first-ever real ECP5-85K FPGA synthesis run against this design found
`$glbnet$clk_4x` achieves only ~1.66 MHz real max frequency against a
100 MHz target. Found and fixed two genuine, previously-invisible
combinational loops: `biu_cache_if.sv`'s `CI_IDLE` D-cache-hit
fast-path (Phase 247 item #10), and `eu_seq_execute.svh`/
`eu_seq_preview.svh`'s `ex_redirect_pending`-via-`stall_base` loop
(narrowed via a new `ex_redirect_pending_older`, protecting Bug 2's
own original fix, `plan.md.old2:4497-4570`, throughout). Both verified
independently and together: full mandatory gate clean, Harte
bit-identical to baseline, all four originally-flagged Verilator
`UNOPTFLAT` warnings gone. **Re-synthesis with both fixes in place still
only reached 1.78 MHz** -- neither loop was ever the dominant
contributor. Reading `nextpnr`'s own critical-path report directly
found the real bottleneck: a single 562.30 ns, ~3600-hop **acyclic**
combinational chain spanning nearly the entire design (BIU state --
cache -- dynamic-bit/CAS2 -- register file -- address ALU carry chain
-- write-data steering -- external bus -- peripheral), no register
boundary anywhere in it. This is not a loop bug; it's a direct
consequence of this project's own S-state-FSM / zero-delay-simulation
design premise never having been checked against real propagation
delay before. Closing it for real needs genuine pipelining -- tracked
as a new effort below, Phase 285.

## Phase 285: real-hardware timing closure via pipelining (SCOPING, informed by real measurement)

**Goal**: run this design at a real 25 MHz external bus frequency
(`$glbnet$clk_4x` = 100 MHz, this design's own 4x-oversampling
convention), the same ballpark as real 68030 silicon (16-50 MHz),
**without changing any externally-visible S-state cycle count** --
this project's own "no cheating cycles" rule (CLAUDE.md) applies just as
much to a pipelining fix as to any other change.

### Investigation performed this session (2026-09-22)

**Step 1 -- get the real critical-path population, not just the worst
path.** `nextpnr --report ... --detailed-timing-report` produces a JSON
timing report with `detailed_net_timings`: real per-register worst-case
arrival-time data for every register endpoint in the design (13,463 of
them for this build), not just the single worst path a plain synthesis
log shows. This is the tool to reach for whenever a fuller picture of
the timing population (not just the #1 offender) is needed -- described
in `nextpnr-ecp5 --help` but never used by this project before this
session.

**Finding 1 (superseded by Finding 3 below, kept for the record)**: the
initial read of this data showed only 145 endpoints exceeding 400 ns,
all of the identical shape (peripheral write-data registers -- SPI/
UART/SDRAM/LED), suggesting one shared upstream write-data chain was
the dominant bottleneck. Traced it to `biu_cycle_gen.sv`'s own
`ext_d_out = ... blc_wdata` being driven live/combinationally all the
way from `eu_seq_execute.svh`'s `mem_wdata` (an EU-side ALU/regfile
result), through `biu_sizing_fsm.sv`'s and `biu_cache_if.sv`'s own
matching "dispatch-cycle live-passthrough" fast-path arms (the same
"skip the register on the very first dispatch tick" pattern Phase 284
already found and fixed once, for a different signal), with zero
register anywhere in the chain.

**Fix attempted**: `biu_cycle_gen.sv` gained a new `wdata_hold_r`
register, capturing `blc_wdata` during `sphase==SP_S2` (the real write
cycle's own AS-only state) and used for `ext_d_out` from `SP_S3` onward
instead of the live wire -- exploiting the real, confirmed 1-tick gap
every reachable write-shaped cycle type (WRITE, RMW-write, CAS2 W1/W2)
has between S2 and S3/S4 in this file's own state-transition table.
Burst-write (`ST_BWRITE_*`) deliberately excluded via the existing
`is_burst_write` signal -- its own `ST_BWRITE_S6->S4` loop-back never
revisits S2 for beats 2-4, which would have made `wdata_hold_r` go
stale; confirmed via a real `make test` regression
(`tb/biu_tb.sv`'s own "MOVE16 burst write" tests, which drive
`eu_m16_req` directly at this module's own port -- exercised by the
mandatory gate even though `eu_m16_req` is hardwired to `1'b0` in
`m68030_top.sv` and thus permanently unreachable from the real
integrated chip, MOVE16 having been removed entirely, Phase 250 F8).
Full mandatory gate clean (`make test` 38/38, `cosim_grp` 8/8,
`cosim_memind` 33/33, `dat-synth` 50/50), Harte bit-identical to
baseline.

**Finding 2 -- the fix, while correct, had zero measured effect.**
Re-synthesis gave `1.79 MHz`, unchanged. Re-reading the new critical
path showed why: `wdata_hold_r` ITSELF is now in the critical cluster
(~556 ns), because the value feeding it was never actually settled
ahead of time -- `s_state` is still the starting point of the exact
same chain feeding the new register's own `D` input. **Lesson: adding a
register downstream of a combinational chain only helps if the chain's
own source has already settled by an *earlier* clock edge than the one
the new register captures on.** Here it hadn't -- the underlying value
was still reactively recomputing on the very same edge.

**Finding 3 -- the real root cause: `dyn_bit_get_Dn`, a deliberate,
architecturally-necessary same-cycle reaction to `mem_ack`.**
`eu_seq_execute.svh:2509`: `dyn_bit_get_Dn = ... mem_ack && ...` --
live, combinational, no register. The instant a dynamic-bit
instruction's own memory read of its target register *number*
completes, this fires the same tick and immediately selects
`rd_a_sel`/`rd_b_sel`, which drives `rd_b_data`, which flows through
`ex_an_base` -> `ex_an_new` -> the ALU's own `alu_dst` (via the
documented "same-register auto-update" special case,
`eu_seq_execute.svh:4072`, e.g. `ADDA.L (A0)+,A0`) -> the ALU result ->
write-data -> the pins, all within the tick `mem_ack` asserts. This is
exactly the mechanism [[feedback_post_ack_signal_reuse]] documents --
it exists specifically to preserve the real-silicon-matching zero-gap
back-to-back bus timing Track 1-3 spent ~20 phases building. It is not
a bug and not simply pipelineable: the target register *number*
literally does not exist before the memory read completes, so there is
nothing to "preview" one cycle early the way the other 16 special-FSM
families can. Real 68030 silicon has the identical sequential
dependency -- it simply has custom-gate propagation delay fast enough
to fit within its own clock period, which FPGA LUT fabric cannot match
at the same logical depth.

**Finding 4 -- the scale of the real gap: 67% of the whole design fails
a 100 MHz budget, not just one chain.** Computed directly from the same
per-endpoint data: of 13,487 register endpoints, **9,040 (67.0%)**
exceed the 10 ns period a real 100 MHz `clk_4x` needs. Median endpoint
delay is 16.3 ns -- over 1.5x the budget, and that's the median, not an
outlier. This rules out "find and fix the one worst chain" as a viable
strategy on its own; reaching 100 MHz needs systemic register insertion
across a large fraction of the datapath.

**Finding 5 -- but the 9,040 failing endpoints are NOT evenly spread.**
Module-level breakdown of every failing (>10 ns) endpoint:

| Module | Failing endpoints | Share |
|---|---|---|
| `u_cpu.u_eu.u_seq` (decode/hazard/16 special FSMs) | 2,860 | 31.6% |
| `u_cpu.u_biu.u_cache` (D-cache interface) | 2,316 | 25.6% |
| `u_cpu.u_biu.u_icache` (I-cache interface) | 2,107 | 23.3% |
| `u_cpu.u_eu.u_rf` (register file) | 593 | 6.6% |
| `u_cpu.u_ifu` | 255 | 2.8% |
| `u_cpu.u_biu.u_mmu` (ATC) | 223 | 2.5% |
| `u_cpu.u_biu.u_cg` (cycle_gen) | 207 | 2.3% |
| `u_cpu.u_biu.u_sf` (sizing_fsm) | 138 | 1.5% |
| `u_cpu.u_biu.u_cg.u_bc` (burst_ctrl) | 131 | 1.4% |
| `u_cpu.u_exc` | 81 | 0.9% |
| peripherals (sdram/spi/uart/misc) | ~90 | ~1% |

**80.6% of all failing endpoints live in just 3 modules** (`u_seq` +
`u_cache` + `u_icache`). This turns "pipeline the whole design" into a
prioritized, 3-phase plan.

### Phase A (next, highest leverage, bounded risk): D-cache + I-cache -> real BRAM

`u_cache` (2,316) + `u_icache` (2,107) = **4,423 endpoints, 48.9% of the
entire failing population**, plausibly explained in full by the
already-confirmed BRAM-inference gap: `data_d`/`tag_d`/`valid_d` and
`data_i`/`tag_i`/`valid_i` fall back to flip-flops (`Warning: Replacing
memory ... with list of registers`, confirmed via a synthesis-only
Yosys run), not BRAM. Every one of those ~2,000+ storage bits gets its
own wide combinational read-select mux (16 lines x 4 words) plus
tag-compare logic -- thousands of individually-slow endpoints from one
structural cause. A real ECP5 `DP16KD` block has a dedicated,
hard-wired synchronous read port; using it eliminates this whole class
at once, no general LUT fabric or routing involved.

Root cause already diagnosed (read directly from `biu_cache_if.sv`'s
own `data_d` write sites): each array has multiple distinct write sites
(burst-fill from separate per-beat registers, byte/word merge-writes
via `merge_wr()`, full-longword writes) instead of one canonical
single-write-port pattern, which breaks Yosys's `memory_bram` template
matching. Fix: consolidate each array to a single muxed write port
(computing which source is active combinationally, feeding one write).
This directly reuses the timing model Phase 284 already established --
D-cache hit already costs 1 registered cycle (`CI_HIT`), matching a
real BRAM's own natural synchronous-read latency, so this should be a
clean fit, not a new cycle-count negotiation.

**Not yet started.** Also plausibly reduces placement congestion
generally (routing delay dominates the worst paths found so far, and
congestion correlates with logic density), which could improve *other*
modules' timing as a side effect -- worth a full re-measurement
(fresh `nextpnr --report`) after this phase alone, before scoping
Phase C's own real extent.

### Phase B (small, lower priority): MMU ATC + peripheral long tail

`u_mmu`'s 223 failing endpoints are the ATC -- an associative,
CAM-like structure (needs parallel compare across all entries), not a
plain indexed array, so BRAM conversion doesn't directly apply here.
Small enough (2.5%) to defer; revisit only if still a problem after
Phase A. Peripheral/misc (~90 endpoints, ~1%) is noise-level.

### Phase C (hard part, ~Track-1-3-scale effort): `eu_seq` restructuring

2,860 failing endpoints (31.6%) in the sequencer. Two genuinely
different problem shapes needing different treatment, not yet
separated out (module-level counts don't distinguish them):

1. **Genuinely runtime-reactive, same-cycle `mem_ack` dependencies**
   (the `dyn_bit_get_Dn` shape from Finding 3; likely siblings
   `cas_get_du_r`/`cas2_get_du1_r`/`cas2_get_du2_r` have the identical
   shape). Cannot be pipelined without either accepting a real extra
   cycle for that specific instruction shape (a narrow, deliberate,
   documented deviation from Track 3's own zero-gap guarantee, for
   probably 3-5 rare instruction families) or accepting they stay slow.
   **Needs explicit user sign-off before touching** -- this walks back
   a hard-won Track 3 property for a narrow case, not a decision to
   make unilaterally.
2. **Statically-known-ahead-of-dispatch logic that has simply never
   been staged** -- ordinary decode -> regfile -> ALU -> write-data
   dispatch with no runtime data dependency, just unregistered
   combinational depth. Fixable by extending the *existing* preview-port
   infrastructure (`rd_prev_a`/`rd_prev_b`, `eu_new_dispatch` --
   Track 1-3's own proven pattern for 16 special-FSM families) to also
   cover the general/ordinary dispatch path.

Realistically structured the same way Track 3 was: one instruction-
family/mechanism at a time, each with its own dedicated cosim hazard
test and full mandatory-gate + Harte verification before the next.
Given Track 3 itself was ~20 phases for a comparable-scale problem,
**Phase C alone is realistically comparable in size to Track 1-3's
entire multi-hundred-phase history.** Not yet started; not yet even
sub-scoped into "which of the 2,860 endpoints are category 1 vs 2" --
that categorization is itself real work for whenever Phase C begins,
likely easier to do accurately once Phase A's own real impact has
shifted/reduced the remaining population.

### Honest bottom line

- Phase A is well-scoped, bounded, and should be done first -- both for
  its own ~49% impact and because it changes the picture Phase C needs
  to solve.
- Phase C is a multi-phase, multi-session effort of Track-3 scale, and
  part of it requires a real architectural trade-off decision (accepting
  a narrow cycle-count exception) that isn't a unilateral call.
- 100 MHz is the target, not a guarantee -- re-measure via a fresh real
  `nextpnr --report` after each phase, exactly like every other phase in
  this project's history, rather than assume.

### Phase C re-scoping (a later session, `project_eu_pipeline_cutpoints.md`, read-only investigation)

After Phase A landed (real BRAM for `data_d`/`data_i`, 1.79->2.46MHz
measured), re-ran the module-level failing-endpoint breakdown against
the fresh `timing_report.json`: total failing endpoints dropped
9,040->4,886 (-46%, confirming Phase A's benefit was broader than just
the cache modules), but `u_seq`'s own count barely moved (2,860->2,972)
-- meaning its *share* of what remains jumped to 60.8%. Per-cell
synthesized names (`wb_result_TRELLIS_FF_...`-style) were investigated
and found **not reliable signal attribution** -- ABC9 names newly
created intermediate LUT/mux cells after the nearest still-traceable
ancestor register, which can be many hops removed from the real cause;
only the hierarchical instance-path prefix survives accurately.

Cross-checked against nextpnr's own single worst `critical_paths[0]`
(3249 hops): **both** endpoints trace back to
`u_cpu.u_biu.u_cache.addr_r` -- the same whole-system chain Phase 284
already found (BIU cycle-gen -> cache interface -> register file ->
address ALU -> write-data steering -> external bus), not something
newly isolated to `eu_seq`.

A dedicated read-only trace (`project_eu_pipeline_cutpoints.md`) found
the real shape is worse than this plan's own prior framing: `mem_addr`'s
dispatch mux (`eu_seq_execute.svh:5669`) has EVERY arm already
registered (`preview_addr` continuously computed from
`rd_prev_a`/`rd_prev_b`, every special-FSM arm a genuine `_r` flop) --
the mux inputs are not the depth problem. **The mux select,
`preview_ok`, is** -- gated on a ~17-way OR of every family's own
`*_final_ack`, every single one ANDed with `mem_ack` (THIS cycle's
ack), further ANDed with a ~14-term hazard chain. This is not
`dyn_bit_get_Dn`'s 5-family exception -- **it is the literal Track 1-3
zero-gap dispatch mechanism itself**, for every instruction pair in the
machine. Genuinely pipelining "ack arrives -> next address computed"
would insert a real gap cycle between every consecutive bus cycle for
every instruction, directly reversing Track 1-3's ~20-phase achievement
-- a much bigger ask than this plan's prior "5 special families need
sign-off" framing anticipated. TAS/CAS/CAS2's own bus-lock timing
depends on this exact path's precise cycle behavior -- explicitly
off-limits for any restructuring here.

**Only one low-risk, no-behavior-change lever found**: `preview_ok`'s
own flat boolean structure -- the 17-way OR (`preview_current_ready`)
and the 14-term hazard AND-chain -- restructured into balanced
sub-groups instead of one flat chain (the same bug shape as the
already-documented `feedback_elseif_priority_chain.md`). Pure
regrouping, functionally identical (OR/AND are associative), unverified
whether it measurably helps real synthesis until actually measured.
Implemented (`preview_ready_ordinary`/`preview_ready_special`,
`preview_hazard_grp1/2/3`, `rtl/eu_seq_preview.svh`) and verified: full
mandatory gate clean (`make test` 38/38, `cosim_grp` 8/8,
`cosim_memind` 33/33, `dat-synth` 50/50), Harte bit-identical to
baseline. Real synthesis+P&R measurement in progress to confirm whether
this actually moves `clk_4x`'s achieved frequency (per this project's
own established precedent -- `wdata_hold_r`, Phase 285, was equally
verified-correct and had zero measured effect).

**Bottom line, revised**: there is no clean, Phase-A-scale fix
remaining for `eu_seq`. The dominant chain is the deliberate, central
zero-gap dispatch mechanism itself, not a narrow local optimization.
Actually reducing what's computed same-cycle (true pipelining) is
understood to be a much bigger effort than previously scoped and needs
fresh, explicit user sign-off on a redefined Phase C before any further
RTL changes beyond the logic-restructuring already done here.

---

# MH030-P — a deliberately pipelined core (new initiative, planning closed 2026-09-23)

The incremental-timing-fix track above is **closed**. After Phase C was
re-scoped and found to be the Track 1-3 zero-gap dispatch mechanism
itself rather than a bounded `eu_seq`-local bug, the user decided to stop
patching timing and design a genuinely staged core instead, with MH030's
existing RTL kept green as the functional/cycle-accurate golden
reference.

**The full plan lives at `~/.claude/plans/purrfect-beaming-valley.md`**
(same convention as `wobbly-honking-cascade.md` /
`silent-copper-latch.md`). It is the authority on phases and gates; this
section is only the decision record.

**Four scope decisions taken and approved:**

1. **Bus fidelity: protocol-exact, timing-free.** Per-cycle signal
   sequencing (ECS/OCS, AS/DS stagger, SIZ/FC, DSACK handshake, RMC,
   burst continuity) stays exactly as the manual specifies and as MH030
   implements it. The *spacing between* bus cycles may differ. This is
   the single deliberate, signed-off divergence from MH030.
2. **Parallel core** at `rtlp/` (top `mh030p_top`), MH030's own `rtl/`
   frozen and kept green — not an in-place transformation, not a
   clean-room rewrite.
3. **Target 25-50 MHz `clk_4x`**, not 100 MHz. The "100 MHz" figure was
   never a protocol requirement: in the FPGA there is no real 25 MHz
   external bus (every peripheral runs on `clk_4x` too), so the genuine
   goal is instruction throughput on an ECP5-85K.
4. **Staged: integer core first**, MMU/caches brought into the pipeline
   later.

**Hard evidence for the diagnosis**, from the post-Phase-A
`impl/timing_report.json`: TRELLIS_COMB 54,344/83,640 (65% full) but
TRELLIS_FF only 9,367/83,640 (**11% full**), DP16KD 4/208. A **5.8:1
LUT:FF ratio** (a well-pipelined core sits near 1.5:1) is the
combinational-cone signature in hard numbers — and it also means the fix
is affordable: ~74k unused flip-flops and 204 unused BRAMs are available
to spend on register boundaries. Pipelining this design was never
resource-constrained; it was simply never attempted.

**Why this is tractable: most verification transfers unchanged.**
`scripts/run_harte.py` compares architectural state only
(`--timeout-cycles` is a budget, not an assertion), and
`tools/buscmp.py` compares the bus *transaction sequence*, not cycle
timing — so the full 124-suite Harte corpus, `cosim_grp`,
`cosim_memind` and `dat-synth` all carry over as-is. What does NOT carry
over: `tb/biu_tb.sv` / `tb/stall_fsm_tb.sv` cycle-count assertions and
`timing_diagrams/`, which stay owned by `rtl/`. A new dual-core
differential testbench (both tops, same memory image, compare
architectural state at retire plus the bus transaction sequence) becomes
the primary safety net, with MH030 as the golden model.

**Non-negotiable process rule**: every phase closes with BOTH the test
gate green AND a real measured Fmax number. `wdata_hold_r` (Phase 285)
was fully verified correct and had *zero* frequency effect, and the
`preview_ok` regrouping was never measured at all — measurement is not
optional. **P2's first real Fmax number is a genuine go/no-go** on the
whole effort.

## MH030-P P0 — scripted Fmax measurement + the sequential divider

**`scripts/measure_fmax.py` (new)**: `run` (full synthesis + P&R with the
KNOWN-GOOD unrestricted `synth_lattice` recipe, then analyse) and `analyze`
(an existing report, no synthesis). There was no timing target before this,
and the wrong recipe had already cost two measurements.

A methodology correction it forced: `detailed_net_timings`' per-endpoint
`delay` is that net's own **routing delay, not a cumulative arrival time**.
The "per-endpoint worst-case arrival / 9,040 failing endpoints" figure quoted
by earlier sessions is therefore *not reproducible* from this report, and is
not repeated. What the report genuinely contains -- and what the script now
reports -- is the fully enumerated worst path with per-hop delay, type and
hierarchical attribution.

**P0 FINDING: the worst path was not what the narrative assumed.**
Re-analysing the existing post-Phase-A report:

| Module (hierarchical prefix) | Worst-path delay | Share | Hops |
|---|---|---|---|
| `u_cpu.u_eu.u_md` | 191.18 ns | **47.0%** | 1920 |
| `u_cpu.u_eu.u_seq` | 169.34 ns | 41.6% | 1196 |
| `<top>` | 24.27 ns | 6.0% | 106 |
| `u_cpu.u_biu.u_cache` (+`data_d`) | 19.31 ns | 4.7% | 25 |

Total 406.99 ns / 3249 hops, 64.5% routing / 35.3% logic. The `u_md` portion
is a repeating ~60-hop / ~4 ns block about 30 times over -- a restoring-
division array. A design-wide cross-check (total net routing delay by prefix,
all 24,602 net-endpoints) says something different and equally important:
`u_seq` is 43.6% design-wide across 9,992 endpoints while `u_md` is only 5.3%
across 750. The two are complementary: **`u_md` binds the current number,
`u_seq` is the systemic problem**. Fixing the divider raises Fmax until the
next path binds; it does not remove the case for the rewrite.

**The fix (`rtl/eu_mul_div.sv`)**: it was `// purely combinational` by its own
first line -- four independent 32-bit dividers each instantiating both `/` and
`%` (eight divide operators), all evaluating every cycle and feeding the
writeback mux. Statically that is a register-to-register path that must settle
in one clock; functionally it never needed to, because the EU already holds
DIVS.L/DIVU.L stalled for 352/304 ticks to match real 68030 cycle counts. It
is a multicycle path in all but structure. Replaced by ONE shared sequential
restoring-division engine (one 32-bit compare+subtract per tick, 32 ticks),
computing the *identical* mathematical values -- same truncate-toward-zero
signed semantics, same overflow rules, same flags -- so every Harte-verified
behaviour is preserved exactly. Multiply stays combinational (it maps to
MULT18X18D DSPs, only 5 of 156 in use). Handshake: `div_start`/`div_busy`,
threaded through `m68030_eu.sv`/`eu_seq.sv`; `md_div_busy` joins
`ex_internal_stall`, which already means exactly "freeze EX latches, bubble
WB". For DIVS.L/DIVU.L Dn,Dn the existing 352/304-tick stall dwarfs the
divider's 32, so those cycle counts are unchanged; word and memory-source
forms genuinely do get slower, in the direction of the manual (DIVU.W is 44
clocks on real silicon; this RTL was computing it combinationally in ~3).

**Three real bugs found while integrating, none obvious statically:**

1. **Operand-derived flags must be latched with the operands.** A first
   attempt left `div_by_zero` combinational, reasoning it depends only on the
   divisor and never on an iteration. Wrong: for a memory-source divide `src`
   is only valid on the `mem_ack` tick, and the result is now consumed ~32
   ticks later, when `src` reads stale (often zero) -- producing a spurious
   divide-by-zero trap that aborted the instruction. Caught by `alu_mem_tb`'s
   DIVU-01/DIVS-01. Every divide output is now registered, latched at
   `div_start`, and `div_busy` asserts even in the short-circuited cases so
   the consumer always sees a settled value. `div_trap_raw` correspondingly
   now fires on the divider's own *completion* rather than at the three-way
   operand-validity predicate it used to carry -- that predicate still decides
   when the divide *starts* (`div_operands_valid` inherited it verbatim).
2. **Holding `ex_valid` through a stall re-issues the memory request.** The
   generic `mem_req` term is `ex_valid && (ex_is_mem_rd || ex_is_mem_wr)`, so
   a memory-source divide re-read its operand every bus cycle for the whole
   stall -- `cosim_memind25` showed four reads of `0x208` where the reference
   had one. This is the identical failure mode the artificial-stall whitelist
   already documents (and the reason that whitelist excludes memory-source
   forms). Guarded with `div_mem_operand_done`. The matching guard on
   `ex_mem_stall` is equally necessary: without it the instruction waited
   forever for a second ack that now correctly never comes.
3. **The guard must be qualified by `ex_unit == UNIT_DIV`.** `div_started_r`
   only self-clears on `!ex_valid`, and Track 1-3's zero-gap dispatch means
   `ex_valid` can stay high straight into the *next* instruction -- an
   unqualified guard suppressed that instruction's own read and hung the sim.

**Testbench consequences (three, all genuine expectation updates, not RTL
bugs)**: `alu_mem_tb`'s `run_instr` settle window raised 15 -> 60 ticks
(`instr_ack` fires when decode consumes the instruction, not when WB commits,
so DIVU-01/DIVS-01 were checking the destination before the divide wrote
back); `eu_tb`'s EU-6 now checks `div_trap` one tick later (the divide unit
reports it, rather than combinational logic); `eu_seq_tb` needed the new ports
wired (leaving `md_div_busy` undriven made `ex_internal_stall` an `x` that
corrupted unrelated tests, including cpSAVE/cpRESTORE).

**`tools/buscmp.py` gains `--allow-fetch-interleave`**, applied to the three
divide-based cosim targets (`memind25`, `memind33`, `memind40`). It compares
the program-fetch stream and the data stream **independently**, and both must
still match exactly and in order -- nothing is skipped or tolerated, unlike
`--allow-dut-extra-fetch`. Only cross-stream interleaving is relaxed, because
the longer divide lets the IFU prefetch queue run further ahead before a
dependent data cycle issues, and Musashi is purely functional and never models
prefetch overlap at all. Hand-verified per target before applying (memind25:
24 fetches + 13 data cycles byte-identical; memind33: 12 + 5; memind40:
26 + 10). A first attempt generalised `--allow-dut-extra-fetch` to skip a
*run* of reads instead -- wrong model, since those fetches are not extra but
merely reordered, and consuming them broke the later alignment.

**Verification**: `make test` 38/38, `cosim_grp` 8/8, `cosim_memind` 33/33,
`dat-synth` 50/50, and a full 124-suite Harte sweep at
`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` -- **bit-identical to baseline**
(the 2 are the documented ASL.b corpus anomaly).

**MEASURED RESULT: 2.46 MHz -> 14.24 MHz, a 5.8x gain.** (113 min yosys +
8.6 min nextpnr, the plain unrestricted recipe -- a genuine full ABC9 run, not
the ~2 min invalid-recipe signature. The 960 "conflicting drivers" warnings are
concentrated entirely in `tag_i`/`valid_i`/`valid_d`, the three cache arrays
documented as not yet converted to BRAM, not the design-wide spray the bad
recipe produces.)

| | Before | After |
|---|---|---|
| `clk_4x` achieved | 2.46 MHz | **14.24 MHz** |
| Worst path | 406.99 ns / 3249 hops | **70.24 ns / 97 hops** |
| TRELLIS_COMB | 54,344 | **42,387** (-22%) |
| TRELLIS_FF | 9,367 | 9,541 (+174) |
| Routing share of worst path | 64.5% | 82.5% |

Removing eight combinational divide arrays took ~12,000 LUTs out of the design
for the cost of 174 flip-flops. The worst path is no longer depth-bound (82.5%
routing) and has **no single dominator** left: `u_seq` 26.0%, `u_cache` 22.7%,
`u_md` 21.0% (its own iteration loop + result mux, now a reasonable 14.74 ns),
`u_icache.data_i` 18.0%. The path crosses 16 module transitions, i.e. it is
still the whole-system chain Phase 284 described -- just ~6x shorter.

**This materially changes the outlook recorded at the pivot.** The estimate
then was that further bounded fixes cap around 3-5 MHz and that genuine
pipelining of the dispatch mechanism would reach 10-20 MHz. One bounded fix
reached 14.24 MHz, which is already inside the range that was supposed to
require the rewrite. The 25-50 MHz target now looks plausibly reachable by
continuing with bounded fixes (the tag/valid arrays those 960 warnings point
straight at; the MMU ATC; `eu_alu`'s carry chain) before committing to a
multi-hundred-phase microarchitecture rewrite. That is a decision for the user,
not an argument that the rewrite is wrong -- `u_seq` is still 43.6% of
design-wide routing, and nothing here addresses that.

## MH030-P bounded fix 2 — multiply-driven cache arrays (a real hardware bug)

**Decision (2026-09-24)**: after P0 measured 14.24 MHz, the user chose to
continue with bounded fixes rather than start the rewrite (P1).

The next target was supposed to be "convert `tag_d`/`valid_d`/`tag_i`/`valid_i`
to BRAM", which the 960 synthesis "conflicting drivers" warnings appeared to
point at. **That framing was wrong on both counts and is corrected here.**
These arrays are tiny -- `tag_i[0:15]` is 400 bits, `tag_d[0:15]` 432,
`valid_d[0:15][0:3]` 64, `valid_i[0:15]` 16 -- against a 16 Kbit DP16KD, so
BRAM is the wrong target entirely and they correctly belong in flip-flops.
And the warnings were not about memory inference at all.

**The actual bug**: `tag_i`/`valid_i` were each assigned from **two different
`always_ff` blocks** (the `itrickle` sequencer and the main FSM), and `valid_d`
likewise (the `dtrickle` sequencer and the main FSM). Yosys reported this as
two `$dff` cells driving one net. In simulation it is a benign race -- the two
blocks never fire in the same cycle -- but it synthesises to two physical
flip-flops shorted onto one net and **would not work on real hardware**. Both
were introduced by Phase A's own trickle sequencers: `data_d` was correctly
given a single arbitrated write port for exactly this reason (its own comment
says so), but `valid_d` and the I-cache's `tag_i`/`valid_i` were simply missed.
`tag_d` has a single writer, which is precisely why it never appeared in the
warnings -- a detail that confirms the diagnosis rather than contradicting it.

**Fix**: each array now has exactly one assigning `always_ff`. The trickle
sequencers keep sole ownership of their own `*_active_r`/`*_next_r` state;
their array commits move into the main FSM block, reproducing each trickle
block's own guard condition verbatim, and placed FIRST in the `else` branch so
they hold the LOWEST priority -- a CACR invalidate or a concurrent fill
correctly overrides an in-flight trickle, rather than a line being resurrected
after it was invalidated. The I-cache still commits `tag_i`/`valid_i` only on
the last trickled word, which remains deliberate: `valid_i` is per-LINE, so
publishing earlier would claim a whole line valid while 3 of its 4 words were
still mid-trickle.

**New permanent gate: `make lint-drivers`.** `sv2v` + `yosys -p "proc; check"`
over `TOP_SRCS`, failing on any multiply-driven signal. `check` is the pass
that reports this and it must run after `proc` -- a plain `proc; opt_clean`
finds nothing, which is why an initial attempt at verifying the fix wrongly
reported zero warnings both before AND after and had to be discarded. Verified
end-to-end by temporarily restoring the pre-fix RTL: 480 warnings (400 `tag_i`
+ 64 `valid_d` + 16 `valid_i`, exactly matching the array dimensions), then 0
after. A whole-RTL sweep reports **0 problems**, so these were the only
instances. ~37 s, so it is cheap enough to run routinely. The full-design run's
960 was each warning reported twice, at module and at instance scope.

**Verification**: `make test` 38/38, `cosim_grp` 8/8, `cosim_memind` 33/33,
`dat-synth` 50/50, `lint-drivers` clean, Harte
`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` -- bit-identical to baseline.

### Open: bit-field EA coverage gap in `rtl/` (found by the P1 sweep, NOT fixed)

`rtl/eu_seq_decode.svh:5957` restricts bit-field instructions to five EA
modes: `Dn`, `(An)`, `(d16,An)`, `(xxx).W` and `(d16,PC)`. It reports
**indexed `(d8,An,Xn)`, `(xxx).L` and `(d8,PC,Xn)` as ILLEGAL**, though all
three are legal control modes for BFxxx on a real 68020/68030.

Unlike the `MOVE CCR,<ea>` gap fixed alongside it, this is **not a small
change**, and the difference is worth recording so it is not mistaken for
one later. `MOVE CCR,<ea>` was a one-line condition plus a shared body that
already existed for the SR form. This needs four coordinated pieces:

1. **`m68030_seq.sv`** — bit-field `ext_count` is currently uniform
   (`is_bf` appears in one flat list at line 1021, with no per-mode
   handling). Indexed needs 2 extension words like `(d16,An)`; `(xxx).L`
   needs 3 (bf_spec plus two address words).
2. **`eu_seq_decode.svh`** — extend the mode list, add the `Xn` register
   read, `dec_xn_wl`/`dec_xn_scale`, and reposition `bf_spec_w` for the
   3-word case. The existing code selects `bf_spec` from `[31:16]` vs
   `[15:0]` on a two-way `bf_two_ext` test that a third case breaks.
3. **The `bf_mem_run_r` FSM** — its address generation is base+displacement
   only; indexed needs `An + Xn*scale + d8`.
4. **Register-port allocation** — `rd_a` is the EA base, so `Xn` needs
   `rd_b`, which the bit-field path does not currently claim.

That is the same shape and roughly the same size as the per-family
memory-indirect EA rollout phases, each of which was its own phase. It also
touches `eu_seq_decode.svh`, which currently passes 702,142 Harte vectors,
so it deserves a dedicated phase with its own tests rather than being
folded into P1's decoder work.

**Impact is low**: these are 68020+ bit-field forms with indexed/long
absolute EAs, exercised by no current test (the Harte corpus is
68000-captured and has no bit-field coverage at all). The new decoder
deliberately matches the reference's restricted set and comments why, so
nothing silently diverges in the meantime.

## MH030-P P1 — STATUS: decoder complete to its useful limit

### What exists

- `rtlp/mh030p_uop.svh` — the micro-operation definition. Encoding choices
  proven through iverilog/sv2v/yosys with scratch compiles *before* the file
  was written: no `typedef enum` (Icarus demands a cast on every non-literal
  assignment), no `'0` or `'{...}` on packed structs, constant bit-selects
  hoisted out of `always_*`. Every encoding shared with `rtl/` (sizes, units,
  ALU ops) is reproduced exactly, never tidied, because a second encoding
  means a conversion layer.
- `rtlp/mh030p_decode.sv` — combinational decoder, 33 uop classes.
- `tb/uop_decode_equiv_tb.sv` — sweeps all 65,536 opcodes against the
  reference decoder, in `make test` (39/39) at 1.6 s. `+probe` dumps the
  reference's view of chosen opcodes; `+gaps` samples the first unclaimed
  opcode per group. Both diagnostics repeatedly turned "guess one convention
  per rebuild" into "learn a dozen in one run".

### Coverage: 52,845 of 58,053 claimed, 0 mismatches

Compared field by field: class, unit, ALU/md/bit op, size, writes_reg,
updates_ccr, destination register, and EA displacement/index/scale.

### The remaining 5,208 are mostly NOT implementable — this is the key finding

Most of what is left is the reference decoder **accepting genuinely illegal
encodings** instead of rejecting them:

| Opcode | What it is | What `rtl/` does |
|---|---|---|
| `0x1008` | `MOVE.B A0,D0` — byte MOVE cannot use An | decodes as normal MOVE.B |
| `0x5008` | `ADDQ.B #8,A0` — byte ADDQ to An | decodes, writes A0 |
| `0x9008` | `SUB.B A0,D0` | decodes as plain SUB.B |
| `0x203D` | mode 111 / reg 101 — reserved EA | decodes as MOVE.L |
| `0x00C0` | `ORI` with `ss=11` — not a valid size | decodes as OR |

On real silicon each takes an Illegal Instruction exception. **Driving this
sweep to 100% would therefore be wrong** — it would copy illegal-opcode
acceptance into the new core. The new decoder rejects all of them, so the gap
number will not reach zero and should not. This is the opposite of the
under-acceptance gaps below, and arguably worse: an under-accepted opcode
traps when it should not, an over-accepted one silently executes when it
should trap.

The rest of the remainder is the `ext_count` dependency: where several
extension words make a displacement's position ambiguous, the decoder sets
`ea_disp_valid = 0` rather than emit a wrong value. Porting
`m68030_seq.sv`'s ext_count chain would close MOVES with displacement, the
multi-word MOVE forms, and MOVEC.

### `rtl/` findings

| Finding | Status |
|---|---|
| `MOVE CCR,<ea>` memory destinations missing | **FIXED**, test `system_tb` MOVE_SR-03b |
| Bit-field EAs: no indexed/abs.L/PC-indexed | Scoped as its own phase (see above) |
| Illegal-encoding over-acceptance | **NEW**, not fixed, see table |
| CAS accepts only `(An)`, and not CAS.W | Recorded, matched not claimed |
| CMP2/CHK2 restricted mode set | Recorded, matched not claimed |
| Extension-word convention `[15:12]` | NOT a bug — `m68030_seq.sv:1160` normalises; my error |

### What P1 did NOT do

P1 is decode only. There are **no pipeline stages yet** — no registered
ID/AG/OF/EX/WB boundaries, no forwarding network, no `mh030p_top`. That is
P2, and P2 is what produces the first Fmax number for the new architecture,
which the plan names as the go/no-go for the whole rewrite.

**Nothing about the rewrite's central question has been answered yet.** The
existing core measures 13.78 MHz. The new one measures nothing, because
there is nothing to measure.

## MH030-P: the go/no-go measurement

Both cores wrapped in an identical thin harness (`scripts/gen_fmax_wrapper.py`)
and synthesised with the same recipe on the same part. The harness exists
because `rtl/m68030_eu` cannot be placed standalone at all -- 35 inputs
(450 bits) and 78 outputs against 365 pins.

| | New core (P3) | Old EU | ratio |
|---|---|---|---|
| Fmax | **38.02 MHz** | **19.55 MHz** | 1.94x |
| Critical path | 26.30 ns | 51.16 ns | |
| Hops | 77 | 77 | — |
| **Logic delay** | **8.99 ns** | **9.86 ns** | **1.10x** |
| Routing delay | 16.79 ns | 40.78 ns | 2.43x |
| TRELLIS_COMB | 4,618 | 29,043 | 6.3x |
| TRELLIS_FF | 1,048 | 4,474 | |

**The new core is 1.94x faster. But the reason is not what the rewrite
predicted, and that matters more than the headline.**

Logic delay is essentially the SAME (8.99 vs 9.86 ns) and both paths are 77
hops. The entire difference is routing: 16.79 ns against 40.78 ns. Routing
delay tracks physical spread, and the new core is **6.3x smaller** in LUTs
because it does far less. So most of the win is "a small design places
compactly and routes short", not "staging cut the critical path".

If pipelining were the dominant effect, the new core's LOGIC delay should be
markedly lower. It is not. That is the single most important number here and
it is the one that argues against declaring the premise validated.

Three further reasons to treat 1.94x as an upper bound:

* `u_md` is **32.2%** of the old core's critical path (16.45 ns). The new
  core has no multiply/divide unit at all. Adding one back attacks the new
  core's path directly.
* The new core has no exceptions, no MMU, no memory destinations, no indexed
  or memory-indirect EA, and none of the ~20 special-instruction FSMs. Every
  one of those adds LUTs, and LUTs are what the routing delay tracks.
* The harness is not perfectly common-mode: the output XOR tree scales with
  port count, 78 outputs against 9. Only 21% of the old core's path is in
  `<top>` though, so this is a bias in the new core's favour rather than the
  explanation.

**Honest verdict: the architecture is about 2x faster at one sixth the size
and a fraction of the functionality.** That is encouraging and it is real,
but it is not yet evidence that the pipelining is what bought it. The test
that would settle it is bringing the new core to rough feature parity and
re-measuring -- if Fmax holds near 38 MHz as the LUT count grows toward the
old core's, the premise is proven; if it decays toward 20 MHz, the gain was
size all along.

## MH030-P: the growth test — does Fmax hold as functionality lands?

All four measurements use the same part, recipe and identical thin harness
(`scripts/gen_fmax_wrapper.py`).

| Design | LUTs | Fmax | Period | Logic | Routing |
|---|---|---|---|---|---|
| New core, minimal (pre-P3) | 4,618 | 38.02 MHz | 26.30 ns | 8.99 ns | 16.79 ns |
| New core, all features | 7,038 | **33.96 MHz** | 29.45 ns | 8.18 ns | 20.74 ns |
| New CPU (core+IFU+arbiter) | 7,736 | **32.21 MHz** | 31.04 ns | 9.51 ns | 21.01 ns |
| Old EU (`m68030_eu`) | 29,043 | 19.55 MHz | 51.16 ns | 9.86 ns | 40.78 ns |

**The growth test result: +52% LUTs cost only −11% Fmax.** That is better than
area scaling alone would predict — routing delay in a 2D placement tends to
grow with roughly the square root of area, which for 1.52x area would have
cost ~19% period; the observed cost was 12%.

**Logic delay is flat across all four**, 8.2-9.9 ns. The new core is not
logically shallower than the old one and never was; what it has is far less
area, and therefore far shorter routes.

### The honest extrapolation, and why it matters

Reaching the old EU's 29,043 LUTs means another 4.1x growth from here. Fitting
the observed scaling (period ∝ area^0.27) gives ~43 ns, about **23 MHz**. A
square-root model gives ~60 ns, about **17 MHz**. So at genuine feature parity
this architecture plausibly lands somewhere around **17-23 MHz against the old
core's 19.55 MHz** -- comparable, possibly modestly better, but NOT the 1.94x
the first comparison suggested.

That first 1.94x was measured at one sixth the size and a fraction of the
function, and this test says most of it was size. The earlier caveat was the
right one.

### What this does not settle

The new core will not need 29,043 LUTs for the same function: it has no
zero-gap preview mechanism, no 17 bespoke multi-cycle FSMs, and a uniform
uop-driven EX instead of ~6,200 lines of combinational decode feeding execute
directly. How much of the old core's area was that machinery rather than
irreducible ISA cost is unmeasured, and it is the difference between
"comparable" and "meaningfully faster". Measuring it needs the new core taken
substantially closer to parity -- which is the same test, run again later.

### Growth test, second data point: functional breadth is nearly free

After adding bit operations, BCD, EXT/SWAP/ADDX and MOVEM:

| Design | LUTs | Fmax | Period | Logic | Routing |
|---|---|---|---|---|---|
| New core, minimal | 4,618 | 38.02 MHz | 26.30 ns | 8.99 | 16.79 |
| New core, all features | 7,038 | 33.96 MHz | 29.45 ns | 8.18 | 20.74 |
| New CPU (+IFU+arbiter) | 7,736 | 32.21 MHz | 31.04 ns | 9.51 | 21.01 |
| **New CPU + breadth + MOVEM** | **9,201** | **32.59 MHz** | **30.69 ns** | 9.25 | 20.91 |
| Old EU | 29,043 | 19.55 MHz | 51.16 ns | 9.86 | 40.78 |

**+19% LUTs cost nothing** -- Fmax went from 32.21 to 32.59 MHz, flat within
placement noise. The previous step cost 11% for 52%; this one cost zero for
19%.

That difference is the useful finding, and it is not luck. The earlier growth
was the AG stage and the memory path -- logic inserted INTO the dispatch
chain. This growth is bit-operation and BCD units sitting in parallel with the
ALU, plus a MOVEM sequencer that runs beside the pipeline rather than inside
its critical path. **Adding functional breadth is close to free; adding
dispatch depth is what costs.**

That is also precisely the distinction the original diagnosis rested on. The
old core's problem was never breadth -- it was `preview_ok`, a 17-way
ack-dependent mux select sitting in the middle of the longest path, i.e.
dispatch depth. This core does not have that and is not acquiring it as the
ISA fills in.

### Growth test, third data point: 12,106 LUTs at 28.21 MHz, and a new binder

After LEA/PEA/JMP/JSR, RTE with a real Format $0 frame and status register,
EXG, LINK/UNLK and the system-control moves (commit `048f6b3`):

| Design | LUTs | Fmax | Period | Logic | Routing |
|---|---|---|---|---|---|
| New core, minimal | 4,618 | 38.02 MHz | 26.30 ns | 8.99 | 16.79 |
| New core, all features | 7,038 | 33.96 MHz | 29.45 ns | 8.18 | 20.74 |
| New CPU (+IFU+arbiter) | 7,736 | 32.21 MHz | 31.04 ns | 9.51 | 21.01 |
| New CPU + breadth + MOVEM | 9,201 | 32.59 MHz | 30.69 ns | 9.25 | 20.91 |
| **+ control flow, RTE, EXG/LINK, sysctl** | **12,106** | **28.21 MHz** | **35.44 ns** | 8.80 | 26.11 |
| Old EU | 29,043 | 19.55 MHz | 51.16 ns | 9.86 | 40.78 |

+32% LUTs for -13% Fmax, which sits between the first step's -11%-for-+52% and
the second's zero-for-+19%. Logic delay is still flat (8.80 ns), for the fifth
measurement running.

**But the interesting part is not the number, it is where the path now is.**
The worst path has moved almost entirely into one module:

| Module | Delay | Share | Hops |
|---|---|---|---|
| `u_core.u_md` | 29.68 ns | **83.7%** | 61 |
| `u_core` | 4.88 ns | 13.8% | 8 |
| `<top>` | 0.89 ns | 2.5% | 4 |

73 hops total, 73.7% of it routing. `u_md` is `rtl/eu_mul_div.sv`, reused
verbatim: the divider was made sequential at P0 (the 2.46 -> 14.24 MHz fix) but
the MULTIPLY is still combinational, a 32x32 composed from five MULT18X18D
blocks plus LUT adders, and that composition network is the depth. It did not
bind at 9,201 LUTs and does bind at 12,106 -- not because it grew, but because
the design around it did, so its own nets got longer.

This is the same shape as the P0 finding, and the same kind of fix: bounded,
local, well understood, in a module the new core inherited rather than wrote.
It is the obvious next lever, ahead of any further parity work, because a
83.7%-of-path single module means nothing else can be measured until it moves.

### Growth point 4: breadth stopped being free, and logic depth moved

After TAS, CAS with a real bus lock, bit fields, MOVEC/VBR, MOVEP, CHK,
TRAPcc, Line-A, interrupts and the rest of the exception generalisation
(measured at commit `31ed707`):

| Design | LUTs | Fmax | Period | Logic | Routing |
|---|---|---|---|---|---|
| New CPU + breadth + MOVEM | 9,201 | 32.59 MHz | 30.69 ns | 9.25 | 20.91 |
| + control flow, RTE, EXG/LINK, sysctl | 12,106 | 28.21 MHz | 35.44 ns | 8.80 | 26.11 |
| + own two-stage multiplier | 12,913 | 29.11 MHz | 34.35 ns | 8.56 | 25.26 |
| **+ atomics, bit fields, MOVEC/VBR, MOVEP, interrupts** | **14,138** | **21.46 MHz** | **46.60 ns** | **11.89** | 34.19 |

**+9.5% LUTs for -26% Fmax**, which is far worse than any previous step and
breaks the pattern the earlier points established. The first-six-point curve
predicted 27.9 MHz at this area; the measurement is 21.5.

**The signal is logic delay, which moved for the first time in seven
measurements.** It had sat at 8.18-9.51 ns across every design measured, the
old core included, and is now 11.89 ns. Routing grew too, but routing growing
with area is expected; logic depth growing is not, and it says this increment
added combinational DEPTH rather than just area.

Reading the path confirms it: **74 of its 105 hops are CCU2C carry-chain
cells**, with 22 muxes and only 9 plain LUTs. That is arithmetic in SERIES --
roughly two 32-bit adders plus a comparator -- not a wide fan-in. (The
synthesized names all carry an `mvm_ready` prefix, which is not attribution;
ABC9 names new cells after the nearest traceable ancestor register.)

The likely cause, and it is a design error rather than a cost of the
instructions themselves: **the exception conditions were put into `stall_ex`.**
`exc_req` now includes CHK's signed 32-bit bound comparison, CMP2/CHK2's two
signed comparisons, and TRAPcc's condition-code mux -- and `stall_ex` gates the
AG-to-EX register, the writeback latch, `instr_ready` and the memory port. Every
one of those comparators is therefore in front of everything. Separately,
`mem_addr`'s mux acquired several new arithmetic arms (`ex_ea + cmp2_step`,
`mvp_addr + 2`, `exc_base - 8`, `vbr_r + vector`), each its own adder.

This is the same distinction the earlier points drew, landing the other way
round. "Functional breadth is close to free; dispatch depth is what costs" still
holds -- but exception DETECTION is not breadth. Putting a comparator in the
stall path is dispatch depth, and it cost what dispatch depth costs.

**The fix is structural and not yet attempted**: the trap decision is already
latched (`exc_pend`, added for a correctness reason -- see the CMP2/CHK2 commit),
so the comparators could feed only that register while `stall_ex` depends on a
cheap decode-time "this instruction might trap" flag plus a "decision made"
register. That costs one cycle on possibly-trapping instructions, which is
architecturally free -- real CHK is eight-plus clocks. It has NOT been measured,
and given this project's own record on predicted-versus-measured timing wins,
the estimate is worth nothing until it has been.

Refit over all seven points: period = 0.872 x area^0.398, which extrapolates to
**19.1 MHz** at the old core's 29,043 LUTs -- against its 19.55. The exponent
nearly doubled because of this one point. Dropping it gives back 0.276 and
22.9 MHz. Which of those is the real curve depends entirely on whether the
depth added here is structural or a mistake, and the paragraph above says it is
a mistake -- but saying so is not measuring it.

### The multiplier fix: it moved the path and barely moved the clock

The finding above said `u_md` was 83.7% of the worst path, so the new core got
its own two-stage multiplier (`rtlp/mh030p_mul.sv`, five 17x17 partial products
with the composition adders behind a register; verified against the frozen
reference over 2,000 operand pairs, bit-identical including N and Z).

| | LUTs | Fmax | Period | `u_md` share of path |
|---|---|---|---|---|
| before | 12,106 | 28.21 MHz | 35.44 ns | **83.7%** |
| after  | 12,913 | 29.11 MHz | 34.35 ns | **0%** |

**The fix worked structurally and gained 3%.** `u_md` is now completely off the
critical path -- 97.4% of it is in `u_core` -- and Fmax moved 28.21 -> 29.11 MHz.
The multiply was genuinely 84% of that path and was genuinely eliminated; the
NEXT path was 34.35 ns.

This is the third time this project has measured the same lesson, and it is
worth stating plainly because it keeps being tempting to forget: **an
attribution share is not a headroom estimate.** Phase 284 fixed two real
combinational loops for 1.78 vs 1.73 MHz. Phase 285's `wdata_hold_r` was fully
verified and had zero effect. Here a module holding 84% of the path yielded 3%.
In a routing-dominated design with many near-equal paths, removing the worst one
reveals the second, which is nearly as long by construction.

What binds now, read from the report rather than guessed: both endpoints in
`u_core`, 75 hops, 73.5% routing, and the delay concentrated in two `CCU2C`
carry chains with wide LUT muxes ahead of them -- a 32-bit adder fed by a deep
mux. (The synthesized cell names all carry an `mvm_ready` prefix, which is NOT
attribution: ABC9 names new cells after the nearest traceable ancestor
register, a trap already documented in `project_eu_pipeline_cutpoints.md`.)

Logic delay: 8.56 ns, the sixth flat measurement in a row (8.18-9.51 ns across
every design measured, old core included). The new core has never been
logically shallower than the old one. Its advantage is entirely area and
therefore routing.

### Refit over all six new-core points

period = 2.563 x area^0.276

| Target | Predicted |
|---|---|
| 15,000 LUTs | 27.5 MHz |
| 20,000 LUTs | 25.4 MHz |
| 29,043 LUTs (old core's size) | 22.9 MHz |

Against the old EU's 19.55 MHz. The exponent has drifted back up from the
0.22 the four-point fit gave to 0.276, because the two newest points landed
below the optimistic curve -- so the honest reading is the middle of the
earlier range, ~23 MHz at parity, not the ~25 the previous refit suggested.
The target band this effort was scoped to is 25-50 MHz; the core is inside it
NOW at 29.11 MHz, and the extrapolation says it leaves the bottom of that band
somewhere before parity unless something changes the curve rather than the
constant.

Refitting the scaling across all four new-core points gives period ∝ area^0.22,
which extrapolated to the old core's 29,043 LUTs is ~40 ns, about **25 MHz**
against its 19.55 MHz -- up from the ~23 MHz the previous fit suggested, and
now on a shallower curve.

The area question is also looking better than the LUT count alone implies: at
9,201 LUTs this core already executes the integer ISA including memory
operands, RMW, memory-to-memory, indexed EA, mul/div, branches, DBcc/Scc,
BSR/RTS, TRAP, bit operations, BCD and MOVEM. It is not remotely 1/3 of the
way through the old core's function at 1/3 of its area.


## MH030-P: what the core actually is, as of commit `f0e032f`

An inventory, because "are we at parity" is the question that keeps coming up
and the honest answer needs a list rather than a number.

### Executable: 27 of 33 µop classes

`UC_ALU` `UC_MOVE` `UC_MOVEQ` `UC_ADDQ` `UC_SHIFT` `UC_MULDIV` `UC_BITOP`
`UC_BCD` `UC_EXT` `UC_SWAP` `UC_EXG` `UC_SCC` `UC_BRANCH` `UC_DBCC` `UC_JMP`
`UC_RETURN` `UC_LEA` `UC_LINK` `UC_TRAP` `UC_SYSCTL` `UC_MOVEM` `UC_MOVEP`
`UC_BITFIELD` `UC_ATOMIC` `UC_MOVEC` `UC_ADDX` `UC_NOP`

Which in instruction terms means: the integer ALU set with memory operands and
read-modify-write, MOVE in every direction including memory-to-memory,
multiply and divide, all shifts and rotates, bit operations, BCD, MOVEM,
MOVEP, bit fields, TAS and CAS with a genuine bus lock, EXG, LINK/UNLK,
LEA/PEA/JMP/JSR, BSR/RTS, RTE/RTR with a real status register and Format $0
frame, DBcc/Scc, TRAP/TRAPV/TRAPcc/CHK/CHK2/Line-A, divide-by-zero,
autovectored interrupts with a non-maskable level 7, MOVEC with a real VBR,
and MOVE to/from SR/CCR/USP. EA modes: register direct, `(An)`, `(An)+`,
`-(An)`, `(d16,An)`, `(d8,An,Xn)`, absolute short and long, `(d16,PC)`,
`(d8,PC,Xn)`.

### Not executable, and why

| Gap | Reason |
|---|---|
| `UC_PACK` (PACK/UNPK) | **not decoded at all** -- needs decoder work first |
| `UC_CACHE`, `UC_MMU`, `UC_COPROC` | not decoded; out of scope for an integer core |
| CAS2 | immediate-mode encoding, two extension words, every field moves |
| MOVES | needs the alternate function codes to mean something |
| Bit-field MEMORY forms | needs the byte/word/longword sub-access sizing rtl/ got at Phase 276 |
| Bit-field Dn offset/width | two more register read ports than exist |
| Scc / MOVE SR / MOVE CCR to memory | write data is only known in EX; needs a write-from-EX path |
| Memory-indirect and full-format EA | needs the `ext_count` chain ported |
| Privilege violation, illegal instruction | no vector for either; the decoder reports UNIMPL rather than distinguishing illegal |
| Bus error, address error, formats $1/$2/$A/$B | only Format $0 exists |
| Trace (T0/T1) | no trace bit handling |
| Real IACK bus cycles | interrupts are autovectored only |
| The protocol-exact BIU, caches, MMU | P3/P6; the bus is still an abstract `mem_req`/`mem_ack` |

### The verification position, stated plainly

The core is held by **121 hand-written program checks** in
`tb/mh030p_top_tb.sv`, a 2,000-case differential test of the multiplier
against `rtl/eu_mul_div.sv`, and the 65,536-opcode decoder equivalence sweep.
`rtl/` is held by 702,142 Harte vectors, 8 cosim groups, 33 memind targets and
50 dat-synth vectors, **none of which has ever been pointed at this core.**

That gap is not academic. Building the classes above surfaced **16 real bugs in
already-shipped `rtlp/` code**, every one found by a test written to check
something else:

1. CCR never forwarded into EX -- `Bcc` after `CMP` used the previous comparison
2. `alu_x` absent from the X mux -- ADD/SUB/NEG/ADDX left X unchanged
3. No memory-destination RMW ever updated the CCR
4. `mem_hold` captured on any ack -- an RMW's write ack overwrote its read data
5. Forwarding expires under a stall -- CHK lost its operand mid-decision
6. `UC_TRAP` sub-op collision -- CHK, CHK2, TRAPcc and 4,096 A-line opcodes jumped through address 0
7. B-port forwarding selector never mirrored the B-port read
8. Bit-op flags zeroed N/V/C where the reference leaves them
9-13. `ext_words` miscounted five separate times (MOVE USP, TRAPF, bit fields, MOVEC/MOVES, CAS)
14. `ag_is_trap` blocked CHK's and CMP2's own reads -- memory-bound CHK could never have worked
15. Exception request re-evaluated from operands the exception sequence overwrites
16. `exc_disc_r` never cleared -- every instruction after a fault committed nothing

Items 3, 4, 5, 7 and 14 were all in code that had been passing its own tests
for many commits. The finding rate has not fallen off as the core matured; it
has stayed roughly constant per increment, which is what one would expect of a
core whose only net is its own hand-written tests.

**The single highest-value next step remains pointing Harte at `mh030p_top`.**
It compares architectural state only, so it transfers essentially unchanged,
and it would turn 121 checks into ~700k vectors.


## The measurement's own noise floor — and a correction

Three targeted fixes were made to the reported worst path and all three
"measured nothing". Checking why exposed a hole in the method rather than
anything about the RTL: **every measurement in this effort used
`--randomize-seed`, so no comparison ever separated placement noise from RTL
effect.**

Re-running the IDENTICAL netlist with a fixed seed settles it:

| Run | RTL | Fmax |
|---|---|---|
| nt6 | before the stall-path restructure | 21.46 MHz |
| nt7 | exception decision moved behind a register | 21.08 MHz |
| nt8 | + effective-address adder chain collapsed | 21.49 MHz |
| nt8b | **byte-identical to nt8**, seed 12345 | 21.01 MHz |

Seed-only spread: **0.48 MHz**. Spread across three genuinely different RTL
variants: **0.41 MHz**. They are the same magnitude, so all four numbers are one
population, ≈21.2 ± 0.25 MHz, and the three variants are indistinguishable.

### What this does and does not invalidate

**Still solid** — differences much larger than 0.5 MHz:
- the sequential divider, 2.46 -> 14.24 MHz
- cache BRAM inference, 1.79 -> 2.46 MHz
- this session's breadth cost, 29.11 -> 21.46 MHz (7.65 MHz)
- every growth-curve point, whose steps are 1-8 MHz apart

**Now only "below resolution", not "measured to do nothing"**:
- the stall-path restructure and the EA adder collapse. Both remain correct
  engineering -- the first removed real arithmetic from a signal that gates the
  whole core and fixed a real bug class, the second provably removed two 32-bit
  adds from a register-to-register path -- but any effect is under 0.5 MHz and
  this method cannot see it.

**A correction to a claim already recorded above**: the two-stage multiplier was
reported as "+3%, 28.21 -> 29.11 MHz". That is 0.9 MHz on a single run each, only
about twice the seed spread, from a comparison that also changed the seed. The
structural finding stands and is independently visible -- `u_md` went from 83.7%
of the worst path to 0% -- but the frequency figure is weak evidence and should
not be quoted as a measured 3% gain. The honest version is: the multiply left
the critical path, and the clock did not move enough to distinguish from noise.

### Protocol from here

No single-run comparison. Any change expected to move Fmax by less than ~2 MHz
needs at least three fixed seeds per variant, reported as a range. A change that
cannot clear that bar is not worth a 3-hour measurement at all -- which is itself
the useful conclusion, because it means single-path surgery on this design is
unmeasurable and therefore not the lever. The one effect that IS far above noise
is area: 12.9k -> 14.1k LUTs cost 7.65 MHz. That is where the signal is.


## The 50 MHz target, measured properly: it is a population problem

`make depth` (17 s, `scripts/logic_depth.py`) reads the synthesised netlist and
reports every register's logic-cone depth. Calibrated against four real nextpnr
runs at 0.794 ns per level, so 20 ns -- 50 MHz -- is a budget of **25 levels**.

At 14.1k LUTs the current core reports:

| depth | endpoints | |
|---|---|---|
| >= 57 levels | 3 of 2545 | the worst path, and the only thing nextpnr ever showed |
| >= 45 levels | 101 | |
| >= 34 levels | 263 | |
| **>= 25 levels** | **1073 of 2545 (42%)** | **over the 50 MHz budget** |

**That is the answer to why three consecutive critical-path fixes achieved
nothing.** Only 3 endpoints sit at the worst depth; 1,073 are over budget.
Repairing the deepest of 1,073 offenders cannot move the clock, and no amount of
reading nextpnr's report -- which names exactly one path per clock -- could have
revealed that. It was the question I most wanted answered after the multiplier
fix and could not answer from the data I had.

So 50 MHz is not "find the bottleneck". It is **halve the logic depth of 42% of
the design**, which is a microarchitecture job: more pipeline stages, shallower
cones between them. Consistent with the LUT:FF ratio of 5.7:1 against the ~1.5:1
a well-pipelined core shows, and with routing being 73% of the delay.

### Honest limits of the proxy

The ordering is reliable -- 43 levels measured fastest, 64 slowest, and the two
variants that tied at 57 levels measured within noise of each other. The absolute
figure runs ~15% pessimistic. But it is necessary, not sufficient: nt6 -> nt7 cut
depth 64 -> 57 and moved Fmax not at all, which says the design is congestion-
limited as well as depth-limited at this size. Use it to reject ideas cheaply and
to aim; still confirm with a multi-seed measurement before claiming anything.


## A genuine inconsistency found in rtl/, the frozen reference

Adding an extension-word-count check to the decoder equivalence sweep (see
below) surfaced one in `rtl/` itself, which is the outcome the plan explicitly
said to welcome rather than treat as scope creep.

`rtl/eu_seq_decode.svh` reports **valid=1** for `MOVE CCR,<ea>` with a memory
destination -- 0x42E8 `(d16,A0)`, 0x42F0 `(d8,A0,Xn)`, 0x42F8 `(xxx).W`,
0x42F9 `(xxx).L`. Those forms were added during this project's own P1 work
(recorded above: "MOVE CCR,<ea> memory destinations were missing entirely --
FIXED, with test system_tb MOVE_SR-03b").

But `rtl/m68030_seq.sv`'s `ext_count` still returns **0** for all four. Since
`drain = eu_instr_ack ? (3'd1 + ext_count) : 3'd0` is the only path that
retires words from the prefetch queue, a two-word instruction is counted as
one: the displacement would be executed as the next instruction.

**Not fixed here, deliberately.** `rtl/` is frozen for this effort, and
changing its sequencer requires the full mandatory gate including the
124-suite Harte sweep -- a separate piece of work with its own verification
cost. What is NOT yet established is whether it manifests: that depends on
whether any existing test actually executes one of those four forms, which
has not been checked. The decoder/sequencer disagreement is certain; the
observable failure is not.

### Why the check was worth building

Eight extension-word miscounts had been found ONE AT A TIME by the Harte
corpus, each costing its own debugging cycle: MOVE USP, TRAPF, bit fields,
MOVEC/MOVES, CAS, CMP2/CHK2, the group-0 byte/word immediates, and the
register-count shifts. Two of them (the group-0 immediates and the shifts)
presented as CPU HANGS, because a miscount does not produce a wrong answer --
it derails the instruction stream, and the fetch unit drains `1 + ext_words`
even for an instruction the core declines to execute.

They share one root cause: the count was derived from `ea_mode_w` and
`ea_is_imm`, which are computed from `instr[5:0]` unconditionally and are
therefore meaningless for any instruction whose low six bits are not an EA
field. `m68030_seq.sv` already computes the authoritative count for all 65,536
opcodes, so comparing against it turned eight discoveries into one exhaustive
check -- which then found three more immediately (RTS, RTE and RTR, all of
which had been claiming a word they do not have).

One methodological note. The sweep's own test extension word was
`0xA5A5_3C7F`, whose bit 8 is SET -- which makes every indexed effective
address a FULL-FORMAT one. Since this decoder deliberately implements only the
brief format, the check reported ~4,500 opcodes of that known gap and drowned
every real miscount. Changing it to `0xA4A5_3C7F` -- one bit, still asymmetric
between halves -- was the difference between a useless check and a decisive one.

## MH030-P reaches the reference: `PASS 702142 FAIL 2`

The full 124-suite Tom Harte sweep against the pipelined core:

    PASS 702142  FAIL 2  SKIP 281221  TIMEOUT 0

That is MH030's own number, to the vector. Every one of the 123 runnable
suites is at 100%; the two failures are the documented ASL.b corpus data
anomaly that `rtl/` cannot pass either, and the SKIP count matches because
the skip decision belongs to `can_run`/`gen_hex` in the harness, not to the
core.

This closes the integer-ISA-breadth work that had been running since the
core first executed an instruction. It does NOT mean the two cores are
equivalent: Harte compares architectural state only, so bus transaction
order (`buscmp.py`) and the multi-cycle families that no Harte suite covers
(they are 68020+-only) are still unmeasured against the new core.

### Getting there needed a faster sweep first

The Icarus runner was the real constraint on every remaining gap: one suite
at 1500 of its 8065 vectors took about as long as the whole corpus takes
now. `sim/harte_pvbatch` (`make sim/harte_pvbatch`) is a Verilator build of
the same manifest/blob protocol `sim/harte_vbatch` already spoke, so
`run_harte_batch.py --sim sim/harte_pvbatch` drives it unchanged. Validated
the way the `rtl/` backend was: ADDA.l gives the identical verdict through
both backends, 5256/5256, in 5 seconds instead of 30 for a third of it.
`sim/harte_p` (Icarus) remains the per-suite debugging tool -- it is what
`--verbose` diagnosis and `+bustrace`/`+ccrtrace` run on.

### The last gaps, and what they had in common

Three of the four were one bug wearing different clothes: **a destination
whose address register the source had already moved.**

| Form | Wrong by | Real rule |
|---|---|---|
| `ADDA.l -(A3),A3` | +4 | destination operand is A3 AFTER the decrement |
| `ADDA.l (A7)+,A7` | -4 | destination operand is A7 AFTER the increment |
| `CMPM.l (A7)+,(A7)+` | -4 | second address is A7+4; A7 ends 8 higher |
| `MOVE.w (A1)+,-(A1)` | -2 | must end where it started |

All four now come from one expression, `ex_src_an_post` -- the source
register's value after its own autoincrement, which for a predecrement is
just the computed address and for a postincrement is one step past it. The
step has to be at the OPERAND size with the A7-byte rule, not the write
size, which is the same distinction that made `DIVU.W -(A7)` hang earlier.

A fourth, unrelated one: `MOVE.w (d16,A7),(A7)+` shares the register but
the source does not MOVE it, so the displaced source address must not become
the destination's base. The same-register redirect is now gated on the source
mode actually being an autoincrement.

### Extension words are numbered, and each side reads its own

The decoder read every displacement out of the same half of `ext`. That is
correct only while at most one side of the instruction needs a word, which is
why `ea_disp_valid` had been gated to `ext_words == 1` and why memory-to-
memory moves with a displacement at each end were declared out of scope.

Extension words are numbered from 0 in instruction order: whatever precedes
the EA fields (an immediate, a register-spec word), then the SOURCE's own
words, then the DESTINATION's. The fill-in now derives the leading count by
**subtraction from `uop.ext_words`**, which is already swept against
`m68030_seq.sv`, rather than restating the per-family exceptions a second
time and getting a different answer. It found one immediately: the static bit
ops' immediate is ONE word whatever `instr[7:6]` says, and the old
`imm_takes_ext` guard read those bits as a size and skipped two.

Consequences:

* All EA derivation moved to the END of the decode block, after the word
  count exists -- including the index fields that had been assigned in eight
  separate branches.
* `ea_disp_valid` now means "every word this instruction needs is reachable"
  (indices 0-2; `ext` carries two, `q3` the third), so the sweep compares
  displacements and index fields for **every** multi-extension-word opcode
  instead of only single-word ones. Still 0 mismatches. A fourth word is
  genuinely unreachable, which is what rules out an absolute long at both
  ends.

### Indexed memory destinations are no longer out of scope

That exclusion was structural, not effort: the uop carried one set of index
fields. It now carries `dst_ea_idx_*` as well, and the register file has a
**fourth read port**, because a move with `(d8,An,Xn)` at both ends needs
four registers in the same cycle -- two bases, two indices. One more 16-to-1
mux and one register, against a stall on an instruction that already costs
several cycles, with ~74,000 spare flip-flops on the device. The destination's
index is scaled in AG, where the adder already lives, and carried into EX as
one value; the AG base interlock covers it the same way it covers the source's.

An immediate source also frees the single EA slot, since an immediate needs
no address, so `MOVE.l #imm,-(A0)` and `MOVE.b #imm,(d16,A0)` now execute
with the destination in `ea_*` and `ea_slot_is_dst` telling the fill-in to
read the destination's own offset.

## MH030-P's first real Fmax, and two restructurings the clock rejected

The plan's P2 gate was "a real Fmax number for the new architecture". The new
core cannot be dropped into the SoC -- its bus is abstract, not 68030 pins --
so `make fmax-p` / `make fmax-rtl` put **both** cores through the identical
`gen_fmax_wrapper.py` harness `make depth` already used, which equalises their
very different port counts (see that script's header). The absolute numbers are
therefore NOT comparable to the ~13.8 MHz whole-SoC figure; the rtl/-vs-rtlp/
difference is the measurement. `SEED` is explicit and fixed, never
`--randomize-seed`.

### The first number was 12.97 MHz, and 78% of it was a false loop

Attribution put 151 of the worst path's 179 hops in `u_peek` -- the small
decoder at the top level whose only job is telling the fetch unit how many
extension words to drain. It was a **cycle**: the fetch unit's `ext` is muxed
BY `ext_words` (one extension word is normalised into the low half), and
`u_peek` was fed that same `ext` to compute `ext_words`.

The cycle is false. Every read of `ext` in the decoder feeds `uop.imm`,
`uop.dst_reg` or a bitfield register select -- never `uclass`, `subop` or
`ea_mode` -- so `ext_words` is a function of the opcode alone and it settles
immediately in simulation. Place-and-route does not care: it unrolls the cycle
and charges two full passes through the decoder to one clock. The module walk
showed exactly that -- `u_peek` 59 hops, `u_ifu` 4, `u_peek` again 92, then
`u_core`.

Same class as Phase 284's loops in `rtl/`, invisible for the same reason:
simulation has no propagation delay. Broken with an `ext_raw` output (the two
words without the normalisation), and the property it relies on is now **tested
rather than commented**: the equivalence sweep decodes all 65,536 opcodes twice
with unrelated `ext`/`q3` and requires the same `ext_words`, failing hard
otherwise. **12.97 -> 23.13 MHz, +78%.**

### Then two "obvious" fixes, both of which made it slower

| change | mean Fmax (3 fixed seeds) | verdict |
|---|---|---|
| baseline | **22.93** (23.13 / 22.82 / 22.84) | -- |
| prefetch queue: shift -> head pointer | 21.80 (21.47 / 22.08 / 21.84) | reverted |
| `ext_words`: priority chain -> case | 21.69 (21.50 / 21.76 / 21.82) | reverted |

Both ranges are non-overlapping with the baseline's, so neither is the ~0.5 MHz
seed spread. Both were *correct* -- the queue change kept the full corpus
bit-identical, and the case was proven byte-identical on `ext_words` for all
65,536 opcodes via a throwaway dumping testbench, not merely on the subset the
sweep claims. Both were reverted on the measurement, with the finding left as a
comment at the site someone would next reach for them.

**The queue:** retiring words assigned all eight entries from a
variable-distance shift, every entry carrying a five-way mux driven by `drain`,
which decode produces -- the whole array downstream of a decode cone every
cycle. A head pointer does it with a 3-bit add. But the shift network
**terminates at flip-flops**, which have a whole clock to settle, whereas a head
pointer puts a variable eight-way read mux on `instr`/`ext`/`q3`, directly in
front of the decoder -- the one consumer with no slack. The change moved work
off a path with room onto the path that binds.

**The chain:** 25 conditions deep, feeding `issue`/`drain`. A case over `uclass`
is a balanced tree about six deep, and it was slower. The likely reason is that
the chain's early arms are cheap constants, so common cases exit in a few levels
and ABC9 maps that shape directly, while a case makes every arm pay full depth.

### What this says about the method

The logic-depth proxy predicted BOTH of these wrong, and in the same direction:
it liked the queue change (fetch unit 50 -> 32 levels, design-wide population at
or above 35 levels 679 -> 402) and it liked the case. It counts levels to each
endpoint without knowing which endpoints have slack, so it cannot distinguish
"deep path into a flip-flop with a clock to spare" from "deep path into the one
consumer that binds". **Treat it as a filter for candidates, never as evidence.**

What DID work, by a wide margin, was finding a structural defect -- a false
combinational cycle -- rather than trying to make correct logic shallower. That
is the same lesson Phase 284/285 recorded for `rtl/` (`wdata_hold_r` fully
verified and worth zero; the D-cache loop a genuine bug) and it now has two more
data points behind it.

**Position: 22.93 MHz standalone**, against a 25-50 MHz target. `make fmax-rtl`
(the same harness around `m68030_top`, the apples-to-apples baseline) had not
finished at the time of writing -- the reference core is much larger and its
ABC9 stage runs for hours -- so the architectural delta is still unquantified.

### The loop diagnosis, confirmed independently -- and the detector that missed it

The "+78%" claim above rested on a single pre-fix seed, so the mechanism was
checked directly rather than inferred: synthesise the pre-fix tree and run
nextpnr **without** `--ignore-loops`.

    pre-fix:   Info: Found 6 combinational loops:   (refuses to place)
    post-fix:  places and routes cleanly

Decisive, and it carries two consequences.

**`--ignore-loops` is now OFF for `make fmax-p`.** It was in the recipe when the
first measurement ran, and it was hiding these six. A flag that turns "your
design has a combinational loop" into "your design is mysteriously slow" is
worth more as a hard failure. `make fmax-rtl` keeps it: `rtl/` is frozen, and
that is the recipe every trustworthy measurement of it used.

**Verilator's UNOPTFLAT did not report them.** A full `--lint-only` over `rtlp/`
is clean, and so is `yosys proc; check` for multiple drivers. The loops close
through *instance ports at the top level*, and per-bit the cycle is genuinely
false, which is presumably why Verilator's analysis let them through. This
matters because Phase 284 used UNOPTFLAT as *the* detector for `rtl/`'s loops --
it is necessary but demonstrably not sufficient, and nextpnr's own loop check is
the one that finds this shape.

## Bus data-order cosimulation for MH030-P -- and a real bug it exposed

The full Harte corpus passing says less than it sounds. Harte compares
architectural state at the end of one instruction and nothing else, so it is
blind to the ORDER of memory accesses: a memory-to-memory move that writes
before it reads, a MOVEM walking its registers backwards, PACK's two reversed
byte accesses -- every one of those passes it. `tools/buscmp.py` is what checks
order, and no part of it had ever been pointed at the new core.

`tb/cosim_p_tb.sv` + `make cosim_p` do that now. Two things this core lacks had
to be supplied:

* **No function-code output** -- the bus is abstract. FC is synthesised from the
  two facts that define it: program-vs-data from which requester the arbiter
  granted (`u_arb.owner`), supervisor-vs-user from `sr_sys_r`. Not a guess.
* **A different fetch granularity** -- this fetch unit fills its queue a
  longword at a time where `rtl/` fetches a word, so the two *program* streams
  differ in transaction count and size by design and comparing them says
  nothing. New `buscmp.py --data-only` drops fetches from both logs and compares
  the data stream, which is where access order actually lives.

One incidental open question: this core reads its reset vectors on the DATA port
(fc=101) where `rtl/` reads them on the program port (fc=110). `rtl/`'s value
there turns out to be an **unoverridden default** (`biu_cycle_gen.sv`'s
`cyc_fc = 3'b110` initialiser, which the init states never set), so which is
correct per MC68030UM §8.1.1 is genuinely unsettled and was NOT "fixed" to match.
`--skip-dut 2` sets it aside for now.

### The bug: full-format extension words are silently misread, not rejected

Only 2 of 67 reference logs compare clean, and the reason is a single feature --
but its failure mode is worse than absence. `UEA_MEMIND` is never produced by
`mh030p_decode.sv`, and **`ext[8]` -- the bit that distinguishes a full-format
extension word from a brief-format one -- is never tested anywhere in the core.**
So a full-format EA is not declined; it is claimed and decoded *as if* it were
brief format, reading a base-displacement size field and an I/IS field as though
they were a scale, an index register and an 8-bit displacement.

Worse, `ea_words()` returns 1 for an indexed EA unconditionally, while a real
full-format EA carries 1 to 5 words (the extension word, plus a null/word/long
base displacement, plus a null/word/long outer displacement). The count is
therefore wrong, and a wrong count does not produce a wrong answer -- it derails
the instruction stream, which is the hang class this project has now documented
about a dozen times. `memind2` shows it exactly: its first two data writes match
the reference **precisely**, then the memory-indirect load at 0x24 is misread and
the core runs off fetching NOPs to 0x1f24 forever.

That the decoder equivalence sweep never caught this is itself instructive: its
test extension word is `0xA4A5_3C7F`, chosen with **bit 8 deliberately clear**
so that the known full-format gap would not drown every other miscount. The one
check that would have found it has the case excluded by construction.

### What closing it needs, and why it is not a patch

Rejecting full format correctly still requires reading bit 8 of *the EA's own
first extension word*, and that position is not currently reachable at the point
it is needed: `ea_words()` feeds the offset computation (`ew_pre`), so having it
depend on a word selected BY that computation is circular. The clean answer is
to give the decoder the fetch unit's `ext_raw` as a second input and do all
positional access from unnormalised words -- which has no dependence on
`ext_words` at all -- leaving `ext` for the legacy field reads. That is a
contained refactor, and it is the prerequisite for implementing full format
properly rather than a workaround.

So the next phase is: positional access off `ext_raw`, then reject-or-implement
full format. It unblocks ~60 of the 67 cosim targets, which are the only tests
in the project that can see memory access order at all.

## Five Fmax hypotheses, and the measurement that invalidated all five verdicts

Ran the loop the plan asks for -- checkpoint, implement, measure, accept or
roll back -- five times. **Every one came back ~1 MHz "below baseline", and
that turned out to be an artefact of the measurement, not a property of any of
the changes.**

| # | hypothesis | 3-seed mean | first verdict | real verdict |
|---|---|---|---|---|
| 1 | precompute BSR/JSR return address into a register | 21.68 | reject | unresolved |
| 2 | carry-save the 3-input `ag_ea` adder | 22.04 | reject | unresolved |
| 3 | pass `--freq` so nextpnr targets a real frequency | 22.93 | no effect | **confirmed** no effect |
| 4 | remove `eu_mul_div`'s multiply logic from the netlist | 21.49 | reject | unresolved |
| 5 | (not reached -- superseded by the finding below) | -- | -- | -- |

Hypothesis 4 is what broke it open. It only **deletes** logic -- a LUT-mapped
16x16 multiplier -- and deleting logic cannot lengthen a critical path. Measuring
it 1.4 MHz slower was impossible, so the measurement was wrong, not the change.

### The real number: the baseline's own spread is 1.32 MHz, not ~0.5

Measured directly, the unmodified baseline over nine placement seeds:

    23.13  22.82  22.84  22.49  23.00  22.64  22.10  21.81  21.99
    min 21.81   max 23.13   range 1.32 MHz   mean 22.54

**Seeds 1, 2 and 3 are its three best.** Every hypothesis was measured at seeds
1-3 against a "baseline" of 22.93 that was really the top of the distribution,
and every hypothesis' mean (21.49-22.04) sits inside the baseline's own range.
The earlier reasoning -- "the ranges do not overlap, so the difference is real"
-- was wrong in a specific way worth naming: **varying the seed samples
placement variation within a FIXED netlist, and says nothing about the
netlist-to-netlist variation that any RTL edit introduces.** Three seeds of each
is not a controlled comparison.

`make fmax-p-sweep` (SEEDS=9) now reports mean/min/max, and the recipe's own
comment carries the numbers so the next person does not redo this.

### This retroactively weakens two verdicts recorded earlier in this session

The prefetch-queue head-pointer change and the `ext_words` chain-to-case change
were both rolled back on exactly this basis -- 3 seeds each, "non-overlapping
ranges". Their means (21.80 and 21.69) also sit inside the baseline's 9-seed
range, so **neither is established as a regression.** Both remain rolled back,
which is still the right call on a different ground -- neither showed a
*benefit* either, and the simpler existing code is preferable absent evidence --
but the comments left in `mh030p_ifu.sv` and `mh030p_decode.sv` overstate the
case and have been corrected to say "unresolved" rather than "measured slower".

What survives unchanged from that episode is the narrower, still-valid point:
**the logic-depth proxy is not evidence.** It liked both changes; neither was
shown to help. It counts levels without knowing which endpoints have slack.

### One genuine code finding, independent of timing

`eu_mul_div`'s multiply logic reaches the `rtlp/` netlist as a **LUT-mapped
16x16 multiplier**, even though `mh030p_core.sv` ties its `op[2]` high (divide
only, `MUL_*` are ops 0-3) and every real multiply goes through `mh030p_mul`
instead. `MULT18X18D` count is exactly 5, which is `mh030p_mul`'s own five
17x17 partial products -- so `u_md`'s surviving product got no DSP and sits in
LUTs. Yosys's log shows it being narrowed (`Removed top 16 bits (of 32) from
port A`) rather than removed.

That is real dead area whether or not it costs frequency. Fixing it cleanly
means not instantiating `eu_mul_div`'s multiplier from `rtlp/` at all -- a
divide-only variant, or an opt-out parameter on the frozen module defaulting to
"on" so `rtl/` is unaffected. Not done here: the measurement cannot currently
show whether it is worth anything, and `rtl/` is frozen.

### Where this leaves Fmax

**22.54 MHz mean (21.81-23.13) standalone**, against the 25-50 MHz target. The
honest position is that this measurement cannot resolve a change worth less than
about 2 MHz, so the remaining route is not incremental restructuring -- it is
either a change large enough to clear that bar (the kind that has actually paid:
a combinational loop removed, a combinational divider made sequential, cache
arrays given real BRAM) or a better measurement, e.g. sweeping many seeds on
both arms of every comparison rather than three.

## Plan: larger structural changes for Fmax, ordered by likely impact

Written after five small hypotheses all came back unresolved (above). Two things
changed the basis for planning:

1. **Cell-name attribution is worthless in a flattened build, and that was
   believed for a whole session.** Ground truth: all five `MULT18X18D` cells --
   which can only be `mh030p_mul`'s, inside `u_core` -- are named
   `u_dut.u_ifu.req_epoch_LUT4_D_Z_...`. ABC9 carries the surviving ancestor's
   entire hierarchy path. The earlier claim that "67.8% of the worst path is in
   the fetch unit" is withdrawn; so is the flattened per-module breakdown.
2. **`make area-p` now gives real attribution** (`-noflatten` synthesis, each
   module's own cells, ~15 s). `scripts/measure_fmax.py`'s docstring, which
   asserted the dotted prefix was trustworthy, has been corrected.

Real per-module combinational cells:

| module | comb | % | carry | DSP | FF |
|---|---|---|---|---|---|
| `mh030p_core` | 10,714 | 35.6% | 480 | 0 | 1,430 |
| `mh030p_regfile` | 9,513 | 31.6% | 0 | 0 | 640 |
| `mh030p_decode` | 2,132 | 7.1% | 0 | 0 | 0 |
| `eu_shifter` | 2,084 | 6.9% | 34 | 0 | 0 |
| `mh030p_ifu` | 1,749 | 5.8% | 31 | 0 | 231 |
| `eu_bitfield` | 1,459 | 4.8% | 56 | 0 | 0 |
| `eu_mul_div` | 976 | 3.2% | 137 | **4** | 173 |
| `eu_alu` | 592 | 2.0% | 17 | 0 | 0 |
| `mh030p_mul` | 310 | 1.0% | 32 | 5 | 167 |
| others | 502 | 1.7% | | | |
| **TOTAL** | **30,083** | | | | |

**Acceptance criterion for every item below**: `make fmax-p-sweep` (9 seeds) on
*both* arms, `make test` 42/42, decoder sweep clean, full Harte corpus
`PASS 702142 FAIL 2`. Treat an Fmax difference under ~2 MHz as unresolved and
judge the item on its area/structure evidence instead. Items 1-3 are
independent and should be **batched** into one measurement, because
individually they may each sit under the resolution bar.

### 1. Register file: pack the array (MEASURED: 9,513 -> 4,697 comb, -51%)

The biggest single anomaly in the design, and the cheapest to fix. A 16x32
register file is 31.6% of all combinational logic. Yosys reports
`Replacing memory \regs with list of registers` -- correct, since a 4-read /
2-write file with a write-first bypass cannot be block RAM -- but the resulting
mux tree costs ~1,450 cells per read port, about **9x** what a 16:1 32-bit mux
needs (5 LUT4 per bit).

Cause is the *indexed unpacked array*. Replacing `reg [31:0] regs [0:15]` with
one packed `reg [511:0]` and part-select reads/writes (`regs_flat[{sel,5'b0} +:
32]`) makes yosys emit one `$shiftx` per port instead. Measured on the module in
isolation, same function and same 640 flip-flops:

    as-is                     comb 9513
    packed + part-select      comb 4697      -51%, and -16% of the WHOLE design

Cost decomposition, for further reduction if wanted:

| feature | cells |
|---|---|
| second write port | 2,039 |
| fourth read port | 1,464 |
| write-first bypass | 1,122 |

The fourth read port exists solely for the index register of an indexed
*destination* EA, which only memory-to-memory MOVE with `(d8,An,Xn)` at the
destination uses -- time-multiplexing it with port C at the cost of one stall
cycle on that one family is available if the packing alone is not enough.

Risk: low. Mechanical, behaviour-preserving, and the whole corpus exercises the
register file on every instruction. **Ready to implement.**

### 2. Divide-only unit for `rtlp/`: `eu_mul_div`'s multiplier is dead weight

`eu_mul_div` carries **4 MULT18X18D** plus most of its 976 comb cells for
multiply hardware that `rtlp/` can never reach: `mh030p_core` ties its `op[2]`
high, `MUL_*` are ops 0-3, and every real multiply goes through `mh030p_mul`
(which has its own 5 DSPs). In the *flattened* build yosys prunes it down to a
single LUT-mapped 16x16 product rather than removing it.

Fix without touching frozen `rtl/`: add `parameter MUL_ENABLE = 1` to
`rtl/eu_mul_div.sv` -- default leaves `rtl/` bit-identical -- and instantiate
with 0 from `rtlp/`. Alternative: a `rtlp/mh030p_div.sv` of its own, at the cost
of re-verifying divide.

Risk: very low. Expected: pure area plus 4 DSPs returned; may or may not move
the clock.

### 3. Prefetch queue: the same packing trick

`mh030p_ifu`'s `q` array draws the identical `Replacing memory \q with list of
registers` warning, and the module is 1,749 comb. The queue is read at four
rolling offsets and written at a variable index, so it has the same
indexed-array shape the register file does. Smaller prize, nearly free once item
1 establishes the pattern.

### 4. Forwarding network: one commit bus instead of two write ports per mux

`ag_a`/`ag_b`/`ag_c`/`ag_d` and `ex_a_f`/`ex_b_f` are each a 5-way 32-bit select
over `wb`, `wb2`, `wbp`, `wbp2` and the register read -- eight such muxes, all
sitting directly in front of the functional units and the address adders, inside
`mh030p_core`'s 10,714. Resolving the two write ports into a single prioritised
commit bus *once* turns every one of them into a 3-way select. A further step,
dropping one forwarding level in favour of an interlock, is available because
cycle counts are free under the signed-off timing model.

Risk: moderate. Forwarding produced this session's subtlest failures (a CHK that
detected its trap then lost the operand); full corpus after each step, not at
the end.

### 5. Give the slow, rare units their own cycle

`eu_shifter` (2,084) and `eu_bitfield` (1,459) are 11.7% of combinational logic,
both purely combinational, and both sit in the single-cycle EX result mux
alongside the ALU. Registering their results and stalling one cycle for those op
classes takes their depth out of the EX critical path entirely. Bit-field and
shift-by-register instructions are rare, and the manual already makes them slow.

Risk: moderate -- touches `ex_result` and the CCR source selection, which is
where several real bugs have lived.

### 6. Decode: registered predecode, or a positional-word convention

Two decode cones sit in series today: the fetch unit's `ext` output is muxed by
`ext_words`, which comes from a *full decode* of the same word (`u_peek`), and
that muxed `ext` is then the core decoder's input. `mh030p_decode` is 7.1% of
comb logic and is instantiated twice.

The clean fix is the positional-word convention already scoped for full-format
EA support: every field read takes its word by static index from the
unnormalised `ext_raw`, so the mux -- and the serialisation -- disappears. That
gives it **feature value independent of timing**, since it is also the
prerequisite for rejecting or implementing full-format extension words (see the
cosim section above).

Risk: moderate-to-high on its own terms -- a wrong `ext_words` derails the
instruction stream rather than giving a wrong answer -- but the exhaustive
65,536-opcode sweep covers exactly that.

### Considered and rejected, with reasons

* **Global stall network.** Inspected: `stall_ex` is already a shallow OR of
  cheap registered flags. Nothing to win.
* **Local arithmetic restructuring** (precomputed return address, carry-save EA
  adder, priority-chain-to-case, head-pointer queue). Five attempts, none
  resolvable by a measurement whose seed spread is 1.32 MHz. Not a lever.
* **`--freq` on nextpnr.** Tested, bit-identical results. The ECP5 placer is
  timing-driven regardless.

### Honest expectation

None of these can be promised a number in advance; that is the point of the
acceptance criterion. What can be said is that the three historical wins in this
project were all of the same shape as items 1, 2 and 5 -- removing or
sequentialising a large always-evaluating block (a combinational loop, +10 MHz;
a combinational divider, 5.8x; cache arrays to real BRAM, +37%) -- while every
attempt at making correct logic locally shallower has been unmeasurable. Item 1
alone removes 16% of the design's combinational logic, which is the largest
single lever now visible.

## Items 1-3 implemented and measured: area fell 17.9%, the clock fell 7.4%

All three were implemented, fully verified, and measured with 9 seeds on both
arms. **The batch is a clear, resolved regression and has been rolled back
except for item 2.**

| arm | n | mean | min | max | area (comb) |
|---|---|---|---|---|---|
| baseline | 9 | **22.54** | 21.81 | 23.13 | 30,083 |
| items 1-3 | 9 | **20.87** | 19.99 | 21.42 | 24,693 (-17.9%) |
| item 2 alone | 9 | 21.60 | 20.87 | 22.30 | 29,817 (-0.9%) |

The items 1-3 ranges do **not overlap** the baseline's (21.42 vs 21.81), so
unlike the five small hypotheses this one is genuinely resolved: removing 5,390
combinational cells -- 17.9% of the design -- cost 1.67 MHz.

Every functional gate stayed green throughout: `make test` 42/42, decoder
equivalence sweep clean including the opcode-only `ext_words` check,
`make cosim_p` 2/2, and the full 124-suite corpus bit-identical at
`PASS 702142 FAIL 2 SKIP 281221`.

### What each item actually did

**1. Packed register file: 9,513 -> 4,697 comb (-51%), same 640 flip-flops.**
Worked exactly as predicted on area. The mechanism is also now clear on timing:
an indexed unpacked array makes yosys build 32 independent, shallow,
locally-routable 16:1 mux trees, while one packed vector with part-selects makes
it build a **512-bit-wide `$shiftx` barrel network** -- far fewer cells, but
enormous first-stage fan-out and much worse routing in a design that is already
72% routing-dominated. Cheaper and slower. **Rolled back.**

**2. `eu_mul_div` multiply opted out (`MUL_ENABLE` parameter, default 1).**
976 -> 710 comb, 137 -> 83 carry, and **4 MULT18X18D -> 0**. Smaller than the
~700 comb this plan projected. **Kept** -- see the reasoning below.

**3. Packed prefetch queue: `mh030p_ifu` 1,749 -> 1,441 comb.** Same mechanism
as item 1, same verdict. **Rolled back.**

### Why item 2 is kept against its own measurement

Measured alone it is *also* ~0.9 MHz slower (mean 21.60, 7 of 9 seeds below
baseline, paired difference significant). But item 2 **only deletes logic that
the core cannot reach** -- `MUL_*` are ops 0-3 and `mh030p_core` ties `op[2]`
high -- and deleting unreachable logic cannot lengthen a critical path. The drop
is the placement lottery being re-rolled, not a consequence of the change.
Keeping known-dead multiply hardware and 4 stranded DSPs in order to appease a
noisy metric is the worse engineering call, so this one is kept on physical
grounds with the measurement recorded honestly rather than hidden.

`rtl/` is provably unaffected: the parameter defaults to 1, `m68030_eu`
instantiates without it, and MULU/MULS/DIVU/DIVS all run 100% (19,344 vectors).

### The methodological conclusion, which is the real result

This is now **eight** RTL changes measured against this design, and the pattern
is consistent: *any* netlist perturbation lands about 1 MHz lower, and that
includes **two changes that only removed logic**. The variance is not the
placement seed -- 9 seeds per arm pins that at ~1.4 MHz range -- it is
**nextpnr's P&R outcome varying with the netlist itself**, which the seed axis
cannot sample. Checked and eliminated as explanations: the measurement wrapper
is not on the critical path (0 of 97 hops), `--freq` makes no difference, and
cell-name attribution was already known to lie.

So, plainly: **at 18.6% utilisation and 72% routing dominance, RTL-level Fmax
optimisation of this core is not actionable through this flow.** Neither of the
two proxies works -- logic depth is blind to slack, and cell count is now shown
to be *anti*-correlated with the clock -- and the real measurement cannot
attribute a change smaller than the netlist-variance floor.

Two proxies dead and eight null-or-negative results is enough evidence to stop
this line. What remains genuinely worth doing is the architectural work that is
large enough to escape the floor -- more pipeline stages (plan items 4-6, in
particular giving `eu_shifter` and `eu_bitfield` their own cycle and cutting the
forwarding network) -- judged by *throughput* (Fmax / ticks-per-instruction) and
not by chasing a metric whose floor is 1.4 MHz wide.

### And the apples-to-apples baseline finally landed

`make fmax-rtl` (the reference `m68030_top` standalone, identical wrapper, seed
1) completed after hours in ABC9: **13.59 MHz**, against this core's 21.81-23.13.
The pipelined core is roughly **65% faster than the reference at the same
treatment**, a gap far outside the noise floor. That is the P2 go/no-go answer
the plan asked for, and it is a clear yes on architecture even though the
target band is 25-50 MHz and this core sits below it.

## Sequential shifter: 21.60 -> 29.16 MHz (+35%), and into the target band

Plan item 5, narrowed to its strongest form -- not "give the shifter its own
cycle" but **make it sequential, one bit per tick**, the same shape as the P0
divider fix. Measured with 9 seeds on both arms:

| arm | n | mean | min | max |
|---|---|---|---|---|
| original baseline | 9 | 22.54 | 21.81 | 23.13 |
| item 2 only (the arm this builds on) | 9 | 21.60 | 20.87 | 22.30 |
| **+ `mh030p_shift`** | 9 | **29.16** | 28.39 | 30.14 |

**+7.56 MHz on the arm it replaces, +6.62 on the original baseline.** The ranges
are nowhere near overlapping -- this is five times the 1.4 MHz noise floor and
the first change in this project's history to clear it by a wide margin. It also
puts the core **inside the 25-50 MHz target band** for the first time.

### Why it worked, and why the area number is beside the point

`rtl/eu_shifter.sv` is combinational and needs roughly **fourteen
variable-distance barrel shifters** to be: lsl, lsr, asr plus its sign fill, two
each for rol and ror, two 33-bit ones each for roxl and roxr, and three mask
generators of the form `result_mask >> eff_shift`. 2,084 cells, all
re-evaluating every cycle whether or not the instruction is a shift.

`rtlp/mh030p_shift.sv` steps one bit per tick and needs exactly one fixed 1-bit
shift per direction, which costs wiring: **220 cells**, a 9.5x reduction on the
unit. The core itself grew by 874 (the handshake and the extra stall term), so
design-wide area only fell 4.2%, 30,083 -> 28,827.

**A 4% area reduction bought a 35% clock gain**, which is the clearest
demonstration yet that cell count is not the metric -- what matters is *what kind*
of logic leaves the timing graph. A barrel shifter is depth; a mux tree is width.

### Single-bit iteration is the ground truth, which is why it is simpler

The awkward corners of 68k shift semantics need no special cases when you
iterate, because iteration is what the silicon does:

* `count > size_bits` clearing C and X falls out -- by then the value is zero and
  every further step shifts a zero out.
* ROXL/ROXR's period of `size_bits+1` falls out of rotating through X.
* ASL's V ("the MSB changed at any point during the shift") is a running OR,
  rather than the reference's windowed-mask reconstruction of the same question.

Only the `count == 0` case is special, and it is latched at start: C clears for
every op except ROXL/ROXR, which take the current X instead.

`rtl/eu_shifter.sv` is **untouched** and remains the reference; `rtl/` keeps
using it. The three documented sequentialisation hazards were all applied up
front (`feedback_sequentializing_combinational_unit`): every output is latched
with the operands, `start` is qualified by `mem_got` for the memory-EA forms, and
`shf_started` is qualified by instruction type so it cannot linger into the next
instruction under zero-gap dispatch.

Verification: full corpus bit-identical at `PASS 702142 FAIL 2 SKIP 281221` with
the only imperfect suite being ASL.b's two known corpus anomalies -- and the
corpus contains about two dozen shift suites, so this is strong equivalence
evidence. `make test` 42/42, decoder sweep clean, `cosim_p` 2/2, `cosim_grp` 8/8,
`make lint-drivers` clean.

### Throughput cost: not visible on these programs

A shift of count N now costs ~N ticks rather than 1. MC68030UM's own figure is
6 + 2n, so this is still faster than real silicon, and `rtl/` pays the 6 + 2n.
Execution-cycle counts on grp0-7 are unchanged at 3.33x faster than `rtl/`, but
those programs do not stress shift counts, so the cost is simply not
characterised by them. A shift-heavy benchmark would be needed to quote it.

### The throughput metric, corrected

The first version of the cross-core tick comparison measured "cycle when the
STOP opcode was fetched". That is **not** a fair point: `rtl/`'s prefetch queue
is 4-7 words and rtlp's is 8, so they run different distances ahead of execution
and the metric flatters whichever fetches further. Both testbenches now report
`EXECCYCLES`, taken from each core's own execution-stop register
(`u_seq.stop_r` and `u_core.stopped_r`). The corrected numbers give the **same
3.33x** (1185 vs 356 ticks), so the earlier figure survives -- but on a basis
that can be defended.

### What this says about where to go next

Three of this project's four large wins now share one shape: remove a big
always-evaluating arithmetic block from the timing graph (divider 5.8x, cache
BRAM +37%, shifter +35%). Every local restructuring was unmeasurable, and the two
array-packing changes were measurably negative.

The obvious next candidate is the same shape: **`eu_bitfield`, 1,459 cells**,
combinational, always evaluating, serving instructions that are rare and that the
manual already makes slow. After that the list thins -- `eu_bcd` is only 117
cells and `eu_alu`'s 592 genuinely must be single-cycle.

## Sequential bit-field unit: built, proven, measured, not adopted

The same lever that took the shifter from 21.60 to 29.16 MHz, applied to
`eu_bitfield`'s five variable-distance shifters (`(1<<aw)-1`, `data>>sr`,
`1<<(aw-1)`, `wmask<<sr`, `(src&wmask)<<sr`) and its **32-deep FFO priority
chain with a 32-bit subtract per level**. `rtlp/mh030p_bitfield.sv` removes all
of them: two fixed 32-tick passes, every step a 1-bit shift, no priority chain.

| arm | n | mean | min | max | bitfield comb |
|---|---|---|---|---|---|
| combinational `eu_bitfield` | 9 | **29.16** | 28.39 | 30.14 | 1,459 |
| `mh030p_bitfield` | 9 | 28.29 | 27.26 | 29.38 | 845 (+324 FF) |

Ranges overlap heavily, 7 of 9 seeds are lower, mean 0.87 MHz down --
**unresolved and leaning negative**, against a real cost of ~66 ticks per
bit-field instruction. So the core keeps `rtl/eu_bitfield.sv` and the new module
is left in the tree, clearly marked as not instantiated.

### Why it failed where the shifter succeeded

This is the transferable part. The shifter went **2,084 -> 220** cells with
almost no new state. The bit-field unit goes **1,459 -> 845 and adds 324
flip-flops** -- nine 32-bit registers (`data_r`, `src_r`, `wmask`, `dsh`,
`field_r`, `flag_r`, `fsh`, `pmask`, `splc`) -- and still leaves a combinational
output mux computing `~pmask`, `^pmask`, `|pmask`, `field_r | exts_sign` and the
FFO arithmetic, all now fed from those registers.

**Removing variable shifters only wins if you do not spend the depth again on the
way out.** A version holding less state might pay; that is the thing to try if
this is revisited.

### The verification net had to be built from scratch, and it earned its place

Bit-field instructions are 68020+, so the 68000-captured Harte corpus has **zero**
coverage of them -- sequentialising this unit with no net would have been
unverifiable. `tb/bf_equiv_tb.sv` compares the two units directly over 8 ops x 32
offsets x 32 widths x 12 operand pairs: **50,688 vectors, 0 mismatches** on the
result and all four flags, first run. It is in `make test` (43/43) so the module
cannot rot even though nothing instantiates it.

It also caught a real integration bug immediately -- and precisely the fallout
`feedback_sequentializing_combinational_unit` predicts. `tb/mh030p_top_tb.sv`'s
bit-field program had a fixed `repeat (350)` budget, ample for a combinational
unit but not for five sequential ops at ~66 ticks each: the last one was cut off
mid-flight, so BFCLR's result and its N flag were simply never written. Found by
instrumenting the unit and reading the trace rather than guessing, which showed
four ops completing correctly and the fifth starting but never finishing.

### Standing position after this

The core stays at **29.16 MHz mean (28.39-30.14)**, inside the 25-50 MHz band,
against the reference's 13.59 MHz and at 3.33x fewer ticks. Of the two
always-evaluating blocks left, `eu_bcd` is only 117 cells and `eu_alu`'s 592
genuinely must be single-cycle -- so **this line of attack is now exhausted**.
The remaining candidates worth real effort are SoC integration (a real hardware
number, and the 25-50 MHz target lives there) and a proper throughput benchmark.

## Units: what the measured MHz figure actually is

Worth stating plainly, because it is easy to read the wrong way round.

**Every Fmax number in this document is `clk_4x`, the INTERNAL clock.** CLAUDE.md's
design constraint is "run the Verilog design at 4x the external bus frequency
(e.g. 100 MHz internal for 25 MHz bus)", and the net nextpnr reports on is
literally `$glbnet$clk_4x`. So 29.16 MHz is 29.16 MHz *inside* the chip -- not a
68030 pin clock with 116 MHz running underneath it.

For `rtl/`, which is cycle-accurate, the division is real and meaningful: 6
S-states per bus cycle at 2 `clk_4x` ticks each is 3 bus clocks, so

    rtl/   clk_4x 13.59 MHz  ->  external bus 3.40 MHz
                              ->  performs as a real 3.40 MHz 68030

**For `rtlp/` the division does not apply at all.** That core has no S-states --
its bus is abstract, one request and one ack -- so `clk_4x` is simply "the clock",
and the name is inherited from `rtl/` rather than describing anything. Quoting
29.16/4 for it would be meaningless.

Which is why throughput is the only cross-core figure worth having:

    same programs (grp0-7):  rtl/ 1185 ticks @ 13.59 MHz = 87.2 us
                             rtlp/  356 ticks @ 29.16 MHz = 12.2 us
                             wall-clock speedup 7.14x

    => rtlp/ delivers the throughput of a real 68030 at ~24.3 MHz
    => a cycle-accurate core would need clk_4x = 97 MHz to match it

That last line is the whole case for the pivot in one number. 97 MHz `clk_4x` is
essentially the original 100 MHz target that three sessions of bounded fixes could
not approach -- the best `rtl/` ever measured in the SoC was 2.46 MHz, and 13.59
standalone. `rtlp/` reaches equivalent performance by spending **3.33x fewer
ticks** instead of chasing a 7x faster clock, which is exactly the
protocol-exact-but-timing-free trade that was signed off.

Caveats that ride along with the 24.3 MHz: it comes from 23-67-tick programs
(prologue-heavy, no loops or real memory traffic), and both cores were measured
standalone through the `gen_fmax_wrapper.py` harness rather than in the SoC. A
real benchmark and SoC integration are what would firm it up.

## Stage 2 (register-file area) -- analysed, and deliberately not done

The measured prize was real: the register file is 9,513 combinational cells,
~34% of the design, and its cost decomposes as **second write port 2,039**,
**fourth read port 1,464**, **write-first bypass 1,122**. Together the first two
are ~12% of the design. Every route to them turned out to be invasive surgery in
the read or commit network, for an area win with no expected speed benefit:

* **Fourth read port.** It exists solely for `dst_ea_idx_reg`, consumed only via
  `ex_didx`, for one instruction shape (memory-to-memory MOVE with `(d8,An,Xn)`
  at the destination). Removing it means time-multiplexing port C, and because
  the reads are REGISTERED -- address in cycle N, data in N+1 -- that is a
  **two**-cycle phase, not one: present the destination index, take it a cycle
  later, then present the source index and take that. It needs a 2-bit phase
  threaded through `rd_c_sel`, `rd_c_en`, `stall_ag`, the `ag_base_busy`
  interlock and the AG->EX boundary, plus a 32-bit holding register for the
  captured index (so the win is ~1,400 not 1,464).
* **Second write port.** Serialising EXG/LINK/UNLK means committing twice
  through port 1, and `wb_en` is forced low during a stall, so the commit path
  itself has to change. The write order also matters: the regfile documents that
  port 1 must win a same-register conflict because `UNLK A7` sets A7 from An and
  then pops into An, so the secondary write has to land FIRST.
* **Write-first bypass on ports C and D** looked like a cheap ~560 cells, on the
  theory that `ag_base_busy` already interlocks those registers. It does not
  cover the same hazard: the interlock catches a producer sitting in EX, while
  the bypass catches a read ISSUED in the very cycle a producer commits, whose
  value has fallen out of both forwarding levels by the time it is consumed.
  The regfile's own header justifies it for exactly that case.

**Why stop rather than push.** This session established, with 9 seeds on both
arms, that cell count is not just a poor proxy for the clock here but an
*anti*-correlated one: packing the register file and prefetch queue removed
**17.9%** of the design's combinational cells and measured **1.67 MHz slower**.
So the 12% buys area alone -- worth having eventually, for headroom to fit an
FPU, MMU and caches -- while the risk lands squarely on the read/commit network
that produced the session's one real win (the 29.16 MHz shifter result).

The honest conclusion is that this is the right change at the *wrong time*: it
belongs with a deliberate area campaign when something actually needs the space,
not in a speed programme. The numbers above are recorded so it does not have to
be re-derived.

## Stage 3: a real benchmark, and the finding that reframes the speed problem

`tests/bench1.s` + `make bench`. Three loops with genuine memory traffic -- a
bus-bound copy, an execute-bound register chain, and an address-generation-bound
indexed sum -- 64 iterations each, with the result checked (`D0 = 2016`) so a
wrong answer cannot masquerade as a fast one. This replaces the 23-67 tick
opcode-group programs, which are prologue-dominated and measure startup.

    benchmark execution ticks:  rtl/ 23,665   rtlp/ 6,116
      tick ratio        3.87x   (the toy programs said 3.33x)
      wall-clock ratio  8.30x
      => rtlp/ equals a real 68030 at 28.2 MHz

So the toy programs were *understating* the advantage. 28.2 MHz-equivalent is the
number to quote, not 24.3.

Both testbenches needed their fixed budgets made configurable to run this at all
(`+cycles`, and for `rtl/` a `+settle` -- it fetches the terminating STOP some
17,000 cycles before it executes it, so the old hardcoded 500-cycle settle
reported zero).

### Where the 6,116 ticks go, and it is not the execute pipeline

`make bench` now reports the budget:

    issued=1419  stalled=1544  idle=3163  redirects=253  bus=1610
                                          fetch=1352  data=258

**EX is idle -- nothing to execute at all -- for 3,163 of 6,116 ticks, 52%.**
And the front end issues **1,352 instruction fetches for 1,419 instructions**,
nearly one bus transaction per instruction, when a longword fetch supplies two.

The cause is visible in the same line: **253 taken branches**. The loops are 4-7
instructions long, so a branch flushes the prefetch queue roughly every five
instructions, discarding everything fetched past it and then refilling from the
target. The execute pipeline is not the bottleneck and neither is the clock --
the front end is.

### What that is worth

If fetch overhead vanished, the tick count would fall toward `issued + stalled`
= ~3,000, i.e. **roughly 2x the throughput**, which at the present 29.16 MHz
`clk_4x` would be equivalent to a real 68030 at **~56 MHz**.

The fix is the one real 68030 silicon uses and this core does not have: an
**instruction cache**. 256 bytes, direct-mapped, is enough to make a 4-7
instruction loop almost entirely fetch-free. That is plan item P6, and it is now
quantified rather than assumed: it is worth about as much as everything the Fmax
programme achieved, for a feature that has to be built anyway.

A cheaper intermediate, if P6 is too large to take on directly, is a loop buffer
-- keep the last N fetched words and satisfy a backward branch from them without
going to the bus. It captures most of the same win for tight loops specifically.

**This reframes the remaining speed question.** Eleven RTL changes were measured
against the clock this session for one resolvable win of +35%; the front end is
sitting on a 2x, it is measurable without any of the Fmax noise, and the work is
a feature the plan already schedules.

## Instruction cache: 6,116 -> 4,025 ticks, and fetches 1,352 -> 43

Acting directly on Stage 3's finding. `rtlp/mh030p_icache.sv` sits between the
fetch unit and the arbiter: **16 longwords, 64 bytes, direct-mapped**, with a
same-cycle ack on a hit.

    make bench, rtlp/:
      before   EXECCYCLES 6116   issued=1419 stalled=1544 idle=3163
                                bus=1610 fetch=1352 data=258
      after    EXECCYCLES 4025   issued=1419 stalled=1295 idle=1321
                                bus= 301 fetch=  43 data=258

**Instruction fetches fell 1,352 -> 43, a 97% reduction**, idle time more than
halved, and the tick count fell 34%. `D0` still checks correct, so the speed is
not bought with a wrong answer.

Updated cross-core position:

    execution ticks:  rtl/ 23,665   rtlp/ 4,025   ->  5.88x
    wall-clock (13.59 vs ~29.1 MHz)               ->  12.6x
    => rtlp/ equals a real 68030 at ~42.8 MHz     (was 28.2)

### Design choices, each with its reason

* **A longword per entry, not a 16-byte line.** This core's bus has no burst
  transfer -- the arbiter moves one longword per transaction -- so a line would
  need four separate misses to fill and would buy nothing over caching each
  longword as it arrives.
* **Same-cycle ack on a hit.** The fetch unit samples `if_ack` in a clocked
  block, so a combinational ack retires the request on that edge: a hit costs one
  tick. This is why the data is NOT in BRAM -- a registered read would make every
  hit two ticks, and with ~1,300 hits that would give back most of the win.
* **The tag carries address bit 1.** Fetch addresses are not longword-aligned in
  general: `fetch_pc` comes from `redirect_pc` and then adds 4, so a branch to an
  odd word address makes every later fetch 2 mod 4. The bytes at 0x08 and 0x0A
  overlap but are different requests returning different data.
* **It snoops the data side.** The real 68030's I-cache is not coherent with
  writes and expects software to flush. This one invalidates a matching entry,
  which costs one comparator and removes the whole class of risk -- the Harte
  harness synthesises programs whose writes can land anywhere.

### Size was measured, not assumed -- and 64 bytes is enough

Built and benchmarked at three sizes:

    entries   ticks   fetches   icache cells   design total
      16      4,025      43        3,257          32,116
      32      4,025      43        7,683          36,542
      64      4,025      43       10,583          39,442

**Identical ticks and identical fetch counts at every size**, because the loops
that matter are 4-7 instructions and 64 bytes already holds them whole. The read
muxes are what cost area and they grow with the entry count, so 32 and 64 were
paying ~4,400 and ~7,300 cells for nothing measurable. `ENTRIES` is a parameter;
raise it when a workload with bigger loops demonstrates a benefit, which this
benchmark cannot.

Area: 28,283 -> 32,116, **+13.6% for a 34% throughput gain**. The first cut of
the module used indexed unpacked arrays and cost 13,940 cells at 64 entries --
the same per-bit priority-mux pathology the register file has. Packing into
vectors with part-selects brought that to 10,583, and this is the case where
packing is right: the read feeds the fetch unit's queue write, a flip-flop with a
whole clock to settle, rather than the decoder and address adder that made
packing measure 1.67 MHz slower in the register file.

Verified: `make test` 43/43, corpus bit-identical at `PASS 702142 FAIL 2
SKIP 281221`, `cosim_p` 2/2, `cosim_grp` 8/8, `make lint-drivers` clean.

### The clock cost, and the first change that traded it away on purpose

The 9-seed sweep landed and the cache **does** cost clock:

| arm | n | mean | min | max |
|---|---|---|---|---|
| before the cache | 9 | **29.16** | 28.39 | 30.14 |
| with the cache | 9 | **27.70** | 27.09 | 28.41 |

Paired difference **-1.46 MHz, negative on all nine seeds** (sd 0.80), so unlike
most things measured in this project it is a real effect rather than placement
noise -- the added mux tree is not free after all, despite terminating in
flip-flops.

**It is still clearly worth it, and this is the first change here judged on
throughput rather than clock:**

    time per benchmark run   before 209.7   after 145.3   ->  1.44x net
    68030-equivalent         28.2 MHz       ->  40.7 MHz

Trading 5% of the clock for 34% fewer ticks is exactly the trade the plan's own
"the honest metric is Fmax / ticks-per-instruction" line asks for, and it is the
first time in this project that a change has been accepted while measuring
*slower* on the clock. Judging it by Fmax alone would have rejected a 1.44x
throughput win.

### What remains in the tick budget

`idle=1321` and `stalled=1295` of 4,025. Idle is still a third of all ticks, so
the front end has more to give even now -- the remaining misses are cold and the
253 redirects still cost refill latency. Beyond that, `stalled` is the execute
path, where the sequential shifter and divider now deliberately spend cycles.

## The caches were never switched on -- and that corrects every cross-core figure

Reverting the `rtlp/` instruction cache prompted the obvious question: what do
the 68030's OWN caches do? The answer is that nobody in this project had ever
looked, because **only two programs in the repo (`timing_manual_738/739`) ever
write CACR**, and the 68030 comes out of reset with both caches disabled.

`tests/bench2.s` is `bench1.s` plus a `movec` to CACR. Sweeping the enable bits:

| CACR | ticks | program fetches | data accesses | |
|---|---|---|---|---|
| `0000` | 24,689 | 1,354 | 256 | both caches off |
| `0101` | 9,360 | 33 | 256 | EI + ED |
| `2101` | 9,199 | 33 | 240 | + WA (write allocate) |
| `2111` | **9,185** | **17** | 240 | + IBE (instruction burst) |
| `3111` | -- | -- | -- | + DBE: **WRONG ANSWER**, see below |

**Simply enabling the caches is worth 2.69x on `rtl/`.**

### This invalidates figures I reported earlier in this session

Every cross-core number was measured against a reference running with its caches
off, which is not a fair comparison -- it is a comparison against a deliberately
crippled 68030. Corrected:

| | claimed earlier | actual (rtl/ caches on) |
|---|---|---|
| tick ratio | 3.87x | **1.50x** |
| wall-clock ratio | 8.30x | **3.22x** |
| rtlp/ as a real 68030 | 28.2 MHz | **10.9 MHz** |

The reverted I-cache experiment would have taken rtlp to ~16 MHz-equivalent on
the corrected basis, not 40.7. The *direction* of every conclusion holds -- the
front end really was costing 52% of rtlp's ticks, and fixing it really is worth
~1.44x -- but the headline magnitudes were inflated about 2.6x and should not be
quoted.

### Where the two caches stand, separately

**The instruction cache is already near-optimal.** 1,354 misses -> 33 with the
cache on, -> 17 with burst. There is essentially nothing left to win there; the
97.6% it removes is the same effect the reverted `rtlp` experiment measured.

**The data cache delivers almost nothing on this workload**, and the reasons
decompose cleanly:

* **128 of the 256 accesses are write-through writes.** Architecturally
  unavoidable -- the 68030 D-cache is write-through by design, so every write
  reaches the bus regardless.
* **The remaining 128 reads miss because of exact aliasing.** The index is
  `addr[7:4]` over 16 lines, so bits [11:8] are ignored: `SRC` at 0x1000 and
  `DST` at 0x1400 map to the identical lines. Two 256-byte arrays cannot coexist
  in a 256-byte direct-mapped cache, so every write evicts the line the next read
  needs. Write allocate recovers only 16 of 256 for exactly this reason.

That second point is faithful to the real chip, not a defect -- it is what a
256-byte direct-mapped cache does. Improving it means deviating from the
architecture (more lines, or associativity), which is a deliberate decision
rather than an optimisation.

### A real bug found: data-cache burst returns bad data

`CACR = $3111` (adding bit 12, DBE) makes this program compute the **wrong D0**
and never complete, while its write stream still looks correct -- so a data-cache
burst fill is returning bad data. Instruction burst on the *same shared burst
controller* works fine (33 -> 17 misses, answer correct), which places the fault
specifically on the data side.

Not chased further here: it is in frozen `rtl/`, `biu_cache_if.sv`'s burst
completion is the most intricate part of Phase A's work (an immediate write of
the requested word plus a `dtrickle_*` background sequencer arbitrating against
the main FSM), and it deserves its own session with the full gate.

### One dormant testbench gap closed on the way

`tb/cosim_grp_tb.sv` had no `burst_beat_probe`, so during a burst it returned the
same word four times. CLAUDE.md records that class of gap as "structurally
inapplicable because none of those testbenches ever enable CACR" -- which stopped
being true the moment `bench2.s` did. Added (two lines, reads 0 when no burst is
active, so a no-op for every existing test). Gate confirms: `make test` 43/43,
`cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth` 50/50.

### What "more efficient caches" actually means now

1. **Use them.** 2.69x, available today, costing nothing. Every future measurement
   on `rtl/` should enable CACR or say explicitly that it does not.
2. **Fix the data-burst bug.** It is the one unexplored efficiency feature and it
   is currently unusable.
3. **The instruction cache needs nothing.**
4. **The data cache's limit is architectural**, not implementational: write-through
   plus 256 bytes direct-mapped. Going further is a deliberate departure from the
   68030.
5. **For `rtlp/`, P6 is now quantified**: reusing these caches is worth ~2.7x on the
   fetch side, which is far more than the entire Fmax programme achieved.

## The data-burst bug: both caches shared one unqualified burst ack

Diagnosed and **fixed**. My first characterisation of this was wrong and worth
correcting: I reported it as "data-cache burst returns bad data, instruction burst
on the same controller is fine, so the fault is data-side". Narrowing the CACR
bits showed something else entirely:

| CACR | IBE | DBE | ticks | D0 |
|---|---|---|---|---|
| `0101` | 0 | 0 | 9,360 | correct |
| `1101` | 0 | **1** | 8,941 | correct |
| `1111` | **1** | **1** | 6,582 | **WRONG** |
| `2111` | **1** | 0 | 9,185 | correct |

**Data burst alone is fine, and faster. Instruction burst alone is fine. Only
both together fail.** So it was never a data-side fault -- it was the two clients
of the single shared burst controller interfering.

### Root cause

`rtl/m68030_biu.sv`, lines 785 and 909:

    .dc_burst_ack   (eu_burst_ack),     // D-cache
    .ic_burst_ack   (eu_burst_ack),     // I-cache

**Both caches were told that ANY completing burst was theirs.** The request side
has always been grant-gated -- `cg_burst_req_mux` is
`eu_burst_req | (dc_burst_req && grant_eu) | (ic_burst_req && grant_ifu)` -- and
the ack side simply was not. That asymmetry is the whole bug.

Why it survived: with only one burst-enable bit set, only one client ever has a
burst outstanding, so the stray ack reaches a module sitting in an idle state and
its own `state == ..._BURST0 && ack` guard fails harmlessly. With both set, a
cache waiting in its burst state consumes the OTHER cache's `burst_rdata0..3` as
its own line fill.

Fixed by qualifying both acks with the same grants the request side uses. The
arbiter holds a grant for the whole bus cycle and a burst is one bus cycle, so
the grant still identifies the owner when the ack lands.

    CACR=1111  before: D0 WRONG      after: 8,929 ticks, D0 correct
    CACR=3111  before: never completed  after: 10,273 ticks, D0 correct

### What the caches are worth, finally

    caches off (CACR=0000)                 24,689 ticks
    best configuration (CACR=1111)          8,929 ticks   ->  2.77x

Write allocate (`3111`) measures **slower** at 10,273, for the aliasing reason
above: allocating on write evicts the line the next read needs when SRC and DST
map to identical lines. So the best setting for this workload is both caches and
both bursts, no write allocate.

### Verification

Full mandatory gate, since this is a change to frozen `rtl/`: `make test` 43/43,
`cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth` 50/50, `lint-drivers` clean,
and the **124-suite Harte sweep bit-identical at `PASS 702142 FAIL 2
SKIP 281221`**.

`tests/bench2.s` is now the regression, wired into `make bench` with its own D0
check -- nothing else in the repo exercises IBE and DBE together, which is exactly
why this went unnoticed. A dedicated unit test in `tb/cache_tb.sv` (both bursts
enabled, data integrity checked) would be the stronger net and is **not** added
here.

### B-1: the unit test that catches it

`tb/cache_tb.sv` gains **B-1**, the regression the fix deserved, and it is verified
to fail without the fix rather than merely assumed to.

Three fresh 16-byte lines are read at their **last** longword -- the one a
whole-line fill must have fetched and the one a wrong-burst fill is most likely to
corrupt -- with `CACR = $1111` (EI | IBE | ED | DBE), the one combination no other
test in the file sets. B-1's own code is cold in the I-cache, so D-cache bursts are
issued while I-cache bursts are in flight, which is the overlap the bug needs.

**Confirmed to catch it.** With the fix reverted:

    FAIL  B-1: D4 line data correct: got 207c0000 exp 3c3c4d4d

`0x207C` is `MOVEA.L #imm,A0` -- B-1's **own instruction stream**, delivered into a
data-cache line. That is the bug stated as plainly as it can be.

Three things about writing it are worth recording, because each cost a rebuild and
all three are properties of this file rather than of the bug:

* **The code has to be emitted "up front."** Test blocks chain by `JMP_ABS_L_OP`,
  and the CPU reaches a spliced-in block while the testbench is still running the
  *previous* block's checks -- so code written later in the `initial` block does
  not exist yet when the CPU arrives. I-5's own ROM is up front for the same
  reason, and says so.
* **ROM setup and checks live in different regions of the same `initial` block**,
  and the section comments appear in both. Anchoring the check block on the
  `// D-13:` comment put it in the setup region, where it ran before the CPU had
  executed anything -- 5 spurious failures and a broken chain.
* **`emit_set_cacr` uses D7 as scratch**, so B-1 restores CACR (D-13/D-14/I-5
  inherit it) *after* its reads and deliberately never uses D7 as a result
  register.
* The non-vacuity checks are **address-gated** rather than the file's existing
  sticky `ic_burst_req_seen_r`/`dc_burst_req_seen_r`. Those are already set by
  earlier tests, and clearing them "just before B-1" is a race the testbench cannot
  win, since it does not know when the CPU arrives.

Gate after the fix, with B-1 in: `make test` 43/43 (cache included), `cosim_grp`
8/8, `cosim_memind` 33/33, `dat-synth` 50/50, `make bench` both programs correct,
and the 124-suite Harte sweep bit-identical (run before B-1 was added; B-1 is
testbench-only and cannot affect it).

## Stage 1: rtl/'s full-format MOVE ext_count -- two real omissions, and a reclassification

`m68030_seq.sv`'s `is_move_idx_src_memdst_full` listed destination modes
`{010,011,100,101}` and **omitted `110` (indexed) and `111` (absolute)**, so those
fell through to `is_memind_full`'s generic formula and reported the SOURCE's word
count alone. The sweep gives each an unarguable repro, because a full-format word
with a null base displacement and no memory indirection needs exactly as many words
as brief:

    op 0x11b0 brief             ext_count = 2   correct
    op 0x11b0 full, ext 0x3110  ext_count = 1   WRONG -- dst word lost
    op 0x11f0 full, ext 0x3110  needs 2 ((xxx).W dst), reported 1
    op 0x13f0 full, ext 0x3110  needs 3 ((xxx).L dst), reported 1

Fixed: an indexed destination adds its own brief extension word, exactly as
`(d16,An)` adds its displacement; an absolute destination adds 1 or 2 by its
sub-type, which lives in the MOVE destination register field `instr[11:9]`
(`f_dn` here). Same failure mode as the gap this block was originally written
for -- the IFU under-drains and decodes the destination's extension word as the
next instruction. Invisible to Harte (68000-captured, zero full-format coverage)
and to the memind suite, whose indexed-source cases all pair with a register
destination.

**Completion criterion, and it is met: zero MOVE-group disagreements remain for a
null-bd non-indirect full-format word.** 240 opcodes fixed (64 + 16 per group,
i.e. every register combination of each shape).

### The reclassification, which matters more than the fix

The sweep's 6,475 disagreements were described earlier in this file as evidence of
a bug in `rtl/`. Splitting them by the full-format word actually used shows that
was only true for a small part:

| full-format word | extra words it asks for | disagreements |
|---|---|---|
| `3110` | 0 | **499** |
| `3122` | 2 (word bd + word od) | 2,880 |
| `3133` | 4 (long bd + long od) | 2,856 |

Everything with extra > 0 is `rtl/`'s **documented scope boundary**, not a defect.
`is_move_idx_src_memdst_full`'s own comment says it is "scoped to non-indirect
full-format (fi_iis==000) only, matching the established boundary the entire
mode=110 EA rollout (Phases 116-147) already drew for genuine memory-indirect" --
so `memind_bd_words` counts base displacements and never outer ones, full-format
*destinations* are not handled, and full-format PC-indexed is a different decode
path entirely. `rtlp`'s decoder counts all of them, because it derives the count
straight from the manual's bit layout. **It is more complete than the reference, not
in disagreement with it.**

And the 499 that remain at extra=0 are all accounted for:

    group 4  18  -- MOVE CCR,<ea>: Stage 3's own bug, fixed separately
    group E  80  -- the documented bitfield-EA gap (no indexed/abs.L/PC-indexed)
    group F 401  -- F-line/coprocessor, which rtlp declines and the main pass excludes

So the sweep's full-format pass still cannot become a hard gate, but for a much
better-understood reason than "the reference is wrong": it is measuring a genuine
capability difference. Making it a gate needs either `rtl/` to implement the full
envelope or the check to exclude the documented boundary explicitly.

Gate: `make test` 43/43, `cosim_grp` 8/8, `cosim_memind` 33/33, `dat-synth` 50/50,
`make bench` both correct, 124-suite Harte sweep bit-identical at
`PASS 702142 FAIL 2 SKIP 281221`.

## Stage 2: non-indirect full-format EAs implemented in rtlp

Full-format extension words went from *counted and declined* to **executed**, for
the case that is plain arithmetic: `I/IS == 000`, no memory indirection, so the
address is base + base-displacement + scaled index. Genuine memory indirection
(`([bd,An],Xn,od)`) still declines, because it needs a memory read in the middle of
address generation and this core has no path for that.

Scoped from evidence rather than guessed. Looking at what the blocked cosim targets
actually use:

    memind7   ($100,a0,d1.l)       non-indirect full format, word bd
    memind13  (-$10000,a0,d1.l)    non-indirect full format, long bd
    memind2   ([$10,a0],d1.l)      GENUINE memory indirect -- still out

What it took:

* `ff_indirect()` / `ff_bd_words()` in the decoder, and `uop.ea_full_fmt` narrowed
  to mean "full format **and** genuinely indirect" so the arithmetic case becomes
  executable.
* The base displacement read from the word(s) following the EA's own extension
  word, sign-extended for the word form. Brief format's 8-bit displacement lives
  *inside* the extension word, and full format's low byte means BD SIZE / I/IS
  instead, so it must not be sign-extended as a displacement.
* `ea_bs` / `ea_is` (and destination equivalents) for full format's BASE SUPPRESS
  and INDEX SUPPRESS bits, which is how `(bd,Xn)`, `(bd,An)` and a bare `(bd)` are
  expressed. The core zeroes `ea_base` and `ag_idx` accordingly.

**Result: the data-order cosim goes from 2 of 67 targets to 4** -- exactly the two
identified above, which is the confirmation that matters. Both are now in
`make cosim_p`.

### One real bug, found by trace rather than inspection

The first attempt produced no change at all, and the reason is worth keeping. The
central EA fill-in recomputed the leading-word offset by subtracting the EA widths
from `uop.ext_words` -- but by then `ext_words` had already been *increased* by the
full-format extras, so the offset pointed one word too far and `sxw` read the
**base-displacement word instead of the EA extension word**. That silently wrecked
the displacement, the index register and the scale together. The cosim trace showed
it plainly: `add.l ($100,a0,d1.l),d2` read `A0` with no displacement and no index.

Fixed by computing the leading offset exactly once, from the BRIEF count, and
having the fill-in reuse it -- along with `ew_dst_at`, the destination's offset,
which has to step over the source's **full** width including its extras. The brief
count is the right basis and must stay so: these offsets locate the words that tell
us how many extras exist, so deriving them from the adjusted total is circular.

Gate: `make test` 43/43, decoder sweep clean, corpus bit-identical at
`PASS 702142 FAIL 2 SKIP 281221`, `cosim_p` 4/4, `make bench` both correct.

## Stage 3: rtl/'s MOVE SR/CCR,<ea> ext_count -- the chain had no arm at all

`m68030_seq.sv`'s `ext_count` had **no arm matching `MOVE SR,<ea>` or
`MOVE CCR,<ea>` with a memory destination**, so all 18 such opcodes fell through
to 0: a two-word instruction counted as one, with its displacement then decoded as
the next instruction. Meanwhile `eu_seq_decode.svh` reports `valid=1` for them --
the CCR forms were added deliberately, with test `system_tb` MOVE_SR-03b -- so the
decoder and the sequencer disagreed about the very same opcodes.

This had been recorded several sessions ago as "the disagreement is certain; the
observable failure is not", and left. It is now fixed, and one thing that was *not*
known then is settled: **it affects brief format exactly as much as full format.**
Driving the sweep with a bit-8-clear word gives the identical 18 disagreements, so
this was never a full-format corner -- any `MOVE CCR,(d16,An)` in ordinary code
would derail the instruction stream.

The 18: `(d16,An)` x8, `(d8,An,Xn)` x8, `(xxx).W`, `(xxx).L`.

    op 0x42e8  needs 1, reported 0
    op 0x42f9  needs 2, reported 0

New `is_move_sr_ccr_memdst` covering `f_dn` 000 (SR) and 001 (CCR) across those
modes, placed **after** `is_memind_full` in the chain so it is strictly additive --
anything that arm already handles keeps its existing, more complete count, and only
what previously fell through to 0 is caught.

### The sweep's exclusion is gone, which is the real win

`tb/uop_decode_equiv_tb.sv` had to **exclude `MOVE CCR,<ea>`** from its ext_count
comparison to stay green, with a comment explaining it was "a genuine inconsistency
in rtl/ rather than a limitation". That exclusion has been deleted: all 18 agree,
and the check now covers them like any other opcode. One of the sweep's three
documented blind spots is closed -- the remaining two (F-line, and bit fields with
a real EA) are genuine `rtl/` capability boundaries rather than inconsistencies.

Gate: `make test` 43/43, decoder sweep 0 mismatches with the exclusion removed,
`cosim_grp` 8/8, `cosim_memind` 33/33, `cosim_p` 4/4, `dat-synth` 50/50,
`make bench` both correct, 124-suite Harte sweep bit-identical at
`PASS 702142 FAIL 2 SKIP 281221`.

## Stage 4 (caches into rtlp): measured first, and the answer is not what P6 assumed

P6 says to reuse `biu_icache_if.sv` and `biu_cache_if.sv` under the A4 registered-
dispatch contract. Those modules talk to the whole BIU -- CACR, CDIS#, CBREQ/CBACK
and `biu_burst_ctrl`, `biu_cycle_gen`'s S-state FSM, `biu_sizing_fsm`'s DSACK
handling -- so reusing them means giving `rtlp` a real 68030 bus. Measuring what
that costs, before doing it, changes the conclusion.

**Cost of one bus transaction, measured from the benchmark:**

    rtl/  caches off   24,689 ticks / 1,546 transactions = 16.0 ticks each
    rtl/  caches on     8,929 ticks /   289 transactions = 30.9 ticks each
    rtlp/ abstract      6,116 ticks / 1,610 transactions =  3.8 ticks each

A real bus access costs `rtlp` **about four times** what its abstract one does --
6 S-states at 2 `clk_4x` ticks each is 12 ticks before any dispatch overhead.
Consequently:

| rtlp configuration | bus transactions | bus ticks alone | vs today's 6,116 total |
|---|---|---|---|
| today (abstract, no caches) | 1,610 | ~6,100 | -- |
| real BIU, no caches | 1,610 | **~25,760** | ~3x WORSE than rtl/ with caches |
| real BIU + real caches | ~300 | ~4,800 | roughly break-even |

**So for `rtlp` the real BIU and the real caches very nearly cancel out.** The
1.44x a cache measured earlier exists *because* this core's bus is cheap; a faithful
bus eats it. Stage 4 as P6 specifies it therefore buys **fidelity, not speed** --
which is a perfectly good reason to do it, but not the reason recorded.

It also reframes the caches: on the abstract bus they are an optimisation worth
1.44x, but under A4 they stop being optional. Without them a real-bus `rtlp` is
three times slower than `rtl/`; with them it is competitive. They pay for the BIU.

### The three real options

**A -- faithful caches plus the real BIU (P6/A4 as written).** Real pins, S-states,
DSACK, burst, CACR-controlled 256-byte caches, reusing verified `rtl/` modules.
Throughput roughly unchanged from today. Large effort. Buys architectural fidelity,
SoC integration and the first real-hardware number.

**B -- a faithful 68030 cache on the existing abstract bus.** 256 bytes, 16 lines x
4 longwords, CACR bits 0/1/3/2 and 8/9/11/10, write-through, no snooping (matching
silicon), plus `UC_CACHE` made executable so software can flush. Honest on geometry
and control, but **not** on fill: with no burst on this bus a 4-longword line costs
four separate transactions, so a miss costs 8 ticks where the reverted
longword-per-entry version cost 2. Roughly break-even on sequential code, winning
only on loops -- i.e. much of the 1.44x comes back only because the line is already
resident.

**C -- do not cache `rtlp` yet.** Record that the 1.44x is contingent on the cheap
bus and will evaporate under A4, and spend the effort on the A4 contract itself,
which is the actual blocker for a hardware number and for the SoC.

**Recommendation: C then A.** Treat the A4 bus contract as the next real piece and
bring the caches in *with* it, because that is when they stop being a nicety and
become the thing that makes a faithful-bus `rtlp` viable at all (25,760 -> 4,800
ticks of bus). Building a cache now tunes a configuration A4 is going to replace,
and B's unfaithful fill behaviour would have to be undone anyway.

## A4 implemented: rtlp on the real BIU, with the 68030's own caches

Option **C then A** was taken. C needed no code -- the finding above already
argued against building a cache for a bus that was about to be replaced -- so
this is A: `rtlp`'s CPU driving `rtl/`'s own verified `m68030_biu`, real pins,
real S-states, real DSACK, real bursts, and both genuine 256-byte caches under
CACR.

### What was built

`rtlp/mh030p_cpu.sv` (new) holds the fetch unit, the core and the peek decoder --
everything above the bus. It is shared by two tops that differ only in what sits
underneath:

| top | bus | used by |
|---|---|---|
| `mh030p_top` | `mh030p_arb`, abstract, one-tick ack | every pre-existing rtlp gate, unchanged |
| `mh030p_biu_top` (new) | `m68030_biu`, real pins | `tb/mh030p_biu_tb.sv` (new) |

`mh030p_top` keeps its exact behaviour -- this was deliberate, because that is
the arm carrying the full Harte corpus, and it must not be put at risk to
accommodate the new one. The core gained two inert outputs it had no reason to
publish before (`sr_sys_o`, `cacr_o`); `cacr_o` is what makes the caches
reachable, so software enables them here exactly as it does on `rtl/`.

`tb/mh030p_biu_tb.sv` is a pin-level peripheral: it watches AS/DS, answers with
DSACK, tracks burst beats, and holds CBACK asserted for the whole burst. Its
memory model is taken from `tb/cosim_grp_tb.sv` rather than reinvented, so a tick
count measured here is directly comparable with the reference's.

### The A4 adaptation is four conversions, all real

1. **Function code.** The core has no concept of address space; the BIU needs one
   for its cache tags, the MMU and the FC pins. Derived from SR's S bit.
2. **Write-data justification.** The core right-justifies (byte in `[7:0]`);
   `biu_byte_lane_ctrl.sv` expects the opposite and says so in its header. Reads
   need no conversion -- `merge_rdata()` already right-justifies.
3. **The bus lock.** `mem_lock` maps to `eu_cas_hold`, not `eu_rmw`: `eu_rmw`
   makes `biu_cycle_gen` run its combined 12-state RMW cycle, and this core
   dispatches the read and the write as two ordinary transactions. `eu_cas_hold`
   is exactly the signal Phase 241/242 added for that shape.
4. **Ack width.** `biu_cycle_gen` holds its ack high for all four ticks of S7
   (`rtl/m68030_ifu.sv:475` and `biu_sizing_fsm.sv:314` both say so, and both
   guard themselves accordingly). This core's port is specified with a
   single-tick ack. Converted in the adapter, not the core, for the same reason
   as above.

`eu_new_dispatch` is tied low -- the honest value. There is no preview mechanism
to report, which is the whole point of A4.

### Two real bugs found, neither in the new code

**1. `rtlp` issued unaligned longword instruction fetches.** Branch targets are
only word-aligned on a 68k, and `mh030p_ifu.sv` put the target straight on the
bus as a 4-byte read. The abstract memory models answer that, because they
assemble the result byte by byte from the exact address -- so a longword read at
0x0E genuinely returned the bytes at 0x0E..0x11. **No real 68030 bus can do
that**: a 32-bit port returns the aligned longword, so the queue received
`word@0x0C` first, one word too early, and every instruction after a branch
decoded one word out of step. It presented as a wrong answer, not a hang: the
copy loop in `tests/bench1.s` ran past its bound for over a thousand iterations
because the ADDQ incrementing its counter had been shifted out of the stream.
Fixed the reference's way -- round the target down to a longword boundary and tag
that fetch so it enqueues only its low word (`rtl/m68030_ifu.sv` carries a
`skip_first_r` for exactly this).

**2. `rtl/m68030_biu.sv` delivered a burst line to the wrong cache.** Signature:
correct with either burst-enable bit alone, wrong with IBE+DBE together -- the
same shape as the bug the previous session fixed by grant-qualifying
`dc_burst_ack`/`ic_burst_ack`. That fix was right that the request and ack sides
must agree on the owner. Its stated premise was not: *"the arbiter holds a grant
for the whole bus cycle, and a burst is one bus cycle, so the grant still
identifies the owner when the ack lands."*

`biu_cycle_gen` leaves `ST_IDLE` for `ST_BURST_S0` on a clock edge, and on that
edge `bus_idle` is still asserted while `bus_lock`'s own `is_burst` term is not
yet -- so `biu_arbiter` is free to re-arbitrate in the very cycle the burst
launches. Traced directly: at t=16885 the I-cache asserted `ic_burst_req` for
0x30 and won the bus; one tick later `grant_eu` was asserted because the EU is
essentially always requesting. The address `biu_cycle_gen` latched stayed the
I-cache's for all four beats (`ext_a=0x30` throughout), but at the ack the live
grant said EU, so `dc_burst_ack` fired and the D-cache took the I-cache's line as
its own fill for 0x1000. The instruction words at 0x30 were then copied into the
program's data and summed into its result.

Fixed with `burst_owner_ifu_r`, latched while `bus_idle` is asserted with a burst
pending and frozen thereafter -- the same discipline `biu_cycle_gen` already
applies to the burst address, and for the same reason
(`feedback_live_address_during_held_grant.md`). An edge detector on
`cg_burst_req_mux` was tried first and is wrong: the losing cache keeps its
request asserted while the winner's burst runs, so the mux can stay continuously
high across two bursts belonging to different clients and the detector never
re-arms. That version hung the benchmark outright.

This is a genuine latent bug in frozen `rtl/`, surfaced -- as the plan said to
expect and welcome -- by a configuration whose dispatch spacing differs.

### Measured

`make bench` now runs all four arms. Same program, same memory model, same
`EXECCYCLES` definition (each core's own execution-stop register):

| arm | bench1, caches off | bench2, caches on |
|---|---|---|
| `rtl/` reference | 23,665 | 8,929 |
| `rtlp` on the real BIU (A4) | 24,294 | **8,603** |
| `rtlp` on the abstract bus | 6,616 | n/a |

**The Stage 4 prediction holds, and it is the headline.** On a faithful bus the
pipelined core's advantage very nearly disappears: 6,616 ticks becomes 24,294,
because a real bus access costs ~16 ticks against the abstract bus's ~3.8. The
caches are what make it viable at all -- 2.82x, from 24,294 to 8,603 -- and with
them `rtlp` lands 3.7% ahead of the reference rather than the 3.6x the abstract
bus suggested. A4 bought fidelity, and the throughput claim was always the cheap
bus talking.

Bus transactions tell the same story from the other side: 1,737 with the caches
off, 231 with them on, of which only 21 are instruction fetches.

### Deliberately not done

`eu_iack_req` (real IACK cycles), `eu_cas2_req`, EU-initiated bursts, MOVE16,
`biu_multiop_fsm` for MOVEM/MOVEP, coprocessor and BKPT are all tied off, matching
how `rtl/m68030_top.sv` ties off what it cannot drive. The core autovectors
interrupts internally and sequences MOVEM/MOVEP from its own FSMs. Boot reads
addresses 0 and 4 twice, because the BIU runs its own SSP/PC init sequence and so
does the core; the BIU holds `eu_req` off until its own pair completes, so they
never collide, and consuming `init_ssp`/`init_pc` instead would need a boot write
port into the register file to save two bus cycles once. No Fmax measurement has
been taken for `mh030p_biu_top` yet.

### A recorded project fact does not survive gating: `--sim` was a no-op

Spot-checking BCC (a branch suite -- the obvious place for a fetch-alignment fix
to bite) gave **`PASS 3053 FAIL 28`, 99.1%** through `run_harte.py --sim
sim/harte_p`, against CLAUDE.md's claim that MH030-P passes all 123 runnable
suites at 100%. Chasing that turned up a **tooling bug, and the recorded number
is the casualty.**

`scripts/run_harte_batch.py` computed `sim_bin` from `--sim` and then never used
it: `run_chunk()` and `run_chunk_verilator()` both read the module-level
`SIM_BIN`/`VSIM_BIN` constants directly. So `--sim sim/harte_pvbatch` -- the
recipe CLAUDE.md documents for MH030-P -- **measured the REFERENCE core while
appearing to measure the pipelined one**, and with the default `--backend icarus`
it ran the reference *Icarus* binary over the whole corpus, which is exactly the
slow path CLAUDE.md warns about. Two full sweeps were started and abandoned in
this session before that was spotted; a third "confirmation" that BCC was
`3081/3081` was the reference core answering.

Fixed: the binary is threaded through to both launchers, and a `*vbatch` name
selects the Verilator launcher on its own, since pairing a native executable with
`vvp` cannot work. With the fix the two harnesses **agree exactly** --
`run_harte.py --sim sim/harte_p` and `run_harte_batch.py --sim sim/harte_pvbatch`
both report `PASS 3053 FAIL 28` for BCC.

**Consequences, stated plainly:**

- MH030-P's recorded `PASS 702142 FAIL 2 SKIP 281221` is **not reproducible** and
  should not be requoted. It was produced through the broken `--sim`, so it is
  the reference core's number. The reference's own figure is unaffected -- it is
  measured with `--backend verilator`, which was never broken, and it re-measured
  bit-identical this session.
- The 28 BCC failures are **pre-existing and not a regression** from the
  fetch-alignment fix: stashing `rtlp/mh030p_ifu.sv` and rebuilding gave the
  identical `PASS 3053 FAIL 28`.
- Same family as the "9,040 failing endpoints" figure that turned out not to be
  reproducible either.

**MH030-P's real full-corpus number, measured both with and without this
session's changes:**

| arm | result |
|---|---|
| MH030-P, this session's changes | `PASS 621799  FAIL 80345  SKIP 281221  TIMEOUT 576` |
| MH030-P, changes stashed (baseline) | `PASS 621799  FAIL 80345  SKIP 281221  TIMEOUT 600` |
| `rtl/` reference (unaffected) | `PASS 702142  FAIL 2  SKIP 281221  TIMEOUT 0` |

PASS and FAIL are **identical** with and without the changes, and TIMEOUT falls
by 24, so everything in this session is neutral-to-slightly-better and the
**80,345 failures are wholly pre-existing** -- roughly 11.4% of runnable vectors,
against a recorded claim of 2. The sampled failures are memory-destination ALU
forms (`ADD.w #,(d16,A7)`, `ADD.w #,(d8,A4,Xn)`) getting both CCR and the stored
bytes wrong, which is a systematic gap rather than an edge case, and nothing to do
with fetch alignment or the BIU.

So "MH030-P reaches the reference" was never true. Closing that gap is its own
piece of work and has not been started; what this session establishes is the real
starting number and a harness that actually measures the core it names.

## Measured baseline for the 100 MHz target (2026-09-28)

`make fmax-pbiu` / `fmax-pbiu-sweep` are new (the A4 configuration had no Fmax
target). Every number below is a real synth + P&R run.

| configuration | Fmax | basis |
|---|---|---|
| A4: `mh030p_biu_top` (rtlp CPU + real BIU + both caches) | **24.71 MHz** | 9 seeds, 23.68-25.74, range 2.06 |
| `m68030_biu` alone | **27.78 MHz** | 1 seed |
| `mh030p_top` (rtlp, abstract bus, no BIU) | 29.16 MHz | 9 seeds, recorded earlier |
| `m68030_top` (rtl/ reference) | 13.59 MHz | recorded earlier |
| A4 at **speed grade 8** instead of 6 | **25.01 MHz** | 1 seed, vs 25.10 same seed at grade 6 |

**Three findings that set the shape of the problem.**

**1. The reused BIU is already the ceiling.** 27.78 MHz standalone, against the
A4 configuration's 24.71 -- the whole design sits 11% below the BIU's own limit.
`rtlp` measures 29.16 MHz without it. So the three blocks are all in one narrow
band (25-29 MHz) and there is **no single bottleneck to remove**: improving the
pipelined core alone cannot pass ~28 MHz, because plan A5's "Tier 2, reuse the
BIU" decision caps it there. 100 MHz requires re-architecting `biu_cycle_gen`
and siblings, which that decision explicitly put out of scope.

**2. The device is not the limiter.** Speed grade 8 measured 25.01 MHz against
grade 6's 25.10 on the same seed -- no improvement, and ULX3S ships grade 6
anyway. There is no free 20% in the part. The entire 4x must come from RTL.

**3. Logic depth alone already exceeds the 100 MHz budget.** The A4 worst path is
42.23 ns over 85 hops, and it splits **74.4% routing (31.43 ns) / 24.3% logic
(10.28 ns)**. 100 MHz is a 10 ns budget, so *even with zero routing delay* the
present logic depth does not fit. 85 hops needs to become 10-15. Cutting depth
also cuts routing superlinearly, because shorter chains let the placer keep logic
local -- which is the real reason the routing share is so high.

Supporting evidence on where the depth is: **LUT:FF is 5.17 : 1** (26,147 COMB /
5,060 FF) where a well-pipelined core sits near 1.5:1. This is the same
combinational-cone signature that justified the rewrite for `rtl/` (5.8:1) -- the
new core has barely improved it. Utilisation is 31% LUT / **6% FF**, so ~78k
flip-flops are spare: registers are not what this design is short of.

**The worst path is an outlier, not yet a population.** nextpnr's three reported
paths for the worst seed are 42.23 ns (23.68 MHz), 11.69 ns (85.53 MHz) and
4.05 ns. The 3.6x gap between first and second says the binding path is one
structure rather than a broad front -- but nextpnr reports only three paths, so
this is **not** evidence that everything else is at 85 MHz, and the per-endpoint
`delay` field cannot be summed into arrival times (that is the mistake behind the
old, unreproducible "9,040 failing endpoints" figure). The honest method is
iterative: cut the worst path, re-measure, see what binds next.

Recurring ancestor names on that path are `ag_pc` and `mvm_ready`, and it crosses
into `u_biu.u_icache` twice. Only the instance prefixes are trustworthy
(`u_cpu.u_core`, `u_biu.u_icache`); the rest of each cell name is ABC-invented.
The shape -- fetch address, a MOVEM-readiness term, and the I-cache, in one
combinational chain -- points at the **issue decision** in `mh030p_cpu.sv`:
`if_instr` -> `u_peek` decode -> `peek.ext_words` -> `have_all` -> `issue` ->
`drain`, combined with `core_ready` from the core's stall logic and `redirect`
coming back. That is structurally the same mistake as `rtl/`'s `preview_ok`: the
per-cycle issue decision computed combinationally across a decoder, the queue and
the stall network. To be confirmed by RTL trace before acting, not assumed.

### Honest assessment of the 100 MHz target

100 MHz on LFE5U-85F is, on this evidence, **not reachable for this design
without changing the two scope decisions the MH030-P plan rests on** (reuse the
BIU; keep `rtl/` frozen as the model). The arithmetic is unforgiving: 4.05x from
24.71, with logic depth alone already at 10.28 ns of a 10 ns budget, no device
headroom, and the reused BIU capping the whole thing at 27.78 MHz.

My estimate, flagged as an estimate: Stages 1-2 below reach **30-40 MHz** with
reasonable confidence; Stages 3-5 plausibly reach **45-65 MHz** for an effort
comparable to Track 1-3; **100 MHz I would not commit to on ECP5 at all.** The
things that would genuinely change that answer are a different FPGA family (ECP5
is a 40nm 2014 part; a Nexus/CertusPro or Artix-7 would make 100 MHz far more
attainable) or accepting substantially more cycles per instruction to buy clock.
This estimate has been wrong in both directions before in this project -- the
pivot predicted 3-5 MHz for bounded fixes and one bounded fix delivered 14.24 --
so the staged gates below exist to replace it with measurements early.

### The stages

Each stage: implement, full mandatory gate, **9-seed** Fmax sweep (the noise floor
is ~1.4-2 MHz, so a single seed decides nothing), record the number here.

**Stage 1 -- the A4 issue-decision cone.** Confirm the worst path by RTL trace,
then break it. Prime candidate: predecode `ext_words` when a word ENTERS the
prefetch queue rather than at issue, storing 3 bits per entry, which removes a
whole decoder pass from the issue path; and register the `if_ack`/`mem_ack`
edge-detect products rather than feeding them combinationally into queue control.
Cheapest, highest-information step. Expected ceiling afterwards: ~28 MHz, because
the BIU binds. **Gate: does the next binding path move to the BIU?**

**Stage 2 -- `biu_cycle_gen`'s own worst path.** 27.78 MHz standalone with a
healthy 2.16:1 LUT:FF, so this is not a cone problem: it is a ~100-state FSM whose
next-state and pin-output decode are wide and flat. Levers that do not touch
protocol behaviour: one-hot state encoding, registered pin outputs (a pin driven
from a register one tick later is still protocol-exact as long as the S-state
sequence is preserved), and splitting the next-state decode by cycle type. **This
requires unfreezing `rtl/` or forking the BIU into `rtlp/`** -- see the decision
below.

**Stage 3 -- the core's 5.17:1 cone ratio.** Systematic, and the largest piece.
Split AG into address-mux then adder; split EX into operand-select then
ALU/shifter/BCD/bitfield; give the CCR/flag network its own stage. Each split
costs a cycle somewhere, so **the gate is Fmax/ticks, not Fmax** -- `make bench`
must be run alongside every sweep, or this stage can make the machine slower while
the clock number improves.

**Stage 4 -- routing locality.** Only worth attempting after 1-3, because 74%
routing is mostly a symptom of long chains. Then: hunt high-fan-out nets, consider
floorplan constraints, and re-check whether ABC9 mapping helps or hurts.

**Stage 5 -- re-decide the target.** With Stages 1-4 measured, either 100 MHz is
in sight on ECP5 or it is not, and the choice is between accepting the measured
number, spending cycles-per-instruction to buy clock, or changing device.

**The decision that gates Stages 2 onward**: the MH030-P plan's A5 says the BIU is
**Tier 2, reused**, and `rtl/` is frozen. 27.78 MHz says that decision and the
100 MHz target are incompatible. Either the BIU gets re-architected (in `rtl/`, or
forked into `rtlp/` so `rtl/` stays the golden model), or the target comes down.
Not a call to make silently.

### Decisions taken (2026-09-28), and what they change

1. **Fork the BIU into `rtlp/`.** `rtl/` stays frozen and keeps working as the
   golden model and as the core mackerel-030f ships. BIU fixes will have to be
   applied twice; nothing already verified is put at risk.
2. **Raw throughput is the goal, not the clock number.** So the metric is
   **`Fmax / ticks`**, and `make bench` runs beside every Fmax sweep. A stage that
   buys clock by spending cycles has to win on the product or it does not land.

**The tick budget on the real bus, measured** (`tests/bench2.hex`, caches on,
8,603 ticks, new `BUDGET` line in `tb/mh030p_biu_tb.sv`):

    issued=1421  stalled=4902  idle=2337  redirects=253  busbusy=3310

That is **6.05 ticks per instruction**, against 4.66 on the abstract bus. EX is
**stalled 57% of all ticks**, and 3,310 ticks (38.5%) have AS asserted -- so about
two thirds of the stall is waiting for the bus.

**231 transactions consume 3,310 ticks: 14.3 ticks each.** The protocol floor is
12 (6 S-states x 2 ticks), so the BIU is already near its own limit. This reframes
the programme, because it means **the bus protocol itself is now the largest single
consumer of time**, and under a throughput goal with no real 25 MHz external bus
it is buying nothing: every peripheral in the SoC is on `clk_4x` too, so 12 ticks
to read a longword out of on-chip RAM is pure protocol overhead.

**Revised stage order, highest expected `Fmax/ticks` first:**

**Stage 1 -- the issue-decision cone (clock, no tick cost).** As above. Pure win
either way, and independent of every other decision. Start here.

**Stage 2 -- fork the BIU into `rtlp/`, then cut its FSM depth (clock, no tick
cost).** 27.78 MHz standalone with a healthy 2.16:1 LUT:FF, so this is flat wide
decode rather than cones: one-hot state, registered pin outputs, next-state decode
split by cycle type. Lifts the ~28 MHz ceiling that currently binds everything.

**Stage 2b -- synchronous-termination fast path (ticks, NEEDS A DECISION).**
Potentially the biggest single item on the board: 3,310 bus ticks down to a few
hundred would take bench2 from 8,603 to roughly 5,900 (1.46x) *and* compound with
every clock gain. The 68030 already defines the mechanism -- STERM gives a
synchronous 2-clock cycle instead of 3 -- and the forked BIU could additionally
offer a genuinely short path for on-chip targets. **But this spends the one
bus-fidelity decision the MH030-P plan signed off** ("protocol-exact, timing-free":
per-cycle signal sequencing stays exactly as the manual specifies). Recommended,
because the pins it is being exact for are not connected to anything that needs it,
but not to be done silently.

**Stage 3 -- the core's 5.17:1 cone ratio (clock, COSTS ticks).** AG and EX splits.
Under a throughput goal this is a genuine trade and must be judged on `Fmax/ticks`
with `make bench`, not on the sweep alone. Demoted below 2b for that reason.

**Stage 4 -- routing locality.** Only after 1-3; 74% routing is mostly a symptom.

**Stage 5 -- re-decide the target** against measurements rather than estimates.

### Stage 1 investigation: the real structure, and two hypotheses killed

**Attribution first, because the flattened netlist cannot give it.** nextpnr's
worst path for the A4 config names `ag_pc` and `mvm_ready`, but those are
ABC-invented ancestor names and only the instance prefix is trustworthy. A
`-noflatten` synthesis gives real hierarchical names, and its path reads:

       0.52 ns    1 hop   u_cpu.u_ifu          (source register)
      23.49 ns   50 hops  u_cpu.u_peek         <- the peek decoder
       1.87 ns    4 hops  u_cpu.u_ifu          (the `ext` mux)
      18.68 ns   50 hops  u_cpu.u_core.u_dec   <- the core's decoder
       3.62 ns    4 hops  u_cpu.u_core
       6.90 ns   16 hops  u_cpu.u_core.u_rf    (read-port select)

**Two decoders in series in one clock**, joined by `mh030p_ifu.sv:117`:

    assign ext = (ext_words == 3'd1) ? {16'h0, q[1]} : {q[1], q[2]};

`ext_words` comes from `u_peek`; `ext` feeds `u_core.u_dec`. So the chain is
q[0] -> peek decode -> ext mux -> full decode -> regfile select. `ext_raw` was
added to stop `u_peek` depending on that mux (a genuine false loop), and it does
-- but it never addressed the core decoder's own dependence on the peek decoder's
output, which is the serial pass.

**Caveat on the 50/50 split, stated because it changes what to fix**: with
`-noflatten` Yosys cannot prune a module's unused outputs, and `u_peek`'s only
used output is `ext_words`. In the real flattened netlist the rest of that
decoder is pruned, so 23.49 ns almost certainly overstates the peek leg. The
*structure* is real either way; the depth attribution between the two legs is not
trustworthy from this run.

**Hypothesis 1 -- registering `ext_words` to cut the peek leg: INCONCLUSIVE.**
A throwaway probe measured 20.63 / 27.52 MHz on seeds 1-2 against a baseline of
25.10 / 25.30 on the same seeds -- worse on one, better on the other. That is the
documented netlist-variance floor, not a result, and three seeds cannot resolve
it. Reverted without concluding either way.

**Hypothesis 2 -- `xword(i,tot)` is identically `rawword(i)`: DISPROVED.**
It looked like a clean win: replace the normalised-`ext` reads with raw positional
reads and the dependency disappears for free. The 65,536-opcode sweep returned
**8,688 failures** immediately. The reason is in the function's own comment:
`tot` is the RAW-FIELD SUM (`ea_words_total`) while `ext` is normalised by the
DECODED `uop.ext_words`, and "several families report a count their own low six
bits do not imply". `xword` is a deliberate composition of the two, not a
positional accessor. Reverted; sweep clean again.

**What Stage 1 actually requires.** Not a patch. To remove the serial pass the
core's decoder must normalise `ext` itself from `ext_raw`, which means hoisting
the `ext_words` computation ahead of the main `always_comb` -- and that
computation currently depends on `uop.uclass`, `uop.subop` and the EA mode/size
that the same block produces. Done properly it pays twice: `u_peek` can then be
deleted outright, since the only reason two full decoders exist is that a shared
one would close the loop this normalisation creates. Two decoders become one.

That is a real refactor of the most intricate file in `rtlp/`, with
`tb/uop_decode_equiv_tb.sv` (all 65,536 opcodes, already comparing displacements)
and the Harte corpus as the net. It is the right Stage 1, but it is not the cheap
one this plan assumed.

### Stage 1, the measurement that changes the target: `ext_words` costs 24 ns

The `-noflatten` attribution left one doubt worth settling before refactoring
anything: Yosys cannot prune a module's unused outputs in that mode, and
`u_peek`'s only used output is `ext_words`, so its 50 attributed levels might
have been an artifact. New `tb/extw_probe.sv` + **`make fmax-extw`** settles it by
measuring that cone alone -- registers in, registers out, every other decoder
output pruned:

    seed 1: 41.70 MHz      seed 2: 45.37 MHz

**About 22-24 ns, for a 3-bit output that is a pure function of 16 opcode bits
plus a couple of extension bits.** The depth is real, not an artifact, and it
reframes Stage 1 completely:

* Fixing the serial pass alone is **not sufficient**. Even with the peek decoder
  taken off the critical path entirely, `ext_words` still has to be computed
  before the fetch unit can normalise `ext`, so this cone caps the whole design
  near **41-45 MHz** however the plumbing is rearranged. That is below the
  45-65 MHz that Stages 1-3 were estimated to reach, so it binds first.
* It is also the reason the serial pass is expensive in the first place: two
  passes hurt because each one is deep.

**Why it is deep, and what the fix is.** `uop.ext_words` is assigned at the END
of the main `always_comb`, from `uop.uclass`, `uop.subop` and the decoded EA
mode/size -- so the whole classification chain is in its cone, and it terminates
in a ~25-arm serial `? :` priority chain. A direct implementation would not need
any of that: group select from `instr[15:12]`, per-group counts computed in
parallel from the opcode's own bit-fields, one mux. That is plausibly 6-8 levels
against the present ~50.

This is the right Stage 1: a dedicated shallow `ext_words` decoder, with
`mh030p_decode` keeping its own copy as the oracle. It is bounded, additive, and
attacks the measured cost rather than the plumbing around it.

**The net: better than first stated, but pointed at the wrong oracle.**
A first pass over this claimed full-format counts were unverified. **That was
wrong** -- `tb/uop_decode_equiv_tb.sv` already had a dedicated full-format pass
driving three genuine full-format words (+0/+2/+4) across all 65,536 opcodes.
Corrected here rather than left standing.

What it did lack was asymmetric bd/od pairs and the base/index-suppress bits, so
the pass is now widened from 3 shapes to 8 (adds word-bd/null-od, long-bd/no-
indirect, word-bd/LONG-od, BS set, IS set). That took the reported disagreement
count to 18,115 over 438,648 comparisons.

**Those disagreements are not a bug list.** That pass is reporting-only because
it compares against the REFERENCE sequencer, and the reference is known wrong
here -- `m68030_seq.sv`'s `ext_count` miscounts MOVE with an indexed EA at both
ends in full format, which this very pass found. So the number says more about
the reference than about `mh030p_decode`.

**Which settles the oracle question for the rewrite**: a shallow `ext_words`
decoder must be checked against **`mh030p_decode`'s own `ext_words`**, not
against the reference. `mh030p_decode` is what passes Harte and the cosims, so it
is the trustworthy oracle for a like-for-like replacement, and the comparison is
exact rather than advisory. The 8 shapes above are what that comparison should
sweep.

**Order of work for Stage 1:**
1. DONE: sweep widened to 8 full-format shapes. Next, add a second
   `mh030p_decode` instance wired to the shallow decoder's inputs and compare
   `ext_words` exactly, across all 65,536 opcodes x all 8 shapes. Confirm the new
   check fails when the arithmetic is perturbed, not just that it passes.
2. Write the shallow `ext_words` decoder; iterate against `make fmax-extw`.
3. Swap `u_peek` to it; 9-seed `fmax-pbiu-sweep` + `make bench` + full gate.
4. Only then revisit the serial pass, which may no longer matter.

### Profiling the 24 ns: it is diffuse, and the chain is not the culprit

`make fmax-extw` makes the cone cheap to dissect. Driving the probe's output from
successively smaller pieces of the computation (seed 1 throughout):

| what the probe outputs | Fmax | delay |
|---|---|---|
| `uop.uclass` alone | 137.80 MHz | 7.3 ns |
| `src_ea_words` alone | 85.65 MHz | 11.7 ns |
| `imm_words` alone | 70.92 MHz | 14.1 ns |
| `ea_words_total` (src+dst+imm) | 66.07 MHz | 15.1 ns |
| a balanced `case (uop.uclass)` (throwaway, wrong values, right shape) | 49.43 MHz | 20.2 ns |
| **`uop.ext_words` as it stands** | **41.70 MHz** | **24.0 ns** |

**Three things follow, and two of them kill earlier plans in this file.**

**1. The ~25-arm priority chain is NOT the cost.** Replacing it with a balanced
one-hot `case` over `uop.uclass` -- the restructuring this file proposed, and the
one the decoder's own comment records as "measured slower ... UNRESOLVED" -- is
worth about **4 ns of the 17 ns gap**, taking 41.70 to 49.43. Now measured in
isolation rather than through full-design noise, so the codebase's open question
is answered: a case helps a little, and is nowhere near sufficient. Do not spend
Stage 1 on it.

**2. Classification is cheap; the word ARITHMETIC is not.** `uclass` costs 7.3 ns,
but `src_ea_words` alone already costs 11.7 and `imm_words` alone 14.1 -- and
`imm_words` is textually two muxes (`ea_is_imm ? (long?2:1) : (imm_takes_ext?2:0)`).
Its depth is therefore entirely in its PREDICATES, which are produced by the same
decode chain. The cost is spread across `ea_words()`'s per-mode counting
(including the full-format `ff_extra`/`ff_bd_words` reads), the immediate sizing,
the three-way sum, and finally the class select -- each layer adding a few ns.

**3. So `ext_words` cannot be fixed by restructuring; it has to be REPLACED.**
Getting 24 ns down to single digits means a genuinely independent minimal decoder
that computes the word count straight from opcode bit-fields in parallel, sharing
nothing with the main decode chain. That is the "dedicated shallow decoder" idea,
and it is now the only version of Stage 1 the measurements support.

**And the payoff has to be stated honestly before anyone starts it.** Even a
perfect `ext_words` at 100+ MHz leaves the BIU at 27.78 MHz and the A4
configuration's other paths where they are, so this unlocks roughly **25 -> 30-35
MHz**, not more. It is worth doing -- it is a real 24 ns structure on the critical
path, and every later stage is blocked behind it -- but it is one step of several,
and the diffuse profile above is the same "everything contributes a bit" shape the
whole-design measurements showed. That shape is what a 4x target is really up
against.

### Full-format addendum profiled (2026-10-02, resumed session)

The checkpoint's own queued measurement is done: isolate `ew_lead` / `ff_extra`
with the same drive-from-smaller-pieces technique already used for `uclass`/
`ea_words_total`/`imm_words`, by temporarily overriding `uop.ext_words` at the
very end of `mh030p_decode.sv`'s `always_comb` (after line 1780, the real last
writer) with each successively larger sub-expression, `make fmax-extw`, then
`git checkout --` to revert -- no RTL change is committed from this, it is a
read-only measurement using the existing permanent probe. Confirmed the
**reported figure is nextpnr's first "Info:" line**, not the later "Warning:"
line (a second, noisier number from the same run) -- reverting and re-running
reproduced the documented `41.70 MHz` baseline on the Info line exactly, so the
convention from the earlier table carries over cleanly. (The seed/run-to-run
noise on this tiny cone is real, roughly +-3 MHz -- single-seed numbers below,
not swept.)

| probe driven from | Fmax (Info line) | delay |
|---|---|---|
| `ew_lead` alone | 86.78 MHz | 11.53 ns |
| `ff_extra(ew_srcw)` (adds the source rawword mux + ff_extra) | 60.98 MHz | 16.40 ns |
| `ff_extra(ew_dstw)` (adds `ew_dst_at`'s add + dest rawword mux + ff_extra) | 54.84 MHz | 18.23 ns |
| `uop.ext_words` as it stands (both terms summed, real code) | 41.70 MHz | 24.0 ns |

**Three findings, one of them a real surprise:**

1. **The full-format addendum is genuinely serial, confirming the checkpoint's
   suspicion**: it adds 24.0 - 11.53 = **12.47 ns on top of `ew_lead`**, split
   roughly 4.9 ns (source rawword mux + `ff_extra`), 1.8 ns (dest offset add +
   rawword mux + `ff_extra`), and 5.75 ns for the final two-term merge back into
   `uop.ext_words` (a 3-way add: `ew_lead` + both `ff_extra` results). A shallow
   replacement cannot make this leg parallel with the brief count the way
   `uclass`/`src_ea_words`/`imm_words` are parallel with each other --
   `ew_srcw`/`ew_dstw` are selected BY the leading offset, so reading them has to
   wait for it, on real silicon as much as in this RTL.

2. **`ew_lead` is cheaper than the raw brief-chain pieces it's built from, and
   that is a real optimization opportunity, not noise.** `ew_lead = ext_words -
   src_ea_words - dst_ea_words` has to depend on the full ~25-arm brief
   priority chain (which alone measured 15.1 ns as `ea_words_total`, 14.1 ns as
   `imm_words`) PLUS a subtract-and-compare on top -- it should cost MORE than
   either, not less. Measuring 11.53 ns instead means Yosys/ABC9's boolean
   optimizer is algebraically cancelling most of the brief chain's complexity
   out of this particular subtraction (plausible: for most `uclass` arms,
   `ext_words` IS `src_ea_words + dst_ea_words + (something small)`, so the
   subtraction collapses toward that small remainder rather than needing the
   whole classification result). **This means a hand-written shallow `ew_lead`
   might already beat what a naive port of the formula would predict** -- worth
   confirming by writing it directly (not as a subtraction) and comparing, not
   assuming a 15 ns floor inherited from `ea_words_total`.

3. **The realistic target for a full shallow replacement is therefore
   two-part, not one number**: a brief leg that the earlier table already
   suggests can reach somewhere under 15 ns (finding 2 above suggests possibly
   less), plus a full-format addendum that is structurally serial after it and
   measures 12.47 ns in the current encoding -- so even a perfect brief leg
   still leaves the full-format addendum's own 3 serial steps (offset select,
   two rawword+ff_extra lookups, final merge) to shrink separately. Total
   realistic floor is closer to **15-18 ns (55-65 MHz)** than to the
   single-digit-ns ideal the checkpoint floated, unless the final merge
   (finding 1's 5.75 ns) can be restructured to run in parallel with the dest
   lookup rather than after it (dest's own `ff_extra` doesn't need the source
   term, only `ew_dst_at` does -- the source and dest `ff_extra` results could
   plausibly be summed independently and added to `ew_lead` in one 3-input
   adder instead of two serial 2-input adds; untried).

**Next step (not started): write the shallow decoder.** Order-of-work item 1
from the prior session (add a second `mh030p_decode` instance to
`tb/uop_decode_equiv_tb.sv`, wired to the shallow decoder's inputs, comparing
`ext_words` exactly across all 65,536 opcodes x the existing 8 full-format
shapes) still has to happen BEFORE or alongside writing the decoder, since it's
the correctness oracle -- the depth numbers above say what to beat, not that
it's safe to skip verification. Suggested order: (a) write the shallow brief
leg first (parallel per-group word counts from `instr[15:12]` and friends, no
subtraction-from-the-old-chain), wire it into the equivalence testbench
immediately and get it to 0 mismatches on brief-format opcodes before touching
full-format; (b) add the full-format addendum on top, verified against the
existing 8-shape sweep; (c) only once both are exact, swap `u_peek` to the new
decoder and re-run `make fmax-extw` + the 9-seed `fmax-pbiu-sweep` + `make
bench` + full gate (`make test`, `cosim_grp`, `cosim_memind`, `dat-synth`,
Harte).

**Do not re-derive what is already established**: `uclass` is cheap (7.3 ns);
a balanced `case` over `uclass` is a ~4 ns win and not sufficient; the EA-mode
and immediate-sizing ARITHMETIC is where the brief leg's cost concentrates;
the full-format addendum is a separate, serial 12.47 ns on top (new, this
session); the shallow decoder must be checked against `mh030p_decode`'s own
`ext_words` (not the reference `m68030_seq.sv`, a known-wrong oracle for
full-format counts); and the realistic payoff of fixing `ext_words` alone is
~25 -> 30-35 MHz, not more, because the BIU (27.78 MHz) and the rest of the A4
critical path are separate, still-unaddressed ceilings (Stage 2 / Stage 2b in
the "Decisions taken" section above).

**Also still open from "Decisions taken"**: the synchronous-termination fast path
(Stage 2b) needs the user's sign-off before implementation, since it spends the
"protocol-exact, timing-free" bus-fidelity decision -- flagged there, not yet
raised again since.

### Stage 1 shallow brief-format decoder: WRITTEN, 0 mismatches, 2.46x on the cone (same session, continued)

Wrote `ext_words_fast()`, a new function in `rtlp/mh030p_decode.sv`, implementing
the order from the previous section: the brief-format leg first, verified
immediately, full-format addendum deliberately NOT started yet (see below).

**What it is.** A direct transcription of the real decoder's per-group
if-elseif priority chain (same order, same guard wires -- `g0_is_ccr_sr`,
`g4_is_movem`, `g5_is_trapcc`, `g_is_bf`, etc. -- all already existing,
already-cheap, raw-opcode-bit wires computed well before the huge
classification `always_comb`), but computing a word count directly at each
branch instead of building a `uop_t`. It reads NO `uop.*` field anywhere --
that is the entire point, since the measured 24 ns cost is `uop.subop`/
`uop.siz`/`uop.opnd_word`/etc. being outputs of the ~1000-line classifier, and
avoiding them removes the forced serialisation after that classifier rather
than restructuring it. For every branch that is genuinely accepted (a real
instruction), the value is `ea_words_total` (also already cheap, a
raw-wire sum); accepted branches with a documented ext_words-chain special
case (MOVEP, STOP, LINK, CAS/CAS2, MOVEC, MOVEM, BITFIELD, CHK, TRAPcc,
DBcc, Bcc, SYSCTL's USP forms, the ALU/MULDIV immediate-size rules) keep
that exact special-cased value, derived by hand from the real chain
(`plan.md`'s own working notes, not reproduced here, walked every one of the
~45 branch sites in `rtlp/mh030p_decode.sv` to confirm which raw predicate
guards it and whether `ea_words_total` or a flat constant is correct there --
see the file's own inline comments on `ext_words_fast()` for the summary).
The fallback for "nothing in this group's if-elseif chain matched" (an
unclassified/illegal opcode, left at `UC_UNIMPL` with `ea_mode`/
`dst_ea_mode` at their `uop_clear()` default of `NONE`) is `imm_words +
dst_ea_words` -- deliberately excluding `src_ea_words`, mirroring the real
decoder's own "NONE/NONE catch-all" exactly, for the same reason: an
illegal opcode's raw mode/reg bits can coincidentally read as a real
address (confirmed this matters for `RESET`/`NOP`/`RTD`, whose shared
`sys_is_misc` raw mode field reads as `AN_IDX`, 1 word, even though none of
them have a real EA).

**Correctness: exact, immediately.** Exposed via a new module output,
`ext_words_fast_o` (named-port instantiations elsewhere are unaffected by
adding a port). Added a dedicated sweep to `tb/uop_decode_equiv_tb.sv` --
all 65,536 opcodes, held at the fixed brief-format `ext` pattern the main
sweep already uses (bit 8 clear, so the real `ext_words`'s full-format
addendum is always 0 and directly comparable) -- comparing
`ext_words_fast_o` against `uop.ext_words` for EVERY opcode, not just
claimed ones (the real decoder computes `ext_words` for `UC_UNIMPL` too, so
the fetch unit can drain correctly, and the shallow version has to match
that). First real run: **0 mismatches across all 65,536 opcodes**, on the
first attempt after fixing one Icarus-specific bug (below) -- the by-hand
branch-by-branch derivation held up completely under exhaustive sweep,
which is the strongest confirmation this project's own methodology
produces.

**One real toolchain bug found and fixed, not an RTL bug.** The first sweep
run reported `ext_words_fast_o` as `X` for literally every opcode. Root
cause, confirmed via a minimal standalone repro
(`sub` module, `function automatic` with no arguments reading a module port
directly, driven out via `assign y = f();`): Icarus mis-tracks sensitivity
for a continuous `assign` built from an automatic function that reads
enclosing-scope signals rather than its own arguments -- the repro's `y`
held its FIRST computed value forever and never re-evaluated when the
input changed (worse than stale: in the real file it read as pure X,
likely because the function's locals never get escaped the right side of
the implicit process entirely). Fixed by driving the port from
`always_comb ext_words_fast_o = ext_words_fast();` instead of `assign` --
confirmed correct in the same minimal repro (second version, `always_comb`
updates on every input change) before touching the real file. New
feedback memory worth keeping: an automatic SystemVerilog function with
implicit (non-parameter) reads of enclosing module signals needs
`always_comb`, not `assign`, to get correct Icarus sensitivity.

**Measured Fmax: 2.46x on the cone, now past 100 MHz for this cone alone.**
New `tb/extw_fast_probe.sv` + `make fmax-extw-fast` (identical wrapper shape
to the existing `tb/extw_probe.sv` / `make fmax-extw`, for a direct
before/after comparison on the same methodology). Three seeds:

| probe | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| real `ext_words` (baseline) | 41.91 MHz | -- | -- |
| `ext_words_fast_o` (new)    | 102.67 MHz | 107.19 MHz | 100.31 MHz |

~24.0 ns -> ~9.5 ns. This is well past the "15-18 ns / 55-65 MHz" floor the
previous session's profiling projected -- that projection was for the FULL
cone including the full-format addendum's own serial 12.47 ns; this number
is BRIEF-FORMAT ONLY (the addendum is not implemented in the shallow
version yet, see below), so the two numbers are not yet directly
comparable to each other, only each to its own predecessor.

**NOT swapped into `u_peek` or anywhere else production uses it.** This is
still deliberately scaffolding: `ext_words_fast_o` is read only by the new
equivalence-sweep check and the new fmax probe. Full mandatory gate run to
confirm the new port + function are inert everywhere else: `make test`
(43/43), `make lint-drivers` (clean), `make bench` (all four arms
reproduce their exact previously-recorded tick counts -- 23665/8929 for
`rtl/`, 24294/8603 for A4 -- confirming zero behavioural change to any
production path). Full Harte sweep for MH030-P (`make sim/harte_pvbatch`
+ `run_harte_batch.py --sim sim/harte_pvbatch`) CONFIRMED: `PASS 621799
FAIL 80345 SKIP 281221 TIMEOUT 576`, bit-identical to the recorded
baseline. Full mandatory gate clean.

### Stage 1 part 2 + swap-in (same session, continued)

**Full-format addendum: DONE, 0 mismatches.** `ea_mode_eff_fast()` /
`dst_ea_mode_eff_fast()` + a plain `always_comb` computing
`ext_words_fast_full_o` (brief leg plus the full-format extra words), all
from raw wires. A first version returned `ea_mode_w` unconditionally for
every non-MOVE group, which is wrong for families whose low 6 bits are not
an EA field at all (Bcc's displacement, MOVEQ's immediate, the shift
REGISTER form's count-source/op-select bits, `sys_is_misc`'s own fixed
`instr[5:3]==110` which reads as `AN_IDX`, and MOVEC's fixed
`instr[15:1]` pattern -- `0x4E7B`'s own `f_reg` reads as `PC_IDX`). The
equivalence sweep caught this immediately and precisely: 24,381 mismatches
concentrated in exactly those groups. Fixed by making every group's gate
explicit about whether it genuinely constrains the EA field. A second,
unrelated issue was a real Yosys limitation, not an RTL bug: a function
calling another automatic function two levels deep
(`ext_words_fast_full()` calling `ext_words_fast()` and
`ea_mode_eff_fast()`) made Yosys's `proc` pass fail with "Non-constant
expression in constant function" even though neither function has any
non-synthesizable content on its own. Fixed by flattening into a plain
`always_comb` that reuses the already-computed `ext_words_fast_o` signal
instead of calling `ext_words_fast()` a second time, keeping only
single-level function calls. **0 mismatches across all 65,536 opcodes x the
existing 8 full-format shapes**, checked for every opcode including
`UC_UNIMPL` ones.

**Measured: 1.19x on the complete cone, smaller than the brief leg's own
2.46x.** New `tb/extw_fast_full_probe.sv` + `make fmax-extw-fast-full`:
~49-50 MHz / ~20 ns across 3 seeds, vs the real `ext_words`' ~42 MHz /
24 ns. Smaller than the brief-only win because the full-format addendum is
genuinely serial after the brief count (confirmed last session) -- it has
to know where the extension word is before it can read it.

**Swapped into production**: `rtlp/mh030p_cpu.sv`'s `u_peek` now reads
`ext_words_fast_full_o` instead of `peek.ext_words` for both `have_all`'s
`if_avail` comparison and `drain`'s `mh030p_ifu` input, in place of the old
`peek.ext_words`/`peek` struct field, which is now otherwise completely
unread by this module (`peek`'s own full classification decode becomes
dead logic for synthesis to prune, which is the whole point -- the
expensive classification cone is no longer on this path at all). Full gate
clean: `make test` 43/43, `make lint-drivers` clean, `make bench`'s all
four arms reproduce their EXACT previously-recorded tick counts (zero
behavioural change), full Harte sweep for MH030-P CONFIRMED bit-identical
to baseline (`PASS 621799 FAIL 80345 SKIP 281221 TIMEOUT 576`).

**Design-wide A4 Fmax measurement: CONFIRMED, a real win.**
`make fmax-pbiu-sweep SEEDS=9`: **27.36 MHz mean (range 25.15-28.77)**,
every one of the 9 seeds individually above the prior baseline's own mean
(`24.71 MHz`, range 23.68-25.74) -- **+2.65 MHz / +10.7%**, clearly outside
the documented noise floor for this exact sweep
([[feedback_fmax_noise_floor]]: ~1-2 MHz at 9 seeds, and the explicit
warning that 8 prior RTL changes all measured ~1 MHz DOWN including two
that only deleted logic). A 3-seed first look (26.93 MHz) undersold it
slightly by catching two of the sweep's weaker seeds; the full 9-seed run
is the number to keep. This is now the largest confirmed Fmax win in the
100 MHz programme after the divider (5.8x) and the D/I-cache BRAM mapping
(+37%) -- comparable in relative size to the sequential shifter (+35%).

**Stage 1 is CLOSED.** Summary for whoever picks this up next: `ext_words`
was rewritten from scratch as `ext_words_fast_o`/`ext_words_fast_full_o` in
`rtlp/mh030p_decode.sv`, computed directly from raw opcode-bit wires rather
than from the ~1000-line classifier's own output fields, verified bit-exact
against the real decoder across all 65,536 opcodes and 8 full-format
shapes, swapped into `mh030p_cpu.sv`'s `u_peek` in place of
`peek.ext_words` (which is now dead code there, pruned by synthesis), and
measured at 27.36 MHz design-wide (A4 configuration) against a 24.71 MHz
baseline. Full mandatory gate clean throughout: `make test` 43/43,
`make lint-drivers` clean, `make bench` reproduces every arm's exact
tick count, full Harte sweep for MH030-P bit-identical to baseline
(`PASS 621799 FAIL 80345 SKIP 281221 TIMEOUT 576`).

`cosim_grp` (8/8), `cosim_memind` (33/33) and `dat-synth` (50/50) all
confirmed clean too, as expected since `rtl/` (what those exercise) was
never touched this session -- Stage 1 is fully, completely closed.

### Post-Stage-1 re-profiling: diffuse, no single dominator (same session, continued)

Re-ran the worst-path attribution the way every prior bounded fix in this
programme did it BEFORE touching any code: `make fmax-pbiu-sweep`'s own
9 `--report` JSONs (already on disk from the SEEDS=9 run above) analysed
with `scripts/measure_fmax.py analyze`, one per seed, checking which module
dominates each seed's own worst register-to-register path.

**`ext_words`/`u_peek` does not appear in ANY of the 9 seeds' worst paths.**
Stage 1 genuinely removed it from the critical path, not just from its own
isolated cone measurement.

**What dominates instead, across the 9 seeds:**

| seed | dominant module | share |
|---|---|---|
| 1 | `u_cpu.u_core` | 76.9% |
| 2 | `u_cpu.u_core` | 76.5% |
| 3 | `u_cpu.u_core` | 85.4% |
| 4 | `u_cpu.u_core` | 73.7% |
| 5 | `u_cpu.u_core` | 88.7% |
| 6 | `u_biu.u_cache` | 70.4% |
| 7 | `u_cpu.u_core` | 94.5% |
| 8 | `u_cpu.u_core` | 81.6% |
| 9 | `u_cpu.u_core` | 89.0% |

8 of 9 seeds: `mh030p_core.sv`'s own `u_core` dominates, with a smaller
detour through `u_biu.u_cache`/`u_biu.u_icache`'s data array in most of
those. 1 of 9 (seed 6): `u_biu.u_cache`'s own control logic dominates
instead, with `u_core` not appearing at all. This alternation between two
close-in-magnitude contributors, varying by P&R seed, is the same
"diffuse, no single dominator" shape this programme has seen once before
(the P0-era measurement: `u_seq` 26.0%/`u_cache` 22.7%/`u_md` 21.0%/
`u_icache.data_i` 18.0%) -- expected, since removing the single biggest
piece (`ext_words`) naturally brings the next-biggest contenders closer
together rather than leaving one clear new dominant item.

**Seed 7's full path (the cleanest: 2 module transitions, 94.5% `u_core`)
was traced to specific RTL, not just a module name.** The path's FIRST
register name (`ag_pc_...`) is reliable per this project's own naming rule
(ABC9 names a merged cell after its nearest traceable ancestor, and the
whole 59-hop chain carries that single name forward with no other register
appearing until the very end) -- `ag_pc` is a real register,
`rtlp/mh030p_core.sv:340`, the AG pipeline stage's own copy of the PC. The
path's LAST cell is `u_biu.u_cache.addr_r`, the D-cache's registered address
input. In between: `ag_pc2 = ag_pc + 2` (`:993`), a mux selecting
`ea_base` between zero/`ag_pc2`/`ag_b` depending on EA mode (`:1091-1095`),
`ag_ea = ea_base + ag_uop.ea_disp + ea_adj_idx` (`:1128`, ALREADY reduced
from 4 serial adds to 2 per that line's own comment), and a further mux
selecting `mem_addr` between `ag_c-4` (push/link)/`ag_b` (unlk)/`ag_ea`
(everything else) (`:1191-1193`). This is a genuine, already-partially-
optimized, single-cycle "compute the effective address and issue the bus
request" chain -- not an always-evaluating block with an unused result the
way the divider/shifter/cache-array wins were. [[feedback_sequentialise_always_evaluating_blocks]]'s
own lesson (local restructuring and area cuts fail; only removing/
sequentialising a genuinely avoidable always-evaluating block works) argues
against a speculative micro-optimisation attempt here without first
isolating this exact chain the way `tb/extw_probe.sv` isolated `ext_words`
-- that isolation has NOT been done yet for this chain.

**Two real directions from here, genuinely different in scope, and this is
a decision point like the ones this programme has hit before (Stage 2b's
synchronous-termination fast path, the original rewrite-vs-bounded-fixes
pivot):**

1. **Bounded, lower-risk**: build a dedicated isolated probe for the
   `ag_pc -> ag_ea -> mem_addr` chain (mirroring `tb/extw_probe.sv`'s
   technique) to get a real ns number for this cone alone, and separately
   investigate `u_biu.u_cache`'s own control-logic depth (seed 6's finding)
   the same way Phase A investigated `data_d`'s BRAM mapping. Either could
   plausibly yield another Phase-A-shaped win, but neither is confirmed
   fixable yet -- this is investigation, not a known lever.
2. **Bigger, higher-risk**: genuine pipelining of the AG/EX stage (splitting
   effective-address computation from bus-request issue across two cycles),
   which is the shape of fix that would structurally remove this chain
   rather than shrink it, but is explicitly the kind of change this
   programme has repeatedly deferred pending user sign-off (same category
   as Stage 2b and the original P1+ pipelining questions), because it
   changes the core's own cycle-timing behaviour, not just its gate count.

**Not started this session; no RTL changed since the Stage 1 swap-in
commit.** The 100 MHz target is still 3.65x away (27.36 vs 100); the BIU's
own standalone ceiling (27.78 MHz) is also still open and unrelated to
either direction above.

### MH030-P correctness pass (same session, redirected from Fmax)

The user asked, on seeing MH030-P's own Harte score (`PASS 621799 FAIL
80345 SKIP 281221 TIMEOUT 576` -- not `rtl/`'s `PASS 702142 FAIL 2`, a real
mix-up worth guarding against again), to pause the AG/EX pipelining plan
above and look at why MH030-P's correctness gap was so large. It turned
out to be three narrow, well-understood gaps plus one real independent bug
found along the way, not a deep architectural problem -- fixed in order of
measured impact, each verified with a full per-suite diff against the
immediately prior run (zero tolerance for silent regressions) plus `make
test`/`make lint-drivers`/`make bench` each time:

1. **ANDI/ORI/EORI #imm,CCR/SR (sub-op 6) was decoded but never executed at
   all** -- `dec_sysctl_ok` explicitly excluded it (a documented, not
   accidental, scope decision) and EX had no execution path for it.
   Decoder fix: `uop.alu_op = g0_alu_op` (reusing the already-correct
   OR/AND/EOR mapping) and `uop.siz` repurposed as the CCR(byte)/SR(word)
   selector, matching real silicon's own encoding. Core fix: widened
   `dec_sysctl_ok`, added `sys_logic_result` wired into the existing
   direct-write `ccr_r`/`sr_sys_r` branches. **~41,000 of the 80,345
   failures**, all 6 target suites (ANDItoCCR/SR, ORItoCCR/SR,
   EORItoCCR/SR) to 100%. `PASS 621799->661875`.

2. **MOVE <ea>,CCR/SR (sub-op 2/3) with a memory SOURCE** -- decoder already
   set `reads_mem`/`src_kind=US_MEM` correctly, but `dec_sysctl_ok`
   blanket-excluded any `reads_mem` instruction. Unlike (3) below, a read
   has no timing problem (the ordinary `ex_wait_mem`/`mem_hold` mechanism
   already covers it) -- widened the gate for sub-op 2/3 specifically, and
   replaced `sys_wr_val`'s hand-rolled immediate/register fallback with
   `ex_src_raw`, the core's own already-correct general-purpose operand mux.
   **+6,679**, MOVEtoCCR/SR to 100% on their runnable vectors.
   `PASS 661875->668554`.

3. **Scc,\<ea\> and MOVE SR/CCR,\<ea\> (sub-op 0/1) with a memory
   DESTINATION** -- the harder one: the write VALUE depends on
   `cond_true`/`sr_sys_r`/`ccr_live`, none of which are known until EX, but
   every "pure write" instruction's bus request dispatches the same cycle
   it leaves AG, straight from AG-only registers -- one cycle too early.
   Fix: excluded both (`ag_is_scc_mem`/`ag_is_sys_wr_mem`) from AG's
   immediate `mem_req` dispatch, added a one-shot EX-resident write branch
   (`scc_sys_wr_issued`, mirroring the existing RMW write-turnaround's own
   shape) that fires once the value has settled; the address itself needed
   no deferral since `ag_ea` doesn't depend on either. Two Icarus
   declaration-order fixes needed along the way (a shared
   `ex_needs_scc_sys_wr` wire hoisted above the `always_ff` that uses it;
   the write data computed directly from `sr_sys_r`/`ccr_live`/`cond_true`
   rather than reusing `sys_rd_val`, whose `ex_b_u` dependency is declared
   later in the file and isn't needed for a memory destination anyway).

   **This surfaced a real, independent, pre-existing bug**: `ag_an_upd`
   (the autoincrement/predecrement same-cycle register-file commit) never
   checked `!redirect`. A speculatively-fetched instruction sitting in AG
   can be squashed by a branch/jump/return resolving in EX the very same
   cycle, but `ag_an_upd` is a same-cycle combinational bypass -- clearing
   `ag_valid` for the NEXT cycle doesn't undo a commit that already
   happened THIS cycle. Latent until this session: a ghost opcode decoding
   as Scc/MOVE-SR,\<ea\> with an autoincrement EA was previously just
   declined (`dec_executable=0`, so `ag_valid` was already 0), never
   reaching this wire. Making those two instructions executable exposed it
   as a regression in exactly the redirect-causing families
   (Bcc/BSR/JMP/JSR/RTE/RTR/RTS) -- and fixing it with `&& !redirect`
   turned out to fix a LARGE pre-existing bug in its own right: Bcc, BSR,
   JMP, RTE, RTR, RTS all go from long-standing non-zero fail counts to
   100% on their runnable vectors, and JSR improves substantially (729->526
   fail; its own remaining 275 timeouts are separate and pre-existing).
   **+2,290** net (Scc/MOVEfromSR fixed, several redirect-family suites
   fixed outright). `PASS 668554->677979`, **FAIL 33590->24165**.

   One honestly-reported, NOT newly introduced caveat: BTST already had 561
   failing/timing-out vectors before this session touched anything (its own
   separate, undocumented, PC-relative-addressing-shaped bug -- register
   corruption patterns like `D6: got 0x584d0079, exp 0x584d798b`, upper
   16 bits matching, lower 16 wrong, suggesting a sizing issue specific to
   that family, unrelated to any of today's fixes). After these fixes the
   count is 282 fail (was 281) -- a 1-vector shift within an
   already-broken population confirmed to still be dominated by that same
   separate pattern, not a new independent failure mode. Left for BTST's
   own dedicated investigation rather than chased here.

**Net for the session: `PASS 621799->677979` (+56,180), `FAIL 80345->24165`
(-70%)**, `SKIP 281221` and `TIMEOUT 576` unchanged throughout (every fix
was additive -- previously-declined instructions becoming executable,
never previously-passing ones breaking, confirmed by a full per-suite diff
after every single commit).

**Next biggest remaining groups, not yet investigated** (fresh per-suite
breakdown after the `ag_an_upd` fix):

| suite(s) | fail+timeout | notes |
|---|---|---|
| MOVEM.w / MOVEM.l | ~6,111 + 1 | not yet looked at this session |
| ASR/ASL/LSL/LSR/ROL/ROR/ROXL/ROXR (word forms esp., byte forms too) | ~11,500 | **two distinct symptoms found, not yet root-caused**: register-destination forms fail on CCR only (X/C flags specifically look wrong -- `got 0x19 exp 0x08`, i.e. X and C both spuriously set, N/Z/V correct) with the shift RESULT itself correct; memory-destination forms write `0x00 0x00` (as if the shift never ran, or ran enough times to flush to zero) instead of the real shifted value -- likely two separate bugs sharing a `UU_SHF`/sizing-adjacent cause, needs its own `--verbose` investigation per form before touching code |
| TAS | 1,195 | not yet looked at |
| LINK | 1,005 | not yet looked at |
| PEA | 851 | not yet looked at |
| JSR (275) / BTST (279) / CHK (21) | timeouts | pre-existing, separate from this session's fixes; JSR's own FAIL count did improve via the `ag_an_upd` fix, its TIMEOUT count did not |

**Whoever picks this up next should keep using the same methodology**:
`python3 scripts/run_harte_batch.py tests/harte/SUITE.json.gz --sim
sim/harte_pvbatch -j 1 --chunk-size 300 --verbose` to see real got/exp
diffs before guessing at a fix, and a full per-suite diff (see this
session's own throwaway Python snippets, not preserved as a script but
trivial to redo against two `run_harte_batch.py` log files) after every
change, no exceptions -- that discipline is what caught the `ag_an_upd`
regression immediately instead of it shipping silently.

### MH030-P correctness pass CLOSED (a later session, continuing from the table above)

Worked the remaining table top-to-bottom, biggest group first, same
methodology, one commit per fix with a full per-suite diff + `make
test`/`make lint-drivers`/`make bench` gate every time. **Final result:
`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0` -- bit-identical to `rtl/`'s own
score**, including the same 2 permanently-unfixable ASL.b corpus-data
vectors (Phase 87, confirmed a Tom Harte corpus error, not an RTL bug).
Closes this section's own standing user instruction ("continue to improve
until the new code matches the old code") in full.

**TAS Dn (1,195 fail -> 0)**: register-direct TAS (0x4AC0-0x4AC7) fell
through undecoded entirely -- `g4_is_tas` required real memory and the
generic Dn-ALU fallback never matched it either (its own `b76=11` fails
`f_ss_valid`). New `g4_is_tas_dn` decode branch; widened `dec_executable`'s
TAS/CAS clause to accept `dst_kind==US_DREG` as an alternative to
`dec_ea_ok`; fixed `tas_orig`/`tas_res` to read/preserve `ex_b_u`/`ex_dst`
instead of `mem_hold`/zeroing the upper 24 bits (there is no memory read to
hold for a register destination).

**LINK A7 (1,005 -> 0)**: LINK An pushes the OLD An value, except when
An IS A7 itself, where real silicon pushes the STACK POINTER AFTER its own
decrement (a documented 68k quirk) -- the decoder's `mem_wdata` mux used
`ag_b` (the pre-decrement value) unconditionally. Fixed with a
`dst_reg==4'd15` special case pushing `ag_c-4` instead (the same value
already computed for the new SP).

**PEA/JSR indexed EA (851 + 526/275 timeout -> 0)**: a push (PEA/JSR)
always forces the register file's C port to read A7 for `-(A7)`, which
collided with an INDEXED EA's own need for the C port to read its index
register -- for `(d8,An,Xn)` this made the instruction silently
undispatchable (decode's own `dec_ea_class_ok` explicitly excluded it);
for `(d8,PC,Xn)` it dispatched but read A7's value as the index, producing
a wrong address. Fixed by routing a push's own index register through the
otherwise-unused A port instead of C (A is never touched by a push's write
data), mirrored across `dec_push_idx`/`ag_push_idx`/`ag_xn_src` the way
every other `_sel` pair in this file must agree.

**Leading-extension-word bug class (BTST/BCHG/BCLR/BSET 1,126 fail + 279
timeout -> 0, then the group-0 ALU-immediate family -- EOR/CMP/AND/OR/SUB/
ADD .b and .w, 918 fail -> 0, then MOVE's own immediate source -- MOVE.b/w
113 fail -> 0)**: found and fixed independently three times before the
shape was recognized and named -- see
`~/.claude/projects/-Users-malcolm-MH030/memory/feedback_leading_extension_word_bug_class.md`.
A plain `uop.imm = ext` read smears a LEADING bit-number/immediate word
together with a DIFFERENT, later extension word the destination's own EA
needs, because `ext`'s two halves swap which physical half holds "word 0"
depending on total word count. Fixed throughout with the already-existing
`xword(0, tot)`/`xword(1, tot)` position-aware helpers. The dynamic/static
BTST forms also needed genuinely NEW decode branches for PC-relative and
immediate EA (the one bit op of the four legal there, since it's
read-only) -- previously entirely undecoded, silently skipped as an
unexecutable bubble (confirmed via a direct Icarus trace: no bus cycle, no
register write, PC just advances past it).

**The `rtlp`-specific "fast" shallow EA-mode/ext_words predictor**
(`ext_words_fast()`/`ea_mode_eff_fast()`, used by `mh030p_cpu.sv`'s
`u_peek` to lay out the IFU's raw `ext` register AHEAD of the real decode)
had no matching branches for the newly-added BTST PC-relative/immediate
cases -- it silently fell through to a 0-word guess, so the IFU arranged
`ext` assuming the wrong total and the real decoder then read the wrong
physical half even with its own `ext_words` count correct. This is what
actually fixed the PC-relative forms' wrong effective address; the decode
branch alone wasn't sufficient. Added matching branches to both functions.

**PC-relative base needs a per-family lead adjustment (part of the BTST
fix above, then separately for MOVEM)**: `ag_pc2` (PC+2) is only the right
base when the displacement is the FIRST extension word. A leading
bit-number or mask word pushes it to PC+4. New `ag_pc_lead` term (+2 for
UC_BITOP subop==1, later widened to UC_MOVEM) added to `ea_base`'s
PC-relative arm.

**MOVEM.w/.l (100 + 107/1 timeout -> 0)**: two bugs. (1) The SAME
PC-relative lead-word bug as BTST -- this is what the PRIOR session's own
"transfer N gets transfer N-1's data" symptom actually was (every transfer
read one word short, which looks exactly like an off-by-one in the
mask/stepping logic even though that logic was already correct, as the
prior session's own exhaustive check found). (2) A genuinely separate
hang: MOVEM with an all-clear register mask (0x0000, "transfer nothing")
dispatches zero bus cycles, so `ex_wait_mem`'s generic `mem_got` gate
never sets and stays true forever even after MOVEM's own `mvm_done` state
machine correctly finishes. Every nonzero mask masked this (mem_got
latches on the first real transfer and nothing clears it mid-instruction).
Fixed by excluding `UC_MOVEM` from `ex_wait_mem` entirely -- it already
manages its own sequencing via `mvm_done`.

**The abs.L + long-immediate 4-word gap (EOR/OR/AND/SUB/CMP/ADD .l, 25
fail -> 0)**: a documented, not newly-discovered, structural limit --
`xword`/`rawword` only reached 3 extension words (`ext`'s two halves plus
`q3`), but a long immediate (2 words) feeding an absolute-long EA (2 more)
needs 4. The IFU's own prefetch queue is already 8 deep; `q4` (`=q[4]`)
was simply never exposed as a decoder input. Threaded a new `q4` port
through `mh030p_ifu.sv` -> `mh030p_cpu.sv` -> `mh030p_core.sv` ->
`mh030p_decode.sv`, extended both word-access helpers with a 4th case, and
widened `ea_disp_valid` from `<=3` to `<=4`. Every other `mh030p_decode`
instantiation (3 Fmax probes, the standalone core testbench, the
65536-opcode equivalence sweep) needed the new required port wired too.

**MOVE mem-to-mem index self-hazard (18 of MOVE.b's own remaining 76 ->
0)**: a genuine operand-evaluation-order hazard, not a decode bug --
when a memory-to-memory MOVE's destination index register (Xn) happens to
BE the source's own auto-incrementing register ((An)+/-(An)), real 68k
silicon fully evaluates the source (including its own step) before
reading Xn for the destination. This core's index-register read (`ag_d`)
lands in the same AG cycle as the step itself, before the step's own
same-cycle commit reaches the register file, so it read the PRE-step
value -- one byte/word short. Fixed with a narrow bypass
(`ag_dst_idx_is_src_an`) reusing `ag_an_val` (already computed
combinationally for the commit path) in place of the raw port-D read when
this specific register coincidence applies.

**CHK #imm,Dn (21 timeout -> 0, the very last gap)**: not a wrong value --
`uop.imm` was never assigned AT ALL for the immediate-bound form, despite
`src_kind` correctly saying `US_IMM`. The bound was always 0, causing far
more traps than real hardware and apparently landing every affected vector
in an exception-sequencing state this core doesn't cleanly recover from.
Fixed by adding the missing `uop.imm = ext` (safe as a plain read here,
unlike the leading-word cases above, because CHK's own EA field IS the
immediate when `ea_is_imm` -- there is no second, separate EA concurrently
consuming words to collide with).

**Final gate, same as every fix above**: `make test` 43/43 (`uop_equiv`
clean throughout, including after the `q4` port addition), `make
lint-drivers` clean, full 124-suite Harte sweep `PASS 702142 FAIL 2
SKIP 281221 TIMEOUT 0`, `make bench` all four arms' `EXECCYCLES`/D0-checks
unchanged throughout (none of these fixes touch dispatch timing for
previously-working instruction shapes). **This closes the correctness
pass. The Fmax/100MHz programme is unaffected and remains paused exactly
where the pivot session left it** -- see
`project_mh030_pipelined_rewrite_planning.md`'s own "Session checkpoint"
pointer if that work resumes.

### AG/EX EA-adder split (a later session, resuming the Fmax programme from
the checkpoint above, `~/.claude/plans/golden-puzzling-music.md`, IMPLEMENTED
AND MEASURED)

Executed the plan the prior section's own decision point proposed as
direction 1 (bounded) plus the structural half of direction 2, via the
surgical cut the plan itself designed: rather than a true new AG1/AG2
pipeline-register pair (which would have needed promoting the
`ag_base_busy` interlock to look two stages ahead -- the plan's own
identified highest-risk spot), the EA adder (`ea_base`/`ag_ea`) and the
`mem_addr`/`mem_req`/`mem_rw`/`mem_siz`/`mem_wdata` dispatch logic moved
OUT of AG's single cycle and INTO a new, one-shot-gated cycle inside EX,
reading `ex_b`/`ex_sp`/`ex_a`/the new `ex_pc2` pass-through register --
registers the existing AG->EX transfer already carries unconditionally, so
the hazard-sensitive forwarding network and its interlock never moved and
never needed to become 3-level.

**Phase 0 (measurement-only, zero RTL change) confirmed the plan's own
"real, open risk" did not block proceeding**: three isolated probes
(`tb/ag_ea_probe_full.sv`/`_pcrel.sv`/`_fwd.sv`, `make fmax-ag-ea-full`/
`-pcrel`/`-fwd`) measured the full existing EA cone at 46.88 MHz, the
PC-relative-only sub-case (no forwarding mux in that path at all) at
300.03 MHz, and the forwarding-plus-indexed sub-case separately -- (b)
being nowhere near (a)'s ceiling meant the cut was worth making.

**Phase 1 simplified the plan's own design in one place**: the plan
proposed excluding MOVEM/MOVEP from the new `ex_needs_ea` gate (reasoning
they build their own address differently and shouldn't wait on a generic
EA phase). Direct code inspection before writing any RTL found this
reasoning stale -- both the MOVEM and MOVEP standalone sequencer FSMs read
`ex_ea` directly in their own seed branches, with NO existing `ea_done`-
equivalent gating at all, so the exclusion was dropped and both FSMs
instead got `&& ea_done` added to their own `!mvm_run`/`!mvp_run` seed
conditions -- caught by inspection, before it could become a second
build's worth of a failing-test surprise. A third, same-shape bug was
found the same way in `scc_sys_wr_issued` (the Phase-280-session tracker
for Scc/MOVE-SR-CCR's own deferred memory-destination write): its own set
condition fired on `ex_needs_scc_sys_wr` alone, one cycle before `ea_done`,
causing the real dispatch branch's `!scc_sys_wr_issued` guard to already be
false once `ex_ea` was actually ready -- this one WAS caught by the
mandatory full Harte sweep (2 regressed suites, MOVEfromSR/Scc, diffed
against baseline) rather than by inspection, fixed with the same
`&& ea_done` qualifier.

**A fourth, genuinely independent, pre-existing bug was found via `make
bench`'s `cosim_p_bench1` arm -- the one gate in this whole programme that
actually executes a real multi-instruction program rather than one
instruction in isolation, and the only reason this was ever caught.**
`tests/bench1.s`'s fill-to-copy loop boundary (`moveq #0,d1` immediately
followed by a post-incrementing memory instruction) hung indefinitely.
Root cause, confirmed by first reproducing it against the UNMODIFIED
baseline (`git stash`, confirming the identical hang pre-existed this
session's own change entirely -- not a regression this split introduced):
`rtlp/mh030p_core.sv`'s single first write port (`wb_wr_en`/`wb_wr_sel`/
`wb_wr_data`) was a priority MUX across FIVE different sources --
`ag_an_upd` (AG's own same-cycle autoincrement bypass), the ordinary
`wb_valid&&wb_writes` commit, `mvm_reg_wr`, `mvm_base_commit`, and
`exc_commit_sp`/`rst_commit_sp` -- on the stated assumption (the comment
at the mux's own original site) that "nothing in this phase's subset both
updates An and commits an ALU result in the same cycle." That assumption
covered a single instruction doing both; it never accounted for TWO
DIFFERENT, adjacent instructions each needing the port on the same cycle
-- `ag_an_upd` is the AG-stage instruction entering/advancing, the other
arms are the EX-stage instruction one stage further along retiring -- which
is routine, not exceptional, whenever a retiring register-only instruction
(MOVEQ) is immediately followed by a post/pre-incrementing memory
instruction (the mem2mem MOVE in `bench1.s`'s own copy loop). Whichever arm
the mux picked silently discarded every other arm's write that cycle:
MOVEQ's own `D1=0` commit lost the regfile ARRAY write (though the 2-level
forwarding network, which bypasses the array entirely, still carried the
correct value to the immediately-following instruction -- masking the bug
for one more instruction before the loop's SECOND iteration read the
STALE, pre-loop array value once forwarding aged out, which is why the
failure looked like a loop that never terminates rather than one wrong
value). **Fixed with a genuine third write port**
(`wr3_en`/`wr3_sel`/`wr3_data` in `rtlp/mh030p_regfile.sv`), dedicated
exclusively to `ag_an_upd`, mirroring the existing second port's own
precedent (and its own stated willingness to spend a port + one more
register against this project's ~74,000 spare flip-flops rather than cost
a stall). A genuine same-register collision between this port and ports
1/2 remains structurally impossible: `ag_base_busy` already interlocks AG
against both other ports' targets whenever AG needs a register `ag_an_upd`
would also write, so priority among the three ports on a real collision is
moot by construction. `sp_live`/`sp_shadow` (A7's own write-first bypass,
outside the regfile) needed the identical third clause added. Hit the same
Icarus forward-reference-before-declaration quirk this project has hit
before (`ag_an_upd`/`ag_an_val` are declared ~250 lines after the u_rf
instantiation and `sp_live`) -- solved the same way as the existing
`wb_wr_en`/`wb_wr_sel`/`wb_wr_data` precedent: pre-declare plain
`wr3_en`/`wr3_sel`/`wr3_data` wires early, connect those, drive them via a
continuous `assign` placed near `ag_an_upd`'s own declaration.

**`tb/mh030p_core_tb.sv`** needed 6 `bubble(N)` call sites bumped by +2
cycles each -- the new one-cycle EA-dispatch latency on the LAST
memory-referencing instruction before each fixed-delay `chk()` block,
confirmed via a real regression (not guessed) before being accepted.

**Full gate, all clean**: `make test` 43/43, `make lint-drivers` clean,
full 124-suite Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2
SKIP 281221 TIMEOUT 0`, confirmed via the real re-run, not assumed), `make
bench` all four arms passing: `rtl/` 23665/8929 (untouched, as expected --
this session touched only `rtlp/`), `rtlp` abstract-bus 6617 (was 6616,
+1 -- NOT +1-per-memory-op as a naive reading of the plan's own Phase 1
step 6 note might suggest; most of bench1's existing memory-wait stalls
already absorb the new 1-cycle EA latency, so it surfaces only where
zero-gap back-to-back dispatch previously fully hid it), A4 caches-off
24294 (UNCHANGED from baseline -- this workload is bus-latency-bound, ~16
ticks/access, so the 1-cycle front-end shift is completely absorbed and
never reaches the critical path, resolving a prior session's own
"suspicious, not yet investigated" note about this exact number), A4
caches-on 8751 (was 8603, +148 -- with caches on, far fewer, mostly
back-to-back accesses, so the added latency is far less hidden and shows
up directly, as expected).

**Fmax re-measurement: a real structural win, but NOT a measurable mean
improvement -- report both halves honestly.** `make fmax-pbiu-sweep
SEEDS=9`: **27.25 MHz mean (range 25.10-29.33)** against the 27.36 MHz
baseline (range 25.15-28.77) -- effectively flat, well inside
[[feedback_fmax_noise_floor]]'s own documented ~1-2 MHz noise floor for
this exact sweep.

**CORRECTION (same session, a later pass): the module-attribution
conclusion drawn from that sweep was WRONG, and the error is itself an
important, generalizable finding -- see
[[feedback_flattened_attribution_needs_noflatten_crosscheck]].** The
first pass re-profiled the 9 `--report` JSONs from the FLATTENED sweep
above with `scripts/measure_fmax.py analyze` and concluded `u_cpu.u_core`
no longer dominates any seed, with the worst path attributed entirely to
`u_dut.u_biu.u_cache`/`data_d`/`u_icache.data_i`. **This did not survive a
`-noflatten` cross-check.** `make fmax-pbiu-noflat SEED=4` and `SEED=1`
(module boundaries genuinely trustworthy there, unlike the flattened
build) both show the SAME, completely different worst path: `u_cpu.u_ifu`
(clk-to-q on `instr`) -> `u_cpu.u_peek` (44-46 hops, **19.11-19.12 ns,
44.7-44.9% of the ~42.6 ns total, consistent to two decimal places across
both independent seeds**) -> back through `u_cpu.u_ifu` -> `u_core.u_dec`
-> `u_core` -> `u_core.u_rf` (setup on `rd_a_data`). `u_biu.u_cache` does
not appear in either noflat seed's worst path at all. The flattened
build's own "no u_core" conclusion was real in one narrow sense (ABC9's
nearest-surviving-ancestor naming genuinely doesn't call the dominant
cells `u_core` in that build) but the inference drawn from it --
"therefore the bottleneck moved to the cache" -- was false; the true
dominant contributor (`u_peek`) was simply attributed to the wrong module
name by the flattening, the same failure mode already documented once
for `mh030p_mul`'s DSPs (named `u_ifu.req_epoch_*`) but not previously
known to extend to ordinary module-prefix "module walk" attribution, only
to single-cell naming. **Do not trust a flattened sweep's module
attribution for a NEW conclusion without a `-noflatten` cross-check on at
least one seed first** -- this is now a standing requirement for this
programme, not just a one-off caveat.

**The real finding is not new, and is not actionable without a different
kind of fix.** `mh030p_cpu.sv`'s own header comment (lines 73-91,
predating this session) already documents exactly this chain: `u_peek`
(a full `mh030p_decode` instance, kept alive solely to produce
`ext_words_fast_full_o`/Stage 1's own rewrite) must settle before
`u_ifu`'s `drain`/`have_all` can decide how many words the real decode
(`u_core.u_dec`) gets to see this cycle, which gates the regfile's own
read-address mux one hop further on -- all serial within one clock
period. The measured 19.11-19.12 ns matches Stage 1's own already-
published isolated-cone number for the COMPLETE/full-format case almost
exactly (CLAUDE.md's Stage 1 writeup: "~49-50 MHz/~20 ns (complete, with
the full-format addendum, 1.19x -- smaller because that addendum is
genuinely serial after the brief count)"). Stage 1 already concluded this
remaining cost is "genuinely serial" and did not promise to remove it
from the critical path, only to make the computation itself cheaper (it
did: from the old two-full-decoder-pass shape, 78% of the path/151 of 179
hops, down to this). **This is Stage 1's own known, already-quantified
floor showing up end-to-end, not a new bottleneck** -- the "u_core no
longer dominates" claim is retracted; `u_peek`'s cost was there all
along, just mis-attributed. The 100 MHz target is 4.28x away at the real,
noflat-measured ~23.4 MHz for this specific build (SEED=4/1 noflat
numbers; the flattened 27.25 MHz mean remains the tracked sweep metric
since `-noflatten` is not the standard measurement recipe, only a
cross-check). **No new probe was built and no RTL change is proposed from
this investigation** -- shrinking `ext_words_fast_full_o` further, or
breaking its same-cycle serial dependency on `u_ifu`'s own drain decision
(e.g. by computing it a cycle ahead against an already-buffered
prefetch-queue word, genuinely retiming rather than just cheapening the
arithmetic), is a materially different kind of change than Stage 1's own
shallow-decoder rewrite and has not been scoped.

### MH030-P Stage 1 decoder merge IMPLEMENTED and MEASURED (2026-10-04, commit `e06c722`)

Resumes the staged 100 MHz plan from the 2026-09-28 checkpoint above, per
the user's explicit instruction after reframing 100 MHz as the real target
(not a stretch goal -- see `docs/mh030p_architecture.md` section 2):
"start phase 1 then move to 2 and 3. after each stage, test, measure and
commit." Full writeup lives in `docs/mh030p_architecture.md` sections 4.2,
7.1 and 8; this entry is the dated pointer.

**Implemented as scoped**: deleted `mh030p_cpu.sv`'s own `u_peek`
`mh030p_decode` instance (which existed solely to compute `ext_words` one
cycle ahead of the real decoder -- two full decoder passes per clock).
`mh030p_decode.sv` now computes `ext_words_fast_full_o` first and
normalises its own `ext` internally from it, so the module needs no
external `ext` input at all. `mh030p_core.sv` exposes `u_dec`'s own
`ext_words_fast_full_o` as a new output (`dec_ext_words_o`) so
`mh030p_cpu.sv` can still compute `have_all`/`drain` without a second
decoder instance -- not a combinational loop, since that signal depends
only on `instr`/`ext_raw`/`q3`/`q4`, never on `instr_valid`.

**Two real, previously-latent decode bugs found and fixed**, exposed by
the merge once a testbench inconsistency (`tb/uop_decode_equiv_tb.sv`
feeding `u_new` and the reference decoder two DIFFERENT un-normalised
`ext` values that happened to agree by coincidence before the merge) was
itself fixed: MOVES direction (`ext[11]`) was never checked --
`writes_reg` was hardcoded to 1 unconditionally, so a store-direction
MOVES (Rn->ea) was mis-reported as writing a register; and bit-field's own
register-field read the full `ext[15:12]` (4 bits, bleeding in bit 15 as
if it were a MOVEC/MOVES-style D/A selector, a wrong generalisation this
file's own header comment had asserted) instead of the Dn-only 3-bit field
the reference always uses. A third, separate, pre-existing gap (UC_MMU's
own sub-opcode validity never checked against the extension word) was
found, documented, and excluded from the equivalence sweep rather than
fixed, since it is unrelated to the merge and its own scope.

**Full gate clean**: `make test` 43/43, `make lint-drivers` clean,
`tb/uop_decode_equiv_tb.sv` 0 mismatches, full 124-suite Harte sweep
bit-identical to baseline (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`),
`make bench` all four arms with `EXECCYCLES` byte-identical to before
(23665/8929/6617/24294/8751) -- confirming zero behavioural change.

**Measured: 26.49 MHz mean (9 seeds, range 24.88-27.50), flat to slightly
down versus the 27.25 MHz pre-Stage-1 baseline.** This is NOT the ~28 MHz
the 2026-09-28 estimate predicted, and a `-noflatten` cross-check (2
seeds, consistent: 23.57/23.65 MHz) shows why: the two-decoder chain is
genuinely gone from the critical path, exactly as designed, but **the
reused BIU did not become the new binding constraint the way the
2026-09-28 plan expected.** The real worst path is now entirely internal
to `u_cpu.u_core`: `instr_ready` (the AG/EX stall-gating decision) →
`u_core.u_alu` → `mem_addr` (the registered bus-dispatch address), 65
hops, ~83-84% attributed to `u_core` across both seeds. This points at
Stage 3's own territory (core-side AG/EX/CCR pipelining), not Stage 2 (the
BIU) -- a real, measured contradiction of the earlier plan's own
sequencing rationale, recorded here rather than silently overridden.

**Proceeding to Stage 2 next regardless**, per the user's own explicit,
already-given sequencing instruction, not because fresh measurement
currently points at the BIU -- forking the BIU is still necessary,
already-decided work that Stage 2b and any future BIU-side fix depend on,
so it is not wasted even though it will not move the tracked Fmax number
until the core-internal chain found here is also addressed. See
`docs/mh030p_architecture.md` section 8 for the full staging note.

### MH030-P Stage 2 fork DONE; Stage 2/3 re-ordered by user decision (2026-10-04)

Forked the BIU into `rtlp/` (`rtlp/mh030p_biu.sv` + `rtlp/mh030p_biu_cycle_gen.sv`,
`rtl/m68030_biu.sv`/`biu_cycle_gen.sv` completely untouched, every other
submodule reused unforked) -- commit `934b052`. Verified behaviourally
identical: `make test` 43/43, `make lint-drivers` clean, `make bench` all
four arms with `EXECCYCLES` byte-identical.

Before starting the actual FSM depth restructuring (the reason for the
fork), flagged to the user that the prior commit's own measurement
(`instr_ready`→`u_alu`→`mem_addr`, entirely inside `u_core`, dominant
across 2 `-noflatten` seeds) means the BIU is not currently the binding
constraint -- its own 27.78 MHz standalone ceiling is already above the
26.49 MHz full design. Restructuring `biu_cycle_gen`'s 117-state FSM
encoding now would be real regression risk on the most protocol-critical
file in the project for a currently-unmeasurable payoff.

**User decision: do Stage 3 (core pipelining) next, defer the FSM
rewrite until Stage 3's own re-measurement confirms the BIU has become
the limiter.** `docs/mh030p_architecture.md` section 8 updated to record
this re-ordering. The fork stays in place either way. See the "Stage 3"
section there for the specific target (`instr_ready`'s own stall-gating
tree, the unexpected `u_alu` detour needing its own trace before a split
is designed).

### MH030-P Stage 3 first fix: CAS compare latched, measured +Fmax, u_alu confirmed off critical path (2026-10-04)

Root cause (found via direct `-noflatten` trace after Stage 1): `cas_eq =
alu_z` (CAS's own live ALU-derived compare result) feeds `cas_skip_wr`,
which gates a branch of the SAME shared `always_ff` that commits
`mem_addr`/`mem_rw` for every instruction's own dispatch -- so the ALU's
combinational depth was bleeding into the critical path for instructions
that aren't even CAS.

Fix (commit `e1404a2`): `cas_cmp_done_r`/`cas_eq_r` latch the compare
result one cycle after `mem_got` instead of reading `alu_z` live,
mirroring this file's own `trap_decided` and memory-form-shift `shf_busy`
precedents exactly, including the matching gate needed in the
`rmw_wr_issued`/`rmw_done` latch per an explicit prior-documented
precedent about that exact failure mode (found once already for the
shift case). New dedicated regression `tests/cas_stage3.s` (`make
test-cas-stage3`, CAS has zero Harte coverage) confirms both match and
mismatch stay correct and shows the expected +1-tick-per-CAS cost
(161->163 EXECCYCLES for 2 back-to-back CAS instances). Full gate clean:
`make test` 43/43, `make lint-drivers` clean, full Harte sweep
bit-identical (`PASS 702142 FAIL 2 SKIP 281221 TIMEOUT 0`), `make bench`
all four arms unchanged (CAS isn't used by bench1/bench2).

**Measured: 26.49 -> 27.45 MHz mean** (9 seeds: 26.65, 27.55, 27.70,
28.68, 27.93, 27.90, 26.15, 28.50, 25.98; range 25.98-28.68) -- the whole
range shifted upward versus the pre-fix 24.88-27.50, not just the mean, a
real-looking improvement though still within the documented noise floor.
A `-noflatten` cross-check (2 seeds, consistent: 26.40/25.98 MHz)
confirms `u_alu` is genuinely gone from the critical path.

**Next target, identified by direct measurement**: `u_ifu.instr` ->
`u_core.u_dec` (~22 ns, ~58%, 44-46 hops, consistent both seeds) ->
`u_core.u_rf` -- the SOLE remaining decoder's own classification depth,
the same shape of problem already solved once for the front decoder
(`u_peek`) before the Stage 1 merge, now exposed with nothing else
stacked on top of it. Not yet investigated; no probe built. See
`docs/mh030p_architecture.md` section 8 for the full writeup.

**Session trajectory so far, mean values only**: 24.71 -> 27.36 MHz
(prior session, Stage 1 `ext_words` rewrite) -> 26.49 MHz (this session,
full decoder merge) -> 27.45 MHz (this session, CAS latch fix). Stage 2
(BIU fork) is done with zero behavioural change; its own FSM depth
restructuring remains deferred since the BIU is still not the binding
constraint (27.78 MHz standalone vs 27.45 MHz full design -- closer than
before, but `u_dec`'s own ~22 ns is still the thing actually gating
dispatch).

### MH030-P Stage 3 investigation: u_dec's own depth isolated and profiled, ea_idx_reg found dominant (2026-10-04)

New `tb/udec_rdsel_probe.sv` / `make fmax-udec-rdsel`, same register-in/
register-out technique as `tb/extw_probe.sv`: isolates the chain the
post-CAS-fix `-noflatten` trace found dominant (`u_dec`'s own
classification through the register file's `rd_a_sel` address mux,
stopping short of the regfile's own array read).

**Measured: 57.71 MHz (~17.3 ns) in isolation** -- somewhat faster than
the ~22 ns the full-design trace attributed to `u_dec`, consistent with
real fan-out on `dec_uop`'s own many other consumers rather than a
`-noflatten` DCE artifact. Profiled by driving the probe from
progressively smaller sub-expressions (same technique that found
`ext_words`' own real cost):

| sub-expression | Fmax | ns |
|---|---|---|
| `uclass` alone | 149.37 MHz | ~6.7 |
| `dst_reg` alone | 103.86 MHz | ~9.6 |
| `src_reg` alone | 126.57 MHz | ~7.9 |
| `ea_idx_reg` alone | 53.44 MHz | ~18.7 |
| full `rd_a_sel` mux | 57.71 MHz | ~17.3 |

**`ea_idx_reg` alone is nearly as expensive as the whole mux.** Traces to
`sxw = xword(ea_slot_is_dst ? ew_dst_at : ew_lead, ew_tot)` in
`mh030p_decode.sv` -- the same shape of cascading, per-family
extension-word-position arithmetic that made `ext_words` itself expensive
before Stage 1's shallow rewrite.

**Not yet fixed.** A "shallow `ea_idx_reg`" shortcut (computed straight
from raw bits in parallel with classification, mirroring
`ext_words_fast()` exactly) is a comparable-scope undertaking to that
entire Stage 1 rewrite -- new independent logic, a 65,536-opcode
equivalence sweep, bit-exact verification before swap-in -- not a quick
patch. Flagged for explicit scoping and sign-off before attempting. See
`docs/mh030p_architecture.md` section 8 for the full writeup.

No RTL changed this entry -- measurement only, mirroring `make test`/
`make lint-drivers` confirmed unaffected (new standalone probe file).

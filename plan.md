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

**New, OPEN bug found via mackerel-030f integration testing (a later
session), not yet root-caused in this repo**
(`project_skiptx_branch_target_regwrite_bug.md`): the first instruction
fetched at a taken conditional branch's own target can have its
destination-register decode corrupted — confirmed via direct
`eu_regfile.sv` write-port tracing that a `MOVE.L #imm,D1` sitting
exactly at a `BEQ.S` branch target never writes D1 at all, instead
producing a spurious write to D4 (an unrelated register from several
instructions earlier) carrying garbage data. Reproduced identically
across three different immediate values and two independent debug
builds; confirmed not a ROM-encoding bug (opcode bytes independently
re-verified and cleanly fetched) and not related to any BERR/exception
path (`berr_n` confirmed to never assert during the sequence). See the
project file for the full repro, exact signal traces, and a suggested
first debugging step (a small standalone `m68030_top`-only testbench
forcing `BEQ.S` taken directly into a `MOVE.L #imm,Dn`, inspecting
`eu_seq_decode.svh`'s own destination-register capture across the
redirect the same way Track 1's Phase 254-255 fix was diagnosed) —
plausibly a third instance of the same "stale `dec_*` field right after
a redirect" bug shape Track 1 already found and fixed twice for
RTS/RTR/RTE and CMPM, this time for a plain taken branch rather than a
multi-phase-stall redirect.

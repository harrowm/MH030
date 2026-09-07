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

### Proposed next steps (not yet actioned -- pending user direction)

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

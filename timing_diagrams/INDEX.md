# Timing diagram index

Every generated timing diagram, in the order the corresponding figure
appears in `docs/MC68030UM.pdf`. Each entry shows the manual's own figure
next to this RTL's simulated bus trace for the same cycle, rendered
through the real EU/decode pipeline (not a standalone bus-cycle drive)
unless noted. See `diagrams.md` for the full manifest (source testbench,
PDF/printed page, crop geometry) and `README.md` for the generation
pipeline.

## Figure 7-21 — Asynchronous Byte and Word Read Cycles, 32-Bit Port

Word read followed by two byte reads, all three chained with zero idle
gap.

![manual](generated/read_cycle_manual.png)
![sim](generated/read_cycle_eu_sim.png)

## Figure 7-22 — Long-Word Read, 8-Bit Port with CLOUT Asserted

`MOVE.L (A0),D0` against an 8-bit dynamic-sizing port: 4 chained byte
sub-cycles, SIZ sequence 00/11/10/01 (longword/3-byte/word/byte
remaining).

![manual](generated/manual_722.png)
![sim](generated/manual_722_sim.png)

## Figure 7-23 — Long-Word Read, 16-Bit and 32-Bit Port

Same read against a 16-bit-port region: 2 chained word sub-cycles.

![manual](generated/manual_723.png)
![sim](generated/manual_723_sim.png)

## Figure 7-25 — Read-Write-Write-Read Chain

Zero-wait-state portion: a read, two writes, and a trailing read, all
chained with zero idle gap — the diagram whose own construction found
and closed two real dispatch-gap bugs this session (the write-as-CURRENT
preview fix and the `biu_cache_if.sv` `CI_WRITE` fast-path fix, both in
`CLAUDE.md`'s post-Track-3 entries).

![manual](generated/manual_725.png)
![sim](generated/manual_725_sim.png)

## Figure 7-26 — Asynchronous Byte and Word Write Cycles, 32-Bit Port

A word write followed by two byte writes, 32-bit port, zero idle gap.

![manual](generated/manual_726.png)
![sim](generated/manual_726_sim.png)

## Figure 7-28 — Long-Word Operand Write, 16-Bit Port

`MOVE.L D0,(A0)` against a 16-bit-port region: 2 chained word sub-cycle
writes.

![manual](generated/manual_728.png)
![sim](generated/manual_728_sim.png)

## Figure 7-30 — Asynchronous Byte Read-Modify-Write Cycle, 32-Bit Port

`TAS (A0)`'s own locked read-then-write. AS genuinely negates between the
read and write phases, then reasserts for the write (the F1 AS-continuity
fix, `CLAUDE.md`).

![manual](generated/manual_730.png)
![sim](generated/manual_730_sim.png)

## Figure 7-36 — Synchronous Read-Modify-Write Cycle Timing, CIIN Asserted

`TAS (A0)`'s own locked read-then-write (the same RMW-lock shape as
Figure 7-30), this time terminated via `/STERM` instead of `/DSACKx` for
both the read and write phase — combines Figure 7-30's own RMW-lock
model with Figure 7-32's own always-ready synchronous-device model.

![manual](generated/manual_736.png)
![sim](generated/manual_736_sim.png)

## Figure 7-32 — Synchronous Read with CIIN Asserted and CBACK Negated

`MOVE.L (A0),D0` terminated via `/STERM` instead of `/DSACKx` —
`biu_cycle_gen.sv`'s own `sterm_active` bypass. `/CIIN` asserted, `/CBACK`
negated (no burst), matching the figure's own case exactly.

![manual](generated/manual_732.png)
![sim](generated/manual_732_sim.png)

## Figure 7-38 — Long-Word Operand Request with Burst Request and Wait Cycle

A D-cache miss with `CACR.DBE` (burst enable) set triggers a real
4-longword burst line fill — all 4 beats shown, with `/CBREQ`/`/CBACK`
handshaking each one. `/DSACKx`-terminated rather than `/STERM` (the
shared `tb/mem_model.sv` this diagram uses is DSACK-only); real 68030
burst mode accepts either termination method.

![manual](generated/manual_738.png)
![sim](generated/manual_738_sim.png)

## Figure 7-39 — Long-Word Operand Request with Burst Request, CBACK Negated Early

The same burst line fill, but the peripheral negates `/CBACK` after just
beat 1, aborting the burst early — beats 2/3 never happen. Found and
fixed a real gap while building this: `rtl/biu_burst_ctrl.sv` only ever
sampled `/CBACK` once, at beat 0 (a sticky latch), never re-checking it
on later beats — a real peripheral negating `/CBACK` mid-burst was
silently ignored and the burst ran to completion regardless, contrary
to MC68030UM.pdf §6.1.4/6.2's own explicit text: "The premature negation
of the CBACK signal during the burst operation causes the current cycle
to complete normally... However, the burst operation aborts." Fixed by
resampling `/CBACK` every beat instead of only the first. (Also found,
while re-verifying Figure 7-38 against the fix: that diagram's own
testbench mirrored `/CBREQ`'s own brief beat-0-only pulse for `/CBACK`
instead of modeling a real peripheral holding it asserted for the whole
burst — harmless under the old sticky-latch bug, but broke Figure 7-38
once CBACK was correctly resampled every beat. Fixed to hold `/CBACK`
asserted for the whole burst, matching `tb/cache_tb.sv`'s own already-
proven convention.)

![manual](generated/manual_739.png)
![sim](generated/manual_739_sim.png)

## Figure 7-44 / 7-45 — Interrupt Acknowledge Cycle Timing / Autovector Operation Timing

A genuine level-7 (NMI) interrupt request, recognized at the next
instruction boundary, dispatching a real CPU-space IACK bus cycle
(`FC=7`, address `$FFFFFFFx`), answered here with `/AVEC` (autovector),
followed by the exception frame push. Found and, in a later session,
fixed a real gap while building this
(`project_int_pending_level7_mask_gap.md`): `m68030_exc.sv`'s own
`int_pending` formula had no edge-triggered/non-maskable path for level
7, so a level-7 request asserted before anything lowered SR's own
reset-default mask of 7 was never recognized. Fixed via a sticky
edge-detect latch (`nmi_pending_r`) ORed into `int_pending`, set on any
transition of the synchronized IPL lines into level 7 and cleared once
the interrupt actually dispatches. The test program no longer lowers
the mask before looping — SR's mask stays at its reset-default 7
throughout, exercising the fix directly rather than working around it.

![manual](generated/manual_744.png)
![sim](generated/manual_744_sim.png)

## Figure 7-47 — Breakpoint Acknowledge Cycle Timing

`BKPT #7` dispatches a CPU-space read (`FC=7`, address = breakpoint
number × 4) answered with a substitute opcode word via ordinary
`/DSACKx` response (mirrors `tb/stall_fsm_tb.sv`'s own established
BKPT-live-substitution convention) — execution continues with the
substituted instruction.

![manual](generated/manual_747.png)
![sim](generated/manual_747_sim.png)

## Figure 7-49 — Bus Error without DSACKx

An ordinary read to a non-responding address, terminated by `/BERR`
alone (`/DSACKx`/`/STERM` never assert). Found and, in a later session,
fixed a real gap while building this
(`project_berr_no_halt_retry_loop.md`): with `/HALT` left deasserted
(the "plain BERR → exception" path), this specific construction
re-dispatched the same faulting access repeatedly instead of ever
completing exception dispatch. Root cause: `biu_sizing_fsm.sv` (sitting
between `biu_cache_if.sv` and `biu_cycle_gen.sv`) had no BERR-abort path
at all — its state machine only ever exited its active sub-cycle state
on a successful ack, which a genuinely faulted cycle never produces, so
it got stuck forever re-driving the stale faulting address into
`biu_cycle_gen` regardless of what the exception controller wanted to
dispatch next. Fixed via a new `cyc_berr` input (mirroring
`biu_cache_if.sv`'s own `sf_berr`) that resets it cleanly back to idle —
the exception now genuinely completes end-to-end. The diagram itself
still only needs the one faulting bus cycle's own pin-level timing,
unaffected either way and shown here.

![manual](generated/manual_749.png)
![sim](generated/manual_749_sim.png)

## Figure 7-54 — Asynchronous Late Retry

A write cycle where the device asserts `/DSACKx` (indicating success)
but a fault is detected late and `/BERR` + `/HALT` assert anyway,
forcing a genuine BERR+HALT retry (`biu_cycle_gen.sv`'s own
`!halt_s && !in_retry_r` branch, distinct from Figure 7-49's own plain-
BERR-to-exception path) — the retried write then completes cleanly with
no further fault.

![manual](generated/manual_754.png)
![sim](generated/manual_754_sim.png)

## Figure 7-60 — Bus Arbitration Operation Timing

An external DMA device requests the bus (`/BR`), the CPU grants it
(`/BG`) once its own current cycle completes, the device acknowledges
(`/BGACK`) and holds the bus, then releases it back.

![manual](generated/manual_760.png)
![sim](generated/manual_760_sim.png)

## Figure 7-64 — Initial Reset Operation Timing

The digital/bus-visible part of reset: `/RESET` held, the bus tri-stated,
then released and the real ISP (initial SSP/PC) read beginning. The VCC
ramp and analog timing spec the manual also shows aren't RTL-observable
(no analog power model in this project).

![manual](generated/manual_764.png)
![sim](generated/manual_764_sim.png)

## Project-specific (no manual figure)

`preview_dispatch` demonstrates the EU-side dispatch-gap fix itself
(`CLAUDE.md`'s Phase 254 entry) directly — not a datasheet cycle, so
there's no manual page to compare against. See `diagrams.md` for detail.

## Scope

This set covers the core asynchronous read/write/RMW family reachable
via ordinary EU-driven instructions, plus synchronous STERM cycles
(including synchronous RMW), burst-mode fills (including an early-abort
variant), CPU space/IACK, breakpoint acknowledge, bus error (both the
plain-exception and the BERR+HALT-retry paths), bus arbitration, and
reset — one representative diagram per category rather than exhaustive
coverage of every figure within it. Not attempted: the remaining late-
BERR/retry variants beyond Figures 7-49/7-54 (Figures 7-50 through
7-53), late retry for a burst specifically (Figure 7-56), the remaining
burst-fill variants beyond Figure 7-39 (Figure 7-40's own "fill
deferred" case), and the misaligned-transfer example diagrams (Figures
7-5 through 7-18, which mostly restate the dynamic-sizing behavior
Figures 7-22/7-23/7-28 already demonstrate) — each is a straightforward
extension of a category already covered here, left as further optional
additions rather than exhaustively built out.

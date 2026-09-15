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

## Figure 7-44 / 7-45 — Interrupt Acknowledge Cycle Timing / Autovector Operation Timing

A genuine level-7 (NMI) interrupt request, recognized at the next
instruction boundary, dispatching a real CPU-space IACK bus cycle
(`FC=7`, address `$FFFFFFFx`), answered here with `/AVEC` (autovector),
followed by the exception frame push. Found and worked around a real,
previously-undiscovered gap while building this
(`project_int_pending_level7_mask_gap.md`): `m68030_exc.sv`'s own
`int_pending` formula has no edge-triggered/non-maskable path for level
7, so a level-7 request asserted before anything lowers SR's own
reset-default mask of 7 is never recognized — worked around in the test
program by lowering the mask first, matching what real code would do
regardless; not yet fixed.

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
alone (`/DSACKx`/`/STERM` never assert). Found, documented, not chased
further (`project_berr_no_halt_retry_loop.md`): with `/HALT` left
deasserted (the "plain BERR → exception" path), this specific
construction re-dispatches the same faulting access repeatedly instead
of completing exception dispatch — the diagram itself only needs the
one faulting bus cycle's own pin-level timing, which is unaffected and
shown here.

![manual](generated/manual_749.png)
![sim](generated/manual_749_sim.png)

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
via ordinary EU-driven instructions, plus synchronous STERM cycles,
burst-mode fills, CPU space/IACK, breakpoint acknowledge, bus error, bus
arbitration, and reset — one representative diagram per category rather
than exhaustive coverage of every figure within it. Not attempted:
synchronous RMW timing (Figure 7-36), the various late-BERR/retry
variants beyond Figure 7-49 (Figures 7-50 through 7-56), late retry for
a burst specifically (Figure 7-56), the remaining burst-fill variants
(Figures 7-39 through 7-41), and the misaligned-transfer example
diagrams (Figures 7-5 through 7-18, which mostly restate the dynamic-
sizing behavior Figures 7-22/7-23/7-28 already demonstrate) — each is a
straightforward extension of a category already covered here, left as
further optional additions rather than exhaustively built out.

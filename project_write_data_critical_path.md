# Write-data critical path investigation (Phase 285, INVESTIGATED, partial fix shipped)

## Context

Phase 284 found and fixed two real combinational loops but only moved
real FPGA achieved frequency from 1.66 MHz to 1.78 MHz — neither was the
dominant contributor. This investigation used `nextpnr --report
... --detailed-timing-report` (a JSON timing report giving real
per-register worst-case arrival time for every endpoint in the design,
not just the single worst path a plain log shows) to get a fuller
picture, for the first time in this project's history.

## Finding 1: one shared write-data chain (superseded, see Finding 2)

The initial read of the per-endpoint data showed only 145 endpoints
exceeding 400 ns, all the same shape: peripheral write-data registers
(SPI `bb8`/`ccr`, UART `wb_dat_is`, SDRAM `wdata_r`, even the LEDs).
Traced to `biu_cycle_gen.sv`'s `ext_d_out = ... blc_wdata` being driven
live/combinationally all the way from `eu_seq_execute.svh`'s
`mem_wdata` (often a live EU-side ALU/regfile result), through
`biu_sizing_fsm.sv`'s and `biu_cache_if.sv`'s own matching
"dispatch-cycle live-passthrough" fast-path arms (the identical "skip
the register on the very first dispatch tick" pattern Phase 284's
D-cache fix already found and removed once, for a different signal) —
zero register anywhere in the chain.

## Fix implemented

`biu_cycle_gen.sv` gained a new `wdata_hold_r` register, capturing
`blc_wdata` during `sphase==SP_S2` (the real write cycle's own AS-only
state) and used for `ext_d_out` from `SP_S3` onward instead of the live
wire. This exploits a real, confirmed 1-tick gap: every reachable
write-shaped cycle type (WRITE, RMW-write, CAS2 W1/W2) transitions
through `sphase==SP_S2` for exactly one tick before reaching `SP_S3`/
`SP_S4` (confirmed directly from `biu_cycle_gen.sv`'s own `state_nxt`
transition table). Burst-write (`ST_BWRITE_*`) is deliberately excluded
via the existing `is_burst_write` signal — its own `ST_BWRITE_S6->S4`
loop-back never revisits S2 for beats 2-4, which would make
`wdata_hold_r` go stale. This was not a hypothetical concern: it
surfaced as a real `make test` regression on the first implementation
attempt (`tb/biu_tb.sv`'s own "MOVE16 burst write" tests, which drive
`eu_m16_req` directly at `biu_cycle_gen`'s own module port — exercised
by the mandatory gate even though `eu_m16_req` is permanently hardwired
to `1'b0` in `m68030_top.sv`, MOVE16 having been removed entirely,
Phase 250 F8, so this specific path is unreachable from the real
integrated chip but still unit-tested).

## Verification

Full mandatory gate clean (`make test` 38/38, `cosim_grp` 8/8,
`cosim_memind` 33/33, `dat-synth` 50/50), full 124-suite Harte sweep
bit-identical to baseline (`PASS 702142 FAIL 2`).

## Finding 2: the fix had zero measured effect on real frequency

Re-synthesis with the fix in place gave `1.79 MHz` — unchanged from
before. Re-reading the new critical path explained why: `wdata_hold_r`
itself is now sitting in the critical cluster (~556 ns) — the value
feeding its own `D` input was never actually settled ahead of the
capture edge. `s_state` is still the starting point of the exact same
combinational chain feeding the new register.

**Lesson**: adding a register downstream of a combinational chain only
helps if the chain's own source has already settled by an *earlier*
clock edge than the one the new register captures on. A register
inserted at a point where the upstream logic is *still reactively
computing on the same edge* just relocates the identical setup-time
race to a new location — it doesn't shorten anything.

## Finding 3: the real root cause — `dyn_bit_get_Dn`

`eu_seq_execute.svh:2509`: `dyn_bit_get_Dn = ... mem_ack && ...` — live,
combinational, no register anywhere. The instant a dynamic-bit
instruction (BCHG/BCLR/BSET/BTST with an indexed EA, reading its own
target register *number* from memory) completes that memory read, this
signal fires the same tick and immediately selects `rd_a_sel`/
`rd_b_sel` (which register to read next), driving `rd_b_data`, flowing
through `ex_an_base` → `ex_an_new` → the ALU's own `alu_dst` (via the
documented "same-register auto-update" special case,
`eu_seq_execute.svh:4072`, e.g. `ADDA.L (A0)+,A0`) → the ALU result →
write-data → the pins, all within the same tick `mem_ack` asserts.

This is exactly the mechanism
[[feedback_post_ack_signal_reuse]] (this project's own memory notes)
documents: it exists specifically to preserve the real-silicon-matching
zero-gap back-to-back bus timing Track 1-3 spent ~20 phases building
(`~/.claude/plans/wobbly-honking-cascade.md`). **It is not a bug and not
simply pipelineable**: the target register *number* for a dynamic-bit
instruction literally does not exist before the memory read completes,
so there is nothing to "preview" one cycle early the way the other 16
special-FSM families' own preview mechanism does. Real 68030 silicon has
the identical sequential dependency — it simply has custom-gate
propagation delay fast enough to fit within its own clock period, which
general-purpose FPGA LUT fabric cannot match at the same logical depth.

## Finding 4: the scale of the real gap

Computed directly from the same per-endpoint timing data: of 13,487
register endpoints in the whole design, **9,040 (67.0%) exceed the
10 ns period a real 100 MHz `clk_4x` needs.** Median endpoint delay is
16.3 ns — over 1.5x the budget, and that's the median, not an outlier.
This rules out "find and fix the single worst chain" as a viable
strategy for reaching 100 MHz on its own; the gap is systemic, not
concentrated in one path.

## Finding 5: the 9,040 failing endpoints are not evenly spread

Module-level breakdown of every failing (>10 ns) endpoint:

| Module | Failing endpoints | Share |
|---|---|---|
| `u_cpu.u_eu.u_seq` | 2,860 | 31.6% |
| `u_cpu.u_biu.u_cache` (D-cache) | 2,316 | 25.6% |
| `u_cpu.u_biu.u_icache` (I-cache) | 2,107 | 23.3% |
| `u_cpu.u_eu.u_rf` (register file) | 593 | 6.6% |
| everything else | 1,164 | 12.9% |

**80.6% of all failing endpoints live in just 3 modules.** This reframes
"pipeline the whole design" into a prioritized, 3-phase plan — see
`plan.md`'s own Phase 285 section for the full Phase A/B/C breakdown
(Phase A: D-cache + I-cache → real BRAM, 48.9% of the failing
population, bounded risk, not yet started; Phase B: MMU ATC, small,
deferred; Phase C: `eu_seq` restructuring, comparable in scope to the
entire Track 1-3 effort, needs a real architectural trade-off decision
before it can even begin).

## Status

`wdata_hold_r` is kept — it's a correct, harmless, verified improvement
(genuinely removes one unregistered dispatch-cycle passthrough) even
though it wasn't the fix that moves the frequency needle. The real path
forward is Phase A (cache/icache BRAM conversion), tracked in `plan.md`.

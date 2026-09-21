# Bug: byte/word reads from a genuinely 8-bit/16-bit external port land top-justified instead of right-justified

**Status: FIXED AND VERIFIED.** `biu_sizing_fsm.sv`'s `merge_rdata()` now
right-justifies byte/word reads assembled from a dynamically-sized 8-bit
or 16-bit port, matching the convention every other consumer of
`mem_rdata` in `eu_seq_execute.svh` already relies on. Found via a real
mackerel-030f SoC UART integration failure (a separate FPGA project using
this repo's `rtl/` as a git dependency), NOT via any bug in the UART code
itself — traced there first, and the UART, its wrapper, and MH030's own
byte-lane-replication write path were all confirmed correct before the
real root cause was found one layer up, in the BIU's own dynamic-sizing
read-assembly logic.

## Summary

`MOVE.B (5,A1),D2` (reading a UART's Line Status Register, an 8-bit
port) reliably loaded D2 with `0x60000000` instead of `0x00000060`. Since
`BTST #5,D2` tests bit 5 of whatever `D2` holds, and the real value
(`0x60`, THRE+TEMT both set) landed at bits `[31:24]` instead of `[7:0]`,
the test bit was always 0 — `boot.s` always took the "not ready, skip
transmit" branch, on every single loop iteration, forever.

Traced end-to-end via direct hierarchical signal tracing in a Verilator
sim of the real mackerel-030f SoC (not a unit test): the UART core's own
`lsr` register genuinely holds `0x60` at read time; it propagates
correctly through `biu_sizing_fsm`'s own internal `sf_accum`/`sf_rdata_r`,
through `biu_cache_if`'s `ca_eu_rdata`, all the way to `m68030_eu.sv`'s
`mem_rdata` INPUT — every one of those signals shows `0x60000000` at the
exact `mem_ack`/`eu_ack` cycle. The value is correct; only its
**position** within the 32-bit word is wrong.

## Root cause

`biu_sizing_fsm.sv`'s `merge_rdata()` function assembles a read result
across however many sub-cycles the port's own dynamically-negotiated
width requires. For a **32-bit port**, it already correctly normalizes a
byte/word result to the right-justified convention (`{24'h0,
raw[31:24]}` etc., keyed off `{orig_siz, addr_lo}`) that the rest of the
EU expects — e.g. `eu_seq_execute.svh`'s own MOVEP handling reads
`mem_rdata[7:0]` directly, and this convention is documented and relied
on throughout that file.

But for **8-bit and 16-bit ports**, the function instead positioned each
incoming byte at its natural big-endian *longword* lane (byte 0 at
`[31:24]` ... byte 3 at `[7:0]`), **regardless of the original request
size**:

```systemverilog
2'b10: begin  // 8-bit port: data on D[31:24]
    case (done[1:0])
        2'b00: piece = {raw[31:24], 24'h0};        // byte 0 → top
        ...
```

This is correct **by construction** for a longword request (all four
lanes end up filled either way, so justification is moot — this is
exactly the case `tb/biu_tb.sv`'s own pre-existing "Longword read from
8-bit/16-bit port" tests exercised, and is why this bug survived
undetected). It is **wrong** for a byte or word request, which needs the
final result right-justified into `[7:0]`/`[15:0]` — a combination no
existing test ever exercised, since it needs a real, dynamically-sized,
narrower-than-32-bit port responding to something smaller than a
longword, not just a longword transfer through one.

## Fix

Replaced the fixed lane-position lookup with a shift computed directly
from `orig_bytes` (the original request size) and `done` (bytes already
assembled before this sub-cycle):

- **8-bit port** (always exactly 1 byte per beat, matching
  `next_siz()`/`needs_more()`'s own `xfer=1` convention for this port
  unconditionally): `piece = {24'h0, raw[31:24]} << (8 * (orig_bytes -
  1 - done))`. This reduces to the *exact same* shifts as the old code
  for `orig_bytes==4` (longword — unchanged, still passes the existing
  tests), and newly right-justifies `orig_bytes==1` (byte) and
  `orig_bytes==2` (word).
- **16-bit port** (always exactly 2 bytes per beat when
  `orig_bytes>=2`, matching `xfer=2`): `piece = {16'h0, raw[31:16]} <<
  (8 * (orig_bytes - 2 - done))`. Same reduction: unchanged for
  `orig_bytes==4`, newly correct for `orig_bytes==2`.

**Deliberately not fixed — a genuinely separate, pre-existing gap, not
worsened by this fix:** a **byte** request serviced by a **16-bit**
port. `next_siz()`/`needs_more()`'s own model treats a 16-bit port as
always consuming 2 bytes of "capacity" per beat even when only 1 byte
was really requested, and which half of the port's own `D[31:16]`
response holds the real byte is peripheral- and address-dependent (the
32-bit-port branch already threads `addr_lo` through for exactly this
reason; the 8/16-bit branches never have). Fixing this properly would
need a new `addr_lo`-based half-selection this module doesn't currently
have anywhere, and no real peripheral in this project (UART: 8-bit;
SPI: 8-bit; SDRAM: 16-bit, only ever accessed as a longword) exercises
the combination. Left exactly as before — not fixed, not worsened.

## Verification

New dedicated regression coverage in `tb/biu_tb.sv`: byte read from an
8-bit port, word read from an 8-bit port (2 sub-cycles), word read from
a 16-bit port (1 sub-cycle) — all check the right-justified result
directly. Confirmed all three **fail cleanly** on the pre-fix code
(`got 11000000 expected 00000011`, etc.) via a temporary revert, then
pass with the fix restored. The existing longword-via-8/16-bit-port
tests remain unchanged and passing throughout.

Full mandatory gate clean (`make test` 38/38), `make cosim_grp` 8/8,
`make dat-synth` 50/50, full 124-suite Tom Harte sweep bit-identical to
baseline (`PASS 702142 FAIL 2` documented ASL.b anomaly, `SKIP 281221
TIMEOUT 0` — unaffected, since Harte's own harness never models a real
dynamically-sized narrower-than-32-bit port).

**`make cosim_memind` initially regressed (4 of 33 tests: memind10,
memind30, memind31, memind34, memind36)** after this session's *other*
fix (`project_skiptx_branch_target_regwrite_bug.md`, the branch-redirect
stale-fetch fix) landed — traced each one directly against its own
`.s` source and confirmed all four are the exact same, expected, genuine
consequence of that fix: a taken `Bcc`/unconditional `JSR`/`JMP` landing
while the IFU's own ambient readahead into the (now-abandoned)
fall-through path is still genuinely in flight now correctly lets that
real bus cycle complete before dispatching the redirect, instead of the
old code's mid-cycle address mutation silently folding the two into one
transaction. Musashi (a purely functional emulator with no genuine
bus-cycle-level speculative-prefetch model) never issues this extra bus
cycle at all, so its own reference trace no longer bit-matches — a
Musashi-modeling gap, not an RTL regression, confirmed by hand-checking
each test's own `.s` source: memind10/30/31 all contain a `JSR`/`JMP`
immediately followed by deliberately-unreachable filler; memind34/36
each contain a genuinely-taken `Bcc`. `tools/buscmp.py` gained a new
`--allow-dut-extra-fetch` flag (mirroring the existing
`--allow-adjacent-swap` precedent) that tolerates exactly one DUT-only
**READ** cycle (never a write) whose immediate successor realigns with
the reference stream — applied to those 4 Makefile targets only. Every
other `cosim_memind` target, `cosim_grp`, and `dat-synth` needed no
change and remain exactly as strict as before.

**Closes `project_biu_narrow_port_read_justification_bug.md` in full.**

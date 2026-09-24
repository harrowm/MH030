# Scoping: the next bounded timing fixes after 14.24 MHz

Written while the multiple-driver fix was measuring, from the `seqdiv`
timing report (the 14.24 MHz one). No RTL was changed, so the running
measurement's attribution is undisturbed.

## The shape of what's left

Worst register-to-register path: **70.24 ns over 97 hops**, crossing **16
module transitions**.

| Module | Delay | Routing | Logic | Placement sites |
|---|---|---|---|---|
| `u_seq` | 18.28 ns | 15.58 | 2.69 | 8 |
| `u_cache` | 18.82 ns | 15.45 | 2.84 | 8 |
| `u_md` | 14.74 ns | 11.01 | 3.74 | 7 |
| `u_icache.data_i` | 12.62 ns | 11.38 | 1.24 | 6 |
| `u_sdram` | 4.86 ns | — | — | — |

**Total logic on the entire path is 11.74 ns of 70.24 ns.** The remaining
58 ns is routing between distant sites — the ten worst hops are 41% of the
path and every one is a long diagonal (e.g. `[90,73] -> [58,47]`).

The consequence matters for choosing fixes: **logic-depth reduction cannot
buy much**, because eliminating *all* remaining logic on the path only
reaches ~58 ns. What actually helps is (a) putting a register boundary
somewhere in the chain, or (b) removing cells to ease congestion — which
is most of why the divider fix worked (it removed ~12k LUTs, -22%).

The path in order, with per-segment delay:

```
 1 u_cache            4.22    9  u_seq             2.32
 2 u_icache.data_i    3.55   10  u_cache           4.17
 3 u_cache.data_d     2.86   11  u_sdram           3.73
 4 u_seq             12.17   12  u_cache           4.94
 5 u_mmu              0.93   13  u_sdram           1.13
 6 u_md              14.74   14  u_cache           2.63
 7 u_seq              1.38   15  u_seq             2.40
 8 u_icache.data_i    6.02   16  u_icache.data_i   3.04
```

## Candidate B (RECOMMENDED): move the divider's sign re-application off the output path

**Evidence.** Of the 28 `u_md` hops, **20 are CCU2C cells** — a carry chain.
The path *passes through* `u_md` (entering from `u_mmu`, leaving to `u_seq`)
rather than terminating in it, so this is not the iteration loop (whose
inputs `div_rem_r`/`div_dsr_r` are both registers). It is the **output**
path.

The suspect is the sign re-application added with the sequential divider
(`rtl/eu_mul_div.sv`):

```systemverilog
assign div_quot_signed = div_qneg_res_r ? (~div_quot_mag_r + 32'd1) : div_quot_mag_r;
assign div_rem_signed  = div_rneg_res_r ? (~div_rem_mag_r  + 32'd1) : div_rem_mag_r;
```

Two 32-bit two's-complement negates — each a full carry chain — sitting
**between a register and the writeback mux**, evaluated every cycle and
feeding `result_lo`/`result_hi` -> `ex_result` -> `wb_result`.

**Fix.** Register the already-signed values instead of the magnitudes: do
the negate in the final iteration tick (`div_iter == 1`), where the result
registers are written anyway, so `div_quot_signed`/`div_rem_signed` become
plain register reads. The carry chain moves into a cycle that already
exists and has slack.

**Cost: zero cycles.** The negate happens on the same edge that already
latches `div_quot_mag_r`; nothing downstream moves. It does add a second
adder's worth of logic in that one tick, which must be checked not to
become the new bottleneck — but that tick is one of 32 iteration ticks, not
the dispatch path.

**Risk: low.** Self-contained in `eu_mul_div.sv`, and `tb/eu_mul_div_tb.sv`
already checks every signed edge case (truncate-toward-zero, remainder sign
follows dividend, INT_MIN/-1, over/underflow) — those tests are the exact
equivalence gate for this change.

**Caveat.** ABC9 cell names are not reliable signal attribution (only the
hierarchical prefix is), so "which carry chain" is inference from the
*shape* — 20 CCU2C cells on a pass-through path, and these are the only
carry chains in the module whose inputs are registers and whose outputs
leave the module. Worth confirming by measurement rather than trusting.

## Candidate A: register the SoC's data-return mux (`mackerel-030f`)

**What the loop actually is.** Not DSACK — MH030 puts `dsack0/1` through
2-stage synchronizers by design, so that leg is already register-broken.
It is the **read-data return**: `ext_a` (combinational out of the BIU) ->
address decode (`in_rom`/`in_sdram`/...) -> the `ext_d_in` mux select ->
straight back into the CPU, plus the address/control leg into the
peripherals.

```systemverilog
assign ext_d_in = in_rom   ? rom_dout_r :
                  in_uart  ? {4{uart_data_out}} :
                  in_spi   ? {4{spi_data_out}} :
                  in_sdram ? {sdram_rdata, sdram_rdata} : 32'h0;
```

**Why a register is safe here (verified, not assumed).**
`biu_cycle_gen.sv` latches `captured_rdata <= ext_d_in` only at
`ST_READ_S4`/`S5`, gated on `!dsack_wait`, i.e. on the *synchronized*
DSACK — at least 2 ticks after the peripheral asserts it. A 1-tick register
on the return path therefore has slack and **adds no wait state**.

Hold is satisfied on every source: `sdram_adapter`'s `rdata` is a register
assigned only on `sys_rd_data_valid` and held, with `done` latched until
`req` drops; `rom_dout_r` is registered and stable while the address is.
`uart_data_out`/`spi_data_out` still need checking.

**Expected gain: modest.** The cut lands at path position ~11 of 16,
splitting 70.24 ns into roughly 56 ns + 14 ns, so ~17-18 MHz *if* nothing
else re-converges. `u_sdram`'s own contribution alone is only 4.86 ns (6.9%).

**Risk: low but cross-repo**, and it changes the SoC rather than the core.

## Recommended order

1. **Candidate B** — inside MH030, zero cycle cost, strong existing test
   coverage, attacks the single largest module segment (14.74 ns).
2. **Candidate A** — if B's measurement shows the tail still binding.

Measure them separately. This session has twice shown that plausible
reasoning about timing is wrong until measured (`wdata_hold_r` was correct
and worth zero; the tag/valid arrays were not the BRAM problem they looked
like), so stacking them would destroy attribution.

## Honest ceiling estimate

Neither candidate is another 5.8x. With logic at only 11.74 ns of 70.24 ns,
the remaining path is structurally distributed rather than deep, and each
bounded fix cuts one segment while the next-worst path re-converges. A
realistic read is **high-teens to low-20s MHz** from continuing this way,
against the 25-50 MHz target — reaching the top of that range likely still
needs real register boundaries in the CPU chain, which is the rewrite
argument. That should be re-evaluated after B's measurement, not assumed
now.

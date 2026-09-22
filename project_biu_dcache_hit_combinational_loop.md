# D-cache hit combinational feedback loop (Phase 284, FIXED AND VERIFIED)

## Discovery

Found via the very first real ECP5-85K FPGA synthesis + place-and-route run
ever performed against this design (triggered while bringing MH030 up on
real ULX3S hardware inside the mackerel-030f SoC project). `nextpnr-ecp5`'s
static timing analysis reported the CPU core achieves only **~1.66 MHz**
real max frequency for `$glbnet$clk_4x` against a 100 MHz target, with
thousands of hold-time violations. This had never been checked before —
this project's entire verification history (Icarus/Verilator, Tom Harte
cosim, mackerel-030f SoC simulation) is purely event-driven functional
simulation, which models zero gate/routing propagation delay and cannot
detect a real combinational timing hazard at all.

A dedicated Explore-agent investigation traced every edge directly against
the RTL (not inferred) and found Verilator's own `UNOPTFLAT` elaboration
warnings (`preview_ok`, `ex_redirect_pending`, `rd_a_sel`, `rd_b_sel`, all
"Circular combinational logic — this may cause simulation results to
differ from synthesis") all sit in **one single strongly-connected
component**, closing through exactly one no-register-boundary node:
`biu_cache_if.sv`'s `CI_IDLE` state serving a D-cache **hit** purely
combinationally:

```systemverilog
end else if (eu_req && eu_rw && dhit) begin
    eu_ack   = 1'b1;
    eu_rdata = extract_rd(data_d[idx][woff], eu_siz, eu_addr[1:0]);
end
```

`eu_addr` (hence `dhit`, hence this `eu_ack`/`eu_rdata`) is combinationally
computed from `mem_addr`, which itself depends on **this same cycle's own**
`mem_ack`/`mem_rdata` via three separate paths, all independently confirmed
real: `preview_ok` (Track 3's own preview address mux), `dyn_bit_get_Dn`
(the dynamic register-swap mechanism, `rd_a_sel`/`rd_b_sel`), and
`ex_redirect_pending`/`ex_mem_stall` (via `chk_trap`/`stall`/
`dec_branch_taken`). All three close back into `mem_addr` → `eu_addr` →
`dhit` → `eu_ack`/`eu_rdata` → `mem_ack`/`mem_rdata`, the exact same node.

This fast path was added at `plan.md` Phase 247 item #10, a latency
optimization to shave one cycle off a D-cache hit. The older, registered
path (`CI_HIT`, `rtl/biu_cache_if.sv:478`, `:522-525`, `:1263+`) was never
removed and still correctly delivers `eu_ack`/`eu_rdata` one cycle later
from latched `idx_r`/`woff_r`/`addr_r`. The I-cache (`biu_icache_if.sv`)
was never given the equivalent optimization — its own hit response lives
only in `IC_HIT`, one cycle after `IC_IDLE` — so this fix brings the
D-cache back in line with how the I-cache has always worked.

## Fix

Deleted the combinational fast-path arm from `biu_cache_if.sv`'s `CI_IDLE`
output block entirely, reverting to the pre-existing, unmodified `CI_HIT`
registered path for D-cache hits. Pure deletion — no new logic, since the
slower path was already fully implemented and wired. Net effect: a D-cache
**hit** read now takes 1 extra `clk_4x` cycle, matching the I-cache's own
existing convention. Writes, misses, disabled-cache accesses, and every
other cache-interface path are completely untouched.

## Verification

Full mandatory gate clean (`make test` 38/38, `make cosim_grp` 8/8,
`make cosim_memind` 33/33, `make dat-synth` 50/50), full 124-suite Tom
Harte sweep bit-identical to baseline (`PASS 702142 FAIL 2` documented
ASL.b anomaly) — the D-cache is never enabled by Harte's own harness,
matching this project's own established precedent for other cache/burst
fixes. A fresh Verilator elaboration confirmed all four originally-flagged
`UNOPTFLAT` warnings gone. No `tb/cache_tb.sv` timing assertion needed
updating (none had encoded the old 0-cycle hit latency as a hard
assumption).

## Important: this fix alone did NOT resolve the real-hardware timing problem

Re-running FPGA synthesis with only this fix in place showed **no
meaningful improvement** (1.73 MHz vs the 1.66 MHz original) — this loop,
while a genuine combinational-cycle bug worth fixing on its own merits, was
never the dominant contributor to the achieved frequency. See
[project_eu_stall_redirect_combinational_loop.md](project_eu_stall_redirect_combinational_loop.md)
for the second loop found and fixed in the same investigation, and
`project_fpga_critical_path_investigation.md` (Phase 285+) for the much
larger finding that neither loop was ever the real bottleneck: the actual
critical path is a single ~562 ns, ~3600-hop acyclic combinational chain
spanning nearly the entire design with no register boundary anywhere in
it, requiring a genuine microarchitectural pipelining effort to close —
out of scope for this fix, tracked separately.

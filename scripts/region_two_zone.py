# Stage 4, second attempt: the BRAM-interface cut (region_bram_iface.py)
# measured WORSE (26.85 vs 27.64 MHz, 3 seeds). This tries a structurally
# different idea -- not fencing off a signal cone, but giving the placer
# two coarse sub-problems instead of one: u_core (~55% of the design's
# real logic cells) gets the left ~55% of the die, u_biu gets the rest.
# Untested assumption this script exists to check, not assert: that two
# large, proportionally-sized zones reduce congestion versus one
# unconstrained free-for-all. Chip grid confirmed 126x95 via
# ctx.getBelLocation sweep.
CORE_REGION = (0, 0, 69, 95)
BIU_REGION = (70, 0, 126, 95)

core_cells = []
biu_cells = []
for kv in ctx.cells:
    n = kv.first
    if n.startswith("u_dut.u_cpu.u_core."):
        core_cells.append(n)
    elif n.startswith("u_dut.u_biu."):
        biu_cells.append(n)

print(f"region_two_zone: {len(core_cells)} u_core cells -> {CORE_REGION}, "
      f"{len(biu_cells)} u_biu cells -> {BIU_REGION}")

ctx.createRectangularRegion("core_zone", *CORE_REGION)
ctx.createRectangularRegion("biu_zone", *BIU_REGION)
for n in core_cells:
    ctx.constrainCellToRegion(n, "core_zone")
for n in biu_cells:
    ctx.constrainCellToRegion(n, "biu_zone")

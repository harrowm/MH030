# Stage 4 (docs/mh030p_architecture.md section 8): constrain the u_core
# cells with a direct net connection to either cache BRAM's own pins (found
# by real netlist BFS, not name matching -- cell names do not survive this
# flattened netlist's ABC9 renaming at all, confirmed empirically: a search
# for "mem_" anywhere in u_core's cell names returns zero hits) into a
# region near wherever the BRAMs actually land.
#
# Both BRAMs measured at (17,22) [I-cache data_i] and (31,22) [D-cache
# data_d] in an unconstrained seed-1 placement -- close together already.
# A 3-level BFS from both BRAMs' ports explodes fast (level 0: 1,979 u_core
# cells, level 1 cumulative: 9,972, level 2: 24,333, level 3: 31,535 of
# u_core's 37,150 total) -- the "interface" is not small at any practical
# radius, consistent with this design's routing-dominated, diffuse
# congestion signature. This script uses ONLY the level-0 cut (cells with a
# DIRECT net connection to a BRAM pin) as the most defensible, smallest
# real target: these cells have a genuine electrical reason to sit near the
# BRAM; nothing beyond level 0 does, by the same reasoning.
import collections

BRAMS = ["u_dut.u_biu.u_cache.data_d.0.0", "u_dut.u_biu.u_icache.data_i.0.0"]
# Generous box around both measured BRAM locations (17,22)/(31,22), sized
# for ~1,979 cells with routing slack -- not the "half the chip" a whole-
# u_core constraint would need.
REGION_BOX = (5, 5, 50, 45)

cell_by_name = {}
for kv in ctx.cells:
    cell_by_name[kv.first] = kv.second


def net_driver_cell(net):
    if net is None or net.driver is None or net.driver.cell is None:
        return None
    return net.driver.cell.name


def net_sink_cells(net):
    out = []
    if net is None:
        return out
    for u in net.users:
        if u.cell is not None:
            out.append(u.cell.name)
    return out


core_cells_lvl0 = set()
visited = set()
frontier = collections.deque()

for bram_name in BRAMS:
    bram_cell = cell_by_name.get(bram_name)
    if bram_cell is None:
        continue
    for pkv in bram_cell.ports:
        net = pkv.second.net
        if net is None:
            continue
        drv = net_driver_cell(net)
        if drv and drv != bram_name:
            frontier.append(drv)
        for s in net_sink_cells(net):
            if s != bram_name:
                frontier.append(s)

while frontier:
    name = frontier.popleft()
    if name in visited:
        continue
    visited.add(name)
    if name.startswith("u_dut.u_cpu.u_core."):
        core_cells_lvl0.add(name)

print(f"region_bram_iface: constraining {len(core_cells_lvl0)} u_core cells "
      f"(direct BRAM-pin connections only) into region {REGION_BOX}")

ctx.createRectangularRegion("bram_iface_region", *REGION_BOX)
for n in core_cells_lvl0:
    ctx.constrainCellToRegion(n, "bram_iface_region")

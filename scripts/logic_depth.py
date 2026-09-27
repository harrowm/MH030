#!/usr/bin/env python3
"""
Fast register-to-register logic-depth analysis of a synthesised ECP5 netlist.

WHY THIS EXISTS
---------------
A real nextpnr timing measurement takes about three hours and, as this project
measured directly, has a seed-to-seed spread of ~0.5 MHz -- so it cannot resolve
a change worth less than ~2 MHz, and three consecutive critical-path fixes were
"measured" against noise. This reads the post-synthesis netlist instead and
finishes in seconds, which turns two experiments a day into dozens.

WHAT IT REPORTS, AND WHY LEVELS ARE ENOUGH
------------------------------------------
Per-cell logic delays were calibrated from this project's own nextpnr reports:
LUT4 averaged 0.242 ns and CCU2C 0.247 ns over 237 real samples. They are the
same to within noise, so an UNWEIGHTED level count is a valid proxy -- a carry
cell and a LUT cost the same per hop here.

Pairing that with the measured routing share gives an ns-per-level constant,
CALIBRATED against four real nextpnr runs of this design:

    nt5  34.35 ns / 43 levels = 0.799     nt7  47.45 ns / 57 = 0.832
    nt6  46.60 ns / 64 levels = 0.728     nt8  46.54 ns / 57 = 0.816
                               mean 0.794, range 0.728-0.832 (+/-7%)

    period ~= levels * 0.794 ns   ->   50 MHz needs <= 25 levels

HOW FAR TO TRUST IT. The ORDERING is right: 43 levels measured fastest and 64
slowest, and the two variants that tied at 57 levels measured within noise of
each other. The absolute value runs ~15% pessimistic. But it is necessary, not
sufficient -- nt6 -> nt7 cut depth 64 -> 57 and measured no frequency change at
all, which says that at this size the design is also congestion-limited. So use
this to reject bad ideas cheaply and to aim, and still confirm with a real
multi-seed measurement before claiming a win.

The histogram matters as much as the worst path. nextpnr's report names only one
path per clock, which cannot answer "is this one deep chain or thousands of
near-equal ones" -- the question that mattered most and could not be answered
from its output. Here every endpoint's depth is available.
"""
import json, sys, argparse, collections, re

# Cells that END a combinational path: their outputs are sources, inputs sinks.
SEQ_TYPES = {"TRELLIS_FF", "DP16KD", "DPR16X4C", "PDPW16KD", "TRELLIS_DPR16X4"}


def load_top(path):
    d = json.load(open(path))
    # The real design module is the one with primitives in it; the rest are
    # blackbox declarations and ABC9 helpers.
    best, best_n = None, -1
    for name, m in d["modules"].items():
        n = len(m.get("cells", {}))
        if n > best_n:
            best, best_n = (name, m), n
    return best


def build(mod):
    """net bit -> driving (cell,port); cell -> list of input net bits."""
    drivers = {}          # bit -> cell name
    cell_inputs = {}      # cell -> [bits]
    cell_type = {}
    for cname, c in mod["cells"].items():
        dirs = c.get("port_directions", {})
        cell_type[cname] = c["type"]
        ins = []
        for port, bits in c["connections"].items():
            d = dirs.get(port)
            for b in bits:
                if not isinstance(b, int):
                    continue          # constants
                if d == "output":
                    drivers[b] = cname
                elif d == "input":
                    ins.append(b)
        cell_inputs[cname] = ins
    return drivers, cell_inputs, cell_type


def depths(drivers, cell_inputs, cell_type):
    """Longest combinational level count reaching each cell's output."""
    memo, onstack, loops = {}, set(), []

    def lvl(cname):
        if cname in memo:
            return memo[cname]
        if cname in onstack:
            loops.append(cname)
            return 0                  # break the cycle rather than hang
        if cell_type[cname] in SEQ_TYPES:
            memo[cname] = 0           # a register output starts a fresh path
            return 0
        onstack.add(cname)
        best = 0
        for b in cell_inputs[cname]:
            src = drivers.get(b)
            if src is None:
                continue              # a top-level input port
            best = max(best, lvl(src) + 1)
        onstack.discard(cname)
        memo[cname] = best
        return best

    sys.setrecursionlimit(200000)
    for cname in cell_type:
        lvl(cname)
    return memo, loops


def prefix_of(name):
    """The hierarchical prefix, which is the only trustworthy part of a
    synthesised cell name -- ABC9 names new cells after the nearest traceable
    ancestor register, so the leaf is not attribution."""
    head = name.split("_LUT4")[0].split("_CCU2C")[0].split("_PFUMX")[0]
    head = head.split("_TRELLIS_FF")[0].split("_L6MUX21")[0]
    return head.rsplit(".", 1)[0] if "." in head else "<top>"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist")
    ap.add_argument("--ns-per-level", type=float, default=0.794,
                    help="calibrated logic+routing per level (default 0.794)")
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()

    name, mod = load_top(a.netlist)
    drivers, cell_inputs, cell_type = build(mod)
    memo, loops = depths(drivers, cell_inputs, cell_type)

    # An endpoint is a sequential cell; its depth is the deepest cone feeding it.
    ep = {}
    for cname, ctype in cell_type.items():
        if ctype not in SEQ_TYPES:
            continue
        best, via = 0, None
        for b in cell_inputs[cname]:
            src = drivers.get(b)
            if src is None or cell_type[src] in SEQ_TYPES:
                continue
            if memo[src] + 1 > best:
                best, via = memo[src] + 1, src
        ep[cname] = (best, via)

    counts = collections.Counter(c["type"] for c in mod["cells"].values())
    print(f"module {name}   cells: " +
          "  ".join(f"{k} {v}" for k, v in counts.most_common(6)))
    if loops:
        print(f"WARNING: {len(loops)} combinational loop(s) broken for analysis")

    worst = sorted(ep.items(), key=lambda kv: -kv[1][0])
    if not worst:
        print("no sequential endpoints found"); return
    top_lvl = worst[0][1][0]
    print(f"\nworst register-to-register depth : {top_lvl} levels"
          f"   -> est. {top_lvl * a.ns_per_level:.1f} ns"
          f" = {1000.0 / (top_lvl * a.ns_per_level):.1f} MHz")

    print(f"\ndeepest {a.top} endpoints:")
    for cname, (lv, via) in worst[:a.top]:
        print(f"  {lv:4d}  {prefix_of(cname):28s} {cname[:70]}")

    print("\ndepth histogram (endpoints at or above each level):")
    lv_list = sorted((v[0] for v in ep.values()), reverse=True)
    budget = int(round(20.0 / a.ns_per_level))     # levels that fit in 20 ns
    for thr in sorted({top_lvl, int(top_lvl * .8), int(top_lvl * .6),
                       int(top_lvl * .4), budget}, reverse=True):
        if thr < 1:
            continue
        n = sum(1 for x in lv_list if x >= thr)
        note = "   <- over the 50 MHz budget" if thr == budget else ""
        print(f"  >= {thr:4d} levels : {n:6d} of {len(lv_list)}{note}")

    print("\ndepth by module prefix (deepest endpoint in each):")
    bym = collections.defaultdict(int)
    for cname, (lv, _) in ep.items():
        p = prefix_of(cname)
        bym[p] = max(bym[p], lv)
    for p, lv in sorted(bym.items(), key=lambda kv: -kv[1])[:8]:
        print(f"  {lv:4d}  {p}")


if __name__ == "__main__":
    main()

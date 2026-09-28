#!/usr/bin/env python3
"""Real ECP5 Fmax measurement + critical-path attribution for the MH030 cores.

Two subcommands:

    measure_fmax.py run     [--soc-dir DIR] [--top TOP] [--tag NAME]
    measure_fmax.py analyze REPORT.json [--top-modules N]

`run` performs a full synthesis + place-and-route using the KNOWN-GOOD
timing recipe and then analyses the resulting report.  `analyze` skips
straight to the analysis of an existing report, which is what you want most
of the time -- a real `run` takes roughly 3 hours.

WHY THIS SCRIPT EXISTS
----------------------
Before this, there was no timing target at all, and two separate
measurements were wasted on the wrong recipe.  mackerel-030f's own
`Makefile` `$(BIT)` target uses:

    synth_lattice -family ecp5 -top ... -run begin:map_luts
    abc -lut 4

That recipe exists to *generate a bitstream*, and it is INVALID for timing
measurement: it emits ~1,360 spurious "conflicting drivers" warnings and
finishes in about two minutes instead of the real ~3h ABC9 run.  The valid
recipe -- the one every trustworthy measurement in this project's history
used -- is the plain, unrestricted `synth_lattice`, which is what `run`
below does.  Do not "optimise" it.

ON ATTRIBUTION
--------------
nextpnr names synthesised cells after the nearest still-traceable ancestor
register, so a suffix like `wb_result_TRELLIS_FF_...` does NOT mean the
delay belongs to `wb_result`; ABC9 may have created that cell many hops
away.

**THE DOTTED PREFIX IS NOT TRUSTWORTHY EITHER.**  This script used to claim
it was, and that claim is false, checked against a known ground truth: in
the flattened MH030-P build every one of the five MULT18X18D cells -- which
can only be mh030p_mul's, inside u_core -- is named
`u_dut.u_ifu.req_epoch_LUT4_D_Z_...`.  ABC9 carries the surviving ancestor's
whole hierarchy path, so a merged cell can be attributed to a module it has
nothing to do with.  The per-module figures this script prints are therefore
INDICATIVE ONLY and must not be used to decide where to work.

For real attribution use `make area-p` (synthesis with `-noflatten`, counting
each module's own cells) -- see scripts/module_area.py.

A note on `detailed_net_timings`: its per-endpoint `delay` is that net's own
routing delay, NOT a cumulative arrival time at the endpoint.  Earlier
sessions quoted a "per-endpoint worst-case arrival" / "failing endpoint
count" figure; that number is not directly present in this report and is not
reproduced here.  What IS directly present, and is what this script reports,
is the fully enumerated worst critical path with a per-hop delay and type.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from collections import Counter, OrderedDict

DEFAULT_SOC_DIR = os.path.expanduser("~/mackerel-030f/pld/mackerel-030f")
OSS_CAD = os.path.expanduser("~/oss-cad-suite/bin")


# ─────────────────────────── attribution helpers ────────────────────────────

def module_of(cell):
    """Hierarchical instance prefix of a synthesised cell name.

    'u_cpu.u_biu.u_cache.addr_r_TRELLIS_FF_Q_1_DI_LUT4...' -> 'u_cpu.u_biu.u_cache'
    A cell with no dot at all is top-level glue; report it as '<top>'.
    """
    return cell.rsplit(".", 1)[0] if "." in cell else "<top>"


def analyse_path(path):
    """Summarise one critical path: totals, per-type split, per-module split,
    and the ordered sequence of modules the path actually walks through."""
    by_type = Counter()
    by_module = Counter()
    hops_by_module = Counter()
    walk = []          # ordered module transitions, with delay accumulated

    for hop in path:
        delay = hop.get("delay", 0.0) or 0.0
        by_type[hop.get("type", "?")] += delay

        # Attribute a hop to where it LANDS; that is the cell being driven.
        cell = (hop.get("to") or {}).get("cell", "")
        mod = module_of(cell) if cell else "<unknown>"
        by_module[mod] += delay
        hops_by_module[mod] += 1

        if not walk or walk[-1][0] != mod:
            walk.append([mod, delay, 1])
        else:
            walk[-1][1] += delay
            walk[-1][2] += 1

    return {
        "total_ns": sum(by_type.values()),
        "hops": len(path),
        "by_type": by_type,
        "by_module": by_module,
        "hops_by_module": hops_by_module,
        "walk": walk,
    }


def fmt_row(name, ns, total, extra=""):
    pct = (100.0 * ns / total) if total else 0.0
    return f"  {name:<46s} {ns:9.2f} ns  {pct:5.1f}%  {extra}"


# ──────────────────────────────── analysis ──────────────────────────────────

def do_analyze(report_path, top_modules=12, walk_limit=40):
    with open(report_path) as fh:
        report = json.load(fh)

    print(f"Report: {report_path}")
    print()

    # ── Achieved frequency ──────────────────────────────────────────────
    print("=" * 78)
    print("ACHIEVED FREQUENCY")
    print("=" * 78)
    for clk, info in sorted(report.get("fmax", {}).items()):
        achieved = info.get("achieved", 0.0)
        constraint = info.get("constraint", 0.0)
        period = (1000.0 / achieved) if achieved else float("inf")
        budget = (1000.0 / constraint) if constraint else float("inf")
        short = "MET" if achieved >= constraint else f"{constraint / achieved:.1f}x SHORT"
        print(f"  {clk}")
        print(f"    achieved   {achieved:8.2f} MHz   (period {period:8.2f} ns)")
        print(f"    constraint {constraint:8.2f} MHz   (budget {budget:8.2f} ns)   -> {short}")
    print()

    # ── Utilisation, with the LUT:FF ratio that motivated the rewrite ───
    util = report.get("utilization", {})
    comb = util.get("TRELLIS_COMB", {})
    ff = util.get("TRELLIS_FF", {})
    if comb.get("used") and ff.get("used"):
        print("=" * 78)
        print("UTILIZATION")
        print("=" * 78)
        for name in ("TRELLIS_COMB", "TRELLIS_FF", "DP16KD", "MULT18X18D"):
            u = util.get(name, {})
            if u.get("used"):
                avail = u.get("available", 0)
                pct = (100.0 * u["used"] / avail) if avail else 0.0
                print(f"  {name:<16s} {u['used']:7d} / {avail:<7d} ({pct:4.1f}%)")
        ratio = comb["used"] / ff["used"]
        verdict = "combinational-cone signature" if ratio > 3.0 else "reasonably pipelined"
        print(f"  LUT:FF ratio     {ratio:7.2f} : 1   <- {verdict}")
        print("                                   (a well-pipelined core sits near 1.5:1)")
        print()

    # ── Critical paths ──────────────────────────────────────────────────
    paths = report.get("critical_paths", [])
    reg2reg = [p for p in paths
               if "async" not in p.get("from", "") and "async" not in p.get("to", "")]
    if not reg2reg:
        print("No register-to-register critical path in this report.")
        return 0

    worst = max(reg2reg, key=lambda p: sum((h.get("delay") or 0.0) for h in p["path"]))
    summary = analyse_path(worst["path"])
    total = summary["total_ns"]

    print("=" * 78)
    print("WORST REGISTER-TO-REGISTER PATH")
    print("=" * 78)
    print(f"  {worst['from']}  ->  {worst['to']}")
    print(f"  total {total:.2f} ns over {summary['hops']} hops"
          f"  (implies {1000.0 / total:.2f} MHz for this path alone)")
    print()

    print("  Delay by type:")
    for kind, ns in summary["by_type"].most_common():
        print(fmt_row(kind, ns, total))
    print()

    print(f"  Delay by module (top {top_modules}, attributed by hierarchical prefix only):")
    for mod, ns in summary["by_module"].most_common(top_modules):
        print(fmt_row(mod, ns, total, extra=f"{summary['hops_by_module'][mod]:5d} hops"))
    print()

    # The module walk is the "shape of the chain" -- which subsystems the
    # path crosses, in order.  This is what previous investigations were
    # reconstructing by hand.
    walk = summary["walk"]
    print(f"  Module walk ({len(walk)} transitions; showing"
          f"{' first ' + str(walk_limit) if len(walk) > walk_limit else ' all'}):")
    for mod, ns, hops in walk[:walk_limit]:
        print(f"    {ns:8.2f} ns  {hops:5d} hops  {mod}")
    if len(walk) > walk_limit:
        remaining = sum(w[1] for w in walk[walk_limit:])
        print(f"    ... {len(walk) - walk_limit} further transitions,"
              f" {remaining:.2f} ns")
    print()

    return 0


# ───────────────────────────── measurement run ──────────────────────────────

def do_run(soc_dir, top, tag, skip_synth):
    yosys = os.path.join(OSS_CAD, "yosys")
    nextpnr = os.path.join(OSS_CAD, "nextpnr-ecp5")
    for tool in (yosys, nextpnr):
        if not os.path.exists(tool):
            sys.exit(f"missing tool: {tool}")
    if not os.path.isdir(soc_dir):
        sys.exit(f"missing SoC dir: {soc_dir}")

    impl = os.path.join(soc_dir, "impl")
    os.makedirs(impl, exist_ok=True)
    stamp = tag or time.strftime("%Y%m%d-%H%M%S")
    json_out = os.path.join(impl, f"{top}.json")
    report = os.path.join(impl, f"timing_report-{stamp}.json")

    # Source list mirrors the SoC Makefile's GLUE_SRCS + UART_SRCS. flat.v is
    # produced by the SoC Makefile's own sv2v step; build it there first.
    flat = os.path.join(soc_dir, "flat.v")
    if not os.path.exists(flat):
        sys.exit(f"missing {flat} -- run 'make flat.v' in {soc_dir} first")

    glue = ["mackerel_030f.v", "clk_pll.v", "uart.v", "spi.v", "sdram_adapter.v",
            "vendor/sdram_16bit.v", "vendor/tiny_spi.v"]
    uart_dir = os.path.join(soc_dir, "../../cores/uart16550/rtl/verilog")
    uart = sorted(os.path.join(uart_dir, f)
                  for f in os.listdir(uart_dir) if f.endswith(".v")) \
        if os.path.isdir(uart_dir) else []

    if not skip_synth:
        # THE VALID RECIPE. Plain, unrestricted synth_lattice -- no
        # '-run begin:map_luts', no manual 'abc -lut 4'. See module docstring.
        script = (
            f"read_verilog flat.v; "
            f"read_verilog {' '.join(glue + uart)}; "
            f"synth_lattice -family ecp5 -top {top}; "
            f"write_json {json_out}"
        )
        print(f"[1/2] yosys (expect ~3h; the ABC9 stage dominates)")
        t0 = time.time()
        rc = subprocess.call([yosys, "-p", script], cwd=soc_dir)
        if rc != 0:
            sys.exit(f"yosys failed ({rc})")
        print(f"      yosys done in {(time.time() - t0) / 60:.1f} min")

    print(f"[2/2] nextpnr-ecp5")
    t0 = time.time()
    rc = subprocess.call([
        nextpnr, "--85k", "--package", "CABGA381",
        "--json", json_out,
        "--lpf", os.path.join(soc_dir, "ulx3s_v20.lpf"),
        "--ignore-loops", "--randomize-seed", "--timing-allow-fail",
        "--report", report, "--detailed-timing-report",
    ], cwd=soc_dir)
    if rc != 0:
        sys.exit(f"nextpnr failed ({rc})")
    print(f"      nextpnr done in {(time.time() - t0) / 60:.1f} min")
    print()

    return do_analyze(report)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="full synthesis + P&R, then analyse (~3h)")
    r.add_argument("--soc-dir", default=DEFAULT_SOC_DIR)
    r.add_argument("--top", default="mackerel_030f")
    r.add_argument("--tag", default=None, help="label for the report filename")
    r.add_argument("--skip-synth", action="store_true",
                   help="reuse the existing yosys JSON; re-run P&R only")

    a = sub.add_parser("analyze", help="analyse an existing timing report")
    a.add_argument("report")
    a.add_argument("--top-modules", type=int, default=12)

    args = ap.parse_args()
    if args.cmd == "run":
        return do_run(args.soc_dir, args.top, args.tag, args.skip_synth)
    return do_analyze(args.report, args.top_modules)


if __name__ == "__main__":
    sys.exit(main())

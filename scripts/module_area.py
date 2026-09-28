#!/usr/bin/env python3
"""Per-module combinational/FF counts from a HIERARCHY-PRESERVING netlist.

    module_area.py <netlist.json>

WHY THIS EXISTS. Cell names in a flattened synth_lattice netlist are NOT usable
for attribution, and this was discovered the hard way: in the flattened build of
MH030-P, all five MULT18X18D cells -- which are unambiguously mh030p_mul's,
inside u_core -- are named `u_dut.u_ifu.req_epoch_LUT4_D_Z_...`. ABC9 renames
merged cells after whatever ancestor register survived, INCLUDING its hierarchy
prefix, so even the dotted prefix lies. A whole session's worth of "67.8% of the
worst path is in the fetch unit" came from trusting it.

The fix is to synthesise with `-noflatten` and count each module's OWN cells,
which is what this script reports. Costs ~15 s and is the only attribution in
this project that has been checked against a known ground truth.
"""
import json, sys, collections

COMB = {'LUT4', 'CCU2C', 'PFUMX', 'L6MUX21', 'MULT18X18D'}

def main(path):
    mods = json.load(open(path))['modules']
    rows = []
    for name, m in mods.items():
        if name.startswith('$'):
            continue
        c = collections.Counter(x['type'] for x in m.get('cells', {}).values())
        comb = sum(v for k, v in c.items() if k in COMB)
        ff = c.get('TRELLIS_FF', 0)
        if comb or ff:
            rows.append((comb, ff, name, c.get('CCU2C', 0), c.get('MULT18X18D', 0)))
    rows.sort(reverse=True)
    tot = sum(r[0] for r in rows) or 1
    print(f"{'module (own cells only)':26s} {'comb':>7s} {'%':>6s} {'carry':>6s} {'DSP':>4s} {'FF':>6s}")
    for comb, ff, name, cc, dsp in rows:
        print(f"{name:26s} {comb:7d} {100*comb/tot:5.1f}% {cc:6d} {dsp:4d} {ff:6d}")
    print(f"{'TOTAL':26s} {tot:7d}")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

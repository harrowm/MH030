#!/usr/bin/env python3
"""Convert a VCD dump into a WaveDrom JSON timing-diagram spec.

Deliberately dependency-free (stdlib only) -- this project's own Python
tooling (tools/buscmp.py, scripts/run_harte.py, etc.) has no third-party
dependencies either, and this machine's system Python is externally
managed (PEP 668), making a one-off `pip install` for a VCD-parsing
library more friction than writing the ~100 lines needed to parse the
handful of VCD constructs this script actually needs.

VCD format notes (see IEEE 1364-2005 Annex A, or just Icarus's own output):
  - Header: `$var wire <width> <id> <name> [<msb>:<lsb>] $end` declares a
    signal. The SAME signal name can appear multiple times with DIFFERENT
    ids -- `$dumpvars(0, <top>)` dumps every hierarchical scope, and a
    port-connected net gets its own $var entry at every scope it passes
    through. Only the FIRST occurrence of a name (the top-level testbench
    signal itself, before any `$scope module <submodule>` line) is used
    here -- later occurrences are the same net re-declared deeper in the
    hierarchy and are ignored.
  - Value-change section: `#<time>` starts a new timestamp; each following
    line until the next `#` is either `<bit><id>` (1-bit, no space) or
    `b<binary> <id>` (multi-bit, space-separated).
"""
import argparse
import json
import re
import sys


def parse_vcd(path, wanted_names):
    """Returns (id_to_name, changes) where changes is {id: [(time, value_str), ...]}."""
    name_to_id = {}
    id_to_name = {}
    changes = {}
    in_header = True
    current_scope_depth = 0
    seen_scope = False
    t = 0

    var_re = re.compile(r'^\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)')
    with open(path, 'r') as f:
        for line in f:
            line = line.rstrip('\n')
            if in_header:
                if line.startswith('$scope'):
                    seen_scope = True
                    current_scope_depth += 1
                elif line.startswith('$upscope'):
                    current_scope_depth -= 1
                elif line.startswith('$var'):
                    m = var_re.match(line)
                    if m:
                        width, vid, name = m.group(1), m.group(2), m.group(3)
                        if name in wanted_names and name not in name_to_id:
                            name_to_id[name] = vid
                            id_to_name[vid] = name
                            changes[vid] = []
                elif line.startswith('$enddefinitions'):
                    in_header = False
                continue
            # Value-change section
            if not line:
                continue
            if line[0] == '#':
                t = int(line[1:])
                continue
            if line[0] == 'b':
                # b<binary> <id>
                parts = line[1:].split(' ', 1)
                if len(parts) != 2:
                    continue
                val, vid = parts[0], parts[1]
                if vid in changes:
                    changes[vid].append((t, val))
            else:
                # <bit><id>, no space
                bit, vid = line[0], line[1:]
                if vid in changes:
                    changes[vid].append((t, bit))

    if not name_to_id:
        sys.exit("No wanted signals found in VCD header -- check signal names")
    missing = wanted_names - set(name_to_id.keys())
    if missing:
        sys.exit(f"Signals not found in VCD: {sorted(missing)}")

    return name_to_id, changes


def value_at(changes_for_id, t):
    """Last known value of a signal at time t (VCD only records changes)."""
    val = None
    for (ct, cv) in changes_for_id:
        if ct > t:
            break
        val = cv
    return val


def bin_to_hex(binstr, nbits):
    if binstr is None:
        return None
    # VCD binary values can contain x/z; treat any of those as unknown.
    if any(c in binstr for c in 'xXzZ'):
        return None
    val = int(binstr, 2)
    hex_digits = (nbits + 3) // 4
    return format(val, f'0{hex_digits}x')


def build_columns(name_to_id, changes, clock_name, window_start, window_end):
    """One column per rising edge of `clock_name` within [window_start, window_end]."""
    clk_id = name_to_id[clock_name]
    edges = [t for (t, v) in changes[clk_id] if v == '1' and window_start <= t <= window_end]
    # De-duplicate / sort (VCD changes are already time-ordered, but be safe).
    edges = sorted(set(edges))
    return edges


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('vcd', help='input VCD file')
    ap.add_argument('-o', '--output', required=True, help='output WaveDrom JSON path')
    ap.add_argument('--clock', default='clk_4x', help='clock signal name (default: clk_4x)')
    ap.add_argument('--start-signal', default='ext_as_n',
                     help='signal whose first assertion (0) marks the window start')
    ap.add_argument('--margin-cycles', type=int, default=3,
                     help='idle clock cycles to show before/after the active window')
    args = ap.parse_args()

    # Signals shown in the diagram, top-to-bottom, matching Figure 7-21's
    # own layout as closely as this project's own pin set allows (SIZ1/SIZ0
    # split, A1/A0 split, /ECS/OCS not modeled as separate testbench probes
    # here -- only the signals this project's own m68030_biu actually
    # exposes as top-level ports are used).
    bus_signals = [
        ('ext_a',    'A2-A31', 32),
        ('ext_fc',   'FC0-FC2', 3),
        ('ext_siz',  'SIZ1-SIZ0', 2),
    ]
    level_signals = [
        ('ext_rw',     'R/W'),
        ('ext_as_n',   '/AS'),
        ('ext_ds_n',   '/DS'),
        ('dsack0_n',   '/DSACK0'),
        ('dsack1_n',   '/DSACK1'),
        ('ext_dben_n', '/DBEN'),
    ]
    data_signals = [
        ('ext_d_in', 'D0-D31 (read data)', 32),
    ]

    wanted = {args.clock, args.start_signal}
    wanted |= {n for n, _, _ in bus_signals}
    wanted |= {n for n, _ in level_signals}
    wanted |= {n for n, _, _ in data_signals}

    name_to_id, changes = parse_vcd(args.vcd, wanted)

    # Find the active window: the LAST time start-signal (active-low)
    # asserts ('0') before the end of the trace, through its next
    # deassertion. This testbench's own boot sequence (SSP/PC fetch) also
    # asserts /AS earlier in the trace -- the cycle this script actually
    # wants to render is always the final one before $finish, since that's
    # the one instruction the test explicitly drives via eu_req/eu_ack.
    start_id = name_to_id[args.start_signal]
    assert_t = None
    for (t, v) in changes[start_id]:
        if v == '0':
            assert_t = t
    if assert_t is None:
        sys.exit(f"{args.start_signal} never asserted -- nothing to render")
    deassert_t = assert_t
    for (t, v) in changes[start_id]:
        if v == '1' and t > assert_t:
            deassert_t = t
            break

    clk_id = name_to_id[args.clock]
    all_clk_times = sorted(set(t for (t, v) in changes[clk_id]))
    # clk_4x is a simple #5 toggle -> half-period is the gap between
    # consecutive recorded edges of either polarity.
    half_periods = [all_clk_times[i] - all_clk_times[i - 1] for i in range(1, len(all_clk_times))]
    half_period = min(half_periods) if half_periods else 5000
    margin = args.margin_cycles * 2 * half_period

    window_start = max(0, assert_t - margin)
    window_end = deassert_t + margin

    columns = build_columns(name_to_id, changes, args.clock, window_start, window_end)
    if len(columns) < 2:
        sys.exit("Fewer than 2 clock edges in window -- widen --margin-cycles")

    # Sample each signal once per column (at the column's own timestamp).
    def wave_for_level(name):
        vid = name_to_id[name]
        vals = [value_at(changes[vid], t) for t in columns]
        wave = ''
        prev = None
        for v in vals:
            if v is None:
                wave += 'x'
            elif v == prev:
                wave += '.'
            else:
                wave += v
            prev = v
        return wave

    def wave_and_data_for_bus(name, nbits):
        vid = name_to_id[name]
        vals = [value_at(changes[vid], t) for t in columns]
        hexvals = [bin_to_hex(v, nbits) for v in vals]
        wave = ''
        data = []
        prev = None
        for hv in hexvals:
            if hv is None:
                wave += 'x'
                prev = None
            elif hv == prev:
                wave += '.'
            else:
                wave += '='
                data.append(hv)
                prev = hv
        return wave, data

    def wave_for_clock():
        # One 'p' per column boundary -- WaveDrom draws a clean clock
        # trace; the actual column cadence already matches real clk_4x
        # edges, so this is a faithful (if not literally pixel-accurate
        # frequency-scaled) representation.
        return 'p' * len(columns)

    signal_list = []
    signal_list.append({'name': 'CLK (4x internal)', 'wave': wave_for_clock()})
    for name, label, nbits in bus_signals:
        wave, data = wave_and_data_for_bus(name, nbits)
        entry = {'name': label, 'wave': wave}
        if data:
            entry['data'] = data
        signal_list.append(entry)
    for name, label in level_signals:
        signal_list.append({'name': label, 'wave': wave_for_level(name)})
    signal_list.append({'name': '', 'wave': ''})  # spacer
    for name, label, nbits in data_signals:
        wave, data = wave_and_data_for_bus(name, nbits)
        entry = {'name': label, 'wave': wave}
        if data:
            entry['data'] = data
        signal_list.append(entry)

    spec = {
        'signal': signal_list,
        'config': {'hscale': 1},
    }

    with open(args.output, 'w') as f:
        json.dump(spec, f, indent=2)
    print(f"Wrote {args.output}: {len(columns)} columns, "
          f"window [{window_start}, {window_end}] ps")


if __name__ == '__main__':
    main()

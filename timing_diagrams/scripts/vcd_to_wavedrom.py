#!/usr/bin/env python3
"""Convert a VCD dump into a WaveDrom JSON timing-diagram spec.

Deliberately dependency-free (stdlib only) -- this project's own Python
tooling (tools/buscmp.py, scripts/run_harte.py, etc.) has no third-party
dependencies either, and this machine's system Python is externally
managed (PEP 668), making a one-off `pip install` for a VCD-parsing
library more friction than writing the ~200 lines needed to parse the
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
    `b<binary> <id>` (multi-bit, space-separated). Icarus can (harmlessly)
    write a same-value line more than once for a given id with no real
    edge in between -- `value_at()`'s "last known value at time t" lookup
    is naturally insensitive to this, so it's never worth de-duplicating.

Rendered signal set mirrors MC68030UM.pdf Figure 7-21's own layout as
closely as this project's own m68030_biu ports allow: address split into
A2-A31/A1/A0 (masking the low 2 bits out of A2-A31 so it reads as
constant across a same-longword chain, matching the manual), /ECS and
/OCS included (both are real m68030_biu ports), and the data bus split
into 4 byte lanes (D24-D31/D16-D23/D8-D15/D0-D7) with only the lane(s)
actually selected by SIZ+A1/A0 populated per column -- everything else
matches the underlying real value (mem_model.sv drives the full stored
longword on every access; the *display* re-derives which lanes a real
32-bit-port peripheral would actually be read from, the same computation
biu_byte_lane_ctrl.sv performs internally for writes).

A synthetic "S-STATE" lane is also emitted, derived directly from the
BIU's own `s_state` output: labeled sequentially (S0, S1, S2, ...) in
the order distinct state values are actually observed within each bus
cycle (reset at each ST_IDLE -> non-idle transition), NOT a hardcoded
reproduction of the RTL's internal enum names (which skip two of the
eight literal ST_READ_S* values for a plain read) -- this labeling is
therefore an honest, self-consistent report of what the RTL actually
does, not a claim that it matches the manual's own S0/S2/S4 numbering
label-for-label.
"""
import argparse
import json
import re
import sys


def parse_vcd(path, wanted_names):
    """Returns (name_to_id, changes) where changes is {id: [(time, value_str), ...]}."""
    name_to_id = {}
    changes = {}
    in_header = True
    t = 0

    var_re = re.compile(r'^\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)')
    with open(path, 'r') as f:
        for line in f:
            line = line.rstrip('\n')
            if in_header:
                if line.startswith('$var'):
                    m = var_re.match(line)
                    if m:
                        _width, vid, name = m.group(1), m.group(2), m.group(3)
                        if name in wanted_names and name not in name_to_id:
                            name_to_id[name] = vid
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
                parts = line[1:].split(' ', 1)
                if len(parts) != 2:
                    continue
                val, vid = parts[0], parts[1]
                if vid in changes:
                    changes[vid].append((t, val))
            else:
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


def bin_to_int(binstr):
    if binstr is None or any(c in binstr for c in 'xXzZ'):
        return None
    return int(binstr, 2)


def bin_to_hex(binstr, nbits):
    v = bin_to_int(binstr)
    if v is None:
        return None
    hex_digits = (nbits + 3) // 4
    return format(v, f'0{hex_digits}x')


def find_last_n_windows(changes, start_id, n):
    """Returns the last N (assert_t, deassert_t) pairs of an active-low
    start signal, in chronological order. `assert_t` is when it goes to
    '0'; `deassert_t` is the next time it goes back to '1'."""
    pairs = []
    asserted_at = None
    for (t, v) in changes[start_id]:
        if v == '0' and asserted_at is None:
            asserted_at = t
        elif v == '1' and asserted_at is not None:
            pairs.append((asserted_at, t))
            asserted_at = None
    if len(pairs) < n:
        sys.exit(f"Only found {len(pairs)} complete assert/deassert windows, need {n}")
    return pairs[-n:]


def build_columns(changes, clk_id, window_start, window_end):
    """One column per rising edge of the clock within [window_start, window_end]."""
    edges = sorted(set(t for (t, v) in changes[clk_id] if v == '1' and window_start <= t <= window_end))
    return edges


ACTIVE_LOW_LEVEL_SIGNALS = [
    ('ext_as_n',   '/AS'),
    ('ext_ds_n',   '/DS'),
    ('dsack0_n',   '/DSACK0'),
    ('dsack1_n',   '/DSACK1'),
    ('ext_dben_n', '/DBEN'),
    ('ext_ecs_n',  '/ECS'),
    ('ext_ocs_n',  '/OCS'),
]

# byte_index -> (bit_hi, bit_lo) within a 32-bit big-endian D0-D31 bus,
# and the SIZ=byte A1/A0 encoding that selects it directly.
BYTE_LANES = [
    (0, 'D24-D31'),  # bits [31:24], A1A0=00
    (1, 'D16-D23'),  # bits [23:16], A1A0=01
    (2, 'D8-D15'),   # bits [15:8],  A1A0=10
    (3, 'D0-D7'),    # bits [7:0],   A1A0=11
]


def active_lanes(siz_val, a1a0):
    """Which of the 4 byte lanes (0=D31-24 .. 3=D7-0) a 32-bit port drives
    for a given SIZ[1:0] + A[1:0], per biu_byte_lane_ctrl.sv's own steering
    rule (mirrored here for display, not re-derived from the RTL)."""
    if siz_val == 0b00:      # longword: all 4 lanes
        return {0, 1, 2, 3}
    if siz_val == 0b10:      # word: A1 selects the upper or lower half
        a1 = (a1a0 >> 1) & 1
        return {0, 1} if a1 == 0 else {2, 3}
    if siz_val == 0b01:      # byte: A1A0 selects exactly one lane
        return {a1a0}
    return {0, 1, 2, 3}       # line/burst -- not used by this diagram


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('vcd', help='input VCD file')
    ap.add_argument('-o', '--output', required=True, help='output WaveDrom JSON path')
    ap.add_argument('--clock', default='clk_4x', help='clock signal name (default: clk_4x)')
    ap.add_argument('--start-signal', default='ext_as_n',
                     help='active-low signal whose assert/deassert marks one bus cycle')
    ap.add_argument('--cycles', type=int, default=3,
                     help='number of trailing back-to-back bus cycles to render (default: 3)')
    ap.add_argument('--margin-cycles', type=int, default=3,
                     help='idle clock cycles to show before/after the active window')
    args = ap.parse_args()

    bus_signals = [
        ('ext_fc',  'FC0-FC2', 3),
        ('ext_siz', 'SIZ1-SIZ0', 2),
    ]

    wanted = {args.clock, args.start_signal, 'ext_a', 'ext_siz', 'ext_d_in', 's_state'}
    wanted |= {n for n, _, _ in bus_signals}
    wanted |= {n for n, _ in ACTIVE_LOW_LEVEL_SIGNALS}
    wanted.add('ext_rw')

    name_to_id, changes = parse_vcd(args.vcd, wanted)

    start_id = name_to_id[args.start_signal]
    windows = find_last_n_windows(changes, start_id, args.cycles)
    assert_t = windows[0][0]
    deassert_t = windows[-1][1]

    clk_id = name_to_id[args.clock]
    all_clk_times = sorted(set(t for (t, v) in changes[clk_id]))
    half_periods = [all_clk_times[i] - all_clk_times[i - 1] for i in range(1, len(all_clk_times))]
    half_period = min(half_periods) if half_periods else 5000
    margin = args.margin_cycles * 2 * half_period

    window_start = max(0, assert_t - margin)
    window_end = deassert_t + margin

    columns = build_columns(changes, clk_id, window_start, window_end)
    if len(columns) < 2:
        sys.exit("Fewer than 2 clock edges in window -- widen --margin-cycles")

    def wave_for_level(name):
        vid = name_to_id[name]
        wave = ''
        prev = None
        for t in columns:
            v = value_at(changes[vid], t)
            if v is None:
                wave += 'x'
                prev = None
            elif v == prev:
                wave += '.'
            else:
                wave += v
                prev = v
        return wave

    def wave_and_data_for_bus(name, nbits, mask_low_bits=0):
        vid = name_to_id[name]
        wave = ''
        data = []
        prev = None
        for t in columns:
            raw = value_at(changes[vid], t)
            iv = bin_to_int(raw)
            if iv is not None and mask_low_bits:
                iv &= ~((1 << mask_low_bits) - 1)
            hv = None if iv is None else format(iv, f'0{(nbits + 3) // 4}x')
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

    def wave_for_addr_bit(bit_index):
        vid = name_to_id['ext_a']
        wave = ''
        prev = None
        for t in columns:
            raw = value_at(changes[vid], t)
            iv = bin_to_int(raw)
            bitval = 'x' if iv is None else str((iv >> bit_index) & 1)
            wave += '.' if bitval == prev else bitval
            prev = bitval
        return wave

    def wave_and_data_for_byte_lane(byte_idx):
        # Gated on /DBEN rather than /AS: /DBEN is the manual's own "data
        # bus enable" signal (asserted once the device is expected to be
        # presenting valid data, MC68030UM.pdf S2/table 7-x), so gating on
        # it (rather than the wider /AS window) avoids showing a value
        # before the bus cycle has actually reached that point -- matching
        # the manual's own single clean data-valid box per cycle instead of
        # a spurious one-column "00" placeholder at the very start of /AS.
        dben_vid = name_to_id['ext_dben_n']
        siz_vid = name_to_id['ext_siz']
        a_vid = name_to_id['ext_a']
        d_vid = name_to_id['ext_d_in']
        wave = ''
        data = []
        prev_kind = None  # None | 'blank' | 'data'
        prev_hex = None
        for t in columns:
            dben_v = value_at(changes[dben_vid], t)
            siz_iv = bin_to_int(value_at(changes[siz_vid], t))
            a_iv = bin_to_int(value_at(changes[a_vid], t))
            d_iv = bin_to_int(value_at(changes[d_vid], t))
            hv = None
            if dben_v == '0' and siz_iv is not None and a_iv is not None and d_iv is not None:
                lanes = active_lanes(siz_iv, a_iv & 0b11)
                if byte_idx in lanes:
                    shift = (3 - byte_idx) * 8
                    hv = format((d_iv >> shift) & 0xFF, '02x')
            if hv is None:
                wave += '.' if prev_kind == 'blank' else '0'
                prev_kind, prev_hex = 'blank', None
            elif hv == prev_hex and prev_kind == 'data':
                wave += '.'
            else:
                wave += '='
                data.append(hv)
                prev_kind, prev_hex = 'data', hv
        return wave, data

    def wave_for_clock():
        return 'p' * len(columns)

    def wave_for_state():
        """Sequential S0/S1/... labels derived from real s_state transitions,
        renumbered from 0 at each ST_IDLE -> non-idle boundary (ST_IDLE == 1,
        confirmed against rtl/biu_cycle_gen.sv's own enum)."""
        vid = name_to_id['s_state']
        wave = ''
        data = []
        prev_raw = None
        label_n = None  # None while idle
        for t in columns:
            raw = value_at(changes[vid], t)
            iv = bin_to_int(raw)
            if iv is None:
                wave += 'x'
                prev_raw = None
                label_n = None
                continue
            if iv == 1:  # ST_IDLE
                if prev_raw == 1:
                    wave += '.'
                else:
                    wave += '='
                    data.append('--')
                prev_raw = 1
                label_n = None
                continue
            if prev_raw == iv:
                wave += '.'
            else:
                if label_n is None:
                    label_n = 0
                else:
                    label_n += 1
                wave += '='
                data.append(f'S{label_n}')
                prev_raw = iv
        return wave, data

    signal_list = [{'name': 'CLK (4x internal)', 'wave': wave_for_clock()}]

    st_wave, st_data = wave_for_state()
    signal_list.append({'name': 'S-STATE (RTL)', 'wave': st_wave, 'data': st_data})

    addr_wave, addr_data = wave_and_data_for_bus('ext_a', 32, mask_low_bits=2)
    signal_list.append({'name': 'A2-A31', 'wave': addr_wave, 'data': addr_data})
    signal_list.append({'name': 'A1', 'wave': wave_for_addr_bit(1)})
    signal_list.append({'name': 'A0', 'wave': wave_for_addr_bit(0)})

    for name, label, nbits in bus_signals:
        wave, data = wave_and_data_for_bus(name, nbits)
        entry = {'name': label, 'wave': wave}
        if data:
            entry['data'] = data
        signal_list.append(entry)

    signal_list.append({'name': 'R/W', 'wave': wave_for_level('ext_rw')})
    for name, label in ACTIVE_LOW_LEVEL_SIGNALS:
        signal_list.append({'name': label, 'wave': wave_for_level(name)})

    signal_list.append({'name': '', 'wave': ''})  # spacer
    for byte_idx, label in BYTE_LANES:
        wave, data = wave_and_data_for_byte_lane(byte_idx)
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
          f"{args.cycles} cycle(s), window [{window_start}, {window_end}] ps")


if __name__ == '__main__':
    main()

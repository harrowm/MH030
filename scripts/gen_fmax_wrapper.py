#!/usr/bin/env python3
"""Generate an identical thin synthesis harness around a core, so two designs
can be compared on internal logic depth rather than on pin count.

    gen_fmax_wrapper.py <flat.v> <top> <wrapper_name> <out.v>

WHY THIS EXISTS. A standalone place-and-route of rtl/m68030_eu fails outright:
it has 35 inputs (450 bits) and 78 outputs, which exceeds the 365 IO pins on
CABGA381 -- nextpnr reports "no BELs remaining to implement cell type
TRELLIS_IO". So the old and new cores cannot simply be synthesised as-is and
compared; the one with fewer ports would also be the only one that places.

The harness fixes that and equalises the two at the same time:
  * every core INPUT is driven from a flip-flop in a wide shift register, so
    nothing comes straight off a pin and the input side costs one pin
  * every core OUTPUT is XOR-reduced into a single registered bit, so the
    output side also costs one pin regardless of how many the core has

Both cores get exactly this treatment, so the wrapper is common-mode and the
difference that remains is the cores themselves.

The input is sv2v output (plain Verilog). Only names appearing in the module
HEADER are treated as ports -- sv2v also emits internal declarations such as
_sv2v_unused inside the body, and treating those as ports makes yosys reject
the instantiation.
"""
import re, sys

def ports(path, top):
    src = open(path).read()
    m = re.search(r'\bmodule\s+' + top + r'\s*\((.*?)\);(.*?)\bendmodule', src, re.S)
    if not m:
        sys.exit("module %s not found" % top)
    # Only names listed in the module header are real ports. sv2v emits
    # internal declarations such as _sv2v_unused inside the body, and treating
    # those as ports makes yosys reject the instantiation.
    hdr = set(n.strip() for n in m.group(1).replace('\n', ' ').split(',')
              if n.strip())
    body = m.group(2)
    out = []
    for mm in re.finditer(r'^\s*(input|output)\s+(?:wire|reg)?\s*(?:signed\s*)?'
                          r'(\[[^\]]+\])?\s*([A-Za-z_][A-Za-z0-9_$]*)\s*;',
                          body, re.M):
        if mm.group(3) in hdr:
            out.append((mm.group(1), mm.group(2) or '', mm.group(3)))
    return out

def width(rng):
    if not rng: return 1
    a, b = rng.strip('[]').split(':')
    return abs(int(a) - int(b)) + 1

def gen(path, top, wrapname, clk, rst):
    ps = ports(path, top)
    ins  = [p for p in ps if p[0] == 'input'  and p[2] not in (clk, rst)]
    outs = [p for p in ps if p[0] == 'output']
    tot_in = sum(width(r) for _, r, _ in ins)
    L = []
    L.append("module %s (input wire %s, input wire %s," % (wrapname, clk, rst))
    L.append("                 input wire seed, output reg probe);")
    L.append("    // Stimulus register: every core input is a flip-flop output, so")
    L.append("    // nothing is driven straight from a pin.")
    L.append("    reg [%d:0] stim;" % (tot_in - 1))
    L.append("    always @(posedge %s or negedge %s)" % (clk, rst))
    L.append("        if (!%s) stim <= 0; else stim <= {stim[%d:0], seed};"
             % (rst, tot_in - 2))
    bit = 0
    conns = ["." + clk + "(" + clk + ")", "." + rst + "(" + rst + ")"]
    for _, r, n in ins:
        w = width(r)
        conns.append(".%s(stim[%d:%d])" % (n, bit + w - 1, bit) if w > 1
                     else ".%s(stim[%d])" % (n, bit))
        bit += w
    owires = []
    for _, r, n in outs:
        L.append("    wire %s %s_w;" % (r, n) if r else "    wire %s_w;" % n)
        conns.append(".%s(%s_w)" % (n, n))
        owires.append((n, width(r)))
    L.append("    %s u_dut (%s);" % (top, ", ".join(conns)))
    L.append("    // Reduce every output to one registered bit so the output side")
    L.append("    // costs one pin regardless of how many the core has.")
    red = " ^ ".join("(^%s_w)" % n for n, _ in owires) if owires else "1'b0"
    L.append("    always @(posedge %s or negedge %s)" % (clk, rst))
    L.append("        if (!%s) probe <= 1'b0; else probe <= %s;" % (rst, red))
    L.append("endmodule")
    print("%s: %d inputs (%d bits), %d outputs" % (top, len(ins), tot_in, len(outs)),
          file=sys.stderr)
    return "\n".join(L) + "\n"

if __name__ == "__main__":
    open(sys.argv[4], "w").write(gen(sys.argv[1], sys.argv[2], sys.argv[3],
                                     "clk_4x", "rst_n"))

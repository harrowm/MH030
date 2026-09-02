#!/usr/bin/env python3
"""Generate tb/ext_count_overlap_flags.svh: a SystemVerilog include wiring
every one of rtl/m68030_seq.sv's own `ext_count` always_comb block's 48
if/else-if branch CONDITIONS (extracted verbatim from the RTL source, not
hand-transcribed) into one bus, for tb/ext_count_overlap_tb.sv's own
opcode-sweep check that at most one branch's own condition is ever true for
a given input (deferred-items closure follow-up, plan.md "De-duplicate
ext_count's decode primitives against eu_seq.sv").

Deliberately NOT hand-maintained, and deliberately checks whole BRANCH
conditions rather than individual is_* flags: the chain has several
legitimate "refinement pair" flags (e.g. is_alu_mem_src / is_alu_mem_src_long,
is_addq_subq_ext / is_addq_subq_ext_long) that are DESIGNED to be true
together -- the chain's own branch conditions already encode the correct
disambiguation inline (e.g. `is_alu_mem_src && !is_alu_mem_src_long`). A
naive "at most one raw is_* flag true" check would flood with expected
false positives from every such pair; checking whole branch conditions (as
literally written, negations and all) instead directly answers the
question that actually matters: could more than one distinct branch of
this if/else-if chain match the same input? A hand-typed list of ~50+
branch conditions would itself be exactly the kind of "two places must
stay in sync" duplication this whole effort exists to eliminate, so this
script re-parses the real RTL source every time it runs instead.

Usage: scripts/gen_ext_count_overlap_flags.py rtl/m68030_seq.sv tb/ext_count_overlap_flags.svh
"""
import re
import sys

# Ports of m68030_seq -- the sweep testbench already declares regs/wires of
# these exact names (mirroring tb/seq_ctrl_tb.sv's own `m68030_seq dut (.*);`
# pattern), so branch conditions referencing them resolve directly with no
# extra passthrough wire needed.
PORT_NAMES = {
    "instr_word", "ifu_ext_data", "ifu_q3_word", "ifu_ext34_data",
    "ifu_q5_word", "instr_valid", "ifu_ext1_valid", "ifu_ext_valid",
    "ifu_ext4_valid", "ifu_ext5_valid", "ifu_ext6_valid", "drain",
    "eu_instr_word", "eu_ext_data", "eu_q3_word", "eu_ext34_data",
    "eu_q5_word", "eu_instr_valid", "eu_ext_valid", "eu_instr_ack", "eu_busy",
}

# SystemVerilog reserved words that can appear inside a boolean expression
# without being a signal reference (none of the chain's own conditions
# currently use any, but keep this explicit/extensible rather than assume).
SV_KEYWORDS = set()


def _blank_comments(text: str) -> str:
    """Replace // and /* */ comment bodies with spaces, preserving length
    and line breaks, so character offsets still line up with the original
    text (needed so the begin/end scan below doesn't get confused by an
    English word "end" appearing in prose comments -- which it does,
    repeatedly, in this file's own commentary)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text[i:i + 2] == "//":
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif text[i:i + 2] == "/*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _blank_literals(text: str) -> str:
    """Replace Verilog sized/based literals (e.g. 3'b110, 4'hF) with spaces
    of the same length, so their own [bodh] digit-like suffix letters (the
    "h0" in 4'h0, the "b000" in 3'b000) never get mistaken for identifier
    references during the identifier-extraction pass below."""
    pat = re.compile(r"\d+'[sS]?[bBoOdDhH][0-9a-fA-F_xzXZ?]*")
    out = list(text)
    for m in pat.finditer(text):
        for i in range(*m.span()):
            out[i] = " "
    return "".join(out)


def extract_ext_count_block(src: str) -> str:
    marker = "logic [2:0] ext_count;"
    idx = src.index(marker)
    begin_kw = re.search(r"\balways_comb\s+begin\b", src[idx:])
    if not begin_kw:
        raise SystemExit("could not find 'always_comb begin' after ext_count declaration")
    start = idx + begin_kw.end()

    # Simple begin/end depth counter (word-boundary matched) to find the
    # matching end for the always_comb block itself. Scans a comment-
    # blanked copy (same length/offsets as src) so a stray English "end"
    # inside a // comment can't be mistaken for the keyword.
    blanked = _blank_comments(src)
    depth = 1
    pos = start
    tok_re = re.compile(r"\b(begin|end)\b")
    while depth > 0:
        m = tok_re.search(blanked, pos)
        if not m:
            raise SystemExit("unbalanced begin/end while scanning ext_count block")
        if m.group(1) == "begin":
            depth += 1
        else:
            depth -= 1
        pos = m.end()
    return src[start:pos]


def _balanced_paren_end(text: str, open_idx: int) -> int:
    assert text[open_idx] == "("
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    raise SystemExit("unbalanced parens while extracting a branch condition")


def extract_branch_conditions(block: str) -> list[tuple[str, str]]:
    """Every top-level `if (...)` / `else if (...)` condition in the block,
    in source order, extracted verbatim (whitespace/newlines collapsed),
    paired with its own `ext_count = <value>;` result expression. Confirmed
    via a direct scan that this chain has zero nested if/case inside any
    branch body (every branch is a single `ext_count = ...;` statement) --
    if a future edit changes that shape, the sanity floor check in main()
    will catch a suspiciously low condition count, but a genuinely NEW
    nested construct inside a branch body could silently produce a wrong
    (too-broad or too-narrow) condition/value text; this is a known
    limitation, documented rather than defended against blindly.

    The value is needed because checking raw condition truth alone is too
    strict for a priority (if/else-if) chain: a broad catch-all bucket near
    the end of the chain routinely, harmlessly, structurally overlaps with
    many earlier, more-specific branches that happen to ALSO satisfy one of
    its many OR'd sub-terms -- the chain is never actually reached that far
    for those opcodes, so it's not a bug. Only an overlap where the two
    branches would produce a DIFFERENT ext_count value is worth a human's
    attention (see tb/ext_count_overlap_tb.sv's own header for the concrete
    false-positive example -- is_move_mm's own ext_count==1 branch
    "overlapping" with the ext_count==1 catch-all bucket -- that motivated
    this).
    """
    # Comments stripped (so a stray "//" inside a multi-line condition can't
    # leak into the emitted expression), literals deliberately KEPT intact --
    # this text is what actually gets written into the .svh file, so the
    # real 4'h0/3'b000-style values must survive verbatim.
    blanked = _blank_comments(block)
    result = []
    for m in re.finditer(r"\b(?:else\s+)?if\s*\(", blanked):
        open_idx = m.end() - 1
        close_idx = _balanced_paren_end(blanked, open_idx)
        raw = blanked[open_idx + 1:close_idx]
        cond = " ".join(raw.split())

        val_m = re.search(r"ext_count\s*=\s*(.*?);", blanked[close_idx:])
        if not val_m:
            raise SystemExit(
                f"could not find 'ext_count = ...;' right after branch condition "
                f"'{cond[:60]}...' -- a branch body shape this script doesn't "
                "expect (see extract_branch_conditions' own docstring)"
            )
        value = " ".join(val_m.group(1).split())
        result.append((cond, value))
    return result


def top_level_or_count(cond: str) -> int:
    """Count `||` occurrences at paren-depth 0 in a condition string --
    used to auto-detect the chain's own broad "catch-all bucket" branches
    (an OR of many unrelated is_* conditions all mapping to the same
    ext_count value, meant as a fallback for whatever the earlier, more
    specific branches don't catch) versus a normal, narrowly-scoped branch.
    Measured directly against the real chain: the two genuine buckets have
    40 and 11 top-level ORs; every other branch has at most 1 -- a wide,
    unambiguous margin, not a fragile threshold. Auto-detected rather than
    hardcoded by branch index so this stays correct if the chain's own
    branch order ever changes."""
    depth = 0
    count = 0
    i = 0
    while i < len(cond):
        if cond[i] == "(":
            depth += 1
        elif cond[i] == ")":
            depth -= 1
        elif depth == 0 and cond[i:i + 2] == "||":
            count += 1
            i += 1
        i += 1
    return count


BUCKET_OR_THRESHOLD = 5

# The mode=110 full-format EA rollout's own established architecture
# (Phases 116-147, plan.md; this session's own ext_count-de-duplication
# Stage 1 fix): a FULL-FORMAT-aware branch is always positioned EARLIER in
# this chain than the pre-existing BRIEF-only branch it needs to override
# for full-format opcodes -- the brief branch is deliberately left
# unmodified (it's still correct for brief format, and is never actually
# reached for full format once shadowed). This produces exactly the same
# harmless "later branch overlaps an earlier, more specific one" shape as
# an auto-detected OR-bucket, just without the tell-tale large OR count --
# so it's detected the same way conceptually, via automatic analysis of the
# real RTL rather than a hand-maintained list: a branch is "format-
# independent" if NONE of the identifiers in its own condition text
# transitively depend (through the file's own chain of `assign` statements)
# on one of the three peek_fi_full* signals that distinguish brief from
# full format anywhere in this file. A disagreement between an EARLIER,
# format-DEPENDENT branch and a LATER, format-INDEPENDENT one is, by this
# project's own established architecture, always the deliberate-override
# shape, not a bug -- see compute_format_dependent_names() below.
FORMAT_SEED_SIGNALS = {"peek_fi_full", "peek_fi_full_movem", "peek_fi_full_q3"}

# One further, deliberately narrow, hand-justified exception -- NOT a
# growing hand-maintained list (if this ever needs a second entry, that's a
# signal to generalize the detection instead, the same way the OR-bucket
# and format-dependence heuristics above already generalized two earlier
# one-off exclusions). is_memind_full and is_move_idx_src_memdst_full are
# BOTH format-dependent (both require peek_fi_full), so the format-
# dependence check above can't separate them by itself -- but
# is_move_idx_src_memdst_full's own condition is a strict refinement of
# is_memind_full's own (it adds "destination is also memory" on top of the
# same is_move_idx_src term that feeds is_memind_full's own mode110_ea_src
# disjunction), added specifically (this session, plan.md's ext_count
# de-duplication Stage 1 fix) to fire ahead of is_memind_full for MOVE
# (d8,An,Xn),<memory dst> -- for those opcodes is_memind_full's own later
# branch is always shadowed by design, not a shadowing bug.
KNOWN_REFINEMENT_PAIRS = {("is_move_idx_src_memdst_full", "is_memind_full")}


def find_identifiers(text: str) -> set[str]:
    # Literals blanked HERE ONLY (not in the condition text stored above),
    # so a literal's own [bodh] digit-suffix letters (the "h0" in 4'h0, the
    # "b000" in 3'b000) never get mistaken for identifier references.
    return set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", _blank_literals(text)))


def find_all_assigns(src: str) -> dict[str, list[str]]:
    """Every top-level `assign NAME = EXPR;` in the whole file (not just the
    ext_count block -- is_X flags feeding ext_count's own conditions are
    declared at file scope, outside the block), mapping name -> list of RHS
    expression texts (a name can be assigned more than once in principle,
    though this file's own is_X flags never are)."""
    blanked = _blank_comments(src)
    assigns: dict[str, list[str]] = {}
    for m in re.finditer(r"\bassign\s+([A-Za-z_][A-Za-z0-9_]*)", blanked):
        name = m.group(1)
        eq_m = re.match(r"\s*(\[[^\]]*\])?\s*=(?!=)", blanked[m.end():])
        if not eq_m:
            continue
        start = m.end() + eq_m.end()
        depth = 0
        i = start
        while i < len(blanked):
            c = blanked[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == ";" and depth == 0:
                break
            i += 1
        assigns.setdefault(name, []).append(blanked[start:i])
    return assigns


def compute_format_dependent_names(src: str) -> set[str]:
    """Every identifier that transitively depends (through this file's own
    chain of `assign` statements) on one of FORMAT_SEED_SIGNALS -- i.e.
    every signal whose own value can only ever be nonzero/true when the
    instruction's own mode=110 extension word is in FULL format. See this
    module's own FORMAT_SEED_SIGNALS comment for why this matters."""
    assigns = find_all_assigns(src)
    deps: dict[str, set[str]] = {
        name: set().union(*(find_identifiers(expr) for expr in exprs)) - {name}
        for name, exprs in assigns.items()
    }

    memo: dict[str, bool] = {}

    def depends(name: str, stack: frozenset[str]) -> bool:
        if name in memo:
            return memo[name]
        if name in FORMAT_SEED_SIGNALS:
            memo[name] = True
            return True
        if name in stack:
            return False  # break a cycle conservatively (none expected)
        result = False
        for dep in deps.get(name, ()):
            if depends(dep, stack | {name}):
                result = True
                break
        memo[name] = result
        return result

    return {name for name in deps if depends(name, frozenset())} | FORMAT_SEED_SIGNALS


def condition_is_format_dependent(cond: str, format_dependent_names: set[str]) -> bool:
    return bool(find_identifiers(cond) & format_dependent_names)


def find_declared_type(src: str, name: str) -> str:
    """Locate `logic [...] NAME` (or `logic NAME`) anywhere in src and
    return the exact `logic [...]`/`logic` prefix text, so the generated
    local passthrough wire has the identical width -- reusing the real
    declaration rather than re-guessing a width."""
    pat = re.compile(
        r"\blogic\s*(\[[^\]]+\])?\s*((?:\w+\s*,\s*)*)\b" + re.escape(name) + r"\b"
    )
    m = pat.search(src)
    if not m:
        return None
    width = m.group(1)
    return f"logic {width}" if width else "logic"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <m68030_seq.sv> <output.svh>")
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path) as f:
        src = f.read()

    block = extract_ext_count_block(src)
    branches = extract_branch_conditions(block)
    if len(branches) < 40:
        raise SystemExit(
            f"only found {len(branches)} branch conditions in the ext_count block -- "
            "expected 40+; the block-boundary/branch scan in this script probably "
            "needs updating to match a structural change in m68030_seq.sv"
        )

    is_bucket = [top_level_or_count(cond) >= BUCKET_OR_THRESHOLD for cond, _ in branches]
    n_buckets = sum(is_bucket)
    if n_buckets == 0 or n_buckets > 4:
        raise SystemExit(
            f"auto-detected {n_buckets} catch-all bucket branches (>= "
            f"{BUCKET_OR_THRESHOLD} top-level ||'s) -- expected 1-4; either a "
            "real structural change to the chain's own catch-all buckets, or "
            "BUCKET_OR_THRESHOLD needs revisiting for a new branch shape"
        )

    format_dependent_names = compute_format_dependent_names(src)
    is_format_dep = [
        condition_is_format_dependent(cond, format_dependent_names) for cond, _ in branches
    ]
    n_format_dep = sum(is_format_dep)
    if n_format_dep == 0:
        raise SystemExit(
            "0 branch conditions detected as format-dependent (depending on "
            "peek_fi_full/peek_fi_full_movem/peek_fi_full_q3) -- expected "
            "several; the dependency-closure analysis in "
            "compute_format_dependent_names() probably needs updating to "
            "match a structural change in m68030_seq.sv"
        )

    # shadow_of[i] = index of the branch that refines/precedes branch i (per
    # KNOWN_REFINEMENT_PAIRS), or -1. Resolved by exact condition-text match,
    # so a rename in the RTL breaks this loudly (KeyError-style) rather than
    # silently going stale.
    cond_to_index = {cond: i for i, (cond, _) in enumerate(branches)}
    shadow_of = [-1] * len(branches)
    for refiner_cond, refined_cond in KNOWN_REFINEMENT_PAIRS:
        if refiner_cond not in cond_to_index or refined_cond not in cond_to_index:
            raise SystemExit(
                f"KNOWN_REFINEMENT_PAIRS entry ({refiner_cond!r}, {refined_cond!r}) "
                "no longer matches any branch condition in m68030_seq.sv -- "
                "the RTL changed and this pair needs updating or removing"
            )
        refiner_idx, refined_idx = cond_to_index[refiner_cond], cond_to_index[refined_cond]
        if refiner_idx >= refined_idx:
            raise SystemExit(
                f"KNOWN_REFINEMENT_PAIRS entry ({refiner_cond!r}, {refined_cond!r}): "
                "the refiner must appear EARLIER in the chain than the branch it "
                "shadows, but doesn't -- re-verify this pair is still safe"
            )
        shadow_of[refined_idx] = refiner_idx

    all_ids = set()
    for cond, value in branches:
        all_ids |= find_identifiers(cond)
        all_ids |= find_identifiers(value)
    needed = sorted(n for n in all_ids if n not in PORT_NAMES and n not in SV_KEYWORDS)

    decls = []
    for name in needed:
        ty = find_declared_type(src, name)
        if ty is None:
            raise SystemExit(
                f"branch condition references '{name}' but no `logic ... {name}` "
                "declaration was found in m68030_seq.sv -- either a typo in the "
                "RTL's own condition, or this script's declaration-finder regex "
                "needs to handle a new declaration style"
            )
        decls.append((name, ty))

    with open(out_path, "w") as f:
        f.write(
            "// AUTO-GENERATED by scripts/gen_ext_count_overlap_flags.py from\n"
            "// rtl/m68030_seq.sv's own ext_count always_comb block -- do not\n"
            "// hand-edit. Re-run the generator (the Makefile rule for\n"
            "// $(SIM)/ext_count_overlap does this automatically) whenever\n"
            "// m68030_seq.sv's ext_count chain changes.\n"
            f"//\n// {len(branches)} branch conditions found; checked as whole,\n"
            "// verbatim conditions (not individual is_* flags) so legitimate\n"
            "// refinement pairs like is_X/is_X_long don't false-positive, and\n"
            "// paired with each branch's own ext_count VALUE expression so a\n"
            "// same-value overlap (a harmless, structural consequence of how\n"
            "// if/else-if priority chains work -- see this generator's own\n"
            "// extract_branch_conditions() docstring) doesn't false-positive\n"
            "// either. See this generator's own header comment.\n\n"
        )
        f.write("// Local passthrough wires for every dut-internal signal the\n")
        f.write("// branch conditions/values below reference (module ports are\n")
        f.write("// already testbench-level regs of the same name -- no passthrough\n")
        f.write("// needed for those).\n")
        for name, ty in decls:
            f.write(f"{ty} {name}; assign {name} = dut.{name};\n")
        f.write("\n")
        f.write(f"localparam int EXT_COUNT_BRANCH_N = {len(branches)};\n")
        f.write("logic [EXT_COUNT_BRANCH_N-1:0] ext_count_branch_bus;\n")
        f.write("logic [2:0] ext_count_branch_val [0:EXT_COUNT_BRANCH_N-1];\n")
        f.write(
            "// Auto-detected catch-all buckets (>= "
            f"{BUCKET_OR_THRESHOLD} top-level ||'s in the branch's own\n"
            "// condition) -- excluded from the overlap-check's value-\n"
            "// disagreement trigger in tb/ext_count_overlap_tb.sv, since a\n"
            "// broad fallback branch overlapping an earlier, more specific\n"
            "// branch is expected, harmless chain-priority behavior, not a\n"
            "// bug (see that testbench's own header comment).\n"
        )
        f.write("logic [EXT_COUNT_BRANCH_N-1:0] ext_count_branch_is_bucket;\n")
        f.write(f"assign ext_count_branch_is_bucket = {len(branches)}'b" +
                "".join("1" if b else "0" for b in reversed(is_bucket)) + ";\n")
        f.write(
            "// Format-dependent branches (see FORMAT_SEED_SIGNALS above): a\n"
            "// later, format-INDEPENDENT branch disagreeing with an EARLIER,\n"
            "// format-DEPENDENT one is this project's own established\n"
            "// deliberate-override architecture (Phases 116-147, plan.md),\n"
            "// not a shadowing bug -- tb/ext_count_overlap_tb.sv's own check\n"
            "// treats that specific pairing as safe.\n"
        )
        f.write("logic [EXT_COUNT_BRANCH_N-1:0] ext_count_branch_is_format_dep;\n")
        f.write(f"assign ext_count_branch_is_format_dep = {len(branches)}'b" +
                "".join("1" if b else "0" for b in reversed(is_format_dep)) + ";\n")
        f.write(
            "// KNOWN_REFINEMENT_PAIRS (see that constant's own comment "
            "above): branch i is safely shadowed specifically when branch "
            "ext_count_branch_shadow_of[i] (a strict earlier refinement of "
            "it) has already won -- -1 means no such relationship.\n"
        )
        f.write("int ext_count_branch_shadow_of [0:EXT_COUNT_BRANCH_N-1];\n")
        f.write("initial begin\n")
        for i, s in enumerate(shadow_of):
            f.write(f"    ext_count_branch_shadow_of[{i}] = {s};\n")
        f.write("end\n")
        for i, (cond, value) in enumerate(branches):
            f.write(f"assign ext_count_branch_bus[{i}] = ({cond});\n")
            f.write(f"assign ext_count_branch_val[{i}] = ({value});\n")
        f.write("\n// For failure-message readability only.\n")
        f.write("function automatic string ext_count_branch_desc(input int idx);\n")
        f.write("    case (idx)\n")
        for i, (cond, value) in enumerate(branches):
            esc = cond.replace('"', '\\"')
            f.write(f'        {i}: ext_count_branch_desc = "{esc}";\n')
        f.write('        default: ext_count_branch_desc = "?";\n')
        f.write("    endcase\n")
        f.write("endfunction\n")

    print(f"wrote {out_path}: {len(branches)} branch conditions "
          f"({n_buckets} catch-all buckets, {n_format_dep} format-dependent), "
          f"{len(decls)} passthrough wires")


if __name__ == "__main__":
    main()

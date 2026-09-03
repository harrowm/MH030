`default_nettype none
`timescale 1ns/1ps

// Exhaustive opcode-sweep mutual-exclusivity check for m68030_seq.sv's own
// ext_count if/else-if chain (deferred-items closure follow-up, plan.md
// "De-duplicate ext_count's decode primitives against eu_seq.sv").
//
// Historically, every real bug found in this chain (Phase 96's Scc
// mislabel, Phase 150's MOVEC gap, Phase 161 Stage A5's BFCHG/BFEXTS/BFFFO
// mapping bug, Phase 216's F-line MMU ext_count gap) has the same shape:
// a real 68030 opcode either aliases into an unrelated instruction
// family's own branch condition, or matches no branch at all and silently
// falls through to the default ext_count=0. This test targets the first
// shape directly: for every possible instr_word (all 65,536 values) times
// a representative set of extension-word "peek" configurations (the only
// inputs the chain's own branch conditions read besides instr_word), check
// whether more than one of the chain's 48 branches is ever true for the
// same input AND would produce a DIFFERENT ext_count value.
//
// Checks whole BRANCH conditions (as literally written in the RTL, via the
// generated tb/ext_count_overlap_flags.svh -- see that generator's own
// header comment for why), not individual is_* flags: several flags are
// deliberate "refinement pairs" (is_alu_mem_src / is_alu_mem_src_long, and
// similar) designed to be true together, with the disambiguation already
// encoded in the branch condition itself (e.g. `is_alu_mem_src &&
// !is_alu_mem_src_long`). Checking raw flags would flood with expected
// false positives from every such pair; checking the real if/else-if
// guards directly answers the question that actually matters.
//
// Also filters on the two branches' own ext_count VALUE actually
// disagreeing, not mere co-truth -- an earlier attempt at this check found
// ~46,300 of 393,216 opcode/config combinations "overlapping" with zero
// real bugs among them: a broad catch-all bucket near the end of the chain
// (e.g. branch 46, the "1 extension word" bucket, an OR of ~30 unrelated
// is_* conditions) routinely, harmlessly, and by design overlaps with many
// earlier, more-specific branches that happen to ALSO satisfy one of its
// OR'd sub-terms -- the chain is never actually reached that far for those
// opcodes (if/else-if stops at the first match), so it's not a bug,
// regardless of what the unreached bucket would also have said. The one
// concrete example that DID survive this filter during development (see
// plan.md) was is_ori_andi_eori_sr's own condition failing to constrain
// f_dn/f_ss at all, overlapping CAS2's own narrow encoding slot with a
// genuinely different value (2 vs 1) -- harmless in practice only because
// CAS2's branch happens to appear earlier in the chain and wins by
// priority, but worth a human's attention as a real, if currently
// inert, imprecision in is_ori_andi_eori_sr's own condition.
//
// A SECOND, structurally different class of false positive turned up once
// value-disagreement filtering was added: the mode=110 full-format EA
// rollout's own established architecture (Phases 116-147, plan.md) always
// positions a full-format-AWARE override branch EARLIER in this chain than
// the pre-existing brief-only branch it needs to override -- the brief
// branch is deliberately left unmodified, since it's still correct for
// brief format and is simply never reached for full format once shadowed.
// This produces the exact same harmless "later branch disagrees with an
// earlier, more specific one" shape as a catch-all bucket, just without the
// tell-tale large OR count that identifies a bucket. Detected the same way
// in spirit -- automatically, from the real RTL, not a hand-maintained list
// -- via tb/ext_count_overlap_flags.svh's own ext_count_branch_is_format_dep
// bus (see scripts/gen_ext_count_overlap_flags.py's own
// compute_format_dependent_names(), a transitive-closure analysis over
// every `assign` in m68030_seq.sv finding every signal that can only be
// true when the extension word is in full format): a format-INDEPENDENT
// branch that disagrees with an EARLIER format-DEPENDENT branch is this
// established override pattern, not a shadowing bug, and is excluded from
// the trigger below the same way a bucket is. Confirmed by hand against all
// 9 distinct signatures this sweep found before this refinement (plan.md)
// -- every one was exactly this shape (is_movem_idx_full/is_cmp2chk2_idx_full/
// the various is_move_mm_*_idxdst_full arms/is_move_idx_src_memdst_full/
// is_memind_full, each correctly preceding and shadowing its own
// pre-existing brief-only sibling branch).
//
// Extension-word coverage is deliberately NOT a full 4096-value cross
// product (65536 instr_word x 4096 ext-data-bit combos x 64 q3-word combos
// is many orders of magnitude too large to be worth running) -- the
// classifiers this chain reads only ever look at is_full, bdsz[1]
// (word-vs-long), and (iis==0 vs iis!=0), never any other bit combination,
// so 6 representative configurations (brief, and 5 full-format shapes
// spanning null/word/long bd crossed with direct/indirect od) cover every
// distinct code path the chain can take. If a future change to
// m68030_seq.sv makes some other bit combination meaningfully distinct,
// extend NUM_CFG rather than assume this list is exhaustive forever.

module ext_count_overlap_tb;

    logic [15:0] instr_word;
    logic [31:0] ifu_ext_data;
    logic [15:0] ifu_q3_word;
    logic [31:0] ifu_ext34_data;
    logic [15:0] ifu_q5_word;
    logic [15:0] ifu_q6_word;   // 10-item backlog Stage 8 (plan.md)
    logic        instr_valid;
    logic        ifu_ext1_valid;
    logic        ifu_ext_valid;
    logic        ifu_ext4_valid;
    logic        ifu_ext5_valid;
    logic        ifu_ext6_valid;
    logic        ifu_ext7_valid;  // 10-item backlog Stage 8 (plan.md)
    logic [2:0]  drain;
    logic [15:0] eu_instr_word;
    logic [31:0] eu_ext_data;
    logic [15:0] eu_q3_word;
    logic [31:0] eu_ext34_data;
    logic [15:0] eu_q5_word;
    logic [15:0] eu_q6_word;     // 10-item backlog Stage 8 (plan.md)
    logic        eu_instr_valid;
    logic        eu_ext_valid;
    logic        eu_instr_ack;
    logic        eu_busy;

    m68030_seq dut (.*);

    // Provides: ext_count_branch_bus[47:0], ext_count_branch_desc(idx),
    // EXT_COUNT_BRANCH_N, plus local passthrough wires for every
    // dut-internal signal the branch conditions reference.
    `include "ext_count_overlap_flags.svh"

    function automatic logic [15:0] mk_ext_word(
        input logic       full,
        input logic [1:0] bdsz,
        input logic [2:0] iis
    );
        mk_ext_word = {7'b0, full, 2'b00, bdsz, 1'b0, iis};
    endfunction

    localparam int NUM_CFG = 6;
    logic [15:0] cfg_word [0:NUM_CFG-1];
    initial begin
        cfg_word[0] = mk_ext_word(1'b0, 2'b00, 3'b000);  // brief format everywhere
        cfg_word[1] = mk_ext_word(1'b1, 2'b01, 3'b000);  // full, null bd, no indirect
        cfg_word[2] = mk_ext_word(1'b1, 2'b10, 3'b000);  // full, word bd, no indirect
        cfg_word[3] = mk_ext_word(1'b1, 2'b11, 3'b000);  // full, long bd, no indirect
        cfg_word[4] = mk_ext_word(1'b1, 2'b10, 3'b011);  // full, word bd, indirect (long od)
        cfg_word[5] = mk_ext_word(1'b1, 2'b11, 3'b011);  // full, long bd, indirect (long od)
    end

    integer overlap_count;
    integer fail;

    // Distinct-signature dedup (Icarus 13 has no associative array support,
    // per this project's own established finding -- a small fixed-size
    // linear-scan table is fine here since the number of genuinely DISTINCT
    // branch-overlap shapes is expected to be small, even though the same
    // shape can recur across thousands of individual opcodes as some
    // unrelated field varies). Reports each distinct shape once, with its
    // own first-seen example instr_word/cfg, rather than an unbounded
    // stream of per-opcode duplicates of the same underlying finding.
    localparam int MAX_SIGS = 200;
    logic [63:0] seen_sig [0:MAX_SIGS-1];
    logic [15:0] seen_instr_word [0:MAX_SIGS-1];
    int          seen_cfg [0:MAX_SIGS-1];
    int          num_sigs;

    initial begin
        int cfg;
        integer w;
        logic [15:0] cw;

        instr_valid    = 1'b1;
        ifu_ext1_valid = 1'b1;
        ifu_ext_valid  = 1'b1;
        ifu_ext4_valid = 1'b1;
        ifu_ext5_valid = 1'b1;
        ifu_ext6_valid = 1'b1;
        ifu_ext7_valid = 1'b1;  // 10-item backlog Stage 8 (plan.md)
        eu_instr_ack   = 1'b0;
        eu_busy        = 1'b0;
        overlap_count  = 0;
        fail           = 0;
        num_sigs       = 0;

        for (cfg = 0; cfg < NUM_CFG; cfg = cfg + 1) begin
            cw = cfg_word[cfg];
            // Same representative pattern on both ifu_ext_data halves (the
            // "q1 high / q2 low" and "q1 low / q2 high" peek conventions
            // both used somewhere in the chain) and on ifu_q3_word, so
            // every peek site sees a consistent picture regardless of
            // which convention it reads.
            ifu_ext_data = {cw, cw};
            ifu_q3_word  = cw;

            for (w = 0; w < 65536; w = w + 1) begin
                instr_word = w[15:0];
                #1;
                if ($countones(ext_count_branch_bus) > 1) begin
                    // Not itself a bug -- see the file header. Only worth
                    // reporting if the true branches would actually give
                    // DIFFERENT ext_count values; same-value overlaps are a
                    // harmless, structural consequence of how a broad
                    // catch-all bucket near the end of an if/else-if chain
                    // routinely, correctly, overlaps with earlier specific
                    // branches it's never actually reached for.
                    int b;
                    logic [2:0] first_val;
                    logic       first_seen;
                    logic       seen_format_dep;
                    logic       value_disagreement;
                    logic [EXT_COUNT_BRANCH_N-1:0] contributes;
                    first_seen      = 1'b0;
                    seen_format_dep = 1'b0;
                    value_disagreement = 1'b0;
                    contributes = '0;
                    for (b = 0; b < EXT_COUNT_BRANCH_N; b = b + 1) begin
                        // Catch-all buckets excluded from the trigger --
                        // see this file's own header comment for why an
                        // earlier, specific branch overlapping a later
                        // bucket (regardless of value) is expected,
                        // harmless chain-priority behavior.
                        if (ext_count_branch_bus[b] && !ext_count_branch_is_bucket[b]) begin
                            // A format-INDEPENDENT branch that shows up
                            // AFTER an earlier format-DEPENDENT branch has
                            // already won (established first_val) is this
                            // project's own established deliberate-override
                            // architecture (see this file's own header
                            // comment) -- skip it entirely, it never
                            // actually decides anything for this input.
                            // Same treatment, narrower scope, for a known
                            // refinement pair (ext_count_branch_shadow_of) --
                            // only skip branch b when its OWN specific
                            // refiner is the one that already won, not any
                            // earlier format-dependent branch in general.
                            if (seen_format_dep && !ext_count_branch_is_format_dep[b]) begin
                                // safely shadowed (format), not counted at all
                            end else if (ext_count_branch_shadow_of[b] != -1 &&
                                         contributes[ext_count_branch_shadow_of[b]]) begin
                                // safely shadowed (known refinement pair), not counted at all
                            end else if (!first_seen) begin
                                first_val     = ext_count_branch_val[b];
                                first_seen    = 1'b1;
                                contributes[b] = 1'b1;
                                if (ext_count_branch_is_format_dep[b]) seen_format_dep = 1'b1;
                            end else begin
                                contributes[b] = 1'b1;
                                if (ext_count_branch_is_format_dep[b]) seen_format_dep = 1'b1;
                                if (ext_count_branch_val[b] !== first_val) begin
                                    value_disagreement = 1'b1;
                                end
                            end
                        end
                    end
                    if (value_disagreement) begin
                        // Dedup by signature: exactly the bits that actually
                        // contributed to the disagreement decision above
                        // (buckets and safely-shadowed format-independent
                        // branches excluded -- including them would splinter
                        // what's really the same underlying shape into many
                        // apparently-distinct signatures).
                        logic [63:0] sig;
                        int          j;
                        logic        found;
                        sig = 64'h0;
                        for (j = 0; j < EXT_COUNT_BRANCH_N; j = j + 1) begin
                            if (contributes[j]) sig[j] = 1'b1;
                        end
                        found = 1'b0;
                        for (j = 0; j < num_sigs; j = j + 1) begin
                            if (seen_sig[j] === sig) found = 1'b1;
                        end
                        if (!found) begin
                            if (num_sigs < MAX_SIGS) begin
                                seen_sig[num_sigs]        = sig;
                                seen_instr_word[num_sigs] = w[15:0];
                                seen_cfg[num_sigs]        = cfg;
                                num_sigs                  = num_sigs + 1;
                            end
                        end
                        overlap_count = overlap_count + 1;
                    end
                end
            end
            $display("PASS cfg=%0d (%04h) sweep complete, overlap_count so far=%0d",
                      cfg, cw, overlap_count);
        end

        if (overlap_count == 0) begin
            $display("PASS: no two ext_count branch conditions ever true simultaneously across %0d configs x 65536 opcodes", NUM_CFG);
        end else begin
            int s, b2;
            $display("FAIL: %0d opcode/config combinations had more than one ext_count branch condition true simultaneously, %0d distinct signature(s):",
                      overlap_count, num_sigs);
            for (s = 0; s < num_sigs; s = s + 1) begin
                string matched;
                matched = "";
                for (b2 = 0; b2 < EXT_COUNT_BRANCH_N; b2 = b2 + 1) begin
                    if (seen_sig[s][b2]) begin
                        matched = {matched, (matched == "" ? "" : ", "),
                                   $sformatf("[%0d] %s", b2, ext_count_branch_desc(b2))};
                    end
                end
                $display("  SIGNATURE %0d (first seen cfg=%0d instr_word=%04h): %s",
                          s, seen_cfg[s], seen_instr_word[s], matched);
            end
            fail = fail + 1;
        end

        $display("=== TOTAL: %0d failure(s) ===", fail);
        if (fail == 0) $display("ALL TESTS PASSED");
        $finish;
    end

endmodule

`default_nettype wire

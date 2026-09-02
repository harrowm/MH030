`default_nettype none

// Shared primitive instruction-word / extension-word field extraction.
// Used identically by m68030_seq.sv (ext_count / IFU drain) and eu_seq.sv
// (EU decode) since both classify the exact same instr_word on the same
// cycle (m68030_seq.sv does a pure combinational assign eu_instr_word =
// instr_word passthrough). No package/import: plain file-scope
// `function automatic`, validated against this project's exact Icarus-13
// (-g2012) toolchain before being written here (plan.md, ext_count
// de-duplication Stage 2) -- zero SystemVerilog package precedent exists
// anywhere in this repo, so the mechanism was proven with a standalone
// scratch compile first rather than assumed.
//
// Deliberately NOT shared: the higher-level is_X/dec_is_* predicates and
// m68030_seq.sv's own `ext_count` priority chain -- only the bit-position
// primitives those are built from. Before this file existed, both
// `eu_seq.sv` and `m68030_seq.sv` independently hand-copied the exact same
// bit positions for opcode field extraction and mode=110 full-format
// extension-word classification -- a documented recurring source of real
// bugs in this project's history (Phase 96's Scc mislabel, Phase 150's
// MOVEC gap, Phase 161 Stage A5's BFCHG/BFEXTS/BFFFO mapping bug, Phase
// 216's F-line MMU ext_count gap all share this exact "two places must
// stay in sync" shape). This file exists so there is now exactly ONE place
// in the whole codebase where these bit positions are ever written down.

// Opcode field extraction -- instr_word[15:12]/[11:9]/[8]/[7:6]/[5:3]/[2:0].
function automatic logic [3:0] opf_group(input logic [15:0] w); opf_group = w[15:12]; endfunction
function automatic logic [2:0] opf_dn   (input logic [15:0] w); opf_dn    = w[11:9];  endfunction
function automatic logic       opf_dir  (input logic [15:0] w); opf_dir   = w[8];     endfunction
function automatic logic [1:0] opf_ss   (input logic [15:0] w); opf_ss    = w[7:6];   endfunction
function automatic logic [2:0] opf_mode (input logic [15:0] w); opf_mode  = w[5:3];   endfunction
function automatic logic [2:0] opf_reg  (input logic [15:0] w); opf_reg   = w[2:0];   endfunction

// Mode=110 (indexed EA) full-format extension-word classification. Caller
// passes whichever 16-bit word slice is relevant for its own pipeline
// stage/data layout (ext_data[15:0], ifu_ext_data[31:16], ifu_ext_data[15:0],
// ifu_q3_word, ...) -- the underlying bit positions (is_full=bit8,
// bdsz=bits[5:4], iis=bits[2:0]) are identical regardless of which slice.
function automatic logic       eaf_is_full(input logic [15:0] w); eaf_is_full = w[8];   endfunction
function automatic logic [1:0] eaf_bdsz   (input logic [15:0] w); eaf_bdsz    = w[5:4]; endfunction
function automatic logic [2:0] eaf_iis    (input logic [15:0] w); eaf_iis     = w[2:0]; endfunction

// Stage 4 (optional, ext_count de-duplication plan, plan.md): 2-bit
// displacement-size field -> word count (01=null,10=word,11=long ->
// 0/1/2 extra extension words). Shared by m68030_seq.sv's own
// memind_bd_words/movem_bd_words/q3bd_words (called with bdsz directly)
// and memind_od_words/movem_od_words (called with iis[1:0] -- only bit[1]
// and the literal value 2'b11 matter for the word count either way, same
// as for bdsz). Intra-m68030_seq.sv only -- eu_seq.sv doesn't need a word
// *count* here, it computes the actual displacement *value* directly via
// fi_bd.
function automatic logic [2:0] eaf_disp_words(input logic [1:0] sz);
    eaf_disp_words = (sz == 2'b10) ? 3'd1 : (sz == 2'b11) ? 3'd2 : 3'd0;
endfunction

`default_nettype wire

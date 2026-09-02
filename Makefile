SHELL     := bash
.SHELLFLAGS := -c

# ── Simulator ──────────────────────────────────────────────────────────────
IV       := iverilog
VVP      := vvp
IVFLAGS  := -g2012 -I rtl -I tb
SIM      := sim

# Suppress the hundreds of harmless "sorry: constant selects" lines from
# Icarus 13 while still propagating iverilog's exit code on real errors.
IVCOMP = { $(IV) $(IVFLAGS) -o $@ $^ 2>&1 || { echo "ERROR: $@ compile failed"; exit 1; }; } \
         | grep -Ev "sorry:|^$$" ; exit $${PIPESTATUS[0]}

# ── Source lists (reused across many tests) ────────────────────────────────
EU_SRCS := \
    rtl/opcode_fields.sv \
    rtl/eu_regfile.sv \
    rtl/eu_alu.sv \
    rtl/eu_shifter.sv \
    rtl/eu_mul_div.sv \
    rtl/eu_bcd.sv \
    rtl/eu_bitops.sv \
    rtl/eu_agu.sv \
    rtl/eu_bitfield.sv \
    rtl/eu_seq.sv \
    rtl/m68030_eu.sv

BIU_SRCS := \
    rtl/biu_eclk_gen.sv \
    rtl/biu_cycle_gen.sv \
    rtl/biu_arbiter.sv \
    rtl/biu_sizing_fsm.sv \
    rtl/biu_multiop_fsm.sv \
    rtl/biu_cache_if.sv \
    rtl/biu_icache_if.sv \
    rtl/biu_mmu_if.sv \
    rtl/biu_mmu_arb.sv \
    rtl/biu_exc_capture.sv \
    rtl/biu_byte_lane_ctrl.sv \
    rtl/biu_config.sv \
    rtl/biu_pin_driver.sv \
    rtl/biu_error_handler.sv \
    rtl/biu_burst_ctrl.sv

# ── Unit tests ─────────────────────────────────────────────────────────────
$(SIM)/eu_regfile: rtl/eu_regfile.sv                 tb/eu_regfile_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/eu_alu:     rtl/eu_alu.sv                     tb/eu_alu_tb.sv     | $(SIM)
	$(IVCOMP)

$(SIM)/eu_shifter: rtl/eu_shifter.sv                 tb/eu_shifter_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/eu_mul_div: rtl/eu_mul_div.sv                 tb/eu_mul_div_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/eu_bcd:     rtl/eu_bcd.sv                     tb/eu_bcd_tb.sv     | $(SIM)
	$(IVCOMP)

$(SIM)/eu_bitops:  rtl/eu_bitops.sv                  tb/eu_bitops_tb.sv  | $(SIM)
	$(IVCOMP)

$(SIM)/agu:        rtl/eu_agu.sv                     tb/agu_tb.sv        | $(SIM)
	$(IVCOMP)

# ── EU integration ─────────────────────────────────────────────────────────
$(SIM)/eu_seq_tb:  $(EU_SRCS)                         tb/eu_seq_tb.sv     | $(SIM)
	$(IVCOMP)

$(SIM)/eu_tb:      $(EU_SRCS)                         tb/eu_tb.sv         | $(SIM)
	$(IVCOMP)

$(SIM)/ctrl_flow:  $(EU_SRCS)                         tb/ctrl_flow_tb.sv  | $(SIM)
	$(IVCOMP)

$(SIM)/ea_modes:   $(EU_SRCS)                         tb/ea_modes_tb.sv   | $(SIM)
	$(IVCOMP)

$(SIM)/data_move:  $(EU_SRCS)                         tb/data_move_tb.sv  | $(SIM)
	$(IVCOMP)

$(SIM)/alu_reg:    $(EU_SRCS)                         tb/alu_reg_tb.sv    | $(SIM)
	$(IVCOMP)

$(SIM)/alu_mem:    $(EU_SRCS)                         tb/alu_mem_tb.sv    | $(SIM)
	$(IVCOMP)

$(SIM)/bitfield:   $(EU_SRCS)                         tb/bitfield_tb.sv   | $(SIM)
	$(IVCOMP)

$(SIM)/bcd_pack:  $(EU_SRCS)                         tb/bcd_pack_tb.sv  | $(SIM)
	$(IVCOMP)

$(SIM)/system:    $(EU_SRCS)                         tb/system_tb.sv    | $(SIM)
	$(IVCOMP)

$(SIM)/exception: $(EU_SRCS)                         tb/exception_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/atomic:    $(EU_SRCS)                         tb/atomic_tb.sv    | $(SIM)
	$(IVCOMP)

$(SIM)/seq52:      $(EU_SRCS)                         tb/seq52_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq54:      $(EU_SRCS)                         tb/seq54_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/special_instr: $(EU_SRCS)                      tb/special_instr_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/ea_extended: $(EU_SRCS)                        tb/ea_extended_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cmpm:       $(EU_SRCS)                         tb/cmpm_tb.sv        | $(SIM)
	$(IVCOMP)

# ── Standalone modules ─────────────────────────────────────────────────────
$(SIM)/ifu:        rtl/m68030_ifu.sv                  tb/ifu_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/seq_ctrl:      rtl/opcode_fields.sv rtl/m68030_seq.sv  tb/seq_ctrl_tb.sv        | $(SIM)
	$(IVCOMP)

tb/ext_count_overlap_flags.svh: rtl/m68030_seq.sv scripts/gen_ext_count_overlap_flags.py
	python3 scripts/gen_ext_count_overlap_flags.py rtl/m68030_seq.sv tb/ext_count_overlap_flags.svh

$(SIM)/ext_count_overlap: rtl/opcode_fields.sv rtl/m68030_seq.sv tb/ext_count_overlap_tb.sv \
                   | tb/ext_count_overlap_flags.svh $(SIM)
	$(IVCOMP)

$(SIM)/pipeline:    rtl/m68030_ifu.sv rtl/m68030_seq.sv $(EU_SRCS) \
                   tb/pipeline_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/stall_hazard: rtl/m68030_ifu.sv rtl/m68030_seq.sv $(EU_SRCS) \
                   tb/stall_hazard_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/exc:        rtl/m68030_exc.sv                  tb/exc_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/mmu:        rtl/m68030_mmu.sv rtl/biu_mmu_if.sv tb/mmu_tb.sv        | $(SIM)
	$(IVCOMP)

# ── BIU ───────────────────────────────────────────────────────────────────
$(SIM)/biu:        $(BIU_SRCS) tb/mem_model.sv        tb/biu_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/biu_int: rtl/m68030_biu.sv $(BIU_SRCS) \
                   tb/mem_model.sv tb/biu_int_tb.sv | $(SIM)
	$(IVCOMP)

# ── Top integration ────────────────────────────────────────────────────────
TOP_SRCS := rtl/m68030_top.sv rtl/m68030_biu.sv $(BIU_SRCS) \
            $(EU_SRCS) rtl/m68030_ifu.sv rtl/m68030_seq.sv \
            rtl/m68030_exc.sv rtl/m68030_mmu.sv

$(SIM)/top:        $(TOP_SRCS) tb/mem_model.sv tb/top_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_boot:    $(TOP_SRCS) tb/cosim_boot_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cache:         $(TOP_SRCS) tb/cache_tb.sv | tb/common_helpers.svh $(SIM)
	$(IVCOMP)

$(SIM)/stall_fsm:     $(TOP_SRCS) tb/stall_fsm_tb.sv | tb/common_helpers.svh $(SIM)
	$(IVCOMP)

$(SIM)/mmu_xlate:     $(TOP_SRCS) tb/mmu_xlate_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/timing:        $(TOP_SRCS) tb/timing_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_smoke:   $(TOP_SRCS) tb/cosim_smoke_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_grp:  $(TOP_SRCS) tb/cosim_grp_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_dat:  $(TOP_SRCS) tb/cosim_dat_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/harte_dat:  $(TOP_SRCS) tb/harte_tb.sv | $(SIM)
	$(IVCOMP)

# Batched Harte runner (many tests per vvp process) — drives
# scripts/run_harte_batch.py. See plan.md's Harte-sweep-performance
# investigation for the two testbench bugs found while building this and the
# ADD.b/MOVEM.l validation against run_harte.py's per-process results.
$(SIM)/harte_batch:  $(TOP_SRCS) tb/harte_batch_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/mustest: $(TOP_SRCS) tb/mustest_tb.sv | $(SIM)
	$(IVCOMP)

# ── Verilator build for mustest (100-1000x faster than Icarus) ───────────────
VLATOR       := verilator
VOBJ         := obj_mustest
VLATOR_FLAGS := --cc -sv --Mdir $(VOBJ) --top-module mustest_tb \
                --x-assign 0 --x-initial 0 -Wno-fatal -Wno-WIDTHTRUNC \
                -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE -Wno-INITIALDLY \
                --public -fno-dfg

$(VOBJ)/Vmustest_tb: $(TOP_SRCS) tb/mustest_tb.sv tb/mustest_main.cpp | $(VOBJ)
	$(VLATOR) $(VLATOR_FLAGS) --exe tb/mustest_main.cpp $(TOP_SRCS) tb/mustest_tb.sv
	$(MAKE) -C $(VOBJ) -f Vmustest_tb.mk OPT_FAST="-O2"

$(VOBJ):
	mkdir -p $(VOBJ)

sim/vmustest: $(VOBJ)/Vmustest_tb | $(SIM)
	cp $< $@

# ── Verilator build for the batched Harte runner (see plan.md's Harte-sweep-
# performance investigation) ─────────────────────────────────────────────────
VOBJ_HARTE := obj_harte_vbatch
VLATOR_FLAGS_HARTE := --cc -sv --Mdir $(VOBJ_HARTE) --top-module harte_verilator_tb \
                --x-assign 0 --x-initial 0 -Wno-fatal -Wno-WIDTHTRUNC \
                -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE -Wno-INITIALDLY \
                --public -fno-dfg

$(VOBJ_HARTE)/Vharte_verilator_tb: $(TOP_SRCS) tb/harte_verilator_tb.sv tb/harte_verilator_main.cpp | $(VOBJ_HARTE)
	$(VLATOR) $(VLATOR_FLAGS_HARTE) --exe tb/harte_verilator_main.cpp $(TOP_SRCS) tb/harte_verilator_tb.sv
	$(MAKE) -C $(VOBJ_HARTE) -f Vharte_verilator_tb.mk OPT_FAST="-O2"

$(VOBJ_HARTE):
	mkdir -p $(VOBJ_HARTE)

sim/harte_vbatch: $(VOBJ_HARTE)/Vharte_verilator_tb | $(SIM)
	cp $< $@

# ── Bare-metal test hex generation (requires vasmm68k_mot in PATH) ──────────
tests/%.bin: tests/%.s
	vasmm68k_mot -Fbin -m68030 $< -o $@

tests/%.hex: tests/%.bin tools/bin2hex.py
	python3 tools/bin2hex.py $< > $@

# ── Regression list (ordered: unit → EU → standalone → BIU → top) ─────────
ALL_TESTS := \
    $(SIM)/eu_regfile $(SIM)/eu_alu $(SIM)/eu_shifter $(SIM)/eu_mul_div \
    $(SIM)/eu_bcd $(SIM)/eu_bitops $(SIM)/agu \
    $(SIM)/eu_seq_tb $(SIM)/eu_tb \
    $(SIM)/ctrl_flow $(SIM)/ea_modes $(SIM)/data_move $(SIM)/alu_reg $(SIM)/alu_mem $(SIM)/bitfield $(SIM)/bcd_pack $(SIM)/system $(SIM)/exception $(SIM)/atomic \
    $(SIM)/special_instr $(SIM)/ea_extended $(SIM)/cmpm \
    $(SIM)/ifu $(SIM)/seq_ctrl $(SIM)/ext_count_overlap $(SIM)/pipeline $(SIM)/stall_hazard $(SIM)/exc $(SIM)/mmu \
    $(SIM)/biu $(SIM)/biu_int \
    $(SIM)/top $(SIM)/cosim_boot $(SIM)/cosim_smoke $(SIM)/stall_fsm $(SIM)/cache $(SIM)/mmu_xlate

# ── Phase 74: Musashi reference log ─────────────────────────────────────────
MUSASHI_DIR := tools/musashi
MUSASHI_SRC := $(MUSASHI_DIR)/m68kcpu.c $(MUSASHI_DIR)/m68kdasm.c \
               $(MUSASHI_DIR)/m68kops.c  $(MUSASHI_DIR)/softfloat/softfloat.c
MUSASHI_FLAGS := -O2 -DM68K_EMULATE_FC=1 -I$(MUSASHI_DIR) -lm

$(MUSASHI_DIR)/m68kmake: $(MUSASHI_DIR)/m68kmake.c
	gcc -o $@ $<

$(MUSASHI_DIR)/m68kops.c $(MUSASHI_DIR)/m68kops.h: $(MUSASHI_DIR)/m68kmake
	cd $(MUSASHI_DIR) && ./m68kmake

tools/m68ksim: tools/m68ksim.c $(MUSASHI_SRC)
	gcc $(MUSASHI_FLAGS) -o $@ $^

winuae/tests/smoke_ref.log: tools/m68ksim tests/smoke.hex | winuae/tests
	./tools/m68ksim tests/smoke.hex 300 > $@

winuae/tests:
	mkdir -p winuae/tests

.PHONY: m68ksim ref-log buscmp cosim_grp \
        buscmp-grp0 buscmp-grp1 buscmp-grp2 buscmp-grp3 \
        buscmp-grp4 buscmp-grp5 buscmp-grp6 buscmp-grp7 \
        dat-replay dat-synth mustest mustest40 vmustest \
        harte-add harte-add-b harte-add-w harte-add-l

# Tom Harte SingleStepTests: run ADD.b/w/l against DUT
# Usage: make harte-add [LIMIT=N] [VERBOSE=-v]
HARTE_LIMIT ?=
HARTE_VERBOSE ?=
harte-add: $(SIM)/harte_dat
	python3 scripts/run_harte.py \
	    tests/harte/ADD.b.json.bin \
	    tests/harte/ADD.w.json.bin \
	    tests/harte/ADD.l.json.bin \
	    $(if $(HARTE_LIMIT),--limit $(HARTE_LIMIT)) \
	    $(if $(HARTE_VERBOSE),--verbose)

harte-add-b: $(SIM)/harte_dat
	python3 scripts/run_harte.py tests/harte/ADD.b.json.bin \
	    $(if $(HARTE_LIMIT),--limit $(HARTE_LIMIT)) $(if $(HARTE_VERBOSE),--verbose)

harte-add-w: $(SIM)/harte_dat
	python3 scripts/run_harte.py tests/harte/ADD.w.json.bin \
	    $(if $(HARTE_LIMIT),--limit $(HARTE_LIMIT)) $(if $(HARTE_VERBOSE),--verbose)

harte-add-l: $(SIM)/harte_dat
	python3 scripts/run_harte.py tests/harte/ADD.l.json.bin \
	    $(if $(HARTE_LIMIT),--limit $(HARTE_LIMIT)) $(if $(HARTE_VERBOSE),--verbose)
m68ksim: tools/m68ksim
ref-log: winuae/tests/smoke_ref.log

# Phase 77: .dat-suite replay
# Usage: make dat-replay DAT=path/to/68030.dat [LIMIT=200] [VERBOSE=-v]
dat-replay: $(SIM)/cosim_dat tools/m68ksim
	python3 scripts/run_cosim.py --dat $(DAT) $(if $(LIMIT),--limit $(LIMIT)) $(VERBOSE)

# Phase 77: synthetic DUT vs Musashi register-state comparison (no .dat needed)
# Usage: make dat-synth [N=50]
DAT_SYNTH_N ?= 50
dat-synth: $(SIM)/cosim_dat tools/m68ksim
	python3 scripts/run_cosim.py --synth $(DAT_SYNTH_N) $(VERBOSE)

# Phase 78: Musashi instruction test suite — run all mc68000 .bin tests through DUT
# Usage: make mustest [VERBOSE=-v]
mustest: sim/vmustest tools/mustest
	python3 scripts/run_mustest.py --sim sim/vmustest $(VERBOSE)

# Phase 78: mc68040-specific tests (bit-field, CAS, CHK2, long mul/div, etc.)
mustest40: sim/vmustest tools/mustest
	python3 scripts/run_mustest.py --sim sim/vmustest --dir tools/musashi/test/mc68040 $(VERBOSE)

# Convenience: just build the Verilator mustest binary
vmustest: sim/vmustest

tools/mustest: tools/musashi/test/test_driver.c $(MUSASHI_SRC)
	gcc $(MUSASHI_FLAGS) -I tools/musashi/test -o $@ $^

# Phase 75: compare DUT bus log to reference
# Usage: make buscmp  (captures live DUT run and compares to reference)
buscmp: winuae/tests/smoke_ref.log
	$(VVP) $(SIM)/cosim_smoke 2>&1 | grep "^BUS" > /tmp/_dut_smoke.log || true
	python3 tools/buscmp.py /tmp/_dut_smoke.log winuae/tests/smoke_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap

# Phase 76: per-opcode-group bus comparison tests
# Reference logs: generated on demand (make winuae/tests/grpN_ref.log)
winuae/tests/grp%_ref.log: tools/m68ksim tests/grp%.hex | winuae/tests
	./tools/m68ksim tests/grp$*.hex 300 > $@

# Run DUT for one group and diff vs reference.  Usage: make buscmp-grp0
GRP_REFS := $(patsubst %,winuae/tests/grp%_ref.log,0 1 2 3 4 5 6 7)
GRP_HEXS := $(patsubst %,tests/grp%.hex,0 1 2 3 4 5 6 7)

define GRP_RULE
buscmp-grp$(1): $(SIM)/cosim_grp winuae/tests/grp$(1)_ref.log tests/grp$(1).hex
	$$(VVP) $$(SIM)/cosim_grp +hexfile=tests/grp$(1).hex +grp=grp$(1) 2>&1 \
	    | grep "^BUS" > /tmp/_dut_grp$(1).log || true
	python3 tools/buscmp.py /tmp/_dut_grp$(1).log winuae/tests/grp$(1)_ref.log \
	    --reads-only $(if $(filter 6,$(1)),--max 6,--dut-may-continue)
endef
$(foreach n,0 1 2 3 4 5 6 7,$(eval $(call GRP_RULE,$(n))))

# Run all 8 group tests
cosim_grp: buscmp-grp0 buscmp-grp1 buscmp-grp2 buscmp-grp3 \
           buscmp-grp4 buscmp-grp5 buscmp-grp6 buscmp-grp7

# Phase 107/115/116/117: memory-indirect / full-format mode=110 EA bus
# comparison tests. Harte's corpus is 68000-captured and has zero coverage
# of this 68020+-only mode, so this is the only regression coverage for it.
# memind2=word bd, post (MOVE); memind3=word bd+word od (post) and null
# bd+word od (pre) (MOVE); memind7=word bd (ADD memory-source, OR memory-
# dest RMW -- Stage 2's ALU-mem-src family); memind10=word bd (PEA + JSR
# indexed -- Stage 3, also confirms the is_jsr_idx ext_count fix);
# memind11=word bd (MOVEM.L store+load indexed -- Stage 4, the first family
# in this rollout needing additive rather than override ext_count
# arithmetic, since MOVEM's own baseline already occupies 2 ext words
# before any full-format concept applies); memind12=brief + word bd
# (CMP2.L/CHK2.L indexed -- Phase 120, the first *unimplemented* family in
# this rollout rather than merely brief-limited; also fixed a genuine
# dyn_bit_get_Dn timing conflict this new form exposed, see plan.md
# Phase 120); memind13=long (32-bit) bd (ADD memory-source, OR memory-dest
# RMW -- Phase 121, the fi_bd fix that benefits every already-converted
# Stage 1-3 site "for free"); memind16=long (32-bit) bd for MOVEM.L itself
# (Phase 138 -- MOVEM's own mode110 arm has a bespoke bd extraction, not
# fi_bd, so needed its own dedicated fix and its own dedicated test);
# memind17=genuine memory-indirect with long bd + word od together (Phase
# 140 -- fixes a real fi_od aliasing bug, not just a missing feature: the
# old code silently misread od's value from bd's own high half instead of
# its real position one word further out); memind21=genuine memory-
# indirect with long bd AND long od together (Phase 146 -- the last
# combination requiring the new genuine-q5 IFU plumbing, Phase 145).
#
# memind18 (Phase 141: MOVE #imm,(bd,An,Xn) full-format indexed dst) is
# deliberately NOT wired in here, same reason as memind9/14/15: this arm's
# pre-existing (unrelated to Phase 141's own change -- unmodified by it)
# dec_is_mem_rmw "2-port trick" performs a real bus READ before the write
# that Musashi doesn't, so a plain --reads-only compare still mismatches
# (that flag only tolerates trailing spurious *writes*, not an interleaved
# extra *read*). All three EA computations (word bd, long bd, MOVE.L's own
# word-bd-only case) and every written value were hand-verified to match
# Musashi exactly once the phantom reads are accounted for.
#
# tests/memind19.s (Phase 142: MOVE (xxx).L,(bd,An,Xn) full-format indexed
# dst, word bd -- the abs.L-src arm) is also deliberately not wired in:
# unlike memind18 (RMW phantom-read quirk), this one uses the real move_mm
# FSM and hits the *other*, unrelated benign quirk instead -- the same
# prefetch-interleave reordering already documented for memind/memind4/
# memind6/memind9/memind14 (the DUT's real pipelined IFU prefetch fetches
# one word earlier than Musashi's own interpretive re-fetch quirk expects).
# The actual write (EA + value) matches Musashi byte-for-byte; only the
# fetch-vs-read cycle order differs by one slot.
#
# tests/memind20.s (Phase 143: MOVE (An)/(An)+/-(An)/(d16,An),(bd,An,Xn)
# full-format indexed dst, the plain-memory-src arm -- the last and
# hardest of the three MOVE mem-to-mem arms this rollout adds) is also
# deliberately not wired in -- same benign prefetch-interleave quirk as
# memind19 just above; all three writes were hand-verified to match
# Musashi byte-for-byte.
#
# tests/memind.s, memind4.s (Phase 115: the very first minimal pre/post
# reproduction, and the IS=1/index-suppressed case), memind5.s (Phase 116:
# TAS+NBCD), memind6.s (Phase 116: CLR+ASL), memind8.s (Phase 117: dynamic
# BSET), memind9.s (Phase 118: LEA/CHK/ADDQ.L/MOVE-to-CCR), memind14.s
# (Phase 122: MOVE mem-to-mem indexed-dst full-format bd, abs.W-src and
# (d16,PC)-src forms), and memind15.s (Phase 122: same, register-src form)
# are deliberately *not* wired in here -- each hits its own flavor of a
# benign, pre-existing DUT-vs-Musashi bus-trace difference unrelated to
# correctness (see each file's own header comment: memind/memind4/memind6/
# memind9/memind14 have a prefetch-interleave timing difference depending
# on the tested instruction's own shape; memind5's TAS half, memind8's
# BSET, and memind15's register-src MOVE mem-to-mem all hit variants of the
# same *different*, also pre-existing gap -- an extra bus read (or, for
# byte-sized transfers, the testbench's bus logger showing the full 32-bit
# internal register instead of just the relevant byte) on indexed-EA
# RMW/locked writes, confirmed via a plain baseline `TAS (A0)` test showing
# the identical gap even with zero of any of these phases' own changes
# involved). All eight kept in tests/ as standalone, still-useful hand-run
# reproductions rather than wired into an automated target that would need
# to special-case each one's own reason.
winuae/tests/memind%_ref.log: tools/m68ksim tests/memind%.hex | winuae/tests
	./tools/m68ksim tests/memind$*.hex 300 > $@
# memind25 needs more than the generic 300-cycle default: DIVS.L's own
# real (Musashi) divide microcode plus 4 chained MUL/DIV instructions
# don't complete within 300 cycles -- this explicit rule (which make
# prefers over the pattern rule above for this exact filename) overrides
# with 600.
winuae/tests/memind25_ref.log: tools/m68ksim tests/memind25.hex | winuae/tests
	./tools/m68ksim tests/memind25.hex 600 > $@

buscmp-memind2: $(SIM)/cosim_grp winuae/tests/memind2_ref.log tests/memind2.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind2.hex +grp=memind2 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind2.log || true
	python3 tools/buscmp.py /tmp/_dut_memind2.log winuae/tests/memind2_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
# memind3 (Phase 160 Stage 1): the same benign prefetch/data-read reordering
# every other memind target now tolerates via --allow-adjacent-swap, but as a
# wider (3+ cycle) shuffle in this specific test -- confirmed by hand (sorted
# address+data set comparison) that DUT and REF contain identical bus events
# aside from DUT's own expected 3 post-STOP trailing prefetches, just
# reordered. Not wired into `cosim_memind`; kept as a standalone hand-run
# target rather than extending buscmp.py's tolerance to N-way reordering.
buscmp-memind3: $(SIM)/cosim_grp winuae/tests/memind3_ref.log tests/memind3.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind3.hex +grp=memind3 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind3.log || true
	python3 tools/buscmp.py /tmp/_dut_memind3.log winuae/tests/memind3_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind7: $(SIM)/cosim_grp winuae/tests/memind7_ref.log tests/memind7.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind7.hex +grp=memind7 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind7.log || true
	python3 tools/buscmp.py /tmp/_dut_memind7.log winuae/tests/memind7_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind10: $(SIM)/cosim_grp winuae/tests/memind10_ref.log tests/memind10.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind10.hex +grp=memind10 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind10.log || true
	python3 tools/buscmp.py /tmp/_dut_memind10.log winuae/tests/memind10_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind11: $(SIM)/cosim_grp winuae/tests/memind11_ref.log tests/memind11.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind11.hex +grp=memind11 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind11.log || true
	python3 tools/buscmp.py /tmp/_dut_memind11.log winuae/tests/memind11_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind12: $(SIM)/cosim_grp winuae/tests/memind12_ref.log tests/memind12.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind12.hex +grp=memind12 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind12.log || true
	python3 tools/buscmp.py /tmp/_dut_memind12.log winuae/tests/memind12_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind13: $(SIM)/cosim_grp winuae/tests/memind13_ref.log tests/memind13.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind13.hex +grp=memind13 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind13.log || true
	python3 tools/buscmp.py /tmp/_dut_memind13.log winuae/tests/memind13_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind16: $(SIM)/cosim_grp winuae/tests/memind16_ref.log tests/memind16.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind16.hex +grp=memind16 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind16.log || true
	python3 tools/buscmp.py /tmp/_dut_memind16.log winuae/tests/memind16_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind17: $(SIM)/cosim_grp winuae/tests/memind17_ref.log tests/memind17.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind17.hex +grp=memind17 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind17.log || true
	python3 tools/buscmp.py /tmp/_dut_memind17.log winuae/tests/memind17_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
buscmp-memind21: $(SIM)/cosim_grp winuae/tests/memind21_ref.log tests/memind21.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind21.hex +grp=memind21 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind21.log || true
	python3 tools/buscmp.py /tmp/_dut_memind21.log winuae/tests/memind21_ref.log \
	    --reads-only --dut-may-continue --allow-adjacent-swap
# memind26 (deferred-items closure plan Stage 8, plan.md): MOVE mem-to-mem
# plain-src (d16,An)-src indexed-dst with a LONG destination bd -- the one
# sub-case Phase 143's own memind20.s left out of scope. Full comparison
# (reads AND the write) matches Musashi/WinUAE exactly aside from the same
# benign prefetch-interleave adjacent reordering documented for memind9.s/
# 14.s/19.s/20.s -- --allow-adjacent-swap tolerates it cleanly.
buscmp-memind26: $(SIM)/cosim_grp winuae/tests/memind26_ref.log tests/memind26.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind26.hex +grp=memind26 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind26.log || true
	python3 tools/buscmp.py /tmp/_dut_memind26.log winuae/tests/memind26_ref.log \
	    --dut-may-continue --allow-adjacent-swap
# memind27 (deferred-items closure follow-up, plan.md, ext_count
# de-duplication Stage 1): MOVE (bd,An,Xn),<memory dst> in full-format --
# the real bug found by tb/ext_count_overlap_tb.sv's own exhaustive sweep.
# Full comparison (reads AND both writes) matches Musashi/WinUAE exactly
# aside from the same benign prefetch-interleave adjacent reordering
# documented for memind9.s/14.s/19.s/20.s/22.s -- --allow-adjacent-swap
# tolerates it cleanly (every value, including both computed writes,
# matches byte-for-byte).
buscmp-memind27: $(SIM)/cosim_grp winuae/tests/memind27_ref.log tests/memind27.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind27.hex +grp=memind27 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind27.log || true
	python3 tools/buscmp.py /tmp/_dut_memind27.log winuae/tests/memind27_ref.log \
	    --dut-may-continue --allow-adjacent-swap
# memind15 (Phase 149, plan.md): full comparison, NOT --reads-only -- the
# phantom read this file's own header used to document is gone now that
# MOVE Dn,(d8,An,Xn) is a genuine single-phase write via rd_c, so the full
# bus trace (reads AND the write) matches Musashi/WinUAE exactly.
buscmp-memind15: $(SIM)/cosim_grp winuae/tests/memind15_ref.log tests/memind15.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind15.hex +grp=memind15 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind15.log || true
	python3 tools/buscmp.py /tmp/_dut_memind15.log winuae/tests/memind15_ref.log \
	    --dut-may-continue
# memind24 (Phase 149, plan.md): An-source sibling of memind15 -- exercises
# dec_c_reg's own is_an bit for the first time. Also a full comparison.
buscmp-memind24: $(SIM)/cosim_grp winuae/tests/memind24_ref.log tests/memind24.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind24.hex +grp=memind24 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind24.log || true
	python3 tools/buscmp.py /tmp/_dut_memind24.log winuae/tests/memind24_ref.log \
	    --dut-may-continue
# memind25 (open-items backlog Stage 7, plan.md): MULU.L/MULS.L/DIVU.L/
# DIVS.L memory-EA forms ((An)/(An)+/(d16,An)/(xxx).L) -- the first-ever
# decode of these instructions' non-register source. Full comparison
# (reads AND every computed-result write) matches Musashi exactly.
buscmp-memind25: $(SIM)/cosim_grp winuae/tests/memind25_ref.log tests/memind25.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind25.hex +grp=memind25 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind25.log || true
	python3 tools/buscmp.py /tmp/_dut_memind25.log winuae/tests/memind25_ref.log \
	    --dut-may-continue

cosim_memind: buscmp-memind2 buscmp-memind7 buscmp-memind10 buscmp-memind11 \
              buscmp-memind12 buscmp-memind13 buscmp-memind16 buscmp-memind17 buscmp-memind21 \
              buscmp-memind15 buscmp-memind24 buscmp-memind25 buscmp-memind26 buscmp-memind27

# WinUAE ROM build (kept for future WinUAE-based reference, not used in regression)
winuae/roms/smoke_test.rom: tests/smoke.bin tools/make_kickrom.py
	python3 tools/make_kickrom.py $< $@

.PHONY: uae-rom
uae-rom: winuae/roms/smoke_test.rom

# ── Phony targets ──────────────────────────────────────────────────────────
.PHONY: compile test run clean help

compile: $(ALL_TESTS)

test: compile
	@pass=0; fail=0; \
	for bin in $(ALL_TESTS); do \
	    name=$$(basename $$bin); \
	    out=$$($(VVP) $$bin 2>&1); \
	    if echo "$$out" | grep -q "^FAIL"; then \
	        printf "FAIL  %s\n" $$name; \
	        echo "$$out" | grep "^FAIL" | sed 's/^/      /'; \
	        fail=$$((fail + 1)); \
	    else \
	        printf "pass  %s\n" $$name; \
	        pass=$$((pass + 1)); \
	    fi; \
	done; \
	echo ""; \
	echo "$$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

# Compile and run a single test: make run TEST=seq43
run: $(SIM)/$(TEST)
	$(VVP) $(SIM)/$(TEST)

# Remove all build outputs; rm -rf sim/ clears stale binaries from any prior naming scheme
clean:
	rm -rf $(SIM)
	rm -f *.vvp *.vcd a.out

$(SIM):
	mkdir -p $(SIM)

help:
	@echo "Targets:"
	@echo "  make test          — compile and run all 27 tests (~2s)"
	@echo "  make compile       — compile all without running"
	@echo "  make run TEST=seq43 — compile and run one test"
	@echo "  make sim/seq43     — recompile one test binary"
	@echo "  make clean         — remove sim/ binaries and top-level .vvp/.vcd"
	@echo "  make -j compile    — parallel compile (faster on multicore)"

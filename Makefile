SHELL     := bash
.SHELLFLAGS := -c

# ── Simulator ──────────────────────────────────────────────────────────────
IV       := iverilog
VVP      := vvp
IVFLAGS  := -g2012 -I rtl -I tb
# oss-cad-suite yosys, used only by the `lint-drivers` target below.
YOSYS_BIN ?= $(HOME)/oss-cad-suite/bin/yosys
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

# rtl/eu_seq.sv's own body is split across two `` `include ``'d fragments
# (rtl/eu_seq_decode.svh, rtl/eu_seq_execute.svh) for navigability -- pure
# text substitution, same compiled module. This rule means every target that
# already lists rtl/eu_seq.sv as a prerequisite (directly or via $(EU_SRCS),
# which is nearly every target in this Makefile) correctly rebuilds if
# either .svh changes, without needing per-target edits (unlike
# tb/common_helpers.svh's own order-only-prereq approach, appropriate there
# since only 2 targets consume it). A no-recipe rule alone does NOT do this
# under GNU Make 3.81 (confirmed empirically: `make -n` reports "Nothing to
# be done" and never propagates staleness downstream) -- Make's own
# staleness check for a target vs. rtl/eu_seq.sv is purely an mtime
# comparison, and nothing ever bumps rtl/eu_seq.sv's own mtime without an
# actual recipe. `touch $@` is the standard GNU Make idiom for exactly this
# "propagate a dependency without regenerating content" case -- it only
# runs (and only bumps the mtime) when a .svh is genuinely newer, content is
# never touched, so this has zero effect on `git status`/content hashing.
rtl/eu_seq.sv: rtl/eu_seq_decode.svh rtl/eu_seq_execute.svh
	@touch $@

BIU_SRCS := \
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

# MH030-P: the pipelined integer core (P2).
$(SIM)/mh030p_core: rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
                    rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtlp/mh030p_uop.svh \
                    rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
                    rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv rtl/eu_bitfield.sv \
                    tb/mh030p_core_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
	    rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/opcode_fields.sv rtl/eu_alu.sv \
	    rtl/eu_shifter.sv rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv rtl/eu_bitfield.sv \
	    tb/mh030p_core_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

# MH030-P: the new pipelined multiplier against the frozen reference.
$(SIM)/mh030p_mul: rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/eu_mul_div.sv \
                   tb/mh030p_mul_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ tb/mh030p_mul_tb.sv \
	    rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/eu_mul_div.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

# MH030-P: fetch unit + core running a program out of memory.
$(SIM)/mh030p_top: rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv rtlp/mh030p_ifu.sv \
                   rtlp/mh030p_core.sv \
                   rtlp/mh030p_regfile.sv rtlp/mh030p_decode.sv \
                   rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv \
                   rtlp/mh030p_uop.svh rtl/opcode_fields.sv rtl/eu_alu.sv \
                   rtl/eu_shifter.sv rtl/eu_mul_div.sv rtl/eu_bitops.sv \
                   rtl/eu_bcd.sv tb/mh030p_top_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv \
	    rtlp/mh030p_ifu.sv \
	    rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv rtlp/mh030p_decode.sv \
	    rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv \
	    rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv rtl/eu_mul_div.sv \
	    rtl/eu_bitops.sv rtl/eu_bcd.sv rtl/eu_bitfield.sv tb/mh030p_top_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

# MH030-P: the Tom Harte corpus against the pipelined core. Same output
# contract as $(SIM)/harte_dat, so scripts/run_harte.py --sim drives either.
# Bit-field equivalence sweep. The Harte corpus is 68000-captured and has ZERO
# bit-field coverage (68020+ instructions), so sequentialising that unit needed a
# net built from scratch -- this compares rtlp/mh030p_bitfield.sv against
# rtl/eu_bitfield.sv over every offset, width and op.
$(SIM)/bf_equiv: rtlp/mh030p_bitfield.sv rtl/eu_bitfield.sv tb/bf_equiv_tb.sv \
                 | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_bitfield.sv \
	    rtl/eu_bitfield.sv tb/bf_equiv_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

$(SIM)/cosim_p: rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv rtlp/mh030p_ifu.sv \
                rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
                rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtlp/mh030p_uop.svh \
                rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
                rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv \
                rtl/eu_bitfield.sv tb/cosim_p_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv \
	    rtlp/mh030p_ifu.sv rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
	    rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/opcode_fields.sv \
	    rtl/eu_alu.sv rtl/eu_shifter.sv rtl/eu_mul_div.sv rtl/eu_bitops.sv \
	    rtl/eu_bcd.sv rtl/eu_bitfield.sv tb/cosim_p_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

$(SIM)/harte_p: rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv rtlp/mh030p_ifu.sv \
                rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
                rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtlp/mh030p_uop.svh \
                rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
                rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv \
                rtl/eu_bitfield.sv tb/harte_p_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv \
	    rtlp/mh030p_ifu.sv rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
	    rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/opcode_fields.sv \
	    rtl/eu_alu.sv rtl/eu_shifter.sv rtl/eu_mul_div.sv rtl/eu_bitops.sv \
	    rtl/eu_bcd.sv rtl/eu_bitfield.sv tb/harte_p_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

# MH030-P: new-core decoder vs the reference decoder, all 65536 opcodes.
# Needs -I rtlp for mh030p_uop.svh, so it cannot use the plain $(IVCOMP).
# MH030-P on the REAL BIU (plan A4). rtlp's CPU plus rtl/'s own verified BIU
# and both genuine 68030 caches, driven through real pins by a pin-level
# peripheral. This is the configuration that measures what the A4 contract
# actually costs, so it needs BIU_SRCS as well as the rtlp sources -- but NOT
# m68030_seq/eu/exc/mmu, since the pipelined core replaces all four.
MH030P_BIU_SRCS := rtlp/mh030p_biu_top.sv rtlp/mh030p_cpu.sv \
                   rtlp/mh030p_ifu.sv rtlp/mh030p_core.sv \
                   rtlp/mh030p_regfile.sv rtlp/mh030p_decode.sv \
                   rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv \
                   rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
                   rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv \
                   rtl/eu_bitfield.sv \
                   rtl/m68030_biu.sv $(BIU_SRCS)

$(SIM)/mh030p_biu: $(MH030P_BIU_SRCS) rtlp/mh030p_uop.svh \
                   tb/mh030p_biu_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ tb/mh030p_biu_tb.sv \
	    $(MH030P_BIU_SRCS) 2>&1 \
	  || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	  | grep -v "^$$" || true

$(SIM)/uop_equiv: rtlp/mh030p_decode.sv rtlp/mh030p_uop.svh \
                  rtl/opcode_fields.sv rtl/eu_seq.sv rtl/eu_seq_decode.svh \
                  rtl/eu_seq_execute.svh rtl/eu_seq_preview.svh \
                  rtl/m68030_seq.sv \
                  rtl/eu_bitfield.sv tb/uop_decode_equiv_tb.sv | $(SIM)
	@{ $(IV) $(IVFLAGS) -I rtlp -o $@ rtlp/mh030p_decode.sv rtl/opcode_fields.sv \
	    rtl/eu_seq.sv rtl/m68030_seq.sv \
	    rtl/eu_bitfield.sv tb/uop_decode_equiv_tb.sv 2>&1 \
	    || { echo "ERROR: $@ compile failed"; exit 1; }; } \
	    | grep -Ev "sorry:|warning:|^$$" ; exit $${PIPESTATUS[0]}

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

$(SIM)/minrepro:      $(TOP_SRCS) tb/minrepro_tb.sv | tb/common_helpers.svh $(SIM)
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
VLATOR_FLAGS := --cc -sv -Irtl --Mdir $(VOBJ) --top-module mustest_tb \
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
VLATOR_FLAGS_HARTE := --cc -sv -Irtl --Mdir $(VOBJ_HARTE) --top-module harte_verilator_tb \
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

# ── Verilator build for the batched MH030-P Harte runner ────────────────────
# The Icarus runner (sim/harte_p) stays the per-suite debugging tool; this is
# the only practical way to sweep the full corpus against the new core, for
# exactly the reason the rtl/ Verilator backend exists.
RTLP_SRCS := rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv rtlp/mh030p_ifu.sv \
             rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
             rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv \
             rtl/opcode_fields.sv rtl/eu_alu.sv rtl/eu_shifter.sv \
             rtl/eu_mul_div.sv rtl/eu_bitops.sv rtl/eu_bcd.sv \
             rtl/eu_bitfield.sv
VOBJ_HARTE_P := obj_harte_p_vbatch
VLATOR_FLAGS_HARTE_P := --cc -sv -Irtlp -Irtl --Mdir $(VOBJ_HARTE_P) \
                --top-module harte_p_verilator_tb \
                --x-assign 0 --x-initial 0 -Wno-fatal -Wno-WIDTHTRUNC \
                -Wno-WIDTHEXPAND -Wno-CASEINCOMPLETE -Wno-INITIALDLY \
                --public -fno-dfg

$(VOBJ_HARTE_P)/Vharte_p_verilator_tb: $(RTLP_SRCS) rtlp/mh030p_uop.svh \
                tb/harte_p_verilator_tb.sv tb/harte_p_verilator_main.cpp \
                | $(VOBJ_HARTE_P)
	$(VLATOR) $(VLATOR_FLAGS_HARTE_P) --exe ../tb/harte_p_verilator_main.cpp \
	    $(RTLP_SRCS) tb/harte_p_verilator_tb.sv
	$(MAKE) -C $(VOBJ_HARTE_P) -f Vharte_p_verilator_tb.mk OPT_FAST="-O2"

$(VOBJ_HARTE_P):
	mkdir -p $(VOBJ_HARTE_P)

sim/harte_pvbatch: $(VOBJ_HARTE_P)/Vharte_p_verilator_tb | $(SIM)
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
    $(SIM)/bf_equiv $(SIM)/ifu $(SIM)/seq_ctrl $(SIM)/ext_count_overlap $(SIM)/pipeline $(SIM)/stall_hazard $(SIM)/exc $(SIM)/mmu \
    $(SIM)/biu $(SIM)/biu_int \
    $(SIM)/top $(SIM)/cosim_boot $(SIM)/cosim_smoke $(SIM)/stall_fsm $(SIM)/cache $(SIM)/mmu_xlate \
    $(SIM)/minrepro $(SIM)/uop_equiv $(SIM)/mh030p_mul $(SIM)/mh030p_core $(SIM)/mh030p_top

# tb/minrepro_tb.sv: regression test for
# project_skiptx_branch_target_regwrite_bug.md -- now FIXED (m68030_ifu.sv
# holds fetch_addr_r/fetch_pend_r stable across a redirect while a fetch is
# genuinely still in flight, instead of letting the eventual stale ack get
# misattributed to whatever the IFU has since re-armed for). Moved into
# ALL_TESTS above now that it passes (make test: 38/38).

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

# ── MH030-P bus data-order comparison ───────────────────────────────────────
# What Harte cannot check. The corpus compares architectural state at the end of
# one instruction, so it is blind to the ORDER of memory accesses -- a
# memory-to-memory move that writes before it reads, a MOVEM walking its
# registers backwards, PACK's two reversed byte accesses would all pass it.
#
# --data-only, because this core's fetch unit fills its queue a LONGWORD at a
# time where rtl/ fetches a word: the two program streams differ in count and
# size by design, so comparing them says nothing, while the data stream is
# exactly the part that carries access-order information.
#
# --skip-dut 2 drops this core's own reset-vector reads, which it issues on the
# data port where rtl/ issues them on the program port (see plan.md -- rtl/'s FC
# there is an unoverridden default, so which is right is genuinely open).
#
# FOUR targets. memind7 and memind13 joined once rtlp gained non-indirect
# full-format EAs -- they use ($100,a0,d1.l) and (-$10000,a0,d1.l), which are
# plain base + base-displacement + scaled-index arithmetic. The other 63
# reference logs need GENUINE memory indirection (a memory read in the middle of
# address generation, which this core has no path for) or one of the four uop
# classes rtlp still cannot execute. See plan.md.
PCOSIM_TARGETS := smoke timing_preview_idx_current_idx memind7 memind13

define PCOSIM_RULE
buscmp-p-$(1): $(SIM)/cosim_p winuae/tests/$(1)_ref.log tests/$(1).hex
	$$(VVP) $$(SIM)/cosim_p +hexfile=tests/$(1).hex +grp=$(1) 2>&1 \
	    | grep "^BUS" > /tmp/_dutp_$(1).log || true
	python3 tools/buscmp.py /tmp/_dutp_$(1).log winuae/tests/$(1)_ref.log \
	    --data-only --skip-dut 2
endef
$(foreach t,$(PCOSIM_TARGETS),$(eval $(call PCOSIM_RULE,$(t))))

# Cross-core THROUGHPUT benchmark. tests/bench1.s is loops with real memory
# traffic, unlike the 23-67 tick opcode-group programs, which are
# prologue-dominated and measure startup rather than execution. Both cores stop
# on the same event (their own execution-stop register) and cosim_p also reports
# where the ticks went.
.PHONY: bench
bench: $(SIM)/cosim_grp $(SIM)/cosim_p $(SIM)/mh030p_biu tests/bench1.hex tests/bench2.hex
	@echo "-- rtl/ (cycle-accurate)"
	@$(VVP) $(SIM)/cosim_grp +hexfile=tests/bench1.hex +grp=bench1 \
	    +cycles=400000 +settle=40000 2>&1 | grep -E "^EXECCYCLES|^PASS|^FAIL"
	@echo "-- rtl/ with its OWN caches enabled (CACR=\$$1111)"
	@echo "   also the regression for the burst-ack bug: both caches were given"
	@echo "   the same unqualified eu_burst_ack, so D0 came out wrong."
	@$(VVP) $(SIM)/cosim_grp +hexfile=tests/bench2.hex +grp=bench2 \
	    +cycles=400000 +settle=40000 +expected_d0=000007E0 2>&1 \
	    | grep -E "^EXECCYCLES|D0 correct|^FAIL"
	@echo "-- rtlp/ (pipelined, no caches)"
	@$(VVP) $(SIM)/cosim_p +hexfile=tests/bench1.hex +grp=bench1 \
	    +expected_d0=000007E0 2>&1 | grep -E "^EXECCYCLES|^BUDGET|^PASS|^FAIL"
	@echo "-- rtlp/ on the REAL BIU (plan A4), caches OFF"
	@$(VVP) $(SIM)/mh030p_biu +hexfile=tests/bench1.hex \
	    +cycles=120000 +expected_d0=000007E0 2>&1 \
	    | grep -E "^EXECCYCLES|^BUSTXN|D0 correct|^FAIL"
	@echo "-- rtlp/ on the REAL BIU (plan A4), the 68030's OWN caches (CACR=\$$1111)"
	@echo "   also the regression for the latched-burst-owner fix: the two caches"
	@echo "   qualified their burst ack on the LIVE grant, which moves mid-burst."
	@$(VVP) $(SIM)/mh030p_biu +hexfile=tests/bench2.hex \
	    +cycles=120000 +expected_d0=000007E0 2>&1 \
	    | grep -E "^EXECCYCLES|^BUSTXN|D0 correct|^FAIL"

.PHONY: cosim_p
cosim_p: $(patsubst %,buscmp-p-%,$(PCOSIM_TARGETS))

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

winuae/tests/bf_sizing%_ref.log: tools/m68ksim tests/bf_sizing%.hex | winuae/tests
	./tools/m68ksim tests/bf_sizing$*.hex 300 > $@

winuae/tests/pack_order%_ref.log: tools/m68ksim tests/pack_order%.hex | winuae/tests
	./tools/m68ksim tests/pack_order$*.hex 300 > $@
# memind25 needs more than the generic 300-cycle default: DIVS.L's own
# real (Musashi) divide microcode plus 4 chained MUL/DIV instructions
# don't complete within 300 cycles -- this explicit rule (which make
# prefers over the pattern rule above for this exact filename) overrides
# with 600.
winuae/tests/memind25_ref.log: tools/m68ksim tests/memind25.hex | winuae/tests
	./tools/m68ksim tests/memind25.hex 600 > $@
# memind40 needs even more than memind25's own 600: two real divide-microcode
# instructions (DIVS.L and DIVU.L) plus the indexed/full-format/imm EA
# overhead don't complete within 300 or even 600 cycles -- 900 needed.
winuae/tests/memind40_ref.log: tools/m68ksim tests/memind40.hex | winuae/tests
	./tools/m68ksim tests/memind40.hex 900 > $@

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
	    --reads-only --dut-may-continue --allow-adjacent-swap --allow-dut-extra-fetch
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
# --allow-fetch-interleave: memind25 divides, and eu_mul_div.sv's divider is
# sequential now (MH030-P P0 finding: it was 47% of the worst ECP5 critical
# path). The extra ~32 ticks let the IFU prefetch queue run further ahead
# before the next instruction's own data write issues, so two instruction
# fetches overtake that write. NOT waved through: the flag compares the
# program-fetch stream and the data stream independently and BOTH must still
# match exactly and in order -- here that is 24 fetches and 13 data cycles,
# byte-identical on both sides. Only the cross-stream interleaving differs,
# and Musashi (purely functional) never models prefetch overlap at all, so
# its interleaving is not a specification.
	python3 tools/buscmp.py /tmp/_dut_memind25.log winuae/tests/memind25_ref.log \
	    --dut-may-continue --allow-fetch-interleave
# memind28 (10-item backlog Stage 9a, plan.md): LEA's own genuine
# memory-indirect EA, ([bd,An],Xn,od) with fi_iis!=0 -- the first family
# beyond MOVE/MOVEA to support it. LEA never dereferences its own final
# EA, so the bus trace should show only ONE extra access beyond the
# instruction fetches (the inner pointer read) and never a second access
# at the resolved address; the computed EA is then stored to memory so the
# full comparison (not reads-only) directly proves the resolved value too.
buscmp-memind28: $(SIM)/cosim_grp winuae/tests/memind28_ref.log tests/memind28.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind28.hex +grp=memind28 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind28.log || true
	python3 tools/buscmp.py /tmp/_dut_memind28.log winuae/tests/memind28_ref.log \
	    --dut-may-continue
# memind29 (10-item backlog Stage 9a, plan.md): PEA's own genuine
# memory-indirect EA -- same shape as memind28, but PEA still needs a real
# outer bus cycle (a WRITE of the resolved EA to the stack, not a read at
# the resolved address like MOVE's own case). Full comparison directly
# proves both the inner pointer read AND the pushed value.
buscmp-memind29: $(SIM)/cosim_grp winuae/tests/memind29_ref.log tests/memind29.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind29.hex +grp=memind29 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind29.log || true
	python3 tools/buscmp.py /tmp/_dut_memind29.log winuae/tests/memind29_ref.log \
	    --dut-may-continue
# memind30 (10-item backlog Stage 9b, plan.md): JMP's own genuine
# memory-indirect EA -- shares LEA's own address-only shape (no outer bus
# cycle, becomes the new PC directly once the inner pointer read lands).
# Deliberately kept entirely within tools/m68ksim's own 4KB reference
# window (see the test's own header comment) -- a JMP target landing on
# an aliased address would be unsafe there, unlike memind13/16/17/21's
# own large-magnitude-displacement technique.
buscmp-memind30: $(SIM)/cosim_grp winuae/tests/memind30_ref.log tests/memind30.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind30.hex +grp=memind30 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind30.log || true
	python3 tools/buscmp.py /tmp/_dut_memind30.log winuae/tests/memind30_ref.log \
	    --dut-may-continue --allow-dut-extra-fetch
# memind31 (10-item backlog Stage 9b, plan.md): JSR's own genuine
# memory-indirect EA -- same outer-write shape as PEA's own memind arm,
# but pushes the return PC (not the resolved EA) and jumps to the
# resolved address instead. Found and fixed two real bugs while building
# this: dec_return_pc was hardcoded decode_pc+4 (wrong for any full-format
# JSR, indirect or not -- a pre-existing bug, not introduced this stage);
# and a first attempt forgot to suppress dec_is_mem_wr for the memind
# branch (mirroring PEA's own arm), which tripped ex_an_base's own
# "(ex_is_mem_wr && !ex_is_idx) ? rd_b_data : rd_a_data" special case
# (meant for JSR/PEA's own simple, non-indexed push forms), substituting
# Xn for An in the memind FSM's own inner-address capture.
buscmp-memind31: $(SIM)/cosim_grp winuae/tests/memind31_ref.log tests/memind31.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind31.hex +grp=memind31 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind31.log || true
	python3 tools/buscmp.py /tmp/_dut_memind31.log winuae/tests/memind31_ref.log \
	    --dut-may-continue --allow-dut-extra-fetch
# memind32-35 (general ALU-with-EA-source genuine indirect stage, plan.md):
# ADD.L (register write), DIVU.W (word-sized memory operand, exercises the
# memind read-size + timing fixes), CMP.L (no register write at all, flags
# only, verified via a conditional branch on the resulting CCR), and
# ADDA.L (An-destination, dec_dyn_bit_is_an's own swap path). Found and
# fixed two real, previously-latent RTL bugs while building these: (1)
# div_trap_raw's own md_div_by_zero check fired on the memind FSM's INNER
# read too (mem_ack fires twice for memind, once per phase), evaluating
# the still-in-flight pointer value as a divisor and causing a real
# simulation hang; (2) a genuine one-cycle timing mismatch -- ex_mem_stall's
# own memind term is the raw registered memind_outer_r, which clears one
# cycle after mem_ack (unlike the ordinary ex_is_mem_rd path, which clears
# the same cycle) -- so both dyn_bit_get_Dn's own register swap and the
# memory operand's own value needed re-timing to memind_outer_done_r, with
# a new memind_read_val_r latch holding the value across that gap (mem_rdata
# itself reverts the cycle after mem_ack).
buscmp-memind32: $(SIM)/cosim_grp winuae/tests/memind32_ref.log tests/memind32.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind32.hex +grp=memind32 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind32.log || true
	python3 tools/buscmp.py /tmp/_dut_memind32.log winuae/tests/memind32_ref.log \
	    --dut-may-continue
buscmp-memind33: $(SIM)/cosim_grp winuae/tests/memind33_ref.log tests/memind33.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind33.hex +grp=memind33 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind33.log || true
# --allow-fetch-interleave: DIVU.W via genuine memory-indirect EA, so the same
# cause as memind25/memind40 -- the sequential divider lets prefetch run ahead
# of the dependent store. Both streams still match exactly (12 fetches, 5 data
# cycles); only their interleaving differs.
	python3 tools/buscmp.py /tmp/_dut_memind33.log winuae/tests/memind33_ref.log \
	    --dut-may-continue --allow-fetch-interleave
buscmp-memind34: $(SIM)/cosim_grp winuae/tests/memind34_ref.log tests/memind34.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind34.hex +grp=memind34 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind34.log || true
	python3 tools/buscmp.py /tmp/_dut_memind34.log winuae/tests/memind34_ref.log \
	    --dut-may-continue --allow-dut-extra-fetch
buscmp-memind35: $(SIM)/cosim_grp winuae/tests/memind35_ref.log tests/memind35.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind35.hex +grp=memind35 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind35.log || true
	python3 tools/buscmp.py /tmp/_dut_memind35.log winuae/tests/memind35_ref.log \
	    --dut-may-continue
# memind36-37 (CMP2/CHK2 genuine indirect stage, plan.md): CMP2.L pre-indexed
# null-od (verified via a conditional branch on the resulting C flag, since
# CMP2 sets no directly-comparable register result) and CHK2.L post-indexed
# null-od (deliberately non-trapping, proving the FSM merge + EA resolution
# without re-verifying CHK2's own already-covered trap dispatch). Found and
# fixed two real, previously-latent bugs while building these: (1) a genuine
# bit-encoding bug in this session's own new dec_memind_od code -- the real
# fi_iis[1:0] od-size encoding is 01=null/10=word/11=long, not the
# 00=null/10=word/11=long a pre-existing (misleading, but harmlessly
# dead-code-safe elsewhere) fi_od comment in eu_seq.sv suggested; (2) a
# genuine one-cycle ex_mem_stall gap specific to CMP2/CHK2's own memind
# dispatch -- cmp2_run_r's memind-start branch keys off memind_outer_done_r
# (itself already one cycle behind mem_ack), so there's a further, distinct
# gap cycle (after memind_outer_r clears but before cmp2_run_r turns 1) that
# ex_mem_stall's existing terms didn't cover, letting EX prematurely accept
# the next instruction and corrupt ex_is_cmp2chk2 before the second
# (upper-bound) read ever completed -- manifested as a spurious CHK2 trap
# (found via a genuine post-indexed CHK2-via-memind cosim mismatch). Fixed
# with a new cmp2_memind_first_ack stall-hold term, mirroring cmp2_first_ack's
# own existing shape for the ordinary (non-memind) dispatch path.
buscmp-memind36: $(SIM)/cosim_grp winuae/tests/memind36_ref.log tests/memind36.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind36.hex +grp=memind36 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind36.log || true
	python3 tools/buscmp.py /tmp/_dut_memind36.log winuae/tests/memind36_ref.log \
	    --dut-may-continue --allow-dut-extra-fetch
buscmp-memind37: $(SIM)/cosim_grp winuae/tests/memind37_ref.log tests/memind37.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind37.hex +grp=memind37 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind37.log || true
	python3 tools/buscmp.py /tmp/_dut_memind37.log winuae/tests/memind37_ref.log \
	    --dut-may-continue
# memind38-39 (TAS/Scc genuine indirect stage, plan.md §Phase 245): TAS.B
# pre-indexed (RMW-locked bus protocol's own dispatch trigger restructured to
# wait for the memind FSM's inner-read completion) and Scc.B post-indexed
# (found and fixed a genuine, previously-undiscovered bug along the way:
# Scc-to-memory was modeled as a real read-modify-write, but real 68020+/
# 68030 Scc-to-memory is a plain write with no discarded read at all, per
# direct inspection of Musashi's own m68kops.c). Also found and fixed two
# genuine test-infrastructure gaps while building these: cosim_grp_tb.sv's
# own bus logger bracketed cycles on AS's edges, which only produces ONE log
# line for an entire RMW-locked read+write pair (AS stays asserted
# throughout; DS is what actually toggles per sub-phase) -- switched to
# DS-edge triggering. tools/buscmp.py's own byte/word comparison didn't
# account for the DUT's own real, address-aligned big-endian byte-lane
# positioning (vs. Musashi's own canonical zero-extended-low-value logging
# convention) -- fixed with lane-aware extraction, distinguishing the two
# log conventions by their own field width (Verilog %h's fixed 8 hex digits
# vs. Musashi's own size-matched %02x/%04x/%08x).
buscmp-memind38: $(SIM)/cosim_grp winuae/tests/memind38_ref.log tests/memind38.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind38.hex +grp=memind38 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind38.log || true
	python3 tools/buscmp.py /tmp/_dut_memind38.log winuae/tests/memind38_ref.log \
	    --dut-may-continue
buscmp-memind39: $(SIM)/cosim_grp winuae/tests/memind39_ref.log tests/memind39.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind39.hex +grp=memind39 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind39.log || true
	python3 tools/buscmp.py /tmp/_dut_memind39.log winuae/tests/memind39_ref.log \
	    --dut-may-continue
# memind40 (docs/*.md review, plan.md §Phase 247): MULU.L/MULS.L/DIVU.L/
# DIVS.L's own indexed EA and #imm forms -- the two forms Phase 192
# explicitly deferred ("would need the dyn_bit_get_Dn 3rd-operand-deferred-
# register trick for the Xn-vs-Dl/Dq register-port conflict... and a 2nd
# 32-bit immediate word"), entirely undecoded until this phase (real code
# using either form would hit an illegal-instruction fault). Covers brief
# indexed, full-format indexed (word bd), and #imm, mixing MUL/DIV and
# signed/unsigned.
buscmp-memind40: $(SIM)/cosim_grp winuae/tests/memind40_ref.log tests/memind40.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind40.hex +grp=memind40 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind40.log || true
# --allow-fetch-interleave: same cause as memind25 above -- memind40 runs two
# real divides, and the sequential divider lets prefetch run further ahead of
# the dependent data cycles. Both streams still match exactly (26 fetches, 10
# data cycles); only their interleaving differs. --allow-adjacent-swap is no
# longer needed once the streams are compared separately.
	python3 tools/buscmp.py /tmp/_dut_memind40.log winuae/tests/memind40_ref.log \
	    --dut-may-continue --allow-fetch-interleave
# memind41 (docs/*.md review, plan.md §Phase 247 item #9): CAS/CAS2 real
# bus-trace cosim test against Musashi -- the first ever built for either
# instruction. Closes the actual root cause behind the Dc/Du-swap decode bug
# item #9 found and fixed: no cosim/bus-trace test had ever exercised CAS or
# CAS2 before this phase.
buscmp-memind41: $(SIM)/cosim_grp winuae/tests/memind41_ref.log tests/memind41.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind41.hex +grp=memind41 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind41.log || true
	python3 tools/buscmp.py /tmp/_dut_memind41.log winuae/tests/memind41_ref.log \
	    --dut-may-continue
# memind42 (Phase 251 item 2): MOVEM's own genuine memory-indirect EA
# ([bd,An],Xn,od)/([bd,An,Xn],od) -- the last originally-deferred memind
# family (word-count sizing was already fixed at Phase 234; only the EA
# *value* resolution was missing). Covers store+pre-indexed and
# load+post-indexed, both long-sized (2 registers each -- a genuine
# single-register MOVEM list is silently rewritten by vasm into the
# equivalent plain MOVEA instruction, and word-sized 2-register transfers
# hit a known, pre-existing benign Musashi coalescing quirk unrelated to
# this feature, documented in the test's own header).
buscmp-memind42: $(SIM)/cosim_grp winuae/tests/memind42_ref.log tests/memind42.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/memind42.hex +grp=memind42 2>&1 \
	    | grep "^BUS" > /tmp/_dut_memind42.log || true
	python3 tools/buscmp.py /tmp/_dut_memind42.log winuae/tests/memind42_ref.log \
	    --dut-may-continue

# bf_sizing1/2 (project_bf_mem_longword_sizing_bug.md fix, plan.md): the
# bitfield-mem real minimal-footprint bus sizing fix -- bf_sizing1 covers
# the span==1 case (single BYTE read+write), bf_sizing2 covers the
# harder span==3 case (WORD then BYTE sub-accesses, the 2-sub-access
# shape this fix adds).
buscmp-bf_sizing1: $(SIM)/cosim_grp winuae/tests/bf_sizing1_ref.log tests/bf_sizing1.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/bf_sizing1.hex +grp=bf_sizing1 2>&1 \
	    | grep "^BUS" > /tmp/_dut_bf_sizing1.log || true
	python3 tools/buscmp.py /tmp/_dut_bf_sizing1.log winuae/tests/bf_sizing1_ref.log \
	    --dut-may-continue

buscmp-bf_sizing2: $(SIM)/cosim_grp winuae/tests/bf_sizing2_ref.log tests/bf_sizing2.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/bf_sizing2.hex +grp=bf_sizing2 2>&1 \
	    | grep "^BUS" > /tmp/_dut_bf_sizing2.log || true
	python3 tools/buscmp.py /tmp/_dut_bf_sizing2.log winuae/tests/bf_sizing2_ref.log \
	    --dut-may-continue

# pack_order1/2 (project_pack_source_read_order_bug.md fix, plan.md):
# PACK's own real 2-byte source-read order (pack_order1) and UNPK's own
# real 2-byte destination-write order (pack_order2), both the opposite
# of a standard big-endian word access.
buscmp-pack_order1: $(SIM)/cosim_grp winuae/tests/pack_order1_ref.log tests/pack_order1.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/pack_order1.hex +grp=pack_order1 2>&1 \
	    | grep "^BUS" > /tmp/_dut_pack_order1.log || true
	python3 tools/buscmp.py /tmp/_dut_pack_order1.log winuae/tests/pack_order1_ref.log \
	    --dut-may-continue

buscmp-pack_order2: $(SIM)/cosim_grp winuae/tests/pack_order2_ref.log tests/pack_order2.hex
	$(VVP) $(SIM)/cosim_grp +hexfile=tests/pack_order2.hex +grp=pack_order2 2>&1 \
	    | grep "^BUS" > /tmp/_dut_pack_order2.log || true
	python3 tools/buscmp.py /tmp/_dut_pack_order2.log winuae/tests/pack_order2_ref.log \
	    --dut-may-continue

cosim_memind: buscmp-memind2 buscmp-memind7 buscmp-memind10 buscmp-memind11 \
              buscmp-memind12 buscmp-memind13 buscmp-memind16 buscmp-memind17 buscmp-memind21 \
              buscmp-memind15 buscmp-memind24 buscmp-memind25 buscmp-memind26 buscmp-memind27 \
              buscmp-memind28 buscmp-memind29 buscmp-memind30 buscmp-memind31 \
              buscmp-memind36 buscmp-memind37 buscmp-memind38 buscmp-memind39 buscmp-memind40 \
              buscmp-memind41 buscmp-memind42 \
              buscmp-memind32 buscmp-memind33 buscmp-memind34 buscmp-memind35 \
              buscmp-bf_sizing1 buscmp-bf_sizing2 \
              buscmp-pack_order1 buscmp-pack_order2

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
# ── Multiple-driver lint (MH030-P) ──────────────────────────────────────────
# Catches a signal assigned from more than one always_ff block. That is a
# benign race in simulation -- the two blocks typically never fire in the same
# cycle -- but it synthesises to two physical flip-flops driving one net, and
# will NOT work on real hardware. Found the hard way: Phase A's own cache
# trickle sequencers left tag_i/valid_i/valid_d assigned from two blocks each,
# which the first full FPGA synthesis reported as 960 "multiple conflicting
# drivers" warnings buried in a 20MB log.
#
# `check` is the pass that reports it, and it must run after `proc`; a plain
# `proc; opt_clean` finds nothing. Needs sv2v + yosys (oss-cad-suite).
lint-drivers:
	@sv2v -I rtl $(TOP_SRCS) > /tmp/_mh030_lint.v
	@$(YOSYS_BIN) -p "read_verilog /tmp/_mh030_lint.v; proc; check" 2>&1 \
	    | grep -E "conflicting drivers" > /tmp/_mh030_lint.out || true
	@if [ -s /tmp/_mh030_lint.out ]; then \
	    echo "FAIL  multiple-driver lint:"; \
	    grep -oE "conflicting drivers for [^[]*" /tmp/_mh030_lint.out \
	        | sort | uniq -c | sort -rn; \
	    exit 1; \
	else echo "OK    no multiply-driven signals"; fi

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

# ── MH030-P: fast logic-depth proxy (seconds, not the 3-hour nextpnr run) ────
# A real Fmax measurement cannot resolve a change worth less than ~2 MHz (its
# seed-to-seed spread is ~0.5 MHz), so this reads the synthesised netlist
# instead. See scripts/logic_depth.py's header for the calibration.
DEPTH_SRC := rtl/opcode_fields.sv rtlp/mh030p_top.sv rtlp/mh030p_cpu.sv rtlp/mh030p_arb.sv \
             rtlp/mh030p_ifu.sv rtlp/mh030p_core.sv rtlp/mh030p_regfile.sv \
             rtlp/mh030p_decode.sv rtlp/mh030p_mul.sv rtlp/mh030p_shift.sv rtl/eu_alu.sv \
             rtl/eu_shifter.sv rtl/eu_mul_div.sv rtl/eu_bitops.sv \
             rtl/eu_bcd.sv rtl/eu_bitfield.sv
YOSYS_OSS ?= $(HOME)/oss-cad-suite/bin/yosys

.PHONY: depth
depth:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl $(DEPTH_SRC) > $(SIM)/depth.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/depth.v mh030p_top \
	    wrap_depth $(SIM)/depth_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/depth.v $(SIM)/depth_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_depth; \
	    write_json $(SIM)/depth.json' -l $(SIM)/depth_yosys.log > /dev/null
	@python3 scripts/logic_depth.py $(SIM)/depth.json

# ── Standalone core Fmax, both cores through the identical wrapper ───────────
# The plan's P2 gate is "a real Fmax number for the new architecture", and the
# new core cannot be dropped into the SoC -- its bus is abstract, not 68030
# pins. So both cores are measured STANDALONE through the same
# gen_fmax_wrapper.py harness that `make depth` already uses, which equalises
# their wildly different port counts (see that script's header). The absolute
# numbers are therefore not comparable to the ~13.8 MHz whole-SoC figure; the
# rtl/-vs-rtlp/ DIFFERENCE is what this measures, and that is the number the
# go/no-go rests on.
#
# SEED is fixed and explicit, never --randomize-seed. THREE SEEDS IS NOT
# ENOUGH -- measured directly: the unmodified baseline over seeds 1-9 gives
# 23.13 22.82 22.84 22.49 23.00 22.64 22.10 21.81 21.99, a range of 1.32 MHz,
# and seeds 1-3 happen to be its three BEST. Five separate RTL experiments were
# each measured at seeds 1-3, all landed ~1 MHz "below baseline", and every one
# of their means sits inside that range -- including one that only DELETED
# logic, which cannot lengthen a critical path. Use `make fmax-p-sweep` and
# treat anything under ~2 MHz as unresolved.
NEXTPNR_OSS ?= $(HOME)/oss-cad-suite/bin/nextpnr-ecp5
SEED        ?= 1
# TARGET FREQUENCY. Suspected of mattering -- without --freq, nextpnr
# constrains an unconstrained clock to 12 MHz and reports "PASS at 12.00 MHz",
# which looks like it would stop the tool optimising once cleared. TESTED, and
# it does NOT: the baseline gives bit-identical results at seeds 1/2/3 with and
# without it, so the ECP5 placer and router are timing-driven regardless and
# that line is reporting only. Kept because it states the intent and would
# matter if the design ever exceeded it.
FREQ        ?= 60


.PHONY: fmax-p fmax-rtl
fmax-p:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl $(DEPTH_SRC) > $(SIM)/fmaxp.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/fmaxp.v mh030p_top \
	    wrap_fmax $(SIM)/fmaxp_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/fmaxp.v $(SIM)/fmaxp_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/fmaxp.json' -l $(SIM)/fmaxp_yosys.log > /dev/null
# NO --ignore-loops, deliberately. The flag was in this recipe when the first
# measurement ran, and it was hiding SIX combinational loops in the new core --
# worth 78% of the worst path, and worth ~10 MHz once broken. Verilator's
# UNOPTFLAT did NOT report them (they closed through instance ports at the top
# level, and per-bit the cycle is false), so nextpnr's own loop detection is the
# stronger check and the only one that caught it. Leaving the flag off makes a
# new loop a hard failure instead of a slow mystery. fmax-rtl keeps it: rtl/ is
# frozen, and this is the recipe every trustworthy measurement of it used.
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/fmaxp.json \
	    --seed $(SEED) --freq $(FREQ) --timing-allow-fail \
	    --report $(SIM)/fmaxp_report-$(SEED).json 2>&1 \
	    | grep -E "Max frequency|Total LUT4s|TRELLIS_FF|combinational loop"
# Fmax of the ext_words cone ALONE -- see tb/extw_probe.sv's header. ~30 s, and
# the only fast feedback loop for the structure that currently binds the design.
.PHONY: fmax-extw
fmax-extw:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl rtlp/mh030p_decode.sv rtl/opcode_fields.sv \
	    tb/extw_probe.sv > $(SIM)/extw.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/extw.v extw_probe \
	    wrap_fmax $(SIM)/extw_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/extw.v $(SIM)/extw_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/extw.json' -l $(SIM)/extw_yosys.log > /dev/null
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/extw.json \
	    --seed $(SEED) --freq 200 --timing-allow-fail 2>&1 \
	    | grep -E "Max frequency"

# Fmax of the Stage 1 shallow ext_words_fast_o cone -- same wrapper shape as
# fmax-extw, for a direct before/after comparison. See tb/extw_fast_probe.sv.
.PHONY: fmax-extw-fast
fmax-extw-fast:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl rtlp/mh030p_decode.sv rtl/opcode_fields.sv \
	    tb/extw_fast_probe.sv > $(SIM)/extwf.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/extwf.v extw_fast_probe \
	    wrap_fmax $(SIM)/extwf_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/extwf.v $(SIM)/extwf_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/extwf.json' -l $(SIM)/extwf_yosys.log > /dev/null
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/extwf.json \
	    --seed $(SEED) --freq 200 --timing-allow-fail 2>&1 \
	    | grep -E "Max frequency"

# Fmax of the COMPLETE shallow replacement (brief + full-format addendum).
# See tb/extw_fast_full_probe.sv.
.PHONY: fmax-extw-fast-full
fmax-extw-fast-full:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl rtlp/mh030p_decode.sv rtl/opcode_fields.sv \
	    tb/extw_fast_full_probe.sv > $(SIM)/extwff.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/extwff.v extw_fast_full_probe \
	    wrap_fmax $(SIM)/extwff_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/extwff.v $(SIM)/extwff_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/extwff.json' -l $(SIM)/extwff_yosys.log > /dev/null
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/extwff.json \
	    --seed $(SEED) --freq 200 --timing-allow-fail 2>&1 \
	    | grep -E "Max frequency"

# The A4 configuration: rtlp's CPU plus rtl/'s real BIU and both caches. This is
# the number that matters for hardware, because it is the only rtlp arm that can
# actually drive a bus -- mh030p_top's 29.16 MHz is measured on a core with no
# bus interface in it at all, so it is not comparable with fmax-rtl.
#
# --ignore-loops is NOT passed here for the same reason fmax-p omits it: a loop
# should be a hard failure, not a slow mystery. If the BIU brings loops of its own
# (fmax-rtl passes the flag), this will fail loudly and that is the useful outcome.
.PHONY: fmax-pbiu
fmax-pbiu:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl $(MH030P_BIU_SRCS) > $(SIM)/fmaxpb.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/fmaxpb.v mh030p_biu_top \
	    wrap_fmax $(SIM)/fmaxpb_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/fmaxpb.v $(SIM)/fmaxpb_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/fmaxpb.json' -l $(SIM)/fmaxpb_yosys.log > /dev/null
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/fmaxpb.json \
	    --seed $(SEED) --freq $(FREQ) --timing-allow-fail \
	    --report $(SIM)/fmaxpb_report-$(SEED).json 2>&1 \
	    | grep -E "Max frequency|Total LUT4s|TRELLIS_FF|combinational loop"

.PHONY: fmax-pbiu-sweep
fmax-pbiu-sweep:
	@rm -f $(SIM)/fmax_pbiu_sweep.txt
	@for s in $$(seq 1 $(SEEDS)); do \
	    v=$$($(MAKE) -s fmax-pbiu SEED=$$s 2>&1 \
	         | grep -E "Max frequency" | tail -1 \
	         | grep -oE "[0-9.]+ MHz" | head -1 | cut -d' ' -f1); \
	    echo "seed $$s: $$v MHz"; echo "$$v" >> $(SIM)/fmax_pbiu_sweep.txt; \
	done
	@python3 -c "import sys; v=[float(x) for x in open('$(SIM)/fmax_pbiu_sweep.txt')]; \
	    v.sort(); n=len(v); \
	    print('n=%d  mean=%.2f  min=%.2f  max=%.2f  range=%.2f MHz' \
	          % (n, sum(v)/n, v[0], v[-1], v[-1]-v[0]))"

fmax-rtl:
	@mkdir -p $(SIM)
	@sv2v -I rtl $(TOP_SRCS) > $(SIM)/fmaxr.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/fmaxr.v m68030_top \
	    wrap_fmax $(SIM)/fmaxr_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/fmaxr.v $(SIM)/fmaxr_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax; \
	    write_json $(SIM)/fmaxr.json' -l $(SIM)/fmaxr_yosys.log > /dev/null
	@$(NEXTPNR_OSS) --85k --package CABGA381 --json $(SIM)/fmaxr.json \
	    --seed $(SEED) --freq $(FREQ) --ignore-loops --timing-allow-fail \
	    --report $(SIM)/fmaxr_report-$(SEED).json 2>&1 \
	    | grep -E "Max frequency|Total LUT4s|TRELLIS_FF"

# Sweep seeds and report mean/min/max, because one seed says almost nothing and
# three says less than it appears to (see the SEED note above). SEEDS defaults
# to 9, which is what it took to see the baseline's real 1.32 MHz spread.
# Per-module area, with attribution that is actually trustworthy. A FLATTENED
# netlist's cell names lie -- all five of mh030p_mul's DSPs come out named
# `u_dut.u_ifu.req_epoch_...` -- so this synthesises with -noflatten and counts
# each module's own cells. ~15 s. Use this, never cell-name prefixes, to decide
# where the logic is.
.PHONY: area-p
area-p:
	@mkdir -p $(SIM)
	@sv2v -I rtlp -I rtl $(DEPTH_SRC) > $(SIM)/areap.v
	@python3 scripts/gen_fmax_wrapper.py $(SIM)/areap.v mh030p_top \
	    wrap_fmax $(SIM)/areap_wrap.v
	@$(YOSYS_OSS) -p 'read_verilog $(SIM)/areap.v $(SIM)/areap_wrap.v; \
	    synth_lattice -family ecp5 -top wrap_fmax -noflatten; \
	    write_json $(SIM)/areap.json' -l $(SIM)/areap_yosys.log > /dev/null
	@python3 scripts/module_area.py $(SIM)/areap.json

SEEDS ?= 9
.PHONY: fmax-p-sweep
fmax-p-sweep:
	@rm -f $(SIM)/fmax_sweep.txt
	@for s in $$(seq 1 $(SEEDS)); do \
	    v=$$($(MAKE) -s fmax-p SEED=$$s 2>&1 \
	         | grep -E "Max frequency" | tail -1 \
	         | grep -oE "[0-9.]+ MHz" | head -1 | cut -d' ' -f1); \
	    echo "seed $$s: $$v MHz"; echo "$$v" >> $(SIM)/fmax_sweep.txt; \
	done
	@python3 -c "import sys; v=[float(x) for x in open('$(SIM)/fmax_sweep.txt')]; \
	    v.sort(); n=len(v); \
	    print('n=%d  mean=%.2f  min=%.2f  max=%.2f  range=%.2f MHz' \
	          % (n, sum(v)/n, v[0], v[-1], v[-1]-v[0]))"

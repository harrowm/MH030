SHELL     := bash
.SHELLFLAGS := -c

# ── Simulator ──────────────────────────────────────────────────────────────
IV       := iverilog
VVP      := vvp
IVFLAGS  := -g2012 -I rtl
SIM      := sim

# Suppress the hundreds of harmless "sorry: constant selects" lines from
# Icarus 13 while still propagating iverilog's exit code on real errors.
IVCOMP = { $(IV) $(IVFLAGS) -o $@ $^ 2>&1 || { echo "ERROR: $@ compile failed"; exit 1; }; } \
         | grep -Ev "sorry:|^$$" ; exit $${PIPESTATUS[0]}

# ── Source lists (reused across many tests) ────────────────────────────────
EU_SRCS := \
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
    rtl/biu_mmu_if.sv \
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

$(SIM)/seq_ctrl:      rtl/m68030_seq.sv                  tb/seq_ctrl_tb.sv        | $(SIM)
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

$(SIM)/stall_fsm:     $(TOP_SRCS) tb/stall_fsm_tb.sv | $(SIM)
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
    $(SIM)/ifu $(SIM)/seq_ctrl $(SIM)/pipeline $(SIM)/stall_hazard $(SIM)/exc $(SIM)/mmu \
    $(SIM)/biu $(SIM)/biu_int \
    $(SIM)/top $(SIM)/cosim_boot $(SIM)/cosim_smoke $(SIM)/stall_fsm

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
	    --reads-only --dut-may-continue

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

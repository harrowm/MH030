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

$(SIM)/seq36:      $(EU_SRCS)                         tb/seq36_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq37:      $(EU_SRCS)                         tb/seq37_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq38:      $(EU_SRCS)                         tb/seq38_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq39:      $(EU_SRCS)                         tb/seq39_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq40:      $(EU_SRCS)                         tb/seq40_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq41:      $(EU_SRCS)                         tb/seq41_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq42:      $(EU_SRCS)                         tb/seq42_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq43:      $(EU_SRCS)                         tb/seq43_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq46:      $(EU_SRCS)                         tb/seq46_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq47:      $(EU_SRCS)                         tb/seq47_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq48:      $(EU_SRCS)                         tb/seq48_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq49:      $(EU_SRCS)                         tb/seq49_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq50:      $(EU_SRCS)                         tb/seq50_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq52:      $(EU_SRCS)                         tb/seq52_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq53:      $(EU_SRCS)                         tb/seq53_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq54:      $(EU_SRCS)                         tb/seq54_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq56:      $(EU_SRCS)                         tb/seq56_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq57:      $(EU_SRCS)                         tb/seq57_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq58:      $(EU_SRCS)                         tb/seq58_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq59:      $(EU_SRCS)                         tb/seq59_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq60:      $(EU_SRCS)                         tb/seq60_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq61:      $(EU_SRCS)                         tb/seq61_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq62:      $(EU_SRCS)                         tb/seq62_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq63:      $(EU_SRCS)                         tb/seq63_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq64:      $(EU_SRCS)                         tb/seq64_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq65:      $(EU_SRCS)                         tb/seq65_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq66:      $(EU_SRCS)                         tb/seq66_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq67:      $(EU_SRCS)                         tb/seq67_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq68:      $(EU_SRCS)                         tb/seq68_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq69:      $(EU_SRCS)                         tb/seq69_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq70:      $(EU_SRCS)                         tb/seq70_tb.sv      | $(SIM)
	$(IVCOMP)

$(SIM)/seq71:      $(EU_SRCS)                         tb/seq71_tb.sv      | $(SIM)
	$(IVCOMP)

# ── Standalone modules ─────────────────────────────────────────────────────
$(SIM)/ifu:        rtl/m68030_ifu.sv                  tb/ifu_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/seq_m:      rtl/m68030_seq.sv                  tb/seq_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/seq_int:    rtl/m68030_ifu.sv rtl/m68030_seq.sv $(EU_SRCS) \
                   tb/seq_int_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/exc:        rtl/m68030_exc.sv                  tb/exc_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/mmu:        rtl/m68030_mmu.sv rtl/biu_mmu_if.sv tb/mmu_tb.sv        | $(SIM)
	$(IVCOMP)

# ── BIU ───────────────────────────────────────────────────────────────────
$(SIM)/biu:        $(BIU_SRCS) tb/mem_model.sv        tb/biu_tb.sv        | $(SIM)
	$(IVCOMP)

$(SIM)/m68030_biu: rtl/m68030_biu.sv $(BIU_SRCS) \
                   tb/mem_model.sv tb/m68030_biu_tb.sv | $(SIM)
	$(IVCOMP)

# ── Top integration ────────────────────────────────────────────────────────
TOP_SRCS := rtl/m68030_top.sv rtl/m68030_biu.sv $(BIU_SRCS) \
            $(EU_SRCS) rtl/m68030_ifu.sv rtl/m68030_seq.sv \
            rtl/m68030_exc.sv rtl/m68030_mmu.sv

$(SIM)/top:        $(TOP_SRCS) tb/mem_model.sv tb/top_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim72:    $(TOP_SRCS) tb/cosim72_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim73:    $(TOP_SRCS) tb/cosim73_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_grp:  $(TOP_SRCS) tb/cosim_grp_tb.sv | $(SIM)
	$(IVCOMP)

$(SIM)/cosim_dat:  $(TOP_SRCS) tb/cosim_dat_tb.sv | $(SIM)
	$(IVCOMP)

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
    $(SIM)/seq36 $(SIM)/seq37 $(SIM)/seq38 $(SIM)/seq39 $(SIM)/seq40 \
    $(SIM)/seq41 $(SIM)/seq42 $(SIM)/seq43 $(SIM)/seq46 $(SIM)/seq47 $(SIM)/seq48 $(SIM)/seq49 $(SIM)/seq50 $(SIM)/seq52 $(SIM)/seq53 $(SIM)/seq54 $(SIM)/seq56 $(SIM)/seq57 $(SIM)/seq58 $(SIM)/seq59 $(SIM)/seq60 $(SIM)/seq61 $(SIM)/seq62 $(SIM)/seq63 $(SIM)/seq64 $(SIM)/seq65 $(SIM)/seq66 $(SIM)/seq67 $(SIM)/seq68 $(SIM)/seq69 $(SIM)/seq70 $(SIM)/seq71 \
    $(SIM)/ifu $(SIM)/seq_m $(SIM)/seq_int $(SIM)/exc $(SIM)/mmu \
    $(SIM)/biu $(SIM)/m68030_biu \
    $(SIM)/top $(SIM)/cosim72 $(SIM)/cosim73

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
        dat-replay dat-synth
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

# Phase 75: compare DUT bus log to reference
# Usage: make buscmp  (captures live DUT run and compares to reference)
buscmp: winuae/tests/smoke_ref.log
	$(VVP) $(SIM)/cosim73 2>&1 | grep "^BUS" > /tmp/_dut_smoke.log || true
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

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
$(SIM)/top:        rtl/m68030_top.sv rtl/m68030_biu.sv $(BIU_SRCS) \
                   $(EU_SRCS) rtl/m68030_ifu.sv rtl/m68030_seq.sv \
                   rtl/m68030_exc.sv rtl/m68030_mmu.sv \
                   tb/mem_model.sv tb/top_tb.sv | $(SIM)
	$(IVCOMP)

# ── Regression list (ordered: unit → EU → standalone → BIU → top) ─────────
ALL_TESTS := \
    $(SIM)/eu_regfile $(SIM)/eu_alu $(SIM)/eu_shifter $(SIM)/eu_mul_div \
    $(SIM)/eu_bcd $(SIM)/eu_bitops $(SIM)/agu \
    $(SIM)/eu_seq_tb $(SIM)/eu_tb \
    $(SIM)/seq36 $(SIM)/seq37 $(SIM)/seq38 $(SIM)/seq39 $(SIM)/seq40 \
    $(SIM)/seq41 $(SIM)/seq42 $(SIM)/seq43 $(SIM)/seq46 $(SIM)/seq47 $(SIM)/seq48 $(SIM)/seq49 $(SIM)/seq50 $(SIM)/seq52 \
    $(SIM)/ifu $(SIM)/seq_m $(SIM)/seq_int $(SIM)/exc $(SIM)/mmu \
    $(SIM)/biu $(SIM)/m68030_biu \
    $(SIM)/top

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

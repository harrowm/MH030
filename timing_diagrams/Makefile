# Timing-diagram generation pipeline.
#
# Each diagram needs: a testbench (tb/<name>_tb.sv) that dumps a VCD over
# exactly the bus cycle(s) of interest, a WaveDrom JSON spec derived from
# that VCD (scripts/vcd_to_wavedrom.py), a rendered PNG of that spec
# (wavedrom-cli), and a cropped PNG of the corresponding manual page
# (scripts/crop_manual_page.sh). See README.md for the full explanation
# and diagrams.md for the manifest of what's been generated so far.

RTL := ../rtl
IVERILOG := iverilog -g2012 -I $(RTL) -I ../tb
VVP := vvp

BIU_SRCS := $(RTL)/m68030_biu.sv $(RTL)/biu_cycle_gen.sv $(RTL)/biu_arbiter.sv \
            $(RTL)/biu_sizing_fsm.sv $(RTL)/biu_multiop_fsm.sv $(RTL)/biu_cache_if.sv \
            $(RTL)/biu_icache_if.sv $(RTL)/biu_mmu_if.sv $(RTL)/biu_mmu_arb.sv \
            $(RTL)/biu_exc_capture.sv $(RTL)/biu_byte_lane_ctrl.sv $(RTL)/biu_config.sv \
            $(RTL)/biu_pin_driver.sv $(RTL)/biu_error_handler.sv $(RTL)/biu_burst_ctrl.sv \
            ../tb/mem_model.sv

# Full CPU sources -- needed for diagrams driven through the real EU/decode
# pipeline (preview_dispatch) rather than a standalone m68030_biu instance
# (read_cycle). Mirrors ../Makefile's own TOP_SRCS exactly.
EU_SRCS := $(RTL)/opcode_fields.sv $(RTL)/eu_regfile.sv $(RTL)/eu_alu.sv \
           $(RTL)/eu_shifter.sv $(RTL)/eu_mul_div.sv $(RTL)/eu_bcd.sv \
           $(RTL)/eu_bitops.sv $(RTL)/eu_agu.sv $(RTL)/eu_bitfield.sv \
           $(RTL)/eu_seq.sv $(RTL)/m68030_eu.sv

TOP_SRCS := $(RTL)/m68030_top.sv $(RTL)/m68030_biu.sv $(RTL)/biu_cycle_gen.sv \
            $(RTL)/biu_arbiter.sv $(RTL)/biu_sizing_fsm.sv $(RTL)/biu_multiop_fsm.sv \
            $(RTL)/biu_cache_if.sv $(RTL)/biu_icache_if.sv $(RTL)/biu_mmu_if.sv \
            $(RTL)/biu_mmu_arb.sv $(RTL)/biu_exc_capture.sv $(RTL)/biu_byte_lane_ctrl.sv \
            $(RTL)/biu_config.sv $(RTL)/biu_pin_driver.sv $(RTL)/biu_error_handler.sv \
            $(RTL)/biu_burst_ctrl.sv $(EU_SRCS) $(RTL)/m68030_ifu.sv $(RTL)/m68030_seq.sv \
            $(RTL)/m68030_exc.sv $(RTL)/m68030_mmu.sv

.PHONY: all read_cycle preview_dispatch clean

all: read_cycle preview_dispatch

# ── read_cycle: Figure 7-21's own leftmost cycle (single word read) ────────
read_cycle: generated/read_cycle_sim.png generated/read_cycle_manual.png

sim_read_cycle: tb/read_cycle_tb.sv $(BIU_SRCS)
	$(IVERILOG) -o $@ $(BIU_SRCS) tb/read_cycle_tb.sv

read_cycle.vcd: sim_read_cycle
	$(VVP) sim_read_cycle

specs/read_cycle.json: read_cycle.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py read_cycle.vcd -o $@

generated/read_cycle_sim.png: specs/read_cycle.json
	npx --yes wavedrom-cli -i $< -p $@

generated/read_cycle_manual.png: scripts/crop_manual_page.sh
	./scripts/crop_manual_page.sh 194 "1150x1400+0+190" $@

# ── preview_dispatch: Phase 254's own EU-side dispatch-gap fix, shown
# through the real EU pipeline (CLAUDE.md) -- no manual figure to compare
# against (this is a project-specific optimization, not a datasheet
# cycle), so this diagram is sim-only, one PNG.
preview_dispatch: generated/preview_dispatch_sim.png

sim_preview_dispatch: tb/preview_dispatch_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/preview_dispatch_tb.sv

preview_dispatch.vcd: sim_preview_dispatch ../tests/timing_preview.hex
	$(VVP) sim_preview_dispatch

specs/preview_dispatch.json: preview_dispatch.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py preview_dispatch.vcd -o $@ --cycles 3 --margin-cycles 2

generated/preview_dispatch_sim.png: specs/preview_dispatch.json
	npx --yes wavedrom-cli -i $< -p $@

clean:
	rm -f sim_read_cycle sim_preview_dispatch *.vcd

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

.PHONY: all read_cycle clean

all: read_cycle

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

clean:
	rm -f sim_read_cycle *.vcd

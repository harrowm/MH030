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

.PHONY: all read_cycle read_cycle_eu preview_dispatch manual_722 manual_723 \
        manual_725 manual_726 manual_728 manual_730 manual_732 manual_736 \
        manual_738 manual_739 manual_744 manual_747 manual_749 manual_754 \
        manual_760 manual_764 clean

all: read_cycle read_cycle_eu preview_dispatch manual_722 manual_723 \
     manual_725 manual_726 manual_728 manual_730 manual_732 manual_736 \
     manual_738 manual_739 manual_744 manual_747 manual_749 manual_754 \
     manual_760 manual_764

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

# ── read_cycle_eu: the same Figure 7-21 word/byte/byte chain as
# read_cycle, but driven through the REAL EU/decode pipeline instead of
# m68030_biu standalone -- answers whether the gap read_cycle shows
# between its three cycles is closed once a real decoded instruction
# stream drives dispatch. Shares generated/read_cycle_manual.png (same
# figure, same crop) rather than needing its own manual crop.
read_cycle_eu: generated/read_cycle_eu_sim.png

sim_read_cycle_eu: tb/read_cycle_eu_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/read_cycle_eu_tb.sv

read_cycle_eu.vcd: sim_read_cycle_eu ../tests/timing_manual_chain.hex
	$(VVP) sim_read_cycle_eu

specs/read_cycle_eu.json: read_cycle_eu.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py read_cycle_eu.vcd -o $@ --cycles 3 --margin-cycles 2

generated/read_cycle_eu_sim.png: specs/read_cycle_eu.json
	npx --yes wavedrom-cli -i $< -p $@

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

# ── manual_725/726/730: same inline-32-bit-port-model shape as
# read_cycle_eu, different test program/testbench per figure. All three
# reuse the Figure 7-21 manual crop's own established recipe (own
# manual_NNN.png crop instead, generated once already via
# scripts/crop_manual_page.sh -- see diagrams.md for the page numbers).
manual_725: generated/manual_725_sim.png

sim_manual_725: tb/manual_725_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_725_tb.sv

manual_725.vcd: sim_manual_725 ../tests/timing_manual_725.hex
	$(VVP) sim_manual_725

specs/manual_725.json: manual_725.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_725.vcd -o $@ --cycles 4 --margin-cycles 2

generated/manual_725_sim.png: specs/manual_725.json
	npx --yes wavedrom-cli -i $< -p $@

manual_726: generated/manual_726_sim.png

sim_manual_726: tb/manual_726_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_726_tb.sv

manual_726.vcd: sim_manual_726 ../tests/timing_manual_726.hex
	$(VVP) sim_manual_726

specs/manual_726.json: manual_726.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_726.vcd -o $@ --cycles 3 --margin-cycles 2

generated/manual_726_sim.png: specs/manual_726.json
	npx --yes wavedrom-cli -i $< -p $@

manual_730: generated/manual_730_sim.png

sim_manual_730: tb/manual_730_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_730_tb.sv

manual_730.vcd: sim_manual_730 ../tests/timing_manual_730.hex
	$(VVP) sim_manual_730

specs/manual_730.json: manual_730.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_730.vcd -o $@ --cycles 1 --margin-cycles 3

generated/manual_730_sim.png: specs/manual_730.json
	npx --yes wavedrom-cli -i $< -p $@

# ── manual_732/738/744/747/749/760/764: the second diagram batch
# (synchronous STERM, burst, IACK/autovector, breakpoint, bus
# error/retry, bus arbitration, reset) -- see INDEX.md's own "Scope"
# section for what's covered vs. deliberately deferred within each
# category (including Figure 7-54's own late-retry variant, never
# built). All use the plain 32-bit inline-model template except where
# a testbench's own header comment says otherwise.
manual_732: generated/manual_732_sim.png

sim_manual_732: tb/manual_732_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_732_tb.sv

manual_732.vcd: sim_manual_732 ../tests/timing_manual_732.hex
	$(VVP) sim_manual_732

specs/manual_732.json: manual_732.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_732.vcd -o $@ --cycles 1 --margin-cycles 3 \
	    --extra-signals "sterm_n:/STERM,ciin_n:/CIIN,ciout_n:/CIOUT,ext_cbreq_n:/CBREQ,cback_n:/CBACK"

generated/manual_732_sim.png: specs/manual_732.json
	npx --yes wavedrom-cli -i $< -p $@

manual_736: generated/manual_736_sim.png

sim_manual_736: tb/manual_736_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_736_tb.sv

manual_736.vcd: sim_manual_736 ../tests/timing_manual_736.hex
	$(VVP) sim_manual_736

specs/manual_736.json: manual_736.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_736.vcd -o $@ --cycles 1 --margin-cycles 3 \
	    --extra-signals "sterm_n:/STERM,ciin_n:/CIIN,ciout_n:/CIOUT,ext_cbreq_n:/CBREQ,cback_n:/CBACK"

generated/manual_736_sim.png: specs/manual_736.json
	npx --yes wavedrom-cli -i $< -p $@

manual_738: generated/manual_738_sim.png

sim_manual_738: tb/manual_738_tb.sv $(TOP_SRCS) ../tb/mem_model.sv
	$(IVERILOG) -o $@ $(TOP_SRCS) ../tb/mem_model.sv tb/manual_738_tb.sv

manual_738.vcd: sim_manual_738 ../tests/timing_manual_738.hex
	$(VVP) sim_manual_738

specs/manual_738.json: manual_738.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_738.vcd -o $@ --cycles 1 --margin-cycles 52 \
	    --extra-signals "ext_cbreq_n:/CBREQ,cback_n:/CBACK"

generated/manual_738_sim.png: specs/manual_738.json
	npx --yes wavedrom-cli -i $< -p $@

manual_739: generated/manual_739_sim.png

sim_manual_739: tb/manual_739_tb.sv $(TOP_SRCS) ../tb/mem_model.sv
	$(IVERILOG) -o $@ $(TOP_SRCS) ../tb/mem_model.sv tb/manual_739_tb.sv

manual_739.vcd: sim_manual_739 ../tests/timing_manual_739.hex
	$(VVP) sim_manual_739

specs/manual_739.json: manual_739.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_739.vcd -o $@ --cycles 1 --margin-cycles 15 \
	    --extra-signals "ext_cbreq_n:/CBREQ,cback_n:/CBACK"

generated/manual_739_sim.png: specs/manual_739.json
	npx --yes wavedrom-cli -i $< -p $@

manual_744: generated/manual_744_sim.png

sim_manual_744: tb/manual_744_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_744_tb.sv

manual_744.vcd: sim_manual_744 ../tests/timing_manual_744.hex
	$(VVP) sim_manual_744

specs/manual_744.json: manual_744.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_744.vcd -o $@ --cycles 6 --margin-cycles 2 \
	    --extra-signals "avec_n:/AVEC"

generated/manual_744_sim.png: specs/manual_744.json
	npx --yes wavedrom-cli -i $< -p $@

manual_747: generated/manual_747_sim.png

sim_manual_747: tb/manual_747_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_747_tb.sv

manual_747.vcd: sim_manual_747 ../tests/timing_manual_747.hex
	$(VVP) sim_manual_747

specs/manual_747.json: manual_747.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_747.vcd -o $@ --cycles 3 --margin-cycles 2

generated/manual_747_sim.png: specs/manual_747.json
	npx --yes wavedrom-cli -i $< -p $@

manual_749: generated/manual_749_sim.png

sim_manual_749: tb/manual_749_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_749_tb.sv

manual_749.vcd: sim_manual_749 ../tests/timing_manual_749.hex
	$(VVP) sim_manual_749

specs/manual_749.json: manual_749.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_749.vcd -o $@ --cycles 2 --margin-cycles 3 \
	    --extra-signals "berr_n:/BERR"

generated/manual_749_sim.png: specs/manual_749.json
	npx --yes wavedrom-cli -i $< -p $@

manual_754: generated/manual_754_sim.png

sim_manual_754: tb/manual_754_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_754_tb.sv

manual_754.vcd: sim_manual_754 ../tests/timing_manual_754.hex
	$(VVP) sim_manual_754

specs/manual_754.json: manual_754.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_754.vcd -o $@ --cycles 2 --margin-cycles 10 \
	    --extra-signals "berr_n:/BERR,halt_n:/HALT"

generated/manual_754_sim.png: specs/manual_754.json
	npx --yes wavedrom-cli -i $< -p $@

manual_760: generated/manual_760_sim.png

sim_manual_760: tb/manual_760_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_760_tb.sv

manual_760.vcd: sim_manual_760 ../tests/timing_manual_760.hex
	$(VVP) sim_manual_760

specs/manual_760.json: manual_760.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_760.vcd -o $@ --cycles 2 --margin-cycles 55 \
	    --extra-signals "br_n:/BR,ext_bg_n:/BG,bgack_n:/BGACK"

generated/manual_760_sim.png: specs/manual_760.json
	npx --yes wavedrom-cli -i $< -p $@

manual_764: generated/manual_764_sim.png

sim_manual_764: tb/manual_764_tb.sv $(TOP_SRCS)
	$(IVERILOG) -o $@ $(TOP_SRCS) tb/manual_764_tb.sv

manual_764.vcd: sim_manual_764 ../tests/timing_manual_764.hex
	$(VVP) sim_manual_764

specs/manual_764.json: manual_764.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_764.vcd -o $@ --cycles 2 --margin-cycles 20 \
	    --extra-signals "rst_n:/RESET_IN,ext_rstout_n:/RSTOUT"

generated/manual_764_sim.png: specs/manual_764.json
	npx --yes wavedrom-cli -i $< -p $@

# ── manual_722/723/728: dynamic-bus-sizing diagrams (8-bit/16-bit port),
# driven through the real EU/decode pipeline PLUS the shared
# tb/mem_model.sv (its own configurable PORT_WIDTH parameter is what
# actually produces the multi-beat dynamic-sizing split these figures
# show -- the inline 32-bit-only model the other diagrams use can't).
manual_722: generated/manual_722_sim.png

sim_manual_722: tb/manual_722_tb.sv $(TOP_SRCS) ../tb/mem_model.sv
	$(IVERILOG) -o $@ $(TOP_SRCS) ../tb/mem_model.sv tb/manual_722_tb.sv

manual_722.vcd: sim_manual_722 ../tests/timing_manual_722.hex
	$(VVP) sim_manual_722

specs/manual_722.json: manual_722.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_722.vcd -o $@ --cycles 4 --margin-cycles 2

generated/manual_722_sim.png: specs/manual_722.json
	npx --yes wavedrom-cli -i $< -p $@

manual_723: generated/manual_723_sim.png

sim_manual_723: tb/manual_723_tb.sv $(TOP_SRCS) ../tb/mem_model.sv
	$(IVERILOG) -o $@ $(TOP_SRCS) ../tb/mem_model.sv tb/manual_723_tb.sv

manual_723.vcd: sim_manual_723 ../tests/timing_manual_723.hex
	$(VVP) sim_manual_723

specs/manual_723.json: manual_723.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_723.vcd -o $@ --cycles 2 --margin-cycles 2

generated/manual_723_sim.png: specs/manual_723.json
	npx --yes wavedrom-cli -i $< -p $@

manual_728: generated/manual_728_sim.png

sim_manual_728: tb/manual_728_tb.sv $(TOP_SRCS) ../tb/mem_model.sv
	$(IVERILOG) -o $@ $(TOP_SRCS) ../tb/mem_model.sv tb/manual_728_tb.sv

manual_728.vcd: sim_manual_728 ../tests/timing_manual_728.hex
	$(VVP) sim_manual_728

specs/manual_728.json: manual_728.vcd scripts/vcd_to_wavedrom.py
	python3 scripts/vcd_to_wavedrom.py manual_728.vcd -o $@ --cycles 2 --margin-cycles 2

generated/manual_728_sim.png: specs/manual_728.json
	npx --yes wavedrom-cli -i $< -p $@

clean:
	rm -f sim_read_cycle sim_preview_dispatch sim_manual_* *.vcd

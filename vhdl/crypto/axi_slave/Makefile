# Makefile — AXI Slave VHDL build and simulation
#
# Targets
#   all       : analyse all source files and elaborate the testbench
#   elaborate : elaborate the testbench
#   run       : run the simulation
#   clean     : remove all generated artefacts

GHDL = ghdl
STD  = --std=08

STAMP_PKG = .analysed_pkg
STAMP_WR  = .analysed_wr
STAMP_RD  = .analysed_rd
STAMP_TOP = .analysed_top
STAMP_TB  = .analysed_tb

TB_ENTITY = tb_axi_slave

$(STAMP_PKG): axi_slave_pkg.vhd
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_WR): axi_slave_wr.vhd $(STAMP_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_RD): axi_slave_rd.vhd $(STAMP_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_TOP): axi_slave.vhd $(STAMP_WR) $(STAMP_RD)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_TB): tb_axi_slave.vhd $(STAMP_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

.PHONY: all elaborate run clean

all: elaborate

elaborate: $(STAMP_TB)
	$(GHDL) -e $(STD) $(TB_ENTITY)

run: elaborate
	$(GHDL) -r $(STD) $(TB_ENTITY)

clean:
	rm -f $(STAMP_PKG) $(STAMP_WR) $(STAMP_RD) $(STAMP_TOP) $(STAMP_TB)
	rm -f work-obj08.cf $(TB_ENTITY)

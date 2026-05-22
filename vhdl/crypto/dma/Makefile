# Makefile — DMA Engine VHDL build and simulation
#
# Targets
#   all       : analyse all source files and elaborate the testbench
#   elaborate : elaborate the testbench
#   run       : run the simulation
#   clean     : remove all generated artefacts

GHDL      = ghdl
STD       = --std=08
TEMPLATES = ../../../templates
COMMON    = common_lib

# ─── Common library (template files, compiled into common_lib/) ───────────────

STAMP_AXI_PKG    = $(COMMON)/.analysed_axi_pkg
STAMP_FIFO       = $(COMMON)/.analysed_fifo
STAMP_SOFT_FIFO  = $(COMMON)/.analysed_soft_fifo_pkg
STAMP_AXI_MEM    = $(COMMON)/.analysed_axi_memory

$(COMMON):
	mkdir -p $(COMMON)

$(STAMP_AXI_PKG): $(TEMPLATES)/axi_pkg.vhd | $(COMMON)
	$(GHDL) -a $(STD) --work=common --workdir=$(COMMON) $<
	@touch $@

$(STAMP_FIFO): $(TEMPLATES)/fifo.vhd | $(COMMON)
	$(GHDL) -a $(STD) --work=common --workdir=$(COMMON) $<
	@touch $@

$(STAMP_SOFT_FIFO): $(TEMPLATES)/soft_fifo_pkg.vhd | $(COMMON)
	$(GHDL) -a $(STD) --work=common --workdir=$(COMMON) $<
	@touch $@

$(STAMP_AXI_MEM): $(TEMPLATES)/axi_memory.vhd $(STAMP_AXI_PKG) | $(COMMON)
	$(GHDL) -a $(STD) --work=common --workdir=$(COMMON) \
	    -P./$(COMMON) $<
	@touch $@

COMMON_STAMPS = $(STAMP_AXI_PKG) $(STAMP_FIFO) $(STAMP_SOFT_FIFO) $(STAMP_AXI_MEM)

# ─── DMA source files (compiled into work, depend on common) ─────────────────

FIFO_SRC  = fifo.vhd
JOIN_SRC  = block_join.vhd
SPLIT_SRC = block_split.vhd
RD_SRC    = dma_read_engine.vhd
WR_SRC    = dma_write_engine.vhd
TOP_SRC   = dma_engine.vhd
TB_SRC    = tb_dma_engine.vhd

STAMP_FIFO_LOCAL = .analysed_fifo_local
STAMP_JOIN       = .analysed_join
STAMP_SPLIT      = .analysed_split
STAMP_RD         = .analysed_rd
STAMP_WR         = .analysed_wr
STAMP_TOP        = .analysed_top
STAMP_TB         = .analysed_tb

TB_ENTITY = tb_dma_engine

$(STAMP_FIFO_LOCAL): $(FIFO_SRC)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_JOIN): $(JOIN_SRC) $(STAMP_FIFO_LOCAL)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_SPLIT): $(SPLIT_SRC) $(STAMP_FIFO_LOCAL)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_RD): $(RD_SRC) $(STAMP_JOIN)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_WR): $(WR_SRC) $(STAMP_SPLIT)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_TOP): $(TOP_SRC) $(STAMP_RD) $(STAMP_WR)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

$(STAMP_TB): $(TB_SRC) $(STAMP_TOP) $(COMMON_STAMPS)
	$(GHDL) -a $(STD) -P./$(COMMON) $<
	@touch $@

# ─── Phony targets ────────────────────────────────────────────────────────────

.PHONY: all elaborate run clean

all: elaborate

elaborate: $(STAMP_TB)
	$(GHDL) -e $(STD) -P./$(COMMON) $(TB_ENTITY)

run: elaborate
	$(GHDL) -r $(STD) -P./$(COMMON) $(TB_ENTITY)

clean:
	rm -f $(STAMP_FIFO_LOCAL) $(STAMP_JOIN) $(STAMP_SPLIT)
	rm -f $(STAMP_RD) $(STAMP_WR) $(STAMP_TOP) $(STAMP_TB)
	rm -f work-obj08.cf $(TB_ENTITY)
	rm -rf $(COMMON)

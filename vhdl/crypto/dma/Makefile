# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Makefile — DMA Engine VHDL build and simulation                        ║
# ║                                                                          ║
# ║  Targets                                                                 ║
# ║    all       : analyse all source files and elaborate the testbench      ║
# ║    elaborate : elaborate the testbench (links everything together)       ║
# ║    run       : run the simulation                                        ║
# ║    clean     : remove GHDL work library artefacts                       ║
# ╚══════════════════════════════════════════════════════════════════════════╝

GHDL = ghdl
STD  = --std=08

RD_SRC  = dma_read_engine.vhd
WR_SRC  = dma_write_engine.vhd
TOP_SRC = dma_engine.vhd
TB_SRC  = tb_dma_engine.vhd

STAMP_RD  = .analysed_rd
STAMP_WR  = .analysed_wr
STAMP_TOP = .analysed_top
STAMP_TB  = .analysed_tb

TB_ENTITY = tb_dma_engine

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all
all: elaborate

# ─────────────────────────────────────────────────────────────────────────────
$(STAMP_RD): $(RD_SRC)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_WR): $(WR_SRC)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_TOP): $(TOP_SRC) $(STAMP_RD) $(STAMP_WR)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_TB): $(TB_SRC) $(STAMP_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: elaborate
elaborate: $(STAMP_TB)
	$(GHDL) -e $(STD) $(TB_ENTITY)

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: run
run: elaborate
	$(GHDL) -r $(STD) $(TB_ENTITY)

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(STAMP_RD) $(STAMP_WR) $(STAMP_TOP) $(STAMP_TB)
	rm -f work-obj08.cf
	rm -f $(TB_ENTITY)

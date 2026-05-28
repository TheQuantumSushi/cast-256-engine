# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Makefile — GCM VHDL build and simulation                                ║
# ║                                                                          ║
# ║  Targets                                                                 ║
# ║    all       : analyse all sources and elaborate the testbench           ║
# ║    pkg       : analyse gcm_pkg.vhd                                       ║
# ║    gf128     : analyse gf128_mul.vhd                                     ║
# ║    ghash     : analyse ghash.vhd                                         ║
# ║    gcm       : analyse gcm.vhd                                           ║
# ║    tb        : analyse tb_gcm.vhd                                        ║
# ║    elaborate : elaborate the testbench                                   ║
# ║    run       : run the simulation                                        ║
# ║    clean     : remove GHDL work library artefacts                        ║
# ║                                                                          ║
# ║  Note: cast256 sources are re-analysed into this directory's work        ║
# ║  library so the project is self-contained. Changing any cast256 source   ║
# ║  invalidates the relevant stamp file and triggers re-analysis.           ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Tools ─────────────────────────────────────────────────────────────────────
GHDL   = ghdl
STD    = --std=08 -frelaxed

# ── cast256 source paths ──────────────────────────────────────────────────────
CAST_DIR    = ../cast256
CAST_PKG    = $(CAST_DIR)/cast256_pkg.vhd
CAST_KS     = $(CAST_DIR)/cast256_ks.vhd
CAST_ENC    = $(CAST_DIR)/cast256_enc.vhd
CAST_TOP    = $(CAST_DIR)/cast256.vhd

# ── GCM source files ──────────────────────────────────────────────────────────
PKG_SRC   = gcm_pkg.vhd
GF128_SRC = gf128_mul.vhd
GHASH_SRC = ghash.vhd
GCM_SRC   = gcm.vhd
TB_SRC    = tb_gcm.vhd

# ── Stamp files ───────────────────────────────────────────────────────────────
STAMP_CAST_PKG = .analysed_cast_pkg
STAMP_CAST_KS  = .analysed_cast_ks
STAMP_CAST_ENC = .analysed_cast_enc
STAMP_CAST_TOP = .analysed_cast_top
STAMP_PKG      = .analysed_pkg
STAMP_GF128    = .analysed_gf128
STAMP_GHASH    = .analysed_ghash
STAMP_GCM      = .analysed_gcm
STAMP_TB       = .analysed_tb

TB_ENTITY = tb_gcm

# ─────────────────────────────────────────────────────────────────────────────
# Default target
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all
all: elaborate

# ─────────────────────────────────────────────────────────────────────────────
# cast256 dependency chain (re-analysed into this work library)
# ─────────────────────────────────────────────────────────────────────────────

$(STAMP_CAST_PKG): $(CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_CAST_KS): $(CAST_KS) $(STAMP_CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_CAST_ENC): $(CAST_ENC) $(STAMP_CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(STAMP_CAST_TOP): $(CAST_TOP) $(STAMP_CAST_KS) $(STAMP_CAST_ENC)
	$(GHDL) -a $(STD) $<
	@touch $@

# ─────────────────────────────────────────────────────────────────────────────
# GCM source analysis
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: pkg
pkg: $(STAMP_PKG)

$(STAMP_PKG): $(PKG_SRC)
	$(GHDL) -a $(STD) $<
	@touch $@

.PHONY: gf128
gf128: $(STAMP_GF128)

$(STAMP_GF128): $(GF128_SRC) $(STAMP_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

.PHONY: ghash
ghash: $(STAMP_GHASH)

$(STAMP_GHASH): $(GHASH_SRC) $(STAMP_PKG) $(STAMP_GF128)
	$(GHDL) -a $(STD) $<
	@touch $@

.PHONY: gcm
gcm: $(STAMP_GCM)

$(STAMP_GCM): $(GCM_SRC) $(STAMP_PKG) $(STAMP_GHASH) $(STAMP_CAST_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

.PHONY: tb
tb: $(STAMP_TB)

$(STAMP_TB): $(TB_SRC) $(STAMP_GCM)
	$(GHDL) -a $(STD) $<
	@touch $@

# ─────────────────────────────────────────────────────────────────────────────
# Elaborate
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: elaborate
elaborate: $(STAMP_TB)
	$(GHDL) -e $(STD) $(TB_ENTITY)

# ─────────────────────────────────────────────────────────────────────────────
# Run simulation
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: run
run: elaborate
	$(GHDL) -r $(STD) $(TB_ENTITY) --vcd=tb_gcm.vcd

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(STAMP_CAST_PKG) $(STAMP_CAST_KS) $(STAMP_CAST_ENC) $(STAMP_CAST_TOP)
	rm -f $(STAMP_PKG) $(STAMP_GF128) $(STAMP_GHASH) $(STAMP_GCM) $(STAMP_TB)
	rm -f work-obj08.cf $(TB_ENTITY) tb_gcm.vcd

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Makefile — CAST-256 VHDL build, simulation and synthesis               ║
# ║                                                                          ║
# ║  Targets                                                                 ║
# ║    all         : analyse all source files and elaborate the testbench    ║
# ║    pkg         : analyse cast256_pkg.vhd                                 ║
# ║    ks          : analyse cast256_ks.vhd                                  ║
# ║    enc         : analyse cast256_enc.vhd                                 ║
# ║    top         : analyse cast256.vhd                                     ║
# ║    tb          : analyse tb_cast256.vhd                                  ║
# ║    elaborate   : elaborate the testbench (links everything together)     ║
# ║    run         : run the simulation with the default RFC 2612 vector     ║
# ║    synth       : run Vivado synthesis and timing analysis                ║
# ║    clean       : remove GHDL work library artefacts                     ║
# ║    cleanall    : clean + remove Vivado output files                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Tools ─────────────────────────────────────────────────────────────────────
GHDL    = ghdl
VIVADO  = vivado
STD     = --std=08

# ── Source files ──────────────────────────────────────────────────────────────
PKG_SRC = cast256_pkg.vhd
KS_SRC  = cast256_ks.vhd
ENC_SRC = cast256_enc.vhd
TOP_SRC = cast256.vhd
TB_SRC  = tb_cast256.vhd

# ── GHDL work library stamp files ────────────────────────────────────────────
# GHDL does not produce one output file per source; it writes everything into
# work-obj08.cf.  We use hidden stamp files (.analysed_*) to track which
# sources are up to date, so Make can skip re-analysis when nothing changed.
STAMP_PKG = .analysed_pkg
STAMP_KS  = .analysed_ks
STAMP_ENC = .analysed_enc
STAMP_TOP = .analysed_top
STAMP_TB  = .analysed_tb

# ── Top-level entity for elaboration and simulation ───────────────────────────
TB_ENTITY = tb_cast256

# ── Vivado script ─────────────────────────────────────────────────────────────
TCL_SCRIPT = synth_cast256.tcl

# ─────────────────────────────────────────────────────────────────────────────
# Default target
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all
all: elaborate

# ─────────────────────────────────────────────────────────────────────────────
# Per-file analysis targets
# Each stamp depends on the source file and on its upstream dependencies.
# ─────────────────────────────────────────────────────────────────────────────

# cast256_pkg — no VHDL dependencies
.PHONY: pkg
pkg: $(STAMP_PKG)

$(STAMP_PKG): $(PKG_SRC)
	$(GHDL) -a $(STD) $<
	@touch $@

# cast256_ks — depends on the package
.PHONY: ks
ks: $(STAMP_KS)

$(STAMP_KS): $(KS_SRC) $(STAMP_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

# cast256_enc — depends on the package
.PHONY: enc
enc: $(STAMP_ENC)

$(STAMP_ENC): $(ENC_SRC) $(STAMP_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

# cast256 top-level — depends on ks and enc
.PHONY: top
top: $(STAMP_TOP)

$(STAMP_TOP): $(TOP_SRC) $(STAMP_KS) $(STAMP_ENC)
	$(GHDL) -a $(STD) $<
	@touch $@

# testbench — depends on the top-level
.PHONY: tb
tb: $(STAMP_TB)

$(STAMP_TB): $(TB_SRC) $(STAMP_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

# ─────────────────────────────────────────────────────────────────────────────
# Elaborate
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: elaborate
elaborate: $(STAMP_TB)
	$(GHDL) -e $(STD) $(TB_ENTITY)

# ─────────────────────────────────────────────────────────────────────────────
# Run simulation (default RFC 2612 vector)
# Override key/plaintext from the command line if needed:
#   make run KEY=<64 hex chars> PT=<32 hex chars>
# ─────────────────────────────────────────────────────────────────────────────
KEY ?= 2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604
PT  ?= 00000000000000000000000000000000

.PHONY: run
run: elaborate
	$(GHDL) -r $(STD) $(TB_ENTITY) \
		-gKEY_HEX=$(KEY) \
		-gPT_HEX=$(PT)

# ─────────────────────────────────────────────────────────────────────────────
# Vivado synthesis and timing analysis
#
# Vivado output is teed to vivado_synth.log so the post-processing awk scripts
# can parse it without re-running the tool.
#
# Summary parsing:
#   utilization.rpt  → LUT count and utilisation % (read from Vivado's own
#                       "Util%" column — never computed manually, which was
#                       the source of the previous "17600% of device" bug)
#   vivado_synth.log → Fmax, critical path, WNS (from TCL puts lines)
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: synth
synth: $(TCL_SCRIPT)
	@$(VIVADO) -mode batch -source $(TCL_SCRIPT) 2>&1 | tee vivado_synth.log
	@echo ""
	@printf "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
	@printf "  Synthesis Summary — cast256 (%s)\n" \
		"$$(grep 'for part:' vivado_synth.log | awk '{print $$NF}' | head -1)"
	@printf "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
	@awk -F'|' '\
	/Slice LUTs\*/ { \
	    used = $$3; gsub(/ /, "", used); \
	    pct  = $$6; gsub(/ /, "", pct); \
	    printf "  Total LUTs       : %-8s (%.2f%% of device)\n", used, pct+0 } \
	/RAMB18E1 only/ { \
	    n = $$3; gsub(/ /, "", n); \
	    printf "  RAMB18E1         : %d\n", n+0 } \
	/Slice Registers / { \
	    if (!ff) { n = $$3; gsub(/ /, "", n); \
	               printf "  Flip-flops       : %d\n", n+0; ff = 1 } } \
	' utilization.rpt
	@awk '\
	/Estimated Fmax/  { printf "  Fmax             : %s %s\n",  $$(NF-1), $$NF } \
	/Critical path/   { printf "  Critical path    : %s %s\n",  $$(NF-1), $$NF } \
	/Worst slack/     { printf "  WNS              : %s %s\n",  $$(NF-1), $$NF } \
	' vivado_synth.log
	@printf "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(STAMP_PKG) $(STAMP_KS) $(STAMP_ENC) $(STAMP_TOP) $(STAMP_TB)
	rm -f work-obj08.cf
	rm -f $(TB_ENTITY)

.PHONY: cleanall
cleanall: clean
	rm -f timing_summary.rpt utilization.rpt vivado_synth.log
	rm -f vivado.jou vivado.log
	rm -rf .Xil
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
# ║    run       : run the simulation with formatted output                  ║
# ║    run-vcd   : run the simulation and dump a VCD waveform                ║
# ║    clean     : remove GHDL work library artefacts                        ║
# ║                                                                          ║
# ║  Note: cast256 sources are re-analysed into this directory's work        ║
# ║  library so the project is self-contained. Changing any cast256 source   ║
# ║  invalidates the relevant stamp file and triggers re-analysis.           ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Tools ─────────────────────────────────────────────────────────────────────
GHDL = ghdl
STD  = --std=08 -frelaxed

# ── cast256 source paths ──────────────────────────────────────────────────────
CAST_DIR = ../cast256
CAST_PKG = $(CAST_DIR)/cast256_pkg.vhd
CAST_KS  = $(CAST_DIR)/cast256_ks.vhd
CAST_ENC = $(CAST_DIR)/cast256_enc.vhd
CAST_TOP = $(CAST_DIR)/cast256.vhd

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
# Run simulation — formatted output, no VCD
#
# The awk script does two things:
#   1. For report note lines: strips the GHDL "file:line:col:@time:(report note):"
#      prefix so only the message text is printed — much cleaner to read.
#   2. Colour-codes PASS (green), FAIL/ERROR (red), WARN (yellow),
#      section separators and headers (cyan).
#
# Lines that are not report notes (elaboration info, etc.) pass through
# unchanged so nothing is silently dropped.
#
# --ieee-asserts=disable  : suppresses internal IEEE library assertions.
# --assert-level=failure     : only halt on severity failure; note/warning/error
#                               reports are printed but do not stop the run.
# ─────────────────────────────────────────────────────────────────────────────

define AWK_FILTER
/\(report note\):/ {
    sub(/.*\(report note\): /, "")
    if      (/PASS/)          { print "\033[0;32m" $$0 "\033[0m" }
    else if (/FAIL|ERROR/)    { print "\033[0;31m" $$0 "\033[0m" }
    else if (/WARN/)          { print "\033[0;33m" $$0 "\033[0m" }
    else if (/^#{2,}|^-{2,}/) { print "\033[0;36m" $$0 "\033[0m" }
    else                      { print }
    next
}
/\(report failure\)|assertion failure/ { print "\033[1;31m" $$0 "\033[0m"; next }
/\(report error\)/                     { print "\033[0;31m" $$0 "\033[0m"; next }
/\(report warning\)/                   { print "\033[0;33m" $$0 "\033[0m"; next }
{ print }
endef
export AWK_FILTER

.PHONY: run
run: elaborate
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "\033[1m  GCM Simulation — $(TB_ENTITY)\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_ENTITY) \
		--ieee-asserts=disable \
		--assert-level=failure \
		2>&1 | awk "$$AWK_FILTER"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

# ─────────────────────────────────────────────────────────────────────────────
# Run simulation with cycle timing report
#
# Filters [TIMING] report lines emitted by gcm.vhd and builds a per-phase
# table showing absolute cycle number and delta cycles between phases.
#
# Assumes CLK_PERIOD = 10 ns (hardcoded in gcm.vhd report statements).
#
# Phases reported (per test run):
#   START     → start_i asserted
#   H_START   → key schedule done; H = CAST256(K,0) starting
#   GCTR_INIT → H done + all AAD blocks hashed; GCTR starting
#   LEN_HASH  → all GCTR blocks done; length block GHASH starting
#   TAG_ENC   → length GHASH done; tag encryption starting
#   DONE      → done_o asserted
# ─────────────────────────────────────────────────────────────────────────────

define AWK_TIMING
BEGIN {
    run  = 0
    prev = 0
    t0   = 0
    CLK  = 10
    printf "\n"
}
/\[TIMING\]/ {
    sub(/.*\(report note\): /, "")
    # extract phase name (word after [TIMING]) and time in ns (last integer before "ns")
    match($$0, /\[TIMING\] ([A-Z_]+)\s+([0-9]+) ns/, arr)
    phase = arr[1]
    t_ns  = arr[2] + 0
    cyc   = int(t_ns / CLK)

    if (phase == "START") {
        run++
        t0   = t_ns
        prev = t_ns
        printf "  ╔══════════════════════════════════════════════════════╗\n"
        printf "  ║  Test run %-3d                                        ║\n", run
        printf "  ╠═══════════════╦══════════════╦══════════════╦════════╣\n"
        printf "  ║ %-13s ║ %12s ║ %12s ║ %6s ║\n", \
               "Phase", "abs ns", "abs cycles", "delta"
        printf "  ╠═══════════════╬══════════════╬══════════════╬════════╣\n"
        printf "  ║ %-13s ║ %12d ║ %12d ║ %6s ║\n", \
               phase, t_ns, cyc, "—"
    } else {
        delta = int((t_ns - prev) / CLK)
        printf "  ║ %-13s ║ %12d ║ %12d ║ %6d ║\n", \
               phase, t_ns, cyc, delta
        prev = t_ns
    }
    if (phase == "DONE") {
        total = int((t_ns - t0) / CLK)
        printf "  ╠═══════════════╬══════════════╬══════════════╬════════╣\n"
        printf "  ║ %-13s ║ %12s ║ %12s ║ %6d ║\n", \
               "TOTAL", "", "", total
        printf "  ╚═══════════════╩══════════════╩══════════════╩════════╝\n\n"
    }
}
endef
export AWK_TIMING

.PHONY: run-time
run-time: elaborate
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "\033[1m  GCM Cycle Timing — $(TB_ENTITY)\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_ENTITY) \
		--ieee-asserts=disable \
		--assert-level=failure \
		2>&1 | awk "$$AWK_TIMING"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"


# ─────────────────────────────────────────────────────────────────────────────
.PHONY: run-vcd
run-vcd: elaborate
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "\033[1m  GCM Simulation — $(TB_ENTITY)  [VCD → tb_gcm.vcd]\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_ENTITY) \
		--ieee-asserts=disable \
		--assert-level=failure \
		--vcd=tb_gcm.vcd \
		2>&1 | awk "$$AWK_FILTER"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "  Waveform written to \033[0;36mtb_gcm.vcd\033[0m"

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(STAMP_CAST_PKG) $(STAMP_CAST_KS) $(STAMP_CAST_ENC) $(STAMP_CAST_TOP)
	rm -f $(STAMP_PKG) $(STAMP_GF128) $(STAMP_GHASH) $(STAMP_GCM) $(STAMP_TB)
	rm -f work-obj08.cf $(TB_ENTITY) tb_gcm.vcd
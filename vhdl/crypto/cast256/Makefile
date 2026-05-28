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
# Runs Vivado in batch mode, tee-ing all output to vivado_synth.log so the
# full transcript is visible while also being parseable afterwards.
# Once synthesis completes, AWK_SYNTH_SUMMARY extracts and formats the key
# metrics from vivado_synth.log and utilization.rpt into a compact table.
#
# Metrics reported:
#   Timing     : Fmax, WNS, critical path, pass/fail status
#   Resources  : LUT6, total LUTs (%), RAMB18E1, FDRE, total cells
#   Per-module : cast256_enc cells, cast256_ks cells
# ─────────────────────────────────────────────────────────────────────────────

define AWK_SYNTH_SUMMARY
BEGIN {
    fmax = "N/A"; wns = "N/A"; crit = "N/A"; ts = "N/A"
    lut6 = 0; lut5 = 0; lut4 = 0; lut3 = 0; lut2 = 0; lut1 = 0
    ramb18 = 0; fdre = 0; total_cells = 0
    enc_cells = -1; ks_cells = -1
    total_luts = "N/A"; lut_pct = "N/A"
}

function commas(n,    s, r) {
    s = sprintf("%d", n + 0)
    r = ""
    while (length(s) > 3) {
        r = "," substr(s, length(s) - 2) r
        s = substr(s, 1, length(s) - 3)
    }
    return s r
}

# ── Timing metrics — TCL summary block at end of vivado_synth.log ────────────
# These patterns only appear in the synth log, not in any report file.
!/^#/ && / Estimated Fmax/ {
    tmp = $$0; sub(/.*: /, "", tmp); fmax = tmp
}
!/^#/ && / Worst slack/ {
    tmp = $$0; sub(/.*: /, "", tmp); sub(/ ns.*/, "", tmp); wns = tmp " ns"
}
!/^#/ && / Critical path/ {
    tmp = $$0; sub(/.*: /, "", tmp); sub(/ ns.*/, "", tmp); crit = tmp " ns"
}
!/^#/ && / Status/ {
    tmp = $$0; sub(/.*Status[[:space:]]*: /, "", tmp); ts = tmp
}

# ── Cell usage table: |N  |CellName  | Count|  (n=5 when split by |) ──────
# ── Instance areas  : |N  |Instance  |Module| Cells| (n=6)            ──────
# These rows start with |<digit> which cannot appear in utilization.rpt.
/^\|[0-9]/ {
    n = split($$0, f, "|")

    if (n == 5) {
        cell = f[3]; gsub(/ /, "", cell)
        cnt  = f[4]; gsub(/ /, "", cnt)
        if      (cell == "LUT6")     lut6   = cnt + 0
        else if (cell == "LUT5")     lut5   = cnt + 0
        else if (cell == "LUT4")     lut4   = cnt + 0
        else if (cell == "LUT3")     lut3   = cnt + 0
        else if (cell == "LUT2")     lut2   = cnt + 0
        else if (cell == "LUT1")     lut1   = cnt + 0
        else if (cell == "RAMB18E1") ramb18 = cnt + 0
        else if (cell == "FDRE")     fdre   = cnt + 0
    }

    if (n == 6) {
        inst = f[3]; gsub(/ /, "", inst)
        mod  = f[4]; gsub(/ /, "", mod)
        cnt  = f[5]; gsub(/ /, "", cnt)
        if      (inst == "top")         total_cells = cnt + 0
        else if (mod  == "cast256_enc") enc_cells   = cnt + 0
        else if (mod  == "cast256_ks")  ks_cells    = cnt + 0
    }
}

# ── utilization.rpt: "| Slice LUTs* | used | fixed | avail | util% |" ───────
# "LUT as Logic" / "LUT as Memory" sub-rows are excluded by the second guard.
/\| Slice LUTs/ && !/LUT as/ {
    n = split($$0, f, "|")
    v = f[3]; gsub(/ /, "", v); total_luts = v
    p = f[6]; gsub(/ /, "", p); lut_pct    = p
}

END {
    if (total_luts == "N/A") total_luts = lut1+lut2+lut3+lut4+lut5+lut6
    if (enc_cells  <  0)     enc_cells  = "N/A"
    if (ks_cells   <  0)     ks_cells   = "N/A"

    green = "\033[0;32m"; red = "\033[0;31m"; bold = "\033[1m"; rst = "\033[0m"
    col   = (ts ~ /MEETS TIMING/ && ts !~ /DOES NOT/) ? green : red
    hr    = "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    printf "\n%s\n", hr
    printf "  %sSynthesis Summary — cast256 (xc7z010clg400-1, 10.0 ns target)%s\n", bold, rst
    printf "%s\n\n", hr

    printf "  %-28s  %s\n",         "Fmax",                  fmax
    printf "  %-28s  %s\n",         "WNS",                   wns
    printf "  %-28s  %s\n",         "Critical path",         crit
    printf "  %-28s  %s%s%s\n",     "Status", col, ts, rst
    printf "\n"
    printf "  %-28s  %s\n",         "LUT6",                  commas(lut6)
    if (lut_pct != "N/A")
        printf "  %-28s  %s  (%s%% of device)\n", \
                                    "Total LUTs (all types)", commas(total_luts+0), lut_pct
    else
        printf "  %-28s  %s\n",     "Total LUTs (all types)", commas(total_luts+0)
    printf "  %-28s  %s\n",         "RAMB18E1",              commas(ramb18)
    printf "  %-28s  %s\n",         "FDRE (flip-flops)",     commas(fdre)
    printf "  %-28s  %s\n",         "Total cells",           commas(total_cells)
    printf "  %-28s  %s\n",         "cast256_enc cells",     (enc_cells == "N/A" ? "N/A" : commas(enc_cells+0))
    printf "  %-28s  %s\n",         "cast256_ks cells",      (ks_cells  == "N/A" ? "N/A" : commas(ks_cells+0))
    printf "\n%s\n\n", hr
}
endef
export AWK_SYNTH_SUMMARY

.PHONY: synth
synth: $(TCL_SCRIPT)
	$(VIVADO) -mode batch -source $(TCL_SCRIPT) 2>&1 | tee vivado_synth.log
	@echo ""
	@if [ -f utilization.rpt ]; then \
		awk "$$AWK_SYNTH_SUMMARY" vivado_synth.log utilization.rpt; \
	else \
		echo "  (utilization.rpt not found — synthesis may have failed)"; \
	fi

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
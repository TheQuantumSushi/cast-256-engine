# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Makefile — crypto top-level integration testbench                       ║
# ║                                                                          ║
# ║  Analyses all components in dependency order, elaborates                ║
# ║  tb_crypto_integration, and runs the simulation.                        ║
# ║                                                                          ║
# ║  Targets                                                                 ║
# ║    all       : analyse all sources + elaborate testbench                ║
# ║    run       : run simulation (formatted coloured output)               ║
# ║    run-vcd   : run simulation + dump VCD waveform                       ║
# ║    clean     : remove GHDL artefacts                                    ║
# ║                                                                          ║
# ║  Generics                                                                ║
# ║    STEP3 = false (default): skips T7/T8 (no DMA bridge yet)            ║
# ║    STEP3 = true            : enables T7/T8 once Step 3 is complete      ║
# ║      make run STEP3=true                                                ║
# ╚══════════════════════════════════════════════════════════════════════════╝

GHDL = ghdl
STD  = --std=08 -frelaxed

STEP3 ?= false

# ── Source paths ──────────────────────────────────────────────────────────────
CAST_DIR = cast256
AXI_DIR  = axi_slave
DMA_DIR  = dma
GCM_DIR  = gcm

# cast256 chain
CAST_PKG = $(CAST_DIR)/cast256_pkg.vhd
CAST_KS  = $(CAST_DIR)/cast256_ks.vhd
CAST_ENC = $(CAST_DIR)/cast256_enc.vhd
CAST_TOP = $(CAST_DIR)/cast256.vhd

# axi_slave chain
AXI_PKG  = $(AXI_DIR)/axi_slave_pkg.vhd
AXI_WR   = $(AXI_DIR)/axi_slave_wr.vhd
AXI_RD   = $(AXI_DIR)/axi_slave_rd.vhd
AXI_TOP  = $(AXI_DIR)/axi_slave.vhd

# dma chain
DMA_FIFO  = $(DMA_DIR)/fifo.vhd
DMA_JOIN  = $(DMA_DIR)/block_join.vhd
DMA_SPLIT = $(DMA_DIR)/block_split.vhd
DMA_RD    = $(DMA_DIR)/dma_read_engine.vhd
DMA_WR    = $(DMA_DIR)/dma_write_engine.vhd
DMA_TOP   = $(DMA_DIR)/dma_engine.vhd

# gcm chain
GCM_PKG  = $(GCM_DIR)/gcm_pkg.vhd
GF128    = $(GCM_DIR)/gf128_mul.vhd
GHASH    = $(GCM_DIR)/ghash.vhd
GCM_TOP  = $(GCM_DIR)/gcm.vhd

# crypto top + testbenches
CRYPTO      = crypto.vhd
TB          = tb_crypto_integration.vhd
TB_BENCH    = tb_crypto_bench.vhd

TB_ENTITY       = tb_crypto_integration
TB_BENCH_ENTITY = tb_crypto_bench

# ── Stamp files ───────────────────────────────────────────────────────────────
S_CAST_PKG = .s_cast_pkg
S_CAST_KS  = .s_cast_ks
S_CAST_ENC = .s_cast_enc
S_CAST_TOP = .s_cast_top
S_AXI_PKG  = .s_axi_pkg
S_AXI_WR   = .s_axi_wr
S_AXI_RD   = .s_axi_rd
S_AXI_TOP  = .s_axi_top
S_DMA_FIFO = .s_dma_fifo
S_DMA_JOIN = .s_dma_join
S_DMA_SPLIT= .s_dma_split
S_DMA_RD   = .s_dma_rd
S_DMA_WR   = .s_dma_wr
S_DMA_TOP  = .s_dma_top
S_GCM_PKG  = .s_gcm_pkg
S_GF128    = .s_gf128
S_GHASH    = .s_ghash
S_GCM_TOP  = .s_gcm_top
S_CRYPTO   = .s_crypto
S_TB       = .s_tb
S_TB_BENCH = .s_tb_bench

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all
all: elaborate

# ── CAST-256 ──────────────────────────────────────────────────────────────────
$(S_CAST_PKG): $(CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_CAST_KS): $(CAST_KS) $(S_CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_CAST_ENC): $(CAST_ENC) $(S_CAST_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_CAST_TOP): $(CAST_TOP) $(S_CAST_KS) $(S_CAST_ENC)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── AXI slave ─────────────────────────────────────────────────────────────────
$(S_AXI_PKG): $(AXI_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_AXI_WR): $(AXI_WR) $(S_AXI_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_AXI_RD): $(AXI_RD) $(S_AXI_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_AXI_TOP): $(AXI_TOP) $(S_AXI_WR) $(S_AXI_RD)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── DMA engine ────────────────────────────────────────────────────────────────
$(S_DMA_FIFO): $(DMA_FIFO)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_DMA_JOIN): $(DMA_JOIN)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_DMA_SPLIT): $(DMA_SPLIT)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_DMA_RD): $(DMA_RD) $(S_DMA_FIFO) $(S_DMA_JOIN)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_DMA_WR): $(DMA_WR) $(S_DMA_FIFO) $(S_DMA_SPLIT)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_DMA_TOP): $(DMA_TOP) $(S_DMA_RD) $(S_DMA_WR)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── GCM ───────────────────────────────────────────────────────────────────────
$(S_GCM_PKG): $(GCM_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_GF128): $(GF128) $(S_GCM_PKG)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_GHASH): $(GHASH) $(S_GCM_PKG) $(S_GF128)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_GCM_TOP): $(GCM_TOP) $(S_GCM_PKG) $(S_GHASH) $(S_CAST_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── Crypto top ────────────────────────────────────────────────────────────────
$(S_CRYPTO): $(CRYPTO) $(S_AXI_TOP) $(S_DMA_TOP) $(S_GCM_TOP)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── Testbenches ───────────────────────────────────────────────────────────────
$(S_TB): $(TB) $(S_CRYPTO)
	$(GHDL) -a $(STD) $<
	@touch $@

$(S_TB_BENCH): $(TB_BENCH) $(S_CRYPTO)
	$(GHDL) -a $(STD) $<
	@touch $@

# ── Elaborate ─────────────────────────────────────────────────────────────────
.PHONY: elaborate
elaborate: $(S_TB)
	$(GHDL) -e $(STD) $(TB_ENTITY)

.PHONY: elaborate-bench
elaborate-bench: $(S_TB_BENCH)
	$(GHDL) -e $(STD) $(TB_BENCH_ENTITY)

# ─────────────────────────────────────────────────────────────────────────────
# Run targets
# ─────────────────────────────────────────────────────────────────────────────

define AWK_FILTER
/\(report note\):/ {
    sub(/.*\(report note\): /, "")
    if      (/PASS/)          { print "\033[0;32m" $$0 "\033[0m" }
    else if (/FAIL|ERROR/)    { print "\033[0;31m" $$0 "\033[0m" }
    else if (/WARN/)          { print "\033[0;33m" $$0 "\033[0m" }
    else if (/SKIP/)          { print "\033[0;33m" $$0 "\033[0m" }
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
	@echo "\033[1m  crypto Integration — $(TB_ENTITY)  [STEP3=$(STEP3)]\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_ENTITY) \
		-gSTEP3_IMPLEMENTED=$(STEP3) \
		--ieee-asserts=disable \
		--assert-level=failure \
		2>&1 | awk "$$AWK_FILTER"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

.PHONY: run-vcd
run-vcd: elaborate
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "\033[1m  crypto Integration — $(TB_ENTITY)  [VCD → tb_crypto_integration.vcd]\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_ENTITY) \
		-gSTEP3_IMPLEMENTED=$(STEP3) \
		--ieee-asserts=disable \
		--assert-level=failure \
		--vcd=tb_crypto_integration.vcd \
		2>&1 | awk "$$AWK_FILTER"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "  Waveform → \033[0;36mtb_crypto_integration.vcd\033[0m"

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: bench
bench: elaborate-bench
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@echo "\033[1m  crypto Benchmark — $(TB_BENCH_ENTITY)  [$(CLK_MHZ) MHz, mem_lat=$(MEM_LAT)]\033[0m"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
	@$(GHDL) -r $(STD) $(TB_BENCH_ENTITY) \
		-gCLK_MHZ=$(CLK_MHZ) \
		-gMEM_LAT=$(MEM_LAT) \
		--ieee-asserts=disable \
		--assert-level=failure \
		2>&1 | awk "$$AWK_FILTER"
	@echo "\033[1m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

CLK_MHZ ?= 100
MEM_LAT ?= 4

.PHONY: bench-vcd
bench-vcd: elaborate-bench
	@$(GHDL) -r $(STD) $(TB_BENCH_ENTITY) \
		-gCLK_MHZ=$(CLK_MHZ) \
		-gMEM_LAT=$(MEM_LAT) \
		--ieee-asserts=disable \
		--assert-level=failure \
		--vcd=tb_crypto_bench.vcd \
		2>&1 | awk "$$AWK_FILTER"
	@echo "  Waveform → \033[0;36mtb_crypto_bench.vcd\033[0m"

.PHONY: clean
clean:
	rm -f $(S_CAST_PKG) $(S_CAST_KS) $(S_CAST_ENC) $(S_CAST_TOP)
	rm -f $(S_AXI_PKG) $(S_AXI_WR) $(S_AXI_RD) $(S_AXI_TOP)
	rm -f $(S_DMA_FIFO) $(S_DMA_JOIN) $(S_DMA_SPLIT) $(S_DMA_RD) $(S_DMA_WR) $(S_DMA_TOP)
	rm -f $(S_GCM_PKG) $(S_GF128) $(S_GHASH) $(S_GCM_TOP)
	rm -f $(S_CRYPTO) $(S_TB) $(S_TB_BENCH)
	rm -f work-obj08.cf $(TB_ENTITY) $(TB_BENCH_ENTITY)
	rm -f tb_crypto_integration.vcd tb_crypto_bench.vcd

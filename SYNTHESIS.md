# CAST-256 Engine — Synthesis Report

**Tool:** Vivado v2025.2  
**Device:** xc7z010clg400-1 (Zybo Z7-10, speed grade -1)  
**Top-level entity:** `crypto`  
**Mode:** out-of-context synthesis  
**Clock target:** 100 MHz (10.000 ns)  
**Date:** 2026-05-28  

Reproduce with:
```bash
cd vhdl/crypto
vivado -mode batch -source synth_crypto.tcl
# reports written to vhdl/crypto/synth/
```

---

## 1. Timing

| Metric | Value |
|--------|-------|
| Clock constraint | 10.000 ns (100 MHz) |
| Worst Negative Slack (WNS) | **−3.745 ns** |
| Critical path delay | **13.745 ns** |
| **Estimated Fmax** | **72.8 MHz** |
| Failing setup endpoints | 266 / 20952 |
| Pulse-width violations | 0 |

**The design does not meet timing at 100 MHz.** The maximum achievable frequency from synthesis is approximately **72.8 MHz**, at which point the worst slack would be 0. After place-and-route with physical optimisation (`opt_design`) a further 0.5–1.5 ns is typically recovered, so the real achievable frequency on silicon is likely in the **73–78 MHz** range.

### 1.1 Critical path

The single bottleneck path is entirely confined to the CAST-256 encryption datapath:

```
Source      : u_gcm/u_cast/gen_enc[1].u_enc/s1_out_reg[1]/C
Destination : u_gcm/u_cast/gen_enc[1].u_enc/s3_out_reg[0]/D

Total delay : 13.723 ns  (logic 5.852 ns / 42 %,  routing 7.871 ns / 58 %)
Logic levels: 24  (CARRY4×10  LUT6×6  LUT5×2  LUT3×3  LUT2×2  LUT4×1)
```

The path traverses **10 cascaded CARRY4 primitives**, which corresponds to a 40-bit carry chain inside one of the CAST-256 round-function additions. CAST-256 performs six 32-bit modular additions per round across 48 rounds; Vivado maps each addition to a carry chain and, for this particular round combination, was unable to break the chain across a register boundary. The result is a 3.4 ns logic-only contribution from carry propagation before any routing delay is added.

All other paths in the design meet timing comfortably (next worst: DMA FIFO read-pointer → `m0_axi_rready`, 3.3 ns total delay).

### 1.2 Fixing the timing violation

The fix is to add a pipeline register inside `cast256_enc.vhd` to break the 40-bit adder into two 20-bit stages:

- **Cost:** +1 clock cycle of latency per encryption pass (from ~53 cy to ~54 cy per block at the cipher level; negligible at system level).
- **Benefit:** Critical path halved to ~6.9 ns → timing met at 100 MHz with approximately +3 ns margin.
- **Alternative:** Reduce the operating clock to **72 MHz**, which is sufficient for the target throughput (see Section 4).

---

## 2. Resource utilisation

Target device total resources: 17 600 LUTs, 35 200 FFs, 80 DSPs, 60 BRAMs (×36).

| Resource | Used | Available | Utilisation |
|----------|------|-----------|-------------|
| Slice LUTs | **11 587** | 17 600 | **65.8 %** |
| — as Logic | 11 411 | 17 600 | 64.8 % |
| — as Distributed RAM | 176 | 6 000 | 2.9 % |
| Slice Registers (FFs) | **7 742** | 35 200 | **22.0 %** |
| Block RAMs (×18) | **4** | 120 | **3.3 %** |
| DSPs | 0 | 80 | 0.0 % |
| F7 Muxes | 251 | 8 800 | 2.9 % |

The design fits on the Z7-10 with approximately **34 % LUT headroom** and **78 % FF headroom**. No BRAMs beyond the four used for FIFOs within the DMA engine are consumed. DSPs are unused — the cipher uses only LUT-based arithmetic.

### 2.1 Utilisation by block (hierarchical)

| Block | LUTs | % of total | FFs | % of total |
|-------|------|-----------|-----|-----------|
| **CAST-256 total** | **9 573** | **82.6 %** | 2 583 | 33.4 % |
| — Key schedule (`u_ks`) | 3 742 | 32.3 % | 2 050 | 26.5 % |
| — Encryption channel 0 (`gen_enc[0]`) | 3 214 | 27.7 % | 266 | 3.4 % |
| — Encryption channel 1 (`gen_enc[1]`) | 2 593 | 22.4 % | 267 | 3.5 % |
| **GCM FSM + GHASH** | **1 210** | **10.4 %** | 3 063 | 39.6 % |
| — GF(2¹²⁸) multiplier | 646 | 5.6 % | 395 | 5.1 % |
| — GHASH engine | 134 | 1.2 % | 387 | 5.0 % |
| — GCM state machine | 430 | 3.7 % | 2 281 | 29.5 % |
| **DMA engine** | **412** | **3.6 %** | 668 | 8.6 % |
| — Read engine + block_join | 198 | 1.7 % | 347 | 4.5 % |
| — Write engine + block_split | 214 | 1.8 % | 321 | 4.1 % |
| **AXI slave** | **390** | **3.4 %** | 740 | 9.6 % |
| Top-level / DMA adapter | 2 | 0.0 % | 688 | 8.9 % |

**CAST-256 is the dominant consumer** at 82.6 % of LUTs. This is expected for a symmetric cipher implemented in LUT-based logic without DSP blocks. Two parallel encryption channels are instantiated (`gen_enc[0]` and `gen_enc[1]`), each requiring ~2 900–3 200 LUTs for the combinatorial round logic. The key schedule is the single largest sub-block at 3 742 LUTs.

Everything outside CAST-256 — the GCM orchestrator, GHASH, DMA, and AXI slave — collectively uses fewer than 2 100 LUTs (18 % of the design).

---

## 3. Synthesis warnings

19 warnings, 0 critical warnings, 0 errors.

| Warning | Count | Explanation |
|---------|-------|-------------|
| `btn[3:0]` and `sw[3:1]` unconnected | 14 | Buttons and switches 1–3 are not used by the current design. `sw[0]` is used to gate the IRQ. Expected. |
| `rd_base_addr[31:30]` / `wr_base_addr[31:30]` unconnected | 4 | The DMA engine ports are 32-bit but only the lower 30 bits are used (1 GB address space). The top two bits are tied to `"00"` in `crypto.vhd`. Expected. |
| `dma_rd_valid_reg` removed (unused FF) | 1 | A register in `crypto.vhd` (`dma_rd_valid`) is driven but its combinatorial output already propagates directly; Vivado removed the redundant FF. Benign. |

No functional warnings — all relate to intentional design decisions.

---

## 4. Performance at achievable frequency

Running at **72 MHz** (the synthesis-estimated Fmax) rather than 100 MHz:

| Metric | 100 MHz (target) | 72 MHz (achievable) |
|--------|-----------------|---------------------|
| Timing status | ❌ Violated | ✅ Met |
| GHASH-final overhead | 57 cy = 570 ns | 57 cy = 792 ns |
| KS cold overhead | 515 cy = 5.15 µs | 515 cy = 7.15 µs |
| Marginal cost / 128-bit block (warm) | 52 cy = 520 ns | 52 cy = 722 ns |
| **Throughput, 8-block warm** | 204 Mbps | **147 Mbps** |
| **Throughput, asymptote (warm)** | ~246 Mbps | **~177 Mbps** |

At 72 MHz the accelerator still comfortably outperforms software AES on the Cortex-A9 (typically 40–80 Mbps for AES-128-GCM in software on the same processor).

---

## 5. Recommendations

### 5.1 Fix the timing violation (high priority for 100 MHz operation)

Add a pipeline stage inside `cast256_enc.vhd` to break the 10× CARRY4 chain. Target: cut the carry depth to ≤ 5 CARRY4 per stage. Expected result: Fmax ≥ 100 MHz with +3 ns margin.

### 5.2 Consider targeting 72 MHz for submission

If pipeline modification is out of scope, operating at 72 MHz is a valid engineering choice:
- The timing constraint would be met with zero violations.
- Throughput (147 Mbps at 8 blocks) is sufficient for the project specification.
- The report should clearly state the chosen frequency and justify it.

### 5.3 Run full implementation (place and route)

This report is synthesis-only (`out_of_context` mode). Full implementation through `place_design` and `route_design` is required to:
- Obtain the real post-route Fmax (typically 0–2 ns better than synthesis after `opt_design`).
- Confirm the bitstream is generated without errors.
- Validate the design operates correctly on the board at the chosen frequency.

### 5.4 LUT headroom is adequate but not generous

At 65.8 % LUT utilisation there is approximately 6 000 LUTs of margin. This is enough for debug infrastructure (ILA, VIO) but leaves limited room for adding a second GCM instance or a deeper DMA pipeline if performance improvements are later attempted.

---

## 6. Summary

| Item | Result |
|------|--------|
| Target frequency | 100 MHz |
| Achieved Fmax (synthesis) | **72.8 MHz** |
| Timing status | **VIOLATED** at 100 MHz |
| Root cause | 40-bit carry chain in `cast256_enc` round function |
| LUT utilisation | **65.8 %** (fits, limited headroom) |
| FF utilisation | **22.0 %** (comfortable) |
| BRAM utilisation | **3.3 %** (4× RAMB18, DMA FIFOs) |
| DSP utilisation | **0 %** |
| Synthesis warnings | 19 (all benign) |
| Dominant block | CAST-256 (82.6 % of LUTs) |
| Recommended action | Reduce clock to 72 MHz **or** pipeline `cast256_enc` round adder |

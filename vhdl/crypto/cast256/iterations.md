# CAST-256 synthesis : iterative improvement log


## Iterations

- **Iteration 1 : Baseline (LUT S-boxes).** The design worked correctly in simulation but was completely unusable for synthesis. All 4 S-boxes were inferred as combinatorial LUT ROMs, and both the key schedule and encryption core computed every round in a single clock cycle by chaining all f-functions back to back. The chip was essentially full and the timing was catastrophic. Technically: S-boxes implemented as `constant sbox_t` in the package, causing Vivado to inline 4 × 256 × 32-bit truth tables as distributed LUT logic; 16 sequential f-function calls per cycle in `cast256_ks` (2 w-octaves) and 4 per cycle in `cast256_enc` created a 131 ns combinatorial critical path, yielding Fmax = 7.6 MHz and ~91% LUT utilisation on the device.

- **Iteration 2 : BRAM signals + 2-phase FSM (current).** The S-boxes were moved from package constants to architecture-level signals initialised from those constants, with `ram_style = "block"` applied to the signals. The FSMs were restructured so that each f-function takes exactly 2 clock cycles: an ADDR state where the BRAM address is presented combinatorially, and a COMPUTE state where the registered BRAM output is used for the arithmetic. LUT usage dropped by ~79%, BRAM usage went from 0 to 8 RAMB18, and Fmax jumped from 7.6 MHz to 89.4 MHz. Technically: declaring `signal SBOX1_r : sbox_t := SBOX1` gives Vivado a first-class hardware object to map to RAMB18 primitives; the `bram_read` process performs a registered read (`s1_out <= SBOX1_r(addr_a)` on rising edge), giving 1-cycle read latency; `cast256_ks` and `cast256_enc` were restructured with IDLE / ADDR / COMPUTE / ST_DONE states and separate `addr_comb` combinatorial processes driving the BRAM addresses; the key schedule adds a SUBKEY_EXTRACT state after each odd octave; latency increased to 96 cycles per block (enc) and ~396 cycles (ks) as the price for the LUT reduction.

- **Iteration 3 : LUTRAM S-boxes + pipelined address forwarding + 2 parallel enc engines.** Three optimisations applied simultaneously to `cast256_enc` and `cast256`. First, `ram_style` changed from `"block"` to `"distributed"` on all 4 S-box signals, moving them from RAMB18 to LUTRAM: read latency is identical (1 cycle, registered read) but the enc core no longer consumes any BRAM, dropping the total from 8 to 4 RAMB18 (KS only). Second, the ADDR state was eliminated from the inner loop of `cast256_enc`: a new combinatorial signal `f_result_comb` replicates the f-function arithmetic from `s1_out`/`s2_out`/`s3_out`/`s4_out`, and `addr_comb` was extended to activate in COMPUTE state as well, driving SRAM addresses for step N+1 while step N is being processed. The forwarding uses `beta_reg.x XOR f_result_comb` for Q-round transitions (where each step reads the word just updated by the previous step) and registered `beta_reg` values for QBAR rounds (where all data dependencies are 2+ cycles old and already settled). This collapses the per-step cost from ADDR+COMPUTE (2 cycles) to COMPUTE only (1 cycle after the initial ADDR), halving enc latency from ~97 to ~50 cycles. Third, `cast256.vhd` was redesigned to instantiate 2 independent enc engines sharing the single KS subkey buses, exposing 2 parallel encryption channels (`plaintext_0/1`, `encrypt_start_0/1`, `ciphertext_0/1`, `enc_done_0/1`). The 2 LUTRAM-based engines together consume ~6,100 LUT cells; the KS grows from 4,961 to 6,487 cells due to Vivado duplicating subkey fanout trees for 2 consumers instead of 1. Fmax dropped from 89.4 MHz to 72.4 MHz because the forwarding chain places a full adder tree (f_result_comb, ~3.5 ns) in series before the existing I-computation (adder/XOR + barrel rotate, ~5.5 ns), producing a 13.8 ns critical path that exceeds the 10 ns reference clock. The design fits the device at 50.25% LUT utilisation and is functional; the Fmax ceiling is a direct consequence of the forwarding chain and can be traded back for latency by reverting to the 2-phase ADDR/COMPUTE loop if needed.

---

## Results table

| Metric | Iteration 1 : LUT S-boxes | Iteration 2 : BRAM signals + 2-phase FSM | Iteration 3 : LUTRAM + pipelined addr + 2 engines |
|---|---|---|---|
| **Fmax** | 7.6 MHz | 89.4 MHz | 72.4 MHz |
| **WNS** | −121.439 ns | −1.182 ns | −3.810 ns |
| **Critical path** | 131.4 ns | 11.2 ns | 13.8 ns |
| **LUT6** | 15,947 | 1,775 | 5,831 |
| **Total LUTs (all types)** | ~16,000 | 3,347 | 8,844 |
| **RAMB18E1** | 0 | 8 | 4 |
| **FDRE (flip-flops)** | ~2,800 | 2,192 | 2,597 |
| **Total cells** | ~29,000 | 5,643 | 12,574 |
| **cast256_enc cells** | 5,766 | 682 | 3,044 (×2 engines) |
| **cast256_ks cells** | 23,319 | 4,961 | 6,487 |
| **LUT % of xc7z010** | ~91% | ~19% | ~50% |

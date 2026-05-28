# CAST-256 synthesis : iterative improvement log


## Iterations

- **Iteration 1 : Baseline (LUT S-boxes).** The design worked correctly in simulation but was completely unusable for synthesis. All 4 S-boxes were inferred as combinatorial LUT ROMs, and both the key schedule and encryption core computed every round in a single clock cycle by chaining all f-functions back to back. The chip was essentially full and the timing was catastrophic. Technically: S-boxes implemented as `constant sbox_t` in the package, causing Vivado to inline 4 × 256 × 32-bit truth tables as distributed LUT logic; 16 sequential f-function calls per cycle in `cast256_ks` (2 w-octaves) and 4 per cycle in `cast256_enc` created a 131 ns combinatorial critical path, yielding Fmax = 7.6 MHz and ~91% LUT utilisation on the device.

- **Iteration 2 : BRAM signals + 2-phase FSM (current).** The S-boxes were moved from package constants to architecture-level signals initialised from those constants, with `ram_style = "block"` applied to the signals. The FSMs were restructured so that each f-function takes exactly 2 clock cycles: an ADDR state where the BRAM address is presented combinatorially, and a COMPUTE state where the registered BRAM output is used for the arithmetic. LUT usage dropped by ~79%, BRAM usage went from 0 to 8 RAMB18, and Fmax jumped from 7.6 MHz to 89.4 MHz. Technically: declaring `signal SBOX1_r : sbox_t := SBOX1` gives Vivado a first-class hardware object to map to RAMB18 primitives; the `bram_read` process performs a registered read (`s1_out <= SBOX1_r(addr_a)` on rising edge), giving 1-cycle read latency; `cast256_ks` and `cast256_enc` were restructured with IDLE / ADDR / COMPUTE / ST_DONE states and separate `addr_comb` combinatorial processes driving the BRAM addresses; the key schedule adds a SUBKEY_EXTRACT state after each odd octave; latency increased to 96 cycles per block (enc) and ~396 cycles (ks) as the price for the LUT reduction.

---

## Results table

| Metric | Iteration 1 : LUT S-boxes | Iteration 2 : BRAM signals + 2-phase FSM |
|---|---|---|
| **Fmax** | 7.6 MHz | 89.4 MHz |
| **WNS** | −121.439 ns | −1.182 ns |
| **Critical path** | 131.4 ns | 11.2 ns |
| **LUT6** | 15,947 | 1,775 |
| **Total LUTs (all types)** | ~16,000 | 3,347 |
| **RAMB18E1** | 0 | 8 |
| **FDRE (flip-flops)** | ~2,800 | 2,192 |
| **Total cells** | ~29,000 | 5,643 |
| **cast256_enc cells** | 5,766 | 682 |
| **cast256_ks cells** | 23,319 | 4,961 |
| **LUT % of xc7z010** | ~91% | ~19% |

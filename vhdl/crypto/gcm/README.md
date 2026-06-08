# gcm

VHDL implementation of GCM authenticated encryption/decryption (NIST SP
800-38D, Algorithms 4 and 5) using CAST-256 as the underlying block cipher.

Constraints matching the hardware:
- IV : exactly 96 bits
- AAD and PT : multiples of 128 bits, up to 1 GB
- Tag : 128 bits

## Source files

| File | Role |
|---|---|
| `gcm_pkg.vhd` | Shared constants (`GF_R` reduction polynomial) and `inc32` utility function |
| `gf128_mul.vhd` | GF(2^128) multiplier. 32-bit unrolled: 4 cycles per multiplication |
| `ghash.vhd` | Sequential GHASH (SP 800-38D Algorithm 2). Feeds blocks into `gf128_mul`, 6 cycles/block |
| `gcm.vhd` | Top-level GCM FSM. Orchestrates key schedule, H precomputation, AAD hashing, GCTR encrypt/decrypt, length block, and tag. Also handles DMA read/write requests |
| `tb_gcm.vhd` | Functional testbench: encrypt/decrypt round-trips, tamper detection, zero-AAD, zero-PT, sequential operations |

## Pipeline overview

GHASH (6 cycles/block) runs concurrently with CAST-256 (96 cycles/block), so
GHASH always finishes before the next ciphertext block is ready. The GCM FSM
issues DMA reads for block N+1 in parallel with CAST-256 encrypting block N.
Net throughput: ~1 block / 96 cycles.

## Build

| Target | Description |
|---|---|
| `make` | Analyse all sources (including cast256) and elaborate the testbench |
| `make run` | Simulate with formatted PASS/FAIL output |
| `make run-vcd` | Simulate and dump waveform to `tb_gcm.vcd` |
| `make run-time` | Simulate and print a per-phase cycle timing table |
| `make clean` | Remove GHDL work library and stamp files |

Individual file targets: `make pkg` · `make gf128` · `make ghash` · `make gcm` · `make tb`

### Dependency order

```
gcm_pkg → gf128_mul → ghash ↘
                              gcm → tb → elaborate → run
cast256 (from ../cast256/) ↗
```

The cast256 sources are re-analysed into this directory's work library so
the GCM simulation is self-contained.

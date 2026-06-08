# Testbenches

All three testbenches target `crypto.vhd` (the top-level entity) and are run from `vhdl/crypto/` via the root Makefile there.

## `tb_crypto_integration.vhd`

Functional correctness testbench. Drives the AXI4-Lite slave with a behavioural master and answers the DMA master bus with a memory model.

Runs ~12 named tests :
- T0-T6 : reset, config write, AXI bounds check, encrypt, decrypt (valid tag),
  decrypt (tampered tag), soft reset
- T7-T11 : multi-block encrypt/decrypt round-trips, back-to-back operations,
  AAD-only and PT-only paths
- T_SWB, T_SRESET_MID, T_DMA_RD_ERR, T_DMA_WR_ERR : edge cases (START while
  BUSY, soft reset mid-operation, AXI SLVERR injection)

Each test reports PASS/FAIL via `report` statements.

```bash
make run          # from vhdl/crypto/
make run-vcd      # same + generate waveform
```

## `tb_crypto_bench.vhd`

Cycle-accurate performance benchmark, not a correctness test. Uses a free-running cycle counter and a DMA-monitor process to timestamp every phase of each operation. Sweeps PT length, AAD length, cold vs warm key, encrypt vs decrypt across nine sections (S1-S9). Prints a formatted table with total cycles, per-phase breakdown (key schedule, DMA read window, DMA write window,
GHASH final), and Mbps throughput. Source of the numbers in `PERFORMANCE.md`.

```bash
make bench                         # from vhdl/crypto/
make bench CLK_MHZ=200 MEM_LAT=2   # different clock / memory model
make bench-vcd                     # same + generate waveform
```

## `tb_cast256.vhd`

Minimal smoke test for the `cast256` entity in isolation. Drives a single hardcoded key + plaintext pair through the encrypt handshake and prints the resulting ciphertext hex to the console. No pass/fail logic ; verify by eye against the expected value in the header comment. Useful when iterating on the cipher core alone without pulling in the rest of the fabric.

To test a different vector, edit `KEY_HEX` and `PT_HEX` at the top of the file and re-run. Note : `vhdl/crypto/cast256/` has its own `tb_cast256.vhd` which runs the full RFC 2612 KAT suite via `make run` in that directory.

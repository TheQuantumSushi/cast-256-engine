# test_suite

Verifies the correctness of the CAST-256 VHDL implementation against a reference C implementation.

## Files

| File | Role |
|---|---|
| `cast.c` | Brian Gladman's original CAST-256 reference implementation (RFC 2612). Used as ground truth for KAT generation. Requires `std_defs.h` |
| `std_defs.h` | Type definitions for `cast.c`. The copy used during KAT generation replaces `unsigned long` with `uint32_t` to be correct on 64-bit hosts |
| `cast256_standalone.c` | Self-contained CAST-256 implementation without `std_defs.h` dependency. Used by `driver/tests/` (avoids the file-scope switch statements in `cast.c` that are invalid C11) |
| `gcm_ref.c` / `gcm_ref.h` | GCM mode wrapped around the reference CAST-256. Used by `driver/tests/test_e2e` to generate and verify full encrypt/decrypt vectors |
| `gcm_kat_gen.c` | Standalone KAT generator for GCM vectors (key + IV + AAD + PT → CT + tag) |
| `kat_inputs.txt` | Input records for `generate_kat.sh`. Each record specifies a NAME, KEY, and PLAINTEXT to run through the C reference |
| `generate_kat.sh` | Compiles `cast.c` in a temporary `_build/` directory, then processes `kat_inputs.txt` to emit `.kat` files |
| `run_kat.sh` | Analyses and elaborates the VHDL cast256 sources (from `../`), then runs each `.kat` file through `tb_cast256` and reports PASS/FAIL |

## KAT workflow

Known-Answer Test vectors are pre-generated from the C reference and stored as `.kat` files. The VHDL simulation is then run against those files; any output mismatch is a failure.

1. Generate KAT files from the C reference (only needed once, or after changing `kat_inputs.txt`)
```bash
# From the cast256/ directory:
test_suite/generate_kat.sh -d test_suite/kat_files_256_bits
```

2. Run all KAT vectors against the VHDL simulation
```bash
# From the cast256/ directory:
test_suite/run_kat.sh -k test_suite/kat_files_256_bits
```

## KAT directories

- `kat_files_256_bits/` : vectors exercising the 256-bit CAST-256 core (boundary patterns, all-zeros, all-ones, incremental, random, RFC 2612 test vectors at 128 / 192 / 256-bit key lengths)
- `kat_files_rfc2612/` : vectors taken directly from RFC 2612 Appendix B

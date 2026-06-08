# Driver tests

Host-side test suites for the CAST-256-GCM driver. No Zybo, no `/dev/mem`, no cross-compiler required : both run on any x86 Linux host with `gcc`.

```
make        # build and run both suites
make unit   # unit tests only
make e2e    # end-to-end tests only
```

## `test_logic` : driver unit tests

Replaces the AXI register bank with a plain `uint32_t` array. A global
`mock_hw_response` controls what the polling loop reads back from the CSR.

Checks :
- error paths : `NOT_INIT`, `BUSY`, `INVALID_KEY`, `INVALID_PARAM`, `TIMEOUT`, `AXI_ERROR`
- register encoding : big-endian key / IV / tag packing, correct byte-to-word layout
- CSR write values : correct `MODE` bit for encrypt vs. decrypt, `SOFT_RESET` on reset

## `test_e2e` : end-to-end tests against a software hardware model

`hw_model` is a more complete simulation: it intercepts the `CSR_START` write via `crypto_set_hw_hook()`, runs the actual CAST-256-GCM computation using the C reference (`gcm_ref.c` / `cast256_standalone.c`), and writes the resulting ciphertext and tag back into the register array - exactly as the hardware would.

Results are compared against an independent `gcm_ref` call to catch any driver/model divergence. Covers encrypt, decrypt, tamper detection, zero-AAD, zero-PT, and sequential operations with different IVs.

# driver

Thin polling userspace driver for the CAST-256-GCM AXI peripheral on the Zybo board. Accesses the hardware via `/dev/mem` + `mmap` - no kernel module, no interrupts. Requires root (`CAP_SYS_RAWIO`).

## Source files

### Public API

| File | Role |
|---|---|
| `crypto_driver.h` | Public header. Include this in application code. Declares the full API and pulls in `crypto_errors.h` and `crypto_regs.h` |
| `crypto_regs.h` | Register offsets (`REG_KEY_BASE`, `REG_CSR`, ...) and CSR bit masks (`CSR_START`, `CSR_DONE`, ...). Physical base address and map size |
| `crypto_errors.h` | Error code constants returned (negated) by all driver functions |

### Implementation

| File | Role |
|---|---|
| `crypto_driver.c` | Core driver : `crypto_init`, key/IV loading, `crypto_encrypt`, `crypto_decrypt`, polling loop, tag read/write, mock init for host tests |
| `crypto_mem.c` | ARM/Linux-specific utilities : `virt_to_phys` (via `/proc/self/pagemap`), `crypto_flush_cache` and `crypto_invalidate_cache` (ARM cacheflush syscall). Not linked in host test builds |
| `crypto_hw_priv.h` | Private header shared between `crypto_driver.c` and `crypto_test.c`. Exposes `g_regs` and the `reg_read` / `reg_write` inline helpers. Never include in application code |

### Binaries

| File | Role |
|---|---|
| `crypto_test.c` | On-board hardware test suite. Requires the Zybo with a programmed bitstream. Tests the full encrypt/decrypt pipeline against known vectors, error paths, and edge cases |
| `crypto_demo.c` | End-to-end demonstration : encrypts a 32-byte message with 16-byte AAD, prints ciphertext and tag, decrypts and verifies, then confirms tamper detection |

### Tests (host-side, no hardware needed)

See `tests/README.md` for details.

| File | Role |
|---|---|
| `tests/test_logic.c` | Unit tests for driver logic using a mock register array |
| `tests/test_e2e.c` | End-to-end tests against the software hardware model |
| `tests/hw_model.{h,c}` | Software model of the full hardware stack, used by `test_e2e` |

## Build

Requires `arm-linux-gnueabihf-gcc` for ARM targets and `gcc` for host tests.

| Target | Output | Description |
|---|---|---|
| `make lib` | `libcrypto_driver.a` | Static library for linking into an application |
| `make tests_arm` | `crypto_tests_arm` | On-board hardware test binary (ARM) |
| `make demo_arm` | `crypto_demo` | End-to-end demo binary (ARM) |
| `make test` | — | Build and run host-side logic tests (x86, no hardware) |
| `make clean` | — | Remove all build artefacts |

## Typical workflows

### Run host-side tests (no Zybo needed)

```bash
make test
# or, for the full test suite including end-to-end:
cd tests && make
```

### Deploy and run on the Zybo

1. Cross-compile
```bash
make tests_arm
```

2. Copy to board
```bash
scp crypto_tests_arm root@<zybo-ip>:/root/
```

Or by placing it on the SD card directly

3. Run on the board (requires root)
```bash
./crypto_tests_arm
```

### Use the library in an application

```bash
make lib
arm-linux-gnueabihf-gcc -Wall -O2 -I driver/ my_app.c -L driver/ -lcrypto_driver -o my_app
```

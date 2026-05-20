# ANNEX — Linux Driver Reference (M6)

Thin polling user-space driver over `/dev/mem` for the CAST-256-GCM AXI peripheral on
the Zybo Rev. B board. No kernel module, no interrupts. Requires root (`CAP_SYS_RAWIO`).

---

## Hardware at a Glance

```
[Userspace] ──/dev/mem──► [AXI-Lite @ 0x43C00000] ──► [Crypto Core] ◄──► [DDR via HP0]
```

- **M_AXI_GP0** (0x43C00000): control registers — the driver reads and writes these.
- **S_AXI_HP0**: DMA port — the hardware reads plaintext/AAD and writes ciphertext directly
  to DDR, bypassing the CPU entirely. Physical DDR addresses are required.
- The hardware exposes a register bank; driver writes config, asserts START, polls CSR.

---

## Register Map

| Offset       | Name            | Access | Notes                                               |
|--------------|-----------------|--------|-----------------------------------------------------|
| 0x000–0x01C  | KEY (8 words)   | W      | Big-endian; **writing word 7 triggers H computation** |
| 0x020–0x028  | IV (3 words)    | W      | 96-bit IV, big-endian                               |
| 0x02C        | —               | —      | DECERR (reserved)                                   |
| 0x030        | AAD_ADDR        | W      | Physical DDR address of AAD buffer                  |
| 0x034        | AAD_LEN         | W      | AAD length in bytes (multiple of 16)                |
| 0x038        | PT_ADDR         | W      | Plaintext addr (enc) / ciphertext addr (dec)        |
| 0x03C        | PT_LEN          | W      | Corresponding length in bytes                       |
| 0x040        | CT_ADDR         | W      | Ciphertext output addr (enc) / plaintext addr (dec) |
| 0x044        | CT_LEN          | R      | Written by hardware after encryption                |
| 0x048–0x054  | TAG (4 words)   | R/W    | HW overwrites after enc; SW must write before dec   |
| 0x058        | CSR             | R/W    | START[0] RST[1] MODE[2] BUSY[8] DONE[9] TAGV[10] ERR[11] |
| 0x05C        | DEBUG           | R      | FSM state in bits [3:0]                             |
| 0x060+       | —               | —      | DECERR (unmapped)                                   |

---

## API Summary

| Function | What it does |
|----------|--------------|
| `crypto_init(base_addr)` | Open `/dev/mem` with `O_RDWR\|O_SYNC`, `mmap` 4 KB at `base_addr` |
| `crypto_set_key(key, len)` | Zero-pad to 32 B, write 8 words big-endian; poll BUSY until H-key computed (1 s timeout) |
| `crypto_set_iv(iv)` | Write 12 bytes as 3 words big-endian to 0x020–0x028; no trigger |
| `crypto_encrypt(aad_phys, aad_len, pt_phys, pt_len, ct_phys)` | Write DMA regs, `CSR=START` (MODE=0), poll DONE (30 s timeout) |
| `crypto_decrypt(aad_phys, aad_len, ct_phys, ct_len, pt_phys, tag)` | Write expected tag, write DMA regs, `CSR=MODE\|START`, poll DONE, check TAGV |
| `crypto_get_tag(buf)` | Read 4 words from 0x048–0x054 into 16-byte buffer |
| `crypto_get_status(out)` | Return raw CSR word |
| `crypto_reset()` | Write `CSR_SOFT_RESET` to CSR, sleep 10 µs |
| `crypto_cleanup()` | `munmap` + `close(mem_fd)` |
| `crypto_flush_cache(buf, len)` | `__builtin___clear_cache` — push CPU writes to DDR before DMA read |
| `crypto_invalidate_cache(buf, len)` | Same built-in — discard stale cache lines after DMA write |
| `virt_to_phys(vaddr)` | Read `/proc/self/pagemap` → PFN → physical address; returns 0 on failure |

---

## Call Sequences

**Encrypt**
1. `crypto_init(CRYPTO_BASE_PHYS)`
2. `crypto_set_key(key, len)` — loads key, waits for H-key computation
3. `crypto_set_iv(iv)` — loads 96-bit IV
4. Allocate AAD / PT / CT buffers (page-aligned, `mlock`'d)
5. `crypto_flush_cache(aad, aad_len)` + `crypto_flush_cache(pt, pt_len)`
6. `crypto_encrypt(aad_phys, aad_len, pt_phys, pt_len, ct_phys)`
7. `crypto_invalidate_cache(ct, ct_len)` — then read ciphertext
8. `crypto_get_tag(tag_out)`

**Decrypt**
1–4. Same setup as encrypt; swap PT ↔ CT buffer roles
5. `crypto_flush_cache(ct, ct_len)`
6. `crypto_decrypt(aad_phys, aad_len, ct_phys, ct_len, pt_phys, expected_tag)`
7. `crypto_invalidate_cache(pt, pt_len)` — then read plaintext
8. Return value: 0 = OK, `-CRYPTO_ERR_TAG_MISMATCH` = authentication failed

---

## Cache Coherency

DMA accesses DDR directly; the CPU L1/L2 caches are not automatically coherent with it.

- **Before DMA read** (steps 5 above): `crypto_flush_cache` — ensures CPU writes reach DDR.
- **After DMA write** (step 7 above): `crypto_invalidate_cache` — discards stale cache lines
  so the CPU reads fresh data from DDR.

Skipping either step causes silent data corruption.

---

## Error Codes

| Code | Value | Condition |
|------|-------|-----------|
| `CRYPTO_ERR_MEM_OPEN`    | 1 | `open("/dev/mem")` failed |
| `CRYPTO_ERR_MMAP`        | 2 | `mmap` failed |
| `CRYPTO_ERR_BUSY`        | 3 | Hardware BUSY at function entry |
| `CRYPTO_ERR_INVALID_KEY` | 4 | Key length ≠ 16 / 24 / 32 bytes |
| `CRYPTO_ERR_TIMEOUT`     | 5 | 30 s polling deadline exceeded |
| `CRYPTO_ERR_AXI`         | 6 | DMA bus error (BRESP/RRESP ≠ 00) |
| `CRYPTO_ERR_TAG_MISMATCH`| 7 | Decrypt tag validation failed |
| `CRYPTO_ERR_NOT_INIT`    | 8 | `crypto_init` not called |

All functions return these as negative integers (e.g. `-CRYPTO_ERR_BUSY`).

---

## Pitfalls

- **Key word order matters**: words must be written 0x000 → 0x01C in order; the write to
  0x01C triggers H-key computation — out-of-order writes silently break GCM authentication.
- **Silent BUSY discard**: writes to KEY / IV / address registers while `BUSY=1` are silently
  ignored by hardware — not an error, not a SLVERR. Always check BUSY before writing config.
- **TAG register polarity**: for decrypt, write the expected tag to 0x048–0x054 **before**
  asserting START; for encrypt, read the computed tag from the same registers **after** DONE.
- **Physical addresses**: `virt_to_phys` reads `/proc/self/pagemap`; the page must already be
  resident in DDR — call `mlock(buf, len)` or allocate with `MAP_POPULATE | MAP_LOCKED`.

---

## Design Rationale

This section justifies the hardware-interface and driver-architecture choices that are not obvious from the register map alone.

### Driver architecture: userspace `/dev/mem` over kernel module

A UIO or character-device kernel module would be the production-grade choice, but it requires a matching kernel build environment, module signing, and `insmod` rights. For a single-application research platform:

- `/dev/mem` + `mmap` requires only `root` and is self-contained — no `.ko` file, no toolchain dependency beyond `gcc`.
- The driver talks to exactly one process at a time; no concurrency arbitration is needed.
- If multiple processes need access in the future, promoting to a kernel driver is straightforward because the register interface does not change.

### Driver architecture: polling over interrupts

Raising an interrupt from the FPGA to the Zynq PS requires configuring the GIC (Generic Interrupt Controller) and either a kernel driver or UIO to proxy the signal to userspace. The round-trip latency (FPGA → GIC → kernel → signal → userspace) is comparable to or worse than tight polling for operations that complete in milliseconds. Polling on a Cortex-A9 running at 667 MHz burns one core but avoids the entire interrupt infrastructure. If power consumption becomes a concern, a short `nanosleep` is already inserted between polls to yield the CPU.

### `O_SYNC` on `/dev/mem`

Without `O_SYNC`, the CPU may satisfy reads from its internal write buffer or L1 data cache rather than issuing a real AXI transaction. For MMIO registers this causes stale reads (e.g. reading CSR after asserting START may return the pre-START value). `O_SYNC` marks the mapping as *device* memory — every load/store reaches the AXI bus. This is equivalent to ARM's `nGnRE` (non-Gathering, non-Reordering, Early Write Acknowledgement) device memory attribute.

### `MAP_SHARED` mapping

`MAP_PRIVATE` creates a copy-on-write anonymous mapping; writes never leave the CPU. `MAP_SHARED` is required so that stores to the virtual mapping are forwarded to the underlying physical device (the AXI-Lite register bank). This is not unique to this driver — it applies to every MMIO `mmap`.

### Physical addresses for DMA

The FPGA DMA engine issues AXI transactions to the DDR controller through **S_AXI_HP0**, which connects directly to the Zynq DDR controller and operates on **physical bus addresses**. The Zynq-7000 does not provide a configurable IOMMU for the PL-to-DDR path; there is no address translation between the HP port and the memory controller. The driver therefore translates virtual → physical via `/proc/self/pagemap` and must ensure the pages are page-resident before reading their PFN (hence the `mlock` requirement).

### Big-endian word encoding for KEY, IV, and TAG

RFC 2612 (CAST-256) defines all inputs in big-endian byte order. The hardware ingests key words and IV words directly as RFC-format 32-bit integers — word 0 holds bytes 0–3 (most significant). Encoding in the driver exactly mirrors the RFC notation, so test vectors from the RFC can be compared byte-for-byte without any endian swizzling in the application.

### KEY word write order and triggered H computation

The hardware triggers **H = BC(K, 0)** on the AXI write strobe to offset `0x01C` (word 7 of the key). All 8 key words must be written in order 0 → 7 because:

1. The hardware samples all 8 words into an internal register on the word-7 write edge.
2. Any word written after word 7 is ignored until the next full 8-word sequence.
3. Out-of-order writes leave some words stale, producing a different (wrong) H — a silent authentication failure with no error signal.

This design avoids a separate "key commit" command register at the cost of strict write ordering. The driver enforces this by using a sequential loop that always writes 0x000 → 0x01C.

### Silent BUSY discard

When the hardware FSM is in any state other than IDLE, AXI writes to KEY, IV, and DMA address registers are **accepted without SLVERR** (no bus error) but the data is silently dropped. This is a deliberate FSM design choice: responding with SLVERR on every spurious write during processing would require the driver to handle AXI error responses, complicating both the hardware and software. Instead, the contract is: check BUSY before writing any configuration, as enforced by every driver function.

### Shared TAG register bank for encrypt and decrypt

Offsets `0x048–0x054` serve dual purpose:

- **After encrypt (read):** hardware writes the computed 128-bit authentication tag here once DONE=1.
- **Before decrypt (write):** driver writes the expected tag here before asserting START; hardware compares the DMA-produced tag against this value and sets TAG_VALID accordingly.

Sharing saves 4 registers (16 bytes) in the register map. The driver manages the direction: always write before decrypt START, always read after encrypt DONE.

### Timeout values

| Operation | Timeout | Justification |
|-----------|---------|---------------|
| Encrypt / Decrypt | 30 s | A 1 MB payload at a conservative 100 Mbit/s effective throughput takes ~80 ms; 30 s is a 375× margin that safely covers any realistic input size without false timeouts. |
| H-key computation | 1 s | H = BC(K, 0) is a single 128-bit block cipher call. At 100 MHz with a fully pipelined CAST-256 core, this completes in O(100) clock cycles (~1 µs). 1 s is a 10⁶× margin — chosen to be robust against any synthesis or simulation artefact during development. |

### Cache coherency requirement

The Cortex-A9 and the FPGA DMA engine share DDR but **do not share a coherent interconnect** on this design. The Zynq ACP (Accelerator Coherency Port) is not used; HP0 bypasses the SCU. Consequence:

- CPU writes to a buffer sit in L1/L2 until the cache line is evicted. If the DMA reads DDR before eviction, it sees stale data. → **flush before DMA read** (`crypto_flush_cache`).
- DMA writes to DDR are invisible to the CPU until the relevant cache line is invalidated. If the CPU reads before invalidation, it gets the old cached value. → **invalidate after DMA write** (`crypto_invalidate_cache`).

Both operations use `__builtin___clear_cache`, which on ARM GCC emits the `dmb` (data memory barrier) and the CP15 cache maintenance instructions needed to clean and invalidate the affected lines.

---

## Build

```bash
# Static library (link into your application)
cd sw/driver
arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard \
    -c crypto_driver.c -o crypto_driver.o
arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard \
    -c crypto_mem.c    -o crypto_mem.o
ar rcs libcrypto_driver.a crypto_driver.o crypto_mem.o

# On-board hardware test binary
arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard \
    crypto_driver.c crypto_mem.c crypto_test.c -o crypto_tests

# Host-side logic tests (no hardware required, GCC on Linux / MSYS2)
gcc -Wall -Wextra -O2 -DCRYPTO_TEST_BUILD -I. tests/test_logic.c crypto_driver.c -o test_logic
./test_logic

# Or use make:
make lib         # cross-compile static library
make tests_arm   # cross-compile on-board test binary
make test        # build + run host logic tests
```

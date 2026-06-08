# CAST-256/GCM Accelerator: Project Overview

## Summary

This project is a hardware-accelerated authenticated encryption engine targeting the **Zynq-7000 SoC (Zybo Rev. B)**. It implements the **CAST-256** block cipher (RFC 2612) in **GCM mode** (NIST SP 800-38D), providing both encryption and authentication (AEAD) in a single hardware pipeline accessible from Linux userspace via an AXI4-Lite slave interface.

The system is partitioned into three hardware components developed independently, plus a software driver:

| Component | Location | Role |
|-----------|----------|------|
| AXI Slave | `vhdl/axi_slave/` | Control plane - register bank, CPU interface |
| DMA Engine | `vhdl/dma/` | Data plane - moves plaintext/AAD/ciphertext to/from DDR |
| Crypto Core | `vhdl/crypto/cast256/` + `vhdl/crypto/gcm/` | CAST-256 cipher + GCM mode orchestration |
| Top-level | `vhdl/crypto/crypto.vhd` | Wires all three; hosts the GCM FSM inline |
| SW Driver | `driver/` | Userspace C library (`/dev/mem`, polling) |

---

## Directory Structure

```
cast256/
├── README.md                     Project specification & requirements
├── ANNEX_DMA.md                  DMA engine design review & state diagrams
├── ANNEX_DRIVER.md               Software driver reference & call sequences
│
├── vhdl/crypto/
│   ├── crypto.vhd                TOP-LEVEL: instantiates all components + inline GCM FSM
│   │
│   ├── axi_slave/
│   │   ├── axi_slave.vhd         Structural wrapper (instantiates _rd + _wr)
│   │   ├── axi_slave_wr.vhd      Write channel + register bank
│   │   ├── axi_slave_rd.vhd      Read channel + CSR encoding
│   │   ├── axi_slave_pkg.vhd     Register map constants
│   │   ├── tb_axi_slave.vhd      Testbench
│   │   └── Makefile
│   │
│   ├── dma/
│   │   ├── dma_engine.vhd        Top-level wrapper (read + write engines)
│   │   ├── dma_read_engine.vhd   4-state FSM: AR→R channel, 4 words/block
│   │   ├── dma_write_engine.vhd  5-state FSM: AW→W→B channels, 2-entry FIFO
│   │   ├── block_join.vhd        32-bit → 128-bit assembly (big-endian)
│   │   ├── block_split.vhd       128-bit → 32-bit streaming
│   │   ├── fifo.vhd              Generic parameterized FIFO
│   │   ├── dma_mem_init.hex      Behavioral memory for simulation
│   │   ├── tb_dma_engine.vhd     8-test self-checking testbench
│   │   └── Makefile
│   │
│   ├── cast256/
│   │   ├── cast256.vhd           Top-level: mux input, instantiate KS + enc
│   │   ├── cast256_ks.vhd        Key schedule: 24 octaves, ~396 cycles latency
│   │   ├── cast256_enc.vhd       Encryption: 12 rounds, 96 cycles latency
│   │   ├── cast256_pkg.vhd       S-box constants, types, helper functions
│   │   ├── tb_cast256.vhd        Testbench (RFC 2612 KAT vectors)
│   │   ├── synth_cast256.tcl     Vivado synthesis script
│   │   └── Makefile
│   │
│   └── gcm/
│       ├── gcm.vhd               Standalone GCM FSM (alternate - currently unused)
│       ├── ghash.vhd             128-bit GHASH accumulator, 33-cycle latency
│       ├── gf128_mul.vhd         GF(2^128) multiplier, 32-cycle latency
│       ├── gcm_pkg.vhd           GF_R reduction polynomial, inc32 function
│       ├── tb_gcm.vhd            Testbench
│       └── Makefile
│
├── driver/
│   ├── crypto_driver.h/c         Public API: encrypt, decrypt, key/IV setup
│   ├── crypto_regs.h             Hardware register map
│   ├── crypto_mem.c              Cache coherency helpers (flush/invalidate)
│   ├── crypto_hw_priv.h          Private: memory layout internals
│   ├── crypto_errors.h           Error codes: CRYPTO_ERR_*
│   ├── crypto_test.c             On-board demo
│   ├── Makefile                  Cross-compile: arm-linux-gnueabihf
│   └── tests/
│       ├── test_logic.c          Host-side unit tests (no hardware)
│       └── Makefile
│
└── doc/
    ├── cast256.pdf               RFC 2612: CAST-256 specification
    └── gcm.pdf                   NIST SP 800-38D: GCM specification
```

---

## Component Details

### 1. AXI Slave - Control Plane

**Files:** `axi_slave.vhd`, `axi_slave_wr.vhd`, `axi_slave_rd.vhd`, `axi_slave_pkg.vhd`

AXI4-Lite slave with a 12-bit address space (4 kB). Split into a write channel (AW+W+B) and a read channel (AR+R) to reduce state machine complexity.

**Register map:**

| Offset | Register | Access | Width | Description |
|--------|----------|--------|-------|-------------|
| 0x000–0x01C | KEY[0–7] | W | 32×8 | 256-bit secret key (word 7 write triggers `key_loaded_pulse`) |
| 0x020–0x028 | IV[0–2] | W | 32×3 | 96-bit initialization vector |
| 0x02C | AAD_ADDR | W | 32 | Byte address of AAD buffer in DDR |
| 0x030 | AAD_LEN | W | 32 | AAD length in bytes (multiple of 16) |
| 0x034 | PT_ADDR | W | 32 | Byte address of plaintext buffer |
| 0x038 | PT_LEN | W | 32 | Plaintext length in bytes (multiple of 16) |
| 0x03C | CT_ADDR | W | 32 | Byte address for ciphertext output |
| 0x040 | CT_LEN | R | 32 | Ciphertext length (written by GCM FSM on completion) |
| 0x044–0x054 | TAG[0–3] | R/W | 32×4 | Auth tag - read after encrypt, write before decrypt |
| 0x058 | CSR | R/W | 32 | Control/Status (see below) |
| 0x05C | DEBUG | R | 32 | FSM state [3:0] |
| others | - | - | - | Returns DECERR |

**CSR bit map:**

| Bit | Name | Direction | Description |
|-----|------|-----------|-------------|
| 0 | START | W | Write 1 to launch AEAD operation (one-cycle pulse) |
| 1 | SOFT_RESET | W | Write 1 to reset FSM |
| 2 | MODE | W | 0 = encrypt, 1 = decrypt |
| 8 | BUSY | R | Operation in progress |
| 9 | DONE | R | Operation complete |
| 10 | TAG_VALID | R | Computed tag is valid (encrypt) or tag matched (decrypt) |
| 11 | ERROR | R | DMA or auth error occurred |

**Key design decisions:**
- Writing key word 7 (offset `0x01C`) triggers `key_loaded_pulse`; out-of-order writes are silently dropped.
- Writes to configuration registers while `BUSY=1` are accepted by the AXI channel but ignored by the GCM FSM.
- The TAG register bank is shared between encrypt (read computed tag) and decrypt (write expected tag).

---

### 2. DMA Engine - Data Plane

**Files:** `dma_engine.vhd`, `dma_read_engine.vhd`, `dma_write_engine.vhd`, `block_join.vhd`, `block_split.vhd`, `fifo.vhd`

AXI4-Lite master with a 30-bit address space (1 GB). Transfers data between DDR and the cryptographic core in 128-bit blocks via sequential 32-bit AXI transactions.

**Read engine (4-state FSM):**  
`IDLE → RD_ISSUE_AR → RD_WAIT_RDATA → RD_BLOCK_READY`  
Issues AR channel, receives 4×32-bit words via R channel, assembles them into a 128-bit block via `block_join`, asserts `rd_block_valid`, waits for `rd_block_consumed` pulse from GCM FSM.

**Write engine (5-state FSM + 2-entry FIFO):**  
`IDLE → WR_ISSUE_AW → WR_ISSUE_W → WR_WAIT_B → WR_NEXT`  
Accepts 128-bit blocks from GCM FSM into a FIFO, decomposes them via `block_split`, issues AW+W+B for each 32-bit word.

**Block assembly endianness:** Big-endian - first AXI word → bits [127:96], last word → bits [31:0]. Consistent with RFC 2612 byte ordering.

**Performance:**
- Read: 18 cycles/block → ~89 MB/s @ 100 MHz
- Write: 16 cycles/block + 1-cycle gap → ~80 MB/s @ 100 MHz
- Read and write engines are independent FSMs with disjoint AXI channels, enabling overlap.

**Key design decisions:**
- AXI4-Lite (no outstanding transactions) is sufficient given CAST-256's ~96-cycle latency cap of ~17 MB/s sustained throughput.
- 2-entry write FIFO decouples GCM output timing from AXI slave congestion.
- `rd_done`, `wr_done`, `dma_error` are sticky (level) signals, cleared on the next `rd_start`/`wr_start` pulse.

---

### 3. CAST-256 Block Cipher

**Files:** `cast256.vhd`, `cast256_ks.vhd`, `cast256_enc.vhd`, `cast256_pkg.vhd`

128-bit block cipher per RFC 2612. Only encryption is implemented (GCM requires only `BC(K, block)` for CTR stream generation and tag computation; decryption uses the same forward encryption path).

**Key schedule (`cast256_ks.vhd`):**  
24 octaves × 8 f-functions × 2 cycles (ADDR + COMPUTE via Block RAM) ≈ **396 cycles latency**.  
Produces rotation keys (`kr_array_t`: 12 sets of 4×5-bit) and masking keys (`km_array_t`: 12 sets of 4×32-bit).

**Encryption (`cast256_enc.vhd`):**  
12 rounds (6 forward quad-rounds Q + 6 reverse quad-rounds QBAR), 4 f-functions per round, 2 cycles each → **96 cycles latency**.  
S-boxes (SBOX1–SBOX4) implemented as 256×32 Block RAM (`ram_style="block"` → RAMB18 primitives).

**Interface:**

| Port | Width | Direction | Description |
|------|-------|-----------|-------------|
| `key` | 256 | in | Secret key |
| `key_valid` | 1 | in | Pulse: start key schedule |
| `key_ready` | 1 | out | High when key schedule complete |
| `plaintext` | 128 | in | Input block |
| `encrypt_start` | 1 | in | Pulse: start encryption (gated with `key_ready`) |
| `ciphertext` | 128 | out | Encrypted output |
| `enc_done` | 1 | out | High when output valid |

---

### 4. GCM Mode

**Files:** `gcm.vhd` (standalone, currently unused), `ghash.vhd`, `gf128_mul.vhd`, `gcm_pkg.vhd`  
**Integrated as:** inline FSM inside `crypto.vhd`

**GCM FSM states (as in `crypto.vhd`):**  
`GCM_IDLE → GCM_KEY_SCHED → GCM_COMPUTE_H → GCM_PROCESS_AAD → GCM_ENCRYPT → GCM_GEN_TAG → GCM_DONE / GCM_ERROR / GCM_SOFT_RESET`

**Encryption sequence:**
1. `key_loaded_pulse` → key schedule (~396 cycles) → `BC(K, 0^128)` → H subkey (~96 cycles)
2. `rd_start` → DMA reads AAD blocks → fed to GHASH
3. For each plaintext block: read via DMA + `BC(K, counter)` via CAST-256 + XOR → ciphertext → write via DMA + feed ciphertext to GHASH (read and write overlap)
4. GHASH length block flush
5. `BC(K, J0)` XOR GHASH accumulator → authentication tag

**GHASH (`ghash.vhd`):**  
Maintains 128-bit accumulator `Y`, updated per block: `Y_i = (Y_{i−1} XOR X_i) · H` over GF(2^128).  
33-cycle latency (32-cycle `gf128_mul` + 1 pipeline stage).  
Since 33 cycles < 96 cycles (CAST-256 latency), GHASH never stalls the pipeline.

**GF(2^128) multiplier (`gf128_mul.vhd`):**  
32-cycle latency. Reduction polynomial: `x^128 + x^7 + x^2 + x + 1`.

**CTR counter:** `counter = IV || 0x00000002`, incremented via `inc32` on lower 32 bits per block.  
**Tag input:** `J0 = IV || 0x00000001`.

---

### 5. Top-Level Wrapper (`crypto.vhd`)

Instantiates `axi_slave`, `dma_engine`, `cast256`, and `ghash`. The GCM FSM is implemented **inline** (not as a separate entity) and orchestrates all three components.

**Cipher input mux** (`cipher_mux` enum):
- `MUX_H_COMPUTE` → `0^128` (H subkey precomputation)
- `MUX_CTR` → CTR counter block (stream cipher)
- `MUX_TAG_GEN` → J0 block (final tag encryption)

**External ports:**
- `aclk`, `aresetn` - system clock and active-low reset
- `s0_axi_*` - AXI4-Lite slave (12-bit, CPU control plane)
- `m0_axi_*` - AXI4-Lite master (30-bit, DDR data plane)
- `irq` - interrupt to PS on completion

---

### 6. Software Driver

**Files:** `driver/`

Userspace C library for Linux on the Zynq PS.

| Design choice | Rationale |
|---------------|-----------|
| `/dev/mem` mmap, not kernel module | No module signing required; sufficient for research prototype |
| Polling, not interrupts | Avoids GIC configuration; latency acceptable for sub-second operations |
| Physical addresses via `/proc/self/pagemap` | Zynq HP0 bypasses MMU; DMA needs physical DDR addresses |
| Explicit cache flush/invalidate | Zynq L1/L2 not coherent with FPGA DMA; `__builtin___clear_cache` required |
| Big-endian key/IV/tag encoding | RFC 2612 §2.1: byte 0 = most significant byte |

---

## Known Issues

| Priority | Issue | Location | Description |
|----------|-------|----------|-------------|
| High | Address width truncation | `crypto.vhd` | `axi_slave` outputs 32-bit addresses; DMA's AXI master is 30-bit. Top 2 bits silently discarded - silent data corruption if address > 1 GB |
| High | Conflicting GCM implementations | `gcm.vhd` vs `crypto.vhd` | Standalone `gcm.vhd` uses different port names (`dma_rd_req_o`, `dma_rd_addr_o`, …) from what `crypto.vhd`'s inline FSM expects (`rd_start`, `rd_base`, …). `gcm.vhd` is currently not instantiated. |
| High | H precomputation readiness | `crypto.vhd`, `axi_slave_rd.vhd` | No explicit CSR bit signals when H subkey is ready. CPU must infer this from DEBUG register or blind polling. |
| Medium | GHASH length block format undocumented | `gcm_pkg.vhd` | Layout `len_block = aad_len_bits ∥ ct_len_bits` (128-bit total) not defined as a constant or comment |
| Medium | `block_join`/`block_split` endianness not commented | `block_join.vhd`, `block_split.vhd` | Big-endian word assembly is critical for auth correctness; not documented inline |
| Low | No integration testbench | - | All testbenches are per-component. No `tb_crypto_integration.vhd` exercises `crypto.vhd` end-to-end |
| Low | Makefile inconsistencies | All `Makefile` files | Minor GHDL flag differences; no shared `Makefile.common` |

---

## Encryption Data Flow

```
CPU (Linux driver)
  │
  ├─ Write KEY[0–7], IV[0–2], AAD_ADDR/LEN, PT_ADDR/LEN, CT_ADDR
  └─ Write CSR.START = 1
       │
       ▼
  axi_slave  ──(csr_start pulse)──►  GCM FSM (in crypto.vhd)
                                          │
                      ┌───────────────────┤
                      │                   │
              key_valid pulse        rd_start (AAD)
                      │                   │
                      ▼                   ▼
                 CAST-256 KS          DMA Read ──► DDR
                 (~396 cycles)            │
                      │            rd_block_data (128-bit)
               cipher_start (H)          │
                      │                  ▼
                 CAST-256 Enc        GHASH (AAD blocks)
                 (~96 cycles)             │
                      │            (accumulate Y)
                  H subkey ─────────►  H_reg
                                         │
                      ┌──────────────────┤
                      │  for each plaintext block:
                      │
                 rd_start (PT) ──► DMA Read ──► DDR
                      │
                 rd_block_data ──► XOR ◄── cipher_dout (BC(K,ctr))
                                    │
                              ciphertext ─┬─► wr_block_data ──► DMA Write ──► DDR
                                          └─► GHASH (CT blocks)
                                                    │
                                             GHASH length block
                                                    │
                                             cipher_start (J0) ──► CAST-256
                                                    │
                                        tag = BC(K,J0) XOR GHASH_accum
                                                    │
  axi_slave  ◄──(DONE, TAG_VALID, tag_computed)──  GCM FSM
       │
  irq ──► CPU
```

---

## Simulation & Build

All VHDL components use **GHDL** for simulation. Each subdirectory has a `Makefile` with a `make run` target.

The software driver cross-compiles with `arm-linux-gnueabihf-gcc` for deployment on the Zynq PS.

Reference: `vhdl/crypto/cast256/test_suite/cast.c` provides a pure-C CAST-256 implementation for golden-value comparison.

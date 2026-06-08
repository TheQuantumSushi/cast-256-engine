# CAST-256/GCM Accelerator - Integration Roadmap

This document describes the sequence of sessions needed to integrate the three independently developed components (AXI slave, DMA engine, CAST-256/GCM) into a working `crypto.vhd` top-level.

> **Rule:** no step depends on a later one. Each session should leave the repository in a compilable, simulatable state before the next begins.

---

## Step 1 - Reconcile `gcm.vhd` vs. the inline GCM FSM in `crypto.vhd` ✅ DONE

### Decision: `gcm.vhd` is the authoritative implementation

`crypto.vhd`'s inline GCM FSM and the `ghash_engine` component it referenced have been removed. `crypto.vhd` now instantiates `u_gcm : gcm` alongside `u_slave : axi_slave` and `u_dma : dma_engine`.

### Why `gcm.vhd` wins - four findings

**Finding 1 - `crypto.vhd` cannot compile (fatal)**

`crypto.vhd` declared a component `ghash_engine` and tried to instantiate it. No such entity exists. The real file is `gcm/ghash.vhd` with entity `ghash` - completely different port names (`flush_len`/`aad_len_bits`/`ct_len_bits` do not exist in `ghash.vhd`).

**Finding 2 - `gcm.vhd` is more complete and correct**

`gcm.vhd` uses the actual `ghash.vhd` interface directly (`blk_i`, `valid_i`, `clear_i`, `Y_o`, `done_o`). It handles both encrypt and decrypt modes, feeds the GHASH length block manually (`GCM_LEN_HASH` state), and includes ARM states (`GCM_KS_ARM`, `GCM_H_ARM`, `GCM_GCTR_ARM`, `GCM_TAG_ARM`) that prevent reading a stale `enc_done='1'` before a new encryption starts. The inline FSM in `crypto.vhd` had none of these.

**Finding 3 - `gcm.vhd` is self-contained (kills Steps 4 original)**

`gcm.vhd` internally instantiates both `cast256` and `ghash`. There is nothing for `crypto.vhd` to wire between those two components and a GCM orchestrator - that wiring already exists inside `gcm.vhd`. The original Step 4 (CAST-256 + GHASH ↔ GCM wiring) is therefore obsolete and has been removed from the plan.

**Finding 4 - DMA interface model mismatch (deferred to Step 3)**

`gcm.vhd` uses a per-block request model: one `dma_rd_req_o` pulse + `dma_rd_addr_o` per block. `dma_engine.vhd` uses a burst model: one `rd_start` + total `rd_block_count` upfront, then streams blocks. A bridge adapter process in `crypto.vhd` must translate between the two. This is the main work of Step 3.

**Finding 5 - Key schedule model differs (behavioral trade-off)**

`gcm.vhd` re-runs the ~396-cycle key schedule on every `start_i`, then computes H = BC(K,0) (~96 cycles). The `key_loaded_pulse` from `axi_slave` is no longer used. This adds ~500 cycles per operation but is always correct. `csr_busy` covers this entire window so the CPU correctly sees BUSY from START to DONE.

### Definitive signal-name table

#### AXI slave → `gcm` (via `crypto.vhd`)

| `axi_slave` port | `crypto.vhd` signal | `gcm` port | Width | Notes |
|------------------|---------------------|-----------|-------|-------|
| `key_reg` | `key_reg` | `key_i` | 256 | Direct |
| `iv_reg` | `iv_reg` | `iv_i` | 96 | Direct |
| `aad_addr_reg` | `aad_addr_reg` | `aad_addr_i` | 30 | `[29:0]` - bounds-checked by Step 2 |
| `aad_len_reg` | `aad_len_reg` | `aad_len_i` | 30 | `[29:0]` |
| `pt_addr_reg` | `pt_addr_reg` | `pt_addr_i` | 30 | `[29:0]` |
| `pt_len_reg` | `pt_len_reg` | `pt_len_i` | 30 | `[29:0]` |
| `ct_addr_reg` | `ct_addr_reg` | `ct_addr_i` | 30 | `[29:0]` |
| `tag_reg_out` | `tag_expected` | `tag_i` | 128 | Expected tag (decrypt) |
| `csr_start` | `csr_start` | `start_i` | 1 | One-cycle pulse |
| `csr_mode` | `csr_mode` | `mode_i` | 1 | 0=enc, 1=dec |
| `csr_soft_reset` | `aresetn_gcm` | `aresetn` | 1 | `aresetn AND NOT csr_soft_reset` |
| `key_loaded_pulse` | `key_loaded` | (unused) | 1 | Signal kept to avoid undriven-output warning |

#### `gcm` → AXI slave (via `crypto.vhd` `p_status` process)

| `gcm` port | `crypto.vhd` signal | `axi_slave` port | Notes |
|------------|---------------------|-----------------|-------|
| `done_o` | `gcm_done` | `csr_done` | Latched on rising edge |
| `auth_fail_o` | `gcm_auth_fail` | `csr_error` | Latched when `gcm_done='1'` |
| `tag_o` | `gcm_tag` → `tag_computed` | `tag_computed_in` | Latched when `gcm_done='1'` |
| (derived) | `csr_busy` | `csr_busy` | Set on `csr_start`, cleared on `gcm_done` |
| (derived) | `csr_tag_valid` | `csr_tag_valid` | Set when `gcm_done AND NOT auth_fail` |
| - | `pt_len_reg` | `ct_len_in` | GCM stream cipher: CT len = PT len |
| - | `"0000"` | `fsm_state_in` | `gcm.vhd` does not expose FSM state |

#### `gcm` DMA ports ↔ `dma_engine` (Step 3 bridge signals in `crypto.vhd`)

| `gcm` port | `crypto.vhd` bridge signal | `dma_engine` port | Step 3 adapter role |
|------------|---------------------------|-------------------|---------------------|
| `dma_rd_req_o` | `dma_rd_req` | `rd_start` | per-block req → burst start |
| `dma_rd_addr_o` | `dma_rd_addr` | `rd_base_addr[29:0]` | first req addr → base |
| `dma_rd_data_i` | `dma_rd_data` | `rd_block_data` | stream forward |
| `dma_rd_valid_i` | `dma_rd_valid` | `rd_block_valid` | stream forward |
| `dma_wr_req_o` | `dma_wr_req` | `wr_start` | per-block req → burst start |
| `dma_wr_addr_o` | `dma_wr_addr` | `wr_base_addr[29:0]` | first req addr → base |
| `dma_wr_data_o` | `dma_wr_data` | `wr_block_data` | per-block → stream |
| `dma_wr_done_i` | `dma_wr_done` | `wr_block_accepted` | per-block ack |

### Files changed

| File | Change |
|------|--------|
| `vhdl/crypto/crypto.vhd` | Removed broken inline FSM, `ghash_engine`, standalone `cast256`; added `gcm` component + `u_gcm` instantiation with stub DMA signals and `p_status`/`p_irq` processes |

---

## Step 2 - AXI slave ↔ GCM wiring ✅ DONE

### What was done

All signal wiring between `axi_slave` and `gcm` was completed in Step 1 as part of restructuring `crypto.vhd`. The only concrete work in this step was eliminating the 32-bit → 30-bit silent address truncation.

**Address/length registers in `axi_slave_wr.vhd` pass 32-bit values to `gcm.vhd` which only has 30-bit ports.** Bits [31:30] were silently discarded in `crypto.vhd`'s port slice. Any address ≥ 1 GB would be corrupted without error.

### Fix applied

**`axi_slave_pkg.vhd`** - added `RESP_SLVERR = "10"` (was missing; only OKAY and DECERR existed).

**`axi_slave_wr.vhd`** - added `wr_slverr_v` variable and a `data_v[31:30] /= "00"` check on all five address/length registers:

| Register | Offset | Constraint |
|----------|--------|------------|
| AAD_ADDR | 0x030 | Byte address into 1 GB DDR space |
| AAD_LEN | 0x034 | Byte length, max 1 GB |
| PT_ADDR | 0x038 | Byte address into 1 GB DDR space |
| PT_LEN | 0x03C | Byte length, max 1 GB |
| CT_ADDR | 0x040 | Byte address into 1 GB DDR space |

Any write with bits [31:30] non-zero returns SLVERR on the AXI B channel and leaves the register unchanged. The CPU detects the error via the B channel; no `csr_error` bit is set (that is reserved for cryptographic runtime errors).

### Files changed

| File | Change |
|------|--------|
| `axi_slave/axi_slave_pkg.vhd` | Added `RESP_SLVERR = "10"` |
| `axi_slave/axi_slave_wr.vhd` | `wr_slverr_v` variable; bounds check on 5 registers; SLVERR branch in response logic |

---

## Step 3 - DMA burst adapter ✅ DONE

**Bridge `gcm.vhd`'s per-block DMA request model to `dma_engine.vhd`'s burst model.**

### The mismatch

`gcm.vhd` was designed for a simple DMA that responds to individual block requests:

```
gcm → dma_rd_req_o (pulse) + dma_rd_addr_o (addr for this block)
dma → dma_rd_data_i (128-bit block) + dma_rd_valid_i (pulse)
```

`dma_engine.vhd` uses a burst model that requires the total count upfront:

```
gcm → rd_start (pulse) + rd_base_addr + rd_block_count
dma → rd_block_data + rd_block_valid (stream)
gcm → rd_block_consumed (per-block ack)
dma → rd_done (sticky, all blocks done)
```

### Adapter design

Add a `p_dma_adapter` process in `crypto.vhd` that bridges the two models. The adapter must handle three independent phases:

**Phase 1 - AAD read (triggered by gcm's first `dma_rd_req_o` when `gcm` is in `GCM_AAD_REQ`):**
1. Latch first request address as `rd_base_addr`.
2. Derive block count from `aad_len_reg[29:4]` (byte length ÷ 16).
3. Issue one `rd_start` pulse to `dma_engine`.
4. For each `rd_block_valid` arrival: assert `rd_block_consumed`, forward `rd_block_data` → `dma_rd_data`, assert `dma_rd_valid` for one cycle.
5. On `rd_done`: phase complete.

**Phase 2 - Plaintext read + Ciphertext write (GCTR phase):**
- Same read-side pattern as Phase 1, using `pt_addr_reg` and `pt_len_reg`.
- Write side: for each `dma_wr_req_o` pulse from `gcm`, forward `dma_wr_data` → `wr_block_data`, assert `wr_block_valid`. On `wr_block_accepted`, assert `dma_wr_done` for one cycle.
- Issue `wr_start` with `ct_addr_reg` and `pt_len_reg[29:4]` upfront (before or simultaneously with `rd_start`).

**Phase detection:** use `gcm`'s own address outputs (`dma_rd_addr_o`) to distinguish phases - AAD address matches `aad_addr_reg`, PT address matches `pt_addr_reg`.

### Interface checklist (replace all stubs in `u_dma` port map)

| `dma_engine` port | Driven by |
|-------------------|-----------|
| `rd_start` | adapter |
| `rd_base_addr` | `"00" & dma_rd_addr` (30-bit padded to 32-bit) |
| `rd_block_count` | `aad_len_reg[27:4]` or `pt_len_reg[27:4]` depending on phase |
| `wr_start` | adapter |
| `wr_base_addr` | `"00" & ct_addr_reg[29:0]` |
| `wr_block_count` | `pt_len_reg[27:4]` |
| `rd_block_data` | → `dma_rd_data` |
| `rd_block_valid` | → trigger for `dma_rd_valid` |
| `rd_block_consumed` | adapter |
| `wr_block_data` | `dma_wr_data` |
| `wr_block_valid` | adapter |
| `wr_block_accepted` | → `dma_wr_done` |
| `rd_done` | adapter (phase complete flag) |
| `wr_done` | adapter |
| `dma_error` | → `csr_error` (OR with `gcm_auth_fail`) |

**Files touched:** `vhdl/crypto/crypto.vhd`  
**Deliverable:** all `-- Step 3` stubs in `u_dma` port map replaced with real signals; AAD and GCTR phases correctly sequenced; `dma_error` routed to `csr_error`.

---

## Step 4 - Control-flow fix: START while BUSY ✅ DONE

**One remaining control-path issue after Steps 1–3.**

### Issue - `csr_start` while BUSY is silently swallowed

**Current behaviour:** `axi_slave_wr.vhd` line 337 already gates START:
```vhdl
if data_v(0) = '1' and csr_busy = '0' then
    start_r <= '1';
end if;
```
If BUSY=1, the pulse is silently dropped with OKAY response. The CPU gets no indication that the START was ignored.

**Fix:** Return SLVERR on the B channel when CSR.START is written while `csr_busy = '1'`. This makes the protocol violation explicit - the CPU must not write START until DONE or an idle state is confirmed.

```vhdl
-- CSR write, START bit
if data_v(0) = '1' then
    if csr_busy = '1' then
        wr_slverr_v := '1';   -- START while BUSY: reject
    else
        start_r <= '1';
    end if;
end if;
```

Note: Issues A (H precomputation readiness) and C (key write ordering) from the original plan are **no longer applicable**:
- Issue A: `gcm.vhd` runs the key schedule on every `start_i` - `csr_busy` covers the full window from START to DONE including KS+H computation.
- Issue C: `key_loaded_pulse` is unused in the `gcm.vhd` model.

**Files touched:** `axi_slave/axi_slave_wr.vhd`  
**Deliverable:** writing CSR.START while BUSY returns SLVERR; all other CSR write behaviour unchanged.

---

## Step 5 - Integration testbench ✅ DONE

**Verify the full system end-to-end before declaring integration complete.**

**Create `vhdl/crypto/testbenches/tb_crypto_integration.vhd`.**

The testbench instantiates `crypto.vhd` and provides:
- A behavioral AXI4-Lite slave model (acts as DDR memory, responds to DMA master transactions on `m0_axi_*`)
- A BFM for the AXI4-Lite control slave (drives register writes/reads on `s0_axi_*`)

**Test sequence:**

```
1.  Reset (aresetn low for 10 cycles)
2.  Write KEY[0–7] in order (0x000–0x01C)
3.  Write IV[0–2], AAD_ADDR, AAD_LEN, PT_ADDR, PT_LEN, CT_ADDR
4.  Pre-load behavioral DDR memory with known AAD and plaintext blocks
5.  Write CSR.START = 1
6.  Poll CSR until DONE=1 (expect BUSY→DONE transition)
7.  Read TAG[0–3] - compare against NIST SP 800-38D known-answer value
8.  Read back ciphertext from behavioral memory - compare against expected
9.  Decrypt: write MODE=1, swap PT/CT addresses, write expected TAG, assert START
10. Poll DONE; verify TAG_VALID=1, csr_error=0
```

**Additional tests:**
- Bounds check: write AAD_ADDR = 0x4000_0000 → verify SLVERR on B channel, register unchanged
- START while BUSY: write START while operation in progress → verify SLVERR
- DMA error injection: make behavioral memory return RRESP ≠ OKAY → verify `csr_error=1`
- SOFT_RESET mid-operation: assert CSR.SOFT_RESET → verify FSM returns to IDLE, BUSY cleared
- Back-to-back: run two encryptions sequentially without system reset

**Files created:** `vhdl/crypto/testbenches/tb_crypto_integration.vhd`  
**Deliverable:** all tests pass under GHDL; known-answer test matches NIST SP 800-38D vector.

---

## Summary Table

| Step | Status | Scope | Files changed | Key output |
|------|--------|-------|--------------|------------|
| 1 | ✅ DONE | Reconcile two GCM implementations | `crypto.vhd` | `gcm.vhd` is authoritative; broken inline FSM removed; `p_status`/`p_irq` added; DMA stubs in place |
| 2 | ✅ DONE | Address bounds validation | `axi_slave_pkg.vhd`, `axi_slave_wr.vhd` | SLVERR on 5 address/length registers if bits [31:30] set |
| 3 | ✅ DONE | DMA burst adapter | `crypto.vhd` | All `-- Step 3` stubs replaced; per-block ↔ burst bridge implemented; `dma_wr_done` sticky for GCTR_LAST window |
| 4 | ✅ DONE | START-while-BUSY SLVERR | `axi_slave_wr.vhd` | One-line fix; explicit protocol rejection |
| ~~4 orig~~ | ~~obsolete~~ | ~~CAST-256 + GHASH wiring~~ | - | Superseded: `gcm.vhd` owns these internally |
| ~~5 orig~~ | ~~partial~~ | ~~H_READY, key ordering~~ | - | H_READY N/A; key ordering N/A; START gating → Step 4 |
| 5 | ✅ DONE | Integration testbench | `tb_crypto_integration.vhd` | T0–T10 + T_SWB + T_SRESET_MID; round-trip encrypt/decrypt; bounds/error/reset coverage |

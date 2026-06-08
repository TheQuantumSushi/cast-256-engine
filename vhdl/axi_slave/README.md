# axi_slave

AXI4-Lite slave interface between the Zynq PS (CPU) and the crypto accelerator fabric. Serves two purposes : deliver CPU inputs (key, IV, buffer addresses, mode) to the hardware, and expose hardware outputs (status, computed tag) back to the CPU.

## Source files

| File | Role |
|---|---|
| `axi_slave_pkg.vhd` | Shared constants (`RESP_OKAY`, `RESP_SLVERR`, `RESP_DECERR`), FSM state types, `is_mapped` address validator |
| `axi_slave_wr.vhd` | Write channel (AW + W + B). Owns all registers; the only stateful entity |
| `axi_slave_rd.vhd` | Read channel (AR + R). Stateless: receives `tag_in` and `mode_in` from the write channel |
| `axi_slave.vhd` | Structural wrapper that instantiates and wires `axi_slave_wr` and `axi_slave_rd` |

The two channels are kept in separate files to make each FSM shorter and easier
to validate independently.

## Register map

| Address | Register | Access | Width |
|---|---|---|---|
| `0x000–0x01C` | Key K (8 × 32-bit words, big-endian) | Write-only | 256 bits |
| `0x020–0x028` | IV (3 × 32-bit words) | Write-only | 96 bits |
| `0x02C` | Reserved | - | DECERR |
| `0x030–0x034` | AAD base address / byte length | Write-only | 32 bits each |
| `0x038–0x03C` | Plaintext base address / byte length | Write-only | 32 bits each |
| `0x040` | Ciphertext base address | Write-only | 32 bits |
| `0x044` | Ciphertext byte length | Read-only | 32 bits |
| `0x048–0x054` | Authentication tag (4 × 32-bit words) | R/W | 128 bits |
| `0x058` | Control and Status Register (CSR) | R/W | see below |
| `0x05C` | Debug (FSM state) | Read-only | 4 bits |

For address registers (AAD, PT, CT), bits `[31:30]` must be zero — the DMA interface only covers a 30-bit address space. A non-zero value returns SLVERR.

The ciphertext length at `0x044` is read-only because it is computed by the datapath. In encryption mode it equals the plaintext length, so the CPU never needs to write it.

The tag register (`0x048–0x054`) is R/W because its direction depends on the
mode. In encryption mode the datapath writes the computed tag when `csr_done` rises. In decryption mode the CPU writes the expected tag before asserting START, and the accelerator uses it for authentication verification.

### CSR bit fields (`0x058`)

| Bit | Name | Access | Description |
|---|---|---|---|
| 0 | `START` | Write | Launch the accelerator. Ignored if busy |
| 1 | `SOFT_RESET` | Write | Clear all registers. Effective even when busy |
| 2 | `MODE` | R/W | 0 = encryption, 1 = decryption |
| 8 | `BUSY` | Read | Accelerator is running |
| 9 | `DONE` | Read | Processing completed |
| 10 | `TAG_VALID` | Read | Authentication tag matched (decrypt only) |
| 11 | `ERROR` | Read | AXI bus error occurred during DMA |

## Write FSM (`axi_slave_wr`)

Four states: `WR_IDLE` → `WR_HAVE_ADDR` / `WR_HAVE_DATA` → `WR_BOTH`.

The AW and W channels are not guaranteed to arrive in the same cycle, so the FSM buffers whichever half arrives first and waits for the other before decoding the address and asserting `BVALID`.

In `WR_BOTH`, register writes are gated by `csr_busy`: writes are silently accepted (response OKAY) but the register value is not updated while the accelerator is running, since inputs must not change mid-operation.
`SOFT_RESET` is the only exception — it bypasses the busy guard and clears all registers immediately. In encryption mode, the tag register is also updated automatically by the datapath when `csr_done` rises, without a CPU write.

## Read FSM (`axi_slave_rd`)

Two states: `RD_IDLE` → `RD_LATCHED`.

`ARREADY` is asserted combinatorially when `ARVALID` is seen, completing the address handshake in one cycle. The FSM latches the address, decodes `RDATA`, and asserts `RVALID`. Once `RREADY` is seen, `RVALID` is de-asserted and the FSM returns to `RD_IDLE`.

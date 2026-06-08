/* crypto_regs.h - hardware register map and CSR bits for the CAST-256-GCM
 * AXI peripheral on the Zynq-7000 (Zybo Rev. B).
 *
 * Include this header in any file that needs to name a register or CSR bit.
 * Do NOT include it in user-facing application code - use crypto_driver.h.
 */

#ifndef CRYPTO_REGS_H
#define CRYPTO_REGS_H

/* ---------------------------------------------------------------------------
 * Register offsets (byte offsets from the peripheral base address)
 * --------------------------------------------------------------------------*/

#define REG_KEY_BASE  0x000u  /* 32 B, 8×32-bit words, write-only             */
#define REG_IV_BASE   0x020u  /* 12 B, 3×32-bit words, write-only             */
#define REG_AAD_ADDR  0x030u  /* Physical DDR address of the AAD buffer       */
#define REG_AAD_LEN   0x034u  /* AAD length in bytes (must be multiple of 16) */
#define REG_PT_ADDR   0x038u  /* Plaintext addr (enc) / ciphertext addr (dec) */
#define REG_PT_LEN    0x03Cu  /* Corresponding length in bytes                */
#define REG_CT_ADDR   0x040u  /* Ciphertext output (enc) / plaintext out (dec)*/
#define REG_CT_LEN    0x044u  /* read-only - written by hardware after enc    */
#define REG_TAG_BASE  0x048u  /* 16 B, 4×32-bit words, R/W                   */
#define REG_CSR       0x058u  /* Control/Status Register (see bits below)     */
#define REG_DEBUG     0x05Cu  /* read-only: FSM state in bits [3:0]           */

/* ---------------------------------------------------------------------------
 * CSR bit masks
 * --------------------------------------------------------------------------*/

#define CSR_START      (1u <<  0)  /* WO: write 1 to launch operation          */
#define CSR_SOFT_RESET (1u <<  1)  /* WO: write 1 to reset the state machine   */
#define CSR_MODE       (1u <<  2)  /* RW: 0 = encrypt, 1 = decrypt             */
#define CSR_BUSY       (1u <<  8)  /* RO: operation in progress                */
#define CSR_DONE       (1u <<  9)  /* RO: operation complete                   */
#define CSR_TAG_VALID  (1u << 10)  /* RO: tag matched on decrypt               */
#define CSR_ERROR      (1u << 11)  /* RO: AXI bus error (BRESP/RRESP != 00)   */

/* ---------------------------------------------------------------------------
 * Address space and timing
 * --------------------------------------------------------------------------*/

/* Zynq-7000 M_AXI_GP0 window: 0x4000_0000 – 0x7FFF_FFFF.
 * Verify the exact offset in Vivado Address Editor after block-design export. */
#define CRYPTO_BASE_PHYS  0x43C00000UL
#define CRYPTO_MAP_SIZE   0x1000u          /* 4 kB - covers the full register bank */

/* Maximum time to wait for DONE after asserting START. */
#define CRYPTO_TIMEOUT_SEC  30

#endif /* CRYPTO_REGS_H */

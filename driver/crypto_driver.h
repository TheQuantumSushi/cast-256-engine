/* crypto_driver.h - public API for the CAST-256-GCM AXI peripheral driver.
 *
 * Thin polling user-space driver over /dev/mem.
 * Requires root (CAP_SYS_RAWIO). No kernel module, no interrupts.
 *
 * Cross-compile for Zybo Cortex-A9:
 *   arm-linux-gnueabihf-gcc -Wall -Wextra -O2 \
 *       crypto_driver.c crypto_mem.c [-o <target>]
 */

#ifndef CRYPTO_DRIVER_H
#define CRYPTO_DRIVER_H

#include <stddef.h>
#include <stdint.h>

#include "crypto_errors.h"
#include "crypto_regs.h"

/* ---------------------------------------------------------------------------
 * Initialisation
 * --------------------------------------------------------------------------*/

/* Open /dev/mem and map the peripheral register bank.
 * Must be called before any other function.
 *
 * Args :
 *   - base_addr [uint32_t] : physical base address of the peripheral
 *
 * Returns :
 *   - [int] : 0, -CRYPTO_ERR_MEM_OPEN, or -CRYPTO_ERR_MMAP
 */
int crypto_init(uint32_t base_addr);

/* Unmap registers and close /dev/mem. Call at program exit. */
void crypto_cleanup(void);

/* Assert SOFT_RESET and wait 10 µs. */
void crypto_reset(void);

/* ---------------------------------------------------------------------------
 * Configuration  (call after crypto_init, before encrypt/decrypt)
 * --------------------------------------------------------------------------*/

/* Load key into hardware key registers (big-endian, MSW first).
 * key_len must be 16, 24, or 32 bytes; shorter keys are zero-padded to 32.
 * The key schedule and H = BC(K, 0) are computed on the next START pulse.
 *
 * Args :
 *   - key     [const uint8_t *] : key bytes
 *   - key_len [size_t]          : key length in bytes (16, 24, or 32)
 *
 * Returns :
 *   - [int] : 0, -CRYPTO_ERR_NOT_INIT, -CRYPTO_ERR_INVALID_KEY, or -CRYPTO_ERR_BUSY
 */
int crypto_set_key(const uint8_t *key, size_t key_len);

/* Load a 96-bit IV into hardware IV registers (big-endian, 12 bytes).
 *
 * Args :
 *   - iv [const uint8_t *] : 12-byte IV
 *
 * Returns :
 *   - [int] : 0, -CRYPTO_ERR_NOT_INIT, or -CRYPTO_ERR_BUSY
 */
int crypto_set_iv(const uint8_t *iv);

/* ---------------------------------------------------------------------------
 * Cryptographic operations
 * --------------------------------------------------------------------------*/

/* Run GCM authenticated encryption.
 * All addresses must be physical DDR addresses (use virt_to_phys()).
 * All lengths must be multiples of 16 bytes.
 * Caller must flush CPU cache for aad and pt buffers before calling.
 *
 * Args :
 *   - aad_phys [uint32_t] : physical address of the AAD buffer
 *   - aad_len  [size_t]   : AAD length in bytes
 *   - pt_phys  [uint32_t] : physical address of the plaintext buffer
 *   - pt_len   [size_t]   : plaintext length in bytes
 *   - ct_phys  [uint32_t] : physical address of the ciphertext output buffer
 *
 * Returns :
 *   - [int] : 0, -CRYPTO_ERR_NOT_INIT, -CRYPTO_ERR_BUSY, -CRYPTO_ERR_TIMEOUT,
 *             or -CRYPTO_ERR_AXI
 */
int crypto_encrypt(uint32_t aad_phys, size_t aad_len,
                   uint32_t pt_phys,  size_t pt_len,
                   uint32_t ct_phys);

/* Run GCM authenticated decryption.
 * expected_tag must point to the 16-byte tag produced during encryption.
 *
 * Args :
 *   - aad_phys     [uint32_t]        : physical address of the AAD buffer
 *   - aad_len      [size_t]          : AAD length in bytes
 *   - ct_phys      [uint32_t]        : physical address of the ciphertext buffer
 *   - ct_len       [size_t]          : ciphertext length in bytes
 *   - pt_phys      [uint32_t]        : physical address of the plaintext output buffer
 *   - expected_tag [const uint8_t *] : 16-byte authentication tag to verify
 *
 * Returns :
 *   - [int] : 0, -CRYPTO_ERR_NOT_INIT, -CRYPTO_ERR_BUSY, -CRYPTO_ERR_TIMEOUT,
 *             -CRYPTO_ERR_AXI, or -CRYPTO_ERR_TAG_MISMATCH
 */
int crypto_decrypt(uint32_t aad_phys, size_t aad_len,
                   uint32_t ct_phys,  size_t ct_len,
                   uint32_t pt_phys,
                   const uint8_t *expected_tag);

/* ---------------------------------------------------------------------------
 * Result readback
 * --------------------------------------------------------------------------*/

/* Read the 16-byte authentication tag produced after DONE=1.
 *
 * Args :
 *   - tag_out [uint8_t *] : caller-allocated 16-byte buffer
 *
 * Returns :
 *   - [int] : 0 or -CRYPTO_ERR_NOT_INIT
 */
int crypto_get_tag(uint8_t *tag_out);

/* Read the raw CSR word.
 *
 * Args :
 *   - status_out [uint32_t *] : receives the CSR value
 *
 * Returns :
 *   - [int] : 0 or -CRYPTO_ERR_NOT_INIT
 */
int crypto_get_status(uint32_t *status_out);

/* Read the ciphertext byte length written by hardware into REG_CT_LEN
 * after a completed encrypt operation.
 *
 * Args :
 *   - len_out [uint32_t *] : receives the ciphertext length in bytes
 *
 * Returns :
 *   - [int] : 0 or -CRYPTO_ERR_NOT_INIT
 */
int crypto_get_ct_len(uint32_t *len_out);

/* ---------------------------------------------------------------------------
 * Memory utilities
 * --------------------------------------------------------------------------*/

/* Translate a virtual address to a physical DDR address via /proc/self/pagemap.
 * Pins the page with mlock() before the lookup. Requires root (CAP_IPC_LOCK).
 *
 * Args :
 *   - vaddr [void *] : virtual address of the page to translate
 *
 * Returns :
 *   - [uint64_t] : physical address, or 0 on failure
 */
uint64_t virt_to_phys(void *vaddr);

/* Flush CPU D-cache lines covering [buf, buf+len) to DDR before a DMA read.
 *
 * Args :
 *   - buf [void *]  : start of the region to flush
 *   - len [size_t]  : length in bytes
 */
void crypto_flush_cache(void *buf, size_t len);

/* Invalidate CPU D-cache lines covering [buf, buf+len) after a DMA write.
 *
 * Args :
 *   - buf [void *]  : start of the region to invalidate
 *   - len [size_t]  : length in bytes
 */
void crypto_invalidate_cache(void *buf, size_t len);

/* ---------------------------------------------------------------------------
 * On-board hardware test suite (crypto_test.c)
 * --------------------------------------------------------------------------*/

/* Run a sequence of hardware self-tests (encrypt + decrypt + tamper).
 *
 * Args :
 *   - pt_phys [uint32_t] : physical address of the plaintext buffer (min 16 B)
 *   - ct_phys [uint32_t] : physical address of the ciphertext buffer (min 16 B)
 *   - pt_buf  [void *]   : virtual address of the plaintext buffer
 *   - ct_buf  [void *]   : virtual address of the ciphertext buffer
 *   - len     [size_t]   : buffer size in bytes (minimum 16)
 *
 * Returns :
 *   - [int] : 0 on all-pass, negative error code on first failure
 */
int crypto_run_unit_tests(uint32_t pt_phys, uint32_t ct_phys,
                          void *pt_buf, void *ct_buf, size_t len);

/* ---------------------------------------------------------------------------
 * Test-build hooks  (compiled only when -DCRYPTO_TEST_BUILD)
 * --------------------------------------------------------------------------*/

#ifdef CRYPTO_TEST_BUILD
/* Inject a mock register array directly, skipping /dev/mem entirely.
 *
 * Args :
 *   - mock_regs [volatile uint32_t *] : array of at least CRYPTO_MAP_SIZE/4 words
 *
 * Returns :
 *   - [int] : 0 always
 */
int crypto_init_mock(volatile uint32_t *mock_regs);

/* Controls what wait_done() writes back to the CSR register when it sees
 * CSR_START asserted (simulates the hardware completing an operation).
 * Set to CSR_DONE for success, CSR_DONE|CSR_TAG_VALID for a tag-match,
 * or CSR_ERROR for a bus error.  Default value: CSR_DONE. */
extern volatile uint32_t mock_hw_response;

/* Captures the exact CSR value the driver wrote before the last wait_done()
 * poll.  Use in tests to verify encrypt writes exactly CSR_START (MODE=0)
 * and decrypt writes CSR_MODE | CSR_START (MODE=1). */
extern volatile uint32_t mock_csr_at_start;

/* Install a hardware-model hook that replaces mock_hw_response.
 * When set, wait_done() calls hook(g_regs) instead of writing
 * mock_hw_response.  The hook must simulate hardware behaviour: run the
 * crypto operation and write results (CSR_DONE, CSR_TAG_VALID, tag
 * registers) directly into the register array.
 *
 * Args :
 *   - hook [void (*)(volatile uint32_t *)] : hook function, or NULL to revert
 */
void crypto_set_hw_hook(void (*hook)(volatile uint32_t *regs));
#endif

#endif /* CRYPTO_DRIVER_H */

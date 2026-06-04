/* hw_model.h — software model of the CAST-256-GCM hardware accelerator.
 *
 * Simulates the behaviour of the full hardware stack (axi_slave +
 * dma_engine + gcm + cast256) from the driver's point of view:
 *
 *   - Maintains the same register map as the hardware (REG_KEY_BASE …
 *     REG_CSR as defined in crypto_regs.h).
 *   - When the driver writes CSR_START, hw_model_hook() runs the
 *     corresponding GCM operation using the C reference (gcm_ref.c /
 *     cast.c) and writes the result back into the register array, exactly
 *     as the hardware would.
 *   - Translates 32-bit "physical" addresses into real pointers via a
 *     simple mapping table registered by the test.
 *
 * Usage in a test:
 *
 *   hw_model_reset();                          // clear mapping table
 *   hw_model_map(AAD_PHYS, aad_buf, aad_len);  // register memory regions
 *   hw_model_map(PT_PHYS,  pt_buf,  pt_len);
 *   hw_model_map(CT_PHYS,  ct_buf,  pt_len);
 *
 *   crypto_init_mock(mock_regs);
 *   crypto_set_hw_hook(hw_model_hook);         // connect model to driver
 *
 *   crypto_set_key(key, 32);
 *   crypto_set_iv(iv);
 *   crypto_encrypt(AAD_PHYS, aad_len, PT_PHYS, pt_len, CT_PHYS);
 *   // ct_buf and mock_regs[REG_TAG_BASE/4..] now hold the result.
 */

#ifndef HW_MODEL_H
#define HW_MODEL_H

#include <stddef.h>
#include <stdint.h>

/* Maximum number of simultaneously mapped memory regions. */
#define HW_MODEL_MAX_REGIONS 16

/* Register a (phys_addr → buffer) mapping.
 * The driver passes phys_addr to the hardware; the model translates it
 * to the real pointer.  len is the usable byte count at that address.
 * Replaces an existing entry with the same phys_addr. */
void hw_model_map(uint32_t phys_addr, void *buf, size_t len);

/* Clear all registered mappings. */
void hw_model_reset(void);

/* The hook function to pass to crypto_set_hw_hook().
 * Reads register values set by the driver, runs GCM encrypt or decrypt,
 * and writes results (CT, tag, CSR_DONE / CSR_ERROR) back into regs[]. */
void hw_model_hook(volatile uint32_t *regs);

#endif /* HW_MODEL_H */

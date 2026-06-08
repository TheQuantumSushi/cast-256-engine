/* crypto_hw_priv.h - private register-access interface.
 *
 * Include ONLY in driver source files (crypto_driver.c, crypto_test.c).
 * Never expose this header to application code.
 *
 * g_regs is defined in crypto_driver.c and shared with crypto_test.c so that
 * on-board tests can perform raw register writes (e.g. to simulate a START
 * without going through the public API).
 */

#ifndef CRYPTO_HW_PRIV_H
#define CRYPTO_HW_PRIV_H

#include <stdint.h>

/* Pointer to the mmap'd register bank - set by crypto_init / crypto_init_mock */
extern volatile uint32_t *g_regs;

static inline uint32_t reg_read(unsigned off) {
    return g_regs[off / 4];
}

static inline void reg_write(unsigned off, uint32_t val) {
    g_regs[off / 4] = val;
}

#endif /* CRYPTO_HW_PRIV_H */

/* crypto_driver.c — core driver: initialisation, key/IV loading, and
 * GCM encrypt/decrypt operations.
 *
 * Cross-compile for Zybo Cortex-A9:
 *   arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -c crypto_driver.c
 *
 * Host test build (skips /dev/mem — see crypto_init_mock):
 *   gcc -Wall -Wextra -O2 -DCRYPTO_TEST_BUILD -c crypto_driver.c
 */

/* Expose POSIX.1-2008 symbols (clock_gettime, nanosleep, usleep) under -std=c11 */
#define _POSIX_C_SOURCE 200809L

#include "crypto_driver.h"
#include "crypto_hw_priv.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifndef CRYPTO_TEST_BUILD
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

/* ---------------------------------------------------------------------------
 * Module state
 * --------------------------------------------------------------------------*/

volatile uint32_t *g_regs = NULL;  /* exported via crypto_hw_priv.h */

#ifndef CRYPTO_TEST_BUILD
static int mem_fd = -1;
#else
/* Default mock response: operation succeeds without a tag check. */
volatile uint32_t mock_hw_response = CSR_DONE;
/* Snapshot of the CSR value written by the driver just before wait_done(). */
volatile uint32_t mock_csr_at_start = 0;
/* Optional hardware-model hook — overrides mock_hw_response when set. */
static void (*mock_hw_hook)(volatile uint32_t *regs) = NULL;

void crypto_set_hw_hook(void (*hook)(volatile uint32_t *regs)) {
    mock_hw_hook = hook;
}
#endif

/* ---------------------------------------------------------------------------
 * Internal helpers
 * --------------------------------------------------------------------------*/

/* Poll the CSR until DONE or ERROR, or until the deadline passes.
 *
 * In test builds there is no real hardware to poll: when the function sees
 * CSR_START asserted it writes mock_hw_response back to the CSR (simulating
 * the hardware completing) and returns based on that value. */
static int wait_done(void) {
#ifdef CRYPTO_TEST_BUILD
    uint32_t csr = reg_read(REG_CSR);
    mock_csr_at_start = csr;  /* snapshot before mock overwrites */
    if (csr & CSR_START) {
        if (mock_hw_hook) {
            mock_hw_hook(g_regs);   /* hw model writes result directly to g_regs */
        } else {
            reg_write(REG_CSR, mock_hw_response);
        }
        csr = reg_read(REG_CSR);    /* re-read: hook or mock may have changed CSR */
    }
    if (csr & CSR_ERROR) return -CRYPTO_ERR_AXI;
    if (csr & CSR_DONE)  return 0;
    return -CRYPTO_ERR_TIMEOUT;
#else
    struct timespec deadline, now;
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += CRYPTO_TIMEOUT_SEC;

    for (;;) {
        uint32_t csr = reg_read(REG_CSR);
        if (csr & CSR_DONE)  return 0;
        if (csr & CSR_ERROR) return -CRYPTO_ERR_AXI;
        nanosleep(&(struct timespec){0, 10000}, NULL); /* 10 µs */
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec > deadline.tv_sec) return -CRYPTO_ERR_TIMEOUT;
    }
#endif
}

/* Write a 128-bit tag (16 bytes, big-endian) to the tag register bank. */
static void write_tag(const uint8_t *t) {
    for (int i = 0; i < 4; i++) {
        uint32_t w = ((uint32_t)t[4*i]   << 24) | ((uint32_t)t[4*i+1] << 16)
                   | ((uint32_t)t[4*i+2] <<  8) |  (uint32_t)t[4*i+3];
        reg_write(REG_TAG_BASE + 4u * (unsigned)i, w);
    }
}

/* Read the 128-bit tag from the tag register bank (big-endian) into out[]. */
static void read_tag(uint8_t *out) {
    for (int i = 0; i < 4; i++) {
        uint32_t w = reg_read(REG_TAG_BASE + 4u * (unsigned)i);
        out[4*i]   = (uint8_t)(w >> 24);
        out[4*i+1] = (uint8_t)(w >> 16);
        out[4*i+2] = (uint8_t)(w >>  8);
        out[4*i+3] = (uint8_t)(w);
    }
}

/* ---------------------------------------------------------------------------
 * Initialisation
 * --------------------------------------------------------------------------*/

#ifndef CRYPTO_TEST_BUILD

int crypto_init(uint32_t base_addr) {
    /* O_SYNC: forces uncached (device) access — register reads are reliable */
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("crypto_init: open /dev/mem");
        return -CRYPTO_ERR_MEM_OPEN;
    }

    g_regs = mmap(NULL, CRYPTO_MAP_SIZE, PROT_READ | PROT_WRITE,
                  MAP_SHARED, mem_fd, (off_t)base_addr);
    if (g_regs == MAP_FAILED) {
        perror("crypto_init: mmap");
        close(mem_fd);
        mem_fd = -1;
        g_regs = NULL;
        return -CRYPTO_ERR_MMAP;
    }
    return 0;
}

void crypto_cleanup(void) {
    if (g_regs)    { munmap((void *)g_regs, CRYPTO_MAP_SIZE); g_regs  = NULL; }
    if (mem_fd >= 0) { close(mem_fd);                          mem_fd = -1;   }
}

void crypto_reset(void) {
    if (!g_regs) return;
    reg_write(REG_CSR, CSR_SOFT_RESET);
    nanosleep(&(struct timespec){0, 10000}, NULL); /* 10 µs — well above any reset latency at 100 MHz */
}

#else /* CRYPTO_TEST_BUILD — host stubs */

int crypto_init(uint32_t base_addr) {
    (void)base_addr;
    return -CRYPTO_ERR_MEM_OPEN; /* /dev/mem not available on host */
}

void crypto_cleanup(void) { g_regs = NULL; }

void crypto_reset(void) {
    if (!g_regs) return;
    reg_write(REG_CSR, CSR_SOFT_RESET);
}

int crypto_init_mock(volatile uint32_t *mock_regs) {
    g_regs = mock_regs;
    return 0;
}

#endif /* CRYPTO_TEST_BUILD */

/* ---------------------------------------------------------------------------
 * Configuration
 * --------------------------------------------------------------------------*/

int crypto_set_key(const uint8_t *key, size_t key_len) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!key) return -CRYPTO_ERR_INVALID_PARAM;
    if (key_len != 16 && key_len != 24 && key_len != 32)
        return -CRYPTO_ERR_INVALID_KEY;
    if (reg_read(REG_CSR) & CSR_BUSY) return -CRYPTO_ERR_BUSY;

    uint8_t padded[32] = {0};
    memcpy(padded, key, key_len);

    /* Words written 0x000 → 0x01C in order (big-endian, MSW first).
     * Writing key registers stores the key; the GCM hardware runs the
     * key schedule and computes H = BC(K, 0) on the next START pulse,
     * not here.  No BUSY poll needed. */
    for (int i = 0; i < 8; i++) {
        uint32_t w = ((uint32_t)padded[4*i]   << 24) | ((uint32_t)padded[4*i+1] << 16)
                   | ((uint32_t)padded[4*i+2] <<  8) |  (uint32_t)padded[4*i+3];
        reg_write(REG_KEY_BASE + 4u * (unsigned)i, w);
    }
    return 0;
}

int crypto_set_iv(const uint8_t *iv) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!iv) return -CRYPTO_ERR_INVALID_PARAM;
    if (reg_read(REG_CSR) & CSR_BUSY) return -CRYPTO_ERR_BUSY;

    for (int i = 0; i < 3; i++) {
        uint32_t w = ((uint32_t)iv[4*i]   << 24) | ((uint32_t)iv[4*i+1] << 16)
                   | ((uint32_t)iv[4*i+2] <<  8) |  (uint32_t)iv[4*i+3];
        reg_write(REG_IV_BASE + 4u * (unsigned)i, w);
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * Cryptographic operations
 * --------------------------------------------------------------------------*/

int crypto_encrypt(uint32_t aad_phys, size_t aad_len,
                   uint32_t pt_phys,  size_t pt_len,
                   uint32_t ct_phys) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (reg_read(REG_CSR) & CSR_BUSY) return -CRYPTO_ERR_BUSY;

    reg_write(REG_AAD_ADDR, aad_phys);
    reg_write(REG_AAD_LEN,  (uint32_t)aad_len);
    reg_write(REG_PT_ADDR,  pt_phys);
    reg_write(REG_PT_LEN,   (uint32_t)pt_len);
    reg_write(REG_CT_ADDR,  ct_phys);
    reg_write(REG_CSR, CSR_START); /* MODE=0 (encrypt) */
    return wait_done();
}

int crypto_decrypt(uint32_t aad_phys, size_t aad_len,
                   uint32_t ct_phys,  size_t ct_len,
                   uint32_t pt_phys,
                   const uint8_t *expected_tag) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!expected_tag) return -CRYPTO_ERR_INVALID_PARAM;
    if (reg_read(REG_CSR) & CSR_BUSY) return -CRYPTO_ERR_BUSY;

    /* Tag must be written before START so hardware can compare after processing. */
    write_tag(expected_tag);

    reg_write(REG_AAD_ADDR, aad_phys);
    reg_write(REG_AAD_LEN,  (uint32_t)aad_len);
    reg_write(REG_PT_ADDR,  ct_phys);  /* ciphertext is the "input" for decrypt */
    reg_write(REG_PT_LEN,   (uint32_t)ct_len);
    reg_write(REG_CT_ADDR,  pt_phys);  /* plaintext output address */
    reg_write(REG_CSR, CSR_MODE | CSR_START);

    int ret = wait_done();
    if (ret) return ret;
    if (!(reg_read(REG_CSR) & CSR_TAG_VALID)) return -CRYPTO_ERR_TAG_MISMATCH;
    return 0;
}

/* ---------------------------------------------------------------------------
 * Result readback
 * --------------------------------------------------------------------------*/

int crypto_get_tag(uint8_t *tag_out) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!tag_out) return -CRYPTO_ERR_INVALID_PARAM;
    read_tag(tag_out);
    return 0;
}

int crypto_get_status(uint32_t *status_out) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!status_out) return -CRYPTO_ERR_INVALID_PARAM;
    *status_out = reg_read(REG_CSR);
    return 0;
}

int crypto_get_ct_len(uint32_t *len_out) {
    if (!g_regs) return -CRYPTO_ERR_NOT_INIT;
    if (!len_out) return -CRYPTO_ERR_INVALID_PARAM;
    *len_out = reg_read(REG_CT_LEN);
    return 0;
}

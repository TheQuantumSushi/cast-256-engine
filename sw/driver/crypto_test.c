/* crypto_test.c — on-board hardware test suite for the CAST-256-GCM driver.
 *
 * Requires actual hardware (Zybo + programmed bitstream).  Do NOT run on host.
 *
 * Link together with crypto_driver.c and crypto_mem.c:
 *   arm-linux-gnueabihf-gcc -Wall -Wextra -O2 \
 *       crypto_driver.c crypto_mem.c crypto_test.c -o crypto_tests
 *
 * Then run on the board (as root):
 *   ./crypto_tests
 *
 * All test results are written to stderr so they survive log redirection.
 */

#include "crypto_driver.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* ---------------------------------------------------------------------------
 * Internal test helpers
 * --------------------------------------------------------------------------*/

/* Test 1 — After writing a valid key and IV the hardware must be idle. */
static int test_idle_after_key_iv(void) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT1 FAIL: set_key returned %d\n", r); return r; }

    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT1 FAIL: set_iv returned %d\n", r); return r; }

    uint32_t csr;
    crypto_get_status(&csr);
    if (csr & CSR_BUSY) { fprintf(stderr, "UNIT1 FAIL: BUSY set after key+IV\n"); return -1; }
    if (csr & CSR_DONE) { fprintf(stderr, "UNIT1 FAIL: DONE set after key+IV\n"); return -1; }

    fprintf(stderr, "UNIT1 PASS: hardware idle after key+IV load\n");
    return 0;
}

/* Test 2 — START with all-zero addresses must not deadlock; the hardware is
 * expected to raise an AXI error (address 0 is not valid DDR) rather than
 * spinning indefinitely. */
static int test_no_deadlock_on_bad_addr(void) {
    /* Fresh key/IV to ensure the hardware is in a known state. */
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};
    crypto_reset();
    crypto_set_key(key, 16);
    crypto_set_iv(iv);

    int r = crypto_encrypt(0, 16, 0, 16, 0); /* all-zero addresses */
    if (r == -CRYPTO_ERR_TIMEOUT) {
        fprintf(stderr, "UNIT2 FAIL: hardware deadlocked (timeout)\n");
        crypto_reset();
        return -1;
    }
    /* AXI error is the expected outcome; other early returns are also fine. */
    fprintf(stderr, "UNIT2 PASS: no deadlock (ret=%d)\n", r);
    crypto_reset();
    return 0;
}

/* Test 3 — Encrypt 16 zero bytes, capture and print the authentication tag. */
static int test_encrypt_zeros(uint32_t pt_phys, uint32_t ct_phys,
                               void *pt_buf, void *ct_buf, uint8_t *tag_out) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    crypto_reset();
    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT3 FAIL: set_key %d\n", r); return r; }
    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT3 FAIL: set_iv %d\n", r); return r; }

    memset(pt_buf, 0, 16);
    crypto_flush_cache(pt_buf, 16);

    r = crypto_encrypt(0, 0, pt_phys, 16, ct_phys);
    if (r) { fprintf(stderr, "UNIT3 FAIL: encrypt %d\n", r); return r; }

    crypto_invalidate_cache(ct_buf, 16);

    r = crypto_get_tag(tag_out);
    if (r) { fprintf(stderr, "UNIT3 FAIL: get_tag %d\n", r); return r; }

    fprintf(stderr, "UNIT3 PASS: encrypt OK, tag = ");
    for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", tag_out[i]);
    fprintf(stderr, "\n");
    return 0;
}

/* Test 4 — Decrypt with the correct tag from Test 3 must succeed (TAGV=1). */
static int test_decrypt_correct_tag(uint32_t pt_phys, uint32_t ct_phys,
                                     void *ct_buf, const uint8_t *tag) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    crypto_reset();
    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT4 FAIL: set_key %d\n", r); return r; }
    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT4 FAIL: set_iv %d\n", r); return r; }

    crypto_flush_cache(ct_buf, 16);

    r = crypto_decrypt(0, 0, ct_phys, 16, pt_phys, tag);
    if (r) { fprintf(stderr, "UNIT4 FAIL: decrypt %d\n", r); return r; }

    fprintf(stderr, "UNIT4 PASS: decrypt with correct tag accepted\n");
    return 0;
}

/* Test 5 — One corrupted ciphertext byte must cause a tag mismatch. */
static int test_decrypt_bad_tag(uint32_t pt_phys, uint32_t ct_phys,
                                  void *ct_buf, const uint8_t *tag) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    /* Corrupt the first byte of the ciphertext. */
    ((uint8_t *)ct_buf)[0] ^= 0xFF;
    crypto_flush_cache(ct_buf, 16);

    crypto_reset();
    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT5 FAIL: set_key %d\n", r); return r; }
    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT5 FAIL: set_iv %d\n", r); return r; }

    r = crypto_decrypt(0, 0, ct_phys, 16, pt_phys, tag);
    if (r != -CRYPTO_ERR_TAG_MISMATCH) {
        fprintf(stderr, "UNIT5 FAIL: expected TAG_MISMATCH, got %d\n", r);
        return -1;
    }

    fprintf(stderr, "UNIT5 PASS: tampered ciphertext correctly rejected\n");
    return 0;
}

/* ---------------------------------------------------------------------------
 * Public entry point
 * --------------------------------------------------------------------------*/

int crypto_run_unit_tests(uint32_t pt_phys, uint32_t ct_phys,
                          void *pt_buf, void *ct_buf, size_t len) {
    if (len < 16) {
        fprintf(stderr, "crypto_run_unit_tests: buffer must be >= 16 bytes\n");
        return -1;
    }

    int r;
    uint8_t tag[16];

    r = test_idle_after_key_iv();          if (r) return r;
    r = test_no_deadlock_on_bad_addr();    if (r) return r;
    r = test_encrypt_zeros(pt_phys, ct_phys, pt_buf, ct_buf, tag); if (r) return r;
    r = test_decrypt_correct_tag(pt_phys, ct_phys, ct_buf, tag);   if (r) return r;
    r = test_decrypt_bad_tag(pt_phys, ct_phys, ct_buf, tag);       if (r) return r;

    fprintf(stderr, "\nALL UNIT TESTS PASSED\n");
    return 0;
}

/* Expose MAP_ANONYMOUS and other Linux extensions under -std=c11 */
#define _GNU_SOURCE

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
#include "crypto_hw_priv.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>


static void print_hex(const char *label, const uint8_t *buf, int n) {
    fprintf(stderr, "%s", label);
    for (int i = 0; i < n; i++) fprintf(stderr, "%02x", buf[i]);
    fprintf(stderr, "\n");
}

/* ---------------------------------------------------------------------------
 * Diagnostic helpers
 * --------------------------------------------------------------------------*/

/* Map phys_addr via /dev/mem with O_SYNC (uncached device mapping) and print
 * len bytes.  This bypasses the CPU D-cache entirely — what you see here is
 * exactly what is in DDR right now, regardless of cache state. */
static void read_phys_uncached(const char *label, uint32_t phys, size_t len) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { fprintf(stderr, "%s[open /dev/mem failed]\n", label); return; }
    long pagesz = sysconf(_SC_PAGESIZE);
    uint32_t page_base = phys & ~((uint32_t)(pagesz - 1));
    size_t   map_len   = (size_t)(phys - page_base) + len;
    map_len = (map_len + (size_t)pagesz - 1) & ~((size_t)pagesz - 1);
    void *m = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, (off_t)page_base);
    close(fd);
    if (m == MAP_FAILED) { fprintf(stderr, "%s[mmap failed]\n", label); return; }
    const uint8_t *p = (const uint8_t *)m + (phys - page_base);
    fprintf(stderr, "%s", label);
    for (size_t i = 0; i < len; i++) fprintf(stderr, "%02x", p[i]);
    fprintf(stderr, "\n");
    munmap(m, map_len);
}

/* Write a sentinel pattern to virt, flush cache, then read the same physical
 * address via /dev/mem.  Confirms that virt_to_phys returned the right frame
 * AND that crypto_flush_cache actually commits data to DDR. */
static void verify_phys_mapping(const char *name, uint32_t phys, void *virt) {
    fprintf(stderr, "PHYS_CHECK[%s]: virt=%p  phys=0x%08x\n", name, virt, phys);

    /* Write a non-zero sentinel. */
    ((volatile uint32_t *)virt)[0] = 0xCAFEBABEu;
    ((volatile uint32_t *)virt)[1] = 0xDEADBEEFu;
    ((volatile uint32_t *)virt)[2] = 0x12345678u;
    ((volatile uint32_t *)virt)[3] = 0xABCDEF01u;
    crypto_flush_cache(virt, 16);
    read_phys_uncached("  DDR after sentinel flush : ", phys, 16);

    /* Restore zeros, flush again. */
    memset(virt, 0, 16);
    crypto_flush_cache(virt, 16);
    read_phys_uncached("  DDR after zero flush     : ", phys, 16);
}

/* Print every hardware register that is safe to read at any time. */
static void dump_hw_regs(const char *ctx) {
    fprintf(stderr, "=== HW registers [%s] ===\n", ctx);
    fprintf(stderr, "  CSR      = 0x%08x  BUSY=%d DONE=%d TAGV=%d ERR=%d MODE=%d\n",
            reg_read(REG_CSR),
            (reg_read(REG_CSR) >>  8) & 1,
            (reg_read(REG_CSR) >>  9) & 1,
            (reg_read(REG_CSR) >> 10) & 1,
            (reg_read(REG_CSR) >> 11) & 1,
            (reg_read(REG_CSR) >>  2) & 1);
    fprintf(stderr, "  DEBUG    = 0x%08x  (FSM state in bits[3:0] = %u)\n",
            reg_read(REG_DEBUG), reg_read(REG_DEBUG) & 0xFu);
    fprintf(stderr, "  AAD_ADDR = 0x%08x\n", reg_read(REG_AAD_ADDR));
    fprintf(stderr, "  AAD_LEN  = 0x%08x\n", reg_read(REG_AAD_LEN));
    fprintf(stderr, "  PT_ADDR  = 0x%08x\n", reg_read(REG_PT_ADDR));
    fprintf(stderr, "  PT_LEN   = 0x%08x\n", reg_read(REG_PT_LEN));
    fprintf(stderr, "  CT_ADDR  = 0x%08x\n", reg_read(REG_CT_ADDR));
    fprintf(stderr, "  CT_LEN   = 0x%08x  (bytes written by HW after encrypt)\n",
            reg_read(REG_CT_LEN));
    fprintf(stderr, "  TAG      = %08x%08x%08x%08x\n",
            reg_read(REG_TAG_BASE +  0),
            reg_read(REG_TAG_BASE +  4),
            reg_read(REG_TAG_BASE +  8),
            reg_read(REG_TAG_BASE + 12));
    fprintf(stderr, "===========================\n");
}

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

/* Test 2 — START with all-zero addresses must not deadlock. */
static int test_no_deadlock_on_bad_addr(void) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};
    crypto_reset();
    crypto_set_key(key, 16);
    crypto_set_iv(iv);

    int r = crypto_encrypt(0, 16, 0, 16, 0);
    if (r == -CRYPTO_ERR_TIMEOUT) {
        fprintf(stderr, "UNIT2 FAIL: hardware deadlocked (timeout)\n");
        crypto_reset();
        return -1;
    }
    fprintf(stderr, "UNIT2 PASS: no deadlock (ret=%d)\n", r);
    crypto_reset();
    return 0;
}

/* Test 3 — Encrypt 16 zero bytes, capture and print the authentication tag. */
static int test_encrypt_zeros(uint32_t pt_phys, uint32_t ct_phys,
                               void *pt_buf, void *ct_buf, uint8_t *tag_out) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    fprintf(stderr, "UNIT3 DBG: pt_phys=0x%08x  ct_phys=0x%08x\n", pt_phys, ct_phys);

    /* Confirm that virt_to_phys and crypto_flush_cache are both working. */
    verify_phys_mapping("pt", pt_phys, pt_buf);
    verify_phys_mapping("ct", ct_phys, ct_buf);

    crypto_reset();
    dump_hw_regs("after reset, before encrypt");

    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT3 FAIL: set_key %d\n", r); return r; }
    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT3 FAIL: set_iv %d\n", r); return r; }

    /* Ensure pt is zero in DDR, ensure ct slot is clean. */
    memset(pt_buf, 0, 16);
    crypto_flush_cache(pt_buf, 16);
    memset(ct_buf, 0, 16);
    crypto_flush_cache(ct_buf, 16);

    read_phys_uncached("UNIT3 DBG: pt DDR before encrypt   = ", pt_phys, 16);
    read_phys_uncached("UNIT3 DBG: ct DDR before encrypt   = ", ct_phys, 16);

    r = crypto_encrypt(0, 0, pt_phys, 16, ct_phys);

    dump_hw_regs("immediately after encrypt returns");

    /* Gold-standard check: bypass cache entirely. */
    read_phys_uncached("UNIT3 DBG: ct DDR via /dev/mem     = ", ct_phys, 16);

    /* Cache-invalidate path. */
    crypto_invalidate_cache(ct_buf, 16);
    print_hex("UNIT3 DBG: ct CPU view (from DDR)  = ", (uint8_t *)ct_buf, 16);

    /* Re-read pt slot to confirm HW didn't scribble there. */
    read_phys_uncached("UNIT3 DBG: pt DDR after encrypt    = ", pt_phys, 16);

    if (r) { fprintf(stderr, "UNIT3 FAIL: encrypt returned %d\n", r); return r; }

    r = crypto_get_tag(tag_out);
    if (r) { fprintf(stderr, "UNIT3 FAIL: get_tag %d\n", r); return r; }

    fprintf(stderr, "UNIT3 PASS: encrypt OK, tag = ");
    for (int i = 0; i < 16; i++) fprintf(stderr, "%02x", tag_out[i]);
    fprintf(stderr, "\n");
    return 0;
}

/* Test 4 — Decrypt with the correct tag from Test 3 must succeed (TAGV=1). */
static int test_decrypt_correct_tag(uint32_t pt_phys, uint32_t ct_phys,
                                     void *ct_buf, void *pt_buf,
                                     const uint8_t *tag) {
    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};

    print_hex("UNIT4 DBG: expected tag              = ", tag, 16);

    /* Gold-standard: what does DDR actually hold for ct right now? */
    read_phys_uncached("UNIT4 DBG: ct DDR via /dev/mem at entry = ", ct_phys, 16);
    print_hex("UNIT4 DBG: ct CPU cached view at entry  = ", (uint8_t *)ct_buf, 16);

    crypto_reset();
    dump_hw_regs("after reset, before decrypt");

    int r = crypto_set_key(key, 16);
    if (r) { fprintf(stderr, "UNIT4 FAIL: set_key %d\n", r); return r; }
    r = crypto_set_iv(iv);
    if (r) { fprintf(stderr, "UNIT4 FAIL: set_iv %d\n", r); return r; }

    /* Flush ct_buf so HW reads the actual ciphertext from DDR. */
    crypto_flush_cache(ct_buf, 16);
    read_phys_uncached("UNIT4 DBG: ct DDR after flush (pre-dec)  = ", ct_phys, 16);

    /* Zero out pt slot and flush so HW writes into a clean DDR frame. */
    memset(pt_buf, 0, 16);
    crypto_flush_cache(pt_buf, 16);
    read_phys_uncached("UNIT4 DBG: pt DDR before decrypt         = ", pt_phys, 16);

    r = crypto_decrypt(0, 0, ct_phys, 16, pt_phys, tag);

    dump_hw_regs("immediately after decrypt returns");

    read_phys_uncached("UNIT4 DBG: pt DDR via /dev/mem post-dec  = ", pt_phys, 16);
    crypto_invalidate_cache(pt_buf, 16);
    print_hex("UNIT4 DBG: pt CPU view post-inv          = ", (uint8_t *)pt_buf, 16);

    if (r) { fprintf(stderr, "UNIT4 FAIL: decrypt returned %d\n", r); return r; }

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
    r = test_decrypt_correct_tag(pt_phys, ct_phys, ct_buf, pt_buf, tag); if (r) return r;
    r = test_decrypt_bad_tag(pt_phys, ct_phys, ct_buf, tag);       if (r) return r;

    fprintf(stderr, "\nALL UNIT TESTS PASSED\n");
    return 0;
}

/* ---------------------------------------------------------------------------
 * Entry point
 * --------------------------------------------------------------------------*/

int main(void) {
    int r = crypto_init(CRYPTO_BASE_PHYS);
    if (r) {
        fprintf(stderr, "crypto_init failed: %d\n", r);
        return 1;
    }

    /* Step 1 — Fault in two anonymous pages to pin stable physical frames.
     * We only need these to discover pt_phys and ct_phys via virt_to_phys;
     * we will NOT use them for actual data (see step 2). */
    const size_t buf_len = 4096;  /* one full page — required for /dev/mem alignment */
    void *pt_anon = mmap(NULL, buf_len, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    void *ct_anon = mmap(NULL, buf_len, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (pt_anon == MAP_FAILED || ct_anon == MAP_FAILED) {
        fprintf(stderr, "mmap (anonymous) failed\n");
        if (pt_anon != MAP_FAILED) munmap(pt_anon, buf_len);
        if (ct_anon != MAP_FAILED) munmap(ct_anon, buf_len);
        crypto_cleanup();
        return 1;
    }
    /* Touch the pages so the kernel assigns real physical frames, then pin. */
    memset(pt_anon, 0, buf_len);
    memset(ct_anon, 0, buf_len);
    if (mlock(pt_anon, buf_len) || mlock(ct_anon, buf_len)) {
        perror("mlock");
        munmap(pt_anon, buf_len); munmap(ct_anon, buf_len);
        crypto_cleanup();
        return 1;
    }

    uint32_t pt_phys = (uint32_t)virt_to_phys(pt_anon);
    uint32_t ct_phys = (uint32_t)virt_to_phys(ct_anon);
    if (!pt_phys || !ct_phys) {
        fprintf(stderr, "virt_to_phys failed (run as root?)\n");
        munmap(pt_anon, buf_len); munmap(ct_anon, buf_len);
        crypto_cleanup();
        return 1;
    }

    /* Step 2 — Map the SAME physical pages via /dev/mem with O_SYNC.
     *
     * O_SYNC + MAP_SHARED on /dev/mem causes the kernel to create a
     * Strongly-Ordered (non-cacheable, non-bufferable) PTE for those pages.
     * Every CPU read/write goes directly to DDR, bypassing L1 and L2.
     *
     * This means:
     *   • We never need crypto_flush_cache   — writes reach DDR instantly.
     *   • We never need crypto_invalidate_cache — reads always fetch from DDR.
     *   • The DMA sees exactly what we wrote, and we see exactly what the DMA wrote
     *     (once the S_AXI_GP0 write buffer has drained — handled by the delay in
     *     wait_done()).
     *
     * The anonymous mappings (pt_anon / ct_anon) are kept mlock'd so the
     * kernel does not reclaim the physical frames, but we never write to them
     * again to avoid dirtying the cache alias. */
    int dfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (dfd < 0) {
        perror("open /dev/mem (uncached DMA buffer mapping)");
        munmap(pt_anon, buf_len); munmap(ct_anon, buf_len);
        crypto_cleanup();
        return 1;
    }
    void *pt_buf = mmap(NULL, buf_len, PROT_READ | PROT_WRITE,
                        MAP_SHARED, dfd, (off_t)pt_phys);
    void *ct_buf = mmap(NULL, buf_len, PROT_READ | PROT_WRITE,
                        MAP_SHARED, dfd, (off_t)ct_phys);
    close(dfd);
    if (pt_buf == MAP_FAILED || ct_buf == MAP_FAILED) {
        perror("mmap /dev/mem (uncached DMA buffers)");
        if (pt_buf != MAP_FAILED) munmap(pt_buf, buf_len);
        if (ct_buf != MAP_FAILED) munmap(ct_buf, buf_len);
        munmap(pt_anon, buf_len); munmap(ct_anon, buf_len);
        crypto_cleanup();
        return 1;
    }

    /* Zero DDR directly via the uncached path, overwriting any data that a
     * previous DMA run may have left in these physical frames. */
    memset(pt_buf, 0, buf_len);
    memset(ct_buf, 0, buf_len);

    r = crypto_run_unit_tests(pt_phys, ct_phys, pt_buf, ct_buf, buf_len);

    munmap(pt_buf, buf_len);
    munmap(ct_buf, buf_len);
    munmap(pt_anon, buf_len);
    munmap(ct_anon, buf_len);
    crypto_cleanup();
    return r ? 1 : 0;
}

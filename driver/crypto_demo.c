/* crypto_demo.c - end-to-end demonstration of the CAST-256/GCM accelerator.
 *
 * Encrypts a 32-byte message with 16-byte AAD, prints the ciphertext and
 * authentication tag, decrypts and verifies the plaintext, then confirms
 * that a tampered ciphertext is correctly rejected.
 *
 * Build:  make demo_arm
 * Run:    sudo ./crypto_demo   (root required for /dev/mem)
 */

#define _GNU_SOURCE

#include "crypto_driver.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* ── Demo parameters ──────────────────────────────────────────────────────── */

/* 256-bit secret key */
static const uint8_t KEY[32] = {
    0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
    0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    0x76, 0x2e, 0x71, 0x60, 0xf3, 0x8b, 0x4d, 0xa5,
    0x6a, 0x78, 0x4d, 0x90, 0x45, 0x19, 0x0c, 0xfe
};

/* 96-bit initialization vector */
static const uint8_t IV[12] = {
    0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce,
    0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88
};

/* 16 bytes of Additional Authenticated Data (1 block) */
static const uint8_t AAD[16] = "CASTOS-DEMO-V1!";

/* 32 bytes of plaintext (2 blocks) */
static const uint8_t PLAINTEXT[32] = "CAST-256/GCM on Zynq-7000  FPGA!";

#define PT_LEN   32
#define AAD_LEN  16
#define BUF_SIZE 4096   /* one full page per DMA region */

/* ── Helpers ──────────────────────────────────────────────────────────────── */

static void print_hex(const char *label, const uint8_t *buf, size_t len)
{
    printf("  %-26s ", label);
    for (size_t i = 0; i < len; i++) {
        if (i && i % 16 == 0)
            printf("\n  %-27s", "");
        printf("%02x", buf[i]);
    }
    printf("\n");
}

static void separator(void) { printf("  %s\n", "------------------------------------------------------------"); }

/* Allocate one page of DMA-accessible memory.
 *
 * Two mappings are created for the same physical page:
 *   - anon   : ordinary anonymous mmap, used only to pin the page and to
 *              obtain its physical address via virt_to_phys().
 *   - uncached: /dev/mem + O_SYNC remapping - strongly-ordered (non-cacheable).
 *              All CPU reads/writes go directly to DDR; no explicit cache flush
 *              or invalidate is ever needed.
 *
 * Returns the uncached virtual pointer, or NULL on error.
 * *phys_out  : physical DDR address
 * *anon_out  : anonymous mapping (must be munmap'd by caller)
 */
static void *alloc_dma_buf(uint32_t *phys_out, void **anon_out)
{
    void *anon = mmap(NULL, BUF_SIZE, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (anon == MAP_FAILED) return NULL;
    memset(anon, 0, BUF_SIZE);
    if (mlock(anon, BUF_SIZE) != 0) { munmap(anon, BUF_SIZE); return NULL; }

    uint32_t phys = (uint32_t)virt_to_phys(anon);
    if (!phys) { munmap(anon, BUF_SIZE); return NULL; }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { munmap(anon, BUF_SIZE); return NULL; }

    void *buf = mmap(NULL, BUF_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, (off_t)phys);
    close(fd);
    if (buf == MAP_FAILED) { munmap(anon, BUF_SIZE); return NULL; }

    *phys_out = phys;
    *anon_out = anon;
    return buf;
}

/* ── Main ─────────────────────────────────────────────────────────────────── */

int main(void)
{
    int ok = 1;   /* overall pass/fail flag */

    printf("\n");
    printf("  ============================================================\n");
    printf("  CAST-256 / GCM Hardware Accelerator  --  End-to-End Demo\n");
    printf("  Zynq-7000 (Zybo Rev. B)  |  AXI4-Lite  |  Userspace driver\n");
    printf("  ============================================================\n\n");

    /* ── Initialise hardware ──────────────────────────────────────────── */
    if (crypto_init(CRYPTO_BASE_PHYS) != 0) {
        fprintf(stderr, "  ERROR: crypto_init failed (run as root?)\n");
        return 1;
    }

    /* ── Allocate uncached DMA buffers ────────────────────────────────── */
    uint32_t aad_phys, pt_phys, ct_phys, rec_phys;
    void *aad_anon, *pt_anon, *ct_anon, *rec_anon;

    void *aad_buf = alloc_dma_buf(&aad_phys, &aad_anon);
    void *pt_buf  = alloc_dma_buf(&pt_phys,  &pt_anon);
    void *ct_buf  = alloc_dma_buf(&ct_phys,  &ct_anon);
    void *rec_buf = alloc_dma_buf(&rec_phys, &rec_anon);

    if (!aad_buf || !pt_buf || !ct_buf || !rec_buf) {
        fprintf(stderr, "  ERROR: DMA buffer allocation failed\n");
        return 1;
    }

    /* ── Print inputs ─────────────────────────────────────────────────── */
    printf("  [ Input ]\n");
    separator();
    print_hex("Key (256-bit):",    KEY,       32);
    print_hex("IV  (96-bit):",     IV,        12);
    print_hex("AAD (16 bytes):",   AAD,       AAD_LEN);
    printf("  %-26s \"%.*s\"\n", "AAD (text):", AAD_LEN, (const char *)AAD);
    print_hex("Plaintext (32 B):", PLAINTEXT, PT_LEN);
    printf("  %-26s \"%.*s\"\n", "Plaintext (text):", PT_LEN, (const char *)PLAINTEXT);
    separator();
    printf("\n");

    /* ── Copy inputs into uncached DMA buffers ────────────────────────── */
    memcpy(aad_buf, AAD,       AAD_LEN);
    memcpy(pt_buf,  PLAINTEXT, PT_LEN);
    memset(ct_buf,  0, PT_LEN);
    memset(rec_buf, 0, PT_LEN);

    /* ════════════════════════════════════════════════════════════════════
     * STEP 1 - ENCRYPTION
     * ════════════════════════════════════════════════════════════════════ */
    printf("  [ Step 1: Encryption ]\n");
    separator();

    crypto_reset();
    crypto_set_key(KEY, 32);
    crypto_set_iv(IV);

    int r = crypto_encrypt(aad_phys, AAD_LEN, pt_phys, PT_LEN, ct_phys);
    if (r != 0) {
        printf("  Encrypt:   FAIL (error %d)\n", r);
        ok = 0;
    } else {
        uint8_t tag[16];
        crypto_get_tag(tag);

        print_hex("Ciphertext (32 B):", (const uint8_t *)ct_buf, PT_LEN);
        print_hex("Auth tag   (16 B):", tag,                      16);
        printf("  Encrypt:   PASS\n");

        /* ══════════════════════════════════════════════════════════════
         * STEP 2 - DECRYPTION  (with correct tag)
         * ══════════════════════════════════════════════════════════════ */
        separator();
        printf("\n  [ Step 2: Decryption with correct tag ]\n");
        separator();

        crypto_reset();
        crypto_set_key(KEY, 32);
        crypto_set_iv(IV);

        r = crypto_decrypt(aad_phys, AAD_LEN, ct_phys, PT_LEN, rec_phys, tag);
        if (r != 0) {
            printf("  Decrypt:   FAIL (error %d)\n", r);
            ok = 0;
        } else {
            print_hex("Recovered  (32 B):", (const uint8_t *)rec_buf, PT_LEN);
            printf("  %-26s \"%.*s\"\n", "Recovered (text):",
                   PT_LEN, (const char *)rec_buf);

            int match = (memcmp(rec_buf, PLAINTEXT, PT_LEN) == 0);
            printf("  Plaintext match:   %s\n", match ? "PASS" : "FAIL");
            printf("  Tag verified:      PASS\n");
            if (!match) ok = 0;
        }

        /* ══════════════════════════════════════════════════════════════
         * STEP 3 - TAMPER TEST  (corrupt one byte, expect rejection)
         * ══════════════════════════════════════════════════════════════ */
        separator();
        printf("\n  [ Step 3: Tamper test (flip ciphertext byte 0) ]\n");
        separator();

        ((uint8_t *)ct_buf)[0] ^= 0xFF;

        crypto_reset();
        crypto_set_key(KEY, 32);
        crypto_set_iv(IV);

        r = crypto_decrypt(aad_phys, AAD_LEN, ct_phys, PT_LEN, rec_phys, tag);
        int rejected = (r == -CRYPTO_ERR_TAG_MISMATCH);
        printf("  Tampered decrypt:  %s\n",
               rejected ? "PASS  (tag mismatch correctly detected)"
                        : "FAIL  (tamper was not caught!)");
        if (!rejected) ok = 0;
    }

    /* ── Final verdict ────────────────────────────────────────────────── */
    separator();
    printf("\n  ============================================================\n");
    printf("  %s\n", ok ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
    printf("  ============================================================\n\n");

    /* ── Cleanup ──────────────────────────────────────────────────────── */
    munmap(aad_buf, BUF_SIZE); munmap(aad_anon, BUF_SIZE);
    munmap(pt_buf,  BUF_SIZE); munmap(pt_anon,  BUF_SIZE);
    munmap(ct_buf,  BUF_SIZE); munmap(ct_anon,  BUF_SIZE);
    munmap(rec_buf, BUF_SIZE); munmap(rec_anon, BUF_SIZE);
    crypto_cleanup();
    return ok ? 0 : 1;
}

/* test_logic.c — host-side unit tests for the CAST-256-GCM driver.
 *
 * Tests error paths, input validation, and register I/O using a mock
 * register array instead of real hardware.  No /dev/mem or ARM required.
 *
 * Build (Linux or MinGW/MSYS2 GCC):
 *   gcc -Wall -Wextra -O2 -DCRYPTO_TEST_BUILD \
 *       -I.. test_logic.c ../crypto_driver.c -o test_logic
 *
 * Run:
 *   ./test_logic
 *
 * All results go to stdout; exits 0 on all-pass, 1 on first failure.
 */

#include "../crypto_driver.h"

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Minimal test framework
 * --------------------------------------------------------------------------*/

static int g_pass = 0;
static int g_fail = 0;

#define EXPECT_EQ(got, want, label) \
    do { \
        int _g = (got), _w = (want); \
        if (_g == _w) { \
            printf("  PASS  %-50s  got %d\n", label, _g); \
            g_pass++; \
        } else { \
            printf("  FAIL  %-50s  want %d, got %d\n", label, _w, _g); \
            g_fail++; \
        } \
    } while (0)

#define EXPECT_NE(got, want, label) \
    do { \
        int _g = (got), _w = (want); \
        if (_g != _w) { \
            printf("  PASS  %-50s  got %d (≠%d)\n", label, _g, _w); \
            g_pass++; \
        } else { \
            printf("  FAIL  %-50s  must not be %d\n", label, _w); \
            g_fail++; \
        } \
    } while (0)

/* ---------------------------------------------------------------------------
 * Mock register bank
 * --------------------------------------------------------------------------*/

/* Must cover at least CRYPTO_MAP_SIZE/4 words (0x1000/4 = 1024) */
static uint32_t mock_regs[1024];

static void mock_reset(void) {
    memset(mock_regs, 0, sizeof(mock_regs));
    crypto_cleanup();                      /* detach any previous mapping   */
    crypto_init_mock(mock_regs);           /* attach fresh mock             */
}

/* Simulate a specific CSR state (e.g. BUSY=1, DONE=1). */
static void mock_set_csr(uint32_t bits) {
    mock_regs[REG_CSR / 4] = bits;
}

/* ---------------------------------------------------------------------------
 * Test groups
 * --------------------------------------------------------------------------*/

static void test_not_init(void) {
    printf("\n--- NOT_INIT checks (before any crypto_init) ---\n");
    crypto_cleanup(); /* ensure no mapping */

    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};
    uint8_t tag[16] = {0};
    uint32_t status = 0;

    EXPECT_EQ(crypto_set_key(key, 16),          -CRYPTO_ERR_NOT_INIT, "set_key before init");
    EXPECT_EQ(crypto_set_iv(iv),                -CRYPTO_ERR_NOT_INIT, "set_iv before init");
    EXPECT_EQ(crypto_encrypt(0,0,0,16,0),       -CRYPTO_ERR_NOT_INIT, "encrypt before init");
    EXPECT_EQ(crypto_decrypt(0,0,0,16,0,tag),   -CRYPTO_ERR_NOT_INIT, "decrypt before init");
    EXPECT_EQ(crypto_get_tag(tag),              -CRYPTO_ERR_NOT_INIT, "get_tag before init");
    EXPECT_EQ(crypto_get_status(&status),       -CRYPTO_ERR_NOT_INIT, "get_status before init");
}

static void test_invalid_key(void) {
    printf("\n--- Key length validation ---\n");
    mock_reset();

    uint8_t key[33] = {0};

    EXPECT_EQ(crypto_set_key(key,  0), -CRYPTO_ERR_INVALID_KEY, "key_len=0  rejected");
    EXPECT_EQ(crypto_set_key(key,  1), -CRYPTO_ERR_INVALID_KEY, "key_len=1  rejected");
    EXPECT_EQ(crypto_set_key(key, 15), -CRYPTO_ERR_INVALID_KEY, "key_len=15 rejected");
    EXPECT_EQ(crypto_set_key(key, 16), 0,                        "key_len=16 accepted");
    EXPECT_EQ(crypto_set_key(key, 17), -CRYPTO_ERR_INVALID_KEY, "key_len=17 rejected");
    EXPECT_EQ(crypto_set_key(key, 24), 0,                        "key_len=24 accepted");
    EXPECT_EQ(crypto_set_key(key, 25), -CRYPTO_ERR_INVALID_KEY, "key_len=25 rejected");
    EXPECT_EQ(crypto_set_key(key, 32), 0,                        "key_len=32 accepted");
    EXPECT_EQ(crypto_set_key(key, 33), -CRYPTO_ERR_INVALID_KEY, "key_len=33 rejected");
}

static void test_busy_at_entry(void) {
    printf("\n--- BUSY rejection at function entry ---\n");
    mock_reset();
    mock_set_csr(CSR_BUSY);

    uint8_t key[16] = {0};
    uint8_t iv[12]  = {0};
    uint8_t tag[16] = {0};

    /* All configuration and operation functions must reject when BUSY=1. */
    EXPECT_EQ(crypto_set_key(key, 16),        -CRYPTO_ERR_BUSY, "set_key busy");
    EXPECT_EQ(crypto_set_iv(iv),              -CRYPTO_ERR_BUSY, "set_iv busy");
    EXPECT_EQ(crypto_encrypt(0,0,0,16,0),     -CRYPTO_ERR_BUSY, "encrypt busy");
    EXPECT_EQ(crypto_decrypt(0,0,0,16,0,tag), -CRYPTO_ERR_BUSY, "decrypt busy");
}

static void test_key_write_pattern(void) {
    printf("\n--- Key register write order and big-endian encoding ---\n");
    mock_reset();

    /* Write a 16-byte key with distinct byte values so we can verify encoding. */
    uint8_t key[32] = {
        0x01, 0x02, 0x03, 0x04,   /* word 0 → 0x01020304 */
        0x05, 0x06, 0x07, 0x08,   /* word 1 → 0x05060708 */
        0x09, 0x0A, 0x0B, 0x0C,   /* word 2 → 0x090A0B0C */
        0x0D, 0x0E, 0x0F, 0x10,   /* word 3 → 0x0D0E0F10 */
        /* remaining 16 bytes zero-padded */
    };

    int r = crypto_set_key(key, 16);
    EXPECT_EQ(r, 0, "set_key returns 0");

    /* Verify big-endian word layout in mock registers. */
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 0], (int)0x01020304, "KEY word 0");
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 1], (int)0x05060708, "KEY word 1");
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 2], (int)0x090A0B0C, "KEY word 2");
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 3], (int)0x0D0E0F10, "KEY word 3");
    /* Zero-padding of remaining words */
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 4], 0, "KEY word 4 (pad)");
    EXPECT_EQ((int)mock_regs[REG_KEY_BASE/4 + 7], 0, "KEY word 7 (pad)");
}

static void test_iv_write_pattern(void) {
    printf("\n--- IV register write order and big-endian encoding ---\n");
    mock_reset();

    uint8_t iv[12] = {
        0xDE, 0xAD, 0xBE, 0xEF,   /* word 0 → 0xDEADBEEF */
        0xCA, 0xFE, 0xBA, 0xBE,   /* word 1 → 0xCAFEBABE */
        0x01, 0x23, 0x45, 0x67,   /* word 2 → 0x01234567 */
    };

    int r = crypto_set_iv(iv);
    EXPECT_EQ(r, 0, "set_iv returns 0");

    EXPECT_EQ((int)mock_regs[REG_IV_BASE/4 + 0], (int)0xDEADBEEF, "IV word 0");
    EXPECT_EQ((int)mock_regs[REG_IV_BASE/4 + 1], (int)0xCAFEBABE, "IV word 1");
    EXPECT_EQ((int)mock_regs[REG_IV_BASE/4 + 2], (int)0x01234567, "IV word 2");
}

static void test_tag_roundtrip(void) {
    printf("\n--- Tag register round-trip (write then read) ---\n");
    mock_reset();

    /* Simulate hardware writing a tag into the tag registers. */
    uint8_t hw_tag[16] = {
        0x11,0x22,0x33,0x44, 0x55,0x66,0x77,0x88,
        0x99,0xAA,0xBB,0xCC, 0xDD,0xEE,0xFF,0x00
    };

    /* Pack the bytes into mock registers manually (big-endian). */
    mock_regs[REG_TAG_BASE/4 + 0] = 0x11223344u;
    mock_regs[REG_TAG_BASE/4 + 1] = 0x55667788u;
    mock_regs[REG_TAG_BASE/4 + 2] = 0x99AABBCCu;
    mock_regs[REG_TAG_BASE/4 + 3] = 0xDDEEFF00u;

    uint8_t out[16] = {0};
    int r = crypto_get_tag(out);
    EXPECT_EQ(r, 0, "get_tag returns 0");
    EXPECT_EQ(memcmp(out, hw_tag, 16), 0, "tag bytes match hardware");

    printf("  tag = ");
    for (int i = 0; i < 16; i++) printf("%02x", out[i]);
    printf("\n");
}

static void test_encrypt_dma_regs(void) {
    printf("\n--- Encrypt: DMA register programming + CSR_START ---\n");
    mock_reset();
    mock_hw_response = CSR_DONE; /* hardware responds: operation complete */

    int r = crypto_encrypt(0xA0000000u, 64, 0xB0000000u, 128, 0xC0000000u);
    EXPECT_EQ(r, 0, "encrypt returns 0");

    EXPECT_EQ((int)mock_regs[REG_AAD_ADDR/4], (int)0xA0000000u, "AAD_ADDR set");
    EXPECT_EQ((int)mock_regs[REG_AAD_LEN /4], 64,               "AAD_LEN set");
    EXPECT_EQ((int)mock_regs[REG_PT_ADDR /4], (int)0xB0000000u, "PT_ADDR set");
    EXPECT_EQ((int)mock_regs[REG_PT_LEN  /4], 128,              "PT_LEN set");
    EXPECT_EQ((int)mock_regs[REG_CT_ADDR /4], (int)0xC0000000u, "CT_ADDR set");
}

static void test_decrypt_tag_mismatch(void) {
    printf("\n--- Decrypt: TAG_VALID not set → TAG_MISMATCH error ---\n");
    mock_reset();
    mock_hw_response = CSR_DONE; /* DONE=1, TAG_VALID=0 → mismatch */

    uint8_t tag[16] = {0};
    int r = crypto_decrypt(0, 0, 0xB0000000u, 16, 0xC0000000u, tag);
    EXPECT_EQ(r, -CRYPTO_ERR_TAG_MISMATCH, "decrypt returns TAG_MISMATCH");
}

static void test_decrypt_tag_valid(void) {
    printf("\n--- Decrypt: TAG_VALID set → success ---\n");
    mock_reset();
    mock_hw_response = CSR_DONE | CSR_TAG_VALID; /* hardware: tag matched */

    uint8_t tag[16] = {0};
    int r = crypto_decrypt(0, 0, 0xB0000000u, 16, 0xC0000000u, tag);
    EXPECT_EQ(r, 0, "decrypt returns 0 when TAG_VALID");
}

static void test_status_readback(void) {
    printf("\n--- get_status: raw CSR readback ---\n");
    mock_reset();

    mock_set_csr(CSR_DONE | CSR_TAG_VALID);

    uint32_t status = 0;
    int r = crypto_get_status(&status);
    EXPECT_EQ(r, 0, "get_status returns 0");
    EXPECT_NE((int)(status & CSR_DONE),      0, "DONE bit visible");
    EXPECT_NE((int)(status & CSR_TAG_VALID), 0, "TAG_VALID bit visible");
    EXPECT_EQ((int)(status & CSR_BUSY),      0, "BUSY bit clear");
}

static void test_reset(void) {
    printf("\n--- reset: CSR_SOFT_RESET is written ---\n");
    mock_reset();

    mock_set_csr(CSR_DONE); /* put something in CSR first */
    crypto_reset();

    /* After reset the driver should have written CSR_SOFT_RESET. */
    EXPECT_EQ((int)(mock_regs[REG_CSR/4] & CSR_SOFT_RESET),
              (int)CSR_SOFT_RESET, "SOFT_RESET written to CSR");
}

/* ---------------------------------------------------------------------------
 * Entry point
 * --------------------------------------------------------------------------*/

int main(void) {
    printf("=== CAST-256-GCM driver logic tests ===\n");
    printf("(mock hardware — no /dev/mem required)\n");

    test_not_init();
    test_invalid_key();
    test_busy_at_entry();
    test_key_write_pattern();
    test_iv_write_pattern();
    test_tag_roundtrip();
    test_encrypt_dma_regs();
    test_decrypt_tag_mismatch();
    test_decrypt_tag_valid();
    test_status_readback();
    test_reset();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}

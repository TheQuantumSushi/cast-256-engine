/* test_e2e.c — end-to-end tests for the driver ↔ hardware interface.
 *
 * Each test calls the public driver API (crypto_set_key, crypto_set_iv,
 * crypto_encrypt, crypto_decrypt, crypto_get_tag) exactly as real
 * application code would.  The hw_model intercepts CSR_START, runs the
 * full CAST-256-GCM computation, and writes results back into the register
 * bank — simulating the complete hardware stack.
 *
 * The gcm_ref C reference is called independently to compute expected
 * values; mismatches are reported with byte-level hex dumps.
 *
 * Tests
 * ─────
 *   T1  Encrypt          — CT and TAG match C reference
 *   T2  Decrypt (valid)  — plaintext recovered, no error
 *   T3  Decrypt (tamper) — one CT byte corrupted → TAG_MISMATCH
 *   T4  Encrypt, AAD=0   — tag-only over plaintext
 *   T5  Encrypt, PT=0    — tag-only over AAD
 *   T6  Sequential       — two encrypts with different IVs are independent
 *
 * Build (see Makefile):
 *   gcc -DCRYPTO_TEST_BUILD -Wall -O2 ...
 */

#include "../crypto_driver.h"
#include "hw_model.h"
#include "gcm_ref.h"

#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* ═══════════════════════════════════════════════════════════════════════════
 * Minimal test framework
 * ═══════════════════════════════════════════════════════════════════════════ */

static int g_pass = 0;
static int g_fail = 0;

#define EXPECT_EQ(got, want, label) \
    do { \
        int _g = (got), _w = (want); \
        if (_g == _w) { \
            printf("  PASS  %-55s  got %d\n", label, _g); \
            g_pass++; \
        } else { \
            printf("  FAIL  %-55s  want %d  got %d\n", label, _w, _g); \
            g_fail++; \
        } \
    } while (0)

static void expect_mem_eq(const uint8_t *got, const uint8_t *want,
                          size_t len, const char *label)
{
    if (memcmp(got, want, len) == 0) {
        printf("  PASS  %-55s\n", label);
        g_pass++;
        return;
    }
    printf("  FAIL  %s\n", label);
    printf("        want: ");
    for (size_t i = 0; i < len; i++) printf("%02x", want[i]);
    printf("\n        got : ");
    for (size_t i = 0; i < len; i++) printf("%02x", got[i]);
    printf("\n");
    g_fail++;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Shared test fixtures
 * ═══════════════════════════════════════════════════════════════════════════ */

/* Mock register bank shared across all tests. */
static uint32_t mock_regs[1024];

/* RFC 2612 256-bit test key (same as tb_gcm.vhd). */
static const uint8_t KEY[32] = {
    0x23,0x42,0xbb,0x9e, 0xfa,0x38,0x54,0x2c,
    0xbe,0xd0,0xac,0x83, 0x94,0x0a,0xc2,0x98,
    0x8d,0x7c,0x47,0xce, 0x26,0x49,0x08,0x46,
    0x1c,0xc1,0xb5,0x13, 0x7a,0xe6,0xb6,0x04
};

/* 96-bit IV (same as tb_gcm.vhd). */
static const uint8_t IV[12] = {
    0xca,0xfe,0xba,0xbe, 0x12,0x34,0x56,0x78, 0x00,0x00,0x00,0x01
};

/* A second IV for sequential-operation tests. */
static const uint8_t IV2[12] = {
    0xde,0xad,0xbe,0xef, 0x00,0x11,0x22,0x33, 0x44,0x55,0x66,0x77
};

/* 1-block AAD (same as tb_gcm.vhd). */
static const uint8_t AAD[16] = {
    0x00,0x01,0x02,0x03, 0x04,0x05,0x06,0x07,
    0x08,0x09,0x0a,0x0b, 0x0c,0x0d,0x0e,0x0f
};

/* 2-block plaintext (same as tb_gcm.vhd). */
static const uint8_t PT[32] = {
    0x10,0x11,0x12,0x13, 0x14,0x15,0x16,0x17,
    0x18,0x19,0x1a,0x1b, 0x1c,0x1d,0x1e,0x1f,
    0x20,0x21,0x22,0x23, 0x24,0x25,0x26,0x27,
    0x28,0x29,0x2a,0x2b, 0x2c,0x2d,0x2e,0x2f
};

/* Fake physical addresses (arbitrary non-zero, non-overlapping values). */
#define PHYS_AAD  0x10000000u
#define PHYS_PT   0x20000000u
#define PHYS_CT   0x30000000u
#define PHYS_PT2  0x40000000u  /* second set for T6 */
#define PHYS_CT2  0x50000000u

/* Reset everything between tests. */
static void test_reset(void)
{
    memset(mock_regs, 0, sizeof(mock_regs));
    crypto_cleanup();
    crypto_init_mock(mock_regs);
    crypto_set_hw_hook(hw_model_hook);
    hw_model_reset();
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T1 — Encrypt: CT and TAG match C reference
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_encrypt_vs_ref(void)
{
    printf("\n--- T1  Encrypt: CT and TAG match C GCM reference ---\n");
    test_reset();

    uint8_t aad_buf[16];  memcpy(aad_buf, AAD, 16);
    uint8_t pt_buf[32];   memcpy(pt_buf,  PT,  32);
    uint8_t ct_buf[32];   memset(ct_buf, 0, 32);

    hw_model_map(PHYS_AAD, aad_buf, sizeof(aad_buf));
    hw_model_map(PHYS_PT,  pt_buf,  sizeof(pt_buf));
    hw_model_map(PHYS_CT,  ct_buf,  sizeof(ct_buf));

    /* Compute expected values independently using the C reference. */
    uint8_t exp_ct[32], exp_tag[16];
    gcm_encrypt(KEY, 32, IV, AAD, 16, PT, 32, exp_ct, exp_tag);

    /* Run the driver. */
    EXPECT_EQ(crypto_set_key(KEY, 32),                               0, "set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),                                     0, "set_iv ok");
    EXPECT_EQ(crypto_encrypt(PHYS_AAD, 16, PHYS_PT, 32, PHYS_CT),   0, "encrypt ok");

    uint8_t tag_out[16];
    EXPECT_EQ(crypto_get_tag(tag_out), 0, "get_tag ok");

    /* Verify against reference. */
    expect_mem_eq(ct_buf,  exp_ct,  32, "CT  matches C reference");
    expect_mem_eq(tag_out, exp_tag, 16, "TAG matches C reference");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T2 — Decrypt valid: plaintext recovered correctly
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_decrypt_valid(void)
{
    printf("\n--- T2  Decrypt (valid): plaintext recovered ---\n");
    test_reset();

    /* First, produce the ciphertext using the C reference directly
     * (not through the driver — we are testing decrypt here). */
    uint8_t ct_buf[32];
    uint8_t ref_tag[16];
    gcm_encrypt(KEY, 32, IV, AAD, 16, PT, 32, ct_buf, ref_tag);

    uint8_t aad_buf[16]; memcpy(aad_buf, AAD, 16);
    uint8_t pt_out[32];  memset(pt_out, 0, 32);

    /* For decrypt the driver maps: PT_ADDR → ciphertext input,
     *                               CT_ADDR → plaintext output.   */
    hw_model_map(PHYS_AAD, aad_buf, 16);
    hw_model_map(PHYS_PT,  ct_buf,  32);   /* CT is the "input" */
    hw_model_map(PHYS_CT,  pt_out,  32);   /* PT is the "output" */

    EXPECT_EQ(crypto_set_key(KEY, 32), 0, "set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),       0, "set_iv ok");
    int r = crypto_decrypt(PHYS_AAD, 16, PHYS_PT, 32, PHYS_CT, ref_tag);
    EXPECT_EQ(r, 0, "decrypt returns 0 (tag valid)");

    expect_mem_eq(pt_out, PT, 32, "recovered PT matches original");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T3 — Decrypt tampered: tag mismatch detected
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_decrypt_tamper(void)
{
    printf("\n--- T3  Decrypt (tamper): CRYPTO_ERR_TAG_MISMATCH returned ---\n");
    test_reset();

    uint8_t ct_buf[32];
    uint8_t ref_tag[16];
    gcm_encrypt(KEY, 32, IV, AAD, 16, PT, 32, ct_buf, ref_tag);

    /* Corrupt one byte of the ciphertext. */
    ct_buf[7] ^= 0xFF;

    uint8_t aad_buf[16]; memcpy(aad_buf, AAD, 16);
    uint8_t pt_out[32];  memset(pt_out, 0, 32);

    hw_model_map(PHYS_AAD, aad_buf, 16);
    hw_model_map(PHYS_PT,  ct_buf,  32);
    hw_model_map(PHYS_CT,  pt_out,  32);

    EXPECT_EQ(crypto_set_key(KEY, 32), 0, "set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),       0, "set_iv ok");
    int r = crypto_decrypt(PHYS_AAD, 16, PHYS_PT, 32, PHYS_CT, ref_tag);
    EXPECT_EQ(r, -CRYPTO_ERR_TAG_MISMATCH, "tampered CT → TAG_MISMATCH");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T4 — Encrypt with AAD = 0 bytes
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_encrypt_no_aad(void)
{
    printf("\n--- T4  Encrypt with zero AAD ---\n");
    test_reset();

    uint8_t pt_buf[32];  memcpy(pt_buf, PT, 32);
    uint8_t ct_buf[32];  memset(ct_buf, 0, 32);

    /* No AAD mapping needed — length is 0. */
    hw_model_map(PHYS_PT, pt_buf, 32);
    hw_model_map(PHYS_CT, ct_buf, 32);

    uint8_t exp_ct[32], exp_tag[16];
    gcm_encrypt(KEY, 32, IV, NULL, 0, PT, 32, exp_ct, exp_tag);

    EXPECT_EQ(crypto_set_key(KEY, 32), 0, "set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),       0, "set_iv ok");
    /* aad_phys / aad_len = 0 → hardware ignores AAD phase. */
    EXPECT_EQ(crypto_encrypt(0, 0, PHYS_PT, 32, PHYS_CT), 0, "encrypt ok");

    uint8_t tag_out[16];
    EXPECT_EQ(crypto_get_tag(tag_out), 0, "get_tag ok");

    expect_mem_eq(ct_buf,  exp_ct,  32, "CT  matches no-AAD reference");
    expect_mem_eq(tag_out, exp_tag, 16, "TAG matches no-AAD reference");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T5 — Encrypt with PT = 0 bytes (authentication-only)
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_encrypt_no_pt(void)
{
    printf("\n--- T5  Encrypt with zero PT (auth-only) ---\n");
    test_reset();

    uint8_t aad_buf[16]; memcpy(aad_buf, AAD, 16);
    hw_model_map(PHYS_AAD, aad_buf, 16);
    /* No PT or CT mapping needed — lengths are 0. */

    uint8_t exp_tag[16];
    gcm_encrypt(KEY, 32, IV, AAD, 16, NULL, 0, NULL, exp_tag);

    EXPECT_EQ(crypto_set_key(KEY, 32), 0, "set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),       0, "set_iv ok");
    EXPECT_EQ(crypto_encrypt(PHYS_AAD, 16, 0, 0, 0), 0, "encrypt ok");

    uint8_t tag_out[16];
    EXPECT_EQ(crypto_get_tag(tag_out), 0, "get_tag ok");
    expect_mem_eq(tag_out, exp_tag, 16, "TAG matches auth-only reference");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * T6 — Sequential operations: two encrypts with different IVs are independent
 * ═══════════════════════════════════════════════════════════════════════════ */
static void test_sequential_ops(void)
{
    printf("\n--- T6  Sequential encrypts (different IVs) are independent ---\n");
    test_reset();

    uint8_t aad1[16]; memcpy(aad1, AAD, 16);
    uint8_t pt1[32];  memcpy(pt1,  PT,  32);
    uint8_t ct1[32];  memset(ct1,  0,   32);

    uint8_t aad2[16]; memcpy(aad2, AAD, 16);
    uint8_t pt2[32];  memcpy(pt2,  PT,  32);
    uint8_t ct2[32];  memset(ct2,  0,   32);

    hw_model_map(PHYS_AAD,  aad1, 16);
    hw_model_map(PHYS_PT,   pt1,  32);
    hw_model_map(PHYS_CT,   ct1,  32);
    hw_model_map(PHYS_PT2,  pt2,  32);
    hw_model_map(PHYS_CT2,  ct2,  32);

    uint8_t exp_ct1[32], exp_tag1[16];
    uint8_t exp_ct2[32], exp_tag2[16];
    gcm_encrypt(KEY, 32, IV,  AAD, 16, PT, 32, exp_ct1, exp_tag1);
    gcm_encrypt(KEY, 32, IV2, AAD, 16, PT, 32, exp_ct2, exp_tag2);

    /* ── First encrypt (IV1) ── */
    EXPECT_EQ(crypto_set_key(KEY, 32), 0, "op1: set_key ok");
    EXPECT_EQ(crypto_set_iv(IV),       0, "op1: set_iv ok");
    EXPECT_EQ(crypto_encrypt(PHYS_AAD, 16, PHYS_PT, 32, PHYS_CT), 0, "op1: encrypt ok");
    uint8_t tag1[16];
    EXPECT_EQ(crypto_get_tag(tag1), 0, "op1: get_tag ok");
    expect_mem_eq(ct1,  exp_ct1,  32, "op1: CT  matches reference");
    expect_mem_eq(tag1, exp_tag1, 16, "op1: TAG matches reference");

    /* ── Second encrypt (IV2) — reuses same key, different IV ── */
    EXPECT_EQ(crypto_set_iv(IV2),  0, "op2: set_iv ok");
    EXPECT_EQ(crypto_encrypt(PHYS_AAD, 16, PHYS_PT2, 32, PHYS_CT2), 0, "op2: encrypt ok");
    uint8_t tag2[16];
    EXPECT_EQ(crypto_get_tag(tag2), 0, "op2: get_tag ok");
    expect_mem_eq(ct2,  exp_ct2,  32, "op2: CT  matches reference");
    expect_mem_eq(tag2, exp_tag2, 16, "op2: TAG matches reference");

    /* The two ciphertexts must differ (different IVs → different keystreams). */
    int same = (memcmp(ct1, ct2, 32) == 0);
    EXPECT_EQ(same, 0, "op1 and op2 produce distinct CTs");
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Entry point
 * ═══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    printf("=== Driver ↔ Hardware model end-to-end tests ===\n");
    printf("(CAST-256-GCM, 256-bit key, software hardware model)\n");

    test_encrypt_vs_ref();
    test_decrypt_valid();
    test_decrypt_tamper();
    test_encrypt_no_aad();
    test_encrypt_no_pt();
    test_sequential_ops();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}

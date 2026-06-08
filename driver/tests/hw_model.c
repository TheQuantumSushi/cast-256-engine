/* hw_model.c - software model of the CAST-256-GCM hardware accelerator.
 *
 * See hw_model.h for the design rationale.
 *
 * Register semantics replicated from the hardware:
 *
 *   ENCRYPT (CSR_MODE = 0):
 *     Inputs  : key_reg, iv_reg, AAD_ADDR/LEN, PT_ADDR/LEN, CT_ADDR
 *     Outputs : CT written to CT_ADDR buffer, TAG written to tag_reg,
 *               CT_LEN written to REG_CT_LEN, CSR = CSR_DONE.
 *
 *   DECRYPT (CSR_MODE = 1):
 *     Inputs  : key_reg, iv_reg, AAD_ADDR/LEN,
 *               PT_ADDR/LEN  - ciphertext (driver maps CT here),
 *               CT_ADDR      - plaintext output (driver maps PT here),
 *               tag_reg      - expected tag (written by driver before START).
 *     Outputs : plaintext written to CT_ADDR buffer,
 *               CSR = CSR_DONE | CSR_TAG_VALID  (tag OK)
 *               CSR = CSR_DONE                  (tag mismatch).
 *
 *   Any unmapped physical address -> CSR = CSR_ERROR.
 */

#include "hw_model.h"
#include "gcm_ref.h"      /* gcm_encrypt, gcm_decrypt */
#include "crypto_regs.h"  /* register offsets and CSR bits */

#include <string.h>
#include <stdint.h>
#include <stddef.h>

/* -------------------------------------------------------------------------
 * Memory mapping table
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t phys;
    uint8_t *ptr;
    size_t   len;
    int      valid;
} region_t;

static region_t regions[HW_MODEL_MAX_REGIONS];

void hw_model_map(uint32_t phys_addr, void *buf, size_t len)
{
    /* Replace existing entry with the same address if present. */
    for (int i = 0; i < HW_MODEL_MAX_REGIONS; i++) {
        if (regions[i].valid && regions[i].phys == phys_addr) {
            regions[i].ptr = (uint8_t *)buf;
            regions[i].len = len;
            return;
        }
    }
    /* Find a free slot. */
    for (int i = 0; i < HW_MODEL_MAX_REGIONS; i++) {
        if (!regions[i].valid) {
            regions[i].phys  = phys_addr;
            regions[i].ptr   = (uint8_t *)buf;
            regions[i].len   = len;
            regions[i].valid = 1;
            return;
        }
    }
    /* Table full - callers must not exceed HW_MODEL_MAX_REGIONS. */
}

void hw_model_reset(void)
{
    memset(regions, 0, sizeof(regions));
}

/* Resolve a physical address to a real pointer.
 *
 * Args :
 *   - phys [uint32_t] : physical address to look up
 *   - len  [size_t]   : required byte count
 *
 * Returns :
 *   - [uint8_t *] : real pointer, or NULL if not mapped or region too small
 */
static uint8_t *lookup(uint32_t phys, size_t len)
{
    if (len == 0) return (uint8_t *)"";   /* any non-NULL sentinel */
    for (int i = 0; i < HW_MODEL_MAX_REGIONS; i++) {
        if (regions[i].valid &&
            regions[i].phys == phys &&
            regions[i].len  >= len)
            return regions[i].ptr;
    }
    return NULL;
}

/* -------------------------------------------------------------------------
 * Register extraction helpers (big-endian words <-> byte arrays)
 * ------------------------------------------------------------------------- */

/* Unpack n_words big-endian 32-bit register words into a byte array.
 *
 * Args :
 *   - regs        [const volatile uint32_t *] : register array
 *   - base_offset [unsigned]                  : byte offset of the first word
 *   - n_words     [size_t]                    : number of 32-bit words to read
 *   - out         [uint8_t *]                 : destination byte array (4*n_words bytes)
 */
static void reg_to_bytes(const volatile uint32_t *regs,
                         unsigned base_offset, size_t n_words,
                         uint8_t *out)
{
    for (size_t i = 0; i < n_words; i++) {
        uint32_t w = regs[(base_offset / 4) + i];
        out[4*i    ] = (uint8_t)(w >> 24);
        out[4*i + 1] = (uint8_t)(w >> 16);
        out[4*i + 2] = (uint8_t)(w >>  8);
        out[4*i + 3] = (uint8_t)(w      );
    }
}

/* Pack a byte array into n_words big-endian 32-bit register words.
 *
 * Args :
 *   - regs        [volatile uint32_t *] : register array
 *   - base_offset [unsigned]            : byte offset of the first word
 *   - n_words     [size_t]              : number of 32-bit words to write
 *   - in          [const uint8_t *]     : source byte array (4*n_words bytes)
 */
static void bytes_to_reg(volatile uint32_t *regs,
                         unsigned base_offset, size_t n_words,
                         const uint8_t *in)
{
    for (size_t i = 0; i < n_words; i++) {
        regs[(base_offset / 4) + i] =
            ((uint32_t)in[4*i    ] << 24) |
            ((uint32_t)in[4*i + 1] << 16) |
            ((uint32_t)in[4*i + 2] <<  8) |
             (uint32_t)in[4*i + 3];
    }
}

/* -------------------------------------------------------------------------
 * Main hook
 * ------------------------------------------------------------------------- */

void hw_model_hook(volatile uint32_t *regs)
{
    /* ── Extract parameters from the register bank ── */

    uint8_t key[32], iv[12];
    reg_to_bytes(regs, REG_KEY_BASE, 8, key);   /* 256-bit key */
    reg_to_bytes(regs, REG_IV_BASE,  3, iv);    /* 96-bit IV   */

    uint32_t csr      = regs[REG_CSR      / 4];
    uint32_t aad_phys = regs[REG_AAD_ADDR / 4];
    uint32_t aad_len  = regs[REG_AAD_LEN  / 4];
    uint32_t pt_phys  = regs[REG_PT_ADDR  / 4];
    uint32_t pt_len   = regs[REG_PT_LEN   / 4];
    uint32_t ct_phys  = regs[REG_CT_ADDR  / 4];
    int      decrypt  = (csr & CSR_MODE) != 0;

    /* ── Resolve physical addresses → real pointers ── */

    uint8_t *aad_ptr = lookup(aad_phys, aad_len);
    uint8_t *pt_ptr  = lookup(pt_phys,  pt_len);
    uint8_t *ct_ptr  = lookup(ct_phys,  pt_len);

    if ((aad_len > 0 && !aad_ptr) ||
        (pt_len  > 0 && (!pt_ptr || !ct_ptr))) {
        regs[REG_CSR / 4] = CSR_ERROR;
        return;
    }

    /* ── Run the cryptographic operation ── */

    if (!decrypt) {
        /* ENCRYPT */
        uint8_t tag[16];
        gcm_encrypt(key, 32, iv,
                    aad_ptr, aad_len,
                    pt_ptr,  pt_len,
                    ct_ptr,                 /* CT written directly to mapped buf */
                    tag);

        regs[REG_CT_LEN / 4] = pt_len;     /* hardware reports output length */
        bytes_to_reg(regs, REG_TAG_BASE, 4, tag);
        regs[REG_CSR / 4] = CSR_DONE;

    } else {
        /* DECRYPT
         * Driver convention (crypto_driver.c):
         *   REG_PT_ADDR / REG_PT_LEN → ciphertext input
         *   REG_CT_ADDR              → plaintext output
         * REG_TAG_BASE holds the expected tag, written by driver before START. */
        uint8_t expected_tag[16];
        reg_to_bytes(regs, REG_TAG_BASE, 4, expected_tag);

        int ok = gcm_decrypt(key, 32, iv,
                             aad_ptr, aad_len,
                             pt_ptr,  pt_len,  /* pt_ptr = ciphertext input */
                             expected_tag,
                             ct_ptr);          /* ct_ptr = plaintext output */

        uint32_t result = CSR_DONE;
        if (ok == 0) result |= CSR_TAG_VALID;
        regs[REG_CSR / 4] = result;
    }
}

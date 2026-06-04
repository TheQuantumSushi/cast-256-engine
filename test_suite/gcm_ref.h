/* gcm_ref.h — CAST-256-GCM reference implementation.
 *
 * Implements GCM as specified in NIST SP 800-38D using cast.c as the
 * underlying block cipher.  Restrictions (matching the hardware):
 *   - 96-bit (12-byte) IV
 *   - AAD and plaintext lengths must be multiples of 16 bytes (or 0)
 *   - 256-bit key (cast.c also supports 128/192 — key_len in bytes)
 *
 * Not reentrant: cast.c uses a global key schedule.
 */

#ifndef GCM_REF_H
#define GCM_REF_H

#include <stddef.h>
#include <stdint.h>

/* GCM authenticated encryption.
 *
 * key / key_len : 16, 24, or 32 bytes.
 * iv            : exactly 12 bytes (96-bit IV).
 * aad / aad_len : additional authenticated data; aad_len must be a
 *                 multiple of 16 (may be 0).
 * pt  / pt_len  : plaintext; pt_len must be a multiple of 16 (may be 0).
 * ct_out        : output ciphertext (caller allocates pt_len bytes).
 * tag_out       : 16-byte authentication tag.
 */
void gcm_encrypt(const uint8_t *key,  size_t key_len,
                 const uint8_t  iv[12],
                 const uint8_t *aad,  size_t aad_len,
                 const uint8_t *pt,   size_t pt_len,
                 uint8_t       *ct_out,
                 uint8_t        tag_out[16]);

/* GCM authenticated decryption.
 *
 * Returns  0 if authentication passes (tag matches).
 * Returns -1 if the computed tag does not match expected_tag.
 * pt_out is written even on tag mismatch (caller must discard it).
 */
int gcm_decrypt(const uint8_t *key,  size_t key_len,
                const uint8_t  iv[12],
                const uint8_t *aad,  size_t aad_len,
                const uint8_t *ct,   size_t ct_len,
                const uint8_t  expected_tag[16],
                uint8_t       *pt_out);

#endif /* GCM_REF_H */

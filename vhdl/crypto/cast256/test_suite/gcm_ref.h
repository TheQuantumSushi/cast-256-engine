/* gcm_ref.h - CAST-256-GCM reference implementation.
 *
 * Implements GCM as specified in NIST SP 800-38D using cast.c as the
 * underlying block cipher.  Restrictions (matching the hardware):
 *   - 96-bit (12-byte) IV
 *   - AAD and plaintext lengths must be multiples of 16 bytes (or 0)
 *   - 256-bit key (cast.c also supports 128/192 - key_len in bytes)
 *
 * Not reentrant: cast.c uses a global key schedule.
 */

#ifndef GCM_REF_H
#define GCM_REF_H

#include <stddef.h>
#include <stdint.h>

/* GCM authenticated encryption (NIST SP 800-38D).
 *
 * Args :
 *   - key     [const uint8_t *] : key bytes (16, 24, or 32)
 *   - key_len [size_t]          : key length in bytes
 *   - iv      [const uint8_t[12]] : 96-bit IV (exactly 12 bytes)
 *   - aad     [const uint8_t *] : additional authenticated data (may be NULL if aad_len=0)
 *   - aad_len [size_t]          : AAD length in bytes (multiple of 16)
 *   - pt      [const uint8_t *] : plaintext (may be NULL if pt_len=0)
 *   - pt_len  [size_t]          : plaintext length in bytes (multiple of 16)
 *   - ct_out  [uint8_t *]       : output ciphertext buffer (caller allocates pt_len bytes)
 *   - tag_out [uint8_t[16]]     : output 16-byte authentication tag
 */
void gcm_encrypt(const uint8_t *key,  size_t key_len,
                 const uint8_t  iv[12],
                 const uint8_t *aad,  size_t aad_len,
                 const uint8_t *pt,   size_t pt_len,
                 uint8_t       *ct_out,
                 uint8_t        tag_out[16]);

/* GCM authenticated decryption (NIST SP 800-38D).
 * pt_out is written even on tag mismatch; caller must discard it on failure.
 *
 * Args :
 *   - key          [const uint8_t *]   : key bytes (16, 24, or 32)
 *   - key_len      [size_t]            : key length in bytes
 *   - iv           [const uint8_t[12]] : 96-bit IV (exactly 12 bytes)
 *   - aad          [const uint8_t *]   : additional authenticated data
 *   - aad_len      [size_t]            : AAD length in bytes (multiple of 16)
 *   - ct           [const uint8_t *]   : ciphertext input
 *   - ct_len       [size_t]            : ciphertext length in bytes (multiple of 16)
 *   - expected_tag [const uint8_t[16]] : 16-byte tag to verify
 *   - pt_out       [uint8_t *]         : output plaintext buffer (caller allocates ct_len bytes)
 *
 * Returns :
 *   - [int] : 0 if tag matches, -1 on tag mismatch
 */
int gcm_decrypt(const uint8_t *key,  size_t key_len,
                const uint8_t  iv[12],
                const uint8_t *aad,  size_t aad_len,
                const uint8_t *ct,   size_t ct_len,
                const uint8_t  expected_tag[16],
                uint8_t       *pt_out);

#endif /* GCM_REF_H */

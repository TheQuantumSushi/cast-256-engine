/* gcm_ref.c — CAST-256-GCM reference implementation (NIST SP 800-38D).
 *
 * Block cipher: cast.c by Brian Gladman (set_key / encrypt).
 * GF(2^128) reduction polynomial: x^128 + x^7 + x^2 + x + 1
 *   → R = 0xE1000000000000000000000000000000  (matches gcm_pkg.vhd).
 * Counter: inc32 increments the rightmost 32 bits (matches gcm_pkg.vhd).
 *
 * All lengths are in bytes and must be multiples of 16 (hardware constraint).
 * Bit ordering follows the GCM standard: bit 0 of a string is the MSB of
 * its first byte.
 */

#include "gcm_ref.h"

#include <string.h>
#include <stdint.h>

/* cast.c uses 'unsigned long' as its 32-bit word type (u4byte in std_defs.h).
 * On Windows (MinGW/MSVC, LLP64) unsigned long is 32 bits.
 * We declare the two functions we need without pulling in std_defs.h, whose
 * "../std_defs.h" relative include requires a specific directory layout. */
typedef unsigned long cast_u4;
extern cast_u4 *set_key(const cast_u4 in_key[], const cast_u4 key_len);
extern void     encrypt(const cast_u4 in_blk[4], cast_u4 out_blk[4]);

/* -------------------------------------------------------------------------
 * Block cipher wrapper: 16-byte big-endian arrays ↔ cast.c u4byte words.
 * cast.c is compiled with BYTE_SWAP, so its public interface uses
 * big-endian 32-bit words (it byte-swaps to little-endian internally).
 * ------------------------------------------------------------------------- */

static void bc_set_key(const uint8_t *key, size_t key_len_bytes)
{
    cast_u4 kw[8] = {0};
    size_t nw = key_len_bytes / 4;
    for (size_t i = 0; i < nw; i++)
        kw[i] = ((cast_u4)key[4*i  ] << 24) | ((cast_u4)key[4*i+1] << 16)
              | ((cast_u4)key[4*i+2] <<  8) |  (cast_u4)key[4*i+3];
    set_key(kw, (cast_u4)(key_len_bytes * 8));
}

static void bc_encrypt(const uint8_t in[16], uint8_t out[16])
{
    cast_u4 iw[4], ow[4];
    for (int i = 0; i < 4; i++)
        iw[i] = ((cast_u4)in[4*i  ] << 24) | ((cast_u4)in[4*i+1] << 16)
              | ((cast_u4)in[4*i+2] <<  8) |  (cast_u4)in[4*i+3];
    encrypt(iw, ow);
    for (int i = 0; i < 4; i++) {
        out[4*i  ] = (uint8_t)(ow[i] >> 24);
        out[4*i+1] = (uint8_t)(ow[i] >> 16);
        out[4*i+2] = (uint8_t)(ow[i] >>  8);
        out[4*i+3] = (uint8_t)(ow[i]      );
    }
}

/* -------------------------------------------------------------------------
 * GF(2^128) arithmetic — NIST SP 800-38D §6.3 bit convention:
 *   bit 0 of the field element = MSB of byte[0]
 *   bit 127                    = LSB of byte[15]
 * ------------------------------------------------------------------------- */

/* Right-shift the 128-bit value in v[] by one position.
 * Bit 0 (MSB of v[0]) becomes 0; bit 127 (LSB of v[15]) falls off. */
static void gf128_shr(uint8_t v[16])
{
    uint8_t carry = 0;
    for (int i = 0; i < 16; i++) {
        uint8_t new_carry = (v[i] & 1u) << 7;
        v[i] = (v[i] >> 1) | carry;
        carry = new_carry;
    }
}

/* Multiply X · Y in GF(2^128) using reduction polynomial R = 0xE1||0^120. */
static void gf128_mul(const uint8_t X[16], const uint8_t Y[16], uint8_t Z[16])
{
    uint8_t V[16];
    memcpy(V, X, 16);
    memset(Z, 0, 16);

    for (int i = 0; i < 128; i++) {
        /* y_i: bit i of Y, where i=0 is the MSB of Y[0]. */
        int y_i = (Y[i / 8] >> (7 - (i % 8))) & 1;
        if (y_i) {
            for (int j = 0; j < 16; j++) Z[j] ^= V[j];
        }
        int v127 = V[15] & 1;   /* rightmost bit of V before shifting */
        gf128_shr(V);
        if (v127) V[0] ^= 0xE1; /* XOR R = 0xE1 || 0^120 */
    }
}

/* -------------------------------------------------------------------------
 * GHASH_H(X)  (NIST §6.4 Algorithm 2)
 * Processes n_blocks × 16 bytes; caller ensures len is a multiple of 16.
 * Y_out must be initialised by the caller (pass 0^128 for fresh GHASH).
 * ------------------------------------------------------------------------- */
static void ghash_update(const uint8_t H[16],
                         const uint8_t *X, size_t len,
                         uint8_t Y[16])
{
    for (size_t i = 0; i < len; i += 16) {
        uint8_t tmp[16];
        for (int j = 0; j < 16; j++) tmp[j] = Y[j] ^ X[i + j];
        gf128_mul(tmp, H, Y);
    }
}

/* -------------------------------------------------------------------------
 * inc32: increment the rightmost 32 bits of a 128-bit counter.
 * Matches inc32() in gcm_pkg.vhd: blk[31:0] + 1, upper bits unchanged.
 * ------------------------------------------------------------------------- */
static void inc32(uint8_t blk[16])
{
    for (int i = 15; i >= 12; i--) {
        if (++blk[i] != 0) break;
    }
}

/* -------------------------------------------------------------------------
 * GCTR(K, ICB, X) — counter-mode encryption/decryption.
 * len must be a multiple of 16 (hardware constraint).
 * in and out may alias.
 * ------------------------------------------------------------------------- */
static void gctr(const uint8_t ICB[16],
                 const uint8_t *in, size_t len, uint8_t *out)
{
    uint8_t CB[16];
    memcpy(CB, ICB, 16);
    for (size_t i = 0; i < len; i += 16) {
        uint8_t O[16];
        bc_encrypt(CB, O);
        for (int j = 0; j < 16; j++) out[i + j] = in[i + j] ^ O[j];
        inc32(CB);
    }
}

/* -------------------------------------------------------------------------
 * Build the 16-byte length block: [len_A_bits]_64 || [len_C_bits]_64
 * (big-endian 64-bit integers, NIST §6.4).
 * ------------------------------------------------------------------------- */
static void build_len_block(size_t aad_len, size_t ct_len, uint8_t lb[16])
{
    uint64_t la = (uint64_t)aad_len * 8;
    uint64_t lc = (uint64_t)ct_len  * 8;
    for (int i = 0; i < 8; i++) {
        lb[i    ] = (uint8_t)(la >> (56 - 8 * i));
        lb[8 + i] = (uint8_t)(lc >> (56 - 8 * i));
    }
}

/* =========================================================================
 * Public API
 * ========================================================================= */

void gcm_encrypt(const uint8_t *key,  size_t key_len,
                 const uint8_t  iv[12],
                 const uint8_t *aad,  size_t aad_len,
                 const uint8_t *pt,   size_t pt_len,
                 uint8_t       *ct_out,
                 uint8_t        tag_out[16])
{
    /* 1. Load key and compute H = BC(K, 0^128). */
    bc_set_key(key, key_len);
    uint8_t H[16] = {0};
    bc_encrypt(H, H);

    /* 2. J0 = IV || 0^31 || 1  (96-bit IV → 128-bit counter). */
    uint8_t J0[16];
    memcpy(J0, iv, 12);
    J0[12] = 0; J0[13] = 0; J0[14] = 0; J0[15] = 1;

    /* 3. CT = GCTR(K, inc32(J0), PT). */
    uint8_t CB1[16];
    memcpy(CB1, J0, 16);
    inc32(CB1);
    gctr(CB1, pt, pt_len, ct_out);

    /* 4. S = GHASH_H(A || C || len(A)||len(C)). */
    uint8_t S[16] = {0};
    if (aad_len > 0) ghash_update(H, aad, aad_len, S);
    if (pt_len  > 0) ghash_update(H, ct_out, pt_len, S);
    uint8_t lb[16];
    build_len_block(aad_len, pt_len, lb);
    ghash_update(H, lb, 16, S);

    /* 5. T = MSB_128(GCTR(K, J0, S)). */
    gctr(J0, S, 16, tag_out);
}

int gcm_decrypt(const uint8_t *key,  size_t key_len,
                const uint8_t  iv[12],
                const uint8_t *aad,  size_t aad_len,
                const uint8_t *ct,   size_t ct_len,
                const uint8_t  expected_tag[16],
                uint8_t       *pt_out)
{
    /* 1. Load key and compute H. */
    bc_set_key(key, key_len);
    uint8_t H[16] = {0};
    bc_encrypt(H, H);

    /* 2. J0. */
    uint8_t J0[16];
    memcpy(J0, iv, 12);
    J0[12] = 0; J0[13] = 0; J0[14] = 0; J0[15] = 1;

    /* 3. PT = GCTR(K, inc32(J0), CT). */
    uint8_t CB1[16];
    memcpy(CB1, J0, 16);
    inc32(CB1);
    gctr(CB1, ct, ct_len, pt_out);

    /* 4. S = GHASH_H(A || CT || len). */
    uint8_t S[16] = {0};
    if (aad_len > 0) ghash_update(H, aad, aad_len, S);
    if (ct_len  > 0) ghash_update(H, ct,  ct_len,  S);
    uint8_t lb[16];
    build_len_block(aad_len, ct_len, lb);
    ghash_update(H, lb, 16, S);

    /* 5. T = MSB_128(GCTR(K, J0, S)). */
    uint8_t tag[16];
    gctr(J0, S, 16, tag);

    /* 6. Constant-time tag comparison. */
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= tag[i] ^ expected_tag[i];
    return diff ? -1 : 0;
}

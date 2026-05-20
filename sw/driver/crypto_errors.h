/* crypto_errors.h — driver error codes.
 *
 * All driver functions return 0 on success and the negative of one of these
 * codes on failure (e.g. -CRYPTO_ERR_BUSY).
 */

#ifndef CRYPTO_ERRORS_H
#define CRYPTO_ERRORS_H

#define CRYPTO_ERR_MEM_OPEN     1  /* open("/dev/mem") failed                  */
#define CRYPTO_ERR_MMAP         2  /* mmap failed                              */
#define CRYPTO_ERR_BUSY         3  /* hardware busy at function entry          */
#define CRYPTO_ERR_INVALID_KEY  4  /* key_len ∉ {16, 24, 32}                  */
#define CRYPTO_ERR_TIMEOUT      5  /* polling deadline exceeded                */
#define CRYPTO_ERR_AXI          6  /* DMA bus error (BRESP/RRESP ≠ 00)        */
#define CRYPTO_ERR_TAG_MISMATCH 7  /* decrypt authentication tag mismatch     */
#define CRYPTO_ERR_NOT_INIT     8  /* crypto_init() not yet called             */

#endif /* CRYPTO_ERRORS_H */

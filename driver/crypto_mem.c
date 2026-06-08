/* Expose syscall() and Linux-specific extensions under -std=c11 */
#define _GNU_SOURCE

/* crypto_mem.c - address translation and cache coherency utilities.
 *
 * These functions are Linux / ARM-specific:
 *   - virt_to_phys  requires /proc/self/pagemap (Linux kernel feature)
 *   - flush/invalidate use the ARM Linux cacheflush syscall directly
 *
 * Do not link this file for host-side (x86) test builds.
 */

#include "crypto_driver.h"

#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ARM Linux private syscall number for cache maintenance.
 * __builtin___clear_cache is documented for icache (JIT use) and its dcache
 * side-effect is toolchain-dependent - it is a no-op on some arm-linux-gnueabihf
 * libgcc builds.  Call the kernel directly to guarantee both caches are cleaned
 * and invalidated (BCACHE = clean+invalidate dcache, then invalidate icache). */
#ifndef __ARM_NR_cacheflush
#define __ARM_NR_cacheflush 0x0f0002
#endif
#define BCACHE 0   /* kernel interprets 0 as "flush everything" on ARM */

/* ---------------------------------------------------------------------------
 * Address translation
 * --------------------------------------------------------------------------*/

/* Translate a virtual address to its physical DDR address via /proc/self/pagemap.
 * Pins the page with mlock() before the lookup so the PFN is valid.
 *
 * Args :
 *   - vaddr [void *] : virtual address to translate
 *
 * Returns :
 *   - [uint64_t] : physical address, or 0 on failure
 */
uint64_t virt_to_phys(void *vaddr) {
    uint64_t entry = 0;

    /* Pin the containing page so the kernel faults it into physical RAM and
     * populates /proc/self/pagemap with a valid PFN.  Without this, a freshly
     * malloc'd or not-yet-accessed page may have no physical frame assigned,
     * causing pagemap to report present=0 and this function to return 0.
     * Failure is intentionally ignored: if mlock fails the subsequent
     * present-bit check (bit 63) still catches the missing entry. */
    mlock(vaddr, 1);

    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;

    long page_size = sysconf(_SC_PAGESIZE);
    /* Each pagemap entry is 8 bytes; entry index = page number */
    off_t offset = ((uintptr_t)vaddr / (size_t)page_size) * 8;

    if (lseek(fd, offset, SEEK_SET) < 0) { close(fd); return 0; }
    if (read(fd, &entry, 8) != 8)        { close(fd); return 0; }
    close(fd);

    /* Bit 63: page present in RAM.  Bits 54:0: PFN. */
    if (!(entry & (1ULL << 63))) return 0;
    uint64_t pfn = entry & 0x007FFFFFFFFFFFFFULL;
    return (pfn * (uint64_t)page_size) + ((uintptr_t)vaddr % (size_t)page_size);
}

/* ---------------------------------------------------------------------------
 * Cache coherency
 * --------------------------------------------------------------------------*/

/* DMA accesses DDR directly; the CPU caches are not automatically coherent.
 *
 * Before a DMA read  (hardware reads from DDR): flush so CPU writes reach DDR.
 * After  a DMA write (hardware writes to DDR) : invalidate so CPU reads fresh
 * data rather than stale cached data.
 *
 * Skipping either step causes silent data corruption.
 */

/* Flush CPU D-cache lines covering [buf, buf+len) to DDR before a DMA read.
 *
 * Args :
 *   - buf [void *] : start of the region to flush
 *   - len [size_t] : length in bytes
 */
void crypto_flush_cache(void *buf, size_t len) {
    syscall(__ARM_NR_cacheflush, (long)buf, (long)((char *)buf + len), BCACHE);
}

/* Invalidate CPU D-cache lines covering [buf, buf+len) after a DMA write.
 *
 * Args :
 *   - buf [void *] : start of the region to invalidate
 *   - len [size_t] : length in bytes
 */
void crypto_invalidate_cache(void *buf, size_t len) {
    syscall(__ARM_NR_cacheflush, (long)buf, (long)((char *)buf + len), BCACHE);
}

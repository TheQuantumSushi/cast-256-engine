/* gcm_kat_gen.c — Generate CAST-256-GCM Known-Answer Test vectors.
 *
 * Computes expected (CT, TAG) pairs for a fixed set of (KEY, IV, AAD, PT)
 * inputs and prints them in two formats:
 *
 *   --ghdl  : one line per output value, suitable as GHDL generic arguments
 *             (used by run_gcm_kat.sh to drive tb_gcm with expected values)
 *
 *   --kat   : human-readable KAT record for documentation / future extension
 *
 * The test vector is identical to the one hard-coded in tb_gcm.vhd so that
 * the shell script can pass the computed CT/TAG as generics and the VHDL
 * simulation will assert against them.
 *
 * Build:
 *   gcc -Wall -O2 -I. gcm_kat_gen.c gcm_ref.c cast.c -o gcm_kat_gen
 *
 * Usage:
 *   ./gcm_kat_gen          (prints --ghdl format by default)
 *   ./gcm_kat_gen --kat    (prints human-readable KAT record)
 *   ./gcm_kat_gen --all    (prints both)
 */

#include "gcm_ref.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* ---- Test vector matching tb_gcm.vhd constants ------------------------- */

static const uint8_t KEY[32] = {
    0x23,0x42,0xbb,0x9e, 0xfa,0x38,0x54,0x2c,
    0xbe,0xd0,0xac,0x83, 0x94,0x0a,0xc2,0x98,
    0x8d,0x7c,0x47,0xce, 0x26,0x49,0x08,0x46,
    0x1c,0xc1,0xb5,0x13, 0x7a,0xe6,0xb6,0x04
};

static const uint8_t IV[12] = {
    0xca,0xfe,0xba,0xbe, 0x12,0x34,0x56,0x78, 0x00,0x00,0x00,0x01
};

static const uint8_t AAD[16] = {
    0x00,0x01,0x02,0x03, 0x04,0x05,0x06,0x07,
    0x08,0x09,0x0a,0x0b, 0x0c,0x0d,0x0e,0x0f
};

static const uint8_t PT[32] = {
    0x10,0x11,0x12,0x13, 0x14,0x15,0x16,0x17,
    0x18,0x19,0x1a,0x1b, 0x1c,0x1d,0x1e,0x1f,
    0x20,0x21,0x22,0x23, 0x24,0x25,0x26,0x27,
    0x28,0x29,0x2a,0x2b, 0x2c,0x2d,0x2e,0x2f
};

/* ---- Helpers ----------------------------------------------------------- */

static void print_hex(const char *label, const uint8_t *data, size_t len)
{
    printf("%s:", label);
    for (size_t i = 0; i < len; i++) printf("%02x", data[i]);
    printf("\n");
}

/* Print just the hex digits (no label, no newline) for shell capture. */
static void print_hex_raw(const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; i++) printf("%02x", data[i]);
}

/* ---- Main -------------------------------------------------------------- */

int main(int argc, char *argv[])
{
    int fmt_ghdl = 1;   /* default */
    int fmt_kat  = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--kat")  == 0) { fmt_ghdl = 0; fmt_kat  = 1; }
        if (strcmp(argv[i], "--ghdl") == 0) { fmt_ghdl = 1; fmt_kat  = 0; }
        if (strcmp(argv[i], "--all")  == 0) { fmt_ghdl = 1; fmt_kat  = 1; }
    }

    uint8_t ct[32];
    uint8_t tag[16];

    gcm_encrypt(KEY, sizeof(KEY), IV, AAD, sizeof(AAD),
                PT, sizeof(PT), ct, tag);

    if (fmt_ghdl) {
        /* One value per line so the shell script can read them easily. */
        printf("CT0:");  print_hex_raw(ct,      16); printf("\n");
        printf("CT1:");  print_hex_raw(ct + 16, 16); printf("\n");
        printf("TAG:");  print_hex_raw(tag,     16); printf("\n");
    }

    if (fmt_kat) {
        printf("# CAST-256-GCM Known-Answer Test Vector\n");
        printf("# Key schedule: 256-bit CAST-256 (RFC 2612 §A, 256-bit variant)\n");
        printf("# Mode: GCM authenticated encryption, NIST SP 800-38D\n");
        printf("# AAD length : %zu bytes  |  PT length : %zu bytes\n\n",
               sizeof(AAD), sizeof(PT));
        print_hex("KEY", KEY, sizeof(KEY));
        print_hex("IV",  IV,  sizeof(IV));
        print_hex("AAD", AAD, sizeof(AAD));
        print_hex("PT",  PT,  sizeof(PT));
        print_hex("CT",  ct,  sizeof(ct));
        print_hex("TAG", tag, sizeof(tag));

        /* Verify round-trip */
        uint8_t pt_rec[32];
        int ok = gcm_decrypt(KEY, sizeof(KEY), IV, AAD, sizeof(AAD),
                             ct, sizeof(ct), tag, pt_rec);
        int pt_match = (memcmp(pt_rec, PT, sizeof(PT)) == 0);
        printf("VERIFY:decrypt=%s pt_match=%s\n",
               ok == 0 ? "PASS" : "FAIL",
               pt_match ? "PASS" : "FAIL");
    }

    return 0;
}

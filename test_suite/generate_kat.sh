#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  generate_kat.sh                                                         ║
# ║  Generate CAST-256 Known-Answer Test files from a reference C            ║
# ║  implementation (cast.c / std_defs.h).                                   ║
# ║                                                                           ║
# ║  Reads  : kat_inputs.txt  (same directory as this script)                ║
# ║  Writes : {name}.kat files to OUT_DIR (default: script directory)        ║
# ║                                                                           ║
# ║  Usage  : ./generate_kat.sh [-d <output_dir>]                            ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Resolve script directory ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            if [[ $# -lt 2 ]]; then
                echo "Error: -d requires a directory argument" >&2
                exit 1
            fi
            OUT_DIR="$(realpath "$2")"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: $(basename "$0") [-d <output_dir>]" >&2
            exit 1
            ;;
    esac
done

# ── Prerequisite checks ───────────────────────────────────────────────────────
KAT_INPUTS="$SCRIPT_DIR/kat_inputs.txt"
CAST_C="$SCRIPT_DIR/cast.c"
STD_DEFS_H="$SCRIPT_DIR/std_defs.h"

for required in "$KAT_INPUTS" "$CAST_C" "$STD_DEFS_H"; do
    if [[ ! -f "$required" ]]; then
        echo "Error: required file not found: $required" >&2
        exit 1
    fi
done

for tool in gcc make python3; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' not found in PATH" >&2
        exit 1
    fi
done

mkdir -p "$OUT_DIR"

# ── Build directory setup ─────────────────────────────────────────────────────
# Directory layout:
#   _build/
#     std_defs.h          ← fixed-width-type replacement for the original
#     main.c              ← KAT driver (argv[1]=key_hex  argv[2]=pt_hex)
#     Makefile
#     cast256/
#       cast.c            ← CR-stripped copy of the original
#
# cast.c does  #include "../std_defs.h"  which GCC resolves relative to
# cast.c's own location, giving  _build/cast256/../std_defs.h = _build/std_defs.h ✓
#
# cast.c was distributed with \<CR><CR><LF> line endings.  The extra <CR>
# after each backslash-continuation breaks the macro definitions.  We strip
# every <CR> byte (0x0d) before copying.

BUILD_DIR="$SCRIPT_DIR/_build"
mkdir -p "$BUILD_DIR/cast256"

# Strip \r from cast.c before writing to the build directory
python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(data.replace(b'\r', b''))
" "$CAST_C" "$BUILD_DIR/cast256/cast.c"

# ── _build/std_defs.h ─────────────────────────────────────────────────────────
# The original std_defs.h typedefs u4byte as `unsigned long`, which is 64-bit
# on modern Linux.  We replace it with <stdint.h> types so u4byte is always
# uint32_t.  We also mask the shift amounts in rotl/rotr to [0,31] to avoid
# undefined behaviour on shifts ≥ 32.
cat > "$BUILD_DIR/std_defs.h" << 'STDEFS_EOF'
#ifndef STD_DEFS_H
#define STD_DEFS_H

#include <stdint.h>

typedef uint8_t  u1byte;
typedef uint16_t u2byte;
typedef uint32_t u4byte;
typedef int8_t   s1byte;
typedef int16_t  s2byte;
typedef int32_t  s4byte;

/* Circular 32-bit rotates — shift amount masked to [0,31] to avoid UB */
#define rotr(x, n) \
    (((uint32_t)(x) >> (((int)(n)) & 31)) | \
     ((uint32_t)(x) << (32 - (((int)(n)) & 31))))

#define rotl(x, n) \
    (((uint32_t)(x) << (((int)(n)) & 31)) | \
     ((uint32_t)(x) >> (32 - (((int)(n)) & 31))))

/* Byte-reverse a 32-bit word */
#define bswap(x) \
    ((rotl((x), 8) & 0x00ff00ffu) | (rotr((x), 8) & 0xff00ff00u))

/* Extract byte n (0 = LSB) from a 32-bit word */
#define byte(x, n) ((u1byte)((uint32_t)(x) >> (8 * (n))))

#ifdef BLOCK_SWAP
#  define BYTE_SWAP
#  define WORD_SWAP
#endif

/* cast.c defines BYTE_SWAP before including this header, so io_swap = bswap */
#ifdef BYTE_SWAP
#  define io_swap(x) bswap(x)
#else
#  define io_swap(x) (x)
#endif

#endif /* STD_DEFS_H */
STDEFS_EOF

# ── _build/main.c ─────────────────────────────────────────────────────────────
# Endianness contract with cast.c:
#   cast.c defines BYTE_SWAP → io_swap = bswap (byte-reverses every 32-bit
#   word on input/output).  We therefore supply the key and plaintext words as
#   little-endian uint32_t values (bytes loaded in natural memory order).
#   bswap inside set_key / encrypt converts them to the big-endian
#   representation the RFC algorithm uses internally.  The ciphertext output
#   words are in the same little-endian format; we decode them byte-by-byte
#   to reconstruct the big-endian hex string.
cat > "$BUILD_DIR/main.c" << 'MAIN_EOF'
/*
CAST-256 KAT driver.

Args:
    - argv[1] [char*] : key as a hex string (32/40/48/56/64 hex chars)
    - argv[2] [char*] : 128-bit plaintext as a hex string (32 hex chars)

Returns:
    - int : 0 on success, 1 on error
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef uint32_t u4byte;

/* Declarations from cast256/cast.c */
u4byte *set_key(const u4byte in_key[], const u4byte key_len);
void    encrypt(const u4byte in_blk[4], u4byte out_blk[4]);

/*
Parse a hex string into a byte array.

Args:
    - hex       [const char*] : null-terminated hex string (must have even length)
    - bytes     [uint8_t*]    : output buffer
    - max_bytes [size_t]      : capacity of output buffer

Returns:
    - int : number of bytes written, or -1 on error
*/
static int hex_to_bytes(const char *hex, uint8_t *bytes, size_t max_bytes)
{
    size_t len = strlen(hex);
    if (len % 2 != 0) return -1;
    size_t n = len / 2;
    if (n > max_bytes) return -1;
    for (size_t i = 0; i < n; i++) {
        unsigned int v;
        if (sscanf(hex + 2 * i, "%02x", &v) != 1) return -1;
        bytes[i] = (uint8_t)v;
    }
    return (int)n;
}

/*
Pack 4 consecutive big-endian bytes into a little-endian u4byte word.
cast.c's io_swap (= bswap) will reverse the byte order back to big-endian
inside set_key / encrypt, recovering the correct RFC representation.

Args:
    - b [const uint8_t*] : pointer to the first of 4 bytes

Returns:
    - u4byte : little-endian packed 32-bit word
*/
static u4byte pack_le(const uint8_t *b)
{
    return ((u4byte)b[0]      ) |
           ((u4byte)b[1] <<  8) |
           ((u4byte)b[2] << 16) |
           ((u4byte)b[3] << 24);
}

int main(int argc, char *argv[])
{
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <key_hex> <plaintext_hex>\n", argv[0]);
        return 1;
    }

    const char *key_hex = argv[1];
    const char *pt_hex  = argv[2];

    /* ── Parse key ──────────────────────────────────────────────────────── */
    uint8_t key_bytes[32] = {0};
    int key_len_bytes = hex_to_bytes(key_hex, key_bytes, 32);
    if (key_len_bytes < 0) {
        fprintf(stderr, "Error: invalid key hex string\n");
        return 1;
    }
    int key_len_bits = key_len_bytes * 8;
    if (key_len_bits != 128 && key_len_bits != 160 &&
        key_len_bits != 192 && key_len_bits != 224 && key_len_bits != 256) {
        fprintf(stderr,
            "Error: key must be 128/160/192/224/256 bits, got %d\n",
            key_len_bits);
        return 1;
    }

    /* ── Parse plaintext ────────────────────────────────────────────────── */
    uint8_t pt_bytes[16] = {0};
    int pt_len = hex_to_bytes(pt_hex, pt_bytes, 16);
    if (pt_len != 16) {
        fprintf(stderr,
            "Error: plaintext must be exactly 128 bits (32 hex chars)\n");
        return 1;
    }

    /* ── Load key as little-endian u4byte words ──────────────────────────── */
    u4byte key_words[8] = {0};
    int num_key_words = (key_len_bytes + 3) / 4;
    for (int i = 0; i < num_key_words; i++) {
        key_words[i] = pack_le(key_bytes + 4 * i);
    }
    set_key(key_words, (u4byte)key_len_bits);

    /* ── Load plaintext and encrypt ──────────────────────────────────────── */
    u4byte pt_words[4], ct_words[4];
    for (int i = 0; i < 4; i++) {
        pt_words[i] = pack_le(pt_bytes + 4 * i);
    }
    encrypt(pt_words, ct_words);

    /* ── Decode ciphertext words back to bytes ───────────────────────────── */
    uint8_t ct_bytes[16];
    for (int i = 0; i < 4; i++) {
        ct_bytes[4 * i + 0] = (uint8_t)((ct_words[i]      ) & 0xff);
        ct_bytes[4 * i + 1] = (uint8_t)((ct_words[i] >>  8) & 0xff);
        ct_bytes[4 * i + 2] = (uint8_t)((ct_words[i] >> 16) & 0xff);
        ct_bytes[4 * i + 3] = (uint8_t)((ct_words[i] >> 24) & 0xff);
    }

    /* ── Emit KAT record ─────────────────────────────────────────────────── */
    printf("KEY:%s\n", key_hex);
    printf("PLAINTEXT:%s\n", pt_hex);
    printf("CIPHERTEXT:");
    for (int i = 0; i < 16; i++) {
        printf("%02x", ct_bytes[i]);
    }
    printf("\n");

    return 0;
}
MAIN_EOF

# ── _build/Makefile ───────────────────────────────────────────────────────────
cat > "$BUILD_DIR/Makefile" << 'MAKEFILE_EOF'
CC     = gcc
CFLAGS = -Wall -Wextra -O2 -std=c99
TARGET = cast_kat

.PHONY: all clean

all: $(TARGET)

$(TARGET): main.c cast256/cast.c
	$(CC) $(CFLAGS) -o $(TARGET) main.c cast256/cast.c

clean:
	rm -f $(TARGET)
MAKEFILE_EOF

# ── Compile ───────────────────────────────────────────────────────────────────
echo "Compiling..."
make -C "$BUILD_DIR" --no-print-directory
BINARY="$BUILD_DIR/cast_kat"

# ── Parse kat_inputs.txt and generate .kat files ──────────────────────────────
# Input format (fields may appear in any order; records are delimited by each
# new NAME field or by blank lines):
#
#   NAME:{name}
#   KEY:{key}
#   PLAINTEXT:{plaintext}
#
# Hex strings are normalised to lowercase before being passed to cast_kat.

echo "Generating KAT files..."

current_name=""
current_key=""
current_pt=""
generated=0

# Flush the current record to a .kat file (if all 3 fields are present).
flush_record() {
    if [[ -n "$current_name" && -n "$current_key" && -n "$current_pt" ]]; then
        local key_lc pt_lc
        key_lc="$(printf '%s' "$current_key" | tr '[:upper:]' '[:lower:]')"
        pt_lc="$(printf '%s'  "$current_pt"  | tr '[:upper:]' '[:lower:]')"

        local out_file="$OUT_DIR/${current_name}.kat"
        "$BINARY" "$key_lc" "$pt_lc" > "$out_file"
        echo "  wrote $out_file"
        generated=$(( generated + 1 ))

        current_name=""
        current_key=""
        current_pt=""
    elif [[ -n "$current_name" || -n "$current_key" || -n "$current_pt" ]]; then
        echo "Warning: incomplete record (NAME='$current_name') — skipped" >&2
        current_name=""
        current_key=""
        current_pt=""
    fi
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    # Strip carriage returns and surrounding whitespace
    line="$(printf '%s' "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Skip blank lines and comment lines
    [[ -z "$line" || "$line" == \#* ]] && continue

    field="${line%%:*}"
    value="${line#*:}"

    case "$field" in
        NAME)
            # A new NAME starts a new record; flush any pending one first
            flush_record
            current_name="$value"
            ;;
        KEY)
            current_key="$value"
            ;;
        PLAINTEXT)
            current_pt="$value"
            # Flush as soon as all 3 fields are in hand
            if [[ -n "$current_name" && -n "$current_key" ]]; then
                flush_record
            fi
            ;;
        *)
            echo "Warning: unrecognised field '$field' — ignored" >&2
            ;;
    esac
done < "$KAT_INPUTS"

# Final flush in case the file does not end with a blank line
flush_record

echo "Done — $generated KAT file(s) written to $OUT_DIR"

# ── Clean up build artefacts ──────────────────────────────────────────────────
echo "Cleaning up..."
make -C "$BUILD_DIR" clean --no-print-directory
rm -rf "$BUILD_DIR"

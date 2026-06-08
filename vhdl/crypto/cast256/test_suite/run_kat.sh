#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  run_kat.sh                                                              ║
# ║  Run all CAST-256 KAT files against the VHDL simulation and report       ║
# ║  pass / fail for each vector.                                            ║
# ║                                                                          ║
# ║  Usage : ./run_kat.sh -k <kat_dir> [-s <vhdl_src_dir>]                  ║
# ║                                                                          ║
# ║  -k <kat_dir>      Directory containing the .kat files (required)        ║
# ║  -s <vhdl_src_dir> Directory containing the .vhd source files           ║
# ║                    (default: parent directory, i.e. cast256/)            ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAT_DIR=""
SRC_DIR="$SCRIPT_DIR/.."

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k)
            [[ $# -lt 2 ]] && { echo "Error: -k requires a directory" >&2; exit 1; }
            KAT_DIR="$(realpath "$2")"; shift 2 ;;
        -s)
            [[ $# -lt 2 ]] && { echo "Error: -s requires a directory" >&2; exit 1; }
            SRC_DIR="$(realpath "$2")"; shift 2 ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: $(basename "$0") -k <kat_dir> [-s <vhdl_src_dir>]" >&2
            exit 1 ;;
    esac
done

[[ -z "$KAT_DIR" ]] && { echo "Error: -k <kat_dir> is required" >&2; exit 1; }
[[ ! -d "$KAT_DIR" ]] && { echo "Error: KAT directory not found: $KAT_DIR" >&2; exit 1; }
[[ ! -d "$SRC_DIR" ]] && { echo "Error: source directory not found: $SRC_DIR" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for f in cast256_pkg.vhd cast256_ks.vhd cast256_enc.vhd cast256.vhd tb_cast256.vhd; do
    [[ ! -f "$SRC_DIR/$f" ]] && { echo "Error: $f not found in $SRC_DIR" >&2; exit 1; }
done
command -v ghdl &>/dev/null || { echo "Error: ghdl not found in PATH" >&2; exit 1; }

# ── Build in a temporary directory ───────────────────────────────────────────
# GHDL writes its work library (work-obj08.cf) into the current directory.
# We use a temp dir so this script does not pollute the source tree.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Build directory : $BUILD_DIR"
echo "VHDL sources    : $SRC_DIR"
echo "KAT files       : $KAT_DIR"
echo ""

# Copy sources so ghdl -a can find them relative to the build dir
for f in cast256_pkg.vhd cast256_ks.vhd cast256_enc.vhd cast256.vhd tb_cast256.vhd; do
    cp "$SRC_DIR/$f" "$BUILD_DIR/$f"
done

cd "$BUILD_DIR"

# ── Analyse and elaborate (once) ─────────────────────────────────────────────
echo "Analysing..."
ghdl -a --std=08 cast256_pkg.vhd
ghdl -a --std=08 cast256_ks.vhd
ghdl -a --std=08 cast256_enc.vhd
ghdl -a --std=08 cast256.vhd
ghdl -a --std=08 tb_cast256.vhd

echo "Elaborating..."
ghdl -e --std=08 tb_cast256

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " Running KAT vectors"
echo "══════════════════════════════════════════════════════════════════"

# ── Run each .kat file ────────────────────────────────────────────────────────
pass=0
fail=0
errors=0

for kat_file in "$KAT_DIR"/*.kat; do
    [[ ! -f "$kat_file" ]] && { echo "No .kat files found in $KAT_DIR" >&2; exit 1; }

    name="$(basename "$kat_file" .kat)"

    # Parse the KAT fields
    key=""
    pt=""
    expected_ct=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "${line%%:*}" in
            KEY)       key="${line#KEY:}" ;;
            PLAINTEXT) pt="${line#PLAINTEXT:}" ;;
            CIPHERTEXT) expected_ct="${line#CIPHERTEXT:}" ;;
        esac
    done < "$kat_file"

    if [[ -z "$key" || -z "$pt" || -z "$expected_ct" ]]; then
        echo "  [SKIP] $name - malformed KAT file"
        errors=$(( errors + 1 ))
        continue
    fi

    # Run the simulation; GHDL sends report output to stderr
    sim_output="$(ghdl -r --std=08 tb_cast256 \
        -gKEY_HEX="$key" \
        -gPT_HEX="$pt" 2>&1)" || true

    # Extract the ciphertext from the CIPHERTEXT: report line
    got_ct="$(printf '%s\n' "$sim_output" \
        | grep -oP '(?<=CIPHERTEXT:)[0-9a-fA-F]{32}' \
        | tr '[:upper:]' '[:lower:]')"

    expected_ct="$(printf '%s' "$expected_ct" | tr '[:upper:]' '[:lower:]')"

    if [[ -z "$got_ct" ]]; then
        printf "  [ERROR] %-30s  simulation produced no output\n" "$name"
        errors=$(( errors + 1 ))
    elif [[ "$got_ct" == "$expected_ct" ]]; then
        printf "  [PASS]  %-30s  %s\n" "$name" "$got_ct"
        pass=$(( pass + 1 ))
    else
        printf "  [FAIL]  %-30s\n" "$name"
        printf "          expected : %s\n" "$expected_ct"
        printf "          got      : %s\n" "$got_ct"
        fail=$(( fail + 1 ))
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
total=$(( pass + fail + errors ))
echo ""
echo "══════════════════════════════════════════════════════════════════"
printf " Results : %d / %d passed" "$pass" "$total"
[[ $fail   -gt 0 ]] && printf "   %d failed"  "$fail"
[[ $errors -gt 0 ]] && printf "   %d error(s)" "$errors"
echo ""
echo "══════════════════════════════════════════════════════════════════"

# Exit with a non-zero code if anything failed, so CI pipelines catch it
[[ $(( fail + errors )) -gt 0 ]] && exit 1 || exit 0

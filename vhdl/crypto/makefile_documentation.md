# Makefile — CAST-256 build reference

## Requirements

`ghdl` and `vivado` must be in `PATH`. `synth_cast256.tcl` must be in the same directory.

## Targets

| Target | Command | Description |
|---|---|---|
| Build all | `make` | Analyse all sources and elaborate the testbench |
| Simulate | `make run` | Run simulation with the default RFC 2612 vector |
| Synthesise | `make synth` | Run Vivado timing and utilisation analysis |
| Clean | `make clean` | Remove GHDL work library and stamp files |
| Full clean | `make cleanall` | `clean` + remove Vivado reports and logs |

Individual file targets: `make pkg` · `make ks` · `make enc` · `make top` · `make tb`

These re-analyse a single file and everything that depends on it, in the correct order.

## Custom simulation vector

```bash
make run KEY=<64 hex chars> PT=<32 hex chars>
```

## Dependency order

```
pkg → ks  ↘
         top → tb → elaborate → run
     enc ↗
```

Make tracks which files are up to date via hidden stamp files (`.analysed_*`).
Only stale files and their dependents are re-analysed on the next `make`.

---

## Workflow example

Standard cycle whenever a source file is modified.

### After modifying any VHDL file

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make clean
make
```

If only one file changed, use its individual target to avoid a full rebuild:

```bash
# Example: only cast256_enc.vhd was modified
make enc
# Re-analyses enc, then top, then tb in the correct order.
# pkg and ks are left untouched.
```

### Run the default simulation (RFC anchor vector)

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make run
# Expected output line:
# CIPHERTEXT:4f6a2038286897b9c9870136553317fa
```

### Run a custom vector

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make run \
  KEY=2342bb9efa38542cbed0ac83940ac2988d7c47ce264908461cc1b5137ae6b604 \
  PT=00000000000000000000000000000000
```

### Verify all 20 KAT vectors pass

```bash
cd ~/Documents/ds/cast-256-engine/test_suite
./run_kat.sh \
  -k 256_bit_tests/ \
  -s ~/Documents/ds/cast-256-engine/vhdl/crypto
# Expected last lines:
#  Results : 20 / 20 passed
```

### Run Vivado synthesis and check results

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make synth
grep -E "Slice LUTs|Block RAM" utilization.rpt
grep -E "Worst slack|Estimated Fmax" timing_summary.rpt
```

To discard all synthesis artifacts and re-run from scratch:

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make cleanall
make synth
```

### Full validation sequence (all steps in order)

```bash
cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make clean
make
make run

cd ~/Documents/ds/cast-256-engine/test_suite
./run_kat.sh \
  -k 256_bit_tests/ \
  -s ~/Documents/ds/cast-256-engine/vhdl/crypto

cd ~/Documents/ds/cast-256-engine/vhdl/crypto
make synth
grep -E "Slice LUTs|Block RAM" utilization.rpt
grep -E "Worst slack|Estimated Fmax" timing_summary.rpt
```

# cast256

VHDL implementation of the CAST-256 block cipher (RFC 2612), 256-bit key,
128-bit block. Designed as a standalone pipelined core instantiated by the
GCM top-level (`crypto.vhd`).

## Source files

| File | Role |
|---|---|
| `cast256_pkg.vhd` | S-box constants (SBOX1-4), shared types, helper functions used by ks and enc |
| `cast256_ks.vhd` | Key schedule: expands the 256-bit key into 192 round sub-keys over ~396 cycles |
| `cast256_enc.vhd` | Encryption datapath: 12 rounds, 48 f-function steps, ~96 cycles/block. BRAM S-boxes (ram_style="block"), DSP f-functions (use_dsp="yes") |
| `cast256.vhd` | Top-level: multiplexes input, instantiates `cast256_ks` and N_ENG `cast256_enc` engines in parallel, arbitrates the output |
| `tb_cast256.vhd` | KAT testbench: runs all RFC 2612 Appendix A vectors via `make run` |
| `iterations.md` | Synthesis iteration log: S-box inference strategies, DSP mapping experiments, timing results per attempt |

## Build

Requires `ghdl` and `vivado` in `PATH`.

| Target | Description |
|---|---|
| `make` | Analyse all sources and elaborate the testbench |
| `make run` | Simulate with the default RFC 2612 256-bit vector |
| `make synth` | OOC synthesis via `tcl_files/synth_cast256.tcl` (Vivado) |
| `make clean` | Remove GHDL work library and stamp files |
| `make cleanall` | `clean` + remove Vivado reports and logs |

Individual file targets: `make pkg` · `make ks` · `make enc` · `make top` · `make tb`

These re-analyse a single file and all its dependents in the correct order.

### Dependency order

```
pkg → ks  ↘
           top → tb → elaborate → run
      enc ↗
```

Make tracks which files are up to date via hidden stamp files (`.analysed_*`).
Only stale files and their dependents are re-analysed on the next `make`.

### Custom simulation vector

```bash
make run KEY=<64 hex chars> PT=<32 hex chars>
```

## Typical workflows

### Simulate after modifying a source file

```bash
# Full rebuild
make clean && make && make run

# Or, if only one file changed, use its individual target:
make enc   # re-analyses enc, then top, then tb — skips pkg and ks
```

### Run OOC synthesis and check results

```bash
make synth
# Summary is printed to the console at the end of the run.
# Full reports: timing_summary.rpt  utilization.rpt
```

### Run all RFC 2612 KAT vectors

```bash
# From the cast256/ directory:
test_suite/run_kat.sh -k test_suite/kat_files_256_bits
```

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

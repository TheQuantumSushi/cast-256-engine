# Vivado TCL scripts

Four Vivado batch scripts for the CAST-256-GCM accelerator on the Zybo Z7-10 board. All scripts use `[info script]` to locate themselves, so they can be invoked from any working directory :

```
vivado -mode batch -source tcl_files/<script>.tcl
```

---

## Summary of their purpose :

| Script | Purpose | Output |
|---|---|---|
| `package_ip.tcl` | Wrap VHDL sources as a Vivado IP core | `vhdl/crypto/crypto_ip/` |
| `create_bd.tcl` | Full board build : block design + synth + P&R + bitstream | `vhdl/crypto/fpga.bit` |
| `synth_crypto.tcl` | OOC synthesis of the full fabric for fast timing feedback | `vhdl/crypto/synth/*.rpt` |
| `synth_cast256.tcl` | OOC synthesis of the CAST-256 core in isolation | `vhdl/crypto/cast256/*.rpt` |

Run order :
- `package_ip.tcl` first to create a Vivado IP Core
- `create_bd.tcl` after this to build the full synthesis + place & route + bitstream pipeline
- `synth_crypto.tcl` whenever you wish to have a quick performance and fabric utilization assessment without doing a full build
- `synth_cast256.tcl` to have the same but isolating the core of cast256 only

---

## Script details

### `package_ip.tcl`

Reads all VHDL source files and registers them as a Vivado IP core in `vhdl/crypto/crypto_ip/`. This step is required
once, before building `create_bd.tcl`, because Vivado's block design flow works with packaged IPs.

Key things it configures :
- sets the correct AXI address widths (12-bit for `s0_axi`, 30-bit for `m0_axi`), which Vivado would otherwise auto-infer as 32-bit
- marks the `irq` port as an interrupt master interface so it can be connected to `PS7 IRQ_F2P` in the block design without a manual bus interface assignment

Note : to re-run it, delete `vhdl/crypto/crypto_ip/` first, then re-run.

---

### `create_bd.tcl`

The full board build pipeline in one script. Requires `package_ip.tcl` to have been run first.

What it does, in order :
1. creates a Vivado project in `vhdl/crypto/vivado_proj/`.
2. builds the block design wiring the Zynq PS to the crypto IP:
   - `PS7 M_AXI_GP0` -> SmartConnect -> `crypto s0_axi` @ `0x43C00000`
   - `crypto m0_axi` -> SmartConnect -> `PS7 S_AXI_GP0` (DDR, 512 MB)
   - `PS7 FCLK_CLK0` clocks all fabric blocks
   - `FCLK_RESET0_N` -> `proc_sys_reset` -> `aresetn`
   - `crypto irq` -> `xlconcat` -> `PS7 IRQ_F2P[0]`
3. adds `crypto.xdc` (pin constraints for switches, buttons, LEDs).
4. runs synthesis, place & route, and bitstream generation.
5. copies `fpga.bit` to `vhdl/crypto/` and writes `crypto.xsa`.

**Digilent board files :** if installed, the PS7 DDR/MIO configuration is applied automatically via board preset. If not, a minimal hardcoded configuration for the Zybo Z7-10 DDR3 is used instead.

---

### `synth_crypto.tcl`

Out-of-context synthesis of the complete fabric (`crypto.vhd` and all sub-modules) without the Zynq PS. OOC mode treats the design as a black-box with unconstrained I/O, which is fine for timing and utilization analysis but cannot produce a bitstream ; the goal is in fact to have a performance report and not have a full build.

Outputs written to `vhdl/crypto/synth/` :
- `timing_summary.rpt` - worst negative slack, critical path, estimated Fmax
- `utilization.rpt` - flat LUT / FF / DSP / BRAM counts vs. device budget
- `utilization_hier.rpt` - per-instance breakdown (useful for isolating which sub-module is consuming the most resources)

A formatted summary is also printed to the console at the end of the run.

---

### `synth_cast256.tcl`

Same principle as `synth_crypto.tcl` but synthesises only the CAST-256 core (`cast256_pkg`, `cast256_ks`, `cast256_enc`, `cast256`) in isolation, without GCM, AXI slave, or DMA. Reports are written to `vhdl/crypto/cast256/`.

---

## Typical workflows used :

### First-time board build


1. Package the IP (once, or after any port/interface change)
```bash
vivado -mode batch -source tcl_files/package_ip.tcl
```

2. Full build: block design + synthesis + P&R + bitstream (~20 min)
```bash
vivado -mode batch -source tcl_files/create_bd.tcl
```

3. Program the FPGA by putting the file `fpga.bit` on the SD card (it gets automatically applied to the FPGA at boot time, per configuration of the board provided)


### Iterating on VHDL (timing check only)

1. Fast OOC synthesis of the full fabric
```bash
vivado -mode batch -source tcl_files/synth_crypto.tcl
```

2. Or, if only the cipher core changed
```bash
vivado -mode batch -source tcl_files/synth_cast256.tcl
```

### Rebuilding after a port change on `crypto.vhd`

A port change invalidates the packaged IP. Delete the old package and rebuild :

```bash
rm -rf vhdl/crypto/crypto_ip
vivado -mode batch -source tcl_files/package_ip.tcl
vivado -mode batch -source tcl_files/create_bd.tcl
```

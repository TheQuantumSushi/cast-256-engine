# cast-256-engine

A hardware accelerator for authenticated encryption, written in VHDL for a Zynq-7000 FPGA (Zybo Z7) : the **CAST-256** algorithm, in **GCM mode** (NIST SP 800-38D), along with an ARM Linux driver and DMA transfers over AXI4-Lite.

This was a team project of three students for the Digital Systems course. It was originally developed in a private GitLab repository ; I duplicated it (including commit history) on this GitHub page to be able to feature it.

- **The assignment** : its content and specifications can be found in [`assignment.md`](assignment.md).
- **Our technical report** : it is in the [`report/`](report/) folder: [`digisys_report_kah_cano_hirschmiller.pdf`](report/digisys_report_kah_cano_hirschmiller.pdf).

## Overview

The goal was to build a complete cryptographic engine to run on the Zybo Z7 boards (Zynq-7000), re-implementing the CAST-256/GCM algorithm in VHDL, together with ARM Linux drivers and a DMA engine that moves data between the CPU and the FPGA core through AXI4-Lite slave and master interfaces. The whole design is organized around and driven by FSMs.

The project covered the full Vivado toolchain : synthesis, static timing analysis (critical path, maximum clock frequency), resource usage (LUTs, flip-flops, BRAM) and testbenches with a full test suite.

The core idea was to make the system as fast as possible within the limited hardware footprint of the FPGA, leading to reasoning about design tradeoffs in order to push the clock frequency up and avoid bottlenecks.

### Final performance

| | |
|---|---|
| Critical path | 13.745 ns |
| Maximum clock frequency | 72.8 MHz |
| Asymptotic throughput | 179 Mbps (warm key, large payload) |
| Slice LUTs | 11,587 / 17,600 (65.8%) |
| Slice registers | 7,742 / 35,200 (22.0%) |
| RAMB18 | 4 / 120 (3.3%) |
| DSPs | 0 / 80 |

### Possible improvements

We identified several ways to go further, but ran out of time and stopped there. We thought about doing the following things :

- Pipeline the adder in the CAST-256 encryption datapath, which is the main bottleneck that limits the design to 72.8 MHz
- Use more BRAM for the S-boxes (right now, only 3.3% is used), to free LUTs which would allow us to fit additional crypto engines
- Process 16 bits per step in the GF(2^128) multiplier instead of the current 8

## Repository layout

| Folder | Content |
|---|---|
| `vhdl/crypto` | Top-level `crypto` entity, CAST-256 core, GCM/GHASH, testbenches, synthesis files |
| `vhdl/axi_slave` | AXI4-Lite slave and register bank |
| `vhdl/dma` | DMA engine (read and write) on the AXI master interface |
| `driver` | ARM Linux driver, host-side tests and demo |
| `tcl_files` | Vivado scripts (IP packaging, block design, implementation) |
| `doc` | CAST-256 and GCM specifications |
| `report` | Final report, diagrams, timing and utilization reports |

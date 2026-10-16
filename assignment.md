<!-- MAIN-ONLY: DO NOT MODIFY THIS FILE

Copyright © Telecom Paris
Copyright © Renaud Pacalet (renaud.pacalet@telecom-paris.fr)

This file must be used under the terms of the CeCILL. This source
file is licensed as described in the file COPYING, which you should
have received as part of this distribution. The terms are also
available at:
https://cecill.info/licences/Licence_CeCILL_V2.1-en.html
-->

The final project of the DigitalSystems course

---

[TOC]

---

# Summary

The goal of the project is to implement a complete hardware and software system for Authenticated Encryption with Associated Data (AEAD).
The input messages and output messages are stored in the external memory.
A hardware accelerator mapped in the FPGA fabric of the Zynq core is used to speed up the cryptographic operations.
The software part that runs on the ARM processor stores a message to encrypt or decrypt in memory.
It then configures the hardware accelerator by storing parameters in its interface registers (secret key, initialization vector, base addresses and lengths of input/output messages, ...)

The software launches the processing and the hardware accelerator runs autonomously until the complete message has been processed and the output message stored in memory.
The software controls the hardware accelerator thanks to one more interface register: a control and status register which content modifies the behavior of the accelerator (soft reset, freeze...), and reflects the current state of the accelerator (busy or not, error situations...)

# Evaluation

The project accounts for 25% of the final grade.
All members of the group will get the same grade.
It will be evaluated based on your source code and your report which you will write in markdown format in the `/REPORT.md` file.
Do not neglect the report, it will have a significant weight:

- Provide block diagrams with a clear identification of the registers and of the combinatorial parts; name the registers, explain what the combinatorial parts do.
- Provide state diagrams and detailed explanations for your state machines.
- Explain what each VHDL source file contains and what its role is in the global picture.
- Detail and motivate your design choices (partitioning, scheduling of operations...)
- Explain how you validated each part.
- Comment your synthesis results (maximum clock frequency, resource usage...)
- Provide an overview of the performance of your cryptographic accelerator (e.g., in Mb/s).
- Document the companion software components you developed (drivers, scripts, libraries...)
- Provide a user documentation showing how to use your cryptographic accelerator and its companion software components.
- ...

The deadline for the submission of source codes and report is the day **before** the written exam at 23:59.
It is a sharp deadline after which the repository will become read-only and there will be no way to modify anything any more.
Your source codes and your report must be pushed before the deadline in a branch named `final` of your project's git repository.
Please check twice that you did not forget anything in another branch, the `final` branch is the only branch that will be considered.

# Use of existing resources

Smart engineers optimize their work by reusing what can reasonably be reused and by using the right tools to increase their productivity.
Smart reuse of existing resources is thus encouraged and will be rewarded if and only if:

- You cite the original source, explain why you decided to use it, what you changed, why and how.
- It is **not** parts of the work of other groups, even after obfuscation, renaming of user identifiers...
  Plagiarism is not accepted.
  
About VHDL code that you may find on Internet: be careful, my experience shows that most of it was written by students like you, not by experts.
A significant proportion does not work at all and contains basic errors showing that the authors did not really understand digital hardware design and/or hardware description languages like VHDL.
Another significant proportion is written at a disappointing low level (e.g., one entity/architecture pair for any 2 inputs multiplexer).
Sometimes the VHDL code you find was generated automatically from gate-level entry GUI tools, automatically translated into VHDL from another language, or from a netlist obtained after logic synthesis.
So, before reusing such code, please look at it carefully and ask yourself if it's really worth reusing.

A validated VHDL design with its simulation environment is of much higher value than a not validated VHDL design without a simulation environment.
So, try to also design simulation environments and to validate what you did by simulation.

# Use of AI

Smart engineers also optimize their work by using the right tools to increase their productivity.
The use of AI is accepted and even encouraged (being able to efficiently use AI is a valuable skill) but:

- Do not let the AI do the thinking, it is a deadly trap.
  If you discover that you don't understand the design any more, it is time to step back and recover the control of operations.
- If you use AI for a task make it clear in your report and provide a complete description of your interactions (prompts, agents, obtained results, what was wrong with them, how you iterated to fix...)
- You are 100% responsible for the results.
  If your coding AI generates bogus or low quality code it is your responsibility.
  If the result does not work as expected it is your responsibility.

Note: you can also write your final report with an AI but with the same reservations as for the code.
In particular, if parts of the report are nonsensical or have nothing to do with your design, it is your responsibility.

# Functional specifications

The hardware accelerator is named `crypto`.
It communicates with its environment with a 32-bits AXI4 lite target interface `s0_axi` and a 32-bits AXI4 lite initiator interface `m0_axi`.
It receives parameters and commands from `s0_axi`.
The environment also uses `s0_axi` to read status information about `crypto`.
`crypto` reads the input message and writes the encrypted message through `m0_axi` (it is what is called a Direct Memory Access (DMA) capable peripheral).

## Encryption / decryption

`crypto` implements the AEAD according the Galois/Counter Mode (GCM) specified in the NIST Special Publication 800-38D (which can be found in the `doc` subdirectory), with the following restrictions:

- 96 bits (12 bytes) Initialization Vectors (IV)
- Between 0 and 1GB of Additional Authenticated Data (AAD), in multiples of 128 bits (16 bytes)
- Between 0 and 1GB of plaintext, in multiples of 128 bits (16 bytes)
- 128 bits (16 bytes) authentication tags

The symmetric block cipher used is denoted BC in the following.
Its specification can be found in the `doc` subdirectory of your dedicated git repository.
Different block ciphers are allocated to the different groups but all block ciphers have 128, 192 or 256 bits secret keys and 128 bits blocks.
In case your block cipher supports other key or block lengths, ignore them.
In GCM the underlying block cipher is used only to encrypt, you can thus safely ignore the decryption part of the specification of your block cipher.
BC can be considered as a function of two parameters, the key K and the input block P; it returns the 128 bits encrypted block BC(K, P).

## The `s0_axi` 32-bits AXI4 lite target interface

The `s0_axi` 32-bits AXI4 lite target interface is used by the environment to access the interface registers of `crypto`.
The address buses are 12-bits wide (the minimum supported by Xilinx tools).
The corresponding 4kB (4096) address space must contain:

- the secret key K (16, 24 or 32 bytes)
- the Initialization Vector IV (12 bytes)
- the AAD base address (4 bytes)
- the AAD byte length (4 bytes, multiple of 16)
- the plaintext base address (4 bytes)
- the plaintext byte length (4 bytes, multiple of 16)
- the ciphertext base address (4 bytes)
- the ciphertext byte length (4 bytes, multiple of 16)
- the tag (16 bytes)
- the control and status register (4 bytes)

This leaves 4008 unmapped bytes.
You can add more interface registers in the unmapped region if you wish (debugging, timer for performance measurements...)
CPU read or write accesses to unmapped addresses shall receive a DECERR response.

## The `m0_axi` 32-bits AXI4 lite initiator interface

The `m0_axi` 32-bits AXI4 lite initiator interface is used by `crypto` to read the input message and to write the output message from/to memory.
The address buses are 30-bits wide, that is a total address space of 1GB.
The input message and the output message are stored somewhere in this address space.
Only the output ciphertext part is written in memory: the AAD part of the input is read to compute the authentication tag but not written back in memory, 

# Interface specifications

The interface of `crypto` is the following:

| Name             | Type                             | Direction | Description                                                |
| :----            | :----                            | :----     | :----                                                      |
| `aclk`           | `std_ulogic`                     | in        | system clock                                               |
| `aresetn`        | `std_ulogic`                     | in        | **synchronous** active **low** reset                       |
| `s0_axi_araddr`  | `std_ulogic_vector(11 downto 0)` | in        | read address from CPU (12 bits = 4kB)                      |
| `s0_axi_arvalid` | `std_ulogic`                     | in        | read address valid from CPU                                |
| `s0_axi_arready` | `std_ulogic`                     | out       | read address acknowledge to CPU                            |
| `s0_axi_awaddr`  | `std_ulogic_vector(11 downto 0)` | in        | write address from CPU (12 bits = 4kB)                     |
| `s0_axi_awvalid` | `std_ulogic`                     | in        | write address valid flag from CPU                          |
| `s0_axi_awready` | `std_ulogic`                     | out       | write address acknowledge to CPU                           |
| `s0_axi_wdata`   | `std_ulogic_vector(31 downto 0)` | in        | write data from CPU                                        |
| `s0_axi_wstrb`   | `std_ulogic_vector(3 downto 0)`  | in        | write byte enables from CPU                                |
| `s0_axi_wvalid`  | `std_ulogic`                     | in        | write data and byte enables valid from CPU                 |
| `s0_axi_wready`  | `std_ulogic`                     | out       | write data and byte enables acknowledge to CPU             |
| `s0_axi_rdata`   | `std_ulogic_vector(31 downto 0)` | out       | read data response to CPU                                  |
| `s0_axi_rresp`   | `std_ulogic_vector(1 downto 0)`  | out       | read status response (OKAY, SLVERR or DECERR) to CPU       |
| `s0_axi_rvalid`  | `std_ulogic`                     | out       | read data and status response valid flag to CPU            |
| `s0_axi_rready`  | `std_ulogic`                     | in        | read response acknowledge from CPU                         |
| `s0_axi_bresp`   | `std_ulogic_vector(1 downto 0)`  | out       | write status response (OKAY, SLVERR or DECERR) to CPU      |
| `s0_axi_bvalid`  | `std_ulogic`                     | out       | write status response valid to CPU                         |
| `s0_axi_bready`  | `std_ulogic`                     | in        | write response acknowledge from CPU                        |
| `m0_axi_araddr`  | `std_ulogic_vector(29 downto 0)` | out       | read address to memory (30 bits = 1GB)                     |
| `m0_axi_arvalid` | `std_ulogic`                     | out       | read address valid to memory                               |
| `m0_axi_arready` | `std_ulogic`                     | in        | read address acknowledge from memory                       |
| `m0_axi_awaddr`  | `std_ulogic_vector(29 downto 0)` | out       | write address to memory (30 bits = 1GB)                    |
| `m0_axi_awvalid` | `std_ulogic`                     | out       | write address valid flag to memory                         |
| `m0_axi_awready` | `std_ulogic`                     | in        | write address acknowledge from memory                      |
| `m0_axi_wdata`   | `std_ulogic_vector(31 downto 0)` | out       | write data to memory                                       |
| `m0_axi_wstrb`   | `std_ulogic_vector(3 downto 0)`  | out       | write byte enables to memory                               |
| `m0_axi_wvalid`  | `std_ulogic`                     | out       | write data and byte enables valid to memory                |
| `m0_axi_wready`  | `std_ulogic`                     | in        | write data and byte enables acknowledge from memory        |
| `m0_axi_rdata`   | `std_ulogic_vector(31 downto 0)` | in        | read data response from memory                             |
| `m0_axi_rresp`   | `std_ulogic_vector(1 downto 0)`  | in        | read status response (OKAY, SLVERR or DECERR) from memory  |
| `m0_axi_rvalid`  | `std_ulogic`                     | in        | read data and status response valid flag from memory       |
| `m0_axi_rready`  | `std_ulogic`                     | out       | read response acknowledge to memory                        |
| `m0_axi_bresp`   | `std_ulogic_vector(1 downto 0)`  | in        | write status response (OKAY, SLVERR or DECERR) from memory |
| `m0_axi_bvalid`  | `std_ulogic`                     | in        | write status response valid from memory                    |
| `m0_axi_bready`  | `std_ulogic`                     | out       | write response acknowledge to memory                       |
| `irq`            | `std_ulogic`                     | out       | interrupt request to CPU                                   |
| `sw`             | `std_ulogic_vector(3 downto 0)`  | in        | wired to the four user slide switches                      |
| `btn`            | `std_ulogic_vector(3 downto 0)`  | in        | wired to the four user press buttons                       |
| `led`            | `std_ulogic_vector(3 downto 0)`  | out       | wired to the four user LEDs                                |

The slide switches, press buttons and LEDs have no specified role, use them as you wish (debugging...)
The entity declaration is already coded in `/vhdl/crypto/crypto.vhd`.
Please do not modify this entity declaration.

# Performance specifications

Try to implement the most powerful accelerator you can (multiple processing rounds per clock cycle, pipelining, other types of parallel architectures...)
Remember that the performance also depends on the clock frequency: computing twice more in a twice longer clock period does not change the processing power.
The performance on the `s0_axi` target interface is not critical but things are different on the `m0_axi` initiator interface where the accesses shall be optimized in order to not slow down the processing.
Read and write operations shall probably be parallel, read and write requests shall probably not be delayed while waiting for responses...

Note that with a 32-bits wide `m0_axi` interface, even if it is optimized, reading or writing a 128 bits block takes at least 4 clock cycles.
When targeting the maximum performance for your hardware accelerator do not try to go below 4 clock cycles to process a block, it would be a waste.

And remember that the resources in the FPGA fabric are limited.
Before designing a super-sophisticated deeply pipelined architecture check that it fits...

<!-- vim: set tabstop=4 softtabstop=4 shiftwidth=4 expandtab textwidth=0: -->

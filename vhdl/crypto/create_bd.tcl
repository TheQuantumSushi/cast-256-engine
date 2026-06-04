# create_bd.tcl
# Creates a Vivado project for the Zybo Z7-10, builds the block design that
# wires the Zynq PS to the crypto IP, then runs synthesis → implementation →
# bitstream in a single script.
#
# Prerequisites:
#   1. Run package_ip.tcl first  (generates ./crypto_ip/)
#   2. Digilent board files installed (optional — see NOTE below)
#   3. Vivado 2019.2 or later in batch mode
#
# Run from vhdl/crypto/:
#   vivado -mode batch -source create_bd.tcl
#
# Outputs written to vhdl/crypto/:
#   crypto.bit  — FPGA bitstream  (program via Hardware Manager)
#   crypto.xsa  — hardware handoff (PetaLinux / Vitis)
#
# NOTE: If Digilent board files are not installed the PS7 will be configured
# with a minimal manual parameter set that works for Zybo Z7-10.  Install
# board files from https://github.com/Digilent/vivado-boards for full preset.
#
# Block design topology:
#
#   PS7 M_AXI_GP0 (AXI4)
#       → axi_smc_ctrl (SmartConnect 1:1)     ← AXI4 → AXI4-Lite
#       → crypto_0 s0_axi (AXI4-Lite, 12-bit addr)   @0x43C0_0000
#
#   crypto_0 m0_axi (AXI4-Lite, 30-bit addr)
#       → axi_smc_dma (SmartConnect 1:1)      ← AXI4-Lite → AXI4 (handled internally)
#       → PS7 S_AXI_GP0                               DDR: 0x0000_0000 / 512 MB
#
#   S_AXI_GP0 is the low-bandwidth general-purpose slave — lower throughput than
#   HP0 but accepts AXI4-Lite masters via SmartConnect without a separate
#   Protocol Converter IP.  Sufficient for the single-word DMA transfers this
#   design issues.
#
#   PS7 FCLK_CLK0 (100 MHz) ─── all fabric clocks
#   PS7 FCLK_RESET0_N → proc_sys_reset_0 → crypto_0 aresetn
#   crypto_0 irq → xlconcat_irq → PS7 IRQ_F2P[0]

# ── Parameters ────────────────────────────────────────────────────────────────
set part       xc7z010clg400-1
set board_part digilentinc.com:zybo-z7-10:part0:1.1
set proj_name  crypto_zybo
set proj_dir   ./vivado_proj
set bd_name    crypto_bd
set ip_repo    [file normalize ./crypto_ip]

# ── Guard ─────────────────────────────────────────────────────────────────────
if {![file exists ${ip_repo}/component.xml]} {
    error "crypto IP not found at ${ip_repo}/component.xml\n  Run:  vivado -mode batch -source package_ip.tcl"
}

# ── Helper: add IP cell using latest installed VLNV ───────────────────────────
proc add_ip {cell_name ip_name} {
    set defs [lsort [get_ipdefs -filter "NAME == ${ip_name}"]]
    if {${defs} eq {}} { error "IP not in catalog: ${ip_name}" }
    set vlnv [lindex ${defs} end]
    create_bd_cell -type ip -vlnv ${vlnv} ${cell_name}
    puts "  + ${cell_name}  (${vlnv})"
}

# ── Create project ────────────────────────────────────────────────────────────
puts "\n================================================"
puts " Creating Vivado project: ${proj_name}"
puts "================================================"
create_project ${proj_name} ${proj_dir} -part ${part} -force
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# Board preset (requires Digilent board files)
set have_board 0
if {[catch {set_property board_part ${board_part} [current_project]} err]} {
    puts "NOTE: Zybo board files not installed — PS7 will use manual configuration."
    puts "      (${err})"
} else {
    set have_board 1
    puts "Board preset applied: ${board_part}"
}

# Register the packaged crypto IP
set_property ip_repo_paths ${ip_repo} [current_project]
update_ip_catalog -rebuild
puts "IP catalog updated — crypto IP registered from ${ip_repo}"

# ── Block design ──────────────────────────────────────────────────────────────
puts "\n================================================"
puts " Building block design: ${bd_name}"
puts "================================================"
create_bd_design ${bd_name}
current_bd_design ${bd_name}

# ── Zynq PS7 ──────────────────────────────────────────────────────────────────
add_ip processing_system7_0 processing_system7

if {${have_board}} {
    # Board preset fills in DDR, MIO, UART, Ethernet parameters automatically
    apply_bd_automation \
        -rule   xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR"  apply_board_preset "1" \
                 Master "Disable"  Slave "Disable"} \
        [get_bd_cells processing_system7_0]
} else {
    # Minimal manual configuration for Zybo Z7-10 DDR3 / 667 MHz
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/DDR]
    make_bd_intf_pins_external [get_bd_intf_pins processing_system7_0/FIXED_IO]
    set_property -dict [list \
        CONFIG.PCW_UIPARAM_DDR_PARTNO          {MT41K256M16 RE-125} \
        CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ  {33.333333}          \
        CONFIG.PCW_APU_PERIPHERAL_FREQMHZ      {666.666667}         \
        CONFIG.PCW_UART0_PERIPHERAL_ENABLE     {1}                  \
        CONFIG.PCW_UART0_UART0_IO              {MIO 14 .. 15}       \
    ] [get_bd_cells processing_system7_0]
}

# Enable the interfaces we need
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0            {1}   \
    CONFIG.PCW_USE_S_AXI_GP0            {1}   \
    CONFIG.PCW_USE_FABRIC_INTERRUPT     {1}   \
    CONFIG.PCW_IRQ_F2P_INTR             {1}   \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
] [get_bd_cells processing_system7_0]

# ── Processing System Reset ───────────────────────────────────────────────────
add_ip proc_sys_reset_0 proc_sys_reset

# ── Crypto IP ─────────────────────────────────────────────────────────────────
create_bd_cell -type ip -vlnv kah:crypto:crypto:1.0 crypto_0
puts "  + crypto_0  (kah:crypto:crypto:1.0)"

# ── AXI SmartConnect — control path: M_AXI_GP0 (AXI4) → s0_axi (AXI4-Lite) ──
add_ip axi_smc_ctrl smartconnect
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells axi_smc_ctrl]

# ── AXI SmartConnect — DMA path: m0_axi (AXI4-Lite) → S_AXI_GP0 ─────────────
# SmartConnect handles the AXI4-Lite → AXI4 protocol conversion internally,
# so no separate Protocol Converter IP is required.
add_ip axi_smc_dma smartconnect
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells axi_smc_dma]

# ── xlconcat: single irq bit → PS7 IRQ_F2P vector ────────────────────────────
add_ip xlconcat_irq xlconcat
set_property CONFIG.NUM_PORTS {1} [get_bd_cells xlconcat_irq]

# ── Clock connections (all from FCLK_CLK0 = 100 MHz) ─────────────────────────
set fclk [get_bd_pins processing_system7_0/FCLK_CLK0]
foreach pin {
    processing_system7_0/M_AXI_GP0_ACLK
    processing_system7_0/S_AXI_GP0_ACLK
    proc_sys_reset_0/slowest_sync_clk
    crypto_0/aclk
    axi_smc_ctrl/aclk
    axi_smc_dma/aclk
} {
    connect_bd_net ${fclk} [get_bd_pins ${pin}]
}

# ── Reset connections ─────────────────────────────────────────────────────────
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]

set periph_rst [get_bd_pins proc_sys_reset_0/peripheral_aresetn]
set interc_rst [get_bd_pins proc_sys_reset_0/interconnect_aresetn]

connect_bd_net ${periph_rst} [get_bd_pins crypto_0/aresetn]
connect_bd_net ${interc_rst} [get_bd_pins axi_smc_ctrl/aresetn]
connect_bd_net ${interc_rst} [get_bd_pins axi_smc_dma/aresetn]

# ── AXI control path: M_AXI_GP0 → axi_smc_ctrl → crypto s0_axi ──────────────
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_smc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M00_AXI] \
                    [get_bd_intf_pins crypto_0/s0_axi]

# ── AXI DMA path: crypto m0_axi → axi_smc_dma → S_AXI_GP0 ──────────────────
connect_bd_intf_net [get_bd_intf_pins crypto_0/m0_axi] \
                    [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] \
                    [get_bd_intf_pins processing_system7_0/S_AXI_GP0]

# ── Interrupt path: irq → xlconcat → IRQ_F2P[0] ──────────────────────────────
connect_bd_net [get_bd_pins crypto_0/irq]      [get_bd_pins xlconcat_irq/In0]
connect_bd_net [get_bd_pins xlconcat_irq/dout] \
               [get_bd_pins processing_system7_0/IRQ_F2P]

# ── Board I/O: sw[3:0], btn[3:0], led[3:0] ───────────────────────────────────
create_bd_port -dir I -from 3 -to 0 -type data sw
create_bd_port -dir I -from 3 -to 0 -type data btn
create_bd_port -dir O -from 3 -to 0 -type data led

connect_bd_net [get_bd_ports sw]          [get_bd_pins crypto_0/sw]
connect_bd_net [get_bd_ports btn]         [get_bd_pins crypto_0/btn]
connect_bd_net [get_bd_pins crypto_0/led] [get_bd_ports led]

# ── Address editor ────────────────────────────────────────────────────────────
# Control slave: 0x43C0_0000, 4 KB  (matches CRYPTO_BASE_PHYS in sw/driver/)
assign_bd_address \
    -offset 0x43C00000 -range 4K \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs crypto_0/s0_axi/reg0] -force

# DMA master: full low DDR window via S_AXI_GP0 (512 MB from 0x0)
assign_bd_address \
    -offset 0x00000000 -range 512M \
    -target_address_space [get_bd_addr_spaces crypto_0/m0_axi] \
    [get_bd_addr_segs processing_system7_0/S_AXI_GP0/GP0_DDR_LOWOCM] -force

# ── Validate and save ─────────────────────────────────────────────────────────
validate_bd_design
save_bd_design
puts "Block design validated and saved."

# ── Generate HDL wrapper ──────────────────────────────────────────────────────
make_wrapper -files [get_files ${bd_name}.bd] -top
set wrapper \
    ${proj_dir}/${proj_name}.srcs/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.vhd
add_files -norecurse ${wrapper}
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ── XDC constraints ───────────────────────────────────────────────────────────
# Constrains sw, btn, led physical pins.  Clock and reset are constrained by
# the block design (PS FCLK_CLK0 / proc_sys_reset).
add_files -fileset constrs_1 -norecurse ./crypto.xdc
puts "Constraints added: crypto.xdc"

# ── Synthesis ─────────────────────────────────────────────────────────────────
puts "\n================================================"
puts " Synthesis ..."
puts "================================================"
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed — check ${proj_dir}/${proj_name}.runs/synth_1/*.log"
}
puts "Synthesis complete."

# ── Implementation + bitstream ────────────────────────────────────────────────
puts "\n================================================"
puts " Implementation + write_bitstream ..."
puts "================================================"
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed — check ${proj_dir}/${proj_name}.runs/impl_1/*.log"
}
puts "Implementation complete."

# ── Copy bitstream ────────────────────────────────────────────────────────────
set impl_dir ${proj_dir}/${proj_name}.runs/impl_1
set bit_src  [glob -nocomplain ${impl_dir}/*_wrapper.bit]
if {${bit_src} ne {}} {
    file copy -force [lindex ${bit_src} 0] ./crypto.bit
}

# ── Hardware handoff for PetaLinux / Vitis ────────────────────────────────────
if {[catch {
    write_hw_platform -fixed -force -include_bit -file ./crypto.xsa
} err]} {
    # Vivado < 2019.2 uses write_sysdef
    set hwdef [glob -nocomplain ${impl_dir}/*.hwdef]
    if {${hwdef} ne {}} {
        write_sysdef -hwdef [lindex ${hwdef} 0] -bitfile ./crypto.bit \
                     -file ./crypto.hdf
        puts "Hardware handoff (legacy HDF): ./crypto.hdf"
    }
} else {
    puts "Hardware handoff: ./crypto.xsa"
}

puts "\n================================================"
puts " Build complete!"
puts ""
puts "   Bitstream : ./crypto.bit"
puts "   Hardware  : ./crypto.xsa"
puts ""
puts " Next steps:"
puts "   A. Program FPGA:"
puts "        Vivado Hardware Manager → Open Target → Program Device → crypto.bit"
puts ""
puts "   B. Cross-compile driver (requires arm-linux-gnueabihf-gcc):"
puts "        cd sw/driver && make tests_arm"
puts "        # produces: sw/driver/crypto_tests_arm"
puts ""
puts "   C. Deploy and run on Zybo:"
puts "        scp sw/driver/crypto_tests_arm root@<zybo-ip>:/root/"
puts "        ssh root@<zybo-ip> ./crypto_tests_arm"
puts "================================================"

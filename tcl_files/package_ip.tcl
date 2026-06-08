# package_ip.tcl
# Packages the crypto entity and all VHDL dependencies as a Vivado IP core
# so that create_bd.tcl can drop it into the block design.
#
# Run ONCE before create_bd.tcl (from any directory):
#   vivado -mode batch -source tcl_files/package_ip.tcl
#
# Output: vhdl/crypto/crypto_ip/component.xml  (Vivado IP catalog entry)
#
# Re-run: delete vhdl/crypto/crypto_ip/ first.

set script_dir [file dirname [file normalize [info script]]]
set vhdl_root  [file normalize ${script_dir}/../vhdl]
set vhdl_dir   [file normalize ${vhdl_root}/crypto]
set ip_root    [file normalize ${vhdl_dir}/crypto_ip]
set tmp_prj    [file normalize ${vhdl_dir}/pkg_tmp]
set part       xc7z010clg400-1

if {[file exists ${ip_root}/component.xml]} {
    puts "IP already packaged at ${ip_root} - delete the folder to re-package."
    return
}

# ── Temporary project ─────────────────────────────────────────────────────────
create_project -force pkg_tmp ${tmp_prj} -part ${part}
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# ── Source files (strict dependency order) ────────────────────────────────────
foreach f {
    cast256/cast256_pkg.vhd
    cast256/cast256_ks.vhd
    cast256/cast256_enc.vhd
    cast256/cast256.vhd
    gcm/gcm_pkg.vhd
    gcm/gf128_mul.vhd
    gcm/ghash.vhd
    gcm/gcm.vhd
    crypto.vhd
} { add_files -norecurse ${vhdl_dir}/${f} }

foreach f {
    axi_slave/axi_slave_pkg.vhd
    axi_slave/axi_slave_wr.vhd
    axi_slave/axi_slave_rd.vhd
    axi_slave/axi_slave.vhd
    dma/fifo.vhd
    dma/block_join.vhd
    dma/block_split.vhd
    dma/dma_read_engine.vhd
    dma/dma_write_engine.vhd
    dma/dma_engine.vhd
} { add_files -norecurse ${vhdl_root}/${f} }
set_property file_type {VHDL 2008} [get_files -filter {FILE_TYPE == VHDL}]
set_property top crypto [current_fileset]
update_compile_order -fileset sources_1

# ── Package as IP ─────────────────────────────────────────────────────────────
puts "\nPackaging crypto IP -> ${ip_root} ..."
ipx::package_project \
    -root_dir    ${ip_root} \
    -vendor      kah        \
    -library     crypto     \
    -taxonomy    /UserIP    \
    -import_files

set ip [ipx::current_core]

# ── IP metadata ───────────────────────────────────────────────────────────────
set_property vendor              kah                                         ${ip}
set_property library             crypto                                      ${ip}
set_property name                crypto                                      ${ip}
set_property version             1.0                                         ${ip}
set_property display_name       "CAST-256/GCM AXI Accelerator"              ${ip}
set_property description        "AXI4-Lite CAST-256-GCM engine for Zynq-7000" ${ip}
set_property vendor_display_name kah                                         ${ip}

# ── Fix AXI address widths ────────────────────────────────────────────────────
# Vivado auto-infers 32-bit; our slave uses 12-bit and DMA master uses 30-bit.
foreach {ifname aw} {s0_axi 12  m0_axi 30} {
    set bif [ipx::get_bus_interfaces ${ifname} -of_objects ${ip}]
    if {${bif} eq {}} {
        puts "WARNING: bus interface ${ifname} not auto-detected - verify port naming"
        continue
    }
    catch {ipx::remove_bus_parameter ADDR_WIDTH ${bif}}
    set_property value ${aw} [ipx::add_bus_parameter ADDR_WIDTH ${bif}]
    puts "  ${ifname} ADDR_WIDTH -> ${aw}"
}

# ── Interrupt interface for irq port ──────────────────────────────────────────
# Marks irq as an interrupt master so Vivado can connect it to PS7 IRQ_F2P.
set irq_if [ipx::add_bus_interface irq ${ip}]
set_property abstraction_type_vlnv xilinx.com:signal:interrupt_rtl:1.0 ${irq_if}
set_property bus_type_vlnv         xilinx.com:signal:interrupt:1.0     ${irq_if}
set_property interface_mode        master                                ${irq_if}
set_property display_name          Interrupt                             ${irq_if}
ipx::add_port_map INTERRUPT ${irq_if}
set_property physical_name irq \
    [ipx::get_port_maps INTERRUPT -of_objects ${irq_if}]

# ── Save and validate ─────────────────────────────────────────────────────────
ipx::create_xgui_files ${ip}
ipx::update_checksums  ${ip}
ipx::save_core         ${ip}
ipx::check_integrity -quiet ${ip}

puts "\n================================================"
puts " IP packaged -> ${ip_root}/component.xml"
puts " Next: vivado -mode batch -source tcl_files/create_bd.tcl"
puts "================================================"

close_project
file delete -force ${tmp_prj}

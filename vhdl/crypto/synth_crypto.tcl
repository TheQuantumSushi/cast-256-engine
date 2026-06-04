# synth_crypto.tcl
# Out-of-context synthesis of the crypto fabric (CAST-256-GCM accelerator).
# Purpose: fast timing and utilization analysis WITHOUT the Zynq PS context.
#
# Run from vhdl/crypto/:
#   vivado -mode batch -source synth_crypto.tcl
#
# Outputs (written to vhdl/crypto/synth/):
#   timing_summary.rpt   -- critical path and Fmax
#   utilization.rpt      -- LUT / FF / DSP / BRAM usage
#   utilization_hier.rpt -- per-instance breakdown
#
# NOTE — Full Zybo board build (bitstream + XSA):
#   Use create_bd.tcl instead.  OOC synthesis (-mode out_of_context) cannot
#   drive place/route because it excludes the Zynq PS and DDR/FIXED_IO ports.
#   Steps: vivado -mode batch -source package_ip.tcl
#          vivado -mode batch -source create_bd.tcl

# ── Target device ──────────────────────────────────────────────────────────────
set part "xc7z010clg400-1"

# ── Clock target ──────────────────────────────────────────────────────────────
set clk_period_ns 10.0   ;# 100 MHz target

# ── Output directory ──────────────────────────────────────────────────────────
set out_dir synth
file mkdir $out_dir

# ── Source files (read in strict dependency order) ────────────────────────────
set src_files {
    cast256/cast256_pkg.vhd
    cast256/cast256_ks.vhd
    cast256/cast256_enc.vhd
    cast256/cast256.vhd

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

    gcm/gcm_pkg.vhd
    gcm/gf128_mul.vhd
    gcm/ghash.vhd
    gcm/gcm.vhd

    crypto.vhd
}

puts "================================================"
puts " crypto synthesis  --  part: $part"
puts " Clock target: $clk_period_ns ns  ([expr {1000.0/$clk_period_ns}] MHz)"
puts "================================================"

foreach f $src_files {
    puts " reading: $f"
    read_vhdl -vhdl2008 $f
}

puts "\n Synthesizing..."
synth_design \
    -top  crypto \
    -part $part  \
    -mode out_of_context

# Clock constraint for timing analysis
create_clock -period $clk_period_ns -name aclk [get_ports aclk]

# ── Reports ───────────────────────────────────────────────────────────────────
puts "\n Writing reports to $out_dir/ ..."

report_timing_summary \
    -delay_type max \
    -report_unconstrained \
    -check_timing_verbose \
    -max_paths 10 \
    -input_pins \
    -file $out_dir/timing_summary.rpt

report_utilization \
    -file $out_dir/utilization.rpt

report_utilization \
    -hierarchical \
    -file $out_dir/utilization_hier.rpt

# ── Extract key numbers and print summary ─────────────────────────────────────
set tp      [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns     [get_property SLACK $tp]
set cp_ns   [expr {$clk_period_ns - $wns}]
set fmax    [expr {1000.0 / $cp_ns}]

# Pull utilization primitives
set luts    [get_property USED [get_cells -hierarchical -filter {REF_NAME =~ LUT*}   ]]
set ffs     [get_property USED [get_cells -hierarchical -filter {REF_NAME =~ FF*}    ]]

# Safer utilization extraction from the report
proc grep_rpt {file pattern} {
    set fh [open $file r]
    set lines [split [read $fh] "\n"]
    close $fh
    foreach l $lines {
        if {[regexp $pattern $l m]} { return $m }
    }
    return "n/a"
}

puts "\n================================================"
puts " TIMING SUMMARY"
puts "================================================"
puts [format "  Worst Negative Slack : %+.3f ns" $wns]
puts [format "  Critical path        :  %.3f ns" $cp_ns]
puts [format "  Estimated Fmax       :  %.1f MHz" $fmax]
if {$wns >= 0} {
    puts "  Status               :  TIMING MET at $clk_period_ns ns"
} else {
    set slack_pct [expr {abs($wns) / $clk_period_ns * 100.0}]
    puts [format "  Status               :  TIMING VIOLATED (%.1f%% over budget)" $slack_pct]
}

puts "\n================================================"
puts " UTILIZATION  (xc7z010clg400-1 resource budget)"
puts "================================================"
# Parse from the utilization report for cleaner numbers
set u [open $out_dir/utilization.rpt r]
set urpt [read $u]
close $u

foreach {label pattern avail} {
    "Slice LUTs  "  {Slice LUTs\s*\|\s*(\d+)} 17600
    "Slice Regs  "  {Slice Registers\s*\|\s*(\d+)} 35200
    "DSPs        "  {DSPs\s*\|\s*(\d+)} 80
    "Block RAMs  "  {Block RAM Tile\s*\|\s*(\d+)} 60
} {
    if {[regexp $pattern $urpt m val]} {
        set pct [expr {$val * 100.0 / $avail}]
        puts [format "  %-14s %5s / %-6s  (%5.1f%%)" $label $val $avail $pct]
    }
}

puts "\n Full reports:"
puts "   $out_dir/timing_summary.rpt"
puts "   $out_dir/utilization.rpt"
puts "   $out_dir/utilization_hier.rpt"
puts "================================================"

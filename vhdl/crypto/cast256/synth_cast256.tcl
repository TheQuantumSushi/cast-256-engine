# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  synth_cast256.tcl                                                       ║
# ║  Synthesize the cast256 core in isolation and report timing/utilization. ║
# ║                                                                          ║
# ║  Run from the directory that contains the .vhd source files:             ║
# ║    vivado -mode batch -source synth_cast256.tcl                          ║
# ║                                                                          ║
# ║  Outputs (written to the same directory):                                ║
# ║    timing_summary.rpt   — critical path and Fmax                         ║
# ║    utilization.rpt      — LUT / FF / BRAM resource usage                 ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Target device ─────────────────────────────────────────────────────────────
# Zybo Z7-10 : xc7z010clg400-1
# Zybo Z7-20 : xc7z020clg400-1
# Check your board and update this if needed.
set part "xc7z010clg400-1"

# ── Source files (relative to working directory) ──────────────────────────────
set src_files {
    cast256_pkg.vhd
    cast256_ks.vhd
    cast256_enc.vhd
    cast256.vhd
}

# ── Clock constraint (internal — not reported) ────────────────────────────────
# A reference clock is required for Vivado to compute timing paths and derive
# Fmax. The period value only affects how WNS is expressed; Fmax is independent
# of it (Fmax = 1000 / critical_path_ns). The value is not surfaced in output.
set clk_period_ns 10.0

# ─────────────────────────────────────────────────────────────────────────────

puts "================================================"
puts " Synthesizing cast256 for part: $part"
puts "================================================"

# Read all source files
foreach f $src_files {
    read_vhdl -vhdl2008 $f
}

# Synthesize in out-of-context mode: treats cast256 as a standalone block,
# not requiring top-level I/O constraints.
synth_design \
    -top cast256 \
    -part $part \
    -mode out_of_context \
    -verilog_define {} \
    -verbose

# Create a virtual clock on the aclk port so timing analysis has a reference.
# This is what Vivado uses to compute slack and identify the critical path.
create_clock -period $clk_period_ns -name aclk [get_ports aclk]

# ── Reports ───────────────────────────────────────────────────────────────────
puts "\n================================================"
puts " Writing reports..."
puts "================================================"

report_timing_summary \
    -delay_type max \
    -report_unconstrained \
    -check_timing_verbose \
    -max_paths 5 \
    -input_pins \
    -file timing_summary.rpt

report_utilization \
    -file utilization.rpt

set wns              [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set critical_path_ns [expr {$clk_period_ns - $wns}]
set fmax_mhz         [expr {1000.0 / $critical_path_ns}]

puts "\n================================================"
puts " Timing summary"
puts "================================================"
puts [format " Worst slack      : %.3f ns" $wns]
puts [format " Critical path    : %.3f ns" $critical_path_ns]
puts [format " Estimated Fmax   : %.1f MHz" $fmax_mhz]
puts "================================================\n"

puts "Full reports written to:"
puts "  timing_summary.rpt"
puts "  utilization.rpt"
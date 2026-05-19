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

# ── Clock constraint ──────────────────────────────────────────────────────────
# This is the target clock period in nanoseconds.
# Vivado will tell you how much slack you have against this target.
# Positive slack = your design meets timing at this frequency.
# Negative slack = your design is too slow; Fmax is lower than this.
# Start with 10 ns (100 MHz) and adjust based on the results.
set clk_period_ns 10.0

# ─────────────────────────────────────────────────────────────────────────────

puts "================================================"
puts " Synthesizing cast256 for part: $part"
puts " Target clock period          : ${clk_period_ns} ns"
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

# ── Print Fmax estimate to console ────────────────────────────────────────────
# WNS = Worst Negative Slack.
# If WNS >= 0 : design meets timing. Fmax >= 1 / clk_period_ns.
# If WNS <  0 : design does not meet timing.
#               Critical path delay = clk_period_ns - WNS (since WNS is negative,
#               this adds to the period). Fmax = 1 / (clk_period_ns - WNS).
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set critical_path_ns [expr {$clk_period_ns - $wns}]
set fmax_mhz [expr {1000.0 / $critical_path_ns}]

puts "\n================================================"
puts " Timing summary"
puts "================================================"
puts [format " Target period    : %.2f ns  (%.1f MHz)" \
    $clk_period_ns [expr {1000.0 / $clk_period_ns}]]
puts [format " Worst slack      : %.3f ns" $wns]
puts [format " Critical path    : %.3f ns" $critical_path_ns]
puts [format " Estimated Fmax   : %.1f MHz" $fmax_mhz]
if {$wns >= 0} {
    puts " Status           : MEETS TIMING"
} else {
    puts " Status           : DOES NOT MEET TIMING at ${clk_period_ns} ns"
}
puts "================================================\n"

puts "Full reports written to:"
puts "  timing_summary.rpt"
puts "  utilization.rpt"

# ============================================================================
# Vivado non-project build for the Arty A7-100T (roadmap R3.1)
#
#   vivado -mode batch -source fpga/arty_a7_100t/build.tcl -tclargs <repo> <out> [ram_addr_bits]
#
# ram_addr_bits picks the RAM profile, 4 to 15; 15, the default, is the full
# 256 KB of HSI section 5.
#
# Usually run through fpga/arty_a7_100t/build.py, which also hashes the
# bitstream and writes the build manifest. The build stops with an error if
# the mapped design loses what the safety argument depends on, or misses
# timing.
# ============================================================================

set root [file normalize [lindex $argv 0]]
set out  [file normalize [lindex $argv 1]]
set ram_bits [expr {[llength $argv] > 2 ? [lindex $argv 2] : 15}]
set part xc7a100tcsg324-1
set here $root/fpga/arty_a7_100t
file mkdir $out

proc require {cond message} {
  if {![uplevel 1 [list expr $cond]]} {
    error "BUILD CHECK FAILED: $message"
  }
  puts "BUILD CHECK OK: $message"
}

set_part $part

# --- Sources -------------------------------------------------------------------
# NEORV32 in its own order, with the board image in place of the default one
set neorv32 $root/rtl/core/neorv32
set fh [open $neorv32/rtl/file_list_core.f r]
set core_files {}
foreach line [split [read $fh] "\n"] {
  set line [string trim $line]
  if {$line eq "" || [string match "--*" $line]} { continue }
  set path [string map [list {$NEORV32_HOME} $neorv32] $line]
  if {[string match "*neorv32_imem_image.vhd" $path]} { continue }
  lappend core_files $path
}
close $fh
read_vhdl -vhdl2008 -library neorv32 [concat [list $here/board_imem_image.vhd] $core_files]

read_vhdl -vhdl2008 -library lockstep [concat \
  [list $root/config/package_soc_types.vhd] \
  [glob $root/rtl/safety_blocks/*.vhd] \
  [glob $root/rtl/peripherals/*.vhd] \
  [list $root/rtl/lockstep_core.vhd $root/rtl/top_automotive_soc.vhd]]
read_vhdl -vhdl2008 [list $here/arty_a7_top.vhd]
read_xdc $here/arty_a7_100t.xdc

# --- Synthesis -------------------------------------------------------------------
# FSM extraction is off for the whole design: the comparator's and the
# self-test's safe-state encodings must not be re-encoded. Their registers also
# carry fsm_encoding and dont_touch in the RTL. See docs/verification/synthesis.md.
synth_design -top arty_a7_top -part $part -fsm_extraction off -generic g_ram_addr_bits=$ram_bits
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/utilization_synth.txt

# --- Checks on the synthesised design -------------------------------------------
proc flops {pattern} {
  return [llength [get_cells -hier -quiet -filter "IS_SEQUENTIAL && NAME =~ $pattern"]]
}
require {[flops {*i_lockstep_gate/r_current_state_reg*}] == 8} \
  "the comparator state keeps all 8 flip-flops of its encoding"
require {[flops {*i_lockstep_gate/r_fault_latched_reg*}] == 1} \
  "the comparator fault latch is kept"
require {[flops {*i_comparator_self_test/r_result_reg*}] == 8} \
  "the self-test result keeps all 8 flip-flops of its encoding"
require {[llength [get_cells -hier -quiet -filter {NAME =~ *i_cpu_master/*}]] > 0} \
  "core A is in the design"
require {[llength [get_cells -hier -quiet -filter {NAME =~ *i_cpu_checker/*}]] > 0} \
  "core B is in the design"
require {[flops {*i_temporal_diversity/r_bus_reg*}] >= 2 * 70} \
  "core A's bus delay line keeps two stages of the 70 compared bits"
# 72 bits a word, 36 Kib a RAMB36: a profile of 9 or fewer bits may map to
# LUT RAM instead, and is not checked here
set ram_tiles [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36* && NAME =~ *i_ecc_ram*}]
set ram_need  [expr {(72 * (1 << $ram_bits)) / 36864}]
if {$ram_bits >= 10} {
  require {[llength $ram_tiles] >= $ram_need} \
    "the [expr {8 << $ram_bits >> 10}] KB ECC RAM is in block RAM ($ram_need or more RAMB36)"
}

# --- Implementation ----------------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp

report_utilization          -file $out/utilization.txt
report_ram_utilization      -file $out/ram_utilization.txt
report_timing_summary -max_paths 20 -report_unconstrained -file $out/timing_summary.txt
report_cdc -details         -file $out/cdc.txt
report_clock_interaction    -file $out/clock_interaction.txt
report_methodology          -file $out/methodology.txt
report_drc                  -file $out/drc.txt

set setup [get_timing_paths -setup -max_paths 1 -nworst 1]
set hold  [get_timing_paths -hold -max_paths 1 -nworst 1]
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
puts "TIMING WNS=$wns WHS=$whs"
require {$wns >= 0} "setup timing met (WNS $wns ns)"
require {$whs >= 0} "hold timing met (WHS $whs ns)"

# The same structural checks after implementation, which can also optimise
require {[flops {*i_lockstep_gate/r_current_state_reg*}] == 8} \
  "after routing, the comparator state still has 8 flip-flops"
require {[flops {*i_comparator_self_test/r_result_reg*}] == 8} \
  "after routing, the self-test result still has 8 flip-flops"

write_bitstream -force $out/arty_a7_lockstep.bit
puts "BUILD DONE"

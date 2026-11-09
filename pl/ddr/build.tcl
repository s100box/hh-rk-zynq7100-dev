# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Build the RK-ZYNQ7100 PL DDR3 bitstream: the board's second gigabyte of
# DRAM, on banks 33/34, mapped into the PS at 0x4000_0000 through M_AXI_GP0.
#
# Usage:
#   vivado -mode batch -nojournal -nolog -source build.tcl -tclargs [<outdir> [project]]
#
# ⚠ Keep <outdir> short -- Vivado's IP flow hits Windows' 260-character path
# limit and fails without mentioning paths. The default is $RKZ7100_BUILD/ddr,
# or without that C:/rkz7100-build/ddr on Windows and ~/rkz7100-build/ddr
# elsewhere.
#
# Products, copied to <outdir>/:
#   rkz7100_ddr.bit      for JTAG
#   rkz7100_ddr_raw.bin  write_bitstream's -bin_file output, which fpga_manager
#                        REFUSES; run ../bit2bin.py on the .bit for that.

set outdir [lindex $argv 0]
if {$outdir eq ""} {
    if {[info exists env(RKZ7100_BUILD)]} {
        set outdir $env(RKZ7100_BUILD)/ddr
    } elseif {$tcl_platform(platform) eq "windows"} {
        set outdir C:/rkz7100-build/ddr
    } else {
        set outdir [file normalize ~/rkz7100-build/ddr]
    }
}

# A second argument of "project" stops once the project is complete -- IP
# generated, sources and constraints added, top set -- without running
# anything. Open $outdir/proj/ddr.xpr in the Vivado GUI and press Run
# Implementation; what it builds comes from the lists below, so the GUI and
# the batch flow cannot drift apart.
set project_only [expr {[lindex $argv 1] eq "project"}]

set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set part xc7z100ffg900-2
set top  rkz7100_ddr

source [file join $repo linux board ps7_config.tcl]

# Generate boot initialization before creating the PL project. It uses the
# shared boot settings, not the PL-specific overrides applied below.
source [file join $repo linux ps7_init_build.tcl]
rkz7100::generate_ps7_init $outdir

file mkdir $outdir/ip
source [file normalize [file join [file dirname [info script]] ../../../retrosim-build/vivado.tcl]]
retrosim::create_project ddr $outdir/proj $part

# ---------------------------------------------------------------------------
# PS7 -- the same configuration as the Linux PS init, with this design's
# overrides removed from the shared list before it is applied and verified
# (applying them afterward would be undone by the verify pass; see
# ../board/build.tcl).
# ---------------------------------------------------------------------------
create_ip -name processing_system7 -vendor xilinx.com -library ip -version 5.5 \
    -module_name ps7_rkz7100 -dir $outdir/ip
set ps [get_ips ps7_rkz7100]

# GP0 carries the DRAM, so the registers need GP1: GP0's window is exactly the
# 1 GB the DRAM fills, leaving nowhere to decode a second slave.
set overrides [list \
    CONFIG.PCW_USE_M_AXI_GP0        {1} \
    CONFIG.PCW_USE_M_AXI_GP1        {1} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE    {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_S_AXI_HP1        {1} \
    CONFIG.PCW_USE_S_AXI_HP2        {1} \
    CONFIG.PCW_S_AXI_HP1_FREQMHZ    {100} \
    CONFIG.PCW_S_AXI_HP2_FREQMHZ    {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR         {1} \
    CONFIG.PCW_NUM_F2P_INTR_INPUTS  {3} \
]

set settable {}
foreach {k v} $PS7_CONFIG {
    if {[string match CONFIG.PCW_ACT_* $k]} continue
    if {[dict exists $overrides $k]}        continue
    lappend settable $k $v
}
lappend settable {*}$overrides

if {[catch {set_property -dict $settable $ps} err]} {
    puts "WARNING: the one-call PS7 apply was refused: $err"
}
set refused {}
foreach {k v} $settable {
    if {[catch {set got [get_property $k $ps]}] || $got ne $v} {
        if {[catch {set_property $k $v $ps}]} { lappend refused $k }
    }
}
if {[llength $refused]} {
    puts "==== PS7 REFUSED [llength $refused] SETTINGS ===="
    foreach k $refused { puts "  $k" }
    error "PS7 configuration incomplete"
}
generate_target all $ps

# ---------------------------------------------------------------------------
# MIG. Its pin assignment comes from mig.prj, which gen_mig_prj.py builds from
# the master XDC -- MIG reads pins from the project file, not from an XDC.
# ---------------------------------------------------------------------------
set prj [file join $repo pl mig.prj]
if {![file exists $prj]} { error "missing $prj -- run gen_mig_prj.py" }

create_ip -name mig_7series -vendor xilinx.com -library ip \
    -module_name mig_rkz7100 -dir $outdir/ip
set_property -dict [list \
    CONFIG.XML_INPUT_FILE        $prj \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM  {Custom} \
    CONFIG.BOARD_MIG_PARAM       {Custom} \
] [get_ips mig_rkz7100]
generate_target all [get_ips mig_rkz7100]

# ---------------------------------------------------------------------------
# The two AXI converters between GP0 (AXI3, 32-bit, fclk_clk0) and the MIG's
# slave (AXI4, 32-bit, ui_clk). The MIG is GP0's only slave, so there is
# nothing to decode and these replace a full interconnect; the one choice of
# master -- the CPU or BIST engine 2 -- is axi_owner's, in the RTL.
#
# The AXI data width stays 32 all the way to the MIG: the memory could carry
# 256 bits per beat, but GP0 delivers 32, so a wider MIG port would only add
# a width converter that never has more to move.
# ---------------------------------------------------------------------------
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip \
    -module_name apc -dir $outdir/ip
set_property -dict [list CONFIG.SI_PROTOCOL {AXI3} CONFIG.MI_PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.ID_WIDTH {12}] [get_ips apc]
generate_target all [get_ips apc]

create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
    -module_name acc -dir $outdir/ip
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.ACLK_ASYNC {1} \
    CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.ID_WIDTH {12}] [get_ips acc]
generate_target all [get_ips acc]

# ---------------------------------------------------------------------------
# RTL and constraints. Everything in ../board/rtl except that design's top
# level is shared -- the AXI slave, the fan logic, the EMIO pads, the
# frequency counters, the BIST engines and axi_owner.
# ---------------------------------------------------------------------------
add_files -norecurse [glob $here/rtl/*.v]

# ⚠ NOT a hand-maintained list: naming the files one by one is a second
# source list that drifts, and a module added there and missed here fails
# synthesis only after the twenty-minute MIG build. Unreferenced modules cost
# nothing, so take the lot and let the top level decide.
foreach f [glob [file join $repo pl board rtl *]] {
    if {[file tail $f] eq "rkz7100_pl.v"} continue
    add_files -norecurse $f
}
add_files -fileset constrs_1 -norecurse [glob $here/xdc/*.xdc]

# ⚠ The *_timing.xdc is IMPLEMENTATION ONLY: it names clk_fpga_0, which does
# not exist during synthesis, and an XDC cannot guard that with `if`. See
# that file's header.
set_property USED_IN_SYNTHESIS false \
    [get_files -of_objects [get_filesets constrs_1] *_timing.xdc]
set_property top $top [current_fileset]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------------
if {$project_only} {
    puts "==== PROJECT ONLY ===="
    puts "     open $outdir/proj/ddr.xpr in Vivado and Run Implementation"
    exit 0
}

set jobs 8
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis failed -- see $outdir/proj/ddr.runs/synth_1/runme.log"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed -- see $outdir/proj/ddr.runs/impl_1/runme.log"
}

open_run impl_1
puts "==== TIMING ===="
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "  WNS $wns"
puts "  WHS $whs"
report_utilization -file $outdir/utilization.txt

# ---------------------------------------------------------------------------
# Did the clock groups apply? A Vivado constraint that matches nothing is
# accepted in silence, and `puts` from inside an XDC does not reach the run
# log, so constraint_check.tcl (shared with pl/board) asks the routed design
# instead: a clock group that applied leaves no TIMED path between its clocks
# and the rest.
# ---------------------------------------------------------------------------
source [file join $repo pl constraint_check.tcl]
rkz_check_clock_groups {pl_clk gtx_clk156 gtx_sataclk}
report_timing_summary -file $outdir/timing.txt
# Negative slack on a DDR3 interface is not a warning to read later: the
# design will either fail calibration or corrupt data on a warm day.
if {$wns < 0 || $whs < 0} {
    error "TIMING NOT MET (WNS $wns, WHS $whs) -- see $outdir/timing.txt"
}

set runs $outdir/proj/ddr.runs/impl_1
# ⚠ Two different files are called ".bin" on this board, and the FPGA manager
# accepts only one of them. write_bitstream's own -bin_file output is the
# configuration data in Vivado's big-endian order; Zynq's PCAP DMA wants it
# byte-swapped, which is what pl/bit2bin.py produces from the .bit. Loading
# the wrong one gives "Invalid bitstream, could not find a sync word", so the
# raw file is copied out under a name that cannot be mistaken for the other.
foreach {ext out} {bit .bit bin _raw.bin} {
    set src $runs/$top.$ext
    if {[file exists $src]} {
        file copy -force $src $outdir/$top$out
        puts "==== wrote $outdir/$top$out ([file size $src] bytes)"
    } else {
        error "expected $src, which write_bitstream did not produce"
    }
}
puts "==== for Linux: run bit2bin.py on $outdir/$top.bit"
puts "==== BUILD OK ===="

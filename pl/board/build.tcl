# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Build the RK-ZYNQ7100 PL bitstream: the PS7, the PL DDR3 behind its MIG, the
# register file, HDMI out and in, the camera, the SFP+ transceivers, the PL
# Ethernet port and the BIST engines.
#
# Usage:
#   vivado -mode batch -nojournal -nolog -source build.tcl -tclargs [<outdir> [ip|project]]
#
# <outdir> defaults to $RKZ7100_BUILD/board, or without that to
# C:/rkz7100-build/board on Windows and ~/rkz7100-build/board elsewhere.
#
# ⚠ Keep <outdir> short. Vivado's IP flow trips over Windows' 260-character
# path limit and fails in obscure ways well before it says so; that is why the
# default is a short path of its own, NOT a path under the repo.
#
# Products, copied to <outdir>/ at the end:
#   rkz7100_pl.bit      for JTAG (Vivado hardware manager, or U-Boot `fpga loadb`)
#   rkz7100_pl_raw.bin  write_bitstream's own -bin_file output. NOT what Linux's
#                       fpga_manager takes -- run ../bit2bin.py on the .bit for that.

set outdir [lindex $argv 0]
if {$outdir eq ""} {
    if {[info exists env(RKZ7100_BUILD)]} {
        set outdir $env(RKZ7100_BUILD)/board
    } elseif {$tcl_platform(platform) eq "windows"} {
        set outdir C:/rkz7100-build/board
    } else {
        set outdir [file normalize ~/rkz7100-build/board]
    }
}

# A second argument of "ip" stops after the IP have been generated, which is
# all that is needed to refresh the simulation stubs with
# ../tools/gen_ip_stubs.py. Elaborating against fresh stubs costs seconds and
# rejects a mis-wired port; finding the same error at the end of a synthesis
# run costs twenty-five minutes.
set ip_only [expr {[lindex $argv 1] eq "ip"}]

# A second argument of "project" stops once the project is complete -- IP
# generated, sources and constraints added, top set -- without running
# anything. Open $outdir/proj/board.xpr in the Vivado GUI and press Run
# Implementation. Everything the GUI then builds comes from the same lists
# this script uses in batch, so the two cannot drift apart.
set project_only [expr {[lindex $argv 1] eq "project"}]

set here [file dirname [file normalize [info script]]]
set repo [file normalize $here/../..]
set part xc7z100ffg900-2
set top  rkz7100_pl

# The PS configuration is shared with the Linux PS init: one source of truth.
source [file join $repo linux board ps7_config.tcl]

# Generate boot initialization before creating the PL project. It uses the
# shared boot settings, not the PL-specific overrides applied below.
source [file join $repo linux ps7_init_build.tcl]
rkz7100::generate_ps7_init $outdir

file mkdir $outdir/ip
source [file normalize [file join [file dirname [info script]] ../../../retrosim-build/vivado.tcl]]
retrosim::create_project board $outdir/proj $part

# ---------------------------------------------------------------------------
# PS7
# ---------------------------------------------------------------------------
create_ip -name processing_system7 -vendor xilinx.com -library ip -version 5.5 \
    -module_name ps7_rkz7100 -dir $outdir/ip
set ps [get_ips ps7_rkz7100]

# ⚠ The whole list in ONE call. Applied one property at a time the IP
# validates each against the state so far and refuses the 1.8V MIO settings
# before bank 501 has moved off its 3.3V default -- see ../../linux/gen_ps7.tcl;
# a refusal there costs fourteen MIO pins. PCW_ACT_* are values
# Vivado computes; one refused key would sink the whole call.
# Every port enabled here has a master on it. An enabled port with nothing
# driving it is a few hundred "unconnected pin" warnings and no benefit:
#   M_AXI_GP0    the MIG, shared with BIST engine 2 through axi_owner
#   M_AXI_GP1    through a crossbar: the register file, both VDMAs'
#                control ports and the CSI-2 receiver's
#   S_AXI_HP0    the HDMI capture VDMA's data master
#   S_AXI_HP1/2  the two axi_bist engines
#   S_AXI_HP3    the camera VDMA's data master
#   IRQ_F2P      [1:0] the HP bist engines, [2] the HDMI VDMA, [3] the
#                camera VDMA, [4] the CSI-2 receiver, [5] the MIG's bist
#                engine (GIC 61..66)
#   ENET1        GEM1 over EMIO as GMII, for the PL Ethernet PHY through
#                gmii_to_rgmii. Here and not in the shared ps7_config.tcl, so
#                the ddr design and the boot's PS init are unchanged -- which
#                also means the PS init does not route GEM1's clocks from EMIO;
#                linux/board/S15fpga does, before networking starts.
#
# ⚠ These OVERRIDE ps7_config.tcl, so they are removed from the list that gets
# applied and verified below. Applied first and verified against the full
# list afterward, the verify pass would put the shared values back and
# silently undo every override.
set overrides [list \
    CONFIG.PCW_USE_M_AXI_GP0        {1} \
    CONFIG.PCW_USE_M_AXI_GP1        {1} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE    {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_S_AXI_HP0        {1} \
    CONFIG.PCW_USE_S_AXI_HP1        {1} \
    CONFIG.PCW_USE_S_AXI_HP2        {1} \
    CONFIG.PCW_S_AXI_HP0_FREQMHZ    {100} \
    CONFIG.PCW_S_AXI_HP1_FREQMHZ    {100} \
    CONFIG.PCW_S_AXI_HP2_FREQMHZ    {100} \
    CONFIG.PCW_USE_S_AXI_HP3        {1} \
    CONFIG.PCW_S_AXI_HP3_FREQMHZ    {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR         {1} \
    CONFIG.PCW_NUM_F2P_INTR_INPUTS  {6} \
    CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET1_ENET1_IO       {EMIO} \
    CONFIG.PCW_ENET1_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET1_GRP_MDIO_IO    {EMIO} \
    CONFIG.PCW_ENET1_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_ENET1_PERIPHERAL_FREQMHZ {1000 Mbps} \
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

# Anything the PS7 did not take is a silently wrong board configuration.
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
# HDMI input: the AXI VDMA that writes captured frames into PS DRAM, and the
# protocol converter in front of M_AXI_GP1's AXI-Lite slaves.
#
# S2MM only -- this design never reads video out of memory. The stream is one
# RGB888 pixel per beat, so 24 bits wide; the memory side is 64 to match
# S_AXI_HP0.
#
# ⚠ c_s2mm_max_burst_length stays at 8. The VDMA's data master is AXI4 with an
# eight-bit burst length and S_AXI_HP0 is AXI3 with four, and the top level
# wires them together directly because the master carries no ID and so needs
# nothing reflected. Raising this past 16 would silently truncate every burst.
# rkz7100_pl.v latches an awlen_overflow bit that says so if it ever happens.
#
# c_prmry_is_aclk_async is 1, but the top level clocks all three VDMA ports
# from FCLK_CLK0: the crossing from the ADV7611's LLC is axis_cdc_fifo in
# rkz7100_pl.v, because a VDMA whose stream clock stops does not answer its
# control port either.
# ---------------------------------------------------------------------------
create_ip -name axi_vdma -vendor xilinx.com -library ip -version 6.3 \
    -module_name vdma_hdmirx -dir $outdir/ip
set_property -dict [list \
    CONFIG.c_include_mm2s            {0} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_num_fstores             {3} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {24} \
    CONFIG.c_s2mm_linebuffer_depth   {2048} \
    CONFIG.c_s2mm_max_burst_length   {8} \
    CONFIG.c_prmry_is_aclk_async     {1} \
    CONFIG.c_include_s2mm_sf         {1} \
    CONFIG.c_include_s2mm_dre        {0} \
] [get_ips vdma_hdmirx]
generate_target all [get_ips vdma_hdmirx]

# M_AXI_GP1 is AXI3 with 12-bit IDs; the crossbar's slaves are AXI4-Lite,
# which has neither IDs nor bursts. AXI3 requires every BID and RID to match
# the AWID or ARID that asked for it, and an AXI4-Lite slave cannot supply
# one, so something has to remember them. That is what this is for.
create_ip -name axi_protocol_converter -vendor xilinx.com -library ip \
    -version 2.1 -module_name apc_vdma_lite -dir $outdir/ip
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI3} \
    CONFIG.MI_PROTOCOL {AXI4LITE} \
    CONFIG.DATA_WIDTH  {32} \
    CONFIG.ID_WIDTH    {12} \
    CONFIG.ADDR_WIDTH  {32} \
] [get_ips apc_vdma_lite]
generate_target all [get_ips apc_vdma_lite]

# The SFP+ cages' transceivers, one channel per instance; gtx_prbs.v places
# two, and the quad's QPLL. The wizard is configured for 3.125 Gb/s on the
# CPLL -- its defaults -- and gtx_prbs.v moves each channel to 6.25 (CPLL,
# divider 1) or 10.3125 (QPLL) at run time: against the wizard's own
# configurations of all three rates at 40 bits, RXCDR_CFG differs for every
# rate and PMA_RSV above 6.6 Gb/s, and gtx_prbs.v writes both over the DRP.
#   tx/rx_data_width, int_datawidth 40       40 bits at the fabric and inside:
#                                            the user clock is the line rate
#                                            / 40, 257.8 MHz at 10.3125
#   prbs_detector, port_txprbssel/forceerr   the built-in PRBS generator and
#                                            checker, and their controls
#   port_loopback                            LOOPBACK[2:0] at run time
#   port_rx/txpolarity                       a P/N swap on a cable or board
#                                            is then a register write, not a
#                                            rebuild
#   port_tx/rxrate, port_tx/rxsysclksel      the divider and the PLL, at run
#                                            time
#   txdiffctrl, port_rxlpmen                 TX swing and the RX equalizer
#                                            mode as ports, from CTRL's
#                                            upper bits (gtx_prbs.v)
#   drp_clock 100                            ⚠ this is what sets the startup
#                                            FSMs' STABLE_CLOCK_PERIOD. At
#                                            the default 60 the wrapper
#                                            hard-codes 16 ns, and on this
#                                            100 MHz clock every reset wait
#                                            would run at 62% of its length.
create_ip -name gtwizard -vendor xilinx.com -library ip -version 3.6 \
    -module_name gtx_sfp -dir $outdir/ip
set_property -dict [list \
    CONFIG.gt0_val_tx_data_width       40 \
    CONFIG.gt0_val_rx_data_width       40 \
    CONFIG.gt0_val_tx_int_datawidth    40 \
    CONFIG.gt0_val_rx_int_datawidth    40 \
    CONFIG.gt0_val_prbs_detector       true \
    CONFIG.gt0_val_port_txprbssel      true \
    CONFIG.gt0_val_port_txprbsforceerr true \
    CONFIG.gt0_val_port_loopback       true \
    CONFIG.gt0_val_port_rxpolarity     true \
    CONFIG.gt0_val_port_txpolarity     true \
    CONFIG.gt0_val_port_txrate         true \
    CONFIG.gt0_val_port_rxrate         true \
    CONFIG.gt0_val_port_txsysclksel    true \
    CONFIG.gt0_val_port_rxsysclksel    true \
    CONFIG.gt0_val_txdiffctrl          true \
    CONFIG.gt0_val_port_rxlpmen        true \
    CONFIG.gt0_val_drp_clock           100 \
] [get_ips gtx_sfp]
foreach {k v} {gt0_val_tx_data_width 40 gt0_val_tx_int_datawidth 40
               gt0_val_rx_data_width 40 gt0_val_rx_int_datawidth 40
               gt0_val_tx_line_rate 3.125 gt0_val_port_txrate true
               gt0_val_port_txsysclksel true} {
    if {[get_property CONFIG.$k [get_ips gtx_sfp]] ne $v} {
        error "gtx_sfp: $k is [get_property CONFIG.$k [get_ips gtx_sfp]], not $v"
    }
}
generate_target all [get_ips gtx_sfp]

# The PL Ethernet port: GMII from GEM1 (EMIO) to RGMII on PHY2. Shared logic
# IN the core, so it makes its own transmit clocks from the 200 MHz oscillator
# and owns its IDELAYCTRL. Its MDIO register sits at address 8, clear of PHY2
# at 1.
create_ip -name gmii_to_rgmii -vendor xilinx.com -library ip -version 4.1 \
    -module_name gmii_rgmii_phy2 -dir $outdir/ip
set_property -dict [list \
    CONFIG.SupportLevel {Include_Shared_Logic_in_Core} \
    CONFIG.C_PHYADDR    {8} \
] [get_ips gmii_rgmii_phy2]
generate_target all [get_ips gmii_rgmii_phy2]

# ---------------------------------------------------------------------------
# The camera: MIPI CSI-2 receiver, and a second VDMA for its frames.
#
# The OV5647 sends RAW10 Bayer on two lanes. Its PLL settings put the modes
# at 315 Mb/s per lane (640x480), 441 (1296x972 and 1920x1080) and 472.5
# (2592x1944); the soft D-PHY on this part accepts up to 800. DPY_LINE_RATE
# sets the receiver's HS settle time and the clock it constrains the lanes
# with, so it is set just above the fastest mode.
#
# The data lanes' IDELAYs take their tap from the D-PHY's own register (+0x04
# from the receiver's base, a byte per lane) once DPY_EN_REG_IF is on, and it
# resets to C_IDLY_TAP. That needs C_CAL_MODE FIXED, which in turn is what
# lets C_IDLY_TAP be set at all; C_EN_EXT_TAP makes the IDELAYs loadable and
# moves the IDELAYCTRL into the top level. Its lane*_tap ports are NOT what
# drives the taps -- the register is -- and the top level ties them off.
#
# 10 is measured. Swept against the receiver's own ECC/CRC counts, the clean
# window depends on the mode: 640x480 (315 Mb/s) at 0..25 and 31, 1296x972 and
# 1920x1080 (441 Mb/s) at 1..19, and 2592x1944 (472.5 Mb/s) ONLY at 30 and 31.
# No one tap serves all four, so the reset value is the middle of the 441
# window, clean for three modes with no software at all, and
# pl/tools/camsetup.sh sets 31 for 5 MP. camtest.sh -t repeats the sweep.
#
# ⚠ C_CAL_MODE must be set BEFORE the other two, in its own call: until it
# is FIXED the IP disables C_EN_EXT_TAP and C_IDLY_TAP, and a disabled
# parameter is ignored with a warning, not refused.
#
# The video frame buffer (CMN_INC_VFB) turns the CSI-2 packets into AXI4-
# Stream video, one pixel per beat: 16 bits, RAW10 in the low ten.
# ---------------------------------------------------------------------------
create_ip -name mipi_csi2_rx_subsystem -vendor xilinx.com -library ip \
    -module_name csi_cam -dir $outdir/ip
set_property -dict [list \
    CONFIG.CMN_NUM_LANES           {2} \
    CONFIG.C_DPHY_LANES            {2} \
    CONFIG.CMN_PXL_FORMAT          {RAW10} \
    CONFIG.CMN_NUM_PIXELS          {1} \
    CONFIG.CMN_INC_VFB             {true} \
    CONFIG.DPY_LINE_RATE           {480} \
    CONFIG.C_HS_LINE_RATE          {480} \
    CONFIG.C_EN_7S_LINERATE_CHECK  {true} \
    CONFIG.DPY_EN_REG_IF           {true} \
] [get_ips csi_cam]
set_property CONFIG.C_CAL_MODE FIXED [get_ips csi_cam]
set_property -dict [list CONFIG.C_EN_EXT_TAP true CONFIG.C_IDLY_TAP 10] [get_ips csi_cam]
foreach {k v} {C_CAL_MODE FIXED C_EN_EXT_TAP true C_IDLY_TAP 10 DPY_EN_REG_IF true DPY_LINE_RATE 480} {
    if {[get_property CONFIG.$k [get_ips csi_cam]] ne $v} {
        error "csi_cam: $k is [get_property CONFIG.$k [get_ips csi_cam]], not $v"
    }
}
generate_target all [get_ips csi_cam]

# The HDMI VDMA's shape with a 16-bit stream, a line buffer deep enough for
# the sensor's 2592-pixel lines, and no clock crossing: every side of it runs
# on FCLK_CLK0.
create_ip -name axi_vdma -vendor xilinx.com -library ip -version 6.3 \
    -module_name vdma_cam -dir $outdir/ip
set_property -dict [list \
    CONFIG.c_include_mm2s            {0} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_num_fstores             {3} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {16} \
    CONFIG.c_s2mm_linebuffer_depth   {4096} \
    CONFIG.c_s2mm_max_burst_length   {8} \
    CONFIG.c_prmry_is_aclk_async     {0} \
    CONFIG.c_include_s2mm_sf         {1} \
    CONFIG.c_include_s2mm_dre        {0} \
] [get_ips vdma_cam]
generate_target all [get_ips vdma_cam]

# M_AXI_GP1, after its protocol converter, fans out to four AXI-Lite slaves:
# the two VDMAs, 64 KB each, the CSI-2 receiver, 128 KB because its D-PHY
# registers sit above the controller's, and the register file at 0x8010_0000.
# The device trees name the same addresses.
#
# ⚠ The register file is an AXI3 slave on a Lite port. That works because the
# converter ahead of the crossbar turns a CPU burst into single beats; the
# file sees AWLEN 0 and answers each one. GP0 is the MIG's here, all of it.
create_ip -name axi_crossbar -vendor xilinx.com -library ip \
    -module_name xbar_gp1 -dir $outdir/ip
set_property -dict [list \
    CONFIG.PROTOCOL           {AXI4LITE} \
    CONFIG.CONNECTIVITY_MODE  {SASD} \
    CONFIG.NUM_SI             {1} \
    CONFIG.NUM_MI             {4} \
    CONFIG.ADDR_WIDTH         {32} \
    CONFIG.DATA_WIDTH         {32} \
    CONFIG.M00_A00_BASE_ADDR  {0x0000000080000000} \
    CONFIG.M00_A00_ADDR_WIDTH {16} \
    CONFIG.M01_A00_BASE_ADDR  {0x0000000080010000} \
    CONFIG.M01_A00_ADDR_WIDTH {16} \
    CONFIG.M02_A00_BASE_ADDR  {0x0000000080020000} \
    CONFIG.M02_A00_ADDR_WIDTH {17} \
    CONFIG.M03_A00_BASE_ADDR  {0x0000000080100000} \
    CONFIG.M03_A00_ADDR_WIDTH {16} \
] [get_ips xbar_gp1]
generate_target all [get_ips xbar_gp1]


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

if {$ip_only} {
    puts "==== IP ONLY ===="
    puts "     now: python pl/tools/gen_ip_stubs.py $outdir board"
    exit 0
}

# ---------------------------------------------------------------------------
# RTL and constraints
# ---------------------------------------------------------------------------
add_files -norecurse [glob $here/rtl/*.v]
add_files -fileset constrs_1 -norecurse [glob $here/xdc/*.xdc]

# ⚠ The *_timing.xdc is IMPLEMENTATION ONLY. It names clk_fpga_0, which does
# not exist while the PS7 is a black box during synthesis, and an XDC cannot
# guard that with `if` -- Vivado reads constraint files with a restricted Tcl
# interpreter that has neither `if` nor `foreach`:
#
#   CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not supported
#   in the xdc constraint file.
#
# A clock-group block written with either one never applies, in any build, and
# nothing fails until the logic it is meant to relax stops being optimized
# away -- so the file is implementation-only and holds no control flow.
set_property USED_IN_SYNTHESIS false \
    [get_files -of_objects [get_filesets constrs_1] *_timing.xdc]
set_property top $top [current_fileset]
update_compile_order -fileset sources_1

if {$project_only} {
    puts "==== PROJECT ONLY ===="
    puts "     open $outdir/proj/board.xpr in Vivado and Run Implementation"
    exit 0
}

# ---------------------------------------------------------------------------
# Synthesis, implementation, bitstream
# ---------------------------------------------------------------------------
set jobs 8
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis failed -- see $outdir/proj/board.runs/synth_1/runme.log"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed -- see $outdir/proj/board.runs/impl_1/runme.log"
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "==== TIMING ===="
puts "  WNS $wns"
puts "  WHS $whs"
report_timing_summary -file $outdir/timing.txt
report_utilization -hierarchical -file $outdir/utilization.txt


# ---------------------------------------------------------------------------
# Did the constraints actually do anything? A Vivado constraint that matches
# nothing is accepted in silence, and `puts` from inside an XDC does not reach
# the run log, so the implemented design is asked here instead: a clock group
# that applied leaves no TIMED path between its clocks and the rest. (There is
# no `get_clock_groups` in Vivado; the test is on behavior, not metadata.)
# ---------------------------------------------------------------------------
# The clock-group self-check is shared with pl/ddr.
source [file join $repo pl constraint_check.tcl]
# *TXOUTCLK is both SFP channels' user clock, created by the gtwizard IP's
# own XDC. The two share one group: no path runs between them, since each
# channel's logic lives entirely in its own domain plus the register clock.
rkz_check_clock_groups {pl_clk gtx_clk156 gtx_sataclk hdmi_rx_pclk *TXOUTCLK phy2_rxc mipi_clk_hs_p}

# ⚠ The SFP lanes are pinned by PACKAGE_PIN on their ports. Confirm the
# channels actually landed there instead of trusting that the XDC line
# matched: a constraint that matches nothing is silently a no-op, and a GTX
# channel placed on the SATA lanes would build, load and fail in a way that
# looks like a bad cable.
# Two independent facts per channel: the transceiver under gtx/ch[N] is on
# the expected site, and the port it drives landed on the expected pin. (A
# GT output port is not the GT's direct neighbor in the netlist -- Vivado puts
# a pseudo-OBUF between them -- so the two are checked separately rather than
# by walking from one to the other.) The ? stands for the generate brackets.
set gt_want {
    *ch?0?.gtx_i*  GTXE2_CHANNEL_X0Y14  {sfp_txp[0]} P2  {sfp_rxp[0]} T6
    *ch?1?.gtx_i*  GTXE2_CHANNEL_X0Y15  {sfp_txp[1]} N4  {sfp_rxp[1]} P6
}
foreach {pat site txport txpin rxport rxpin} $gt_want {
    set cell [get_cells -quiet -hierarchical -filter "REF_NAME == GTXE2_CHANNEL && NAME =~ $pat"]
    if {[llength $cell] != 1} {
        error "GTX PLACEMENT: expected one GTXE2_CHANNEL matching $pat, found [llength $cell]"
    }
    set got [get_property LOC $cell]
    puts "====   $cell at $got"
    if {$got ne $site} { error "GTX PLACEMENT: $cell is on '$got', expected $site" }
    foreach {port pin} [list $txport $txpin $rxport $rxpin] {
        set g [get_property PACKAGE_PIN [get_ports $port]]
        puts "====   $port on $g"
        if {$g ne $pin} { error "GTX PLACEMENT: $port is on '$g', expected $pin" }
    }
}
set railing [get_cells -quiet -hierarchical -filter {REF_NAME =~ BUFH* && NAME =~ *cpll_railing*}]
if {[llength $railing] != 2} {
    error "GTX PLACEMENT: expected 2 CPLL-railing BUFHs, found [llength $railing] -- the XDC LOC query matches nothing"
}
foreach b $railing {
    set cr [get_property CLOCK_REGION [get_sites -of_objects $b]]
    puts "====   $b in $cr"
    if {$cr ne "X1Y3"} { error "GTX PLACEMENT: $b is in $cr, not X1Y3 with its reference" }
}
# The TXOUTCLK clocks the XDC creates at the 10.3125 Gb/s period, and the
# quad's QPLL beside the two channels.
foreach c {sfp1_TXOUTCLK sfp2_TXOUTCLK} {
    set k [get_clocks -quiet $c]
    if {[llength $k] != 1} { error "GTX PLACEMENT: clock $c does not exist -- the XDC query matched nothing" }
    set per [get_property PERIOD $k]
    puts "====   $c period $per on [get_property SOURCE_PINS $k]"
    if {abs($per - 3.878) > 0.001} { error "GTX PLACEMENT: $c period $per, expected 3.878" }
}
set qpll [get_cells -quiet -hierarchical -filter {REF_NAME == GTXE2_COMMON}]
if {[llength $qpll] != 1} { error "GTX PLACEMENT: expected one GTXE2_COMMON, found [llength $qpll]" }
puts "====   $qpll at [get_property LOC $qpll]"
if {[get_property LOC $qpll] ne "GTXE2_COMMON_X0Y3"} {
    error "GTX PLACEMENT: the QPLL is not in quad 112 (GTXE2_COMMON_X0Y3)"
}
puts "==== GTX PLACEMENT OK"

# Where did the HDMI input bus's first flops actually land?
#
# Asking for IOB packing in the XDC is a REQUEST: a cell name that matches
# nothing is accepted in silence, and a flop the placer could not fit is a
# warning in a log nobody reads. Either way the slack comes back and the
# cause looks like the input delay rather than the placement.
#
# This is a DIAGNOSTIC, not the gate -- the WNS check below is the gate, and
# a check that guesses the wrong property name would be a false failure on a
# perfectly good design. It prints where the flops went so the next person
# does not have to open the checkpoint to find out.
set rkz_io 0
set rkz_locs {}
foreach rkz_c [get_cells -quiet {hdmi_rx/d0_reg[*] hdmi_rx/de0_reg
                                 hdmi_rx/hs0_reg hdmi_rx/vs0_reg}] {
    set rkz_l [get_property -quiet LOC $rkz_c]
    lappend rkz_locs $rkz_l
    if {[string match "ILOGIC*" $rkz_l] || [string match "IOB*" $rkz_l]} {
        incr rkz_io
    }
}
puts "====   HDMI RX first-stage flops: [llength $rkz_locs] found,\
       $rkz_io in I/O sites"
puts "====   example placements: [lrange [lsort -unique $rkz_locs] 0 2]"

# ⚠ A BITSTREAM IS WRITTEN BEFORE THIS RUNS, so without an error here a design
# that misses timing still produces a loadable file and a "BUILD OK".
# Negative slack is not a warning to read later: it is a design that works on
# the bench and fails on a warm day, or on the next netlist.
if {$wns < 0 || $whs < 0} {
    error "TIMING NOT MET (WNS $wns, WHS $whs) -- see $outdir/timing.txt"
}

set runs $outdir/proj/board.runs/impl_1
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

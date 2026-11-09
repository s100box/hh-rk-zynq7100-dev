# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Timing exceptions for the full design. IMPLEMENTATION ONLY -- build.tcl sets
# USED_IN_SYNTHESIS false on this file.
#
# ⚠ WHY THIS IS A SEPARATE FILE, and why there is no `if` in it.
#
# Two things force it:
#
# 1. An XDC is read by a RESTRICTED Tcl interpreter. `foreach` and `if` are
#    not available:
#
#      CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not
#      supported in the xdc constraint file.
#
#    A clock-group block written with either one never runs, in any build,
#    and nothing fails: the crossings it is meant to relax are the only thing
#    it changes.
#
# 2. The constraint needs `clk_fpga_0`, which does not exist while the PS7 is
#    a black box during synthesis. Guarding that with `if` is exactly what
#    point 1 forbids. Marking the whole file implementation-only removes the
#    need for a guard: by then every clock is real.
#
# So: no control flow here, and nothing in this file is needed to synthesize.

# ---------------------------------------------------------------------------
# The measured oscillators are unrelated to the PS clock and to each other.
#
# freq_ctr crosses a gate one way and a toggle plus a data word the other. The
# data is stable for a whole gate period -- about a second -- before it is
# sampled, so the crossing needs a synchronizer, which it has, and no timing
# relationship, which this says.
#
# -include_generated_clocks keeps each family together: the SATA reference
# appears with its ODIV2 child, and anything derived from the 200 MHz
# oscillator stays with it.
#
# phy2_rxc is the PL Ethernet PHY's RGMII receive clock. The core's transmit
# clocks come from its MMCM on the 200 MHz oscillator, so they belong to
# sys_clk's group already.
#
# *TXOUTCLK is the two SFP channels' user clocks, created by the gtwizard IP's
# own XDC. They share a group because no path runs between them; each
# channel's logic lives in its own domain and the register clock.
#
# hdmi_rx_pclk is the ADV7611's LLC. The MIPI group is the camera's clock
# lane and the byte clock the CSI-2 receiver's own XDC derives from it.
# ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_fpga_0] \
    -group [get_clocks -include_generated_clocks pl_clk] \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks gtx_clk156] \
    -group [get_clocks -include_generated_clocks gtx_sataclk] \
    -group [get_clocks -include_generated_clocks hdmi_rx_pclk] \
    -group [get_clocks -quiet -filter {NAME =~ *TXOUTCLK}] \
    -group [get_clocks -include_generated_clocks phy2_rxc] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports mipi_clk_hs_p]]

# ---------------------------------------------------------------------------
# The HDMI input bus, which is source-synchronous to the ADV7611's LLC.
#
# ⚠ THESE NUMBERS ARE AN ASSUMPTION, NOT A DATA SHEET FIGURE, and they are
# the one thing in this design that is not measured.
#
# The model is the physical one for this kind of bus: the ADV7611 launches
# data shortly AFTER an LLC edge, and the fabric samples it on the next edge.
# So both delays are positive -- data valid from 1.0 ns to 4.0 ns after the
# launch edge.
#
# A symmetric window, -min -2.0 to -max +2.0, looks like the safe direction
# to be wrong in. It is not: a negative minimum says the data may arrive
# BEFORE the clock, which is a hold requirement no short path can meet, and
# the design fails setup AND hold at once. A window that is wrong in shape
# cannot be made safe by making it wider.
#
# What actually confirms capture works is the status block the capture RTL
# publishes: measured h_active, v_active, h_total, v_total and a frame
# counter, readable from Linux. Wrong sampling shows up there as geometry
# that does not match the mode the ADV7611 reports over I2C -- a comparison
# against something this design did not produce. The ADV7611 also has a
# programmable LLC delay, so a real skew problem is adjustable from software
# rather than needing another bitstream.
# ---------------------------------------------------------------------------
set_input_delay -clock [get_clocks hdmi_rx_pclk] -max 4.0 \
    [get_ports {hdmi_rx_d[*] hdmi_rx_de hdmi_rx_hs hdmi_rx_vs}]
set_input_delay -clock [get_clocks hdmi_rx_pclk] -min 1.0 \
    [get_ports {hdmi_rx_d[*] hdmi_rx_de hdmi_rx_hs hdmi_rx_vs}]

# ---------------------------------------------------------------------------
# HDMI is source-synchronous: the data leaves against the pixel clock the MMCM
# makes, and the ADV7511 latches it on that clock's rising edge (register
# 0x16[0] = 0 in pl/tools/hdmitest.sh). It wants roughly 1.0 ns of setup and 0.7 ns
# of hold.
#
# ⚠ The clock is found by asking which clock drives that buffer, not by
# guessing its name. A generated clock's name depends on the MMCM instance
# path, and a set_output_delay whose -clock matches nothing is accepted in
# silence and constrains nothing -- the same trap as above, one level down.
# ---------------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_pins hdmi/pix_bufg/O]] \
    -max  1.0 [get_ports {hdmi_tx_d[*] hdmi_tx_de hdmi_tx_hsync hdmi_tx_vsync}]
set_output_delay -clock [get_clocks -of_objects [get_pins hdmi/pix_bufg/O]] \
    -min -0.7 [get_ports {hdmi_tx_d[*] hdmi_tx_de hdmi_tx_hsync hdmi_tx_vsync}]

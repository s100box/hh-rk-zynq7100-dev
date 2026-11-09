# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# RK-ZYNQ7100 PL full design: pins and I/O constraints.
#
# Pins are taken verbatim from ../../RK_ZYNQ7100_master.xdc (schematic, every
# pin checked against the Vivado xc7z100ffg900 package pinout).
#
# LED1-4 (green) and the bicolor LED8 (PL_LED5/6) are driven by NPN
# transistors: 1 = on. KEY1-4 pull to GND against 4.7K pull-ups: pressed = 0.
# Bank 10 is VCC_ADJ2, 3.3V by default (RA2 = 3.24K); bank 35 is 1.8V.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property -dict {PACKAGE_PIN AC16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]     ;# PL_LED1  bank 10
set_property -dict {PACKAGE_PIN AC17 IOSTANDARD LVCMOS33} [get_ports {led[1]}]     ;# PL_LED2  bank 10
set_property -dict {PACKAGE_PIN AH18 IOSTANDARD LVCMOS33} [get_ports {led[2]}]     ;# PL_LED3  bank 10
set_property -dict {PACKAGE_PIN AE18 IOSTANDARD LVCMOS33} [get_ports {led[3]}]     ;# PL_LED4  bank 10
set_property -dict {PACKAGE_PIN G12  IOSTANDARD LVCMOS18} [get_ports {led[4]}]     ;# PL_LED5  bank 35, bicolor LED8 half A
set_property -dict {PACKAGE_PIN F12  IOSTANDARD LVCMOS18} [get_ports {led[5]}]     ;# PL_LED6  bank 35, bicolor LED8 half B

set_property -dict {PACKAGE_PIN AJ18 IOSTANDARD LVCMOS33} [get_ports {key_n[0]}]   ;# PL_KEY1  bank 10, active low
set_property -dict {PACKAGE_PIN AE17 IOSTANDARD LVCMOS33} [get_ports {key_n[1]}]   ;# PL_KEY2  bank 10, active low
set_property -dict {PACKAGE_PIN AF17 IOSTANDARD LVCMOS33} [get_ports {key_n[2]}]   ;# PL_KEY3  bank 10, active low
set_property -dict {PACKAGE_PIN AF18 IOSTANDARD LVCMOS33} [get_ports {key_n[3]}]   ;# PL_KEY4  bank 10, active low

# The keys are mechanical and read by software; they have no timing to meet.
set_false_path -from [get_ports {key_n[*]}]

# Fan header J10, bank 11 at 3.3V (user guide section 9).
#   FAN_PWM  is INVERTED by NPN Q7: the pin high pulls the fan's PWM line low.
#   FAN_TACH is open collector with a 4.7K pull-up on the board.
# Neither has any timing to meet: the PWM is 25 kHz and the tach is ~100 Hz,
# and both are synchronized into fclk_clk0 inside fan_ctrl.
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports fan_pwm]
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVCMOS33} [get_ports fan_tach]
set_false_path -to   [get_ports fan_pwm]
set_false_path -from [get_ports fan_tach]

# I2C on PL pins, handed to the PS as EMIO GPIOs (see rtl/emio_pads.v).
# Bit-banged by Linux's i2c-gpio at 100 kHz, so nothing here has timing to
# meet -- but the I/O standards differ by bank and do matter:
#   HDMI TX  bank 35, 1.8V, 2K pull-ups to 1.8V   (ADV7511 at 0x39)
#   HDMI RX  bank 11, 3.3V, 2K pull-ups to 3.3V   (ADV7611 at 0x4C)
#   camera   bank 9,  3.3V, 4.7K pull-ups         (AT24C256 at 0x50)
# The board provides every pull-up; i2c-gpio only ever pulls a line down.
set_property -dict {PACKAGE_PIN H14  IOSTANDARD LVCMOS18} [get_ports hdmi_tx_scl]
set_property -dict {PACKAGE_PIN K15  IOSTANDARD LVCMOS18} [get_ports hdmi_tx_sda]
set_property -dict {PACKAGE_PIN AC24 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_scl]
set_property -dict {PACKAGE_PIN AD24 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_sda]
set_property -dict {PACKAGE_PIN AC19 IOSTANDARD LVCMOS33} [get_ports cam_scl]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports cam_sda]
# J9's two control lines, bank 9: pin 5 (the Pi's CAM_IO0, a module's power
# enable) and pin 4 (CAM_IO1). Slow GPIOs, so no timing.
set_property -dict {PACKAGE_PIN AD19 IOSTANDARD LVCMOS33} [get_ports cam_gpio]
set_property -dict {PACKAGE_PIN AD20 IOSTANDARD LVCMOS33} [get_ports cam_clk]
set_false_path -to   [get_ports {cam_gpio cam_clk}]
set_false_path -from [get_ports {cam_gpio cam_clk}]

# The camera's MIPI D-PHY, bank 35. The board's network (schematic sheet 20)
# puts 150R across each HS pair -- R281, R285, R292, always in circuit -- and
# taps each wire through 100R to an LP input. The 150R is the HS
# termination, so DIFF_TERM stays OFF: the internal 100R on top would leave
# 60R. HSUL_12 on the LP inputs needs a 0.6 V reference, which bank 35 makes
# internally; its LVCMOS18 pins do not use one.
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports mipi_clk_hs_p]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports mipi_clk_hs_n]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports {mipi_d_hs_p[0]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports {mipi_d_hs_n[0]}]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports {mipi_d_hs_p[1]}]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVDS DIFF_TERM FALSE} [get_ports {mipi_d_hs_n[1]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD HSUL_12} [get_ports mipi_clk_lp_p]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD HSUL_12} [get_ports mipi_clk_lp_n]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD HSUL_12} [get_ports {mipi_d_lp_p[0]}]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD HSUL_12} [get_ports {mipi_d_lp_n[0]}]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD HSUL_12} [get_ports {mipi_d_lp_p[1]}]
set_property -dict {PACKAGE_PIN E12 IOSTANDARD HSUL_12} [get_ports {mipi_d_lp_n[1]}]
set_property INTERNAL_VREF 0.6 [get_iobanks 35]

# ADV7611 RESET, active low, 4.7K pull-down on the board: the chip stays in
# reset, and off the I2C bus, until this is driven high.
set_property -dict {PACKAGE_PIN AG25 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_rst_n]

# The PL Ethernet PHY's management bus (PHY2, U19, RTL8211F-CG at address 1,
# bank 11), driven by GEM1's MDIO through the gmii_to_rgmii core
# (rtl/rkz7100_pl.v). MDIO has a 1.5K pull-up on the board; MDC is push-pull.
set_property -dict {PACKAGE_PIN AG19 IOSTANDARD LVCMOS33} [get_ports phy2_mdc]
set_property -dict {PACKAGE_PIN AH19 IOSTANDARD LVCMOS33} [get_ports phy2_mdio]
set_false_path -to   [get_ports {phy2_mdc phy2_mdio}]
set_false_path -from [get_ports phy2_mdio]

# PHY2's RGMII, bank 11 at 3.3 V. The gmii_to_rgmii core's own XDC carries the
# input and output delays; it needs a clock ON the receive-clock port, which is
# on an SRCC pin (AF20, IO_L14P_T2_SRCC_11) so it can reach a BUFG.
set_property -dict {PACKAGE_PIN AF20 IOSTANDARD LVCMOS33} [get_ports phy2_rxc]
set_property -dict {PACKAGE_PIN AG20 IOSTANDARD LVCMOS33} [get_ports phy2_rx_ctl]
set_property -dict {PACKAGE_PIN AJ20 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[0]}]
set_property -dict {PACKAGE_PIN AE21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[1]}]
set_property -dict {PACKAGE_PIN AG21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[2]}]
set_property -dict {PACKAGE_PIN AH21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[3]}]
set_property -dict {PACKAGE_PIN Y22  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports phy2_txc]
set_property -dict {PACKAGE_PIN AF19 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports phy2_tx_ctl]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {phy2_txd[0]}]
set_property -dict {PACKAGE_PIN AA22 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {phy2_txd[1]}]
set_property -dict {PACKAGE_PIN AD21 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {phy2_txd[2]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {phy2_txd[3]}]
create_clock -period 8.000 -name phy2_rxc [get_ports phy2_rxc]

set_false_path -to   [get_ports {hdmi_tx_scl hdmi_tx_sda hdmi_rx_scl hdmi_rx_sda cam_scl cam_sda hdmi_rx_rst_n}]
set_false_path -from [get_ports {hdmi_tx_scl hdmi_tx_sda hdmi_rx_scl hdmi_rx_sda cam_scl cam_sda}]

# ---------------------------------------------------------------------------
# HDMI input: the ADV7611's parallel video bus, bank 11 at 3.3 V.
#
# The receiver drives its own clock, LLC, so this is a SOURCE-SYNCHRONOUS bus
# and everything on it is captured on that clock -- see rtl/hdmi_rx_capture.v.
# AD23 is clock-capable (SRCC), which is why the board can do this at all.
#
# ⚠ hdmi_rx_vs is the ADV7611's VS/FIELD/ALSB pin, and out of reset the chip
# SAMPLES IT TO CHOOSE ITS OWN I2C ADDRESS: low gives 0x4C, high gives 0x4D.
# The fabric must never drive it. It is an input here and must stay one, or
# the receiver moves off the address the device tree names and the bus looks
# dead.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AD23 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_pclk]
set_property -dict {PACKAGE_PIN AJ24 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_de]
set_property -dict {PACKAGE_PIN AH24 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_hs]
set_property -dict {PACKAGE_PIN AG24 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_vs]
set_property -dict {PACKAGE_PIN AC22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[0]}]
set_property -dict {PACKAGE_PIN AE23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[1]}]
set_property -dict {PACKAGE_PIN AF24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[2]}]
set_property -dict {PACKAGE_PIN AH23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[3]}]
set_property -dict {PACKAGE_PIN AG22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[4]}]
set_property -dict {PACKAGE_PIN AF22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[5]}]
set_property -dict {PACKAGE_PIN AF23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[6]}]
set_property -dict {PACKAGE_PIN AH22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[7]}]
set_property -dict {PACKAGE_PIN AE22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[8]}]
set_property -dict {PACKAGE_PIN AC23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[9]}]
set_property -dict {PACKAGE_PIN AK17 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[10]}]
set_property -dict {PACKAGE_PIN AK18 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[11]}]
set_property -dict {PACKAGE_PIN AJ19 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[12]}]
set_property -dict {PACKAGE_PIN AK20 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[13]}]
set_property -dict {PACKAGE_PIN AK21 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[14]}]
set_property -dict {PACKAGE_PIN AJ21 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[15]}]
set_property -dict {PACKAGE_PIN AK22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[16]}]
set_property -dict {PACKAGE_PIN AK23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[17]}]
set_property -dict {PACKAGE_PIN AJ23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[18]}]
set_property -dict {PACKAGE_PIN AK25 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[19]}]
set_property -dict {PACKAGE_PIN AJ25 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[20]}]
set_property -dict {PACKAGE_PIN AA23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[21]}]
set_property -dict {PACKAGE_PIN AA24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[22]}]
set_property -dict {PACKAGE_PIN AB24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[23]}]

# The pixel clock the ADV7611 produces. 74.25 MHz is 720p60, and everything
# at or below it -- 1080p30, 576p, 480p, VGA. A source that is not connected
# drives no clock at all, which is the case hdmi_rx_capture.v is built to
# survive.
#
# ⚠ 1080p60 IS OUT OF SPEC FOR THIS BUILD. Its LLC is 148.5 MHz and the
# design does not close there, for a reason worth writing down:
#
# The LLC reaches the capture flops through an IBUF and a BUFG, about 4.4 ns
# of clock insertion delay; the data has only an IBUF, about 1.6 ns. The
# clock therefore arrives long after the data, which is a HOLD violation, and
# the placer fixes it the only way it can -- a ZHOLD delay of about 7.1 ns in
# the data path. That satisfies hold and leaves nothing for setup at
# 148.5 MHz (WNS about -1.4 ns); at 74.25 MHz the same delay fits with room
# to spare.
#
# The fix for 1080p60 is to stop the clock arriving late rather than to delay
# the data: an MMCM whose feedback compensates the BUFG insertion delay, so
# the clock at the flops is phase-aligned with the clock at the pin and no
# ZHOLD is needed -- an MMCM that must re-lock whenever the source changes
# resolution, with the capture block and the CDC FIFO's write side on its
# output.
create_clock -period 13.468 -name hdmi_rx_pclk [get_ports hdmi_rx_pclk]

# ⚠ The first capture flop of every signal on this bus goes IN THE I/O BLOCK.
#
# Left in the fabric, the placer puts them wherever the design has room, and
# the pad-to-flop route becomes part of the setup path -- measured at about
# 7.5 ns, more than a whole 148.5 MHz period (6.734 ns). An IOB flop's input
# delay is short and, more importantly, FIXED -- it does not depend on what
# else the design happens to contain.
#
# hdmi_rx_capture.v is built for this: the first stage of its input pipeline
# is a plain flop with no reset and no logic in front of it, which is what an
# IOB can hold.
#
# ⚠ If these names ever stop matching, the constraint matches nothing and is
# accepted in SILENCE, and the only symptom is the slack coming back.
# build.tcl prints afterward how many of the 27 landed in I/O sites.
set_property IOB TRUE [get_cells -quiet {hdmi_rx/d0_reg[*]}]
set_property IOB TRUE [get_cells -quiet {hdmi_rx/de0_reg hdmi_rx/hs0_reg hdmi_rx/vs0_reg}]

# ---------------------------------------------------------------------------
# SFP+ cages J1 and J4, low-speed pins, bank 9 at 3.3 V.
#
# These four are the only SFP pins wired to the FPGA at all. MOD-DEF0/1/2 (the
# module I2C and the presence detect), RS0 and RS1 each sit on a 4.7K pull-up
# and go nowhere, and TX_FAULT is tied to ground -- so a module cannot be
# identified, detected or rate-selected from here, only enabled and watched.
#
# ⚠ TX_DISABLE is PULLED UP on the board: a module transmits only while the
# FPGA holds the pin low. Every bitstream that leaves these pins alone leaves
# the transmitters off, which is why a copper SFP fitted to this board does
# not link until software asks it to.
#
# Nothing here has timing to meet: TX_DISABLE changes at human speed and LOS
# is synchronized in the fabric before the PS sees it.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AB19 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[0]}]
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[1]}]
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33} [get_ports {sfp_los[0]}]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports {sfp_los[1]}]
set_false_path -to   [get_ports {sfp_tx_disable[*]}]
set_false_path -from [get_ports {sfp_tx_disable[*] sfp_los[*]}]

# Compression roughly halves the 7z100's bitstream, which is what
# fpga_manager pushes through devcfg on every load.
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ---------------------------------------------------------------------------
# The 40-pin header J8, bank 10 at VCC_ADJ2 (3.3V by default, RA2 = 3.24K).
#
# All 34 pins are EMIO GPIOs (bits 18..51 -> Linux gpio 72..105), so Linux
# owns direction and level per pin. Generated from ../../RK_ZYNQ7100_master.xdc
# by pl/tools/gen_j8_xdc.py -- no pin is retyped here.
#
# These are 17 routed differential pairs being used as 34 single-ended pins.
# That is fine at LVCMOS33, but if a pair is ever wanted as a real LVDS pair,
# both halves have to leave this list together.
#
# Nothing here has timing to meet: a GPIO the PS reads and writes over EMIO is
# asynchronous to everything by construction, and the PS GPIO block samples it
# with no relationship to fclk_clk0.
# ---------------------------------------------------------------------------
# >>> J8 pins generated by pl/tools/gen_j8_xdc.py -- do not edit by hand
set_property -dict {PACKAGE_PIN AJ16 IOSTANDARD LVCMOS33} [get_ports {j8[0]}]  ;# IO1_P   J8 pin 4   gpio 72
set_property -dict {PACKAGE_PIN AK16 IOSTANDARD LVCMOS33} [get_ports {j8[1]}]  ;# IO1_N   J8 pin 3   gpio 73
set_property -dict {PACKAGE_PIN AG17 IOSTANDARD LVCMOS33} [get_ports {j8[2]}]  ;# IO2_P   J8 pin 6   gpio 74
set_property -dict {PACKAGE_PIN AG16 IOSTANDARD LVCMOS33} [get_ports {j8[3]}]  ;# IO2_N   J8 pin 5   gpio 75
set_property -dict {PACKAGE_PIN AH17 IOSTANDARD LVCMOS33} [get_ports {j8[4]}]  ;# IO3_P   J8 pin 8   gpio 76
set_property -dict {PACKAGE_PIN AH16 IOSTANDARD LVCMOS33} [get_ports {j8[5]}]  ;# IO3_N   J8 pin 7   gpio 77
set_property -dict {PACKAGE_PIN AF15 IOSTANDARD LVCMOS33} [get_ports {j8[6]}]  ;# IO4_P   J8 pin 10  gpio 78
set_property -dict {PACKAGE_PIN AG15 IOSTANDARD LVCMOS33} [get_ports {j8[7]}]  ;# IO4_N   J8 pin 9   gpio 79
set_property -dict {PACKAGE_PIN AJ15 IOSTANDARD LVCMOS33} [get_ports {j8[8]}]  ;# IO5_P   J8 pin 12  gpio 80
set_property -dict {PACKAGE_PIN AK15 IOSTANDARD LVCMOS33} [get_ports {j8[9]}]  ;# IO5_N   J8 pin 11  gpio 81
set_property -dict {PACKAGE_PIN AF14 IOSTANDARD LVCMOS33} [get_ports {j8[10]}]  ;# IO6_P   J8 pin 14  gpio 82
set_property -dict {PACKAGE_PIN AG14 IOSTANDARD LVCMOS33} [get_ports {j8[11]}]  ;# IO6_N   J8 pin 13  gpio 83
set_property -dict {PACKAGE_PIN AJ14 IOSTANDARD LVCMOS33} [get_ports {j8[12]}]  ;# IO7_P   J8 pin 16  gpio 84
set_property -dict {PACKAGE_PIN AJ13 IOSTANDARD LVCMOS33} [get_ports {j8[13]}]  ;# IO7_N   J8 pin 15  gpio 85
set_property -dict {PACKAGE_PIN AH14 IOSTANDARD LVCMOS33} [get_ports {j8[14]}]  ;# IO8_P   J8 pin 18  gpio 86
set_property -dict {PACKAGE_PIN AH13 IOSTANDARD LVCMOS33} [get_ports {j8[15]}]  ;# IO8_N   J8 pin 17  gpio 87
set_property -dict {PACKAGE_PIN AK13 IOSTANDARD LVCMOS33} [get_ports {j8[16]}]  ;# IO9_P   J8 pin 20  gpio 88
set_property -dict {PACKAGE_PIN AK12 IOSTANDARD LVCMOS33} [get_ports {j8[17]}]  ;# IO9_N   J8 pin 19  gpio 89
set_property -dict {PACKAGE_PIN AE12 IOSTANDARD LVCMOS33} [get_ports {j8[18]}]  ;# IO10_P  J8 pin 22  gpio 90
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports {j8[19]}]  ;# IO10_N  J8 pin 21  gpio 91
set_property -dict {PACKAGE_PIN AG12 IOSTANDARD LVCMOS33} [get_ports {j8[20]}]  ;# IO11_P  J8 pin 24  gpio 92
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports {j8[21]}]  ;# IO11_N  J8 pin 23  gpio 93
set_property -dict {PACKAGE_PIN AE16 IOSTANDARD LVCMOS33} [get_ports {j8[22]}]  ;# IO12_P  J8 pin 26  gpio 94
set_property -dict {PACKAGE_PIN AE15 IOSTANDARD LVCMOS33} [get_ports {j8[23]}]  ;# IO12_N  J8 pin 25  gpio 95
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {j8[24]}]  ;# IO13_P  J8 pin 28  gpio 96
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {j8[25]}]  ;# IO13_N  J8 pin 27  gpio 97
set_property -dict {PACKAGE_PIN AD16 IOSTANDARD LVCMOS33} [get_ports {j8[26]}]  ;# IO14_P  J8 pin 30  gpio 98
set_property -dict {PACKAGE_PIN AD15 IOSTANDARD LVCMOS33} [get_ports {j8[27]}]  ;# IO14_N  J8 pin 29  gpio 99
set_property -dict {PACKAGE_PIN AD14 IOSTANDARD LVCMOS33} [get_ports {j8[28]}]  ;# IO15_P  J8 pin 32  gpio 100
set_property -dict {PACKAGE_PIN AD13 IOSTANDARD LVCMOS33} [get_ports {j8[29]}]  ;# IO15_N  J8 pin 31  gpio 101
set_property -dict {PACKAGE_PIN AC14 IOSTANDARD LVCMOS33} [get_ports {j8[30]}]  ;# IO16_P  J8 pin 34  gpio 102
set_property -dict {PACKAGE_PIN AC13 IOSTANDARD LVCMOS33} [get_ports {j8[31]}]  ;# IO16_N  J8 pin 33  gpio 103
set_property -dict {PACKAGE_PIN AB12 IOSTANDARD LVCMOS33} [get_ports {j8[32]}]  ;# IO17_P  J8 pin 36  gpio 104
set_property -dict {PACKAGE_PIN AC12 IOSTANDARD LVCMOS33} [get_ports {j8[33]}]  ;# IO17_N  J8 pin 35  gpio 105
# <<< end generated J8 pins

set_false_path -to   [get_ports {j8[*]}]
set_false_path -from [get_ports {j8[*]}]
# A weak pull-up on every header pin, so an unconnected pin reads 1 by design
# rather than by whatever a floating input settles to, and a 0 means
# something is pulling it down. It does not disturb a pin driven as an
# output.
set_property PULLUP TRUE [get_ports {j8[*]}]

# ---------------------------------------------------------------------------
# The four oscillators the frequency counters measure (rtl/freq_ctr.v).
#
# ⚠ A constraint written before the clock it names exists silently matches
# nothing. The clocks are created here; the clock groups and clock-based
# exceptions live in rkz7100_pl_timing.xdc.
#
# PL_CLK is an ordinary fabric input. SYS_CLK is the 200 MHz LVDS oscillator
# on bank 34 -- AC-coupled and biased to VCCO/2 on the board, hence
# DIFF_SSTL15 rather than LVDS. The two GTX references go to MGTREFCLK pins,
# which take a PACKAGE_PIN but no IOSTANDARD: they are transceiver inputs.
# The SATA reference reaches the fabric only through
# IBUFDS_GTE2's ODIV2, which is why Vivado derives a half-rate generated clock
# for it. The SFP reference does not reach the fabric by ODIV2 at all: its
# buffer's one route into the fabric is taken by the gtwizard's CPLL
# sequencing, so its frequency is counted through SFP1's TXOUTCLK.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AD18 IOSTANDARD LVCMOS33} [get_ports pl_clk]
create_clock -period 20.000 -name pl_clk [get_ports pl_clk]

set_property -dict {PACKAGE_PIN F9 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN E8 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

set_property PACKAGE_PIN R8 [get_ports gtx_clk156_p]
set_property PACKAGE_PIN R7 [get_ports gtx_clk156_n]
create_clock -period 6.400 -name gtx_clk156 [get_ports gtx_clk156_p]

# The SFP+ cages' serial lanes, GTX quad 112. Dedicated transceiver pins, so
# no IOSTANDARD; pinning the P side of a pair places the whole channel. SFP1
# lands on GTXE2_CHANNEL_X0Y14 and SFP2 on GTXE2_CHANNEL_X0Y15, which
# build.tcl checks after routing rather than trusting these lines.
set_property PACKAGE_PIN P2 [get_ports {sfp_txp[0]}]
set_property PACKAGE_PIN T6 [get_ports {sfp_rxp[0]}]
set_property PACKAGE_PIN N4 [get_ports {sfp_txp[1]}]
set_property PACKAGE_PIN P6 [get_ports {sfp_rxp[1]}]

# The channels' TXOUTCLK, at the FASTEST rate gtx_prbs.v can select: 10.3125
# Gb/s / 40 = 257.8 MHz. Left alone, Vivado derives it from the transceiver's
# attributes, which describe the 3.125 Gb/s the wizard was built for, and
# would time the user-clock logic at 78 MHz. Named *TXOUTCLK so the timing
# XDC's asynchronous group takes them; build.tcl checks both exist with this
# period. The ? stands for the generate brackets.
create_clock -period 3.878 -name sfp1_TXOUTCLK [get_pins -hier -filter {NAME =~ *ch?0?.gtx_i*gtxe2_i/TXOUTCLK}]
create_clock -period 3.878 -name sfp2_TXOUTCLK [get_pins -hier -filter {NAME =~ *ch?1?.gtx_i*gtxe2_i/TXOUTCLK}]

# ⚠ Each gtwizard channel carries a "CPLL railing" block (the UG476 CPLL
# power-up workaround) that clocks a small counter from the reference through
# a BUFH. A BUFH can only take IBUFDS_GTE2.O from ITS OWN clock region, and
# left to itself the placer puts both at BUFHCE_X0Y36, on the other side of
# the device from IBUFDS_GTE2_X0Y7 and the channels in X1Y3, and routing
# fails with "2 unroutable pins" on the net gtx_refclk156. They are LOCed
# rather than given a CLOCK_REGION, which Vivado accepts only on a GLOBAL
# buffer: on a BUFH it is a critical warning and a no-op. The ? stands for the
# generate block's brackets, which a glob would read as a character class.
set_property LOC BUFHCE_X1Y36 [get_cells -hierarchical -filter {REF_NAME =~ BUFH* && NAME =~ *ch?0?.gtx_i*cpll_railing*}]
set_property LOC BUFHCE_X1Y37 [get_cells -hierarchical -filter {REF_NAME =~ BUFH* && NAME =~ *ch?1?.gtx_i*cpll_railing*}]

set_property PACKAGE_PIN N8 [get_ports gtx_sataclk_p]
set_property PACKAGE_PIN N7 [get_ports gtx_sataclk_n]
create_clock -period 6.667 -name gtx_sataclk [get_ports gtx_sataclk_p]

# ---------------------------------------------------------------------------
# HDMI output, ADV7511 (U22), bank 35 at 1.8 V.
#
# 24-bit RGB plus a pixel clock and three control lines. The pixel clock
# leaves through an ODDR (see rtl/hdmi_out.v) so that it takes the same kind
# of output path as the data it has to be aligned with.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN K13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[0]}]
set_property -dict {PACKAGE_PIN E17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[1]}]
set_property -dict {PACKAGE_PIN F17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[2]}]
set_property -dict {PACKAGE_PIN D16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[3]}]
set_property -dict {PACKAGE_PIN E16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[4]}]
set_property -dict {PACKAGE_PIN E15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[5]}]
set_property -dict {PACKAGE_PIN G14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[6]}]
set_property -dict {PACKAGE_PIN D14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[7]}]
set_property -dict {PACKAGE_PIN H13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[8]}]
set_property -dict {PACKAGE_PIN J13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[9]}]
set_property -dict {PACKAGE_PIN G15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[10]}]
set_property -dict {PACKAGE_PIN F15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[11]}]
set_property -dict {PACKAGE_PIN G16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[12]}]
set_property -dict {PACKAGE_PIN C13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[13]}]
set_property -dict {PACKAGE_PIN A15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[14]}]
set_property -dict {PACKAGE_PIN J15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[15]}]
set_property -dict {PACKAGE_PIN B15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[16]}]
set_property -dict {PACKAGE_PIN D15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[17]}]
set_property -dict {PACKAGE_PIN B16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[18]}]
set_property -dict {PACKAGE_PIN A17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[19]}]
set_property -dict {PACKAGE_PIN B17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[20]}]
set_property -dict {PACKAGE_PIN C17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[21]}]
set_property -dict {PACKAGE_PIN J16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[22]}]
set_property -dict {PACKAGE_PIN H16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[23]}]
set_property -dict {PACKAGE_PIN F14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_clk}]
set_property -dict {PACKAGE_PIN J14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_de}]
set_property -dict {PACKAGE_PIN C14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_hsync}]
set_property -dict {PACKAGE_PIN C16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_vsync}]

# Clock groups and clock-based exceptions live in rkz7100_pl_timing.xdc,
# which is implementation-only (see its header).

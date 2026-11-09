# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# RK-ZYNQ7100 PL DDR3 design: everything the MIG does not constrain itself.
#
# The DDR3 pins are NOT here. MIG takes them from mig.prj and emits its own
# XDC; listing them again would collide. This file has the system clock, the
# LEDs, keys and fan, the EMIO pins (I2C, ADV7611 reset, PHY2 MDIO, J8), the
# measured oscillators, and the MIG status crossings.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---------------------------------------------------------------------------
# 200 MHz system clock: LVDS oscillator Y7, bank 34 SRCC, AC-coupled and
# biased to VCCO/2 with 100R across the pair (R172). Bank 34 is the DDR3
# address/control bank at 1.5V, so this is DIFF_SSTL15, not LVDS.
#
# MIG is generated with SystemClock = "No Buffer", so the IBUFDS is in our
# RTL and MIG never sees these as ports -- which means MIG's own XDC does not
# constrain them and this create_clock is the only one.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN F9  IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN E8  IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# ---------------------------------------------------------------------------
# LEDs and keys (see ../../RK_ZYNQ7100_master.xdc)
# ---------------------------------------------------------------------------
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

set_false_path -from [get_ports {key_n[*]}]

# ---------------------------------------------------------------------------
# Clock domain crossings
#
# init_calib_complete and mmcm_locked are generated in the MIG's ui_clk domain
# and read in the PS's fclk_clk0 domain through two-flop synchronizers in
# rkz7100_ddr.v. The first flop of each is where the crossing lands, and it is
# the only place a timing exception belongs -- constrain the D pin, not the
# whole path, so a real path inside either domain is still checked.
# ---------------------------------------------------------------------------
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *calib_sync_reg[0]/D}]
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *locked_sync_reg[0]/D}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

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

# ADV7611 RESET, active low, 4.7K pull-down on the board: the chip stays in
# reset, and off the I2C bus, until this is driven high.
set_property -dict {PACKAGE_PIN AG25 IOSTANDARD LVCMOS33} [get_ports hdmi_rx_rst_n]

# The PL Ethernet PHY's management bus (PHY2, U19, RTL8211F-CG at address 1,
# bank 11), on EMIO GPIO for a bit-banging MDIO driver, so the PHY can be
# identified and configured with no MAC in the fabric at all. MDIO has a
# 1.5K pull-up on the board; MDC is push-pull.
set_property -dict {PACKAGE_PIN AG19 IOSTANDARD LVCMOS33} [get_ports phy2_mdc]
set_property -dict {PACKAGE_PIN AH19 IOSTANDARD LVCMOS33} [get_ports phy2_mdio]
set_false_path -to   [get_ports {phy2_mdc phy2_mdio}]
set_false_path -from [get_ports phy2_mdio]

set_false_path -to   [get_ports {hdmi_tx_scl hdmi_tx_sda hdmi_rx_scl hdmi_rx_sda cam_scl cam_sda hdmi_rx_rst_n}]
set_false_path -from [get_ports {hdmi_tx_scl hdmi_tx_sda hdmi_rx_scl hdmi_rx_sda cam_scl cam_sda}]

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

# ---------------------------------------------------------------------------
# The four oscillators the frequency counters measure (rtl/freq_ctr.v).
#
# ⚠ A constraint written before the clock it names exists silently matches
# nothing. The clocks are created here; the clock groups live in
# rkz7100_ddr_timing.xdc.
#
# PL_CLK is an ordinary fabric input. SYS_CLK is constrained at the top of
# this file. The two GTX references go to MGTREFCLK pins, which take a
# PACKAGE_PIN but no IOSTANDARD: they are transceiver inputs, reaching the
# fabric only through IBUFDS_GTE2's ODIV2, which is why Vivado derives a
# half-rate generated clock for each.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AD18 IOSTANDARD LVCMOS33} [get_ports pl_clk]
create_clock -period 20.000 -name pl_clk [get_ports pl_clk]

# sys_clk is already constrained above; the frequency counter taps the same
# buffered clock the MIG runs on rather than a second one.

set_property PACKAGE_PIN R8 [get_ports gtx_clk156_p]
set_property PACKAGE_PIN R7 [get_ports gtx_clk156_n]
create_clock -period 6.400 -name gtx_clk156 [get_ports gtx_clk156_p]

set_property PACKAGE_PIN N8 [get_ports gtx_sataclk_p]
set_property PACKAGE_PIN N7 [get_ports gtx_sataclk_n]
create_clock -period 6.667 -name gtx_sataclk [get_ports gtx_sataclk_p]


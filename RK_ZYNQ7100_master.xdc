# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# RK-ZYNQ7100 development board (xc7z100ffg900-2) master constraints
#
# PL pins only: the PS side (MIO, PS DDR3) is configured by the processing_system7
# IP, not by XDC. Every line is commented out; uncomment what your design uses.
#
# Derived from the vendor schematic (z7100-schematic, 24 sheets, OCR scan), every
# pin checked against the Vivado xc7z100ffg900 package pinout (pin function, bank,
# differential partner). The FMC LA assignment is confirmed by the validated
# AD9361/FMCOMMS2 constraints in github.com/R0Y00/rk-zynq7100-fmcomms2-linux.
#
# PL bank voltages (VCCO):
#   Bank 9   HR 3.3V      SFP control, PCIe PERST#, camera I2C/clock, 50 MHz PL_CLK, FMC PRSNT
#   Bank 10  HR VCC_ADJ2  40-pin header, PL_LED1-4 (LED4-LED7), keys 1-4. Default 3.3V (RA2 = 3.24K).
#   Bank 11  HR 3.3V      HDMI RX (ADV7611), PL Ethernet PHY2 (RGMII), fan, FMC I2C, FMC PG_C2M
#   Bank 12  HR VCC_ADJ1  FMC LA (FMC VADJ). Default 2.5V (RA1 = 4.7K; 8.06K = 1.8V, 3.24K = 3.3V).
#   Bank 13  HR VCC_ADJ1  FMC LA
#   Bank 33  HP 1.5V      PL DDR3 data
#   Bank 34  HP 1.5V      PL DDR3 address/control, 200 MHz SYS_CLK
#   Bank 35  HP 1.8V      HDMI TX (ADV7511), MIPI CSI-2, PL_LED5/6 (LED8)
#   GTX 109/110 FMC DP0-7 | 111 PCIe x4 | 112 SATA x2 + SFP+ x2
#   Bank 0 (config) 3.3V; MIO bank 500 3.3V; MIO bank 501 1.8V; PS DDR bank 502 1.5V.

#set_property CFGBVS VCCO [current_design]
#set_property CONFIG_VOLTAGE 3.3 [current_design]

#------------------------------------------------------------------------------
# Clocks
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN AD18 IOSTANDARD LVCMOS33} [get_ports {pl_clk}]               ;# PL_CLK  50 MHz oscillator Y2 (bank 9 MRCC)
#create_clock -period 20.000 -name pl_clk [get_ports pl_clk]
#set_property -dict {PACKAGE_PIN F9   IOSTANDARD DIFF_SSTL15} [get_ports {sys_clk_p}]         ;# SYS_CLK_P  200 MHz LVDS osc Y7, AC-coupled, biased to VCCO/2, 100R (R172)
#set_property -dict {PACKAGE_PIN E8   IOSTANDARD DIFF_SSTL15} [get_ports {sys_clk_n}]         ;# SYS_CLK_N
#create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]
#set_property PACKAGE_PIN R8   [get_ports {gtx_clk156_p}]                                     ;# GTX_CLK156P25_P  156.25 MHz SiT9120 (Y8), MGTREFCLK1_112 (SFP+)
#set_property PACKAGE_PIN R7   [get_ports {gtx_clk156_n}]                                     ;# GTX_CLK156P25_N
#create_clock -period 6.400 -name gtx_clk156 [get_ports gtx_clk156_p]
#set_property PACKAGE_PIN N8   [get_ports {gtx_sataclk_p}]                                    ;# GTX_SATACLK_P  150 MHz osc Y9, MGTREFCLK0_112 (SATA)
#set_property PACKAGE_PIN N7   [get_ports {gtx_sataclk_n}]                                    ;# GTX_SATACLK_N
#create_clock -period 6.667 -name gtx_sataclk [get_ports gtx_sataclk_p]

#------------------------------------------------------------------------------
# User LEDs and keys
#   PL_LED1-4 (green LED4-LED7) and the bicolor LED8 (PL_LED5/6) are driven by NPN transistors: 1 = on.
#   KEY1-4 pull to GND against 4.7K pull-ups to VCC_ADJ2: pressed = 0.
#   Bank 10 IOSTANDARD follows VCC_ADJ2 (LVCMOS33 at the default 3.3V).
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN AC16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]               ;# PL_LED1  bank 10
#set_property -dict {PACKAGE_PIN AC17 IOSTANDARD LVCMOS33} [get_ports {led[1]}]               ;# PL_LED2  bank 10
#set_property -dict {PACKAGE_PIN AH18 IOSTANDARD LVCMOS33} [get_ports {led[2]}]               ;# PL_LED3  bank 10
#set_property -dict {PACKAGE_PIN AE18 IOSTANDARD LVCMOS33} [get_ports {led[3]}]               ;# PL_LED4  bank 10
#set_property -dict {PACKAGE_PIN G12  IOSTANDARD LVCMOS18} [get_ports {led[4]}]               ;# PL_LED5  bank 35, bicolor LED8 half A
#set_property -dict {PACKAGE_PIN F12  IOSTANDARD LVCMOS18} [get_ports {led[5]}]               ;# PL_LED6  bank 35, bicolor LED8 half B
#set_property -dict {PACKAGE_PIN AJ18 IOSTANDARD LVCMOS33} [get_ports {key_n[0]}]             ;# PL_KEY1  bank 10, active low
#set_property -dict {PACKAGE_PIN AE17 IOSTANDARD LVCMOS33} [get_ports {key_n[1]}]             ;# PL_KEY2  bank 10, active low
#set_property -dict {PACKAGE_PIN AF17 IOSTANDARD LVCMOS33} [get_ports {key_n[2]}]             ;# PL_KEY3  bank 10, active low
#set_property -dict {PACKAGE_PIN AF18 IOSTANDARD LVCMOS33} [get_ports {key_n[3]}]             ;# PL_KEY4  bank 10, active low

#------------------------------------------------------------------------------
# Fan (J10, 4-pin, 12V)
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN W21  IOSTANDARD LVCMOS33} [get_ports {fan_pwm}]              ;# FAN_PWM  drives NPN Q7 via 4.7K: 1 pulls the fan PWM line low (inverted)
#set_property -dict {PACKAGE_PIN Y21  IOSTANDARD LVCMOS33} [get_ports {fan_tach}]             ;# FAN_TACH  33R + 4.7K pull-up to 3.3V

#------------------------------------------------------------------------------
# PL DDR3, 2x MT41J256M16 = 32-bit, 1 GB (banks 33/34, 1.5V)
#   Let the MIG 7-series IP set the I/O standards; only pin locations are listed here.
#   System clock: sys_clk_p/n (F9/E8), 200 MHz. VRN/VRP (DCI) on L5/L4 (bank 33) and M12/M10 (bank 34).
#   Bank 34 IO_L3P_T0_DQS_PUDC_B (A8) is pulled to GND via 1K: I/O pull-ups ON during configuration.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN J4  } [get_ports {ddr3_dq[0]}]                               ;# PL_DDR3_DQ0
#set_property -dict {PACKAGE_PIN K1  } [get_ports {ddr3_dq[1]}]                               ;# PL_DDR3_DQ1
#set_property -dict {PACKAGE_PIN J5  } [get_ports {ddr3_dq[2]}]                               ;# PL_DDR3_DQ2
#set_property -dict {PACKAGE_PIN K5  } [get_ports {ddr3_dq[3]}]                               ;# PL_DDR3_DQ3
#set_property -dict {PACKAGE_PIN J3  } [get_ports {ddr3_dq[4]}]                               ;# PL_DDR3_DQ4
#set_property -dict {PACKAGE_PIN L3  } [get_ports {ddr3_dq[5]}]                               ;# PL_DDR3_DQ5
#set_property -dict {PACKAGE_PIN K6  } [get_ports {ddr3_dq[6]}]                               ;# PL_DDR3_DQ6
#set_property -dict {PACKAGE_PIN L2  } [get_ports {ddr3_dq[7]}]                               ;# PL_DDR3_DQ7
#set_property -dict {PACKAGE_PIN G1  } [get_ports {ddr3_dq[8]}]                               ;# PL_DDR3_DQ8
#set_property -dict {PACKAGE_PIN H6  } [get_ports {ddr3_dq[9]}]                               ;# PL_DDR3_DQ9
#set_property -dict {PACKAGE_PIN H2  } [get_ports {ddr3_dq[10]}]                              ;# PL_DDR3_DQ10
#set_property -dict {PACKAGE_PIN G6  } [get_ports {ddr3_dq[11]}]                              ;# PL_DDR3_DQ11
#set_property -dict {PACKAGE_PIN H4  } [get_ports {ddr3_dq[12]}]                              ;# PL_DDR3_DQ12
#set_property -dict {PACKAGE_PIN G5  } [get_ports {ddr3_dq[13]}]                              ;# PL_DDR3_DQ13
#set_property -dict {PACKAGE_PIN H3  } [get_ports {ddr3_dq[14]}]                              ;# PL_DDR3_DQ14
#set_property -dict {PACKAGE_PIN F2  } [get_ports {ddr3_dq[15]}]                              ;# PL_DDR3_DQ15
#set_property -dict {PACKAGE_PIN F3  } [get_ports {ddr3_dq[16]}]                              ;# PL_DDR3_DQ16
#set_property -dict {PACKAGE_PIN E3  } [get_ports {ddr3_dq[17]}]                              ;# PL_DDR3_DQ17
#set_property -dict {PACKAGE_PIN F4  } [get_ports {ddr3_dq[18]}]                              ;# PL_DDR3_DQ18
#set_property -dict {PACKAGE_PIN D1  } [get_ports {ddr3_dq[19]}]                              ;# PL_DDR3_DQ19
#set_property -dict {PACKAGE_PIN D4  } [get_ports {ddr3_dq[20]}]                              ;# PL_DDR3_DQ20
#set_property -dict {PACKAGE_PIN E1  } [get_ports {ddr3_dq[21]}]                              ;# PL_DDR3_DQ21
#set_property -dict {PACKAGE_PIN E5  } [get_ports {ddr3_dq[22]}]                              ;# PL_DDR3_DQ22
#set_property -dict {PACKAGE_PIN E2  } [get_ports {ddr3_dq[23]}]                              ;# PL_DDR3_DQ23
#set_property -dict {PACKAGE_PIN C1  } [get_ports {ddr3_dq[24]}]                              ;# PL_DDR3_DQ24
#set_property -dict {PACKAGE_PIN A3  } [get_ports {ddr3_dq[25]}]                              ;# PL_DDR3_DQ25
#set_property -dict {PACKAGE_PIN B1  } [get_ports {ddr3_dq[26]}]                              ;# PL_DDR3_DQ26
#set_property -dict {PACKAGE_PIN B5  } [get_ports {ddr3_dq[27]}]                              ;# PL_DDR3_DQ27
#set_property -dict {PACKAGE_PIN B2  } [get_ports {ddr3_dq[28]}]                              ;# PL_DDR3_DQ28
#set_property -dict {PACKAGE_PIN C4  } [get_ports {ddr3_dq[29]}]                              ;# PL_DDR3_DQ29
#set_property -dict {PACKAGE_PIN C2  } [get_ports {ddr3_dq[30]}]                              ;# PL_DDR3_DQ30
#set_property -dict {PACKAGE_PIN B4  } [get_ports {ddr3_dq[31]}]                              ;# PL_DDR3_DQ31
#set_property -dict {PACKAGE_PIN K3  } [get_ports {ddr3_dqs_p[0]}]                            ;# PL_DDR3_DQS0_P
#set_property -dict {PACKAGE_PIN K2  } [get_ports {ddr3_dqs_n[0]}]                            ;# PL_DDR3_DQS0_N
#set_property -dict {PACKAGE_PIN J1  } [get_ports {ddr3_dqs_p[1]}]                            ;# PL_DDR3_DQS1_P
#set_property -dict {PACKAGE_PIN H1  } [get_ports {ddr3_dqs_n[1]}]                            ;# PL_DDR3_DQS1_N
#set_property -dict {PACKAGE_PIN E6  } [get_ports {ddr3_dqs_p[2]}]                            ;# PL_DDR3_DQS2_P
#set_property -dict {PACKAGE_PIN D5  } [get_ports {ddr3_dqs_n[2]}]                            ;# PL_DDR3_DQS2_N
#set_property -dict {PACKAGE_PIN A5  } [get_ports {ddr3_dqs_p[3]}]                            ;# PL_DDR3_DQS3_P
#set_property -dict {PACKAGE_PIN A4  } [get_ports {ddr3_dqs_n[3]}]                            ;# PL_DDR3_DQS3_N
#set_property -dict {PACKAGE_PIN L1  } [get_ports {ddr3_dm[0]}]                               ;# PL_DDR3_DM0
#set_property -dict {PACKAGE_PIN G4  } [get_ports {ddr3_dm[1]}]                               ;# PL_DDR3_DM1
#set_property -dict {PACKAGE_PIN D3  } [get_ports {ddr3_dm[2]}]                               ;# PL_DDR3_DM2
#set_property -dict {PACKAGE_PIN A2  } [get_ports {ddr3_dm[3]}]                               ;# PL_DDR3_DM3
#set_property -dict {PACKAGE_PIN H7  } [get_ports {ddr3_addr[0]}]                             ;# PL_DDR3_A0
#set_property -dict {PACKAGE_PIN L8  } [get_ports {ddr3_addr[1]}]                             ;# PL_DDR3_A1
#set_property -dict {PACKAGE_PIN H11 } [get_ports {ddr3_addr[2]}]                             ;# PL_DDR3_A2
#set_property -dict {PACKAGE_PIN D10 } [get_ports {ddr3_addr[3]}]                             ;# PL_DDR3_A3
#set_property -dict {PACKAGE_PIN H8  } [get_ports {ddr3_addr[4]}]                             ;# PL_DDR3_A4
#set_property -dict {PACKAGE_PIN D11 } [get_ports {ddr3_addr[5]}]                             ;# PL_DDR3_A5
#set_property -dict {PACKAGE_PIN L7  } [get_ports {ddr3_addr[6]}]                             ;# PL_DDR3_A6
#set_property -dict {PACKAGE_PIN E10 } [get_ports {ddr3_addr[7]}]                             ;# PL_DDR3_A7
#set_property -dict {PACKAGE_PIN L10 } [get_ports {ddr3_addr[8]}]                             ;# PL_DDR3_A8
#set_property -dict {PACKAGE_PIN H12 } [get_ports {ddr3_addr[9]}]                             ;# PL_DDR3_A9
#set_property -dict {PACKAGE_PIN G7  } [get_ports {ddr3_addr[10]}]                            ;# PL_DDR3_A10
#set_property -dict {PACKAGE_PIN J9  } [get_ports {ddr3_addr[11]}]                            ;# PL_DDR3_A11
#set_property -dict {PACKAGE_PIN H9  } [get_ports {ddr3_addr[12]}]                            ;# PL_DDR3_A12
#set_property -dict {PACKAGE_PIN J11 } [get_ports {ddr3_addr[13]}]                            ;# PL_DDR3_A13
#set_property -dict {PACKAGE_PIN K10 } [get_ports {ddr3_addr[14]}]                            ;# PL_DDR3_A14
#set_property -dict {PACKAGE_PIN K11 } [get_ports {ddr3_ba[0]}]                               ;# PL_DDR3_BA0
#set_property -dict {PACKAGE_PIN K8  } [get_ports {ddr3_ba[1]}]                               ;# PL_DDR3_BA1
#set_property -dict {PACKAGE_PIN G11 } [get_ports {ddr3_ba[2]}]                               ;# PL_DDR3_BA2
#set_property -dict {PACKAGE_PIN G9  } [get_ports {ddr3_ras_n}]                               ;# PL_DDR3_RAS_B
#set_property -dict {PACKAGE_PIN E7  } [get_ports {ddr3_cas_n}]                               ;# PL_DDR3_CAS_B
#set_property -dict {PACKAGE_PIN F7  } [get_ports {ddr3_we_n}]                                ;# PL_DDR3_WE_B
#set_property -dict {PACKAGE_PIN F8  } [get_ports {ddr3_cs_n[0]}]                             ;# PL_DDR3_S0_B
#set_property -dict {PACKAGE_PIN D6  } [get_ports {ddr3_cke[0]}]                              ;# PL_DDR3_CKE
#set_property -dict {PACKAGE_PIN J10 } [get_ports {ddr3_odt[0]}]                              ;# PL_DDR3_ODT
#set_property -dict {PACKAGE_PIN E11 } [get_ports {ddr3_reset_n}]                             ;# PL_DDR3_RST
#set_property -dict {PACKAGE_PIN D9  } [get_ports {ddr3_ck_p[0]}]                             ;# PL_DDR3_CLK_P
#set_property -dict {PACKAGE_PIN D8  } [get_ports {ddr3_ck_n[0]}]                             ;# PL_DDR3_CLK_N

#------------------------------------------------------------------------------
# PCIe Gen2 x4 edge connector (GTX quad 111). Lane order is reversed: lane 0 = channel 3.
#------------------------------------------------------------------------------
#set_property PACKAGE_PIN U8   [get_ports {pcie_refclk_p}]                                    ;# PCIE_CLK_P  100 MHz from the slot, AC-coupled, MGTREFCLK0_111
#set_property PACKAGE_PIN U7   [get_ports {pcie_refclk_n}]                                    ;# PCIE_CLK_N
#create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]
#set_property -dict {PACKAGE_PIN AC18 IOSTANDARD LVCMOS33} [get_ports {pcie_perst_n}]         ;# PCIE_RESET  PERST#, 4.7K pull-up to 3.3V (bank 9)
#set_property PACKAGE_PIN V2   [get_ports {pcie_txp[0]}]                                      ;# PCIE_TX0_P
#set_property PACKAGE_PIN V1   [get_ports {pcie_txn[0]}]                                      ;# PCIE_TX0_N
#set_property PACKAGE_PIN AA4  [get_ports {pcie_rxp[0]}]                                      ;# PCIE_RX0_P
#set_property PACKAGE_PIN AA3  [get_ports {pcie_rxn[0]}]                                      ;# PCIE_RX0_N
#set_property PACKAGE_PIN W4   [get_ports {pcie_txp[1]}]                                      ;# PCIE_TX1_P
#set_property PACKAGE_PIN W3   [get_ports {pcie_txn[1]}]                                      ;# PCIE_TX1_N
#set_property PACKAGE_PIN Y6   [get_ports {pcie_rxp[1]}]                                      ;# PCIE_RX1_P
#set_property PACKAGE_PIN Y5   [get_ports {pcie_rxn[1]}]                                      ;# PCIE_RX1_N
#set_property PACKAGE_PIN Y2   [get_ports {pcie_txp[2]}]                                      ;# PCIE_TX2_P
#set_property PACKAGE_PIN Y1   [get_ports {pcie_txn[2]}]                                      ;# PCIE_TX2_N
#set_property PACKAGE_PIN AB6  [get_ports {pcie_rxp[2]}]                                      ;# PCIE_RX2_P
#set_property PACKAGE_PIN AB5  [get_ports {pcie_rxn[2]}]                                      ;# PCIE_RX2_N
#set_property PACKAGE_PIN AB2  [get_ports {pcie_txp[3]}]                                      ;# PCIE_TX3_P
#set_property PACKAGE_PIN AB1  [get_ports {pcie_txn[3]}]                                      ;# PCIE_TX3_N
#set_property PACKAGE_PIN AC4  [get_ports {pcie_rxp[3]}]                                      ;# PCIE_RX3_P
#set_property PACKAGE_PIN AC3  [get_ports {pcie_rxn[3]}]                                      ;# PCIE_RX3_N

#------------------------------------------------------------------------------
# SFP+ x2 and SATA x2 (GTX quad 112)
#   SFP+: MOD-DEF0/1/2 and RS0/RS1 are pulled up to 3.3V only; not connected to the FPGA; TX_FAULT is tied to ground.
#   SATA: J5/J6 7-pin connectors, both directions AC-coupled on the board.
#------------------------------------------------------------------------------
#set_property PACKAGE_PIN P2   [get_ports {sfp1_txp}]                                         ;# SFP1_TX_P  SFP1 cage
#set_property PACKAGE_PIN P1   [get_ports {sfp1_txn}]                                         ;# SFP1_TX_N
#set_property PACKAGE_PIN T6   [get_ports {sfp1_rxp}]                                         ;# SFP1_RX_P
#set_property PACKAGE_PIN T5   [get_ports {sfp1_rxn}]                                         ;# SFP1_RX_N
#set_property -dict {PACKAGE_PIN AB19 IOSTANDARD LVCMOS33} [get_ports {sfp1_tx_disable}]      ;# SFP1_TX_DIS  4.7K pull-up: TX disabled until driven low
#set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33} [get_ports {sfp1_los}]             ;# SFP1_LOSS  RX loss of signal, 4.7K pull-up
#set_property PACKAGE_PIN N4   [get_ports {sfp2_txp}]                                         ;# SFP2_TX_P  SFP2 cage
#set_property PACKAGE_PIN N3   [get_ports {sfp2_txn}]                                         ;# SFP2_TX_N
#set_property PACKAGE_PIN P6   [get_ports {sfp2_rxp}]                                         ;# SFP2_RX_P
#set_property PACKAGE_PIN P5   [get_ports {sfp2_rxn}]                                         ;# SFP2_RX_N
#set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports {sfp2_tx_disable}]      ;# SFP2_TX_DIS  4.7K pull-up: TX disabled until driven low
#set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports {sfp2_los}]             ;# SFP2_LOSS  RX loss of signal, 4.7K pull-up
#set_property PACKAGE_PIN T2   [get_ports {sata1_txp}]                                        ;# SATA1_TX_P  SATA1 (J5)
#set_property PACKAGE_PIN T1   [get_ports {sata1_txn}]                                        ;# SATA1_TX_N
#set_property PACKAGE_PIN V6   [get_ports {sata1_rxp}]                                        ;# SATA1_RX_P
#set_property PACKAGE_PIN V5   [get_ports {sata1_rxn}]                                        ;# SATA1_RX_N
#set_property PACKAGE_PIN R4   [get_ports {sata2_txp}]                                        ;# SATA2_TX_P  SATA2 (J6)
#set_property PACKAGE_PIN R3   [get_ports {sata2_txn}]                                        ;# SATA2_TX_N
#set_property PACKAGE_PIN U4   [get_ports {sata2_rxp}]                                        ;# SATA2_RX_P
#set_property PACKAGE_PIN U3   [get_ports {sata2_rxn}]                                        ;# SATA2_RX_N

#------------------------------------------------------------------------------
# HDMI output, ADV7511 (bank 35, 1.8V)
#   24-bit parallel video: HDMI_TX_D[23:16] -> ADV7511 D[35:28], [15:8] -> D[23:16], [7:0] -> D[11:4].
#   I2C: 2K pull-ups to 1.8V; ADV7511 main map at 0x72 (8-bit) / 0x39 (7-bit), PD/AD pin tied low.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN K13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[0]}]         ;# HDMI_TX_D0
#set_property -dict {PACKAGE_PIN E17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[1]}]         ;# HDMI_TX_D1
#set_property -dict {PACKAGE_PIN F17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[2]}]         ;# HDMI_TX_D2
#set_property -dict {PACKAGE_PIN D16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[3]}]         ;# HDMI_TX_D3
#set_property -dict {PACKAGE_PIN E16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[4]}]         ;# HDMI_TX_D4
#set_property -dict {PACKAGE_PIN E15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[5]}]         ;# HDMI_TX_D5
#set_property -dict {PACKAGE_PIN G14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[6]}]         ;# HDMI_TX_D6
#set_property -dict {PACKAGE_PIN D14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[7]}]         ;# HDMI_TX_D7
#set_property -dict {PACKAGE_PIN H13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[8]}]         ;# HDMI_TX_D8
#set_property -dict {PACKAGE_PIN J13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[9]}]         ;# HDMI_TX_D9
#set_property -dict {PACKAGE_PIN G15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[10]}]        ;# HDMI_TX_D10
#set_property -dict {PACKAGE_PIN F15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[11]}]        ;# HDMI_TX_D11
#set_property -dict {PACKAGE_PIN G16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[12]}]        ;# HDMI_TX_D12
#set_property -dict {PACKAGE_PIN C13  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[13]}]        ;# HDMI_TX_D13
#set_property -dict {PACKAGE_PIN A15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[14]}]        ;# HDMI_TX_D14
#set_property -dict {PACKAGE_PIN J15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[15]}]        ;# HDMI_TX_D15
#set_property -dict {PACKAGE_PIN B15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[16]}]        ;# HDMI_TX_D16
#set_property -dict {PACKAGE_PIN D15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[17]}]        ;# HDMI_TX_D17
#set_property -dict {PACKAGE_PIN B16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[18]}]        ;# HDMI_TX_D18
#set_property -dict {PACKAGE_PIN A17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[19]}]        ;# HDMI_TX_D19
#set_property -dict {PACKAGE_PIN B17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[20]}]        ;# HDMI_TX_D20
#set_property -dict {PACKAGE_PIN C17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[21]}]        ;# HDMI_TX_D21
#set_property -dict {PACKAGE_PIN J16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[22]}]        ;# HDMI_TX_D22
#set_property -dict {PACKAGE_PIN H16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_d[23]}]        ;# HDMI_TX_D23
#set_property -dict {PACKAGE_PIN F14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_clk}]          ;# HDMI_TX_CLK  pixel clock to the ADV7511
#set_property -dict {PACKAGE_PIN J14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_de}]           ;# HDMI_TX_DE
#set_property -dict {PACKAGE_PIN C14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_hs}]           ;# HDMI_TX_HSYNC
#set_property -dict {PACKAGE_PIN C16  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_vs}]           ;# HDMI_TX_VSYNC
#set_property -dict {PACKAGE_PIN H14  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_scl}]          ;# HDMI_TX_SCL
#set_property -dict {PACKAGE_PIN K15  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_sda}]          ;# HDMI_TX_SDA
#set_property -dict {PACKAGE_PIN G17  IOSTANDARD LVCMOS18} [get_ports {hdmi_tx_int}]          ;# HDMI_TX_INT  interrupt from the ADV7511 (2K pull-up)

#------------------------------------------------------------------------------
# HDMI input, ADV7611 (bank 11, 3.3V)
#   24-bit parallel video through 33R series resistors. RESET has a 4.7K pull-down: the
#   ADV7611 stays in reset until the FPGA drives HDMI_RX_RST high. I2C: 2K pull-ups to 3.3V.
#   The ADV7611 answers EDID itself (DDCA); HPD to the source is driven by its HPA_A pin.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN AC22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[0]}]         ;# HDMI_RX_D0
#set_property -dict {PACKAGE_PIN AE23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[1]}]         ;# HDMI_RX_D1
#set_property -dict {PACKAGE_PIN AF24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[2]}]         ;# HDMI_RX_D2
#set_property -dict {PACKAGE_PIN AH23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[3]}]         ;# HDMI_RX_D3
#set_property -dict {PACKAGE_PIN AG22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[4]}]         ;# HDMI_RX_D4
#set_property -dict {PACKAGE_PIN AF22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[5]}]         ;# HDMI_RX_D5
#set_property -dict {PACKAGE_PIN AF23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[6]}]         ;# HDMI_RX_D6
#set_property -dict {PACKAGE_PIN AH22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[7]}]         ;# HDMI_RX_D7
#set_property -dict {PACKAGE_PIN AE22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[8]}]         ;# HDMI_RX_D8
#set_property -dict {PACKAGE_PIN AC23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[9]}]         ;# HDMI_RX_D9
#set_property -dict {PACKAGE_PIN AK17 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[10]}]        ;# HDMI_RX_D10
#set_property -dict {PACKAGE_PIN AK18 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[11]}]        ;# HDMI_RX_D11
#set_property -dict {PACKAGE_PIN AJ19 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[12]}]        ;# HDMI_RX_D12
#set_property -dict {PACKAGE_PIN AK20 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[13]}]        ;# HDMI_RX_D13
#set_property -dict {PACKAGE_PIN AK21 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[14]}]        ;# HDMI_RX_D14
#set_property -dict {PACKAGE_PIN AJ21 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[15]}]        ;# HDMI_RX_D15
#set_property -dict {PACKAGE_PIN AK22 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[16]}]        ;# HDMI_RX_D16
#set_property -dict {PACKAGE_PIN AK23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[17]}]        ;# HDMI_RX_D17
#set_property -dict {PACKAGE_PIN AJ23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[18]}]        ;# HDMI_RX_D18
#set_property -dict {PACKAGE_PIN AK25 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[19]}]        ;# HDMI_RX_D19
#set_property -dict {PACKAGE_PIN AJ25 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[20]}]        ;# HDMI_RX_D20
#set_property -dict {PACKAGE_PIN AA23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[21]}]        ;# HDMI_RX_D21
#set_property -dict {PACKAGE_PIN AA24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[22]}]        ;# HDMI_RX_D22
#set_property -dict {PACKAGE_PIN AB24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_d[23]}]        ;# HDMI_RX_D23
#set_property -dict {PACKAGE_PIN AD23 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_pclk}]         ;# HDMI_RX_PCLK  LLC pixel clock from the ADV7611 (SRCC)
#create_clock -period 6.734 -name hdmi_rx_pclk [get_ports hdmi_rx_pclk]   ;# 148.5 MHz (1080p60); pl/board's capture closes only 74.25 MHz (13.468 ns)
#set_property -dict {PACKAGE_PIN AJ24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_de}]           ;# HDMI_RX_DE
#set_property -dict {PACKAGE_PIN AH24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_hs}]           ;# HDMI_RX_HS
#set_property -dict {PACKAGE_PIN AG24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_vs}]           ;# HDMI_RX_VS
#set_property -dict {PACKAGE_PIN AC24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_scl}]          ;# HDMI_RX_SCL
#set_property -dict {PACKAGE_PIN AD24 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_sda}]          ;# HDMI_RX_SDA
#set_property -dict {PACKAGE_PIN AG25 IOSTANDARD LVCMOS33} [get_ports {hdmi_rx_rst_n}]        ;# HDMI_RX_RST  ADV7611 RESET (active low)

#------------------------------------------------------------------------------
# PL Gigabit Ethernet, RTL8211F-CG PHY2 in RGMII (bank 11, 3.3V), PHY address 001
#   PHY2 I/O runs at 3.3V (CFG_LDO = 00). PHYRSTB and INTB are pulled up only, not wired to the FPGA.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports {phy2_txd[0]}]          ;# PHY2_TXD0
#set_property -dict {PACKAGE_PIN AA22 IOSTANDARD LVCMOS33} [get_ports {phy2_txd[1]}]          ;# PHY2_TXD1
#set_property -dict {PACKAGE_PIN AD21 IOSTANDARD LVCMOS33} [get_ports {phy2_txd[2]}]          ;# PHY2_TXD2
#set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {phy2_txd[3]}]          ;# PHY2_TXD3
#set_property -dict {PACKAGE_PIN AF19 IOSTANDARD LVCMOS33} [get_ports {phy2_tx_ctl}]          ;# PHY2_TXCTL
#set_property -dict {PACKAGE_PIN Y22  IOSTANDARD LVCMOS33} [get_ports {phy2_txc}]             ;# PHY2_TXCK  TX clock, FPGA -> PHY
#set_property -dict {PACKAGE_PIN AJ20 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[0]}]          ;# PHY2_RXD0
#set_property -dict {PACKAGE_PIN AE21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[1]}]          ;# PHY2_RXD1
#set_property -dict {PACKAGE_PIN AG21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[2]}]          ;# PHY2_RXD2
#set_property -dict {PACKAGE_PIN AH21 IOSTANDARD LVCMOS33} [get_ports {phy2_rxd[3]}]          ;# PHY2_RXD3
#set_property -dict {PACKAGE_PIN AG20 IOSTANDARD LVCMOS33} [get_ports {phy2_rx_ctl}]          ;# PHY2_RXCTL
#set_property -dict {PACKAGE_PIN AF20 IOSTANDARD LVCMOS33} [get_ports {phy2_rxc}]             ;# PHY2_RXCK  RX clock, PHY -> FPGA (SRCC)
#create_clock -period 8.000 -name phy2_rxc [get_ports phy2_rxc]
#set_property -dict {PACKAGE_PIN AG19 IOSTANDARD LVCMOS33} [get_ports {phy2_mdc}]             ;# PHY2_MDC
#set_property -dict {PACKAGE_PIN AH19 IOSTANDARD LVCMOS33} [get_ports {phy2_mdio}]            ;# PHY2_MDIO  1.5K pull-up

#------------------------------------------------------------------------------
# MIPI CSI-2 camera, 2 lanes, FPC J9 (bank 35, 1.8V)
#   Passive D-PHY network (XAPP894 style): each HS pair (MIPI_CLK/LAN0/LAN1) also reaches an
#   LP pair (MIPI_LPCLK/LP0/LP1) through 100R, with 150R across each pair. XAPP894 uses LVDS
#   for HS and HSUL_12 for LP on an HP bank; HSUL_12 needs INTERNAL_VREF 0.6 on bank 35.
#   Camera I2C (CAM_EE_SCL/SDA) is shared with the AT24C256 EEPROM at 0x50.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN E13  IOSTANDARD LVDS} [get_ports {mipi_clk_p}]               ;# MIPI_CLK_P  HS clock
#set_property -dict {PACKAGE_PIN D13  IOSTANDARD LVDS} [get_ports {mipi_clk_n}]               ;# MIPI_CLK_N
#set_property -dict {PACKAGE_PIN C11  IOSTANDARD LVDS} [get_ports {mipi_d_p[0]}]              ;# MIPI_LAN0_P  HS lane 0
#set_property -dict {PACKAGE_PIN B11  IOSTANDARD LVDS} [get_ports {mipi_d_n[0]}]              ;# MIPI_LAN0_N
#set_property -dict {PACKAGE_PIN C12  IOSTANDARD LVDS} [get_ports {mipi_d_p[1]}]              ;# MIPI_LAN1_P  HS lane 1
#set_property -dict {PACKAGE_PIN B12  IOSTANDARD LVDS} [get_ports {mipi_d_n[1]}]              ;# MIPI_LAN1_N
#set_property -dict {PACKAGE_PIN B14  IOSTANDARD HSUL_12} [get_ports {mipi_lp_clk_p}]         ;# MIPI_LPCLK_P  LP clock
#set_property -dict {PACKAGE_PIN A14  IOSTANDARD HSUL_12} [get_ports {mipi_lp_clk_n}]         ;# MIPI_LPCLK_N
#set_property -dict {PACKAGE_PIN A13  IOSTANDARD HSUL_12} [get_ports {mipi_lp_d_p[0]}]        ;# MIPI_LP0_P  LP lane 0
#set_property -dict {PACKAGE_PIN A12  IOSTANDARD HSUL_12} [get_ports {mipi_lp_d_n[0]}]        ;# MIPI_LP0_N
#set_property -dict {PACKAGE_PIN F13  IOSTANDARD HSUL_12} [get_ports {mipi_lp_d_p[1]}]        ;# MIPI_LP1_P  LP lane 1
#set_property -dict {PACKAGE_PIN E12  IOSTANDARD HSUL_12} [get_ports {mipi_lp_d_n[1]}]        ;# MIPI_LP1_N
#set_property INTERNAL_VREF 0.6 [get_iobanks 35]
#set_property -dict {PACKAGE_PIN AD20 IOSTANDARD LVCMOS33} [get_ports {cam_clk}]              ;# CAM_CLK  bank 9, J9 pin 4 (the Pi connector's CAM_IO1; the OV5647 module has its own oscillator)
#set_property -dict {PACKAGE_PIN AD19 IOSTANDARD LVCMOS33} [get_ports {cam_gpio}]             ;# CAM_GPIO  bank 9, J9 pin 5 (the Pi connector's CAM_IO0: the OV5647 module's power enable)
#set_property -dict {PACKAGE_PIN AC19 IOSTANDARD LVCMOS33} [get_ports {cam_scl}]              ;# CAM_EE_SCL  bank 9, camera + EEPROM I2C, 4.7K pull-up
#set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports {cam_sda}]              ;# CAM_EE_SDA  bank 9

#------------------------------------------------------------------------------
# 40-pin header J8 (bank 10, VCC_ADJ2), 17 differential pairs
#   Header pin 2k+2 = IOk_P, 2k+1 = IOk_N (k = 1..17). Pins 1/37/38 GND, 2 +5V, 39/40 +3.3V.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN AJ16 IOSTANDARD LVCMOS33} [get_ports {gpio_p[1]}]            ;# IO1_P  J8 pin 4
#set_property -dict {PACKAGE_PIN AK16 IOSTANDARD LVCMOS33} [get_ports {gpio_n[1]}]            ;# IO1_N  J8 pin 3
#set_property -dict {PACKAGE_PIN AG17 IOSTANDARD LVCMOS33} [get_ports {gpio_p[2]}]            ;# IO2_P  J8 pin 6
#set_property -dict {PACKAGE_PIN AG16 IOSTANDARD LVCMOS33} [get_ports {gpio_n[2]}]            ;# IO2_N  J8 pin 5
#set_property -dict {PACKAGE_PIN AH17 IOSTANDARD LVCMOS33} [get_ports {gpio_p[3]}]            ;# IO3_P  J8 pin 8
#set_property -dict {PACKAGE_PIN AH16 IOSTANDARD LVCMOS33} [get_ports {gpio_n[3]}]            ;# IO3_N  J8 pin 7
#set_property -dict {PACKAGE_PIN AF15 IOSTANDARD LVCMOS33} [get_ports {gpio_p[4]}]            ;# IO4_P  J8 pin 10
#set_property -dict {PACKAGE_PIN AG15 IOSTANDARD LVCMOS33} [get_ports {gpio_n[4]}]            ;# IO4_N  J8 pin 9
#set_property -dict {PACKAGE_PIN AJ15 IOSTANDARD LVCMOS33} [get_ports {gpio_p[5]}]            ;# IO5_P  J8 pin 12
#set_property -dict {PACKAGE_PIN AK15 IOSTANDARD LVCMOS33} [get_ports {gpio_n[5]}]            ;# IO5_N  J8 pin 11
#set_property -dict {PACKAGE_PIN AF14 IOSTANDARD LVCMOS33} [get_ports {gpio_p[6]}]            ;# IO6_P  J8 pin 14
#set_property -dict {PACKAGE_PIN AG14 IOSTANDARD LVCMOS33} [get_ports {gpio_n[6]}]            ;# IO6_N  J8 pin 13
#set_property -dict {PACKAGE_PIN AJ14 IOSTANDARD LVCMOS33} [get_ports {gpio_p[7]}]            ;# IO7_P  J8 pin 16
#set_property -dict {PACKAGE_PIN AJ13 IOSTANDARD LVCMOS33} [get_ports {gpio_n[7]}]            ;# IO7_N  J8 pin 15
#set_property -dict {PACKAGE_PIN AH14 IOSTANDARD LVCMOS33} [get_ports {gpio_p[8]}]            ;# IO8_P  J8 pin 18
#set_property -dict {PACKAGE_PIN AH13 IOSTANDARD LVCMOS33} [get_ports {gpio_n[8]}]            ;# IO8_N  J8 pin 17
#set_property -dict {PACKAGE_PIN AK13 IOSTANDARD LVCMOS33} [get_ports {gpio_p[9]}]            ;# IO9_P  J8 pin 20
#set_property -dict {PACKAGE_PIN AK12 IOSTANDARD LVCMOS33} [get_ports {gpio_n[9]}]            ;# IO9_N  J8 pin 19
#set_property -dict {PACKAGE_PIN AE12 IOSTANDARD LVCMOS33} [get_ports {gpio_p[10]}]           ;# IO10_P  J8 pin 22
#set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports {gpio_n[10]}]           ;# IO10_N  J8 pin 21
#set_property -dict {PACKAGE_PIN AG12 IOSTANDARD LVCMOS33} [get_ports {gpio_p[11]}]           ;# IO11_P  J8 pin 24
#set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports {gpio_n[11]}]           ;# IO11_N  J8 pin 23
#set_property -dict {PACKAGE_PIN AE16 IOSTANDARD LVCMOS33} [get_ports {gpio_p[12]}]           ;# IO12_P  J8 pin 26
#set_property -dict {PACKAGE_PIN AE15 IOSTANDARD LVCMOS33} [get_ports {gpio_n[12]}]           ;# IO12_N  J8 pin 25
#set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {gpio_p[13]}]           ;# IO13_P  J8 pin 28
#set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {gpio_n[13]}]           ;# IO13_N  J8 pin 27
#set_property -dict {PACKAGE_PIN AD16 IOSTANDARD LVCMOS33} [get_ports {gpio_p[14]}]           ;# IO14_P  J8 pin 30
#set_property -dict {PACKAGE_PIN AD15 IOSTANDARD LVCMOS33} [get_ports {gpio_n[14]}]           ;# IO14_N  J8 pin 29
#set_property -dict {PACKAGE_PIN AD14 IOSTANDARD LVCMOS33} [get_ports {gpio_p[15]}]           ;# IO15_P  J8 pin 32
#set_property -dict {PACKAGE_PIN AD13 IOSTANDARD LVCMOS33} [get_ports {gpio_n[15]}]           ;# IO15_N  J8 pin 31
#set_property -dict {PACKAGE_PIN AC14 IOSTANDARD LVCMOS33} [get_ports {gpio_p[16]}]           ;# IO16_P  J8 pin 34
#set_property -dict {PACKAGE_PIN AC13 IOSTANDARD LVCMOS33} [get_ports {gpio_n[16]}]           ;# IO16_N  J8 pin 33
#set_property -dict {PACKAGE_PIN AB12 IOSTANDARD LVCMOS33} [get_ports {gpio_p[17]}]           ;# IO17_P  J8 pin 36
#set_property -dict {PACKAGE_PIN AC12 IOSTANDARD LVCMOS33} [get_ports {gpio_n[17]}]           ;# IO17_N  J8 pin 35

#------------------------------------------------------------------------------
# FMC HPC J7 (ASP-134486-01): LA00-LA33 on banks 12/13 at VADJ (VCC_ADJ1), DP0-7 on GTX 109/110
#   HA and HB are NOT connected. VADJ defaults to 2.5V (LVDS_25 / LVCMOS25).
#   VREF_A_M2C (FMC_VREF) feeds the VREF pins of banks 12/13 (AB26, AH29, T28, R21).
#   The AD9361/FMCOMMS2 port in rk-zynq7100-fmcomms2-linux uses exactly these LA pins.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN U25  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {fmc_clk0_m2c_p}] ;# FMC_CLK0_P  bank 13 SRCC
#set_property -dict {PACKAGE_PIN V26  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {fmc_clk0_m2c_n}] ;# FMC_CLK0_N
#set_property -dict {PACKAGE_PIN AC28 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {fmc_clk1_m2c_p}] ;# FMC_CLK1_P  bank 12 MRCC
#set_property -dict {PACKAGE_PIN AD28 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {fmc_clk1_m2c_n}] ;# FMC_CLK1_N
#set_property -dict {PACKAGE_PIN U26  IOSTANDARD LVCMOS25} [get_ports {fmc_la00_p}]           ;# FMC_LA00_CC_P
#set_property -dict {PACKAGE_PIN U27  IOSTANDARD LVCMOS25} [get_ports {fmc_la00_n}]           ;# FMC_LA00_CC_N
#set_property -dict {PACKAGE_PIN AB27 IOSTANDARD LVCMOS25} [get_ports {fmc_la01_p}]           ;# FMC_LA01_CC_P
#set_property -dict {PACKAGE_PIN AC27 IOSTANDARD LVCMOS25} [get_ports {fmc_la01_n}]           ;# FMC_LA01_CC_N
#set_property -dict {PACKAGE_PIN AK27 IOSTANDARD LVCMOS25} [get_ports {fmc_la02_p}]           ;# FMC_LA02_P
#set_property -dict {PACKAGE_PIN AK28 IOSTANDARD LVCMOS25} [get_ports {fmc_la02_n}]           ;# FMC_LA02_N
#set_property -dict {PACKAGE_PIN AJ28 IOSTANDARD LVCMOS25} [get_ports {fmc_la03_p}]           ;# FMC_LA03_P
#set_property -dict {PACKAGE_PIN AJ29 IOSTANDARD LVCMOS25} [get_ports {fmc_la03_n}]           ;# FMC_LA03_N
#set_property -dict {PACKAGE_PIN AH26 IOSTANDARD LVCMOS25} [get_ports {fmc_la04_p}]           ;# FMC_LA04_P
#set_property -dict {PACKAGE_PIN AH27 IOSTANDARD LVCMOS25} [get_ports {fmc_la04_n}]           ;# FMC_LA04_N
#set_property -dict {PACKAGE_PIN AG26 IOSTANDARD LVCMOS25} [get_ports {fmc_la05_p}]           ;# FMC_LA05_P
#set_property -dict {PACKAGE_PIN AG27 IOSTANDARD LVCMOS25} [get_ports {fmc_la05_n}]           ;# FMC_LA05_N
#set_property -dict {PACKAGE_PIN AJ30 IOSTANDARD LVCMOS25} [get_ports {fmc_la06_p}]           ;# FMC_LA06_P
#set_property -dict {PACKAGE_PIN AK30 IOSTANDARD LVCMOS25} [get_ports {fmc_la06_n}]           ;# FMC_LA06_N
#set_property -dict {PACKAGE_PIN AD30 IOSTANDARD LVCMOS25} [get_ports {fmc_la07_p}]           ;# FMC_LA07_P
#set_property -dict {PACKAGE_PIN AE30 IOSTANDARD LVCMOS25} [get_ports {fmc_la07_n}]           ;# FMC_LA07_N
#set_property -dict {PACKAGE_PIN AF30 IOSTANDARD LVCMOS25} [get_ports {fmc_la08_p}]           ;# FMC_LA08_P
#set_property -dict {PACKAGE_PIN AG30 IOSTANDARD LVCMOS25} [get_ports {fmc_la08_n}]           ;# FMC_LA08_N
#set_property -dict {PACKAGE_PIN AF29 IOSTANDARD LVCMOS25} [get_ports {fmc_la09_p}]           ;# FMC_LA09_P
#set_property -dict {PACKAGE_PIN AG29 IOSTANDARD LVCMOS25} [get_ports {fmc_la09_n}]           ;# FMC_LA09_N
#set_property -dict {PACKAGE_PIN AE27 IOSTANDARD LVCMOS25} [get_ports {fmc_la10_p}]           ;# FMC_LA10_P
#set_property -dict {PACKAGE_PIN AF27 IOSTANDARD LVCMOS25} [get_ports {fmc_la10_n}]           ;# FMC_LA10_N
#set_property -dict {PACKAGE_PIN Y28  IOSTANDARD LVCMOS25} [get_ports {fmc_la11_p}]           ;# FMC_LA11_P
#set_property -dict {PACKAGE_PIN AA29 IOSTANDARD LVCMOS25} [get_ports {fmc_la11_n}]           ;# FMC_LA11_N
#set_property -dict {PACKAGE_PIN AC26 IOSTANDARD LVCMOS25} [get_ports {fmc_la12_p}]           ;# FMC_LA12_P
#set_property -dict {PACKAGE_PIN AD26 IOSTANDARD LVCMOS25} [get_ports {fmc_la12_n}]           ;# FMC_LA12_N
#set_property -dict {PACKAGE_PIN AE25 IOSTANDARD LVCMOS25} [get_ports {fmc_la13_p}]           ;# FMC_LA13_P
#set_property -dict {PACKAGE_PIN AF25 IOSTANDARD LVCMOS25} [get_ports {fmc_la13_n}]           ;# FMC_LA13_N
#set_property -dict {PACKAGE_PIN AB29 IOSTANDARD LVCMOS25} [get_ports {fmc_la14_p}]           ;# FMC_LA14_P
#set_property -dict {PACKAGE_PIN AB30 IOSTANDARD LVCMOS25} [get_ports {fmc_la14_n}]           ;# FMC_LA14_N
#set_property -dict {PACKAGE_PIN AA27 IOSTANDARD LVCMOS25} [get_ports {fmc_la15_p}]           ;# FMC_LA15_P
#set_property -dict {PACKAGE_PIN AA28 IOSTANDARD LVCMOS25} [get_ports {fmc_la15_n}]           ;# FMC_LA15_N
#set_property -dict {PACKAGE_PIN Y26  IOSTANDARD LVCMOS25} [get_ports {fmc_la16_p}]           ;# FMC_LA16_P
#set_property -dict {PACKAGE_PIN Y27  IOSTANDARD LVCMOS25} [get_ports {fmc_la16_n}]           ;# FMC_LA16_N
#set_property -dict {PACKAGE_PIN AE28 IOSTANDARD LVCMOS25} [get_ports {fmc_la17_p}]           ;# FMC_LA17_CC_P
#set_property -dict {PACKAGE_PIN AF28 IOSTANDARD LVCMOS25} [get_ports {fmc_la17_n}]           ;# FMC_LA17_CC_N
#set_property -dict {PACKAGE_PIN R25  IOSTANDARD LVCMOS25} [get_ports {fmc_la18_p}]           ;# FMC_LA18_CC_P
#set_property -dict {PACKAGE_PIN R26  IOSTANDARD LVCMOS25} [get_ports {fmc_la18_n}]           ;# FMC_LA18_CC_N
#set_property -dict {PACKAGE_PIN W29  IOSTANDARD LVCMOS25} [get_ports {fmc_la19_p}]           ;# FMC_LA19_P
#set_property -dict {PACKAGE_PIN W30  IOSTANDARD LVCMOS25} [get_ports {fmc_la19_n}]           ;# FMC_LA19_N
#set_property -dict {PACKAGE_PIN Y30  IOSTANDARD LVCMOS25} [get_ports {fmc_la20_p}]           ;# FMC_LA20_P
#set_property -dict {PACKAGE_PIN AA30 IOSTANDARD LVCMOS25} [get_ports {fmc_la20_n}]           ;# FMC_LA20_N
#set_property -dict {PACKAGE_PIN V28  IOSTANDARD LVCMOS25} [get_ports {fmc_la21_p}]           ;# FMC_LA21_P
#set_property -dict {PACKAGE_PIN V29  IOSTANDARD LVCMOS25} [get_ports {fmc_la21_n}]           ;# FMC_LA21_N
#set_property -dict {PACKAGE_PIN V27  IOSTANDARD LVCMOS25} [get_ports {fmc_la22_p}]           ;# FMC_LA22_P
#set_property -dict {PACKAGE_PIN W28  IOSTANDARD LVCMOS25} [get_ports {fmc_la22_n}]           ;# FMC_LA22_N
#set_property -dict {PACKAGE_PIN W25  IOSTANDARD LVCMOS25} [get_ports {fmc_la23_p}]           ;# FMC_LA23_P
#set_property -dict {PACKAGE_PIN W26  IOSTANDARD LVCMOS25} [get_ports {fmc_la23_n}]           ;# FMC_LA23_N
#set_property -dict {PACKAGE_PIN T29  IOSTANDARD LVCMOS25} [get_ports {fmc_la24_p}]           ;# FMC_LA24_P
#set_property -dict {PACKAGE_PIN U29  IOSTANDARD LVCMOS25} [get_ports {fmc_la24_n}]           ;# FMC_LA24_N
#set_property -dict {PACKAGE_PIN R27  IOSTANDARD LVCMOS25} [get_ports {fmc_la25_p}]           ;# FMC_LA25_P
#set_property -dict {PACKAGE_PIN T27  IOSTANDARD LVCMOS25} [get_ports {fmc_la25_n}]           ;# FMC_LA25_N
#set_property -dict {PACKAGE_PIN T30  IOSTANDARD LVCMOS25} [get_ports {fmc_la26_p}]           ;# FMC_LA26_P
#set_property -dict {PACKAGE_PIN U30  IOSTANDARD LVCMOS25} [get_ports {fmc_la26_n}]           ;# FMC_LA26_N
#set_property -dict {PACKAGE_PIN T24  IOSTANDARD LVCMOS25} [get_ports {fmc_la27_p}]           ;# FMC_LA27_P
#set_property -dict {PACKAGE_PIN T25  IOSTANDARD LVCMOS25} [get_ports {fmc_la27_n}]           ;# FMC_LA27_N
#set_property -dict {PACKAGE_PIN N26  IOSTANDARD LVCMOS25} [get_ports {fmc_la28_p}]           ;# FMC_LA28_P
#set_property -dict {PACKAGE_PIN N27  IOSTANDARD LVCMOS25} [get_ports {fmc_la28_n}]           ;# FMC_LA28_N
#set_property -dict {PACKAGE_PIN P23  IOSTANDARD LVCMOS25} [get_ports {fmc_la29_p}]           ;# FMC_LA29_P
#set_property -dict {PACKAGE_PIN P24  IOSTANDARD LVCMOS25} [get_ports {fmc_la29_n}]           ;# FMC_LA29_N
#set_property -dict {PACKAGE_PIN N28  IOSTANDARD LVCMOS25} [get_ports {fmc_la30_p}]           ;# FMC_LA30_P
#set_property -dict {PACKAGE_PIN P28  IOSTANDARD LVCMOS25} [get_ports {fmc_la30_n}]           ;# FMC_LA30_N
#set_property -dict {PACKAGE_PIN P25  IOSTANDARD LVCMOS25} [get_ports {fmc_la31_p}]           ;# FMC_LA31_P
#set_property -dict {PACKAGE_PIN P26  IOSTANDARD LVCMOS25} [get_ports {fmc_la31_n}]           ;# FMC_LA31_N
#set_property -dict {PACKAGE_PIN N29  IOSTANDARD LVCMOS25} [get_ports {fmc_la32_p}]           ;# FMC_LA32_P
#set_property -dict {PACKAGE_PIN P29  IOSTANDARD LVCMOS25} [get_ports {fmc_la32_n}]           ;# FMC_LA32_N
#set_property -dict {PACKAGE_PIN P30  IOSTANDARD LVCMOS25} [get_ports {fmc_la33_p}]           ;# FMC_LA33_P
#set_property -dict {PACKAGE_PIN R30  IOSTANDARD LVCMOS25} [get_ports {fmc_la33_n}]           ;# FMC_LA33_N
#set_property -dict {PACKAGE_PIN AC21 IOSTANDARD LVCMOS33} [get_ports {fmc_scl}]              ;# FMC_SCL  bank 11, 4.7K pull-up
#set_property -dict {PACKAGE_PIN W23  IOSTANDARD LVCMOS33} [get_ports {fmc_sda}]              ;# FMC_SDA  bank 11
#set_property -dict {PACKAGE_PIN Y23  IOSTANDARD LVCMOS33} [get_ports {fmc_pg_c2m}]           ;# PWRGD  PG_C2M, bank 11, 4.7K pull-up to 3.3V
#set_property -dict {PACKAGE_PIN AE20 IOSTANDARD LVCMOS33} [get_ports {fmc_prsnt_n}]          ;# FMC_PRSNT  PRSNT_M2C_L, bank 9, 4.7K pull-up; also switches the JTAG chain
#set_property PACKAGE_PIN AD10 [get_ports {fmc_gbtclk0_m2c_p}]                                ;# FMC_GBTCLK0_M2C_P  MGTREFCLK0_109, AC-coupled
#set_property PACKAGE_PIN AD9  [get_ports {fmc_gbtclk0_m2c_n}]                                ;# FMC_GBTCLK0_M2C_N
#set_property PACKAGE_PIN AA8  [get_ports {fmc_gbtclk1_m2c_p}]                                ;# FMC_GBTCLK1_M2C_P  MGTREFCLK0_110, AC-coupled
#set_property PACKAGE_PIN AA7  [get_ports {fmc_gbtclk1_m2c_n}]                                ;# FMC_GBTCLK1_M2C_N
#set_property PACKAGE_PIN AK10 [get_ports {fmc_dp_c2m_p[0]}]                                  ;# FMC_DP0_C2M_P  DP0, GTX quad 109
#set_property PACKAGE_PIN AK9  [get_ports {fmc_dp_c2m_n[0]}]                                  ;# FMC_DP0_C2M_N
#set_property PACKAGE_PIN AH10 [get_ports {fmc_dp_m2c_p[0]}]                                  ;# FMC_DP0_M2C_P
#set_property PACKAGE_PIN AH9  [get_ports {fmc_dp_m2c_n[0]}]                                  ;# FMC_DP0_M2C_N
#set_property PACKAGE_PIN AK6  [get_ports {fmc_dp_c2m_p[1]}]                                  ;# FMC_DP1_C2M_P  DP1, GTX quad 109
#set_property PACKAGE_PIN AK5  [get_ports {fmc_dp_c2m_n[1]}]                                  ;# FMC_DP1_C2M_N
#set_property PACKAGE_PIN AJ8  [get_ports {fmc_dp_m2c_p[1]}]                                  ;# FMC_DP1_M2C_P
#set_property PACKAGE_PIN AJ7  [get_ports {fmc_dp_m2c_n[1]}]                                  ;# FMC_DP1_M2C_N
#set_property PACKAGE_PIN AJ4  [get_ports {fmc_dp_c2m_p[2]}]                                  ;# FMC_DP2_C2M_P  DP2, GTX quad 109
#set_property PACKAGE_PIN AJ3  [get_ports {fmc_dp_c2m_n[2]}]                                  ;# FMC_DP2_C2M_N
#set_property PACKAGE_PIN AG8  [get_ports {fmc_dp_m2c_p[2]}]                                  ;# FMC_DP2_M2C_P
#set_property PACKAGE_PIN AG7  [get_ports {fmc_dp_m2c_n[2]}]                                  ;# FMC_DP2_M2C_N
#set_property PACKAGE_PIN AK2  [get_ports {fmc_dp_c2m_p[3]}]                                  ;# FMC_DP3_C2M_P  DP3, GTX quad 109
#set_property PACKAGE_PIN AK1  [get_ports {fmc_dp_c2m_n[3]}]                                  ;# FMC_DP3_C2M_N
#set_property PACKAGE_PIN AE8  [get_ports {fmc_dp_m2c_p[3]}]                                  ;# FMC_DP3_M2C_P
#set_property PACKAGE_PIN AE7  [get_ports {fmc_dp_m2c_n[3]}]                                  ;# FMC_DP3_M2C_N
#set_property PACKAGE_PIN AH2  [get_ports {fmc_dp_c2m_p[4]}]                                  ;# FMC_DP4_C2M_P  DP4, GTX quad 110
#set_property PACKAGE_PIN AH1  [get_ports {fmc_dp_c2m_n[4]}]                                  ;# FMC_DP4_C2M_N
#set_property PACKAGE_PIN AH6  [get_ports {fmc_dp_m2c_p[4]}]                                  ;# FMC_DP4_M2C_P
#set_property PACKAGE_PIN AH5  [get_ports {fmc_dp_m2c_n[4]}]                                  ;# FMC_DP4_M2C_N
#set_property PACKAGE_PIN AF2  [get_ports {fmc_dp_c2m_p[5]}]                                  ;# FMC_DP5_C2M_P  DP5, GTX quad 110
#set_property PACKAGE_PIN AF1  [get_ports {fmc_dp_c2m_n[5]}]                                  ;# FMC_DP5_C2M_N
#set_property PACKAGE_PIN AG4  [get_ports {fmc_dp_m2c_p[5]}]                                  ;# FMC_DP5_M2C_P
#set_property PACKAGE_PIN AG3  [get_ports {fmc_dp_m2c_n[5]}]                                  ;# FMC_DP5_M2C_N
#set_property PACKAGE_PIN AE4  [get_ports {fmc_dp_c2m_p[6]}]                                  ;# FMC_DP6_C2M_P  DP6, GTX quad 110
#set_property PACKAGE_PIN AE3  [get_ports {fmc_dp_c2m_n[6]}]                                  ;# FMC_DP6_C2M_N
#set_property PACKAGE_PIN AF6  [get_ports {fmc_dp_m2c_p[6]}]                                  ;# FMC_DP6_M2C_P
#set_property PACKAGE_PIN AF5  [get_ports {fmc_dp_m2c_n[6]}]                                  ;# FMC_DP6_M2C_N
#set_property PACKAGE_PIN AD2  [get_ports {fmc_dp_c2m_p[7]}]                                  ;# FMC_DP7_C2M_P  DP7, GTX quad 110
#set_property PACKAGE_PIN AD1  [get_ports {fmc_dp_c2m_n[7]}]                                  ;# FMC_DP7_C2M_N
#set_property PACKAGE_PIN AD6  [get_ports {fmc_dp_m2c_p[7]}]                                  ;# FMC_DP7_M2C_P
#set_property PACKAGE_PIN AD5  [get_ports {fmc_dp_m2c_n[7]}]                                  ;# FMC_DP7_M2C_N

#------------------------------------------------------------------------------
# AD-FMCOMMS2-EBZ (AD9361) on the FMC: the validated mapping from rk-zynq7100-fmcomms2-linux
#   Use instead of the generic LA lines above when porting ADI HDL; LVDS_25 needs VADJ = 2.5V (default).
#   PS SPI0 (EMIO) drives the AD9361 SPI; spi0_* are EMIO ports of the PS7 block.
#------------------------------------------------------------------------------
#set_property -dict {PACKAGE_PIN U26  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_clk_in_p}] ;# FMC_LA00_CC_P
#set_property -dict {PACKAGE_PIN U27  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_clk_in_n}] ;# FMC_LA00_CC_N
#set_property -dict {PACKAGE_PIN AB27 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_frame_in_p}] ;# FMC_LA01_CC_P
#set_property -dict {PACKAGE_PIN AC27 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_frame_in_n}] ;# FMC_LA01_CC_N
#set_property -dict {PACKAGE_PIN AK27 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[0]}] ;# FMC_LA02_P
#set_property -dict {PACKAGE_PIN AK28 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[0]}] ;# FMC_LA02_N
#set_property -dict {PACKAGE_PIN AJ28 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[1]}] ;# FMC_LA03_P
#set_property -dict {PACKAGE_PIN AJ29 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[1]}] ;# FMC_LA03_N
#set_property -dict {PACKAGE_PIN AH26 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[2]}] ;# FMC_LA04_P
#set_property -dict {PACKAGE_PIN AH27 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[2]}] ;# FMC_LA04_N
#set_property -dict {PACKAGE_PIN AG26 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[3]}] ;# FMC_LA05_P
#set_property -dict {PACKAGE_PIN AG27 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[3]}] ;# FMC_LA05_N
#set_property -dict {PACKAGE_PIN AJ30 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[4]}] ;# FMC_LA06_P
#set_property -dict {PACKAGE_PIN AK30 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[4]}] ;# FMC_LA06_N
#set_property -dict {PACKAGE_PIN AD30 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_p[5]}] ;# FMC_LA07_P
#set_property -dict {PACKAGE_PIN AE30 IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports {rx_data_in_n[5]}] ;# FMC_LA07_N
#set_property -dict {PACKAGE_PIN AF30 IOSTANDARD LVDS_25} [get_ports {tx_clk_out_p}]          ;# FMC_LA08_P
#set_property -dict {PACKAGE_PIN AG30 IOSTANDARD LVDS_25} [get_ports {tx_clk_out_n}]          ;# FMC_LA08_N
#set_property -dict {PACKAGE_PIN AF29 IOSTANDARD LVDS_25} [get_ports {tx_frame_out_p}]        ;# FMC_LA09_P
#set_property -dict {PACKAGE_PIN AG29 IOSTANDARD LVDS_25} [get_ports {tx_frame_out_n}]        ;# FMC_LA09_N
#set_property -dict {PACKAGE_PIN Y28  IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[0]}]      ;# FMC_LA11_P
#set_property -dict {PACKAGE_PIN AA29 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[0]}]      ;# FMC_LA11_N
#set_property -dict {PACKAGE_PIN AC26 IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[1]}]      ;# FMC_LA12_P
#set_property -dict {PACKAGE_PIN AD26 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[1]}]      ;# FMC_LA12_N
#set_property -dict {PACKAGE_PIN AE25 IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[2]}]      ;# FMC_LA13_P
#set_property -dict {PACKAGE_PIN AF25 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[2]}]      ;# FMC_LA13_N
#set_property -dict {PACKAGE_PIN AE27 IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[3]}]      ;# FMC_LA10_P
#set_property -dict {PACKAGE_PIN AF27 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[3]}]      ;# FMC_LA10_N
#set_property -dict {PACKAGE_PIN AB29 IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[4]}]      ;# FMC_LA14_P
#set_property -dict {PACKAGE_PIN AB30 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[4]}]      ;# FMC_LA14_N
#set_property -dict {PACKAGE_PIN AA27 IOSTANDARD LVDS_25} [get_ports {tx_data_out_p[5]}]      ;# FMC_LA15_P
#set_property -dict {PACKAGE_PIN AA28 IOSTANDARD LVDS_25} [get_ports {tx_data_out_n[5]}]      ;# FMC_LA15_N
#set_property -dict {PACKAGE_PIN Y30  IOSTANDARD LVCMOS25} [get_ports {gpio_status[0]}]       ;# FMC_LA20_P
#set_property -dict {PACKAGE_PIN AA30 IOSTANDARD LVCMOS25} [get_ports {gpio_status[1]}]       ;# FMC_LA20_N
#set_property -dict {PACKAGE_PIN V28  IOSTANDARD LVCMOS25} [get_ports {gpio_status[2]}]       ;# FMC_LA21_P
#set_property -dict {PACKAGE_PIN V29  IOSTANDARD LVCMOS25} [get_ports {gpio_status[3]}]       ;# FMC_LA21_N
#set_property -dict {PACKAGE_PIN V27  IOSTANDARD LVCMOS25} [get_ports {gpio_status[4]}]       ;# FMC_LA22_P
#set_property -dict {PACKAGE_PIN W28  IOSTANDARD LVCMOS25} [get_ports {gpio_status[5]}]       ;# FMC_LA22_N
#set_property -dict {PACKAGE_PIN W25  IOSTANDARD LVCMOS25} [get_ports {gpio_status[6]}]       ;# FMC_LA23_P
#set_property -dict {PACKAGE_PIN W26  IOSTANDARD LVCMOS25} [get_ports {gpio_status[7]}]       ;# FMC_LA23_N
#set_property -dict {PACKAGE_PIN T29  IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[0]}]          ;# FMC_LA24_P
#set_property -dict {PACKAGE_PIN U29  IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[1]}]          ;# FMC_LA24_N
#set_property -dict {PACKAGE_PIN R27  IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[2]}]          ;# FMC_LA25_P
#set_property -dict {PACKAGE_PIN T27  IOSTANDARD LVCMOS25} [get_ports {gpio_ctl[3]}]          ;# FMC_LA25_N
#set_property -dict {PACKAGE_PIN W29  IOSTANDARD LVCMOS25} [get_ports {gpio_en_agc}]          ;# FMC_LA19_P
#set_property -dict {PACKAGE_PIN W30  IOSTANDARD LVCMOS25} [get_ports {gpio_sync}]            ;# FMC_LA19_N
#set_property -dict {PACKAGE_PIN N26  IOSTANDARD LVCMOS25} [get_ports {gpio_resetb}]          ;# FMC_LA28_P
#set_property -dict {PACKAGE_PIN Y26  IOSTANDARD LVCMOS25} [get_ports {enable}]               ;# FMC_LA16_P
#set_property -dict {PACKAGE_PIN Y27  IOSTANDARD LVCMOS25} [get_ports {txnrx}]                ;# FMC_LA16_N
#set_property -dict {PACKAGE_PIN T30  IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports {spi0_csn_0_o}] ;# FMC_LA26_P
#set_property -dict {PACKAGE_PIN U30  IOSTANDARD LVCMOS25} [get_ports {spi0_clk_o}]           ;# FMC_LA26_N
#set_property -dict {PACKAGE_PIN T24  IOSTANDARD LVCMOS25} [get_ports {spi0_sdo_o}]           ;# FMC_LA27_P
#set_property -dict {PACKAGE_PIN T25  IOSTANDARD LVCMOS25} [get_ports {spi0_sdi_i}]           ;# FMC_LA27_N
#create_clock -name rx_clk -period 4.000 [get_ports rx_clk_in_p]

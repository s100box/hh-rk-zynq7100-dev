# RK-ZYNQ7100 Development Board: User Guide

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

This guide covers the RK-ZYNQ7100 development board, a carrier for the AMD Zynq-7000 **XC7Z100-2FFG900**.

Most of what follows has been **run on the board**, from sources in this
repository: the U-Boot and Linux build under [`../linux/`](../linux/README.md)
and the PL designs under [`../pl/`](../pl/README.md). Where a number appears
here it was measured unless the text says otherwise, and where a procedure
appears it is one these files carry out.

Two external sources sit behind that work:

- **The vendor schematic** (24 sheets, a scanned PDF). Every PL pin comes from the drawing and agrees with Vivado's own pinout for `xc7z100ffg900-2` on pin function, bank and differential partner: all 367 PL pins. It remains the only source for the parts nothing here has driven: the FMC beyond its LA pins, and the PCIe, SATA and FMC transceiver lanes.
- **[rk-zynq7100-fmcomms2-linux](https://github.com/R0Y00/rk-zynq7100-fmcomms2-linux)**, a board-tested AD9361/FMCOMMS2 port. It was the starting point for the MIO assignment, the PS DDR3 part and the FMC LA pins, and it independently corroborates the schematic on those. The PS configuration in this repository is applied, verified and booted on its own terms ([section 22](#22-where-the-board-data-came-from)).

The companion file [`RK_ZYNQ7100_master.xdc`](../RK_ZYNQ7100_master.xdc), in the repository root, has a constraint line for every PL signal described here.

---

## Contents

1. [Board overview](#1-board-overview)
2. [Getting started](#2-getting-started)
3. [Power](#3-power)
4. [Boot, configuration and reset](#4-boot-configuration-and-reset)
5. [Clocks](#5-clocks)
6. [I/O banks and voltages](#6-io-banks-and-voltages)
7. [PS peripherals (MIO)](#7-ps-peripherals-mio)
8. [DDR3 memory](#8-ddr3-memory)
9. [LEDs, keys and fan](#9-leds-keys-and-fan)
10. [JTAG and UART](#10-jtag-and-uart)
11. [Ethernet](#11-ethernet)
12. [USB 2.0](#12-usb-20)
13. [SD card, eMMC and EEPROM](#13-sd-card-emmc-and-eeprom)
14. [PCI Express](#14-pci-express)
15. [SFP+ cages](#15-sfp-cages)
16. [SATA](#16-sata)
17. [HDMI output (ADV7511)](#17-hdmi-output-adv7511)
18. [HDMI input (ADV7611)](#18-hdmi-input-adv7611)
19. [MIPI CSI-2 camera](#19-mipi-csi-2-camera)
20. [FMC HPC connector](#20-fmc-hpc-connector)
21. [40-pin I/O header](#21-40-pin-io-header)
22. [Where the board data came from](#22-where-the-board-data-came-from)
23. [Known issues and design notes](#23-known-issues-and-design-notes)
24. [Appendix: unassigned PL pins](#24-appendix-unassigned-pl-pins)
25. [The PS-PL interfaces](#25-the-ps-pl-interfaces)

---

## 1. Board overview

| Item | Details |
|---|---|
| SoC | AMD Zynq-7000 **XC7Z100-2FFG900** (Vivado part `xc7z100ffg900-2`): dual Cortex-A9 + Kintex-7-class fabric, 16 GTX transceivers |
| PS memory | 1 GB DDR3, 32-bit, 2× MT41J256M16 (DDR3-1600 grade, `RE-125`) |
| PL memory | 1 GB DDR3, 32-bit, 2× MT41J256M16 on HP banks 33/34 |
| Flash | 2× Winbond W25Q256FV quad SPI in dual-parallel mode = 64 MB (512 Mb) |
| eMMC | Samsung KLM8G1GETF-B041, 8 GB, on SD1 |
| High-speed serial | PCIe Gen2 x4 edge connector, 2× SFP+, 2× SATA, FMC DP0–DP7 |
| Networking | 2× Gigabit Ethernet, both RTL8211F-CG in RGMII: one on the PS, one on the PL |
| Video | HDMI out (ADV7511), HDMI in (ADV7611), MIPI CSI-2 2-lane camera connector |
| USB | USB 2.0 OTG through a USB3320 ULPI PHY: USB-C (device) and USB-A (host) |
| Expansion | FMC HPC (LA00–LA33 + 8 DP lanes), 40-pin 2.54 mm header (17 differential pairs) |
| Debug | USB-C: FT2232HQ for JTAG + UART |
| User I/O | 5 PL LEDs (4 green + 1 bicolor, 6 signals), 4 PL keys, PWM fan header, reset key |
| Storage | micro-SD (SD0), AT24C256 EEPROM |
| Power | 12V DC jack or the PCIe slot's 12V |

### Block diagram (from sheet 1 of the schematic)

```
                 EEPROM 256Kb   MIPI 2-lane   HDMI OUT (ADV7511)   SD CARD
                        \            |              |               /
  PL LED x2 ---+      +----------------------------------------------+      +--- FMC HPC
  4-wire fan --+      |                                              |      +--- HDMI IN (ADV7611)
  JTAG+UART ---+------|   XC7Z100-2FFG900                            |------+--- PL ETH
  PS ETH ------+      |   eMMC 8GB   QSPI 512Mb                      |      +--- USB 2.0 host/device
  SATA x2 -----+      |   PS DDR3 1GB   PL DDR3 1GB                  |      +--- PL LED x4
  SFP+ x2 -----+      +----------------------------------------------+      +--- PL KEY x4
                                 |                    |
                            PCIe 2.0 x4          40-pin IO
```

---

## 2. Getting started

1. **Power.** Plug 12V into the DC jack DC1 and turn on the power switch SW2. The green LED3 shows that 3.3V is up.
2. **USB.** Connect the JTAG USB-C port (USB1). The FT2232HQ provides:
   - a JTAG cable that Vivado's Hardware Manager detects,
   - a serial port wired to the PS UART0.
3. **Boot mode.** Set DIP switch SW1 (see [section 4](#4-boot-configuration-and-reset)).
4. **Vivado design.** Part `xc7z100ffg900-2`.
   - The `processing_system7` block needs this board's MIO, clocks and DDR ([section 7](#7-ps-peripherals-mio)). Apply [`../linux/board/ps7_config.tcl`](../linux/board/ps7_config.tcl). That file is not a transcription of anyone's reference: it is the configuration this board boots on, it generates the `ps7_init` that SPL and U-Boot are built from, and both PL designs apply and then **verify** it setting by setting, so a value the IP quietly refuses stops the build instead of producing a board that half works.
   - [`../pl/board/build.tcl`](../pl/board/build.tcl) is a complete worked example: batch Tcl, from an empty directory to a bitstream; `project` as a second argument stops at a project the GUI can open.
5. **Constraints.** Copy the PL constraints you need from `RK_ZYNQ7100_master.xdc`. Every line is commented out; the two designs under [`../pl/`](../pl/README.md) show which lines a working design ends up with.
6. **Configured.** Once the PL is configured, the FPGA DONE LED (LED1, white) lights.

### A working starting point

Everything below has been run on this board, and the sources are in this
repository rather than described only in prose:

| Want | Where | State |
|---|---|---|
| U-Boot + Linux: from a microSD card, stand-alone from QSPI + eMMC, or JTAG + TFTP | [`../linux/`](../linux/) | Boots from QSPI + eMMC with no host attached |
| The whole-board PL design (PL DDR3, LEDs, keys, the fan, the three populated I2C buses, all 34 header pins, HDMI in and out, the camera, SFP, PL Ethernet) | [`../pl/board/`](../pl/board/) | Runs; loaded with `fpga_manager`, or from U-Boot at boot |
| The 1 GB of PL DDR3, mapped into the PS | [`../pl/ddr/`](../pl/ddr/) | Calibrates; verified across the full gigabyte, and 392 MB/s from a fabric master |
| Fabric masters reaching PS DRAM, and a fabric interrupt | [`../pl/board/rtl/axi_bist.v`](../pl/board/rtl/axi_bist.v) | 798 MB/s per HP port, 0 errors; `IRQ_F2P` wakes a `/dev/uio` reader |
| HDMI output: pixel clock, CEA timing, a test pattern | [`../pl/board/rtl/hdmi_out.v`](../pl/board/rtl/hdmi_out.v) | The ADV7511 locks to it, and an ADV7611 at the far end of a loopback locks to the TMDS |
| HDMI input as a V4L2 capture device | [`../pl/board/rtl/hdmi_rx_capture.v`](../pl/board/rtl/hdmi_rx_capture.v) | `/dev/video0`; captures 1280x720p60, checked pixel by pixel against the test pattern |
| Simulation before a 20-minute Vivado run | [`../pl/sim/`](../pl/sim/README.md) | 17 self-checking benches, an elaboration of each top level and a Verilator lint, in minutes |

---

## 3. Power

**Input.** 12V comes in through DC jack DC1 (SS54 diode, SMBJ15CA TVS), then push switch SW2 and fuse F1.
- In a PCIe slot, the slot's 12V (`12V_PCIE`) enters through diode D10 **after** SW2. The board therefore powers up from the slot whatever the switch position.

| Rail | Regulator | Supplies |
|---|---|---|
| +1.0V, 30 A | U34 TPS53355 | VCCINT, VCCBRAM, VCCPINT |
| MGTAVCC 1.0V, 8 A | U35 TPS54821 | GTX MGTAVCC |
| MGTAVTT 1.2V, 3 A | U36 TLV62130 | GTX MGTAVTT |
| MGT_1.8V | U37 ME6211 LDO (from 3.3V) | GTX MGTVCCAUX |
| +3.3V | U28 TPS54821 | Banks 0/9/11, MIO bank 500, peripherals, oscillators |
| +1.8V | U29 TPS54821 | VCCAUX, VCCPAUX, bank 35, MIO bank 501, VCCADC |
| +1.5V | U32 TLV62130 | PS DDR3 (bank 502), PL DDR3 (banks 33/34) |
| +5V | U30 TLV62130 | USB-A VBUS, HDMI, 40-pin header pin 2 |
| **VCC_ADJ1** | U31 TLV62130 | FMC VADJ, banks 12/13. **Default 2.5V.** |
| **VCC_ADJ2** | U33 TLV62130 | 40-pin header, PL_LED1–4 (LED4–LED7), keys, bank 10. **Default 3.3V.** |
| PS / PL DDR VTT | TPS51200 | DDR3 termination and VREF |

**Sequencing.** The 1.0V regulator's power-good (`1V0_PG`) enables the 3.3V, 5V, 1.5V and MGTAVCC rails and the 1.8V rail. `PG_1.8V` then enables VCC_ADJ1 and VCC_ADJ2, and MGTAVCC's power-good enables MGTAVTT.

**Changing VCC_ADJ1 (FMC VADJ).** Change feedback resistor RA1 (10K top resistor R243):

| RA1 | VCC_ADJ1 |
|---|---|
| 8.06K | 1.8V |
| **4.7K (default)** | **2.5V** |
| 3.24K | 3.3V |

**VCC_ADJ2** is set by RA2 = 3.24K, giving 3.3V. The same table applies. Change the IOSTANDARDs of banks 12/13 (VCC_ADJ1) or bank 10 (VCC_ADJ2) to match.

---

## 4. Boot, configuration and reset

**Boot mode** is read from MIO[5:3] at power-on:
- MIO3 is pulled low.
- MIO4 and MIO5 each have a 4.7K pull-up to 3.3V, and one position of DIP switch SW1 grounds each of them.

| MIO5 | MIO4 | MIO3 | Boot mode |
|---|---|---|---|
| 1 | 0 | 0 | **Quad SPI** (MIO4's switch position ON) |
| 1 | 1 | 0 | **SD card** (both switches OFF) |
| 0 | 0 | 0 | JTAG (both switches ON) |

**Switch positions:** SW1 is a 2-position DIP switch (DSIC02LSGET).
- SW1-1 (pins 1–4) grounds MIO4, and SW1-2 (pins 2–3) grounds MIO5.
- Both ON = JTAG, SW1-1 ON only = QSPI, both OFF = SD.
- The mode the BootROM saw is in `BOOT_MODE` (0xF800025C): 0 = JTAG, 1 = QSPI, 5 = SD. With both switches OFF it reads 5, as the table says.
- There are no boot-mode jumpers.

**Measured.** With SW1-1 ON and SW1-2 OFF the board boots entirely
on its own: BootROM → U-Boot SPL from QSPI → U-Boot from QSPI →
`distro_bootcmd` → `extlinux.conf` on the eMMC → Linux → login prompt. No JTAG,
no network. `BOOT_MODE` (`0xF800025C`) reads 1, and U-Boot reports
`modeboot=qspiboot`.

⚠ **The QSPI is two chips in DUAL PARALLEL, and that bites the SPL.** `spi-nor`
splits every access across both W25Q256FVs and halves the offset. A read that
starts at the beginning of an image is fine; a second read at some other
offset is not always. With `CONFIG_SPL_LOAD_FIT`, SPL fetches the device tree
as a separate, separately-offset read, and the tree arrives with a correct body
but **wrong first eight bytes** — magic `dc4dfeed` instead of `d00dfeed`.
U-Boot then has no usable device tree and dies in `dev_get_uclass_plat()`
before the console starts, so the only symptom is `Trying to boot from SPI`
and silence.

So U-Boot is loaded as **one contiguous image** (a legacy `u-boot.img`, device
tree already appended), and SPL makes a single read. See
[`../linux/board/uboot-rkz7100.fragment`](../linux/board/uboot-rkz7100.fragment).

**Flash layout used here**, which Linux exposes as three MTD partitions:

| Offset | Size | Contents | MTD |
|---|---|---|---|
| `0x000000` | 14 MiB | `boot.bin` (SPL) at 0, `u-boot.img` at `0x100000` | `mtd0` "boot" |
| `0xE00000` | 512 KiB | U-Boot environment | `mtd1` "u-boot-env" |
| `0xE80000` | 49.5 MiB | unused | `mtd2` "spare" |

The flash can be written from Linux with `flashcp`, which erases, writes and
verifies in one step — easier than interrupting U-Boot's countdown:

```
flashcp -v qspi-boot.bin /dev/mtd0
```

where `qspi-boot.bin` is `boot.bin` padded out to `0x100000` followed by
`u-boot.img`. **Measured:** 2 MiB over 258 eraseblocks, erase,
write and verify in 11.1 s, after which the board rebooted from the flash it
had just rewritten. See "Reflashing from Linux" in
[the Linux guide](linux-guide.md).

**The other straps:**
- MIO2 is pulled low, so the JTAG chain is cascaded (PS and PL on one chain).
- MIO6 is pulled low, so the PLLs are used.
- MIO7 is pulled low, setting MIO bank 500 to 3.3V.
- MIO8 is pulled high, setting MIO bank 501 to 1.8V. MIO8 is also the QSPI feedback clock.

| Item | Details |
|---|---|
| PS_CLK | 33.333 MHz oscillator Y1, 33R to pin A22 |
| PS_POR_B | MAX809T supervisor on +3.3V, 80.6R to D21 |
| PS_SRST_B | 4.7K pull-up (B19). There is no button. |
| PL config | Bank 0 at 3.3V (`CFGBVS VCCO`, `CONFIG_VOLTAGE 3.3`). INIT_B and PROGRAM_B have 4.7K pull-ups; there is no PROGRAM button. |
| FPGA DONE | LED1 (white) |
| JTAG | FT2232HQ channel A, through a 74LCX125 buffer. When an FMC card is fitted (`FMC_PRSNT` low), an ADG719 switch routes the chain through the card: `FMC_PRSNT` = 1 gives `JTAG_TDO = FPGA_TDO`, and 0 gives `JTAG_TDO = FMC_TDO`. |
| QSPI | 2× W25Q256FV, dual-parallel x8 (MIO0–13, feedback clock on MIO8) |
| Reset key K5 | Drives `SYS_RESET`, the enable of the 1.0V VCCINT regulator U34. Every other rail sequences from its power-good, so K5 acts as a full power-cycle reset. |

---

## 5. Clocks

| Clock | Source | FPGA pin(s) | Bank | Notes |
|---|---|---|---|---|
| PS_CLK 33.333 MHz | Y1 | A22 | 500 | PS reference |
| PL_CLK 50 MHz | Y2, 3.3V | **AD18** | 9 (MRCC) | General-purpose PL clock |
| SYS_CLK 200 MHz | Y7 SG3225VAN LVDS | **F9 / E8** | 34 (SRCC) | AC-coupled, biased to VCCO/2 by 10K/10K dividers, 100R termination. MIG reference clock; use `DIFF_SSTL15`. |
| GTX 156.25 MHz | Y8 SiT9120AI | R8 / R7 | GTX 112 REFCLK1 | SFP+ (10GBASE-R) |
| GTX 150 MHz | Y9 | N8 / N7 | GTX 112 REFCLK0 | SATA |
| PCIe REFCLK | Slot, 100 MHz | U8 / U7 | GTX 111 REFCLK0 | AC-coupled |
| FMC GBTCLK0 / 1 | FMC card | AD10/AD9, AA8/AA7 | GTX 109 / 110 REFCLK0 | AC-coupled |
| FMC CLK0 / CLK1_M2C | FMC card | U25/V26, AC28/AD28 | 13 SRCC / 12 MRCC | |
| HDMI_RX_PCLK | ADV7611 LLC | AD23 | 11 (SRCC) | |
| PHY2_RXCK | RTL8211F | AF20 | 11 (SRCC) | 125 / 25 / 2.5 MHz |
| MIPI_CLK | Camera | E13 / D13 | 35 (SRCC) | D-PHY HS clock |
| ADV7511 CEC clock | Y10 | — | — | Local to the ADV7511 |
| ADV7611 | Y11, 28.63636 MHz crystal | — | — | Local |
| Ethernet PHYs | Y4 / Y5, 25 MHz crystals | — | — | Local |
| USB3320 | Y6, 24 MHz crystal | — | — | ULPI clock out to MIO36 |

### Measured on the hardware

Each of these four clocks a counter in the PL that Linux reads (`pl/README.md`,
"The oscillators, counted"). For Y2 and Y9 that counter is their only
consumer, so nothing else would reveal a fault in them: a part that was not
fitted, is dead, or was fitted at the wrong frequency looks exactly like one
nothing happens to use. For Y7 and Y8 it turns a symptom into a number:

| Oscillator | Reading | Nominal | Error |
|---|---|---|---|
| Y2, `PL_CLK` (AD18) | **50,000,207 Hz** | 50 MHz | +4.1 ppm |
| Y8, GTX 156.25 MHz, through SFP1's user clock | **78,125,420 Hz** at the reset rate, Y8 ÷ 2 | 78.125 MHz | +5.4 ppm |
| Y9, GTX 150 MHz ÷ 2 | **75,000,753 Hz** | 75 MHz | +10.0 ppm |
| Y7, `SYS_CLK` | **200,001,364 Hz** | 200 MHz | +6.8 ppm |

The `ddr` design counts the same four by a second route -- Y8 through its
reference buffer's `ODIV2`, at 78,125,401 Hz, +5.1 ppm -- and agrees to within
a few ppm on all four.

⚠ **The two GTX references reach their counters differently.** An
`MGTREFCLK` pin feeds the transceiver quad, not the fabric. Y9 is counted
through `IBUFDS_GTE2`'s `ODIV2`, which divides by two, so that reading is half
the oscillator. Y8's buffer has only one route into the fabric and the SFP
transceivers use it ([section 15](#15-sfp-cages)), so in the full design
Y8 is counted through SFP1's user clock -- its `TXOUTCLK`, the line rate ÷ 40,
phase-locked to Y8 by whichever PLL SFP1's rate selects, carrying Y8's ppm
unchanged, and zero while the transceivers are held in reset. At the three
rates it reads 78,125,420, 156,250,838 and 257,813,884 Hz: +5.4 ppm each time,
the last through the QPLL. That both answer at all confirms MGTAVCC, MGTAVTT and MGTVCCAUX are
up.

⚠ **This measures a ratio to the PS oscillator**, scaled by an assumed 100 MHz
`FCLK_CLK0`. An error in PS_CLK moves every reading together, which is what the
four same-signed offsets above look like rather than four independently fast
crystals. It answers "is it there and is it the right frequency", not "how
accurate is it".

---

## 6. I/O banks and voltages

| Bank | Type | VCCO | Contents | IOSTANDARD |
|---|---|---|---|---|
| 0 | Config | 3.3V | JTAG, DONE, INIT_B, PROGRAM_B | — |
| 500 | MIO | 3.3V | MIO0–15: QSPI, USB reset, UART0 | (PS7) |
| 501 | MIO | 1.8V | MIO16–53: Ethernet, USB ULPI, SD0, eMMC, MDIO | (PS7) |
| 502 | PS DDR | 1.5V | PS DDR3 | (PS7) |
| 9 | HR | 3.3V | SFP control, PERST#, camera clock/GPIO/I2C, PL_CLK, FMC PRSNT | LVCMOS33 |
| 10 | HR | VCC_ADJ2 (3.3V) | 40-pin header, PL_LED1–4 (LED4–LED7), keys | LVCMOS33 |
| 11 | HR | 3.3V | HDMI RX, PL Ethernet, fan, FMC I2C, FMC PG_C2M | LVCMOS33 |
| 12 | HR | VCC_ADJ1 (2.5V) | FMC LA (part), FMC CLK1 | LVCMOS25 / LVDS_25 |
| 13 | HR | VCC_ADJ1 (2.5V) | FMC LA (part), FMC CLK0 | LVCMOS25 / LVDS_25 |
| 33 | HP | 1.5V | PL DDR3 data | SSTL15 (MIG) |
| 34 | HP | 1.5V | PL DDR3 address/control, SYS_CLK | SSTL15 (MIG) |
| 35 | HP | 1.8V | HDMI TX, MIPI CSI-2, PL_LED5/6 (LED8) | LVCMOS18, LVDS, HSUL_12 |

**Other bank details:**
- Banks 33 and 34 have DCI resistors: VRN/VRP 80.6R on L5/L4 and M12/M10.
- Banks 12 and 13 take their VREF from the FMC's VREF_A_M2C. Their VREF pins are AB26, AH29, T28 and R21.
- Bank 33's VREF pins (J6, C3) are tied to the PL DDR VTTREF.
- Bank 34's PUDC_B pin (A8) is pulled to ground through 1K, so I/O pull-ups are **on** during configuration.

---

## 7. PS peripherals (MIO)

Read from schematic sheet 2. This is the map in
[`../linux/board/ps7_config.tcl`](../linux/board/ps7_config.tcl), which the PL
builds apply and verify and which generates the `ps7_init` that SPL and U-Boot
are built from. The board boots from QSPI and eMMC on it with nothing
attached. The FMCOMMS2 port's `ps_reference.tcl` agrees.

| MIO | Function | Notes |
|---|---|---|
| 0 | QSPI1 CS | Second flash (U4) |
| 1 | QSPI0 CS | First flash (U2) |
| 2–5 | QSPI0 IO0–IO3 | MIO2/3 also boot straps (pulled low); MIO4/5 go to SW1 |
| 6 | QSPI0 CLK | Strap: pulled low |
| 7 | USB PHY reset (active low) | Strap: pulled low. Drives USB3320 RESETB through a diode. |
| 8 | QSPI feedback clock | Strap: pulled high |
| 9 | QSPI1 CLK | |
| 10–13 | QSPI1 IO0–IO3 | |
| 14 / 15 | UART0 RX / TX | To the FT2232HQ channel B, through a TXS0102 level shifter |
| 16–27 | Ethernet 0 RGMII | PHY1 RTL8211F-CG: 16 TXCK, 17–20 TXD0–3, 21 TXCTL, 22 RXCK, 23–26 RXD0–3, 27 RXCTL |
| 28–39 | USB0 ULPI | USB3320: 28 DATA4, 29 DIR, 30 STP, 31 NXT, 32–35 DATA0–3, 36 CLK, 37–39 DATA5–7 |
| 40–45 | SD0 (micro-SD) | 40 CLK, 41 CMD, 42–45 D0–D3. No CD or WP pins. |
| 46–51 | SD1 (eMMC, 4-bit) | 46 DAT0, 47 CMD, 48 CLK, 49 DAT1, 50 DAT2, 51 DAT3 |
| 52 / 53 | Ethernet 0 MDC / MDIO | PHY1 address 001 |

PS7 clocks (from `ps7_config.tcl`): CPU 666.7 MHz, FCLK0 100 MHz, FCLK1 200 MHz, QSPI 200 MHz, SDIO 100 MHz, UART 100 MHz, ENET0 125 MHz (1000 Mb/s). EMIO GPIO is 64 bits wide. SPI0 is routed to EMIO, as in the FMCOMMS2 configuration where it drives the AD9361; nothing here uses it.

---

## 8. DDR3 memory

**PS DDR3:** 2× MT41J256M16 on bank 502, 32-bit, 1 GB (`0x00000000`–`0x3FFFFFFF`). The PS7 DDR part is set to `MT41J256M16 RE-125`. DCI uses VRP/VRN at M21/N21 with 80.6R.

**PL DDR3:** 2× MT41J256M16 (U8 = bytes 0–1, U9 = bytes 2–3) on banks 33/34, 32-bit, 1 GB.
- Address and command lines have 40.2R termination to `PL_DDRVTT` (TPS51200). CK has 80.6R across the pair.
- Each chip has 240R on ZQ.
- Use the MIG 7-series IP with a 200 MHz system clock on `SYS_CLK` (F9/E8).
- A0–A14 and BA0–BA2 are all routed, so each x16 chip addresses its full 4 Gb.

**A MIG configuration that calibrates on this board** (measured;
the generator is [`../pl/ddr/gen_mig_prj.py`](../pl/ddr/gen_mig_prj.py)):

| Setting | Value | Why |
|---|---|---|
| Memory part | `MT41J256M16XX-125` | MIG already carries the timing for it |
| `InternalVref` | **0 (external)** | ⚠ bank 33's VREF pins go to the board's `VTTREF`. Internal VREF builds fine and then fails to calibrate. |
| DCI | on, `50 Ohms` | VRP/VRN reference resistors are fitted on both banks |
| Row / Col / Bank | 15 / 10 / 3 | 2^15 × 2^10 × 2^3 × 32 bit = 1 GB |
| `SystemClock` | "No Buffer" | the IBUFDS on F9/E8 lives in user RTL, so the pins stay in the XDC |
| tCK | 2500 ps (400 MHz, DDR3-800) | conservative; see below |

The parts are DDR3-1600 rated and the −2 device could drive them far harder.
400 MHz is enough because the CPU reaches this memory over `M_AXI_GP0` — 32
bits at 100 MHz — so the bus, not the DRAM, is the limit.

**Mapping it into the PS.** `M_AXI_GP0`'s window is `0x4000_0000`–`0x7FFF_FFFF`,
exactly 1 GB, and PS DDR ends at `0x3FFF_FFFF` — so the PL DRAM drops in at
`0x4000_0000` with no address decode and no hole. Anything else on the PL then
needs `M_AXI_GP1` (`0x8000_0000`), because nothing else fits beside a slave
that fills its window.

⚠ **`dd if=/dev/mem` cannot read this memory** — it fails `Bad address` and
moves zero records, because `/dev/mem`'s read/write path uses
`xlate_dev_mem_ptr()`, which returns NULL for physical addresses that are not
kernel RAM. `mmap()` works, which is why busybox `devmem` reads and writes it
happily. Anything bulk must mmap: see
[`../pl/ddr/memtest.c`](../pl/ddr/memtest.c).

### PL DDR3 data

| Signal | FPGA pin (bank 33) | Notes |
|---|---|---|
| DQ0 | J4 | U8, byte 0 |
| DQ1 | K1 | U8, byte 0 |
| DQ2 | J5 | U8, byte 0 |
| DQ3 | K5 | U8, byte 0 |
| DQ4 | J3 | U8, byte 0 |
| DQ5 | L3 | U8, byte 0 |
| DQ6 | K6 | U8, byte 0 |
| DQ7 | L2 | U8, byte 0 |
| DQ8 | G1 | U8, byte 1 |
| DQ9 | H6 | U8, byte 1 |
| DQ10 | H2 | U8, byte 1 |
| DQ11 | G6 | U8, byte 1 |
| DQ12 | H4 | U8, byte 1 |
| DQ13 | G5 | U8, byte 1 |
| DQ14 | H3 | U8, byte 1 |
| DQ15 | F2 | U8, byte 1 |
| DQ16 | F3 | U9, byte 2 |
| DQ17 | E3 | U9, byte 2 |
| DQ18 | F4 | U9, byte 2 |
| DQ19 | D1 | U9, byte 2 |
| DQ20 | D4 | U9, byte 2 |
| DQ21 | E1 | U9, byte 2 |
| DQ22 | E5 | U9, byte 2 |
| DQ23 | E2 | U9, byte 2 |
| DQ24 | C1 | U9, byte 3 |
| DQ25 | A3 | U9, byte 3 |
| DQ26 | B1 | U9, byte 3 |
| DQ27 | B5 | U9, byte 3 |
| DQ28 | B2 | U9, byte 3 |
| DQ29 | C4 | U9, byte 3 |
| DQ30 | C2 | U9, byte 3 |
| DQ31 | B4 | U9, byte 3 |
| DQS0_P / _N | K3 / K2 | byte 0 |
| DQS1_P / _N | J1 / H1 | byte 1 |
| DQS2_P / _N | E6 / D5 | byte 2 |
| DQS3_P / _N | A5 / A4 | byte 3 |
| DM0 | L1 | byte 0 |
| DM1 | G4 | byte 1 |
| DM2 | D3 | byte 2 |
| DM3 | A2 | byte 3 |

### PL DDR3 address and control

| Signal | FPGA pin (bank 34) |
|---|---|
| A0 | H7 |
| A1 | L8 |
| A2 | H11 |
| A3 | D10 |
| A4 | H8 |
| A5 | D11 |
| A6 | L7 |
| A7 | E10 |
| A8 | L10 |
| A9 | H12 |
| A10 | G7 |
| A11 | J9 |
| A12 | H9 |
| A13 | J11 |
| A14 | K10 |
| BA0 | K11 |
| BA1 | K8 |
| BA2 | G11 |
| RAS# | G9 |
| CAS# | E7 |
| WE# | F7 |
| CS# | F8 |
| CKE | D6 |
| ODT | J10 |
| RESET# | E11 |
| CK_P / CK_N | D9 / D8 |

---

### Measured from inside the fabric

A third AXI master in the fabric (`pl/board/rtl/axi_bist.v`, BIST engine 2 in
both designs) sweeps the PL DDR3 directly, without the CPU:

| | |
|---|---|
| 16,777,216 bytes written and verified | **392 MB/s**, 0 errors |

392 of a theoretical 400: the MIG's slave port is generated 32 bits wide at
100 MHz, so that is **98% of the port**, not of the memory. Getting past it
means regenerating the MIG with a wider port.

⚠ That engine shares the MIG's single AXI port with the CPU through an
ownership switch, one owner at a time, and the loser is answered **SLVERR**
rather than left waiting — a master hung on the PL bus here means a JTAG
`rst -system`. While the engine holds the bus, a CPU access to `0x4000_0000`
raises a bus error. That is the design working.

⚠ The engine is given **offsets into the DRAM starting at 0**, because it
addresses the MIG directly; the CPU reaches the same memory at `0x4000_0000`
only because that is where the GP0 window sits and the MIG sees just the low 30
bits.

---

## 9. LEDs, keys and fan

| Item | Net | FPGA pin | Bank | Polarity |
|---|---|---|---|---|
| LED4 (green) | PL_LED1 | AC16 | 10 | 1 = on (NPN Q1) |
| LED5 (green) | PL_LED2 | AC17 | 10 | 1 = on |
| LED6 (green) | PL_LED3 | AH18 | 10 | 1 = on |
| LED7 (green) | PL_LED4 | AE18 | 10 | 1 = on |
| LED8 bicolor, half A | PL_LED5 | G12 | 35 | 1 = on (NPN Q5) |
| LED8 bicolor, half B | PL_LED6 | F12 | 35 | 1 = on (NPN Q6) |
| KEY1 (K1) | PL_KEY1 | AJ18 | 10 | Pressed = 0 (4.7K pull-up to VCC_ADJ2) |
| KEY2 (K2) | PL_KEY2 | AE17 | 10 | Pressed = 0 |
| KEY3 (K3) | PL_KEY3 | AF17 | 10 | Pressed = 0 |
| KEY4 (K4) | PL_KEY4 | AF18 | 10 | Pressed = 0 |
| Fan PWM (J10) | FAN_PWM | W21 | 11 | NPN Q7 pulls the PWM line low when the pin is 1, so the logic is **inverted** |
| Fan tach (J10) | FAN_TACH | Y21 | 11 | 33R series, 4.7K pull-up to 3.3V, Schottky clamp |

LED1 (white) is FPGA DONE, LED3 (green) is 3.3V power, and LED2 (green) is USB-A VBUS enable. None of these are under FPGA control.

**From Linux.** The four user LEDs and the four keys are wired
into the PS as EMIO GPIOs by the designs in [`../pl/`](../pl/README.md), so
Linux exposes them as an LED class (`/sys/class/leds/rkz7100:green:led1`..`4`,
LED1 on the heartbeat trigger) and an input device (`KEY_1`..`KEY_4`, active
low, 20 ms debounce). The bicolor LED8 stays driven by the fabric as the PL's
own heartbeat. See "LEDs and keys" in [the Linux guide](linux-guide.md).

### The fan, and the die temperature (measured)

⚠ **An unconfigured FPGA leaves the fan OFF, not running.** PUDC_B is strapped
low (section 6), so the pull-ups are on during configuration, FAN_PWM (W21) is
pulled high, Q7 conducts and the fan's PWM line is held down. Measured, the
fan is worth roughly **8 °C** on an otherwise idle board: 33–38 °C with a
bitstream loaded and the fan running, against 40 °C and still climbing with
the fan held off, and 46.5–47 °C read with no bitstream at all (that last one
after a long spell running the PL DDR3 design, so it carries stored heat).
The thermal time constant is minutes, so a reading taken soon after a change
is part-way along a curve rather than a settled figure.

Nothing in the PL can change it — how long the board sits without a fan is
decided by whatever loads the bitstream, which is why U-Boot's PREBOOT loads
it before Linux starts, and [`../linux/board/S15fpga`](../linux/board/S15fpga)
does if U-Boot did not.

The **XADC** needs none of that. Its PS interface (`0xF8007100`) works with no
bitstream at all, and Linux's `xilinx-xadc` driver brings up the die
temperature and six supply rails as an IIO device. Read through `iio-hwmon`,
they come out as VCCINT 1.00 V, VCCAUX 1.78 V, VCCBRAM 1.01 V, VCCPINT 1.00 V,
VCCPAUX 1.78 V and VCCO_DDR 1.50 V — an independent check of the power table in
[section 3](#3-power).

A working fan controller is in [`../pl/`](../pl/README.md) and
[`../linux/`](../linux/README.md): the PWM comes from PS TTC1 through EMIO,
the PL inverts it for Q7 and counts the tachometer, and Linux drives it as an
ordinary hwmon `pwm1` with `fan1_input` in rpm beside it. The tachometer
follows the PWM monotonically over the whole range, and the fabric forces the
fan to full speed if the PWM waveform stops arriving.

A thermal zone on the XADC channel drives it with no daemon: the die
temperature moves the fan between five cooling states, 25% below 45 °C and
full at 75 °C. The lowest state is deliberately not 0% — a stopped waveform is
what the fabric reads as "nobody is driving this".

---

## 10. JTAG and UART

The JTAG USB-C port (USB1) connects to an **FT2232HQ** (U15). It has a 12 MHz crystal, and its configuration lives in a 93LC56 EEPROM, which Vivado needs in order to recognize the cable.

- **Channel A** (ADBUS0–3) is JTAG, through 33R resistors and a 74LCX125 buffer. The FMC card joins the chain when fitted (see [section 4](#4-boot-configuration-and-reset)).
- **Channel B** (BDBUS0/1) is a UART. A TXS0102 level shifter connects it to PS **UART0** on MIO14 (RXD) and MIO15 (TXD). It is the usual Linux console.

---

## 11. Ethernet

Two RTL8211F-CG PHYs (U18, U19), each with a 25 MHz crystal and an HR911130A RJ45 jack with magnetics and LEDs. Both are strapped to **PHY address 001**.

| | PHY1: PS Ethernet (RJ1) | PHY2: PL Ethernet (RJ2) |
|---|---|---|
| MAC | PS GEM0 (MIO16–27), `eth0` | PS **GEM1** over EMIO, through a GMII-to-RGMII core in the PL (bank 11), `eth1` |
| Interface | RGMII | RGMII |
| PHY I/O voltage | 1.8V (CFG_LDO = 10), matching MIO bank 501 | 3.3V (CFG_LDO = 00), matching bank 11 |
| MDC / MDIO | MIO52 / MIO53 | AG19 / AH19, GEM1's MDIO through the core |
| Reset | PHYRSTB pulled up only | PHYRSTB pulled up only |

**PL Ethernet (PHY2) pins, bank 11, LVCMOS33:**

| Signal | Pin | Signal | Pin |
|---|---|---|---|
| TXCK (FPGA → PHY) | Y22 | RXCK (PHY → FPGA) | AF20 |
| TXCTL | AF19 | RXCTL | AG20 |
| TXD0 | AB21 | RXD0 | AJ20 |
| TXD1 | AA22 | RXD1 | AE21 |
| TXD2 | AD21 | RXD2 | AG21 |
| TXD3 | AB22 | RXD3 | AH21 |
| MDC | AG19 | MDIO | AH19 (1.5K pull-up) |

The RTL8211F adds RGMII clock delays internally by default (RXDLY/TXDLY
straps), and both ports rely on that: neither design adds IDELAYs of its own.

| | PHY1 (RJ1) | PHY2 (RJ2) |
|---|---|---|
| Linux name | `eth0` | `eth1` |
| MAC address (this board's) | `02:00:da:b9:ee:0e` | `02:00:da:b9:ee:0f` |
| Both from | the EEPROM, at 0x20 | the EEPROM, at 0x26 |
| `phy-mode` | `rgmii-id` | `gmii` -- GEM1 to the core is GMII; it also leaves PHY2's delays as strapped |
| Needs | nothing in the PL | the full bitstream, `CONFIG_XILINX_GMII2RGMII`, and `S15fpga` |

**Selecting 10/100/1000.** Both are ordinary phylib PHYs behind a GEM, so
`ethtool -s ethN autoneg on advertise ...` sets either one; all three speeds
are measured working with traffic on both ports. On `eth1` a speed change also
has to reach the GMII-to-RGMII core, whose transmit clock depends on it; the
`xilinx_gmii2rgmii` driver writes the negotiated speed into the core's register
(MDIO address 8) after every PHY status read. See "The Ethernet PHYs, and selecting 10/100/1000" in
[the Linux guide](linux-guide.md) and "The PL Ethernet port" in
[the PL design](hh-rk-zynq7100-design.md).

**Measured.** Both links come up **1000 Mb/s full duplex**. `iperf3`, with the
other port down so every packet provably crossed the one being measured, the
board as server and the client on a PC on the same LAN:

| | `eth0` (PS, RJ1) | `eth1` (PL, RJ2) |
|---|---|---|
| Into the board | 670--673 Mbit/s, three runs (582--642 from a client behind WSL2's NAT) | **666--674 Mbit/s**, five runs |
| Out of the board | 612--770 Mbit/s, three runs (692--808 to that client) | **562--807 Mbit/s**, eight runs |
| DHCP + 20/20 pings | 1000, 100 and 10 Mb/s | 1000, 100 and 10 Mb/s |

Both are limited by the Cortex-A9s, not by the links; the outbound figure
swings run to run on both ports alike. Over a 60-second receive run `eth1`
took **4.8 GB with no CRC, FIFO or overrun error**, which bounds its receive
bit error rate below 8 × 10⁻¹¹ at 95% confidence. Real throughput, not a link light, is what proves the RGMII delays
are right, on both ports.

⚠ **Both ports on one LAN answer ARP for each other's addresses.** Linux's
default ARP behavior replies on any interface, so with `eth0` and `eth1` both
up on the same subnet a ping "to `eth1`" can be answered through `eth0`. Test
one port with the other down, as `pl/tools/eth2test.sh` does, or put them on
different networks.

---

## 12. USB 2.0

The PS USB0 controller connects over ULPI (MIO28–39) to a **USB3320** PHY (U20), which has a 24 MHz crystal. **MIO7** resets the PHY, active low, through diode D1, with a 10K pull-up to 1.8V.

The PHY's single D+/D− pair goes to **two** connectors:
- **USB2 (USB-C):** device mode. [`../linux/`](../linux/README.md) builds the gadget functions into the kernel and composes them at run time through configfs; boot `zynq-rkz7100-usbdev.dtb`, which sets `dr_mode = "peripheral"` and drops the PHY's `drv-vbus`.
- **USB3 (USB-A):** host mode. VBUS comes through a TPS2051 switch, enabled by the PHY's CPEN output (`USBCP_EN`); LED2 shows when it is enabled.

Use one connector at a time; they share the same signals.

**On the hardware.** MIO7 has to be pulsed before the PHY answers
at all -- the PS7 init leaves it tri-stated, and the symptom is
`ci_hdrc: unable to init phy: -110`; see `linux/README.md`. Once it is, the
host side reaches `USB 2.0 started`, and the device side (the `-usbdev`
device tree) gives a `ci_hdrc.0` UDC that an ACM gadget binds to.

**Measured on USB-A.** A Verbatim STORE N GO enumerates as `/dev/sda`,
14.4 GB FAT32. 64 MB written and read back with a matching MD5 after dropping
caches: **6.8 MB/s written, 22.8 MB/s read** (a second run: 5.8 and 21.9).

⚠ The write figure needs `conv=fsync`. Without it `dd` reports the page
cache -- 1.15 s for the same 64 MB, which works out at a speed USB 2.0 cannot
reach and should be the tell.

---

## 13. SD card, eMMC and EEPROM

- **micro-SD (SD1 connector):** PS SD0 on MIO40–45. It runs at 1.8V on the MIO side, and a TXS02612 level shifter drives the card at 3.3V. The card-detect contact is not connected to the PS.
- **eMMC:** a Samsung KLM8G1GETF-B041 (8 GB) on PS SD1, MIO46–51, 4-bit, with VCCQ at 1.8V and 10K pull-ups.
  - Its reset, `MMC_RSTN`, is not connected to any PS MIO pin.
  - [`../linux/`](../linux/README.md) puts its root filesystem here.
  - Linux sees it as `mmcblk1`, **7.28 GiB**, `8GTF4R`, high-speed MMC, with
    two 4 MiB boot partitions and a 512 KiB RPMB. The single data partition
    `mmcblk1p1` starts at LBA 16 and holds an ext4 root that U-Boot's distro
    boot finds through `/boot/extlinux/extlinux.conf`.
  - ⚠ The factory image ships here. Back it up before overwriting: the vendor
    does not publish it.
- **micro-SD measured:** a 29.2 GiB SDHC card enumerates as `mmcblk0` at high
  speed; raw read 15.5 MB/s, and a 32 MiB file written with `fsync` at
  14.5 MB/s read back with the same MD5 after a cache drop and remount.
- **EEPROM:** an AT24C256C (U13, 256 Kbit) at I2C address **0x50** on `CAM_EE_SCL/SDA` (AC19/AB20, bank 9).
  - That bus is shared with the MIPI camera connector.
  - ⚠ **It is writable.** R102 4.7K pulls WP to **ground** (sheet 11), and on
    the AT24C256 `WP` is active high: low allows writes, high inhibits them.
    Confirmed on the hardware by writing a byte at offset `0x100` and reading
    it back.
  - A0/A1/A2 are all grounded, which is where 0x50 comes from.
  - The AT24C256C datasheet (Atmel-8568F, section 4) confirms it: WP low or
    floating allows writes, and only a tie to VCC inhibits them.
  - **In use:** the board's two Ethernet MAC addresses, six raw bytes each:
    `eth0`'s at offset `0x20`, which U-Boot reads at boot and hands to Linux,
    and `eth1`'s -- the PL port's -- at `0x26`, which Linux reads itself. See
    "The MAC address" in [the Linux guide](linux-guide.md).
  - **Factory contents:** an ASCII timestamp at offset 0 (the placeholder
    `2026-01-01 00:00:00` illustrates the format), and `0xFF` for the rest of its 32 KiB; the MAC
    addresses above are added to that. Linux binds
    it as `at24 2-0050: 32768 byte 24c256 EEPROM` — 32 KiB, writable.

**Reaching it from Linux.** This bus is on PL pins, and the PS has no I2C
controller wired to it. The designs in [`../pl/`](../pl/README.md) hand the
two pins to the PS as EMIO GPIOs and Linux bit-bangs them with `i2c-gpio`;
see "I2C" in [the Linux guide](linux-guide.md). It needs a
bitstream loaded, like everything else on PL pins.

---

## 14. PCI Express

- An x8-size edge connector with **4 lanes** wired to GTX quad **111** (Gen2, 5 GT/s, is the XC7Z100's limit).
- The reference clock comes from the slot, AC-coupled, to MGTREFCLK0_111 (U8/U7).
- **PERST#** goes to **AC18** (bank 9) with a 4.7K pull-up to 3.3V.
- PRSNT1# is tied to PRSNT2# at all three positions (x1, x4 and x8).
- The slot's 12V can power the whole board (see [section 3](#3-power)). SMBus, WAKE#, JTAG and the slot's 3.3V pins are not used.
- The TX lanes are AC-coupled on the board.

| PCIe lane | FPGA TX P / N | FPGA RX P / N | GTX quad |
|---|---|---|---|
| Lane 0 | V2 / V1 | AA4 / AA3 | 111 ch3 |
| Lane 1 | W4 / W3 | Y6 / Y5 | 111 ch2 |
| Lane 2 | Y2 / Y1 | AB6 / AB5 | 111 ch1 |
| Lane 3 | AB2 / AB1 | AC4 / AC3 | 111 ch0 |

**The lane order is reversed** (lane 0 = channel 3). The master XDC pins each lane explicitly.

---

## 15. SFP+ cages

The two SFP+ cages are channels 2 and 3 of GTX quad **112**, clocked from its
156.25 MHz reference. Channels 0 and 1 of the same quad are the SATA ports,
with their own 150 MHz reference ([section 16](#16-sata)).

| Port | FPGA TX P / N | FPGA RX P / N | GTX quad |
|---|---|---|---|
| SFP1 | P2 / P1 | T6 / T5 | 112 ch2 |
| SFP2 | N4 / N3 | P6 / P5 | 112 ch3 |

**SFP+ cages J1 and J4** (both TE 1367073-1). The pin list below comes from
**sheet 16 rendered at 300 dpi**, not from the OCR text layer: "not
connected" is a claim worth being sure of.

Only **two** pins per cage reach the FPGA:

| Cage pin | Signal | FPGA |
|---|---|---|
| 3 | TX_DISABLE | SFP1 `AB19`, SFP2 `AA20` |
| 8 | LOS | SFP1 `AA18`, SFP2 `AA19` |

Each has a 4.7K pull-up (R155/R160 on J1, R162/R167 on J4), so the laser stays
off until the FPGA drives the pin low.

Everything else on the low-speed side terminates at a pull-up and goes
nowhere:

| Cage pin | Signal | On the board |
|---|---|---|
| 4 | SDA (MOD-DEF2) | 4.7K to +3.3V — **R157** (J1), **R164** (J4) |
| 5 | SCL (MOD-DEF1) | 4.7K to +3.3V — **R156** (J1), **R163** (J4) |
| 6 | MOD_ABS (MOD-DEF0) | 4.7K to +3.3V — **R158** (J1), **R165** (J4) |
| 7 | RS0 | 4.7K to +3.3V — **R159** (J1), **R166** (J4) |
| 9 | RS1 | 4.7K to +3.3V — **R161** (J1), **R168** (J4) |
| 2 | TX_FAULT | tied to the pin-1 ground net |
| 1, 10 | VeeT, VeeR | ground |

**Both are Linux GPIOs.** [`../pl/board/`](../pl/README.md) hands them to the
PS through EMIO, named in the device tree:

| Line | gpiochip0 | |
|---|---|---|
| `SFP1-TX_DISABLE` | 106 | out, active high, pulled up |
| `SFP2-TX_DISABLE` | 107 | out, active high, pulled up |
| `SFP1-LOS` | 108 | in |
| `SFP2-LOS` | 109 | in |

⚠ **A module's transmitter is OFF until software drives `TX_DISABLE` low**,
and it returns there the moment software stops holding the line -- the pin is
released, not driven high, so the board's pull-up decides. An SFP fitted here
that "will not link" has usually never been asked to transmit:

```
gpioset --mode=signal gpiochip0 106=0 107=0 &
```

**Measured with a copper SFP in each cage:** released, both `TX_DISABLE` pins
read **1**, so the pull-ups are real and the pins are connected; `LOS` reads
**0** on both in every state. A 1000BASE-T SFP reports nothing useful on
`LOS`, so copper modules cannot show the pin's effect.

**Measured with an optical cable:** `TX_DISABLE` reaches the module and
works. With two legs of a QSFP+ to 4x SFP+ active optical cable in SFP1 and
SFP2 and a PRBS-31 source and checker at the QSFP end, both pins released (reading 1) leave the
legs dark: the far receivers get nothing, while the direction into this
board is error-free. Held low with the `gpioset` above, both directions carry
PRBS-31 error-free at 3.125, 6.25 and 10.3125 Gb/s.

⚠ So the FPGA can **enable a module and read its loss-of-signal, and nothing
else**. In particular:

- **No module I2C**, so no ID EEPROM at 0x50 and no diagnostics at 0x51. A
  module's type, vendor, wavelength and temperature are all unreachable.
- **No MOD_ABS**, so software cannot even tell whether a cage is occupied.
  Whether a module is present has to be inferred from LOS, or assumed.
- **No rate select**, so a multi-rate module stays at whatever RS0/RS1 pulled
  high selects.
- **TX_FAULT is grounded**, not merely unconnected, so a module reporting a
  fault is pulling against a hard ground. That is harmless for an open-drain
  output, but it does mean the signal can never be recovered by reworking a
  pull-up — the net would have to be cut.

Each cage has filtered 3.3V for VCCT and VCCR.

### The SFP transceivers

**Working at 3.125, 6.25 and 10.3125 Gb/s, both ways, through a passive DAC
cable** between the cages, all from one bitstream. The full design runs each
transceiver's own PRBS generator and checker on SFP1 (`GTXE2_CHANNEL_X0Y14`)
and SFP2 (`GTXE2_CHANNEL_X0Y15`), from the 156.25 MHz reference on
`MGTREFCLK1_112`, and a register picks each channel's rate at run time. Linux
drives it with [`pl/tools/gtxtest.sh`](../pl/tools/gtxtest.sh) (`-r all` for
all three).

| Rate | PLL | PRBS-31, 15 s, each direction | BER (95%) |
|---|---|---|---|
| 3.125 Gb/s | each channel's CPLL, /2 | 0 errors in 4.7 × 10¹⁰ bits | < 6.3 × 10⁻¹¹ |
| 6.25 Gb/s | each channel's CPLL, /1 | 0 errors in 9.5 × 10¹⁰ bits | < 3.2 × 10⁻¹¹ |
| 10.3125 Gb/s | the quad's QPLL, /1 | 0 errors in 1.57 × 10¹¹ bits | < 1.9 × 10⁻¹¹ |

Each row holds for near-end PMA loopback and through the cable alike, and
both paths run at normal polarity.

⚠ **The test proves the pattern crosses the cable**, rather than returning
inside the chip: a single TX bit error injected at one cage is counted by the
**other** cage's checker and not by its own, in both directions and at every
rate. One injected bit error counts as a burst of 2 to 4 words, because the
checker is self-synchronizing and PRBS-31 has two taps.

⚠ **10.3125 Gb/s needs a second attribute.** Against the wizard's own
configurations of all three rates, `RXCDR_CFG` differs for every rate and
`PMA_RSV` above 6.6 Gb/s. The rate change writes both over the DRP; with only
the first, 10.3125 Gb/s fails even in near-end loopback. It sets the output
dividers the same way, as the `TXOUT_DIV`/`RXOUT_DIV` attributes, and leaves
the `TXRATE`/`RXRATE` ports at 000: those ports are sampled on the user clock
the change itself stops ([the PL design](hh-rk-zynq7100-design.md), "The SFP+
cages"). ⚠ A receiver can still fail to leave reset, intermittently, at
3.125 Gb/s; switching that channel to 10.3125 Gb/s and back recovers it, and
so does a PL reload.

⚠ **Nothing here identifies the module or cable.** With no module I2C wired
(above), a DAC's EEPROM and an optical module's diagnostics are unreachable,
and `LOS` says nothing useful about a passive cable. A passive DAC needs
nothing from the I2C, and the active optical cable above works without it; a
module or active cable that waits for I2C setup will not.

The register map and the design notes are in [the PL design](hh-rk-zynq7100-design.md),
"The SFP+ cages".

---

## 16. SATA

The two SATA connectors are channels 0 and 1 of GTX quad **112**, clocked from
its 150 MHz reference. Channels 2 and 3 of the same quad are the SFP+ cages
([section 15](#15-sfp-cages)).

| Port | Connector | FPGA TX P / N | FPGA RX P / N | GTX quad |
|---|---|---|---|---|
| SATA1 | J5 | T2 / T1 | V6 / V5 | 112 ch0 |
| SATA2 | J6 | R4 / R3 | U4 / U3 | 112 ch1 |

Both directions are AC-coupled with 100 nF on the board. **Both connectors
are wired as hosts** (sheet 16): the FPGA's TX pair lands on pins 2/3 (A+/A−)
and its RX pair on pins 5/6 (B−/B+), with pins 1, 4 and 7 grounded.

⚠ **So a standard SATA cable between J5 and J6 cannot loop them back.** A SATA
data cable is wired pin to pin, and the crossover comes from the host and the
device transmitting on opposite pairs. Two host ports on one cable join
transmitter to transmitter. Testing these lanes needs a SATA device, or a
cable that swaps pair A with pair B.

Neither design uses these lanes. Their 150 MHz reference is measured running,
at 75,000,753 Hz through its divide-by-2 output, +10 ppm ([section 5](#5-clocks)).

---

## 17. HDMI output (ADV7511)

An ADV7511KSTZ (U22) is driven by 24-bit parallel video from bank 35 at 1.8V.

| Signal | FPGA pin | Notes |
|---|---|---|
| HDMI_TX_CLK | F14 | Pixel clock |
| HDMI_TX_DE / HSYNC / VSYNC | J14 / C14 / C16 | |
| HDMI_TX_SCL / SDA | H14 / K15 | 2K pull-ups to 1.8V. Main map at 0x72 (8-bit), 0x39 (7-bit). |
| HDMI_TX_INT | G17 | 2K pull-up |

The data bus uses the ADV7511's 24-bit RGB 4:4:4 input pins:

| HDMI_TX | FPGA pin | ADV7511 pin |
|---|---|---|
| D0 | K13 | D4 |
| D1 | E17 | D5 |
| D2 | F17 | D6 |
| D3 | D16 | D7 |
| D4 | E16 | D8 |
| D5 | E15 | D9 |
| D6 | G14 | D10 |
| D7 | D14 | D11 |
| D8 | H13 | D16 |
| D9 | J13 | D17 |
| D10 | G15 | D18 |
| D11 | F15 | D19 |
| D12 | G16 | D20 |
| D13 | C13 | D21 |
| D14 | A15 | D22 |
| D15 | J15 | D23 |
| D16 | B15 | D28 |
| D17 | D15 | D29 |
| D18 | B16 | D30 |
| D19 | A17 | D31 |
| D20 | B17 | D32 |
| D21 | C17 | D33 |
| D22 | J16 | D34 |
| D23 | H16 | D35 |

**Reaching it from Linux:** bit-banged over EMIO GPIOs with `i2c-gpio`, like
the EEPROM bus ([section 13](#13-sd-card-emmc-and-eeprom)); it needs a
bitstream loaded.

The DDC lines have 2K pull-ups to 5V, and HPD has a 10K pull-down.

**From the schematic (sheet 18).** U22 is an
**ADV7511KSTZQ**, 100-pin.

| | |
|---|---|
| Supplies | `DVDD1V8`, `PLVDD1V8` and `AVDD1V8` from **+1.8V**, each through a PBY100505T ferrite (L19/L20/L21); `MVDD3V3` from **+3.3V** through L22 |
| I2C | SDA pin 56, SCL pin 55, **2K pull-ups to +1.8V** (R183/R184), which is why these pins are LVCMOS18 on bank 35 |
| Interrupt | `INT` pin 45 → `HDMI_TX_INT`, 2K pull-up (R185) |
| CEC clock | **Y10**, an OT322512MJBA4SL oscillator on +3.3V, through R186 33R — not a crystal |
| `R_EXT` | pin 28, 887R to ground (R187) |
| Video in | `CLK` 79, `DE` 97, `VSYNC` 2, `HSYNC` 98 |
| Data mapping | The 24 bits land on the ADV7511's **upper byte lanes**: `HDMI_TX_D0..D7` → D4–D11, `D8..D15` → D16–D23, `D16..D23` → D28–D35. The unused low bits of each lane are tied off. |
| TMDS | Each pair through an RClamp0524P (D2/D3/D4) to connector HDMI1; HEAC± is AC-coupled |
| CEC bus | Pin 48 → **HDMI1 pin 13**, pulled up by **R179 27K to +3.3V through D5** (1N5819WS, anode at the resistor). This is the **only** CEC pull-up on the board — the ADV7611 end has none (see the end of [section 18](#18-hdmi-input-adv7611)) |
| HPD | Pin 30 ← the connector's `HOT_PLUG_DET` (pin 19), with **R182 10K to ground** |
| DDC | HDMI1 pins 15/16, **2K pull-ups to +5V** (R180/R181) |

**Measured:** the ADV7511 answers at **0x39** over the bit-banged
I2C, along with its other maps at 0x38, 0x3c, 0x3e and 0x3f.

⚠ **On a loopback the receiver needs an EDID before this works.** Without
one the ADV7611 holds HPD low, and the ADV7511 powers itself down while HPD
is low: `v4l2-ctl -d /dev/v4l-subdev0 --set-edid=type=hdmi` on the receiver,
then the transmitter locks.

**Measured: the fabric drives it, and it locks.** A pixel clock,
CEA-861 timing and a 24-bit test pattern come from `pl/board/rtl/hdmi_out.v`;
`pl/tools/hdmitest.sh` writes the chip's setup over the bit-banged I2C.

| | |
|---|---|
| MMCM | locked — register `0x14` bit 1 in the PL |
| ADV7511 | answers, revision `0x14`, accepts the setup |
| `0x9E` bit 4 | **set** — its PLL is locked to our pixel clock |

So the pixel clock leaves through its `ODDR`, reaches the chip on the right
pin, and the chip locks to it. **No picture has been seen**, because that needs
a monitor.

⚠ **The ADV7511 powers itself down when HPD is low**, whatever is written to
`0x41`. With no cable attached, `0x41` is written as `0x10` and reads back
`0x50` — bit 6, power-down, set by the chip itself — and `0x9E` then reads
`0x00`, because an unpowered PLL cannot lock to anything. That is not a fault,
but it makes the two most useful diagnostics read exactly as they would if the
pixel clock were dead. `hdmitest.sh -f` sets `0xD6[7:6] = 11` so the chip
behaves as though HPD were asserted; that is how the lock above was measured,
and it is the only way to test the fabric side without a sink.

**The pixel clock is exact:** the MMCM makes 74.25 MHz from the 200 MHz
oscillator as 200 ÷ 8 × 37.125 ÷ 12.5 (VCO 928.125 MHz), so 720p runs at
60.000 Hz; the same VCO ÷ 6.25 gives 1080p's 148.5 MHz. A local oscillator
(Y10) supplies the CEC clock.

### CEC

CEC is one bus shared by both connectors, and on this board the transmitter
side matters most: **R179, 27K to +3.3V through D5, is the bus's only
pull-up**, on HDMI1. The ADV7611 end has none, so the receiver can transmit
only when the cable carries pin 13 through (see the end of [section 18](#18-hdmi-input-adv7611)).

The ADV7511's CEC is configured **over I2C by hand**. Its Linux driver is a
DRM bridge that needs a DRM pipeline, and this board has none, so nothing sets
up its CEC controller at boot.

⚠ That configuration is volatile: it is lost on every power cycle.
`pl/tools/cectest.sh` re-applies it on each run.

CEC works in both directions between HDMI1 and HDMI2 over one HDMI cable,
driven by `cectest.sh`. The receiving half is at the end of
[section 18](#18-hdmi-input-adv7611).

---

## 18. HDMI input (ADV7611)

An ADV7611 (U23) outputs 24-bit parallel video through 33R resistors to bank 11 at 3.3V.
- **Supplies:** own regulators, 3.3V (XC6206) and 1.8V (ME6211), fed from 5V.
- **EDID:** the ADV7611 answers the source's EDID requests itself.
- **HPD:** HPA_A drives the connector's hot-plug line.

**Measured: the ADV7611 answers at 0x4C**, reporting revision `0x2051` in
registers 0xEA/0xEB (unless it has wedged; see known issue 12).

⚠ **`i2cdetect -r` does not find it.** The part wants a register address
written before a read, so forcing SMBus read-byte probing returns nothing and
looks exactly like a dead chip. The default probing, or `-q`, finds it.

| Signal | FPGA pin | Notes |
|---|---|---|
| HDMI_RX_PCLK (LLC) | AD23 | Clock-capable (SRCC) |
| HDMI_RX_DE / HS / VS | AJ24 / AH24 / AG24 | |
| HDMI_RX_SCL / SDA | AC24 / AD24 | 2K pull-ups to 3.3V. IO map at 0x98 (8-bit). |
| HDMI_RX_RST | AG25 | **4.7K pull-down: the ADV7611 stays in reset until the FPGA drives this pin high** |

**From the schematic (sheet 19).** U23 is an
**ADV7611**, 64-pin with a ground pad on pin 65.

| | |
|---|---|
| Clock | **Y11, 28.63636 MHz crystal** on XTALP (58) / XTALN (59), 10 pF loading caps (C376/C377) and a 1M bias resistor (R211) |
| Supplies | `DVDDIO` (44, 34, 23) from **+3.3V_HDMI_A**; `TVDD` (11, 8, 5) from +3.3V_HDMI; `PVDD` (57), `DVDD` (60, 52, 40, 24) and `CVDD` (14, 2) from **+1.8V_HDMI** |
| Rails | U24 XC6206P332MR makes +3.3V_HDMI from **+5V**, then L23 ferrite gives +3.3V_HDMI_A. U25 ME6211C18M5G-N makes +1.8V_HDMI from +5V, enabled by R223 10K from +3.3V_HDMI |
| I2C | SCL 53, SDA 54, **2K pull-ups (R214/R215) to +3.3V_HDMI_A** — so a 3.3V bank 11 drives them directly |
| Reset | `RESET` pin 56, **4.7K pull-down (R213)** |
| Video out | `LLC` 25, `DE` 45, `HS` 46, `VS/FIELD/ALSB` 47, `P0..P23` through 33R series resistors |
| TMDS in | RXA pairs through RClamp0524P (D6/D7) from connector HDMI2 |
| CEC bus | Pin 61 → **HDMI2 pin 13**, and **no pull-up at this end** — the bus relies entirely on R179 on the transmit connector, reaching this end through the cable. Measured working in both directions; see known issue 10 (pin 14, HEC, is left unconnected) |
| Interrupts | **None reach the FPGA.** `INT1` (pin 55) has no net, and the alternate `SCLK/INT2` (49) and `MCLK/INT2` (51) are unconnected as well; pin 1 is wired but used for its **HPA** function. This is why `hdmi-receiver@4c` declares no `interrupts`, and why the `adv7604` driver has to poll for CEC to work — known issue 10 |

⚠ `VS/FIELD/ALSB` (pin 47) doubles as the **I2C address select**, sampled out
of reset: low gives 0x98 (7-bit 0x4C), high gives 0x9A (0x4D). It is wired to
the FPGA, so whatever the PL does with that pin decides the address.

**Reaching it from Linux:** bit-banged over EMIO GPIOs with `i2c-gpio`, like
the EEPROM bus ([section 13](#13-sd-card-emmc-and-eeprom)); it needs a
bitstream loaded.

**Capturing from Linux.** The receiver hands the fabric 24-bit RGB with its
own clock, and everything that turns that into a V4L2 device already exists in
this kernel:

```
HDMI2 -> ADV7611 -> 24-bit RGB + LLC/DE/HS/VS -> hdmi_rx_capture -> AXI VDMA -> S_AXI_HP0 -> PS DRAM
            |                                                          |
      adv7604 over i2c-gpio                                  xilinx_dma, xilinx-vipp -> /dev/video0
```

`adv7604` (which covers the ADV7611), `xilinx_dma` and the `xilinx-vipp` /
`xilinx-dma` V4L2 pair are all mainline and all already built in, so no driver
has to be written for this path. It **works**: booting
`zynq-rkz7100-hdmirx.dtb` gives `/dev/video0`, and with HDMI1 looped back to
HDMI2 it captures 1280x720p60 in `BGR3` -- see "HDMI input" in
[the PL design](hh-rk-zynq7100-design.md) for the measurements.

⚠ **The VDMA's stream clock must be a PS clock, not the ADV7611's LLC**, even
though the VDMA is able to cross clocks itself. A VDMA whose stream clock is
not running does not answer its AXI-Lite *control* port either, so with no
HDMI source the DMA driver's first register read during probe never completes
and the kernel hangs mid-boot with no console past the PL330 driver. The
crossing happens in `axis_cdc_fifo.v` instead, which is allowed to stop when
the cable is unplugged.

⚠ **720p60 and below.** The capture path is constrained for a 74.25 MHz
pixel clock, which covers 720p60, 1080p30, 576p, 480p and VGA. 1080p60 needs
148.5 MHz and does not close: the LLC arrives at the capture flops 4.4 ns
late through a BUFG, the placer inserts a 7.1 ns ZHOLD delay in the data path
to fix the resulting hold violation, and that leaves nothing for setup.
Getting 1080p60 means deskewing the clock with an MMCM rather than delaying
the data. See "HDMI input" in [the PL design](hh-rk-zynq7100-design.md).

⚠ **Two kernel patches are needed**, both in `linux/board/patches/linux/`,
and neither is optional:

| | |
|---|---|
| `0001-xilinx-vip-...` | `adv7604` reports `MEDIA_BUS_FMT_RGB888_1X24`, which is not in the Xilinx VIP format table. Without it `VIDIOC_STREAMON` returns `-EINVAL` on an otherwise perfect pipeline. |
| `0002-adv7604-poll-...` | The board connects no interrupt to the ADV7611, and `adv7604` services CEC only from its interrupt handler. Without it CEC frames are acknowledged on the wire but every transmit times out. Capture is unaffected. |

⚠ A loopback from HDMI1 to HDMI2 tests both ends at once, and is the only
test available without a monitor or a source. It is not equivalent to either:
the ADV7611 is far more tolerant than a TV about InfoFrames, and a real
source negotiates EDID differently.

| HDMI_RX | FPGA pin | ADV7611 pin |
|---|---|---|
| D0 | AC22 | P0 |
| D1 | AE23 | P1 |
| D2 | AF24 | P2 |
| D3 | AH23 | P3 |
| D4 | AG22 | P4 |
| D5 | AF22 | P5 |
| D6 | AF23 | P6 |
| D7 | AH22 | P7 |
| D8 | AE22 | P8 |
| D9 | AC23 | P9 |
| D10 | AK17 | P10 |
| D11 | AK18 | P11 |
| D12 | AJ19 | P12 |
| D13 | AK20 | P13 |
| D14 | AK21 | P14 |
| D15 | AJ21 | P15 |
| D16 | AK22 | P16 |
| D17 | AK23 | P17 |
| D18 | AJ23 | P18 |
| D19 | AK25 | P19 |
| D20 | AJ25 | P20 |
| D21 | AA23 | P21 |
| D22 | AA24 | P22 |
| D23 | AB24 | P23 |

### CEC

The ADV7611's CEC is `/dev/cec0`, through the `adv7604` driver; it needs
`CONFIG_VIDEO_ADV7604_CEC=y` and the polling patch (known issue 10).

This end has no CEC pull-up; the bus relies on R179 on HDMI1, through the
cable. The transmitting half, and how `pl/tools/cectest.sh` drives both ends
over one cable between HDMI1 and HDMI2, is at the end of
[section 17](#17-hdmi-output-adv7511).

⚠ A cheap HDMI cable may omit pin 13. The receiver then cannot transmit at
all, while the transmitter still can, because only its end has the pull-up.

---

## 19. MIPI CSI-2 camera

**Working: an Arducam 5 MP OV5647 module on J9 is `/dev/video1`**, RAW10
Bayer, in every mode the sensor's driver offers, with the full bitstream
and the capture device tree (`zynq-rkz7100-hdmirx.dtb`).

| Mode | Per lane | Measured, steady state | Checked |
|---|---|---|---|
| 640x480 | 315 Mb/s | 67.5 fps | whole frames, exact color bars, no damaged packet |
| 1296x972 | 441 Mb/s | 32.1 fps | the same |
| 1920x1080 | 441 Mb/s | 33.0 fps | the same |
| 2592x1944 | 472.5 Mb/s | 16.8 fps | the same; 10 MB a frame |

"Exact color bars" is the sensor's test pattern arriving bit for bit;
"no damaged packet" is the CSI-2 receiver's own ECC, CRC and start-of-
transmission counts staying at zero, over 300 frames at 640x480 and 60 at
2592x1944. [`pl/tools/camtest.sh`](../pl/tools/camtest.sh) runs all of it,
including three streams back to back.

```
OV5647 --2 lanes--> soft D-PHY + CSI-2 RX --> cam_guard --> AXI VDMA --> S_AXI_HP3 --> DRAM
  (I2C 0x36)         (bank 35, 0x8002_0000)                 (0x8001_0000)
```

Drivers: `ov5647`, `xilinx-csi2rxss` and `xilinx-vipp` with `xilinx_dma`, all
in this kernel. The camera is its own media device; with the HDMI input also
up it is `/dev/media1`, otherwise `/dev/media0`. `camtest.sh` finds it by name.
To capture, set the mode on every pad -- and the input delay that mode needs
-- with [`pl/tools/camsetup.sh`](../pl/tools/camsetup.sh), then stream:

```
sh camsetup.sh 1296 972
v4l2-ctl -d /dev/video1 --set-fmt-video=width=1296,height=972,pixelformat=BG10,bytesperline=2592 \
         --stream-mmap --stream-count=10 --stream-to=frames.raw
```

⚠ **`field:none` must be given for the receiver's pads** (`camsetup.sh` does
it). Without it they hold
`V4L2_FIELD_ANY`, the link validation refuses the sensor's `NONE`, and
`VIDIOC_STREAMON` fails with a bare `Broken pipe`. Set `bytesperline` too: the
node otherwise keeps the stride of its 1920-pixel default.

**What it needs**, each measured on the board:

| | |
|---|---|
| `clock-noncontinuous` on the sensor's endpoint | With a continuous clock lane only the FIRST stream after the bitstream loads delivers frames; every later one runs with the byte clock present and no packet received, and neither the receiver's reset nor a full fabric reset brings it back. With the lane dropping to LP-11 between lines, every stream restarts. |
| `cam_guard` between the receiver and the VDMA | Every stream begins with a partial frame that has no frame start. Without the guard the VDMA takes about 300 lines of it and stops, the receiver's line buffer overflows, and its driver disables the core until the stream ends. The guard always accepts, and drops to the next frame start on overflow or after an idle gap. |
| The D-PHY's input delay, per mode | Swept against the receiver's damaged-packet counts, the clean window depends on the line rate: 640x480 at taps 0..25 (and 31), 1296x972 and 1920x1080 at 1..19, and 2592x1944 **only at 30 and 31**. The bitstream resets to 10, clean for the first three with no software; `pl/tools/camsetup.sh` sets 31 for 5 MP. `camtest.sh -t` repeats the sweep. |
| 128 MB of CMA | A 5 MP frame is 10 MB and streaming needs at least three; the default 16 MB holds one. |
| No internal termination | The board fits 150R across each HS pair, always in circuit; `DIFF_TERM` on top would leave 60R. |

**The control lines.** J9 pin 5 (`CAM_GPIO`, Linux gpio 62) is the Raspberry
Pi connector's CAM_IO0, the module's power enable: the device tree names it
the sensor's `pwdn-gpios`, and the driver powers the module off between
streams. The module also pulls it up itself. J9 pin 4 (`CAM_CLK`, gpio 63) is
CAM_IO1, unused: the module carries its own 25 MHz oscillator -- it answers on
I2C with nothing driving that pin -- and the device tree only tells the driver
so, with a fixed clock.

**Registers** for looking inside: the receiver at `0x8002_0000`, its D-PHY at
`+0x1000` (IDELAY taps at `+0x04`, a byte per lane; HS settle at `+0x30` and
`+0x48`), the camera VDMA at `0x8001_0000`, and in the register file's block 2
the D-PHY byte-clock frequency and `cam_guard`'s counters -- see "The camera"
in [the PL design](hh-rk-zynq7100-design.md).

### The connector

The 15-pin 1.0 mm FPC connector J9 is 2-lane. Its pinout is a Raspberry Pi camera connector numbered in reverse:

| J9 pin | Signal | J9 pin | Signal |
|---|---|---|---|
| 1 | +3.3V | 9 | GND |
| 2 | CAM_EE_SDA (AB20) | 10 | MIPI_LAN1_P |
| 3 | CAM_EE_SCL (AC19) | 11 | MIPI_LAN1_N |
| 4 | CAM_CLK (AD20; the Pi's CAM_IO1) | 12 | GND |
| 5 | CAM_GPIO (AD19; the Pi's CAM_IO0) | 13 | MIPI_LAN0_P |
| 6 | GND | 14 | MIPI_LAN0_N |
| 7 | MIPI_CLK_P | 15 | GND |
| 8 | MIPI_CLK_N | | |

**D-PHY network** (sheet 20). The board uses a passive network in the style of AMD XAPP894:
- Each HS pair (CLK, LAN0, LAN1) goes straight to an LVDS-capable pair on bank 35 (1.8V), with 150R across it (R281, R285, R292) -- the HS termination.
- Each wire also reaches a low-power (LP) input through its own 100R resistor.

| D-PHY lane | HS pair (LVDS) | LP pair (HSUL_12) |
|---|---|---|
| Clock | MIPI_CLK E13 / D13 | MIPI_LPCLK B14 / A14 |
| Data 0 | MIPI_LAN0 C11 / B11 | MIPI_LP0 A13 / A12 |
| Data 1 | MIPI_LAN1 C12 / B12 | MIPI_LP1 F13 / E12 |

With `HSUL_12` on the LP inputs, bank 35 needs `INTERNAL_VREF 0.6`. That is compatible with the bank's LVCMOS18 HDMI TX pins.
The HS inputs are `LVDS` with `DIFF_TERM FALSE`, because the 150R is already there.

---

## 20. FMC HPC connector

J7 is an ASP-134486-01, a full-size HPC connector. What is wired:
- **LA00–LA33 are all present**, split across banks 12 and 13, both at VADJ = `VCC_ADJ1`.
- **All 8 DP lanes** and both GBTCLKs go to GTX quads 109 and 110.
- **HA00–HA23 and HB00–HB21 are not connected.**

| FMC function | Connection |
|---|---|
| VADJ (C39/C40/H40 ...) | VCC_ADJ1, 2.5V by default (section 3) |
| 12P0V, 3P3V, 3P3VAUX | Board 12V and 3.3V |
| VREF_A_M2C (H1) | FMC_VREF: the VREF pins of banks 12/13 |
| PG_C2M (D1) | `PWRGD`, FPGA **Y23** (bank 11), 4.7K pull-up to 3.3V |
| PRSNT_M2C_L (H2) | `FMC_PRSNT`, FPGA **AE20** (bank 9), 4.7K pull-up. It also switches the JTAG chain. |
| PG_M2C (F1) | 4.7K pull-up to 3.3V. Not connected to the FPGA. |
| SCL / SDA (C30/C31) | FPGA **AC21 / W23** (bank 11), 4.7K pull-ups to 3.3V |
| GA0 / GA1 | Ground (the card's EEPROM is at 0x50) |
| TCK/TMS/TDI/TDO | In the board JTAG chain when a card is fitted |

### LA pairs

"CC" marks the clock-capable pairs. The last column is how the FMCOMMS2 port
uses each pair, which is what corroborates the schematic reading.

⚠ **Nothing here has been verified on hardware.** No FMC card has been fitted
to this board, and nothing in this repository touches any FMC signal, its
I2C bus included. Treat the table as two independent readings of a drawing that
agree, which is not the same as a measurement.

| FMC signal | Connector P / N | FPGA P / N | Bank | FMCOMMS2 port |
|---|---|---|---|---|
| LA00 (CC) | G6 / G7 | U26 / U27 | 13 | rx_clk_in (pair) |
| LA01 (CC) | D8 / D9 | AB27 / AC27 | 12 | rx_frame_in (pair) |
| LA02 | H7 / H8 | AK27 / AK28 | 12 | rx_data_in[0] (pair) |
| LA03 | G9 / G10 | AJ28 / AJ29 | 12 | rx_data_in[1] (pair) |
| LA04 | H10 / H11 | AH26 / AH27 | 12 | rx_data_in[2] (pair) |
| LA05 | D11 / D12 | AG26 / AG27 | 12 | rx_data_in[3] (pair) |
| LA06 | C10 / C11 | AJ30 / AK30 | 12 | rx_data_in[4] (pair) |
| LA07 | H13 / H14 | AD30 / AE30 | 12 | rx_data_in[5] (pair) |
| LA08 | G12 / G13 | AF30 / AG30 | 12 | tx_clk_out (pair) |
| LA09 | D14 / D15 | AF29 / AG29 | 12 | tx_frame_out (pair) |
| LA10 | C14 / C15 | AE27 / AF27 | 12 | tx_data_out[3] (pair) |
| LA11 | H16 / H17 | Y28 / AA29 | 12 | tx_data_out[0] (pair) |
| LA12 | G15 / G16 | AC26 / AD26 | 12 | tx_data_out[1] (pair) |
| LA13 | D17 / D18 | AE25 / AF25 | 12 | tx_data_out[2] (pair) |
| LA14 | C18 / C19 | AB29 / AB30 | 12 | tx_data_out[4] (pair) |
| LA15 | H19 / H20 | AA27 / AA28 | 12 | tx_data_out[5] (pair) |
| LA16 | G18 / G19 | Y26 / Y27 | 12 | enable / txnrx |
| LA17 (CC) | D20 / D21 | AE28 / AF28 | 12 |  |
| LA18 (CC) | C22 / C23 | R25 / R26 | 13 |  |
| LA19 | H22 / H23 | W29 / W30 | 13 | gpio_en_agc / gpio_sync |
| LA20 | G21 / G22 | Y30 / AA30 | 12 | gpio_status[0] / gpio_status[1] |
| LA21 | H25 / H26 | V28 / V29 | 13 | gpio_status[2] / gpio_status[3] |
| LA22 | G24 / G25 | V27 / W28 | 13 | gpio_status[4] / gpio_status[5] |
| LA23 | D23 / D24 | W25 / W26 | 13 | gpio_status[6] / gpio_status[7] |
| LA24 | H28 / H29 | T29 / U29 | 13 | gpio_ctl[0] / gpio_ctl[1] |
| LA25 | G27 / G28 | R27 / T27 | 13 | gpio_ctl[2] / gpio_ctl[3] |
| LA26 | D26 / D27 | T30 / U30 | 13 | spi0_csn_0_o / spi0_clk_o |
| LA27 | C26 / C27 | T24 / T25 | 13 | spi0_sdo_o / spi0_sdi_i |
| LA28 | H31 / H32 | N26 / N27 | 13 | gpio_resetb |
| LA29 | G30 / G31 | P23 / P24 | 13 |  |
| LA30 | H34 / H35 | N28 / P28 | 13 |  |
| LA31 | G33 / G34 | P25 / P26 | 13 |  |
| LA32 | H37 / H38 | N29 / P29 | 13 |  |
| LA33 | G36 / G37 | P30 / R30 | 13 |  |

| FMC clock | Connector P / N | FPGA P / N |
|---|---|---|
| CLK0_M2C | H4 / H5 | U25 / V26 (bank 13 SRCC) |
| CLK1_M2C | G2 / G3 | AC28 / AD28 (bank 12 MRCC) |
| GBTCLK0_M2C | D4 / D5 | AD10 / AD9 (MGTREFCLK0_109, AC-coupled) |
| GBTCLK1_M2C | B20 / B21 | AA8 / AA7 (MGTREFCLK0_110, AC-coupled) |

### High-speed lanes

| FMC lane | C2M (FPGA TX) P / N | M2C (FPGA RX) P / N | GTX quad |
|---|---|---|---|
| DP0 | AK10 / AK9 | AH10 / AH9 | 109 ch0 |
| DP1 | AK6 / AK5 | AJ8 / AJ7 | 109 ch1 |
| DP2 | AJ4 / AJ3 | AG8 / AG7 | 109 ch2 |
| DP3 | AK2 / AK1 | AE8 / AE7 | 109 ch3 |
| DP4 | AH2 / AH1 | AH6 / AH5 | 110 ch0 |
| DP5 | AF2 / AF1 | AG4 / AG3 | 110 ch1 |
| DP6 | AE4 / AE3 | AF6 / AF5 | 110 ch2 |
| DP7 | AD2 / AD1 | AD6 / AD5 | 110 ch3 |

---

## 21. 40-pin I/O header

J8 is a 2×20, 2.54 mm header on bank 10 at VCC_ADJ2 (3.3V by default). It carries **17 differential pairs**, routed as pairs, and uses the same power layout as the ALINX 40-pin expansion header.

**All 34 pins are Linux GPIOs.** The PL designs hand them to the
PS as EMIO GPIOs, so Linux owns direction and level per pin with no driver and
no register poking:

```
gpioinfo | grep J8          # J8.4-IO1_P .. J8.35-IO17_N
gpioset gpiochip0 72=1      # drive J8 pin 4 high
gpioget gpiochip0 73        # read J8 pin 3
```

| | Linux gpio |
|---|---|
| `IOk_P` (header pin 2k+2) | 72 + 2(k−1) |
| `IOk_N` (header pin 2k+1) | 73 + 2(k−1) |

`gpio-line-names` in the device tree names every line after its **physical
header pin**, so nobody has to keep the mapping in their head.

Pins come up as **inputs** — `GPIO_T` resets to 1 — which is the safe default
for a header whose other end is unknown. (Before the PL is configured they are
pulled *high*, not floating: PUDC_B is strapped low on this board.)

⚠ `pl/tools/j8test.sh` walks a one through all 34 and reads the pin levels
back through the IOBUFs. It **cannot** catch a consistent permutation, because
the write and the readback take the same path; a wire between two known header
pins is the only thing that settles which physical pin is which.

| Pin | Function |
|---|---|
| 1, 37, 38 | GND |
| 2 | +5V |
| 39, 40 | +3.3V |

| Pin | Signal | FPGA | Pin | Signal | FPGA |
|---|---|---|---|---|---|
| 3 | IO1_N | AK16 | 4 | IO1_P | AJ16 |
| 5 | IO2_N | AG16 | 6 | IO2_P | AG17 |
| 7 | IO3_N | AH16 | 8 | IO3_P | AH17 |
| 9 | IO4_N | AG15 | 10 | IO4_P | AF15 |
| 11 | IO5_N | AK15 | 12 | IO5_P | AJ15 |
| 13 | IO6_N | AG14 | 14 | IO6_P | AF14 |
| 15 | IO7_N | AJ13 | 16 | IO7_P | AJ14 |
| 17 | IO8_N | AH13 | 18 | IO8_P | AH14 |
| 19 | IO9_N | AK12 | 20 | IO9_P | AK13 |
| 21 | IO10_N | AF12 | 22 | IO10_P | AE12 |
| 23 | IO11_N | AH12 | 24 | IO11_P | AG12 |
| 25 | IO12_N | AE15 | 26 | IO12_P | AE16 |
| 27 | IO13_N | AF13 | 28 | IO13_P | AE13 |
| 29 | IO14_N | AD15 | 30 | IO14_P | AD16 |
| 31 | IO15_N | AD13 | 32 | IO15_P | AD14 |
| 33 | IO16_N | AC13 | 34 | IO16_P | AC14 |
| 35 | IO17_N | AC12 | 36 | IO17_P | AB12 |

---

## 22. Where the board data came from

Nothing in this section is the recommended way to use the board;
[`../linux/`](../linux/README.md) and [`../pl/`](../pl/README.md) are. It is
here because provenance matters: some tables in this guide derive from
another board-tested design, and a reader should be able to tell which.

[R0Y00/rk-zynq7100-fmcomms2-linux](https://github.com/R0Y00/rk-zynq7100-fmcomms2-linux)
ports ADI's FMCOMMS2 HDL and Linux IIO stack to this board with Vivado and
PetaLinux 2025.2. What this guide took from it:

| Taken | Status here |
|---|---|
| `ps_reference.tcl`, the PS7 configuration | Not used. The PS7 configuration here is [`../linux/board/ps7_config.tcl`](../linux/board/ps7_config.tcl), applied **and verified setting by setting** by both PL builds; it generates the `ps7_init` that SPL and U-Boot are built from, and boots the board stand-alone from QSPI and eMMC. |
| `system_constr.xdc`, the FMC LA pins | Corroborates the schematic reading. Reproduced in the master XDC. **Still unverified on hardware** -- no FMC card has been fitted. |
| The boot flow | Not used. This board boots from a microSD card that carries SPL, U-Boot, the bitstream, the kernel and the root, or from SPL and U-Boot in QSPI to `extlinux` on the eMMC; either way U-Boot's PREBOOT loads the bitstream ([section 4](#4-boot-configuration-and-reset)). |
| Its address map | Not reused. Both designs here put the PL DDR3 at `0x4000_0000` (M_AXI_GP0); the full design's register file is at `0x8010_0000` and its VDMAs and CSI-2 receiver below that, and the `ddr` design's register file at `0x8000_0000` (both M_AXI_GP1). |

Its own address map, for anyone working with an FMCOMMS2 card:

| Item | Setting |
|---|---|
| AXI AD9361 | `0x79020000` |
| RX DMAC | `0x7c400000`, GIC 89 |
| TX DMAC | `0x7c420000`, GIC 88 |
| AD9361 SPI | PS SPI0 CS0 (EMIO), mode 1 |
| AD9361 reset | Zynq GPIO 100 |
| AD9361 reference clock | 40 MHz (from the FMCOMMS2 card) |

⚠ Do not reuse that map on this repository's designs: `0x7902_0000` and
`0x7c40_0000` are inside the M_AXI_GP0 window, which in both designs here is
the PL DDR3: an FMCOMMS2 driver would read and write memory.

---

## 23. Known issues and design notes

Items 1, 4, 6, 7, 8 and 11 come from reading the schematic; check them on real
hardware before depending on them. Running designs confirm 2 (bank 10 at
`LVCMOS33` against VCC_ADJ2 = 3.3 V), 3 (sheet 16 rendered at 300 dpi, and
`TX_DISABLE` switches an optical module's transmitter), 5 (one `ci_hdrc` controller and one
PHY, used as a host or as a device by swapping the device tree) and 9 (LEDs
light on a 1, keys read 0 when pressed). Items 10, 12, 13 and 14 are measured on
the board or in Vivado.

1. **The FMC HPC connector has no HA/HB signals.** It carries LA00–LA33 and DP0–7 only. Cards that use HA or HB (many dual-ADC cards) will not work fully.
2. **Change IOSTANDARDs with VADJ.** Banks 12/13 follow VCC_ADJ1 and bank 10 follows VCC_ADJ2. Changing RA1 or RA2 requires matching IOSTANDARD changes. LVDS_25 needs VCC_ADJ1 = 2.5V.
3. **The SFP low-speed pins are not connected to the FPGA**, except TX_DISABLE and LOS. MOD-DEF0/1/2 (the module I2C and the presence detect), RS0 and RS1 each sit on a 4.7K pull-up and go nowhere, and TX_FAULT is tied to ground. Module identification, presence detection and rate selection are all impossible. The source is the rendered schematic, not the OCR text; [section 15](#15-sfp-cages) has the resistor designators.
4. **The two Ethernet PHY resets are not under software control** (PHYRSTB is pulled up), and neither is the eMMC's RST_n.
5. **Only one USB connector works at a time.** The USB-A (host) and USB-C (device) connectors share one PHY and one D+/D− pair. Measured: with a working mass-storage device on USB-A, plugging a lead into USB-C **breaks the running port** — the drive drops mid-transfer and the host loops on `device not accepting address ... error -71` / `Cannot enable. Maybe the USB cable is bad?` until one of the two is removed. The message names the cable, which is the wrong suspect.
6. **The PCIe lanes are reversed** (lane 0 = GTX channel 3).
7. **12V from the PCIe slot bypasses the power switch SW2.**
8. **The camera I2C bus is shared with the AT24C256 EEPROM** at 0x50. A camera module with a device at 0x50 will collide.
9. **Keys are active low**, while LEDs are active high.
10. **The ADV7611's interrupt is not connected to anything.** `INT1` (pin 55) is a bare stub, as are the alternate `SCLK/INT2` (49) and `MCLK/INT2` (51); pin 1 is wired but used for `HPA`. `hdmi-receiver@4c` therefore declares no `interrupts`, and stock `adv7604.c` calls `cec_transmit_done()` only from its interrupt service routine -- so CEC frames are sent and acknowledged on the wire while the CEC core is never told, and every transmit times out. This build carries `linux/board/patches/linux/0002-adv7604-poll-the-status-registers-when-no-interrupt-is-wired.patch`, which polls the status registers instead; with it **CEC works in both directions** ([section 18](#18-hdmi-input-adv7611)). A kernel without that patch will show CEC as `message 00 timed out` and `/dev/cec0` permanently `Not Allocated`.
11. **The schematic is a low-resolution OCR scan** (2048×1447 pixels per sheet). Pin numbers come from the images, and every one agrees with Vivado's package data (function name, bank and differential partner). Net names are as drawn. A few `CAM-EE_*` nets are written here as `CAM_EE_*`.
12. **The ADV7611 can stop answering I2C, and only a power cycle clears it.** The symptom is the whole `i2c-hdmi-rx` bus scanning empty -- nothing at 0x4C -- after the chip probed normally at boot. It looks like a wiring or supply fault and is neither: the ADV7511 on `i2c-hdmi-tx` keeps answering, and the receiver's SCL/SDA still read **high at the pad**, which proves its 2K pull-ups to +3.3V_HDMI_A are powered. Read the pad levels back through `emio_pads`' `IOBUF.O` in the PS GPIO `DATA_2_RO` register at `0xE000A068`, and check `HDMI_RX_RST` the same way. **Neither a reset pulse nor a warm `reboot` recovers it** -- a warm reboot does not power-cycle the chip -- and neither does reloading the bitstream. Remove board power and re-apply it; the chip then reports ID 0x2051 again. A brief power cycle with the HDMI cable in does not always clear it; power off for several seconds with the cable out. The trigger is not established.
13. **A GTX reference can reach the fabric through `O` or through `ODIV2`, not both.** An `IBUFDS_GTE2` has one route into the fabric clock network. The gtwizard's CPLL power-up sequencing takes `O` into the fabric through a `BUFH`, so a design that uses the transceivers cannot also count that reference through `ODIV2`: routing fails with unroutable pins on `O`. The full design counts Y8 through SFP1's `TXOUTCLK` instead. The same `BUFH`s must also sit in the transceivers' clock region (`X1Y3` for quad 112) and have to be placed by `LOC` -- `CLOCK_REGION` applies only to global buffers, and on a `BUFH` it is silently a no-op.
14. **A cable plugged into HDMI2 after boot turns the ADV7611's termination off.** The +5V it brings triggers the chip's cable-detect reset (HDMI map 0x48[6] = 0), which returns the TMDS clock termination to its power-on default, off (HDMI map 0x83 = 0xFF); the driver enabled it once, at probe. The transmitter then reports "monitor sense: low" and the receiver "Link has been severed" although the cable detect reads +5V present. `pl/tools/hdmirxtest.sh -c` detects this and writes 0x83 = 0xFE; booting with the cable in avoids it.

---

## 24. Appendix: unassigned PL pins

These PL user I/O pins have no net in the schematic. The DCI resistors (VRN/VRP), the VREF pins and PUDC_B are excluded.

| Bank | Pins with no net |
|---|---|
| 9 | Y20 |
| 10 | AA13, AA14, AA15, AA17, AB14, AB15, AB16, AB17 |
| 12 | AA25, AB25, AC29, AD25, AD29, AE26, AH28, AJ26, AK26, Y25 |
| 13 | P21, R22, R23, R28, T22, T23, U21, U22, U24, V21, V22, V23, V24, W24 |
| 33 | F5, G2 |
| 34 | A10, A7, A9, B10, B6, B7, B9, C6, C7, C8, C9, F10, G10, J8, K12, K7, L12, L9 |
| 35 | K16, L13, L14, L15, M16 |

These GTX reference clock inputs are not connected: AF10/AF9 (109 REFCLK1), AC8/AC7 (110 REFCLK1), W8/W7 (111 REFCLK1).

---

## 25. The PS-PL interfaces

What connects the processing system to the fabric, in each design. Every port
enabled in a design has something on it; an enabled port with nothing driving
it is only a few hundred warnings.

| Interface | Width | full design | `ddr` |
|---|---|---|---|
| `M_AXI_GP0` | 32-bit AXI3 | the 1 GB PL DDR3, through the MIG | the same |
| `M_AXI_GP1` | 32-bit AXI3 | through an AXI-Lite crossbar: the HDMI capture VDMA (`0x8000_0000`), the camera VDMA (`0x8001_0000`), the CSI-2 receiver (`0x8002_0000`) and the register file (`0x8010_0000`) | the register file, directly at `0x8000_0000` |
| `S_AXI_HP0` | **64-bit** AXI3 | the HDMI capture VDMA's frames into PS DRAM | -- |
| `S_AXI_HP1`, `HP2` | **64-bit** AXI3 | the two BIST engines | the two BIST engines |
| `S_AXI_HP3` | **64-bit** AXI3 | the camera VDMA's frames into PS DRAM | -- |
| `IRQ_F2P` | 6 lines / 3 lines | [1:0] the BIST engines on the HP ports, [2] the HDMI capture VDMA, [3] the camera VDMA, [4] the CSI-2 receiver, [5] the BIST engine on the MIG | the three BIST engines |
| EMIO GPIO | 64 bits | fan tachometer, the I2C buses, the ADV7611 reset, the camera connector's two control lines (62, 63), LEDs, keys, the 40-pin header, the SFP control pins, the CSI-2 receiver's video reset (110) | the same less the SFP and camera pins, plus PHY2's MDIO on 62/63 -- which no device tree binds, since PHY2's MDIO belongs to GEM1 in the full design |
| EMIO `ENET1` | GMII + MDIO | **GEM1**, the PL Ethernet port, through a GMII-to-RGMII core | -- |
| EMIO `TTC1` | wave 0 | the fan PWM | the fan PWM |

`ENET1` is enabled only in the full design's own PS configuration, so the
`ddr` design and the PS init the boot runs are unchanged by it. That is also
why the boot does not route GEM1's clocks from EMIO, and `S15fpga` does
([section 11](#11-ethernet)).

### The high-performance ports

`S_AXI_HP0`--`HP3` are 64 bits wide with a 6-bit ID, and are the only way
for the PL to reach PS DRAM at speed. Measured with the BIST engines in
[the PL design](hh-rk-zynq7100-design.md):

| | |
|---|---|
| Each port, separately | **798 MB/s**, 0 errors |
| Theoretical | 800 MB/s — 64 bits at 100 MHz |

⚠ **The HP ports are NOT coherent with the CPU's caches.** Anything the CPU
exchanges with a fabric master through them must be mapped uncached, or the two
will disagree and the memory will get the blame. The device tree reserves the
top 16 MB of PS DRAM with `no-map`, which keeps the kernel out *and* makes
`/dev/mem` hand the region back uncached.

⚠ A fabric master has no MMU and no bounds check. Whatever address it is
given is what it writes, at 64 bits a clock.

### The fabric interrupt

`IRQ_F2P[7:0]` map to GIC IDs 61–68 and `[15:8]` to 84–91. A device tree
numbers shared peripheral interrupts from 32, so `IRQ_F2P[0]` is `<0 29 4>`.

| `IRQ_F2P` | GIC | Device tree |
|---|---|---|
| 0 | 61 | `interrupts = <0 29 4>` |
| 1 | 62 | `<0 30 4>` |
| 2 | 63 | `<0 31 4>` |
| 3 | 64 | `<0 32 4>` |
| 4 | 65 | `<0 33 4>` |
| 5 | 66 | `<0 34 4>` |

The `ddr` design configures three lines and the full design six, in its own PS
configuration overrides; lines 3 and 4 are the camera's.
Verified on the hardware: lines 0 and 1 appear in `/proc/interrupts` as
`pl-bist` and wake a blocked reader on `/dev/uio` (`pl/tools/bisttest.sh`).
The device tree's nodes carry the full design's numbers: under the `ddr`
design its third engine interrupts on line 2 (GIC 63, SPI 31), which no
device tree binds.

⚠ `uio_pdrv_genirq.of_id=generic-uio` must be on the kernel command line. That
driver's device-tree match table is declared empty and filled from a module
parameter, so `compatible = "generic-uio"` binds to nothing without it — with
no `/dev/uio*` and nothing in dmesg to say why.

### What is unused

`S_AXI_GP0` and `GP1`, and `S_AXI_ACP` -- the last being the only
*coherent* path into PS memory, and the one to reach for if a fabric master
ever needs to share data with the CPU without uncached mappings. EMIO SPI0 is
enabled by the shared PS configuration and drives nothing. `FCLK_CLK1` is
generated at 200 MHz and connected to nothing; the 200 MHz the designs use
comes from the Y7 oscillator.

---

*Schematic sheets referenced in this guide* (the PDF itself is not in the
repository): 18 HDMI out (ADV7511), 19 HDMI in (ADV7611), 13 Ethernet,
14 USB, 16 SFP+/SATA, 20 LEDs/keys/fan/camera, 21-23 FMC, 11 SD/camera I2C.
Sheet 1 is the block diagram. Pages render legibly at 300 dpi or better; the
OCR text layer does not, and should not be quoted.

*Sources:*
- *The vendor schematic `z7100-schematic_ocr.pdf` (24 sheets).*
- *The Vivado 2026.1 package data for `xc7z100ffg900-2`.*
- *[R0Y00/rk-zynq7100-fmcomms2-linux](https://github.com/R0Y00/rk-zynq7100-fmcomms2-linux) (commit 461efa3): `system_constr.xdc`, `ps_reference.tcl` and the documentation.*

# RK-ZYNQ7100 Linux guide

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

See the [README](../linux/README.md) for orientation. Commands use repository-root
paths unless a procedure explicitly changes directory.

**Contents**

- [Two boot traps](#two-boot-traps)
- [Why Buildroot, not PetaLinux](#why-buildroot-not-petalinux)
- [Versions](#versions)
- [Files](#files)
- [Build](#build)
- [Boot from an SD card](#boot-from-an-sd-card)
- [Boot over the network: JTAG, then TFTP](#boot-over-the-network-jtag-then-tftp)
- [Boot from QSPI and eMMC](#boot-from-qspi-and-emmc)
- [Installing to eMMC and QSPI](#installing-to-emmc-and-qspi)
- [Peripheral support](#peripheral-support)
- [U-Boot in QSPI is a legacy image, not a FIT](#u-boot-in-qspi-is-a-legacy-image-not-a-fit)
- [The USB PHY reset on MIO7](#the-usb-phy-reset-on-mio7)
- [USB device mode](#usb-device-mode)
- [I2C](#i2c)
- [The 40-pin header](#the-40-pin-header)
- [The BIST engines](#the-bist-engines)
- [LEDs and keys](#leds-and-keys)
- [The MAC address](#the-mac-address)
- [The Ethernet PHYs, and selecting 10/100/1000](#the-ethernet-phys-and-selecting-101001000)
- [The camera](#the-camera)
- [Die temperature and the fan](#die-temperature-and-the-fan)
- [Regenerating the PS init](#regenerating-the-ps-init)
- [Bring-up order](#bring-up-order)

A from-source U-Boot and Linux for the RK-ZYNQ7100 (XC7Z100-2FFG900), built with Buildroot. It boots three ways:

1. **From a microSD card**. Write `sdcard.img` to a card, set SW1 to SD and power up: SPL, U-Boot, the bitstream, the kernel and the root filesystem all come from the card. See "Boot from an SD card". ⚠ With SW1 at SD this has not yet been run. With SW1 at QSPI and a card in the slot, U-Boot's distro boot finds the card's `extlinux` first and boots the card's kernel, root (`root=/dev/mmcblk0p2`) and bitstream, and that has.
2. **From the board's own flash**: SPL and U-Boot in QSPI, the root on the eMMC, and nothing attached. See "Installing to eMMC and QSPI".
3. **Over the network**, the development loop. JTAG-load U-Boot and it TFTP-boots Linux on its own, so a new kernel or root filesystem runs without writing any flash. See "Boot over the network: JTAG, then TFTP".

**Status: runs on the board.** It boots from QSPI and eMMC with nothing attached, and a JTAG-loaded U-Boot TFTP-boots Linux to a login prompt with no typing. The SD card image: the card's kernel, root and bitstream have booted (U-Boot from QSPI finds the card's `extlinux` first), but the SW1 = SD path, SPL and U-Boot from the card itself, has not been run. Measured:

| | Result |
|---|---|
| DDR | `bootuboot: DDR ok`, U-Boot reports `DRAM: 1 GiB`, relocates to the top of it (`0x3fexxxxx`..`0x3ffxxxxx`; the exact address moves with the build) |
| Console | UART0 on the FT2232HQ's channel B, 115200 8N1; JTAG is its channel A. Both on the one USB-C port. |
| Ethernet, U-Boot | DHCP, then TFTP at **4.3 MiB/s** |
| LEDs and keys | ✅ LED1–4 as `/sys/class/leds` (LED1 on the heartbeat trigger) and KEY1–4 as an input device via `gpio-keys`, both over EMIO GPIO. LED8 stays in the fabric as the PL's own heartbeat. |
| 40-pin header J8 | ✅ All 34 pins as Linux GPIOs (72–105) with `gpio-line-names` naming each by its physical header pin. Walking-ones test passes; `pl/tools/j8test.sh`. |
| PL → PS DRAM (`S_AXI_HP`) | ✅ Two AXI masters in the fabric at **798 MB/s** each, 0 errors, cross-verified between ports. |
| Fabric interrupt (`IRQ_F2P`) | ✅ Six lines. GIC 61, 62 and 66 are the three BIST engines, shown as `pl-bist`; 61 and 62 are verified to wake a blocked `/dev/uio` reader (`bisttest.sh` tests those two). GIC 63 and 64 are the HDMI and camera VDMAs', handled by `xilinx_dma`, and 65 the CSI-2 receiver's. |
| Oscillators | ✅ All four clocks the fabric has no other use for, counted from Linux: 50.000 MHz, 78.125 MHz (the GTX ref ÷2, through SFP1's user clock at the reset rate), 75.000 MHz (SATA ref ÷2), 200.001 MHz. |
| PL DDR3 from the fabric | ✅ **392 MB/s** through the MIG, 0 errors over 16 MB, with the CPU-altered-word test confirming the engine and the CPU address the same memory. `pl/tools/bisttest.sh -b 0x80000000` with the `ddr` design. |
| HDMI output | ◐ Pixel clock, CEA timing and a test pattern in the fabric; with HDMI1 looped to HDMI2 the ADV7511 sees a real HPD and the ADV7611 at the far end reports TMDS detected and locked (`pl/tools/hdmitest.sh`; `-f` forces HPD with no cable). **No monitor has shown a picture yet.** Audio is impossible on this board. |
| HDMI input | ✅ **`/dev/video0`**, from `adv7604` + `xilinx_dma` + `xilinx-vipp`, all mainline and all already built in. With HDMI1 looped to HDMI2 it captures 1280x720p60 at `BGR3`; ten frames are exactly 27,648,000 bytes every color bar and the border on the exact pixel, and a static row byte-identical between frames. Boot `zynq-rkz7100-hdmirx.dtb`, give the receiver an EDID (`v4l2-ctl -d /dev/v4l-subdev0 --set-edid=type=hdmi`, or it holds HPD low and the transmitter powers down), and run `pl/tools/hdmirxtest.sh -c`. Needs the `0001-xilinx-vip-...` patch in `board/patches/linux/`. |
| Camera (J9) | ✅ **`/dev/video1`**: an OV5647 through `ov5647` + `xilinx-csi2rxss` + `xilinx-vipp`, RAW10 in all four sensor modes up to 2592x1944, whole frames, exact color bars and no damaged packet; streams restart. `pl/tools/camtest.sh`. See "The camera". |
| USB host (USB-A) | ✅ `Found SMSC USB3320 ULPI transceiver`, `ULPI integrity check: passed`, `EHCI Host Controller`, `USB 2.0 started`. A Verbatim STORE N GO enumerates as `/dev/sda`, 14.4 GB FAT32. 64 MB written and read back with a matching md5 after dropping caches: **6.8 MB/s written** (with `conv=fsync`; without it dd reports the page cache, not the stick) and **22.8 MB/s read**; a second run gave 5.8 and 21.9. The `-110` a PHY without its reset pulse gives is covered under "The USB PHY reset on MIO7". |
| PL Ethernet (RJ2) | ✅ **`eth1`**: GEM1 over EMIO, through a GMII-to-RGMII core in the full bitstream, to PHY2. DHCP and ping at 1000, 100 and 10 Mb/s; `iperf3` **666–674 Mbit/s** in and **562–807 Mbit/s** out, and a 60 s, 4.8 GB receive run with no receive error. `pl/tools/eth2test.sh`. See "The Ethernet PHYs". |
| MAC address | ✅ `eth0` and `eth1` read their addresses from the EEPROM (0x20 and 0x26), written once by hand; see "The MAC address". U-Boot's PREBOOT reads eth0's; Linux reads eth1's through nvmem. |
| Ethernet, Linux | `RTL8211F Gigabit Ethernet` driver, **1000 Mb/s full**, DHCP, ping 0% loss. `iperf3`: **670–673 Mbit/s** into the board, **612–770 Mbit/s** out, no board-side error counters; from a client behind WSL2's NAT, 582–642 in and 692–808 out over three runs each. The client end sets as much of the figure as the board. |
| microSD | 29.2 GiB SDHC detected (`mmcblk0`). Raw read 15.5 MB/s. A 32 MiB file written with fsync at 14.5 MB/s read back with the same MD5 after a cache drop and remount, and `fsck.fat` was clean. |
| eMMC | `mmcblk1`, 8GTF4R, 7.28 GiB, high-speed MMC. ✅ Carries the root filesystem: 7.1 GiB ext4, read-write, `root=/dev/mmcblk1p1`. |
| QSPI | `w25q256 (65536 Kbytes)`, 3 MTD partitions. `failed to read ear reg` is the harmless warning the FMCOMMS2 port also reports. ✅ Holds SPL at 0 and U-Boot at `0x100000`; the board boots from it with no host attached, and Linux rewrites it in place with `flashcp` — see "Reflashing from Linux". |
| I2C | ✅ Three bit-banged buses on PL pins via `i2c-gpio` over EMIO, and all three devices answer: the ADV7511 at 0x39, the ADV7611 at 0x4C (revision 0x2051) and the AT24C256 at 0x50. |
| HDMI CEC | ✅ Works both ways over the HDMI1→HDMI2 loopback; `pl/tools/cectest.sh` exercises it. Needs **two** things: `CONFIG_VIDEO_ADV7604_CEC=y`, and the `0002-adv7604-poll-...` patch, because this board leaves the ADV7611's `INT1` unconnected and stock `adv7604.c` calls `cec_transmit_done()` only from its ISR — without it every frame goes out, is acknowledged, and still times out in software. The boot log confirms the patch: `no interrupt wired, polling status every 20 ms`. Only the receiver is a Linux CEC device; the ADV7511 is set up over I2C by hand and forgets it on every power cycle. |
| SFP+ transceivers | ✅ 3.125, 6.25 and 10.3125 Gb/s both ways through a passive DAC between the cages, 0 errors at each (BER < 1.9 × 10⁻¹¹ at 10.3125). No driver: the PRBS exerciser in the PL is register block 3 of the full design, and `pl/tools/gtxtest.sh -r all` drives it with `devmem`. Needs the full bitstream with the multi-rate exerciser (`0x80100100` reads `0x47580003`). |
| Ethernet PHYs | ✅ Both select 10/100/1000 with `ethtool`, measured at all three with traffic. On `eth1` the change also reaches the GMII-to-RGMII core, through `xilinx_gmii2rgmii`. |
| Die temperature | ✅ The PS XADC interface comes up on its own as an IIO device; `iio-hwmon` puts its temperature and six supply rails under hwmon, where `sensors` reads them. **46.5 °C** idle with no bitstream, **38.4 °C** with the fan running. The rails read back exactly what the power table says: 1.00, 1.78, 1.01, 1.00, 1.78 and 1.50 V. |
| Fan | ✅ `pwm1` under hwmon sets the speed, `fan1_input` reads it back in rpm, and a thermal zone on the XADC drives it from the die temperature with no daemon. Under both CPUs spinning for a minute the die went 40.6 → 41.8 °C and the fan 1068 → 1077 rpm: the loop reads and acts, and the board is nowhere near its trip points on CPU load alone. Both fan pins belong to the PL, so U-Boot's PREBOOT loads a bitstream before Linux starts (`board/S15fpga`, if it did not) to make any of it reach the fan. See "Die temperature and the fan". |
| USB (device, USB-C) | ✅ **Enumerated by a host.** With a lead to a PC and an ACM gadget bound through configfs, `/sys/class/udc/ci_hdrc.0/state` reads **`configured`** at **high-speed**, and the host sees `VID_1D6B PID_0104` serial `0001` as a composite device plus a USB serial port. Data crosses **both ways**: a string written to `/dev/ttyGS0` arrives at the host, and one written by the host arrives on the board. See "USB device mode". |

**Build outputs** (checked after the build): `sdcard.img`, `boot.bin`, `u-boot.img`, `rootfs.ext4`, `u-boot.bin`, `rkz7100-boot.scr`, `uImage`, `rootfs.cpio.uboot` and all three DTBs (default, `-usbdev`, `-hdmirx`). Every defconfig and fragment line reached its `.config`, which `build.sh` enforces.

## Two boot traps

**1. The pre-relocation heap is 2 KiB.** U-Boot proper's pre-relocation heap (`SYS_MALLOC_F_LEN` = 0x800), gd and stack share 8 KiB of OCM, and every `bootph-all` node binds before relocation. With the QSPI, flash and SD nodes among them, the UART's `clk_get_by_index()` returns **`-ENOMEM`**, `serial_init()` panics, and `panic()` resets the chip: no console output, the PC back in the BootROM at `0xffffff28`, and `REBOOT_STATUS` showing `SLC_RST`. So only the clock controller and UART are `bootph-all`, and the boot media are `bootph-pre-ram` (SPL only); see `board/zynq-rkz7100-uboot.dts`.
- ⚠ A larger `SYS_MALLOC_F_LEN` does not help: 64 KiB overruns the 8 KiB and data-aborts (PC at the abort vector, `0x04000010`).

**2. Outside JTAG boot mode the BootROM leaves the CPU in Thumb state.** With SW1 on SD (`BOOT_MODE` = 5) and no bootable card, the BootROM parks the CPU with **`CPSR = 0x200001DF`, Thumb bit set**. U-Boot's ARM code would then run as Thumb and do nothing, so `tools/bootuboot.tcl` sets CPSR to ARM state and SVC mode (`0x1d3`) before it starts U-Boot.

## Why Buildroot, not PetaLinux

[rk-zynq7100-fmcomms2-linux](https://github.com/R0Y00/rk-zynq7100-fmcomms2-linux), the one Linux port proven on this board, uses **PetaLinux 2025.2** with ADI's kernel (6.12) and U-Boot 2025.01. This build deliberately does not:

| | This build | rk-zynq7100-fmcomms2-linux |
|---|---|---|
| Distribution | Buildroot 2025.02.6, everything from source | PetaLinux 2025.2 (Yocto) + meta-adi |
| Kernel | Xilinx linux-xlnx 6.6.70 LTS | ADI linux 6.12 |
| First-stage boot | U-Boot SPL + `ps7_init_gpl.c` generated by Vivado | Vitis FSBL |
| U-Boot | Xilinx u-boot-xlnx 2024.01 | 2025.01 |
| Needs | A Linux host (WSL on Windows), plus Vivado only to regenerate the PS init | Vivado, Vitis and PetaLinux 2025.2 installs, Ubuntu 22.04 |
| JTAG/TFTP loop | `tools/bootuboot.tcl` → U-Boot → TFTP, automatic | XSDB data loader, then U-Boot commands |

Reasons for the choice:
- **Everything from source in one command.** `build.sh` fetches Buildroot and builds the toolchain, U-Boot, the kernel and the root filesystem.
- **Nothing proprietary to install.**
- **The ADI kernel only matters for the AD9361.** For a general-purpose Linux on the board, the Xilinx kernel is the better-supported base.

What **is** taken from that repository is everything board-specific it proved on hardware:
- **The PS7 configuration**, verbatim apart from TTC1 for the fan, in `board/ps7_config.tcl`: DDR part and timing, the MIO map, and clocks.
- **The device-tree choices** for 1 GiB, dual-parallel QSPI, eMMC on SD1 and ULPI USB.

For the FMCOMMS2 SDR stack, use that repository as it is.

## Versions

| Component | Version |
|---|---|
| Buildroot | 2025.02.6 |
| Linux | `Xilinx/linux-xlnx` tag `xlnx_rebase_v6.6_LTS_merge_6.6.70` |
| U-Boot | `Xilinx/u-boot-xlnx` tag `xlnx_rebase_v2024.01_2024.2` |
| Kernel defconfig | `xilinx_zynq` + `board/linux-rkz7100.fragment` |
| U-Boot defconfig | `xilinx_zynq_virt` + `board/uboot-rkz7100.fragment` |

## Files

| File | What it is |
|---|---|
| `build.sh` | The build. Run it on a Linux host (WSL on Windows). |
| `stage-tftp.sh` | Copies the images into a TFTP root. |
| `tools/bootuboot.tcl` | JTAG-loads U-Boot (XSDB), after checking the DDR. |
| `gen_ps7.tcl` | Regenerates the PS init from `board/ps7_config.tcl` (Vivado). |
| `configs/rkz7100_defconfig` | Buildroot configuration |
| `board/ps7_config.tcl` | The PS7 settings, from the FMCOMMS2 port's tested design |
| `board/ps7_init_gpl.[ch]` | Generated PS init. U-Boot SPL compiles it. |
| `<pl build dir>/ps7_init.tcl` | Locally generated XSDB initialization; not a tracked source file. |
| `board/zynq-rkz7100.dts` | Kernel device tree: USB0 host on USB-A |
| `board/zynq-rkz7100-usbdev.dts` | The same, with USB0 as a device on USB-C |
| `board/zynq-rkz7100-hdmirx.dts` | The default tree plus the HDMI-input and camera capture pipelines (needs the full bitstream) |
| `board/zynq-rkz7100-uboot.dts` | U-Boot's device tree |
| `board/*.fragment` | Kernel and U-Boot config additions |
| `board/rkz7100-boot.cmd` | The TFTP boot script (compiled to `rkz7100-boot.scr`) |
| `board/post-image.sh`, `genimage.cfg`, `extlinux.conf` | SD card image assembly |
| `board/post-build.sh` | Writes `/boot/extlinux/extlinux.conf` and installs `S15fpga` and the sensors labels |
| `board/S15fpga` | Init script: loads `/lib/firmware/rkz7100.bin` if U-Boot did not, and routes GEM1's clocks from EMIO |
| `board/sensors-rkz7100.conf` | lm-sensors labels for the XADC rails |
| `board/patches/linux/` | Kernel patches: the Xilinx VIP RGB888 format, adv7604 status polling |

## Build

```sh
# On a Linux host. Under WSL, the build itself goes in the Linux filesystem,
# not /mnt/c; build.sh refuses otherwise.
RKZ7100_BITSTREAM=<pl build dir>/rkz7100_pl.bit linux/build.sh
```

- **`RKZ7100_BITSTREAM`** puts a PL bitstream on the SD card image, where U-Boot loads it before Linux starts. A `.bit` is converted with `pl/bit2bin.py`. Leave it out and the card boots with the PL unconfigured.
- **`RKZ7100_PS7_INIT`** selects a locally generated `ps7_init.tcl` for JTAG boot. By default, `build.sh` finds it beside `RKZ7100_BITSTREAM`, where the PL build publishes it. An explicit missing/empty file is an error. Without an implicit artifact, Linux/SPL still builds, but the images cannot be staged for JTAG boot until initialization is supplied. The selected Tcl is copied into `output/images/`; a build selecting none removes a stale copy there. See [PS init generation](#regenerating-the-ps-init).
- **`TFTP_SERVER`** matters only for the network boot: the TFTP server's address as the board sees it, a dotted IPv4 address (`build.sh` refuses a hostname), compiled into U-Boot's `bootcmd`. Without it, U-Boot fetches from the TFTP server the DHCP lease names (the `next-server` of most DHCP servers). `TFTP_PORT` sets the port when something else owns UDP 69.
- **Output** goes to `~/rkz7100-linux/buildroot/output/images/`; `RKZ7100_WORK` moves the whole build.
- **Downloads** go to `~/rkz7100-linux/dl`. Point `BR2_DL_DIR` at an existing Buildroot download cache to reuse its tarballs.
- **`BUILDROOT_VERSION`** (default `2025.02.6`) is the tag cloned, and **`JOBS`** (default `nproc`) the parallel make jobs.

After the build, `build.sh` checks these instead of trusting the configuration:
1. U-Boot's `.config` points `XILINX_PS_INIT_FILE` at our `ps7_init_gpl.c`.
2. SPL actually compiled it (`spl/board/xilinx/zynq/ps_init_gpl.o` exists; that object is only built when the setting is honored).
3. The `bootcmd` carries the requested TFTP server, or none.
4. The U-Boot device tree is newer than its DTS (a failed DTS compile leaves the old one in place).
5. Every defconfig and fragment line reached its `.config`.
6. `sbin/resize2fs` is in the rootfs.

Editing anything in `board/` and re-running `build.sh` rebuilds the kernel and U-Boot. Buildroot cannot see changes outside its tree, so the script drops their build stamps itself.

## Boot from an SD card

1. Write `sdcard.img` to a microSD card. This replaces everything on the card.
   ```sh
   sudo dd if=sdcard.img of=/dev/sdX bs=4M conv=fsync
   ```
   On Windows, balenaEtcher or Win32 Disk Imager does the same.
2. Set the boot-mode switch **SW1 to SD: both switches OFF**. There are no
   jumpers.
3. Open the console: the FT2232HQ's USB-C port carries JTAG on its first
   channel and UART0 on its second, so UART0 is the second of the two serial
   ports it adds. 115200 8N1, any terminal program.
4. Power up.

It ends at a `rkz7100 login:` prompt (`root`, no password), with DHCP on
`eth0`. U-Boot does not try the network on an SD boot; it goes straight to
distro boot, which finds `extlinux.conf` on the card.

| Partition | Holds |
|---|---|
| 1, FAT | `boot.bin` (SPL), `u-boot.img`, `uImage`, `system.dtb`, `extlinux/extlinux.conf`, and `rkz7100.bin` when the build was given a bitstream |
| 2, ext4 | the root filesystem, mounted as `/` from `root=/dev/mmcblk0p2` |

- **The bitstream.** U-Boot's PREBOOT loads `rkz7100.bin` from partition 1
  before the boot command runs, so the fan, the I2C buses and the PL Ethernet port
  exist by the time Linux probes them, and `eth0` gets its MAC address from the
  EEPROM (see "The MAC address"). To run a different design, replace that file;
  `pl/bit2bin.py` makes one from a `.bit`. A card with no `rkz7100.bin` still
  boots, with the PL unconfigured and the fan held off until something loads a
  design (see "Die temperature and the fan").
- **Other device trees.** The card boots `system.dtb`, which is
  `zynq-rkz7100.dtb`. The other two are in `/boot` on partition 2; copy one
  over `system.dtb` on partition 1 to boot it. `zynq-rkz7100-hdmirx.dtb` needs
  the full bitstream, because probing it reads PL registers.
- ⚠ **`saveenv` writes `uboot.env` to partition 1, and from then on it
  replaces the compiled-in environment entirely**, PREBOOT included. Delete the
  file to go back.
- **`reboot` works**: the BootROM runs the card again.

## Boot over the network: JTAG, then TFTP

**0. Board setup.**
- Set the boot-mode DIP switch **SW1** to **JTAG: both switches ON**. There are no jumpers.
  - SW1-1 (pins 1–4) grounds MIO4, and SW1-2 (pins 2–3) grounds MIO5. Each line otherwise has a 4.7K pull-up to 3.3V and a 20K series resistor.
  - Both ON = JTAG, SW1-1 ON only = QSPI, both OFF = SD.
  - Check the current mode with `mrd 0xF800025C` in XSDB: 0 = JTAG, 1 = QSPI, 5 = SD.
- Connect the JTAG USB-C port (FT2232HQ) and Ethernet, and power up. With JTAG boot selected the console stays silent. That is expected: the BootROM has nothing to run.

**1. Stage the TFTP root:**

```sh
linux/stage-tftp.sh <tftproot>        # IMAGES=<dir> to stage from another images directory
```

**2. Serve it.** The workspace uses the Rust
[hh-tftpd](https://github.com/s100box/hh-tftpd/blob/main/README.md).
It has no crate dependencies and supports `blksize` negotiation. That sibling
is optional: another TFTP server with block-size support, such as tftpd-hpa or
dnsmasq, can serve the same staged files.

From this repository's root, in a separate terminal, build and run the server:

```sh
cargo run --release --manifest-path ../hh-tftpd/Cargo.toml -- \
  --root <tftproot> --port 6969
```

This needs stable Rust. The example uses 6969 so it can coexist with a server
already serving other rigs on UDP 69; build U-Boot with `TFTP_PORT=6969` too.
Omit `--port` to use the default 69 when that port is available. The root must
exist and contain the files staged in step 1. Transfers are read-only unless
an upload directory is explicitly enabled. An existing shared instance can
also use `--client <board-ip>=<tftproot>` to select a root per board; preserve
its existing mappings when configuring it. The
[server design](https://github.com/s100box/hh-tftpd/blob/main/doc/hh-tftpd-design.md) documents the host tool.

**When something else owns UDP 69** on the TFTP server, build with `TFTP_PORT=6969` and serve on that port instead. U-Boot is built with `CONFIG_TFTP_PORT`, and the `bootcmd` sets `tftpdstp`.

On Windows, allow the selected UDP port on the private network as Administrator
if the firewall blocks it (the board otherwise prints `T T T`):

```powershell
$TftpPort = 6969  # use 69 if the server and U-Boot use the default port
New-NetFirewallRule -DisplayName "TFTP server (board bring-up)" -Direction Inbound -Protocol UDP -LocalPort $TftpPort -Action Allow -Profile Private
```

**3. Open the console** as for an SD boot: the FT2232HQ's second serial port (channel B = UART0), 115200 8N1.

**4. JTAG-boot U-Boot** from the repository root, with XSDB from Vivado:

```sh
xsdb linux/tools/bootuboot.tcl <tftproot>/ps7_init.tcl <tftproot>/u-boot.bin [jtag-cable-serial]
```

- **The cable serial is needed whenever more than one Zynq is on the chain.** Without it, the script refuses and lists what it found. `JTAG_CABLE_SERIAL` in the environment does the same.
- It checks DDR before loading anything (`bootuboot: DDR ok`), then prints the PC. On this 1 GiB board a healthy U-Boot relocates to around **`0x3ffxxxxx`**. A PC still at `0x040xxxxx` means U-Boot never got past `board_init_f`.

**5. Watch it boot.** U-Boot counts down 3 s, then:

```
setenv autoload no; setenv tftpdstp <TFTP_PORT>; dhcp
[setenv serverip <TFTP_SERVER>, only when the build named one]
tftpboot 0x3000000 rkz7100-boot.scr; source 0x3000000
  → tftpboot ${rkz7100_dtb} (default zynq-rkz7100.dtb), uImage, rootfs.cpio.uboot → bootm
```

This ends at a `rkz7100 login:` prompt (`root`, no password), with DHCP on `eth0`.

**By hand**, press a key during the countdown and type:

```
setenv autoload no
dhcp
setenv serverip <tftp-server>
tftpboot 0x3000000 rkz7100-boot.scr
source 0x3000000
```

- To use USB0 as a **device** on USB-C instead of a host on USB-A, run `setenv rkz7100_dtb zynq-rkz7100-usbdev.dtb` before the `source`.
- ⚠ Run `dhcp` **before** `setenv serverip`: the lease overwrites `serverip` with the DHCP server's idea.
- U-Boot reads the MAC address out of the EEPROM once one has been written there, so the DHCP lease is stable from boot to boot. See "The MAC address" below.

**`reboot` in Linux does not come back.** With SW1 on JTAG the BootROM has nothing to run after a reset. Run `tools/bootuboot.tcl` again: that is the whole loop.

## Boot from QSPI and eMMC

- **Installed and booted:** the board boots with no
  host at all — `BootROM → SPL (QSPI) → U-Boot (QSPI) → distro_bootcmd →
  extlinux on the eMMC → Linux → login`. See "Installing to eMMC and QSPI"
  below, and "U-Boot in QSPI is a legacy image" for the QSPI boot trap.

  Two lines in that boot log look like faults and are not. U-Boot prints
  `*** Warning - bad CRC, using default environment` because no environment
  is saved in the flash -- the compiled-in default is what this board runs. Then `distro_bootcmd` tries a
  boot script at `0xfc0000` in the flash before it gets to the eMMC, finds the
  factory's leftover, and prints `Wrong image format for "source" command`
  followed by `QSPI: SCRIPT FAILED: continuing...` for the QSPI and JTAG
  entries in turn. Both are the fallback chain working as intended.

## Installing to eMMC and QSPI

The result: the board powers up into Linux on its own, root read-write on the
eMMC, nothing on the network required. Done once from a JTAG-booted U-Boot;
every command below was run on the hardware.

**Back up the factory contents first.** They are not published anywhere, and
the flash arrives with a vendor image. `sf read` + `tftpput` for the QSPI,
`mmc read` + `tftpput` for the eMMC's first 16 MiB, and a `tar` of the factory
rootfs from a TFTP-booted Linux. Verify each one (`crc32` in U-Boot against
a copy on another machine) before writing anything.

```
# eMMC: the ext4 root goes at the start of partition 1 (block 0x10).
tftpboot 0x10000000 rootfs.ext4
mmc dev 1
mmc write 0x10000000 0x10 0x100000
mmc read  0x10000000 0x10 0x100000     # read it back and
crc32 0x10000000 0x20000000            # compare with the crc32 before the write

# QSPI: SPL at 0, U-Boot at 0x100000 (CONFIG_SYS_SPI_U_BOOT_OFFS).
sf probe
tftpboot 0x10000000 boot.bin
sf erase 0 0x40000
sf write 0x10000000 0 ${filesize}
sf read 0x11000000 0 ${filesize}
cmp.b 0x10000000 0x11000000 ${filesize}
tftpboot 0x10000000 u-boot.img
sf erase 0x100000 0x180000
sf write 0x10000000 0x100000 ${filesize}
sf read 0x11000000 0x100000 ${filesize}
cmp.b 0x10000000 0x11000000 ${filesize}
sf erase 0xE00000 0x20000              # drop the factory environment
sf erase 0xE40000 0x20000
```

Then set **SW1 to QSPI** (SW1-1 ON, SW1-2 OFF) and power-cycle.

**Refreshing the root later, from Linux.** Once the board can TFTP-boot a
ramdisk, the eMMC root can be replaced without U-Boot at all — and without a
512 MiB detour through `/tmp`, which is a 502 MiB tmpfs and would not hold it.
busybox `tftp` writes to whatever local path it is given, including a block
device:

```
tftp -b 1468 -g -r rootfs.ext4 -l /dev/mmcblk1p1 <tftp-server>
e2fsck -f -p /dev/mmcblk1p1
resize2fs /dev/mmcblk1p1
```

**Measured:** 512 MiB written, checked and grown to 7.28 GiB
(1,908,734 4k blocks). `-b 1468` took **2m57s (3.0 MB/s)**; the same transfer
without it took **5m00s (1.8 MB/s)**, because busybox `tftp` otherwise uses
512-byte blocks and half a gigabyte becomes a million round trips. Neither is
near what the link can do — this is latency, not bandwidth — but the flag is
free.

⚠ Rewriting the root removes anything that was only ever put there by hand:
`/boot/rkz7100.bin` (which U-Boot's PREBOOT loads), `/lib/firmware/rkz7100.bin`
and any locally-patched `/etc/init.d/S15fpga` have
to go back afterward, and the version of every board file is whatever the
**build** had, not whatever the working tree has. Rebuild before you write.

The image carries `/boot` with it — `uImage`, the three DTBs and the
`extlinux.conf` that `board/post-build.sh` writes — so this installs the
kernel as well as the root.

`rootfs.ext4` is 512 MiB but the eMMC partition is 7.28 GiB, so grow the
filesystem once, as above (`e2fsck` then `resize2fs`, which gives 7.1 GiB
with 6.7 G free). Do it from the TFTP ramdisk, where the eMMC is not mounted.

### What makes a local boot work

- `BR2_LINUX_KERNEL_INSTALL_TARGET=y` puts `uImage` and the DTBs in the
  rootfs `/boot`, and `board/post-build.sh` writes
  `/boot/extlinux/extlinux.conf` beside them with `root=/dev/mmcblk1p1`.
  U-Boot's distro boot scans `mmc0` (SD) then `mmc1` (eMMC) and runs the first
  `extlinux.conf` it finds. Two more labels, `linux-usbdev` and
  `linux-hdmirx`, boot the same kernel with the USB-device and capture DTBs.
- `CONFIG_BOOTCOMMAND` only netboots when `${modeboot}` is `jtagboot`. A board
  that booted from QSPI or SD has its own kernel and should not sit through a
  TFTP timeout first.

### Three traps

- **`resize2fs` is not part of Buildroot's `e2fsprogs` by default.**
  `BR2_PACKAGE_E2FSPROGS_RESIZE2FS=y` is a separate symbol, and Buildroot does
  *not* rebuild a package when only a sub-option changes — turning it on after
  e2fsprogs is built leaves the old install in place, silently. `make e2fsprogs-dirclean` and rebuild.
  `build.sh` fails if `sbin/resize2fs` is missing. (It installs to `/sbin`,
  not `/usr/sbin`: `E2FSPROGS_CONF_OPTS` sets `--sbindir=/sbin`.)
- **Do not add the root device to `/etc/fstab`.** The same rootfs is also
  packed into the TFTP cpio, and `mount -a` runs there too: an auto entry for
  `/dev/mmcblk1p1` on `/` makes a *ramdisk* boot mount the eMMC over its own
  root, so every later file read comes from the eMMC. The kernel mounts
  root from `root=` and `rw` on the command line; nothing else is needed.
  `post-build.sh` also deletes any such line, because `output/target` is
  never wiped.
- **Check which directory the TFTP server is actually serving.** If the
  images are staged to one directory and `tftpd`'s `--root` points at another,
  the board keeps fetching the previous build and looks as if it ignores every
  fix. `ls -l` the TFTP root and compare
  `Bytes transferred` against the file size.

## Peripheral support

| Peripheral | Where | Driver | Notes |
|---|---|---|---|
| Console | UART0, MIO14/15 | `xilinx_uartps` | FT2232HQ channel B, `ttyPS0` |
| Gigabit Ethernet | GEM0, MIO16–27 + MDIO 52/53 | `macb` + `realtek` | RTL8211F at address 1, `rgmii-id`. The PHY reset has no GPIO (pulled up), so nothing to own. |
| microSD | SD0, MIO40–45 | `sdhci-of-arasan` | `no-1-8-v` (fixed translator), `broken-cd` (no card-detect line) |
| eMMC 8 GB | SD1, MIO46–51 | `sdhci-of-arasan` | `mmc1`, 4-bit, `non-removable` |
| QSPI 64 MiB | MIO0–13 | `spi-zynq-qspi` + `spi-nor` | Dual parallel, the same binding as `zynq-zc706.dts`. The FMCOMMS2 port reports a harmless EAR warning. `flashcp` to `/dev/mtd0` writes it from Linux; see "Reflashing from Linux". |
| USB | USB0, MIO28–39 | `ci_hdrc` + `ulpi` | Host on USB-A (`drv-vbus` turns on its VBUS switch), or device on USB-C with the `-usbdev` DTB. MIO7 (PHY reset) is held high by a gpio-hog. |
| XADC | — | `xilinx-xadc` | Die temperature and supplies |
| PL loading | devcfg | `fpga-mgr-zynq` | `echo x.bin > /sys/class/fpga_manager/fpga0/firmware` after `bit2bin` |

Everything else on this board is a **PL** peripheral: it has no PS driver and
does not exist until a bitstream is loaded. Most of it works -- the LEDs
and keys, the fan, all three I2C buses, the 40-pin header, HDMI in and out,
the MIPI camera, the PL PHY's MDIO, the SFP control pins and the SFP
transceivers are all covered elsewhere in this file or in `pl/README.md`. What
remains untouched is PCIe, SATA and the FMC.

## U-Boot in QSPI is a legacy image, not a FIT

`xilinx_zynq_virt` is a multi-board configuration, and two of its defaults
leave SPL printing `U-Boot SPL 2024.01 ... Trying to boot from SPI` and then
nothing:

- `CONFIG_OF_LIST` names seventeen Xilinx reference boards and not this one,
  so `u-boot.img` is a FIT with eighteen device trees. The fragment lists this
  board alone.
- `CONFIG_SPL_LOAD_FIT` makes SPL fetch the device tree as a **second read at
  its own offset** in the flash. On this dual-parallel QSPI that read returns
  the tree with its **first eight bytes** wrong (magic `dc4dfeed` for
  `d00dfeed`, totalsize `0x66b0` for `0x3938`) and the rest intact. U-Boot then
  has no device tree and data-aborts in `dev_get_uclass_plat()` before its
  console comes up; halted over JTAG, the PC sits at `0x40`, SPL's shared
  exception handler, in abort mode.

`spi-nor` splits every dual-parallel access across both W25Q256FV and halves
the offset, and `spi-nor-core.c` special-cases reads that start at an odd
offset. That fits the evidence (the firmware read from offset 0 is fine; the
tree's offset is not) but is not proven in the driver.

So SPL loads U-Boot as **one contiguous legacy image**: `u-boot.bin`, device
tree already appended, behind a 64-byte header, in a single read. It is byte
for byte what the JTAG path loads.

⚠ `CONFIG_OF_EMBED` is not an alternative: it builds, and U-Boot then hangs in
`hang()` before the console comes up, on the JTAG path too.

⚠ With SW1 on QSPI, `tools/bootuboot.tcl` does not work unmodified: its
`rst -system` lets the BootROM start SPL from flash, which fights the JTAG
download. The core must be halted within about 120 ms of the reset, not 3 s.

### Reflashing from Linux

Easier than interrupting U-Boot's countdown, and it verifies as it goes:

```
tftp -g -r qspi-boot.bin -l /tmp/qspi-boot.bin <tftp-server>
flashcp -v /tmp/qspi-boot.bin /dev/mtd0
```

`qspi-boot.bin` is `boot.bin` padded to `0x100000` followed by `u-boot.img`
(2,106,056 bytes for one build; the size varies) -- `cp boot.bin qspi-boot.bin &&
truncate -s 1M qspi-boot.bin && cat u-boot.img >> qspi-boot.bin`; `mtd0` is the 14 MiB "boot" partition starting at
flash offset 0, in 8 KiB eraseblocks.

**Measured.** 258 eraseblocks, erase + write + verify in **11.1 s**,
exit status 0, `Verifying data: 2056k/2056k (100%)`. The board was then
rebooted and came up through SPL from the rewritten flash to a login prompt.

⚠ **Hash the flash before and after.** `head -c <size> /dev/mtd0 | md5sum`
against the image says whether a write is needed at all, and proves
afterward that it landed. A mismatch after a write means stop and look
rather than write again.

## The USB PHY reset on MIO7

MIO7 is three things at once:
- the USB3320's RESETB, through a diode against a 10K pull-up to 1.8V,
- a boot-mode strap with a 20K pull-down,
- a GPIO the PS7 init leaves **tri-stated at the pin mux**: `MIO_PIN_07` = `0x601`, `TRI_ENABLE` = 1.

**Symptom:** `ci_hdrc: unable to init phy: -110`. Measured over JTAG: `ULPI_VIEWPORT` = `0x48030000`. The PHY clocks (`SS` = 1), but a register read never completes (`ULPIRUN` stuck).

**Cause:** the PHY never gets a clean reset after power-up. The pin is never driven, so RESETB drifts up on the resistor divider, and the PHY comes up with its ULPI register interface wedged.

⚠ **A GPIO hog is not enough.** The GPIO block's `DIRM`/`OEN`/`DATA` read "driving high" while the SLCR's `TRI_ENABLE` keeps the driver off, so the pin is not driven at all.

**The fix** has two halves:
1. **U-Boot `CONFIG_PREBOOT`** (`board/uboot-rkz7100.fragment`): clear `TRI_ENABLE`, drive MIO7 low for 10 ms, then high. After that the PHY reads vendor `0x0424`, product `0x07`.
2. **Linux keeps the pin driven:** a `pinctrl` state on `gpio0` with `bias-disable` makes `pinctrl-zynq` clear `TRI_ENABLE`, and the gpio-hog then really holds MIO7 high (`board/zynq-rkz7100.dts`).

**Result:** `ULPI integrity check: passed`, and the EHCI host started.

## USB device mode

The two connectors share one PHY and one D+/D- pair, so USB0 is either a host
on USB-A or a device on USB-C -- never both. The kernel is the same either
way; only the device tree differs, and `board/post-build.sh` writes all three into
`/boot/extlinux/extlinux.conf`:

| Label | Device tree | USB0 |
|---|---|---|
| `linux` (default) | `zynq-rkz7100.dtb` | host, USB-A |
| `linux-usbdev` | `zynq-rkz7100-usbdev.dtb` | peripheral, USB-C |
| `linux-hdmirx` | `zynq-rkz7100-hdmirx.dtb` | host, USB-A; HDMI and camera capture (only with the full bitstream) |

That table is what a boot from the eMMC root reads. An SD card built from
`sdcard.img` boots `board/extlinux.conf` from its FAT partition, which has
only `linux`. A TFTP boot
never sees it: `rkz7100-boot.cmd` fetches the tree named by `${rkz7100_dtb}`
instead, so there the switch is `setenv rkz7100_dtb zynq-rkz7100-usbdev.dtb`
before `source`.

**Pick the second one for a single local boot.** Stop U-Boot's countdown, then:

```
setenv pxe_label_override linux-usbdev
run distro_bootcmd
```

`pxe_label_override` is what U-Boot's extlinux parser checks before it honors
`default` -- no menu, no edit to the filesystem, and no `saveenv`. Leaving it
unsaved is deliberate: a stored environment shadows the compiled-in default on
every later boot, including after a U-Boot rebuild that changes `bootcmd`. A plain
`reboot` comes back on the host tree.

The kernel then reports `Machine model: RK-ZYNQ7100 (USB device)` and
`/sys/class/udc/ci_hdrc.0` exists.

### Building a gadget

Nothing is bound at boot; the functions are configured at run time through
configfs, which is **not mounted by default**:

```
mount -t configfs none /sys/kernel/config

G=/sys/kernel/config/usb_gadget/g1
mkdir -p $G/strings/0x409 $G/configs/c.1/strings/0x409 $G/functions/acm.usb0
echo 0x1d6b > $G/idVendor                       # Linux Foundation
echo 0x0104 > $G/idProduct                      # multifunction composite
echo RK-ZYNQ7100 > $G/strings/0x409/product
echo 0001        > $G/strings/0x409/serialnumber
echo ACM         > $G/configs/c.1/strings/0x409/configuration
ln -s $G/functions/acm.usb0 $G/configs/c.1/acm.usb0
echo ci_hdrc.0 > $G/UDC
```

⚠ **That symlink must name an absolute path.** `ln -s ../../functions/acm.usb0
configs/c.1/` fails on configfs with `No such file or directory`, which reads
like the function was never created.

`CONFIG_USB_CONFIGFS_{ACM,RNDIS,ECM,MASS_STORAGE,F_FS}` are all in the kernel,
so `ecm.usb0`, `rndis.usb0` or `mass_storage.usb0` swap in for `acm.usb0` the
same way.

**Measured, with a lead to a PC.** The ACM gadget binds, `/dev/ttyGS0`
appears, and:

| | |
|---|---|
| `/sys/class/udc/ci_hdrc.0/state` | **`configured`** |
| `current_speed` | **high-speed** |
| On the host | `VID_1D6B PID_0104` serial `0001`, a composite device plus a USB serial port |
| Board to host | a string written to `/dev/ttyGS0` arrives verbatim |
| Host to board | a string written to the host's port arrives verbatim |

⚠ `state` reads `not attached` until a gadget is **bound**, cable or no
cable -- a UDC with nothing bound never pulls up D+. Reading that as "no host
connected" sends you to check the lead when the fault is that `UDC` was never
written.

⚠ The gadget **discards** host-to-device data when nothing has
`/dev/ttyGS0` open. Start the reader on the board first, or the first message
vanishes and the direction looks broken.

## I2C

Every I2C device on this board — the ADV7511, the ADV7611, the AT24C256, the
camera module and whatever is on an FMC card — is reached over a bus that
lands on **PL** pins. The PS has no I2C controller wired out to them.

So the PL hands the pins to the PS as EMIO GPIOs and `i2c-gpio` bit-bangs
them. Three buses are wired:

| Bus | Linux gpio (SCL/SDA) | Device |
|---|---|---|
| `i2c-hdmi-tx` | 55 / 56 | ADV7511 at 0x39 |
| `i2c-hdmi-rx` | 57 / 58 | ADV7611 at 0x4C |
| `i2c-cam` | 59 / 60 | AT24C256 at 0x50, and the camera connector |

```
i2cdetect -l                 # which /dev/i2c-N is which bus
i2cdetect -y 0               # what answers on it
hexdump -C /sys/bus/nvmem/devices/*/nvmem | head    # the EEPROM
```

### Measured on the hardware

```
i2c-0  i2c-hdmi-tx     38 39 3c 3e 3f        the ADV7511 and its other maps
i2c-1  i2c-hdmi-rx     4c                    the ADV7611
i2c-2  i2c-cam         50                    the AT24C256
```

All three answer. The ADV7511 appearing on five addresses is what an ADV7511
looks like: 0x39 is the main map and the others are its EDID, packet and CEC
maps. The ADV7611 identifies itself properly — its revision registers read
`0xEA = 0x20`, `0xEB = 0x51`, which is the ADV7611's ID:

```
i2cget -y 1 0x4c 0xea      # 0x20
i2cget -y 1 0x4c 0xeb      # 0x51
```

⚠ **`i2cdetect -r` hides the ADV7611.** Forcing SMBus *read byte* probing
with `-r` returns nothing at 0x4C, which reads exactly like a dead chip. The
ADV7611 wants a register address written before it will read, so a bare read-byte gets no answer. `i2cdetect`'s default probing, and
`-q` (quick write), both find it:

```
i2cdetect -y -q 1          # 4c
i2cget -y 1 0x4c 0x00      # 0x08
```

When a device that should be there is missing from a scan, change the probing
method before you change your mind about the hardware.

⚠ **All of this needs a bitstream.** The pins are PL pins: with the PL
unconfigured the buses do not exist as far as the board is concerned, even
though the `i2c-gpio` adapters still register. U-Boot's PREBOOT loads one
before the kernel starts, and `board/S15fpga` does if it did not.

⚠ **The ADV7611 answers nothing until its reset is released.** `HDMI_RX_RST`
has a 4.7K pull-down, so the chip stays in reset until the PL drives it high;
a gpio-hog on gpio 61 does that. Without it the HDMI-in bus looks dead and the
bus is not the problem.

⚠ **The EEPROM is writable.** R102 4.7K pulls `WP` to **ground**, and `WP` on
the AT24C256 is active high — low allows writes. A byte written at offset
`0x100` reads back:

```
i2cset -y -f 2 0x50 0x01 0x00 0x5a i     # offset 0x0100 = 0x5A
i2cset -y -f 2 0x50 0x01 0x00 0xff i     # and back
```

(16-bit addressing, so the two address bytes precede the data; `-f` because
the `at24` driver owns the device.)

That is where the board's MAC addresses live — see "The MAC address"
below.

**What is in it (read):** an ASCII timestamp at offset 0 (represented below
by the placeholder `2026-01-01 00:00:00`), then the MAC addresses at 0x20 and 0x26
once written (see "The MAC address"), and `0xFF` elsewhere. A factory test
stamp, and the only thing on this board that records when it was made.

```
hexdump -C /sys/bus/i2c/devices/2-0050/eeprom | head -2
00000000  32 30 32 36 2d 30 31 2d  30 31 20 30 30 3a 30 30  |2026-01-01 00:00|
00000010  3a 30 30 ff ff ff ff ff  ff ff ff ff ff ff ff ff  |:00.............|
```

## The 40-pin header

All 34 pins of J8 are EMIO GPIOs, so Linux owns direction and level per pin:

```
gpioinfo | grep J8          # J8.4-IO1_P .. J8.35-IO17_N, named by header pin
gpioset  gpiochip0 72=1     # drive J8 pin 4 high
gpioget  gpiochip0 73       # read J8 pin 3
```

`gpio-line-names` in the device tree names every line after its **physical
header pin**, so `gpioinfo` reads `J8.4-IO1_P` rather than "line 72" and
nobody has to keep the mapping in their head.

| Thing | Linux gpio | Notes |
|---|---|---|
| J8 `IOk_P` | 72 + 2(k−1) | header pin 2k+2 |
| J8 `IOk_N` | 73 + 2(k−1) | header pin 2k+1 |

Pins come up as **inputs** — `GPIO_T` resets to 1 — which is the safe default
for a header whose other end is unknown. Each has a weak **pull-up** in the
full design, so an unconnected pin reads 1 by design and a 0 means
something is pulling it down: a wire from J8 pin 36 (`IO17_P`, gpio 104) to
ground reads 0 while its neighbors read 1.

⚠ `pl/tools/j8test.sh` walks a one through all 34 and reads the pin levels
back. It **cannot** catch a consistent permutation, because the write and the
readback take the same path; a wire between two known header pins is the only
thing that settles which physical pin is which.

## The BIST engines

The PL has three BIST engines. Two are AXI masters on `S_AXI_HP1` and `HP2`
that reach PS DRAM at 64 bits a clock; the third sweeps the PL DDR3 through
the MIG. All three interrupt the CPU when a run finishes.

```
sh pl/tools/bisttest.sh -m 8
```

**Measured:** 16,777,216 bytes in 2,100,168 cycles on each port —
**798 MB/s**, against a theoretical 800 (64 bits at 100 MHz). Zero errors,
HP2 verified what HP1 wrote, and both woke a blocked reader on `/dev/uio`.

### Where they are allowed to write

```
reserved-memory {
        bist-buffer@3f000000 { reg = <0x3f000000 0x1000000>; no-map; };
};
```

⚠ **The engines have no bounds check of any kind.** Whatever `ADDR` points at
is overwritten at 64 bits a clock. The device tree reserves the top 16 MB of
the gigabyte so there is somewhere safe to aim them; `/proc/iomem` shows
System RAM ending at `0x3effffff` when it has worked.

⚠ `no-map` is doing two jobs. It keeps the kernel out, and it keeps the region
out of the kernel's linear map so `/dev/mem` hands it back **uncached**. That
second part is not a detail: the HP ports are not coherent with the CPU's
caches, so a cached mapping would let the CPU read stale lines and blame the
memory. Nothing in the fabric can tell those two apart.

### The interrupt

`IRQ_F2P[0]`, `[1]` and `[5]` are GIC 61, 62 and 66, which the device tree
numbers as SPI 29, 30 and 34. (`IRQ_F2P[2]`, `[3]` and `[4]` are GIC 63–65, SPI 31–33 -- the HDMI
VDMA, the camera VDMA and the CSI-2 receiver, claimed by their drivers rather
than by UIO.) Each BIST engine gets a
`uio_pdrv_genirq` node, so reading 4 bytes from `/dev/uioN` blocks until that
engine finishes:

```
# grep pl-bist /proc/interrupts
 40:          3          0  GIC-0  61 Level     pl-bist
 41:          2          0  GIC-0  62 Level     pl-bist
```

(Engines 0 and 1, which `bisttest.sh` fires; engine 2's line, GIC 66, has a
node too, `pl_bist2`, and is not exercised by the script.)

⚠ **`uio_pdrv_genirq.of_id=generic-uio` is not optional.** That driver's
device-tree match table is declared empty and filled in from a module
parameter, so a node with `compatible = "generic-uio"` binds to **nothing**
without it — even with `CONFIG_UIO_PDRV_GENIRQ=y`. The symptom is no
`/dev/uio*` and not one word in dmesg about why. `board/post-build.sh` puts it
on the kernel command line.

⚠ **A reader must be blocked in `read()` before the run starts.** uio records
the event count at `open()`, so an interrupt that arrives first is already
accounted for and the next `read()` waits forever. A short run finishes in
microseconds — far quicker than a shell can start `dd`.

⚠ **This busybox has no `timeout`.** `timeout 5 dd ...` exits 127 immediately,
which looks exactly like "the interrupt never arrived" and sends you looking
at working hardware. `bisttest.sh` uses a `sleep`-and-`kill` watchdog.

The engine's interrupt is a level held until software writes its ACK register,
and `uio_pdrv_genirq` masks the GIC line in its handler and leaves userspace to
re-arm it by writing a 4-byte 1 to `/dev/uioN`. Clear the engine **first**, or
re-arming just re-fires.

## LEDs and keys

The four green LEDs and the four push buttons are ordinary Linux devices, not
register pokes:

```
ls /sys/class/leds/                       # rkz7100:green:led1 .. led4
echo 1 > /sys/class/leds/rkz7100:green:led2/brightness
echo none > /sys/class/leds/rkz7100:green:led1/trigger   # it starts as heartbeat

evtest /dev/input/event0                  # KEY1..KEY4 as KEY_1..KEY_4
```

LED1 comes up on the **heartbeat** trigger, so a working kernel is visible
across the room; `echo none > trigger` hands it back. The others start off.
Any LED trigger works — `mmc0`, `netdev`, `cpu0` — which is the point of
making them a real LED class.

The keys are active low (they pull to ground against 4.7K pull-ups) and
`gpio-keys` debounces them in software at 20 ms. They arrive as `KEY_1` to
`KEY_4` on an input device, so `evtest` sees them and so does anything else
that reads input events.

| Thing | Linux gpio | Notes |
|---|---|---|
| LED1–4 | 64–67 | active high — the board drives them through NPN transistors |
| KEY1–4 | 68–71 | active low |

⚠ **The bicolor LED8 is deliberately not here.** It stays driven by the
fabric, where it blinks at ~1.5 Hz to mean "the PL is configured and clocked"
and goes solid when the design reports itself up. Handing it to Linux would
trade the one indicator that works with no software running for a fourth
controllable LED, which is a bad trade. Software can still take it through the
register at `0x08`.

Like everything else on PL pins, all of this needs a bitstream — U-Boot loads
one before the kernel starts.

## The MAC address

Both go in the EEPROM, six raw bytes each, past the factory timestamp. A new
board's EEPROM has none, so write them once (below); without them the
addresses are random on every boot, which makes DHCP leases and `arp` caches
useless.

| | `eth0` (PS, RJ1) | `eth1` (PL, RJ2) |
|---|---|---|
| Address (this board's) | `02:00:da:b9:ee:0e` | `02:00:da:b9:ee:0f` |
| EEPROM offset | `0x20` | `0x26` |
| Read by | U-Boot's `PREBOOT`, which forces it into `ethaddr` and stamps it into the kernel's device tree as `local-mac-address` | Linux, through an nvmem cell |

Both are locally administered (`02:` -- bit 1 set, so neither can collide with
a real OUI). Deriving eth0's from the eMMC serial (`mmc cid`; `0xdab9ee0e`
above) makes it reproducible if the EEPROM is cleared; eth1's is the next one
up.

To change one, write six bytes and reboot -- `seek=32` for eth0, `seek=38`
for eth1:

```
printf '\002\000\336\255\276\357' | \
    dd of=/sys/bus/i2c/devices/2-0050/eeprom bs=1 seek=38 conv=notrunc
```

⚠ **U-Boot's address wins over the EEPROM cell.** `of_get_mac_address()` takes
`mac-address`, `local-mac-address` and `address` before it ever tries an nvmem
cell, so on a normal boot eth0 uses what U-Boot fixed in, and its nvmem cell
is only the fallback. eth1 has no U-Boot fixup, so its cell is the one that
counts.

⚠ **The cells are in a `fixed-layout` node, not directly under the EEPROM.**
`at24` in this kernel does not set `add_legacy_fixed_of_cells`, so cells
written as plain children of the EEPROM node are never registered, and every
lookup of them fails. eth0 hides the failure because it takes U-Boot's
address; eth1 falls back to a random one.

⚠ **Referencing the EEPROM also fixes the NAMES.** A controller whose MAC is
an nvmem cell waits for `at24` to bind, because `fw_devlink` follows the
phandle. With a MAC written into the device tree instead, GEM1 does not wait,
probes first and becomes `eth0` -- and the boot's DHCP, which runs on `eth0`,
moves to the PL port. With both reading the EEPROM, both wait, and they are
retried in device-tree order: GEM0 is `eth0`, GEM1 is `eth1`.

### Why this needs U-Boot to load the bitstream

The EEPROM is on **PL pins**. Nothing can read it until the PL is configured,
so the ordering is the whole design:

1. `PREBOOT` loads the bitstream from the boot medium -- `rkz7100.bin` on an
   SD card's FAT partition, `/boot/rkz7100.bin` on the eMMC otherwise -- and
   configures the PL.
2. `PREBOOT` then reads the six bytes over the now-live bit-banged I2C and
   forces `ethaddr`.
3. U-Boot writes `ethaddr` into the device tree it hands the kernel.
4. Linux comes up with it, and `S15fpga` sees the PL already configured and
   leaves it alone.

⚠ **`setenv -f`, not `setenv`.** U-Boot probes the Ethernet during `Net:`,
which runs *before* `preboot`, so by the time we read the EEPROM it has
already invented a random address and write-protected `ethaddr`. A plain
`setenv` fails with `Can't overwrite "ethaddr"` and the random one survives —
silently, because preboot's output scrolls past. The boot log still shows the
`using random MAC address` warning from that earlier probe; that is expected,
and the address Linux ends up with is the one that matters.

⚠ **`setexpr.b` drops leading zeros**, so this builds `2:0:da:b9:ee:e`.
U-Boot parses each colon-separated field as hex, so that *is* `02:00:...:0e` —
`net list` confirms it. A blank EEPROM reads `0xFF`, and `ff:ff:ff:ff:ff:ff`
is the broadcast address, so `preboot` refuses to use it.

### What else loading the bitstream early buys

| | |
|---|---|
| The fan | Runs from power-on instead of waiting for userspace — without it the part sits about 8 °C hotter |
| I2C and GEM1 | The I2C buses exist when their drivers probe, and GEM1's PHY scan -- which goes through the GMII-to-RGMII core in the PL -- finds PHY2, so no unbind/rebind dance is needed |
| `fpga_manager` | `S15fpga` prints `PL already configured by U-Boot`, routes GEM1's clocks from EMIO, and does nothing else |

The `INFO:post config was not run` line after the load is U-Boot's zynqpl
driver printing unconditionally on success; `zynq_slcr_devcfg_enable()` has
already run, and the working EMIO I2C proves the level shifters are on.
Nothing to chase.

## The Ethernet PHYs, and selecting 10/100/1000

There are two RTL8211F-CG PHYs, each behind one of the PS's Ethernet
controllers, and `ethtool` drives both.

### PHY1, on the PS (RJ1)

An ordinary phylib PHY behind the GEM, on the PS's own MDIO pins (MIO52/53),
so `ethtool` drives it and nothing special is needed:

```
ethtool -s eth0 autoneg on advertise 0x008     # 100baseT full only
ethtool -s eth0 autoneg on advertise 0x002     # 10baseT full only
ethtool -s eth0 autoneg on advertise 0x03f     # everything again
```

**Measured:** 1000 → 100 → 10 → 1000, each renegotiating in a few
seconds, with `ping` still running at 10 Mb/s (3/3, 0.8 ms). The 10 Mb/s case
is the one worth checking: the GEM's transmit clock has to drop to 2.5 MHz,
and traffic flowing proves `macb` retuned it through the clock framework.

Restricting what is advertised is better than `autoneg off speed N`: a gigabit
link is only legal with autonegotiation on, so forcing is a 10/100-only trick.
`phytool read eth0/1/<reg>` reaches the registers directly.

### PHY2, on the PL (RJ2)

PHY2 is wired entirely to the PL -- RGMII **and** its MDC/MDIO -- so its MAC is
the PS's second controller, **GEM1**, brought out over EMIO as GMII and turned
into RGMII by Xilinx's `gmii_to_rgmii` core in the full bitstream. The core
also carries GEM1's MDIO through to the PHY. Linux sees an ordinary `macb`
interface, `eth1`:

```
ethtool -s eth1 autoneg on advertise 0x008     # 100baseT full only
ethtool eth1                                   # what was negotiated
sh pl/tools/eth2test.sh                        # the whole check, below
```

Three things make it work, and each one fails quietly without the others:

| | |
|---|---|
| `CONFIG_XILINX_GMII2RGMII=y` | The core's transmit clock depends on the link speed, and it learns the speed only through its own register at MDIO address 8. The `xilinx_gmii2rgmii` driver writes it after every PHY status read. Without it the core stays at its reset speed and only one link rate carries traffic. |
| The device tree | `&gem1` with `phy-mode = "gmii"` and `phy-handle` on **PHY2 itself**; the converter is a second node on the same MDIO bus, at 8, pointing at PHY2. `"gmii"` also leaves PHY2's RGMII delays as strapped, which is what the core's timing expects. |
| `board/S15fpga` | GEM1's clocks must come from EMIO. ENET1 is enabled only in the full design's PS configuration, so the PS init the boot runs does not select that, and the kernel's clock driver will not switch the mux itself. `S15fpga` sets the source selects in `GEM1_RCLK_CTRL` (`0xF800013C`, bit 4) and `GEM1_CLK_CTRL` (`0xF8000144`, bit 6). |

⚠ `S15fpga` also sets `CLKACT` (bit 0) in both registers, but in
`GEM1_CLK_CTRL` that bit belongs to the kernel: its clock gate clears it
whenever `eth1` is down and sets it again on the next `ip link set up`, and
it rewrites the dividers on every speed change. Both are harmless with the EMIO
source selected, and a check of GEM1's clocking should look at the source
selects only.

**Measured,** with `eth0` down so that every packet crossed RJ2:

| | |
|---|---|
| 1000, 100, 10 Mb/s | link, a DHCP lease and 20/20 pings to the gateway at each; the core's speed register follows every change |
| `iperf3` into the board | **666–674 Mbit/s**, and a 60 s run of **4.8 GB with no CRC, FIFO or overrun error** |
| `iperf3` out of the board | **562–807 Mbit/s** over eight runs; the figure swings run to run, on `eth0` too |

Those are the CPUs' limits, not the link's, and on par with `eth0`.
`pl/tools/eth2test.sh` repeats the speed walk; for throughput it leaves `eth1`
up alone with `-k`, and `iperf3 -s` here with `iperf3 -c` on a host measures
it. The core's own view of the link is at `0xF4` in the register file (see
`pl/README.md`).

⚠ **Test one port with the other down.** Both ports are on the same LAN, and
Linux answers ARP for any local address on any interface by default, so with
both up a ping "to `eth1`" can be answered through `eth0`.

### ⚠ A device on PL pins must be probed *after* the bitstream

U-Boot normally configures the PL before Linux starts, and then this does not
arise. When it has not, `S15fpga` loads the bitstream itself, long after the
drivers probed -- and whatever a driver found across pins that did not exist
yet, it keeps. GEM1's MDIO reaches PHY2 only through the core in the PL, so
its PHY scan finds nothing; `S15fpga` unbinds and rebinds GEM1 after the load.

The I2C **buses** survive being created early — `i2c-gpio` registers an
adapter without touching a pin — but a **client** on one does not, if it reads
the part when it probes. `at24` validates the EEPROM at probe, gets nothing
across pins that do not exist yet, and leaves the device unbound with no
`eeprom` attribute, while a plain `i2cget` on the same address works perfectly
once the PL is up. `S15fpga` binds it again for the same reason:

```
at24 2-0050: 32768 byte 24c256 EEPROM
```

The rule that covers both: **anything that performs I/O when it probes must be
probed again after the bitstream**. Registering a bus is not I/O; scanning one,
or reading a device on it, is.

## The camera

J9 takes a Raspberry Pi-style camera module; the one here is an Arducam 5 MP
OV5647. It is `/dev/video1`, with the full bitstream and the capture device
tree (`zynq-rkz7100-hdmirx.dtb`):

```
OV5647 --I2C 0x36 on i2c-cam--> ov5647             (the sensor, a subdev)
       --2 MIPI lanes--> CSI-2 receiver in the PL   xilinx-csi2rxss (a subdev)
                         --> cam_guard --> AXI VDMA  xilinx_dma, xilinx-vipp -> /dev/video1
```

`pl/tools/camsetup.sh W H` gets a mode ready -- the same format on every pad,
with `field:none`, and the D-PHY input delay that mode needs (tap 10, the
reset value, for the lower three; 31 for 2592x1944). `pl/tools/camtest.sh`
sets each mode, captures, and checks the frames, the sensor's color-bar
test pattern and the receiver's own error counts; `-t` sweeps the delay.

What Linux needs, beyond the drivers (`CONFIG_VIDEO_OV5647` and
`CONFIG_VIDEO_XILINX_CSI2RXSS`, both in the fragment):

| | |
|---|---|
| `clock-noncontinuous` on the sensor's endpoint | ⚠ Without it only the first stream after the bitstream loads delivers frames. Every later one runs with the byte clock present and no packet received, and no reset short of reconfiguring brings it back. |
| `pwdn-gpios` = gpio 62 | J9 pin 5, the module's power enable. The driver powers the module off between streams, so the sensor does not answer on I2C while nothing streams. |
| `clocks` = a 25 MHz `fixed-clock` | The module has its own oscillator; the driver only needs to be told its rate, and refuses any other. |
| `video-reset-gpios` = gpio 110 | The receiver's video reset, pulsed by the driver at probe and after every stream stop; its only way to recover the core after a stream error. |
| `CONFIG_CMA_SIZE_MBYTES=128` | A 2592x1944 RAW10 frame is 10 MB and streaming needs at least three; the default 16 MB held one, and the capture failed with `dma alloc ... failed`. |
| `reg = <0x80020000 0x20000>` | The receiver's registers and, from `+0x1000`, its D-PHY's. |

⚠ **The media device number moves.** The camera is its own media device;
with the HDMI input's pipeline also registered it is `/dev/media1`, and when
the HDMI receiver does not probe it is `/dev/media0`. Find it by bus info
(`platform:video-camera`), as `camtest.sh` does.

⚠ **`xilinx-csi2rxss` stops the stream on a full line buffer.** Its
"Stream Line Buffer Full!" interrupt disables the core until the stream
stops, with the sensor still sending. `cam_guard` in the PL exists so that
never happens -- see "The camera" in `pl/README.md`.

## Die temperature and the fan

Both arrive in hwmon, so `sensors`, `fancontrol` or anything else that looks
for a temperature or a fan finds them without knowing anything about this
board.

```
# sensors
die_thermal-virtual-0
Adapter: Virtual device
temp1:        +38.4 C

pwmfan-isa-0000
Adapter: ISA adapter
Fan (J10):   1068 RPM

xadc_hwmon-isa-0000
Adapter: ISA adapter
VCCINT (1.0V):     1.00 V
VCCAUX (1.8V):     1.78 V
VCCBRAM (1.0V):    1.00 V
VCCPINT (1.0V):    1.00 V
VCCPAUX (1.8V):    1.78 V
VCCO_DDR (1.5V):   1.50 V
XC7Z100 die:      +38.4 C
```

Taken on a cold standalone boot, with nothing done by hand: the
board loaded its own bitstream, the thermal zone took charge of the fan, and
the fan is turning at the governor's idle state. The names come from
`board/sensors-rkz7100.conf`; without it these are `in1..in6` and there is no
way to tell which rail sagged.

The rails read back exactly what the user guide's power table describes —
1.0 V, 1.8 V, 1.5 V — which is a free check on both the table and the PS
configuration.

To set the fan by hand, write `pwm1` on the `pwmfan` device:

```
echo 128 > /sys/class/hwmon/hwmon0/pwm1
```

⚠ Find it by its `name`, not by the number: hwmon indices follow probe order
and are not guaranteed:

```
for h in /sys/class/hwmon/hwmon*; do echo "$h = $(cat $h/name)"; done
```

### Where each piece comes from

| Piece | What provides it |
|---|---|
| The measurements | The **PS XADC interface** (`xlnx,zynq-xadc-1.00.a` at `0xf8007100`), already enabled in the device tree and already an IIO device. No PL involvement. |
| `temp1_input`, `in*_input` | `iio-hwmon`, a node that consumes XADC channels. `&adc` carries `#io-channel-cells` for it. |
| `pwm1` | `pwm-fan` on top of `pwm-cadence` — **TTC1 channel 0** in the PS, out through EMIO. |
| The pin end | The PL: `fan_ctrl.v` inverts the PWM for the board's transistor and counts the tachometer. See [the fan controller](hh-rk-zynq7100-design.md#2-fan-controller). |

The XADC channel numbers in `io-channels` are indexes into the driver's channel
array, not the channel numbers in the sysfs names: 0 is the temperature, then
vccint, vccaux, vccbram, vccpint, vccpaux, vccoddr. `vrefp` and `vrefn` (7, 8)
are the converter's own references and say nothing about the board, so they are
left out.

### Why TTC1, and why `#pwm-cells` decides it

The fan's PWM pin is a PL pin, so a PS timer can only reach it through the
fabric. Zynq's TTCs can put their waveform outputs on EMIO, and the kernel has
a PWM driver for them, which makes the whole fan path mainline drivers and no
soft IP.

`#pwm-cells` in the TTC node is what chooses between the two drivers that both
match `cdns,ttc`: the clocksource driver returns `-ENODEV` for a node that has
it, and `pwm-cadence` returns `-ENODEV` for a node that does not. TTC0 is left
alone — it registers as `ttc_clocksource`, though `arm_global_timer` is what
the system actually runs on.

TTC1 is enabled in `board/ps7_config.tcl` for the PL build; it **does not
change the PS init** (`ps7_init_gpl.c`, `ps7_init_gpl.h` and `ps7_init.tcl`
are byte-identical with or without it), so enabling it needs no regeneration.

### ⚠ No bitstream means no fan, and the fan is OFF

`pwm1` exists and accepts writes whether or not the PL is configured — TTC1 is
a PS peripheral and does not care. The signal simply does not reach the pin.
And an unconfigured PL does not leave the fan running: PUDC_B is strapped low,
so the pull-ups hold W21 high and the board's transistor holds the fan off.
The part idles about 8 °C hotter that way. Loading a bitstream is what gives
the board its fan back.

### ⚠ `pwm1 = 0` means full speed, not off

The TTC waveform's resting level at
0% duty is not defined — measured here it rested low after a ramp down and high
after a step down from 255 — but neither resting level has edges, and the PL
reads "no waveform" as "cool the part". To actually stop the fan, set
`FAN_CTRL[1]` in the PL: `devmem 0x8010001C 32 2` with the `board/` design
loaded, and `0` to give it back. `../pl/README.md` has the detail.

### Fan speed, two ways

`fan1_input` comes from `pwm-fan` itself, which counts tachometer edges on an
interrupt. The tachometer is a PL pin, so the PL carries it up to the PS on
**EMIO GPIO 0 = Zynq GPIO 54**, and the device tree points the fan node's
`interrupts` at it.

`pulses-per-revolution = <2>` is an assumption about the **fan**, not about
the board — two pulses per revolution is what nearly every 4-wire fan does,
but nothing here can check it. If a fan with a different count goes on, the
rpm will be out by that ratio and the PL's `FAN_STATUS` register, which counts
raw pulses per second, is what settles it. The two are independent readings of
the same wire, which is worth having when a number looks wrong.

### Automatic control

There is no daemon. A `generic-adc-thermal` sensor reads the XADC's
temperature channel — no lookup table, because the channel is `IIO_TEMP` and
the driver takes the processed value as millicelsius — and a thermal zone
moves `pwm-fan` through its cooling states:

| Die temperature | Cooling state | `pwm1` |
|---|---|---|
| below 45 °C | 0 | 64 |
| 45 °C | 1 | 102 |
| 55 °C | 2 | 153 |
| 65 °C | 3 | 204 |
| 75 °C | 4 | 255 |

with 4 °C of hysteresis on each trip and the `step_wise` governor.

⚠ **State 0 is 64, not 0, and that is deliberate.** A zero duty stops the
waveform, and the PL reads a stopped waveform as "nobody is driving this" and
forces full speed. A cooling floor of 0 would therefore make the governor's
idle state the loudest one. A 25% floor keeps the waveform alive, keeps the
tachometer reading, and leaves the fabric fallback for what it is for — Linux
not running.

There is deliberately **no `critical` trip**. On this part it would mean an
orderly shutdown in the middle of whatever is running, and a bench board that
turns itself off is worse than a warm one.

To take the fan back by hand, write `pwm1`; the governor will move it again at
the next poll (5 s, or 2 s once a trip is crossed). `fancontrol` and
`pwmconfig` are in the rootfs for a userspace policy instead.

### Loading a bitstream at boot

Both fan pins are PL pins, so none of the fan control reaches the fan without
a bitstream. U-Boot's PREBOOT loads one before Linux starts -- `rkz7100.bin`
from an SD card's FAT partition on an SD boot, `/boot/rkz7100.bin` from the
eMMC otherwise -- and `S15fpga` then finds the PL configured and only routes
GEM1's clocks. When U-Boot has not, `board/S15fpga` loads
`/lib/firmware/rkz7100.bin` through the FPGA manager, and exits quietly if
nothing is there. Neither is tied to a design; put whichever one you want
there:

```
python3 pl/bit2bin.py <pl build dir>/rkz7100_pl.bit rkz7100.bin
```

Without one the fan stays off until something loads a design.

## Regenerating the PS init

Both PL builds automatically generate `<outdir>/ps7_init.tcl`, including
`ip` and `project` runs. `linux/ps7_init_build.tcl` instantiates PS7 v5.5 using
only the canonical `board/ps7_config.tcl`, before creating the PL project.
This keeps JTAG boot consistent with SPL rather than inheriting the full PL
design's Ethernet/AXI-port overrides. Vivado emits the initialization through
its [IP output-product generation](https://docs.amd.com/r/en-US/ug896-vivado-ip/Using-Tcl-Commands-to-Reset-and-Generate-Target-IP).

To generate initialization alone, run from the repository root with Vivado
2026.1 on PATH and the `retrosim-build` sibling available:

```sh
vivado -mode batch -nojournal -nolog -source linux/gen_ps7.tcl -tclargs <outdir>
```

The script writes `<outdir>/ps7_init.tcl`. The shared content cache under
`<outdir>/boot-init/` includes configuration/generator contents and the Vivado
version in its key; a missing cached Tcl is regenerated. Refused, unreadable,
or mismatched settings and missing/empty products fail the build. A failed
regeneration removes the previously published top-level Tcl. Vendor output
and any notices it contains are preserved without rewriting it.

`PYTHON3` can select the Python executable used by the shared cache. On Windows,
use a native executable path if a Store alias cannot be launched by Tcl.

For a Windows PL build followed by a WSL Linux build, set
`RKZ7100_BITSTREAM` to the `.bit` under `/mnt/c/...`; the Linux driver finds
`ps7_init.tcl` beside it. Alternatively set `RKZ7100_PS7_INIT` explicitly,
including when the selected bitstream was copied elsewhere. `stage-tftp.sh`
requires the staged Tcl and copies it beside `u-boot.bin`. It fails before
copying any files when initialization is absent. The XSDB command uses
`<tftproot>/ps7_init.tcl`.

The generated Tcl is not tracked or bundled in release archives. Regenerate
it locally for JTAG boot and preserve any notices in the vendor output.

The GPL-noticed C/H files remain tracked so Linux/SPL builds do not require
Vivado. When changing boot settings, review and update those files from
`<outdir>/boot-init/ps7_init_gpl.c` and `.h`, preserving the vendor notices
and their added SPDX identifiers. Generation alone does not update them.
All three silicon revisions are covered by the generated runtime selection.

Run `python -m unittest discover -s linux/tests` from the repository root for
cache invalidation, configuration rejection, incomplete generation, stale-file
removal, and TFTP staging regressions. These tests use a mocked PS7 IP plus
the real shared cache; they do not establish board boot behavior.

## Bring-up order

For a new board, in this order; each step tests something the one before
could not, and every step has been run on this board:

1. **`bootuboot: DDR ok`** and a PC near `0x3ffxxxxx`. This proves JTAG, the PS init and DDR.
2. **U-Boot banner on the console**, reporting `DRAM: 1 GiB`. This proves UART0. Then run `mtest` over a range.
3. **`dhcp`, then the TFTP boot.** This proves Ethernet at layer 3, which a link light does not.
4. **Linux to a login prompt.**
5. **`ethtool eth0` and `iperf3`.** 1 Gb/s with real throughput proves the RGMII delays.
6. **`mmc` in U-Boot and `/dev/mmcblk0`, `/dev/mmcblk1` in Linux.** SD and eMMC.
7. **`sf probe` reporting 64 MiB, and `mtdinfo`.** QSPI, from both sides: `sf probe`, `sf erase`/`sf write` and a `cmp.b` read-back from U-Boot, and `mtdinfo` plus a verified `flashcp` of the 2 MiB boot image from Linux. The board boots out of the flash either way.
8. **`lsusb` with a stick on USB-A, and a gadget on USB-C.** A USB stick enumerates as `/dev/sda` on the host tree, and on the `-usbdev` tree an ACM gadget reaches `configured` at high speed on a PC. See "USB device mode".
9. **A bitstream through the FPGA manager.** `bit2bin.py` then `/sys/class/fpga_manager/fpga0/firmware`; `state` reads `operating`, and the PL answers on M_AXI_GP0. See [`../pl/README.md`](../pl/README.md).
10. **`sensors`, and the board cooling itself.** On a cold standalone boot: the bitstream loaded at boot, the XADC's die temperature and rails in hwmon, `fan1_input` in rpm from the tachometer, and a thermal zone holding the fan at its idle state with nothing done by hand. See "Die temperature and the fan".

# hh-rk-zynq7100-dev programmable logic

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

Build and load the full `board` design or the smaller `ddr` memory-test design.

## Documentation

| Document | Contents |
|---|---|
| [Design](../doc/hh-rk-zynq7100-design.md) | Architecture, peripherals, registers, and hardware validation. |
| [Linux guide](../linux/README.md) | Building Linux and configuring boot. |
| [Simulation guide](sim/README.md) | Automated RTL checks. |

## Repository layout

| Path | Contents |
|---|---|
| `board/` | Full board design, constraints, and build Tcl. |
| `ddr/` | Memory and BIST design. |
| `tools/` | Board-side tests and constraint/stub generators. |
| `sim/` | Benches, vendor-IP stubs, and verification runners. |

## Requirements

See the root [requirements](../README.md#requirements). Both designs use
`linux/board/ps7_config.tcl` for PS configuration and consume shared tooling
from the sibling `retrosim-build` checkout.

## Getting started

### Building

Run from `pl/`:

Vivado 2026.1, from a shell with Vivado's `settings64` sourced (or its `bin`
on PATH):

```
vivado -mode batch -nojournal -nolog -source board/build.tcl -tclargs [<outdir> [ip|project]]
```

`<outdir>` defaults to `$RKZ7100_BUILD/board`, or without that to
`C:/rkz7100-build/board` on Windows and `~/rkz7100-build/board` elsewhere; the
`ddr` design does the same with `ddr`. A second argument of `project` creates
the Vivado project and stops, for opening in the GUI; `ip` (the board design
only) stops after the IP have been generated, which is all
`tools/gen_ip_stubs.py` needs to refresh the simulation stubs.

⚠ **Keep the output directory short and out of the repo.** Vivado's IP flow
trips over Windows' 260-character path limit and fails in ways that do not
mention paths, such as `IP directory ... does not exist`. That is why the
default is a short path of its own.

Both builds generate `<outdir>/ps7_init.tcl` automatically, including `ip`
and `project` runs. This is the canonical boot initialization from
`linux/board/ps7_config.tcl`, generated separately from PL-specific PS7 overrides.
The shared content cache under `<outdir>/boot-init/` is invalidated by changes
to that configuration, the generator, or the Vivado version. See
[PS init generation](../doc/linux-guide.md#regenerating-the-ps-init) for JTAG
boot and Linux staging. No board is accessed by generation.

The build fails loudly rather than quietly: if the PS7 refuses any setting from
`ps7_config.tcl` it stops, and if synthesis or implementation does not reach
100% it stops with the path to the run log.

### Loading a bitstream into Linux

Vivado writes configuration data big-endian; Zynq's PCAP DMA reads 32-bit
little-endian words. `bit2bin.py` does the byte swap (what Xilinx's `bootgen
-process_bitstream bin` does) and strips the `.bit` header, so the flow needs
nothing but Vivado and Python:

```
python3 bit2bin.py <outdir>/rkz7100_pl.bit rkz7100_pl.bin
```

It prints the part name out of the header — loading a bitstream built for the
wrong device is otherwise a silent, puzzling failure.

On the board:

```
tftp -g -r rkz7100_pl.bin -l /lib/firmware/rkz7100_pl.bin <tftp-server>   # or scp, or a USB stick
echo 0 > /sys/class/fpga_manager/fpga0/flags        # 0 = full reconfiguration
echo rkz7100_pl.bin > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state             # -> operating
```

`state` reads `unknown` before the first load — that is the driver not knowing,
not a failure. After a successful load it reads `operating`.

**To have it loaded at boot**, put it where U-Boot's PREBOOT looks:
`rkz7100.bin` on an SD card's FAT partition for an SD boot, `/boot/rkz7100.bin`
on the eMMC otherwise. If U-Boot did not configure the PL,
`../linux/board/S15fpga` loads `/lib/firmware/rkz7100.bin`. That is worth
doing for more than the PL: the fan's pins are PL pins, so an unconfigured FPGA is a board with no
working fan (see the [fan controller design](../doc/hh-rk-zynq7100-design.md#2-fan-controller)), and the thermal zone has no cooling device
that reaches anything until a bitstream is in.

⚠ **Two different files are called `.bin`, and only one of them loads.**
`build.tcl` also asks `write_bitstream` for its own `-bin_file`, which is the
configuration data in Vivado's byte order; that file is copied out as
`<design>_raw.bin` precisely so it cannot be reached for by accident. Feeding
it to the FPGA manager gives

```
fpga_manager fpga0: Invalid bitstream, could not find a sync word.
                    Bitstream must be a byte swapped .bin file
```

which names the cause exactly. `bit2bin.py` takes the **`.bit`**.

⚠ **Give the design a moment before reading its status.** Reading the
`ddr/` design's `STATUS` immediately after the load returns `0x2` — MMCM
locked, calibration *not* complete — because MIG calibration is still running.
Three seconds later it reads `0x3`. A single read taken too early looks
exactly like a design that failed to calibrate.

⚠ **Do not touch the PL's address window before a bitstream is loaded.**
`devmem 0x80100000` with the PL unconfigured issues an AXI read that nothing
will ever answer, and the CPU hangs there — no oops, no console, no ping, and
the `reboot` you type next goes nowhere. Read
`/sys/class/fpga_manager/fpga0/state` and see `operating` first.

Recovering from it needs no hands on the board: reset it over JTAG, and the
BootROM boots again from whatever SW1 selects.

```
connect
targets -set -filter {jtag_cable_serial == "<serial>" && name =~ "APU*"}
rst -system
```

(in `xsdb`, which ships with Vivado; `jtag targets` lists each cable's serial.) ⚠ **With more than one
Zynq on the JTAG chain, the cable serial is not optional.** Filtering on
`name =~ "APU*"` alone then matches every Zynq's APU, and `rst -system` on the
wrong one resets another board in the middle of its work.

### Board tools

| | |
|---|---|
| [`tools/j8test.sh`](tools/j8test.sh) | walking ones across all 34 header pins |
| [`tools/bisttest.sh`](tools/bisttest.sh) | the AXI BIST engines: errors and MB/s |
| [`tools/hdmitest.sh`](tools/hdmitest.sh) | ADV7511 setup and status; `-f` tests with no cable |
| [`tools/hdmirxtest.sh`](tools/hdmirxtest.sh) | the capture path from three independent angles: the fabric's own measurements, the ADV7611 over I2C, and V4L2; `-c` captures frames |
| [`tools/cectest.sh`](tools/cectest.sh) | CEC over the HDMI loopback: sets the ADV7511's CEC up by hand, then allocates a logical address and reaches it from `/dev/cec0` |
| [`tools/gtxtest.sh`](tools/gtxtest.sh) | the SFP transceivers: PRBS-31 through near-end PMA loopback, then through the cable, with an injected error proving each end's pattern arrives at the other |
| [`tools/eth2test.sh`](tools/eth2test.sh) | the PL Ethernet port: with eth0 down, DHCP and ping at 1000, 100 and 10 Mb/s, and the core's view of each |
| [`tools/sfptest.sh`](tools/sfptest.sh) | the SFP cages' `TX_DISABLE` and `LOS`, and what their movement does or does not prove |
| [`tools/camtest.sh`](tools/camtest.sh) | the OV5647 on J9: every mode, the sensor's color bars, the receiver's damaged-packet counts, back-to-back restarts; `-t WxH [lane [hold]]` sweeps the D-PHY taps |
| [`tools/camsetup.sh`](tools/camsetup.sh) | sets the pad formats and the D-PHY tap for one mode (`camsetup.sh W H`) |
| [`tools/gen_j8_xdc.py`](tools/gen_j8_xdc.py) | regenerates the J8 pins from the master XDC; `--check` in the pre-commit hook |
| [`tools/gen_ip_stubs.py`](tools/gen_ip_stubs.py) | simulation stubs from each IP's `.veo` |

## Verification

Run from the repository root before a Vivado build:

```sh
pl/sim/run.sh
```

See the [simulation guide](sim/README.md) for optional lint, memory-inference,
and coverage checks, and the [design](../doc/hh-rk-zynq7100-design.md#verification)
for hardware validation status. Enable the commit hook with
`git config core.hooksPath .githooks`.

## License

See the repository [license](../README.md#license).

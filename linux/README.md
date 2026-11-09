# RK-ZYNQ7100 Linux

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

Buildroot support for U-Boot, Linux, and the RK-ZYNQ7100 root filesystem.

## Documentation

| Document | Contents |
|---|---|
| [Linux guide](../doc/linux-guide.md) | Build, boot, installation, drivers, and troubleshooting. |
| [PL design](../doc/hh-rk-zynq7100-design.md) | Hardware interfaces and validation status. |
| [Release guide](../doc/releasing.md) | Packaging and source-archive requirements. |

## Repository layout

| Path | Contents |
|---|---|
| `build.sh` | Buildroot download and build driver. |
| `gen_ps7.tcl`, `ps7_init_build.tcl` | Canonical PS7 boot-init generation, also invoked by PL builds. |
| `board/` | PS configuration, device trees, boot scripts, and patches. |
| `tools/` | JTAG boot and image helpers. |

## Requirements

Use the Linux host and versions listed in the root
[requirements](../README.md#requirements). Buildroot downloads its own source
dependencies. Under WSL, keep the build directory on the Linux filesystem.
SPL uses the tracked GPL-noticed C/H initialization sources and builds without
Vivado. JTAG boot additionally needs a locally generated `ps7_init.tcl`; both
PL builds generate it automatically. The [generation guide](../doc/linux-guide.md#regenerating-the-ps-init)
covers standalone generation and transfer between Windows and WSL.

## Getting started

Follow the [build procedure](../doc/linux-guide.md#build), then choose the
[SD-card](../doc/linux-guide.md#boot-from-an-sd-card),
[network](../doc/linux-guide.md#boot-over-the-network-jtag-then-tftp), or
[QSPI/eMMC](../doc/linux-guide.md#boot-from-qspi-and-emmc) boot procedure.
Read the selected procedure in full before writing an image; installation
can overwrite existing card, flash, or eMMC contents.

## Verification

Use the [peripheral checks](../doc/linux-guide.md#peripheral-support) and
[hardware validation record](../doc/hh-rk-zynq7100-design.md#verification)
to distinguish a built image from a tested boot path. Run
`python -m unittest discover -s linux/tests` from the repository root for the
PS7 generation and staging checks (Python with `tkinter`, and Git Bash on Windows). Run the
[PL gate](../pl/sim/README.md) after changes to hardware interfaces.

## License

The Linux support includes files with different licenses. See the root
[license and exceptions](../README.md#license) and each file's header.

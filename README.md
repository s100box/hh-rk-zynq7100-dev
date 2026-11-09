# hh-rk-zynq7100-dev

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

Constraints, hardware documentation, Linux support, and programmable-logic
designs for the RK-ZYNQ7100 board with an AMD Zynq-7000 `xc7z100ffg900-2`.
Its SFP+ ports can serve as a far end for the XCKU5P release tests.

Board listing: [RK-ZYNQ7100 on AliExpress](https://www.aliexpress.us/item/3256809053862199.html).

## Documentation

| Document | Contents |
|---|---|
| [Board guide](doc/RK_ZYNQ7100_User_Guide.md) | Hardware, pin provenance, electrical limits, and known issues. |
| [Design](doc/hh-rk-zynq7100-design.md) | PL architecture, registers, peripherals, and hardware validation. |
| [Coverage](doc/coverage.md) | Measured simulation baseline, source revisions, and uncovered cases. |
| [PL build guide](pl/README.md) | Synthesis, loading, and board-side test tools. |
| [Linux guide](linux/README.md) | Build and boot entry points. |
| [Simulation guide](pl/sim/README.md) | Benches, elaboration, lint, and coverage. |
| [Release guide](doc/releasing.md) | Packaging matching bitstreams, Linux images, and source archives. |
| [RTL style](https://github.com/s100box/retrosim-build/blob/main/doc/rtl-style.md) | Shared formatting, local lint exceptions, and checked scope. |

## Repository layout

| Path | Contents |
|---|---|
| `RK_ZYNQ7100_master.xdc` | Master constraints for PL pins. |
| `pl/board/`, `pl/ddr/` | Full board and memory-test designs. |
| `pl/sim/`, `pl/tools/` | Simulations and board-side checks. |
| `linux/` | Buildroot configuration, boot files, drivers, and patches. |
| `doc/` | Board, design, and release references. |
| `package.sh` | Release archive builder. |

## Requirements

### Tools

Versions are the ones everything here is built and run with.

| Tool | Version | For |
|---|---|---|
| AMD Vivado | 2026.1 | the PL designs (`pl/board`, `pl/ddr`), batch Tcl or a generated project for the GUI, and the PS init |
| Icarus Verilog | 14.0 (devel) | `pl/sim/run.sh`: every bench, and an elaboration of each top level against IP stubs |
| Verilator | 5.049 (devel), optional | `pl/sim/run.sh`: a lint of both top levels, skipped when `verilator_bin` is not on `PATH`; `pl/sim/cov.sh`: code coverage of the benches |
| Yosys | 0.65, optional | `pl/sim/run.sh`: a check that `fb_reader`'s line buffers synthesize to block RAM; skipped when `yosys` is not on `PATH` |
| Python | 3.13 | Simulation runner, boot-init cache, `pl/bit2bin.py`, stub/XDC/MIG generators; `tkinter` for the host tests |
| Rust | stable, optional | `hh-tftpd`'s standalone host server |
| Buildroot | 2025.02.6, fetched by `linux/build.sh` | U-Boot 2024.01 and Linux 6.6.70 (Xilinx forks), the root filesystem |
| A Linux host | Ubuntu 24.04 (under WSL): GCC 13.3, DTC 1.7.0, GNU Make 4.3 | `linux/build.sh` |

### Sibling repositories

Clone the shared build repository beside this checkout. PL sources, benches,
IP stubs and the JTAG loader remain local. `linux/build.sh` downloads Buildroot,
which fetches the kernel, U-Boot and the remaining Linux dependencies.

| Repository | Provides | Needed by |
|---|---|---|
| [retrosim-build](https://github.com/s100box/retrosim-build/blob/main/README.md) | Shared tools, manifest execution and Vivado Tcl primitives | PL builds, simulation and commit checks |
| `hh-xcku5p-dev` | optional: the XCKU5P board's design, whose QSFP28 port, through a QSFP+ to 4x SFP+ active optical cable, is a far end for this board's SFP cages (`ku5p.py qsfp-peer --zynq`). It runs on that board, so only that board needs it | the SFP-to-QSFP optical test only |
| [hh-tftpd](https://github.com/s100box/hh-tftpd/blob/main/README.md) | optional: standalone Rust TFTP host server | Network boot; any compatible TFTP server can substitute |

## Getting started

Run the verification gate below, then build the PL from `pl/`:

```sh
vivado -mode batch -nojournal -nolog -source board/build.tcl
```

The [PL build guide](pl/README.md#getting-started) describes output paths,
project generation, and loading through Linux. Follow the
[Linux guide](linux/README.md) to build and boot the operating system.

The [hardware validation record](doc/hh-rk-zynq7100-design.md#verification)
distinguishes tested boot paths and peripherals from remaining checks.
In particular, booting a card's kernel through QSPI U-Boot does not validate
BootROM boot from SD. The two USB connectors share one PHY: connect only one
at a time. An unconfigured PL leaves the fan off.

## Verification

From the repository root:

```sh
pl/sim/run.sh
python -m unittest discover -s linux/tests
```

The runner checks benches and top-level elaboration. Verilator lint and the
Yosys block-RAM check run when their tools are installed. See the
[simulation guide](pl/sim/README.md) for the complete scope and optional coverage.

Enable the hook with `git config core.hooksPath .githooks`. It checks staged
scripts and constraints, runs the PS7 generation/staging host tests, and runs the RTL gate when RTL or bench files change.

The host tests require Python's `tkinter` module; no display is needed. If the
CAD suite's Python lacks it, set `PYTHON3` to a native host Python with Tk before
committing (Bash: `export PYTHON3=/path/to/python`; PowerShell:
`$env:PYTHON3='C:/path/to/python.exe'`).

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT License ([LICENSE-MIT](LICENSE-MIT) or
  <http://opensource.org/licenses/MIT>)

at your option. Each source file says so in its `SPDX-License-Identifier`.

These are licensed differently, as their headers say:

- The device trees (`linux/board/*.dts`) are GPL-2.0 (the U-Boot one GPL-2.0+),
  like the kernel sources they include, and the kernel patches (`linux/board/patches/linux/`) are
  under the kernel's GPL-2.0.
- `linux/board/ps7_init_gpl.c` and `ps7_init_gpl.h` are generated by Vivado
  and are GPL-2.0-or-later, as Xilinx's notice in them and their SPDX line
  say. The XSDB `ps7_init.tcl` is generated locally during PL builds and is
  excluded from the current source tree and release archives. See
  [PS init generation](doc/linux-guide.md#regenerating-the-ps-init).
- `doc/*.csv` is board data from the vendor's documents.

### Contributions

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.

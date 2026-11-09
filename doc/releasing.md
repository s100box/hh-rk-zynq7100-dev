# hh-rk-zynq7100-dev release guide

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

`package.sh` builds the thing a user downloads: the sources as git has them,
the board bitstream (and the `ddr` one, with `--ddr`), the Linux images and a
README that says what to do with each.

```sh
sh package.sh --pl <pl/board build dir> --ddr <pl/ddr build dir> \
              --linux <buildroot output/images> \
              --legal <buildroot output/legal-info>
```

Build the artifacts from the same committed source revision that will be
archived. The source snapshot excludes external tools and `retrosim-build`;
the release README explains how to supply those dependencies beside `source/`.
The current source tree and release archives omit generated `ps7_init.tcl`.
Users regenerate it during the PL build or with the standalone
[PS7 generation command](linux-guide.md#regenerating-the-ps-init) for JTAG boot.

Run it where both sides are visible -- with Vivado on Windows and Buildroot in
WSL, that means WSL, where the Vivado output is under `/mnt/c`. The packaged
sources come from `git archive`, so there is no second file list to drift out
of step, and uncommitted work is left out with a warning rather than shipped.

⚠ Build Linux with `RKZ7100_BITSTREAM` set to the same bitstream as `--pl`.
The SD card image carries its own copy, and `package.sh` refuses a card whose
bitstream differs or is missing.

⚠ `--legal` matters. The kernel, U-Boot and BusyBox binaries are GPL, so a
release that carries them has to carry their sources too; `make legal-info`
in the Buildroot directory collects exactly that. Without it the script
warns, and the release is not one to publish.

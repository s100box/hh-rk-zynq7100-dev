#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Copy what the board fetches over TFTP -- and what JTAG boot loads -- into a
# TFTP root.
#
#   ./stage-tftp.sh <tftproot>
#
# No sudo and no repacking: Buildroot already produced the ramdisk as
# rootfs.cpio.uboot (see configs/rkz7100_defconfig).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tftproot="${1:?usage: stage-tftp.sh <tftproot>}"
IMAGES="${IMAGES:-${RKZ7100_WORK:-$HOME/rkz7100-linux}/buildroot/output/images}"

# ⚠ Every device tree the boot script can be pointed at. A tree that is built
# but not staged fails at the U-Boot prompt as a TFTP timeout, which reads as
# a network problem rather than a missing file.
files=(rkz7100-boot.scr uImage zynq-rkz7100.dtb zynq-rkz7100-usbdev.dtb
       zynq-rkz7100-hdmirx.dtb
       rootfs.cpio.uboot u-boot.bin boot.bin u-boot.img
       rootfs.ext4 ps7_init.tcl)   # eMMC filesystem and locally generated JTAG init
for f in "${files[@]}"; do
    if [ ! -f "$IMAGES/$f" ]; then
        echo "stage-tftp.sh: no $IMAGES/$f -- run build.sh" >&2
        if [ "$f" = ps7_init.tcl ]; then
            echo "JTAG init needs RKZ7100_PS7_INIT or the artifact beside RKZ7100_BITSTREAM" >&2
        fi
        exit 1
    fi
done

mkdir -p "$tftproot"
for f in "${files[@]}"; do
    cp -f "$IMAGES/$f" "$tftproot/$f"
    printf '  %-26s %10d bytes\n' "$f" "$(stat -c %s "$tftproot/$f")"
done

# ⚠ The ramdisk is loaded at 0x4000000 and must not run into U-Boot, which
# relocates below 0x40000000; that leaves ~950 MB, but a ramdisk over 200 MB
# is a mistake worth refusing.
bytes=$(stat -c %s "$tftproot/rootfs.cpio.uboot")
if [ "$bytes" -gt 200000000 ]; then
    echo "stage-tftp.sh: rootfs.cpio.uboot is $bytes bytes -- too big to netboot sensibly" >&2
    exit 1
fi
echo "== staged in $tftproot"

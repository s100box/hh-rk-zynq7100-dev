#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# After the images are built:
#   * compile the TFTP boot script (rkz7100-boot.scr),
#   * name the default device tree system.dtb for U-Boot's distro boot,
#   * assemble the SD card image, with the bitstream when there is one.
set -e

BOARD_DIR="$(dirname "$0")"
DTB=zynq-rkz7100.dtb

for f in "${DTB}" zynq-rkz7100-usbdev.dtb uImage rootfs.cpio.uboot u-boot.bin; do
    if [ ! -f "${BINARIES_DIR}/${f}" ]; then
        echo "post-image: ${BINARIES_DIR}/${f} is missing" >&2
        exit 1
    fi
done

"${HOST_DIR}/bin/mkimage" -A arm -O linux -T script -C none -n "rkz7100 TFTP boot" \
    -d "${BOARD_DIR}/rkz7100-boot.cmd" "${BINARIES_DIR}/rkz7100-boot.scr" >/dev/null

# Buildroot's board/zynq/post-image.sh derives this link from
# BR2_LINUX_KERNEL_INTREE_DTS_NAME, which is empty with a custom DTS -- so it
# would create nothing and genimage would fail on a missing file.
ln -sf "${DTB}" "${BINARIES_DIR}/system.dtb"
install -m 0644 -D "${BOARD_DIR}/extlinux.conf" "${BINARIES_DIR}/extlinux.conf"

# The bitstream, when build.sh was given one, goes on the card's FAT
# partition, where U-Boot's PREBOOT loads it on an SD boot. A copy left by an
# earlier build is removed first, so the card never carries a bitstream nobody
# asked for this time.
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
rm -f "${BINARIES_DIR}/rkz7100.bin" "${BINARIES_DIR}/genimage-bitstream.cfg"
if [ -n "${RKZ7100_BITSTREAM_BIN:-}" ]; then
    install -m 0644 "${RKZ7100_BITSTREAM_BIN}" "${BINARIES_DIR}/rkz7100.bin"
    GENIMAGE_CFG="${BINARIES_DIR}/genimage-bitstream.cfg"
    awk '{ if ($0 ~ /"uImage"$/) { print $0 ","; t = $0; sub(/uImage/, "rkz7100.bin", t); print t } else print }' \
        "${BOARD_DIR}/genimage.cfg" > "${GENIMAGE_CFG}"
    grep -q '"rkz7100.bin"' "${GENIMAGE_CFG}" || {
        echo "post-image: could not add rkz7100.bin to the genimage config" >&2
        exit 1
    }
fi

support/scripts/genimage.sh -c "${GENIMAGE_CFG}"

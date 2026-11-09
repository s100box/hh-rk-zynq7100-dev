# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# U-Boot script: boot Linux on the RK-ZYNQ7100 entirely over TFTP.
#
# Compiled to rkz7100-boot.scr by post-image.sh (mkimage -T script) and fetched
# by the default bootcmd (see uboot-rkz7100.fragment), or by hand:
#     setenv autoload no; dhcp; setenv serverip <tftp-server>
#     tftpboot 0x3000000 rkz7100-boot.scr; source 0x3000000
#
# Load map (1 GiB board; U-Boot has relocated to the top of DDR by now):
#     0x02000000  device tree
#     0x02080000  uImage (the kernel then relocates to 0x8000)
#     0x04000000  rootfs.cpio.uboot, the initramfs
#
# `setenv rkz7100_dtb zynq-rkz7100-usbdev.dtb` first to run USB0 as a device
# on the USB-C connector instead of a host on USB-A.

if test -z "${rkz7100_dtb}"; then setenv rkz7100_dtb zynq-rkz7100.dtb; fi
setenv bootargs console=ttyPS0,115200 earlycon rw
echo "rkz7100: fetching ${rkz7100_dtb}, uImage and rootfs.cpio.uboot from ${serverip}"
tftpboot 0x2000000 ${rkz7100_dtb} && tftpboot 0x2080000 uImage && tftpboot 0x4000000 rootfs.cpio.uboot && bootm 0x2080000 0x4000000 0x2000000
echo "rkz7100: TFTP boot failed -- check serverip, the firewall rule for the TFTP port, and the TFTP root"

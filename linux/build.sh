#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Build U-Boot and Linux for the RK-ZYNQ7100 (XC7Z100-2FFG900) with Buildroot.
#
# Produces, in $WORK/buildroot/output/images/:
#   sdcard.img              a complete bootable microSD image
#   boot.bin, u-boot.img    SPL + U-Boot for SD or QSPI boot
#   rootfs.ext4             the root filesystem, for the eMMC
#   u-boot.bin              JTAG-load this (tools/bootuboot.tcl) for a network boot
#   rkz7100-boot.scr        the TFTP boot script U-Boot's bootcmd then fetches
#   uImage, zynq-rkz7100{,-usbdev,-hdmirx}.dtb, rootfs.cpio.uboot
#                           what that script fetches
#
# Needs a Linux host; on Windows, WSL:
#     wsl -e bash -lc '/mnt/c/<path to>/linux/build.sh'
#
# Environment:
#   RKZ7100_BITSTREAM  a PL bitstream (.bit or fpga_manager .bin) to put on the
#                      SD card, where U-Boot loads it before Linux starts
#                      (default none: the card boots with the PL unconfigured)
#   RKZ7100_PS7_INIT optional locally generated ps7_init.tcl for JTAG boot;
#                      otherwise discovered beside RKZ7100_BITSTREAM
#   TFTP_SERVER   the TFTP server a JTAG boot fetches from (default: the one
#                 the DHCP lease names)
#   TFTP_PORT     its UDP port, when something else owns 69 (default 69)
#   RKZ7100_WORK  the build directory, in the Linux fs     (default ~/rkz7100-linux)
#   BUILDROOT_VERSION  the Buildroot tag to clone          (default 2025.02.6)
#   BR2_DL_DIR    the download cache                       (default $RKZ7100_WORK/dl)
#   JOBS          parallel make jobs                       (default nproc)
set -euo pipefail

# Buildroot refuses a PATH containing spaces, and WSL inherits the Windows one.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD="$HERE/board"
WORK="${RKZ7100_WORK:-$HOME/rkz7100-linux}"
BUILDROOT_VERSION="${BUILDROOT_VERSION:-2025.02.6}"
BR="$WORK/buildroot"
JOBS="${JOBS:-$(nproc)}"
TFTP_SERVER="${TFTP_SERVER:-}"
TFTP_PORT="${TFTP_PORT:-69}"
export BR2_DL_DIR="${BR2_DL_DIR:-$WORK/dl}"

case "$WORK" in
  /mnt/*) echo "refusing to build under $WORK -- use the Linux filesystem (9p is slow and case-folds)" >&2
          exit 1 ;;
esac
case "$TFTP_SERVER" in
  *[!0-9.]*) echo "TFTP_SERVER must be a dotted IPv4 address, not '$TFTP_SERVER'" >&2; exit 1 ;;
esac
case "$TFTP_PORT" in
  *[!0-9]*|"") echo "TFTP_PORT must be a number, not '$TFTP_PORT'" >&2; exit 1 ;;
esac

for f in ps7_init_gpl.c ps7_init_gpl.h zynq-rkz7100.dts zynq-rkz7100-usbdev.dts \
         zynq-rkz7100-hdmirx.dts \
         zynq-rkz7100-uboot.dts linux-rkz7100.fragment uboot-rkz7100.fragment \
         rkz7100-boot.cmd post-build.sh post-image.sh genimage.cfg extlinux.conf; do
  [ -f "$BOARD/$f" ] || { echo "missing board file: $BOARD/$f" >&2; exit 1; }
done

mkdir -p "$WORK/gen"
# Freeze the optional JTAG artifact before the long Linux build. It is generated
# by Vivado, not copied from the source tree. No Tcl is needed by U-Boot SPL.
ps7_args=()
[ -z "${RKZ7100_PS7_INIT:-}" ] || ps7_args+=(--init "$RKZ7100_PS7_INIT")
[ -z "${RKZ7100_BITSTREAM:-}" ] || ps7_args+=(--bitstream "$RKZ7100_BITSTREAM")
python3 "$HERE/tools/stage_ps7.py" "$WORK/gen" "${ps7_args[@]}"

# The bitstream for the SD card. post-image.sh puts whatever is at
# $RKZ7100_BITSTREAM_BIN on the card's FAT partition, and removes a stale one
# when it is unset. A .bit is converted here, because fpga_manager and U-Boot's
# `fpga load` both want the byte-swapped, header-less form.
rm -f "$WORK/gen/rkz7100.bin"
if [ -n "${RKZ7100_BITSTREAM:-}" ]; then
  [ -f "$RKZ7100_BITSTREAM" ] || { echo "no bitstream at $RKZ7100_BITSTREAM" >&2; exit 1; }
  case "$RKZ7100_BITSTREAM" in
    *.bit) python3 "$HERE/../pl/bit2bin.py" "$RKZ7100_BITSTREAM" "$WORK/gen/rkz7100.bin" ;;
    *)     cp "$RKZ7100_BITSTREAM" "$WORK/gen/rkz7100.bin" ;;
  esac
  export RKZ7100_BITSTREAM_BIN="$WORK/gen/rkz7100.bin"
else
  unset RKZ7100_BITSTREAM_BIN
fi

if [ ! -d "$BR" ]; then
  echo "==> cloning Buildroot $BUILDROOT_VERSION"
  git clone --depth 1 --branch "$BUILDROOT_VERSION" \
      https://gitlab.com/buildroot.org/buildroot.git "$BR"
fi

# Buildroot resolves BR2_* paths against its own tree and U-Boot resolves
# CONFIG_XILINX_PS_INIT_FILE against its srctree: both need absolute paths.
# The TFTP server, when one is named, goes into U-Boot's default bootcmd.
if [ -n "$TFTP_SERVER" ]; then SET_SERVERIP="setenv serverip $TFTP_SERVER; "; else SET_SERVERIP=""; fi
echo "==> generating defconfig and fragments (TFTP server ${TFTP_SERVER:-from DHCP}:$TFTP_PORT, downloads in $BR2_DL_DIR)"
sed -e "s#@PS7_INIT_C@#$BOARD/ps7_init_gpl.c#g" -e "s#@SET_SERVERIP@#$SET_SERVERIP#g" \
    -e "s#@TFTP_PORT@#$TFTP_PORT#g" \
    "$BOARD/uboot-rkz7100.fragment" > "$WORK/gen/uboot-rkz7100.fragment"
sed -e "s#@BOARD@#$BOARD#g" -e "s#@UBOOT_FRAGMENT@#$WORK/gen/uboot-rkz7100.fragment#g" \
    "$HERE/configs/rkz7100_defconfig" > "$BR/configs/rkz7100_defconfig"

cd "$BR"
echo "==> configuring"
make rkz7100_defconfig

# Buildroot drops any symbol whose dependencies are unmet, without a word. Every
# line the defconfig sets must appear verbatim in the resolved .config.
dropped="$(grep -v '^#' configs/rkz7100_defconfig | grep '=' | grep -vxF -f .config || true)"
if [ -n "$dropped" ]; then
  echo "Buildroot dropped these defconfig settings (unmet dependencies):" >&2
  echo "$dropped" | sed 's/^/    /' >&2
  exit 1
fi

# U-Boot needs its device tree inside its own tree, registered in the dts
# Makefile, and ps7_init_gpl.h beside the init source it compiles. Extract,
# drop the files in, then build. (Idempotent: re-running just re-copies.)
echo "==> placing the U-Boot device tree"
make uboot-extract
UB="$(echo "$BR"/output/build/uboot-*)"
[ -d "$UB" ] || { echo "u-boot source not found" >&2; exit 1; }
cp "$BOARD/zynq-rkz7100-uboot.dts" "$UB/arch/arm/dts/zynq-rkz7100.dts"
cp "$BOARD/ps7_init_gpl.h" "$UB/board/xilinx/zynq/ps7_init_gpl.h"
if ! grep -q 'zynq-rkz7100.dtb' "$UB/arch/arm/dts/Makefile"; then
  sed -i 's#^dtb-$(CONFIG_ARCH_ZYNQ) += \\#dtb-$(CONFIG_ARCH_ZYNQ) += \\\n\tzynq-rkz7100.dtb \\#' \
      "$UB/arch/arm/dts/Makefile"
  grep -q 'zynq-rkz7100.dtb' "$UB/arch/arm/dts/Makefile" \
    || { echo "failed to register zynq-rkz7100.dtb in the U-Boot dts Makefile" >&2; exit 1; }
fi
# A changed board file must reach an already-built U-Boot or kernel. Buildroot
# only re-runs a package whose stamps are gone, and it cannot see that a file
# outside its tree (a DTS, a fragment, the PS init) changed -- so when anything
# under board/ is newer than a package's build stamp, drop that package's
# stamps and let it reconfigure and rebuild.
# (A custom-tarball kernel builds in output/build/linux-custom.)
for pkg in "$UB" "$BR/output/build/linux-custom"; do
  [ -f "$pkg/.stamp_built" ] || continue
  if [ -n "$(find "$BOARD" -newer "$pkg/.stamp_built" -print -quit)" ]; then
    echo "==> board files changed since $(basename "$pkg") was built; rebuilding it"
    rm -f "$pkg"/.stamp_built "$pkg"/.stamp_target_installed "$pkg"/.stamp_images_installed \
          "$pkg"/.stamp_configured "$pkg"/.stamp_kconfig_fixup_done "$pkg"/.stamp_installed
  fi
done

# ⚠ A changed kernel PATCH needs more than that. Buildroot applies patches
# once, when it extracts the source, and dropping the build stamps above
# rebuilds the already-patched tree -- so an edited patch would never reach
# the kernel, and the build would still succeed. Re-extract instead.
lk="$BR/output/build/linux-custom"
if [ -f "$lk/.stamp_patched" ] &&
   [ -n "$(find "$BOARD/patches/linux" -newer "$lk/.stamp_patched" -print -quit)" ]; then
  echo "==> a kernel patch changed since the kernel was patched; re-extracting it"
  make linux-dirclean
fi

echo "==> building (-j$JOBS)"
make "-j$JOBS"

# Prove the two board inputs actually reached U-Boot, rather than trusting the
# fragment: the PS init object only exists when XILINX_PS_INIT_FILE was
# honored, and the bootcmd must carry the server we asked for -- or none.
grep -q "^CONFIG_XILINX_PS_INIT_FILE=\"$BOARD/ps7_init_gpl.c\"" "$UB/.config" \
  || { echo "U-Boot .config does not point XILINX_PS_INIT_FILE at our ps7_init_gpl.c" >&2; exit 1; }
[ -f "$UB/spl/board/xilinx/zynq/ps_init_gpl.o" ] \
  || { echo "SPL did not compile our PS init (no spl/board/xilinx/zynq/ps_init_gpl.o)" >&2; exit 1; }
grep -q "setenv tftpdstp $TFTP_PORT; if dhcp; then ${SET_SERVERIP}if tftpboot" "$UB/.config" \
  || { echo "U-Boot bootcmd does not carry TFTP server ${TFTP_SERVER:-from DHCP}:$TFTP_PORT" >&2; exit 1; }

# ⚠ And prove the DEVICE TREE was rebuilt, not just the config.
#
# U-Boot's dtb rule prints "Check .../.<name>.dtb.pre.tmp for errors" and
# leaves the previous dtb in place when the DTS fails to compile, and
# Buildroot's uboot step still returns 0. Every check above reads .config, so a
# stale dtb passes them all. A stale dtb is older than its source, so test
# that.
ub_dts="$UB/arch/arm/dts/zynq-rkz7100.dts"
ub_dtb="$UB/arch/arm/dts/zynq-rkz7100.dtb"
[ -f "$ub_dtb" ] || { echo "U-Boot device tree was never compiled: no $ub_dtb" >&2; exit 1; }
[ "$ub_dtb" -nt "$ub_dts" ]   || { echo "U-Boot device tree is STALE: $ub_dtb is older than $ub_dts -- the DTS failed to compile and the old dtb was kept. Look for 'Check .*.pre.tmp for errors' in the build output." >&2; exit 1; }
[ "$UB/u-boot.bin" -nt "$ub_dts" ]   || { echo "u-boot.bin is older than the device tree it should contain" >&2; exit 1; }

# kconfig, like Buildroot, drops a fragment line whose dependencies are unmet
# and says nothing. Every CONFIG_ line of both fragments must be in the result.
for pair in "$BOARD/linux-rkz7100.fragment:$BR/output/build/linux-custom/.config" \
            "$WORK/gen/uboot-rkz7100.fragment:$UB/.config"; do
  frag="${pair%%:*}"; cfg="${pair#*:}"
  lost="$(grep -E '^CONFIG_' "$frag" | grep -vxF -f "$cfg" || true)"
  if [ -n "$lost" ]; then
    echo "$(basename "$frag"): these settings did not reach $cfg:" >&2
    echo "$lost" | sed 's/^/    /' >&2
    exit 1
  fi
done

# Buildroot does NOT rebuild a package when only one of its sub-options changes
# -- turning on BR2_PACKAGE_E2FSPROGS_RESIZE2FS after e2fsprogs was already
# built leaves the old install in place, silently, and the eMMC root then can
# never be grown past the size of rootfs.ext4. Check the tool that matters.
[ -x "$BR/output/target/sbin/resize2fs" ]   || { echo "resize2fs is missing from the rootfs -- 'make e2fsprogs-dirclean' and rebuild" >&2; exit 1; }

echo
# Avoid carrying a previous build's JTAG init into images when none was selected.
if [ -f "$WORK/gen/ps7_init.tcl" ]; then
    python3 "$HERE/tools/stage_ps7.py" "$BR/output/images" --init "$WORK/gen/ps7_init.tcl"
else
    python3 "$HERE/tools/stage_ps7.py" "$BR/output/images"
fi
echo "==> images"
ls -l output/images/
cat <<EOF

Next, either:
  * SD card: write output/images/sdcard.img to a card, set SW1 to SD (both
    switches OFF) and power up. See linux/README.md, "Boot from an SD card".
  * Network: copy the images into a TFTP root with
       $HERE/stage-tftp.sh <tftproot>
    serve it, set SW1 to JTAG (both ON), and JTAG-load U-Boot:
       xsdb $HERE/tools/bootuboot.tcl <tftproot>/ps7_init.tcl <tftproot>/u-boot.bin [cable-serial]
    It then boots Linux over TFTP by itself.
EOF

#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Build a release: the sources as git has them, the two bitstreams, the Linux
# images, and a README with operating and rebuilding instructions. Rebuilding
# also requires the external tools and retrosim-build sibling named there.
#
#   sh package.sh --pl <dir> [--ddr <dir>] --linux <dir> [--legal <dir>] \
#                 [--out <dir>] [--version <name>]
#
#   --pl      a finished pl/board build directory (rkz7100_pl.bit inside)
#   --ddr     a finished pl/ddr build directory; optional, and left out of
#             the release if not given
#   --linux   Buildroot's output/images
#   --legal   Buildroot's output/legal-info, the GPL source bundle (below)
#   --out     where to write; default ./release
#   --version names the directory and the archive; default the git describe
#
# Relative paths are taken from the directory the script is run from.
#
# ⚠ RUN IT WHERE BOTH SIDES ARE VISIBLE. The bitstreams are built by Vivado
# on Windows and the images by Buildroot in WSL, so on a Windows host run
# it from WSL, where the Vivado output is under /mnt/c.
#
# ⚠ THE SOURCES COME FROM `git archive`, not from a list kept here. A second
# list is a list that drifts: the packaged tree is exactly what is committed,
# so what a user builds is what was tested. Uncommitted work is NOT packaged,
# and the script says so rather than quietly shipping HEAD.
#
# ⚠ GPL. The kernel, U-Boot and BusyBox binaries in a release oblige you to
# offer their sources. `make legal-info` in the Buildroot directory writes
# exactly that bundle; pass it with --legal and it ships beside them. Without
# it the script warns, and the release is not one you should publish.
#
#   export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#   make -C ~/rkz7100-linux/buildroot legal-info
#
# ⚠ That PATH line is not decoration: Buildroot refuses to run at all when
# PATH holds a space, and WSL inherits the Windows one. Without it the make
# stops at "Your PATH contains spaces" and leaves a legal-info directory
# holding the manifests but none of the sources -- which looks like a bundle
# and is not one. linux/build.sh sets the same PATH for the same reason.

set -eu

PL=""; DDR=""; LINUX=""; LEGAL=""; OUT="release"; VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pl)      PL=$2;      shift 2 ;;
        --ddr)     DDR=$2;     shift 2 ;;
        --linux)   LINUX=$2;   shift 2 ;;
        --legal)   LEGAL=$2;   shift 2 ;;
        --out)     OUT=$2;     shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        -h|--help) sed -n '5,35p' "$0"; exit 0 ;;
        *) echo "package.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

# Every path argument is taken relative to where the script was run from,
# before it moves to the repository for git.
abspath() { case "$1" in ""|/*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
PL=$(abspath "$PL"); DDR=$(abspath "$DDR"); LINUX=$(abspath "$LINUX")
LEGAL=$(abspath "$LEGAL"); OUT=$(abspath "$OUT")

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

die()  { echo "package.sh: $*" >&2; exit 1; }
warn() { echo "package.sh: ⚠ $*" >&2; }
say()  { echo "== $*"; }

[ -n "$PL" ]    || die "--pl is required (a finished pl/board build directory)"
[ -n "$LINUX" ] || die "--linux is required (Buildroot's output/images)"
[ -f "$PL/rkz7100_pl.bit" ] || die "no rkz7100_pl.bit in $PL"
[ -f "$LINUX/uImage" ]      || die "no uImage in $LINUX"

# The release names itself after the commit it was cut from, so a bug report
# can be traced to a tree.
[ -n "$VERSION" ] || VERSION=$(git describe --tags --always --dirty)
[ -z "$(git status --porcelain)" ] ||
    warn "the working tree has uncommitted changes; they are NOT in this release"

REL="$OUT/rkz7100-$VERSION"
rm -rf "$REL"
mkdir -p "$REL/bitstreams" "$REL/linux" "$REL/source"

# ---------------------------------------------------------------- sources
say "sources, from git"
git archive --format=tar HEAD | tar -x -C "$REL/source"
git rev-parse HEAD > "$REL/source/GIT_COMMIT"

# ------------------------------------------------------------- bitstreams
# Both formats: .bit for JTAG and Vivado, .bin for Linux's fpga_manager,
# which takes a different byte order -- bit2bin.py is what turns one into
# the other, and it is in the sources.
say "bitstreams"
cp "$PL/rkz7100_pl.bit" "$REL/bitstreams/rkz7100-board.bit"
python3 pl/bit2bin.py "$PL/rkz7100_pl.bit" "$REL/bitstreams/rkz7100-board.bin" >/dev/null
if [ -n "$DDR" ]; then
    [ -f "$DDR/rkz7100_ddr.bit" ] || die "no rkz7100_ddr.bit in $DDR"
    cp "$DDR/rkz7100_ddr.bit" "$REL/bitstreams/rkz7100-ddr.bit"
    python3 pl/bit2bin.py "$DDR/rkz7100_ddr.bit" "$REL/bitstreams/rkz7100-ddr.bin" >/dev/null
fi
for f in "$PL/timing.txt" "$PL/utilization.txt"; do
    [ -f "$f" ] && cp "$f" "$REL/bitstreams/board-$(basename "$f")"
done

# ⚠ The SD card image carries its own copy of the bitstream (build.sh's
# RKZ7100_BITSTREAM), and U-Boot loads that one on an SD boot. A release whose
# card holds a different bitstream from bitstreams/ -- or none -- boots a
# design nobody tested with these images, so it is refused.
if [ -f "$LINUX/sdcard.img" ]; then
    [ -f "$LINUX/rkz7100.bin" ] ||
        die "sdcard.img carries no bitstream -- rebuild Linux with RKZ7100_BITSTREAM=$PL/rkz7100_pl.bit"
    cmp -s "$LINUX/rkz7100.bin" "$REL/bitstreams/rkz7100-board.bin" ||
        die "the bitstream on sdcard.img is not $PL/rkz7100_pl.bit -- rebuild Linux with RKZ7100_BITSTREAM=$PL/rkz7100_pl.bit"
fi

# ------------------------------------------------------------------ Linux
say "Linux images"
for f in boot.bin u-boot.img u-boot.bin uImage rootfs.cpio.uboot rootfs.ext4 sdcard.img \
         zynq-rkz7100.dtb zynq-rkz7100-hdmirx.dtb zynq-rkz7100-usbdev.dtb \
         rkz7100-boot.scr; do
    if [ -f "$LINUX/$f" ]; then cp "$LINUX/$f" "$REL/linux/"
    else warn "no $f in $LINUX"; fi
done

# ⚠ The two disk images are mostly empty space. They are sparse where they
# are built and stop being sparse the moment they are copied to another
# filesystem, so they are gzipped here: half a gigabyte of rootfs becomes
# tens of megabytes, and `zcat rootfs.ext4.gz > /dev/...` writes it back.
for f in sdcard.img rootfs.ext4; do
    [ -f "$REL/linux/$f" ] && gzip -9 "$REL/linux/$f"
done

# ⚠ The GPL bundle is a SEPARATE archive, not part of the release directory.
# It is several times the size of everything else, and the obligation is to offer the sources alongside the binaries,
# not to make everyone download them. Publish both, and keep them together.
GPL=""
if [ -n "$LEGAL" ]; then
    say "GPL source bundle"
    [ -d "$LEGAL" ] || die "no such legal-info directory: $LEGAL"
    [ -d "$LEGAL/sources" ] || die "$LEGAL holds no sources/ -- see the PATH note above"
    GPL="$OUT/rkz7100-$VERSION-gpl-sources.tar.gz"
    tar -C "$(dirname "$LEGAL")" -czf "$GPL" "$(basename "$LEGAL")"
    cp "$LEGAL/manifest.csv" "$REL/linux/gpl-manifest.csv"
else
    warn "no --legal bundle: the GPL binaries in linux/ ship without their sources"
fi

# --------------------------------------------------------------- the README
say "README"
# The template's comment header explains the substitutions to whoever edits
# it; the reader of a release does not need it, so it is dropped here.
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@COMMIT@/$(git rev-parse --short HEAD)/g" \
    -e '1,/-->/d' \
    doc/RELEASE_README.in > "$REL/README.md"

# ------------------------------------------------------------- the manifest
# One checksum file over everything, so a download can be checked and a
# support question can start from "which file differs".
say "checksums"
( cd "$REL" && find . -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )

if command -v tar >/dev/null 2>&1; then
    say "archive"
    ( cd "$OUT" && tar -czf "rkz7100-$VERSION.tar.gz" "rkz7100-$VERSION" )
fi

echo
echo "release: $REL"
du -sh "$REL" 2>/dev/null || true
[ -f "$OUT/rkz7100-$VERSION.tar.gz" ] && du -sh "$OUT/rkz7100-$VERSION.tar.gz"
[ -n "$GPL" ] && du -sh "$GPL"
[ -n "$GPL" ] || warn "without the GPL sources this release is not one to publish"
exit 0

#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Check the PL DDR3 came up, then hand over to memtest for the real work.
# Run it on the board with either design's bitstream loaded:
#
#     sh test-ddr.sh                     # the ddr design
#     sh test-ddr.sh -b 0x80100000       # the full design
#
# PL DRAM: 1 GB at 0x4000_0000 (M_AXI_GP0) in both.
set -e

REGS=0x80000000
[ "${1:-}" = "-b" ] && { REGS=$2; shift 2; }

say() { echo "== $*"; }

id=$(devmem $((REGS + 0x00)) 32)
status=$(devmem $((REGS + 0x14)) 32)
echo "   ID     $id   (expect 0x5A710002)"
echo "   STATUS $status   (expect bits [1:0] set: calibrated + MIG MMCM locked)"

case "$id" in
    0x5A710002) ;;
    *) echo "!! wrong ID -- is the ddr bitstream loaded?" >&2; exit 1 ;;
esac

# Report the two status bits apart. "The MMCM never locked" and "calibration
# failed" have nothing to do with each other: the first is the 200 MHz
# oscillator or its pins, the second is the DDR3 interface itself.
locked=$(( ($status >> 1) & 1 ))
calib=$(( $status & 1 ))
[ "$locked" = 1 ] || { echo "!! MIG MMCM did not lock -- check SYS_CLK (F9/E8)" >&2; exit 1; }
[ "$calib"  = 1 ] || { echo "!! DDR3 calibration did not complete" >&2; exit 1; }
say "MIG calibrated"

say "single-word access through /dev/mem"
devmem 0x40000000 32 0xA5A5A5A5
devmem 0x40000004 32 0x5A5A5A5A
a=$(devmem 0x40000000 32)
b=$(devmem 0x40000004 32)
echo "   0x40000000 = $a   0x40000004 = $b"
[ "$a" = "0xA5A5A5A5" ] && [ "$b" = "0x5A5A5A5A" ] \
    || { echo "!! readback mismatch" >&2; exit 1; }

# ⚠ Do NOT reach for `dd if=/dev/mem bs=1M skip=1024` here. It fails with
# "Bad address" and moves zero records: /dev/mem's read()/write() path goes
# through xlate_dev_mem_ptr(), which returns NULL for a physical address that
# is not kernel RAM, so the copy gets -EFAULT. mmap() of the same range works,
# which is why `devmem` above is fine. Anything bulk has to mmap -- hence
# memtest, cross-compiled from memtest.c with the Buildroot toolchain:
#
#   arm-buildroot-linux-gnueabihf-gcc -O2 -static -o memtest memtest.c
if [ -x ./memtest ]; then
    MT=./memtest
elif [ -x /root/memtest ]; then
    MT=/root/memtest
else
    echo "   (memtest not found -- registers and single words checked only)"
    exit 0
fi

say "handing over to memtest"
exec "$MT"

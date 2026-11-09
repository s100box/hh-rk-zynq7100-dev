#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Walking-ones test of the 40-pin header J8 on the RK-ZYNQ7100.
#
# Drives each of the 34 pins through the Linux GPIO interface, then reads the
# PS GPIO DATA_RO registers back -- the actual pin level, through the IOBUF,
# not the value that was written. One pin high and 33 low at every step, so
# two EMIO bits landing on one pad, a pad stuck high or low, and a pin that
# does not respond at all are all visible.
#
# ⚠ What this CANNOT catch: a consistent permutation. The write and the
# readback take the same path, so if the bit order were reversed end to end
# this would still pass. Only a wire between two known header pins settles
# which physical pin is which -- see linux/README.md.
#
# sysfs gpio 584..617 = gpiochip0 lines 72..105 (the chip's base is 512)
# = EMIO 18..51 = j8[0..33].
#   j8[0..13]  -> bank 2 bits 18..31   (DATA_RO 0xE000A068)
#   j8[14..33] -> bank 3 bits 0..19    (DATA_RO 0xE000A06C)

set -u

FIRST=584
N=34
SYS=/sys/class/gpio
B2_RO=0xE000A068
B3_RO=0xE000A06C

die() { echo "j8test: $*" >&2; exit 1; }

[ -d "$SYS" ] || die "no $SYS -- CONFIG_GPIO_SYSFS is off"

# Bail out early if the PL is not configured: every J8 pin is a PL pin, and
# without a bitstream the EMIO signals go nowhere.
state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager state is '$state', not 'operating' -- load a bitstream first"

i=0
while [ $i -lt $N ]; do
    g=$((FIRST + i))
    [ -d "$SYS/gpio$g" ] || echo $g > $SYS/export 2>/dev/null
    [ -d "$SYS/gpio$g" ] || die "cannot export gpio $g"
    echo out > $SYS/gpio$g/direction || die "cannot set gpio $g to output"
    echo 0 > $SYS/gpio$g/value
    i=$((i + 1))
done

# The 34 J8 pin levels, read back through the IOBUFs; j8[0] in bit 0
read_pins() {
    v2=$(devmem $B2_RO 32)
    v3=$(devmem $B3_RO 32)
    # mask down to the J8 bits: bank2 [31:18], bank3 [19:0]
    p2=$(( (v2 >> 18) & 0x3FFF ))
    p3=$(( v3 & 0xFFFFF ))
    # 34-bit value, j8[0] in the low bit
    echo $(( p2 | (p3 << 14) ))
}

fails=0
i=0
while [ $i -lt $N ]; do
    g=$((FIRST + i))
    echo 1 > $SYS/gpio$g/value
    got=$(read_pins)
    want=$(( 1 << i ))
    if [ "$got" != "$want" ]; then
        printf 'FAIL  j8[%2d] gpio %d: pins=0x%09X expected 0x%09X\n' \
               "$i" "$g" "$got" "$want"
        fails=$((fails + 1))
    fi
    echo 0 > $SYS/gpio$g/value
    i=$((i + 1))
done

# All low, then all high: catches a pin that only ever reads one way.
allzero=$(read_pins)
[ "$allzero" = "0" ] || { printf 'FAIL  all-low readback 0x%09X, expected 0\n' "$allzero"; fails=$((fails + 1)); }

i=0
while [ $i -lt $N ]; do echo 1 > $SYS/gpio$((FIRST + i))/value; i=$((i + 1)); done
allone=$(read_pins)
want=$(( (1 << N) - 1 ))
[ "$allone" = "$want" ] || { printf 'FAIL  all-high readback 0x%09X, expected 0x%09X\n' "$allone" "$want"; fails=$((fails + 1)); }

# Leave every pin an input: that is the safe state for a header, and it is
# what the bitstream comes up in.
i=0
while [ $i -lt $N ]; do
    g=$((FIRST + i))
    echo 0 > $SYS/gpio$g/value
    echo in > $SYS/gpio$g/direction
    echo $g > $SYS/unexport 2>/dev/null
    i=$((i + 1))
done

if [ $fails -eq 0 ]; then
    echo "j8test: PASS -- 34 pins, walking ones + all-low + all-high"
else
    echo "j8test: FAIL -- $fails check(s) failed"
fi
exit $fails

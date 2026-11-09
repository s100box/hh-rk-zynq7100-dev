#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Exercise HDMI CEC across the board's own HDMI out -> HDMI in loopback.
#
# This needs an HDMI cable between HDMI1 (out) and HDMI2 (in), and the cable
# must carry pin 13. Only the RECEIVER is a Linux CEC device: the ADV7611 is
# driven by the adv7604 driver and appears as /dev/cec0. The ADV7511 on the
# transmit side has no driver here -- its CEC lives in a DRM bridge driver
# that needs a DRM pipeline, and this board has none -- so this script
# configures the transmitter by hand over I2C and then drives the link from
# the receiver's Linux CEC adapter.
#
# ⚠ THERE IS ONLY ONE PULL-UP ON THIS BUS. R179, 27K to +3.3V through the
# Schottky D5, sits on the TRANSMIT connector; the ADV7611 end has none of its
# own. So the receiver can only talk at all when the cable joins pin 13
# through, and "the receiver cannot transmit" is a cable symptom before it is
# a chip symptom.
#
# ⚠ THE ADV7611's INTERRUPT IS NOT WIRED on this board (known issue 10 in
# doc/RK_ZYNQ7100_User_Guide.md; INT1, pin 55, is a
# bare stub, and so are the alternate INT2 outputs on 49 and 51). Stock
# adv7604.c reaches cec_transmit_done() only from its interrupt handler, so
# without the polling patch in linux/board/patches/linux every CEC frame is
# sent and acknowledged on the wire while the kernel is never told, and each
# transmit times out with
#
#     cec-1-004c: message 00 timed out
#
# leaving the adapter Not Allocated. If this script fails at the allocation
# step, check that the running kernel carries that patch -- the boot log says
#     adv7611 1-004c: no interrupt wired, polling status every 20 ms
# -- before suspecting the cable or the chips.
#
# Usage:  cectest.sh

set -u

TXBUS=0          # i2c-hdmi-tx, the ADV7511
TXMAIN=0x39
TXCEC=0x3c       # main map 0xE1 holds this address in its 8-bit form
TXLA=4           # the transmitter answers as Playback Device 1
SUBDEV=/dev/v4l-subdev0

die() { echo "cectest: $*" >&2; exit 1; }

[ -c /dev/cec0 ] || die "no /dev/cec0 -- needs CONFIG_VIDEO_ADV7604_CEC and a probed ADV7611 (known issue 12 in doc/RK_ZYNQ7100_User_Guide.md: it can wedge until a power cycle)"
command -v cec-ctl >/dev/null 2>&1 || die "no cec-ctl"

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager is '$state' -- both I2C buses are PL pins"

echo "=== 1. the receiver needs a physical address, which comes from its EDID"
# Writing an EDID also asserts HPD, which is what makes the source start up.
v4l2-ctl -d $SUBDEV --set-edid=edid=hdmi >/dev/null 2>&1 \
    || die "could not write the EDID to $SUBDEV"
pa=$(cec-ctl -d /dev/cec0 2>/dev/null | sed -n 's/.*Physical Address *: *//p')
echo "    physical address: $pa"
[ "$pa" = "f.f.f.f" ] && die "physical address still invalid after the EDID write"

echo "=== 2. bring up the ADV7511's CEC by hand (no Linux driver on this side)"
# Values follow adv7511-v4l2.c exactly:
#   main 0xE1   = CEC map address, 8-bit form
#   CEC  0x4E   = [7:2] clock divider, bit 0 powers the section up.
#                 Y10 is 12 MHz, and the driver's own formula is
#                 ((freq / 750000) - 1) << 2 = 15 << 2 = 0x3C.
#   CEC  0x4A   = legacy mode, then clear all rx buffers
#   CEC  0x4B/0x4C = enable address mask 0, and the address for it
#   CEC  0x12   = [6:4] retry count
i2cset -y -f $TXBUS $TXMAIN 0xe1 0x78    # CEC map -> 7-bit 0x3C
i2cset -y -f $TXBUS $TXCEC  0x4e 0x3c    # clock divider, still powered down
i2cset -y -f $TXBUS $TXCEC  0x4e 0x3d    # ... and power it up
i2cset -y -f $TXBUS $TXCEC  0x4a 0x00
i2cset -y -f $TXBUS $TXCEC  0x4a 0x07
i2cset -y -f $TXBUS $TXCEC  0x11 0x00    # tx disabled until we ask for it
i2cset -y -f $TXBUS $TXCEC  0x4b 0x10    # address mask 0 on
i2cset -y -f $TXBUS $TXCEC  0x4c $TXLA
i2cset -y -f $TXBUS $TXCEC  0x12 0x30
got=$(i2cget -y -f $TXBUS $TXCEC 0x4e)
[ "$got" = "0x3d" ] || die "ADV7511 CEC 0x4e reads $got, expected 0x3d -- is the chip alive?"
echo "    ADV7511 CEC up, answering as logical address $TXLA"

echo "=== 3. allocate a logical address for the receiver"
# ⚠ This is the step that fails on an unpatched kernel. A NACK here would be
# SUCCESS -- it means the address is free and gets taken. A TIMEOUT means the
# transmit never completed as far as software knows, which is the missing
# interrupt, not the wire.
cec-ctl -d /dev/cec0 --tv >/dev/null 2>&1
la=$(cec-ctl -d /dev/cec0 2>/dev/null | sed -n 's/.*Logical Address  *: *//p' | head -1)
echo "    logical address: $la"
case "$la" in
    ""|*"Not Allocated"*)
        echo ""
        echo "  RESULT: allocation FAILED."
        echo "          On a kernel without the adv7604 polling patch this is"
        echo "          expected -- see the header. Check the boot log for"
        echo "          'no interrupt wired, polling status every'."
        exit 1 ;;
esac

echo "=== 4. reach the transmitter from Linux"
out=$(cec-ctl -d /dev/cec0 --to $TXLA --poll 2>&1)
echo "$out" | sed 's/^/    /'
echo ""
if echo "$out" | grep -qi "not acknowledged\|timed out\|error"; then
    echo "  RESULT: the receiver's CEC stack is alive, but logical address"
    echo "          $TXLA did not answer. The transmitter's CEC config is"
    echo "          volatile -- it is lost on every power cycle and is only"
    echo "          set by step 2 above."
    exit 1
fi
echo "  RESULT: CEC works end to end."
echo "          The receiver allocated a logical address and reached the"
echo "          transmitter through the HDMI cable, so the bus, both CEC"
echo "          blocks, pin 13 of the cable and the kernel path are all good."

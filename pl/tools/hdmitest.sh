#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Bring up the ADV7511 HDMI transmitter and report what the sink says back.
#
# The fabric produces the pixel clock, CEA timing and 24-bit RGB (see
# pl/board/rtl/hdmi_out.v). Everything else the chip needs arrives over the
# bit-banged I2C bus the PL hands to Linux. This writes that setup and then
# reads the status registers, so a black screen can be attributed rather than
# guessed at.
#
# Usage:  hdmitest.sh [-d] [-f]
#   -d  DVI mode instead of HDMI
#   -f  force HPD, so the chip powers up with NO CABLE ATTACHED
#
# ⚠ AUDIO IS NOT POSSIBLE on this board. The ADV7511's I2S and SPDIF inputs
# are strapped on the PCB rather than routed to the PL, so no configuration
# here can carry samples to it. Video, DDC and CEC are fine.

set -u

DVI=0
FORCE_HPD=0
for a in "$@"; do
    case "$a" in
        -d) DVI=1 ;;
        -f) FORCE_HPD=1 ;;
    esac
done

ADDR=0x39

die() { echo "hdmitest: $*" >&2; exit 1; }

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager is '$state' -- the HDMI pins are PL pins"

command -v i2cget >/dev/null 2>&1 || die "no i2c-tools"

# ---------------------------------------------------------------- find the bus
# The i2c-gpio buses are numbered in probe order, which is not a promise.
# Look for the one where 0x39 answers.
BUS=""
for d in /dev/i2c-*; do
    n=${d#/dev/i2c-}
    if i2cget -y "$n" $ADDR 0x00 >/dev/null 2>&1; then
        BUS=$n
        break
    fi
done
[ -n "$BUS" ] || die "the ADV7511 does not answer at $ADDR on any i2c bus"
echo "ADV7511 at $ADDR on i2c-$BUS"

w() { i2cset -y "$BUS" $ADDR "$1" "$2"; }
r() { i2cget -y "$BUS" $ADDR "$1"; }

echo "  chip revision: $(r 0x00)"

# ------------------------------------------------------------------ power up
# 0x41[6] is POWER_DOWN. Everything else is ignored until this is clear.
w 0x41 0x10
sleep 1

# ⚠ The "fixed registers". The ADV7511 Programming Guide requires these exact
# values and does not document what they do; they are not defaults, and the
# part does not work reliably without them. The values are the guide's.
w 0x98 0x03
w 0x9A 0xE0
w 0x9C 0x30
w 0x9D 0x61
w 0xA2 0xA4
w 0xA3 0xA4
w 0xE0 0xD0
w 0xF9 0x00

# ---------------------------------------------------------------- input video
# 0x15 = 0x00: input is 24-bit RGB 4:4:4 with separate HSYNC/VSYNC, which is
#              exactly what hdmi_out.v drives. The low nibble is the audio
#              input format and is irrelevant here (see the note above).
w 0x15 0x00
# 0x16[5:4] = 11 -> 8 bits per color; [7] = 0 -> 4:4:4 output; [0] = 0 ->
#             data latched on the rising edge of the pixel clock, matching the
#             ODDR in the fabric.
w 0x16 0x30
# no color space conversion: RGB in, RGB out
w 0x18 0x00

# ------------------------------------------------------------- HDMI or DVI
if [ "$DVI" = "1" ]; then
    # DVI carries no InfoFrames at all, which makes it the more forgiving
    # first target: a sink that dislikes our AVI InfoFrame cannot reject it.
    w 0xAF 0x04
    echo "  output mode: DVI"
else
    w 0xAF 0x06
    # AVI InfoFrame: RGB, no overscan.
    w 0x55 0x02
    w 0x56 0x18
    echo "  output mode: HDMI"
fi

# ⚠ The ADV7511 POWERS ITSELF DOWN when HPD is low, whatever was written to
# 0x41. With no cable attached, 0x41 is written as 0x10 and reads back 0x50 --
# bit 6, power-down, set by the chip itself -- and 0x9E then reads 0x00 because
# an unpowered PLL cannot lock to anything.
#
# That is not a fault and it is not a fabric problem, but it makes the two most
# useful diagnostics read exactly as they would if the pixel clock were dead.
# 0xD6[7:6] = 11 tells the chip to behave as though HPD were asserted, which is
# the only way to prove the clock arrives without plugging in a monitor.
if [ "$FORCE_HPD" = "1" ]; then
    w 0xD6 0xC0
    w 0x41 0x10
    echo "  HPD overridden (0xD6[7:6]=11) -- testing without a sink"
fi

# clear any latched interrupts so the status read below is current
w 0x96 0xFF
sleep 1

# ------------------------------------------------------------------- status
st=$(r 0x42)
echo "  status 0x42 = $st"
v=$(printf '%d' "$st")
if [ $(( v & 0x40 )) -ne 0 ]; then
    echo "  HPD:           asserted  -- a sink is connected and powered"
else
    echo "  HPD:           low       -- no sink detected on the cable"
fi
if [ $(( v & 0x20 )) -ne 0 ]; then
    echo "  monitor sense: asserted"
else
    echo "  monitor sense: low"
fi

pw=$(r 0x41)
echo "  power 0x41 = $pw"

# 0x9E is the PLL / clock status: bit 4 set means the ADV7511's internal PLL
# has locked to the incoming pixel clock. That is the single most useful bit
# here -- it separates "the fabric is not clocking the chip" from "the chip is
# clocked and the sink is refusing the mode".
pll=$(r 0x9E)
pv=$(printf '%d' "$pll")
if [ $(( pv & 0x10 )) -ne 0 ]; then
    echo "  0x9E = $pll  -- PLL LOCKED to the pixel clock from the fabric"
else
    echo "  0x9E = $pll  -- PLL not locked."
    if [ $(( v & 0x40 )) -eq 0 ] && [ "$FORCE_HPD" = "0" ]; then
        echo "        With HPD low the chip powers itself down, so this says"
        echo "        nothing about the fabric. Re-run with -f to find out."
    fi
fi

# Measured with no cable attached and -f:
#   0x41 = 0x10 (powered up), 0x9E = 0x12 (bit 4 set).
# So the MMCM's 74.25 MHz leaves through the ODDR, reaches the ADV7511, and
# the chip locks to it. Everything up to the connector is proven.

# DDC: report the ADV7511's EDID segment register (0xC4). This does not read
# the EDID itself.
seg=$(r 0xC4 2>/dev/null || echo "-")
echo "  EDID segment register 0xC4 = $seg"

echo ""
echo "Now look at the screen. The pattern is color bars over a moving bar"
echo "over a gray ramp, with a one-pixel white border."
echo "  * bar not moving      -> the pixel clock or timing generator stopped"
echo "  * border clipped      -> the porches are wrong for this mode"
echo "  * nothing at all      -> check HPD and 0x9E above first"

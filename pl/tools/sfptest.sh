#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Exercise the only two SFP+ signals that reach the FPGA: TX_DISABLE out and
# LOS back.
#
# ⚠ WHAT THIS CAN AND CANNOT TELL YOU.
#
# Four of the ten low-speed pins per cage are usable at all on this board, and
# only these two are wired to the FPGA. MOD-DEF0/1/2 -- the module I2C and the
# presence detect -- RS0 and RS1 all end at a 4.7K pull-up and go nowhere, and
# TX_FAULT is tied to ground. So there is no way to ask what module is fitted,
# whether one is fitted at all, or what line rate it wants.
#
# ⚠ TX_DISABLE is PULLED UP, so a module's transmitter is OFF until something
# drives the pin low. A copper SFP that "does not link" in this board has
# usually not been asked to transmit yet. That is the first thing this checks.
#
# ⚠ A PASSIVE DAC IS NOT A MODULE. It is shielded twinax with an EEPROM: there
# is no transmitter to disable and usually nothing driving LOS. Against a DAC,
# expect TX_DISABLE to change nothing and LOS to sit at whatever the pull-up
# gives. That is not a failure -- it is the cable being passive, which is
# exactly why a DAC is the right thing for testing the transceivers.
#
# The test that means something is with TWO OPTICAL OR COPPER MODULES cabled
# to each other: disabling A's transmitter should make B report loss of
# signal. That one measurement covers SFP1's TX_DISABLE, SFP2's LOS and the
# link between the cages, without involving the FPGA's transceivers.
#
# Usage:  sfptest.sh [-e] [-d]
#   -e  leave both transmitters ENABLED on exit
#   -d  leave both transmitters DISABLED on exit (the default, and the power-on state)

set -u

LEAVE=disabled
for a in "$@"; do
    case "$a" in
        -e) LEAVE=enabled ;;
        -d) LEAVE=disabled ;;
    esac
done

die() { echo "sfptest: $*" >&2; exit 1; }

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager is '$state' -- these are PL pins"
command -v gpioget >/dev/null 2>&1 || die "no libgpiod tools"

# Find the lines by NAME, not by number. The numbers move whenever the EMIO
# map changes, and a stale number silently reads a different pin.
#
# ⚠ gpiofind prints TWO words, "gpiochip0 106". Substituting that whole
# string into a gpioset argument builds "gpiochip0 106=0 gpiochip0 107=0",
# where the second chip name is parsed as an offset and the command fails
# with "invalid offset<->value mapping" -- while the script carries on and
# reports the pin states it never changed.
for n in SFP1-TX_DISABLE SFP2-TX_DISABLE SFP1-LOS SFP2-LOS; do
    gpiofind "$n" >/dev/null 2>&1 || \
        die "no GPIO line called $n -- the device tree or bitstream lacks the SFP lines"
done
CHIP=$(gpiofind SFP1-TX_DISABLE | cut -d" " -f1)
TD1=$(gpiofind SFP1-TX_DISABLE  | cut -d" " -f2)
TD2=$(gpiofind SFP2-TX_DISABLE  | cut -d" " -f2)
LO1=$(gpiofind SFP1-LOS         | cut -d" " -f2)
LO2=$(gpiofind SFP2-LOS         | cut -d" " -f2)

los() { gpioget "$CHIP" "$1"; }

# ⚠ gpioset releases the line as soon as it exits, and the board's pull-up
# then pulls TX_DISABLE back high -- the transmitter would switch off the
# instant the command returned. --mode=signal in the background holds it.
HOLD=""
drop_hold() {
    [ -n "$HOLD" ] && { kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null; HOLD=""; }
}
set_tx() {   # set_tx <sfp1 value> <sfp2 value>
    drop_hold
    gpioset --mode=signal "$CHIP" "$TD1=$1" "$TD2=$2" &
    HOLD=$!
    sleep 2
}

echo "$CHIP: SFP1 TX_DISABLE $TD1 LOS $LO1   SFP2 TX_DISABLE $TD2 LOS $LO2"
echo ""

echo "=== released: the pull-up holds TX_DISABLE high, transmitters OFF"
drop_hold
sleep 2
echo "  LOS: SFP1=$(los $LO1)  SFP2=$(los $LO2)"

echo "=== both transmitters ENABLED (TX_DISABLE driven low)"
set_tx 0 0
E1=$(los $LO1); E2=$(los $LO2)
echo "  LOS: SFP1=$E1  SFP2=$E2"

echo "=== SFP1 transmitter OFF, SFP2 still on"
set_tx 1 0
D1=$(los $LO1); D2=$(los $LO2)
echo "  LOS: SFP1=$D1  SFP2=$D2"

echo ""
# ⚠ The interesting cell is SFP2's LOS. Disabling SFP1's transmitter removes
# the signal SFP2 receives, so with two real modules cabled together SFP2
# should go from 0 (signal present) to 1 (lost). SFP1's own LOS says nothing
# about its own transmitter.
if [ "$E2" = "0" ] && [ "$D2" = "1" ]; then
    echo "  RESULT: SFP2 lost signal when SFP1's transmitter was disabled."
    echo "          SFP1's TX_DISABLE, SFP2's LOS and the link between them are proven."
elif [ "$E2" = "$D2" ]; then
    echo "  RESULT: SFP2's LOS did not move ($E2 either way)."
    echo "          Expected with a PASSIVE DAC, which has no transmitter to"
    echo "          disable. With two real modules cabled together it would"
    echo "          mean TX_DISABLE is not reaching the module."
else
    echo "  RESULT: SFP2's LOS moved $E2 -> $D2, which is backwards."
    echo "          LOS is asserted HIGH on loss; check the module."
fi

case "$LEAVE" in
    enabled)  echo ""; echo "leaving both transmitters ENABLED"; set_tx 0 0
              echo "⚠ held by a background gpioset (pid $HOLD); it releases"
              echo "  when that process exits, and the pull-up then turns the"
              echo "  transmitters off again." ;;
    disabled) drop_hold; echo ""; echo "left as found: transmitters OFF" ;;
esac

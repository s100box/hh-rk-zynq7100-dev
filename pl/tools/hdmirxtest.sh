#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Report the state of the HDMI input capture path, from the pins to
# /dev/video0, so a black frame can be attributed rather than guessed at.
#
# Three independent sources are read, and they are independent on purpose:
#
#   1. the capture block's own registers in the PL -- what the fabric sees
#      arriving on the ADV7611's pins, measured, with no driver involved
#   2. the ADV7611 over I2C -- what the receiver thinks it has locked to
#   3. V4L2 -- what Linux will hand a program
#
# When 1 and 2 disagree the fabric is sampling wrongly. When 1 and 2 agree
# and 3 is empty, the pipeline is not bound. Reading only one of them cannot
# tell those apart.
#
# Usage:  hdmirxtest.sh [-c]
#   -c  also capture frames and report what arrived: re-enables the
#       receiver's termination if a late cable reset it, sets the pipeline
#       to 24-bit RGB at the detected size, captures ten frames, and prints
#       the bar edges against this board's test pattern
#
# ⚠ Needs the bitstream that contains the capture path, and the
# zynq-rkz7100-hdmirx device tree. Reading a PL address with no bitstream
# HANGS THE CPU -- there is no oops, and no way back but a system reset over
# JTAG (see pl/README.md).

set -u

CAP=0
for a in "$@"; do
    case "$a" in -c) CAP=1 ;; esac
done

die() { echo "hdmirxtest: $*" >&2; exit 1; }

state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo unknown)
[ "$state" = "operating" ] || die "fpga_manager is '$state' -- every address below is a PL address"

# ---------------------------------------------------------------- the fabric
# Sub-block 2 of the register file (blk_rdata2). addr[8:6] picks the window
# (0 is the core registers) and addr[5:2] the register inside it, so
# sub-block 2 starts at the register base + 0xC0.
BASE=0x801000C0
rd() { devmem $(printf '0x%X' $((BASE + $1))) 32; }

S0=$(rd 0);  S1=$(rd 4);  S2=$(rd 8);  S3=$(rd 12); S4=$(rd 16)

v() { printf '%d' "$1"; }
H_ACT=$(( $(v $S0) & 0xFFFF ));   H_TOT=$(( ($(v $S0) >> 16) & 0xFFFF ))
V_ACT=$(( $(v $S1) & 0xFFFF ));   V_TOT=$(( ($(v $S1) >> 16) & 0xFFFF ))
FRAMES=$(( $(v $S2) & 0xFFFF ));  STALLS=$(( ($(v $S2) >> 16) & 0xFFFF ))
FLAGS=$(( $(v $S3) & 0xFF ));     UPD=$(( ($(v $S3) >> 8) & 0xFF ))

echo "=== what the fabric sees on the ADV7611's pins"
echo "  raw: $S0 $S1 $S2 $S3"
# ⚠ THE UPDATE COUNTER FIRST. Every other register here reads 0 when the
# pixel clock is dead, and 0x0 x 0x0 is also what a black picture would look
# like if the clock were fine. Only this counter separates them: it advances
# once per frame, in the pixel clock's own domain, so it cannot move without
# a clock.
if [ "$UPD" -eq 0 ]; then
    echo "  updates:       0  -- NO PIXEL CLOCK. The ADV7611 is not driving LLC,"
    echo "                      so nothing below was measured. Everything reading"
    echo "                      zero is the absence of a clock, not a black frame."
else
    echo "  updates:       $UPD  (snapshots taken, one per frame)"
    echo "  active:        ${H_ACT}x${V_ACT}"
    echo "  total:         ${H_TOT}x${V_TOT}"
    echo "  frames seen:   $FRAMES"
    echo "  stalls:        $STALLS   (frames abandoned because the VDMA was not ready)"
fi
echo "  DE seen:       $(( FLAGS & 1 ))"
echo "  HS seen:       $(( (FLAGS >> 1) & 1 ))   polarity high: $(( (FLAGS >> 4) & 1 ))"
echo "  VS seen:       $(( (FLAGS >> 2) & 1 ))   polarity high: $(( (FLAGS >> 3) & 1 ))"
echo "  streaming:     $(( (FLAGS >> 5) & 1 ))"
echo "  frame dropped: $(( (FLAGS >> 6) & 1 ))   (sticky)"
if [ $(( $(v $S4) & 1 )) -ne 0 ]; then
    echo "  ⚠ AWLEN OVERFLOW: the VDMA issued a burst longer than 16 beats and the"
    echo "    AXI4-to-AXI3 width adaptation truncated it. Memory past the end of a"
    echo "    buffer may have been written. The VDMA must have c_s2mm_max_burst_length 8"
    echo "    (pl/board/build.tcl)."
fi

# --------------------------------------------------------------- the ADV7611
echo ""
echo "=== what the ADV7611 reports over I2C"
B=""
for d in /dev/i2c-*; do
    n=${d#/dev/i2c-}
    if i2cget -y "$n" 0x4C 0xEA >/dev/null 2>&1; then B=$n; break; fi
done
if [ -z "$B" ]; then
    # ⚠ Not necessarily a fault, and usually the opposite. Once the adv7604
    # driver binds it OWNS the I2C device, and i2cget cannot address it --
    # so silence here with a working /dev/video0 below means the driver got
    # there first, which is what is supposed to happen.
    if [ -e /dev/video0 ]; then
        echo "  not reachable from i2cget -- the adv7604 driver holds it,"
        echo "  which is what the V4L2 section below is reporting instead"
    else
        echo "  the ADV7611 does not answer at 0x4C on any bus, and no driver"
        echo "  holds it either -- check the bitstream and the i2c-gpio pins"
    fi
else
    echo "  on i2c-$B, revision $(i2cget -y $B 0x4C 0xEA)$(i2cget -y $B 0x4C 0xEB | sed 's/0x//')"
    CD=$(i2cget -y $B 0x4C 0x6F); TM=$(i2cget -y $B 0x4C 0x6A)
    echo "  0x6F cable detect = $CD   (bit 0: a TMDS clock is present on the input)"
    echo "  0x6A tmds status  = $TM   (bit 4: signal detected; 0x43 all set: locked)"
    tv=$(printf '%d' "$TM")
    [ $(( tv & 0x10 )) -ne 0 ] && echo "    TMDS signal: detected" || echo "    TMDS signal: NOT detected"
    [ $(( tv & 0x43 )) -eq 67 ] && echo "    TMDS lock:   LOCKED"    || echo "    TMDS lock:   not locked"
    # ⚠ An ADV7611 that nothing has configured keeps its core powered down and
    # reads 0x00 here however good the signal is. That is the adv7604 driver's
    # job -- if this reads 0x00, check the driver bound before blaming the cable.
fi

# -------------------------------------------------------------------- V4L2
echo ""
echo "=== what Linux offers"
if [ ! -e /dev/video0 ]; then
    echo "  no /dev/video0."
    echo "  Bound drivers:"
    ls /sys/bus/i2c/drivers/adv7604/ 2>/dev/null | sed 's/^/    adv7604: /'
    ls /sys/bus/platform/drivers/xilinx-video/ 2>/dev/null | sed 's/^/    xilinx-video: /'
    dmesg | grep -iE "adv76|xilinx-video|xvip|vdma|video" | tail -12 | sed 's/^/    /'
    exit 1
fi
echo "  $(cat /sys/class/video4linux/video0/name 2>/dev/null)"
command -v v4l2-ctl >/dev/null 2>&1 || { echo "  (no v4l2-ctl)"; exit 0; }
v4l2-ctl -d /dev/video0 --all 2>&1 | head -25 | sed 's/^/  /'

echo ""
echo "  --- the receiver's view of the incoming timings ---"
for sd in /dev/v4l-subdev*; do
    [ -e "$sd" ] || continue
    if v4l2-ctl -d "$sd" --query-dv-timings >/dev/null 2>&1; then
        echo "  $sd:"
        v4l2-ctl -d "$sd" --query-dv-timings 2>&1 | sed 's/^/    /'
    fi
done

if [ "$CAP" = "1" ]; then
    echo ""
    echo "=== capturing"
    RXB=$(i2cdetect -l | awk '/i2c-hdmi-rx/ { sub("i2c-", "", $1); print $1 }')

    # ⚠ Plugging a cable in after boot resets the ADV7611's HDMI section
    # (cable-detect reset, HDMI map 0x48[6] = 0), and that puts its TMDS
    # clock termination back to its power-on default: OFF, 0x83 = 0xFF. The
    # driver enabled it once, at probe, and does not again. The transmitter
    # then sees no receiver ("monitor sense: low"), the receiver reports
    # "Link has been severed", and nothing locks. Port A's termination is
    # re-enabled here if it is off.
    if [ -n "$RXB" ]; then
        HM=$(( $(i2ctransfer -f -y "$RXB" w1@0x4c 0xfb r1) >> 1 ))
        TERM=$(i2ctransfer -f -y "$RXB" w1@$HM 0x83 r1)
        if [ "$TERM" = "0xff" ]; then
            i2ctransfer -f -y "$RXB" w2@$HM 0x83 0xfe
            echo "  TMDS termination was OFF (HDMI map 0x83 = 0xff) -- enabled for port A"
            sleep 2
        fi
    fi

    # ⚠ Set the pipeline format from what the receiver actually detected
    # rather than from what this script expects. A hard-coded 1280x720 would
    # "work" against a source sending something else by capturing garbage of
    # the right size.
    RXSD=""
    for sd in /dev/v4l-subdev*; do
        [ -e "$sd" ] || continue
        case "$(cat /sys/class/video4linux/$(basename $sd)/name)" in
            adv7611*) RXSD=$sd ;;
        esac
    done
    [ -n "$RXSD" ] || die "no adv7611 subdevice"
    v4l2-ctl -d "$RXSD" --set-dv-bt-timings query >/dev/null 2>&1 ||
        die "the receiver detects no signal -- see the timings above"
    W=$(v4l2-ctl -d "$RXSD" --get-dv-timings | awk '/Active width/ { print $3 }')
    H=$(v4l2-ctl -d "$RXSD" --get-dv-timings | awk '/Active height/ { print $3 }')
    echo "  $RXSD: timings set from the detected signal, ${W}x${H}"

    # The receiver's source pad and the capture node must both carry 24-bit
    # RGB at that size: the fabric takes the ADV7611's 24-bit bus as it is.
    RXNAME=$(cat /sys/class/video4linux/$(basename $RXSD)/name)
    media-ctl -d /dev/media0 -V "\"$RXNAME\":1 [fmt:RGB888_1X24/${W}x${H} field:none]"
    v4l2-ctl -d /dev/video0 --set-fmt-video=width=$W,height=$H,pixelformat=BGR3
    v4l2-ctl -d /dev/video0 -V 2>&1 | grep -E 'Width|Pixel' | sed 's/^/  /'
    rm -f /tmp/hdmirx.raw
    v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=10 \
        --stream-to=/tmp/hdmirx.raw 2>&1 | sed 's/^/  /'
    if [ -s /tmp/hdmirx.raw ]; then
        FB=$((W * H * 3))
        echo "  captured $(wc -c < /tmp/hdmirx.raw) bytes to /tmp/hdmirx.raw" \
             "($(( $(wc -c < /tmp/hdmirx.raw) / FB )) frames of $FB)"
        # A frame that is all one value is what a stopped pipeline produces.
        echo "  distinct byte values in the first 64 KB:\
 $(od -An -tu1 -N65536 /tmp/hdmirx.raw | tr -s ' ' '\n' | sort -u | grep -c .)"

        # If the source is this board's own HDMI output (video_tpg.v), row
        # H/7 crosses the white border and the eight bars. Each bar starts on
        # a multiple of W/8, and the pixel before it belongs to the bar
        # before. Bytes are B, G, R.
        ROW=$((H / 7))
        echo "  row $ROW of frame 3, as B G R -- against this board's test pattern:"
        for x in 0 1 $((W/8 - 1)) $((W/8)) $((2*W/8)) $((7*W/8 - 1)) $((7*W/8)) $((W - 1)); do
            printf "    x=%-5s %s\n" $x "$(od -An -tx1 -N3 \
                -j $((3*FB + ROW*W*3 + x*3)) /tmp/hdmirx.raw)"
        done
        echo "    expected: x=0 and x=$((W-1)) white (border), x=1 black,"
        echo "    x=$((W/8)) blue, x=$((2*W/8)) green, x=$((7*W/8)) white"
    else
        echo "  nothing captured"
    fi
fi

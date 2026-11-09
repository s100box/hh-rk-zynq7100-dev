#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# camtest.sh -- the OV5647 camera on J9, end to end, on the board.
#
#   sh camtest.sh            every mode, the color-bar check, repeated streams
#   sh camtest.sh -m 640x480 one mode only
#   sh camtest.sh -t 1296x972 [LANE [HOLD]]
#                            sweep the D-PHY's IDELAY taps 0..31 -- both lanes
#                            together, or LANE 0 or 1 with the other held at
#                            HOLD (default 31) -- and report the color-bar
#                            check and the receiver's damaged-packet count at
#                            each; the taps are restored afterward
#
# For each sensor mode it sets RAW10 Bayer (SBGGR10) on every pad of the
# pipeline -- sensor, CSI-2 receiver sink and source -- captures frames from
# /dev/videoN and checks:
#
#   frames    every frame arrives, at exactly W x H x 2 bytes
#   rate      frames per second over the capture
#   pattern   with the sensor's color-bar test pattern on, and the first 5
#             frames skipped while the sensor settles, every even row is
#             identical, every odd row is identical, the two differ, the first
#             bar is full-scale white (1023) and the last is black (0). That
#             is a bit-exact check of the whole path: D-PHY, CSI-2, the frame
#             buffer, the VDMA and the stride.
#   restart   three captures back to back. The receiver restarts cleanly only
#             with the sensor on a non-continuous clock (clock-noncontinuous in
#             the device tree); with a continuous one only the first stream works.
#
# Needs the full bitstream and the capture device tree (zynq-rkz7100-hdmirx).
# Exit status is the number of failed checks.

MODES="640x480 1296x972 1920x1080 2592x1944"
[ "$1" = "-m" ] && MODES="$2"

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# ---- find the camera's media device and its entities ---------------------
MD=
for m in /dev/media*; do
    media-ctl -d "$m" -p 2>/dev/null | grep -q 'platform:video-camera' && MD=$m
done
[ -n "$MD" ] || { echo "camtest: no media device for video-camera"; exit 1; }
topo=$(media-ctl -d "$MD" -p)
SENSOR=$(echo "$topo" | sed -n 's/.*entity [0-9]*: \(ov5647 [^ ]*\) .*/\1/p' | head -1)
CSI=$(echo "$topo" | sed -n 's/.*entity [0-9]*: \([^ ]*csi2rx\) .*/\1/p' | head -1)
VID=$(echo "$topo" | sed -n 's/.*device node name \(\/dev\/video[0-9]*\).*/\1/p' | head -1)
SUBDEV=$(echo "$topo" | grep -A3 "entity [0-9]*: $SENSOR" | sed -n 's/.*device node name \(\/dev\/v4l-subdev[0-9]*\).*/\1/p')
CSISUB=$(echo "$topo" | grep -A3 "entity [0-9]*: $CSI" | sed -n 's/.*device node name \(\/dev\/v4l-subdev[0-9]*\).*/\1/p')
echo "camtest: $MD  sensor '$SENSOR' ($SUBDEV)  receiver '$CSI'  capture $VID"
[ -n "$SENSOR" ] && [ -n "$CSI" ] && [ -n "$VID" ] && [ -n "$SUBDEV" ] && [ -n "$CSISUB" ] ||
    { echo "camtest: pipeline incomplete"; exit 1; }

# ---- helpers --------------------------------------------------------------
setfmt() {  # W H
    f="SBGGR10_1X10/${1}x${2} field:none"
    media-ctl -d "$MD" -V "\"$SENSOR\":0 [fmt:$f]" &&
    media-ctl -d "$MD" -V "\"$CSI\":0 [fmt:$f]" &&
    media-ctl -d "$MD" -V "\"$CSI\":1 [fmt:$f]"
}

now_cs() { cut -d' ' -f1 /proc/uptime | tr -d .; }   # centiseconds

# capture W H N GUARD [null] -> sets FRAMES and CS (elapsed centiseconds).
# With "null" the frames go to /dev/null and FRAMES counts v4l2-ctl's
# dequeue markers instead: a full-size frame is 10 MB, and /tmp is RAM.
capture() {
    rm -f /tmp/camtest.raw
    out=/tmp/camtest.raw; [ "$5" = null ] && out=/dev/null
    t0=$(now_cs)
    v4l2-ctl -d "$VID" \
        --set-fmt-video=width=$1,height=$2,pixelformat=BG10,bytesperline=$(($1 * 2)) \
        --stream-mmap --stream-count=$3 --stream-to=$out \
        > /tmp/camtest.log 2>&1 &
    p=$!; ticks=0
    while kill -0 $p 2>/dev/null && [ $ticks -lt $(($4 * 10)) ]; do
        sleep 0.1; ticks=$((ticks + 1))
    done
    kill $p 2>/dev/null && wait $p 2>/dev/null
    CS=$(( $(now_cs) - t0 ))
    if [ "$5" = null ]; then
        FRAMES=$(tr -cd '<' < /tmp/camtest.log | wc -c)
        return
    fi
    sz=$(wc -c < /tmp/camtest.raw 2>/dev/null || echo 0)
    FB=$(($1 * $2 * 2))
    FRAMES=$((sz / FB))
    [ $((sz % FB)) -eq 0 ] || FRAMES=-1
}

# row R of frame K of the last capture, as md5
rowsum() { dd if=/tmp/camtest.raw bs=$((W * 2)) skip=$(($2 * H + $1)) count=1 \
               2>/dev/null | md5sum | cut -c1-32; }

# pixels [A, B) of row R of frame K, as decimal values one per line
pixels() { dd if=/tmp/camtest.raw bs=2 skip=$(( ($4 * H + $3) * W + $1 )) \
               count=$(($2 - $1)) 2>/dev/null | od -An -tu2 -v | tr -s ' ' '\n' |
               grep -v '^$'; }

# linkerrs -> LERR, FSYNC: the receiver's own count of damaged packets since
# the last stream started -- ECC (1- and 2-bit), CRC, SoT, SoT sync, word
# count, data ID and lane count errors -- and of frame-sync events. The
# driver resets its counters at every stream start and --log-status prints
# them to the kernel log.
#
# These are what make the color-bar check honest. The bars are the same in
# every frame and the capture buffers are reused, so a line the receiver
# DROPS for a bad CRC leaves the previous frame's identical line in place,
# and comparing rows cannot see it. The receiver can.
linkerrs() {
    dmesg -c >/dev/null
    v4l2-ctl -d "$CSISUB" --log-status >/dev/null 2>&1
    LERR=$(dmesg | grep -E 'ECC|CRC|SOT|Word Count|Data Id|Lane Count' |
           sed -n 's/.*events: *\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
    FSYNC=$(dmesg | grep -E 'Frame (Sync|Level) Error' |
           sed -n 's/.*events: *\([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
}

# colorbars W H -> FRAMES, good (settled frames that are whole and exact),
# e0 / o0 (the reference even and odd rows, from the last frame), and
# LERR / FSYNC for the capture.
#
# The first frames after a stream starts can be short: the driver starts the
# sensor and only then applies its controls, which changes its timing under
# them. SETTLE frames are skipped; every one after that must be perfect.
SETTLE=5; NB=10; K=$((NB - 1))
colorbars() {
    W=$1; H=$2; good=0; e0=; o0=
    v4l2-ctl -d "$SUBDEV" -c test_pattern=1 >/dev/null
    capture $W $H $NB 30
    v4l2-ctl -d "$SUBDEV" -c test_pattern=0 >/dev/null
    [ $FRAMES -eq $NB ] || return
    e0=$(rowsum 0 $K); o0=$(rowsum 1 $K)
    k=$SETTLE
    while [ $k -le $K ]; do
        same=1
        for r in 0 2 $((H / 4 * 2)) $((H / 2 * 2 - 2)) $((H - 2)); do
            [ "$(rowsum $r $k)" = "$e0" ] || same=0
        done
        for r in 1 3 $((H / 4 * 2 + 1)) $((H / 2 * 2 - 1)) $((H - 1)); do
            [ "$(rowsum $r $k)" = "$o0" ] || same=0
        done
        [ "$e0" != "$o0" ] || same=0
        good=$((good + same)); k=$((k + 1))
    done
    linkerrs
}

# The D-PHY's IDELAY taps: +0x04 in the D-PHY's registers at 0x8002_1000
# (the receiver's base + 0x1000), one byte per data lane ([4:0] lane 0,
# [12:8] lane 1), 78 ps a tap. It resets to the bitstream's C_IDLY_TAP, 10.
TAPS=0x80021004
settaps() { devmem $TAPS 32 $(( ($2 << 8) | $1 )); }
# The tap each mode streams at -- the same table as camsetup.sh, which says
# why: 31 for 2592x1944, 10 (the reset value) for the rest.
tap_for() { [ "$1x$2" = "2592x1944" ] && echo 31 || echo 10; }

# ---- -t [WxH [LANE [HOLD]]]: sweep the D-PHY taps -------------------------
if [ "$1" = "-t" ]; then
    mode=${2:-1296x972}; W=${mode%x*}; H=${mode#*x}
    lane=${3:-both}; hold=${4:-31}
    setfmt $W $H || { echo "camtest: $mode refused"; exit 1; }
    saved=$(devmem $TAPS 32)
    echo "--- tap sweep at $mode, lane $lane (the other held at $hold)"
    t=0
    while [ $t -le 31 ]; do
        case $lane in
            0) settaps $t $hold ;;
            1) settaps $hold $t ;;
            *) settaps $t $t ;;
        esac
        colorbars $W $H
        printf '  tap %2d (%4d ps)  %d/%d exact, %d whole frames, %d damaged packets\n' \
            $t $((t * 78)) $good $((NB - SETTLE)) $FRAMES $LERR
        t=$((t + 1))
    done
    devmem $TAPS 32 $saved
    exit 0
fi

# ---- per mode -------------------------------------------------------------
v4l2-ctl -d "$SUBDEV" -c test_pattern=0 >/dev/null 2>&1
echo "camtest: D-PHY taps lane 0 $(( $(devmem $TAPS 32) & 31 )), lane 1 $(( ($(devmem $TAPS 32) >> 8) & 31 ))"
for mode in $MODES; do
    W=${mode%x*}; H=${mode#*x}
    t=$(tap_for $W $H)
    echo "--- $mode, D-PHY tap $t"
    setfmt $W $H || { bad "$mode: pad formats refused"; continue; }
    settaps $t $t

    N=30
    capture $W $H $N 20 null
    if [ $FRAMES -eq $N ]; then
        fps10=$(( N * 1000 / (CS > 0 ? CS : 1) ))
        ok "$N frames in $((CS / 100)).$(printf %02d $((CS % 100))) s, ~$((fps10 / 10)).$((fps10 % 10)) fps (including stream start)"
    else
        bad "$mode: $FRAMES of $N frames (stalled or short)"
        continue
    fi
    # The link is judged on this plain capture. The color-bar one below
    # switches the test pattern on as the stream starts, which can damage
    # a packet of the first frame on its own.
    linkerrs
    [ $LERR -eq 0 ] && ok "no damaged packets ($FSYNC frame-sync events)" ||
        bad "$mode: the receiver reported $LERR damaged packets"

    colorbars $W $H
    if [ $FRAMES -ne $NB ]; then
        bad "$mode: color-bar capture got $FRAMES of $NB whole frames"
        continue
    fi
    ok "$NB frames of exactly $((W * H * 2)) bytes"
    [ "$e0" != "$o0" ] || bad "$mode: even and odd color-bar rows are the same"
    [ $good -eq $((NB - SETTLE)) ] &&
        ok "color bars: frames $SETTLE..$K all have identical even rows and identical odd rows" ||
        bad "$mode: only $good of $((NB - SETTLE)) settled color-bar frames are whole and exact"
    bw=$((W / 16))   # well inside the first and last bars, which are ~W/8 wide
    white=$(pixels 4 $((bw - 4)) $((H / 2)) $K | grep -vc '^1023$')
    black=$(pixels $((W - bw + 4)) $((W - 4)) $((H / 2)) $K | grep -vc '^0$')
    [ "$white" -eq 0 ] && [ "$black" -eq 0 ] &&
        ok "first bar white (1023), last bar black (0)" ||
        bad "$mode: bar levels wrong ($white non-white, $black non-black pixels)"
done

# ---- restart ----------------------------------------------------------------
W=640; H=480; settaps $(tap_for $W $H) $(tap_for $W $H)
echo "--- restart, three streams back to back at ${W}x${H}"
setfmt $W $H
for i in 1 2 3; do
    capture $W $H 10 10
    [ $FRAMES -eq 10 ] && ok "stream $i: 10 frames" ||
        bad "stream $i: $FRAMES of 10 frames -- is the sensor endpoint clock-noncontinuous?"
done

echo "camtest: $fail failure(s)"
exit $fail

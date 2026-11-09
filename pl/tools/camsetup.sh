#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# camsetup.sh W H -- get the camera pipeline ready to stream W x H.
#
# Sets SBGGR10 on every pad (the OV5647, and the CSI-2 receiver's sink and
# source, with field:none) and the D-PHY's input delay for that mode's line
# rate. After this, /dev/video1 streams with
#
#   v4l2-ctl -d /dev/video1 \
#       --set-fmt-video=width=W,height=H,pixelformat=BG10,bytesperline=2W \
#       --stream-mmap ...
#
# The delay is per mode because the receiver's clean window is. Swept with
# camtest.sh -t against the receiver's own damaged-packet counts:
#
#   640x480              315 Mb/s    clean at taps 0..25, and 31
#   1296x972, 1920x1080  441 Mb/s    clean at 1..19
#   2592x1944            472.5 Mb/s  clean ONLY at 30 and 31
#
# so 10 for the first three -- the bitstream's reset value -- and 31 for 5 MP.
#
# Modes: 640x480 1296x972 1920x1080 2592x1944.

W=${1:?usage: camsetup.sh W H}; H=${2:?usage: camsetup.sh W H}

# The D-PHY's tap register: +0x04 in the D-PHY's registers at 0x8002_1000
# (the receiver's base + 0x1000), a byte a lane.
TAPS=0x80021004
tap_for() { [ "$1x$2" = "2592x1944" ] && echo 31 || echo 10; }

M=
for m in /dev/media*; do
    media-ctl -d "$m" -p 2>/dev/null | grep -q 'platform:video-camera' && M=$m
done
[ -n "$M" ] || { echo "camsetup: no media device for video-camera" >&2; exit 1; }
topo=$(media-ctl -d "$M" -p)
SENSOR=$(echo "$topo" | sed -n 's/.*entity [0-9]*: \(ov5647 [^ ]*\) .*/\1/p' | head -1)
CSI=$(echo "$topo" | sed -n 's/.*entity [0-9]*: \([^ ]*csi2rx\) .*/\1/p' | head -1)

f="SBGGR10_1X10/${W}x${H} field:none"
media-ctl -d "$M" -V "\"$SENSOR\":0 [fmt:$f]" &&
media-ctl -d "$M" -V "\"$CSI\":0 [fmt:$f]" &&
media-ctl -d "$M" -V "\"$CSI\":1 [fmt:$f]" || { echo "camsetup: ${W}x${H} refused" >&2; exit 1; }

t=$(tap_for "$W" "$H")
devmem $TAPS 32 $(( (t << 8) | t ))
echo "camsetup: ${W}x${H} on $M, D-PHY tap $t"

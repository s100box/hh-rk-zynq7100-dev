# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The HDMI input capture block, with video_timing as its stimulus -- the same
# generator that drives the HDMI output, and one already checked against
# CEA-861 constants written out a second time. It runs all three modes,
# including the one whose syncs are negative, and it is the slowest bench by
# far: three full-rate video streams and four frames of each.
pl/sim/hdmi_rx_capture_tb.v
pl/board/rtl/hdmi_rx_capture.v
pl/board/rtl/video_timing.v

# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The whole HDMI output: the pattern's pixel must arrive with the DE and
# syncs that describe it, since the ADV7511 samples them on one edge.
pl/sim/hdmi_out_tb.v
pl/board/rtl/hdmi_out.v
pl/board/rtl/video_timing.v
pl/board/rtl/video_tpg.v
pl/sim/stubs/xilinx_prims.v

# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The guard between the camera's CSI-2 receiver and its VDMA: the receiver
# is never stalled, and a downstream stall costs one frame, not the stream.
pl/sim/cam_guard_tb.v
pl/board/rtl/cam_guard.v
pl/board/rtl/axis_cdc_fifo.v

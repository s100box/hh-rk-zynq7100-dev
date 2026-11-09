# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The clock-domain crossing that carries captured video from the pixel
# clock into the AXI clock. Three clock ratios, and the reader stalls at
# random so the FIFO actually fills -- `full` is the flag most likely to
# be wrong, being the one that needs the extra pointer bit to be told
# apart from `empty`.
pl/sim/axis_cdc_fifo_tb.v
pl/board/rtl/axis_cdc_fifo.v

# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The framebuffer scanout. The RTL is Verilog, but the bench uses $sformatf
# and string arguments, so it needs -g2012.
-g2012
pl/sim/fb_reader_tb.v
pl/sim/axi_mem_bfm.v
pl/board/rtl/fb_reader.v

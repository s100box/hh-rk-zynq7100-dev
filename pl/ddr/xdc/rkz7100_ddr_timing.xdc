# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Timing exceptions for the ddr design. IMPLEMENTATION ONLY -- build.tcl sets
# USED_IN_SYNTHESIS false on this file.
#
# ⚠ WHY THIS IS A SEPARATE FILE, and why there is no `if` in it.
#
# An XDC is read by a RESTRICTED Tcl interpreter. `foreach` and `if` are not
# available:
#
#   CRITICAL WARNING: [Designutils 20-1307] Command 'foreach' is not
#   supported in the xdc constraint file.
#
# A clock-group block written with either one never runs, in any build -- and
# nothing fails until the logic it is meant to relax stops being optimized
# away, when WNS goes deeply negative across every crossing.
#
# The constraint also needs `clk_fpga_0`, which does not exist while the PS7
# is a black box during synthesis. Guarding that needs `if`, which is what the
# restricted interpreter forbids -- so the whole file is implementation-only
# instead, where every clock is real and no guard is needed.

# ---------------------------------------------------------------------------
# Five unrelated clock families.
#
#   clk_fpga_0    the PS clock; GP0/GP1, the registers, the BIST engines
#   sys_clk       the 200 MHz oscillator and everything the MIG derives from
#                 it -- ui_clk, mem_refclk, the ISERDES/OSERDES clocks
#   pl_clk        50 MHz, measured only
#   gtx_clk156    156.25 MHz reference, with its ODIV2 child
#   gtx_sataclk   150 MHz reference, with its ODIV2 child
#
# -include_generated_clocks keeps each family in ONE group, so the MIG's
# internal clocks stay related to each other and to the oscillator they come
# from, while being unrelated to the PS clock -- which is the truth, and is
# why there is an axi_clock_converter between them.
# ---------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_fpga_0] \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks pl_clk] \
    -group [get_clocks -include_generated_clocks gtx_clk156] \
    -group [get_clocks -include_generated_clocks gtx_sataclk]

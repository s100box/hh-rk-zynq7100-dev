# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The GTX PRBS exerciser on the SFP lanes. The transceiver is a behavioral
# model of the gtwizard channel's contract (gtx_sfp_model.v), since Icarus
# cannot run the encrypted GTXE2 model -- so this pins the fabric around the
# transceiver: the register decode, which field reaches which port, both
# clock crossings and the counters, several of them to the exact cycle.
pl/sim/gtx_prbs_tb.v
pl/sim/gtx_sfp_model.v
pl/board/rtl/gtx_prbs.v
pl/sim/stubs/xilinx_prims.v

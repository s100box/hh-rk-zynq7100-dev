# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# The Ethernet CRC, pinned against the published check value from outside
# this design. It has to pass on its own terms: eth_mac_tb is a loopback, and
# a loopback only proves the two halves agree -- a transmitter and receiver
# sharing the same mistake about bit order would pass it and be rejected by
# every real partner.
-g2012
pl/sim/eth_crc32_tb.sv
pl/board/rtl/eth_crc32.sv

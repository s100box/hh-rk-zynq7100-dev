#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Convert a Vivado .bit (or raw .bin) into the form Zynq's devcfg wants.

The Zynq fpga_manager driver feeds the file straight to the PCAP DMA, which
reads 32-bit little-endian words. Vivado writes the configuration stream
big-endian, so every 32-bit word has to be byte-swapped. That is the whole of
what Xilinx's `bootgen -process_bitstream bin` does, and doing it here keeps
the flow to Vivado plus Python -- no bootgen, no Vitis install.

    python3 bit2bin.py rkz7100_pl.bit rkz7100_pl.bin

A .bit also carries a header (design name, part, date) which is stripped. The
part name is printed, because loading a bitstream built for the wrong device
is otherwise a silent, puzzling failure.
"""

import struct
import sys

SYNC = b"\xaa\x99\x55\x66"   # the configuration sync word, as Vivado writes it


def parse_bit(data):
    """Return (payload, fields) from a .bit, or (data, {}) if it has no header."""
    if len(data) < 2 or struct.unpack(">H", data[0:2])[0] != 9:
        return data, {}                      # already a raw .bin

    pos = 2 + 9                              # 2-byte length + 9-byte magic
    pos += 2                                 # a 0x0001 separator
    fields = {}
    while pos < len(data):
        key = chr(data[pos])
        pos += 1
        if key == "e":
            (n,) = struct.unpack(">I", data[pos:pos + 4])
            pos += 4
            return data[pos:pos + n], fields
        (n,) = struct.unpack(">H", data[pos:pos + 2])
        pos += 2
        fields[key] = data[pos:pos + n].rstrip(b"\x00").decode("ascii", "replace")
        pos += n
    raise ValueError("no 'e' (bitstream data) field found -- is this a .bit?")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: bit2bin.py <in.bit|in.bin> <out.bin>")
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, "rb") as f:
        payload, fields = parse_bit(f.read())

    if fields:
        print(f"design {fields.get('a', '?')}  part {fields.get('b', '?')}  "
              f"{fields.get('c', '?')} {fields.get('d', '?')}")

    if len(payload) % 4:
        sys.exit(f"payload is {len(payload)} bytes, not a multiple of 4")

    # Find the sync word before trusting the file. If it is not there in one
    # orientation or the other, this is not a configuration stream and
    # swapping it would just produce a file devcfg times out on.
    if SYNC in payload[:256]:
        swap = True
    elif SYNC[::-1] in payload[:256]:
        print("note: already byte-swapped; copying without swapping")
        swap = False
    else:
        sys.exit("no sync word in the first 256 bytes -- not a bitstream?")

    if swap:
        words = struct.unpack(f">{len(payload) // 4}I", payload)
        out = struct.pack(f"<{len(words)}I", *words)
    else:
        out = payload

    with open(dst, "wb") as f:
        f.write(out)
    print(f"wrote {dst}, {len(out)} bytes")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Stage optional, locally generated XSDB initialization with Linux images.

An explicit --init must exist. Otherwise discover ps7_init.tcl beside the PL
bitstream, where both Vivado builds publish it. Linux/SPL builds need only the
tracked GPL C/H sources, so a missing implicit artifact disables JTAG staging
rather than adding a Vivado dependency to a Linux-only build.
"""

import argparse
from pathlib import Path
import shutil


def stage(destination, *, init=None, bitstream=None):
    """Copy a selected init file, or remove a stale destination if none exists."""
    target = destination / "ps7_init.tcl"
    source = init or (bitstream.parent / "ps7_init.tcl" if bitstream else None)
    if source is None or not source.is_file():
        target.unlink(missing_ok=True)
        if init is not None:
            raise FileNotFoundError(f"no generated PS7 initialization at {init}")
        print("PS7 Tcl not staged: JTAG boot needs a PL build or linux/gen_ps7.tcl")
        return False
    if source.stat().st_size == 0:
        target.unlink(missing_ok=True)
        raise ValueError(f"empty PS7 initialization: {source}")
    destination.mkdir(parents=True, exist_ok=True)
    if source.resolve() != target.resolve():
        shutil.copyfile(source, target)
    print(f"PS7 Tcl staged: {target}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--init", type=Path)
    parser.add_argument("--bitstream", type=Path)
    args = parser.parse_args()
    try:
        stage(args.destination, init=args.init, bitstream=args.bitstream)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"stage_ps7: {exc}\n")


if __name__ == "__main__":
    main()

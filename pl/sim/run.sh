#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Run every PL bench with Icarus Verilog, elaborate both top levels against
# their IP stubs, and lint both with Verilator when it is installed. The RTL
# has to pass here before a Vivado build is worth starting: a synthesis run
# costs twenty minutes and a board session costs more, and neither one tells
# you which beat went wrong.
#
# Needs iverilog on PATH (oss-cad-suite's bin directory is enough; the script
# puts the suite's lib directory first itself, below):
#
#   PATH="$HOME/oss-cad-suite/bin:$PATH" pl/sim/run.sh
#
# Exits non-zero if any step fails, so it can be a gate.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work="${TMPDIR:-/tmp}/rkz7100-sim.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

command -v iverilog >/dev/null 2>&1 || {
    echo "run.sh: no iverilog on PATH" >&2
    exit 127
}

# ⚠ iverilog runs its preprocessor and compiler as child programs, and on a
# Windows host they load their DLLs from PATH. Git runs hooks with its own
# libexec/git-core first on PATH, whose DLLs they cannot use, and they then
# exit 127 without a word. Put the suite's lib directory first.
ivl_lib=$(cd "$(dirname "$(command -v iverilog)")/../lib" 2>/dev/null && pwd) &&
    PATH="$ivl_lib:$PATH"

RTL="$repo/pl/board/rtl"
STUBS="$here/stubs/xilinx_prims.v"

fail=0

# Shared runner owns manifest parsing, bounded child processes and verdicts.
py=$(command -v python3 || command -v python)
build=${RETROSIM_BUILD:-$here/../../../retrosim-build}
"$py" "$build/tools/bench_suite.py" "$here/suite.json" || fail=$((fail + 1))

# ---------------------------------------------------------------------------
# Elaborate each top level against the stubs generated for its IP.
#
# This is not a simulation -- it is a wiring check. -Wportbind reports any
# port connected at the wrong width, which is the failure mode that matters
# when a 64-bit HP data bus, a 6-bit ID and a 4-bit burst length all have to
# line up with a master that can also be configured 32/12/8. Vivado would
# eventually say so too, twenty minutes later, in a log nobody reads.
#
# Narrowing hp1_wdata to 32 bits in the full design's top reports:
#   "Port 205 (S_AXI_HP1_WDATA) of module ps7_rkz7100 expects 64 bit(s), given 32."
# ---------------------------------------------------------------------------
elaborate() {
    name=$1
    shift
    printf '=== elaborate %s\n' "$name"
    # ⚠ -Wimplicit matters as much as -Wportbind, and for a worse reason.
    # Verilog invents a one-bit net for any undeclared identifier in a port
    # connection, so a typo in a clock or reset name is not an error -- it is
    # a floating wire. The ddr top calls its reset ps_rstn, not rstn, so
    # .rstn(rstn) there holds a block in permanent reset -- and a design full
    # of permanently reset blocks synthesizes, meets timing, loads and runs.
    # The only symptom is the thing those blocks were supposed to do.
    if ! iverilog -g2005 -Wportbind -Wimplicit -t null -o /dev/null "$@" \
            > "$work/$name.elab" 2>&1; then
        grep -v 'inherited\|timescale is here' "$work/$name.elab" >&2
        echo "run.sh: $name did not elaborate" >&2
        fail=$((fail + 1))
        return
    fi
    if grep -qE 'expects .* bit\(s\), given|implicit definition of wire' \
            "$work/$name.elab"; then
        grep -E 'expects .* bit\(s\), given|implicit definition of wire' \
            "$work/$name.elab" | sed 's/^/  /' >&2
        echo "run.sh: $name has width mismatches or implicit nets" >&2
        fail=$((fail + 1))
        return
    fi
    echo "  ok    every port width agrees, no implicit nets"
}

# Each design elaborates against ITS OWN stubs. The two configure the PS7
# differently and instantiate different IP, so one set cannot describe both:
# sharing one would make whichever design was not generated last fail against
# ports that are perfectly real in its own build.
#
# The Ethernet core is SystemVerilog and is not instantiated by either top
# level, so it is excluded here rather than forcing -g2012 on everything.
if [ -f "$here/stubs/board/ps7_rkz7100_stub.v" ]; then
    # The whole stub directory, not the PS7 by name: this design also
    # instantiates the capture VDMA and its protocol converter, and naming
    # one stub means a new IP fails to elaborate rather than being checked.
    elaborate rkz7100_pl "$here/stubs/xilinx_prims.v" \
              "$here/stubs/board"/*_stub.v "$RTL"/*.v
else
    printf '=== elaborate rkz7100_pl\n'
    echo "  skipped -- no stubs; run pl/tools/gen_ip_stubs.py <build> board"
fi

if [ -f "$here/stubs/ddr/mig_rkz7100_stub.v" ]; then
    elaborate rkz7100_ddr "$here/stubs/xilinx_prims.v" \
              "$here/stubs/ddr"/*_stub.v \
              "$repo/pl/ddr/rtl"/*.v \
              "$RTL/axi4_regs.v" "$RTL/fan_ctrl.v" "$RTL/emio_pads.v" \
              "$RTL/axi_bist.v" "$RTL/freq_ctr.v" "$RTL/axi_owner.v"
else
    printf '=== elaborate rkz7100_ddr\n'
    echo "  skipped -- no stubs; run pl/tools/gen_ip_stubs.py <build> ddr"
fi

# ---------------------------------------------------------------------------
# Verilator lint of both top levels, every warning class on except these,
# each an idiom this RTL uses on purpose:
#
#   WIDTHEXPAND   a counter compared with an integer parameter: Verilog
#                 zero-extends the counter, which is the intended meaning
#   UNUSEDSIGNAL  full AXI interfaces whose IDs and responses a master
#                 ignores, and register fields that are stored and read
#                 back but drive nothing
#   PROCASSINIT   an initial value on a register that is also reset: the
#                 value the fabric powers up with, which the CDC flops need
#   PINCONNECTEMPTY  primitive and IP outputs left open by name, on purpose
#   TIMESCALEMOD  some RTL files carry a timescale and some do not; no RTL
#                 file has a delay, so the unit never matters
#   DECLFILENAME, MULTITOP  several files hold helpers beside their module
#
# The stubs are linted with the RTL but their warnings are not counted: the
# ODDR stub drives Q from both edges, which is what an ODDR is.
#
# Verilator is optional here. Without it the step says so and the run stays
# green on the Icarus results alone.
# ---------------------------------------------------------------------------
LINT_W="-Wall -Wno-DECLFILENAME -Wno-MULTITOP -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL
        -Wno-PROCASSINIT -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY"
VL=$(command -v verilator_bin 2>/dev/null || command -v verilator_bin.exe 2>/dev/null || true)
# verilator_bin finds its include files through VERILATOR_ROOT, which the
# oss-cad-suite wrapper normally sets; here it is derived from where the
# binary is.
if [ -n "$VL" ] && [ -z "${VERILATOR_ROOT:-}" ]; then
    VERILATOR_ROOT=$(cd "$(dirname "$VL")/../share/verilator" 2>/dev/null && pwd) &&
        export VERILATOR_ROOT
fi

lint() {
    name=$1
    shift
    printf '=== lint %s\n' "$name"
    if [ -z "$VL" ]; then
        echo "  skipped -- no verilator_bin on PATH"
        return
    fi
    $VL --lint-only $LINT_W --top-module "$name" "$@" > "$work/$name.lint" 2>&1
    # Verilator's closing "Exiting due to N warning(s)" counts the stubs'
    # warnings too, so it is not a finding of its own.
    grep -E '^%(Warning|Error)' "$work/$name.lint" \
        | grep -v 'stubs\|^%Error: Exiting due to' > "$work/$name.lint.own" || true
    if [ -s "$work/$name.lint.own" ]; then
        sed 's/^/  /' "$work/$name.lint.own" >&2
        echo "run.sh: $name has lint findings" >&2
        fail=$((fail + 1))
        return
    fi
    echo "  ok    no findings"
}

if [ -f "$here/stubs/board/ps7_rkz7100_stub.v" ]; then
    lint rkz7100_pl "$STUBS" "$here/stubs/board"/*_stub.v "$RTL"/*.v
fi
if [ -f "$here/stubs/ddr/mig_rkz7100_stub.v" ]; then
    lint rkz7100_ddr "$STUBS" "$here/stubs/ddr"/*_stub.v \
         "$repo/pl/ddr/rtl"/*.v \
         "$RTL/axi4_regs.v" "$RTL/fan_ctrl.v" "$RTL/emio_pads.v" \
         "$RTL/axi_bist.v" "$RTL/freq_ctr.v" "$RTL/axi_owner.v"
fi

# ---------------------------------------------------------------------------
# The line buffers in fb_reader must map to block RAM. Both forms of a read
# simulate the same, so no bench can see it: a combinational read builds
# 320 distributed-RAM primitives instead of four block RAMs, and the design
# still works. Yosys's 7-series synthesis says which one the RTL asks for.
# Optional, like the lint: skipped when yosys is not on PATH.
# ---------------------------------------------------------------------------
printf '=== block RAM: fb_reader\n'
if command -v yosys >/dev/null 2>&1; then
    # Paths inside a yosys script are not converted for a native Windows
    # yosys the way command-line arguments are, so convert them here.
    fb_src="$RTL/fb_reader.v"; fb_out="$work/fb.stat"
    if command -v cygpath >/dev/null 2>&1; then
        fb_src=$(cygpath -m "$fb_src"); fb_out=$(cygpath -m "$fb_out")
    fi
    yosys -q -p "read_verilog $fb_src; synth_xilinx -top fb_reader -family xc7; tee -q -o $fb_out stat" \
        > "$work/fb.yosys" 2>&1
    if grep -q 'RAMB36E1\|RAMB18E1' "$work/fb.stat" 2>/dev/null &&
       ! grep -q 'RAM32M\|RAM64M\|RAM128X1D\|RAM256X1S' "$work/fb.stat"; then
        echo "  ok    the line buffers are block RAM"
    else
        grep -E 'RAMB|RAM32|RAM64|RAM128|RAM256' "$work/fb.stat" 2>/dev/null | sed 's/^/  /' >&2
        echo "run.sh: fb_reader's line buffers are not block RAM" >&2
        fail=$((fail + 1))
    fi
else
    echo "  skipped -- no yosys on PATH"
fi

echo
if [ $fail -eq 0 ]; then
    echo "pl/sim: PASS"
else
    echo "pl/sim: FAIL -- $fail step(s)" >&2
fi
exit $fail

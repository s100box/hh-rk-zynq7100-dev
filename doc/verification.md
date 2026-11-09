# RK-ZYNQ7100 verification guide

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

See the [README](../pl/sim/README.md) for orientation. Commands use repository-root
paths unless a procedure explicitly changes directory.

**Contents**

- [The benches](#the-benches)
- [What the benches are built to avoid](#what-the-benches-are-built-to-avoid)
- [The elaboration checks](#the-elaboration-checks)
- [The lint](#the-lint)
- [The block-RAM check](#the-block-ram-check)
- [Regenerating the stubs](#regenerating-the-stubs)
- [Coverage](#coverage)

```
PATH="$HOME/oss-cad-suite/bin:$PATH" pl/sim/run.sh   # or wherever iverilog lives
```

Seventeen benches, run by Icarus Verilog; an elaboration of each top level
against its IP stubs; a Verilator lint of each top level; and a Yosys check
that `fb_reader`'s line buffers map to block RAM. The whole run
takes a few minutes, most of it `hdmi_rx_capture_tb`. Exits non-zero if any
step fails, so it works as a gate.

⚠ On a Windows host iverilog loads its DLLs from `PATH` and exits 127 with no
message when it gets the wrong ones. Shared tool discovery used by `run.sh`
puts both oss-cad-suite's `bin` and `lib` on PATH. The runner also requires
Python 3.10+ and the `retrosim-build` sibling.

Verilator and Yosys are optional: without `verilator_bin` or `yosys` on
`PATH` the lint or the block-RAM step says it was skipped, and the run stays
green on the Icarus results alone.

The RTL passes here before a Vivado build is worth starting. A synthesis run
costs twenty minutes and a board session costs more, and neither one tells you
which beat went wrong.

## The benches

Each bench is a file list in `benches/`: `<bench>.f` names the bench, the
models and the RTL it checks, one path per line from the repository root, and
says what the bench is for. A `-g2012` line marks a bench that needs
SystemVerilog. `run.sh` runs one per file list, in name order, and `cov.sh`
builds the same lists; a new bench is a new `.f` file.

| Bench | What it pins down |
|---|---|
| `axi4_regs_tb` | the register file, AXI3 bursts, the sub-block windows, and a **read and a write on the same cycle** |
| `axi_bist_axi4_tb` | the BIST engine at 32 bits / AXI4 / 12-bit ID port, the MIG's dialect |
| `axi_bist_tb` | the AXI master: clean run, a **valid word moved to the wrong address**, a flipped bit, a slave that stops answering |
| `axi_owner_tb` | the MIG ownership switch, using two real BIST engines as masters, including a response that arrives with nothing outstanding and a refused 256-beat read that must get exactly 256 beats |
| `axis_cdc_fifo_tb` | the pixel clock to AXI clock crossing, at three clock ratios |
| `cam_guard_tb` | the camera guard: the CSI-2 receiver is never stalled, and a downstream stall costs one frame, not the stream |
| `emio_pads_tb` | EMIO GPIO pads: driven, released to the pull-up, and read back, per bit |
| `eth_crc32_tb` | the FCS against the published check value, from outside this design |
| `eth_mac_tb` | TX→RX loopback: the SFD, padding to the minimum, the FCS verdict, and recovery after a bad frame |
| `fan_ctrl_tb` | the fan's inverted PWM, the full-speed fallback to the exact clock, force-off, and the tachometer count |
| `fb_reader_tb` | the framebuffer scanout, with **every pixel its own address**; no line late in normal frames, late lines counted when reads are held off, and a whole picture again after |
| `freq_ctr_tb` | three live clocks and one that never ticks |
| `gtx_prbs_tb` | the SFP PRBS exerciser against a model of the transceiver: register decode, the clock crossings, exact error and cycle counts, and the DRP rate change |
| `hdmi_out_tb` | the whole HDMI output: each mode's pixel clock computed from its MMCM settings (720p and 1080p exact to 1 ppm), MMCM lock and reset, the ODDR clock, and **the pixel arriving with the DE and syncs that describe it** |
| `hdmi_rx_capture_tb` | the HDMI input capture block at 720p, 1080p and 640×480, with **every pixel carrying its own coordinates**, a cold start in 640×480's vertical blank whose first frame must be captured, and a dead pixel clock that must read as no measurement |
| `video_timing_tb` | one line each of 720p, 1080p and 640×480 and a whole 640×480 frame, against CEA-861 constants written out a second time |
| `video_tpg_tb` | the test pattern: border, bar edges, moving bar and ramp, each on its exact pixel |

## What the benches are built to avoid

Each rule below exists because the obvious version of the test passes on a
wrong design.

**A comparison against a second copy of the same logic proves nothing.**
`eth_crc32_tb` checks CRC-32 of `"123456789"` against `0xCBF43926`, the
published check value — because a CRC with its conventions reversed is
perfectly self-consistent, and a transmitter and receiver sharing the mistake
agree with each other forever and are rejected by everything else on the wire.
`video_timing_tb` writes the CEA constants out again from the standard rather
than reading the module's parameters, so a typo disagrees with itself.

**A pattern that does not depend on the address hides address bugs.**
`axi_bist` derives every 32-bit lane from its own byte address, and the bench
proves that matters by moving a *valid* word to the wrong place and requiring
the engine to notice. An LFSR pattern sails through that.

**A memory model that never stalls is blind.** `axi_mem_bfm` refuses a
handshake on every channel at random and answers reads after a latency. A
master that assumes `WREADY` is always high passes against a zero-delay model
and then hangs on the real `S_AXI_HP`.

**A loopback only proves the two halves agree.** `eth_mac_tb` sits on top of
`eth_crc32_tb` for exactly that reason: a green loopback means something only
when `eth_crc32_tb` is green too.

## The elaboration checks

Not simulations — wiring checks, run against stubs generated from each IP's own
`.veo` template by `pl/tools/gen_ip_stubs.py`:

```
iverilog -g2005 -Wportbind -Wimplicit -t null
```

- **`-Wportbind`** catches a bus connected at the wrong width. Narrowing
  `hp1_wdata` to 32 bits in the full design's top reports *"Port 205
  (S_AXI_HP1_WDATA) of module ps7_rkz7100 expects 64 bit(s), given 32."*
- **`-Wimplicit`** catches a port connected to a net that does not exist.
  Verilog invents a one-bit net for an undeclared identifier, so a typo in a
  clock or reset name is not an error — it is a floating wire. The `ddr` top
  calls its reset `ps_rstn`, so a block wired there to `.rstn(rstn)` sits in
  permanent reset, and the bitstream still synthesizes, meets timing, loads
  and runs.

⚠ One stub directory **per design**. The two configure the PS7 differently —
the full design enables GEM1 over EMIO, `S_AXI_HP0` and `S_AXI_HP3` and six fabric
interrupts, `ddr` none of the first three and three interrupts — so a shared set makes the other design fail
against ports that are perfectly real in its own build.

⚠ The stubs declare the same module names as the real IP. They live here and
must never reach a synthesis file list, where they would replace the IP with a
block that answers nothing.

## The lint

Verilator lints both top levels with `-Wall`, less the warning classes this
RTL triggers on purpose (`run.sh` lists each with its reason). The stubs are
linted alongside but their warnings are not counted. The lint takes every
`.v` in `board/rtl`, so `fb_reader` is parsed with the rest although no top
instantiates it; the Ethernet core is SystemVerilog and is not on the list.

## The block-RAM check

`fb_reader`'s line buffers must be block RAM, and no bench can tell: a
buffer read combinationally simulates exactly like one read through a
register, but synthesis can only build it from distributed RAM -- 320
`RAM64M` primitives here instead of four `RAMB36E1`. `run.sh` runs Yosys's
7-series synthesis on the module and fails unless it finds block RAM and no
distributed RAM.

## Regenerating the stubs

```
python pl/tools/gen_ip_stubs.py <outdir>/board board
python pl/tools/gen_ip_stubs.py <outdir>/ddr   ddr
```

where `<outdir>` is the build's output root: `$RKZ7100_BUILD`, or by default
`C:/rkz7100-build` on Windows and `~/rkz7100-build` elsewhere.

They are checked in so the benches run with no Vivado tree. Regenerate when an
IP's configuration changes which ports exist or how wide they are.

## Coverage

```
pl/sim/cov.sh            # every bench
pl/sim/cov.sh hdmi       # only the benches whose name contains "hdmi"
```

Builds every bench's file list with Verilator (5.x, `--timing`) and line,
branch and toggle coverage, runs it, merges the results, and prints a table
per RTL file (`cov_summary.py`; `--missed` lists each missed line and branch).
The benches check themselves under Verilator as they do under Icarus, so a
bench that fails there is reported too. `coverage.vlt` keeps the benches and
models out of the count. Output goes to `$RKZ7100_COV` (default
`${TMPDIR:-/tmp}/rkz7100-cov`), with an annotated copy of every source.
Coverage is opt-in and not part of the gate.

On native Windows, the shared builder refreshes Verilator's generated C++
source list after HDL or include changes; see the
[shared helper contract](https://github.com/s100box/retrosim-build/blob/main/doc/host-services.md#3-manifest-benches-and-coverage).

The [coverage baseline](coverage.md) owns the per-file figures, collection
revisions and uncovered-case triage for all seventeen benches. The top levels
are checked separately by elaboration and lint; they are not instantiated by
the coverage benches. Rerun the full suite after RTL, manifest or bench changes.

## Recovery and backpressure regressions

- `axi4_regs_tb` stalls both beats of a counter/status burst while live values
  change, then checks that a fresh access sees the new value.
- `axi_owner_tb` requests handover with AW and AR stalled, verifies the offers
  persist, and holds responses before allowing the switch. It also offers W
  before AW, checks a slave whose AWREADY waits for WVALID, and drains a partial
  data burst accepted before its address before changing ownership.
- `axi_bist_tb` stops write and read runs before address acceptance, then
  checks that exactly the offered burst drains without a watchdog. Write data
  must be offered while AWREADY is low to avoid a legal slave dependency
  deadlocking the master. The bench also samples the memory model's randomized
  stall decisions to check their configured probability.
- `fan_ctrl_tb` seeds the tachometer near saturation and checks both interior
  pulses and a pulse on the measurement boundary.

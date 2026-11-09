# hh-rk-zynq7100 coverage

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

[README](../README.md) · [Design](hh-rk-zynq7100-design.md)

## Collection

All 17 manifest benches pass with Verilator 5.049, native Windows MSVC,
and the shared runner. This is a software simulation baseline, not a new
hardware measurement. Release source trees (Git object IDs):

- `hh-rk-zynq7100-dev/pl/board/rtl/`: `a521a4e994f8f9b27247bd2f832aa58fe2d6ee53`
- `hh-rk-zynq7100-dev/pl/ddr/rtl/`: `0338948e2b8a39f2aa359765249a5e0895c197c7`
- `hh-rk-zynq7100-dev/pl/sim/`: `5f318cc36f10b9ea84bba8b8cfbad1fe91a2d441`

These content identities remain valid when commit history is repackaged.

Coverage points are merged across instances by logical identity. From the
repository root, regenerate the measurements and table with:

```sh
python ../retrosim-build/tools/bench_suite.py pl/sim/suite.json --mode coverage --jobs 2 --output tmp/coverage
python pl/sim/cov_summary.py tmp/coverage/merged.dat --md
```

Replace the table below with the summary output; retain and review the collection
provenance and hole triage. `--missed` lists uncovered line and branch points.
Run the full suite when refreshing this baseline; a filtered run has a narrower
scope. Coverage is optional and is not a commit gate.

## Design RTL

| File | Line | Branch | Toggle |
|---|---:|---:|---:|
| `axi4_regs.v` |  84.2% (32/38) |  72.9% (51/70) |  33.5% (697/2080) |
| `axi_bist.v` |  74.4% (29/39) |  90.0% (54/60) |  50.5% (1240/2454) |
| `axi_owner.v` | 100.0% (6/6) | 100.0% (140/140) |  48.7% (852/1748) |
| `axis_cdc_fifo.v` | 100.0% (13/13) | 100.0% (4/4) |  80.9% (212/262) |
| `cam_guard.v` | 100.0% (5/5) | 100.0% (18/18) |  33.7% (173/514) |
| `emio_pads.v` | -- | -- |  91.7% (22/24) |
| `eth_crc32.sv` | 100.0% (6/6) | 100.0% (4/4) | 100.0% (214/214) |
| `eth_mac_rx.sv` |  80.0% (8/10) |  70.0% (7/10) |  90.9% (211/232) |
| `eth_mac_tx.sv` |  91.7% (11/12) |  90.9% (20/22) |  92.6% (274/296) |
| `fan_ctrl.v` | 100.0% (8/8) | 100.0% (10/10) |  58.0% (153/264) |
| `fb_reader.v` | 100.0% (11/11) |  97.5% (39/40) |  19.6% (316/1616) |
| `freq_ctr.v` | 100.0% (10/10) | 100.0% (12/12) |  31.2% (95/304) |
| `gtx_prbs.v` |  92.2% (94/102) |  91.4% (53/58) |  58.7% (1492/2542) |
| `hdmi_out.v` | 100.0% (2/2) |  50.0% (1/2) |  91.1% (173/190) |
| `hdmi_rx_capture.v` | 100.0% (46/46) |  83.3% (40/48) |  51.0% (693/1358) |
| `video_timing.v` | 100.0% (2/2) | 100.0% (16/16) |  94.1% (111/118) |
| `video_tpg.v` | 100.0% (12/12) | 100.0% (26/26) |  74.2% (178/240) |
| **TOTAL** |  91.6% (295/322) |  91.7% (495/540) |  49.2% (7106/14456) |

## Hole triage

The two top levels are elaborated and linted separately, not simulated by
these benches. Their wiring and status multiplexers are outside this report.
Wide counters and data paths do not reach every upper bit in a short simulation.
The remaining line and branch holes include AXI error/timeout recovery, GTX
failure paths, and capture/framebuffer control cases. They remain counted;
the figures do not establish those cases as unreachable. `pl/sim/coverage.vlt`
excludes testbenches and behavioral models.

Directed tests for these remaining cases are still needed.

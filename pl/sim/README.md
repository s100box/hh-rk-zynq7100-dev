# RK-ZYNQ7100 PL verification

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

Automated checks for the board and DDR programmable-logic designs.

## Documentation

| Document | Contents |
|---|---|
| [Verification guide](../../doc/verification.md) | Bench inventory, test strategy, elaboration, lint, and coverage. |
| [Design](../../doc/hh-rk-zynq7100-design.md) | Interfaces and hardware validation. |
| [Shared host services](https://github.com/s100box/retrosim-build/blob/main/doc/host-services.md) | Manifest runner and coverage contracts. |

## Repository layout

| Path | Contents |
|---|---|
| `benches/` | One source list per testbench. |
| `suite.json` | Consumer compiler options, verdict pattern and resource limits. |
| `run.sh` | Simulation, elaboration, lint, and inference gate. |
| `cov.sh`, `coverage.vlt` | Optional Verilator coverage. |

## Requirements

Python, Icarus Verilog and the sibling `retrosim-build` are required.
Verilator and Yosys enable additional checks;
their absence is reported as a skip. Coverage also needs Verilator with
`--timing`, a C++ toolchain, and Python. See the root
[requirements](../../README.md#requirements).

## Getting started

From the repository root:

```sh
pl/sim/run.sh
```

On Windows, put the OSS CAD Suite's `bin` on PATH; the runner adds its `lib`
directory. Run the gate before synthesis.

## Verification

The runner exits nonzero if a check fails. See the
[verification guide](../../doc/verification.md) for individual checks,
stub regeneration, optional coverage commands, and recorded coverage limits.

## License

See the repository [license](../../README.md#license).

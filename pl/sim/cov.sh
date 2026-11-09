#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Consumer manifests and verdict policy are declared in suite.json.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
py=$(command -v python3 || command -v python)
build=${RETROSIM_BUILD:-$here/../../../retrosim-build}
exec "$py" "$build/tools/bench_suite.py" "$here/suite.json" "${1:-}" --mode coverage --output "${RKZ7100_COV:-${TMPDIR:-/tmp}/rkz7100-cov}"

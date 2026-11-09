# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Generate the canonical boot PS7 initialization without synthesizing PL.
# From the repository root:
#   vivado -mode batch -nojournal -nolog -source linux/gen_ps7.tcl -tclargs <outdir>
# Both PL builds call the same helper automatically. The top-level artifact is
# <outdir>/ps7_init.tcl; boot-init/ also contains generated GPL C/H products for
# maintainers updating the tracked SPL sources. Generated files retain notices.
set outdir [lindex $argv 0]
if {$outdir eq "" || [llength $argv] != 1} {
    error "usage: vivado -mode batch -source linux/gen_ps7.tcl -tclargs <outdir>"
}
source [file join [file dirname [file normalize [info script]]] ps7_init_build.tcl]
rkz7100::generate_ps7_init $outdir

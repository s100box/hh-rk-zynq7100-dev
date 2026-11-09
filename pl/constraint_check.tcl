# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Does the set_clock_groups block in the timing XDC actually apply?
#
# ⚠ ONE FILE, BOTH DESIGNS. A per-design copy of a gate drifts, and half a
# gate is worse than none: a check that fires on a healthy design teaches
# everyone to argue the next real failure away.
#
# Call from the implementation stage, with the routed design open:
#     source [file join $repo pl constraint_check.tcl]
#     rkz_check_clock_groups {pl_clk gtx_clk156 gtx_sataclk}
#
# Raises an error, so it stops the build.

proc rkz_check_clock_groups {want} {
    puts "==== CONSTRAINT CHECK"
    puts "====   clocks defined: [lsort [get_clocks -quiet *]]"
    set missing {}
    set crossed {}
    foreach c $want {
        set ck [get_clocks -quiet $c]
        if {[llength $ck] == 0} {
            lappend missing $c
            continue
        }
        # Vivado has no remove_from_collection, and get_clocks has no "not
        # this one": build the complement by name.
        set names [get_property NAME $ck]
        # VIRTUAL clocks are left out of "other". They have no source pin and
        # exist only to describe an external device's timing -- the
        # gmii_to_rgmii core, for one, times RGMII receive data against its own
        # virtual copy of the receive clock -- so the paths from them to the
        # real clock ARE the I/O timing, and must stay timed.
        set other {}
        foreach o [get_clocks -quiet *] {
            if {[lsearch -exact $names [get_property NAME $o]] >= 0} continue
            if {[llength [get_property SOURCE_PINS $o]] == 0} continue
            lappend other $o
        }
        set n 0
        if {[llength $other]} {
            # ⚠ Count paths that are TIMED, not paths that exist.
            # get_timing_paths returns unconstrained paths as well, and the
            # crossings inside freq_ctr are SUPPOSED to be there -- a latched
            # word and a gate, each through a synchronizer. What the clock
            # grouping changes is whether they carry a requirement, and an
            # unconstrained path reports an EMPTY slack.
            foreach p [get_timing_paths -quiet -from $ck -to $other -max_paths 8] {
                if {[get_property SLACK $p] ne ""} { incr n }
            }
            foreach p [get_timing_paths -quiet -from $other -to $ck -max_paths 8] {
                if {[get_property SLACK $p] ne ""} { incr n }
            }
        }
        if {$n > 0} { lappend crossed $c }
        puts "====   $c: $n TIMED path(s) to other clocks (0 = asynchronous, as intended)"
    }
    if {[llength $missing]} {
        puts "====   MISSING CLOCKS: $missing"
        error "expected clocks were never created -- check the XDC pin names"
    }
    if {[llength $crossed]} {
        error "clock crossings are still being timed for: $crossed -- the set_clock_groups block matched nothing"
    }
    puts "==== CONSTRAINT CHECK OK"
}

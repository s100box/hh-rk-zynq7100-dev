# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Source-only boot-init generator. Use the canonical boot PS7 configuration,
# independently of each PL design's peripheral/AXI-port overrides.
namespace eval rkz7100 {
    variable ps7_dir [file dirname [file normalize [info script]]]
}
set rkz7100_shared [file normalize [file join $rkz7100::ps7_dir ../../retrosim-build]]
if {[info exists ::env(RETROSIM_BUILD)]} { set rkz7100_shared $::env(RETROSIM_BUILD) }
source [file join $rkz7100_shared vivado.tcl]
unset rkz7100_shared

proc rkz7100::produce_ps7_init {outdir} {
    variable ps7_dir
    source [file join $ps7_dir board ps7_config.tcl]
    file mkdir $outdir/ip
    create_project -force ps7cfg $outdir/project -part xc7z100ffg900-2
    create_ip -name processing_system7 -vendor xilinx.com -library ip -version 5.5 \
        -module_name ps7_rkz7100 -dir $outdir/ip
    set ps [get_ips ps7_rkz7100]

    # ⚠ THE WHOLE LIST IN ONE CALL, as the block design applied it. Applied one
    # property at a time the IP validates each against the state so far, and the
    # list is alphabetical: PCW_MIO_16_IOTYPE {LVCMOS 1.8V} arrives before
    # PCW_PRESET_BANK1_VOLTAGE has moved bank 501 off its 3.3V default, and is
    # refused as "out of range { LVCMOS 3.3V }" -- fourteen MIO pins and the USB
    # reset pin are lost that way. The PCW_ACT_* entries are left
    # out: they are values Vivado computes, and one refused key would sink the call.
    set settable {}
    foreach {k v} $PS7_CONFIG {
        if {![string match CONFIG.PCW_ACT_* $k]} { lappend settable $k $v }
    }
    if {[catch {set_property -dict $settable $ps} err]} {
        puts "==== the one-call apply was refused; retrying per property ===="
        puts "  $err"
    }
    # A second, per-property pass picks up anything the first left different, and
    # names what is still refused after it.
    set refused {}
    foreach {k v} $settable {
        if {[catch {set got [get_property $k $ps]}] || $got ne $v} {
            if {[catch {set_property $k $v $ps}]} { lappend refused $k }
        }
    }
    puts "==== REFUSED: [llength $refused] ===="
    foreach k $refused { puts "  $k" }

    # Read back what the IP holds and compare with what was asked for. Anything
    # that differs is printed: a PS that quietly did not take a DDR or MIO setting
    # is the failure this whole file exists to prevent.
    set diffs 0
    foreach {k v} $PS7_CONFIG {
        if {[string match CONFIG.PCW_ACT_* $k]} continue
        if {[catch {set got [get_property $k $ps]}]} {
            puts "  MISSING $k"
            incr diffs
            continue
        }
        if {$got ne $v} {
            puts [format "  DIFF %-40s wanted {%s} got {%s}" $k $v $got]
            incr diffs
        }
    }
    puts "==== READBACK DIFFERENCES: $diffs ===="
    if {[llength $refused] || $diffs} { error "PS7 configuration incomplete; no boot init published" }
    foreach k {PCW_CRYSTAL_PERIPHERAL_FREQMHZ PCW_UIPARAM_DDR_PARTNO PCW_UIPARAM_DDR_BUS_WIDTH
               PCW_UIPARAM_DDR_FREQ_MHZ PCW_PRESET_BANK0_VOLTAGE PCW_PRESET_BANK1_VOLTAGE
               PCW_QSPI_QSPI_IO PCW_UART0_UART0_IO PCW_ENET0_ENET0_IO PCW_USB0_USB0_IO
               PCW_SD0_SD0_IO PCW_SD1_SD1_IO PCW_USB0_RESET_IO} {
        puts [format "  %-34s %s" $k [get_property CONFIG.$k $ps]]
    }

    generate_target all [get_files ps7_rkz7100.xci]
    # Keep vendor output intact, including any notices the installed tool emits.
    # Publish only after all products exist; a partial run gets no cache receipt.
    foreach name {ps7_init.tcl ps7_init_gpl.c ps7_init_gpl.h} {
        set product [file join $outdir ip ps7_rkz7100 $name]
        if {![file isfile $product] || [file size $product] == 0} {
            error "PS7 generation did not produce $product"
        }
        file copy -force $product [file join $outdir $name]
    }
    close_project
}

proc rkz7100::generate_ps7_init {outdir} {
    variable ps7_dir
    set outdir [file normalize $outdir]
    file mkdir $outdir
    set cache [file join $outdir boot-init]
    set published [file join $outdir ps7_init.tcl]
    # A failed regeneration must not leave an old published Tcl looking current.
    file delete -force $published
    retrosim::cached_ip $cache $outdir \
        [list [file join $ps7_dir ps7_init_build.tcl] [file join $ps7_dir board ps7_config.tcl]] \
        [file join $cache ps7_init.tcl] [list rkz7100::produce_ps7_init $cache]
    set artifact [file join $cache ps7_init.tcl]
    if {[file size $artifact] == 0} { error "empty PS7 initialization: $artifact" }
    file copy -force $artifact $published
    puts "PS7 boot initialization: $published"
    return $published
}

# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Exercise PS7 generation failure handling, cache freshness and Linux staging."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tkinter
import unittest

LINUX = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stage_ps7", LINUX / "tools/stage_ps7.py")
stage_ps7 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage_ps7)


class GenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ps7 build ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "inputs"
        (self.config / "board").mkdir(parents=True)
        for name in ["ps7_init_build.tcl", "board/ps7_config.tcl"]:
            shutil.copyfile(LINUX / name, self.config / name)
        self.out = self.root / "out"
        self.tcl = tkinter.Tcl()
        self.tcl.call("source", str(LINUX / "ps7_init_build.tcl"))
        self.tcl.setvar("rkz7100::ps7_dir", str(self.config))
        self.tcl.setvar("env(PYTHON3)", sys.executable)
        # Vendor commands are mocked; the real shared cache and generator's
        # property validation run against the complete board configuration.
        self.tcl.eval(r"""
            set generations 0
            set fault {}
            set properties [dict create]
            proc version {args} { return 2026.1 }
            proc create_project {args} {
                incr ::generations
                set ::properties [dict create]
            }
            proc create_ip {args} {
                set ::ipdir [lindex $args [expr {[lsearch -exact $args -dir] + 1}]]
            }
            proc get_ips {args} { return ps7 }
            proc get_files {args} { return ps7.xci }
            proc close_project {} {}
            proc set_property {args} {
                if {[lindex $args 0] eq "-dict"} {
                    if {$::fault eq "refused"} { error "batch refused" }
                    set pairs [lindex $args 1]
                } else { set pairs [lrange $args 0 1] }
                foreach {k v} $pairs {
                    if {$k eq "CONFIG.PCW_UART0_PERIPHERAL_ENABLE"} {
                        if {$::fault eq "refused"} { error "setting refused" }
                        if {$::fault eq "ignored"} { continue }
                    }
                    dict set ::properties $k $v
                }
            }
            proc get_property {k object} {
                if {$k eq "CONFIG.PCW_UART0_PERIPHERAL_ENABLE" && $::fault eq "missing"} {
                    error "unreadable setting"
                }
                if {[dict exists $::properties $k]} { return [dict get $::properties $k] }
                return unset
            }
            proc generate_target {args} {
                set dir [file join $::ipdir ps7_rkz7100]
                file mkdir $dir
                foreach name {ps7_init.tcl ps7_init_gpl.c ps7_init_gpl.h} {
                    set f [open [file join $dir $name] w]
                    if {$::fault ne "empty"} { puts $f "generated $name" }
                    close $f
                }
            }
        """)

    def generate(self):
        return Path(str(self.tcl.call("rkz7100::generate_ps7_init", str(self.out))))

    def test_cache_reuse_and_input_change(self):
        output = self.generate()
        self.assertTrue(output.is_file())
        self.generate()
        self.assertEqual(self.tcl.getvar("generations"), 1)
        with (self.config / "board/ps7_config.tcl").open("a") as stream:
            stream.write("\n# changed input\n")
        self.generate()
        self.assertEqual(self.tcl.getvar("generations"), 2)

    def test_missing_cached_product_is_regenerated(self):
        self.generate()
        (self.out / "boot-init/ps7_init.tcl").unlink()
        self.generate()
        self.assertEqual(self.tcl.getvar("generations"), 2)

    def test_failed_regeneration_never_publishes_stale_output(self):
        output = self.generate()
        with (self.config / "board/ps7_config.tcl").open("a") as stream:
            stream.write("\n# require regeneration\n")
        self.tcl.setvar("fault", "refused")
        with self.assertRaises(tkinter.TclError):
            self.generate()
        self.assertFalse(output.exists())
        self.assertFalse((self.out / "boot-init/.retrosim-ip.key").exists())

    def test_refused_ignored_missing_and_empty_outputs_fail(self):
        for fault in ["refused", "ignored", "missing", "empty"]:
            with self.subTest(fault=fault):
                self.tcl.setvar("fault", fault)
                self.tcl.eval("set properties [dict create]")
                with self.assertRaises(tkinter.TclError):
                    self.generate()
                self.assertFalse((self.out / "ps7_init.tcl").exists())
                self.assertFalse((self.out / "boot-init/.retrosim-ip.key").exists())


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ps7 stage ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.destination = self.root / "images"
        self.destination.mkdir()
        self.target = self.destination / "ps7_init.tcl"

    def test_discover_beside_bitstream_and_preserve_bytes(self):
        source = self.root / "ps7_init.tcl"
        source.write_bytes(b"# vendor output\r\nproc ps7_init {} {}\r\n")
        self.assertTrue(stage_ps7.stage(self.destination, bitstream=self.root / "board.bit"))
        self.assertEqual(self.target.read_bytes(), source.read_bytes())

    def test_explicit_selection_overrides_bitstream(self):
        source = self.root / "explicit.tcl"
        source.write_text("explicit initialization")
        self.assertTrue(stage_ps7.stage(self.destination, init=source, bitstream=self.root / "board.bit"))
        self.assertEqual(self.target.read_bytes(), source.read_bytes())

    def test_optional_absence_removes_stale_output(self):
        self.target.write_text("stale")
        self.assertFalse(stage_ps7.stage(self.destination))
        self.assertFalse(self.target.exists())

    def test_bad_explicit_input_removes_stale_output(self):
        for empty in [False, True]:
            source = self.root / "bad.tcl"
            if empty:
                source.write_text("")
            self.target.write_text("stale")
            with self.assertRaises((FileNotFoundError, ValueError)):
                stage_ps7.stage(self.destination, init=source)
            self.assertFalse(self.target.exists())

    def test_tftp_preflight_requires_generated_init(self):
        # Use the shared Git Bash pin rather than accidentally invoking WSL.
        shared = Path(os.environ.get("RETROSIM_BUILD", LINUX.parents[1] / "retrosim-build"))
        sys.path.insert(0, str(shared / "tools"))
        from retrosim_build.toolchain import Toolchain
        bash = Toolchain().resolve("BASH_EXE").path
        names = ["rkz7100-boot.scr", "uImage", "zynq-rkz7100.dtb",
                 "zynq-rkz7100-usbdev.dtb", "zynq-rkz7100-hdmirx.dtb",
                 "rootfs.cpio.uboot", "u-boot.bin", "boot.bin", "u-boot.img", "rootfs.ext4"]
        for name in names:
            (self.destination / name).write_bytes(b"fixture")
        target = self.root / "tftp"
        env = dict(os.environ, IMAGES=self.destination.as_posix())
        command = [bash, str(LINUX / "stage-tftp.sh"), target.as_posix()]
        failed = subprocess.run(command, env=env, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"ps7_init.tcl", failed.stderr)
        self.assertFalse(target.exists())
        self.target.write_bytes(b"locally generated")
        passed = subprocess.run(command, env=env, capture_output=True)
        self.assertEqual(passed.returncode, 0, passed.stderr.decode(errors="replace"))
        self.assertEqual((target / "ps7_init.tcl").read_bytes(), self.target.read_bytes())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Generate simulation stubs for the Vivado IP the PL designs instantiate.

The top levels instantiate Vivado IP (the PS7, the MIG, the protocol and clock
converters, the GP1 crossbar, the VDMAs, the CSI-2 receiver, the gtwizard and
the GMII-to-RGMII core; see IPS below), which only exist after Vivado has
generated them.
Without stubs nothing above the leaf modules can be elaborated, so a port
connected at the wrong width -- or a port that does not exist at all -- is
not caught until synthesis, twenty minutes later, and then only as an error
in a log nobody reads.

⚠ The source is each IP's .veo INSTANTIATION TEMPLATE, not its internal
wrapper. Those are different interfaces: the PS7 wrapper declares every port
the IP could ever have, including ones a given configuration does not expose.
A stub built from the wrapper happily accepts `.S_AXI_HP1_ARESETN()`, which
synthesis then rejects with "named port connection does not exist". The .veo
lists exactly what was generated, with direction and width in the trailing
comment.

    python pl/tools/gen_ip_stubs.py <outdir>/ddr ddr

(<outdir> is $RKZ7100_BUILD, or by default C:/rkz7100-build on Windows and
~/rkz7100-build elsewhere)

writes pl/sim/stubs/<design>/<module>_stub.v for each IP found. The stubs are
checked in so the benches run without a Vivado tree; regenerate them whenever
an IP's configuration changes which ports exist or how wide they are.

⚠ They model CONNECTIVITY, not behavior. The PS7 stub's FCLK_CLK0/1 run and
FCLK_RESET0_N releases so a top level can be elaborated and clocked; every
other output is tied low and no AXI port answers anything. A design that
elaborates against these is correctly plugged in, which is not the same as
working.

⚠ These files declare the same module names as the real IP. They live in
pl/sim/stubs/ and must never reach a synthesis file list, where they would
silently replace the IP with a block that answers nothing. The build scripts glob
only pl/board/rtl/ and pl/ddr/rtl/, which is why these are kept somewhere else
entirely.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))
# ⚠ One directory per DESIGN, not one set of stubs for the repo. The two
# designs configure the PS7 differently and instantiate different IP, so a
# single stub set cannot describe both, and whichever was generated last would
# make the other design fail to elaborate against ports that are perfectly
# real in its own build.
STUBS_ROOT = os.path.join(REPO, 'pl', 'sim', 'stubs')

# An IP absent from a given build is skipped, not an error: the list is the
# union across designs.
IPS = [
    ('ps7_rkz7100',  'ip/ps7_rkz7100/ps7_rkz7100.veo',   50),
    ('apc',          'ip/apc/apc.veo',                   40),
    ('acc',          'ip/acc/acc.veo',                   40),
    ('mig_rkz7100',  'ip/mig_rkz7100/mig_rkz7100.veo',   40),
    ('vdma_hdmirx',  'ip/vdma_hdmirx/vdma_hdmirx.veo',   30),
    ('apc_vdma_lite', 'ip/apc_vdma_lite/apc_vdma_lite.veo', 40),
    ('gtx_sfp',      'ip/gtx_sfp/gtx_sfp.veo',           50),
    ('gmii_rgmii_phy2', 'ip/gmii_rgmii_phy2/gmii_rgmii_phy2.veo', 30),
    ('csi_cam',      'ip/csi_cam/csi_cam.veo',           30),
    ('vdma_cam',     'ip/vdma_cam/vdma_cam.veo',         30),
    ('xbar_gp1',     'ip/xbar_gp1/xbar_gp1.veo',         30),
]

# The IPs do not all spell the trailing comment the same way:
#   PS7 / converters:  .SIG(SIG),   // input wire [31 : 0] SIG
#   MIG:               .SIG(SIG),   // input [11:0]        SIG
# so `wire` is optional and the colon may or may not have spaces. Getting this
# wrong is silent -- it parses zero ports and the stub is empty -- so the
# caller checks the count against a floor per IP.
PORT_RE = re.compile(
    r'^\s*\.([A-Za-z_]\w*)\s*\([^)]*\)\s*,?\s*'
    r'//\s*(input|output|inout)\s+(?:wire\s+)?'
    r'(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?')

CLOCKS = ('FCLK_CLK0', 'FCLK_CLK1', 'FCLK_CLK2', 'FCLK_CLK3')
RESETS = ('FCLK_RESET0_N', 'FCLK_RESET1_N', 'FCLK_RESET2_N', 'FCLK_RESET3_N')


# Some ports carry no trailing comment at all -- the MIG writes
#     .sys_clk_i                       (sys_clk_i),
# with nothing after it. The comment-based regex above does not match those,
# and without this the stub would reject a port the real IP genuinely has, so
# they are picked up here and assumed to be single-bit inputs. That is safe:
# getting the direction wrong on one fails loudly at elaboration (an input
# cannot be driven by a module output), and the assumption is printed rather
# than made quietly.
BARE_RE = re.compile(r'^\s*\.([A-Za-z_]\w*)\s*\([^)]*\)\s*,?\s*$')


def parse(path):
    text = io.open(path, encoding='utf-8', errors='replace', newline='').read()
    ports, seen, assumed = [], set(), []
    for line in text.split('\n'):
        m = PORT_RE.match(line)
        if m:
            name, direction, msb, lsb = m.groups()
        else:
            mb = BARE_RE.match(line)
            if not mb:
                continue
            name, direction, msb, lsb = mb.group(1), 'input', None, None
            assumed.append(name)
        if name in seen:
            continue
        seen.add(name)
        rng = '' if msb is None else '[%s:%s] ' % (msb, lsb)
        ports.append((direction, rng, name, msb, lsb))
    if assumed:
        print('    (no direction comment, assumed 1-bit input: %s)'
              % ', '.join(assumed))
    return ports


def emit(module, ports):
    out = [
        '// SPDX-License-Identifier: MIT OR Apache-2.0',
        '// SPDX-FileCopyrightText: 2026 Howard M. Harte',
        '//',
        "// GENERATED by pl/tools/gen_ip_stubs.py from the IP's .veo template.",
        '// Do not edit.',
        '//',
        '// A simulation stand-in for %s with exactly the ports the' % module,
        '// generated IP exposes, so a port that does not exist -- or one',
        '// connected at the wrong width -- fails to elaborate here rather',
        '// than in a synthesis log twenty minutes later.',
        '//',
        '// \u26a0 Connectivity only: nothing here answers an AXI transaction.',
        '//',
        '// \u26a0 Never add this file to a synthesis file list. It would',
        '// replace the real IP with a block that drives zeros.',
        '',
        '`timescale 1ns / 1ps',
        '',
        'module %s (' % module,
    ]
    out.append(',\n'.join('    %-6s %s%s' % (d, r, n)
                          for d, r, n, _, _ in ports))
    out.append(');')
    out.append('')
    have = set(n for _, _, n, _, _ in ports)

    out.append('    // Outputs tied low; inouts left floating.')
    for direction, rng, name, msb, lsb in ports:
        if direction != 'output':
            continue
        if name in CLOCKS or name in RESETS:
            continue
        if msb is None:
            out.append("    assign %s = 1'b0;" % name)
        else:
            out.append("    assign %s = %d'd0;" % (name,
                                                   int(msb) - int(lsb) + 1))
    out.append('')

    if any(c in have for c in CLOCKS):
        out.append("    reg fclk0 = 1'b0;")
        out.append("    reg fclk1 = 1'b0;")
        out.append('    always #5   fclk0 = ~fclk0;   // 100 MHz')
        out.append('    always #2.5 fclk1 = ~fclk1;   // 200 MHz')
        for c, r in (('FCLK_CLK0', 'fclk0'), ('FCLK_CLK1', 'fclk1')):
            if c in have:
                out.append('    assign %s = %s;' % (c, r))
        for c in ('FCLK_CLK2', 'FCLK_CLK3'):
            if c in have:
                out.append("    assign %s = 1'b0;" % c)
        out.append('')
    if any(r in have for r in RESETS):
        out.append("    reg rst_n = 1'b0;")
        out.append("    initial begin #200; rst_n = 1'b1; end")
        for r in RESETS:
            if r in have:
                out.append('    assign %s = rst_n;' % r)
        out.append('')
    out.append('endmodule')
    out.append('')
    return '\n'.join(out)


def main():
    if len(sys.argv) < 3:
        sys.exit('usage: gen_ip_stubs.py <vivado-build-dir> <design>\n'
                 '  e.g. gen_ip_stubs.py C:/rkz7100-build/ddr ddr')
    root = sys.argv[1]
    design = sys.argv[2]
    out_dir = os.path.join(STUBS_ROOT, design)
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    made = 0
    for module, veo, floor in IPS:
        src = os.path.join(root, veo)
        if not os.path.exists(src):
            print('  skipped   %-14s (no %s)' % (module, veo))
            continue
        ports = parse(src)
        if len(ports) < floor:
            sys.exit('gen_ip_stubs: only parsed %d ports for %s, which cannot '
                     'be right' % (len(ports), module))
        dst = os.path.join(out_dir, '%s_stub.v' % module)
        io.open(dst, 'w', encoding='utf-8', newline='\n').write(
            emit(module, ports))
        print('  wrote     %-14s %3d ports -> pl/sim/stubs/%s/%s_stub.v'
              % (module, len(ports), design, module))
        made += 1
    if not made:
        sys.exit('gen_ip_stubs: nothing generated -- is %s a Vivado build tree?'
                 % root)


if __name__ == '__main__':
    main()

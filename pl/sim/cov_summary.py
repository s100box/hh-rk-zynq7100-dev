#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Per-file line, branch and toggle coverage from a merged Verilator .dat.

Each record of the .dat is  C '<name>' <count>, where <name> is a run of
\\x01<key>\\x02<value> pairs: t is the metric, f the source file, l the line.
Verilator keeps one record per point per INSTANCE (keys h and page); a point
here is keyed on everything else and counts as covered if any instance hit it.
Only the design RTL is reported: files under pl/board/rtl and
pl/ddr/rtl.

    cov_summary.py merged.dat               the table
    cov_summary.py merged.dat --md          the table in Markdown
    cov_summary.py merged.dat --missed      also each file's missed lines and
                                            branches
"""
import os
import sys

METRICS = ("line", "branch", "toggle")
INSTANCE_KEYS = ("h", "page")
DESIGN_DIRS = ("pl/board/rtl/", "pl/ddr/rtl/")


def design_path(f):
    f = f.replace("\\", "/")
    for d in DESIGN_DIRS:
        i = f.find(d)
        if i >= 0:
            return f[i:]
    return None


def parse(path):
    points = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for rec in fh:
            if not rec.startswith("C '"):
                continue
            end = rec.rfind("' ")
            try:
                count = int(rec[end + 2:])
            except ValueError:
                continue
            kv = dict(p.split("\x02", 1) for p in rec[3:end].split("\x01") if "\x02" in p)
            f = design_path(kv.get("f", ""))
            if f is None or kv.get("t") not in METRICS:
                continue
            key = tuple(sorted((k, v) for k, v in kv.items() if k not in INSTANCE_KEYS))
            prev = points.get(key)
            if prev is None or count > prev[3]:
                points[key] = (f, kv["t"], kv, count)
    return points.values()


def pct(c, t):
    return f"{100.0 * c / t:5.1f}% ({c}/{t})" if t else "--"


def main(argv):
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print(__doc__, file=sys.stderr)
        return 2
    agg, missed = {}, {}
    for f, t, kv, count in parse(files[0]):
        slot = agg.setdefault(f, {m: [0, 0] for m in METRICS})[t]
        slot[1] += 1
        if count:
            slot[0] += 1
        elif t != "toggle":
            missed.setdefault(f, []).append((int(kv.get("l", 0)), t, kv.get("o", "")))
    tot = {m: [0, 0] for m in METRICS}
    rows = []
    for f in sorted(agg):
        for m in METRICS:
            tot[m][0] += agg[f][m][0]
            tot[m][1] += agg[f][m][1]
        rows.append((f, agg[f]))
    rows.append(("TOTAL", tot))
    if "--md" in argv:
        print("| File | Line | Branch | Toggle |")
        print("|---|---:|---:|---:|")
        for f, a in rows:
            name = f"**{f}**" if f == "TOTAL" else f"`{os.path.basename(f)}`"
            print(f"| {name} | " + " | ".join(pct(*a[m]) for m in METRICS) + " |")
    else:
        print(f"{'File':<40} {'Line':>18} {'Branch':>18} {'Toggle':>20}")
        for f, a in rows:
            print(f"{f:<40} {pct(*a['line']):>18} {pct(*a['branch']):>18} {pct(*a['toggle']):>20}")
    if "--missed" in argv:
        for f in sorted(missed):
            print(f"\n{f}")
            for l, t, o in sorted(set(missed[f])):
                print(f"  {l:5d} {t:<6} {o}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Generates src/unicode_tables.zig from the Unicode Character Database.

Usage:
    tools/gen_unicode.py fetch <version> <dir>      download the input files
    tools/gen_unicode.py generate <dir> <out.zig>   write the tables

Inputs (all from https://www.unicode.org/Public/<version>/ucd/):
    UnicodeData.txt            General_Category
    Scripts.txt                Script
    DerivedCoreProperties.txt  Alphabetic, Lowercase, Uppercase
    PropList.txt               White_Space, Join_Control
    PropertyValueAliases.txt   names of General_Category and Script values

To regenerate the checked-in file:

    tools/gen_unicode.py fetch 18.0.0 /some/empty/dir
    tools/gen_unicode.py generate /some/empty/dir src/unicode_tables.zig
    zig fmt src/unicode_tables.zig

The output records the Unicode version and the SHA-256 of every input, so a
regenerated file can be compared with the checked-in one. Surrogates
(U+D800..U+DFFF) are never in a table: they are not scalar values.

Only the Python standard library is used.
"""

import hashlib
import os
import re
import sys
import urllib.request

FILES = [
    "UnicodeData.txt",
    "Scripts.txt",
    "DerivedCoreProperties.txt",
    "PropList.txt",
    "PropertyValueAliases.txt",
]
MAX = 0x10FFFF
SUR = (0xD800, 0xDFFF)

# Aliases for the binary properties we expose (PropertyAliases.txt, short names).
BINARY = {
    "Alphabetic": ["Alpha"],
    "Lowercase": ["Lower"],
    "Uppercase": ["Upper"],
    "White_Space": ["space", "WSpace"],
    "Join_Control": ["Join_C"],
}
# gc groups beyond the first-letter groups (L, M, N, P, S, Z, C).
GC_LC = ["Lu", "Ll", "Lt"]


def loose(name):
    """UAX44-LM3 loose matching: ignore case, spaces, '_' and '-'."""
    return re.sub(r"[ _\-]", "", name).lower()


# ---- range helpers -----------------------------------------------------------


def normalize(ranges):
    """Sort, merge, and cut out surrogates. Ranges are inclusive (lo, hi)."""
    cut = []
    for lo, hi in ranges:
        if hi < SUR[0] or lo > SUR[1]:
            cut.append((lo, hi))
        else:
            if lo < SUR[0]:
                cut.append((lo, SUR[0] - 1))
            if hi > SUR[1]:
                cut.append((SUR[1] + 1, hi))
    cut.sort()
    out = []
    for lo, hi in cut:
        if out and lo <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def complement(ranges):
    out, nxt = [], 0
    for lo, hi in normalize(ranges):
        if lo > nxt:
            out.append((nxt, lo - 1))
        nxt = hi + 1
    if nxt <= MAX:
        out.append((nxt, MAX))
    return normalize(out)


def union(*tables):
    return normalize([r for t in tables for r in t])


# ---- parsing -----------------------------------------------------------------


def parse_ranges(text, want):
    """`LO..HI ; Name # ...` lines, collected by Name. `want` filters names."""
    out = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        rng, name = [x.strip() for x in line.split(";")[:2]]
        if want is not None and name not in want:
            continue
        lo, _, hi = rng.partition("..")
        out.setdefault(name, []).append((int(lo, 16), int(hi or lo, 16)))
    return {k: normalize(v) for k, v in out.items()}


def parse_unicode_data(text):
    gc, first = {}, None
    for line in text.splitlines():
        f = line.split(";")
        cp, name, cat = int(f[0], 16), f[1], f[2]
        if name.endswith(", First>"):
            first = cp
            continue
        lo = first if name.endswith(", Last>") else cp
        first = None
        gc.setdefault(cat, []).append((lo, cp))
    return {k: normalize(v) for k, v in gc.items()}


def parse_aliases(text, prop):
    """[(short, long, extra aliases...)] for `prop ; short ; long ; ...` lines."""
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = [x.strip() for x in line.split(";")]
        if f[0] == prop:
            out.append(f[1:])
    return out


# ---- generation --------------------------------------------------------------


def emit_table(name, ranges):
    flat = [v for lo, hi in ranges for v in (lo, hi)]
    lines = []
    for i in range(0, len(flat), 10):
        lines.append("    " + ", ".join("0x%X" % v for v in flat[i : i + 10]) + ",")
    body = "\n".join(lines)
    return "const %s = [_]u21{\n%s\n};\n" % (name, body) if flat else "const %s = [_]u21{};\n" % name


def build_map(entries, what):
    """entries: [(alias, table_id)] -> {loose key: table_id}, rejecting clashes."""
    m = {}
    for alias, tid in entries:
        k = loose(alias)
        if k in m and m[k] != tid:
            sys.exit("%s: alias %r clashes (%s vs %s)" % (what, alias, m[k], tid))
        m[k] = tid
    return m


def generate(ucd, out_path):
    read = lambda n: open(os.path.join(ucd, n), encoding="utf-8").read()
    sums = {n: hashlib.sha256(open(os.path.join(ucd, n), "rb").read()).hexdigest() for n in FILES}
    version = re.search(r"Scripts-(\d+\.\d+\.\d+)\.txt", read("Scripts.txt")).group(1)

    # General_Category
    gc = parse_unicode_data(read("UnicodeData.txt"))
    gc_aliases = parse_aliases(read("PropertyValueAliases.txt"), "gc")
    shorts = {a[0] for a in gc_aliases}
    for cat in gc:
        assert cat in shorts, "unknown gc " + cat
    assigned = union(*gc.values())
    gc["Cn"] = complement(assigned)
    gc.setdefault("Cs", [])
    gc["LC"] = union(*(gc[c] for c in GC_LC))
    for letter in "LMNPSZC":
        gc[letter] = union(*(gc[c] for c in list(gc) if len(c) == 2 and c[0] == letter and c != "LC"))
    for s in shorts:
        assert s in gc, "gc value without table: " + s

    # Script
    sc = parse_ranges(read("Scripts.txt"), None)
    sc_aliases = parse_aliases(read("PropertyValueAliases.txt"), "sc")
    long_to_short = {a[1]: a[0] for a in sc_aliases}
    sc_tables = {}
    for long_name, ranges in sc.items():
        sc_tables[long_to_short[long_name]] = ranges
    sc_tables["Zzzz"] = complement(union(*sc_tables.values()))
    # A few script values (Hrkt) are defined but have no code points in
    # Scripts.txt; they are not exposed.
    sc_aliases = [a for a in sc_aliases if a[0] in sc_tables]

    # Binary properties
    derived = parse_ranges(read("DerivedCoreProperties.txt"), {"Alphabetic", "Lowercase", "Uppercase"})
    props = parse_ranges(read("PropList.txt"), {"White_Space", "Join_Control"})
    bp = {**derived, **props}
    for name in BINARY:
        assert name in bp, "missing property " + name
    bp["Any"] = normalize([(0, MAX)])
    bp["ASCII"] = [(0, 0x7F)]
    bp["Assigned"] = complement(gc["Cn"])

    # Derived classes behind \w \d \s (UTS #18, Annex C)
    word = union(bp["Alphabetic"], gc["Mn"], gc["Mc"], gc["Me"], gc["Nd"], gc["Pc"], bp["Join_Control"])

    out = []
    w = out.append
    w("//! GENERATED by tools/gen_unicode.py. Do not edit.\n")
    w("//!\n")
    w("//! Unicode Character Database %s, https://www.unicode.org/Public/%s/ucd/\n" % (version, version))
    w("//! Input SHA-256:\n")
    for n in FILES:
        w("//!   %s  %s\n" % (sums[n], n))
    w("//!\n")
    w("//! Each table is a flat list of inclusive (lo, hi) pairs of Unicode scalar\n")
    w("//! values, sorted and non-overlapping. Surrogates are excluded.\n\n")
    w("const std = @import(\"std\");\n\n")
    w("pub const version = \"%s\";\n\n" % version)
    w("pub const Table = []const u21;\n\n")

    entries_gc, entries_sc, entries_bp = [], [], []
    for a in gc_aliases:
        tid = "gc_" + a[0]
        entries_gc += [(x, tid) for x in a]
    for a in sc_aliases:
        tid = "sc_" + a[0]
        entries_sc += [(x, tid) for x in a]
    for name, aliases in list(BINARY.items()) + [("Any", []), ("ASCII", []), ("Assigned", [])]:
        entries_bp += [(x, "bp_" + name) for x in [name] + aliases]

    w("pub const word: Table = &word_table;\n")
    w("pub const digit: Table = &gc_Nd;\n")
    w("pub const space: Table = &bp_White_Space;\n\n")
    w(emit_table("word_table", word))
    for cat in sorted(gc):
        w(emit_table("gc_" + cat, gc[cat]))
    for s in sorted(sc_tables):
        w(emit_table("sc_" + s, sc_tables[s]))
    for b in sorted(bp):
        w(emit_table("bp_" + b, bp[b]))
    w("\n")

    def emit_map(var, entries, what):
        m = build_map(entries, what)
        w("/// Keys are loosely matched names: lower case, without space, '_' or '-'.\n")
        w("pub const %s = std.StaticStringMap(Table).initComptime(.{\n" % var)
        for k in sorted(m):
            w('    .{ "%s", &%s },\n' % (k, m[k]))
        w("});\n\n")

    emit_map("general_category", entries_gc, "gc")
    emit_map("script", entries_sc, "sc")
    emit_map("binary", entries_bp, "binary")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("".join(out))
    print("wrote %s (Unicode %s)" % (out_path, version))


def fetch(version, dest):
    os.makedirs(dest, exist_ok=True)
    for n in FILES:
        url = "https://www.unicode.org/Public/%s/ucd/%s" % (version, n)
        print("fetching", url)
        with urllib.request.urlopen(url, timeout=60) as r, open(os.path.join(dest, n), "wb") as f:
            f.write(r.read())


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "fetch":
        fetch(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == "generate":
        generate(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)

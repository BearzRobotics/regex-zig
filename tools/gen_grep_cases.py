#!/usr/bin/env python3
"""Generates src/testdata/grep_cases.txt: random BRE and ERE patterns with the
lines GNU grep selects and the first match it reports on each, so the test
suite can check regex-zig against GNU grep.

Usage: tools/gen_grep_cases.py [output]      (default src/testdata/grep_cases.txt)

The file records the grep version it was produced with. Patterns that GNU grep
rejects are skipped. grep runs with LC_ALL=C (byte semantics). The random seed
is fixed, so the output is reproducible for a given grep.

File format, one record per line, fields separated by a tab:
    P  <E|B|Ei|Bi>  <pattern>         i: grep -i
    L  <0|1>  <span>  <line>          1 if grep selected the line; span is
                                      "start,end" of the first non-empty
                                      match `grep -ob` prints, or "-"
"""

import os
import random
import subprocess
import sys
import tempfile

SEED = 20260101
# Patterns per mode.
MODES = (("E", 700), ("B", 700), ("Ei", 200), ("Bi", 200))
LINES_PER_PATTERN = 8


def gen(rng, ere, depth, groups):
    """One alternation. `groups` is a one-element list counting capture groups."""

    def lp():
        return "(" if ere else "\\("

    def rp():
        return ")" if ere else "\\)"

    def bar():
        return "|" if ere else "\\|"

    def quant():
        if ere:
            return rng.choice(["*", "+", "?", "{1,2}", "{2}", "{0,2}", "{,2}", "{1,}"])
        return rng.choice(["*", "\\+", "\\?", "\\{1,2\\}", "\\{2\\}", "\\{0,2\\}", "\\{,2\\}", "\\{1,\\}"])

    def atom():
        r = rng.randrange(14)
        if r < 5:
            return rng.choice("abc"), False
        if r == 5:
            return ".", False
        if r == 6:
            return rng.choice([
                "[ab]", "[^a]", "[a-c]", "[[:alpha:]]", "[[:upper:] ]",
                # '[', ']', '&' and '-' as ordinary members.
                "[[]", "[a[]", "[][a]", "[^]a]", "[^[]", "[a&&b]", "[+-[]", "[b-]", "[\\a]",
            ]), False
        if r in (7, 8) and depth > 0:
            groups[0] += 1
            return lp() + alt(depth - 1) + rp(), True
        if r == 9:
            return rng.choice(["\\b", "\\<", "\\>", "\\B"]), True
        if r == 10 and groups[0] > 0:
            return "\\" + str(rng.randint(1, min(groups[0], 9))), False
        if r == 11:
            return rng.choice(["\\w", "\\W", "\\s", "\\S"]), False
        return rng.choice("abc"), False

    def piece(first, last):
        a, special = atom()
        out = a
        # Quantify ordinary atoms, groups and classes; never assertions.
        if not special or a.startswith(lp()):
            if rng.randrange(3) == 0:
                out += quant()
        return out

    def concat():
        items = [piece(i == 0, False) for i in range(rng.randint(1, 3))]
        s = "".join(items)
        if rng.randrange(8) == 0:
            s = "^" + s
        if rng.randrange(8) == 0:
            s = s + "$"
        return s

    def alt(d):
        s = concat()
        if rng.randrange(4) == 0:
            s += bar() + concat()
        return s

    return alt(depth)


def make_lines(rng):
    alphabet = "abcabc  ABC[]&-\\"
    lines = []
    for _ in range(LINES_PER_PATTERN):
        n = rng.randint(0, 9)
        lines.append("".join(rng.choice(alphabet) for _ in range(n)))
    return lines


def grep_select(flags, pattern, lines):
    """[(selected, span)] for each line, or None if grep rejects the pattern."""
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write("\n".join(lines) + "\n")
        path = f.name
    try:
        env = dict(os.environ, LC_ALL="C")

        def run(*extra):
            args = ["grep", *flags, *extra, "-e", pattern, path]
            return subprocess.run(args, capture_output=True, text=True, env=env)

        r = run("-n")
        if r.returncode == 2:
            return None
        # "line:file offset:text" for every non-empty match.
        o = run("-n", "-o", "-b")
    finally:
        os.unlink(path)
    hit = {int(l.split(":", 1)[0]) for l in r.stdout.splitlines()}
    # The input is ASCII, so character and byte offsets agree.
    starts = [0]
    for line in lines:
        starts.append(starts[-1] + len(line) + 1)
    spans = {}
    for out in o.stdout.splitlines():
        number, offset, text = out.split(":", 2)
        i = int(number) - 1
        if i not in spans:
            begin = int(offset) - starts[i]
            spans[i] = "%d,%d" % (begin, begin + len(text))
    return [(1 if (i + 1) in hit else 0, spans.get(i, "-")) for i in range(len(lines))]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "src/testdata/grep_cases.txt"
    version = subprocess.run(["grep", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    rng = random.Random(SEED)
    records = []
    for mode, count in MODES:
        flags = ["-E" if mode[0] == "E" else "-G"] + (["-i"] if mode.endswith("i") else [])
        made = 0
        while made < count:
            groups = [0]
            pat = gen(rng, mode[0] == "E", 2, groups)
            lines = make_lines(rng)
            result = grep_select(flags, pat, lines)
            if result is None:
                continue
            records.append("P\t%s\t%s" % (mode, pat))
            records.extend("L\t%d\t%s\t%s" % (sel, span, l) for (sel, span), l in zip(result, lines))
            made += 1
    with open(out, "w") as f:
        f.write("# Generated by tools/gen_grep_cases.py with: %s\n" % version)
        f.write("\n".join(records) + "\n")
    print("wrote %s: %d patterns (%s)" % (out, sum(n for _, n in MODES), version))


if __name__ == "__main__":
    main()

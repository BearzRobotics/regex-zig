# regex-zig

A pure-Zig regular-expression library. Syntaxes: Perl, Oniguruma, POSIX ERE and BRE (with the GNU extensions), and the Rust `regex` syntax. Engines: a lazy DFA and a Pike VM (linear time) for ordinary patterns, a bounded backtracker for back-references and look-around, and for patterns too large for the linear-time program (`Regex.isLinearTime()` tells which you got). The linear-time bound is per search; iterating over every match can be quadratic (see `Matches` in `src/ops.zig`). Optional UTF-8 / Unicode matching, pattern sets, and line-oriented search over memory or a `std.Io.Reader`. Requires Zig 0.17. See `SPEC.md` for the goals and `CHANGELOG.md` for what each release contains.

```zig
const regex = @import("regex");

var re = try regex.Regex.compile(gpa, "(\\w+)@(\\w+)\\.com", .{ .utf8 = true }, null);
defer re.deinit(gpa);
var s = try re.searcher(gpa); // one Searcher per thread; the Regex must outlive it
defer s.deinit();

if (try s.find(text, 0)) |m| {
    const user = text[m.group(1).?[0]..m.group(1).?[1]];
    _ = user;
}
const out = try s.replaceAll(gpa, text, "$2:$1"); // caller frees
defer gpa.free(out);
```

Grep-style use:

```zig
var set = try regex.RegexSet.compile(gpa, &.{ "foo", "ba+r" }, .{ .dialect = .posix_ere }, null);
defer set.deinit(gpa);
var ss = try set.searcher(gpa);
defer ss.deinit();
var lines = ss.matchingLines(text, false); // or regex.LineStream over a reader
while (try lines.next()) |line| _ = line.text;
```

## Build and test

```
zig build test                          # unit, differential and behaviour tests
zig build test -Dunicode_tables=false   # without the Unicode tables
zig build bench                         # benchmarks (ReleaseFast)
```

Add it to another project with `zig fetch --save` and `b.dependency("regex", .{})`; pass `.unicode_tables = false` to leave the Unicode tables out.

## Untrusted patterns and input

`Options.limits` bounds pattern length, nesting, repeat counts, program size, compiler work, capture memory, the DFA cache, and the backtracker's steps and stack; exceeding one is an error. Two things are left to the caller:

- If backtracking is not acceptable, refuse patterns for which `Regex.isLinearTime()` is false.
- The linear-time bound is per search. Walking every match (`count`, `findAll`, `split`, `replaceAll`) can take quadratic time, so bound the input.

## Documentation

- `docs/architecture.md` — how the pieces fit together.
- `docs/decisions/` — design decisions (UTF-8 matching, matching engines, the resolved open decisions).
- `docs/compatibility/` — supported constructs and deviations per syntax.
- `tools/gen_unicode.py` — regenerates `src/unicode_tables.zig` from the Unicode Character Database.
- `tools/gen_grep_cases.py` — regenerates `src/testdata/grep_cases.txt` from GNU grep.

## Future work

Not in 0.5.0; recorded as known limitations in `CHANGELOG.md`.

- A required-substring prefilter, and SIMD prefilters beyond the byte and prefix scans.
- Perl's priority in lazy loops that can match empty, on the linear-time engines.
- Aho-Corasick (or Teddy) for large literal sets in `RegexSet`.
- Streaming beyond line-oriented input (matches across reader chunks).
- Full Unicode case folding (ß to ss) and `\p{Script_Extensions}`.
- POSIX subexpression rule for group positions in leftmost-longest mode.
- Faster capture-group and leftmost-longest paths (currently the Pike VM).
- Differential tests in the suite against ripgrep (or the Rust `regex` crate) and Perl.

## License

Copyright (c) 2026 Dakota James Owen Keeler.

regex-zig is free software under the GNU Library General Public License, version 2
or (at your option) any later version (`LGPL-2.0-or-later`). It comes with no
warranty. See `LICENSE`.

`src/unicode_tables.zig` is generated from the Unicode Character Database and
keeps the Unicode License.

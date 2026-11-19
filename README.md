# regex-zig

A pure-Zig regular-expression library: Perl, Oniguruma and POSIX ERE syntaxes, a linear-time Pike VM for ordinary patterns, a bounded backtracker for back-references and look-around, and optional UTF-8 / Unicode matching. Requires Zig 0.17. See `SPEC.md` for the goals and `CHANGELOG.md` for what each release contains.

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

## Build and test

```
zig build test                          # unit, differential and behaviour tests
zig build test -Dunicode_tables=false   # without the Unicode tables
zig build bench                         # benchmarks (ReleaseFast)
```

Add it to another project with `zig fetch --save` and `b.dependency("regex", .{})`; pass `.unicode_tables = false` to leave the Unicode tables out.

## Documentation

- `docs/decisions/` — design decisions (UTF-8 matching, matching engines).
- `docs/compatibility/` — supported constructs and deviations per syntax.
- `tools/gen_unicode.py` — regenerates `src/unicode_tables.zig` from the Unicode Character Database.

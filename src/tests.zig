//! Behaviour tests for the parser and the backtracking engine. Expected
//! results follow Perl/PCRE and Oniguruma semantics as documented in
//! docs/compatibility/perl.md.

const std = @import("std");
const regex = @import("root.zig");
const unicode = @import("unicode.zig");

const gpa = std.testing.allocator;

fn repeated(unit: []const u8, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, unit.len * n);
    for (0..n) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
    return out;
}

/// Returns "start..end" of the first match, or null.
fn span(pattern: []const u8, hay: []const u8, opts: regex.Options) !?[2]usize {
    var re = try regex.Regex.compile(gpa, pattern, opts, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const m = (try s.find(hay, 0)) orelse null;
    const got: ?[2]usize = if (m) |mm| .{ mm.start(), mm.end() } else null;

    // Every behaviour test doubles as a differential test: when the default
    // engine is not the backtracker, the backtracker must give the same span.
    if (opts.engine == .auto and re.prog.engine != .backtrack) {
        var bo = opts;
        bo.engine = .backtrack;
        var bre = try regex.Regex.compile(gpa, pattern, bo, null);
        defer bre.deinit(gpa);
        var bs = try bre.searcher(gpa);
        defer bs.deinit();
        const bm = try bs.find(hay, 0);
        const bgot: ?[2]usize = if (bm) |mm| .{ mm.start(), mm.end() } else null;
        try std.testing.expectEqual(bgot, got);
    }
    return got;
}

fn expectSpan(pattern: []const u8, hay: []const u8, want: ?[2]usize) !void {
    try expectSpanOpts(pattern, hay, want, .{});
}

fn expectSpanOpts(pattern: []const u8, hay: []const u8, want: ?[2]usize, opts: regex.Options) !void {
    const got = try span(pattern, hay, opts);
    if (want == null) {
        try std.testing.expect(got == null);
    } else {
        try std.testing.expect(got != null);
        try std.testing.expectEqual(want.?[0], got.?[0]);
        try std.testing.expectEqual(want.?[1], got.?[1]);
    }
}

fn expectGroup(pattern: []const u8, hay: []const u8, group: u32, want: ?[]const u8) !void {
    var re = try regex.Regex.compile(gpa, pattern, .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const m = (try s.find(hay, 0)).?;
    if (m.group(group)) |g| {
        try std.testing.expectEqualStrings(want.?, hay[g[0]..g[1]]);
    } else try std.testing.expect(want == null);
}

fn expectCompileError(pattern: []const u8, opts: regex.Options, want: regex.Error) !void {
    var diag: regex.Diagnostic = .{};
    try std.testing.expectError(want, regex.Regex.compile(gpa, pattern, opts, &diag));
    try std.testing.expect(diag.message.len > 0);
}

test "literals, dot, alternation" {
    try expectSpan("abc", "xxabcxx", .{ 2, 5 });
    try expectSpan("a.c", "a\nc abc", .{ 4, 7 });
    try expectSpan("cat|dog", "hotdog", .{ 3, 6 });
    try expectSpan("", "abc", .{ 0, 0 });
    try expectSpan("abc", "ab", null);
}

test "alternation is leftmost-first, not longest" {
    try expectSpan("a|ab", "ab", .{ 0, 1 });
    try expectSpan("ab|a", "ab", .{ 0, 2 });
}

test "quantifiers: greedy, lazy, possessive, counted" {
    try expectSpan("a*", "aaa", .{ 0, 3 });
    try expectSpan("a+?", "aaa", .{ 0, 1 });
    try expectSpan("a{2}", "aaaa", .{ 0, 2 });
    try expectSpan("a{2,3}", "aaaa", .{ 0, 3 });
    try expectSpan("a{2,}", "aaaa", .{ 0, 4 });
    try expectSpan("a{2,3}?", "aaaa", .{ 0, 2 });
    try expectSpan("a?b", "b", .{ 0, 1 });
    try expectSpan("a*+a", "aaa", null);
    try expectSpan("a++b", "aaab", .{ 0, 4 });
    try expectSpan("x{,2}", "x{,2}", .{ 0, 5 }); // Perl: literal braces
}

test "literal braces" {
    try expectSpan("a{", "a{", .{ 0, 2 });
    try expectSpan("a{x}", "a{x}", .{ 0, 4 });
}

test "classes" {
    try expectSpan("[a-c]+", "xxabcabd", .{ 2, 7 });
    try expectSpan("[^a-c]+", "abxyz", .{ 2, 5 });
    try expectSpan("[]a]+", "x]a]", .{ 1, 4 });
    try expectSpan("[a-]+", "a-a", .{ 0, 3 });
    try expectSpan("[\\d_]+", "ab12_3c", .{ 2, 6 });
    try expectSpan("[[:alpha:]]+", "12abC3", .{ 2, 5 });
    try expectSpan("[[:^alpha:]]+", "ab12c", .{ 2, 4 });
    try expectSpan("[a[bc]]+", "xbcax", .{ 1, 4 }); // Oniguruma nested class
    try expectSpan("\\w+", "  foo_1 ", .{ 2, 7 });
    try expectSpan("\\S+", "  ab ", .{ 2, 4 });
}

test "anchors and boundaries (perl dialect)" {
    try expectSpan("^b", "a\nb", null);
    try expectSpan("(?m)^b", "a\nb", .{ 2, 3 });
    try expectSpan("a$", "a\n", .{ 0, 1 }); // $ before final newline
    try expectSpan("a\\z", "a\n", null);
    try expectSpan("\\bfoo\\b", "a foo b", .{ 2, 5 });
    try expectSpan("\\Boo", "foo", .{ 1, 3 });
    try expectSpan("\\Aa", "ba", null);
}

test "anchors (oniguruma dialect: ^ and $ are line anchors)" {
    try expectSpanOpts("^b", "a\nb", .{ 2, 3 }, .{ .dialect = .oniguruma });
    try expectSpanOpts("a$", "a\nb", .{ 0, 1 }, .{ .dialect = .oniguruma });
    // (?m) means dot-matches-newline there.
    try expectSpanOpts("(?m)a.b", "a\nb", .{ 0, 3 }, .{ .dialect = .oniguruma });
    try expectSpanOpts("\\h+", "xyz09af", .{ 3, 7 }, .{ .dialect = .oniguruma });
}

test "groups and captures" {
    try expectGroup("(a)(b)?", "ac", 1, "a");
    try expectGroup("(a)(b)?", "ac", 2, null);
    try expectGroup("(?:ab)+(c)", "ababc", 1, "c");
    try expectGroup("(?<word>\\w+)@", "me@x", 1, "me");
    try expectGroup("(a|ab)(c|bcd)", "abcd", 2, "bcd");
    try expectGroup("(\\d+)-(\\d+)", "tel 12-345", 2, "345");
}

test "backreferences" {
    try expectSpan("(a+)b\\1", "aabaa", .{ 0, 5 });
    try expectSpan("(a+)b\\1", "aaba", .{ 1, 4 });
    try expectSpan("(?<q>['\"]).*?\\k<q>", "x 'hi' y", .{ 2, 6 });
    try expectSpanOpts("(a)\\1", "aA", .{ 0, 2 }, .{ .ignore_case = true });
    try expectSpan("(a)?\\1", "b", null); // unset group fails the reference
}

test "look-ahead" {
    try expectSpan("foo(?=bar)", "foobaz foobar", .{ 7, 10 });
    try expectSpan("foo(?!bar)", "foobar foobaz", .{ 7, 10 });
    try expectSpan("(?=a)a", "ba", .{ 1, 2 });
}

test "look-behind" {
    try expectSpan("(?<=\\$)\\d+", "cost 10 $20", .{ 9, 11 });
    try expectSpan("(?<!\\$)\\b\\d+", "$20 30", .{ 4, 6 });
    try expectSpan("(?<=ab|c)x", "abx", .{ 2, 3 });
    try expectSpan("(?<=ab|c)x", "cx", .{ 1, 2 });
    try expectSpan("(?<=a)b", "b", null);
    try expectCompileError("(?<=a+)b", .{}, error.Unsupported);
}

test "atomic groups" {
    try expectSpan("(?>a+)b", "aaab", .{ 0, 4 });
    try expectSpan("(?>a+)a", "aaa", null);
    try expectSpan("(?>a|ab)c", "abc", null); // atomic: no retry with "ab"
}

test "captures set inside an atomic group are undone on later failure" {
    // First alternative captures then fails after the group; group 1 must be
    // unset for the second alternative.
    try expectGroup("(?:(?>(a))x|a)", "a", 1, null);
}

test "inline flags are scoped to their group" {
    try expectSpan("(?i)abc", "xABC", .{ 1, 4 });
    try expectSpan("a(?i:b)c", "aBc", .{ 0, 3 });
    try expectSpan("a(?i:b)c", "aBC", null);
    try expectSpan("(a(?i)b)c", "aBc", .{ 0, 3 });
    try expectSpan("(a(?i)b)C", "aBc", null);
    try expectSpan("(?i)a(?-i)b", "Ab", .{ 0, 2 });
    try expectSpan("(?i)a(?-i)b", "AB", null);
    try expectSpanOpts("abc", "ABC", .{ 0, 3 }, .{ .ignore_case = true });
    try expectSpanOpts("[a-c]+", "ABC", .{ 0, 3 }, .{ .ignore_case = true });
}

test "extended mode and comments" {
    try expectSpan("(?x) a b # comment\n c", "abc", .{ 0, 3 });
    try expectSpan("a(?#note)b", "ab", .{ 0, 2 });
    try expectSpan("(?x) a\\ b", "a b", .{ 0, 3 });
}

test "escapes" {
    try expectSpan("\\x41\\x{42}", "AB", .{ 0, 2 });
    try expectSpan("\\t\\n", "\t\n", .{ 0, 2 });
    try expectSpan("\\.\\*\\(", ".*(", .{ 0, 3 });
    try expectSpan("\\Qa.b\\E+", "a.bbb", .{ 0, 5 });
    try expectSpan("\\0", "a\x00", .{ 1, 2 });
}

test "empty-body loops terminate" {
    try expectSpan("(a*)*b", "aaab", .{ 0, 4 });
    try expectSpan("(a*)+$", "aaa", .{ 0, 3 });
    try expectSpan("(?:)*x", "x", .{ 0, 1 });
    try expectSpan("(a|)*c", "aac", .{ 0, 3 });
}

test "high bytes are literal and never crash" {
    try expectSpan("\xc3\xa9", "caf\xc3\xa9", .{ 3, 5 });
    try expectSpan(".", "\xff", .{ 0, 1 });
    try expectSpan("a", "\xff\xfe", null);
}

test "pathological patterns hit the backtracker step limit instead of hanging" {
    var re = try regex.Regex.compile(gpa, "(a*)*b", .{ .engine = .backtrack, .limits = .{ .max_steps = 100_000 } }, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    // Nested quantifiers are exponential in a backtracker; the budget stops it.
    try std.testing.expectError(error.StepLimitExceeded, s.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));

    var re2 = try regex.Regex.compile(gpa, "(a+)+b", .{ .engine = .backtrack, .limits = .{ .max_steps = 100_000 } }, null);
    defer re2.deinit(gpa);
    var s2 = try re2.searcher(gpa);
    defer s2.deinit();
    try std.testing.expectError(error.StepLimitExceeded, s2.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));
}

test "stack limit is enforced" {
    var re = try regex.Regex.compile(gpa, ".*x", .{ .engine = .backtrack, .limits = .{ .max_stack = 64 } }, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const hay = try repeated("a", 1000);
    defer gpa.free(hay);
    try std.testing.expectError(error.StackLimitExceeded, s.find(hay, 0));
}

test "\\G anchors at the search start" {
    var re = try regex.Regex.compile(gpa, "\\Gab", .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const m = (try s.find("xab ab", 4)).?;
    try std.testing.expectEqual(@as(usize, 4), m.start());
    try std.testing.expect((try s.find("xab ab", 1)) != null);
    try std.testing.expect((try s.find("xxab", 1)) == null);
}

test "invalid and unsupported patterns report errors" {
    try expectCompileError("(", .{}, error.InvalidPattern);
    try expectCompileError("a)", .{}, error.InvalidPattern);
    try expectCompileError("[a", .{}, error.InvalidPattern);
    try expectCompileError("[z-a]", .{}, error.InvalidPattern);
    try expectCompileError("*a", .{}, error.InvalidPattern);
    try expectCompileError("a**", .{}, error.InvalidPattern);
    try expectCompileError("a{3,2}", .{}, error.InvalidPattern);
    try expectCompileError("\\", .{}, error.InvalidPattern);
    try expectCompileError("(a)\\2", .{}, error.InvalidPattern);
    try expectCompileError("\\k<nope>", .{}, error.InvalidPattern);
    try expectCompileError("\\q", .{}, error.InvalidPattern);
    try expectCompileError("\\p{L}", .{}, error.Unsupported);
    try expectCompileError("(?~abc)", .{}, error.Unsupported);
    try expectCompileError("[a&&b]", .{}, error.Unsupported);
    try expectCompileError("\\x{100}", .{}, error.Unsupported);
}

test "limits: nesting, repeat count, program size, pattern length" {
    const open = try repeated("(", 500);
    defer gpa.free(open);
    const deep = try std.mem.concat(gpa, u8, &.{ open, open });
    defer gpa.free(deep);
    @memset(deep[500..], ')');
    try expectCompileError(deep, .{}, error.LimitExceeded);
    try expectCompileError("a{5000}", .{}, error.LimitExceeded);
    try expectCompileError("(?:a{1000}){1000}", .{}, error.LimitExceeded);
    try expectCompileError("abc", .{ .limits = .{ .max_pattern_len = 2 } }, error.LimitExceeded);
}

test "allocation failures do not leak" {
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        const a = fa.allocator();
        var re = regex.Regex.compile(a, "(?<n>a|b)+(?=c)\\k<n>[x-z]", .{}, null) catch continue;
        re.deinit(a);
    }
}

test "first-byte prefilter never skips a valid match" {
    try expectSpan("a*b", "xxb", .{ 2, 3 });
    try expectSpan("(a|)b", "zb", .{ 1, 2 });
    try expectSpan("\\bfoo", "a foo", .{ 2, 5 });
    try expectSpan("(?=a)a", "ba", .{ 1, 2 });
    try expectSpan("(?<=x)y", "xy", .{ 1, 2 });
    try expectSpan("[^x]", "xxy", .{ 2, 3 });
    try expectSpan(".", "\n\nq", .{ 2, 3 });
    try expectSpanOpts("(?s).", "\nq", .{ 0, 1 }, .{});
    try expectSpan("(a)?\\1b", "b", null);
    try expectSpan("(a?)\\1b", "b", .{ 0, 1 }); // backreference to an empty group
    try expectSpanOpts("K", "k", .{ 0, 1 }, .{ .ignore_case = true });
    try expectSpan("x?", "", .{ 0, 0 });
    try expectSpan("^$", "", .{ 0, 0 });
    try expectSpan("a|b|", "zz", .{ 0, 0 });
}

test "posix_ere dialect" {
    const ere: regex.Options = .{ .dialect = .posix_ere };
    // Basics shared with the other dialects.
    try expectSpanOpts("a(b|c)+d", "xabcbd", .{ 1, 6 }, ere);
    try expectSpanOpts("^[[:alpha:]]+$", "Hello", .{ 0, 5 }, ere);
    try expectSpanOpts("a{2,3}", "caaaa", .{ 1, 4 }, ere);
    // `.` matches a newline; anchors are text anchors.
    try expectSpanOpts("a.b", "a\nb", .{ 0, 3 }, ere);
    try expectSpanOpts("^b", "a\nb", null, ere);
    // `*?` is `(*)?`: greedy, not lazy.
    try expectSpanOpts("a*?", "aaa", .{ 0, 3 }, ere);
    try expectSpanOpts("a+?b", "aab", .{ 0, 3 }, ere);
    // `(?` has no meaning in ERE.
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "(?:a)", ere, null));
    // GNU escapes; others are the character itself.
    try expectSpanOpts("\\w+", "  ab_1 ", .{ 2, 6 }, ere);
    try expectSpanOpts("\\bfoo\\b", "a foo b", .{ 2, 5 }, ere);
    try expectSpanOpts("a\\.b", "a.b", .{ 0, 3 }, ere);
    try expectSpanOpts("\\d", "d", .{ 0, 1 }, ere);
    try expectSpanOpts("\\d", "5", null, ere);
    try expectSpanOpts("(a)\\1", "xaa", .{ 1, 3 }, ere);
    // A backslash in a bracket expression is a literal.
    try expectSpanOpts("[\\d]+", "5\\d", .{ 1, 3 }, ere);
    // Case folding applies as in the other dialects.
    try expectSpanOpts("COPY", "a copy", .{ 2, 6 }, .{ .dialect = .posix_ere, .ignore_case = true });
}

fn withSearcher(pattern: []const u8, opts: regex.Options, comptime body: fn (*regex.Searcher) anyerror!void) !void {
    var re = try regex.Regex.compile(gpa, pattern, opts, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    try body(&s);
}

test "isMatch and count" {
    try withSearcher("a+", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            try std.testing.expect(try s.isMatch("xxaxx"));
            try std.testing.expect(!(try s.isMatch("xxx")));
            try std.testing.expectEqual(@as(usize, 3), try s.count("a-aa-aaa"));
        }
    }.f);
}

test "iteration over empty matches terminates and covers every position" {
    try withSearcher("x*", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            // "abc": empty matches at 0,1,2,3.
            try std.testing.expectEqual(@as(usize, 4), try s.count("abc"));
            // "axxb": empty@0, "xx"@1..3, empty@3, empty@4.
            const spans = try s.findAll(gpa, "axxb");
            defer gpa.free(spans);
            try std.testing.expectEqual(@as(usize, 4), spans.len);
            try std.testing.expectEqual(@as(usize, 1), spans[1].start);
            try std.testing.expectEqual(@as(usize, 3), spans[1].end);
            try std.testing.expectEqual(@as(usize, 0), try s.count("") - 1);
        }
    }.f);
}

test "split" {
    try withSearcher(",", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            const parts = try s.split(gpa, "a,b,,c,");
            defer gpa.free(parts);
            try std.testing.expectEqual(@as(usize, 5), parts.len);
            try std.testing.expectEqualStrings("a", parts[0]);
            try std.testing.expectEqualStrings("", parts[2]);
            try std.testing.expectEqualStrings("", parts[4]);
        }
    }.f);
}

test "replaceAll expands numbered and named groups" {
    try withSearcher("(?<k>\\w+)=(\\w+)", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            const out = try s.replaceAll(gpa, "a=1, bb=2", "${2}:$1 ($$) ${k}");
            defer gpa.free(out);
            try std.testing.expectEqualStrings("1:a ($) a, 2:bb ($) bb", out);
        }
    }.f);
}

test "replaceAll rejects bad templates even without matches" {
    try withSearcher("(a)", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            for ([_][]const u8{ "$", "$x", "$2", "${nope}", "${1", "${}" }) |bad|
                try std.testing.expectError(error.InvalidReplacement, s.replaceAll(gpa, "zzz", bad));
        }
    }.f);
}

test "non-participating group expands to nothing" {
    try withSearcher("(a)|(b)", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            const out = try s.replaceAll(gpa, "ab", "[$1|$2]");
            defer gpa.free(out);
            try std.testing.expectEqualStrings("[a|][|b]", out);
        }
    }.f);
}

// ---- utf8 mode --------------------------------------------------------------

const u8opts: regex.Options = .{ .utf8 = true };

fn expectU8(pattern: []const u8, hay: []const u8, want: ?[2]usize) !void {
    try expectSpanOpts(pattern, hay, want, u8opts);
}

test "utf8: dot and classes consume whole characters" {
    try expectU8("^.$", "é", .{ 0, 2 });
    try expectU8("^.$", "☺", .{ 0, 3 });
    try expectU8("^.$", "😀", .{ 0, 4 });
    try expectU8("^..$", "é", null);
    try expectU8("^[^a]$", "é", .{ 0, 2 });
    try expectU8("^[^a]+$", "bé☺", .{ 0, 6 });
    try expectU8("é+", "aééé", .{ 1, 7 });
    try expectU8("[é]", "caf\u{e9}", .{ 3, 5 });
    try expectU8("[à-ü]+", "xéüy", .{ 1, 5 });
    try expectU8("[^à-ü]", "éa", .{ 2, 3 });
    if (unicode.enabled) {
        try expectU8("^\\W$", "☺", .{ 0, 3 });
        try expectU8("^\\W$", "é", null); // \w is Unicode-aware in utf8 mode
    } else {
        try expectU8("^\\W$", "é", .{ 0, 2 }); // ASCII-only without the tables
    }
    try expectU8("^\\D$", "☺", .{ 0, 3 });
    // The same patterns keep their byte meaning without utf8.
    try expectSpan("^.$", "é", null);
}

test "utf8: dot does not match newline unless dot-all" {
    try expectU8(".", "\n", null);
    try expectU8("(?s).", "\n", .{ 0, 1 });
    try expectU8("^.$", "\u{10FFFF}", .{ 0, 4 });
}

test "utf8: \\x escapes are scalar values" {
    try expectU8("\\x{263A}", "a☺", .{ 1, 4 });
    try expectU8("\\xE9", "é", .{ 0, 2 });
    try expectU8("[\\x{3040}-\\x{309F}]+", "xひらがなy", .{ 1, 13 });
    try expectU8("\\x{10FFFF}", "\u{10FFFF}", .{ 0, 4 });
    var diag: regex.Diagnostic = .{};
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "\\x{D800}", u8opts, &diag));
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "\\x{110000}", u8opts, &diag));
    // Byte mode still refuses what it cannot represent.
    try expectCompileError("\\x{263A}", .{}, error.Unsupported);
}

test "utf8: the pattern must be valid UTF-8" {
    var diag: regex.Diagnostic = .{};
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "a\xffb", u8opts, &diag));
    try std.testing.expectEqual(@as(usize, 1), diag.pos);
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "a\xc3", u8opts, &diag));
    try std.testing.expectError(error.InvalidPattern, regex.Regex.compile(gpa, "\xed\xa0\x80", u8opts, &diag));
}

test "utf8: invalid haystack bytes never match and never crash" {
    const bad = [_][]const u8{
        "\xff",     "\x80",   "\xc3",         "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80",
        "\xe2\x82", "a\x80b", "\xf0\x9f\x98",
    };
    for (bad) |h| {
        try expectU8("^.$", h, null);
        try expectU8("^[^a]$", h, null);
        try expectU8("^\\W$", h, null);
        // Searching and iterating terminate and stay in bounds.
        var re = try regex.Regex.compile(gpa, ".*", u8opts, null);
        defer re.deinit(gpa);
        var s = try re.searcher(gpa);
        defer s.deinit();
        _ = try s.count(h);
    }
    // Valid text around invalid bytes still matches.
    try expectU8("a.b", "a\x80b", null);
    try expectU8("é", "\xffé\xff", .{ 1, 3 });
}

test "utf8: empty matches never fall inside a character" {
    try withSearcher("x*", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            try std.testing.expectEqual(@as(usize, 2), try s.count("é")); // 0 and 2
            try std.testing.expectEqual(@as(usize, 3), try s.count("é☺")); // 0, 2, 5
            const spans = try s.findAll(gpa, "é☺");
            defer gpa.free(spans);
            try std.testing.expectEqual(@as(usize, 2), spans[1].start);
        }
    }.f);
}

test "utf8: look-behind needs a fixed byte width" {
    try expectU8("(?<=é)x", "éx", .{ 2, 3 });
    try expectCompileError("(?<=.)x", u8opts, error.Unsupported);
    try expectSpan("(?<=.)x", "ax", .{ 1, 2 }); // fine in byte mode
}

test "utf8: quantifier after \\Q..\\E and escaped characters binds to the character" {
    try expectU8("\\Qé\\E+", "éé", .{ 0, 4 });
    try expectU8("\\é", "é", .{ 0, 2 });
    try expectU8("\\é+", "éé", .{ 0, 4 });
}

test "utf8: captures and replacement work on multibyte text" {
    try withSearcher("(.)(.)", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            const out = try s.replaceAll(gpa, "éa☺b", "$2$1");
            defer gpa.free(out);
            try std.testing.expectEqualStrings("aé" ++ "b☺", out);
        }
    }.f);
}

test "utf8: program size for . and [^a]" {
    // ADR 0001 gate: lowering must stay small (measured sizes are in the ADR).
    inline for (.{ ".", "(?s).", "[^a]", "\\W", "[à-ü]" }) |pat| {
        var re = try regex.Regex.compile(gpa, pat, u8opts, null);
        defer re.deinit(gpa);
        try std.testing.expect(re.prog.insts.len < 80);
    }
}

// ---- utf8 mode: Unicode properties and classes (phase 2) ---------------------

test "utf8: \\w \\d \\s are Unicode-aware" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8("^\\w+$", "café_9", .{ 0, 7 });
    try expectU8("^\\w+$", "漢字", .{ 0, 6 });
    try expectU8("^\\w$", "\u{300}", .{ 0, 2 }); // combining mark
    try expectU8("^\\d+$", "٣٤٥", .{ 0, 6 }); // Arabic-Indic digits
    try expectU8("^\\D$", "٣", null);
    try expectU8("^\\s+$", " \u{a0}\u{3000}", .{ 0, 6 });
    try expectU8("^\\S$", "\u{a0}", null);
    try expectU8("^\\W$", "-", .{ 0, 1 });
    // Byte mode keeps ASCII semantics.
    try expectSpan("^\\w$", "é", null);
}

test "utf8: \\p and \\P" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8("^\\p{L}+$", "héllo", .{ 0, 6 });
    try expectU8("^\\pL+$", "héllo", .{ 0, 6 });
    try expectU8("\\p{Lu}", "aÉb", .{ 1, 3 });
    try expectU8("\\p{Ll}", "AÉb", .{ 3, 4 });
    try expectU8("^\\p{Greek}+$", "αβγ", .{ 0, 6 });
    try expectU8("\\p{Script=Han}+", "a漢字b", .{ 1, 7 });
    try expectU8("\\p{sc=Hira}+", "xひらy", .{ 1, 7 });
    try expectU8("\\p{gc=Nd}", "a٣", .{ 1, 3 });
    try expectU8("\\p{Alphabetic}+", "1ab2", .{ 1, 3 });
    try expectU8("^\\P{L}+$", "12 -", .{ 0, 4 });
    try expectU8("\\P{L}", "é", null);
    try expectU8("\\p{^L}", "é", null);
    try expectU8("\\P{^L}", "é", .{ 0, 2 });
    try expectU8("^\\p{Any}$", "😀", .{ 0, 4 });
    try expectU8("\\p{letter}", "x", .{ 0, 1 }); // loose names
    // Inside classes, alone and combined.
    try expectU8("^[\\p{L}\\d_]+$", "été_٣", .{ 0, 8 });
    try expectU8("^[^\\p{L}]+$", "12!", .{ 0, 3 });
    try expectU8("[^\\p{L}]", "é", null);
    try expectU8("^[\\P{L}]$", "é", null);
    try expectU8("^[\\p{Lu}\\p{Nd}]+$", "É٣A", .{ 0, 5 });
}

test "utf8: \\p errors" {
    if (!unicode.enabled) {
        try expectCompileError("\\p{L}", u8opts, error.Unsupported);
        return;
    }
    try expectCompileError("\\p{NoSuchThing}", u8opts, error.InvalidPattern);
    try expectCompileError("\\p{L", u8opts, error.InvalidPattern);
    try expectCompileError("\\p", u8opts, error.InvalidPattern);
    try expectCompileError("\\p{gc=Greek}", u8opts, error.InvalidPattern);
    try expectCompileError("\\p{L}", .{}, error.Unsupported); // needs utf8
    try expectCompileError("[\\p{L}]", .{}, error.Unsupported);
}

test "utf8: POSIX classes use Unicode where it is clear" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8("^[[:alpha:]]+$", "héllo", .{ 0, 6 });
    try expectU8("^[[:upper:]]$", "É", .{ 0, 2 });
    try expectU8("^[[:lower:]]$", "é", .{ 0, 2 });
    try expectU8("^[[:alnum:]]+$", "é٣a", .{ 0, 5 });
    try expectU8("^[[:digit:]]$", "٣", .{ 0, 2 });
    try expectU8("^[[:space:]]$", "\u{3000}", .{ 0, 3 });
    try expectU8("^[[:blank:]]+$", " \t\u{a0}", .{ 0, 4 });
    try expectU8("^[[:^alpha:]]$", "é", null);
    try expectU8("^[[:punct:]]$", "!", .{ 0, 1 });
    try expectU8("^[[:punct:]]$", "¿", null); // punct stays ASCII
    try expectSpan("^[[:alpha:]]$", "é", null); // byte mode unchanged
}

test "utf8: \\b is Unicode-aware" {
    if (!unicode.enabled) return error.SkipZigTest;
    try withSearcher("\\bcafé\\b", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            try std.testing.expect(try s.isMatch("un café noir"));
            try std.testing.expect(!(try s.isMatch("cafés")));
            try std.testing.expect(!(try s.isMatch("xcafé")));
        }
    }.f);
    try withSearcher("\\b", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            // "é a": boundaries at 0, 2, 3, 4. Not between the bytes of é.
            try std.testing.expectEqual(@as(usize, 4), try s.count("é a"));
            // Invalid bytes are not word characters.
            try std.testing.expectEqual(@as(usize, 2), try s.count("a\xff"));
        }
    }.f);
    try withSearcher("\\B", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            try std.testing.expect(!(try s.isMatch("é")));
        }
    }.f);
    // Byte mode: the two bytes of é are not word bytes, so 'é' alone has no boundary.
    try withSearcher("\\b", .{}, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            try std.testing.expectEqual(@as(usize, 0), try s.count("é"));
        }
    }.f);
}

test "utf8: large classes stay small and run in one step per character" {
    if (!unicode.enabled) return error.SkipZigTest;
    var re = try regex.Regex.compile(gpa, "\\p{L}+", u8opts, null);
    defer re.deinit(gpa);
    // The set is far too big to lower to byte sequences; it uses cp_class.
    try std.testing.expect(re.prog.insts.len < 20);
    try std.testing.expect(re.prog.cp_sets.len == 1);
    var s = try re.searcher(gpa);
    defer s.deinit();
    // 100k characters: with one alternative per sequence this would exceed
    // the step budget; with cp_class it is linear.
    const text = try repeated("é漢a", 100_000);
    defer gpa.free(text);
    const m = (try s.find(text, 0)).?;
    try std.testing.expectEqual(@as(usize, text.len), m.end());
}

test "utf8: invalid bytes never match a property class" {
    if (!unicode.enabled) return error.SkipZigTest;
    const bad = [_][]const u8{ "\xff", "\x80", "\xc3", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82" };
    for (bad) |h| {
        try expectU8("^\\p{L}$", h, null);
        try expectU8("^\\P{L}$", h, null);
        try expectU8("^\\w$", h, null);
        try expectU8("^\\W$", h, null);
        try expectU8("^[^\\p{L}]$", h, null);
    }
}

test "utf8: Unicode classes on captures and replacement" {
    if (!unicode.enabled) return error.SkipZigTest;
    try withSearcher("(\\p{Lu})(\\p{Ll}+)", u8opts, struct {
        fn f(s: *regex.Searcher) anyerror!void {
            const out = try s.replaceAll(gpa, "Émile et Zoé", "$2$1");
            defer gpa.free(out);
            try std.testing.expectEqualStrings("mileÉ et oéZ", out);
        }
    }.f);
}

// ---- utf8 mode: case-insensitive matching (phase 3) ---------------------------

const u8i: regex.Options = .{ .utf8 = true, .ignore_case = true };

fn expectU8i(pattern: []const u8, hay: []const u8, want: ?[2]usize) !void {
    try expectSpanOpts(pattern, hay, want, u8i);
}

test "utf8: case-insensitive literals use Unicode simple case folding" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8i("é", "É", .{ 0, 2 });
    try expectU8i("É", "é", .{ 0, 2 });
    try expectU8i("straße", "STRASSE", null); // full folding (ß -> ss) is not supported
    try expectU8i("ß", "\u{1E9E}", .{ 0, 3 }); // capital sharp s
    try expectU8i("σ", "Σς", .{ 0, 2 });
    try expectU8i("ς", "Σ", .{ 0, 2 });
    try expectU8i("привет", "ПРИВЕТ", .{ 0, 12 });
    try expectU8i("k", "\u{212A}", .{ 0, 3 }); // KELVIN SIGN
    try expectU8i("\u{212A}", "k", .{ 0, 1 });
    try expectU8i("s", "\u{17F}", .{ 0, 2 }); // LONG S
    try expectU8i("abc", "xABCx", .{ 1, 4 });
    try expectU8i("é+", "éÉé", .{ 0, 6 });
    try expectU8i("\\x{E9}", "É", .{ 0, 2 });
    // Inline flags and byte mode.
    try expectU8("(?i)é", "É", .{ 0, 2 });
    try expectU8("(?i:é)É", "ÉÉ", .{ 0, 4 });
    try expectU8("é(?i)", "É", null);
    try expectSpanOpts("é", "É", null, .{ .ignore_case = true }); // byte mode folds ASCII only
}

test "utf8: case-insensitive classes fold before negation" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8i("^[à-ü]+$", "ÉÈ", .{ 0, 4 });
    try expectU8i("^[a-c]+$", "ABC", .{ 0, 3 });
    try expectU8i("[k]", "\u{212A}", .{ 0, 3 });
    try expectU8i("[^é]", "É", null);
    try expectU8i("[^é]", "e", .{ 0, 1 });
    try expectU8i("^[^k]$", "\u{212A}", null);
    try expectU8i("^\\p{Lu}+$", "abcé", .{ 0, 5 }); // (?i) widens \p{Lu}
    try expectU8i("^\\p{Ll}+$", "ABCÉ", .{ 0, 5 });
    try expectU8i("^[[:upper:]]+$", "abc", .{ 0, 3 });
    // Without (?i) nothing changes.
    try expectU8("^[à-ü]+$", "ÉÈ", null);
    try expectU8("^\\p{Lu}+$", "abc", null);
}

test "utf8: case-insensitive back-references compare characters" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8i("(é)\\1", "éÉ", .{ 0, 4 });
    try expectU8i("(k)\\1", "k\u{212A}", .{ 0, 4 }); // 1 byte then 3 bytes
    try expectU8i("(\\x{212A})\\1", "\u{212A}k", .{ 0, 4 }); // 3 bytes then 1 byte
    try expectU8i("(é)\\1", "éa", null);
    try expectU8i("(.+)\\1", "ÀBcàbC", .{ 0, 8 });
    try expectSpanOpts("(a)\\1", "aA", .{ 0, 2 }, .{ .ignore_case = true });
}

test "utf8: case folding and look-behind" {
    if (!unicode.enabled) return error.SkipZigTest;
    try expectU8i("(?<=a)x", "Ax", .{ 1, 2 }); // ASCII-only variants: fixed width
    try expectU8i("(?<=é)x", "Éx", .{ 2, 3 }); // both variants are 2 bytes
    try expectU8("(?<=[à-ü])x", "éx", .{ 2, 3 });
    // 'k' and 's' have variants of different lengths, so the width is not fixed.
    try expectCompileError("(?<=s)x", u8i, error.Unsupported);
}

test "utf8: without the tables case folding is ASCII-only" {
    if (unicode.enabled) return error.SkipZigTest;
    try expectU8i("abc", "ABC", .{ 0, 3 });
    try expectU8i("é", "É", null);
    try expectU8i("k", "\u{212A}", null);
}

// ---- pathological patterns -----------------------------------------------------

// SPEC section 2 goal 2: patterns without back-references or look-around run
// in linear time. With the default engine these finish quickly with the
// right answer; the backtracker, forced, still stops at its step limit.
const pathological = [_]struct { pattern: []const u8, unit: u8, n: usize, tail: []const u8 }{
    .{ .pattern = "(a*)*b", .unit = 'a', .n = 30, .tail = "" },
    .{ .pattern = "(a+)+$", .unit = 'a', .n = 30, .tail = "!" },
    .{ .pattern = "(a|aa)+$", .unit = 'a', .n = 40, .tail = "!" },
    .{ .pattern = "(x+x+)+y", .unit = 'x', .n = 40, .tail = "" },
    .{ .pattern = "(a?){30}a{30}", .unit = 'a', .n = 29, .tail = "" },
    .{ .pattern = "(a*)*b", .unit = 'a', .n = 100_000, .tail = "" },
};

test "pathological patterns run in linear time with the default engine" {
    for (pathological) |c| {
        const body = try gpa.alloc(u8, c.n);
        defer gpa.free(body);
        @memset(body, c.unit);
        const hay = try std.mem.concat(gpa, u8, &.{ body, c.tail });
        defer gpa.free(hay);
        var re = try regex.Regex.compile(gpa, c.pattern, .{}, null);
        defer re.deinit(gpa);
        var s = try re.searcher(gpa);
        defer s.deinit();
        // None of these match; the point is that the answer comes back.
        try std.testing.expect((try s.find(hay, 0)) == null);
    }
    // And one that does match: (a+)+$ on a run of a's.
    var re = try regex.Regex.compile(gpa, "(a+)+$", .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const hay = try repeated("a", 50_000);
    defer gpa.free(hay);
    const m = (try s.find(hay, 0)).?;
    try std.testing.expectEqual(@as(usize, 50_000), m.end());
}

test "pathological patterns: the backtracker still stops at its step limit" {
    for (pathological[0..4]) |c| {
        const body = try gpa.alloc(u8, c.n);
        defer gpa.free(body);
        @memset(body, c.unit);
        const hay = try std.mem.concat(gpa, u8, &.{ body, c.tail });
        defer gpa.free(hay);
        var re = try regex.Regex.compile(gpa, c.pattern, .{ .engine = .backtrack }, null);
        defer re.deinit(gpa);
        var s = try re.searcher(gpa);
        defer s.deinit();
        try std.testing.expectError(error.StepLimitExceeded, s.find(hay, 0));
    }
}

test "a long scan is not limited by the step budget with the default engine" {
    const hay = try repeated("the quick brown fox ", 100_000);
    defer gpa.free(hay);
    var re = try regex.Regex.compile(gpa, "[a-z]+@", .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    try std.testing.expect((try s.find(hay, 0)) == null);
    // The backtracker's budget is per find call, so the same scan exceeds it.
    var bt = try regex.Regex.compile(gpa, "[a-z]+@", .{ .engine = .backtrack }, null);
    defer bt.deinit(gpa);
    var bs = try bt.searcher(gpa);
    defer bs.deinit();
    try std.testing.expectError(error.StepLimitExceeded, bs.find(hay, 0));
}

// ---- engines: leftmost-longest, forced engines, differential --------------------

test "posix_ere is leftmost-longest" {
    const ere: regex.Options = .{ .dialect = .posix_ere };
    // Leftmost-first would pick "a"; POSIX picks the longest alternative.
    try expectSpanOpts("a|ab", "abc", .{ 0, 2 }, ere);
    try expectSpanOpts("(a|ab)(c|bcd)", "abcd", .{ 0, 4 }, ere);
    try expectSpanOpts("a*", "aaa", .{ 0, 3 }, ere);
    try expectSpanOpts("x*|y", "yyy", .{ 0, 1 }, ere); // at start 0 the longest of "" and "y" is "y"
    try expectSpanOpts("a|ab", "abc", .{ 0, 1 }, .{}); // perl dialects stay leftmost-first
    // With a back-reference the backtracker is used and is leftmost-longest too.
    try expectSpanOpts("(a|ab)\\1", "abab", .{ 0, 4 }, ere);
    try expectSpanOpts("(a|ab)(b?)\\2", "abb", .{ 0, 3 }, ere);
}

test "the engine is chosen from the pattern, and can be forced" {
    var plain = try regex.Regex.compile(gpa, "a(b|c)*d", .{}, null);
    defer plain.deinit(gpa);
    try std.testing.expect(plain.prog.engine == .dfa);
    var no_dfa = try regex.Regex.compile(gpa, "a(b|c)*d", .{ .engine = .pike }, null);
    defer no_dfa.deinit(gpa);
    try std.testing.expect(no_dfa.prog.engine == .pike);

    for ([_][]const u8{ "(a)\\1", "a(?=b)", "(?<=a)b", "(?>a+)b", "a++b" }) |needs_bt| {
        var re = try regex.Regex.compile(gpa, needs_bt, .{}, null);
        defer re.deinit(gpa);
        try std.testing.expect(re.prog.engine == .backtrack);
        try expectCompileError(needs_bt, .{ .engine = .pike }, error.Unsupported);
    }
    var forced = try regex.Regex.compile(gpa, "a(b|c)*d", .{ .engine = .backtrack }, null);
    defer forced.deinit(gpa);
    try std.testing.expect(forced.prog.engine == .backtrack);
}

test "a pattern too large for the Pike VM falls back to the backtracker" {
    if (!unicode.enabled) return error.SkipZigTest;
    // \p{L}{40} is about 40 copies of a class of several thousand instructions.
    const opts: regex.Options = .{ .utf8 = true, .limits = .{ .max_program_len = 20_000 } };
    var re = try regex.Regex.compile(gpa, "\\p{L}{40}", opts, null);
    defer re.deinit(gpa);
    try std.testing.expect(re.prog.engine == .backtrack);
    try expectCompileError("\\p{L}{40}", .{ .utf8 = true, .engine = .pike, .limits = .{ .max_program_len = 20_000 } }, error.LimitExceeded);
}

const Oom = error{OutOfMemory};

const Gen = struct {
    r: std.Random,
    out: std.ArrayList(u8) = .empty,
    /// POSIX syntax (no `(?:`, no lazy quantifiers).
    ere: bool,
    /// Basic-expression spelling: `\\(`, `\\|`, `\\+`, `\\{m,n\\}`.
    bre: bool = false,
    /// A quantifier was applied to something containing a group: capture
    /// positions may legitimately differ between the engines then.
    quantified_group: bool = false,

    fn put(g: *Gen, s: []const u8) Oom!void {
        try g.out.appendSlice(gpa, s);
    }

    fn alt(g: *Gen, depth: u32) Oom!void {
        try g.concat(depth);
        if (g.r.uintLessThan(u8, 4) == 0) {
            try g.put(if (g.bre) "\\|" else "|");
            try g.concat(depth);
        }
    }

    fn concat(g: *Gen, depth: u32) Oom!void {
        const n = g.r.intRangeAtMost(u8, 1, 3);
        for (0..n) |_| try g.piece(depth);
    }

    fn piece(g: *Gen, depth: u32) Oom!void {
        const has_group = try g.atom(depth);
        if (g.r.uintLessThan(u8, 3) != 0) return;
        const quants = [_][]const u8{ "*", "+", "?", "{1,2}", "{2}", "{0,2}" };
        const bre_quants = [_][]const u8{ "*", "\\+", "\\?", "\\{1,2\\}", "\\{2\\}", "\\{0,2\\}" };
        try g.put(if (g.bre) bre_quants[g.r.uintLessThan(usize, bre_quants.len)] else quants[g.r.uintLessThan(usize, quants.len)]);
        if (!g.ere and g.r.uintLessThan(u8, 3) == 0) try g.put("?");
        if (has_group) g.quantified_group = true;
    }

    /// Returns true if the atom contains a capture group.
    fn atom(g: *Gen, depth: u32) Oom!bool {
        switch (g.r.uintLessThan(u8, 12)) {
            0, 1, 2, 3 => try g.put(&.{"abc"[g.r.uintLessThan(usize, 3)]}),
            4 => try g.put("."),
            5 => try g.put(if (g.r.boolean()) "[ab]" else "[^a]"),
            6, 7 => if (depth > 0) {
                try g.put(if (g.bre) "\\(" else "(");
                try g.alt(depth - 1);
                try g.put(if (g.bre) "\\)" else ")");
                return true;
            } else try g.put("a"),
            8 => if (depth > 0 and !g.ere) {
                try g.put("(?:");
                try g.alt(depth - 1);
                try g.put(")");
            } else try g.put("b"),
            9 => try g.put(if (g.r.boolean()) "^" else "$"),
            10 => try g.put("\\b"),
            else => try g.put("c"),
        }
        return false;
    }
};

fn expectSameResult(pattern: []const u8, opts: regex.Options, compare_groups: bool, hay: []const u8) !void {
    try expectSameEngines(pattern, opts, .pike, .backtrack, compare_groups, hay);
}

/// Every match of an iteration over `hay` is the same under both engines
/// (so empty matches and searches from a position other than 0 are covered).
fn expectSameEngines(pattern: []const u8, opts: regex.Options, a: regex.Engine, b: regex.Engine, compare_groups: bool, hay: []const u8) !void {
    var ao = opts;
    ao.engine = a;
    var bo = opts;
    bo.engine = b;
    var are = try regex.Regex.compile(gpa, pattern, ao, null);
    defer are.deinit(gpa);
    var bre = try regex.Regex.compile(gpa, pattern, bo, null);
    defer bre.deinit(gpa);
    var as = try are.searcher(gpa);
    defer as.deinit();
    var bs = try bre.searcher(gpa);
    defer bs.deinit();

    // isMatch must agree with find.
    const exists = try as.isMatch(hay);
    const bexists = try bs.isMatch(hay);
    if (exists != bexists) {
        std.debug.print("ISMATCH MISMATCH pattern={s} hay={any} {s}={} {s}={}\n", .{ pattern, hay, @tagName(a), exists, @tagName(b), bexists });
        return error.TestUnexpectedResult;
    }

    var ait = as.matches(hay);
    var bit = bs.matches(hay);
    while (true) {
        const am = try ait.next();
        const bm = try bit.next();
        if (am == null or bm == null) {
            if ((am == null) != (bm == null)) {
                std.debug.print("MISMATCH pattern={s} hay={any} ({s} null={}, {s} null={})\n", .{ pattern, hay, @tagName(a), am == null, @tagName(b), bm == null });
                return error.TestUnexpectedResult;
            }
            break;
        }
        if (am.?.start() != bm.?.start() or am.?.end() != bm.?.end()) {
            std.debug.print("MISMATCH pattern={s} hay={any} {s}={d}..{d} {s}={d}..{d}\n", .{ pattern, hay, @tagName(a), am.?.start(), am.?.end(), @tagName(b), bm.?.start(), bm.?.end() });
            return error.TestUnexpectedResult;
        }
        if (compare_groups) {
            var g: u32 = 1;
            while (g <= are.groupCount()) : (g += 1) {
                if (!std.meta.eql(am.?.group(g), bm.?.group(g))) {
                    std.debug.print("GROUP MISMATCH pattern={s} hay={any} group={d}\n", .{ pattern, hay, g });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "differential: the Pike VM agrees with the backtracker on random patterns" {
    var prng = std.Random.DefaultPrng.init(0xd1ff);
    const r = prng.random();
    const alphabet = "abc\n";
    var compared: usize = 0;
    for ([_]regex.Dialect{ .perl, .posix_ere, .posix_bre }) |dialect| {
        for (0..1500) |_| {
            var g: Gen = .{ .r = r, .ere = dialect == .posix_ere or dialect == .posix_bre, .bre = dialect == .posix_bre };
            defer g.out.deinit(gpa);
            try g.alt(2);
            const opts: regex.Options = .{ .dialect = dialect };
            // Skip anything the parser rejects (for example nested quantifiers in perl).
            var probe = regex.Regex.compile(gpa, g.out.items, .{ .dialect = dialect, .engine = .pike }, null) catch continue;
            probe.deinit(gpa);
            for (0..6) |_| {
                var hay: [12]u8 = undefined;
                const len = r.uintLessThan(usize, hay.len + 1);
                for (hay[0..len]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
                try expectSameResult(g.out.items, opts, !g.quantified_group, hay[0..len]);
                compared += 1;
            }
        }
    }
    try std.testing.expect(compared > 5000);
}

test "differential: utf8 patterns agree between the engines" {
    if (!unicode.enabled) return error.SkipZigTest;
    const patterns = [_][]const u8{ ".", ".+", "[^a]+", "é+", "(?i)é+", "\\w+", "\\p{L}+", "\\p{Lu}\\p{Ll}*", "[à-ü]+", "\\b\\w+\\b", "☺|é", "(?i)straße|k+", "[^\\p{L}]+", "\\d+" };
    const hays = [_][]const u8{ "", "abc é☺ Éa", "日本語 text", "\xff\x80é\xc3", "KkK\u{212A} ſs", "٣٤ 12", "😀x😀" };
    for (patterns) |pat| {
        for (hays) |h| try expectSameResult(pat, .{ .utf8 = true }, true, h);
    }
}

test "differential: the lazy DFA agrees with the Pike VM on random patterns" {
    var prng = std.Random.DefaultPrng.init(0xdfa);
    const r = prng.random();
    const alphabet = "abc\n";
    var compared: usize = 0;
    for ([_]regex.Dialect{ .perl, .posix_ere, .oniguruma, .posix_bre }) |dialect| {
        for (0..1500) |_| {
            var g: Gen = .{ .r = r, .ere = dialect == .posix_ere or dialect == .posix_bre, .bre = dialect == .posix_bre };
            defer g.out.deinit(gpa);
            try g.alt(2);
            // Skip what the parser rejects or what the DFA cannot take.
            var probe = regex.Regex.compile(gpa, g.out.items, .{ .dialect = dialect, .engine = .dfa }, null) catch continue;
            probe.deinit(gpa);
            for (0..8) |_| {
                var hay: [14]u8 = undefined;
                const len = r.uintLessThan(usize, hay.len + 1);
                for (hay[0..len]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
                try expectSameEngines(g.out.items, .{ .dialect = dialect }, .dfa, .pike, true, hay[0..len]);
                compared += 1;
            }
        }
    }
    try std.testing.expect(compared > 8000);
}

test "differential: utf8 patterns agree between the DFA and the Pike VM" {
    const patterns = [_][]const u8{ ".", ".+", "[^a]+", "é+", "(?i)é+", "[à-ü]+", "☺|é", "(?i)straße|k+", "a.c", "^é", "é$", "(é|a)*b" };
    const hays = [_][]const u8{ "", "abc é☺ Éa", "日本語 text", "\xff\x80é\xc3", "KkK\u{212A} ſs", "😀x😀", "é\n", "a\nb" };
    for (patterns) |pat| {
        for (hays) |h| try expectSameEngines(pat, .{ .utf8 = true }, .dfa, .pike, true, h);
    }
    if (!unicode.enabled) return;
    const uni = [_][]const u8{ "\\p{L}+", "\\p{Lu}\\p{Ll}*", "[^\\p{L}]+", "\\d+", "\\w+@\\w+" };
    for (uni) |pat| {
        for (hays) |h| try expectSameEngines(pat, .{ .utf8 = true }, .dfa, .pike, true, h);
    }
    // A Unicode \b cannot be evaluated by the DFA, so it is not eligible.
    try expectCompileError("\\b\\w+", .{ .utf8 = true, .engine = .dfa }, error.Unsupported);
}

test "the DFA falls back when its cache is too small" {
    // Many distinct states with a tiny cache: the answer must still be right.
    const hay = try repeated("abcabcabd", 2000);
    defer gpa.free(hay);
    const opts: regex.Options = .{ .engine = .dfa, .limits = .{ .max_dfa_cache = 2000 } };
    var re = try regex.Regex.compile(gpa, "(a|b|c)*abd(a|b|c|d){5}x", opts, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    try std.testing.expect((try s.find(hay, 0)) == null);
    try std.testing.expect(!(try s.isMatch(hay)));
    const hay2 = try std.mem.concat(gpa, u8, &.{ hay, "abdabcdax" });
    defer gpa.free(hay2);
    try std.testing.expect(try s.isMatch(hay2));
    const m = (try s.find(hay2, 0)).?;
    try std.testing.expectEqual(hay2.len, m.end());
}

test "the DFA treats a final newline like the other engines" {
    for ([_][]const u8{ "a$", "a\\Z", "^a$", "(a)$" }) |pat| {
        for ([_][]const u8{ "a", "a\n", "ba\n", "a\nb", "\n", "" }) |h| {
            try expectSameEngines(pat, .{}, .dfa, .pike, true, h);
            try expectSameEngines(pat, .{}, .dfa, .backtrack, true, h);
        }
    }
}

test "word boundaries in the DFA (ASCII)" {
    for ([_][]const u8{ "\\bfoo\\b", "\\Bo+\\B", "\\b", "\\B", "(\\w+)\\b" }) |pat| {
        for ([_][]const u8{ "foo", "a foo b", "xfoox", "foo_bar foo", "", " ", "fooo" }) |h| {
            try expectSameEngines(pat, .{}, .dfa, .pike, true, h);
        }
    }
}

// ---- POSIX BRE and the GNU word anchors ------------------------------------------

const bre_opts: regex.Options = .{ .dialect = .posix_bre };

test "bre: groups, alternation and intervals use backslashes" {
    try expectSpanOpts("a\\(b\\|c\\)*d", "xabcbd", .{ 1, 6 }, bre_opts);
    try expectSpanOpts("a\\{2,3\\}", "aaaa", .{ 0, 3 }, bre_opts);
    try expectSpanOpts("a\\{2\\}", "aaaa", .{ 0, 2 }, bre_opts);
    try expectSpanOpts("a\\{2,\\}", "aaaa", .{ 0, 4 }, bre_opts);
    try expectSpanOpts("ab\\+", "abbb", .{ 0, 4 }, bre_opts);
    try expectSpanOpts("ab\\?c", "ac abc", .{ 0, 2 }, bre_opts);
    try expectSpanOpts("a\\|ab", "abc", .{ 0, 2 }, bre_opts); // leftmost-longest
    try expectSpanOpts("x*", "xxx", .{ 0, 3 }, bre_opts);
    try expectSpanOpts("a**", "aaa", .{ 0, 3 }, bre_opts); // a quantifier may follow a quantifier
}

test "bre: ERE operators are ordinary characters" {
    try expectSpanOpts("(a)", "x(a)", .{ 1, 4 }, bre_opts);
    try expectSpanOpts("a|b", "xa|b", .{ 1, 4 }, bre_opts);
    try expectSpanOpts("a+", "aa+", .{ 1, 3 }, bre_opts);
    try expectSpanOpts("a?", "a?", .{ 0, 2 }, bre_opts);
    try expectSpanOpts("a{2}", "a{2}", .{ 0, 4 }, bre_opts);
    try expectSpanOpts("a{2}", "aa", null, bre_opts);
}

test "bre: star and anchors are special only where POSIX says" {
    try expectSpanOpts("*a", "*a", .{ 0, 2 }, bre_opts); // star at the start is literal
    try expectSpanOpts("\\(*a\\)", "x*a", .{ 1, 3 }, bre_opts); // and at the start of a group
    try expectSpanOpts("a\\|*b", "*b", .{ 0, 2 }, bre_opts); // and after an alternation bar
    try expectSpanOpts("^*a", "*a", .{ 0, 2 }, bre_opts); // star after ^ is literal
    try expectSpanOpts("a^b", "a^b", .{ 0, 3 }, bre_opts); // ^ in the middle is literal
    try expectSpanOpts("a$b", "a$b", .{ 0, 3 }, bre_opts); // and so is $
    try expectSpanOpts("^a", "ba", null, bre_opts);
    try expectSpanOpts("a$", "ab", null, bre_opts);
    try expectSpanOpts("a$", "ba", .{ 1, 2 }, bre_opts);
    try expectSpanOpts("\\(^a\\)", "ba", null, bre_opts); // ^ at the start of a group anchors
    try expectSpanOpts("\\(^a\\)", "ab", .{ 0, 1 }, bre_opts);
    try expectSpanOpts("x\\|^a", "ba", null, bre_opts);
    try expectSpanOpts("\\(a$\\)", "ba", .{ 1, 2 }, bre_opts); // $ at the end of a group anchors
}

test "bre: back-references and GNU escapes" {
    try expectSpanOpts("\\(a*\\)b\\1", "aabaa", .{ 0, 5 }, bre_opts);
    try expectSpanOpts("\\(.\\)\\1", "abccd", .{ 2, 4 }, bre_opts);
    try expectSpanOpts("\\w\\+", "  foo_1 ", .{ 2, 7 }, bre_opts);
    try expectSpanOpts("a\\sb", "a b", .{ 0, 3 }, bre_opts);
    try expectSpanOpts("\\bfoo\\b", "a foo b", .{ 2, 5 }, bre_opts);
    try expectSpanOpts("a\\.b", "axb a.b", .{ 4, 7 }, bre_opts);
    try expectSpanOpts("a\\*", "a*", .{ 0, 2 }, bre_opts);
    try expectSpanOpts("[a-c]*", "abcd", .{ 0, 3 }, bre_opts);
    try expectSpanOpts("[\\n]", "\\", .{ 0, 1 }, bre_opts); // a backslash in a bracket is literal
    try expectSpanOpts("a.c", "a\nc", .{ 0, 3 }, bre_opts); // `.` matches a newline
}

test "bre: syntax errors" {
    try expectCompileError("\\(a", bre_opts, error.InvalidPattern);
    try expectCompileError("a\\)", bre_opts, error.InvalidPattern);
    try expectCompileError("a\\{2", bre_opts, error.InvalidPattern);
    try expectCompileError("a\\{3,2\\}", bre_opts, error.InvalidPattern);
    try expectCompileError("\\{1\\}", bre_opts, error.InvalidPattern);
    try expectCompileError("a\\{\\}", bre_opts, error.InvalidPattern);
    try expectCompileError("a\\{2000\\}", bre_opts, error.LimitExceeded);
}

test "word and text anchors in the POSIX dialects" {
    const ere: regex.Options = .{ .dialect = .posix_ere };
    for ([_]regex.Options{ ere, bre_opts }) |o| {
        try expectSpanOpts("\\<foo\\>", "a foo b", .{ 2, 5 }, o);
        try expectSpanOpts("\\<foo\\>", "xfoo foox", null, o);
        try expectSpanOpts("\\<f", "of f", .{ 3, 4 }, o);
        try expectSpanOpts("o\\>", "of o", .{ 3, 4 }, o);
        try expectSpanOpts("\\`a", "ba", null, o);
        try expectSpanOpts("\\`a", "ab", .{ 0, 1 }, o);
        try expectSpanOpts("a\\'", "ab", null, o);
        try expectSpanOpts("a\\'", "ba", .{ 1, 2 }, o);
    }
    // POSIX `$` is the end of the text, not "before a final newline".
    try expectSpanOpts("a$", "a\n", null, ere);
    try expectSpanOpts("a$", "a\n", null, bre_opts);
    try expectSpanOpts("a$", "a\n", .{ 0, 1 }, .{}); // Perl's does match there
}

test "bre: leftmost-longest on every engine" {
    for ([_]regex.Engine{ .auto, .dfa, .pike, .backtrack }) |eng| {
        var o = bre_opts;
        o.engine = eng;
        try expectSpanOpts("a\\|ab\\|abc", "abcd", .{ 0, 3 }, o);
        try expectSpanOpts("\\(a\\|ab\\)\\(c\\|bcd\\)", "abcd", .{ 0, 4 }, o);
    }
}

// ---- the Rust dialect -------------------------------------------------------------

const rust: regex.Options = .{ .dialect = .rust };
const rust8: regex.Options = .{ .dialect = .rust, .utf8 = true };

test "rust: groups, flags and quantifiers" {
    try expectSpanOpts("a(b|c)*d", "xabcbd", .{ 1, 6 }, rust);
    try expectSpanOpts("(?P<x>a)(?<y>b)", "ab", .{ 0, 2 }, rust);
    try expectSpanOpts("a+?", "aaa", .{ 0, 1 }, rust);
    try expectSpanOpts("a{2,3}", "aaaa", .{ 0, 3 }, rust);
    try expectSpanOpts("(?i)abc", "xABC", .{ 1, 4 }, rust);
    try expectSpanOpts("(?i:a)b", "Ab", .{ 0, 2 }, rust);
    try expectSpanOpts("(?i:a)b", "AB", null, rust);
    try expectSpanOpts("(?s)a.b", "a\nb", .{ 0, 3 }, rust);
    try expectSpanOpts("a.b", "a\nb", null, rust);
    try expectSpanOpts("(?m)^b$", "a\nb\nc", .{ 2, 3 }, rust);
    try expectSpanOpts("(?x) a b # comment", "ab", .{ 0, 2 }, rust);
    try expectSpanOpts("a|", "b", .{ 0, 0 }, rust); // empty alternative
    try expectSpanOpts("a|b|", "c", .{ 0, 0 }, rust);
}

test "rust: swap-greed flag" {
    try expectSpanOpts("(?U)a+", "aaa", .{ 0, 1 }, rust);
    try expectSpanOpts("(?U)a+?", "aaa", .{ 0, 3 }, rust);
    try expectSpanOpts("(?U:a*)b", "aab", .{ 0, 3 }, rust);
    try expectSpanOpts("a+(?U)b+", "abbb", .{ 0, 2 }, rust);
}

test "rust: $ is the end of the text" {
    try expectSpanOpts("a$", "a\n", null, rust);
    try expectSpanOpts("a$", "a", .{ 0, 1 }, rust);
    try expectSpanOpts("\\Aa\\z", "a", .{ 0, 1 }, rust);
}

test "rust: unsupported constructs are errors" {
    try expectCompileError("(a)\\1", rust, error.Unsupported);
    try expectCompileError("(?<n>a)\\k<n>", rust, error.Unsupported);
    try expectCompileError("a(?=b)", rust, error.Unsupported);
    try expectCompileError("a(?!b)", rust, error.Unsupported);
    try expectCompileError("(?<=a)b", rust, error.Unsupported);
    try expectCompileError("(?<!a)b", rust, error.Unsupported);
    try expectCompileError("(?>a)", rust, error.Unsupported);
    try expectCompileError("(?#c)a", rust, error.Unsupported);
    try expectCompileError("a*+", rust, error.InvalidPattern); // no possessive; a nested quantifier
    try expectCompileError("a**", rust, error.InvalidPattern);
    try expectCompileError("a\\Z", rust, error.InvalidPattern);
    try expectCompileError("\\Ga", rust, error.InvalidPattern);
    try expectCompileError("\\Qa\\E", rust, error.InvalidPattern);
    try expectCompileError("\\ha", rust, error.InvalidPattern);
    try expectCompileError("(?-u)a", rust, error.Unsupported);
    // The same constructs are fine in the Perl dialect.
    try expectSpanOpts("(a)\\1", "aa", .{ 0, 2 }, .{});
}

test "rust: every pattern runs on a linear-time engine" {
    for ([_][]const u8{ "a(b|c)*d", "(?i)x+y", "[a-z&&[^aeiou]]+", "\\bfoo\\b", "(a*)*b" }) |pat| {
        var re = try regex.Regex.compile(gpa, pat, rust, null);
        defer re.deinit(gpa);
        try std.testing.expect(re.prog.engine != .backtrack);
    }
}

test "rust: class set operations" {
    try expectSpanOpts("[a-z&&[^aeiou]]+", "aebcdi", .{ 2, 5 }, rust);
    try expectSpanOpts("[a-z--aeiou]+", "aebcdi", .{ 2, 5 }, rust);
    try expectSpanOpts("[a-f~~d-k]+", "xdxbk", .{ 3, 5 }, rust); // symmetric difference is a-c and g-k; 'd' is in both
    try expectSpanOpts("[a-f~~d-k]+", "bgh", .{ 0, 3 }, rust);
    try expectSpanOpts("[\\w--\\d]+", "12ab3", .{ 2, 4 }, rust);
    try expectSpanOpts("[[a-z]&&[c-m]&&[^e]]+", "bcefz", .{ 1, 2 }, rust);
    try expectSpanOpts("[^a-z&&[^aeiou]]", "b", null, rust); // negation applies to the whole class
    try expectSpanOpts("[^a-z&&[^aeiou]]", "e", .{ 0, 1 }, rust);
    try expectSpanOpts("[a-c]", "-", null, rust);
    try expectSpanOpts("[a-]", "-", .{ 0, 1 }, rust);
    // Outside the Rust dialect `&&` is not accepted here.
    try expectCompileError("[a&&b]", .{}, error.Unsupported);
    // A range ending in '-' still works in the Perl dialect.
    try expectSpanOpts("[+--]+", "+,-", .{ 0, 3 }, .{});
}

test "rust: \\u escapes and Unicode" {
    try expectSpanOpts("\\x41", "A", .{ 0, 1 }, rust);
    try expectSpanOpts("\\u0041", "A", .{ 0, 1 }, rust);
    try expectSpanOpts("\\u{41}", "A", .{ 0, 1 }, rust);
    try expectSpanOpts("\\U00000041", "A", .{ 0, 1 }, rust);
    try expectSpanOpts("\\u00E9", "é", .{ 0, 2 }, rust8);
    try expectSpanOpts("\\u{1F600}", "😀", .{ 0, 4 }, rust8);
    try expectCompileError("\\u00", rust, error.InvalidPattern);
    try expectCompileError("\\u{D800}", rust8, error.InvalidPattern);
    if (!unicode.enabled) return;
    try expectSpanOpts("\\pL+", "123héllo456", .{ 3, 9 }, rust8);
    try expectSpanOpts("(?i)É", "é", .{ 0, 2 }, rust8);
    try expectSpanOpts("[\\p{Greek}&&\\p{Ll}]+", "ΑΒαβγΓ", .{ 4, 10 }, rust8);
}

// ---- sets, literal prefixes, lines ------------------------------------------------

test "regex set: any member matches, earlier patterns win ties" {
    var set = try regex.RegexSet.compile(gpa, &.{ "foo", "ba+r", "x[0-9]" }, .{}, null);
    defer set.deinit(gpa);
    var s = try set.searcher(gpa);
    defer s.deinit();
    try std.testing.expect(try s.isMatch("a baaar b"));
    try std.testing.expect(try s.isMatch("zzx7"));
    try std.testing.expect(!(try s.isMatch("fo ba x")));
    const m = (try s.find("--bar--foo", 0)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start());
    try std.testing.expectEqual(@as(usize, 5), m.end());

    const which = try set.matchedPatterns(gpa, "foo and x1");
    defer gpa.free(which);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, which);
    try std.testing.expectEqual(@as(usize, 3), set.len());
}

test "regex set: leftmost-first picks the earlier pattern, POSIX the longest" {
    var perl = try regex.RegexSet.compile(gpa, &.{ "ab", "abc" }, .{}, null);
    defer perl.deinit(gpa);
    var ps = try perl.searcher(gpa);
    defer ps.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try ps.find("abc", 0)).?.end());

    var ere = try regex.RegexSet.compile(gpa, &.{ "ab", "abc" }, .{ .dialect = .posix_ere }, null);
    defer ere.deinit(gpa);
    var es = try ere.searcher(gpa);
    defer es.deinit();
    try std.testing.expectEqual(@as(usize, 3), (try es.find("abc", 0)).?.end());
}

test "regex set: empty set, errors, groups and back-references" {
    var none = try regex.RegexSet.compile(gpa, &.{}, .{}, null);
    defer none.deinit(gpa);
    var ns = try none.searcher(gpa);
    defer ns.deinit();
    try std.testing.expect(!(try ns.isMatch("anything")));

    var diag: regex.Diagnostic = .{};
    try std.testing.expectError(error.InvalidPattern, regex.RegexSet.compile(gpa, &.{ "ok", "(bad" }, .{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), diag.pattern);
    try std.testing.expectError(error.Unsupported, regex.RegexSet.compile(gpa, &.{ "a", "(b)\\1" }, .{}, &diag));
    try std.testing.expectEqual(@as(usize, 1), diag.pattern);

    // Groups are accepted and simply not reported.
    var grouped = try regex.RegexSet.compile(gpa, &.{ "(a)(b)", "c(d)" }, .{}, null);
    defer grouped.deinit(gpa);
    var gs = try grouped.searcher(gpa);
    defer gs.deinit();
    try std.testing.expect(try gs.isMatch("xcd"));
    try std.testing.expectEqual(@as(u32, 0), grouped.all.groupCount());
}

test "regex set: many patterns agree with one alternation" {
    const pats = [_][]const u8{ "alpha", "be+ta", "gam{2}a", "d[a-c]lta", "^eps", "zeta$" };
    var set = try regex.RegexSet.compile(gpa, &pats, .{}, null);
    defer set.deinit(gpa);
    var one = try regex.Regex.compile(gpa, "alpha|be+ta|gam{2}a|d[a-c]lta|^eps|zeta$", .{}, null);
    defer one.deinit(gpa);
    var ss = try set.searcher(gpa);
    defer ss.deinit();
    var os = try one.searcher(gpa);
    defer os.deinit();
    for ([_][]const u8{ "alpha", "xbeeeta", "gammma", "gamma", "delta dbltaa", "epsilon", "an eps", "zeta", "zeta ", "" }) |h| {
        const a = try ss.find(h, 0);
        const b = try os.find(h, 0);
        try std.testing.expectEqual(b == null, a == null);
        if (a) |m| {
            try std.testing.expectEqual(b.?.start(), m.start());
            try std.testing.expectEqual(b.?.end(), m.end());
        }
    }
}

test "literal prefix: found by substring search, results unchanged" {
    var re = try regex.Regex.compile(gpa, "needle[0-9]+x", .{}, null);
    defer re.deinit(gpa);
    try std.testing.expectEqualStrings("needle", re.prog.literal_prefix);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const filler = try repeated("needl needle needle9 neeedle ", 1000);
    defer gpa.free(filler);
    const hay = try std.mem.concat(gpa, u8, &.{ filler, "needle123x!" });
    defer gpa.free(hay);
    const m = (try s.find(hay, 0)).?;
    try std.testing.expectEqual(filler.len, m.start());
    try std.testing.expectEqual(hay.len - 1, m.end());
    try std.testing.expect((try s.find(filler, 0)) == null);
    // Group, case-insensitive and non-literal starts have no usable prefix.
    var g = try regex.Regex.compile(gpa, "(ab)cd", .{}, null);
    defer g.deinit(gpa);
    try std.testing.expectEqualStrings("abcd", g.prog.literal_prefix);
    var ci = try regex.Regex.compile(gpa, "(?i)abc", .{}, null);
    defer ci.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ci.prog.literal_prefix.len);
    var alt = try regex.Regex.compile(gpa, "ab|cd", .{}, null);
    defer alt.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), alt.prog.literal_prefix.len);
}

test "literal prefix with a prefix at the end of the haystack and overlapping starts" {
    for ([_][]const u8{ "aab", "aaab", "abab" }) |pat| {
        for ([_][]const u8{ "aaaab", "aa", "ababab", "xaab", "a", "", "aaabaab" }) |h| {
            try expectSameEngines(pat, .{}, .dfa, .pike, true, h);
            try expectSameEngines(pat, .{}, .dfa, .backtrack, true, h);
        }
    }
}

// ---- GNU grep reference cases ---------------------------------------------------------

// src/testdata/grep_cases.txt is produced by tools/gen_grep_cases.py: random
// BRE and ERE patterns, and which lines GNU grep selects (LC_ALL=C).
const grep_cases = @embedFile("testdata/grep_cases.txt");

// Patterns where GNU grep 3.12 disagrees with Perl-style back-reference
// semantics. regex-zig follows Perl here (leftmost-first/longest with the
// capture of the last iteration, empty iterations allowed); GNU grep reports
// no match. Documented in docs/compatibility/posix_ere.md.
const known_grep_deviations = [_][]const u8{
    "b|((c?)){2}\\1$", // back-reference to a group that is repeated and can be empty
};

fn isKnownDeviation(pattern: []const u8) bool {
    for (known_grep_deviations) |k| if (std.mem.eql(u8, k, pattern)) return true;
    return false;
}

fn checkGrepCases(mode: u8, engine: regex.Engine) !usize {
    const dialect: regex.Dialect = if (mode == 'E') .posix_ere else .posix_bre;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, grep_cases, '\n');
    var re: ?regex.Regex = null;
    var s: ?regex.Searcher = null;
    defer {
        if (s) |*x| x.deinit();
        if (re) |*x| x.deinit(gpa);
    }
    var pattern: []const u8 = "";
    var active = false;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const kind = f.next().?;
        const a = f.next().?;
        const b = f.rest();
        if (std.mem.eql(u8, kind, "P")) {
            if (s) |*x| x.deinit();
            if (re) |*x| x.deinit(gpa);
            s = null;
            re = null;
            active = a[0] == mode and !isKnownDeviation(b);
            if (!active) continue;
            pattern = b;
            re = regex.Regex.compile(gpa, pattern, .{ .dialect = dialect, .engine = engine }, null) catch |e| {
                // A forced engine may legitimately refuse (back-references).
                if (engine != .auto and e == error.Unsupported) {
                    active = false;
                    continue;
                }
                std.debug.print("COMPILE {s} pattern={s}: {s}\n", .{ @tagName(dialect), pattern, @errorName(e) });
                failures += 1;
                active = false;
                continue;
            };
            s = try re.?.searcher(gpa);
        } else if (active) {
            const want = a[0] == '1';
            const got = try s.?.isMatch(b);
            if (got != want) {
                std.debug.print("GREP MISMATCH {s}/{s} pattern={s} line=\"{s}\" grep={} ours={}\n", .{ @tagName(dialect), @tagName(engine), pattern, b, want, got });
                failures += 1;
            }
        }
    }
    return failures;
}

test "GNU grep agreement: ERE and BRE on every engine" {
    var total: usize = 0;
    for ([_]u8{ 'E', 'B' }) |mode| {
        for ([_]regex.Engine{ .auto, .pike, .backtrack }) |eng| total += try checkGrepCases(mode, eng);
    }
    try std.testing.expectEqual(@as(usize, 0), total);
}

// ---- robustness: fuzzing and allocation failure -----------------------------------------

test "fuzz: arbitrary patterns and haystacks never crash, and engines agree" {
    var prng = std.Random.DefaultPrng.init(0xf022);
    const r = prng.random();
    // Characters that matter to the parsers, plus some non-ASCII bytes.
    const pat_chars = "abc.*+?|()[]{}^$\\-,:=!<>&~0123 \n\xc3\xa9\x80\xff";
    const hay_chars = "abc \n\xc3\xa9\x80\xff1";
    var compiled: usize = 0;
    for (0..4000) |_| {
        var pat_buf: [14]u8 = undefined;
        const plen = r.uintLessThan(usize, pat_buf.len + 1);
        for (pat_buf[0..plen]) |*c| c.* = pat_chars[r.uintLessThan(usize, pat_chars.len)];
        const pat = pat_buf[0..plen];
        const dialect: regex.Dialect = @fromBackingInt(@intCast(r.uintLessThan(u8, 5)));
        const opts: regex.Options = .{ .dialect = dialect, .utf8 = r.boolean(), .ignore_case = r.uintLessThan(u8, 4) == 0, .limits = .{ .max_steps = 200_000 } };

        var re = regex.Regex.compile(gpa, pat, opts, null) catch continue;
        re.deinit(gpa);
        compiled += 1;
        var hay_buf: [16]u8 = undefined;
        const hlen = r.uintLessThan(usize, hay_buf.len + 1);
        for (hay_buf[0..hlen]) |*c| c.* = hay_chars[r.uintLessThan(usize, hay_chars.len)];
        const hay = hay_buf[0..hlen];

        // Every engine that accepts the pattern must give the same spans.
        var first: ?[2]?[2]usize = null;
        for ([_]regex.Engine{ .auto, .dfa, .pike, .backtrack }) |eng| {
            var o = opts;
            o.engine = eng;
            var e = regex.Regex.compile(gpa, pat, o, null) catch continue;
            defer e.deinit(gpa);
            var s = try e.searcher(gpa);
            defer s.deinit();
            const m = s.find(hay, 0) catch |err| switch (err) {
                error.StepLimitExceeded, error.StackLimitExceeded => continue,
                else => return err,
            };
            const got: [2]?[2]usize = .{ if (m) |mm| .{ mm.start(), mm.end() } else null, null };
            if (first) |f| {
                if (!std.meta.eql(f[0], got[0])) {
                    std.debug.print("ENGINE DISAGREE pattern={s} hay={any} dialect={s} utf8={}\n", .{ pat, hay, @tagName(dialect), opts.utf8 });
                    return error.TestUnexpectedResult;
                }
            } else first = got;
        }
    }
    try std.testing.expect(compiled > 300);
}

test "allocation failure: compile and search clean up and never crash" {
    const patterns = [_]struct { pat: []const u8, opts: regex.Options }{
        .{ .pat = "a(b|c)*d", .opts = .{} },
        .{ .pat = "(a)\\1", .opts = .{} },
        .{ .pat = "\\p{L}+é", .opts = .{ .utf8 = true } },
        .{ .pat = "x\\{2,3\\}\\(y\\)", .opts = .{ .dialect = .posix_bre } },
        .{ .pat = "[a-z&&[^aeiou]]+", .opts = .{ .dialect = .rust } },
    };
    patterns: for (patterns) |c| {
        var fail_at: usize = 0;
        while (true) : (fail_at += 1) {
            var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_at });
            const a = fa.allocator();
            var re = regex.Regex.compile(a, c.pat, c.opts, null) catch |e| {
                // Unsupported never depends on allocation (for example \p{..}
                // with -Dunicode_tables=false), so retrying would not end.
                if (e == error.Unsupported) continue :patterns;
                try std.testing.expect(e == error.OutOfMemory);
                continue;
            };
            defer re.deinit(a);
            var s = re.searcher(a) catch {
                continue;
            };
            defer s.deinit();
            _ = s.find("xabcd aab éé xxy", 0) catch {};
            _ = s.count("abcabc") catch {};
            if (!fa.has_induced_failure) break;
        }
        try std.testing.expect(fail_at > 3);
    }
}

test "allocation failure: sets and replacement" {
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_at });
        const a = fa.allocator();
        var set = regex.RegexSet.compile(a, &.{ "ab", "c+", "(d)" }, .{}, null) catch continue;
        defer set.deinit(a);
        var s = set.searcher(a) catch continue;
        defer s.deinit();
        const out = s.replaceAll(a, "abccd", "<$0>") catch |e| {
            try std.testing.expect(e == error.OutOfMemory or e == error.InvalidReplacement);
            continue;
        };
        a.free(out);
        if (!fa.has_induced_failure) break;
    }
}

/// Reference for matchingLines: every line tested on its own with the
/// backtracking engine, which has no skipping.
fn linesReference(pattern: []const u8, hay: []const u8, opts: regex.Options, out: *std.ArrayList(usize)) !void {
    var bo = opts;
    bo.engine = .backtrack;
    var re = try regex.Regex.compile(gpa, pattern, bo, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |line| {
        n += 1;
        if (it.peek() == null and line.len == 0) break;
        if ((try s.find(line, 0)) != null) try out.append(gpa, n);
    }
}

test "perf: matchingLines skipping agrees with per-line search (numbers, offsets)" {
    const hay = "fox\n\nabc\nxfoxy\n\n\nthe two\nzzz\nfo\nfox fox\nends with fox";
    const cases = [_]struct { pat: []const u8, opts: regex.Options }{
        .{ .pat = "fox", .opts = .{} },
        .{ .pat = "f", .opts = .{} },
        .{ .pat = "[fz]", .opts = .{} },
        .{ .pat = "^fox", .opts = .{ .dialect = .posix_ere } },
        .{ .pat = "^((two|the)s?)$", .opts = .{ .dialect = .posix_ere } },
        .{ .pat = "(two|the)s?", .opts = .{ .dialect = .posix_ere } },
        .{ .pat = "^[a-m]+ [n-z]+", .opts = .{ .dialect = .posix_ere } },
        .{ .pat = "fox$", .opts = .{ .dialect = .posix_ere } },
        .{ .pat = "FOX", .opts = .{ .ignore_case = true } },
        .{ .pat = "zzzq", .opts = .{} },
        .{ .pat = "x*", .opts = .{} },
    };
    for (cases) |c| {
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(gpa);
        try linesReference(c.pat, hay, c.opts, &want);
        var re = try regex.Regex.compile(gpa, c.pat, c.opts, null);
        defer re.deinit(gpa);
        var s = try re.searcher(gpa);
        defer s.deinit();
        var it = s.matchingLines(hay, false);
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try it.next()) |l| {
            try got.append(gpa, l.number);
            try std.testing.expect(std.mem.startsWith(u8, hay[l.start..], l.text));
        }
        try std.testing.expectEqualSlices(usize, want.items, got.items);
    }
}

test "perf: DFA start anchors, first-byte skipping and long haystacks agree with the Pike VM" {
    const pats = [_][]const u8{ "^ab", "^ab|^cd", "\\Aab", "(?m)^b+", "^a|b", "q", "[qz]", "[qzy]", "[qzyx]", "needle", "nee+dle" };
    var buf: [3000]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    for (&buf) |*b| b.* = "abcqzyx\n e"[rng.random().uintLessThan(usize, 10)];
    @memcpy(buf[2000..][0..6], "needle");
    for (pats) |pat| {
        var a = try regex.Regex.compile(gpa, pat, .{ .engine = .dfa }, null);
        defer a.deinit(gpa);
        var b = try regex.Regex.compile(gpa, pat, .{ .engine = .pike }, null);
        defer b.deinit(gpa);
        var sa = try a.searcher(gpa);
        defer sa.deinit();
        var sb = try b.searcher(gpa);
        defer sb.deinit();
        var from: usize = 0;
        while (from < buf.len) : (from += 37) {
            const x = try sa.find(&buf, from);
            const y = try sb.find(&buf, from);
            try std.testing.expectEqual(y != null, x != null);
            if (x) |m| {
                try std.testing.expectEqual(y.?.start(), m.start());
                try std.testing.expectEqual(y.?.end(), m.end());
            }
        }
        try std.testing.expectEqual(try sb.matchesAnywhere(&buf), try sa.matchesAnywhere(&buf));
    }
}

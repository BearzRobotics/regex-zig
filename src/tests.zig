//! Behaviour tests for the parser and the backtracking engine. Expected
//! results follow Perl/PCRE and Oniguruma semantics as documented in
//! docs/compatibility/perl.md.

const std = @import("std");
const regex = @import("root.zig");

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
    const m = (try s.find(hay, 0)) orelse return null;
    return .{ m.start(), m.end() };
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

test "pathological patterns hit the step limit instead of hanging" {
    var re = try regex.Regex.compile(gpa, "(a*)*b", .{ .limits = .{ .max_steps = 100_000 } }, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    // Nested quantifiers are exponential in a backtracker; the budget stops it.
    try std.testing.expectError(error.StepLimitExceeded, s.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));

    var re2 = try regex.Regex.compile(gpa, "(a+)+b", .{ .limits = .{ .max_steps = 100_000 } }, null);
    defer re2.deinit(gpa);
    var s2 = try re2.searcher(gpa);
    defer s2.deinit();
    try std.testing.expectError(error.StepLimitExceeded, s2.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));
}

test "stack limit is enforced" {
    var re = try regex.Regex.compile(gpa, ".*x", .{ .limits = .{ .max_stack = 64 } }, null);
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

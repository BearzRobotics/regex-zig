// SPDX-License-Identifier: LGPL-2.0-or-later
//! Line-oriented streaming search over a `std.Io.Reader` (grep-style).
//!
//! Streaming semantics (SPEC section 9, decision 6): a pattern is matched
//! against one line at a time, so a match never crosses a buffer boundary
//! and the engine needs no look-behind beyond the current line. Memory use
//! is one line. A line longer than the reader's buffer is an error
//! (`error.StreamTooLong`) rather than a silent split. General streaming of
//! matches that may span lines is not implemented.

const std = @import("std");
const backtrack = @import("backtrack.zig");
const ops = @import("ops.zig");

const Searcher = backtrack.Searcher;

pub const LineStream = struct {
    searcher: *Searcher,
    reader: *std.Io.Reader,
    /// Report the lines that do not match (`grep -v`).
    invert: bool = false,
    number: usize = 0,
    offset: usize = 0,

    pub const Error = backtrack.MatchError || error{ ReadFailed, StreamTooLong };

    /// The next matching line. `Line.text` points into the reader's buffer
    /// and is valid until the next call.
    pub fn next(ls: *LineStream) Error!?ops.Line {
        while (try ls.reader.takeDelimiter('\n')) |text| {
            ls.number += 1;
            const start = ls.offset;
            ls.offset += text.len + 1;
            if ((try ls.searcher.matchesAnywhere(text)) != ls.invert)
                return .{ .number = ls.number, .start = start, .text = text };
        }
        return null;
    }
};

const regex = @import("root.zig");

test "lines from memory and from a reader" {
    const gpa = std.testing.allocator;
    var re = try regex.Regex.compile(gpa, "fo+", .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    const data = "a\nfoo\nbar\nxfoox\n\nfo";

    var it = s.matchingLines(data, false);
    const want = [_]struct { n: usize, text: []const u8 }{ .{ .n = 2, .text = "foo" }, .{ .n = 4, .text = "xfoox" }, .{ .n = 6, .text = "fo" } };
    for (want) |w| {
        const l = (try it.next()).?;
        try std.testing.expectEqual(w.n, l.number);
        try std.testing.expectEqualStrings(w.text, l.text);
    }
    try std.testing.expect((try it.next()) == null);

    var inv = s.matchingLines(data, true);
    var count: usize = 0;
    while (try inv.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count); // a, bar, and the empty line

    var reader = std.Io.Reader.fixed(data);
    var ls: LineStream = .{ .searcher = &s, .reader = &reader };
    const first = (try ls.next()).?;
    try std.testing.expectEqual(@as(usize, 2), first.number);
    try std.testing.expectEqual(@as(usize, 2), first.start);
    try std.testing.expectEqualStrings("foo", first.text);
    _ = (try ls.next()).?;
    const last = (try ls.next()).?;
    try std.testing.expectEqualStrings("fo", last.text);
    try std.testing.expect((try ls.next()) == null);
}

test "line anchors apply to each line" {
    const gpa = std.testing.allocator;
    var re = try regex.Regex.compile(gpa, "^b.*d$", .{ .dialect = .posix_ere }, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    var it = s.matchingLines("abcd\nbxd\nbd\nb\n", false);
    try std.testing.expectEqualStrings("bxd", (try it.next()).?.text);
    try std.testing.expectEqualStrings("bd", (try it.next()).?.text);
    try std.testing.expect((try it.next()) == null);
}

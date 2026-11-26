// SPDX-License-Identifier: LGPL-2.0-or-later
//! Convenience operations built on Searcher.find: iteration, counting,
//! replacement and splitting. They are re-exported as Searcher methods.
//!
//! Empty matches: after an empty match the next search starts one byte later,
//! so every position is tried once and the iteration always terminates. This
//! is the Rust `regex` rule. It differs from Perl only for patterns that can
//! match both empty and non-empty at one position (`|a` on "a").

const std = @import("std");
const backtrack = @import("backtrack.zig");

const Searcher = backtrack.Searcher;
const Match = backtrack.Match;
const MatchError = backtrack.MatchError;

pub const Span = struct { start: usize, end: usize };

pub const ReplaceError = MatchError || error{
    /// The replacement text has a malformed or unknown `$` reference.
    InvalidReplacement,
};

/// True if the pattern matches anywhere in `hay`.
pub fn isMatch(s: *Searcher, hay: []const u8) MatchError!bool {
    return s.matchesAnywhere(hay);
}

/// Iterates over successive, non-overlapping matches. Each Match borrows the
/// searcher's registers and is valid until the next call to `next`.
pub const Matches = struct {
    searcher: *Searcher,
    hay: []const u8,
    pos: usize = 0,

    pub fn next(it: *Matches) MatchError!?Match {
        if (it.pos > it.hay.len) return null;
        const m = (try it.searcher.find(it.hay, it.pos)) orelse {
            it.pos = it.hay.len + 1;
            return null;
        };
        it.pos = if (m.end() == m.start()) m.end() + 1 else m.end();
        return m;
    }
};

pub fn matches(s: *Searcher, hay: []const u8) Matches {
    return .{ .searcher = s, .hay = hay };
}

pub fn count(s: *Searcher, hay: []const u8) MatchError!usize {
    var it = matches(s, hay);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// Spans of every match. The caller owns the returned slice.
pub fn findAll(s: *Searcher, gpa: std.mem.Allocator, hay: []const u8) MatchError![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    var it = matches(s, hay);
    while (try it.next()) |m| try out.append(gpa, .{ .start = m.start(), .end = m.end() });
    return out.toOwnedSlice(gpa);
}

/// The pieces of `hay` between matches (Rust `split` rules: an empty match at
/// either end yields an empty first or last piece). The pieces borrow `hay`;
/// the caller owns the returned slice.
pub fn split(s: *Searcher, gpa: std.mem.Allocator, hay: []const u8) MatchError![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var last: usize = 0;
    var it = matches(s, hay);
    while (try it.next()) |m| {
        try out.append(gpa, hay[last..m.start()]);
        last = m.end();
    }
    try out.append(gpa, hay[last..]);
    return out.toOwnedSlice(gpa);
}

const Piece = union(enum) { text: []const u8, group: u32 };

/// Reads the next piece of a replacement template. Syntax: `$N` and `${N}`
/// (group number), `${name}` (named group), `$$` (a literal `$`). Any other
/// `$` is an error rather than silently literal, so typos are caught.
fn nextPiece(s: *const Searcher, repl: []const u8, i: *usize) error{InvalidReplacement}!Piece {
    if (repl[i.*] != '$') {
        const end = std.mem.indexOfScalarPos(u8, repl, i.*, '$') orelse repl.len;
        defer i.* = end;
        return .{ .text = repl[i.*..end] };
    }
    const rest = repl[i.* + 1 ..];
    if (rest.len == 0) return error.InvalidReplacement;
    if (rest[0] == '$') {
        i.* += 2;
        return .{ .text = "$" };
    }
    var body: []const u8 = undefined;
    if (rest[0] == '{') {
        const close = std.mem.indexOfScalar(u8, rest, '}') orelse return error.InvalidReplacement;
        body = rest[1..close];
        i.* += close + 2;
    } else {
        var n: usize = 0;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        body = rest[0..n];
        i.* += n + 1;
    }
    if (body.len == 0) return error.InvalidReplacement;
    // Digits only: parseInt would also take a sign or `_`.
    const numeric = for (body) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    const group = if (numeric)
        std.fmt.parseInt(u32, body, 10) catch return error.InvalidReplacement
    else blk: {
        for (s.prog.names) |nm| if (std.mem.eql(u8, nm.name, body)) break :blk nm.index;
        return error.InvalidReplacement;
    };
    if (group > s.prog.group_count) return error.InvalidReplacement;
    return .{ .group = group };
}

/// Replaces every match with `repl`, expanding `$` references (see
/// nextPiece). A group that did not participate expands to nothing. The
/// template is validated before searching, so a bad one fails even when
/// nothing matches. The caller owns the returned slice.
pub fn replaceAll(s: *Searcher, gpa: std.mem.Allocator, hay: []const u8, repl: []const u8) ReplaceError![]u8 {
    var i: usize = 0;
    while (i < repl.len) _ = try nextPiece(s, repl, &i);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var last: usize = 0;
    var it = matches(s, hay);
    while (try it.next()) |m| {
        try out.appendSlice(gpa, hay[last..m.start()]);
        i = 0;
        while (i < repl.len) switch (try nextPiece(s, repl, &i)) {
            .text => |t| try out.appendSlice(gpa, t),
            .group => |g| if (m.group(g)) |sp| try out.appendSlice(gpa, hay[sp[0]..sp[1]]),
        };
        last = m.end();
    }
    try out.appendSlice(gpa, hay[last..]);
    return out.toOwnedSlice(gpa);
}

/// One line of the input, without its newline.
pub const Line = struct {
    /// 1-based.
    number: usize,
    /// Offset of the first byte of the line in the input.
    start: usize,
    text: []const u8,
};

/// Iterates over the lines of `hay` that match, or with `invert` that do not
/// (`grep` and `grep -v`). Each line is matched on its own: `^` and `$` are
/// the ends of the line and a match never spans lines. A final line with no
/// newline counts; an empty piece after the last newline does not.
pub const MatchingLines = struct {
    searcher: *Searcher,
    hay: []const u8,
    invert: bool = false,
    pos: usize = 0,
    number: usize = 0,

    pub fn next(it: *MatchingLines) MatchError!?Line {
        while (it.pos < it.hay.len) {
            if (!it.invert) {
                // Skip, in one scan, every line without a byte a match can
                // start with; they cannot match.
                if (it.searcher.nextCandidate(it.hay, it.pos)) |q| {
                    if (q >= it.hay.len) {
                        it.pos = it.hay.len;
                        return null;
                    }
                    const ls = if (std.mem.lastIndexOfScalar(u8, it.hay[it.pos..q], '\n')) |i| it.pos + i + 1 else it.pos;
                    it.number += countNewlines(it.hay[it.pos..ls]);
                    it.pos = ls;
                }
            }
            const start = it.pos;
            const nl = std.mem.indexOfScalarPos(u8, it.hay, start, '\n') orelse it.hay.len;
            it.pos = nl + 1;
            it.number += 1;
            const text = it.hay[start..nl];
            if ((try it.searcher.matchesAnywhere(text)) != it.invert)
                return .{ .number = it.number, .start = start, .text = text };
        }
        return null;
    }
};

fn countNewlines(buf: []const u8) usize {
    const V = 32;
    var n: usize = 0;
    var i: usize = 0;
    const nl: @Vector(V, u8) = @splat('\n');
    while (i + V <= buf.len) : (i += V) {
        const v: @Vector(V, u8) = buf[i..][0..V].*;
        n += @popCount(@as(u32, @bitCast(v == nl)));
    }
    while (i < buf.len) : (i += 1) n += @intFromBool(buf[i] == '\n');
    return n;
}

pub fn matchingLines(s: *Searcher, hay: []const u8, invert: bool) MatchingLines {
    return .{ .searcher = s, .hay = hay, .invert = invert };
}

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
    return (try s.find(hay, 0)) != null;
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
    const group = if (std.fmt.parseInt(u32, body, 10)) |g| g else |_| blk: {
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

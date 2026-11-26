// SPDX-License-Identifier: LGPL-2.0-or-later
//! Code-point ranges and their lowering to UTF-8 byte sequences (ADR 0001).
//!
//! In `utf8` mode a character class is a sorted list of Unicode scalar value
//! ranges. The compiler cannot test code points directly because the matching
//! VM works on bytes, so each range is split into pieces whose UTF-8
//! encodings are "one byte range per position". For example U+0080..U+07FF
//! becomes `[C2-DF][80-BF]`. Only well-formed UTF-8 is accepted: no overlong
//! forms, no surrogates, nothing above U+10FFFF.

const std = @import("std");

pub const max_scalar: u21 = 0x10FFFF;
const surrogate_lo: u21 = 0xD800;
const surrogate_hi: u21 = 0xDFFF;

pub const CpRange = struct { lo: u21, hi: u21 };

pub const ByteRange = struct { lo: u8, hi: u8 };

/// A run of 1 to 4 byte ranges; a byte string matches when each of its bytes
/// is inside the range at the same position.
pub const Sequence = struct {
    len: u3 = 0,
    ranges: [4]ByteRange = undefined,

    pub fn accepts(s: Sequence, bytes: []const u8) bool {
        if (bytes.len != s.len) return false;
        for (bytes, s.ranges[0..s.len]) |b, r| if (b < r.lo or b > r.hi) return false;
        return true;
    }
};

fn rangeLessThan(_: void, a: CpRange, b: CpRange) bool {
    return a.lo < b.lo;
}

/// Sorts, merges touching or overlapping ranges, and removes surrogates
/// (which are not scalar values). The result is canonical.
pub fn normalize(gpa: std.mem.Allocator, list: *std.ArrayList(CpRange)) std.mem.Allocator.Error!void {
    var clipped: std.ArrayList(CpRange) = .empty;
    defer clipped.deinit(gpa);
    for (list.items) |r| {
        if (r.hi < surrogate_lo or r.lo > surrogate_hi) {
            try clipped.append(gpa, r);
        } else {
            if (r.lo < surrogate_lo) try clipped.append(gpa, .{ .lo = r.lo, .hi = surrogate_lo - 1 });
            if (r.hi > surrogate_hi) try clipped.append(gpa, .{ .lo = surrogate_hi + 1, .hi = r.hi });
        }
    }
    std.mem.sort(CpRange, clipped.items, {}, rangeLessThan);
    list.clearRetainingCapacity();
    for (clipped.items) |r| {
        if (list.items.len > 0) {
            const last = &list.items[list.items.len - 1];
            if (@as(u32, r.lo) <= @as(u32, last.hi) + 1) {
                last.hi = @max(last.hi, r.hi);
                continue;
            }
        }
        try list.append(gpa, r);
    }
}

/// Replaces a normalized list with its complement inside `floor..max_scalar`
/// (surrogates stay excluded). Code points below `floor` are dropped.
pub fn complementFrom(gpa: std.mem.Allocator, list: *std.ArrayList(CpRange), floor: u21) std.mem.Allocator.Error!void {
    var out: std.ArrayList(CpRange) = .empty;
    defer out.deinit(gpa);
    var next: u32 = floor;
    for (list.items) |r| {
        if (r.hi < floor) continue;
        if (r.lo > next) try out.append(gpa, .{ .lo = @intCast(next), .hi = r.lo - 1 });
        next = @max(next, @as(u32, r.hi) + 1);
    }
    if (next <= max_scalar) try out.append(gpa, .{ .lo = @intCast(next), .hi = max_scalar });
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, out.items);
    try normalize(gpa, list);
}

/// Appends the byte sequences that together accept exactly the UTF-8
/// encodings of the scalar values in `r`. `r` must contain no surrogates
/// (use `normalize` first).
pub fn appendSequences(gpa: std.mem.Allocator, out: *std.ArrayList(Sequence), r: CpRange) std.mem.Allocator.Error!void {
    try split(gpa, out, r.lo, r.hi);
}

fn split(gpa: std.mem.Allocator, out: *std.ArrayList(Sequence), lo: u21, hi: u21) std.mem.Allocator.Error!void {
    // Keep each piece within one encoded length (1, 2, 3 or 4 bytes).
    inline for (.{ 0x7F, 0x7FF, 0xFFFF }) |boundary| {
        if (lo <= boundary and boundary < hi) {
            try split(gpa, out, lo, boundary);
            try split(gpa, out, boundary + 1, hi);
            return;
        }
    }
    if (hi <= 0x7F) {
        var s: Sequence = .{ .len = 1 };
        s.ranges[0] = .{ .lo = @intCast(lo), .hi = @intCast(hi) };
        try out.append(gpa, s);
        return;
    }
    // Within one length, split until every continuation byte position spans
    // either a full 80-BF run or a single value, so the range is a plain
    // product of byte ranges. Position i (from the end) covers the low 6*i bits.
    var i: u5 = 1;
    while (i < 4) : (i += 1) {
        const mask: u21 = (@as(u21, 1) << (6 * i)) - 1;
        if ((lo & ~mask) != (hi & ~mask)) {
            if ((lo & mask) != 0) {
                try split(gpa, out, lo, lo | mask);
                try split(gpa, out, (lo | mask) + 1, hi);
                return;
            }
            if ((hi & mask) != mask) {
                try split(gpa, out, lo, (hi & ~mask) - 1);
                try split(gpa, out, hi & ~mask, hi);
                return;
            }
        }
    }
    var lo_bytes: [4]u8 = undefined;
    var hi_bytes: [4]u8 = undefined;
    // Both ends are scalar values by precondition, so encoding cannot fail.
    const n = std.unicode.utf8Encode(lo, &lo_bytes) catch unreachable;
    _ = std.unicode.utf8Encode(hi, &hi_bytes) catch unreachable;
    var s: Sequence = .{ .len = n };
    for (0..n) |k| s.ranges[k] = .{ .lo = lo_bytes[k], .hi = hi_bytes[k] };
    try out.append(gpa, s);
}

/// Binary search in a normalized range list.
pub fn containsRange(ranges: []const CpRange, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// The UTF-8 lead bytes that can begin an encoding of a scalar in `r`.
pub fn leadByteRange(r: CpRange) ByteRange {
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    _ = std.unicode.utf8Encode(r.lo, &a) catch unreachable;
    _ = std.unicode.utf8Encode(r.hi, &b) catch unreachable;
    return .{ .lo = a[0], .hi = b[0] };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn sequencesFor(gpa: std.mem.Allocator, ranges: []const CpRange) !std.ArrayList(Sequence) {
    var list: std.ArrayList(CpRange) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, ranges);
    try normalize(gpa, &list);
    var seqs: std.ArrayList(Sequence) = .empty;
    errdefer seqs.deinit(gpa);
    for (list.items) |r| try appendSequences(gpa, &seqs, r);
    return seqs;
}

fn acceptedBy(seqs: []const Sequence, bytes: []const u8) usize {
    var n: usize = 0;
    for (seqs) |s| {
        if (s.accepts(bytes)) n += 1;
    }
    return n;
}

/// Every scalar value is accepted exactly when it is in `ranges`, and by at
/// most one sequence (so alternation order cannot matter).
fn expectExactly(ranges: []const CpRange) !void {
    var seqs = try sequencesFor(testing.allocator, ranges);
    defer seqs.deinit(testing.allocator);
    var cp: u21 = 0;
    while (true) : (cp += 1) {
        if (cp < surrogate_lo or cp > surrogate_hi) {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            var inside = false;
            for (ranges) |r| inside = inside or (cp >= r.lo and cp <= r.hi);
            const hits = acceptedBy(seqs.items, buf[0..n]);
            try testing.expectEqual(@as(usize, if (inside) 1 else 0), hits);
        }
        if (cp == max_scalar) break;
    }
}

test "sequences: whole scalar range accepts every scalar exactly once" {
    try expectExactly(&.{.{ .lo = 0, .hi = max_scalar }});
}

test "sequences: ranges that cross length and continuation boundaries" {
    try expectExactly(&.{.{ .lo = 0x80, .hi = 0x7FF }});
    try expectExactly(&.{.{ .lo = 0x7E, .hi = 0x81 }});
    try expectExactly(&.{.{ .lo = 0x7FF, .hi = 0x800 }});
    try expectExactly(&.{.{ .lo = 0xE9, .hi = 0x1F600 }});
    try expectExactly(&.{.{ .lo = 0x3040, .hi = 0x309F }});
    try expectExactly(&.{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 0xFFFF, .hi = 0x10000 }, .{ .lo = 0x10FFFF, .hi = 0x10FFFF } });
}

test "sequences reject ill-formed UTF-8" {
    var seqs = try sequencesFor(testing.allocator, &.{.{ .lo = 0, .hi = max_scalar }});
    defer seqs.deinit(testing.allocator);
    const bad = [_][]const u8{
        "\xC0\x80", // overlong NUL
        "\xC1\xBF", // overlong
        "\xE0\x80\x80", // overlong
        "\xF0\x80\x80\x80", // overlong
        "\xED\xA0\x80", // surrogate D800
        "\xED\xBF\xBF", // surrogate DFFF
        "\xF4\x90\x80\x80", // above U+10FFFF
        "\xF5\x80\x80\x80", // invalid lead
        "\xFF",
        "\x80", // stray continuation
        "\xC2", // truncated
        "\xE2\x82", // truncated
    };
    for (bad) |b| try testing.expectEqual(@as(usize, 0), acceptedBy(seqs.items, b));
}

test "sequence count for the full scalar range stays small" {
    var seqs = try sequencesFor(testing.allocator, &.{.{ .lo = 0, .hi = max_scalar }});
    defer seqs.deinit(testing.allocator);
    try testing.expect(seqs.items.len <= 12);
}

test "normalize merges, sorts and clips surrogates" {
    var list: std.ArrayList(CpRange) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &.{
        .{ .lo = 10, .hi = 20 }, .{ .lo = 0, .hi = 5 }, .{ .lo = 6, .hi = 9 }, .{ .lo = 0xD000, .hi = 0xE100 },
    });
    try normalize(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(CpRange{ .lo = 0, .hi = 20 }, list.items[0]);
    try testing.expectEqual(CpRange{ .lo = 0xD000, .hi = 0xD7FF }, list.items[1]);
    try testing.expectEqual(CpRange{ .lo = 0xE000, .hi = 0xE100 }, list.items[2]);
}

test "complementFrom" {
    var list: std.ArrayList(CpRange) = .empty;
    defer list.deinit(testing.allocator);
    try list.append(testing.allocator, .{ .lo = 0x80, .hi = 0xFF });
    try complementFrom(testing.allocator, &list, 0x80);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(CpRange{ .lo = 0x100, .hi = 0xD7FF }, list.items[0]);
    try testing.expectEqual(CpRange{ .lo = 0xE000, .hi = max_scalar }, list.items[1]);
}

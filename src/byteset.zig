//! A set of byte values, stored as a 256-bit bitmap.

const std = @import("std");

pub const ByteSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn add(s: *ByteSet, c: u8) void {
        s.bits[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
    }

    /// Adds every byte in lo...hi (inclusive). Does nothing when lo > hi.
    pub fn addRange(s: *ByteSet, lo: u8, hi: u8) void {
        if (lo > hi) return;
        var c: u16 = lo;
        while (c <= hi) : (c += 1) s.add(@intCast(c));
    }

    pub fn has(s: ByteSet, c: u8) bool {
        return s.bits[c >> 6] & (@as(u64, 1) << @intCast(c & 63)) != 0;
    }

    pub fn unionWith(s: *ByteSet, o: ByteSet) void {
        for (&s.bits, o.bits) |*a, b| a.* |= b;
    }

    pub fn intersectWith(s: *ByteSet, o: ByteSet) void {
        for (&s.bits, o.bits) |*a, b| a.* &= b;
    }

    pub fn invert(s: *ByteSet) void {
        for (&s.bits) |*a| a.* = ~a.*;
    }

    /// For every ASCII letter in the set, also add its other-case partner.
    pub fn addAsciiCaseCounterparts(s: *ByteSet) void {
        var c: u8 = 'a';
        while (c <= 'z') : (c += 1) {
            const up = c - 32;
            if (s.has(c) or s.has(up)) {
                s.add(c);
                s.add(up);
            }
        }
    }

    pub fn count(s: ByteSet) usize {
        var n: usize = 0;
        for (s.bits) |b| n += @popCount(b);
        return n;
    }

    pub fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

test "add, range, has, invert" {
    var s: ByteSet = .{};
    s.addRange('a', 'c');
    try std.testing.expect(s.has('b') and !s.has('d'));
    s.invert();
    try std.testing.expect(!s.has('b') and s.has('d'));
    try std.testing.expectEqual(@as(usize, 253), s.count());
}

test "case counterparts" {
    var s: ByteSet = .{};
    s.add('k');
    s.add('Z');
    s.addAsciiCaseCounterparts();
    try std.testing.expect(s.has('K') and s.has('z'));
}

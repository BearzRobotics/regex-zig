//! Unicode property lookup over the generated tables in unicode_tables.zig.
//!
//! A table is a flat, sorted list of inclusive (lo, hi) scalar-value pairs.
//! Names are matched loosely (UAX #44, LM3): case, spaces, '_' and '-' are
//! ignored.

const std = @import("std");
const tables = @import("unicode_tables.zig");
const utf8 = @import("utf8.zig");

pub const Table = tables.Table;
pub const version = tables.version;

/// \w: Alphabetic + Mark + Decimal_Number + Connector_Punctuation +
/// Join_Control (UTS #18, Annex C).
pub const word = tables.word;
/// \d: General_Category=Decimal_Number.
pub const digit = tables.digit;
/// \s: White_Space.
pub const space = tables.space;

pub const alphabetic = tables.binary.get("alphabetic").?;
pub const uppercase = tables.binary.get("uppercase").?;
pub const lowercase = tables.binary.get("lowercase").?;
/// General_Category=Space_Separator.
pub const space_separator = tables.general_category.get("zs").?;

pub fn contains(t: Table, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = t.len / 2;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < t[2 * mid]) {
            hi = mid;
        } else if (cp > t[2 * mid + 1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// True for a character matched by \w in utf8 mode.
pub fn isWord(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return contains(word, cp);
}

pub fn appendRanges(gpa: std.mem.Allocator, list: *std.ArrayList(utf8.CpRange), t: Table) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < t.len) : (i += 2) try list.append(gpa, .{ .lo = t[i], .hi = t[i + 1] });
}

fn looseKey(buf: []u8, name: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (c == ' ' or c == '_' or c == '-') continue;
        if (n == buf.len) return null;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn lookup(comptime map: anytype, name: []const u8) ?Table {
    var buf: [64]u8 = undefined;
    const key = looseKey(&buf, name) orelse return null;
    return map.get(key);
}

/// The table for a property as written inside `\p{...}`: `Lu`, `Letter`,
/// `Greek`, `Alphabetic`, `gc=Lu`, `General_Category=Letter`, `sc=Greek`,
/// `Script=Greek`. Null when the name is unknown or unsupported (for
/// example Script_Extensions).
pub fn lookupProperty(name: []const u8) ?Table {
    if (std.mem.indexOfAny(u8, name, "=:")) |i| {
        var buf: [64]u8 = undefined;
        const key = looseKey(&buf, name[0..i]) orelse return null;
        const value = name[i + 1 ..];
        if (std.mem.eql(u8, key, "gc") or std.mem.eql(u8, key, "generalcategory") or std.mem.eql(u8, key, "category"))
            return lookup(tables.general_category, value);
        if (std.mem.eql(u8, key, "sc") or std.mem.eql(u8, key, "script"))
            return lookup(tables.script, value);
        return null;
    }
    return lookup(tables.binary, name) orelse
        lookup(tables.general_category, name) orelse
        lookup(tables.script, name);
}

test "contains uses inclusive pairs" {
    const t = [_]u21{ 0x41, 0x5A, 0x61, 0x7A };
    try std.testing.expect(contains(&t, 'A') and contains(&t, 'Z') and contains(&t, 'q'));
    try std.testing.expect(!contains(&t, '@') and !contains(&t, '[') and !contains(&t, '{'));
}

test "property names" {
    try std.testing.expect(lookupProperty("Lu") != null);
    try std.testing.expect(lookupProperty("uppercase_letter") != null);
    try std.testing.expect(lookupProperty("gc=Lu") != null);
    try std.testing.expect(lookupProperty("General Category=Lu") != null); // loose matching ignores spaces
    try std.testing.expect(lookupProperty("Script=Greek") != null);
    try std.testing.expect(lookupProperty("sc=Grek") != null);
    try std.testing.expect(lookupProperty("Greek") != null);
    try std.testing.expect(lookupProperty("alphabetic") != null);
    try std.testing.expect(lookupProperty("Nope") == null);
    try std.testing.expect(lookupProperty("gc=Greek") == null);
    try std.testing.expect(lookupProperty("scx=Greek") == null);
}

test "known members" {
    const lu = lookupProperty("Lu").?;
    try std.testing.expect(contains(lu, 'A') and contains(lu, 0xC9) and !contains(lu, 'a') and !contains(lu, 0xE9));
    try std.testing.expect(contains(lookupProperty("Greek").?, 0x3B1));
    try std.testing.expect(contains(lookupProperty("Han").?, 0x6F22));
    try std.testing.expect(contains(digit, '7') and contains(digit, 0x663)); // ARABIC-INDIC DIGIT THREE
    try std.testing.expect(contains(space, 0xA0) and contains(space, 0x3000) and !contains(space, 'a'));
    try std.testing.expect(isWord('a') and isWord('_') and isWord(0xE9) and isWord(0x6F22) and isWord(0x300)); // combining mark
    try std.testing.expect(!isWord(' ') and !isWord('-') and !isWord(0x263A) and !isWord(0xA0));
    try std.testing.expect(contains(lookupProperty("Any").?, 0x10FFFF));
    try std.testing.expect(!contains(lookupProperty("Assigned").?, 0x378)); // unassigned in Greek block
}

test "tables are sorted, non-overlapping, and exclude surrogates" {
    const names = [_][]const u8{ "L", "Lu", "Nd", "Greek", "Han", "Alphabetic", "Cn", "C", "Any" };
    for (names) |n| {
        const t = lookupProperty(n).?;
        try std.testing.expect(t.len % 2 == 0);
        var prev: i64 = -1;
        var i: usize = 0;
        while (i < t.len) : (i += 2) {
            try std.testing.expect(t[i] <= t[i + 1]);
            try std.testing.expect(@as(i64, t[i]) > prev + 1 or prev == -1);
            try std.testing.expect(t[i] < 0xD800 or t[i] > 0xDFFF);
            try std.testing.expect(t[i + 1] < 0xD800 or t[i + 1] > 0xDFFF);
            prev = t[i + 1];
        }
    }
    try std.testing.expect(word.len > 0);
}

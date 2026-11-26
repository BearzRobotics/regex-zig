// SPDX-License-Identifier: LGPL-2.0-or-later
//! Unicode property lookup over the generated tables in unicode_tables.zig.
//!
//! A table is a flat, sorted list of inclusive (lo, hi) scalar-value pairs.
//! Names are matched loosely (UAX #44, LM3): case, spaces, '_' and '-' are
//! ignored.

const std = @import("std");
const build_options = @import("build_options");
const utf8 = @import("utf8.zig");

/// False when built with -Dunicode_tables=false: the tables are not linked,
/// every table below is empty, and callers fall back to ASCII behaviour.
pub const enabled = build_options.unicode_tables;

const tables = if (enabled) @import("unicode_tables.zig") else struct {};

pub const Table = []const u21;
pub const version = if (enabled) tables.version else "none";
const no_table: Table = &.{};

/// \w: Alphabetic + Mark + Decimal_Number + Connector_Punctuation +
/// Join_Control (UTS #18, Annex C).
pub const word: Table = if (enabled) tables.word else no_table;
/// \d: General_Category=Decimal_Number.
pub const digit: Table = if (enabled) tables.digit else no_table;
/// \s: White_Space.
pub const space: Table = if (enabled) tables.space else no_table;

pub const alphabetic: Table = if (enabled) tables.binary.get("alphabetic").? else no_table;
pub const uppercase: Table = if (enabled) tables.binary.get("uppercase").? else no_table;
pub const lowercase: Table = if (enabled) tables.binary.get("lowercase").? else no_table;
/// General_Category=Space_Separator.
pub const space_separator: Table = if (enabled) tables.general_category.get("zs").? else no_table;

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

// ---- simple case folding ---------------------------------------------------

/// Code points per row of `orbits`; shorter rows are padded with 0.
pub const orbit_width: usize = if (enabled) tables.orbit_width else 1;
/// Each row is one set of code points that are equal under Unicode simple
/// case folding (CaseFolding.txt, statuses C and S), ascending.
pub const orbits: []const u21 = if (enabled) &tables.orbits else &.{};
const orbit_index: []const u32 = if (enabled) &tables.orbit_index else &.{};

/// The row of `orbits` that contains `cp` (including `cp` itself), or null
/// when `cp` has no case variants.
pub fn orbit(cp: u21) ?[]const u21 {
    if (!enabled) return null;
    var lo: usize = 0;
    var hi: usize = orbit_index.len / 2;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const key = orbit_index[2 * mid];
        if (cp < key) {
            hi = mid;
        } else if (cp > key) {
            lo = mid + 1;
        } else return orbitRow(orbit_index[2 * mid + 1]);
    }
    return null;
}

pub fn orbitRow(row: usize) []const u21 {
    if (!enabled) return &.{};
    const cells = orbits[row * orbit_width ..][0..orbit_width];
    var n: usize = cells.len;
    while (cells[n - 1] == 0) n -= 1;
    return cells[0..n];
}

pub fn orbitCount() usize {
    return orbits.len / orbit_width;
}

/// True if the two code points are equal under simple case folding.
pub fn eqlFold(a: u21, b: u21) bool {
    if (a == b) return true;
    const row = orbit(a) orelse return false;
    return std.mem.indexOfScalar(u21, row, b) != null;
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
    if (!enabled) return null;
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
    if (!enabled) return error.SkipZigTest;
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
    if (!enabled) return error.SkipZigTest;
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
    if (!enabled) return error.SkipZigTest;
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

test "case folding orbits" {
    if (!enabled) return error.SkipZigTest;
    try std.testing.expect(eqlFold('a', 'A') and eqlFold(0xE9, 0xC9));
    try std.testing.expect(eqlFold('k', 0x212A) and eqlFold('K', 0x212A)); // KELVIN SIGN
    try std.testing.expect(eqlFold('s', 0x17F)); // LONG S
    try std.testing.expect(eqlFold(0x3C3, 0x3C2) and eqlFold(0x3C3, 0x3A3)); // sigma forms
    try std.testing.expect(eqlFold(0xDF, 0x1E9E)); // sharp s
    try std.testing.expect(!eqlFold('a', 'b') and !eqlFold('1', '2'));
    try std.testing.expect(orbit('1') == null and orbit(0x263A) == null);
    // Every row is ascending, has no padding inside, and is found from each member.
    for (0..orbitCount()) |r| {
        const row = orbitRow(r);
        try std.testing.expect(row.len >= 2);
        for (row, 0..) |cp, i| {
            if (i > 0) try std.testing.expect(row[i - 1] < cp);
            try std.testing.expectEqual(row.ptr, orbit(cp).?.ptr);
        }
    }
}

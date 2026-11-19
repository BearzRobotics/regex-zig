//! Context checks shared by the matching engines: empty-width assertions and
//! UTF-8 decoding around a position. They look at the whole haystack, so
//! they behave the same in every engine.

const std = @import("std");
const ast = @import("ast.zig");
const ByteSet = @import("byteset.zig").ByteSet;
const unicode = @import("unicode.zig");

/// True if the assertion holds at `pos`. `search_start` is where this
/// search began (for \\G).
pub fn check(a: ast.Assertion, hay: []const u8, pos: usize, search_start: usize, utf8_mode: bool) bool {
    return switch (a) {
        .line_start => pos == 0 or hay[pos - 1] == '\n',
        .line_end => pos == hay.len or hay[pos] == '\n',
        .text_start => pos == 0,
        .text_end => pos == hay.len,
        .text_end_or_final_newline => pos == hay.len or (pos + 1 == hay.len and hay[pos] == '\n'),
        .word_boundary => wordBefore(hay, pos, utf8_mode) != wordAfter(hay, pos, utf8_mode),
        .not_word_boundary => wordBefore(hay, pos, utf8_mode) == wordAfter(hay, pos, utf8_mode),
        .word_start => !wordBefore(hay, pos, utf8_mode) and wordAfter(hay, pos, utf8_mode),
        .word_end => wordBefore(hay, pos, utf8_mode) and !wordAfter(hay, pos, utf8_mode),
        .search_start => pos == search_start,
    };
}

pub const Decoded = struct { cp: u21, len: u3 };

/// The well-formed UTF-8 character starting at `pos`, or null (end of input,
/// or an invalid or truncated sequence).
pub fn decodeAt(hay: []const u8, pos: usize) ?Decoded {
    if (pos >= hay.len) return null;
    const b = hay[pos];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (hay.len - pos < len) return null;
    const cp = std.unicode.utf8Decode(hay[pos..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// The well-formed character that ends exactly at `pos`, if there is one.
pub fn decodeBefore(hay: []const u8, pos: usize) ?Decoded {
    if (pos == 0) return null;
    var start = pos - 1;
    // A character is at most 4 bytes: step back over continuation bytes.
    while (start > 0 and pos - start < 4 and hay[start] & 0xC0 == 0x80) start -= 1;
    const d = decodeAt(hay, start) orelse return null;
    return if (start + d.len == pos) d else null;
}

fn wordBefore(hay: []const u8, pos: usize, utf8_mode: bool) bool {
    if (pos == 0) return false;
    if (!utf8_mode or hay[pos - 1] < 0x80) return ByteSet.isWordByte(hay[pos - 1]);
    const d = decodeBefore(hay, pos) orelse return false;
    return unicode.isWord(d.cp);
}

fn wordAfter(hay: []const u8, pos: usize, utf8_mode: bool) bool {
    if (pos >= hay.len) return false;
    if (!utf8_mode or hay[pos] < 0x80) return ByteSet.isWordByte(hay[pos]);
    const d = decodeAt(hay, pos) orelse return false;
    return unicode.isWord(d.cp);
}

//! Parser for the Perl-style syntax family. Two dialects share one parser:
//!
//!   * .perl       — Perl/PCRE flavour: `^`/`$` match at text boundaries unless
//!                   (?m); (?s) lets `.` match '\n'; `\h` is horizontal space.
//!   * .oniguruma  — Oniguruma "Ruby" flavour as used by Sublime syntaxes:
//!                   `^`/`$` are always line anchors; (?m) lets `.` match '\n';
//!                   `\h` is a hex digit; `{,n}` is accepted.
//!
//! Matching is byte-based for now: a pattern byte >= 0x80 is a literal byte,
//! and `.` and negated classes consume one byte. Unicode properties (\p{..})
//! are reported as unsupported rather than ignored (SPEC §5).

const std = @import("std");
const ast = @import("ast.zig");
const ByteSet = @import("byteset.zig").ByteSet;

const Node = ast.Node;

pub const Dialect = enum { perl, oniguruma };

pub const Limits = struct {
    max_pattern_len: usize = 64 * 1024,
    max_depth: u32 = 200,
    max_repeat: u32 = 1000,
    max_program_len: usize = 100_000,
    /// Backtracking steps allowed per find call.
    max_steps: u64 = 10_000_000,
    /// Backtrack-stack frames allowed.
    max_stack: usize = 4 * 1024 * 1024,
};

pub const Error = error{
    OutOfMemory,
    /// The pattern is malformed. See the Diagnostic for what and where.
    InvalidPattern,
    /// Valid in some engines but not implemented here. See the Diagnostic.
    Unsupported,
    /// A configured Limits value was exceeded.
    LimitExceeded,
};

/// Describes the first problem found. `message` is a static string.
pub const Diagnostic = struct {
    pos: usize = 0,
    message: []const u8 = "",
};

pub const Name = struct { name: []const u8, index: u32 };

pub const Parsed = struct {
    root: *const Node,
    group_count: u32,
    names: []const Name,
};

const Flags = struct {
    ignore_case: bool = false,
    /// ^ and $ are line anchors (always on for .oniguruma).
    line_anchors: bool = false,
    dot_all: bool = false,
    extended: bool = false,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    dialect: Dialect,
    limits: Limits,
    flags: Flags,
    depth: u32 = 0,
    group_count: u32 = 0,
    names: std.ArrayList(Name) = .empty,
    max_backref: u32 = 0,
    backref_pos: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, err: Error, pos: usize, msg: []const u8) Error {
        p.diag.* = .{ .pos = pos, .message = msg };
        return err;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn node(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.arena.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > p.limits.max_depth)
            return p.fail(error.LimitExceeded, p.pos, "pattern nesting too deep");
    }

    fn leave(p: *Parser) void {
        p.depth -= 1;
    }

    // alt := concat ('|' concat)*
    fn parseAlt(p: *Parser) Error!*const Node {
        try p.enter();
        defer p.leave();
        const first = try p.parseConcat();
        if (p.peek() != '|') return first;
        var alts: std.ArrayList(*const Node) = .empty;
        try alts.append(p.arena, first);
        while (p.eat('|')) try alts.append(p.arena, try p.parseConcat());
        return p.node(.{ .alt = alts.items });
    }

    fn parseConcat(p: *Parser) Error!*const Node {
        var items: std.ArrayList(*const Node) = .empty;
        while (true) {
            p.skipExtended();
            const c = p.peek() orelse break;
            if (c == '|' or c == ')') break;
            if (p.startsWith("\\Q")) {
                // \Q...\E: literal text. A following quantifier binds to the
                // last character only, as in Perl.
                p.pos += 2;
                const body_start = p.pos;
                const end = std.mem.indexOfPos(u8, p.src, body_start, "\\E") orelse p.src.len;
                p.pos = if (end == p.src.len) end else end + 2;
                if (end == body_start) continue;
                for (p.src[body_start .. end - 1]) |b| try items.append(p.arena, try p.literal(b));
                try items.append(p.arena, try p.parseQuantifiers(try p.literal(p.src[end - 1])));
                continue;
            }
            const atom = (try p.parseAtom()) orelse continue;
            try items.append(p.arena, try p.parseQuantifiers(atom));
        }
        return switch (items.items.len) {
            0 => p.node(.empty),
            1 => items.items[0],
            else => p.node(.{ .concat = items.items }),
        };
    }

    /// In extended mode, skip whitespace and `# comment` lines.
    fn skipExtended(p: *Parser) void {
        if (!p.flags.extended) return;
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
                p.pos += 1;
            } else if (c == '#') {
                while (p.peek()) |d| : (p.pos += 1) if (d == '\n') break;
            } else break;
        }
    }

    const Quant = struct { min: u32, max: ?u32, braces: bool };

    /// Parses a quantifier at the cursor, or returns null leaving the cursor
    /// untouched (a `{` that is not a valid quantifier is a literal).
    fn tryQuantifier(p: *Parser) Error!?Quant {
        const c = p.peek() orelse return null;
        switch (c) {
            '*' => {
                p.pos += 1;
                return .{ .min = 0, .max = null, .braces = false };
            },
            '+' => {
                p.pos += 1;
                return .{ .min = 1, .max = null, .braces = false };
            },
            '?' => {
                p.pos += 1;
                return .{ .min = 0, .max = 1, .braces = false };
            },
            '{' => {
                const save = p.pos;
                p.pos += 1;
                const lo = p.number();
                var hi: ?u32 = lo;
                var has_comma = false;
                if (p.eat(',')) {
                    has_comma = true;
                    hi = p.number();
                }
                const closed = p.eat('}');
                const valid = closed and (lo != null or (has_comma and hi != null and p.dialect == .oniguruma));
                if (!valid) {
                    p.pos = save;
                    return null;
                }
                const min = lo orelse 0;
                const max: ?u32 = if (has_comma) hi else min;
                if (max) |m| if (m < min)
                    return p.fail(error.InvalidPattern, save, "repeat range is reversed");
                if (min > p.limits.max_repeat or (max orelse 0) > p.limits.max_repeat)
                    return p.fail(error.LimitExceeded, save, "repeat count too large");
                return .{ .min = min, .max = max, .braces = true };
            },
            else => return null,
        }
    }

    fn number(p: *Parser) ?u32 {
        const start = p.pos;
        var v: u64 = 0;
        while (p.peek()) |c| : (p.pos += 1) {
            if (c < '0' or c > '9') break;
            v = @min(v * 10 + (c - '0'), std.math.maxInt(u32));
        }
        return if (p.pos == start) null else @intCast(v);
    }

    fn parseQuantifiers(p: *Parser, atom: *const Node) Error!*const Node {
        var cur = atom;
        var count: u32 = 0;
        while (true) {
            p.skipExtended();
            const qpos = p.pos;
            const q = (try p.tryQuantifier()) orelse break;
            if (count > 0 and p.dialect == .perl)
                return p.fail(error.InvalidPattern, qpos, "nested quantifier");
            var greed: ast.Greed = .greedy;
            if (p.eat('?')) {
                greed = .lazy;
            } else if (p.peek() == '+' and !(q.braces and p.dialect == .oniguruma)) {
                p.pos += 1;
                greed = .possessive;
            }
            try p.enter();
            cur = try p.node(.{ .repeat = .{ .sub = cur, .min = q.min, .max = q.max, .greed = greed } });
            count += 1;
        }
        p.depth -= count;
        return cur;
    }

    /// Returns null for constructs that produce no node (comments, flag changes).
    fn parseAtom(p: *Parser) Error!?*const Node {
        const c = p.src[p.pos];
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => {
                p.pos += 1;
                return try p.node(.{ .set = try p.parseClass() });
            },
            '.' => {
                p.pos += 1;
                return try p.node(.{ .any = p.flags.dot_all });
            },
            '^' => {
                p.pos += 1;
                return try p.node(.{ .assertion = if (p.flags.line_anchors) .line_start else .text_start });
            },
            '$' => {
                p.pos += 1;
                return try p.node(.{ .assertion = if (p.flags.line_anchors) .line_end else .text_end_or_final_newline });
            },
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return p.fail(error.InvalidPattern, p.pos, "quantifier has nothing to repeat"),
            '{' => {
                // A valid quantifier here has nothing to repeat; otherwise literal.
                const save = p.pos;
                if (try p.tryQuantifier()) |_|
                    return p.fail(error.InvalidPattern, save, "quantifier has nothing to repeat");
                p.pos += 1;
                return try p.literal('{');
            },
            else => {
                p.pos += 1;
                return try p.literal(c);
            },
        }
    }

    fn literal(p: *Parser, c: u8) Error!*const Node {
        if (p.flags.ignore_case and std.ascii.isAlphabetic(c)) {
            var s: ByteSet = .{};
            s.add(c);
            s.addAsciiCaseCounterparts();
            return p.node(.{ .set = s });
        }
        return p.node(.{ .byte = c });
    }

    fn parseGroup(p: *Parser) Error!?*const Node {
        const open = p.pos;
        p.pos += 1; // '('
        // Flags set inside a group end with it; `(?i)` alone is the exception
        // and keeps its effect until the enclosing group closes.
        const saved = p.flags;

        if (!p.eat('?')) {
            p.group_count += 1;
            return p.finishGroup(open, .{ .capture = p.group_count }, saved);
        }
        const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated group");
        switch (c) {
            ':' => {
                p.pos += 1;
                return p.finishGroup(open, .plain, saved);
            },
            '>' => {
                p.pos += 1;
                return p.finishGroup(open, .atomic, saved);
            },
            '=' => {
                p.pos += 1;
                return p.finishGroup(open, .{ .look = .{ .ahead = true, .negate = false } }, saved);
            },
            '!' => {
                p.pos += 1;
                return p.finishGroup(open, .{ .look = .{ .ahead = true, .negate = true } }, saved);
            },
            '#' => {
                while (p.peek()) |d| : (p.pos += 1) if (d == ')') break;
                if (!p.eat(')')) return p.fail(error.InvalidPattern, open, "unterminated comment");
                return null;
            },
            '<' => {
                if (p.startsWith("<=")) {
                    p.pos += 2;
                    return p.finishGroup(open, .{ .look = .{ .ahead = false, .negate = false } }, saved);
                }
                if (p.startsWith("<!")) {
                    p.pos += 2;
                    return p.finishGroup(open, .{ .look = .{ .ahead = false, .negate = true } }, saved);
                }
                p.pos += 1;
                return p.namedGroup(open, '>', saved);
            },
            '\'' => {
                p.pos += 1;
                return p.namedGroup(open, '\'', saved);
            },
            'P' => {
                p.pos += 1;
                if (!p.eat('<')) return p.fail(error.Unsupported, open, "(?P construct other than (?P<name>");
                return p.namedGroup(open, '>', saved);
            },
            '~' => return p.fail(error.Unsupported, open, "absent operator (?~...)"),
            '|' => return p.fail(error.Unsupported, open, "branch reset group (?|...)"),
            else => return p.parseFlagGroup(open, saved),
        }
    }

    fn namedGroup(p: *Parser, open: usize, close: u8, saved: Flags) Error!?*const Node {
        const start = p.pos;
        while (p.peek()) |d| : (p.pos += 1) {
            if (d == close) break;
            if (!(std.ascii.isAlphanumeric(d) or d == '_'))
                return p.fail(error.InvalidPattern, p.pos, "invalid character in group name");
        }
        if (p.pos == start or !p.eat(close))
            return p.fail(error.InvalidPattern, open, "malformed group name");
        const name = p.src[start .. p.pos - 1];
        p.group_count += 1;
        try p.names.append(p.arena, .{ .name = name, .index = p.group_count });
        return p.finishGroup(open, .{ .capture = p.group_count }, saved);
    }

    /// (?flags) or (?flags:subpattern). Flags: i m s x, `-` turns the rest off.
    fn parseFlagGroup(p: *Parser, open: usize, saved: Flags) Error!?*const Node {
        var on = true;
        var f = p.flags;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated group");
            p.pos += 1;
            switch (c) {
                '-' => on = false,
                'i' => f.ignore_case = on,
                'x' => f.extended = on,
                // m and s swap meaning between the dialects.
                'm' => switch (p.dialect) {
                    .perl => f.line_anchors = on,
                    .oniguruma => f.dot_all = on,
                },
                's' => switch (p.dialect) {
                    .perl => f.dot_all = on,
                    .oniguruma => return p.fail(error.InvalidPattern, p.pos - 1, "unknown flag 's' in Oniguruma syntax"),
                },
                ')' => {
                    p.flags = f;
                    return null;
                },
                ':' => {
                    p.flags = f;
                    return p.finishGroup(open, .plain, saved);
                },
                else => return p.fail(error.Unsupported, p.pos - 1, "unsupported inline flag"),
            }
        }
    }

    const GroupKind = union(enum) {
        plain,
        capture: u32,
        atomic,
        look: struct { ahead: bool, negate: bool },
    };

    fn finishGroup(p: *Parser, open: usize, kind: GroupKind, saved: Flags) Error!*const Node {
        const sub = try p.parseAlt();
        p.flags = saved;
        if (!p.eat(')')) return p.fail(error.InvalidPattern, open, "unterminated group");
        return switch (kind) {
            .plain => p.node(.{ .group = .{ .sub = sub, .index = null } }),
            .capture => |i| p.node(.{ .group = .{ .sub = sub, .index = i } }),
            .atomic => p.node(.{ .atomic = sub }),
            .look => |l| p.node(.{ .look = .{ .sub = sub, .ahead = l.ahead, .negate = l.negate } }),
        };
    }

    // ---- escapes -------------------------------------------------------

    fn classEscape(p: *Parser, c: u8) ?ByteSet {
        var s: ByteSet = .{};
        switch (std.ascii.toLower(c)) {
            'd' => s.addRange('0', '9'),
            'w' => {
                s.addRange('a', 'z');
                s.addRange('A', 'Z');
                s.addRange('0', '9');
                s.add('_');
            },
            's' => {
                s.add(' ');
                s.addRange('\t', '\r');
            },
            'h' => switch (p.dialect) {
                .oniguruma => {
                    s.addRange('0', '9');
                    s.addRange('a', 'f');
                    s.addRange('A', 'F');
                },
                .perl => {
                    s.add(' ');
                    s.add('\t');
                },
            },
            else => return null,
        }
        if (std.ascii.isUpper(c)) s.invert();
        return s;
    }

    /// A single-byte escape (after the backslash): \n \t \xHH \0oo and escaped
    /// punctuation. The cursor is just past the escape letter.
    fn byteEscape(p: *Parser, c: u8, at: usize) Error!?u8 {
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'f' => return 0x0c,
            'v' => return 0x0b,
            'a' => return 0x07,
            'e' => return 0x1b,
            '0' => {
                var v: u32 = 0;
                var n: u8 = 0;
                while (n < 2) : (n += 1) {
                    const d = p.peek() orelse break;
                    if (d < '0' or d > '7') break;
                    v = v * 8 + (d - '0');
                    p.pos += 1;
                }
                return @intCast(v);
            },
            'x' => {
                var digits: []const u8 = undefined;
                if (p.eat('{')) {
                    const s = p.pos;
                    while (p.peek()) |d| : (p.pos += 1) if (d == '}') break;
                    digits = p.src[s..p.pos];
                    if (!p.eat('}')) return p.fail(error.InvalidPattern, at, "unterminated \\x{...}");
                } else {
                    const s = p.pos;
                    while (p.pos - s < 2 and p.pos < p.src.len and std.ascii.isHex(p.src[p.pos])) p.pos += 1;
                    digits = p.src[s..p.pos];
                }
                const v = std.fmt.parseInt(u32, digits, 16) catch
                    return p.fail(error.InvalidPattern, at, "invalid hexadecimal escape");
                if (v > 0xff) return p.fail(error.Unsupported, at, "code point above 0xFF (Unicode matching not implemented)");
                return @intCast(v);
            },
            else => {
                if (std.ascii.isAlphanumeric(c)) return null;
                return c;
            },
        }
    }

    fn parseEscape(p: *Parser) Error!?*const Node {
        const at = p.pos;
        p.pos += 1; // backslash
        const c = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        p.pos += 1;

        if (p.classEscape(c)) |s| return try p.node(.{ .set = s });
        switch (c) {
            'b' => return try p.node(.{ .assertion = .word_boundary }),
            'B' => return try p.node(.{ .assertion = .not_word_boundary }),
            'A' => return try p.node(.{ .assertion = .text_start }),
            'z' => return try p.node(.{ .assertion = .text_end }),
            'Z' => return try p.node(.{ .assertion = .text_end_or_final_newline }),
            'G' => return try p.node(.{ .assertion = .search_start }),
            'p', 'P' => return p.fail(error.Unsupported, at, "Unicode property \\p{...}"),
            'R', 'X', 'K', 'C' => return p.fail(error.Unsupported, at, "unsupported escape"),
            'E' => return null,
            'k' => {
                const open = p.peek() orelse return p.fail(error.InvalidPattern, at, "malformed \\k");
                const close: u8 = switch (open) {
                    '<' => '>',
                    '\'' => '\'',
                    else => return p.fail(error.InvalidPattern, at, "malformed \\k"),
                };
                p.pos += 1;
                const s = p.pos;
                while (p.peek()) |d| : (p.pos += 1) if (d == close) break;
                const name = p.src[s..p.pos];
                if (!p.eat(close)) return p.fail(error.InvalidPattern, at, "malformed \\k");
                for (p.names.items) |n| if (std.mem.eql(u8, n.name, name))
                    return try p.node(.{ .backref = .{ .index = n.index, .ignore_case = p.flags.ignore_case } });
                return p.fail(error.InvalidPattern, at, "reference to unknown group name");
            },
            '1'...'9' => {
                p.pos -= 1;
                const n = p.number().?;
                if (n > p.max_backref) {
                    p.max_backref = n;
                    p.backref_pos = at;
                }
                return try p.node(.{ .backref = .{ .index = n, .ignore_case = p.flags.ignore_case } });
            },
            else => {},
        }
        if (try p.byteEscape(c, at)) |b| return try p.literal(b);
        return p.fail(error.InvalidPattern, at, "unknown escape sequence");
    }

    // ---- character classes ----------------------------------------------

    /// Cursor is just past '['. Consumes through the closing ']'.
    fn parseClass(p: *Parser) Error!ByteSet {
        const open = p.pos - 1;
        try p.enter();
        defer p.leave();
        var set: ByteSet = .{};
        const negate = p.eat('^');
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated character class");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (c == '[') {
                if (p.startsWith("[:")) {
                    if (try p.posixClass()) |s| {
                        set.unionWith(s);
                        continue;
                    }
                }
                p.pos += 1;
                set.unionWith(try p.parseClass());
                continue;
            }
            if (c == '&' and p.startsWith("&&"))
                return p.fail(error.Unsupported, p.pos, "class intersection &&");

            const lo = (try p.classItem(&set)) orelse continue;
            // Range?
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                const save = p.pos;
                p.pos += 1;
                const nxt = p.peek().?;
                if (nxt == '[') {
                    p.pos = save; // '-' followed by a nested class: literal '-'
                    set.add(lo);
                    continue;
                }
                var scratch: ByteSet = .{};
                const hi = (try p.classItem(&scratch)) orelse {
                    // Range to a class escape like [a-\d]: treat '-' literally.
                    set.add(lo);
                    set.add('-');
                    set.unionWith(scratch);
                    continue;
                };
                if (hi < lo) return p.fail(error.InvalidPattern, save, "character class range is reversed");
                set.addRange(lo, hi);
            } else set.add(lo);
        }
        if (p.flags.ignore_case) set.addAsciiCaseCounterparts();
        if (negate) set.invert();
        return set;
    }

    /// One element inside a class. Returns the byte for a single-byte item, or
    /// null after adding a multi-byte item (\d, \w, ...) straight into `set`.
    fn classItem(p: *Parser, set: *ByteSet) Error!?u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        if (c != '\\') return c;
        const at = p.pos - 1;
        const e = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        p.pos += 1;
        if (p.classEscape(e)) |s| {
            set.unionWith(s);
            return null;
        }
        if (e == 'b') return 0x08; // \b inside a class is backspace
        if (e == 'p' or e == 'P') return p.fail(error.Unsupported, at, "Unicode property \\p{...}");
        if (try p.byteEscape(e, at)) |b| return b;
        return p.fail(error.InvalidPattern, at, "unknown escape sequence in class");
    }

    /// At "[:". Returns the set for [:name:] / [:^name:], or null (cursor
    /// unmoved) when this is not a POSIX class, so the caller treats '[' as a
    /// nested class.
    fn posixClass(p: *Parser) Error!?ByteSet {
        const start = p.pos;
        const end = std.mem.indexOfPos(u8, p.src, start + 2, ":]") orelse return null;
        var name = p.src[start + 2 .. end];
        const neg = name.len > 0 and name[0] == '^';
        if (neg) name = name[1..];
        var s: ByteSet = .{};
        if (std.mem.eql(u8, name, "alpha")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
        } else if (std.mem.eql(u8, name, "digit")) {
            s.addRange('0', '9');
        } else if (std.mem.eql(u8, name, "alnum")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
            s.addRange('0', '9');
        } else if (std.mem.eql(u8, name, "upper")) {
            s.addRange('A', 'Z');
        } else if (std.mem.eql(u8, name, "lower")) {
            s.addRange('a', 'z');
        } else if (std.mem.eql(u8, name, "space")) {
            s.add(' ');
            s.addRange('\t', '\r');
        } else if (std.mem.eql(u8, name, "blank")) {
            s.add(' ');
            s.add('\t');
        } else if (std.mem.eql(u8, name, "punct")) {
            s.addRange('!', '/');
            s.addRange(':', '@');
            s.addRange('[', '`');
            s.addRange('{', '~');
        } else if (std.mem.eql(u8, name, "xdigit")) {
            s.addRange('0', '9');
            s.addRange('a', 'f');
            s.addRange('A', 'F');
        } else if (std.mem.eql(u8, name, "word")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
            s.addRange('0', '9');
            s.add('_');
        } else if (std.mem.eql(u8, name, "cntrl")) {
            s.addRange(0, 31);
            s.add(127);
        } else if (std.mem.eql(u8, name, "print")) {
            s.addRange(32, 126);
        } else if (std.mem.eql(u8, name, "graph")) {
            s.addRange(33, 126);
        } else if (std.mem.eql(u8, name, "ascii")) {
            s.addRange(0, 127);
        } else return p.fail(error.InvalidPattern, start, "unknown POSIX class name");
        p.pos = end + 2;
        if (neg) s.invert();
        return s;
    }
};

pub fn parse(
    arena: std.mem.Allocator,
    pattern: []const u8,
    dialect: Dialect,
    ignore_case: bool,
    limits: Limits,
    diag: *Diagnostic,
) Error!Parsed {
    diag.* = .{};
    if (pattern.len > limits.max_pattern_len) {
        diag.* = .{ .pos = 0, .message = "pattern too long" };
        return error.LimitExceeded;
    }
    var p: Parser = .{
        .arena = arena,
        .src = pattern,
        .dialect = dialect,
        .limits = limits,
        .flags = .{ .ignore_case = ignore_case, .line_anchors = dialect == .oniguruma },
        .diag = diag,
    };
    const root = try p.parseAlt();
    if (p.pos < pattern.len) return p.fail(error.InvalidPattern, p.pos, "unmatched ')'");
    if (p.max_backref > p.group_count)
        return p.fail(error.InvalidPattern, p.backref_pos, "reference to a group that does not exist");
    return .{ .root = root, .group_count = p.group_count, .names = p.names.items };
}

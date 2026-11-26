// SPDX-License-Identifier: LGPL-2.0-or-later
//! Parser for the Perl-style syntax family. Five dialects share one parser:
//!
//!   * .perl       — Perl/PCRE flavour: `^`/`$` match at text boundaries unless
//!                   (?m); (?s) lets `.` match '\n'; `\h` is horizontal space.
//!   * .oniguruma  — Oniguruma "Ruby" flavour as used by Sublime syntaxes:
//!                   `^`/`$` are always line anchors; (?m) lets `.` match '\n';
//!                   `\h` is a hex digit; `{,n}` is accepted.
//!   * .posix_ere  — POSIX extended expressions with the GNU `\w \W \s \S \b \B`
//!                   and back-references: `.` matches '\n', `^`/`$` are text
//!                   anchors, a quantifier may follow a quantifier (`a*?` is
//!                   `(a*)?`, never lazy), `(?` has no meaning, a backslash in
//!                   a bracket expression is a literal, and any other escape
//!                   stands for the character itself. Matching is still
//!                   leftmost-first, so the span of a match may differ from a
//!                   leftmost-longest engine; whether a match exists does not.
//!   * .rust       — the syntax of Rust's `regex` crate (as used by ripgrep):
//!                   Perl-like groups, flags (i m s x U u) and escapes, `$` is
//!                   the end of the text, and set operations in classes
//!                   (`[a-z&&[^aeiou]]`, `--`, `~~`). No back-references,
//!                   look-around, atomic groups, possessive quantifiers, `\Z`
//!                   or `\G`: those are errors, so every pattern runs on the
//!                   linear-time engines.
//!   * .posix_bre  — POSIX basic expressions with the GNU extensions: `\( \)`
//!                   groups, `\{m,n\}` intervals, `\+ \? \|`, `*` literal at the
//!                   start of an expression or group, `^` and `$` anchors only
//!                   where POSIX allows (otherwise literal), and the same GNU
//!                   escapes as the ERE (`\w \s \b \< \> \` \'` and
//!                   back-references).
//!
//! By default matching is byte-based: a pattern byte >= 0x80 is a literal byte,
//! and `.` and negated classes consume one byte. With `utf8` set the pattern
//! must be valid UTF-8 and literals, `.`, classes, negation and `\x{...}`
//! work on Unicode scalar values (docs/decisions/0001-utf8-matching.md).
//! In that mode \p{..}, \w, \d, \s, the common POSIX classes and (?i) use
//! the Unicode tables (unless built with -Dunicode_tables=false); \p{..} without `utf8` is reported as unsupported rather
//! than ignored (SPEC §5).

const std = @import("std");
const ast = @import("ast.zig");
const ByteSet = @import("byteset.zig").ByteSet;
const ucp = @import("utf8.zig");
const unicode = @import("unicode.zig");

const Node = ast.Node;

pub const Dialect = enum { perl, oniguruma, posix_ere, posix_bre, rust };

pub const Limits = struct {
    max_pattern_len: usize = 64 * 1024,
    max_depth: u32 = 200,
    max_repeat: u32 = 1000,
    max_program_len: usize = 100_000,
    /// Bytes of capture slots the Pike VM may reserve in each Searcher. The
    /// need grows with (instructions that can hold a thread) x (groups).
    /// A pattern that needs more is refused at compile time.
    max_capture_bytes: usize = 64 * 1024 * 1024,
    /// Backtracking steps allowed per find call.
    max_steps: u64 = 10_000_000,
    /// Backtrack-stack frames allowed.
    max_stack: usize = 4 * 1024 * 1024,
    /// Bytes of states and transitions the lazy DFA may cache per direction.
    /// When full the cache is cleared; if that keeps happening the search
    /// falls back to the Pike VM.
    max_dfa_cache: usize = 2 * 1024 * 1024,
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
    /// For a set of patterns: which one the problem is in.
    pattern: usize = 0,
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
    /// (?U): `*` is lazy and `*?` greedy (Rust dialect).
    swap_greed: bool = false,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    dialect: Dialect,
    utf8: bool,
    limits: Limits,
    flags: Flags,
    depth: u32 = 0,
    group_count: u32 = 0,
    names: std.ArrayList(Name) = .empty,
    max_backref: u32 = 0,
    backref_pos: usize = 0,
    diag: *Diagnostic,

    fn posix(p: *const Parser) bool {
        return p.dialect == .posix_ere or p.dialect == .posix_bre;
    }

    /// The alternation operator: `|`, or `\|` in a basic expression.
    fn atAltBar(p: *Parser) bool {
        return if (p.dialect == .posix_bre) p.startsWith("\\|") else p.peek() == '|';
    }

    fn eatAltBar(p: *Parser) bool {
        if (!p.atAltBar()) return false;
        p.pos += if (p.dialect == .posix_bre) 2 else 1;
        return true;
    }

    /// The end of a group: `)`, or `\)` in a basic expression.
    fn atGroupClose(p: *Parser) bool {
        return if (p.dialect == .posix_bre) p.startsWith("\\)") else p.peek() == ')';
    }

    fn eatGroupClose(p: *Parser) bool {
        if (!p.atGroupClose()) return false;
        p.pos += if (p.dialect == .posix_bre) 2 else 1;
        return true;
    }

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

    // ---- literals and classes -----------------------------------------------

    /// A character class under construction. In byte mode `bytes` holds any
    /// byte. In utf8 mode `bytes` holds only ASCII and `ranges` the scalar
    /// values >= 0x80.
    const Class = struct {
        bytes: ByteSet = .{},
        ranges: std.ArrayList(ucp.CpRange) = .empty,
    };

    /// The scalar value starting at `i` and its length. The pattern was
    /// validated as UTF-8 up front, so decoding cannot fail.
    fn decodeAt(p: *Parser, i: usize) struct { cp: u21, len: u3 } {
        const len = std.unicode.utf8ByteSequenceLength(p.src[i]) catch unreachable;
        const cp = std.unicode.utf8Decode(p.src[i..][0..len]) catch unreachable;
        return .{ .cp = cp, .len = len };
    }

    /// A literal scalar value. Outside utf8 mode `cp` is always a byte.
    fn literalCp(p: *Parser, cp: u21) Error!*const Node {
        if (p.flags.ignore_case and p.utf8 and unicode.enabled and unicode.orbit(cp) != null) {
            // Case-insensitive: the character and its case variants.
            var cls: Class = .{};
            try p.classAddCp(&cls, cp);
            try p.classFoldCase(&cls);
            return p.classNode(&cls);
        }
        if (!p.utf8 or cp < 0x80) return p.literal(@intCast(cp));
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        const items = try p.arena.alloc(*const Node, n);
        for (items, buf[0..n]) |*it, b| it.* = try p.node(.{ .byte = b });
        // A concat is a single atom, so a following quantifier repeats the
        // whole character.
        return p.node(.{ .concat = items });
    }

    /// The literal character at `i` (one byte, or one scalar in utf8 mode).
    fn literalChar(p: *Parser, i: usize) Error!struct { node: *const Node, len: usize } {
        const c = p.src[i];
        if (p.utf8 and c >= 0x80) {
            const d = p.decodeAt(i);
            return .{ .node = try p.literalCp(d.cp), .len = d.len };
        }
        return .{ .node = if (p.utf8) try p.literalCp(c) else try p.literal(c), .len = 1 };
    }

    fn classAddRange(p: *Parser, cls: *Class, lo: u21, hi: u21) Error!void {
        if (!p.utf8) {
            cls.bytes.addRange(@intCast(lo), @intCast(hi));
            return;
        }
        if (lo < 0x80) cls.bytes.addRange(@intCast(lo), @intCast(@min(hi, 0x7f)));
        if (hi >= 0x80) try cls.ranges.append(p.arena, .{ .lo = @max(lo, 0x80), .hi = hi });
    }

    fn classAddCp(p: *Parser, cls: *Class, cp: u21) Error!void {
        try p.classAddRange(cls, cp, cp);
    }

    fn classUnion(p: *Parser, cls: *Class, other: Class) Error!void {
        cls.bytes.unionWith(other.bytes);
        try cls.ranges.appendSlice(p.arena, other.ranges.items);
    }

    /// Complement. In utf8 mode this is over the scalar values, so `[^a]`
    /// contains every non-ASCII character.
    fn classInvert(p: *Parser, cls: *Class) Error!void {
        cls.bytes.invert();
        if (!p.utf8) return;
        var ascii: ByteSet = .{};
        ascii.addRange(0, 0x7f);
        cls.bytes.intersectWith(ascii);
        try ucp.normalize(p.arena, &cls.ranges);
        try ucp.complementFrom(p.arena, &cls.ranges, 0x80);
    }

    /// A class from a set of ASCII bytes (all the built-in classes are ASCII).
    fn classFromSet(p: *Parser, s: ByteSet, negate: bool) Error!Class {
        var cls: Class = .{ .bytes = s };
        if (negate) try p.classInvert(&cls);
        return cls;
    }

    /// Adds every scalar value in `table`, or every one outside it.
    fn classAddTable(p: *Parser, cls: *Class, table: unicode.Table, negate: bool) Error!void {
        var list: std.ArrayList(ucp.CpRange) = .empty;
        try unicode.appendRanges(p.arena, &list, table);
        if (negate) try ucp.complementFrom(p.arena, &list, 0);
        for (list.items) |r| try p.classAddRange(cls, r.lo, r.hi);
    }

    /// `\p{Name}`, `\pL`, `\p{^Name}` and the `\P` forms; the cursor is just
    /// past the `p` or `P`.
    fn propertyClass(p: *Parser, negated: bool, at: usize) Error!Class {
        if (!p.utf8) return p.fail(error.Unsupported, at, "Unicode property \\p{...} needs utf8 mode");
        if (!unicode.enabled) return p.fail(error.Unsupported, at, "Unicode property \\p{...}: built without -Dunicode_tables");
        var neg = negated;
        var name: []const u8 = undefined;
        if (p.eat('{')) {
            const close = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse
                return p.fail(error.InvalidPattern, at, "unterminated \\p{...}");
            name = p.src[p.pos..close];
            p.pos = close + 1;
            if (name.len > 0 and name[0] == '^') {
                neg = !neg;
                name = name[1..];
            }
        } else {
            if (p.pos >= p.src.len) return p.fail(error.InvalidPattern, at, "\\p needs a property name");
            name = p.src[p.pos..][0..1];
            p.pos += 1;
        }
        const table = unicode.lookupProperty(name) orelse
            return p.fail(error.InvalidPattern, at, "unknown or unsupported Unicode property");
        var cls: Class = .{};
        try p.classAddTable(&cls, table, neg);
        return cls;
    }

    /// Adds the case variants of every member of `cls`. In utf8 mode with the
    /// Unicode tables this is simple case folding (so `k` brings in KELVIN
    /// SIGN); otherwise only ASCII letters are folded. Full folding, where one
    /// character folds to several (ß to ss), is not supported.
    fn classFoldCase(p: *Parser, cls: *Class) Error!void {
        if (!p.utf8 or !unicode.enabled) {
            cls.bytes.addAsciiCaseCounterparts();
            return;
        }
        try ucp.normalize(p.arena, &cls.ranges);
        // Collect first: adding while scanning would unsort `ranges`.
        var additions: std.ArrayList(u21) = .empty;
        for (0..unicode.orbitCount()) |r| {
            const row = unicode.orbitRow(r);
            var any = false;
            for (row) |cp| {
                if (cp < 0x80) any = any or cls.bytes.has(@intCast(cp)) else any = any or ucp.containsRange(cls.ranges.items, cp);
            }
            if (any) try additions.appendSlice(p.arena, row);
        }
        for (additions.items) |cp| try p.classAddCp(cls, cp);
    }

    fn classNode(p: *Parser, cls: *Class) Error!*const Node {
        if (!p.utf8) return p.node(.{ .set = cls.bytes });
        try ucp.normalize(p.arena, &cls.ranges);
        // A class with no non-ASCII member stays a plain byte set.
        if (cls.ranges.items.len == 0) return p.node(.{ .set = cls.bytes });
        var all: std.ArrayList(ucp.CpRange) = .empty;
        var c: u8 = 0;
        while (c < 0x80) {
            if (!cls.bytes.has(c)) {
                c += 1;
                continue;
            }
            const start = c;
            while (c < 0x80 and cls.bytes.has(c)) c += 1;
            try all.append(p.arena, .{ .lo = start, .hi = c - 1 });
        }
        try all.appendSlice(p.arena, cls.ranges.items);
        return p.node(.{ .cp_set = all.items });
    }

    // alt := concat ('|' concat)*
    fn parseAlt(p: *Parser) Error!*const Node {
        try p.enter();
        defer p.leave();
        const first = try p.parseConcat();
        if (!p.atAltBar()) return first;
        var alts: std.ArrayList(*const Node) = .empty;
        try alts.append(p.arena, first);
        while (p.eatAltBar()) try alts.append(p.arena, try p.parseConcat());
        return p.node(.{ .alt = alts.items });
    }

    fn parseConcat(p: *Parser) Error!*const Node {
        var items: std.ArrayList(*const Node) = .empty;
        while (true) {
            p.skipExtended();
            const c = p.peek() orelse break;
            _ = c;
            if (p.atAltBar() or p.atGroupClose()) break;
            if (p.dialect != .posix_bre and p.dialect != .rust and p.startsWith("\\Q")) {
                // \Q...\E: literal text. A following quantifier binds to the
                // last character only, as in Perl.
                p.pos += 2;
                const body_start = p.pos;
                const end = std.mem.indexOfPos(u8, p.src, body_start, "\\E") orelse p.src.len;
                p.pos = if (end == p.src.len) end else end + 2;
                if (end == body_start) continue;
                var i = body_start;
                while (i < end) {
                    const r = try p.literalChar(i);
                    i += r.len;
                    try items.append(p.arena, if (i == end) try p.parseQuantifiers(r.node) else r.node);
                }
                continue;
            }
            const atom = (try p.parseAtom(items.items.len == 0)) orelse continue;
            // In a basic expression an anchor cannot be repeated: a `*` after
            // `^` is a literal star.
            if (p.dialect == .posix_bre and atom.* == .assertion) {
                try items.append(p.arena, atom);
                continue;
            }
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
        if (p.dialect == .posix_bre) return p.tryBreQuantifier();
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

    /// `*`, `\+`, `\?` and `\{m,n\}` in a basic expression.
    fn tryBreQuantifier(p: *Parser) Error!?Quant {
        if (p.eat('*')) return .{ .min = 0, .max = null, .braces = false };
        if (p.startsWith("\\+")) {
            p.pos += 2;
            return .{ .min = 1, .max = null, .braces = false };
        }
        if (p.startsWith("\\?")) {
            p.pos += 2;
            return .{ .min = 0, .max = 1, .braces = false };
        }
        if (!p.startsWith("\\{")) return null;
        const save = p.pos;
        p.pos += 2;
        const lo = p.number();
        var hi: ?u32 = lo;
        var has_comma = false;
        if (p.eat(',')) {
            has_comma = true;
            hi = p.number();
        }
        if (!p.startsWith("\\}")) return p.fail(error.InvalidPattern, save, "unterminated or malformed \\{...\\}");
        p.pos += 2;
        if (lo == null and !(has_comma and hi != null))
            return p.fail(error.InvalidPattern, save, "malformed \\{...\\}");
        const min = lo orelse 0;
        const max: ?u32 = if (has_comma) hi else min;
        if (max) |m| if (m < min) return p.fail(error.InvalidPattern, save, "repeat range is reversed");
        if (min > p.limits.max_repeat or (max orelse 0) > p.limits.max_repeat)
            return p.fail(error.LimitExceeded, save, "repeat count too large");
        return .{ .min = min, .max = max, .braces = true };
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
            if (count > 0 and (p.dialect == .perl or p.dialect == .rust))
                return p.fail(error.InvalidPattern, qpos, "nested quantifier");
            var greed: ast.Greed = .greedy;
            if (p.posix()) {
                // No lazy or possessive forms: a following `?` or `+` is
                // another quantifier, read on the next turn of the loop.
            } else if (p.eat('?')) {
                greed = .lazy;
            } else if (p.peek() == '+' and !(q.braces and p.dialect == .oniguruma) and p.dialect != .rust) {
                p.pos += 1;
                greed = .possessive;
            }
            if (p.flags.swap_greed) greed = switch (greed) {
                .greedy => .lazy,
                .lazy => .greedy,
                .possessive => .possessive,
            };
            try p.enter();
            cur = try p.node(.{ .repeat = .{ .sub = cur, .min = q.min, .max = q.max, .greed = greed } });
            count += 1;
        }
        p.depth -= count;
        return cur;
    }

    /// Returns null for constructs that produce no node (comments, flag changes).
    fn parseAtom(p: *Parser, at_start: bool) Error!?*const Node {
        const c = p.src[p.pos];
        if (p.dialect == .posix_bre) switch (c) {
            // A star with nothing to repeat is an ordinary character.
            '*' => {
                p.pos += 1;
                return try p.literal('*');
            },
            // An anchor only at the start of an expression or group, and `$`
            // only at the end of one; elsewhere they are ordinary.
            '^' => {
                p.pos += 1;
                return if (at_start) try p.node(.{ .assertion = .text_start }) else try p.literal('^');
            },
            '$' => {
                p.pos += 1;
                if (p.pos == p.src.len or p.startsWith("\\)") or p.startsWith("\\|"))
                    return try p.node(.{ .assertion = .text_end });
                return try p.literal('$');
            },
            '(', ')', '|', '+', '?', '{', '}' => {
                p.pos += 1;
                return try p.literal(c);
            },
            else => {},
        };
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => {
                p.pos += 1;
                var cls = try p.parseClass();
                return try p.classNode(&cls);
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
                // POSIX `$` is the end of the text; Perl's also matches before a final newline.
                return try p.node(.{ .assertion = if (p.flags.line_anchors) .line_end else if (p.posix() or p.dialect == .rust) .text_end else .text_end_or_final_newline });
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
                const r = try p.literalChar(p.pos);
                p.pos += r.len;
                return r.node;
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

        if (p.dialect == .posix_ere or !p.eat('?')) {
            p.group_count += 1;
            return p.finishGroup(open, .{ .capture = p.group_count }, saved);
        }
        const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated group");
        if (p.dialect == .rust) switch (c) {
            '>', '=', '!', '#', '\'' => return p.fail(error.Unsupported, open, "group construct not supported by the Rust dialect (look-around, atomic group, comment)"),
            '<' => if (p.startsWith("<=") or p.startsWith("<!"))
                return p.fail(error.Unsupported, open, "look-behind is not supported by the Rust dialect"),
            else => {},
        };
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
                'U' => if (p.dialect == .rust) {
                    f.swap_greed = on;
                } else return p.fail(error.Unsupported, p.pos - 1, "unsupported inline flag"),
                'u' => if (p.dialect != .rust) {
                    return p.fail(error.Unsupported, p.pos - 1, "unsupported inline flag");
                } else if (!on) {
                    return p.fail(error.Unsupported, p.pos - 1, "(?-u): Unicode mode is chosen with Options.utf8, not per group");
                },
                // m and s swap meaning between the dialects.
                'm' => switch (p.dialect) {
                    .perl, .posix_ere, .posix_bre, .rust => f.line_anchors = on,
                    .oniguruma => f.dot_all = on,
                },
                's' => switch (p.dialect) {
                    .perl, .posix_ere, .posix_bre, .rust => f.dot_all = on,
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
        if (!p.eatGroupClose()) return p.fail(error.InvalidPattern, open, "unterminated group");
        return switch (kind) {
            .plain => p.node(.{ .group = .{ .sub = sub, .index = null } }),
            .capture => |i| p.node(.{ .group = .{ .sub = sub, .index = i } }),
            .atomic => p.node(.{ .atomic = sub }),
            .look => |l| p.node(.{ .look = .{ .sub = sub, .ahead = l.ahead, .negate = l.negate } }),
        };
    }

    // ---- escapes -------------------------------------------------------

    /// The class for \d \w \s \h and their negations, or null for any other letter.
    fn classEscape(p: *Parser, c: u8) Error!?Class {
        var s: ByteSet = .{};
        if (p.utf8 and unicode.enabled) {
            // Unicode-aware in utf8 mode (UTS #18, Annex C).
            const table: ?unicode.Table = switch (std.ascii.toLower(c)) {
                'd' => unicode.digit,
                'w' => unicode.word,
                's' => unicode.space,
                else => null,
            };
            if (table) |tbl| {
                var cls: Class = .{};
                try p.classAddTable(&cls, tbl, std.ascii.isUpper(c));
                return cls;
            }
        }
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
                .rust => return null, // no \h in the Rust syntax
                .perl, .posix_ere, .posix_bre => {
                    s.add(' ');
                    s.add('\t');
                },
            },
            else => return null,
        }
        return try p.classFromSet(s, std.ascii.isUpper(c));
    }

    /// A single-character escape (after the backslash): \n \t \xHH \x{H..} \0oo and
    /// escaped punctuation. A byte in byte mode, a scalar value in utf8 mode. The cursor is just past the escape letter.
    fn scalarFromHex(p: *Parser, digits: []const u8, at: usize) Error!u21 {
        const v = std.fmt.parseInt(u32, digits, 16) catch
            return p.fail(error.InvalidPattern, at, "invalid hexadecimal escape");
        if (p.utf8) {
            if (v > ucp.max_scalar) return p.fail(error.InvalidPattern, at, "code point above U+10FFFF");
            if (v >= 0xD800 and v <= 0xDFFF) return p.fail(error.InvalidPattern, at, "surrogate code point");
        } else if (v > 0xff) {
            return p.fail(error.Unsupported, at, "code point above 0xFF (enable utf8 for Unicode matching)");
        }
        return @intCast(v);
    }

    fn byteEscape(p: *Parser, c: u8, at: usize) Error!?u21 {
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
                return try p.scalarFromHex(digits, at);
            },
            // \u7F7F, \u{7F7F} and \U0000007F: Rust only.
            'u', 'U' => {
                if (p.dialect != .rust) return null;
                var digits: []const u8 = undefined;
                if (p.eat('{')) {
                    const s = p.pos;
                    while (p.peek()) |d| : (p.pos += 1) if (d == '}') break;
                    digits = p.src[s..p.pos];
                    if (!p.eat('}')) return p.fail(error.InvalidPattern, at, "unterminated \\u{...}");
                } else {
                    const want: usize = if (c == 'u') 4 else 8;
                    const s = p.pos;
                    while (p.pos - s < want and p.pos < p.src.len and std.ascii.isHex(p.src[p.pos])) p.pos += 1;
                    if (p.pos - s != want) return p.fail(error.InvalidPattern, at, "\\u needs exactly 4 hex digits, \\U exactly 8");
                    digits = p.src[s..p.pos];
                }
                return try p.scalarFromHex(digits, at);
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

        if (p.dialect == .rust) switch (c) {
            '1'...'9', 'k' => return p.fail(error.Unsupported, at, "back-references are not supported by the Rust dialect"),
            'Z', 'G', 'R', 'X', 'K', 'C', 'Q', 'E' => return p.fail(error.InvalidPattern, at, "unrecognized escape sequence in the Rust dialect"),
            else => {},
        };
        // An escaped non-ASCII character stands for itself in every dialect.
        if (p.utf8 and c >= 0x80) {
            p.pos -= 1;
            const d = p.decodeAt(p.pos);
            p.pos += d.len;
            return try p.literalCp(d.cp);
        }
        if (p.posix()) return p.posixEscape(c, at);
        if (try p.classEscape(c)) |found| {
            var cls = found;
            return try p.classNode(&cls);
        }
        switch (c) {
            'b' => return try p.node(.{ .assertion = .word_boundary }),
            'B' => return try p.node(.{ .assertion = .not_word_boundary }),
            'A' => return try p.node(.{ .assertion = .text_start }),
            'z' => return try p.node(.{ .assertion = .text_end }),
            'Z' => return try p.node(.{ .assertion = .text_end_or_final_newline }),
            'G' => return try p.node(.{ .assertion = .search_start }),
            'p', 'P' => {
                var cls = try p.propertyClass(c == 'P', at);
                if (p.flags.ignore_case) try p.classFoldCase(&cls);
                return try p.classNode(&cls);
            },
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
        if (try p.byteEscape(c, at)) |cp| return try p.literalCp(cp);
        return p.fail(error.InvalidPattern, at, "unknown escape sequence");
    }

    /// An escape in POSIX ERE (GNU flavour): word and space classes, word
    /// boundaries and back-references; anything else is the character itself.
    fn posixEscape(p: *Parser, c: u8, at: usize) Error!*const Node {
        switch (c) {
            'w', 'W', 's', 'S' => {
                var cls = (try p.classEscape(c)).?;
                return try p.classNode(&cls);
            },
            'b' => return try p.node(.{ .assertion = .word_boundary }),
            'B' => return try p.node(.{ .assertion = .not_word_boundary }),
            '<' => return try p.node(.{ .assertion = .word_start }),
            '>' => return try p.node(.{ .assertion = .word_end }),
            '`' => return try p.node(.{ .assertion = .text_start }),
            '\'' => return try p.node(.{ .assertion = .text_end }),
            '(' => if (p.dialect == .posix_bre) {
                p.group_count += 1;
                return p.finishGroup(at, .{ .capture = p.group_count }, p.flags);
            } else return try p.literal(c),
            '{' => if (p.dialect == .posix_bre) {
                return p.fail(error.InvalidPattern, at, "interval has nothing to repeat");
            } else return try p.literal(c),
            '1'...'9' => {
                const n: u32 = c - '0';
                if (n > p.max_backref) {
                    p.max_backref = n;
                    p.backref_pos = at;
                }
                return try p.node(.{ .backref = .{ .index = n, .ignore_case = p.flags.ignore_case } });
            },
            else => return try p.literal(c),
        }
    }

    // ---- character classes ----------------------------------------------

    const SetOp = enum { intersection, difference, symmetric };

    /// A set operator in a Rust-dialect class: `&&`, `--` or `~~`.
    fn setOpAhead(p: *Parser) ?SetOp {
        if (p.dialect != .rust) return null;
        if (p.startsWith("&&")) return .intersection;
        if (p.startsWith("--")) return .difference;
        if (p.startsWith("~~")) return .symmetric;
        return null;
    }

    fn classCopy(p: *Parser, c: Class) Error!Class {
        var out: Class = .{ .bytes = c.bytes };
        try out.ranges.appendSlice(p.arena, c.ranges.items);
        return out;
    }

    fn classIntersect(p: *Parser, a: *Class, b: *Class) Error!Class {
        try ucp.normalize(p.arena, &a.ranges);
        try ucp.normalize(p.arena, &b.ranges);
        var out: Class = .{ .bytes = a.bytes };
        out.bytes.intersectWith(b.bytes);
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.ranges.items.len and j < b.ranges.items.len) {
            const x = a.ranges.items[i];
            const y = b.ranges.items[j];
            const lo = @max(x.lo, y.lo);
            const hi = @min(x.hi, y.hi);
            if (lo <= hi) try out.ranges.append(p.arena, .{ .lo = lo, .hi = hi });
            if (x.hi < y.hi) i += 1 else j += 1;
        }
        return out;
    }

    fn classSetOp(p: *Parser, op: SetOp, a: *Class, b: *Class) Error!Class {
        switch (op) {
            .intersection => return p.classIntersect(a, b),
            .difference => {
                var nb = try p.classCopy(b.*);
                try p.classInvert(&nb);
                return p.classIntersect(a, &nb);
            },
            .symmetric => {
                var na = try p.classCopy(a.*);
                var nb = try p.classCopy(b.*);
                try p.classInvert(&na);
                try p.classInvert(&nb);
                var left = try p.classIntersect(a, &nb);
                var right = try p.classIntersect(b, &na);
                try p.classUnion(&left, right);
                _ = &right;
                return left;
            },
        }
    }

    /// Cursor is just past '['. Consumes through the closing ']'.
    fn parseClass(p: *Parser) Error!Class {
        const open = p.pos - 1;
        try p.enter();
        defer p.leave();
        const negate = p.eat('^');
        var cls = try p.parseClassSeq(open, true);
        // Rust: `[a-z&&[^aeiou]]`; all the operators have the same precedence
        // and associate to the left.
        while (p.setOpAhead()) |op| {
            p.pos += 2;
            var rhs = try p.parseClassSeq(open, false);
            cls = try p.classSetOp(op, &cls, &rhs);
        }
        if (!p.eat(']')) return p.fail(error.InvalidPattern, open, "unterminated character class");
        if (p.flags.ignore_case) try p.classFoldCase(&cls);
        if (negate) try p.classInvert(&cls);
        return cls;
    }

    /// The members of a class up to, not including, the closing ']' or (in
    /// the Rust dialect) a set operator. `first` allows a leading ']' to be
    /// an ordinary character.
    fn parseClassSeq(p: *Parser, open: usize, first_may_be_bracket: bool) Error!Class {
        var cls: Class = .{};
        var first = first_may_be_bracket;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated character class");
            if (c == ']' and !first) break;
            if (p.setOpAhead() != null) break;
            first = false;
            if (c == '[') {
                if (p.startsWith("[:")) {
                    if (try p.posixClass()) |pc| {
                        try p.classUnion(&cls, pc);
                        continue;
                    }
                }
                p.pos += 1;
                try p.classUnion(&cls, try p.parseClass());
                continue;
            }
            if (c == '&' and p.startsWith("&&"))
                return p.fail(error.Unsupported, p.pos, "class intersection &&");

            const lo = (try p.classItem(&cls)) orelse continue;
            // Range? The '-' is one byte, so test the byte after it.
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']' and !(p.dialect == .rust and p.startsWith("--"))) {
                const save = p.pos;
                p.pos += 1;
                const nxt = p.peek().?;
                if (nxt == '[') {
                    p.pos = save; // '-' followed by a nested class: literal '-'
                    try p.classAddCp(&cls, lo);
                    continue;
                }
                var scratch: Class = .{};
                const hi = (try p.classItem(&scratch)) orelse {
                    // Range to a class escape like [a-\d]: treat '-' literally.
                    try p.classAddCp(&cls, lo);
                    try p.classAddCp(&cls, '-');
                    try p.classUnion(&cls, scratch);
                    continue;
                };
                if (hi < lo) return p.fail(error.InvalidPattern, save, "character class range is reversed");
                try p.classAddRange(&cls, lo, hi);
            } else try p.classAddCp(&cls, lo);
        }
        return cls;
    }

    /// One element inside a class. Returns the scalar (or byte) for a single
    /// character, or null after adding a multi-character item (\d, \w, ...)
    /// straight into `cls`.
    fn classItem(p: *Parser, cls: *Class) Error!?u21 {
        const c = p.src[p.pos];
        if (p.utf8 and c >= 0x80) {
            const d = p.decodeAt(p.pos);
            p.pos += d.len;
            return d.cp;
        }
        p.pos += 1;
        // In a POSIX bracket expression a backslash is an ordinary character.
        if (c != '\\' or p.posix()) return c;
        const at = p.pos - 1;
        const e = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        if (p.utf8 and e >= 0x80) {
            const d = p.decodeAt(p.pos);
            p.pos += d.len;
            return d.cp;
        }
        p.pos += 1;
        if (try p.classEscape(e)) |found| {
            try p.classUnion(cls, found);
            return null;
        }
        if (e == 'b') return 0x08; // \b inside a class is backspace
        if (e == 'p' or e == 'P') {
            try p.classUnion(cls, try p.propertyClass(e == 'P', at));
            return null;
        }
        if (try p.byteEscape(e, at)) |cp| return cp;
        return p.fail(error.InvalidPattern, at, "unknown escape sequence in class");
    }

    /// In utf8 mode the classes with a clear Unicode meaning (UTS #18,
    /// Annex C) use the tables; the rest (punct, cntrl, print, graph, xdigit,
    /// ascii) stay ASCII. Null means "not one of those".
    fn posixUnicodeClass(p: *Parser, name: []const u8, neg: bool) Error!?Class {
        var cls: Class = .{};
        if (std.mem.eql(u8, name, "alpha")) {
            try p.classAddTable(&cls, unicode.alphabetic, false);
        } else if (std.mem.eql(u8, name, "alnum")) {
            try p.classAddTable(&cls, unicode.alphabetic, false);
            try p.classAddTable(&cls, unicode.digit, false);
        } else if (std.mem.eql(u8, name, "upper")) {
            try p.classAddTable(&cls, unicode.uppercase, false);
        } else if (std.mem.eql(u8, name, "lower")) {
            try p.classAddTable(&cls, unicode.lowercase, false);
        } else if (std.mem.eql(u8, name, "digit")) {
            try p.classAddTable(&cls, unicode.digit, false);
        } else if (std.mem.eql(u8, name, "space")) {
            try p.classAddTable(&cls, unicode.space, false);
        } else if (std.mem.eql(u8, name, "word")) {
            try p.classAddTable(&cls, unicode.word, false);
        } else if (std.mem.eql(u8, name, "blank")) {
            try p.classAddTable(&cls, unicode.space_separator, false);
            try p.classAddCp(&cls, '\t');
        } else return null;
        if (neg) try p.classInvert(&cls);
        return cls;
    }

    /// At "[:". Returns the set for [:name:] / [:^name:], or null (cursor
    /// unmoved) when this is not a POSIX class, so the caller treats '[' as a
    /// nested class.
    fn posixClass(p: *Parser) Error!?Class {
        const start = p.pos;
        const end = std.mem.indexOfPos(u8, p.src, start + 2, ":]") orelse return null;
        var name = p.src[start + 2 .. end];
        const neg = name.len > 0 and name[0] == '^';
        if (neg) name = name[1..];
        if (p.utf8 and unicode.enabled) if (try p.posixUnicodeClass(name, neg)) |cls| {
            p.pos = end + 2;
            return cls;
        };
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
        return try p.classFromSet(s, neg);
    }
};

/// Offset of the first byte that is not part of well-formed UTF-8.
fn invalidUtf8At(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return i;
        if (i + n > s.len) return i;
        _ = std.unicode.utf8Decode(s[i..][0..n]) catch return i;
        i += n;
    }
    return null;
}

pub fn parse(
    arena: std.mem.Allocator,
    pattern: []const u8,
    dialect: Dialect,
    ignore_case: bool,
    utf8: bool,
    limits: Limits,
    diag: *Diagnostic,
) Error!Parsed {
    diag.* = .{};
    if (utf8) if (invalidUtf8At(pattern)) |at| {
        diag.* = .{ .pos = at, .message = "pattern is not valid UTF-8" };
        return error.InvalidPattern;
    };
    if (pattern.len > limits.max_pattern_len) {
        diag.* = .{ .pos = 0, .message = "pattern too long" };
        return error.LimitExceeded;
    }
    var p: Parser = .{
        .arena = arena,
        .src = pattern,
        .dialect = dialect,
        .utf8 = utf8,
        .limits = limits,
        .flags = .{ .ignore_case = ignore_case, .line_anchors = dialect == .oniguruma, .dot_all = dialect == .posix_ere or dialect == .posix_bre },
        .diag = diag,
    };
    const root = try p.parseAlt();
    if (p.pos < pattern.len) return p.fail(error.InvalidPattern, p.pos, "unmatched ')'");
    if (p.max_backref > p.group_count)
        return p.fail(error.InvalidPattern, p.backref_pos, "reference to a group that does not exist");
    return .{ .root = root, .group_count = p.group_count, .names = p.names.items };
}

/// A copy of `n` with every capture group made a plain group, or an error for
/// a back-reference (which would point at a group that no longer exists).
fn stripCaptures(arena: std.mem.Allocator, n: *const Node) Error!*const Node {
    const out = try arena.create(Node);
    out.* = switch (n.*) {
        .empty, .byte, .any, .set, .cp_set, .assertion => n.*,
        .backref => return error.Unsupported,
        .concat => |items| .{ .concat = try stripAll(arena, items) },
        .alt => |items| .{ .alt = try stripAll(arena, items) },
        .repeat => |r| .{ .repeat = .{ .sub = try stripCaptures(arena, r.sub), .min = r.min, .max = r.max, .greed = r.greed } },
        .group => |g| .{ .group = .{ .sub = try stripCaptures(arena, g.sub), .index = null } },
        .atomic => |sub| .{ .atomic = try stripCaptures(arena, sub) },
        .look => |l| .{ .look = .{ .sub = try stripCaptures(arena, l.sub), .ahead = l.ahead, .negate = l.negate } },
    };
    return out;
}

fn stripAll(arena: std.mem.Allocator, items: []const *const Node) Error![]const *const Node {
    const out = try arena.alloc(*const Node, items.len);
    for (items, out) |it, *o| o.* = try stripCaptures(arena, it);
    return out;
}

/// Parses several patterns into one alternation, in order, for a set. Capture
/// groups are dropped (a set reports spans, not groups) and back-references
/// are rejected. On failure `diag.pattern` says which pattern.
pub fn parseSet(
    arena: std.mem.Allocator,
    patterns: []const []const u8,
    dialect: Dialect,
    ignore_case: bool,
    utf8: bool,
    limits: Limits,
    diag: *Diagnostic,
) Error!Parsed {
    var alts: std.ArrayList(*const Node) = .empty;
    for (patterns, 0..) |pat, i| {
        const one = parse(arena, pat, dialect, ignore_case, utf8, limits, diag) catch |e| {
            diag.pattern = i;
            return e;
        };
        const stripped = stripCaptures(arena, one.root) catch |e| {
            diag.* = .{ .pos = 0, .message = "back-references are not supported in a set", .pattern = i };
            return e;
        };
        try alts.append(arena, stripped);
    }
    const root = try arena.create(Node);
    root.* = switch (alts.items.len) {
        0 => .{ .set = .{} }, // an empty set never matches
        1 => alts.items[0].*,
        else => .{ .alt = alts.items },
    };
    return .{ .root = root, .group_count = 0, .names = &.{} };
}

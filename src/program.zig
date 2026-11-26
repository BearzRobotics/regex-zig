// SPDX-License-Identifier: LGPL-2.0-or-later
//! Compiled program for the backtracking VM, and the compiler from the AST.

const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const ByteSet = @import("byteset.zig").ByteSet;
const utf8 = @import("utf8.zig");
const unicode = @import("unicode.zig");

pub const unset = std.math.maxInt(usize);

/// A set that needs more byte sequences than this is matched with `cp_class`
/// instead (see ADR 0001, section 10).
const max_inline_sequences = 16;

/// Bounds the compiler's own work. A counted repeat compiles its body once per
/// copy, and a body can hold many nodes that emit nothing, so the limit on
/// emitted instructions does not by itself bound compile time.
const work_per_instruction = 16;
const min_work = 1 << 18;

pub const Inst = union(enum) {
    byte: u8,
    any, // any byte except '\n'
    any_nl, // any byte
    set: u32, // index into Program.sets
    /// utf8 mode: decode one scalar value and test it against Program.cp_sets[n].
    /// Used for sets too large to be worth lowering to byte sequences.
    cp_class: u32,
    /// Try `first`; on failure resume at `second`.
    split: struct { first: u32, second: u32 },
    jmp: u32,
    /// regs[n] = current position (restored on backtrack).
    save: u32,
    /// Backtracker only: capture group `group` closes. Publishes the start held
    /// in regs[pending] and the current position together, so a
    /// back-reference inside the group still sees the previous capture.
    close_group: struct { group: u32, pending: u32 },
    assertion: ast.Assertion,
    backref: struct { index: u32, ignore_case: bool },
    /// Push a barrier; the body runs as an atomic unit.
    atomic_start,
    atomic_end,
    /// Look-around body. For negative looks `end` is where matching resumes
    /// when the body fails.
    look_start: struct { negate: bool, end: u32 },
    look_end,
    /// Move back `n` bytes (look-behind of fixed width), failing at text start.
    back: u32,
    /// Loop guard for bodies that can match empty: regs[slot] = position.
    mark: u32,
    /// If no progress since `mark`, fall through to the loop exit; else jump.
    loop_end: struct { slot: u32, target: u32 },
    match,
};

/// Which matching engine runs a pattern (docs/decisions/0002-matching-engines.md).
pub const Engine = enum {
    /// Pike VM when the pattern allows it, otherwise the backtracker.
    auto,
    backtrack,
    pike,
    /// Lazy DFA for the match span, Pike VM for captures. Only patterns whose
    /// assertions a DFA can evaluate qualify (see dfaEligible).
    dfa,
};

/// What the compiler needs beyond the AST.
pub const Settings = struct {
    utf8: bool = false,
    /// Leftmost-longest instead of leftmost-first (POSIX syntaxes).
    longest: bool = false,
    engine: Engine = .auto,
};

/// The byte-at-a-time program for the Pike VM: only `byte`, `any`, `any_nl`,
/// `set`, `split`, `jmp`, `save`, `assertion` and `match` instructions.
pub const Nfa = struct {
    insts: []const Inst,
    sets: []const ByteSet,

    pub fn deinit(n: Nfa, gpa: std.mem.Allocator) void {
        gpa.free(n.insts);
        gpa.free(n.sets);
    }
};

pub const Program = struct {
    insts: []const Inst,
    /// Bytes a match can start with, or null when the pattern can match the
    /// empty string (or the set cannot be bounded). Used to skip start
    /// positions without running the VM.
    first_bytes: ?ByteSet,
    sets: []const ByteSet,
    cp_sets: []const []const utf8.CpRange,
    group_count: u32,
    reg_count: u32,
    names: []const parse.Name,
    /// Matching is over UTF-8: start positions inside a character are skipped.
    utf8: bool,
    longest: bool,
    /// The engine `find` uses: .backtrack, .pike or .dfa, never .auto.
    engine: Engine,
    nfa: ?Nfa,
    /// The same pattern compiled right to left, for the DFA that finds where
    /// a match starts. Set exactly when engine is .dfa.
    reverse_nfa: ?Nfa,
    /// Bytes every match starts with (a case-sensitive literal prefix), or
    /// empty. Lets the DFA jump to the next occurrence with a substring search.
    literal_prefix: []const u8,
    /// The pattern contains `$` or `\Z`, which match before a final newline.
    /// The DFA treats them as end of text, so a haystack that ends in a
    /// newline is searched with the Pike VM instead.
    final_newline_assertion: bool,

    pub fn deinit(prog: Program, gpa: std.mem.Allocator) void {
        if (prog.nfa) |n| n.deinit(gpa);
        if (prog.reverse_nfa) |n| n.deinit(gpa);
        gpa.free(prog.literal_prefix);
        gpa.free(prog.insts);
        gpa.free(prog.sets);
        for (prog.cp_sets) |s| gpa.free(s);
        gpa.free(prog.cp_sets);
        for (prog.names) |n| gpa.free(n.name);
        gpa.free(prog.names);
    }
};

const Compiler = struct {
    gpa: std.mem.Allocator,
    limits: parse.Limits,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList(ByteSet) = .empty,
    cp_sets: std.ArrayList([]const utf8.CpRange) = .empty,
    /// The AST slice each entry of cp_sets was copied from, so a node that is
    /// compiled several times (a repeat body) shares one copy.
    cp_sources: std.ArrayList([]const utf8.CpRange) = .empty,
    loop_slots: u32 = 0,
    group_count: u32,
    utf8: bool,
    /// Compile for the Pike VM (see Nfa) instead of the backtracker.
    nfa: bool = false,
    /// Compile the pattern right to left (the DFA that finds match starts).
    reverse: bool = false,
    depth: u32 = 0,
    /// AST nodes compiled so far, counting every copy.
    work: usize = 0,
    diag: *parse.Diagnostic,

    fn emit(c: *Compiler, i: Inst) parse.Error!u32 {
        if (c.insts.items.len >= c.limits.max_program_len) {
            c.diag.* = .{ .pos = 0, .message = "compiled program too large" };
            return error.LimitExceeded;
        }
        try c.insts.append(c.gpa, i);
        return @intCast(c.insts.items.len - 1);
    }

    fn here(c: *Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn unsupported(c: *Compiler, msg: []const u8) parse.Error {
        c.diag.* = .{ .pos = 0, .message = msg };
        return error.Unsupported;
    }

    fn compile(c: *Compiler, n: *const ast.Node) parse.Error!void {
        c.depth += 1;
        defer c.depth -= 1;
        if (c.depth > c.limits.max_depth) {
            c.diag.* = .{ .pos = 0, .message = "pattern nesting too deep" };
            return error.LimitExceeded;
        }
        c.work += 1;
        if (c.work > @max(c.limits.max_program_len *| work_per_instruction, min_work)) {
            c.diag.* = .{ .pos = 0, .message = "pattern expands to too much compile work" };
            return error.LimitExceeded;
        }
        switch (n.*) {
            .empty => {},
            .byte => |b| _ = try c.emit(.{ .byte = b }),
            .any => |nl| if (c.utf8) try c.compileAnyUtf8(nl) else {
                _ = try c.emit(if (nl) .any_nl else .any);
            },
            .cp_set => |ranges| try c.emitRanges(ranges),
            .set => |s| {
                try c.sets.append(c.gpa, s);
                _ = try c.emit(.{ .set = @intCast(c.sets.items.len - 1) });
            },
            .concat => |items| if (c.reverse) {
                var i = items.len;
                while (i > 0) {
                    i -= 1;
                    try c.compile(items[i]);
                }
            } else for (items) |it| try c.compile(it),
            .alt => |alts| try c.compileAlt(alts, null),
            .repeat => |r| try c.compileRepeat(r),
            .group => |g| {
                if (g.index) |i| {
                    if (c.nfa) {
                        // No back-references here, so nothing can observe a
                        // half-written capture.
                        _ = try c.emit(.{ .save = 2 * i });
                        try c.compile(g.sub);
                        _ = try c.emit(.{ .save = 2 * i + 1 });
                    } else {
                        const pending = 2 * (c.group_count + 1) + (i - 1);
                        _ = try c.emit(.{ .save = pending });
                        try c.compile(g.sub);
                        _ = try c.emit(.{ .close_group = .{ .group = i, .pending = pending } });
                    }
                } else try c.compile(g.sub);
            },
            .atomic => |sub| {
                if (c.nfa) return c.unsupported("atomic group needs the backtracking engine");
                _ = try c.emit(.atomic_start);
                try c.compile(sub);
                _ = try c.emit(.atomic_end);
            },
            .look => |l| try c.compileLook(l),
            .assertion => |a| _ = try c.emit(.{ .assertion = if (c.reverse) reverseAssertion(a) else a }),
            .backref => |b| if (c.nfa) {
                return c.unsupported("back-reference needs the backtracking engine");
            } else {
                _ = try c.emit(.{ .backref = .{ .index = b.index, .ignore_case = b.ignore_case } });
            },
        }
    }

    /// `.` in utf8 mode: any scalar value, except '\n' unless `nl`.
    fn compileAnyUtf8(c: *Compiler, nl: bool) parse.Error!void {
        var ranges: std.ArrayList(utf8.CpRange) = .empty;
        defer ranges.deinit(c.gpa);
        if (nl) {
            try ranges.append(c.gpa, .{ .lo = 0, .hi = utf8.max_scalar });
        } else {
            try ranges.append(c.gpa, .{ .lo = 0, .hi = '\n' - 1 });
            try ranges.append(c.gpa, .{ .lo = '\n' + 1, .hi = utf8.max_scalar });
        }
        try utf8.normalize(c.gpa, &ranges);
        try c.emitRanges(ranges.items);
    }

    /// A set of scalar values as an alternation of UTF-8 byte sequences (see
    /// utf8.zig). The sequences are disjoint, so their order does not matter.
    fn emitRanges(c: *Compiler, ranges: []const utf8.CpRange) parse.Error!void {
        if (c.nfa) return c.emitRangesNfa(ranges);
        var seqs: std.ArrayList(utf8.Sequence) = .empty;
        defer seqs.deinit(c.gpa);
        for (ranges) |r| try utf8.appendSequences(c.gpa, &seqs, r);
        if (seqs.items.len > max_inline_sequences) {
            // Trying hundreds of alternatives per character would be slow;
            // decode the character once and binary-search the ranges instead.
            for (c.cp_sources.items, 0..) |src, k| {
                if (src.ptr == ranges.ptr and src.len == ranges.len) {
                    _ = try c.emit(.{ .cp_class = @intCast(k) });
                    return;
                }
            }
            const copy = try c.gpa.dupe(utf8.CpRange, ranges);
            {
                // Only until `cp_sets` owns the copy: after that `build` frees
                // it, also when the `emit` below fails.
                errdefer c.gpa.free(copy);
                try c.cp_sources.ensureUnusedCapacity(c.gpa, 1);
                try c.cp_sets.append(c.gpa, copy);
            }
            c.cp_sources.appendAssumeCapacity(ranges);
            _ = try c.emit(.{ .cp_class = @intCast(c.cp_sets.items.len - 1) });
            return;
        }
        if (seqs.items.len == 0) {
            // An empty set never matches.
            try c.sets.append(c.gpa, .{});
            _ = try c.emit(.{ .set = @intCast(c.sets.items.len - 1) });
            return;
        }
        var jumps: std.ArrayList(u32) = .empty;
        defer jumps.deinit(c.gpa);
        for (seqs.items, 0..) |seq, i| {
            const last = i + 1 == seqs.items.len;
            var split: u32 = undefined;
            if (!last) split = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const body = c.here();
            for (seq.ranges[0..seq.len]) |br| try c.emitByteRange(br);
            if (!last) {
                try jumps.append(c.gpa, try c.emit(.{ .jmp = 0 }));
                c.insts.items[split] = .{ .split = .{ .first = body, .second = c.here() } };
            }
        }
        for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.here() };
    }

    /// NFA form of a character set: a trie over the byte ranges of the UTF-8
    /// sequences, so sequences that share their first byte ranges share
    /// instructions and the lead byte does not fan out into one thread per
    /// sequence.
    fn emitRangesNfa(c: *Compiler, ranges: []const utf8.CpRange) parse.Error!void {
        var seqs: std.ArrayList(utf8.Sequence) = .empty;
        defer seqs.deinit(c.gpa);
        for (ranges) |r| try utf8.appendSequences(c.gpa, &seqs, r);
        if (seqs.items.len == 0) {
            try c.sets.append(c.gpa, .{});
            _ = try c.emit(.{ .set = @intCast(c.sets.items.len - 1) });
            return;
        }
        // Read right to left, the last byte of a character comes first.
        if (c.reverse) for (seqs.items) |*s| std.mem.reverse(utf8.ByteRange, s.ranges[0..s.len]);
        std.mem.sort(utf8.Sequence, seqs.items, {}, sequenceLessThan);
        var ends: std.ArrayList(u32) = .empty;
        defer ends.deinit(c.gpa);
        try c.emitTrie(seqs.items, 0, &ends);
        for (ends.items) |j| c.insts.items[j] = .{ .jmp = c.here() };
    }

    /// `seqs` is sorted and every member has the same first `depth` ranges.
    /// Left to right, sequences with equal first ranges have equal length.
    /// Right to left they need not (a 2-byte and a 3-byte character can end in
    /// the same continuation range), so a group can contain sequences that
    /// end here as well as sequences that go on.
    fn emitTrie(c: *Compiler, seqs: []const utf8.Sequence, depth: u3, ends: *std.ArrayList(u32)) parse.Error!void {
        var i: usize = 0;
        while (i < seqs.len) {
            const key = seqs[i].ranges[depth];
            var j = i + 1;
            while (j < seqs.len and std.meta.eql(seqs[j].ranges[depth], key)) j += 1;
            const last = j == seqs.len;
            var split: u32 = undefined;
            if (!last) split = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const body = c.here();
            try c.emitByteRange(key);
            // Sorted shorter-first, so the ones that end here come first.
            var ending: usize = 0;
            while (i + ending < j and seqs[i + ending].len == depth + 1) ending += 1;
            const continuing = seqs[i + ending .. j];
            if (ending > 0 and continuing.len > 0) {
                const alt = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
                try ends.append(c.gpa, try c.emit(.{ .jmp = 0 }));
                c.insts.items[alt] = .{ .split = .{ .first = alt + 1, .second = c.here() } };
                try c.emitTrie(continuing, depth + 1, ends);
            } else if (ending > 0) {
                try ends.append(c.gpa, try c.emit(.{ .jmp = 0 }));
            } else {
                try c.emitTrie(continuing, depth + 1, ends);
            }
            if (!last) c.insts.items[split] = .{ .split = .{ .first = body, .second = c.here() } };
            i = j;
        }
    }

    fn emitByteRange(c: *Compiler, br: utf8.ByteRange) parse.Error!void {
        if (br.lo == br.hi) {
            _ = try c.emit(.{ .byte = br.lo });
            return;
        }
        var s: ByteSet = .{};
        s.addRange(br.lo, br.hi);
        // Many sequences share the same continuation range (80-BF); reuse it.
        for (c.sets.items, 0..) |existing, k| {
            if (std.meta.eql(existing, s)) {
                _ = try c.emit(.{ .set = @intCast(k) });
                return;
            }
        }
        try c.sets.append(c.gpa, s);
        _ = try c.emit(.{ .set = @intCast(c.sets.items.len - 1) });
    }

    /// Alternatives in priority order. `back_widths`, when set, gives each
    /// branch a leading `back` (look-behind).
    fn compileAlt(c: *Compiler, alts: []const *const ast.Node, back_widths: ?[]const u32) parse.Error!void {
        var jumps: std.ArrayList(u32) = .empty;
        defer jumps.deinit(c.gpa);
        for (alts, 0..) |alt, i| {
            const last = i + 1 == alts.len;
            var split: u32 = undefined;
            if (!last) split = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const body = c.here();
            if (back_widths) |w| _ = try c.emit(.{ .back = w[i] });
            try c.compile(alt);
            if (!last) {
                try jumps.append(c.gpa, try c.emit(.{ .jmp = 0 }));
                c.insts.items[split] = .{ .split = .{ .first = body, .second = c.here() } };
            }
        }
        for (jumps.items) |j| c.insts.items[j] = .{ .jmp = c.here() };
    }

    fn compileLook(c: *Compiler, l: ast.Look) parse.Error!void {
        if (c.nfa) return c.unsupported("look-around needs the backtracking engine");
        const start = try c.emit(.{ .look_start = .{ .negate = l.negate, .end = 0 } });
        if (l.ahead) {
            try c.compile(l.sub);
        } else {
            // Each top-level alternative must have its own fixed width.
            const alts: []const *const ast.Node = switch (l.sub.*) {
                .alt => |a| a,
                else => &.{l.sub},
            };
            var widths = try c.gpa.alloc(u32, alts.len);
            defer c.gpa.free(widths);
            for (alts, 0..) |a, i| {
                widths[i] = fixedWidth(a, c.utf8) orelse
                    return c.unsupported("look-behind must have a fixed width");
            }
            try c.compileAlt(alts, widths);
        }
        _ = try c.emit(.look_end);
        c.insts.items[start] = .{ .look_start = .{ .negate = l.negate, .end = c.here() } };
    }

    fn compileRepeat(c: *Compiler, r: ast.Repeat) parse.Error!void {
        if (r.greed == .possessive) {
            if (c.nfa) return c.unsupported("possessive quantifier needs the backtracking engine");
            _ = try c.emit(.atomic_start);
            try c.compileRepeatBody(r);
            _ = try c.emit(.atomic_end);
        } else try c.compileRepeatBody(r);
    }

    fn compileRepeatBody(c: *Compiler, r: ast.Repeat) parse.Error!void {
        const lazy = r.greed == .lazy;
        var i: u32 = 0;
        while (i < r.min) : (i += 1) {
            const before = c.here();
            try c.compile(r.sub);
            // A body that emits nothing, such as `(?:)` or `x{0}`, emits
            // nothing every time. Nested, such repeats would multiply.
            if (c.here() == before) break;
        }

        if (r.max) |max| {
            // (x(x(x)?)?)? — every optional copy exits to the same end.
            var splits: std.ArrayList(u32) = .empty;
            defer splits.deinit(c.gpa);
            var k: u32 = r.min;
            while (k < max) : (k += 1) {
                try splits.append(c.gpa, try c.emit(.{ .split = .{ .first = 0, .second = 0 } }));
                try c.compile(r.sub);
            }
            const end = c.here();
            for (splits.items) |s| {
                const body = s + 1;
                c.insts.items[s] = .{ .split = if (lazy)
                    .{ .first = end, .second = body }
                else
                    .{ .first = body, .second = end } };
            }
            return;
        }

        if (c.nfa) {
            // do-while shape: entry: split(body, exit); body; split(body, exit).
            // When the body can match empty, an empty iteration reaches the
            // exit at the priority the body had (as in Perl), where a jump
            // back to the entry would be cut by the Pike VM's visited set and
            // lose that path.
            const entry = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const body = c.here();
            try c.compile(r.sub);
            const again = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const exit = c.here();
            const order: @TypeOf(c.insts.items[entry].split) = if (lazy)
                .{ .first = exit, .second = body }
            else
                .{ .first = body, .second = exit };
            c.insts.items[entry] = .{ .split = order };
            c.insts.items[again] = .{ .split = order };
            return;
        }

        // Unbounded tail: L: split(body, exit); body; jmp L; exit:
        const loop = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
        var slot: ?u32 = null;
        // The Pike VM needs no guard: its visited set stops empty loops.
        if (!c.nfa and canBeEmpty(r.sub)) {
            // After the captures and the pending group starts.
            slot = 2 * (c.group_count + 1) + c.group_count + c.loop_slots;
            c.loop_slots += 1;
            _ = try c.emit(.{ .mark = slot.? });
        }
        try c.compile(r.sub);
        if (slot) |sl| {
            // loop_end falls through to exit when the iteration was empty.
            _ = try c.emit(.{ .loop_end = .{ .slot = sl, .target = loop } });
        } else _ = try c.emit(.{ .jmp = loop });
        const exit = c.here();
        c.insts.items[loop] = .{ .split = if (lazy)
            .{ .first = exit, .second = loop + 1 }
        else
            .{ .first = loop + 1, .second = exit } };
    }
};

/// The assertion that holds at the same position when the text is read
/// right to left. `$` and `\Z` become start-of-text; the DFA only runs when
/// they mean end of text (see Program.final_newline_assertion).
fn reverseAssertion(a: ast.Assertion) ast.Assertion {
    return switch (a) {
        .line_start => .line_end,
        .line_end => .line_start,
        .text_start => .text_end,
        .text_end, .text_end_or_final_newline => .text_start,
        .word_start => .word_end,
        .word_end => .word_start,
        .word_boundary, .not_word_boundary, .search_start => a,
    };
}

/// Whether the lazy DFA can run this pattern: no `\G`, and `\b` only when it
/// is ASCII-only (a Unicode `\b` needs the characters around the position,
/// not just the previous byte).
fn dfaEligible(n: *const ast.Node, unicode_word: bool) bool {
    return switch (n.*) {
        .assertion => |a| switch (a) {
            .search_start => false,
            .word_boundary, .not_word_boundary, .word_start, .word_end => !unicode_word,
            else => true,
        },
        .empty, .byte, .any, .set, .cp_set, .atomic, .look, .backref => true,
        .concat => |items| for (items) |it| {
            if (!dfaEligible(it, unicode_word)) break false;
        } else true,
        .alt => |alts| for (alts) |a| {
            if (!dfaEligible(a, unicode_word)) break false;
        } else true,
        .repeat => |r| dfaEligible(r.sub, unicode_word),
        .group => |g| dfaEligible(g.sub, unicode_word),
    };
}

/// Appends the literal bytes the pattern must start with. Returns true when
/// the whole of `n` is literal, so the next item in a sequence can extend it.
fn collectPrefix(n: *const ast.Node, out: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
    switch (n.*) {
        .empty => return true,
        .byte => |b| {
            try out.append(gpa, b);
            return true;
        },
        .concat => |items| {
            for (items) |it| if (!try collectPrefix(it, out, gpa)) return false;
            return true;
        },
        .group => |g| return collectPrefix(g.sub, out, gpa),
        else => return false,
    }
}

fn hasFinalNewlineAssertion(n: *const ast.Node) bool {
    return switch (n.*) {
        .assertion => |a| a == .text_end_or_final_newline,
        .empty, .byte, .any, .set, .cp_set, .backref => false,
        .concat => |items| for (items) |it| {
            if (hasFinalNewlineAssertion(it)) break true;
        } else false,
        .alt => |alts| for (alts) |a| {
            if (hasFinalNewlineAssertion(a)) break true;
        } else false,
        .repeat => |r| hasFinalNewlineAssertion(r.sub),
        .group => |g| hasFinalNewlineAssertion(g.sub),
        .atomic => |sub| hasFinalNewlineAssertion(sub),
        .look => |l| hasFinalNewlineAssertion(l.sub),
    };
}

fn sequenceLessThan(_: void, a: utf8.Sequence, b: utf8.Sequence) bool {
    const n = @min(a.len, b.len);
    for (a.ranges[0..n], b.ranges[0..n]) |x, y| {
        if (x.lo != y.lo) return x.lo < y.lo;
        if (x.hi != y.hi) return x.hi < y.hi;
    }
    return a.len < b.len;
}

/// True if the pattern uses something only the backtracker implements.
fn needsBacktracker(n: *const ast.Node) bool {
    return switch (n.*) {
        .atomic, .look, .backref => true,
        .empty, .byte, .any, .set, .cp_set, .assertion => false,
        .concat => |items| for (items) |it| {
            if (needsBacktracker(it)) break true;
        } else false,
        .alt => |alts| for (alts) |a| {
            if (needsBacktracker(a)) break true;
        } else false,
        .repeat => |r| r.greed == .possessive or needsBacktracker(r.sub),
        .group => |g| needsBacktracker(g.sub),
    };
}

/// Width in bytes if every match of `n` has the same length.
fn fixedWidth(n: *const ast.Node, utf8_mode: bool) ?u32 {
    return switch (n.*) {
        .empty, .assertion, .look => 0,
        .byte, .set => 1,
        // A scalar value is 1 to 4 bytes long.
        .any => if (utf8_mode) null else 1,
        // Fixed only when every range stays within one encoded length, and
        // all ranges share it (for example a class of two-byte letters).
        .cp_set => |ranges| blk: {
            var width: ?u32 = null;
            for (ranges) |r| {
                const lo_len = std.unicode.utf8CodepointSequenceLength(r.lo) catch break :blk null;
                const hi_len = std.unicode.utf8CodepointSequenceLength(r.hi) catch break :blk null;
                if (lo_len != hi_len or (width != null and width.? != lo_len)) break :blk null;
                width = lo_len;
            }
            break :blk width;
        },
        .concat => |items| blk: {
            var total: u32 = 0;
            for (items) |it| total +|= fixedWidth(it, utf8_mode) orelse break :blk null;
            break :blk total;
        },
        .alt => |alts| blk: {
            const w = fixedWidth(alts[0], utf8_mode) orelse break :blk null;
            for (alts[1..]) |a| if (fixedWidth(a, utf8_mode) != w) break :blk null;
            break :blk w;
        },
        .repeat => |r| blk: {
            const max = r.max orelse break :blk null;
            if (max != r.min) break :blk null;
            break :blk (fixedWidth(r.sub, utf8_mode) orelse break :blk null) *| r.min;
        },
        .group => |g| fixedWidth(g.sub, utf8_mode),
        .atomic => |sub| fixedWidth(sub, utf8_mode),
        .backref => null,
    };
}

fn canBeEmpty(n: *const ast.Node) bool {
    return switch (n.*) {
        .empty, .assertion, .look, .backref => true,
        .byte, .any, .set, .cp_set => false,
        .concat => |items| for (items) |it| {
            if (!canBeEmpty(it)) break false;
        } else true,
        .alt => |alts| for (alts) |a| {
            if (canBeEmpty(a)) break true;
        } else false,
        .repeat => |r| r.min == 0 or canBeEmpty(r.sub),
        .group => |g| canBeEmpty(g.sub),
        .atomic => |sub| canBeEmpty(sub),
    };
}

const First = struct { set: ByteSet = .{}, nullable: bool = false };

/// Conservative superset of the bytes a match of `n` can begin with, and
/// whether `n` can match without consuming input.
fn firstOf(n: *const ast.Node) First {
    var all: ByteSet = .{};
    all.invert();
    switch (n.*) {
        .empty, .assertion, .look => return .{ .nullable = true },
        .byte => |b| {
            var s: ByteSet = .{};
            s.add(b);
            return .{ .set = s };
        },
        .any => |nl| {
            var s = all;
            if (!nl) {
                s = .{};
                s.add('\n');
                s.invert();
            }
            return .{ .set = s };
        },
        .set => |s| return .{ .set = s },
        .cp_set => |ranges| {
            var s: ByteSet = .{};
            for (ranges) |r| {
                const lead = utf8.leadByteRange(r);
                s.addRange(lead.lo, lead.hi);
            }
            return .{ .set = s };
        },
        .backref => return .{ .set = all, .nullable = true },
        .concat => |items| {
            var r: First = .{ .nullable = true };
            for (items) |it| {
                const f = firstOf(it);
                r.set.unionWith(f.set);
                if (!f.nullable) {
                    r.nullable = false;
                    break;
                }
            }
            return r;
        },
        .alt => |alts| {
            var r: First = .{};
            for (alts) |a| {
                const f = firstOf(a);
                r.set.unionWith(f.set);
                r.nullable = r.nullable or f.nullable;
            }
            return r;
        },
        .repeat => |rep| {
            var f = firstOf(rep.sub);
            if (rep.min == 0) f.nullable = true;
            return f;
        },
        .group => |g| return firstOf(g.sub),
        .atomic => |sub| return firstOf(sub),
    }
}

const Built = struct {
    insts: []const Inst,
    sets: []const ByteSet,
    cp_sets: []const []const utf8.CpRange,
    loop_slots: u32,
};

/// One compilation of the AST: for the backtracker (`nfa` false) or for the
/// Pike VM. The caller owns the returned slices.
fn build(gpa: std.mem.Allocator, parsed: parse.Parsed, limits: parse.Limits, utf8_mode: bool, nfa: bool, reverse: bool, diag: *parse.Diagnostic) parse.Error!Built {
    var c: Compiler = .{ .gpa = gpa, .limits = limits, .group_count = parsed.group_count, .utf8 = utf8_mode, .nfa = nfa, .reverse = reverse, .diag = diag };
    errdefer c.insts.deinit(gpa);
    errdefer c.sets.deinit(gpa);
    errdefer {
        for (c.cp_sets.items) |s| gpa.free(s);
        c.cp_sets.deinit(gpa);
    }
    defer c.cp_sources.deinit(gpa);

    _ = try c.emit(.{ .save = 0 }); // match start
    try c.compile(parsed.root);
    _ = try c.emit(.{ .save = 1 });
    _ = try c.emit(.match);

    const insts = try c.insts.toOwnedSlice(gpa);
    errdefer gpa.free(insts);
    const sets = try c.sets.toOwnedSlice(gpa);
    errdefer gpa.free(sets);
    const cp_sets = try c.cp_sets.toOwnedSlice(gpa);
    return .{ .insts = insts, .sets = sets, .cp_sets = cp_sets, .loop_slots = c.loop_slots };
}

/// Compile a parsed pattern. The returned Program owns gpa memory (and copies
/// the group names out of the parser arena). The backtracker program is
/// always built; the Pike VM program is built too when the pattern allows it
/// and `settings.engine` is not `.backtrack`.
pub fn compile(gpa: std.mem.Allocator, parsed: parse.Parsed, limits: parse.Limits, settings: Settings, diag: *parse.Diagnostic) parse.Error!Program {
    const eligible = !needsBacktracker(parsed.root);
    if ((settings.engine == .pike or settings.engine == .dfa) and !eligible) {
        diag.* = .{ .pos = 0, .message = "pattern needs the backtracking engine (back-reference, look-around, atomic group or possessive quantifier)" };
        return error.Unsupported;
    }

    const bt = try build(gpa, parsed, limits, settings.utf8, false, false, diag);
    errdefer {
        gpa.free(bt.insts);
        gpa.free(bt.sets);
        for (bt.cp_sets) |s| gpa.free(s);
        gpa.free(bt.cp_sets);
    }

    var nfa: ?Nfa = null;
    errdefer if (nfa) |n| n.deinit(gpa);
    if (eligible and settings.engine != .backtrack) {
        if (build(gpa, parsed, limits, settings.utf8, true, false, diag)) |b| {
            nfa = .{ .insts = b.insts, .sets = b.sets };
            gpa.free(b.cp_sets);
        } else |e| switch (e) {
            // Too big for the Pike VM: fall back to the backtracker, unless
            // the caller insisted.
            error.LimitExceeded => if (settings.engine == .pike or settings.engine == .dfa) return e else {
                diag.* = .{};
            },
            else => return e,
        }
    }

    // The lazy DFA needs the pattern compiled right to left as well.
    var reverse_nfa: ?Nfa = null;
    errdefer if (reverse_nfa) |n| n.deinit(gpa);
    if (nfa != null and (settings.engine == .auto or settings.engine == .dfa)) {
        if (dfaEligible(parsed.root, settings.utf8 and unicode.enabled)) {
            if (build(gpa, parsed, limits, settings.utf8, true, true, diag)) |b| {
                reverse_nfa = .{ .insts = b.insts, .sets = b.sets };
                gpa.free(b.cp_sets);
            } else |e| switch (e) {
                error.LimitExceeded => if (settings.engine == .dfa) return e else {
                    diag.* = .{};
                },
                else => return e,
            }
        } else if (settings.engine == .dfa) {
            diag.* = .{ .pos = 0, .message = "pattern uses an assertion the DFA cannot evaluate (\\G, or \\b with Unicode word characters)" };
            return error.Unsupported;
        }
    }

    var names = try gpa.alloc(parse.Name, parsed.names.len);
    var done: usize = 0;
    errdefer {
        for (names[0..done]) |n| gpa.free(n.name);
        gpa.free(names);
    }
    for (parsed.names, 0..) |n, i| {
        names[i] = .{ .name = try gpa.dupe(u8, n.name), .index = n.index };
        done = i + 1;
    }

    var prefix: std.ArrayList(u8) = .empty;
    errdefer prefix.deinit(gpa);
    _ = try collectPrefix(parsed.root, &prefix, gpa);
    // A single byte is already covered by the first-byte set.
    if (prefix.items.len < 2) prefix.clearRetainingCapacity();
    const literal_prefix = try prefix.toOwnedSlice(gpa);
    errdefer gpa.free(literal_prefix);

    const first = firstOf(parsed.root);
    return .{
        .insts = bt.insts,
        .first_bytes = if (first.nullable) null else first.set,
        .sets = bt.sets,
        .cp_sets = bt.cp_sets,
        .group_count = parsed.group_count,
        .reg_count = 2 * (parsed.group_count + 1) + parsed.group_count + bt.loop_slots,
        .names = names,
        .utf8 = settings.utf8,
        .longest = settings.longest,
        .engine = if (reverse_nfa != null) .dfa else if (nfa != null) .pike else .backtrack,
        .nfa = nfa,
        .reverse_nfa = reverse_nfa,
        .literal_prefix = literal_prefix,
        .final_newline_assertion = hasFinalNewlineAssertion(parsed.root),
    };
}

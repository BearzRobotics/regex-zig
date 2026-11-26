// SPDX-License-Identifier: LGPL-2.0-or-later
//! regex-zig: a pure-Zig regular-expression library (see SPEC.md).
//!
//! Current state: the Perl, Oniguruma and POSIX ERE parsers and the bounded
//! backtracking engine, with isMatch/matches/count/findAll/split/replaceAll
//! helpers on Searcher (ops.zig), and UTF-8 matching (Options.utf8) with Unicode
//! properties and simple case folding (-Dunicode_tables=false leaves the
//! tables out). POSIX BRE, the Rust dialect, the linear-time engine, full case
//! folding and streaming are not implemented yet.

const std = @import("std");
const parse = @import("parse.zig");
const program = @import("program.zig");
const backtrack = @import("backtrack.zig");
const ops = @import("ops.zig");
const stream = @import("stream.zig");

pub const Dialect = parse.Dialect;
pub const Limits = parse.Limits;
pub const Error = parse.Error;
pub const Diagnostic = parse.Diagnostic;
pub const MatchError = backtrack.MatchError;
pub const Match = backtrack.Match;
pub const Searcher = backtrack.Searcher;
pub const Engine = program.Engine;
pub const Span = ops.Span;
pub const Line = ops.Line;
pub const MatchingLines = ops.MatchingLines;
pub const LineStream = stream.LineStream;
pub const Matches = ops.Matches;
pub const ReplaceError = ops.ReplaceError;

pub const Options = struct {
    dialect: Dialect = .perl,
    ignore_case: bool = false,
    /// Match over UTF-8: the pattern must be valid UTF-8, and `.`, classes,
    /// negation and `\x{...}` work on Unicode scalar values. Invalid UTF-8 in
    /// the haystack never matches `.` or a class and never causes a crash.
    /// Also makes `\p{..}`, `\w \d \s \b` and the common POSIX classes
    /// Unicode-aware, and `ignore_case` / `(?i)` uses Unicode simple case
    /// folding. See docs/decisions/0001-utf8-matching.md for what is not
    /// covered (full case folding).
    utf8: bool = false,
    limits: Limits = .{},
    /// Which engine runs the pattern. `.auto` picks the Pike VM (linear
    /// time) unless the pattern needs the backtracker; `.backtrack` and
    /// `.pike` force one, mainly for tests. See docs/decisions/0002-matching-engines.md.
    engine: Engine = .auto,
};

/// A compiled pattern. Immutable after compile, so it may be shared between
/// threads; matching state lives in a Searcher.
pub const Regex = struct {
    /// Compiles a parsed pattern; shared by `compile` and `RegexSet`.
    fn compileParsed(gpa: std.mem.Allocator, parsed: parse.Parsed, options: Options, d: *Diagnostic) Error!Regex {
        const prog = try program.compile(gpa, parsed, options.limits, .{
            .utf8 = options.utf8,
            .longest = options.dialect == .posix_ere or options.dialect == .posix_bre,
            .engine = options.engine,
        }, d);
        return .{ .prog = prog, .limits = options.limits };
    }

    prog: program.Program,
    limits: Limits,

    /// `diag`, when given, receives the position and reason for a failure.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, options: Options, diag: ?*Diagnostic) Error!Regex {
        var scratch: Diagnostic = .{};
        const d = diag orelse &scratch;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = try parse.parse(arena_state.allocator(), gpa, pattern, options.dialect, options.ignore_case, options.utf8, options.limits, d);
        return compileParsed(gpa, parsed, options, d);
    }

    pub fn deinit(re: *Regex, gpa: std.mem.Allocator) void {
        re.prog.deinit(gpa);
    }

    /// The Regex must outlive the Searcher (it owns the program memory).
    pub fn searcher(re: *const Regex, gpa: std.mem.Allocator) !Searcher {
        return Searcher.init(gpa, re.prog, re.limits);
    }

    /// True when each search runs in time linear in the input (the DFA or the
    /// Pike VM). False when the backtracker runs the pattern, bounded only by
    /// `Limits.max_steps` and `max_stack`: because it needs it (back-reference,
    /// look-around, atomic group, possessive quantifier), because it is too
    /// large for the linear-time program (`max_program_len`; this can happen
    /// to a large Unicode repeat such as `\p{L}{40}` in any dialect), or
    /// because `Options.engine` asked for it. Check this before accepting
    /// untrusted patterns that must not backtrack. The bound is per `find`.
    pub fn isLinearTime(re: *const Regex) bool {
        return re.prog.engine != .backtrack;
    }

    /// Number of capture groups (not counting group 0).
    pub fn groupCount(re: *const Regex) u32 {
        return re.prog.group_count;
    }
};

/// Many patterns searched together (for `grep -f`). The combined pattern
/// matches wherever any member does; with leftmost-first dialects an earlier
/// pattern wins a tie at the same position. Capture groups are not reported
/// and back-references are rejected. Each pattern is also compiled alone, so
/// `matchedPatterns` can say which ones match.
pub const RegexSet = struct {
    all: Regex,
    each: []Regex,

    /// `diag.pattern` is the index of the pattern a failure is in.
    pub fn compile(gpa: std.mem.Allocator, patterns: []const []const u8, options: Options, diag: ?*Diagnostic) Error!RegexSet {
        var scratch: Diagnostic = .{};
        const d = diag orelse &scratch;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = try parse.parseSet(arena_state.allocator(), gpa, patterns, options.dialect, options.ignore_case, options.utf8, options.limits, d);
        var all = try Regex.compileParsed(gpa, parsed, options, d);
        errdefer all.deinit(gpa);
        const each = try gpa.alloc(Regex, patterns.len);
        var done: usize = 0;
        errdefer {
            for (each[0..done]) |*r| r.deinit(gpa);
            gpa.free(each);
        }
        for (patterns, 0..) |pat, i| {
            each[i] = Regex.compile(gpa, pat, options, d) catch |e| {
                d.pattern = i;
                return e;
            };
            done = i + 1;
        }
        return .{ .all = all, .each = each };
    }

    pub fn deinit(set: *RegexSet, gpa: std.mem.Allocator) void {
        for (set.each) |*r| r.deinit(gpa);
        gpa.free(set.each);
        set.all.deinit(gpa);
    }

    /// `Regex.isLinearTime` for the combined pattern and every member.
    pub fn isLinearTime(set: *const RegexSet) bool {
        for (set.each) |*re| if (!re.isLinearTime()) return false;
        return set.all.isLinearTime();
    }

    pub fn len(set: *const RegexSet) usize {
        return set.each.len;
    }

    /// A Searcher for the combined pattern: `find`, `isMatch`, `matches`, ...
    /// The set must outlive it.
    pub fn searcher(set: *const RegexSet, gpa: std.mem.Allocator) !Searcher {
        return set.all.searcher(gpa);
    }

    /// The indices (ascending) of the patterns that match somewhere in `hay`.
    /// The caller frees the result.
    pub fn matchedPatterns(set: *const RegexSet, gpa: std.mem.Allocator, hay: []const u8) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        errdefer out.deinit(gpa);
        for (set.each, 0..) |*re, i| {
            var s = try re.searcher(gpa);
            defer s.deinit();
            if (try s.isMatch(hay)) try out.append(gpa, i);
        }
        return out.toOwnedSlice(gpa);
    }
};

test {
    _ = @import("stream.zig");
    _ = @import("byteset.zig");
    _ = @import("utf8.zig");
    _ = @import("unicode.zig");
    _ = @import("tests.zig");
}

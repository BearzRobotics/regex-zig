//! regex-zig: a pure-Zig regular-expression library (see SPEC.md).
//!
//! Current state: the Perl, Oniguruma and POSIX ERE parsers and the bounded
//! backtracking engine, with isMatch/matches/count/findAll/split/replaceAll
//! helpers on Searcher (ops.zig), and phase 1 of UTF-8 matching (Options.utf8).
//! POSIX BRE, the Rust dialect, the linear-time engine, Unicode properties and
//! case folding, and streaming are not implemented yet.

const std = @import("std");
const parse = @import("parse.zig");
const program = @import("program.zig");
const backtrack = @import("backtrack.zig");
const ops = @import("ops.zig");

pub const Dialect = parse.Dialect;
pub const Limits = parse.Limits;
pub const Error = parse.Error;
pub const Diagnostic = parse.Diagnostic;
pub const MatchError = backtrack.MatchError;
pub const Match = backtrack.Match;
pub const Searcher = backtrack.Searcher;
pub const Span = ops.Span;
pub const Matches = ops.Matches;
pub const ReplaceError = ops.ReplaceError;

pub const Options = struct {
    dialect: Dialect = .perl,
    ignore_case: bool = false,
    /// Match over UTF-8: the pattern must be valid UTF-8, and `.`, classes,
    /// negation and `\x{...}` work on Unicode scalar values. Invalid UTF-8 in
    /// the haystack never matches `.` or a class and never causes a crash.
    /// See docs/decisions/0001-utf8-matching.md for what is not covered yet.
    utf8: bool = false,
    limits: Limits = .{},
};

/// A compiled pattern. Immutable after compile, so it may be shared between
/// threads; matching state lives in a Searcher.
pub const Regex = struct {
    prog: program.Program,
    limits: Limits,

    /// `diag`, when given, receives the position and reason for a failure.
    pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, options: Options, diag: ?*Diagnostic) Error!Regex {
        var scratch: Diagnostic = .{};
        const d = diag orelse &scratch;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const parsed = try parse.parse(arena_state.allocator(), pattern, options.dialect, options.ignore_case, options.utf8, options.limits, d);
        const prog = try program.compile(gpa, parsed, options.limits, options.utf8, d);
        return .{ .prog = prog, .limits = options.limits };
    }

    pub fn deinit(re: *Regex, gpa: std.mem.Allocator) void {
        re.prog.deinit(gpa);
    }

    /// The Regex must outlive the Searcher (it owns the program memory).
    pub fn searcher(re: *const Regex, gpa: std.mem.Allocator) !Searcher {
        return Searcher.init(gpa, re.prog, re.limits);
    }

    /// Number of capture groups (not counting group 0).
    pub fn groupCount(re: *const Regex) u32 {
        return re.prog.group_count;
    }
};

test {
    _ = @import("byteset.zig");
    _ = @import("utf8.zig");
    _ = @import("tests.zig");
}

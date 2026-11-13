//! regex-zig: a pure-Zig regular-expression library (see SPEC.md).
//!
//! Current state: the Perl, Oniguruma and POSIX ERE parsers and the bounded
//! backtracking engine. POSIX BRE, the Rust dialect, the linear-time engine,
//! UTF-8 and streaming are not implemented yet.

const std = @import("std");
const parse = @import("parse.zig");
const program = @import("program.zig");
const backtrack = @import("backtrack.zig");

pub const Dialect = parse.Dialect;
pub const Limits = parse.Limits;
pub const Error = parse.Error;
pub const Diagnostic = parse.Diagnostic;
pub const MatchError = backtrack.MatchError;
pub const Match = backtrack.Match;
pub const Searcher = backtrack.Searcher;

pub const Options = struct {
    dialect: Dialect = .perl,
    ignore_case: bool = false,
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
        const parsed = try parse.parse(arena_state.allocator(), pattern, options.dialect, options.ignore_case, options.limits, d);
        const prog = try program.compile(gpa, parsed, options.limits, d);
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
    _ = @import("tests.zig");
}

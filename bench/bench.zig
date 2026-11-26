// SPDX-License-Identifier: LGPL-2.0-or-later
//! Benchmarks (`zig build bench`, always built with ReleaseFast).
//!
//! Each case runs a pattern over a generated haystack several times and
//! reports the best time. Haystacks are deterministic, so numbers are
//! comparable between runs on the same machine; they are not comparable
//! between machines. No performance claim should be made without a baseline
//! from this program (docs: ai/AGENTS.md section 6).
//!
//! Pathological cases use the default limits and report what the engine does
//! (match, no match, or a limit error) instead of a throughput.

const std = @import("std");
const regex = @import("regex");

const Kind = enum { prose, ascii_a, unicode_text, long_lines };

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    kind: Kind,
    size: usize,
    options: regex.Options = .{},
    /// Count every match in the haystack (true) or just find the first (false).
    all: bool = true,
};

const no_step_limit: regex.Limits = .{ .max_steps = std.math.maxInt(u64) };

const throughput_cases = [_]Case{
    .{ .name = "literal prefix + class", .pattern = "needle[0-9]+", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "ERE alternation (longest)", .pattern = "quick|lazy|brown|fox", .kind = .prose, .size = 4 << 20, .options = .{ .dialect = .posix_ere, .limits = no_step_limit } },
    .{ .name = "literal, absent", .pattern = "zqxjv", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "literal, many", .pattern = "the", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "alternation of words", .pattern = "quick|lazy|brown|fox", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "class run [a-z]+", .pattern = "[a-z]+", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "word boundary \\bfox\\b", .pattern = "\\bfox\\b", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "email-like", .pattern = "[a-z]+@[a-z]+\\.com", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "greedy .* per line", .pattern = "^.*$", .kind = .long_lines, .size = 1 << 20, .options = .{ .limits = no_step_limit, .dialect = .oniguruma } },
    .{ .name = "case-insensitive literal", .pattern = "(?i)quick", .kind = .prose, .size = 4 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "capture groups", .pattern = "(\\w+) (\\w+)", .kind = .prose, .size = 1 << 20, .options = .{ .limits = no_step_limit } },
    .{ .name = "utf8 .+", .pattern = ".+", .kind = .unicode_text, .size = 1 << 20, .options = .{ .utf8 = true, .limits = no_step_limit } },
    .{ .name = "utf8 \\p{L}+", .pattern = "\\p{L}+", .kind = .unicode_text, .size = 1 << 20, .options = .{ .utf8 = true, .limits = no_step_limit } },
    .{ .name = "utf8 (?i) literal", .pattern = "(?i)éa", .kind = .unicode_text, .size = 1 << 20, .options = .{ .utf8 = true, .limits = no_step_limit } },
    .{ .name = "utf8 [^a] run", .pattern = "[^a]+", .kind = .unicode_text, .size = 1 << 20, .options = .{ .utf8 = true, .limits = no_step_limit } },
};

/// Line-search cases (the grep question: does each line match?), run through
/// `Searcher.matchingLines` the way util-core's grep does.
const line_cases = [_]Case{
    .{ .name = "lines ^[a-m]+[[:space:]][n-z]+", .pattern = "^[a-m]+[[:space:]][n-z]+", .kind = .prose, .size = 10 << 20, .options = .{ .dialect = .posix_ere } },
    .{ .name = "lines -x (two|the)s?", .pattern = "^((two|the)s?)$", .kind = .prose, .size = 10 << 20, .options = .{ .dialect = .posix_ere } },
    .{ .name = "lines (two|the)s?", .pattern = "(two|the)s?", .kind = .prose, .size = 10 << 20, .options = .{ .dialect = .posix_ere } },
    .{ .name = "lines literal fox", .pattern = "fox", .kind = .prose, .size = 10 << 20, .options = .{ .dialect = .posix_ere } },
    .{ .name = "lines literal absent", .pattern = "zqxjv", .kind = .prose, .size = 10 << 20, .options = .{ .dialect = .posix_ere } },
    .{ .name = "lines utf8 .", .pattern = ".", .kind = .unicode_text, .size = 10 << 20, .options = .{ .dialect = .posix_ere, .utf8 = true } },
    .{ .name = "lines utf8 -i the", .pattern = "the", .kind = .unicode_text, .size = 10 << 20, .options = .{ .dialect = .posix_ere, .utf8 = true, .ignore_case = true } },
    .{ .name = "lines utf8 -i café", .pattern = "CAFÉ", .kind = .unicode_text, .size = 10 << 20, .options = .{ .dialect = .posix_ere, .utf8 = true, .ignore_case = true } },
};

const Pathological = struct { name: []const u8, pattern: []const u8, unit: []const u8, repeats: usize, tail: []const u8 };

const pathological_cases = [_]Pathological{
    .{ .name = "(a*)*b", .pattern = "(a*)*b", .unit = "a", .repeats = 30, .tail = "" },
    .{ .name = "(a+)+$", .pattern = "(a+)+$", .unit = "a", .repeats = 30, .tail = "!" },
    .{ .name = "(a|aa)+$", .pattern = "(a|aa)+$", .unit = "a", .repeats = 40, .tail = "!" },
    .{ .name = "(x+x+)+y", .pattern = "(x+x+)+y", .unit = "x", .repeats = 40, .tail = "" },
    .{ .name = "(a*)*b, long input", .pattern = "(a*)*b", .unit = "a", .repeats = 100_000, .tail = "" },
    .{ .name = "a?^n a^n", .pattern = "(a?){30}a{30}", .unit = "a", .repeats = 30, .tail = "" },
};

const words = [_][]const u8{
    "the",   "quick", "brown", "fox", "jumps",             "over",  "lazy",            "dog", "and",  "then",
    "runs",  "away",  "from",  "a",   "very",              "angry", "farmer",          "who", "owns", "this",
    "field", "mail",  "me",    "at",  "alice@example.com", "or",    "bob@example.org",
};

const uwords = [_][]const u8{
    "café",
    "naïve",
    "über",
    "straße",
    "привет",
    "мир",
    "日本語",
    "漢字",
    "ひらがな",
    "Ελληνικά",
    "éa",
    "ÉA",
    "the",
    "a",
    "fox",
    "résumé",
    "Ünïcödé",
    "🙂",
    "emoji",
    "words",
};

fn generate(gpa: std.mem.Allocator, kind: Kind, size: usize) ![]u8 {
    var buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    if (kind == .ascii_a) {
        @memset(buf, 'a');
        return buf;
    }
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const r = rng.random();
    var n: usize = 0;
    var line: usize = 0;
    while (n < size) {
        const w = switch (kind) {
            .unicode_text => uwords[r.uintLessThan(usize, uwords.len)],
            else => words[r.uintLessThan(usize, words.len)],
        };
        const sep: u8 = if (kind == .long_lines) (if (line > 2000) '\n' else ' ') else (if (r.uintLessThan(u8, 12) == 0) '\n' else ' ');
        if (n + w.len + 1 > size) break;
        @memcpy(buf[n..][0..w.len], w);
        n += w.len;
        buf[n] = sep;
        n += 1;
        line = if (sep == '\n') 0 else line + w.len + 1;
    }
    // Pad (never cut a character: pad with spaces).
    @memset(buf[n..], ' ');
    return buf;
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn runThroughput(io: std.Io, gpa: std.mem.Allocator, c: Case) !void {
    const hay = try generate(gpa, c.kind, c.size);
    defer gpa.free(hay);

    const t0 = now(io);
    var re = try regex.Regex.compile(gpa, c.pattern, c.options, null);
    defer re.deinit(gpa);
    const compile_ns = now(io) - t0;

    var s = try re.searcher(gpa);
    defer s.deinit();

    var best: i96 = std.math.maxInt(i96);
    var matches: usize = 0;
    var failure: ?anyerror = null;
    for (0..5) |_| {
        const start = now(io);
        const n = if (c.all) s.count(hay) else blk: {
            const m = s.find(hay, 0) catch |e| break :blk e;
            break :blk @as(anyerror!usize, if (m != null) 1 else 0);
        };
        const elapsed = now(io) - start;
        if (n) |v| {
            matches = v;
            best = @min(best, elapsed);
        } else |e| {
            failure = e;
            break;
        }
    }
    if (failure) |e| {
        std.debug.print("{s:<28} compile {d:>7} ns   FAILED: {s}\n", .{ c.name, @as(u64, @intCast(compile_ns)), @errorName(e) });
        return;
    }
    const secs = @as(f64, @floatFromInt(best)) / 1e9;
    const mb = @as(f64, @floatFromInt(hay.len)) / (1024.0 * 1024.0);
    std.debug.print("{s:<28} compile {d:>7} ns   {d:>9.2} ms   {d:>8.1} MB/s   {d} matches\n", .{ c.name, @as(u64, @intCast(compile_ns)), secs * 1000.0, mb / secs, matches });
}

fn runLines(io: std.Io, gpa: std.mem.Allocator, c: Case) !void {
    const hay = try generate(gpa, c.kind, c.size);
    defer gpa.free(hay);
    var re = try regex.Regex.compile(gpa, c.pattern, c.options, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();
    var best: i96 = std.math.maxInt(i96);
    var n: usize = 0;
    for (0..5) |_| {
        const start = now(io);
        var it = s.matchingLines(hay, false);
        n = 0;
        while (try it.next()) |_| n += 1;
        best = @min(best, now(io) - start);
    }
    const secs = @as(f64, @floatFromInt(best)) / 1e9;
    const mb = @as(f64, @floatFromInt(hay.len)) / (1024.0 * 1024.0);
    std.debug.print("{s:<32} {d:>9.2} ms   {d:>8.1} MB/s   {d} lines\n", .{ c.name, secs * 1000.0, mb / secs, n });
}

/// A RegexSet of many words (`grep -f words`), searched line by line.
fn runSet(io: std.Io, gpa: std.mem.Allocator, nwords: usize) !void {
    const hay = try generate(gpa, .prose, 10 << 20);
    defer gpa.free(hay);
    var rng = std.Random.DefaultPrng.init(0xfeed);
    const r = rng.random();
    var store: std.ArrayList(u8) = .empty;
    defer store.deinit(gpa);
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(gpa);
    var offs: std.ArrayList([2]usize) = .empty;
    defer offs.deinit(gpa);
    for (0..nwords) |_| {
        const len = 5 + r.uintLessThan(usize, 6);
        const o = store.items.len;
        for (0..len) |_| try store.append(gpa, 'a' + r.uintLessThan(u8, 26));
        try offs.append(gpa, .{ o, store.items.len });
    }
    for (offs.items) |o| try pats.append(gpa, store.items[o[0]..o[1]]);
    const t0 = now(io);
    var set = try regex.RegexSet.compile(gpa, pats.items, .{ .dialect = .posix_ere }, null);
    defer set.deinit(gpa);
    const compile_ms = @as(f64, @floatFromInt(now(io) - t0)) / 1e6;
    var s = try set.searcher(gpa);
    defer s.deinit();
    var best: i96 = std.math.maxInt(i96);
    var n: usize = 0;
    for (0..3) |_| {
        const start = now(io);
        var it = s.matchingLines(hay, false);
        n = 0;
        while (try it.next()) |_| n += 1;
        best = @min(best, now(io) - start);
    }
    const secs = @as(f64, @floatFromInt(best)) / 1e9;
    std.debug.print("set of {d:<5} words, lines      {d:>9.2} ms   (compile {d:.1} ms)   {d} lines\n", .{ nwords, secs * 1000.0, compile_ms, n });
}

fn runPathological(io: std.Io, gpa: std.mem.Allocator, c: Pathological) !void {
    const hay = try gpa.alloc(u8, c.unit.len * c.repeats + c.tail.len);
    defer gpa.free(hay);
    for (0..c.repeats) |i| @memcpy(hay[i * c.unit.len ..][0..c.unit.len], c.unit);
    @memcpy(hay[c.unit.len * c.repeats ..], c.tail);

    var re = try regex.Regex.compile(gpa, c.pattern, .{}, null);
    defer re.deinit(gpa);
    var s = try re.searcher(gpa);
    defer s.deinit();

    const start = now(io);
    const result = s.find(hay, 0);
    const ms = @as(f64, @floatFromInt(now(io) - start)) / 1e6;
    if (result) |m| {
        std.debug.print("{s:<28} n={d:<7} {d:>9.2} ms   {s}\n", .{ c.name, c.repeats, ms, if (m != null) "match" else "no match" });
    } else |e| {
        std.debug.print("{s:<28} n={d:<7} {d:>9.2} ms   {s}\n", .{ c.name, c.repeats, ms, @errorName(e) });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    std.debug.print("regex-zig benchmarks (best of 5; ReleaseFast)\n\n", .{});
    std.debug.print("-- throughput --\n", .{});
    for (throughput_cases) |c| try runThroughput(io, gpa, c);
    std.debug.print("\n-- line search (10 MB) --\n", .{});
    for (line_cases) |c| try runLines(io, gpa, c);
    for ([_]usize{ 10, 300, 3000 }) |n| try runSet(io, gpa, n);
    std.debug.print("\n-- pathological patterns, default limits --\n", .{});
    for (pathological_cases) |c| try runPathological(io, gpa, c);
}

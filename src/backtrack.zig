//! Backtracking VM for patterns that need back-references, look-around,
//! atomic groups or possessive quantifiers (SPEC §2.3). It uses an explicit,
//! bounded stack instead of recursion, and a step budget, so hostile patterns
//! produce an error instead of a crash or an unbounded run.

const std = @import("std");
const program = @import("program.zig");
const parse = @import("parse.zig");
const ByteSet = @import("byteset.zig").ByteSet;
const ops = @import("ops.zig");
const context = @import("context.zig");
const pike = @import("pike.zig");
const utf8 = @import("utf8.zig");
const unicode = @import("unicode.zig");

const Program = program.Program;
const unset = program.unset;

pub const MatchError = error{
    OutOfMemory,
    StepLimitExceeded,
    StackLimitExceeded,
};

const Frame = union(enum) {
    /// Alternative to try after a failure.
    branch: struct { pc: u32, pos: usize },
    /// Undo a register write.
    restore: struct { reg: u32, old: usize },
    /// Barrier for atomic groups and look-around.
    marker: struct { kind: Kind, pos: usize, resume_pc: u32 },

    const Kind = enum { atomic, look, neg_look };
};

pub const Match = struct {
    regs: []const usize,

    pub fn start(m: Match) usize {
        return m.regs[0];
    }

    pub fn end(m: Match) usize {
        return m.regs[1];
    }

    /// Span of capture group `i` (0 = whole match), or null if it did not
    /// participate.
    pub fn group(m: Match, i: u32) ?[2]usize {
        const a = m.regs[2 * i];
        const b = m.regs[2 * i + 1];
        if (a == unset or b == unset) return null;
        return .{ a, b };
    }
};

/// Per-search mutable state. A compiled Program may be shared; each thread
/// needs its own Searcher.
pub const Searcher = struct {
    gpa: std.mem.Allocator,
    /// Copy of the compiled program's slices; the Regex that owns the memory
    /// must outlive this Searcher, but may be moved.
    prog: Program,
    limits: parse.Limits,
    regs: []usize,
    /// Leftmost-longest mode: the longest match found so far from this start.
    best: []usize = &.{},
    have_best: bool = false,
    /// The Pike VM, when the program was compiled for it (see Program.engine).
    pike: ?pike.Pike = null,
    stack: std.ArrayList(Frame) = .empty,
    steps: u64 = 0,
    /// Position recorded by the marker most recently removed by cutToMarker.
    cut_pos: usize = 0,

    pub const isMatch = ops.isMatch;
    pub const matches = ops.matches;
    pub const count = ops.count;
    pub const findAll = ops.findAll;
    pub const split = ops.split;
    pub const replaceAll = ops.replaceAll;

    pub fn init(gpa: std.mem.Allocator, prog: Program, limits: parse.Limits) !Searcher {
        const regs = try gpa.alloc(usize, prog.reg_count);
        errdefer gpa.free(regs);
        var best: []usize = &.{};
        if (prog.longest and prog.engine == .backtrack) best = try gpa.alloc(usize, prog.reg_count);
        errdefer if (best.len > 0) gpa.free(best);
        var vm: ?pike.Pike = null;
        if (prog.engine == .pike) vm = try pike.Pike.init(gpa, prog);
        return .{ .gpa = gpa, .prog = prog, .limits = limits, .regs = regs, .best = best, .pike = vm };
    }

    pub fn deinit(s: *Searcher) void {
        s.gpa.free(s.regs);
        if (s.best.len > 0) s.gpa.free(s.best);
        if (s.pike) |*vm| vm.deinit();
        s.stack.deinit(s.gpa);
    }

    /// Leftmost match at or after `from`. The returned Match borrows the
    /// searcher's registers and is valid until the next call.
    pub fn find(s: *Searcher, hay: []const u8, from: usize) MatchError!?Match {
        if (s.pike) |*vm| {
            const regs = vm.find(hay, from) orelse return null;
            return .{ .regs = regs };
        }
        s.steps = 0;
        var start = from;
        const first = s.prog.first_bytes;
        while (start <= hay.len) : (start += 1) {
            // In utf8 mode a match never starts inside a character. A stray
            // continuation byte is skipped too: nothing can match it anyway.
            if (s.prog.utf8 and start < hay.len and hay[start] & 0xC0 == 0x80) continue;
            if (first) |set| {
                // A pattern that cannot match empty needs a byte here.
                if (start == hay.len) break;
                if (!set.has(hay[start])) continue;
            }
            @memset(s.regs, unset);
            s.stack.clearRetainingCapacity();
            if (try s.run(hay, start, from)) return .{ .regs = s.regs };
        }
        return null;
    }

    fn push(s: *Searcher, f: Frame) MatchError!void {
        if (s.stack.items.len >= s.limits.max_stack) return error.StackLimitExceeded;
        try s.stack.append(s.gpa, f);
    }

    fn setReg(s: *Searcher, reg: u32, val: usize) MatchError!void {
        try s.push(.{ .restore = .{ .reg = reg, .old = s.regs[reg] } });
        s.regs[reg] = val;
    }

    /// Pop frames until a branch (or a succeeding negative look) gives a new
    /// place to continue. Returns null when nothing is left.
    fn backtrack(s: *Searcher, pos: *usize) ?u32 {
        while (s.stack.pop()) |f| switch (f) {
            .restore => |r| s.regs[r.reg] = r.old,
            .branch => |b| {
                pos.* = b.pos;
                return b.pc;
            },
            .marker => |m| if (m.kind == .neg_look) {
                // The negative look's body failed everywhere: the look holds.
                pos.* = m.pos;
                return m.resume_pc;
            },
        };
        return null;
    }

    /// Remove the nearest marker and every choice point above it, keeping the
    /// register-restore records so a later failure still undoes captures.
    fn cutToMarker(s: *Searcher) Frame.Kind {
        var i = s.stack.items.len;
        while (i > 0) {
            i -= 1;
            if (s.stack.items[i] == .marker) break;
        }
        const marker = s.stack.items[i].marker;
        var w = i;
        for (s.stack.items[i + 1 ..]) |f| {
            if (f == .restore) {
                s.stack.items[w] = f;
                w += 1;
            }
        }
        s.stack.shrinkRetainingCapacity(w);
        s.cut_pos = marker.pos;
        return marker.kind;
    }

    /// Leftmost-longest mode, after the search from one start is exhausted:
    /// the best match found, if any.
    fn finishRun(s: *Searcher) bool {
        if (!s.have_best) return false;
        @memcpy(s.regs, s.best);
        return true;
    }

    fn run(s: *Searcher, hay: []const u8, start: usize, search_start: usize) MatchError!bool {
        s.have_best = false;
        const insts = s.prog.insts;
        var pc: u32 = 0;
        var pos = start;
        while (true) {
            s.steps += 1;
            if (s.steps > s.limits.max_steps) return error.StepLimitExceeded;
            var ok = true;
            switch (insts[pc]) {
                .byte => |b| if (pos < hay.len and hay[pos] == b) {
                    pos += 1;
                    pc += 1;
                } else {
                    ok = false;
                },
                .any => if (pos < hay.len and hay[pos] != '\n') {
                    pos += 1;
                    pc += 1;
                } else {
                    ok = false;
                },
                .any_nl => if (pos < hay.len) {
                    pos += 1;
                    pc += 1;
                } else {
                    ok = false;
                },
                .set => |i| if (pos < hay.len and s.prog.sets[i].has(hay[pos])) {
                    pos += 1;
                    pc += 1;
                } else {
                    ok = false;
                },
                .cp_class => |i| if (context.decodeAt(hay, pos)) |d| {
                    if (utf8.containsRange(s.prog.cp_sets[i], d.cp)) {
                        pos += d.len;
                        pc += 1;
                    } else ok = false;
                } else {
                    ok = false;
                },
                .split => |sp| {
                    try s.push(.{ .branch = .{ .pc = sp.second, .pos = pos } });
                    pc = sp.first;
                },
                .jmp => |t| pc = t,
                .save => |r| {
                    try s.setReg(r, pos);
                    pc += 1;
                },
                .assertion => |a| if (context.check(a, hay, pos, search_start, s.prog.utf8)) {
                    pc += 1;
                } else {
                    ok = false;
                },
                .backref => |b| {
                    const a = s.regs[2 * b.index];
                    const e = s.regs[2 * b.index + 1];
                    // A group that did not participate makes the reference fail.
                    if (a == unset or e == unset) {
                        ok = false;
                    } else if (backrefLen(hay, a, e, pos, b.ignore_case, s.prog.utf8)) |n| {
                        pos += n;
                        pc += 1;
                    } else ok = false;
                },
                .atomic_start => {
                    try s.push(.{ .marker = .{ .kind = .atomic, .pos = pos, .resume_pc = 0 } });
                    pc += 1;
                },
                .atomic_end => {
                    _ = s.cutToMarker();
                    pc += 1;
                },
                .look_start => |l| {
                    try s.push(.{ .marker = .{
                        .kind = if (l.negate) .neg_look else .look,
                        .pos = pos,
                        .resume_pc = l.end,
                    } });
                    pc += 1;
                },
                .look_end => {
                    const kind = s.cutToMarker();
                    if (kind == .neg_look) {
                        ok = false; // body matched, so the negative look fails
                    } else {
                        pos = s.cut_pos;
                        pc += 1;
                    }
                },
                .back => |n| if (pos >= n) {
                    pos -= n;
                    pc += 1;
                } else {
                    ok = false;
                },
                .mark => |slot| {
                    try s.setReg(slot, pos);
                    pc += 1;
                },
                .loop_end => |l| pc = if (s.regs[l.slot] == pos) pc + 1 else l.target,
                .match => if (s.prog.longest) {
                    // Keep the longest; go on exploring the other alternatives.
                    if (!s.have_best or s.regs[1] > s.best[1]) {
                        @memcpy(s.best, s.regs);
                        s.have_best = true;
                    }
                    ok = false;
                } else return true,
            }
            if (!ok) pc = s.backtrack(&pos) orelse return s.finishRun();
        }
    }
};

/// Length of the text at `pos` that equals the captured text hay[a..e], or
/// null. Case-insensitive comparison in utf8 mode works on characters (simple
/// case folding), so the two texts may differ in byte length.
fn backrefLen(hay: []const u8, a: usize, e: usize, pos: usize, ignore_case: bool, utf8_mode: bool) ?usize {
    if (!ignore_case or !utf8_mode) {
        const len = e - a;
        if (hay.len - pos >= len and eqlBytes(hay[a..e], hay[pos..][0..len], ignore_case)) return len;
        return null;
    }
    var i = a;
    var j = pos;
    while (i < e) {
        const x = context.decodeAt(hay, i);
        const y = context.decodeAt(hay, j);
        if (x != null and y != null and i + x.?.len <= e) {
            if (!unicode.eqlFold(x.?.cp, y.?.cp)) return null;
            i += x.?.len;
            j += y.?.len;
        } else {
            // Not a whole character: compare the bytes themselves.
            if (j >= hay.len or hay[j] != hay[i]) return null;
            i += 1;
            j += 1;
        }
    }
    return j - pos;
}

fn eqlBytes(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

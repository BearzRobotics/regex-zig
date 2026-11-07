//! Compiled program for the backtracking VM, and the compiler from the AST.

const std = @import("std");
const ast = @import("ast.zig");
const parse = @import("parse.zig");
const ByteSet = @import("byteset.zig").ByteSet;

pub const unset = std.math.maxInt(usize);

pub const Inst = union(enum) {
    byte: u8,
    any, // any byte except '\n'
    any_nl, // any byte
    set: u32, // index into Program.sets
    /// Try `first`; on failure resume at `second`.
    split: struct { first: u32, second: u32 },
    jmp: u32,
    /// regs[n] = current position (restored on backtrack).
    save: u32,
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

pub const Program = struct {
    insts: []const Inst,
    /// Bytes a match can start with, or null when the pattern can match the
    /// empty string (or the set cannot be bounded). Used to skip start
    /// positions without running the VM.
    first_bytes: ?ByteSet,
    sets: []const ByteSet,
    group_count: u32,
    reg_count: u32,
    names: []const parse.Name,

    pub fn deinit(prog: Program, gpa: std.mem.Allocator) void {
        gpa.free(prog.insts);
        gpa.free(prog.sets);
        for (prog.names) |n| gpa.free(n.name);
        gpa.free(prog.names);
    }
};

const Compiler = struct {
    gpa: std.mem.Allocator,
    limits: parse.Limits,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList(ByteSet) = .empty,
    loop_slots: u32 = 0,
    group_count: u32,
    depth: u32 = 0,
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
        switch (n.*) {
            .empty => {},
            .byte => |b| _ = try c.emit(.{ .byte = b }),
            .any => |nl| _ = try c.emit(if (nl) .any_nl else .any),
            .set => |s| {
                try c.sets.append(c.gpa, s);
                _ = try c.emit(.{ .set = @intCast(c.sets.items.len - 1) });
            },
            .concat => |items| for (items) |it| try c.compile(it),
            .alt => |alts| try c.compileAlt(alts, null),
            .repeat => |r| try c.compileRepeat(r),
            .group => |g| {
                if (g.index) |i| {
                    _ = try c.emit(.{ .save = 2 * i });
                    try c.compile(g.sub);
                    _ = try c.emit(.{ .save = 2 * i + 1 });
                } else try c.compile(g.sub);
            },
            .atomic => |sub| {
                _ = try c.emit(.atomic_start);
                try c.compile(sub);
                _ = try c.emit(.atomic_end);
            },
            .look => |l| try c.compileLook(l),
            .assertion => |a| _ = try c.emit(.{ .assertion = a }),
            .backref => |b| _ = try c.emit(.{ .backref = .{ .index = b.index, .ignore_case = b.ignore_case } }),
        }
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
                widths[i] = fixedWidth(a) orelse
                    return c.unsupported("look-behind must have a fixed width");
            }
            try c.compileAlt(alts, widths);
        }
        _ = try c.emit(.look_end);
        c.insts.items[start] = .{ .look_start = .{ .negate = l.negate, .end = c.here() } };
    }

    fn compileRepeat(c: *Compiler, r: ast.Repeat) parse.Error!void {
        if (r.greed == .possessive) {
            _ = try c.emit(.atomic_start);
            try c.compileRepeatBody(r);
            _ = try c.emit(.atomic_end);
        } else try c.compileRepeatBody(r);
    }

    fn compileRepeatBody(c: *Compiler, r: ast.Repeat) parse.Error!void {
        const lazy = r.greed == .lazy;
        var i: u32 = 0;
        while (i < r.min) : (i += 1) try c.compile(r.sub);

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

        // Unbounded tail: L: split(body, exit); body; jmp L; exit:
        const loop = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
        var slot: ?u32 = null;
        if (canBeEmpty(r.sub)) {
            slot = 2 * (c.group_count + 1) + c.loop_slots;
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

/// Width in bytes if every match of `n` has the same length.
fn fixedWidth(n: *const ast.Node) ?u32 {
    return switch (n.*) {
        .empty, .assertion, .look => 0,
        .byte, .any, .set => 1,
        .concat => |items| blk: {
            var total: u32 = 0;
            for (items) |it| total +|= fixedWidth(it) orelse break :blk null;
            break :blk total;
        },
        .alt => |alts| blk: {
            const w = fixedWidth(alts[0]) orelse break :blk null;
            for (alts[1..]) |a| if (fixedWidth(a) != w) break :blk null;
            break :blk w;
        },
        .repeat => |r| blk: {
            const max = r.max orelse break :blk null;
            if (max != r.min) break :blk null;
            break :blk (fixedWidth(r.sub) orelse break :blk null) *| r.min;
        },
        .group => |g| fixedWidth(g.sub),
        .atomic => |sub| fixedWidth(sub),
        .backref => null,
    };
}

fn canBeEmpty(n: *const ast.Node) bool {
    return switch (n.*) {
        .empty, .assertion, .look, .backref => true,
        .byte, .any, .set => false,
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

/// Compile a parsed pattern. The returned Program owns gpa memory (and copies
/// the group names out of the parser arena).
pub fn compile(gpa: std.mem.Allocator, parsed: parse.Parsed, limits: parse.Limits, diag: *parse.Diagnostic) parse.Error!Program {
    var c: Compiler = .{ .gpa = gpa, .limits = limits, .group_count = parsed.group_count, .diag = diag };
    errdefer c.insts.deinit(gpa);
    errdefer c.sets.deinit(gpa);

    _ = try c.emit(.{ .save = 0 }); // match start; also anchors \G-free scanning
    try c.compile(parsed.root);
    _ = try c.emit(.{ .save = 1 });
    _ = try c.emit(.match);

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

    const insts = try c.insts.toOwnedSlice(gpa);
    errdefer gpa.free(insts);
    const sets = try c.sets.toOwnedSlice(gpa);
    const first = firstOf(parsed.root);
    return .{
        .insts = insts,
        .first_bytes = if (first.nullable) null else first.set,
        .sets = sets,
        .group_count = parsed.group_count,
        .reg_count = 2 * (parsed.group_count + 1) + c.loop_slots,
        .names = names,
    };
}

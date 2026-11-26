// SPDX-License-Identifier: LGPL-2.0-or-later
//! Pike VM: runs the NFA program (program.zig, `Nfa`) over the haystack one
//! byte at a time, keeping every live thread, so the work is bounded by
//! (program size) x (input size) whatever the pattern. See
//! docs/decisions/0002-matching-engines.md.
//!
//! Threads are kept in priority order. In leftmost-first mode the first
//! thread to reach `match` cuts off all lower-priority threads; in
//! leftmost-longest mode the earliest start wins, then the longest end.
//! Each thread carries its own capture array.
//!
//! A search allocates nothing: lists, capture arrays and the closure stack
//! are sized once, when the Pike is created.

const std = @import("std");
const program = @import("program.zig");
const context = @import("context.zig");
const ByteSet = @import("byteset.zig").ByteSet;

const Inst = program.Inst;
const unset = program.unset;

const Frame = union(enum) {
    /// Expand the closure from this instruction.
    visit: u32,
    /// Undo a capture write after the branch that made it is finished.
    restore: struct { slot: u32, old: usize },
};

/// The threads at one input position.
const List = struct {
    /// Sparse set of instructions already reached at this position.
    dense: []u32,
    sparse: []u32,
    len: usize = 0,
    /// The threads (consuming instructions and `match`), in priority order.
    thread_pc: []u32,
    thread_caps: []usize,
    nthreads: usize = 0,

    /// `n` instructions, of which `slots` can hold a thread.
    fn init(gpa: std.mem.Allocator, n: usize, slots: usize, ncap: usize) !List {
        const dense = try gpa.alloc(u32, n);
        errdefer gpa.free(dense);
        const sparse = try gpa.alloc(u32, n);
        errdefer gpa.free(sparse);
        const thread_pc = try gpa.alloc(u32, slots);
        errdefer gpa.free(thread_pc);
        const thread_caps = try gpa.alloc(usize, slots * ncap);
        return .{ .dense = dense, .sparse = sparse, .thread_pc = thread_pc, .thread_caps = thread_caps };
    }

    fn deinit(l: *List, gpa: std.mem.Allocator) void {
        gpa.free(l.dense);
        gpa.free(l.sparse);
        gpa.free(l.thread_pc);
        gpa.free(l.thread_caps);
    }

    fn reset(l: *List) void {
        l.len = 0;
        l.nthreads = 0;
    }

    fn contains(l: *const List, pc: u32) bool {
        const i = l.sparse[pc];
        return i < l.len and l.dense[i] == pc;
    }

    fn mark(l: *List, pc: u32) void {
        l.sparse[pc] = @intCast(l.len);
        l.dense[l.len] = pc;
        l.len += 1;
    }

    fn addThread(l: *List, pc: u32, caps: []const usize) void {
        l.thread_pc[l.nthreads] = pc;
        @memcpy(l.thread_caps[l.nthreads * caps.len ..][0..caps.len], caps);
        l.nthreads += 1;
    }
};

pub const Pike = struct {
    gpa: std.mem.Allocator,
    insts: []const Inst,
    sets: []const ByteSet,
    first_bytes: ?ByteSet,
    ncap: usize,
    utf8: bool,
    longest: bool,
    clist: List,
    nlist: List,
    stack: std.ArrayList(Frame),
    /// Captures of the thread being expanded.
    caps: []usize,
    /// Captures of the best match found so far; the result of `find`.
    best: []usize,

    /// `prog.nfa` must be set. Borrows the program's slices: the Regex that
    /// owns them must outlive the Pike.
    pub fn init(gpa: std.mem.Allocator, prog: program.Program) !Pike {
        const nfa = prog.nfa.?;
        const n = nfa.insts.len;
        const ncap = 2 * (prog.group_count + 1);
        const slots = nfa.threadSlots();
        var clist = try List.init(gpa, n, slots, ncap);
        errdefer clist.deinit(gpa);
        var nlist = try List.init(gpa, n, slots, ncap);
        errdefer nlist.deinit(gpa);
        // Each instruction is visited once per closure and pushes at most one
        // frame for a split and one for a capture, so 2n+2 frames suffice and
        // the search never allocates.
        var stack: std.ArrayList(Frame) = .empty;
        errdefer stack.deinit(gpa);
        try stack.ensureTotalCapacity(gpa, 2 * n + 2);
        const caps = try gpa.alloc(usize, ncap);
        errdefer gpa.free(caps);
        const best = try gpa.alloc(usize, ncap);
        return .{
            .gpa = gpa,
            .insts = nfa.insts,
            .sets = nfa.sets,
            .first_bytes = prog.first_bytes,
            .ncap = ncap,
            .utf8 = prog.utf8,
            .longest = prog.longest,
            .clist = clist,
            .nlist = nlist,
            .stack = stack,
            .caps = caps,
            .best = best,
        };
    }

    pub fn deinit(p: *Pike) void {
        p.clist.deinit(p.gpa);
        p.nlist.deinit(p.gpa);
        p.stack.deinit(p.gpa);
        p.gpa.free(p.caps);
        p.gpa.free(p.best);
    }

    /// A match never starts inside a UTF-8 character.
    fn startAllowed(p: *const Pike, hay: []const u8, pos: usize) bool {
        return !(p.utf8 and pos < hay.len and hay[pos] & 0xC0 == 0x80);
    }

    /// Leftmost match at or after `from`: the capture registers (2 per
    /// group, group 0 first), valid until the next call, or null.
    pub fn find(p: *Pike, hay: []const u8, from: usize) ?[]const usize {
        if (from > hay.len) return null;
        p.clist.reset();
        p.nlist.reset();
        var matched = false;
        var pos = from;
        while (true) {
            if (!matched and p.startAllowed(hay, pos)) {
                // With nothing running, skip positions that cannot start a match.
                if (p.clist.nthreads == 0) if (p.first_bytes) |set| {
                    // Closures that died on an assertion leave visited marks
                    // behind. They belong to this position; the skip may move.
                    p.clist.reset();
                    while (pos < hay.len and !(set.has(hay[pos]) and p.startAllowed(hay, pos))) pos += 1;
                    // The pattern cannot match empty, so it needs a byte.
                    if (pos >= hay.len) return null;
                };
                @memset(p.caps, unset);
                p.addThread(&p.clist, 0, pos, hay, from);
            }
            if (p.clist.nthreads == 0) {
                if (matched or pos >= hay.len) break;
                // The failed start (for example an assertion) still marked
                // instructions as visited; those marks belong to this position.
                p.clist.reset();
                pos += 1;
                continue;
            }

            const c: ?u8 = if (pos < hay.len) hay[pos] else null;
            p.nlist.reset();
            var k: usize = 0;
            while (k < p.clist.nthreads) : (k += 1) {
                const pc = p.clist.thread_pc[k];
                const tcaps = p.clist.thread_caps[k * p.ncap ..][0..p.ncap];
                // Leftmost: a thread that started after the best match cannot win.
                if (matched and p.longest and tcaps[0] > p.best[0]) continue;
                switch (p.insts[pc]) {
                    .match => {
                        if (p.longest) {
                            if (!matched or tcaps[0] < p.best[0] or (tcaps[0] == p.best[0] and tcaps[1] > p.best[1]))
                                @memcpy(p.best, tcaps);
                            matched = true;
                        } else {
                            @memcpy(p.best, tcaps);
                            matched = true;
                            // Lower-priority threads can no longer win.
                            break;
                        }
                    },
                    .byte => |b| if (c != null and c.? == b) p.advance(pc, pos, tcaps, hay, from),
                    .any => if (c != null and c.? != '\n') p.advance(pc, pos, tcaps, hay, from),
                    .any_nl => if (c != null) p.advance(pc, pos, tcaps, hay, from),
                    .set => |i| if (c != null and p.sets[i].has(c.?)) p.advance(pc, pos, tcaps, hay, from),
                    else => unreachable,
                }
            }
            std.mem.swap(List, &p.clist, &p.nlist);
            if (pos >= hay.len) break;
            pos += 1;
        }
        return if (matched) p.best else null;
    }

    /// A thread consumed the byte at `pos`: continue it at pc+1 in the next list.
    fn advance(p: *Pike, pc: u32, pos: usize, tcaps: []const usize, hay: []const u8, search_start: usize) void {
        @memcpy(p.caps, tcaps);
        p.addThread(&p.nlist, pc + 1, pos + 1, hay, search_start);
    }

    /// Adds the thread at `pc0`, and every thread reachable from it without
    /// consuming input, to `list`, in priority order. `p.caps` holds the
    /// captures on entry and is scratch space afterwards.
    fn addThread(p: *Pike, list: *List, pc0: u32, pos: usize, hay: []const u8, search_start: usize) void {
        p.stack.clearRetainingCapacity();
        p.stack.appendAssumeCapacity(.{ .visit = pc0 });
        while (p.stack.pop()) |frame| switch (frame) {
            .restore => |r| p.caps[r.slot] = r.old,
            .visit => |start| {
                var pc = start;
                while (!list.contains(pc)) {
                    list.mark(pc);
                    switch (p.insts[pc]) {
                        .jmp => |t| pc = t,
                        .split => |sp| {
                            p.stack.appendAssumeCapacity(.{ .visit = sp.second });
                            pc = sp.first;
                        },
                        .save => |r| {
                            p.stack.appendAssumeCapacity(.{ .restore = .{ .slot = r, .old = p.caps[r] } });
                            p.caps[r] = pos;
                            pc += 1;
                        },
                        .assertion => |a| {
                            if (!context.check(a, hay, pos, search_start, p.utf8)) break;
                            pc += 1;
                        },
                        .byte, .any, .any_nl, .set, .match => {
                            list.addThread(pc, p.caps);
                            break;
                        },
                        else => unreachable,
                    }
                }
            },
        };
    }
};

// SPDX-License-Identifier: LGPL-2.0-or-later
//! Lazy DFA over the NFA program (program.zig, `Nfa`). It answers "where does
//! a match end" (forward, unanchored) and "where does it start" (the same
//! pattern compiled right to left, anchored at the end), in time linear in
//! the input once its states are built. It never produces captures: the
//! caller runs the Pike VM on the span for those. See
//! docs/decisions/0002-matching-engines.md, section 9.
//!
//! A DFA state is an ordered list of NFA instructions to resume at (the
//! "seeds"), plus the kind of the previous byte. The empty-width assertions
//! are evaluated when a transition is built, from the previous byte (in the
//! state) and the next byte (the transition's symbol), so `^ $ \b` need no
//! special states. A transition also reports whether a match ends at the
//! current position, before the next byte is consumed.
//!
//! The forward DFA is leftmost-first: once a match is found, lower-priority
//! threads (including new starts) are dropped. For leftmost-longest it is only
//! used to decide whether any match exists. The reverse DFA keeps every
//! thread, so it finds the longest match backwards, that is, the leftmost start.
//!
//! States are cached up to `max_bytes`; when full the cache is cleared. If
//! that happens more than `max_flushes` times in one search, the search gives
//! up (`error.GaveUp`) and the caller falls back to the Pike VM.

const std = @import("std");
const program = @import("program.zig");
const ast = @import("ast.zig");
const ByteSet = @import("byteset.zig").ByteSet;

const Inst = program.Inst;

pub const Error = error{ OutOfMemory, GaveUp };

/// Substring search: 32 lanes compare the needle's first and last bytes at
/// once, and only candidates are verified. Falls back to the standard
/// library for short haystacks.
fn indexOfNeedle(hay: []const u8, pos: usize, needle: []const u8) ?usize {
    const V = 32;
    const n = needle.len;
    if (hay.len < pos + n) return null;
    const last_start = hay.len - n; // last possible match start
    const vf: @Vector(V, u8) = @splat(needle[0]);
    const vl: @Vector(V, u8) = @splat(needle[n - 1]);
    var i = pos;
    while (i + V <= last_start + 1) : (i += V) {
        const a: @Vector(V, u8) = hay[i..][0..V].*;
        const b: @Vector(V, u8) = hay[i + n - 1 ..][0..V].*;
        var bits: u32 = @bitCast((a == vf) & (b == vl));
        while (bits != 0) {
            const k = i + @ctz(bits);
            if (std.mem.eql(u8, hay[k..][0..n], needle)) return k;
            bits &= bits - 1;
        }
    }
    while (i <= last_start) : (i += 1) {
        if (hay[i] == needle[0] and std.mem.eql(u8, hay[i .. i + n], needle)) return i;
    }
    return null;
}

/// Index of the first of `a`, `b`, `c` at or after `pos`, or `hay.len`.
fn indexOfAny3(hay: []const u8, pos: usize, a: u8, b: u8, c: u8) usize {
    const V = 32;
    var i = pos;
    const va: @Vector(V, u8) = @splat(a);
    const vb: @Vector(V, u8) = @splat(b);
    const vc: @Vector(V, u8) = @splat(c);
    while (i + V <= hay.len) : (i += V) {
        const v: @Vector(V, u8) = hay[i..][0..V].*;
        const m = (v == va) | (v == vb) | (v == vc);
        const bits: u32 = @bitCast(m);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < hay.len) : (i += 1) {
        const x = hay[i];
        if (x == a or x == b or x == c) return i;
    }
    return hay.len;
}

/// What the byte before a position was, as far as assertions care.
pub const Kind = enum(u8) { text_edge, newline, word, other };

fn kindOf(b: u8) Kind {
    if (b == '\n') return .newline;
    if (ByteSet.isWordByte(b)) return .word;
    return .other;
}

const Anchor = enum { none, line, text };

const unknown: u32 = std.math.maxInt(u32);
const max_flushes = 4;

pub const Dfa = struct {
    gpa: std.mem.Allocator,
    insts: []const Inst,
    sets: []const ByteSet,
    /// Anchored at the start position (the reverse DFA) instead of searching.
    anchored: bool,
    /// Leftmost-first: a match drops lower-priority threads. The anchored
    /// (reverse) DFA keeps them all, because it wants the longest match.
    cut: bool,
    utf8: bool,
    /// Whether any assertion looks at the previous byte; if not, all states
    /// get the same kind so they are not duplicated.
    uses_prev: bool,
    /// Bytes a match can start with (forward DFA, pattern cannot match empty).
    first: ?ByteSet,
    /// Bytes every match starts with (forward DFA), or empty.
    prefix: []const u8,
    /// Precomputed from `first` once (see `init`): membership table, and the
    /// members themselves when there are one to three, so the skip loop is a
    /// memchr or a table walk instead of rescanning the 256-bit set.
    first_tab: [256]bool = @splat(false),
    first_n: u8 = 0,
    first_bytes: [3]u8 = .{ 0, 0, 0 },
    /// Where a new search can start from an idle state: `.line` when every
    /// match begins with `^` (only just after a newline), `.text` when with
    /// `\A`, else `.none`. Forward DFA only.
    start_anchor: Anchor = .none,
    nclasses: usize,
    stride: usize,
    classes: [256]u8 = undefined,
    reps: [256]u8 = undefined,

    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    seeds: std.ArrayList([]const u32) = .empty,
    kinds: std.ArrayList(Kind) = .empty,
    nomore: std.ArrayList(bool) = .empty,
    /// Per state: no threads, not dead, not "match already found" (the state
    /// a search is in when nothing is running and the first-byte skip applies).
    idle: std.ArrayList(bool) = .empty,
    trans: std.ArrayList(u32) = .empty,
    start_ids: [4]?u32 = .{ null, null, null, null },
    max_bytes: usize,
    used: usize = 0,
    epoch: u32 = 0,
    search_flushes: u32 = 0,

    // Scratch for building transitions.
    dense: []u32,
    sparse: []u32,
    seen_dense: []u32,
    seen_sparse: []u32,
    threads: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(u32) = .empty,
    next_seeds: std.ArrayList(u32) = .empty,
    key_buf: std.ArrayList(u8) = .empty,
    visited_len: usize = 0,
    matched: bool = false,

    pub fn init(gpa: std.mem.Allocator, nfa: program.Nfa, anchored: bool, utf8: bool, first: ?ByteSet, prefix: []const u8, max_bytes: usize) Error!Dfa {
        const n = nfa.insts.len;
        var d: Dfa = .{
            .gpa = gpa,
            .insts = nfa.insts,
            .sets = nfa.sets,
            .anchored = anchored,
            .cut = !anchored,
            .utf8 = utf8,
            .uses_prev = false,
            .first = if (anchored) null else first,
            .prefix = if (anchored) &.{} else prefix,
            .nclasses = 0,
            .stride = 0,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .max_bytes = max_bytes,
            .dense = &.{},
            .sparse = &.{},
            .seen_dense = &.{},
            .seen_sparse = &.{},
        };
        // From here on `deinit` frees whatever has been allocated so far.
        errdefer d.deinit();
        d.dense = try gpa.alloc(u32, n);
        d.sparse = try gpa.alloc(u32, n);
        d.seen_dense = try gpa.alloc(u32, n + 1);
        d.seen_sparse = try gpa.alloc(u32, n + 1);
        d.buildClasses();
        if (d.first) |fb| {
            for (0..256) |i| d.first_tab[i] = fb.has(@intCast(i));
            const nf = fb.count();
            if (nf <= 3) {
                d.first_n = @intCast(nf);
                var k: usize = 0;
                for (0..256) |i| if (fb.has(@intCast(i))) {
                    d.first_bytes[k] = @intCast(i);
                    k += 1;
                };
            } else d.first_n = 255;
        }
        if (!anchored) d.start_anchor = d.findAnchor();
        d.stride = d.nclasses + 1;
        // Closures push at most one pending branch per instruction.
        try d.stack.ensureTotalCapacity(gpa, n + 2);
        try d.threads.ensureTotalCapacity(gpa, n + 2);
        try d.next_seeds.ensureTotalCapacity(gpa, n + 2);
        try d.resetCache();
        return d;
    }

    pub fn deinit(d: *Dfa) void {
        d.gpa.free(d.dense);
        d.gpa.free(d.sparse);
        d.gpa.free(d.seen_dense);
        d.gpa.free(d.seen_sparse);
        d.map.deinit(d.gpa);
        d.seeds.deinit(d.gpa);
        d.kinds.deinit(d.gpa);
        d.nomore.deinit(d.gpa);
        d.idle.deinit(d.gpa);
        d.trans.deinit(d.gpa);
        d.threads.deinit(d.gpa);
        d.stack.deinit(d.gpa);
        d.next_seeds.deinit(d.gpa);
        d.key_buf.deinit(d.gpa);
        d.arena.deinit();
    }

    /// Walks the instructions reachable from the start without consuming a
    /// byte; the anchor holds when each path meets the same start assertion.
    fn findAnchor(d: *Dfa) Anchor {
        var found: Anchor = .none;
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(d.gpa);
        var seen: std.DynamicBitSetUnmanaged = std.DynamicBitSetUnmanaged.initEmpty(d.gpa, d.insts.len) catch return .none;
        defer seen.deinit(d.gpa);
        stack.append(d.gpa, 0) catch return .none;
        while (stack.pop()) |start| {
            var pc = start;
            while (!seen.isSet(pc)) {
                seen.set(pc);
                switch (d.insts[pc]) {
                    .jmp => |t| pc = t,
                    .split => |sp| {
                        stack.append(d.gpa, sp.second) catch return .none;
                        pc = sp.first;
                    },
                    .save => pc += 1,
                    .assertion => |a| {
                        const kind: Anchor = switch (a) {
                            .line_start => .line,
                            .text_start => .text,
                            else => return .none,
                        };
                        if (found != .none and found != kind) return .none;
                        found = kind;
                        break;
                    },
                    else => return .none,
                }
            }
        }
        return found;
    }

    // ---- byte classes -----------------------------------------------------

    /// Partition the 256 bytes into classes that no instruction or assertion
    /// can tell apart, so a state needs one transition per class.
    fn buildClasses(d: *Dfa) void {
        var cls: [256]u16 = @splat(0);
        var count: usize = 1;
        var newline = false;
        var word = false;
        var cont = false;
        for (d.insts) |inst| switch (inst) {
            .byte => |b| {
                var s: ByteSet = .{};
                s.add(b);
                count = refine(&cls, count, s);
            },
            .set => |i| count = refine(&cls, count, d.sets[i]),
            .any => newline = true,
            .assertion => |a| switch (a) {
                .line_start => {
                    newline = true;
                    d.uses_prev = true;
                },
                .line_end => newline = true,
                .text_start => d.uses_prev = true,
                .word_boundary, .not_word_boundary, .word_start, .word_end => {
                    word = true;
                    d.uses_prev = true;
                },
                else => {},
            },
            else => {},
        };
        if (newline) {
            var s: ByteSet = .{};
            s.add('\n');
            count = refine(&cls, count, s);
        }
        if (word) {
            var s: ByteSet = .{};
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
            s.addRange('0', '9');
            s.add('_');
            count = refine(&cls, count, s);
        }
        if (d.utf8) cont = true;
        if (cont) {
            var s: ByteSet = .{};
            s.addRange(0x80, 0xBF);
            count = refine(&cls, count, s);
        }
        var seen: [256]bool = @splat(false);
        for (0..256) |b| {
            d.classes[b] = @intCast(cls[b]);
            if (!seen[cls[b]]) {
                seen[cls[b]] = true;
                d.reps[cls[b]] = @intCast(b);
            }
        }
        d.nclasses = count;
    }

    /// Split every class into the part inside `set` and the part outside.
    fn refine(cls: *[256]u16, count: usize, set: ByteSet) usize {
        var remap: [512]u16 = @splat(std.math.maxInt(u16));
        var n: u16 = 0;
        for (0..256) |b| {
            const key = @as(usize, cls[b]) * 2 + @intFromBool(set.has(@intCast(b)));
            if (remap[key] == std.math.maxInt(u16)) {
                remap[key] = n;
                n += 1;
            }
            cls[b] = remap[key];
        }
        _ = count;
        return n;
    }

    // ---- state cache ------------------------------------------------------

    fn resetCache(d: *Dfa) Error!void {
        _ = d.arena.reset(.retain_capacity);
        d.map.clearRetainingCapacity();
        d.seeds.clearRetainingCapacity();
        d.kinds.clearRetainingCapacity();
        d.nomore.clearRetainingCapacity();
        d.idle.clearRetainingCapacity();
        d.trans.clearRetainingCapacity();
        d.start_ids = .{ null, null, null, null };
        d.used = 0;
        // State 0 is the dead state: no threads, nothing more can match.
        try d.seeds.ensureUnusedCapacity(d.gpa, 1);
        try d.kinds.ensureUnusedCapacity(d.gpa, 1);
        try d.nomore.ensureUnusedCapacity(d.gpa, 1);
        try d.idle.ensureUnusedCapacity(d.gpa, 1);
        try d.trans.ensureUnusedCapacity(d.gpa, d.stride);
        d.idle.appendAssumeCapacity(false);
        d.seeds.appendAssumeCapacity(&.{});
        d.kinds.appendAssumeCapacity(.other);
        d.nomore.appendAssumeCapacity(true);
        d.trans.appendNTimesAssumeCapacity(0, d.stride);
    }

    fn intern(d: *Dfa, seeds: []const u32, kind: Kind, nomore: bool) Error!u32 {
        if (seeds.len == 0 and (d.anchored or nomore)) return 0;
        d.key_buf.clearRetainingCapacity();
        try d.key_buf.append(d.gpa, @backingInt(kind));
        try d.key_buf.append(d.gpa, @intFromBool(nomore));
        try d.key_buf.appendSlice(d.gpa, std.mem.sliceAsBytes(seeds));
        if (d.map.get(d.key_buf.items)) |id| return id;

        const cost = d.key_buf.items.len * 2 + d.stride * 4 + 64;
        if (d.used + cost > d.max_bytes) {
            d.search_flushes += 1;
            if (d.search_flushes > max_flushes) return error.GaveUp;
            d.epoch += 1;
            try d.resetCache();
        }
        // Reserve everything first so a failed allocation leaves the cache
        // consistent: either the state is added completely or not at all.
        const a = d.arena.allocator();
        const key = try a.dupe(u8, d.key_buf.items);
        const owned = try a.dupe(u32, seeds);
        try d.map.ensureUnusedCapacity(d.gpa, 1);
        try d.seeds.ensureUnusedCapacity(d.gpa, 1);
        try d.kinds.ensureUnusedCapacity(d.gpa, 1);
        try d.nomore.ensureUnusedCapacity(d.gpa, 1);
        try d.idle.ensureUnusedCapacity(d.gpa, 1);
        try d.trans.ensureUnusedCapacity(d.gpa, d.stride);
        const id: u32 = @intCast(d.seeds.items.len);
        d.map.putAssumeCapacity(key, id);
        d.seeds.appendAssumeCapacity(owned);
        d.kinds.appendAssumeCapacity(kind);
        d.nomore.appendAssumeCapacity(nomore);
        d.idle.appendAssumeCapacity(seeds.len == 0 and !nomore);
        d.trans.appendNTimesAssumeCapacity(unknown, d.stride);
        d.used += cost;
        return id;
    }

    fn startState(d: *Dfa, kind: Kind) Error!u32 {
        const k = if (d.uses_prev) kind else Kind.other;
        if (d.start_ids[@backingInt(k)]) |id| return id;
        const seeds: []const u32 = if (d.anchored) &.{0} else &.{};
        const id = try d.intern(seeds, k, false);
        // A flush inside intern cleared start_ids; record the new id.
        d.start_ids[@backingInt(k)] = id;
        return id;
    }

    fn isIdle(d: *const Dfa, id: u32) bool {
        return d.idle.items[id];
    }

    // ---- building transitions ----------------------------------------------

    fn assertionHolds(a: ast.Assertion, prev: Kind, next: ?u8) bool {
        return switch (a) {
            .line_start => prev == .text_edge or prev == .newline,
            .line_end => next == null or next.? == '\n',
            .text_start => prev == .text_edge,
            // `\Z` and `$` are only run here when the haystack does not end
            // in a newline, so they mean end of text.
            .text_end, .text_end_or_final_newline => next == null,
            .word_boundary => (prev == .word) != (next != null and ByteSet.isWordByte(next.?)),
            .not_word_boundary => (prev == .word) == (next != null and ByteSet.isWordByte(next.?)),
            .word_start => prev != .word and (next != null and ByteSet.isWordByte(next.?)),
            .word_end => prev == .word and !(next != null and ByteSet.isWordByte(next.?)),
            .search_start => unreachable,
        };
    }

    fn visited(d: *const Dfa, pc: u32) bool {
        const i = d.sparse[pc];
        return i < d.visited_len and d.dense[i] == pc;
    }

    fn markVisited(d: *Dfa, pc: u32) void {
        d.sparse[pc] = @intCast(d.visited_len);
        d.dense[d.visited_len] = pc;
        d.visited_len += 1;
    }

    /// Adds `pc0` and everything reachable without consuming a byte to
    /// `threads`, in priority order. Returns true when a match was reached
    /// and the remaining lower-priority work must be dropped.
    fn follow(d: *Dfa, pc0: u32, prev: Kind, next: ?u8) bool {
        d.stack.clearRetainingCapacity();
        d.stack.appendAssumeCapacity(pc0);
        while (d.stack.pop()) |start| {
            var pc = start;
            while (!d.visited(pc)) {
                d.markVisited(pc);
                switch (d.insts[pc]) {
                    .jmp => |t| pc = t,
                    .split => |sp| {
                        d.stack.appendAssumeCapacity(sp.second);
                        pc = sp.first;
                    },
                    .save => pc += 1,
                    .assertion => |a| {
                        if (!assertionHolds(a, prev, next)) break;
                        pc += 1;
                    },
                    .byte, .any, .any_nl, .set => {
                        d.threads.appendAssumeCapacity(pc);
                        break;
                    },
                    .match => {
                        d.matched = true;
                        if (!d.cut) break;
                        // Leftmost-first: nothing of lower priority can win.
                        d.stack.clearRetainingCapacity();
                        return true;
                    },
                    else => unreachable,
                }
            }
        }
        return false;
    }

    /// The transition from state `id` on class `sym` (`nclasses` is the end of
    /// the text): `(next state << 1) | match-ends-here`.
    fn compute(d: *Dfa, id: u32, sym: usize) Error!u32 {
        const prev = d.kinds.items[id];
        const nomore = d.nomore.items[id];
        const next: ?u8 = if (sym == d.nclasses) null else d.reps[sym];

        d.visited_len = 0;
        d.threads.clearRetainingCapacity();
        d.matched = false;
        var stop = false;
        for (d.seeds.items[id]) |s| {
            if (d.follow(s, prev, next)) {
                stop = true;
                break;
            }
        }
        // A new search can start here, unless a match already ended the
        // search or this byte is inside a UTF-8 character.
        const inside_char = d.utf8 and next != null and next.? & 0xC0 == 0x80;
        if (!stop and !d.anchored and !nomore and !inside_char) _ = d.follow(0, prev, next);
        const matched = d.matched;
        if (next == null) return @as(u32, @intFromBool(matched));

        // Step every thread over the byte.
        const b = next.?;
        d.next_seeds.clearRetainingCapacity();
        var seen_len: usize = 0;
        for (d.threads.items) |pc| {
            const ok = switch (d.insts[pc]) {
                .byte => |x| b == x,
                .any => b != '\n',
                .any_nl => true,
                .set => |i| d.sets[i].has(b),
                else => unreachable,
            };
            if (!ok) continue;
            const target = pc + 1;
            const i = d.seen_sparse[target];
            if (i < seen_len and d.seen_dense[i] == target) continue;
            d.seen_sparse[target] = @intCast(seen_len);
            d.seen_dense[seen_len] = target;
            seen_len += 1;
            d.next_seeds.appendAssumeCapacity(target);
        }
        const kind: Kind = if (d.uses_prev) kindOf(b) else .other;
        const new_nomore = !d.anchored and (nomore or matched);
        const id2 = try d.intern(d.next_seeds.items, kind, new_nomore);
        return (id2 << 1) | @as(u32, @intFromBool(matched));
    }

    /// The (cached) transition; computes and records it when unknown.
    fn step(d: *Dfa, id: u32, sym: usize) Error!u32 {
        const slot = @as(usize, id) * d.stride + sym;
        const e = d.trans.items[slot];
        if (e != unknown) return e;
        const epoch = d.epoch;
        const entry = try d.compute(id, sym);
        // A flush renumbered every state; the old slot no longer exists.
        if (d.epoch == epoch) d.trans.items[slot] = entry;
        return entry;
    }

    // ---- searching ---------------------------------------------------------

    fn kindBefore(hay: []const u8, pos: usize) Kind {
        return if (pos == 0) .text_edge else kindOf(hay[pos - 1]);
    }

    /// Forward, unanchored: the end of the leftmost-first match at or after
    /// `from`, or null. With `first_only`, the end of the earliest-ending
    /// match, which is enough to know that one exists.
    pub fn findEnd(d: *Dfa, hay: []const u8, from: usize, first_only: bool) Error!?usize {
        if (from > hay.len) return null;
        d.search_flushes = 0;
        var state = try d.startState(kindBefore(hay, from));
        var last: ?usize = null;
        var pos = from;
        const has_first = d.first != null;
        const stride = d.stride;
        const classes = &d.classes;
        outer: while (pos < hay.len) {
            if (d.start_anchor != .none and pos > 0 and d.idle.items[state]) {
                // Every match starts with ^ (or \A): nothing can start here
                // unless the previous byte is a newline.
                if (d.start_anchor == .text) return last;
                if (hay[pos - 1] != '\n') {
                    const nl = std.mem.indexOfScalarPos(u8, hay, pos, '\n') orelse return last;
                    pos = nl + 1;
                    state = try d.startState(.newline);
                    // At the very end (just after a final newline) the
                    // end-of-text step still sees a line start.
                    if (pos >= hay.len) break :outer;
                }
            }
            if (has_first and d.idle.items[state]) {
                // Nothing is running: jump to the next byte a match can start with.
                const q = d.skipIdle(hay, pos);
                // The pattern cannot match empty, so it needs a byte.
                if (q >= hay.len) return last;
                if (q != pos) {
                    pos = q;
                    state = try d.startState(kindBefore(hay, pos));
                }
            }
            // Hot loop: one table lookup per byte; leave it for an unknown
            // transition, a match end, the dead state, or an idle state.
            var trans = d.trans.items;
            while (true) {
                const e = trans[@as(usize, state) * stride + classes[hay[pos]]];
                if (e == unknown or e & 1 != 0) {
                    const e2 = if (e == unknown) try d.step(state, classes[hay[pos]]) else e;
                    if (e2 & 1 != 0) {
                        last = pos;
                        if (first_only) return last;
                    }
                    state = e2 >> 1;
                    if (state == 0) return last;
                    pos += 1;
                    if (pos >= hay.len) break :outer;
                    continue :outer;
                }
                state = e >> 1;
                if (state == 0) return last;
                pos += 1;
                if (pos >= hay.len) break :outer;
                if (d.idle.items[state] and (has_first or d.start_anchor != .none)) continue :outer;
                trans = d.trans.items;
            }
        }
        const e = try d.step(state, d.nclasses);
        if (e & 1 != 0) last = pos;
        return last;
    }

    /// The first position at or after `pos` where a match can start (the end
    /// of `hay` when none). Only valid for a forward DFA with a first-byte set.
    pub fn skipIdle(d: *const Dfa, hay: []const u8, pos: usize) usize {
        if (d.prefix.len >= 2) return indexOfNeedle(hay, pos, d.prefix) orelse hay.len;
        switch (d.first_n) {
            1 => return std.mem.indexOfScalarPos(u8, hay, pos, d.first_bytes[0]) orelse hay.len,
            2, 3 => return indexOfAny3(hay, pos, d.first_bytes[0], d.first_bytes[if (d.first_n > 1) 1 else 0], d.first_bytes[if (d.first_n > 2) 2 else 0]),
            else => {
                var q = pos;
                while (q < hay.len and !d.first_tab[hay[q]]) q += 1;
                return q;
            },
        }
    }

    /// Reverse, anchored at `end`: the smallest position at or after `from`
    /// where a match that ends at `end` can start, or null. Must be run on the
    /// DFA built from the reversed program.
    pub fn findStart(d: *Dfa, hay: []const u8, from: usize, end: usize) Error!?usize {
        d.search_flushes = 0;
        // The previous byte, read right to left, is the one after `end`.
        const right: Kind = if (end == hay.len) .text_edge else kindOf(hay[end]);
        var state = try d.startState(right);
        var best: ?usize = null;
        var pos = end;
        while (pos > from) {
            const e = try d.step(state, d.classes[hay[pos - 1]]);
            if (e & 1 != 0) best = pos;
            state = e >> 1;
            if (state == 0) return best;
            pos -= 1;
        }
        // At `from`: assertions still see the byte before it.
        const sym = if (from > 0) d.classes[hay[from - 1]] else d.nclasses;
        const e = try d.step(state, sym);
        if (e & 1 != 0) best = pos;
        return best;
    }
};

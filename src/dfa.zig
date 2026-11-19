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

/// What the byte before a position was, as far as assertions care.
pub const Kind = enum(u8) { text_edge, newline, word, other };

fn kindOf(b: u8) Kind {
    if (b == '\n') return .newline;
    if (ByteSet.isWordByte(b)) return .word;
    return .other;
}

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
    nclasses: usize,
    stride: usize,
    classes: [256]u8 = undefined,
    reps: [256]u8 = undefined,

    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    seeds: std.ArrayList([]const u32) = .empty,
    kinds: std.ArrayList(Kind) = .empty,
    nomore: std.ArrayList(bool) = .empty,
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
        const dense = try gpa.alloc(u32, n);
        errdefer gpa.free(dense);
        const sparse = try gpa.alloc(u32, n);
        errdefer gpa.free(sparse);
        const seen_dense = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(seen_dense);
        const seen_sparse = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(seen_sparse);
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
            .dense = dense,
            .sparse = sparse,
            .seen_dense = seen_dense,
            .seen_sparse = seen_sparse,
        };
        errdefer d.arena.deinit();
        d.buildClasses();
        d.stride = d.nclasses + 1;
        // Closures push at most one pending branch per instruction.
        try d.stack.ensureTotalCapacity(gpa, n + 2);
        errdefer d.stack.deinit(gpa);
        try d.threads.ensureTotalCapacity(gpa, n + 2);
        errdefer d.threads.deinit(gpa);
        try d.next_seeds.ensureTotalCapacity(gpa, n + 2);
        errdefer d.next_seeds.deinit(gpa);
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
        d.trans.deinit(d.gpa);
        d.threads.deinit(d.gpa);
        d.stack.deinit(d.gpa);
        d.next_seeds.deinit(d.gpa);
        d.key_buf.deinit(d.gpa);
        d.arena.deinit();
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
        d.trans.clearRetainingCapacity();
        d.start_ids = .{ null, null, null, null };
        d.used = 0;
        // State 0 is the dead state: no threads, nothing more can match.
        try d.seeds.append(d.gpa, &.{});
        try d.kinds.append(d.gpa, .other);
        try d.nomore.append(d.gpa, true);
        try d.trans.appendNTimes(d.gpa, 0, d.stride);
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
        const a = d.arena.allocator();
        const key = try a.dupe(u8, d.key_buf.items);
        const owned = try a.dupe(u32, seeds);
        const id: u32 = @intCast(d.seeds.items.len);
        try d.map.put(d.gpa, key, id);
        try d.seeds.append(d.gpa, owned);
        try d.kinds.append(d.gpa, kind);
        try d.nomore.append(d.gpa, nomore);
        try d.trans.appendNTimes(d.gpa, unknown, d.stride);
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
        return d.seeds.items[id].len == 0 and !d.nomore.items[id] and id != 0;
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
        while (pos < hay.len) {
            if (d.first) |fb| if (d.isIdle(state)) {
                // Nothing is running: jump to the next byte a match can start with.
                var q = pos;
                if (d.prefix.len >= 2) {
                    q = std.mem.indexOfPos(u8, hay, pos, d.prefix) orelse hay.len;
                } else if (fb.count() == 1) {
                    const only: u8 = for (0..256) |i| {
                        if (fb.has(@intCast(i))) break @intCast(i);
                    } else unreachable;
                    q = std.mem.indexOfScalarPos(u8, hay, pos, only) orelse hay.len;
                } else {
                    while (q < hay.len and !fb.has(hay[q])) q += 1;
                }
                // The pattern cannot match empty, so it needs a byte.
                if (q >= hay.len) return last;
                if (q != pos) {
                    pos = q;
                    state = try d.startState(kindBefore(hay, pos));
                }
            };
            const e = try d.step(state, d.classes[hay[pos]]);
            if (e & 1 != 0) {
                last = pos;
                if (first_only) return last;
            }
            state = e >> 1;
            if (state == 0) return last;
            pos += 1;
        }
        const e = try d.step(state, d.nclasses);
        if (e & 1 != 0) last = pos;
        return last;
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

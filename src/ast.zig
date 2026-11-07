//! Syntax-independent regular-expression AST. Every parser produces this tree
//! and the compiler consumes it, so engines never see syntax details.
//!
//! Nodes are allocated from the parser's arena; the tree is freed as a whole
//! once compilation is done.

const ByteSet = @import("byteset.zig").ByteSet;

pub const Assertion = enum {
    line_start, // ^ in line mode
    line_end, // $ in line mode
    text_start, // \A, or ^ outside line mode
    text_end, // \z
    text_end_or_final_newline, // \Z, or $ outside line mode
    word_boundary,
    not_word_boundary,
    search_start, // \G: position where this search began
};

pub const Greed = enum { greedy, lazy, possessive };

pub const Node = union(enum) {
    empty,
    byte: u8,
    /// `.`; the payload says whether it also matches '\n'.
    any: bool,
    set: ByteSet,
    concat: []const *const Node,
    alt: []const *const Node,
    repeat: Repeat,
    /// Capturing group when `index` is non-null (1-based), else plain grouping.
    group: Group,
    atomic: *const Node,
    look: Look,
    assertion: Assertion,
    backref: Backref,
};

pub const Repeat = struct {
    sub: *const Node,
    min: u32,
    max: ?u32, // null = unbounded
    greed: Greed,
};

pub const Group = struct {
    sub: *const Node,
    index: ?u32,
};

pub const Look = struct {
    sub: *const Node,
    ahead: bool,
    negate: bool,
};

pub const Backref = struct {
    index: u32,
    ignore_case: bool,
};

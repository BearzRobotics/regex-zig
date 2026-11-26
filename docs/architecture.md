# Architecture

How regex-zig is put together as of version 0.5.0. Design decisions and their reasons are in `docs/decisions/`; the requirements are in `SPEC.md`.

## Overview

```
 pattern text + Options (dialect, utf8, ignore_case, limits, engine)
        |
   [ parse.zig ]   one Parser, five dialects, validates UTF-8 in utf8 mode
        |  AST (ast.zig): byte, any, set, cp_set, concat, alt, repeat,
        |                 group, atomic, look, assertion, backref
        v
   [ program.zig ] compiles the AST up to four times:
        |   1. backtracker program   (always; cp_class for big Unicode sets)
        |   2. NFA program           (patterns without backref/look/atomic/possessive)
        |   3. reverse NFA program   (when the DFA can run the pattern)
        |   plus: literal prefix, first-byte set, flags
        v
   Regex (immutable, shareable)          Program.engine = .dfa | .pike | .backtrack
        |
   Regex.searcher(gpa)  ->  Searcher (per thread; owns all mutable state)
        |
        +-- .dfa       dfa.zig forward  -> where the match ends
        |              dfa.zig reverse  -> where it starts
        |              pike.zig         -> captures, only if the pattern has groups
        +-- .pike      pike.zig         -> span and captures
        +-- .backtrack backtrack.zig    -> everything, bounded by Limits
        |
   ops.zig       isMatch, matches, count, findAll, split, replaceAll, lines
   stream.zig    LineStream over std.Io.Reader
   root.zig      Regex, RegexSet, Options, re-exports
```

## Files

| File | Role |
|---|---|
| `src/parse.zig` | Parser for all dialects; builds the AST; `parseSet` for sets |
| `src/ast.zig` | The syntax-independent tree |
| `src/byteset.zig` | 256-bit byte set |
| `src/utf8.zig` | Code-point ranges, and lowering of ranges to UTF-8 byte sequences |
| `src/unicode.zig`, `src/unicode_tables.zig` | Property lookup and case-folding orbits over generated tables (`tools/gen_unicode.py`); empty with `-Dunicode_tables=false` |
| `src/program.zig` | Instruction set, compiler, engine selection, `Program` |
| `src/context.zig` | Empty-width assertions and UTF-8 decoding around a position; shared by all engines |
| `src/backtrack.zig` | Backtracking VM and the `Searcher` (engine dispatch) |
| `src/pike.zig` | Pike VM: linear time, captures |
| `src/dfa.zig` | Lazy DFA, forward and reverse |
| `src/ops.zig` | Convenience operations built on `Searcher.find` |
| `src/stream.zig` | Line streaming |
| `src/root.zig` | Public API |
| `src/tests.zig`, `src/testdata/` | Behaviour, differential, fuzz and reference tests |
| `bench/bench.zig` | `zig build bench` |
| `tools/` | Table and test-case generators (Python, maintainers only) |

## Engine selection

Decided once, in `program.compile`:

1. Back-references, look-around, atomic groups or possessive quantifiers: **backtracker**. Its work is bounded by `Limits.max_steps` and `max_stack`, not by the input size.
2. Otherwise the NFA program is built. If it would exceed `max_program_len` (for example `\p{L}{100}`), fall back to the backtracker; `Regex.isLinearTime` reports it. If the Pike VM's capture slots would exceed `max_capture_bytes`, compiling fails.
3. If the pattern has no `\G` and no Unicode `\b \B \< \>`, the reverse NFA program is built too and the engine is **DFA**; otherwise **Pike VM**.

`Options.engine` forces `.backtrack`, `.pike` or `.dfa` (an error if the pattern does not qualify), mainly for tests.

## Searching with the DFA engine

- `isMatch`: forward DFA, stop at the first match flag.
- `find` with no groups: forward DFA gives the end of the leftmost-first match, reverse DFA (anchored at that end, keeping all threads) gives the start.
- `find` with groups: the span from the DFAs, then the Pike VM from that start for the captures.
- Leftmost-longest dialects: the DFA decides whether a match exists; the Pike VM finds the span.
- A haystack ending in a newline, when the pattern contains `$` or `\Z`, goes to the Pike VM (the DFA treats those as end of text).
- If the DFA cache keeps filling (`Limits.max_dfa_cache`), the search falls back to the Pike VM.

## Resource use

| Resource | Bound |
|---|---|
| Pattern length, nesting, repeat count, program size | `Limits` (compile time, errors) |
| Compiler work | 16 nodes per allowed instruction (at least 262,144), so repeats of bodies that emit little cannot run on |
| Parse memory for classes | built in a scratch arena reset per class; one copy per distinct set |
| Backtracker | `max_steps` per `find` call (a back-reference adds a step per 32 bytes compared), `max_stack` frames |
| Pike VM | two thread lists of `t x (2g+2)` words (`t` = instructions that can hold a thread, `g` = groups), sized once and capped by `max_capture_bytes`; no allocation while searching |
| Lazy DFA | `max_dfa_cache` bytes per direction; cleared when full, then falls back |
| `Searcher` | all mutable state; one per thread; the `Regex` must outlive it |

## Threading

A `Regex` (and `RegexSet`) is immutable after compile and can be shared. A `Searcher` is not thread-safe; use one per thread.

## Tests

`zig build test` runs: parser and behaviour tests (each also checks the backtracker against the default engine), randomized differential tests (Pike vs backtracker, DFA vs Pike, over Perl, ERE, BRE and Oniguruma syntaxes), agreement with GNU grep 3.12 on lines and match spans for generated BRE and ERE cases, with and without `-i` (`src/testdata/grep_cases.txt`), fuzzing with arbitrary pattern bytes and with backtracker-only constructs, slice-against-stream line search, DFA cache flush and fallback tests, allocation-failure tests, limit and pathological-pattern tests. `zig build test -Dunicode_tables=false` covers the build without the tables.

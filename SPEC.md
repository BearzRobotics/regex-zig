# regex-zig — Specification

Status: Draft 0.1
Implementation language: Zig (version pinned by the project; currently developed against 0.17.0)
Engineering policy: ai/AGENTS.md
Scope: A reusable regular-expression library for Zig. First consumers: `grep` and `sed` in Core Utils.

## 1. Purpose

regex-zig is an independent, pure-Zig regular-expression engine that can parse the pattern syntaxes needed by GNU grep, GNU sed and ripgrep, and match them over byte streams with predictable resource use. It must be usable without Core Utils, and Core Utils depends on it only as an ordinary Zig package.

## 2. Goals

1. Parse these syntaxes, each selected explicitly by the caller:
   - POSIX BRE and ERE, including the GNU extensions (`\<`, `\>`, `\b`, `\B`, `\w`, `\W`, `\s`, `\S`, `\'`, `` \` ``, back-references, `\+ \? \|` in BRE).
   - A Rust-`regex`-style dialect as used by ripgrep (Unicode classes, inline flags such as `(?i)`, non-greedy repetition, named groups).
   - A Perl-compatible subset sufficient for `grep -P` (look-around, back-references, possessive/atomic constructs). The exact subset is an open decision (§9).
2. Guarantee linear-time matching, in input size, for every pattern that has no back-references or look-around.
3. Support back-references and look-around through a separate, explicitly bounded backtracking path, so their cost never affects patterns that do not use them.
4. Match over bytes by default and over UTF-8 when requested. Invalid UTF-8 in the haystack must not cause undefined behaviour or a crash in either mode.
5. Search streaming input (`std.Io.Reader`) without loading the whole input, and also search in-memory slices.
6. Provide fast paths: literal and literal-prefix extraction, required-substring prefilters, and SIMD byte search where the target supports it.
7. Expose an idiomatic native Zig API with explicit allocators and documented ownership, lifetimes and error behaviour.
8. Provide the primitives grep and sed need: match spans, capture groups, multi-pattern sets, line-oriented search, case-insensitive and multiline modes, and substitution-friendly iteration.

## 3. Non-goals

- Source or behaviour compatibility with any single existing engine beyond the documented syntaxes.
- Locale-dependent collation (`[[.ch.]]`, `[[=e=]]`) beyond the C/POSIX locale and Unicode; unsupported constructs are reported, not ignored (§5).
- A stable C ABI. An optional C FFI may come later, and must be labelled experimental (AGENTS.md §13).
- Being the fastest engine on every workload before it is correct.

## 4. Architecture (proposed)

```
 pattern text + syntax
        │
   [ parser ] ──► AST ──► [ analysis ] (literals, anchors, captures, features used)
                              │
              ┌───────────────┼───────────────────┐
         [ compiler: NFA ]  [ literal prefilter ]  [ feature check ]
              │
   ┌──────────┼───────────────┐
 [ lazy DFA ] [ NFA simulation ] [ bounded backtracker ]
 (match/no)   (captures)         (back-refs, look-around)
```

- The parser is separate for each syntax and produces one shared AST, so engines never see syntax-specific details.
- Engine selection is automatic from the analysis result, and can be forced for testing.
- The lazy DFA has an explicit, configurable state-cache bound. When the cache is exhausted it flushes, and if it thrashes it falls back to NFA simulation rather than growing memory.
- All compiled-program memory belongs to one `Regex` value and is released by one `deinit`.

This is a proposal. Significant changes need a record in `docs/decisions/` (AGENTS.md §3). Whether to write the engine from scratch or port the published designs of existing engines is the first such decision (§9).

## 5. Behaviour requirements

- Unsupported syntax or options return a descriptive error that names the construct and its position. They are never silently ignored.
- Every pattern has configurable limits: maximum pattern length, nesting depth, repetition count, compiled-program size and backtracking step budget. Defaults are finite.
- Exceeding a limit is an error, not a crash and not an unbounded allocation.
- Matching never reads outside the haystack, whatever the pattern or the input bytes.
- Leftmost-first versus leftmost-longest semantics are chosen by syntax: POSIX syntaxes use leftmost-longest, the Rust-style and Perl dialects use leftmost-first. This must be documented per syntax, and tested against the reference behaviour.

## 6. API sketch (non-normative)

```zig
const regex = @import("regex");
var re = try regex.Regex.compile(gpa, pattern, .{ .syntax = .posix_ere, .utf8 = false, .case_insensitive = false });
defer re.deinit();
if (re.find(haystack)) |m| { _ = m.start; _ = m.end; }
var searcher = try re.searcher(gpa, .{});  // streaming / repeated search state, separate from the compiled program
```

A compiled `Regex` is immutable and safe to share between threads. Per-search mutable state lives in a separate searcher value, so a grep running several threads needs one compiled pattern and one searcher per thread.

## 7. Testing and verification

- Unit tests for each parser, covering valid, invalid and boundary inputs.
- Conformance tests derived from published specifications: the POSIX regular-expression chapter, the GNU grep and sed manuals, the Rust `regex` crate documentation. Pin versions in `docs/compatibility/`.
- Differential tests against pinned reference implementations, such as GNU grep and ripgrep, where the licences and platforms permit.
- Fuzz and property tests that check three things: no crash on arbitrary patterns or haystacks, the DFA and NFA paths agree, and results are the same for slice and streamed input.
- Pathological-pattern tests such as `(a*)*b` to prove the linear-time claim, and allocation-failure tests (`std.testing.FailingAllocator`).
- Benchmarks against representative grep workloads before any performance claim.
- Test scripts and fixtures go in `test/` (AGENTS.md §11).

## 8. Documentation

- `SPEC.md`: this file.
- `docs/architecture.md`: the implemented structure, once it exists.
- `docs/decisions/`: engine strategy, Unicode data source, Perl-subset scope.
- `docs/compatibility/`: per-syntax supported constructs, deviations and reference versions.

## 9. Open decisions

1. From scratch, or port the published designs of existing engines (for example RE2, Rust `regex`, TRE), and which licences are acceptable for any ported code.
2. Unicode data: what Zig 0.17's standard library provides, or whether tables must be generated at build time from the Unicode Character Database, and which Unicode version to pin.
3. The exact Perl-compatible subset for `grep -P`, and whether full PCRE2 compatibility is a goal or the vendored C library is a better fit under AGENTS.md §7.
4. Multi-pattern strategy for large sets (`grep -f`): one combined automaton, or a prefilter such as Aho-Corasick, or Teddy-style SIMD for small literal sets.
5. Whether captures are needed on the DFA fast path or only on the slower paths.
6. Streaming semantics: how a match that crosses a buffer boundary is handled, and the maximum look-behind the engine requires.
7. Whether the library API is generic over the haystack encoding at comptime or selects it at runtime.

## 10. Initial acceptance criteria

A first usable release exists when:

- BRE and ERE compile and match with GNU-compatible results on a documented test set, with the compatibility gaps listed.
- Linear-time behaviour on pathological patterns is demonstrated by tests.
- Core Utils can build a minimal `grep` on it, and that `grep` passes its tests under individual-executable and multicall builds.
- A reproducible contributor workflow (`zig build`, `zig build test`) exists and is documented.

References to consult during implementation: POSIX Base Definitions, Regular Expressions; GNU grep manual; GNU sed manual; Rust `regex` crate documentation and its syntax reference; RE2 syntax and design write-ups; the Unicode Standard Annex #29 and Technical Standard #18 for Unicode matching. This draft does not claim any of these were consulted or verified.

# Changelog

## 0.3.0

### Added
- **Lazy DFA** (forward and reverse) as the default engine for eligible patterns. It finds where a match ends and starts; the Pike VM runs only to fill in captures. This recovers, and mostly exceeds, the speed lost in 0.2.0 (`zig build bench`, MB/s, 0.2.0 to 0.3.0: `[a-z]+` 21 to 121, email-like 15 to 232, utf8 `\p{L}+` 3 to 144, alternation of words 55 to 396, literal `the` 217 to 499). Cache size is bounded by `Limits.max_dfa_cache`; when it keeps filling, the search falls back to the Pike VM. `Options.engine = .dfa` forces it.
- **Literal-prefix and first-byte skipping** in the DFA, using `std.mem` substring searches.
- **POSIX BRE** (`Dialect.posix_bre`) with the GNU extensions `\+ \? \|` and `\{m,n\}`, and the BRE rules for `*`, `^` and `$`. Leftmost-longest.
- **Rust regex syntax** (`Dialect.rust`): flags `i m s x U`, set operations in classes (`&&`, `--`, `~~`), `\u` escapes; back-references, look-around and other non-regular constructs are errors.
- **Word and text anchors** `\<`, `\>`, `` \` ``, `\'` in the POSIX dialects.
- **`RegexSet`**: many patterns searched together (`grep -f`), with `matchedPatterns`.
- **Line-oriented search**: `Searcher.matchingLines` over memory and `LineStream` over a `std.Io.Reader`, with invert (`grep -v`).
- **Tests:** agreement with GNU grep 3.12 on 1,400 generated BRE and ERE patterns, DFA-vs-Pike differential tests, fuzzing with arbitrary pattern bytes, allocation-failure tests.
- **Docs:** `docs/architecture.md`, ADR 0003 (the open decisions from SPEC section 9), compatibility pages for BRE and Rust, an implementation-status section in `SPEC.md`.

### Changed
- POSIX dialects: `$` is the end of the text, not "before a final newline".
- `Limits` has a new field `max_dfa_cache`; `Engine` has a new value `.dfa`; `Dialect` has `.posix_bre` and `.rust`; `Diagnostic` has a `pattern` field.

### Fixed
- Found by the new tests: a lazy-DFA cache that was left inconsistent after an allocation failure, and leaks when its initialisation failed part-way.

### Known limitations
- Captured groups and leftmost-longest spans are found by the Pike VM, which is slower (about 17 and 47 MB/s on the benchmark); `isMatch` and `find` without groups use the DFA.
- Sub-group positions can differ between engines for some quantified groups whose body can match the empty string, and in leftmost-longest mode follow thread priority, not the POSIX subexpression rule.
- GNU grep selects no line for a back-reference to a repeated group that can match empty (`b|((c?)){2}\1$`); regex-zig follows Perl semantics there.
- Streaming is line-oriented only. No SIMD prefilters of our own, no Aho-Corasick for large literal sets.
- Full Unicode case folding (ß to ss) and `\p{Script_Extensions}` are not supported. In `utf8` mode look-behind needs a fixed width in bytes.
- Not differentially tested against ripgrep or the Rust `regex` crate.

## 0.2.0

### Added
- **Linear-time engine.** A Pike VM now runs every pattern that has no back-reference, look-around, atomic group or possessive quantifier, in time proportional to input size. Pathological patterns such as `(a+)+$` and `(a*)*b` finish instead of hitting the step limit. Patterns that need the backtracker still use it. `Options.engine` (`.auto`, `.backtrack`, `.pike`) selects or forces an engine. See `docs/decisions/0002-matching-engines.md`.
- **Leftmost-longest matching** for `.posix_ere`, in both engines.
- **UTF-8 matching** (`Options.utf8`): code-point literals, `.`, classes and negation, `\x{...}`, invalid input never matches and never crashes (ADR 0001).
- **Unicode properties and classes** in `utf8` mode: `\p{..}` / `\P{..}` (General_Category, Script, Alphabetic, Lowercase, Uppercase, White_Space, Any, ASCII, Assigned), Unicode-aware `\w \d \s \b`, and the POSIX classes alpha, alnum, upper, lower, digit, space, word, blank. Tables are generated from Unicode 18.0.0 by `tools/gen_unicode.py`.
- **Unicode simple case folding** for `(?i)` in `utf8` mode (literals, classes, `\p{..}`, back-references).
- **Build option** `-Dunicode_tables=false` leaves the Unicode tables out (about 167 KB smaller in a ReleaseSmall program).
- **Searcher helpers:** `isMatch`, `matches` (iterator), `count`, `findAll`, `split`, `replaceAll` (with `$1`, `${name}`, `$$`).
- **Benchmarks:** `zig build bench` (ReleaseFast) with throughput and pathological-pattern cases.
- Differential tests that compare the two engines on random patterns, and on every behaviour test.

### Performance: read this before upgrading
The Pike VM trades speed for the linear-time guarantee, and there is no lazy DFA yet, so **ordinary patterns are slower than in 0.1.0** with the default engine (`zig build bench`, same machine, MB/s, before then after): literal `the` 783 to 217, alternation of words 233 to 55, `[a-z]+` 122 to 21, email-like 45 to 15, capture groups 49 to 16, utf8 `.+` 56 to 12, utf8 `\p{L}+` 114 to 3. Pathological patterns that used to fail with `StepLimitExceeded` now finish in milliseconds. If you only run trusted patterns and need the old speed, set `.engine = .backtrack`. A lazy DFA and literal prefilters are the planned fix.

### Known limitations
- Group positions can differ between the Pike VM and the backtracker for some quantified groups whose body can match the empty string; use `engine = .backtrack` when exact Perl capture positions matter there (ADR 0002, section 4).
- Sub-group positions in leftmost-longest mode follow thread priority, not the POSIX subexpression rule.
- Full Unicode case folding (ß to ss) and `\p{Script_Extensions}` are not supported.
- In `utf8` mode look-behind needs a fixed width in bytes.
- Not implemented yet: POSIX BRE, the Rust dialect, a lazy DFA, literal prefilters beyond the first-byte set, streaming input, multi-pattern sets.

## 0.1.0
- Perl, Oniguruma and POSIX ERE parsers and the bounded backtracking engine.

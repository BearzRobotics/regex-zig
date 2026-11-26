# 0001: UTF-8 matching

Status: **Accepted** (decisions in §8). Phases 1 to 3 (§9 to §11) are implemented.

Related: SPEC.md §2 goal 4 ("match over bytes by default and over UTF-8 when requested") and §6 (`utf8` option).

## 1. Problem

Matching is byte-based today (`src/parse.zig` header). In that mode:

- `.` and negated classes such as `[^a]` consume one byte, so on UTF-8 text they match half of a multibyte character.
- A class cannot hold a code point above 0xFF (`ByteSet` is 256 bits), so `[é]` and `[à-ü]` do not mean what a user expects.
- `\x{263A}` and `\p{..}` are rejected as unsupported.

A caller that wants character semantics (ripgrep-style dialect, `grep` in a UTF-8 locale) cannot get them.

## 2. Goals and non-goals

Goals:

1. An opt-in `utf8` mode where `.`, classes, escapes and negation operate on Unicode scalar values (U+0000..U+10FFFF, excluding surrogates).
2. Invalid UTF-8 in the haystack never causes undefined behaviour, a crash or an out-of-bounds read (SPEC §5). Pattern syntax in `utf8` mode must itself be valid UTF-8.
3. No cost for byte-mode users, and no change to byte-mode behaviour.
4. Keep the engine ready for the planned linear-time engine (SPEC §4: lazy DFA, Pike VM), which works on bytes.

Non-goals for the first phase: Unicode property classes (`\p{..}`), full Unicode case folding, grapheme clusters, normalization, locale collation.

## 3. Proposed design

### 3.1 Compile code points to UTF-8 byte sequences (recommended)

The parser produces code-point sets. The compiler turns each set into an alternation of **byte-class sequences** that accept exactly the well-formed UTF-8 encodings of those scalars. The matching VM keeps working on bytes and gains no new instructions.

Example: `[\u{80}-\u{7FF}]` becomes `[C2-DF][80-BF]`. A range spanning several encoded lengths is split into sub-ranges with equal-length encodings, then split again so each sub-range is a sequence of byte ranges. This is the standard range-splitting technique (used by RE2 and Rust's `regex-syntax`); it must be re-derived and tested here, not copied.

Well-formedness follows the byte-range table for UTF-8 in the Unicode Standard (Table 3-7) and RFC 3629: no overlong forms, no surrogates (ED A0..BF), nothing above U+10FFFF (F4 90+). *I have not read these in this session; the implementer must check the exact table against the sources before coding.*

Consequences:

- `.` and `[^a]` can never match an invalid byte, so invalid haystack input fails to match instead of misbehaving. Bytes that are not part of a valid sequence are skipped by the search loop.
- The existing prefilter (`first_bytes`) still works: it becomes the set of lead bytes.
- Look-around and back-references need no change in the VM.
- A future DFA needs no UTF-8 awareness.

### 3.2 Alternative considered: decode instructions in the VM

Add `any_cp` / `cp_set` instructions that decode a scalar at `pos`, then test it against a sorted range table (binary search).

- Simpler compiler and a smaller program for large classes.
- But the VM must define behaviour for invalid sequences on every instruction, the DFA would still need a byte form later (so the work is done twice), and byte-level prefiltering gets harder.

Rejected because the byte-sequence approach keeps one execution model. It is the main place to revisit if program size (below) proves unacceptable.

### 3.3 Changes by component

| Component | Change |
|---|---|
| `Options` | Add `utf8: bool = false` (name per SPEC §6). |
| `parse.zig` | In `utf8` mode, decode literal multibyte characters into code points; accept `\x{H..H}` up to 0x10FFFF and reject surrogates and larger values with a positioned `Diagnostic`; build classes as code-point range lists; negate over the scalar range (not over 0..255). Invalid UTF-8 in the pattern is `InvalidPattern`. |
| `ast.zig` | New node `cp_set` holding sorted, non-overlapping `[lo, hi]` ranges. `.any` in `utf8` mode means "any scalar". ASCII-only classes can stay `ByteSet`. |
| `program.zig` | Lower `cp_set` and `.any` to byte-sequence alternations, sharing common suffixes to bound size. Enforce `max_program_len` (`LimitExceeded`). |
| `backtrack.zig` | No new instructions. `find` skips start positions that are UTF-8 continuation bytes. `Matches` (`ops.zig`) advances by one whole character, not one byte, after an empty match, so empty matches never fall inside a character. Invalid bytes advance by one. |
| Look-behind | `back n` is a byte count. In `utf8` mode it is only valid when the sub-pattern has a fixed **byte** length (for example ASCII-only); otherwise report `Unsupported`. |

### 3.4 Size and resource behaviour

A negated or full-range class such as `[^a]` or `.` expands to the several byte sequences that cover U+0000..U+10FFFF (a handful of instructions with suffix sharing). Large Unicode classes would expand far more, which is why `\p{..}` is out of phase 1 and subject to `max_program_len`. Both figures are my estimates; **the actual sizes need to be measured on a prototype** before the limit defaults are changed.

Memory use and step counts stay inside the existing `Limits`.

## 4. Case-insensitive matching

`ignore_case` currently folds ASCII. Full Unicode folding needs data tables (the Zig standard library does not, as far as I know, ship case-folding tables; verify against the installed 0.17.1 source). Options: generate a compact table from the Unicode Character Database into the repo, or keep ASCII-only folding in `utf8` mode.

Proposed phase 1: ASCII-only folding, documented as a known deviation, with an `Unsupported` error where a pattern explicitly asks for something we cannot honour. Phase 2 decides about tables and records a dependency decision (AGENTS.md §7).

## 5. Phasing

1. **Phase 1:** `utf8` option, code-point literals, `.`, classes and negation, `\x{..}`, iterator advancement, fixed-byte-width look-behind, ASCII-only folding.
2. **Phase 2:** `\p{..}` / `\P{..}` and Unicode-aware `\w \d \s \b` (if chosen, §8), with generated tables.
3. **Phase 3:** Unicode case folding.

## 6. Testing

- Positive and negative cases for each construct in both modes, including multibyte literals, ranges crossing 1/2/3/4-byte boundaries, negated classes, and the iterator over text with multibyte characters (`x*` on `é`).
- Invalid-input robustness: truncated sequences, overlong encodings (C0 80), surrogates (ED A0 80), values above U+10FFFF (F4 90 80 80), stray continuation bytes. Expect no match and no crash, never a read past the end.
- A round-trip test: every scalar value encoded with `std.unicode` matches `.` exactly once, and every surrogate/invalid pattern is rejected. This can be exhaustive (about 1.1 million values).
- Regression: the existing 35 byte-mode tests must pass unchanged.
- Compare outputs against a reference engine with a documented version (Rust `regex` or PCRE2 in UTF mode) on a fixed corpus, and record that version.

## 7. Documentation to update with the implementation

`SPEC.md` §6 (final option name), `docs/compatibility/*.md` (per-dialect `utf8` behaviour and deviations), and a new `docs/architecture.md` entry for the lowering step.

## 8. Decisions

1. **Unicode-aware `\w \d \s \b`:** yes, in `utf8` mode, provided it is not awkward. Classes (`\w \d \s` and negations) fit the code-point-set mechanism directly once the phase-2 tables exist. `\b` is the awkward one: it is not expressible as byte sequences, so it needs a Unicode word-boundary assertion that decodes the character before and after `pos` (a bounded, local VM change, tested against invalid input). Until phase 2 these stay ASCII-only in `utf8` mode, and that is documented.
2. **Case folding:** ASCII-only in phase 1, as proposed (§4).
3. **Dialects:** all three dialects in phase 1. The parser is shared, so restricting `.posix_ere` would add a special case rather than remove work. `utf8` is orthogonal to leftmost-first versus leftmost-longest.
4. **Unicode data:** generated tables checked into the repo (phase 2), with the generator script and the Unicode version recorded. No dependency.
5. **Lowering strategy:** the byte-sequence approach (§3.1) stays the plan. Because it has not been measured, the first step of phase 1 is a size check: lower `.` and `[^a]` and record the instruction counts. If they are unreasonable, revisit §3.2 before building further.

## 9. Phase 1 results

Implemented: `Options.utf8`, UTF-8 validation of the pattern, code-point literals, `.`, classes and negation, `\x{..}`, iteration that never splits a character, and the fixed-byte-width look-behind rule, for all three dialects. Code: `src/utf8.zig` (ranges and lowering), `parse.zig`, `program.zig`.

**Size gate (§8.5), measured with the byte-sequence lowering and no suffix sharing:**

| Pattern (utf8) | Instructions | Byte sets |
|---|---|---|
| `.` | 49 | 11 |
| `(?s).` | 46 | 10 |
| `[^a]` | 49 | 11 |
| `\W` | 58 | 13 |
| `[à-ü]` | 5 | 1 |

These are small against `max_program_len` (100,000), so the gate passes and §3.2 stays rejected.

**Known cost.** The VM tries the byte sequences one after another, pushing a branch frame for each. A non-ASCII character in `.` therefore costs up to eight failed alternatives before the right one. Grouping sequences by lead byte (or a dispatch instruction) is a likely optimisation, to be done only with a benchmark.

**Testing.** `utf8.zig` checks the range splitting against `std.unicode` for every scalar value (about 1.1 million) on several range shapes, requires that no two sequences accept the same encoding, and checks ill-formed forms (overlong, surrogate, above U+10FFFF, truncated, stray continuation). `tests.zig` covers the parser, search and iteration behaviour, and invalid haystacks.

**Behaviour choices to be aware of.** In `utf8` mode `\xHH` is the scalar U+00HH (so `\xE9` is `é`, two bytes). A stray continuation byte is never a match start. `\W`, `\D`, `\S` and negated POSIX classes include all non-ASCII characters until phase 2.

## 10. Phase 2 results

Implemented: `\p{..}` / `\P{..}` / `\pL` / `\p{^..}`, Unicode-aware `\w \d \s \b`, and Unicode meanings for the POSIX classes alpha, alnum, upper, lower, digit, space, word and blank, all in `utf8` mode only.

**Tables (decision 8.4).** `tools/gen_unicode.py` generates `src/unicode_tables.zig` from the Unicode Character Database **18.0.0**. The header of the generated file records the version and the SHA-256 of every input file, and the script documents how to regenerate it. Only the Python standard library is needed, and only by maintainers. The checked-in file is about 225 KB of source: General_Category (all values and the groups L, LC, M, N, P, S, Z, C), Script (all scripts), Alphabetic, Lowercase, Uppercase, White_Space, Any, ASCII, Assigned, and the derived `\w` set. Names are matched loosely (UAX #44 LM3). The binary-size cost of linking the tables was not measured.

Verification done while generating: the General_Category tables partition the 1,112,064 scalar values exactly (no gaps or overlaps), and they agree with Python's `unicodedata` (Unicode 16.0) on every character assigned in 16.0 except U+0295, which the UCD 18.0.0 data lists as `Lo`, so the generator follows the source file.

**New VM instruction (a change to §3.1).** A large set cannot be lowered to byte sequences without hundreds of alternatives per character: `\p{L}` would be tried against all of them one after another, in a backtracking VM that also spends a step per attempt. So a set that needs more than 16 byte sequences compiles to one `cp_class` instruction instead. It decodes one well-formed UTF-8 character (invalid, truncated, overlong, surrogate and out-of-range sequences all fail) and binary-searches the range list. Smaller sets, including `.` and `[^a]`, still lower to byte sequences. This is the §3.2 approach used only where §3.1 does not scale. Consequences:

- Program size for `\p{L}+` is 12 instructions plus one shared range list (identical sets are shared; since 0.5.0 also between separate occurrences in a pattern).
- A future lazy DFA must lower `cp_class` to byte automata itself. It can reuse `utf8.appendSequences`, so no work is lost.
- The step budget counts one step per character for these classes. A test matches `\p{L}+` over 300,000 bytes of mixed text.

**`\b`.** The word-boundary assertion decodes the character before and after the position when it is not ASCII; an invalid or truncated neighbour is not a word character, and a position inside a character is never reported as a boundary.

**Behaviour choices.**
- An unknown property name is `InvalidPattern`; `\p{..}` without `utf8` is `Unsupported`.
- `\p{Name}` is tried as a binary property, then General_Category, then Script, as Rust's regex does; `gc=`, `sc=` and the long forms are accepted. Script_Extensions is not supported.
- `\w` follows UTS #18 Annex C: Alphabetic + Mark + Decimal_Number + Connector_Punctuation + Join_Control.
- `punct`, `cntrl`, `print`, `graph`, `xdigit` and `ascii` stay ASCII, because their Unicode definitions vary between engines.


## 11. Phase 3: case folding, and the tables build option

**Build option.** `zig build -Dunicode_tables=false` (also `b.dependency("regex", .{ .unicode_tables = false })`) leaves the generated tables out. Measured with a small program that compiles a pattern and searches, `zig build-exe -O ReleaseSmall -fstrip`: **356,456 bytes with the tables, 189,248 without** (167 KB). Without them, `\p{..}` is rejected as `Unsupported`, and `utf8` mode keeps ASCII-only `\w \d \s \b`, POSIX classes and case folding. The default is on. `zig build test` passes in both configurations; the tests that need the tables are skipped when they are off.

**Case folding.** Unicode *simple* case folding (CaseFolding.txt statuses C and S), generated into the same tables file. The generator groups the code points that fold to the same target into "orbits" (at most 4 members in Unicode 18.0.0) and emits the rows plus a sorted index.

- A literal under `(?i)` whose character has case variants becomes the set of its variants. Classes are folded after their members are collected and before negation, so `(?i)[^é]` excludes `É`. `\p{..}` under `(?i)` is widened the same way. Folding scans the roughly 1,400 orbits, not the class members, so `(?i)[^a]` costs the same as `(?i)[a]`.
- Back-references under `(?i)` compare characters, not bytes, so `(k)\1` matches `k` followed by KELVIN SIGN even though the two differ in length.
- Full case folding (one character folding to several, such as ß to ss) is not supported. `(?i)straße` does not match `STRASSE`.
- Unicode folding brings in non-ASCII variants of two ASCII letters (`k`: U+212A, `s`: U+017F), as UTS #18 requires and Rust's `regex` does. Those literals are no longer ASCII-only sets in `utf8` mode.

**Look-behind.** `fixedWidth` now accepts a character set whose members all encode to the same length, so `(?i)(?<=é)` and `(?<=[à-ü])` work in `utf8` mode. A case-insensitive `(?<=k)` or `(?<=s)` is rejected (the variants are 1 and 3, or 1 and 2, bytes). Per-length alternatives would lift this; not done.

**Testing.** Orbit invariants (every row ascending, every member finds its row), the examples above, both byte-mode and tables-off behaviour.

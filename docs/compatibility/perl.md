# Perl / Oniguruma dialects: compatibility record

Status: partial, first slice (not verified against reference engines).
Date: 2026-11-04

References: PCRE2 and Oniguruma (Ruby syntax) documentation. Neither was
consulted while writing this; expected results in `src/tests.zig` come from
the author's knowledge of those engines and are NOT differentially tested yet.

## Supported

- Literals, `.`, alternation (leftmost-first), groups: capturing, `(?:)`,
  named `(?<n>)` `(?'n')` `(?P<n>)`, atomic `(?>)`, comments `(?#)`.
- Quantifiers `* + ? {n} {n,} {n,m}` (and `{,m}` in Oniguruma), lazy `?`,
  possessive `+`. A `{` that is not a valid quantifier is a literal.
- Classes: ranges, negation, nested classes (union), POSIX `[[:name:]]`,
  `\d \w \s \h` and negations, escapes.
- Anchors: `^ $ \A \z \Z \b \B \G`.
- Back-references `\1` and `\k<name>`, look-ahead, fixed-width look-behind
  (each top-level alternative may have its own width).
- Inline flags `(?imsx-imsx)` and `(?flags:...)`, scoped to the enclosing group.
- Dialect differences: Oniguruma `^`/`$` are line anchors, `(?m)` = dot-all,
  `\h` = hex digit. Perl: `(?m)` = line anchors, `(?s)` = dot-all.
- Limits: pattern length, nesting depth, repeat count, program size, steps,
  stack frames. Exceeding one is an error.

## Not supported (reported as `error.Unsupported`)

`\p{..}`, `\X`, `\R`, `\K`, `\C`, absent operator, branch reset, class
intersection `&&`, code points above 0xFF, variable-length look-behind,
conditionals, recursion, callouts.

## Known gaps and deviations

- Byte matching by default: `.` consumes one byte, `\p{..}` is rejected, and
  `(?i)` folds ASCII letters only. With `Options.utf8` the pattern must be valid
  UTF-8 and matching is over Unicode scalar values: `.`, classes, negation,
  `\x{...}`, `\p{..}` / `\P{..}` (General_Category, Script, Alphabetic,
  Lowercase, Uppercase, White_Space, Any, ASCII, Assigned; Unicode 18.0.0),
  `\w \d \s \b` (UTS #18 Annex C definitions), the POSIX classes alpha, alnum,
  upper, lower, digit, space, word and blank, and case-insensitive matching by
  Unicode *simple* case folding (literals, classes, `\p{..}` and back-references;
  `(?i)k` also matches KELVIN SIGN, `(?i)s` also matches LONG S). Full folding,
  where one character folds to several (ß to ss), is not supported.
- Still ASCII-only in `utf8` mode: punct, cntrl, print, graph, xdigit, ascii and
  `\h`. `\p{Script_Extensions=..}` and other properties are rejected.
- Look-behind must have a fixed width in bytes. In `utf8` mode `(?<=.)` is
  rejected, and so is a case-insensitive `(?<=s)` or `(?<=k)`, whose variants
  have different encoded lengths; `(?<=a)`, `(?<=é)` with `(?i)`, and `(?<=[à-ü])`
  are fine.
- A match never starts inside a character; invalid UTF-8 in the haystack never
  matches `.` or a class and is not a word character.
- Building with `-Dunicode_tables=false` leaves out the Unicode tables (about
  167 KB less in a ReleaseSmall executable): `\p{..}` is then rejected, and
  `utf8` mode keeps ASCII-only `\w \d \s \b`, POSIX classes and case folding.
- Each `split` pushes a stack frame, so `.*` over an N-byte line needs N
  frames (default cap 4M). Single-byte-loop specialisation is planned.
- Back-reference to a group that did not participate fails (Oniguruma and
  PCRE default); not configurable.
- A first-byte prefilter skips start positions that cannot begin a match.
  No literal-prefix or required-substring optimisation yet.
- No linear-time engine yet (SPEC §2.2 is not met by this slice).

## Known engine difference

For a repeated group that can match empty and prefers to, the default engine can
choose a different match from Perl: `(\w{0,2}?)+b` on `cbb` gives `0..3`, Perl
`0..2`. `engine = .backtrack` gives Perl's result. See
`docs/decisions/0002-matching-engines.md`, section 4.

## Tests

`zig build test` — 28 tests including limits, allocation failure and
pathological patterns. No fuzzing or differential tests yet.

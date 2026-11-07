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

- Byte matching only: no UTF-8, no Unicode case folding; `.` consumes one byte.
- Case-insensitive matching is ASCII only.
- Nested quantifiers such as `(a+)+b` are exponential in a backtracker; the
  step budget turns this into `StepLimitExceeded`.
- Each `split` pushes a stack frame, so `.*` over an N-byte line needs N
  frames (default cap 4M). Single-byte-loop specialisation is planned.
- Back-reference to a group that did not participate fails (Oniguruma and
  PCRE default); not configurable.
- A first-byte prefilter skips start positions that cannot begin a match.
  No literal-prefix or required-substring optimisation yet.
- No linear-time engine yet (SPEC §2.2 is not met by this slice).

## Tests

`zig build test` — 28 tests including limits, allocation failure and
pathological patterns. No fuzzing or differential tests yet.

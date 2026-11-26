# Perl / Oniguruma dialects: compatibility record

Applies to 0.5.0. Dates: 2026-11-26.

References: the test suite's expected results (`src/tests.zig`). During the
2026-11 audit, random patterns and the backtracker's results for `.perl` were
compared with Perl 5.40.1; that comparison is **not** part of the test suite.
`.oniguruma` has not been compared with Oniguruma, and nothing has been
compared with PCRE2.

## Supported

- Literals, `.`, alternation (leftmost-first), groups: capturing, `(?:)`,
  named `(?<n>)` `(?'n')` `(?P<n>)`, atomic `(?>)`, comments `(?#)`, also
  between an atom, its quantifier and the quantifier's `?` or `+`.
- Quantifiers `* + ? {n} {n,} {n,m} {,m}`, lazy `?`, possessive `+`. A `{`
  that is not a valid quantifier is a literal (`{,}` is literal).
- Classes: ranges, negation, nested classes (union), POSIX `[[:name:]]`,
  `\d \w \s \h` and negations, escapes.
- Anchors: `^ $ \A \z \Z \b \B \G`.
- Back-references `\1`, `\k<name>` and `\k'name'`, also inside their own group
  (which then sees the previous iteration's capture); look-ahead; fixed-width
  look-behind (each top-level alternative may have its own width).
- `\10` and larger refer to a group only if that many groups have been opened
  before; otherwise they are octal escapes, as in Perl.
- `\Q..\E`, `\x..`, `\x{..}`, `\0..`.
- Inline flags `(?imsx-imsx)` and `(?flags:...)`, scoped to the enclosing group.
- Group names may not start with a digit. A name may be used twice;
  references then use the first.
- Dialect differences: Oniguruma `^`/`$` are line anchors, `(?m)` = dot-all,
  `\h` = hex digit. Perl: `(?m)` = line anchors, `(?s)` = dot-all.
- With `Options.utf8`: matching over Unicode scalar values, `\p{..}` / `\P{..}`
  (General_Category, Script, Alphabetic, Lowercase, Uppercase, White_Space,
  Any, ASCII, Assigned; Unicode 18.0.0), Unicode `\w \d \s \b` (UTS #18
  Annex C) and POSIX classes alpha, alnum, upper, lower, digit, space, word and
  blank, and Unicode *simple* case folding.

## Not supported (reported as errors)

`\X`, `\R`, `\K`, `\C`, the absent operator, branch reset, class intersection
`&&`, collating symbols `[[.x.]]` and equivalence classes `[[=x=]]` (in `.perl`;
`.oniguruma` reads them as nested classes),
variable-length look-behind, conditionals, recursion, callouts. Without
`utf8`: `\p{..}` and code points above 0xFF.

## Known deviations

- **Nested classes in `.perl`.** `[a[bc]]` is the union of `a`, `b`, `c`
  (Oniguruma syntax). Perl reads the class `[a[bc]` followed by a literal `]`.
  One consequence: Perl accepts `[[:]`, which is an unterminated class here.
- **Lazy loops that can match empty.** For a repeated group containing a lazy
  part that can match empty, the default engine can choose a different match
  from Perl: `(\w{0,2}?)+b` on `cbb` gives `0..3`, Perl `0..2`; likewise
  `c(b|.{0,2}?)*` on `cbc`. `engine = .backtrack` gives Perl's result
  (`docs/decisions/0002-matching-engines.md`, section 4).
- **Captures Perl keeps after backtracking.** In some patterns with forward or
  self references Perl matches using a capture left over from an abandoned
  path (`\1*?(.)c`). Here a group that has not participated makes the
  reference fail.
- **Empty matches in iteration**: after an empty match the next search starts
  one character later, so a non-empty match at that position is not reported
  (`|a` on `a`).
- Byte matching by default: `.` consumes one byte and `(?i)` folds ASCII only.
- Full case folding (ß to ss) and `\p{Script_Extensions}` are not supported.
  `punct`, `cntrl`, `print`, `graph`, `xdigit`, `ascii` and `\h` stay ASCII.
- Look-behind needs a fixed width in bytes. In `utf8` mode `(?<=.)` is
  rejected, and so is a case-insensitive `(?<=s)` or `(?<=k)`.
- A match never starts inside a character; invalid UTF-8 in the haystack never
  matches `.` or a class and is not a word character.
- Building with `-Dunicode_tables=false` leaves out the Unicode tables:
  `\p{..}` is rejected and `utf8` mode keeps ASCII classes and folding.
- On the backtracker each `split` pushes a stack frame, so `.*` over an N-byte
  line needs N frames (`Limits.max_stack`).

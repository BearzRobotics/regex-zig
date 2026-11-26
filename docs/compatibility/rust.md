# Rust regex syntax (`Dialect.rust`)

Applies to 0.5.0. The syntax of the Rust `regex` crate (as used by ripgrep), implemented from its documented behaviour. Selected constructs and random patterns were compared with ripgrep 15.1.0 (`--no-unicode`) during the 2026-11 audit; there is no differential test against it in the test suite.

## Supported

- Literals, `.` (not newline unless `(?s)`), classes with ranges and negation, POSIX classes `[[:alpha:]]`, nested classes, and the set operators `&&` (intersection), `--` (difference) and `~~` (symmetric difference), left-associative. Under `(?i)`, case folding applies to each operand before the operation.
- Escapes `\d \w \s \D \W \S`, `\n \t \r \f \v \a`, `\x7F`, `\x{10FFFF}`, `\u007F`, `\u{7F}`, `\U0000007F`, `\pL`, `\p{Greek}`, `\P{L}` (the property and Unicode escapes need `Options.utf8`).
- Anchors `^ $ \A \z \b \B`, and word start and end `\< \> \b{start} \b{end}`. `$` is the end of the text; `(?m)` makes `^` and `$` line anchors.
- Groups `(...)`, `(?:...)`, `(?P<name>...)`, `(?<name>...)`; flags `(?i) (?m) (?s) (?x) (?U)` and `(?flags:...)`, `(?-flags)`.
- Quantifiers `* + ? {n} {n,} {n,m}` and their lazy forms; `(?U)` swaps greedy and lazy.
- Leftmost-first matching.

## Rejected (errors, never ignored)

Back-references (`\1`, `\k<n>`), look-around, atomic groups, comments `(?#...)`, possessive quantifiers and nested quantifiers (`a**`, `a*+`), `\Z \G \Q \E \R \X \K \C \h`, a `{` that is not a valid repetition, a class escape at either end of a class range, `\b \< \>` inside a class, duplicate group names, `\b{start-half}` and `\b{end-half}` (unsupported), and `(?-u)` (Unicode mode is the `utf8` option, for the whole pattern). No construct in this syntax needs the backtracker, so patterns run on the linear-time engines, with one exception: a pattern whose linear-time program would exceed `Limits.max_program_len` (a large Unicode repeat such as `\p{L}{40}` in `utf8` mode) falls back to the bounded backtracker. `Regex.isLinearTime()` tells which happened; a caller that accepts untrusted patterns should check it.

## Differences from the crate

- The `\b{start-half}` and `\b{end-half}` assertions and the `(?R)` CRLF flag are not supported.
- Unicode mode is chosen with `Options.utf8`, not per pattern with `(?u)`; `(?u)` is accepted and has no effect.
- Iteration (`matches`, `findAll`, `count`, `split`, `replaceAll`) reports an empty match at the end of the previous match; the crate skips it. `x*` on `axxb` gives `0..0`, `1..3`, `3..3`, `4..4` here and not `3..3` in the crate. This is the same in every dialect.
- Case-insensitive matching uses Unicode simple case folding, as in the crate.

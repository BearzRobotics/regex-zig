# Rust regex syntax (`Dialect.rust`)

The syntax of the Rust `regex` crate (as used by ripgrep), implemented from its documented behaviour. Not tested against the crate itself; there is no differential test against it yet.

## Supported

- Literals, `.` (not newline unless `(?s)`), classes with ranges and negation, POSIX classes `[[:alpha:]]`, nested classes, and the set operators `&&` (intersection), `--` (difference) and `~~` (symmetric difference), left-associative.
- Escapes `\d \w \s \D \W \S`, `\n \t \r \f \v \a`, `\x7F`, `\x{10FFFF}`, `\u007F`, `\u{7F}`, `\U0000007F`, `\pL`, `\p{Greek}`, `\P{L}` (the property and Unicode escapes need `Options.utf8`).
- Anchors `^ $ \A \z \b \B`. `$` is the end of the text; `(?m)` makes `^` and `$` line anchors.
- Groups `(...)`, `(?:...)`, `(?P<name>...)`, `(?<name>...)`; flags `(?i) (?m) (?s) (?x) (?U)` and `(?flags:...)`, `(?-flags)`.
- Quantifiers `* + ? {n} {n,} {n,m}` and their lazy forms; `(?U)` swaps greedy and lazy.
- Leftmost-first matching.

## Rejected (errors, never ignored)

Back-references (`\1`, `\k<n>`), look-around, atomic groups, comments `(?#...)`, possessive quantifiers and nested quantifiers (`a**`, `a*+`), `\Z \G \Q \E \R \X \K \C \h`, and `(?-u)` (Unicode mode is the `utf8` option, for the whole pattern). No construct in this syntax needs the backtracker, so patterns run on the linear-time engines, with one exception: a pattern whose linear-time program would exceed `Limits.max_program_len` (a large Unicode repeat such as `\p{L}{40}` in `utf8` mode) falls back to the bounded backtracker. `Regex.isLinearTime()` tells which happened; a caller that accepts untrusted patterns should check it.

## Differences from the crate

- `\b{start}`-style word-boundary variants and the `(?R)` CRLF flag are not supported.
- Unicode mode is chosen with `Options.utf8`, not per pattern with `(?u)`; `(?u)` is accepted and has no effect.
- Case-insensitive matching uses Unicode simple case folding, as in the crate.

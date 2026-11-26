# POSIX basic regular expressions (`Dialect.posix_bre`)

Applies to 0.5.0. Matches GNU grep 3.12 `-G`, both which lines match and where, on the generated agreement test (`src/testdata/grep_cases.txt`, LC_ALL=C, 700 random patterns and 200 with `-i`). Not a claim of full POSIX or GNU compliance.

## Supported

- Ordinary characters, `.` (also matches a newline), bracket expressions `[...]` with ranges, negation, and the classes `[:alpha:]` etc. `[`, `&&` and a backslash inside a bracket are ordinary members, and a range may end at `[`.
- Groups `\( \)`, alternation `\|`, repetition `*`, `\+`, `\?`, intervals `\{m\}`, `\{m,\}`, `\{m,n\}`, `\{,n\}`, `\{,\}` (GNU extensions: `\+ \? \|`). A quantifier may follow a quantifier (`a**`).
- Back-references `\1` to `\9`.
- `^` anchors only at the start of the expression or of a group or alternative, and `$` only at the end of one; elsewhere they are ordinary characters. `*` at the start of an expression, group or alternative, or right after `^`, is an ordinary character.
- GNU escapes `\w \W \s \S \b \B \< \> \` \'`. Any other escaped character stands for itself.
- `(`, `)`, `|`, `+`, `?`, `{`, `}` are ordinary characters.
- `^` and `$` mean start and end of the text (the text is one line when used with `Searcher.matchingLines` or `LineStream`).

## Matching rule

Leftmost-longest for the overall match. Sub-group positions follow thread priority among matches of the same length; this is not the POSIX subexpression rule.

## Not supported

Equivalence classes and collating symbols (`[[=e=]]`, `[[.ch.]]`, reported as unsupported) and locale-dependent behaviour.

## Errors

Unterminated `\(`, unmatched `\)`, malformed or unterminated `\{`, reversed ranges, and an interval with nothing to repeat are `InvalidPattern`; a count above `Limits.max_repeat` is `LimitExceeded`.

# POSIX ERE dialect: compatibility record

Status: partial, first slice (not verified against a reference engine).
Date: 2026-11-13

References: POSIX.1-2017, Base Definitions, chapter 9 "Regular Expressions"
(Extended Regular Expressions), and the GNU regex extensions described in the
glibc manual. Neither was consulted while writing this; the expected results in
`src/tests.zig` come from the author's knowledge and are NOT differentially
tested against `regcomp(REG_EXTENDED)` or GNU grep -E yet.

First consumer: dkman (`apropos` / `whatis` patterns).

## Supported (`Options.dialect = .posix_ere`)

- Literals, `.`, alternation, groups (all capturing), `* + ? {n} {n,} {n,m}`.
- A quantifier may follow a quantifier: `a*?` is `(a*)?`; there are no lazy or
  possessive forms. `(?` has no special meaning (`(?:a)` is an error: `?` has
  nothing to repeat).
- `.` matches a newline; `^` and `$` anchor at the text boundaries (as without
  `REG_NEWLINE`).
- Bracket expressions: ranges, negation, `[[:alpha:]]`-style classes; a
  backslash inside brackets is a literal.
- GNU escapes `\w \W \s \S \b \B` and back-references `\1`..`\9`.
- Any other escape stands for the character itself (`\.`, `\d` is `d`).

## Not supported

- `\<` and `\>` (word start/end): `error.Unsupported`.
- Collating symbols and equivalence classes `[[.x.]]`, `[[=x=]]`.
- Leftmost-longest matching. The engine is leftmost-first, so the *span* of a
  match can differ from `regexec`; whether a match exists does not. A consumer
  that only asks "does it match?" is unaffected.
- POSIX BRE.

## Matching rules and engines (version 0.2.0)

- `.posix_ere` is **leftmost-longest** for the overall match: the leftmost start wins, then the longest end (`a|ab` on `abc` matches `ab`). Sub-group positions follow thread priority among matches of the same length, which is not the POSIX subexpression rule.
- Patterns without back-references run on the Pike VM in time linear in the input; patterns with back-references run on the backtracker (still leftmost-longest, bounded by the step limit). See `docs/decisions/0002-matching-engines.md`.
- `Options.utf8` works with this dialect: `.`, bracket expressions and negation use Unicode scalar values; `\w`, `\s` and the POSIX classes alpha, alnum, upper, lower, digit, space and blank are Unicode-aware; `(?i)` equivalents use simple case folding. See `perl.md` for the full list.

# POSIX ERE dialect: compatibility record

Applies to 0.5.0. Date: 2026-11-26.

Reference: GNU grep 3.12 `-E`, `LC_ALL=C`. The test suite checks which lines
match **and where** (`grep -ob`) on 700 generated patterns, plus 200 with `-i`
(`src/testdata/grep_cases.txt`, made by `tools/gen_grep_cases.py`). This is not
a claim of full POSIX or GNU compliance; POSIX.1 itself was not consulted.

## Supported (`Options.dialect = .posix_ere`)

- Literals, `.`, alternation, groups (all capturing), `* + ? {n} {n,} {n,m}`,
  and as in GNU `{,m}` and `{,}`.
- A quantifier may follow a quantifier: `a*?` is `(a*)?`; there are no lazy or
  possessive forms. `(?` has no special meaning (`(?:a)` is an error).
- A `)` with no group open is a literal. A `{` that is not a valid interval is
  a literal.
- `.` matches a newline; `^` and `$` anchor at the text boundaries (as without
  `REG_NEWLINE`).
- Bracket expressions: ranges, negation, `[[:alpha:]]`-style classes. `[`,
  `&&` and a backslash are ordinary members, and a range may end at `[`.
- GNU escapes `\w \W \s \S \b \B \< \> \` \'` and back-references `\1`..`\9`.
  Any other escape stands for the character itself (`\.`, `\d` is `d`, `\Q`
  is `Q`).
- With `Options.utf8`, `.`, brackets and negation use Unicode scalar values;
  see `perl.md` for what becomes Unicode-aware.

## Matching rules and engines

- **Leftmost-longest** for the overall match: the leftmost start wins, then the
  longest end (`a|ab` on `abc` matches `ab`). Sub-group positions follow thread
  priority among matches of the same length, which is not the POSIX
  subexpression rule.
- Patterns without back-references run in time linear in the input per search;
  patterns with them run on the backtracker, bounded by the step limit.
  `isMatch` stops at the first match; `find` has to try the alternatives to
  find the longest.

## Differences from GNU grep

- Collating symbols and equivalence classes `[[.x.]]`, `[[=x=]]` are reported
  as unsupported.
- grep rejects `[:alpha:]` written without outer brackets, and a `-` right
  after a range (`[a-z-x]`); both are accepted here as ordinary classes.
- `a{}` and a quantifier at the start of an expression are handled differently:
  `a{}` is literal here (grep: error), `*a` is an error here (grep: warning).
- For a back-reference to a group that is repeated and can match empty, such as
  `b|((c?)){2}\1$`, GNU grep selects fewer lines; this library follows Perl.

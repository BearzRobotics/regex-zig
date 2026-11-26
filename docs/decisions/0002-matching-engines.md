# 0002: Matching engines

Status: **Accepted**. Steps A (Pike VM and engine selection, section 6) and B (lazy DFA, section 9) are implemented.

Related: SPEC.md §2 goals 2 and 3, §4 (architecture), §5 (leftmost-longest for POSIX), §9 decisions 1 and 5.

## 1. Problem

Every pattern currently runs on the backtracking VM. It is bounded by a step budget, not by input size, so `(a+)+$` on thirty `a`s fails with `StepLimitExceeded` and a long scan can exhaust the budget (both are pinned by baseline tests; `zig build bench` shows throughput and the pathological cases). SPEC §2.2 requires linear time for every pattern without back-references or look-around. SPEC §5 requires leftmost-longest results for the POSIX syntaxes, and the backtracker is leftmost-first.

## 2. Design

Three engines over one AST, with the engine chosen at compile time:

| Engine | Handles | Guarantee | Gives |
|---|---|---|---|
| Backtracker (exists) | everything, including back-references, look-around, atomic groups, possessive quantifiers | bounded by `Limits`, not linear | spans, captures |
| Pike VM (step A) | everything except those four features | O(program size × input size) | spans, captures |
| Lazy DFA (step B) | the same patterns, but only some assertions | O(input) after warm-up, bounded cache | match end only |

Selection (`Options.engine = .auto`):

1. A pattern that uses back-references, look-around, atomic groups or possessive quantifiers uses the backtracker.
2. Any other pattern uses the Pike VM (and later the DFA as an accelerator in front of it).
3. If the pattern is too large to compile for the Pike VM (`max_program_len`), it falls back to the backtracker. This loses the linear guarantee and is documented.

`Options.engine` can force `.backtrack` or `.pike`, so tests can run both (SPEC §4: "can be forced for testing").

## 3. The NFA program

The Pike VM and the DFA run over bytes in lockstep, so every consuming instruction must consume exactly one byte. The backtracker program does not satisfy that in `utf8` mode (`cp_class` consumes 1 to 4 bytes). So a second program, the **NFA program**, is compiled from the same AST by the same compiler with `nfa = true`:

- It uses only `byte`, `any`, `any_nl`, `set`, `split`, `jmp`, `save`, `assertion` and `match`.
- No loop guards (`mark` / `loop_end`). An unbounded repeat is compiled as `split(body, exit); body; split(body, exit)` (do-while) rather than `L: split(body, exit); body; jmp L`. The Pike VM's per-position visited set stops empty loops, and with this shape an empty iteration continues to the exit at the priority of the body, as in Perl. With a jump back to the entry, that path was cut and the Pike VM returned a different span from the backtracker (found by the differential test on `(b{0,2}?|cc?)*X`).
- Character sets in `utf8` mode are lowered to UTF-8 byte sequences, always, as a **prefix trie** (sequences that share their first byte ranges share instructions), so the lead byte does not fan out into one thread per sequence. A large class such as `\p{L}` is a few thousand instructions here, where the backtracker uses a single `cp_class`.

A large pattern may exceed `max_program_len` in this form (for example `\p{L}{100}`); selection rule 3 covers it.

## 4. Semantics

- **Leftmost-first** (Perl dialects): threads are kept in priority order; the first thread to reach `match` cuts off all lower-priority threads. This is the same result the backtracker gives, which is what the differential tests check.
- **Leftmost-longest** (`.posix_ere`, later BRE): the leftmost start wins, then the longest end. Threads are not cut off by priority; a match replaces the best one only if it starts earlier or, from the same start, ends later. The backtracker also supports this mode (it explores all alternatives and keeps the longest), so ERE patterns with back-references get the same overall rule, at exponential worst-case cost bounded by `Limits`.
- **Captures.** The Pike VM carries a capture array per thread, so it returns the same captures as the backtracker, with two known differences, to be documented in `docs/compatibility/`:
  - Loops whose body can match the empty string: the do-while shape above keeps the captures of an empty iteration, as the backtracker does, and overall spans agree. **Known remaining difference:** the *group* positions can still differ from the backtracker for some quantified groups whose body can match empty, for example `\b(.?|$(^a|^b)+\b)*b` on `bbc` (found by the differential test with group comparison forced on). The random differential test therefore compares groups only when no quantifier is applied to a group. To be investigated; use `engine = .backtrack` when exact Perl capture positions matter in such patterns.
  - **Overall spans can differ too** (found later; this corrects the statement above that they agree). It takes a repeated group with a lazy part that can match empty; `c(b|.{0,2}?)*` on `cbc` is another case. In `(\w{0,2}?)+b` on `cbb`, Perl and the backtracker match `0..2`; the Pike VM and the DFA match `0..3`. A new, empty iteration reaches an instruction already visited at that position, so the path from there to the loop exit is lost and a lower-priority path wins. The visited set is what bounds the Pike VM's work; fixing this needs it to tell apart arrivals with and without progress, which is not done. Use `engine = .backtrack` where Perl's exact choice matters. A test pins the behaviour.
  - In leftmost-longest mode, groups follow the priority order among threads that end at the same longest position. This is not the POSIX subexpression rule. Overall spans follow POSIX.
- **Assertions.** `^ $ \A \z \Z \G \b \B` are evaluated in the closure with the real haystack, so Unicode `\b` works in the Pike VM exactly as in the backtracker. (The DFA will support only the assertions it can encode in its state; others fall back to the Pike VM.)
- **UTF-8.** A match never starts inside a character, as in the backtracker.

## 5. Resource use

- **Per search, not per iteration.** "Linear" describes one `find`. Iterating over all matches repeats it, and a search may need the rest of the input to confirm a short match, so `count` or `replaceAll` can be quadratic (`a.*b|a` on a run of `a`s: 80,000 bytes took about 6 s).
- Pike VM memory: two thread lists, each with a capture array per instruction: about `2 × t × (2g + 2) × 8` bytes for `t` instructions that can hold a thread (byte-consuming ones and `match`) and `g` groups, allocated once per `Searcher`. This grows with the product, so it is capped by `Limits.max_capture_bytes` (64 MiB by default), checked at compile time.
- No allocation during a search. The explicit stack used for the closure is bounded by the instruction count and reused.
- The step budget does not apply to the Pike VM, because its work is bounded by input size.

## 6. Step A as implemented

Files: `src/pike.zig` (the VM), `src/context.zig` (assertion and UTF-8 helpers shared with the backtracker), `src/program.zig` (NFA compile mode, `needsBacktracker`, `Nfa`), `src/backtrack.zig` (engine dispatch, leftmost-longest mode), `src/root.zig` (`Options.engine`).

Verification: the pathological baseline tests flip to "completes and reports no match"; a deterministic randomized differential test compares the Pike VM with the backtracker on generated patterns and haystacks (spans always, captures when no loop body can be empty); every existing behaviour test runs on both engines.

## 7. Alternatives considered

- **Memoizing backtracker** (visited bitset over (pc, position)). Linear in time with O(program × input) memory, but it cannot report leftmost-longest and gives no path to a DFA.
- **DFA only.** Cannot produce captures, so a second engine would be needed anyway.
- **Stepping the Pike VM by character** instead of by byte. This would let `cp_class` stay one instruction, but priorities between threads that finish at different positions become ambiguous, which breaks leftmost-first.


## 9. Step B: the lazy DFA

Files: `src/dfa.zig`; `program.zig` (reverse compile, eligibility, literal prefix); `backtrack.zig` (`Searcher.findDfa`, `matchesAnywhere`).

**Shape.** A DFA state is an ordered list of NFA instructions to resume at plus the kind of the previous byte (text edge, newline, word, other). Empty-width assertions are evaluated when a transition is built, from the previous byte (in the state) and the next byte (the transition's symbol), so `^ $ \b \B \< \>` need no special states. A transition returns the next state and whether a match ends at the current position, before the next byte (a match is reported one byte late, as in other lazy DFAs). Bytes are grouped into equivalence classes so a state needs one transition per class, not 256.

**Two directions.** The forward, unanchored DFA is leftmost-first (a match drops lower-priority threads, including later starts) and gives the end of the leftmost-first match. The same pattern compiled right to left, anchored at that end and keeping all threads, gives the start: it is the smallest start of any match ending there, which equals the leftmost start. The Pike VM runs only to fill in captures, starting at the DFA's start. Leftmost-longest dialects use the DFA only to decide that a match exists (earliest-ending match end cannot give the leftmost start), then the Pike VM finds the span.

**Eligibility.** No `\G`, and no `\b \B \< \>` when `utf8` is on with the Unicode tables (a Unicode word boundary needs the characters around the position, not one previous byte). `$` and `\Z` are evaluated as end of text, so a haystack that ends in a newline is searched with the Pike VM when the pattern contains one (checked per search).

**Cache.** States and transitions are cached up to `Limits.max_dfa_cache` (2 MiB default) per direction. When full the cache is cleared; after four clears in one search the DFA gives up and that search runs on the Pike VM. Adding a state is atomic with respect to allocation failure (found by the allocation-failure test).

**Prefilters.** When nothing is running and the pattern cannot match empty, the forward DFA skips to the next byte a match can start with (`memchr`-style for one byte), or, for a literal prefix of two or more bytes, to the next occurrence of the prefix with a substring search. No SIMD code of our own: this is `std.mem.indexOfScalarPos` and `indexOfPos`.

**Results.** On `zig build bench` (same machine, MB/s): `[a-z]+` 21 (Pike only) to 121, email-like 15 to 232, utf8 `\p{L}+` 3 to 144, alternation of words 55 to 396, literal `the` 217 to 499. Captured groups still take the Pike VM (about 17 MB/s), and a leftmost-longest `find` too (about 47 MB/s); `isMatch` is the fast path for those.

**Testing.** Randomized differential tests compare the DFA with the Pike VM (spans, groups, `isMatch`, iteration) over four syntaxes; targeted tests cover a tiny cache, final newlines, ASCII and Unicode word boundaries, prefixes, and utf8.

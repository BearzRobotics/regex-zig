# 0002: Matching engines

Status: **Accepted** (the order of work was approved in the roadmap discussion). Step A (Pike VM and engine selection) is described in section 6 as it is implemented.

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
  - In leftmost-longest mode, groups follow the priority order among threads that end at the same longest position. This is not the POSIX subexpression rule. Overall spans follow POSIX.
- **Assertions.** `^ $ \A \z \Z \G \b \B` are evaluated in the closure with the real haystack, so Unicode `\b` works in the Pike VM exactly as in the backtracker. (The DFA will support only the assertions it can encode in its state; others fall back to the Pike VM.)
- **UTF-8.** A match never starts inside a character, as in the backtracker.

## 5. Resource use

- Pike VM memory: two thread lists, each with a capture array per instruction: about `2 × n × (2g + 2) × 8` bytes for `n` instructions and `g` groups, allocated once per `Searcher`. A program has at most `max_program_len` instructions.
- No allocation during a search. The explicit stack used for the closure is bounded by the instruction count and reused.
- The step budget does not apply to the Pike VM, because its work is bounded by input size.

## 6. Step A as implemented

Files: `src/pike.zig` (the VM), `src/context.zig` (assertion and UTF-8 helpers shared with the backtracker), `src/program.zig` (NFA compile mode, `needsBacktracker`, `Nfa`), `src/backtrack.zig` (engine dispatch, leftmost-longest mode), `src/root.zig` (`Options.engine`).

Verification: the pathological baseline tests flip to "completes and reports no match"; a deterministic randomized differential test compares the Pike VM with the backtracker on generated patterns and haystacks (spans always, captures when no loop body can be empty); every existing behaviour test runs on both engines.

## 7. Alternatives considered

- **Memoizing backtracker** (visited bitset over (pc, position)). Linear in time with O(program × input) memory, but it cannot report leftmost-longest and gives no path to a DFA.
- **DFA only.** Cannot produce captures, so a second engine would be needed anyway.
- **Stepping the Pike VM by character** instead of by byte. This would let `cp_class` stay one instruction, but priorities between threads that finish at different positions become ambiguous, which breaks leftmost-first.

## 8. Not decided here

The lazy DFA's cache policy and assertion support (step B), and streaming (SPEC §9.6), get their own sections or ADRs when they are done.

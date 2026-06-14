# mcfuzz coverage TODO

A prioritized backlog of what the type-directed fuzzer (`tools/fuzz/mcfuzz.py`) could
still support, split into *new surface to generate* and *new ways to check*. Parked here
to pick up later. See also memory `differential-testing.md`.

## Strategic framing

The single biggest blind spot: **every value-oracle compares the two backends against
each other** (differential, pipeline, sanitize, determinism all assume C≡LLVM ⇒ correct).
They share the entire frontend, MIR verifier, and constant-folder, so a bug *there* is
invisible to all of them. The >512-block verifier bug was only caught because `pipeline`
is a *status* oracle. ⇒ The highest-leverage additions are **independent** checks (E1, E2).

## Recommended order (do roughly top-to-bottom)

1. **C1** remaining wrapping ops — cheap, signed-domain history says bugs lurk.
2. **C2** remaining checked ops.
3. **C3, C8** sat in comparisons; richer boolean nesting.
4. **B3, B1, B2** early return; `for`; `break`/`continue`.
5. **D1** globals — high value (mc_race_load helpers; 2 past C bugs lived here).
6. **E2** metamorphic oracle — catches codegen bugs with no 2nd backend.
7. **E1** reference interpreter — *the* structural win; sees the shared-frontend bug class.
8. **A1** `Result<T,E>` + `?` propagation.
9. **A2** tagged unions with payload.
10. **A6** fold `move`/`defer` into mcfuzz (today only in `mcgen_move`).
11. **A3 → A5** optionals → pointers → slices (unlocks **E5** memory-safety oracle).
12. **A7** f32 (blocked on double-literal-suffix fix).
13. Remaining infra/oracles (E3–E8, F-series) and the high-effort type features
    (A8 generics, A9 closures, D5 multi-module).

---

## Implementation notes already discovered (don't re-derive)

- **wrapping.sub/mul/neg/bit_* are NOT user-callable.** `sema.zig:6923` only accepts
  `wrapping.add`. The other wrapping ops are reachable **only via the `wrap<T>` arithmetic
  domain** (`+ - *`, and bitwise/shift for unsigned). ⇒ implement **C1 by adding `wrap<uN>`
  and `wrap<iN>` domain types**, mirroring exactly how `sat<uN>` was added (TYPES entry with
  `kind="wrap"`, a `WRAPS` list, a `gen_value` branch, fold via `uN.wrap_from`). This is also
  genuinely new codegen (wrap-domain lowering), distinct from the `wrapping.add` builtin.
- **`sat<T>` is unsigned-only** (`sat<iN>` → `E_ARITH_DOMAIN_UNSIGNED`); `+ - *` work; fold
  via `uN.wrap_from(x)`. Already implemented.
- **Open enums** extract via `.raw()` (not `as u8`); `open enum O: u8 {…}`. Closed enums
  need an exhaustive switch (kept for the representation-check path). Already implemented.
- **INT64_MIN literal**: C backend now emits `(-9223372036854775807LL - 1)` for a negated
  2^63 magnitude (fixed in `lower_c.zig`). Positive 2^63 in a u64 context stays bare.
- Globals exist: `global name: T = …;` and are mutable; in-place field/index stores work.
- `saturating.add` / `checked.sub` etc. as *user call syntax* do **not** exist — domains only.

---

## A. Type system — values to generate

| # | Item | Effort | Notes |
|---|------|--------|-------|
| A1 | `Result<T,E>` (`ok`/`err`, `?` propagation) | Med-High | Error edges + early return; only in `mcgen_move` today |
| A2 | Tagged `union` with payload (`.variant(payload)`, payload-binding switch) | Med-High | Tag+payload layout; finicky syntax |
| A3 | Optionals `?*T` (nullable pointers) | Med | Needs null/unwrap oracle |
| A4 | Pointers / references `*T`, address-of, deref | High | Lifetime/alias tracking |
| A5 | Slices `[]T` (ptr+len), slicing | High | Unlocks bounds oracle (E5) |
| A6 | `move` linear types + `defer` cleanup | Med | Exists in `mcgen_move`; unify; invariant `live_count==0` |
| A7 | f32 | Low-Med | **Blocked** on double-literal-suffix fix (currently excluded) |
| A8 | Generics / type parameters | High | Monomorphization path |
| A9 | Closures / fn pointers / `Allocator` vtable | High | `-fsanitize=function` ABI surface |
| A10 | `usize`/`isize` in more positions | Low | Partially present |
| A11 | Type aliases (`type Name = …`) | Low | Alias resolution in lowering |
| A12 | Deeper aggregates (structs-of-slices, arrays-of-unions) | Low | After A1–A5 |
| A13 | Closed enums with explicit `: u8` repr + custom discriminants | Low | `enum E: u8 { A = 3 }` discriminant codegen |

## B. Language constructs / control flow

| # | Item | Effort | Notes |
|---|------|--------|-------|
| B1 | `for` loops | Low-Med | Confirm MC `for` syntax first |
| B2 | `break` / `continue` / labeled loops | Low-Med | New CFG edges |
| B3 | Early `return` in harness body | Low | Single trailing return today |
| B4 | Nested/expression `switch` (switch as value) | Low-Med | Statement/fold only today |
| B5 | `if` as expression / ternary | Low | If MC supports it |
| B6 | Recursion (self / mutual) | Med | Function DAG acyclic by design; needs bounded-termination story |
| B7 | Block expressions / shadowing scopes | Low | Scope resolution |
| B8 | `defer` in non-move contexts | Low | Ordering/cleanup codegen |

## C. Operators / arithmetic / expressions

| # | Item | Effort | Notes |
|---|------|--------|-------|
| C1 | Remaining wrapping ops via `wrap<T>` domain (`+ - *`, bitwise) | **Low** | Only `wrapping.add` builtin used today; see notes above |
| C2 | Remaining checked ops (`checked.sub/mul`, checked neg) | Low | Trap-edge coverage — domain/op forms only |
| C3 | `sat<uN>` in comparisons / mixed positions | Low | sat supports ordering; only arith+fold today |
| C4 | Cross-domain conversions (`wrap`↔`sat`↔plain) | Med | Domain-mixing rejection + valid conversion codegen |
| C5 | Checked `<<` overflow trap in trapping mode | Low | Currently excluded as "not trap-free" |
| C6 | Bitwise on more widths / rotate if available | Low | |
| C7 | Float intrinsics (sqrt/abs/min/max) if exposed | Med | Observe by comparison |
| C8 | Boolean short-circuit `&&`/`||` nesting | Low | Richer `gen_bool` |
| C9 | Pointer/index arithmetic edges | High | Depends on A4/A5 |

## D. Declarations / program structure

| # | Item | Effort | Notes |
|---|------|--------|-------|
| D1 | Global / module-level vars (incl. mutable statics) | Med | **High value** — `mc_race_load` helpers; 2 past C bugs here |
| D2 | `extern fn` decls + calls | Med | ABI/linkage |
| D3 | Multiple `export` fns / richer harness ABI | Low | Calling-convention variety |
| D4 | `const` globals & compile-time constant exprs | Low-Med | Constant-folder (pairs with E1) |
| D5 | Imports / multi-module programs | High | Cross-module resolution |
| D6 | Attributes / contracts / `comptime` blocks if present | Med | Profile-specific |

## E. New oracles (ways to check)

| # | Item | Effort | Notes |
|---|------|--------|-------|
| E1 | **Reference interpreter** (eval `harness()` from AST/HIR, assert digest) | High | **Highest leverage** — catches bugs both backends share |
| E2 | **Metamorphic/algebraic** (semantics-preserving transform → same digest) | Med | `x+0`, commutativity, dead branches; no 2nd backend |
| E3 | Optimization-level differential | Low-Med | If backends expose `-O` levels |
| E4 | Independent oracles on `facts`/`emit-map`/`lower-hir/-mir/-ir` | Med | Today only verify-hir/verify/emit-c/emit-llvm asserted |
| E5 | Memory-safety oracle (ASan over pointer/slice programs) | Med | Depends on A4/A5 |
| E6 | Round-trip / idempotence (re-parse, re-lower → stable) | Med | Printer/parser asymmetries |
| E7 | Crash-bucketing & auto-minimization of findings | Med | Triage QoL |
| E8 | Trap-location agreement (same logical trap site) | Med | Stronger than "both trap" |

## F. Methodology / infrastructure

| # | Item | Effort | Notes |
|---|------|--------|-------|
| F1 | Coverage-guided / byte-seed fuzzing | High | **Blocked** by subprocess speed; needs in-process/persistent harness |
| F2 | Mutation-based *semantic* fuzzing of valid programs | Med | `robust` only mutates for crash/hang today |
| F3 | Corpus persistence + regression seed bank | Low-Med | Keep found-bug seeds as permanent gates |
| F4 | Parallel/persistent compiler process | Med | Throughput; prerequisite for F1 |
| F5 | Structured shrinker keyed on root-cause signature | Med | Differential shrinker times out on large programs |
| F6 | Swarm/config diversity (vary type-mix weights per run) | Low | Spread coverage |
| F7 | Statistical coverage reporting (`--report` mode) | Low | Did this ad-hoc; make it a flag |

---

## Already done (for reference, not TODO)

- Full scalar type system (int widths signed/unsigned, f64, bool), structs (nested DAG),
  closed + open enums, fixed arrays incl. arrays-of-structs / arrays-of-enums / nested `[N][M]T`,
  function DAG (params/ABI), if/else, while.
- `switch` in statement position (side-effecting arms).
- In-place aggregate mutation (`s.f =`, `a[i] =`, nested).
- `sat<uN>` saturating domain.
- Boundary-directed integer literals (→ found & fixed the INT64_MIN C-backend bug).
- Seven oracles: differential, fuzz-trap, sanitize, robust, failclosed, determinism, pipeline.

### Done 2026-06-14 (this pass)

- **C1** `wrap<uN>` arithmetic domain (`+ - * & | ^ >>`). → found & fixed a real C-backend UB
  (narrow `wrap<u16>` multiply promoted to signed `int` and overflowed; now computed in
  `unsigned int`).
- **C2** checked subtraction + checked negation (`-INT_MIN` traps).
- **C3** sat/wrap values in comparisons (sat ordering+equality, wrap equality only).
- **C8** `&&`/`||` short-circuit nesting in generated booleans.
- **B1** `for x in <array>` loops (element bound read-only).
- **B2** `break`/`continue` (loop counter increments first → no infinite loop on continue).
- **B3** conditional early `return`.
- **D1** module-level globals (exercise the mc_race_load/store helper path).
- **D4** `const` global named compile-time constants.
- **A13** closed enums with explicit `: u8` repr + custom discriminant values.
- **E2** metamorphic oracle (`fuzz-metamorphic`): a semantics-preserving transform
  (body-in-helper that harness() calls) must not change the result — catches single-backend
  codegen bugs the C-vs-LLVM differential cannot.

### Still open (largest / blocked — multi-session or design-gated)

- **E1** reference interpreter — highest leverage, but a full precise interpreter of the
  generated subset (all arithmetic domains, structs/arrays/enums/switch/loops/globals/tuples);
  high effort + high risk (a wrong interpreter yields false findings).
- **A1** `Result<T,E>`+`?`, **A2** unions, **A6** `move`/`defer` (exists in `mcgen_move`).
- **A3→A5** optionals → pointers → slices (unlocks **E5** memory-safety oracle); **C9** ptr arith.
- **A8** generics, **A9** closures, **D5** multi-module — language-feature-heavy.
- **A7** f32 — blocked on the f32 double-literal-suffix backend fix.
- **F1** coverage-guided — blocked by subprocess speed (needs persistent/in-process harness).
- Misc lower-value: C4/C6/C7, D2/D3/D6, E3/E4/E6/E7/E8, F2–F7, A10/A11/A12.

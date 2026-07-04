# mcfuzz coverage TODO

A prioritized backlog of what the type-directed fuzzer (`tools/fuzz/mcfuzz.py`) could
still support, split into *new surface to generate* and *new ways to check*. Parked here
to pick up later. See also memory `differential-testing.md`.

## Strategic framing

The single biggest blind spot: **every value-oracle compares the two backends against
each other** (differential, pipeline, sanitize, determinism all assume C≡LLVM ⇒ correct).
(**Update:** the independent oracles below — E1 reference interpreter and E2 metamorphic
— are now **implemented** as build steps (`fuzz-reference` / `fuzz-metamorphic`) and,
alongside `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-artifacts`, and `fuzz-corpus`,
are wired into both `m0` and `fast` in `build/tiers.zig`. The remaining backlog is
generator surface, where the differential oracles still apply.)

They share the entire frontend, MIR verifier, and constant-folder, so a bug *there* is
invisible to all of them. The >512-block verifier bug was only caught because `pipeline`
is a *status* oracle. ⇒ The highest-leverage additions are **independent** checks (E1, E2).

## Recommended order (do roughly top-to-bottom)

1. **C1** remaining wrapping ops — cheap, signed-domain history says bugs lurk.
2. **C2** remaining checked ops.
3. **C3, C8** sat in comparisons; richer boolean nesting.
4. **B3, B1, B2** early return; `for`; `break`/`continue`.
5. **D1** globals — high value (mc_race_load helpers; 2 past C bugs lived here).
6. ~~**E2** metamorphic oracle~~ — **DONE** (`oracle_metamorphic`, build step
   `fuzz-metamorphic`): a semantics-preserving source transform must not change the result.
7. ~~**E1** reference interpreter~~ — **DONE** (`tools/fuzz/mcref.py` + `oracle_reference`,
   build step `fuzz-reference`): an independent Python interpreter evaluates the same AST and
   the compiled output must match it — sees the shared-frontend bug class.
8. ~~**E6** round-trip/idempotence oracle~~ — **DONE** (`oracle_roundtrip`, build step
   `fuzz-roundtrip`): generated source and formatted source both check, formatting is
   idempotent, preserves the stripped token stream, and emits the same C after source-location
   normalization.
9. ~~**E4** artifact consistency oracle~~ — **DONE / expanding** (`oracle_artifacts`,
   build step `fuzz-artifacts`): facts, lower-MIR, lower-IR, and emit-map are parsed as real
   artifacts and checked for trap-edge and source-map invariants.
10. **A1** `Result<T,E>` + `?` propagation.
11. **A2** tagged unions with payload.
12. **A6** fold `move`/`defer` into mcfuzz (today only in `mcgen_move`).
13. **A3 → A5** optionals → pointers → slices (unlocks **E5** memory-safety oracle).
14. **A7** f32 (blocked on double-literal-suffix fix).
15. Remaining infra/oracles (E5, E8, F-series except F5) and the high-effort type features
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
| E1 | **Reference interpreter** (eval generated subset, assert digest) | Done / expanding | `fuzz-reference`, gated by `m0`/`fast`; highest leverage for bugs both backends share. Keep extending the interpreted subset as generator surface grows. |
| E2 | **Metamorphic/algebraic** (semantics-preserving transform → same digest) | Done / expanding | `fuzz-metamorphic`, gated by `m0`/`fast`; keep adding transforms for new constructs. |
| E3 | Optimization-level differential | Done / expanding | `fuzz-optlevel`, gated by `m0`/`fast`; keep widening the generated surface. |
| E4 | Artifact consistency oracle over `facts`/`emit-map`/`lower-mir`/`lower-ir` | Done / expanding | `fuzz-artifacts`, gated by `m0`/`fast`; checks stage status, MIR/IR trap-edge counters, checked-trap facts reaching IR, and core mcmap source/function/MIR-reference invariants. |
| E5 | Memory-safety oracle (ASan over pointer/slice programs) | Med | Depends on A4/A5 |
| E6 | Round-trip / idempotence (re-parse, re-lower → stable) | Done / expanding | `fuzz-roundtrip`, gated by `m0`/`fast`; generated and formatted source both check, `fmt(fmt(src)) == fmt(src)`, stripped token streams match, and emitted C matches after source-location normalization. |
| E7 | Crash-bucketing & auto-minimization of findings | Done / expanding | `mcfuzz.py run` prints root-cause bucket summaries on failure, can write `--triage-dir` JSONL findings, and `--shrink-failures` opt-in minimizes the first finding per signature. |
| E8 | Trap-location agreement (same logical trap site) | Med | Stronger than "both trap" |

## F. Methodology / infrastructure

| # | Item | Effort | Notes |
|---|------|--------|-------|
| F1 | Coverage-guided / byte-seed fuzzing | High | **Blocked** by subprocess speed; needs in-process/persistent harness |
| F2 | Mutation-based *semantic* fuzzing of valid programs | Med | `robust` only mutates for crash/hang today |
| F3 | Corpus persistence + regression seed bank | Low-Med | Keep found-bug seeds as permanent gates |
| F4 | Parallel/persistent compiler process | Med | Throughput; prerequisite for F1 |
| F5 | Structured shrinker keyed on root-cause signature | Done / expanding | `finding_signature()` is shared by run bucketing and shrink predicates, so shrinking preserves the normalized root-cause class instead of matching ad hoc substrings. |
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
- Eight oracles: differential, fuzz-trap, sanitize, robust, failclosed, determinism, pipeline,
  roundtrip.

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
- **A1** `Result<T, u32>` helper functions: ok/err returns, `?` propagation chains, folded by
  the harness via `switch r { ok(v)=>… err(e)=>… }` (XOR fold — a checked `+` would overflow/trap).
- **A11** type aliases (`type Alias = <int>`), transparent in use.
- **A7** f32 — **enabled** by fixing the C-backend f32 double-rounding bug (literal exprs now
  computed in `float` via an `f` suffix; was ~1 ULP off LLVM). Third real bug found+fixed.
- **A3** nullable pointers `?*T` to globals, read via `if let` narrowing.
- **A4** non-nullable pointers `*T` + deref.
- **A8** comptime-generic functions (`gid(comptime T: type, …)`, monomorphized per call type).
- **A9** capturing closures via `bind(&env, fn)` -> `closure(T)->R`.
- **E3** optimization-level differential oracle (`fuzz-optlevel`): emitted C must give the same
  result at -O0 and -O2 (no optimization-sensitive UB).
- **E1** reference interpreter (`fuzz-reference`): compiled output must match the independent
  Python interpreter for the generated subset.

**Tally: 19 coverage items + 3 promoted oracles (metamorphic, optlevel, reference) + 3 real
C-backend bugs found & fixed (INT64_MIN, narrow wrap-mul UB, f32 double-rounding). The original
core oracle family plus `fuzz-metamorphic`, `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-corpus`, and
`fuzz-reference` now gate both `m0` and `fast`.**

### Done 2026-07-04

- **E6** round-trip/idempotence oracle (`fuzz-roundtrip`): generated source and formatted source
  both check; `fmt(fmt(src)) == fmt(src)`; formatting preserves the position-stripped `mcc lex`
  token stream; and generated vs formatted source emit the same C after normalizing source-location
  directives.

### Done 2026-07-04 (E4 artifact consistency)

- **E4** artifact consistency oracle (`fuzz-artifacts`): for every generated program accepted by
  `mcc check`, run `facts`, `lower-mir`, `lower-ir`, and `emit-map`; report stage hang/crash/reject
  as findings; verify `mir`/`ir` function `trap_edges=N` counters match their concrete trap-edge
  rows; require checked arithmetic/shift facts to have a same-function/kind/source-position IR
  trap edge; and validate core `.mcmap` structure, positive source spans, source-origin paths,
  the exported `harness` function row, and MIR function references.

**Current tally: 19 coverage items + 5 promoted oracles (metamorphic, optlevel, reference,
roundtrip, artifacts) + 3 real C-backend bugs found & fixed. The original core oracle family plus
`fuzz-metamorphic`, `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-corpus`, `fuzz-reference`,
`fuzz-roundtrip`, and `fuzz-artifacts` now gate both `m0` and `fast`.**

### Blocked by missing backend support (can't be generated into runnable programs)

- **A2** tagged unions with payload — **not runtime-lowerable**: even the spec's own
  `ReflectToken` union fails both `emit-c` and `emit-llvm` (`UnsupportedC/LlvmEmission`); tagged
  unions are a sema/comptime-reflection construct only. Needs tagged-union codegen first.
- **A5** slices `[]T` — `arr[0..n]` -> `[]const T` hits `E_NO_IMPLICIT_POINTER_CONVERSION`; the
  slice-construction surface is finicky/limited. Deferred (would unlock E5 memory-safety oracle).
- **C4** cross-domain conversions — no clean plain↔`wrap`/`sat` conversion form
  (`wrap<u8>.from(p)` → `E_NO_IMPLICIT_CONVERSION`); only literal init + domain ops + `wrap_from`.
- **D2** `extern fn` calls — not runnable without linking external definitions the harness can't
  provide.
- **A6** `move`/`defer` — already covered by the separate `mcgen_move.py` generator.

### Still open (largest — multi-session or architecture-gated)

- **E1 expansion** — the reference interpreter exists, but must keep growing with the generator
  surface. The risk is now coverage and false findings in new interpreted constructs, not the
  absence of the oracle.
- **D5** multi-module — needs an import/module system (no such surface today).
- **F1** coverage-guided — blocked by subprocess speed (needs persistent/in-process harness).
- Misc lower-value: C6/C7 (mostly covered), D3/D6, E5/E7/E8, F2–F7, A10 (usize already
  generated)/A12 (depends on A2/A5).

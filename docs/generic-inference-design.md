# Design note: inferring `comptime T: type` arguments at call sites

Status: **designed, not implemented.** This note records the desired feature, why it is
not a trivial change in the current pipeline, exactly what is and isn't soundly
inferable, and the recommended implementation path. It exists so the work is scoped
before it is built (the same way `docs/traits-design.md` preceded traits), rather than
shipping a half-version that infers some calls and not others.

## The feature

A generic function takes its type as a leading `comptime T: type` value argument:

```mc
fn make_pair(comptime T: type, x: T, y: T) -> Pair<T> { … }
fn sum_two(comptime T: type, a: *T, b: *T) -> u32 where T: Shape { … }

let p = make_pair(u32, x, y);        // today
let n = sum_two(Square, &s1, &s2);   // today
```

The ask (review item #2): allow omitting the leading type argument and inferring it from
the value arguments —

```mc
let p = make_pair(x, y);     // infer T from x
let n = sum_two(&s1, &s2);   // infer T = Square from *Square
```

## What is soundly inferable — and what is not

Inference deduces `T` by matching a value argument's **type** against the parameter type
with `T` as a free variable:

| call arg | param type | arg type | deduce |
|---|---|---|---|
| `&s1` (s1: Square) | `*T` | `*Square` | `T = Square` ✅ |
| `sq` (sq: Square) | `T` | `Square` | `T = Square` ✅ |
| `mk()` (mk → Square) | `T` | `Square` | `T = Square` ✅ |
| `b` (b: Box<Square>) | `Box<T>` | `Box<Square>` | `T = Square` ✅ (recursive match) |
| `20` | `T` | *(untyped int literal)* | **ambiguous** ❌ |
| `null` / `uninit` | `T` | *(no type)* | **ambiguous** ❌ |
| — (T only in return) | — | — | **not deducible** ❌ |

The motivating `make_pair(20, 22)` is in the ❌ rows: an MC integer literal is untyped
until a context fixes it, so `T` could be `u8`/`u16`/`u32`/… There is no sound choice, so
that call **must keep an explicit `T`** (or annotate the binding). Inference is therefore
"best effort, never wrong": when `T` is deducible from a typed value arg it is filled in;
otherwise the existing explicit-type-arg requirement stands. It must never *guess*.

## Why it is not a small change here

The pipeline is: parse → **sema (`checkModule`)** on the generic module → **lowering**,
inside which **`monomorphize.zig`** rewrites each generic call to a specialized instance
(`src/main.zig` `runEmitC`/`runEmitLlvm`; both run sema first, then `be.lower`). The two
relevant facts:

1. **The type info lives in sema.** Deducing `T = Square` from `&s1` requires knowing
   `s1: Square`. Only sema computes value-expression types (`exprResultType`,
   `checkExpr`).
2. **The rewrite lives in a type-blind pass.** `monomorphize.zig` is a syntactic
   clone/substitute pass (`rewriteGenericCall`, `monomorphize.zig:551`). It has the
   function table and trait-conformance map but **no local/parameter types**, so it can
   type neither `&s1` nor `x`. Its arity gate is exact:
   `if (node.args.len != info.decl.params.len) return null;`.

So the place that *could* infer (sema) is not the place that *does* the rewrite (mono),
and mono runs after sema on the same AST. Doing inference purely in mono only reaches the
`mk()`-returns-a-known-type row — not the motivating `&local` / bare-`local` rows — so a
mono-only version would infer almost none of the cases people actually want.

There is currently **no AST-mutation/desugar stage in sema** (expression-`switch` and
similar are desugared in the *parser*, which has no types). Adding one is the crux of the
work.

## Recommended implementation

**Sema-side inference that annotates the call, consumed by an unchanged monomorphizer.**

1. **Arity:** in sema's call check (`sema.zig`, the `.call` arm, ~`E_CALL_ARG_COUNT`),
   when the callee is a generic function and `args.len == params.len − (leading comptime
   type params)`, do not error — attempt inference instead. Mirror the relaxed arity in
   `monomorphize.zig:551`.
2. **Deduce:** for each missing leading type param `T`, find the first value parameter
   whose type mentions `T`, take the corresponding argument's type via `exprResultType`,
   and unify structurally (`T`, `*T`, `[N]T`, `Box<T>`, …) to a concrete type name. New
   helper, e.g. `deduceTypeParam(param_ty, arg_ty, "T") ?Ident`. Bail (require explicit)
   on an untyped literal / `null` / `uninit` / return-only `T`.
3. **Annotate:** insert the deduced type-name idents as the leading value arguments of the
   call node, so the post-sema AST looks exactly as if the user wrote them explicitly.
   This needs a *mutable* path to the call node (sema currently visits expressions by
   value) — either thread `*ast.Expr` through the relevant visitor, or run inference as a
   dedicated mutating mini-pass between `checkModule` and `be.lower` that re-derives the
   handful of types it needs. The latter keeps `checkModule` non-mutating.
4. **Downstream unchanged:** `monomorphize.zig` then sees a complete explicit call;
   substitution, mangling/dedup, and the `where T: Trait` bound check
   (`E_TRAIT_NOT_SATISFIED`, `monomorphize.zig:585`) all run as-is against the now-present
   `T`. Backends are untouched (they never see type args — `dropComptimeParams`).

### Edge cases to cover
- Multiple type params, each inferred from its own value param (`pair(x, y)` → T from x,
  U from y); some explicit and some inferred is **out of scope** (all-or-nothing per call
  keeps resolution unambiguous).
- `T` behind nested generics (`Box<T>`): recursive structural unification, not just a name
  grab.
- Conflicting deductions (`T` from two args that disagree): `E_TYPE_ARG_CONFLICT`.
- Bound failure on the inferred `T` reports on the call line (the existing keystone).

## Acceptance
- `sum_two(&s1, &s2)`, `make_pair(sq1, sq2)` infer `T` and behave identically to the
  explicit form on both backends (diff-backend parity).
- `make_pair(20, 22)` still requires an explicit `T` (or an annotated binding) — a clear
  `E_TYPE_ARG_REQUIRED`, never a silent guess.
- No existing explicit-type-arg call changes behaviour.

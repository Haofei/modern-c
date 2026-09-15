# Typed semantic facts and typed MIR

This is the short description of how semantic information reaches the backends
today, and the one rule that keeps it from regressing.

It replaces a 1967-line document that had grown into a migration ledger:
per-family status tables, phase narratives, and exact string anchors that a
family of Python "inventory" gates then counted. Those gates are deleted. What
survives is the data flow and the import rule, both checked by
`src/architecture_boundary_tests.zig` (`zig build architecture-boundary-test`).

## Current data flow

```text
source ──► parser ──► AST
                       │
                       ▼
                    sema.zig                 resolves names, types, effects,
                       │    │                ownership, and safety policy
                       │    └──► sema_types.Resolved   interned resolved types,
                       │              │                keyed by expression
                       ▼              │
             CheckedProgram (syntax-free)    callable/global/signature facts
                       │              │
                       ▼              ▼
                   MIR builder               blocks, instructions, typed facts
                       │
                       ▼
                  MIR verifier               admission checks for lowering
                       │
                       ▼
                 VerifiedProgram
                    │       │
              lower_c    lower_llvm          mechanical emission
```

`src/compiler_session.zig` owns the session (files, diagnostics, parsing,
checking, MIR construction). `src/artifact_publisher.zig` owns output.
`src/main.zig` is only the CLI composition root.

## What is actually typed today, and what is not

Typed:

- MIR carries a typed id family in `src/mir_model.zig` (`SourceId`, `NodeId`,
  `SymbolId`, `TypeId`, `ValueId`, `BlockId`, `SpanId`).
- `Function.executable_body` (`ExecutableBody`) is the id-based body form the
  backends consume; `mir_executable_c.zig` / `mir_executable_llvm.zig` read it.
- `CheckedProgram` is a syntax-free table of callable, global, and signature
  facts. It is deliberately not a second expression IR.

Not yet typed — the honest list:

- **MIR carries two body representations.** `Function.blocks[].instructions`
  is a `kind` enum plus a `detail: []const u8` string, alongside the typed
  `executable_body`. The verifier still string-compares `instruction.detail`.
- **`ValueType` is stringly typed** (`integer: []const u8`, `struct_: []const u8`)
  and mirrored by parallel `TypeId` / `SignatureTypeId` fields; `Instruction`
  carries both `result_ty: ValueType` and `typed_result_ty: TypeId`.
- **Facts are joined by `SpanId`** across 31 `*Fact` tables rather than hanging
  off typed nodes.

## The sema-to-MIR handoff

Sema used to answer every type question with an `ast.TypeExpr` — syntax — and
the MIR builder re-derived the same answers from the AST. One judgement, two
implementations, free to drift.

`src/sema_types.zig` is the replacement: a structurally interned
`ResolvedType` table (an integer is a signedness plus a width, not the string
`"u32"`), plus an expression → `TypeId` side table the checker fills during its
walk. `CompilationSession` owns it for a request and hands it to the builder
through `BuildOptions.resolved_types`. Where it answers, it is the authority;
the builder does not infer.

| Expression form | Type authority | Notes |
|---|---|---|
| `int_literal`, `bool_literal`, `void_literal` | sema table | The literal→scalar rule has one implementation, in `sema_types.zig`. |
| identifier (local, param, global) | sema table | Only when the declared type is a builtin scalar or a simple nominal name. |
| comparison / `&&` / `\|\|` / `!` | sema table | Always `bool`; four restatements in `mir_build.zig` were deleted. |
| direct call return | sema table | Bare-identifier callee, no type args, declared function; read at the same fallback position where sema's own chain lands. |
| arithmetic / bitwise binary, unary `-` | builder | Result is an operand's type; sema and the builder consult different fallbacks when neither operand carries one. |
| member, index, slice, deref, cast, `try`, `address_of` | builder | Not modelled by the table yet. |
| intrinsic calls (atomic, MMIO, DMA, reflection, bitcast, conversion, `const_get`, dyn dispatch) | builder | Each has its own rule on both sides; the table must not answer where the chains could diverge. |
| pointer, slice, array, optional, generic, qualified types | builder | `ResolvedType` models scalars and nominal identities only. |

Two limitations worth naming:

- **Nominal types are interned by name, not by symbol id.** Sema has no
  symbol-id table — its scopes and registries are keyed by name — so
  `ResolvedType.nominal` is a dense index into a name table the `Resolved`
  owns. That keeps the spelling out of the type, but it is a stopgap for a real
  `SymbolId`/`DefId`. A type alias is recorded as written rather than resolved
  to its target, because the alias spelling is what reaches the C and LLVM type
  emitters.
- **Expression identity is the source span.** `ast.Expr` carries no node id.
  Giving it one is not cheap: `parser.zig` alone produces expressions at ~69
  anonymous literal sites with no constructor to funnel through, and
  `monomorphize.zig`, `eval.zig`, `sema_move.zig`, `ast_query.zig` and
  `signature_type_materializer.zig` synthesize more. A copied node would also
  duplicate its id exactly as it duplicates its span, so a naive `NodeId` would
  not fix the ambiguity the span key has. Where one span resolves two ways the
  entry stops answering and the builder falls back, so the key fails closed.

The rest is tracked in [`refactoring-plan.md`](refactoring-plan.md).

## The rule

> A backend, or a MIR body/plan module, reads MIR. It does not read syntax.

Concretely, no file matching `lower_c*`, `lower_llvm*`, `backend*`,
`lower_cov.zig`, `mir_executable_*.zig`, or `mir_body_plan*.zig` may
`@import` `ast.zig`, `ast_bridge.zig`, `ast_query.zig`, `attr_syntax.zig`,
`expr_syntax.zig`, `parser.zig`, `sema.zig`, `sema_*.zig`, `type_bridge.zig`,
or `type_syntax.zig`.

`ast_bridge.zig` and `type_bridge.zig` are included because they are
transparent re-exports of `ast.zig` and `type_syntax.zig`; excluding them would
make the rule bypassable by adding another bridge module.

### Enforcement

`src/architecture_boundary_tests.zig` parses the real `@import` edges out of
`src/` and enforces the rule. Every current violation is listed once, by name,
in its `exceptions` table with the reason it is still there. The list must stay
exact: an unlisted violation fails, and so does a stale entry, so the remaining
debt can only shrink and is readable in one place.

As of this writing the exceptions are:

- four unit-test roots (`lower_c_tests.zig`, `lower_llvm_tests.zig`,
  `mir_body_plan_tests.zig`) that parse MC fixture source in-process — test
  drivers, not lowering paths;
- nineteen `ast_bridge` / `type_bridge` edges in the C backend, where emission
  still receives AST-shaped declarations (globals, aggregates, inline asm,
  MMIO) and AST-shaped type expressions for naming and shape decisions.

The LLVM backend has no non-test exception.

Run it with `zig build architecture-boundary-test`; it is also part of
`zig build test`, `m0`, `fast`, and `c0`.

## Why not needle-count gates

The previous approach pinned exact occurrence counts of source strings in
JSON/Markdown ledgers (`docs/codegen-ingress-migration.json`,
`docs/review-goal-status.json`, and about a dozen `*-inventory.py` scripts).
That had three problems: the counts broke on unrelated edits, they proved
nothing about the module graph, and keeping them green became its own workload
larger than the invariant they approximated. One structural check over real
import edges replaces all of them.

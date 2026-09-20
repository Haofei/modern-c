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
- **Instruction-scoped facts are not yet fields on the typed node.** They key
  on the instruction's identity now rather than on a source span -- integer,
  float, bounds, representation, target-type, call-target, `const_get`, bind
  thunk, range and element/range-slice access facts all carry a
  `typed_inst_id` -- but they are still side tables the verifier joins, not
  data hanging off `ExecutableBody`. Resolved accesses also key on an
  `AccessId`; pointer provenance keys on the place it describes.
- **There is no join from a legacy instruction to the typed body.**
  `Instruction.typed_inst_id` and `ExecutableStatement.id` are both `InstId`
  but come from two independent counters, and `ExecutableExpression` has no
  `InstId` at all. The remaining `Instruction.detail` readers are listed in
  [`todo.md`](todo.md); the ones that are still blocked are blocked on this.

## The sema-to-MIR handoff

Sema used to answer every type question with an `ast.TypeExpr` — syntax — and
the MIR builder re-derived the same answers from the AST. One judgement, two
implementations, free to drift.

`src/sema_types.zig` is the replacement: a structurally interned
`ResolvedType` table (an integer is a signedness plus a width, not the string
`"u32"`; a pointer is a kind, a mutability, a nullability and a child type id;
a signature is an interned run of parameter ids and a return id), plus an
expression → `TypeId` side table the checker fills during its walk.
`CompilationSession` owns it for a request and hands it to the builder through
`BuildOptions.resolved_types`. Where it answers, it is the authority; the
builder's own derivation is a debug cross-check (`FunctionBuilder.fromTable`
asserts `Resolved.agreesWithSyntax`) and the fallback for MIR built without a
preceding check.

`Resolved.toTypeExpr` is the one place syntax is produced from a resolved
type. It serves the consumers that still take `ast.TypeExpr` — today the
builder's type-expression plumbing; the signature materializer and the
emitter boundary are the next in line — and is a rendering of the fact, not a
second source of it.

| Expression form | Type authority | Notes |
|---|---|---|
| `int_literal`, `bool_literal`, `void_literal` | sema table | The literal→scalar rule has one implementation, in `sema_types.zig`. |
| identifier (local, param, global) | sema table | The declared type, whatever its shape, as long as the table models it (see below). |
| comparison / `&&` / `\|\|` / `!` | sema table | Always `bool`; four restatements in `mir_build.zig` were deleted. |
| direct call return | sema table | Bare-identifier callee, no type args, declared function; keyed on the call expression's span and read at the same fallback position where sema's own chain lands. |
| member, index, slice, deref, cast, `try`, grouped, `move` | sema table | Sema's `exprResultType` rule, recorded at the expression's own span. |
| arithmetic / bitwise / shift binary, unary `-` | sema table | An operand's type: the left operand's for a shift, otherwise the first operand that carries one. When neither does, nothing is recorded and the builder does not fall back to the assignment target or the literal default either: the expression is literal-class and its context decides downstream. Sema's rule wins because it produces the diagnostics users see. |
| unary `~` | builder | Sema has no rule for it. |
| `address_of`, `borrow` | builder | Sema computes no type for these; the builder's bounded place-and-mutability rule is the only one. |
| intrinsic calls (atomic, MMIO, DMA, reflection, bitcast, conversion, `const_get`, dyn dispatch) | builder | Each has its own rule on both sides; the table must not answer where the chains could diverge. |
| `.len` on a slice or array, struct-literal / array-literal / enum-literal results | builder | Sema types these from context rather than from the expression. |

What `ResolvedType` models: `void`, `bool`, the integers, `f32`/`f64`, the
builtin names (`never`, `Order`, `cstr`, `PAddr`, `VAddr`, `DmaAddr`,
`c_void`, `va_list`), nominal declarations by `DefId`, single and raw-many
pointers (nullability on the pointer), slices, arrays with an evaluated length,
`?T` value optionals, `Result<T, E>`, `fn`/`closure` signatures, generics over
a declaration or a builtin generic (`atomic`, `sat`, `wrap`, `Secret`, …),
`const`/`mut` qualifiers, and `*dyn Trait`. Not modelled, so not recorded: a
generic type parameter inside a template, an array whose length does not fold,
a generic with a non-type argument (`DmaBuf<T, .noncoherent>`), and a
`Type.member` path.

Two limitations worth naming:

- **Nominal types are declarations; a type alias is recorded as written, with
  its target beside it.** `src/sema_symbols.zig` gives every declaration — function, global,
  struct, enum, tagged union, overlay union, packed bits, alias, trait,
  parameter, local — a `DefId` at the start of checking, and
  `ResolvedType.nominal` is that id. Top-level ids are numbered by the same
  per-file-ordinal rule `compiler_session.prepareResolvedProgram` uses, so
  sema's identities and the session's are one space rather than two; body
  locals take ids from the reserved local half of the ordinal range
  (`semantic_ids.local_ordinal_base`). Sema's registries stay name-keyed for
  the shape questions they answer, and name lookup is a thin layer over the id
  table (`Table.typeDef` / `Table.valueDef`, first-wins, exactly as the
  registries always resolved a name). An alias is recorded as
  `ResolvedType.nominal` with kind `.alias` — the alias declaration, not its
  target — because the alias spelling is what reaches the C and LLVM type
  emitters today. Its resolved target is kept in `Resolved.alias_targets`
  (`aliasTarget(def_id)`), so the pass that collapses aliases can flip the
  recording without re-resolving anything. Until then `?Alias` over a pointer
  alias is an `optional` of the alias, not a nullable pointer.
- **Expression identity is the source span.** `ast.Expr` carries no node id.
  Giving it one is not cheap: `parser.zig` alone produces expressions at ~69
  anonymous literal sites with no constructor to funnel through, and
  `monomorphize.zig`, `eval.zig`, `sema_move.zig`, `ast_query.zig` and
  `signature_type_materializer.zig` synthesize more. A copied node would also
  duplicate its id exactly as it duplicates its span, so a naive `NodeId` would
  not fix the ambiguity the span key has. Where one span resolves two ways the
  entry stops answering and the builder falls back, so the key fails closed.

The rest is tracked in [`todo.md`](todo.md).

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
- thirteen `ast_bridge` / `type_bridge` edges in the C backend, where emission
  still receives AST-shaped declarations (globals, aggregates, inline asm) and
  AST-shaped type expressions for naming and shape decisions.

The declaration collector (`lower_c_defs.zig`) and the MMIO declaration
renderer (`lower_c_mmio_defs.zig`) are off that list: both now render from the
`EnumFact` / `TaggedUnionFact` / `StructFact` rows and the `SignatureTypeId`s
inside them. `lower_c_type.appendSignatureType` is `appendType` over the
interned signature graph, and is the renderer those declarations use.

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

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
  `executable_body`. The verifier still string-compares `instruction.detail`,
  but only in two places now: the eleven fact families' fallback walks for a
  body the typed form does not represent, and `instructionTypedIdentitiesValid`,
  which verifies the stream itself. The third group, the finding channel, is
  gone -- see below.
- **`ValueType` is stringly typed** (`integer: []const u8`, `struct_: []const u8`)
  and mirrored by parallel `TypeId` / `SignatureTypeId` fields; `Instruction`
  carries both `result_ty: ValueType` and `typed_result_ty: TypeId`.
  Pointer spelling has one rule, `mir_model.pointerSpelling`: a
  `PointerShape.child` and the pointee type's own `ValueType.name()` are the
  same text, and `mir_syntax`'s type text renders through it. It is still a
  presentation name, not an identity -- a pointee it cannot name (anything but
  `u8`, `u16`, `u32`, `c_void`) falls back to the bare `*mut`, so two pointer
  types can share one name. Structural identity remains `TypeId`, and a
  completeness check that compares element or pointee types by `name()` is
  still approximating one.
- **Instruction-scoped facts are side tables, and every one of the eleven
  families now names a typed obligation in `ExecutableBody`.** They key on an
  identity rather than on a source span -- integer, float, bounds,
  representation, target-type, call-target, `const_get`, bind thunk, range and
  element/range-slice access facts all carry a `typed_inst_id`, and a resolved
  access carries its own `AccessId`, which is what its obligation names.
  Pointer provenance keys on the place it describes. The handoff, family by
  family:

  | Family | Typed obligation it names | Verifier reads |
  |---|---|---|
  | bounds | `index.bounds_obligation`, `range_slice.bounds_obligation`, and the same field on an `index` place projection | the typed body |
  | integer literal | `ExecutableExpression.literal_conversion` (identity plus the target type) | the typed body |
  | float literal | `ExecutableExpression.literal_conversion`, shared with the integer family | the typed body |
  | target-type | a row of `ExecutableBody.target_type_obligations`, naming the node that owns it | the typed body |
  | call-target | `ExecutableExpression.call_target_obligation`, or `ExecutableTerminator.call_target_obligation` for a diverging explicit trap (identity plus the `CallTargetKind`) | the typed body |
  | representation | a row of `ExecutableBody.representation_obligations`, naming the node that owns it | the typed body |
  | range | `ExecutableExpression.range_obligation` (region, span, result type and the typed operation) | the typed body |
  | const_get | `ExecutableExpression.const_get_obligation`; the index is the node's own `builtin_call.const_index` | the typed body |
  | bind thunk | its target-type and call-target halves, plus `ExecutableLocalIdentity.value_id` for the closure local | the typed body |
  | resolved access (element, range slice) | `ExecutableAccessObligation` on the `index` / `range_slice` node or the `index` place projection, named by the fact's own `AccessId` (identity plus the resolved result type) | the typed body |

  Every one of these falls back to the stream for a body the typed form does
  not represent -- an incomplete body, an `extern` declaration, a global
  initializer's pseudo-callable -- which is what
  `mir_verify.typedObligationsRepresented` decides. The `address_of` and
  `deref` arms of the access family never joined the stream at all: they are
  checked on their spans and their operand type class, and a deref has no
  typed expression to move to because the typed body models it as a place
  projection. `todo.md` records the measurement.
- **The legacy instruction stream and the typed body are joined, but the
  stream is still there.** See [the join](#the-join-between-the-two-bodies)
  below. The remaining `Instruction.detail` readers, every remaining consumer
  of the stream, and the measurement that says why it cannot be deleted yet
  are listed in [`todo.md`](todo.md). In short: 28% of functions have no typed
  body for their obligations to live on, and five consumers are genuine --
  the representation-dominance dataflow behind `E_REPRESENTATION_CHECK_MISSING`,
  the `#[irq_context]` call walk, the contract-region pairing behind
  `E_UNCHECKED_OUTSIDE_CONTRACT`, the cleanup CFG's `(block, instruction index)`
  action identity that both backends consume, and `lower_c_map`'s source-map
  provenance and MIR digest.

## Refusals are values, not instructions

A refusal the MIR builder records is a `mir.Function.findings` row: a `SpanId`
and a `FindingKind`, a tagged union with one arm per family. It used to be an
`ffi_check` / `usage_check` / `switch_check` / `result_check` /
`operator_check` / `conversion_check` / `assignment_check` /
`arithmetic_domain_check` / `nullability_conversion` / `aggregate_check` /
`unsafe_check` / `mmio_check` / `address_deref` / `address_conversion` /
`address_operation` instruction whose `detail` string named the finding, which
`mir_verify.zig` then classified back into a diagnostic through ten
string-comparison chains.

The list is on `Function`, not on `ExecutableBody`, and that is the whole
design decision. A finding is not an obligation the typed body carries; it says
the function must not lower at all, and a refused body is routinely
*incomplete*, so there is frequently no typed node to hang it on. The list has
to outlive the instruction stream, and `ExecutableBody` would not.

`mir_verify_util.zig` maps each finding to its diagnostic with a total switch
over the family's enum. That is what makes "this finding has no diagnostic"
(exactly one: `try_handled`) different from "this spelling has no mapping",
which the `eql` chains could not express -- each of them ended in a `return`
that served as both. `todo.md` records what that separation caught.

Every producer that used to answer with a spelling -- `conversionFinding`,
`nullabilityFinding`, `integerLiteralRangeFinding`,
`checkedIntegerBinaryFinding`, `floatBinaryFinding`,
`domainConversionCallFinding`, `typedResourceCallFinding`,
`atomicOrderingFinding`, `mmioOrderingFinding`, `dmaCacheModeFinding` --
returns the enum, so a finding is never text between the decision and the
diagnostic. Two arms carry a name rather than an enum on purpose:
`address_operation` and `unsafe_required` have one diagnostic each, and what
they carry is an operator or callee spelling -- a value name, like an
instruction's value id, not a classification.

## The join between the two bodies

MIR carries two bodies for the same function, so anything that holds a legacy
`Instruction` and needs the typed answer -- or holds a typed node and needs to
know what it replaced -- needs a way to cross between them. That way is an
identity, not a span and not a string:

```text
Instruction.typed_inst_id  ──┐
                             ├──►  the one node that realizes it
ExecutableStatement.inst_id ─┘     (ExecutableStatement or ExecutableExpression)
ExecutableExpression.inst_id
```

`ExecutableStatement.id` is that statement's index in
`ExecutableBody.statements` -- it is what `ExecutableExpression.owner_statement`
points at -- and `ExprId` is an index into `ExecutableBody.expressions`. Neither
is an instruction identity, and numbering them from the instruction counter
would break every use of them as an array position. So the join is a separate
field on the typed node, `inst_id`, holding the `InstId` of the instruction
that node replaces.

The builder records it where it emits both forms of the same source statement.
The direction that matters is *instruction to node*: the instruction is the
thing being replaced, and the question a consumer asks is "what realizes this
instruction?". `mir_model.executableNodeForInstruction` (and its statement- and
expression-typed variants) is that lookup.

`mir_verify.validateExecutableBodyJoinForLowering` makes it an identity rather
than a hint. It proves three things before any backend may consume a module:

1. a recorded `inst_id` names an instruction that exists in that function, so
   following the join cannot land on nothing;
2. no two typed nodes name the same instruction, so "the node that realizes
   this instruction" is single-valued;
3. in a complete body, every instruction that `instructionJoinsExecutableBody`
   declares joinable is named by exactly one node -- the join is total on its
   declared domain.

That domain is the statement-shaped instruction kinds: `local`, `assign`,
`assert_condition`, `defer_cleanup`, `control_transfer`, `return_value`,
`asm_effect`. It is a predicate over instruction *kind* alone, because a
predicate that read `Instruction.detail` would be the string classification the
typed body exists to replace. Expression-shaped kinds are outside it: one
source expression becomes a run of instructions (a load, a representation
check, the value itself) against a tree of typed expressions, so "exactly one"
is the wrong shape for them -- they may still carry `inst_id`, and (1) and (2)
still hold for them, they are just not required to be present. `binary` is the
one statement-shaped kind left out: it heads `if let`, `switch`, `while` and
`for`, and the first three are realized by a `guard` statement and are joined,
but a `for` loop is realized by a `for_each` *terminator*, which is not a
statement and so has no node to name.

Two function shapes are exempt from (3): an `extern` declaration, which has no
body, and a global initializer's pseudo-callable, which is an expression
compiled with a function body's checks rather than a statement sequence.
`CheckedProgram` is where that distinction is recorded, so the verifier reads
it from `CheckedCallableFact.kind` rather than guessing from the body's shape.

The instruction-scoped fact families are unchanged by this: they continue
to join on `typed_inst_id` with their own exactly-one invariants. One of them
gained a typed field rather than a new join: `RepresentationFact.use` is a
`RepresentationUseKind`, the typed form of what a `representation_use`
instruction spells in `detail`, exactly as `TargetTypeFact.kind` is for a
`target_type` instruction. The fact is the authority and the instruction's
string is rendered from it; the verifier checks that correspondence, and that
a `representation_use` fact is the only kind that carries a use.

`src/lower_c_map.zig` is the first consumer: it labels every source-map row
from the typed body or a typed fact, and reads no `detail` at all.

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

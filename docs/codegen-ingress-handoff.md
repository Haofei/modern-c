# Codegen ingress handoff

Measured 2026-08-31 on `master`.

## Current state

- The strict corpus is 160/160 canonical for both C and LLVM.
- Specialized MIR plans are fully retired: zero admissions, zero plan
  definitions, and no `mir_statement_plan.zig` exception.
- The broad census admits 1463/1825 C functions and 1505/1879 LLVM functions.
  The remaining 362 C and 374 LLVM bodies use the explicit AST fallback.
- `CheckedProgram` and the per-file module graph goals are complete. The active
  review goal is deletion of `FunctionBodyFallbackArtifact.syntax` and both
  backend fallback branches.

The latest cutover added canonical `for_each` and `for_step` terminators. MIR
owns iterable evaluation, synthetic iterable/index locals, element binding,
loop control, and representation traps. Both renderers mechanically consume the
same verified terminators. The old foreach return/update recognizers, emitters,
tests, census variants, and shared statement-plan module were deleted.

Canonical memory facts now distinguish ordinary aggregate storage from packed
bits and unions. Declared structs, value optionals, and fixed arrays are copied
through recursively verified scalar leaves for mutable-global and guarded
pointer accesses; packed/union values retain one plain storage operation so
their representation is not decomposed incorrectly. This closes eight C and
nine LLVM broad-corpus fallbacks while preserving the prior race-unordered
contract. C fixed-array leaves use the canonical `.elems[index]` layout and the
generated row-replacement fixture compile-checks with `clang -Werror`.

Checked unary/binary trap ownership is resolved after the canonical expression
table is complete. This removes the construction-order dependency between the
source-shaped legacy fact walk and evaluation-ordered `ExprId`s without
weakening the bijective trap projection check. The complete monomorphization
fixture is now 8/8 canonical in both backends; the broad `trap_projection`
reason fell from 60 to 55.

Scalar/enum switch admission now keeps source wildcard arms separate from
representation/bounds trap successors created while evaluating the subject.
Those traps remain explicit executable edges; they no longer consume the
switch default slot. Six broad-corpus entries per backend moved to canonical
emission, leaving 17 C / 19 LLVM `general_switch` bodies in the structural
variant/generated-control-flow tail.

## Next work

Run the broad census and work from the largest producer-owned reason:

```sh
OUTDIR=zig-out/fallback-census-broad JOBS=8 \
  bash tools/toolchain/fallback-census.sh
```

Current leading blockers are `trap_projection`, `unsupported_statement`,
`unsupported_member`, `general_switch`, string and
aggregate construction, `try`, and unsupported calls. Renderer rejection is a
smaller secondary group.

Declared-struct slice element reads with scalar fields are no longer part of
that renderer group. Canonical C and LLVM rebuild the value from unordered
field loads, preserving the prior race-tolerant behavior.

Executable `LocalId` values are declaration-generation identities. Reusing a
name in a later disjoint lexical scope no longer aliases the earlier LLVM
alloca; 16 LLVM-only fallback bodies moved to canonical emission.

Function MIR also owns callable return signatures. LLVM applies that fact to
the declaration, call result, local slot, and aggregate field representation,
which retires the final four bodies that were renderer-ready but rejected by
the integration ingress. The remaining LLVM fallback set has no
`canonical=ready` tail.

Canonical MIR now owns byte-view construction and equality. Both renderers use
the addressed `Place.ty` for object size instead of reconstructing it from a
lossy pointer child spelling; fixed-array byte views therefore preserve their
length and compile in both outputs. The direct byte-view fixture is 3/3
canonical in C and LLVM, and the nine LLVM bodies exposed by this producer
cutover no longer fall back. Later lexical generations with a repeated local
name are also distinct in canonical C output.

The producer no longer carries a one-off slice-store completion recognizer.
The executable-body verifier promotes every valid body without an explicit
incomplete reason; compile-time statements are explicitly classified and stay
outside runtime MIR. Parameter-field addresses now own their representation
trap at construction time and are rendered mechanically by both backends.
Fixed-array indexing is now admitted by typed base identity rather than by its
source consumer shape. The direct-return-only helpers were deleted; parameters,
locals, nested projections, and direct-call array values share one path. The
`arrays_slices.mc` root is 29/29 canonical in both backends. `uninit` is also
modeled as a local storage policy, so C no longer claims it is an ordinary
renderable value and LLVM no longer emits a fake initializer store.

Fixed-array places may now begin at one checked dereference of a typed pointer
parameter. The shared place predicate reports that provenance explicitly, so
the producer, verifier and both renderers preserve both the non-null
representation edge and every bounds edge. Immutable local pointer copies of a
parameter use the same field-address path. Consequently all three address
helpers in `pointer_field_addr.mc` are canonical in both backends; only its
larger aggregate-construction caller still falls back.

Each slice must:

1. add one typed executable-MIR operation or complete an existing one;
2. verify identity, type, effects, traps, and CFG ownership before codegen;
3. make C and LLVM consume the same operation;
4. pass focused tests, both backend shards, and the strict census;
5. delete superseded fallback code in the same change.

Do not add another specialized plan or backend AST recognizer. Missing facts
remain an explicit fallback until canonical MIR owns them.

## Completion condition

P0 completes only when the broad fallback reaches zero and these are deleted:

- `FunctionBodyFallbackArtifact.syntax: ast.Block`;
- `function_body_fallbacks` from codegen artifacts;
- both backend calls to `findLegacyFunctionBody`;
- fallback-only inventory exceptions.

Tests or a high admission percentage alone do not complete the goal.

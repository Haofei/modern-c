# Codegen ingress handoff

Measured 2026-08-30 on `master`.

## Current state

- The strict corpus is 160/160 canonical for both C and LLVM.
- Specialized MIR plans are fully retired: zero admissions, zero plan
  definitions, and no `mir_statement_plan.zig` exception.
- The broad census admits 1440/1827 C functions and 1472/1879 LLVM functions.
  The remaining 387 C and 407 LLVM bodies use the explicit AST fallback.
- `CheckedProgram` and the per-file module graph goals are complete. The active
  review goal is deletion of `FunctionBodyFallbackArtifact.syntax` and both
  backend fallback branches.

The latest cutover added canonical `for_each` and `for_step` terminators. MIR
owns iterable evaluation, synthetic iterable/index locals, element binding,
loop control, and representation traps. Both renderers mechanically consume the
same verified terminators. The old foreach return/update recognizers, emitters,
tests, census variants, and shared statement-plan module were deleted.

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

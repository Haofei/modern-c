# Codegen ingress handoff

Measured 2026-08-30 on `master`.

## Current state

- The strict corpus is 160/160 canonical for both C and LLVM.
- Specialized MIR plans are fully retired: zero admissions, zero plan
  definitions, and no `mir_statement_plan.zig` exception.
- The broad census admits 1414/1809 C functions and 1433/1861 LLVM functions.
  The remaining 395 C and 428 LLVM bodies use the explicit AST fallback.
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

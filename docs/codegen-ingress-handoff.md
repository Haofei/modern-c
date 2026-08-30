# Codegen ingress handoff

Measured 2026-08-30 on `master`.

## Current state

- The strict corpus is 160/160 canonical for both C and LLVM.
- Specialized MIR plans are fully retired: zero admissions, zero plan
  definitions, and no `mir_statement_plan.zig` exception.
- The broad census admits 1335/1777 C functions and 1370/1829 LLVM functions.
  The remaining 442 C and 459 LLVM bodies use the explicit AST fallback.
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

Current leading blockers are `trap_projection`, `producer_invariant`,
`unsupported_statement`, `unsupported_member`, `general_switch`, string and
aggregate construction, `try`, and unsupported calls. Renderer rejection is a
smaller secondary group.

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

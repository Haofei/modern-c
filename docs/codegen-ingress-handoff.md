# Codegen-ingress migration — handoff

Handoff for the three review goals in `docs/review-goal-status.json`. Written
2026-08-19. Baseline commit: **`127e06d7`** (clean tree, both backends build).

## TL;DR

- **P0 `function-body-fallback`** — active, incremental, the only goal advanced.
  C fast-path admission is at **26.9%** (433/1609 functions); the other 73% still
  ingest the transitional AST body. Multi-week to finish (it is re-implementing
  full function-body emission on MIR).
- **P1 `typed-hir-checked-program`** — frozen. Double-write scaffold seeded in
  `mir_model.zig`; legacy string-identity cutover not started.
- **P1 `real-module-graph`** — frozen. `module_graph.zig` / `module_parser.zig`
  exist and `ir_inspection.zig` consumes a `ResolvedSourceDatabase`, but the main
  sema→MIR→codegen pipeline still uses the combined-source text. Cutover undone.

None of the three is complete. Each is a multi-week unit. Do not report otherwise.

## The three goals, precisely

1. **P0**: C (`src/lower_c_emitter.zig`) and LLVM (`src/lower_llvm.zig`) codegen
   must stop ingesting `FunctionBodyFallbackArtifact.syntax: ast.Block`. Every
   function body must lower from verified MIR / typed facts. Today a MIR "fast
   path" (`emitSimpleMirFunction` + the `simpleMir*` recognizers) admits a growing
   fraction; the rest fall back to `legacyFunctionBody` (the AST body). Goal =
   fast path covers everything, AST-body ingress deleted.
2. **P1 typed-HIR**: a canonical Typed HIR / CheckedProgram with typed-id identity
   (SourceId/NodeId/SymbolId/TypeId/ValueId/BlockId/SpanId in `mir_model.zig`),
   replacing string-identity. Scaffold exists; cutover not done.
3. **P1 module-graph**: loader stops textual inclusion / combined source; per-file
   / per-module identity through the whole pipeline. Consumers partly migrated;
   cutover not done.

### Goal dependencies (established, corrected)

See memory `p0-spanid-decoupling-blocked.md` for the full analysis. Key result:
**P0 is NOT coupled to the module-graph source basis** — P0's `simpleMir*`
recognizers correlate MIR entities within one function (= one file), and equality
is invariant under module-graph's uniform per-file line/offset rebasing. The only
real cross-goal dependency is soft: a canonical typed-HIR would collapse the
~158 recognizers, making P0 cheap+finite — but P0 is completable without it, just
more expensively. Prioritize by value + frozen-cutover risk, not by any invented
P0↔module-graph rework urgency.

## P0: what has been done (all on master, all validated)

Method per slice (never skip): a recognizer + a gate case + a render case in
**both** backends, then validate on host:
- `zig build test-shard-lower-c test-shard-lower-llvm` green;
- emitted C/LLVM compile under clang (`/opt/homebrew/opt/llvm/bin/clang`,
  `-Wno-override-module` for `.ll`);
- `mcc emit-map` shows no `generated_c_line=0` for an admitted function
  (source-map fidelity);
- soundness/parity probes for the specific shape.
Then Docker `m0` regenerates emit-snapshots (host skips LLVM/qemu gates).

Families closed (14, both backends): checked arithmetic; bare param past elided
nonnull; scalar deref `return p.*`; plain unsigned binary (add/sub/mul/and/or/xor,
u32/u64); plain unary; pointer-field load; `phys` address constructor; bitwise;
address-typed (PAddr/VAddr) field + deref; pointer comparison `return a==b`;
single nested-call arg `return g(f())` (first structural slice, `db2f7f5f`);
multi-arg with one nested call + pure-leaf args `return g2(f(), b)` (`127e06d7`);
single-local call chains `let x = f(); return g(x)` (current batch).

Tooling: `src/fallback_census.zig` + `tools/toolchain/fallback-census.{sh,py}` —
armed by `MC_FALLBACK_CENSUS=<path>`, hooks the real admission branch in each
backend's `emitFunctionDefinitions`, dumps JSONL, ranks remaining fallbacks.
Worklist: `docs/codegen-ingress-p0-worklist.md` (has the current census snapshot).

### THREE real miscompiles were caught by the discipline (learn from these)

1. **optional-deref dropped the tag**: an early `return p.*` recognizer admitted
   `?u32` derefs as a single load, dropping the optional tag. Fix: gate on
   declared-return-type == `ret.result_ty.name()`.
2. **LLVM pointer `icmp` render break**: admitting pointer compares reached an
   `integerBitsOf(ptr)==null → error` path. Fix: add pointer `icmp eq/ne`.
3. **`return 0` dropped a reassignment**: a too-broad prefix-call skip admitted
   `var v=0; v=combine(...); return v` as `return 0`. Fix: gate the skip to the
   return call's own callee + `!simpleMirEntryBlockFoldsLocal`.

All three were caught by unit/regression tests (esp. the eval-order test below)
BEFORE commit. **Never ship a codegen slice without these probes.**

## Next work

The first local-declaration statement primitive is complete for the strict
single-local call chain `let x = f(); return g(x)`. It preserves two evaluations
and source order, uses the local's typed `ValueId`, and does not fold `f()` into
the return expression. The broad C census gained four admitted functions.

Remaining buckets are all large or medium-with-risk:

- Builtin/void bodies (`store_release`, atomics, `bitcast`): statement-level
  builtin lowering (addressable temps + `__builtin_memcpy`). Large.
- Compare/binary with checked-arith or atomic-load operands (`(a%align)==0`,
  `load(p)!=x`): widen `SimpleMirCompareBinary` operands from `SimpleMirArg`
  (leaf) to carry sub-expressions. Medium, with eval-order + trap-counting risk.
- Switch/branch/loop 5+ block families: control-flow. Large.

The clean recognizer-only wins are exhausted; everything left is structural.

## Validation quick-reference

```
# fast iteration (host)
zig build                                   # build mcc-real
zig build test-shard-lower-c test-shard-lower-llvm   # ~2min each; run separately if timing out
zig-out/bin/mcc-real emit-c  file.mc -o out.c
zig-out/bin/mcc-real emit-llvm file.mc -o out.ll
clang -std=c11 -c out.c -o /dev/null
clang -Wno-override-module -c out.ll -o /dev/null
MC_FALLBACK_CENSUS=/tmp/c.jsonl zig-out/bin/mcc-real emit-c file.mc -o /dev/null   # per-fn admitted/fallback
zig-out/bin/mcc-real lower-mir file.mc      # dump MIR to understand a shape
bash tools/toolchain/fallback-census.sh     # full-corpus ranked census (slow, ~330 invocations)
```

The **eval-order regression test** `lower-c sequences return call arguments left
to right` (in `src/lower_c_tests.zig`) is the single most important guard for any
call-inlining change — C does not specify argument evaluation order, so
side-effecting sub-calls must be sequenced through temps unless there is only one.

Full validation (emit-snapshots, kernel, LLVM-trap, qemu) needs Docker `m0`; the
host skips those. See memory `use-docker-for-dev` and `m0-parallel-runner`.

## Working conventions (from repo memory — keep these)

- Commit directly on `master`; never create branches.
- End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Never fabricate completion or ship unvalidated codegen. Every slice: both
  shards + clang + source-map + the shape's soundness/parity probe, then Docker m0.

## Pointers

- Goals + status: `docs/review-goal-status.json`
- P0 worklist + census snapshot: `docs/codegen-ingress-p0-worklist.md`
- Deep P0 notes, the fold-vs-emit crux, the three miscompiles, the corrected
  goal-dependency analysis: memory `p0-spanid-decoupling-blocked.md`
- Overall production-readiness review + roadmap: memory
  `compiler-production-readiness.md`
- Backends share verified MIR + a Backend interface: memory `backend-abstraction`

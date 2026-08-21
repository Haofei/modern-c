# Codegen-ingress migration — handoff

Handoff for the three review goals in `docs/review-goal-status.json`. Updated
2026-08-21 after the typed indirect-call return slice.

## TL;DR

- **P0 `function-body-fallback`** — active, incremental, the only goal advanced.
  The current strict ratchet corpus admits **75/160 C** and **76/160 LLVM**
  functions. The last completed broad snapshot before this slice was C
  439/1611; broad report mode is intentionally best-effort and is not a gate.
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

Families closed (16, both backends): checked arithmetic; bare param past elided
nonnull; scalar deref `return p.*`; plain unsigned binary (add/sub/mul/and/or/xor,
u32/u64); plain unary; pointer-field load; `phys` address constructor; bitwise;
address-typed (PAddr/VAddr) field + deref; pointer comparison `return a==b`;
single nested-call arg `return g(f())` (first structural slice, `db2f7f5f`);
multi-arg with one nested call + pure-leaf args `return g2(f(), b)` (`127e06d7`);
single-local call chains `let x = f(); return g(x)`; C additionally accepts a
nested initializer call such as `let x = f(g(a), b); return h(x)` without
folding away the local statement. LLVM deliberately remains fallback for this
last shape until a shared statement/value representation can express it without
adding another backend-only union variant. Leaf-operand typed unary call targets
now share a single descriptor in both backends; conversion, `phys`, alias-safe
`bitcast`, and `enum.raw` returns consume verified call-target and type facts
without an AST body fallback. MIR records the exact operand root as a
`typed_unary_operand` source/type fact; backends no longer infer it by scanning
later instructions. Complex roots without a matching root instruction fail
closed until their complete MIR expression is representable. Leaf-only
`wrapping.add`, `serial.before`, `serial.after`, `serial.distance`, and
`counter.delta_mod` returns now use the same pattern through indexed,
owner-qualified `typed_call_operand` facts. Both backends validate exact domain,
payload, result, and operand types before rendering; call-bearing operands remain
on the full path to preserve evaluation order.

Tooling: `src/fallback_census.zig` + `tools/toolchain/fallback-census.{sh,py}` —
armed by `MC_FALLBACK_CENSUS=<path>`, hooks the real admission branch in each
backend's `emitFunctionDefinitions`, dumps JSONL, ranks remaining fallbacks.
Worklist: `docs/codegen-ingress-p0-worklist.md` (has the current census snapshot).

The first backend-neutral statement slice lives in
`src/mir_statement_plan.zig`. It admits a one-block, no-trap, no-cleanup void
body containing a discarded direct-call result or a zero-argument ordinary
function-pointer call through a parameter/local. The local form keeps
`entry_of()` and `entry()` as two ordered statements. Calls carry a separate
`typed_callee_span_id`, so plan/fact association uses an opaque SpanId without
changing the enclosing expression span used by diagnostics and source maps.
The same module now owns a typed plan for a value-producing function-pointer
call returned immediately. MIR records indexed `indirect_call_argument` facts
plus the canonical callee root and optional field projection; both backends
consume the shared admission result for parameter, global, and global-field
callees. Closures and non-leaf arguments remain fail-closed.

The same module now owns a typed field-place plan. MIR records each member's
base `SpanId` and resolved field index, assignment target/value `SpanId`s, and
the returned value `SpanId`. Both backends lower one-block global field
stores/loads and nested by-value parameter field reads from that single plan,
including `box.pair.left` and `value.pair.right`, without reading a function
body. Pointer traversal and locals remain fail-closed until their storage/value
semantics are represented by the shared plan.

### Six correctness defects were caught by the discipline (learn from these)

1. **optional-deref dropped the tag**: an early `return p.*` recognizer admitted
   `?u32` derefs as a single load, dropping the optional tag. Fix: gate on
   declared-return-type == `ret.result_ty.name()`.
2. **LLVM pointer `icmp` render break**: admitting pointer compares reached an
   `integerBitsOf(ptr)==null → error` path. Fix: add pointer `icmp eq/ne`.
3. **`return 0` dropped a reassignment**: a too-broad prefix-call skip admitted
   `var v=0; v=combine(...); return v` as `return 0`. Fix: gate the skip to the
   return call's own callee + `!simpleMirEntryBlockFoldsLocal`.
4. **unequal-width bitcast over-read**: the C memcpy lowering copied the target
   width from a smaller source object while LLVM rejected the same program.
   Fix: sema now requires equal known fixed-layout widths; fast-path admission
   repeats the width/fact checks and generated C carries a static assertion.
5. **typed-unary operand descendant substitution**: a line/column lookup could
   lower `bitcast<f32>(x & y)` as `bitcast<f32>(x)`. Fix: MIR now records the
   exact operand root and admission requires a matching root instruction and
   complete semantic type.
6. **mixed-width arithmetic domains were accepted**: sema compared only the
   broad `serial` / `counter` class, so `serial<u32>` and `serial<u64>` could be
   passed to the same operation. Fix: compare the exact resolved domain type;
   backend admission repeats the exact-domain check.

All six were caught by unit/regression tests (especially the eval-order test below)
BEFORE commit. **Never ship a codegen slice without these probes.**

## Next work

The first local-declaration statement primitive is complete for the strict
single-local call chain `let x = f(); return g(x)`. It preserves evaluations and
source order, uses the local's typed `ValueId`, and does not fold the initializer
into the return expression. C can also preserve one nested initializer call;
the last completed broad snapshot was C 439/1611 and LLVM 414/1530, while the
current strict corpus is C 75/160 and LLVM 76/160. The exact-root soundness gate
deliberately returned three previously over-broad admissions per backend to
fallback.

Remaining buckets are all large or medium-with-risk:

- Builtin/void bodies (`store_release`, atomics): statement-level builtin
  lowering. Large. Direct-return bitcast and enum-raw no longer belong here.
- Remaining arithmetic-domain calls (bounded/assumption/Result-producing and
  three-operand forms): extend the shared descriptor only after MIR can model
  their result/control effects and all operands explicitly. Medium per semantic
  family; do not widen the leaf-only binary path.
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
- Backends share verified MIR + a Backend interface: memory `backend-abstraction`

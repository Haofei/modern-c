# Codegen-ingress migration — handoff

Handoff for the three review goals in `docs/review-goal-status.json`. Written
2026-08-19. Baseline commit: **`127e06d7`** (clean tree, both backends build).

## TL;DR

- **P0 `function-body-fallback`** — active, incremental, the only goal advanced.
  C fast-path admission is at **26.7%** (429/1609 functions); the other 73% still
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

Families closed (13, both backends): checked arithmetic; bare param past elided
nonnull; scalar deref `return p.*`; plain unsigned binary (add/sub/mul/and/or/xor,
u32/u64); plain unary; pointer-field load; `phys` address constructor; bitwise;
address-typed (PAddr/VAddr) field + deref; pointer comparison `return a==b`;
single nested-call arg `return g(f())` (first structural slice, `db2f7f5f`);
multi-arg with one nested call + pure-leaf args `return g2(f(), b)` (`127e06d7`).

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

## THE NEXT TASK (fully diagnosed, ready to resume)

Biggest remaining bucket (census: **205 fns, 17% of fallbacks**, plus the 138+82
related): `return <ident>` local-computed / multi-statement returns, e.g.

```
fn le1() -> u32 { let x = f(); return g(x); }
fn round_up_to_page(addr: usize) -> usize {
    let aligned: PAddr = pa_align_up(pa(addr), 4096);
    return pa_value(aligned);
}
```

These need a **local-declaration emission primitive**: emit `<ctype> x = <init>;`
as a real C/LLVM statement (fidelity-preserving), then `return <expr using x>;`,
with references to `x` rendered **by name** (not folded to its init — folding
drops the `let`'s source map, which is why the fold path is gated out by
`simpleMirEntryBlockFoldsLocal`, and naively folding would double-call `f()`).

### Design that was in progress (reverted; rebuild from here)

A self-contained recognizer + emission branch, NOT touching the ~15 call sites of
`simpleMirEntryBlockFoldsLocal`:

1. `CEmitter.emitted_local: ?[]const u8 = null` field. While building the return,
   set it to the local name; references to it in `simpleMirArgAt` /
   `simpleMirCallArgAt` (add a guard **before** the existing local-fold at
   `simpleMirArgAt`'s `simpleMirLocalValueArg` call, ~line 5474) return
   `.param = name` so they render as the identifier.
2. Recognizer `simpleMirLocalDeclCallReturn(function, fn_mir)`: require
   `blocks.len == 1`, `trap_edges.len == 0`, exactly one `.local` (name `x`);
   `init_source = simpleMirLocalInitSource(fn_mir, x)`; `init_call =
   simpleMirDirectCallAtSource(init_source)`; **x's C type =
   `cTypeFor(self.functions.get(init_call.callee).?.return_type.?, .typedef_name)`**
   (this is the clean type-resolution answer — locals have no TypeExpr, but the
   init callee's declared return type is x's type); build the return call with
   `self.emitted_local = x` set so `x` renders by name; require the return call
   references `x`; check `trap_edges.len == simpleMirDirectCallReturnTrapCount`.
3. Emission branch: `<ctype> x = <init_call>;` (line directive from the local's
   source) then `return <return_call>;` (line directive from the return source).

### THE BLOCKER that stopped it (this is the crux — read before resuming)

`simpleMirReturn` runs BEFORE any new recognizer and already matches `le1` as the
**folded** `.direct_call = g(f())` (its arg recognizer `simpleMirLocalCallArgAt`
folds `x`→`f()`). That non-null `simple_return` then hits
`simpleMirPrefixVoidCallsBeforeReturn`, which returns null for le1 (f is non-void,
doesn't feed the return, and `folds_local` is true so the nested-arg skip is
gated off), so `emitSimpleMirFunction` **returns false at that point**
(`... orelse return false`, ~line 1611) and never reaches the new recognizer.

**Fix**: compute `simple_local_decl_call` EARLY — right after `simple_assert`,
BEFORE `simple_return` — and gate `simple_return` (and its prefix-calls block)
on `simple_local_decl_call == null`. The new recognizer is strict (single local +
call init + call return using the local), so it declines every shape
`simpleMirReturn` should still handle; trying it first is safe. Then add the LLVM
parallel and the same validation (both shards, clang, `emit-map` source-map
check, and confirm no double-call of the init).

### After that, remaining buckets (all large or medium-with-risk)

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

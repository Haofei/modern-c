# Codegen-ingress migration — handoff

Handoff for the three review goals in `docs/review-goal-status.json`. Updated
2026-08-22 after the per-file module cutover and structural body-plan batch.

## TL;DR

- **P0 `function-body-fallback`** — active and incremental.
  The current strict ratchet corpus admits **145/160 C** and **140/160 LLVM**
  functions. The remaining 15 C / 20 LLVM bodies are explicitly listed by the
  census; broad report mode remains best-effort and is not a gate.
- **P1 `minimal-checked-program`** — complete. Callable identity, signature
  representation, ABI and closed effect flags are created from checked
  declarations before body MIR lowering. MIR adopts that table, and
  `VerifiedProgram` independently admits it against the completed MIR. The
  table contains no AST or expression tree; executable bodies remain canonical
  MIR, so this did not add a full Typed HIR.
- **P1 `real-module-graph`** — complete. The loader owns independent source
  buffers, parses and resolves each FileId independently, and the production
  sema→MIR→codegen pipeline consumes `ResolvedProgram`. Combined-source loading,
  offset boundary recovery and the legacy session parse carrier were deleted.

Two of the three goals are complete. Only P0 remains; do not report it complete
until the AST body artifact and fallback branch are deleted.

The current batch replaces another set of backend-local syntax recognizers with
bounded, backend-neutral MIR plans for assertions, nullable control, scalar
expressions/control, nested conditional returns, aggregate sequences, workflow
calls, stack allocation and access operations. Admission is structural and
typed-fact driven: shared plans do not recognize fixture, function, local or
callee spellings. Renamed-equivalent tests enforce that property. The work also
caught an initializer-graph parent-slot overflow and prevented a C slice path
from silently dropping race-safe load/store operations.

## The three goals, precisely

1. **P0**: C (`src/lower_c_emitter.zig`) and LLVM (`src/lower_llvm.zig`) codegen
   must stop ingesting `FunctionBodyFallbackArtifact.syntax: ast.Block`. Every
   function body must lower from verified MIR / typed facts. Today a MIR "fast
   path" (`emitSimpleMirFunction` + the `simpleMir*` recognizers) admits a growing
   fraction; the rest fall back to `legacyFunctionBody` (the AST body). Goal =
   fast path covers everything, AST-body ingress deleted.
2. **P1 minimal CheckedProgram**: a syntax-free table with typed callable/body
   identity, signature representation, ABI and effect summaries. It must not
   duplicate MIR expressions or control flow. The first callable/body table is
   present; remaining syntax-shaped declaration artifacts still need cutover.
3. **P1 module-graph**: complete. Source, diagnostics, visibility, source maps,
   debug metadata and MIR source identity now use per-file identity through the
   production pipeline.

### Goal dependencies (established, corrected)

See memory `p0-spanid-decoupling-blocked.md` for the full analysis. Key result:
**P0 is NOT coupled to the module-graph source basis** — P0's `simpleMir*`
recognizers correlate MIR entities within one function (= one file), and equality
is invariant under module-graph's uniform per-file line/offset rebasing. The only
real cross-goal dependency is soft: shared syntax-free signature, layout and
operation plans can collapse recognizer families without creating a second
expression IR. P0 is completable without the module-graph cutover. Prioritize by
value and deletion of old ingress, not by an invented P0↔module-graph dependency.

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

Families closed (both backends): checked arithmetic; bare param past elided
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
callees. It now also reconstructs checked constant-index global table places
from typed member/index operand edges, so `ops[1](x,y)` and
`boxes[1].combine(x,y)` share the same Bounds edge, signature and argument
facts in both backends. Closures and non-leaf arguments remain fail-closed.

The same module now owns a typed aggregate-place plan. MIR records each member's
base `SpanId` and resolved field index, assignment target/value `SpanId`s, and
the returned value `SpanId`. Both backends lower one-block global field
stores/loads, nested by-value parameter field reads, and local aggregate copies
initialized from a parameter/global from that single plan, including
`box.pair.left`, `value.pair.right`, and `let copy: Box = box`, without reading a
function body. Pointer traversal and literal-initialized locals remain
fail-closed until their storage/value semantics are represented by the shared
plan.

Nullable-pointer promotion is now another shared, identity-driven slice.
`let maybe: ?*T = p; return maybe`, a null-initialized local reassigned from
`p`, and a void direct call accepting `?*T` all validate the exact local/callee
`ValueId`, operand/callee `SpanId`, nullable and non-null type facts, plus the
single `InvalidRepresentation` edge. Since a typed non-null pointer always
satisfies the nullable representation, neither backend emits that trap. The
local forms deliberately retain storage and reassignment instead of folding to
`return p`, preserving source/debug shape without reopening the AST body.

A bounded local-generation plan now covers `var x: T = uninit; x = aggregate;
return x` for fixed arrays and homogeneous integer structs. MIR owns the local
`ValueId`, statement operand edges, literal operand `SpanId`s, and resolved
struct field indices, so source field order is preserved without backend AST
inspection. The verifier rejects duplicate or sentinel field identities.
Heterogeneous struct literals remain fail-closed because the current MIR
builder still records their literal child target type too broadly; the
backends do not guess around that missing fact.

That plan now also covers fixed-array constant-index projections. MIR records
the base and index operand `SpanId`s, a canonical non-negative literal value,
the static array bound, and the matching Bounds trap edge. The verifier rejects
index metadata that disagrees with the canonical literal operand; both backends
independently match the carried bound to the declared array type before
emission. Parameter reads, race-tolerant global reads/stores, and local array
copies initialized from a parameter/global now use the shared plan. Dynamic
indices remain fail-closed.

Nested fixed-array and field/array projections now retain each successive
static bound in MIR. Store values cover parameters, typed non-negative integer
literals, and bounded one-level integer-array literals. Small array literals
carry their immediate operand `SpanId`s; malformed operand identity is rejected
by the verifier, while both backends independently validate the declared array
length and element types. This closes scalar nested writes and row replacement
for global arrays, struct-field arrays, and array-to-struct-to-array places.
Nested aggregate literals and local literal-owned storage remain fallback.

Exhaustive scalar switches with a parameter subject and integer-literal return
arms now use one backend-neutral CFG plan. Each switch-arm marker owns a bounded
set of normalized signed-magnitude or wildcard patterns, so character cases,
negative integer cases, multi-pattern arms, and the default edge no longer have
to be recovered from the AST body. The MIR identity verifier rejects malformed
or partially populated pattern payloads before either backend runs.

### Seven correctness defects were caught by the discipline (learn from these)

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
7. **slice representation was checked as a raw pointer**: MIR's coarse result
   class admitted the projected slice, but the first C emitter draft rendered
   `slice == NULL`. Fix: representation emission reads the exact verified type
   fact and checks `ptr == NULL && len != 0`; a real Clang compile caught the
   invalid aggregate comparison before commit.

All seven were caught by unit/regression or emitted-artifact compilation tests
(especially the eval-order test below) BEFORE commit. **Never ship a codegen
slice without these probes.**

Local aggregate generations now have one shared recursive value/place plan for
pure nested struct/array initialization, one optional local field/constant-index
update, and a projected return. Aggregate children retain MIR operand order and
resolved field indices; every local root joins by `ValueId`. Checked indexes no
longer join their trap evidence through line/column arithmetic: the full index
expression `SpanId` identifies the trap edge and the index-operand `SpanId`
identifies its bounds fact. Calls, dynamic indexes, multiple stores, cleanup,
and effectful leaves remain fail-closed until the plan carries their sequencing.

Direct-call aggregate projections now use a separate shared plan. It evaluates
the call exactly once and walks a bounded MIR-owned field/dynamic-index chain.
Arguments carry indexed `direct_call_argument` identities rooted at the exact
callee `SpanId`; field projections carry resolved indices; checked indexes carry
their exact Bounds edge; and slice projections carry their exact representation
fact. Both backends now admit `make_values(seed)[index]`,
`make_bag(seed).values[index]`, and `make_bag(seed).tail[index]` without reading
the function body. A zero-argument nested call is represented as an explicit
argument operation and staged before the outer call; other nested/effectful
argument shapes remain fail-closed.

The same boundary now covers the three-block fixed-array `for` shape whose body
immediately returns the bound element and whose after block returns an integer
literal. The `.for_element` fact owns the binding `ValueId`; a tagged iterable
root owns either a parameter array or a direct call, while field projections,
element type, body exit, and empty-array exit are validated once in
`mir_statement_plan.zig`. Direct-call arguments also carry either a parameter
identity or an explicitly staged zero-argument call. This removes the AST body
fallback for `first_from_array`, `first_from_array_call`,
`first_from_array_field_call`, and `first_from_seeded_array_call`. Slices,
side-effecting bodies, and general loops remain fail-closed.

## Next work

The first local-declaration statement primitive is complete for the strict
single-local call chain `let x = f(); return g(x)`. It preserves evaluations and
source order, uses the local's typed `ValueId`, and does not fold the initializer
into the return expression. C can also preserve one nested initializer call;
the last completed broad snapshot was C 439/1611 and LLVM 414/1530, while the
current strict corpus is C 122/160 and LLVM 123/160. The exact-root soundness gate
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

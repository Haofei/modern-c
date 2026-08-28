# Codegen-ingress migration — handoff

Handoff for the three review goals in `docs/review-goal-status.json`. Updated
2026-08-28 after expanding canonical executable MIR and reducing the
`simple_return` specialized path.

## TL;DR

- **P0 `function-body-fallback`** — active. The strict ratchet corpus now admits
  **160/160 C** and **160/160 LLVM** functions with zero fallback and zero
  unsupported bodies. The ratchet is locked at 100%. This is a qualification
  checkpoint, not the deletion boundary: the current 522-root broad census
  finds **608/1778 C** and **653/1849 LLVM** distinct functions using the AST
  body (C admits 65.8%, LLVM 64.7%). Report mode intentionally preserves
  partial records from reject/unsupported roots, so these figures are the
  current migration snapshot rather than a like-for-like performance metric.
  P0 therefore remains incomplete until the executable MIR body is general
  enough for that corpus and the artifact/branch is physically deleted.
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

Value-optional comparisons against `null` now lower as an explicit test of the
verified optional representation's `present` field. This repairs an existing C
miscompile where canonical admission produced an illegal aggregate comparison;
LLVM now consumes the same representation fact rather than falling back. Other
optional-to-optional equality remains fail-closed. The broad census is now C
**1170/1778** (1037 canonical / 133 specialized) and LLVM **1196/1849** (1050
canonical / 146 specialized), with 608 and 653 fallbacks respectively. The
focused ratchet is 153 tests per backend.

Nested fixed-array construction now completes its recursive layout fact only
after the child array metadata exists. C reconstructs the already-declared
framed typedef name from that structural shape and LLVM renders the same nested
array layout. `make_for_bag` therefore moves off fallback in both backends;
broad admission is C **1170/1778** (1037 canonical / 133 specialized) and LLVM
**1192/1849** (1046 canonical / 146 specialized). The focused ratchet is 152
tests per backend.

The built-in `IrqOff` witness is now a nominal executable-MIR integer whose
one-byte storage comes from the shared scalar representation table. This moves
`critical_read` off AST fallback and `read_device` off `simple_return` in both
backends without adding a recognizer. Broad admission is now C **1169/1778**
(1036 canonical / 133 specialized) and LLVM **1191/1849** (1045 canonical / 146
specialized); broad `simple_return` use is 31/35. The mapping is intentionally
limited to the actual built-in witness so a user enum named `Error` cannot be
conflated with a library result-error spelling. The focused ratchet is 151
tests per backend.

Qualified enum variant paths now lower directly to canonical numeric literals.
This removes the false runtime member load and representation trap formerly
attached to `Enum.case`, while retaining the verifier proof marker required by
closed-enum uses. In the focused enum raw fixture, fallback drops from three to
two functions per backend; the focused no-fallback ratchet is now 150 tests per
backend. The current broad split is C 1034 canonical / 134 specialized and LLVM
1043 canonical / 147 specialized. Because this fresh broad sweep de-duplicated
to nine fewer functions per backend than the preceding snapshot, its fallback
totals are recorded as a new baseline rather than claimed as a nine-function
migration delta.

The latest slice moves plain scalar MMIO register reads/writes into executable
MIR. The verified operation owns the MMIO parameter, aligned byte offset,
storage identity, ordering and evaluated value. Both renderers are mechanical;
`RegBits`, mapped/computed receivers and unsupported storage stay closed. A
focused census admits 11/17 functions canonically in both backends, with the
remaining six belonging to those deliberately excluded shapes. The slice also
fixed the canonical loop back-edge to re-enter the condition header; previously
an effectful `while` condition could be evaluated once and then skipped on later
iterations. Verifier mutation tests cover illegal MMIO orderings and forged
bases, and the no-fallback ratchet now has 146 C / 146 LLVM focused tests.

Target-typed negative integer literals are now canonical values rather than a
`comptime_int` unary operation plus a spurious checked-negation trap. Suffixed
literals retain their declared storage type, unsuffixed literals adopt the
expected signed integer type, and the minimum signed value remains representable
without a runtime overflow edge. Dynamic unary negation still owns its exact
checked trap. This moved 15 additional broad-corpus functions off fallback in
each backend and added C/LLVM/MIR regressions for suffix, minimum, division and
remainder cases.

Scalar `T.trap_from(value)` conversions now bind their checked integer range
relation and exact `IntegerOverflow` edge to one canonical builtin ExprId.
Unsigned narrowing, signed/unsigned crossings and value-preserving widening
share one verifier model; both renderers evaluate the operand once and consume
that model mechanically. The 64-bit-and-smaller subset is admitted while
128-bit extrema remain fail-closed. This moved three more broad functions off
fallback per backend, including one formerly specialized `simple_return` body.

The remaining scalar conversion family now uses that same canonical integer
relation. `wrap_from` and `from_mod` perform an explicit modular resize,
`sat_from` clamps signed/unsigned crossings without a trap edge, and domain
`from` preserves its verified storage representation. Both renderers consume
the same source/target width and signedness facts. `tests/c_emit/conversions.mc`
is now 8/8 canonical in both backends. The broad census moves two more functions
off AST fallback and three off `simple_return` per backend: C is now
1158/1785 admitted with 1025 canonical / 133 specialized, while LLVM is
1176/1858 with 1020 canonical / 156 specialized.

Fallible `T.try_from(value)` now completes that scalar conversion slice. MIR
owns the `Result<T, ConversionError>` layout together with the same source and
target integer range relation; `ConversionError` has canonical `u8` storage but
retains its nominal result identity for C declarations. C materializes every
operand once before selecting the success/error aggregate, and LLVM constructs
the equivalent `{ i1, T, i8 }` value. `narrow_try` and `widen_try` in the result
library fixture are canonical in both backends. The broad census removes two
more fallbacks per backend: C is **1160/1785** with 1027 canonical / 133
specialized, and LLVM is **1178/1858** with 1022 canonical / 156 specialized.

`serial.compare` now uses the same result-layout boundary rather than the
domain AST emitter. MIR preserves the nominal `Order` and
`AmbiguousSerialOrder` identities while recording their `i8`/`u8` storage,
and both renderers derive ambiguity from the unsigned half-window before
constructing the result. Generalizing built-in scalar result storage also
unblocked several existing Result constructors without adding a recognizer.
The broad snapshot is now C **1167/1787** with 1035 canonical / 132
specialized and LLVM **1180/1858** with 1025 canonical / 155 specialized;
fallback is 620 and 678 respectively.

`counter.elapsed_bounded` now crosses the same syntax-free boundary. MIR owns
the `counter<T>` and `Duration<T>` domain identities plus the canonical
`Result<Duration<T>, AmbiguousCounterInterval>` storage shape. C reconstructs
the nominal Duration helper spelling only from that structural type, and LLVM
uses the same verified `{ i1, T, i8 }` layout. `tests/c_emit/library_results.mc`
is now 4/4 canonical in both backends. The broad census advances to C
**1168/1787** with 1036 canonical / 132 specialized and LLVM **1181/1858**
with 1026 canonical / 155 specialized; fallback falls to 619 and 677. The
focused no-fallback ratchet is now 147 tests per backend.

Member lowering now distinguishes an actual slice `.len` from an ordinary
aggregate field whose spelling happens to be `len`. Previously the canonical
producer assigned every such member the slice `usize` type; this could reject a
valid struct projection or admit it under the wrong type. The fix uses the
base's structural pointer-kind before choosing the slice operation, while
ordinary members continue through their declared field index/type. The broad C
admission total remains **1168/1787** (1034 canonical / 134 specialized), while
LLVM advances to **1190/1858** (1042 canonical / 148 specialized), reducing its
fallback count by nine to 668. The focused ratchet is now 148 tests per backend.

Wrapping-domain unary negation now stays on canonical executable MIR in LLVM
as well as C. LLVM consumes the verified `wrap<T>` type and absence of a trap
edge, then mechanically emits modular subtraction from zero. Broad LLVM
admission remains **1190/1858**, but one function moves from `simple_return` to
canonical (1043 canonical / 147 specialized), so broad `simple_return` use is
now 36. The focused no-fallback ratchet is 149 tests per backend.

Fixed-array identity is now structural over element spelling and known length;
`[4]T` and `[8]T` no longer collide in the `ValueType`/`TypeId` map. Nested
array layouts are producer-owned, large homogeneous arrays use one bounded
element metadata slot plus their logical length, and LLVM rejects an incomplete
nested layout during admission rather than failing during rendering. The broad
census has no remaining canonical-ready ingress mismatch: C is 1167/1787 with
1035 canonical bodies, while LLVM is 1180/1858 with 1025 canonical bodies and
678 AST fallbacks.

The latest batch migrated another 10 C and 13 LLVM broad functions away from
`simple_return`. A trial physical deletion exposed 50 no-fallback shard tests
whose edge-case and mutation behavior has not yet reached canonical MIR, so the
deletion was reverted. This preserves fail-closed behavior and makes the true
retirement boundary explicit instead of declaring success from the smaller
strict corpus. The strict corpus now has 96 canonical and 64 specialized
functions per backend, with 14 specialized plan definitions; broad
`simple_return` use is down to 30 C / 43 LLVM. Canonical executable MIR now
covers Result construction, wrapping/serial/counter operations, enum raw and
open-enum conversions, wide-integer register casts, negative floating literals
and pointer qualification comparisons.

The current batch replaces another set of backend-local syntax recognizers with
bounded, backend-neutral MIR plans for assertions, nullable control, scalar
expressions/control, nested conditional returns, aggregate sequences, workflow
calls, stack allocation and access operations. Admission is structural and
typed-fact driven: shared plans do not recognize fixture, function, local or
callee spellings. Renamed-equivalent tests enforce that property. The work also
caught an initializer-graph parent-slot overflow and prevented a C slice path
from silently dropping race-safe load/store operations.

The latest vertical slices make ordinary binary operands and character literals
canonical before codegen. Unsuffixed integer/character operands now adopt the
binary operation's checked operand type for comparisons and non-trapping
operators as well as checked arithmetic. Character source spelling is parsed
once into an integer magnitude and no longer crosses the executable-MIR
boundary. This admitted 26 additional C functions and 21 LLVM functions in the
broad census without adding a backend-local syntax recognizer.

Resolved by-value struct members are also canonical executable-MIR operations.
MIR owns the base value, dense field index, result type, aggregate layout shape,
and a presentation-only field spelling. C mechanically emits the spelling and
LLVM emits `extractvalue`; neither backend scans a declaration or expression
AST. Nested by-value member chains are admitted. Direct scalar fields of
non-null `*Struct` parameters now lower as canonical `deref + field +
load/store` places: MIR owns the pointee aggregate, field index/type,
representation edge and access ordering; C emits `root->field` and LLVM emits a
checked GEP plus atomic load/store. Pointer-valued fields and nested/temporary
pointer roots remain fail-closed until their additional representation and
lifetime edges are explicit. The shared C identifier policy keeps declarations
and canonical accesses consistent for prelude names such as `offsetof` and
`uint32_t`.

The census now records the exact canonical stopping layer independently from
the final admitted/fallback status. Of the remaining fallbacks, C attributes
614 to an incomplete MIR producer and 15 to renderer support; LLVM attributes
654/30 respectively. No body marked canonical-ready falls through to AST
codegen. The producer bucket is now
classified by its first stable canonical-model gap. The largest C reasons are
trap projection (125), producer invariants (91), unsupported members (85), and
unresolved indexing (48); LLVM records 141/91/85/63 respectively. Direct pointer-member scalar access is
canonical in the targeted census; the remaining `unlowered_member` reason count
is 15 in each backend. This turns
the remaining migration into a ranked producer/renderer/ingress worklist and
prevents work on the wrong layer.

Address-class representation casts are now canonical executable casts rather
than backend special cases. Only 64-bit unsigned integer ↔ address-class
conversions are admitted; narrower/signed and pointer conversions remain
closed. In the targeted `std/addr.mc` census this removed 14
`unsupported_expression` classifications and left only 6 C / 8 LLVM
fallbacks, all in larger control/value-graph families.

Arithmetic-domain identity is now retained structurally in `ValueType` rather than
collapsed to the underlying integer before executable lowering. MIR marks
wrapping and saturating binary semantics explicitly and the verifier rejects a
domain/operation mismatch or a stray trap edge. C uses the existing saturating
and masked-shift helpers; LLVM emits unsigned overflow intrinsics plus `select`
for saturation and masks wrapping shift counts before `shl`/`lshr`. A mutation
test proves that changing a wrapping operation to saturating fails admission.
The focused arithmetic-domain/bitwise/no-trap census moved from 27/30 to 29/30
in both backends.

Explicit scalar `uninit` locals are now represented as storage without an
initializer expression. A following assignment creates the executable value;
the front-end definite-initialization rules still reject reads before that
store. Grouping does not change the representation, while aggregate `uninit`
continues through its existing aggregate plan. Both scalar initialization
fixtures now lower through canonical MIR in C and LLVM.

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

The original backend-neutral straight-line statement slice has been retired.
Discarded direct-call results and zero-argument ordinary function-pointer calls
through a parameter or direct-call-initialized local now use canonical
executable MIR. `ExecutableCallSignature` owns the bounded parameter/return
contract, the verifier checks it, and both mechanical renderers preserve the
ordered `entry_of()` then `entry()` evaluation without source-shape recovery.
The old builder, C/LLVM emitters, selected-path census entry, and shared plan
machinery are deleted. The same module still owns a typed plan for a value-producing function-pointer
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

Scalar `raw.load<T>` and `raw.store<T>` are now canonical for supported scalar
payloads. Their executable-MIR call owns a typed `PAddr`, exact payload/result,
lexical unsafe authority and operand order. C uses its existing volatile helper,
while LLVM emits a volatile access and declines the canonical path when a
sanitizer profile needs legacy instrumentation. Aggregate payloads remain
fail-closed. `fence.release/acquire/full` also carry an explicit typed void
effect and lower mechanically to the existing C barriers or LLVM fence
orderings. `raw.ptr<T>` now owns its typed address operand, unsafe authority,
non-null result check and exact representation trap edge. Both backends consume
that edge mechanically after materializing the pointer. The broad census moved
to C 868/1696 and LLVM 869/1762 admitted, removing 39 and 36 fallbacks across
the machine-effect slices.

The next broad cut introduced a first-class, value-preserving
`representation_check` executable expression. Its typed `ExprId` operand and
exact trap owner replace backend/source-shape inference for a non-null single
pointer, so the same operation covers returns, call arguments, local
initializers and comparisons. Both renderers evaluate once, branch through the
verified trap edge, then reuse the unchanged value. The 522-root census is now
C **896/1696 (52.8%)** and LLVM **889/1762 (50.5%)**, with 800/873 fallbacks;
this slice alone admitted 28 C and 20 LLVM functions and reduced
`trap_projection` by 53/51 records. Further representation predicates belong
as kinds on this operation, not as new AST recognizers.

Implicit pointer return conversions now use first-class executable cast kinds:
`pointer_to_nullable` and `pointer_const_narrow`. They preserve the pointer
representation and consume the value already guarded by
`representation_check`; neither backend invents another trap or source-shaped
conversion rule. A deliberately broad trial of generic return coercion regressed
legacy specialized-plan admission and was discarded. The bounded pointer-only
cutover leaves the strict corpus at 160/160 per backend and moves the 522-root
broad census to C **898/1696 (52.9%)** and LLVM **890/1762 (50.5%)**, with
798/872 fallbacks.

The next bounded operand slice target-types `null` in pointer comparisons with
the other operand's structural pointer identity. C no longer needs its AST
fallback for `p != null`; the LLVM unit path is likewise canonical. The broad
census is now C **900/1696 (53.1%)** and LLVM **890/1762 (50.5%)**, with
796/872 fallbacks.

The raw-many offset slice is canonical for direct values and nested call
arguments. `ExecutableExpression.builtin_call` owns the receiver, coerced
`usize` index, exact raw-many pointer type, evaluation order, and an
`unsafe_authorized` bit verified before codegen. Its computed dereference is now
also canonical: `ExecutablePlace.root.value` points at the already evaluated
offset expression, and the verifier admits only that builtin plus one deref.
Load, address and mutable store use race-unordered access and no non-null
representation edge. C emits the existing race helpers; LLVM reuses the GEP SSA
value. The focused raw-many root is C **25/27** and LLVM **26/27** admitted. The
522-root census is now C **934/1696 (55.1%)** and LLVM **933/1762 (53.0%)**,
with 762/829 fallbacks. Computed raw-many places removed 19 fallbacks from each
backend; the following fixed-arity C-ABI call slice removed the remaining 11
LLVM ingress mismatches. MIR now owns canonical parameter types and the
variadic bit, while a syntax-free per-call ABI plan owns target
`zeroext`/`signext`; variadic calls remain fail-closed on the legacy path.
CheckedProgram now owns an independent copy of the canonical parameter-type
vector, so equal-arity signature drift is rejected before codegen. Domain
integer C-ABI arguments share their child integer extension class, and
aggregate/unknown ABI classes fail closed instead of being mistaken for a valid
no-extension class.
`forget_unchecked` now crosses the same boundary as a typed unsafe builtin: its
operand is evaluated once, no release operation is emitted, and signature
aggregate metadata lets LLVM type linear resource parameters without AST body
fallback. That made 11 more bodies producer-complete per backend and admitted
11 C / 9 LLVM functions.
Non-nullable slices now carry a typed `valid_slice` representation check in
executable MIR. Both renderers evaluate the slice once and reject exactly
`len != 0 && ptr == null`; nullable slices, ordinary/raw pointers, arrays and
enums remain fail-closed. The broad census admitted 4 more functions per
backend and projected 13 previously missing representation edges per backend;
the remaining 9 in that group now expose independent producer invariants.

The complete bounded scalar atomic family now uses executable MIR:
`atomic.init`, load, store, fetch-add and fetch-sub. MIR owns the storage
`PlaceId`, payload `TypeId`, typed ordering and exact pointer representation
edge. Local `atomic<T>` storage is normalized to its payload representation;
global and direct `*atomic<T>` receivers use the same operations. C emits
`__atomic_*` builtins and LLVM emits `load/store atomic` or `atomicrmw`, with
bool stored as `i8`. Ordering source enum expressions no longer cross the
canonical boundary. Aggregate atomic fields, nested pointers and non-scalar
payloads remain fail-closed. The 564-root sweep moved 42 additional C and LLVM
functions into admitted paths while the corpus itself grew by 38 functions;
the noncanonical-enum blocker fell from 43 to 25 per backend.

Non-naked function mechanics no longer block canonical bodies. `weak`,
`section`, `align`, and `noinline` are emitted by one shared wrapper per
backend, while transitional specialized plans remain restricted to plain
functions so they cannot silently discard attributes. This moved the two
ordinary attributed functions in `section_attr.mc` off AST fallback in both
backends. The same census exposed an inaccurate aggregate fact: an overlay/C
union was labelled `declared_struct`. Executable MIR now preserves `c_union`
identity; the verifier admits that metadata but continues to reject union
construction as struct construction. Until canonical union layout exists, the
affected body stays producer-incomplete instead of being falsely reported
ready. The 522-root census after that slice was C **939/1696 (55.4%)** and
LLVM **939/1762 (53.3%)**, with 757/823 fallbacks and zero
ready-but-fallback bodies.

Canonical LLVM now emits ordinary `fadd`, `fsub`, `fmul`, `fdiv`, `fneg` and
all six floating comparisons directly from typed executable MIR. Comparison
predicates preserve the legacy/C NaN contract (`oeq`, `une`, and ordered
relations), and float literals remain bit-exact. In the strict corpus this
moved ten functions from `simple_return` to canonical emission (42→52
canonical, 118→108 specialized). The broad census moved seventeen functions
to canonical emission, including two functions previously on AST fallback.
After that measurement, executable MIR aggregate metadata became transitive:
an outer aggregate now brings along every by-value nested aggregate and enum
layout identity required to render its LLVM GEP type. Registration is bounded
and rolls back the whole recursive addition on an incomplete nested type. This
moved eight more LLVM functions from `simple_return` to canonical emission and
one from AST fallback. LLVM is now **942/1762 (53.5%)**, with 820 fallbacks and
296 specialized bodies. C is unchanged at **939/1696 (55.4%)**, with 757
fallbacks and 268 specialized bodies.

Runtime `assert` now owns one typed statement-level `Assert/assert_stmt` edge
whose source block, trap block and bool condition are verified before codegen.
The C renderer branches to the MIR trap block; LLVM emits the corresponding
guard/continuation CFG. Both evaluate the condition graph once. Short-circuit
conditions remain fallback because eager expression materialization would
change their semantics, and comptime assertions remain outside the runtime
executable body. This slice moved two module-visibility functions per backend
from producer-incomplete to renderer-unsupported; it deliberately did not
change the broad admitted/fallback totals above.

The census now records the exact selected codegen path, separating the general
canonical executable-MIR renderer from transitional specialized MIR plans and
the AST fallback. The first four retired paths (`simple_assert`,
`scalar_local_checked_binary_return`, `slice_length_return`, and `place_store`)
were deleted after proving zero use. `scalar_control` was then
retired after its three inline-only control-flow tests moved to canonical CFG
emission; its standalone plan, tests and both backend renderers were deleted.
Both specialized-plan chains are now ratcheted from 38 definitions to 26.
Complete backend shards remain mandatory retirement evidence because the broad
fixture census still misses inline-only paths.

Canonical body admission now compares executable parameters, return values and
direct callees exclusively against typed MIR `ValueType`/callable facts. The C
and LLVM admission paths no longer compare those facts with `ast.Param` or
`ast.TypeExpr`, and the C path no longer recovers direct-call signatures from
the declaration artifact registry. This moved four broad-corpus C functions
from specialized plans to canonical emission without changing the strict
corpus. Canonical LLVM output uses stable `LocalId` parameter names; affected
tests now assert those identities instead of legacy source-local spellings.

Enum literals now cross the executable-MIR boundary as canonical numeric tags
plus a verified nominal-enum/repr table. Both renderers consume that table;
positive and signed enum cases no longer require source case spelling for a
direct return or direct-call argument. This moved seven functions per backend
to canonical emission (six from `simple_return`, one from AST fallback), and
the direct enum-literal branch was deleted from both copies of the transitional
`simple_return` recognizer. Local enum fold cases remain on the bounded legacy
branch until their representation-check cleanup is explicit in executable MIR.

The 26-plan existence checks are flat boolean registries, replacing the
duplicated negated conjunctions. This does not
pretend the plans are gone, but it makes every later retirement a one-entry
deletion and removes operator-precedence risk from the cutover mechanism.

`simple_conditional_statement_return` is now fully retired. The executable-MIR
producer classifies dead continuations after all-returning arms as unreachable,
and branch-local global loads/stores no longer trip the obsolete straight-line
admission restriction. C and LLVM therefore consume the same explicit CFG and
memory-access facts for conditional calls, stores, aggregate/enum/float returns,
and mixed early exits. The strict census moved two functions per backend from
specialized to canonical emission (C 56/104, LLVM 54/106).

`identity_return` is also fully retired. Function values now remain a resolved
`SymbolId` with `SymbolIdentity.kind=function` in executable MIR. The C
renderer emits that identity directly; LLVM maps the same value to an opaque
function pointer without inventing a global load. Ordinary global symbols still
require an explicit MIR memory-access operation. The strict census moved one
function per backend to canonical emission (C 57/103, LLVM 55/105), and the
standalone plan, backend recognizers and renderer branches were deleted.

The same producer now gives `phys(...)` its canonical `PAddr` result instead of
leaving it `.unknown`. Nested checked integer operands therefore retain their
overflow CFG and cross both mechanical renderers. This closes `pa_offset` and
equivalent direct shapes without adding a backend recognizer.

`logical_return` is fully retired. Executable MIR marks `logical_and` and
`logical_or` eager-safe only when every recursively evaluated operand is a pure
boolean local, literal, or proven logical node. The verifier rejects a missing
or forged proof, while both renderers consume the same fact. The strict census
moved four functions per backend to canonical emission (C 61/99, LLVM 59/101),
and the plan model, builder, census path, and both backend emitters were deleted.

`pointer_to_integer_cast` is fully retired. `ExecutableCastKind` now owns the
pointer-to-integer conversion, while the existing representation-check
expression and `InvalidRepresentation` edge remain explicit. C emits the guard
before its integer cast and LLVM emits the same guard before `ptrtoint`. The
strict census moved one function per backend to canonical emission (C 62/98,
LLVM 60/100); the standalone plan and both backend implementations were deleted.

`nullable_pointer_void_call` is fully retired. Canonical direct-call admission
still requires exact argument types except for one typed, representation-
preserving conversion: a non-C-ABI non-null pointer may widen to its nullable
form. This moves the remaining strict C call to canonical emission and, unlike
the deleted C special plan, preserves the executable-MIR
`InvalidRepresentation` guard before the call. LLVM already used that canonical
path, so the strict split is now C 63/97 and LLVM 60/100 while the shared plan
registry falls to 28.

`nullable_pointer_local_return` is fully retired. Local initialization,
assignment, and return share the same bounded `pointer_to_nullable` executable-
MIR cast, so neither backend reconstructs the promotion from local names or
target-type spans. C canonical local stores now accept pointer values only for
plain local storage; race-unordered global/projection stores remain limited to
the typed scalar helper set. Both renderers preserve the non-null source guard
before the nullable initialization or assignment. The strict split is now C
65/95 and LLVM 62/98, and the shared registry falls to 27.

`assert_expression` is fully retired. MIR now owns one eager-safety proof for
short-circuit boolean trees whose leaves are side-effect-free locals/literals
or ordinary comparisons of those leaves. Calls, loads, representation checks,
and any expression with a trap edge remain excluded. The producer, verifier,
and both renderers consume that same proof; `mir_assert_plan.zig` and both
recursive backend renderers were deleted. The strict split is now C 66/94 and
LLVM 63/97, and the shared registry falls to 26.

`scalar_expression` is fully retired. The producer now contextualizes a
targetless integer literal before classifying an executable coercion. A checked
shift count such as `32` therefore becomes the verified operand type directly,
instead of first failing an impossible runtime `comptime_int -> u64` cast and
leaving a complete expression graph marked incomplete. Both `high_word` and
`flag_set` now use the canonical renderer. The standalone 381-line plan, its
tests, and both backend implementations are deleted. The strict split is C
67/93 and LLVM 64/96, and the shared registry falls to 25.

`access_local_address_update` is fully retired. Executable MIR now proves that
a pointer local has one direct-local address initializer and is never
reassigned; the producer, verifier, and both renderers use that bounded
provenance fact for the guarded dereference store. The source-shaped plan and
both dedicated emitters are deleted. The strict split is now C 68/92 and LLVM
65/95, and the shared registry falls to 24.

`while_control` is fully retired. The source-bearing `break`/`continue`
statement is presentation metadata in executable MIR; the verified basic-block
terminator is the sole control-flow authority. Both mechanical renderers now
ignore that marker and emit the canonical CFG, while the dedicated plan,
admission helpers, and C/LLVM emitters are deleted. The strict split remains C
68/92 and moves to LLVM 67/93, and the shared registry falls to 23.

`simple_trap` is fully retired. A terminal `trap(.Reason)` or `unreachable`
is now normalized to a verified CFG jump into a trap block; the explicit trap
reason is joined to its call-target fact by opaque `SpanId` and projected to an
exact executable `TrapKind`. Both mechanical renderers consume that CFG,
including `never` functions, and the duplicated source-location recognizers
and helper-selection branches are deleted. The strict split remains C 68/92
and LLVM 67/93, while the shared registry falls to 22.

The straight-line `statement` plan is fully retired. The strict ratchet corpus
now reports C 72 canonical / 88 specialized and LLVM 71 canonical / 89
specialized, with 21 remaining specialized plan definitions. The callable
slice is deliberately narrow: only verified zero-argument ordinary function
pointers returning void are canonical here; closures and value-producing
indirect calls remain on their existing qualified paths.

The `simple_enum_switch_return` plan is fully retired. Executable MIR now owns
an enum switch's subject `ExprId`, normalized signed/unsigned case values,
default trap block, and exact arm `BlockId`s. The verifier rejects missing,
duplicate, or dangling dispatch entries, and both mechanical renderers emit
the same table without enum AST declarations or source case names. The old
plan structs, source-shaped recognizer, C/LLVM emitters, admission-chain term,
and census path are deleted rather than left dormant.
The strict corpus contains no enum-switch fixture, so its admission split stays
C 72/88 and LLVM 71/89; the independently counted shared specialized-plan
registry is the convergence signal here and falls from 21 definitions to 20.

The dedicated `nested_conditional_return` plan is fully retired. Complete C
and LLVM shards continue to lower its nested classify fixture through the
canonical executable CFG, so the 317-line recognizer/model, its standalone
tests, both backend-specific support and rendering branches, and its census
path are deleted. Strict admission remains C 72/88 and LLVM 71/89; the shared
specialized-plan registry falls from 20 definitions to 19.

The `scalar_switch_return` plan is fully retired. The canonical executable
switch table now accepts verified integer/domain subjects as well as enums, so
the strict corpus moves three functions per backend to canonical emission (C
75/85, LLVM 74/86). During the cutover, the full C shard exposed an expression-
arm effect hole: MMIO reads in expression-form arms were not present in the
executable statement stream. Switch construction now records those evaluations
before deciding canonical completeness, preserving their barriers and keeping
unsupported effects on the general path. The standalone scalar plan model,
recognizer, both backend renderers, and census path are deleted; the registry
falls from 19 definitions to 18.

The `simple_void_body` plan is now fully retired. Callable parameter signatures
are carried by executable MIR, lexical contract calls and fixed-array bodies are
canonical, and write-only locals no longer fail admission. These changes move
the two production users (`fmt_put_hex32`/`fmt_put_hex64`) to the canonical
renderer. The complete shards also exposed several synthetic aggregate-global
and pointer-projection cases which were never complete executable MIR; those
remain explicit AST fallback instead of retaining a second specialized void-body
implementation. Both plan models, recognizers, renderers, census path, and the
obsolete write-only-local admission heuristic were deleted.
The strict corpus remains fully admitted (C 84 canonical/76 specialized,
LLVM 83 canonical/77 specialized), while the shared specialized-plan registry
falls to 15 definitions.

The `local_aggregate_assignment_return` plan is now fully retired. Executable
MIR records declared nullable/array/struct local storage even when the source
initializer is `uninit`, then owns the aggregate construction, assignment,
reload, and return sequence. The old plan model and builder, both backend
support/rendering branches, its census path, and plan-specific tests are
deleted. More complex aggregate projections continue to use their existing
qualified paths: retaining the legacy MIR initializer span keeps
`aggregate_sequence` and `alloca_hoist` stable while executable MIR treats
`uninit` only as a storage policy. The strict corpus remains fully admitted and
moves two functions per backend to canonical emission (C 86/74, LLVM 85/75);
the shared specialized-plan registry falls to 14 definitions.

The first local-declaration statement primitive is complete for the strict
single-local call chain `let x = f(); return g(x)`. It preserves evaluations and
source order, uses the local's typed `ValueId`, and does not fold the initializer
into the return expression. C can also preserve one nested initializer call;
the last completed broad snapshot was C 439/1611 and LLVM 414/1530. The current
strict corpus remains fully admitted, split into C 67 canonical/93 specialized
and LLVM 64 canonical/96 specialized. The exact-root soundness gate
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
JOBS=4 bash tools/toolchain/fallback-census.sh  # bounded parallel full-corpus census; JOBS=1 is deterministic serial mode
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

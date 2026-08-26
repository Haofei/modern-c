# P0 codegen-ingress worklist (function-body fallback)

Goal (docs/review-goal-status.json `function-body-fallback`): C/LLVM codegen no
longer ingests the AST body (`FunctionBodyFallbackArtifact.syntax: ast.Block`);
every function body lowers from verified MIR. This file is the census-derived,
evidence-backed worklist for that goal — so the remaining work is attacked
head-of-distribution, not by blind shape enumeration.

## Measurement

`tools/toolchain/fallback-census.sh` (recorder: `src/fallback_census.zig`) hooks
the real admission branch in each backend's `emitFunctionDefinitions` and ranks
which function shapes still fall back. The strict ratchet corpus now admits
**100% of C functions (160/160)** and **100% of LLVM functions (160/160)** with
zero fallback and zero unsupported bodies. The checked-in ratchet is locked at
that boundary.

The strict corpus is not the P0 completion definition. The current 2026-08-26
broad sweep over all 522 `tests/**/*.mc` roots de-duplicated to 1696 C and 1762
LLVM functions. It still found 757 C and 820 LLVM AST-body fallbacks. Report
mode preserves partial records from reject/unsupported roots, so these totals
are the current migration snapshot rather than a direct throughput comparison
with older root sets. Those
figures establish that final deletion now requires a
general syntax-free executable MIR body and mechanical backend renderers; more
strict-corpus recognizers are no longer an honest completion strategy.

### Last completed broad census snapshot (2026-08-26)

The 522-root sweep found C **939/1696 admitted (55.4%)**, 757 fallback, and
LLVM **942/1762 admitted (53.5%)**, 820 fallback. There were no unsupported
bodies because the transitional AST ingress is still present, and no
canonical-ready body still fell through to that ingress. The latest slice
adds transitive by-value aggregate/enum metadata with bounded failure rollback,
so LLVM can mechanically render nested aggregate GEP types. It moves eight
broad functions from `simple_return` to canonical MIR and one function off AST
fallback. The preceding float slice adds ordinary arithmetic, negation and
comparisons to the syntax-free LLVM renderer. It preserves bit-exact literals
and the established NaN predicate contract, moves ten strict-corpus functions
and seventeen broad functions from specialized lowering to canonical MIR, and
moves two broad functions off AST fallback. The earlier attribute slice admits
ordinary `section`/`noinline` function definitions through the canonical body while
preserving normalized render mechanics. It also corrects overlay/C union
aggregate identity so LLVM does not mistake union fields for struct layout.
The earlier enum slice makes enum literals canonical numeric tags backed
by a verified nominal/repr table. It moved seven functions per backend to
canonical emission and deleted the direct enum-literal branch from both
transitional `simple_return` recognizers. The machine-effect slice makes scalar `raw.load<T>` /
`raw.store<T>` and all three `fence.*` operations
typed executable-MIR builtins. MIR
owns the exact `PAddr` operand, payload/result type, lexical unsafe authority and
left-to-right operand evaluation. C mechanically selects the existing volatile
runtime helper (preserving sanitizer hooks); LLVM emits volatile load/store and
keeps sanitizer profiles on the instrumented legacy path. Aggregate raw access
remains fail-closed until canonical layout and instrumentation policy cross the
boundary. Fences carry a typed void effect and preserve release/acquire/full
order in both renderers. `raw.ptr<T>` now owns its typed `PAddr` operand,
lexical unsafe authority, non-null pointer result and exact
`InvalidRepresentation` edge. C materializes and guards the result; LLVM emits
`inttoptr` and branches through the same MIR trap block. Together these machine
effect slices admitted 39 additional C functions and 36 LLVM functions.
`raw_many_offset` and `phys(...)` remain canonical as described below.

The latest producer slice adds a value-preserving
`representation_check(ExprId)` operation for non-null single pointers. The
wrapper, rather than a source-shaped local/load recognizer, owns the exact trap
edge and therefore applies uniformly to returns, local initializers, call
arguments and comparison operands. C and LLVM each evaluate the operand once,
guard it, and expose the unchanged value. This admitted a further 28 C and 20
LLVM functions while reducing the broad `trap_projection` producer bucket by
53 C and 51 LLVM records.

The latest bounded cast slice gives implicit non-null-to-nullable pointer
promotion and mutable-to-const pointer narrowing explicit executable-MIR cast
kinds. Both preserve the pointer representation; the non-null wrapper remains
the sole owner of the exact `InvalidRepresentation` edge. Return production is
intentionally limited to those two conversions: a trial that applied generic
coercion to every return reduced legacy-plan admission and was rejected by the
broad census. The bounded version adds 2 C and 1 LLVM admissions without a
strict-corpus regression.

Pointer comparisons now target-type `null` with the other operand's structural
pointer identity. This removes the parser's synthetic `null` shape before
verification, so the generic renderer compares two identical typed pointer
operands. It removes 2 further C fallbacks; the focused LLVM unit path is also
canonical, while the broad LLVM total is unchanged because the surrounding
roots remain unsupported before those records are published.

Computed raw-many dereference places now use an evaluated `ExprId` root in
executable MIR. The verifier admits only a typed `raw_many_offset` result plus
exactly one dereference; arbitrary expression roots, nullable/single pointers
and extra projections remain fail-closed. Load, address and mutable store share
that place identity, preserve left-to-right evaluation, use race-unordered
memory access, and deliberately carry no non-null representation edge. This
removes 19 broad-corpus fallbacks from each backend; the focused
`raw_many_pointer.mc` root is now C 25/27 and LLVM 26/27 admitted.

Fixed-arity direct calls now carry a syntax-free LLVM C-ABI plan derived from
the callee MIR signature. `Function` owns canonical parameter types plus the
variadic bit; admission checks every argument/result against that signature,
keeps variadic default promotions on the legacy path, and normalizes target
`zeroext`/`signext` attributes before the mechanical renderer runs. The MIR
verifier also rejects parameter-count/type drift between the function signature
and executable body. This closes the remaining 11 broad-corpus LLVM
`ingress_mismatch` records without changing C admission.
CheckedProgram now independently stores that parameter-type vector and compares
it with structural `ValueType` equality, closing the equal-arity drift gap before
backend admission.
LLVM also classifies domain integers through their child integer for C ABI
extensions and rejects unsupported aggregate/unknown ABI classes rather than
silently treating them as a valid no-extension scalar.

`forget_unchecked` is now a typed unsafe executable-MIR builtin rather than a
backend-recognized call. MIR owns its one operand and void result, the verifier
requires lexical unsafe authority and zero trap/representation metadata, and
both renderers evaluate the operand exactly once while emitting no release
operation. Signature aggregate shapes are also interned for resource parameters
so LLVM can mechanically type a forgotten linear token. The broad sweep made 11
additional C bodies and 11 LLVM bodies producer-complete; C admitted all 11 and
LLVM admitted 9, with the remaining 2 exposing independent renderer work.

Non-nullable slice representation is now an explicit `.valid_slice` MIR
operation with one exact `InvalidRepresentation` edge. C checks the materialized
slice typedef once; LLVM checks the `{ ptr, i64 }` aggregate once. The predicate
is `len != 0 && ptr == null`, and Bounds remains a separate operation. This
admits 4 more functions per backend and reduces `trap_projection` by 13 in each;
9 of those functions now stop at a later producer invariant instead of a missing
trap edge.

Scalar `atomic.load` now has a dedicated executable-MIR operation for direct
global storage and exactly one pointer indirection. The operation owns its
atomic place, scalar payload identity, typed memory ordering and exact
`InvalidRepresentation` edge. Ordinary load/store/address operations reject
atomic places, and both renderers accept only bool or 8/16/32/64/size integer
payloads. C emits `__atomic_load_n`; LLVM emits `load atomic`, maps relaxed to
`monotonic`, and loads bool storage as `i8`. Local `atomic.init`, aggregate
atomic fields, fetch/store and nested pointers remain on the fallback. The
nested-pointer semantic helper was tightened at the same time so
`**atomic<T>` cannot be mistaken for a direct receiver. This admits 3 additional
functions in each backend.

Runtime assertions now carry a statement-owned, exact `Assert/assert_stmt`
edge into executable MIR. Producer completion and the verifier require one bool
condition in the same statement/block and one typed trap terminator. C branches
to that trap block and LLVM emits an explicit guard/continuation edge, so neither
renderer reconstructs assertion semantics from the AST. Short-circuit and
comptime assertions stay fail-closed. In the broad census this moved two
module-visibility functions per backend to the renderer boundary without yet
changing the admitted totals.

The census also ranks the canonical stopping layer. For C the remaining 757
fallbacks are 707 `producer_incomplete` and 50 `renderer_unsupported`; LLVM is
747/76. The ready-but-fallback bucket is zero in both backends. Producer-incomplete
records also carry a backend-neutral reason emitted beside the canonical body.
The leading C reasons are `producer_invariant` (141),
`trap_projection` (116), `noncanonical_literal` (102),
`unsupported_member` (50), and
`unlowered_index` (46). LLVM has `producer_invariant` 141,
`trap_projection` 129, `noncanonical_literal` 105, `unlowered_index` 60 and
`unsupported_member` 50. By-value struct member
projection, direct pointer-member scalar access, and integer-domain identity are
canonical; the remaining `unlowered_member` bucket is 15 in each backend.
Therefore producer work is the dominant next step and renderer work can be
selected as a small bounded parallel lane. Remaining C fallbacks ranked by
family (LLVM has the same distribution within a few functions):

| n | %fb | family | examples | remaining blocker |
|---|---|---|---|---|
| 102 | 13% | return `<ident>` 1 blk 0 trap | load_acquire, region_holds | remaining local/effectful computations |
| 82 | 11% | return `<ident>` 2 blk 1 trap | slice_of_struct, slice_of_array | remaining slice/enum representation and bounds traps |
| 34 | 4% | fallthrough void 1 blk 0 trap | call_literal, store_release | builtin/atomic void body → statement-level |
| 46 | 5% | switch return `<ident>` 5+ blk | pa_align_down, SlotFuture__poll | general CFG + value graph |
| 41 | 5% | return `<ident>` 3-4 blk 2+ trap | inferred_call_slice_element | same, more control flow |
| 18 | 2% | return binary 2 blk 1 trap | counter_differs, ptr_differs | checked/atomic operands with exact trap edges |
| 36 | 4% | fallthrough void 2 blk 1 trap | array/field address stores | statement/place graph + check edge |
| 22 | 3% | branch return `<ident>` 5+ blk | loops and UB probes | general CFG + loop control |
| 15 | 2% | return binary 1 blk 0 trap | raw_ret, neg_f64 | ordering-sensitive or domain-specific binary |

Every remaining bucket is now either **large** (general local/multi-statement
value graphs, statement-level builtin/void lowering, or CFG rendering) or
**medium-with-risk** (checked/atomic/domain operands with observable evaluation
order and trap counts). The clean recognizer-only wins are exhausted. The next
unit of progress is the shared executable MIR body, not another source-shaped
recognizer.

## The fidelity-safe admission method (established, must be preserved)

The MIR fast path is a **deliberately simplified emission with lower fidelity**
than the AST fallback. Admitting a family must not regress fidelity (policy
choice: *preserve fidelity first*). Two verified fidelity gaps:

1. **Folded `let`.** The fast path folds `let y = a+b; return y` into
   `return a+b`, dropping that construct's source-map / `#line` entry. Gate
   admission on `simpleMirEntryBlockFoldsLocal(fn_mir) == false` — direct-return
   shapes fold nothing and lose no source map; let-folding functions stay on the
   fallback that still emits their per-construct map.
2. **Param debug info.** The fast path omits param `llvm.dbg.value` — already
   accepted policy (the migrated functions lack it), so not a *new* regression,
   but confirm per family.

Validation per slice (all host-runnable): `zig build test-shard-lower-c
test-shard-lower-llvm` green; emitted C/LLVM compile under `clang`
(`/opt/homebrew/opt/llvm/bin`); `mcc emit-map` shows no `generated_c_line=0` for
an admitted function. Then Docker m0 regenerates emit-snapshots.

## Ratchet gate

`zig build fallback-census-ratchet-test` runs
`tools/toolchain/fallback-census.sh --check` over the explicit C/LLVM-positive
`tools/toolchain/fallback-census-roots.txt` corpus. Unlike the broad report mode,
check mode fails on any compile error, timeout, or crash; it does not use `|| true`
to turn a failed root into a successful gate. The checked-in baseline is
`tools/toolchain/fallback-census-baseline.tsv`:

The runner uses four bounded workers by default (`JOBS=1` restores serial
execution). Each compiler invocation has private output, log, status, and
scratch files; the parent concatenates JSONL parts in numeric launch order, so
parallel execution does not change the raw census or ranked report.

| Backend | Total min | Admitted min | Fallback max | Unsupported max | Admission bps min | Canonical min | Specialized max | Plan definitions max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C | 160 | 160 | 0 | 0 | 10000 | 57 | 103 | 31 |
| LLVM | 160 | 160 | 0 | 0 | 10000 | 55 | 105 | 31 |

Each census record also names the exact selected lowering path. New executable
MIR admissions should increase `canonical_min`; transitional specialized
admissions and plan definitions may only decrease. Four specialized plans that
had no broad-corpus hits and were unneeded by either complete backend shard were
retired from both emitters: `simple_assert`,
`scalar_local_checked_binary_return`, `slice_length_return`, and `place_store`.
Their renderer helpers were deleted with the entrances, reducing both plan
chains from 38 to 34 definitions without changing strict admission.

Broad-corpus zero hits alone are not retirement proof. The first retirement
probe found three paths used only by inline backend tests. Canonical CFG now
owns every `scalar_control` case, so its standalone 468-line plan, 32-line plan
test and both backend implementations were deleted, reducing the registry to
32 plans. `simple_conditional_statement_return` has been retired after dead
conditional continuations and branch-local global accesses moved into canonical
executable MIR. `identity_return` is also gone: executable MIR now carries a
resolved function `SymbolId`, while both mechanical renderers distinguish that
pointer value from an ordinary global load. The registry is down to 31 plans.
`simple_loop_return` remains.
A deletion is accepted only when the exact-path census and both complete
backend shards agree that coverage is unchanged.

## Remaining families, by tractability

### Closed this migration (direct-return / direct-void, all both-backend)

Each was a recognizer family + gate case + render case, validated identically
(both shards green, emitted C/LLVM compile under clang, all function source-map
entries have nonzero generated lines, soundness/parity probes). The same discipline caught
optional-deref, pointer-compare, evaluation-order, unequal-width bitcast, and
typed-unary operand-descendant bugs before commit.

| Family | Example | Commit |
|---|---|---|
| Direct-return checked arithmetic | `pa_diff`, `wrap_add` | `71b3299d` |
| Bare param return past elided nonnull | `return p` (`p: *u32`) | (session) |
| Scalar deref of param ptr | `return p.*` | (session) |
| Plain unsigned binary (add/sub/mul/and/or/xor) | `return a + b` | (session) |
| Plain unary | `return -a`, `return !b` | (session) |
| Pointer-field load | `return s.next` | (session) |
| Address constructor (`phys`) | `return phys(v)` → `uintptr_t` | (session) |
| Bitwise binary | `return a & b` | (session) |
| Address-typed field / deref | `PAddr`/`VAddr` field & `*p` | (session) |
| Pointer comparison | `return a == b` (ptr params) | `8591552e` |
| Local call chain | `let x = f(); return g(x)` | (current batch) |
| Nested local call initializer (C) | `let x = f(g(a), b); return h(x)` | (current batch) |
| Leaf-operand typed unary call targets | numeric conversion, `phys`, `bitcast`, `enum.raw`; root keyed by `typed_unary_operand` SpanId/type fact | (current batch) |
| Leaf-operand typed binary domain calls | `wrapping.add`, serial before/after/distance, counter delta; indexed roots keyed by owner-qualified `typed_call_operand` facts | (current batch) |
| Shared straight-line statement plan | discarded non-void call; zero-argument function-pointer call through param/local | (current batch) |
| Typed indirect call return plan | `return op(x,y)`, global/local function-pointer, global struct-field function-pointer, and checked constant-index global table projections such as `ops[1](x,y)` / `boxes[1].combine(x,y)` | (current batch) |
| Pure logical return tree | `return a && b`, `return !a || (b && c)`; MIR owns typed operand edges | (current batch) |
| Shared field-place read/store plan | global, by-value parameter, and non-local-initialized local fields, including `box.pair.left`; MIR owns local initializer, member-base, field-index, assignment, and return edges | (current batch) |
| Shared fixed-array place plan | constant-index reads, global stores, and non-local-initialized local array copies; MIR owns base/index identities, canonical literal value, static bound, and Bounds trap edges | (current batch) |
| Nested fixed-array stores | nested array/field projections plus scalar and bounded one-level integer-array literal stores; MIR owns aggregate operand identities and both backends validate declared element count/type | (current batch) |
| Scalar switch returns | exhaustive integer/character cases with literal returns; MIR owns normalized signed-magnitude patterns and both backends consume one shared CFG plan | (current batch) |
| Local aggregate assignment generation | `var x: T = uninit; x = aggregate; return x`; MIR owns the local generation, assignment edges, aggregate operands, and resolved struct field indices | (current batch) |
| Local aggregate projection updates | nested struct/array literal initialization followed by one local field/constant-index update and projected return; a bounded recursive MIR value graph owns operand order and field indices, local roots join by `ValueId`, and Bounds edges/facts join through `SpanId` | (current batch) |
| Direct-call aggregate projection returns | `make_values(seed)[index]`, `make_bag(seed).values[index]`, and `make_bag(seed).tail[index]`; MIR owns the callee, indexed arguments, projection chain, dynamic bounds edge, and exact representation fact while both backends evaluate the call once | (current batch) |
| Sequence foreach return | parameter arrays/slices, direct calls returning either representation, field-projected arrays, and a staged zero-argument nested call; `.for_element` carries the binding `ValueId`, slice representation checking stays explicit, and one shared CFG plan owns iterable evaluation, first-element, and empty-sequence exits | (current batch) |
| Parameter while with immediate break/continue | MIR emits a source-bearing `control_transfer` instruction and one shared three-block CFG plan validates condition identity plus exact loop/exit edge before either backend renders it | (current batch) |
| Slice foreach scalar update + break/continue | one bounded shared CFG plan owns slice representation, local generation, element binding, replacement or checked-add operand edges, overflow trap, source-bearing control transfer, and final return; `tests/llvm/for_loops.mc` is now 100% MIR-admitted in both backends | (current batch) |
| Function-symbol identity return | `fn entry_of() -> fn() -> void { return tick; }`; canonical executable MIR owns the resolved function `SymbolId` and both mechanical renderers emit its pointer identity directly; the specialized plan has been deleted | `identity_return` retired |
| Local function-pointer call | `let op: fn(A,B)->R = target; return op(a,b)`; the indirect-call plan now proves the local generation, initializer function identity, callee root, signature, and indexed arguments, while both backends preserve a materialized local and indirect call | (current batch) |
| Nullable pointer promotion | `let maybe: ?*T = p; return maybe`, null-init + reassignment, and `consume_nullable(p)`; one shared MIR plan joins `ValueId`, call `SpanId`, exact nullable/non-null type facts and the statically satisfied representation edge, while both backends preserve local storage/order and omit the impossible trap | (current batch) |
| Nullable pointer try | `return maybe?`, `return make_nullable()?`, direct/void one-argument consumers, and a zero-argument source call; one shared MIR plan joins the `try_operand`, unwrapped value, call argument, representation-use facts, and exact InvalidRepresentation/Unwrap edge pair while both backends evaluate the source exactly once | (current batch) |
| Checked pointer-root places | indirect calls such as `return op.combine(x,y)` and scalar stores such as `env.value=value`; MIR owns the canonical pointer root, projection, representation check/trap, argument/value identities, and both backends preserve atomic access semantics | (current batch) |
| Checked pointer-to-integer cast | `return p as usize`; MIR owns source/target type facts, pointer `ValueId`, exact representation edge, and the return edge while C/LLVM only spell the target cast | (current batch) |
| Checked scalar local generation | `let x: u32 = n + 1; return x`; a shared plan owns the local generation, typed operands, overflow edge, source locations and return identity while both backends preserve a materialized local instead of folding it | (current batch) |
| Pure scalar bitcast | equal-width integer/float reinterpretation; MIR owns canonical operand/result types and C uses `__builtin_bit_cast` while LLVM uses `bitcast` or identity | `21e8a53a` |
| By-value struct member projection | nested value projections; MIR owns aggregate type, dense field index, field/result types, and presentation spelling; C/LLVM render mechanically | (current batch) |
| Direct pointer-member scalar access | non-null `*Struct` parameter field reads/writes lower as `deref + field` places with a representation edge; C emits checked `root->field`, LLVM emits checked GEP plus atomic load/store; pointer-valued and nested/temporary roots remain closed | (current batch) |
| Address-class representation cast | 64-bit unsigned integer ↔ PAddr/VAddr-style address classes; MIR owns the cast kind and both backends mechanically preserve the 64-bit representation; narrower/signed and pointer conversions stay closed | (current batch) |
| Compile-time reflection constants | `sizeof`, `alignof`, `field_offset`, `bit_offset`, `repr_of`; MIR selects a checked 64-bit `usize` value and both backends render the same literal, including struct/overlay/C-union layout | (current batch) |
| Declared-struct construction | MIR owns aggregate `TypeId`, declaration-order field table and source-order operands; both renderers consume the same verified permutation | `7e95352b` |
| Target-typed binary/character literals | unsuffixed integer and character operands adopt the binary operand type; character spelling is parsed once and removed from executable MIR | (current batch) |
| Explicit scalar `uninit` storage | `var x: T = uninit` becomes `local_init(value=null)` for scalar storage; later assignment/store owns the first value generation | (current batch) |
| Declared-struct construction | MIR owns a `TypeId`-keyed aggregate table, exact field types and resolved field indices; operands evaluate in source order while C/LLVM assemble declaration-order layout; duplicate/incomplete/mistyped fields fail verification | (current batch) |

### Remaining strict-corpus families

None. Nullable control, access/address, slice terminals, aggregate sequence,
workflow, stack allocation and nested conditional parity are admitted by both
backends. Zero strict fallback is necessary but not sufficient: P0 completes
only after the broad language corpus no longer needs the AST artifact and the
artifact type plus legacy branches are physically deleted.

### Broader remaining families, by tractability

| Family | Example | Blocker | Effort |
|---|---|---|---|
| Remaining builtin / `call_target` returns | bounded/assumption/Result-producing and three-operand domain calls | each kind still needs an explicit typed semantic descriptor, control/result model, and backend rendering; leaf binary domain calls no longer fall back | **medium per semantic family** |
| Builtin / `call_target` void bodies | `store_release`, atomics | same statement-level/builtin gap (plain void calls already admitted) | **large** |
| Checked-operand comparison | `return (a+b) == b` | `SimpleMirCompareBinary` operands are `SimpleMirArg` (no `checked_binary` variant); needs a richer operand type | **medium** |
| Remaining multi-statement returns | locals initialized by non-call expressions, multiple locals, assignments, traps | C now also covers one nested call inside the initializer; LLVM and the remaining shapes need a general MIR statement/value sequence | **large** |
| Remaining folded-`let` families | nested casts/calls/loads and multiple locals | the first checked scalar generation now preserves local/source shape; the remaining expression graphs need bounded MIR value plans | **large** |

The remaining chunk is no longer mostly recognizer-shaped. Pure boolean
parameter trees now use explicit operator operand `SpanId` edges and one shared
plan; neither backend reconstructs their shape from source. The shared
statement-level plan admits discarded non-void calls and zero-argument
function-pointer calls through params or one direct-call-initialized local. A
second shared plan admits value-producing indirect calls returned immediately;
MIR owns the indexed argument values and canonical callee root/projection, and
both backends only render that plan. Closures, non-leaf arguments,
reassignment, traps, and cleanup still fail closed. The next expansion must add
explicit MIR operands rather than another backend-local recognizer.
Multi-statement returns, builtin/void bodies and,
for folded-`let`, a source-map-derived-from-MIR change remain. Plain
function-call returns/voids are already admitted. Leaf-operand
typed unary call targets now share one descriptor; complex roots remain on the
full path until the entire expression is representable. New kinds must supply
complete MIR type facts and explicit rendering rather than add another return
union variant.

## Honest bottom line

After the one clean gate-widen (checked arithmetic), the remaining families are
NOT quick recognizer additions — they need the fast path extended to
statement-level and builtin lowering (large), plus a source-map-from-MIR change
to admit folded-`let` shapes without losing fidelity (large). Completing P0
(deleting the AST body ingress) is effectively re-implementing full body
emission on MIR at fallback fidelity. Multi-week. Related: the two P1 goals
(minimal CheckedProgram identity, module-graph cutover) are separate bounded
foundations; see [[p0-spanid-decoupling-blocked]] for the corrected dependency
analysis (P0 is NOT coupled to module-graph's source basis).

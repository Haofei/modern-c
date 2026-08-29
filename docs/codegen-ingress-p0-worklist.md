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

The strict corpus is not the P0 completion definition. The current 2026-08-29
broad sweep over 522 repository MC roots de-duplicated to 1760 C and 1831 LLVM
functions. It found 576 C and 617 LLVM AST-body fallbacks. Report
mode preserves partial records from reject/unsupported roots, so these totals
are the current migration snapshot rather than a direct throughput comparison
with older root sets. Those
figures establish that final deletion now requires a
general syntax-free executable MIR body and mechanical backend renderers; more
strict-corpus recognizers are no longer an honest completion strategy.

### Last completed broad census snapshot (2026-08-29)

The 522-root sweep found C **1184/1760 admitted (67.3%)**, 576 fallback, and
LLVM **1214/1831 admitted (66.3%)**, 617 fallback. There were no unsupported
bodies because the transitional AST ingress is still present, and no
canonical-ready body fell through to either backend's legacy ingress. The latest
slice moved nullable-pointer unwrap into one typed executable-MIR operation
with an exact `Unwrap` edge, then deleted `NullableTryPlan` and both backend
implementations. Six broad-corpus functions per backend moved from specialized
admission to canonical emission. The broad split is therefore C **1069
canonical / 115 specialized** and LLVM **1086 canonical / 128 specialized**.
The strict ratchet is **107 C / 107 LLVM canonical functions**, specialized
admission has fallen to **53/53**, and specialized plan definitions to **12**.
`simple_return` remains a bounded safety net at **31 C / 35 LLVM** broad uses;
its earlier retirement probe was reverted because the lowering shards exposed
fault-injection and edge-case behavior that canonical MIR does not yet own.

Optional and `Result` if-let discrimination and payload extraction now use
explicit executable-MIR variant operations. A typed synthetic local guarantees
single subject evaluation; the verifier binds each discriminant/payload kind to
the matching optional or Result shape. This removes six C and ten LLVM broad
fallbacks and replaces six/seven specialized admissions.

Optional-value equality against `null` is now an explicit representation-tag
operation in both mechanical renderers. This replaces the invalid C aggregate
comparison that had already been admitted and moves four de-duplicated LLVM
functions from fallback to canonical executable MIR. Equality between two
non-null optional aggregates stays closed until MIR defines payload equality.
The focused no-fallback ratchet is now 153 tests per backend.

Nested fixed-array aggregate construction now carries a recursive layout-
complete proof. The producer sets that bit only after the child array metadata
exists; LLVM consumes the nested layout directly, and C derives the existing
framed array typedef name recursively from the same MIR shape. This moves
`make_for_bag` off fallback in both backends without admitting incomplete
layouts. The focused no-fallback ratchet is now 152 tests per backend.

The built-in `IrqOff` witness now retains its nominal MIR spelling while using
the one-byte ABI already owned by `scalar_repr.zig`. It no longer collapses to
opaque `.value`, so ordinary acquire/use/restore functions are syntax-free in
both renderers. This moves `critical_read` off AST fallback and `read_device`
off `simple_return` in each backend; broad fallback falls by one and
`simple_return` use is now 31 C / 35 LLVM. The normalization is deliberately
limited to `IrqOff`: user-declared enums such as `Error` keep their enum
identity. The focused no-fallback ratchet is now 151 tests per backend.

Qualified enum variants now become canonical executable-MIR literals before a
`.raw()` projection is rendered. `Enum.case` no longer masquerades as a runtime
aggregate member load or acquire a false representation trap; the legacy MIR
still records the non-trapping proof marker required by closed-enum uses. A
focused census over `enum_raw_closed_g25_g27.mc` reduces AST fallback from three
to two functions in each backend, and the no-fallback ratchet is now 150 tests
per backend. The broad totals above are a fresh de-duplicated snapshot; their
denominators differ from the preceding run, so they are not presented as a
nine-function migration delta.

Wrapping-domain unary negation is now a fully mechanical LLVM operation. MIR
already distinguished `wrap<T>` from checked integers; LLVM admission now
accepts that exact domain with no trap edge and emits modular `sub T 0, value`.
This moves `allow_wrapping_neg` from transitional `simple_return` to canonical
MIR, reduces broad LLVM `simple_return` use from 37 to 36, and raises the
focused no-fallback ratchet to 149 tests per backend. C already emitted the
same verified operation and its corresponding regression now also forbids
body fallback.

Target-typed negative integer literals now lower as canonical signed values.
Suffixed literals keep their declared integer type; unsuffixed literals adopt
the expected signed type; and the signed minimum is represented directly rather
than as an overflowing runtime negation. Dynamic negation continues to require
its exact trap edge. This removed 15 broad fallbacks per backend and raised the
focused no-fallback ratchet to 148 tests per backend.

Scalar trapping integer conversions now carry one canonical range relation and
one exact `IntegerOverflow` owner. The producer covers unsigned narrowing,
signed/unsigned crossings and value-preserving widening up to 64 bits; 128-bit
extrema remain closed. C and LLVM evaluate the operand once and mechanically
render the same fact. This removed three broad fallbacks per backend and raised
the focused no-fallback ratchet to 148 tests per backend.

The same relation now owns the remaining non-Result scalar conversions:
`wrap_from`, `from_mod`, `sat_from`, and storage-preserving domain `from`.
The renderers no longer reconstruct their width/sign behavior from source
syntax. Saturation has no trap edge and clamps both signed/unsigned boundaries;
modular forms use the verified integer resize. The conversion fixture is 8/8
canonical in both backends. This removes two more broad fallbacks and three
`simple_return` admissions per backend.

Fallible `try_from` conversions now consume the same relation and a canonical
`Result<T, ConversionError>` type fact. The C renderer evaluates its operand
once and selects a typed success/error aggregate; LLVM emits the equivalent
tagged aggregate. This removes the `narrow_try` and `widen_try` fallbacks in
both backends. The scalar conversion family is therefore no longer a source of
AST fallback in `tests/c_emit/conversions.mc` or for those two result helpers.

`serial.compare` now owns its half-window ambiguity rule and
`Result<Order, AmbiguousSerialOrder>` storage in executable MIR. The producer
maps the library scalar identities to canonical `i8`/`u8` payload storage, while
C retains the nominal helper name and LLVM consumes only the storage layout.
This directly removes `seq_compare` and also lets several existing Result
constructors become canonical. Broad `simple_return` use falls to 29 C / 42
LLVM, with no new specialized plan.

Fixed-array `ValueType` identity now includes the immediate element spelling
and known length instead of collapsing every array to the same `"array"` key.
Executable aggregate metadata recursively records bounded nested arrays and
represents large homogeneous arrays with one element-type slot plus their full
logical length. LLVM admission validates that nested layout before typed GEP
emission, so preflight and rendering cannot disagree. This removed all nine
previous canonical-ready LLVM ingress mismatches and moved six broad LLVM
functions off AST fallback without changing C fallback coverage.

The scalar-MMIO slice makes plain `Reg<u8|u16|u32|u64, access>` reads and writes
typed executable-MIR operations. MIR owns the MMIO parameter identity, aligned
byte offset, storage `TypeId`, access ordering and value evaluation; C and LLVM
mechanically emit volatile access plus acquire/release barriers. `RegBits`,
mapped addresses and computed receivers remain fail-closed. Mutation tests
reject illegal read/write orderings and non-MMIO bases. The slice also exposed
and fixed a pre-existing CFG bug: a `while` back-edge jumped directly to the
body, so an effectful condition was evaluated only once. The back-edge now
returns to the condition header, and both ordinary loop plans and MMIO loop
tests enforce that invariant.

The preceding slice
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

The bounded scalar atomic family now has typed executable-MIR operations for
init, load, store, fetch-add and fetch-sub. Operations own the atomic place,
payload identity, ordering and any exact `InvalidRepresentation` edge. Local
`atomic<T>` storage is normalized to `T`; globals and direct pointer receivers
share the same operation model. C emits `__atomic_*`; LLVM emits
`load/store atomic` and `atomicrmw`, mapping bool storage through `i8`.
Ordering enum spelling is consumed by MIR construction instead of becoming a
backend operand. Aggregate atomic fields, nested pointers and non-scalar
payloads remain closed. In the expanded 564-root sweep, the enum-literal
blocker fell from 43 to 25 per backend and admitted paths rose by 42 while the
corpus itself grew by 38 functions.

Runtime assertions now carry a statement-owned, exact `Assert/assert_stmt`
edge into executable MIR. Producer completion and the verifier require one bool
condition in the same statement/block and one typed trap terminator. C branches
to that trap block and LLVM emits an explicit guard/continuation edge, so neither
renderer reconstructs assertion semantics from the AST. Short-circuit and
comptime assertions stay fail-closed. In the broad census this moved two
module-visibility functions per backend to the renderer boundary without yet
changing the admitted totals.

The census also ranks the canonical stopping layer. For C the remaining 629
fallbacks are 614 `producer_incomplete` and 15 `renderer_unsupported`; LLVM is
654/30. The ready-but-fallback bucket is zero in both backends. Producer-incomplete
records also carry a backend-neutral reason emitted beside the canonical body.
The leading C reasons are `trap_projection` (125),
`producer_invariant` (91), `unsupported_member` (85), and
`unlowered_index` (48). LLVM has `trap_projection` 141,
`producer_invariant` 91, `unsupported_member` 85 and `unlowered_index` 63.
By-value struct member
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
| C | 160 | 160 | 0 | 0 | 10000 | 67 | 93 | 25 |
| LLVM | 160 | 160 | 0 | 0 | 10000 | 64 | 96 | 25 |

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
pointer value from an ordinary global load. `logical_return` is gone as well:
executable MIR owns the recursively verified proof that eager evaluation of a
pure boolean tree is equivalent to source short-circuit evaluation.
`pointer_to_integer_cast` is now canonical too: its typed cast preserves the
pointer representation guard and target integer type in both renderers. The
`nullable_pointer_void_call` plan is gone as well. Direct non-C-ABI calls may
now admit only the verified representation-preserving non-null-to-nullable
pointer widening; C consequently retains the same `InvalidRepresentation`
guard that LLVM already emitted. Nullable-pointer local initialization and
assignment now use the same bounded typed cast, and the mechanical renderers
preserve the guard before creating the nullable value. Their dedicated local-
return plan has also been deleted. Pure logical assertion trees now use one
MIR-owned eager-safety proof shared by the producer, verifier, and both
renderers; the standalone assertion plan and file are deleted. Targetless
integer literals are now contextualized before executable-MIR coercion
classification, so checked shifts no longer mark an otherwise complete body
incomplete. This moved the last `scalar_expression` user (`high_word`) to the
canonical renderer; `flag_set` was already canonical. The 381-line plan, its
tests, and both backend implementations are deleted. The registry was down to
25 plans at that checkpoint. Subsequent retirement batches removed the
remaining straight-line statement plan, enum-switch plan, and the now-
redundant `nested_conditional_return` plan. The nested classify fixture stays
canonical in both complete backend shards, while deleting its standalone
recognizer/model and both backend renderers brought the registry to 19 plans.
Scalar integer/character switches now use the same canonical executable switch
table as enums; deleting their dedicated plan brings the current registry to
18 plans and moves the strict split to C 75/85 and LLVM 74/86.
`simple_loop_return` remains.

`simple_void_body` is retired. Executable MIR now carries callable parameter
signatures and accepts write-only locals, while lexical contract calls and
fixed-array bodies are canonical. The two production users in `std/fmt` use the
canonical renderer. Synthetic aggregate-global and pointer-projection fixtures
which still lack complete executable facts deliberately take the general AST
fallback; they no longer justify keeping a parallel specialized plan. The plan,
recognizer, both renderers, census path, and write-only-local admission
heuristic were deleted only after both complete backend shards agreed.
The strict corpus remains C 84 canonical/76 specialized and LLVM 83/77; the
shared specialized-plan registry is now 15 definitions.

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
| Straight-line indirect-call statement | discarded non-void calls and zero-argument function-pointer calls now use canonical executable MIR with a verified callable signature; the shared specialized statement plan and both emitters are deleted | `statement` retired |
| Typed indirect call return plan | `return op(x,y)`, global/local function-pointer, global struct-field function-pointer, and checked constant-index global table projections such as `ops[1](x,y)` / `boxes[1].combine(x,y)` | (current batch) |
| Pure logical return tree | `return a && b`, `return !a || (b && c)`; MIR owns typed operand edges | (current batch) |
| Shared field-place read/store plan | global, by-value parameter, and non-local-initialized local fields, including `box.pair.left`; MIR owns local initializer, member-base, field-index, assignment, and return edges | (current batch) |
| Shared fixed-array place plan | constant-index reads, global stores, and non-local-initialized local array copies; MIR owns base/index identities, canonical literal value, static bound, and Bounds trap edges | (current batch) |
| Nested fixed-array stores | nested array/field projections plus scalar and bounded one-level integer-array literal stores; MIR owns aggregate operand identities and both backends validate declared element count/type | (current batch) |
| Scalar switch returns | exhaustive integer/character cases with literal returns; MIR owns normalized signed-magnitude patterns and both backends consume one shared CFG plan | (current batch) |
| Enum switch returns | executable MIR owns the enum subject, normalized numeric case table, default InvalidRepresentation trap, and arm BlockIds; the duplicated C/LLVM recognizer and emitters are deleted | `simple_enum_switch_return` retired |
| Local aggregate assignment generation | `var x: T = uninit; x = aggregate; return x`; executable MIR owns storage, aggregate construction, assignment, reload and return; the specialized plan and both backend branches are deleted | `local_aggregate_assignment_return` retired |
| Local aggregate projection updates | nested struct/array literal initialization followed by one local field/constant-index update and projected return; a bounded recursive MIR value graph owns operand order and field indices, local roots join by `ValueId`, and Bounds edges/facts join through `SpanId` | (current batch) |
| Direct-call aggregate projection returns | `make_values(seed)[index]`, `make_bag(seed).values[index]`, and `make_bag(seed).tail[index]`; MIR owns the callee, indexed arguments, projection chain, dynamic bounds edge, and exact representation fact while both backends evaluate the call once | (current batch) |
| Sequence foreach return | parameter arrays/slices, direct calls returning either representation, field-projected arrays, and a staged zero-argument nested call; `.for_element` carries the binding `ValueId`, slice representation checking stays explicit, and one shared CFG plan owns iterable evaluation, first-element, and empty-sequence exits | (current batch) |
| Parameter while with immediate break/continue | Canonical executable MIR owns the source marker and exact loop/exit CFG edges; both renderers ignore the presentation-only marker and follow the verified terminator | `while_control` retired |
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
| Local-address scalar update | `let p: *mut T = &x; *p = x + 1`; executable MIR proves the immutable local-address alias, owns the checked store and representation edge, and both renderers consume the same proof | `access_local_address_update` retired |
| Terminal explicit trap / unreachable | Return or expression-statement termination is a verified CFG jump to an exact trap terminator; explicit reasons join through opaque `SpanId`, and neither backend scans source locations or selects runtime helpers | `simple_trap` retired |

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
plan; neither backend reconstructs their shape from source. Canonical
executable MIR now admits discarded non-void calls and zero-argument
function-pointer calls through params or one direct-call-initialized local. A
remaining shared plan admits value-producing indirect calls returned immediately;
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

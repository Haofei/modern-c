# Typed semantic facts / typed MIR design

This is the design slice for the compiler-production-readiness Phase 4 bucket
"Typed fact table: sema resolves once, backends consume". It turns the current
architecture note into implementable phases with invariants and evidence gates.
"Phase 4" names the completed narrow foundation, not the broader remaining
typed-fact migration umbrella. The current closure matrix for that umbrella lives
in [`compiler-production-readiness.md`](compiler-production-readiness.md).

## Current state

### Status boundary

Completed statements in this document describe verified, committed fact-family
work. An active implementation slice is not evidence and does not extend the
claimed supported subset until its focused gates pass. The completed direct local
aggregate-alias slice emits ordinary MIR `PointerProvenanceFact` rows for member
and fixed-array-element reads through an alias initialized directly from
`&local_aggregate`; C and LLVM consume them and fail closed when a destination
row is removed.

The completed analogous direct local fixed-pointer-array alias slice covers a
pointer initialized directly from `&ptrs` and then dereferenced at a constant
index. MIR emits the destination fact, and both backends fail closed when that
destination row is removed. Dynamic alias indexes remain outside this slice.

The completed dynamic extension emits a destination fact only when every backing
pointer-array element has the same live provenance kind. Mixed, invalidated, and
reassigned shapes remain unknown.

The completed semantic inference register names backend/sema/MIR inference
families that can affect lowering semantics, records their current owner,
consumer, migration status, and fail-closed policy, and is gated by
`tools/toolchain/semantic-facts-inventory.py`. This closes the inventory action
slice, not the migration of those families.

The completed backend AST-inference budget sets the current shrinking budget to
seven registered backend families. This closes the budget action slice; each
budgeted family still needs a later migration, reduction, or accepted limitation
decision.

The completed scalar pointer deref default audit records the current C/LLVM
decision entry points and default behavior for missing provenance. It closes the
audit action slice, not the escaped-pointer or aggregate-return CFG policy
boundaries.

The completed escaped pointer boundary audit covers direct pointer argument
escape, aggregate address escape, and existing callback escape cases. Returned
pointer facts now cover direct internal returns, local function aliases, and
conservative callback/exported ambiguity. Arbitrary-CFG aggregate provenance
remains open.

The compiler already has several fact-like surfaces, but they are not a single
typed semantic source of truth:

- `mcc facts` parses a module and prints `src/ir.zig`'s fact collector output via
  `ir.appendFacts`. These are textual inspection facts for semantic traps,
  contracts, MMIO, race semantics, and related spec evidence.
- `mcc lower-ir` prints the same `src/ir.zig` model as a compact textual IR
  artifact. It is useful for fixtures, but backends do not consume it.
- `mcc lower-mir` builds MIR through `src/mir.zig`. `src/mir_model.zig` gives
  instructions a `ValueType`, source line/column, optional `value_id`, contract
  metadata, `RangeFact`, `RepresentationFact`, and `elided_bounds`; the dump
  prints instruction `value_id` fields plus explicit `mir representation_fact`
  and `mir elided_bounds_fact` rows for representation identity and optimized
  check-elision source points.
- `src/mir.zig` already records range/elision facts for optimizer-visible
  checks. `Function.elided_bounds` is a span-keyed list of source points where a
  bounds/division check was proven dead, and `Function.range_facts` records
  unchecked arithmetic range evidence inside contract regions.
- The C backend (`src/lower_c_emitter.zig`) and LLVM backend
  (`src/lower_llvm.zig`) both consume optimized MIR `elided_bounds` through
  `mirCheckElided`, so this is the existing parity template: one MIR fact,
  consumed by both backends, with checks kept when the fact is absent.
- Large classes of backend behavior still rederive semantics from the AST. The
  C backend has helper inference in files such as `src/lower_c_infer.zig`; the
  LLVM backend carries its own type/provenance maps and currently performs the
  richest pointer/global race provenance reasoning in `src/lower_llvm.zig`.

## First-principles invariants

1. Sema is the source of truth. A backend-consumed semantic fact must be created
   from sema's checked view of the program or from a MIR construction step that
   only preserves sema-validated meaning.
2. Facts are typed and keyed. A fact key is either a stable span key
   (`function_id + line + column + role`) for source operations or a `value_id`
   key for MIR values/places. Text snippets are display fields, not authority.
3. Backends fail closed when a fact is missing, stale, ambiguous, or has a kind
   they do not understand. "Fail closed" means emit the conservative runtime
   check, emit the conservative atomic/plain form, or return `Unsupported*Emission`
   with source context; it never means silently guessing.
4. No backend may infer a semantic fact that sema did not record. Backends may
   still perform local emission mechanics such as naming temporaries, choosing
   an LLVM instruction spelling for an already-typed operation, or computing a C
   helper name from a typed fact.
5. Facts with mutation/alias sensitivity must be invalidated on assignment,
   address escape, pointer escape, function call, indirect call, unknown
   aggregate write, dynamic-index write, and any backend-visible operation whose
   side effects could change the fact's operands.
6. Evidence must prove parity. A migration is not done until tests show the C
   and LLVM backends consume the same fact family for the same source program and
   make the same conservative choice when the fact is absent.
7. Textual artifacts stay debug surfaces. `mcc facts`, `lower-ir`, and
   `lower-mir` may print facts for humans/tests, but production lowering consumes
   typed in-memory facts, not reparsed text.

## Proposed shape

Add a `SemanticFacts` table that can be owned by a checked module or embedded in
typed MIR. The first implementation should be narrow and should not require a
full typed AST rewrite.

Candidate API shape:

```zig
pub const FactKey = union(enum) {
    span: SpanFactKey,
    value_id: ValueId,
};

pub const SemanticFact = union(enum) {
    check_elided: CheckElisionFact,
    pointer_provenance: PointerProvenanceFact,
    range_constraint: RangeConstraintFact,
};

pub const SemanticFacts = struct {
    by_span: std.AutoHashMap(SpanFactKey, SemanticFactId),
    by_value: std.AutoHashMap(ValueId, SemanticFactSet),
    facts: std.ArrayList(SemanticFact),
};
```

The exact types can live in `src/semantic_facts.zig`, `src/mir_model.zig`, or a
small MIR extension. The important contract is that each fact has:

- a kind-specific payload with typed enums rather than strings;
- a source span for diagnostics and artifact printing;
- the producing phase (`sema`, `mir_opt`) for auditability;
- an invalidation policy documented next to the fact kind;
- a textual dump adapter for `mcc facts`/`lower-mir` tests.

## Implementable phases

### Phase 1: inventory and stabilize current facts/artifact formats

Inventory every current fact-like output and consumer:

- `src/ir.zig`: `appendFacts`, `appendLowerIr`, trap/contract/MMIO/race text;
- `src/mir_model.zig`: `RangeFact`, `RepresentationFact`, `SourcePoint`,
  `Instruction.value_id`;
- `src/mir.zig`: `range_facts`, `elided_bounds`, `proven_facts`,
  invalidation in `invalidateFacts`, address-taking, assignment, loop, and call
  handling;
- C backend MIR consumption: `mirCheckElided` and range-contract consumers;
- LLVM backend MIR consumption: `mirCheckElided` and duplicated
  pointer/global-provenance inference maps.

Gate:

- a markdown inventory section or table lands with file/function references;
- `rg -n "typed-semantic|semantic fact|typed fact" docs src` finds the design
  and any new code comments;
- no behavior change.

### Phase 1 inventory: current fact-like surfaces

This table is an inventory of the current code, not a claim that these surfaces
are already one typed semantic fact table. Textual artifacts remain debug/test
surfaces unless a backend is listed as consuming the in-memory MIR data directly.

| Surface | Producer / representation | Invalidation and stability points | Artifact printer | Backend consumer / gap |
|---|---|---|---|---|
| Text IR inspection facts | `src/ir.zig:510` `Collector.appendFacts`, `src/ir.zig:525` `appendFacts`, and `src/ir.zig:590` `ModuleFactCollector.appendFacts` walk the AST and emit line-oriented `fact ...` rows for trap edges, `#[no_lang_trap]`, unsafe contracts, unchecked calls, ordinary/racing access, MMIO calls/access/order, and direct MMIO assignment. | AST-derived only; there is no typed in-memory table behind this surface. MMIO global/parameter discovery is held in `ModuleFactCollector.globals` / `mmio_structs` (`src/ir.zig:571-576`) and helper lookups such as `mmioAccess` (`src/ir.zig:664`) and `mmioRegisterTarget` (`src/ir.zig:746`). | `mcc facts` dispatches through `src/main.zig:291` and prints `ir.appendFacts` at `src/main.zig:645-648`. Representative rows include `fact checked_arithmetic_trap` (`src/ir.zig:1059`), `fact ordinary_access` (`src/ir.zig:1116`), `fact racing_load_semantics` (`src/ir.zig:1121`), `fact non_atomic_rmw` (`src/ir.zig:1165`), and `fact mmio_access` (`src/ir.zig:1199`). | No production backend consumes this text. It is evidence for tests/spec fixtures and must not become a reparsed backend input. |
| Lower-IR contract/trap artifact | `src/ir.zig:128` `appendLowerIr` builds `IrFunction` records with `trap_edges`, `safe_no_trap_ops`, `contract_regions`, and `unchecked_calls`; `FunctionIrBuilder.collectContractBlock` records contract regions at `src/ir.zig:378`. | Textual IR model only; contract activity is tracked by `FunctionIrBuilder.active_contract` / `active_contract_region_id` (`src/ir.zig:197-199`) while walking the AST. | `mcc lower-ir` dispatches through `src/main.zig:301` and prints `ir.appendLowerIr` at `src/main.zig:667-670`. It emits `ir contract_region`, `ir unchecked_call`, `ir trap_edge`, `ir post_contract_trap_edge`, and `ir safe_no_trap` rows (`src/ir.zig:137-180`). | No production backend consumes this artifact. Contract scope also has a C inspection artifact in `src/lower_c_inspect.zig:195-219`, but that is a lower artifact, not the source of backend semantic authority. |
| MIR typed instruction metadata | `src/mir_model.zig` `ValueType`, `Instruction`, and optional `value_id` / `contract_region_id` carry typed operation metadata. `Function` owns `contract_regions`, `range_facts`, `call_target_facts`, `target_type_facts`, `pointer_provenance_facts`, `representation_facts`, and `elided_bounds`. | `CallTargetFact` records bounded builtin/call identities. `TargetTypeFact` records the complete target `ast.TypeExpr` for `bind` and `ok`/`err` constructors, including local, assignment, return, call-argument, and nested aggregate propagation. Every row matches dedicated metadata at the same source point; exact validation rejects missing, stale, and duplicate rows. | `mcc lower-mir` prints function summaries plus owned `mir call_target_fact` and `mir target_type_fact` rows. | C and LLVM validate both tables before emission and consume target-type facts for closure/Result representation; broader semantic decisions remain in the registered fallback families. |
| MIR no-overflow range facts | `src/mir_model.zig:201` `RangeFact` records `region_id`, `target`, `op`, operands, result type, and source point. Producers are `FunctionBuilder.addRangeFactForUncheckedCall` (`src/mir.zig:2491-2507`) and `addAggregateRangeFactForUncheckedExpr` (`src/mir.zig:2509-2530`) inside active `#[unsafe_contract(no_overflow)]` regions. | These facts are appended for unchecked no-overflow calls in contract regions. They are not the same as transient optimizer `proven_facts`; they persist in `Function.range_facts` until the MIR module is freed. | `appendDumpOpt` prints `mir range_fact ... assumption=no_overflow recorded=true` at `src/mir.zig:359-364`; MIR verification facts also scan `function.range_facts` at `src/mir.zig:534`. LLVM emission prints non-semantic `; mir range_fact consumed ... assumption=no_overflow` comments when it consumes a fact; C emission prints `/* MC_MIR_RANGE no_overflow ... */` comments from its MIR-gated unchecked paths. The inventory checker anchors the owned `RangeFact` model, the dump row, and exact C/LLVM no-overflow range consumer call counts. | The C backend wires `has_mir_no_overflow_range_fact` through `arithContext` (`src/lower_c_emitter.zig:1591-1610`) and matches facts in `hasMirNoOverflowRangeFact` (`src/lower_c_emitter.zig:4545-4557`); its generic builtin dispatcher now rejects unchecked no-overflow calls instead of emitting plain arithmetic without a matching fact. C and LLVM both have target-label coverage for return values, inferred locals, assignments, call arguments, binary operands, array literal elements, and struct literal fields. LLVM requires `requireMirNoOverflowRangeFact` for `unchecked.add/sub/mul` and matches target identity through `current_mir_range_target` for those contexts. Removing a matching `RangeFact`, or retargeting it to a different target label in a prebuilt MIR module, makes both C and LLVM fail closed instead of trusting the AST call, including non-`value` inferred-local, assignment, call-argument, binary-operand, aggregate-element, and aggregate-field targets; absence coverage now explicitly spans those non-`value` contexts in both backends. Broader range/bounds facts are still not a complete typed fact family. |
| MIR bounds facts | `src/mir_model.zig` `BoundsFact` records index and slice checks that remain after MIR optimization; `FunctionBuilder.buildExpr` appends them with the same source point as the check. | Optimized proofs remain represented by `elided_bounds`; every non-elided array/slice check requires a `BoundsFact` instead of being accepted from AST shape alone. | `mcc lower-mir` prints the function `bounds_facts=N` count and stable `mir bounds_fact fn=... kind=index|slice recorded=true line=... column=...` rows. The inventory checker anchors the owned `BoundsFact` model, dump row, and C/LLVM `requireMirBoundsFact` consumers with exact call counts. | C and LLVM call `requireMirBoundsFact` before emitting non-elided array-index or slice bounds checks. Removing the matching fact from prebuilt MIR produces `UnsupportedCEmission` / `UnsupportedLlvmEmission`; direct missing-fact tests cover both backends. |
| MIR integer literal facts | `src/mir_model.zig` `IntegerFact` records accepted target-typed integer literal conversion with the literal text, target `ValueType`, and source point. `FunctionBuilder.addIntegerLiteralFact` appends an `integer_literal_conversion` metadata instruction plus the owned fact when `integerLiteralFitsTarget` accepts a conversion. | These facts are admission evidence for target-typed integer literal lowering. Out-of-range literals still produce MIR conversion diagnostics; accepted literals now have a positive MIR row instead of leaving backends to trust only AST target context. | `mcc lower-mir` prints `integer_facts=N` and stable `mir integer_fact fn=... literal=... target_type=... recorded=true` rows. The inventory checker anchors the model, producer, dump row, C/LLVM validator calls, and missing/stale tests. | C and LLVM call `validateIntegerFactsForLowering` at backend entry. Removing integer facts from prebuilt MIR, or retargeting one to a different integer type, returns `InvalidMirIntegerFacts` before backend emission. This is a bounded integer/default fact slice for target-typed integer literals, not full typed HIR replacement. |
| MIR check-elision source points | `src/mir_model.zig:212` `SourcePoint` and `Function.elided_bounds` (`src/mir_model.zig:234-239`) record checks proven dead by optimized MIR. Producers append source points for constant in-bounds index (`src/mir.zig:2263-2278`), constant in-bounds slice (`src/mir.zig:2293-2305`), and division/modulo elision (`src/mir.zig:2437`). | Transient `ProvenFact` guard/assert facts are recorded by `recordTrueCondFacts` (`src/mir.zig:2704-2730`), restricted by `factIdentAllowed` (`src/mir.zig:2743-2750`), and invalidated by new bindings, assignment, loops, and address-of (`src/mir.zig:1176-1178`, `src/mir.zig:1212-1214`, `src/mir.zig:1972-1982`, `src/mir.zig:2046-2049`, `src/mir.zig:2690-2697`). | `lower-mir --optimize` exposes absence of the original `cmp_bounds`/trap edge, records optimized instruction detail such as `const_in_bounds`, includes an `elided_bounds=N` summary count, and prints explicit `mir elided_bounds_fact ... recorded=true` rows from `Function.elided_bounds`. | Both backends consume the same MIR list and fail closed when absent. C uses `mirCheckElided` for array indexing and slice guards (`src/lower_c_emitter.zig:3574-3586`, `src/lower_c_emitter.zig:4272-4280`, `src/lower_c_emitter.zig:4564-4573`) and passes the hook into arithmetic lowering (`src/lower_c_arith.zig:58-59`, `src/lower_c_arith.zig:391`, `src/lower_c_arith.zig:467`, `src/lower_c_arith.zig:507`). LLVM uses function-filtered `mirCheckElided` for array indexing, slice guards, and div/rem checks (`src/lower_llvm.zig:6607-6616`, plus call sites), matching C's function-filtered source-point lookup. |
| LLVM backend-local pointer/global race provenance | `LlvmEmitter` owns backend-local maps for local function/aggregate/pointer-array aliases, aggregate field facts, array element facts, and slice facts (`src/lower_llvm.zig`). Aggregate-return pointer fields are loaded only from MIR facts by `collectMirAggregateReturnPointerFieldFacts`; the old LLVM AST pre-scan is retired. C admits pointer-local provenance through MIR-only helpers, while LLVM uses `updatePointerProvenanceFromMirOrLocalProof` for its registered local-only alias proof. | This remains the largest duplicated inference class. The Phase 5 cleanup retires LLVM's global pointer-local AST fallback and aggregate-return AST collector: covered direct forms without a MIR fact remain unknown, while non-MIR aggregate-alias shapes may preserve only an existing `local_storage` proof. LLVM also has no backend-local scalar pointer-return summary: supported direct, forwarded, noalias-wrapped, branched, and local-function-alias return flows are caller MIR facts. | `lower-mir` prints authoritative `mir pointer_provenance_fact ...` and `mir aggregate_return_pointer_fact ...` rows. C and LLVM tests cover fact consumption and missing-fact conservative lowering for direct locals, aggregate field paths, and aggregate-return pointer fields. | LLVM defaults bare scalar pointer dereferences to unordered atomics unless a live `local_storage` fact or syntactic `&local` proves locality. Scalar and aggregate pointer parameter call-site summaries, scalar pointer-return summaries, global AST fallback proofs, and aggregate-return AST summaries are retired; only the registered local aggregate-alias proof remains outside MIR. Direct local aggregate and aggregate-return provenance remain separate. |
| C backend global/race lowering helpers | `src/lower_c_global.zig` routes direct global scalar, array, and field accesses through race helpers or relaxed C atomics. Examples include `appendGlobalLoadExpr` (`src/lower_c_global.zig:142-150`), `appendGlobalStorePrefix` (`src/lower_c_global.zig:153-162`), `globalAssignmentTarget` (`src/lower_c_global.zig:176-183`), and array/member global access helpers (`src/lower_c_global.zig:219-242`, `src/lower_c_global.zig:270-315`). The Phase 4 C slice adds `src/lower_c_emitter.zig` MIR consumers such as `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, `applyMirPointerProvenanceForIndexAssignment`, `applyMirAggregatePointerFieldFactsAtSource`, `applyMirAggregatePointerFieldFactsForSubjectAtSource`, `applyMirPointerProvenanceInvalidationsAtCall`, and `derefAccessLowering`. | Direct global helper logic still keys from AST/global type information and `GlobalInfo`. For direct pointer-like locals, direct pointer-local copies from live global-backed locals, direct raw-many local `.offset(0)` transfers, direct fixed local pointer-array elements, direct aggregate pointer-field destination reads, constant-index direct aggregate pointer-array element destination reads, and direct aggregate `field_path` rows for covered direct struct-literal initializers, whole-aggregate and nested aggregate member struct-literal reassignments, field assignments, pointer-array element assignments, and same-struct aggregate copies, C consumes `Function.pointer_provenance_facts` at local initializer, assignment, index-assignment, and call-invalidation source points. Direct fixed pointer-array element destination reads now stay MIR-owned: if the destination fact is absent, C leaves the destination provenance unknown instead of reconstructing it from backend-local array-element state. Bare scalar pointee deref loads/stores default to `mc_race_load_*` / `mc_race_store_*` (or relaxed `__atomic_*_n` for pointer-shaped pointees); only a live `local_storage` fact or a syntactic `&local` keeps the plain path, and `unknown`/invalidated facts fall back to the race-tolerant default. The raw-many offset deref temp path delegates scalar loads through `emitRaceLoadTempFromPointerTemp`; pointer-member scalar fields, nested pointer-member scalar chains, slice scalar indexes, unproven pointer-to-array scalar indexes, scalar fields reached through pointer-backed indexed aggregate storage, and nested scalar member chains rooted in pointer-backed indexed aggregate storage also use race-tolerant load/store paths. Bare struct/fixed-array aggregate value copies through unproven pointer derefs, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, indexed and nested indexed aggregate fields, aggregate slice storage, and unproven pointer-to-array aggregate storage now lower recursively to race-tolerant scalar/pointer leaves where every leaf is supported; unsupported union-like leaves still fail closed. | `src/lower_c_inspect.zig:455-492` prints `lower ordinary_access`, `lower race_backend`, `lower race_semantics`, `lower c_ub`, and `lower racing_load_semantics` rows for direct global inspection. C emission also prints non-semantic `/* mir pointer_provenance consumed ... */` comments for the narrow facts it consumes, including `field=...` and `element=N` for aggregate field and array element rows. | C consumes MIR `elided_bounds`, `range_facts`, and now the narrow direct pointer-like local/direct-copy/direct raw-many zero-offset/direct fixed pointer-array element/direct aggregate pointer-read/direct aggregate `field_path` subset of `PointerProvenanceFact` for scalar deref load/store decisions. Conservative scalar lowering also covers call/member/index pointers, direct raw-many offset deref temps, pointer-member scalar fields, nested pointer-member scalar chains, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, slice scalar indexes, unproven pointer-to-array scalar indexes, indexed aggregate scalar fields, nested indexed aggregate scalar member chains, recursive indexed and nested indexed aggregate field value copies, recursive aggregate whole-element value copies, and recursive struct/fixed-array aggregate pointer derefs when locality is not proven; broader race/global helper decisions remain outside typed pointer-provenance facts. |

### Semantic inference family register

This register is the Phase 1 gate for backend semantic inference. Each row names
one inference family that can affect lowering semantics. The inventory checker
requires the row and its code anchors to remain present. Closing a family means
either migrating it to typed facts / MIR-owned state, or documenting it as an
accepted conservative fallback with missing-fact or diagnostic evidence.

| Family | Owner / source anchors | Current consumer | Migration status | Fail-closed policy |
|---|---|---|---|---|
| `c-expression-type-inference` | `src/lower_c_infer.zig` `operandEmitType`, `derefPointeeType`, return/type classifiers; shared `src/ast_query.zig` `enumVariantPathType` | C expression, aggregate, call, and deref emission | Registered backend inference; enum variant-path typing now uses the shared AST query instead of a C-local case scan, and the inventory forbids local reintroduction of that scan, but the broader family still needs typed facts/MIR migration. | Unsupported or unknown shapes return null/unsupported and must not invent a semantic fact. |
| `c-type-shape-classification` | `src/lower_c_info.zig` `localInfoFromType` / `globalInfoFromType`; `src/lower_c_shape.zig` shape helpers | C local/global model, race helper choice, aggregate-vs-scalar routing | Registered backend inference. | Unknown aggregate/scalar/race-helper shapes must reject or use conservative recursive lowering. |
| `c-abi-aggregate-lowering` | `src/lower_c_aggregate.zig` array/struct/tagged-union literal emitters | C aggregate values, ABI-shaped constructors, aggregate unchecked-call paths | Registered backend inference. | Unsupported aggregate forms return `UnsupportedCEmission`; extern/export by-value hazards remain diagnosed. |
| `c-call-target-classification` | `src/lower_c_call.zig` sequenced/bitcast/extern-nonnull call emitters plus MIR-gated semantic escapes; `src/lower_c_builtin.zig` builtin classifiers; `src/lower_c_reflect.zig` MIR-gated reflection emission; `src/lower_c_memory.zig` MIR-gated byte-view emission | C call emission and special builtin lowering | Registered backend inference. The five value-producing reflection intrinsics, both byte-view intrinsics, `declassify`/`reveal`, and `compiler.assume_noalias_unchecked` are MIR-owned: C uses the AST only to extract operands and select emission mechanics after an exact `CallTargetFact.kind` match. Other registered call categories remain to migrate. | Unknown call targets stay ordinary calls or unsupported; no provenance/range fact may be inferred from a call spelling. Missing or stale facts for migrated categories reject prebuilt MIR before emission. |
| `c-bounds-range-consumption` | `src/lower_c_emitter.zig` `requireMirBoundsFact`, `hasMirNoOverflowRangeFact`, `mirCheckElided` | C bounds checks, unchecked arithmetic, check elision | MIR-owned for current range/bounds/check-elision subset. | Missing/stale facts keep checks or reject prebuilt MIR. |
| `c-pointer-provenance-consumption` | `src/lower_c_emitter.zig` MIR provenance consumers and deref lowering | C pointer-mediated race lowering | MIR-owned for narrow direct subset; registered conservative fallback for broader scalar leaves. | Missing facts keep provenance unknown and use race-tolerant scalar lowering where supported. |
| `c-direct-global-race-helpers` | `src/lower_c_global.zig` direct global load/store helpers | C direct global scalar/array/member access | Registered direct-global backend inference. | Unsupported scalar helper widths fail closed; aggregate leaves recurse only through supported shapes. |
| `llvm-pointer-provenance-consumption` | `src/lower_llvm.zig` MIR-or-local-proof provenance consumers and race-tolerant deref lowering | LLVM pointer-mediated race lowering | MIR-owned for direct facts; one registered local-only proof remains outside MIR. | Missing facts default scalar derefs to unordered atomic unless positive local/raw/MMIO proof exists. |
| `llvm-expression-type-inference` | `src/lower_llvm.zig` `exprType` / `derefPointeeType`; shared `src/ast_query.zig` expression/call-shape queries | LLVM expression, call, deref, constructor, and MMIO emission | Registered backend inference. `bind` and `ok`/`err` still use shared AST queries only to recognize the operand shape, but their complete target type and representation now come from exact MIR `TargetTypeFact` rows; the former LLVM `bindClosureType` reconstruction is retired. Reflection, byte-view, declassify/reveal, noalias, bounded reduce/atomic/MaybeUninit/bitcast/phys and `const_get` use their existing MIR call-target gates. Qualified tagged unions, enum paths, raw/varargs and broader expression typing remain open. | Unsupported or unknown shapes return null/unsupported. Missing/stale target-type or migrated call-target facts reject prebuilt MIR before emission. |
| `llvm-bounds-range-consumption` | `src/lower_llvm.zig` `requireMirBoundsFact`, `requireMirNoOverflowRangeFact`, `mirCheckElided` | LLVM bounds checks, unchecked arithmetic, check elision | MIR-owned for current range/bounds/check-elision subset. | Missing/stale facts keep checks or reject prebuilt MIR. |
| `llvm-representation-fact-consumption` | `src/mir.zig` representation validator; `src/lower_llvm.zig` MIR validation at backend entry | LLVM representation-sensitive lowering | MIR-owned for current representation facts. | Missing/stale representation facts reject prebuilt MIR before lowering. |
| `mir-pointer-provenance-production` | `src/mir.zig` pointer-provenance producers and invalidators | C/LLVM pointer-provenance consumers | MIR-owned for direct local, aggregate-field, fixed-array, invalidation, and aggregate-return-adjacent subsets. | Unsupported producers emit unknown/no fact; consumers must remain conservative. |
| `mir-aggregate-return-production` | `src/mir.zig` aggregate-return pointer fact collector and bounded path cap | C/LLVM aggregate-return pointer-field consumers | MIR-owned for named bounded return shapes. | Unsupported CFG/aggregate shapes emit no fact and must stay conservative. |
| `mir-bounds-range-production` | `src/mir.zig` no-overflow range, bounds, and elided-check producers | C/LLVM range/bounds/check-elision consumers | MIR-owned for current bounded subset. | Missing optimization proof keeps runtime check; unchecked no-overflow consumption requires a matching fact. |
| `sema-call-type-resolution` | `src/sema.zig` call return/type helpers | Sema checking and MIR/backend source typing | Sema-owned source of truth, but not yet exported as a unified typed HIR. | Backends must not overrule sema; unsupported backend call spelling must reject or lower conservatively. |
| `sema-layout-representation-checks` | `src/sema.zig` layout, packed-bits, and bitcast-layout checks | Sema representation diagnostics and MIR representation facts | Sema/MIR-owned for current representation facts. | Backend representation lowering must require matching MIR facts or reject prebuilt MIR. |

### Representation-fact hardening audit

This audit gates the current representation-fact admission contract. A
prebuilt MIR module must carry an exact owned `RepresentationFact` row for each
representation-sensitive instruction, and it must not carry extra stale rows
that no longer correspond to an instruction. Backends validate this fact family
at entry instead of treating the AST as a second representation authority.

| Boundary | Evidence |
|---|---|
| Owned fact model | `src/mir_model.zig` owns `RepresentationFact` rows in `Function.representation_facts`; `src/mir.zig` records rows through the `representationFactKind` producer path. |
| Stable identity key | Facts match by instruction kind, result type, source point, detail, and `value_id`; `lower-mir` prints both instruction `value_id=...` and `mir representation_fact ... value_id=...` rows. |
| Backend admission gate | C calls `validateRepresentationFactsForLowering` from `appendCProfileWithMir`; LLVM calls it from `appendLlvmCheckedMir`. |
| Missing-fact rejection | `lower-c rejects prebuilt MIR with missing representation facts` and `LLVM rejects prebuilt MIR with missing representation facts` remove required rows and expect `InvalidMirRepresentationFacts`. |
| Stale-fact rejection | `lower-c rejects prebuilt MIR with stale representation facts` and `LLVM rejects prebuilt MIR with stale representation facts` retarget a required row and expect `InvalidMirRepresentationFacts`. |
| Extra stale-fact rejection | `lower-c rejects prebuilt MIR with extra stale representation facts` and `LLVM rejects prebuilt MIR with extra stale representation facts` keep all valid rows, append an unmatched stale row, and still expect `InvalidMirRepresentationFacts`. |

### Backend AST-inference budget

Current backend AST-inference budget: **8 registered families**.

This is a shrinking budget. These families are allowed only because their
current behavior is named, anchored, and paired with a fail-closed policy. A new
backend semantic inference family must either reuse an existing registered
family or deliberately update this budget. A migration slice that removes a
family from backend authority must reduce the count.

| Family | Budget class | Reduction condition |
|---|---|---|
| `c-expression-type-inference` | Backend AST inference budget | C expression type decisions that affect lowering are provided by typed facts/MIR or rejected when absent. |
| `c-type-shape-classification` | Backend AST inference budget | Local/global shape, aggregate/scalar routing, and race-helper eligibility are supplied by typed facts or an accepted target matrix. |
| `c-abi-aggregate-lowering` | Backend AST inference budget | Aggregate ABI/literal lowering consumes typed layout/ABI facts or rejects unsupported forms without backend rediscovery. |
| `c-call-target-classification` | Backend AST inference budget | Builtin/special call lowering consumes sema/MIR call-target facts instead of classifying callee syntax in the backend. |
| `c-direct-global-race-helpers` | Backend AST inference budget | Direct global race-helper routing is represented by typed memory/race facts or by an accepted direct-global backend policy. |
| `c-pointer-provenance-consumption` | Backend AST inference budget | Broader scalar-leaf conservative fallback is fully covered by typed provenance facts or an accepted default policy. |
| `llvm-pointer-provenance-consumption` | Backend AST inference budget | The remaining LLVM local-only proof is migrated to MIR facts or explicitly accepted as a local emission proof, not semantic inference. |
| `llvm-expression-type-inference` | Backend AST inference budget | LLVM expression type decisions that affect lowering are provided by typed facts/MIR or rejected when absent. |

### Scalar pointer deref default audit

This audit gates the current default for ordinary scalar pointer dereferences:
missing or unknown provenance must not silently produce UB-bearing plain memory
operations. Plain lowering requires a positive local-storage proof. Unsupported
scalar widths or aggregate shapes without a sound recursive lowering fail closed.

| Access path | Positive plain proof | Missing-proof default | Fail-closed boundary |
|---|---|---|---|
| C bare scalar pointer deref | `derefPointerHasProvenLocalStorage` accepts a live MIR `local_storage` pointer fact, a local aggregate/array element fact, or syntactic `&local` through grouped/cast wrappers. | `derefAccessLowering` routes scalar leaves through `mc_race_load_*` / `mc_race_store_*` and pointer-shaped leaves through relaxed `__atomic_*_n`. | Scalars without a race helper, such as unsupported wide scalar leaves, return `UnsupportedCEmission`; aggregate pointees use the recursive aggregate path instead of plain aggregate copy. |
| C aggregate pointer deref leaves | The same local proof keeps the aggregate access on the plain structural path. | `emitRaceTolerantAggregateLoadFromPtr` and `emitRaceTolerantAggregateStoreFromPtr` recursively lower scalar/pointer leaves through the race-tolerant helpers. | Unsupported aggregate kinds, union-like leaves, or non-constant array sizes reject emission. |
| LLVM bare scalar pointer deref | `pointerExprHasProvenLocalStorage` accepts a live MIR `local_storage` pointer fact, local aggregate/array provenance, or syntactic `&local` through grouped/cast wrappers. | `derefUsesRaceTolerantLowering` makes `emitDeref` / store paths pass `use_atomic=true`, so scalar leaves emit `load/store atomic ... unordered`. | Atomic-ineligible scalar leaves reject through `ordinaryAtomicScalarTooWide` / `UnsupportedLlvmEmission`; aggregate pointees use the recursive aggregate path. |
| LLVM aggregate pointer deref leaves | The same local proof keeps aggregate deref on the plain structural path. | `emitRaceTolerantAggregateDerefLoad` and `emitRaceTolerantAggregateDerefStore` recursively lower scalar leaves with `emitOrdinaryLoad/Store(..., true)`. | Unsupported unions, non-constant array lengths, or atomic-ineligible leaves reject emission. |

### Escaped pointer boundary audit

Escapes must drop positive local/global provenance before later dereferences.
This audit covers the currently named escape boundary; broader returned-pointer
policy and aggregate-return CFG policy are audited separately below.

| Escape path | Required lowering behavior | Evidence |
|---|---|---|
| Direct pointer argument escape | Passing a proven-local pointer to a direct call invalidates the live local proof before the next C/LLVM deref, so the later scalar load is race-tolerant. | `src/lower_c_tests.zig` and `src/lower_llvm_tests.zig` `escaped_local_pointer_lowers_race_tolerant`; C sequenced call statements apply `applyMirPointerProvenanceInvalidationsAtCall`. |
| Aggregate address escape | Passing `&aggregate` to a call invalidates pointer-field facts for the aggregate, so a later field read and deref stays conservative. | `escaped_aggregate_pointer_field_lowers_race_tolerant` in C/LLVM tests; MIR emits call invalidation for the aggregate field path. |
| Function-pointer callback escape | Escaped copied callback aliases do not prove scalar or aggregate pointer parameters local/global; callee derefs lower race-tolerantly. | `tests/spec/data_race_semantics.mc` callback escape cases and LLVM assertions for `consume_alias_copy_escape_param`, `consume_aggregate_alias_copy_escape_param`, and `consume_aggregate_indirect_escape_param`. |

### Returned pointer facts audit

Scalar pointer-return facts are deliberately narrow. MIR may summarize only
internal functions whose explicit returns all resolve to the same global-backed
pointer shape; caller locals receive normal `PointerProvenanceFact` rows from
that summary. Callback, exported, malformed wrapper, mixed, recursive, and
external-return paths stay unknown and must lower conservatively.

| Return path | Required fact/default | Evidence |
|---|---|---|
| Direct internal return | A non-exported helper that returns `&global`, or a well-formed `assume_noalias_unchecked` wrapper around it, may seed a caller-local `global_storage` fact. | `src/mir_tests.zig` `MIR records direct internal global pointer return provenance in callers`; C/LLVM `uses_returned_global_pointer` and missing-fact checks. |
| Local function alias return | A straight-line local function alias of an already summarized internal helper may seed the same caller-local fact; reassignment, branch, loop, or unknown alias keeps the call result unknown. | `MIR records internal global pointer return provenance through local function aliases`; C/LLVM `uses_global_pointer_through_alias`. |
| Callback/function-pointer return | A function-pointer parameter or escaped callback return is not summarized and does not produce pointer provenance. | C/LLVM `uses_callback_pointer_return` loads through race-tolerant scalar lowering with no consumed MIR provenance comment. |
| Exported pointer return | An exported function body is not used as a provenance producer, even if its implementation currently returns `&global`. | MIR `uses_exported_global_pointer` has no `global_storage` fact; C/LLVM `uses_exported_global_pointer` uses race-tolerant scalar loads. |

### Phase 2: add a typed fact table for one narrow fact family

Status: complete for the narrow MIR pointer/global provenance table described
below. This phase does not migrate backend consumption and does not close the
typed-facts bucket.

Introduce the table without migrating every fact. The first family should be
small enough to verify end-to-end.

Recommended first migration: pointer/global race provenance, because LLVM has a
large duplicated inference class today and the production ledger has many recent
race-provenance fixes. Start with a narrow subset:

- direct global address provenance for pointer-like locals initialized from
  `&global`;
- direct raw-many pointer-like locals initialized or assigned from
  `base.offset(0)` only when `base` is a direct raw-many local with a live
  `global_storage` fact, including valid noalias-wrapped zero-offset transfers;
- direct pointer-like locals initialized or assigned from another direct local
  pointer identifier only when that source has a live non-element
  `global_storage` fact with a compatible pointer shape, including valid
  noalias-wrapped copies of that pointer identifier;
- direct local fixed pointer-array element provenance for array literal elements
  and constant-index assignments initialized from visible `&global` or `&local`
  address expressions or compatible already-live direct pointer expressions such
  as pointer-local copies, plus destination reads from valid noalias-wrapped
  constant-index element expressions;
- direct aggregate pointer-field destination provenance for `let p = holder.ptr`
  / `p = holder.ptr` when the direct field was initialized or assigned from a
  visible `&global` / `&local` address expression or compatible already-live
  direct pointer expression such as a pointer-local copy or raw-many
  `.offset(0)` transfer, including noalias-wrapped direct address expressions;
- direct aggregate pointer-array element destination provenance for
  `let p = holder.ptrs[0]` / `p = holder.ptrs[0]` when the direct fixed
  pointer-array field element was initialized or assigned from a visible
  `&global` or `&local` address expression or compatible already-live direct
  pointer expression such as a pointer-local copy or raw-many `.offset(0)`
  transfer, including noalias-wrapped direct address expressions;
- direct same-struct aggregate initializer/assignment copies that propagate
  already-live direct aggregate pointer-field and pointer-array element
  provenance into later destination reads from the copied local;
- nested direct aggregate pointer-field and pointer-array element destination
  reads through direct local aggregate paths such as `outer.inner.ptr` and
  `outer.inner.ptrs[0]`;
- invalidation/unknown facts on pointer reassignment, whole-array reassignment,
  dynamic-index write, address escape, direct call, and indirect call.

Implemented shape:

- `src/mir_model.zig` defines `PointerProvenanceFact` with typed
  `PointerProvenance` (`global_storage`, `local_storage`, `unknown`),
  typed invalidation reason/policy enums, source point, subject local, optional
  aggregate `field_path`, optional element index, optional storage object, and
  `PointerShape`.
- `Function.pointer_provenance_facts` owns the typed fact slice alongside
  existing `range_facts` and `elided_bounds`.
- `src/mir.zig` produces facts while building MIR from sema-visible AST/MIR
  inputs. It deliberately recognizes only direct address expressions, the
  direct pointer-local copy and raw-many local `.offset(0)` transfers described
  above, direct fixed pointer-array places, direct aggregate pointer-field
  destination reads, and constant-index direct aggregate pointer-array element
  destination reads, including aggregate fields/elements assigned from
  compatible live direct pointer expressions, including raw-many zero-offset
  transfers and noalias-wrapped direct addresses, struct-literal aggregate
  pointer fields/elements initialized from those same direct expressions, and
  those reached through direct same-struct local aggregate initializer/assignment
  copies, nested direct aggregate member paths, and casted noalias-wrapped
  aggregate pointer-field or pointer-array-element read updates;
  raw-many zero transfers propagate both live `global_storage` and live
  `local_storage` from the base pointer. Computed values, dynamic reads,
  nonzero/dynamic offsets, call-produced bases, unsupported paths, or stale
  facts do not produce `global_storage`.
- MIR also emits explicit aggregate-field provenance rows with `field_path` for
  direct aggregate pointer fields and pointer-array fields, including nested
  paths, same-struct aggregate copies, reassignment, dynamic-index write
  invalidation, address escape, and call invalidation. These rows make the
  aggregate-field state auditable in `lower-mir`; backend migration of every
  aggregate-field consumer remains broader work.
- `appendDumpOpt` prints stable `mir pointer_provenance_fact ...` rows and the
  function summary includes `pointer_provenance_facts=N`.
- `src/mir_tests.zig` covers direct fact creation, local-storage facts,
  constant-index array assignment, raw-many zero-offset facts, direct aggregate
  reads through same-struct aggregate copies, nested direct aggregate reads,
  explicit aggregate `field_path` rows, aggregate pointer updates from live
  pointer-local copies, raw-many zero-offset expressions, and noalias-wrapped
  direct addresses, struct-literal field/elements initialized or reassigned from
  those expressions including nested aggregate member reassignments and explicit
  nested local-storage member initializer/reassignment evidence for scalar
  pointer fields and pointer-array elements,
  nonzero/dynamic offset and unknown-base
  fail-closed cases, reassignment invalidation, dynamic-index write
  invalidation, call invalidation, address-escape invalidation, absent
  computed-pointer facts, and dump text.

Alternative first migration: bounds/range check elision, because both backends
already consume `elided_bounds`. This is lower risk, but it proves less about
retiring duplicated backend AST inference.

Gate:

- typed fact constructors are called from the sema/MIR path: done for this
  pointer/global provenance subset;
- `lower-mir` or `mcc facts` prints a stable textual view of the same typed facts:
  done through `lower-mir` / `appendDumpOpt`;
- unit tests cover fact creation and invalidation, including absent-fact cases:
  done in `src/mir_tests.zig`.

### Phase 3: migrate one backend inference class

Status: complete only for LLVM consumption of the narrow
`PointerProvenanceFact` subset: direct pointer-like locals, noalias-wrapped
direct address expressions, direct pointer-local copies from live global-backed
locals including noalias-wrapped pointer-local copies, direct raw-many local
`.offset(0)` transfers including noalias-wrapped zero-offset transfers, direct
fixed local pointer-array elements including noalias-wrapped constant-index
element reads, and covered direct aggregate `field_path` rows including
struct-literal initializer, whole-aggregate reassignment, aggregate-read update,
casted noalias aggregate-read update, and nested aggregate member reassignment
facts. The Phase 4 C narrow
subset is also complete for scalar pointer deref load/store decisions. The
bounded Phase 5 direct-local cleanup is complete, but removal of duplicated
broader LLVM inference remains pending.

Move one backend from AST re-inference to typed fact consumption.

For the recommended pointer/global provenance slice, migrate LLVM first because
the current inference lives there. The backend should ask `SemanticFacts` whether
the pointer value/place is global-backed. If the fact exists and is live, emit
the current unordered atomic load/store behavior. If the fact is missing, stale,
or not expressible, keep the conservative existing behavior for that case.

Gate:

- tests that currently pin LLVM global-backed pointer provenance still pass:
  done for direct MIR-fact pointer locals, noalias-wrapped direct address
  expressions, pointer-array elements, and the existing broader LLVM fixture set;
- new negative tests prove missing/stale facts do not produce atomic provenance:
  done for local-storage facts, dynamic-index invalidation, call invalidation,
  noalias-wrapped direct address facts removed from the destination, a direct
  pointer-local copy whose destination fact is removed while the base fact
  remains live, and a direct raw-many zero-offset local whose destination fact is
  removed while the base fact remains live in `src/lower_llvm_tests.zig` /
  `tests/spec/data_race_semantics.mc`;
- code review can point to removed or bypassed AST inference in LLVM for the
  chosen subset: done for the direct pointer-like local initializer/assignment
  RHS forms covered by MIR direct address, noalias-wrapped direct address,
  direct pointer-local copy, and direct raw-many zero-offset facts through
  the MIR-only pointer-local helpers plus
  `applyMirPointerProvenanceForLocalInitializer`,
  `applyMirPointerProvenanceForAssignment`, and the existing
  `applyMirPointerProvenanceForIndexAssignment` consumer comments; duplicated
  broader LLVM inference is intentionally still present for unsupported shapes.

### Phase 4: migrate the second backend and add parity tests

Status: complete for the narrow C subset: direct pointer-like locals,
noalias-wrapped direct address expressions, direct pointer-local copies from
live global-backed locals, direct raw-many local
`.offset(0)` transfers, direct fixed local pointer-array elements including
elements written from compatible live direct pointer expressions, direct
aggregate pointer-field destination reads, constant-index direct aggregate
pointer-array element destination reads, and those same direct aggregate reads
after aggregate pointer-field and pointer-array element assignments from
compatible live direct pointer expressions, including raw-many zero-offset
expressions and noalias-wrapped direct addresses, struct-literal fields/elements
initialized or reassigned from those same expressions including nested aggregate
member reassignments, same-struct local aggregate initializer/assignment copies,
or nested direct aggregate member paths. C now
consumes MIR `PointerProvenanceFact` rows for pointer-like locals initialized or
assigned from visible address expressions, noalias-wrapped visible address expressions, compatible direct pointer-local
copies including noalias-wrapped pointer-local copies, or the supported raw-many zero-offset shape including noalias-wrapped zero-offset transfers, direct fixed pointer-array
literal elements and constant-index assignments including pointer-local copy
values, noalias-wrapped fixed pointer-array element reads, direct aggregate pointer fields and direct aggregate pointer-array
element reads including aggregate assignments from pointer-local copy values and
raw-many zero-offset expressions, noalias-wrapped direct addresses,
noalias-wrapped aggregate pointer-field and pointer-array element updates, copied
aggregate locals, noalias-wrapped aggregate pointer-field and pointer-array
element reads, noalias-wrapped aggregate-read updates, direct struct-literal field/elements initialized or reassigned
from those same expressions including nested aggregate member reassignments and
explicit nested local-storage member initializer/reassignment evidence for scalar
pointer fields and pointer-array elements, and
nested direct aggregate paths, and invalidation rows that
make those facts stale.
The pointer-like local initializer and assignment paths route those direct
shapes through `updatePointerProvenanceFromMir` and
`updatePointerProvenanceAssignmentFromMir`. Both backends clear the destination
first and repopulate it only from a matching MIR fact; unsupported or missing
facts remain unknown and use conservative lowering.
It also consumes explicit aggregate `field_path` facts for direct struct-literal
aggregate initializers, direct aggregate field assignments, direct aggregate
pointer-array element assignments, and direct same-struct aggregate copies.
Covered direct aggregate updates from `&global`, `&local`, compatible live
direct pointer expressions, raw-many zero-offset expressions, or noalias-wrapped
direct addresses now seed the aggregate pointer-field cache from MIR field
facts, including direct struct-literal initializers and whole/nested
struct-literal reassignments. If those field facts are
removed, local direct aggregate derefs fall back to the conservative
race-tolerant path instead of preserving a backend-only local proof.
Constant-index reads such as `let p = ptrs[0]` inherit the array-element fact
when MIR has proven that element live `global_storage` or `local_storage`; direct
aggregate reads such as `let p = holder.ptr`, `let p = holder.ptrs[0]`, and the
same reads through a direct copied aggregate local including nested copied field paths or nested direct aggregate
path inherit the destination fact emitted by MIR. For scalar pointee deref
loads/stores, live `global_storage`
facts route through `mc_race_load_*` /
`mc_race_store_*` using the pointer expression; `local_storage` is the positive
plain-deref proof, while `unknown`, nonzero/dynamic raw-many offsets,
call-produced raw-many bases, dynamic-index writes, call/reassignment
invalidation, absent facts, and non-constant indexes do not establish global
provenance and rely on the conservative race-tolerant scalar deref default where
that access class is supported. C emits
non-semantic `/* mir pointer_provenance consumed ... */` comments, including
`element=N` for consumed array facts, and `src/lower_c_tests.zig` checks that C
comment source points match the authoritative `lower-mir` fact row and LLVM
comment.

Teach the C backend to consume the same typed fact. The C backend may not need
the same atomic lowering choice for every case, but it must make its emission
decision from the same fact family or explicitly fail closed.

Gate:

- one source fixture is run through C and LLVM with artifact checks showing the
  same semantic fact id/source point drives both emissions: done for the
  direct-local scalar deref, noalias-wrapped direct pointer, direct fixed pointer-array, direct aggregate
  pointer-read, copied aggregate pointer-read, and nested aggregate pointer-read
  fixtures in
  `src/lower_c_tests.zig`, alongside the existing LLVM
  `; mir pointer_provenance consumed ...` checks;
- absent/stale fact fixtures prove both backends choose the conservative path:
  done in C for `local_storage`, `unknown` reassignment, dynamic-index write
  invalidation, call invalidation, raw-many nonzero/dynamic/unknown bases, and
  direct raw-many offset derefs, direct pointer reads and noalias-wrapped direct
  pointer reads with the `p` destination fact removed, pointer-local copy and
  direct raw-many zero destination reads with the `q` destination fact removed,
  fixed pointer-array element destination reads with the `p` destination fact
  removed, and aggregate pointer-field and aggregate
  pointer-array element destination reads with the `p` destination fact removed,
  plus direct aggregate `holder.ptr` / `holder.ptrs[0]` local-storage field facts
  removed from direct and copied aggregate locals and aggregate field facts
  removed after pointer-local-copy, raw-many zero, and noalias aggregate
  assignments; LLVM covers the same direct, aggregate destination, and aggregate
  `field_path` missing-fact shapes in the Phase 3/5 negative fixtures;
- `zig build test` covers the fact dump, C emission, LLVM emission, and
  differential/spec harness rows: done for this slice.

### Phase 5: retire duplicated AST inference

Status: complete for retirement of global pointer-local AST inference. C clears
the destination and repopulates it only through MIR. LLVM does the same for
every MIR-owned direct form; for non-MIR aggregate-alias shapes it retains only
an existing `local_storage` proof, never a global proof. Missing facts for the
direct address, copy, raw-many-zero, array-element, and aggregate-field subsets
remain unknown and lower conservatively. The aggregate-return summary collector
uses the same silent helper while emission preserves consumed-fact comments.
For fixed pointer-array element initializers/assignments from MIR-owned direct
pointer values, the shared LLVM element-cache helper now consumes the MIR
element fact before fallback; missing element facts clear LLVM's element cache
instead of reconstructing the destination from backend-local AST inference.
For direct aggregate pointer-array element assignments from MIR-owned pointer
locals, missing aggregate `field_path` facts likewise leave the aggregate
element provenance unknown instead of reconstructing it from backend-local
pointer-copy inference.
The C aggregate struct-literal helper now uses the same direct pointer-container
predicate for pointer fields and pointer-array elements, so pointer-local copies,
raw-many zero-offset values, fixed-array element reads, and aggregate pointer
reads are treated as MIR-owned there too. C regression coverage now includes
scalar pointer fields and pointer-array elements initialized or reassigned from
proven-local pointer-copy struct literals: removing the matching aggregate
`field_path` fact leaves the later deref on the conservative race-tolerant path
instead of preserving backend-local local-storage inference.
LLVM also consumes
explicit aggregate `field_path` facts for direct struct-literal aggregate
initializers, direct aggregate field assignments, direct aggregate pointer-array
element assignments, and direct same-struct aggregate copies. Covered direct
aggregate updates from `&global`, `&local`, compatible live direct pointer
expressions, raw-many zero-offset expressions, or noalias-wrapped direct
addresses now seed the aggregate pointer-field cache from MIR field facts,
including direct struct-literal initializers. If those field facts are removed,
local direct derefs fall back to the conservative race-tolerant path instead of
preserving a backend-only local proof. The
LLVM scoped-block emitter preserves MIR-backed pointer-local provenance updates
plus local pointer-array element and aggregate pointer-field provenance updates
for bindings that existed before the block, so pointer, fixed-array element, and
aggregate-field assignments inside an unsafe/contract block remain visible to
later scalar derefs after the block, while block-local facts are still discarded
with the lexical scope. The
aggregate-return summary collection now sets
`current_function` while collecting and route the same covered direct-local
forms through `updatePointerProvenanceFromMir`, which applies matching
MIR source-point facts through the mode-aware
`applyMirPointerProvenanceFactsAtSourceWithMode`.
MIR now unwraps noalias calls even when they sit below casts for the covered
constant-index fixed pointer-array element read and direct aggregate
pointer-field / pointer-array-element read shapes, and C/LLVM use matching
direct pointer-container classifiers for those casted noalias reads. Same-struct
whole-aggregate copies through `compiler.assume_noalias_unchecked(holder, n)`
now use the MIR aggregate `field_path` fact path as well: MIR treats the wrapper
as transparent in `directAggregateCopySourceName`, and C/LLVM consume the
matching subject source point for noalias-wrapped direct aggregate copies.
The same direct aggregate-copy path now also covers same-struct cast wrappers
around that noalias expression; LLVM treats the identical resolved aggregate type
cast as a no-op instead of failing or re-deriving copy provenance.
Nested aggregate member copies are path-aware too: MIR can copy live facts from
`src.inner.*` into `dst.inner.*` for
`dst.inner = compiler.assume_noalias_unchecked(src.inner, n)`, and backends
consume the resulting nested destination field facts. The same nested copy path
now covers same-struct cast wrappers such as
`dst.inner = compiler.assume_noalias_unchecked(src.inner, n) as Inner` for both
scalar pointer fields and fixed pointer-array elements.
Missing
or stale facts remain fail-closed: the MIR consumer clears/avoids proven
state for direct address, noalias-wrapped direct address, pointer-local copy,
raw-many zero-offset, constant-index fixed pointer-array element-read, direct
aggregate pointer-field-read, and direct aggregate pointer-array element-read
forms without a matching source-point fact, including copied and nested
aggregate variants. Tests remove those destination or aggregate `field_path`
facts from an in-memory MIR module, or assert backend consumed comments, to
prove covered cases lower from MIR rather than backend-only inference. Aggregate
pointer-alias writes, returned/external aggregate storage, and other unsupported
aggregate shapes still intentionally use the fallback provenance ladder until
equivalent typed facts exist. The old same-struct local aggregate cache-copy
fallback has been removed from LLVM's direct local aggregate path; covered copied
aggregate fields now arrive through MIR `field_path` facts or remain
conservative. C and LLVM aggregate-copy MIR gates now mirror MIR's same-struct
source check for local copies, noalias/cast/grouped wrappers, and nested member
copies, so they only treat aggregate-copy provenance as MIR-owned when the source
resolves to the destination struct type.

The LLVM fixed local pointer-array element cache now preserves
`local_storage` as well as `global_storage` from MIR element facts and direct
fallback tracking. That lets dynamic reads from direct fixed arrays, and direct
pointer-to-array aliases over all-local elements, seed the destination pointer
as proven local. The aggregate pointer-field cache now does the same for direct
aggregate pointer-array fields and local aggregate pointer aliases. Slice range
tracking now records direct and aggregate-backed all-local pointer-element ranges
as positive local proofs too, so constant-index and dynamic-index reads through
those tracked slices keep the final scalar deref plain. Broader alias-flow
local-storage distinctions outside these tracked direct slice shapes remain
conservative. Scalar and aggregate pointer parameter call-site summaries are
retired: without a typed MIR parameter fact, LLVM matches C by lowering their
scalar dereferences race-tolerantly. Aggregate member local provenance still
feeds the fallback ladder for local aggregate aliases and alias member writes to
local storage; mixed or unknown paths remain conservative. Aggregate-return summaries now keep
the provenance kind as well: returned `global_storage` fields can still seed
caller aggregate facts, but returned callee-local `local_storage` fields are not
converted into caller-local or false global proofs. LLVM's remaining
backend-local noalias wrapper checks now require the real builtin shape, so
malformed same-named calls and grouped call-callee impostors cannot seed
fallback parameter, return, direct provenance, or expression-type facts outside
the MIR-owned classifier. C uses the same strict shared noalias call-shape helper
for emission, type inference, and MIR/fallback provenance classifiers, so its
remaining noalias fallback paths do not carry separate argument-count/type-arg
truth. C's shared bitcast classifier now owns the complete one-type-argument,
one-value-argument shape as well, with malformed local bitcast initializers still
failing closed through the callee-only check. The
shared LLVM raw-many `.offset` classifier now also requires the real no-type-arg,
one-offset-argument shape before fallback typing or provenance can use the base
expression. MIR pointer provenance now uses the builder's compile-time `usize`
evaluator for the covered direct raw-many zero, fixed pointer-array element, and
aggregate pointer-array element shapes, so const-global forms such as
`p.offset(ZERO)` and `ptrs[FIRST_INDEX]` produce the same typed facts as literal
zero/index forms and are consumed by C/LLVM from MIR. The same evaluator now uses
MIR's reflection-aware compile-time folding path, so reflected constants such as
`REFLECT_ZERO_OFFSET = field_offset<ZeroField>(.value)` and
`REFLECT_INDEX = field_offset<ZeroField>(.value)` are also fact-owned by MIR when
used in `p.offset(REFLECT_ZERO_OFFSET)` or `ptrs[REFLECT_INDEX]`, rather than a
backend-local index classifier. Grouped and casted direct raw-many zero-offset
transfers such as `(p.offset(0))` and `p.offset(0) as [*]mut T` are also
MIR-owned for the covered direct-local shape; C and LLVM missing-destination
tests keep those forms conservative instead of rebuilding destination
provenance from backend-local wrapper handling. Direct well-shaped reflection calls inside those
same expressions are also provenance-preserving in MIR: `field_offset`,
`bit_offset`, `sizeof`/`size_of`, `alignof`, `repr_of`, and `field_type` no
longer invalidate live pointer facts merely because they use call syntax, so
`p.offset(field_offset<ZeroField>(.value))` and
`ptrs[field_offset<ZeroField>(.value)]` can emit destination facts directly.

The broader Phase 5 goal remains open. LLVM still intentionally uses
backend-local provenance mechanics for unsupported shapes: aggregate aliases
outside the covered direct local shapes, pointer-array aliases outside the
covered direct local shapes, raw-many zero offsets outside the direct-local
MIR-owned compile-time-zero shape, callback/exported/nontrivial returned
pointers, broader aggregate return summaries,
and other fallback paths. The narrow internal `return &global` pointer-return
form, straight-line local aliases of those proven returns, acyclic direct
forwarding through already summarized internal helpers, and well-formed
`assume_noalias_unchecked` wrappers around those forms are no longer in that
fallback: MIR records the call-result local's normal
`PointerProvenanceFact`, and both backends consume it; a missing caller fact
falls back to race-tolerant lowering.
C now keeps the fixed pointer-array destination-read boundary on the MIR-owned
side: covered direct pointer-container shapes pass through
`applyMirPointerProvenanceFactsAtSource` / the shared MIR admission helpers and
the missing-MIR-fact tests, and missing destination facts leave the destination
provenance unknown instead of using a backend-local fixed-array fallback.

The direct local aggregate-alias slice is a completed bounded Phase 5 migration
of the first listed fallback family. MIR emits the destination
`PointerProvenanceFact` for direct alias member and constant-index
pointer-array reads; C and LLVM consume it; and removing it makes both backends
use conservative scalar lowering. Alias writes retain alias-scoped facts while
invalidating the direct aggregate path, preserving the established conservative
boundary for direct reads after alias mutation.

C and LLVM also consume the existing MIR no-overflow `RangeFact` family for the
bounded unchecked arithmetic shape: `unchecked.add/sub/mul` must match a
source-point fact before either backend emits the plain arithmetic operation.
Both backends require the fact's target label to match the emission context;
retargeted prebuilt MIR facts fail closed instead of authorizing unchecked
arithmetic from source syntax alone. C and LLVM both cover the producer target
labels for return values, inferred locals, assignments, call arguments, binary
operands, array literal elements, and struct literal fields, and both backends
now retarget an aggregate-field fact in a negative gate.
This removes the backend-local trust in the AST unchecked call for that shape;
it does not migrate broader bounds/range facts. Representation facts are
first-class owned MIR rows and the lower-MIR artifact now covers cast value
identities across return checks, initializers, assignments, call arguments, and
aggregate fields/elements. Both production backends consume that family as an
admission gate: prebuilt MIR with a missing or stale fact fails before lowering.
This does not yet replace all backend representation-check emission mechanics.
Target-typed integer literal conversions are now also represented as owned MIR
`IntegerFact` rows and guarded by a C/LLVM admission validator. Missing or stale
prebuilt integer facts fail before lowering, so this bounded literal-defaulting
shape no longer relies only on backend AST target context.

Once both backends consume a broader typed fact family, remove the corresponding
backend AST inference helpers for that family. Keep only local emission mechanics
and source-location diagnostics.

Gate:

- the Phase 1 inventory checker enforces zero LLVM
  `updatePointerGlobalProvenance` definitions and calls, pins the C MIR-only
  helpers, and allows exactly one LLVM local-only proof classifier;
- the Phase 1 inventory checker anchors the C fixed pointer-array classifier so
  the MIR-owned pointer-container path remains visible;
- the Phase 1 inventory checker anchors oversized integer-literal syntax
  overflow handling before defaulting, including initializer, targetless, and
  binary-operand semantic gates plus exact reject-fixture counts;
- the production readiness bucket links to the migration commits and parity
  tests for each bounded cleanup slice;
- follow-up families are listed with owners/order: bounds/range facts, integer
  type/default facts, nullability/niche facts, representation-check facts.

### Phase status update: local_storage facts are load-bearing (spec I.13 flip)

The bare pointer-deref access class now implements the spec I.13 conservative
default on BOTH backends: `p.*` loads and `p.* = x` stores lower race-tolerantly
(LLVM `load/store atomic ... unordered`; C `mc_race_load_*`/`mc_race_store_*`,
or relaxed `__atomic_load_n`/`__atomic_store_n` for pointer-shaped pointees)
unless the pointer carries a POSITIVE locality proof — a live MIR
`local_storage` `PointerProvenanceFact` for the pointer local, or a syntactic
address-of a named local. `local_storage` facts are therefore load-bearing:
both emitters track the proven storage class per pointer local
(`pointer_local_provenance` in `src/lower_llvm.zig`,
`mir_pointer_local_provenance` in `src/lower_c_emitter.zig`), with liveness
symmetric to the global side (call/indirect-call/address-escape/dynamic-index
invalidations drop the proof back to unknown -> race-tolerant). MIR propagates
`local_storage` through direct pointer-local copies and constant-index reads of
local fixed pointer arrays. Wide scalars (u128/i128) with no sound
race-tolerant lowering fail emission closed on both backends. The
member/index/slice-element access classes are follow-up slices and still use
the proven-global ladders.

## Candidate first migration details

Pointer/global race provenance is the preferred first migration because it has
clear production value and a visible duplication problem.

Initial fact:

```zig
pub const PointerProvenanceFact = struct {
    provenance: enum { global_storage, local_storage, unknown },
    pointer_shape: PointerShape,
    subject: LocalId,
    storage: ?ObjectId,
    element_index: ?usize,
    source: SourcePoint,
    invalidation_reason: enum { none, reassignment, dynamic_index_write, call, indirect_call, address_escape },
    invalidation_policy: enum { invalidate_on_mutation_escape_or_call },
};
```

Initial positive fixture:

- local pointer initialized from a visible global;
- local pointer-array element initialized from a visible global;
- final scalar deref through the pointer/element.

Initial negative fixtures:

- reassignment to stack-backed storage clears the fact;
- dynamic-index assignment clears element/range facts;
- call between fact creation and use clears call-sensitive facts;
- escaped pointer/address produces `unknown`, not `global_storage`.

Backend gates:

- LLVM emits unordered atomics only when consuming `global_storage`;
- C emits or instruments according to the same `global_storage` fact, or rejects
  an unsupported subcase with source context;
- both artifact tests print the same fact id/source point for the same source
  operation.

These backend gates were the Phase 3/4 migration work and are complete for the
narrow fact families described above. Current production backends still use
legacy inference only for the explicitly listed unsupported fallback families;
the readiness closure matrix owns their migration or fail-closed disposition.

## Aggregate Returns (Partial Implementation)

This fact family is now implemented for a bounded domain. MIR owns direct
internal struct-literal helpers and straight-line local aggregate returns when
the returned local is initialized or whole-assigned from a direct literal, or
copied from another such tracked local. Returned structs may contain scalar
pointer fields, fixed arrays of scalar pointer elements, recursively nested
struct literals, fixed arrays of struct elements made from those shapes, and
nested fixed arrays of those struct elements. C and LLVM consume those facts.
Unsupported aggregate-return shapes stay
conservative; LLVM no longer has an AST pre-scan that can recreate returned
pointer-field facts outside MIR.

### Fact shape

The owned MIR module carries an `AggregateReturnSummaryFact` for every callee in
the migrated domain, and an `AggregateReturnPointerFact` for each returned
pointer field proven to have global storage:

```zig
pub const AggregateReturnPointerFact = struct {
    callee: []const u8,
    field_path: []const u8,
    provenance: enum { global_storage },
    pointer_shape: PointerShape,
    source: SourcePoint,
};
```

`AggregateReturnSummaryFact` is a coverage marker, not a provenance proof. If a
matching marker exists but the field fact is absent, the consumer must keep the
field unknown. That prevents a missing or stale MIR fact from silently using the
legacy LLVM AST inference. `local_storage` is deliberately excluded: callee-local
storage cannot become a caller-local proof through an aggregate return.

### Producer boundary

Current producer boundary:

- non-exported functions with a direct struct-literal return, or a final return
  of a local initialized or whole-assigned from a direct struct literal or a
  tracked copy of one;
- straight-line call-free declaration and whole-local assignment prefixes,
  including plain scoped blocks and transparent unsafe blocks whose contents
  reduce to the same supported straight-line aggregate updates, plus pure
  comptime blocks whose contents are compile-time expression/assert statements,
  and contract blocks whose contents reduce to the same supported aggregate
  updates; calls, member writes outside the supported aggregate-update forms,
  dereference writes, and other control flow are outside the producer domain,
  except for exhaustive bool/wildcard switches whose arms each independently
  reduce to an already-supported return value, or have direct returning arms
  plus fallthrough arms that contain only supported whole-local declarations,
  whole-local assignments, direct bounded nested aggregate member assignments,
  or direct constant-index fixed pointer-array element assignments before a
  checked trailing return, exhaustive all-fallthrough switch/`if` joins before
  the same kind of checked trailing return, bounded `if let` path splits whose
  reachable arms reduce to supported return/fallthrough or explicit-else return
  paths, including when nested inside supported switch arms, bounded
  sequential top-level exhaustive switch joins, or bounded nested
  exhaustive switch/`if` return paths whose expanded paths stay within the
  aggregate-return path cap;
- return structs with scalar pointer fields, fixed arrays of scalar pointer
  elements, recursively nested struct literals, fixed arrays of struct elements
  containing those shapes, and nested fixed arrays of those struct elements;
  dynamic-index reads and aggregate array nesting beyond those fixed domains
  remain outside the domain;
- pointer fields directly proven global by the existing MIR direct-address or
  direct internal pointer-return summary.

The remaining producer must operate on the checked module and derive its result
from the same direct pointer/aggregate facts used by ordinary MIR construction:

- direct struct-literal returns and returns of tracked local aggregates;
- straight-line local declaration and assignment prefixes, including plain
  scoped blocks and transparent unsafe blocks whose contents reduce to those
  supported prefix statements, plus pure comptime blocks whose contents are
  compile-time expression/assert statements, contract blocks whose contents
  reduce to supported aggregate updates, ordinary direct-literal call prefixes
  that have no exits, tracked-local direct zero-argument call/assert prefix
  statements, and transparent `while`/`for` prefixes
  whose condition or iterable and body have no calls/exits or pointer-bearing
  tracked aggregate mutation;
- exhaustive bool/wildcard switches with bounded return/fallthrough paths,
  including all-fallthrough switch/`if` joins before a supported trailing return,
  bounded `if let` return/fallthrough and explicit-else return path splits,
  including when nested inside supported switch arms,
  bounded sequential top-level switch joins, and bounded nested switch/`if`
  return paths;
- intersection of field facts across paths, retaining a field only when every
  path agrees on `global_storage` and pointer shape.

Every other shape remains outside the MIR-owned domain. That includes loop calls
or exits, non-stable pointer-bearing tracked aggregate mutation inside loops,
tracked-local argument-bearing/member/indirect prefix calls, direct or indirect
calls in nested aggregate-return control prefixes, exports, unions,
aggregate/array element nesting beyond the direct field model, fallthrough
dynamic-index writes, dereference writes or non-transparent nested control flow,
and any path with a missing or ambiguous field fact. Fallthrough dynamic-index
writes are an explicit fail-closed boundary: MIR emits no owned aggregate-return
summary, and C/LLVM keep returned fields unknown.
Callees with tracked-local argument-bearing/member/indirect prefix calls or
direct/indirect calls in nested aggregate-return control prefixes are also
explicit fail-closed boundaries: MIR emits no owned aggregate-return summary for
the callee, and both backends keep the returned field unknown.
Mixed return paths that do not agree on the same `global_storage` field are
covered by the summary-without-field gate: MIR may record the callee as
MIR-owned, but emits no field fact, and both backends keep the returned field
unknown.
Exported aggregate returns are not a provenance-producer obligation while
extern/export by-value struct returns are rejected by sema. MIR still has
negative coverage for the unchecked diagnostic fixture: exported aggregate
return callees receive no aggregate-return summary.
Callee-local storage returned inside an aggregate is not a producer obligation
for checked code because sema rejects the local-address escape. The diagnostic
fixture remains covered as a negative MIR case: unchecked MIR construction must
not emit a `global_storage` aggregate-return pointer fact for that field.
Unsupported aggregate array nesting beyond the named fixed pointer-array and
fixed struct-array domains is also an explicit fail-closed boundary: MIR emits
no owned aggregate-return summary for those diagnostic shapes, and both backends
keep the final scalar load conservative.
Dereference writes through aggregate aliases, such as `alias.*.ptr = &global`,
are explicit fail-closed boundaries too: MIR emits no summary for the callee, so
both backends keep the returned field unknown. Transparent nested exhaustive
`switch`/boolean-`if` statements are supported inside aggregate-return candidate
paths when their subjects and arms contain no calls/exits/control flow or
aggregate mutation. Transparent nested `if let` blocks are supported under the
same rule when the matched value and reachable bodies contain no calls/exits,
control flow, or aggregate mutation. Non-transparent nested control flow remains
an explicit fail-closed boundary: MIR emits no summary for that callee, and
C/LLVM keep the returned field conservative. `defer` prefixes before direct
struct-literal returns are transparent when their deferred expression has no
exits/control flow; the literal itself supplies the returned pointer-field
provenance even when the deferred cleanup is effectful. Tracked-local aggregate
returns also allow direct zero-argument deferred cleanup calls. Deferred calls
that mention the returned local, member calls, indirect calls, and other
argument-bearing cleanup shapes remain outside the producer. `while`/`for` loop prefixes, including nested loops inside
otherwise transparent aggregate-return switch arms, are transparent when their
bodies contain only provenance-transparent statements plus local
`break`/`continue`; tracked local aggregate returns additionally allow scalar
local assignments and scalar aggregate-field assignments inside those loops
when the assigned value cannot introduce pointer provenance. Loop calls, exits,
and pointer-bearing tracked aggregate mutation remain outside the producer.
Non-transparent nested CFG joins and above-cap path-count-overflow CFG joins before a final aggregate return remain
fail-closed: MIR emits no summary, and both backends keep returned fields
conservative. The current
aggregate-return path cap is a named 16-path bound, so 3x3 exhaustive switch
chains are inside the producer domain while 3x3x3 chains remain fail-closed.
Plain scoped-block prefixes, transparent unsafe-block
prefixes, and contract-block prefixes are supported only when their contents
reduce to the same straight-line aggregate-return prefix domain; block locals
are discarded at block exit, while supported updates to an outer returned
aggregate remain visible. No-overflow contract blocks may also contain scalar
local declaration/assignment/assert/expression prefixes whose only call-like
operations are `unchecked.add/sub/mul` with call-free operands, for both direct
literal returns and tracked local aggregate returns. Other contract calls remain
outside the producer. Pure comptime-block prefixes are supported only when their
contents are compile-time expression/assert statements;
runtime-affecting contents remain outside the producer. Call-free runtime
expression/assert prefixes are also transparent and do not mutate aggregate
facts for tracked-local returns. Ordinary call expressions before a direct
struct-literal return are transparent when they contain no `try`, `await`,
block expressions, or `unreachable`; the literal itself still supplies the
returned pointer-field provenance. Transparent `while`/`for` prefixes
are supported only when the condition or iterable has no calls/exits and the
loop body has no calls/exits or pointer-bearing tracked aggregate mutation;
local `break`/`continue`, scalar-local assignments, and scalar aggregate-field
assignments in the tracked-local producer are allowed.

### Aggregate-return unsupported CFG matrix

The aggregate-return CFG decision is explicit: the compiler keeps the bounded
16-path producer and treats the unsupported CFG classes below as accepted
fail-closed limitations until a later slice deliberately moves a row into the
supported producer domain. Each row has MIR evidence plus C/LLVM conservative
lowering evidence where backend consumption is relevant.

| Unsupported class | Required behavior | Evidence |
|---|---|---|
| Non-transparent nested call/control | Calls or exits inside nested aggregate-return control paths suppress the returned-field summary. | MIR `nested_call_control_holder` has no summary; C/LLVM `aggregate-return nested call control fails closed`. |
| Above-cap path expansion | CFG expansion beyond the named 16-path cap suppresses the summary instead of partially proving fields. | MIR `path_overflow_switch_holder` has no summary; C/LLVM `aggregate-return path overflow switches fail closed`. |
| Argument-bearing tracked-local calls/defer | Calls or deferred cleanups that can observe or mutate the tracked return local by argument/member/indirect path suppress the summary. | MIR `call_arg_before_return` and `local_defer_arg_prefix_holder` have no summary; C/LLVM returned fields stay conservative through the existing missing-summary path. |
| Non-stable pointer mutation in loop prefixes | Loop prefixes that can change a pointer-bearing field to a different storage target suppress the summary. | MIR `mixed_pointer_mutating_while_prefix_holder` has no summary; C/LLVM `aggregate-return mixed pointer-mutating while prefix fails closed`. |
| Ambiguous dynamic-index writes | Dynamic writes to pointer arrays are supported only when every element already has the same proven address; mixed dynamic writes suppress the summary. | MIR `trailing_mixed_dynamic_array_updated_holder` has no summary; same-address dynamic writes remain covered by `trailing_dynamic_array_updated_holder`. |
| Dereference writes through aliases | Writes such as `alias.*.ptr = &global` are not treated as transparent aggregate updates. | MIR `deref_updated_holder` has no summary; C/LLVM `aggregate-return dereference writes fail closed`. |
| Exported or escaping-local aggregate returns | Exported aggregate-return bodies and callee-local pointer fields are not provenance producers. | MIR `exported_holder` has no summary and `local_only_holder` has no `global_storage` field fact. |
| Unsupported aggregate nesting | Aggregate shapes outside the named scalar pointer, fixed pointer-array, nested struct, fixed struct-array, and nested fixed-array domains remain conservative. | C/LLVM `aggregate-return nested pointer arrays with missing leaf facts fail closed` and the aggregate-return producer matrix above. |

### Consumer and retirement rule

At `let dst: Holder = callee()`, C and LLVM apply matching return-field facts to
`dst` before backend-local aggregate inference. For a call shape covered by an
`AggregateReturnSummaryFact` but lacking a matching field fact, both backends
leave the returned field unknown and final scalar dereferences use conservative
race-tolerant lowering. LLVM keeps `aggregate_return_pointer_fields` only as a
MIR-populated cache; the AST collector is gone.

### Required evidence

1. Complete: `lower-mir` dumps owned summary and return-field facts with callee,
   field path, shape, provenance, and source point.
2. Complete for the direct-literal and straight-line-local boundary: MIR tests
   cover global, unknown, local initialization, whole-local reassignment,
   tracked whole-local copies, exhaustive branch joins, direct fixed
   pointer-array elements including nested fixed pointer arrays, nested
   aggregate field paths, fixed arrays of struct elements with pointer-bearing
   fields, and nested fixed arrays of those struct elements. Direct literal
   returns after ordinary call prefixes without exits, direct-literal
   effectful defer prefixes without exits, tracked-local direct zero-argument
   call/assert prefix statements, tracked-local direct zero-argument deferred
   cleanup calls, call-free expression/assert/defer prefixes, transparent
   `while`/`for` prefixes with local `break`/`continue`, and tracked-local
   aggregate returns with scalar-mutating loop locals, scalar aggregate-field
   loop mutations, or stable same-address pointer-field loop mutations are
   covered. Tracked-local argument-bearing/member/indirect call prefixes are
   explicitly excluded.
3. Complete for C and LLVM direct literals, straight-line locals, tracked copies,
   and exhaustive branches: normal consumption is visible in lowering, and
   removing only the return-field fact produces conservative lowering.
4. Complete for named unsupported producer shapes: contract-block prefixes with
   unsupported calls, non-stable pointer-bearing tracked aggregate mutations
   inside loop prefixes, loop calls/exits,
   tracked-local argument-bearing/member/indirect prefix calls,
   tracked-local argument-bearing/member/indirect deferred cleanup prefixes,
   non-transparent nested CFG joins, above-cap path-count-overflow CFG joins,
   exported aggregate returns, mixed paths, fallthrough
   dynamic-index writes, dereference writes, and aggregate array nesting beyond the fixed
   pointer-array/struct-array domains are covered as fail-closed rather than
   inferred.
5. Complete: the semantic-facts inventory rejects the retired LLVM
   aggregate-return AST collector, and LLVM loads aggregate-return pointer-field
   cache entries only from MIR facts.

## Non-goals

- Do not replace the parser, AST, HIR, MIR, and all backend type queries in one
  change.
- Do not make `mcc facts` or `lower-ir` the backend input format.
- Do not infer new semantics in backends while migrating; backends only consume
  recorded facts.
- Do not make optimized builds less conservative. When a proof is absent, keep
  checks and conservative lowering.
- Do not solve full alias analysis. Facts should be narrow, invalidated
  aggressively, and expanded only when evidence gates justify it.
- Do not promise a fully typed MIR verifier until operands, dominance,
  def-before-use, and value typing are actually verified.

## Acceptance criteria for the completed Phase 4 foundation

The narrow Phase 4 foundation is complete because all of these are true:

- a checked module or MIR carries typed facts produced from sema/MIR, not
  backend-local AST inference;
- at least one high-value fact family is consumed by both C and LLVM backends;
- parity tests prove both backends consume the same fact and fail closed when it
  is missing/stale;
- duplicated backend AST inference for that fact family has been retired;
- `mcc facts`, `lower-ir`, or `lower-mir` exposes a stable debug view of the
  typed facts for fixtures;
- `zig build test` gates the migrated family;
- remaining semantic fact families are tracked in the explicit closure matrix,
  rather than hidden inside the original vague architecture item.

These criteria do not close the broader typed semantic fact migration umbrella.
That umbrella closes only when its finite readiness matrix is complete or its
remaining rows are explicitly accepted as limitations.

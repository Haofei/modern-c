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
| MIR typed instruction metadata | `src/mir_model.zig` `ValueType`, `Instruction`, and optional `value_id` / `contract_region_id` carry typed operation metadata. `Function` owns `contract_regions`, `range_facts`, `pointer_provenance_facts`, `representation_facts`, and `elided_bounds`. | Function construction transfers owned slices in `FunctionBuilder.finish`. `Instruction.value_id` is populated by `addInstrWithValue`; the same builder path appends typed `RepresentationFact` rows for representation-sensitive typed loads, checks, uses, and aggregate field/element representation obligations with stable value identities such as `value_id=cast`. `PointerProvenanceFact.field_path` rows own their aggregate path strings, cover direct aggregate pointer-field and pointer-array element facts from initializers, direct assignments, same-struct initializer and assignment copies including nested field and pointer-array element paths, whole-aggregate struct-literal reassignments, and nested aggregate member struct-literal reassignments, and are freed with the MIR module. The MIR representation verifier uses the instruction `value_id` identities to match checks to uses. | `mcc lower-mir` dispatches through `src/main.zig` and prints `mir.appendDumpOpt`. `appendDumpOpt` prints function summaries including `representation_facts=N`, instructions including `value_id=...`, trap edges, owned `mir representation_fact` rows for typed loads/checks/uses including cast identities across return checks, initializers, assignments, call arguments, aggregate fields, and aggregate elements, range facts, pointer-provenance facts including optional `field=...`, and explicit elided-bounds fact rows. MIR verification facts also print representation rows from `Function.representation_facts`. | C and LLVM consume the owned representation fact slice at backend entry: `validateRepresentationFactsForLowering` rejects prebuilt MIR with a missing or stale fact instead of accepting AST-only representation truth. Broader backend semantic decisions remain limited to the fact families below plus backend-local fallback inference. |
| MIR no-overflow range facts | `src/mir_model.zig:201` `RangeFact` records `region_id`, `target`, `op`, operands, result type, and source point. Producers are `FunctionBuilder.addRangeFactForUncheckedCall` (`src/mir.zig:2491-2507`) and `addAggregateRangeFactForUncheckedExpr` (`src/mir.zig:2509-2530`) inside active `#[unsafe_contract(no_overflow)]` regions. | These facts are appended for unchecked no-overflow calls in contract regions. They are not the same as transient optimizer `proven_facts`; they persist in `Function.range_facts` until the MIR module is freed. | `appendDumpOpt` prints `mir range_fact ... assumption=no_overflow recorded=true` at `src/mir.zig:359-364`; MIR verification facts also scan `function.range_facts` at `src/mir.zig:534`. LLVM emission prints non-semantic `; mir range_fact consumed ... assumption=no_overflow` comments when it consumes a fact; C emission prints `/* MC_MIR_RANGE no_overflow ... */` comments from its MIR-gated unchecked paths. The inventory checker anchors the owned `RangeFact` model, the dump row, and exact C/LLVM no-overflow range consumer call counts. | The C backend wires `has_mir_no_overflow_range_fact` through `arithContext` (`src/lower_c_emitter.zig:1591-1610`) and matches facts in `hasMirNoOverflowRangeFact` (`src/lower_c_emitter.zig:4545-4557`); its generic builtin dispatcher now rejects unchecked no-overflow calls instead of emitting plain arithmetic without a matching fact. C and LLVM both have target-label coverage for return values, inferred locals, assignments, call arguments, binary operands, array literal elements, and struct literal fields. LLVM requires `requireMirNoOverflowRangeFact` for `unchecked.add/sub/mul` and matches target identity through `current_mir_range_target` for those contexts. Removing a matching `RangeFact`, or retargeting it to a different target label in a prebuilt MIR module, makes both C and LLVM fail closed instead of trusting the AST call, including non-`value` inferred-local, assignment, call-argument, binary-operand, aggregate-element, and aggregate-field targets; absence coverage now explicitly spans those non-`value` contexts in both backends. Broader range/bounds facts are still not a complete typed fact family. |
| MIR bounds facts | `src/mir_model.zig` `BoundsFact` records index and slice checks that remain after MIR optimization; `FunctionBuilder.buildExpr` appends them with the same source point as the check. | Optimized proofs remain represented by `elided_bounds`; every non-elided array/slice check requires a `BoundsFact` instead of being accepted from AST shape alone. | `mcc lower-mir` prints the function `bounds_facts=N` count and stable `mir bounds_fact fn=... kind=index|slice recorded=true line=... column=...` rows. The inventory checker anchors the owned `BoundsFact` model, dump row, and C/LLVM `requireMirBoundsFact` consumers with exact call counts. | C and LLVM call `requireMirBoundsFact` before emitting non-elided array-index or slice bounds checks. Removing the matching fact from prebuilt MIR produces `UnsupportedCEmission` / `UnsupportedLlvmEmission`; direct missing-fact tests cover both backends. |
| MIR check-elision source points | `src/mir_model.zig:212` `SourcePoint` and `Function.elided_bounds` (`src/mir_model.zig:234-239`) record checks proven dead by optimized MIR. Producers append source points for constant in-bounds index (`src/mir.zig:2263-2278`), constant in-bounds slice (`src/mir.zig:2293-2305`), and division/modulo elision (`src/mir.zig:2437`). | Transient `ProvenFact` guard/assert facts are recorded by `recordTrueCondFacts` (`src/mir.zig:2704-2730`), restricted by `factIdentAllowed` (`src/mir.zig:2743-2750`), and invalidated by new bindings, assignment, loops, and address-of (`src/mir.zig:1176-1178`, `src/mir.zig:1212-1214`, `src/mir.zig:1972-1982`, `src/mir.zig:2046-2049`, `src/mir.zig:2690-2697`). | `lower-mir --optimize` exposes absence of the original `cmp_bounds`/trap edge, records optimized instruction detail such as `const_in_bounds`, includes an `elided_bounds=N` summary count, and prints explicit `mir elided_bounds_fact ... recorded=true` rows from `Function.elided_bounds`. | Both backends consume the same MIR list and fail closed when absent. C uses `mirCheckElided` for array indexing and slice guards (`src/lower_c_emitter.zig:3574-3586`, `src/lower_c_emitter.zig:4272-4280`, `src/lower_c_emitter.zig:4564-4573`) and passes the hook into arithmetic lowering (`src/lower_c_arith.zig:58-59`, `src/lower_c_arith.zig:391`, `src/lower_c_arith.zig:467`, `src/lower_c_arith.zig:507`). LLVM uses function-filtered `mirCheckElided` for array indexing, slice guards, and div/rem checks (`src/lower_llvm.zig:6607-6616`, plus call sites), matching C's function-filtered source-point lookup. |
| LLVM backend-local pointer/global race provenance | `LlvmEmitter` owns backend-local maps for local function/aggregate/pointer-array aliases, aggregate field facts, array element facts, slice facts, and aggregate-return summaries (`src/lower_llvm.zig`). It collects only aggregate-return facts in `collectAggregateReturnPointerFieldSummaries`; C admits pointer-local provenance through MIR-only helpers, while LLVM uses `updatePointerProvenanceFromMirOrLocalProof` for its registered local-only alias proof. | This remains the largest duplicated inference class. The Phase 5 cleanup retires LLVM's global pointer-local AST fallback: covered direct forms without a MIR fact remain unknown, while non-MIR aggregate-alias shapes may preserve only an existing `local_storage` proof. LLVM also has no backend-local scalar pointer-return summary: supported direct, forwarded, noalias-wrapped, branched, and local-function-alias return flows are caller MIR facts. | `lower-mir` prints authoritative `mir pointer_provenance_fact ...` rows. C and LLVM tests cover fact consumption and missing-fact conservative lowering for direct locals and aggregate field paths. | LLVM defaults bare scalar pointer dereferences to unordered atomics unless a live `local_storage` fact or syntactic `&local` proves locality. Scalar and aggregate pointer parameter call-site summaries, scalar pointer-return summaries, and global AST fallback proofs are retired; only the registered local aggregate-alias proof remains outside MIR. Direct local aggregate and aggregate-return provenance remain separate. |
| C backend global/race lowering helpers | `src/lower_c_global.zig` routes direct global scalar, array, and field accesses through race helpers or relaxed C atomics. Examples include `appendGlobalLoadExpr` (`src/lower_c_global.zig:142-150`), `appendGlobalStorePrefix` (`src/lower_c_global.zig:153-162`), `globalAssignmentTarget` (`src/lower_c_global.zig:176-183`), and array/member global access helpers (`src/lower_c_global.zig:219-242`, `src/lower_c_global.zig:270-315`). The Phase 4 C slice adds `src/lower_c_emitter.zig` MIR consumers such as `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, `applyMirPointerProvenanceForIndexAssignment`, `applyMirAggregatePointerFieldFactsAtSource`, `applyMirAggregatePointerFieldFactsForSubjectAtSource`, `applyMirPointerProvenanceInvalidationsAtCall`, and `derefAccessLowering`. | Direct global helper logic still keys from AST/global type information and `GlobalInfo`. For direct pointer-like locals, direct pointer-local copies from live global-backed locals, direct raw-many local `.offset(0)` transfers, direct fixed local pointer-array elements, direct aggregate pointer-field destination reads, constant-index direct aggregate pointer-array element destination reads, and direct aggregate `field_path` rows for covered direct struct-literal initializers, whole-aggregate and nested aggregate member struct-literal reassignments, field assignments, pointer-array element assignments, and same-struct aggregate copies, C consumes `Function.pointer_provenance_facts` at local initializer, assignment, index-assignment, and call-invalidation source points. Direct fixed pointer-array element destination reads now stay MIR-owned: if the destination fact is absent, C leaves the destination provenance unknown instead of reconstructing it from backend-local array-element state. Bare scalar pointee deref loads/stores default to `mc_race_load_*` / `mc_race_store_*` (or relaxed `__atomic_*_n` for pointer-shaped pointees); only a live `local_storage` fact or a syntactic `&local` keeps the plain path, and `unknown`/invalidated facts fall back to the race-tolerant default. The raw-many offset deref temp path delegates scalar loads through `emitRaceLoadTempFromPointerTemp`; pointer-member scalar fields, nested pointer-member scalar chains, slice scalar indexes, unproven pointer-to-array scalar indexes, scalar fields reached through pointer-backed indexed aggregate storage, and nested scalar member chains rooted in pointer-backed indexed aggregate storage also use race-tolerant load/store paths. Bare struct/fixed-array aggregate value copies through unproven pointer derefs, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, indexed and nested indexed aggregate fields, aggregate slice storage, and unproven pointer-to-array aggregate storage now lower recursively to race-tolerant scalar/pointer leaves where every leaf is supported; unsupported union-like leaves still fail closed. | `src/lower_c_inspect.zig:455-492` prints `lower ordinary_access`, `lower race_backend`, `lower race_semantics`, `lower c_ub`, and `lower racing_load_semantics` rows for direct global inspection. C emission also prints non-semantic `/* mir pointer_provenance consumed ... */` comments for the narrow facts it consumes, including `field=...` and `element=N` for aggregate field and array element rows. | C consumes MIR `elided_bounds`, `range_facts`, and now the narrow direct pointer-like local/direct-copy/direct raw-many zero-offset/direct fixed pointer-array element/direct aggregate pointer-read/direct aggregate `field_path` subset of `PointerProvenanceFact` for scalar deref load/store decisions. Conservative scalar lowering also covers call/member/index pointers, direct raw-many offset deref temps, pointer-member scalar fields, nested pointer-member scalar chains, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, slice scalar indexes, unproven pointer-to-array scalar indexes, indexed aggregate scalar fields, nested indexed aggregate scalar member chains, recursive indexed and nested indexed aggregate field value copies, recursive aggregate whole-element value copies, and recursive struct/fixed-array aggregate pointer derefs when locality is not proven; broader race/global helper decisions remain outside typed pointer-provenance facts. |

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
form, acyclic direct forwarding through already summarized internal helpers,
and well-formed `assume_noalias_unchecked` wrappers around either form are no
longer in that fallback: MIR records the call-result local's normal
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

This fact family is now implemented only for a narrow initial domain. MIR owns
direct internal struct-literal helpers and straight-line local aggregate returns
when the returned local is initialized or whole-assigned from a direct literal,
or copied from another such tracked local. Returned structs may contain scalar
pointer fields, fixed arrays of scalar pointer elements, and recursively nested
struct literals made from those shapes. C and LLVM consume those facts. All
other aggregate-return shapes
still use `aggregate_return_pointer_fields`, the LLVM-local AST pre-scan; that
collector has **not** been retired.

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
- straight-line declaration and assignment prefixes only; calls, member writes,
  dereference writes, and other control flow are outside the
  producer domain, except for exhaustive bool/wildcard switches whose arms each
  independently reduce to an already-supported return value, or have direct
  returning arms plus empty fallthrough arms to a checked trailing return;
- return structs with scalar pointer fields or fixed arrays of scalar pointer
  elements, including recursively nested struct literals; arrays whose elements
  are aggregates or arrays, slices, and other pointer-bearing field shapes
  remain outside the domain;
- pointer fields directly proven global by the existing MIR direct-address or
  direct internal pointer-return summary.

The remaining producer must operate on the checked module and derive its result
from the same direct pointer/aggregate facts used by ordinary MIR construction:

- direct struct-literal returns and returns of tracked local aggregates;
- straight-line local declaration and assignment prefixes;
- exhaustive bool/wildcard switches with bounded return/fallthrough paths;
- intersection of field facts across paths, retaining a field only when every
  path agrees on `global_storage` and pointer shape.

Every other shape remains outside the MIR-owned domain. That includes loops,
indirect calls, exports, unions, aggregate/array element nesting beyond the
direct field model, non-empty fallthrough branch effects, and any path with a
missing or ambiguous field fact.

### Consumer and retirement rule

At `let dst: Holder = callee()`, C and LLVM apply matching return-field facts to
`dst` before backend-local aggregate inference. For a call shape covered by an
`AggregateReturnSummaryFact` but lacking a matching field fact, both backends
leave the returned field unknown and final scalar dereferences use conservative
race-tolerant lowering. LLVM may delete `aggregate_return_pointer_fields` only
after its supported source domain is represented by this producer and the
missing-fact gate covers every migrated shape.

### Required evidence

1. Complete: `lower-mir` dumps owned summary and return-field facts with callee,
   field path, shape, provenance, and source point.
2. Complete for the direct-literal and straight-line-local boundary: MIR tests
   cover global, unknown, local initialization, whole-local reassignment,
   tracked whole-local copies, exhaustive branch joins, direct fixed
   pointer-array elements, and nested aggregate field paths.
3. Complete for C and LLVM direct literals, straight-line locals, tracked copies,
   and exhaustive branches: normal consumption is visible in lowering, and
   removing only the return-field fact produces conservative lowering.
4. Remaining: non-empty fallthrough branch effects, mixed, exported,
   aggregate/array element nesting beyond the direct field model, and
   local-storage return cases.
5. Remaining: the semantic-facts inventory must reject the LLVM collector once
   no accepted legacy domain remains; then run `zig build test` and both backend
   suites after collector retirement.

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

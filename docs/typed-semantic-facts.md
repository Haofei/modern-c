# Typed semantic facts / typed MIR design

This is the design slice for the compiler-production-readiness Phase 4 bucket
"Typed fact table: sema resolves once, backends consume". It turns the current
architecture note into implementable phases with invariants and evidence gates.

## Current state

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
| MIR typed instruction metadata | `src/mir_model.zig` `ValueType`, `Instruction`, and optional `value_id` / `contract_region_id` carry typed operation metadata. `Function` owns `contract_regions`, `range_facts`, `pointer_provenance_facts`, `representation_facts`, and `elided_bounds`. | Function construction transfers owned slices in `FunctionBuilder.finish`. `Instruction.value_id` is populated by `addInstrWithValue`; the same builder path appends typed `RepresentationFact` rows for representation-sensitive typed loads, checks, uses, and aggregate field/element representation obligations with stable value identities such as `value_id=cast`. `PointerProvenanceFact.field_path` rows own their aggregate path strings, cover direct aggregate pointer-field and pointer-array element facts from initializers, direct assignments, same-struct initializer and assignment copies including nested field and pointer-array element paths, whole-aggregate struct-literal reassignments, and nested aggregate member struct-literal reassignments, and are freed with the MIR module. The MIR representation verifier uses the instruction `value_id` identities to match checks to uses. | `mcc lower-mir` dispatches through `src/main.zig` and prints `mir.appendDumpOpt`. `appendDumpOpt` prints function summaries including `representation_facts=N`, instructions including `value_id=...`, trap edges, owned `mir representation_fact` rows for typed loads/checks/uses including cast identities across return checks, initializers, assignments, call arguments, aggregate fields, and aggregate elements, range facts, pointer-provenance facts including optional `field=...`, and explicit elided-bounds fact rows. MIR verification facts also print representation rows from `Function.representation_facts`. | Backends receive a built MIR module. The typed instruction stream and owned representation fact slice are consumed by MIR verification/artifact gates today; backend semantic decisions are currently limited to the fact families below plus backend-local AST inference. |
| MIR no-overflow range facts | `src/mir_model.zig:201` `RangeFact` records `region_id`, `target`, `op`, operands, result type, and source point. Producers are `FunctionBuilder.addRangeFactForUncheckedCall` (`src/mir.zig:2491-2507`) and `addAggregateRangeFactForUncheckedExpr` (`src/mir.zig:2509-2530`) inside active `#[unsafe_contract(no_overflow)]` regions. | These facts are appended for unchecked no-overflow calls in contract regions. They are not the same as transient optimizer `proven_facts`; they persist in `Function.range_facts` until the MIR module is freed. | `appendDumpOpt` prints `mir range_fact ... assumption=no_overflow recorded=true` at `src/mir.zig:359-364`; MIR verification facts also scan `function.range_facts` at `src/mir.zig:534`. LLVM emission prints non-semantic `; mir range_fact consumed ... assumption=no_overflow` comments when it consumes a fact; C emission prints `/* MC_MIR_RANGE no_overflow ... */` comments from its MIR-gated unchecked paths. | The C backend wires `has_mir_no_overflow_range_fact` through `arithContext` (`src/lower_c_emitter.zig:1591-1610`) and matches facts in `hasMirNoOverflowRangeFact` (`src/lower_c_emitter.zig:4545-4557`); its generic builtin dispatcher now rejects unchecked no-overflow calls instead of emitting plain arithmetic without a matching fact. C and LLVM both have target-label coverage for return values, inferred locals, assignments, call arguments, binary operands, array literal elements, and struct literal fields. LLVM requires `requireMirNoOverflowRangeFact` for `unchecked.add/sub/mul` and matches target identity through `current_mir_range_target` for those contexts. Removing a matching `RangeFact`, or retargeting it to a different target label in a prebuilt MIR module, makes both C and LLVM fail closed instead of trusting the AST call, including non-`value` inferred-local, assignment, call-argument, binary-operand, aggregate-element, and aggregate-field targets; absence coverage now explicitly spans those non-`value` contexts in both backends. Broader range/bounds facts are still not a complete typed fact family. |
| MIR check-elision source points | `src/mir_model.zig:212` `SourcePoint` and `Function.elided_bounds` (`src/mir_model.zig:234-239`) record checks proven dead by optimized MIR. Producers append source points for constant in-bounds index (`src/mir.zig:2263-2278`), constant in-bounds slice (`src/mir.zig:2293-2305`), and division/modulo elision (`src/mir.zig:2437`). | Transient `ProvenFact` guard/assert facts are recorded by `recordTrueCondFacts` (`src/mir.zig:2704-2730`), restricted by `factIdentAllowed` (`src/mir.zig:2743-2750`), and invalidated by new bindings, assignment, loops, and address-of (`src/mir.zig:1176-1178`, `src/mir.zig:1212-1214`, `src/mir.zig:1972-1982`, `src/mir.zig:2046-2049`, `src/mir.zig:2690-2697`). | `lower-mir --optimize` exposes absence of the original `cmp_bounds`/trap edge, records optimized instruction detail such as `const_in_bounds`, includes an `elided_bounds=N` summary count, and prints explicit `mir elided_bounds_fact ... recorded=true` rows from `Function.elided_bounds`. | Both backends consume the same MIR list and fail closed when absent. C uses `mirCheckElided` for array indexing and slice guards (`src/lower_c_emitter.zig:3574-3586`, `src/lower_c_emitter.zig:4272-4280`, `src/lower_c_emitter.zig:4564-4573`) and passes the hook into arithmetic lowering (`src/lower_c_arith.zig:58-59`, `src/lower_c_arith.zig:391`, `src/lower_c_arith.zig:467`, `src/lower_c_arith.zig:507`). LLVM uses function-filtered `mirCheckElided` for array indexing, slice guards, and div/rem checks (`src/lower_llvm.zig:6607-6616`, plus call sites), matching C's function-filtered source-point lookup. |
| LLVM backend-local pointer/global race provenance | `LlvmEmitter` owns backend-local maps for `pointer_local_provenance`, local function/aggregate/pointer-array aliases, aggregate field facts, array element facts, slice facts, return summaries, and parameter summaries (`src/lower_llvm.zig`). It collects summary facts in `collectGlobalPointerProvenanceSummaries` and updates local facts through functions such as `updatePointerGlobalProvenance`, `updatePointerProvenanceFromMirOrFallback`, `updateAggregatePointerAliasProvenance`, and array/field/slice helpers. | This is the largest duplicated inference class. It resets or clears facts on loop/switch boundaries and asm, on local declaration/assignment tracking, on aggregate pointer deref assignment, and on array/slice backing writes; scoped blocks now preserve pointer-local provenance changes for outer bindings while still discarding block-local facts. The Phase 3 LLVM slice routes direct pointer-like locals, direct pointer-local copies from live global-backed locals, direct raw-many local `.offset(0)` transfers, direct fixed local pointer-array elements, direct destination pointers read from constant-index fixed local pointer-array elements, direct destination pointers read from direct aggregate pointer fields, and direct destination pointers read from constant-index direct aggregate pointer-array fields through MIR fact helpers such as `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, and `applyMirPointerProvenanceForIndexAssignment`; the bounded Phase 5 cleanup bypasses `updatePointerGlobalProvenance` for direct pointer-like local initializer/assignment RHS forms already covered by MIR direct address, pointer-local copy, raw-many zero-offset, constant-index fixed pointer-array element-read, direct aggregate pointer-field-read, or direct aggregate pointer-array element-read facts in both the emission path and the aggregate summary collector paths that route through `applyMirPointerProvenanceFactsAtSourceSilent`. Direct aggregate `field_path` rows from struct-literal initializers, whole-aggregate and nested aggregate member struct-literal reassignments, direct field updates, and same-struct copies including nested field and pointer-array element paths are consumed where covered; direct struct-literal initializer and reassignment pointer fields and pointer-array element values that are already MIR-owned pointer container expressions now leave LLVM aggregate field provenance unknown when the field fact is missing instead of rebuilding local/global provenance from backend-local pointer-copy inference. Broader cases still use backend-local inference. | `lower-mir` prints the authoritative `mir pointer_provenance_fact ...` rows for the narrow subset. LLVM tests also assert non-semantic `; mir pointer_provenance consumed ...` comments at direct consumption sites, and `src/lower_llvm_tests.zig` covers direct pointer locals, direct pointer-local copies, direct raw-many zero-offset locals, direct aggregate pointer-field reads, direct aggregate pointer-array element reads, struct-literal initializer and whole/nested reassignment aggregate field facts, indexed and nested indexed aggregate field value copies, and recursive struct/fixed-array aggregate pointer deref value copies with field-wise unordered atomic lowering; selected MIR facts removed from covered direct-local and nested field-path cases prove those cases lower conservatively without the comment/source point. | LLVM consumes MIR `PointerProvenanceFact` rows for the narrow direct-local/direct-copy/direct-raw-many-zero/direct-array/direct-field-read/direct-aggregate-array-element subset; at bare scalar-deref sites `derefUsesRaceTolerantLowering` now defaults to unordered atomics unless a live `local_storage` fact (or syntactic `&local`) proves locality. Struct and fixed-array aggregate pointer deref loads/stores, ambiguous aggregate whole-element indexes, ambiguous indexed and nested indexed aggregate field value copies, and ambiguous pointer-member aggregate value copies are split recursively into unordered atomic leaf accesses when every leaf has ordinary scalar/pointer race-tolerant lowering; proven-local aggregate derefs, proven-local nested pointer-member aggregate copies, and fixed local array field loads stay plain, and union-like aggregate leaves still fail closed. For direct pointer-like local initializer/assignment from visible address expressions, live global-backed direct local copies, direct raw-many local `.offset(0)`, constant-index fixed local pointer-array element reads, direct aggregate pointer-field reads, or direct aggregate pointer-array element reads, LLVM no longer re-infers global storage through `updatePointerGlobalProvenance` in the emission path or in aggregate-return/aggregate-parameter summary collection; the broader LLVM provenance family still needs migration/cleanup. |
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
  `mirPointerProvenanceCoversDirectLocalUpdate` plus
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
shapes through `updatePointerProvenanceFromMirOrFallback` and
`updatePointerProvenanceAssignmentFromMirOrFallback`, using
`mirPointerProvenanceCoversDirectLocalUpdate` to keep MIR-owned direct updates
out of the older inline fallback logic while preserving the conservative
fallback for unsupported shapes.
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

Status: complete only for bounded LLVM direct-local cleanup slices. LLVM no
longer calls `updatePointerGlobalProvenance` for direct pointer-like local
initializer/assignment RHS forms that MIR `PointerProvenanceFact` owns through
direct address provenance, noalias-wrapped direct address provenance, direct pointer-local copy provenance, the narrow
direct raw-many local `.offset(0)` transfer for both global and local storage, a constant-index fixed local
pointer-array element read, a direct aggregate pointer-field read, or a
constant-index direct aggregate pointer-array element read, including those
direct aggregate reads through same-struct copied aggregate locals or nested
direct aggregate member paths, in the direct emission path. The direct emission
path and aggregate-return/aggregate-parameter summary collectors now use the
same `updatePointerProvenanceFromMirOrFallback` decision helper for pointer-like
local initializers, and direct assignment emission uses the matching
`updatePointerProvenanceAssignmentFromMirOrFallback` helper so reassignment
source-point comments remain visible while summary collection stays silent.
The direct-local MIR consumption branches and
`mirPointerProvenanceCoversDirectLocalUpdate` wrappers also share the
`directMirPointerContainerValueExpr` classifier instead of spelling out the
covered direct pointer-container shape list inline.
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
aggregate-return and aggregate-parameter summary collectors now set
`current_function` while collecting and route the same covered direct-local
forms through `updatePointerProvenanceFromMirOrFallback`, which applies matching
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
conservative. LLVM also now keeps scalar pointer parameters plain when every
visible internal direct or local function-pointer-alias call passes direct local
storage, while mixed/escaped/uncalled/exported parameter shapes remain
conservative. Aggregate member local provenance now feeds the same fallback
ladder for local aggregate aliases, alias member writes to local storage, and
local-only aggregate pointer parameter summaries: intersected `local_storage`
fields seed destination pointer locals as proven local, while mixed/global or
unknown summary paths remain conservative. Aggregate-return summaries now keep
the provenance kind as well: returned `global_storage` fields can still seed
caller aggregate facts, but returned callee-local `local_storage` fields are not
converted into caller-local or false global proofs. LLVM's remaining
backend-local noalias wrapper checks now require the real builtin shape, so
malformed same-named calls cannot seed fallback parameter, return, direct
provenance, or expression-type facts outside the MIR-owned classifier. The
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
backend-local index classifier. Direct well-shaped reflection calls inside those
same expressions are also provenance-preserving in MIR: `field_offset`,
`bit_offset`, `sizeof`/`size_of`, `alignof`, `repr_of`, and `field_type` no
longer invalidate live pointer facts merely because they use call syntax, so
`p.offset(field_offset<ZeroField>(.value))` and
`ptrs[field_offset<ZeroField>(.value)]` can emit destination facts directly.

The broader Phase 5 goal remains open. LLVM still intentionally uses
backend-local provenance mechanics for unsupported shapes: aggregate aliases
outside the covered direct local shapes, pointer-array aliases outside the
covered direct local shapes, raw-many zero offsets outside the direct-local
MIR-owned compile-time-zero shape, returned pointers, broader parameter summary shapes, broader
aggregate return summaries, and other fallback paths.
C now keeps the fixed pointer-array destination-read boundary on the MIR-owned
side: covered direct pointer-container shapes pass through
`applyMirPointerProvenanceFactsAtSource` / the shared MIR-or-fallback helpers and
the missing-MIR-fact tests, and missing destination facts leave the destination
provenance unknown instead of using a backend-local fixed-array fallback.

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
identities across return checks, initializers, assignments, call arguments,
aggregate fields, and aggregate elements, but production backend decisions still
do not consume that representation fact family.

Once both backends consume a broader typed fact family, remove the corresponding
backend AST inference helpers for that family. Keep only local emission mechanics
and source-location diagnostics.

Gate:

- for the bounded direct-local cleanup, `rg` still finds
  `updatePointerGlobalProvenance` only as a fallback helper, while the direct
  initializer/assignment emission path and the covered aggregate summary
  collector paths gate calls through `mirPointerProvenanceCoversDirectLocalUpdate`;
- the Phase 1 inventory checker anchors the C fixed pointer-array classifier so
  the MIR-owned pointer-container path remains visible;
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

These backend gates remain Phase 3/4 work. Current production backends still use
their existing inference paths and must fail closed when this typed fact family is
absent or not yet consumed.

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

## Acceptance criteria for closing the bucket

The Phase 4 typed fact table bucket can close when all of these are true:

- a checked module or MIR carries typed facts produced from sema/MIR, not
  backend-local AST inference;
- at least one high-value fact family is consumed by both C and LLVM backends;
- parity tests prove both backends consume the same fact and fail closed when it
  is missing/stale;
- duplicated backend AST inference for that fact family has been retired;
- `mcc facts`, `lower-ir`, or `lower-mir` exposes a stable debug view of the
  typed facts for fixtures;
- `zig build test` gates the migrated family;
- remaining semantic fact families are tracked as follow-up buckets rather than
  hidden inside the original vague architecture item.

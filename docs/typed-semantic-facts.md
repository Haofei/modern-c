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
  metadata, `RangeFact`, and `elided_bounds`.
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
- `src/mir_model.zig`: `RangeFact`, `SourcePoint`, `Instruction.value_id`;
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
| MIR typed instruction metadata | `src/mir_model.zig:57` `ValueType`, `src/mir_model.zig:114` `Instruction`, and `src/mir_model.zig:118-119` optional `value_id` / `contract_region_id` carry typed operation metadata. `Function` owns `contract_regions`, `range_facts`, and `elided_bounds` at `src/mir_model.zig:225-239`. | Function construction transfers owned slices in `FunctionBuilder.finish` (`src/mir.zig:940-1004`). `Instruction.value_id` is populated by `addInstrWithValue` users such as representation checks/uses (`src/mir.zig:2591-2605`) and is currently metadata, not a general fact key. | `mcc lower-mir` dispatches through `src/main.zig:297` and prints `mir.appendDumpOpt` at `src/main.zig:424-427`. `appendDumpOpt` prints function summaries, contract regions, instructions, trap edges, and range facts (`src/mir.zig:308-366`). | Backends receive a built MIR module. The typed instruction stream is also consumed by MIR verification, but backend semantic decisions are currently limited to the fact families below plus backend-local AST inference. |
| MIR no-overflow range facts | `src/mir_model.zig:201` `RangeFact` records `region_id`, `target`, `op`, operands, result type, and source point. Producers are `FunctionBuilder.addRangeFactForUncheckedCall` (`src/mir.zig:2491-2507`) and `addAggregateRangeFactForUncheckedExpr` (`src/mir.zig:2509-2530`) inside active `#[unsafe_contract(no_overflow)]` regions. | These facts are appended for unchecked no-overflow calls in contract regions. They are not the same as transient optimizer `proven_facts`; they persist in `Function.range_facts` until the MIR module is freed. | `appendDumpOpt` prints `mir range_fact ... assumption=no_overflow recorded=true` at `src/mir.zig:359-364`; MIR verification facts also scan `function.range_facts` at `src/mir.zig:534`. | The C backend wires `has_mir_no_overflow_range_fact` through `arithContext` (`src/lower_c_emitter.zig:1591-1610`) and matches facts in `hasMirNoOverflowRangeFact` (`src/lower_c_emitter.zig:4545-4557`). LLVM does not currently have an equivalent `range_facts` consumer. |
| MIR check-elision source points | `src/mir_model.zig:212` `SourcePoint` and `Function.elided_bounds` (`src/mir_model.zig:234-239`) record checks proven dead by optimized MIR. Producers append source points for constant in-bounds index (`src/mir.zig:2263-2278`), constant in-bounds slice (`src/mir.zig:2293-2305`), and division/modulo elision (`src/mir.zig:2437`). | Transient `ProvenFact` guard/assert facts are recorded by `recordTrueCondFacts` (`src/mir.zig:2704-2730`), restricted by `factIdentAllowed` (`src/mir.zig:2743-2750`), and invalidated by new bindings, assignment, loops, and address-of (`src/mir.zig:1176-1178`, `src/mir.zig:1212-1214`, `src/mir.zig:1972-1982`, `src/mir.zig:2046-2049`, `src/mir.zig:2690-2697`). | `lower-mir --checks=elide-proven` exposes absence of the original `cmp_bounds`/trap edge and records optimized instruction detail such as `const_in_bounds`; the current dump does not print an explicit `elided_bounds` row. | Both backends consume the same MIR list and fail closed when absent. C uses `mirCheckElided` for array indexing and slice guards (`src/lower_c_emitter.zig:3574-3586`, `src/lower_c_emitter.zig:4272-4280`, `src/lower_c_emitter.zig:4564-4573`) and passes the hook into arithmetic lowering (`src/lower_c_arith.zig:58-59`, `src/lower_c_arith.zig:391`, `src/lower_c_arith.zig:467`, `src/lower_c_arith.zig:507`). LLVM uses `mirCheckElided` for array indexing, slice guards, and div/rem checks (`src/lower_llvm.zig:5830-5834`, `src/lower_llvm.zig:5895-5910`, `src/lower_llvm.zig:5948-5959`, `src/lower_llvm.zig:7102-7118`). |
| LLVM backend-local pointer/global race provenance | `LlvmEmitter` owns backend-local maps for `global_pointer_locals`, local function/aggregate/pointer-array aliases, aggregate field facts, array element facts, slice facts, return summaries, and parameter summaries (`src/lower_llvm.zig`). It collects summary facts in `collectGlobalPointerProvenanceSummaries` and updates local facts through functions such as `updatePointerGlobalProvenance`, `updateAggregatePointerAliasProvenance`, and array/field/slice helpers. | This is the largest duplicated inference class. It resets or clears facts on block/contract/loop/switch boundaries and asm, on local declaration/assignment tracking, on aggregate pointer deref assignment, and on array/slice backing writes. The Phase 3 LLVM slice now routes direct pointer-like locals and direct fixed local pointer-array elements through MIR fact helpers such as `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, and `applyMirPointerProvenanceForIndexAssignment`; broader cases still use backend-local inference. | `lower-mir` prints the authoritative `mir pointer_provenance_fact ...` rows for the narrow subset. LLVM tests also assert non-semantic `; mir pointer_provenance consumed ...` comments at direct consumption sites. | LLVM consumes MIR `PointerProvenanceFact` rows for the narrow direct-local/direct-array subset before `pointerExprHasGlobalStorageProvenance` chooses unordered atomics. The C backend and the broader LLVM provenance family still need migration/cleanup. |
| C backend global/race lowering helpers | `src/lower_c_global.zig` routes direct global scalar, array, and field accesses through race helpers or relaxed C atomics. Examples include `appendGlobalLoadExpr` (`src/lower_c_global.zig:142-150`), `appendGlobalStorePrefix` (`src/lower_c_global.zig:153-162`), `globalAssignmentTarget` (`src/lower_c_global.zig:176-183`), and array/member global access helpers (`src/lower_c_global.zig:219-242`, `src/lower_c_global.zig:270-315`). | This logic keys from AST/global type information and `GlobalInfo`, not from a typed semantic fact table. It is direct-global oriented and does not share LLVM's backend-local pointer provenance maps. | `src/lower_c_inspect.zig:455-492` prints `lower ordinary_access`, `lower race_backend`, `lower race_semantics`, `lower c_ub`, and `lower racing_load_semantics` rows for inspection. | C consumes MIR `elided_bounds` and `range_facts` as listed above, but race/global helper decisions still come from C lowering helpers rather than a shared typed pointer provenance fact. |

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
- direct local fixed pointer-array element provenance for array literal elements
  and constant-index assignments initialized from visible `&global` or `&local`
  address expressions;
- invalidation/unknown facts on pointer reassignment, whole-array reassignment,
  dynamic-index write, address escape, direct call, and indirect call.

Implemented shape:

- `src/mir_model.zig` defines `PointerProvenanceFact` with typed
  `PointerProvenance` (`global_storage`, `local_storage`, `unknown`),
  typed invalidation reason/policy enums, source point, subject local, optional
  element index, optional storage object, and `PointerShape`.
- `Function.pointer_provenance_facts` owns the typed fact slice alongside
  existing `range_facts` and `elided_bounds`.
- `src/mir.zig` produces facts while building MIR from sema-visible AST/MIR
  inputs. It deliberately recognizes only direct address expressions and direct
  fixed pointer-array places; computed values, dynamic reads, unsupported paths,
  or stale facts do not produce `global_storage`.
- `appendDumpOpt` prints stable `mir pointer_provenance_fact ...` rows and the
  function summary includes `pointer_provenance_facts=N`.
- `src/mir_tests.zig` covers direct fact creation, local-storage facts,
  constant-index array assignment, reassignment invalidation, dynamic-index
  write invalidation, call invalidation, address-escape invalidation, absent
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
`PointerProvenanceFact` subset: direct pointer-like locals and direct fixed
local pointer-array elements. C backend consumption and removal of duplicated
broader LLVM inference remain pending.

Move one backend from AST re-inference to typed fact consumption.

For the recommended pointer/global provenance slice, migrate LLVM first because
the current inference lives there. The backend should ask `SemanticFacts` whether
the pointer value/place is global-backed. If the fact exists and is live, emit
the current unordered atomic load/store behavior. If the fact is missing, stale,
or not expressible, keep the conservative existing behavior for that case.

Gate:

- tests that currently pin LLVM global-backed pointer provenance still pass:
  done for direct MIR-fact pointer locals/array elements and the existing broader
  LLVM fixture set;
- new negative tests prove missing/stale facts do not produce atomic provenance:
  done for local-storage facts, dynamic-index invalidation, and call invalidation
  in `src/lower_llvm_tests.zig` / `tests/spec/data_race_semantics.mc`;
- code review can point to removed or bypassed AST inference in LLVM for the
  chosen subset: done for the narrow subset through
  `applyMirPointerProvenanceForLocalInitializer`,
  `applyMirPointerProvenanceForAssignment`, and
  `applyMirPointerProvenanceForIndexAssignment`; duplicated broader LLVM
  inference is intentionally still present for unsupported shapes.

### Phase 4: migrate the second backend and add parity tests

Teach the C backend to consume the same typed fact. The C backend may not need
the same atomic lowering choice for every case, but it must make its emission
decision from the same fact family or explicitly fail closed.

Gate:

- one source fixture is run through C and LLVM with artifact checks showing the
  same semantic fact id/source point drives both emissions;
- absent/stale fact fixtures prove both backends choose the conservative path;
- `zig build test` covers the fact dump, C emission, LLVM emission, and
  differential/spec harness rows.

### Phase 5: retire duplicated AST inference

Once both backends consume the typed fact family, remove the corresponding
backend AST inference helpers for that family. Keep only local emission mechanics
and source-location diagnostics.

Gate:

- `rg` no longer finds the migrated semantic inference class in backend-only
  helpers except for emission mechanics;
- the production readiness bucket links to the migration commits and parity
  tests;
- follow-up families are listed with owners/order: bounds/range facts, integer
  type/default facts, nullability/niche facts, representation-check facts.

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

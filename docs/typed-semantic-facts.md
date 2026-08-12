# Typed semantic facts / typed MIR design

This is the design slice for the typed fact table work: sema resolves once,
backends consume. It turns the current architecture note into implementable
phases with invariants and evidence gates.

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

The typed MIR identity migration has started with `BlockId`: `src/mir_model.zig`
defines the typed ID family (`SourceId`, `NodeId`, `SymbolId`, `TypeId`,
`ValueId`, `BlockId`, and `SpanId`), built MIR blocks carry a `typed_id` plus
typed successor mirrors, built MIR functions carry `typed_symbol_id` entries
backed by a module-owned `SymbolIdentity` table, representation-sensitive instructions and
`RepresentationFact` rows double-write typed `ValueId` identities, each function
also double-writes typed `TypeId` result identities for representation-sensitive
instructions/facts and typed `SpanId` source identities for those rows, each
function owns `ValueIdentity`, `TypeIdentity`, and `SpanIdentity` tables for
those typed ids, target-type owner rows now double-write a typed `SymbolId`
mirror backed by a function-owned `target_owner_identity` table, target-type
facts now double-write typed `TypeId` result identities and typed `SpanId`
source identities alongside their metadata instructions, and
`mir-identity-inventory-test` gates those seeds. This is a migration anchor only;
legacy string/value/type identity remains live until the later Phase 2 slices
move those domains onto typed IDs.

The MIR verifier also checks instruction-carried `TypeId`, `SpanId`, and
`ValueId` rows plus target-type owner `SymbolId` rows against the owning
function identity tables when those IDs are present. Target-type admission also
requires fact-carried `TypeId`, `SpanId`, and owner `SymbolId` mirrors to match
their corresponding metadata instruction and the owning function identity
tables, and `lower-mir` prints the target-type `typed_result_ty_id`,
`typed_span_id`, and `typed_target_owner_id` on the owned fact row.
Representation-fact admission now also requires fact-carried `typed_result_ty_id`
and `typed_span_id` mirrors to match the owning function identity tables;
`lower-mir` prints those rows plus the optional representation `typed_value_id`
mirror. Hand-built compatibility MIR may still leave unrelated typed fields
invalid, but it cannot make a representation fact and its instruction drift
together back to untyped result-type or line/column matching.

`VerifiedProgram` now exposes a `SourceSpellingView` backed by the verified MIR
`SymbolIdentity` table. Backend entrypoints can resolve function symbol spelling
through this explicit view instead of treating the AST as the source-spelling
table. `VerifiedProgram` no longer stores a general `ast.Module` or raw
declaration slice. Declaration-list mechanics now go through collected
`EarlyDeclarationArtifacts`, carried by `LowerRequest` instead of being stored
on `VerifiedProgram`. Source-map row syntax enumeration is isolated in
`declaration_artifacts.zig`; `EmitMapRequest` carries collected
`SourceMapArtifact` values rather than a declaration view or wrapper module. The early metadata artifact boundary
now pre-collects const fn/global/type/aggregate categories while still carrying
ordered declaration artifacts for C declaration collection. It still carries
declaration slices for not-yet-normalized comptime and LLVM callable/global
mechanics, but the remaining syntax-shaped ingress is named and exact-gated by
the inventory. C and LLVM runtime hook suppression already consume the shared
`SourceSpellingView.definesFunctionSpelling` query when deciding whether to
emit weak/default trap and sanitizer hook bodies; per-backend
`moduleDefinesHook` helpers are exact-zero gated, and the AST is no longer the
authority for that prelude symbol-spelling decision.

Artifact metadata consumers are also converging on the shared
`artifact_model.ArtifactBundle` contract instead of local header checks.
`mcmap-verify.py` now validates
metadata sidecar `artifact_kind` and `backend` identity when the consumer
declares an expected class, plus generated artifact and loaded-source SHA-256
when those paired files are supplied. C/source-map-bearing artifacts additionally
carry `source_map_generated_artifact_sha256`, `source_map_payload_sha256`, and
`mir_facts_sha256` as one validated binding; the verifier rejects incomplete
source-map digest triplets and can compare the mapped generated-C artifact when
provided. The CLI/build gates reject C, LLVM, and host-executable `.mcmeta`
sidecars if they are paired with the wrong artifact class, wrong backend, wrong
generated bytes, wrong source-map generated bytes, wrong loaded-source bytes, or
an incomplete source-map/MIR-fact digest binding.

The completed backend AST-inference budget sets the current shrinking budget to
seven registered backend families. This closes the budget action slice; each
budgeted family still needs a later migration, reduction, or accepted limitation
decision.

Within that budget, C's legacy `source_type_for_expr` callback has been removed
and the retired `src/lower_c_infer.zig` module is deleted. The inventory fails
closed if that module is reintroduced. The
generic `Result<T, E>` and tagged-union source-expression fallbacks have been
removed, and zero-span address-of deref
pointee inference now requires the addressed operand to have an `operandEmitType`
result instead of delegating to generic source typing. Zero-span member base
and index base typing now follow the same rule. Explicit casts keep their declared
target type, and other Result/tagged-union expression typing now goes through
`operandEmitType` or the existing ident/call/grouped paths. Generated zero-span
slice bases use a narrow call-return/operand-emission helper instead of generic
source typing. Direct source identifiers now also get MIR `expression_result`
facts; C and LLVM direct-ident lookup use the local/global/function declaration
tables only to find the declared type and then require the MIR row to match
before using it. Direct `&ptr.*` source-address paths use the same rule for the
pointer operand before deriving pointee mutability.
The remaining C helper is named `identTypeForEmissionRecovered` to make that
role explicit: it recovers a declared storage type for generated nodes or for
stale-fact comparison, but it does not authorize a source-spanned identifier
without the matching MIR row. Generated zero-span identifiers and
parser-synthesized tuple destructure temps remain on the declaration fallback
because they have no stable user-source identifier fact. Direct source calls
likewise get MIR `expression_result` rows;
C still uses the call-specific fact family to identify the callee/ABI path, but
the final value type for a source call expression must match its
`expression_result` row. Source-spanned C index expressions follow the same
rule; the remaining `localIndexElementType` fallback is limited to
compiler-generated zero-span indexes and inventory-gated so it cannot quietly
become source authority again. Nullable source-expression classification follows
the same boundary: the direct-local nullable fallback is generated-only, while
real source nullable expressions must present an `expression_result` row.

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
typed semantic source of truth.  `src/mir_facts_view.zig` is the current narrow
production query boundary: both C and LLVM consult it for target-type facts, so
source-span matching, owner matching, and `TypeId`/`SpanId`/`SymbolId` identity
validation are no longer independently reimplemented by each backend. Local
queries no longer hide module-wide scans; the remaining generated-plumbing
module-wide fallback has been retired; current-function compatibility queries are exact-count gated.

- `mcc facts` parses a module and prints `src/ir.zig`'s fact collector output via
  `ir.appendFacts`. These are textual inspection facts for semantic traps,
  contracts, MMIO, race semantics, and related spec evidence.
- `mcc inspect-ir` prints the same `src/ir.zig` model as a compact textual
  inspection artifact. It is useful for fixtures, but backends do not consume
  it. `lower-ir` remains a compatibility alias.
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
- Large classes of backend behavior still carry semantic-adjacent emission
  queries. The retired `src/lower_c_infer.zig` module is deleted and
  inventory-gated absent, but
  the C backend still has operand, shape, and target-policy queries in
  `src/lower_c_emitter.zig`, `src/lower_c_info.zig`, and related helpers; the
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
7. Textual artifacts stay debug surfaces. `mcc facts`, `inspect-ir`, and
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
| MIR explicit-trap call facts | `explicitTrapCallTargetKind` resolves the eight accepted `trap(.Reason)` forms into exact identities with `never` result type. Sema rejects type arguments, wrong arity, and unknown or non-literal reasons before MIR construction. | Generic call-target validation requires one matching identity instruction/fact pair. A stale reason identity fails validation even though the control-flow edge remains generically classified as `.ExplicitTrap`. | `lower-mir` prints the exact trap identity at the call source point. | C and LLVM map the MIR identity through `explicitTrapHelperForTarget` to select the runtime ABI helper, and LLVM uses it to recognize a diverging expression statement. AST only validates nonsemantic argument shape after that identity is known. Missing or stale facts reject prebuilt MIR; backend-local trap-callee classifiers are exact-zero gated. |
| MIR runtime-assert condition facts | The statement builder records a complete canonical `assert_condition=bool` target-type fact at the condition source point beside the typed assert instruction and `.Assert` trap edge. | Generic target-type validation requires the matching complete fact. The backend contract additionally requires the target type to remain canonical `bool`, so a stale complete non-`bool` fact cannot authorize lowering. | `lower-mir` prints the owned target-type row with the other function facts. | C and LLVM both require the fact through shared bool-condition target-type admission helpers before assert lowering. C target-types the ordinary condition from it; LLVM no longer calls backend-local `exprType` for assert conditions. Missing facts fail MIR admission; stale complete types fail backend admission. |
| MIR while-loop condition facts | The loop builder records a complete canonical `loop_condition=bool` target-type fact at every `while` condition source point beside its conversion check. | Generic target-type validation requires the matching complete fact. The backend contract additionally requires canonical `bool`, so a stale complete non-`bool` fact cannot authorize lowering. | `lower-mir` prints the owned target-type row with the other function facts. | C and LLVM both require the fact through shared bool-condition target-type admission helpers before while lowering. LLVM no longer calls backend-local `exprType` for the condition. Missing facts fail MIR admission; stale complete types fail backend admission. |
| MIR switch subject type facts | The switch builder records one complete `switch_subject` target-type fact at every subject source point. It covers Result, nullable pointer, tagged union, enum, scalar, and parser-desugared boolean `if` subjects; grouped logical/comparison expressions resolve recursively to canonical `bool`. | Generic target-type validation requires one matching fact. C and LLVM independently compare a fact with any locally available type only to reject stale prebuilt MIR; the fact, not the local query, selects the lowering family. | `lower-mir` prints the owned target-type row with the other function facts. | C requires the fact before selecting Result/nullable/tagged-union/enum/scalar lowering. LLVM passes it to every switch emitter and no longer scans tagged-union patterns to infer the subject type. Missing facts fail MIR admission; stale complete types fail backend admission. |
| MIR `if let` subject type facts | The `if let` builder records one complete `if_let_subject` target-type fact at every value source point. It covers the accepted Result and nullable binding subjects, including direct calls that require one-time backend materialization. | Target-type validation requires one matching fact and rejects a forged `if_let_subject` whose value family is no longer Result or nullable even when the instruction was retargeted with it. C and LLVM independently compare a fact with any locally available type only to reject stale prebuilt MIR; the fact selects the Result versus nullable lowering family and supplies the C materialization type. | `lower-mir` prints the owned target-type row with the other function facts. | C requires the fact before Result/nullable `if let` lowering and passes it into fact-typed subject materialization. LLVM passes it to both `if let` emitters. Missing facts, non-Result/non-nullable family forgeries, and stale complete types fail before emission. |
| MIR `try` operand type facts | The expression builder records one complete `try_operand` target-type fact at every Result or nullable operand source point, including the nullable result of `mmio.map<T>(...)` rather than its non-null payload. | Target-type validation requires one matching fact and rejects a forged `try_operand` whose value family is no longer Result or nullable even when the instruction was retargeted with it. C classifies direct, nested, sequenced, and hoisted `try` paths from the fact; LLVM compares the fact with any locally available type only to reject stale prebuilt MIR. | `lower-mir` prints the owned target-type row with the other function facts. | C materializes Result/nullable operands from the fact, including `MmioPtr<T>` nullable payloads, and LLVM requires it before propagation/trap checks and `try` result typing. Missing facts, non-Result/non-nullable family forgeries, and stale complete types fail before emission. |
| MIR inferred local copy/call/cast/address/storage-read/try/unary/binary/literal type facts | For a one-name unannotated local initialized directly from an existing local value, a direct address of a previously declared local or global place, a field path rooted in one, a fixed-array element rooted in one, or the direct pointee of a declared pointer/raw-many-pointer local, a direct member/index/slice/dereference read with a resolved storage type, a direct Result/nullable `try` payload read with a complete `try_operand` fact, an ordinary direct function/extern call, a function-pointer or closure call with a complete `indirect_call_callee` signature, a non-`void` `*dyn Trait` call with complete `dyn_dispatch_result` and fixed-argument facts, value-producing `atomic.load` / `atomic.fetch_add` / `atomic.fetch_sub` calls with an `atomic_payload` fact, `MaybeUninit.assume_init()` with a `maybe_uninit_payload` fact, `phys(value)` with a `phys_result` fact, `raw.load<T>` / `raw.ptr<T>` with a `raw_result` fact, `bitcast<T>` with a `bitcast_target` fact, `value.raw()` with an `enum_raw_result` fact, arithmetic-domain result calls with a `domain_result` fact, MMIO `read` with an `mmio_result` fact, scalar/domain conversions with a `conversion_target` fact, function-body reflection with a `reflection_result` fact, direct raw-many offsets with a `raw_many_offset_result` fact or their dereferences with a `raw_many_offset_element` fact, `mem.as_bytes` / `mem.bytes_equal` with complete byte-view result facts, semantic escapes with complete result facts, an explicit `value as T` cast, a typed unary/binary expression including bitwise `&` / `|` / `^` / `<<` / `>>`, or a targetless integer (`u32`) / bool literal, MIR records an owned `inferred_local` target-type fact keyed by the binding name and initializer source point. Direct data-address facts own a generated pointer type with `*mut T` for a mutable root and `*const T` for an immutable local or top-level `const` global; for `&pointer.*`, the declared pointer/raw-many-pointer type determines that qualification. | Generic target-type validation matches the owned fact and instruction. C and LLVM compare the sema-defined local/direct-address/direct-storage/direct-try/direct-call/indirect-signature/dynamic-dispatch/builtin-result/cast/unary/binary/literal type to reject stale prebuilt MIR; direct-address admission compares both pointee type and pointer qualification. The fact selects the destination binding type. | `lower-mir` prints the owner alongside the target-type row. | C uses the fact for inferred local-copy, direct local/global-place/field-path/fixed-array-element/direct-pointer-pointee address, and direct member/index/slice/dereference/`try` payload reads; scalar, array, slice, tagged-union, Result, nullable, indirect, and dynamic-dispatch calls; atomic/MaybeUninit/physical-address/raw/bitcast/enum-raw/arithmetic-domain/MMIO-read/conversion/reflection/raw-many-offset and raw-many-offset-dereference/byte-view/semantic-escape result calls; direct-cast; checked-unary; checked-arithmetic and bitwise; comparison; short-circuit logical; integer-literal; and bool-literal declarations. LLVM uses it before allocating each binding. Removing the fact fails MIR admission and retargeting it fails backend emission. Slice indexes, pointer chains, call results, void builtins, MMIO writes, non-dynamic member calls, and broader computed initializers remain in the registered broader expression-inference boundary. |
| MIR direct address result facts | A direct `&function` expression records a complete `expression_result` function-pointer signature from the resolved function summary. A bounded direct data-address expression records `*const T` or `*mut T` from the established local/global place and mutability rule; admitted top-level `const` globals, field/fixed-array projections, and direct local pointer/raw-many-pointer pointees use the same rule. Slice indexes, pointer chains, and call results remain factless. | Generic target-type validation requires the source-span instruction/fact pair. Data-address retargeting is rejected by C/LLVM admitted-place checks before emission; inferred address bindings validate both the pointee and the `const`/`mut` qualification against backend declaration state. | `lower-mir` prints the owned `expression_result` row. | C and LLVM consume the fact for code-pointer and bounded data-pointer typing; missing facts fail admission and stale facts fail backend lowering. |
| MIR target-typed char literal facts | A target-typed char literal records a complete `char_literal` target-type fact whenever its context resolves to an integer type. | Generic target-type validation requires the source-span instruction/fact pair. C and LLVM compare the fact to their semantic target before emission. | `lower-mir` prints the owned target-type row. | C parses the MC char literal and explicitly casts its byte value to the fact-owned integer type; LLVM emits the same parsed byte value at the fact-owned type. Missing facts fail MIR admission and retargeted facts fail checked lowering. C static global initialization remains the existing static-initializer mechanism, with generic MIR admission enforcing the fact. |
| MIR `for` iterable and element type facts | The loop builder records complete `for_iterable` and `for_element` target-type facts at every iterable source point. | Generic target-type validation requires matching facts. C and LLVM additionally prove that the iterable fact is an array/slice and that its child matches the element fact, then compare a locally available iterable type only to reject stale prebuilt MIR. | `lower-mir` prints both owned target-type rows with the other function facts. | C and LLVM admit the iterable through target-type emission helpers and read the separate loop-binding element row through loop-element helpers, then use the pair for call-bearing iterable materialization, iterable storage, length, element loads, and binding storage. Missing facts fail MIR admission; stale complete types fail backend admission. |
| MIR direct, indirect, and dynamic-dispatch call type facts | An identifier-form call resolved to a declared ordinary function or extern records `direct_call_result` at the callee source point and `direct_call_argument` at each argument source point. Fixed-argument types are copied from the sema-visible declaration summary; variadic tail argument types are copied from the already-resolved expression type. A function-pointer or closure call records one complete `indirect_call_callee` signature fact at its callee source point. A `*dyn Trait` call records `dyn_dispatch_argument` for every fixed user argument; non-`void` calls additionally record `dyn_dispatch_result`. Dynamic facts are owned by trait name and vtable slot/argument index, while member calls remain excluded from direct facts so they cannot bind to an unrelated same-named free-function summary. | Generic target-type validation requires one matching complete fact per metadata instruction. Direct-call facts additionally carry a callee owner and optional fixed-argument index; dynamic-dispatch facts carry the trait owner and vtable slot/argument identity. This prevents generated calls with identical source coordinates from cross-matching. Ordinary source call-target facts now carry the exact callee span, including offset/length, rather than only the whole call expression's line/column; this prevents nested same-start calls such as `read_state().raw()` from cross-consuming the outer member-call target kind. C and LLVM additionally compare consumed fixed direct/dynamic facts with the declaration or trait signature, using those only as ABI/stale-fact checks rather than missing-fact fallbacks; variadic direct tail facts have no declared parameter to compare against. | `lower-mir` prints `target_owner` and `target_index` on direct/dynamic rows and prints the complete indirect callee signature row with the other target facts. | C and LLVM consume direct facts, including variadic direct-call tail argument facts, in ordinary, inferred-result, sequenced, extern-nonnull, value, and void/never paths; their checked-MIR function-pointer and closure paths consume `indirect_call_callee`, and dynamic-dispatch paths consume `dyn_dispatch_argument` plus `dyn_dispatch_result` when applicable. Missing facts fail MIR admission; stale complete types and malformed stale indirect signatures fail backend admission. Non-dynamic member calls and variadic dynamic dispatch remain outside this bounded migration. LLVM's `expectedTyForCallArg` and direct `fn_sigs` return fallback are exact-zero gated; the async generated-source collision fixture gates owner-aware identity, and the MIR test gates same-named member exclusion. |
| Text IR inspection facts | `src/ir.zig:510` `Collector.appendFacts`, `src/ir.zig:525` `appendFacts`, and `src/ir.zig:590` `ModuleFactCollector.appendFacts` walk the AST and emit line-oriented `fact ...` rows for trap edges, `#[no_lang_trap]`, unsafe contracts, unchecked calls, ordinary/racing access, MMIO calls/access/order, and direct MMIO assignment. | AST-derived only; there is no typed in-memory table behind this surface. MMIO global/parameter discovery is held in `ModuleFactCollector.globals` / `mmio_structs` (`src/ir.zig:571-576`) and helper lookups such as `mmioAccess` (`src/ir.zig:664`) and `mmioRegisterTarget` (`src/ir.zig:746`). | `mcc facts` dispatches through `src/main.zig:291` and prints `ir.appendFacts` at `src/main.zig:645-648`. Representative rows include `fact checked_arithmetic_trap` (`src/ir.zig:1059`), `fact ordinary_access` (`src/ir.zig:1116`), `fact racing_load_semantics` (`src/ir.zig:1121`), `fact non_atomic_rmw` (`src/ir.zig:1165`), and `fact mmio_access` (`src/ir.zig:1199`). | No production backend consumes this text. It is evidence for tests/spec fixtures and must not become a reparsed backend input. |
| Inspect-IR contract/trap artifact | `src/ir.zig:128` `appendLowerIr` builds `IrFunction` records with `trap_edges`, `safe_no_trap_ops`, `contract_regions`, and `unchecked_calls`; `FunctionIrBuilder.collectContractBlock` records contract regions at `src/ir.zig:378`. | Textual inspection model only; contract activity is tracked by `FunctionIrBuilder.active_contract` / `active_contract_region_id` (`src/ir.zig:197-199`) while walking the AST. | `mcc inspect-ir` dispatches through `src/main.zig` and prints `ir.appendLowerIr`; the legacy `lower-ir` alias prints the same artifact. It emits `ir contract_region`, `ir unchecked_call`, `ir trap_edge`, `ir post_contract_trap_edge`, and `ir safe_no_trap` rows (`src/ir.zig:137-180`). | No production backend consumes this artifact. Contract scope also has a C inspection artifact in `src/lower_c_inspect.zig:195-219`, but that is an inspection artifact, not the source of backend semantic authority. |
| MIR typed instruction metadata | `src/mir_model.zig` `ValueType`, `Instruction`, and optional `value_id` / `contract_region_id` / `const_index` carry typed operation metadata. `Function` owns the typed fact tables and any generated `TypeExpr` child nodes or generic argument slices referenced by them. | `CallTargetFact` records bounded builtin/call identities, including closure bind, Result constructors, reductions, enum representation reads, arithmetic-domain calls, `const_get`, DMA calls, raw-many pointer offsets, MMIO mapping and register reads/writes, raw memory, varargs, reflection, byte-view, semantic-escape, atomic initialization/member operations, MaybeUninit operations, and scalar/domain conversion result types. `TargetTypeFact` records complete types for constructors, contextual literals/aggregates, self-typed qualified-union and enum-path expressions, member/index/slice/dereference and unary/binary expression results, mapped-try error expressions, null/optional/dyn coercions, scalar/domain conversion source/targets, reduction elements, enum raw source/results, arithmetic-domain source/payload/result/interval types, const-get base/results, DMA buffer/payload/results, raw-many offset receiver/element/results, MMIO-map source/payload/results, MMIO register struct/storage/value/results, raw-memory address/payload/results, varargs cursor/payload/results, byte-view source/results, reflection target/results, explicit-cast source/targets, implicit single-pointer/slice const-narrowing source/targets, semantic-escape source/results, atomic-init payload/results, and atomic/MaybeUninit member payloads. Assignment, target-typed constructor, and qualified tagged-union constructor call instructions carry the resolved MIR-owned lowering type instead of `.unknown`. `expression_result` rows use the full source span, not just line/column, so nested expressions on one line cannot cross-match. Explicit casts, semantic escapes, MMIO mapping, and varargs cursors cover generated type nodes with explicit MIR lifetime ownership; domain calls and scalar `try_from` conversion call targets similarly own generated `Result` shapes. Atomic-init payload/result pairs use a unique owner/index group so same-source generated calls cannot cross-match. A `? else MAPPED` expression is built with the enclosing `Result<T,E>` error type, so target-typed mapped enum literals no longer depend on C inference. Implicit const narrowing emits paired facts only for `*mut T` to `*const T` and `[]mut T` to `[]const T`; pass-through values and raw-many pointers emit none. Metadata/fact multiplicities must match and same-key complete types must be structurally equal. | `mcc lower-mir` prints function summaries plus owned target rows. | C and LLVM validate before emission through `validateLoweringAdmission`; call-target, target-type, representation, integer, range, function-return, terminator, and all runtime/fact-bearing instruction type positions reject `.unknown` type placeholders. Diagnostic-only check instructions remain the explicit `.unknown` allowlist. Closure bind, Result constructors, reductions, enum representation reads, arithmetic-domain calls, `const_get`, DMA calls, raw-many pointer offsets, MMIO mapping/register calls, conversion, explicit-cast, mapped-try, self-typed expressions, member/index/slice/dereference and unary/binary type queries, implicit view const-narrowing, semantic escapes, atomic initialization/member operations, MaybeUninit, raw memory, varargs, reflection, and byte-view lowering consume exact MIR identities/types where migrated; removing any `expression_result` row rejects prebuilt MIR. Broader direct expression emission remains a registered migration boundary. |
| MIR no-overflow range facts | `src/mir_model.zig:201` `RangeFact` records `region_id`, `target`, `op`, operands, result type, and source point. Producers are `FunctionBuilder.addRangeFactForUncheckedCall` (`src/mir.zig:2491-2507`) and `addAggregateRangeFactForUncheckedExpr` (`src/mir.zig:2509-2530`) inside active `#[unsafe_contract(no_overflow)]` regions. | These facts are appended for unchecked no-overflow calls in contract regions. They are not the same as transient optimizer `proven_facts`; they persist in `Function.range_facts` until the MIR module is freed. | `appendDumpOpt` prints `mir range_fact ... assumption=no_overflow recorded=true` at `src/mir.zig:359-364`; MIR verification facts also scan `function.range_facts` at `src/mir.zig:534`. LLVM emission prints non-semantic `; mir range_fact consumed ... assumption=no_overflow` comments when it consumes a fact; C emission prints `/* MC_MIR_RANGE no_overflow ... */` comments from its MIR-gated unchecked paths. The inventory checker anchors the owned `RangeFact` model, the dump row, and exact C/LLVM no-overflow range consumer call counts. | The C backend wires `has_mir_no_overflow_range_fact` through `arithContext` (`src/lower_c_emitter.zig:1591-1610`) and matches facts in `hasMirNoOverflowRangeFact` (`src/lower_c_emitter.zig:4545-4557`); its generic builtin dispatcher now rejects unchecked no-overflow calls instead of emitting plain arithmetic without a matching fact. C and LLVM both have target-label coverage for return values, inferred locals, assignments, call arguments, binary operands, array literal elements, and struct literal fields. LLVM requires `requireMirNoOverflowRangeFact` for `unchecked.add/sub/mul` and matches target identity through `current_mir_range_target` for those contexts. Removing a matching `RangeFact`, or retargeting it to a different target label in a prebuilt MIR module, makes both C and LLVM fail closed instead of trusting the AST call, including non-`value` inferred-local, assignment, call-argument, binary-operand, aggregate-element, and aggregate-field targets; absence coverage now explicitly spans those non-`value` contexts in both backends. Broader range/bounds facts are still not a complete typed fact family. |
| MIR bounds facts | `src/mir_model.zig` `BoundsFact` records index and slice checks that remain after MIR optimization; `FunctionBuilder.buildExpr` appends them with the same source point as the check. | Optimized proofs remain represented by `elided_bounds`; every non-elided array/slice check requires a `BoundsFact` instead of being accepted from AST shape alone. | `mcc lower-mir` prints the function `bounds_facts=N` count and stable `mir bounds_fact fn=... kind=index|slice recorded=true line=... column=...` rows. The inventory checker anchors the owned `BoundsFact` model, dump row, and C/LLVM `requireMirBoundsFact` consumers with exact call counts. | C and LLVM call `requireMirBoundsFact` before emitting non-elided array-index or slice bounds checks. Removing the matching fact from prebuilt MIR produces `UnsupportedCEmission` / `UnsupportedLlvmEmission`; direct missing-fact tests cover both backends. |
| MIR integer literal facts | `src/mir_model.zig` `IntegerFact` records accepted target-typed integer literal conversion with the literal text, target `ValueType`, and source point. `FunctionBuilder.addIntegerLiteralFact` appends an `integer_literal_conversion` metadata instruction plus the owned fact when `integerLiteralFitsTarget` accepts a conversion. | These facts are admission evidence for target-typed integer literal lowering. Out-of-range literals still produce MIR conversion diagnostics; accepted literals now have a positive MIR row instead of leaving backends to trust only AST target context. | `mcc lower-mir` prints `integer_facts=N` and stable `mir integer_fact fn=... literal=... target_type=... recorded=true` rows. The inventory checker anchors the model, producer, dump row, unified C/LLVM admission call, and missing/stale tests. | C and LLVM call `validateLoweringAdmission` at backend entry, which includes `validateIntegerFactsForLowering` and rejects `.unknown` placeholders in admitted integer fact target types. Removing integer facts from prebuilt MIR, or retargeting one to a different integer type, returns `InvalidMirIntegerFacts` before backend emission. This is a bounded integer/default fact slice for target-typed integer literals, not full typed HIR replacement. |
| MIR `const_get` index facts | `src/mir_model.zig` `ConstGetFact` records the checked compile-time index and source point; the corresponding typed `.index` instruction carries the same value in `const_index`. Complete `const_get_base` and `const_get_result` target rows own the array and element types. | `validateConstGetFactsForLowering` requires bidirectional multiplicity and exact index/source agreement between instructions and facts. Target-type and call-target validators independently gate the two types and operation identity. | `lower-mir` reports `const_get_facts=N`, prints `const_index=N` on the instruction, and emits `mir const_get_fact ... index=N recorded=true`. | C and LLVM validate at backend entry and use the fact index plus target types. Missing/stale index facts return `InvalidMirConstGetFacts`; missing types return `InvalidMirTargetTypeFacts`. Backend AST use is limited to the confirmed base expression and admitted call shape. |
| MIR DMA call facts | `dmaCallTarget` resolves every accepted cache clean/invalidate and `DmaBuf` address/slice call into an exact `CallTargetKind` plus complete `dma_buffer`, `dma_payload`, and `dma_result` target rows. Alias resolution and `[]mut T` result construction happen once in MIR. | Generic call-target and target-type validators require matching instruction/fact multiplicity, exact identity, and structurally equal complete types. | `lower-mir` prints the DMA call-target instruction/fact and all three target-type rows at the call source point. | C and LLVM use the MIR operation identity and types; AST use is limited to admitted call shape and operand extraction. Missing identities/types or stale identities reject prebuilt MIR. LLVM-local `exprType`/`dmaBufInfo` and C local-`source_ty` recognition are retired and exact-zero gated. |
| MIR raw-many offset facts | `rawManyOffsetCallTarget` resolves every accepted `[*]T.offset(index)` into the `raw_many_offset` identity plus complete `raw_many_offset_base`, `raw_many_offset_element`, and `raw_many_offset_result` rows. Receiver alias resolution and element extraction happen once in MIR. | Generic call-target and target-type validators require matching instruction/fact multiplicity, identity, and complete types. The operation remains provenance-preserving in MIR, while only separately proven zero-offset transfers gain positive storage provenance. | `lower-mir` prints the operation identity and all three type rows at the call source point. | C and LLVM consume MIR identity/types and use syntax only for operand extraction. Missing/stale identities or missing types reject prebuilt MIR. C raw-many local/function-return recursion and LLVM receiver `exprType`/alias re-resolution are retired. |
| MIR MMIO call facts | `mmioCallTarget` resolves every accepted MMIO register `read`/`write` into an exact identity plus complete `mmio_struct`, `mmio_storage`, `mmio_value`, and `mmio_result` rows. Receiver, register, and alias resolution happen once in MIR; `RegBits` storage and exposed value types remain distinct. | Generic call-target and target-type validators require matching instruction/fact multiplicity, identity, and complete types. Sema/MIR still validate the register access mode and ordering syntax. | `lower-mir` prints the MMIO operation identity and all four type rows at the call source point. | C and LLVM consume MIR identity/types. AST use is limited to confirmed operand/field extraction and ordering emission; declaration lookup and field offsets remain backend layout mechanics. Missing/stale identities or missing types reject prebuilt MIR. C register metadata inference and LLVM receiver/field type reconstruction are retired and exact-zero gated. |
| MIR MMIO-map facts | `mmioMapCallTarget` resolves every accepted `mmio.map<T>(PAddr)` into the `mmio_map` identity plus complete `mmio_map_source`, `mmio_map_payload`, and `mmio_map_result` rows. MIR owns the generated nullable result child node. | Generic call-target and target-type validators require matching instruction/fact multiplicity, identity, and complete types. Sema/MIR still validate unsafe context and the MMIO target class. | `lower-mir` prints the map identity and all three type rows at the call source point. | C direct emission, C nullable-try rewriting and payload discovery, and LLVM emission/result typing dispatch from the MIR identity and consume its types. AST use is limited to admitted call shape and operand extraction. Missing/stale identities or missing types reject prebuilt MIR; backend payload reconstruction from type arguments and `isMmioMapCallName` call-name classification are exact-zero gated. |
| MIR raw-memory call facts | `rawCallTarget` resolves every accepted `raw.load<T>`, `raw.ptr<T>`, and `raw.store<T>` into an exact operation identity plus complete `raw_address`, `raw_payload`, and `raw_result` rows. The result is `T`, `*mut T`, or `void` respectively. | Generic call-target and target-type validators require matching instruction/fact multiplicity, identity, and structurally equal complete types. | `lower-mir` prints each raw operation identity and all three type rows at the call source point. | C and LLVM consume MIR address/payload/result types for emission and result queries; AST use is limited to validating the confirmed shape and extracting operands. C `raw.load` / `raw.ptr` emission and LLVM raw call classification now share `rawAddressTypesForEmission`, so both backends consume the complete address/payload/result triplet through named admission helpers. Missing identities or any missing type reject prebuilt MIR for load, ptr, and store. Backend type-argument and hard-coded address-type inference is exact-zero gated. |
| MIR varargs call facts | `vaCallTarget` resolves accepted `va.start`, `va.arg<T>`, and `va.end` calls into exact identities. Start owns `va_result=va_list`; arg owns canonical `va_cursor=*mut va_list`, `va_payload=T`, and `va_result=T`; end owns the same cursor type and `va_result=void`. Generated cursor child nodes are owned by the MIR function. Sema separately enforces exact arity/type-argument shape, rejects `va.start` outside a variadic function, and accepts only `&va_list` or `*mut va_list` cursors. | Generic validators require matching identity/type instruction and fact multiplicity with structurally equal complete types. | `lower-mir` prints each identity and all applicable cursor/payload/result rows at the call source point. | C and LLVM consume the complete types for cursor expression emission, extracted ABI payload spelling, initialization/end admission, and expression result typing. C `va.arg` / `va.end` emission and LLVM varargs call classification now share `vaCallTypesForEmission`, localizing the applicable cursor/payload/result admission for those statement/value paths. AST use is limited to confirmed operation shape and operand extraction. Direct pointer cursors and address-of locals are covered. Removing identities or any applicable type family rejects prebuilt MIR; the LLVM cursor `exprType` fallback and old result-only fact kinds are exact-zero gated. |
| MIR reflection call facts | `reflectionCallTarget` resolves function-body `size_of`/`sizeof`, `alignof`, `field_offset`, `bit_offset`, and `repr_of` calls into exact identities plus complete `reflection_target` and `reflection_result` rows. | Generic validators require matching identity/type instruction and fact multiplicity with structurally equal complete types. | `lower-mir` prints each reflection identity and both type rows at the call source point. | C and LLVM dispatch from the reflection MIR identity and consume target/result facts for layout evaluation and result typing. AST only supplies field-name extraction and layout emission mechanics after the kind is known. Missing identities or types reject prebuilt MIR. C/LLVM reflection-call classifiers, C call-emission type-argument authority, and LLVM call-emission AST folding are exact-zero gated. Type-level reflection used while evaluating array lengths/layout is not represented by function MIR and remains open. |
| MIR byte-view call facts | `byteViewCallTarget` resolves `mem.as_bytes` and `mem.bytes_equal` into exact identities plus complete `byte_view_source` and `byte_view_result` rows. The source is the addressed object type for as-bytes and canonical `[]const u8` for equality; results are `[]const u8` and `bool`. | Generic validators require matching identity/type instruction and fact multiplicity with structurally equal complete types. | `lower-mir` prints the operation identity and both type rows at the call source point. | C and LLVM dispatch from the `byte_view_as_bytes` / `byte_view_equal` MIR kind and consume source/result facts for object size/layout, pointer/slice construction, comparison operands, and result queries. AST only supplies address and operand emission mechanics after the kind is known. The remaining AST read is intentionally mechanics-only: C and LLVM each keep one `byteViewAddressTarget(call.args[0])` check to validate the address expression they are about to emit after MIR has already authorized the byte-view identity and source/result types. Both occurrences are exact-count gated so this emission-mechanics escape hatch cannot expand into another backend-local semantic classifier. Missing identities or types reject prebuilt MIR; C/LLVM byte-view callee classifiers, C source inference, and LLVM expression/slice reconstruction are exact-zero gated. |
| MIR check-elision source points | `src/mir_model.zig:212` `SourcePoint` and `Function.elided_bounds` (`src/mir_model.zig:234-239`) record checks proven dead by optimized MIR. Producers append source points for constant in-bounds index (`src/mir.zig:2263-2278`), constant in-bounds slice (`src/mir.zig:2293-2305`), and division/modulo elision (`src/mir.zig:2437`). | Transient `ProvenFact` guard/assert facts are recorded by `recordTrueCondFacts` (`src/mir.zig:2704-2730`), restricted by `factIdentAllowed` (`src/mir.zig:2743-2750`), and invalidated by new bindings, assignment, loops, and address-of (`src/mir.zig:1176-1178`, `src/mir.zig:1212-1214`, `src/mir.zig:1972-1982`, `src/mir.zig:2046-2049`, `src/mir.zig:2690-2697`). | `lower-mir --optimize` exposes absence of the original `cmp_bounds`/trap edge, records optimized instruction detail such as `const_in_bounds`, includes an `elided_bounds=N` summary count, and prints explicit `mir elided_bounds_fact ... recorded=true` rows from `Function.elided_bounds`. | Both backends consume the same MIR list and fail closed when absent. C uses `mirCheckElided` for array indexing and slice guards (`src/lower_c_emitter.zig:3574-3586`, `src/lower_c_emitter.zig:4272-4280`, `src/lower_c_emitter.zig:4564-4573`) and passes the hook into arithmetic lowering (`src/lower_c_arith.zig:58-59`, `src/lower_c_arith.zig:391`, `src/lower_c_arith.zig:467`, `src/lower_c_arith.zig:507`). LLVM uses function-filtered `mirCheckElided` for array indexing, slice guards, and div/rem checks (`src/lower_llvm.zig:6607-6616`, plus call sites), matching C's function-filtered source-point lookup. |
| LLVM backend-local pointer/global race provenance | `LlvmEmitter` owns backend-local maps for local function/aggregate/pointer-array aliases, aggregate field facts, array element facts, and slice facts (`src/lower_llvm.zig`). Aggregate-return pointer fields are loaded only from MIR facts by `collectMirAggregateReturnPointerFieldFacts`; the old LLVM AST pre-scan is retired. C admits pointer-local provenance through MIR-only helpers. LLVM's aggregate-alias map is now mechanics-only: it associates a local alias with the backing local whose field facts MIR has already produced. | This remains the largest duplicated inference class. The Phase 5 cleanup retires LLVM's global pointer-local AST fallback and aggregate-return AST collector: covered direct forms without a MIR fact remain unknown. An aggregate-alias write can no longer infer `local_storage` or `global_storage` for its backing aggregate from the RHS; it consumes a matching backing fact when present and otherwise clears the backing field to `unknown`. LLVM also has no backend-local scalar pointer-return summary: supported direct, forwarded, noalias-wrapped, branched, and local-function-alias return flows are caller MIR facts. | `lower-mir` prints authoritative `mir pointer_provenance_fact ...` and `mir aggregate_return_pointer_fact ...` rows. C and LLVM tests cover fact consumption and missing-fact conservative lowering for direct locals, aggregate field paths, aggregate aliases, and aggregate-return pointer fields. | LLVM defaults bare scalar pointer dereferences to unordered atomics unless a live `local_storage` fact or syntactic `&local` proves locality. Scalar and aggregate pointer parameter call-site summaries, scalar pointer-return summaries, global AST fallback proofs, aggregate-return AST summaries, and aggregate-alias write proofs are retired. The remaining local aggregate-alias map may expose only an already consumed MIR backing-field fact; it cannot create a storage proof. Direct local aggregate and aggregate-return provenance remain separate. |
| C backend global/race lowering helpers | `src/lower_c_global.zig` routes direct global scalar, array, and field accesses through race helpers or relaxed C atomics. Examples include `appendGlobalLoadExpr` (`src/lower_c_global.zig:142-150`), `appendGlobalStorePrefix` (`src/lower_c_global.zig:153-162`), `globalAssignmentTarget` (`src/lower_c_global.zig:176-183`), and array/member global access helpers (`src/lower_c_global.zig:219-242`, `src/lower_c_global.zig:270-315`). The Phase 4 C slice adds `src/lower_c_emitter.zig` MIR consumers such as `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, `applyMirPointerProvenanceForIndexAssignment`, `applyMirAggregatePointerFieldFactsAtSource`, `applyMirAggregatePointerFieldFactsForSubjectAtSource`, `applyMirPointerProvenanceInvalidationsAtCall`, and `derefAccessLowering`. | Direct global helper logic still keys from AST/global type information and `GlobalInfo`. For direct pointer-like locals, direct pointer-local copies from live global-backed locals, direct raw-many local `.offset(0)` transfers, direct fixed local pointer-array elements, direct aggregate pointer-field destination reads, constant-index direct aggregate pointer-array element destination reads, and direct aggregate `field_path` rows for covered direct struct-literal initializers, whole-aggregate and nested aggregate member struct-literal reassignments, field assignments, pointer-array element assignments, and same-struct aggregate copies, C consumes `Function.pointer_provenance_facts` at local initializer, assignment, index-assignment, and call-invalidation source points. Fact-subject declaration recovery is centralized behind `mirPointerFactSubjectRecoveredType` and used only to confirm that a matched MIR fact still names a supported local storage shape. Direct fixed pointer-array element destination reads now stay MIR-owned: if the destination fact is absent, C leaves the destination provenance unknown instead of reconstructing it from backend-local array-element state. Bare scalar pointee deref loads/stores default to `mc_race_load_*` / `mc_race_store_*` (or relaxed `__atomic_*_n` for pointer-shaped pointees); only a live `local_storage` fact or a syntactic `&local` keeps the plain path, and `unknown`/invalidated facts fall back to the race-tolerant default. The raw-many offset deref temp path delegates scalar loads through `emitRaceLoadTempFromPointerTemp`; pointer-member scalar fields, nested pointer-member scalar chains, slice scalar indexes, unproven pointer-to-array scalar indexes, scalar fields reached through pointer-backed indexed aggregate storage, and nested scalar member chains rooted in pointer-backed indexed aggregate storage also use race-tolerant load/store paths. Bare struct/fixed-array aggregate value copies through unproven pointer derefs, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, indexed and nested indexed aggregate fields, aggregate slice storage, and unproven pointer-to-array aggregate storage now lower recursively to race-tolerant scalar/pointer leaves where every leaf is supported; unsupported union-like leaves still fail closed. | `src/lower_c_inspect.zig:455-492` prints `lower ordinary_access`, `lower race_backend`, `lower race_semantics`, `lower c_ub`, and `lower racing_load_semantics` rows for direct global inspection. C emission also prints non-semantic `/* mir pointer_provenance consumed ... */` comments for the narrow facts it consumes, including `field=...` and `element=N` for aggregate field and array element rows. | C consumes MIR `elided_bounds`, `range_facts`, and now the narrow direct pointer-like local/direct-copy/direct raw-many zero-offset/direct fixed pointer-array element/direct aggregate pointer-read/direct aggregate `field_path` subset of `PointerProvenanceFact` for scalar deref load/store decisions. Conservative scalar lowering also covers call/member/index pointers, direct raw-many offset deref temps, pointer-member scalar fields, nested pointer-member scalar chains, direct/nested pointer-member aggregate fields, proven-local pointer-member aggregate copies, slice scalar indexes, unproven pointer-to-array scalar indexes, indexed aggregate scalar fields, nested indexed aggregate scalar member chains, recursive indexed and nested indexed aggregate field value copies, recursive aggregate whole-element value copies, and recursive struct/fixed-array aggregate pointer derefs when locality is not proven; broader race/global helper decisions remain outside typed pointer-provenance facts. |

The latest bounded call migration gives all accepted explicit-trap reasons exact
MIR identities and `never` results. Sema validates exact reason shape, and C/LLVM
no longer parse the reason independently when selecting the runtime trap helper.
LLVM statement emission and divergence classification share `trapHelperForCall`,
so both control-flow consumers map the MIR identity to the runtime helper through
one path. Missing or stale identities fail MIR admission. This closes
explicit-trap reason classification; broader expression typing, representation,
pointer-provenance, and typed-HIR/MIR workstreams remain open.

The latest bounded expression-type migration gives every runtime assert a
complete canonical MIR-owned `bool` condition fact. Both backends require it
before condition lowering, and LLVM no longer uses backend-local `exprType` for
this statement family. Missing facts fail generic MIR admission and stale
complete non-`bool` facts fail backend admission. This closes runtime-assert
condition typing only; broader expression typing and typed-HIR/MIR remain open.

Ordinary declared direct calls now carry complete MIR-owned result and fixed
argument types. Function-pointer and closure calls carry one complete
MIR-owned callee signature. Checked C uses it for closure dispatch and indirect
result typing; LLVM also uses it for indirect-call parameter emission. Variadic
tails remain explicitly targetless. Missing direct or indirect facts fail MIR
admission, and stale direct complete types or malformed stale indirect
signatures fail backend admission. Exact dynamic-dispatch typing and broader
expression typing remain open.

Target-typed `atomic.init(value)` now carries an exact MIR-owned call identity
and complete payload/result types for local and global initialization. Each pair
has a unique owner/index group, and both backends validate every matching group
before extracting the confirmed value operand. Missing facts reject prebuilt
MIR, stale complete types fail backend admission, and the former C/LLVM
spelling-based initialization classifiers are retired. Atomic member operations
remain covered by their separate receiver-derived payload facts; broader
expression typing and typed-HIR/MIR remain open.

Every MIR `target_type` instruction now also carries the complete source-level
type syntax. Generic target-type admission compares that syntax with each
prebuilt fact, in addition to source location, owner/index, and runtime
representation. A stale complete fact is therefore classified before C or LLVM
lowering; the backends preserve their existing unsupported-emission error
surface while no longer decide whether the fact is stale.

### Grouped expression result authority

User-source grouped expressions carry their own span-identified
`expression_result` row. C's `operandEmitType` and LLVM's `exprType` consume
that outer fact; recursive inspection of the inner expression is only a
stale-fact check. Compiler-generated zero-span groupings retain the bounded
construction-derived fallback because they cannot be keyed to source facts.
The MIR, C, and LLVM regressions remove or retarget exactly the `(value)` row,
so neither backend can restore outer result typing from the grouped AST.

This is a bounded closure inside `c-expression-type-inference` and
`llvm-expression-type-inference`, not closure of broader computed-expression
typing.

The same rule now covers grouped direct calls and C's grouped result-category
queries for arrays, slices, enums, tagged unions, `Result`, nullable values,
pointers, structs, booleans, and condition operands. Their inner call or type
classification may reject a stale outer fact but cannot supply the result when
the outer source fact is absent. Exact `(make())` MIR/C/LLVM tests protect this
boundary; zero-span generated expressions remain the only fallback.

### Source block expression policy

User-source block expressions also carry a span-identified
`expression_result` row. LLVM's admitted block-expression lowering consumes
that row and rejects a missing or stale fact. The C backend does not currently
admit block expressions as values: it returns its stable
`UnsupportedCEmission` diagnostic instead of recursively inferring a result
type. This is an explicit T2 disposition, not backend parity for syntax support:
the semantic owner is MIR wherever the syntax is admitted, while an unsupported
consumer must diagnose rather than guess.

### Boolean expression result authority

Source boolean literals, comparison/logical binaries, and logical negation use
their complete MIR `expression_result` row when C decides whether boolean
emission is required. The AST operator remains a stale-fact sanity check, not
the authority. LLVM consumes the same result row through `exprType`. Generated
zero-span nodes retain their construction-derived category because they cannot
be matched to source facts. Exact comparison-result MIR/C/LLVM removal and
retargeting tests gate this bounded T2 slice.

### Semantic inference family register

This register is the Phase 1 gate for backend semantic inference. Each row names
one inference family that can affect lowering semantics. The inventory checker
requires the row and its code anchors to remain present. Closing a family means
either migrating it to typed facts / MIR-owned state, or documenting it as an
accepted conservative fallback with missing-fact or diagnostic evidence.

Current C call-expression source typing quarantine: `lower_c_convert` and
`lower_c_call` no longer expose expression-source-type callbacks. Variadic
direct-call tail argument type selection now consumes owned MIR
`direct_call_argument` facts. Pointer-to-`paddr` target casts for sequenced temps
are handled by the shared C target-expression emitter instead of the call helper.
Source array/slice base typing, including indexed-member element typing,
indexed-field lookup, slice `.len` receivers, and for-loop iterable stale-fact
checks, now requires the source-spanned base's own `expression_result`;
recovered array/slice/operand shape is only a stale-fact check,
generated-node fallback, or exact-gated `__destr*` tuple-destructure synthetic
base fallback. Source
member-field, pointer-member-path, race-tolerant aggregate receiver, and
dyn-dispatch receiver base typing now requires the source-spanned member
base's own `expression_result`; recovered operand/call/member shape is only a
stale-fact check, generated-node fallback, or exact-gated `__destr*` tuple-destructure
synthetic base fallback. Dyn-coercion vtable source typing is MIR-owned through
`dyn_coercion_source`; C operand/call typing remains only for existing-dyn
pass-through detection, not for constructing new vtable wrappers.
Pointer-to-`PAddr` target casts consume
`paddr_coercion_source` for target-typed unsafe coercions and
`explicit_cast_source` for explicit casts; a focused C regression removes the
coercion source fact from `raw.store(ptr, ...)` and requires prebuilt-MIR
admission to fail before source typing can be reconstructed. The remaining
fallback for generated `PAddr` coercion source typing is explicit and
zero-span-guarded through the shared generated source-type helper. By-value aggregate
member copy source typing now consumes the member expression's
`expression_result` fact, with a same-struct nested member-copy regression that
removes that fact and requires prebuilt-MIR admission to reject before C can
reconstruct the aggregate source type. Direct aggregate-copy identifier sources
now reuse `identTypeForEmissionRecovered`, so source-spanned identifiers require
their own `expression_result` before the aggregate-copy path treats a local's
declared struct type as a matching copy source.
Direct address-place typing follows the same boundary: `&ident` still takes
mutability from local/global declaration metadata, but the place type itself
must pass the identifier `expression_result` gate before C uses it as the
address pointee.
Pointer-provenance shape classifiers follow the same rule for source-spanned
identifier bases: direct aggregate-member roots, fixed pointer-array bases,
raw-many bases, and direct pointer-local copy expressions recover local/container
shape through `identTypeForEmissionRecovered` before consuming or propagating a
MIR pointer-provenance fact.
Direct identifier assignment provenance updates also use that identifier gate
before deciding whether the target is a pointer-like local, aggregate local, or
fixed pointer-array local.
MIR pointer-provenance fact-subject declaration recovery is centralized behind
`mirPointerFactSubjectRecoveredType` and remains a mechanics check that the
already matched fact subject still denotes a currently supported local storage
shape.
Nullable source expression typing now consumes the expression's
`expression_result` fact when the expression is not a call, cast, or grouped
wrapper with its own typed row; nullable local declaration recovery is named and
guarded as a generated-only fallback.
Result and nullable `switch`/`if let` subject materialization now consumes the
already-required MIR subject target type; the C switch helper no longer asks for
backend-local Result/nullable source-type inference to choose that subject type.
Array, slice, enum, tagged-union, Result, and nullable inferred locals now
use the common MIR-owned call-return path before validating the owned
`inferred_local` row; direct calls still enter that path through the verified
`direct_call_result` fact. Qualified
tagged-union constructor inferred locals
consume the existing MIR-owned `qualified_union_result` fact instead of falling
back to tagged-union source-type inference. The C emitter no longer keeps
per-family `arrayReturnTypeForExpr`, `resultTypeForExpr`, `enumReturnTypeForExpr`,
`nullableReturnTypeForExpr`, or `taggedUnionReturnTypeForExpr` wrappers; direct
call result typing goes through the shared MIR-owned helper. The now-unreferenced
private C-infer `sliceReturnTypeForIndexBase`, array/enum/nullable return, and
Result expression classifiers have been removed rather than retained as dormant
backend-local semantic fallbacks.
The old recursive source-type fallback is retained only for
compiler-generated zero-span bases.
Direct slice-call index bases now use the access helper's MIR fact path:
complete `expression_result` rows when present, and MIR-owned
`direct_call_result` for direct-call bases; `lower_c_infer` no
longer exposes public slice/array/enum/nullable/tagged-union/Result call
return-type classifier helpers that are only used inside the infer module. The
last private slice-call wrapper has also been inlined at its only call site, so
the remaining slice-call path uses the common call-result query directly. The
private tagged-union call wrapper has likewise been folded into the single
public tagged-union expression query, leaving the qualified-union MIR fact and
common call-result query as the only call-specific inputs for that path. The
private enum-call wrapper has also been inlined into the enum value query, so
enum-valued calls use the same common call-result query before checking enum
identity. The enum variant-path wrapper has also been removed; `Enum.variant`
now reads the MIR-owned `enum_variant_path_result` row directly from the enum
value query. Boolean identifier classification now uses the same operand type
query as member and index boolean checks, retiring the separate identifier-only
helper. That shared operand-bool wrapper has also been inlined into the boolean
classifier, leaving `operandEmitType` as the single local query before checking
the bool storage type. The source-expression bool wrapper and its binary-op
predicate have also been folded into the boolean classifier, so user-source
boolean-producing syntax reaches one local MIR `expression_result` check. The
duplicate no-local-fallback identifier type helper has been merged into the
single identifier source-type query because both paths already reject shadowed
locals without a source type before considering globals. The
enum-identifier helper has likewise been folded into the shared identifier
source-type query plus enum-type check, reducing the C expression inference
helper surface without changing the registered fallback boundary. The unused
generic enum-expression wrapper has been removed; remaining callers use the
emitter's value-expression or type-level enum query directly. The enum
value-expression query has now moved out of `lower_c_infer` as well; it reuses
the emitter's `operandEmitType`, call-return facts, and MIR
`expression_result` rows instead of expanding the shared inference helper
surface. The array-expression query has also moved out of `lower_c_infer`;
numeric index typing now asks for the index expression's own MIR-backed operand
type, while the emitter's remaining array-shape helper is bounded to array
emission mechanics and still checks source member/index/deref results against
`expression_result`. The struct-name expression query has likewise moved out of
`lower_c_infer`; the remaining emitter helper only maps an already MIR/operand
authorized type to the C member-access shape. The condition-operand query has
also moved out of `lower_c_infer`; flow lowering now gets its operand type from
the emitter's MIR-backed operand, call-result, numeric, and literal
`expression_result` queries. The deref-pointee query has moved out of
`lower_c_infer`; numeric dereference classification now uses the dereference
expression's own MIR-backed result type, while the emitter's remaining pointee
helper is bounded to dereference emission mechanics. The boolean expression
query has also moved out of `lower_c_infer`; boolean local initialization now
uses the emitter's MIR-backed expression result checks directly. The cast-result
wrapper has also been inlined into the only
pointer-deref cast query, leaving the shared explicit-cast target helper plus
the existing `expression_result` stale-fact check as the local authority. The
tagged-union expression query has also moved out of `lower_c_infer`; switch
subject fallback now uses the emitter's `qualified_union_result`, call-result,
operand, cast-target, and grouped `expression_result` checks directly. The
slice expression/base query has also moved out of `lower_c_infer`; slice
emission now keeps the call-return, operand-derived zero-span, and
`expression_result` stale-fact checks local to the C emitter instead of exposing
them as shared backend semantic helpers. The
compound numeric-expression missing-fact predicate has likewise been folded into
the numeric result admission path, so source compound numeric expressions have a
single local `expression_result` requirement. The optional numeric result-fact
wrapper has also been folded into the numeric emission classifier, so direct
numeric values and compound numeric expressions now share one local
MIR-result-fact admission path. That numeric emission classifier has now moved
out of the retired inference module as well; the C emitter owns the remaining
emission-shape recursion while consuming MIR `expression_result` and
`explicit_cast_target` rows for source-spanned values. The final operand/source
identifier helper has also moved into the C emitter; `lower_c_infer` is now
deleted, and reintroducing that module fails inventory unless it is explicitly
reclassified.
Direct-call index lowering now queries MIR-owned base facts inside
`lower_c_access` for both array and slice base typing, instead of
access-context callbacks named as slice/array return-type classifiers.
Direct-call index address lowering also queries that base fact once
per address expression before choosing slice or fixed-array emission mechanics.
Unary operands in sequenced comparison conditions now follow the same
source-expression rule: source-spanned unary expressions must consume their own
MIR `expression_result` row and use the recursively recovered operand type only
to reject stale rows; zero-span generated nodes keep the bounded fallback.
Array-valued dereference queries now use the same source-expression rule:
source-spanned `ptr.*` array results consume their own MIR `expression_result`
row before fixed-array index lowering can use them, while zero-span generated
dereferences keep the bounded pointee fallback.
Source-spanned address-of pointee queries now also consume the address
expression's own MIR `expression_result` row directly instead of routing through
the generic operand helper; zero-span generated address expressions keep the
bounded addressed-operand fallback.
Struct-name classification for source member/index results now reads the
member/index expression's own MIR `expression_result` row directly; zero-span
generated member/index nodes keep the bounded operand fallback.
Array-shape classification for source member/index results follows the same
rule and reads the member/index expression's own MIR `expression_result` row
directly before fixed-array lowering uses it.
Pointer-shape classification for source member results also reads the member
expression's own MIR `expression_result` row directly; zero-span generated
members keep the bounded operand fallback.
Boolean-shape classification for source member/index results likewise reads
the expression's own MIR `expression_result` row directly; identifiers and
zero-span generated nodes keep their bounded declaration/operand paths.
Source-spanned cast expressions used as dereference bases now require both the
MIR `explicit_cast_target` and the cast expression's own matching
`expression_result` row before C recovers a pointer-like pointee; generated
zero-span casts keep the bounded syntactic target fallback.
Source member/index expressions used as dereference bases now also read their
own MIR `expression_result` row directly before C recovers a pointer-like
pointee; generated zero-span nodes keep the bounded operand fallback.
Source member/index expressions used as sequenced comparison operands now read
their own MIR `expression_result` row directly as the operand width/type;
generated zero-span nodes keep the bounded operand fallback.
LLVM source cast expression typing now requires the cast expression's own
`expression_result` row to match the MIR `explicit_cast_target`; the target row
alone is no longer sufficient for `exprType(.cast)`.
LLVM source member/index expressions used as comparison operands now read their
own MIR `expression_result` row directly in `comparisonOperandType`, matching
the C sequenced-comparison operand rule.
LLVM source binary expression typing now also reads the binary expression's own
MIR `expression_result` row directly; operand-derived result inference remains
limited to generated zero-span nodes.
LLVM source unary expression typing follows the same direct `expression_result`
rule; generated zero-span unary nodes keep the bounded operand fallback.
LLVM source float literal expression typing now reads the MIR `float_literal`
target fact instead of returning no expression type.
LLVM source char literal expression typing now reads the MIR `char_literal`
target fact.
LLVM source string literal expression typing now reads the MIR `string_literal`
target fact.
LLVM source enum literal expression typing now reads the MIR `enum_literal`
target fact.
LLVM source null literal expression typing now reads the MIR `null_literal`
target fact.
LLVM source struct literal expression typing now reads the MIR `struct_literal`
target fact.
LLVM source void literal expression typing now reads the MIR `expression_result`
target fact.
LLVM identifier expression typing, expression-result stale-fact checks, and
comparison member/index operand typing now share the same `isSourceSpan`
source/generated boundary instead of open-coded line/column tests; direct checks
in those paths are exact-zero gated.
C nullable/tagged-union grouped typing, generated nullable-local recovery, and
boolean expression classification now use the same `isSourceSpan`
source/generated boundary; the retired localized line/column checks and their
shared-gate replacements are exact-gated.
C generated `PAddr` recovery, numeric result classification, condition operand
typing, slice result/base typing, cast result typing, and operand member/index
typing now use the same shared source/generated boundary; localized old
line/column checks in those paths are exact-gated.
C identifier recovery, member-base typing, array/pointer/deref/struct/call
type queries, source member/index/slice/grouped typing, and generated recursive
source-type fallback also use the shared source/generated boundary; their
retired localized checks are exact-gated.
C unary-result generated fallback, member result generated fallback, dyn
pass-through typing, enum grouped typing, array/slice base typing, aggregate
member-copy generated fallback, and MIR target-type fact zero-span guards now
use the same shared source/generated boundary. `lower_c_emitter.zig` has no
remaining direct `expr.span.line` / `expr.span.column` source-boundary checks;
that zero count is exact-gated.
The remaining C zero-span recursive source-type fallback is centralized behind
`generatedExprSourceTypeForEmission` and exact-count-gated from array/slice,
member-base, aggregate member-copy source, and generated `PAddr` recovery paths.
LLVM mirrors the same source/generated boundary through the shared
`isSourceSpan` predicate inside `exprType`; direct line/column source checks for
that expression-type switch are exact-zero-gated. LLVM aggregate member-copy
source typing now has the same explicit boundary through
`aggregateCopyMemberSourceTypeForEmission`: source spans consume
`expression_result`, while generated zero-span mechanics may still delegate to
the existing `exprType` fallback.
LLVM null-literal expected-type selection, `switch`/`if let` subject facts,
`try` operand facts, contextual target-type helpers, struct-literal
construction, generated direct-call dispatch, and generated `Result`
constructors now use the same `isSourceSpan` boundary. The retired direct LLVM
line/column checks for those paths are exact-gated.
LLVM `callExpressionType` and `callReturnType` now cache the MIR call-target
kind once per helper before checking migrated call-result branches, reducing
repeated fact-table scans on the expression typing hot path. The remaining
direct branch lookups and the new local `call_kind` gates are exact-counted.
LLVM `emitBuiltinValueCall` now applies the same pattern to value emission:
declassify, assume-noalias, phys, raw-load, varargs, and raw-ptr dispatch share
one MIR call-target lookup for the call span. The retired repeated lookups and
expanded local `call_kind` gates are exact-counted.
LLVM `emitBuiltinVoidCall` now applies the same pattern to void emission:
raw-store, cpu-pause, and fence dispatch share one MIR call-target lookup for
the call span. The reduced direct lookup count and the local raw-store /
cpu-pause / fence `call_kind` gates are exact-counted.
C statement-level lowering now follows the same authority shape for its
raw-store, cpu-pause, fence, and explicit-trap statement paths. `emitRawStoreStmt`,
`emitCpuPauseStmt`, and `emitFenceStmt` cache the call span's MIR
call-target kind in a local `call_kind`, while `emitNeverExprStmt` delegates
explicit-trap helper selection to `trapHelperForCall`. The old direct
statement-level `call.callee.*.span` checks for those paths are exact-zero
gated, and the new helper/cache counts are exact-counted.
C call-result typing now uses the same cached-kind shape. `callReturnTypeForCall`
looks up the MIR call-target kind once, reuses it for migrated enum-raw,
const-get, DMA/domain, declassify, assume-noalias, raw-many-offset, raw-result,
and MaybeUninit result branches, and passes the confirmed kind into raw-result
and MaybeUninit helpers. DMA and arithmetic-domain inferred-local result typing
now route through `dmaResultReturnTypeForCall` and
`domainResultReturnTypeForCall` before consuming `.dma_result` or
`.domain_result`, so those result shapes remain tied to MIR identities instead
of receiver/type spelling. Enum-raw and const-get inferred-local result typing
now route through `enumRawResultReturnTypeForCall` and
`constGetResultReturnTypeForCall` before consuming `.enum_raw_result` or
`.const_get_result`, keeping representation and fixed-index result shapes tied
to MIR result rows. Declassify and assume-noalias inferred-local result typing
now route through `declassifyResultReturnTypeForCall` and
`assumeNoaliasResultReturnTypeForCall` before consuming `.declassify_result` or
`.assume_noalias_result`, keeping capability-sensitive result typing out of the
ordinary call fallback. Raw-many offset inferred-local result typing now routes
through `rawManyOffsetResultReturnTypeForCall` before consuming
`.raw_many_offset_result`, keeping pointer result typing tied to MIR rows
instead of receiver spelling or alias reconstruction. Reflection, byte-view,
bitcast, scalar/domain conversion, and physical-address inferred-local result
typing now route through `simpleMirResultReturnTypeForCall`, so these simple
result facts are named as MIR result admission rather than inline call-return
shortcuts. Ordinary direct-call inferred-local result typing now delegates to
`directCallReturnTypeForCall`, keeping `.direct_call_result` consumption and
declared-return validation in one named helper. Closure-call inferred-local
result typing now delegates to `closureCallReturnTypeForCall`, keeping closure
return extraction out of inline call-result fallback logic. Function-pointer and
closure-signature indirect-call inferred-local result typing now delegates to
`indirectCallReturnTypeForCall`, keeping `indirect_call_callee` signature return
extraction out of inline fallback logic. Direct and grouped C call expression
typing now share `callExpressionResultTypeForEmission` before consuming the
source `expression_result` row, centralizing stale-row comparison and
generated-node fallback. Nullable and tagged-union grouped expression typing
uses the same `checkedExpressionResultTypeForEmission` helper, so source
`expression_result` stale-row checks and generated-node fallback are shared
across these grouped result paths. C condition grouped/unary result typing and
grouped source-type typing now use that same helper as well; the remaining
direct grouped stale-row checks are exact-gated mechanics paths. Grouped array
typing also uses the shared helper before projecting array shape from the
validated result type. Grouped slice-result, generated slice-base, and operand
storage typing use `checkedStorageExpressionResultTypeForEmission`, preserving
the storage-type stale-row comparison while exact-zero-gating the old direct
grouped stale-row inventory. C dyn pass-through's generated fallback now uses
`generatedExprSourceTypeForEmission` instead of hand-rolling a zero-span
`exprSourceTypeForEmission` recursion, keeping source-spanned dyn coercion
authority fail-closed. C grouped enum-name typing is now named behind
`groupedEnumNameForValueExpr`, keeping source `expression_result` authority and
zero-span generated recursion separated. C grouped bool, pointer,
deref-pointee, and struct-name classification follow the same named-helper
shape, so the generic inline grouped fallback is exact-zero-gated. C bool
literal, storage, binary, unary, and source `expression_result` classification
are now named helpers as well, retiring the old inline bool classifier shapes.
`storageOrExpressionResultTypeForEmission` centralizes the generated
operand/source `expression_result` split for bool-storage, numeric deref,
condition member/index, array member/index, pointer member, deref-pointee
member/index, and struct-name member/index queries; the remaining inline case is
the special pointee-derived array-deref check. That special case is now named as
`arrayDerefResultTypeForEmission`, preserving the zero-span pointee fallback and
source `expression_result` stale-row check while exact-zero-gating the last
inline `const ty = if (!isSourceSpan(...))` inventory path. The old repeated
return-type direct call-span lookups are exact-zero gated. C explicit-cast
result typing is now named behind `checkedCastResultTypeForEmission`; generated
casts keep their target type, while source casts must match both
`explicit_cast_target` and `expression_result` rows before C uses the result
type. C generated member-result recovery is now named behind
`generatedMemberResultTypeForEmission`, so source members remain
`expression_result` gated while zero-span generated state-machine members keep
their declaration fallback. Generated aggregate member-copy source typing now
uses named fallback helpers as well: source expressions still require
`expression_result`, while generated expressions recover storage/source type
only through the generated-only path. Nullable expression typing now follows the
same shape: source expressions consume `expression_result`, generated nullable
fallbacks live behind `generatedNullableExpressionTypeForEmission`, and nullable
candidate filtering is centralized in `nullableTypeFromCandidate` for call,
cast, null-literal target, generated-local recovery, inferred-local call-result
predicates, and try-operand predicates. Value-optional payload filtering is
centralized in `valueOptionalPayloadFromCandidate` for try-replacement
predicates, value-optional coercion, nullable representation selection, and
race-tolerant aggregate classification; value-optional pass-through detection
also reuses `nullableTypeFromCandidate` instead of reopening the nullable kind.
Nullable switch and if-let subject admission now uses the same nullable
candidate helper for subject gates and nullable-representation extraction from
MIR facts.
Result family filtering is centralized
in `resultTypeFromCandidate` for switch dispatch, if-let admission, and
inferred-local call-result predicates. Array, slice, and enum call-result
predicate filtering is now named behind `arrayTypeFromType`,
`sliceTypeFromCandidate`, and `enumTypeFromCandidate`; enum switch dispatch and
generic-switch enum-name selection reuse the same enum candidate helpers, and
`enumNameForType` delegates to that same `enumNameFromCandidate` filter.
Struct name filtering follows the same pattern through
`structNameFromCandidate` for known-struct and direct aggregate-copy paths.
Generated-member fallback and aggregate field lookup now reuse
`structTypeNameFromType` for struct and pointer-to-struct name selection instead
of carrying duplicate inline kind switches.
Pointer expression classification now uses `pointerTypeFromCandidate` for
member-base, direct/member expression, and grouped pointer checks instead of
repeating inline `.pointer` tests.
Direct-address inferred-local emission now uses `pointerNodeFromCandidate` to
gate and unpack the MIR-owned pointer result type instead of destructuring the
`.pointer` kind inline.
Slice access fallback for `.ptr`/`.len` now reuses
`sliceTypeFromCandidate` instead of carrying a separate inline `.slice` test.
Slice `.len` member emission also reuses that slice candidate helper for the
base gate instead of directly reopening the alias-resolved `.slice` kind.
Slice call-result typing now reuses `sliceTypeFromCandidate` for call-return
slice gates instead of checking the direct `.slice` kind.
Nullable payload extraction now goes through `nullablePayloadFromCandidate`;
value-optional payload checks and race aggregate recursion reuse that helper
instead of directly unpacking `.nullable` in the race-lowering classifier.
Nullable representation selection reuses the same nullable payload helper and
`dynTraitNameFromCandidate` instead of directly unpacking `.nullable` and
checking the child `.dyn_trait` kind.
Raw-many pointer local recovery now uses `rawManyPointerTypeFromCandidate`
instead of an inline `.raw_many_pointer` test.
Indexed member-field element recovery now uses
`arrayOrSliceElementTypeFromCandidate` instead of an inline array/slice kind
switch.
Indexed member-path typing now uses the same helper through `indexedElementType`
instead of carrying a second inline array/slice child switch.
For-loop stale-fact checks reuse `arrayOrSliceElementTypeFromCandidate` when
comparing the MIR-owned `for_element` fact against the iterable child type.
For-loop element planning reuses `arrayTypeFromType` for the fixed-array
iterable gate before selecting the C element plan.
Default local initialization reuses `arrayTypeFromType` for the array
aggregate-zero initializer gate instead of checking the declared type's `.array`
kind inline.
Index expression stale-fact checks reuse the same helper when comparing a
MIR-owned `expression_result` row against the base element type.
Direct-address index place recovery now reuses `arrayTypeFromType` instead of
reopening an alias-resolved `.array` test in the place-analysis body.
Dyn-target and pass-through filtering now uses `dynTraitNameFromCandidate` for
both direct `*dyn Trait` and nullable dyn-trait targets instead of duplicating
that kind switch.
Dynamic dispatch receiver trait selection now uses
`dynDispatchTraitNameFromCandidate` for direct dyn and pointer-to-dyn receiver
shapes instead of inlining that switch in `dynCalleeTrait`.
Race aggregate classification also reuses `dynTraitNameFromCandidate` for the
dyn-trait aggregate gate instead of directly checking `.dyn_trait`.
Pointer-value dyn coercion now uses `dynPointerSourcePointeeFromCandidate` for
existing-dyn pass-through and pointer-pointee selection. That helper now reuses
`dynTraitNameFromCandidate` and `pointerNodeFromCandidate` instead of directly
checking `.dyn_trait` / `.pointer`.
Tagged-union call
candidate typing follows the same split through
`taggedUnionCallCandidateTypeForEmission`: qualified constructors consume
`qualified_union_result`, ordinary calls use the shared call-result path, and
both pass through `taggedUnionTypeFromType` before C treats them as tagged
unions. Tagged-union switch dispatch and inferred-local call predicates reuse
that same candidate filter instead of checking the tagged-union registry
directly.
C assume-noalias provenance checks now mirror the LLVM predicate shape:
`isMirAssumeNoaliasCall` uses `mirHasCallTargetKindAt(.assume_noalias, ...)`
instead of comparing a raw call-target lookup. The retired C direct
assume-noalias comparison is exact-zero gated.
C raw-load float classification now uses the same predicate shape:
`callResolvesToFloat` gates the raw-load special case with
`mirHasCallTargetKindAt(.raw_load, ...)` and still reads the MIR-owned
`raw_result` type fact before deciding whether the expression is floating-point.
The retired direct raw-load comparison is exact-zero gated.
C bind emission now uses `mirHasCallTargetKindAt(.bind, ...)` before consuming
the MIR-owned `.bind` target-type fact. The stale fact guard remains in place,
and the old direct bind comparison is exact-zero gated. With this slice, C
backend `call.callee.*.span` / `node.callee.*.span` call-target comparisons in
the emitter's named statement/value paths have been reduced to predicates or
local cached `call_kind` decisions.
Bind target closure-shape filtering now uses `closureNodeFromCandidate` in
`bindEmitPlan` instead of directly checking and unpacking `.closure_type`.
Race aggregate classification also reuses `closureNodeFromCandidate` for the
closure aggregate gate instead of directly checking `.closure_type`.
LLVM generic call emission now caches the call span's MIR target kind before
drop/forget rejection and bind value emission. The bind value path consumes the
same cached `call_kind` and MIR-owned `.bind` target-type fact, while the old
repeated direct `mirCallTargetKindAt(span) == .bind` check is exact-zero gated.
LLVM Result-constructor value emission now caches the call span's MIR target
kind before selecting `mir.resultConstructorFactInfo`; generated zero-span
mechanics keep the explicit generated constructor path. The retired inline
`mirCallTargetKindAt(span)` constructor lookup is exact-zero gated.
LLVM raw call classification now receives the already-confirmed MIR raw
call-target kind from raw-store/raw-load/raw-ptr callers. `rawCallInfo` no
longer rescans the call span internally, and the old no-kind helper surface is
exact-zero-gated.
LLVM const-get classification now receives the already-confirmed `.const_get`
call-target kind from value-emission and expression-typing callers.
`constGetCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated.
LLVM enum-raw classification now receives the already-confirmed `.enum_raw`
call-target kind from value-emission and expression-typing callers.
`enumRawCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated. Its source/result target-type
admission now goes through `enumRawTypesForEmission`, leaving only one
exact-gated helper read for `.enum_raw_source` and `.enum_raw_result`. C
`value.raw()` emission now mirrors that target-type admission shape through its
own `enumRawTypesForEmission` helper.
LLVM domain-residue classification now receives the already-confirmed
`.wrap_residue` call-target kind from value-emission and expression-typing
callers. `domainResidueCallInfo` no longer rescans the call span internally,
and the old no-kind helper surface is exact-zero-gated. Its domain/result
target-type admission now goes through `domainTypesForEmission`, with the
payload row still required as part of complete domain-call admission.
LLVM arithmetic-domain op classification now receives the already-confirmed
domain call-target kind from value-emission and expression-typing callers.
`domainOpCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated. Its domain/payload/result/optional
interval target-type admission now goes through the same
`domainTypesForEmission` helper, leaving only one exact-gated helper read for
`.domain_type`, `.domain_payload`, `.domain_result`, and the interval row when
the MIR domain identity requires one.
C `wrap.residue()` emission now mirrors this target-type admission shape
through `residueTypesForEmission`; C serial/counter domain operation emission
uses `domainTypesForEmission` for domain/payload/result and the optional
interval row. The remaining `.domain_*` C reads are helper-admission reads,
not inline emission decisions. C inferred-local call-result typing routes MIR
domain identities through `domainResultReturnTypeForCall` before consuming
`.domain_result`, so wrap/Duration/Result result shapes are not reconstructed
from the AST in that path.
LLVM wrapping arithmetic classification now receives the already-confirmed
wrapping call-target kind from value-emission and expression-typing callers.
`wrappingCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated. Its left/right/result target-type
admission now goes through `wrappingTypesForEmission`, backed by the shared
`arithmeticCallTypesForEmission` triplet helper.
LLVM unchecked arithmetic classification now receives the already-confirmed
unchecked call-target kind from value-emission and expression-typing callers.
`uncheckedCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated. Its left/right/result target-type
admission now goes through `uncheckedTypesForEmission`, backed by the shared
`arithmeticCallTypesForEmission` triplet helper. Concrete LLVM
`.wrapping_*`/`.unchecked_*` target-type reads are exact-zero-gated. C
wrapping/unchecked call info now mirrors that triplet admission shape through
its own shared `arithmeticCallTypesForEmission` helper, and concrete C
`.wrapping_*`/`.unchecked_*` target-type reads are exact-zero-gated.
LLVM reduce-call classification now receives the already-confirmed reduce
call-target kind from value-emission and expression-typing callers.
`reduceCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated. Its slice/element target-type
admission now goes through `reduceTypesForEmission`, leaving one exact-gated
helper read for `.reduce_source` and `.reduce_element`. C `reduce.sum_*`
emission now mirrors that target-type admission shape through its own
`reduceTypesForEmission` helper; type-artifact collection retains its
source-only helper because it only pre-collects required generated C types.
LLVM scalar conversion classification now receives the already-confirmed
conversion call-target kind from value-emission and expression-typing callers.
`conversionCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated.
LLVM byte-view classification now receives the already-confirmed byte-view
call-target kind from value-emission and expression-typing callers.
`byteViewCallInfo` no longer rescans the call span internally, and the old
no-kind helper surface is exact-zero-gated.
LLVM reflection classification now receives the already-confirmed reflection
call-target kind from value-emission and expression-typing callers.
`reflectionCallInfo` no longer rescans the call span internally,
`reflectionCallValue` consumes the already-built info, and the old no-kind
helper/value call sites are exact-zero-gated.
LLVM bitcast and physical-address target-type helpers now receive the
already-confirmed `.bitcast` / `.phys` call-target kinds from value-emission and
expression-typing callers. `bitcastCallTargetType` and `physCallTargetType` no
longer rescan the call span internally, and the old no-kind helper call sites
are exact-zero-gated. LLVM bitcast then moved beyond the target-only helper:
value emission and expression-result queries now consume `bitcast_source` and
`bitcast_target` together through `bitcastTypesForEmission` /
`bitcastTypesForQuery`, and the old target-only helper is exact-zero-gated.
LLVM physical-address emission/query paths now consume `.phys_result` through
`physResultTypeForEmission` / `physResultTypeForQuery`, and the old
`physCallTargetType` helper is exact-zero-gated.
LLVM MMIO-map classification now receives the already-confirmed `.mmio_map`
call-target kind from value-emission and expression-typing callers.
`mmioMapCallInfo` no longer rescans the call span internally, and the old
no-kind helper call sites are exact-zero-gated.
LLVM raw-many-offset classification now receives the already-confirmed
`.raw_many_offset` call-target kind from value-emission, expression-typing, and
provenance callers. `rawManyOffsetCallInfo` no longer rescans the call span
internally, and the old no-kind helper call sites are exact-zero-gated.
LLVM MaybeUninit classification now receives the already-confirmed
MaybeUninit call-target kind from void-emission, value-emission, and
expression-typing callers. `maybeUninitCallInfo` no longer rescans the call span
internally, and the old no-kind helper call sites are exact-zero-gated.
LLVM atomic classification now receives the already-confirmed atomic
call-target kind from void-emission, value-emission, and expression-typing
callers. `atomicCallInfo` no longer rescans the call span internally, and the
old no-kind helper call sites are exact-zero-gated.
LLVM DMA classification now receives the already-confirmed DMA call-target kind
from void-emission, value-emission, and expression-typing callers.
`dmaCacheCallInfo` and `dmaBufCallInfo` no longer rescan the call span
internally, and the old no-kind helper call sites are exact-zero-gated.
LLVM varargs classification now receives the already-confirmed varargs
call-target kind from local-initializer, value-emission, and expression-typing
callers. `vaCallInfo` no longer rescans the call span internally, and the old
no-kind helper call sites are exact-zero-gated.
LLVM va_list local initializer paths now also cache the `init.kind.call`
operand and MIR call-target kind before admitting `va_start`, so the old direct
`init.kind.call.callee.*.span` lookup and no-cache
`vaCallInfo(init.kind.call, kind)` form are exact-zero gated.
LLVM MMIO-access classification now receives the already-confirmed MMIO access
call-target kind from void-emission, value-emission, and expression-typing
callers. `mmioAccessInfo` no longer rescans the call span internally, and the
old no-kind helper call sites are exact-zero-gated.
LLVM assume-noalias provenance classification now uses the shared call-target
predicate instead of directly reading the call's fact row inside the provenance
helper. The old direct `assume_noalias` comparison is exact-zero-gated, leaving
the helper as a narrow predicate over an already MIR-owned call identity.
LLVM expression-statement lowering now caches the call statement's MIR
call-target kind once and reuses it for `drop` / `forget_unchecked` discard
dispatch and varargs statement dispatch. This keeps statement lowering tied to
the same MIR-owned identity while removing a duplicate fact-table lookup in the
statement path. LLVM discard statement emission now also admits the discarded
argument through `requireMirDiscardArgumentTypeForEmission`, so the
`.discard_argument` row uses the shared target-type emission helper rather than
a one-off fact-table read. LLVM inferred-local `try` payload validation now
also reads the operand through `requireMirTryOperandType`, matching normal
try-expression lowering and reducing the remaining direct LLVM `.try_operand`
fact-read budget. The expression-type query path now uses
`mirTryOperandTypeForQuery`, which delegates to the same helper while preserving
query-style `null` on unsupported or stale facts, so direct LLVM
`.try_operand` fact reads are exact-zero-gated. C inferred-local try payload
validation and try-hoist scan predicates now mirror that shape through
`mirTryOperandTypeForQuery`, so direct C `.try_operand` fact reads are also
exact-zero-gated. C `drop` / `forget_unchecked` discard emission now consumes
`.discard_argument` through `discardArgumentTypeForEmission`, making the C
discard target-type read a named admission helper. C physical-address emission
now consumes `.phys_result` through `physResultTypeForEmission`. C semantic
escape emission now admits `reveal` / `assume_noalias_unchecked` source/result
rows through `semanticEscapeTypesForEmission` wrappers. C bitcast value-temp,
local-init, and inferred-local lowering now admit source/target rows through
`bitcastTypesForEmission`. LLVM raw-memory and varargs call classification now
consume their complete target-type rows through `rawAddressTypesForEmission`
and `vaCallTypesForEmission`, and LLVM semantic-escape emission/query paths now
consume source/result rows through `semanticEscapeTypesForEmission` wrappers
instead of concrete direct fact reads. LLVM bitcast emission/query paths now
consume source/target rows through `bitcastTypesForEmission` /
`bitcastTypesForQuery`. LLVM physical-address emission/query paths now consume
`.phys_result` through `physResultTypeForEmission` /
`physResultTypeForQuery`.

| Family | Owner / source anchors | Current consumer | Migration status | Fail-closed policy |
|---|---|---|---|---|
| `c-expression-type-inference` | `src/lower_c_emitter.zig` MIR-backed operand, numeric, call-result, array/slice, deref, and source-type emission queries; retired `src/lower_c_infer.zig` module deleted and inventory-gated absent | C expression, aggregate, call, and deref emission | Registered backend inference. Qualified tagged-union constructor and enum variant-path result typing now consume MIR facts; backend declaration scans for those semantic types are retired. Typed member/index/slice/dereference, bounded direct address, and unary result queries use span-identified `expression_result` rows where the C classifier already has an independently recovered storage type. Array-valued member and index results now consume those rows directly in `arrayTypeForExpr`, rather than rewalking struct fields or prior array expressions; pointer-valued intermediate members likewise use their result facts in `exprIsPointer` to select C `->` lowering, and identifier bases in that operator-selection path now reuse the same identifier MIR fact gate. Source array/slice bases, including indexed-member element typing, indexed-field lookup, slice `.len` receivers, direct-call array/slice indexing, and for-loop iterable stale-fact checks, now require the source-spanned base's own `expression_result`; recovered array/slice/operand/direct-call-result shape is only a stale-fact check, generated-node fallback, or exact-gated `__destr*` tuple-destructure synthetic base fallback. Source member-field, pointer-member-path, race-tolerant aggregate receiver, and dyn-dispatch receiver base typing now requires the source-spanned member base's own `expression_result`; recovered operand/call/member shape is only a stale-fact check, generated-node fallback, or exact-gated `__destr*` tuple-destructure synthetic base fallback. Dyn-coercion vtable source typing is MIR-owned through `dyn_coercion_source`, and C/LLVM consume that fact instead of independently selecting the source type. Pointer-to-`PAddr` target casts consume `paddr_coercion_source` for target-typed unsafe coercions and `explicit_cast_source` for explicit casts; non-cast source expressions no longer use recursive source typing for that decision, missing `paddr_coercion_source` now has a focused C fail-closed regression, and generated `PAddr` coercion source recovery is exact-gated behind a zero-span helper. By-value aggregate member copy source typing consumes the source expression's `expression_result` and now has a same-struct nested member-copy missing-fact admission regression; direct aggregate-copy identifier sources also reuse the identifier `expression_result` gate before comparing local declared struct type; direct `&ident` place typing uses the same gate for pointee type while preserving local/global mutability metadata; direct pointer-provenance identifier classifiers for aggregate roots, fixed pointer arrays, raw-many bases, and pointer-local copies use the same gate before classifying local container shape; direct identifier assignment provenance updates use the same gate before classifying pointer-like locals, aggregate locals, or fixed pointer-array locals; nullable source expression typing consumes the source expression's `expression_result`; nullable local declaration recovery is exact-gated as a generated-only fallback because no source-keyed fact can identify those generated nodes. Result/nullable `switch` and `if let` subject materialization consumes the MIR subject type instead of backend-local result/nullable source-type inference. Array/slice/enum/tagged-union/Result/nullable inferred-local typing uses the common MIR-owned call-result emission path before checking `inferred_local` or family shape; direct calls still enter that path through `direct_call_result`; nullable call source selection uses the same path before checking the nullable shape; qualified tagged-union constructor inferred-local typing consumes `qualified_union_result`. The old C `callReturnTypeForExpr` entry point is retired and exact-zero-gated; source-spanned call/grouped-call queries go through `callResultTypeForEmission`, where the MIR `expression_result` row authorizes the value type and call-return mechanics only validate stale facts. LLVM mirrors the naming boundary: the old `callReturnType` helper is retired, statement/expression call-result mechanics go through `callResultTypeForEmission`, and source call expressions still require `expression_result` through `callExpressionType`. The old source-type recursion is limited to zero-span generated bases. By-value nested struct members now consume the intermediate result fact in `structTypeNameForExpr` and numeric-member inference instead of independently scanning that intermediate declaration; the emitter's operand query retains declaration comparison only to reject a stale fact. Numeric value expressions with source spans now require their complete `expression_result` row when the classifier has only an operand-derived storage type; generated zero-span nodes keep the bounded fallback because no source-keyed fact can identify them. Source grouped/unary/member/index/deref numeric classifiers now use the same rule instead of accepting operand-derived storage when their own source row is missing. Numeric binary inferred-local initialization now requires its complete `expression_result` row and uses operand recovery only to reject a stale row, rather than falling back when the row is absent. Sequenced comparison literals now obtain their contextual operand type from the literal's `expression_result`; C no longer recreates a default `u32` decision before sibling-width reconciliation. Fixed-array direct-call bases now consume MIR-owned expression/direct-call-result facts before C index lowering, so `make_matrix()[0]` becomes wrapper-array `.elems[...]` access rather than invalid C array subscripting. Raw-many offset return/deref typing consumes MIR result/element facts, and the recursive local/function-return receiver inference is retired. Ordinary declared direct-call result/fixed-argument typing and checked-MIR function-pointer/closure call signatures now consume complete MIR facts; declarations only confirm direct-call ABI/stale-fact equality. Direct address-of-deref pointer operands now use `operandEmitType`, so a source `&ptr.*` path requires `ptr`'s complete `expression_result` before C derives pointee mutability. Address-of facts are limited to the established local/mutable-global place family; other address shapes remain in the registered fallback boundary. The broader family still needs typed-fact/MIR migration. | Unsupported or unknown shapes return null/unsupported and must not invent a semantic fact. |
| `c-type-shape-classification` | `src/lower_c_info.zig` `localInfoFromType` / `globalInfoFromType` / `AggregateGlobalCShape`; `src/lower_c_shape.zig` shape helpers | C local/global model, race helper choice, aggregate-vs-scalar routing | Registered backend inference. MMIO-map nullable payload discovery now consumes the MIR payload fact instead of rebuilding `MmioPtr<T>` from the call type argument. C aggregate-global representation is an accepted internal target policy: the explicit shape matrix selects C aggregate initialization/access mechanics for arrays, slices, closures, dyn traits, `Result`, aggregate `MaybeUninit`, and declared aggregates. It does not select a source-level or external ABI. | Unknown aggregate/scalar/race-helper shapes must reject or use conservative recursive lowering. Missing migrated facts reject prebuilt MIR. |
| `c-abi-aggregate-lowering` | `src/lower_c_aggregate.zig` array/struct/tagged-union literal emitters; `src/sema.zig` `checkExternExportStructAbi`; `src/lower_llvm.zig` `cAbiExtension` | Internal aggregate values and ABI-shaped constructors; explicit C ABI boundary admission and scalar extension | Registered backend mechanics for internal aggregate construction. **Completed bounded T2 slice:** source struct literals carry a MIR-owned construction class distinguishing ordinary declared structs, `#[c_union]`, and packed-bits; declaration lookup remains a stale-fact/layout check rather than route authority. Explicit `extern "C"` declarations and unmarked exports reject every currently unclassified by-value family. Bare `extern fn` and `#[mc_abi]` exports remain backend-private. LLVM C ABI scalar definitions, declarations, and direct calls share target-aware extension attributes. | A missing or retargeted struct-literal construction class rejects checked MIR in both backends. Unsupported internal aggregate forms fail backend emission; `E_EXTERN_STRUCT_BY_VALUE` requires pointers/out parameters for unclassified C ABI values until per-target aggregate classification exists. |
| `c-call-target-classification` | `src/lower_c_call.zig` sequenced/bitcast/extern-nonnull call emitters plus MIR-gated semantic escapes; `src/lower_c_collect.zig` / `src/lower_c_emitter.zig` bind, reduction, and atomic-init consumers; `src/lower_c_builtin_emit.zig` enum raw consumer; `src/lower_c_arith.zig` / `src/lower_c_domain.zig` arithmetic-domain consumers; `src/lower_c_access.zig` const-get and raw-many offset consumers; `src/lower_c_mmio.zig` MMIO map/register consumers; `src/lower_c_emitter.zig` / `src/lower_c_try.zig` Result and nullable-try consumers; `src/lower_c_atomic.zig` / `src/lower_c_memory.zig` MIR payload and DMA consumers; `src/builtin_syntax.zig` builtin spelling classifiers; `src/lower_c_reflect.zig` MIR-gated reflection emission; `src/lower_c_convert.zig` MIR-gated conversion emission | C call emission and special builtin lowering | **MIR-owned; no longer in the backend AST-inference budget.** Closure bind, Result constructors, reductions, enum representation reads, arithmetic-domain calls, `const_get`, DMA calls, raw-many pointer offsets, MMIO mapping/register calls, bitcast, physical-address, reflection, byte-view, semantic escapes, atomic initialization/member operations, MaybeUninit, raw memory operations, varargs operations, and all six scalar/domain conversion operations use MIR call identities and complete facts. Conversion call-target result types are produced by MIR, with `try_from` represented as `Result<T, ConversionError>`, so neither backend falls through generic call inference for that identity. C reduction type-artifact collection now requires the same MIR reduction identity before consuming `reduce_source`, matching reduction emission. Residual AST use validates a MIR-confirmed callee shape, arity, symbol, field/layout, or ABI emission detail; it cannot select special lowering or upgrade an ordinary call. | Unknown call targets stay ordinary calls or unsupported; no provenance/range fact may be inferred from a call spelling. Missing, stale, or `.unknown` typed facts for migrated categories reject prebuilt MIR before emission. |
| `c-bounds-range-consumption` | `src/lower_c_emitter.zig` `requireMirBoundsFact`, `hasMirNoOverflowRangeFact`, `mirCheckElided` | C bounds checks, unchecked arithmetic, check elision | MIR-owned for current range/bounds/check-elision subset. | Missing/stale facts keep checks or reject prebuilt MIR. |
| `c-pointer-provenance-consumption` | `src/lower_c_emitter.zig` MIR provenance consumers and deref lowering | C pointer-mediated race lowering | MIR-owned for narrow direct subset; registered conservative fallback for broader scalar leaves. | Missing facts keep provenance unknown and use race-tolerant scalar lowering where supported. |
| `c-direct-global-race-helpers` | `src/lower_c_global.zig` direct global load/store helpers | C direct global scalar/array/member access | Registered direct-global backend inference. | Unsupported scalar helper widths fail closed; aggregate leaves recurse only through supported shapes. |
| `llvm-pointer-provenance-consumption` | `src/lower_llvm.zig` MIR-or-local-proof provenance consumers and race-tolerant deref lowering | LLVM pointer-mediated race lowering | MIR-owned for direct facts; one registered local-only proof remains outside MIR. | Missing facts default scalar derefs to unordered atomic unless positive local/raw/MMIO proof exists. |
| `llvm-expression-type-inference` | `src/lower_llvm.zig` `exprType` / `derefPointeeType`; shared `src/ast_query.zig` expression/call-shape queries | LLVM expression, call, deref, constructor, and MMIO emission | Registered backend inference. Closure bind and Result constructors now require MIR identities and contextual target types; constructors, contextual coercions/literals/aggregates, reduction elements/results, enum raw source/results, arithmetic-domain source/payload/result/interval types, const-get base/results/indexes, DMA buffer/payload/results, raw-many offset receiver/element/results, MMIO-map source/payload/results, MMIO register struct/storage/value/results, raw-memory address/payload/results, varargs cursor/payload/results, byte-view source/results, reflection target/results, conversion/bitcast/semantic-escape operations, atomic-init grouped payload/results, atomic/MaybeUninit member payloads, physical-address results, explicit casts, implicit single-pointer/slice const narrowing, qualified tagged-union constructors, enum variant paths, bounded direct function/data address results, and member/index/slice/dereference and unary/binary result queries obtain their migrated semantic types from MIR facts. Explicit source-cast expression typing now requires the cast's own complete `expression_result` to match `explicit_cast_target`, matching C's fail-closed cast result rule. Source identifier expression typing now requires the identifier's own complete `expression_result`, using LLVM's local/global/function tables only to reject stale rows; direct address-of-deref pointer operands reuse that path before LLVM derives pointee mutability for `&ptr.*`. Source member/index comparison operands now read their own complete `expression_result` directly in the comparison classifier instead of relying on a broader expression-type fallback. Source unary and binary expression typing now read their own complete `expression_result` directly; only generated zero-span nodes retain operand-derived result inference. Source float, char, string, enum, null, and struct literal expression typing reads MIR target facts; source void literal expression typing reads the MIR `expression_result`. Non-call source expression statements now also require their own `expression_result`, with `exprType` used only to reject stale facts before value emission. Switch and if-let source subjects share one `requireMirSubjectType` admission path for MIR fact lookup, stale-fact comparison, and nullable representation validation. LLVM `try` operand admission now shares the target-type emission helper: source operands require the `.try_operand` fact, and `exprType` only rejects stale rows. Binary inferred-local admission now requires a complete `expression_result` and checks it against the operand-derived expected type before comparing it to the owned `inferred_local` fact. Data-address facts remain limited to the established local/mutable-global place family; other address shapes retain their registered fallback boundary. Reduction result construction is determined by the MIR call identity and element fact; enum `.raw()` no longer derives receiver or repr types from LLVM-local expression/enum lookup; arithmetic-domain calls no longer resolve aliases or rebuild `wrap`/`Duration`/`Result` types; `const_get` no longer invokes LLVM-local expression/array/length inference; DMA calls no longer invoke LLVM-local `exprType`/`dmaBufInfo` or rebuild the slice result; raw-many `.offset` no longer derives receiver or element types through LLVM-local `exprType` and alias resolution; MMIO map/register calls no longer derive semantic types through LLVM-local type arguments, receiver expressions, or field metadata lookup; raw-memory calls no longer derive semantic types from LLVM-local type arguments or hard-coded address types; varargs calls no longer recover cursor or result types through LLVM-local `exprType`; byte-view calls no longer derive object/slice types through LLVM-local `exprType` or a synthesized slice; reflection calls no longer hand the AST call to LLVM-local reflection type extraction; atomic/MaybeUninit member call-info no longer derives payloads from receiver types; atomic initialization no longer uses AST spelling to derive identity, payload, or result type in local or global paths. Direct calls require MIR result/fixed-argument facts, function-pointer/closure calls require the complete MIR callee signature, and inferred-local grouped-call typing now goes through the same `exprType`/grouped `expression_result` path; `expectedTyForCallArg`, the direct `fn_sigs` return fallback, and the extra inferred-local call-return fallback are retired. Broader expression typing remains open. | Unsupported or unknown shapes return null/unsupported. Missing/stale target-type or migrated call-target facts reject prebuilt MIR before emission. |
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
| Stable identity key | Facts match by instruction kind, result type, source point, detail, textual `value_id`, and the typed `ValueId` mirror when present; `lower-mir` prints the legacy instruction `value_id=...` and `mir representation_fact ... value_id=...` rows. |
| Flow-proven nonnull bindings | A nullable-pointer `if let` or switch binding records a scope-local nonnull proof. Uses still emit matching typed-load and representation-check facts, but the statically discharged check has no `InvalidRepresentation` trap edge. Shadowed bindings restore the outer proof state; ordinary pointer parameters remain trapping. |
| Backend admission gate | C and LLVM call the unified `validateLoweringAdmission` seam before emission; that seam includes `validateRepresentationFactsForLowering` and rejects `.unknown` placeholders in admitted representation fact types. |
| Missing-fact rejection | `lower-c rejects prebuilt MIR with missing representation facts` and `LLVM rejects prebuilt MIR with missing representation facts` remove required rows and expect `InvalidMirRepresentationFacts`. |
| Stale-fact rejection | `lower-c rejects prebuilt MIR with stale representation facts` and `LLVM rejects prebuilt MIR with stale representation facts` retarget a required row and expect `InvalidMirRepresentationFacts`. |
| Extra stale-fact rejection | `lower-c rejects prebuilt MIR with extra stale representation facts` and `LLVM rejects prebuilt MIR with extra stale representation facts` keep all valid rows, append an unmatched stale row, and still expect `InvalidMirRepresentationFacts`. |
| Result try-payload representation | `lower-c rejects prebuilt MIR with missing Result try payload representation facts`, `lower-c rejects prebuilt MIR with stale Result try payload representation facts`, and the matching LLVM tests prove `representation_use detail=try_unwrap` for pointer payloads is admitted by the same MIR-owned representation fact gate. |

### Backend AST-inference budget

Current backend AST-inference budget: **7 registered families**.

This is a shrinking budget. These families are allowed only because their
current behavior is named, anchored, and paired with a fail-closed policy. A new
backend semantic inference family must either reuse an existing registered
family or deliberately update this budget. A migration slice that removes a
family from backend authority must reduce the count.

Current M0 reduction: C unchecked no-overflow inferred-local initialization now
uses the source expression's complete `expression_result` fact for non-call
source expressions. The remaining numeric-expression fallback is exact-count
gated to generated zero-span nodes that cannot be keyed by source span. C cast
target classification now uses one shared target/result admission helper for
nullable values, floating values, enum values, tagged-union values, numeric
values, and pointer pointees, instead of accepting `explicit_cast_target`
alone. The AST cast target remains only for generated zero-span casts. LLVM
source-cast expression typing now follows the same target/result rule instead
of accepting
`explicit_cast_target` alone. LLVM source member/index comparison operands now
follow the same direct `expression_result` rule as C. LLVM source binary
expression typing now also consumes the binary expression's own
`expression_result` row directly; source unary expression typing follows the
same direct rule. LLVM source float literal expression typing consumes the MIR
`float_literal` target fact, and char literal expression typing consumes
`char_literal`. LLVM source string literal expression typing consumes
`string_literal`; enum literal expression typing consumes `enum_literal`;
null literal expression typing consumes `null_literal`; struct literal expression
typing consumes `struct_literal`; void literal expression typing consumes
`expression_result`. C inference call-result
queries now use the shared emitter hook that consumes direct, indirect,
dynamic-dispatch, and migrated builtin call
facts; the private direct-call-only helper is exact-zero gated. The C inference
context no longer carries the function declaration map, so call-result
authority cannot be reintroduced there without changing the inventory. The same
context also no longer carries the owned-target hook; owned fact consumption
stays in the emitter/lowering contexts that explicitly need ownership identity.
Result and nullable inferred-call local classifiers are named
`isResultMirCallResultType` and `isNullableMirCallResultType`; they only check
the family of a MIR-gated call result, and the old call-return authority names
are exact-zero-gated.
The C memory-view/DMA context also dropped its unused alias table handle; byte
view, DMA, and MaybeUninit lowering now expose only the MIR facts and emission
hooks they actually consume. The C leaf-call temp context also stopped carrying
the alias table for bitcast temporaries; `bitcast_target` is now consumed as the
MIR-owned target type and C spelling remains delegated to the emitter's type
view. The direct C conversion bitcast emitter follows the same rule: it consumes
the MIR `bitcast_target` row directly instead of re-resolving that target through
the backend alias table. C unchecked inferred-local arithmetic no longer carries
the numeric expression type callback for generated fallback recovery; source
expressions use `expression_result`, unchecked calls use their MIR result facts,
and other generated numeric fallback shapes now fail closed.

| Family | Budget class | Reduction condition |
|---|---|---|
| `c-expression-type-inference` | Backend AST inference budget | C expression type decisions that affect lowering are provided by typed facts/MIR or rejected when absent. |
| `c-type-shape-classification` | Backend AST inference budget | Local/global shape, aggregate/scalar routing, and race-helper eligibility are supplied by typed facts or an accepted target matrix. |
| `c-abi-aggregate-lowering` | Backend AST inference budget | Internal aggregate construction consumes typed layout/ABI facts or rejects unsupported forms; explicit C ABI/export aggregate values are an inventory-gated diagnostic boundary until target ABI facts exist. |
| `c-direct-global-race-helpers` | Backend AST inference budget | Direct global race-helper routing is represented by typed memory/race facts or by an accepted direct-global backend policy. |
| `c-pointer-provenance-consumption` | Backend AST inference budget | Broader scalar-leaf conservative fallback is fully covered by typed provenance facts or an accepted default policy. |
| `llvm-pointer-provenance-consumption` | Backend AST inference budget | The remaining LLVM local-only proof is migrated to MIR facts or explicitly accepted as a local emission proof, not semantic inference. |
| `llvm-expression-type-inference` | Backend AST inference budget | LLVM expression type decisions that affect lowering are provided by typed facts/MIR or rejected when absent. |

### T3 final backend inference dispositions

T3 closes the classification question for the finite seven-family backend
budget. It does not declare every family MIR-owned or freeze future migration.
It requires every residual path to have one auditable terminal behavior today:
consume a fact, lower conservatively, use a documented target-only policy, or
diagnose unsupported input. No row may remain an unclassified cleanup item.

| Family | Final disposition | Enforced boundary |
|---|---|---|
| `c-expression-type-inference` | `conservative-or-diagnosed` | Migrated source shapes require MIR facts; unrecognized or unsupported expression shapes return no type or reject emission instead of inventing one. |
| `c-type-shape-classification` | `accepted-target-policy` | The named C aggregate/global and race-helper matrices decide internal C representation mechanics; unknown shapes reject or recurse conservatively and do not define source/external ABI. |
| `c-abi-aggregate-lowering` | `diagnosed-unsupported` | Explicit C ABI/export by-value aggregates without target classification produce `E_EXTERN_STRUCT_BY_VALUE`; internal construction remains target mechanics around resolved layout. |
| `c-direct-global-race-helpers` | `accepted-target-policy` | Only the documented scalar-width and recursive aggregate helper matrix is admitted; unsupported leaves fail emission. |
| `c-pointer-provenance-consumption` | `conservative-fallback` | Missing positive provenance selects race-tolerant scalar/recursive aggregate lowering or rejects an unsupported leaf. |
| `llvm-pointer-provenance-consumption` | `conservative-fallback` | Missing positive provenance selects unordered atomic scalar/recursive aggregate lowering or rejects an unsupported leaf; alias maps cannot create provenance. |
| `llvm-expression-type-inference` | `conservative-or-diagnosed` | Migrated source shapes require MIR facts; unknown or unsupported shapes return no type or reject emission. |

`semantic-facts-inventory.py` requires the disposition keys to match the budget
exactly and anchors every row. Adding an eighth family therefore requires an
explicit policy in the same patch; removing one requires reducing both sets.

### T4 backend semantic-authority audit

The production backend source surface is now an exact inventory, excluding
test-only modules. Each C/LLVM lowering module has one top-level authority
class. Adding or renaming a backend module without classifying it fails the
semantic-facts inventory.

| Authority class | Meaning | Modules |
|---|---|---|
| Registered semantic family | The module contains one or more residual semantic decisions governed by the seven-family budget and its final T3 disposition. It may also consume facts or perform mechanics. | `ast_query`; C aggregate/emitter/expression/global/inference/info/layout/shape/target/type modules; LLVM main/lookup/query/shape modules. |
| MIR/fact consumer | Lowering selection is entered through the registered MIR identities, types, provenance, range, bounds, or representation facts anchored by the family inventory. AST access validates spelling, arity, layout, or emission operands after selection. | C entry/access/arithmetic/atomic/builtin/call/collect/conversion/domain/memory/MMIO/reflection/special/switch/try modules; LLVM atomic/reflection modules. |
| Mechanics-only | The module encodes names, text, target syntax, CFG emission, aliases, attributes, runtime declarations, already-selected operations, module-pipeline ordering, or backend data models. It is not allowed to introduce a new lowering-affecting semantic classification without moving to a registered family or MIR/fact consumer class. | Remaining inventoried C/LLVM backend modules, including `lower_c_module`. |

This is a supported-subset authority audit, not a proof derived automatically
from Zig semantics. The exact-file gate prevents an unseen backend surface; the
family anchors, retired-classifier counts, missing/stale tests, and review of
the mechanics-only list constrain decisions inside those files. A new semantic
decision in an existing mechanics module must reclassify that module and update
the relevant family inventory in the same change.

### P4 C/LLVM provenance policy parity

The complete current provenance fallback register has the same C and LLVM
policy. Positive facts may select ordinary lowering only for the documented
MIR/local/raw/MMIO proof sets. Removing or invalidating a fact selects the
conservative path or the same diagnosed unsupported boundary in both backends.

| Boundary | C policy | LLVM policy | Paired evidence |
|---|---|---|---|
| Unknown scalar dereference | Race-tolerant `mc_race_*`/atomic helper lowering; unsupported widths reject. | Unordered atomic scalar lowering; atomic-ineligible widths reject. | Scalar pointer deref default audit and exact central-helper counts. |
| Escaped pointer | Call/address escape invalidates positive provenance before the next dereference. | Same invalidation and conservative next dereference. | `escaped pointer provenance lowers conservatively` suites. |
| Higher-order/exported return | Callback/function-pointer and exported ambiguity do not create positive provenance. | Same conservative return policy. | Returned pointer facts audit and direct-positive/missing-fact pairs. |
| Aggregate return outside bounded CFG | No summary/fact is produced; scalar leaves remain race-tolerant. | Same absent-summary/fact behavior. | Aggregate-return unsupported CFG matrix and C/LLVM fail-closed suites. |
| Unsupported scalar/aggregate leaf | Emission rejects instead of using a plain racy C access. | Emission rejects instead of using a non-atomic racy LLVM access. | Scalar/aggregate leaf failure matrix. |

`semantic-facts-inventory.py` anchors this parity table together with the
existing scalar, escape, return, and aggregate-CFG audits. A newly admitted
pointer flow must add its positive and absent-proof evidence to both backends;
that flow alone reopens P3/P4.

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
large duplicated inference class today and the validation ledger has many recent
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
- the typed-fact migration notes link to the migration commits and parity
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
the migration closure matrix owns their migration or fail-closed disposition.

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
struct-literal returns are transparent only when their deferred expression is a
MIR-admitted direct cleanup call; the literal itself supplies the returned
pointer-field provenance even when the deferred cleanup is effectful.
Tracked-local aggregate returns also allow direct zero-argument deferred cleanup calls. Deferred calls
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
   cleanup calls, expression/assert prefixes without calls or exits, transparent
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
- Do not make `mcc facts` or `inspect-ir` / `lower-ir` the backend input format.
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
- `mcc facts`, `inspect-ir`, or `lower-mir` exposes a stable debug view of the
  typed facts for fixtures;
- `zig build test` gates the migrated family;
- remaining semantic fact families are tracked in the explicit closure matrix,
  rather than hidden inside the original vague architecture item.

These criteria do not close the broader typed semantic fact migration umbrella.
That umbrella closes only when its finite migration matrix is complete or its
remaining rows are explicitly accepted as limitations.

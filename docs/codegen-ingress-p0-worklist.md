# P0 codegen-ingress worklist

Goal: delete the AST function-body fallback after every ordinary body is
emitted from verified executable MIR.

## Measurement (2026-09-01)

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 168/168 canonical | 168/168 canonical |
| broad sweep | 1606/1818 admitted | 1658/1872 admitted |
| AST fallback | 212 | 214 |
| specialized plans | 0 | 0 |

The specialized-plan migration is closed. `mir_statement_plan.zig`, both
foreach plan emitters, and all selected-path enum variants were deleted.

Trapping `?` is canonical for nullable pointers, value optionals, and Results
when the enclosing function does not return Result. Same-type Result
propagation is a separate verified `try_propagate` operation: it returns the
already evaluated Result unchanged on error and exposes the success payload on
the continuation. Producer, verifier, C, and LLVM consume the same typed Result
layout and preserve expression order for assignments, calls, and multiple
unwraps. Checked `mmio.map<T>(PAddr)?` is a separate pointer-niche operation
whose unsafe authorization, address/result classes, and exact `Unwrap` edge are
verified before either renderer runs. Mapped propagation has its own
`try_map_error` operation: the producer admits an exact `#[error_from]`
conversion signature or a side-effect-free canonical enum literal, the
verifier checks source and enclosing Result payload identities, and both
renderers branch before extracting the success payload. These slices retired
twenty-four broad-corpus fallbacks per backend in total and reduced
`unsupported_try` to zero. The cleanup case is separately classified
`defer_cleanup` and stays fail-closed until cleanup edges own propagation.

Guarded aggregate dereferences and mutable aggregate globals now carry their
memory-access class in executable MIR. Declared structs, value optionals, and
fixed arrays lower recursively to scalar leaf loads/stores in both backends;
packed bits and unions remain one storage unit and therefore do not take the
leaf path. The broad sweep gained eight C and nine LLVM canonical bodies.

Checked arithmetic trap edges are now attached after all evaluation-ordered
expressions exist. The producer still requires an exact, unambiguous typed
owner and the verifier still checks every edge bijectively. This closes both
`fill_size` monomorphizations in C and LLVM and reduces the leading
`trap_projection` bucket from 60 to 55.

Representation trap ownership is now resolved after canonical places,
expressions, and statements have all been normalized. Exact typed candidates
are admitted only when the owner is unique; ambiguous and incomplete dynamic
trait/nullable representations remain fail-closed. Local pointer generations
such as `let q = p; q.* = value` now preserve their pointer shape and attach
the store guard to the canonical place. This reduces `trap_projection` from 55
to 46 per backend and retires four net fallbacks per backend.

Recursive IEEE-float classification removes a spurious integer-overflow edge
from nested float arithmetic. `f32x4_sum` is canonical in both renderers,
reducing `trap_projection` from 46 to 45 and retiring two broad-corpus fallback
instances per backend.

Typed local pointer generations now retain their canonical pointee place when
a field is projected through them. MIR owns the representation edge and both
renderers consume the same projected place, including mutable pointer locals
whose value lives in an addressable slot. This removes eleven entries from the
`trap_projection` bucket, admits four additional broad-corpus functions per
backend, and leaves 42 trap-projection bodies per backend; the other newly
exposed bodies remain fail-closed on their next structural blocker.

Fixed-array projections behind a checked pointer parameter now own both parts
of their safety contract: one pointer-representation edge and every checked
index edge. Access classification treats the pointee as external storage rather
than the local parameter slot, and LLVM can emit the representation guard for
both expression and statement owners. Sixteen `trap_projection` entries leave
the bucket, fourteen functions per backend become canonical, and the remaining
two expose their next typed-operation blocker. The bucket is now 26 bodies per
backend.

Opaque and precise inline assembly are executable-MIR statements. Decoded
templates and clobbers are body-owned bytes; precise inputs and outputs use
`ExprId`, `LocalId`, and checked `TypeId` facts. C and LLVM share the operation
and receive stub mode explicitly. Nineteen broad-corpus functions per backend
move to canonical emission, leaving one malformed negative fixture in the
`unsupported_statement` bucket.

Valid naked functions now take a narrow canonical renderer path: one verified
opaque asm statement and one `unreachable` terminator, with no ordinary CFG
wrapper. The naked runtime proof passes in C and LLVM, five additional
broad-corpus bodies per backend are canonical, and the legacy AST naked-body
emitters and syntax bridge have been deleted. No broad fallback is marked
`canonical=ready`; the remaining tail is producer-incomplete or an explicit
renderer capability gap.

Typed scalar/enum switches now distinguish a source wildcard arm from trap
successors created while evaluating the subject. Representation and bounds
traps remain independently owned executable edges instead of being mistaken
for a second switch default. Canonical `declassify` then supplies its verified
payload type and unsafe authorization as a representation-identity builtin.
The two slices retire eight broad-corpus fallback entries per backend and
reduce `general_switch` to 16 C / 18 LLVM bodies. Fixed-array `const_get` now
stores its receiver and compile-time index directly on the verified builtin
operation; this retires one further fallback per backend.

Reflection calls now contribute their checked `usize` result type when MIR
selects a comparison operand type. Unsuffixed constants compared with
`size_of`, `alignof`, or `field_offset` no longer leak `comptime_int` into
either renderer; `fuzz_c_union.size_check` is canonical in both backends.

Packed-bits field assignment is now an explicit executable-MIR
`packed_field_store`. It owns the complete packed place, boolean field index,
and storage access class; C and LLVM mechanically emit the same scalar
read-modify-write. Local storage remains plain, while a mutable global uses the
existing race-unordered load/store contract. This closes `set_tx_empty` and
`update_global_tx_empty` in both backends without treating the field as an
ordinary byte-sized boolean store.

Direct store access now follows the canonical `PlaceId` root after name
resolution. A local that shadows a mutable global therefore remains plain
local storage instead of inheriting race access from the shared spelling.
Direct local `u128`/`i128` storage also has its actual 16-byte alignment; the C
renderer still rejects shared 128-bit scalar access because the qualified
runtime intentionally provides no such race helper. These two identity/layout
fixes retire one fallback per backend each.

Nested fixed-array indexing now traces a projection chain to either a local
array or a by-value parameter array. The two renderers consume the same typed
array shapes and checked bounds edges; `aggregate_ordering.mc` is 8/8
canonical, is covered by the strict ratchet, and retires one broad fallback per
backend.

Fixed-array member places behind an implicit pointer auto-deref now resolve
their declaration type and symbolic constant length before place admission.
Bounds edges are attached in a final bijective pass using the verifier's exact
fixed/slice-index predicate, so incomplete aggregate projections remain
closed. Safe mutable-to-const pointer casts use the existing checked
representation wrapper, and switch-arm terminal traps are projected from any
typed case target. This retires six C and seven LLVM broad fallbacks. One
`InvalidCompletionClaim` remains (`packet_init`), requiring a canonical proof
for a reassigned local pointer generation before its fixed-array field can be
opened.

## Ranked next slices

1. Close typed place and return/CFG invariants.
2. Lower generic member/place operations and unsupported calls.
3. Model non-eager logical operations as explicit short-circuit CFG.
4. Lower the remaining variant and generated general switches with typed cases
   and explicit CFG.
5. Lower strings, arrays/aggregates, `try`, and remaining calls.
6. Close renderer-only capability gaps.
7. Delete the AST fallback artifact and both backend branches.

The verifier now promotes every structurally valid body that has no explicit
producer-owned incomplete reason. Compile-time statements carry an explicit
reason and remain fail-closed instead of being emitted as runtime work.

The fixed-array index renderer slice is closed for `arrays_slices.mc`: all 29
functions are canonical in both backends, and four source-consumer-specific
admission helpers were deleted. Canonical `uninit` now means uninitialized
local storage rather than a runtime value.

Slice indexing of a declared struct whose fields are scalar is also canonical.
Both renderers rebuild the aggregate from race-tolerant unordered field loads,
so the cutover preserves the legacy access contract without a racy whole-value
copy. `inferred_call_slice_element` is canonical in both backends.

`LocalId` now identifies a declaration generation rather than a source
spelling. Disjoint lexical scopes can reuse a name without collapsing LLVM
allocas or types; this retired 16 LLVM-only fallbacks while leaving the C
canonical path unchanged.

Callable return representation is now a verified function fact. LLVM uses the
same fact for function signatures, direct-call results, local storage, and
aggregate callable fields, so closure values are consistently represented as
`{ ptr, ptr }`. The last four `canonical=ready` LLVM fallbacks are retired;
every remaining LLVM fallback is either producer-incomplete or renderer-owned.

Callable field stores now use exact signatures attached to function symbols,
callable parameters, closure binds, and aggregate field metadata. The verifier
rejects a mismatched signature before rendering. LLVM uses the canonical
parameter-projected place for checked pointer roots and splits fat closure
storage into code/environment pointer accesses, including recursively copied
race-tolerant aggregates. Four additional LLVM broad-corpus functions are
canonical; C remains at its existing boundary.

Dynamic-trait calls and stores are now syntax-free executable operations.
Exact trait `SymbolId`s live on parameters and aggregate fields; a call owns
its receiver `PlaceId`, vtable slot, signature, arguments, and representation
edge. C and LLVM consume the same two-pointer value and the verifier rejects a
trait-mismatched store. `std/task.mc` is 15/16 canonical in both backends; its
remaining `Join2__poll` fallback is a genuine short-circuit CFG requirement,
not a missing dynamic-dispatch recognizer. Broad incomplete-reason telemetry
now reports verifier errors after projection instead of stopping at a coarse
legacy/executable trap-count mismatch.

Dynamic-trait coercion itself is now syntax-free as well. `dyn_bind` records
the concrete pointer operand and exact trait/concrete symbol pair; return and
local identities retain the selected trait across direct calls and aggregate
fields. C constructs `mc_dyn_Trait` and LLVM constructs `{ ptr, ptr }` from
that same verified operation. The focused return/field/call-position fixture
is 5/5 canonical in both backends, and the broad sweep retires 17 C and 22 LLVM
fallbacks without adding a source-shape recognizer.

Byte-view construction and equality are canonical executable operations in
both renderers. Their source object size comes from the addressed canonical
place type rather than from a pointer-child spelling, so fixed arrays retain
their exact length. The three direct byte-view fixtures are 3/3 canonical in
both backends; the newly completed array callers also closed nine LLVM ingress
fallbacks. C gives later same-spelled lexical local generations a stable ID
suffix, preventing flat CFG emission from redeclaring one C name.

The parameter-pointee fixed-array/address family is also closed. A leading
typed parameter dereference is part of the shared fixed-array place metadata;
the two backends no longer reconstruct it independently, and both retain the
representation and bounds trap edges. Immutable local copies of pointer
parameters use a narrow canonical provenance proof. The three address-return
helpers in `pointer_field_addr.mc` are now canonical in C and LLVM.

Fixed-array fields reached through a checked pointer are now aggregate-capable
typed places rather than scalar-only member loads. An immediately indexed
field is lowered as one projected-place load, so neither renderer has to
materialize and then reinterpret a whole temporary array. The verifier owns
the same representation edge and parameter-root proof. This moves sixteen
broad-corpus functions per backend to canonical MIR across byteview, pool,
ring, slotmap, const-generic ring, and capability workloads. The broad fallback
is now 212 C / 214 LLVM; `unsupported_member` is reduced to two producer cases
per backend.

## Rules

- No new specialized plan or backend AST recognizer.
- Missing typed facts fail closed to the explicit fallback.
- C and LLVM consume one verified operation.
- Every slice runs focused tests, both backend shards, strict census, and an
  updated broad census.
- Completion means deletion of the fallback ingress, not a percentage.

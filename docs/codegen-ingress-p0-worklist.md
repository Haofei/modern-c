# P0 codegen-ingress worklist

Goal: delete the AST function-body fallback after every ordinary body is
emitted from verified executable MIR.

## Measurement (2026-09-01)

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 160/160 canonical | 160/160 canonical |
| broad sweep | 1475/1825 admitted | 1517/1879 admitted |
| AST fallback | 350 | 362 |
| specialized plans | 0 | 0 |

The specialized-plan migration is closed. `mir_statement_plan.zig`, both
foreach plan emitters, and all selected-path enum variants were deleted.

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

## Ranked next slices

1. Attach remaining trap projections to canonical expression/statement IDs.
2. Close signature/type-reference mismatches.
3. Lower unsupported statements and generic member/place operations.
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

## Rules

- No new specialized plan or backend AST recognizer.
- Missing typed facts fail closed to the explicit fallback.
- C and LLVM consume one verified operation.
- Every slice runs focused tests, both backend shards, strict census, and an
  updated broad census.
- Completion means deletion of the fallback ingress, not a percentage.

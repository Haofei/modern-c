# P0 codegen-ingress worklist

Goal: delete the AST function-body fallback after every ordinary body is
emitted from verified executable MIR.

## Measurement (2026-08-30)

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 160/160 canonical | 160/160 canonical |
| broad sweep | 1431/1827 admitted | 1447/1879 admitted |
| AST fallback | 396 | 432 |
| specialized plans | 0 | 0 |

The specialized-plan migration is closed. `mir_statement_plan.zig`, both
foreach plan emitters, and all selected-path enum variants were deleted.

## Ranked next slices

1. Attach remaining trap projections to canonical expression/statement IDs.
2. Close signature/type-reference mismatches.
3. Lower unsupported statements and generic member/place operations.
4. Lower general switches with typed cases and explicit CFG.
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

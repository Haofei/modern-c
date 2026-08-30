# P0 codegen-ingress worklist

Goal: delete the AST function-body fallback after every ordinary body is
emitted from verified executable MIR.

## Measurement (2026-08-30)

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 160/160 canonical | 160/160 canonical |
| broad sweep | 1335/1777 admitted | 1370/1829 admitted |
| AST fallback | 442 | 459 |
| specialized plans | 0 | 0 |

The specialized-plan migration is closed. `mir_statement_plan.zig`, both
foreach plan emitters, and all selected-path enum variants were deleted.

## Ranked next slices

1. Attach remaining trap projections to canonical expression/statement IDs.
2. Close producer invariants and signature/type-reference mismatches.
3. Lower unsupported statements and generic member/place operations.
4. Lower general switches with typed cases and explicit CFG.
5. Lower strings, arrays/aggregates, `try`, and remaining calls.
6. Close renderer-only capability gaps.
7. Delete the AST fallback artifact and both backend branches.

## Rules

- No new specialized plan or backend AST recognizer.
- Missing typed facts fail closed to the explicit fallback.
- C and LLVM consume one verified operation.
- Every slice runs focused tests, both backend shards, strict census, and an
  updated broad census.
- Completion means deletion of the fallback ingress, not a percentage.

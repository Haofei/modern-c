# P0 codegen-ingress worklist

Goal: delete `FunctionBodyFallbackArtifact.syntax: ast.Block` after every
ordinary function body is emitted from verified executable MIR. Passing tests
or reaching a percentage threshold does not complete this goal; deleting the
AST ingress does.

## Current measurement (2026-08-29)

Run:

```sh
OUTDIR=zig-out/fallback-census-broad JOBS=8 \
  bash tools/toolchain/fallback-census.sh
```

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 160/160 admitted, 0 fallback | 160/160 admitted, 0 fallback |
| broad repository sweep | 1252/1774 admitted, 522 fallback | 1292/1845 admitted, 553 fallback |
| canonical bodies | 1153 | 1185 |
| transitional specialized bodies | 99 | 107 |

The strict ratchet is a regression gate, not the completion definition. The
broad sweep includes partial records from unsupported/reject roots and is the
worklist snapshot.

## Latest completed slices

- Canonical cast identity now covers representation casts, float resizing and
  every defined integer width/sign conversion. LLVM selects `sext`, `zext` or
  `trunc` from the verified source/target types.
- Packed-bits storage metadata, field reads, construction, local initialization
  and whole-value reassignment are canonical in both renderers.
- Named/comptime local array lengths are resolved once in the MIR builder's
  const environment. Direct returns from immutable, initialized, never-written
  local fixed arrays are canonical; mutable locals and slices remain closed.
- These slices reduced broad fallback by 15 functions in each backend during
  the current batch. MIR/cleanup is 358/358 and backend is 1034/1034.

## Remaining producer blockers

Ranked by broad frequency (C / LLVM where different):

1. `trap_projection`: 130 / 138
2. `unsupported_member`: 63 / 63
3. `producer_invariant`: 28 / 28
4. `unsupported_statement`: 27 / 27
5. `unlowered_array`: 25 / 27
6. `unsupported_call`: 25 / 25
7. `general_switch`: 21 / 23
8. `InvalidBuiltinCall`: 20 / 19
9. `unsupported_struct_literal`: 20 / 20
10. `noncanonical_string_literal`: 18 / 18
11. `unsupported_try`: 15 / 15
12. `unlowered_member`: 14 / 14

Renderer-only rejection remains 46 C / 61 LLVM bodies. It must be reduced by
typed, verifier-checked slices; renderer admission must not infer source
semantics.

## Order of work

1. Make trap ownership attach to canonical `ExprId`/`InstId` for the remaining
   bounds, representation and arithmetic operations. Do not admit a memory
   operation unless its access ordering and exact trap edge are already in MIR.
2. Normalize member/place provenance so generic aggregate fields use one typed
   aggregate table rather than source-shaped member recovery.
3. Complete ordinary aggregate/array construction and local/global stores.
4. Lower calls, switches, `try`, strings and inline assembly only after their
   evaluation order, effects and ABI are explicit in executable MIR.
5. For every canonical family, remove the corresponding specialized plan.
6. When broad fallback reaches zero, delete both backend fallback branches,
   `FunctionBodyFallbackArtifact`, and the AST body payload in one cutover.

## Safety rules

- No new backend AST/body recognizers.
- Missing typed facts fail closed.
- C and LLVM consume the same operation and verifier invariant.
- Every slice runs MIR/cleanup, backend, strict census and a broad census.
- A fallback plan is removed only when its whole admitted family is canonical;
  adding canonical code without deleting obsolete legacy code is not progress.

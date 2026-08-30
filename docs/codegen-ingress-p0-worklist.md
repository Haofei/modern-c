# P0 codegen-ingress worklist

Goal: delete `FunctionBodyFallbackArtifact.syntax: ast.Block` after every
ordinary function body is emitted from verified executable MIR. Passing tests
or reaching a percentage threshold does not complete this goal; deleting the
AST ingress does.

## Current measurement (2026-08-30)

Run:

```sh
OUTDIR=zig-out/fallback-census-broad JOBS=8 \
  bash tools/toolchain/fallback-census.sh
```

| corpus | C | LLVM |
| --- | ---: | ---: |
| strict ratchet | 160/160 admitted, 0 fallback (131 canonical) | 160/160 admitted, 0 fallback (131 canonical) |
| broad repository sweep | 1305/1771 admitted, 466 fallback | 1337/1822 admitted, 485 fallback |
| canonical bodies | 1234 | 1262 |
| transitional specialized bodies | 71 | 75 |

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
- Atomic aggregate-field access, global arithmetic-domain operations, low-level
  `cpu.pause`/physical-address calls, and `unchecked.add/sub/mul` are now
  canonical. Unchecked arithmetic carries its exact no-overflow contract-region
  ID and typed span into executable MIR; admission rejects a missing proof
  before either renderer runs.
- Taking a checked address of a fixed-array element now owns an exact Bounds
  edge in executable MIR. Builder, verifier and both renderers share the typed
  `PlaceId` projection; seven C and eight LLVM broad-corpus fallbacks retired.
- Typed indirect calls are no longer limited to the old zero-parameter/void
  canonical slice. Existing signature facts and renderer admission now cover
  parameter and local function pointers with arguments and return values; the
  strict corpus moved two more bodies per backend from specialized plans to the
  canonical emitter.
- Callable values loaded from global objects, fixed arrays, aggregate fields,
  and fixed-array elements of aggregate objects now share the canonical typed
  place/load model. The fixed-array element field case is a two-projection
  `PlaceId`, and checked indexing retains its exact Bounds edge.
- The transitional `IndirectCallReturnPlan`, its source-shaped callee model,
  both backend emitters and its census category were deleted. The specialized
  plan-definition count is now 9. Relative to the preceding broad snapshot,
  C canonical bodies rose by 12 and specialized bodies fell by 8; LLVM
  canonical bodies rose by 14 and specialized bodies fell by 11. Broad AST
  fallback fell by 4 C and 3 LLVM bodies. MIR/cleanup and backend shards pass.
- Scalar slice reads and writes now use the canonical executable place/index
  model, including exact representation/bounds edges, race-unordered loads and
  stores, and RHS-before-LHS assignment evaluation. The old `access_slice` and
  `access_operation` models, builders and both backend emitters were deleted.
  The strict split is now C 130 canonical / 30 specialized and LLVM 131 / 29;
  only eight specialized plan definitions remain.
- Callable struct fields and closure `{code, env}` values now lower through the
  canonical executable body in both backends. The entire workflow plan, its
  two backend emitters, tests, import surface and census category were deleted.
  The strict split is now 132 canonical / 28 specialized for both backends;
  seven specialized plan definitions remain.

## Remaining producer blockers

Ranked by broad frequency (C / LLVM where different):

1. `trap_projection`: 94 / 98
2. `unsupported_member`: 63 / 63
3. `unsupported_statement`: 27 / 27
4. `producer_invariant`: 28 / 28
5. `unlowered_array`: 25 / 25
6. `unsupported_call`: 22 / 22
7. `general_switch`: 21 / 23
8. `unsupported_struct_literal`: 19 / 19
9. `noncanonical_string_literal`: 18 / 18
10. `unsupported_try`: 15 / 15
11. `unlowered_member`: 12 / 12
12. `InvalidBuiltinCall`: 10 / 10

Renderer-only rejection remains 41 C / 49 LLVM bodies. It must be reduced by
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

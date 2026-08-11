# Refactoring plan

This is the active code-facing refactoring plan for `modern-c`.

Do not create another remediation/status roadmap for the same work. Open risk
state lives in [`review-risk-register.yaml`](review-risk-register.yaml). Product
profile scope lives in [`profile-manifest.json`](profile-manifest.json) and
[`scope-control-plan.md`](scope-control-plan.md). This file only defines the
execution order.

## Goal

Reduce duplicate semantic authority before expanding product surface.

Target shape:

```text
CompilationSession
        ↓
immutable syntax + resolved semantic facts
        ↓
typed MIR + MIR verifier
        ↓
VerifiedProgram
        ↓
mechanical C/LLVM artifact emission
```

Main rule: backends may use source spelling for emission mechanics, but not as
authority for type, representation, ABI, layout, provenance, control flow, or
safety decisions.

Anchored current invariant:
`src/compiler_session.zig` owns `CompilationSession`: file-boundary,
module-graph, visibility, IO, parse/check, MIR build, VerifiedProgram
construction, and request-scoped diagnostics. `src/artifact_publisher.zig` owns
artifact output, metadata sidecar preflight, rollback, and publication. `src/main.zig`
is the CLI composition root for command dispatch.
MIR already has typed seeds for block, function symbol, value, type, and span.
Verifier/admission checks reject result/span/owner drift.

## Non-goals for this refactor

These areas stay profile-scoped or experimental until the compiler authority
boundary is stable:

- new language surface area;
- LLVM as an equal production backend where facts are still incomplete;
- self-host expansion beyond the declared bootstrap subset;
- advanced LSP/indexing work that requires a persistent query service;
- deployable kernel, Agent product, or real hardware claims;
- new vendored runtimes in the default compiler profile.

## Active phases

| Phase | Theme | Primary risks | Exit signal |
|---:|---|---|---|
| 0 | Stop authority growth | `ARCH-BACKEND-FACTS`, `BACKEND-LLVM-PROFILE` | semantic-facts inventory does not grow, or each remaining exception is exact-count-gated. |
| 1 | Typed MIR identity | `ARCH-TYPED-MIR` | backend-critical types, symbols, values, ABI/layout, representation, and control facts are typed or verifier-owned. |
| 2 | `VerifiedProgram` narrowing | `ARCH-TYPED-MIR`, `ARCH-BACKEND-FACTS` | production backend entrypoints no longer expose AST as semantic input. |
| 3 | Artifact provenance | `ARCH-SOURCE-MAP-DIGEST` | emitted bytes, source maps, lowering options, source/MIR digests, and tool identity are bound together. |
| 4 | Manifest-backed governance | `GATE-MANIFEST`, `COMPONENT-PROFILE-MINIMIZATION` | build/CI/release/docs read status from manifests instead of Markdown counters. |
| 5 | Profile-scoped kernel hardening | `KERNEL-CAPABILITY-MINT`, `HARDWARE-PRODUCTION-QUALIFICATION` | production capability/hardware claims are type-gated and evidence-backed. |

Phases 0–2 are the default work. Phases 3–5 should not displace compiler P0
unless the patch is small, isolated, and directly closes a listed risk.

## Phase 0 — stop backend authority growth

Purpose: prevent C/LLVM backends from becoming parallel semantic analyzers.

Work items:

1. Pick one remaining helper from
   `tools/toolchain/semantic-facts-inventory.py`.
2. Replace it with an existing MIR/semantic fact, or add the smallest new typed
   fact.
3. Delete the old inference path, quarantine it to generated/mechanics-only
   code, or lock it behind an exact inventory exception.
4. Add a regression proving the backend cannot silently reconstruct the fact
   from AST shape or type spelling.

Done when:

- `semantic-facts-inventory-test` passes;
- touched C and LLVM paths consume the same fact or fail closed;
- no new backend helper infers type, representation, ABI, provenance, control
  flow, or safety without inventory coverage.

## Phase 1 — make MIR identity typed

Purpose: make illegal backend-critical states unrepresentable or rejected before
codegen.

Preferred order:

1. call target identity and call result facts;
2. optional/result representation;
3. ABI/layout-sensitive aggregate facts;
4. load/store pointer provenance;
5. trap, runtime-check, and control-effect facts.

Done when:

- production lowering positions do not accept `.unknown` except through an
  explicit diagnostic/debug allowlist;
- migrated type/value/symbol/span identities use typed IDs or verifier-owned
  tables;
- malformed MIR states are rejected before backend admission;
- backends no longer reconstruct migrated facts from strings or AST nodes.

## Phase 2 — narrow `VerifiedProgram`

Purpose: make codegen admission mean “verified semantic input”, not “verified
MIR plus syntax escape hatches”.

Work items:

1. Introduce typed views for symbol spelling, source spans, layout, ABI,
   representation, and target configuration.
2. Replace one backend AST ingress at a time with those views.
3. Remove direct production backend entrypoints that bypass `VerifiedProgram`.
4. Keep any remaining syntax access mechanics-only and exact-count-gated.

Done when:

- production C/LLVM entrypoints require `VerifiedProgram`;
- `VerifiedProgram` does not expose `ast.Module` as a general backend semantic
  input;
- adding a backend does not require reimplementing semantic analysis.

## Phase 3 — bind artifact provenance

Purpose: make emitted artifacts and their metadata describe the same bytes.

Work items:

1. Introduce one shared artifact metadata object.
2. Attach artifact digest and canonical lowering options to source maps.
3. Record source digest, MIR/fact digest, compiler identity, target, and
   downstream tool identity.
4. Make `mcc build` write the final executable transactionally.

Done when:

- wrong artifact/map pairings are rejected;
- failed or interrupted `build` does not corrupt an existing output;
- release evidence names the same artifact digest produced locally.

## Phase 4 — make manifests authoritative

Purpose: stop Markdown, CI, release, and build files from carrying competing
status truth.

Authoritative inputs:

- `docs/review-risk-register.yaml`;
- `docs/profile-manifest.json`;
- `docs/component-manifest.json`;
- `docs/gate-manifest.json`.

Work items:

1. Validate those manifests together.
2. Make build/CI assertions consume manifest IDs.
3. Generate Markdown summaries where practical.
4. Keep prose navigational and explanatory, not authoritative.

Done when:

- missing or renamed blocking gates fail manifest tests;
- active Markdown has no independent High/Critical open/closed counters;
- profile claims point to manifest IDs and risk IDs.

## Immediate implementation queue

Do these in order unless a failing test forces a narrower slice:

| Order | Slice | Proof |
|---:|---|---|
| 1 | Remove or quarantine the next backend-local semantic helper. | Complete for `src/lower_c_infer.zig`: the retired helper module is deleted, and `semantic-facts-inventory-test` fails if the file is reintroduced. |
| 2 | Convert one call/optional/result MIR family toward typed IDs or verifier-owned facts. | Complete for `if_let_subject` and `try_operand`: MIR admission now rejects forged non-Result/non-nullable subject/operand families before backend emission. |
| 3 | Replace one `VerifiedProgram` AST semantic read with a typed view. | Complete for naked backend `program.syntax_module` reads: C/LLVM entrypoints now use exact-gated legacy/source-map accessors and SourceSpellingView remains the MIR-owned spelling view. |
| 4 | Introduce shared artifact metadata without changing emitted bytes. | Complete for metadata/map envelope writing: `.mcmeta` and `.mcmap` now use the same `artifact_model.ArtifactBundle` writer while preserving their magic/header bytes; artifact envelope construction now lives outside the backend seam. |
| 5 | Bind C source-map output to artifact digest. | Complete for consumer admission: `.mcmap` verification now requires `artifact_kind=c-source-map`, `backend=c`, payload digest, MIR-facts digest, and matching generated artifact digest. |
| 6 | Make `mcc build` final output transactional. | Complete: `mcc build` writes through exclusive temporary C/executable artifacts, preserves the previous executable on clang/hosted-boundary/preflight failures, leaks no `*.mc-build-*` temps on tested failures, and binds the `.mcmeta` sidecar to exact executable bytes so stale sidecars are rejected. The portable contract is digest-bound fail-closed pairing, not an impossible two-path crash-atomic filesystem commit. |
| 7 | Convert one build/CI assertion to consume `gate-manifest.json`. | Complete for `ci-m0-pass`: CI PASS assertions now come from `docs/gate-manifest.json` `ci_pass_assertions`, and `gate-manifest-test` rejects unregistered, duplicate, under-floor, or non-m0 assertion gates. |
| 9 | Continue C source-cast authority reduction. | Complete for nullable and floating source-cast classifiers: both now go through the shared target/result fact helper, and `explicit_cast_target` inventory dropped from 9 to 7 C emitter reads. |
| 10 | Centralize C source-cast result admission. | Complete for enum, tagged-union, numeric, and pointer-pointee source-cast classifiers: they now share `castResultTypeForEmission`, and C emitter `explicit_cast_target` inventory dropped from 7 to 3 reads. |
| 11 | Split C dyn pass-through detection from dyn coercion source authority. | Complete: new vtable wrapper construction consumes `dyn_coercion_source` directly; operand/call typing is limited to existing-dyn pass-through detection, and missing source facts have a focused C regression. |
| 12 | Lock pointer-to-`PAddr` source authority behind MIR facts. | Complete: source `raw.store(ptr, ...)` lowering requires `paddr_coercion_source`; removing that fact rejects prebuilt MIR before C can reconstruct the pointer source type. |
| 13 | Lock aggregate member-copy source authority behind MIR expression results. | Complete: same-struct nested member copy provenance now has a focused C regression proving removal of the `Inner` `expression_result` rejects prebuilt MIR before C can reconstruct source aggregate type. |
| 14 | Gate C member-base source typing on MIR expression results. | Complete: source-spanned member bases now require their own `expression_result` before C uses recovered local/call/member shape as a stale-fact check; the recovered helper is exact-count-gated. |
| 15 | Gate C array/slice base source typing on MIR expression results. | Complete: source-spanned array/slice bases require their own `expression_result`; recovered array/slice/operand shape is only a stale-fact check, generated-node fallback, or exact-gated `__destr*` tuple-destructure synthetic base fallback. |
| 16 | Rename direct identifier source recovery to match its authority boundary. | Complete: `sourceTypeForIdent` is now `identTypeForEmissionRecovered`; the helper name and inventory anchor make clear that declaration recovery is a stale-fact/generated-node aid, not source authority for source-spanned identifiers. |
| 17 | Route direct aggregate-copy identifier source checks through the identifier MIR fact gate. | Complete: same-struct aggregate-copy source identifiers now reuse `identTypeForEmissionRecovered`, so source-spanned locals need matching `expression_result` before local declaration type can classify the copy source. |
| 18 | Route pointer-member operator selection for identifier bases through the identifier MIR fact gate. | Complete: `exprIsPointer` no longer reads `LocalInfo.source_ty` directly for identifier bases; source-spanned identifiers must pass `identTypeForEmissionRecovered` before C selects `->` lowering. |
| 19 | Route direct address-place identifier typing through the identifier MIR fact gate. | Complete: `directAddressPlaceInfo` still reads local/global mutability metadata, but identifier place type now comes through `identTypeForEmissionRecovered`, so source-spanned `&ident` operands need matching `expression_result`. |
| 20 | Route pointer-provenance identifier shape classifiers through the identifier MIR fact gate. | Complete: direct aggregate-member roots, fixed pointer-array bases, raw-many bases, and direct pointer-local copy expressions now use `identTypeForEmissionRecovered` before classifying local pointer/container shape. |
| 21 | Route direct identifier assignment provenance updates through the identifier MIR fact gate. | Complete: direct local assignment provenance now uses `identTypeForEmissionRecovered` before classifying a target as pointer-like, aggregate, or fixed pointer-array local; grouped targets recurse to the identifier path instead of reading `LocalInfo.source_ty` directly. |
| 22 | Make nullable local declaration recovery an explicit generated-only fallback. | Complete: `directNullableLocalTypeForEmission` is now `generatedNullableLocalTypeForEmission`, guards zero-span internally, and remains exact-count-gated as a mechanics-only fallback for generated nodes that cannot have source-keyed `expression_result` rows. |
| 23 | Centralize MIR pointer-provenance fact-subject declaration recovery. | Complete: `mirPointerFactSubjectRecoveredType` is the exact-count-gated entry for checking that a matched MIR `PointerProvenanceFact.subject` still denotes a supported local storage shape; direct `info.source_ty` reads in fact application/invalidation are gone. |
| 24 | Make generated `PAddr` coercion source recovery explicit. | Complete: `paddrCoercionSourceTypeForEmission` now delegates non-fact source recovery to `generatedPaddrCoercionSourceTypeForEmission`, which is zero-span-guarded and exact-count-gated; source-spanned coercions still require `paddr_coercion_source` or `explicit_cast_source`. |
| 25 | Centralize remaining generated C source-type recursion. | Complete: array/slice base fallback, member-base fallback, and generated `PAddr` coercion fallback now call `generatedExprSourceTypeForEmission`, which rejects source-spanned expressions and is exact-count-gated as the remaining zero-span mechanics boundary. |
| 26 | Mirror the source/generated boundary in LLVM expression typing. | Complete: LLVM `exprType` now uses the shared `isSourceSpan` predicate for source-spanned versus generated zero-span expression branches, and the old direct line/column test in that switch is exact-zero-gated. |
| 27 | Clarify optional/result call-result family checks in C. | Complete: Result and nullable inferred-call local classifiers are now named `isResultMirCallResultType` and `isNullableMirCallResultType`, making clear they only check the family of a MIR-gated call result; the old call-return authority names are exact-zero-gated. |
| 28 | Narrow legacy declaration syntax access behind a typed view. | Complete: C/LLVM backend entrypoints now receive explicit `LegacyDeclarationSlice` legacy parameters instead of reading raw syntax or `VerifiedProgram.declarationMetadata()`; the legacy raw accessor is exact-zero-gated while the remaining source-map mechanics accessor stays separate. |
| 29 | Bind one more artifact consumer to the shared artifact metadata path. | Complete: `mcmap-verify.py` now validates `.mcmeta` `artifact_kind` and `backend` identity on request, and CLI/build gates reject C, LLVM, and host-executable sidecars presented as the wrong artifact class. |
| 30 | Continue removing C source-type paths that still recover source facts from locals, calls, or AST shape. | Complete for aggregate member-copy sources: `directAggregateMemberCopySourceTypeForEmission` is retired; the remaining fallback is named `generatedAggregateMemberCopySourceTypeForEmission`, source-spanned expressions still require `expression_result`, and zero-span recursion flows through `generatedExprSourceTypeForEmission`. |
| 31 | Continue mirroring C authority reductions in LLVM for touched expression families. | Complete for aggregate member-copy sources: LLVM now routes that family through `aggregateCopyMemberSourceTypeForEmission`, which consumes `expression_result` for source spans and only falls back to `exprType` for generated zero-span mechanics; direct aggregate-copy `self.exprType(expr)` is exact-zero-gated. |
| 32 | Convert the next optional/result representation family into a typed MIR/verifier-owned fact. | Complete for `Result` try payload pointer representation: C and LLVM now have focused admission tests proving missing or stale `representation_use detail=try_unwrap` facts reject before lowering, so the try-payload pointer representation cannot be recovered by either backend. |
| 33 | Narrow the remaining source-map syntax mechanics escape. | Complete: source-map generation now consumes `SourceMapMechanicsView`; row enumeration is isolated behind a mechanics view instead of a raw `syntaxForSourceMapMechanics()` accessor. |
| 34 | Keep declaration metadata as an explicit view across backend entrypoints. | Complete: C and LLVM verified backend entrypoints now pass `LegacyDeclarationSlice` into their internal lowering entrypoints; backend-specific early metadata accessors are opened only at the remaining legacy mechanics boundary, while raw-module compatibility wrappers construct explicit declaration metadata views. |
| 35 | Reduce one LLVM declaration metadata AST consumer. | Complete for backend-name aliases: LLVM alias emission now uses already-collected ordered function metadata plus `backend_names`/`fn_sigs`, and no longer re-enumerates the syntax module in `emitBackendNameAliases(module)`. |
| 36 | Fold LLVM backend-name metadata collection into the existing function collection pass. | Complete: the early declaration scan no longer reads `decl.attrs` to populate `backend_names`; `collectFunction(fn_decl, attrs)` records backend-name metadata alongside `fn_sigs`, and the old extra attrs enumeration is exact-zero-gated. |
| 37 | Fold LLVM const-global width collection into the existing global collection pass. | Complete: the standalone `collectConstGlobalWidths(module)` syntax scan is gone; const global widths are recorded from each `collectGlobal(global)` declaration, and the old module-level width pass is exact-zero-gated. |
| 38 | Merge C const function and const-global width prepasses. | Complete: C lowering now uses one early `collectConstMetadata(module)` scan for const functions and const global widths, preserving reflection/layout timing while removing the separate `collectConstGlobalWidths(module)` pass; the old const-fn and width passes are exact-zero-gated. |
| 39 | Merge LLVM non-struct type artifact validation scans. | Complete: packed bits, overlay unions, tagged unions, type aliases, and enums now validate through one `collectNonStructTypeArtifacts(module)` pass after type-name preregistration; the old separate `ctx.collect*` module scans are exact-zero-gated. |
| 40 | Merge C early const/type-name metadata prepasses. | Complete: C lowering now uses one early declaration metadata prepass for const functions, const global widths, and nominal type-name preregistration; the old `collectConstMetadata(module)` and `collectForwardTypeNames(module)` passes are exact-zero-gated. |
| 41 | Merge LLVM callable/value declaration artifact scans. | Complete: functions, extern functions, globals, traits, and impl-trait metadata now populate through one `collectCallableAndValueDeclArtifacts(module)` pass; the old separate `ctx.collectFunction` and `ctx.collectGlobal` module scans are exact-zero-gated. |
| 42 | Route C function declaration emission through collected declaration artifacts. | Complete: C function forward declarations, extern prototypes, and function definitions now consume the ordered `function_decl_artifacts` list populated by `collectFnDeclArtifact`, and the old `emitFunctionDeclarations(module)` / `emitFunctionDefinitions(module)` syntax scans are exact-zero-gated. |
| 43 | Route C global definition emission through collected declaration artifacts. | Complete: C global definitions now consume the ordered `global_decl_artifacts` list populated by `collectGlobalDeclArtifact`, and the old `emitGlobalDefinitions(module)` syntax scan is exact-zero-gated. |
| 44 | Route C MMIO struct emission through collected declaration artifacts. | Complete: C MMIO struct definitions now consume the ordered `mmio_struct_decl_artifacts` list populated by `collectStructDeclArtifact`, and the old `emitMmioStructTypes(module)` syntax scan is exact-zero-gated. |
| 45 | Route C aggregate type emission through collected declaration artifacts. | Complete: C dependency-ordered aggregate emission now seeds source-order struct/tagged-union units from the ordered `aggregate_decl_artifacts` list populated by `collectStructDeclArtifact` and `collectTaggedUnion`; the old `emitOrderedAggregates(module)` syntax scan is exact-zero-gated. |
| 46 | Route LLVM global/function emission through collected declaration artifacts. | Complete: LLVM global emission and callable declaration emission now consume ordered `global_decl_artifacts` and `function_decl_artifacts` populated by `collectCallableAndValueDeclArtifacts(module)`; the old `ctx.emitGlobal`, `ctx.emitFunction`, and `ctx.emitExternFunction` module scans are exact-zero-gated. |
| 47 | Fold LLVM const-fn preregistration into the existing early declaration pass. | Complete: LLVM const-fn metadata now populates inside the early declaration prepass before const-global folding, and the old standalone `ctx.const_fns` function scan is exact-zero-gated. |
| 48 | Route LLVM struct artifact validation through collected declaration artifacts. | Complete: LLVM struct validation now consumes ordered `struct_decl_artifacts` populated during the early declaration prepass after non-struct type artifacts are collected; the old direct `ctx.collectStruct` module scan is exact-zero-gated. |
| 49 | Route C aggregate forward declarations through collected declaration artifacts. | Complete: C aggregate forward typedefs now consume ordered `aggregate_decl_artifacts` plus collected array/result maps, and the old `emitAggregateForwardDeclarations(module)` helper/module scan is exact-zero-gated. |
| 50 | Route C bind-thunk discovery through collected function declaration artifacts. | Complete: C bind-thunk discovery now consumes ordered `function_decl_artifacts` after function signatures are collected, and the old `collectBindThunks(module)` syntax scan is exact-zero-gated. |
| 51 | Route C declaration artifact collection through the early declaration list. | Complete, later narrowed by order 66: C lowering originally recorded source-order `decl_artifacts` during the early declaration prepass and the later artifact-collection pass consumed that list; the old second `collectDeclArtifacts(module)` syntax scan is exact-zero-gated. |
| 52 | Route LLVM declaration artifact collection through the early declaration list. | Complete: LLVM lowering now records source-order `decl_artifacts` during the early declaration prepass and the later non-struct/callable declaration collection passes consume that list; the old `collectNonStructTypeArtifacts(module)` and `collectCallableAndValueDeclArtifacts(module)` syntax scans are exact-zero-gated. |
| 53 | Route C source-map row emission through collected mechanics rows. | Complete: C source-map generation now isolates source row enumeration before emitting through `decl_row_artifacts`; the old direct `SourceMapEmitter.emitModule(module)` scan is exact-zero-gated as mechanics-only. |
| 54 | Remove backend-specific legacy declaration accessors. | Complete: `LegacyDeclarationSlice` no longer exposes generic or backend-specific syntax accessors; C and LLVM consume the same explicit declaration slice and the old `syntaxFor*DeclarationMetadata()` accessors are exact-zero-gated. |
| 55 | Collapse C/LLVM early declaration metadata wrappers. | Complete: the dedicated C/LLVM early metadata wrapper types are gone; `LegacyDeclarationSlice` is the only remaining declaration-slice transition view. |
| 56 | Route C/LLVM const-global folding through collected declaration artifacts. | Complete: `eval.collectConstGlobalsFromDeclsWithOptions()` now folds over a caller-provided declaration list; C/LLVM pass the early `decl_artifacts` list, and the old backend module-wide const-global folding calls are exact-zero-gated. |
| 57 | Narrow C/LLVM early declaration metadata prepasses to declaration-list inputs. | Complete: C `collectEarlyDeclarationMetadataFromDecls()` and LLVM `preRegisterTypeDeclsFromDecls()` now consume `module.decls` as an explicit list; the old module-shaped early metadata prepass signatures are exact-zero-gated. |
| 58 | Narrow source-map mechanics row enumeration to declaration-list input. | Complete: `SourceMapMechanicsView` now exposes `declsForRowEnumeration()` instead of an `ast.Module`; C source-map collection uses `collectRowArtifactsFromDecls()`, and the old module-shaped row enumeration accessors are exact-zero-gated. |
| 59 | Keep early declaration metadata as declaration-list only. | Complete: early declaration metadata no longer exposes module-shaped or backend-specific access; C/LLVM use `LegacyDeclarationSlice.declsForEarlyDeclarationScan()` and old `syntaxForEarlyDeclarationScan()` methods are exact-zero-gated. |
| 60 | Narrow comptime evaluation context from module input to declaration-list input. | Complete: `ComptimeScope` now stores `decls: ?[]const ast.Decl` instead of `module: ?ast.Module`; C/LLVM const folding and nested const-fn scopes propagate declaration slices, and the old `moduleForComptimeEvaluation()` view methods are exact-zero-gated. |
| 61 | Store declaration metadata and source-map mechanics as declaration slices. | Complete: `LegacyDeclarationSlice` and `SourceMapMechanicsView` store `[]const ast.Decl` instead of `ast.Module`; module-shaped accessors are exact-zero-gated. |
| 62 | Store parent declaration metadata view as a declaration slice. | Complete: `LegacyDeclarationSlice` now stores `[]const ast.Decl` instead of `ast.Module`, so all declaration/source-map mechanics views are decl-slice views; remaining `VerifiedProgram` syntax storage was isolated for the next slice. |
| 63 | Replace legacy module-shaped view constructors with declaration-slice constructors. | Complete: `LegacyDeclarationSlice` and `SourceMapMechanicsView` now expose `forDecls(...)`; the old `forLegacySyntax(...)` constructors and all call sites are exact-zero-gated. |
| 64 | Store declaration metadata outside `VerifiedProgram`. | Complete: `VerifiedProgram` no longer stores `decls: []const ast.Decl` or `LegacyDeclarationSlice`; declaration metadata is passed as an explicit legacy backend parameter. |
| 65 | Construct `VerifiedProgram` from MIR only. | Complete: `VerifiedProgram.init(...)` replaces declaration-slice construction; `CompilationSession.buildVerifiedProgram` validates MIR without passing `module.decls`, and `backend.VerifiedProgram.initFromDecls(...)` is exact-zero-gated. |
| 66 | Remove C's generic declaration artifact list. | Complete: C early metadata still pre-registers from the declaration slice, but artifact collection now consumes that slice directly through `collectDeclArtifactsFromDecls(decls)`; the old `decl_artifacts: ArrayList(ast.Decl)` storage and generic replay loop are exact-zero-gated. |
| 67 | Gate LLVM direct-address place typing through expression-result facts. | Complete: LLVM `&ident` place classification still uses local/global maps for storage mutability, but source-spanned place type now goes through `identifierExpressionType(operand, ident.text)` and therefore requires a matching `expression_result` fact; direct `slot.ty`/`local_types`/`global_types` place-type reads are exact-zero-gated. |
| 68 | Require typed representation fact result/span identities at lowering admission. | Complete: `validateRepresentationFactsForLowering` now rejects representation facts without valid `typed_result_ty` and `typed_span_id` table matches, so hand-built compatibility MIR cannot make a representation fact and its instruction drift together back to untyped string/line-column matching. |
| 69 | Keep `VerifiedProgram` free of syntax-backed mechanics views. | Complete: `VerifiedProgram` no longer stores a generic declaration slice, `LegacyDeclarationSlice`, or `SourceMapMechanicsView`; declaration metadata and source-map syntax mechanics are explicit legacy backend/emit-map parameters, so remaining syntax-shaped access must go through named mechanics views and the old raw declaration field/count is exact-gated. |
| 70 | Bind emit-c metadata sidecar consumers to artifact/source identity. | Complete: the `emit-c -o` CLI gate now verifies the `.mcmeta` sidecar through `mcmap-verify.py` with artifact kind, backend, generated artifact digest, and loaded-source digest, and rejects wrong backend, wrong artifact bytes, and wrong loaded-source bytes. |
| 71 | Centralize LLVM expression source/generated boundary checks. | Complete: LLVM comparison operand member/index typing, identifier expression typing, and `expressionResultTypeAt` now use the shared `isSourceSpan` gate instead of ad hoc line/column checks; the retired direct checks and new shared-gate counts are exact-gated. |
| 72 | Centralize C expression source/generated boundary checks. | Complete: C nullable/tagged-union grouped typing, generated nullable-local recovery, and boolean expression classification now use the shared `isSourceSpan` gate instead of localized line/column checks; the retired direct checks and new shared-gate counts are exact-gated. |
| 73 | Centralize more C source/generated type-query checks. | Complete: C generated `PAddr` recovery, numeric result classification, condition operand typing, slice result/base typing, cast result typing, and operand member/index typing now use `isSourceSpan`; the retired localized checks and replacement counts are exact-gated. |
| 74 | Isolate legacy backend syntax mechanics outside the core backend seam. | Complete: `LegacyDeclarationSlice` and `SourceMapMechanicsView` moved to `legacy_backend_syntax.zig`; `backend.zig` no longer imports `ast.zig` or contains `[]const ast.Decl`, and architecture/semantic inventory gates ratchet the backend AST import and declaration-slice counts down. |
| 74 | Centralize C recursive source-type query boundaries. | Complete: C identifier recovery, member-base typing, array/pointer/deref/struct/call type queries, source member/index/slice/grouped typing, and generated recursive source-type fallback now use `isSourceSpan`; retired localized checks and replacement counts are exact-gated. |
| 75 | Remove remaining direct C expression span boundary checks. | Complete: C unary-result, member-result, dyn pass-through, enum grouped, array/slice base, aggregate-copy generated fallback, and MIR target-type zero-span guards now use `isSourceSpan`; direct `expr.span.line` / `expr.span.column` and related base/member-span checks in `lower_c_emitter.zig` are exact-zero-gated. |
| 76 | Centralize remaining LLVM source/generated span guards. | Complete: LLVM null-literal expected-type selection, switch/if-let subject facts, try operand facts, target-type fact lookup helpers, struct-literal construction fallback, generated direct-call dispatch, and generated Result constructors now use `isSourceSpan`; retired direct LLVM line/column guards are exact-gated. |
| 77 | Cache LLVM call-target kind in expression type hot paths. | Complete: LLVM `callExpressionType` and `callReturnType` now look up a call expression's MIR call-target kind once per helper and reuse it for migrated call result branches; retired repeated `assume_noalias` / `declassify` direct lookups and the new local `call_kind` gates are exact-counted. |
| 78 | Cache LLVM call-target kind in builtin value emission. | Complete: LLVM `emitBuiltinValueCall` now looks up the MIR call-target kind once and reuses it for declassify, assume-noalias, phys, raw-load, varargs, and raw-ptr value emission; retired repeated direct call-kind lookups and the expanded local `call_kind` gates are exact-counted. |
| 79 | Cache LLVM call-target kind in builtin void emission. | Complete: LLVM `emitBuiltinVoidCall` now looks up the MIR call-target kind once and reuses it for raw-store, cpu-pause, and fence dispatch; the reduced direct lookup count plus the new `call_kind` raw-store/cpu-pause/fence gates are exact-counted. |
| 80 | Pass cached raw call-target kind into LLVM raw call info. | Complete: LLVM `rawCallInfo` now receives the already-confirmed MIR raw call-target kind from raw-store/raw-load/raw-ptr callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 81 | Pass cached const-get call-target kind into LLVM const-get info. | Complete: LLVM `constGetCallInfo` now receives the already-confirmed `.const_get` call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 82 | Pass cached enum-raw call-target kind into LLVM enum-raw info. | Complete: LLVM `enumRawCallInfo` now receives the already-confirmed `.enum_raw` call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 83 | Pass cached domain-residue call-target kind into LLVM residue info. | Complete: LLVM `domainResidueCallInfo` now receives the already-confirmed `.wrap_residue` call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 84 | Pass cached arithmetic-domain call-target kind into LLVM domain-op info. | Complete: LLVM `domainOpCallInfo` now receives the already-confirmed arithmetic-domain call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 85 | Pass cached wrapping call-target kind into LLVM wrapping info. | Complete: LLVM `wrappingCallInfo` now receives the already-confirmed wrapping call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 86 | Pass cached unchecked call-target kind into LLVM unchecked info. | Complete: LLVM `uncheckedCallInfo` now receives the already-confirmed unchecked arithmetic call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 87 | Pass cached reduce call-target kind into LLVM reduce info. | Complete: LLVM `reduceCallInfo` now receives the already-confirmed reduce call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 88 | Pass cached conversion call-target kind into LLVM conversion info. | Complete: LLVM `conversionCallInfo` now receives the already-confirmed scalar conversion call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 89 | Pass cached byte-view call-target kind into LLVM byte-view info. | Complete: LLVM `byteViewCallInfo` now receives the already-confirmed byte-view call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 90 | Pass cached reflection call-target kind into LLVM reflection info. | Complete: LLVM `reflectionCallInfo` now receives the already-confirmed reflection call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; `reflectionCallValue` consumes the already-built info and old no-kind helper/value call sites are exact-zero-gated. |
| 91 | Pass cached bitcast/phys call-target kinds into LLVM target-type helpers. | Complete: LLVM `bitcastCallTargetType` and `physCallTargetType` now receive already-confirmed `.bitcast` / `.phys` call-target kinds from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 92 | Pass cached MMIO-map call-target kind into LLVM MMIO-map info. | Complete: LLVM `mmioMapCallInfo` now receives the already-confirmed `.mmio_map` call-target kind from value-emission and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 93 | Pass cached raw-many-offset call-target kind into LLVM raw-many-offset info. | Complete: LLVM `rawManyOffsetCallInfo` now receives the already-confirmed `.raw_many_offset` call-target kind from value-emission, expression-typing, and provenance callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 94 | Pass cached MaybeUninit call-target kind into LLVM MaybeUninit info. | Complete: LLVM `maybeUninitCallInfo` now receives the already-confirmed MaybeUninit call-target kind from void-emission, value-emission, and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 95 | Pass cached atomic call-target kind into LLVM atomic info. | Complete: LLVM `atomicCallInfo` now receives the already-confirmed atomic call-target kind from void-emission, value-emission, and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 96 | Pass cached DMA call-target kind into LLVM DMA info. | Complete: LLVM `dmaCacheCallInfo` and `dmaBufCallInfo` now receive the already-confirmed DMA call-target kind from void-emission, value-emission, and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 97 | Pass cached varargs call-target kind into LLVM varargs info. | Complete: LLVM `vaCallInfo` now receives the already-confirmed varargs call-target kind from local-initializer, value-emission, and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 98 | Pass cached MMIO-access call-target kind into LLVM MMIO-access info. | Complete: LLVM `mmioAccessInfo` now receives the already-confirmed MMIO access call-target kind from void-emission, value-emission, and expression-typing callers instead of rescanning the call's fact table internally; old no-kind call sites are exact-zero-gated. |
| 99 | Use the call-target predicate for LLVM assume-noalias provenance checks. | Complete: LLVM `isMirAssumeNoaliasCall` now uses the existing call-target predicate instead of directly rescanning the call's fact table in the provenance helper; the old direct assume-noalias lookup is exact-zero-gated. |
| 100 | Cache LLVM statement-level call-target kind in expression statement lowering. | Complete: LLVM expression-statement lowering now looks up a call statement's MIR call-target kind once and reuses it for `drop`/`forget_unchecked` and varargs statement dispatch; the previous duplicate direct call-span lookup is retired. |
| 101 | Centralize LLVM explicit-trap call-target helper selection. | Complete: LLVM `emitNeverExpr` and `exprStatementDiverges` now share `trapHelperForCall`, so explicit-trap statement emission and divergence classification use one MIR call-target helper-selection path; the previous per-consumer direct call-span lookups are retired. |

## Next implementation batch

After order 101 is verified, keep the next patches small and biased toward
removing backend authority before adding new abstractions:

| Next | Slice | Closure signal |
|---:|---|---|
| 102 | Cache C statement-level call-target kind and centralize explicit-trap helper selection. | Complete: C statement lowering now looks up raw-store, cpu-pause, and fence call-target kinds once through a local `call_kind`, and explicit-trap statement emission uses `trapHelperForCall`; the retired direct statement-level call-span lookups are exact-zero-gated. |
| 103 | Cache C call-return type call-target kind and pass confirmed kinds into result helpers. | Complete: C `callReturnTypeForCall` now looks up a call span's MIR target kind once and reuses it for enum-raw, const-get, DMA/domain, declassify, assume-noalias, raw-many-offset, raw-result, and MaybeUninit result typing; raw and MaybeUninit result helpers consume the confirmed kind instead of rescanning the call span. |
| 104 | Use the call-target predicate for C assume-noalias provenance checks. | Complete: C `isMirAssumeNoaliasCall` now uses the shared MIR call-target predicate instead of directly comparing a call-span lookup; the old direct assume-noalias comparison is exact-zero-gated. |
| 105 | Use the call-target predicate for C raw-load float classification. | Complete: C `callResolvesToFloat` now uses the shared MIR call-target predicate for the raw-load special case and still consumes the MIR `raw_result` type fact for the float decision; the old direct raw-load comparison is exact-zero-gated. |
| 106 | Use the call-target predicate for C bind emission. | Complete: C `emitNamedSpecialCallExpr` now gates `bind` lowering through `mirHasCallTargetKindAt(.bind, ...)` instead of directly comparing the call-span lookup; the stale `.bind` target-type fact guard remains, and the old direct bind comparison is exact-zero-gated. |
| 107 | Cache LLVM va_list initializer call-target kinds. | Complete: LLVM local-initializer lowering now caches `init.kind.call` and its MIR call-target kind before detecting `va_start` for both va_list storage paths; the old direct `init.kind.call.callee.*.span` lookups and old no-cache `vaCallInfo(init.kind.call, kind)` form are exact-zero-gated. |
| 108 | Cache LLVM generic call-target kind before bind/drop dispatch. | Complete: LLVM `emitCall` now caches the call span's MIR target kind once and reuses it for drop/forget rejection and bind value emission; the old repeated direct `mirCallTargetKindAt(span) == .bind` check is exact-zero-gated. |
| 109 | Cache LLVM Result-constructor call-target kind. | Complete: LLVM value emission now caches the call span's MIR target kind before selecting `Result` constructor facts, while generated zero-span mechanics still use the explicit generated constructor path; the old inline `mirCallTargetKindAt(span)` result-constructor lookup is exact-zero-gated. |
| 110 | Exact-gate C call-expression result queries behind the fact-backed emission interface. | Complete: C expression-result consumers now call `callResultTypeForEmission`, whose source-spanned call and grouped-call paths require the MIR `expression_result` row and use call-return mechanics only as stale-fact validation; the retired `callReturnTypeForExpr` interface is exact-zero-gated. |
| 111 | Exact-gate LLVM call-result mechanics behind the fact-backed emission interface. | Complete: LLVM statement and expression call-result consumers now call `callResultTypeForEmission`, while source call expressions still require `expression_result` through `callExpressionType`; the retired `callReturnType` helper and old call sites are exact-zero-gated. |
| 112 | Bind MIR call-target facts to exact callee spans. | Complete: MIR call-target facts for ordinary source calls now store the callee span, including offset/length, instead of the whole call expression's line/column-only source point; LLVM call-target lookup uses an exact source matcher, and direct-call fact/declaration checks accept span-insensitive same syntax types. The retired ordinary `addCallTargetFact(..., expr.span)` forms are exact-zero-gated. |
| 113 | Gate LLVM non-call expression-statement typing behind an emission helper. | Complete: LLVM non-call expression statements now route through `exprStatementTypeForEmission`; source-spanned statements require their own MIR `expression_result` row and use `exprType` only as a stale-fact check, while generated zero-span mechanics keep the bounded fallback. The retired direct `exprType` statement fallback is exact-zero-gated. |
| 114 | Centralize LLVM switch/if-let subject type admission. | Complete: LLVM switch and if-let subject lowering now route through `requireMirSubjectType`, so source-spanned subjects share the same MIR target-type fact lookup, stale-fact comparison, and nullable representation admission. The retired duplicated `.switch_subject` / `.if_let_subject` direct fact lookups are exact-zero-gated. |
| 115 | Centralize LLVM target-type emission admission for `try` operands. | Complete: LLVM `try` operand admission now routes through `requireMirTargetTypeForEmission`, so source-spanned operands require the MIR `.try_operand` target-type fact and use `exprType` only as a stale-fact check. The retired direct `requireMirTryOperandType` fact lookup is exact-gated. |
| 116 | Consolidate duplicate `test-spec` diagnostic fixture passes. | Complete: the declared diagnostic-code, inline `EXPECT_ERROR` line, and unexpected semantic-diagnostic checks now share one per-fixture parse/sema pass. The coverage is preserved, import-aware checks remain import-aware, non-import fixtures still reject undeclared compiler errors, and hot-cache `m0` drops to roughly 9s. |
| 117 | Centralize LLVM bool condition target-type admission. | Complete: LLVM runtime assert and while-loop condition lowering now share `requireMirBoolTargetTypeForEmission`, so source-spanned conditions use one target-type fact admission path and both retired direct `.assert_condition` / `.loop_condition` lookups are exact-zero-gated. |
| 118 | Route LLVM `for` iterable admission through the shared target-type helper. | Complete: LLVM `for` lowering now admits the iterable through `requireMirTargetTypeForEmission(.for_iterable, ...)`, so source-spanned iterable facts use the same stale-fact validation path as other migrated target types. The element fact remains a separate `.for_element` row because it is the loop binding type, not the iterable expression type. The retired direct `.for_iterable` lookup is exact-zero-gated. |
| 119 | Centralize C bool condition target-type admission. | Complete: C runtime assert and while-loop lowering now share `requireMirBoolTargetTypeForEmission`, so both condition paths use one bool target-type admission helper and the retired direct `.assert_condition` / `.loop_condition` lookups are exact-zero-gated for C. |
| 120 | Route C `for` iterable admission through the shared target-type helper. | Complete: C `for` lowering now admits the iterable through `requireMirForIterableTypeForEmission`, which delegates to the C target-type emission helper with the existing iterable stale-fact check. The element fact remains a separate `.for_element` row because it is the loop binding type, not the iterable expression type. The retired direct `.for_iterable` lookup is exact-zero-gated for C. |
| 121 | Route C/LLVM `for` element admission through loop-element helpers. | Complete: C and LLVM `for` lowering now read the `.for_element` row through `requireMirForElementTypeForEmission`. The element fact remains independent from the iterable expression type and is still checked against the iterable child type, but both retired direct `.for_element` lookups are exact-zero-gated. |
| 122 | Route LLVM discard argument admission through the target-type helper. | Complete: LLVM `drop` / `forget_unchecked` statement lowering now reads `.discard_argument` through `requireMirDiscardArgumentTypeForEmission`, which delegates to the shared target-type emission helper. The retired direct `.discard_argument` lookup is exact-zero-gated. |
| 123 | Route LLVM inferred-local try operand admission through the shared helper. | Complete: LLVM inferred-local `try` payload result validation now reads the operand type through `requireMirTryOperandType`, so this path uses the same `.try_operand` target-type admission helper as try-expression lowering. The remaining direct LLVM `.try_operand` lookup budget drops from 2 to 1. |
| 124 | Retire the remaining direct LLVM `try_operand` fact read. | Complete: LLVM expression-type queries now use `mirTryOperandTypeForQuery`, which delegates to `requireMirTryOperandType` and preserves the query-style `null` result on unsupported or stale facts. The direct LLVM `.try_operand` fact-read budget is now exact-zero-gated. |
| 125 | Retire direct C `try_operand` fact reads. | Complete: C inferred-local try payload validation and try-hoist scan predicates now use `mirTryOperandTypeForQuery`, which delegates to `requireMirTargetTypeForEmission(.try_operand, ...)` while preserving query-style `null` / `false` results. The direct C `.try_operand` fact-read budget is now exact-zero-gated. |
| 126 | Name the C discard-argument target-type admission point. | Complete: C `drop` / `forget_unchecked` lowering now consumes `.discard_argument` through `discardArgumentTypeForEmission`, making the only remaining C discard target-type lookup a named helper instead of a one-off call-site read; the helper and call site are exact-gated. |
| 127 | Consolidate C raw-address target-type admission. | Complete: C `raw.load` / `raw.ptr` lowering now consumes `raw_address`, `raw_payload`, and `raw_result` through `rawAddressTypesForEmission`, so the two branches share one complete MIR target-type admission point. Each raw-address fact lookup drops from two direct reads to one exact-gated helper read. |
| 128 | Consolidate C varargs target-type admission. | Complete: C `va.arg` / `va.end` lowering now consumes cursor/payload/result rows through `vaCallTypesForEmission`, so cursor/result admission is shared and the remaining payload read is localized to the `va.arg` path. The C varargs target-type helper and call sites are exact-gated. |
| 129 | Name the C physical-address result admission point. | Complete: C `phys(value)` lowering now consumes `.phys_result` through `physResultTypeForEmission`, keeping the MIR result-type admission visible and exact-gated instead of a one-off call-site read. |
| 130 | Consolidate C semantic-escape type admission. | Complete: C `reveal` / `assume_noalias_unchecked` lowering now consumes source/result target-type rows through `declassifyTypesForEmission` and `assumeNoaliasTypesForEmission`, both backed by the shared `semanticEscapeTypesForEmission` helper. The source/result fact reads remain exact-gated in one named admission path. |
| 131 | Consolidate C bitcast source/target admission. | Complete: C bitcast value-temp, local-init, and inferred-local lowering now consume `bitcast_source` and `bitcast_target` through `bitcastTypesForEmission`. The old target-only helper is exact-zero-gated, and the bitcast source fact read drops from two direct reads to one named admission point. |
| 132 | Consolidate LLVM raw-address and varargs target-type admission. | Complete: LLVM `raw.load` / `raw.ptr` / `raw.store` now consume the `raw_address` / `raw_payload` / `raw_result` triplet through `rawAddressTypesForEmission`, and LLVM `va.start` / `va.arg` / `va.end` now consume cursor/payload/result rows through `vaCallTypesForEmission`. The raw and varargs fact reads remain exact-gated in named admission paths instead of one-off helper bodies. |
| 133 | Consolidate LLVM semantic-escape target-type admission. | Complete: LLVM `declassify` / `assume_noalias` value emission now consumes source/result rows through `declassifyTypesForEmission` and `assumeNoaliasTypesForEmission`, backed by `semanticEscapeTypesForEmission`. LLVM expression-type queries use the matching query helpers, so the concrete `.declassify_*` / `.assume_noalias_*` direct reads are exact-zero-gated. |
| 134 | Consolidate LLVM bitcast source/target admission. | Complete: LLVM bitcast value emission and expression-result queries now consume `bitcast_source` / `bitcast_target` through `bitcastTypesForEmission` / `bitcastTypesForQuery`. The old target-only `bitcastCallTargetType` helper and its call sites are exact-zero-gated. |
| 135 | Name LLVM physical-address result admission. | Complete: LLVM `phys(value)` value emission and expression-result queries now consume `.phys_result` through `physResultTypeForEmission` / `physResultTypeForQuery`. The old `physCallTargetType` helper and its call sites are exact-zero-gated. |
| 136 | Consolidate LLVM enum-raw target-type admission. | Complete: LLVM `value.raw()` classification now consumes `.enum_raw_source` / `.enum_raw_result` through `enumRawTypesForEmission`, keeping source/result type admission in one exact-gated helper instead of inline reads inside `enumRawCallInfo`. |
| 137 | Consolidate LLVM reduction source/element admission. | Complete: LLVM `reduce.sum_*` classification now consumes `.reduce_source` / `.reduce_element` through `reduceTypesForEmission`, keeping the slice and element type admission in one exact-gated helper before result-type construction. |
| 138 | Consolidate C enum-raw and reduction target-type admission. | Complete: C `value.raw()` emission now consumes `.enum_raw_source` / `.enum_raw_result` through `enumRawTypesForEmission`, and C `reduce.sum_*` emission now consumes `.reduce_source` / `.reduce_element` through `reduceTypesForEmission`. The remaining direct reads are exact-gated helper reads instead of inline emission reads. |
| 139 | Consolidate LLVM wrapping/unchecked operand-result admission. | Complete: LLVM `wrapping.*` and `unchecked.*` call classification now consume left/right/result target-type rows through `wrappingTypesForEmission` and `uncheckedTypesForEmission`, both backed by the shared `arithmeticCallTypesForEmission` helper. Concrete `.wrapping_*` / `.unchecked_*` direct reads are exact-zero-gated. |
| 140 | Consolidate C wrapping/unchecked operand-result admission. | Complete: C `wrapping.*` and `unchecked.*` call info now consumes left/right/result target-type rows through `wrappingTypesForEmission` and `uncheckedTypesForEmission`, both backed by the shared `arithmeticCallTypesForEmission` helper. Concrete C `.wrapping_*` / `.unchecked_*` target-type reads are exact-zero-gated. |
| 141 | Consolidate LLVM arithmetic-domain target-type admission. | Complete: LLVM `wrap.residue()` and serial/counter domain operation classification now consume domain/payload/result/interval target-type rows through `domainTypesForEmission`. Direct `.domain_type` / `.domain_payload` / `.domain_result` reads are reduced to one exact-gated helper read, with `.domain_interval` read only for interval-bearing operations. |
| 142 | Consolidate C arithmetic-domain target-type admission. | Complete: C `wrap.residue()` and serial/counter domain operation emission now consume domain/payload/result/interval target-type rows through `residueTypesForEmission` and `domainTypesForEmission`. Direct `.domain_*` reads remain only inside exact-gated helper admission instead of inline emission paths. |
| 143 | Name C arithmetic-domain call-result admission. | Complete: C `callReturnTypeForCall` now routes MIR domain identities through `domainResultReturnTypeForCall` before consuming `.domain_result`, documenting that inferred-local result typing must use the MIR domain result row instead of rebuilding wrap/Duration/Result shapes from the AST. |
| 144 | Name C DMA call-result admission. | Complete: C `callReturnTypeForCall` now routes MIR DMA identities through `dmaResultReturnTypeForCall` before consuming `.dma_result`, documenting that inferred-local DMA result typing must use the MIR result row instead of reconstructing DMA address or slice result shapes from receiver/type spelling. |
| 145 | Name C enum-raw and const-get call-result admission. | Complete: C `callReturnTypeForCall` now routes MIR enum-raw and const-get identities through `enumRawResultReturnTypeForCall` and `constGetResultReturnTypeForCall` before consuming `.enum_raw_result` / `.const_get_result`, keeping inferred-local result typing tied to MIR result rows instead of enum lookup or array shape reconstruction. |
| 146 | Name C semantic-escape call-result admission. | Complete: C `callReturnTypeForCall` now routes MIR declassify and assume-noalias identities through `declassifyResultReturnTypeForCall` and `assumeNoaliasResultReturnTypeForCall` before consuming `.declassify_result` / `.assume_noalias_result`, keeping capability-sensitive inferred-local result typing tied to MIR rows instead of ordinary call or pointer spelling inference. |
| 147 | Name C raw-many-offset call-result admission. | Complete: C `callReturnTypeForCall` now routes MIR raw-many offset identities through `rawManyOffsetResultReturnTypeForCall` before consuming `.raw_many_offset_result`, keeping inferred-local pointer result typing tied to MIR rows instead of receiver spelling or alias reconstruction. |
| 148 | Consolidate C simple builtin call-result admission. | Complete: C `callReturnTypeForCall` now routes reflection, byte-view, bitcast, conversion, and physical-address inferred-local result typing through `simpleMirResultReturnTypeForCall`, keeping those simple MIR result rows out of inline call-return shortcuts. |
| 149 | Name C direct-call result admission. | Complete: C `callReturnTypeForCall` now delegates ordinary direct-call result typing to `directCallReturnTypeForCall`, keeping `.direct_call_result` consumption and declared-return validation in one named helper instead of inline fallback logic. |
| 150 | Name C closure-call result admission. | Complete: C `callReturnTypeForCall` now delegates closure callee return extraction to `closureCallReturnTypeForCall`, keeping closure result typing out of inline fallback logic and exact-gating the old direct extraction shape. |
| 151 | Name C indirect-call result admission. | Complete: C `callReturnTypeForCall` now delegates MIR `indirect_call_callee` signature return extraction to `indirectCallReturnTypeForCall`, keeping function-pointer and closure signature result typing out of inline fallback logic. |
| 152 | Consolidate C call expression-result admission. | Complete: C `callResultTypeForEmission` now routes both direct call expressions and grouped call expressions through `callExpressionResultTypeForEmission` before consuming the source `expression_result` row, so stale-row comparison and generated-node fallback are centralized. |
| 153 | Consolidate C nullable/tagged grouped expression-result admission. | Complete: C nullable and tagged-union grouped expression typing now share `checkedExpressionResultTypeForEmission` with call result typing before consuming source `expression_result` rows, centralizing stale-row comparison and generated-node fallback. |
| 154 | Consolidate C condition/source grouped expression-result admission. | Complete: C condition grouped/unary result typing and grouped source-type typing now share `checkedExpressionResultTypeForEmission`, reducing direct `expression_result` stale-row checks to the remaining exact-gated mechanics paths. |
| 155 | Consolidate C grouped array expression-result admission. | Complete: C grouped array typing now uses `checkedExpressionResultTypeForEmission` before projecting the array shape, leaving only storage-type mechanics paths on the direct grouped stale-row inventory. |
| 156 | Consolidate C storage grouped expression-result admission. | Complete: C grouped slice-result, generated slice-base, and operand storage typing now share `checkedStorageExpressionResultTypeForEmission`, so the direct grouped stale-row inventory is exact-zero-gated. |
| 157 | Route C dyn pass-through generated fallback through the generated source-type helper. | Complete: `dynPassThroughTypeForEmission` no longer hand-rolls the zero-span `exprSourceTypeForEmission` fallback; it delegates to `generatedExprSourceTypeForEmission`, keeping source-spanned dyn coercion authority fail-closed. |
| 158 | Name C grouped enum-name admission. | Complete: `enumNameForValueExpr` now delegates grouped enum typing to `groupedEnumNameForValueExpr`, separating source `expression_result` authority from zero-span generated recursion and exact-gating the old inline grouped fallback. |
| 159 | Name C grouped expression classification admission. | Complete: C grouped bool, pointer, deref-pointee, and struct-name classification now use named helpers, separating source `expression_result` authority from zero-span recursion and exact-zero-gating the generic inline grouped fallback. |
| 160 | Name C bool expression classification admission. | Complete: C bool literal, storage, binary, unary, and source `expression_result` checks now use named helpers, retiring the old inline bool source/generated classifier shapes. |
| 161 | Centralize C storage-or-expression result admission. | Complete: C bool-storage, numeric deref, condition member/index, array member/index, pointer member, deref-pointee member/index, and struct-name member/index queries now share `storageOrExpressionResultTypeForEmission`, leaving only the special pointee-derived array-deref case in that inline source/generated inventory. |
| 162 | Name C array-deref result admission. | Complete: C pointer-to-array deref typing now uses `arrayDerefResultTypeForEmission`, preserving the zero-span pointee fallback and source `expression_result` stale-row check while exact-zero-gating the last inline `const ty = if (!isSourceSpan(...))` inventory path. |
| 163 | Name C explicit-cast result admission. | Complete: `castResultTypeForEmission` now delegates to `checkedCastResultTypeForEmission`, preserving zero-span generated cast typing while source casts require matching `explicit_cast_target` and `expression_result` rows. |
| 164 | Name C generated member-result fallback. | Complete: `memberResultTypeOrGenerated` now delegates the zero-span declaration fallback to `generatedMemberResultTypeForEmission`, so source members remain expression-result gated and the old inline generated-member return shape is exact-zero-gated. |
| 165 | Name C generated aggregate member-copy source fallback. | Complete: generated aggregate member-copy source typing now separates source `expression_result` admission, generated fallback admission, and generated storage/source recovery through named helpers, exact-zero-gating the old inline three-line fallback. |
| 166 | Name C nullable generated fallback. | Complete: `nullableExpressionResultTypeOrGenerated` now separates source `expression_result` admission from `generatedNullableExpressionTypeForEmission`, and nullable-shape filtering uses `nullableTypeFromCandidate` instead of inline candidate checks. |
| 167 | Name C tagged-union call candidate admission. | Complete: `taggedUnionTypeForExpr` now delegates call candidate typing to `taggedUnionCallCandidateTypeForEmission`, separating qualified-union MIR result admission from ordinary call-result stale-shape validation before the final tagged-union filter. |
| 168 | Centralize C nullable candidate filtering. | Complete: nullable call, cast, null-literal target, and generated-local recovery paths now reuse `nullableTypeFromCandidate`, leaving nullable shape selection in one helper instead of scattered inline `.nullable` checks. |
| 169 | Reuse C nullable candidate filtering in predicate paths. | Complete: nullable inferred-local call-result and try-operand predicate checks now reuse `nullableTypeFromCandidate`, so boolean nullable classifiers no longer carry separate inline representation tests. |
| 170 | Reuse C tagged-union candidate filtering in predicate paths. | Complete: tagged-union switch dispatch and inferred-local call-result predicates now reuse `taggedUnionTypeFromType`, leaving tagged-union shape selection in one helper instead of scattered direct registry checks. |
| 171 | Centralize C value-optional candidate filtering. | Complete: try-replacement value-optional predicates and value-optional coercion now reuse `valueOptionalPayloadFromCandidate`, leaving nullable-payload representation selection in one helper instead of scattered inline nullable/payload checks. |
| 172 | Centralize C Result candidate filtering. | Complete: Result switch dispatch, Result if-let admission, and inferred-local call-result predicates now reuse `resultTypeFromCandidate`, leaving generic `Result` family selection in one helper instead of scattered inline generic-name checks. |
| 173 | Reuse C value-optional filtering in representation paths. | Complete: nullable representation selection and race-tolerant aggregate classification now reuse `valueOptionalPayloadFromCandidate`, so value-optional payload checks are no longer duplicated outside the helper. |
| 174 | Centralize C array/slice/enum candidate filtering. | Complete: inferred-local array, slice, and enum call-result predicates now reuse `arrayTypeFromType`, `sliceTypeFromCandidate`, and `enumTypeFromCandidate`, leaving those family-shape checks in named helpers instead of inline kind/registry tests. |
| 175 | Reuse C enum candidate filtering in switch paths. | Complete: enum switch dispatch and generic-switch enum-name selection now reuse `enumTypeFromCandidate` / `enumNameFromCandidate`, avoiding repeated direct enum registry checks in switch lowering. |
| 176 | Delegate C enum name helper to the candidate filter. | Complete: `enumNameForType` now delegates to `enumNameFromCandidate`, keeping enum name selection behind the same registry filter used by switch and inferred-local predicate paths. |
| 177 | Centralize C struct name filtering. | Complete: `isKnownStructType` and `directStructTypeName` now reuse `structNameFromCandidate`, leaving struct registry/name selection in one helper instead of duplicated direct registry checks. |
| 178 | Centralize C pointer candidate filtering. | Complete: member-base pointer checks, direct/member expression pointer checks, and grouped pointer checks now reuse `pointerTypeFromCandidate`, leaving pointer-family selection in one helper instead of repeated inline `.pointer` tests. |
| 179 | Reuse C slice candidate filtering in slice access. | Complete: slice `.ptr`/`.len` fallback access now reuses `sliceTypeFromCandidate`, avoiding another inline `.slice` test outside the named slice candidate helper. |
| 180 | Centralize C raw-many pointer candidate filtering. | Complete: direct raw-many local-name recovery now uses `rawManyPointerTypeFromCandidate`, keeping raw-many pointer family selection behind a named helper instead of an inline `.raw_many_pointer` test. |
| 181 | Centralize C array/slice element candidate filtering. | Complete: indexed member-field element recovery now uses `arrayOrSliceElementTypeFromCandidate`, keeping array/slice element selection in one helper instead of an inline kind switch. |
| 182 | Centralize C dyn-trait candidate filtering. | Complete: dyn-target/pass-through checks and target trait-name recovery now reuse `dynTraitNameFromCandidate`, leaving direct dyn versus nullable-dyn selection in one helper instead of duplicated inline kind switches. |
| 183 | Centralize C dyn pointer-source pointee filtering. | Complete: pointer-value dyn coercion now uses `dynPointerSourcePointeeFromCandidate`, keeping existing-dyn pass-through and pointer-pointee selection out of the emission body. |
| 184 | Reuse C array candidate filtering in direct-address index places. | Complete: direct-address index place recovery now uses `arrayTypeFromType` for the array-base gate instead of reopening the alias-resolved kind in the place analysis body. |
| 185 | Centralize C dyn-dispatch receiver trait filtering. | Complete: dynamic member-call dispatch now uses `dynDispatchTraitNameFromCandidate`, keeping direct `dyn Trait` versus `*dyn Trait` receiver selection out of `dynCalleeTrait`. |
| 186 | Reuse C struct/pointer-struct name filtering in member fallback paths. | Complete: generated-member fallback and aggregate field lookup now reuse `structTypeNameFromType` instead of carrying duplicate `name` / `pointer -> name` switches. |
| 187 | Reuse C array/slice element filtering in for-loop stale-fact checks. | Complete: `requireMirForLoopTypes` now uses `arrayOrSliceElementTypeFromCandidate` when comparing the MIR-owned `for_element` fact against the iterable's child type. |
| 188 | Reuse C array/slice element filtering in index expression stale-fact checks. | Complete: `emitIndexExpr` now uses `arrayOrSliceElementTypeFromCandidate` when comparing a MIR-owned index `expression_result` against the base element type. |
| 189 | Reuse C slice candidate filtering in slice `.len` member emission. | Complete: slice `.len` emission now uses `sliceTypeFromCandidate` for the base slice gate instead of directly reopening the alias-resolved `.slice` kind. |
| 190 | Reuse C array/slice element filtering in indexed member-path typing. | Complete: `indexedElementType` now uses `arrayOrSliceElementTypeFromCandidate` instead of carrying a separate inline array/slice child switch. |
| 191 | Reuse C array candidate filtering in for-loop element planning. | Complete: `emitForLoop` now uses `arrayTypeFromType` for the fixed-array iterable gate before building the C element plan. |
| 192 | Centralize C pointer node filtering for direct-address inferred locals. | Complete: `emitAddressOfInferredLocalInit` now uses `pointerNodeFromCandidate` for the MIR-owned pointer result gate instead of destructuring `.pointer` inline. |
| 193 | Reuse C nullable candidate filtering in value-optional pass-through. | Complete: `emitValueOptionalCoercion` now uses `nullableTypeFromCandidate` to detect optional pass-through sources instead of reopening the alias-resolved `.nullable` kind. |
| 194 | Reuse C nullable candidate filtering in switch/if-let subject admission. | Complete: nullable switch and if-let subject gates, plus their nullable representation extraction from MIR facts, now use `nullableTypeFromCandidate` instead of direct `.nullable` kind tests. |
| 195 | Centralize C closure target filtering for bind emission. | Complete: `bindEmitPlan` now uses `closureNodeFromCandidate` for the closure target gate instead of directly checking and unpacking `.closure_type`. |
| 196 | Reuse C array candidate filtering in default local initialization. | Complete: default local initialization now uses `arrayTypeFromType` for the aggregate-zero array initializer gate instead of checking the declared type's `.array` kind inline. |
| 197 | Reuse C slice candidate filtering in slice call-result typing. | Complete: `sliceReturnTypeForExpr` now uses `sliceTypeFromCandidate` for call-return slice gates instead of checking the direct `.slice` kind. |
| 198 | Centralize C dyn/closure filtering in race aggregate classification. | Complete: `raceAggregateKind` now reuses `dynTraitNameFromCandidate` and `closureNodeFromCandidate` for dyn-trait and closure aggregate gates instead of directly checking `.dyn_trait` / `.closure_type` in the race-lowering classifier. |
| 199 | Centralize C nullable payload filtering for race aggregate recursion. | Complete: nullable payload extraction now goes through `nullablePayloadFromCandidate`; `valueOptionalPayloadFromCandidate` and `raceAggregateKind` reuse that helper instead of directly unpacking `.nullable` in the race-lowering classifier. |
| 200 | Reuse C nullable/dyn helpers in nullable representation selection. | Complete: `nullableRepresentationForTargetType` now uses `nullablePayloadFromCandidate` and `dynTraitNameFromCandidate` instead of directly unpacking `.nullable` and checking the child `.dyn_trait` kind. |
| 201 | Centralize C dyn pointer-source filtering. | Complete: `dynPointerSourcePointeeFromCandidate` now reuses `dynTraitNameFromCandidate` for existing-dyn pass-through and `pointerNodeFromCandidate` for pointer-pointee selection instead of directly checking `.dyn_trait` / `.pointer` in the dyn-coercion helper. |
| 202 | Move artifact envelope ownership out of backend seam. | Complete: `ArtifactBundle`, digest helpers, and `.mcmeta`/`.mcmap` writers moved to `artifact_model.zig`; `main`, `lower_c_map`, `artifact_publisher`, and `CompilationSession` consume the artifact model directly, while `backend.zig` only references the digest type needed by `LowerOptions`. |

Default next patch: continue Phase 0/1 compiler authority work unless a narrower kernel-profile regression fails.

## Patch rules

Each refactor patch should change one invariant family.

A patch is complete only if it includes:

- the code change;
- one focused regression, inventory check, or manifest check;
- documentation/risk-register changes only when the claim changes;
- no unrelated kernel/LSP/selfhost/release edits.

Split the patch if it:

- changes more than one semantic family;
- adds a new abstraction while leaving the old authority path untracked;
- updates status prose without changing the owning manifest, inventory, code, or
  tests;
- expands an experimental profile into a production claim.

## Verification ladder

Compiler authority slices use two levels. Run the focused level for every small
mechanical slice; batch the broad truth gates after several adjacent slices or
before handoff/merge.

Focused level:

```text
git diff --check
zig build semantic-facts-inventory-test --summary all
zig test <directly touched backend test file> --test-filter <touched family>
```

Broad truth level:

```text
zig build test-unit --summary all
zig build c-test --summary all
zig build sweep --summary all
zig build diff-backend --summary all
```

Do not delete semantic parity tests just to speed up the inner loop. Move them
to the broad level unless the touched slice changes cross-backend semantics,
MIR fact shape, ABI/layout, or the parity harness itself.

Governance-only slices:

```text
git diff --check
zig build gate-manifest-test --summary all
```

Kernel trust-boundary slices:

```text
git diff --check
zig build test-unit --summary all
zig build <focused-qemu-gate-for-touched-subsystem> --summary all
```

Use the focused tamper/substitution or capability tests for the touched
subsystem before changing risk-register status.

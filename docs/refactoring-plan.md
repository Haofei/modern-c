# Refactoring plan

This is the active code-facing refactoring plan for `modern-c`. It translates
the open items in [`review-risk-register.yaml`](review-risk-register.yaml) into
an ordered execution plan.

The goal is not to add features. The goal is to remove duplicate authority,
make compiler requests isolated, make backend semantics mechanically verifiable,
and keep experimental product surfaces out of production claims.

## Current position

| Area | Status | Decision |
|---|---|---|
| Compiler request state | Closed for the admitted subset | Keep `CompilationSession` as the request boundary and extend it only through tests. |
| Typed MIR identity | In progress | Continue migrating type/value/symbol/span identity from strings and AST side channels into typed MIR tables. Do not expand backend semantics while this is open. |
| Backend semantic authority | Open | Backends must become consumers of verified facts, not secondary semantic analyzers. |
| HIR authority | Open | Either promote HIR to the production semantic boundary or keep it as a generated inspection view. |
| Artifact/source-map provenance | Open | Bind emitted bytes, source maps, options, toolchain identity, and MIR/fact digests together. |
| Build gate governance | Open | Move stringly gate lists into one generated manifest. |
| Product/TCB scope | Open | Keep selfhost, LLVM parity, kernel production, Agent runtime, and vendored runtimes profile-scoped until their blockers close. |
| Kernel secure loading | Open | Production loading must consume exact-byte `VerifiedBundle` capabilities, not raw bytes plus metadata. |

## Planning horizon

Use three horizons instead of one large undifferentiated roadmap:

| Horizon | Target | Must finish | Explicitly out of scope |
|---|---|---|---|
| H1 | Stabilize compiler-core authority | Phases 2-4 | Kernel production, selfhost expansion, new language surface. |
| H2 | Make artifacts and gates auditable | Phases 5-7 | Real hardware qualification except evidence-schema preparation. |
| H3 | Close production kernel trust boundaries | Phases 8-9 | Any production claim before exact-byte load and hardware evidence exist. |

Every slice should be small enough to review as one invariant change. If a slice
needs more than one semantic authority migration, split it.

## Non-negotiable rules

1. Do not expand language, kernel, Agent, selfhost, LSP, or release surface while
   a phase is removing duplicate authority in that area.
2. Keep the C backend as the reference release path until typed MIR/fact
   boundaries are enforced.
3. Keep LLVM useful for differential testing, but do not treat it as equal
   production authority while backend-local inference remains.
4. A refactor closes only when code, tests, inventory/gate checks, and docs agree.
5. When a typed fact lands, delete, quarantine, or register the old inference
   path in the same slice. Do not leave two live authorities.
6. Markdown documents summarize state; [`review-risk-register.yaml`](review-risk-register.yaml)
   is the source of truth for open/closed blocker status.

## Phase 0 — Scope freeze and risk-register discipline

Purpose: stop new product breadth from masking compiler-core work.

Deliverables:

- Keep [`review-risk-register.yaml`](review-risk-register.yaml) as the only
  open/closed blocker ledger.
- Keep [`scope-control-plan.md`](scope-control-plan.md) as the profile policy.
- Keep this file as the only ordered refactoring plan.
- Archive or demote stale remediation/status documents when they duplicate these
  three files.

Closure criteria:

- No markdown file carries independent open-blocker counters that conflict with
  `review-risk-register.yaml`.
- New work declares its blocking profile before it is added to release gates.

Risk links:

- `SCOPE-PRODUCT-SURFACE`
- `GATE-MANIFEST`

## Phase 1 — Request-scoped compiler session

Purpose: make one compiler invocation an explicit object instead of process-global mutable state.

Status: closed for the admitted subset.

Completed baseline:

- `src/main.zig` creates request-scoped `CompilationSession` helpers for compile-like commands.
- File-boundary, module-graph, visibility, IO, parse/check, MIR build, and
  `VerifiedProgram` admission are session-owned instead of file-scope globals.
- `compilation-session-inventory-test` anchors the seam.

Remaining maintenance:

- Any new compile-like command must enter through `CompilationSession`.
- Any new request state must be a session field or an explicit parameter.
- Add reentrancy coverage when a new pipeline stage is introduced.

Risk links:

- `ARCH-COMPILATION-SESSION`
- `LSP-COMPILER-SERVICE`

## Phase 2 — Typed MIR identity

Purpose: stop using strings, AST `TypeExpr`, nullable side fields, or source
spelling as semantic identity in codegen-admitted MIR.

Current baseline:

- MIR already has typed seeds for block, function symbol, value, type, and span
  identity.
- Representation-sensitive instructions and facts mirror typed value/type/span
  IDs.
- Target-type facts mirror typed result types, source spans, and owner symbols
  where an owner exists. Verifier/admission checks reject result/span/owner drift.
- Inventory checks anchor the current typed identity surface.

Next slices, in order:

1. Move optional/result representation facts fully behind typed IDs.
2. Move ABI/layout-sensitive facts behind `TypeId`/layout-table IDs.
3. Remove `unknown` from verified MIR admission; allow it only in builder/debug states.
4. Replace instruction `kind + optional fields` with tagged instruction variants for
   the highest-risk families first: calls, optional tests, representation checks,
   loads/stores, and traps.

Closure criteria:

- Verified MIR contains no string identity for types, values, symbols, optional/result representation, ABI shape, or provenance.
- MIR verifier rejects missing or stale fact-table entries before backend admission.
- C and LLVM no longer reconstruct migrated facts from AST or type spelling.

Risk links:

- `ARCH-TYPED-MIR`
- `ARCH-HIR-AUTHORITY`
- `ARCH-BACKEND-FACTS`

## Phase 3 — Backend authority reduction

Purpose: turn C and LLVM backends into mechanical consumers of verified facts.

Deliverables:

- Replace the production backend boundary with a narrow `VerifiedProgram` that
  exposes typed MIR, symbol table, type table, layout table, ABI table, source
  spelling table, and backend-specific config.
- Remove `ast.Module` and `TypeExpr` from production backend entrypoints.
- Split backend logic into module collection, function lowering, type projection,
  ABI lowering, control flow, runtime checks, source-map emission, and artifact writing.
- Delete backend-local semantic helpers as their corresponding typed facts land.
- Keep backend fallback policies explicit: conservative lowering, source-spanned
  diagnostic, or verifier failure.

First target:

- Create a backend-surface inventory that lists every C/LLVM helper still
  reading AST/type spelling for semantic decisions.
- For each migrated fact family, update the inventory in the same commit that
  deletes or quarantines the old helper.

Closure criteria:

- Production backend code cannot access AST nodes for semantic decisions.
- Every remaining backend semantic helper is registered as a temporary exception
  or eliminated.
- C/LLVM differential gates pass for the admitted subset using the same verified facts.

Risk links:

- `ARCH-BACKEND-FACTS`
- `BACKEND-LLVM-PROFILE`

## Phase 4 — HIR decision

Purpose: remove the current half-authoritative HIR state.

Decision required before broad MIR/backend cleanup:

- Option A: promote HIR to the production boundary:
  `Syntax AST -> Resolved/Typed HIR -> Typed MIR -> Backend`.
- Option B: keep HIR as a generated inspection/debug view derived from semantic data.

Preferred direction:

- Promote only if it reduces backend/MIR access to AST.
- Otherwise keep it non-authoritative and make that explicit in docs and tests.

Closure criteria:

- There is no second semantic path where HIR says one thing and production MIR/codegen consumes another.
- `mcc lower-hir` / `verify-hir` output is documented as either production input or inspection output.
- Backends and MIR builder have one declared upstream semantic source for every
  type/control/effect/layout/provenance fact.

Risk links:

- `ARCH-HIR-AUTHORITY`

## Phase 5 — Artifact and source-map binding

Purpose: make emitted artifacts, source maps, options, and toolchain identity one auditable object.

Deliverables:

- Add an `ArtifactBundle` metadata object containing:
  artifact digest, source-map digest, source digest, MIR/fact digest, compiler
  version/commit, target, backend config, checks mode, and toolchain identity.
- Produce source maps during the same lowering transaction that writes the artifact.
- Make source-map consumers verify artifact digest before use.
- Make `mcc build` use exclusive temp files and atomic final replacement.

Closure criteria:

- `emit-c`, `emit-llvm`, `emit-map`, and `build` share artifact metadata code.
- A source map for artifact A is rejected for artifact B.
- Failed or interrupted build does not corrupt an existing output.

Risk links:

- `ARCH-SOURCE-MAP-DIGEST`

## Phase 6 — Gate manifest consolidation

Purpose: stop maintaining build, CI, release, and documentation gate truth in
several string lists.

Deliverables:

- Create one gate manifest with:
  `id`, owner, category, tier, required tools, blocking profiles, and skip policy.
- Generate Zig build registration, CI pass assertions, release evidence, and doc summaries from the manifest.
- Collapse execution tiers to:
  `pr`, `nightly`, and `release`.
- Keep current anti-vacuity checks until the generated manifest fully replaces hand-written lists.

Closure criteria:

- Adding, renaming, or deleting a blocking gate requires editing exactly one manifest row.
- Deleted or skipped blocking gates fail CI with a clear error.
- Release evidence names the same gate IDs as local builds.
- Documentation does not contain manually maintained gate pass/fail counters.

Risk links:

- `GATE-MANIFEST`

## Phase 7 — Profile and TCB minimization

Purpose: prevent every experimental subsystem from becoming part of one implied production TCB.

Deliverables:

- Define profile manifests for:
  `compiler-subset`, `llvm-experimental`, `selfhost-experimental`,
  `kernel-qemu`, `production-kernel`, and `developer-tools`.
- For each profile, list in-scope source directories, gates, toolchain components,
  vendored dependencies, and release blockers.
- Give BearSSL, QuickJS, WAMR, openlibm, firmware, and trust anchors explicit
  component metadata: upstream, revision, patch set, license, PURL/CPE where
  available, advisory status, owner, and review date.

Closure criteria:

- A compiler-only release does not include QuickJS/WAMR/production kernel claims by accident.
- High/Critical advisories are release-blocking or explicitly waived for affected profiles.
- Release notes state which profiles are qualified and which are experimental.

Risk links:

- `SCOPE-PRODUCT-SURFACE`
- `SELFHOST-PROFILE`
- `SUPPLY-TCB-CVE-INTAKE`
- `TCB-PROFILE-MINIMIZATION`

## Phase 8 — Kernel trust-boundary closure

Purpose: move secure boot and Agent loading from component demos to one typed trust chain.

Deliverables:

- Introduce an opaque exact-byte `VerifiedBundle` created only by crypto and policy verification.
- Make production ELF/Agent loading consume `VerifiedBundle`, not raw bytes plus a verified flag.
- Bind loaded image identity to bundle digest, payload digest, signer/key ID,
  version, policy version, rollback state, and runtime audit event.
- Make privileged capability/right mint require an unforgeable root token or module-private constructor.
- Wire policy/audit persistence through the production storage path.

Closure criteria:

- Public production APIs cannot express “verify A, load B”.
- Production loader has no raw-byte admission path.
- Unauthorized modules cannot mint privileged capabilities.
- Tampered, unsigned, rollback, wrong-key, wrong-platform, and replaced-buffer bundles are rejected before load.

Risk links:

- `KERNEL-VERIFIED-BUNDLE`
- `KERNEL-CAPABILITY-MINT`

## Phase 9 — Real-board production qualification

Purpose: separate QEMU surrogate evidence from hardware production evidence.

Deliverables:

- Boot the selected VisionFive 2 profile on real hardware in the intended privilege mode.
- Validate timer, external interrupts, UART, storage, network, watchdog, Agent runtime, reboot reason, and rollback behavior.
- Run storage-full, crash, power-loss, rollback, and long-soak tests.
- Record firmware, DTB, toolchain, artifact digest, board identity, and duration in qualification evidence.

Closure criteria:

- `production-kernel` profile has hardware evidence, not only QEMU evidence.
- Hardware failures are tracked separately from QEMU surrogate failures.
- Production checklist has no unchecked item for the claimed hardware profile.

Risk links:

- `HARDWARE-PRODUCTION-QUALIFICATION`

## Execution order

Do the phases in this order unless a release profile explicitly narrows the scope:

1. Phase 0: scope/risk-register discipline.
2. Phase 1: `CompilationSession` maintenance only.
3. Phase 2: typed MIR identity.
4. Phase 3: backend authority reduction.
5. Phase 4: HIR authority decision.
6. Phase 5: artifact/source-map binding.
7. Phase 6: generated gate manifest.
8. Phase 7: profile and TCB minimization.
9. Phase 8: kernel trust-boundary closure.
10. Phase 9: real-board qualification.

Phases 7-9 can be prepared in parallel only as profile-manifest work. They
should not consume compiler-core implementation time until Phases 2-4 are closed
or a release profile explicitly requires them.

## Slice rules

Each implementation slice must:

- change one invariant family only;
- include a focused regression test that fails without the code change;
- update the relevant inventory script when an architectural seam is introduced;
- update this plan or [`review-risk-register.yaml`](review-risk-register.yaml)
  only when status or closure criteria materially change;
- leave the worktree in a state where at least the focused gate and inventory
  gate pass.

Do not close a phase because a document says the direction is implemented.
Close it only when production code can no longer express the bad state.

## Near-term implementation backlog

Use this backlog for the next engineering slices:

1. Move optional/result representation lowering to typed fact consumers only.
2. Add a backend-surface inventory row for every remaining C/LLVM semantic helper.
3. Remove or quarantine the first migrated backend-local inference helper.
4. Add artifact digest metadata to source-map output.
5. Introduce the first generated gate manifest for a small subset of existing gates.
6. Decide HIR authority explicitly and update `mcc lower-hir` / `verify-hir`
   documentation to match the decision.

Each slice should end with:

- a focused regression test;
- the relevant inventory check;
- `zig build test-unit` or a narrower equivalent when appropriate;
- docs/risk-register update if blocker status changes.

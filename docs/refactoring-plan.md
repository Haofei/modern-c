# Refactoring execution plan

This is the active code-facing refactoring plan for `modern-c`.

It converts the open items in [`review-risk-register.yaml`](review-risk-register.yaml)
into implementation phases. Do not create separate remediation plans for the
same work. Markdown status pages may summarize this file, but the source of
truth for open/closed blocker state remains the risk register.

## Goal

Reduce duplicate authority before expanding the product surface.

The near-term target is a compiler core where one request is isolated, one
semantic model owns type/control/layout/provenance facts, verified MIR is the
backend admission boundary, and emitted artifacts carry auditable provenance.

This plan is not a feature roadmap. New language, kernel, Agent, selfhost, LSP,
or release features should be deferred unless they directly close a listed
phase or are explicitly scoped to an experimental profile.

## Current position

| Area | Status | Required direction |
|---|---|---|
| Compiler request state | Closed for the admitted subset | Keep all compile-like commands on `CompilationSession`; add reentrancy tests when new state is introduced. |
| Typed MIR identity | In progress | Continue moving type/value/symbol/span/representation identity out of strings, AST side channels, and backend-local maps. |
| Backend authority | In progress | Treat C/LLVM as consumers of verified facts; delete or register every remaining semantic inference helper. |
| HIR authority | Open decision | Either promote HIR into the production path or document/test it as inspection-only. |
| Artifact/source-map provenance | Partially remediated | Bind artifact bytes, source maps, options, toolchain identity, and MIR/fact digests in one metadata object. |
| Gate governance | Open | Replace hand-maintained gate string lists with one manifest. |
| Product/TCB scope | Open | Keep selfhost, production kernel, Agent runtime, and vendored runtimes profile-scoped. |
| Kernel secure loading | Open | Production loaders must accept opaque exact-byte `VerifiedBundle` capabilities, not raw bytes plus metadata. |

## Non-negotiable rules

1. One slice changes one invariant family.
2. A slice is not closed by documentation alone; code, tests, inventory checks,
   and docs must agree.
3. When a typed fact lands, the old inference path must be deleted, quarantined,
   or registered in the same change.
4. Backends may use syntax spelling for emission mechanics, but not as semantic
   authority.
5. `review-risk-register.yaml` is the only open/closed blocker ledger.
6. Experimental profiles must not silently become production claims.

## Phase 0 — Documentation and scope control

Purpose: keep the project from using multiple documents as competing status
ledgers.

Deliverables:

- Keep [`review-risk-register.yaml`](review-risk-register.yaml) as the only
  blocker ledger.
- Keep [`scope-control-plan.md`](scope-control-plan.md) as the profile policy.
- Keep this file as the only ordered refactoring plan.
- Archive stale remediation/status documents when they duplicate these three
  files.
- Remove manually maintained “open blocker count” claims from Markdown unless
  generated from the risk register.

Closure criteria:

- `docs/README.md` points readers to the canonical status documents.
- No active Markdown page contradicts the risk register for High/Critical work.
- New release-blocking work declares its profile before it is wired into gates.

Risk links: `SCOPE-PRODUCT-SURFACE`, `GATE-MANIFEST`

## Phase 1 — Request-scoped compiler session

Purpose: make compiler invocations reentrant and testable.

Status: closed for the admitted subset.

Completed baseline:

- Compile-like CLI commands construct request-scoped `CompilationSession`
  helpers.
- File-boundary, module-graph, visibility, IO, parse/check, MIR build, and
  `VerifiedProgram` admission are session-owned rather than file-scope globals.
- `compilation-session-inventory-test` anchors the seam.

Remaining maintenance:

- New compile-like commands must enter through `CompilationSession`.
- New request state must be a session field or explicit parameter.
- Add parallel/reentrancy coverage when session state expands.

Risk links: `ARCH-COMPILATION-SESSION`, `LSP-COMPILER-SERVICE`

## Phase 2 — Typed MIR identity

Purpose: stop representing semantic identity with strings, optional side fields,
or AST `TypeExpr` in codegen-admitted MIR.

Current baseline:

- MIR already has typed seeds for block, function symbol, value, type, and span
  identity.
- Representation and target-type facts mirror typed result/value/span/owner IDs.
- Verifier/admission checks reject result/span/owner drift.
- Inventory checks anchor the migrated surface.

Implementation order:

1. Move optional/result representation lowering fully behind typed IDs.
2. Move ABI/layout-sensitive facts behind `TypeId` and layout-table IDs.
3. Remove `unknown` from verified MIR admission; allow it only in builder/debug
   states.
4. Convert high-risk instruction families from `kind + optional fields` into
   tagged variants: calls, optional tests, representation checks, loads/stores,
   and traps.

Closure criteria:

- Verified MIR contains no string identity for types, values, symbols,
  optional/result representation, ABI shape, or provenance.
- MIR verifier rejects missing/stale fact-table entries before backend admission.
- C and LLVM do not reconstruct migrated facts from AST or type spelling.

Risk links: `ARCH-TYPED-MIR`, `ARCH-HIR-AUTHORITY`, `ARCH-BACKEND-FACTS`

## Phase 3 — Backend authority reduction

Purpose: make C and LLVM lowering mechanical consumers of verified facts.

Current baseline:

- `semantic-facts-inventory-test` owns the finite backend AST-inference budget
  and backend source-surface classification.
- New backend modules must be classified as a registered semantic family,
  MIR/fact consumer, or mechanics-only code.

Deliverables:

- Narrow `VerifiedProgram` so production backend entrypoints expose typed MIR,
  symbol table, type table, layout table, ABI table, source spelling table, and
  backend config.
- Remove `ast.Module` and `TypeExpr` from production backend semantic decisions.
- Split backend code by responsibility: module collection, function lowering,
  type projection, ABI lowering, control flow, runtime checks, source-map
  emission, and artifact writing.
- Delete backend-local helpers as their corresponding typed facts land.
- Keep fallback policy explicit: verifier failure, source-spanned diagnostic, or
  conservative lowering.

Closure criteria:

- Production backend code cannot access AST nodes for semantic decisions.
- Every remaining semantic helper is either registered as a temporary exception
  or eliminated.
- C/LLVM differential gates pass for the admitted subset using the same verified
  facts.

Risk links: `ARCH-BACKEND-FACTS`, `BACKEND-LLVM-PROFILE`

## Phase 4 — HIR authority decision

Purpose: remove the current half-authoritative HIR state.

Decision:

- Option A: promote HIR into the production path:
  `Syntax AST -> Resolved/Typed HIR -> Typed MIR -> Backend`.
- Option B: keep HIR as a generated inspection/debug view derived from semantic
  data.

Preferred rule:

- Promote HIR only if it reduces MIR/backend access to AST.
- Otherwise keep it inspection-only and test/document that explicitly.

Closure criteria:

- There is no second semantic path where HIR says one thing and production
  MIR/codegen consumes another.
- `mcc lower-hir` and `verify-hir` are documented as either production-boundary
  commands or inspection commands.
- Backends and MIR builder have one declared upstream semantic source for every
  type/control/effect/layout/provenance fact.

Risk link: `ARCH-HIR-AUTHORITY`

## Phase 5 — Artifact and source-map binding

Purpose: make emitted artifacts, source maps, options, and toolchain identity one
auditable object.

Deliverables:

- Add an `ArtifactBundle` metadata object containing artifact digest,
  source-map digest, source digest, MIR/fact digest, compiler version/commit,
  target, backend config, checks mode, and toolchain identity.
- Produce source maps in the same lowering transaction that writes the artifact.
- Make source-map consumers verify artifact digest before use.
- Make `mcc build` use exclusive temp files and atomic final replacement.

Current baseline:

- `emit-map` consumes the same generated C bytes used for the map and records
  their SHA-256 digest in the map header.
- `emit-map` also records the exact source SHA-256 supplied by the request layer
  and the lowering profile/check/stub options used to produce the artifact.
- `emit-map` records a SHA-256 digest over the MIR metadata and fact tables it
  consumes for source-map correlation.
- Full toolchain/source-map digest binding remains open until `ArtifactBundle`
  exists.

Closure criteria:

- `emit-c`, `emit-llvm`, `emit-map`, and `build` share artifact metadata code.
- A source map for artifact A is rejected for artifact B.
- Failed or interrupted builds do not corrupt existing outputs.

Risk link: `ARCH-SOURCE-MAP-DIGEST`

## Phase 6 — Gate manifest consolidation

Purpose: stop maintaining build, CI, release, and documentation gate truth in
several string lists.

Deliverables:

- Create one gate manifest with `id`, owner, category, tier, required tools,
  blocking profiles, and skip policy.
- Generate Zig build registration, CI pass assertions, release evidence, and doc
  summaries from the manifest.
- Collapse execution tiers to `pr`, `nightly`, and `release`.
- Keep anti-vacuity checks until the manifest fully replaces hand-written lists.

Closure criteria:

- Adding, renaming, or deleting a blocking gate requires editing exactly one
  manifest row.
- Deleted or skipped blocking gates fail CI with a clear error.
- Release evidence names the same gate IDs as local builds.
- Documentation has no manually maintained gate pass/fail counters.

Risk link: `GATE-MANIFEST`

## Phase 7 — Profile and TCB minimization

Purpose: prevent experimental subsystems from becoming part of one implied
production TCB.

Deliverables:

- Define profile manifests for `compiler-subset`, `llvm-experimental`,
  `selfhost-experimental`, `kernel-qemu`, `production-kernel`, and
  `developer-tools`.
- For each profile, list source directories, gates, toolchain components,
  vendored dependencies, and release blockers.
- Give BearSSL, QuickJS, WAMR, openlibm, firmware, and trust anchors explicit
  component metadata: upstream, revision, patch set, license, PURL/CPE where
  available, advisory status, owner, and review date.

Closure criteria:

- A compiler-only release does not include QuickJS/WAMR/production kernel claims
  by accident.
- High/Critical advisories are release-blocking or explicitly waived for affected
  profiles.
- Release notes state which profiles are qualified and which are experimental.

Risk links: `SCOPE-PRODUCT-SURFACE`, `SELFHOST-PROFILE`,
`SUPPLY-TCB-CVE-INTAKE`, `TCB-PROFILE-MINIMIZATION`

## Phase 8 — Kernel trust-boundary closure

Purpose: move secure boot and Agent loading from component demos to one typed
trust chain.

Deliverables:

- Introduce an opaque exact-byte `VerifiedBundle` created only by crypto and
  policy verification.
- Make production ELF/Agent loading consume `VerifiedBundle`, not raw bytes plus
  a verified flag.
- Bind loaded image identity to bundle digest, payload digest, signer/key ID,
  version, policy version, rollback state, and runtime audit event.
- Make privileged capability/right mint require an unforgeable root token or a
  module-private constructor.
- Wire policy/audit persistence through the production storage path.

Closure criteria:

- Public production APIs cannot express “verify A, load B”.
- Production loader has no raw-byte admission path.
- Unauthorized modules cannot mint privileged capabilities.
- Tampered, unsigned, rollback, wrong-key, wrong-platform, and replaced-buffer
  bundles are rejected before load.

Risk links: `KERNEL-VERIFIED-BUNDLE`, `KERNEL-CAPABILITY-MINT`

## Phase 9 — Real-board production qualification

Purpose: separate QEMU surrogate evidence from hardware production evidence.

Deliverables:

- Boot the selected VisionFive 2 profile on real hardware in the intended
  privilege mode.
- Validate timer, external interrupts, UART, storage, network, watchdog, Agent
  runtime, reboot reason, and rollback behavior.
- Run storage-full, crash, power-loss, rollback, and long-soak tests.
- Record firmware, DTB, toolchain, artifact digest, board identity, and duration
  in qualification evidence.

Closure criteria:

- `production-kernel` profile has hardware evidence, not only QEMU evidence.
- Hardware failures are tracked separately from QEMU surrogate failures.
- Production checklist has no unchecked item for the claimed hardware profile.

Risk link: `HARDWARE-PRODUCTION-QUALIFICATION`

## Execution order

Run the work in this order unless a release profile explicitly narrows the
scope:

1. Phase 0: scope and risk-register discipline.
2. Phase 1: `CompilationSession` maintenance only.
3. Phase 2: typed MIR identity.
4. Phase 3: backend authority reduction.
5. Phase 4: HIR authority decision.
6. Phase 5: artifact/source-map binding.
7. Phase 6: generated gate manifest.
8. Phase 7: profile and TCB minimization.
9. Phase 8: kernel trust-boundary closure.
10. Phase 9: real-board qualification.

Phases 7-9 can be prepared in parallel only as manifest/evidence work. They
should not consume compiler-core implementation time until Phases 2-4 are closed
or a release profile explicitly requires them.

## First implementation slices

Use this backlog for the next bounded patches:

1. Retire one remaining optional/result backend inference path by routing it
   through existing typed representation or target-type facts.
2. Update the T3/T4 backend authority inventory in the same patch that retires
   the helper.
3. Add an artifact metadata header to source-map output and verify artifact
   digest mismatch rejection.
4. Introduce a generated gate manifest for a small existing subset before moving
   the whole build inventory.
5. Decide HIR authority and update `lower-hir` / `verify-hir` docs and tests.
6. Add a profile manifest skeleton for `compiler-subset` and
   `llvm-experimental`.
7. Prototype exact-byte `VerifiedBundle` admission as a new API while keeping raw
   loader APIs quarantined to tests/demos.

Each slice should end with:

- a focused regression test;
- the relevant inventory check;
- `zig build test-unit` or a narrower equivalent where appropriate;
- docs/risk-register update only if blocker status changes.

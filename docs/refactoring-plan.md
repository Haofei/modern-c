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
| HIR authority | Closed as inspection-only | Keep `lower-hir` / `verify-hir` as inspection commands; MIR verification remains the backend production boundary. |
| Artifact/source-map provenance | Partially remediated | Bind artifact bytes, source maps, options, toolchain identity, and MIR/fact digests in one metadata object. |
| Gate governance | Pilot manifest | Expand `gate-manifest.json` from the compiler-core pilot to generated build/CI/doc rows. |
| Product/TCB scope | In progress | Keep selfhost, production kernel, Agent runtime, and vendored runtimes profile-scoped through `profile-manifest.json`. |
| Kernel secure loading | Open | Production loaders must accept opaque exact-byte `VerifiedBundle` capabilities, not raw bytes plus metadata. |

## Milestone cut lines

Use these milestones to decide what belongs in the active refactor branch. A
change that does not advance the current milestone should stay out unless it is
a small bug fix or a profile-specific gate repair.

| Milestone | Target | Accept | Defer |
|---|---|---|---|
| M1 — semantic core | Typed MIR and backend authority stop expanding. | Retire backend-local inference helpers, move facts behind typed IDs, make malformed MIR states rejected earlier. | New syntax, new runtime surface, selfhost expansion, advanced LSP features. |
| M2 — artifact identity | Every emitted artifact has the same provenance strength. | Shared artifact metadata for `emit-c`, `emit-llvm`, `emit-map`, and `build`; source-map/artifact digest verification. | Release polish that does not consume the shared metadata object. |
| M3 — governance single-source | Gate/profile/release claims are generated or checked from manifests. | Expand `gate-manifest.json`, add TCB component metadata, remove manual counters from active docs. | New status/remediation Markdown pages. |
| M4 — kernel trust chain | Production-shaped loading cannot express verify-A/load-B. | Exact-byte `VerifiedBundle` prototype, privileged capability mint isolation, substitution tests. | Real production-kernel claims before M4 has typed APIs and tests. |

Only M1 is allowed to take broad compiler-core implementation time by default.
M2 and M3 may proceed when they touch already-modified files or unblock evidence
generation. M4 starts as a prototype until the compiler core stops moving.

## 2026-07 execution policy

The refactor is intentionally narrow: stabilize the compiler core before adding
more product surface.

Default priority:

1. compiler semantic authority;
2. backend admission and artifact provenance;
3. gate/profile generation;
4. kernel and Agent production trust boundaries.

Work that does not close one of those priorities should be treated as
experimental profile work, not release-blocking core work. In particular, avoid
expanding selfhost coverage, advanced LSP features, production kernel claims,
runtime vendoring, or new backend surface while Phases 2-4 remain open.

This policy does not remove existing gates. It prevents new implementation
complexity from becoming mandatory before the semantic boundary is stable.

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
7. A refactor slice must delete, quarantine, or inventory at least one old path;
   adding a new abstraction while leaving the old authority path untracked does
   not count as progress.
8. New docs are allowed only when they become canonical source material. Status
   updates, remediation reports, and one-off review conclusions go under
   `docs/archive/` or are folded into this file and the risk register.

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
- C and LLVM nullable `switch` / `if let` subject lowering now consumes the
  MIR-owned subject representation from `.switch_subject` / `.if_let_subject`
  facts; stale pointer-vs-value optional representation facts are rejected
  before emission.
- C and LLVM backend entrypoints now share `mir.validateLoweringAdmission()`;
  call-target, target-type, representation, integer, range, function-return,
  terminator, and all runtime/fact-bearing instruction type positions reject
  the `.unknown` type placeholder before lowering. Diagnostic-only check
  instructions remain the explicit `.unknown` allowlist.
- Scalar/domain conversion call-target result types are MIR-owned, including
  `try_from` as `Result<T, ConversionError>`, rather than falling back through
  generic call inference.
- Assignment, target-typed constructor, and qualified tagged-union constructor
  call instructions carry their resolved MIR-owned lowering type instead of a
  debug-only `.unknown` placeholder.
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
- `VerifiedProgram` exposes a MIR-backed `SourceSpellingView` for symbol
  spelling. Legacy `syntax_module` remains only because declaration metadata has
  not yet been fully normalized. C and LLVM runtime hook suppression now consume
  the shared `SourceSpellingView.definesFunctionSpelling` query; duplicate
  backend-local `moduleDefinesHook` helpers are exact-zero gated. Function-level
  spelling lookup is no longer part of the backend-facing public view; external
  backend consumers get symbol spelling by typed `SymbolId` or the narrow
  runtime-hook predicate. The remaining legacy `program.syntax_module` ingress
  points in C/LLVM backend entry shims are exact-count gated so AST access cannot
  expand while typed MIR normalization is still in progress.

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

- Option B is selected for the current architecture: HIR stays an inspection and
  verification projection, not the production input to MIR or backend lowering.

Completed baseline:

- `README.md` documents HIR as inspection-only.
- `mcc --help` states that HIR commands are inspection-only and MIR
  verification remains the backend production boundary.
- `lower-hir` and `verify-hir` outputs begin with an inspection-only contract
  header.
- `hir_tests.zig` and `mcc-cli-test` anchor the contract.

Re-entry rule:

- Promote HIR only if it reduces MIR/backend access to AST. Until then, it must
  remain a generated inspection/debug view and must not be cited as codegen
  admission evidence.

Closure criteria:

- There is no production claim that treats HIR as codegen admission.
- `mcc lower-hir` and `verify-hir` are documented and tested as inspection
  commands.
- Backends and MIR builder continue to name MIR/facts, not HIR, as the upstream
  semantic source for type/control/effect/layout/provenance facts.

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

- `emit-map` builds an `ArtifactBundle` header for the generated source-map
  payload.
- `ArtifactBundle` and the bundle-header writer now live at the backend seam in
  `src/backend.zig`; `lower_c_map` consumes the shared object instead of owning
  a private source-map-only metadata contract.
- The bundle records the SHA-256 digest of the same generated C bytes used for
  the map.
- `emit-map` also records the exact source SHA-256 supplied by the request layer
  and the lowering profile/check/stub options used to produce the artifact.
- `emit-map` records a SHA-256 digest over the MIR metadata and fact tables it
  consumes for source-map correlation.
- The bundle records the SHA-256 digest of the source-map payload (`# columns`
  plus `entry` rows), so consumers can detect map-body substitution.
- `tools/toolchain/mcmap-verify.py` verifies map-payload and generated-artifact
  digests, and `mcmap-test` proves tampered map bodies and wrong artifacts are
  rejected.
- `mcc build` writes the generated hosted C through an exclusive sibling
  temporary file, reserves the linked executable path with exclusive create,
  links to that temporary executable, and commits the final output with an
  atomic rename.
- `emit-c`, `emit-llvm`, and `build` now write sibling `.mcmeta` sidecars for
  `-o` outputs using the same `ArtifactBundle` header code as `emit-map`.
- `build` computes the metadata digest from the linked executable bytes and
  records the clang identity, resolved executable path, and executable SHA-256
  digest used for that link step when the tool can be resolved from `PATH` or an
  explicit path.
- Release packaging now emits `.tar.gz.mcmeta` sidecars for release tarballs and
  records them in `SHA256SUMS`, release inventory, CycloneDX SBOM, workflow
  upload/publish paths, and release-process documentation.
- Release tarball sidecars record the Zig toolchain version, resolved path, and
  executable SHA-256 digest used by the packaging helper.
- Producing source maps in the same artifact-writing transaction, recording
  complete toolchain identities for every remaining downstream tool invocation,
  and replacing all release evidence prose with generated manifest rows remain
  open.

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

Current baseline:

- `docs/gate-manifest.json` defines a pilot set of compiler-core gates with
  owner, category, execution tier, required tools, blocking profiles, build
  tiers, and skip policy.
- `gate-manifest-test` validates those gate IDs are registered in `build/*.zig`,
  reference known profiles, and appear in each declared `m0` / `fast` / `c0`
  dependency list.
- `fast`, `m0`, and `c0` run the pilot manifest gate; focused dev-gates route
  manifest edits to that gate.
- Full build registration, CI pass assertions, release evidence, and docs are
  still hand-maintained outside the pilot.

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

Current baseline:

- `docs/profile-manifest.json` defines the six product profiles and ties each
  one to blocking risks, registered gates, and TCB components.
- `profile-manifest-test` validates the manifest against
  `review-risk-register.yaml`, the registered Zig build gates, and
  `docs/tcb-components.json`.
- `docs/tcb-components.json` defines the profile-facing TCB component IDs,
  owners, categories, advisory status, review dates, and vendored provenance
  pointers. `vendoring-test` validates that every license-bearing vendored
  dependency has matching component metadata.
- `fast`, `m0`, and `c0` run the profile manifest gate; focused dev-gates route
  profile/risk/scope edits to that gate.
- Full per-component advisory metadata for every vendored TCB remains open
  under `SUPPLY-TCB-CVE-INTAKE`; automated advisory intake and waiver policy
  remain open before any production TCB claim.

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

## Implementation queue

This is the current bounded patch queue. Keep each row independently
reviewable; do not merge rows merely because the files overlap.

| Order | Slice | Primary files | Required proof | Retires or prevents |
|---:|---|---|---|---|
| 1 | Move one ABI/layout-sensitive lowering decision behind `TypeId` / layout-table facts. | `src/layout.zig`, `src/mir_type.zig`, `src/mir.zig`, backend type/lower files | C/LLVM ABI/layout fixture plus `mir-identity-inventory-test` and `semantic-facts-inventory-test`. | Backend recomputing layout or ABI shape from type spelling. |
| 2 | Convert the first MIR instruction family to tagged-union shape. Start with calls or optional tests. | `src/mir_model.zig`, `src/mir.zig`, verifier, both backends | Malformed-field combinations become unrepresentable or rejected; `test-unit`. | `kind + optional fields` illegal states for that family. |
| 3 | Remove or quarantine the next backend-local semantic helper from the semantic-facts inventory. | `tools/toolchain/semantic-facts-inventory.py`, `src/lower_c_*`, `src/lower_llvm_*` | Inventory count decreases or the helper moves to a named temporary exception with focused parity tests. | Silent expansion of backend-local semantic authority. |
| 4 | Expand `gate-manifest.json` from the pilot compiler-core subset to generated build/CI/doc rows. | `docs/gate-manifest.json`, `build/`, `tools/ci/`, `tools/toolchain/` | Generated projection matches hand-written rows before replacement; `gate-manifest-test`, `ci-pass-gates-test`, `parallel-runner-test`. | Stringly gate drift beyond the pilot subset. |
| 5 | Add per-vendored TCB component metadata and advisory status to the profile/TCB manifest surface. | `docs/profile-manifest.json`, `docs/vendoring.md`, `third_party/*/README.vendored.md`, `tools/toolchain/vendoring-test.py` | Vendoring/profile gates prove every profile TCB component has owner, upstream, revision, license, and advisory status. | Runtime TCBs becoming implicit in unrelated production profiles. |
| 6 | Share artifact metadata across `emit-c`, `emit-llvm`, `emit-map`, and `build`. | `src/main.zig`, `src/backend.zig`, `src/lower_c_map.zig`, `tools/toolchain/mcmap-verify.py` | `mcmap-test`, `path-remap-test`, `mcc-build-test`, and a metadata digest smoke. | Source maps or build outputs carrying weaker provenance than emit-map. |
| 7 | Prototype exact-byte `VerifiedBundle` admission as a new production-shaped API. | `kernel/core/production_ops.mc`, `kernel/core/elf_loader.mc`, `kernel/crypto/` | Tamper/substitution tests prove raw bytes cannot reach the production loader path. | “verify A, load B” API shape. |

Every slice must end with:

- a focused regression test;
- the relevant inventory check when one exists;
- `zig build test-unit` or a documented narrower equivalent;
- docs/risk-register update only if blocker status changes;
- no new duplicate status document.

## Explicit deferrals

These areas stay useful, but they should not consume core refactor capacity until
their owning profile becomes the active release target:

| Area | Current treatment | Re-entry condition |
|---|---|---|
| LLVM as equal production backend | Experimental/differential backend while typed MIR is still open. | Phases 2-3 close for the relevant semantic families. |
| Selfhost | Bootstrap experiment, not a second language authority. | Main compiler typed MIR/backend seam is stable enough to define a selfhost subset manifest. |
| Advanced LSP features | Keep existing features working; avoid expanding workspace intelligence. | Persistent `CompilationSession`/query service exists. |
| Production kernel / Agent runtime | Profile-scoped; QEMU evidence is surrogate. | `VerifiedBundle`, capability mint, persistence, and real-board gates are active profile blockers. |
| New vendored runtimes | Do not enter default production TCB. | Profile manifest names the runtime, CVE owner, gates, and release blocker policy. |

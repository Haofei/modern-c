# Refactoring plan

This plan translates the open risks in
[`review-risk-register.yaml`](review-risk-register.yaml) into code-facing
refactoring work. It is intentionally narrower than the product roadmap in
[`todo.md`](todo.md): the goal is to reduce duplicate authority and make later
feature work cheaper, not to add new surface area.

## Ground rules

1. Do not expand language, kernel, Agent, selfhost, or LSP scope while a phase is
   removing duplicate semantic authority in that area.
2. Keep the C backend as the reference release path until typed MIR/fact
   boundaries are enforced.
3. Treat LLVM, selfhost, secure boot, and advanced LSP as profile-scoped work
   until their blockers in `review-risk-register.yaml` close.
4. Every phase must end with a mechanical check, fixture, or gate. A design note
   alone does not close a refactor.
5. When a typed fact is introduced, delete or quarantine the old backend-local
   inference path in the same slice. Do not leave two live authorities.

## Phase 0: freeze and measure the current seams

Purpose: make the current implicit seams visible before moving code.

Work:

- Add a small inventory for each backend semantic decision:
  optional/result representation, ABI shape, pointer provenance, layout,
  ownership/move effect, runtime check choice, and source span mapping.
- Mark each decision as one of:
  `typed-fact-consumer`, `verified-mir-consumer`, `diagnostic-fallback`,
  `backend-local-inference`, or `mechanics-only`.
- Add a check that no new `backend-local-inference` row is introduced without an
  explicit entry in the inventory.
- Keep the existing `m0` and differential gates green.

Acceptance:

- Inventory exists in a machine-readable or generated form.
- Every C/LLVM semantic helper is mapped to an inventory row.
- New semantic backend helper additions fail review or CI unless registered.

Risk register links:

- `ARCH-BACKEND-FACTS`
- `ARCH-TYPED-MIR`
- `BACKEND-LLVM-PROFILE`

## Phase 1: introduce `CompilationSession`

Purpose: make one compiler request a real object instead of process-global state.

Work:

- Add `CompilationSession` with allocator, IO handles, source manager,
  module graph, visibility mode, target/config, diagnostics, budgets, and
  artifact sink.
- Move `combined_boundaries`, `combined_module_graph`, `active_visibility_mode`,
  and stdout state behind the session.
- Convert `check`, `lower-mir`, `verify`, `emit-c`, `emit-llvm`, `emit-map`, and
  `build` to call the same session pipeline.
- Keep CLI behavior byte-compatible except for error messages that become more
  specific.
- Add a parallel reentrancy test that compiles two different roots with different
  visibility/module graph state in the same process.

Acceptance:

- No compiler phase reads mutable request state from `src/main.zig` globals.
- CLI commands share one pipeline entry for parse/name/transform/sema/MIR/verify.
- Reentrancy test passes under both serial and parallel test runners.

Risk register links:

- `ARCH-COMPILATION-SESSION`
- `LSP-COMPILER-SERVICE`

## Phase 2: make typed MIR identity explicit

Purpose: stop treating type/value/symbol spelling as semantic identity.

Work:

- Introduce stable `SourceId`, `NodeId`, `SymbolId`, `TypeId`, `ValueId`, and
  `BlockId` tables.
- Migrate MIR instructions toward tagged unions with correlated fields enforced
  by the type shape instead of optional side fields.
- Remove `unknown` from verified MIR. Unknown facts may exist in builder/debug
  states, not in codegen-admitted MIR.
- Move optional/result representation, ABI type, layout, pointer provenance, and
  effect facts into typed tables consumed by MIR and backends.
- Keep string spelling only for diagnostics, debug dumps, and output symbol
  spelling.

Acceptance:

- Verified MIR contains no string identity for types, values, symbols, or
  optional/result representation.
- MIR verifier rejects missing fact table entries before codegen.
- At least optional/result and ABI-shape lowering no longer call backend-local
  classification helpers.

Risk register links:

- `ARCH-TYPED-MIR`
- `ARCH-BACKEND-FACTS`
- `ARCH-HIR-AUTHORITY`

## Phase 3: shrink backend authority

Purpose: turn C and LLVM backends into consumers of verified facts.

Work:

- Change the backend interface so production lowering receives:
  verified MIR, symbol table, type table, layout table, ABI table, source map
  builder, and backend-specific config.
- Remove `ast.Module` from the production `VerifiedProgram` boundary. If source
  spelling is still needed, pass a narrow `SourceSpelling`/`NameTable` view.
- Delete or fail-close backend inference paths as each typed fact lands.
- Split large emitters by responsibility:
  module collection, function lowering, type projection, ABI lowering,
  expression/statement lowering, runtime checks, and artifact writing.
- Keep LLVM in differential/experimental profile until the same fact inventory is
  enforced for it.

Acceptance:

- Production backend entrypoints cannot access AST nodes or `TypeExpr`.
- Missing required semantic facts produce a source-spanned diagnostic or verifier
  failure, not backend reconstruction.
- C/LLVM differential gates still pass for the admitted subset.

Risk register links:

- `ARCH-BACKEND-FACTS`
- `BACKEND-LLVM-PROFILE`

## Phase 4: bind artifacts and source maps

Purpose: make emitted bytes, maps, options, and toolchain identity auditable as
one object.

Work:

- Add an `ArtifactBundle` or equivalent metadata object containing:
  artifact digest, source map digest, source digest, MIR/fact digest, compiler
  version/commit, target, backend config, checks mode, and toolchain identity.
- Produce source maps during the same lowering pass that writes the artifact.
- Make map consumers verify the artifact digest before using the map.
- Make `mcc build` use the same atomic artifact transaction shape as `emit-*`.

Acceptance:

- `emit-c`, `emit-llvm`, `emit-map`, and `build` share artifact metadata code.
- A source map for one artifact is rejected for a different artifact digest.
- Failed `build` cannot corrupt an existing output.

Risk register links:

- `ARCH-SOURCE-MAP-DIGEST`

## Phase 5: consolidate gate and evidence plumbing

Purpose: stop maintaining the build/test/release truth in several string lists.

Work:

- Create one gate manifest with `id`, owner, category, tier, required tools,
  blocking profiles, and skip policy.
- Generate Zig build registrations, CI pass assertions, release evidence, and
  documentation summaries from that manifest.
- Collapse execution tiers to `pr`, `nightly`, and `release`.
- Keep existing anti-vacuity checks until generated manifests fully replace
  hand-written lists.

Acceptance:

- Adding or renaming a gate requires editing one manifest row.
- `m0`, `fast`, CI, and release evidence consume generated gate data.
- Deleted or skipped blocking gates fail CI with a clear error.

Risk register links:

- `GATE-MANIFEST`

## Phase 6: split product profiles and TCBs

Purpose: prevent every experimental subsystem from becoming part of one implied
production claim.

Work:

- Define minimal TCB manifests for `compiler-subset`, `llvm-experimental`,
  `selfhost-experimental`, `kernel-qemu`, `production-kernel`, and
  `developer-tools`.
- Move profile-specific vendored dependencies into explicit manifests:
  BearSSL, QuickJS, WAMR, openlibm, firmware, and trust anchors.
- Add advisory/CVE intake status and waiver fields to each vendored component.
- Ensure release notes state which profiles are qualified and which TCBs are in
  scope.

Acceptance:

- A compiler-only release does not implicitly claim QuickJS/WAMR/production
  kernel TCBs.
- Vendored dependency metadata is complete enough for release qualification.
- High/Critical advisory status is release-blocking or explicitly waived.

Risk register links:

- `SCOPE-PRODUCT-SURFACE`
- `SUPPLY-TCB-CVE-INTAKE`
- `TCB-PROFILE-MINIMIZATION`
- `SELFHOST-PROFILE`

## Phase 7: close production-kernel trust boundaries

Purpose: move secure boot and Agent loading from component demos to one typed
trust chain.

Work:

- Introduce an opaque exact-byte `VerifiedBundle` created only by crypto +
  policy verification.
- Make production ELF/Agent loading consume `VerifiedBundle`, not raw bytes plus
  a separate verified flag.
- Bind loaded image identity to bundle digest, payload digest, signer/key ID,
  version, policy version, rollback state, and runtime audit record.
- Make privileged capability/right mint require an unforgeable root token or
  become module-private.
- Wire policy/audit persistence through the production block-backed path.

Acceptance:

- Production loader has no raw-byte admission path.
- Tests cannot express “verify A, load B” through the public API.
- Unauthorized modules cannot mint privileged capabilities.
- Tampered, unsigned, rollback, wrong-key, wrong-platform, and replaced-buffer
  bundles are rejected before load.

Risk register links:

- `KERNEL-VERIFIED-BUNDLE`
- `KERNEL-CAPABILITY-MINT`

## Phase 8: real-board qualification

Purpose: separate QEMU surrogate evidence from production hardware evidence.

Work:

- Bring the selected VisionFive 2 profile to real board boot in the intended
  privilege mode.
- Validate timer, external interrupts, UART, storage, network, watchdog,
  brokered Agent runtime, and reboot reason handling.
- Run storage-full, crash, power-loss, rollback, and long soak tests.
- Record board firmware, DTB, toolchain, artifact digest, and test duration in
  qualification evidence.

Acceptance:

- `production-kernel` profile has hardware evidence, not only QEMU evidence.
- Real-board failures are tracked separately from QEMU surrogate failures.
- Production checklist in `todo.md` has no unchecked item for the claimed
  profile.

Risk register links:

- `HARDWARE-PRODUCTION-QUALIFICATION`

## Suggested execution order

1. Phase 0: inventory current seams.
2. Phase 1: `CompilationSession`.
3. Phase 2: typed MIR identity for optional/result + ABI first.
4. Phase 3: delete backend inference for migrated facts.
5. Phase 4: artifact/source-map metadata.
6. Phase 5: generated gate manifest.
7. Phase 6: profile/TCB manifests.
8. Phase 7: `VerifiedBundle` + capability root.
9. Phase 8: real-board qualification.

Phases 6-8 can start in parallel only after their profile boundaries are
explicit. They should not block compiler-core cleanup unless a release profile
requires them.

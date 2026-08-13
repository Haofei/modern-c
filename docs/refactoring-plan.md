# Refactoring plan

This is the active code-facing refactoring plan for `modern-c`.

Do not create another remediation/status roadmap for the same work. This file
defines the execution order for code-facing compiler-core cleanup.

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
- editor-product and incremental-service work that requires a persistent query service;
- deployable kernel, Agent product, or real hardware claims;
- new vendored runtimes in the default compiler profile.

## Active phases

| Phase | Theme | Primary risks | Exit signal |
|---:|---|---|---|
| 0 | Stop authority growth | `ARCH-BACKEND-FACTS`, `BACKEND-LLVM-PROFILE` | semantic-facts inventory does not grow, or each remaining exception is exact-count-gated. |
| 1 | Typed MIR identity | `ARCH-TYPED-MIR` | backend-critical types, symbols, values, ABI/layout, representation, and control facts are typed or verifier-owned. |
| 2 | `VerifiedProgram` narrowing | `ARCH-TYPED-MIR`, `ARCH-BACKEND-FACTS` | production backend entrypoints no longer expose AST as semantic input. |
| 3 | Artifact provenance | `ARCH-SOURCE-MAP-DIGEST` | emitted bytes, source maps, lowering options, source/MIR digests, and tool identity are bound together. |
| 4 | Manifest-backed gates | `GATE-MANIFEST` | build/CI/docs read compiler-core gate status from one manifest instead of Markdown counters. |
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
- local artifact metadata names the same artifact digest produced locally.

## Phase 4 — make manifests authoritative

Purpose: stop Markdown, CI, and build files from carrying competing compiler-core
gate status truth.

Authoritative inputs:

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

## Current implementation queue

Do these in order unless a failing test forces a narrower slice:

| Order | Slice | Proof |
|---:|---|---|
| 1 | Delete remaining historical compatibility surfaces that are not part of the current CLI, gate, or compiler API. | The surface is removed, all references move to the current entrypoint, and focused CLI/tool tests pass. |
| 2 | Remove or quarantine the next backend-local semantic helper. | `semantic-facts-inventory-test` passes and the touched backend test proves missing facts fail closed. |
| 3 | Convert the next backend-critical fact family toward typed IDs or verifier-owned facts. | MIR admission rejects stale/forged identity before C or LLVM emission. |
| 4 | Narrow the next `VerifiedProgram` or codegen request syntax ingress. | Production C/LLVM entrypoints keep syntax mechanics explicit and exact-count-gated. |
| 5 | Keep active gate status in manifests and short plans, not completed-patch ledgers. | Completed work is represented by Git history and ratchet tests; this document only carries the next execution order. |

Default next patch: continue Phase 0/1 compiler authority work unless a narrower
compatibility-surface deletion is available and independently verifiable.

## Patch rules

Each refactor patch should change one invariant family.

A patch is complete only if it includes:

- the code change;
- one focused regression, inventory check, or manifest check;
- documentation/risk-register changes only when the claim changes;
- no unrelated kernel/product edits.

Split the patch if it:

- changes more than one semantic family;
- adds a new abstraction while leaving the old authority path untracked;
- updates status prose without changing the owning manifest, inventory, code, or
  tests;
- expands an experimental validation workload into a product surface.

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

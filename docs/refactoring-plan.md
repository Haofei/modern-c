# Refactoring plan

This is the active code-facing refactoring plan for `modern-c`.

Do not create separate remediation or status plans for the same work. Open and
closed blocker state lives in [`review-risk-register.yaml`](review-risk-register.yaml).
Product/profile scope lives in [`profile-manifest.json`](profile-manifest.json)
and [`scope-control-plan.md`](scope-control-plan.md). This file only defines the
execution order.

## Goal

Reduce duplicate authority before expanding product surface.

The near-term target is:

```text
Source/session state
        ↓
Syntax + resolved semantic facts
        ↓
Typed MIR + MIR verifier
        ↓
VerifiedProgram
        ↓
Backend emits artifacts mechanically
```

The main rule is simple: C and LLVM may use syntax spelling for emission
mechanics, but not as a semantic authority for type, representation, ABI,
layout, provenance, control flow, or safety decisions.

## Current priority order

| Priority | Workstream | Why it comes first |
|---:|---|---|
| P0 | Typed MIR identity and backend authority | This directly controls miscompile risk and backend drift. |
| P0 | `VerifiedProgram` narrowing | Backend admission must mean verified semantic input, not verified MIR plus AST escape hatches. |
| P1 | Artifact and source-map provenance | Emitted bytes, maps, options, and tool identity must describe the same artifact. |
| P1 | Gate/profile single source of truth | Build, CI, release, docs, and profiles must not maintain competing status ledgers. |
| P2 | Kernel trust-chain hardening | Keep secure boot, Agent, and hardware claims profile-scoped until compiler authority is stable. |
| P2 | Selfhost / advanced LSP / new product surface | Useful, but not allowed to become a second semantic authority or production blocker yet. |

## Milestone plan

Use these milestones to decide what to implement next. They are ordered by
miscompile risk first, product surface second.

### M0 — stop semantic authority growth

Purpose: prevent new backend-local inference while existing helpers are retired.

Allowed work:

- lower an exact-count inventory number;
- convert one backend decision to a MIR/semantic fact;
- add a guard that fails if a backend starts reading AST/type spelling for a
  migrated semantic family;
- document a temporary mechanics-only exception with an exact count.

Exit criteria:

- `semantic-facts-inventory-test` passes;
- no new backend helper can infer type, representation, ABI, provenance, control
  flow, or safety facts without inventory coverage;
- every touched C/LLVM path either consumes the same fact or has a documented
  conservative/fail-closed policy.

### M1 — make typed MIR carry backend-critical identity

Purpose: move the high-risk facts into verifier-owned tables or typed IDs.

Implementation order:

1. call target identity and call result facts;
2. optional/result representation;
3. ABI/layout-sensitive aggregate facts;
4. load/store pointer provenance;
5. trap/runtime-check/control-effect facts.

Exit criteria:

- production lowering positions do not accept `.unknown` except through an
  explicit diagnostic/debug allowlist;
- malformed MIR states are rejected before backend admission;
- backend code does not reconstruct migrated facts from AST shape or string
  spelling.

### M2 — narrow `VerifiedProgram` into the backend admission boundary

Purpose: make codegen admission mean "verified semantic input", not
"verified MIR plus syntax escape hatches".

Implementation order:

1. introduce typed views for symbol spelling, source spans, layouts, ABI facts,
   representation facts, and target config;
2. replace one AST ingress at a time with one of those views;
3. remove direct backend entrypoints that bypass `VerifiedProgram`;
4. keep remaining syntax reads mechanics-only and exact-count-gated.

Exit criteria:

- production C/LLVM entrypoints require `VerifiedProgram`;
- backend APIs no longer expose `ast.Module` as a general semantic input;
- adding a backend does not require reimplementing semantic analysis.

### M3 — bind artifact provenance

Purpose: ensure emitted bytes, source maps, options, and tool identity describe
the same artifact.

Implementation order:

1. add a shared artifact metadata object;
2. attach artifact digest and lowering options to source maps;
3. record source/fact/MIR digest and compiler/toolchain identity;
4. make `build` write the final executable transactionally.

Exit criteria:

- wrong artifact/map pairing is rejected;
- interrupted or failed `build` does not corrupt an existing output;
- release evidence can name the same artifact digest as local builds.

### M4 — generate governance from manifests

Purpose: stop Markdown, CI, release, and build files from carrying competing
status truth.

Implementation order:

1. validate `gate-manifest.json`, `profile-manifest.json`,
   `tcb-components.json`, and `review-risk-register.yaml` together;
2. make build/CI assertions consume manifest IDs;
3. generate Markdown summaries from manifests where practical;
4. keep active prose navigational rather than authoritative.

Exit criteria:

- missing or renamed blocking gates fail manifest tests;
- active Markdown has no independent High/Critical open/closed counters;
- profile claims point to manifest IDs and risk IDs.

### M5 — close profile-scoped kernel production blockers

Purpose: keep kernel/security work from displacing compiler P0 while still
preserving the production path.

Implementation order:

1. exact-byte `VerifiedBundle` API closure;
2. capability/right mint isolation;
3. persistent audit/rollback identity;
4. vendored TCB advisory intake;
5. real hardware qualification gates.

Exit criteria:

- production loader cannot express verify-A/load-B;
- ordinary kernel components cannot mint authority by import convention;
- QEMU evidence is clearly separated from real-device production evidence.

## First implementation backlog

These are intentionally small patch candidates. Do them in order unless a test
failure forces a narrower fix.

| Order | Patch candidate | Proof |
|---:|---|---|
| 1 | Retire or exact-gate the next C backend inference helper from `semantic-facts-inventory.py`. | Inventory count decreases or exception count is locked. |
| 2 | Replace one remaining call-family type lookup with a MIR call/result fact. | Touched call fixtures pass on C and LLVM. |
| 3 | Move one optional/result representation decision into a typed MIR fact. | C/LLVM optional fixtures and malformed-MIR rejection pass. |
| 4 | Replace one backend AST read with a typed symbol/source-spelling view. | Backend AST semantic-read count does not grow. |
| 5 | Add a regression for a migrated fact proving backend AST reconstruction would fail. | Regression fails before the code change or inventory guard. |
| 6 | Introduce the first shared artifact metadata struct without changing emitted bytes. | Emit tests compare unchanged artifacts plus new metadata. |
| 7 | Bind C source-map output to artifact digest. | Wrong map/artifact pairing is rejected. |
| 8 | Make `mcc build` final output transactional. | Interrupted/failing build leaves previous output intact. |
| 9 | Convert one gate/build assertion to consume `gate-manifest.json`. | Manifest test catches a missing gate ID. |
| 10 | Prototype the next `VerifiedBundle` API closure behind the kernel profile. | Verify/load substitution tests fail closed. |

Default next action: continue with backlog items 1–5 until M0/M1 stop finding
backend semantic authority regressions.

## P0 — Compiler semantic authority

### P0.1 Retire backend-local semantic inference

Replace backend-local type/source/representation inference with verified MIR
facts or typed semantic facts.

Execution loop:

1. Pick one remaining inference helper from
   `tools/toolchain/semantic-facts-inventory.py`.
2. Replace it with an existing MIR fact, or add the smallest new typed fact.
3. Delete the old helper, quarantine it behind a generated-node-only path, or
   register a temporary exact-count exception.
4. Add a regression that would fail if the backend reconstructed the fact from
   AST or type spelling.
5. Run the compiler authority verification ladder.

Done when:

- the semantic-facts inventory shows no authority expansion;
- touched C and LLVM paths consume the same fact or have a documented
  conservative/fail-closed policy;
- C/LLVM differential and fixture gates pass for the touched family.

Risk links: `ARCH-BACKEND-FACTS`, `BACKEND-LLVM-PROFILE`.

### P0.2 Strengthen typed MIR identity

Move verified MIR away from string identity, AST `TypeExpr`, and
`kind + optional fields` states.

Preferred order:

1. ABI/layout-sensitive types;
2. calls and call result facts;
3. optional/result representation;
4. loads/stores and pointer provenance;
5. traps and runtime check facts.

Done when:

- migrated types, values, symbols, spans, representation, and ABI facts use
  typed IDs or verifier-owned tables;
- malformed states are unrepresentable or rejected before backend admission;
- `.unknown` is not accepted in production-lowering positions except for an
  explicit diagnostic/debug allowlist.

Risk link: `ARCH-TYPED-MIR`.

### P0.3 Narrow `VerifiedProgram`

Turn `VerifiedProgram` into the only production backend input.

Execution order:

1. Replace one remaining backend `ast.Module` / `TypeExpr` semantic read with a
   typed view: symbol spelling, layout table, ABI table, representation table,
   source-span table, or target config.
2. Gate the old access with exact inventory counts while it remains.
3. Remove direct backend entrypoints that bypass `VerifiedProgram`.

Done when:

- production backend entrypoints do not gain new AST semantic reads;
- every remaining AST access is mechanics-only, exact-count-gated, or scheduled
  in this plan;
- adding a backend does not require duplicating semantic analysis.

Risk links: `ARCH-TYPED-MIR`, `ARCH-BACKEND-FACTS`.

## P1 — Artifact provenance and governance

### P1.1 Bind artifacts, maps, and tool identity

Make `emit-c`, `emit-llvm`, `emit-map`, and `build` produce comparable metadata.

Done when:

- emitted artifact bytes have a digest;
- source maps include and verify the artifact digest;
- lowering options, target, compiler identity, source digest, MIR/fact digest,
  and downstream tool identity are recorded in one metadata path;
- failed or interrupted `build` does not corrupt an existing output.

Risk link: `ARCH-SOURCE-MAP-DIGEST`.

### P1.2 Use manifests as status truth

Keep Markdown navigational. Keep machine-readable files authoritative.

Authoritative files:

- `docs/review-risk-register.yaml` — blocker state;
- `docs/profile-manifest.json` — product profiles and blocking risks;
- `docs/tcb-components.json` — TCB ownership and provenance;
- `docs/gate-manifest.json` — gate ownership, tiers, tools, profiles, skip
  policy.

Done when:

- active Markdown has no independent High/Critical open/closed counters;
- adding or renaming a blocking gate/profile/TCB component is checked from a
  manifest;
- release evidence names the same gate IDs as local builds.

Risk links: `SCOPE-PRODUCT-SURFACE`, `GATE-MANIFEST`,
`TCB-PROFILE-MINIMIZATION`.

## P2 — Profile-scoped production hardening

### P2.1 Kernel exact-byte trust chain

Keep kernel production work profile-scoped until the API cannot express
verify-A/load-B.

Done when:

- an opaque `VerifiedBundle` is created only by crypto and policy verification;
- production ELF/Agent loading consumes `VerifiedBundle`, not raw bytes plus a
  boolean;
- loaded image identity records bundle digest, payload digest, signer/key ID,
  version, policy version, rollback state, and audit identity;
- tamper, replacement, rollback, wrong-key, wrong-platform, and unsigned bundle
  tests fail before load.

Risk link: `KERNEL-VERIFIED-BUNDLE`.

### P2.2 Capability mint isolation

Privileged authority creation must require an unforgeable root token or become
module-private.

Done when:

- ordinary kernel components cannot call `cap_mint`, `rcap_mint`, or
  `rights_grant` by import convention;
- compile-fail or equivalent tests prove non-bootstrap minting is rejected.

Risk link: `KERNEL-CAPABILITY-MINT`.

### P2.3 Hardware and TCB qualification

QEMU remains surrogate evidence. Production hardware claims need separate
qualification.

Done when:

- real-board boot, interrupt, storage, network, watchdog, rollback, crash,
  power-loss, and soak evidence exists for the claimed platform;
- vendored BearSSL, QuickJS, WAMR, openlibm, firmware, and trust anchors have
  owner, revision, license, advisory status, and waiver policy;
- affected High/Critical advisories block release or have explicit accepted
  risk.

Risk links: `HARDWARE-PRODUCTION-QUALIFICATION`, `SUPPLY-TCB-CVE-INTAKE`.

## Explicit deferrals

These are not deleted. They are not allowed to consume core refactor capacity
until their owning profile becomes active.

| Area | Treatment | Re-entry condition |
|---|---|---|
| LLVM as equal production backend | Keep as differential/experimental where coverage is incomplete. | P0 backend authority closes for the relevant semantic families. |
| Selfhost | Keep as bootstrap experiment, not language authority. | Main compiler typed MIR and backend seam are stable for a declared subset. |
| Advanced LSP | Keep existing features working; avoid broad expansion. | Persistent session/query service exists. |
| Production kernel / Agent runtime | Keep profile-scoped; QEMU is surrogate. | Exact-byte bundle, capability mint, persistence, audit, and hardware gates are active. |
| New vendored runtimes | Do not enter default production TCB. | Profile manifest names runtime, owner, gates, and advisory policy. |

## Freeze rules

- No new language surface unless it removes or validates an existing semantic
  fallback.
- No new backend feature unless the required MIR/semantic facts already exist.
- No selfhost expansion until the relevant P0 semantic boundary is stable.
- No advanced LSP expansion until compiler requests can use a stable
  session/query API.
- No production-kernel claim until P2 has typed APIs and hardware evidence.
- No new status Markdown; update the risk register, manifests, or this plan.

## Patch discipline

Each refactor patch should change one invariant family.

A patch is not complete unless it includes:

- the code change;
- one focused regression or inventory check;
- documentation/risk-register changes only if the claim changes;
- no unrelated kernel/LSP/selfhost/release edits.

Stop and split the patch if it:

- changes more than one semantic family;
- adds a new abstraction while leaving the old authority path untracked;
- updates status prose without changing the owning manifest, inventory, code, or
  tests;
- expands an experimental profile into a production claim.

## Verification ladder

For compiler authority slices, normally run:

```text
git diff --check
zig build semantic-facts-inventory-test --summary all
zig build test-unit --summary all
zig build c-test --summary all
zig build sweep --summary all
zig build diff-backend --summary all
```

For governance-only slices, run the touched manifest tests plus
`git diff --check`.

For kernel trust-boundary slices, run focused tamper/substitution or capability
compile-fail tests before changing risk-register status.

## Immediate queue

Use this queue for the next implementation cycle:

| Order | Slice | Primary proof |
|---:|---|---|
| 1 | Remove or quarantine the next backend-local semantic helper from the semantic-facts inventory. | Inventory count decreases or exact exception is locked; C/LLVM touched fixtures pass. |
| 2 | Convert one MIR family, preferably calls or optional tests, toward tagged variants or verifier-owned typed IDs. | Malformed states are rejected before backend admission. |
| 3 | Replace one remaining `VerifiedProgram` AST ingress with a typed symbol/layout/source-spelling view. | Backend AST semantic-read count decreases or stays exact-gated. |
| 4 | Complete shared artifact metadata across remaining emission paths. | Wrong artifact/map pairing is rejected; sidecars carry comparable metadata. |
| 5 | Expand manifest validation toward generated build/CI/release projections. | Manifest tests catch missing/renamed blocking gates. |
| 6 | Prototype the next exact-byte `VerifiedBundle` closure step only if it does not displace compiler P0 work. | Verify/load substitution tests fail closed. |

Current default: work on queue items 1–3 first.

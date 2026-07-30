# Scope control and over-engineering reduction plan

This document keeps the project from treating every implemented subsystem as
equally production-bound. The current imbalance is not that every module is too
abstract; it is that the product surface has grown faster than the compiler's
core semantic boundary.

The near-term priority is therefore to reduce duplicate authority and profile
claims, not to remove safety checks.

## Current imbalance

The repository now contains a language/compiler, C and LLVM backends, selfhost
experiments, kernel/Agent runtime work, LSP/editor tooling, QEMU suites, secure
boot components, release provenance, and multiple vendored TCBs.

Those pieces are useful, but they should not all be treated as one production
profile while the following core items remain open:

- typed MIR identity and verified facts as the backend boundary;
- removal of backend-local semantic inference;
- real module graph and incrementality;
- exact-byte `VerifiedBundle`;
- per-profile TCB definition.

## Profile policy

Use these profiles when deciding whether a gate or subsystem is release-blocking.
The machine-readable source for profile status, blocking risks, blocking gates,
and referenced TCB component IDs is
[`profile-manifest.json`](profile-manifest.json). Component ownership,
provenance, advisory status, and vendored dependency metadata live in
[`tcb-components.json`](tcb-components.json). This table is the prose policy
summary.

| Profile | Blocking scope | Non-blocking / experimental scope |
|---|---|---|
| `compiler-subset` | Parser/sema/MIR verifier, C backend reference path, diagnostics, source loading, C/LLVM differential for covered fixtures | Selfhost, kernel production claims, secure boot, advanced LSP, runtime TCB profiles |
| `llvm-experimental` | LLVM verifier/object/differential smoke for supported fixtures | Full language-surface parity until typed MIR/fact boundaries are complete |
| `selfhost-experimental` | Explicit bootstrap subset tests and fixpoint evidence | Any claim that selfhost is the production compiler or language authority |
| `kernel-qemu` | QEMU boot/runtime workloads, kernel API model tests | Real hardware production support, power-loss/durable security claims |
| `production-kernel` | Exact-byte bundle, persistent policy/audit, real hardware soak, external audit, minimal TCB | QEMU-only evidence, metadata-only secure-boot demos |
| `developer-tools` | Basic diagnostics, formatting, navigation smoke, LSP resource limits | Low-latency incremental service claims until a query DB / persistent compiler service exists |

## Immediate simplification rules

1. Do not add new broad product surfaces unless the owner also specifies the
   profile where they are blocking.
2. Treat C backend as the reference release path until typed MIR/facts remove
   backend-local semantic inference.
3. Treat LLVM backend as differential/experimental where coverage is incomplete.
4. Treat selfhost as an experiment until the main compiler semantic boundary is
   stable.
5. Do not duplicate readiness state across markdown files; summarize
   `docs/review-risk-register.yaml`.
6. Keep safety-critical mechanisms such as atomic output, OOM visibility,
   hostile-input budgets, capability roots, and exact-byte verification. These
   are not over-engineering.

## Gate simplification target

The long-term gate inventory should collapse into one manifest with three
execution tiers:

```yaml
tiers:
  pr:
    intent: fast deterministic feedback
  nightly:
    intent: fuzz, differential, broad fixture sweeps
  release:
    intent: full qualification, QEMU/hardware where applicable, provenance
```

Each gate should declare:

```yaml
id: backend-diff
owner: codegen
category: semantic-equivalence
tier: pr
blocking_profiles:
  - compiler-subset
required_tools:
  - clang
  - llvm
```

Build steps, CI, documentation, and release evidence should be generated from
that manifest rather than maintained as separate string lists.

The current bridge state is:

- profile ownership is machine-readable in `docs/profile-manifest.json`;
- TCB component ownership, provenance, and advisory status are
  machine-readable in `docs/tcb-components.json`;
- the first compiler-core gate subset is machine-readable in
  `docs/gate-manifest.json`;
- `profile-manifest-test` verifies every profile references known risks and
  registered build gates and known TCB component IDs;
- `gate-manifest-test` verifies the pilot gate subset is registered and present
  in its declared build tiers;
- gate generation itself remains open under `GATE-MANIFEST`.

## Non-goals

This plan does not recommend deleting:

- `CompilationSession`;
- typed MIR;
- `VerifiedBundle`;
- atomic artifact output;
- OOM/resource-limit handling;
- capability mint isolation;
- hostile-input tests.

Those are required simplifications of authority and failure behavior, not
unnecessary abstraction.

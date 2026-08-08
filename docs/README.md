# Documentation map

Start here when deciding which document to trust. The repo has several useful
historical plans, but the active source of truth should be small:

- [`../README.md`](../README.md) — project overview, build commands, current backend
  and QEMU coverage.
- [`todo.md`](todo.md) — current consolidated roadmap and known open work.
- [`review-risk-register.yaml`](review-risk-register.yaml) — machine-readable
  source for open review blockers and profile-blocking status.
- [`profile-manifest.json`](profile-manifest.json) — machine-readable product
  profile manifest tying profiles to risks, gates, and components.
- [`component-manifest.json`](component-manifest.json) — machine-readable component
  manifest tying profile component IDs to owners, provenance, advisory status,
  and vendored dependency metadata.
- [`gate-manifest.json`](gate-manifest.json) — machine-readable gate manifest
  for compiler-core/governance ownership, tiers, profiles, and skip policy.
- [`scope-control-plan.md`](scope-control-plan.md) — profile policy for keeping
  experimental surface area separate from production claims.
- [`refactoring-plan.md`](refactoring-plan.md) — ordered refactoring phases that
  turn the open risks into code-facing work with closure criteria.
- [`spec/MC_0.7_Final_Design.md`](spec/MC_0.7_Final_Design.md) — normative language
  and backend contract.
- [`spec/MC_Kernel_Design.md`](spec/MC_Kernel_Design.md) — source-faithful kernel
  architecture and status.

## Current reference docs

These are still useful as day-to-day references or rationale companions:

| Area | Document | Use |
|---|---|---|
| Language interop | [`c-abi-interop.md`](c-abi-interop.md) | C ABI, symbols, strings, trap ABI, boundary diagnostics. |
| Backend seam | [`backend-abstraction.md`](backend-abstraction.md) | Where C/LLVM backends plug into `mcc`. |
| Refactoring | [`refactoring-plan.md`](refactoring-plan.md) | Ordered code-facing refactoring phases derived from the risk register. |
| Kernel-language comparison | [`kernel-language-comparison-plan.md`](kernel-language-comparison-plan.md) | Evidence plan for narrow, fair C/Rust/MC machine-contract comparisons; consumes compiler/language evidence without redefining it. |
| Release/process | [`../SECURITY.md`](../SECURITY.md), [`../STABILITY.md`](../STABILITY.md), [`../CHANGELOG.md`](../CHANGELOG.md), [`release-process.md`](release-process.md) | Security reporting, compatibility expectations, development-line changes, and the release checklist. |
| Scope/profile control | [`review-risk-register.yaml`](review-risk-register.yaml), [`profile-manifest.json`](profile-manifest.json), [`component-manifest.json`](component-manifest.json), [`gate-manifest.json`](gate-manifest.json), [`scope-control-plan.md`](scope-control-plan.md) | Single-source blocker state plus machine-readable profile/risk/gate/component bindings for separating experimental subsystems from stable language work. |
| Testing | [`test-architecture.md`](test-architecture.md), [`qemu-validation-checklist.md`](qemu-validation-checklist.md) | Fixture contracts, gate layers, manifest discipline, and the local/CI QEMU surrogate checklist. |
| Unsafe/UB audit | [`unsafe-boundary.md`](unsafe-boundary.md), [`c-ub-matrix.md`](c-ub-matrix.md), [`lowering-coverage.md`](lowering-coverage.md) | Unsafe syntax, C-UB handling, and lowering coverage reports. |
| Traits/async rationale | [`traits-design.md`](traits-design.md), [`async-plan.md`](async-plan.md) | Design reasoning behind implemented or mostly implemented features. |
| Kernel validation workload | [`platform-portability-plan.md`](platform-portability-plan.md) | Rationale for retained kernel/QEMU language-validation workloads. Prefer `todo.md` for the repo-wide short list. |
| Fuzzing backlog | [`mcfuzz-coverage-todo.md`](mcfuzz-coverage-todo.md) | Generator/oracle expansion notes. Some gating statements are historical; see `todo.md` for current gate status. |

## Historical records

Historical remediation notes, milestone drafts, and experiment records are kept
in git history instead of as live documentation. When an older plan conflicts
with `README.md`, `todo.md`, or the two specs, trust the newer consolidated
sources unless the code proves otherwise.

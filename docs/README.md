# Documentation map

Start here when deciding which document to trust. The repo has several useful
historical plans, but the active source of truth should be small:

- [`../README.md`](../README.md) — project overview, build commands, current backend
  and QEMU coverage.
- [`todo.md`](todo.md) — current consolidated roadmap and known open work.
- [`review-risk-register.yaml`](review-risk-register.yaml) — machine-readable
  source for open review blockers and profile-blocking status.
- [`scope-control-plan.md`](scope-control-plan.md) — profile policy for keeping
  experimental surface area separate from production claims.
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
| Compiler readiness | [`compiler-production-readiness.md`](compiler-production-readiness.md) | Code-grounded gap assessment + phased roadmap for making `mcc` itself production grade (compiler-side complement to `production-readiness-plan.md`). |
| Kernel-language comparison | [`kernel-language-comparison-plan.md`](kernel-language-comparison-plan.md) | Evidence plan for narrow, fair C/Rust/MC machine-contract comparisons; consumes compiler qualification without redefining it. |
| Release/process | [`../SECURITY.md`](../SECURITY.md), [`../STABILITY.md`](../STABILITY.md), [`../CHANGELOG.md`](../CHANGELOG.md), [`release-process.md`](release-process.md) | Security reporting, compatibility expectations, development-line changes, and the release checklist. |
| Scope/profile control | [`review-risk-register.yaml`](review-risk-register.yaml), [`scope-control-plan.md`](scope-control-plan.md) | Single-source open blocker state and rules for separating experimental subsystems from production profiles. |
| Testing | [`test-architecture.md`](test-architecture.md), [`qemu-validation-checklist.md`](qemu-validation-checklist.md) | Fixture contracts, gate layers, manifest discipline, and the local/CI QEMU surrogate checklist. |
| Unsafe/UB audit | [`unsafe-boundary.md`](unsafe-boundary.md), [`c-ub-matrix.md`](c-ub-matrix.md), [`lowering-coverage.md`](lowering-coverage.md) | Unsafe syntax, C-UB handling, and lowering coverage reports. |
| Traits/async rationale | [`traits-design.md`](traits-design.md), [`async-plan.md`](async-plan.md) | Design reasoning behind implemented or mostly implemented features. |
| Agent/kernel direction | [`future-kernel-plan.md`](future-kernel-plan.md), [`production-readiness-plan.md`](production-readiness-plan.md), [`platform-portability-plan.md`](platform-portability-plan.md) | Longer-form rationale and product-readiness plans. Prefer `todo.md` for the repo-wide short list. |
| Fuzzing backlog | [`mcfuzz-coverage-todo.md`](mcfuzz-coverage-todo.md) | Generator/oracle expansion notes. Some gating statements are historical; see `todo.md` for current gate status. |

## Historical records

These documents are retained because they explain decisions and landed work, but
their original "state today" sections are not current backlog:

- [`archive/`](archive/) — historical remediation reports, milestone notes, experiment plans, and completed/deferred campaign records.

When a historical plan conflicts with `README.md`, `todo.md`, or the two specs,
trust the newer consolidated sources unless the code proves otherwise.

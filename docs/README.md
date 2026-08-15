# Documentation map

Start here when deciding which document to trust. The repo has several useful
historical plans, but the active source of truth should be small:

- [`../README.md`](../README.md) — project overview, build commands, current backend
  and QEMU coverage.
- [`todo.md`](todo.md) — current consolidated roadmap and known open work.
- [`refactoring-plan.md`](refactoring-plan.md) — ordered refactoring phases that
  turn the open risks into code-facing work with closure criteria.
- [`spec/MC_0.7_Final_Design.md`](spec/MC_0.7_Final_Design.md) — normative language
  and backend contract.

## Current reference docs

These are still useful as day-to-day references or rationale companions:

| Area | Document | Use |
|---|---|---|
| Language interop | [`c-abi-interop.md`](c-abi-interop.md) | C ABI, symbols, strings, trap ABI, boundary diagnostics. |
| Backend seam | [`backend-abstraction.md`](backend-abstraction.md) | Where C/LLVM backends plug into `mcc`. |
| Refactoring | [`refactoring-plan.md`](refactoring-plan.md) | Ordered code-facing refactoring phases for the compiler core. |
| Codegen ingress migration | [`codegen-ingress-migration.json`](codegen-ingress-migration.json) | Machine-readable budget for AST-shaped declaration payloads still exposed to codegen. |
| Change log | [`../CHANGELOG.md`](../CHANGELOG.md) | Development-line changes. |
| Gate inventory | [`gate-manifest.json`](gate-manifest.json) | Test selection input; not a release-claim source of truth. |
| Testing | [`test-architecture.md`](test-architecture.md) | Fixture contracts, gate layers, and manifest discipline. |
| Unsafe/UB audit | [`unsafe-boundary.md`](unsafe-boundary.md), [`c-ub-matrix.md`](c-ub-matrix.md), [`lowering-coverage.md`](lowering-coverage.md) | Unsafe syntax, C-UB handling, and lowering coverage reports. |
| Traits rationale | [`traits-design.md`](traits-design.md) | Design reasoning behind implemented trait and dynamic-dispatch behavior. |

## Historical records

Historical remediation notes, milestone drafts, and experiment records are kept
in git history instead of as live documentation. When an older plan conflicts
with `README.md`, `todo.md`, or the two specs, trust the newer consolidated
sources unless the code proves otherwise.

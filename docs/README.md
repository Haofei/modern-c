# Documentation map

Start here when deciding which document to trust. The repo has several useful
historical plans, but the active source of truth should be small:

- [`../README.md`](../README.md) — project overview, build commands, current backend
  and QEMU coverage.
- [`todo.md`](todo.md) — current consolidated roadmap and known open work.
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
| Testing | [`test-architecture.md`](test-architecture.md) | Fixture contracts, gate layers, and manifest discipline. |
| Unsafe/UB audit | [`unsafe-boundary.md`](unsafe-boundary.md), [`c-ub-matrix.md`](c-ub-matrix.md), [`lowering-coverage.md`](lowering-coverage.md) | Unsafe syntax, C-UB handling, and lowering coverage reports. |
| Traits/async rationale | [`traits-design.md`](traits-design.md), [`async-plan.md`](async-plan.md) | Design reasoning behind implemented or mostly implemented features. |
| Agent/kernel direction | [`future-kernel-plan.md`](future-kernel-plan.md), [`production-readiness-plan.md`](production-readiness-plan.md), [`platform-portability-plan.md`](platform-portability-plan.md), [`quickjs-agent-plan.md`](quickjs-agent-plan.md), [`agent-sandbox-milestone.md`](agent-sandbox-milestone.md) | Longer-form rationale, current plans, and milestone history. Prefer `todo.md` for the repo-wide short list. |
| Fuzzing backlog | [`mcfuzz-coverage-todo.md`](mcfuzz-coverage-todo.md) | Generator/oracle expansion notes. Some gating statements are historical; see `todo.md` for current gate status. |

## Historical records

These documents are retained because they explain decisions and landed work, but
their original "state today" sections are not current backlog:

- [`agent-os-vision.md`](agent-os-vision.md) — agent-OS thesis.
- [`hardening-todo.md`](hardening-todo.md) — completed/deferred hardening campaign.

When a historical plan conflicts with `README.md`, `todo.md`, or the two specs,
trust the newer consolidated sources unless the code proves otherwise.

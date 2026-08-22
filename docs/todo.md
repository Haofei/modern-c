# Current roadmap

This is the short active backlog for MC. Historical campaigns live in git
history; this file should describe only current compiler-core direction.

## Baseline

- `zig build m0` is the normal local/CI compiler-core gate.
- `zig build m0-full` is the broader validation matrix for the implemented
  language, backends, fuzz oracles, host-driver fixtures, and retained QEMU
  fixtures.
- Freestanding/QEMU fixtures are validation workloads for language, MIR,
  ownership, ABI, unsafe-boundary, and backend-lowering behavior. They are not a
  kernel or OS deliverable track.
- `docs/feature-maturity.json` is the machine-readable feature-status table.
  Advanced language forms stay experimental there until the backend semantic
  authority boundary is closed.

## Active priorities

| Priority | Area | Next work |
|---|---|---|
| P0 | Backend semantic authority | Remove backend-local semantic inference and keep C/LLVM lowering driven by typed MIR, verified facts, layout/ABI tables, and `VerifiedProgram`. |
| P0 | `VerifiedProgram` narrowing | Remove AST-shaped semantic ingress from backend entrypoints; keep source spelling and spans mechanics-only. |
| P0 | Language surface freeze | Keep async, traits, closures, broad generics, `view struct`, `region struct`, `thread_move`, and borrowed-return contracts experimental until the backend authority boundary is closed. |
| P0 | Test speed and sharding | Keep the cheap `m0`/`fast` loop focused; leave broad sweeps in `m0-full` and parallel runners. |
| P1 | Module identity | Move away from text-inclusion identity toward per-file source, module, definition, type, and body IDs. |
| P1 | QEMU validation boundary | Keep RISC-V/QEMU fixtures only where they validate language, ABI, MMIO, ownership, trap/interrupt behavior, or backend lowering. |
| P2 | Fuzzing and independent oracles | Expand fuzz generators only where generated programs can lower into runnable C/LLVM comparisons. |
| P2 | Tooling polish | Improve formatter, diagnostics, and symbol output as needed by active language work. |

## Non-goals in the core backlog

- Kernel deliverable features.
- Filesystem, networking, storage, package, service-supervisor, and
  update/recovery work outside language-validation fixtures.
- Board certification, fleet operations, shipped-image policy, or support
  process.
- New language surface before the current semantic authority boundary is stable.

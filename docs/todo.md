# Current roadmap

This is the short active backlog for MC. Historical campaigns live in git
history; this file should describe only current compiler-core direction.

## Baseline

- `zig build m0` is the normal local/CI compiler-core gate.
- `zig build m0-full` is the broader validation matrix for the implemented
  language, backends, fuzz oracles, runtime experiments, and retained QEMU
  fixtures.
- Kernel code is a validation workload for language, MIR, ownership, ABI,
  unsafe-boundary, freestanding, and backend-lowering behavior. It is not a
  product track.

## Active priorities

| Priority | Area | Next work |
|---|---|---|
| P0 | Backend semantic authority | Remove backend-local semantic inference and keep C/LLVM lowering driven by typed MIR, verified facts, layout/ABI tables, and `VerifiedProgram`. |
| P0 | `VerifiedProgram` narrowing | Remove AST-shaped semantic ingress from backend entrypoints; keep source spelling and spans mechanics-only. |
| P0 | Test speed and sharding | Keep the cheap `m0`/`fast` loop focused; leave broad sweeps in `m0-full` and parallel runners. |
| P1 | Module identity | Move away from text-inclusion identity toward per-file source, module, definition, type, and body IDs. |
| P1 | QEMU validation boundary | Keep RISC-V/QEMU fixtures only where they validate language, ABI, MMIO, syscall, ownership, or backend-lowering behavior. |
| P2 | Fuzzing and independent oracles | Expand fuzz generators only where generated programs can lower into runnable C/LLVM comparisons. |
| P2 | Tooling polish | Improve formatter, diagnostics, and symbol output as needed by active language work. |

## Non-goals in the core backlog

- Kernel product features.
- Filesystems, networking stacks, storage stacks, package ecosystems, service
  supervisors, and update/recovery products.
- Board certification, fleet operations, shipped-image policy, or product
  support process.
- New language surface before the current semantic authority boundary is stable.

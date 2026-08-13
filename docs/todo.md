# Current roadmap

This is the consolidated follow-up list for MC. Older planning notes remain in
this directory as rationale and execution logs, but this file is the short,
current backlog to check first.

Current baseline:

- `zig build m0` is the core compiler qualification gate for normal local/CI
  feedback; `zig build m0-full` is the full milestone gate for the implemented
  language, backend, hardening, fuzz, runtime, and retained QEMU validation
  surface.
- `zig build riscv-qemu-validation` is the focused QEMU/OpenSBI validation gate
  for the retained RISC-V language/backend surrogate.
- The C and LLVM backends both cover the current implemented spec surface.
- RISC-V S-mode under OpenSBI, confined app loading, interrupt-driven driver
  paths, resource governance, and selected cross-architecture kernel gates are
  retained as validation evidence.
- The project is still a prototype. Kernel work is kept as language/compiler
  validation evidence, not as a product track.

## Active priorities

| Priority | Area | Current state | Next work |
|---|---|---|---|
| P0 | Kernel validation workload | Board-specific VisionFive 2 metadata, QMP hotplug, and soak-style qualification fixtures have been removed from the current language-oriented scope. The retained RISC-V QEMU/OpenSBI gates are language/backend evidence, not hardware release evidence. | Keep the QEMU surrogate green only where it validates language, ABI, driver, MMIO, syscall, or backend-lowering behavior. |
| P0 | Interrupt-driven I/O | S-mode timer, single-shot PLIC delivery, re-armed PLIC multishot, context-aware PLIC helper reuse, reusable S-mode PLIC dispatch, and retained device IRQ completion gates pass on both backends. | Keep the promoted IRQ gates green as language/backend evidence. Add hardware runs only when they expose language, ABI, driver, MMIO, syscall, or backend-lowering gaps. |
| P1 | Confined app ABI fixtures | Confined app broker fixtures, the kernel async broker, and the versioned `SYS_SUBMIT` / `SYS_POLL` user ABI have been removed from the current language-oriented scope. | Keep async validation in compiler/host fixtures unless a separate runtime validation profile is created. |
| P1 | Cross-architecture backend gaps | Deep x86/AArch64 QEMU boot/user/VM execution fixtures have been removed from the current language-oriented scope. Compiler-side target coverage remains in host-only arch emission and precise-asm tests. | Keep arch coverage focused on compiler target selection, ABI/data-layout facts, and backend emission; reintroduce platform execution only for a concrete language/backend gap. |
| P1 | Updates and recovery | Kernel update/live-update fixtures were removed from the current language-oriented scope. | Keep update/recovery out of the kernel validation workload unless a separate product profile is created. |
| P1 | Persistence and recovery | Filesystems, block storage, checkpoint-like primitives, lifecycle, and basic BlockDevice persistence gates exist. | Keep only storage/recovery pieces required by active kernel validation fixtures. |
| P1 | Kernel product surface | POSIX/VFS/TCP/DNS/socket/shell/userland/exec product fixtures have been removed from the current language-oriented scope. | Keep kernel validation focused on language, ABI, MMIO, ownership, and backend-lowering evidence. |
| P1 | Multi-architecture platform | RISC-V remains the reference QEMU/OpenSBI validation path. x86_64 and AArch64 are retained as compiler target/emit coverage, not as kernel product platforms. | Keep the RISC-V QEMU/OpenSBI path as the reference validation path. Defer additional platform execution unless it directly validates compiler, ABI, runtime, or backend behavior. |
| P2 | Fuzzing and independent oracles | The mcfuzz oracle family, including `fuzz-metamorphic`, `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-reference`, and `fuzz-corpus`, is registered in `build/fuzz.zig` and wired into `m0-full`; `.github/workflows/nightly-fuzz.yml` also exists for the longer fuzz cadence. | Keep the promoted fuzz gates green in the full/nightly profiles; continue expanding generator surface and independent oracle coverage where backend/runtime support exists. |
| P2 | Remaining mcfuzz generator surface | Most scalar/control-flow coverage has landed. Tagged unions, slices, multi-module programs, external-link programs, and coverage-guided throughput remain open or blocked. | Keep expanding `tools/fuzz/mcfuzz.py` where backend/runtime support exists; do not generate features that cannot yet lower into runnable programs. |
| P2 | Tooling polish | `mcc fmt` and symbol indexing are implemented and gated. | Improve formatter pretty-printing and developer diagnostics as needed by active language work. |

## Historical work folded into this roadmap

Completed campaign notes and experiment drafts live in git history, not as live
documentation. Their current takeaways are folded into this roadmap.

## Kernel validation boundary

There is no kernel product checklist in the current repository scope. Kernel
work remains useful when it validates language, MIR, ownership, backend, ABI,
unsafe-boundary, freestanding, or driver behavior. Product operations, release
images, hardware soak, fleet observability, update policy, and broad hardware
qualification belong to a separate product profile if one is ever created.

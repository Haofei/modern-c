# Current roadmap

This is the consolidated follow-up list for MC. Older planning notes remain in
this directory as rationale and execution logs, but this file is the short,
current backlog to check first.

Current baseline:

- `zig build m0` is the core compiler qualification gate for normal local/CI
  feedback; `zig build m0-full` is the full milestone gate for the implemented
  language, backend, hardening, fuzz, runtime, and QEMU validation surface.
- `zig build riscv-qemu-validation` is the focused QEMU/OpenSBI validation gate
  for the retained RISC-V board-metadata fixture.
- The C and LLVM backends both cover the current implemented spec surface.
- RISC-V S-mode under OpenSBI, confined app loading, interrupt-driven driver
  paths, resource governance, and selected cross-architecture kernel gates are
  retained as validation evidence.
- The project is still a prototype. Kernel work is kept as language/compiler
  validation evidence, not as a product track.

## Active priorities

| Priority | Area | Current state | Next work |
|---|---|---|---|
| P0 | Kernel validation workload | StarFive VisionFive 2 metadata remains as a board-resource fixture (`kernel/platform/starfive_visionfive2/profile.mc`): OpenSBI S-mode plus FDT-described UART/interrupt/storage/network expectations. `visionfive2-resource-test` / `llvm-visionfive2-resource-test` validate the profile's FDT-resource fixture against QEMU, but this is language/backend evidence, not hardware release evidence. | Keep the QEMU surrogate green. Use real hardware only when it exposes language, ABI, driver, async, MMIO, syscall, or backend-lowering gaps. |
| P0 | Interrupt-driven I/O | S-mode timer, single-shot PLIC delivery, re-armed PLIC multishot, context-aware PLIC helper reuse, reusable S-mode PLIC dispatch, and registered S-mode async virtio-blk / virtio-net TX/RX IRQ completion gates pass on both backends. | Keep the promoted IRQ gates green as language/backend evidence. Add hardware runs only when they expose language, ABI, driver, async, MMIO, syscall, or backend-lowering gaps. |
| P1 | Confined app ABI fixtures | Confined app loading, structured submit/poll, bounded request validation, quota/backpressure/cancel handling, and a versioned `SYS_SUBMIT` / `SYS_POLL` ABI contract are retained where they validate compiler, ABI, async, and user-copy behavior. | Keep the fixtures narrow. Product runtime roadmap work is outside current scope. |
| P1 | Cross-architecture backend gaps | C-backed x86/aarch64 paths are substantially gated. LLVM has target-aware `va_list`/`va_arg` lowering and emits target triples/data layouts for retained user-libc objects. | Keep promoted gates green; add cross-architecture depth only when it validates compiler, ABI, runtime, or backend behavior. |
| P1 | Updates and recovery | Kernel update/live-update fixtures were removed from the current language-oriented scope. | Keep update/recovery out of the kernel validation workload unless a separate product profile is created. |
| P1 | Persistence and recovery | Filesystems, block storage, checkpoint-like primitives, lifecycle, and basic BlockDevice persistence gates exist. | Keep only storage/recovery pieces required by active kernel validation fixtures. |
| P1 | VFS/POSIX/network completeness | VFS, fdspace, ramfs/diskfs/blockfs, sockets, DNS/TCP, brokered net calls, and shell/userland tests exist. | Decide the retained syscall subset; add only the POSIX/VFS/network pieces the language/runtime validation workload actually needs. |
| P1 | Multi-architecture platform | RISC-V, x86_64, and AArch64 all have substantial boot/user/VM coverage; device depth varies. | Keep the RISC-V QEMU/OpenSBI path as the reference validation path. Defer x86 virtio-pci data-path depth, AArch64 GIC/timer/virtio depth, and COW/demand portability unless those become near-term validation targets. |
| P2 | Fuzzing and independent oracles | The mcfuzz oracle family, including `fuzz-metamorphic`, `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-reference`, and `fuzz-corpus`, is registered in `build/fuzz.zig` and wired into `m0-full`; `.github/workflows/nightly-fuzz.yml` also exists for the longer fuzz cadence. | Keep the promoted fuzz gates green in the full/nightly profiles; continue expanding generator surface and independent oracle coverage where backend/runtime support exists. |
| P2 | Remaining mcfuzz generator surface | Most scalar/control-flow coverage has landed. Tagged unions, slices, multi-module programs, external-link programs, and coverage-guided throughput remain open or blocked. | Keep expanding `tools/fuzz/mcfuzz.py` where backend/runtime support exists; do not generate features that cannot yet lower into runnable programs. |
| P2 | Tooling polish | `mcc fmt`, symbol indexing, LSP, package registry, and editor client are implemented and gated. | Improve formatter pretty-printing, type-directed completion, and developer diagnostics as needed by active language work. Keep package registry signing/networking outside core language priorities. |

## Historical work folded into this roadmap

Completed campaign notes and experiment drafts live in git history, not as live
documentation. Their current takeaways are folded into this roadmap.

## Kernel validation boundary

There is no kernel product checklist in the current repository scope. Kernel
work remains useful when it validates language, MIR, ownership, backend, ABI,
unsafe-boundary, freestanding, or driver behavior. Product operations, release
images, hardware soak, fleet observability, update policy, and broad hardware
qualification belong to a separate product profile if one is ever created.

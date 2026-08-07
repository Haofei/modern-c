# Current roadmap

This is the consolidated follow-up list for MC. Older planning notes remain in
this directory as rationale and execution logs, but this file is the short,
current backlog to check first.

Current baseline:

- `zig build m0` is the core compiler qualification gate for normal local/CI
  feedback; `zig build m0-full` is the full milestone gate for the implemented
  language, backend, hardening, agent, fuzz, runtime, and QEMU surface.
- `zig build riscv-qemu-validation` is the focused QEMU/OpenSBI surrogate for
  the selected RISC-V board path when VisionFive 2 hardware is unavailable.
- The C and LLVM backends both cover the current implemented spec surface.
- RISC-V S-mode under OpenSBI, confined QuickJS agents, brokered FS/network tool
  paths, resource governance, and many cross-architecture kernel gates are in
  place.
- The project is still a prototype: production readiness now depends more on
  platform, policy, persistence, operations, and scale hardening than on basic
  compiler bring-up.

## Active priorities

| Priority | Area | Current state | Next work |
|---|---|---|---|
| P0 | Production target | The first real-board candidate is StarFive VisionFive 2 (`kernel/platform/starfive_visionfive2/profile.mc`): OpenSBI S-mode, FDT-described UART/interrupt/storage/network resources, and a fixed appliance-kernel scope. `visionfive2-readiness-test` / `llvm-visionfive2-readiness-test` now validate the profile's FDT-resource adapter against QEMU, but this remains surrogate evidence, not hardware evidence. | Keep the QEMU surrogate green until hardware is available; then bring the profile from selected metadata to board boot: validate DTB matching, UART, timer, interrupts, storage, network, watchdog, soak expectations, agent runtime, and release bar. |
| P0 | Interrupt-driven I/O | S-mode timer, single-shot PLIC delivery, re-armed PLIC multishot, context-aware PLIC helper reuse, reusable S-mode PLIC dispatch, registered S-mode async virtio-blk / virtio-net TX/RX IRQ completion gates, production JS `host_net_fetch` completion from a real S-mode virtio-net PLIC interrupt through `SYS_POLL`, and production JS `host_fs_read` completion from a real S-mode virtio-blk PLIC interrupt through `SYS_POLL` all pass on both backends. | Keep the promoted IRQ gates green, then move the same pattern from the QEMU proof path into the selected real-board profile. |
| P1 | Agent production surface | Confined QuickJS agents, structured submit/poll, real FS broker ops, brokered network demos, first-class JS `host_net_fetch`, quota/backpressure/cancel handling, e2e agent showcases, TCP-backed JS `host_net_fetch` over virtio-net, IRQ-backed S-mode JS storage/network completion through `SYS_POLL`, and a versioned `SYS_SUBMIT` / `SYS_POLL` ABI contract are gated. | Add isolated out-of-process tool transport as the default runtime path, cross-arch real-broker parity, and virtio-blk reboot integration only if the product scope requires it. |
| P1 | Cross-architecture backend gaps | C-backed x86/aarch64 agent paths are substantially gated. LLVM now has target-aware `va_list`/`va_arg` lowering, emits target triples/data layouts for non-RISC-V QuickJS/user-libc objects, and the non-RISC-V LLVM QuickJS sync/async gates are in `m0`. | Keep the promoted gates green; focus new cross-architecture work on product-driven runtime, broker, and device parity rather than compiler bring-up. |
| P1 | Updates and recovery | Kernel OTA/live-update fixtures were removed from the current language-oriented scope. | Reintroduce product OTA/recovery only behind a concrete product profile. |
| P1 | Persistence and recovery | Filesystems, block storage, checkpoint-like primitives, lifecycle, and basic BlockDevice persistence gates exist. | Keep only storage/recovery pieces required by active kernel demos; defer product policy/audit persistence. |
| P1 | VFS/POSIX/network completeness | VFS, fdspace, ramfs/diskfs/blockfs, sockets, DNS/TCP, brokered net calls, and shell/userland tests exist. | Decide the retained syscall subset; add only the POSIX/VFS/network pieces the language/runtime validation workload actually needs. |
| P1 | Multi-architecture platform | RISC-V, x86_64, and AArch64 all have substantial boot/user/VM coverage; device depth varies. | Focus now on the real-board RISC-V path. Defer x86 virtio-pci data-path depth, AArch64 GIC/timer/virtio depth, and COW/demand portability unless those become near-term targets. |
| P2 | Fuzzing and independent oracles | The mcfuzz oracle family, including `fuzz-metamorphic`, `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-reference`, and `fuzz-corpus`, is registered in `build/fuzz.zig` and wired into `m0-full`; `.github/workflows/nightly-fuzz.yml` also exists for the longer fuzz cadence. | Keep the promoted fuzz gates green in the full/nightly profiles; continue expanding generator surface and independent oracle coverage where backend/runtime support exists. |
| P2 | Remaining mcfuzz generator surface | Most scalar/control-flow coverage has landed. Tagged unions, slices, multi-module programs, external-link programs, and coverage-guided throughput remain open or blocked. | Keep expanding `tools/fuzz/mcfuzz.py` where backend/runtime support exists; do not generate features that cannot yet lower into runnable programs. |
| P2 | Tooling polish | `mcc fmt`, symbol indexing, LSP, package registry, and editor client are implemented and gated. | Improve formatter pretty-printing, type-directed completion, package registry signing/networking, and developer diagnostics as needed by active work. |

## Historical work folded into this roadmap

Completed campaign notes and experiment drafts live in git history, not as live
documentation. Their current takeaways are folded into this roadmap, the
platform plan, `future-kernel-plan.md`, and `production-readiness-plan.md`.

## Minimum production checklist

The first production claim should require all of these:

- [x] One real board profile is selected and documented.
- [x] Focused RISC-V QEMU/OpenSBI surrogate validation exists.
- [x] Stable `SYS_SUBMIT` / `SYS_POLL` ABI version/error contract exists.
- [ ] Kernel boots on that board in the intended privilege mode.
- [ ] Timer and external interrupts work on that board.
- [ ] Storage and network run through production-shaped, brokered paths.
- [ ] Agent runs confined with no ambient FS/network authority.
- [ ] All external effects go through brokers.
- [ ] Allowed and denied broker decisions are audited.
- [ ] Per-agent memory, request, output, and network budgets are enforced across the production paths.
- [ ] Syscall and broker fuzz tests exist.
- [ ] Long QEMU soak and real-board soak pass.
- [ ] Security review has no unresolved critical findings.

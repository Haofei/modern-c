# TODO - spec/code delta after MC 0.6.1 backend completion

This file is regenerated from the current spec, README, build gates, and source
tree after the LLVM backend was finished for the current spec surface.

Legend:

- `[~]` implemented enough for the current milestone, but not production-grade
- `[ ]` not implemented yet

Current baseline evidence:

- `zig build m0` passes with C, LLVM IR, LLVM object, LLVM O2/object, package,
  std, demo, kernel-module LLVM object, LLVM kernel QEMU boot, host-suite, and
  QEMU gates.
- `docs/spec/MC_0.6.1_Final_Design.md` Appendix M describes LLVM as complete for
  the current spec surface.
- `docs/spec/MC_0.6.1_Final_Design.md` L.3 and README "Prototype or incomplete"
  describe the remaining work as MC-C2/tooling work, not current backend
  conformance work.

## Compiler and spec follow-up

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | Full comptime execution / reflection | `src/eval.zig`, `src/sema.zig`, `tests/spec/comptime.mc`, `tests/c_emit/reflection.mc`, and `reflect-test` cover scalar/aggregate consts, const-fn control flow, layout reflection, and `field_type(...)` in type positions. README still says arbitrary interpreter coverage is incomplete. | Decide the intended MC-C2 interpreter boundary, then add spec fixtures for unsupported const-fn expressions before extending `eval.zig`. |
| `[~]` | Production MIR optimizer use | MIR records checked-operation facts and no-overflow contract facts; LLVM/C gates reject unsafe hidden assumptions. README still says broader range algebra and optimization passes are incomplete. | Add an optimizer pass plan with proof obligations, then gate one real transformation at a time with MIR facts plus C/LLVM equivalence tests. |
| `[~]` | Full CFG-based linear `move` verifier | `src/sema.zig` now checks return-exit leaks, branch-local resources, if-let move payloads, scoped block locals, rejects moving outer resources in loops, and flags loop-body locals that leak on a `break`/`continue` edge (`reject_loop_break_leak`/`reject_loop_continue_leak` in `tests/spec/move_linear.mc`). It is still a frontend state analysis, not a MIR/CFG dataflow pass with explicit unreachable/panic/trap edges and full defer LIFO ordering. | Move linear verification onto MIR/CFG edges with `Live`/`Moved`/`Deferred`/`Unreachable` states, then add fixtures for nested returns, panic/trap exits, and defer ordering. |
| `[~]` | Source/MIR-quality native debug tooling | `emit-map` emits initial `.mcmap`; LLVM emits DWARF and `llvm-debug-test` checks calls, control flow, atomics/fences, and nullable/Result narrowing. Spec N still describes long-term object-to-MC-source/MIR mapping. | Extend `.mcmap` to include stable typed-AST/MIR IDs and object-symbol correlation; add a test that checks map rows against generated C and LLVM object symbols. |
| `[~]` | Production package manager | `tools/toolchain/mcc-pkg.sh`, `pkg-test`, and `llvm-pkg-test` cover local manifests, recursive deps, version checks, and build. README/spec still leave registry and release publishing outside the current implementation. | Define registry metadata, version resolution policy, lockfile format, and publish/install commands; add offline registry fixtures. |
| `[ ]` | LSP and formatter | No LSP or formatter implementation is present. | Choose formatter ownership first, then expose parser/sema diagnostics through an LSP server using the same diagnostic codes as `mcc check`. |

## Standard library and MC-C2 profile

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | `std/mmio` register-field helpers and IO-memory copy | Spec 28.6 explicitly calls `std/mmio` planned; current code uses typed MMIO directly in tests such as `tests/c_emit/mmio*.mc` and QEMU MMIO demos. No `std/mmio.mc` exists. | Add `std/mmio.mc` helpers on top of `Reg`, `RegBits`, `MmioPtr`, and fences; port one driver/demo to the module. |
| `[~]` | Library-scale DMA ownership protocols | `std/dma.mc`, `move` checking, and DMA/cache spec fixtures exist; README says a complete hardware coherence simulation is not implemented. | Add multi-device ownership/state-machine tests and decide whether simulation belongs in std tests, QEMU demos, or host drivers. |
| `[x]` | Virtqueue chain ownership return | `vq_complete_chain` now returns a `move CompletedChain3` whose three `DeviceBuffer`s are handed back to the caller (validated against in-flight presence/length and chain links, typed `VqCompleteError` on any inconsistency); `virtio_blk` reclaims each buffer via `invalidate_for_cpu`/`free` and maps faults to `BlkError.DeviceFault`. Each buffer is reconstructed at its submitted allocation size, never the device-reported length. | Remaining: a timeout path that resets the queue and reclaims still-in-flight buffers (today it fails closed, leaving them device-owned until teardown). |
| `[x]` | Handle provenance for allocators/resources | `Owned<T>` and `Arc<T>` now carry the `*Allocator` they were minted from; `own_free`/`arc_drop` reclaim through that stored allocator with no separate, possibly-mismatched argument — freeing through the wrong owner is unrepresentable. `arc.mc` also exposes immutable shared access plus uniqueness-checked mutable access. | Optionally extend the same provenance to page/DMA handles. |
| `[~]` | Generational handle opacity | `std/arena.mc`, `std/pool.mc`, and slot-style kernel handles validate generation on access, but MC structs are not yet an opacity/privacy boundary, so raw field construction remains a trust assumption for safe APIs. | Add opaque/private field support or constructor-only handle capabilities, then update generational handles so callers cannot forge current-generation references. |
| `[~]` | Advanced packed ABI validation | Packed bits and overlay unions are covered in spec/C/LLVM fixtures; MC-C2 still calls out advanced packed ABI validation. | Add cross-backend ABI golden tests for nested packed overlays, volatile MMIO register fields, and host C layout comparison. |
| `[~]` | Precise asm per compiler/architecture | Precise asm lowering is covered for current C/LLVM paths; MC-C2 calls out per-compiler/arch precision as advanced work. | Split asm fixtures by target/compiler constraints and add negative tests for unsupported constraint combinations. |

## OS integration roadmap derived from current tests

These are outside the MC language/backend spec finish line, but they are the
next practical OS milestones shown by the current kernel, host, and QEMU tests.

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | Endpoint-first IPC and blocking semantics | `endpoint-test`, `ipc-test`, `ipc2-test`, `service-test`, and `waitqueue-test` cover endpoint generation, receive filtering, service loops, and wait queues; raw pid paths still exist. | Mark raw-pid send/call as legacy and make blocking send/call return `Result` or timeout on dead/full targets. |
| `[~]` | Process lifecycle integration | QEMU tests cover process spawn/wait, exec, U-mode, ELF run, vmspace/vmctx, COW, demand paging, and scheduler integration. | Connect fork/exec/wait, fd inheritance, address-space lifecycle, and child-exit waitqueue wakeups into one production path. |
| `[x]` | Page-table-aware user copies | `kernel/core/uaccess.mc` adds `UserAddrSpace` (region bounds + `*PageTable`): `copy_from_user_pt`/`copy_to_user_pt` translate every user VA through the Sv39 page table (`page_table_lookup`) and validate PTE_U plus PTE_R/PTE_W page by page, validating the whole range up front so a copy is all-or-nothing (fail closed). `uaccess-pt-test` proves kernel-only pages, unmapped holes, and off-page straddles are all rejected with nothing copied. The numeric `UserSpace` path stays for identity-mapped bring-up. | Define fault-driven partial-copy/restart semantics once a real trap path exists. |
| `[x]` | Process-death global resource cleanup | `ProcTable` now carries a `death_hook: closure(u32, u32)` invoked by `proc_death_cleanup` with the dead `(pid, gen)`; subsystems install it via `proc_set_death_hook` (the process table stays decoupled from granttab/registry). `death-hook-test` proves an installed hook revokes the dead pid's grants and unregisters its services on `proc_exit`. | Install the hook on the real bring-up path and extend it to other per-owner subsystems as they appear. |
| `[~]` | User-mode service graph | Supervisor, registry v2, manifest, heartbeat/restart, liveupdate, userserver, fs-server, block-server, and net-server tests exist. | Add dependency graph ordering, quiescence, endpoint generation handoff, and restart/live-update compatibility checks. |
| `[~]` | VFS/POSIX completeness | VFS, fdspace, ramfs, diskfs, blockfs, pipes, permissions, shell, libc core, and fs syscall tests exist. | Add nested directories, inode metadata, `stat`, `readdir`, `dup`, `ioctl`, and external program execution from diskfs. |
| `[~]` | Network service completeness | UDP sockets, TCP parser/state/reasm/rtx/window, socket syscall, net server, virtio-net, and live RX tests exist. | Connect TCP to the socket syscall API, add ARP cache/routing/DHCP/DNS, and make IRQ-driven RX the default path. |
| `[~]` | Multi-architecture production path | RISC-V QEMU, OpenSBI, aarch64 boot, x86 boot/scheduler, SMP, IPI, and spinlock tests exist. | Add per-arch trap/paging/interrupt parity, real scheduler SMP integration, and TLB shootdown. |

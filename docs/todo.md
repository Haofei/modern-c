# TODO - spec/code delta as of MC 0.7

The compiler/spec and standard-library/MC-C2 deltas this file used to track are
**all closed** — comptime value folding, the fact-gated MIR optimizer, the CFG-based
linear `move` verifier, source/MIR debug tooling (`.mcmap`), the package manager
(registry/lockfile/publish/install), the LSP + formatter, `std/mmio`, library-scale
DMA ownership, generational-handle opacity, advanced packed-ABI validation, and
per-architecture precise-asm verification all landed with `m0` gates and are
documented in `docs/spec/MC_0.7_Final_Design.md` and `README.md`. See the git
history for the per-feature commits.

What remains below is **outside** the MC language/backend spec finish line: the OS
integration roadmap surfaced by the current kernel, host, and QEMU tests.

Legend:

- `[~]` implemented enough for the current milestone, but not production-grade

Current baseline evidence:

- `zig build m0` passes with C, LLVM IR, LLVM object, LLVM O2/object, package,
  std, demo, kernel-module LLVM object, LLVM kernel QEMU boot, host-suite, and
  QEMU gates.
- `docs/spec/MC_0.7_Final_Design.md` Appendix M describes LLVM as complete for
  the current spec surface.
- `docs/spec/MC_0.7_Final_Design.md` L.3 and README "Prototype or incomplete"
  describe the remaining work as MC-C2/tooling work, not current backend
  conformance work.

## OS integration roadmap derived from current tests

These are outside the MC language/backend spec finish line, but they are the
next practical OS milestones shown by the current kernel, host, and QEMU tests.

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | Endpoint-first IPC and blocking semantics | `endpoint-test`, `ipc-test`, `ipc2-test`, `service-test`, and `waitqueue-test` cover endpoint generation, receive filtering, service loops, and wait queues. The endpoint path (`ipc_call_ep`) returns `Result<…, EpError>`, and **`ipc_send_result`** now gives the raw-pid send a TYPED bounded outcome distinguishing **Denied** (allow_mask), **DeadTarget** (no such/exited process), and **Timeout** (mailbox stayed full for the yield budget) — the Result form of `ipc_try_send`/`ipc_send_timeout`. Covered by `ipc-result-test` (C + LLVM host-suite). | Mark raw-pid send/call as legacy in favour of the endpoint + Result paths; thread `ipc_send_result` through the syscall surface. |
| `[~]` | Process lifecycle integration | QEMU tests cover process spawn/wait, exec, U-mode, ELF run, vmspace/vmctx, COW, demand paging, and scheduler integration. | Connect fork/exec/wait, fd inheritance, address-space lifecycle, and child-exit waitqueue wakeups into one production path. |
| `[~]` | User-mode service graph | Supervisor, registry v2, manifest, heartbeat/restart, liveupdate, userserver, fs-server, block-server, and net-server tests exist. **Dependency-graph ordering** now landed: a per-service `deps` array (`supervisor_set_dep`) + `supervisor_start_ordered` performs a topological start — a service is spawned/Running only once its declared dependency is Running, and a missing or cyclic dependency is rejected (`DepUnsatisfied`) rather than partially started. `supervisor-test` (C + LLVM host-suite) registers C→B→A out of order and asserts they spawn in dependency order (via the increasing assigned pids), and that a cycle is rejected. | Add quiescence (steady-state detection), endpoint generation handoff, and restart/live-update compatibility checks. |
| `[~]` | VFS/POSIX completeness | VFS, fdspace, ramfs, diskfs, blockfs, pipes, permissions, shell, libc core, and fs syscall tests exist. **`vfs_stat`** (size/capacity/position inode+descriptor metadata) and **`vfs_dup`** (descriptor copy onto the same backing file, position copied) now landed, with `ramfs_capacity`; covered by the `vfs-test` host driver on C + LLVM. | Add nested directories, `readdir`, `ioctl`, a shared open-file-description offset for `dup`, and external program execution from diskfs. |
| `[~]` | Network service completeness | UDP sockets, TCP parser/state/reasm/rtx/window, socket syscall, net server, virtio-net, and live RX tests exist. | Connect TCP to the socket syscall API, add ARP cache/routing/DHCP/DNS, and make IRQ-driven RX the default path. |
| `[~]` | Multi-architecture production path | RISC-V QEMU, OpenSBI, aarch64 boot, x86 boot/scheduler, SMP, IPI, and spinlock tests exist. | Add per-arch trap/paging/interrupt parity, real scheduler SMP integration, and TLB shootdown. |

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
| `[~]` | Process lifecycle integration | QEMU tests cover process spawn/wait, exec, U-mode, ELF run, vmspace/vmctx, COW, demand paging, and scheduler integration. **Process fd lifecycle now landed end to end.** `fd_inherit` (kernel/lib/fdspace, on `slotmap_alloc_at`) copies a whole fd-space preserving fd numbers across gaps; a `Process` (kernel/core/process) carries an `FdSpace`, and **fork/exec/wait fd semantics are wired**: `proc_spawn` gives the child a COPY of the spawner's fds (same numbers, independent), `proc_exec` swaps the image but PRESERVES fds (fork copies, exec preserves), and `proc_death_cleanup` releases a dying process's fds so a reused slot inherits no ghost. The full fork→exit→reap→reuse→exec path is covered by `forkfd-test` (C + LLVM host-suite). | Wire the fd-space into the syscall surface (open/close/dup over `proc_fds`), add close-on-exec flags, and connect a real ELF entry from `elf_parse_header` into `proc_exec` on the QEMU exec path. |
| `[~]` | User-mode service graph | Supervisor, registry v2, manifest, heartbeat/restart, liveupdate, userserver, fs-server, block-server, and net-server tests exist. **Dependency-graph ordering** now landed: a per-service `deps` array (`supervisor_set_dep`) + `supervisor_start_ordered` performs a topological start — a service is spawned/Running only once its declared dependency is Running, and a missing or cyclic dependency is rejected (`DepUnsatisfied`) rather than partially started. `supervisor-test` (C + LLVM host-suite) registers C→B→A out of order and asserts they spawn in dependency order (via the increasing assigned pids), and that a cycle is rejected. | Add quiescence (steady-state detection), endpoint generation handoff, and restart/live-update compatibility checks. |
| `[~]` | VFS/POSIX completeness | VFS, fdspace, ramfs, diskfs, blockfs, pipes, permissions, shell, libc core, and fs syscall tests exist. **`vfs_stat`** (size/capacity/position inode+descriptor metadata) and **`vfs_dup`** (descriptor copy onto the same backing file, position copied) now landed, with `ramfs_capacity`; covered by the `vfs-test` host driver on C + LLVM. | Add nested directories, `readdir`, `ioctl`, a shared open-file-description offset for `dup`, and external program execution from diskfs. |
| `[~]` | Network service completeness | UDP sockets, TCP parser/state/reasm/rtx/window, socket syscall, net server, virtio-net, and live RX tests exist. An **ARP cache** (`kernel/net/arp_cache`) now caches IP→MAC bindings so the stack does not re-ARP every send: a bounded table with insert/refresh-in-place, typed `lookup` (Miss, no sentinel), `invalidate`, and round-robin eviction when full; covered by `arp-cache-test` (C + LLVM). | Connect TCP to the socket syscall API, add routing/DHCP/DNS, wire the ARP cache into the send path, and make IRQ-driven RX the default. |
| `[~]` | Multi-architecture production path | RISC-V QEMU, OpenSBI, aarch64 boot, x86 boot/scheduler, SMP, IPI, and spinlock tests exist. The **arch-neutral TLB-shootdown bookkeeping** now exists (`kernel/core/tlb_shootdown`): a shootdown carries a `targets` core-mask (every core but the initiator) and an `acked` mask over the checked `Mask32`, with `shootdown_begin`/`ack`/`pending`/`complete` — the coordination (which cores must flush, wait until all ack) that gates a mapping change, separate from the per-arch IPI + flush. `tlb-shootdown-test` (C + LLVM) covers initiator-excludes-self, non-target/duplicate acks, completion, range provenance, and the single-core trivial case. | Wire it to the per-arch IPI + TLB-flush, and add per-arch trap/paging/interrupt parity and real scheduler SMP integration. |

# MINIX-parity TODO

What this kernel is missing relative to MINIX 3, as a checklist. Ordered: the
**microkernel-essential** gaps first (what makes us a faithful MINIX-style microkernel —
a finite, well-understood list), then the **OS-completeness** gaps (large, but mostly
volume + borrowed components, and orthogonal to microkernel design).

Legend: `[ ]` missing · `[~]` partial (note says what we already have) · `[x]` done.

> **Progress (language/stdlib hardening pass):** landed (1) **const-generic struct
> params** `Foo<T, N>` — parser accepts integer type-args, the monomorphizer substitutes
> the value into `[N]T`; `std/pool` is now `Pool<T, N>` and `constgen-test` exercises
> `Ring<T, N>` at two capacities; (2) **memory grants** (`std/grant`, `grant-test`); (3)
> **`ipc_call`/sendrec**; (4) a **move-checker fix** — by-value `move` args inside an
> `if`-condition / `switch`-subject are now consumed (no more `let tmp = f(x)` workaround).
> All gated; 80 `m0` gates green.

---

## Tier 1 — Microkernel-essential (the real to-do)

### Protection & isolation
- [x] Per-server **MMU isolation** — `isolation_demo`: two processes in separate page
      tables see only their own frame at the shared VA and exchange data only via
      cross-address-space IPC (`isolation-test`).
- [x] Servers run in **user mode** — `userserver_demo`: a service loop runs in U-mode and
      reaches the kernel only through syscalls (`userserver-test`).
- [x] **Kernel calls** — `kcall(op, arg)` gateway, gated by a per-process kcall mask
      (`privilege-test`). Real privileged ops behind the gate are still stubbed.
- [x] **Memory grants** — `std/grant`: bounded, revocable delegation (`grant-test`). Cross-
      *address-space* transfer still pending per-server isolation; today the region is shared.
- [x] **Per-server privilege model** — per-process IPC allow-list (`ipc_try_send`) +
      kcall mask (`privilege-test`). IRQ/port allow-lists still TODO.

### IPC completeness
- [x] **Asynchronous notify** — `ipc_notify` (non-blocking, drop-if-full). `ipc2-test`.
- [x] **Source filtering on receive** — `ipc_receive_from(src)`. `ipc2-test`.
- [x] **`sendrec`** — `ipc_call` (send + block for reply) in process.mc.
- [x] **Queued / multi-slot mailboxes** — per-process IPC_SLOTS mailbox. `ipc2-test`.
- [x] **IPC timeouts** — `ipc_receive_timeout` (bounded poll, no infinite block). `timeout-test`.

### Process & memory model
- [~] **copy-on-write** — `kernel/core/cow`: two spaces share a RO frame; a write faults,
      the writer gets a private copy, the other keeps the original (`cow-test`). Full
      `fork` (whole-AS duplication driving this per-page) is the remaining integration.
- [x] **Signals** (kernel primitive) — `proc_kill`/`proc_sigpending`/`proc_sigtake`
      (`signal-test`). POSIX handlers/default-actions (a PM server) still TODO.
- [x] **Demand paging** — `kernel/core/demand`: an S-mode page-fault handler maps a page
      at the faulting address and the instruction retries transparently (`demand-test`).
- [~] **`mmap`** — `kernel/core/mmap` `mmap_anon`/`munmap`: map anonymous pages into a
      page table, read/written under active satp (`mmap-test`). Shared memory + swapping TODO.

### Core servers
- [x] **Reincarnation with heartbeat liveness** — supervisor detects a missed heartbeat
      via `ipc_receive_timeout` and restarts (bounded policy). `heartbeat-test` +
      `restart-test`. Dependency-aware recovery still TODO.
- [x] **Name / registry server** — `registry_demo`: services register by key, clients
      look up by name (`registry-test`). Pub/sub config still TODO.
- [x] **Userspace-set scheduling policy** — `proc_set_priority` (policy set externally) +
      `proc_yield_priority` (kernel runs highest-priority runnable). `usched-test`.

---

## Tier 2 — OS completeness (large, mostly orthogonal to microkernel design)

### Filesystem
- [~] **VFS multi-FS switch** — `kernel/fs/vfsmount`: mount/umount/resolve dispatches to
      a backing FS by key (`vfsmount-test`). Path-prefix routing + live mounting into the VFS TODO.
- [x] **On-disk filesystem format** (persistent) — `kernel/fs/diskfs`: superblock + inode
      table + data on the device, re-read on remount (`diskfs-test`).
- [~] **Directories / paths** — `diskfs` has a root directory (name->inode lookup,
      `diskfs-test`); nested dirs/paths still TODO.
- [~] **inodes** — on-disk inodes (size + data block) in `diskfs`; permissions/times/owner TODO.
- [x] **Buffer / page cache** — `kernel/fs/bcache`: write-back, dirty-tracked, hit/miss (`bcache-test`).

### POSIX & userland
- [~] **POSIX syscall layer** — `kernel/core/posix`: getpid + open/write/read/close + ENOSYS
      over the dispatch table (`posix-test`). Full set (fork/exec/wait/dup/ioctl/...) TODO.
- [~] **libc** — `std/libc`: minimal core (mc_memeq/mc_strlen/mc_atoi), `libc-test`. Full libc TODO.
- [~] **A shell** — `kernel/core/shell` tokenizes + runs core builtins (`echo`/`true`/
      `false`/`exit`); an interactive **user-mode** REPL (`shell_user_demo`) adds `top` in
      its own layer (dispatched via `sh_arg_eq`), reading the real ProcTable through
      SYS_PROC_* syscalls. Console I/O via SYS_GETC/SYS_PUTC (`ushell-test`, `shell2-test`;
      `zig build run-ushell`). TODO before [x]: dispatch/run **external programs** (fork/exec
      from `diskfs` via the ELF loader) so it's a real command surface, and a live PM-owned
      process table feeding `top` (currently a spawned-but-unscheduled snapshot).
- [~] **A userland** — `kernel/core/userland`: an `echo` utility over the args vector
      (`userland-test`) + shell builtins. Full utility set TODO (borrowed in MINIX).
- [~] **Dynamic linking** — `kernel/core/dynlink`: R_RISCV_RELATIVE relocation pass for
      PIE images (`dynlink-test`). Symbol resolution + PLT/GOT + .so loading TODO.
- [x] **Users / permissions** — `kernel/core/perm`: uid/gid + rwx-mode checks, root bypass (`perm-test`).
- [x] **Pipes/FIFOs + fd-based I/O + select** — `kernel/core/pipe` FIFO (`pipe-test`) +
      `kernel/core/fdtable` (pipe/socket fds, `fd_select`, `fdtable-test`).
- [x] **argv/envp** — `kernel/core/args`: packed NUL-terminated argument vector (`args-test`).
- [~] **Process groups / sessions** — `kernel/core/pgroup`: setsid/setpgid/getpgid/getsid (`pgroup-test`). Full job control TODO.

### Drivers (real, isolated, varied)
- [~] **Real-hardware NIC driver** — `kernel/drivers/pci` + `kernel/drivers/e1000`: PCI-
      enumerate + discover the real Intel e1000 (0x8086:0x100E) + read its BAR over ECAM
      (`e1000-test`). Full TX/RX rings + AHCI/SATA disk TODO.
- [~] **Device classes** — framebuffer (`kernel/drivers/fb`, `fb-test`) + RTC (`rtc-test`).
      Keyboard/USB/audio TODO.
- [~] **Device-tree parsing** — `kernel/core/fdt`: FDT magic/totalsize/version (`fdt-test`).
      PCI/ACPI enumeration + full DTB node walk TODO.
- [~] **TTY line discipline** — `kernel/core/tty`: canonical mode (backspace + newline-
      completed lines, `tty-test`). Full TTY server + job control TODO.

### Networking
- [~] **TCP as a server** — `tcp_server_demo`: the TCP state machine runs as a user-mode
      server; a client drives a passive-open handshake to ESTABLISHED over IPC (`tcp-server-test`).
      DNS/DHCP/routing/multi-interface TODO.
- [~] **BSD sockets as fds** — `fdtable` exposes sockets as descriptors with select
      readiness (`fdtable-test`); full bind/connect/accept-over-fd TODO.

### Platform / portability
- [~] **Real-hardware boot path** — `sbi-boot-test`: boots under OpenSBI (the real RISC-V
      firmware used on hardware) in S-mode via the SBI ABI. Boot-from-disk image + a
      physical board still TODO.
- [~] **Multiple architectures** — `kernel/arch/aarch64`: MC code compiled + booted on a
      2nd architecture (aarch64 QEMU virt, `aarch64-test`), alongside riscv64. Full aarch64
      kernel port (trap/paging/context) TODO; x86 TODO.
- [~] **SMP scheduling** — `kernel/core/smprq`: per-core run queues + work stealing
      (`smprq-test`), on top of the 2-hart bring-up + ticket spinlock + IPIs. Wiring the
      live scheduler onto per-core queues TODO.
- [~] **Wall-clock / RTC** — `rtc_demo` reads the goldfish-RTC MMIO (host time, `rtc-test`),
      alongside the CLINT timer. Full clock management (settimeofday, NTP) TODO.

### Reliability extras
- [x] **MMU-backed crash containment** — `contain_runtime`: a faulting server is contained
      by the page-fault handler (redirected to recovery, no panic); system continues (`contain-test`).
- [~] **Live update** — `kernel/core/liveupdate`: checkpoint a service's state, install a
      new version, restore the state into it (`liveupdate-test`). Full transparent live
      update (quiescence, transfer of all servers) TODO.

---

## Suggested order of attack (Tier 1 first)
1. Run servers in their own address spaces (per-server `satp`) + IPC over the `ecall`
   trap → real fault isolation. (Machinery exists in `vmspace`/`sched-vm`.)
2. **Kernel calls** + **memory grants** — the controlled privileged gateway + safe
   cross-AS data (needed once §1 separates address spaces).
3. Richer **IPC** (async/notify, source filtering, `sendrec`).
4. **`fork` + COW** and **signals** in a Process-Manager server.
5. **Demand paging** + a real **page-fault handler** (kill, don't panic).
6. **Name/registry server** + a real **reincarnation** policy.

Tiers 1 completes the *microkernel*; Tier 2 is the road to a *complete OS* and is mostly
independent work (and, like MINIX, much of the userland could be borrowed rather than
written).

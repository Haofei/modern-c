# Kernel audit, plan, and foundational patch

This is the audit / prioritized plan / first-patch artifact the brief asks to "start
by producing." It is written against the current state (the roadmap is implemented;
see `kernel-todo.md`), so the audit reflects a finished build and the plan covers the
remaining refinements.

## 1. Build / test status (audit)

- `zig build` — green; `zig build test` — green (language + std fixtures).
- `zig build m0` — **green, 62 gates.** Coverage by roadmap phase:
  - **Short-term:** build/test fixes, fail-closed trap + panic diagnostics, page
    allocator validation + real freeing, virtio-net/packet refactor, QEMU regression
    gates.
  - **Medium-term:** physical frame allocator, Sv39 page tables, kernel heap, kernel
    threads + context switch, cooperative + preemptive timer scheduler, UART/console
    driver framework, virtio-blk, ramfs + VFS + file syscalls.
  - **Long-term:** user mode, ELF loader + load-and-run, process lifecycle
    (spawn/exit/wait/reap/exec), file + socket syscalls, ramfs/VFS/block-backed FS,
    UDP + TCP (segments, state machine, window, reassembly, retransmit + timer,
    sockets, real TX + RX demux + live RX-queue wiring), SMP (bring-up, ticket
    spinlock, IPIs), debugging (trace ring, log levels, symbolized backtraces,
    fuzzing). Paging is activated (S-mode satp), per-process address spaces are
    switched by the scheduler, and one integrated image boots all of it + the NIC.
- **Compiler/stdlib work surfaced by the kernel (foundation-first):** ~15 compiler
  features/fixes (function pointers, global + struct-field atomics, address-class
  casts, enum-literal comparisons, `operandEmitType`, fn-pointer typedefs, …) plus
  std abstractions (typed addresses, `Result`/typed errors, bounds-checked byte
  reader/writer, endian + wrapping helpers, DMA/virtqueue ownership tokens, barriers,
  spinlock, gigapage mapper).

## 2. Prioritized plan (remaining refinements)

These are refinements on proven mechanisms, not unimplemented pillars:

1. **Foundational — remove kernel complexity (this patch, below).** Eliminate the
   "bind a bool/enum field of an array element to a local before using it in a
   condition" workaround that recurred in 10+ sites.
2. Inbound UDP → socket end to end (slirp DNS round-trip) on top of the live RX path.
3. Map the user image through page tables instead of PMP; demand paging.
4. ARP cache; full IPv4 validation (IHL/total-length/fragments); interrupt-driven
   RX/TX; a `netif` abstraction.
5. Remaining compiler ergonomics: nested `arr[i].field[j]`; fn-pointer-call as a
   bare condition; global struct-value stores.

## 3. First patch series — foundational improvement

**Make a bool/enum field of an array element usable directly** (`if table[i].used`),
instead of forcing `let x: bool = table[i].used; if x` everywhere. Two layers:

- **MIR verifier** (`src/mir.zig`): `structTypeNameAliasDepth` now dereferences a
  pointer (`*mut T` → `T`), so `typeExprForExpr` resolves member access through a
  pointer parameter; `t.items[i].field` types correctly and the bool-operator check
  stops rejecting it.
- **C backend** (`src/lower_c.zig`): `exprIsBoolForEmission`'s `.member` case now uses
  `operandEmitType`, so a `switch` lowered from `if table[i].field` is cast to `int`
  (no `-Wswitch-bool`).

This removed the workaround at 10 sites across `ramfs`, `vfs`, `udp_socket`, and
`blockdev` (now plain `if fs.files[i].used` / `if !v.fds[i].active`), and all 62 gates
+ the language fixtures stay green. It removes complexity rather than adding a demo.

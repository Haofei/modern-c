# kernel/lib — reusable OS/framework modules

The layering rule for generic code:

- **`std/`** — freestanding primitives. No process, syscall, scheduler, fd, service, or
  kernel-policy assumptions. Usable outside this kernel unchanged. (ring, slotmap, pool,
  arena, alloc, byteview, bytes, mask, addr, sync, time, …)
- **`kernel/lib/`** — reusable OS building blocks that *do* assume an OS shape: IPC
  message queues, request/reply service loops, wait queues, fd spaces, process snapshots.
  Generic and testable in isolation, but OS-flavored — they belong to the kernel, not std.
- **`kernel/core/`** — trusted mechanisms: the scheduler, process table, syscall dispatch,
  low-level IPC, traps, memory primitives. The minimal privileged base everything builds on.
- **`kernel/*`** — concrete subsystems and drivers.

Litmus test for a generic module: *"would this be useful outside this kernel?"* Yes → std.
No (it encodes an OS policy/shape) → kernel/lib. Partly → split a std primitive from a
kernel/lib policy wrapper.
